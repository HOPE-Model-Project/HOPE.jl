"""Deterministic orchestration contracts for bounded adaptive holistic studies."""

const HOLISTIC_STUDY_SCHEMA_VERSION = 1
const ADAPTIVE_STUDY_STAGES = Set([
    "SPECIFIED",
    "GTEP_SOLVED",
    "REALIZED",
    "PCM_SOLVED",
    "VERIFIED",
    "REVISION_REQUESTED",
    "REVISION_APPROVED",
])
const ADAPTIVE_STUDY_TERMINAL_STATUSES =
    Set(["ACTIVE", "ACCEPTED", "NOT_ACCEPTED", "INCONCLUSIVE"])
const ADAPTIVE_STUDY_REVISION_TYPES = Set([
    "realization_local_resiting",
    "candidate_zone_eligibility",
    "candidate_capacity_envelope",
    "transmission_interface",
    "assumption_change",
])
const ADAPTIVE_STUDY_ENSEMBLE_POLICIES = Set(["any", "all", "fraction", "worst_case"])

function _adaptive_string_dict(value::AbstractDict)
    return Dict{String,Any}(string(key) => item for (key, item) in value)
end

function _adaptive_canonical(value)
    if value isa AbstractDict
        normalized = _adaptive_string_dict(value)
        return string(
            "{",
            join(
                [
                    string(repr(key), ":", _adaptive_canonical(normalized[key])) for
                    key in sort(collect(keys(normalized)))
                ],
                ",",
            ),
            "}",
        )
    elseif value isa AbstractVector
        return string("[", join(_adaptive_canonical.(value), ","), "]")
    elseif value === nothing
        return "null"
    elseif value isa Bool
        return value ? "true" : "false"
    end
    return repr(value)
end

_adaptive_fingerprint(value) = bytes2hex(sha256(_adaptive_canonical(value)))

function _adaptive_string_list(value, field::AbstractString; allow_empty::Bool = false)
    value isa AbstractVector || throw(ArgumentError("$(field) must be a list."))
    result = String[]
    for item in value
        text = _feedback_text(item)
        isempty(text) && throw(ArgumentError("$(field) cannot contain blank values."))
        push!(result, text)
    end
    !allow_empty && isempty(result) && throw(ArgumentError("$(field) cannot be empty."))
    length(unique(result)) == length(result) ||
        throw(ArgumentError("$(field) cannot contain duplicate values."))
    return result
end

function _adaptive_bool(value, field::AbstractString)
    value isa Bool && return value
    text = lowercase(_feedback_text(value))
    text == "true" && return true
    text == "false" && return false
    throw(ArgumentError("$(field) must be boolean."))
end

"""
    validate_holistic_study_spec(spec)

Validate and normalize the version-1 adaptive-study contract. The contract pins
the scientific objective, fixed assumptions, ensemble acceptance rule, bounded
iteration budget, revision vocabulary, and human-approval boundary.
"""
function validate_holistic_study_spec(spec::AbstractDict)
    normalized = _adaptive_string_dict(spec)
    get(normalized, "schema_version", nothing) == HOLISTIC_STUDY_SCHEMA_VERSION ||
        throw(ArgumentError("Holistic study schema_version must be 1."))
    _feedback_text(get(normalized, "artifact_type", "")) == "HOPE.holistic_study_spec" ||
        throw(ArgumentError("artifact_type must be HOPE.holistic_study_spec."))
    study_id = _feedback_text(get(normalized, "study_id", ""))
    isempty(study_id) && throw(ArgumentError("study_id must be nonblank."))
    objectives = _adaptive_string_list(get(normalized, "objectives", nothing), "objectives")
    fixed_assumptions = get(normalized, "fixed_assumptions", nothing)
    fixed_assumptions isa AbstractDict ||
        throw(ArgumentError("fixed_assumptions must be a mapping."))

    acceptance = get(normalized, "acceptance", nothing)
    acceptance isa AbstractDict || throw(ArgumentError("acceptance must be a mapping."))
    acceptance = _adaptive_string_dict(acceptance)
    ensemble_policy = lowercase(_feedback_text(get(acceptance, "ensemble_policy", "")))
    ensemble_policy in ADAPTIVE_STUDY_ENSEMBLE_POLICIES || throw(
        ArgumentError(
            "acceptance.ensemble_policy must be any, all, fraction, or worst_case.",
        ),
    )
    minimum_fraction = Float64(get(acceptance, "minimum_fraction", 1.0))
    0.0 <= minimum_fraction <= 1.0 ||
        throw(ArgumentError("acceptance.minimum_fraction must be between 0 and 1."))
    ensemble_policy == "fraction" &&
        minimum_fraction <= 0.0 &&
        throw(ArgumentError("fraction acceptance requires a positive minimum_fraction."))
    acceptance["ensemble_policy"] = ensemble_policy
    acceptance["minimum_fraction"] = minimum_fraction

    iteration_budget = Int(get(normalized, "iteration_budget", 0))
    iteration_budget >= 1 || throw(ArgumentError("iteration_budget must be positive."))
    allowed_revision_types = _adaptive_string_list(
        get(normalized, "allowed_revision_types", nothing),
        "allowed_revision_types";
        allow_empty = true,
    )
    invalid_revisions = setdiff(Set(allowed_revision_types), ADAPTIVE_STUDY_REVISION_TYPES)
    isempty(invalid_revisions) || throw(
        ArgumentError(
            "Unsupported allowed_revision_types: $(join(sort(collect(invalid_revisions)), ", ")).",
        ),
    )

    approval_policy = get(normalized, "approval_policy", nothing)
    approval_policy isa AbstractDict ||
        throw(ArgumentError("approval_policy must be a mapping."))
    approval_policy = _adaptive_string_dict(approval_policy)
    require_human_for = _adaptive_string_list(
        get(approval_policy, "require_human_for", Any[]),
        "approval_policy.require_human_for";
        allow_empty = true,
    )
    isempty(setdiff(Set(require_human_for), Set(allowed_revision_types))) || throw(
        ArgumentError("Human-approval revision types must also be allowed revision types."),
    )
    if "assumption_change" in allowed_revision_types &&
       !("assumption_change" in require_human_for)
        throw(ArgumentError("assumption_change must require human approval."))
    end
    approval_policy["require_human_for"] = require_human_for

    normalized["study_id"] = study_id
    normalized["objectives"] = objectives
    normalized["fixed_assumptions"] = _adaptive_string_dict(fixed_assumptions)
    normalized["acceptance"] = acceptance
    normalized["iteration_budget"] = iteration_budget
    normalized["allowed_revision_types"] = allowed_revision_types
    normalized["approval_policy"] = approval_policy
    return normalized
end

function load_holistic_study_spec(path::AbstractString)
    isfile(path) || throw(ArgumentError("Holistic study specification not found: $(path)"))
    spec = YAML.load_file(path)
    spec isa AbstractDict ||
        throw(ArgumentError("Holistic study specification must be a YAML mapping."))
    return validate_holistic_study_spec(spec)
end

function _adaptive_history_entry(
    state::AbstractDict,
    event::AbstractString,
    from_stage,
    to_stage::AbstractString;
    details::AbstractDict = Dict{String,Any}(),
)
    return Dict{String,Any}(
        "sequence" => length(state["history"]) + 1,
        "iteration" => state["iteration"],
        "event" => String(event),
        "from_stage" => from_stage,
        "to_stage" => String(to_stage),
        "details" => deepcopy(_adaptive_string_dict(details)),
    )
end

function _adaptive_attempt(iteration::Int; parent_revision = nothing)
    return Dict{String,Any}(
        "iteration" => iteration,
        "stage" => "SPECIFIED",
        "parent_revision" => deepcopy(parent_revision),
        "artifacts" => Dict{String,Any}(),
        "verification" => nothing,
        "revision" => nothing,
    )
end

"""Create an immutable, active state artifact at the `SPECIFIED` stage."""
function initialize_adaptive_study(spec::AbstractDict)
    normalized = validate_holistic_study_spec(spec)
    state = Dict{String,Any}(
        "artifact_type" => "HOPE.adaptive_study_state",
        "schema_version" => 1,
        "study_id" => normalized["study_id"],
        "spec_sha256" => _adaptive_fingerprint(normalized),
        "spec" => deepcopy(normalized),
        "stage" => "SPECIFIED",
        "terminal_status" => "ACTIVE",
        "iteration" => 1,
        "attempts" => [_adaptive_attempt(1)],
        "approved_revision_fingerprints" => String[],
        "history" => Dict{String,Any}[],
    )
    push!(
        state["history"],
        _adaptive_history_entry(
            state,
            "initialize",
            nothing,
            "SPECIFIED";
            details = Dict("spec_sha256" => state["spec_sha256"]),
        ),
    )
    return state
end

function _validate_adaptive_state(state::AbstractDict; require_active::Bool = true)
    _feedback_text(get(state, "artifact_type", "")) == "HOPE.adaptive_study_state" ||
        throw(ArgumentError("State must be a HOPE.adaptive_study_state artifact."))
    get(state, "schema_version", nothing) == 1 ||
        throw(ArgumentError("Adaptive study state schema_version must be 1."))
    stage = _feedback_text(get(state, "stage", ""))
    stage in ADAPTIVE_STUDY_STAGES || throw(ArgumentError("Unknown study stage $(stage)."))
    terminal = _feedback_text(get(state, "terminal_status", ""))
    terminal in ADAPTIVE_STUDY_TERMINAL_STATUSES ||
        throw(ArgumentError("Unknown terminal status $(terminal)."))
    require_active &&
        terminal != "ACTIVE" &&
        throw(ArgumentError("Adaptive study is already terminal: $(terminal)."))
    validate_holistic_study_spec(state["spec"])
    return nothing
end

function _adaptive_transition(
    state::AbstractDict,
    event::AbstractString,
    expected_stage::AbstractString,
    next_stage::AbstractString;
    details::AbstractDict = Dict{String,Any}(),
)
    _validate_adaptive_state(state)
    state["stage"] == expected_stage || throw(
        ArgumentError(
            "Event $(event) requires stage $(expected_stage), not $(state["stage"]).",
        ),
    )
    next_stage in ADAPTIVE_STUDY_STAGES ||
        throw(ArgumentError("Unknown next stage $(next_stage)."))
    result = deepcopy(state)
    result["stage"] = next_stage
    result["attempts"][end]["stage"] = next_stage
    push!(
        result["history"],
        _adaptive_history_entry(
            result,
            event,
            expected_stage,
            next_stage;
            details = details,
        ),
    )
    return result
end

"""
    record_adaptive_stage(state, target_stage, artifact)

Record one immutable stage artifact. Only the ordered transitions
`SPECIFIED -> GTEP_SOLVED -> REALIZED -> PCM_SOLVED` are accepted.
"""
function record_adaptive_stage(
    state::AbstractDict,
    target_stage::AbstractString,
    artifact::AbstractDict,
)
    target = uppercase(strip(target_stage))
    transition = Dict(
        "GTEP_SOLVED" => ("SPECIFIED", "gtep"),
        "REALIZED" => ("GTEP_SOLVED", "realization"),
        "PCM_SOLVED" => ("REALIZED", "pcm"),
    )
    haskey(transition, target) ||
        throw(ArgumentError("target_stage must be GTEP_SOLVED, REALIZED, or PCM_SOLVED."))
    expected, artifact_key = transition[target]
    result = _adaptive_transition(
        state,
        "record_$(artifact_key)",
        expected,
        target;
        details = Dict("artifact_sha256" => _adaptive_fingerprint(artifact)),
    )
    result["attempts"][end]["artifacts"][artifact_key] = deepcopy(artifact)
    return result
end

function _adaptive_acceptance_rows(results)
    if results isa AbstractDataFrame
        return [
            Dict(string(name) => row[name] for name in propertynames(row)) for
            row in eachrow(results)
        ]
    end
    results isa AbstractVector ||
        throw(ArgumentError("Ensemble results must be a table or list."))
    return [_adaptive_string_dict(row) for row in results]
end

function _adaptive_member_accepted(row::AbstractDict)
    review = get(row, "HumanReviewRequired", get(row, "human_review_required", false))
    review_required =
        review === nothing ? false : _adaptive_bool(review, "human review flag")
    review_required && return false
    explicit = get(row, "Accepted", get(row, "accepted", nothing))
    explicit !== nothing && return _adaptive_bool(explicit, "accepted")
    classification = uppercase(
        _feedback_text(get(row, "Classification", get(row, "classification", ""))),
    )
    isempty(classification) && throw(
        ArgumentError("Each ensemble member must declare accepted or classification."),
    )
    return classification == "ACCEPTED"
end

function _adaptive_member_name(row::AbstractDict, index::Int)
    name =
        _feedback_text(get(row, "Variant", get(row, "variant", get(row, "member_id", ""))))
    return isempty(name) ? "member_$(index)" : name
end

"""Evaluate `any`, `all`, `fraction`, or conservative `worst_case` ensemble policy."""
function evaluate_ensemble_acceptance(results, acceptance::AbstractDict)
    rows = _adaptive_acceptance_rows(results)
    isempty(rows) && throw(ArgumentError("Ensemble results cannot be empty."))
    policy_contract = _adaptive_string_dict(acceptance)
    policy = lowercase(_feedback_text(get(policy_contract, "ensemble_policy", "")))
    policy in ADAPTIVE_STUDY_ENSEMBLE_POLICIES ||
        throw(ArgumentError("Unsupported ensemble policy $(policy)."))
    minimum_fraction = Float64(get(policy_contract, "minimum_fraction", 1.0))
    0.0 <= minimum_fraction <= 1.0 ||
        throw(ArgumentError("minimum_fraction must be between 0 and 1."))
    names = [_adaptive_member_name(row, index) for (index, row) in enumerate(rows)]
    passed = [_adaptive_member_accepted(row) for row in rows]
    accepted_count = count(identity, passed)
    fraction = accepted_count / length(rows)
    accepted = if policy == "any"
        accepted_count >= 1
    elseif policy == "fraction"
        fraction + eps(Float64) >= minimum_fraction
    else
        accepted_count == length(rows)
    end
    return Dict{String,Any}(
        "artifact_type" => "HOPE.ensemble_acceptance_result",
        "schema_version" => 1,
        "ensemble_policy" => policy,
        "minimum_fraction" => minimum_fraction,
        "accepted" => accepted,
        "member_count" => length(rows),
        "accepted_count" => accepted_count,
        "accepted_fraction" => fraction,
        "accepted_variants" => names[passed],
        "failed_variants" => names[.!passed],
        "worst_case_passed" => all(passed),
    )
end

"""Verify the PCM ensemble and apply the pinned acceptance and iteration budgets."""
function verify_adaptive_study(state::AbstractDict, ensemble_results)
    _validate_adaptive_state(state)
    state["stage"] == "PCM_SOLVED" ||
        throw(ArgumentError("Verification requires stage PCM_SOLVED."))
    verification =
        evaluate_ensemble_acceptance(ensemble_results, state["spec"]["acceptance"])
    result = _adaptive_transition(
        state,
        "verify",
        "PCM_SOLVED",
        "VERIFIED";
        details = Dict(
            "accepted" => verification["accepted"],
            "accepted_count" => verification["accepted_count"],
            "member_count" => verification["member_count"],
        ),
    )
    result["attempts"][end]["verification"] = verification
    if verification["accepted"]
        result["terminal_status"] = "ACCEPTED"
    elseif result["iteration"] >= result["spec"]["iteration_budget"]
        result["terminal_status"] = "INCONCLUSIVE"
    end
    return result
end

function _adaptive_protected_change_keys(request::AbstractDict)
    changes = get(request, "changes", Dict{String,Any}())
    changes isa AbstractDict || throw(ArgumentError("revision changes must be a mapping."))
    keys_changed = Set(string.(keys(changes)))
    protected = Set(["acceptance", "acceptance_criteria", "iteration_budget", "objectives"])
    overlap = intersect(keys_changed, protected)
    isempty(overlap) || throw(
        ArgumentError(
            "A revision cannot change pinned study controls: $(join(sort(collect(overlap)), ", ")).",
        ),
    )
    return keys_changed
end

"""Create a typed revision request without mutating the verified parent attempt."""
function request_adaptive_revision(
    state::AbstractDict,
    revision_type::AbstractString;
    request::AbstractDict = Dict{String,Any}(),
)
    _validate_adaptive_state(state)
    state["stage"] == "VERIFIED" ||
        throw(ArgumentError("Revision requests require stage VERIFIED."))
    verification = state["attempts"][end]["verification"]
    verification isa AbstractDict || throw(ArgumentError("Verified attempt has no result."))
    verification["accepted"] &&
        throw(ArgumentError("An accepted study cannot request another revision."))
    revision = lowercase(strip(revision_type))
    revision in state["spec"]["allowed_revision_types"] ||
        throw(ArgumentError("Revision type $(revision) is not allowed by the study spec."))
    changed_keys = _adaptive_protected_change_keys(request)
    fixed_keys = Set(keys(state["spec"]["fixed_assumptions"]))
    changed_fixed = intersect(changed_keys, fixed_keys)
    !isempty(changed_fixed) &&
        revision != "assumption_change" &&
        throw(
            ArgumentError(
                "Fixed assumptions may change only through assumption_change: $(join(sort(collect(changed_fixed)), ", ")).",
            ),
        )
    approval_required = revision in state["spec"]["approval_policy"]["require_human_for"]
    request_artifact = Dict{String,Any}(
        "artifact_type" => "HOPE.adaptive_revision_request",
        "schema_version" => 1,
        "request_id" => _feedback_id(
            "adaptive-revision",
            state["study_id"],
            state["iteration"],
            revision,
            _adaptive_fingerprint(request),
        ),
        "study_id" => state["study_id"],
        "iteration" => state["iteration"],
        "revision_type" => revision,
        "approval_required" => approval_required,
        "status" => approval_required ? "proposed" : "approved",
        "request" => deepcopy(_adaptive_string_dict(request)),
    )
    next_stage = approval_required ? "REVISION_REQUESTED" : "REVISION_APPROVED"
    result = _adaptive_transition(
        state,
        "request_revision",
        "VERIFIED",
        next_stage;
        details = Dict(
            "request_id" => request_artifact["request_id"],
            "revision_type" => revision,
            "approval_required" => approval_required,
        ),
    )
    result["attempts"][end]["revision"] = request_artifact
    return result
end

"""Record a human approval or rejection for the current revision request."""
function record_adaptive_revision_decision(
    state::AbstractDict,
    decision::AbstractString;
    approver::AbstractString,
    rationale::AbstractString,
)
    _validate_adaptive_state(state)
    state["stage"] == "REVISION_REQUESTED" ||
        throw(ArgumentError("A revision decision requires stage REVISION_REQUESTED."))
    normalized = lowercase(strip(decision))
    normalized in ("approved", "rejected") ||
        throw(ArgumentError("decision must be approved or rejected."))
    isempty(strip(approver)) && throw(ArgumentError("approver must be nonblank."))
    isempty(strip(rationale)) && throw(ArgumentError("rationale must be nonblank."))
    next_stage = normalized == "approved" ? "REVISION_APPROVED" : "VERIFIED"
    result = _adaptive_transition(
        state,
        "revision_$(normalized)",
        "REVISION_REQUESTED",
        next_stage;
        details = Dict("approver" => approver, "rationale" => rationale),
    )
    result["attempts"][end]["revision"]["status"] = normalized
    result["attempts"][end]["revision"]["decision"] =
        Dict("approver" => String(approver), "rationale" => String(rationale))
    return result
end

"""Start an immutable child attempt after an approved, non-cycling revision."""
function start_adaptive_child_iteration(state::AbstractDict)
    _validate_adaptive_state(state)
    state["stage"] == "REVISION_APPROVED" ||
        throw(ArgumentError("A child iteration requires stage REVISION_APPROVED."))
    result = deepcopy(state)
    if result["iteration"] >= result["spec"]["iteration_budget"]
        result["terminal_status"] = "INCONCLUSIVE"
        push!(
            result["history"],
            _adaptive_history_entry(
                result,
                "iteration_budget_exhausted",
                "REVISION_APPROVED",
                "REVISION_APPROVED",
            ),
        )
        return result
    end
    revision = result["attempts"][end]["revision"]
    fingerprint = _adaptive_fingerprint(
        Dict(
            "revision_type" => revision["revision_type"],
            "request" => revision["request"],
        ),
    )
    if fingerprint in result["approved_revision_fingerprints"]
        result["terminal_status"] = "INCONCLUSIVE"
        push!(
            result["history"],
            _adaptive_history_entry(
                result,
                "revision_cycle_detected",
                "REVISION_APPROVED",
                "REVISION_APPROVED";
                details = Dict("revision_fingerprint" => fingerprint),
            ),
        )
        return result
    end
    push!(result["approved_revision_fingerprints"], fingerprint)
    previous_iteration = result["iteration"]
    result["iteration"] = previous_iteration + 1
    result["stage"] = "SPECIFIED"
    push!(
        result["attempts"],
        _adaptive_attempt(result["iteration"]; parent_revision = revision),
    )
    push!(
        result["history"],
        _adaptive_history_entry(
            result,
            "start_child_iteration",
            "REVISION_APPROVED",
            "SPECIFIED";
            details = Dict(
                "parent_iteration" => previous_iteration,
                "request_id" => revision["request_id"],
            ),
        ),
    )
    return result
end

"""Stop an active failed study explicitly as `NOT_ACCEPTED` or `INCONCLUSIVE`."""
function stop_adaptive_study(
    state::AbstractDict,
    terminal_status::AbstractString;
    reason::AbstractString,
)
    _validate_adaptive_state(state)
    status = uppercase(strip(terminal_status))
    status in ("NOT_ACCEPTED", "INCONCLUSIVE") ||
        throw(ArgumentError("terminal_status must be NOT_ACCEPTED or INCONCLUSIVE."))
    isempty(strip(reason)) && throw(ArgumentError("reason must be nonblank."))
    result = deepcopy(state)
    result["terminal_status"] = status
    push!(
        result["history"],
        _adaptive_history_entry(
            result,
            "stop",
            result["stage"],
            result["stage"];
            details = Dict("terminal_status" => status, "reason" => reason),
        ),
    )
    return result
end

"""
    run_adaptive_study_iteration(state, handlers)

Execute one deterministic attempt through four injected handlers named `gtep`,
`realization`, `pcm`, and `verification`. The first three return artifact
mappings; verification returns the ensemble member results consumed by the
pinned acceptance policy.
"""
function run_adaptive_study_iteration(state::AbstractDict, handlers::AbstractDict)
    normalized_handlers =
        Dict{String,Any}(string(key) => value for (key, value) in handlers)
    for name in ("gtep", "realization", "pcm", "verification")
        haskey(normalized_handlers, name) ||
            throw(ArgumentError("Adaptive iteration is missing $(name) handler."))
        normalized_handlers[name] isa Function ||
            throw(ArgumentError("Adaptive handler $(name) must be callable."))
    end
    _validate_adaptive_state(state)
    state["stage"] == "SPECIFIED" ||
        throw(ArgumentError("Adaptive iteration must begin at SPECIFIED."))
    current = deepcopy(state)
    gtep_artifact = normalized_handlers["gtep"](deepcopy(current))
    gtep_artifact isa AbstractDict ||
        throw(ArgumentError("gtep handler must return a mapping."))
    current = record_adaptive_stage(current, "GTEP_SOLVED", gtep_artifact)
    realization_artifact = normalized_handlers["realization"](deepcopy(current))
    realization_artifact isa AbstractDict ||
        throw(ArgumentError("realization handler must return a mapping."))
    current = record_adaptive_stage(current, "REALIZED", realization_artifact)
    pcm_artifact = normalized_handlers["pcm"](deepcopy(current))
    pcm_artifact isa AbstractDict ||
        throw(ArgumentError("pcm handler must return a mapping."))
    current = record_adaptive_stage(current, "PCM_SOLVED", pcm_artifact)
    ensemble_results = normalized_handlers["verification"](deepcopy(current))
    return verify_adaptive_study(current, ensemble_results)
end

function write_adaptive_study_state(state::AbstractDict, output_directory::AbstractString)
    _validate_adaptive_state(state; require_active = false)
    ispath(output_directory) &&
        throw(ArgumentError("Adaptive study output already exists: $(output_directory)"))
    mkpath(output_directory)
    state_path = joinpath(output_directory, "adaptive_study_state.yml")
    YAML.write_file(state_path, deepcopy(state))
    manifest_path = joinpath(output_directory, "manifest.yml")
    YAML.write_file(
        manifest_path,
        Dict(
            "artifact_type" => "HOPE.adaptive_study_manifest",
            "schema_version" => 1,
            "study_id" => state["study_id"],
            "state_sha256" => bytes2hex(sha256(read(state_path))),
        ),
    )
    return Dict("state" => state_path, "manifest" => manifest_path)
end
