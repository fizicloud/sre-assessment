# 05. Incident command model

Weight: 15 percent.

The scenario states many alerts and slow detection of customer-impacting failures. Alert volume is an observability problem and is addressed in section 02. Slow detection is partly an observability problem and partly a command problem. A system can detect a failure in 30 seconds and still take 20 minutes to act on it if nobody is empowered to declare, and if the people who could act are still arguing about whether this is really an incident. This section removes that gap.

## 1. Design principles

1. **Declaring is cheap, and the bias is toward declaring.** Over-declaration costs a short call. Under-declaration costs error budget. The model is built so that standing an incident down is explicitly a success, not an admission of error.
2. **One commander, pre-delegated authority.** The Incident Commander holds decision rights for the duration, including rights that normally require change approval. Authority granted at the moment of need arrives too late.
3. **Severity is derived, not debated.** It comes from customer impact and burn rate against the stated SLOs. A matrix removes the opening argument.
4. **The commander does not fix.** Commanding and debugging are different jobs, and one person doing both does neither.
5. **Evidence is captured during, not reconstructed after.** Telemetry retention and dashboard state do not survive a week of normal operations.

## 2. Severity criteria

Severity is set from two inputs: the breadth and depth of customer impact, and the burn rate on the affected journey's error budget. The burn-rate thresholds are the same ones that drive the alerts in section 02, so the alert that wakes someone already carries the severity.

| Severity | Trigger, any one is sufficient | Response | Page |
|---|---|---|---|
| **Sev1** | A scored critical user journey is unavailable, or degraded beyond its SLO, for all customers or a large customer fraction. Fast-burn alert firing on a Tier 1 journey, meaning 14.4x burn sustained over 1 hour. Confirmed data loss or corruption in the critical data set. A regional event is declared. A security incident with active exposure of customer data. | Full incident command stood up within 5 minutes. Bridge opened. | Yes, 24x7 |
| **Sev2** | A scored journey is degraded for an identifiable subset of customers. Slow-burn alert firing, meaning 6x burn sustained over 6 hours. Loss of one availability zone with measurable capacity impact. An external provider is hard-down and the defined fallback is engaged and holding. | Incident Commander and Operations Lead. Bridge at the commander's discretion. | Yes, 24x7 |
| **Sev3** | A non-scored journey or an internal capability is impaired. 3x burn sustained over 1 day. Redundancy is lost without customer impact, for example one replica or one node group down. | Owning team, business hours, tracked to closure. | No |
| **Sev4** | No customer impact and no loss of redundancy. Anomaly worth recording. | Backlog. | No |

### 2.1 A note on what 99.99 percent does to these thresholds

At a 99.99 percent target the error budget is 4.32 minutes per 30-day window, as derived in section 00. A 14.4x fast burn corresponds to a sustained error ratio of 0.144 percent.

```
Error budget ratio    = 0.0001
Fast-burn multiplier  = 14.4
Paging error ratio    = 14.4 x 0.0001 = 0.00144 = 0.144 percent
```

A 0.144 percent error rate is a figure many teams would dismiss as noise. At four nines it is a page. This is the operational cost of the target, and it is the reason section 02 insists on journey-scoped SLIs with clean success definitions. Measured against a noisy or over-broad SLI, a threshold this tight produces exactly the symptom the scenario describes: many alerts, and no confidence in any of them.

## 3. Roles

Roles are functions, not job titles. One person may hold two in a Sev2. Nobody holds two in a Sev1.

| Role | Holds | Does not |
|---|---|---|
| **Incident Commander** | Declares, sets and revises severity, owns the decision log, allocates work, decides on failover, decides on stand-down. Final authority during the incident. | Debug, run commands, write customer comms. |
| **Operations Lead** | Runs the technical response. Translates the commander's decisions into actions. Is the single voice for what the system is doing. | Decide trade-offs that affect customers or data. |
| **Communications Lead** | Status page, customer notifications, internal stakeholder updates, executive briefing. Owns the cadence clock. | Technical investigation. |
| **Scribe** | Timeline, decision log entries, evidence capture, action items. | Anything that competes with writing things down. |
| **Subject Matter Expert** | Depth on one component. Joins and leaves as needed. | Broaden scope without the commander's agreement. |
| **Executive Liaison** | Shields the bridge from executive traffic. Answers upward so the commander does not have to. | Direct the response. |

### 3.1 Authority, stated explicitly

The Incident Commander may, without further approval, during a declared Sev1 or Sev2:

- Initiate a regional failover.
- Shed load, disable a feature, or enable a degraded mode.
- Roll back any deployment, including another team's.
- Scale any resource beyond its normal ceiling.
- Engage an external provider's escalation path.
- Declare that the error budget policy is suspended for the duration.

The commander may not, without named executive approval:

- Accept known permanent data loss.
- Make a public statement that admits liability.
- Disable a security control.

These two lists are the whole point. Without them, the 45-minute RTO is unreachable, because the first 20 minutes go to finding somebody who is allowed to say yes.

## 4. Communication cadence

The Communications Lead owns a clock and publishes whether or not there is news. "No change, next update at HH:MM" is a valid and valuable update. Silence is read as loss of control.

| Severity | Internal bridge update | Stakeholder update | Customer or status page | Executive brief |
|---|---|---|---|---|
| Sev1 | Every 15 min | Every 30 min | Initial within 15 min of declaration, then every 30 min | At declaration, then hourly |
| Sev2 | Every 30 min | Every 60 min | On confirmed customer impact, then hourly | At declaration, then on change |
| Sev3 | Not applicable | Daily while open | Only if customers notice | Not applicable |

The first customer communication goes out before root cause is known. It states what is affected, what customers will experience, what is being done and when the next update comes. It does not state a cause. Causes stated early are usually wrong, and retracting one costs more trust than the outage did.

## 5. Decision log

Kept live by the Scribe, in the incident channel, in a fixed format. Its purpose is not the post-incident review. Its purpose is that the person taking over at hour four can see why the system is in the state it is in.

```
[HH:MM UTC] DECISION #n
  Decision   : Failover of the order journey to the recovery region
  Owner      : IC (name)
  Rationale  : Primary region Aurora writer unreachable 9 min, no recovery
               trend, 62 percent of 30-day error budget consumed
  Reversible : No, failback is a separate planned operation
  Expiry     : Re-evaluate at 14:30 if traffic shift is not complete
  Evidence   : <link to dashboard snapshot, trace id, query>
```

Four fields carry the weight. **Reversible** forces the commander to say out loud whether a door is being closed. **Expiry** stops a decision taken under one set of facts from silently governing a different set an hour later. **Rationale** records the facts available at the time, which is what makes the post-incident review honest instead of retrospective. **Evidence** is what makes the record defensible.

Observations, as distinct from decisions, are logged in the same channel with an `OBS` prefix and a timestamp. The distinction matters because reviews that conflate the two produce the conclusion that somebody should have known, when in fact nobody did.

## 6. Escalation

Escalation is time-triggered, not judgement-triggered. The person on the bridge does not have to decide whether things are bad enough to call for help. The clock decides.

| Elapsed | Trigger | Action |
|---|---|---|
| T+0 | Page acknowledged | Responder assesses, declares or stands down within 5 min |
| T+5 | Not acknowledged | Secondary on-call paged |
| T+10 | Secondary not acknowledged | On-call manager paged, and the full rotation is notified |
| T+15 | Sev1 with no identified mitigation path | Engineering leadership engaged, SMEs for every component on the journey pulled in |
| T+30 | Sev1 still unmitigated | Regional recovery decision is formally put to the commander, who must record a decision either way. Not deciding is not an option at T+30. |
| T+45 | Sev1 still unmitigated | Executive Liaison engaged. Commercial and legal notified if a contractual commitment is at risk. |
| Any | Confirmed data loss, security exposure, or regulatory implication | Immediate escalation regardless of elapsed time |

The T+30 row is deliberate. The stated RTO is 45 minutes. If the failover decision is not forced onto the table at T+30, the decision, the data promotion and the traffic shift cannot all fit inside 45 minutes. Section 04 decomposes the 45 minutes and shows why.

## 7. Evidence capture

Telemetry ages out, dashboards change and the exact query that showed the problem is forgotten. Evidence is captured while the incident is live, by the Scribe, against a standing checklist.

| Evidence | Captured when | Why it cannot wait |
|---|---|---|
| Dashboard state at declaration | T+5 | Auto-refresh destroys the view that triggered the page |
| Representative trace identifiers for failing and succeeding requests | On identification | High-cardinality trace data has the shortest retention |
| The exact log query and its time bounds | On use | A query reconstructed later rarely reproduces the result |
| Deployment and configuration change history for the window | T+10 | Establishes or rules out change causation early, which is the highest-yield question in the first 10 minutes |
| External provider status, captured as a snapshot, plus the service's own probe results | On suspicion | Provider status pages are edited retroactively |
| Resource saturation metrics at the moment of impact | T+15 | Aggregation rollups lose the resolution that shows a brief saturation spike |
| Decision log and timeline | Continuous | Cannot be reconstructed at all |

Captured evidence is written to immutable storage with a retention period longer than the incident review cycle and the longest plausible contractual dispute. Provider-native implementation is specified in section 02.

## 8. Handover

Incidents outlive shifts. An unstructured handover is where the 45-minute RTO goes to die, and it is also where an incident quietly loses its commander without anyone noticing. Handover is an explicit, acknowledged transfer, spoken aloud on the bridge and written in the channel.

```
HANDOVER at [HH:MM UTC]
  Outgoing IC      : (name)        Incoming IC : (name)
  Severity         : Sev1, unchanged since 11:20
  Customer impact  : Order submission failing for approximately 18 percent
                     of sessions, EU customers only
  Error budget     : 71 percent of the 30-day budget consumed
  Current theory   : Connection pool exhaustion on the order service,
                     not yet confirmed
  Ruled out        : Deployment causation (last deploy 31 hours ago),
                     external provider A (probes green throughout)
  In flight        : Pool size increase rolling out, ETA 11:55
  Open decisions   : Whether to fail over if the pool change does not hold
                     by 12:15, see DECISION #7 expiry
  Next update due  : 11:50 internal, 12:00 status page
  Acknowledged     : Incoming IC confirms on bridge
```

The **Ruled out** line is the one most often skipped and the one that saves the most time. Without it the incoming commander re-investigates the deployment and the external provider, which is 20 minutes spent arriving at a conclusion that was already reached.

Handover is complete only when the incoming commander states acknowledgement on the bridge. Until then the outgoing commander still holds the role. A handover assumed is a handover with no commander.

## 9. After the incident

| Trigger | Required within | Output |
|---|---|---|
| Any Sev1 | 5 business days | Blameless review, written, published internally |
| Any Sev2 that consumed more than 10 percent of a journey's error budget | 10 business days | Blameless review |
| Any incident where detection took longer than its journey's target detection time | With the review | A specific observability action item, owned, with a date |
| Any incident mitigated by an undocumented manual action | With the review | Either a runbook entry or an automation item in the backlog |

Review actions enter the same prioritised backlog as everything else in section 06 and are scored the same way. They do not get a privileged lane. Privileged lanes are how a reliability backlog fills with items nobody believes in.

Two review rules that matter more than the template:

1. **Every review states the detection time and the time to mitigate separately.** Mean time to recovery as a single number hides which half of the problem the organisation actually has. The scenario says detection is slow, and that conclusion is only reachable if the two are measured apart.
2. **Counterfactuals are banned from the review.** "Should have noticed" is not a finding. "The signal that would have shown this was not collected, and here is the item to collect it" is a finding.
