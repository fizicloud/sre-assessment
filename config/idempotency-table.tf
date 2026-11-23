// Author:  Hafizi Yahaya
// Created: 2026-11-23
//
// ddb-tier1-idempotency — DynamoDB Global Table.
// Narrative: ../03-resilience.md section 4, ../04-regional-recovery.md section 7.1.
//
// WHY DYNAMODB AND NOT AURORA:
//   Idempotency state must survive the loss of the region whose failure makes replay
//   necessary. Storing idempotency keys in aur-tier1-use1 means that during a regional
//   recovery, the store that would prevent duplicate processing is the store that is
//   unavailable. A Global Table is active-active across both regions and is reachable
//   throughout. See ../03-resilience.md section 4.3.
//
// SECOND ROLE, which is less obvious and matters more during recovery:
//   Because this table is active-active and was reachable throughout, it records
//   acceptances that the promoted Aurora cluster may have no transaction row for.
//   Comparing the two identifies the LOST ACCEPTANCE set precisely, rather than
//   estimating it from a time window. It is the authority for "what did we accept".
//   See ../04-regional-recovery.md section 7.1.

resource "aws_dynamodb_table" "idempotency" {
  name         = "ddb-tier1-idempotency"
  billing_mode = "PAY_PER_REQUEST" // Submit traffic is spiky. Provisioned capacity on
                                   // the idempotency store would make it the thing that
                                   // throttles a traffic spike, which is the opposite of
                                   // what it is for.
  hash_key     = "pk"

  attribute {
    name = "pk" // sha256(tenant_id + ":" + idempotency_key)
    type = "S"
  }

  attribute {
    name = "transaction_id"
    type = "S"
  }

  // Reverse lookup for reconciliation: given a transaction, find its acceptance record.
  global_secondary_index {
    name            = "transaction_id-index"
    hash_key        = "transaction_id"
    projection_type = "ALL"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true // 24 hours. Long enough to cover any client retry window,
                         // short enough that the table does not grow without bound.
  }

  point_in_time_recovery { enabled = true }

  // SEC: encryption at rest with a MULTI-REGION KMS key. A regional key would make the
  // replicated data unreadable in the recovery region, which is the classic failure
  // where cross-region replication produces durable, replicated, undecryptable data.
  // See ../04-regional-recovery.md section 6.
  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.tier1_multiregion.arn
  }

  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  // Active-active in both regions. No promotion step exists and none is required,
  // which is why idempotency state is reachable throughout a failover.
  replica {
    region_name            = "us-west-2"
    kms_key_arn            = aws_kms_replica_key.tier1_usw2.arn
    point_in_time_recovery = true
  }

  tags = {
    Service    = "tier1-digital-service"
    Journey    = "CUJ-4"
    DataClass  = "transactional"
    Criticality = "hard-dependency" // Submit FAILS CLOSED if this is unavailable. A
                                    // submit without idempotency protection is not
                                    // accepted. See ../01-reliability-model.md section 3.
  }
}

// ---------------------------------------------------------------------------
// ACCEPTED RESIDUAL RISK, recorded rather than solved.
//
// DynamoDB Global Tables replicate asynchronously with last-writer-wins conflict
// resolution. During a failover there is a replication-lag window in which the same
// idempotency key could be accepted in BOTH regions.
//
// Three things bound the risk and none of them eliminates it:
//   1. Traffic shift is not instantaneous, so a duplicate requires a client retrying
//      across the shift boundary within the lag window.
//   2. transaction_id is client-generated, so duplicates stay detectable after the fact.
//   3. The reconciliation in ../04-regional-recovery.md section 7.3 is specifically
//      designed to catch duplicates created during a failover.
//
// When this materialises it is REPORTED, not quietly corrected. A risk accepted in
// design and then hidden when it occurs was never really accepted.
// Carried in ../07-validation-limitations.md.
// ---------------------------------------------------------------------------

resource "aws_kms_key" "tier1_multiregion" {
  description             = "tier1 multi-region CMK — must be multi-region or replicated data is unreadable after failover"
  multi_region            = true
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

resource "aws_kms_replica_key" "tier1_usw2" {
  provider                = aws.usw2
  description             = "tier1 multi-region CMK replica, us-west-2"
  primary_key_arn         = aws_kms_key.tier1_multiregion.arn
  deletion_window_in_days = 30
}

// Scheduled decrypt test in the recovery region. The multi-Region key failure is
// invisible until recovery is attempted, so it is verified continuously rather than
// assumed. Checked as item 3 of the dependency validation in
// ../runbooks/dr-regional-failover.md section 7.
resource "aws_cloudwatch_event_rule" "kms_decrypt_probe_usw2" {
  provider            = aws.usw2
  name                = "tier1-kms-decrypt-probe-usw2"
  description         = "Proves the multi-region CMK can decrypt in the recovery region BEFORE it is needed"
  schedule_expression = "rate(15 minutes)"
}
