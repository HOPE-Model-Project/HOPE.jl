using HOPE

function usage(io::IO = stdout)
    println(
        io,
        "Usage: julia --project=. tools/repo_utils/compute_nodal_realizations.jl " *
        "<capacity_plan.csv> <candidate_site_catalog.csv> <realization_policy.yml> " *
        "<output_directory>",
    )
end

function main(args::Vector{String} = ARGS)
    if length(args) != 4
        usage(stderr)
        return 2
    end
    try
        result = HOPE.write_computed_realization_set(
            abspath(args[1]),
            abspath(args[2]),
            abspath(args[3]),
            abspath(args[4]),
        )
        println("HOPE_REALIZATION_VARIANTS=", join(result["summary"].Variant, ","))
        println("HOPE_REALIZATION_ALLOCATIONS=", result["paths"]["allocations"])
        println("HOPE_REALIZATION_MANIFEST=", result["paths"]["manifest"])
        return 0
    catch err
        showerror(stderr, err)
        println(stderr)
        return 1
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
