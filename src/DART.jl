"""
Day-ahead security-constrained unit commitment, rolling real-time dispatch,
generator N-1 security, and two-settlement accounting.

The implementation is intentionally contained in one file. The JuMP
constraints follow the notation groups in `HOPE_SCUC_SCED.pdf` directly.
"""
module DART

using HiGHS
using JuMP

const MOI = JuMP.MOI

# -----------------------------------------------------------------------------
# Data
# -----------------------------------------------------------------------------

Base.@kwdef struct DARTReserveProduct
    name::Symbol
    direction::Symbol
    response_minutes::Int
    requires_online::Bool = true
end

Base.@kwdef struct DARTGenerator
    name::String
    bus::String
    pmax_mw::Float64
    pmin_mw::Float64 = 0.0
    variable_cost_per_mwh::Float64 = 0.0
    no_load_cost_per_hour::Float64 = 0.0
    startup_cost::Float64 = 0.0
    shutdown_cost::Float64 = 0.0
    ramp_up_mw_per_hour::Float64 = Inf
    ramp_down_mw_per_hour::Float64 = Inf
    real_time_ramp_up_mw_per_hour::Float64 = ramp_up_mw_per_hour
    real_time_ramp_down_mw_per_hour::Float64 = ramp_down_mw_per_hour
    startup_limit_mw::Float64 = pmax_mw
    shutdown_limit_mw::Float64 = pmax_mw
    min_up_hours::Int = 0
    min_down_hours::Int = 0
    commitment_required::Bool = true
    contingency_eligible::Bool = false
    forced_outage_rate::Float64 = 0.0
    quick_start_eligible::Bool = false
    quick_start_time_minutes::Int = typemax(Int)
    reserve_capability_mw::Dict{Symbol,Float64} = Dict{Symbol,Float64}()
    reserve_cost_per_mw_hour::Dict{Symbol,Float64} = Dict{Symbol,Float64}()
end

Base.@kwdef struct DARTStorage
    name::String
    bus::String
    energy_capacity_mwh::Float64
    charge_capacity_mw::Float64
    discharge_capacity_mw::Float64
    charge_efficiency::Float64 = 1.0
    discharge_efficiency::Float64 = 1.0
    variable_cost_per_mwh::Float64 = 0.0
    reserve_capability_mw::Dict{Symbol,Float64} = Dict{Symbol,Float64}()
    reserve_cost_per_mw_hour::Dict{Symbol,Float64} = Dict{Symbol,Float64}()
end

Base.@kwdef struct DARTNetwork
    bus_names::Vector{String}
    line_names::Vector{String} = String[]
    ptdf::Matrix{Float64} = zeros(0, length(bus_names))
    line_limit_mw::Vector{Float64} = Float64[]
    emergency_line_limit_mw::Vector{Float64} = copy(line_limit_mw)
end

Base.@kwdef struct DARTSystemData
    generators::Vector{DARTGenerator}
    network::DARTNetwork
    storage::Vector{DARTStorage} = DARTStorage[]
    reserve_products::Vector{DARTReserveProduct} = default_dart_reserve_products()
end

"""
Time-varying inputs for one optimization horizon.

Rows follow generators or buses; columns are chronological intervals.
Interchange is positive for an injection and negative for a withdrawal.
"""
Base.@kwdef struct DARTForecast
    interval_hours::Float64
    load_mw::Matrix{Float64}
    availability::Matrix{Float64}
    generator_in_service::Matrix{Bool} = trues(size(availability))
    interchange_mw::Matrix{Float64} = zeros(size(load_mw))
    reserve_requirement_mw::Dict{Symbol,Vector{Float64}} = Dict{Symbol,Vector{Float64}}()
    terminal_storage_soc_mwh::Union{Nothing,Vector{Float64}} = nothing
end

"""Physical state immediately before an optimization horizon."""
Base.@kwdef struct DARTState
    commitment::Vector{Int}
    generation_mw::Vector{Float64}
    on_duration_hours::Vector{Float64}
    off_duration_hours::Vector{Float64}
    storage_soc_mwh::Vector{Float64} = Float64[]
    generator_in_service::Vector{Bool} = trues(length(commitment))
end

Base.@kwdef struct DARTConfig
    value_of_lost_load_per_mwh::Float64 = 100_000.0
    emergency_load_shed_cost_per_mwh::Float64 = 50_000.0
    allow_emergency_contingency_shed::Bool = false
    apply_for_derating::Bool = true
    security_up_products::Vector{Symbol} = [:reg_up, :spin, :nspin]
    security_down_products::Vector{Symbol} = [:reg_down]
    accept_feasible_time_limit::Bool = true
    maximum_relative_gap::Float64 = 0.01
    maximum_security_variables::Int = 2_000_000
    silent::Bool = true
end

Base.@kwdef struct DARTDispatchResult
    stage::Symbol
    objective_value::Float64
    termination_status::MOI.TerminationStatusCode
    primal_status::MOI.ResultStatusCode
    solve_time_seconds::Float64
    relative_gap::Float64
    interval_hours::Float64
    load_mw::Matrix{Float64}
    interchange_mw::Matrix{Float64}
    generator_in_service::Matrix{Bool}
    generation_mw::Matrix{Float64}
    commitment::Matrix{Int}
    startup::Matrix{Int}
    shutdown::Matrix{Int}
    generator_reserve_mw::Dict{Symbol,Matrix{Float64}}
    storage_charge_mw::Matrix{Float64}
    storage_discharge_mw::Matrix{Float64}
    storage_soc_mwh::Matrix{Float64}
    storage_reserve_mw::Dict{Symbol,Matrix{Float64}}
    load_shed_mw::Matrix{Float64}
    line_flow_mw::Matrix{Float64}
    lmp_per_mwh::Matrix{Float64}
    reserve_requirement_shadow_price_per_mw_hour::Dict{Symbol,Vector{Float64}}
    emergency_load_shed_mw::Array{Float64,3}
    contingency_generator_indices::Vector{Int}
end

Base.@kwdef struct DARTRollingResult
    day_ahead_results::Vector{DARTDispatchResult}
    real_time_results::Vector{DARTDispatchResult}
    rt_to_da_index::Vector{Int}
    final_state::DARTState
end

Base.@kwdef struct DARTSettlementResult
    reserve_settlement_rule::Symbol
    generator_day_ahead_energy::Vector{Float64}
    generator_real_time_deviation::Vector{Float64}
    generator_reserve_credit::Vector{Float64}
    generator_uplift::Vector{Float64}
    storage_day_ahead_energy::Vector{Float64}
    storage_real_time_deviation::Vector{Float64}
    storage_reserve_credit::Vector{Float64}
    storage_uplift::Vector{Float64}
    load_energy_payment::Vector{Float64}
    load_reserve_charge::Vector{Float64}
    load_uplift_charge::Vector{Float64}
    unallocated_reserve_charge::Float64
    unallocated_uplift_charge::Float64
    interchange_credit::Vector{Float64}
    merchandising_surplus::Float64
    settlement_balance::Float64
end

function default_dart_reserve_products()
    return [
        DARTReserveProduct(name = :reg_up, direction = :up, response_minutes = 5),
        DARTReserveProduct(name = :reg_down, direction = :down, response_minutes = 5),
        DARTReserveProduct(name = :spin, direction = :up, response_minutes = 10),
        DARTReserveProduct(
            name = :nspin,
            direction = :up,
            response_minutes = 30,
            requires_online = false,
        ),
    ]
end

function default_dart_state(data::DARTSystemData)
    commitment = [generator.commitment_required ? 0 : 1 for generator in data.generators]
    return DARTState(
        commitment = commitment,
        generation_mw = zeros(length(data.generators)),
        on_duration_hours = [status == 1 ? Inf : 0.0 for status in commitment],
        off_duration_hours = [status == 0 ? Inf : 0.0 for status in commitment],
        storage_soc_mwh = [0.5 * resource.energy_capacity_mwh for resource in data.storage],
    )
end

# -----------------------------------------------------------------------------
# Validation and small helpers
# -----------------------------------------------------------------------------

function _bus_indices(data::DARTSystemData)
    index = Dict(name => n for (n, name) in pairs(data.network.bus_names))
    generator_bus = [index[generator.bus] for generator in data.generators]
    storage_bus = [index[resource.bus] for resource in data.storage]
    return generator_bus, storage_bus
end

_is_nonnegative_or_infinite(value) = !isnan(value) && value >= 0

function _validate_inputs(
    data::DARTSystemData,
    forecast::DARTForecast,
    state::DARTState,
    config::DARTConfig,
)
    G = length(data.generators)
    S = length(data.storage)
    N = length(data.network.bus_names)
    L = length(data.network.line_names)
    T = size(forecast.load_mw, 2)

    G > 0 || throw(ArgumentError("DART requires at least one generator."))
    N > 0 || throw(ArgumentError("DART requires at least one bus."))
    T > 0 || throw(ArgumentError("DART requires at least one interval."))
    length(unique(data.network.bus_names)) == N ||
        throw(ArgumentError("DART bus names must be unique."))
    length(unique(data.network.line_names)) == L ||
        throw(ArgumentError("DART line names must be unique."))
    length(unique(getfield.(data.generators, :name))) == G ||
        throw(ArgumentError("DART generator names must be unique."))
    length(unique(getfield.(data.storage, :name))) == S ||
        throw(ArgumentError("DART storage names must be unique."))
    all(generator.bus in data.network.bus_names for generator in data.generators) ||
        throw(ArgumentError("Every generator must reference a DART bus."))
    all(resource.bus in data.network.bus_names for resource in data.storage) ||
        throw(ArgumentError("Every storage resource must reference a DART bus."))
    size(forecast.load_mw) == (N, T) ||
        throw(ArgumentError("Load must be bus count by interval count."))
    size(forecast.interchange_mw) == (N, T) ||
        throw(ArgumentError("Interchange must be bus count by interval count."))
    size(forecast.availability) == (G, T) ||
        throw(ArgumentError("Availability must be generator count by interval count."))
    size(forecast.generator_in_service) == (G, T) ||
        throw(ArgumentError("Service status must be generator count by interval count."))
    size(data.network.ptdf) == (L, N) ||
        throw(ArgumentError("PTDF dimensions must be line count by bus count."))
    length(data.network.line_limit_mw) == L ||
        throw(ArgumentError("Every line requires a normal limit."))
    length(data.network.emergency_line_limit_mw) == L ||
        throw(ArgumentError("Every line requires an emergency limit."))
    all(isfinite, data.network.ptdf) || throw(ArgumentError("PTDF entries must be finite."))
    all(value -> isfinite(value) && value >= 0, data.network.line_limit_mw) ||
        throw(ArgumentError("Normal line limits must be finite and nonnegative."))
    all(value -> isfinite(value) && value >= 0, data.network.emergency_line_limit_mw) ||
        throw(ArgumentError("Emergency line limits must be finite and nonnegative."))
    all(data.network.emergency_line_limit_mw .>= data.network.line_limit_mw) ||
        throw(ArgumentError("Emergency line limits must be at least normal limits."))
    isfinite(forecast.interval_hours) && forecast.interval_hours > 0 ||
        throw(ArgumentError("Forecast interval length must be finite and positive."))
    all(isfinite, forecast.load_mw) || throw(ArgumentError("Load must be finite."))
    all(isfinite, forecast.interchange_mw) ||
        throw(ArgumentError("Interchange must be finite."))
    all(forecast.load_mw .>= 0) || throw(ArgumentError("Load cannot be negative."))
    all(value -> 0 <= value <= 1, forecast.availability) ||
        throw(ArgumentError("Availability must be between zero and one."))
    if forecast.terminal_storage_soc_mwh !== nothing
        target = forecast.terminal_storage_soc_mwh
        length(target) == S ||
            throw(ArgumentError("Terminal storage SOC must match the storage count."))
        all(
            isfinite(target[s]) && 0 <= target[s] <= data.storage[s].energy_capacity_mwh for
            s = 1:S
        ) || throw(ArgumentError("Terminal storage SOC is outside its energy bounds."))
    end

    product_names = getfield.(data.reserve_products, :name)
    length(unique(product_names)) == length(product_names) ||
        throw(ArgumentError("Reserve product names must be unique."))
    for product in data.reserve_products
        product.direction in (:up, :down) ||
            throw(ArgumentError("Reserve direction must be :up or :down."))
        product.response_minutes > 0 ||
            throw(ArgumentError("Reserve response time must be positive."))
        product.requires_online ||
            product.direction == :up ||
            throw(ArgumentError("Offline reserve must be an upward product."))
    end
    for (name, requirement) in forecast.reserve_requirement_mw
        name in product_names ||
            throw(ArgumentError("Unknown reserve requirement $(name)."))
        length(requirement) == T ||
            throw(ArgumentError("Reserve requirements must match the horizon."))
        all(value -> isfinite(value) && value >= 0, requirement) ||
            throw(ArgumentError("Reserve requirements must be finite and nonnegative."))
    end
    product_by_name = Dict(product.name => product for product in data.reserve_products)

    for generator in data.generators
        all(
            isfinite,
            (
                generator.pmax_mw,
                generator.pmin_mw,
                generator.variable_cost_per_mwh,
                generator.no_load_cost_per_hour,
                generator.startup_cost,
                generator.shutdown_cost,
                generator.startup_limit_mw,
                generator.shutdown_limit_mw,
                generator.forced_outage_rate,
            ),
        ) || throw(ArgumentError("Generator inputs must be finite for $(generator.name)."))
        0 <= generator.pmin_mw <= generator.pmax_mw ||
            throw(ArgumentError("Generator limits are invalid for $(generator.name)."))
        0 <= generator.forced_outage_rate < 1 ||
            throw(ArgumentError("FOR must be in [0, 1) for $(generator.name)."))
        generator.min_up_hours >= 0 && generator.min_down_hours >= 0 ||
            throw(ArgumentError("Minimum up/down times cannot be negative."))
        0 <= generator.startup_limit_mw <= generator.pmax_mw ||
            throw(ArgumentError("Startup limit is invalid for $(generator.name)."))
        0 <= generator.shutdown_limit_mw <= generator.pmax_mw ||
            throw(ArgumentError("Shutdown limit is invalid for $(generator.name)."))
        all(
            _is_nonnegative_or_infinite,
            (
                generator.ramp_up_mw_per_hour,
                generator.ramp_down_mw_per_hour,
                generator.real_time_ramp_up_mw_per_hour,
                generator.real_time_ramp_down_mw_per_hour,
            ),
        ) || throw(ArgumentError("Ramp limits are invalid for $(generator.name)."))
        generator.quick_start_time_minutes >= 0 || throw(
            ArgumentError("Quick-start time cannot be negative for $(generator.name)."),
        )
        all(name in product_names for name in keys(generator.reserve_capability_mw)) ||
            throw(ArgumentError("Generator reserve capability uses an unknown product."))
        all(name in product_names for name in keys(generator.reserve_cost_per_mw_hour)) ||
            throw(ArgumentError("Generator reserve cost uses an unknown product."))
        all(
            value -> isfinite(value) && 0 <= value <= generator.pmax_mw,
            values(generator.reserve_capability_mw),
        ) || throw(ArgumentError("Reserve capability is invalid for $(generator.name)."))
        all(isfinite, values(generator.reserve_cost_per_mw_hour)) ||
            throw(ArgumentError("Reserve costs must be finite for $(generator.name)."))
    end
    for resource in data.storage
        all(
            isfinite,
            (
                resource.energy_capacity_mwh,
                resource.charge_capacity_mw,
                resource.discharge_capacity_mw,
                resource.charge_efficiency,
                resource.discharge_efficiency,
                resource.variable_cost_per_mwh,
            ),
        ) || throw(ArgumentError("Storage inputs must be finite for $(resource.name)."))
        resource.energy_capacity_mwh >= 0 &&
            resource.charge_capacity_mw >= 0 &&
            resource.discharge_capacity_mw >= 0 ||
            throw(ArgumentError("Storage limits cannot be negative."))
        0 < resource.charge_efficiency <= 1 && 0 < resource.discharge_efficiency <= 1 ||
            throw(ArgumentError("Storage efficiencies must be in (0, 1]."))
        all(name in product_names for name in keys(resource.reserve_capability_mw)) ||
            throw(ArgumentError("Storage reserve capability uses an unknown product."))
        all(name in product_names for name in keys(resource.reserve_cost_per_mw_hour)) ||
            throw(ArgumentError("Storage reserve cost uses an unknown product."))
        for (name, capability) in resource.reserve_capability_mw
            limit =
                product_by_name[name].direction == :up ? resource.discharge_capacity_mw :
                resource.charge_capacity_mw
            isfinite(capability) && 0 <= capability <= limit ||
                throw(ArgumentError("Reserve capability is invalid for $(resource.name)."))
        end
        all(isfinite, values(resource.reserve_cost_per_mw_hour)) ||
            throw(ArgumentError("Reserve costs must be finite for $(resource.name)."))
    end

    length(state.commitment) == G &&
        length(state.generation_mw) == G &&
        length(state.on_duration_hours) == G &&
        length(state.off_duration_hours) == G &&
        length(state.generator_in_service) == G ||
        throw(ArgumentError("Generator state vectors have the wrong length."))
    length(state.storage_soc_mwh) == S ||
        throw(ArgumentError("Storage state vector has the wrong length."))
    all(status in (0, 1) for status in state.commitment) ||
        throw(ArgumentError("Commitment state must contain only zero or one."))
    all(
        isfinite(state.generation_mw[g]) &&
            -1e-8 <= state.generation_mw[g] <= data.generators[g].pmax_mw + 1e-8 for g = 1:G
    ) || throw(ArgumentError("Initial generation is outside its physical bounds."))
    all(_is_nonnegative_or_infinite, state.on_duration_hours) &&
        all(_is_nonnegative_or_infinite, state.off_duration_hours) ||
        throw(ArgumentError("Initial on/off durations must be nonnegative."))
    all(
        isfinite(state.storage_soc_mwh[s]) &&
            -1e-8 <= state.storage_soc_mwh[s] <= data.storage[s].energy_capacity_mwh + 1e-8
        for s = 1:S
    ) || throw(ArgumentError("Initial storage SOC is outside its energy bounds."))
    isfinite(config.value_of_lost_load_per_mwh) && config.value_of_lost_load_per_mwh > 0 ||
        throw(ArgumentError("Value of lost load must be finite and positive."))
    isfinite(config.emergency_load_shed_cost_per_mwh) &&
        config.emergency_load_shed_cost_per_mwh > 0 ||
        throw(ArgumentError("Emergency load-shed cost must be finite and positive."))
    length(unique(config.security_up_products)) == length(config.security_up_products) ||
        throw(ArgumentError("Security-up products cannot contain duplicates."))
    length(unique(config.security_down_products)) ==
    length(config.security_down_products) ||
        throw(ArgumentError("Security-down products cannot contain duplicates."))
    all(name in product_names for name in config.security_up_products) ||
        throw(ArgumentError("A security-up product is not defined."))
    all(name in product_names for name in config.security_down_products) ||
        throw(ArgumentError("A security-down product is not defined."))
    all(product_by_name[name].direction == :up for name in config.security_up_products) ||
        throw(ArgumentError("Security-up products must provide upward reserve."))
    all(
        product_by_name[name].direction == :down for name in config.security_down_products
    ) || throw(ArgumentError("Security-down products must provide downward reserve."))
    isfinite(config.maximum_relative_gap) && config.maximum_relative_gap >= 0 ||
        throw(ArgumentError("Maximum relative gap must be finite and nonnegative."))
    config.maximum_security_variables > 0 ||
        throw(ArgumentError("Maximum security variables must be positive."))
    return nothing
end

_for_factor(generator, config) =
    config.apply_for_derating ? 1.0 - generator.forced_outage_rate : 1.0

function _available_pmax(data, forecast, config, g, t)
    generator = data.generators[g]
    service = forecast.generator_in_service[g, t] ? 1.0 : 0.0
    return service *
           forecast.availability[g, t] *
           generator.pmax_mw *
           _for_factor(generator, config)
end

# A drop in available Pmax is forced output loss, not operator-controlled
# ramp-down. Preserve the configured ramp for any additional downward movement.

function _availability_ramp_down_allowance(data, forecast, state, config, g, t)
    current_pmax = _available_pmax(data, forecast, config, g, t)
    if t == 1
        return max(state.generation_mw[g] - current_pmax, 0.0)
    end
    previous_pmax = _available_pmax(data, forecast, config, g, t - 1)
    return max(previous_pmax - current_pmax, 0.0)
end

function _effective_commitment(forecast, commitment, g, t)
    return forecast.generator_in_service[g, t] ? commitment[g, t] : 0.0
end

function _new_model(optimizer, config)
    model = Model(optimizer)
    config.silent && set_silent(model)
    return model
end

function _model_relative_gap(model)
    try
        return relative_gap(model)
    catch
        return NaN
    end
end

function _model_solve_time(model)
    try
        return solve_time(model)
    catch
        return NaN
    end
end

function _require_solution(model, stage, config; require_optimal::Bool = false)
    termination = termination_status(model)
    primal = primal_status(model)
    gap = _model_relative_gap(model)
    termination == MOI.OPTIMAL && return nothing

    acceptable_time_limit =
        !require_optimal &&
        config.accept_feasible_time_limit &&
        termination == MOI.TIME_LIMIT &&
        primal == MOI.FEASIBLE_POINT &&
        isfinite(gap) &&
        gap <= config.maximum_relative_gap
    acceptable_time_limit && return nothing

    error(
        "DART $(stage) solve failed with termination status $(termination), " *
        "primal status $(primal), and relative gap $(gap).",
    )
end

function _has_discrete_variables(model)
    return any(
        variable -> is_binary(variable) || is_integer(variable),
        all_variables(model),
    )
end

function _security_variable_count(data, forecast)
    G = length(data.generators)
    N = length(data.network.bus_names)
    L = length(data.network.line_names)
    T = size(forecast.load_mw, 2)
    C = count(generator.contingency_eligible for generator in data.generators)
    return Int128(2G + 2N + L) * T * C + T
end

function _check_security_model_size(data, forecast, config)
    count = _security_variable_count(data, forecast)
    count <= config.maximum_security_variables || throw(
        ArgumentError(
            "Generator N-1 security would create approximately $(count) scenario " *
            "variables, above maximum_security_variables=$(config.maximum_security_variables). " *
            "Reduce the horizon or contingency set, or explicitly raise the safeguard.",
        ),
    )
    return nothing
end

# -----------------------------------------------------------------------------
# Equations shared by SCUC and SCED
# -----------------------------------------------------------------------------

function _add_dispatch!(
    model,
    data,
    forecast,
    state,
    commitment,
    config;
    real_time::Bool = false,
)
    G = length(data.generators)
    S = length(data.storage)
    N = length(data.network.bus_names)
    L = length(data.network.line_names)
    K = length(data.reserve_products)
    T = size(forecast.load_mw, 2)
    dt = forecast.interval_hours
    generator_bus, storage_bus = _bus_indices(data)

    @variable(model, generation[1:G, 1:T] >= 0)
    @variable(model, generator_reserve[1:G, 1:T, 1:K] >= 0)
    @variable(model, storage_charge[1:S, 1:T] >= 0)
    @variable(model, storage_discharge[1:S, 1:T] >= 0)
    @variable(model, storage_soc[1:S, 1:T] >= 0)
    @variable(model, storage_reserve[1:S, 1:T, 1:K] >= 0)
    if S > 0
        @variable(model, storage_charging_mode[1:S, 1:T], Bin)
    end
    @variable(model, load_shed[1:N, 1:T] >= 0)
    @variable(model, injection[1:N, 1:T])
    @variable(model, line_flow[1:L, 1:T])

    online_up = [
        k for k = 1:K if data.reserve_products[k].direction == :up &&
        data.reserve_products[k].requires_online
    ]
    online_down = [
        k for k = 1:K if data.reserve_products[k].direction == :down &&
        data.reserve_products[k].requires_online
    ]
    offline_up = [
        k for k = 1:K if data.reserve_products[k].direction == :up &&
        !data.reserve_products[k].requires_online
    ]
    all_up = [k for k = 1:K if data.reserve_products[k].direction == :up]
    all_down = [k for k = 1:K if data.reserve_products[k].direction == :down]

    # GEN-1 through GEN-5 and RES-1, RES-2, RES-5.
    for g = 1:G, t = 1:T
        generator = data.generators[g]
        effective_commitment = _effective_commitment(forecast, commitment, g, t)
        pmax = _available_pmax(data, forecast, config, g, t)
        pmin =
            generator.commitment_required ?
            generator.pmin_mw * _for_factor(generator, config) * effective_commitment : 0.0
        ramp_up =
            real_time ? generator.real_time_ramp_up_mw_per_hour :
            generator.ramp_up_mw_per_hour
        ramp_down =
            real_time ? generator.real_time_ramp_down_mw_per_hour :
            generator.ramp_down_mw_per_hour

        @constraint(
            model,
            generation[g, t] +
            sum((generator_reserve[g, t, k] for k in online_up); init = 0.0) <=
            pmax * commitment[g, t]
        )
        @constraint(
            model,
            generation[g, t] -
            sum((generator_reserve[g, t, k] for k in online_down); init = 0.0) >= pmin
        )

        for k = 1:K
            product = data.reserve_products[k]
            reserve = generator_reserve[g, t, k]
            capability = get(generator.reserve_capability_mw, product.name, 0.0)
            if capability == 0
                fix(reserve, 0.0; force = true)
            elseif product.requires_online
                @constraint(model, reserve <= capability * effective_commitment)
                response_hours = product.response_minutes / 60
                if product.direction == :up && isfinite(ramp_up)
                    @constraint(
                        model,
                        reserve <=
                        ramp_up *
                        response_hours *
                        _for_factor(generator, config) *
                        effective_commitment
                    )
                elseif product.direction == :down && isfinite(ramp_down)
                    @constraint(
                        model,
                        reserve <=
                        ramp_down *
                        response_hours *
                        _for_factor(generator, config) *
                        effective_commitment
                    )
                end
            elseif generator.quick_start_eligible &&
                   product.direction == :up &&
                   generator.quick_start_time_minutes <= product.response_minutes
                available_quick_start =
                    min(capability, _available_pmax(data, forecast, config, g, t))
                @constraint(
                    model,
                    reserve <= available_quick_start * (1 - commitment[g, t])
                )
            else
                fix(reserve, 0.0; force = true)
            end
        end
        @constraint(
            model,
            sum((generator_reserve[g, t, k] for k in offline_up); init = 0.0) <=
            pmax * (1 - commitment[g, t])
        )
    end

    # STO-1 through STO-6. The mode binary prevents simultaneous operation.
    for s = 1:S, t = 1:T
        resource = data.storage[s]
        @constraint(
            model,
            storage_charge[s, t] <=
            resource.charge_capacity_mw * storage_charging_mode[s, t]
        )
        @constraint(
            model,
            storage_discharge[s, t] <=
            resource.discharge_capacity_mw * (1 - storage_charging_mode[s, t])
        )
        @constraint(model, storage_soc[s, t] <= resource.energy_capacity_mwh)
        previous_soc = t == 1 ? state.storage_soc_mwh[s] : storage_soc[s, t-1]
        @constraint(
            model,
            storage_soc[s, t] ==
            previous_soc + dt * resource.charge_efficiency * storage_charge[s, t] -
            dt / resource.discharge_efficiency * storage_discharge[s, t]
        )
        @constraint(
            model,
            storage_discharge[s, t] +
            sum((storage_reserve[s, t, k] for k in all_up); init = 0.0) <=
            resource.discharge_capacity_mw
        )
        @constraint(
            model,
            storage_charge[s, t] +
            sum((storage_reserve[s, t, k] for k in all_down); init = 0.0) <=
            resource.charge_capacity_mw
        )
        for k = 1:K
            capability =
                get(resource.reserve_capability_mw, data.reserve_products[k].name, 0.0)
            if capability == 0
                fix(storage_reserve[s, t, k], 0.0; force = true)
            else
                @constraint(model, storage_reserve[s, t, k] <= capability)
            end
        end
        @constraint(
            model,
            sum(
                (
                    data.reserve_products[k].response_minutes / 60 *
                    storage_reserve[s, t, k] for k in all_up
                );
                init = 0.0,
            ) <= previous_soc
        )
        @constraint(
            model,
            sum(
                (
                    data.reserve_products[k].response_minutes / 60 *
                    storage_reserve[s, t, k] for k in all_down
                );
                init = 0.0,
            ) <= resource.energy_capacity_mwh - previous_soc
        )
    end
    if forecast.terminal_storage_soc_mwh !== nothing
        @constraint(
            model,
            storage_terminal_soc[s = 1:S],
            storage_soc[s, T] == forecast.terminal_storage_soc_mwh[s]
        )
    end

    # NET-1 through NET-4.
    generators_at_bus = [[g for g = 1:G if generator_bus[g] == n] for n = 1:N]
    storage_at_bus = [[s for s = 1:S if storage_bus[s] == n] for n = 1:N]
    @constraint(
        model,
        load_shed_limit[n = 1:N, t = 1:T],
        load_shed[n, t] <= forecast.load_mw[n, t]
    )
    @constraint(
        model,
        injection_definition[n = 1:N, t = 1:T],
        injection[n, t] ==
        sum((generation[g, t] for g in generators_at_bus[n]); init = 0.0) +
        sum(
            (storage_discharge[s, t] - storage_charge[s, t] for s in storage_at_bus[n]);
            init = 0.0,
        ) +
        forecast.interchange_mw[n, t] - forecast.load_mw[n, t] + load_shed[n, t]
    )
    @constraint(model, system_balance[t = 1:T], sum(injection[n, t] for n = 1:N) == 0)
    @constraint(
        model,
        ptdf_flow[l = 1:L, t = 1:T],
        line_flow[l, t] == sum(data.network.ptdf[l, n] * injection[n, t] for n = 1:N)
    )
    @constraint(
        model,
        line_upper[l = 1:L, t = 1:T],
        line_flow[l, t] <= data.network.line_limit_mw[l]
    )
    @constraint(
        model,
        line_lower[l = 1:L, t = 1:T],
        line_flow[l, t] >= -data.network.line_limit_mw[l]
    )

    # RES-3 and RES-4.
    @constraint(
        model,
        reserve_requirement[k = 1:K, t = 1:T],
        sum(generator_reserve[g, t, k] for g = 1:G) +
        sum((storage_reserve[s, t, k] for s = 1:S); init = 0.0) >=
        get(forecast.reserve_requirement_mw, data.reserve_products[k].name, zeros(T))[t]
    )

    @expression(
        model,
        dispatch_cost,
        dt * sum(
            data.generators[g].variable_cost_per_mwh * generation[g, t] for g = 1:G, t = 1:T
        ) +
        dt * sum(
            get(
                data.generators[g].reserve_cost_per_mw_hour,
                data.reserve_products[k].name,
                0.0,
            ) * generator_reserve[g, t, k] for g = 1:G, t = 1:T, k = 1:K
        ) +
        dt * sum(
            data.storage[s].variable_cost_per_mwh *
            (storage_charge[s, t] + storage_discharge[s, t]) for s = 1:S, t = 1:T
        ) +
        dt * sum(
            get(
                data.storage[s].reserve_cost_per_mw_hour,
                data.reserve_products[k].name,
                0.0,
            ) * storage_reserve[s, t, k] for s = 1:S, t = 1:T, k = 1:K
        ) +
        dt * config.value_of_lost_load_per_mwh * sum(load_shed[n, t] for n = 1:N, t = 1:T)
    )
    return nothing
end

# SEC-1 through SEC-5: one scenario for each eligible generator.
function _add_generator_security!(model, data, forecast, commitment, config)
    G = length(data.generators)
    N = length(data.network.bus_names)
    L = length(data.network.line_names)
    T = size(forecast.load_mw, 2)
    products = Dict(product.name => k for (k, product) in pairs(data.reserve_products))
    up_products = [products[name] for name in config.security_up_products]
    down_products = [products[name] for name in config.security_down_products]
    offline_up = [k for k in up_products if !data.reserve_products[k].requires_online]
    contingencies = findall(generator.contingency_eligible for generator in data.generators)
    C = length(contingencies)
    model[:contingency_generator_indices] = contingencies
    C == 0 && return @expression(model, emergency_cost, 0.0)
    _check_security_model_size(data, forecast, config)

    generator_bus, _ = _bus_indices(data)
    generation = model[:generation]
    reserve = model[:generator_reserve]
    base_injection = model[:injection]
    base_shed = model[:load_shed]

    @variable(model, contingency_up[1:G, 1:T, 1:C] >= 0)
    @variable(model, contingency_down[1:G, 1:T, 1:C] >= 0)
    @variable(model, emergency_load_shed[1:N, 1:T, 1:C] >= 0)
    @variable(model, contingency_injection[1:N, 1:T, 1:C])
    @variable(model, contingency_line_flow[1:L, 1:T, 1:C])
    @variable(model, worst_contingency_shed[1:T] >= 0)

    if !config.allow_emergency_contingency_shed
        for emergency_shed in emergency_load_shed
            fix(emergency_shed, 0.0; force = true)
        end
    end

    for c = 1:C
        failed = contingencies[c]
        for t = 1:T
            for g = 1:G
                if g == failed
                    fix(contingency_up[g, t, c], 0.0; force = true)
                    fix(contingency_down[g, t, c], 0.0; force = true)
                else
                    @constraint(
                        model,
                        contingency_up[g, t, c] <=
                        sum((reserve[g, t, k] for k in up_products); init = 0.0)
                    )
                    @constraint(
                        model,
                        contingency_down[g, t, c] <=
                        sum((reserve[g, t, k] for k in down_products); init = 0.0)
                    )
                    effective_commitment = _effective_commitment(forecast, commitment, g, t)
                    quick_start_reserve =
                        sum((reserve[g, t, k] for k in offline_up); init = 0.0)
                    @constraint(
                        model,
                        generation[g, t] + contingency_up[g, t, c] -
                        contingency_down[g, t, c] <=
                        _available_pmax(data, forecast, config, g, t) *
                        effective_commitment + quick_start_reserve
                    )
                    generator = data.generators[g]
                    pmin =
                        generator.commitment_required ?
                        generator.pmin_mw *
                        _for_factor(generator, config) *
                        effective_commitment : 0.0
                    @constraint(
                        model,
                        generation[g, t] + contingency_up[g, t, c] -
                        contingency_down[g, t, c] >= pmin
                    )
                end
            end

            for n = 1:N
                @constraint(
                    model,
                    emergency_load_shed[n, t, c] <=
                    forecast.load_mw[n, t] - base_shed[n, t]
                )
                failed_output = generator_bus[failed] == n ? generation[failed, t] : 0.0
                response = sum(
                    (
                        contingency_up[g, t, c] - contingency_down[g, t, c] for
                        g = 1:G if generator_bus[g] == n
                    );
                    init = 0.0,
                )
                @constraint(
                    model,
                    contingency_injection[n, t, c] ==
                    base_injection[n, t] - failed_output +
                    response +
                    emergency_load_shed[n, t, c]
                )
            end
            @constraint(model, sum(contingency_injection[n, t, c] for n = 1:N) == 0)
            @constraint(
                model,
                worst_contingency_shed[t] >= sum(emergency_load_shed[n, t, c] for n = 1:N)
            )
            for l = 1:L
                @constraint(
                    model,
                    contingency_line_flow[l, t, c] == sum(
                        data.network.ptdf[l, n] * contingency_injection[n, t, c] for n = 1:N
                    )
                )
                @constraint(
                    model,
                    -data.network.emergency_line_limit_mw[l] <=
                    contingency_line_flow[l, t, c] <=
                    data.network.emergency_line_limit_mw[l]
                )
            end
        end
    end

    return @expression(
        model,
        emergency_cost,
        forecast.interval_hours *
        config.emergency_load_shed_cost_per_mwh *
        sum(worst_contingency_shed[t] for t = 1:T)
    )
end

# -----------------------------------------------------------------------------
# Day-ahead SCUC and real-time SCED
# -----------------------------------------------------------------------------

function build_dart_scuc_model(
    data::DARTSystemData,
    forecast::DARTForecast,
    state::DARTState;
    config::DARTConfig = DARTConfig(),
    optimizer = HiGHS.Optimizer,
)
    _validate_inputs(data, forecast, state, config)
    isapprox(forecast.interval_hours, 1.0; atol = 1e-9) ||
        throw(ArgumentError("Day-ahead SCUC requires hourly intervals."))
    G = length(data.generators)
    T = size(forecast.load_mw, 2)
    dt = forecast.interval_hours
    model = _new_model(optimizer, config)

    @variable(model, commitment[1:G, 1:T], Bin)
    @variable(model, startup[1:G, 1:T], Bin)
    @variable(model, shutdown[1:G, 1:T], Bin)

    for g = 1:G
        generator = data.generators[g]
        if !generator.commitment_required
            for t = 1:T
                fix(commitment[g, t], 1.0; force = true)
                fix(startup[g, t], 0.0; force = true)
                fix(shutdown[g, t], 0.0; force = true)
            end
            continue
        end
        for t = 1:T
            previous = t == 1 ? state.commitment[g] : commitment[g, t-1]
            @constraint(
                model,
                commitment[g, t] - previous == startup[g, t] - shutdown[g, t]
            )
            @constraint(model, startup[g, t] + shutdown[g, t] <= 1)

            first_up = max(1, t - ceil(Int, generator.min_up_hours / dt) + 1)
            first_down = max(1, t - ceil(Int, generator.min_down_hours / dt) + 1)
            @constraint(
                model,
                sum(startup[g, tau] for tau = first_up:t) <= commitment[g, t]
            )
            @constraint(
                model,
                sum(shutdown[g, tau] for tau = first_down:t) <= 1 - commitment[g, t]
            )
        end

        remaining_up =
            state.commitment[g] == 1 ?
            max(generator.min_up_hours - state.on_duration_hours[g], 0.0) : 0.0
        remaining_down =
            state.commitment[g] == 0 ?
            max(generator.min_down_hours - state.off_duration_hours[g], 0.0) : 0.0
        for t = 1:min(T, ceil(Int, remaining_up / dt - 1e-9))
            fix(commitment[g, t], 1.0; force = true)
        end
        for t = 1:min(T, ceil(Int, remaining_down / dt - 1e-9))
            fix(commitment[g, t], 0.0; force = true)
        end
    end

    _add_dispatch!(model, data, forecast, state, commitment, config)
    generation = model[:generation]
    reserve = model[:generator_reserve]
    online_up = [
        k for k in eachindex(data.reserve_products) if
        data.reserve_products[k].requires_online &&
        data.reserve_products[k].direction == :up
    ]
    online_down = [
        k for k in eachindex(data.reserve_products) if
        data.reserve_products[k].requires_online &&
        data.reserve_products[k].direction == :down
    ]

    # GEN-6/7 and RAMP-1/2.
    for g = 1:G, t = 1:T
        generator = data.generators[g]
        previous_generation = t == 1 ? state.generation_mw[g] : generation[g, t-1]
        previous_commitment = t == 1 ? state.commitment[g] : commitment[g, t-1]
        previous_service =
            t == 1 ? state.generator_in_service[g] : forecast.generator_in_service[g, t-1]
        current_service = forecast.generator_in_service[g, t]
        previous_effective_commitment = previous_service ? previous_commitment : 0.0
        current_effective_commitment = current_service ? commitment[g, t] : 0.0
        physical_startup =
            current_service && !previous_service ? commitment[g, t] : startup[g, t]

        @constraint(
            model,
            generation[g, t] <=
            generator.startup_limit_mw * physical_startup +
            _available_pmax(data, forecast, config, g, t) *
            (current_effective_commitment - physical_startup)
        )
        if t < T
            @constraint(
                model,
                generation[g, t] <=
                generator.shutdown_limit_mw * shutdown[g, t+1] +
                _available_pmax(data, forecast, config, g, t) *
                (current_effective_commitment - shutdown[g, t+1])
            )
        end

        upward_reserve = sum((reserve[g, t, k] for k in online_up); init = 0.0)
        downward_reserve = sum((reserve[g, t, k] for k in online_down); init = 0.0)
        if isfinite(generator.ramp_up_mw_per_hour)
            @constraint(
                model,
                generation[g, t] + upward_reserve - previous_generation <=
                generator.ramp_up_mw_per_hour *
                _for_factor(generator, config) *
                dt *
                previous_effective_commitment +
                generator.startup_limit_mw * physical_startup
            )
        end
        observed_trip = previous_service && !current_service
        if isfinite(generator.ramp_down_mw_per_hour) && !observed_trip
            availability_drop =
                _availability_ramp_down_allowance(data, forecast, state, config, g, t)
            @constraint(
                model,
                previous_generation - generation[g, t] + downward_reserve <=
                generator.ramp_down_mw_per_hour *
                _for_factor(generator, config) *
                dt *
                current_effective_commitment +
                generator.shutdown_limit_mw * shutdown[g, t] +
                availability_drop
            )
        end
    end

    # An offline quick-start unit must first complete its minimum-down obligation.
    for g = 1:G
        generator = data.generators[g]
        minimum_down_intervals = ceil(Int, generator.min_down_hours / dt - 1e-9)
        remaining_down =
            state.commitment[g] == 0 ?
            ceil(
                Int,
                max(generator.min_down_hours - state.off_duration_hours[g], 0.0) / dt -
                1e-9,
            ) : 0
        for (k, product) in pairs(data.reserve_products)
            product.requires_online && continue
            for t = 1:min(T, remaining_down)
                fix(reserve[g, t, k], 0.0; force = true)
            end
            capability = get(generator.reserve_capability_mw, product.name, 0.0)
            capability == 0 && continue
            for t = 1:T
                first_shutdown = max(1, t - minimum_down_intervals + 1)
                @constraint(
                    model,
                    reserve[g, t, k] <=
                    capability * (1 - sum(shutdown[g, tau] for tau = first_shutdown:t))
                )
            end
        end
    end

    emergency_cost = _add_generator_security!(model, data, forecast, commitment, config)
    @expression(
        model,
        commitment_cost,
        dt * sum(
            data.generators[g].no_load_cost_per_hour * commitment[g, t] for g = 1:G, t = 1:T
        ) + sum(
            data.generators[g].startup_cost * startup[g, t] +
            data.generators[g].shutdown_cost * shutdown[g, t] for g = 1:G, t = 1:T
        )
    )
    @objective(model, Min, model[:dispatch_cost] + commitment_cost + emergency_cost)
    return model
end

function _commitment_matrix(data, commitment, T)
    G = length(data.generators)
    matrix =
        commitment isa AbstractVector ? repeat(reshape(Int.(commitment), G, 1), 1, T) :
        Int.(commitment)
    size(matrix) == (G, T) ||
        throw(ArgumentError("Fixed commitment has the wrong dimensions."))
    all(status in (0, 1) for status in matrix) ||
        throw(ArgumentError("Fixed commitment must contain only zero or one."))
    for g = 1:G
        if !data.generators[g].commitment_required
            matrix[g, :] .= 1
        end
    end
    return matrix
end

function build_dart_sced_model(
    data::DARTSystemData,
    forecast::DARTForecast,
    state::DARTState,
    fixed_commitment;
    config::DARTConfig = DARTConfig(),
    optimizer = HiGHS.Optimizer,
)
    _validate_inputs(data, forecast, state, config)
    G = length(data.generators)
    T = size(forecast.load_mw, 2)
    dt = forecast.interval_hours
    commitment_values = _commitment_matrix(data, fixed_commitment, T)
    model = _new_model(optimizer, config)
    @variable(model, 0 <= commitment[1:G, 1:T] <= 1)
    for g = 1:G, t = 1:T
        fix(commitment[g, t], commitment_values[g, t]; force = true)
    end

    _add_dispatch!(model, data, forecast, state, commitment, config; real_time = true)
    generation = model[:generation]
    reserve = model[:generator_reserve]

    # RT-3: ordinary intervals use energy-only RT ramp limits. Commitment and
    # equipment-status transitions use their physical boundary limits.
    for g = 1:G, t = 1:T
        generator = data.generators[g]
        previous_generation = t == 1 ? state.generation_mw[g] : generation[g, t-1]
        previous_commitment =
            generator.commitment_required ?
            (t == 1 ? state.commitment[g] : commitment_values[g, t-1]) : 1
        current_commitment = commitment_values[g, t]
        previous_service =
            t == 1 ? state.generator_in_service[g] : forecast.generator_in_service[g, t-1]
        current_service = forecast.generator_in_service[g, t]
        startup = current_commitment > previous_commitment
        shutdown = current_commitment < previous_commitment
        return_to_service = current_service && !previous_service
        observed_trip = previous_service && !current_service

        if startup || return_to_service
            @constraint(
                model,
                generation[g, t] - previous_generation <= generator.startup_limit_mw
            )
        elseif isfinite(generator.real_time_ramp_up_mw_per_hour)
            @constraint(
                model,
                generation[g, t] - previous_generation <=
                generator.real_time_ramp_up_mw_per_hour * dt
            )
        end
        if !observed_trip
            if shutdown
                @constraint(
                    model,
                    previous_generation - generation[g, t] <= generator.shutdown_limit_mw
                )
            elseif isfinite(generator.real_time_ramp_down_mw_per_hour)
                availability_drop =
                    _availability_ramp_down_allowance(data, forecast, state, config, g, t)
                @constraint(
                    model,
                    previous_generation - generation[g, t] <=
                    generator.real_time_ramp_down_mw_per_hour * dt + availability_drop
                )
            end
        end
    end

    # Offline reserve remains unavailable until minimum down time is complete.
    for g = 1:G
        generator = data.generators[g]
        off_hours = state.off_duration_hours[g]
        previous_commitment = state.commitment[g]
        for t = 1:T
            if commitment_values[g, t] == 0 && off_hours + 1e-9 < generator.min_down_hours
                for (k, product) in pairs(data.reserve_products)
                    product.requires_online || fix(reserve[g, t, k], 0.0; force = true)
                end
            end
            off_hours =
                commitment_values[g, t] == 0 ?
                (previous_commitment == 0 ? off_hours + dt : dt) : 0.0
            previous_commitment = commitment_values[g, t]
        end
    end

    emergency_cost = _add_generator_security!(model, data, forecast, commitment, config)
    @objective(model, Min, model[:dispatch_cost] + emergency_cost)
    return model
end

# -----------------------------------------------------------------------------
# Solving and prices
# -----------------------------------------------------------------------------

function _fix_discrete_decisions!(pricing_model, award_model)
    for award_variable in all_variables(award_model)
        (is_binary(award_variable) || is_integer(award_variable)) || continue
        pricing_variable = variable_by_name(pricing_model, name(award_variable))
        pricing_variable === nothing &&
            error("Pricing model is missing $(name(award_variable)).")
        is_binary(pricing_variable) && unset_binary(pricing_variable)
        is_integer(pricing_variable) && unset_integer(pricing_variable)
        fix(pricing_variable, round(value(award_variable)); force = true)
    end
    return nothing
end

function _result(award_model, pricing_model, data, forecast, stage)
    G = length(data.generators)
    S = length(data.storage)
    N = length(data.network.bus_names)
    T = size(forecast.load_mw, 2)
    K = length(data.reserve_products)
    dt = forecast.interval_hours
    generator_reserve = Array(value.(award_model[:generator_reserve]))
    storage_reserve = Array(value.(award_model[:storage_reserve]))
    contingencies =
        get(object_dictionary(award_model), :contingency_generator_indices, Int[])
    emergency =
        isempty(contingencies) ? zeros(N, T, 0) :
        Array(value.(award_model[:emergency_load_shed]))

    return DARTDispatchResult(
        stage = stage,
        objective_value = objective_value(award_model),
        termination_status = termination_status(award_model),
        primal_status = primal_status(award_model),
        solve_time_seconds = _model_solve_time(award_model),
        relative_gap = _model_relative_gap(award_model),
        interval_hours = dt,
        load_mw = copy(forecast.load_mw),
        interchange_mw = copy(forecast.interchange_mw),
        generator_in_service = copy(forecast.generator_in_service),
        generation_mw = Array(value.(award_model[:generation])),
        commitment = round.(Int, Array(value.(award_model[:commitment]))),
        startup = haskey(object_dictionary(award_model), :startup) ?
                  round.(Int, Array(value.(award_model[:startup]))) : zeros(Int, G, T),
        shutdown = haskey(object_dictionary(award_model), :shutdown) ?
                   round.(Int, Array(value.(award_model[:shutdown]))) : zeros(Int, G, T),
        generator_reserve_mw = Dict(
            data.reserve_products[k].name => generator_reserve[:, :, k] for k = 1:K
        ),
        storage_charge_mw = Array(value.(award_model[:storage_charge])),
        storage_discharge_mw = Array(value.(award_model[:storage_discharge])),
        storage_soc_mwh = Array(value.(award_model[:storage_soc])),
        storage_reserve_mw = Dict(
            data.reserve_products[k].name => storage_reserve[:, :, k] for k = 1:K
        ),
        load_shed_mw = Array(value.(award_model[:load_shed])),
        line_flow_mw = Array(value.(award_model[:line_flow])),
        lmp_per_mwh = [
            -dual(pricing_model[:injection_definition][n, t]) / dt for n = 1:N, t = 1:T
        ],
        reserve_requirement_shadow_price_per_mw_hour = Dict(
            data.reserve_products[k].name =>
                [dual(pricing_model[:reserve_requirement][k, t]) / dt for t = 1:T] for
            k = 1:K
        ),
        emergency_load_shed_mw = emergency,
        contingency_generator_indices = contingencies,
    )
end

function solve_dart_scuc(
    data::DARTSystemData,
    forecast::DARTForecast,
    state::DARTState;
    config::DARTConfig = DARTConfig(),
    optimizer = HiGHS.Optimizer,
)
    award =
        build_dart_scuc_model(data, forecast, state; config = config, optimizer = optimizer)
    optimize!(award)
    _require_solution(award, :day_ahead, config)

    pricing =
        build_dart_scuc_model(data, forecast, state; config = config, optimizer = optimizer)
    _fix_discrete_decisions!(pricing, award)
    optimize!(pricing)
    _require_solution(pricing, :day_ahead_pricing, config; require_optimal = true)
    return _result(award, pricing, data, forecast, :day_ahead)
end

function solve_dart_sced(
    data::DARTSystemData,
    forecast::DARTForecast,
    state::DARTState,
    fixed_commitment;
    config::DARTConfig = DARTConfig(),
    optimizer = HiGHS.Optimizer,
)
    award = build_dart_sced_model(
        data,
        forecast,
        state,
        fixed_commitment;
        config = config,
        optimizer = optimizer,
    )
    optimize!(award)
    _require_solution(award, :real_time, config)

    pricing = award
    if _has_discrete_variables(award)
        pricing = build_dart_sced_model(
            data,
            forecast,
            state,
            fixed_commitment;
            config = config,
            optimizer = optimizer,
        )
        _fix_discrete_decisions!(pricing, award)
        optimize!(pricing)
        _require_solution(pricing, :real_time_pricing, config; require_optimal = true)
    end
    return _result(award, pricing, data, forecast, :real_time)
end

# -----------------------------------------------------------------------------
# Rolling DA/RT simulation
# -----------------------------------------------------------------------------

function _slice_forecast(forecast::DARTForecast, first_interval, last_interval)
    columns = first_interval:last_interval
    return DARTForecast(
        interval_hours = forecast.interval_hours,
        load_mw = forecast.load_mw[:, columns],
        availability = forecast.availability[:, columns],
        generator_in_service = forecast.generator_in_service[:, columns],
        interchange_mw = forecast.interchange_mw[:, columns],
        reserve_requirement_mw = Dict(
            name => requirement[columns] for
            (name, requirement) in forecast.reserve_requirement_mw
        ),
        terminal_storage_soc_mwh = last_interval == size(forecast.load_mw, 2) ?
                                   forecast.terminal_storage_soc_mwh : nothing,
    )
end

function _binding_result(result::DARTDispatchResult)
    return DARTDispatchResult(
        stage = result.stage,
        objective_value = result.objective_value,
        termination_status = result.termination_status,
        primal_status = result.primal_status,
        solve_time_seconds = result.solve_time_seconds,
        relative_gap = result.relative_gap,
        interval_hours = result.interval_hours,
        load_mw = result.load_mw[:, 1:1],
        interchange_mw = result.interchange_mw[:, 1:1],
        generator_in_service = result.generator_in_service[:, 1:1],
        generation_mw = result.generation_mw[:, 1:1],
        commitment = result.commitment[:, 1:1],
        startup = result.startup[:, 1:1],
        shutdown = result.shutdown[:, 1:1],
        generator_reserve_mw = Dict(
            name => values[:, 1:1] for (name, values) in result.generator_reserve_mw
        ),
        storage_charge_mw = result.storage_charge_mw[:, 1:1],
        storage_discharge_mw = result.storage_discharge_mw[:, 1:1],
        storage_soc_mwh = result.storage_soc_mwh[:, 1:1],
        storage_reserve_mw = Dict(
            name => values[:, 1:1] for (name, values) in result.storage_reserve_mw
        ),
        load_shed_mw = result.load_shed_mw[:, 1:1],
        line_flow_mw = result.line_flow_mw[:, 1:1],
        lmp_per_mwh = result.lmp_per_mwh[:, 1:1],
        reserve_requirement_shadow_price_per_mw_hour = Dict(
            name => values[1:1] for
            (name, values) in result.reserve_requirement_shadow_price_per_mw_hour
        ),
        emergency_load_shed_mw = result.emergency_load_shed_mw[:, 1:1, :],
        contingency_generator_indices = result.contingency_generator_indices,
    )
end

function advance_dart_state(data, state, result::DARTDispatchResult)
    dt = result.interval_hours
    commitment = vec(result.commitment[:, 1])
    on_hours = copy(state.on_duration_hours)
    off_hours = copy(state.off_duration_hours)
    for g in eachindex(commitment)
        if commitment[g] == 1
            on_hours[g] = state.commitment[g] == 1 ? on_hours[g] + dt : dt
            off_hours[g] = 0.0
        else
            off_hours[g] = state.commitment[g] == 0 ? off_hours[g] + dt : dt
            on_hours[g] = 0.0
        end
    end

    generation = max.(vec(result.generation_mw[:, 1]), 0.0)
    storage_soc = vec(result.storage_soc_mwh[:, 1])
    for s in eachindex(data.storage)
        storage_soc[s] = clamp(storage_soc[s], 0.0, data.storage[s].energy_capacity_mwh)
    end
    return DARTState(
        commitment = commitment,
        generation_mw = generation,
        on_duration_hours = on_hours,
        off_duration_hours = off_hours,
        storage_soc_mwh = storage_soc,
        generator_in_service = vec(result.generator_in_service[:, 1]),
    )
end

"""
Run hourly DA SCUC and rolling RT SCED from in-memory forecasts.

`day_ahead_forecast` must be hourly. `real_time_forecast` is normally
five-minute data. One DA hour and one RT interval bind at each step.
"""
function run_dart_rolling(
    data::DARTSystemData,
    day_ahead_forecast::DARTForecast,
    real_time_forecast::DARTForecast,
    initial_state::DARTState = default_dart_state(data);
    hours_to_run::Int = min(
        size(day_ahead_forecast.load_mw, 2),
        floor(
            Int,
            size(real_time_forecast.load_mw, 2) * real_time_forecast.interval_hours + 1e-9,
        ),
    ),
    day_ahead_lookahead_hours::Int = 24,
    real_time_lookahead_intervals::Int = 12,
    config::DARTConfig = DARTConfig(),
    optimizer = HiGHS.Optimizer,
)
    isfinite(day_ahead_forecast.interval_hours) &&
        isapprox(day_ahead_forecast.interval_hours, 1.0; atol = 1e-9) ||
        throw(ArgumentError("Day-ahead rolling input must be hourly."))
    isfinite(real_time_forecast.interval_hours) && real_time_forecast.interval_hours > 0 ||
        throw(ArgumentError("RT interval length must be finite and positive."))
    intervals_per_hour = round(Int, 1 / real_time_forecast.interval_hours)
    isapprox(intervals_per_hour * real_time_forecast.interval_hours, 1.0; atol = 1e-9) ||
        throw(ArgumentError("RT interval length must divide one hour."))
    hours_to_run > 0 || throw(ArgumentError("hours_to_run must be positive."))
    day_ahead_lookahead_hours > 0 ||
        throw(ArgumentError("day_ahead_lookahead_hours must be positive."))
    real_time_lookahead_intervals > 0 ||
        throw(ArgumentError("real_time_lookahead_intervals must be positive."))
    hours_to_run <= size(day_ahead_forecast.load_mw, 2) ||
        throw(ArgumentError("The DA forecast is shorter than hours_to_run."))
    hours_to_run * intervals_per_hour <= size(real_time_forecast.load_mw, 2) ||
        throw(ArgumentError("The RT forecast is shorter than hours_to_run."))

    state = initial_state
    day_ahead_results = DARTDispatchResult[]
    real_time_results = DARTDispatchResult[]
    rt_to_da_index = Int[]

    for hour = 1:hours_to_run
        da_last =
            min(size(day_ahead_forecast.load_mw, 2), hour + day_ahead_lookahead_hours - 1)
        da_forecast = _slice_forecast(day_ahead_forecast, hour, da_last)
        da = solve_dart_scuc(
            data,
            da_forecast,
            state;
            config = config,
            optimizer = optimizer,
        )
        push!(day_ahead_results, _binding_result(da))

        for interval_in_hour = 1:intervals_per_hour
            rt_first = (hour - 1) * intervals_per_hour + interval_in_hour
            rt_last = min(
                size(real_time_forecast.load_mw, 2),
                rt_first + real_time_lookahead_intervals - 1,
            )
            rt_forecast = _slice_forecast(real_time_forecast, rt_first, rt_last)
            rt_commitment =
                zeros(Int, length(data.generators), size(rt_forecast.load_mw, 2))
            for t in axes(rt_commitment, 2)
                da_interval = 1 + div(interval_in_hour + t - 2, intervals_per_hour)
                da_interval = min(da_interval, size(da.commitment, 2))
                rt_commitment[:, t] .= da.commitment[:, da_interval]
            end
            rt = solve_dart_sced(
                data,
                rt_forecast,
                state,
                rt_commitment;
                config = config,
                optimizer = optimizer,
            )
            binding_rt = _binding_result(rt)
            push!(real_time_results, binding_rt)
            push!(rt_to_da_index, hour)
            state = advance_dart_state(data, state, binding_rt)
        end
    end

    return DARTRollingResult(
        day_ahead_results = day_ahead_results,
        real_time_results = real_time_results,
        rt_to_da_index = rt_to_da_index,
        final_state = state,
    )
end

# -----------------------------------------------------------------------------
# Two-settlement accounting
# -----------------------------------------------------------------------------

function _allocate_to_load(total, served_energy)
    sum(served_energy) > 0 || return zeros(length(served_energy))
    return total .* served_energy ./ sum(served_energy)
end

function _validate_binding_result(data, result, expected_stage)
    G = length(data.generators)
    S = length(data.storage)
    N = length(data.network.bus_names)
    L = length(data.network.line_names)
    product_names = Set(getfield.(data.reserve_products, :name))

    result.stage == expected_stage || throw(
        ArgumentError(
            "Settlement result has stage $(result.stage), expected $(expected_stage).",
        ),
    )
    isfinite(result.interval_hours) && result.interval_hours > 0 ||
        throw(ArgumentError("Settlement intervals must be finite and positive."))
    isfinite(result.objective_value) ||
        throw(ArgumentError("Settlement results must have a finite objective value."))

    expected_dimensions = (
        (:load_mw, result.load_mw, (N, 1)),
        (:interchange_mw, result.interchange_mw, (N, 1)),
        (:generator_in_service, result.generator_in_service, (G, 1)),
        (:generation_mw, result.generation_mw, (G, 1)),
        (:commitment, result.commitment, (G, 1)),
        (:startup, result.startup, (G, 1)),
        (:shutdown, result.shutdown, (G, 1)),
        (:storage_charge_mw, result.storage_charge_mw, (S, 1)),
        (:storage_discharge_mw, result.storage_discharge_mw, (S, 1)),
        (:storage_soc_mwh, result.storage_soc_mwh, (S, 1)),
        (:load_shed_mw, result.load_shed_mw, (N, 1)),
        (:line_flow_mw, result.line_flow_mw, (L, 1)),
        (:lmp_per_mwh, result.lmp_per_mwh, (N, 1)),
    )
    for (name, values, dimensions) in expected_dimensions
        size(values) == dimensions || throw(
            ArgumentError("Settlement field $(name) must have dimensions $(dimensions)."),
        )
        all(isfinite, values) ||
            throw(ArgumentError("Settlement field $(name) must contain finite values."))
    end

    Set(keys(result.generator_reserve_mw)) == product_names || throw(
        ArgumentError("Generator reserve settlement products do not match system data."),
    )
    Set(keys(result.storage_reserve_mw)) == product_names || throw(
        ArgumentError("Storage reserve settlement products do not match system data."),
    )
    Set(keys(result.reserve_requirement_shadow_price_per_mw_hour)) == product_names ||
        throw(ArgumentError("Reserve shadow-price products do not match system data."))
    for name in product_names
        generator_reserve = result.generator_reserve_mw[name]
        storage_reserve = result.storage_reserve_mw[name]
        shadow_price = result.reserve_requirement_shadow_price_per_mw_hour[name]
        size(generator_reserve) == (G, 1) || throw(
            ArgumentError(
                "Generator reserve result $(name) must be generator count by one.",
            ),
        )
        size(storage_reserve) == (S, 1) || throw(
            ArgumentError("Storage reserve result $(name) must be storage count by one."),
        )
        length(shadow_price) == 1 ||
            throw(ArgumentError("Reserve shadow price $(name) must contain one interval."))
        all(isfinite, generator_reserve) &&
            all(isfinite, storage_reserve) &&
            all(isfinite, shadow_price) ||
            throw(ArgumentError("Reserve settlement values must be finite."))
    end

    contingencies = result.contingency_generator_indices
    length(unique(contingencies)) == length(contingencies) &&
        all(index in 1:G for index in contingencies) ||
        throw(ArgumentError("Contingency generator indices are invalid."))
    size(result.emergency_load_shed_mw) == (N, 1, length(contingencies)) ||
        throw(ArgumentError("Emergency load-shed settlement dimensions are invalid."))
    all(isfinite, result.emergency_load_shed_mw) ||
        throw(ArgumentError("Emergency load-shed values must be finite."))
    return nothing
end

function _validate_settlement_inputs(data, rolling)
    da_results = rolling.day_ahead_results
    rt_results = rolling.real_time_results
    isempty(da_results) &&
        throw(ArgumentError("Settlement requires at least one day-ahead result."))
    isempty(rt_results) &&
        throw(ArgumentError("Settlement requires at least one real-time result."))
    length(rolling.rt_to_da_index) == length(rt_results) ||
        throw(ArgumentError("Every RT result must map to a DA result."))
    issorted(rolling.rt_to_da_index) ||
        throw(ArgumentError("RT-to-DA settlement mappings must be chronological."))
    all(index in eachindex(da_results) for index in rolling.rt_to_da_index) ||
        throw(ArgumentError("An RT result maps to a nonexistent DA result."))

    for result in da_results
        _validate_binding_result(data, result, :day_ahead)
        isapprox(result.interval_hours, 1.0; atol = 1e-9) ||
            throw(ArgumentError("Day-ahead settlement results must be hourly."))
    end
    for result in rt_results
        _validate_binding_result(data, result, :real_time)
    end

    covered_hours = zeros(length(da_results))
    for (rt_index, da_index) in pairs(rolling.rt_to_da_index)
        covered_hours[da_index] += rt_results[rt_index].interval_hours
    end
    for da_index in eachindex(da_results)
        isapprox(
            covered_hours[da_index],
            da_results[da_index].interval_hours;
            atol = 1e-8,
            rtol = 1e-8,
        ) || throw(
            ArgumentError(
                "RT results mapped to DA interval $(da_index) cover " *
                "$(covered_hours[da_index]) hours instead of " *
                "$(da_results[da_index].interval_hours).",
            ),
        )
    end
    return nothing
end

function calculate_dart_settlements(data::DARTSystemData, rolling::DARTRollingResult)
    da_results = rolling.day_ahead_results
    rt_results = rolling.real_time_results
    _validate_settlement_inputs(data, rolling)
    G = length(data.generators)
    S = length(data.storage)
    N = length(data.network.bus_names)
    generator_bus, storage_bus = _bus_indices(data)

    generator_da = zeros(G)
    generator_rt = zeros(G)
    generator_reserve = zeros(G)
    generator_cost = zeros(G)
    storage_da = zeros(S)
    storage_rt = zeros(S)
    storage_reserve = zeros(S)
    storage_cost = zeros(S)
    load_energy = zeros(N)
    interchange_credit = zeros(N)
    served_energy = zeros(N)

    # Day-ahead energy settles at nodal prices. V1 reserve awards settle at
    # resource offers because security deliverability can make their dual value
    # resource-specific.
    for da in da_results
        dt = da.interval_hours
        for g = 1:G
            generator = data.generators[g]
            generator_da[g] +=
                da.generation_mw[g, 1] * da.lmp_per_mwh[generator_bus[g], 1] * dt
            generator_cost[g] +=
                generator.no_load_cost_per_hour * da.commitment[g, 1] * dt +
                generator.startup_cost * da.startup[g, 1] +
                generator.shutdown_cost * da.shutdown[g, 1]
            for product in data.reserve_products
                offer = get(generator.reserve_cost_per_mw_hour, product.name, 0.0)
                generator_reserve[g] +=
                    da.generator_reserve_mw[product.name][g, 1] * offer * dt
            end
        end
        for s = 1:S
            net = da.storage_discharge_mw[s, 1] - da.storage_charge_mw[s, 1]
            storage_da[s] += net * da.lmp_per_mwh[storage_bus[s], 1] * dt
            for product in data.reserve_products
                offer = get(data.storage[s].reserve_cost_per_mw_hour, product.name, 0.0)
                storage_reserve[s] += da.storage_reserve_mw[product.name][s, 1] * offer * dt
            end
        end
        for n = 1:N
            served = da.load_mw[n, 1] - da.load_shed_mw[n, 1]
            load_energy[n] += served * da.lmp_per_mwh[n, 1] * dt
            interchange_credit[n] += da.interchange_mw[n, 1] * da.lmp_per_mwh[n, 1] * dt
        end
    end

    # Real-time energy deviations settle at real-time nodal prices. Reserve
    # deviations use the same resource offers as the day-ahead awards.
    for (rt_index, rt) in pairs(rt_results)
        da = da_results[rolling.rt_to_da_index[rt_index]]
        dt = rt.interval_hours
        for g = 1:G
            generator = data.generators[g]
            deviation = rt.generation_mw[g, 1] - da.generation_mw[g, 1]
            generator_rt[g] += deviation * rt.lmp_per_mwh[generator_bus[g], 1] * dt
            generator_cost[g] +=
                generator.variable_cost_per_mwh * rt.generation_mw[g, 1] * dt
            for product in data.reserve_products
                offer = get(generator.reserve_cost_per_mw_hour, product.name, 0.0)
                reserve_deviation =
                    rt.generator_reserve_mw[product.name][g, 1] -
                    da.generator_reserve_mw[product.name][g, 1]
                generator_reserve[g] += reserve_deviation * offer * dt
                generator_cost[g] +=
                    offer * rt.generator_reserve_mw[product.name][g, 1] * dt
            end
        end
        for s = 1:S
            resource = data.storage[s]
            da_net = da.storage_discharge_mw[s, 1] - da.storage_charge_mw[s, 1]
            rt_net = rt.storage_discharge_mw[s, 1] - rt.storage_charge_mw[s, 1]
            storage_rt[s] += (rt_net - da_net) * rt.lmp_per_mwh[storage_bus[s], 1] * dt
            storage_cost[s] +=
                resource.variable_cost_per_mwh *
                (rt.storage_charge_mw[s, 1] + rt.storage_discharge_mw[s, 1]) *
                dt
            for product in data.reserve_products
                reserve_deviation =
                    rt.storage_reserve_mw[product.name][s, 1] -
                    da.storage_reserve_mw[product.name][s, 1]
                offer = get(resource.reserve_cost_per_mw_hour, product.name, 0.0)
                storage_reserve[s] += reserve_deviation * offer * dt
                storage_cost[s] += offer * rt.storage_reserve_mw[product.name][s, 1] * dt
            end
        end
        for n = 1:N
            da_served = da.load_mw[n, 1] - da.load_shed_mw[n, 1]
            rt_served = rt.load_mw[n, 1] - rt.load_shed_mw[n, 1]
            load_energy[n] += (rt_served - da_served) * rt.lmp_per_mwh[n, 1] * dt
            served_energy[n] += rt_served * dt
            interchange_credit[n] +=
                (rt.interchange_mw[n, 1] - da.interchange_mw[n, 1]) *
                rt.lmp_per_mwh[n, 1] *
                dt
        end
    end

    generator_market_credit = generator_da + generator_rt + generator_reserve
    storage_market_credit = storage_da + storage_rt + storage_reserve
    generator_uplift = max.(generator_cost - generator_market_credit, 0.0)
    storage_uplift = max.(storage_cost - storage_market_credit, 0.0)
    total_reserve = sum(generator_reserve) + sum(storage_reserve)
    total_uplift = sum(generator_uplift) + sum(storage_uplift)
    load_reserve = _allocate_to_load(total_reserve, served_energy)
    load_uplift = _allocate_to_load(total_uplift, served_energy)
    unallocated_reserve = total_reserve - sum(load_reserve)
    unallocated_uplift = total_uplift - sum(load_uplift)

    energy_supplier_credit =
        sum(generator_da) +
        sum(generator_rt) +
        sum(storage_da) +
        sum(storage_rt) +
        sum(interchange_credit)
    merchandising_surplus = sum(load_energy) - energy_supplier_credit
    settlement_balance =
        sum(load_energy) +
        sum(load_reserve) +
        sum(load_uplift) +
        unallocated_reserve +
        unallocated_uplift - energy_supplier_credit - total_reserve - total_uplift -
        merchandising_surplus

    return DARTSettlementResult(
        reserve_settlement_rule = :pay_as_bid,
        generator_day_ahead_energy = generator_da,
        generator_real_time_deviation = generator_rt,
        generator_reserve_credit = generator_reserve,
        generator_uplift = generator_uplift,
        storage_day_ahead_energy = storage_da,
        storage_real_time_deviation = storage_rt,
        storage_reserve_credit = storage_reserve,
        storage_uplift = storage_uplift,
        load_energy_payment = load_energy,
        load_reserve_charge = load_reserve,
        load_uplift_charge = load_uplift,
        unallocated_reserve_charge = unallocated_reserve,
        unallocated_uplift_charge = unallocated_uplift,
        interchange_credit = interchange_credit,
        merchandising_surplus = merchandising_surplus,
        settlement_balance = settlement_balance,
    )
end

export advance_dart_state
export build_dart_sced_model
export build_dart_scuc_model
export calculate_dart_settlements
export DARTConfig
export DARTDispatchResult
export DARTForecast
export DARTGenerator
export DARTNetwork
export DARTReserveProduct
export DARTRollingResult
export DARTSettlementResult
export DARTState
export DARTStorage
export DARTSystemData
export default_dart_reserve_products
export default_dart_state
export run_dart_rolling
export solve_dart_sced
export solve_dart_scuc

end
