
```@meta
CurrentModule = HOPE
```

# Model Overview

HOPE's core optimization models and workflows are:

1. the `GTEP` generation and transmission expansion planning model;
2. the `PCM` production cost model for system operation;
3. the `DART` day-ahead and real-time SCUC/SCED model, with both file-backed and typed in-memory workflows;
4. the holistic two-stage `GTEP`-to-`PCM` workflow; and
5. the `EREC` postprocessing workflow.

An OPF formulation is planned for future development.

## Shared Modeling Features

Both `GTEP` and `PCM` support:

- RPS policy via `clean_energy_policy`: off (`0`), REC trading (`1`), or local annual compliance without `pwe` trading variables (`2`)
- Carbon policy options via `carbon_policy`:
  - `0`: off
  - `1`: state emissions cap with penalty slack
  - `2`: state allowance/cap-and-trade style with penalty slack
- Flexible demand (DR) on/off via `flexible_demand`
- Optional MILP fixed-LP dual recovery via `write_shadow_prices = 1`

## GTEP Configuration Options

- `inv_dcs_bin`:
  - `1`: binary investment/retirement decisions (MILP)
  - `0`: relaxed investment decisions (LP relaxation)
- `planning_reserve_mode`:
  - `0`: off
  - `1`: system-level RA
  - `2`: zonal RA
- `operation_reserve_mode`:
  - `0`: off
  - `1`: SPIN reserve only
- Storage chronology:
  - Full-year mode (`endogenous_rep_day = 0` and `external_rep_day = 0`): cyclic SOC wrap across hour 8760 -> hour 1
  - Representative-day mode (`endogenous_rep_day = 1` or `external_rep_day = 1`): short-duration storage uses day anchors; long-duration storage links across representative periods

## PCM Configuration Options

- `unit_commitment`:
  - `0`: no UC
  - `1`: integer UC (MILP)
  - `2`: convexified UC
- `network_model`:
  - `0`: no network constraints (copper plate)
  - `1`: zonal transport
  - `2`: nodal DCOPF (angle-based)
  - `3`: nodal DCOPF (PTDF-based)
- `operation_reserve_mode`:
  - `0`: off
  - `1`: REG + SPIN
  - `2`: REG + SPIN + NSPIN
- `summary_table`:
  - `1`: write summary analytics to `output/Analysis/Summary_*.csv`

## DART Module

DART provides individual-generator day-ahead SCUC, rolling real-time SCED,
generator N-1 security, storage and reserve co-optimization, and two-settlement
accounting. Standard cases use `Settings/HOPE_model_settings.yml` with
`model_mode: DART`; the typed Julia API remains available for programmatic
studies.

DART currently requires a lossless nodal PTDF network. Compatible operating
features include binary or continuous day-ahead commitment, hourly DA and
subhourly RT chronology, four reserve products, generator contingencies,
realized outages, storage, interchange, and settlement. Planning, investment,
representative-day, aggregation, policy, and flexible-demand features are
rejected during DART validation rather than silently ignored.

See [DART](@ref), [DART Input Data](@ref dart-inputs), and
[RTS24 DART Case](@ref).
