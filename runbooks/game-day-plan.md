# Game-day plan

**Design rationale:** [`../04-regional-recovery.md`](../04-regional-recovery.md) section 10
**Injection mechanism:** AWS Fault Injection Service
**Starting position:** DR has never been exercised end to end. The programme starts at L1 and does not skip levels.

---

## 1. Why this exists

Every RTO, RPO, detection time and resilience control in this submission is a design intention until an exercise measures it. The brief states three symptoms, and two of them are only provable by injection:

| Claim | Proven by |
|---|---|
| Detection under 2 minutes | L2, L3 |
| Resilience controls prevent retry storms | L2 |
| RTO 45 minutes, RPO 5 minutes | **L4** |
| Incident command works without warning | L5 |

L4 is the exercise that converts this document into evidence, and it is the exit criterion for the third 30-day block in section 06.2.

---

## 2. Rules that apply to every exercise

No exercise runs without all six.

1. **A hypothesis, written before the exercise.** A prediction that can be wrong. "We expect detection within 2 minutes and failover within 45" is a hypothesis. "We will test failover" is not, and it cannot fail, which means it teaches nothing.
2. **An abort criterion expressed as a measurement**, not as a judgement call.
3. **An automated stop condition** on the journey burn-rate alarm, so the experiment halts itself when real customer impact appears, without waiting for a human to notice.
4. **A named Incident Commander**, with the exercise run under real incident command. An exercise run informally does not test the command model, which is half of what is being exercised.
5. **A rollback that has itself been tested.**
6. **Pre-drafted customer communications** for the case where impact exceeds the plan.

### 2.1 Stop conditions

FIS stop conditions are wired to the CloudWatch burn-rate alarms from section 02.8.2. This is the control that makes production exercises defensible.

```
FIS experiment template
  stopConditions:
    - source: aws:cloudwatch:alarm
      value: arn:...:alarm/tier1-journey-cuj4-burn-14x
    - source: aws:cloudwatch:alarm
      value: arn:...:alarm/tier1-journey-cuj2-hard-down
```

It also sets the ordering of the whole programme. The observability work in block 1 must land before the resilience and recovery exercises in blocks 2 and 3, because without journey burn-rate alarms there is no safe stop condition and therefore no safe production exercise.

---

## 3. L1 — Tabletop

| | |
|---|---|
| **Environment** | None. No systems touched. |
| **Duration** | 2 hours |
| **Participants** | Incident Commander, Operations Lead, Platform, Data, Transactions, Identity, Communications |
| **Customer impact** | None |

### Method

Walk [`dr-regional-failover.md`](dr-regional-failover.md) line by line against a narrated scenario. At each step the owner states aloud what they would run, where they would run it, and what they would expect to see.

### Scenario

> 14:20. CUJ-4 submit error rate reaches 100 percent. `us-east-1` canaries failing, `us-west-2` canaries green. No deployment in 31 hours. AWS Health shows no event. Aurora writer in `us-east-1` is unreachable.

### Hypothesis

Every step has a named owner, every command is runnable by someone present, and no step is ambiguous.

### Gate to advance

- No step where the owner is unclear or absent
- No command that nobody present could execute
- Every placeholder in section 0 of the runbook resolves to a real value
- The decision tree produces an unambiguous answer for the scenario

### Expected findings at first run

Based on the fact that this runbook has never been exercised, expect to find missing ARNs, at least one step owned by nobody, and disagreement about who may authorise the failover. Finding these in a tabletop costs two hours. Finding them at T+15 of a real incident costs the RTO.

---

## 4. L2 — Component faults, pre-production

| | |
|---|---|
| **Environment** | Pre-production, production-equivalent |
| **Duration** | Half day per experiment set |
| **Customer impact** | None |

Each experiment targets one control from section 03 and asserts it engages in the designed order.

### L2.1 — Slow external provider

**The most important experiment in the entire programme.** It reproduces the stated incident cause.

| | |
|---|---|
| FIS action | `aws:network:disrupt-connectivity`, latency injection toward `ext-payments` |
| Injection | Raise provider response time to 20 s while it continues returning 200 |
| **Hypothesis** | Per-try timeout fires at 1.5 s. Envoy records local-origin failures. Outlier detection ejects, capped at 50 percent. Application circuit breaker opens at 5 consecutive timeouts. Settlement pauses, backlog accumulates in MSK. **CUJ-2, CUJ-3 and CUJ-4 remain unaffected.** Alert raised as Sev2, not Sev1. |
| Abort | Any scored journey availability below 99.9 percent for 2 consecutive minutes |
| Measures | Time to circuit open, pool saturation on non-provider pools, CUJ-4 availability throughout, severity of the alert raised |

**If CUJ-4 availability drops at all, the bulkhead in section 03.5.6 is not working and the original incident can still happen.** This is the single most important assertion in the programme.

### L2.2 — Aurora writer failover

| | |
|---|---|
| FIS action | `aws:rds:failover-db-cluster` |
| **Hypothesis** | Write unavailability of 30 to 60 s behind RDS Proxy. Submits retry with idempotency keys and succeed. **Zero duplicate transactions.** No retry amplification. |
| Abort | Write unavailability beyond 120 s, or any duplicate transaction |
| Measures | Write outage duration, retry count, duplicates created, RDS Proxy borrow latency |

### L2.3 — EKS pod and node faults

| | |
|---|---|
| FIS actions | EKS pod delete, pod network latency |
| **Hypothesis** | PDBs hold. Topology spread keeps replicas across AZs. Outlier detection ejects the latent pod. No customer-visible error. |
| Abort | Any customer-visible error |
| Measures | Ejection time, error rate, pod reschedule time |

### L2.4 — Poison message

| | |
|---|---|
| Injection | Publish a malformed record to a partition on `msk-tier1` |
| **Hypothesis** | Consumer attempts 3 times, publishes to `sqs-tier1-settlement-dlq`, **commits past the offset**, and the partition does not stall. `MaxOffsetLag` alarm fires, `SumOffsetLag` does not. |
| Abort | Partition stalls beyond 5 minutes |
| Measures | Whether the partition stalled, which alarm fired, DLQ oldest-message age |

This experiment validates the alerting choice in section 01.4.3. A stalled partition is invisible in a sum and is a total outage for every customer whose key maps to it.

### L2.5 — Retry storm attempt

| | |
|---|---|
| Injection | Force a dependency to 100 percent failure under full synthetic load |
| **Hypothesis** | Amplification stays at or below 6x. Retry budget caps retries at 10 percent of active requests. Full jitter prevents a synchronised herd. |
| Abort | Amplification above 10x |
| Measures | Ratio of attempted to unique requests per layer, retry arrival distribution |

### Gate to advance to L3

Every experiment above passes its hypothesis. L2.1 and L2.5 are mandatory passes, because they are the two that test the stated incident cause.

---

## 5. L3 — Single-AZ loss, production

| | |
|---|---|
| **Environment** | **Production**, announced, business hours |
| **Duration** | 60 minutes of injection |
| **Customer impact** | None expected |

| | |
|---|---|
| FIS action | AZ availability, power interruption scenario |
| Target | One AZ in `us-east-1` |
| **Hypothesis** | Capacity holds. Surviving AZs absorb full load at the 60 percent utilisation ceiling from section 03.9.2. Aurora fails over if the writer was in the affected AZ. MSK partition leaders re-elect. **No SLO burn.** Detection under 2 minutes. |
| Abort | Any journey burn-rate alarm at 14.4x, or hard-down on any journey |
| Stop condition | Automated, wired to the above |
| Rollback | End the FIS experiment, AZ returns |
| Measures | Utilisation on surviving AZs, pod pending duration, Aurora failover time, MSK re-election time, detection time, error budget consumed |

### Why business hours

A production exercise at 03:00 with the author watching tests the system under conditions that do not resemble an incident. Business hours means real traffic, real load, the people who would actually respond, and a real abort decision. If the design cannot survive a single-AZ loss in business hours, that is the finding, and it is better found deliberately.

### Gate to advance to L4

No SLO burn, utilisation stays within capacity, and detection is under 2 minutes measured rather than estimated.

---

## 6. L4 — Full regional failover, production

**The exercise that converts the design into evidence. Exit criterion for block 3 in section 06.2.**

| | |
|---|---|
| **Environment** | **Production**, announced, low-traffic window |
| **Duration** | 4 hours scheduled, 45 minutes of active failover |
| **Customer impact** | Planned and bounded |

### Method

Execute [`dr-regional-failover.md`](dr-regional-failover.md) in full, as written, under real incident command, with a Scribe keeping the decision log.

> **One deviation from the real runbook.** L4 uses `switchover-global-cluster`, the managed planned switchover with zero data loss, rather than `failover-global-cluster`. The unplanned path leaves the global cluster degraded and requires an hours-to-days Aurora rebuild, per section 04.4.4. Doing that deliberately would leave production without cross-region recovery capability for days.
>
> **This is a real and acknowledged gap in what L4 proves.** It validates detection, decision, authority, traffic shift, dependency validation, journey confirmation and the command model. It does **not** validate the unplanned promotion path or produce a true measured RPO, because a planned switchover loses no data by definition. The unplanned path is exercised in pre-production at L2.2 and modelled from `AuroraGlobalDBRPOLag` telemetry. Stating this honestly is better than claiming an RPO measurement the exercise did not make.

### Hypothesis

| Measure | Prediction |
|---|---|
| Detection | Under 2 minutes |
| Decision | Under 8 minutes from detection |
| Data promotion | Under 10 minutes |
| Traffic shift | Under 5 minutes |
| Dependency validation | Under 10 minutes, all 7 checks pass |
| Journey confirmation | Under 5 minutes |
| **Total RTO** | **Under 45 minutes** |
| **Within RMiT 10.32** | **Under 120 minutes** |
| Data loss | Zero, planned switchover |
| Duplicate transactions | Zero |

### Abort criteria

| Trigger | Action |
|---|---|
| Any journey unavailable beyond 10 minutes | Abort, fail back immediately |
| Dependency validation check 1, 2 or 3 fails | Abort unless a workaround is confirmed within 5 minutes |
| Elapsed time reaches 90 minutes | **Abort regardless of progress.** The RMiT single-incident ceiling is 120 minutes and the abort itself takes time. |
| Any duplicate transaction detected | Abort, reconcile |

### Measures recorded

- Wall-clock duration of every phase against its budget in section 04.1
- Which of the seven dependency checks failed, if any
- Error budget consumed, against both ledgers in section 04.9.3
- Every step where the runbook was wrong, ambiguous or incomplete

### Afterwards

- Fail back during the same window using the planned switchover, after a stability hold
- Full reconciliation per section 04.7, even though zero loss is expected. **Reconciliation that is only run when loss is suspected is a reconciliation nobody trusts.**
- Correct the runbook as part of the review, not later

---

## 7. L5 — Unannounced regional failover

| | |
|---|---|
| **Environment** | **Production**, unannounced to responders |
| **Prerequisite** | L4 passed twice consecutively |
| **Customer impact** | Planned and bounded |

| | |
|---|---|
| Known in advance | Exercise sponsor, Incident Commander on the day, one safety observer with abort authority |
| Not known in advance | The on-call responder, the delivery teams, the escalation path |
| **Hypothesis** | Detection, declaration, escalation and handover work without prior warning. The responder finds and follows the runbook. The T+30 forced decision occurs. Total RTO under 45 minutes. |
| Abort | Safety observer may abort at any point. Automated stop conditions remain armed. |
| Measures | Time to declare, whether the runbook was found and followed, whether authority was exercised without seeking approval, whether handover occurred cleanly if the window spanned a shift |

### What L5 actually tests

L4 tests the system. L5 tests the organisation. The brief says teams disagree on who owns reliability work, and an announced exercise with the right people pre-assembled cannot detect that. An unannounced one finds out whether the authority in section 05.3.1 is real or merely written down.

---

## 8. Schedule against the 90-day roadmap

| Block | Exercises | Exit criterion |
|---|---|---|
| Days 1 to 30 | L1 tabletop, twice. L2.1 and L2.5 in pre-production once burn-rate alarms exist. | Detection time measured by injection, not estimated |
| Days 31 to 60 | Full L2 set. First L3 in production. | A deliberate dependency failure does not propagate into a retry storm, proven by L2.1 and L2.5 |
| Days 61 to 90 | **L4 full regional failover.** | **Measured RTO and RPO recorded against the 45-minute and 5-minute targets** |
| Post-90 | L3 quarterly, L4 quarterly, L5 annually | |

An L4 every quarter exceeds an annual recovery-testing expectation. For a service whose DR has never been exercised, quarterly is the right frequency until two consecutive clean runs establish confidence.

---

## 9. What a failed game day means

A game day that finds nothing was badly designed. A game day that fails has done its job, and the response to a failure is a finding, an owner and a date, scored into the backlog in section 06.1 like any other item.

Two rules protect this:

1. **No exercise is cancelled because the team expects it to fail.** That expectation is the finding, and it is cheaper to confirm in a controlled window than during an incident.
2. **A failed exercise is not an incident unless customers were affected.** Conflating the two makes people stop proposing exercises, which is the fastest way to return to never having exercised DR at all.
