// Author:  Hafizi Yahaya
// Created: 2026-11-23
//
// Multi-window multi-burn-rate SLO alerting for the Tier 1 digital service.
// Narrative: ../02-observability.md section 8.2 and 8.3.
// Spec:      ./slo-spec.yaml
//
// Resource names match ../01-reliability-model.md section 1 and ../diagrams/architecture.svg.
//
// CloudWatch Application Signals computes burn rate natively for services it discovers.
// This file covers the journeys that span CloudFront, API Gateway and EKS, which
// Application Signals does not compose into a single journey SLI on its own.

locals {
  region         = "us-east-1"
  api_name       = "apigw-tier1-use1"
  sns_sev1       = aws_sns_topic.sev1.arn
  sns_sev2       = aws_sns_topic.sev2.arn
  sns_ticket     = aws_sns_topic.ticket.arn

  // Journeys scored at 99.99 percent. CUJ-1 is excluded deliberately: it carries a
  // 99.9 percent objective because ext-idp sits on its synchronous path.
  // See ../00-scope-assumptions.md section 2.4.
  scored_journeys = {
    "cuj2" = { stage = "prod", resource = "/session/validate", objective = 0.9999 }
    "cuj3" = { stage = "prod", resource = "/account",          objective = 0.9999 }
    "cuj4" = { stage = "prod", resource = "/transaction",      objective = 0.9999 }
  }

  // burn_rate: multiple of the budget consumption rate that would exactly exhaust the
  //            budget over the window.
  // long/short: the pair that must BOTH breach. The short window is what stops an alert
  //             firing on a condition that has already resolved.
  burn_windows = {
    "fast" = { burn = 14.4, long_sec = 3600,   short_sec = 300,   severity = "sev1",   action = "page" }
    "slow" = { burn = 6.0,  long_sec = 21600,  short_sec = 1800,  severity = "sev2",   action = "page" }
    "day"  = { burn = 3.0,  long_sec = 86400,  short_sec = 7200,  severity = "sev3",   action = "ticket" }
    "week" = { burn = 1.0,  long_sec = 259200, short_sec = 21600, severity = "sev3",   action = "ticket" }
  }

  // Flatten journeys x windows x {long,short} into one alarm set.
  burn_alarms = merge([
    for jk, j in local.scored_journeys : merge([
      for wk, w in local.burn_windows : {
        "${jk}-${wk}-long"  = { journey = jk, cfg = j, window = wk, w = w, period = w.long_sec }
        "${jk}-${wk}-short" = { journey = jk, cfg = j, window = wk, w = w, period = w.short_sec }
      }
    ]...)
  ]...)
}

// ---------------------------------------------------------------------------
// Component alarms. One per journey, per burn rate, per window length.
// Each evaluates: (5xx / total) / (1 - objective) >= burn_rate
// ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "burn" {
  for_each = local.burn_alarms

  alarm_name = "tier1-journey-${each.value.journey}-burn-${each.value.w.burn}x-${
    endswith(each.key, "-long") ? "long" : "short"
  }"
  alarm_description = join(" ", [
    "Journey ${upper(each.value.journey)} burning error budget at >= ${each.value.w.burn}x",
    "over ${each.value.period}s.",
    "Objective ${each.value.cfg.objective}. Budget 4.32 min per 30d window.",
  ])

  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = each.value.w.burn
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"

  // No actions on component alarms. The composite alarm below is what notifies,
  // so that a single breaching window does not page on its own.
  actions_enabled = false

  metric_query {
    id          = "burn_rate"
    expression  = "(errors / FILL(requests, 0)) / ${1 - each.value.cfg.objective}"
    label       = "Burn rate (multiples of budget consumption)"
    return_data = true
  }

  metric_query {
    id = "errors"
    metric {
      namespace   = "AWS/ApiGateway"
      metric_name = "5XXError"
      period      = each.value.period
      stat        = "Sum"
      dimensions = {
        ApiName  = local.api_name
        Stage    = each.value.cfg.stage
        Resource = each.value.cfg.resource
        Method   = "ANY"
      }
    }
  }

  metric_query {
    id = "requests"
    metric {
      namespace   = "AWS/ApiGateway"
      metric_name = "Count"
      period      = each.value.period
      stat        = "Sum"
      dimensions = {
        ApiName  = local.api_name
        Stage    = each.value.cfg.stage
        Resource = each.value.cfg.resource
        Method   = "ANY"
      }
    }
  }

  tags = {
    Service  = "tier1-digital-service"
    Journey  = upper(each.value.journey)
    Severity = each.value.w.severity
    Class    = "symptom" // Only symptom alerts page. See ../02-observability.md section 8.1.
  }
}

// ---------------------------------------------------------------------------
// Composite alarms. Long AND short must both breach before anything notifies.
// ---------------------------------------------------------------------------
resource "aws_cloudwatch_composite_alarm" "burn" {
  for_each = {
    for k, v in {
      for pair in setproduct(keys(local.scored_journeys), keys(local.burn_windows)) :
      "${pair[0]}-${pair[1]}" => { journey = pair[0], window = pair[1], w = local.burn_windows[pair[1]] }
    } : k => v
  }

  alarm_name        = "tier1-journey-${each.value.journey}-burn-${each.value.w.burn}x"
  alarm_description = "Multi-window burn-rate breach on ${upper(each.value.journey)}. ${each.value.w.action}, ${each.value.w.severity}."

  alarm_rule = join(" AND ", [
    "ALARM(${aws_cloudwatch_metric_alarm.burn["${each.value.journey}-${each.value.window}-long"].alarm_name})",
    "ALARM(${aws_cloudwatch_metric_alarm.burn["${each.value.journey}-${each.value.window}-short"].alarm_name})",
  ])

  alarm_actions = [
    each.value.w.action == "page"
    ? (each.value.w.severity == "sev1" ? local.sns_sev1 : local.sns_sev2)
    : local.sns_ticket
  ]

  // Suppress when an AZ-wide or region-wide condition is already alarming. One AZ
  // failure should produce one alert, not forty. See ../02-observability.md section 8.4.
  actions_suppressor                    = aws_cloudwatch_composite_alarm.regional_event.alarm_name
  actions_suppressor_wait_period        = 60
  actions_suppressor_extension_period   = 120
}

// ---------------------------------------------------------------------------
// Fast path. Burn-rate windows are tuned to protect a budget over time and are
// structurally too slow for a journey that has just stopped. This is deliberately
// crude. It exists to be fast. See ../02-observability.md section 8.3.
// ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "hard_down" {
  for_each = local.scored_journeys

  alarm_name        = "tier1-journey-${each.key}-hard-down"
  alarm_description = "${upper(each.key)} availability below 95 percent for 2 consecutive minutes. Sev1, page immediately."

  comparison_operator = "LessThanThreshold"
  threshold           = 95
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  treat_missing_data  = "breaching" // No data on a Tier 1 journey is itself a symptom.

  alarm_actions = [local.sns_sev1]
  ok_actions    = [local.sns_sev1]

  metric_query {
    id          = "availability_pct"
    expression  = "100 * (1 - (errors / FILL(requests, 1)))"
    label       = "Availability percent"
    return_data = true
  }

  metric_query {
    id = "errors"
    metric {
      namespace   = "AWS/ApiGateway"
      metric_name = "5XXError"
      period      = 60
      stat        = "Sum"
      dimensions  = { ApiName = local.api_name, Stage = each.value.stage, Resource = each.value.resource, Method = "ANY" }
    }
  }

  metric_query {
    id = "requests"
    metric {
      namespace   = "AWS/ApiGateway"
      metric_name = "Count"
      period      = 60
      stat        = "Sum"
      dimensions  = { ApiName = local.api_name, Stage = each.value.stage, Resource = each.value.resource, Method = "ANY" }
    }
  }

  tags = { Service = "tier1-digital-service", Journey = upper(each.key), Severity = "sev1", Class = "symptom" }
}

// ---------------------------------------------------------------------------
// RPO monitors. RPO is a measurement, not a setting. Critical fires at HALF the
// 5-minute objective so there is room to act before it is missed.
// See ../04-regional-recovery.md section 4.2.
// ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "aurora_rpo_lag_critical" {
  alarm_name          = "tier1-aurora-global-rpo-lag-critical"
  alarm_description   = "AuroraGlobalDBRPOLag above 150s. The 5-minute RPO is at risk BEFORE any outage has occurred. Sev2."
  namespace           = "AWS/RDS"
  metric_name         = "AuroraGlobalDBRPOLag"
  dimensions          = { DBClusterIdentifier = "aur-tier1-use1" }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  comparison_operator = "GreaterThanThreshold"
  threshold           = 150000 // milliseconds
  treat_missing_data  = "breaching"
  alarm_actions       = [local.sns_sev2]
  tags                = { Service = "tier1-digital-service", Class = "symptom", Severity = "sev2" }
}

resource "aws_cloudwatch_metric_alarm" "aurora_rpo_lag_warning" {
  alarm_name          = "tier1-aurora-global-rpo-lag-warning"
  alarm_description   = "AuroraGlobalDBRPOLag above 60s. Investigate before it approaches the objective."
  namespace           = "AWS/RDS"
  metric_name         = "AuroraGlobalDBRPOLag"
  dimensions          = { DBClusterIdentifier = "aur-tier1-use1" }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  comparison_operator = "GreaterThanThreshold"
  threshold           = 60000
  alarm_actions       = [local.sns_ticket]
  tags                = { Service = "tier1-digital-service", Class = "symptom", Severity = "sev3" }
}

// ---------------------------------------------------------------------------
// Settlement pipeline. MaxOffsetLag per partition, NOT SumOffsetLag.
// A single stalled partition out of thirty is invisible in a sum and is a total
// outage for every customer whose key hashes to it.
// See ../01-reliability-model.md section 4.3.
// ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "msk_partition_stall" {
  alarm_name          = "tier1-msk-partition-stall"
  alarm_description   = "MaxOffsetLag on any single partition indicates a stalled partition, likely a poison message. CUJ-5 freshness at risk."
  namespace           = "AWS/Kafka"
  metric_name         = "MaxOffsetLag"
  dimensions          = { "Cluster Name" = "msk-tier1-use1", "Consumer Group" = "settlement-consumer" }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  comparison_operator = "GreaterThanThreshold"
  threshold           = 10000
  alarm_actions       = [local.sns_sev2]
  tags                = { Service = "tier1-digital-service", Class = "symptom", Severity = "sev2" }
}

// DLQ alarms on oldest message AGE, not depth. Depth answers how much is broken.
// Age answers how long a customer has been waiting. See ../03-resilience.md section 8.2.
resource "aws_cloudwatch_metric_alarm" "dlq_age" {
  alarm_name          = "tier1-settlement-dlq-oldest-age"
  alarm_description   = "Oldest message in sqs-tier1-settlement-dlq older than 15 minutes."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateAgeOfOldestMessage"
  dimensions          = { QueueName = "sqs-tier1-settlement-dlq" }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = 900
  alarm_actions       = [local.sns_sev2]
  tags                = { Service = "tier1-digital-service", Class = "symptom", Severity = "sev2" }
}

// ---------------------------------------------------------------------------
// Suppressor. Groups a regional or AZ-wide condition so downstream journey
// alarms do not each page separately.
// ---------------------------------------------------------------------------
resource "aws_cloudwatch_composite_alarm" "regional_event" {
  alarm_name        = "tier1-regional-event-suppressor"
  alarm_description = "AZ-wide or region-wide condition detected. Suppresses downstream journey alert actions so one event produces one alert."

  alarm_rule = join(" OR ", [
    "ALARM(tier1-az-capacity-loss)",
    "ALARM(tier1-aws-health-regional-event)",
  ])
}

resource "aws_sns_topic" "sev1"   { name = "tier1-sev1-page" }
resource "aws_sns_topic" "sev2"   { name = "tier1-sev2-page" }
resource "aws_sns_topic" "ticket" { name = "tier1-ticket" }

// Routing continues: SNS -> EventBridge -> Systems Manager Incident Manager response plan,
// which holds the engagement ladder and the incident record.
// See ../02-observability.md section 8.5.
