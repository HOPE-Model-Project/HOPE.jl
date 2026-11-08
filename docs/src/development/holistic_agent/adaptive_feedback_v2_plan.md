# Adaptive Feedback Contract v2

## Objective

The next milestone generalizes the successful Maryland r03 benchmark from one
known spatial correction into an evidence-driven diagnosis and revision system.
The goal is not to add more agents immediately. The goal is to define the
structured evidence, responsibility, and authorized actions that future GTEP,
realization, PCM, coordinator, and assessment agents can use safely.

## Baseline to freeze

The r03 study is the regression baseline. It must continue to verify:

- exactly two model launches;
- one evidence-backed revision request;
- one explicit human approval;
- one child iteration and one realization selection;
- the BGE-build/PEPCO-shortfall diagnosis;
- an independently accepted selected realization with zero load shedding; and
- trace integrity, call budgets, and immutable parent-child lineage.

Runs r01 and r02 remain development records. They document the evidence-interface
and process-completion issues found before the clean r03 replicate.

## Standard evidence contract

Each model layer should publish the evidence needed to assign ownership of a
failure without relying on free-form prose.

| Layer | Required evidence |
| --- | --- |
| GTEP | Capacity additions by zone and technology, planning load shedding, reserve position, binding policy and capacity constraints, objective and solver status |
| Realization | Planned capacity received, capacity successfully placed, unplaced capacity, selected buses/sites, rejection reasons, permitting/interconnection/environmental flags, and variant provenance |
| PCM | Load shedding by zone and hour, reserve shortage, congestion and interface stress, ramping/flexibility symptoms, emissions or policy violations, dispatch of new resources, objective and solver status |

## Failure taxonomy

Before proposing a change, the coordinator should classify the evidence as one
of the following:

- `SOLVER_FAILURE`;
- `PLANNING_CAPACITY_DEFICIT`;
- `SPATIAL_CAPACITY_MISMATCH`;
- `REALIZATION_SITING_INFEASIBLE`;
- `TRANSMISSION_CONGESTION`;
- `OPERATIONAL_FLEXIBILITY_DEFICIT`;
- `POLICY_OR_EMISSIONS_VIOLATION`; or
- `ACCEPTANCE_FAILED_OTHER`.

The Maryland r03 benchmark is a `SPATIAL_CAPACITY_MISMATCH`: GTEP adds capacity
in BGE while all PCM realizations identify the operational shortfall in PEPCO.

## Controlled revision proposal

A revision request should contain:

- the failure classification;
- authoritative evidence paths and summarized values;
- the responsible model layer;
- the parameter or contract field to change;
- old and proposed values;
- controls explicitly held fixed;
- the expected causal effect;
- the approval requirement;
- the iteration budget and stop condition; and
- rollback/provenance information.

The coordinator must not change several unrelated assumptions simply to obtain a
passing run. A revision should be the smallest authorized intervention supported
by the evidence.

## Authorized action catalog

Initial typed actions should include:

- change generation candidate-zone eligibility;
- change candidate technology eligibility;
- revise a declared firm-capacity envelope;
- request new realization alternatives;
- add or enable an approved storage/flexibility candidate;
- enable an approved transmission candidate; and
- escalate an assumption change for human review.

The catalog should state which agent owns each action and which actions always
require human approval.

## Next independent validation case

The next benchmark should test a different mechanism: an operational-flexibility
deficit. GTEP should have enough nominal capacity and meet its planning adequacy
criteria, while PCM fails during stressed hours because the portfolio lacks
ramping, fast-start, or storage capability.

The correct response should change a flexibility or technology contract—not the
candidate zone, total load, or acceptance threshold. This tests whether the
agent chooses an action from evidence instead of repeating the Maryland spatial
correction.

## Agent separation after the contract

Once the v2 contract is stable, responsibilities can be separated into:

- a GTEP agent for investment adequacy and planning assumptions;
- a realization agent for nodal siting alternatives and feasibility evidence;
- a PCM agent for chronological operational diagnosis;
- assessment agents for reliability, emissions, air quality, or other holistic
  gates;
- a coordinator for state, iteration, and approval governance; and
- a human reviewer for consequential changes.

The structured contract should precede this split. Otherwise, additional agents
would exchange interpretations without a precise definition of evidence,
authority, or permitted action.

## Deliverables

1. Freeze r03 as an automated regression benchmark.
2. Define schemas for evidence, failure classification, and revision proposals.
3. Implement diagnostic classification and action validation.
4. Add no-progress, rollback, and iteration-budget termination rules.
5. Build the operational-flexibility benchmark.
6. Only then expose separate role-specific agent tools.
