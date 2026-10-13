# [HOPE Multi-Model and Multi-Agent System Design](@id multi-agent-system-design)

## Status and purpose

This document records the current working design for connecting HOPE's planning,
operations, market, reliability, data, and future agent capabilities. It is an
architecture proposal, not a finalized multi-agent specification.

The immediate objective is to make model-to-model exchange deterministic,
validated, reproducible, and usable without AI. Agents may later control those
same workflows, but they must not be the only mechanism that makes the models
compatible.

The design preserves several important properties:

- GTEP, PCM, and DART remain independently runnable HOPE model modes.
- EREC remains a postprocessing calculation rather than a separate system model.
- Cross-model workflows are explicit options, not prerequisites for using a model.
- Shared physics, state, identity, and provenance are defined in code before they
  are exposed to agents.
- The agent organization remains provisional until the complete HOPE model
  architecture is better established.

## First-principles view

GTEP, PCM, and DART are not merely different solvers over the same input table.
They answer different questions, make decisions at different time scales, and
require different information.

| Mode or function | Primary question | Core decisions or outputs | Typical resolution |
| --- | --- | --- | --- |
| GTEP | What should be built, retained, or retired? | Capacity expansion, retirement, transmission and policy compliance | Multi-year planning with representative or chronological periods |
| PCM | Can an installed system operate chronologically and at what production cost? | Unit commitment, dispatch, storage operation, reserves, flows, curtailment | Hourly or sub-hourly chronological operation |
| DART | How should day-ahead and real-time markets commit, dispatch, procure reserves, and settle? | DA SCUC, RT SCED, reserve awards, deviations, prices, settlement | Hourly day-ahead and sub-hourly real-time intervals |
| EREC | What reliability contribution does a resource provide? | A metric calculated from model inputs or outputs | Postprocessing-specific |

Therefore, the connection between models should be designed around semantic
contracts: installed assets, physical locations, network topology, forecasts,
operational state, market assumptions, and provenance. Copying one model's CSVs
directly into another model is not a sufficient interface.

## Architectural principles

1. **Deterministic kernel before agent orchestration.** Every supported connection
   must exist as a callable, testable workflow that does not require an LLM.
2. **Standalone models remain first-class.** A user may run only GTEP, only PCM,
   or only DART with a complete case package.
3. **Agents coordinate; artifacts carry truth.** Agents exchange immutable artifact
   references and manifests, not unversioned tables pasted into messages.
4. **Physical identity is stable.** Buses, generators, storage units, branches,
   zones, and scenarios use stable IDs across model boundaries.
5. **Assumptions are explicit.** Every transformation records defaults,
   disaggregation rules, mappings, units, and confidence or provenance.
6. **State is typed and time-aware.** Installed-system data, forecasts, dynamic
   initial conditions, and completed-run records are distinct objects.
7. **Validation occurs at every boundary.** Schema, units, timestamps, referential
   integrity, network connectivity, and model compatibility are checked before a
   downstream solve begins.
8. **A failed communication cannot silently mix scenarios.** Run IDs, parent
   artifact hashes, atomic publication, and idempotent operations prevent data
   crossover.

## Proposed layered architecture

```text
User / study definition
          |
          v
Scenario and workflow specification
          |
          v
Canonical contracts and artifact registry
  - PhysicalSystem / CapacityPlan
  - OperationalSnapshot / SimulationState
  - MarketScenario / ForecastSet
  - RunManifest / ModelResult
          |
          v
Deterministic adapters and validators
  - GTEP -> physical realization
  - physical system -> PCM
  - physical system -> DART
  - optional PCM state/results -> DART scenario
          |
          v
Independent model engines
  GTEP              PCM              DART
          \           |              /
           v          v             v
        Results, comparison, reliability, and audit
          |
          v
Optional agent coordination and user-facing analysis
```

The deterministic middle layers are the system's backbone. An agent should call
them rather than reimplementing transformations through prompts.

## Canonical information contracts

The following contracts separate concepts that are often mixed together in case
files.

| Contract | Meaning | Typical producer | Typical consumer |
| --- | --- | --- | --- |
| `ModelCase` | User inputs and model-specific settings needed for a standalone run | User or case builder | One model engine |
| `PhysicalSystem` | Realized assets, locations, topology, ratings, and stable identities | Reference data plus realization module | PCM, DART, network analysis |
| `CapacityPlan` | GTEP build, retirement, and retained-capacity decisions before physical realization | GTEP | Realization module |
| `OperationalSnapshot` | Installed system plus time-indexed load, availability, interchange, reserves, and provenance | Case loader or adapter | PCM and DART adapters |
| `MarketScenario` | DA/RT forecasts, reserve products, bid assumptions, contingencies, and settlement rules | User, scenario builder, or optional PCM adapter | DART |
| `SimulationState` | Commitment, duration-on/off, dispatch history, storage state of charge, and active outages at a boundary time | Initial-state file or preceding run | Chronological PCM or DART window |
| `ModelResult` | Model outputs with schema and semantic metadata | GTEP, PCM, or DART | Analysis, adapters, EREC |
| `RunManifest` | Immutable record of scenario, code version, configuration, input hashes, parents, status, and outputs | Workflow runtime | Every downstream consumer and agent |

The current `OperationalSnapshot` implementation in
`src/operational_snapshot.jl` is an initial foundation for this contract layer.
It loads stable IDs, validates the physical network and calendar, records source
hashes and provenance, and provides typed DART conversion functions. It should
not be treated as the entire future registry or as a mutable global state store.

## Model-connection gaps

### GTEP to PCM

The central gap is **physical realization**. GTEP may decide that a zone receives
new capacity, but PCM requires operable units at specific buses with chronological
parameters. A connection must resolve at least:

- siting a zonal build at one or more buses;
- dividing aggregate capacity into discrete unit sizes;
- assigning stable generator and storage IDs;
- mapping technology classes between formulations;
- adding build vintages and applying retirements;
- providing ramp rates, minimum output, minimum up/down time, startup data,
  outages, reserve eligibility, and storage efficiencies;
- updating network connections and checking deliverability; and
- constructing chronological initial conditions and availability.

These are modeling assumptions, not clerical file conversions. They must be
configurable and recorded in provenance.

### GTEP to DART

This connection contains the GTEP-to-PCM realization gap and additional market
gaps:

- day-ahead and real-time forecast construction;
- generator offer, no-load, startup, shutdown, and reserve prices;
- market-product eligibility and response times;
- quick-start and nonspinning-reserve capability;
- sub-hourly ramp conversion;
- contingency and transmission security assumptions;
- initial commitment and storage state; and
- settlement and deviation rules.

GTEP-to-DART is valuable for testing whether a future portfolio can participate
in and perform under market operations, but it requires more assumptions than a
direct planning-to-production-cost connection.

### PCM to DART

DART should **not automatically inherit a PCM simulation**. A standalone DART
case already has sufficient value for market design, dispatch, reserve, and
settlement studies. Requiring PCM would add run time and would make DART less
usable without always adding information needed by the research question.

An optional PCM-to-DART connection is useful when a study needs:

- a market replay initialized from a particular PCM operating state;
- stressed hours, outages, congestion, or ramping events identified by PCM;
- consistent commitment, dispatch history, and storage state at a handoff time;
- comparison of production-cost operation with DA/RT market outcomes; or
- settlement consequences of forecast error around a physically realized system.

The optional adapter should consume an explicit `OperationalSnapshot`,
`SimulationState`, and `MarketScenario`. It should not read arbitrary PCM output
folders and silently infer assumptions.

### Feedback from operations and markets to planning

PCM and DART can reveal congestion, scarcity, reserve shortfalls, uplift,
curtailment, or deliverability problems. These results may inform a subsequent
GTEP scenario, but they should not automatically modify a planning case. A
feedback workflow must state the rule that converts an operational metric into a
planning constraint, cost, candidate, or scenario assumption.

## Physical realization and external data

A future physical-connection module should map planning abstractions to a
high-resolution electrical representation. OpenStreetMap may contribute
geographic evidence, but it is not by itself an authoritative power-system model.
Useful sources may include public transmission, generator, substation,
interconnection, weather, land-use, and balancing-area datasets.

The module should support both directions:

1. **Assumption to physical system:** place a modeled build into a reference
   network using eligible buses, interconnection limits, land/resource quality,
   distance, or user-defined siting rules.
2. **Physical data to model abstraction:** aggregate detailed assets and topology
   into the zones, technologies, and candidate groups used by GTEP.

Every mapping should preserve source identifiers, spatial resolution, mapping
method, confidence, and unresolved ambiguities. External data should inform a
realization; it should not silently replace the user's study assumptions.

## Operational-state realization

A central module is useful, but it should distinguish four kinds of information:

- **System blueprint:** relatively persistent asset and network facts.
- **Operational snapshot:** exogenous time series and installed-system attributes
  for a scenario and interval range.
- **Simulation state:** endogenous carry-over values at a boundary, such as unit
  commitment duration, last dispatch, state of charge, and active outages.
- **Run record:** immutable audit information describing how artifacts and results
  were created.

This is more precise than a single shared log or globally mutable initialized
model. A downstream case is populated from an immutable, validated snapshot plus
an explicitly selected state. The run record makes that selection reproducible.

## Scenario identity, schema version, and folders

Input folder names remain a convenient human-facing scenario convention, but a
folder name is not sufficient to prevent cross-model data crossover.

- `scenario_id` identifies the study scenario.
- `run_id` identifies one execution attempt.
- `artifact_id` and its content hash identify an immutable exchange object.
- `schema_version` identifies the structure and interpretation of that object.
- `parent_artifact_ids` identify the exact upstream products used.

Thus, `schema_version` is not a replacement for folder-based scenario control.
It allows readers to reject or migrate incompatible data structures, while the
scenario and artifact identities preserve study lineage.

## Failure-safe communication for future agents

Agent messages may be delayed, duplicated, truncated, or delivered out of order.
Correctness must therefore come from the workflow protocol rather than conversational
memory.

Each model job should follow a state machine such as:

```text
CREATED -> VALIDATED -> RUNNING -> PUBLISHED
    |          |           |
    +----------+-----------+-> FAILED
```

Recommended controls are:

- per-run workspaces instead of shared mutable output folders;
- immutable inputs and outputs addressed by hash;
- atomic publication only after validation is complete;
- idempotency keys so retries do not create conflicting runs;
- leases or heartbeats for long-running jobs;
- explicit terminal states and structured error records;
- schema validation at message receipt and artifact load;
- parent-hash checks before a downstream solve;
- units, time zone, calendar, and interval resolution in every time-series
  contract;
- retry-safe status queries rather than assuming a long connection remains open;
  and
- append-only audit events for reconstruction, without treating the event log as
  the numerical source of truth.

Agents should exchange a compact envelope similar to:

```yaml
request_id: request-uuid
scenario_id: rts24_future_2035
run_id: run-uuid
operation: run_dart
input_artifacts:
  - artifact_id: operational-snapshot-uuid
    sha256: "..."
    schema_version: 1
  - artifact_id: market-scenario-uuid
    sha256: "..."
    schema_version: 1
expected_model_mode: DART
```

The message points to data; it does not contain an improvised copy of the data.

## Provisional agent roles

The following roles are useful for capability planning, but they are deliberately
not a finalized deployment topology:

- **Study coordinator:** translates a user objective into an explicit workflow
  and presents decisions requiring user authority.
- **Case and data steward:** locates, versions, validates, and records input data.
- **Physical-realization service or agent:** maps plans and external physical data
  into a valid networked system.
- **GTEP controller:** validates, runs, and interprets planning cases.
- **PCM controller:** validates, runs, and interprets production-cost cases.
- **DART controller:** validates, runs, and interprets DA/RT market cases.
- **Reliability and metrics service:** applies EREC and other postprocessing
  calculations to compatible artifacts.
- **Audit and comparison service:** checks lineage and produces cross-scenario
  comparisons.

These may eventually be separate agents, tools used by one agent, or services
behind a coordinator. That implementation choice should follow workload,
security, reliability, and evaluation evidence rather than being fixed now.

## Supported workflow patterns

The architecture should support all of the following without changing a model's
mathematics:

1. Standalone GTEP.
2. Standalone PCM with an explicitly defined installed system.
3. Standalone DART with DA/RT inputs, initial state, and market assumptions.
4. GTEP to physical realization to PCM.
5. GTEP to physical realization and market assumptions to DART.
6. Optional PCM operating state or stress event to DART.
7. GTEP to PCM to selected DART replay, when scientifically justified.
8. Any compatible completed result to EREC or another postprocessing function.
9. Parallel scenarios followed by provenance-safe comparison.

No workflow should imply that the sequence is mandatory for a standalone study.

## Capability and cross-model test strategy

A setting being present or switched on is not sufficient evidence that a model
capability or cross-model handoff works. Each benchmark claim should be evaluated
at six levels:

1. **Configured:** the feature is enabled with a valid model-mode setting.
2. **Populated:** all required input fields and time series contain meaningful,
   non-default data.
3. **Exercised:** the corresponding variables and constraints are instantiated
   and the test produces a nonzero or otherwise observable response.
4. **Restrictive:** at least one deliberately stressed scenario makes the
   constraint binding or changes the result relative to a controlled baseline.
5. **Transferred:** any state or decision that belongs in a downstream model is
   represented in a typed handoff artifact with identity and provenance.
6. **Consumed:** the downstream model demonstrably uses the transferred value and
   satisfies conservation, topology, chronology, and source-immutability checks.

No single "all features" case can cover the full HOPE configuration space. Some
settings are mutually exclusive, such as system versus zonal planning reserve,
alternative policy modes, representative-period methods, PCM network
formulations, and PCM unit-commitment modes. Combining every compatible feature
in one large case also makes failures difficult to localize.

Use three complementary test layers instead:

- **Contract fixtures:** small deterministic unit tests for retirements, new
  generation, storage, transmission, stable IDs, parameter mapping, topology,
  temporal state, manifests, hashes, and failure behavior.
- **Restricted integration benchmarks:** short, physically consistent cases in
  which selected capacity, retirement, transmission, commitment, reserve, loss,
  policy, and flexibility constraints are intentionally active and observable.
  These test model interaction, not the economic realism of one optimum.
- **Reference studies:** larger realistic cases used to assess numerical health,
  performance, and scientific usefulness without requiring every optional
  constraint to bind.

Each integration benchmark should publish a machine-readable coverage report.
For every claimed feature, the report should record its configured value, input
evidence, activation or binding evidence, upstream artifact field, downstream
consumer, assertions, and result. This capability report can later be consumed
by an agent, but it must be generated and validated by deterministic code.

Cross-model tests should distinguish three semantic classes:

- **Transferred physical state:** installed capacity, retirements, realized unit
  parameters, storage, branches, ratings, locations, and stable identities.
- **Recomputed downstream state:** commitment, dispatch, reserves, storage state,
  prices, and other endogenous operating decisions unless an explicit boundary
  state is selected.
- **Model-local assumptions:** policy interpretation, temporal reduction,
  aggregation, network formulation, security criteria, and solver controls.
  These require compatibility checks and provenance but should not be silently
  copied as though they were physical assets.

This distinction prevents an agent or adapter from interpreting a GTEP setting
as a PCM result, while still requiring the two cases to declare compatible
assumptions where scientific consistency depends on them.

## Decisions already reflected in the current DART work

- DART uses the common `Settings/HOPE_model_settings.yml` workflow with
  `model_mode: DART`.
- Static DART generator and storage fields live in the corresponding standard
  generator and storage tables.
- Real-time load, wind, and solar series remain separate from hourly source
  series because they represent different information and temporal resolution.
- DART validates unsupported GTEP/PCM settings rather than silently applying
  irrelevant features.
- Stable sidecar IDs and a manifest protect identity and input integrity.
- The standalone RTS24 DART case does not require PCM outputs.
- `OperationalSnapshot` and typed conversion functions provide an initial
  deterministic interface for shared installed-system data.

See [DART Input Data](@ref dart-inputs), [RTS24 DART Case](@ref), and
[HOPE-AI: Running HOPE with an LLM Agent](@ref) for the current implemented
interfaces.

## Phased implementation roadmap

### Phase 0 - standalone consistency

- Maintain independently runnable GTEP, PCM, and DART cases.
- Use common settings, validation, stable IDs, and reproducible manifests.
- Keep model-specific data only where the mathematics requires it.

The RTS24 DART work establishes much of this baseline.

### Phase 1 - formal contracts and provenance

- Specify versioned schemas for the canonical contracts.
- Define units, calendars, interval conventions, and missing-data rules.
- Add artifact manifests, parent hashes, and migration policy.
- Build contract-level validators and small round-trip test fixtures.

### Phase 2 - physical realization

- Define technology and topology mapping rules.
- Implement aggregate-build disaggregation and bus siting.
- Add external-data adapters with source and confidence metadata.
- Test energy balance, network connectivity, capacity conservation, and
  deliverability.

### Phase 3 - deterministic cross-model adapters

- Implement GTEP-to-PCM and GTEP-to-DART adapters through the shared contracts.
- Implement optional PCM-state-to-DART handoff.
- Make defaults explicit and emit machine-readable transformation reports.

### Phase 4 - workflow engine

- Add per-run workspaces, state transitions, caching, restart, and atomic
  publication.
- Support branching scenarios and cross-run comparison.
- Expose the same capabilities through Julia APIs, CLI commands, and MCP tools.

### Phase 5 - agent hardening and evaluation

- Give agents least-privilege access to deterministic tools.
- Add idempotency, retries, timeouts, approvals, and audit views.
- Evaluate failure recovery, scenario isolation, numerical reproducibility, and
  incorrect-assumption detection.

### Phase 6 - multi-agent experiments

- Compare one coordinator with tools against specialized cooperating agents.
- Introduce agents only where they improve study quality, interpretability, or
  workload.
- Preserve non-agent workflows as the reproducible reference implementation.

## Acceptance criteria

The architecture is successful when:

- every model remains usable by itself;
- linked runs reproduce the same result from recorded artifacts;
- all cross-model assumptions are inspectable and attributable;
- a failed or repeated agent message cannot mix scenarios or duplicate a run;
- units, time resolution, IDs, and network references are validated before solve;
- a user can trace any output to exact code, settings, inputs, transformations,
  and upstream results; and
- agent-generated analyses can be reproduced through deterministic commands.

## Open design questions

The following decisions should remain open until the underlying HOPE architecture
and representative studies are more complete:

- Which canonical contracts should be Julia structs, portable schemas, or both?
- Which open physical datasets are appropriate by region and voltage level?
- How should competing siting realizations be represented and compared?
- Which PCM outputs are scientifically justified as DART inputs for each study?
- Which operational feedback metrics should generate new GTEP scenarios?
- What belongs in one HOPE service versus separate model-specific services?
- When do specialized agents outperform one agent using well-designed tools?
- Which approvals are required before agents modify cases, launch expensive runs,
  or publish results?

These questions should be answered through concrete workflows and validation
studies rather than by fixing the final agent hierarchy in advance.
