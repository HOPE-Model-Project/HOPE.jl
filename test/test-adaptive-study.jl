using HOPE
using Test
using YAML

const ADAPTIVE_STUDY_EXAMPLE = joinpath(@__DIR__, "fixtures", "adaptive_study_v1")

function _adaptive_handlers(results)
    return Dict(
        "gtep" =>
            state -> Dict(
                "artifact_type" => "HOPE.capacity_plan",
                "iteration" => state["iteration"],
                "new_generation_mw" => 1674.28673662058,
            ),
        "realization" =>
            state -> Dict(
                "artifact_type" => "HOPE.realization_set",
                "iteration" => state["iteration"],
                "variants" => [
                    "balanced_permitting",
                    "least_cost",
                    "environmental_caution",
                    "grid_ready",
                ],
            ),
        "pcm" =>
            state -> Dict(
                "artifact_type" => "HOPE.pcm_realization_ensemble_assessment",
                "iteration" => state["iteration"],
            ),
        "verification" => state -> deepcopy(results),
    )
end

@testset "Adaptive holistic study state machine" begin
    spec = HOPE.load_holistic_study_spec(
        joinpath(ADAPTIVE_STUDY_EXAMPLE, "md_energy_thermal_study.yml"),
    )
    @test spec["iteration_budget"] == 3
    @test spec["acceptance"]["ensemble_policy"] == "any"
    @test_throws ArgumentError HOPE.validate_holistic_study_spec(
        merge(spec, Dict("iteration_budget" => 0)),
    )
    unsafe_spec = deepcopy(spec)
    unsafe_spec["approval_policy"]["require_human_for"] = String[]
    @test_throws ArgumentError HOPE.validate_holistic_study_spec(unsafe_spec)

    initial = HOPE.initialize_adaptive_study(spec)
    @test initial["stage"] == "SPECIFIED"
    @test initial["terminal_status"] == "ACTIVE"
    @test initial["iteration"] == 1

    failed_iteration = [
        Dict("Variant" => variant, "Classification" => "ACCEPTANCE_FAILED") for
        variant in
        ("balanced_permitting", "least_cost", "environmental_caution", "grid_ready")
    ]
    first = HOPE.run_adaptive_study_iteration(initial, _adaptive_handlers(failed_iteration))
    @test initial["stage"] == "SPECIFIED"
    @test first["stage"] == "VERIFIED"
    @test first["terminal_status"] == "ACTIVE"
    @test !first["attempts"][1]["verification"]["accepted"]

    request = Dict(
        "finding" => "PEPCO load shedding persists across all four realizations.",
        "changes" => Dict("allowed_generation_candidate_zones" => ["PEPCO"]),
        "unchanged_controls" => collect(keys(spec["fixed_assumptions"])),
    )
    proposed = HOPE.request_adaptive_revision(
        first,
        "candidate_zone_eligibility";
        request = request,
    )
    @test proposed["stage"] == "REVISION_REQUESTED"
    @test proposed["attempts"][1]["revision"]["approval_required"]
    @test_throws ArgumentError HOPE.start_adaptive_child_iteration(proposed)

    approved = HOPE.record_adaptive_revision_decision(
        proposed,
        "approved";
        approver = "human-reviewer",
        rationale = "The PEPCO-local eligibility test is the smallest evidence-based revision.",
    )
    child = HOPE.start_adaptive_child_iteration(approved)
    @test child["iteration"] == 2
    @test child["stage"] == "SPECIFIED"
    @test length(child["attempts"]) == 2
    @test child["attempts"][2]["parent_revision"]["status"] == "approved"

    accepted_iteration = [
        Dict("Variant" => "balanced_permitting", "Classification" => "ACCEPTANCE_FAILED"),
        Dict("Variant" => "least_cost", "Classification" => "ACCEPTED"),
        Dict("Variant" => "environmental_caution", "Classification" => "ACCEPTANCE_FAILED"),
        Dict("Variant" => "grid_ready", "Classification" => "ACCEPTANCE_FAILED"),
    ]
    final = HOPE.run_adaptive_study_iteration(child, _adaptive_handlers(accepted_iteration))
    @test final["terminal_status"] == "ACCEPTED"
    @test final["attempts"][2]["verification"]["accepted_count"] == 1
    @test final["attempts"][2]["verification"]["accepted_fraction"] == 0.25
    @test_throws ArgumentError HOPE.request_adaptive_revision(
        final,
        "realization_local_resiting",
    )

    @test HOPE.evaluate_ensemble_acceptance(
        accepted_iteration,
        Dict("ensemble_policy" => "any"),
    )["accepted"]
    @test !HOPE.evaluate_ensemble_acceptance(
        accepted_iteration,
        Dict("ensemble_policy" => "all"),
    )["accepted"]
    @test HOPE.evaluate_ensemble_acceptance(
        accepted_iteration,
        Dict("ensemble_policy" => "fraction", "minimum_fraction" => 0.25),
    )["accepted"]
    @test !HOPE.evaluate_ensemble_acceptance(
        accepted_iteration,
        Dict("ensemble_policy" => "worst_case"),
    )["accepted"]

    protected_request = Dict("changes" => Dict("acceptance" => "weaker"))
    @test_throws ArgumentError HOPE.request_adaptive_revision(
        first,
        "assumption_change";
        request = protected_request,
    )
    fixed_request = Dict("changes" => Dict("voll_usd_per_mwh" => 50000.0))
    @test_throws ArgumentError HOPE.request_adaptive_revision(
        first,
        "realization_local_resiting";
        request = fixed_request,
    )

    no_revision_spec = deepcopy(spec)
    no_revision_spec["allowed_revision_types"] = String[]
    no_revision_spec["approval_policy"]["require_human_for"] = String[]
    stopped = HOPE.stop_adaptive_study(
        HOPE.run_adaptive_study_iteration(
            HOPE.initialize_adaptive_study(no_revision_spec),
            _adaptive_handlers(failed_iteration),
        ),
        "NOT_ACCEPTED";
        reason = "No authorized revision addresses the verified finding.",
    )
    @test stopped["terminal_status"] == "NOT_ACCEPTED"

    budget_spec = deepcopy(spec)
    budget_spec["iteration_budget"] = 1
    exhausted = HOPE.run_adaptive_study_iteration(
        HOPE.initialize_adaptive_study(budget_spec),
        _adaptive_handlers(failed_iteration),
    )
    @test exhausted["terminal_status"] == "INCONCLUSIVE"

    mktempdir() do directory
        destination = joinpath(directory, "adaptive-study")
        paths = HOPE.write_adaptive_study_state(final, destination)
        @test all(isfile, values(paths))
        roundtrip = YAML.load_file(paths["state"])
        @test roundtrip["terminal_status"] == "ACCEPTED"
        @test roundtrip["spec_sha256"] == final["spec_sha256"]
        @test_throws ArgumentError HOPE.write_adaptive_study_state(final, destination)
    end
end
