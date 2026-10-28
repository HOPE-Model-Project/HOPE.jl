using HOPE
using Test
using CSV
using DataFrames
using YAML

function _write_child_parent_case(path::AbstractString)
    data = joinpath(path, "Data")
    settings = joinpath(path, "Settings")
    output = joinpath(path, "output")
    mkpath(data)
    mkpath(settings)
    mkpath(output)
    YAML.write_file(
        joinpath(settings, "HOPE_model_settings.yml"),
        Dict(
            "DataCase" => "Data/",
            "model_mode" => "GTEP",
            "resource_aggregation" => 0,
            "endogenous_rep_day" => 0,
            "external_rep_day" => 0,
            "inv_dcs_bin" => 0,
        ),
    )
    candidates = DataFrame(
        :Candidate_ID => ["SOLAR_1", "NGCC_1"],
        :Zone => ["Z1", "Z1"],
        :Type => ["SolarPV", "NGCC"],
        Symbol("Pmax (MW)") => [100.0, 200.0],
        :Flag_RPS => [1, 0],
    )
    CSV.write(joinpath(data, "gendata_candidate.csv"), candidates)
    CSV.write(
        joinpath(data, "rpspolicies.csv"),
        DataFrame(From_state = ["MD"], To_state = ["MD"], RPS = [0.2]),
    )
    CSV.write(
        joinpath(data, "single_parameter.csv"),
        DataFrame(planning_reserve_margin = [0.15]),
    )
    CSV.write(
        joinpath(data, "load_timeseries_regional.csv"),
        DataFrame(Hours = [1], Z1 = [100.0]),
    )
    YAML.write_file(
        joinpath(path, "manifest.yml"),
        Dict(
            "schema_version" => 1,
            "case_name" => "parent",
            "model_mode" => "GTEP",
            "data_subdir" => "Data/",
            "validation" => Dict("status" => "OPTIMAL"),
        ),
    )
    write(joinpath(output, "stale.csv"), "must not be copied\n")
    return candidates
end

function _approved_child_request()
    example = joinpath(
        @__DIR__,
        "..",
        "tools",
        "repo_utils",
        "examples",
        "maryland_incremental_project_siting_v1",
    )
    assessment = YAML.load_file(joinpath(example, "ensemble_assessment_observed.yml"))
    policy = HOPE.load_feedback_policy(joinpath(example, "feedback_policy.yml"))
    package =
        HOPE.build_holistic_feedback(assessment, policy; study_id = "child-scenario-test")
    return only(
        filter(
            request -> request["requested_owner"] == "gtep",
            package["revision_requests"],
        ),
    )
end

@testset "Approved immutable GTEP child scenario" begin
    mktempdir() do directory
        parent = joinpath(directory, "parent")
        original = _write_child_parent_case(parent)
        request = _approved_child_request()
        decision = HOPE.record_revision_decision(
            request,
            "approved";
            approver = "test-approver",
            rationale = "Approve one bounded test child; do not alter policy inputs.",
            decided_at = "2026-10-28T16:00:00-04:00",
        )
        changes = [
            Dict(
                "candidate_id" => "SOLAR_1",
                "before_max_mw" => 100.0,
                "after_max_mw" => 150.0,
                "rationale" => "Exercise the approved renewable candidate envelope.",
            ),
        ]
        spec = HOPE.build_gtep_child_scenario_spec(parent, request, decision, changes)
        child = joinpath(directory, "child")
        result = HOPE.materialize_approved_gtep_child_scenario(
            parent,
            request,
            decision,
            spec,
            child,
        )

        @test result["lineage"]["status"] == "materialized_pending_gtep_solve"
        @test result["lineage"]["materialized_additional_nameplate_mw"] == 50.0
        @test result["lineage"]["protected_data_files_unchanged"]
        @test result["lineage"]["gtep_run_status"] == "NOT_RUN"
        @test result["lineage"]["changed_data_files"] == ["gendata_candidate.csv"]
        @test !isdir(joinpath(child, "output"))
        revised = CSV.read(joinpath(child, "Data", "gendata_candidate.csv"), DataFrame)
        @test revised[revised.Candidate_ID.=="SOLAR_1", Symbol("Pmax (MW)")] == [150.0]
        @test CSV.read(joinpath(parent, "Data", "gendata_candidate.csv"), DataFrame) ==
              original
        @test YAML.load_file(joinpath(child, "manifest.yml"))["validation"]["status"] ==
              "NOT_RUN"
        @test all(isfile, values(result["paths"]))
        @test_throws ArgumentError HOPE.materialize_approved_gtep_child_scenario(
            parent,
            request,
            decision,
            spec,
            child,
        )

        rejected = HOPE.record_revision_decision(
            request,
            "rejected";
            approver = "test-approver",
            rationale = "Reject for test coverage.",
            decided_at = "2026-10-28T16:01:00-04:00",
        )
        @test_throws ArgumentError HOPE.build_gtep_child_scenario_spec(
            parent,
            request,
            rejected,
            changes,
        )

        excessive = HOPE.build_gtep_child_scenario_spec(
            parent,
            request,
            decision,
            [merge(only(changes), Dict("after_max_mw" => 2201.0))],
        )
        excessive_child = joinpath(directory, "excessive")
        @test_throws ArgumentError HOPE.materialize_approved_gtep_child_scenario(
            parent,
            request,
            decision,
            excessive,
            excessive_child,
        )
        @test !ispath(excessive_child)

        ineligible = HOPE.build_gtep_child_scenario_spec(
            parent,
            request,
            decision,
            [
                Dict(
                    "candidate_id" => "NGCC_1",
                    "before_max_mw" => 200.0,
                    "after_max_mw" => 250.0,
                ),
            ],
        )
        ineligible_child = joinpath(directory, "ineligible")
        @test_throws ArgumentError HOPE.materialize_approved_gtep_child_scenario(
            parent,
            request,
            decision,
            ineligible,
            ineligible_child,
        )
        @test !ispath(ineligible_child)
    end
end
