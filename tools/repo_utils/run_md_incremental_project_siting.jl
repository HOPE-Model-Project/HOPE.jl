using HOPE

const EXAMPLE_DIRECTORY = joinpath(
    @__DIR__,
    "examples",
    "maryland_incremental_project_siting_v1",
)

function usage(io::IO = stdout)
    println(
        io,
        "Usage: julia --project=. tools/repo_utils/run_md_incremental_project_siting.jl " *
        "[output_directory]",
    )
end

function main(args::Vector{String} = ARGS)
    length(args) <= 1 || begin
        usage(stderr)
        return 2
    end
    output_directory = if isempty(args)
        joinpath(
            dirname(dirname(@__DIR__)),
            "artifacts",
            "computed_realization_runs",
            "md_incremental_project_siting_v1",
        )
    else
        abspath(only(args))
    end
    try
        result = HOPE.write_computed_realization_set(
            joinpath(EXAMPLE_DIRECTORY, "capacity_plan.csv"),
            joinpath(EXAMPLE_DIRECTORY, "candidate_project_catalog.csv"),
            joinpath(EXAMPLE_DIRECTORY, "realization_policy.yml"),
            output_directory,
        )
        allocations = result["allocations"]
        screening = result["screening"]
        println("HOPE_MD_INCREMENTAL_PROJECT_SITING=passed")
        println("HOPE_REALIZATION_MANIFEST=", result["paths"]["manifest"])
        println(
            "HOPE_SCREENING_COUNTS=eligible:",
            count(screening.ScreenedIn),
            ",excluded:",
            count(.!screening.ScreenedIn),
            ",review:",
            count(screening.ReviewRequired),
        )
        for variant in result["summary"].Variant
            selected = allocations[allocations.Variant.==variant, :]
            length(unique(selected.PlanItemID)) == 9 || error(
                "Variant $(variant) did not realize all nine project blocks.",
            )
            length(unique(selected.CandidateSiteID)) == 9 || error(
                "Variant $(variant) reused a discrete candidate project.",
            )
            isapprox(sum(selected.AllocatedMW), 1700.0; atol = 1e-6) || error(
                "Variant $(variant) did not conserve the 1,700 MW plan.",
            )
            isapprox(sum(selected.AllocatedMWh), 800.0; atol = 1e-6) || error(
                "Variant $(variant) did not conserve the 800 MWh storage plan.",
            )
            selected_ids = join(selected.CandidateSiteID, ",")
            review_ids = join(
                selected.CandidateSiteID[selected.ReviewRequired],
                ",",
            )
            println("HOPE_VARIANT_", uppercase(variant), "_PROJECTS=", selected_ids)
            println(
                "HOPE_VARIANT_",
                uppercase(variant),
                "_HUMAN_REVIEW=",
                isempty(review_ids) ? "none" : review_ids,
            )
        end
        excluded = Set(screening.CandidateSiteID[.!screening.ScreenedIn])
        isempty(intersect(Set(allocations.CandidateSiteID), excluded)) || error(
            "A hard-excluded project appeared in an allocation.",
        )
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
