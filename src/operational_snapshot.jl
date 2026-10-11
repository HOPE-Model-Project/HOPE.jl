"""Typed installed-system snapshot and DART conversion utilities."""

Base.@kwdef struct OperationalGenerator
    id::String
    source_row::Int
    technology::String
    bus_id::String
    zone::String
    pmax_mw::Float64
    pmin_mw::Float64
    variable_cost_per_mwh::Float64
    startup_cost_per_mw::Float64
    static_availability::Float64
    forced_outage_rate::Float64
    ramp_up_fraction_per_hour::Float64
    ramp_down_fraction_per_hour::Float64
    commitment_required::Bool
    min_up_hours::Int
    min_down_hours::Int
    must_run::Bool
    reserve_fraction::Dict{Symbol,Float64}
    no_load_cost_per_hour::Float64 = 0.0
    shutdown_cost::Float64 = 0.0
    startup_limit_fraction::Float64 = 1.0
    shutdown_limit_fraction::Float64 = 1.0
    quick_start_eligible::Bool = false
    quick_start_time_minutes::Int = 0
    nspin_capability_mw::Float64 = 0.0
    reserve_cost_per_mw_hour::Dict{Symbol,Float64} = Dict(
        :reg_up => 0.0,
        :reg_down => 0.0,
        :spin => 0.0,
        :nspin => 0.0,
    )
end

Base.@kwdef struct OperationalStorage
    id::String
    source_row::Int
    technology::String
    bus_id::String
    zone::String
    energy_capacity_mwh::Float64
    charge_capacity_mw::Float64
    discharge_capacity_mw::Float64
    charge_efficiency::Float64
    discharge_efficiency::Float64
    variable_cost_per_mwh::Float64
    reserve_capability_mw::Dict{Symbol,Float64} = Dict(
        :reg_up => 0.0,
        :reg_down => 0.0,
        :spin => 0.0,
        :nspin => 0.0,
    )
    reserve_cost_per_mw_hour::Dict{Symbol,Float64} = Dict(
        :reg_up => 0.0,
        :reg_down => 0.0,
        :spin => 0.0,
        :nspin => 0.0,
    )
end

Base.@kwdef struct OperationalBus
    id::String
    source_row::Int
    source_label::String
    zone::String
    peak_load_mw::Float64
end

Base.@kwdef struct OperationalBranch
    id::String
    source_row::Int
    from_bus_id::String
    to_bus_id::String
    reactance::Float64
    forward_limit_mw::Float64
    reverse_limit_mw::Float64
end

Base.@kwdef struct OperationalSnapshot
    name::String
    generators::Vector{OperationalGenerator}
    storage::Vector{OperationalStorage}
    buses::Vector{OperationalBus}
    branches::Vector{OperationalBranch}
    timestamps::Vector{DateTime}
    load_mw::Matrix{Float64}
    availability::Matrix{Float64}
    interchange_mw::Matrix{Float64}
    reserve_requirement_fraction::Dict{Symbol,Float64}
    source_hashes::Dict{String,String}
    provenance::Dict{String,String}
end

Base.@kwdef struct DARTForecastSet
    day_ahead::DARTForecast
    real_time::DARTForecast
    day_ahead_timestamps::Vector{DateTime}
    real_time_timestamps::Vector{DateTime}
    generator_ids::Vector{String}
    bus_ids::Vector{String}
end

_snapshot_float(value, label) = try
    value isa Number ? Float64(value) : parse(Float64, strip(string(value)))
catch
    throw(ArgumentError("Expected numeric value for $(label); found '$(value)'."))
end

function _snapshot_int(value, label)
    numeric = _snapshot_float(value, label)
    isinteger(numeric) || throw(ArgumentError("$(label) must be an integer."))
    return Int(numeric)
end

function _snapshot_bool(value, label)
    parsed = _snapshot_int(value, label)
    parsed in (0, 1) || throw(ArgumentError("$(label) must be 0 or 1."))
    return parsed == 1
end

function _snapshot_optional(table, row, column, default, parser)
    column in string.(names(table)) || return default
    return parser(table[row, column], column)
end

_snapshot_hash(path) = bytes2hex(sha256(read(path)))

function _manifest_dict(manifest, key)
    value = get(manifest, key, nothing)
    value isa AbstractDict ||
        throw(ArgumentError("Manifest entry '$(key)' must be a mapping."))
    return Dict(string(k) => v for (k, v) in value)
end

function _load_stable_ids(path, expected_counts)
    isfile(path) || throw(ArgumentError("Missing stable ID mapping: $(path)."))
    table = CSV.read(path, DataFrame)
    required = Set(["kind", "source_row", "stable_id"])
    issubset(required, Set(string.(names(table)))) ||
        throw(ArgumentError("stable_ids.csv must contain kind, source_row, stable_id."))
    ids = Dict{String,Vector{String}}()
    for (kind, expected) in expected_counts
        rows = table[string.(table.kind) .== kind, :]
        nrow(rows) == expected ||
            throw(ArgumentError("Stable ID kind $(kind) has the wrong row count."))
        sort!(rows, :source_row)
        Int.(rows.source_row) == collect(1:expected) ||
            throw(ArgumentError("Stable ID kind $(kind) must map each source row once."))
        mapped = string.(rows.stable_id)
        length(unique(mapped)) == expected ||
            throw(ArgumentError("Stable IDs for $(kind) must be unique."))
        ids[kind] = mapped
    end
    all_ids = reduce(vcat, values(ids); init = String[])
    length(unique(all_ids)) == length(all_ids) ||
        throw(ArgumentError("Stable IDs must be globally unique."))
    return ids
end

function _validate_connected_network(from_idx, to_idx, nbus)
    nbus > 0 || throw(ArgumentError("Operational snapshot requires buses."))
    adjacency = [Int[] for _ = 1:nbus]
    for (from, to) in zip(from_idx, to_idx)
        from == to && throw(ArgumentError("A branch cannot be a self-loop."))
        push!(adjacency[from], to)
        push!(adjacency[to], from)
    end
    visited = falses(nbus)
    stack = [1]
    while !isempty(stack)
        node = pop!(stack)
        visited[node] && continue
        visited[node] = true
        append!(stack, adjacency[node])
    end
    all(visited) ||
        throw(ArgumentError("Network is disconnected; PTDF construction was refused."))
    return nothing
end

function _calendar_timestamps(load_data, calendar_year)
    required = Set(["Month", "Day", "Hours"])
    issubset(required, Set(string.(names(load_data)))) ||
        throw(ArgumentError("Load time series must contain Month, Day, Hours."))
    timestamps = DateTime[]
    for row in eachrow(load_data)
        hour_value = _snapshot_int(row["Hours"], "Hours")
        1 <= hour_value <= 24 ||
            throw(ArgumentError("Hours must use the 1:24 convention."))
        push!(
            timestamps,
            DateTime(
                calendar_year,
                _snapshot_int(row["Month"], "Month"),
                _snapshot_int(row["Day"], "Day"),
            ) + Hour(hour_value - 1),
        )
    end
    length(unique(timestamps)) == length(timestamps) ||
        throw(ArgumentError("Operational timestamps must be unique."))
    all(timestamps[i] - timestamps[i-1] == Hour(1) for i = 2:length(timestamps)) ||
        throw(ArgumentError("Operational timestamps must be consecutive hourly starts."))
    any(month(ts) == 2 && day(ts) == 29 for ts in timestamps) &&
        throw(ArgumentError("The standalone DART calendar must be non-leap."))
    return timestamps
end

function _read_snapshot_tables(data_dir)
    required = [
        "gendata.csv",
        "storagedata.csv",
        "busdata.csv",
        "branchdata.csv",
        "load_timeseries_regional.csv",
        "solar_timeseries_regional.csv",
        "wind_timeseries_regional.csv",
        "single_parameter.csv",
    ]
    for file in required
        isfile(joinpath(data_dir, file)) ||
            throw(ArgumentError("Missing required input $(file)."))
    end
    return Dict(file => CSV.read(joinpath(data_dir, file), DataFrame) for file in required)
end

"""
Load a standalone DART manifest, verify pinned SHA-256 hashes, assign stable
sidecar IDs, and construct a shared physical snapshot. PCM results are not read.
"""
function load_operational_snapshot(case_dir::AbstractString)
    manifest_path = joinpath(case_dir, "manifest.yml")
    isfile(manifest_path) ||
        throw(ArgumentError("Missing DART case manifest: $(manifest_path)."))
    manifest = YAML.load_file(manifest_path)
    manifest isa AbstractDict || throw(ArgumentError("DART manifest must be a mapping."))
    schema_version =
        _snapshot_int(get(manifest, "schema_version", 0), "manifest schema_version")
    schema_version == 2 || throw(
        ArgumentError(
            "Unsupported DART manifest schema_version $(schema_version); expected 2 " *
            "(merged asset attributes and native RT time-series metadata).",
        ),
    )

    source_case = string(get(manifest, "source_case", ""))
    data_subdir = string(get(manifest, "source_data_subdir", ""))
    isempty(source_case) && throw(ArgumentError("Manifest must define source_case."))
    isempty(data_subdir) &&
        throw(ArgumentError("Manifest must define source_data_subdir."))
    data_dir = joinpath(normpath(joinpath(case_dir, source_case)), data_subdir)
    isdir(data_dir) || throw(ArgumentError("Source data directory is missing: $(data_dir)."))

    expected_hashes = _manifest_dict(manifest, "source_hashes")
    observed_hashes = Dict{String,String}()
    for (file, expected_raw) in expected_hashes
        path = joinpath(data_dir, file)
        isfile(path) || throw(ArgumentError("Pinned source file is missing: $(path)."))
        observed = _snapshot_hash(path)
        expected = lowercase(string(expected_raw))
        observed == expected ||
            throw(ArgumentError("Source hash mismatch for $(file); regenerate mappings."))
        observed_hashes[file] = observed
    end

    tables = _read_snapshot_tables(data_dir)
    gen = tables["gendata.csv"]
    sto = tables["storagedata.csv"]
    bus = tables["busdata.csv"]
    branch = tables["branchdata.csv"]
    ids = _load_stable_ids(
        joinpath(case_dir, "stable_ids.csv"),
        Dict(
            "generator" => nrow(gen),
            "storage" => nrow(sto),
            "bus" => nrow(bus),
            "branch" => nrow(branch),
        ),
    )

    bus_labels = string.(bus[!, "Bus_id"])
    length(unique(bus_labels)) == length(bus_labels) ||
        throw(ArgumentError("Source bus labels must be unique."))
    bus_id = Dict(bus_labels[i] => ids["bus"][i] for i in eachindex(bus_labels))
    buses = [
        OperationalBus(
            id = ids["bus"][r],
            source_row = r,
            source_label = bus_labels[r],
            zone = string(bus[r, "Zone_id"]),
            peak_load_mw = _snapshot_float(bus[r, "Demand (MW)"], "bus demand"),
        ) for r = 1:nrow(bus)
    ]

    generators = OperationalGenerator[]
    for r = 1:nrow(gen)
        label = string(gen[r, "Bus_id"])
        haskey(bus_id, label) ||
            throw(ArgumentError("Generator row $(r) references unknown bus $(label)."))
        push!(
            generators,
            OperationalGenerator(
                id = ids["generator"][r],
                source_row = r,
                technology = string(gen[r, "Type"]),
                bus_id = bus_id[label],
                zone = string(gen[r, "Zone"]),
                pmax_mw = _snapshot_float(gen[r, "Pmax (MW)"], "Pmax"),
                pmin_mw = _snapshot_float(gen[r, "Pmin (MW)"], "Pmin"),
                variable_cost_per_mwh =
                    _snapshot_float(gen[r, "Cost (\$/MWh)"], "variable cost"),
                startup_cost_per_mw =
                    _snapshot_float(gen[r, "Start_up_cost (\$/MW)"], "startup cost"),
                static_availability = _snapshot_float(gen[r, "AF"], "AF"),
                forced_outage_rate = _snapshot_float(gen[r, "FOR"], "FOR"),
                ramp_up_fraction_per_hour = _snapshot_float(gen[r, "RU"], "RU"),
                ramp_down_fraction_per_hour = _snapshot_float(gen[r, "RD"], "RD"),
                commitment_required = _snapshot_bool(gen[r, "Flag_UC"], "Flag_UC"),
                min_up_hours = _snapshot_int(gen[r, "Min_up_time"], "Min_up_time"),
                min_down_hours = _snapshot_int(gen[r, "Min_down_time"], "Min_down_time"),
                must_run = _snapshot_bool(gen[r, "Flag_mustrun"], "Flag_mustrun"),
                reserve_fraction = Dict(
                    :reg_up => _snapshot_float(gen[r, "RM_REG_UP"], "RM_REG_UP"),
                    :reg_down => _snapshot_float(gen[r, "RM_REG_DN"], "RM_REG_DN"),
                    :spin => _snapshot_float(gen[r, "RM_SPIN"], "RM_SPIN"),
                    :nspin => _snapshot_float(gen[r, "RM_NSPIN"], "RM_NSPIN"),
                ),
                no_load_cost_per_hour = _snapshot_optional(
                    gen,
                    r,
                    "no_load_cost_per_hour",
                    0.0,
                    _snapshot_float,
                ),
                shutdown_cost =
                    _snapshot_optional(gen, r, "shutdown_cost", 0.0, _snapshot_float),
                startup_limit_fraction = _snapshot_optional(
                    gen,
                    r,
                    "startup_limit_fraction",
                    1.0,
                    _snapshot_float,
                ),
                shutdown_limit_fraction = _snapshot_optional(
                    gen,
                    r,
                    "shutdown_limit_fraction",
                    1.0,
                    _snapshot_float,
                ),
                quick_start_eligible = _snapshot_optional(
                    gen,
                    r,
                    "quick_start_eligible",
                    false,
                    _snapshot_bool,
                ),
                quick_start_time_minutes = _snapshot_optional(
                    gen,
                    r,
                    "quick_start_time_minutes",
                    0,
                    _snapshot_int,
                ),
                nspin_capability_mw = _snapshot_optional(
                    gen,
                    r,
                    "nspin_capability_mw",
                    0.0,
                    _snapshot_float,
                ),
                reserve_cost_per_mw_hour = Dict(
                    :reg_up => _snapshot_optional(
                        gen,
                        r,
                        "reg_up_offer_per_mw_hour",
                        0.0,
                        _snapshot_float,
                    ),
                    :reg_down => _snapshot_optional(
                        gen,
                        r,
                        "reg_down_offer_per_mw_hour",
                        0.0,
                        _snapshot_float,
                    ),
                    :spin => _snapshot_optional(
                        gen,
                        r,
                        "spin_offer_per_mw_hour",
                        0.0,
                        _snapshot_float,
                    ),
                    :nspin => _snapshot_optional(
                        gen,
                        r,
                        "nspin_offer_per_mw_hour",
                        0.0,
                        _snapshot_float,
                    ),
                ),
            ),
        )
    end
    any(x.must_run for x in generators) &&
        throw(ArgumentError("DART conversion does not support must-run semantics."))

    storage = OperationalStorage[]
    for r = 1:nrow(sto)
        label = string(sto[r, "Bus_id"])
        haskey(bus_id, label) ||
            throw(ArgumentError("Storage row $(r) references unknown bus $(label)."))
        max_power = _snapshot_float(sto[r, "Max Power (MW)"], "storage power")
        push!(
            storage,
            OperationalStorage(
                id = ids["storage"][r],
                source_row = r,
                technology = string(sto[r, "Type"]),
                bus_id = bus_id[label],
                zone = string(sto[r, "Zone"]),
                energy_capacity_mwh =
                    _snapshot_float(sto[r, "Capacity (MWh)"], "storage energy"),
                charge_capacity_mw =
                    max_power * _snapshot_float(sto[r, "Charging Rate"], "charge rate"),
                discharge_capacity_mw = max_power * _snapshot_float(
                    sto[r, "Discharging Rate"],
                    "discharge rate",
                ),
                charge_efficiency =
                    _snapshot_float(sto[r, "Charging efficiency"], "charge efficiency"),
                discharge_efficiency = _snapshot_float(
                    sto[r, "Discharging efficiency"],
                    "discharge efficiency",
                ),
                variable_cost_per_mwh =
                    _snapshot_float(sto[r, "Cost (\$/MWh)"], "storage cost"),
                reserve_capability_mw = Dict(
                    :reg_up => _snapshot_optional(
                        sto,
                        r,
                        "reg_up_capability_mw",
                        0.0,
                        _snapshot_float,
                    ),
                    :reg_down => _snapshot_optional(
                        sto,
                        r,
                        "reg_down_capability_mw",
                        0.0,
                        _snapshot_float,
                    ),
                    :spin => _snapshot_optional(
                        sto,
                        r,
                        "spin_capability_mw",
                        0.0,
                        _snapshot_float,
                    ),
                    :nspin => _snapshot_optional(
                        sto,
                        r,
                        "nspin_capability_mw",
                        0.0,
                        _snapshot_float,
                    ),
                ),
                reserve_cost_per_mw_hour = Dict(
                    :reg_up => _snapshot_optional(
                        sto,
                        r,
                        "reg_up_offer_per_mw_hour",
                        0.0,
                        _snapshot_float,
                    ),
                    :reg_down => _snapshot_optional(
                        sto,
                        r,
                        "reg_down_offer_per_mw_hour",
                        0.0,
                        _snapshot_float,
                    ),
                    :spin => _snapshot_optional(
                        sto,
                        r,
                        "spin_offer_per_mw_hour",
                        0.0,
                        _snapshot_float,
                    ),
                    :nspin => _snapshot_optional(
                        sto,
                        r,
                        "nspin_offer_per_mw_hour",
                        0.0,
                        _snapshot_float,
                    ),
                ),
            ),
        )
    end

    forward, reverse =
        parse_directional_line_limits(branch; context = "RTS24 branchdata")
    source_bus_index = Dict(x.source_label => i for (i, x) in pairs(buses))
    branches = OperationalBranch[]
    from_idx = Int[]
    to_idx = Int[]
    for r = 1:nrow(branch)
        from_label = string(branch[r, "from_bus"])
        to_label = string(branch[r, "to_bus"])
        haskey(source_bus_index, from_label) ||
            throw(ArgumentError("Unknown branch from_bus $(from_label)."))
        haskey(source_bus_index, to_label) ||
            throw(ArgumentError("Unknown branch to_bus $(to_label)."))
        x = _snapshot_float(branch[r, "X"], "branch reactance")
        x != 0 || throw(ArgumentError("Branch row $(r) has zero reactance."))
        push!(from_idx, source_bus_index[from_label])
        push!(to_idx, source_bus_index[to_label])
        push!(
            branches,
            OperationalBranch(
                id = ids["branch"][r],
                source_row = r,
                from_bus_id = bus_id[from_label],
                to_bus_id = bus_id[to_label],
                reactance = x,
                forward_limit_mw = forward[r],
                reverse_limit_mw = reverse[r],
            ),
        )
    end
    _validate_connected_network(from_idx, to_idx, length(buses))

    load_data = tables["load_timeseries_regional.csv"]
    solar = tables["solar_timeseries_regional.csv"]
    wind = tables["wind_timeseries_regional.csv"]
    T = nrow(load_data)
    nrow(solar) == T && nrow(wind) == T ||
        throw(ArgumentError("Load, solar, and wind row counts must match."))
    year = _snapshot_int(get(manifest, "calendar_year", 2021), "calendar_year")
    timestamps = _calendar_timestamps(load_data, year)

    load_mw = zeros(length(buses), T)
    for (b, x) in pairs(buses)
        x.zone in string.(names(load_data)) ||
            throw(ArgumentError("Load series is missing zone $(x.zone)."))
        load_mw[b, :] .= x.peak_load_mw .* [
            _snapshot_float(v, "load multiplier") for v in load_data[!, x.zone]
        ]
    end
    any(load_mw .< 0) && throw(ArgumentError("Derived load cannot be negative."))
    if "NI" in string.(names(load_data))
        all(iszero, [_snapshot_float(v, "NI") for v in load_data[!, "NI"]]) ||
            throw(ArgumentError("Nonzero interchange is unsupported in this first case."))
    end
    interchange_mw = zeros(length(buses), T)

    af_path = joinpath(data_dir, "gen_availability_timeseries.csv")
    af_data = isfile(af_path) ? CSV.read(af_path, DataFrame) : nothing
    availability = zeros(length(generators), T)
    for (g, x) in pairs(generators)
        source_name = "G$(x.source_row)"
        values =
            if af_data !== nothing && source_name in string.(names(af_data))
                af_data[!, source_name]
            elseif x.technology == "SolarPV"
                solar[!, x.zone]
            elseif x.technology in ("WindOn", "WindOff")
                wind[!, x.zone]
            else
                fill(x.static_availability, T)
            end
        availability[g, :] .= clamp.(
            [_snapshot_float(v, "generator availability") for v in values],
            0.0,
            1.0,
        )
    end

    single = tables["single_parameter.csv"]
    nrow(single) == 1 ||
        throw(ArgumentError("single_parameter.csv must contain one row."))
    reserve_fraction = Dict(
        :reg_up => _snapshot_float(single[1, "reg_up_requirement"], "reg up"),
        :reg_down => _snapshot_float(single[1, "reg_dn_requirement"], "reg down"),
        :spin => _snapshot_float(single[1, "spin_requirement"], "spin"),
        :nspin => _snapshot_float(single[1, "nspin_requirement"], "nspin"),
    )
    provenance = Dict(
        string(k) => string(v) for (k, v) in _manifest_dict(manifest, "provenance")
    )
    return OperationalSnapshot(
        name = string(get(manifest, "case_name", basename(case_dir))),
        generators = generators,
        storage = storage,
        buses = buses,
        branches = branches,
        timestamps = timestamps,
        load_mw = load_mw,
        availability = availability,
        interchange_mw = interchange_mw,
        reserve_requirement_fraction = reserve_fraction,
        source_hashes = observed_hashes,
        provenance = provenance,
    )
end

function _dart_network(snapshot::OperationalSnapshot; reference_bus::Int = 1)
    N = length(snapshot.buses)
    1 <= reference_bus <= N || throw(ArgumentError("Invalid reference_bus."))
    index = Dict(x.id => i for (i, x) in pairs(snapshot.buses))
    from_idx = [index[x.from_bus_id] for x in snapshot.branches]
    to_idx = [index[x.to_bus_id] for x in snapshot.branches]
    _validate_connected_network(from_idx, to_idx, N)
    ptdf = compute_ptdf_from_incidence(
        from_idx,
        to_idx,
        [x.reactance for x in snapshot.branches],
        N,
        reference_bus,
    )
    forward = [x.forward_limit_mw for x in snapshot.branches]
    reverse = [x.reverse_limit_mw for x in snapshot.branches]
    all(isapprox.(forward, reverse; atol = 1e-9, rtol = 0.0)) ||
        throw(ArgumentError("DART requires symmetric line ratings."))
    return DARTNetwork(
        bus_names = getfield.(snapshot.buses, :id),
        line_names = getfield.(snapshot.branches, :id),
        ptdf = ptdf,
        line_limit_mw = forward,
        emergency_line_limit_mw = copy(forward),
    )
end

"""
Map a snapshot to DART. Common-subset and physical-outage profiles set generic
FOR to zero. The deterministic-derated profile retains FOR and uses the PCM
effective rate for ordinary real-time energy ramps.
"""
function build_dart_system(
    snapshot::OperationalSnapshot;
    profile::Symbol = :common_subset,
    include_reserves::Bool = false,
    include_nspin::Bool = false,
    include_unit_commitment::Bool = true,
    enforce_ramps::Bool = true,
    include_storage::Bool = true,
    contingency_ids = String[],
    reference_bus::Int = 1,
)
    profile in (:common_subset, :deterministic_derated, :physical_outage) ||
        throw(ArgumentError("Unknown DART conversion profile $(profile)."))
    contingencies = Set(string.(contingency_ids))
    unknown = setdiff(contingencies, Set(getfield.(snapshot.generators, :id)))
    isempty(unknown) || throw(ArgumentError("Unknown contingency IDs: $(collect(unknown))."))

    generators = DARTGenerator[]
    for x in snapshot.generators
        ru = x.ramp_up_fraction_per_hour * x.pmax_mw
        rd = x.ramp_down_fraction_per_hour * x.pmax_mw
        for_rate = profile == :deterministic_derated ? x.forced_outage_rate : 0.0
        rt_factor = profile == :deterministic_derated ? 1.0 - x.forced_outage_rate : 1.0
        caps = Dict{Symbol,Float64}()
        if include_reserves
            for product in (:reg_up, :reg_down, :spin)
                cap = x.reserve_fraction[product] * x.pmax_mw
                profile == :deterministic_derated &&
                    (cap *= 1.0 - x.forced_outage_rate)
                caps[product] = cap
            end
            if include_nspin
                caps[:nspin] = x.nspin_capability_mw
                profile == :deterministic_derated &&
                    (caps[:nspin] *= 1.0 - x.forced_outage_rate)
            end
        end
        push!(
            generators,
            DARTGenerator(
                name = x.id,
                bus = x.bus_id,
                pmax_mw = x.pmax_mw,
                pmin_mw = include_unit_commitment ? x.pmin_mw : 0.0,
                variable_cost_per_mwh = x.variable_cost_per_mwh,
                no_load_cost_per_hour = x.no_load_cost_per_hour,
                startup_cost = x.startup_cost_per_mw * x.pmax_mw,
                shutdown_cost = x.shutdown_cost,
                ramp_up_mw_per_hour = enforce_ramps ? ru : Inf,
                ramp_down_mw_per_hour = enforce_ramps ? rd : Inf,
                real_time_ramp_up_mw_per_hour = enforce_ramps ? ru * rt_factor : Inf,
                real_time_ramp_down_mw_per_hour = enforce_ramps ? rd * rt_factor : Inf,
                startup_limit_mw = x.startup_limit_fraction * x.pmax_mw,
                shutdown_limit_mw = x.shutdown_limit_fraction * x.pmax_mw,
                min_up_hours = include_unit_commitment ? x.min_up_hours : 0,
                min_down_hours = include_unit_commitment ? x.min_down_hours : 0,
                commitment_required = include_unit_commitment && x.commitment_required,
                contingency_eligible = x.id in contingencies,
                forced_outage_rate = for_rate,
                quick_start_eligible = x.quick_start_eligible,
                quick_start_time_minutes = x.quick_start_time_minutes,
                reserve_capability_mw = caps,
                reserve_cost_per_mw_hour = copy(x.reserve_cost_per_mw_hour),
            ),
        )
    end

    storage = DARTStorage[]
    if include_storage
        for x in snapshot.storage
            capabilities = include_reserves ? copy(x.reserve_capability_mw) :
                           Dict{Symbol,Float64}()
            !include_nspin && delete!(capabilities, :nspin)
            push!(
                storage,
                DARTStorage(
                    name = x.id,
                    bus = x.bus_id,
                    energy_capacity_mwh = x.energy_capacity_mwh,
                    charge_capacity_mw = x.charge_capacity_mw,
                    discharge_capacity_mw = x.discharge_capacity_mw,
                    charge_efficiency = x.charge_efficiency,
                    discharge_efficiency = x.discharge_efficiency,
                    variable_cost_per_mwh = x.variable_cost_per_mwh,
                    reserve_capability_mw = capabilities,
                    reserve_cost_per_mw_hour = copy(x.reserve_cost_per_mw_hour),
                ),
            )
        end
    end
    return DARTSystemData(
        generators = generators,
        network = _dart_network(snapshot; reference_bus = reference_bus),
        storage = storage,
    )
end

function _service_matrix(value, rows, columns, label)
    value === nothing && return trues(rows, columns)
    matrix = Bool.(value)
    size(matrix) == (rows, columns) ||
        throw(ArgumentError("$(label) must have size $(rows) by $(columns)."))
    return matrix
end

"""
Build hourly DA and repeated five-minute RT perfect forecasts. The replication
preserves hourly energy exactly and is synthetic, not measured five-minute data.
Set `include_real_time_reserve_requirements=false` to procure requirements only
in the day-ahead market while retaining RT reserve variables for security
response.
"""
function build_dart_forecasts(
    snapshot::OperationalSnapshot,
    hours;
    rt_intervals_per_hour::Int = 12,
    include_reserves::Bool = false,
    include_real_time_reserve_requirements::Bool = include_reserves,
    include_nspin::Bool = false,
    day_ahead_generator_in_service = nothing,
    real_time_generator_in_service = nothing,
    terminal_storage_soc_mwh = nothing,
)
    selected = collect(Int.(hours))
    isempty(selected) && throw(ArgumentError("At least one hour is required."))
    all(x -> 1 <= x <= length(snapshot.timestamps), selected) ||
        throw(ArgumentError("Forecast hours are outside the snapshot."))
    all(diff(selected) .== 1) ||
        throw(ArgumentError("Forecast hours must be consecutive and ordered."))
    rt_intervals_per_hour > 0 ||
        throw(ArgumentError("rt_intervals_per_hour must be positive."))
    60 % rt_intervals_per_hour == 0 ||
        throw(ArgumentError("rt_intervals_per_hour must divide 60."))

    G = length(snapshot.generators)
    H = length(selected)
    R = rt_intervals_per_hour
    da_load = snapshot.load_mw[:, selected]
    da_availability = snapshot.availability[:, selected]
    da_interchange = snapshot.interchange_mw[:, selected]
    rt_load = repeat(da_load; inner = (1, R))
    rt_availability = repeat(da_availability; inner = (1, R))
    rt_interchange = repeat(da_interchange; inner = (1, R))
    da_service = _service_matrix(day_ahead_generator_in_service, G, H, "DA service")
    rt_service =
        _service_matrix(real_time_generator_in_service, G, H * R, "RT service")

    da_requirements = Dict{Symbol,Vector{Float64}}()
    rt_requirements = Dict{Symbol,Vector{Float64}}()
    if include_reserves || include_real_time_reserve_requirements
        products =
            include_nspin ? (:reg_up, :reg_down, :spin, :nspin) :
            (:reg_up, :reg_down, :spin)
        if include_reserves
            da_gross = vec(sum(da_load; dims = 1))
            for product in products
                fraction = snapshot.reserve_requirement_fraction[product]
                da_requirements[product] = fraction .* da_gross
            end
        end
        if include_real_time_reserve_requirements
            rt_gross = vec(sum(rt_load; dims = 1))
            for product in products
                fraction = snapshot.reserve_requirement_fraction[product]
                rt_requirements[product] = fraction .* rt_gross
            end
        end
    end

    da_timestamps = snapshot.timestamps[selected]
    step = Minute(div(60, R))
    rt_timestamps = [
        timestamp + (r - 1) * step for timestamp in da_timestamps for r = 1:R
    ]
    day_ahead = DARTForecast(
        interval_hours = 1.0,
        load_mw = da_load,
        availability = da_availability,
        generator_in_service = da_service,
        interchange_mw = da_interchange,
        reserve_requirement_mw = da_requirements,
        terminal_storage_soc_mwh = terminal_storage_soc_mwh,
    )
    real_time = DARTForecast(
        interval_hours = 1.0 / R,
        load_mw = rt_load,
        availability = rt_availability,
        generator_in_service = rt_service,
        interchange_mw = rt_interchange,
        reserve_requirement_mw = rt_requirements,
        terminal_storage_soc_mwh = terminal_storage_soc_mwh,
    )
    return DARTForecastSet(
        day_ahead = day_ahead,
        real_time = real_time,
        day_ahead_timestamps = da_timestamps,
        real_time_timestamps = rt_timestamps,
        generator_ids = getfield.(snapshot.generators, :id),
        bus_ids = getfield.(snapshot.buses, :id),
    )
end

"""
Create a pre-interval state. The default is a warm-up seed: UC units online at
Pmin, non-UC units online at zero, and storage at 50 percent. Run a warm-up
horizon and carry its final realized state into an evaluation window.
"""
function build_dart_initial_state(
    data::DARTSystemData;
    commitment = nothing,
    generation_mw = nothing,
    on_duration_hours = nothing,
    off_duration_hours = nothing,
    storage_soc_mwh = nothing,
    generator_in_service = nothing,
)
    G = length(data.generators)
    S = length(data.storage)
    commitment_value = commitment === nothing ? ones(Int, G) : Int.(commitment)
    generation_value =
        generation_mw === nothing ?
        [
            data.generators[g].commitment_required ? data.generators[g].pmin_mw : 0.0 for
            g = 1:G
        ] : Float64.(generation_mw)
    on_value =
        on_duration_hours === nothing ?
        [
            commitment_value[g] == 1 ?
            Float64(max(data.generators[g].min_up_hours, 24)) : 0.0 for g = 1:G
        ] : Float64.(on_duration_hours)
    off_value =
        off_duration_hours === nothing ?
        [
            commitment_value[g] == 0 ?
            Float64(max(data.generators[g].min_down_hours, 24)) : 0.0 for g = 1:G
        ] : Float64.(off_duration_hours)
    soc_value =
        storage_soc_mwh === nothing ?
        [0.5 * x.energy_capacity_mwh for x in data.storage] :
        Float64.(storage_soc_mwh)
    service_value =
        generator_in_service === nothing ? trues(G) : Bool.(generator_in_service)
    for (value, expected, label) in (
        (commitment_value, G, "commitment"),
        (generation_value, G, "generation"),
        (on_value, G, "on duration"),
        (off_value, G, "off duration"),
        (soc_value, S, "storage SOC"),
        (service_value, G, "service status"),
    )
        length(value) == expected ||
            throw(ArgumentError("Initial $(label) has the wrong length."))
    end
    return DARTState(
        commitment = commitment_value,
        generation_mw = generation_value,
        on_duration_hours = on_value,
        off_duration_hours = off_value,
        storage_soc_mwh = soc_value,
        generator_in_service = service_value,
    )
end

"""Select deterministic peak, ramp, and low-renewable diagnostic hours."""
function select_dart_windows(snapshot::OperationalSnapshot)
    load = vec(sum(snapshot.load_mw; dims = 1))
    vre = zeros(length(load))
    for (g, x) in pairs(snapshot.generators)
        if x.technology in ("SolarPV", "WindOn", "WindOff")
            vre .+= x.pmax_mw .* snapshot.availability[g, :]
        end
    end
    net_load = load .- vre
    return (
        peak_net_load = argmax(net_load),
        largest_net_load_ramp = argmax(abs.(diff(net_load))) + 1,
        low_renewable_availability = argmin(vre),
    )
end
