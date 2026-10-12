
```@meta
CurrentModule = HOPE
```

# HOPE Model Settings Explanation

The `HOPE_model_settings.yml` file configures model switches and run controls.

---

|**Parameter Name** | **Example**| **Description**|
| :------------ | :-----------|:-----------|
|`DataCase:` | `Data_100RPS/`| Input data folder under the case directory.|
|`model_mode:`| `GTEP` | File-based model selector: `GTEP`, `PCM`, or `DART`.|
|`holistic_spatial_basis:`| `zone` | Optional GTEP-to-PCM validation basis: GTEP uses `zone` or `bus`; PCM may use `auto` to inherit the paired GTEP basis. `zone` preserves legacy zonal matching, while `bus` validates a bus-as-zone GTEP case against PCM `busdata`, `branchdata`, and nodal load.|
|`resource_aggregation:`| `1` | `1` aggregate resources before model build; `0` use the full input resource list.|
|`representative_day!:`| `1` | Legacy representative-day switch. `1` endogenous representative-day clustering; `0` full chronology. Prefer `endogenous_rep_day` and `external_rep_day` for new cases.|
|`endogenous_rep_day:`| `1` | `1` let HOPE cluster representative days from full chronology; `0` disable endogenous representative-day clustering.|
|`external_rep_day:`| `0` | `1` use user-provided representative periods and `rep_period_weights`; `0` disable external representative periods.|
|`time_periods:`| `1 : (3, 20, 6, 20)` | Legacy fallback for endogenous representative-day seasons. New advanced endogenous rep-day cases should define this in `HOPE_rep_day_settings.yml`.|
|`flexible_demand:`| `1` | `1` enable DR formulation; `0` disable.|
|`inv_dcs_bin:`| `0` | `GTEP`: `1` binary investment decisions; `0` relaxed investments.|
|`unit_commitment:`| `1` | `PCM`: `0` no UC; `1` integer UC; `2` convexified UC. `DART`: `0` continuous DA dispatch; `1` binary DA SCUC.|
|`carbon_policy:`| `1` | `0` off; `1` emissions cap; `2` cap-and-trade style.|
|`clean_energy_policy:`| `1` | `0` off; `1` RPS with REC trading; `2` local RPS without REC trading.|
|`planning_reserve_mode:`| `1` | `GTEP`: `0` off; `1` system-level RA; `2` zonal RA.|
|`operation_reserve_mode:`| `2` | `GTEP`: `0` off, `1` SPIN only. `PCM`/`DART`: `0` off, `1` REG+SPIN, `2` REG+SPIN+NSPIN.|
|`network_model:`| `3` | `PCM`: `0` no network, `1` zonal transport, `2` nodal DCOPF angle-based, `3` nodal DCOPF PTDF-based. `DART` currently requires `3`.|
|`transmission_loss:`| `0` | `GTEP`/`PCM`: `0` lossless network; `1` piecewise-linear transmission losses using \|flow\|. In `PCM`, this is supported for `network_model = 1` and `2`, but not `3`. `DART` requires `0`.|
|`reference_bus:`| `1` | Reference-bus position for PCM nodal modes and the DART PTDF network.|
|`storage_ld_duration_hours:`| `12` | `GTEP`: long-duration storage threshold (MWh/MW).|
|`write_shadow_prices:`| `0` | `1` enables MILP dual-recovery re-solve in PCM/GTEP. DART performs the fixed-integer pricing solve required by settlement through its own workflow.|
|`summary_table:`| `0` | `PCM`: `1` generate `output/Analysis/Summary_*.csv`; `0` disable. Retained for configuration compatibility in DART; DART always writes its standard result CSVs.|
|`solver:`| `gurobi` | Solver name (`cbc`, `clp`, `glpk`, `gurobi`, `cplex`, etc.).|
|`debug:` | `0` | `0` off; `1` conflict refiner; `2` penalty-based debug. DART currently requires `0`.|
|`save_postprocess_snapshot:`| `1` | GTEP only: `0` do not save; `1` save a minimal postprocessing snapshot; `2` save a full snapshot. DART requires `0`.|

---

Notes:

- Parameters like `VOLL`, `planning_reserve_margin`, reserve requirements, `theta_max`, and other numeric constants are read from `single_parameter` input (not from `HOPE_model_settings.yml`).
- Use `endogenous_rep_day` and `external_rep_day` for new cases. `representative_day!` is still supported for backward compatibility.
- Full chronology corresponds to `endogenous_rep_day = 0` and `external_rep_day = 0`.
- Representative-day mode corresponds to `endogenous_rep_day = 1` or `external_rep_day = 1`. These two settings are mutually exclusive.
- Advanced endogenous representative-day controls are stored in `Settings/HOPE_rep_day_settings.yml`.
- Advanced resource aggregation controls are stored in `Settings/HOPE_aggregation_settings.yml` when `resource_aggregation = 1`, including grouping keys, the `basic` or `feature_based` aggregation method, audit outputs, and PCM clustered thermal commitment.
- For PCM, representative-day mode is currently not the primary production workflow; nodal studies are typically run in full chronology.
- For PCM, summary tables are controlled by `summary_table=1` across network modes; nodal-specific summary tables are generated only when `network_model` is `2` or `3`.
- `save_postprocess_snapshot` is mainly useful for workflows that want to reuse a solved baseline later, such as `HOPE.calculate_erec_from_output(...)`.
- To turn on transmission losses:
  1. set `transmission_loss: 1`,
  2. add optional `Loss (%)` columns to the relevant line input tables,
  3. keep `transmission_loss: 0` in `PCM network_model = 3`, because PTDF mode is currently lossless.



## DART compatibility rules

DART is an operational market model with explicit chronological state. The
following common planning/preprocessing features must be disabled:

```yaml
resource_aggregation: 0
representative_day!: 0
endogenous_rep_day: 0
external_rep_day: 0
flexible_demand: 0
clean_energy_policy: 0
carbon_policy: 0
planning_reserve_mode: 0
inv_dcs_bin: 0
transmission_expansion: 0
save_postprocess_snapshot: 0
network_model: 3
transmission_loss: 0
debug: 0
```

`validate_hope` emits a warning and stops if an unavailable feature is enabled.
This makes accidental reuse of a PCM/GTEP setting visible.

## DART-specific settings

All DART-only controls live under `dart_settings`:

| Setting | Meaning |
| :-- | :-- |
| `availability_mode` | `physical_outages` or `deterministic_for_derating` |
| `enforce_ramps` | Enforce DA hourly and RT subhourly ramp limits |
| `include_storage` | Include installed storage and SOC chronology |
| `real_time_reserve_requirements` | Enforce reserve requirements in RT as well as DA |
| `silent` | Suppress detailed solver logs |
| `files.initial_generator_state` | Initial unit commitment/output/duration state |
| `files.initial_storage_state` | Initial storage SOC |
| `files.real_time_load` | Native RT load file with `Minute` |
| `files.real_time_wind` | Native RT wind file with `Minute` |
| `files.real_time_solar` | Native RT solar file with `Minute` |
| `time.binding_hours` | Number of consecutive hours retained as binding |
| `time.day_ahead_lookahead_hours` | Hourly horizon in each DA SCUC |
| `time.real_time_intervals_per_hour` | RT resolution; must divide 60 |
| `time.real_time_lookahead_intervals` | Number of intervals in each rolling RT SCED |
| `time.source_start_hour` | One-based start row in the hourly source series |
| `security.contingency_generator_ids` | Stable IDs tested as generator N-1 outages |
| `security.line_contingencies` | Must remain `false`; not implemented |
| `security.allow_emergency_contingency_shed` | Permit penalized contingency shedding |
| `security.maximum_security_variables` | Memory guard for contingency variables |
| `realized_outage` | Exogenous RT equipment outage definition |
| `interchange` | Balanced fixed injection/withdrawal schedule |
| `terminal_storage.mode` | `none` or `initial` terminal SOC policy |
| `solve_acceptance` | Policy for accepting solver time-limit incumbents |
| `settlement.reserve_rule` | Currently `pay_as_bid` only |
| `acceptance` | Post-solve quality gates; does not alter the optimization |

Solver algorithm options remain in `Settings/<solver>_settings.yml`.
`solve_acceptance` instead controls whether the DART workflow may continue
after a non-optimal solver termination.

See [DART Input Data](@ref dart-inputs) for the CSV contract and
[RTS24 DART Case](@ref) for a complete settings example.
