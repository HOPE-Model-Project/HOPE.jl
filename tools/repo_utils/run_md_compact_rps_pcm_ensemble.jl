using HOPE
using CSV
using DataFrames
using SHA
using YAML

const ROOT = dirname(dirname(@__DIR__))
const MODEL_CASES = joinpath(ROOT, "ModelCases")
const RPS_EXAMPLE = joinpath(MODEL_CASES, "MD_COMPACT_RPS_REALIZATION_EXAMPLE_V1")

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

function _scale_compact_pcm_load!(input::AbstractDict, multiplier::Float64)
    multiplier > 0.0 || throw(ArgumentError("load_multiplier must be positive."))
    multiplier == 1.0 && return input
    zones = input["Zonedata"]
    buses = input["Busdata"]
    maryland_zones = Set(
        strip.(string.(zones.Zone_id[strip.(string.(zones.State)).=="MD"])),
    )
    maryland_buses = Set(
        strip.(string.(buses.Bus_id[strip.(string.(buses.State)).=="MD"])),
    )
    for (key, identifiers) in
        (("Loaddata", maryland_zones), ("NodalLoaddata", maryland_buses))
        haskey(input, key) || throw(ArgumentError("PCM input is missing $(key)."))
        table = input[key]
        columns = intersect(collect(identifiers), names(table))
        isempty(columns) && throw(
            ArgumentError("PCM input $(key) has no Maryland load columns to scale."),
        )
        for name in columns
            table[!, name] = Float64.(table[!, name]) .* multiplier
        end
    end
    return input
end

function run_compact_pcm_ensemble(example::AbstractString, args::Vector{String})
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
        scenario = YAML.load_file(joinpath(example, "scenario.yml"))
        scenario_id = String(scenario["scenario_id"])
        pcm_case = joinpath(MODEL_CASES, String(scenario["pcm_parent_case"]))
        plan_path = joinpath(planning_case, "Planning", "unitized_capacity_plan.csv")
        plan = HOPE.load_capacity_plan(plan_path)
        gtep = HOPE.validate_hope(planning_case)
        pcm = HOPE.validate_hope(pcm_case)
        pcm_input = HOPE.add_compact_planning_proxies_to_pcm(pcm["input"], gtep["input"])
        load_multiplier =
            haskey(scenario, "load_multiplier") ? Float64(scenario["load_multiplier"]) : 1.0
        _scale_compact_pcm_load!(pcm_input, load_multiplier)
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
        policy = HOPE.load_realization_policy(joinpath(example, "realization_policy.yml"))
        templates =
            CSV.read(joinpath(example, "operational_resource_templates.csv"), DataFrame)
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
        cp(joinpath(example, "realization_policy.yml"), policy_path; force = false)
        YAML.write_file(
            assessment_path,
            Dict(
                "artifact_type" => assessment["artifact_type"],
                "schema_version" => 1,
                "scenario_id" => scenario_id,
                "planning_case" => planning_case,
                "planning_manifest" => joinpath(planning_case, "Planning", "manifest.yml"),
                "pcm_case" => pcm_case,
                "solver" => solver,
                "load_multiplier" => load_multiplier,
                "firm_external_contribution_mw" => sum(
                    CSV.read(
                        joinpath(example, "firm_external_contribution.csv"),
                        DataFrame,
                    ).Capacity_MW,
                ),
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
            shedding_path = joinpath(destination, "load_shedding_diagnostics.csv")
            CSV.write(selected_path, member["selected_projects"])
            CSV.write(fast_path, member["fast_screen"]["checks"])
            CSV.write(transfer_path, member["transfer_reconciliation"]["checks"])
            CSV.write(
                shedding_path,
                assessment["evidence"][variant]["load_shedding_diagnostics"],
            )
            append!(member_files, [selected_path, fast_path, transfer_path, shedding_path])
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
                "artifact_type" => "HOPE.compact_pcm_ensemble_manifest",
                "schema_version" => 1,
                "scenario_id" => scenario_id,
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

function main(args::Vector{String} = ARGS)
    return run_compact_pcm_ensemble(RPS_EXAMPLE, args)
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
