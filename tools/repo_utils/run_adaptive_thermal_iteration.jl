using HOPE
using SHA
using YAML

include(joinpath(@__DIR__, "adaptive_study_cli.jl"))

module AdaptivePlanningRunner
include(joinpath(@__DIR__, "run_md_compact_rps_planning.jl"))
end

module AdaptivePCMRunner
include(joinpath(@__DIR__, "run_md_compact_rps_pcm_ensemble.jl"))
end

const ADAPTIVE_MODEL_CASES = joinpath(dirname(dirname(@__DIR__)), "ModelCases")
const ADAPTIVE_BASE_CASE =
    joinpath(ADAPTIVE_MODEL_CASES, "MD_COMPACT_ENERGY_THERMAL_REALIZATION_EXAMPLE_V1")
const ADAPTIVE_PEPCO_CASE =
    joinpath(ADAPTIVE_MODEL_CASES, "MD_COMPACT_ENERGY_THERMAL_PEPCO_FEEDBACK_V1")

function _adaptive_worker_usage(io::IO = stdout)
    println(
        io,
        "Usage: julia --project=. tools/repo_utils/run_adaptive_thermal_iteration.jl " *
        "<workspace> [planning_solver] [pcm_solver]",
    )
end

function _adaptive_iteration_example(state::AbstractDict)
    iteration = Int(state["iteration"])
    iteration == 1 && return ADAPTIVE_BASE_CASE
    iteration == 2 || throw(
        ArgumentError("The validated thermal vertical slice supports iterations 1 and 2 only."),
    )
    attempt = state["attempts"][end]
    revision = get(attempt, "parent_revision", nothing)
    revision isa AbstractDict || throw(
        ArgumentError("Iteration 2 requires an approved parent revision."),
    )
    string(get(revision, "status", "")) == "approved" || throw(
        ArgumentError("Iteration 2 parent revision is not approved."),
    )
    string(get(revision, "revision_type", "")) == "candidate_zone_eligibility" || throw(
        ArgumentError("The validated iteration-2 action is candidate_zone_eligibility."),
    )
    request = get(revision, "request", Dict{String,Any}())
    changes = get(request, "changes", Dict{String,Any}())
    zones = String.(get(changes, "allowed_generation_candidate_zones", String[]))
    zones == ["PEPCO"] || throw(
        ArgumentError("The validated iteration-2 action must restrict candidate zones to PEPCO."),
    )
    return ADAPTIVE_PEPCO_CASE
end

function _adaptive_iteration_manifest(
    state::AbstractDict,
    iteration_directory::AbstractString,
    planning_case::AbstractString,
    ensemble_directory::AbstractString;
    status::AbstractString,
    error_message = nothing,
)
    manifest = Dict{String,Any}(
        "artifact_type" => "HOPE.adaptive_iteration_manifest",
        "schema_version" => 1,
        "study_id" => state["study_id"],
        "iteration" => state["iteration"],
        "status" => String(status),
        "stage" => state["stage"],
        "terminal_status" => state["terminal_status"],
        "planning_case" => abspath(planning_case),
        "pcm_ensemble" => abspath(ensemble_directory),
    )
    error_message === nothing || (manifest["error"] = String(error_message))
    path = joinpath(iteration_directory, "manifest.yml")
    YAML.write_file(path, manifest)
    return path
end

function run_adaptive_thermal_iteration(args::Vector{String} = ARGS)
    length(args) in (1, 2, 3) || begin
        _adaptive_worker_usage(stderr)
        return 2
    end
    workspace = abspath(args[1])
    planning_solver = length(args) >= 2 ? args[2] : "highs"
    pcm_solver = length(args) == 3 ? args[3] : "gurobi"
    state = _load_adaptive_state(workspace)
    state["terminal_status"] == "ACTIVE" || begin
        println(stderr, "Adaptive study is terminal: $(state["terminal_status"])")
        return 2
    end
    state["stage"] == "SPECIFIED" || begin
        println(stderr, "Adaptive iteration requires SPECIFIED, not $(state["stage"]).")
        return 2
    end
    iteration_directory = joinpath(workspace, "iterations", lpad(string(state["iteration"]), 2, '0'))
    planning_case = joinpath(iteration_directory, "planning_case")
    ensemble_directory = joinpath(iteration_directory, "pcm_ensemble")
    ispath(iteration_directory) && begin
        println(stderr, "Adaptive iteration output already exists: $(iteration_directory)")
        return 2
    end
    mkpath(iteration_directory)
    try
        example = _adaptive_iteration_example(state)
        planning_code = AdaptivePlanningRunner.run_compact_planning(
            example,
            [planning_case, planning_solver],
        )
        planning_code == 0 || error("Compact planning failed with exit code $(planning_code).")
        pcm_code = AdaptivePCMRunner.run_compact_pcm_ensemble(
            example,
            [planning_case, ensemble_directory, pcm_solver],
        )
        pcm_code == 0 || error("PCM ensemble failed with exit code $(pcm_code).")
        updated = HOPE.advance_adaptive_study_from_compact_artifacts(
            state,
            planning_case,
            ensemble_directory,
        )
        _write_adaptive_state_atomic(updated, workspace)
        manifest = _adaptive_iteration_manifest(
            updated,
            iteration_directory,
            planning_case,
            ensemble_directory;
            status = "PUBLISHED",
        )
        println("HOPE_ADAPTIVE_ITERATION_STATUS=PUBLISHED")
        println("HOPE_ADAPTIVE_ITERATION=", updated["iteration"])
        println("HOPE_ADAPTIVE_STAGE=", updated["stage"])
        println("HOPE_ADAPTIVE_TERMINAL_STATUS=", updated["terminal_status"])
        println("HOPE_ADAPTIVE_ITERATION_MANIFEST=", manifest)
        return 0
    catch error
        message = sprint(showerror, error, catch_backtrace())
        _adaptive_iteration_manifest(
            state,
            iteration_directory,
            planning_case,
            ensemble_directory;
            status = "FAILED",
            error_message = message,
        )
        println(stderr, message)
        return 1
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(run_adaptive_thermal_iteration())
end
