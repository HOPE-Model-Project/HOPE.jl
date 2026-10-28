# [Adaptive Holistic Assessment Agents](@id adaptive-gtep-pcm-agents)

## Status and purpose

This document proposes an adaptive holistic-assessment framework for HOPE-AI
after the validated deterministic GTEP-to-PCM composite tool. GTEP,
realization, and PCM form the first concrete workflow, not the limit of the
framework. This remains a design specification for the agent system. The
version-1 computed-realization engine described below is now implemented as a
standalone deterministic service. Its GTEP adapter, topology-screened Maryland
catalog builder, selected-variant PCM handoff, pre-PCM structural screens, and
opt-in `run_hope_holistic` integration are also implemented. Discrete-project
selection, development-evidence screens, human-review flags, and multiple
policy realizations are exercised by the
[Maryland Incremental Project-Siting Benchmark v1](@ref md-incremental-project-siting-v1).
The service now includes a first deterministic feedback boundary in
`src/adaptive_feedback.jl`. It converts assessment evidence into typed
`Finding` and `RevisionRequest` artifacts, records human decisions separately,
and enforces an iteration limit. It deliberately stops before automatically
editing or rerunning a GTEP case.

The motivating study pattern is iterative:

1. GTEP produces a zonal capacity plan using planning abstractions such as a
   planning reserve margin.
2. A realization process converts that plan into one or more nodal physical
   systems suitable for PCM.
3. PCM tests chronological operation at higher spatial and temporal resolution.
4. An independent verifier determines whether the evidence satisfies a
   predeclared `HolisticAssessmentContract`.
5. If it does not, the responsible layer proposes a traceable revision. The
   workflow repeats until it passes, reaches an approved stopping condition, or
   returns to a human decision maker.

The existing deterministic linkage remains the computational foundation. It
provides identities, fingerprints, immutable artifacts, conservation checks,
and provenance. Agents add scientific diagnosis and controlled revision; they
do not replace those contracts or move numerical data through conversation.

## General holistic-assessment framework

A holistic assessment connects an upstream decision or design model to one or
more higher-resolution realizations and assessment models, then returns
evidence-based feedback when the proposed system cannot be constructed, solved,
or accepted. The common framework is:

```text
Study specification
        -> upstream decision model
        -> physical or semantic realization
        -> one or more assessment models
        -> assessment-specific verifier
        -> accept, revise, escalate, or stop
```

Reliability assessment is one important use case, but it is not the definition
of holistic assessment. Other workflows may evaluate:

| Assessment family | Example downstream evidence |
| --- | --- |
| Model and operational feasibility | Model construction, mathematical feasibility, commitment and dispatch consistency, or an explainable infeasibility diagnosis |
| Reliability and adequacy | Unserved energy, reserve shortfall, contingencies, LOLE, EUE, or other approved deterministic or probabilistic metrics |
| Economics and deliverability | Production cost, congestion, curtailment, transmission utilization, uplift, or stranded capacity |
| Policy and emissions | RPS or clean-energy compliance, emissions limits, carbon cost, or technology constraints |
| Market performance | Day-ahead and real-time feasibility, reserve procurement, price formation, deviations, or settlement outcomes through DART |
| Resilience and stress testing | Performance under approved weather, outage, fuel, transmission, or demand stress scenarios |

Each assessment family supplies its own versioned criteria and evaluator while
reusing the same artifact lineage, finding, revision, approval, and stopping
contracts. A study may compose several assessment modules, but each pass or fail
claim must name its metric, horizon, threshold, and authoritative evidence.

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
          |              Assessment Agent(s)
          |          (PCM first; other modules optional)
          |                         |
          |                         v
          |                 AssessmentResult
          |                         |
          |                         v
          +<---- RevisionRequest -- Verifier / Assessment Gate
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
| `HolisticAssessmentContract` | Selected assessment modules, model-feasibility and assessment gates, evaluation horizons, allowed revisions, approvals, iteration limit, and compute budget |

### Computed downscaling method v1: constrained site-and-allocate

**Implementation status:** `src/computed_realization.jl` implements the
screening, constrained allocation, policy variants, exact capacity checks, and
hashed realization-set package. The command-line entry point is
`tools/repo_utils/compute_nodal_realizations.jl`; its three input contracts are
documented in `schemas/capacity_plan_v1.yml`,
`schemas/candidate_site_catalog_v1.yml`, and
`schemas/realization_policy_v1.yml`. A small synthetic executable example is
under `tools/repo_utils/examples/computed_realization_v1/`; the geographically
grounded synthetic Maryland project-siting benchmark is under
`tools/repo_utils/examples/maryland_incremental_project_siting_v1/`. The
adapter to solved GTEP outputs and the selected-realization PCM resource builder
are implemented. Real project evidence, live interconnection studies, and the
adaptive revision loop remain subsequent work.

The first general realization method should be useful before it is elaborate.
It should adapt the fundamentals-based logic of Site-and-Grow to HOPE without
embedding a second generation-expansion model inside the realization layer.
GTEP remains authoritative for how much capacity is built in each planning
zone. The realization engine answers the narrower question of where that zonal
capacity can be represented in the nodal PCM system.

The method has three deterministic stages:

1. **Screen.** Remove candidates that violate technology eligibility, zone,
   land or policy exclusions, required network identity, resource thresholds,
   or a hard site or interconnection limit. A favorable score must never
   compensate for a prohibited site.
2. **Allocate.** Assign each zonal technology build among the remaining sites
   by minimizing a reviewed objective subject to exact capacity-conservation
   and site constraints. Existing compatible sites with documented headroom,
   approved brownfield or interconnection sites, and new greenfield candidates
   may all be represented; their relative preference is a policy parameter,
   not a prompt instruction.
3. **Screen the network.** Reject or flag allocations that fail topology,
   connectivity, PTDF/interface, or selected stress-hour checks before a full
   PCM solve.

A suitable version-1 objective is a normalized weighted sum of:

- interconnection and site cost;
- a network-stress or distance proxy;
- resource-quality penalty for location-dependent wind, solar, and hydro;
- fragmentation or excessive unit-count penalty;
- deviation from an approved existing-site or brownfield preference; and
- evidence-quality penalty for candidates supported by weaker data.

The hard constraints should include:

- exact zonal and technology conservation of GTEP generation build and
  retirement MW;
- exact storage power MW and energy MWh conservation;
- technology, zone, site, and bus eligibility;
- site, interconnection, and optional subregional concentration limits;
- reviewed unit sizes or bounded aggregate-unit construction;
- stable network identities and operational-template coverage; and
- deterministic solver settings and tie-breaking.

The default candidate hierarchy is therefore not simply "grow in place." It is
"reuse when defensible, then expand reviewed sites, then use eligible new
sites." Existing sites receive no capacity beyond documented headroom, and a
new site may outrank an existing site when resource, interconnection, policy,
or network evidence supports it.

#### Realization alternatives

One minimum-objective allocation should not be presented as physical truth.
Version 1 should normally generate three policy-labelled members when the
candidate set permits:

1. `balanced_baseline`, using the reviewed central weights;
2. `existing_site_priority`, preferring compatible brownfield expansion; and
3. `resource_network_priority`, favoring resource quality and spatial or
   network dispersion.

Alternatives must use the same parent plan and hard constraints. They may be
generated by different approved weight sets or by diversity constraints that
require material changes in host buses, corridors, or concentration. A study
may request fewer members when the mapping is fully declared or more members
when siting uncertainty is itself an assessment variable.

#### Spatial conservation versus operational reconciliation

HOPE must distinguish a physical planning decision from an aggregate dispatch
result:

- **Capacity is a hard handoff.** Selected generation MW and storage MW/MWh are
  conserved exactly from GTEP to every realization.
- **PCM dispatch is endogenous by default.** Hourly commitment and dispatch
  should reveal operational feasibility, congestion, curtailment, reserves,
  load shedding, and cost. Forcing PCM to reproduce GTEP energy by planning
  time block could conceal the very mismatch the assessment is intended to
  find.
- **Aggregate energy remains evidence.** GTEP generation by technology and
  time block is retained in a reconciliation artifact. HOPE reports PCM-minus-
  GTEP differences and their causes.
- **Hard energy matching is opt-in.** An assessment whose purpose is to
  disaggregate an aggregate emissions or energy projection may explicitly set
  `energy_reconciliation_mode: hard_match`. It is not the default for a
  planning-to-operations assessment.

Weather-year load and wind, solar, hydro, and temperature-dependent operating
profiles should be attached by site and hour before PCM. These profiles must be
mutually time-aligned and linked to the same scenario. A simple reviewed
profile source is preferable to a machine-learning downscaler in version 1.
Any bias correction, physical transformation, or profile scaling must retain
its source, version, and before/after diagnostics.

#### Version-1 validation

The realization engine should be accepted only after the following checks are
automated:

- exact parent-to-child capacity and storage conservation;
- zero assignments to excluded or ineligible candidates;
- compliance with site, interconnection, unitization, and concentration caps;
- complete lineage from GTEP candidate through realization site and PCM unit;
- deterministic repeatability under identical inputs and solver settings;
- comparison of ranked candidates with known existing or recent sites where
  such a benchmark is meaningful;
- sensitivity to objective weights and candidate-data uncertainty;
- network fast-screen and PCM outcomes for every published realization; and
- weather-profile checks for distributions, ramps, extremes, spatial
  variability, and cross-variable synchronicity relevant to the assessment.

This validation does not prove that one allocation is the future. It establishes
that each published allocation is admissible, traceable, reproducible, and
appropriate for the declared assessment.

### Literature basis and deliberate scope

The v1 design combines a small subset of ideas from four downscaling studies:

- Wang et al.'s spatial Site-and-Grow framework separates hard geographic
  exclusion from multi-criteria ranking, conserves aggregate-model totals, and
  uses economic and network fundamentals rather than blindly preserving
  historical spatial shares: [doi:10.1016/j.scitotenv.2021.145504](https://doi.org/10.1016/j.scitotenv.2021.145504).
- Wang et al.'s temporal dispatch method shows the value of weather-responsive
  hourly load and renewable profiles, explicit aggregate boundary conditions,
  and time-aligned dispatch: [doi:10.1021/acs.est.4c08060](https://doi.org/10.1021/acs.est.4c08060).
- Nishant et al. show that any learned downscaler should combine coarse dynamic
  drivers with fine static features and be tested out of sample on distributions,
  spatial and temporal variability, and extremes rather than only average
  error: [doi:10.1088/1748-9326/ace463](https://doi.org/10.1088/1748-9326/ace463).
- Buster et al. show the importance of high-resolution physical features,
  physically coherent transformations, trend preservation, multivariate
  synchronicity, and fit-for-purpose validation of downscaled weather:
  [doi:10.1038/s41560-024-01507-9](https://doi.org/10.1038/s41560-024-01507-9).

HOPE v1 should not train a neural or generative downscaler. Candidate-site data,
hard constraints, and assessment semantics are the immediate bottlenecks, and
a transparent constrained allocator is easier to validate and revise. Learned
weather or siting models can be added later as versioned input providers; they
must not bypass the realization contract or its conservation checks.

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

A fast screen may reject an invalid realization, but only the holistic
assessment contract determines what evidence is sufficient for the final study
claim.

## Feasibility and assessment are separate gates

PCM infeasibility is evidence, not a diagnosis. It may result from a genuinely
inadequate plan, an impossible nodal realization, incompatible operational
parameters, bad chronology, a contract error, or numerical failure. Conversely,
a feasible deterministic PCM run does not by itself pass reliability, economics,
policy, emissions, resilience, market-performance, or any other holistic
assessment.

The framework must preserve five distinct outcomes:

1. **Invalid input or contract:** the assessment must not start.
2. **Execution or numerical failure:** no scientific feasibility conclusion is
   justified.
3. **Mathematical infeasibility:** the formulated downstream problem has no
   feasible solution under the pinned inputs and settings. This creates a
   diagnostic finding and may trigger feedback.
4. **Feasible but not accepted:** the model solved, but one or more declared
   assessment criteria failed.
5. **Accepted:** model feasibility and every required assessment gate passed.

The `HolisticAssessmentContract` must be pinned before the first solve and
separate at least these gates:

| Gate | Example evidence |
| --- | --- |
| Artifact integrity | Valid schemas, hashes, identities, units, calendars, and parent lineage |
| Realization fidelity | Zonal decisions conserved; every physical asset and network change reconciled |
| Model solvability | Accepted solver termination and feasible primal solution |
| Optional operational adequacy | Unserved energy, reserve shortfall, overload, curtailment, ramping, storage, and policy thresholds when an operational module is selected |
| Assessment-specific results | The metrics, horizons, thresholds, and evaluator required by each selected assessment module |
| Optional reliability | Study-defined deterministic contingencies or probabilistic metrics such as LOLE/EUE, only when a suitable reliability evaluator is selected |
| Scientific governance | No unresolved high-severity findings; all material changes approved; final audit passed |

The criterion, horizon, and tolerance belong in the contract. An agent must not
make an infeasible or failed assessment pass by silently relaxing a threshold,
enabling load shedding, changing a penalty, disabling a constraint, or
shortening the evaluation horizon.

## Diagnosis and revision routing

Every failed gate should first create a structured `Finding`. A diagnosis step
then assigns the narrowest responsible layer. The workflow should try the
lowest-authority scientifically valid change before modifying an upstream model.

| Failure class | Typical evidence | First responsible role | Permitted first response |
| --- | --- | --- | --- |
| Contract or data error | Missing IDs, incompatible units, incomplete chronology, stale parent hash | Artifact owner / human data steward | Correct or replace the invalid artifact; do not reinterpret it conversationally |
| Numerical or software failure | Solver error, numerical instability, resource exhaustion | Model agent plus runtime operator | Retry only under an approved numerical policy; otherwise stop for review |
| Mathematical infeasibility | Solver establishes infeasibility under the pinned formulation and inputs | Assessment-model agent, then revision router | Publish available conflict, constraint-group, slack, or feasibility-relaxation diagnostics without treating the relaxation as an accepted solution |
| Realization-local | Bus overload, implausible concentration, site-cap violation, invalid unitization with zonal totals otherwise adequate | Realization agent | Propose a new policy or alternative mapping while preserving the `CapacityPlan` |
| PCM-assumption-local | Missing or inappropriate operating template, initial state, outage, reserve eligibility, or chronology input | PCM agent | Correct an owned operational assumption within its approved range |
| Planning-structural | Persistent firm-capacity, flexibility, storage-duration, interface, or resource-location deficiency across defensible realizations | GTEP agent | Propose a new planning constraint, candidate, cost, capacity credit, reserve rule, or scenario assumption |
| Assessment-policy conflict | A selected assessment standard cannot be evaluated or met under the authorized model scope or budget | Study agent and human | Clarify the research question, approve expanded scope, or stop without a false-safe conclusion |

When supported, an infeasibility diagnosis should retain an irreducible
inconsistent subsystem, conflict refinement, violated constraint groups, or a
separately labeled minimum-slack diagnostic. A feasibility relaxation is
diagnostic evidence only; it must never overwrite or be reported as the original
model solution.

The router should use evidence across several realizations before blaming GTEP.
For example, one congested bus assignment is a realization problem; repeated
congestion across diverse defensible assignments may justify a planning-level
transmission or location constraint.

## Revision contract

Agents may propose changes; deterministic tools apply approved changes. No
agent may directly mutate an accepted parent artifact. Every revision creates a
child scenario and a machine-readable delta.

A `RevisionRequest` includes fields similar to:

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
  assessment_result: {artifact_id: pcm-assessment-006, sha256: "..."}
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

Version 1 is implemented by `build_holistic_feedback`,
`record_revision_decision`, and `write_holistic_feedback_package`. The schemas
are documented in `schemas/holistic_finding_v1.yml` and
`schemas/revision_request_v1.yml`. The deterministic generator refuses to edit
the parent artifacts, emits stable content-derived IDs, preserves forbidden
actions, and stops with `INCONCLUSIVE` when the policy's iteration limit is
reached. Approval authorizes construction of a child scenario; it does not
authorize in-place changes to an accepted case.

The first approved-change materializer is implemented by
`build_gtep_child_scenario_spec` and
`materialize_approved_gtep_child_scenario`. It supports one deliberately narrow
operation: increasing the upper bounds of named RPS-eligible GTEP candidates
when candidate builds are continuous (`inv_dcs_bin = 0`). Discrete candidate
rows require a separate unitization-aware operation.
The concrete specification must include the expected parent values and parent
candidate-table hash, the total increase must remain inside the approved
request envelope, and every other data file must remain byte-identical. The
tool copies no stale model outputs, writes request/decision/specification/delta
lineage, and marks the child `materialized_pending_gtep_solve` with validation
`NOT_RUN`. Its contracts are documented in
`schemas/revision_decision_v1.yml` and
`schemas/gtep_child_scenario_spec_v1.yml`.

This operation expands an optimization option; it does not force the model to
build the capacity and does not claim the downstream finding is resolved. A
new GTEP solve, a new `CapacityPlan`, realization, PCM assessment, and verifier
decision are still required.

## Agent authority

| Role | May do | Must not do without escalation |
| --- | --- | --- |
| Study agent | Define the workflow from an approved study specification; track iterations, budget, and approvals; assemble final evidence | Change scientific thresholds or publish a failed study as successful |
| GTEP agent | Diagnose planning evidence; propose and run allowlisted GTEP case revisions; publish a `CapacityPlan` and delta | Alter physical realization or PCM outputs; silently change policy, demand, costs, or the research objective |
| Realization agent | Select or propose a reviewed realization policy; run the deterministic allocator; publish and compare physical realizations | Change zonal build totals, invent unregistered sites, or hide ambiguity |
| PCM agent | Build validated PCM cases from a `PhysicalSystem`; distinguish execution failure, infeasibility, and feasible-but-failed criteria; diagnose operations; propose owned input corrections; publish an `OperationalAssessment` | Change GTEP decisions, physical sites, or assessment criteria |
| Other assessment agent | Run a selected reliability, market, policy, emissions, economics, or stress-test module and publish a typed `AssessmentResult` | Claim authority outside its declared module or alter upstream artifacts |
| Verifier / assessment gate | Read authoritative artifacts; recompute selected checks; classify findings; issue acceptance or revision evidence | Repair the case it evaluates or waive a failed gate |
| Human approver | Approve material assumptions, scope, budgets, topology/data substitutions, and publication | Approval is recorded as evidence; it must not be inferred from silence |

Agent knowledge should be explicit and reviewable: model documentation,
formulation and data schemas, diagnostic playbooks, approved change templates,
case provenance, and prior validated findings. Conversational memory is not a
substitute for those sources.

## Human-in-the-loop policy

Human approval should be required when a revision changes any of the following:

- policy targets, assessment or reliability thresholds, demand, fuel or technology costs;
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
smaller violation is not convergence if any hard selected assessment criterion
still fails.

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

The deterministic portion of steps 2 through 4 now has an executable baseline:

- `capacity_plan_from_gtep` extracts positive solved generation and storage
  decisions without losing `Candidate_ID` lineage;
- `build_candidate_site_catalog_from_pcm` constructs a conservative catalog
  from existing interconnection buses, installed generation, and incident
  branch-rating proxies;
- `compute_nodal_realizations` publishes the three policy-labelled variants;
  and
- `prepare_pcm_inputs_from_computed_realization` materializes one selected
  variant and delegates resource construction, operational templates, and
  reconciliation to the established PCM handoff.

The reproducible Maryland example contains 48 technology-specific catalog rows
over 12 buses. It is a topology-screened workflow input, not a final siting
study: land, queue, environmental, renewable-resource, and detailed power-flow
evidence remain external review layers. The default `explicit_bus` Maryland
case remains unchanged.

Automatic execution is activated only when both generation and storage declare
`method: computed_allocation` and the physical-realization contract names the
catalog, policy, and selected variant. Before PCM construction, HOPE verifies
bus references, planning-zone consistency, and physical connectivity. It also
reports each bus's allocation-to-incident-rating ratio. That ratio becomes a
hard gate only when the study contract supplies a positive threshold; it is a
transparent topology proxy, not a DC/AC load-flow or contingency proof.

The first scientific-agent implementation should be deliberately narrower than
the final architecture:

1. Freeze the current explicit-bus composite tool as the reference baseline.
2. Define version-1 `CapacityPlan`, `CandidateSiteCatalog`, `RealizationPolicy`,
   `RealizationSet`, `AssessmentResult`, `Finding`, `RevisionRequest`, and
   `HolisticAssessmentContract` schemas. The `Finding` and `RevisionRequest`
   boundary is now executable; the full assessment contract remains future work.
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

July PCM can establish the first operational feasibility and adequacy workflow.
Its infeasibility and feasible-but-failed paths are both valid feedback-loop
tests. It must not be labeled a complete probabilistic reliability study. Later
milestones can compose annual or rolling operation, contingency analysis, EREC,
DART, policy, emissions, economics, resilience, or another validated assessment
module under its own contract.

## What not to build

- Do not let agents edit shared CSV files in place.
- Do not pass capacity plans or PCM results only through natural-language
  messages.
- Do not let the PCM agent directly change GTEP assumptions.
- Do not treat one arbitrary nodal allocation as the unique physical truth.
- Do not equate solver feasibility with successful holistic assessment.
- Do not let an agent relax a threshold in order to declare success.
- Do not rerun indefinitely; revisions require lineage, budgets, and stopping
  rules.
- Do not add agent roles where a deterministic validator or optimizer is the
  appropriate mechanism.

## Design outcome

The target is not three autonomous chatbots and not one fixed reliability
pipeline. It is an adaptive scientific framework in which specialized agents
diagnose and propose, deterministic HOPE tools transform and solve, typed
assessment modules evaluate different study questions, immutable artifacts
communicate, an independent verifier judges evidence, and humans retain
authority over material scientific changes.
