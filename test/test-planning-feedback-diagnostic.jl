using HOPE
using Test
using CSV
using DataFrames
using YAML

function _write_diagnostic_parent(path::AbstractString; solar_built_mw::Float64 = 50.0)
    data = joinpath(path, "Data")
    output = joinpath(path, "output")
    settings = joinpath(path, "Settings")
    mkpath(data)
    mkpath(output)
    mkpath(settings)
    YAML.write_file(
        joinpath(settings, "HOPE_model_settings.yml"),
        Dict(
            "DataCase" => "Data/",
            "model_mode" => "GTEP",
            "resource_aggregation" => 0,
            "endogenous_rep_day" => 0,
            "external_rep_day" => 0,
        ),
    )
    CSV.write(
        joinpath(data, "gendata_candidate.csv"),
        DataFrame(
            :Candidate_ID => ["SOLAR_1", "NGCC_1"],
            :Zone => ["Z1", "Z1"],
            :Type => ["SolarPV", "NGCC"],
            Symbol("Pmax (MW)") => [100.0, 200.0],
            :Flag_RPS => [1, 0],
        ),
    )
    CSV.write(
        joinpath(output, "capacity.csv"),
        DataFrame(
            :Candidate_ID => ["SOLAR_1", "NGCC_1"],
            :EC_Category => ["Candidate", "Candidate"],
            Symbol("Capacity_FIN (MW)") => [solar_built_mw, 100.0],
        ),
    )
    YAML.write_file(
        joinpath(path, "manifest.yml"),
        Dict("validation" => Dict("rps_slack_mwh" => 0.0)),
    )
end

function _diagnostic_plan()
    return DataFrame(
        Plan_Item_ID = ["SOLAR_PLAN", "NGCC_PLAN"],
        Resource_Kind = ["generation", "generation"],
        Zone = ["Z1", "Z1"],
        Type = ["SolarPV", "NGCC"],
        Build_MW = [25.0, 75.0],
        Build_MWh = [missing, missing],
    )
end

function _diagnostic_assessment()
    return Dict(
        "thresholds" => Dict("max_rps_slack_mwh" => 1e-6),
        "findings" => [Dict("Variant" => "baseline", "RPSSlackMWh" => 10.0)],
    )
end

@testset "Planning feedback diagnosis" begin
    mktempdir() do directory
        parent = joinpath(directory, "parent")
        _write_diagnostic_parent(parent)
        context = Dict(
            "capacity_plan_contract" =>
                Dict("enforced_constraints" => ["planning_reserve_margin"]),
        )
        diagnostic = HOPE.diagnose_gtep_feedback_context(
            parent,
            _diagnostic_plan(),
            _diagnostic_assessment(),
            context,
        )
        @test diagnostic["classification"] == "capacity_plan_policy_contract_gap"
        @test !diagnostic["candidate_headroom_revision_supported"]
        @test diagnostic["evidence"]["parent_gtep_rps_passed"]
        @test !diagnostic["evidence"]["capacity_plan_enforced_rps"]
        @test diagnostic["evidence"]["aggregate_rps_candidate_headroom_mw"] == 50.0
        @test sum(diagnostic["capacity_plan_summary"].PlanMW) == 100.0

        destination = joinpath(directory, "diagnostic")
        paths = HOPE.write_gtep_feedback_diagnostic(diagnostic, destination)
        @test all(isfile, values(paths))
        @test_throws ArgumentError HOPE.write_gtep_feedback_diagnostic(
            diagnostic,
            destination,
        )

        constrained_context =
            Dict("capacity_plan_contract" => Dict("enforced_constraints" => ["annual_rps"]))
        unresolved = HOPE.diagnose_gtep_feedback_context(
            parent,
            _diagnostic_plan(),
            _diagnostic_assessment(),
            constrained_context,
        )
        @test unresolved["classification"] ==
              "rps_failure_requires_planning_model_diagnosis"

        exhausted_parent = joinpath(directory, "exhausted")
        _write_diagnostic_parent(exhausted_parent; solar_built_mw = 100.0)
        exhausted = HOPE.diagnose_gtep_feedback_context(
            exhausted_parent,
            _diagnostic_plan(),
            _diagnostic_assessment(),
            constrained_context,
        )
        @test exhausted["classification"] == "qualifying_candidate_envelope_exhausted"
        @test exhausted["candidate_headroom_revision_supported"]
    end
end
