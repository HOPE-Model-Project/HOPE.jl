# `MD_GTEP_holistic_full8760_case_v20260406g` / `MD_PCM_holistic_full8760_case_v20260406g`

GTEP case path: `ModelCases/MD_GTEP_holistic_full8760_case_v20260406g`
PCM case path: `ModelCases/MD_PCM_holistic_full8760_case_v20260406g`

Reference preserved solved pair:

- GTEP: `ModelCases/MD_GTEP_holistic_full8760_case_v20260406g_gtep_run_20260406_210316_674`
- PCM: `ModelCases/MD_PCM_holistic_full8760_case_v20260406g_pcm_run_20260406_210316_734`

## Retained Artifacts

After repo cleanup, this Maryland benchmark is intentionally documented around only the artifacts that should remain part of the long-term repo surface:

- source GTEP case: `ModelCases/MD_GTEP_holistic_full8760_case_v20260406g`
- source PCM case: `ModelCases/MD_PCM_holistic_full8760_case_v20260406g`
- preserved reference GTEP run: `ModelCases/MD_GTEP_holistic_full8760_case_v20260406g_gtep_run_20260406_210316_674`
- preserved reference PCM run: `ModelCases/MD_PCM_holistic_full8760_case_v20260406g_pcm_run_20260406_210316_734`

Older intermediate Maryland holistic variants were exploratory build/debug artifacts and are not part of the benchmark definition.

## Current Build Summary

This is the canonical small full-function Maryland holistic benchmark for HOPE.

The benchmark uses a shared Maryland-only four-zone baseline for both stages, runs the full 8760-hour chronology, and exercises the full direct `run_hope_holistic(...)` handoff from GTEP investment decisions into PCM operations.

The final `v20260406g` pair is the first Maryland full-year holistic benchmark in this repo that is both structurally correct and operationally healthy:

- the GTEP and PCM stages start from the same Maryland-only baseline
- the load file preserves the original `NI` net-import semantics used by HOPE
- current HOPE releases realize the handoff in memory and persist an auditable copy beside the PCM outputs without modifying the source case
- the preserved reference solve completes end to end with zero annual load shedding in both stages

## Review Focus

This page is meant to support review of four specific claims:

- the benchmark is a true shared-baseline GTEP-to-PCM pair rather than two loosely related MD cases
- the Maryland-only reduction kept the intended topology, load, and policy semantics
- new runs record the in-memory handoff in `output_holistic/realized_inputs/`, including mapping audits and a manifest
- the preserved successful pair is stable enough to use as the repo's main small full-function holistic regression benchmark

## Model Setup Snapshot

### Shared Benchmark Facts

| Metric | Value |
| :-- | --: |
| Zones | 4 |
| Hours | 8760 |
| Existing generators | 276 |
| Candidate generators | 17 |
| Existing storage assets | 1 |
| Candidate storage assets | 4 |
| Existing lines | 7 |
| Candidate lines | 12 |

Retained Maryland zones:

- `APS_MD`
- `BGE`
- `PEPCO`
- `DPL_MD`

### GTEP Settings

| Setting | Value |
| :-- | :-- |
| `model_mode` | `GTEP` |
| `DataCase` | `Data_100RPS/` |
| `resource_aggregation` | `1` |
| `endogenous_rep_day` | `0` |
| `external_rep_day` | `0` |
| `clean_energy_policy` | `1` |
| `carbon_policy` | `0` |
| `planning_reserve_mode` | `1` |
| `operation_reserve_mode` | `0` |
| `transmission_loss` | `0` |
| `solver` | `gurobi` |

### PCM Settings

| Setting | Value |
| :-- | :-- |
| `model_mode` | `PCM` |
| `DataCase` | `Data_PCM2035/` |
| `resource_aggregation` | `1` |
| `endogenous_rep_day` | `0` |
| `unit_commitment` | `1` |
| `operation_reserve_mode` | `1` |
| `network_model` | `1` (zonal transport) |
| `transmission_loss` | `0` |
| `clean_energy_policy` | `1` |
| `carbon_policy` | `0` |
| `solver` | `gurobi` |

Shared planning assumptions:

- Maryland RPS target: `0.6`
- planning reserve margin: `0.15`
- full chronology instead of representative days
- resource aggregation enabled in both stages

## Current Solved Status

| Metric | Value |
| :-- | :-- |
| GTEP stage | solved successfully |
| PCM stage | solved successfully |
| GTEP total load shedding | `0 MWh` |
| PCM total load shedding | `0 MWh` |
| GTEP total cost | `2.083038347e9` |
| PCM total cost | `6.591105285e8` |
| GTEP new generation rows | `8` |
| GTEP new storage rows | `2` |
| GTEP new line rows | `0` |

Reference output directories:

- GTEP output: `output/`
- PCM output: `output_holistic/`
- realized PCM handoff for new runs: `output_holistic/realized_inputs/`

## GTEP Stage Results

Observed new generation builds from the preserved successful GTEP solve:

| Zone | Technology | New capacity (MW) |
| :-- | :-- | --: |
| `APS_MD` | `WindOn` | 1315.931 |
| `APS_MD` | `SolarPV` | 1579.117 |
| `DPL_MD` | `WindOn` | 1096.686 |
| `DPL_MD` | `SolarPV` | 1423.228 |
| `BGE` | `WindOn` | 3671.260 |
| `BGE` | `SolarPV` | 351.256 |
| `PEPCO` | `WindOn` | 2238.523 |
| `PEPCO` | `SolarPV` | 1705.376 |

Observed new storage builds:

| Zone | Technology | New power (MW) | New energy (MWh) |
| :-- | :-- | --: | --: |
| `APS_MD` | `Battery` | 2535.863 | 10143.453 |
| `DPL_MD` | `Battery` | 321.503 | 1286.013 |

Transmission expansion outcome:

- no new candidate line is built in the preserved successful solve

GTEP zonal total costs from `output/system_cost.csv`:

| Zone | Total cost |
| :-- | --: |
| `APS_MD` | `5.612484953e8` |
| `BGE` | `5.693323799e8` |
| `PEPCO` | `7.023822875e8` |
| `DPL_MD` | `2.500751847e8` |

## PCM Stage Results

The preserved PCM solve completes on the handed-off post-GTEP system with zero annual load shedding and writes the full `output_holistic/` result set.

PCM zonal total costs from `output_holistic/system_cost.csv`:

| Zone | Total cost |
| :-- | --: |
| `APS_MD` | `1.910548924e7` |
| `BGE` | `1.367669397e8` |
| `PEPCO` | `4.448672637e8` |
| `DPL_MD` | `5.837083588e7` |

Annual storage operations from the preserved PCM outputs:

| Metric | Value |
| :-- | --: |
| Total battery charge | `1.122580865e7 MWh` |
| Total battery discharge | `9.091401054e6 MWh` |

## Holistic Handoff Check

This benchmark is also the reference case for verifying that the GTEP-to-PCM transfer is persisted correctly.

The preserved PCM `output_holistic/resource_aggregation_summary.csv` explicitly contains the handed-off build groups `G29` through `G36`, matching the eight new VRE build rows from the GTEP stage:

| Aggregated resource | Zone | Type | Original Pmax (MW) |
| :-- | :-- | :-- | --: |
| `G29` | `APS_MD` | `WindOn` | 1315.931 |
| `G30` | `APS_MD` | `SolarPV` | 1579.117 |
| `G31` | `DPL_MD` | `WindOn` | 1096.686 |
| `G32` | `DPL_MD` | `SolarPV` | 1423.228 |
| `G33` | `BGE` | `WindOn` | 3671.260 |
| `G34` | `BGE` | `SolarPV` | 351.256 |
| `G35` | `PEPCO` | `WindOn` | 2238.523 |
| `G36` | `PEPCO` | `SolarPV` | 1705.376 |

That makes this pair the repo's main regression benchmark for:

- shared-baseline holistic execution
- Maryland-only topology correctness
- `NI`-preserving load semantics
- PCM input persistence after GTEP handoff
- zero-load-shedding end-to-end validation

## Reproduction

The benchmark can be rerun from the retained source pair through the library entry point that creates fresh case clones before solving:

```julia
using HOPE

result = HOPE.run_hope_holistic_fresh(
    "ModelCases/MD_GTEP_holistic_full8760_case_v20260406g",
    "ModelCases/MD_PCM_holistic_full8760_case_v20260406g",
)
```

That workflow is preferred over case-specific runner scripts because it keeps the reusable orchestration in `src/run_holistic.jl` and avoids reusing stale `output/` trees.

## Reference Files

- Source pair builder: `tools/repo_utils/build_md_holistic_full_pair.jl`
- Holistic library entry points: `src/run_holistic.jl` via `HOPE.run_hope_holistic(...)` and `HOPE.run_hope_holistic_fresh(...)`
- Structural validator: `tools/repo_utils/md_holistic_full_pair/validate_md_holistic_full_pair.jl`
