# 01. Service reliability model

Weight: 20 percent. Selected cloud: **Amazon Web Services**.

This section maps the critical user journeys, their dependencies, their failure modes, the SLIs and SLOs that measure them, the error budgets that govern them, and who owns each part. It is the foundation the other five sections reference.

## 1. Reference architecture and naming

Every name used here is used identically in the diagram, the runbooks and the configuration files. The suffix `-use1` denotes the primary region, `us-east-1`. The suffix `-usw2` denotes the recovery region, `us-west-2`.

| Layer | AWS service | Resource name | Failure domain |
|---|---|---|---|
| Edge | CloudFront | `cf-tier1-dist` | Global, AWS-managed PoP mesh |
| Edge security | AWS WAF (CLOUDFRONT scope) | `waf-tier1-edge` | Global |
| DNS and traffic control | Route 53 + Application Recovery Controller | `r53-tier1-zone`, `arc-tier1-cluster` | Global, 5 regional endpoints |
| API | API Gateway REST | `apigw-tier1-use1` / `-usw2` | Regional |
| Compute | EKS | `eks-tier1-use1` / `-usw2` | Regional, node groups per AZ |
| Service mesh | Istio on EKS | `mesh-tier1` | Regional |
| Streaming | MSK Provisioned + MSK Replicator | `msk-tier1-use1` / `-usw2`, `mskrep-tier1` | Regional, brokers per AZ |
| Relational data | Aurora PostgreSQL Global Database | `aur-tier1-global`, writer `aur-tier1-use1` | Regional cluster, AZ-level instances |
| Connection pooling | RDS Proxy | `rdsproxy-tier1-use1` / `-usw2` | Regional |
| Idempotency store | DynamoDB Global Table | `ddb-tier1-idempotency` | Multi-region active-active |
| Async buffer | SQS + DLQ | `sqs-tier1-settlement`, `sqs-tier1-settlement-dlq` | Regional |
| External | Payment and settlement provider | `ext-payments` | Outside all trust boundaries |
| External | Identity provider, OIDC | `ext-idp` | Outside all trust boundaries |

Two components are additions to the stated stack and are justified rather than assumed. **RDS Proxy** exists because Aurora writer failover without it exposes raw connection churn to the application, and connection storms on recovery were a plausible contributor to the stated retry incidents. **DynamoDB Global Table** exists because idempotency state must survive the loss of the region whose failure makes replay necessary, and storing idempotency keys in the same Aurora cluster being recovered defeats their purpose.

## 2. Critical user journeys

A journey is scored only if it has a customer-observable success condition, a measurement point outside the application, and a named owner. Five journeys are in scope. Four are scored against the 99.99 percent target. One is governed by a freshness SLO because it has no synchronous customer interaction.

| ID | Journey | Customer-observable success | Scored at 99.99 | Tier |
|---|---|---|---|---|
| **CUJ-1** | Establish session, meaning first sign-in | Customer receives a valid session and reaches the authenticated landing view | No, see 2.1 | 1 |
| **CUJ-2** | Validate session, meaning every authenticated request | Request is authorised without re-prompting the customer | Yes | 1 |
| **CUJ-3** | View account and transaction history | Customer sees their current data within the latency objective | Yes | 1 |
| **CUJ-4** | Submit transaction | Transaction is durably accepted and acknowledged | Yes | 1 |
| **CUJ-5** | Settle transaction with the external provider | Transaction reaches a terminal state and the customer sees it | Freshness SLO, see 2.2 | 1 |

### 2.1 Why CUJ-1 is split from CUJ-2, and why only CUJ-2 is scored

Section 00 established that an external provider on the synchronous critical path caps the journey at 99.79 percent. The identity provider cannot be made asynchronous, because a customer signing in needs an answer now. The resolution is to split the journey at the point where the dependency actually bites.

- **CUJ-1, first sign-in**, calls `ext-idp` synchronously. It is governed by its own SLO of 99.9 percent, which is the honest ceiling given the dependency. It is reported separately and has its own error budget.
- **CUJ-2, session validation**, does not call `ext-idp` at all. Tokens are validated locally against a JWKS document cached in the pod with a 24-hour soft TTL and a stale-while-revalidate refresh. Session lifetime is 12 hours with sliding refresh. An `ext-idp` outage therefore stops new sign-ins and does not touch any customer already signed in.

The design consequence is measurable and is the point of the split. With a 12-hour session lifetime, a one-hour identity provider outage at a typical daily login distribution affects the minority of customers who need a new session during that hour, not the entire active user base. The arithmetic ceiling problem is not argued away, it is moved to a smaller journey with an honest target.

**This is a product decision, not purely a technical one.** A 12-hour session reduces the blast radius of identity provider failure and increases the window in which a revoked credential remains usable. The security position is stated in section 4.4. It belongs to the service owner and the security function jointly, and this submission records it as a recommendation rather than a decided fact.

### 2.2 Why CUJ-4 and CUJ-5 are separated

This is the single most consequential decision in the model.

The naive design calls `ext-payments` synchronously inside the submit request and returns the settled result. That makes the payment provider a hard dependency of a scored journey, which section 00 showed caps the achievable availability at 99.79 percent. It is also precisely the shape that produces retry storms, because a slow provider holds request threads open while clients retry.

The design here accepts the transaction durably and settles it asynchronously:

1. The submit request writes the transaction to `aur-tier1-use1` with status `ACCEPTED`, records the idempotency key in `ddb-tier1-idempotency`, and emits an event to `msk-tier1-use1`.
2. The API returns `202 Accepted` with a transaction identifier and a status endpoint.
3. A consumer reads from MSK, calls `ext-payments`, and advances the transaction to a terminal state. Failures retry with backoff against `sqs-tier1-settlement` and land in `sqs-tier1-settlement-dlq` after exhaustion.

**CUJ-4 therefore succeeds when the transaction is durable, not when the money moves.** Its availability depends only on CloudFront, API Gateway, EKS, Aurora and DynamoDB, all of which are inside the trust boundary and all of which can be engineered to 99.99 percent.

The cost of this decision is explicit and must be stated to the business rather than buried. The customer no longer receives an immediate settled confirmation. The product has to be designed around a pending state, and the external provider's failure becomes a settlement latency problem instead of an availability problem. That is a better problem to have, and it is still a real one, which is why CUJ-5 carries a freshness SLO.

Where a product genuinely requires synchronous confirmation, for example a card authorisation at the point of purchase, the honest position is that the journey cannot be 99.99 percent and must carry its own lower target. Claiming otherwise would be arithmetic the provider's own SLA does not support.

## 3. Dependency map and criticality

Dependencies are classified by what happens to the journey when they fail. The classification drives which resilience control in section 03 applies.

**Hard**: the journey fails. **Soft**: the journey degrades but still satisfies its success condition. **Async**: no journey impact, settlement is delayed.

| Journey | Dependency | Class | Behaviour on failure | Control |
|---|---|---|---|---|
| CUJ-2, 3, 4 | `cf-tier1-dist` | Hard | Total loss. Mitigated by CloudFront's own global redundancy. | Origin failover group, custom error responses |
| CUJ-2, 3, 4 | `apigw-tier1-use1` | Hard | Regional loss, triggers regional recovery | Regional redundancy, ARC traffic shift |
| CUJ-2, 3, 4 | `eks-tier1-use1` | Hard | Regional loss if all AZs affected, degraded if one AZ | Multi-AZ node groups, PDBs, over-provisioning |
| CUJ-3 | `aur-tier1-use1` reader | Soft | Reads fall back to the writer endpoint with a reduced concurrency cap | Reader endpoint plus writer fallback |
| CUJ-4 | `aur-tier1-use1` writer | Hard | Submits fail. Writer failover is 30 to 60 seconds behind RDS Proxy. | RDS Proxy, retry with idempotency key |
| CUJ-4 | `ddb-tier1-idempotency` | Hard | Fail closed. A submit without idempotency protection is not accepted. | Global Table, two-region availability |
| CUJ-4 | `msk-tier1-use1` | Soft | Transaction is accepted and the event is written to a transactional outbox in Aurora for later publication | Outbox pattern, see 3.1 |
| CUJ-5 | `ext-payments` | Async | Settlement delayed. Customer-visible as a pending transaction. | Circuit breaker, DLQ, replay |
| CUJ-1 | `ext-idp` | Hard for CUJ-1 only | New sign-ins fail. Existing sessions unaffected. | JWKS cache, 12-hour sessions |
| CUJ-2 | `ext-idp` | None | No runtime call | Local JWKS validation |

### 3.1 The outbox is why MSK is soft rather than hard

If the submit path wrote to Aurora and then published to MSK, an MSK failure between the two would leave a durable transaction that no consumer ever settles. Making the publish synchronous and mandatory would instead make MSK a hard dependency of CUJ-4, which adds a regional failure mode to the service's most important journey.

The transactional outbox resolves both. The submit writes the transaction and the outbox row in one Aurora transaction. A separate relay publishes outbox rows to MSK and marks them published. An MSK outage delays settlement and loses nothing, and CUJ-4 stays available. The cost is a relay to operate and at-least-once delivery semantics, which is why consumers are idempotent by contract in section 03.

## 4. Failure modes

Derived from the architecture and from the three symptoms stated in the brief. Detection source is named for each, because a failure mode with no detection source is the actual problem this service has.

### 4.1 Edge and API

| Failure mode | Effect | Detection source |
|---|---|---|
| Origin unreachable from CloudFront | Total journey loss | CloudFront `5xxErrorRate`, `OriginLatency`, origin failover events |
| ACM certificate expiry | Total journey loss, no gradual onset | ACM `DaysToExpiry` metric, alarm at 30 days |
| API Gateway account throttle, 10,000 RPS steady and 5,000 burst by default | Blanket 429s across all journeys | API Gateway `Count` against quota, `4XXError` |
| Integration timeout at the 29-second REST API ceiling | 504 to the customer after a long wait, the worst customer experience of any failure mode | API Gateway `IntegrationLatency` p99, `5XXError` |
| WAF rule false positive after a managed rule set update | Legitimate traffic blocked, often for a subset | WAF `BlockedRequests` by rule, sudden change in blocked ratio |
| Authorizer failure or JWKS fetch failure | All authenticated requests fail | API Gateway `4XXError`, authorizer latency, JWKS fetch metric |

### 4.2 Compute

| Failure mode | Effect | Detection source |
|---|---|---|
| Single AZ loss | Capacity reduced by up to one third, latency rises if remaining capacity is tight | Container Insights node count by AZ, pod pending count |
| CoreDNS saturation | Intermittent resolution failure across every service, presents as random unrelated errors | CoreDNS request duration and error metrics via Prometheus, `coredns_dns_responses_total` by rcode |
| HPA scale-up lag behind a traffic spike | Latency rise then saturation then error | HPA current versus desired replicas, pod pending duration |
| Node provisioning delay | Pods pending, capacity never arrives | Karpenter or Cluster Autoscaler events, pod pending duration |
| Connection pool exhaustion against Aurora | Request queueing then timeout, the classic retry-storm amplifier | Application pool gauge, RDS Proxy `DatabaseConnectionsBorrowLatency` |
| Deployment of a bad build | Error rate step change correlated to rollout | Application Signals error rate by deployment label |
| Secret or IRSA credential expiry | Sudden total failure of one service with no traffic change | Application error rate, STS and Secrets Manager errors |

### 4.3 Data and streaming

| Failure mode | Effect | Detection source |
|---|---|---|
| Aurora writer failover | 30 to 60 seconds of write unavailability behind RDS Proxy | RDS events, `DatabaseConnections` discontinuity, write error rate |
| Aurora reader replica lag | Stale reads on CUJ-3, customers see their own write missing | `AuroraReplicaLag` |
| Aurora Global Database replication lag | RPO exposure grows silently with no customer-visible symptom until recovery | `AuroraGlobalDBRPOLag`, `AuroraGlobalDBReplicationLag` |
| Long-running transaction blocking DDL or vacuum | Gradual degradation, often during deploys | Performance Insights top SQL, blocked sessions |
| MSK broker loss | Partition leader election, brief produce failures | MSK `ActiveControllerCount`, `OfflinePartitionsCount`, `UnderReplicatedPartitions` |
| MSK consumer lag growth | Settlement falls behind, CUJ-5 freshness breaches before anything alarms | `SumOffsetLag`, `EstimatedMaxTimeLag` per consumer group |
| Poison message in a partition | One partition stalls, lag grows on that partition only, total lag may look acceptable | `MaxOffsetLag` per partition, not the sum |
| MSK storage full | Produce failures, broker degradation | `KafkaDataLogsDiskUsed`, storage autoscaling events |

The poison-message row is why section 02 alerts on `MaxOffsetLag` per partition rather than `SumOffsetLag` alone. A single stalled partition out of thirty is invisible in a sum and is a complete settlement outage for every customer whose key hashes to it.

### 4.4 External providers

| Failure mode | Effect | Detection source |
|---|---|---|
| Provider hard down, fast failure | Settlement stops, circuit opens quickly, queue absorbs | Synthetics canary against the provider, circuit breaker state metric |
| **Provider slow but up** | **The worst case. Connections held, pools exhausted, retries pile up, failure propagates inward from a dependency that never returns an error.** | Outlier detection ejection rate, p99 call latency, pool saturation |
| Provider rate-limits the service | Partial settlement failure, often after a recovery surge | Provider 429 rate, retry count |
| Provider returns success for a request that did not settle | Silent correctness failure, invisible to availability monitoring | Reconciliation job, see section 04 |
| Provider certificate or endpoint rotation | Total provider failure at a time nobody changed anything | TLS handshake error rate, canary |

**The second row is the root cause of the two stated regional incidents.** A provider that returns errors quickly is easy to survive, because the call fails, the circuit opens and the queue absorbs the work. A provider that accepts connections and never responds consumes a thread or a connection per in-flight call, exhausts the pool, and makes every other journey sharing that pool fail. Retries then multiply the load on a dependency that is already failing to keep up. Section 03 treats latency-triggered circuit breaking and pool isolation as the primary fix, and retry budgets as the secondary one.

### 4.5 Cross-cutting

| Failure mode | Effect | Detection source |
|---|---|---|
| Retry storm | Self-inflicted load amplification, the stated incident class | Ratio of attempted to unique requests, retry metric |
| Thundering herd on recovery | A fixed service is immediately knocked over by the backlog | Request rate step change at recovery, queue drain rate |
| Service quota exhaustion | Hard failure at a ceiling nobody was watching | Service Quotas with CloudWatch usage metrics and alarms |
| Configuration change, not code | Behaviour change with no deployment to correlate against | AWS Config change events correlated onto incident timelines |
| Cache stampede on CloudFront invalidation | Origin load spike | Origin request rate, cache hit ratio drop |

## 5. SLI specification

Each SLI states its measurement point, its numerator and denominator, its exclusions and its AWS-native data source. The measurement point matters more than the formula. An SLI measured inside the application cannot observe the failures that prevent requests from reaching the application, which is a large share of the failures that matter.

Machine-readable definitions are in [`slo/slo-spec.yaml`](slo/slo-spec.yaml). The CloudWatch implementation is in [`slo/burn-rate-alarms.tf`](slo/burn-rate-alarms.tf).

### SLI-1: CUJ-2 session validation availability

| Field | Value |
|---|---|
| Measurement point | API Gateway access logs, `apigw-tier1-use1`, authenticated routes |
| Good events | Requests where `$context.status` is not 5xx and not 401 or 403 caused by authorizer failure |
| Valid events | All requests to authenticated routes, excluding client-attributable 4xx |
| Exclusions | 400, 404, 422 and 429 arising from documented client misuse. Explicitly **not excluded**: 429 arising from the service's own throttling, which is a service failure and is counted. |
| Data source | API Gateway access logs to CloudWatch Logs, aggregated by Metric Insights, plus `4XXError` and `5XXError` metrics |

The 429 distinction is deliberate. Throttling a customer because the service cannot cope is unavailability wearing a different status code, and excluding it is the most common way an availability SLI is quietly inflated.

### SLI-2: CUJ-3 account view availability and latency

| Field | Value |
|---|---|
| Measurement point | CloudFront real-time logs for the full customer-observed path |
| Good events, availability | `sc-status` not 5xx and `x-edge-result-type` not `Error` |
| Good events, latency | `time-taken` at or under 1.5 seconds at p95 and 3.0 seconds at p99 |
| Valid events | All requests to the account view route set |
| Exclusions | Client aborts, meaning `x-edge-result-type` of `ClientCommError` |
| Data source | CloudFront real-time logs to Kinesis Data Streams, aggregated to CloudWatch. Standard logs to S3 for Athena backfill and dispute resolution. |

Real-time logs are used rather than standard logs because standard log delivery to S3 is batched with delivery latency measured in minutes. A detection-time objective under two minutes cannot be met from a log source that arrives later than that. This is a cost decision taken deliberately and is recorded in section 02.

### SLI-3: CUJ-4 submit transaction availability

| Field | Value |
|---|---|
| Measurement point | API Gateway access logs, correlated against the Aurora durable write |
| Good events | Requests returning 202 **where the transaction row and the outbox row are both committed** |
| Valid events | All submit requests with a valid idempotency key |
| Exclusions | Duplicate submits deduplicated by idempotency key, counted separately as a correctness signal |
| Data source | API Gateway access logs, plus an EMF business metric emitted by the submit handler on successful commit |

The numerator requires evidence of the durable write rather than only the status code. A 202 returned by a handler that then failed to commit is a false success, and it is exactly the failure an availability SLI built only on HTTP status will report as healthy.

### SLI-4: CUJ-4 submit latency

| Field | Value |
|---|---|
| Measurement point | API Gateway `Latency`, which includes integration latency |
| Objective | p95 at or under 800 ms, p99 at or under 2.0 seconds |
| Data source | API Gateway `Latency` and `IntegrationLatency` metrics at 1-minute resolution |

Both are published because the gap between them isolates API Gateway overhead from backend time, which removes the first ten minutes of argument in a latency incident.

### SLI-5: CUJ-5 settlement freshness

| Field | Value |
|---|---|
| Measurement point | MSK consumer group lag and transaction state transitions |
| Good events | Transactions reaching a terminal state within 15 minutes of acceptance |
| Valid events | All accepted transactions |
| Exclusions | Transactions deliberately held for manual review |
| Data source | MSK `EstimatedMaxTimeLag` per consumer group, plus an EMF metric for acceptance-to-terminal duration |

This is a freshness SLI, not an availability SLI, because CUJ-5 has no synchronous customer interaction. It is the signal that detects a stalled partition, an open circuit breaker that never closed, or a DLQ filling quietly.

### SLI-6: CUJ-1 first sign-in availability

| Field | Value |
|---|---|
| Measurement point | API Gateway access logs on the sign-in route, plus a Synthetics canary executing the full OIDC flow |
| Good events | Sign-in completing with a valid session issued |
| Valid events | All sign-in attempts excluding wrong-credential rejections |
| Exclusions | Genuine authentication failures, which are a success for the system |
| Data source | API Gateway access logs, CloudWatch Synthetics canary success rate, `ext-idp` probe results |

### SLI-7: Correctness, settlement reconciliation

| Field | Value |
|---|---|
| Measurement point | Daily reconciliation of the service's terminal states against the provider's settlement report |
| Good events | Transactions whose internal state matches the provider's record |
| Valid events | All transactions in the reconciliation window |
| Data source | Reconciliation job output, emitted as an EMF metric and alarmed on any non-zero mismatch |

Availability SLIs cannot see correctness failures. A provider that returns success for a settlement that did not occur produces a perfect availability record and a real financial loss. This SLI exists because section 4.4 identified that failure mode and nothing else in the model would catch it.

## 6. SLO targets and error budgets

Targets are differentiated. Applying 99.99 percent to everything is the fastest route to an error budget nobody believes, because the budget is then consumed by journeys the business does not actually consider critical.

| SLI | Journey | Target, 30-day rolling | Error budget | Budget in minutes |
|---|---|---|---|---|
| SLI-1 | CUJ-2 session validation | **99.99 percent** | 0.01 percent | 4.32 min |
| SLI-2 | CUJ-3 account view, availability | **99.99 percent** | 0.01 percent | 4.32 min |
| SLI-2 | CUJ-3 account view, latency p95 ≤ 1.5 s | 99.5 percent | 0.5 percent | n/a, ratio |
| SLI-3 | CUJ-4 submit, availability | **99.99 percent** | 0.01 percent | 4.32 min |
| SLI-4 | CUJ-4 submit, latency p95 ≤ 800 ms | 99.5 percent | 0.5 percent | n/a, ratio |
| SLI-5 | CUJ-5 settlement within 15 min | 99.0 percent | 1.0 percent | n/a, ratio |
| SLI-6 | CUJ-1 first sign-in | 99.9 percent | 0.1 percent | 43.2 min |
| SLI-7 | Settlement correctness | 99.999 percent | 0.001 percent | Alarm on any mismatch |

Three targets deserve their justification stated rather than assumed.

**CUJ-1 at 99.9 percent** is the arithmetic consequence of a synchronous external identity dependency, as established in section 00 and section 2.1. Setting it to 99.99 percent would be setting a target that the provider's own SLA cannot support. A target that is missed through no fault of the team, every month, trains everyone to ignore targets.

**CUJ-5 at 99.0 percent** reflects that settlement is asynchronous by design. A 15-minute freshness objective with a 1 percent budget tolerates provider outages of roughly 7 hours per 30 days before the SLO breaches, which is the point of having moved settlement off the critical path.

**SLI-7 at 99.999 percent** is effectively zero tolerance. Correctness failures in a financial path are not a budget to spend. The target is expressed as a ratio only so it sits in the same framework as the rest.

### 6.1 The disaster clause

Section 00 Finding 1 showed that a 45-minute RTO consumes 10.4 months of a 99.99 percent error budget. This clause is the stated resolution and it is agreed in advance, which is the only time such a clause can honestly be agreed.

1. The Incident Commander may declare a **Regional Disaster Event** when a failure affects an entire AWS region or a regional service the service depends on, and recovery requires the regional failover in section 04.
2. Minutes accrued during a declared Regional Disaster Event are recorded against a separate **disaster budget** of two declared events per 12 months, and are excluded from the 99.99 percent journey SLOs.
3. The exclusion is bounded by the stated RTO. Minutes beyond 45 minutes **do** count against the journey error budget. The clause protects the business decision to accept a 45-minute recovery. It does not protect a recovery that overruns it.
4. The declaration, its timestamp and the measured RTO and RPO are published in the incident record and reviewed at the quarterly reliability steering forum.
5. Game-day failovers are not customer-impacting and do not consume the disaster budget. If a game day does cause customer impact, it is an incident, it is declared, and it counts.

Point 3 is the part that keeps the clause honest. An unbounded disaster exclusion is a blank cheque, and a blank cheque removes the incentive to make recovery fast. The roadmap in section 06 drives toward the Option B active-active posture precisely so this clause becomes unnecessary.

## 7. Ownership

The brief states that teams disagree on who owns reliability work. Disagreement of that kind is almost never resolved by discussion. It is resolved by writing down the answer and attaching consequences, which section 06 does through the error budget policy.

### 7.1 Journey ownership

Every scored journey has exactly one accountable team. Shared ownership of an SLO means nobody is woken up.

| Journey | Accountable | Contributing | Pager |
|---|---|---|---|
| CUJ-1, CUJ-2 | Identity team | Platform, Security | Identity team |
| CUJ-3 | Account team | Platform, Data | Account team |
| CUJ-4 | Transactions team | Platform, Data | Transactions team |
| CUJ-5 | Transactions team | Platform, Integrations | Transactions team |
| SLI-7 correctness | Transactions team | Finance operations | Transactions team, with finance escalation |

### 7.2 Component ownership

| Component | Owner | Pager |
|---|---|---|
| `cf-tier1-dist`, `waf-tier1-edge`, `r53-tier1-zone`, `arc-tier1-cluster` | Platform | Platform |
| `apigw-tier1-*` | Platform owns the gateway, journey teams own their routes | Platform for the gateway, journey team for route-level errors |
| `eks-tier1-*`, `mesh-tier1` | Platform | Platform |
| `msk-tier1-*`, `mskrep-tier1` | Platform owns the cluster, Transactions owns topics and consumer groups | Split, by the metric that fires |
| `aur-tier1-global`, `rdsproxy-tier1-*` | Data | Data |
| `ddb-tier1-idempotency` | Transactions | Transactions |
| Telemetry pipeline, SLO tooling, game-day harness | SRE | SRE |
| Incident command function | SRE | SRE |

The split rows are the ones that cause arguments, so they are resolved by the metric rather than by the component. An MSK broker metric pages Platform. A consumer lag metric pages Transactions. Nobody has to decide at 03:00 whose problem a number is.

### 7.3 What SRE owns, and what it does not

SRE owns the standards, the tooling, the incident command function and the platform capabilities listed above. SRE does not hold the production pager for any journey it does not own the code for. The engagement model, the exit criteria and the error budget policy that enforce this are specified in section 06.4, and they are the mechanism that answers the brief's question about reliability ownership.
