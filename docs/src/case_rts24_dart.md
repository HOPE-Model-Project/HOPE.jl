# RTS24 DART Case

The `RTS24_DART_case` is HOPE's standalone reference case for the day-ahead
and real-time operations workflow. It uses a modified RTS-24 system with:

- 24 buses and 38 branches;
- 33 individual generators;
- five battery resources;
- 8,760 hourly source observations;
- a 24-hour native five-minute realization with 288 intervals; and
- all 19 currently compatible DART constraint families enabled.

The case is maintained in the
[HOPEModelCases](https://github.com/HOPE-Model-Project/HOPEModelCases)
repository.

## Purpose

This case demonstrates a complete DART workflow rather than a PCM-output
postprocessor. The installed fleet, network, hourly forecast, operational
state, reserve offers, and native real-time realization are all explicit case
inputs. No PCM output directory or external PCM case is read at runtime.

The reference run includes:

- binary hourly day-ahead SCUC and rolling five-minute SCED;
- startup, shutdown, minimum up/down, transition, and ramp constraints;
- regulation up/down, spinning reserve, and quick-start NSPIN;
- chronological storage, reserve delivery, and terminal SOC;
- nodal PTDF balance and line limits;
- one strict generator N-1 contingency;
- one realized real-time generator outage;
- a balanced fixed interchange schedule; and
- day-ahead/real-time energy, reserve, uplift, and settlement accounting.

## Run and validate

From a HOPE source checkout with `HOPEModelCases` available as
`ModelCases/`:

```julia
using HOPE

case_path = "ModelCases/RTS24_DART_case"
validation = validate_hope(case_path)
results = run_hope(case_path)
```

The case also includes a command-line wrapper:

```bash
julia --project=. ModelCases/RTS24_DART_case/run_case.jl validate
julia --project=. ModelCases/RTS24_DART_case/run_case.jl run
```

## Input organization

`Settings/HOPE_model_settings.yml` uses `model_mode: DART`. Static DART
generator attributes are merged into `gendata.csv`, and storage reserve
attributes are merged into `storagedata.csv`. Initial generator/storage state
remains in dedicated state files.

The real-time realization is stored separately from the annual hourly source:

- `load_timeseries_realtime_regional.csv`;
- `wind_timeseries_realtime_regional.csv`; and
- `solar_timeseries_realtime_regional.csv`.

Each file has 288 rows and an explicit `Minute` column. See
[DART Input Data](@ref dart-inputs) for the complete schema.

## Reference acceptance result

The verified HiGHS reference run produces:

| Check | Result |
| :-- | --: |
| Constraint families enabled | 19 / 19 |
| Day-ahead solves | 2 optimal |
| Real-time solves | 24 optimal |
| Maximum load shed | 0 MW |
| Maximum emergency load shed | 0 MW |
| Maximum line-limit excess | 0 MW |
| Maximum simultaneous storage charge/discharge | 0 MW |
| Realized-outage generator output | 0 MW |
| Minimum NSPIN award | 38.8554 MW |
| Absolute settlement imbalance | less than `4e-12` |

Machine-readable checks are written to `output/acceptance_summary.csv` and
`output/constraint_coverage.csv`. Dispatch, prices, flows, storage, solver
status, and settlement summaries are written as separate day-ahead and
real-time CSVs.

## Current boundaries

DART currently requires a lossless nodal PTDF network and system-wide reserve
requirements. It supports generator contingencies and pay-as-bid reserve
settlement. Line contingencies, representative days, resource aggregation,
planning reserve, investment, flexible demand, and policy constraints are not
implemented in DART; case validation warns and stops if those common settings
are enabled.
