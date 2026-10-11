using HOPE
using JuMP
using Test

single_bus() = DARTNetwork(bus_names = ["bus"])

function state(commitment, generation; service = trues(length(commitment)), soc = Float64[])
    return DARTState(
        commitment = commitment,
        generation_mw = generation,
        on_duration_hours = [status == 1 ? 10.0 : 0.0 for status in commitment],
        off_duration_hours = [status == 0 ? 10.0 : 0.0 for status in commitment],
        storage_soc_mwh = soc,
        generator_in_service = service,
    )
end

@testset "DART generator N-1 and reserve response" begin
    generators = [
        DARTGenerator(
            name = "energy",
            bus = "bus",
            pmax_mw = 80.0,
            variable_cost_per_mwh = 10.0,
            contingency_eligible = true,
        ),
        DARTGenerator(
            name = "response",
            bus = "bus",
            pmax_mw = 100.0,
            variable_cost_per_mwh = 30.0,
            ramp_up_mw_per_hour = 600.0,
            reserve_capability_mw = Dict(:spin => 100.0),
        ),
    ]
    data = DARTSystemData(generators = generators, network = single_bus())
    forecast = DARTForecast(
        interval_hours = 1.0,
        load_mw = fill(80.0, 1, 1),
        availability = ones(2, 1),
    )
    result = solve_dart_scuc(data, forecast, state([1, 1], [80.0, 0.0]))

    @test result.generation_mw[:, 1] ≈ [80.0, 0.0] atol = 1e-6
    @test result.generator_reserve_mw[:spin][2, 1] ≈ 80.0 atol = 1e-6
    @test sum(result.emergency_load_shed_mw) <= 1e-6
    @test result.contingency_generator_indices == [1]
    @test result.termination_status == JuMP.MOI.OPTIMAL
    @test result.primal_status == JuMP.MOI.FEASIBLE_POINT
    @test result.solve_time_seconds >= 0
    @test result.relative_gap <= 1e-8
end

@testset "DART strict and soft N-1 security" begin
    generators = [
        DARTGenerator(
            name = "contingency",
            bus = "bus",
            pmax_mw = 10.0,
            contingency_eligible = true,
        ),
        DARTGenerator(
            name = "expensive_response",
            bus = "bus",
            pmax_mw = 10.0,
            variable_cost_per_mwh = 60_000.0,
            ramp_up_mw_per_hour = 600.0,
            reserve_capability_mw = Dict(:spin => 10.0),
            reserve_cost_per_mw_hour = Dict(:spin => 100_000.0),
        ),
    ]
    data = DARTSystemData(generators = generators, network = single_bus())
    forecast = DARTForecast(
        interval_hours = 1.0,
        load_mw = fill(10.0, 1, 1),
        availability = ones(2, 1),
    )
    initial_state = state([1, 1], [10.0, 0.0])

    strict = solve_dart_scuc(data, forecast, initial_state)
    soft = solve_dart_scuc(
        data,
        forecast,
        initial_state;
        config = DARTConfig(allow_emergency_contingency_shed = true),
    )

    @test sum(strict.emergency_load_shed_mw) <= 1e-6
    @test strict.generation_mw[2, 1] ≈ 10.0 atol = 1e-6
    @test sum(soft.emergency_load_shed_mw) ≈ 10.0 atol = 1e-6
    @test soft.generation_mw[1, 1] ≈ 10.0 atol = 1e-6
end

@testset "DART product response limits and quick start" begin
    products = [
        DARTReserveProduct(name = :reg_up, direction = :up, response_minutes = 5),
        DARTReserveProduct(name = :spin, direction = :up, response_minutes = 10),
        DARTReserveProduct(
            name = :nspin,
            direction = :up,
            response_minutes = 30,
            requires_online = false,
        ),
    ]
    generators = [
        DARTGenerator(
            name = "outage",
            bus = "bus",
            pmax_mw = 15.0,
            variable_cost_per_mwh = 10.0,
            contingency_eligible = true,
        ),
        DARTGenerator(
            name = "online_response",
            bus = "bus",
            pmax_mw = 100.0,
            variable_cost_per_mwh = 30.0,
            ramp_up_mw_per_hour = 60.0,
            reserve_capability_mw = Dict(:reg_up => 100.0, :spin => 100.0),
        ),
    ]
    data = DARTSystemData(
        generators = generators,
        network = single_bus(),
        reserve_products = products,
    )
    forecast = DARTForecast(
        interval_hours = 1.0,
        load_mw = fill(15.0, 1, 1),
        availability = ones(2, 1),
    )
    config = DARTConfig(
        security_up_products = [:reg_up, :spin, :nspin],
        security_down_products = Symbol[],
    )
    result = solve_dart_scuc(data, forecast, state([1, 1], [15.0, 0.0]); config = config)

    @test result.generator_reserve_mw[:reg_up][2, 1] ≈ 5.0 atol = 1e-6
    @test result.generator_reserve_mw[:spin][2, 1] ≈ 10.0 atol = 1e-6
    @test sum(result.emergency_load_shed_mw) <= 1e-6

    quick_start = DARTGenerator(
        name = "quick_start",
        bus = "bus",
        pmax_mw = 20.0,
        variable_cost_per_mwh = 50.0,
        quick_start_eligible = true,
        quick_start_time_minutes = 20,
        reserve_capability_mw = Dict(:nspin => 20.0),
    )
    quick_data = DARTSystemData(
        generators = [generators[1], quick_start],
        network = single_bus(),
        reserve_products = products,
    )
    quick_result =
        solve_dart_scuc(quick_data, forecast, state([1, 0], [15.0, 0.0]); config = config)
    @test quick_result.commitment[2, 1] == 0
    @test quick_result.generator_reserve_mw[:nspin][2, 1] >= 15.0 - 1e-6
    @test quick_result.generator_reserve_mw[:nspin][2, 1] <= 20.0 + 1e-6
    @test sum(quick_result.emergency_load_shed_mw) <= 1e-6

    unavailable_forecast = DARTForecast(
        interval_hours = 1.0,
        load_mw = fill(15.0, 1, 1),
        availability = reshape([1.0, 0.0], 2, 1),
    )
    unavailable = solve_dart_scuc(
        quick_data,
        unavailable_forecast,
        state([1, 0], [15.0, 0.0]);
        config = DARTConfig(
            allow_emergency_contingency_shed = true,
            security_up_products = [:reg_up, :spin, :nspin],
            security_down_products = Symbol[],
        ),
    )
    @test unavailable.generator_reserve_mw[:nspin][2, 1] <= 1e-8
    @test sum(unavailable.emergency_load_shed_mw) ≈ 15.0 atol = 1e-6

    minimum_down_generator = DARTGenerator(
        name = "minimum_down_quick_start",
        bus = "bus",
        pmax_mw = 10.0,
        min_down_hours = 2,
        quick_start_eligible = true,
        quick_start_time_minutes = 20,
        reserve_capability_mw = Dict(:nspin => 10.0),
    )
    minimum_down_data = DARTSystemData(
        generators = [minimum_down_generator],
        network = single_bus(),
        reserve_products = products,
    )
    minimum_down_forecast = DARTForecast(
        interval_hours = 1.0,
        load_mw = zeros(1, 2),
        availability = ones(1, 2),
        reserve_requirement_mw = Dict(:nspin => [0.0, 10.0]),
    )
    @test_throws ErrorException solve_dart_scuc(
        minimum_down_data,
        minimum_down_forecast,
        state([1], [0.0]);
        config = config,
    )

    offline_products = [
        DARTReserveProduct(
            name = :nspin_10,
            direction = :up,
            response_minutes = 10,
            requires_online = false,
        ),
        DARTReserveProduct(
            name = :nspin_30,
            direction = :up,
            response_minutes = 30,
            requires_online = false,
        ),
    ]
    aggregate_quick_start = DARTGenerator(
        name = "aggregate_quick_start",
        bus = "bus",
        pmax_mw = 10.0,
        quick_start_eligible = true,
        quick_start_time_minutes = 10,
        reserve_capability_mw = Dict(:nspin_10 => 10.0, :nspin_30 => 10.0),
    )
    aggregate_data = DARTSystemData(
        generators = [aggregate_quick_start],
        network = single_bus(),
        reserve_products = offline_products,
    )
    aggregate_forecast = DARTForecast(
        interval_hours = 1.0,
        load_mw = zeros(1, 1),
        availability = ones(1, 1),
        reserve_requirement_mw = Dict(:nspin_10 => [10.0], :nspin_30 => [10.0]),
    )
    @test_throws ErrorException solve_dart_scuc(
        aggregate_data,
        aggregate_forecast,
        state([0], [0.0]);
        config = DARTConfig(
            security_up_products = Symbol[],
            security_down_products = Symbol[],
        ),
    )
end

@testset "DART real-time ramp and equipment transitions" begin
    generator = DARTGenerator(
        name = "unit",
        bus = "bus",
        pmax_mw = 100.0,
        startup_limit_mw = 5.0,
        shutdown_limit_mw = 30.0,
        ramp_down_mw_per_hour = 12.0,
        real_time_ramp_up_mw_per_hour = 60.0,
        real_time_ramp_down_mw_per_hour = 60.0,
    )
    data = DARTSystemData(generators = [generator], network = single_bus())
    config = DARTConfig(
        security_up_products = [:reg_up, :spin, :nspin],
        security_down_products = [:reg_down],
    )

    forecast = DARTForecast(
        interval_hours = 1 / 12,
        load_mw = fill(15.0, 1, 1),
        availability = ones(1, 1),
    )
    ramp = solve_dart_sced(data, forecast, state([1], [10.0]), [1]; config = config)
    @test ramp.generation_mw[1, 1] ≈ 15.0 atol = 1e-6

    availability_drop_forecast = DARTForecast(
        interval_hours = 1 / 12,
        load_mw = reshape([50.0, 49.0], 1, :),
        availability = fill(0.5, 1, 2),
    )
    availability_drop = solve_dart_sced(
        data,
        availability_drop_forecast,
        state([1], [100.0]),
        ones(Int, 1, 2);
        config = config,
    )
    @test isapprox(vec(availability_drop.generation_mw), [50.0, 49.0]; atol = 1e-6)

    day_ahead_availability_drop = solve_dart_scuc(
        data,
        DARTForecast(
            interval_hours = 1.0,
            load_mw = reshape([50.0, 38.0], 1, :),
            availability = fill(0.5, 1, 2),
        ),
        state([1], [100.0]);
        config = config,
    )
    @test isapprox(
        vec(day_ahead_availability_drop.generation_mw),
        [50.0, 38.0];
        atol = 1e-6,
    )

    startup = solve_dart_sced(data, forecast, state([0], [0.0]), [1]; config = config)
    @test startup.generation_mw[1, 1] ≈ 5.0 atol = 1e-6
    @test startup.load_shed_mw[1, 1] ≈ 10.0 atol = 1e-6

    trip_forecast = DARTForecast(
        interval_hours = 1 / 12,
        load_mw = zeros(1, 1),
        availability = ones(1, 1),
        generator_in_service = falses(1, 1),
    )
    trip = solve_dart_sced(
        data,
        trip_forecast,
        state([1], [30.0]; service = [true]),
        [1];
        config = config,
    )
    @test trip.generation_mw[1, 1] <= 1e-8

    return_to_service = solve_dart_sced(
        data,
        forecast,
        state([1], [0.0]; service = [false]),
        [1];
        config = config,
    )
    @test return_to_service.generation_mw[1, 1] ≈ 5.0 atol = 1e-6

    noncommit_data = DARTSystemData(
        generators = [
            DARTGenerator(
                name = "noncommit",
                bus = "bus",
                pmax_mw = 100.0,
                commitment_required = false,
            ),
        ],
        network = single_bus(),
    )
    noncommit_result = solve_dart_sced(
        noncommit_data,
        forecast,
        default_dart_state(noncommit_data),
        [0];
        config = config,
    )
    @test noncommit_result.commitment[1, 1] == 1
    @test noncommit_result.generation_mw[1, 1] ≈ 15.0 atol = 1e-6
    @test noncommit_result.load_shed_mw[1, 1] <= 1e-6
end

@testset "DART nodal PTDF and storage chronology" begin
    network = DARTNetwork(
        bus_names = ["one", "two"],
        line_names = ["one_to_two"],
        ptdf = reshape([0.0, -1.0], 1, 2),
        line_limit_mw = [20.0],
        emergency_line_limit_mw = [25.0],
    )
    generators = [
        DARTGenerator(
            name = "cheap",
            bus = "one",
            pmax_mw = 100.0,
            variable_cost_per_mwh = 10.0,
            commitment_required = false,
        ),
        DARTGenerator(
            name = "local",
            bus = "two",
            pmax_mw = 100.0,
            variable_cost_per_mwh = 30.0,
            commitment_required = false,
        ),
    ]
    data = DARTSystemData(generators = generators, network = network)
    forecast = DARTForecast(
        interval_hours = 1.0,
        load_mw = reshape([0.0, 40.0], 2, 1),
        availability = ones(2, 1),
    )
    result = solve_dart_scuc(data, forecast, default_dart_state(data))
    @test result.generation_mw[:, 1] ≈ [20.0, 20.0] atol = 1e-6
    @test result.line_flow_mw[1, 1] ≈ 20.0 atol = 1e-6
    @test result.lmp_per_mwh[:, 1] ≈ [10.0, 30.0] atol = 1e-6

    storage = DARTStorage(
        name = "battery",
        bus = "bus",
        energy_capacity_mwh = 10.0,
        charge_capacity_mw = 10.0,
        discharge_capacity_mw = 10.0,
    )
    storage_generator = DARTGenerator(
        name = "expensive",
        bus = "bus",
        pmax_mw = 100.0,
        variable_cost_per_mwh = 100.0,
        commitment_required = false,
    )
    storage_data = DARTSystemData(
        generators = [storage_generator],
        storage = [storage],
        network = single_bus(),
    )
    storage_forecast = DARTForecast(
        interval_hours = 1.0,
        load_mw = fill(10.0, 1, 1),
        availability = ones(1, 1),
    )
    storage_result =
        solve_dart_scuc(storage_data, storage_forecast, state([1], [0.0]; soc = [10.0]))
    @test storage_result.storage_discharge_mw[1, 1] ≈ 10.0 atol = 1e-6
    @test storage_result.storage_soc_mwh[1, 1] <= 1e-6
    @test storage_result.storage_charge_mw[1, 1] *
          storage_result.storage_discharge_mw[1, 1] <= 1e-8

    storage_rt = solve_dart_sced(
        storage_data,
        storage_forecast,
        state([1], [0.0]; soc = [10.0]),
        [1],
    )
    @test storage_rt.storage_discharge_mw[1, 1] ≈ 10.0 atol = 1e-6
    @test isfinite(storage_rt.lmp_per_mwh[1, 1])

    terminal_forecast = DARTForecast(
        interval_hours = 1.0,
        load_mw = reshape([0.0, 8.0], 1, 2),
        availability = reshape([1.0, 0.0], 1, 2),
        terminal_storage_soc_mwh = [0.0],
    )
    terminal_result =
        solve_dart_scuc(storage_data, terminal_forecast, state([1], [0.0]; soc = [0.0]))
    @test terminal_result.storage_charge_mw[1, 1] ≈ 8.0 atol = 1e-6
    @test terminal_result.storage_discharge_mw[1, 2] ≈ 8.0 atol = 1e-6
    @test terminal_result.storage_soc_mwh[1, 2] ≈ 0.0 atol = 1e-6

    must_run = DARTGenerator(name = "must_run", bus = "bus", pmax_mw = 20.0, pmin_mw = 20.0)
    inefficient_storage = DARTStorage(
        name = "inefficient",
        bus = "bus",
        energy_capacity_mwh = 10.0,
        charge_capacity_mw = 100.0,
        discharge_capacity_mw = 100.0,
        charge_efficiency = 0.8,
        discharge_efficiency = 0.8,
    )
    physical_data = DARTSystemData(
        generators = [must_run],
        storage = [inefficient_storage],
        network = single_bus(),
    )
    zero_load =
        DARTForecast(interval_hours = 1.0, load_mw = zeros(1, 1), availability = ones(1, 1))
    @test_throws ErrorException solve_dart_sced(
        physical_data,
        zero_load,
        state([1], [20.0]; soc = [10.0]),
        [1],
    )
end

@testset "DART rolling simulation and settlements" begin
    generators = [
        DARTGenerator(
            name = "energy",
            bus = "bus",
            pmax_mw = 80.0,
            variable_cost_per_mwh = 10.0,
            contingency_eligible = true,
        ),
        DARTGenerator(
            name = "response",
            bus = "bus",
            pmax_mw = 100.0,
            variable_cost_per_mwh = 30.0,
            ramp_up_mw_per_hour = 600.0,
            real_time_ramp_up_mw_per_hour = 600.0,
            real_time_ramp_down_mw_per_hour = 600.0,
            reserve_capability_mw = Dict(:spin => 100.0),
            reserve_cost_per_mw_hour = Dict(:spin => 5.0),
        ),
    ]
    data = DARTSystemData(generators = generators, network = single_bus())
    day_ahead = DARTForecast(
        interval_hours = 1.0,
        load_mw = fill(70.0, 1, 1),
        availability = ones(2, 1),
    )
    real_time = DARTForecast(
        interval_hours = 1 / 12,
        load_mw = fill(70.0, 1, 12),
        availability = ones(2, 12),
    )
    rolling = run_dart_rolling(
        data,
        day_ahead,
        real_time,
        state([1, 1], [70.0, 0.0]);
        hours_to_run = 1,
        day_ahead_lookahead_hours = 1,
        real_time_lookahead_intervals = 3,
    )
    settlement = calculate_dart_settlements(data, rolling)

    @test length(rolling.day_ahead_results) == 1
    @test length(rolling.real_time_results) == 12
    @test all(result.generation_mw[1, 1] ≈ 70.0 for result in rolling.real_time_results)
    @test rolling.final_state.generation_mw ≈ [70.0, 0.0] atol = 1e-6
    @test all(
        result.reserve_requirement_shadow_price_per_mw_hour[:spin][1] ≈ 0.0 for
        result in rolling.real_time_results
    )
    @test settlement.generator_reserve_credit[2] ≈ 350.0 atol = 1e-6
    @test settlement.settlement_balance ≈ 0.0 atol = 1e-6

    incomplete = DARTRollingResult(
        day_ahead_results = rolling.day_ahead_results,
        real_time_results = rolling.real_time_results[1:11],
        rt_to_da_index = rolling.rt_to_da_index[1:11],
        final_state = rolling.final_state,
    )
    @test_throws ArgumentError calculate_dart_settlements(data, incomplete)
end

@testset "DART numerical two-settlement accounting" begin
    generator = DARTGenerator(
        name = "supplier",
        bus = "bus",
        pmax_mw = 200.0,
        variable_cost_per_mwh = 10.0,
        no_load_cost_per_hour = 20.0,
        commitment_required = false,
        reserve_capability_mw = Dict(:spin => 50.0),
        reserve_cost_per_mw_hour = Dict(:spin => 5.0),
    )
    data = DARTSystemData(generators = [generator], network = single_bus())
    day_ahead = DARTForecast(
        interval_hours = 1.0,
        load_mw = fill(100.0, 1, 1),
        availability = ones(1, 1),
        interchange_mw = fill(10.0, 1, 1),
        reserve_requirement_mw = Dict(:spin => [10.0]),
    )
    real_time = DARTForecast(
        interval_hours = 1.0,
        load_mw = fill(110.0, 1, 1),
        availability = ones(1, 1),
        interchange_mw = fill(10.0, 1, 1),
        reserve_requirement_mw = Dict(:spin => [12.0]),
    )
    rolling = run_dart_rolling(
        data,
        day_ahead,
        real_time,
        state([1], [90.0]);
        hours_to_run = 1,
        day_ahead_lookahead_hours = 1,
        real_time_lookahead_intervals = 1,
    )
    settlement = calculate_dart_settlements(data, rolling)
    da = only(rolling.day_ahead_results)
    rt = only(rolling.real_time_results)

    @test da.generation_mw[1, 1] ≈ 90.0 atol = 1e-6
    @test rt.generation_mw[1, 1] ≈ 100.0 atol = 1e-6
    @test da.generator_reserve_mw[:spin][1, 1] ≈ 10.0 atol = 1e-6
    @test rt.generator_reserve_mw[:spin][1, 1] ≈ 12.0 atol = 1e-6
    @test da.reserve_requirement_shadow_price_per_mw_hour[:spin][1] ≈ 5.0 atol = 1e-6
    @test rt.reserve_requirement_shadow_price_per_mw_hour[:spin][1] ≈ 5.0 atol = 1e-6

    @test settlement.generator_day_ahead_energy ≈ [900.0] atol = 1e-6
    @test settlement.generator_real_time_deviation ≈ [100.0] atol = 1e-6
    @test settlement.generator_reserve_credit ≈ [60.0] atol = 1e-6
    @test settlement.generator_uplift ≈ [20.0] atol = 1e-6
    @test settlement.load_energy_payment ≈ [1_100.0] atol = 1e-6
    @test settlement.load_reserve_charge ≈ [60.0] atol = 1e-6
    @test settlement.load_uplift_charge ≈ [20.0] atol = 1e-6
    @test settlement.interchange_credit ≈ [100.0] atol = 1e-6
    @test settlement.merchandising_surplus ≈ 0.0 atol = 1e-6
    @test settlement.settlement_balance ≈ 0.0 atol = 1e-6
end

@testset "DART zero-load settlement residual" begin
    generator = DARTGenerator(
        name = "reserve_supplier",
        bus = "bus",
        pmax_mw = 100.0,
        commitment_required = false,
        reserve_capability_mw = Dict(:spin => 10.0),
        reserve_cost_per_mw_hour = Dict(:spin => 5.0),
    )
    data = DARTSystemData(generators = [generator], network = single_bus())
    forecast = DARTForecast(
        interval_hours = 1.0,
        load_mw = zeros(1, 1),
        availability = ones(1, 1),
        reserve_requirement_mw = Dict(:spin => [10.0]),
    )
    rolling = run_dart_rolling(
        data,
        forecast,
        forecast;
        hours_to_run = 1,
        day_ahead_lookahead_hours = 1,
        real_time_lookahead_intervals = 1,
    )
    settlement = calculate_dart_settlements(data, rolling)

    @test settlement.reserve_settlement_rule == :pay_as_bid
    @test settlement.generator_reserve_credit ≈ [50.0] atol = 1e-6
    @test settlement.load_reserve_charge ≈ [0.0] atol = 1e-6
    @test settlement.unallocated_reserve_charge ≈ 50.0 atol = 1e-6
    @test settlement.unallocated_uplift_charge ≈ 0.0 atol = 1e-6
    @test settlement.settlement_balance ≈ 0.0 atol = 1e-6

    invalid_mapping = DARTRollingResult(
        day_ahead_results = rolling.day_ahead_results,
        real_time_results = rolling.real_time_results,
        rt_to_da_index = [2],
        final_state = rolling.final_state,
    )
    @test_throws ArgumentError calculate_dart_settlements(data, invalid_mapping)
end

@testset "DART 24-hour generator N-1 case and size safeguard" begin
    generators = [
        DARTGenerator(
            name = "unit_$(g)",
            bus = "bus",
            pmax_mw = 100.0,
            variable_cost_per_mwh = Float64(g),
            commitment_required = false,
            contingency_eligible = true,
            reserve_capability_mw = Dict(:spin => 100.0),
        ) for g = 1:12
    ]
    data = DARTSystemData(generators = generators, network = single_bus())
    forecast = DARTForecast(
        interval_hours = 1.0,
        load_mw = fill(600.0, 1, 24),
        availability = ones(12, 24),
    )
    result = solve_dart_scuc(data, forecast, default_dart_state(data))

    @test result.termination_status == JuMP.MOI.OPTIMAL
    @test size(result.emergency_load_shed_mw) == (1, 24, 12)
    @test sum(result.emergency_load_shed_mw) <= 1e-6
    @test all(
        isapprox(sum(result.generation_mw[:, t]), 600.0; atol = 1e-6) for
        t in axes(result.generation_mw, 2)
    )

    @test_throws ArgumentError build_dart_scuc_model(
        data,
        forecast,
        default_dart_state(data);
        config = DARTConfig(maximum_security_variables = 100),
    )
end

@testset "DART production input validation" begin
    generator = DARTGenerator(
        name = "unit",
        bus = "bus",
        pmax_mw = 10.0,
        commitment_required = false,
    )
    data = DARTSystemData(generators = [generator], network = single_bus())
    forecast =
        DARTForecast(interval_hours = 1.0, load_mw = zeros(1, 1), availability = ones(1, 1))

    invalid_availability = DARTForecast(
        interval_hours = 1.0,
        load_mw = zeros(1, 1),
        availability = fill(NaN, 1, 1),
    )
    @test_throws ArgumentError build_dart_scuc_model(
        data,
        invalid_availability,
        default_dart_state(data),
    )

    invalid_terminal = DARTForecast(
        interval_hours = 1.0,
        load_mw = zeros(1, 1),
        availability = ones(1, 1),
        terminal_storage_soc_mwh = [0.0],
    )
    @test_throws ArgumentError build_dart_scuc_model(
        data,
        invalid_terminal,
        default_dart_state(data),
    )

    invalid_generator =
        DARTGenerator(name = "unit", bus = "bus", pmax_mw = 10.0, startup_limit_mw = -1.0)
    invalid_generator_data =
        DARTSystemData(generators = [invalid_generator], network = single_bus())
    @test_throws ArgumentError build_dart_scuc_model(
        invalid_generator_data,
        forecast,
        default_dart_state(invalid_generator_data),
    )

    invalid_network = DARTNetwork(
        bus_names = ["bus"],
        line_names = ["line"],
        ptdf = zeros(1, 1),
        line_limit_mw = [-1.0],
        emergency_line_limit_mw = [0.0],
    )
    invalid_network_data =
        DARTSystemData(generators = [generator], network = invalid_network)
    @test_throws ArgumentError build_dart_scuc_model(
        invalid_network_data,
        forecast,
        default_dart_state(invalid_network_data),
    )

    @test_throws ArgumentError build_dart_scuc_model(
        data,
        forecast,
        default_dart_state(data);
        config = DARTConfig(maximum_security_variables = 0),
    )
    @test_throws ArgumentError run_dart_rolling(
        data,
        forecast,
        forecast;
        hours_to_run = 1,
        day_ahead_lookahead_hours = 0,
    )
end
