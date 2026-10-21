# PCM Inputs Explanation

The input files for the **HOPE** model could be one big .XLSX file or multiple .csv files. If you use the XLSX file, each spreadsheet in the file needs to be prepared based on the input instructions below and the spreadsheet names should be carefully checked. If you use the csv files, each csv file will represent one spreadsheet from the XLSX file. If both XLSX file and csv files are provided, the XLSX files will be used.

## network_model setting

In `HOPE_model_settings.yml`, set:

- `network_model: 0` for no network constraints (copper plate).
- `network_model: 1` for zonal transport.
- `network_model: 2` for nodal DCOPF (angle-based).
- `network_model: 3` for nodal DCOPF (PTDF-based).

When using nodal modes (`2`/`3`), provide nodal mapping via `busdata` and `branchdata` (or ensure `linedata` includes equivalent bus columns). Native nodal load must come from `load_timeseries_nodal`, and optional bus-level NI can come from `ni_timeseries_nodal`.

Related run-control settings:

- `unit_commitment: 1` makes PCM a MILP.
- `write_shadow_prices: 1` triggers MILP -> fixed-LP re-solve for dual/LMP recovery when `unit_commitment: 1`.
- `summary_table: 1` writes summary analytics to `output/Analysis/Summary_*.csv`.
- `transmission_loss: 1` enables a piecewise-linear transmission loss approximation based on absolute line flow. This is currently supported for `network_model = 1` and `2`, but not `3`.

Price-output note:

- HOPE exports `power_price*.csv` as the marginal objective cost of `+1 MW` load.
- Because raw equality-constraint duals can flip sign under equivalent reformulations, HOPE applies a formulation-specific sign mapping internally.
- For `network_model = 0/1/2`, exported price follows the raw dual of the load-balance row.
- For `network_model = 3`, exported price uses the negative of the raw dual of `PTDFInjDef_con`.
- This mapping is regression-tested on both the ISO-NE nodal angle case and the RTS24 nodal PTDF case.

Simple workflow for line losses:

1. Keep `transmission_loss: 0` if you want the default lossless PCM run.
2. Set `transmission_loss: 1` only when your active line table includes a `Loss (%)` column.
3. Use `network_model = 1` or `2` with transmission losses.
4. Keep `network_model = 3` with `transmission_loss: 0`; PTDF mode remains lossless in the current HOPE release.
5. In nodal angle-based PCM (`network_model = 2`), HOPE now reports a nonzero `Loss` price component when transmission losses are active.

## internal network helper utilities

These functions are implemented in `src/network_utils.jl` and used by `src/PCM.jl`:

- `first_existing_col`: finds the first available column name among aliases (for robust input parsing).
- `resolve_reference_index`: resolves reference bus/zone from either integer index or ID value.
- `compute_ptdf_from_incidence`: computes PTDF matrix from branch incidence and reactance.
- `compute_zone_ptdf_from_linedata`: convenience wrapper to build zonal PTDF from `linedata` (reserved for a future zonal-PTDF mode; not used in current PCM flow).

They are automatically called in PCM network preprocessing; users do not need to call them directly.

## zonedata

This is the input dataset for zone-relevant information (e.g., demand, mapping with state, etc.).

---

|**Column Name** | **Description**|
| :------------ | :-----------|
|Zone_id | Name of each zone (should be unique)|
|Demand (MW) | Peak demand of the zone in MW|
|State | The state that the zone is belonging to|
|Area | The area that the zone is belonging to|

---

## gendata

This is the input dataset for existing generators.

---

|**Column Name**|**Description**|
|:------------|:-----------|
|Pmax (MW)|Maximum generation (nameplate) capacity of the generator in MW|
|Pmin (MW)|Minimum generation (nameplate) capacity of the generator in MW|
|Zone|The zone that the generator is belonging to|
|Type|The technology type of the generator|
|Flag_thermal|1 if the generator belongs to thermal units, and 0 otherwise|
|Flag_VRE|1 if the generator belongs to variable renewable energy units, and 0 otherwise|
|Flag_mustrun|1 if the generator must run at its nameplate capacity, and 0 otherwise|
|Flag_UC|1 if the generator is eligible for unit commitment constraints, and 0 otherwise|
|Cost (\$/MWh)|Operating cost of the generator in \$/MWh|
|Start_up_cost (\$/MW)|Start up cost for UC generator in \$/MW|
|EF|The CO2 emission factor for the generator in tons/MWh|
|CC|The capacity credit for the generator (it is the fraction of the installed/nameplate capacity of a generator that can be relied upon at a given time)|
|FOR|Forced outrage rate, unitless|
|RM_SPIN|Spinning reserve margin, unitless|
|RU|Ramp up rate, unitless|
|RD|Ramp down rate, unitless|
|Min_down_time|Minimum down time for turning off a generator, hour|
|Min_up_time|Minimum up time for turning on a generator, hour|

---

## operational_resource_templates (optional holistic input)

`operational_resource_templates.csv` is an optional PCM-owned registry used by
the GTEP-to-PCM holistic workflow. A candidate generator or storage row selects
a template through `Operational_Template_ID`. The table must contain unique
`Operational_Template_ID`, `Resource_Kind`, and `Type` values and may include
the operating columns used by `gendata.csv` or `storagedata.csv`.

The precedence is candidate-specific value, referenced template, existing PCM
zone/type average, existing PCM type average, and finally the documented code
default. New thermal generators are always assigned `Flag_UC = 1`. The registry
does not modify existing PCM resources and is ignored by a standalone PCM run;
it is consumed only when GTEP builds are realized into PCM inputs. Cases without
the file remain backward compatible.

The realized-input directory records template decisions in
`operational_parameters_audit.csv`.

## gen_availability_timeseries (optional)

This optional dataset provides hourly **generator-level** availability factors for PCM. It can be used for plant-based VRE profiles and for thermal derating.

Accepted names:

- CSV: `gen_availability_timeseries.csv`
- XLSX sheet: `gen_availability_timeseries`

Expected generator columns:

- `G1`, `G2`, ..., `G(N)`
- ordering follows the row order of `gendata.csv`

Required time columns:

- `Time Period`
- `Hours`

Optional time columns:

- `Month`
- `Day`

Behavior in current PCM:

- If any generator column is provided here, PCM uses that hourly AF for that generator.
- For wind/solar generators with no hourly `G#` column, PCM falls back to zonal `wind_timeseries_regional` or `solar_timeseries_regional`.
- For non-VRE generators with no hourly `G#` column, PCM falls back to the static `AF` column in `gendata`.
- For thermal generators, the hourly AF only derates the generation upper bound. PCM keeps reserve, ramp, and UC availability logic on the original `1-FOR` basis.

So this file is now the main **generator-level availability override** for PCM, with zonal VRE profiles and static generator AF used as fallbacks when a generator-specific hourly column is not supplied.

## linedata

This is the input dataset for existing transmission lines (e.g., transmission capacity limit for each inter-zonal transmission line).

---

|**Column Name** | **Description**|
| :------------ | :-----------|
|From_zone | Starting zone of the inter-zonal transmission line|
|To_zone | Ending zone of the inter-zonal transmission line|
|X or Reactance | Line reactance (recommended for nodal modes). If omitted, current code falls back to unit values (`B_l = 1` / `X = 1`) with a warning.|
|Forward Capacity (MW) | Maximum positive flow from `From_zone` to `To_zone`|
|Reverse Capacity (MW) | Maximum magnitude of negative flow from `To_zone` to `From_zone`|
|Loss (%) *(optional)* | Line loss rate used only when `transmission_loss = 1`. Values can be given as percent (`2`) or fraction (`0.02`). Missing values default to `0`. Shipped example files may keep this column at `0` so the default case behavior stays lossless.|

Both directional capacity columns are required. For a symmetric line, repeat
the same value in both columns. The former transmission input column
`Capacity (MW)` is no longer accepted.

See [GTEP inputs: migrating legacy transmission tables](GTEP_inputs.md#migrating-legacy-transmission-tables)
for the repository migration utility. The same strict contract applies to PCM
`linedata` and `branchdata`.

---

## busdata (optional for zonal modes, recommended for nodal modes)

This dataset defines nodal buses and bus-to-zone mapping.

Required columns for nodal modes:

- `Bus_id`
- `Zone_id`
- one nodal peak-load basis column:
  - `Demand (MW)`, or
  - `Load (MW)`, or
  - `Pd`, or
  - `PD`, or
  - `Load_share`

Optional columns:

- `State` for nodal state-policy accounting. When `network_model` is `2` or `3`, PCM now uses bus-to-state mapping for carbon/RPS accounting if this column is provided. If omitted, PCM falls back to the state of the bus's assigned zone.

CSV name: `busdata.csv`
XLSX sheet name: `busdata`

## branchdata (optional; used preferentially in nodal modes)

This dataset defines nodal transmission branches.

Recommended columns:

- `from_bus`/`to_bus` (or MATPOWER-style `F_BUS`/`T_BUS`)
- `Forward Capacity (MW)` (positive-flow thermal/transfer limit)
- `Reverse Capacity (MW)` (negative-flow thermal/transfer limit magnitude)
- `X` or `Reactance` (for DC angle/PTDF physics)
- `Loss (%)` *(optional; supported when `network_model = 2` and `transmission_loss = 1`)*
- `delta_theta_max` *(optional)*: per-line max angle difference (radians). If omitted/<=0, disabled.

If `branchdata` is provided and `network_model` is nodal, HOPE uses it as network branch input.

Positive branch flow follows `from_bus` to `to_bus`; negative flow follows the
opposite direction. Both directional limits are required, even when they are
equal.

PTDF note:

- `network_model = 3` uses a lossless PTDF-based DCOPF. Keep `transmission_loss: 0` in that mode.

CSV name: `branchdata.csv`
XLSX sheet name: `branchdata`

## ptdf_matrix_nodal / ptdf_matrix (optional)

This optional dataset is used only when `network_model = 3` (nodal PTDF-based DCOPF).

If this file/sheet is provided, HOPE reads the PTDF matrix directly.
If not provided, HOPE computes nodal PTDF from branch endpoints/reactance and `reference_bus`.

Required format:

- One row per line, in the **same row order as the active branch table** (`branchdata` if provided in nodal mode, otherwise `linedata`).
- One column per bus, with column names exactly matching `busdata.Bus_id` (or inferred bus labels).
- Cell value = PTDF coefficient for that line and bus (reference bus convention).

Accepted names:

- CSV: `ptdf_matrix_nodal.csv` (preferred) or `ptdf_matrix.csv`
- XLSX sheet: `ptdf_matrix_nodal` (preferred) or `ptdf_matrix`

## storagedata

This is the input dataset for existing energy storage units (e.g., battery storage and pumped storage hydropower).

---

|**Column Name**|**Description**|
|:------------|:-----------|
|Zone|The zone that the generator is belonging to|
|Type|The technology type of the generator|
|Capacity (MWh)|Maximun energy capacity of the storage in MWh|
|Max Power (MW)|Maximum energy rate (power capacity) of the storage in MW|
|Charging efficiency|Ratio of how much energy is transferred from the charger to the storage unit|
|Discharging efficiency|Ratio of how much energy is transferred from the storage unit to the charger|
|Cost (\$/MWh)|Operating cost of the generator in \$/MWh|
|EF|The CO2 emission factor for the generator in tons/MWh|
|CC|The capacity credit for the generator (it is the fraction of the installed/nameplate capacity of a generator that can be relied upon at a given time)|
|Charging Rate|The maximum rates of charging, unitless|
|Discharging Rate|The maximum rates of discharging, unitless|

---

## solar_timeseries_regional

This is the input dataset for the annual hourly solar PV generation profile in each zone. Each zone has 8760 data points and the values are per unit.

Even if `gen_availability_timeseries` is provided, this zonal file is still used as the fallback profile for any solar generator that does not have its own `G#` column in the generator-level AF input.

---

|**Column Name** | **Description**|
| :------------ | :-----------|
|Month | Months of the year, ranging from 1 to 12|
|Day | Days of the month, ranging from 1 to 31|
|Period | Hours of the day, ranging from 1 to 24|
|Zone 1 | Solar power generation data in zone 1 on a specific period, day, and month|
|Zone 2 | Solar power generation data in zone 2 on a specific period, day, and month|
|... |...|

---

## wind_timeseries_regional

This is the input dataset for the annual hourly wind generation profile in each zone. Each zone has 8760 data points and the values are per unit.

Even if `gen_availability_timeseries` is provided, this zonal file is still used as the fallback profile for any wind generator that does not have its own `G#` column in the generator-level AF input.

---

|**Column Name** | **Description**|
| :------------ | :-----------|
|Month | Months of the year, ranging from 1 to 12|
|Day | Days of the month, ranging from 1 to 31|
|Period | Hours of the day, ranging from 1 to 24|
|Zone 1 | Wind power generation data in zone 1 on a specific period, day, and month|
|Zone 2 | Wind power generation data in zone 2 on a specific period, day, and month|
|... |...|

---

## load_timeseries_regional

This is the input dataset for the annual hourly load profile in each zone. Each zone has 8760 data points and the values are per unit.

In current HOPE PCM:

- `network_model = 0` or `1`: this file is used directly for load modeling
- `network_model = 2` or `3`: this file is still required as the chronology anchor for aligned time-series inputs, but native nodal load must come from `load_timeseries_nodal`
- `NI` in this file remains the system/zonal NI input and the fallback NI source for nodal PCM when `ni_timeseries_nodal` is not provided

---

|**Column Name** | **Description**|
| :------------ | :-----------|
|Month | Months of the year, ranging from 1 to 12|
|Day | Days of the month, ranging from 1 to 31|
|Period | Hours of the day, ranging from 1 to 24|
|Zone 1 | Load data in zone 1 on a specific period, day, and month|
|Zone 2 | Load data in zone 2 on a specific period, day, and month|
|... |...|
|NI | Net load import on a specific period, day, and month|

---

## load_timeseries_nodal (required for nodal PCM)

This dataset provides the annual hourly nodal load profile for nodal PCM. It is required when:

- `network_model = 2`
- `network_model = 3`

HOPE interprets each bus column as a unitless hourly multiplier and builds native bus load as:

- `Bus peak load * nodal hourly multiplier`

The bus peak-load basis comes from `busdata`, then HOPE rescales it within each zone so nodal peak loads sum to the zone peak load in `zonedata`.

Accepted names:

- CSV: `load_timeseries_nodal.csv`
- XLSX sheet: `load_timeseries_nodal`

Required time columns:

- `Time Period`
- `Hours`

Accepted legacy aliases:

- `Period` -> `Hours`
- `Hour` -> `Hours`

Optional time columns:

- `Month`
- `Day`

Required load columns:

- one column per bus
- column names must match `busdata.Bus_id` exactly

Example:

| Time Period | Hours | Month | Day | Bus 1 | Bus 2 | Bus 3 |
| :------------ | :----------- | :----------- | :----------- | :----------- | :----------- | :----------- |
| 1 | 1 | 7 | 1 | 0.82 | 0.79 | 0.91 |
| 1 | 2 | 7 | 1 | 0.80 | 0.77 | 0.88 |

Important behavior:

- HOPE no longer falls back to `zonal hourly load * static bus share` in nodal modes.
- If `load_timeseries_nodal` is missing in nodal PCM, HOPE will stop with an input error.

## ni_timeseries_nodal (optional for nodal PCM)

This optional dataset provides the annual hourly **bus-level NI injections** for nodal PCM. It is used only when:

- `network_model = 2`
- `network_model = 3`

Each bus column is interpreted directly in **MW**:

- positive value = net import injection into the modeled system at that bus
- negative value = net export withdrawal from the modeled system at that bus

Accepted names:

- CSV: `ni_timeseries_nodal.csv`
- XLSX sheet: `ni_timeseries_nodal`

Required time columns:

- `Time Period`
- `Hours`

Accepted legacy aliases:

- `Period` -> `Hours`
- `Hour` -> `Hours`

Optional time columns:

- `Month`
- `Day`

Required NI columns:

- one column per bus
- column names must match `busdata.Bus_id` exactly

Example:

| Time Period | Hours | Month | Day | Bus 118 | Bus 182 | Bus 249 |
| :------------ | :----------- | :----------- | :----------- | :----------- | :----------- | :----------- |
| 1 | 1 | 7 | 1 | 250 | 120 | -40 |
| 1 | 2 | 7 | 1 | 260 | 110 | -35 |

Behavior:

- If `ni_timeseries_nodal` is provided, HOPE uses it directly in nodal power balance instead of allocating `load_timeseries_regional.NI` by bus load share.
- HOPE still reads `load_timeseries_regional.NI`; when both inputs are present, HOPE compares the hourly row sums and uses the nodal NI input as authoritative for nodal PCM.
- When `ni_timeseries_nodal` is omitted, nodal PCM falls back to the legacy load-share allocation of system NI.
- In the ISO-NE 250-bus example, `ni_timeseries_nodal` is generated in preprocessing from official ISO-NE interface chronology, then scaled to the case-level NI magnitude and distributed with interface-centered nodal weights plus a small load-share balancing tail.

## ni_timeseries_nodal_target / ni_timeseries_nodal_cap (optional pair for flexible nodal PCM)

These two optional datasets activate **flexible nodal NI** in nodal PCM:

- `network_model = 2`
- `network_model = 3`

Accepted names:

- CSV: `ni_timeseries_nodal_target.csv`, `ni_timeseries_nodal_cap.csv`
- XLSX sheets: `ni_timeseries_nodal_target`, `ni_timeseries_nodal_cap`

Interpretation:

- `ni_timeseries_nodal_target` is the preferred hourly bus-level NI profile.
- `ni_timeseries_nodal_cap` is the hourly bus-level NI bound the solver may move toward when internal generation and network limits make the target infeasible or too expensive.

Both datasets use the same time-column rules and bus-column rules as `ni_timeseries_nodal`.

Required behavior:

- both files/sheets must be present together
- bus columns must match `busdata.Bus_id`
- `abs(target)` must not exceed `abs(cap)` at any bus-hour
- nonzero target/cap entries must have consistent signs at a bus-hour

Model behavior:

- when both target/cap inputs are present, HOPE ignores fixed `ni_timeseries_nodal` for nodal balance and instead optimizes actual nodal NI between the target and cap bounds
- deviation from the target is penalized in the objective using `PT_NI_DEV`
- outputs include:
  - `power_ni_nodal.csv`
  - `power_ni_zonal.csv`
  - `power_ni_deviation_nodal.csv`

The ISO-NE 250-bus example uses this workflow to treat official ISO-NE interchange as the lower NI target while preserving a higher synthetic NI cap needed to keep the case workable.

## rep_period_weights (required when `external_rep_day = 1`)

This optional-to-required dataset is used when users provide their own clustered representative periods for PCM.

Accepted names:

- CSV: `rep_period_weights.csv`
- XLSX sheet: `rep_period_weights`

Required columns:

- `Time Period`
- `Weight`

Behavior:

- If `external_rep_day = 1`, PCM requires this file/sheet.
- `Time Period` values must match the `Time Period` values used in `load_timeseries_regional` and the other aligned time-series inputs.
- `Weight` is the annual scaling/count for each representative period.

This matches the same external representative-period workflow used by GTEP.

## flexddata (required when `flexible_demand = 1`)

This dataset defines DR resources for PCM backlog load shifting (`dr_DF`, `dr_PB`, `b_DR` over resource set `R`).

---

|**Column Name** | **Description**|
| :------------ | :-----------|
|Zone | Zone name (must match `zonedata.Zone_id`)|
|Type | DR technology type label|
|Max Power (MW) | Maximum DR power in the zone|
|Cost (\$/MW) | DR operating cost coefficient|
|Shift_Efficiency *(optional)* | Payback efficiency factor in backlog update; default = 1.0|
|Max_Defer_Hours *(optional)* | Backlog cap multiplier in hours; default = 24.0|

---

## dr_timeseries_regional (required when `flexible_demand = 1`)

This is the annual hourly DR availability profile in each zone (per unit).

---

|**Column Name** | **Description**|
| :------------ | :-----------|
|Month | Months of the year, ranging from 1 to 12|
|Day | Days of the month, ranging from 1 to 31|
|Period | Hours of the day, ranging from 1 to 24|
|Zone 1 | DR availability in zone 1 on a specific period, day, and month|
|Zone 2 | DR availability in zone 2 on a specific period, day, and month|
|... |...|

---

## carbonpolicies

This is the input dataset for carbon policies.

---

|**Column Name** | **Description**|
| :------------ | :-----------|
|State | Name of the state|
|Time Period | Time periods for carbon allowance (can be yearly or quarterly, set by users)|
|Allowance (tons) | Carbon emission allowance for each state in tons|

---

## rpspolicies

This is the input dataset for renewable portfolio standard (RPS) policies. It defines renewable credits trading relationship between different states (i.e., the states must be neighboring states) and the renewable credit requirement for each state.

---

| **Column Name** | **Description** |
| :------------ | :----------- |
| From_state | State that trading the renewable credits from |
| To_state | State that trading the renewable credits to |
| RPS | RPS requirement (renewable generation percentage) for the state in "From_state" column, range from 0-1, unitless |

---

## single parameters

This is the input dataset for some parameters that can be directly defined based on users' need. If not changed, they remain with default values.

Implementation note: PCM reads these fields through an internal helper (`get_singlepar`) that returns the file value when present, otherwise a built-in default. This keeps backward compatibility when older cases do not include newly added single-parameter columns.

---

|**Column Name** | **Description**|
| :------------ | :-----------|
|VOLL | Value of lost load, default = 100000 |
|planning_reserve_margin | percentage of total capacity that is used for reserve, default = 0.02|
|BigM | For penalty purpose, unitless|
|PT_RPS | Penalty of the state not satisfying RPS requirement, default = 10000000000000|
|PT_emis | Penalty of the state not satisfying CO2 emission requirement, default = 10000000000000|
|PT_NI_DEV | Penalty for deviating from `ni_timeseries_nodal_target` when flexible nodal NI is active, default = 500|
|reg_up_requirement | Hourly REG-UP requirement as fraction of system load, default = 0|
|reg_dn_requirement | Hourly REG-DN requirement as fraction of system load, default = 0|
|spin_requirement | Hourly SPIN requirement as fraction of system load, default = 0.03|
|nspin_requirement | Hourly NSPIN requirement as fraction of system load, default = 0|
|delta_reg | REG reserve sustained-duration factor in energy constraints (hours), default = 1/12|
|delta_spin | SPIN reserve sustained-duration factor in energy constraints (hours), default = 1/6|
|delta_nspin | NSPIN reserve sustained-duration factor in energy constraints (hours), default = 1/2|
|theta_max | Bus angle bound in angle-based nodal DCOPF (numerical guard), default = 1000|
|delta_theta_max | Optional default line angle-difference limit (radians). If `<=0`, disabled. Can be overridden per line by `branchdata/linedata.delta_theta_max`|
|Inv_bugt_gen | Budget for newly installed generators, default = 10000000000000000|
|Inv_bugt_line | Budget for newly installed transmission lines, default = 10000000000000000|
|Inv_bugt_storage | Budget for newly installed storages, default = 10000000000000000|

---

Notes:

- `planning_reserve_margin` and `Inv_bugt_*` are currently not used by `create_PCM_model` (they are relevant to GTEP workflows).
