using HOPE
using SHA
using YAML

function _adaptive_cli_usage(io::IO = stdout)
    println(
        io,
        "Usage: julia --project=. tools/repo_utils/adaptive_study_cli.jl " *
        "<initialize|request-revision|record-decision|start-child|select|stop> " *
        "<workspace> [payload.yml]",
    )
end

function _adaptive_state_path(workspace::AbstractString)
    return joinpath(abspath(workspace), "adaptive_study_state.yml")
end

function _adaptive_manifest_path(workspace::AbstractString)
    return joinpath(abspath(workspace), "manifest.yml")
end

function _load_adaptive_state(workspace::AbstractString)
    path = _adaptive_state_path(workspace)
    isfile(path) || throw(ArgumentError("Adaptive study state not found: $(path)"))
    return YAML.load_file(path)
end

function _load_adaptive_payload(path::AbstractString)
    isfile(path) || throw(ArgumentError("Adaptive command payload not found: $(path)"))
    payload = YAML.load_file(path)
    payload isa AbstractDict || throw(ArgumentError("Adaptive command payload must be a mapping."))
    return Dict{String,Any}(string(key) => value for (key, value) in payload)
end

function _write_adaptive_state_atomic(state::AbstractDict, workspace::AbstractString)
    directory = abspath(workspace)
    mkpath(directory)
    state_path = _adaptive_state_path(directory)
    manifest_path = _adaptive_manifest_path(directory)
    temporary_state = tempname(directory)
    temporary_manifest = tempname(directory)
    try
        YAML.write_file(temporary_state, deepcopy(state))
        state_sha256 = bytes2hex(sha256(read(temporary_state)))
        YAML.write_file(
            temporary_manifest,
            Dict(
                "artifact_type" => "HOPE.adaptive_study_manifest",
                "schema_version" => 1,
                "study_id" => state["study_id"],
                "stage" => state["stage"],
                "terminal_status" => state["terminal_status"],
                "iteration" => state["iteration"],
                "state_sha256" => state_sha256,
            ),
        )
        mv(temporary_state, state_path; force = true)
        mv(temporary_manifest, manifest_path; force = true)
    finally
        isfile(temporary_state) && rm(temporary_state; force = true)
        isfile(temporary_manifest) && rm(temporary_manifest; force = true)
    end
    return Dict("state" => state_path, "manifest" => manifest_path)
end

function _require_payload(args::Vector{String})
    length(args) == 3 || throw(ArgumentError("This command requires a payload YAML file."))
    return _load_adaptive_payload(args[3])
end

function adaptive_study_cli(args::Vector{String} = ARGS)
    length(args) in (2, 3) || begin
        _adaptive_cli_usage(stderr)
        return 2
    end
    command = lowercase(strip(args[1]))
    workspace = abspath(args[2])
    try
        state = if command == "initialize"
            length(args) == 3 || throw(ArgumentError("initialize requires the study spec path."))
            ispath(workspace) && throw(ArgumentError("Adaptive workspace already exists: $(workspace)"))
            HOPE.initialize_adaptive_study(HOPE.load_holistic_study_spec(args[3]))
        elseif command == "request-revision"
            payload = _require_payload(args)
            revision_type = string(get(payload, "revision_type", ""))
            request = get(payload, "request", Dict{String,Any}())
            request isa AbstractDict || throw(ArgumentError("request must be a mapping."))
            HOPE.request_adaptive_revision(
                _load_adaptive_state(workspace),
                revision_type;
                request = request,
            )
        elseif command == "record-decision"
            payload = _require_payload(args)
            HOPE.record_adaptive_revision_decision(
                _load_adaptive_state(workspace),
                string(get(payload, "decision", ""));
                approver = string(get(payload, "approver", "")),
                rationale = string(get(payload, "rationale", "")),
            )
        elseif command == "start-child"
            length(args) == 2 || throw(ArgumentError("start-child does not accept a payload."))
            HOPE.start_adaptive_child_iteration(_load_adaptive_state(workspace))
        elseif command == "select"
            payload = _require_payload(args)
            evidence = get(payload, "evidence", Dict{String,Any}())
            evidence isa AbstractDict || throw(ArgumentError("evidence must be a mapping."))
            HOPE.select_adaptive_realization(
                _load_adaptive_state(workspace),
                string(get(payload, "variant", ""));
                rationale = string(get(payload, "rationale", "")),
                evidence = evidence,
            )
        elseif command == "stop"
            payload = _require_payload(args)
            HOPE.stop_adaptive_study(
                _load_adaptive_state(workspace),
                string(get(payload, "terminal_status", ""));
                reason = string(get(payload, "reason", "")),
            )
        else
            throw(ArgumentError("Unknown adaptive command: $(command)"))
        end
        paths = _write_adaptive_state_atomic(state, workspace)
        println("HOPE_ADAPTIVE_STUDY_ID=", state["study_id"])
        println("HOPE_ADAPTIVE_STAGE=", state["stage"])
        println("HOPE_ADAPTIVE_TERMINAL_STATUS=", state["terminal_status"])
        println("HOPE_ADAPTIVE_ITERATION=", state["iteration"])
        println("HOPE_ADAPTIVE_STATE=", paths["state"])
        return 0
    catch error
        showerror(stderr, error, catch_backtrace())
        println(stderr)
        return 1
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(adaptive_study_cli())
end
