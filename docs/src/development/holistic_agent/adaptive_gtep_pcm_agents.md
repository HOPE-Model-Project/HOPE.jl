# [Adaptive GTEP, Realization, and PCM Agents](@id adaptive-gtep-pcm-agents)

## Status and purpose

This document proposes the next HOPE-AI scientific workflow after the validated
deterministic GTEP-to-PCM composite tool. It is a design specification, not an
implemented agent system.

The motivating study pattern is iterative:

1. GTEP produces a zonal capacity plan using planning abstractions such as a
   planning reserve margin.
2. A realization process converts that plan into one or more nodal physical
   systems suitable for PCM.
3. PCM tests chronological operation at higher spatial and temporal resolution.
4. An independent verifier determines whether the evidence satisfies a
   predeclared study-acceptance contract.
5. If it does not, the responsible layer proposes a traceable revision. The
   workflow repeats until it passes, reaches an approved stopping condition, or
   returns to a human decision maker.

The existing deterministic linkage remains the computational foundation. It
provides identities, fingerprints, immutable artifacts, conservation checks,
and provenance. Agents add scientific diagnosis and controlled revision; they
do not replace those contracts or move numerical data through conversation.

## Central design decision

A zonal GTEP solution does not generally imply one uniquely correct nodal PCM
system. Downscaling must be treated as a constrained scientific realization
problem with explicit data, objectives, and uncertainty.

The realization layer should support two policy families:

- **Declared realization:** a case supplies known candidate locations, as in the
  current `explicit_bus` Maryland benchmark. The linkage verifies and applies
  the declaration deterministically.
- **Computed realization:** a versioned method allocates zonal builds among
  eligible physical sites or buses. The method may produce several diverse,
  defensible realizations when the evidence does not identify one unique answer.

Both policies must be reproducible. Given the same parent artifacts, method
version, parameters, solver settings, and tie-breaking rule, the same
realization artifacts should be produced within declared numerical tolerances.
This is determinism at the workflow and data-contract level; it does not imply
that the physical siting assumption is uniquely true.

## Proposed scientific architecture

```text
User and human approvals
          |
          v
HOPE Study Agent
  pins objectives, scenarios, acceptance criteria, budget, and authority
          |
          v
GTEP Agent ---- publishes ----> CapacityPlan
          |                         |
          |                         v
          |                 Realization Agent
          |                         |
          |                         v
          |                 RealizationSet
          |              (one or more PhysicalSystems)
          |                         |
          |                         v
          |                     PCM Agent
          |                         |
          |                         v
          |              OperationalAssessment
          |                         |
          |                         v
          +<---- RevisionRequest -- Verifier / Reliability Gate
                                    |
                                    v
                         ACCEPTED or HUMAN_REVIEW
```

The scientific roles and workflow-governance roles are separate dimensions. A
GTEP specialist can still operate through a centralized, durable workflow, and
the verifier must remain independent of the agent that proposed a change.

## Deterministic realization engine

The realization agent should not invent bus assignments in prose. It should
construct or select a versioned `RealizationPolicy`, call a deterministic
realization engine, inspect its evidence, and explain or revise the policy.

### Required inputs

| Artifact | Required content |
| --- | --- |
| `CapacityPlan` | GTEP run and input hashes; zonal build, retirement, storage, and transmission decisions; planning assumptions and units |
| `ReferenceNetwork` | Stable bus, branch, zone, voltage, rating, and existing-asset identities with data provenance |
| `CandidateSiteCatalog` | Candidate site or bus ID, technology eligibility, zone, maximum MW/MWh, interconnection limit and cost, resource quality, exclusions, evidence, and confidence |
| `OperationalTemplateRegistry` | Unit sizes, minimum output, ramping, minimum up/down time, outage, startup, reserve, emissions, and storage parameters by reviewed technology template |
| `RealizationPolicy` | Method and version, objective terms, constraints, weights, unitization rules, diversity settings, solver, tolerances, and deterministic tie-breaker |
| `StudyAcceptanceContract` | Operational and reliability gates, evaluation horizons, allowed revisions, approvals, iteration limit, and compute budget |

### Constrained allocation

A first computed realization method can minimize reviewed siting,
interconnection, network-stress, fragmentation, and assumption penalties subject
to constraints such as:

- exact conservation of selected zonal generation MW and storage MW/MWh;
- technology and zone eligibility;
- candidate-site and interconnection capacity;
- discrete or bounded unitization where required;
- stable physical identities and valid network references;
- retirement and transmission realization rules;
- geographic, land, environmental, or policy exclusions supplied by the study;
- operational-template availability; and
- any approved fast deliverability screen.

The objective is a study assumption and must be versioned. Its weights must not
be hidden in an agent prompt.

### Multiple realizations

When siting is underdetermined, the engine should publish a `RealizationSet`
rather than conceal the ambiguity. A set may contain the best solution under the
declared objective plus deterministic alternatives generated with diversity
constraints, for example different host buses, corridors, or geographic
concentrations.

Each member records:

- its parent `CapacityPlan` and input hashes;
- complete candidate-to-unit-to-bus lineage;
- method, version, parameters, solver, and tie-breaker;
- objective components and binding constraints;
- unresolved mappings, warnings, and confidence;
- fast-screen results; and
- why it differs from other members.

This supports two distinct scientific questions: whether a plan has at least
one viable realization, and whether it is robust across plausible
realizations.

### Screening sequence

Expensive PCM solves should follow progressively stronger deterministic checks:

1. schema, units, identity, and capacity conservation;
2. topology, connectivity, and operational-template completeness;
3. static or reduced network deliverability checks;
4. selected stress-hour or reduced-chronology screening; and
5. full approved PCM horizon.

A fast screen may reject an invalid realization, but only the acceptance
contract determines what evidence is sufficient for the final study claim.

## Acceptance is broader than PCM feasibility

PCM infeasibility is evidence, not a diagnosis. It may result from a genuinely
inadequate plan, an impossible nodal realization, incompatible operational
parameters, bad chronology, a contract error, or numerical failure. Conversely,
a feasible deterministic PCM run does not by itself prove a probabilistic
reliability standard.

The `StudyAcceptanceContract` must be pinned before the first solve and separate
at least these gates:

| Gate | Example evidence |
| --- | --- |
| Artifact integrity | Valid schemas, hashes, identities, units, calendars, and parent lineage |
| Realization fidelity | Zonal decisions conserved; every physical asset and network change reconciled |
| Model solvability | Accepted solver termination and feasible primal solution |
| Operational adequacy | Unserved energy, reserve shortfall, overload, curtailment, ramping, storage, and policy thresholds over the declared horizon |
| Reliability | Study-defined deterministic contingencies or probabilistic metrics such as LOLE/EUE, when a suitable evaluator is included |
| Scientific governance | No unresolved high-severity findings; all material changes approved; final audit passed |

The criterion, horizon, and tolerance belong in the contract. An agent must not
make a failed run pass by silently relaxing a reliability threshold, enabling
load shedding, changing a penalty, or shortening the evaluation horizon.

## Diagnosis and revision routing

Every failed gate should first create a structured `Finding`. A diagnosis step
then assigns the narrowest responsible layer. The workflow should try the
lowest-authority scientifically valid change before modifying an upstream model.

| Failure class | Typical evidence | First responsible role | Permitted first response |
| --- | --- | --- | --- |
| Contract or data error | Missing IDs, incompatible units, incomplete chronology, stale parent hash | Artifact owner / human data steward | Correct or replace the invalid artifact; do not reinterpret it conversationally |
| Numerical or software failure | Solver error, numerical instability, resource exhaustion | Model agent plus runtime operator | Retry only under an approved numerical policy; otherwise stop for review |
| Realization-local | Bus overload, implausible concentration, site-cap violation, invalid unitization with zonal totals otherwise adequate | Realization agent | Propose a new policy or alternative mapping while preserving the `CapacityPlan` |
| PCM-assumption-local | Missing or inappropriate operating template, initial state, outage, reserve eligibility, or chronology input | PCM agent | Correct an owned operational assumption within its approved range |
| Planning-structural | Persistent firm-capacity, flexibility, storage-duration, interface, or resource-location deficiency across defensible realizations | GTEP agent | Propose a new planning constraint, candidate, cost, capacity credit, reserve rule, or scenario assumption |
| Acceptance-policy conflict | Required standard cannot be met under the authorized model scope or budget | Study agent and human | Clarify the research question, approve expanded scope, or stop without a false-safe conclusion |

The router should use evidence across several realizations before blaming GTEP.
For example, one congested bus assignment is a realization problem; repeated
congestion across diverse defensible assignments may justify a planning-level
transmission or location constraint.

## Revision contract

Agents may propose changes; deterministic tools apply approved changes. No
agent may directly mutate an accepted parent artifact. Every revision creates a
child scenario and a machine-readable delta.

A `RevisionRequest` should include fields similar to:

```yaml
artifact_type: HOPE.revision_request
schema_version: 1
request_id: revision-uuid
study_id: future-2035
iteration: 2
finding_ids: [finding-017, finding-021]
requested_owner: gtep
classification: planning_structural
parent_artifacts:
  capacity_plan: {artifact_id: plan-001, sha256: "..."}
  realization_set: {artifact_id: realization-set-003, sha256: "..."}
  operational_assessment: {artifact_id: pcm-assessment-006, sha256: "..."}
evidence:
  metric: reserve_shortfall_mwh
  observed: 418.2
  threshold: 0.0
  scope: "July peak and ramping hours; all three approved realizations"
proposed_changes:
  - path: planning.reserve_requirement.upward
    before: 0.07
    after: 0.09
    rationale: "..."
expected_effect: "increase planning procurement of flexible capacity"
alternatives_considered: ["additional storage duration", "interface expansion"]
approval_class: material_planning_assumption
status: proposed
```

The request must distinguish an observed result from an inferred cause and a
proposed remedy. The GTEP agent may accept, reject, or replace the proposal with
another documented change; it must not treat a PCM agent's inference as an
authoritative planning instruction.

## Agent authority

| Role | May do | Must not do without escalation |
| --- | --- | --- |
| Study agent | Define the workflow from an approved study specification; track iterations, budget, and approvals; assemble final evidence | Change scientific thresholds or publish a failed study as successful |
| GTEP agent | Diagnose planning evidence; propose and run allowlisted GTEP case revisions; publish a `CapacityPlan` and delta | Alter physical realization or PCM outputs; silently change policy, demand, costs, or the research objective |
| Realization agent | Select or propose a reviewed realization policy; run the deterministic allocator; publish and compare physical realizations | Change zonal build totals, invent unregistered sites, or hide ambiguity |
| PCM agent | Build validated PCM cases from a `PhysicalSystem`; diagnose operations; propose owned input corrections; publish an `OperationalAssessment` | Change GTEP decisions, physical sites, or acceptance criteria |
| Verifier / reliability gate | Read authoritative artifacts; recompute checks; classify findings; issue acceptance or revision evidence | Repair the case it evaluates or waive a failed gate |
| Human approver | Approve material assumptions, scope, budgets, topology/data substitutions, and publication | Approval is recorded as evidence; it must not be inferred from silence |

Agent knowledge should be explicit and reviewable: model documentation,
formulation and data schemas, diagnostic playbooks, approved change templates,
case provenance, and prior validated findings. Conversational memory is not a
substitute for those sources.

## Human-in-the-loop policy

Human approval should be required when a revision changes any of the following:

- policy targets, reliability thresholds, demand, fuel or technology costs;
- planning reserve or capacity-credit methodology;
- candidate technologies, sites, network topology, or external data source;
- model formulation rather than an allowlisted case parameter;
- evaluation horizon or accepted data quality;
- an established compute or iteration budget; or
- the final publication decision after unresolved warnings.

Routine retries, status checks, deterministic transformations, and changes
within an explicitly approved parameter envelope need not require repeated human
approval.

## Iteration, convergence, and stopping

An adaptive study is a lineage of immutable attempts, not one case directory
edited repeatedly:

```text
SPECIFIED -> GTEP_SOLVED -> REALIZED -> PCM_SOLVED -> VERIFIED
                                                |          |
                                                |          +-> ACCEPTED
                                                |
                                                +-> REVISION_REQUESTED
                                                          |
                         APPROVED_CHILD_SCENARIO <---------+
```

The workflow converges only when all hard gates in the pinned acceptance
contract pass and no high-severity finding remains unresolved. A lower cost or
smaller violation is not convergence if a hard reliability criterion still
fails.

It must stop safely when any of these occurs:

- acceptance;
- the approved iteration or compute budget is exhausted;
- no authorized revision addresses the findings;
- successive iterations cycle or fail to make declared progress;
- the necessary change exceeds an agent's authority; or
- a human pauses or terminates the study.

The terminal result may be `ACCEPTED`, `NOT_ACCEPTED`, or `INCONCLUSIVE`.
`INCONCLUSIVE` is preferable to silently weakening the criterion.

## Recommended first vertical slice

The first scientific-agent implementation should be deliberately narrower than
the final architecture:

1. Freeze the current explicit-bus composite tool as the reference baseline.
2. Define version-1 `CapacityPlan`, `CandidateSiteCatalog`, `RealizationPolicy`,
   `RealizationSet`, `OperationalAssessment`, `Finding`, `RevisionRequest`, and
   `StudyAcceptanceContract` schemas.
3. Implement one deterministic computed-siting method alongside
   `explicit_bus`; do not remove the validated method.
4. Generate a small number of diverse nodal realizations for one zonal GTEP
   plan and run fast deliverability screens before July PCM.
5. Support two feedback routes:
   - realization-local resiting with unchanged zonal totals; and
   - one reviewed planning-structural request, such as additional firm/flexible
     capacity or an interface constraint.
6. Limit the loop to three iterations and require human approval for every GTEP
   assumption change.
7. Evaluate whether the agents diagnose the correct layer, preserve provenance,
   avoid unauthorized changes, and improve acceptance—not whether additional
   conversational roles appear productive.

July PCM can establish the first operational acceptance workflow, but it must
not be labeled a complete probabilistic reliability study. A later milestone
can add annual or rolling operation, contingency analysis, EREC, or another
validated reliability evaluator under its own contract.

## What not to build

- Do not let agents edit shared CSV files in place.
- Do not pass capacity plans or PCM results only through natural-language
  messages.
- Do not let the PCM agent directly change GTEP assumptions.
- Do not treat one arbitrary nodal allocation as the unique physical truth.
- Do not equate solver feasibility with reliability acceptance.
- Do not let an agent relax a threshold in order to declare success.
- Do not rerun indefinitely; revisions require lineage, budgets, and stopping
  rules.
- Do not add agent roles where a deterministic validator or optimizer is the
  appropriate mechanism.

## Design outcome

The target is not three autonomous chatbots. It is an adaptive scientific
workflow in which specialized agents diagnose and propose, deterministic HOPE
tools transform and solve, immutable artifacts communicate, an independent
verifier judges evidence, and humans retain authority over material scientific
changes.
