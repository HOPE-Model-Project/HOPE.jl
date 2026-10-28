"""Typed, approval-gated feedback from holistic assessments to model owners."""

const HOLISTIC_FEEDBACK_SCHEMA_VERSION = 1

_feedback_text(value) = ismissing(value) || value === nothing ? "" : strip(string(value))

function _feedback_id(prefix::AbstractString, parts...)
    canonical = join(string.(parts), "|")
    return string(prefix, "-", first(bytes2hex(sha256(canonical)), 16))
end

function _feedback_rows(assessment::AbstractDict)
    rows = get(assessment, "findings", nothing)
    rows === nothing && throw(ArgumentError("Assessment is missing findings."))
    if rows isa AbstractDataFrame
        return [
            Dict(string(name) => row[name] for name in propertynames(row)) for
            row in eachrow(rows)
        ]
    end
    rows isa AbstractVector ||
        throw(ArgumentError("Assessment findings must be a table or list."))
    return [Dict{String,Any}(string(key) => value for (key, value) in row) for row in rows]
end

function validate_feedback_policy(policy::AbstractDict)
    normalized = Dict{String,Any}(string(key) => value for (key, value) in policy)
    get(normalized, "schema_version", nothing) == HOLISTIC_FEEDBACK_SCHEMA_VERSION ||
        throw(ArgumentError("Feedback policy schema_version must be 1."))
    _feedback_text(get(normalized, "artifact_type", "")) == "HOPE.feedback_policy" ||
        throw(ArgumentError("artifact_type must be HOPE.feedback_policy."))
    max_iterations = Int(get(normalized, "max_iterations", 3))
    max_iterations >= 1 || throw(ArgumentError("max_iterations must be positive."))
    routes = get(normalized, "routes", nothing)
    routes isa AbstractDict || throw(ArgumentError("Feedback policy must declare routes."))
    for route_name in (
        "rps_slack",
        "load_shedding",
        "pcm_infeasible",
        "execution_failure",
        "generic_failure",
        "human_review",
    )
        route = get(routes, route_name, nothing)
        route isa AbstractDict ||
            throw(ArgumentError("Feedback policy is missing route $(route_name)."))
        for field in ("classification", "owner", "severity")
            isempty(_feedback_text(get(route, field, ""))) &&
                throw(ArgumentError("Route $(route_name) must declare $(field)."))
        end
    end
    normalized["max_iterations"] = max_iterations
    normalized["routes"] = Dict{String,Any}(string(key) => value for (key, value) in routes)
    return normalized
end

function load_feedback_policy(path::AbstractString)
    isfile(path) || throw(ArgumentError("Feedback policy not found: $(path)"))
    policy = YAML.load_file(path)
    policy isa AbstractDict ||
        throw(ArgumentError("Feedback policy must be a YAML mapping."))
    return validate_feedback_policy(policy)
end

function _feedback_metric(row::AbstractDict, key::AbstractString, default::Float64 = 0.0)
    value = get(row, key, default)
    (ismissing(value) || value === nothing || isempty(strip(string(value)))) &&
        return default
    parsed = tryparse(Float64, string(value))
    parsed === nothing && throw(ArgumentError("Assessment field $(key) must be numeric."))
    return parsed
end

function _feedback_route_finding(
    study_id::AbstractString,
    iteration::Int,
    route_name::AbstractString,
    route::AbstractDict,
    metric::AbstractString,
    observed::Float64,
    threshold::Float64,
    affected_variants::AbstractVector{<:AbstractString},
    distinct_realizations::Int,
    parent_artifacts::AbstractDict,
)
    minimum_distinct = Int(get(route, "minimum_distinct_realizations", 1))
    cross_realization_requirement_met = distinct_realizations >= minimum_distinct
    classification =
        cross_realization_requirement_met ? _feedback_text(route["classification"]) :
        "insufficient_cross_realization_evidence"
    responsible_owner =
        cross_realization_requirement_met ? _feedback_text(route["owner"]) : "verifier"
    inference =
        cross_realization_requirement_met ?
        _feedback_text(get(route, "inference", "Diagnosis required.")) :
        "The observation has not yet persisted across enough distinct physical realizations to justify upstream revision routing."
    finding_id = _feedback_id(
        "finding",
        study_id,
        iteration,
        route_name,
        metric,
        observed,
        threshold,
        join(sort(affected_variants), ","),
    )
    return Dict{String,Any}(
        "artifact_type" => "HOPE.finding",
        "schema_version" => 1,
        "finding_id" => finding_id,
        "study_id" => String(study_id),
        "iteration" => iteration,
        "status" => "open",
        "gate" => route_name,
        "classification" => classification,
        "severity" => _feedback_text(route["severity"]),
        "responsible_owner" => responsible_owner,
        "parent_artifacts" => deepcopy(parent_artifacts),
        "observation" => Dict(
            "metric" => metric,
            "observed" => observed,
            "threshold" => threshold,
            "affected_variants" => String.(affected_variants),
            "distinct_physical_realizations" => distinct_realizations,
            "minimum_distinct_physical_realizations" => minimum_distinct,
            "cross_realization_requirement_met" => cross_realization_requirement_met,
        ),
        "inference" => Dict(
            "statement" => inference,
            "status" => "hypothesis",
            "authority" => "nonbinding",
        ),
    )
end

function _feedback_distinct_affected(rows, predicate)
    roots = Set{String}()
    for row in rows
        predicate(row) || continue
        variant = _feedback_text(get(row, "Variant", get(row, "variant", "")))
        reused = _feedback_text(get(row, "ReusedFrom", ""))
        push!(roots, isempty(reused) ? variant : reused)
    end
    return count(value -> !isempty(value), roots)
end

"""
    build_holistic_feedback(assessment, policy; kwargs...)

Convert authoritative ensemble outcomes into aggregate findings and bounded,
approval-gated revision requests. Observations, inferred causes, and proposed
remedies remain separate. No parent artifact is modified.
"""
function build_holistic_feedback(
    assessment::AbstractDict,
    policy::AbstractDict;
    study_id::AbstractString,
    iteration::Int = 1,
    parent_artifacts::AbstractDict = Dict{String,Any}(),
)
    isempty(strip(study_id)) && throw(ArgumentError("study_id must be nonblank."))
    iteration >= 1 || throw(ArgumentError("iteration must be positive."))
    normalized_policy = validate_feedback_policy(policy)
    rows = _feedback_rows(assessment)
    thresholds = get(assessment, "thresholds", Dict{String,Any}())
    load_threshold = Float64(get(thresholds, "max_load_shedding_mwh", 1e-6))
    rps_threshold = Float64(get(thresholds, "max_rps_slack_mwh", 1e-6))
    variants =
        [_feedback_text(get(row, "Variant", get(row, "variant", ""))) for row in rows]
    findings = Dict{String,Any}[]

    rps_failed = row -> _feedback_metric(row, "RPSSlackMWh") > rps_threshold
    rps_rows = [row for row in rows if rps_failed(row)]
    if !isempty(rps_rows)
        push!(
            findings,
            _feedback_route_finding(
                study_id,
                iteration,
                "rps_slack",
                normalized_policy["routes"]["rps_slack"],
                "pcm_rps_slack_mwh",
                maximum(_feedback_metric(row, "RPSSlackMWh") for row in rps_rows),
                rps_threshold,
                [variants[index] for (index, row) in enumerate(rows) if row in rps_rows],
                _feedback_distinct_affected(rows, rps_failed),
                parent_artifacts,
            ),
        )
    end
    shedding_failed = row -> _feedback_metric(row, "LoadSheddingMWh") > load_threshold
    shedding_rows = [row for row in rows if shedding_failed(row)]
    if !isempty(shedding_rows)
        push!(
            findings,
            _feedback_route_finding(
                study_id,
                iteration,
                "load_shedding",
                normalized_policy["routes"]["load_shedding"],
                "pcm_load_shedding_mwh",
                maximum(_feedback_metric(row, "LoadSheddingMWh") for row in shedding_rows),
                load_threshold,
                [
                    variants[index] for
                    (index, row) in enumerate(rows) if row in shedding_rows
                ],
                _feedback_distinct_affected(rows, shedding_failed),
                parent_artifacts,
            ),
        )
    end
    infeasible = row -> _feedback_text(get(row, "Classification", "")) == "PCM_INFEASIBLE"
    infeasible_rows = [row for row in rows if infeasible(row)]
    if !isempty(infeasible_rows)
        push!(
            findings,
            _feedback_route_finding(
                study_id,
                iteration,
                "pcm_infeasible",
                normalized_policy["routes"]["pcm_infeasible"],
                "pcm_infeasible_realizations",
                Float64(length(infeasible_rows)),
                0.0,
                [_feedback_text(get(row, "Variant", "")) for row in infeasible_rows],
                _feedback_distinct_affected(rows, infeasible),
                parent_artifacts,
            ),
        )
    end
    execution_failure =
        row -> _feedback_text(get(row, "Classification", "")) == "MODEL_CONSTRUCTION_FAILED"
    execution_rows = [row for row in rows if execution_failure(row)]
    if !isempty(execution_rows)
        push!(
            findings,
            _feedback_route_finding(
                study_id,
                iteration,
                "execution_failure",
                normalized_policy["routes"]["execution_failure"],
                "model_construction_failed_realizations",
                Float64(length(execution_rows)),
                0.0,
                [_feedback_text(get(row, "Variant", "")) for row in execution_rows],
                _feedback_distinct_affected(rows, execution_failure),
                parent_artifacts,
            ),
        )
    end
    requires_review =
        row -> get(row, "HumanReviewRequired", false) in (true, 1, "true", "True")
    review_rows = [row for row in rows if requires_review(row)]
    if !isempty(review_rows)
        push!(
            findings,
            _feedback_route_finding(
                study_id,
                iteration,
                "human_review",
                normalized_policy["routes"]["human_review"],
                "realizations_requiring_human_review",
                Float64(length(review_rows)),
                0.0,
                [_feedback_text(get(row, "Variant", "")) for row in review_rows],
                _feedback_distinct_affected(rows, requires_review),
                parent_artifacts,
            ),
        )
    end
    nonaccepted = [
        row for row in rows if _feedback_text(get(row, "Classification", "")) != "ACCEPTED"
    ]
    if isempty(findings) && !isempty(nonaccepted)
        push!(
            findings,
            _feedback_route_finding(
                study_id,
                iteration,
                "generic_failure",
                normalized_policy["routes"]["generic_failure"],
                "unrouted_failed_realizations",
                Float64(length(nonaccepted)),
                0.0,
                [_feedback_text(get(row, "Variant", "")) for row in nonaccepted],
                length(nonaccepted),
                parent_artifacts,
            ),
        )
    end

    requests = Dict{String,Any}[]
    if iteration < normalized_policy["max_iterations"]
        for finding in findings
            route = normalized_policy["routes"][finding["gate"]]
            Bool(get(route, "revisable", true)) || continue
            Bool(finding["observation"]["cross_realization_requirement_met"]) || continue
            request_id = _feedback_id(
                "revision",
                finding["finding_id"],
                finding["responsible_owner"],
            )
            push!(
                requests,
                Dict{String,Any}(
                    "artifact_type" => "HOPE.revision_request",
                    "schema_version" => 1,
                    "request_id" => request_id,
                    "study_id" => String(study_id),
                    "iteration" => iteration,
                    "finding_ids" => [finding["finding_id"]],
                    "requested_owner" => finding["responsible_owner"],
                    "classification" => finding["classification"],
                    "parent_artifacts" => deepcopy(parent_artifacts),
                    "observed_result" => deepcopy(finding["observation"]),
                    "inferred_cause" => deepcopy(finding["inference"]),
                    "proposed_changes" => deepcopy(get(route, "proposed_changes", Any[])),
                    "allowed_actions" => deepcopy(get(route, "allowed_actions", Any[])),
                    "forbidden_actions" => deepcopy(get(route, "forbidden_actions", Any[])),
                    "approval_class" =>
                        _feedback_text(get(route, "approval_class", "none")),
                    "approval_required" => Bool(get(route, "approval_required", false)),
                    "status" => "proposed",
                ),
            )
        end
    end
    terminal_status = if isempty(findings)
        "ACCEPTED"
    elseif iteration >= normalized_policy["max_iterations"]
        "INCONCLUSIVE"
    else
        "REVISION_REQUIRED"
    end
    return Dict{String,Any}(
        "artifact_type" => "HOPE.holistic_feedback_package",
        "schema_version" => 1,
        "study_id" => String(study_id),
        "iteration" => iteration,
        "terminal_status" => terminal_status,
        "findings" => findings,
        "revision_requests" => requests,
    )
end

function record_revision_decision(
    request::AbstractDict,
    decision::AbstractString;
    approver::AbstractString,
    rationale::AbstractString,
    decided_at::AbstractString,
)
    _feedback_text(get(request, "artifact_type", "")) == "HOPE.revision_request" ||
        throw(ArgumentError("Decision target must be a HOPE.revision_request."))
    _feedback_text(get(request, "status", "")) == "proposed" ||
        throw(ArgumentError("Only a proposed revision request can be decided."))
    normalized_decision = lowercase(strip(decision))
    normalized_decision in ("approved", "rejected") ||
        throw(ArgumentError("decision must be approved or rejected."))
    isempty(strip(approver)) && throw(ArgumentError("approver must be nonblank."))
    isempty(strip(rationale)) && throw(ArgumentError("rationale must be nonblank."))
    isempty(strip(decided_at)) && throw(ArgumentError("decided_at must be nonblank."))
    return Dict{String,Any}(
        "artifact_type" => "HOPE.revision_decision",
        "schema_version" => 1,
        "decision_id" => _feedback_id(
            "decision",
            request["request_id"],
            normalized_decision,
            approver,
            decided_at,
        ),
        "request_id" => request["request_id"],
        "decision" => normalized_decision,
        "approver" => String(approver),
        "rationale" => String(rationale),
        "decided_at" => String(decided_at),
    )
end

function write_holistic_feedback_package(
    package::AbstractDict,
    output_directory::AbstractString,
)
    ispath(output_directory) &&
        throw(ArgumentError("Feedback output already exists: $(output_directory)"))
    mkpath(output_directory)
    package_path = joinpath(output_directory, "feedback_package.yml")
    findings_path = joinpath(output_directory, "findings.yml")
    requests_path = joinpath(output_directory, "revision_requests.yml")
    YAML.write_file(findings_path, Dict("findings" => package["findings"]))
    YAML.write_file(
        requests_path,
        Dict("revision_requests" => package["revision_requests"]),
    )
    YAML.write_file(
        package_path,
        Dict(
            "artifact_type" => package["artifact_type"],
            "schema_version" => package["schema_version"],
            "study_id" => package["study_id"],
            "iteration" => package["iteration"],
            "terminal_status" => package["terminal_status"],
            "finding_count" => length(package["findings"]),
            "revision_request_count" => length(package["revision_requests"]),
        ),
    )
    files = [package_path, findings_path, requests_path]
    manifest_path = joinpath(output_directory, "manifest.yml")
    YAML.write_file(
        manifest_path,
        Dict(
            "artifact_type" => "HOPE.holistic_feedback_manifest",
            "schema_version" => 1,
            "files" =>
                Dict(basename(path) => bytes2hex(sha256(read(path))) for path in files),
        ),
    )
    return Dict(
        "package" => package_path,
        "findings" => findings_path,
        "revision_requests" => requests_path,
        "manifest" => manifest_path,
    )
end
