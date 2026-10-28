"""PCM ensemble preparation and assessment for computed physical realizations."""

function _ensemble_template_row(
    table::AbstractDataFrame,
    zone::AbstractString,
    resource_type::AbstractString,
    label::AbstractString,
)
    matches = [
        row for row = 1:nrow(table) if strip(string(table[row, "Zone"])) == zone &&
        strip(string(table[row, "Type"])) == resource_type
    ]
    isempty(matches) && throw(
        ArgumentError(
            "No $(label) operational template matches zone=$(zone), type=$(resource_type).",
        ),
    )
    return first(matches)
end

"""
    capacity_plan_to_gtep_fixture(capacity_plan, template_gtep_input)

Convert a reviewed standalone `CapacityPlan` into the minimal GTEP input/output
contract expected by the established physical-realization and PCM linkage.
Operational parameters are cloned from an existing compatible GTEP candidate
with the same zone and technology; MW and MWh remain authoritative from the
capacity plan. This adapter does not run or impersonate a GTEP optimization.
"""
function capacity_plan_to_gtep_fixture(
    capacity_plan::AbstractDataFrame,
    template_gtep_input::AbstractDict,
)
    validate_capacity_plan(capacity_plan)
    generation_templates = _computed_required_key(
        template_gtep_input,
        "Gendata_candidate",
        "GTEP template input",
    )
    storage_templates = _computed_required_key(
        template_gtep_input,
        "Estoragedata_candidate",
        "GTEP template input",
    )
    generation_rows = DataFrame[]
    storage_rows = DataFrame[]
    generation_output = DataFrame(
        "Technology" => String[],
        "Zone" => String[],
        "EC_Category" => String[],
        "New_Build" => Bool[],
        "Capacity_INI (MW)" => Float64[],
        "Capacity_RET (MW)" => Float64[],
        "Capacity_FIN (MW)" => Float64[],
        "Candidate_ID" => String[],
    )
    storage_output = DataFrame(
        "Technology" => String[],
        "Zone" => String[],
        "EC_Category" => String[],
        "New_Build" => Bool[],
        "Capacity (MW)" => Float64[],
        "EnergyCapacity (MWh)" => Float64[],
        "Candidate_ID" => String[],
    )
    existing_generation =
        _computed_required_key(template_gtep_input, "Gendata", "GTEP template input")
    for row in eachrow(existing_generation)
        existing_mw = to_float_output(row["Pmax (MW)"], 0.0)
        push!(
            generation_output,
            (
                strip(string(row["Type"])),
                strip(string(row["Zone"])),
                "Existing",
                false,
                existing_mw,
                0.0,
                existing_mw,
                "",
            ),
        )
    end
    for item in eachrow(capacity_plan)
        plan_id = strip(string(item.Plan_Item_ID))
        kind = lowercase(strip(string(item.Resource_Kind)))
        zone = strip(string(item.Zone))
        resource_type = strip(string(item.Type))
        build_mw = Float64(item.Build_MW)
        if kind == "generation"
            source = _ensemble_template_row(
                generation_templates,
                zone,
                resource_type,
                "generation",
            )
            candidate = copy(generation_templates[source:source, :])
            original_mw = to_float_output(candidate[1, "Pmax (MW)"], 0.0)
            pmin_ratio =
                original_mw > 0.0 && "Pmin (MW)" in names(candidate) ?
                to_float_output(candidate[1, "Pmin (MW)"], 0.0) / original_mw : 0.0
            candidate[!, "Candidate_ID"] = [plan_id]
            candidate[!, "Zone"] = [zone]
            candidate[!, "Planning_Zone"] = [zone]
            candidate[!, "Type"] = [resource_type]
            candidate[!, "Pmax (MW)"] = [build_mw]
            "Pmin (MW)" in names(candidate) &&
                (candidate[!, "Pmin (MW)"] = [max(pmin_ratio * build_mw, 0.0)])
            push!(generation_rows, candidate)
            push!(
                generation_output,
                (resource_type, zone, "Candidate", true, 0.0, 0.0, build_mw, plan_id),
            )
        else
            source =
                _ensemble_template_row(storage_templates, zone, resource_type, "storage")
            candidate = copy(storage_templates[source:source, :])
            build_mwh = Float64(item.Build_MWh)
            candidate[!, "Candidate_ID"] = [plan_id]
            candidate[!, "Zone"] = [zone]
            candidate[!, "Planning_Zone"] = [zone]
            candidate[!, "Type"] = [resource_type]
            candidate[!, "Max Power (MW)"] = [build_mw]
            candidate[!, "Capacity (MWh)"] = [build_mwh]
            push!(storage_rows, candidate)
            push!(
                storage_output,
                (resource_type, zone, "Candidate", true, build_mw, build_mwh, plan_id),
            )
        end
    end

    adapted_input = deepcopy(template_gtep_input)
    adapted_input["Gendata_candidate"] =
        isempty(generation_rows) ? generation_templates[1:0, :] :
        reduce((left, right) -> vcat(left, right; cols = :union), generation_rows)
    adapted_input["Estoragedata_candidate"] =
        isempty(storage_rows) ? storage_templates[1:0, :] :
        reduce((left, right) -> vcat(left, right; cols = :union), storage_rows)
    line_candidates = get(adapted_input, "Linedata_candidate", DataFrame())
    line_output = DataFrame(
        "New_Build" => fill(false, nrow(line_candidates)),
        FORWARD_LINE_CAPACITY_COLUMN => zeros(nrow(line_candidates)),
        REVERSE_LINE_CAPACITY_COLUMN => zeros(nrow(line_candidates)),
    )
    if HOLISTIC_CORRIDOR_ID in names(line_candidates)
        line_output[!, HOLISTIC_CORRIDOR_ID] = line_candidates[!, HOLISTIC_CORRIDOR_ID]
    end
    adapted_output = Dict{String,Any}(
        "capacity" => generation_output,
        "es_capacity" => storage_output,
        "line" => line_output,
    )
    return Dict{String,Any}(
        "gtep_input" => adapted_input,
        "gtep_output" => adapted_output,
        "capacity_plan" => DataFrame(capacity_plan),
        "adapter_kind" => "declared_capacity_plan_fixture",
    )
end

"""
    prepare_pcm_realization_ensemble(...)

Compute all declared siting variants, run deterministic fast screens, materialize
each variant through the existing GTEP-to-PCM linkage, and independently
reconcile capacity and identity before any PCM solve.
"""
function prepare_pcm_realization_ensemble(
    capacity_plan::AbstractDataFrame,
    candidate_catalog::AbstractDataFrame,
    policy::AbstractDict,
    template_gtep_input::AbstractDict,
    gtep_config::Dict,
    source_pcm_input::Dict,
    pcm_config::Dict;
    physical_realization = nothing,
    operational_templates = nothing,
    variants = nothing,
    max_allocation_to_incident_rating_ratio::Float64 = Inf,
    require_fast_screen::Bool = true,
)
    pcm_input = deepcopy(source_pcm_input)
    if operational_templates !== nothing
        templates = DataFrame(operational_templates)
        validate_operational_resource_templates(templates)
        pcm_input["OperationalResourceTemplates"] = templates
    end
    normalized_policy = validate_realization_policy(policy)
    realization =
        compute_nodal_realizations(capacity_plan, candidate_catalog, normalized_policy)
    selected_variants =
        variants === nothing ? String.(normalized_policy["variant_order"]) :
        String.(variants)
    isempty(selected_variants) && throw(ArgumentError("At least one variant is required."))
    all(variant -> variant in normalized_policy["variant_order"], selected_variants) ||
        throw(ArgumentError("An ensemble variant is absent from policy.variant_order."))
    fixture = capacity_plan_to_gtep_fixture(capacity_plan, template_gtep_input)
    members = Dict{String,Any}()
    summary = DataFrame(
        Variant = String[],
        FastScreenPassed = Bool[],
        TransferReconciliationPassed = Bool[],
        SelectedProjects = Int[],
        HumanReviewProjects = Int[],
        NewGenerationMW = Float64[],
        NewStoragePowerMW = Float64[],
        NewStorageEnergyMWh = Float64[],
    )
    for variant in selected_variants
        fast_screen = screen_computed_realization(
            realization["allocations"],
            pcm_input;
            variant = variant,
            max_allocation_to_incident_rating_ratio = max_allocation_to_incident_rating_ratio,
        )
        require_fast_screen &&
            !fast_screen["valid"] &&
            throw(
                ArgumentError(
                    "Computed-realization fast screen failed for variant $(variant).",
                ),
            )
        materialized = materialize_computed_realization_handoff(
            fixture["gtep_output"],
            fixture["gtep_input"],
            realization["allocations"];
            variant = variant,
            atol = normalized_policy["tolerance_mw"],
        )
        updated_pcm_input = prepare_pcm_inputs_from_gtep_linked(
            materialized["gtep_output"],
            materialized["gtep_input"],
            gtep_config,
            pcm_input,
            pcm_config,
            physical_realization,
        )
        updated_pcm_input["LinkageAudit"]["computed_realization"] = materialized["audit"]
        updated_pcm_input["LinkageAudit"]["computed_fast_screen"] = fast_screen["checks"]
        reconciliation = validate_holistic_transfer_reconciliation(
            materialized["gtep_output"],
            materialized["gtep_input"],
            pcm_input,
            updated_pcm_input,
            pcm_config,
        )
        selected =
            realization["allocations"][realization["allocations"].Variant.==variant, :]
        transfer = holistic_transfer_summary(updated_pcm_input)
        push!(
            summary,
            (
                variant,
                Bool(fast_screen["valid"]),
                Bool(reconciliation["valid"]),
                nrow(selected),
                count(selected.ReviewRequired),
                Float64(transfer["new_generation_mw"]),
                Float64(transfer["new_storage_power_mw"]),
                Float64(transfer["new_storage_energy_mwh"]),
            ),
        )
        members[variant] = Dict{String,Any}(
            "selected_projects" => selected,
            "fast_screen" => fast_screen,
            "materialization_audit" => materialized["audit"],
            "transfer_reconciliation" => reconciliation,
            "transfer_summary" => transfer,
            "pcm_input" => updated_pcm_input,
        )
    end
    return Dict{String,Any}(
        "schema_version" => 1,
        "artifact_type" => "HOPE.pcm_realization_ensemble",
        "capacity_plan" => DataFrame(capacity_plan),
        "realization" => realization,
        "fixture" => fixture,
        "source_pcm_input" => pcm_input,
        "summary" => summary,
        "members" => members,
    )
end

function _ensemble_classification(metrics::AbstractDict, feasible::Bool; thresholds)
    feasible || return ("PCM_INFEASIBLE", false, "PCM has no feasible primal solution")
    load_shedding = Float64(get(metrics, "pcm_load_shedding_mwh", Inf))
    rps_slack = Float64(get(metrics, "pcm_rps_slack_mwh", Inf))
    if load_shedding > thresholds.max_load_shedding_mwh
        return (
            "ACCEPTANCE_FAILED",
            false,
            "load shedding $(load_shedding) MWh exceeds $(thresholds.max_load_shedding_mwh)",
        )
    end
    if rps_slack > thresholds.max_rps_slack_mwh
        return (
            "ACCEPTANCE_FAILED",
            false,
            "RPS slack $(rps_slack) MWh exceeds $(thresholds.max_rps_slack_mwh)",
        )
    end
    return ("ACCEPTED", true, "PCM is feasible and declared thresholds pass")
end

"""
    assess_pcm_realization_ensemble(prepared, pcm_case_path, pcm_config; kwargs...)

Solve every prepared PCM member with identical settings and return compact,
typed evidence. The function classifies model construction/solve errors,
mathematical infeasibility, acceptance-threshold failure, and acceptance
separately. It does not revise any upstream assumption.
"""
function assess_pcm_realization_ensemble(
    prepared::AbstractDict,
    pcm_case_path::AbstractString,
    pcm_config::Dict;
    solver_override = nothing,
    max_load_shedding_mwh::Float64 = 1e-6,
    max_rps_slack_mwh::Float64 = 1e-6,
)
    solver_name = _effective_solver_name(pcm_config, solver_override)
    if haskey(OPTIONAL_SOLVER_PACKAGES, solver_name)
        _ensure_optional_solver_loaded(solver_name)
        return Base.invokelatest(
            _assess_pcm_realization_ensemble_impl,
            prepared,
            pcm_case_path,
            pcm_config;
            solver_override = solver_override,
            max_load_shedding_mwh = max_load_shedding_mwh,
            max_rps_slack_mwh = max_rps_slack_mwh,
        )
    end
    return _assess_pcm_realization_ensemble_impl(
        prepared,
        pcm_case_path,
        pcm_config;
        solver_override = solver_override,
        max_load_shedding_mwh = max_load_shedding_mwh,
        max_rps_slack_mwh = max_rps_slack_mwh,
    )
end

function _assess_pcm_realization_ensemble_impl(
    prepared::AbstractDict,
    pcm_case_path::AbstractString,
    pcm_config::Dict;
    solver_override = nothing,
    max_load_shedding_mwh::Float64 = 1e-6,
    max_rps_slack_mwh::Float64 = 1e-6,
)
    max_load_shedding_mwh >= 0.0 ||
        throw(ArgumentError("max_load_shedding_mwh must be nonnegative."))
    max_rps_slack_mwh >= 0.0 ||
        throw(ArgumentError("max_rps_slack_mwh must be nonnegative."))
    config = deepcopy(pcm_config)
    config["solver"] = _effective_solver_name(config, solver_override)
    thresholds = (
        max_load_shedding_mwh = max_load_shedding_mwh,
        max_rps_slack_mwh = max_rps_slack_mwh,
    )
    findings = DataFrame(
        Variant = String[],
        Classification = String[],
        Accepted = Bool[],
        HumanReviewRequired = Bool[],
        ReusedFrom = String[],
        TerminationStatus = String[],
        PrimalStatus = String[],
        ObjectiveValue = Float64[],
        LoadSheddingMWh = Float64[],
        RPSSlackMWh = Float64[],
        NewGenerationDispatchMWh = Float64[],
        NewStorageChargeMWh = Float64[],
        NewStorageDischargeMWh = Float64[],
        Reason = String[],
    )
    evidence = Dict{String,Any}()
    solved_signatures = Dict{String,Any}()
    source_pcm_input = get(prepared, "source_pcm_input", nothing)
    for variant in String.(prepared["summary"].Variant)
        member = prepared["members"][variant]
        selected = member["selected_projects"]
        signature = join(
            sort(
                string.(
                    selected.CandidateSiteID,
                    "@",
                    selected.BusID,
                    "@",
                    selected.AllocatedMW,
                    "@",
                    selected.AllocatedMWh,
                ),
            ),
            "|",
        )
        classification = "MODEL_CONSTRUCTION_FAILED"
        accepted = false
        reason = ""
        metrics = Dict{String,Any}(
            "pcm_termination_status" => "NOT_RUN",
            "pcm_primal_status" => "NO_SOLUTION",
            "pcm_objective_value" => NaN,
            "pcm_load_shedding_mwh" => Inf,
            "pcm_rps_slack_mwh" => Inf,
            "pcm_new_generation_dispatch_mwh" => 0.0,
            "pcm_new_storage_charge_mwh" => 0.0,
            "pcm_new_storage_discharge_mwh" => 0.0,
        )
        reused_from = ""
        if haskey(solved_signatures, signature)
            cached = solved_signatures[signature]
            classification = cached.classification
            accepted = cached.accepted
            reason = cached.reason
            metrics = copy(cached.metrics)
            reused_from = cached.variant
        else
            try
                optimizer = initiate_solver(pcm_case_path, String(config["solver"]))
                model = create_PCM_model(config, member["pcm_input"], optimizer)
                solved = solve_model(config, member["pcm_input"], model)
                merge!(metrics, holistic_model_activity_metrics(solved, "pcm"))
                if source_pcm_input !== nothing
                    merge!(
                        metrics,
                        holistic_pcm_transfer_activity_metrics(
                            solved,
                            member["pcm_input"],
                            source_pcm_input,
                            config,
                        ),
                    )
                end
                feasible = has_feasible_primal_solution(solved)
                classification, accepted, reason =
                    _ensemble_classification(metrics, feasible; thresholds = thresholds)
            catch error
                reason = sprint(showerror, error)
            end
            solved_signatures[signature] = (
                variant = variant,
                classification = classification,
                accepted = accepted,
                reason = reason,
                metrics = copy(metrics),
            )
        end
        human_review_required = any(selected.ReviewRequired)
        if classification == "ACCEPTED" && human_review_required
            classification = "HUMAN_REVIEW"
            accepted = false
            reason = "Operational thresholds pass, but one or more selected projects require human approval"
        end
        push!(
            findings,
            (
                variant,
                classification,
                accepted,
                human_review_required,
                reused_from,
                string(metrics["pcm_termination_status"]),
                string(metrics["pcm_primal_status"]),
                Float64(metrics["pcm_objective_value"]),
                Float64(metrics["pcm_load_shedding_mwh"]),
                Float64(metrics["pcm_rps_slack_mwh"]),
                Float64(metrics["pcm_new_generation_dispatch_mwh"]),
                Float64(metrics["pcm_new_storage_charge_mwh"]),
                Float64(metrics["pcm_new_storage_discharge_mwh"]),
                reason,
            ),
        )
        evidence[variant] = Dict{String,Any}(
            "metrics" => metrics,
            "physical_signature" => bytes2hex(sha256(signature)),
            "reused_from" => isempty(reused_from) ? nothing : reused_from,
        )
        GC.gc()
    end
    return Dict{String,Any}(
        "schema_version" => 1,
        "artifact_type" => "HOPE.pcm_realization_ensemble_assessment",
        "thresholds" => Dict(
            "max_load_shedding_mwh" => max_load_shedding_mwh,
            "max_rps_slack_mwh" => max_rps_slack_mwh,
        ),
        "findings" => findings,
        "evidence" => evidence,
    )
end
