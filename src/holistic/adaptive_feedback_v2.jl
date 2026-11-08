"""Evidence, diagnosis, and controlled-revision contracts for adaptive studies."""

const ADAPTIVE_FEEDBACK_V2_SCHEMA_VERSION = 2

const ADAPTIVE_FAILURE_CLASSES = Set([
    "SOLVER_FAILURE",
    "PLANNING_CAPACITY_DEFICIT",
    "SPATIAL_CAPACITY_MISMATCH",
    "REALIZATION_SITING_INFEASIBLE",
    "TRANSMISSION_CONGESTION",
    "OPERATIONAL_FLEXIBILITY_DEFICIT",
    "POLICY_OR_EMISSIONS_VIOLATION",
    "ACCEPTANCE_FAILED_OTHER",
])

const ADAPTIVE_ACTION_CATALOG = Dict{String,Dict{String,Any}}(
    "change_generation_candidate_zone_eligibility" => Dict(
        "owner" => "gtep",
        "revision_type" => "candidate_zone_eligibility",
        "parameter" => "allowed_generation_candidate_zones",
        "approval_required" => true,
        "classifications" => ["SPATIAL_CAPACITY_MISMATCH"],
    ),
    "change_candidate_technology_eligibility" => Dict(
        "owner" => "gtep",
        "revision_type" => "assumption_change",
        "parameter" => "allowed_generation_candidate_types",
        "approval_required" => true,
        "classifications" => [
            "PLANNING_CAPACITY_DEFICIT",
            "OPERATIONAL_FLEXIBILITY_DEFICIT",
            "POLICY_OR_EMISSIONS_VIOLATION",
        ],
    ),
    "revise_firm_capacity_envelope" => Dict(
        "owner" => "gtep",
        "revision_type" => "candidate_capacity_envelope",
        "parameter" => "firm_capacity_envelope_mw",
        "approval_required" => true,
        "classifications" => ["PLANNING_CAPACITY_DEFICIT"],
    ),
    "request_realization_alternatives" => Dict(
        "owner" => "realization",
        "revision_type" => "realization_local_resiting",
        "parameter" => "realization_variant_policy",
        "approval_required" => false,
        "classifications" => ["REALIZATION_SITING_INFEASIBLE"],
    ),
    "enable_storage_flexibility_candidate" => Dict(
        "owner" => "gtep",
        "revision_type" => "assumption_change",
        "parameter" => "storage_candidates_enabled",
        "approval_required" => true,
        "classifications" => ["OPERATIONAL_FLEXIBILITY_DEFICIT"],
    ),
    "enable_transmission_candidate" => Dict(
        "owner" => "gtep",
        "revision_type" => "transmission_interface",
        "parameter" => "transmission_candidates_enabled",
        "approval_required" => true,
        "classifications" => ["SPATIAL_CAPACITY_MISMATCH", "TRANSMISSION_CONGESTION"],
    ),
    "escalate_assumption_change" => Dict(
        "owner" => "coordinator",
        "revision_type" => "assumption_change",
        "parameter" => "assumption_change",
        "approval_required" => true,
        "classifications" => sort(collect(ADAPTIVE_FAILURE_CLASSES)),
    ),
)

function _adaptive_v2_dict(value, field::AbstractString)
    value isa AbstractDict || throw(ArgumentError("$(field) must be a mapping."))
    return _adaptive_string_dict(value)
end

function _adaptive_v2_nonnegative(value, field::AbstractString)
    value === nothing && return nothing
    ismissing(value) && return nothing
    number = try
        Float64(value)
    catch
        throw(ArgumentError("$(field) must be numeric or null."))
    end
    number >= 0.0 || throw(ArgumentError("$(field) cannot be negative."))
    return number
end

function _adaptive_v2_paths(values, field::AbstractString; allow_empty::Bool = true)
    values isa AbstractVector || throw(ArgumentError("$(field) must be a list."))
    paths = String[]
    for value in values
        path = _feedback_text(value)
        isempty(path) && throw(ArgumentError("$(field) cannot contain blank paths."))
        push!(paths, path)
    end
    !allow_empty && isempty(paths) && throw(ArgumentError("$(field) cannot be empty."))
    return sort(unique(paths))
end

function _adaptive_v2_attempt(state::AbstractDict, iteration::Int)
    attempts = get(state, "attempts", nothing)
    attempts isa AbstractVector || throw(ArgumentError("Adaptive state has no attempts."))
    matches = [
        attempt for attempt in attempts if
        attempt isa AbstractDict && Int(get(attempt, "iteration", 0)) == iteration
    ]
    length(matches) == 1 || throw(
        ArgumentError("Adaptive state must contain exactly one iteration $(iteration)."),
    )
    return _adaptive_string_dict(only(matches))
end

function _adaptive_v2_manifest_hashes(artifact::AbstractDict)
    hashes = Dict{String,String}()
    for key in ("planning_manifest", "ensemble_manifest")
        manifest = get(artifact, key, nothing)
        manifest isa AbstractDict || continue
        sha = _feedback_text(get(manifest, "sha256", ""))
        path = _feedback_text(get(manifest, "path", ""))
        !isempty(sha) && (hashes[isempty(path) ? key : path] = sha)
    end
    return hashes
end

function _adaptive_v2_source_paths(artifact::AbstractDict, fields)
    paths = String[]
    for field in fields
        path = _feedback_text(get(artifact, field, ""))
        !isempty(path) && push!(paths, path)
    end
    return sort(unique(paths))
end

function _adaptive_v2_missing_fields(layer::AbstractDict, fields)
    return sort([
        String(field) for field in fields if
        !haskey(layer, field) || layer[field] === nothing || ismissing(layer[field])
    ])
end

function _adaptive_v2_solver_statuses(pcm::AbstractDict)
    findings = get(pcm, "findings", Any[])
    findings isa AbstractVector || return String[]
    statuses = String[]
    for finding in findings
        finding isa AbstractDict || continue
        status = _feedback_text(get(finding, "TerminationStatus", ""))
        !isempty(status) && push!(statuses, status)
    end
    return sort(unique(statuses))
end

"""
    build_adaptive_evidence_v2(state; iteration=state["iteration"])

Adapt one recorded adaptive-study attempt into the standard v2 evidence contract.
Unavailable metrics remain explicit `nothing` values and are listed in each layer's
`missing_fields`; they are never silently inferred.
"""
function build_adaptive_evidence_v2(
    state::AbstractDict;
    iteration::Int = Int(get(state, "iteration", 0)),
)
    iteration >= 1 || throw(ArgumentError("iteration must be positive."))
    study_id = _feedback_text(get(state, "study_id", ""))
    isempty(study_id) && throw(ArgumentError("Adaptive state must declare study_id."))
    attempt = _adaptive_v2_attempt(state, iteration)
    artifacts = _adaptive_v2_dict(
        get(attempt, "artifacts", Dict{String,Any}()),
        "attempt.artifacts",
    )
    gtep = _adaptive_v2_dict(get(artifacts, "gtep", Dict()), "artifacts.gtep")
    realization =
        _adaptive_v2_dict(get(artifacts, "realization", Dict()), "artifacts.realization")
    pcm = _adaptive_v2_dict(get(artifacts, "pcm", Dict()), "artifacts.pcm")
    verification =
        _adaptive_v2_dict(get(attempt, "verification", Dict()), "attempt.verification")

    planning_paths =
        _adaptive_v2_source_paths(gtep, ("planning_result_path", "capacity_plan_path"))
    realization_paths = _adaptive_v2_source_paths(
        realization,
        ("candidate_catalog_path", "allocations_path", "screening_path"),
    )
    pcm_paths = _adaptive_v2_source_paths(pcm, ("findings_path",))

    planning = Dict{String,Any}(
        "artifact_type" => "HOPE.adaptive_planning_evidence",
        "solver" => Dict(
            "termination_status" => get(gtep, "termination_status", nothing),
            "objective_usd" => get(gtep, "objective_usd", nothing),
        ),
        "capacity_additions" => Dict(
            "total_mw" => get(gtep, "new_generation_mw", nothing),
            "zones" => String.(get(gtep, "build_zones", String[])),
            "technologies" => String.(get(gtep, "resource_types", String[])),
            "project_count" => get(gtep, "project_count", nothing),
        ),
        "planning_load_shedding_mwh" => get(gtep, "load_shedding_mwh", nothing),
        "reserve_position_mw" => get(gtep, "reserve_position_mw", nothing),
        "binding_constraints" => String.(get(gtep, "binding_constraints", String[])),
        "evidence_paths" => planning_paths,
    )
    planning["missing_fields"] = _adaptive_v2_missing_fields(
        planning,
        ("planning_load_shedding_mwh", "reserve_position_mw"),
    )

    realization_layer = Dict{String,Any}(
        "artifact_type" => "HOPE.adaptive_realization_evidence",
        "planned_capacity_mw" => get(gtep, "new_generation_mw", nothing),
        "placed_capacity_mw" => get(realization, "placed_capacity_mw", nothing),
        "unplaced_capacity_mw" => get(realization, "unplaced_capacity_mw", nothing),
        "variants" => String.(get(realization, "variants", String[])),
        "selected_sites" => deepcopy(get(realization, "selected_sites", Any[])),
        "rejection_reasons" => deepcopy(get(realization, "rejection_reasons", Any[])),
        "siting_flags" => deepcopy(get(realization, "siting_flags", Dict())),
        "evidence_paths" => realization_paths,
    )
    realization_layer["missing_fields"] = _adaptive_v2_missing_fields(
        realization_layer,
        ("placed_capacity_mw", "unplaced_capacity_mw"),
    )

    pcm_layer = Dict{String,Any}(
        "artifact_type" => "HOPE.adaptive_pcm_evidence",
        "solver_statuses" => _adaptive_v2_solver_statuses(pcm),
        "load_shedding" => Dict(
            "minimum_mwh" => get(pcm, "load_shedding_mwh_min", nothing),
            "maximum_mwh" => get(pcm, "load_shedding_mwh_max", nothing),
            "affected_zones" => String.(get(pcm, "affected_zones", String[])),
            "hours" => get(pcm, "load_shedding_hours", nothing),
            "maximum_hourly_shortfall_mw" =>
                get(pcm, "maximum_hourly_shortfall_mw", nothing),
        ),
        "reserve_shortage_mwh" => get(pcm, "reserve_shortage_mwh", nothing),
        "congestion" => deepcopy(get(pcm, "congestion", Dict())),
        "flexibility" => deepcopy(get(pcm, "flexibility", Dict())),
        "policy_violations" => deepcopy(get(pcm, "policy_violations", Any[])),
        "new_resource_dispatch_mwh" => Dict(
            "minimum" => get(pcm, "new_generation_dispatch_mwh_min", nothing),
            "maximum" => get(pcm, "new_generation_dispatch_mwh_max", nothing),
        ),
        "accepted_variants" =>
            String.(get(verification, "accepted_variants", String[])),
        "accepted_count" => Int(get(verification, "accepted_count", 0)),
        "evidence_paths" => pcm_paths,
    )
    pcm_layer["missing_fields"] =
        _adaptive_v2_missing_fields(pcm_layer, ("reserve_shortage_mwh",))

    source_hashes =
        merge(_adaptive_v2_manifest_hashes(gtep), _adaptive_v2_manifest_hashes(realization))
    evidence = Dict{String,Any}(
        "artifact_type" => "HOPE.adaptive_evidence",
        "schema_version" => ADAPTIVE_FEEDBACK_V2_SCHEMA_VERSION,
        "evidence_id" => _feedback_id(
            "adaptive-evidence",
            study_id,
            iteration,
            _adaptive_fingerprint(artifacts),
        ),
        "study_id" => study_id,
        "iteration" => iteration,
        "planning" => planning,
        "realization" => realization_layer,
        "pcm" => pcm_layer,
        "sources" => Dict(
            "paths" => sort(unique(vcat(planning_paths, realization_paths, pcm_paths))),
            "manifest_sha256" => source_hashes,
        ),
    )
    return validate_adaptive_evidence_v2(evidence)
end

"""Validate and normalize a v2 adaptive evidence artifact."""
function validate_adaptive_evidence_v2(evidence::AbstractDict)
    normalized = _adaptive_string_dict(evidence)
    _feedback_text(get(normalized, "artifact_type", "")) == "HOPE.adaptive_evidence" ||
        throw(ArgumentError("artifact_type must be HOPE.adaptive_evidence."))
    get(normalized, "schema_version", nothing) == ADAPTIVE_FEEDBACK_V2_SCHEMA_VERSION ||
        throw(ArgumentError("Adaptive evidence schema_version must be 2."))
    isempty(_feedback_text(get(normalized, "evidence_id", ""))) &&
        throw(ArgumentError("Adaptive evidence must declare evidence_id."))
    isempty(_feedback_text(get(normalized, "study_id", ""))) &&
        throw(ArgumentError("Adaptive evidence must declare study_id."))
    Int(get(normalized, "iteration", 0)) >= 1 ||
        throw(ArgumentError("Adaptive evidence iteration must be positive."))

    planning = _adaptive_v2_dict(get(normalized, "planning", nothing), "planning")
    realization = _adaptive_v2_dict(get(normalized, "realization", nothing), "realization")
    pcm = _adaptive_v2_dict(get(normalized, "pcm", nothing), "pcm")
    sources = _adaptive_v2_dict(get(normalized, "sources", nothing), "sources")
    for (layer_name, layer, required) in (
        (
            "planning",
            planning,
            (
                "solver",
                "capacity_additions",
                "planning_load_shedding_mwh",
                "reserve_position_mw",
                "binding_constraints",
                "evidence_paths",
                "missing_fields",
            ),
        ),
        (
            "realization",
            realization,
            (
                "planned_capacity_mw",
                "placed_capacity_mw",
                "unplaced_capacity_mw",
                "variants",
                "selected_sites",
                "rejection_reasons",
                "siting_flags",
                "evidence_paths",
                "missing_fields",
            ),
        ),
        (
            "pcm",
            pcm,
            (
                "solver_statuses",
                "load_shedding",
                "reserve_shortage_mwh",
                "congestion",
                "flexibility",
                "policy_violations",
                "new_resource_dispatch_mwh",
                "accepted_variants",
                "accepted_count",
                "evidence_paths",
                "missing_fields",
            ),
        ),
    )
        missing = [field for field in required if !haskey(layer, field)]
        isempty(missing) || throw(
            ArgumentError("$(layer_name) evidence is missing: $(join(missing, ", "))."),
        )
        _adaptive_v2_paths(layer["evidence_paths"], "$(layer_name).evidence_paths")
        _adaptive_string_list(
            layer["missing_fields"],
            "$(layer_name).missing_fields";
            allow_empty = true,
        )
    end
    additions = _adaptive_v2_dict(planning["capacity_additions"], "capacity_additions")
    for field in ("total_mw",)
        haskey(additions, field) ||
            throw(ArgumentError("planning.capacity_additions must declare $(field)."))
        _adaptive_v2_nonnegative(additions[field], "capacity_additions.$(field)")
    end
    _adaptive_v2_nonnegative(
        planning["planning_load_shedding_mwh"],
        "planning_load_shedding_mwh",
    )
    _adaptive_v2_nonnegative(realization["planned_capacity_mw"], "planned_capacity_mw")
    _adaptive_v2_nonnegative(realization["placed_capacity_mw"], "placed_capacity_mw")
    _adaptive_v2_nonnegative(realization["unplaced_capacity_mw"], "unplaced_capacity_mw")
    load_shedding = _adaptive_v2_dict(pcm["load_shedding"], "pcm.load_shedding")
    for field in (
        "minimum_mwh",
        "maximum_mwh",
        "affected_zones",
        "hours",
        "maximum_hourly_shortfall_mw",
    )
        haskey(load_shedding, field) ||
            throw(ArgumentError("pcm.load_shedding must declare $(field)."))
    end
    _adaptive_v2_nonnegative(load_shedding["minimum_mwh"], "load_shedding.minimum_mwh")
    _adaptive_v2_nonnegative(load_shedding["maximum_mwh"], "load_shedding.maximum_mwh")
    _adaptive_v2_paths(sources["paths"], "sources.paths")
    normalized["planning"] = planning
    normalized["realization"] = realization
    normalized["pcm"] = pcm
    normalized["sources"] = sources
    return normalized
end

function _adaptive_v2_nonempty_signal(value)
    value === nothing && return false
    value isa AbstractDict &&
        return any(_adaptive_v2_nonempty_signal(item) for item in values(value))
    value isa AbstractVector &&
        return any(_adaptive_v2_nonempty_signal(item) for item in value)
    value isa Bool && return value
    value isa Number && return value > 0
    return !isempty(_feedback_text(value))
end

"""
    diagnose_adaptive_failure_v2(evidence; thresholds=Dict())

Classify a failed adaptive attempt using ordered, auditable rules. The function
returns `NO_FAILURE` only when an accepted realization is already recorded.
"""
function diagnose_adaptive_failure_v2(
    evidence::AbstractDict;
    thresholds::AbstractDict = Dict{String,Any}(),
)
    normalized = validate_adaptive_evidence_v2(evidence)
    limits = merge(
        Dict{String,Any}(
            "max_load_shedding_mwh" => 1.0e-6,
            "max_unplaced_capacity_mw" => 1.0e-6,
            "max_reserve_shortage_mwh" => 1.0e-6,
        ),
        _adaptive_string_dict(thresholds),
    )
    planning = normalized["planning"]
    realization = normalized["realization"]
    pcm = normalized["pcm"]
    accepted_count = Int(pcm["accepted_count"])
    classification = nothing
    responsible_layer = "coordinator"
    rule = "accepted_realization_present"

    planning_solver = _adaptive_v2_dict(planning["solver"], "planning.solver")
    solver_statuses = vcat(
        [_feedback_text(get(planning_solver, "termination_status", ""))],
        String.(pcm["solver_statuses"]),
    )
    solver_statuses = [uppercase(status) for status in solver_statuses if !isempty(status)]
    successful_statuses = Set(["OPTIMAL", "LOCALLY_SOLVED", "FEASIBLE_POINT"])
    solver_failed = any(status -> !(status in successful_statuses), solver_statuses)

    unplaced = realization["unplaced_capacity_mw"]
    unplaced_failed =
        unplaced !== nothing &&
        Float64(unplaced) > Float64(limits["max_unplaced_capacity_mw"])
    planning_shedding = planning["planning_load_shedding_mwh"]
    reserve_position = planning["reserve_position_mw"]
    planning_deficit =
        (
            planning_shedding !== nothing &&
            Float64(planning_shedding) > Float64(limits["max_load_shedding_mwh"])
        ) || (reserve_position !== nothing && Float64(reserve_position) < 0.0)
    shedding = _adaptive_v2_dict(pcm["load_shedding"], "pcm.load_shedding")
    maximum_shedding = get(shedding, "maximum_mwh", nothing)
    pcm_shedding_failed =
        maximum_shedding !== nothing &&
        Float64(maximum_shedding) > Float64(limits["max_load_shedding_mwh"])
    build_zones = Set(String.(planning["capacity_additions"]["zones"]))
    affected_zones = Set(String.(shedding["affected_zones"]))
    spatial_mismatch =
        pcm_shedding_failed &&
        !isempty(build_zones) &&
        !isempty(affected_zones) &&
        isempty(intersect(build_zones, affected_zones))
    reserve_shortage = pcm["reserve_shortage_mwh"]
    flexibility_failed =
        _adaptive_v2_nonempty_signal(pcm["flexibility"]) || (
            reserve_shortage !== nothing &&
            Float64(reserve_shortage) > Float64(limits["max_reserve_shortage_mwh"])
        )
    congestion_failed = _adaptive_v2_nonempty_signal(pcm["congestion"])
    policy_failed = _adaptive_v2_nonempty_signal(pcm["policy_violations"])

    if accepted_count > 0
        # Keep the explicit no-failure outcome.
    elseif solver_failed
        classification = "SOLVER_FAILURE"
        responsible_layer = "runtime"
        rule = "unsuccessful_solver_status"
    elseif unplaced_failed
        classification = "REALIZATION_SITING_INFEASIBLE"
        responsible_layer = "realization"
        rule = "unplaced_capacity_exceeds_threshold"
    elseif planning_deficit
        classification = "PLANNING_CAPACITY_DEFICIT"
        responsible_layer = "gtep"
        rule = "planning_adequacy_failed"
    elseif spatial_mismatch
        classification = "SPATIAL_CAPACITY_MISMATCH"
        responsible_layer = "gtep"
        rule = "planning_build_and_pcm_shortfall_zones_are_disjoint"
    elseif congestion_failed
        classification = "TRANSMISSION_CONGESTION"
        responsible_layer = "gtep"
        rule = "pcm_congestion_evidence_present"
    elseif flexibility_failed
        classification = "OPERATIONAL_FLEXIBILITY_DEFICIT"
        responsible_layer = "gtep"
        rule = "pcm_flexibility_or_reserve_shortage_evidence_present"
    elseif policy_failed
        classification = "POLICY_OR_EMISSIONS_VIOLATION"
        responsible_layer = "gtep"
        rule = "pcm_policy_violation_evidence_present"
    else
        classification = "ACCEPTANCE_FAILED_OTHER"
        responsible_layer = "coordinator"
        rule = "failed_acceptance_without_more_specific_evidence"
    end

    signals = Dict{String,Any}(
        "solver_statuses" => solver_statuses,
        "planning_build_zones" => sort(collect(build_zones)),
        "pcm_affected_zones" => sort(collect(affected_zones)),
        "pcm_load_shedding_mwh_max" => maximum_shedding,
        "planning_load_shedding_mwh" => planning_shedding,
        "unplaced_capacity_mw" => unplaced,
        "accepted_count" => accepted_count,
    )
    status = classification === nothing ? "NO_FAILURE" : "FAILURE_CLASSIFIED"
    summary =
        classification === nothing ?
        "At least one realization is accepted; no revision is indicated." :
        "$(classification) assigned by rule $(rule)."
    diagnosis = Dict{String,Any}(
        "artifact_type" => "HOPE.adaptive_diagnosis",
        "schema_version" => ADAPTIVE_FEEDBACK_V2_SCHEMA_VERSION,
        "diagnosis_id" => _feedback_id(
            "adaptive-diagnosis",
            normalized["evidence_id"],
            status,
            classification,
            rule,
        ),
        "study_id" => normalized["study_id"],
        "iteration" => normalized["iteration"],
        "evidence_id" => normalized["evidence_id"],
        "status" => status,
        "classification" => classification,
        "responsible_layer" => responsible_layer,
        "rule" => rule,
        "summary" => summary,
        "signals" => signals,
        "evidence_paths" => deepcopy(normalized["sources"]["paths"]),
    )
    return validate_adaptive_diagnosis_v2(diagnosis)
end

"""Validate and normalize a v2 adaptive diagnosis artifact."""
function validate_adaptive_diagnosis_v2(diagnosis::AbstractDict)
    normalized = _adaptive_string_dict(diagnosis)
    _feedback_text(get(normalized, "artifact_type", "")) == "HOPE.adaptive_diagnosis" ||
        throw(ArgumentError("artifact_type must be HOPE.adaptive_diagnosis."))
    get(normalized, "schema_version", nothing) == ADAPTIVE_FEEDBACK_V2_SCHEMA_VERSION ||
        throw(ArgumentError("Adaptive diagnosis schema_version must be 2."))
    for field in ("diagnosis_id", "study_id", "evidence_id", "status", "rule", "summary")
        isempty(_feedback_text(get(normalized, field, ""))) &&
            throw(ArgumentError("Adaptive diagnosis must declare $(field)."))
    end
    status = _feedback_text(normalized["status"])
    status in ("NO_FAILURE", "FAILURE_CLASSIFIED") ||
        throw(ArgumentError("Diagnosis status must be NO_FAILURE or FAILURE_CLASSIFIED."))
    classification = get(normalized, "classification", nothing)
    if status == "NO_FAILURE"
        classification === nothing ||
            throw(ArgumentError("NO_FAILURE diagnosis cannot declare a failure class."))
    else
        _feedback_text(classification) in ADAPTIVE_FAILURE_CLASSES ||
            throw(ArgumentError("Unknown adaptive failure classification."))
    end
    _adaptive_v2_dict(get(normalized, "signals", nothing), "diagnosis.signals")
    normalized["evidence_paths"] = _adaptive_v2_paths(
        get(normalized, "evidence_paths", nothing),
        "diagnosis.evidence_paths",
    )
    return normalized
end

"""Return a copy of the initial authorized action catalog."""
adaptive_action_catalog_v2() = deepcopy(ADAPTIVE_ACTION_CATALOG)

"""
    build_adaptive_revision_proposal_v2(diagnosis, evidence; kwargs...)

Construct the smallest catalog-authorized intervention supported by a diagnosis.
The proposal is inert until it is validated, requested, and (when required)
approved through the adaptive-study state machine.
"""
function build_adaptive_revision_proposal_v2(
    diagnosis::AbstractDict,
    evidence::AbstractDict;
    action::AbstractString,
    old_value,
    proposed_value,
    held_fixed::AbstractVector,
    expected_causal_effect::AbstractString,
    stop_condition::AbstractString,
    maximum_iterations::Int,
    rollback_strategy::AbstractString = "restore_parent_state",
)
    normalized_diagnosis = validate_adaptive_diagnosis_v2(diagnosis)
    normalized_evidence = validate_adaptive_evidence_v2(evidence)
    normalized_diagnosis["status"] == "FAILURE_CLASSIFIED" ||
        throw(ArgumentError("A revision proposal requires a classified failure."))
    normalized_diagnosis["evidence_id"] == normalized_evidence["evidence_id"] ||
        throw(ArgumentError("Diagnosis and evidence IDs do not match."))
    action_name = lowercase(strip(action))
    haskey(ADAPTIVE_ACTION_CATALOG, action_name) ||
        throw(ArgumentError("Unknown adaptive action $(action_name)."))
    catalog = ADAPTIVE_ACTION_CATALOG[action_name]
    classification = normalized_diagnosis["classification"]
    classification in catalog["classifications"] || throw(
        ArgumentError("Action $(action_name) is not authorized for $(classification)."),
    )
    current_iteration = Int(normalized_evidence["iteration"])
    maximum_iterations >= current_iteration ||
        throw(ArgumentError("maximum_iterations cannot precede the current iteration."))
    fixed = _adaptive_string_list(held_fixed, "held_fixed"; allow_empty = false)
    parameter = String(catalog["parameter"])
    parameter in fixed &&
        throw(ArgumentError("The changed parameter cannot also be held fixed."))
    _adaptive_canonical(old_value) == _adaptive_canonical(proposed_value) &&
        throw(ArgumentError("A revision must change the parameter value."))
    isempty(strip(expected_causal_effect)) &&
        throw(ArgumentError("expected_causal_effect must be nonblank."))
    isempty(strip(stop_condition)) &&
        throw(ArgumentError("stop_condition must be nonblank."))
    isempty(strip(rollback_strategy)) &&
        throw(ArgumentError("rollback_strategy must be nonblank."))

    proposal = Dict{String,Any}(
        "artifact_type" => "HOPE.adaptive_revision_proposal",
        "schema_version" => ADAPTIVE_FEEDBACK_V2_SCHEMA_VERSION,
        "proposal_id" => _feedback_id(
            "adaptive-proposal",
            normalized_diagnosis["diagnosis_id"],
            action_name,
            parameter,
            _adaptive_fingerprint(proposed_value),
        ),
        "study_id" => normalized_evidence["study_id"],
        "iteration" => current_iteration,
        "diagnosis_id" => normalized_diagnosis["diagnosis_id"],
        "evidence_id" => normalized_evidence["evidence_id"],
        "classification" => classification,
        "action" => action_name,
        "requested_owner" => catalog["owner"],
        "revision_type" => catalog["revision_type"],
        "change" => Dict(
            "parameter" => parameter,
            "old_value" => deepcopy(old_value),
            "proposed_value" => deepcopy(proposed_value),
        ),
        "held_fixed" => fixed,
        "evidence_paths" => deepcopy(normalized_diagnosis["evidence_paths"]),
        "expected_causal_effect" => String(expected_causal_effect),
        "approval_required" => Bool(catalog["approval_required"]),
        "iteration_budget" => Dict(
            "current" => current_iteration,
            "maximum" => maximum_iterations,
            "remaining_after_child" =>
                max(maximum_iterations - current_iteration - 1, 0),
        ),
        "stop_condition" => String(stop_condition),
        "rollback" => Dict(
            "strategy" => String(rollback_strategy),
            "parent_evidence_id" => normalized_evidence["evidence_id"],
        ),
        "status" => "proposed",
    )
    return validate_adaptive_revision_proposal_v2(proposal)
end

"""Validate and normalize a catalog-backed v2 revision proposal."""
function validate_adaptive_revision_proposal_v2(proposal::AbstractDict)
    normalized = _adaptive_string_dict(proposal)
    _feedback_text(get(normalized, "artifact_type", "")) ==
    "HOPE.adaptive_revision_proposal" ||
        throw(ArgumentError("artifact_type must be HOPE.adaptive_revision_proposal."))
    get(normalized, "schema_version", nothing) == ADAPTIVE_FEEDBACK_V2_SCHEMA_VERSION ||
        throw(ArgumentError("Adaptive revision proposal schema_version must be 2."))
    for field in (
        "proposal_id",
        "study_id",
        "diagnosis_id",
        "evidence_id",
        "classification",
        "action",
        "requested_owner",
        "revision_type",
        "expected_causal_effect",
        "stop_condition",
        "status",
    )
        isempty(_feedback_text(get(normalized, field, ""))) &&
            throw(ArgumentError("Adaptive revision proposal must declare $(field)."))
    end
    normalized["status"] == "proposed" ||
        throw(ArgumentError("A new revision proposal must have status proposed."))
    classification = _feedback_text(normalized["classification"])
    classification in ADAPTIVE_FAILURE_CLASSES ||
        throw(ArgumentError("Unknown adaptive failure classification."))
    action = _feedback_text(normalized["action"])
    haskey(ADAPTIVE_ACTION_CATALOG, action) ||
        throw(ArgumentError("Unknown adaptive action $(action)."))
    catalog = ADAPTIVE_ACTION_CATALOG[action]
    classification in catalog["classifications"] ||
        throw(ArgumentError("Action $(action) is not authorized for $(classification)."))
    normalized["requested_owner"] == catalog["owner"] ||
        throw(ArgumentError("Revision owner does not match the action catalog."))
    normalized["revision_type"] == catalog["revision_type"] ||
        throw(ArgumentError("Revision type does not match the action catalog."))
    Bool(get(normalized, "approval_required", false)) ==
    Bool(catalog["approval_required"]) ||
        throw(ArgumentError("Approval requirement does not match the action catalog."))
    change = _adaptive_v2_dict(get(normalized, "change", nothing), "proposal.change")
    _feedback_text(get(change, "parameter", "")) == catalog["parameter"] ||
        throw(ArgumentError("Changed parameter does not match the action catalog."))
    haskey(change, "old_value") && haskey(change, "proposed_value") ||
        throw(ArgumentError("Revision change must declare old and proposed values."))
    _adaptive_canonical(change["old_value"]) ==
    _adaptive_canonical(change["proposed_value"]) &&
        throw(ArgumentError("A revision must change the parameter value."))
    held_fixed = _adaptive_string_list(normalized["held_fixed"], "held_fixed")
    catalog["parameter"] in held_fixed &&
        throw(ArgumentError("The changed parameter cannot also be held fixed."))
    normalized["evidence_paths"] = _adaptive_v2_paths(
        normalized["evidence_paths"],
        "proposal.evidence_paths";
        allow_empty = false,
    )
    budget = _adaptive_v2_dict(
        get(normalized, "iteration_budget", nothing),
        "proposal.iteration_budget",
    )
    current = Int(get(budget, "current", 0))
    maximum = Int(get(budget, "maximum", 0))
    current >= 1 && maximum >= current ||
        throw(ArgumentError("Revision iteration budget is invalid."))
    Int(get(normalized, "iteration", 0)) == current ||
        throw(ArgumentError("Proposal iteration must match its budget current value."))
    rollback = _adaptive_v2_dict(get(normalized, "rollback", nothing), "rollback")
    isempty(_feedback_text(get(rollback, "strategy", ""))) &&
        throw(ArgumentError("Rollback strategy must be nonblank."))
    isempty(_feedback_text(get(rollback, "parent_evidence_id", ""))) &&
        throw(ArgumentError("Rollback must identify parent evidence."))
    normalized["change"] = change
    normalized["held_fixed"] = held_fixed
    normalized["iteration_budget"] = budget
    normalized["rollback"] = rollback
    return normalized
end

"""
    request_adaptive_revision(state, proposal)

Submit a validated v2 proposal through the existing v1 state machine. This
overload preserves the stable state and approval semantics while recording the
complete v2 proposal inside the immutable revision request.
"""
function request_adaptive_revision(state::AbstractDict, proposal::AbstractDict)
    normalized = validate_adaptive_revision_proposal_v2(proposal)
    _validate_adaptive_state(state)
    normalized["study_id"] == state["study_id"] ||
        throw(ArgumentError("Revision proposal study_id does not match the state."))
    Int(normalized["iteration"]) == Int(state["iteration"]) ||
        throw(ArgumentError("Revision proposal iteration does not match the state."))
    revision_type = normalized["revision_type"]
    revision_type in state["spec"]["allowed_revision_types"] ||
        throw(ArgumentError("Revision type $(revision_type) is not allowed by the study."))
    requires_human = revision_type in state["spec"]["approval_policy"]["require_human_for"]
    requires_human == Bool(normalized["approval_required"]) ||
        throw(ArgumentError("Study approval policy does not match the v2 action catalog."))
    change = normalized["change"]
    request = Dict{String,Any}(
        "finding" => "$(normalized["classification"]) diagnosed by $(normalized["diagnosis_id"]).",
        "failure_classification" => normalized["classification"],
        "changes" => Dict(change["parameter"] => deepcopy(change["proposed_value"])),
        "old_values" => Dict(change["parameter"] => deepcopy(change["old_value"])),
        "unchanged_controls" => deepcopy(normalized["held_fixed"]),
        "evidence_paths" => deepcopy(normalized["evidence_paths"]),
        "expected_causal_effect" => normalized["expected_causal_effect"],
        "stop_condition" => normalized["stop_condition"],
        "rollback" => deepcopy(normalized["rollback"]),
        "contract_v2" => deepcopy(normalized),
    )
    return request_adaptive_revision(state, revision_type; request = request)
end

"""Write validated v2 artifacts and a checksum manifest to a new directory."""
function write_adaptive_feedback_v2(
    evidence::AbstractDict,
    diagnosis::AbstractDict,
    output_directory::AbstractString;
    proposal::Union{Nothing,AbstractDict} = nothing,
)
    normalized_evidence = validate_adaptive_evidence_v2(evidence)
    normalized_diagnosis = validate_adaptive_diagnosis_v2(diagnosis)
    normalized_evidence["evidence_id"] == normalized_diagnosis["evidence_id"] ||
        throw(ArgumentError("Diagnosis does not reference the supplied evidence."))
    normalized_proposal =
        proposal === nothing ? nothing : validate_adaptive_revision_proposal_v2(proposal)
    normalized_proposal === nothing ||
        normalized_proposal["diagnosis_id"] == normalized_diagnosis["diagnosis_id"] ||
        throw(ArgumentError("Proposal does not reference the supplied diagnosis."))
    ispath(output_directory) && throw(
        ArgumentError("Adaptive feedback v2 output already exists: $(output_directory)"),
    )
    mkpath(output_directory)
    paths = Dict{String,String}()
    paths["evidence"] = joinpath(output_directory, "evidence.yml")
    paths["diagnosis"] = joinpath(output_directory, "diagnosis.yml")
    YAML.write_file(paths["evidence"], normalized_evidence)
    YAML.write_file(paths["diagnosis"], normalized_diagnosis)
    if normalized_proposal !== nothing
        paths["proposal"] = joinpath(output_directory, "revision_proposal.yml")
        YAML.write_file(paths["proposal"], normalized_proposal)
    end
    manifest_path = joinpath(output_directory, "manifest.yml")
    YAML.write_file(
        manifest_path,
        Dict(
            "artifact_type" => "HOPE.adaptive_feedback_v2_manifest",
            "schema_version" => ADAPTIVE_FEEDBACK_V2_SCHEMA_VERSION,
            "files" => Dict(
                basename(path) => bytes2hex(sha256(read(path))) for path in values(paths)
            ),
        ),
    )
    paths["manifest"] = manifest_path
    return paths
end
