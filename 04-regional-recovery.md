# 04. Regional recovery

Weight: 20 percent. Selected cloud: **Amazon Web Services**.

The brief states that DR has never been exercised end to end. Until it has been, every number in this section is a design intention. The game-day plan in section 10 and [`runbooks/game-day-plan.md`](runbooks/game-day-plan.md) is therefore not an appendix to this section. It is the part that converts it into evidence.

## 1. The 45-minute budget, decomposed

An RTO is only meaningful once it is spent. Each phase has a budget, and every control in this section exists to protect one of them.

| Phase | Budget | Cumulative | Protected by |
|---|---|---|---|
| Detection | 2 min | T+2 | Hard-down alarms and dual-region canaries, section 02.9 |
| Declaration and decision | 8 min | T+10 | Pre-delegated authority and a decision tree, sections 3 and 2 |
| Data promotion | 10 min | T+20 | Aurora Global Database managed failover, section 4 |
| Traffic shift | 5 min | T+25 | Route 53 ARC routing controls, section 5 |
| Dependency validation | 10 min | T+35 | Pre-validated egress, keys and quotas, section 6 |
| Journey confirmation | 5 min | T+40 | Recovery-region canaries already running, section 02.5 |
| Buffer | 5 min | **T+45** | |

Two observations about where the time actually goes.

**The decision costs more than the technology.** Data promotion and traffic shift together are 15 minutes of the 45, and both are largely automated. Detection plus decision is 10 minutes and is entirely human. Dependency validation is 10 minutes and is mostly pre-work that either was or was not done months earlier. The single largest controllable risk to the RTO is a commander who is not empowered to decide, which is why section 05.3.1 writes the authority down.

**The buffer is 5 minutes and that is uncomfortably thin.** It is stated rather than padded, because a 45-minute RTO decomposed honestly does not leave much room. Section 11 records this as a known limitation and section 06 funds the active-active transition that removes the problem rather than managing it.

## 2. Failure detection and the failover decision

### 2.1 Signals that can trigger consideration

| Signal | Source |
|---|---|
| Hard-down alarm on a scored journey | CloudWatch, 1-minute metrics, 2 periods, section 02.8.3 |
| Primary-region canary failing while recovery-region canary passes | CloudWatch Synthetics from both regions, section 02.5 |
| AWS Health event for a dependent service in `us-east-1` | AWS Health via EventBridge, section 02.8.5 |
| Aurora writer unreachable with no recovery trend | RDS events, `DatabaseConnections`, write error rate |
| Route 53 ARC readiness check failing for the primary cell | ARC readiness |

**The dual-region canary comparison is the highest-value signal in the set.** A primary-region canary failing on its own is ambiguous, because the canary itself may be broken. A primary canary failing while the recovery canary succeeds, from a different region, against a different stack, is strong evidence that the problem is regional and that the recovery region is capable of serving. That second half is what a commander actually needs, and no single-region monitoring design can supply it.

### 2.2 The decision tree

Failover is not the correct response to most Sev1 incidents. It is a large, partially irreversible operation with its own risk, and section 00 established that it consumes 10.4 months of error budget. The tree exists so that the decision is structured rather than improvised at T+8.

```
Is a scored journey down or critically degraded?
  No  -> Not a failover candidate.
  Yes -> Is the recovery region healthy and serving canary traffic?
      No  -> DO NOT FAIL OVER. Failing into a broken region converts a
             regional outage into a total one. Continue in-region recovery.
      Yes -> Is the cause understood AND fixable within the remaining
             RTO budget?
          Yes -> Fix in region. Re-evaluate every 5 minutes against the
                 T+30 escalation in section 05.6.
          No  -> Is the cause a data-plane fault, or a data fault?
              Data fault, meaning corruption or bad data replicated
                  -> DO NOT FAIL OVER. Replication has already carried
                     the fault to the recovery region. Failover
                     propagates the problem and loses the only clean
                     comparison point. Go to point-in-time recovery.
              Data-plane or regional service fault
                  -> FAIL OVER. Record DECISION per section 05.5.
```

Two branches deserve emphasis because both are routes to making an incident worse.

**Never fail into an unverified region.** This is the reason the recovery-region canaries in section 02.5 run continuously rather than during tests. Their standing output is the input to this branch.

**Never fail over for a data fault.** Aurora Global Database replicates physically. Corrupt data, a bad migration or an erroneous bulk update is in the secondary within a second. Failover does not escape it, it only destroys the ability to compare the two copies. The correct response is Aurora point-in-time recovery or a backtrack to a pre-fault timestamp, which is a different runbook with a different RTO. Conflating the two is a common and expensive error.

### 2.3 What is explicitly not automated

Failover is **not** triggered automatically by health checks. This is a deliberate choice against the easier option and the reasons are specific:

1. A health signal can be wrong. An automated failover on a false positive causes an outage that would not otherwise have occurred, and does so at full confidence.
2. The data-fault branch in 2.2 cannot be evaluated by a health check, and it is the branch where automation does the most damage.
3. For a regulated financial institution, an unexplained automated region change is a harder position to defend than a documented decision made by a named person at a recorded time.

The cost of this choice is the 8-minute decision budget in section 1. That cost is accepted, and section 06 drives toward active-active, where the question becomes traffic weighting rather than a binary failover and the decision shrinks accordingly.

## 3. Authority

| Decision | Authority | Escalation |
|---|---|---|
| Declare Sev1 | Any on-call responder | None required |
| Declare a Regional Disaster Event | Incident Commander | Notify executive, do not wait |
| **Execute regional failover** | **Incident Commander, alone** | **None. Pre-delegated.** |
| Accept known data loss within the stated RPO | Incident Commander | Record in the decision log |
| Accept data loss **beyond** the stated RPO | Service owner plus engineering leadership | Required before proceeding |
| Execute failback | Change advisory, planned | Never during the original incident |
| Suspend the error budget policy | Incident Commander | Record |

The third row is the one that determines whether the RTO is achievable. A commander who must find an approver cannot complete detection, decision, promotion, shift and validation inside 45 minutes. The authority is granted in advance, in writing, and is reviewed quarterly rather than negotiated during an incident.

The fifth row is the brake. Data loss within the agreed RPO is a pre-accepted business decision and the commander executes it. Loss beyond the RPO is a different decision of a different kind, and it stops for an owner.

## 4. Data promotion

### 4.1 Aurora Global Database, and the distinction that matters

Aurora Global Database offers two operations that are frequently conflated. They have different prerequisites, different data-loss characteristics and different uses.

| Operation | Prerequisite | Data loss | Used for |
|---|---|---|---|
| **Managed planned switchover** | Primary healthy and reachable | **Zero** | Game days, failback, planned maintenance |
| **Managed unplanned failover** | Primary unavailable | **Bounded by replication lag at the moment of failure** | Genuine regional loss |

The unplanned path is the one that serves the RTO, and its RPO is not a setting. It is whatever the replication lag happened to be.

### 4.2 RPO is a measurement, not a configuration

This is the central point of the data section.

Aurora Global Database typically replicates with sub-second lag. "Typically" is not an objective. If lag has grown to 8 minutes through a long-running transaction, a bulk load or a network event, then the RPO at that moment is 8 minutes, the 5-minute objective is already breached, and nothing in the system has said so.

`AuroraGlobalDBRPOLag` is therefore alarmed as a **standing SLO**, not as an incident metric:

| Alarm | Threshold | Action |
|---|---|---|
| RPO lag warning | Above 60 s for 5 min | Ticket. Investigate the cause. |
| RPO lag critical | Above 150 s for 5 min | **Page, Sev2.** The 5-minute RPO is at risk before any outage has occurred. |

The critical threshold sits at half the stated RPO deliberately. An alarm that fires at 5 minutes fires at the moment the objective is already missed, which is too late to be useful. Alarming at half leaves room to act.

**This converts RPO from an assertion into a continuously verified property.** A reviewer can ask "what was your RPO last Tuesday" and the answer is a time series rather than a design document.

### 4.3 Promotion sequence

1. Confirm `AuroraGlobalDBRPOLag` at the last datapoint before failure. This figure **is** the actual RPO and is recorded in the decision log immediately, because the metric will not be retrievable from a failed region later.
2. Execute the managed unplanned failover, promoting `aur-tier1-usw2` to writer.
3. `rdsproxy-tier1-usw2` is already configured against the local cluster and requires no change. Applications in the recovery region address the proxy, not the cluster, so no application configuration changes during failover.
4. Verify writes succeed against the promoted writer.

Budget: 10 minutes. The promotion itself is typically faster. The budget covers verification and the recording in step 1.

### 4.4 The asymmetry nobody plans for

After an unplanned failover, the global cluster is **degraded, not recovered**. The former primary cannot simply rejoin as a secondary. It must be removed from the global cluster and a new secondary created, which for a large dataset is an hours-long rebuild rather than a minutes-long operation.

The operational consequences are stated plainly:

- For the duration of the rebuild, the service is running in a **single region with no cross-region recovery capability**. A second regional event during this window has no answer.
- Failback cannot happen until the rebuild completes. Failback is days away, not hours.
- This window is the highest-risk period of the entire incident and it begins after everyone has declared the incident resolved.

Section 8 treats failback accordingly, and section 11 records the single-region window as a known limitation.

### 4.5 MSK, the binding constraint on RPO

Section 00.2.5 identified the streaming tier rather than the relational tier as the real RPO constraint. Message durability is the easy half. Consumer **offset position** is the hard half: a consumer that resumes in the recovery region without knowing where it stopped either reprocesses a large backlog or silently skips work.

**MSK Replicator** is used, configured to replicate `msk-tier1-use1` to `msk-tier1-usw2` with consumer group offset synchronisation and identical topic names.

| Property | Consequence |
|---|---|
| Offset synchronisation | Consumers resume near their last committed position without manual offset translation |
| Identical topic names | Consumers need no configuration change on failover, which removes a configuration step from the critical path |
| Asynchronous replication | In-flight records within the replication lag window are lost. **This is the stream RPO.** |
| Periodic rather than continuous offset sync | Consumers may reprocess a window of already-handled records |

The last row is survivable only because consumers are idempotent by contract, per section 03.4.4. Without that property, offset synchronisation would cause duplicate settlement on every failover. The two designs are coupled and neither works alone.

Replication lag is alarmed on the same principle as Aurora:

| Alarm | Threshold | Action |
|---|---|---|
| Replicator latency warning | Above 60 s for 5 min | Ticket |
| Replicator latency critical | Above 150 s for 5 min | **Page, Sev2** |

### 4.6 DynamoDB

`ddb-tier1-idempotency` is a Global Table, active-active in both regions. No promotion step exists and none is required, which is why idempotency state is reachable throughout the failover. The replication-lag caveat is in section 03.4.3 and the reconciliation that bounds it is in section 7.

### 4.7 Consolidated RPO position

| Data set | Mechanism | Expected | Objective | Measured by |
|---|---|---|---|---|
| Transactional, Aurora | Global Database, physical replication | Sub-second | **5 min** | `AuroraGlobalDBRPOLag` |
| Event stream, MSK | MSK Replicator | Seconds | **5 min** | Replicator latency |
| Idempotency, DynamoDB | Global Table | Sub-second | **5 min** | Replication latency |
| Object storage | S3 Cross-Region Replication | Minutes | 15 min, separate | CRR metrics, replication time control |

S3 carries a separate and longer objective because documents and statements are not part of the stated critical data set. Stating it separately is more honest than implying one objective covers everything.

## 5. Traffic shift

### 5.1 Route 53 Application Recovery Controller

Traffic shift uses ARC **routing controls**, which are deliberate on and off switches, not health-check-driven automatic failover.

The selection reason is the one that matters during a regional event. The ARC routing control data plane is distributed across five regional endpoints and is engineered to remain operable when the control planes of individual regions are impaired. A recovery mechanism that depends on the health of the region being recovered from is not a recovery mechanism. This property, not the switch itself, is what is being bought.

### 5.2 Topology

```
Customer
  -> cf-tier1-dist                      (CloudFront, global)
      origin: origin.tier1.example      (Route 53 record)
        -> ARC routing control USE1 = On  -> apigw-tier1-use1
        -> ARC routing control USW2 = Off -> apigw-tier1-usw2
```

A single Route 53 record behind CloudFront is the one switch point. Failover is two routing control state changes and nothing else. CloudFront, the WAF, the certificate and the customer-facing hostname are all unchanged, which removes the slowest and least reversible parts of a DNS-based failover from the critical path entirely.

A CloudFront **origin group** is configured as a secondary automatic mechanism for fast-failing origin errors. It handles a cleanly failing origin in seconds without human involvement. It deliberately does not handle the slow-origin case, for the reason established in section 03.5.1, and it is not relied upon for regional recovery.

### 5.3 Safety rules

ARC safety rules prevent the two mistakes that routing controls make easy.

| Rule | Type | Prevents |
|---|---|---|
| At least one region On | Assertion | Both controls Off, which is a self-inflicted total outage |
| Not both regions On during failover | Assertion | Split-brain writes against two promoted writers |
| USW2 may not be set On while its readiness check is failing | Gating | Failing into a region that cannot serve |

The third rule is the automated form of the decision-tree branch in section 2.2. The gate enforces mechanically what the commander would otherwise have to remember under pressure.

### 5.4 Readiness checks

ARC readiness checks continuously compare the recovery region against the primary: resource counts, instance capacity, Auto Scaling configuration, service quotas and routing configuration. Drift is reported before it matters.

This is the direct answer to "DR has never been exercised end to end." A standby that is validated only during an exercise is a standby whose drift is discovered during an incident. Readiness checks make the comparison a standing fact. They detect the mundane failures that actually break real failovers: a quota that was never raised in the second region, a subnet that was added to one region and not the other, a security group rule that drifted.

### 5.5 Client-side caching

Route 53 TTL on `origin.tier1.example` is 60 seconds, which bounds resolver propagation.

The residual risk is the client. Some resolvers ignore TTL, and the JVM's default `networkaddress.cache.ttl` of caching successful lookups indefinitely is a long-standing cause of failovers that work everywhere except in one service. Any JVM component resolving the origin name sets `networkaddress.cache.ttl=30`. This is verified during game days rather than assumed, because it is invisible until a failover is attempted.

### 5.6 Cost

ARC clusters are among the more expensive AWS controls on a per-hour basis, and it is a standing cost whether or not a failover ever occurs. For a Tier 1 banking journey with a 45-minute RTO and a regulatory ceiling of 120 minutes per incident, it is justified. For a Tier 2 service it would not be, and the same pattern should not be copied downward by default.

## 6. Dependency validation

Ten minutes of the RTO are budgeted here, and almost all of the work is done months in advance. The items below are the ones that actually break real failovers, and each is pre-validated continuously rather than checked during the event.

| Dependency | Risk | Pre-validation | In-event check |
|---|---|---|---|
| **`ext-payments` egress allowlist** | Provider allowlists source IPs. The recovery region's egress addresses were never registered, so the provider rejects every call after failover. | Static NAT Gateway Elastic IPs in **both** regions, both registered with the provider, verified by `syn-ext-payments` running continuously from both regions | Confirm canary green from `usw2` |
| **`ext-idp` egress allowlist** | As above | As above | Confirm `syn-ext-idp` green from `usw2` |
| **KMS keys** | KMS keys are regional. Data encrypted with a `use1` key cannot be decrypted in `usw2`. Replicated encrypted data becomes unreadable. | **Multi-Region KMS keys** for everything replicated. Verified by a scheduled decrypt test in the recovery region. | Confirm decrypt test green |
| **Secrets Manager** | Secrets are regional. The recovery region holds no credentials. | Replica secrets in `usw2`, rotation configured to update both | Confirm application startup |
| **Service quotas** | Quotas are per-region and are routinely lower in the region nobody uses. Capacity requests fail at the moment of need. | Service Quotas with CloudWatch usage alarms in **both** regions, quotas matched | ARC readiness check |
| **ACM certificates** | Regional certificates for regional endpoints | Certificates issued in both regions, expiry alarmed at 30 days | ARC readiness check |
| **Container images** | ECR is regional. A pull from a failed region cannot succeed. | ECR cross-region replication, images present in both | ARC readiness check |
| **Configuration and feature flags** | Drift between regions produces different behaviour after failover | Single source of truth, deployed to both regions by the same pipeline | Compare configuration hash |

**The egress allowlist row is the one that most often turns a successful technical failover into a failed recovery.** Every internal component promotes correctly, traffic shifts cleanly, and then every call to the payment provider is rejected because the provider has never seen the recovery region's source address. It is invisible until a failover is attempted, it cannot be fixed inside the RTO because it requires the provider to make a change, and it is prevented entirely by running the provider canaries from both regions continuously. The canary is cheap. The failure is not.

**The multi-Region KMS row is the equivalent failure for data.** Cross-region replication of encrypted data to a region without the key produces replicated, durable, unreadable data, and the problem is discovered at the point of recovery.

## 7. Reconciliation

Failover within a 5-minute RPO means accepting that some work was in flight and its state is uncertain. Reconciliation establishes what actually happened. For a financial institution it is also the artefact that answers a regulator's questions, so it is designed as a deliverable rather than as cleanup.

### 7.1 DynamoDB is the authority for what was accepted

The key insight is that the idempotency store is active-active and was reachable throughout, while Aurora lost its last moments of writes. `ddb-tier1-idempotency` therefore records acceptances that `aur-tier1-usw2` may have no transaction row for.

Comparing the two identifies the lost-acceptance set precisely, rather than estimating it from a time window.

### 7.2 Procedure

Executed after service is restored and confirmed stable, never during the recovery itself.

| Step | Action | Output |
|---|---|---|
| 1 | Define the window: from the last confirmed-replicated transaction to the promotion timestamp | Bounded reconciliation scope |
| 2 | Compare `ddb-tier1-idempotency` records in the window against transactions in `aur-tier1-usw2` | **Lost acceptances**: accepted and acknowledged to the customer, no durable record |
| 3 | Retrieve settlement status from `ext-payments` for every transaction in the window | Provider's view of reality |
| 4 | Compare provider state against internal state | Four classes, see below |
| 5 | Replay `sqs-tier1-settlement-dlq` and unpublished outbox rows | Recovered in-flight work |
| 6 | Produce the reconciliation report | Finance, audit and regulatory record |

### 7.3 The four classes

| Class | Meaning | Action |
|---|---|---|
| Lost acceptance | Customer was told it was accepted, no record exists | **Customer communication required.** Re-submit using the original idempotency key so the provider deduplicates if it did in fact reach them. |
| Settled, not recorded | Money moved, internal state says otherwise | Update internal state to match the provider. The provider is authoritative for settlement. |
| Recorded, not settled | Internal state says terminal, provider has no record | Investigate individually. Do not auto-retry. This class may indicate the provider lost it, which is a provider escalation. |
| Duplicate | Settled twice, from the Global Table lag window in section 03.4.3 | Void one side with the provider. **Report, because this is the materialisation of a known accepted risk.** |

The first class is the one with a customer obligation attached rather than only a technical one, and it is the reason the Communications Lead in section 05.3 stays engaged after the technical recovery is complete.

The fourth class is the accepted residual risk from section 03.4.3 becoming real. It is reported specifically rather than quietly corrected, because a risk that is accepted in design and then hidden when it occurs was never really accepted.

## 8. Failback

### 8.1 Failback is not failover in reverse

| | Failover | Failback |
|---|---|---|
| Trigger | Unplanned | Planned |
| Time pressure | 45-minute RTO | None |
| Authority | Incident Commander, alone | Change advisory |
| Data loss | Bounded by RPO | **Zero**, via managed planned switchover |
| Timing | Immediately | Days later, low-traffic window |

**Failback never happens during the original incident.** The pressure to return to normal is real and it is the second-outage risk. The recovery region is serving. There is no customer benefit to moving again on the same day, and there is substantial risk in doing so with a tired team against a region whose fault is not yet fully understood.

### 8.2 Preconditions

All must hold. Any failure stops the failback.

1. The original fault is understood and remediated, with evidence.
2. The Aurora global cluster is rebuilt with `use1` as a healthy secondary, per section 4.4. This is usually the long pole.
3. `AuroraGlobalDBRPOLag` to `use1` is within normal bounds for at least 24 hours.
4. MSK Replicator is replicating in the reverse direction with normal latency.
5. ARC readiness checks pass for the `use1` cell.
6. Canaries against `apigw-tier1-use1` are green and have been for at least 24 hours.
7. Reconciliation from section 7 is complete and signed off.
8. A low-traffic window is scheduled and communicated.

### 8.3 Sequence

Failback uses the **managed planned switchover**, not the unplanned failover path, because the primary is healthy by precondition 2. This is a zero-data-loss operation and is the reason failback waits for the rebuild rather than proceeding without it.

1. Confirm all preconditions. Abort on any failure.
2. Quiesce settlement consumers, allowing in-flight work to complete.
3. Execute the managed planned switchover to `use1`. Zero data loss.
4. Reverse MSK Replicator direction.
5. Flip ARC routing controls: USW2 Off, USE1 On, honouring the safety rules in 5.3.
6. Resume settlement consumers with the controlled drain in section 03.8.4.
7. Confirm all canaries green from both regions.
8. Hold a 24-hour heightened observation period before standing down.

## 9. RMiT: the regulatory ceiling behind these numbers

> **Applicability.** The scenario states no regulatory regime, and section 00.E3 excludes compliance mapping on that basis. This section is included because a Tier 1 digital service operated by a Malaysian financial institution falls under Bank Negara Malaysia's Risk Management in Technology policy document, and a recovery design that ignores it is incomplete in that context. Paragraph numbering should be verified against the current policy document, since RMiT was revised in late 2025.

### 9.1 The requirement

For critical systems with immediate service recovery expectations, RMiT paragraph 10.32 sets two limits:

| Limit | Value |
|---|---|
| Cumulative **unplanned** downtime, rolling 12 months | **4 hours (240 minutes)** |
| Maximum tolerable downtime, **single incident** | **120 minutes** |

These are mandatory requirements, and BNM enforces them. Administrative monetary penalties have been issued to multiple licensed institutions for breaching this paragraph.

### 9.2 How the scenario's targets sit against it

| | Scenario target | RMiT 10.32 | Position |
|---|---|---|---|
| Annual unplanned downtime | 51.8 min, from 4.32 min x 12 | ≤ 240 min | SLO is 4.6x tighter than the regulator |
| Single incident | 45 min RTO | ≤ 120 min | 75 min of headroom |

The SLO is the binding constraint in normal operation. The regulator becomes binding only when the disaster clause is invoked.

### 9.3 The disaster clause does not apply to the regulator

This is the consequence that matters and it is easy to miss.

Section 01.6.1 permits declared Regional Disaster Events to be excluded from the 99.99 percent journey SLOs. **RMiT grants no equivalent exclusion.** It counts actual unplanned downtime of critical systems.

```
Normal operations                     51.8 min
2 declared disaster events            90.0 min   (2 x 45 min)
                                     ----------
RMiT 10.32 rolling 12-month tally    141.8 min
Against a cap of                     240.0 min
Remaining margin                      98.2 min
```

The service therefore maintains **two downtime ledgers**:

| Ledger | Counts | Excludes | Owner |
|---|---|---|---|
| SLO ledger | Journey unavailability | Declared Regional Disaster Events, bounded at 45 min | SRE |
| **RMiT 10.32 ledger** | **All unplanned downtime of the critical system** | **Nothing** | Technology risk, with SRE supplying the measurement |

Conflating the two is how an institution passes its own internal reliability review and is penalised by its regulator in the same quarter. The ledgers are reported together at the quarterly steering forum in section 06.5.1 so the divergence is always visible.

### 9.4 The 120-minute ceiling reframes the escalation design

The single-incident cap is 120 minutes. Against the decomposition in section 1:

```
Detection, decision, promotion, shift, validation, confirmation   40 min
Buffer                                                              5 min
                                                                 --------
Planned total                                                      45 min
Headroom to the RMiT single-incident ceiling                       75 min
```

75 minutes sounds generous and is consumed quickly by the things that actually go wrong: a failed dependency validation requiring a provider call, an unrebuilt quota, a shift attempted into a region whose readiness check was failing, or a handover without a stated ruled-out list.

This is the regulatory justification for two controls that would otherwise look like process for its own sake:

- The **T+30 forced failover decision** in section 05.6. Beyond T+30, the remaining phases cannot complete inside the regulatory ceiling.
- The **structured handover** in section 05.8. An unstructured handover during a regional recovery costs 20 minutes of re-investigation, which is the difference between a compliant recovery and a reportable one.

### 9.5 Related obligations deliberately not quantified here

RMiT and BNM's broader framework also cover incident notification to the regulator, annual recovery testing, cloud concentration risk and exit strategy. **No notification deadline is asserted in this submission**, because published sources conflict on whether the applicable timeline sits in RMiT, in the business continuity policy document or elsewhere, and quoting a figure that is wrong is worse than noting the gap. The requirement is recorded as an action in section 06 to confirm the applicable timeline against the primary policy document and to wire it into the communications cadence in section 05.4.

Two points are safe to state and are addressed by this design:

- **Annual recovery testing** is satisfied and exceeded by the game-day ladder in section 10, which exercises recovery quarterly rather than annually.
- **Cloud concentration risk and exit strategy** are addressed in section 11.3.

## 10. Game-day design

Full exercise definitions, scripts and abort criteria are in [`runbooks/game-day-plan.md`](runbooks/game-day-plan.md). The design principles are here because they determine whether the programme is safe enough to actually run.

### 10.1 The ladder

Blast radius increases only when the level below has passed. The brief states DR has never been exercised, so the programme starts at level 1 and does not skip.

| Level | Exercise | Environment | Customer impact | Gate to advance |
|---|---|---|---|---|
| **L1** | Tabletop. Walk the runbook, no systems touched. | None | None | Every step has a named owner and no step is ambiguous |
| **L2** | Component faults via AWS FIS: pod kill, AZ power interruption, Aurora writer failover, injected provider latency | Pre-production | None | Every resilience control in section 03 engages in the designed order |
| **L3** | Single-AZ loss in production, announced, business hours | **Production** | None expected | Capacity holds at 60 percent utilisation, no SLO burn |
| **L4** | Full regional failover in production, announced, low-traffic window | **Production** | Planned, bounded | **Measured RTO and RPO recorded against the 45-minute and 5-minute targets** |
| **L5** | Unannounced regional failover | **Production** | Planned, bounded | Detection, decision and handover work without prior warning |

L4 is the exercise that converts this document into evidence, and it is the exit criterion for the third 30-day block in section 06.2.

### 10.2 AWS Fault Injection Service

FIS is the injection mechanism for L2 and L3. The capability that makes it safe to run in production is **stop conditions**: a CloudWatch alarm that automatically halts and rolls back the experiment.

**Stop conditions are wired to the journey burn-rate alarms from section 02.8.2.** The experiment therefore aborts itself the moment real customer impact appears, without waiting for a human to notice. This is what makes an L3 production exercise defensible rather than reckless, and it is the reason the observability work in block 1 must precede the resilience and recovery work in blocks 2 and 3.

Relevant FIS actions:

| Action | Exercises |
|---|---|
| AZ availability, power interruption scenario | Section 01.4.2 single-AZ loss, section 03.9.2 headroom |
| `aws:rds:failover-db-cluster` | Section 01.4.3 writer failover, RDS Proxy behaviour |
| EKS pod delete and pod network latency | Section 03.5 outlier detection, PDB behaviour |
| `aws:network:disrupt-connectivity` | Section 03.5.5 provider circuit breaker, the slow-dependency case |

### 10.3 Non-negotiable conditions for every exercise

1. A written abort criterion, defined before the exercise, stated as a measurement rather than a judgement.
2. An automated stop condition on the journey burn-rate alarm.
3. A named Incident Commander, with the exercise run under real incident command. An exercise run informally does not test the command model, which is half of what is being exercised.
4. A rollback that has itself been tested.
5. Customer communications pre-drafted for the case where impact exceeds the plan.
6. **A hypothesis stated in advance.** An exercise without a prediction cannot be falsified, and an exercise that cannot fail teaches nothing. "We expect detection within 2 minutes and failover within 45" is a hypothesis. "We will test failover" is not.

### 10.4 Cadence

| Exercise | Frequency |
|---|---|
| L2 component faults | Continuous in CI, plus monthly extended |
| L3 single-AZ, production | Quarterly |
| L4 regional failover, production | **Quarterly**, which exceeds an annual testing expectation |
| L5 unannounced | Annually, once L4 has passed twice consecutively |

## 11. Known limitations

Carried into section 07.

1. **The 5-minute buffer in the RTO decomposition is thin.** One unanticipated step consumes it. The honest mitigation is the active-active transition in section 06.6, not a more optimistic decomposition.
2. **The post-failover single-region window in section 4.4 has no answer.** During the Aurora global cluster rebuild, a second regional event cannot be recovered from. The window is hours to days depending on dataset size, and it is the highest-risk period of the incident.
3. **RPO depends on replication lag at the moment of failure**, which is monitored and alarmed but cannot be guaranteed. A correlated event that both degrades replication and fails the region produces an RPO worse than 5 minutes. The alarms in 4.2 bound the risk without eliminating it.
4. **Cloud concentration risk.** The entire design sits on a single provider, which is a recognised concern for a financial institution and is explicitly a BNM focus area. The brief requires a single provider and forbids mixing, so this is noted rather than designed around. A credible exit strategy depends on data portability rather than on running a second provider in parallel: Aurora PostgreSQL is a standard engine, MSK is standard Kafka, and EKS is standard Kubernetes. The genuinely provider-specific components are ARC, API Gateway and CloudFront, which are the edge and control layers and are the practical replacement cost in an exit scenario. Recording that assessment is more useful than an unfunded multi-cloud ambition.
5. **The external providers are generic.** Real provider failover capabilities, allowlisting processes and reconciliation interfaces would change section 6 and section 7 materially.
