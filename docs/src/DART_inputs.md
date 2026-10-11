# [DART Input Data](@id dart-inputs)

A file-backed DART case follows the same top-level contract as GTEP and PCM:

```text
case/
├── Settings/
│   ├── HOPE_model_settings.yml
│   └── <solver>_settings.yml
├── <DataCase>/
├── manifest.yml
├── stable_ids.csv
└── output/
```

`model_mode: DART` selects the DART loader. The `DataCase` value identifies
the input directory, while `manifest.yml` pins the expected files and SHA-256
hashes. `stable_ids.csv` assigns durable generator, storage, bus, and branch
identifiers independently of source-file labels.

## Installed-system files

DART reuses the normal installed-system CSVs:

| File | DART use |
| :-- | :-- |
| `busdata.csv` | Bus identity, zone, and peak load |
| `branchdata.csv` | Fixed network topology, reactance, and directional ratings |
| `gendata.csv` | Installed generator capability, cost, commitment, flexibility, and reserves |
| `storagedata.csv` | Installed storage energy, power, efficiency, cost, and reserves |
| `single_parameter.csv` | VOLL, reserve requirements, and reserve response times |
| `load_timeseries_regional.csv` | Hourly day-ahead load factors |
| `wind_timeseries_regional.csv` | Hourly day-ahead wind availability |
| `solar_timeseries_regional.csv` | Hourly day-ahead solar availability |

The converter validates row counts, stable-ID coverage, bus references,
calendar ordering, finite values, and network connectivity before model
construction. The current DART network formulation requires symmetric normal
ratings and a lossless nodal PTDF representation.

## Generator DART columns

DART-specific static generator attributes live directly in `gendata.csv`.
They are optional for generic installed-system conversion and default
conservatively, but a full DART case should define them explicitly:

| Column | Meaning |
| :-- | :-- |
| `quick_start_eligible` | Whether an offline unit may provide NSPIN |
| `quick_start_time_minutes` | Time required to qualify as quick-start |
| `no_load_cost_per_hour` | Hourly committed no-load cost |
| `shutdown_cost` | Cost of a shutdown transition |
| `startup_limit_fraction` | Startup output limit as a fraction of Pmax |
| `shutdown_limit_fraction` | Shutdown output limit as a fraction of Pmax |
| `nspin_capability_mw` | Explicit offline non-spinning capability |
| `reg_up_offer_per_mw_hour` | Regulation-up reserve offer |
| `reg_down_offer_per_mw_hour` | Regulation-down reserve offer |
| `spin_offer_per_mw_hour` | Spinning-reserve offer |
| `nspin_offer_per_mw_hour` | Non-spinning-reserve offer |

`Flag_UC` remains the canonical commitment-required flag. A quick-start unit
that provides offline NSPIN still needs commitment variables, so it must use
`Flag_UC = 1`.

## Storage DART columns

Storage reserve data live directly in `storagedata.csv`:

| Column | Meaning |
| :-- | :-- |
| `reg_up_capability_mw` | Regulation-up capability |
| `reg_down_capability_mw` | Regulation-down capability |
| `spin_capability_mw` | Spinning-reserve capability |
| `nspin_capability_mw` | Non-spinning-reserve capability |
| `reg_up_offer_per_mw_hour` | Regulation-up offer |
| `reg_down_offer_per_mw_hour` | Regulation-down offer |
| `spin_offer_per_mw_hour` | Spinning-reserve offer |
| `nspin_offer_per_mw_hour` | Non-spinning-reserve offer |

## Initial operational state

Chronological operation requires state that cannot be inferred from static
nameplate data:

- `initial_generator_state.csv` provides commitment, generation, in-service
  status, and elapsed online/offline durations for every stable generator ID.
- `initial_storage_state.csv` provides initial stored energy for every stable
  storage ID.

These files intentionally remain separate from `gendata.csv` and
`storagedata.csv`: they describe the start of a simulation, not permanent
asset properties.

## Native real-time series

A DART case may configure three native subhourly files:

```yaml
dart_settings:
    files:
        real_time_load: load_timeseries_realtime_regional.csv
        real_time_wind: wind_timeseries_realtime_regional.csv
        real_time_solar: solar_timeseries_realtime_regional.csv
```

All three files must be supplied together. Each row must contain `Month`,
`Day`, `Hours`, and `Minute`, followed by the regional columns used by the
installed system. `Hours` follows HOPE's 1:24 convention. `Minute` must align
with `real_time_intervals_per_hour`; for 12 intervals per hour it is
`0, 5, 10, ..., 55`.

The native files must have matching, unique, consecutive timestamps and cover
the selected DA/RT horizon. Load factors must be finite and nonnegative.
Wind and solar availability must lie in `[0, 1]`. Nonzero interchange belongs
in `dart_settings.interchange`, not the regional `NI` column.

The hourly files continue to define the day-ahead forecast. Native real-time
load replaces repeated hourly load, while native wind and solar values replace
the corresponding real-time renewable availability. Conventional-unit
availability remains governed by the installed system and configured outage.

If no native real-time files are configured, HOPE warns and falls back to
repeated hourly values or the legacy inline multiplier pattern. If files are
configured without `Minute`, HOPE warns and rejects them because their
subhourly chronology cannot be verified.

## Manifest and validation

The standalone format currently uses `schema_version: 2`. This version marks
the merged static DART columns and native real-time file contract; it is not a
scenario identifier. Scenario selection continues to come from the case/input
folder chosen by the user.

Validate a case without solving or writing outputs:

```julia
using HOPE
validation = validate_hope("/path/to/case")
```

Validation verifies manifest hashes, stable IDs, the installed network,
chronology, initial state, compatible settings, and enabled DART constraint
families.
