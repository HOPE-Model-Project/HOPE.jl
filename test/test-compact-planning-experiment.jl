using HOPE
using Test
using CSV
using DataFrames
using YAML

function _compact_parent(path::AbstractString)
    data = joinpath(path, "Data")
    settings = joinpath(path, "Settings")
    output = joinpath(path, "output")
    mkpath(data)
    mkpath(settings)
    mkpath(output)
    YAML.write_file(
        joinpath(settings, "HOPE_model_settings.yml"),
        Dict(
            "DataCase" => "Data/",
            "model_mode" => "GTEP",
            "planning_reserve_mode" => 1,
            "clean_energy_policy" => 2,
            "solver" => "highs",
        ),
    )
    CSV.write(joinpath(data, "zonedata.csv"), DataFrame(Zone_id = ["MD", "EXT"]))
    generation = DataFrame(
        GeneratorID = ["BASE_NGCC"],
        Asset_ID = ["BASE_NGCC"],
        Zone = ["MD"],
        Planning_Zone = ["MD"],
        Type = ["NGCC"],
        ScenarioStatus = ["existing"],
        Bus_id = ["MD_BUS"],
        Flag_RPS = [0],
    )
    generation[!, "Pmax (MW)"] = [100.0]
    generation[!, "Pmin (MW)"] = [0.0]
    generation[!, "AF"] = [1.0]
    CSV.write(joinpath(data, "gendata.csv"), generation)
    candidates = DataFrame(
        Type = ["SolarPV", "WindOn", "NGCC"],
        Zone = ["MD", "MD", "MD"],
        AF = [1.0, 1.0, 0.9],
        Candidate_ID = ["SOLAR_C", "WIND_C", "NGCC_C"],
    )
    CSV.write(joinpath(data, "gendata_candidate.csv"), candidates)
    time = DataFrame(
        "Time Period" => [1, 1],
        "Month" => [7, 7],
        "Day" => [15, 15],
        "Hours" => [1, 2],
    )
    availability = copy(time)
    availability[!, "G1"] = [1.0, 1.0]
    availability[!, "G2"] = [0.01, 0.02]
    availability[!, "G3"] = [0.03, 0.04]
    availability[!, "G4"] = [0.9, 0.9]
    CSV.write(joinpath(data, "gen_availability_timeseries.csv"), availability)
    solar = copy(time)
    solar[!, "MD"] = [0.1, 0.2]
    CSV.write(joinpath(data, "solar_timeseries_regional.csv"), solar)
    wind = copy(time)
    wind[!, "MD"] = [0.3, 0.4]
    CSV.write(joinpath(data, "wind_timeseries_regional.csv"), wind)
    write(joinpath(output, "stale.txt"), "must not be copied")
end

function _unitization_policy()
    return Dict(
        "artifact_type" => "HOPE.capacity_plan_unitization_policy",
        "schema_version" => 1,
        "resources" => Dict(
            "SolarPV" => Dict(
                "target_mw" => 400.0,
                "minimum_mw" => 250.0,
                "maximum_mw" => 500.0,
            ),
            "WindOn" => Dict(
                "target_mw" => 300.0,
                "minimum_mw" => 200.0,
                "maximum_mw" => 400.0,
            ),
            "Battery" => Dict(
                "target_mw" => 200.0,
                "minimum_mw" => 100.0,
                "maximum_mw" => 250.0,
            ),
        ),
    )
end

function _unitized_topology_catalog(plan::AbstractDataFrame)
    rows = DataFrame(
        Candidate_Site_ID = String[],
        Site_ID = String[],
        Bus_id = String[],
        Resource_Kind = String[],
        Zone = String[],
        Type = String[],
        Candidate_Max_MW = Float64[],
        Candidate_Max_MWh = Union{Missing,Float64}[],
        Existing_Site = Bool[],
        Site_Cost = Float64[],
        Network_Stress_Score = Float64[],
        Resource_Quality_Score = Float64[],
        Evidence_Confidence = Float64[],
        Eligible = Bool[],
        Network_Screen_Passed = Bool[],
        Exclusion_Reason = String[],
        Evidence_Source = String[],
    )
    for (kind, zone, resource_type, max_mw, max_mwh) in (
        ("generation", "PEPCO", "WindOn", 4000.0, missing),
        ("storage", "DPL_MD", "Battery", 2000.0, 8000.0),
    )
        for index = 1:12
            bus = string(zone, "_BUS_", lpad(index, 2, '0'))
            push!(
                rows,
                (
                    string(resource_type, "_", index),
                    bus,
                    bus,
                    kind,
                    zone,
                    resource_type,
                    max_mw,
                    max_mwh,
                    true,
                    index / 12,
                    (13 - index) / 12,
                    0.5,
                    0.9,
                    true,
                    true,
                    "",
                    "test topology",
                ),
            )
        end
    end
    return rows
end

@testset "Compact planning experiment" begin
    mktempdir() do directory
        parent = joinpath(directory, "parent")
        child = joinpath(directory, "child")
        _compact_parent(parent)
        contributions = DataFrame(
            Proxy_ID = ["IMPORT_A", "IMPORT_B"],
            Bus_id = ["EXT_A", "EXT_B"],
            Capacity_MW = [60.0, 40.0],
        )
        result = HOPE.materialize_compact_rps_gtep_case(parent, child, contributions)
        @test isfile(result["paths"]["contract"])
        @test !isdir(joinpath(child, "output"))
        parent_generation = CSV.read(joinpath(parent, "Data", "gendata.csv"), DataFrame)
        child_generation = CSV.read(joinpath(child, "Data", "gendata.csv"), DataFrame)
        @test nrow(parent_generation) == 1
        @test nrow(child_generation) == 3
        proxies = child_generation[
            child_generation.ScenarioStatus.=="synthetic_firm_import_proxy",
            :,
        ]
        @test sum(proxies[!, "Pmax (MW)"]) == 100.0
        @test all(proxies.Flag_RPS .== 0)
        availability =
            CSV.read(joinpath(child, "Data", "gen_availability_timeseries.csv"), DataFrame)
        @test availability.G2 == [1.0, 1.0]
        @test availability.G3 == [1.0, 1.0]
        @test availability.G4 == [0.1, 0.2]
        @test availability.G5 == [0.3, 0.4]
        @test availability.G6 == [0.9, 0.9]
        contract = YAML.load_file(result["paths"]["contract"])
        @test !contract["candidate_availability_contract"]["static_fallback_allowed_for_vre"]
        @test contract["candidate_availability_contract"]["candidate_profile_sources"]["SOLAR_C"] ==
              "solar_timeseries_regional.csv:MD"

        continuous_plan = DataFrame(
            Plan_Item_ID = ["WIND_PARENT", "BATTERY_PARENT"],
            Resource_Kind = ["generation", "storage"],
            Zone = ["PEPCO", "DPL_MD"],
            Type = ["WindOn", "Battery"],
            Build_MW = [1806.0, 534.0],
            Build_MWh = [0.0, 2136.0],
        )
        unitized = HOPE.unitize_capacity_plan(continuous_plan, _unitization_policy())
        projects = unitized["capacity_plan"]
        @test nrow(projects) == 9
        @test count(==("WindOn"), projects.Type) == 6
        @test count(==("Battery"), projects.Type) == 3
        @test sum(projects.Build_MW) ≈ 2340.0
        @test sum(projects.Build_MWh) ≈ 2136.0
        @test all(projects.Build_MW[projects.Type.=="WindOn"] .≈ 301.0)
        @test all(projects.Build_MW[projects.Type.=="Battery"] .≈ 178.0)

        topology = _unitized_topology_catalog(projects)
        branches =
            DataFrame(from_bus = topology.Bus_id, to_bus = fill("HUB", nrow(topology)))
        branches[!, "Forward Capacity (MW)"] = fill(1000.0, nrow(topology))
        branches[!, "Reverse Capacity (MW)"] = fill(1000.0, nrow(topology))
        catalog = HOPE.build_unitized_project_catalog(projects, topology, branches)
        @test nrow(catalog) == 24
        @test count(==("denied"), catalog.Permit_Status) == 2
        @test count(!, catalog.Environmental_Eligible) == 2
        @test count(==("suspended"), catalog.Queue_Status) == 2
        @test count(catalog.Community_Review_Required) == 6

        pcm_input = Dict("Gendata" => parent_generation)
        gtep_input = Dict("Gendata" => child_generation)
        updated = HOPE.add_compact_planning_proxies_to_pcm(pcm_input, gtep_input)
        @test nrow(updated["Gendata"]) == 3
        @test Set(string.(updated["Gendata"].Asset_ID)) ==
              Set(["BASE_NGCC", "IMPORT_A", "IMPORT_B"])
    end
end
