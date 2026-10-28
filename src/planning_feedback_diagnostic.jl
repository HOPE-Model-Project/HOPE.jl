"""Evidence-based diagnosis before an upstream GTEP revision is authorized."""

function _diagnostic_context_constraints(context::AbstractDict)
    contract = get(context, "capacity_plan_contract", Dict{String,Any}())
    contract isa AbstractDict ||
        throw(ArgumentError("capacity_plan_contract must be a mapping."))
    enforced = get(contract, "enforced_constraints", String[])
    enforced isa AbstractVector ||
        throw(ArgumentError("capacity_plan_contract.enforced_constraints must be a list."))
    return Set(lowercase.(_feedback_text.(enforced)))
end

function _diagnostic_candidate_utilization(
    candidates::AbstractDataFrame,
    capacity::AbstractDataFrame;
    tolerance_mw::Float64,
)
    _computed_require_columns(
        candidates,
        ["Candidate_ID", "Zone", "Type", "Pmax (MW)", "Flag_RPS"],
        "GTEP candidate table",
    )
    _computed_require_columns(
        capacity,
        ["Candidate_ID", "EC_Category", "Capacity_FIN (MW)"],
        "GTEP capacity output",
    )
    built = Dict{String,Float64}()
    for row in eachrow(capacity)
        _feedback_text(row["EC_Category"]) == "Candidate" || continue
        candidate_id = _feedback_text(row["Candidate_ID"])
        isempty(candidate_id) && continue
        built[candidate_id] = _child_number(row["Capacity_FIN (MW)"], "Capacity_FIN (MW)")
    end
    utilization = DataFrame(
        CandidateID = String[],
        Zone = String[],
        Type = String[],
        RPSEligible = Bool[],
        BuiltMW = Float64[],
        UpperMW = Float64[],
        HeadroomMW = Float64[],
        AtUpperBound = Bool[],
    )
    for row in eachrow(candidates)
        candidate_id = _feedback_text(row["Candidate_ID"])
        upper = _child_number(row["Pmax (MW)"], "Pmax (MW)")
        built_mw = get(built, candidate_id, 0.0)
        headroom = max(upper - built_mw, 0.0)
        push!(
            utilization,
            (
                candidate_id,
                _feedback_text(row["Zone"]),
                _feedback_text(row["Type"]),
                _computed_bool(row["Flag_RPS"], false),
                built_mw,
                upper,
                headroom,
                isapprox(built_mw, upper; atol = tolerance_mw, rtol = 0.0),
            ),
        )
    end
    return utilization
end

function _diagnostic_plan_summary(plan::AbstractDataFrame, eligibility::AbstractDict)
    validate_capacity_plan(plan)
    has_build_mwh = "Build_MWh" in names(plan)
    rows = DataFrame(
        ResourceKind = String[],
        Type = String[],
        RPSEligible = Bool[],
        PlanMW = Float64[],
        PlanMWh = Float64[],
    )
    for item in eachrow(plan)
        kind = _feedback_text(item.Resource_Kind)
        type_name = _feedback_text(item.Type)
        eligible = kind == "generation" && Bool(get(eligibility, type_name, false))
        build_mwh =
            has_build_mwh && !ismissing(item["Build_MWh"]) ? Float64(item["Build_MWh"]) :
            0.0
        push!(rows, (kind, type_name, eligible, Float64(item.Build_MW), build_mwh))
    end
    return combine(
        groupby(rows, [:ResourceKind, :Type, :RPSEligible]),
        :PlanMW => sum => :PlanMW,
        :PlanMWh => sum => :PlanMWh,
    )
end

"""
    diagnose_gtep_feedback_context(parent_case, capacity_plan, assessment, context)

Determine whether a failed operational RPS gate is consistent with exhausted
GTEP candidate headroom or with a missing policy constraint in the capacity
plan's derivation contract. This diagnostic is read-only and does not propose a
numerical model change.
"""
function diagnose_gtep_feedback_context(
    parent_case::AbstractString,
    capacity_plan::AbstractDataFrame,
    assessment::AbstractDict,
    context::AbstractDict;
    tolerance_mw::Float64 = 1e-6,
)
    tolerance_mw > 0.0 || throw(ArgumentError("tolerance_mw must be positive."))
    parent_path, config = load_case_config_for_holistic(
        parent_case;
        context = "diagnose_gtep_feedback_context",
    )
    lowercase(_feedback_text(get(config, "model_mode", ""))) == "gtep" ||
        throw(ArgumentError("Diagnostic parent case must use model_mode GTEP."))
    data_directory = normpath(joinpath(parent_path, String(config["DataCase"])))
    candidate_path = joinpath(data_directory, "gendata_candidate.csv")
    capacity_path = joinpath(parent_path, "output", "capacity.csv")
    isfile(candidate_path) ||
        throw(ArgumentError("GTEP candidate table not found: $(candidate_path)"))
    isfile(capacity_path) ||
        throw(ArgumentError("Validated GTEP capacity output not found: $(capacity_path)"))
    candidates = CSV.read(candidate_path, DataFrame)
    capacity = CSV.read(capacity_path, DataFrame)
    utilization =
        _diagnostic_candidate_utilization(candidates, capacity; tolerance_mw = tolerance_mw)
    eligibility = Dict{String,Bool}()
    for group in groupby(utilization, :Type)
        flags = unique(group.RPSEligible)
        length(flags) == 1 || throw(
            ArgumentError("GTEP candidate type $(first(group.Type)) has mixed RPS flags."),
        )
        eligibility[first(group.Type)] = only(flags)
    end
    plan_summary = _diagnostic_plan_summary(capacity_plan, eligibility)
    assessment_rows = _feedback_rows(assessment)
    thresholds = get(assessment, "thresholds", Dict{String,Any}())
    rps_threshold = Float64(get(thresholds, "max_rps_slack_mwh", 1e-6))
    observed_rps_slack =
        isempty(assessment_rows) ? 0.0 :
        maximum(_feedback_metric(row, "RPSSlackMWh") for row in assessment_rows)
    manifest_path = joinpath(parent_path, "manifest.yml")
    manifest = isfile(manifest_path) ? YAML.load_file(manifest_path) : Dict()
    validation = manifest isa AbstractDict ? get(manifest, "validation", Dict()) : Dict()
    validation isa AbstractDict ||
        throw(ArgumentError("Parent GTEP manifest validation must be a mapping."))
    haskey(validation, "rps_slack_mwh") ||
        throw(ArgumentError("Parent GTEP manifest must record validation.rps_slack_mwh."))
    parent_rps_slack =
        _child_number(validation["rps_slack_mwh"], "parent validation rps_slack_mwh")
    parent_rps_passed = parent_rps_slack <= rps_threshold
    constraints = _diagnostic_context_constraints(context)
    plan_enforced_rps =
        any(name -> name in constraints, ("annual_rps", "rps", "energy_rps"))
    rps_candidates = utilization[utilization.RPSEligible, :]
    aggregate_headroom = sum(rps_candidates.HeadroomMW)
    aggregate_headroom_exhausted = aggregate_headroom <= tolerance_mw
    classification =
        if observed_rps_slack > rps_threshold && parent_rps_passed && !plan_enforced_rps
            "capacity_plan_policy_contract_gap"
        elseif observed_rps_slack > rps_threshold && aggregate_headroom_exhausted
            "qualifying_candidate_envelope_exhausted"
        elseif observed_rps_slack > rps_threshold
            "rps_failure_requires_planning_model_diagnosis"
        else
            "no_rps_failure"
        end
    candidate_headroom_revision_supported =
        classification == "qualifying_candidate_envelope_exhausted"
    recommended_action = if classification == "capacity_plan_policy_contract_gap"
        "derive a child CapacityPlan from an RPS-constrained GTEP solve before realization; do not increase candidate limits"
    elseif classification == "qualifying_candidate_envelope_exhausted"
        "review an approval-bounded increase in eligible candidate limits"
    elseif classification == "rps_failure_requires_planning_model_diagnosis"
        "inspect binding planning constraints, renewable chronology, accreditation, and clean-import assumptions"
    else
        "no upstream RPS revision is indicated"
    end
    return Dict{String,Any}(
        "artifact_type" => "HOPE.gtep_feedback_diagnostic",
        "schema_version" => 1,
        "classification" => classification,
        "recommended_action" => recommended_action,
        "candidate_headroom_revision_supported" => candidate_headroom_revision_supported,
        "evidence" => Dict(
            "observed_pcm_rps_slack_mwh" => observed_rps_slack,
            "pcm_rps_slack_threshold_mwh" => rps_threshold,
            "parent_gtep_rps_slack_mwh" => parent_rps_slack,
            "parent_gtep_rps_passed" => parent_rps_passed,
            "capacity_plan_enforced_rps" => plan_enforced_rps,
            "aggregate_rps_candidate_headroom_mw" => aggregate_headroom,
            "aggregate_rps_candidate_headroom_exhausted" =>
                aggregate_headroom_exhausted,
            "rps_candidates_at_upper_bound" =>
                count(identity, rps_candidates.AtUpperBound),
            "rps_candidate_count" => nrow(rps_candidates),
        ),
        "candidate_utilization" => utilization,
        "capacity_plan_summary" => plan_summary,
        "source_hashes" => Dict(
            "gendata_candidate.csv" => bytes2hex(sha256(read(candidate_path))),
            "capacity.csv" => bytes2hex(sha256(read(capacity_path))),
        ),
    )
end

function write_gtep_feedback_diagnostic(
    diagnostic::AbstractDict,
    output_directory::AbstractString,
)
    ispath(output_directory) &&
        throw(ArgumentError("Diagnostic output already exists: $(output_directory)"))
    mkpath(output_directory)
    utilization_path = joinpath(output_directory, "candidate_utilization.csv")
    plan_path = joinpath(output_directory, "capacity_plan_summary.csv")
    diagnostic_path = joinpath(output_directory, "diagnostic.yml")
    CSV.write(utilization_path, diagnostic["candidate_utilization"])
    CSV.write(plan_path, diagnostic["capacity_plan_summary"])
    YAML.write_file(
        diagnostic_path,
        Dict(
            "artifact_type" => diagnostic["artifact_type"],
            "schema_version" => diagnostic["schema_version"],
            "classification" => diagnostic["classification"],
            "recommended_action" => diagnostic["recommended_action"],
            "candidate_headroom_revision_supported" =>
                diagnostic["candidate_headroom_revision_supported"],
            "evidence" => diagnostic["evidence"],
            "source_hashes" => diagnostic["source_hashes"],
        ),
    )
    files = [utilization_path, plan_path, diagnostic_path]
    manifest_path = joinpath(output_directory, "manifest.yml")
    YAML.write_file(
        manifest_path,
        Dict(
            "artifact_type" => "HOPE.gtep_feedback_diagnostic_manifest",
            "schema_version" => 1,
            "files" =>
                Dict(basename(path) => bytes2hex(sha256(read(path))) for path in files),
        ),
    )
    return Dict(
        "diagnostic" => diagnostic_path,
        "candidate_utilization" => utilization_path,
        "capacity_plan_summary" => plan_path,
        "manifest" => manifest_path,
    )
end
