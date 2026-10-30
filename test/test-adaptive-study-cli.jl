using HOPE
using Test
using YAML

include(
    joinpath(@__DIR__, "..", "tools", "repo_utils", "run_adaptive_thermal_iteration.jl"),
)

@testset "Adaptive study lifecycle CLI" begin
    spec_path =
        joinpath(@__DIR__, "fixtures", "adaptive_study_v1", "md_energy_thermal_study.yml")
    mktempdir() do root
        workspace = joinpath(root, "study")
        @test adaptive_study_cli(["initialize", workspace, spec_path]) == 0
        initialized = _load_adaptive_state(workspace)
        @test initialized["stage"] == "SPECIFIED"
        @test _adaptive_iteration_example(initialized) == ADAPTIVE_BASE_CASE

        handlers = Dict{String,Any}(
            "gtep" => _ -> Dict("build_zone" => "BGE"),
            "realization" => _ -> Dict("variants" => ["least_cost"]),
            "pcm" => _ -> Dict("affected_zone" => "PEPCO"),
            "verification" =>
                _ -> [
                    Dict(
                        "Variant" => "least_cost",
                        "Accepted" => false,
                        "HumanReviewRequired" => false,
                    ),
                ],
        )
        failed = HOPE.run_adaptive_study_iteration(initialized, handlers)
        _write_adaptive_state_atomic(failed, workspace)

        request_path = joinpath(root, "revision.yml")
        YAML.write_file(
            request_path,
            Dict(
                "revision_type" => "candidate_zone_eligibility",
                "request" => Dict(
                    "finding" => "PEPCO contains the binding operational shortfall.",
                    "changes" =>
                        Dict("allowed_generation_candidate_zones" => ["PEPCO"]),
                    "unchanged_controls" => [
                        "planning_reserve_margin",
                        "voll_usd_per_mwh",
                        "load_multiplier",
                    ],
                ),
            ),
        )
        @test adaptive_study_cli(["request-revision", workspace, request_path]) == 0
        requested = _load_adaptive_state(workspace)
        @test requested["stage"] == "REVISION_REQUESTED"

        decision_path = joinpath(root, "decision.yml")
        YAML.write_file(
            decision_path,
            Dict(
                "decision" => "approved",
                "approver" => "test-human",
                "rationale" => "Allow local resiting while keeping the planning controls fixed.",
            ),
        )
        @test adaptive_study_cli(["record-decision", workspace, decision_path]) == 0
        @test adaptive_study_cli(["start-child", workspace]) == 0
        child = _load_adaptive_state(workspace)
        @test child["iteration"] == 2
        @test child["stage"] == "SPECIFIED"
        @test _adaptive_iteration_example(child) == ADAPTIVE_PEPCO_CASE
        @test isfile(joinpath(workspace, "manifest.yml"))
    end
end
