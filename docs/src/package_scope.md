# Package scope and public API

HOPE 2.0 supports five Julia workflows:

- GTEP capacity expansion through `run_hope` and `create_GTEP_model`;
- PCM production-cost modeling through `run_hope` and `create_PCM_model`;
- two-stage GTEP-to-PCM studies through `run_hope_holistic` and
  `run_hope_holistic_fresh`;
- EREC postprocessing through `calculate_erec` and
  `calculate_erec_from_output`; and
- file-backed DART studies through `run_hope` and `validate_hope`, plus
  programmatic day-ahead/real-time SCUC and SCED through the exported DART
  types and functions.

## Supported public interface

The supported interface is the set of names exported by `HOPE` and documented
in the [API Reference](@ref reference). The main groups are:

- case execution: `run_hope`, `run_hope_holistic`,
  `run_hope_holistic_fresh`, `load_data`, `solve_model`, and
  `write_output`;
- model construction: `create_GTEP_model`, `create_PCM_model`, and
  `initiate_solver`;
- temporal and resource preprocessing: `build_endogenous_rep_periods`,
  `resolve_rep_day_time_periods`, `aggregate_gendata_gtep`, and
  `aggregate_gendata_pcm`;
- EREC: `calculate_erec`, `calculate_erec_from_output`,
  `load_erec_settings`, and `load_postprocess_snapshot`;
- DART: `load_dart_case`, `validate_dart_case`, `run_dart_case`, the
  exported `DART*` data/result types, installed-system converters, model
  builders, solvers, rolling-state helpers, and settlement calculation.

Unexported names are implementation details and may change without deprecation.
Input CSV/XLSX columns and YAML settings form a versioned data contract; breaking
changes are documented in the changelog.

## Installation and data boundaries

Loading `HOPE` imports only Julia dependencies and the bundled open-source
solver wrappers. It does not require a commercial solver license, Python,
dashboard services, MCP services, internet downloads, or a local model-case
checkout.

Gurobi, SCIP, and CPLEX support is supplied through Julia package extensions.
Install the selected solver package and its external license separately. The
dashboard and MCP applications under `tools/` have independent Python
environments and are not package dependencies.

Large cases and reference outputs live in
[HOPEModelCases](https://github.com/HOPE-Model-Project/HOPEModelCases). Select
case and output directories explicitly; HOPE does not write into its installed
package directory. Tests use temporary directories for generated outputs.

## Current limitations

- GTEP, PCM, and DART file-based workflows require a compatible external case
  directory. DART also retains a self-contained typed in-memory API.
- DART V1 uses lossless nodal PTDF networks, system-wide reserves, generator
  contingencies, and pay-as-bid reserve settlement. Line contingencies, zonal
  transport, demand response, and policy constraints are outside its current
  scope.
- Clp is unavailable on Apple Silicon; HiGHS remains the default open-source
  solver there.
- Commercial-solver extensions are maintained, but license-backed numerical
  tests are not part of mandatory CI.
- Dashboards and MCP tooling are optional applications, not stable Julia package
  APIs.

## Version 2 migration

HOPE 2.0 replaces the symmetric transmission input column
`Capacity (MW)` with required `Forward Capacity (MW)` and
`Reverse Capacity (MW)` columns. For a previously symmetric line, copy the
old capacity value into both new columns. No automatic migration occurs during
package loading.
