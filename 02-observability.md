# 02. Observability architecture

Weight: 15 percent. Selected cloud: **Amazon Web Services**.

## 1. Diagnosis before design

The brief states two symptoms together: many alerts, and slow detection of customer-impacting failures. These read like opposites and they are not. They are the two halves of one pathology, and naming it correctly determines the whole design.

A system alerted on **causes** produces exactly this picture. Causes are numerous, because every component has dozens of ways to look unhealthy. Cause alerts fire constantly for conditions no customer ever notices, which trains responders to ignore them. And they systematically fail to fire for novel failures, because a cause alert can only detect a failure mode somebody predicted in advance.

A system alerted on **symptoms** has few alerts, every one of them customer-relevant, and it catches failure modes nobody anticipated, because the symptom of an unanticipated failure looks the same as the symptom of an anticipated one.

The design therefore has one organising rule, and the rest of this section implements it:

> **Only journey-level symptom alerts page a human. Cause-level signals are rich, retained and queryable, and they never page.**

Cause signals are not deleted. They are demoted. They are what the responder reads after the symptom alert wakes them, and they are the reason diagnosis is fast once detection has happened. Deleting them would trade a detection problem for a diagnosis problem.

## 2. Telemetry standards

### 2.1 Instrumentation standard

OpenTelemetry is the single instrumentation standard for application telemetry. Services emit OTLP. The reasons are specific rather than fashionable. Instrumentation outlives backend choices, and a bank that re-instruments every time it changes observability vendors pays for the same work repeatedly. AWS now ships first-class OTel support through the AWS Distro for OpenTelemetry, so this costs nothing in native integration.

Infrastructure and managed-service metrics stay native. CloudWatch is where MSK, Aurora, API Gateway and CloudFront publish, and routing those through a collector adds a failure mode for no benefit.

### 2.2 Collector topology

ADOT runs on `eks-tier1-use1` and `eks-tier1-usw2` in two tiers.

| Tier | Deployment | Responsibility |
|---|---|---|
| Agent | DaemonSet, one per node | Receives OTLP from pods on the same node, host and container metrics, Kubernetes attribute enrichment, no sampling decisions |
| Gateway | Deployment, horizontally scaled, behind a Service | Tail sampling, attribute redaction, batching, export to CloudWatch, X-Ray and Amazon Managed Service for Prometheus |

The two tiers exist because of tail sampling. A sampling decision that depends on whether any span in a trace failed requires every span of that trace in one place. A per-node collector only ever sees the spans from its own node, so it cannot make that decision. Running agent-only is the most common reason tail sampling silently degrades into head sampling.

### 2.3 Required attributes

Enforced in code review and verified by a scheduled query that fails the build when a service emits spans missing required attributes. A standard that is not enforced is a wiki page.

| Scope | Attribute | Purpose |
|---|---|---|
| Resource | `service.name`, `service.version`, `deployment.environment` | Service identity and version correlation for deployment-caused failures |
| Resource | `cloud.region`, `cloud.availability_zone` | AZ-level failure attribution, which is otherwise guesswork |
| Resource | `k8s.namespace.name`, `k8s.pod.name`, `k8s.node.name` | Blast radius identification |
| Span | `journey.id` | One of CUJ-1 to CUJ-5. The attribute that makes journey-level SLIs possible. |
| Span | `transaction.id` | Correlates the synchronous submit with the asynchronous settlement |
| Span | `idempotency.key.hash` | Duplicate-submit analysis without storing the key itself |
| Span | `tenant.id.hash` | Per-customer impact analysis without storing an identifier |
| Log | `trace_id`, `span_id`, `journey.id`, `level` | Log to trace correlation |

`journey.id` is the load-bearing one. Without a journey label propagated from the edge, there is no way to compute an SLI for a journey that spans six services, and every SLI degrades into a per-service technical metric. That degradation is why most organisations in this position have service dashboards and no journey view.

### 2.4 Cardinality discipline

Metrics, traces and logs have different cardinality economics, and conflating them is the most common cause of a runaway observability bill.

| Signal | Cardinality rule |
|---|---|
| Metrics | Bounded dimensions only: journey, region, AZ, service, version, status class. **Never** customer id, transaction id, or request id. |
| Traces | Unbounded attributes permitted. This is where high-cardinality identifiers belong. |
| Logs | Unbounded fields permitted. Top-N analysis via CloudWatch Contributor Insights rather than via metric dimensions. |

The practical rule: if a question is "how many" it is a metric, if it is "which one" it is a log or a trace. Teams that answer "which customer is failing" with a metric dimension discover the cost at the end of the month.

### 2.5 Sampling

| Traffic class | Policy |
|---|---|
| Errors, any span with `status=ERROR` | 100 percent retained |
| Slow traces above the journey p99 objective | 100 percent retained |
| Traces touching `ext-payments` or `ext-idp` | 100 percent retained |
| CUJ-4 submit, successful | 10 percent |
| Everything else, successful | 1 to 5 percent, tuned to budget |

Implemented in the ADOT gateway with the `tail_sampling` processor, policies evaluated in that order.

**X-Ray's default sampling rule is not adequate for this service and must be replaced.** The default reservoir of one request per second plus 5 percent of the remainder is designed for cost control on a general workload. At a 99.99 percent target the paging threshold is a 0.144 percent error rate, as computed in section 05. Probabilistic sampling at those rates returns a handful of failing traces across a fleet, and the responder is diagnosing a customer-impacting failure from a sample that may contain none of the failures. Keeping 100 percent of errors costs little, because at a healthy error rate there are few of them.

## 3. Correlation

The requirement is a single trace from the customer's request at the edge through to the database statement, and onward across the asynchronous settlement hop. Three joins are genuinely hard and each is addressed specifically.

### 3.1 Edge to gateway

CloudFront does not propagate a W3C trace context by default. A **CloudFront Function** on the viewer-request event injects a `traceparent` header when one is absent.

CloudFront Functions is the correct choice over Lambda@Edge here. Header manipulation at sub-millisecond latency with no cold start is exactly its design point, and a Tier 1 journey should not accept Lambda@Edge's additional latency on every request for a header rewrite.

The edge anchor is CloudFront's own `x-amz-cf-id`, which is generated for every request, returned to the client and present in CloudFront logs. It is the identifier a customer can quote from a failed response, which makes it the join key for customer-reported issues.

### 3.2 The dual trace-header problem

This is the join that breaks most often and it deserves naming.

AWS native services propagate `X-Amzn-Trace-Id`. OpenTelemetry propagates W3C `traceparent`. API Gateway with X-Ray tracing enabled generates and forwards the AWS header. An OTel-instrumented application reading only `traceparent` will start a **new** trace, and the chain breaks precisely at the boundary between the gateway and the application, which is the boundary a responder most needs to cross.

The fix is to configure both propagators in the SDK and in the ADOT collector, with the X-Ray propagator registered alongside the W3C one, so whichever header arrives is honoured. This is a configuration detail with an outsized consequence, and it is the first thing to verify when a trace appears to begin at the application rather than at the edge.

API Gateway access logs are configured to emit `$context.requestId`, `$context.extendedRequestId`, `$context.xrayTraceId` and the inbound `traceparent`, which gives every log line a join to both trace systems.

### 3.3 Application to database

Traces stop at the database client. The span records `db.statement` and duration, and Aurora's own view of the query lives separately in Performance Insights, with no shared identifier.

The join is made with **sqlcommenter-style SQL comments**. The application appends the trace id as a comment on each statement. The comment travels into `pg_stat_statements` and into Performance Insights, so a slow query identified in Performance Insights can be traced back to the exact customer request that issued it, and a slow trace can be followed forward into the database's own analysis of the statement.

The cost is noted honestly: comments alter the statement text, which affects query plan caching behaviour and inflates `pg_stat_statements` cardinality unless the comment is normalised. This is a deliberate trade and it is worth it, because "the database was slow" without the ability to name which request made it slow is where latency incidents stall.

### 3.4 The asynchronous hop

CUJ-4 accepts the transaction and CUJ-5 settles it, potentially minutes later. Treating this as one continuous parent-child trace produces traces that stay open for minutes, break trace-duration assumptions and are unusable in a trace viewer.

The correct modelling is a **span link**. The submit trace completes when the transaction is durable. The settlement consumer starts a new trace and declares a link to the submit trace, carrying `transaction.id` as the business join key. The `traceparent` is injected into the Kafka record headers on `msk-tier1-use1` so the link can be established.

The operational payoff is specific. When a customer asks why a transaction is still pending, the answer is reachable from `transaction.id` through the link to both the acceptance trace and every settlement attempt, including the ones that failed and retried.

## 4. Service map

| Tool | Role |
|---|---|
| CloudWatch Application Signals | Primary service map. Auto-discovers services on EKS via the CloudWatch Observability add-on, computes per-operation availability and latency, and hosts the SLO definitions with burn-rate tracking natively. |
| X-Ray trace map | Request-level topology for individual traces during diagnosis |
| Amazon Managed Grafana over Amazon Managed Service for Prometheus | Mesh, node and Kubernetes views, and the Istio dashboards that back the resilience controls in section 03 |

**External providers must be explicitly instrumented as downstream subsegments or they will not appear on the map at all.** This matters more than it sounds. The brief identifies external dependencies as a primary concern, and an automatically discovered service map shows only what the instrumentation reports. A provider call made through a plain HTTP client appears as unattributed latency inside the calling service, which presents during an incident as "our service is slow" when the truth is "their service is slow." Calls to `ext-payments` and `ext-idp` are wrapped so they emit their own spans with `peer.service` set, which puts them on the map as distinct nodes with their own error and latency statistics.

## 5. Synthetic checks

CloudWatch Synthetics canaries, one per journey, running from **both** regions at 1-minute frequency.

| Canary | Journey | Asserts |
|---|---|---|
| `syn-cuj1-signin` | CUJ-1 | Full OIDC flow against `ext-idp`, browser-based, session issued |
| `syn-cuj2-validate` | CUJ-2 | Authenticated API call with a pre-provisioned token, 200 and correct body |
| `syn-cuj3-account` | CUJ-3 | Account view API and page render within the latency objective |
| `syn-cuj4-submit` | CUJ-4 | Submit returns 202, then read back the transaction to prove durability |
| `syn-cuj5-settle` | CUJ-5 | The transaction from `syn-cuj4-submit` reaches a terminal state within 15 minutes |
| `syn-ext-payments` | Dependency | Provider health endpoint plus a real sandbox call, because health endpoints lie |
| `syn-ext-idp` | Dependency | JWKS endpoint availability and token issuance |

Four design points carry real weight.

**The recovery-region canaries are the answer to "DR has never been exercised."** They run continuously against `apigw-tier1-usw2` and prove the standby path serves traffic today, not that it served traffic when it was built. A standby validated only during an annual test is a standby whose breakage is discovered during an incident. This is the cheapest control in the entire submission and it closes the largest stated gap.

**`syn-cuj4-submit` writes to production, which demands a designated synthetic tenant.** Transactions from that tenant are excluded from the reconciliation in SLI-7, from business metrics and from financial reporting, and that exclusion is itself tested. For a bank this is not a detail. A synthetic transaction that reaches a real settlement rail or a real financial report is a worse incident than the outage the canary was built to detect.

**`syn-cuj5-settle` is the only check that can detect a stalled settlement pipeline before customers do.** A single stalled MSK partition leaves the service's availability metrics perfect while a subset of customers waits indefinitely.

**Canaries probe from inside AWS and therefore cannot see the path from the customer's ISP to CloudFront.** That gap is real and it is closed by CloudWatch RUM, which reports from actual browsers: page load, JavaScript errors, API failure rates and geographic distribution. RUM also detects the failure class that no server-side signal can see at all, which is a broken client release that stops requests ever being sent.

## 6. Business signals

Emitted with the **Embedded Metric Format**. EMF writes a structured log line that CloudWatch extracts metrics from, so the application makes no additional API call. This matters for a reason beyond convenience: a `PutMetricData` call on the request path is a synchronous dependency that can fail, add latency, or be throttled, and instrumentation that can take down the service it measures is a poor trade.

| Business metric | Detects |
|---|---|
| Transactions accepted per minute | The failure no technical metric sees, see below |
| Transaction value per minute | Disproportionate impact, where few customers fail but they are the large ones |
| Settlement completion rate and acceptance-to-terminal latency | CUJ-5 freshness, provider degradation |
| Pending transaction count and oldest pending age | A stalled pipeline, a latched-open circuit breaker, a filling DLQ |
| Sign-in success rate, split by new session and refresh | Separates `ext-idp` failure from session-handling failure |
| Duplicate submits caught by idempotency key | Client-side retry storms, early |
| Reconciliation mismatch count | SLI-7 correctness, which availability monitoring cannot see |

**The first row is the single most valuable signal in this design.** A sharp drop in accepted transactions while every technical metric is green means requests are not arriving. The causes are a broken mobile release, a bad front-end deploy, a DNS failure, a certificate problem on a client platform, or an upstream partner outage. No server-side metric detects any of them, because the server is healthy and idle. For a Tier 1 service this is a large and under-monitored class of customer-impacting failure.

Transaction rate has strong daily and weekly seasonality, so a static threshold either fires every night or never fires at all. **CloudWatch anomaly detection** is used, with the alarm set on the band rather than on an absolute value.

## 7. Retention

Tiered by the question each tier answers, not by a single blanket policy.

| Tier | Store | Retention | Answers |
|---|---|---|---|
| Hot | CloudWatch Logs, Standard class | 30 days | Live incident diagnosis |
| Hot | X-Ray traces | 30 days, fixed | Live incident diagnosis |
| Hot | Amazon Managed Service for Prometheus | 150 days | Mesh and Kubernetes trend analysis |
| Warm | S3, Parquet via Kinesis Data Firehose with dynamic partitioning | 13 months | Post-incident analysis, capacity planning, year-on-year comparison, queried with Athena |
| Cold | S3 Glacier | Per the institution's records policy, commonly 7 years for financial records | Audit, regulatory enquiry, dispute resolution |
| Evidence | S3 with Object Lock, separate account | Longer than the review cycle and any plausible dispute | Incident evidence per section 05.7, immutable |

### 7.1 Two retention limits that will surprise people during an incident review

**CloudWatch metric resolution degrades with age.** One-minute datapoints are retained for 15 days, five-minute for 63 days, and one-hour for 455 days. A post-incident review conducted more than 15 days after the event cannot see the one-minute resolution that showed a brief saturation spike, because that detail no longer exists. This is the specific reason section 05 requires evidence capture **during** the incident, and the reason the warm tier exists.

**X-Ray's 30-day trace retention is not configurable.** Any trace needed beyond 30 days, which includes anything attached to a dispute or a regulatory enquiry, must be exported into the evidence store while it still exists.

### 7.2 Cost control

CloudWatch Logs ingestion is normally the dominant observability cost, and an unmanaged telemetry build for a Tier 1 service becomes a visible line item quickly. Four controls, in order of yield:

1. **Log level discipline.** INFO in production, DEBUG enabled per-service on demand and auto-reverted. Debug logging left on after an incident is the most common cause of a cost surprise.
2. **Success-path sampling.** Full logging for errors, sampled logging for successful requests. The hundred-thousandth successful request adds nothing.
3. **Infrequent Access log class** for verbose logs that are kept for completeness and rarely queried interactively.
4. **Firehose direct to S3** for archival-only logs, bypassing CloudWatch Logs ingestion entirely.

The honest trade-off: every one of these reduces what is available at the moment an incident starts. The resolution is to make the distinction by signal value and not by volume. Journey-scoped signals and anything touching money are never sampled. Verbose component logs are.

## 8. Alert routing

### 8.1 Taxonomy

Three destinations and one rule.

| Class | Destination | Rule |
|---|---|---|
| **Page** | On-call, 24x7 | Journey-level symptom alerts only. A human must be able to do something now, and a customer is affected. |
| **Ticket** | Team backlog, business hours | Slow-burn budget consumption, capacity trends, approaching quotas, degraded redundancy |
| **Dashboard** | No notification | All cause-level signals |

Every page carries the severity from section 05, so the alert that wakes someone already states what it is.

### 8.2 Burn-rate alerting

Multi-window, multi-burn-rate alarms on each journey SLI. The long window detects real budget consumption, the short window confirms the condition is still true, which is what stops an alert firing on an event that has already resolved.

| Burn rate | Long window | Short window | Budget consumed if sustained | Action |
|---|---|---|---|---|
| 14.4x | 1 hour | 5 minutes | 2 percent | **Page**, Sev1 |
| 6x | 6 hours | 30 minutes | 5 percent | **Page**, Sev2 |
| 3x | 1 day | 2 hours | 10 percent | Ticket |
| 1x | 3 days | 6 hours | 10 percent | Ticket |

Implemented as CloudWatch composite alarms, with the SLI ratio computed by metric math over API Gateway and CloudFront metrics. CloudWatch Application Signals computes burn rate natively for services it discovers, and is used where the journey maps cleanly onto a discovered service. The metric-math implementation is in [`slo/burn-rate-alarms.tf`](slo/burn-rate-alarms.tf) and covers the journeys that span multiple services, which Application Signals does not compose on its own.

### 8.3 The fast path, because burn-rate alerting is too slow for a total outage

Burn-rate windows are tuned to protect a budget over time. They are not tuned to detect a service that has just stopped. A one-hour window with a five-minute confirmation window is appropriate for a slow bleed and too slow for a Tier 1 banking journey that is fully down.

A separate **hard-down** alarm therefore runs in parallel on each scored journey: journey availability below 95 percent over two consecutive one-minute periods pages immediately at Sev1. It is deliberately crude. It exists to be fast, and it fires long before any burn-rate window closes.

This pairing matters for the stated problem. Slow detection is not fixed by better burn-rate tuning, because burn-rate alerting is structurally slow for catastrophic failure. It is fixed by having both.

### 8.4 Noise suppression

The brief's "many alerts" is addressed structurally by section 8.1 and mechanically here.

**Composite alarms with suppressor alarms.** When the AZ-level alarm is in ALARM, the pod, node and service alarms downstream of it are suppressed. One AZ failure then produces one alert instead of forty. This is the single highest-yield noise control available in CloudWatch and it is usually unconfigured.

**Dependency-aware suppression.** When `syn-ext-payments` is failing, settlement-pipeline alarms are suppressed, because they are the expected and correct consequence of a dependency being down. The circuit-breaker state alarm still fires, because that is the signal that says the service is responding properly to the condition.

**Alert dispositioning.** Every page is marked actionable or not actionable at resolution. The resulting precision figure is a tracked metric in section 06.5. Without this measurement, alert quality is an opinion, and alert cleanup becomes an argument between people with different recollections of 03:00.

### 8.5 Routing path

```
CloudWatch alarm
  -> EventBridge rule, matched on severity and journey
    -> SNS topic per severity
      -> AWS Systems Manager Incident Manager response plan
        -> engagement, escalation per section 05.6, and an incident record
```

Incident Manager is selected over an external paging tool as the primary path because it keeps the response plan, the engagement ladder and the incident record inside the account boundary, with CloudWatch and runbook integration, which is the easier position to defend to a financial regulator. Where an institution already runs an external paging tool, SNS fans out to both and Incident Manager remains the system of record.

**AWS Health events are routed into the same pipeline via EventBridge.** This is not optional for a service with a 45-minute RTO. A regional AWS service event frequently appears on the AWS Health Dashboard before the service's own metrics degrade unambiguously, and in a regional recovery decision the difference between "our service is broken" and "AWS has a regional problem" determines whether failover is the right response. Section 04 uses this signal in the failover decision tree.

## 9. Detection time budget

The brief's core symptom restated as a number, per journey, with the mechanism that achieves it.

| Journey | Target detection | Mechanism | Measured |
|---|---|---|---|
| CUJ-2, CUJ-3, CUJ-4 hard down | **Under 2 minutes** | Hard-down alarm, 1-minute metrics, 2 evaluation periods, plus 1-minute canaries from two regions | Quarterly by injection |
| CUJ-2, CUJ-3, CUJ-4 degraded | Under 10 minutes | 14.4x burn-rate alarm with a 5-minute short window | Quarterly by injection |
| CUJ-5 settlement stall | Under 15 minutes | `syn-cuj5-settle`, plus `MaxOffsetLag` per partition | Quarterly by injection |
| External provider degradation | Under 3 minutes | Provider canaries plus circuit-breaker state change events | Game day |
| Correctness mismatch | Under 24 hours | Daily reconciliation, alarmed on any non-zero mismatch | Monthly |
| Silent client-side failure | Under 10 minutes | Transaction-rate anomaly detection, CloudWatch RUM | Quarterly |

**Detection time is itself measured by injection, not asserted.** A detection target that has never been tested against an induced failure is a design intention. Section 06 makes a measured detection time the exit criterion for the first 30-day block, and section 04's game-day design provides the injection mechanism.

### 9.1 Driving detection below one minute, if required

The 2-minute target is bounded by one-minute metric resolution plus alarm evaluation. If the business requires faster, the path is CloudFront real-time logs to Kinesis Data Streams, a consumer computing a high-resolution custom metric at 10-second storage resolution, and a high-resolution alarm with a 30-second period, which brings detection to roughly 60 to 90 seconds.

This is recorded as available and **not recommended for day one**. It adds a streaming pipeline to the detection path, which means the detection mechanism acquires its own failure modes and its own on-call burden. The correct sequence is to reach a reliable 2 minutes first, measure how much of the 45-minute RTO detection actually consumes, and buy the extra minute only if the measurement says it is the binding constraint. On the decomposition in section 04 it is not.
