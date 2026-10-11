using CSV
using DataFrames
using Dates
using HOPE
using Test

function minimal_dart_workflow_config()
    return Dict{String,Any}(
        "DataCase" => "data/",
        "model_mode" => "DART",
        "resource_aggregation" => 0,
        "representative_day!" => 0,
        "flexible_demand" => 0,
        "clean_energy_policy" => 0,
        "carbon_policy" => 0,
        "planning_reserve_mode" => 0,
        "inv_dcs_bin" => 0,
        "operation_reserve_mode" => 2,
        "network_model" => 3,
        "transmission_loss" => 0,
        "reference_bus" => 1,
        "unit_commitment" => 1,
        "solver" => "highs",
        "debug" => 0,
        "dart_settings" => Dict{String,Any}(
            "time" => Dict{String,Any}(
                "binding_hours" => 1,
                "day_ahead_lookahead_hours" => 24,
                "real_time_intervals_per_hour" => 12,
                "real_time_lookahead_intervals" => 12,
            ),
            "availability_mode" => "physical_outages",
        ),
    )
end

@testset "DART workflow setting compatibility" begin
    config = minimal_dart_workflow_config()
    @test HOPE.validate_model_mode("DART")
    @test isempty(validate_dart_settings(config; emit_warnings = false))

    aggregated = deepcopy(config)
    aggregated["resource_aggregation"] = 1
    @test_throws ArgumentError validate_dart_settings(aggregated; emit_warnings = false)
    @test_logs (:warn, r"resource_aggregation=1 is unavailable") begin
        @test_throws ArgumentError validate_dart_settings(aggregated)
    end

    representative = deepcopy(config)
    representative["representative_day!"] = 1
    @test_throws ArgumentError validate_dart_settings(representative; emit_warnings = false)

    policy = deepcopy(config)
    policy["carbon_policy"] = 1
    @test_throws ArgumentError validate_dart_settings(policy; emit_warnings = false)

    angle_network = deepcopy(config)
    angle_network["network_model"] = 2
    @test_throws ArgumentError validate_dart_settings(angle_network; emit_warnings = false)

    convex_uc = deepcopy(config)
    convex_uc["unit_commitment"] = 2
    @test_throws ArgumentError validate_dart_settings(convex_uc; emit_warnings = false)

    representative_metadata = deepcopy(config)
    representative_metadata["time_periods"] = Dict(1 => (3, 20, 6, 20))
    @test length(
        validate_dart_settings(representative_metadata; emit_warnings = false),
    ) == 1
end

@testset "RTS24 standard DART case validation" begin
    case_path = normpath(joinpath(@__DIR__, "..", "ModelCases", "RTS24_DART_case"))
    if isdir(case_path)
        validation = validate_hope(case_path)
        inventory = validation["inventory"]
        coverage = validation["constraint_coverage"]
        @test inventory.count[inventory.item.=="buses"] == [24]
        @test inventory.count[inventory.item.=="branches"] == [38]
        @test inventory.count[inventory.item.=="generators"] == [33]
        @test inventory.count[inventory.item.=="storage"] == [5]
        @test nrow(coverage) == 19
        @test all(coverage.enabled)

        input = validation["input"]
        forecasts = input["forecasts"]
        @test length(forecasts.real_time_timestamps) == 288
        @test Dates.minute.(forecasts.real_time_timestamps[1:12]) == collect(0:5:55)
        @test maximum(abs.(forecasts.real_time.load_mw[:, 1] .-
                           forecasts.real_time.load_mw[:, 2])) > 0
        quick_start = filter(g -> g.quick_start_eligible, input["system"].generators)
        @test length(quick_start) == 6
        @test all(g.commitment_required for g in quick_start)
        @test all(g.reserve_capability_mw[:nspin] == 50.0 for g in quick_start)
        @test !isfile(joinpath(
            case_path,
            "Data_RTS24_DART",
            "dart_generator_parameters.csv",
        ))
        @test !isfile(joinpath(
            case_path,
            "Data_RTS24_DART",
            "dart_storage_parameters.csv",
        ))
    else
        @test_skip "RTS24_DART_case is unavailable in this checkout"
    end
end



@testset "DART real-time Minute guidance" begin
    @test_logs (:warn, r"were not provided") begin
        @test HOPE._dart_realtime_tables(Dict{String,Any}(), pwd()) === nothing
    end

    mktempdir() do directory
        settings = Dict{String,Any}(
            "files" => Dict{String,Any}(
                "real_time_load" => "load.csv",
                "real_time_wind" => "wind.csv",
                "real_time_solar" => "solar.csv",
            ),
        )
        table = DataFrame(Month = [1], Day = [1], Hours = [1], B1 = [1.0])
        for file in ("load.csv", "wind.csv", "solar.csv")
            CSV.write(joinpath(directory, file), table)
        end
        @test_logs (:warn, r"has no Minute column") begin
            @test_throws ArgumentError HOPE._dart_realtime_tables(settings, directory)
        end
    end
end



@testset "DART debug routing" begin
    mktempdir() do case_path
        settings_path = joinpath(case_path, "Settings")
        mkpath(settings_path)
        write(
            joinpath(settings_path, "HOPE_model_settings.yml"),
            "model_mode: DART\n",
        )
        @test_throws ArgumentError HOPE.run_debug(case_path)
    end
end
