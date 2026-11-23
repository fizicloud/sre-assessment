# 00. Scope, assumptions and exclusions

Selected cloud: **Amazon Web Services**, used consistently throughout. See [`README.md`](README.md) for the selection rationale.

## 1. How to read this submission

The scenario gives six tasks and a set of hard constraints. Two of those constraints cannot all be true at once as written. This section does the arithmetic first, because every design decision in the later sections follows from it. A reliability plan that restates the targets without testing them is not a plan.

## 2. Constraint analysis

### 2.1 The stated constraints

| Constraint | Stated value |
|---|---|
| Customer journey availability | 99.99 percent |
| RTO, critical data set | 45 minutes |
| RPO, critical data set | 5 minutes |
| External dependencies | Two third-party providers |
| Scope of controls | Application, platform and external dependencies |

### 2.2 Error budget arithmetic

99.99 percent availability over a 30-day rolling window permits 4.32 minutes of unavailability per window.

```
30 days            = 43,200 minutes
Permitted downtime = 43,200 x 0.0001
                   = 4.32 minutes per 30-day window
```

For a 28-day window the budget is 4.03 minutes. This submission uses a 30-day rolling window and states the figure as 4.32 minutes throughout.

### 2.3 Finding 1: the RTO exceeds the entire error budget by a factor of ten

A 45-minute RTO means the business accepts 45 minutes of unavailability during a regional recovery event.

```
45 minutes / 4.32 minutes = 10.4
```

One exercised regional failover consumes 10.4 months of error budget. A target of 99.99 percent and a manual 45-minute regional recovery are therefore not describing the same system. They describe two different funding levels.

This is resolvable, and the resolution has to be explicit rather than silent:

| Option | What it means | Cost |
|---|---|---|
| A. Disaster clause | 99.99 percent applies to steady state. A declared regional disaster is excluded from the SLI under a written, pre-agreed clause with its own RTO and RPO objectives and its own reporting line. | Governance effort only. |
| B. Fund active-active | Drive actual regional recovery to single-digit minutes through automated traffic shift and warm capacity in both regions, so recovery fits inside the budget. | Roughly double the steady-state platform spend. |
| C. Lower the target | Publish 99.9 percent for any window containing a declared regional event. | Commercial and contractual impact. |

**This submission adopts Option A as the near-term position and Option B as the 90-day direction.** The disaster clause is defined in section 01. The roadmap in section 06 funds the move toward Option B in priority order. Option C is recorded and rejected, because a Tier 1 service that advertises a weaker target during the exact window when it matters most is selling the wrong thing.

### 2.4 Finding 2: external providers cap the journey below the target

The journey depends on two external providers. Third-party providers typically publish 99.9 percent. If both sit on the synchronous critical path of the journey, the achievable ceiling is the product of the chain:

```
Internal platform   0.9999
External provider A 0.999
External provider B 0.999
                    -------
Journey ceiling     0.99790  = 99.79 percent
                             = 90.7 minutes downtime per 30-day window
```

90.7 minutes is 21 times the 4.32-minute budget. No amount of internal engineering recovers it. The target is unreachable by arithmetic, not by effort.

**Therefore the central architectural requirement of this plan is that neither external provider sits on the synchronous critical path of a scored customer journey.** Every provider interaction is one of the following:

1. Asynchronous, accepted to a durable queue and settled later.
2. Served from a cache or a last-known-good value with a stated staleness bound.
3. Degraded to a defined fallback that still satisfies the journey's success definition.

Where none of the three is possible for a given journey step, that step is excluded from the 99.99 percent journey SLI and given its own separate SLO with its own error budget. Section 01 states which journeys and steps fall into which category. This is the difference between a target that can be met and a target that is decorative.

### 2.5 Finding 3: the RPO is achievable, and it constrains the data tier

A 5-minute RPO is comfortably inside what managed cross-region replication delivers for the relational tier under normal conditions. It is not comfortable for the streaming tier, where consumer offset position, not just message durability, determines whether recovery loses work. Section 04 treats stream offset recovery as the binding constraint on RPO and designs for it explicitly.

## 3. Assumptions

These are assumptions, not findings. Each one is stated so a reviewer can challenge it and so the design can be re-derived if it is wrong.

| # | Assumption | Why it matters | If wrong |
|---|---|---|---|
| A1 | The service is customer-facing and revenue-bearing, with a commercial availability commitment behind the 99.99 percent figure. | Justifies Tier 1 spend and an error-budget policy with enforcement. | If the target is aspirational and uncontracted, Option C in 2.3 becomes viable and the roadmap shortens. |
| A2 | Two cloud regions are in scope, one active and one recovery, in the same geography and legal jurisdiction. | Determines the recovery topology and the data residency position. | A three-region or cross-jurisdiction requirement changes the data promotion design in section 04. |
| A3 | The two external providers are a payment or settlement provider and an identity provider. | These are the two most common Tier 1 externals and the two with the sharpest failure semantics. | Named providers with different semantics would change the fallback design in 2.4, not the method. |
| A4 | External providers offer no regional failover that the service controls, and their status is observable only through their own status endpoint and the service's own probes. | Drives synthetic probing of externals and the circuit-breaking design. | A provider with a contractual multi-region endpoint reduces the fallback requirement. |
| A5 | Existing alerting is symptom-poor and cause-rich, which is the usual reason for many alerts and slow detection. | Sets the direction of section 02 toward journey-level symptom alerting. | If alerts are already symptom-based, the problem is routing and thresholds, which section 02 also addresses. |
| A6 | The two retry-storm incidents originated inside the service's own call graph, not from client traffic. | Determines whether the fix is retry budgets and concurrency limits or edge rate limiting. | Client-origin storms shift emphasis to edge throttling, which section 03 covers as well. |
| A7 | There is at least one delivery team per bounded context and no existing platform or SRE team charter. | Shapes the ownership model and the anti-dumping-ground governance in section 06. | An existing SRE team changes the sequencing, not the model. |
| A8 | Change volume is normal for a Tier 1 product, with multiple deploys per week. | Makes change-related failure a first-class failure mode and progressive delivery a first-class control. | Low change volume reduces the weight of deployment controls. |

## 4. Exclusions

Stated so that absence is read as a decision and not as an oversight.

| # | Excluded | Reason |
|---|---|---|
| E1 | Detailed cost modelling with unit prices. | Prices change and vary by agreement. Cost is addressed as relative trade-off and as a named decision at each control, which is the part that survives a price change. |
| E2 | Application source code changes beyond interface contracts. | Resilience controls are specified as contracts that application teams implement. Specifying their internals would exceed the brief and the available information. |
| E3 | Compliance certification mapping to a named framework. | No regulatory regime is stated in the scenario, so a full control-by-control mapping would be invention. Security controls are included on their own merit. **Partial exception:** section 04.9 addresses BNM RMiT paragraph 10.32, because a Tier 1 service with a stated RTO and a 99.99 percent target has a hard regulatory ceiling behind those numbers in a Malaysian financial-institution context, and a recovery design that ignores it is incomplete. That section is scoped, sourced and explicitly marked as conditional on applicability. |
| E4 | Organisation-wide capacity and headcount planning. | The brief asks for reliability work to be balanced against delivery capacity, which section 06 does as a prioritisation and governance problem. Staffing proposals need information the scenario does not provide. |
| E5 | Migration of the existing estate to the target design. | The brief asks for a 90-day reliability backlog, not a re-platforming plan. The roadmap assumes the described architecture is already in production. |
| E6 | Chaos engineering beyond the defined game-day scope. | A continuous chaos programme is the right end state and is listed as a post-90-day item. Starting there before DR has ever been exercised once would be out of order. |

## 5. Known limitations of this submission

Carried forward into section 07, which states how each control would be validated and what remains unproven.

1. No access to the real service means failure modes are derived from the architecture and from the three symptoms stated in the scenario. A real engagement would start from incident history and trace data.
2. Threshold values and budgets are starting points chosen to be defensible, not values tuned against observed traffic. Section 07 states how each would be calibrated in the first 30 days.
3. The external providers are generic. Real provider contracts, rate limits and failure semantics would move the specifics of the fallback design.
