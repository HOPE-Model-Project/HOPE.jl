"""
    run_hope(case::AbstractString; solver_override=nothing)

Run HOPE for a single case directory. GTEP, PCM, and DART cases all use
`Settings/HOPE_model_settings.yml` and write results under `<case>/output/`.
`solver_override` selects a solver for this run without changing the case file.
"""
function _resolve_case_path(case::AbstractString)
    case_path = case
    if startswith(case_path, "HOPE/") || startswith(case_path, "HOPE\\")
        case_path = case_path[6:end]
    end
    case_path = rstrip(case_path, ['/', '\\'])
    if startswith(case_path, "ModelCases/") || startswith(case_path, "ModelCases\\")
        case_path = case_path[12:end]
    end

    path = nothing
    tried_paths = String[]
    test_path = case_path
    push!(tried_paths, test_path)
    isdir(test_path) && (path = test_path)
    if path === nothing
        test_path = joinpath("ModelCases", case_path)
        push!(tried_paths, test_path)
        isdir(test_path) && (path = test_path)
    end
    if path === nothing
        test_path = joinpath("ModelCases", basename(case_path))
        push!(tried_paths, test_path)
        isdir(test_path) && (path = test_path)
    end
    if path === nothing && haskey(ENV, "HOPE_MODELCASES_PATH")
        root = ENV["HOPE_MODELCASES_PATH"]
        test_path = joinpath(root, case_path)
        push!(tried_paths, test_path)
        isdir(test_path) && (path = test_path)
        if path === nothing
            test_path = joinpath(root, basename(case_path))
            push!(tried_paths, test_path)
            isdir(test_path) && (path = test_path)
        end
    end
    if path === nothing
        available = try
            readdir("ModelCases")
        catch
            String[]
        end
        message = "Case directory does not exist: $case\nTried paths:\n"
        message *= join(["  - $p" for p in tried_paths], "\n")
        if !isempty(available)
            message *= "\n\nAvailable cases in ModelCases/:\n"
            message *= join(["  - $name" for name in available], "\n")
        end
        throw(ArgumentError(message))
    end
    return path
end

function _load_hope_settings(path)
    settings_file = joinpath(path, "Settings", "HOPE_model_settings.yml")
    isfile(settings_file) || throw(ArgumentError("Settings file not found: $settings_file"))
    config = YAML.load_file(settings_file)
    config isa AbstractDict || throw(ArgumentError("HOPE settings must be a YAML mapping."))
    config["model_mode"] = uppercase(string(get(config, "model_mode", "")))
    return config
end

function _prepare_standard_input(path, config; context)
    if resource_aggregation_enabled(config)
        config["aggregation_settings"] = load_aggregation_settings(path, config)
    end
    endogenous_rep_day, _, _ = resolve_rep_day_mode(config; context = context)
    if endogenous_rep_day == 1
        config["rep_day_settings"] = load_rep_day_settings(path, config)
    end
    return load_data(config, path)
end

function _effective_solver_name(config::AbstractDict, solver_override)
    selected = solver_override === nothing ? get(config, "solver", "") : solver_override
    name = lowercase(strip(string(selected)))
    isempty(name) && throw(ArgumentError("HOPE solver name must not be blank."))
    return name
end

function _run_hope_impl(
    case::AbstractString,
    path::AbstractString,
    solver_override = nothing,
)
    outpath = joinpath(path, "output")
    try
        config = _load_hope_settings(path)
        config["solver"] = _effective_solver_name(config, solver_override)
        mode = config["model_mode"]
        validate_model_mode(mode)
        optimizer = initiate_solver(path, lowercase(String(config["solver"])))
        if mode == "DART"
            validate_dart_settings(config)
            return run_dart_case(path, config, optimizer)
        end

        input_data = _prepare_standard_input(path, config; context = "run_hope")
        saved_input = deepcopy(input_data)
        model =
            mode == "GTEP" ? create_GTEP_model(config, input_data, optimizer) :
            create_PCM_model(config, input_data, optimizer)
        solved_model = solve_model(config, input_data, model)
        operational_state_trace =
            mode == "PCM" ?
            maybe_capture_pcm_operational_trace(config, input_data, solved_model) : nothing
        output_write = write_output_with_metadata(outpath, config, input_data, solved_model)
        snapshot = nothing
        save_mode =
            parse_postprocess_snapshot_mode(get(config, "save_postprocess_snapshot", 0))
        if save_mode > 0
            if mode == "GTEP"
                snapshot = save_postprocess_snapshot(
                    output_write.actual_outpath,
                    path,
                    config,
                    saved_input,
                    solved_model;
                    mode = save_mode,
                )
            else
                @info "Skipping postprocess snapshot because it is supported only for GTEP."
            end
        end
        return Dict(
            "case_path" => path,
            "output_path" => output_write.actual_outpath,
            "config" => config,
            "solved_model" => solved_model,
            "output" => output_write.results,
            "input" => saved_input,
            "snapshot" => snapshot,
            "operational_state_trace" => operational_state_trace,
        )
    catch err
        @error "Error running HOPE case: $case" exception = (err, catch_backtrace())
        rethrow()
    end
end

function run_hope(case::AbstractString; solver_override = nothing)
    path = _resolve_case_path(case)
    config = _load_hope_settings(path)
    solver_name = _effective_solver_name(config, solver_override)
    if haskey(OPTIONAL_SOLVER_PACKAGES, solver_name)
        _ensure_optional_solver_loaded(solver_name)
        return Base.invokelatest(_run_hope_impl, case, path, solver_name)
    end
    return _run_hope_impl(case, path, solver_name)
end

"""Validate a GTEP, PCM, or DART case without solving it or writing outputs."""
function validate_hope(case::AbstractString)
    path = _resolve_case_path(case)
    config = _load_hope_settings(path)
    mode = config["model_mode"]
    validate_model_mode(mode)
    if mode == "DART"
        return validate_dart_case(path, config)
    end
    input = _prepare_standard_input(path, config; context = "validate_hope")
    return Dict("case_path" => path, "config" => config, "input" => input)
end

function write_hope(case::AbstractString, solved_case::Model)
    isdir(case) || throw(ArgumentError("Case directory does not exist: $case"))
    path = case
    outpath = joinpath(path, "output")
    try
        config = _load_hope_settings(path)
        config["model_mode"] == "DART" && throw(
            ArgumentError(
                "write_hope(::Model) is not valid for rolling DART results; use run_hope.",
            ),
        )
        input = _prepare_standard_input(path, config; context = "write_hope")
        write_output(outpath, config, input, solved_case)
    catch err
        @error "Error writing HOPE output for case: $case" exception =
            (err, catch_backtrace())
        rethrow()
    end
end
