using Dates
using HOPE
using YAML

function usage(io::IO = stdout)
    println(
        io,
        "Usage: julia --project=. tools/repo_utils/run_holistic_agent_job.jl " *
        "<gtep_case> <pcm_case> <manifest_path> [solver]",
    )
end

function write_manifest_atomic(path::AbstractString, manifest::AbstractDict)
    mkpath(dirname(path))
    temporary = joinpath(dirname(path), ".$(basename(path)).$(getpid()).tmp")
    try
        open(temporary, "w") do io
            YAML.write(io, manifest)
        end
        mv(temporary, path; force = true)
    finally
        isfile(temporary) && rm(temporary; force = true)
    end
    return path
end

function update_manifest(path::AbstractString; changes...)
    manifest = YAML.load_file(path)
    manifest isa AbstractDict ||
        error("Holistic run manifest must be a YAML mapping: $(path)")
    for (key, value) in changes
        manifest[string(key)] = value
    end
    write_manifest_atomic(path, manifest)
    return manifest
end

function emit_result(
    result::Dict,
    gtep_case::AbstractString,
    pcm_case::AbstractString,
    coverage,
)
    println("HOPE_GTEP_CASE_PATH=$(gtep_case)")
    println("HOPE_PCM_CASE_PATH=$(pcm_case)")
    println("HOPE_PCM_OUTPUT_PATH=$(result["pcm_output_path"])")
    println("HOPE_HANDOFF_VALID=$(result["handoff_contract"]["valid"])")
    println("HOPE_TRANSFER_VALID=$(result["transfer_reconciliation"]["valid"])")
    if coverage !== nothing
        println("HOPE_COVERAGE_ALL_PASSED=$(coverage["all_passed"])")
    end
    flush(stdout)
    return nothing
end

function main(args::Vector{String} = ARGS)
    if length(args) < 3 || length(args) > 4
        usage(stderr)
        return 2
    end

    gtep_case = abspath(args[1])
    pcm_case = abspath(args[2])
    manifest_path = abspath(args[3])
    solver =
        length(args) == 4 && !isempty(strip(args[4])) ? lowercase(strip(args[4])) : nothing

    try
        result = HOPE.run_hope_holistic(gtep_case, pcm_case; solver_override = solver)
        acceptance_path = joinpath(pcm_case, "Settings", "HOPE_holistic_acceptance.yml")
        coverage = if isfile(acceptance_path)
            HOPE.write_holistic_coverage_report(result, acceptance_path; require_all = true)
        else
            nothing
        end
        result_record = Dict{String,Any}(
            "gtep_case_path" => gtep_case,
            "pcm_case_path" => pcm_case,
            "pcm_output_path" => string(result["pcm_output_path"]),
            "handoff_valid" => Bool(result["handoff_contract"]["valid"]),
            "transfer_valid" => Bool(result["transfer_reconciliation"]["valid"]),
            "coverage_evaluated" => coverage !== nothing,
        )
        if coverage !== nothing
            result_record["coverage_all_passed"] = Bool(coverage["all_passed"])
            result_record["coverage_paths"] =
                Dict(string(key) => string(value) for (key, value) in coverage["paths"])
        end
        update_manifest(
            manifest_path;
            status = "PUBLISHED",
            updated_at_utc = string(now(UTC)),
            result = result_record,
            exit_code = 0,
        )
        emit_result(result, gtep_case, pcm_case, coverage)
        return 0
    catch err
        error_record = Dict{String,Any}(
            "type" => string(typeof(err)),
            "message" => sprint(showerror, err),
        )
        try
            update_manifest(
                manifest_path;
                status = "FAILED",
                updated_at_utc = string(now(UTC)),
                error = error_record,
                exit_code = 1,
            )
        catch manifest_error
            println(
                stderr,
                "Failed to update holistic manifest: ",
                sprint(showerror, manifest_error),
            )
        end
        showerror(stderr, err, catch_backtrace())
        println(stderr)
        return 1
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
