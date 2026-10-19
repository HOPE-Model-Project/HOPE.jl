using JuMP
using DataFrames
using Dates

function pcm_state_test_fixture()
    data = DARTSystemData(
        generators = [
            DARTGenerator(
                name = "A1",
                bus = "B1",
                pmax_mw = 100.0,
                pmin_mw = 10.0,
                commitment_required = true,
            ),
            DARTGenerator(
                name = "A2",
                bus = "B1",
                pmax_mw = 50.0,
                commitment_required = false,
            ),
        ],
        network = DARTNetwork(bus_names = ["B1"]),
        storage = [
            DARTStorage(
                name = "S1",
                bus = "B1",
                energy_capacity_mwh = 40.0,
                charge_capacity_mw = 10.0,
                discharge_capacity_mw = 10.0,
            ),
        ],
    )
    input = Dict(
        "Gendata" => DataFrame(
            :Asset_ID => ["A1", "A2"],
            :Flag_UC => [1, 0],
            :Flag_thermal => [1, 1],
            Symbol("Pmax (MW)") => [100.0, 50.0],
            Symbol("Pmin (MW)") => [10.0, 0.0],
        ),
        "Storagedata" => DataFrame(:Asset_ID => ["S1"]),
    )
    config =
        Dict("model_mode" => "PCM", "unit_commitment" => 1, "resource_aggregation" => 0)
    model = Model(HOPE.HiGHS.Optimizer)
    set_silent(model)
    @variable(model, p[1:2, 1:3] >= 0)
    @variable(model, o[1:1, 1:3], Bin)
    @variable(model, soc[1:1, 1:3] >= 0)
    generation = [0.0 30.0 40.0; 4.0 6.0 5.0]
    commitment = [0.0 1.0 1.0]
    storage = [20.0 17.0 15.0]
    @constraint(model, [g = 1:2, h = 1:3], p[g, h] == generation[g, h])
    @constraint(model, [g = 1:1, h = 1:3], o[g, h] == commitment[g, h])
    @constraint(model, [s = 1:1, h = 1:3], soc[s, h] == storage[s, h])
    @objective(model, Min, 0)
    optimize!(model)
    return config, input, model, data
end

@testset "PCM operational-state adapter" begin
    config, input, model, data = pcm_state_test_fixture()
    state = build_pcm_operational_state(config, input, model, data; boundary_hour = 3)
    @test state.commitment == [1, 1]
    @test state.generation_mw == [40.0, 5.0]
    @test state.on_duration_hours[1] == 2.0
    @test isinf(state.on_duration_hours[2])
    @test state.off_duration_hours == [0.0, 0.0]
    @test state.storage_soc_mwh == [15.0]
    @test all(state.generator_in_service)

    trace = HOPE.capture_pcm_operational_trace(config, input, model)
    traced_state =
        build_pcm_operational_state(config, input, trace, data; boundary_hour = 3)
    @test traced_state.generation_mw == state.generation_mw
    @test traced_state.commitment == state.commitment

    legacy_input = deepcopy(input)
    rename!(legacy_input["Gendata"], :Asset_ID => :GeneratorID)
    rename!(legacy_input["Storagedata"], :Asset_ID => :StorageID)
    @test isnothing(HOPE.maybe_capture_pcm_operational_trace(config, legacy_input, model))

    mktempdir() do root
        artifact = write_pcm_operational_state_artifact(
            joinpath(root, "pcm_state"),
            config,
            input,
            model,
            data;
            boundary_hour = 3,
            boundary_time = DateTime(2035, 8, 2, 3),
            timezone = "America/New_York",
            scenario_id = "pcm-to-dart-test",
            parent_artifact_hashes = Dict("pcm_run" => "run-hash"),
        )
        @test artifact.source_model == "PCM"
        @test artifact.state.generation_mw == [40.0, 5.0]
        @test artifact.parent_artifact_hashes["pcm_run"] == "run-hash"
        @test occursin("left-censored", artifact.assumptions["duration_semantics"])
    end

    mktempdir() do root
        unsolved = Model(HOPE.HiGHS.Optimizer)
        result = Dict(
            "config" => config,
            "input" => input,
            "solved_model" => unsolved,
            "operational_state_trace" => trace,
        )
        artifact = write_pcm_operational_state_artifact(
            joinpath(root, "standalone_result_state"),
            result,
            data;
            boundary_hour = 3,
            boundary_time = DateTime(2035, 8, 2, 3),
            timezone = "America/New_York",
            scenario_id = "standalone-result-test",
        )
        @test artifact.state.storage_soc_mwh == [15.0]

        holistic_result = Dict(
            "pcm_config" => config,
            "pcm_input" => input,
            "pcm_solved_model" => unsolved,
            "pcm_operational_state_trace" => trace,
        )
        holistic_artifact = write_pcm_operational_state_artifact(
            joinpath(root, "holistic_result_state"),
            holistic_result,
            data;
            boundary_hour = 3,
            boundary_time = DateTime(2035, 8, 2, 3),
            timezone = "America/New_York",
            scenario_id = "holistic-result-test",
        )
        @test holistic_artifact.state.generation_mw == [40.0, 5.0]
    end

    mktempdir() do root
        @test_throws ArgumentError write_pcm_operational_state_artifact(
            joinpath(root, "wrong_interval"),
            config,
            input,
            trace,
            data;
            boundary_hour = 3,
            boundary_time = DateTime(2035, 8, 2, 3),
            timezone = "America/New_York",
            scenario_id = "wrong-interval-test",
            interval_minutes = 5,
        )
    end
end

@testset "PCM state ambiguity is rejected" begin
    config, input, model, data = pcm_state_test_fixture()
    relaxed = copy(config)
    relaxed["unit_commitment"] = 2
    @test_throws ArgumentError build_pcm_operational_state(
        relaxed,
        input,
        model,
        data;
        boundary_hour = 3,
    )

    clustered = copy(config)
    clustered["resource_aggregation"] = 1
    clustered["aggregation_settings"] = Dict("clustered_thermal_commitment" => 1)
    clustered_input = deepcopy(input)
    clustered_input["Gendata"][!, :NumUnits] = [2, 1]
    clustered_input["Gendata"][!, Symbol("ClusteredUnitPmax (MW)")] = [50.0, 50.0]
    clustered_input["Gendata"][!, Symbol("ClusteredUnitPmin (MW)")] = [5.0, 0.0]
    @test_throws ArgumentError build_pcm_operational_state(
        clustered,
        clustered_input,
        model,
        data;
        boundary_hour = 3,
    )

    missing_id_input = deepcopy(input)
    missing_id_input["Gendata"][2, :Asset_ID] = "WRONG"
    @test_throws ArgumentError build_pcm_operational_state(
        config,
        missing_id_input,
        model,
        data;
        boundary_hour = 3,
    )

    unsolved = Model(HOPE.HiGHS.Optimizer)
    @variable(unsolved, p[1:2, 1:3] >= 0)
    @variable(unsolved, o[1:1, 1:3], Bin)
    @variable(unsolved, soc[1:1, 1:3] >= 0)
    error = try
        build_pcm_operational_state(config, input, unsolved, data; boundary_hour = 3)
        nothing
    catch caught
        caught
    end
    @test error isa ArgumentError
    @test occursin("could not read the solved value", sprint(showerror, error))
end
