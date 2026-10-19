"""PCM-to-DART operational-state conversion with explicit stable-ID matching."""

"""Solver-neutral PCM trajectory retained long enough to publish boundary state."""
Base.@kwdef struct PCMOperationalTrace
    generator_ids::Vector{String}
    storage_ids::Vector{String}
    hours::Vector{Int}
    generation_mw::Matrix{Float64}
    commitment::Dict{String,Vector{Float64}}
    storage_soc_mwh::Matrix{Float64}
end

function _pcm_state_object(model::JuMP.Model, name::Symbol)
    haskey(JuMP.object_dictionary(model), name) ||
        throw(ArgumentError("Solved PCM model does not contain variable $(name)."))
    return model[name]
end

function _pcm_state_value(variable, label::AbstractString)
    numeric = try
        Float64(JuMP.value(variable))
    catch error
        detail = sprint(showerror, error)
        throw(
            ArgumentError(
                "PCM state conversion could not read the solved value for $(label). " *
                "Keep the solved model alive until the state artifact is written. " *
                "Solver detail: $(detail)",
            ),
        )
    end
    isfinite(numeric) || throw(ArgumentError("PCM state value for $(label) is not finite."))
    return numeric
end

function _pcm_state_id_rows(table::AbstractDataFrame, column::AbstractString, ids, label)
    isempty(ids) && return Dict{String,Int}()
    column in names(table) || throw(
        ArgumentError(
            "$(label) requires stable ID column $(column); implicit row-number transfer is refused.",
        ),
    )
    observed = [value === missing ? "" : strip(string(value)) for value in table[!, column]]
    all(value -> !isempty(value), observed) ||
        throw(ArgumentError("$(label) contains blank stable IDs."))
    length(unique(observed)) == length(observed) ||
        throw(ArgumentError("$(label) contains duplicate stable IDs."))
    rows = Dict(id => row for (row, id) in pairs(observed))
    missing_ids = sort([id for id in ids if !haskey(rows, id)])
    extra_ids = sort([id for id in observed if !(id in Set(ids))])
    isempty(missing_ids) && isempty(extra_ids) || throw(
        ArgumentError(
            "$(label) IDs do not exactly match the target DART system; " *
            "missing=$(join(missing_ids, ',')); extra=$(join(extra_ids, ',')).",
        ),
    )
    return rows
end

function _pcm_state_source_ids(
    table::AbstractDataFrame,
    column::AbstractString,
    label::AbstractString,
)
    column in names(table) || throw(
        ArgumentError(
            "$(label) requires stable ID column $(column); implicit row-number transfer is refused.",
        ),
    )
    ids = [value === missing ? "" : strip(string(value)) for value in table[!, column]]
    all(value -> !isempty(value), ids) ||
        throw(ArgumentError("$(label) contains blank stable IDs."))
    length(unique(ids)) == length(ids) ||
        throw(ArgumentError("$(label) contains duplicate stable IDs."))
    return ids
end

"""
    capture_pcm_operational_trace(pcm_config, pcm_input, pcm_model; kwargs...)

Copy the PCM variables needed at any downstream boundary into solver-neutral
arrays. HOPE calls this immediately after a PCM solve because some commercial
solver handles do not retain queryable results after their run scope exits.
"""
function capture_pcm_operational_trace(
    pcm_config::AbstractDict,
    pcm_input::AbstractDict,
    pcm_model::JuMP.Model;
    generator_id_column::AbstractString = "Asset_ID",
    storage_id_column::AbstractString = "Asset_ID",
)
    uppercase(string(get(pcm_config, "model_mode", ""))) == "PCM" ||
        throw(ArgumentError("PCM trace capture requires model_mode: PCM."))
    gendata = pcm_input["Gendata"]
    storagedata = pcm_input["Storagedata"]
    generator_ids =
        _pcm_state_source_ids(gendata, generator_id_column, "PCM generator state")
    storage_ids = _pcm_state_source_ids(storagedata, storage_id_column, "PCM storage state")

    p = _pcm_state_object(pcm_model, :p)
    hours = Int.(collect(axes(p, 2)))
    isempty(hours) && throw(ArgumentError("PCM state trace requires a nonempty horizon."))
    generation_mw = Matrix{Float64}(undef, length(generator_ids), length(hours))
    for row in eachindex(generator_ids), (column, hour) in pairs(hours)
        generation_mw[row, column] = _pcm_state_value(
            p[row, hour],
            "generator $(generator_ids[row]) at hour $(hour)",
        )
    end

    commitment = Dict{String,Vector{Float64}}()
    uc_mode = _snapshot_int(get(pcm_config, "unit_commitment", 0), "unit_commitment")
    if uc_mode == 1
        "Flag_UC" in names(gendata) ||
            throw(ArgumentError("PCM integer commitment requires Gendata.Flag_UC."))
        o = _pcm_state_object(pcm_model, :o)
        for row in eachindex(generator_ids)
            _snapshot_int(gendata[row, "Flag_UC"], "Flag_UC") == 1 || continue
            commitment[generator_ids[row]] = [
                _pcm_state_value(
                    o[row, hour],
                    "commitment for $(generator_ids[row]) at hour $(hour)",
                ) for hour in hours
            ]
        end
    end

    storage_soc_mwh = Matrix{Float64}(undef, length(storage_ids), length(hours))
    if !isempty(storage_ids)
        soc = _pcm_state_object(pcm_model, :soc)
        for row in eachindex(storage_ids), (column, hour) in pairs(hours)
            storage_soc_mwh[row, column] = _pcm_state_value(
                soc[row, hour],
                "storage SOC for $(storage_ids[row]) at hour $(hour)",
            )
        end
    end
    return PCMOperationalTrace(
        generator_ids = generator_ids,
        storage_ids = storage_ids,
        hours = hours,
        generation_mw = generation_mw,
        commitment = commitment,
        storage_soc_mwh = storage_soc_mwh,
    )
end

function maybe_capture_pcm_operational_trace(
    pcm_config::AbstractDict,
    pcm_input::AbstractDict,
    pcm_model::JuMP.Model;
    generator_id_column::AbstractString = "Asset_ID",
    storage_id_column::AbstractString = "Asset_ID",
)
    gendata = pcm_input["Gendata"]
    storagedata = pcm_input["Storagedata"]
    generator_id_column in names(gendata) || return nothing
    storage_id_column in names(storagedata) || return nothing
    return try
        capture_pcm_operational_trace(
            pcm_config,
            pcm_input,
            pcm_model;
            generator_id_column = generator_id_column,
            storage_id_column = storage_id_column,
        )
    catch error
        @warn "PCM solve succeeded, but its optional operational-state trace could not be captured." exception =
            (error, catch_backtrace())
        nothing
    end
end

function _pcm_state_commitment_value(value, id, hour; tolerance)
    numeric = Float64(value)
    rounded = round(Int, numeric)
    abs(numeric - rounded) <= tolerance && rounded in (0, 1) || throw(
        ArgumentError(
            "PCM commitment for $(id) at hour $(hour) is $(numeric), not a binary unit state.",
        ),
    )
    return rounded
end

function _pcm_state_duration(history, status, interval_hours)
    duration = 0.0
    for value in Iterators.reverse(history)
        value == status || break
        duration += interval_hours
    end
    return duration
end

function _validate_pcm_operational_trace(trace::PCMOperationalTrace)
    isempty(trace.hours) && throw(ArgumentError("PCM state trace has an empty horizon."))
    issorted(trace.hours) && length(unique(trace.hours)) == length(trace.hours) ||
        throw(ArgumentError("PCM state trace hours must be unique and ordered."))
    size(trace.generation_mw) == (length(trace.generator_ids), length(trace.hours)) ||
        throw(ArgumentError("PCM state trace generation dimensions are inconsistent."))
    size(trace.storage_soc_mwh) == (length(trace.storage_ids), length(trace.hours)) ||
        throw(ArgumentError("PCM state trace storage dimensions are inconsistent."))
    all(id -> id in trace.generator_ids, keys(trace.commitment)) ||
        throw(ArgumentError("PCM state trace contains an unknown commitment ID."))
    all(length(entries) == length(trace.hours) for entries in values(trace.commitment)) ||
        throw(ArgumentError("PCM state trace commitment dimensions are inconsistent."))
    return nothing
end

"""
    build_pcm_operational_state(pcm_config, pcm_input, pcm_model, dart_system; kwargs...)

Convert one solved PCM boundary to a `DARTState`. Generator and storage rows
must match the target DART system through explicit stable-ID columns. Integer,
unit-level commitment is required for commitment-enabled DART generators;
relaxed and clustered commitment are rejected because they do not identify a
physical unit state.
"""
function build_pcm_operational_state(
    pcm_config::AbstractDict,
    pcm_input::AbstractDict,
    pcm_model::JuMP.Model,
    dart_system::DARTSystemData;
    boundary_hour::Integer,
    interval_hours::Real = 1.0,
    generator_id_column::AbstractString = "Asset_ID",
    storage_id_column::AbstractString = "Asset_ID",
    generator_in_service = nothing,
    integrality_tolerance::Real = 1e-6,
)
    trace = capture_pcm_operational_trace(
        pcm_config,
        pcm_input,
        pcm_model;
        generator_id_column = generator_id_column,
        storage_id_column = storage_id_column,
    )
    return build_pcm_operational_state(
        pcm_config,
        pcm_input,
        trace,
        dart_system;
        boundary_hour = boundary_hour,
        interval_hours = interval_hours,
        generator_id_column = generator_id_column,
        storage_id_column = storage_id_column,
        generator_in_service = generator_in_service,
        integrality_tolerance = integrality_tolerance,
    )
end

function build_pcm_operational_state(
    pcm_config::AbstractDict,
    pcm_input::AbstractDict,
    trace::PCMOperationalTrace,
    dart_system::DARTSystemData;
    boundary_hour::Integer,
    interval_hours::Real = 1.0,
    generator_id_column::AbstractString = "Asset_ID",
    storage_id_column::AbstractString = "Asset_ID",
    generator_in_service = nothing,
    integrality_tolerance::Real = 1e-6,
)
    uppercase(string(get(pcm_config, "model_mode", ""))) == "PCM" ||
        throw(ArgumentError("PCM state conversion requires model_mode: PCM."))
    interval_hours > 0 || throw(ArgumentError("interval_hours must be positive."))
    boundary_hour > 0 || throw(ArgumentError("boundary_hour must be positive."))
    isfinite(integrality_tolerance) && integrality_tolerance >= 0 ||
        throw(ArgumentError("integrality_tolerance must be finite and nonnegative."))
    _validate_pcm_operational_trace(trace)

    gendata = pcm_input["Gendata"]
    storagedata = pcm_input["Storagedata"]
    generation_ids = getfield.(dart_system.generators, :name)
    storage_ids = getfield.(dart_system.storage, :name)
    generator_rows = _pcm_state_id_rows(
        gendata,
        generator_id_column,
        generation_ids,
        "PCM generator state",
    )
    _pcm_state_id_rows(storagedata, storage_id_column, storage_ids, "PCM storage state")
    trace.generator_ids ==
    _pcm_state_source_ids(gendata, generator_id_column, "PCM generator trace") ||
        throw(ArgumentError("PCM generator trace does not match the supplied PCM input."))
    trace.storage_ids ==
    _pcm_state_source_ids(storagedata, storage_id_column, "PCM storage trace") ||
        throw(ArgumentError("PCM storage trace does not match the supplied PCM input."))
    boundary_column = findfirst(==(Int(boundary_hour)), trace.hours)
    boundary_column === nothing && throw(
        ArgumentError(
            "boundary_hour $(boundary_hour) is not present in the captured PCM horizon " *
            "$(first(trace.hours)):$(last(trace.hours)).",
        ),
    )
    uc_mode = _snapshot_int(get(pcm_config, "unit_commitment", 0), "unit_commitment")
    any_target_uc = any(getfield.(dart_system.generators, :commitment_required))
    any_target_uc &&
        uc_mode != 1 &&
        throw(
            ArgumentError(
                "Commitment-enabled DART generators require integer PCM unit_commitment: 1; " *
                "mode $(uc_mode) cannot provide a physical binary state.",
            ),
        )
    clustered_units, _, _ = pcm_clustered_uc_parameters(Dict(pcm_config), gendata)
    trace_generator_rows = Dict(id => row for (row, id) in pairs(trace.generator_ids))
    trace_storage_rows = Dict(id => row for (row, id) in pairs(trace.storage_ids))

    commitment = Int[]
    generation_mw = Float64[]
    on_duration_hours = Float64[]
    off_duration_hours = Float64[]
    for generator in dart_system.generators
        row = generator_rows[generator.name]
        trace_row = trace_generator_rows[generator.name]
        output = trace.generation_mw[trace_row, boundary_column]
        isfinite(output) ||
            throw(ArgumentError("PCM generation for $(generator.name) is not finite."))
        push!(generation_mw, output)
        if generator.commitment_required
            clustered_units[row] == 1 || throw(
                ArgumentError(
                    "PCM row for $(generator.name) represents $(clustered_units[row]) units; " *
                    "a unit-level operational state cannot be inferred.",
                ),
            )
            haskey(trace.commitment, generator.name) || throw(
                ArgumentError(
                    "PCM trace is missing commitment values for $(generator.name).",
                ),
            )
            history = [
                _pcm_state_commitment_value(
                    trace.commitment[generator.name][column],
                    generator.name,
                    trace.hours[column];
                    tolerance = integrality_tolerance,
                ) for column = 1:boundary_column
            ]
            status = last(history)
            duration = _pcm_state_duration(history, status, Float64(interval_hours))
            push!(commitment, status)
            push!(on_duration_hours, status == 1 ? duration : 0.0)
            push!(off_duration_hours, status == 0 ? duration : 0.0)
        else
            push!(commitment, 1)
            push!(on_duration_hours, Inf)
            push!(off_duration_hours, 0.0)
        end
    end

    storage_soc_mwh = Float64[]
    if !isempty(storage_ids)
        for storage in dart_system.storage
            value = trace.storage_soc_mwh[trace_storage_rows[storage.name], boundary_column]
            isfinite(value) ||
                throw(ArgumentError("PCM storage SOC for $(storage.name) is not finite."))
            push!(storage_soc_mwh, value)
        end
    end

    service = if generator_in_service === nothing
        trues(length(generation_ids))
    else
        generator_in_service isa AbstractDict || throw(
            ArgumentError("generator_in_service must be a stable-ID mapping or nothing."),
        )
        service_map = Dict(
            string(id) => _dart_bool(value) for (id, value) in generator_in_service
        )
        supplied = Set(keys(service_map))
        supplied == Set(generation_ids) || throw(
            ArgumentError(
                "generator_in_service IDs must exactly match the target DART generators.",
            ),
        )
        Bool[service_map[id] for id in generation_ids]
    end
    all(
        service[g] || abs(generation_mw[g]) <= integrality_tolerance for
        g in eachindex(service)
    ) ||
        throw(ArgumentError("An out-of-service PCM generator has nonzero boundary output."))
    state = DARTState(
        commitment = commitment,
        generation_mw = generation_mw,
        on_duration_hours = on_duration_hours,
        off_duration_hours = off_duration_hours,
        storage_soc_mwh = storage_soc_mwh,
        generator_in_service = service,
    )
    _validate_operational_state(dart_system, state)
    return state
end

"""
    write_pcm_operational_state_artifact(path, pcm_config, pcm_input, pcm_model,
                                         dart_system; kwargs...)

Build and publish an immutable `HOPE.simulation_state` artifact from a solved
PCM boundary. Forecasts, bids, reserve rules, and prices are intentionally not
transferred.
"""
function write_pcm_operational_state_artifact(
    path::AbstractString,
    pcm_config::AbstractDict,
    pcm_input::AbstractDict,
    pcm_source::Union{JuMP.Model,PCMOperationalTrace},
    dart_system::DARTSystemData;
    boundary_hour::Integer,
    boundary_time,
    timezone::AbstractString,
    scenario_id::AbstractString,
    interval_minutes::Integer = 60,
    generator_id_column::AbstractString = "Asset_ID",
    storage_id_column::AbstractString = "Asset_ID",
    generator_in_service = nothing,
    parent_artifact_hashes = Dict{String,String}(),
    assumptions = Dict{String,String}(),
)
    interval_minutes == 60 || throw(
        ArgumentError(
            "PCM artifacts use the preceding hourly PCM interval, so interval_minutes must be 60.",
        ),
    )
    state = build_pcm_operational_state(
        pcm_config,
        pcm_input,
        pcm_source,
        dart_system;
        boundary_hour = boundary_hour,
        interval_hours = interval_minutes / 60,
        generator_id_column = generator_id_column,
        storage_id_column = storage_id_column,
        generator_in_service = generator_in_service,
    )
    recorded_assumptions = Dict{String,String}(
        "duration_semantics" => "consecutive solved PCM intervals; left-censored at the PCM horizon start",
        "service_status_default" =>
            generator_in_service === nothing ?
            "all generators in service; PCM FOR is not an outage realization" :
            "explicit stable-ID service mapping",
        "excluded_information" => "forecasts, prices, bids, reserve rules, policies, and settlement assumptions",
    )
    merge!(recorded_assumptions, _operational_state_string_dict(assumptions, "assumptions"))
    return write_operational_state_artifact(
        path,
        dart_system,
        state;
        boundary_time = boundary_time,
        timezone = timezone,
        interval_minutes = interval_minutes,
        source_model = "PCM",
        scenario_id = scenario_id,
        initialization_method = "preceding_run",
        parent_artifact_hashes = parent_artifact_hashes,
        assumptions = recorded_assumptions,
    )
end

"""
    write_pcm_operational_state_artifact(path, pcm_result, dart_system; kwargs...)

Convenience overload for either a standalone PCM `run_hope` result or a
`run_hope_holistic` result. Boundary selection remains explicit.
"""
function write_pcm_operational_state_artifact(
    path::AbstractString,
    pcm_result::AbstractDict,
    dart_system::DARTSystemData;
    kwargs...,
)
    standalone_keys = ("config", "input", "solved_model")
    holistic_keys = ("pcm_config", "pcm_input", "pcm_solved_model")
    values = if all(key -> haskey(pcm_result, key), standalone_keys)
        trace = get(pcm_result, "operational_state_trace", nothing)
        source = trace isa PCMOperationalTrace ? trace : pcm_result["solved_model"]
        (pcm_result["config"], pcm_result["input"], source)
    elseif all(key -> haskey(pcm_result, key), holistic_keys)
        trace = get(pcm_result, "pcm_operational_state_trace", nothing)
        source = trace isa PCMOperationalTrace ? trace : pcm_result["pcm_solved_model"]
        (pcm_result["pcm_config"], pcm_result["pcm_input"], source)
    else
        throw(
            ArgumentError(
                "PCM result must come from run_hope (config/input/solved_model) " *
                "or run_hope_holistic (pcm_config/pcm_input/pcm_solved_model).",
            ),
        )
    end
    return write_pcm_operational_state_artifact(
        path,
        values[1],
        values[2],
        values[3],
        dart_system;
        kwargs...,
    )
end
