using Dates

function small_operational_snapshot(; disconnected = false)
    buses = [
        OperationalBus(
            id = "B1",
            source_row = 1,
            source_label = "1",
            zone = "Z1",
            peak_load_mw = 10.0,
        ),
        OperationalBus(
            id = "B2",
            source_row = 2,
            source_label = "2",
            zone = "Z2",
            peak_load_mw = 10.0,
        ),
    ]
    disconnected && push!(
        buses,
        OperationalBus(
            id = "B3",
            source_row = 3,
            source_label = "3",
            zone = "Z3",
            peak_load_mw = 0.0,
        ),
    )
    generator = OperationalGenerator(
        id = "G1",
        source_row = 1,
        technology = "Coal",
        bus_id = "B1",
        zone = "Z1",
        pmax_mw = 20.0,
        pmin_mw = 0.0,
        variable_cost_per_mwh = 35.0,
        startup_cost_per_mw = 12.0,
        static_availability = 1.0,
        forced_outage_rate = 0.08,
        ramp_up_fraction_per_hour = 0.4,
        ramp_down_fraction_per_hour = 0.4,
        commitment_required = true,
        min_up_hours = 6,
        min_down_hours = 6,
        must_run = false,
        reserve_fraction = Dict(
            :reg_up => 0.08,
            :reg_down => 0.08,
            :spin => 0.1,
            :nspin => 0.1,
        ),
        no_load_cost_per_hour = 3.0,
        shutdown_cost = 4.0,
        startup_limit_fraction = 0.75,
        shutdown_limit_fraction = 0.8,
        quick_start_eligible = true,
        quick_start_time_minutes = 20,
        nspin_capability_mw = 7.0,
        reserve_cost_per_mw_hour = Dict(
            :reg_up => 2.0,
            :reg_down => 1.0,
            :spin => 1.5,
            :nspin => 1.0,
        ),
    )
    resource = OperationalStorage(
        id = "S1",
        source_row = 1,
        technology = "BES",
        bus_id = "B2",
        zone = "Z2",
        energy_capacity_mwh = 40.0,
        charge_capacity_mw = 10.0,
        discharge_capacity_mw = 10.0,
        charge_efficiency = 0.9,
        discharge_efficiency = 0.9,
        variable_cost_per_mwh = 1.0,
        reserve_capability_mw = Dict(
            :reg_up => 4.0,
            :reg_down => 3.0,
            :spin => 2.0,
            :nspin => 1.0,
        ),
        reserve_cost_per_mw_hour = Dict(
            :reg_up => 2.0,
            :reg_down => 1.0,
            :spin => 1.5,
            :nspin => 1.0,
        ),
    )
    branches = [
        OperationalBranch(
            id = "L1",
            source_row = 1,
            from_bus_id = "B1",
            to_bus_id = "B2",
            reactance = 0.1,
            forward_limit_mw = 100.0,
            reverse_limit_mw = 100.0,
        ),
        OperationalBranch(
            id = "L2",
            source_row = 2,
            from_bus_id = "B1",
            to_bus_id = "B2",
            reactance = 0.1,
            forward_limit_mw = 100.0,
            reverse_limit_mw = 100.0,
        ),
    ]
    return OperationalSnapshot(
        name = "test",
        generators = [generator],
        storage = [resource],
        buses = buses,
        branches = branches,
        timestamps = [DateTime(2021, 1, 1), DateTime(2021, 1, 1, 1)],
        load_mw = disconnected ? [10.0 20.0; 5.0 10.0; 0.0 0.0] : [10.0 20.0; 5.0 10.0],
        availability = [1.0 0.5],
        interchange_mw = zeros(length(buses), 2),
        reserve_requirement_fraction = Dict(
            :reg_up => 0.01,
            :reg_down => 0.01,
            :spin => 0.03,
            :nspin => 0.02,
        ),
        source_hashes = Dict{String,String}(),
        provenance = Dict{String,String}(),
    )
end

@testset "Operational snapshot parameter conversion" begin
    snapshot = small_operational_snapshot()
    data = build_dart_system(snapshot; profile = :deterministic_derated)
    generator = only(data.generators)
    @test generator.startup_cost == 240.0
    @test generator.ramp_up_mw_per_hour == 8.0
    @test generator.real_time_ramp_up_mw_per_hour ≈ 7.36
    @test generator.forced_outage_rate == 0.08
    @test generator.no_load_cost_per_hour == 3.0
    @test generator.shutdown_cost == 4.0
    @test generator.startup_limit_mw == 15.0
    @test generator.shutdown_limit_mw == 16.0
    @test generator.quick_start_eligible
    @test generator.quick_start_time_minutes == 20

    reserves = build_dart_system(
        snapshot;
        profile = :deterministic_derated,
        include_reserves = true,
        include_nspin = true,
    )
    @test only(reserves.generators).reserve_capability_mw[:nspin] ≈ 6.44
    @test only(reserves.generators).reserve_cost_per_mw_hour[:reg_up] == 2.0
    @test only(reserves.storage).reserve_capability_mw[:reg_up] == 4.0
    @test only(reserves.storage).reserve_cost_per_mw_hour[:spin] == 1.5

    common = build_dart_system(
        snapshot;
        include_unit_commitment = false,
        enforce_ramps = false,
        include_storage = false,
    )
    @test !only(common.generators).commitment_required
    @test only(common.generators).pmin_mw == 0.0
    @test isinf(only(common.generators).ramp_up_mw_per_hour)
    @test isempty(common.storage)

    outage = build_dart_system(snapshot; profile = :physical_outage)
    @test only(outage.generators).forced_outage_rate == 0.0
end

@testset "Operational snapshot network and chronology" begin
    snapshot = small_operational_snapshot()
    data = build_dart_system(snapshot)
    @test data.network.line_names == ["L1", "L2"]
    injection = [10.0, -10.0]
    flow = data.network.ptdf * injection
    @test flow ≈ [5.0, 5.0] atol = 1e-9

    forecast = build_dart_forecasts(snapshot, 1:2)
    @test size(forecast.real_time.load_mw) == (2, 24)
    @test vec(sum(forecast.real_time.load_mw; dims = 2)) ./ 12 ≈
          vec(sum(forecast.day_ahead.load_mw; dims = 2))
    @test length(forecast.real_time_timestamps) == 24
    @test forecast.real_time_timestamps[2] - forecast.real_time_timestamps[1] == Minute(5)

    day_ahead_reserves = build_dart_forecasts(
        snapshot,
        1:2;
        include_reserves = true,
        include_real_time_reserve_requirements = false,
    )
    @test !isempty(day_ahead_reserves.day_ahead.reserve_requirement_mw)
    @test isempty(day_ahead_reserves.real_time.reserve_requirement_mw)

    state = build_dart_initial_state(data)
    @test state.generation_mw == [0.0]
    @test state.storage_soc_mwh == [20.0]
    @test_throws ArgumentError build_dart_system(
        small_operational_snapshot(disconnected = true),
    )
end
