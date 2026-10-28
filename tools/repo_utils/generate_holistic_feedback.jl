using HOPE
using YAML

function usage(io::IO = stdout)
    println(
        io,
        "Usage: julia --project=. tools/repo_utils/generate_holistic_feedback.jl " *
        "<assessment.yml> <feedback_policy.yml> <output_directory> <study_id> [iteration]",
    )
end

function main(args::Vector{String} = ARGS)
    length(args) in (4, 5) || begin
        usage(stderr)
        return 2
    end
    assessment_path, policy_path, output_directory, study_id = args[1:4]
    iteration = length(args) == 5 ? parse(Int, args[5]) : 1
    try
        assessment = YAML.load_file(abspath(assessment_path))
        policy = HOPE.load_feedback_policy(abspath(policy_path))
        package = HOPE.build_holistic_feedback(
            assessment,
            policy;
            study_id = study_id,
            iteration = iteration,
            parent_artifacts = Dict(
                "assessment" => Dict(
                    "path" => abspath(assessment_path),
                    "sha256" => bytes2hex(HOPE.sha256(read(abspath(assessment_path)))),
                ),
            ),
        )
        paths = HOPE.write_holistic_feedback_package(package, abspath(output_directory))
        println("HOPE_FEEDBACK_STATUS=", package["terminal_status"])
        println("HOPE_FINDING_COUNT=", length(package["findings"]))
        println("HOPE_REVISION_REQUEST_COUNT=", length(package["revision_requests"]))
        println("HOPE_FEEDBACK_MANIFEST=", paths["manifest"])
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
