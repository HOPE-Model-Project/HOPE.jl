"""Standard HOPE case workflow for day-ahead/real-time (DART) studies."""

_dart_bool(value) =
    value isa Bool ? value : value isa Number ? !iszero(value) :
    lowercase(strip(string(value))) in ("true", "yes", "1", "on")

_dart_float(value, label) = try
    Float64(value)
catch
    throw(ArgumentError("DART setting $(label) must be numeric; found $(value)."))
end

function _dart_int(value, label)
    number = _dart_float(value, label)
    isinteger(number) || throw(ArgumentError("DART setting $(label) must be an integer."))
    return Int(number)
end

function _dart_mapping(parent::AbstractDict, key::AbstractString; required = true)
    value = get(parent, key, nothing)
    value === nothing && !required && return Dict{String,Any}()
    value isa AbstractDict || throw(ArgumentError("DART setting $(key) must be a mapping."))
    return Dict(string(k) => v for (k, v) in value)
end

function _dart_disabled(config, key)
    !haskey(config, key) && return true
    value = config[key]
    value === nothing && return true
    value isa AbstractDict && return isempty(value)
    value isa AbstractVector && return isempty(value)
    return !_dart_bool(value)
end

"""Validate the DART subset of the common `HOPE_model_settings.yml` contract."""
function validate_dart_settings(config::AbstractDict; emit_warnings = true)
    errors = String[]
    warnings = String[]
    uppercase(string(get(config, "model_mode", ""))) == "DART" ||
        push!(errors, "model_mode must be DART.")
    haskey(config, "DataCase") && !isempty(strip(string(config["DataCase"]))) ||
        push!(errors, "DataCase must name the DART input directory.")
    haskey(config, "solver") && !isempty(strip(string(config["solver"]))) ||
        push!(errors, "solver must name a configured HOPE solver.")

    disabled_only = Dict(
        "resource_aggregation" => "unit-specific state and contingencies are required",
        "representative_day!" => "chronological DA/RT state transitions are required",
        "endogenous_rep_day" => "chronological DA/RT state transitions are required",
        "external_rep_day" => "chronological DA/RT state transitions are required",
        "flexible_demand" => "flexible-demand equations are not implemented",
        "clean_energy_policy" => "RPS/REC equations are not implemented",
        "carbon_policy" => "carbon-policy equations are not implemented",
        "planning_reserve_mode" => "planning reserve is not an operating reserve",
        "inv_dcs_bin" => "DART has no investment decisions",
        "transmission_expansion" => "DART dispatches a fixed installed network",
        "save_postprocess_snapshot" => "that snapshot records GTEP investment decisions",
        "storage_ld_duration_hours" => "candidate-storage planning is not implemented",
    )
    for (key, reason) in disabled_only
        if !_dart_disabled(config, key)
            message = "$(key)=$(config[key]) is unavailable for DART because $(reason)."
            push!(warnings, message)
            push!(errors, message)
        end
    end

    _dart_int(get(config, "network_model", 3), "network_model") == 3 ||
        push!(errors, "network_model must be 3 (nodal PTDF) for DART.")
    _dart_int(get(config, "transmission_loss", 0), "transmission_loss") == 0 ||
        push!(errors, "transmission_loss must be 0 for DART.")
    _dart_int(get(config, "unit_commitment", 1), "unit_commitment") in (0, 1) ||
        push!(errors, "unit_commitment must be 0 or 1 for DART.")
    _dart_int(get(config, "operation_reserve_mode", 0), "operation_reserve_mode") in
    (0, 1, 2) || push!(errors, "operation_reserve_mode must be 0, 1, or 2 for DART.")
    _dart_int(get(config, "debug", 0), "debug") == 0 ||
        push!(errors, "DART rolling debug is unavailable; set debug: 0.")
    haskey(config, "time_periods") && push!(
        warnings,
        "time_periods is unused by DART; explicit DA/RT chronology is used.",
    )
    if haskey(config, "debug_stage_file") && !isempty(strip(string(config["debug_stage_file"])))
        push!(errors, "debug_stage_file is unavailable for DART.")
    end

    settings = _dart_mapping(config, "dart_settings")
    time = _dart_mapping(settings, "time")
    _dart_int(get(time, "binding_hours", 0), "binding_hours") > 0 ||
        push!(errors, "binding_hours must be positive.")
    _dart_int(get(time, "day_ahead_lookahead_hours", 0), "day_ahead_lookahead_hours") > 0 ||
        push!(errors, "day_ahead_lookahead_hours must be positive.")
    rt_per_hour = _dart_int(
        get(time, "real_time_intervals_per_hour", 0),
        "real_time_intervals_per_hour",
    )
    rt_per_hour > 0 && 60 % rt_per_hour == 0 ||
        push!(errors, "real_time_intervals_per_hour must divide 60.")
    _dart_int(get(time, "real_time_lookahead_intervals", 0), "real_time_lookahead_intervals") > 0 ||
        push!(errors, "real_time_lookahead_intervals must be positive.")

    availability = lowercase(string(get(settings, "availability_mode", "physical_outages")))
    availability in ("physical_outages", "deterministic_for_derating") || push!(
        errors,
        "availability_mode must be physical_outages or deterministic_for_derating.",
    )
    security = _dart_mapping(settings, "security"; required = false)
    _dart_bool(get(security, "line_contingencies", false)) &&
        push!(errors, "DART line contingencies are not implemented.")
    settlement = _dart_mapping(settings, "settlement"; required = false)
    if _dart_bool(get(settlement, "enabled", true))
        lowercase(string(get(settlement, "reserve_rule", "pay_as_bid"))) == "pay_as_bid" ||
            push!(errors, "DART supports only settlement.reserve_rule: pay_as_bid.")
    end
    for warning in warnings
        emit_warnings && @warn warning
    end
    isempty(errors) || throw(
        ArgumentError("Invalid DART configuration:\n  - " * join(errors, "\n  - ")),
    )
    return warnings
end

function _dart_exact_rows(table, column, expected_ids, label)
    observed = string.(table[!, column])
    length(unique(observed)) == length(observed) ||
        throw(ArgumentError("$(label) contains duplicate IDs."))
    Set(observed) == Set(expected_ids) ||
        throw(ArgumentError("$(label) IDs do not match the DART snapshot."))
    return Dict(string(row[column]) => row for row in eachrow(table))
end

function _dart_single_parameters(data_dir)
    path = joinpath(data_dir, "single_parameter.csv")
    isfile(path) || throw(ArgumentError("Missing DART scalar input: $(path)"))
    table = CSV.read(path, DataFrame)
    nrow(table) == 1 || throw(ArgumentError("single_parameter.csv must contain one row."))
    return table
end

function _dart_single_value(table, column, default = nothing)
    column in string.(names(table)) && return _dart_float(table[1, column], column)
    default === nothing && throw(ArgumentError("single_parameter.csv is missing $(column)."))
    return Float64(default)
end

function _dart_products(single)
    reg = round(Int, 60 * _dart_single_value(single, "delta_reg", 1 / 12))
    spin = round(Int, 60 * _dart_single_value(single, "delta_spin", 1 / 6))
    nspin = round(Int, 60 * _dart_single_value(single, "delta_nspin", 1 / 2))
    all(>(0), (reg, spin, nspin)) ||
        throw(ArgumentError("DART reserve response times must be positive."))
    return [
        DARTReserveProduct(name = :reg_up, direction = :up, response_minutes = reg),
        DARTReserveProduct(name = :reg_down, direction = :down, response_minutes = reg),
        DARTReserveProduct(name = :spin, direction = :up, response_minutes = spin),
        DARTReserveProduct(
            name = :nspin,
            direction = :up,
            response_minutes = nspin,
            requires_online = false,
        ),
    ]
end

function _load_dart_system(config, snapshot, settings, data_dir, single)
    reserve_mode = _dart_int(get(config, "operation_reserve_mode", 0), "operation_reserve_mode")
    uc_mode = _dart_int(get(config, "unit_commitment", 1), "unit_commitment")
    security = _dart_mapping(settings, "security"; required = false)
    availability = lowercase(string(get(settings, "availability_mode", "physical_outages")))
    profile = availability == "physical_outages" ? :physical_outage : :deterministic_derated
    base = build_dart_system(
        snapshot;
        profile = profile,
        include_reserves = reserve_mode > 0,
        include_nspin = reserve_mode == 2,
        include_unit_commitment = uc_mode == 1,
        enforce_ramps = _dart_bool(get(settings, "enforce_ramps", true)),
        include_storage = _dart_bool(get(settings, "include_storage", true)),
        contingency_ids = string.(get(security, "contingency_generator_ids", String[])),
        reference_bus = _dart_int(get(config, "reference_bus", 1), "reference_bus"),
    )
    return DARTSystemData(
        generators = base.generators,
        network = base.network,
        storage = base.storage,
        reserve_products = _dart_products(single),
    )
end
function _load_dart_state(data, settings, data_dir)
    files = _dart_mapping(settings, "files"; required = false)
    gen_file = string(get(files, "initial_generator_state", ""))
    sto_file = string(get(files, "initial_storage_state", ""))
    isempty(gen_file) && isempty(sto_file) && return build_dart_initial_state(data)
    isempty(gen_file) && throw(ArgumentError("initial_generator_state is required."))
    gen = CSV.read(joinpath(data_dir, gen_file), DataFrame)
    gen_rows = _dart_exact_rows(gen, :generator_id, getfield.(data.generators, :name), "Initial generator state")
    sto_rows = Dict{String,Any}()
    if !isempty(data.storage)
        isempty(sto_file) && throw(ArgumentError("initial_storage_state is required."))
        sto = CSV.read(joinpath(data_dir, sto_file), DataFrame)
        sto_rows = _dart_exact_rows(sto, :storage_id, getfield.(data.storage, :name), "Initial storage state")
    end
    gids = getfield.(data.generators, :name)
    sids = getfield.(data.storage, :name)
    return build_dart_initial_state(
        data;
        commitment = [Int(gen_rows[id].commitment) for id in gids],
        generation_mw = [Float64(gen_rows[id].generation_mw) for id in gids],
        on_duration_hours = [Float64(gen_rows[id].on_duration_hours) for id in gids],
        off_duration_hours = [Float64(gen_rows[id].off_duration_hours) for id in gids],
        generator_in_service = [_dart_bool(gen_rows[id].in_service) for id in gids],
        storage_soc_mwh = [Float64(sto_rows[id].soc_mwh) for id in sids],
    )
end

function _dart_realtime_tables(settings, data_dir)
    files = _dart_mapping(settings, "files"; required = false)
    file_names = Dict(
        "load" => string(get(files, "real_time_load", "")),
        "wind" => string(get(files, "real_time_wind", "")),
        "solar" => string(get(files, "real_time_solar", "")),
    )
    configured = Dict(key => !isempty(value) for (key, value) in file_names)
    if !any(values(configured))
        @warn(
            "DART native five-minute time series were not provided. Hourly values " *
            "will be repeated or shaped by legacy inline multipliers. Provide RT " *
            "load, wind, and solar files with an explicit Minute column."
        )
        return nothing
    end
    all(values(configured)) || throw(
        ArgumentError(
            "DART native five-minute input requires real_time_load, " *
            "real_time_wind, and real_time_solar together.",
        ),
    )
    tables = Dict{String,DataFrame}()
    for (kind, file) in file_names
        path = joinpath(data_dir, file)
        isfile(path) || throw(ArgumentError("Missing DART real-time $(kind) file: $(path)"))
        table = CSV.read(path, DataFrame)
        if !("Minute" in string.(names(table)))
            @warn(
                "DART real-time $(kind) file $(file) has no Minute column. " *
                "Five-minute timestamps cannot be verified."
            )
            throw(ArgumentError("DART real-time files must contain Minute."))
        end
        tables[kind] = table
    end
    return (load = tables["load"], wind = tables["wind"], solar = tables["solar"])
end

function _dart_realtime_timestamps(table, year, intervals, label)
    required = Set(["Month", "Day", "Hours", "Minute"])
    issubset(required, Set(string.(names(table)))) ||
        throw(ArgumentError("$(label) must contain Month, Day, Hours, and Minute."))
    step = div(60, intervals)
    timestamps = DateTime[]
    for row in eachrow(table)
        hour_value = _dart_int(row["Hours"], "$(label) Hours")
        minute_value = _dart_int(row["Minute"], "$(label) Minute")
        1 <= hour_value <= 24 ||
            throw(ArgumentError("$(label) Hours must use the 1:24 convention."))
        0 <= minute_value < 60 && minute_value % step == 0 || throw(
            ArgumentError(
                "$(label) Minute must use $(collect(0:step:59)) for $(intervals) intervals/hour.",
            ),
        )
        push!(
            timestamps,
            DateTime(
                year,
                _dart_int(row["Month"], "$(label) Month"),
                _dart_int(row["Day"], "$(label) Day"),
            ) + Hour(hour_value - 1) + Minute(minute_value),
        )
    end
    length(unique(timestamps)) == length(timestamps) ||
        throw(ArgumentError("$(label) timestamps must be unique."))
    all(timestamps[i] - timestamps[i-1] == Minute(step) for i = 2:length(timestamps)) ||
        throw(ArgumentError("$(label) timestamps must be consecutive $(step)-minute starts."))
    return timestamps
end

function _dart_native_realtime_profiles(
    settings,
    data_dir,
    snapshot,
    raw_availability,
    expected_timestamps,
    intervals,
)
    tables = _dart_realtime_tables(settings, data_dir)
    tables === nothing && return nothing
    calendar_year = Dates.year(first(expected_timestamps))
    load_timestamps =
        _dart_realtime_timestamps(tables.load, calendar_year, intervals, "RT load")
    wind_timestamps =
        _dart_realtime_timestamps(tables.wind, calendar_year, intervals, "RT wind")
    solar_timestamps =
        _dart_realtime_timestamps(tables.solar, calendar_year, intervals, "RT solar")
    load_timestamps == wind_timestamps == solar_timestamps ||
        throw(ArgumentError("DART RT load, wind, and solar timestamps must match."))

    row_by_time = Dict(timestamp => row for (row, timestamp) in pairs(load_timestamps))
    all(haskey(row_by_time, timestamp) for timestamp in expected_timestamps) ||
        throw(ArgumentError("DART RT files do not cover the selected DA/RT horizon."))
    selected = [row_by_time[timestamp] for timestamp in expected_timestamps]

    rt_load = zeros(length(snapshot.buses), length(selected))
    for (bus, asset) in pairs(snapshot.buses)
        asset.zone in string.(names(tables.load)) ||
            throw(ArgumentError("RT load series is missing zone $(asset.zone)."))
        rt_load[bus, :] .= asset.peak_load_mw .* [
            _dart_float(value, "RT load $(asset.zone)") for
            value in tables.load[selected, asset.zone]
        ]
    end
    all(isfinite, rt_load) && all(rt_load .>= 0) ||
        throw(ArgumentError("DART RT load values must be finite and nonnegative."))
    if "NI" in string.(names(tables.load))
        all(iszero, [_dart_float(value, "RT NI") for value in tables.load[selected, "NI"]]) ||
            throw(ArgumentError("Nonzero RT interchange must use dart_settings.interchange."))
    end

    rt_availability = copy(raw_availability)
    for (generator, asset) in pairs(snapshot.generators)
        table =
            asset.technology == "SolarPV" ? tables.solar :
            asset.technology in ("WindOn", "WindOff") ? tables.wind : nothing
        table === nothing && continue
        asset.zone in string.(names(table)) ||
            throw(ArgumentError("RT $(asset.technology) series is missing zone $(asset.zone)."))
        values = [
            _dart_float(value, "RT $(asset.technology) $(asset.zone)") for
            value in table[selected, asset.zone]
        ]
        all(value -> isfinite(value) && 0.0 <= value <= 1.0, values) ||
            throw(ArgumentError("DART RT VRE availability must be within [0, 1]."))
        rt_availability[generator, :] .= values
    end
    return (load_mw = rt_load, availability = rt_availability)
end

function _dart_forecasts(snapshot, data, state, config, settings, data_dir)
    time = _dart_mapping(settings, "time")
    intervals = Int(time["real_time_intervals_per_hour"])
    binding_hours = Int(time["binding_hours"])
    lookahead = Int(time["day_ahead_lookahead_hours"])
    start_hour = Int(get(time, "source_start_hour", 1))
    total_hours = max(binding_hours, lookahead)
    1 <= start_hour <= length(snapshot.timestamps) - total_hours + 1 ||
        throw(ArgumentError("source_start_hour does not leave a complete DART horizon."))

    rt_service = trues(length(data.generators), total_hours * intervals)
    outage = _dart_mapping(settings, "realized_outage"; required = false)
    if _dart_bool(get(outage, "enabled", !isempty(outage)))
        idx = findfirst(==(string(outage["generator_id"])), getfield.(data.generators, :name))
        idx === nothing && throw(ArgumentError("Unknown realized-outage generator."))
        first = (Int(outage["binding_hour"]) - 1) * intervals + Int(outage["first_interval"])
        last = (Int(outage["binding_hour"]) - 1) * intervals + Int(outage["last_interval"])
        1 <= first <= last <= size(rt_service, 2) ||
            throw(ArgumentError("Realized outage lies outside the DART horizon."))
        rt_service[idx, first:last] .= false
    end

    reserve_mode = Int(get(config, "operation_reserve_mode", 0))
    terminal = _dart_mapping(settings, "terminal_storage"; required = false)
    terminal_mode = lowercase(string(get(terminal, "mode", "none")))
    terminal_soc = terminal_mode == "initial" ? copy(state.storage_soc_mwh) : nothing
    terminal_mode in ("none", "initial") ||
        throw(ArgumentError("terminal_storage.mode must be none or initial."))
    raw = build_dart_forecasts(
        snapshot,
        start_hour:(start_hour+total_hours-1);
        rt_intervals_per_hour = intervals,
        include_reserves = reserve_mode > 0,
        include_real_time_reserve_requirements = _dart_bool(
            get(settings, "real_time_reserve_requirements", reserve_mode > 0),
        ),
        include_nspin = reserve_mode == 2,
        real_time_generator_in_service = rt_service,
        terminal_storage_soc_mwh = terminal_soc,
    )

    da_interchange = copy(raw.day_ahead.interchange_mw)
    rt_interchange = copy(raw.real_time.interchange_mw)
    interchange = _dart_mapping(settings, "interchange"; required = false)
    if _dart_bool(get(interchange, "enabled", false))
        injection = findfirst(==(string(interchange["injection_bus_id"])), data.network.bus_names)
        withdrawal = findfirst(==(string(interchange["withdrawal_bus_id"])), data.network.bus_names)
        injection === nothing && throw(ArgumentError("Unknown interchange injection bus."))
        withdrawal === nothing && throw(ArgumentError("Unknown interchange withdrawal bus."))
        transfer = Float64(interchange["transfer_mw"])
        da_interchange[injection, :] .+= transfer
        da_interchange[withdrawal, :] .-= transfer
        rt_interchange[injection, :] .+= transfer
        rt_interchange[withdrawal, :] .-= transfer
    end

    native = _dart_native_realtime_profiles(
        settings,
        data_dir,
        snapshot,
        raw.real_time.availability,
        raw.real_time_timestamps,
        intervals,
    )
    if native === nothing
        scenario = _dart_mapping(settings, "real_time_scenario"; required = false)
        load_pattern =
            Float64.(get(scenario, "load_multiplier_by_interval", ones(intervals)))
        vre_pattern = Float64.(
            get(scenario, "vre_availability_multiplier_by_interval", ones(intervals)),
        )
        length(load_pattern) == intervals ||
            throw(ArgumentError("RT load pattern has wrong length."))
        length(vre_pattern) == intervals ||
            throw(ArgumentError("RT VRE pattern has wrong length."))
        isapprox(sum(load_pattern), intervals; atol = 1e-10) ||
            throw(ArgumentError("RT load multipliers must have hourly mean one."))
        isapprox(sum(vre_pattern), intervals; atol = 1e-10) ||
            throw(ArgumentError("RT VRE multipliers must have hourly mean one."))
        rt_load = copy(raw.real_time.load_mw)
        rt_availability = copy(raw.real_time.availability)
        vre_ids = Set(
            g.id for
            g in snapshot.generators if g.technology in ("SolarPV", "WindOn", "WindOff")
        )
        for t in axes(rt_load, 2)
            r = mod1(t, intervals)
            rt_load[:, t] .*= load_pattern[r]
            for g in eachindex(data.generators)
                data.generators[g].name in vre_ids && (
                    rt_availability[g, t] =
                        clamp(rt_availability[g, t] * vre_pattern[r], 0, 1)
                )
            end
        end
    else
        rt_load = native.load_mw
        rt_availability = native.availability
    end
    rt_reserve_requirement = copy(raw.real_time.reserve_requirement_mw)
    if !isempty(rt_reserve_requirement)
        gross_load = vec(sum(rt_load; dims = 1))
        for product in keys(rt_reserve_requirement)
            rt_reserve_requirement[product] =
                snapshot.reserve_requirement_fraction[product] .* gross_load
        end
    end
    day_ahead = DARTForecast(
        interval_hours = 1.0,
        load_mw = raw.day_ahead.load_mw,
        availability = raw.day_ahead.availability,
        generator_in_service = raw.day_ahead.generator_in_service,
        interchange_mw = da_interchange,
        reserve_requirement_mw = raw.day_ahead.reserve_requirement_mw,
        terminal_storage_soc_mwh = raw.day_ahead.terminal_storage_soc_mwh,
    )
    real_time = DARTForecast(
        interval_hours = 1 / intervals,
        load_mw = rt_load,
        availability = rt_availability,
        generator_in_service = raw.real_time.generator_in_service,
        interchange_mw = rt_interchange,
        reserve_requirement_mw = rt_reserve_requirement,
        terminal_storage_soc_mwh = raw.real_time.terminal_storage_soc_mwh,
    )
    return (
        day_ahead = day_ahead,
        real_time = real_time,
        day_ahead_timestamps = raw.day_ahead_timestamps,
        real_time_timestamps = raw.real_time_timestamps,
        start_hour = start_hour,
        binding_hours = binding_hours,
        day_ahead_lookahead_hours = lookahead,
        real_time_lookahead_intervals = Int(time["real_time_lookahead_intervals"]),
        real_time_intervals_per_hour = intervals,
    )
end

function _dart_runtime_config(config, settings, single)
    reserve_mode = Int(get(config, "operation_reserve_mode", 0))
    security = _dart_mapping(settings, "security"; required = false)
    acceptance = _dart_mapping(settings, "solve_acceptance"; required = false)
    costs = _dart_mapping(settings, "costs"; required = false)
    availability = lowercase(string(get(settings, "availability_mode", "physical_outages")))
    up = reserve_mode == 0 ? Symbol[] : reserve_mode == 1 ? [:reg_up, :spin] : [:reg_up, :spin, :nspin]
    down = reserve_mode == 0 ? Symbol[] : [:reg_down]
    return DARTConfig(
        value_of_lost_load_per_mwh = Float64(
            get(costs, "value_of_lost_load_per_mwh", _dart_single_value(single, "VOLL")),
        ),
        emergency_load_shed_cost_per_mwh =
            Float64(get(costs, "emergency_load_shed_cost_per_mwh", 50_000.0)),
        allow_emergency_contingency_shed =
            _dart_bool(get(security, "allow_emergency_contingency_shed", false)),
        apply_for_derating = availability == "deterministic_for_derating",
        security_up_products = up,
        security_down_products = down,
        accept_feasible_time_limit =
            _dart_bool(get(acceptance, "accept_feasible_time_limit", false)),
        maximum_relative_gap = Float64(get(acceptance, "maximum_relative_gap", 1e-6)),
        maximum_security_variables = Int(get(security, "maximum_security_variables", 2_000_000)),
        silent = _dart_bool(get(settings, "silent", true)),
    )
end

function _dart_inventory(snapshot, data)
    return DataFrame(
        item = ["buses", "branches", "generators", "storage", "hours", "quick_start"],
        count = [
            length(snapshot.buses),
            length(snapshot.branches),
            length(snapshot.generators),
            length(snapshot.storage),
            length(snapshot.timestamps),
            count(g.quick_start_eligible for g in data.generators),
        ],
    )
end

function _dart_coverage(data, da, rt, settings)
    products = Set(getfield.(data.reserve_products, :name))
    all_products = Set((:reg_up, :reg_down, :spin, :nspin))
    security = _dart_mapping(settings, "security"; required = false)
    settlement = _dart_mapping(settings, "settlement"; required = false)
    rows = [
        ("binary_unit_commitment", any(getfield.(data.generators, :commitment_required)), "binary DA commitment"),
        ("minimum_up_down_time", any(g.min_up_hours > 0 || g.min_down_hours > 0 for g in data.generators), "minimum-time constraints"),
        ("day_ahead_ramps", all(isfinite(g.ramp_up_mw_per_hour) && isfinite(g.ramp_down_mw_per_hour) for g in data.generators), "finite DA ramps"),
        ("real_time_ramps", all(isfinite(g.real_time_ramp_up_mw_per_hour) && isfinite(g.real_time_ramp_down_mw_per_hour) for g in data.generators), "finite RT ramps"),
        ("startup_shutdown_limits", all(isfinite(g.startup_limit_mw) && isfinite(g.shutdown_limit_mw) for g in data.generators), "finite transition limits"),
        ("four_reserve_products", products == all_products, "REG up/down, SPIN, NSPIN"),
        ("day_ahead_reserve_requirements", Set(keys(da.reserve_requirement_mw)) == all_products, "DA reserve requirements"),
        ("real_time_reserve_requirements", Set(keys(rt.reserve_requirement_mw)) == all_products, "RT reserve requirements"),
        ("offline_quick_start", any(g.quick_start_eligible && get(g.reserve_capability_mw, :nspin, 0.0) > 0 for g in data.generators), "offline NSPIN"),
        ("storage_chronology", !isempty(data.storage), "SOC chronology"),
        ("storage_reserves", any(!isempty(s.reserve_capability_mw) for s in data.storage), "storage reserves"),
        ("terminal_storage_soc", da.terminal_storage_soc_mwh !== nothing, "terminal SOC"),
        ("nodal_ptdf_network", !isempty(data.network.line_names), "PTDF line limits"),
        ("balanced_interchange", maximum(abs, da.interchange_mw; init = 0.0) > 0 && maximum(abs, vec(sum(da.interchange_mw; dims = 1)); init = 0.0) < 1e-9, "balanced transaction"),
        ("strict_generator_n_minus_one", any(getfield.(data.generators, :contingency_eligible)) && !_dart_bool(get(security, "allow_emergency_contingency_shed", false)), "strict generator N-1"),
        ("realized_outage", any(.!rt.generator_in_service), "RT outage"),
        ("forecast_deviation", size(rt.load_mw, 2) > 1 && !isapprox(rt.load_mw[:, 1], rt.load_mw[:, 2]; atol = 1e-10), "subhourly deviation"),
        ("fixed_commitment_sced", true, "RT follows DA commitment"),
        ("two_settlement_accounting", _dart_bool(get(settlement, "enabled", true)), "DA/RT settlement"),
    ]
    return DataFrame(
        constraint_family = first.(rows),
        enabled = getindex.(rows, 2),
        evidence = getindex.(rows, 3),
    )
end

function load_dart_case(case_path::AbstractString, config::AbstractDict; emit_warnings = true)
    validate_dart_settings(config; emit_warnings = emit_warnings)
    data_dir = normpath(joinpath(case_path, string(config["DataCase"])))
    isdir(data_dir) || throw(ArgumentError("DART DataCase directory does not exist: $(data_dir)"))
    manifest = YAML.load_file(joinpath(case_path, "manifest.yml"))
    normpath(string(manifest["source_data_subdir"])) == normpath(string(config["DataCase"])) ||
        throw(ArgumentError("manifest source_data_subdir must match DataCase."))
    snapshot = load_operational_snapshot(case_path)
    settings = _dart_mapping(config, "dart_settings")
    single = _dart_single_parameters(data_dir)
    data = _load_dart_system(config, snapshot, settings, data_dir, single)
    state = _load_dart_state(data, settings, data_dir)
    forecasts = _dart_forecasts(snapshot, data, state, config, settings, data_dir)
    coverage = _dart_coverage(data, forecasts.day_ahead, forecasts.real_time, settings)
    acceptance = _dart_mapping(settings, "acceptance"; required = false)
    if _dart_bool(get(acceptance, "require_all_constraint_families", false)) && !all(coverage.enabled)
        missing = join(coverage.constraint_family[.!coverage.enabled], ", ")
        throw(ArgumentError("Required DART constraint families are disabled: $(missing)."))
    end
    any(getfield.(data.generators, :contingency_eligible)) &&
        Int(get(config, "operation_reserve_mode", 0)) == 0 &&
        throw(ArgumentError("Generator N-1 security requires operation_reserve_mode > 0."))
    return Dict{String,Any}(
        "snapshot" => snapshot,
        "system" => data,
        "initial_state" => state,
        "forecasts" => forecasts,
        "dart_config" => _dart_runtime_config(config, settings, single),
        "inventory" => _dart_inventory(snapshot, data),
        "constraint_coverage" => coverage,
        "settings" => settings,
        "data_path" => data_dir,
    )
end

function _dart_dispatch_tables(data, results, timestamps)
    generators = DataFrame[]
    buses = DataFrame[]
    branches = DataFrame[]
    storage = DataFrame[]
    solver = DataFrame[]
    for (i, result) in pairs(results)
        timestamp = timestamps[i]
        gen = DataFrame(
            timestamp = fill(timestamp, length(data.generators)),
            generator_id = getfield.(data.generators, :name),
            in_service = vec(result.generator_in_service),
            generation_mw = vec(result.generation_mw),
            commitment = vec(result.commitment),
            startup = vec(result.startup),
            shutdown = vec(result.shutdown),
        )
        sto = DataFrame(
            timestamp = fill(timestamp, length(data.storage)),
            storage_id = getfield.(data.storage, :name),
            charge_mw = vec(result.storage_charge_mw),
            discharge_mw = vec(result.storage_discharge_mw),
            soc_mwh = vec(result.storage_soc_mwh),
        )
        for product in getfield.(data.reserve_products, :name)
            gen[!, Symbol("$(product)_reserve_mw")] = vec(result.generator_reserve_mw[product])
            sto[!, Symbol("$(product)_reserve_mw")] = vec(result.storage_reserve_mw[product])
        end
        push!(generators, gen)
        push!(storage, sto)
        push!(buses, DataFrame(
            timestamp = fill(timestamp, length(data.network.bus_names)),
            bus_id = data.network.bus_names,
            load_mw = vec(result.load_mw),
            load_shed_mw = vec(result.load_shed_mw),
            interchange_mw = vec(result.interchange_mw),
            lmp_per_mwh = vec(result.lmp_per_mwh),
        ))
        push!(branches, DataFrame(
            timestamp = fill(timestamp, length(data.network.line_names)),
            branch_id = data.network.line_names,
            flow_mw = vec(result.line_flow_mw),
        ))
        push!(solver, DataFrame(
            timestamp = [timestamp],
            stage = [string(result.stage)],
            termination_status = [string(result.termination_status)],
            primal_status = [string(result.primal_status)],
            objective = [result.objective_value],
            relative_gap = [result.relative_gap],
            solve_time_seconds = [result.solve_time_seconds],
        ))
    end
    return (
        generators = vcat(generators...),
        buses = vcat(buses...),
        branches = vcat(branches...),
        storage = vcat(storage...),
        solver = vcat(solver...),
    )
end

function _dart_acceptance(input, rolling, settlement)
    data = input["system"]
    settings = input["settings"]
    results = vcat(rolling.day_ahead_results, rolling.real_time_results)
    optimal = all(r.termination_status == MOI.OPTIMAL for r in results)
    load_shed = maximum(maximum(r.load_shed_mw) for r in results)
    emergency_shed = maximum(maximum(r.emergency_load_shed_mw; init = 0.0) for r in results)
    line_excess = max(
        0.0,
        maximum(
            maximum(abs.(r.line_flow_mw) .- reshape(data.network.line_limit_mw, :, 1); init = -Inf) for r in results
        ),
    )
    simultaneous_storage = maximum(
        maximum(min.(r.storage_charge_mw, r.storage_discharge_mw); init = 0.0) for r in results
    )
    outage_output = 0.0
    outage = _dart_mapping(settings, "realized_outage"; required = false)
    if _dart_bool(get(outage, "enabled", !isempty(outage)))
        g = findfirst(==(string(outage["generator_id"])), getfield.(data.generators, :name))
        rph = input["forecasts"].real_time_intervals_per_hour
        first = (Int(outage["binding_hour"]) - 1) * rph + Int(outage["first_interval"])
        last = (Int(outage["binding_hour"]) - 1) * rph + Int(outage["last_interval"])
        outage_output = maximum(r.generation_mw[g, 1] for r in rolling.real_time_results[first:last])
    end
    nspin = minimum(
        sum(r.generator_reserve_mw[:nspin]) + sum(r.storage_reserve_mw[:nspin]) for r in results
    )
    balance = settlement === nothing ? NaN : settlement.settlement_balance
    table = DataFrame(
        all_constraint_families_enabled = [all(input["constraint_coverage"].enabled)],
        all_solves_optimal = [optimal],
        day_ahead_solves = [length(rolling.day_ahead_results)],
        real_time_solves = [length(rolling.real_time_results)],
        maximum_load_shed_mw = [load_shed],
        maximum_emergency_load_shed_mw = [emergency_shed],
        maximum_line_limit_excess_mw = [line_excess],
        maximum_simultaneous_storage_mw = [simultaneous_storage],
        maximum_outage_generator_output_mw = [outage_output],
        minimum_nspin_award_mw = [nspin],
        settlement_balance = [balance],
    )
    limits = _dart_mapping(settings, "acceptance"; required = false)
    _dart_bool(get(limits, "require_optimal", true)) && !optimal && error("A DART solve was not optimal.")
    load_shed <= Float64(get(limits, "maximum_load_shed_mw", Inf)) || error("DART load shedding exceeded its threshold.")
    emergency_shed <= Float64(get(limits, "maximum_emergency_load_shed_mw", Inf)) || error("DART emergency shedding exceeded its threshold.")
    line_excess <= Float64(get(limits, "maximum_line_limit_excess_mw", 1e-5)) || error("DART line flow exceeded a rating.")
    simultaneous_storage <= Float64(get(limits, "maximum_simultaneous_storage_mw", 1e-6)) || error("DART storage charged and discharged simultaneously.")
    outage_output <= Float64(get(limits, "maximum_outage_generator_output_mw", 1e-6)) || error("The outage generator produced energy.")
    _dart_bool(get(limits, "require_positive_nspin_award", false)) && nspin <= 0 && error("DART did not procure positive NSPIN.")
    settlement !== nothing && abs(balance) > Float64(get(limits, "settlement_balance_tolerance", 1e-5)) && error("DART settlement did not balance.")
    return table
end

function _write_dart_output(case_path, input, rolling, settlement, acceptance)
    outpath = joinpath(case_path, "output")
    tmp = outpath * "_tmp_" * string(round(Int, time()))
    mkdir(tmp)
    try
        CSV.write(joinpath(tmp, "inventory.csv"), input["inventory"])
        CSV.write(joinpath(tmp, "constraint_coverage.csv"), input["constraint_coverage"])
        f = input["forecasts"]
        CSV.write(joinpath(tmp, "selected_window.csv"), DataFrame(
            source_hour = [f.start_hour],
            timestamp = [input["snapshot"].timestamps[f.start_hour]],
            binding_hours = [f.binding_hours],
            day_ahead_lookahead_hours = [f.day_ahead_lookahead_hours],
            real_time_intervals_per_hour = [f.real_time_intervals_per_hour],
            real_time_lookahead_intervals = [f.real_time_lookahead_intervals],
        ))
        da = _dart_dispatch_tables(
            input["system"],
            rolling.day_ahead_results,
            f.day_ahead_timestamps[1:f.binding_hours],
        )
        rt_count = f.binding_hours * f.real_time_intervals_per_hour
        rt = _dart_dispatch_tables(
            input["system"],
            rolling.real_time_results,
            f.real_time_timestamps[1:rt_count],
        )
        for (name, table) in pairs(da)
            CSV.write(joinpath(tmp, "day_ahead_$(name).csv"), table)
        end
        for (name, table) in pairs(rt)
            CSV.write(joinpath(tmp, "real_time_$(name).csv"), table)
        end
        if settlement !== nothing
            CSV.write(joinpath(tmp, "settlement_summary.csv"), DataFrame(
                reserve_rule = [string(settlement.reserve_settlement_rule)],
                merchandising_surplus = [settlement.merchandising_surplus],
                settlement_balance = [settlement.settlement_balance],
                unallocated_reserve_charge = [settlement.unallocated_reserve_charge],
                unallocated_uplift_charge = [settlement.unallocated_uplift_charge],
            ))
        end
        CSV.write(joinpath(tmp, "acceptance_summary.csv"), acceptance)
        return finalize_output_directory(tmp, outpath)
    catch
        isdir(tmp) && rm(tmp; recursive = true, force = true)
        rethrow()
    end
end

function validate_dart_case(case_path::AbstractString, config::AbstractDict)
    input = load_dart_case(case_path, config)
    return Dict(
        "case_path" => case_path,
        "config" => config,
        "input" => input,
        "inventory" => input["inventory"],
        "constraint_coverage" => input["constraint_coverage"],
    )
end

function run_dart_case(case_path::AbstractString, config::AbstractDict, optimizer)
    input = load_dart_case(case_path, config)
    f = input["forecasts"]
    rolling = run_dart_rolling(
        input["system"],
        f.day_ahead,
        f.real_time,
        input["initial_state"];
        hours_to_run = f.binding_hours,
        day_ahead_lookahead_hours = f.day_ahead_lookahead_hours,
        real_time_lookahead_intervals = f.real_time_lookahead_intervals,
        config = input["dart_config"],
        optimizer = optimizer,
    )
    settlement_config = _dart_mapping(input["settings"], "settlement"; required = false)
    settlement = _dart_bool(get(settlement_config, "enabled", true)) ?
                 calculate_dart_settlements(input["system"], rolling) : nothing
    acceptance = _dart_acceptance(input, rolling, settlement)
    output_path = _write_dart_output(case_path, input, rolling, settlement, acceptance)
    return Dict(
        "case_path" => case_path,
        "output_path" => output_path,
        "config" => config,
        "input" => input,
        "rolling_result" => rolling,
        "settlement" => settlement,
        "output" => Dict("acceptance_summary" => acceptance),
    )
end
