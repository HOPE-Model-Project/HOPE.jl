"""Artifact-backed execution helpers for adaptive holistic studies."""

function _adaptive_required_file(path::AbstractString, label::AbstractString)
    resolved = abspath(path)
    isfile(resolved) || throw(ArgumentError("$(label) not found: $(resolved)"))
    return resolved
end

function _adaptive_sha256_file(path::AbstractString)
    return bytes2hex(sha256(read(path)))
end

function _adaptive_verify_file_manifest(
    directory::AbstractString,
    manifest_path::AbstractString,
)
    path = _adaptive_required_file(manifest_path, "Artifact manifest")
    manifest = YAML.load_file(path)
    manifest isa AbstractDict ||
        throw(ArgumentError("Artifact manifest must be a mapping."))
    files = get(manifest, "files", nothing)
    files isa AbstractDict ||
        throw(ArgumentError("Artifact manifest has no files mapping."))
    verified = Dict{String,String}()
    for (relative, expected) in files
        relative_path = string(relative)
        candidate = abspath(joinpath(directory, relative_path))
        relative_to_root = relpath(candidate, abspath(directory))
        startswith(relative_to_root, "..") && throw(
            ArgumentError("Artifact manifest path escapes its directory: $(relative_path)"),
        )
        _adaptive_required_file(candidate, "Manifest artifact $(relative_path)")
        actual = _adaptive_sha256_file(candidate)
        actual == string(expected) ||
            throw(ArgumentError("Artifact hash mismatch for $(candidate)."))
        verified[replace(relative_path, '\\' => '/')] = actual
    end
    return Dict(
        "path" => path,
        "sha256" => _adaptive_sha256_file(path),
        "files" => verified,
    )
end

function _adaptive_table_rows(table::AbstractDataFrame)
    return [
        Dict(string(name) => row[name] for name in propertynames(row)) for
        row in eachrow(table)
    ]
end

function _adaptive_numeric_column(table::AbstractDataFrame, name::AbstractString)
    name in names(table) || return Float64[]
    return [Float64(value) for value in table[!, name] if !ismissing(value)]
end

function _adaptive_pcm_diagnostics(ensemble_directory::AbstractString, findings)
    affected_zones = Set{String}()
    maximum_hourly_shortfall_mw = 0.0
    shedding_hours = Set{Tuple{String,Int}}()
    for row in eachrow(findings)
        variant = _feedback_text(row.Variant)
        diagnostics_path = joinpath(
            ensemble_directory,
            "members",
            variant,
            "load_shedding_diagnostics.csv",
        )
        isfile(diagnostics_path) || continue
        diagnostics = CSV.read(diagnostics_path, DataFrame)
        "LoadSheddingMW" in names(diagnostics) || continue
        for item in eachrow(diagnostics)
            shedding = Float64(item.LoadSheddingMW)
            shedding > 1.0e-9 || continue
            zone = "Zone" in names(diagnostics) ? _feedback_text(item.Zone) : ""
            !isempty(zone) && push!(affected_zones, zone)
            maximum_hourly_shortfall_mw = max(maximum_hourly_shortfall_mw, shedding)
            time_index =
                "TimeIndex" in names(diagnostics) ? Int(item.TimeIndex) :
                length(shedding_hours) + 1
            push!(shedding_hours, (zone, time_index))
        end
    end
    return Dict{String,Any}(
        "affected_zones" => sort(collect(affected_zones)),
        "load_shedding_hours" => length(shedding_hours),
        "maximum_hourly_shortfall_mw" => maximum_hourly_shortfall_mw,
    )
end

"""
    advance_adaptive_study_from_compact_artifacts(state, planning_case, ensemble_directory)

Verify and ingest one solved compact-planning case and its PCM realization
ensemble. The function records immutable GTEP, realization, and PCM artifacts,
then evaluates the ensemble with the study's pinned acceptance contract.
"""
function advance_adaptive_study_from_compact_artifacts(
    state::AbstractDict,
    planning_case::AbstractString,
    ensemble_directory::AbstractString,
)
    _validate_adaptive_state(state)
    state["stage"] == "SPECIFIED" ||
        throw(ArgumentError("Compact artifact ingestion must begin at SPECIFIED."))
    planning_root = abspath(planning_case)
    ensemble_root = abspath(ensemble_directory)
    planning_directory = joinpath(planning_root, "Planning")
    planning_manifest = _adaptive_verify_file_manifest(
        planning_directory,
        joinpath(planning_directory, "manifest.yml"),
    )
    ensemble_manifest = _adaptive_verify_file_manifest(
        ensemble_root,
        joinpath(ensemble_root, "manifest.yml"),
    )
    planning_result_path = _adaptive_required_file(
        joinpath(planning_directory, "planning_result.yml"),
        "Planning result",
    )
    project_plan_path = _adaptive_required_file(
        joinpath(planning_directory, "unitized_capacity_plan.csv"),
        "Unitized capacity plan",
    )
    planning_result = YAML.load_file(planning_result_path)
    project_plan = CSV.read(project_plan_path, DataFrame)
    findings_path = _adaptive_required_file(
        joinpath(ensemble_root, "ensemble_findings.csv"),
        "PCM ensemble findings",
    )
    findings = CSV.read(findings_path, DataFrame)
    isempty(findings) && throw(ArgumentError("PCM ensemble findings cannot be empty."))
    diagnostics = _adaptive_pcm_diagnostics(ensemble_root, findings)

    zones =
        "Zone" in names(project_plan) ? sort(unique(string.(project_plan.Zone))) : String[]
    types =
        "Type" in names(project_plan) ? sort(unique(string.(project_plan.Type))) : String[]
    gtep_artifact = Dict{String,Any}(
        "artifact_type" => "HOPE.capacity_plan",
        "schema_version" => 1,
        "iteration" => state["iteration"],
        "planning_case" => planning_root,
        "planning_manifest" => planning_manifest,
        "planning_result_path" => planning_result_path,
        "capacity_plan_path" => project_plan_path,
        "termination_status" => get(planning_result, "termination_status", nothing),
        "objective_usd" => get(planning_result, "objective_usd", nothing),
        "load_shedding_mwh" => get(planning_result, "load_shedding_mwh", nothing),
        "new_generation_mw" => get(planning_result, "new_generation_mw", nothing),
        "project_count" => nrow(project_plan),
        "build_zones" => zones,
        "resource_types" => types,
    )
    realization_artifact = Dict{String,Any}(
        "artifact_type" => "HOPE.realization_set",
        "schema_version" => 1,
        "iteration" => state["iteration"],
        "ensemble_directory" => ensemble_root,
        "ensemble_manifest" => ensemble_manifest,
        "variants" => string.(findings.Variant),
        "candidate_catalog_path" =>
            joinpath(ensemble_root, "candidate_project_catalog.csv"),
        "allocations_path" => joinpath(ensemble_root, "realization_allocations.csv"),
        "screening_path" => joinpath(ensemble_root, "realization_screening.csv"),
    )
    load_shedding = _adaptive_numeric_column(findings, "LoadSheddingMWh")
    dispatch = _adaptive_numeric_column(findings, "NewGenerationDispatchMWh")
    pcm_artifact = Dict{String,Any}(
        "artifact_type" => "HOPE.pcm_realization_ensemble_assessment",
        "schema_version" => 1,
        "iteration" => state["iteration"],
        "ensemble_directory" => ensemble_root,
        "findings_path" => findings_path,
        "findings" => _adaptive_table_rows(findings),
        "load_shedding_mwh_min" =>
            isempty(load_shedding) ? nothing : minimum(load_shedding),
        "load_shedding_mwh_max" =>
            isempty(load_shedding) ? nothing : maximum(load_shedding),
        "new_generation_dispatch_mwh_min" =>
            isempty(dispatch) ? nothing : minimum(dispatch),
        "new_generation_dispatch_mwh_max" =>
            isempty(dispatch) ? nothing : maximum(dispatch),
        diagnostics...,
    )

    current = record_adaptive_stage(state, "GTEP_SOLVED", gtep_artifact)
    current = record_adaptive_stage(current, "REALIZED", realization_artifact)
    current = record_adaptive_stage(current, "PCM_SOLVED", pcm_artifact)
    return verify_adaptive_study(current, findings)
end
