# 03. Resilience engineering

Weight: 20 percent. Selected cloud: **Amazon Web Services**.

## 1. Root cause: why the retry storms happened

The brief states that retry storms caused two regional incidents. Retry storms are not caused by retries. They are caused by retries meeting three other conditions, and fixing retries alone leaves the service exposed.

### 1.1 Multiplicative amplification

Each layer in a call chain that independently retries multiplies the load on every layer below it.

```
Client              3 attempts
API layer           3 attempts
Service layer       3 attempts
Data access layer   3 attempts
                    ----------
Requests reaching the database for one logical customer request:
3 x 3 x 3 x 3 = 81
```

Every layer looks locally reasonable. Three attempts is a defensible default anywhere you look at it in isolation. The system-level consequence is an 81-fold amplification that arrives precisely when the lowest layer is least able to absorb it.

### 1.2 Generous timeouts, quantified with Little's Law

This is the condition that converts a slow dependency into an outage, and it is the one most often left at its default.

Little's Law states that the number of requests in flight equals arrival rate multiplied by residence time.

```
L = lambda x W

At 1,000 requests per second:
  W = 29 s  (API Gateway REST default ceiling)  ->  L = 29,000 concurrent requests
  W = 4 s   (configured)                        ->  L =  4,000 concurrent requests
```

Now apply a finite resource. If a service holds one database connection per in-flight request from a pool of 200:

```
Throughput ceiling = pool size / residence time

  W = 29 s  ->  200 / 29  =   6.9 requests per second
  W = 2 s   ->  200 / 2   = 100.0 requests per second
```

**A dependency that becomes slow rather than failing reduces effective capacity by a factor of fourteen, with no errors reported anywhere.** The service does not crash. It quietly stops being able to serve, while every health check passes and every component reports itself healthy. Clients then time out and retry, which is where the storm begins.

Section 01.4.4 identified "provider slow but up" as the worst external failure mode. This arithmetic is why.

### 1.3 Unbounded queues

A request that cannot be served immediately is queued. If the queue is unbounded, an overload becomes a latency collapse, then a memory exhaustion, then a crash, then a restart that drops every queued request and returns the load to a cold service. Bounded queues convert the same overload into fast, honest rejection.

### 1.4 Synchronised retries

Retries on a fixed schedule with no jitter arrive together. A thousand clients that all back off 1 second and retry produce a one-thousand-request spike one second later, then another, each arriving while the dependency is still recovering from the last.

### 1.5 The fix set

| Condition | Control | Section |
|---|---|---|
| Multiplicative amplification | One retrying layer per segment, plus retry budgets | 3 |
| Generous timeouts | Timeout ladder with deadline propagation | 2 |
| Unbounded queues | Bounded pools and pending-request limits | 6 |
| Synchronised retries | Full jitter | 3 |
| Slow dependency not detected | Per-try timeout as the sensor for circuit breaking | 5 |
| Cross-journey contamination | Bulkhead pool isolation | 5 |

## 2. Timeouts

### 2.1 The rule

Every tier's timeout must be strictly shorter than the remaining budget of its caller. When a callee's timeout exceeds its caller's, the caller abandons a request the callee is still working on. The work is wasted, the resource stays held, and the caller usually retries, which doubles the load.

Timeouts are therefore derived **inward from the customer latency objective**, not outward from each service's default maximum. Defaults are the problem, not the starting point.

### 2.2 The ladder for CUJ-4, submit transaction

Objective from section 01: p95 at or under 800 ms, p99 at or under 2.0 seconds.

| Hop | Component | Default | **Configured** | Why |
|---|---|---|---|---|
| 1 | Client application | varies | **5 s total**, 1 retry | Covers mobile network variance without holding a user |
| 2 | `cf-tier1-dist` origin response timeout | 30 s | **5 s** | The default is 15x the latency objective |
| 3 | `apigw-tier1-use1` integration timeout | 29 s | **4 s** | The default is the single largest contributor to the Little's Law problem above |
| 4 | `mesh-tier1` route timeout | none | **3.5 s** | Istio `VirtualService.http.timeout` |
| 5 | Application handler deadline | none | **3 s** | Enforced in code, derived from the propagated deadline |
| 6 | Aurora via `rdsproxy-tier1-use1` | none | **1.5 s** `statement_timeout` | A statement exceeding this cannot contribute to a 2 s objective |
| 7 | `ddb-tier1-idempotency` | SDK default | **300 ms**, adaptive retry mode | Single-digit-millisecond service, so 300 ms is already generous |

Each value is strictly below the one above it. Hop 3 is the important row. **Leaving API Gateway at its 29-second ceiling for a journey with a 2-second objective is the specific configuration that made the retry storms possible.**

### 2.3 Deadline propagation

A static ladder still wastes work. A request that has already consumed 2.8 seconds of its 3-second budget should not begin a 1.5-second database query that cannot complete in time.

The remaining budget travels with the request in an `x-deadline-ms` header, decremented at each hop. Before any downstream call, the handler checks the remaining budget against the call's expected cost and fails fast if the work cannot complete. Envoy honours `x-envoy-upstream-rq-timeout-ms` for the mesh hop.

The gain is largest exactly when the system is under stress, because that is when the share of requests arriving with an exhausted budget is highest. Fast rejection returns capacity to requests that can still succeed.

### 2.4 The retry-safety consequence

A timeout is not a failure. It is the absence of information. A request that timed out may have completed at the other end, and this is the reason timeouts and idempotency cannot be designed separately. **No timed-out mutating operation may be retried unless it is protected by an idempotency key.** Section 4 is a prerequisite for section 3, not a companion to it.

## 3. Retry budgets

### 3.1 One retrying layer per segment

The amplification in 1.1 is eliminated by designating which layers may retry.

| Layer | Retries | Rationale |
|---|---|---|
| Client application | **Yes**, 1 retry | Closest to the user, best placed to decide whether a retry is worth the wait |
| CloudFront | No | Origin failover only, which is a different mechanism |
| API Gateway | No | No retry on integration failure |
| Mesh, `mesh-tier1` | **Yes**, 2 attempts, budget-capped | Has the health view needed to retry onto a different healthy pod |
| Application to application | No | Relies on the mesh |
| Application to AWS SDK | **Yes**, adaptive mode | SDK retries target AWS services with their own throttle semantics |
| Settlement consumer to `ext-payments` | **Yes**, asynchronous with backoff | Off the customer path, so retry is cheap and correct |

```
Maximum amplification: 2 (client) x 3 (mesh attempts) = 6
Previously:            3 x 3 x 3 x 3 = 81
```

### 3.2 Budgets rather than counts

A retry count is a per-request limit and provides no system-level protection: ten thousand clients each retrying twice is still twenty thousand extra requests arriving at a dependency that is already failing. A retry **budget** caps retries as a proportion of live traffic, so retries shrink automatically as failures spread.

| Mechanism | Setting |
|---|---|
| Istio `DestinationRule.trafficPolicy.connectionPool.http.maxRetries` | Absolute cap on concurrent retries per cluster. Baseline control. |
| Envoy `retry_budget` via `EnvoyFilter` | Retries limited to **10 percent** of active requests. The percentage control Istio does not expose natively. |
| AWS SDK `AWS_RETRY_MODE=adaptive` | Client-side rate limiter with a token bucket that reduces the retry rate when throttling is observed. Purpose-built to prevent retry storms against AWS services. |

The 10 percent figure is a starting point, calibrated in the first 30 days per section 07.

### 3.3 What may be retried

| Condition | Retry | Note |
|---|---|---|
| Connection failure, connection reset | Yes | Request almost certainly never arrived |
| 502, 503, 504 | Yes | Only with an idempotency key for mutating operations |
| 429 | Yes, **honouring `Retry-After`** | Retrying a throttle without honouring the hint amplifies the overload that caused it |
| Timeout on a mutating operation | **Only** with an idempotency key | See 2.4 |
| 400, 401, 403, 404, 409, 422 | **Never** | Deterministic. A retry will fail identically and costs the dependency real work. |

### 3.4 Full jitter

```
delay = random_between(0, min(cap, base * 2^attempt))
```

Full jitter rather than equal jitter or plain exponential backoff. Plain backoff preserves the synchronisation that caused the herd. Full jitter spreads retries across the entire interval, which is what actually breaks the pattern described in 1.4.

Configuration: `base` 100 ms, `cap` 20 s for asynchronous settlement, `cap` 2 s on the customer path.

## 4. Idempotency

### 4.1 Contract

Every mutating endpoint requires an `Idempotency-Key` header. Requests without one are rejected with 400. This is a hard requirement rather than an option, because an optional idempotency key is absent exactly when a client is written carelessly, which is also when it retries most aggressively.

### 4.2 Implementation

State in `ddb-tier1-idempotency`, a DynamoDB Global Table.

| Field | Purpose |
|---|---|
| `pk` | Hash of tenant plus idempotency key |
| `state` | `IN_PROGRESS` or `COMPLETED` |
| `response_body`, `response_status` | The stored response, replayed verbatim on a duplicate |
| `transaction_id` | Join to the business record |
| `ttl` | 24 hours, sufficient to cover any client retry window |

Flow:

1. Conditional `PutItem` with `attribute_not_exists(pk)`, writing `IN_PROGRESS`.
2. On condition failure with `state = COMPLETED`, return the stored response with the original status. The replay is indistinguishable from the first call, which is the entire point.
3. On condition failure with `state = IN_PROGRESS`, return 409 with `Retry-After`. The first request is still running and the client must not start a second one.
4. On success, perform the work and update to `COMPLETED` with the response.

Returning the **same body**, not merely the same status, is what makes a client's retry safe. A duplicate submit that returns a different transaction identifier has already caused the double-processing the key was meant to prevent.

### 4.3 Why DynamoDB and not Aurora

Idempotency state must survive the loss of the region whose failure makes replay necessary. Storing idempotency keys in `aur-tier1-use1` means that during the regional recovery in section 04, the store that would prevent duplicate processing is the store that is unavailable. A Global Table is active-active across both regions and is reachable throughout.

**The honest limitation.** DynamoDB Global Tables replicate asynchronously with last-writer-wins conflict resolution. During a failover, a replication-lag window exists in which the same idempotency key could be accepted in both regions. Three things bound the risk, and none of them eliminates it:

1. Traffic shift is not instantaneous, so simultaneous writes to the same key in both regions require a client retrying across the shift boundary within the lag window.
2. The transaction identifier is client-generated, so duplicates remain detectable after the fact.
3. The reconciliation in section 04.7 is specifically designed to catch duplicates created during a failover.

This is a residual risk that is accepted and recorded in section 07, not a solved problem. Claiming otherwise would misrepresent how Global Tables behave.

### 4.4 Idempotency downstream

| Boundary | Mechanism |
|---|---|
| Settlement consumer | MSK and SQS are at-least-once. Consumers are idempotent by contract, keyed on `transaction_id`. |
| `ext-payments` | The transaction identifier is sent as the provider's own idempotency key, so provider-side deduplication backs the service's own. |
| Outbox relay | Publishes at least once, marks published after acknowledgement. A crash between the two republishes, which consumers absorb. |

## 5. Circuit breaking

### 5.1 The problem with circuit breakers and slow dependencies

Envoy outlier detection, which is what Istio configures, ejects hosts on consecutive 5xx errors, consecutive gateway errors and success-rate deviation. **None of these detect a dependency that is slow but returning 200.**

This is the gap that matters here, because section 01.4.4 established that slow-but-up is the worst external failure mode and the likely cause of the stated incidents. A circuit breaker configured only on error signals will watch the service collapse without ever opening.

### 5.2 The per-try timeout is the sensor

The resolution is that timeouts and circuit breaking are not independent controls. **The per-try timeout is what converts slowness into an error the circuit breaker can see.** When a call exceeds `perTryTimeout`, Envoy records a local-origin failure and returns 504, which then counts toward consecutive-error ejection.

This makes the ordering explicit: without a tight per-try timeout, outlier detection cannot protect against a slow dependency at all. Tuning the circuit breaker while leaving the timeout at a default is a common and ineffective combination.

### 5.3 Mesh configuration

Full configuration in [`config/istio-outlier-detection.yaml`](config/istio-outlier-detection.yaml).

| Setting | Value | Reason |
|---|---|---|
| `consecutive5xxErrors` | 5 | Low enough to act quickly, high enough to ignore a single bad request |
| `consecutiveGatewayErrors` | 5 | Catches the 504s generated by per-try timeouts, per 5.2 |
| `interval` | 10 s | Analysis sweep frequency |
| `baseEjectionTime` | 30 s | Grows multiplicatively with repeated ejection |
| `maxEjectionPercent` | **50** | See 5.4 |
| `minHealthPercent` | **40** | See 5.4 |
| `perTryTimeout` | 1.5 s | The sensor |

### 5.4 Ejection must never remove the last healthy host

`maxEjectionPercent` defaults to 10 percent in Istio and is frequently raised to 100 on the reasoning that unhealthy hosts should always be removed. That reasoning produces a specific and severe failure: during a widespread dependency problem, every host fails its health criteria, every host is ejected, and the service now has zero capacity. The partial outage becomes a total one, caused by the control meant to prevent it.

Capping at 50 percent with `minHealthPercent` at 40 means outlier detection degrades gracefully. Beyond that threshold Envoy stops ejecting and distributes load across all hosts including the unhealthy ones, on the correct assumption that a widespread failure is not fixed by having nowhere to send traffic.

### 5.5 Application-level breaker for external providers

`ext-payments` is outside the mesh, so it needs an in-process circuit breaker in the settlement consumer.

| State | Behaviour |
|---|---|
| Closed | Normal. Failure ratio tracked over a sliding window. |
| Open | Calls fail immediately without attempting the provider. Work remains queued on `sqs-tier1-settlement`. Opens at a 50 percent failure ratio over 20 calls, or on 5 consecutive timeouts. |
| Half-open | After 30 s, a single probe. Success closes, failure reopens with multiplicative backoff to a 5-minute ceiling. |

State transitions are emitted as EMF metrics and as EventBridge events, which makes circuit state visible in the service map and alertable per section 02.8.4.

**An open breaker on `ext-payments` is not an incident.** It is the system behaving as designed: settlement pauses, work queues durably, CUJ-4 stays available. It raises a Sev2 only if it remains open long enough to threaten the CUJ-5 freshness SLO. Paging on correct behaviour is a meaningful share of the alert noise the brief describes.

### 5.6 Bulkheads

Section 1.2 showed that a slow dependency exhausts a shared pool. If one pool serves both Aurora and `ext-payments`, a slow provider starves database access and takes down journeys that never touch the provider. That is cross-journey contamination, and it is the mechanism by which a single dependency caused a regional incident.

Each dependency gets its own bounded pool.

| Pool | Max connections | Max pending |
|---|---|---|
| Aurora via RDS Proxy | 50 per pod | 20 |
| `ddb-tier1-idempotency` | 20 per pod | 10 |
| `ext-payments`, settlement consumer only | 10 per pod | 5 |
| `ext-idp`, JWKS refresh only | 5 per pod | 2 |

The provider pool is deliberately small. Ten in-flight calls per pod is enough for asynchronous settlement throughput and is far too few to exhaust anything else. The `ext-payments` pool exists only in the settlement consumer, so the pool is not merely bounded, it is absent from the customer-facing path entirely.

## 6. Backpressure

**Principle: reject at the edge, never propagate load inward.** Load that reaches the data tier before being rejected has already consumed the resource it was going to exhaust.

### 6.1 Bounded everywhere

| Layer | Control | Value |
|---|---|---|
| `apigw-tier1-use1` | Method-level throttle and usage plans | Per-method, below the account quota of 10,000 rps steady and 5,000 burst |
| `mesh-tier1` | `connectionPool.tcp.maxConnections` | Per service, sized to pod capacity |
| `mesh-tier1` | `connectionPool.http.http1MaxPendingRequests` | **Bounded queue depth.** The most important single value in this table. |
| `mesh-tier1` | `connectionPool.http.maxRequestsPerConnection` | Prevents a single connection monopolising a backend |
| Application | In-flight request semaphore | Rejects at the front door above the ceiling |
| `rdsproxy-tier1-use1` | `MaxConnectionsPercent` | Protects Aurora from connection storms during failover |
| Settlement consumer | `max.poll.records`, pause and resume | Consumption rate follows downstream capacity |

`http1MaxPendingRequests` deserves its emphasis. Envoy's default pending-request queue is effectively unbounded for practical purposes, which reintroduces condition 1.3. Bounding it is what turns an overload into a 503 returned in milliseconds rather than a latency collapse.

### 6.2 Scaling on saturation, not CPU

HPA on CPU is the wrong signal for a request-driven service with external dependencies. A service blocked on a slow provider has **low** CPU and **high** saturation, so CPU-based autoscaling scales down precisely when it should scale up.

Scaling signals, from Amazon Managed Service for Prometheus via KEDA:

| Signal | Priority |
|---|---|
| In-flight requests per pod against the semaphore ceiling | Primary |
| p99 latency against the journey objective | Secondary |
| MSK consumer lag, for settlement consumers | Primary for consumers |
| CPU | Floor only, never the primary trigger |

### 6.3 Streaming backpressure

Settlement consumers pause consumption when the circuit breaker to `ext-payments` is open or when SQS depth exceeds its threshold, and resume on recovery. Without this, consumers read from MSK as fast as the brokers allow and pile work into a downstream that cannot accept it, converting a provider problem into a queue overflow.

MSK is the correct buffer. It is durable, it is replayable, and it is designed to hold the backlog. SQS and a local queue are not.

## 7. Load shedding

### 7.1 Shedding is how an SLO is kept

Serving 95 percent of traffic correctly beats serving 100 percent of traffic badly, and the second option usually degenerates into serving nothing at all. Shedding is an availability control, not an admission of defeat.

### 7.2 Priority order

| Priority | Traffic | Shed order |
|---|---|---|
| P0 | CUJ-4 submit, CUJ-2 session validation | Last |
| P1 | CUJ-3 account view | Third |
| P2 | CUJ-1 new sign-in | Second |
| P3 | Reporting, exports, bulk operations | First |
| **Never** | Synthetic canaries | **Exempt** |

The exemption is deliberate and easy to get wrong. Shedding canary traffic as low-value removes the service's own view of its health at the exact moment that view matters most. The canary's cost is negligible and its diagnostic value during shedding is high.

### 7.3 Mechanisms

| Layer | Mechanism |
|---|---|
| `waf-tier1-edge` | Rate-based rules per source IP, bot control, geographic rules where applicable |
| `cf-tier1-dist` | Cache for anything cacheable, so shed load never reaches the origin |
| `apigw-tier1-use1` | Per-method throttling, usage plans by client tier |
| Application | Admission control on the in-flight semaphore, returning 503 with `Retry-After` |

### 7.4 Shedding correctly

Rejection must be **fast and honest**. A 503 returned in 2 milliseconds costs almost nothing and lets the client act. A request queued for 29 seconds and then failed has consumed a connection for 29 seconds and told the client nothing useful.

Every shed response carries `Retry-After`. Shedding without it causes well-behaved clients to retry immediately, which converts the shed load straight back into arriving load and defeats the control.

## 8. Queue recovery

### 8.1 Poison messages

Kafka has no native dead-letter mechanism, so the consumer implements it. After 3 attempts with backoff, the record is published to `sqs-tier1-settlement-dlq` with the full payload, the error, the topic, the partition and the offset, and the consumer commits past it.

Committing past a poison message is the critical behaviour. A consumer that retries a permanently failing record forever stalls its partition, and section 01.4.3 showed that a single stalled partition is invisible in `SumOffsetLag` while being a total outage for every customer whose key maps to it.

### 8.2 DLQ operations

| Control | Setting |
|---|---|
| Alarm | **Oldest message age** above 15 minutes, not queue depth |
| Redrive | SQS redrive to source after the defect is fixed, rate-limited |
| Required before redrive | Confirmation that the original failure cause is resolved |

Age rather than depth, because depth answers how much is broken and age answers how long a customer has been waiting. A DLQ holding 5 messages for 6 hours is a worse customer outcome than one holding 500 messages for 2 minutes.

### 8.3 Replay

Replaying from MSK is an offset reset on the consumer group to a timestamp. It is safe only because consumers are idempotent per section 4.4. Without that property, replay doubles every transaction in the window.

Ordering is preserved per partition only. The partition key is the account identifier, so per-account ordering holds across a replay and cross-account ordering does not. No business logic may depend on cross-account ordering, and this is stated as an explicit design constraint rather than discovered during a replay.

### 8.4 Controlled drain, because recovery causes the second outage

When a backlog has accumulated, the instinct is to scale consumers up and drain as fast as possible. That is how a recovered service is immediately knocked over again, and how a recovering external provider is pushed straight back into failure.

Drain is rate-limited and stepped:

1. Resume at 25 percent of normal consumption rate.
2. Hold 5 minutes. Confirm downstream error rate and `ext-payments` latency are stable.
3. Step to 50 percent, then 75 percent, then 100 percent, with the same hold and the same check at each step.
4. Any step that degrades the downstream reverts to the previous rate.

The backlog is durable in MSK. There is no reason to drain it faster than the downstream can absorb, and every reason not to.

## 9. Capacity strategy

### 9.1 Static stability

The recovery region runs at **full production capacity**, not scaled to zero, and not reliant on scaling up during the event.

The reason is specific rather than conservative. Scaling up during a regional event depends on the control plane of a region under stress, at the moment every other customer with the same recovery plan is making the same API calls. A recovery plan whose first step is a large-scale provisioning request to a region in the middle of an incident is a recovery plan with a dependency on the thing that just failed.

This is the single largest cost in the design and it is stated plainly: near-double steady-state platform spend for the compute tier. It is also what makes the 45-minute RTO credible, and it is the foundation of the Option B transition in section 00.2.3.

### 9.2 Availability zone headroom

With three AZs, surviving the loss of one means the surviving two must carry the full load.

```
Required utilisation ceiling = 2/3 = 66 percent
```

Steady-state utilisation is therefore capped at 60 percent, giving margin above the arithmetic minimum. Pod Disruption Budgets and topology spread constraints keep workloads distributed, because three replicas on nodes that happen to share an AZ provides the appearance of redundancy and none of the substance.

### 9.3 Provisioning speed and warm headroom

Karpenter rather than Cluster Autoscaler, for faster node provisioning and better instance-type flexibility. Node provisioning still takes from tens of seconds to minutes, which is slower than a traffic spike.

Warm headroom is therefore maintained with low-priority placeholder pods that are preempted by real workloads. The placeholder is evicted instantly and the real pod schedules onto already-running capacity. This absorbs a spike while Karpenter provisions behind it, and it is the mechanism that covers the HPA scale-up lag identified in section 01.4.2.

### 9.4 Data tier

| Component | Constraint |
|---|---|
| Aurora readers | Auto-scaling on utilisation. Readers are the elastic part of the tier. |
| **Aurora writer** | **A single instance.** Vertical scaling requires a failover, which is 30 to 60 seconds of write unavailability behind RDS Proxy. The writer must therefore be sized for peak plus headroom in advance, and resizing is a planned change, never an incident response. |
| Aurora Serverless v2 | Considered. ACU scaling is fast but not instant, and a Tier 1 writer with a hard latency objective is a poor fit for a capacity model that reacts after load arrives. Recorded as an option for non-critical clusters. |
| `msk-tier1` partitions | **Set once, hard to change.** Partition count caps consumer parallelism. Increasing it changes the key-to-partition mapping and breaks per-account ordering, so it cannot be done during an incident. Partitions are provisioned for projected peak with headroom, and this is called out because it is a capacity decision with no fast remedy. |

### 9.5 Known demand peaks

A financial service has predictable load concentration: payday, month-end, quarter-end and public holiday boundaries. Pre-scaling ahead of these is scheduled rather than reactive, because reactive scaling arrives after the queue has already formed.

### 9.6 Load testing

The capacity model is measured, not calculated. Quarterly load tests run to the point of failure in a production-equivalent environment, recording the breaking point, the first component to saturate, and whether the shedding and backpressure controls engaged in the designed order. A capacity ceiling that has never been observed is an estimate.

## 10. How the controls compose

The test of this design is whether the stated incident can still happen. Walking it through, with `ext-payments` degrading to 20-second response times while continuing to return 200:

| Step | Control | Outcome |
|---|---|---|
| 1 | Provider latency rises | Settlement consumer calls begin exceeding 1.5 s `perTryTimeout` |
| 2 | Per-try timeout | Envoy records local-origin failures, section 5.2 |
| 3 | Outlier detection | Hosts ejected, capped at 50 percent so capacity is never zeroed, section 5.4 |
| 4 | Application circuit breaker | Opens at 5 consecutive timeouts, provider calls stop entirely, section 5.5 |
| 5 | Bulkhead | Only the 10-connection provider pool is affected. Aurora and DynamoDB pools untouched, section 5.6 |
| 6 | Backpressure | Consumer pauses, backlog accumulates durably in MSK, section 6.3 |
| 7 | **CUJ-4 submit** | **Unaffected.** Submit never calls the provider. Transactions continue to be accepted, section 01.2.2 |
| 8 | **CUJ-2 and CUJ-3** | **Unaffected.** Different pools, different path |
| 9 | Retry budget | Even if retries occurred, capped at 10 percent of active requests. No 81-fold amplification, section 3 |
| 10 | Detection | `syn-ext-payments` fails within 3 minutes. Circuit state change raises an event, section 02.9 |
| 11 | Alerting | Sev2, not Sev1. Customer journeys are available and settlement is delayed, section 05.2 |
| 12 | Recovery | Provider recovers, breaker half-opens, controlled drain at 25 percent stepping up, section 8.4 |
| 13 | Reconciliation | Daily check confirms no duplicate or lost settlement, section 01 SLI-7 |

The incident that previously took out a region becomes a Sev2 with delayed settlement and no customer-facing unavailability.

**The controls that do the actual work are steps 2 and 7.** Step 2, a per-try timeout tight enough to convert slowness into a signal, is what lets every subsequent control engage. Step 7, keeping the provider off the synchronous customer path, is what bounds the impact to settlement latency. The circuit breaker, the retry budget and the bulkhead all matter, and none of them would have been sufficient on their own. This is worth stating because circuit breakers are frequently installed as a single fix for this class of incident, and on their own, against a dependency that returns 200 slowly, they do nothing.
