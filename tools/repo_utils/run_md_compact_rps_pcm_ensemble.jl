using HOPE
using CSV
using DataFrames
using SHA
using YAML

const ROOT = dirname(dirname(@__DIR__))
const EXAMPLE = joinpath(@__DIR__, "examples", "md_compact_rps_planning_v1")
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
        "Usage: julia --project=. tools/repo_utils/run_md_compact_rps_pcm_ensemble.jl " *
        "<solved_planning_case> <output_directory> [solver]",
    )
end

function main(args::Vector{String} = ARGS)
    length(args) in (2, 3) || begin
        usage(stderr)
        return 2
    end
    planning_case = abspath(args[1])
    output_directory = abspath(args[2])
    solver = length(args) == 3 ? args[3] : "highs"
    ispath(output_directory) && begin
        println(stderr, "Output already exists: $(output_directory)")
        return 2
    end
    try
        plan_path = joinpath(planning_case, "Planning", "unitized_capacity_plan.csv")
        plan = HOPE.load_capacity_plan(plan_path)
        gtep = HOPE.validate_hope(planning_case)
        pcm = HOPE.validate_hope(PCM_CASE)
        pcm_input = HOPE.add_compact_planning_proxies_to_pcm(pcm["input"], gtep["input"])
        generation_candidates = gtep["input"]["Gendata_candidate"]
        storage_candidates = gtep["input"]["Estoragedata_candidate"]
        branchdata = pcm_input["Branchdata"]
        topology_catalog = HOPE.build_candidate_site_catalog_from_pcm(
            generation_candidates,
            storage_candidates,
            pcm_input["Gendata"],
            pcm_input["Busdata"];
            branchdata = branchdata,
            sites_per_zone = 20,
        )
        project_catalog = HOPE.build_unitized_project_catalog(
            plan,
            topology_catalog,
            branchdata;
            alternatives_per_group = 18,
            hard_exclusions_per_group = 3,
            review_candidates_per_group = 3,
        )
        policy = HOPE.load_realization_policy(joinpath(EXAMPLE, "realization_policy.yml"))
        templates =
            CSV.read(joinpath(EXAMPLE, "operational_resource_templates.csv"), DataFrame)
        physical = HOPE.load_holistic_physical_realization(
            joinpath(planning_case, "Settings", "HOPE_physical_realization.yml"),
        )
        prepared = HOPE.prepare_pcm_realization_ensemble(
            plan,
            project_catalog,
            policy,
            gtep["input"],
            gtep["config"],
            pcm_input,
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
        catalog_path = joinpath(output_directory, "candidate_project_catalog.csv")
        allocation_path = joinpath(output_directory, "realization_allocations.csv")
        screening_path = joinpath(output_directory, "realization_screening.csv")
        preflight_path = joinpath(output_directory, "ensemble_preflight_summary.csv")
        findings_path = joinpath(output_directory, "ensemble_findings.csv")
        assessment_path = joinpath(output_directory, "ensemble_assessment.yml")
        policy_path = joinpath(output_directory, "realization_policy.yml")
        CSV.write(catalog_path, project_catalog)
        CSV.write(allocation_path, prepared["realization"]["allocations"])
        CSV.write(screening_path, prepared["realization"]["screening"])
        CSV.write(preflight_path, prepared["summary"])
        CSV.write(findings_path, assessment["findings"])
        cp(joinpath(EXAMPLE, "realization_policy.yml"), policy_path; force = false)
        YAML.write_file(
            assessment_path,
            Dict(
                "artifact_type" => assessment["artifact_type"],
                "schema_version" => 1,
                "planning_case" => planning_case,
                "planning_manifest" => joinpath(planning_case, "Planning", "manifest.yml"),
                "pcm_case" => PCM_CASE,
                "solver" => solver,
                "thresholds" => assessment["thresholds"],
                "findings" => _yaml_rows(assessment["findings"]),
            ),
        )
        members_directory = joinpath(output_directory, "members")
        mkpath(members_directory)
        member_files = String[]
        for variant in String.(prepared["summary"].Variant)
            destination = joinpath(members_directory, variant)
            mkpath(destination)
            member = prepared["members"][variant]
            selected_path = joinpath(destination, "selected_projects.csv")
            fast_path = joinpath(destination, "fast_screen.csv")
            transfer_path = joinpath(destination, "transfer_reconciliation.csv")
            CSV.write(selected_path, member["selected_projects"])
            CSV.write(fast_path, member["fast_screen"]["checks"])
            CSV.write(transfer_path, member["transfer_reconciliation"]["checks"])
            append!(member_files, [selected_path, fast_path, transfer_path])
        end
        files = [
            catalog_path,
            allocation_path,
            screening_path,
            preflight_path,
            findings_path,
            assessment_path,
            policy_path,
            member_files...,
        ]
        manifest_path = joinpath(output_directory, "manifest.yml")
        YAML.write_file(
            manifest_path,
            Dict(
                "artifact_type" => "HOPE.compact_rps_pcm_ensemble_manifest",
                "schema_version" => 1,
                "files" => Dict(
                    replace(relpath(path, output_directory), '\\' => '/') =>
                        bytes2hex(sha256(read(path))) for path in files
                ),
            ),
        )
        println("HOPE_COMPACT_PCM_ENSEMBLE=completed")
        println("HOPE_COMPACT_PCM_PROJECTS=", nrow(plan))
        println(
            "HOPE_COMPACT_PCM_ELIGIBLE_CANDIDATES=",
            count(prepared["realization"]["screening"].ScreenedIn),
        )
        for row in eachrow(assessment["findings"])
            println(
                "HOPE_COMPACT_VARIANT_",
                uppercase(row.Variant),
                "=",
                row.Classification,
            )
        end
        println("HOPE_COMPACT_PCM_MANIFEST=", manifest_path)
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
