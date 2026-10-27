# Holistic Linkage Assumption and Decision Log

**Status:** Living document
**Last updated:** 2026-10-26

## Purpose

This is the living human-readable register for assumptions and design decisions
that affect information exchange between HOPE models. It currently focuses on
GTEP-to-PCM physical realization and will later include GTEP-to-DART and
PCM-to-DART entries.

The log complements, but does not replace, machine-readable case settings,
physical-realization contracts, manifests, source registers, and run audits.
Those artifacts remain the executable source of truth. This page explains why
the current rules exist, what evidence supports them, and which gaps remain.

## Status vocabulary

| Status | Meaning |
| --- | --- |
| Validated | Implemented and exercised by a solved or automated validation case |
| Active | Implemented or currently assumed, but not fully exercised by the canonical case |
| Proposed | Agreed direction that is not yet implemented |
| Open | A known decision or data gap still requiring resolution |
| Superseded | Retained for history but replaced by a later entry |

## Maintenance rule

Every material cross-model assumption should receive a stable `HLA-###` ID.
When behavior changes, update its status and append a dated history entry. Do
not silently delete a prior decision. Code, case manifests, validation reports,
issues, and agent-run manifests should reference these IDs where practical.

At minimum, a new entry records:

- the models and cases it affects;
- whether it is data, formulation, realization, validation, or computing policy;
- the current rule and rationale;
- its evidence or implementation location;
- its consequence and planned resolution.

## Current register

| ID | Topic | Current rule | Status |
| --- | --- | --- | --- |
| HLA-001 | Spatial resolution | Annual GTEP uses four Maryland zones plus `EXT`; PCM uses 656 buses and 838 branches | Validated |
| HLA-002 | Existing asset identity | `Asset_ID` is the authoritative existing-generator crosswalk | Validated |
| HLA-003 | Candidate identity and siting | `Candidate_ID` identifies a build and `Bus_id` provides its PCM location | Validated |
| HLA-004 | Maryland candidate-bus choice | Each zone uses its largest existing generation bus as a representative candidate bus | Active |
| HLA-005 | New plant sizing | GTEP selects continuous MW; without `PCM_Unit_Size_MW`, one candidate becomes one aggregate PCM row | Validated |
| HLA-006 | Existing-resource parameters | Each model owns its input parameters; retirements transfer capacity changes through `Asset_ID` | Validated |
| HLA-007 | New-resource parameters | Candidate values take precedence, followed by a PCM template, zone/type mean, type mean, and code defaults | Validated |
| HLA-008 | Operational templates | PCM owns an optional validated template registry; new thermal generation is always unit committed | Implemented |
| HLA-009 | Retirement realization | Default is proportional capacity; priority and whole-unit policies are optional | Active |
| HLA-010 | Transmission realization | Use `Corridor_ID`, then explicit endpoints; no line build was selected in the annual case | Active |
| HLA-011 | Reserve alignment | GTEP's 7% upward proxy represents PCM's 1% REG-UP, 3% SPIN, and 3% NSPIN | Validated |
| HLA-012 | Linkage test horizon | Solve GTEP for 8760 hours and PCM for all 744 July hours for routine integration validation | Validated |
| HLA-013 | July RPS interpretation | PCM enforces the 20% local RPS within July; this is deliberately restrictive, not annual REC accounting | Validated |
| HLA-014 | Generator availability | Use static generator `AF` and `FOR`; do not repeat a one-week outage trace across the year | Active |
| HLA-015 | External interchange | Use zero scheduled net interchange and endogenous hourly boundary capacity | Active |
| HLA-016 | Physical network fidelity | OSM supplies topology and geography; several electrical fields remain inferred assumptions | Active |
| HLA-017 | PEPCO deliverability calibration | Increase `OSM_L1528639488` from 500 MW to 600 MW in both directions | Validated |
| HLA-018 | Source immutability | Realized PCM inputs are written to outputs; source GTEP and PCM cases must remain unchanged | Validated |
| HLA-019 | Annual PCM computing policy | The full 656-bus, 8760-hour PCM requires a higher-memory worker; July is the workstation agent test | Active |
| HLA-020 | Repository boundary | Case builders and diagnostics are retained; run workspaces remain ignored generated artifacts | Active |
| HLA-021 | Realization multiplicity | A zonal plan may have several defensible nodal realizations; ambiguity must be published rather than hidden | Proposed |
| HLA-022 | Computed siting | General downscaling uses a versioned candidate-site catalog and deterministic constrained allocation policy | Proposed |
| HLA-023 | Operational feedback | PCM or reliability findings create structured revision requests and never directly mutate GTEP inputs | Proposed |
| HLA-024 | Study acceptance | Feasibility, operational adequacy, and reliability are separate gates pinned before execution | Proposed |
| HLA-025 | Iteration lineage | Every approved revision creates immutable child artifacts with a machine-readable delta | Proposed |
| HLA-026 | Change authority | Agents may make only allowlisted changes; material scientific assumptions require recorded human approval | Proposed |

## Detailed entries

### HLA-001 — spatial roles

- **Scope:** Maryland 20% RPS full-year GTEP-to-PCM benchmark.
- **Rule:** GTEP makes planning decisions over `APS_MD`, `BGE`, `DPL_MD`,
  `PEPCO`, and `EXT`. PCM tests their physical operation on 656 buses and 838
  branches.
- **Rationale:** Planning aggregation is a human and computational choice; PCM
  retains the network detail required to expose intra-zonal constraints.
- **Evidence:** case manifests, `HOPE_physical_realization.yml`, and the holistic
  handoff audit.
- **Consequence:** A feasible zonal plan is not guaranteed to be nodally
  deliverable, so physical realization and a PCM screen remain necessary.

### HLA-002 — existing asset identity

- **Rule:** `Asset_ID` is nonblank and unique in both stages and is used before
  any legacy row or aggregate mapping.
- **Rationale:** Row numbers are unstable under sorting, aggregation, or source
  updates.
- **Evidence:** all 271 existing Maryland generators crosswalk successfully.
- **Next action:** extend the same stable identity convention to every future
  storage and transmission source where it is not already available.

### HLA-003 and HLA-004 — candidate location

- **Rule:** GTEP remains zonal, but each generation and storage candidate carries
  `Planning_Zone`, `Bus_id`, and `Candidate_ID`. The current Maryland case uses
  the largest existing generation bus in each planning zone.
- **Rationale:** This makes the linkage deterministic while higher-quality
  interconnection and land/resource data are unavailable.
- **Evidence:** `references/candidate_bus_mapping.csv` and candidate input rows.
- **Consequence:** All technologies in a zone currently share one representative
  bus. This is a transparent test assumption, not optimized or observed siting.
- **Next action:** define a candidate-bus catalog with technology eligibility,
  bus capacity, siting cost, evidence, and confidence, then add a deterministic
  allocation or siting optimization step.

### HLA-005 — plant and unit size

- **Rule:** The solved continuous GTEP capacity becomes one aggregate PCM row
  unless the candidate supplies `PCM_Unit_Size_MW`.
- **Rationale:** Preserve compatibility with existing continuous GTEP cases while
  supporting explicit unit disaggregation when physical detail is available.
- **Evidence:** `realize_generation_builds` in `src/holistic_linkage.jl` and the
  generation-build audit.
- **Consequence:** Without `PCM_Unit_Size_MW`, a thermal build is one committed
  aggregate row even when it represents several physical units. This is useful
  for linkage testing but is not a production-grade plant fleet.
- **Next action:** choose technology-specific unit sizes and commitment behavior
  through the template registry proposed in HLA-008.

### HLA-006 through HLA-008 — parameter ownership

- **Existing resources:** GTEP and PCM keep their own source tables. They share a
  common fleet basis in this benchmark, and `Asset_ID` maps capacity retirements.
  The linkage does not replace PCM costs, commitment, ramp, reserve, outage, or
  emissions parameters for existing resources.
- **New resources:** candidate-supplied values are copied first. The candidate's
  `Operational_Template_ID` then selects a row from the PCM-owned optional
  `operational_resource_templates.csv`. Remaining numeric fields use the same
  zone/type, then the same type, then code defaults.
- **Thermal commitment safeguard:** every newly realized row with
  `Flag_thermal = 1` receives `Flag_UC = 1`, even when a legacy candidate carries
  a zero placeholder. Existing PCM resources are not modified by this rule.
- **Evidence:** the Maryland annual benchmark defines modern NGCC, solar, wind,
  and four-hour battery templates. The realized-input package writes
  `operational_parameters_audit.csv` with field-level candidate, template, and
  thermal-policy sources.
- **Remaining refinement:** technology-specific unit size and minimum-output
  fractions should be calibrated before treating aggregate GTEP builds as a
  production physical fleet.

### HLA-009 and HLA-010 — retirement and transmission

- **Retirement:** proportional physical capacity is the default. Optional
  largest-first, smallest-first, or explicit-priority allocation and partial-unit
  rejection are implemented.
- **Transmission:** `Corridor_ID` is preferred, followed by explicit PCM
  endpoints. Directional capacity conservation is audited.
- **Validation boundary:** the canonical annual Maryland result selected neither
  retirement nor transmission expansion. The compact restricted benchmark and
  the separate high-resolution annual-GTEP/July-PCM transfer-coverage benchmark
  exercise those paths; the canonical result should not claim that it does.
- **High-resolution coverage evidence:** the derived benchmark retires the 2 MW
  `G1149` asset and adds 1,000 MW in each direction to `OSM_L62255589`. PCM uses
  436.409 MW of flow above the derived pre-upgrade rating. The forcing values are
  explicitly test-only and are not Maryland planning assumptions.

### HLA-011 — reserve translation

- **Rule:** GTEP's single upward reserve product is 7% of load, equal to PCM's
  configured 1% REG-UP + 3% SPIN + 3% NSPIN requirements.
- **Rationale:** Prevent aggregate planning from understating the upward
  capability required by the operational model.
- **Limitation:** This aligns total upward capability, not product response time,
  eligibility, or co-optimization details.

### HLA-012 and HLA-013 — validation horizon and policy

- **Rule:** routine linkage validation uses annual GTEP followed by July PCM.
- **What it establishes:** identity, capacity conservation, physical mapping,
  source immutability, PCM model construction, and operation of the transferred
  fleet under a demanding summer month.
- **What it does not establish:** annual PCM cost, winter adequacy, seasonal
  storage, annual emissions, or annual REC compliance.
- **RPS interpretation:** July independently satisfies 20% local RPS. This is a
  deliberately restrictive integration test, not an annual REC bank.

### HLA-014 and HLA-015 — chronology inputs and boundary

- **Availability:** use each generator's static `AF` and `FOR` because no
  identity-compatible annual outage chronology is available. Repeating the
  compact July outage pattern would create false annual evidence.
- **Interchange:** scheduled nodal interchange is zero because no authoritative
  hourly schedule is assumed. Hourly boundary caps allow endogenous imports and
  exports through retained external interfaces.

### HLA-016 and HLA-017 — physical-data fidelity

- **Observed/derived:** OSM topology, locations, and tagged voltage where
  available.
- **Inferred/assumed:** missing voltage, reactance, ratings, transformers,
  candidate siting, and the external corridor proxy.
- **Calibration:** the four-zone plan produced one July shedding hour at an
  inferred 500 MW intra-PEPCO constraint. `OSM_L1528639488` is therefore modeled
  at 600 MW in both directions. The adjustment remains labeled as a modeling
  assumption and must be revisited when authoritative data are available.

### HLA-018 through HLA-020 — workflow and repository policy

- Realization occurs in memory and is persisted under
  `output_holistic/realized_inputs/`.
- Before/after source hashes must match.
- The full annual PCM exceeded the 32 GB validation workstation during model
  construction; it is not claimed as solved. Route it to a higher-memory worker.
- Exact rolling operation is future work because commitment, dispatch, storage
  state, and annual REC accounting must cross window boundaries.
- Core transfer behavior belongs in `src/`. Agent launchers and diagnostics
  belong in `tools/repo_utils/`. Reproducible case builders belong in
  `ModelCases/tools/`. Generated run workspaces belong under ignored
  `artifacts/agent_runs/`.

### HLA-021 and HLA-022 — general nodal realization

- A zonal build decision does not generally identify one uniquely correct nodal
  system. When candidate locations are not declared, HOPE should represent the
  ambiguity explicitly as a set of diverse, defensible physical realizations.
- Computed realization should consume a reviewed candidate-site catalog,
  reference network, operational templates, and versioned policy. It should
  conserve zonal MW and MWh while enforcing technology, zone, site,
  interconnection, unitization, and network-reference constraints.
- The allocation objective, weights, solver, tolerances, diversity settings,
  and tie-breaker are scientific assumptions and must be present in the
  artifact. Given identical pinned inputs and policy, generation of the
  realization set should be reproducible within declared tolerances.
- The validated `explicit_bus` rule remains a supported declared-realization
  strategy and the regression baseline. General siting is a new layer rather
  than a replacement hidden inside the existing linkage.

### HLA-023 through HLA-026 — adaptive scientific workflow

- A PCM failure is first recorded as evidence and classified. It may be caused
  by data, numerical behavior, physical realization, operational assumptions,
  or a structural planning deficiency; infeasibility alone does not identify
  which layer should change.
- A downstream agent may publish a `RevisionRequest` with parent hashes,
  findings, observed metrics, inferred cause, proposed delta, alternatives, and
  required approval. It may not directly edit an upstream accepted artifact.
- The study pins separate gates for artifact integrity, realization fidelity,
  solver feasibility, operational adequacy, reliability, and scientific
  governance. A feasible PCM run is not automatically a reliability result, and
  an agent may not weaken a failed threshold to declare success.
- Every iteration is an immutable child scenario. Convergence requires all hard
  gates to pass; iteration and compute budgets, cycles, unauthorized changes,
  and human stops are explicit terminal conditions.
- Changes to policy, reliability criteria, demand, costs, planning methodology,
  candidate sites, topology, external data, formulation, or publication require
  recorded human approval unless a reviewed study contract explicitly delegates
  a bounded parameter range.
- The detailed proposed contracts and role boundaries are maintained in
  [Adaptive GTEP, Realization, and PCM Agents](@ref adaptive-gtep-pcm-agents).

## Open decisions

| Decision | Related IDs | Required work |
| --- | --- | --- |
| Nodal siting from zonal-only GTEP | HLA-003, HLA-004, HLA-021, HLA-022 | Implement the proposed candidate-site schema, deterministic allocation objective, diverse realization set, and screening sequence |
| Operational template registry | HLA-005, HLA-007, HLA-008 | Define schema and precedence; update realization and audits |
| Production-grade unitization | HLA-005, HLA-008 | Assign unit sizes and commitment parameters by technology |
| Exact annual or rolling PCM | HLA-012, HLA-019 | Add state carry and annual-policy accounting or provision a high-memory worker |
| Replace inferred physical data | HLA-016, HLA-017 | Incorporate authoritative ratings/topology when licensing and access permit |
| Production-economics retirement and transmission scenarios | HLA-009, HLA-010 | Replace test-only forcing assumptions with reviewed planning economics when suitable data become available |
| Adaptive planning feedback | HLA-023, HLA-024, HLA-025, HLA-026 | Implement findings, revision requests, pinned acceptance gates, approval records, immutable child scenarios, and bounded stopping rules |

## Change history

| Date | Change |
| --- | --- |
| 2026-10-26 | Added proposed general nodal-realization, operational-feedback, acceptance, iteration-lineage, and agent-authority decisions for the adaptive GTEP-realization-PCM workflow. |
| 2026-10-24 | Added the separate high-resolution transfer-coverage benchmark, including pinned retirement, transmission, physical-flow, and source-immutability evidence. |
| 2026-10-20 | Created the consolidated log from the implemented handoff contract, Maryland case manifests/provenance, solved annual-GTEP/July-PCM validation, and current design discussion. |
