using HOPE
using CSV
using DataFrames
using JuMP
using SHA
using YAML

const ROOT = dirname(dirname(@__DIR__))
const EXAMPLE = joinpath(@__DIR__, "examples", "md_compact_rps_planning_v1")
const PARENT = joinpath(ROOT, "ModelCases", "MD_GTEP_RPS20_4zone_public_case")

function _model_sum(model, name::Symbol)
    return haskey(JuMP.object_dictionary(model), name) ? sum(value.(model[name])) : 0.0
end

function usage(io::IO = stdout)
    println(
        io,
        "Usage: julia --project=. tools/repo_utils/run_md_compact_rps_planning.jl " *
        "<output_case_directory> [solver]",
    )
end

function main(args::Vector{String} = ARGS)
    length(args) in (1, 2) || begin
        usage(stderr)
        return 2
    end
    destination = abspath(args[1])
    solver = length(args) == 2 ? args[2] : "highs"
    ispath(destination) && begin
        println(stderr, "Output case already exists: $(destination)")
        return 2
    end
    try
        contributions =
            CSV.read(joinpath(EXAMPLE, "firm_external_contribution.csv"), DataFrame)
        materialized = HOPE.materialize_compact_rps_gtep_case(
            PARENT,
            destination,
            contributions;
            marginal_cost_per_mwh = 0.0,
        )
        result = HOPE.run_hope(destination; solver_override = solver)
        model = result["solved_model"]
        continuous_plan = HOPE.capacity_plan_from_gtep(result["output"], result["input"])
        unitization_policy = YAML.load_file(joinpath(EXAMPLE, "unitization_policy.yml"))
        unitized = HOPE.unitize_capacity_plan(continuous_plan, unitization_policy)
        project_plan = unitized["capacity_plan"]

        planning_directory = joinpath(destination, "Planning")
        mkpath(planning_directory)
        continuous_path = joinpath(planning_directory, "continuous_capacity_plan.csv")
        project_path = joinpath(planning_directory, "unitized_capacity_plan.csv")
        audit_path = joinpath(planning_directory, "unitization_audit.csv")
        result_path = joinpath(planning_directory, "planning_result.yml")
        policy_path = joinpath(planning_directory, "unitization_policy.yml")
        CSV.write(continuous_path, continuous_plan)
        CSV.write(project_path, project_plan)
        CSV.write(audit_path, unitized["audit"])
        cp(joinpath(EXAMPLE, "unitization_policy.yml"), policy_path; force = false)

        rps_slack = _model_sum(model, :pt_rps)
        load_shedding = _model_sum(model, :p_LS)
        metrics = Dict{String,Any}(
            "artifact_type" => "HOPE.compact_rps_planning_result",
            "schema_version" => 1,
            "solver" => solver,
            "termination_status" => string(termination_status(model)),
            "primal_status" => string(primal_status(model)),
            "objective_usd" => objective_value(model),
            "rps_slack_mwh" => rps_slack,
            "load_shedding_mwh" => load_shedding,
            "continuous_plan_items" => nrow(continuous_plan),
            "unitized_project_count" => nrow(project_plan),
            "new_generation_mw" => sum(
                continuous_plan.Build_MW[continuous_plan.Resource_Kind.=="generation"],
            ),
            "new_storage_power_mw" => sum(
                continuous_plan.Build_MW[continuous_plan.Resource_Kind.=="storage"],
            ),
            "new_storage_energy_mwh" => sum(continuous_plan.Build_MWh),
            "firm_external_contribution_mw" => sum(contributions.Capacity_MW),
            "capacity_plan_contract" => Dict(
                "derivation_method" => "solved_gtep_with_declared_firm_external_supply",
                "enforced_constraints" =>
                    ["system_planning_reserve_margin", "maryland_local_annual_rps"],
            ),
        )
        YAML.write_file(result_path, metrics)
        files = [continuous_path, project_path, audit_path, result_path, policy_path]
        manifest_path = joinpath(planning_directory, "manifest.yml")
        YAML.write_file(
            manifest_path,
            Dict(
                "artifact_type" => "HOPE.compact_rps_planning_manifest",
                "schema_version" => 1,
                "files" =>
                    Dict(basename(path) => bytes2hex(sha256(read(path))) for path in files),
            ),
        )

        contract_path = materialized["paths"]["contract"]
        contract = YAML.load_file(contract_path)
        contract["status"] = "solved_capacity_plan_published"
        contract["planning_manifest"] = "Planning/manifest.yml"
        YAML.write_file(contract_path, contract)
        case_manifest_path = joinpath(destination, "manifest.yml")
        case_manifest = YAML.load_file(case_manifest_path)
        case_manifest["status"] = "SOLVED"
        case_manifest["planning_manifest"] = "Planning/manifest.yml"
        case_manifest["validation"] = Dict(
            "solver" => solver,
            "status" => metrics["termination_status"],
            "objective_usd" => metrics["objective_usd"],
            "load_shedding_mwh" => load_shedding,
            "rps_slack_mwh" => rps_slack,
            "unitized_project_count" => nrow(project_plan),
        )
        YAML.write_file(case_manifest_path, case_manifest)

        println("HOPE_COMPACT_PLANNING_STATUS=", metrics["termination_status"])
        println("HOPE_COMPACT_RPS_SLACK_MWH=", rps_slack)
        println("HOPE_COMPACT_LOAD_SHEDDING_MWH=", load_shedding)
        println("HOPE_COMPACT_CONTINUOUS_PLAN_ITEMS=", nrow(continuous_plan))
        println("HOPE_COMPACT_UNITIZED_PROJECTS=", nrow(project_plan))
        for row in eachrow(unitized["audit"])
            println(
                "HOPE_COMPACT_",
                uppercase(row.Type),
                "_PROJECTS=",
                row.ProjectCount,
                ";TOTAL_MW=",
                row.ParentMW,
                ";PROJECT_MW=",
                row.ProjectMW,
                ";TOTAL_MWH=",
                row.ParentMWh,
            )
        end
        println("HOPE_COMPACT_PLANNING_MANIFEST=", manifest_path)
        return 0
    catch error
        showerror(stderr, error, catch_backtrace())
        println(stderr)
        return 1
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
