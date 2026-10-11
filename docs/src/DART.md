```@meta
CurrentModule = HOPE.DART
```

# DART

DART is HOPE's day-ahead and real-time operations module. It supports both the
typed in-memory Julia API and the standard HOPE case workflow. A file-backed
DART case uses `Settings/HOPE_model_settings.yml`, a `DataCase` directory,
solver settings under `Settings/`, and an `output/` directory, matching PCM
and GTEP wherever the mathematical differences allow.

The V1 model contains:

- hourly individual-generator day-ahead SCUC;
- rolling real-time SCED, normally at five-minute resolution;
- lossless nodal PTDF transmission constraints;
- regulation, spinning, and quick-start non-spinning reserves;
- strict generator N-1 corrective redispatch by default;
- chronological storage with mutually exclusive charge/discharge operation; and
- day-ahead/real-time energy, reserve, and uplift settlements.

The implementation is contained in `src/DART.jl`. The main entry points are
`solve_dart_scuc`, `solve_dart_sced`, `run_dart_rolling`, and
`calculate_dart_settlements`.

## Formulation mapping

| Formulation group | Implementation |
| :-- | :-- |
| SCUC-OBJ, UC-1--UC-4 | Commitment, startup/shutdown, minimum up/down time, and commitment costs |
| GEN-1--GEN-7, RAMP-1--RAMP-2 | Generator bounds, transition limits, hourly ramps, and reserve headroom |
| REN-1--REN-2 | Time-varying availability; zero-cost curtailment is eliminated algebraically |
| RES-1--RES-5 | Product capability, response time, requirements, and quick-start eligibility |
| STO-1--STO-6 | Exclusive charge/discharge modes, SOC chronology, and reserve-energy deliverability |
| NET-1--NET-4 | Nodal injection, balance, PTDF flow, and line limits |
| SEC-1--SEC-5 | One corrective scenario per eligible generator |
| RT-1--RT-3 | Fixed DA commitment and energy-only real-time ramping |
| COUP-1 | Binding RT dispatch and SOC are carried into the next solve |

Ramp-down constraints distinguish dispatch movement from an exogenous reduction
in available Pmax. A falling availability cap receives enough allowance for the
forced output loss; any additional downward movement remains subject to the
configured DA or RT ramp rate. An explicit in-service trip remains fully exempt.

V1 deliberately uses system-wide reserve requirements, nodal load shedding,
generator contingencies, and the lossless PTDF network option. Line outages,
zonal transport, demand response, and policy constraints remain outside this
small operational core.

Contingency load shedding is disabled by default. Set
`allow_emergency_contingency_shed = true` in `DARTConfig` only when a penalized
soft-security solve is preferable to infeasibility.

Quick-start reserve is available only while a unit is offline, in service,
within its response-time qualification, beyond any remaining minimum-down
obligation, and within its availability- and forced-outage-derated capacity.

Storage charge and discharge are separated by a binary operating-mode variable
in both SCUC and SCED. A horizon-end SOC can be imposed by setting
`terminal_storage_soc_mwh` in `DARTForecast`. It is optional because forcing a
terminal target at the end of every short rolling RT look-ahead can distort the
binding dispatch. During rolling simulation, a supplied target applies only to
a slice that reaches the end of the corresponding input forecast.

## Operational safeguards

`DARTDispatchResult` records the solver termination status, primal status,
solve time, and relative optimality gap. An optimal result is always accepted.
By default, a time-limited award is also accepted when it has a feasible primal
solution and a relative gap no greater than one percent. Configure this with
`accept_feasible_time_limit` and `maximum_relative_gap`. The fixed-integer LP
used to produce settlement prices must still solve to optimality.

Explicit generator-contingency variables scale with the number of generators,
intervals, and monitored outages. DART estimates that block before creating it
and rejects a solve above `maximum_security_variables` (two million by
default). Reduce the look-ahead or the set of generators marked
`contingency_eligible`, or deliberately raise the limit after confirming the
available memory and solver capacity.

Inputs are checked before model construction for dimensions, finite values,
physical limits, known reserve products, valid state values, and configuration
consistency.

## Settlements

Energy settles at fixed-integer nodal prices. Because contingency deliverability
can make reserve value resource-specific, V1 pays reserve awards at each
resource's submitted reserve offer instead of reporting a misleading uniform
security-reserve price. The result field
`reserve_requirement_shadow_price_per_mw_hour` is the informational dual of the
system reserve-requirement constraint; settlements do not use it. The
settlement output identifies this rule as `:pay_as_bid`.

Settlement input must contain one binding column per result, a valid
chronological RT-to-DA mapping, and exactly one DA interval of RT duration for
each DA award. Reserve and uplift charges are allocated in proportion to
real-time served energy. If there is no served energy, the amounts are reported
explicitly as `unallocated_reserve_charge` and
`unallocated_uplift_charge`; they are included in the settlement balance rather
than silently disappearing.

## Minimal example

The ModelCases repository contains `DART_two_bus_example.jl`, a programmatic
example with no generated or committed data files.

From the HOPE repository root, run it with:

```bash
julia --project=. ModelCases/DART_two_bus_example.jl
```

## Standard HOPE case workflow

Set `model_mode: DART` in `Settings/HOPE_model_settings.yml`, then call:

```julia
using HOPE
validate_hope("ModelCases/RTS24_DART_case")
results = run_hope("ModelCases/RTS24_DART_case")
```

`validate_dart_settings` warns about and rejects enabled planning-only features
that are incompatible with DART, including resource aggregation,
representative days, policy constraints, planning reserves, investment,
transmission expansion, and flexible demand. This prevents a setting from
being silently ignored. DART currently requires a lossless nodal PTDF network, supports binary or relaxed
day-ahead commitment, and supports the normal HOPE reserve modes.

## Installed-system conversion

HOPE provides a narrow installed-system conversion layer for DART cases:

- `load_operational_snapshot` validates a manifest, source SHA-256 hashes, stable
  IDs, calendar, dimensions, bus references, and network connectivity.
- `build_dart_system` maps nameplate assets and PTDF data under an explicit
  common-subset, deterministic-derated, or physical-outage profile.
- `build_dart_forecasts` creates hourly DA and synthetic repeated five-minute RT
  trajectories with explicit ordered generator and bus IDs. In the standard
  file-backed workflow, configured native load, wind, and solar RT files
  replace those repeated values. Native files must provide `Month`, `Day`,
  `Hours`, and an explicit `Minute` column aligned to the configured RT step.
  If no native files are configured, HOPE warns before using the repeated-hourly
  fallback; if configured files omit `Minute`, validation warns and rejects
  them. Set `include_real_time_reserve_requirements=false` for DA procurement
  with RT reserve variables retained for contingency response.
- `build_dart_initial_state` creates a documented warm-up seed; an evaluation
  workflow should replace it with the final realized state of a warm-up run.
- `select_dart_windows` identifies deterministic peak-net-load, largest-ramp, and
  low-renewable hours.

The converter reads immutable physical inputs, not PCM report CSV files. It
rejects disconnected networks, asymmetric line ratings, nonzero interchange,
must-run semantics, and unverified quick-start NSPIN capability rather than
silently changing them.

See [DART Input Data](@ref dart-inputs) for the file schema and validation
rules.

The `RTS24_DART_case` in ModelCases is a standalone standard case with all 19
compatible DART constraint families enabled. It demonstrates manifest and ID
validation, rolling DA/RT operation, physical outage realization, strict
security, storage, reserves, interchange, and settlements:

```bash
julia --project=. ModelCases/RTS24_DART_case/run_case.jl validate
julia --project=. ModelCases/RTS24_DART_case/run_case.jl run
```

See [RTS24 DART Case](@ref) for the complete reference-case walkthrough.
