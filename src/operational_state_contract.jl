"""Versioned, immutable operational-state artifacts for chronological workflows."""

const OPERATIONAL_STATE_SCHEMA_VERSION = 1
const OPERATIONAL_STATE_ARTIFACT_TYPE = "HOPE.simulation_state"

Base.@kwdef struct OperationalStateArtifact
    schema_version::Int
    artifact_id::String
    scenario_id::String
    boundary_time::DateTime
    timezone::String
    interval_minutes::Int
    source_model::String
    initialization_method::String
    physical_system_hash::String
    parent_artifact_hashes::Dict{String,String}
    assumptions::Dict{String,String}
    generator_ids::Vector{String}
    storage_ids::Vector{String}
    state::DARTState
    path::String
end

_operational_state_hash(path::AbstractString) = bytes2hex(sha256(read(path)))

function _operational_state_nonblank(value, label)
    text = strip(string(value))
    isempty(text) && throw(ArgumentError("Operational-state $(label) cannot be blank."))
    return text
end

function _operational_state_string_dict(value, label)
    value === nothing && return Dict{String,String}()
    value isa AbstractDict ||
        throw(ArgumentError("Operational-state $(label) must be a mapping."))
    return Dict(string(key) => string(entry) for (key, entry) in value)
end

function _operational_state_datetime(value, label)
    value isa DateTime && return value
    try
        return DateTime(string(value))
    catch
        throw(
            ArgumentError(
                "Operational-state $(label) must be an ISO-8601 local DateTime without an offset.",
            ),
        )
    end
end

function _operational_state_canonical(parts::AbstractDict)
    lines = String[]
    for key in sort(collect(keys(parts)); by = string)
        value = parts[key]
        if value isa AbstractDict
            for nested in sort(collect(keys(value)); by = string)
                push!(lines, "$(key).$(nested)=$(value[nested])")
            end
        else
            push!(lines, "$(key)=$(value)")
        end
    end
    return join(lines, '\n')
end

"""
    dart_system_fingerprint(data) -> String

Return a deterministic SHA-256 identity for the DART physical system consumed
by a simulation state. The fingerprint covers stable asset and network IDs,
locations, limits, and PTDF coefficients; forecasts and operating state are not
included.
"""
function dart_system_fingerprint(data::DARTSystemData)
    parts = String[]
    for generator in data.generators
        push!(
            parts,
            join(
                (
                    "generator",
                    generator.name,
                    generator.bus,
                    generator.pmax_mw,
                    generator.pmin_mw,
                    generator.commitment_required,
                ),
                '|',
            ),
        )
    end
    for storage in data.storage
        push!(
            parts,
            join(
                (
                    "storage",
                    storage.name,
                    storage.bus,
                    storage.energy_capacity_mwh,
                    storage.charge_capacity_mw,
                    storage.discharge_capacity_mw,
                ),
                '|',
            ),
        )
    end
    network = data.network
    push!(parts, "buses|" * join(network.bus_names, '|'))
    for line in eachindex(network.line_names)
        push!(
            parts,
            join(
                (
                    "line",
                    network.line_names[line],
                    network.line_limit_mw[line],
                    network.emergency_line_limit_mw[line],
                    join(network.ptdf[line, :], ','),
                ),
                '|',
            ),
        )
    end
    return bytes2hex(sha256(join(parts, '\n')))
end

function _validate_operational_state(data::DARTSystemData, state::DARTState)
    generator_ids = getfield.(data.generators, :name)
    storage_ids = getfield.(data.storage, :name)
    length(unique(generator_ids)) == length(generator_ids) ||
        throw(ArgumentError("DART generator IDs must be unique."))
    length(unique(storage_ids)) == length(storage_ids) ||
        throw(ArgumentError("DART storage IDs must be unique."))
    G, S = length(generator_ids), length(storage_ids)
    for (values, expected, label) in (
        (state.commitment, G, "commitment"),
        (state.generation_mw, G, "generation"),
        (state.on_duration_hours, G, "on-duration"),
        (state.off_duration_hours, G, "off-duration"),
        (state.generator_in_service, G, "in-service"),
        (state.storage_soc_mwh, S, "storage-SOC"),
    )
        length(values) == expected || throw(
            ArgumentError(
                "Operational-state $(label) length $(length(values)) does not match $(expected).",
            ),
        )
    end
    all(value in (0, 1) for value in state.commitment) ||
        throw(ArgumentError("Operational-state commitment must contain only zero or one."))
    all(
        isfinite(state.generation_mw[g]) &&
            -1e-8 <= state.generation_mw[g] <= data.generators[g].pmax_mw + 1e-8 for g = 1:G
    ) || throw(ArgumentError("Operational-state generation is outside physical bounds."))
    all(value -> !isnan(value) && value >= 0, state.on_duration_hours) &&
        all(value -> !isnan(value) && value >= 0, state.off_duration_hours) ||
        throw(ArgumentError("Operational-state on/off durations must be nonnegative."))
    all(
        isfinite(state.storage_soc_mwh[s]) &&
            -1e-8 <= state.storage_soc_mwh[s] <= data.storage[s].energy_capacity_mwh + 1e-8
        for s = 1:S
    ) || throw(ArgumentError("Operational-state storage SOC is outside physical bounds."))
    return nothing
end

function _operational_state_artifact_id(metadata, file_hashes)
    identity = Dict{String,Any}(
        "schema_version" => OPERATIONAL_STATE_SCHEMA_VERSION,
        "artifact_type" => OPERATIONAL_STATE_ARTIFACT_TYPE,
        "scenario_id" => metadata["scenario_id"],
        "boundary_time" => metadata["boundary_time"],
        "timezone" => metadata["timezone"],
        "interval_minutes" => metadata["interval_minutes"],
        "source_model" => metadata["source_model"],
        "initialization_method" => metadata["initialization_method"],
        "physical_system_hash" => metadata["physical_system_hash"],
        "parent_artifact_hashes" => metadata["parent_artifact_hashes"],
        "assumptions" => metadata["assumptions"],
        "file_hashes" => file_hashes,
    )
    return bytes2hex(sha256(_operational_state_canonical(identity)))
end

"""
    write_operational_state_artifact(path, data, state; kwargs...)

Write an immutable simulation-state exchange package containing a manifest,
generator state, and storage state. Existing paths are rejected to avoid
silently replacing an artifact already referenced by another model or agent.
"""
function write_operational_state_artifact(
    path::AbstractString,
    data::DARTSystemData,
    state::DARTState;
    boundary_time,
    timezone::AbstractString = "UTC",
    interval_minutes::Integer,
    source_model::AbstractString,
    scenario_id::AbstractString,
    initialization_method::AbstractString,
    physical_system_hash::AbstractString = dart_system_fingerprint(data),
    parent_artifact_hashes = Dict{String,String}(),
    assumptions = Dict{String,String}(),
)
    _validate_operational_state(data, state)
    ispath(path) && throw(
        ArgumentError(
            "Operational-state artifact path already exists and is immutable: $(path)",
        ),
    )
    interval_minutes > 0 ||
        throw(ArgumentError("Operational-state interval_minutes must be positive."))
    timestamp = _operational_state_datetime(boundary_time, "boundary_time")
    metadata = Dict{String,Any}(
        "scenario_id" => _operational_state_nonblank(scenario_id, "scenario_id"),
        "boundary_time" => string(timestamp),
        "timezone" => _operational_state_nonblank(timezone, "timezone"),
        "interval_minutes" => Int(interval_minutes),
        "source_model" =>
            uppercase(_operational_state_nonblank(source_model, "source_model")),
        "initialization_method" => lowercase(
            _operational_state_nonblank(initialization_method, "initialization_method"),
        ),
        "physical_system_hash" => lowercase(
            _operational_state_nonblank(physical_system_hash, "physical_system_hash"),
        ),
        "parent_artifact_hashes" => _operational_state_string_dict(
            parent_artifact_hashes,
            "parent_artifact_hashes",
        ),
    )
    assumptions_dict = _operational_state_string_dict(assumptions, "assumptions")
    metadata["assumptions"] = assumptions_dict
    mkpath(path)
    generator_path = joinpath(path, "generator_state.csv")
    storage_path = joinpath(path, "storage_state.csv")
    CSV.write(
        generator_path,
        DataFrame(
            generator_id = getfield.(data.generators, :name),
            commitment = state.commitment,
            generation_mw = state.generation_mw,
            on_duration_hours = state.on_duration_hours,
            off_duration_hours = state.off_duration_hours,
            in_service = state.generator_in_service,
        ),
    )
    CSV.write(
        storage_path,
        DataFrame(
            storage_id = getfield.(data.storage, :name),
            soc_mwh = state.storage_soc_mwh,
        ),
    )
    file_hashes = Dict(
        "generator_state.csv" => _operational_state_hash(generator_path),
        "storage_state.csv" => _operational_state_hash(storage_path),
    )
    artifact_id = _operational_state_artifact_id(metadata, file_hashes)
    manifest = Dict{String,Any}(
        "schema_version" => OPERATIONAL_STATE_SCHEMA_VERSION,
        "artifact_type" => OPERATIONAL_STATE_ARTIFACT_TYPE,
        "artifact_id" => artifact_id,
        "scenario_id" => metadata["scenario_id"],
        "boundary" => Dict(
            "timestamp" => metadata["boundary_time"],
            "timezone" => metadata["timezone"],
            "interval_minutes" => metadata["interval_minutes"],
        ),
        "source" => Dict(
            "model" => metadata["source_model"],
            "initialization_method" => metadata["initialization_method"],
        ),
        "lineage" => Dict(
            "physical_system_hash" => metadata["physical_system_hash"],
            "parent_artifact_hashes" => metadata["parent_artifact_hashes"],
        ),
        "files" => Dict(
            "generator_state" => Dict(
                "path" => "generator_state.csv",
                "sha256" => file_hashes["generator_state.csv"],
                "rows" => length(data.generators),
            ),
            "storage_state" => Dict(
                "path" => "storage_state.csv",
                "sha256" => file_hashes["storage_state.csv"],
                "rows" => length(data.storage),
            ),
        ),
        "assumptions" => assumptions_dict,
    )
    open(joinpath(path, "manifest.yml"), "w") do io
        YAML.write(io, manifest)
    end
    return load_operational_state_artifact(path, data)
end

function _operational_state_manifest_mapping(parent, key)
    value = get(parent, key, nothing)
    value isa AbstractDict ||
        throw(ArgumentError("Operational-state manifest $(key) must be a mapping."))
    return Dict(string(k) => v for (k, v) in value)
end

function _operational_state_file(path, specification, label)
    relative = _operational_state_nonblank(get(specification, "path", ""), "$(label).path")
    isabspath(relative) &&
        throw(ArgumentError("Operational-state file paths must be relative."))
    resolved = normpath(joinpath(path, relative))
    root = normpath(abspath(path))
    startswith(
        lowercase(abspath(resolved)),
        lowercase(root * string(Base.Filesystem.path_separator)),
    ) || throw(
        ArgumentError("Operational-state $(label) path escapes the artifact directory."),
    )
    isfile(resolved) || throw(ArgumentError("Missing operational-state file: $(resolved)"))
    expected = lowercase(
        _operational_state_nonblank(get(specification, "sha256", ""), "$(label).sha256"),
    )
    observed = _operational_state_hash(resolved)
    observed == expected ||
        throw(ArgumentError("Operational-state hash mismatch for $(relative)."))
    return resolved, expected
end

"""
    load_operational_state_artifact(path, data; require_physical_match=true)

Validate and load a `HOPE.simulation_state` artifact for a DART physical system.
Stable IDs are used to reorder rows, so artifact row order is not significant.
"""
function load_operational_state_artifact(
    path::AbstractString,
    data::DARTSystemData;
    require_physical_match::Bool = true,
)
    manifest_path = joinpath(path, "manifest.yml")
    isfile(manifest_path) ||
        throw(ArgumentError("Missing operational-state manifest: $(manifest_path)"))
    manifest = YAML.load_file(manifest_path)
    manifest isa AbstractDict ||
        throw(ArgumentError("Operational-state manifest must be a YAML mapping."))
    version = Int(get(manifest, "schema_version", 0))
    version == OPERATIONAL_STATE_SCHEMA_VERSION || throw(
        ArgumentError(
            "Unsupported operational-state schema_version $(version); expected $(OPERATIONAL_STATE_SCHEMA_VERSION).",
        ),
    )
    string(get(manifest, "artifact_type", "")) == OPERATIONAL_STATE_ARTIFACT_TYPE || throw(
        ArgumentError(
            "Operational-state artifact_type must be $(OPERATIONAL_STATE_ARTIFACT_TYPE).",
        ),
    )
    boundary = _operational_state_manifest_mapping(manifest, "boundary")
    source = _operational_state_manifest_mapping(manifest, "source")
    lineage = _operational_state_manifest_mapping(manifest, "lineage")
    files = _operational_state_manifest_mapping(manifest, "files")
    generator_specification = _operational_state_manifest_mapping(files, "generator_state")
    storage_specification = _operational_state_manifest_mapping(files, "storage_state")
    generator_path, generator_hash =
        _operational_state_file(path, generator_specification, "generator_state")
    storage_path, storage_hash =
        _operational_state_file(path, storage_specification, "storage_state")

    physical_hash = lowercase(
        _operational_state_nonblank(
            get(lineage, "physical_system_hash", ""),
            "lineage.physical_system_hash",
        ),
    )
    observed_physical_hash = dart_system_fingerprint(data)
    require_physical_match &&
        physical_hash != observed_physical_hash &&
        throw(
            ArgumentError(
                "Operational-state physical_system_hash does not match the DART system.",
            ),
        )

    generator_table = CSV.read(generator_path, DataFrame)
    storage_table = CSV.read(storage_path, DataFrame)
    generator_ids = getfield.(data.generators, :name)
    storage_ids = getfield.(data.storage, :name)
    generator_rows = _dart_exact_rows(
        generator_table,
        :generator_id,
        generator_ids,
        "Operational generator state",
    )
    storage_rows = _dart_exact_rows(
        storage_table,
        :storage_id,
        storage_ids,
        "Operational storage state",
    )
    state = build_dart_initial_state(
        data;
        commitment = [Int(generator_rows[id].commitment) for id in generator_ids],
        generation_mw = [Float64(generator_rows[id].generation_mw) for id in generator_ids],
        on_duration_hours = [
            Float64(generator_rows[id].on_duration_hours) for id in generator_ids
        ],
        off_duration_hours = [
            Float64(generator_rows[id].off_duration_hours) for id in generator_ids
        ],
        generator_in_service = [
            _dart_bool(generator_rows[id].in_service) for id in generator_ids
        ],
        storage_soc_mwh = [Float64(storage_rows[id].soc_mwh) for id in storage_ids],
    )
    _validate_operational_state(data, state)
    metadata = Dict{String,Any}(
        "scenario_id" => _operational_state_nonblank(
            get(manifest, "scenario_id", ""),
            "scenario_id",
        ),
        "boundary_time" => string(
            _operational_state_datetime(
                get(boundary, "timestamp", ""),
                "boundary.timestamp",
            ),
        ),
        "timezone" => _operational_state_nonblank(
            get(boundary, "timezone", ""),
            "boundary.timezone",
        ),
        "interval_minutes" => Int(get(boundary, "interval_minutes", 0)),
        "source_model" => uppercase(
            _operational_state_nonblank(get(source, "model", ""), "source.model"),
        ),
        "initialization_method" => lowercase(
            _operational_state_nonblank(
                get(source, "initialization_method", ""),
                "source.initialization_method",
            ),
        ),
        "physical_system_hash" => physical_hash,
        "parent_artifact_hashes" => _operational_state_string_dict(
            get(lineage, "parent_artifact_hashes", Dict()),
            "lineage.parent_artifact_hashes",
        ),
        "assumptions" => _operational_state_string_dict(
            get(manifest, "assumptions", Dict()),
            "assumptions",
        ),
    )
    metadata["interval_minutes"] > 0 || throw(
        ArgumentError("Operational-state boundary.interval_minutes must be positive."),
    )
    file_hashes =
        Dict("generator_state.csv" => generator_hash, "storage_state.csv" => storage_hash)
    artifact_id = _operational_state_artifact_id(metadata, file_hashes)
    lowercase(string(get(manifest, "artifact_id", ""))) == artifact_id ||
        throw(ArgumentError("Operational-state artifact_id does not match its content."))
    expected_generator_rows = Int(get(generator_specification, "rows", -1))
    expected_storage_rows = Int(get(storage_specification, "rows", -1))
    expected_generator_rows == nrow(generator_table) ||
        throw(ArgumentError("Operational generator row count does not match the manifest."))
    expected_storage_rows == nrow(storage_table) ||
        throw(ArgumentError("Operational storage row count does not match the manifest."))
    return OperationalStateArtifact(
        schema_version = version,
        artifact_id = artifact_id,
        scenario_id = metadata["scenario_id"],
        boundary_time = DateTime(metadata["boundary_time"]),
        timezone = metadata["timezone"],
        interval_minutes = metadata["interval_minutes"],
        source_model = metadata["source_model"],
        initialization_method = metadata["initialization_method"],
        physical_system_hash = physical_hash,
        parent_artifact_hashes = metadata["parent_artifact_hashes"],
        assumptions = metadata["assumptions"],
        generator_ids = generator_ids,
        storage_ids = storage_ids,
        state = state,
        path = normpath(path),
    )
end
