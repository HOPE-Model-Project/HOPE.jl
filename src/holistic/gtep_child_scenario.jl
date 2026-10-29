"""Immutable, approval-gated materialization of bounded GTEP child scenarios."""

const GTEP_CHILD_SCENARIO_SCHEMA_VERSION = 1
const GTEP_CHILD_OPERATION = "qualifying_renewable_candidate_capacity_envelope"
const GTEP_CHILD_SKIPPED_DIRECTORIES =
    Set([".git", "output", "plot_output", "backup", "debug_report"])

function _child_string_dict(value, label::AbstractString)
    value isa AbstractDict || throw(ArgumentError("$(label) must be a mapping."))
    return Dict{String,Any}(string(key) => item for (key, item) in value)
end

function _child_number(value, label::AbstractString)
    parsed = tryparse(Float64, strip(string(value)))
    parsed === nothing && throw(ArgumentError("$(label) must be numeric."))
    isfinite(parsed) || throw(ArgumentError("$(label) must be finite."))
    return parsed
end

function _approved_gtep_envelope(request::AbstractDict)
    _feedback_text(get(request, "artifact_type", "")) == "HOPE.revision_request" ||
        throw(ArgumentError("Revision request must be a HOPE.revision_request."))
    _feedback_text(get(request, "status", "")) == "proposed" ||
        throw(ArgumentError("Revision request must retain proposed status."))
    _feedback_text(get(request, "requested_owner", "")) == "gtep" ||
        throw(ArgumentError("Revision request owner must be gtep."))
    Bool(get(request, "approval_required", false)) ||
        throw(ArgumentError("GTEP child revisions must require approval."))
    proposed = get(request, "proposed_changes", nothing)
    proposed isa AbstractVector ||
        throw(ArgumentError("Revision request must declare proposed_changes."))
    matches = [
        _child_string_dict(change, "proposed change") for
        change in proposed if _feedback_text(get(change, "path", "")) ==
        "gtep.resource_mix.qualifying_clean_energy"
    ]
    length(matches) == 1 || throw(
        ArgumentError(
            "Revision request must contain one qualifying-clean-energy proposed change.",
        ),
    )
    envelope = _child_string_dict(get(only(matches), "envelope", nothing), "envelope")
    maximum = _child_number(
        get(envelope, "max_additional_nameplate_mw", nothing),
        "max_additional_nameplate_mw",
    )
    maximum > 0.0 || throw(ArgumentError("max_additional_nameplate_mw must be positive."))
    return maximum
end

function _validate_revision_decision(request::AbstractDict, decision::AbstractDict)
    _feedback_text(get(decision, "artifact_type", "")) == "HOPE.revision_decision" ||
        throw(ArgumentError("Decision must be a HOPE.revision_decision."))
    _feedback_text(get(decision, "request_id", "")) ==
    _feedback_text(get(request, "request_id", "")) ||
        throw(ArgumentError("Decision request_id does not match the revision request."))
    _feedback_text(get(decision, "decision", "")) == "approved" ||
        throw(ArgumentError("Revision decision must be approved."))
    isempty(_feedback_text(get(decision, "approver", ""))) &&
        throw(ArgumentError("Approved decision is missing an approver."))
    return nothing
end

function validate_gtep_child_scenario_spec(specification::AbstractDict)
    normalized = _child_string_dict(specification, "GTEP child scenario specification")
    get(normalized, "schema_version", nothing) == GTEP_CHILD_SCENARIO_SCHEMA_VERSION ||
        throw(ArgumentError("GTEP child scenario schema_version must be 1."))
    _feedback_text(get(normalized, "artifact_type", "")) ==
    "HOPE.gtep_child_scenario_spec" ||
        throw(ArgumentError("artifact_type must be HOPE.gtep_child_scenario_spec."))
    _feedback_text(get(normalized, "operation", "")) == GTEP_CHILD_OPERATION ||
        throw(ArgumentError("Unsupported GTEP child scenario operation."))
    for field in ("request_id", "decision_id", "parent_candidate_table_sha256")
        isempty(_feedback_text(get(normalized, field, ""))) &&
            throw(ArgumentError("GTEP child scenario specification requires $(field)."))
    end
    changes = get(normalized, "changes", nothing)
    changes isa AbstractVector && !isempty(changes) ||
        throw(ArgumentError("GTEP child scenario specification requires changes."))
    seen = Set{String}()
    normalized_changes = Dict{String,Any}[]
    for change_value in changes
        change = _child_string_dict(change_value, "candidate change")
        candidate_id = _feedback_text(get(change, "candidate_id", ""))
        isempty(candidate_id) && throw(ArgumentError("candidate_id must be nonblank."))
        candidate_id in seen &&
            throw(ArgumentError("candidate_id $(candidate_id) appears more than once."))
        push!(seen, candidate_id)
        before = _child_number(get(change, "before_max_mw", nothing), "before_max_mw")
        after = _child_number(get(change, "after_max_mw", nothing), "after_max_mw")
        after > before || throw(
            ArgumentError(
                "Candidate $(candidate_id) after_max_mw must exceed before_max_mw.",
            ),
        )
        push!(
            normalized_changes,
            Dict(
                "candidate_id" => candidate_id,
                "before_max_mw" => before,
                "after_max_mw" => after,
                "rationale" => _feedback_text(get(change, "rationale", "")),
            ),
        )
    end
    normalized["changes"] = normalized_changes
    return normalized
end

function build_gtep_child_scenario_spec(
    parent_case::AbstractString,
    request::AbstractDict,
    decision::AbstractDict,
    changes::AbstractVector,
)
    _validate_revision_decision(request, decision)
    parent_path, parent_config = load_case_config_for_holistic(
        parent_case;
        context = "build_gtep_child_scenario_spec",
    )
    candidate_path =
        joinpath(parent_path, String(parent_config["DataCase"]), "gendata_candidate.csv")
    isfile(candidate_path) ||
        throw(ArgumentError("Parent GTEP candidate table not found: $(candidate_path)"))
    return validate_gtep_child_scenario_spec(
        Dict(
            "artifact_type" => "HOPE.gtep_child_scenario_spec",
            "schema_version" => 1,
            "operation" => GTEP_CHILD_OPERATION,
            "request_id" => request["request_id"],
            "decision_id" => decision["decision_id"],
            "parent_candidate_table_sha256" => bytes2hex(sha256(read(candidate_path))),
            "changes" => changes,
        ),
    )
end

function _copy_gtep_child_tree(source::AbstractString, destination::AbstractString)
    mkpath(destination)
    for entry in readdir(source)
        entry in GTEP_CHILD_SKIPPED_DIRECTORIES && continue
        source_entry = joinpath(source, entry)
        destination_entry = joinpath(destination, entry)
        if isdir(source_entry)
            _copy_gtep_child_tree(source_entry, destination_entry)
        else
            cp(source_entry, destination_entry; force = false)
        end
    end
    return destination
end

function _child_manifest(parent_case, child_case, config, request, decision)
    parent_manifest_path = joinpath(parent_case, "manifest.yml")
    parent_manifest =
        isfile(parent_manifest_path) ? YAML.load_file(parent_manifest_path) : Dict()
    parent_manifest isa AbstractDict || (parent_manifest = Dict())
    manifest = Dict{String,Any}(string(key) => value for (key, value) in parent_manifest)
    pop!(manifest, "validation", nothing)
    manifest["schema_version"] = 1
    manifest["case_name"] = basename(child_case)
    manifest["model_mode"] = "GTEP"
    manifest["data_subdir"] = String(config["DataCase"])
    manifest["source_case"] = abspath(parent_case)
    manifest["status"] = "materialized_pending_gtep_solve"
    manifest["revision_lineage"] = "Revision/lineage.yml"
    manifest["revision_request_id"] = request["request_id"]
    manifest["revision_decision_id"] = decision["decision_id"]
    manifest["validation"] =
        Dict("status" => "NOT_RUN", "parent_validation_not_inherited" => true)
    return manifest
end

"""
    materialize_approved_gtep_child_scenario(parent, request, decision, spec, child)

Create a new GTEP case with an approval-bounded increase in RPS-eligible
candidate capacity. The parent is never modified; stale output directories are
not copied; policy, load, reserve, and all other data inputs must remain
byte-identical. This function materializes a search envelope but does not run
GTEP or claim the revision fixes the downstream finding.
"""
function materialize_approved_gtep_child_scenario(
    parent_case::AbstractString,
    request::AbstractDict,
    decision::AbstractDict,
    specification::AbstractDict,
    child_case::AbstractString;
    tolerance_mw::Float64 = 1e-6,
)
    tolerance_mw > 0.0 || throw(ArgumentError("tolerance_mw must be positive."))
    child_path = abspath(child_case)
    ispath(child_path) && throw(ArgumentError("Child case already exists: $(child_path)"))
    _validate_revision_decision(request, decision)
    maximum_addition = _approved_gtep_envelope(request)
    spec = validate_gtep_child_scenario_spec(specification)
    _feedback_text(spec["request_id"]) == _feedback_text(request["request_id"]) ||
        throw(ArgumentError("Scenario specification request_id does not match."))
    _feedback_text(spec["decision_id"]) == _feedback_text(decision["decision_id"]) ||
        throw(ArgumentError("Scenario specification decision_id does not match."))
    parent_path, parent_config = load_case_config_for_holistic(
        parent_case;
        context = "materialize_approved_gtep_child_scenario",
    )
    lowercase(_feedback_text(get(parent_config, "model_mode", ""))) == "gtep" ||
        throw(ArgumentError("Parent case must use model_mode GTEP."))
    Int(get(parent_config, "inv_dcs_bin", -1)) == 0 || throw(
        ArgumentError(
            "Candidate-capacity envelope revision requires inv_dcs_bin = 0; discrete candidate rows need a separate unitization-aware operation.",
        ),
    )
    data_directory = normpath(joinpath(parent_path, String(parent_config["DataCase"])))
    candidate_path = joinpath(data_directory, "gendata_candidate.csv")
    isfile(candidate_path) ||
        throw(ArgumentError("Parent GTEP candidate table not found: $(candidate_path)"))
    candidate_hash = bytes2hex(sha256(read(candidate_path)))
    lowercase(_feedback_text(spec["parent_candidate_table_sha256"])) == candidate_hash ||
        throw(
            ArgumentError("Parent candidate table hash does not match the specification."),
        )
    candidates = CSV.read(candidate_path, DataFrame)
    _computed_require_columns(
        candidates,
        ["Candidate_ID", "Pmax (MW)", "Flag_RPS", "Type", "Zone"],
        "GTEP candidate table",
    )
    delta = DataFrame(
        CandidateID = String[],
        Zone = String[],
        Type = String[],
        BeforeMaxMW = Float64[],
        AfterMaxMW = Float64[],
        AdditionalMaxMW = Float64[],
        Rationale = String[],
    )
    revised = copy(candidates)
    for change in spec["changes"]
        candidate_id = change["candidate_id"]
        rows = findall(
            value -> _feedback_text(value) == candidate_id,
            revised[!, "Candidate_ID"],
        )
        length(rows) == 1 || throw(
            ArgumentError(
                "Candidate $(candidate_id) must identify exactly one parent row.",
            ),
        )
        row = only(rows)
        _computed_bool(revised[row, "Flag_RPS"], false) || throw(
            ArgumentError("Candidate $(candidate_id) is not RPS eligible (Flag_RPS != 1)."),
        )
        actual_before = _child_number(revised[row, "Pmax (MW)"], "Pmax (MW)")
        expected_before = Float64(change["before_max_mw"])
        isapprox(actual_before, expected_before; atol = tolerance_mw, rtol = 0.0) || throw(
            ArgumentError(
                "Candidate $(candidate_id) expected before_max_mw=$(expected_before), found $(actual_before).",
            ),
        )
        after = Float64(change["after_max_mw"])
        revised[row, "Pmax (MW)"] = after
        push!(
            delta,
            (
                candidate_id,
                _feedback_text(revised[row, "Zone"]),
                _feedback_text(revised[row, "Type"]),
                actual_before,
                after,
                after - actual_before,
                _feedback_text(change["rationale"]),
            ),
        )
    end
    total_addition = sum(delta.AdditionalMaxMW)
    total_addition <= maximum_addition + tolerance_mw || throw(
        ArgumentError(
            "Requested candidate-capacity increase $(total_addition) MW exceeds approved envelope $(maximum_addition) MW.",
        ),
    )
    parent_fingerprint = holistic_case_fingerprint(parent_path, parent_config)

    _copy_gtep_child_tree(parent_path, child_path)
    child_data_directory = normpath(joinpath(child_path, String(parent_config["DataCase"])))
    child_candidate_path = joinpath(child_data_directory, "gendata_candidate.csv")
    CSV.write(child_candidate_path, revised)
    revision_directory = joinpath(child_path, "Revision")
    mkpath(revision_directory)
    parent_manifest_path = joinpath(parent_path, "manifest.yml")
    isfile(parent_manifest_path) && cp(
        parent_manifest_path,
        joinpath(revision_directory, "parent_manifest.yml");
        force = false,
    )
    request_path = joinpath(revision_directory, "revision_request.yml")
    decision_path = joinpath(revision_directory, "revision_decision.yml")
    spec_path = joinpath(revision_directory, "child_scenario_spec.yml")
    delta_path = joinpath(revision_directory, "candidate_capacity_delta.csv")
    YAML.write_file(request_path, request)
    YAML.write_file(decision_path, decision)
    YAML.write_file(spec_path, spec)
    CSV.write(delta_path, delta)

    child_fingerprint = holistic_case_fingerprint(child_path, parent_config)
    candidate_relative =
        replace(relpath(child_candidate_path, child_data_directory), '\\' => '/')
    parent_keys = Set(keys(parent_fingerprint))
    child_keys = Set(keys(child_fingerprint))
    parent_keys == child_keys ||
        throw(ArgumentError("Child data-file set differs from the parent data-file set."))
    changed_files = sort([
        key for key in parent_keys if parent_fingerprint[key] != child_fingerprint[key]
    ])
    changed_files == [candidate_relative] || throw(
        ArgumentError(
            "Only gendata_candidate.csv may change; changed files=$(join(changed_files, ", ")).",
        ),
    )
    lineage = Dict{String,Any}(
        "artifact_type" => "HOPE.gtep_child_scenario_lineage",
        "schema_version" => 1,
        "status" => "materialized_pending_gtep_solve",
        "parent_case" => abspath(parent_path),
        "child_case" => child_path,
        "request_id" => request["request_id"],
        "decision_id" => decision["decision_id"],
        "operation" => GTEP_CHILD_OPERATION,
        "approved_max_additional_nameplate_mw" => maximum_addition,
        "materialized_additional_nameplate_mw" => total_addition,
        "changed_data_files" => changed_files,
        "parent_candidate_table_sha256" => candidate_hash,
        "child_candidate_table_sha256" => child_fingerprint[candidate_relative],
        "protected_data_files_unchanged" => true,
        "gtep_run_status" => "NOT_RUN",
    )
    lineage_path = joinpath(revision_directory, "lineage.yml")
    YAML.write_file(lineage_path, lineage)
    YAML.write_file(
        joinpath(child_path, "manifest.yml"),
        _child_manifest(parent_path, child_path, parent_config, request, decision),
    )
    evidence_files = [request_path, decision_path, spec_path, delta_path, lineage_path]
    evidence_manifest_path = joinpath(revision_directory, "manifest.yml")
    YAML.write_file(
        evidence_manifest_path,
        Dict(
            "artifact_type" => "HOPE.gtep_child_scenario_manifest",
            "schema_version" => 1,
            "files" => Dict(
                basename(path) => bytes2hex(sha256(read(path))) for path in evidence_files
            ),
        ),
    )
    return Dict{String,Any}(
        "child_case" => child_path,
        "lineage" => lineage,
        "delta" => delta,
        "paths" => Dict(
            "lineage" => lineage_path,
            "delta" => delta_path,
            "manifest" => evidence_manifest_path,
        ),
    )
end
