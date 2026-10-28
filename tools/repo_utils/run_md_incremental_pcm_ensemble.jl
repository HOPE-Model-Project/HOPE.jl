using HOPE
using CSV
using DataFrames
using YAML

const ROOT = dirname(dirname(@__DIR__))
const EXAMPLE_DIRECTORY =
    joinpath(@__DIR__, "examples", "maryland_incremental_project_siting_v1")
const GTEP_CASE = joinpath(ROOT, "ModelCases", "MD_GTEP_RPS20_4zone_public_case")
const PCM_CASE = joinpath(ROOT, "ModelCases", "MD_PCM_RPS20_transmission_public_case")

function _yaml_rows(table::AbstractDataFrame)
    return [
        Dict(string(name) => row[name] for name in propertynames(row)) for
        row in eachrow(table)
    ]
end

function usage(io::IO = stdout)
    println(
        io,
        "Usage: julia --project=. tools/repo_utils/run_md_incremental_pcm_ensemble.jl " *
        "[output_directory] [solver]",
    )
end

function main(args::Vector{String} = ARGS)
    length(args) <= 2 || begin
        usage(stderr)
        return 2
    end
    output_directory =
        isempty(args) ?
        joinpath(
            ROOT,
            "artifacts",
            "computed_realization_runs",
            "md_incremental_pcm_ensemble_v1",
        ) : abspath(args[1])
    solver = length(args) == 2 ? args[2] : "highs"
    ispath(output_directory) && begin
        println(
            stderr,
            "Output already exists; choose a new immutable destination: $(output_directory)",
        )
        return 2
    end

    try
        plan = HOPE.load_capacity_plan(joinpath(EXAMPLE_DIRECTORY, "capacity_plan.csv"))
        catalog = HOPE.load_candidate_site_catalog(
            joinpath(EXAMPLE_DIRECTORY, "candidate_project_catalog.csv"),
        )
        policy = HOPE.load_realization_policy(
            joinpath(EXAMPLE_DIRECTORY, "realization_policy.yml"),
        )
        templates = CSV.read(
            joinpath(EXAMPLE_DIRECTORY, "operational_resource_templates.csv"),
            DataFrame,
        )
        gtep = HOPE.validate_hope(GTEP_CASE)
        pcm = HOPE.validate_hope(PCM_CASE)
        physical = HOPE.load_holistic_physical_realization(
            joinpath(GTEP_CASE, "Settings", "HOPE_physical_realization.yml"),
        )
        prepared = HOPE.prepare_pcm_realization_ensemble(
            plan,
            catalog,
            policy,
            gtep["input"],
            gtep["config"],
            pcm["input"],
            pcm["config"];
            physical_realization = physical,
            operational_templates = templates,
        )
        assessment = HOPE.assess_pcm_realization_ensemble(
            prepared,
            pcm["case_path"],
            pcm["config"];
            solver_override = solver,
        )

        mkpath(output_directory)
        CSV.write(
            joinpath(output_directory, "ensemble_preflight_summary.csv"),
            prepared["summary"],
        )
        CSV.write(
            joinpath(output_directory, "ensemble_findings.csv"),
            assessment["findings"],
        )
        members_directory = joinpath(output_directory, "members")
        mkpath(members_directory)
        for variant in String.(prepared["summary"].Variant)
            destination = joinpath(members_directory, variant)
            mkpath(destination)
            member = prepared["members"][variant]
            CSV.write(
                joinpath(destination, "selected_projects.csv"),
                member["selected_projects"],
            )
            CSV.write(
                joinpath(destination, "fast_screen.csv"),
                member["fast_screen"]["checks"],
            )
            CSV.write(
                joinpath(destination, "transfer_reconciliation.csv"),
                member["transfer_reconciliation"]["checks"],
            )
        end
        YAML.write_file(
            joinpath(output_directory, "ensemble_assessment.yml"),
            Dict(
                "schema_version" => 1,
                "artifact_type" => assessment["artifact_type"],
                "gtep_case" => basename(GTEP_CASE),
                "pcm_case" => basename(PCM_CASE),
                "solver" => solver,
                "thresholds" => assessment["thresholds"],
                "findings" => _yaml_rows(assessment["findings"]),
            ),
        )
        println("HOPE_MD_INCREMENTAL_PCM_ENSEMBLE=completed")
        println(
            "HOPE_ENSEMBLE_FINDINGS=",
            joinpath(output_directory, "ensemble_findings.csv"),
        )
        for row in eachrow(assessment["findings"])
            println("HOPE_VARIANT_", uppercase(row.Variant), "=", row.Classification)
        end
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
