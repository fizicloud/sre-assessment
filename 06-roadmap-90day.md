# 06. Program roadmap, metrics and governance

Weight: 10 percent.

Two things are asked here. A prioritised 90-day backlog driven by risk and toil data, and a governance model that stops SRE becoming an operations dumping ground. The second is the harder of the two and it is placed first, because a backlog handed to a team with the wrong operating model gets delivered once and then decays.

> The 90-day backlog table in section 3 is populated with provider-native work items once the cloud selection is fixed. The scoring method, the governance model and the metrics in sections 1, 4 and 5 are provider-independent by design and are complete.

## 1. Prioritisation method

Reliability backlogs fail in a predictable way. They are written as a list of good ideas, ordered by whoever argued hardest, and then compete against feature work on an uneven footing. The fix is a score that a product manager can read and that survives being challenged.

### 1.1 The score

Every candidate item gets a single number.

```
Priority = (Risk x Toil Relief) / Effort

Risk          = Likelihood x Impact x Detection Gap
Toil Relief   = hours per month of manual work removed, plus 1
Effort        = engineer-weeks to deliver, minimum 0.5
```

The factors, each on a 1 to 5 scale:

| Factor | 1 | 3 | 5 |
|---|---|---|---|
| **Likelihood** | Has not occurred, no leading indicator | Plausible, leading indicators present | Has occurred in the last 12 months, or is occurring now |
| **Impact** | Internal only, no customer effect | One journey degraded for a subset | A scored Tier 1 journey down for all customers, or data loss |
| **Detection Gap** | Detected and alerted in under 1 minute | Detected in minutes, alert exists but is noisy or unrouted | Not detected until a customer reports it |

**Detection Gap is the factor that makes this scoring model fit this scenario.** The brief states slow detection of customer-impacting failures. Standard risk scoring is likelihood times impact, which ranks a well-monitored catastrophic risk above a silent moderate one. That ranking is wrong for an organisation whose stated problem is that it finds out late. Multiplying by the detection gap promotes the failures nobody can currently see, which is exactly the backlog this service needs.

### 1.2 Toil data, and how it is actually gathered

Toil Relief requires real numbers, and "we think this takes a while" is not a number. Toil data is collected in the first two weeks by three means, because any one of them alone is biased:

1. **Pager and ticket archaeology.** Every alert that fired and every ticket raised in the last 90 days, grouped by the action taken to resolve it. Repeated identical actions are toil by definition.
2. **A two-week on-call diary.** Each responder records what they did and how long it took. This catches the work that never generates a ticket, which is usually the majority of it.
3. **Automation gap review.** Every runbook step that is a human executing a deterministic command. These are toil whether or not anyone has complained about them.

The output is an hours-per-month figure per recurring task, with the team that bears it. This figure does double duty. It feeds the score, and it is the evidence base for the toil cap in section 4.

### 1.3 What the score does not decide

The score ranks. It does not sequence. Three overrides apply, and they are stated so that overriding is visible rather than quiet:

1. **Dependency order.** An item that another item requires is scheduled first regardless of score. Burn-rate alerting cannot precede the SLI definitions it measures.
2. **The first game day is not negotiable.** DR has never been exercised end to end. Until it has been, every RTO and RPO figure in this document is an assertion. No score can outrank converting an assertion into a measurement.
3. **An item that only reduces toil for the SRE team, and does nothing for customers, is capped at medium priority.** This prevents the function optimising its own comfort ahead of the service.

## 2. Shape of the 90 days

Three 30-day blocks, each with a single theme and an exit criterion. The exit criterion matters more than the item list, because it is what prevents a block being declared complete on the basis of activity.

| Block | Theme | Exit criterion |
|---|---|---|
| Days 1 to 30 | **See it.** Measurement, journey SLIs, symptom alerting, toil baseline. | Every scored journey has a published SLI, an SLO and burn-rate alerting. The detection time for a synthetic induced failure is measured, not estimated. |
| Days 31 to 60 | **Survive it.** Retry budgets, timeouts, idempotency, circuit breaking, load shedding. | A deliberate dependency failure, injected in a controlled test, does not propagate into a retry storm. Proven by experiment, not by code review. |
| Days 61 to 90 | **Recover from it.** DR exercised end to end, incident command in force, failback proven. | A regional failover has been performed under game-day conditions and the measured RTO and RPO are recorded against the 45-minute and 5-minute targets. |

The ordering is deliberate and it is the opposite of what the symptom list invites. The loudest pain is the retry storms, so the instinct is to start with resilience. Starting there is a mistake, because without journey SLIs there is no way to prove a resilience control worked. Block 1 buys the instrumentation that makes blocks 2 and 3 measurable. The cost of that ordering is that the retry-storm risk stays live for the first 30 days, so two interim mitigations ship inside block 1 as risk reduction: concurrency ceilings and a client retry cap. Both are small, and neither requires the measurement that is still being built.

## 3. The prioritised backlog

> Populated with provider-native items, owners and dependencies once the cloud selection is fixed. Each item carries its Likelihood, Impact, Detection Gap, Toil Relief, Effort and computed Priority score, scored by the method in section 1.

## 4. Governance: keeping SRE out of the dumping ground

This is the part of the brief that is a judgement question rather than a design question. The failure mode is well known. A reliability function is created, it is the only group that understands production, work flows to it because it is competent, and within two quarters it is a second-line operations team carrying other teams' pagers and has no capacity left for engineering. Every item below exists to interrupt a specific step in that sequence.

### 4.1 The engagement model

SRE accepts work through four doors and no others. The list is published, and work that arrives outside it is declined with a reason and a redirection.

| Door | What it is | Bounded by |
|---|---|---|
| **Platform** | Capabilities SRE builds, owns and operates: the telemetry pipeline, the SLO tooling, the failover controls, the game-day harness. | SRE is on the pager for these, permanently and properly. |
| **Embedded consulting** | An SRE joins a delivery team for a fixed term to build a capability with them. | A written start date, end date and exit criterion. The team operates the result. |
| **Incident command** | SRE supplies the Incident Commander function for Sev1 and Sev2. | Commanding, not fixing. See section 05. |
| **Standards and review** | SLO definition, architecture review, post-incident facilitation, readiness assessment. | Advisory. SRE does not hold the resulting actions. |

What is explicitly declined: carrying the production pager for a service SRE does not own, routine operational request queues, manual deployments, access and permission administration, and being the default assignee for any alert nobody else has claimed. Each refusal names the owner it belongs to. A refusal without a destination is just an argument.

### 4.2 The exit criterion rule

Every embedded engagement is written down before it starts with three fields: what capability the team will hold at the end, how that will be demonstrated, and the date. Engagements without an exit criterion become permanent ownership transfers. This single rule prevents more dumping than any other item here, because the dumping ground is almost never built deliberately. It accretes one helpful exception at a time.

### 4.3 The error budget policy, with consequences

A policy with no consequence is a dashboard. The policy is agreed with product leadership before it is ever invoked, because the moment to negotiate is not the moment it first bites.

| Budget state, 30-day rolling | Consequence |
|---|---|
| Above 50 percent remaining | Normal delivery. Ship freely. |
| 25 to 50 percent remaining | Reliability items take priority in the owning team's next sprint. Deployment freeze on high-risk changes to the affected journey. |
| Under 25 percent remaining | Feature work on the affected journey stops. The team's capacity goes to reliability until the budget recovers. Progressive delivery becomes mandatory. |
| Exhausted | As above, plus a written remediation plan signed off by the service owner and engineering leadership before feature work resumes. |
| Exhausted twice in two consecutive quarters | The journey's SLO target itself is reviewed. Either the target is wrong or the architecture cannot support it. Both are findings worth having. |

The last row is not a loophole. It is the honest recognition that a target missed repeatedly is information, and continuing to fail against it while blaming execution helps nobody.

**This policy is the actual anti-dumping-ground mechanism.** The reason reliability work flows to SRE is that delivery teams face no consequence for shipping unreliable software, and SRE absorbs the difference. Attach the consequence to the team that owns the code, and the incentive to hand the problem over disappears. Everything else in this section is supporting structure. This is the load-bearing part.

### 4.4 The toil cap

SRE measures its own toil ratio and publishes it. When it exceeds 50 percent of the team's capacity in any month:

1. The overage is reported to engineering leadership with the specific tasks and their hours.
2. SRE has the standing right to hand the lowest-value toil back to its owning team, with notice, without negotiating.
3. The next sprint's automation work is protected capacity.

The right to hand work back has to be granted in advance and in writing. Asked for in the moment, it reads as a complaint. Granted in advance, it is a control.

### 4.5 Ownership, stated plainly

| Owns | Who |
|---|---|
| Service availability, its SLO, its error budget | The delivery team that owns the service |
| Production pager for a service | The delivery team that owns the service |
| Reliability engineering standards and tooling | SRE |
| Platform capabilities and their pager | SRE |
| Incident command function | SRE |
| The decision to spend error budget | Product owner and delivery team jointly |
| The decision to invoke the error budget policy | SRE, non-discretionary, triggered by measurement |

The last two rows are a deliberate separation. Spending the budget is a product decision. Declaring that it has been spent is a measurement, and measurements are not negotiated. Blurring the two is how error budget policies die quietly.

## 5. Metrics for the reliability programme

Measuring the SRE function by ticket throughput guarantees the dumping ground, because it rewards absorbing work. These metrics reward removing it.

| Metric | Target by day 90 | What it would catch |
|---|---|---|
| Scored journeys with a published SLI and SLO | 100 percent of Tier 1 journeys | Reliability work proceeding without a definition of reliable |
| Median detection time for customer-impacting failure | Under 2 minutes, measured by injection | The stated problem in the brief, tracked as a number |
| Alert precision, meaning the share of pages that were actionable | Above 80 percent | Alert fatigue, which is the other half of slow detection |
| SRE toil ratio | Under 40 percent | The dumping ground forming, early |
| Services where SRE holds the pager but not the code | Zero | The clearest single indicator of misplaced ownership |
| Error budget policy invocations, and compliance with them | Tracked, with zero unexplained overrides | A policy quietly becoming advisory |
| Tier 1 journeys covered by an exercised DR test | 100 percent | Recovery capability that exists only on paper |
| Post-incident action items closed within 30 days | Above 90 percent | Reviews producing paperwork instead of change |
| Change failure rate on the Tier 1 journey | Trending down | Reliability improvements being offset by delivery risk |

Two of these are deliberately uncomfortable. **Services where SRE holds the pager but not the code** has a target of zero and will not be zero on day one, which is the point. **Alert precision** requires every page to be dispositioned as actionable or not, which is a small recurring cost that most teams skip and then wonder why nobody trusts the alerts.

### 5.1 Governance cadence

| Forum | Frequency | Decides |
|---|---|---|
| Error budget review | Weekly, per journey | Whether the budget policy is triggered. A measurement readout, not a discussion. |
| Reliability backlog review | Fortnightly | Re-scoring, sequencing, and which items enter the next sprint |
| Operational review | Monthly | Toil ratio, alert precision, pager load, ownership exceptions |
| Reliability steering | Quarterly | SLO target changes, investment decisions, the Option A to Option B transition from section 00 |

The weekly error budget review is intentionally boring. It reads the number and applies the policy. Forums that debate whether the number is fair are forums that eventually stop applying the policy.

## 6. What happens after day 90

Recorded so that the 90-day plan is visibly a first increment and not a complete answer.

1. **Move from Option A to Option B in section 00.** Active-active with automated traffic shift, which is the only configuration that makes 99.99 percent and regional recovery arithmetically compatible.
2. **Continuous fault injection in pre-production, then production.** Appropriate once DR has been exercised manually and the resilience controls have been proven individually.
3. **Extend the model to Tier 2 services** using the same scoring and the same governance, run by the delivery teams with SRE advising.
4. **Dependency SLO negotiation with the external providers.** Contractual availability and incident communication commitments, informed by a quarter of the service's own probe data on their actual behaviour.
