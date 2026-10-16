function operational_state_test_system()
    return DARTSystemData(
        generators = [
            DARTGenerator(name = "G-1", bus = "B-1", pmax_mw = 100.0, pmin_mw = 10.0),
            DARTGenerator(
                name = "G-2",
                bus = "B-2",
                pmax_mw = 50.0,
                commitment_required = false,
            ),
        ],
        network = DARTNetwork(
            bus_names = ["B-1", "B-2"],
            line_names = ["L-1"],
            ptdf = [0.5 -0.5],
            line_limit_mw = [75.0],
            emergency_line_limit_mw = [90.0],
        ),
        storage = [
            DARTStorage(
                name = "S-1",
                bus = "B-2",
                energy_capacity_mwh = 40.0,
                charge_capacity_mw = 10.0,
                discharge_capacity_mw = 10.0,
            ),
        ],
    )
end

function operational_state_test_state()
    return DARTState(
        commitment = [1, 1],
        generation_mw = [25.0, 5.0],
        on_duration_hours = [6.0, 24.0],
        off_duration_hours = [0.0, 0.0],
        storage_soc_mwh = [18.0],
        generator_in_service = [true, true],
    )
end

@testset "Operational-state artifact round trip" begin
    data = operational_state_test_system()
    state = operational_state_test_state()
    mktempdir() do root
        path = joinpath(root, "state")
        artifact = write_operational_state_artifact(
            path,
            data,
            state;
            boundary_time = DateTime(2035, 7, 1, 12, 5),
            timezone = "America/New_York",
            interval_minutes = 5,
            source_model = "PCM",
            scenario_id = "md-2035-weather-a",
            initialization_method = "preceding_run",
            parent_artifact_hashes = Dict("physical_system" => "abc123"),
            assumptions = Dict("commitment_mapping" => "unit-level stable ID"),
        )
        @test artifact.schema_version == 1
        @test artifact.source_model == "PCM"
        @test artifact.boundary_time == DateTime(2035, 7, 1, 12, 5)
        @test artifact.interval_minutes == 5
        @test artifact.physical_system_hash == dart_system_fingerprint(data)
        @test artifact.state.commitment == state.commitment
        @test artifact.state.generation_mw == state.generation_mw
        @test artifact.state.storage_soc_mwh == state.storage_soc_mwh
        @test isfile(joinpath(path, "manifest.yml"))
        @test isfile(joinpath(path, "generator_state.csv"))
        @test isfile(joinpath(path, "storage_state.csv"))
        @test_throws ArgumentError write_operational_state_artifact(
            path,
            data,
            state;
            boundary_time = DateTime(2035),
            interval_minutes = 5,
            source_model = "DART",
            scenario_id = "duplicate",
            initialization_method = "assumed",
        )
    end
end

@testset "Operational-state integrity and compatibility" begin
    data = operational_state_test_system()
    state = operational_state_test_state()
    mktempdir() do root
        path = joinpath(root, "state")
        write_operational_state_artifact(
            path,
            data,
            state;
            boundary_time = DateTime(2035, 1, 1),
            interval_minutes = 60,
            source_model = "STANDALONE",
            scenario_id = "test",
            initialization_method = "assumed",
        )
        open(joinpath(path, "generator_state.csv"), "a") do io
            write(io, "\n")
        end
        @test_throws ArgumentError load_operational_state_artifact(path, data)
    end

    mktempdir() do root
        path = joinpath(root, "state")
        write_operational_state_artifact(
            path,
            data,
            state;
            boundary_time = DateTime(2035, 1, 1),
            interval_minutes = 60,
            source_model = "DART",
            scenario_id = "test",
            initialization_method = "preceding_run",
            assumptions = Dict("state_source" => "solved"),
        )
        manifest_path = joinpath(path, "manifest.yml")
        manifest = YAML.load_file(manifest_path)
        manifest["assumptions"]["state_source"] = "manually-edited"
        open(manifest_path, "w") do io
            YAML.write(io, manifest)
        end
        @test_throws ArgumentError load_operational_state_artifact(path, data)
    end

    mktempdir() do root
        path = joinpath(root, "state")
        write_operational_state_artifact(
            path,
            data,
            state;
            boundary_time = DateTime(2035, 1, 1),
            interval_minutes = 60,
            source_model = "DART",
            scenario_id = "test",
            initialization_method = "preceding_run",
        )
        changed = operational_state_test_system()
        changed.generators[1].pmax_mw == 100.0
        incompatible = DARTSystemData(
            generators = [
                DARTGenerator(name = "G-1", bus = "B-1", pmax_mw = 101.0),
                changed.generators[2],
            ],
            network = changed.network,
            storage = changed.storage,
        )
        @test_throws ArgumentError load_operational_state_artifact(path, incompatible)
    end
end

@testset "Operational-state schema declaration" begin
    schema = YAML.load_file(joinpath(@__DIR__, "..", "schemas", "operational_state_v1.yml"))
    @test schema["schema_version"] == 1
    @test schema["artifact_type"] == "HOPE.simulation_state"
end
