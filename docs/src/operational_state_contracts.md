# [Operational-State Contracts](@id operational-state-contracts)

HOPE uses a versioned `HOPE.simulation_state` artifact to carry physical state
across chronological model boundaries. It can initialize a DART run from a
preceding PCM or DART run, or preserve a documented standalone warm start.
It does not make PCM a prerequisite for DART.

The artifact contains only state that physically carries across the boundary:

- generator commitment, output, elapsed on/off duration, and in-service status;
- storage state of charge;
- the exact boundary timestamp, timezone, and preceding interval resolution;
- a fingerprint of the consuming physical system; and
- hashes of parent artifacts, state files, and semantic metadata.

Forecasts, reserve requirements, bids, contingencies, market rules, and
settlement assumptions remain in the downstream DART case. Installed generator
and network attributes remain in the physical-system inputs. This separation
prevents a prior model's local assumptions from silently becoming DART inputs.

## Artifact layout

```text
operational_state/
|-- manifest.yml
|-- generator_state.csv
`-- storage_state.csv
```

The normative field definition is `schemas/operational_state_v1.yml`. Stable
IDs, rather than CSV row numbers, connect the artifact to the consumer. The
loader rejects unknown schema versions, modified files, duplicate or missing
IDs, incompatible physical systems, invalid bounds, and a mismatched artifact
ID.

## DART use

Existing DART cases may continue using `initial_generator_state.csv` and
`initial_storage_state.csv`. A linked case can instead select one artifact,
relative to its `DataCase` directory:

```yaml
dart_settings:
    files:
        operational_state_artifact: ../state_from_pcm
```

Do not configure the artifact and legacy initial-state CSVs together. The rest
of the DART scenario—DA/RT time series, outages, reserve products, and settlement
rules—remains independently configurable.

Every completed DART run publishes its final binding state under
`output/operational_state/`. That directory is atomically published with the
other results and can initialize a subsequent run without parsing dispatch
tables.

## Programmatic API

```julia
artifact = HOPE.write_operational_state_artifact(
    "state_from_pcm",
    dart_system,
    boundary_state;
    boundary_time = DateTime(2035, 7, 1, 12),
    timezone = "America/New_York",
    interval_minutes = 60,
    source_model = "PCM",
    scenario_id = "md-2035-weather-a",
    initialization_method = "preceding_run",
    parent_artifact_hashes = Dict("pcm_run" => pcm_run_hash),
)

loaded = HOPE.load_operational_state_artifact("state_from_pcm", dart_system)
```

For a solved PCM model, the producer adapter constructs and writes the artifact
directly:

```julia
artifact = HOPE.write_pcm_operational_state_artifact(
    "state_from_pcm",
    pcm_result, # result from run_hope or run_hope_holistic
    target_dart_system;
    boundary_hour = 168,
    boundary_time = DateTime(2035, 7, 8),
    timezone = "America/New_York",
    scenario_id = "md-2035-weather-a",
)
```

`run_hope` and `run_hope_holistic` capture the required PCM trajectory in a
solver-neutral in-memory trace immediately after optimization when the PCM input
has stable `Asset_ID` columns. Cases without those columns continue to run, but
cannot publish a safe cross-model state artifact. The artifact writer uses the
trace rather than depending on a live commercial-solver handle. The trace is an
intermediate workflow object; the immutable artifact directory is the portable
deliverable for another model, process, or agent.

The PCM and target DART assets must match exactly through `Asset_ID` by default.
The column names are configurable, but implicit row-number matching is refused.
Commitment-enabled DART units require integer PCM commitment and one physical
unit per PCM row. Relaxed UC and clustered multi-unit rows are rejected because
they do not define which physical units are online. The adapter derives elapsed
on/off time from consecutive solved PCM intervals and records that durations are
left-censored at the beginning of the PCM horizon.
Because PCM is hourly, its artifact records `interval_minutes: 60`; the DART
consumer may still advance at its independently configured five-minute cadence.

Artifact directories are immutable: the writer refuses to overwrite an existing
path. A workflow should publish a new artifact for each state boundary and pass
its `artifact_id` to downstream models or agents.

## Connection semantics

- **PCM to DART:** transfer the selected boundary state only when both models
  use compatible stable unit IDs and the same physical-system fingerprint.
- **GTEP to DART:** first realize the GTEP plan as a physical system, then create
  a warm-up or assumed state. GTEP does not produce commitment or SOC state.
- **Standalone DART:** use the existing CSV initialization or an artifact whose
  `initialization_method` explicitly records `warm_start`, `observed`, or
  `assumed`.
- **DART to DART:** consume the automatically published final-state artifact for
  chronological continuation or scenario branching.

This contract and adapter implement the operational-state layer without changing
either PCM or DART mathematics. Selecting stress events and constructing the
separate DART market scenario remain workflow-level decisions.
