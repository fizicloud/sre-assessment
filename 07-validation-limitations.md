# 07. Validation and known limitations

Selected cloud: **Amazon Web Services**.

Two things are in this section. How every control in the submission would be proven to work, and everything that is unproven, uncertain or accepted as residual risk. The second list is longer than most submissions would make it, which is deliberate. A design whose limitations are not written down has limitations anyway.

## 1. Validation matrix

Each control, how it is proven, and what result counts as a pass. A control validated only by reading the configuration is not validated.

| # | Control | Section | Validation method | Pass criterion |
|---|---|---|---|---|
| V1 | Journey SLIs measure the real customer path | 01.5 | Inject a failure at the edge and confirm the SLI moves | SLI reflects the injected failure within one evaluation period |
| V2 | Detection under 2 minutes | 02.9 | Quarterly induced failure, timed from injection to page | Page delivered under 2 min, measured |
| V3 | Trace spans edge to database | 02.3 | Fetch a trace by `x-amz-cf-id` and confirm it contains the Aurora statement | Single trace covering all hops, no break at the gateway boundary |
| V4 | Alert precision above 80 percent | 02.8.4 | Disposition every page as actionable or not | Rolling 30-day precision above 80 percent |
| V5 | Timeout ladder is strictly descending | 03.2.2 | Automated configuration test in CI comparing each hop against its caller | No hop exceeds its caller's remaining budget |
| V6 | Retry amplification bounded at 6x | 03.3.1 | Game day L2.5, measuring attempted versus unique requests per layer | Amplification at or below 6x under 100 percent dependency failure |
| V7 | Idempotency prevents duplicates | 03.4 | Game day L2.2, replay identical keys during a writer failover | Zero duplicate transactions, identical response body on replay |
| V8 | Circuit breaker detects a **slow** dependency | 03.5.2 | Game day L2.1, inject 20 s latency with 200 responses | Breaker opens within 30 s. **This is the experiment that tests the stated incident cause.** |
| V9 | Bulkheads prevent cross-journey contamination | 03.5.6 | Game day L2.1, observe CUJ-2, 3, 4 during provider degradation | **Zero availability impact on journeys that do not call the provider** |
| V10 | Queues are bounded | 03.6.1 | Load test past the breaking point | Service returns 503 fast rather than collapsing into latency |
| V11 | Load shedding follows priority order | 03.7.2 | Load test above capacity | P3 shed first, P0 last, canaries never shed |
| V12 | Poison message does not stall a partition | 03.8.1 | Game day L2.4 | Partition continues, record lands in DLQ, `MaxOffsetLag` alarm fires |
| V13 | Capacity survives one AZ loss | 03.9.2 | Game day L3, production | No SLO burn, surviving AZs within utilisation ceiling |
| V14 | RPO is continuously known | 04.4.2 | `AuroraGlobalDBRPOLag` time series plus alarm test | Alarm fires at 150 s. RPO answerable for any past timestamp. |
| V15 | Consumer offsets survive region loss | 04.4.5 | Pre-production failover with MSK Replicator | Consumers resume without manual offset translation, no work skipped |
| V16 | Traffic shift works when a control plane is impaired | 04.5.1 | Game day L4, using the ARC data plane endpoints | Routing control flips via at least one of the five cluster endpoints |
| V17 | ARC safety rules block unsafe states | 04.5.3 | Deliberately attempt both-off and fail-into-unready | Both attempts rejected |
| V18 | **Provider egress works from the recovery region** | 04.6 | `syn-ext-payments` and `syn-ext-idp` running continuously from `us-west-2` | Both green continuously. **This is the check that most often turns a successful technical failover into a failed recovery.** |
| V19 | Multi-Region KMS decrypts in the recovery region | 04.6 | Scheduled decrypt probe every 15 min | Probe green continuously |
| V20 | RTO under 45 minutes | 04.1 | **Game day L4, production** | Measured end to end, recorded per phase against budget |
| V21 | Reconciliation identifies all four classes | 04.7.3 | Run reconciliation after every L4, including when zero loss is expected | All classes correctly identified, including a seeded duplicate |
| V22 | Incident command works unrehearsed | 05 | Game day L5, unannounced | Declaration, authority exercised without seeking approval, clean handover |
| V23 | Error budget policy is applied | 06.4.3 | Weekly error budget review | Zero unexplained overrides |
| V24 | SRE is not a dumping ground | 06.5 | Monthly operational review | Zero services where SRE holds the pager but not the code |

### 1.1 The three that matter most

**V8 and V9 together test whether the stated incident can still happen.** Everything else is good practice. If a slow provider still contaminates journeys that do not call it, the design has failed at its primary purpose regardless of how the other twenty-two validations score.

**V20 is the one that converts this submission from a design into evidence.** The brief says DR has never been exercised end to end. Until L4 runs, the 45-minute RTO is an assertion.

## 2. Values that are starting points, not tuned figures

Every number below was chosen to be defensible rather than derived from this service's traffic, because no traffic data was available. Each is calibrated in the first 30 days against observed behaviour. Presenting them as final would be false precision.

| Value | Set to | Calibrate against |
|---|---|---|
| Retry budget | 10 percent of active requests | Observed retry rate at healthy baseline. Set to roughly 3x baseline. |
| `consecutive5xxErrors` | 5 | Observed transient error clustering. Too low ejects on noise, too high is slow. |
| `perTryTimeout` | 1.5 s | p99.9 of the dependency's healthy response time, plus margin |
| `http1MaxPendingRequests` | 50 | Measured queue depth at the knee of the load test curve |
| `maxEjectionPercent` | 50 | Minimum healthy host count that still serves peak |
| Provider pool size | 10 connections per pod | Settlement throughput requirement at peak plus backlog drain |
| Burn-rate windows | 14.4x / 6x / 3x / 1x | Standard multi-window values. Validate against 90 days of historical incident data once available. |
| Hard-down threshold | 95 percent over 2 min | Lowest availability observed during a healthy deployment, so rollouts do not page |
| RPO lag warning and critical | 60 s and 150 s | Observed replication lag distribution. Critical stays at half the objective regardless. |
| Session lifetime | 12 hours | Security review. See limitation L3. |
| Utilisation ceiling | 60 percent | Measured AZ-loss behaviour in game day L3 |
| Trace sampling | 1 to 10 percent of successes, 100 percent of errors | Observability budget against diagnostic need |

**The calibration itself is a block 1 deliverable**, not an afterthought. A threshold that has never been compared against real traffic is the most common source of the alert noise the brief describes.

## 3. Known limitations

Ordered by how much they would change the design if addressed.

### L1. DR has never been exercised, so every recovery number is unproven

Stated in the brief and not resolved by this document. The RTO decomposition in 04.1, the RPO position in 04.4.7 and the dependency validation in 04.6 are all designed rather than measured. Game day L4 is the only thing that changes this, and it sits in block 3.

**Consequence:** nothing in section 04 should be reported to a regulator or a customer as a demonstrated capability until L4 has run.

### L2. The RTO buffer is 5 minutes and that is thin

The decomposition in 04.1 allocates 40 minutes across six phases and leaves 5. One unanticipated step consumes it. The honest mitigation is the active-active transition in 06.6, not a more optimistic decomposition.

### L3. A 12-hour session lifetime extends the credential revocation window

Section 01.2.1 splits sign-in from session validation and uses 12-hour sessions so that an identity provider outage does not affect customers who are already signed in. The cost is that a revoked credential or a terminated employee's session remains usable for up to 12 hours unless actively invalidated.

**This is a security and product decision, not an SRE one.** It is recorded as a recommendation. Mitigation if the window is unacceptable: a short-lived access token with a longer refresh token, where refresh validates against a local revocation list rather than against the provider. That preserves most of the availability benefit at the cost of additional complexity.

### L4. The DynamoDB Global Table lag window permits a duplicate during failover

Detailed in 03.4.3. Last-writer-wins replication means the same idempotency key could be accepted in both regions within the replication-lag window during a traffic shift. Bounded by three factors, eliminated by none. Caught by reconciliation class 4 in 04.7.3 and reported rather than silently corrected.

**Accepted residual risk.** The alternative, a strongly consistent cross-region store, does not exist without adding a synchronous cross-region dependency to the submit path, which would be a worse trade.

### L5. The post-failover single-region window has no answer

Detailed in 04.4.4. After an unplanned Aurora failover the global cluster is degraded and the former primary requires a full rebuild, which is hours to days for a large dataset. During that window the service has **no cross-region recovery capability** and a second regional event cannot be recovered from.

This is the highest-risk period of the entire incident and it begins after everyone has declared it resolved. It is flagged in the runbook at section 9.3 and raised explicitly at handover and in the executive brief. No design in this submission removes it.

### L6. Game day L4 does not test the unplanned promotion path

L4 uses the managed planned switchover rather than the unplanned failover, because the unplanned path leaves production without cross-region recovery capability for days, per L5. L4 therefore validates detection, decision, authority, traffic shift, dependency validation and the command model, and does **not** produce a true measured RPO, because a planned switchover loses no data by definition.

The unplanned path is exercised in pre-production at L2.2 and modelled from `AuroraGlobalDBRPOLag` telemetry. Stating this is better than claiming an RPO measurement the exercise did not make.

### L7. RPO depends on replication lag at the moment of failure

Monitored and alarmed per 04.4.2, which is the best available answer, and not a guarantee. A correlated event that both degrades replication and fails the region produces an RPO worse than 5 minutes. The alarms bound the risk by making it visible in advance. They cannot prevent it.

### L8. Single-provider concentration risk

The entire design sits on AWS. The brief requires a single provider and forbids mixing, so this is recorded rather than designed around. It is a recognised supervisory concern for financial institutions.

A credible exit position depends on data portability rather than on running a second provider in parallel. Aurora PostgreSQL is a standard engine, MSK is standard Kafka, and EKS is standard Kubernetes, so the application and data tiers are portable in principle. The genuinely provider-specific components are Route 53 ARC, API Gateway and CloudFront, which are the edge and control layers, and they represent the practical replacement cost in an exit scenario. Recording that assessment is more useful than an unfunded multi-cloud ambition, which typically delivers two partially understood platforms instead of one well understood one.

### L9. The BNM RMiT incident notification deadline is not stated

Section 04.9.5 deliberately asserts no notification timeline. Published sources conflict on whether the applicable deadline sits in RMiT, in the business continuity policy document or elsewhere, and figures from 1 hour to 24 hours appear in secondary sources. Quoting a figure that is wrong is worse than noting the gap.

**Action:** confirm against the primary BNM policy document and wire the confirmed timeline into the communications cadence in 05.4. Carried as a block 1 item.

The two RMiT figures that **are** stated, the 240-minute rolling cap and the 120-minute single-incident ceiling, are consistent across sources and corroborated by published enforcement actions. The paragraph reference should still be verified against the current document, since RMiT was revised in late 2025.

### L10. External providers are generic

Assumption A3 names them as a payment provider and an identity provider. Real providers would change the specifics of the fallback design in 00.2.4, the egress validation in 04.6 and the reconciliation interface in 04.7. The method would not change.

### L11. Observability has retention cliffs that affect incident review

From 02.7.1. CloudWatch retains one-minute metric resolution for 15 days, and X-Ray retains traces for 30 days and is not configurable. A review conducted later than those windows cannot see the resolution that showed a brief saturation spike. Mitigated by the evidence capture in 05.7 and the warm tier, and only if capture actually happens during the incident.

### L12. SQL comments for trace correlation have a cost

From 02.3.3. Appending trace identifiers as SQL comments inflates `pg_stat_statements` cardinality and affects plan cache behaviour unless normalised. Accepted deliberately, because a slow query that cannot be attributed to a customer request is where latency incidents stall.

### L13. CloudFront real-time logs are a cost decision

From 02.5 and the SLI-2 definition. Standard log delivery to S3 is batched with delivery latency in minutes, which cannot support a sub-2-minute detection objective. Real-time logs to Kinesis close the gap and carry an ongoing cost. Taken deliberately for scored journeys only.

### L14. No traffic, incident or cost data was available

The largest limitation and the one that shapes every other. Failure modes are derived from the architecture and from the three symptoms in the brief. A real engagement would begin with 12 months of incident history, trace data and the actual pager load, and would almost certainly re-order the backlog in section 06.3.

## 4. What would change with real access

Stated so that the difference between this submission and real engagement work is explicit.

| Available | Would change |
|---|---|
| 12 months of incident history | The Likelihood factor in every backlog score, and probably the top of the list |
| Actual pager load and ticket data | Toil Relief bands, currently estimated |
| Traffic and seasonality profile | Every threshold in section 2, and the capacity model |
| Real provider contracts and SLAs | CUJ-1's 99.9 percent target, the fallback design, the egress validation process |
| Current cost baseline | The cost trade-offs in 02.7.2, 04.5.6 and 03.9.1, which are currently relative rather than quantified |
| Team structure and skills | The ownership matrix in 01.7 and the engagement model in 06.4.1 |
| Whether 99.99 percent is contractual | Assumption A1, and whether Option C in 00.2.3 is viable at all |
