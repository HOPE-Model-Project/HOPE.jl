using HOPE

function usage(io::IO = stdout)
    println(
        io,
        "Usage: julia --project=. tools/repo_utils/report_holistic_benchmark.jl " *
        "<run_workspace> [output_directory] [validation_slice.yml] [expected.yml]",
    )
end

function main(args::Vector{String} = ARGS)
    if isempty(args) || length(args) > 4
        usage(stderr)
        return 2
    end
    workspace = abspath(args[1])
    output = length(args) >= 2 ? abspath(args[2]) : joinpath(workspace, "benchmark")
    slice = length(args) >= 3 ? abspath(args[3]) : nothing
    expected = length(args) == 4 ? abspath(args[4]) : nothing
    result = HOPE.write_holistic_benchmark_report(
        workspace;
        output_path = output,
        validation_slice_path = slice,
        expected_path = expected,
        require_all = true,
    )
    println("HOPE_BENCHMARK_ALL_PASSED=", result["summary"]["all_passed"])
    println("HOPE_BENCHMARK_REPORT=", result["paths"]["report_markdown"])
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
