using CSV
using DataFrames
using HOPE
using SHA
using Test
using YAML

function _adaptive_test_manifest(directory, artifact_type, files)
    manifest = Dict(
        "artifact_type" => artifact_type,
        "schema_version" => 1,
        "files" => Dict(
            replace(relpath(path, directory), '\\' => '/') =>
                bytes2hex(sha256(read(path))) for path in files
        ),
    )
    YAML.write_file(joinpath(directory, "manifest.yml"), manifest)
end

function _write_adaptive_compact_artifacts(root; accepted = false)
    planning_case = joinpath(root, "planning")
    planning = joinpath(planning_case, "Planning")
    ensemble = joinpath(root, "ensemble")
    mkpath(planning)
    mkpath(ensemble)
    result_path = joinpath(planning, "planning_result.yml")
    plan_path = joinpath(planning, "unitized_capacity_plan.csv")
    YAML.write_file(
        result_path,
        Dict(
            "termination_status" => "OPTIMAL",
            "objective_usd" => 853242952.0,
            "load_shedding_mwh" => 0.0,
            "new_generation_mw" => 1674.2867,
        ),
    )
    CSV.write(
        plan_path,
        DataFrame(
            Plan_Item_ID = ["P1", "P2", "P3"],
            Resource_Kind = fill("generation", 3),
            Zone = fill(accepted ? "PEPCO" : "BGE", 3),
            Type = fill("NGCC", 3),
            Build_MW = fill(558.0956, 3),
            Build_MWh = zeros(3),
        ),
    )
    _adaptive_test_manifest(
        planning,
        "HOPE.compact_planning_manifest",
        [result_path, plan_path],
    )

    findings_path = joinpath(ensemble, "ensemble_findings.csv")
    variants = ["balanced_permitting", "least_cost", "environmental_caution", "grid_ready"]
    accepted_values = accepted ? [false, true, false, false] : fill(false, 4)
    shedding = accepted ? [11038.0, 0.0, 10989.0, 11274.0] : fill(11596.0, 4)
    findings = DataFrame(
        Variant = variants,
        Classification = [
            value ? "ACCEPTED" : "ACCEPTANCE_FAILED" for value in accepted_values
        ],
        Accepted = accepted_values,
        HumanReviewRequired = accepted ? [true, false, true, true] :
                              [false, false, true, false],
        LoadSheddingMWh = shedding,
        NewGenerationDispatchMWh = accepted ? [55320.0, 69238.0, 68599.0, 50649.0] :
                                   fill(50010.0, 4),
    )
    CSV.write(findings_path, findings)
    files = [findings_path]
    for (variant, value) in zip(variants, shedding)
        member = joinpath(ensemble, "members", variant)
        mkpath(member)
        diagnostic = joinpath(member, "load_shedding_diagnostics.csv")
        CSV.write(
            diagnostic,
            DataFrame(
                Zone = value > 0 ? ["PEPCO"] : String[],
                TimeIndex = value > 0 ? [85] : Int[],
                LoadSheddingMW = value > 0 ? [min(value, 930.959)] : Float64[],
            ),
        )
        push!(files, diagnostic)
    end
    for filename in (
        "candidate_project_catalog.csv",
        "realization_allocations.csv",
        "realization_screening.csv",
    )
        path = joinpath(ensemble, filename)
        CSV.write(path, DataFrame(ID = [1]))
        push!(files, path)
    end
    _adaptive_test_manifest(ensemble, "HOPE.compact_pcm_ensemble_manifest", files)
    return planning_case, ensemble
end

@testset "Adaptive compact-artifact execution bridge" begin
    spec = HOPE.load_holistic_study_spec(
        joinpath(@__DIR__, "fixtures", "adaptive_study_v1", "md_energy_thermal_study.yml"),
    )
    mktempdir() do root
        planning, ensemble = _write_adaptive_compact_artifacts(root)
        state = HOPE.advance_adaptive_study_from_compact_artifacts(
            HOPE.initialize_adaptive_study(spec),
            planning,
            ensemble,
        )
        @test state["stage"] == "VERIFIED"
        @test state["terminal_status"] == "ACTIVE"
        @test state["attempts"][1]["artifacts"]["gtep"]["build_zones"] == ["BGE"]
        pcm = state["attempts"][1]["artifacts"]["pcm"]
        @test pcm["affected_zones"] == ["PEPCO"]
        @test pcm["load_shedding_mwh_max"] == 11596.0
        @test state["attempts"][1]["verification"]["accepted_count"] == 0

        open(joinpath(ensemble, "ensemble_findings.csv"), "a") do io
            println(io, "tamper")
        end
        @test_throws ArgumentError HOPE.advance_adaptive_study_from_compact_artifacts(
            HOPE.initialize_adaptive_study(spec),
            planning,
            ensemble,
        )
    end
end
