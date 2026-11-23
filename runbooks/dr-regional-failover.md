# Runbook: regional failover, us-east-1 to us-west-2

**Service:** Tier 1 digital service
**RTO:** 45 minutes · **RPO:** 5 minutes · **RMiT 10.32 single-incident ceiling:** 120 minutes
**Authority to execute:** Incident Commander, pre-delegated, no further approval required
**Design rationale:** [`../04-regional-recovery.md`](../04-regional-recovery.md)

> This runbook is written to be executed under pressure by someone who did not write it. Steps are imperative. Every verification is explicit. Placeholders in angle brackets are resolved from the parameter table in section 0.
>
> **Values in this runbook are illustrative placeholders.** ARNs, endpoints and identifiers are populated from the real environment before this runbook is considered live.

---

## 0. Parameters

| Placeholder | Source |
|---|---|
| `<GLOBAL_CLUSTER_ID>` | `aur-tier1-global` |
| `<USW2_CLUSTER_ARN>` | Aurora cluster ARN, `aur-tier1-usw2` |
| `<USE1_CLUSTER_ARN>` | Aurora cluster ARN, `aur-tier1-use1` |
| `<RC_USE1_ARN>` | ARC routing control ARN, primary cell |
| `<RC_USW2_ARN>` | ARC routing control ARN, recovery cell |
| `<ARC_CLUSTER_ENDPOINTS>` | The five ARC cluster endpoints. **Try each in turn until one responds.** |
| `<READINESS_CHECK_USW2>` | ARC readiness check name, recovery cell |
| `<REPLICATOR_ARN>` | MSK Replicator ARN, `mskrep-tier1` |

---

## 1. STOP. Read this first.

**Do not execute this runbook if any of the following is true.**

| Condition | Why | Go to instead |
|---|---|---|
| The recovery region is not healthy, or `syn-cuj*` canaries in `us-west-2` are failing | Failing into a broken region converts a regional outage into a total one | Continue in-region recovery |
| The cause is data corruption, a bad migration, or an erroneous bulk update | Aurora replicates physically. The fault is already in `us-west-2`. Failover propagates it and destroys the clean comparison point. | Aurora point-in-time recovery runbook |
| The cause is understood and fixable inside the remaining RTO budget | Failover costs 10.4 months of error budget | Fix in region, re-evaluate every 5 min |
| You have not declared a Sev1 | Failover without incident command produces no decision log and no evidence | Declare first, section 05 |

Decision tree: [`../04-regional-recovery.md`](../04-regional-recovery.md) section 2.2.

---

## 2. Phase 1 — Detection confirmed (target T+2)

- [ ] Hard-down alarm or burn-rate alarm firing on a scored journey
- [ ] `us-east-1` canaries failing
- [ ] **`us-west-2` canaries passing** — this is the signal that the problem is regional and the recovery region can serve
- [ ] Check AWS Health Dashboard for a `us-east-1` service event
- [ ] Record the wall-clock time of first customer impact. This starts the RMiT 10.32 clock.

```bash
# Journey health, both regions
for R in us-east-1 us-west-2; do
  echo "== $R =="
  aws cloudwatch describe-alarms --region $R \
    --alarm-name-prefix "tier1-journey-" \
    --state-value ALARM \
    --query 'MetricAlarms[].{Alarm:AlarmName,Since:StateUpdatedTimestamp}' \
    --output table
done
```

---

## 3. Phase 2 — Capture the RPO before it is unrecoverable (target T+4)

> **Do this before anything else changes.** `AuroraGlobalDBRPOLag` is published from the primary region. Once the primary is gone or promotion has occurred, the figure that defines your actual RPO may no longer be retrievable. This number is a regulatory and customer-communication input, not a curiosity.

```bash
aws cloudwatch get-metric-statistics \
  --region us-east-1 \
  --namespace AWS/RDS \
  --metric-name AuroraGlobalDBRPOLag \
  --dimensions Name=DBClusterIdentifier,Value=aur-tier1-use1 \
  --start-time "$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time   "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 60 --statistics Maximum \
  --query 'reverse(sort_by(Datapoints,&Timestamp))[:10].[Timestamp,Maximum]' \
  --output table
```

- [ ] **Record the last datapoint in the decision log. This is the actual RPO.**
- [ ] If it exceeds 300 seconds, the 5-minute RPO is already breached. **Escalate to the service owner before proceeding** — this is now data loss beyond the agreed RPO and the Incident Commander does not hold that authority alone. See section 04.3.

```bash
# MSK Replicator lag — the stream RPO
aws kafka describe-replicator --region us-east-1 \
  --replicator-arn <REPLICATOR_ARN> \
  --query 'ReplicatorState' --output text
```

---

## 4. Phase 3 — Decision (target T+10)

- [ ] Work the decision tree in section 1 above
- [ ] Confirm the recovery region's readiness check is passing

```bash
aws route53-recovery-readiness get-readiness-check-status \
  --readiness-check-name <READINESS_CHECK_USW2> \
  --query '{Readiness:Readiness,Resources:Resources[?Readiness!=`READY`]}' \
  --output json
```

**If readiness is not `READY`, stop and read the failing resources.** The ARC gating safety rule will block the routing control change anyway. Common causes: a service quota never raised in `us-west-2`, a missing subnet, a drifted security group.

- [ ] Record the decision in the decision log using the section 05.5 format. Include the RPO figure from phase 2.
- [ ] Communications Lead issues the first customer notification. **State impact and next update time. Do not state a cause.**
- [ ] Declare a **Regional Disaster Event** per section 01.6.1 and note the timestamp.

---

## 5. Phase 4 — Promote the data tier (target T+20)

### 5.1 Aurora

> Use `failover-global-cluster` for an **unplanned** event, where the primary is unavailable. Use `switchover-global-cluster` **only** when the primary is healthy, which is failback and planned maintenance, not this runbook.

```bash
aws rds failover-global-cluster \
  --region us-west-2 \
  --global-cluster-identifier <GLOBAL_CLUSTER_ID> \
  --target-db-cluster-identifier <USW2_CLUSTER_ARN>
```

- [ ] Poll until the global cluster is available and `us-west-2` is the writer

```bash
watch -n 15 "aws rds describe-global-clusters --region us-west-2 \
  --global-cluster-identifier <GLOBAL_CLUSTER_ID> \
  --query 'GlobalClusters[0].{Status:Status,Members:GlobalClusterMembers[].{Cluster:DBClusterArn,Writer:IsWriter}}' \
  --output json"
```

- [ ] Verify a write succeeds against `rdsproxy-tier1-usw2`

```bash
psql "host=rdsproxy-tier1-usw2.<...> dbname=tier1 sslmode=require" \
  -c "BEGIN; INSERT INTO failover_probe(ts) VALUES (now()); COMMIT; SELECT max(ts) FROM failover_probe;"
```

**No application configuration change is required.** Applications address `rdsproxy-tier1-usw2`, which is already bound to the local cluster.

### 5.2 MSK

- [ ] Confirm consumer group offsets have synchronised into `msk-tier1-usw2`
- [ ] Leave settlement consumers **paused** until after traffic shift and dependency validation. Starting them now sends calls to `ext-payments` before egress has been verified.

---

## 6. Phase 5 — Shift traffic (target T+25)

> ARC routing control changes go through the **data plane**, which requires one of the five cluster endpoints. Try each until one responds. This is the whole point of ARC: it works when regional control planes do not.

```bash
# 1. Recovery region ON
for EP in <ARC_CLUSTER_ENDPOINTS>; do
  aws route53-recovery-cluster update-routing-control-state \
    --endpoint-url "$EP" --region us-west-2 \
    --routing-control-arn <RC_USW2_ARN> \
    --routing-control-state On && break
done

# 2. Primary region OFF
for EP in <ARC_CLUSTER_ENDPOINTS>; do
  aws route53-recovery-cluster update-routing-control-state \
    --endpoint-url "$EP" --region us-west-2 \
    --routing-control-arn <RC_USE1_ARN> \
    --routing-control-state Off && break
done
```

**Order matters.** Recovery region On first. The "at least one region On" assertion rule will reject turning the primary Off while the recovery control is still Off, which is the rule doing its job.

- [ ] Confirm both control states

```bash
for EP in <ARC_CLUSTER_ENDPOINTS>; do
  aws route53-recovery-cluster get-routing-control-state \
    --endpoint-url "$EP" --region us-west-2 \
    --routing-control-arn <RC_USW2_ARN> && break
done
```

- [ ] Confirm `origin.tier1.example` resolves to the `us-west-2` endpoint. TTL is 60 s.

```bash
dig +short origin.tier1.example
```

---

## 7. Phase 6 — Validate dependencies (target T+35)

**This phase is where failovers fail.** Everything above is AWS-internal and generally behaves. These are the external and regional facts that were either prepared months ago or were not.

| # | Check | Command or signal | Fail action |
|---|---|---|---|
| 1 | **`ext-payments` reachable from `us-west-2`** | `syn-ext-payments` canary in `us-west-2` green | Provider egress allowlist is missing the `us-west-2` NAT EIPs. **Cannot be fixed inside the RTO.** Settlement stays paused, transactions keep being accepted, escalate to the provider immediately. |
| 2 | **`ext-idp` reachable from `us-west-2`** | `syn-ext-idp` canary green | New sign-ins fail, existing sessions survive for up to 12 h. Escalate to the provider. |
| 3 | **KMS decrypt in `us-west-2`** | Scheduled decrypt test green | Multi-Region key missing. Encrypted data is unreadable. Escalate immediately, this blocks recovery. |
| 4 | Secrets present | Application pods start and pass readiness | Replica secret missing |
| 5 | Service quotas | ARC readiness check | Request an increase, may not be grantable in time |
| 6 | Certificates valid | ACM in `us-west-2` | Reissue |
| 7 | Configuration parity | Compare configuration hash across regions | Deploy from the single source of truth |

```bash
# Canary status, recovery region
aws synthetics describe-canaries-last-run --region us-west-2 \
  --query 'CanaryLastRun[?starts_with(CanaryName,`syn-`)].{Canary:CanaryName,State:LastRun.Status.State}' \
  --output table
```

- [ ] All seven checks pass, or each failure has a recorded decision and an owner

---

## 8. Phase 7 — Confirm journeys and resume settlement (target T+40)

- [ ] All `syn-cuj*` canaries green from `us-west-2`
- [ ] Journey SLI error rate returning to baseline
- [ ] Business metric: transactions accepted per minute recovering toward normal

**Only now resume settlement consumers**, and resume them with the controlled drain in section 03.8.4. Do not resume at full rate.

```
Resume at 25% -> hold 5 min -> verify ext-payments latency and error rate
  -> 50% -> hold 5 min -> verify
  -> 75% -> hold 5 min -> verify
  -> 100%
```

Any step that degrades the downstream reverts to the previous rate. The backlog is durable in MSK. There is no reason to drain faster than `ext-payments` can absorb, and every reason not to.

- [ ] Communications Lead issues the recovery notification
- [ ] **Record the measured RTO**: first customer impact to journey confirmation. Compare against 45 min and against the RMiT 120-min ceiling.

---

## 9. Phase 8 — After recovery

### 9.1 Immediate

- [ ] **Record both downtime ledgers** per section 04.9.3: the SLO ledger with the disaster exclusion, and the RMiT 10.32 ledger with no exclusion
- [ ] Capture evidence per section 05.7 **before it ages out**. CloudWatch one-minute metrics are retained for 15 days. X-Ray traces for 30.
- [ ] Hand over to the next shift using the section 05.8 template if the incident spans shifts

### 9.2 Reconciliation

Run the procedure in section 04.7. **Not during recovery. After stability is confirmed.**

- [ ] Compare `ddb-tier1-idempotency` against `aur-tier1-usw2` for the window. This identifies **lost acceptances**, where a customer was told the transaction was accepted and no durable record exists.
- [ ] Retrieve settlement status from `ext-payments` for every transaction in the window
- [ ] Classify into the four classes in section 04.7.3
- [ ] **Lost acceptances require customer communication.** Re-submit with the original idempotency key so the provider deduplicates if it did reach them.
- [ ] **Duplicates are reported, not quietly corrected.** They are the known Global Table lag risk from section 03.4.3 materialising.
- [ ] Produce the reconciliation report for finance and audit

### 9.3 Understand the new risk position

> **The service is now running in a single region with no cross-region recovery capability.** After an unplanned failover the Aurora global cluster is degraded. The former primary must be removed and a new secondary built, which is an hours-to-days rebuild for a large dataset. A second regional event during this window has no answer.
>
> This is the highest-risk period of the entire incident and it begins after everyone has declared it resolved. Raise it explicitly at handover and in the executive brief.

- [ ] Begin the Aurora global cluster rebuild
- [ ] Track the single-region window as a live risk until the rebuild completes
- [ ] **Do not attempt failback.** See section 04.8. Failback is a planned change, days later, under change advisory, using `switchover-global-cluster` for zero data loss.

### 9.4 Review

- [ ] Blameless review within 5 business days per section 05.9
- [ ] **State detection time and time to mitigate separately.** A single MTTR figure hides which half of the problem the organisation has.
- [ ] Record measured RTO and RPO against targets in the game-day and incident record
- [ ] Any step in this runbook that was ambiguous, wrong or missing is corrected **as part of the review**, not later
