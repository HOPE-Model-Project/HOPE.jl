using HOPE
using Test
using YAML

const FEEDBACK_EXAMPLE = joinpath(@__DIR__, "fixtures", "adaptive_feedback_v1")

@testset "Adaptive holistic feedback contracts" begin
    assessment = YAML.load_file(joinpath(FEEDBACK_EXAMPLE, "ensemble_assessment.yml"))
    policy = HOPE.load_feedback_policy(joinpath(FEEDBACK_EXAMPLE, "feedback_policy.yml"))
    parent =
        Dict("assessment" => Dict("artifact_id" => "assessment-001", "sha256" => "abc"))
    package = HOPE.build_holistic_feedback(
        assessment,
        policy;
        study_id = "md-incremental-feedback-v1",
        iteration = 1,
        parent_artifacts = parent,
    )

    @test package["terminal_status"] == "REVISION_REQUIRED"
    @test length(package["findings"]) == 2
    @test length(package["revision_requests"]) == 2
    rps = only(filter(finding -> finding["gate"] == "rps_slack", package["findings"]))
    @test rps["classification"] == "planning_structural"
    @test rps["responsible_owner"] == "gtep"
    @test rps["observation"]["distinct_physical_realizations"] == 3
    @test rps["observation"]["cross_realization_requirement_met"]
    @test length(rps["observation"]["affected_variants"]) == 4
    @test rps["inference"]["authority"] == "nonbinding"

    request = only(
        filter(item -> item["requested_owner"] == "gtep", package["revision_requests"]),
    )
    @test request["approval_required"]
    @test request["approval_class"] == "material_planning_assumption"
    @test any(
        occursin("lower the RPS", string(action)) for action in request["forbidden_actions"]
    )
    @test request["status"] == "proposed"

    decision = HOPE.record_revision_decision(
        request,
        "approved";
        approver = "human-reviewer",
        rationale = "Authorize one bounded child GTEP scenario; preserve all policy gates.",
        decided_at = "2026-10-28T15:00:00-04:00",
    )
    @test decision["decision"] == "approved"
    @test decision["request_id"] == request["request_id"]
    @test request["status"] == "proposed"

    repeated = HOPE.build_holistic_feedback(
        assessment,
        policy;
        study_id = "md-incremental-feedback-v1",
        iteration = 1,
        parent_artifacts = parent,
    )
    @test getindex.(package["findings"], "finding_id") ==
          getindex.(repeated["findings"], "finding_id")
    @test getindex.(package["revision_requests"], "request_id") ==
          getindex.(repeated["revision_requests"], "request_id")

    accepted = Dict(
        "thresholds" => assessment["thresholds"],
        "findings" => [
            Dict(
                "Variant" => "baseline",
                "Classification" => "ACCEPTED",
                "HumanReviewRequired" => false,
                "ReusedFrom" => "",
                "LoadSheddingMWh" => 0.0,
                "RPSSlackMWh" => 0.0,
            ),
        ],
    )
    accepted_package =
        HOPE.build_holistic_feedback(accepted, policy; study_id = "accepted-study")
    @test accepted_package["terminal_status"] == "ACCEPTED"
    @test isempty(accepted_package["findings"])
    @test isempty(accepted_package["revision_requests"])

    one_failure = deepcopy(accepted)
    one_failure["findings"][1]["Classification"] = "ACCEPTANCE_FAILED"
    one_failure["findings"][1]["RPSSlackMWh"] = 10.0
    weak_package = HOPE.build_holistic_feedback(
        one_failure,
        policy;
        study_id = "one-realization-study",
    )
    @test only(weak_package["findings"])["classification"] ==
          "insufficient_cross_realization_evidence"
    @test only(weak_package["findings"])["responsible_owner"] == "verifier"
    @test isempty(weak_package["revision_requests"])

    construction_failure = deepcopy(accepted)
    construction_failure["findings"][1]["Classification"] = "MODEL_CONSTRUCTION_FAILED"
    failed_package = HOPE.build_holistic_feedback(
        construction_failure,
        policy;
        study_id = "runtime-failure-study",
    )
    @test failed_package["terminal_status"] == "REVISION_REQUIRED"
    @test only(failed_package["findings"])["classification"] ==
          "execution_or_numerical_failure"
    @test only(failed_package["revision_requests"])["requested_owner"] == "pcm_runtime"

    final_iteration = HOPE.build_holistic_feedback(
        assessment,
        policy;
        study_id = "bounded-study",
        iteration = 3,
    )
    @test final_iteration["terminal_status"] == "INCONCLUSIVE"
    @test isempty(final_iteration["revision_requests"])

    mktempdir() do directory
        destination = joinpath(directory, "feedback")
        paths = HOPE.write_holistic_feedback_package(package, destination)
        @test all(isfile, values(paths))
        @test_throws ArgumentError HOPE.write_holistic_feedback_package(
            package,
            destination,
        )
    end
end
