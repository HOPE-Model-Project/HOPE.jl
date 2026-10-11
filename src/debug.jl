function debug(outpath::AbstractString, config_set::Dict, model::Model)
    model_mode = config_set["model_mode"]


    ##Debugging
    if config_set["debug"] == 0
        println(
            "Debugging method is not set, please set debug = 1 or 2 in HOPE_model_settings.yml",
        )
    elseif config_set["debug"] == 1
        println("Start to debug infeasibility for model in $model_mode mode")
        println("Debugging with 'Conflicts' method")
        optimize!(model)
        compute_conflict!(model)
        if get_attribute(model, MOI.ConflictStatus()) == MOI.CONFLICT_FOUND
            iis_model, _ = copy_conflict(model)
            open(joinpath(outpath, "debug_report.txt"), "w") do f
                println(f, iis_model)
            end
        end

    elseif config_set["debug"] == 2
        println("Start to debug infeasibility for model in $model_mode mode")
        println("Debugging with 'Penalty' method")
        map = relax_with_penalty!(model)
        optimize!(model)
        open(joinpath(outpath, "debug_report.txt"), "w") do f
            for (con, penalty) in map
                violation = value(penalty)
                if violation > 0
                    println(f, "Constraint `$(name(con))` is violated by $violation")
                    flush(f)
                end
            end
        end

    elseif config_set["debug"] != 0
        println(
            "Wrong debug method, please set debug =0, 1 or 2 in HOPE_model_settings.yml",
        )
    end
    return model
end

function run_debug(case::AbstractString)
    path = case
    outpath = joinpath(path, "debug_report")
    mkdir_overwrite(outpath)
    config_set = YAML.load_file(joinpath(case, "Settings", "HOPE_model_settings.yml"))
    model_mode = uppercase(string(get(config_set, "model_mode", "")))
    config_set["model_mode"] = model_mode
    validate_model_mode(model_mode)
    model_mode == "DART" && throw(
        ArgumentError(
            "run_debug does not support rolling DART cases. Set debug: 0 and use validate_hope before run_hope.",
        ),
    )

    #Set solver configuration
    optimizer = initiate_solver(path, config_set["solver"])

    #read in data
    input_data = load_data(config_set, path)

    #create model
    if model_mode == "GTEP"
        my_model = create_GTEP_model(config_set, input_data, optimizer)
    else
        my_model = create_PCM_model(config_set, input_data, optimizer)
    end
    #debug model
    println("Debugging...")
    my_debug_model = debug(outpath, config_set, my_model)
    #output
    #my_output = write_output(outpath, config_set, input_data,my_debug_model)
    return my_debug_model
end
