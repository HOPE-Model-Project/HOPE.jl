using Dates
using HOPE
using YAML

const PROJECT_ROOT = normpath(joinpath(@__DIR__, ".."))

const HOLISTIC_BENCHMARKS = Dict(
    "restricted" => (
        label = "Maryland restricted linkage",
        gtep = "MD_GTEP_restricted_linkage_case",
        pcm = "MD_PCM_restricted_linkage_case",
    ),
    "public-rps20" => (
        label = "Maryland public 20% RPS",
        gtep = "MD_GTEP_RPS20_4zone_public_case",
        pcm = "MD_PCM_RPS20_transmission_public_case",
    ),
)

function usage(io::IO = stdout)
    println(
        io,
        """
        Usage:
          julia --project=. scripts/run_holistic_regressions.jl [options]

        Options:
          --suite NAME         restricted, public-rps20, or all (default: restricted)
          --modelcases PATH    HOPEModelCases checkout (default: HOPE_MODELCASES_PATH or ./ModelCases)
          --solver NAME        Solver override without editing cases (default: HOPE_HOLISTIC_SOLVER or highs)
          --artifacts PATH     Root for compact audit artifacts (default: ./artifacts/holistic)
          --help               Show this message
        """,
    )
end

function parse_arguments(args::Vector{String})
    options = Dict{String,String}(
        "suite" => get(ENV, "HOPE_HOLISTIC_SUITE", "restricted"),
        "modelcases" =>
            get(ENV, "HOPE_MODELCASES_PATH", joinpath(PROJECT_ROOT, "ModelCases")),
        "solver" => get(ENV, "HOPE_HOLISTIC_SOLVER", "highs"),
        "artifacts" => get(
            ENV,
            "HOPE_HOLISTIC_ARTIFACT_DIR",
            joinpath(PROJECT_ROOT, "artifacts", "holistic"),
        ),
    )
    index = 1
    while index <= length(args)
        argument = args[index]
        if argument == "--help"
            usage()
            return nothing
        end
        argument in ("--suite", "--modelcases", "--solver", "--artifacts") ||
            throw(ArgumentError("Unknown argument: $(argument)"))
        index < length(args) || throw(ArgumentError("Missing value for $(argument)"))
        options[argument[3:end]] = args[index+1]
        index += 2
    end
    options["suite"] = lowercase(strip(options["suite"]))
    options["solver"] = lowercase(strip(options["solver"]))
    isempty(options["solver"]) && throw(ArgumentError("--solver must not be blank"))
    options["suite"] in (keys(HOLISTIC_BENCHMARKS)..., "all") || throw(
        ArgumentError(
            "Unsupported suite $(options["suite"]); choose restricted, public-rps20, or all",
        ),
    )
    options["modelcases"] = abspath(options["modelcases"])
    options["artifacts"] = abspath(options["artifacts"])
    return options
end

function selected_benchmarks(suite::AbstractString)
    names = suite == "all" ? collect(keys(HOLISTIC_BENCHMARKS)) : [String(suite)]
    return sort!(names)
end

function require_file(path::AbstractString, description::AbstractString)
    isfile(path) || throw(ArgumentError("Missing $(description): $(path)"))
    return path
end

function require_directory(path::AbstractString, description::AbstractString)
    isdir(path) || throw(ArgumentError("Missing $(description): $(path)"))
    return path
end

function copy_regression_artifacts(result::Dict, destination::AbstractString)
    mkpath(destination)
    for path in values(result["handoff_contract_paths"])
        require_file(path, "handoff artifact")
        cp(path, joinpath(destination, basename(path)); force = false)
    end
    for path in values(result["holistic_coverage_paths"])
        require_file(path, "coverage artifact")
        cp(path, joinpath(destination, basename(path)); force = false)
    end
    realized_inputs = joinpath(result["pcm_output_path"], "realized_inputs")
    require_directory(realized_inputs, "realized-input artifact directory")
    cp(realized_inputs, joinpath(destination, "realized_inputs"); force = false)
    return destination
end

function regression_summary(
    name::AbstractString,
    specification,
    solver::AbstractString,
    result::Dict,
    coverage::Dict,
)
    metrics = coverage["metrics"]
    return Dict{String,Any}(
        "schema_version" => 1,
        "benchmark" => String(name),
        "label" => specification.label,
        "solver" => String(solver),
        "workflow" => "GTEP-PCM",
        "all_passed" => coverage["all_passed"],
        "gtep_termination_status" => metrics["gtep_termination_status"],
        "pcm_termination_status" => metrics["pcm_termination_status"],
        "transfer_reconciliation_valid" => result["transfer_reconciliation"]["valid"],
        "handoff_contract_valid" => result["handoff_contract"]["valid"],
        "source_gtep_unchanged" => metrics["source_gtep_unchanged"],
        "source_pcm_unchanged" => metrics["source_pcm_unchanged"],
        "retired_generation_mw" => get(metrics, "retired_generation_mw", 0.0),
        "new_generation_mw" => get(metrics, "new_generation_mw", 0.0),
        "new_storage_power_mw" => get(metrics, "new_storage_power_mw", 0.0),
        "new_storage_energy_mwh" => get(metrics, "new_storage_energy_mwh", 0.0),
        "line_forward_added_mw" => get(metrics, "line_forward_added_mw", 0.0),
        "pcm_new_generation_dispatch_mwh" =>
            get(metrics, "pcm_new_generation_dispatch_mwh", 0.0),
        "pcm_new_storage_discharge_mwh" =>
            get(metrics, "pcm_new_storage_discharge_mwh", 0.0),
        "pcm_upgraded_line_flow_above_source_mw" =>
            get(metrics, "pcm_upgraded_line_flow_above_source_mw", 0.0),
        "pcm_load_shedding_mwh" => get(metrics, "pcm_load_shedding_mwh", 0.0),
    )
end

function validate_regression!(result::Dict, coverage::Dict)
    metrics = coverage["metrics"]
    failures = String[]
    coverage["all_passed"] || push!(failures, "acceptance thresholds")
    metrics["gtep_termination_status"] == "OPTIMAL" ||
        push!(failures, "GTEP termination=$(metrics["gtep_termination_status"])")
    metrics["pcm_termination_status"] == "OPTIMAL" ||
        push!(failures, "PCM termination=$(metrics["pcm_termination_status"])")
    result["transfer_reconciliation"]["valid"] || push!(failures, "transfer reconciliation")
    result["handoff_contract"]["valid"] || push!(failures, "handoff contract")
    Bool(metrics["source_gtep_unchanged"]) || push!(failures, "GTEP source mutation")
    Bool(metrics["source_pcm_unchanged"]) || push!(failures, "PCM source mutation")
    isempty(failures) ||
        throw(ErrorException("Holistic regression failed: $(join(failures, ", "))"))
    return result
end

function run_benchmark(
    name::AbstractString,
    modelcases_path::AbstractString,
    solver::AbstractString,
    artifact_path::AbstractString,
)
    specification = HOLISTIC_BENCHMARKS[String(name)]
    gtep_source = require_directory(
        joinpath(modelcases_path, specification.gtep),
        "GTEP benchmark case",
    )
    pcm_source = require_directory(
        joinpath(modelcases_path, specification.pcm),
        "PCM benchmark case",
    )
    expectations_name = "HOPE_holistic_acceptance.yml"
    require_file(
        joinpath(pcm_source, "Settings", expectations_name),
        "holistic acceptance contract",
    )

    println("Running $(specification.label) with solver=$(solver)")
    return mktempdir() do temporary_root
        gtep_case = joinpath(temporary_root, specification.gtep)
        pcm_case = joinpath(temporary_root, specification.pcm)
        HOPE.sync_case_tree_without_outputs(gtep_source, gtep_case)
        HOPE.sync_case_tree_without_outputs(pcm_source, pcm_case)
        result = HOPE.run_hope_holistic(gtep_case, pcm_case; solver_override = solver)
        coverage = HOPE.write_holistic_coverage_report(
            result,
            joinpath(pcm_case, "Settings", expectations_name);
            require_all = false,
        )
        benchmark_artifacts = joinpath(artifact_path, String(name))
        copy_regression_artifacts(result, benchmark_artifacts)
        summary = regression_summary(name, specification, solver, result, coverage)
        open(joinpath(benchmark_artifacts, "regression_summary.yml"), "w") do io
            YAML.write(io, summary)
        end
        validate_regression!(result, coverage)
        println("PASS $(specification.label)")
        YAML.write(stdout, summary)
        return summary
    end
end

function main(args::Vector{String} = ARGS)
    options = parse_arguments(args)
    options === nothing && return 0
    require_directory(options["modelcases"], "HOPEModelCases checkout")
    run_stamp = Dates.format(now(UTC), dateformat"yyyymmddTHHMMSS")
    artifact_path = joinpath(options["artifacts"], "run_$(run_stamp)_$(getpid())")
    mkpath(artifact_path)
    summaries = Dict{String,Any}()
    for name in selected_benchmarks(options["suite"])
        summaries[name] =
            run_benchmark(name, options["modelcases"], options["solver"], artifact_path)
    end
    overall = Dict{String,Any}(
        "schema_version" => 1,
        "workflow" => "GTEP-PCM regression suite",
        "suite" => options["suite"],
        "solver" => options["solver"],
        "all_passed" => all(summary["all_passed"] for summary in values(summaries)),
        "benchmarks" => summaries,
    )
    open(joinpath(artifact_path, "regression_suite_summary.yml"), "w") do io
        YAML.write(io, overall)
    end
    println("Holistic regression artifacts: $(artifact_path)")
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
