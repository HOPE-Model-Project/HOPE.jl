using HOPE
using Test
using YAML

const ADAPTIVE_FEEDBACK_V2_EXAMPLE =
    joinpath(@__DIR__, "fixtures", "adaptive_study_v1", "md_energy_thermal_study.yml")

function _adaptive_v2_failed_state(; iteration_budget::Int = 3)
    spec = HOPE.load_holistic_study_spec(ADAPTIVE_FEEDBACK_V2_EXAMPLE)
    spec["iteration_budget"] = iteration_budget
    state = HOPE.initialize_adaptive_study(spec)
    gtep = Dict{String,Any}(
        "artifact_type" => "HOPE.capacity_plan",
        "schema_version" => 1,
        "termination_status" => "OPTIMAL",
        "objective_usd" => 8.53e8,
        "load_shedding_mwh" => 0.0,
        "new_generation_mw" => 1674.3,
        "project_count" => 3,
        "build_zones" => ["BGE"],
        "resource_types" => ["NGCC"],
        "planning_result_path" => "iteration-01/planning_result.yml",
        "capacity_plan_path" => "iteration-01/unitized_capacity_plan.csv",
    )
    realization = Dict{String,Any}(
        "artifact_type" => "HOPE.realization_set",
        "schema_version" => 1,
        "planned_capacity_mw" => 1674.3,
        "placed_capacity_mw" => 1674.3,
        "unplaced_capacity_mw" => 0.0,
        "variants" => [
            "balanced_permitting",
            "least_cost",
            "environmental_caution",
            "grid_ready",
        ],
        "allocations_path" => "iteration-01/realization_allocations.csv",
        "screening_path" => "iteration-01/realization_screening.csv",
        "candidate_catalog_path" => "iteration-01/candidate_project_catalog.csv",
    )
    findings = [
        Dict{String,Any}(
            "Variant" => variant,
            "Classification" => "ACCEPTANCE_FAILED",
            "Accepted" => false,
            "LoadSheddingMWh" => 11596.4,
            "TerminationStatus" => "OPTIMAL",
        ) for variant in realization["variants"]
    ]
    pcm = Dict{String,Any}(
        "artifact_type" => "HOPE.pcm_realization_ensemble_assessment",
        "schema_version" => 1,
        "findings" => findings,
        "findings_path" => "iteration-01/ensemble_findings.csv",
        "load_shedding_mwh_min" => 11596.3,
        "load_shedding_mwh_max" => 11596.5,
        "affected_zones" => ["PEPCO"],
        "load_shedding_hours" => 25,
        "maximum_hourly_shortfall_mw" => 931.0,
        "new_generation_dispatch_mwh_min" => 50002.3,
        "new_generation_dispatch_mwh_max" => 50027.8,
    )
    state = HOPE.record_adaptive_stage(state, "GTEP_SOLVED", gtep)
    state = HOPE.record_adaptive_stage(state, "REALIZED", realization)
    state = HOPE.record_adaptive_stage(state, "PCM_SOLVED", pcm)
    return HOPE.verify_adaptive_study(state, findings)
end

@testset "Adaptive feedback contract v2" begin
    state = _adaptive_v2_failed_state()
    evidence = HOPE.build_adaptive_evidence_v2(state)

    @test evidence["artifact_type"] == "HOPE.adaptive_evidence"
    @test evidence["schema_version"] == 2
    @test evidence["planning"]["capacity_additions"]["zones"] == ["BGE"]
    @test evidence["planning"]["capacity_additions"]["total_mw"] == 1674.3
    @test evidence["realization"]["unplaced_capacity_mw"] == 0.0
    @test evidence["pcm"]["load_shedding"]["affected_zones"] == ["PEPCO"]
    @test evidence["pcm"]["accepted_count"] == 0
    @test length(evidence["sources"]["paths"]) == 6

    diagnosis = HOPE.diagnose_adaptive_failure_v2(evidence)
    @test diagnosis["status"] == "FAILURE_CLASSIFIED"
    @test diagnosis["classification"] == "SPATIAL_CAPACITY_MISMATCH"
    @test diagnosis["responsible_layer"] == "gtep"
    @test diagnosis["signals"]["planning_build_zones"] == ["BGE"]
    @test diagnosis["signals"]["pcm_affected_zones"] == ["PEPCO"]

    held_fixed = [
        "planning_reserve_margin",
        "voll_usd_per_mwh",
        "load_multiplier",
        "maryland_rps_fraction",
        "firm_external_contribution_mw",
        "allowed_generation_candidate_types",
        "storage_candidates_enabled",
    ]
    proposal = HOPE.build_adaptive_revision_proposal_v2(
        diagnosis,
        evidence;
        action = "change_generation_candidate_zone_eligibility",
        old_value = ["BGE"],
        proposed_value = ["PEPCO"],
        held_fixed = held_fixed,
        expected_causal_effect = "Move dispatchable additions into the PCM shortfall zone.",
        stop_condition = "Stop after one child iteration if no realization has zero load shedding.",
        maximum_iterations = state["spec"]["iteration_budget"],
    )
    @test proposal["classification"] == "SPATIAL_CAPACITY_MISMATCH"
    @test proposal["requested_owner"] == "gtep"
    @test proposal["change"]["parameter"] == "allowed_generation_candidate_zones"
    @test proposal["approval_required"]
    @test proposal["iteration_budget"]["remaining_after_child"] == 1

    requested = HOPE.request_adaptive_revision(state, proposal)
    @test requested["stage"] == "REVISION_REQUESTED"
    revision = requested["attempts"][1]["revision"]
    @test revision["revision_type"] == "candidate_zone_eligibility"
    @test revision["request"]["failure_classification"] == "SPATIAL_CAPACITY_MISMATCH"
    @test revision["request"]["changes"] ==
          Dict("allowed_generation_candidate_zones" => ["PEPCO"])
    @test revision["request"]["contract_v2"]["proposal_id"] == proposal["proposal_id"]

    no_progress_child = deepcopy(evidence)
    no_progress_child["iteration"] = 2
    no_progress_child["evidence_id"] = "adaptive-evidence-no-progress-child"
    no_progress =
        HOPE.assess_adaptive_progress_v2(evidence, no_progress_child; proposal = proposal)
    @test no_progress["status"] == "NO_PROGRESS"
    @test no_progress["primary_metrics"] ==
          ["pcm_load_shedding_mwh_max", "maximum_hourly_shortfall_mw"]

    improved_child = deepcopy(no_progress_child)
    improved_child["evidence_id"] = "adaptive-evidence-improved-child"
    improved_child["pcm"]["load_shedding"]["maximum_mwh"] = 5000.0
    improved =
        HOPE.assess_adaptive_progress_v2(evidence, improved_child; proposal = proposal)
    @test improved["status"] == "PROGRESS"

    regressed_child = deepcopy(no_progress_child)
    regressed_child["evidence_id"] = "adaptive-evidence-regressed-child"
    regressed_child["pcm"]["load_shedding"]["maximum_mwh"] = 13000.0
    regressed_child["pcm"]["load_shedding"]["maximum_hourly_shortfall_mw"] = 1000.0
    regressed =
        HOPE.assess_adaptive_progress_v2(evidence, regressed_child; proposal = proposal)
    @test regressed["status"] == "REGRESSION"

    target_child = deepcopy(no_progress_child)
    target_child["evidence_id"] = "adaptive-evidence-target-child"
    target_child["pcm"]["accepted_count"] = 1
    target_child["pcm"]["accepted_variants"] = ["least_cost"]
    target = HOPE.assess_adaptive_progress_v2(evidence, target_child; proposal = proposal)
    @test target["status"] == "TARGET_MET"

    approved = HOPE.record_adaptive_revision_decision(
        requested,
        "approved";
        approver = "human-reviewer",
        rationale = "Approve one bounded spatial correction.",
    )
    child_state = HOPE.start_adaptive_child_iteration(approved)
    for (stage, key) in
        (("GTEP_SOLVED", "gtep"), ("REALIZED", "realization"), ("PCM_SOLVED", "pcm"))
        artifact = deepcopy(state["attempts"][1]["artifacts"][key])
        artifact["iteration"] = 2
        child_state = HOPE.record_adaptive_stage(child_state, stage, artifact)
    end
    child_state = HOPE.verify_adaptive_study(
        child_state,
        child_state["attempts"][2]["artifacts"]["pcm"]["findings"],
    )

    repeated_evidence = HOPE.build_adaptive_evidence_v2(child_state)
    repeated_diagnosis = HOPE.diagnose_adaptive_failure_v2(repeated_evidence)
    repeated_proposal = HOPE.build_adaptive_revision_proposal_v2(
        repeated_diagnosis,
        repeated_evidence;
        action = "change_generation_candidate_zone_eligibility",
        old_value = ["BGE"],
        proposed_value = ["PEPCO"],
        held_fixed = held_fixed,
        expected_causal_effect = "Repeat the same spatial correction.",
        stop_condition = "Stop if the semantic action repeats.",
        maximum_iterations = 3,
    )
    repeated_request = HOPE.request_adaptive_revision(child_state, repeated_proposal)
    repeated_approval = HOPE.record_adaptive_revision_decision(
        repeated_request,
        "approved";
        approver = "human-reviewer",
        rationale = "Exercise the semantic cycle guard.",
    )
    cycle_stopped = HOPE.start_adaptive_child_iteration(repeated_approval)
    @test cycle_stopped["terminal_status"] == "INCONCLUSIVE"
    @test cycle_stopped["history"][end]["event"] == "revision_cycle_detected"

    guarded = HOPE.apply_adaptive_progress_guard_v2(child_state, no_progress)
    @test guarded["terminal_status"] == "INCONCLUSIVE"
    @test guarded["attempts"][2]["rollback"]["status"] == "applied"
    @test guarded["attempts"][2]["rollback"]["to_iteration"] == 1
    @test guarded["history"][end]["event"] == "no_progress_rollback"

    budget_state = _adaptive_v2_failed_state(; iteration_budget = 1)
    @test budget_state["terminal_status"] == "INCONCLUSIVE"
    @test budget_state["attempts"][1]["termination"]["reason"] ==
          "ITERATION_BUDGET_EXHAUSTED"
    @test budget_state["history"][end]["event"] ==
          "iteration_budget_exhausted_at_verification"

    mismatched_budget = deepcopy(proposal)
    mismatched_budget["iteration_budget"]["maximum"] = 2
    @test_throws ArgumentError HOPE.request_adaptive_revision(state, mismatched_budget)

    wrong_action = deepcopy(proposal)
    wrong_action["action"] = "enable_storage_flexibility_candidate"
    @test_throws ArgumentError HOPE.validate_adaptive_revision_proposal_v2(wrong_action)

    contradictory = deepcopy(proposal)
    push!(contradictory["held_fixed"], "allowed_generation_candidate_zones")
    @test_throws ArgumentError HOPE.validate_adaptive_revision_proposal_v2(contradictory)

    solver_evidence = deepcopy(evidence)
    solver_evidence["planning"]["solver"]["termination_status"] = "INFEASIBLE"
    solver_diagnosis = HOPE.diagnose_adaptive_failure_v2(solver_evidence)
    @test solver_diagnosis["classification"] == "SOLVER_FAILURE"

    siting_evidence = deepcopy(evidence)
    siting_evidence["realization"]["unplaced_capacity_mw"] = 250.0
    siting_diagnosis = HOPE.diagnose_adaptive_failure_v2(siting_evidence)
    @test siting_diagnosis["classification"] == "REALIZATION_SITING_INFEASIBLE"

    congestion_evidence = deepcopy(evidence)
    congestion_evidence["planning"]["capacity_additions"]["zones"] = ["PEPCO"]
    congestion_evidence["pcm"]["congestion"] = Dict("overload_mwh" => 0.0)
    neutral_diagnosis = HOPE.diagnose_adaptive_failure_v2(congestion_evidence)
    @test neutral_diagnosis["classification"] == "ACCEPTANCE_FAILED_OTHER"
    congestion_evidence["pcm"]["congestion"]["overload_mwh"] = 120.0
    congestion_diagnosis = HOPE.diagnose_adaptive_failure_v2(congestion_evidence)
    @test congestion_diagnosis["classification"] == "TRANSMISSION_CONGESTION"

    accepted_evidence = deepcopy(evidence)
    accepted_evidence["pcm"]["accepted_count"] = 1
    accepted_evidence["pcm"]["accepted_variants"] = ["least_cost"]
    accepted_diagnosis = HOPE.diagnose_adaptive_failure_v2(accepted_evidence)
    @test accepted_diagnosis["status"] == "NO_FAILURE"
    @test accepted_diagnosis["classification"] === nothing
    @test_throws ArgumentError HOPE.build_adaptive_revision_proposal_v2(
        accepted_diagnosis,
        accepted_evidence;
        action = "change_generation_candidate_zone_eligibility",
        old_value = ["BGE"],
        proposed_value = ["PEPCO"],
        held_fixed = held_fixed,
        expected_causal_effect = "No change should be proposed.",
        stop_condition = "Stop.",
        maximum_iterations = 3,
    )

    catalog = HOPE.adaptive_action_catalog_v2()
    @test catalog["enable_transmission_candidate"]["approval_required"]
    catalog["enable_transmission_candidate"]["owner"] = "changed"
    @test HOPE.adaptive_action_catalog_v2()["enable_transmission_candidate"]["owner"] ==
          "gtep"

    mktempdir() do directory
        destination = joinpath(directory, "adaptive-feedback-v2")
        paths = HOPE.write_adaptive_feedback_v2(
            evidence,
            diagnosis,
            destination;
            proposal = proposal,
        )
        @test all(isfile, values(paths))
        manifest = YAML.load_file(paths["manifest"])
        @test manifest["schema_version"] == 2
        @test length(manifest["files"]) == 3
        @test_throws ArgumentError HOPE.write_adaptive_feedback_v2(
            evidence,
            diagnosis,
            destination;
            proposal = proposal,
        )
    end
end
