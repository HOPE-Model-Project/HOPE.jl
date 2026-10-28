using HOPE
using YAML

const ROOT = dirname(dirname(@__DIR__))
const EXAMPLE = joinpath(@__DIR__, "examples", "maryland_incremental_project_siting_v1")
const PARENT_GTEP = joinpath(ROOT, "ModelCases", "MD_GTEP_RPS20_4zone_public_case")

function usage(io::IO = stdout)
    println(
        io,
        "Usage: julia --project=. tools/repo_utils/diagnose_md_incremental_planning_feedback.jl " *
        "[output_directory]",
    )
end

function main(args::Vector{String} = ARGS)
    length(args) <= 1 || begin
        usage(stderr)
        return 2
    end
    destination =
        isempty(args) ?
        joinpath(
            ROOT,
            "artifacts",
            "computed_realization_runs",
            "md_incremental_planning_diagnostic_v1",
        ) : abspath(only(args))
    try
        plan = HOPE.load_capacity_plan(joinpath(EXAMPLE, "capacity_plan.csv"))
        assessment = YAML.load_file(joinpath(EXAMPLE, "ensemble_assessment_observed.yml"))
        context = YAML.load_file(joinpath(EXAMPLE, "scenario.yml"))
        diagnostic =
            HOPE.diagnose_gtep_feedback_context(PARENT_GTEP, plan, assessment, context)
        paths = HOPE.write_gtep_feedback_diagnostic(diagnostic, destination)
        println("HOPE_PLANNING_DIAGNOSTIC=", diagnostic["classification"])
        println(
            "HOPE_CANDIDATE_HEADROOM_REVISION_SUPPORTED=",
            diagnostic["candidate_headroom_revision_supported"],
        )
        println("HOPE_RECOMMENDED_ACTION=", diagnostic["recommended_action"])
        println("HOPE_DIAGNOSTIC_MANIFEST=", paths["manifest"])
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
