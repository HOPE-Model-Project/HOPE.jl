using CSV
using DataFrames
using YAML

const REPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const MODEL_CASES_ROOT = joinpath(REPO_ROOT, "ModelCases")
const GTEP_CASE_NAME = "MD_GTEP_restricted_linkage_case"
const PCM_CASE_NAME = "MD_PCM_restricted_linkage_case"
const GTEP_CASE = joinpath(MODEL_CASES_ROOT, GTEP_CASE_NAME)
const PCM_CASE = joinpath(MODEL_CASES_ROOT, PCM_CASE_NAME)
const GTEP_DATA = joinpath(GTEP_CASE, "Data")
const PCM_DATA = joinpath(PCM_CASE, "Data")

# These identifiers and coordinates are retained from the public Maryland OSM
# transmission case. The reduced ratings and study resources are intentional
# stress-test assumptions, not claims about the physical assets' real ratings.
const WEST_BUS = "OSM_S62344052_230"
const EAST_BUS = "OSM_S62344051_230"
const CORRIDOR_ID = "OSM_L17622043"

function write_text(path::AbstractString, value::AbstractString)
    mkpath(dirname(path))
    open(path, "w") do io
        write(io, value)
    end
    return path
end

function write_table(dir::AbstractString, name::AbstractString, table::DataFrame)
    mkpath(dir)
    CSV.write(joinpath(dir, name), table)
end

function time_base()
    DataFrame(
        "Time Period" => ones(Int, 24),
        "Month" => ones(Int, 24),
        "Day" => ones(Int, 24),
        "Hours" => collect(1:24),
    )
end

function add_series!(table::DataFrame, name::AbstractString, values)
    table[!, name] = collect(values)
    return table
end

function generator_table(; pcm::Bool)
    zones = pcm ? ["MD_WEST", "MD_EAST"] : [WEST_BUS, EAST_BUS]
    DataFrame(
        "GeneratorID" => ["MD_LINK_G1", "MD_LINK_G2"],
        "Asset_ID" => ["MD_LINK_EXISTING_GAS", "MD_LINK_RETIRE_COAL"],
        "PlantName" =>
            ["Maryland linkage west gas", "Maryland linkage east retirement unit"],
        "State" => ["MD", "MD"],
        "Zone" => zones,
        "Bus_id" => [WEST_BUS, EAST_BUS],
        "Planning_Zone" => ["MD_WEST", "MD_EAST"],
        "Type" => ["NGCC", "Coal"],
        "Pmax (MW)" => [140.0, 20.0],
        "Pmin (MW)" => [0.0, 20.0],
        "Cost (\$/MWh)" => [20.0, 200.0],
        "EF" => [0.45, 1.0],
        "CC" => [1.0, 1.0],
        "AF" => [1.0, 1.0],
        "FOR" => [0.0, 0.0],
        "RM_SPIN" => [0.50, 0.0],
        "RM_REG_UP" => [0.20, 0.0],
        "RM_REG_DN" => [0.20, 0.0],
        "RM_NSPIN" => [0.30, 0.0],
        "RU" => [0.50, 0.25],
        "RD" => [0.50, 0.25],
        "Flag_thermal" => [1, 1],
        "Flag_RET" => [0, 1],
        "Flag_VRE" => [0, 0],
        "Flag_mustrun" => [0, 0],
        "Flag_UC" => [1, 1],
        "Min_down_time" => [2, 2],
        "Min_up_time" => [2, 2],
        "Start_up_cost (\$/MW)" => [10.0, 20.0],
        "Flag_RPS" => [0, 0],
    )
end

function candidate_generator_table()
    DataFrame(
        "Candidate_ID" => ["MD_LINK_NEW_NGCC", "MD_LINK_NEW_SOLAR"],
        "Operational_Template_ID" => ["HOPE_NGCC_RESTRICTED", "HOPE_SOLAR_RESTRICTED"],
        "State" => ["MD", "MD"],
        "Zone" => [EAST_BUS, EAST_BUS],
        "Bus_id" => [EAST_BUS, EAST_BUS],
        "Planning_Zone" => ["MD_EAST", "MD_EAST"],
        "Type" => ["NGCC", "SolarPV"],
        "Pmax (MW)" => [60.0, 100.0],
        "Pmin (MW)" => [12.0, 0.0],
        "Cost (\$/MW/yr)" => [10_000.0, 8_000.0],
        "Cost (\$/MWh)" => [40.0, 0.0],
        "EF" => [0.35, 0.0],
        "CC" => [1.0, 0.60],
        "AF" => [1.0, 1.0],
        "FOR" => [0.0, 0.0],
        "RM_SPIN" => [0.50, 0.0],
        "RM_REG_UP" => [0.20, 0.0],
        "RM_REG_DN" => [0.20, 0.0],
        "RM_NSPIN" => [0.30, 0.0],
        "RU" => [0.50, 1.0],
        "RD" => [0.50, 1.0],
        "Flag_thermal" => [1, 0],
        "Flag_VRE" => [0, 1],
        "Flag_mustrun" => [0, 0],
        "Flag_UC" => [1, 0],
        "Min_down_time" => [2, 0],
        "Min_up_time" => [2, 0],
        "Start_up_cost (\$/MW)" => [15.0, 0.0],
        "Flag_RPS" => [0, 1],
    )
end

function empty_storage_table(; pcm::Bool)
    zone_type = String[]
    table = DataFrame(
        "StorageID" => String[],
        "Asset_ID" => String[],
        "State" => String[],
        "Zone" => zone_type,
        "Bus_id" => String[],
        "Type" => String[],
        "Capacity (MWh)" => Float64[],
        "Max Power (MW)" => Float64[],
        "Charging efficiency" => Float64[],
        "Discharging efficiency" => Float64[],
        "Cost (\$/MWh)" => Float64[],
        "EF" => Float64[],
        "CC" => Float64[],
        "Charging Rate" => Float64[],
        "Discharging Rate" => Float64[],
    )
    pcm || (table[!, "Planning_Zone"] = String[])
    return table
end

function candidate_storage_table()
    DataFrame(
        "Candidate_ID" => ["MD_LINK_NEW_BATTERY"],
        "Operational_Template_ID" => ["HOPE_BATTERY_RESTRICTED"],
        "State" => ["MD"],
        "Zone" => [EAST_BUS],
        "Bus_id" => [EAST_BUS],
        "Planning_Zone" => ["MD_EAST"],
        "Type" => ["Battery"],
        "Capacity (MWh)" => [120.0],
        "Max Power (MW)" => [30.0],
        "Charging efficiency" => [0.90],
        "Discharging efficiency" => [0.90],
        "Cost (\$/MW/yr)" => [5_000.0],
        "Cost (\$/MWh)" => [0.10],
        "EF" => [0.0],
        "CC" => [1.0],
        "Charging Rate" => [1.0],
        "Discharging Rate" => [1.0],
    )
end

function write_common_policy_data(dir::AbstractString)
    write_table(
        dir,
        "carbonpolicies.csv",
        DataFrame("State" => ["MD"], "Time Period" => [1], "Allowance (tons)" => [1.0e9]),
    )
    write_table(
        dir,
        "rpspolicies.csv",
        DataFrame("From_state" => ["MD"], "To_state" => ["MD"], "RPS" => [0.20]),
    )
    write_table(
        dir,
        "single_parameter.csv",
        DataFrame(
            "VOLL" => [100_000.0],
            "planning_reserve_margin" => [0.15],
            "BigM" => [1.0e8],
            "PT_RPS" => [1.0e7],
            "PT_emis" => [1.0e7],
            "Inv_bugt_gen" => [1.0e12],
            "Inv_bugt_line" => [1.0e12],
            "Inv_bugt_storage" => [1.0e12],
            "alpha_storage_anchor" => [0.50],
            "reg_up_requirement" => [0.01],
            "reg_dn_requirement" => [0.01],
            "spin_requirement" => [0.03],
            "nspin_requirement" => [0.01],
            "delta_spin" => [1 / 6],
        ),
    )
end

function write_gtep_data()
    mkpath(GTEP_DATA)
    write_table(
        GTEP_DATA,
        "zonedata.csv",
        DataFrame(
            "Zone_id" => [WEST_BUS, EAST_BUS],
            "Demand (MW)" => [20.0, 130.0],
            "Area" => ["PEPCO", "PEPCO"],
            "Flag_MD" => [1, 1],
            "State" => ["MD", "MD"],
            "Planning_Zone" => ["MD_WEST", "MD_EAST"],
            "Zonal PRM" => [0.15, 0.15],
        ),
    )
    write_table(GTEP_DATA, "gendata.csv", generator_table(pcm = false))
    write_table(GTEP_DATA, "gendata_candidate.csv", candidate_generator_table())
    write_table(GTEP_DATA, "storagedata.csv", empty_storage_table(pcm = false))
    write_table(GTEP_DATA, "storagedata_candidate.csv", candidate_storage_table())
    write_table(
        GTEP_DATA,
        "linedata.csv",
        DataFrame(
            "From_zone" => [WEST_BUS],
            "To_zone" => [EAST_BUS],
            "X" => [0.05],
            "Forward Capacity (MW)" => [10.0],
            "Reverse Capacity (MW)" => [10.0],
            "Loss (%)" => [0.02],
            "Corridor_ID" => [CORRIDOR_ID],
        ),
    )
    write_table(
        GTEP_DATA,
        "linedata_candidate.csv",
        DataFrame(
            "From_zone" => [WEST_BUS],
            "To_zone" => [EAST_BUS],
            "PCM_from_bus" => [WEST_BUS],
            "PCM_to_bus" => [EAST_BUS],
            "X" => [0.05],
            "Forward Capacity (MW)" => [30.0],
            "Reverse Capacity (MW)" => [30.0],
            "Cost (M\$)" => [0.001],
            "Loss (%)" => [0.02],
            "Corridor_ID" => [CORRIDOR_ID],
        ),
    )

    east_load_mw = [
        h <= 7 ? 40.0 :
        h <= 16 ? 50.0 : h == 17 ? 80.0 : h <= 19 ? 130.0 : h <= 22 ? 80.0 : 50.0 for
        h = 1:24
    ]
    solar = [8 <= h <= 16 ? 1.0 : 0.0 for h = 1:24]
    load = time_base()
    add_series!(load, WEST_BUS, ones(24))
    add_series!(load, EAST_BUS, east_load_mw ./ 130.0)
    add_series!(load, "NI", zeros(24))
    write_table(GTEP_DATA, "load_timeseries_regional.csv", load)

    af = time_base()
    add_series!(af, "G1", ones(24))
    add_series!(af, "G2", ones(24))
    add_series!(af, "G3", ones(24))
    add_series!(af, "G4", solar)
    write_table(GTEP_DATA, "gen_availability_timeseries.csv", af)
    write_table(
        GTEP_DATA,
        "rep_period_weights.csv",
        DataFrame("Time Period" => [1], "Weight" => [365.0]),
    )

    dr = time_base()
    add_series!(dr, WEST_BUS, zeros(24))
    add_series!(dr, EAST_BUS, [17 <= h <= 22 ? 1.0 : 0.0 for h = 1:24])
    write_table(GTEP_DATA, "dr_timeseries_regional.csv", dr)
    write_table(
        GTEP_DATA,
        "flexddata.csv",
        DataFrame(
            "Zone" => [EAST_BUS],
            "Type" => ["LoadShifting"],
            "Max Power (MW)" => [12.0],
            "Cost (\$/MW)" => [1.0],
            "CC" => [0.0],
            "Shift_Efficiency" => [1.0],
            "Max_Defer_Hours" => [4.0],
        ),
    )
    write_common_policy_data(GTEP_DATA)
end

function write_pcm_data()
    mkpath(PCM_DATA)
    write_table(
        PCM_DATA,
        "zonedata.csv",
        DataFrame(
            "Zone_id" => ["MD_WEST", "MD_EAST"],
            "Demand (MW)" => [20.0, 130.0],
            "Area" => ["PEPCO", "PEPCO"],
            "State" => ["MD", "MD"],
        ),
    )
    write_table(
        PCM_DATA,
        "busdata.csv",
        DataFrame(
            "Bus_id" => [WEST_BUS, EAST_BUS],
            "Zone_id" => ["MD_WEST", "MD_EAST"],
            "State" => ["MD", "MD"],
            "Latitude" => [38.91233, 38.91309],
            "Longitude" => [-77.02750, -77.01971],
            "Demand (MW)" => [20.0, 130.0],
            "Load_share" => [1.0, 1.0],
        ),
    )
    write_table(PCM_DATA, "gendata.csv", generator_table(pcm = true))
    write_table(PCM_DATA, "storagedata.csv", empty_storage_table(pcm = true))
    write_table(
        PCM_DATA,
        "linedata.csv",
        DataFrame(
            "From_zone" => ["MD_WEST"],
            "To_zone" => ["MD_EAST"],
            "X" => [0.05],
            "Forward Capacity (MW)" => [10.0],
            "Reverse Capacity (MW)" => [10.0],
            "Loss (%)" => [0.02],
            "Corridor_ID" => [CORRIDOR_ID],
        ),
    )
    write_table(
        PCM_DATA,
        "branchdata.csv",
        DataFrame(
            "From_zone" => ["MD_WEST"],
            "To_zone" => ["MD_EAST"],
            "from_bus" => [WEST_BUS],
            "to_bus" => [EAST_BUS],
            "X" => [0.05],
            "Forward Capacity (MW)" => [10.0],
            "Reverse Capacity (MW)" => [10.0],
            "Loss (%)" => [0.02],
            "Corridor_ID" => [CORRIDOR_ID],
        ),
    )

    east_load_mw = [
        h <= 7 ? 40.0 :
        h <= 16 ? 50.0 : h == 17 ? 80.0 : h <= 19 ? 130.0 : h <= 22 ? 80.0 : 50.0 for
        h = 1:24
    ]
    solar = [8 <= h <= 16 ? 1.0 : 0.0 for h = 1:24]
    regional_load = time_base()
    add_series!(regional_load, "MD_WEST", ones(24))
    add_series!(regional_load, "MD_EAST", east_load_mw ./ 130.0)
    add_series!(regional_load, "NI", zeros(24))
    write_table(PCM_DATA, "load_timeseries_regional.csv", regional_load)

    nodal_load = time_base()
    add_series!(nodal_load, WEST_BUS, ones(24))
    add_series!(nodal_load, EAST_BUS, east_load_mw ./ 130.0)
    write_table(PCM_DATA, "load_timeseries_nodal.csv", nodal_load)

    wind = time_base()
    add_series!(wind, "MD_WEST", zeros(24))
    add_series!(wind, "MD_EAST", zeros(24))
    write_table(PCM_DATA, "wind_timeseries_regional.csv", wind)

    solar_table = time_base()
    add_series!(solar_table, "MD_WEST", zeros(24))
    add_series!(solar_table, "MD_EAST", solar)
    write_table(PCM_DATA, "solar_timeseries_regional.csv", solar_table)

    af = time_base()
    add_series!(af, "G1", ones(24))
    add_series!(af, "G2", ones(24))
    write_table(PCM_DATA, "gen_availability_timeseries.csv", af)

    dr = time_base()
    add_series!(dr, "MD_WEST", zeros(24))
    add_series!(dr, "MD_EAST", [17 <= h <= 22 ? 1.0 : 0.0 for h = 1:24])
    write_table(PCM_DATA, "dr_timeseries_regional.csv", dr)
    write_table(
        PCM_DATA,
        "flexddata.csv",
        DataFrame(
            "Zone" => ["MD_EAST"],
            "Type" => ["LoadShifting"],
            "Max Power (MW)" => [12.0],
            "Cost (\$/MW)" => [1.0],
            "CC" => [0.0],
            "Shift_Efficiency" => [1.0],
            "Max_Defer_Hours" => [4.0],
        ),
    )
    write_common_policy_data(PCM_DATA)
end

const GTEP_SETTINGS = """DataCase: Data/
model_mode: GTEP
resource_aggregation: 0
representative_day!: 0
endogenous_rep_day: 0
external_rep_day: 1
flexible_demand: 1
inv_dcs_bin: 1
carbon_policy: 0
clean_energy_policy: 1
planning_reserve_mode: 2
operation_reserve_mode: 1
transmission_expansion: 1
transmission_loss: 1
storage_ld_duration_hours: 12
write_shadow_prices: 1
summary_table: 1
save_postprocess_snapshot: 0
solver: highs
debug: 0
holistic_spatial_basis: bus
time_periods:
  1: (1, 1, 1, 1)
"""

const PCM_SETTINGS = """DataCase: Data/
model_mode: PCM
resource_aggregation: 0
representative_day!: 0
endogenous_rep_day: 0
external_rep_day: 0
flexible_demand: 1
inv_dcs_bin: 0
carbon_policy: 0
clean_energy_policy: 1
planning_reserve_mode: 0
operation_reserve_mode: 2
network_model: 2
transmission_loss: 1
reference_bus: $(WEST_BUS)
unit_commitment: 1
write_shadow_prices: 1
summary_table: 1
solver: highs
debug: 0
holistic_spatial_basis: bus
time_periods:
  1: (1, 1, 1, 1)
"""

const HIGHS_SETTINGS = """Feasib_Tol: 1.0e-7
Optimal_Tol: 1.0e-7
TimeLimit: 300.0
Pre_Solve: choose
Method: choose
run_crossover: true
"""

const GUROBI_SETTINGS = """Feasib_Tol: 1.0e-7
Optimal_Tol: 1.0e-7
TimeLimit: 300.0
MIPGap: 1.0e-6
Method: -1
OutputFlag: 1
"""

const EXPECTATIONS = """schema_version: 1
require_all: true
required_settings:
  gtep:
    inv_dcs_bin: 1
    flexible_demand: 1
    clean_energy_policy: 1
    planning_reserve_mode: 2
    operation_reserve_mode: 1
    transmission_loss: 1
  pcm:
    unit_commitment: 1
    flexible_demand: 1
    clean_energy_policy: 1
    operation_reserve_mode: 2
    network_model: 2
    transmission_loss: 1
thresholds:
  retired_generation_mw:
    minimum: 19.99
  new_generation_mw:
    minimum: 159.99
  new_storage_power_mw:
    minimum: 29.99
  new_storage_energy_mwh:
    minimum: 119.99
  line_forward_added_mw:
    minimum: 29.99
  pcm_new_generation_dispatch_mwh:
    minimum: 1.0
  pcm_new_storage_discharge_mwh:
    minimum: 1.0
  pcm_upgraded_line_max_abs_flow_mw:
    minimum: 10.01
  pcm_dr_deferred_mwh:
    minimum: 0.01
  pcm_operating_reserve_mwh:
    minimum: 0.01
  pcm_transmission_loss_mwh:
    minimum: 0.01
  pcm_load_shedding_mwh:
    maximum: 0.000001
  pcm_rps_slack_mwh:
    maximum: 0.000001
"""

function write_settings()
    for case in (GTEP_CASE, PCM_CASE)
        mkpath(joinpath(case, "Settings"))
    end
    write_text(joinpath(GTEP_CASE, "Settings", "HOPE_model_settings.yml"), GTEP_SETTINGS)
    write_text(joinpath(PCM_CASE, "Settings", "HOPE_model_settings.yml"), PCM_SETTINGS)
    for case in (GTEP_CASE, PCM_CASE)
        write_text(joinpath(case, "Settings", "highs_settings.yml"), HIGHS_SETTINGS)
        write_text(joinpath(case, "Settings", "gurobi_settings.yml"), GUROBI_SETTINGS)
    end
    write_text(joinpath(PCM_CASE, "Settings", "HOPE_holistic_acceptance.yml"), EXPECTATIONS)
end

function write_case_metadata()
    gtep_readme = """# Maryland restricted GTEP-to-PCM linkage benchmark

This compact 24-hour GTEP case is paired with `../$(PCM_CASE_NAME)`. It uses two
real Maryland OSM transmission identifiers but deliberately reduced study
ratings and synthetic operating assumptions to make linkage behavior observable.

The case is an integration/acceptance benchmark, not a forecast of the Maryland
system. It is designed to produce nonzero retirement, generation, storage, and
transmission decisions while exercising binary investment, zonal planning
reserve, spinning reserve, RPS, demand response, and transmission losses.

Carbon-policy alternatives, resource aggregation, endogenous representative-day
selection, and interregional net interchange are intentionally left to focused
tests. The GTEP case does use an external representative-period weight so the
24-hour operations are annualized.

Run the complete pair with:

```julia
include("run_holistic_pair.jl")
```

The paired PCM output writes `holistic_coverage.yml` and
`holistic_coverage.csv`; the run fails if a required acceptance check fails.
"""
    pcm_readme = """# Maryland restricted PCM linkage benchmark

This compact 24-hour nodal PCM case is paired with
`../$(GTEP_CASE_NAME)`. The source inputs are immutable: GTEP decisions are
realized in memory and persisted under `output_holistic/realized_inputs/`.

The case exercises nodal angle-based DCOPF, binary unit commitment,
REG-UP/REG-DOWN/SPIN/NSPIN, demand response, RPS, storage operation, and
piecewise-linear transmission losses. See
`Settings/HOPE_holistic_acceptance.yml` for the machine-readable acceptance
contract.

Carbon-policy alternatives, resource aggregation, representative-day selection,
and interregional net interchange are intentionally outside this compact pair.

This is a deliberately stressed software benchmark, not a calibrated Maryland
production-cost study.
"""
    write_text(joinpath(GTEP_CASE, "README.md"), gtep_readme)
    write_text(joinpath(PCM_CASE, "README.md"), pcm_readme)
    write_text(
        joinpath(GTEP_CASE, ".gitignore"),
        "output/\noutput_holistic/\noutput_backup*/\n",
    )
    write_text(
        joinpath(PCM_CASE, ".gitignore"),
        "output/\noutput_holistic/\noutput_backup*/\n",
    )

    manifest_common = Dict(
        "schema_version" => 1,
        "benchmark_class" => "restricted_linkage_acceptance",
        "geographic_basis" => "Maryland OSM identifiers",
        "data_character" => "reduced synthetic stress assumptions on public physical identifiers",
        "hours" => 24,
        "license_note" => "See repository and source Maryland public-case licensing/provenance notes.",
    )
    YAML.write_file(
        joinpath(GTEP_CASE, "manifest.yml"),
        merge(
            copy(manifest_common),
            Dict("model_mode" => "GTEP", "paired_case" => PCM_CASE_NAME),
        ),
    )
    YAML.write_file(
        joinpath(PCM_CASE, "manifest.yml"),
        merge(
            copy(manifest_common),
            Dict("model_mode" => "PCM", "paired_case" => GTEP_CASE_NAME),
        ),
    )

    runner = """using HOPE

const GTEP_CASE = @__DIR__
const PCM_CASE = normpath(joinpath(@__DIR__, "..", "$(PCM_CASE_NAME)"))

result = HOPE.run_hope_holistic(GTEP_CASE, PCM_CASE)
report = HOPE.write_holistic_coverage_report(
    result,
    joinpath(PCM_CASE, "Settings", "HOPE_holistic_acceptance.yml");
    require_all = true,
)
println("Holistic coverage passed: ", report["all_passed"])
"""
    write_text(joinpath(GTEP_CASE, "run_holistic_pair.jl"), runner)
    write_text(joinpath(GTEP_CASE, "run_case.jl"), "using HOPE\nHOPE.run_hope(@__DIR__)\n")
    write_text(joinpath(PCM_CASE, "run_case.jl"), "using HOPE\nHOPE.run_hope(@__DIR__)\n")
end

function main()
    write_gtep_data()
    write_pcm_data()
    write_settings()
    write_case_metadata()
    println("Built $GTEP_CASE")
    println("Built $PCM_CASE")
end

main()
