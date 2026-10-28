using HOPE
using YAML

function usage(io::IO = stdout)
    println(
        io,
        "Usage: julia --project=. tools/repo_utils/materialize_gtep_child_scenario.jl " *
        "<parent_gtep_case> <revision_request.yml> <revision_decision.yml> " *
        "<child_scenario_spec.yml> <child_case_directory>",
    )
end

function main(args::Vector{String} = ARGS)
    length(args) == 5 || begin
        usage(stderr)
        return 2
    end
    parent_case, request_path, decision_path, spec_path, child_case = args
    try
        request = YAML.load_file(abspath(request_path))
        decision = YAML.load_file(abspath(decision_path))
        specification = YAML.load_file(abspath(spec_path))
        result = HOPE.materialize_approved_gtep_child_scenario(
            parent_case,
            request,
            decision,
            specification,
            child_case,
        )
        println("HOPE_GTEP_CHILD_SCENARIO=materialized_pending_gtep_solve")
        println("HOPE_CHILD_CASE=", result["child_case"])
        println(
            "HOPE_ADDITIONAL_CANDIDATE_LIMIT_MW=",
            result["lineage"]["materialized_additional_nameplate_mw"],
        )
        println("HOPE_CHILD_LINEAGE=", result["paths"]["lineage"])
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
