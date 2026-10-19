is_holistic_missing(x) =
    ismissing(x) ||
    x === nothing ||
    (x isa AbstractFloat && isnan(x)) ||
    (x isa AbstractString && begin
        stripped = strip(x)
        isempty(stripped) || lowercase(stripped) == "nan"
    end)

function holistic_debug_stage_log(config_set::Dict, stage::AbstractString)
    debug_stage_file = get(config_set, "debug_stage_file", nothing)
    if debug_stage_file === nothing
        return nothing
    end
    open(String(debug_stage_file), "a") do io
        println(io, "time=", time(), ", stage=", stage)
    end
    return nothing
end

function holistic_debug_stage_log_pair(
    gtep_config::Dict,
    pcm_config::Dict,
    stage::AbstractString,
)
    logged_paths = Set{String}()
    for config in (gtep_config, pcm_config)
        debug_stage_file = get(config, "debug_stage_file", nothing)
        if debug_stage_file === nothing
            continue
        end
        debug_stage_path = String(debug_stage_file)
        if debug_stage_path in logged_paths
            continue
        end
        push!(logged_paths, debug_stage_path)
        holistic_debug_stage_log(config, stage)
    end
    return nothing
end

function parse_holistic_float_or_missing(x)
    is_holistic_missing(x) && return missing
    value = if x isa Number
        Float64(x)
    elseif x isa AbstractString
        parse(Float64, strip(x))
    else
        throw(ArgumentError("Cannot convert value $x to Float64"))
    end
    return isnan(value) ? missing : value
end

fill_missing_with_group_mean(
    df::DataFrame,
    group_cols::Vector{Symbol},
    cols_to_fill::Vector{Symbol};
    pcm_config::Union{Nothing,Dict} = nothing,
) = begin
    work = copy(df)
    available_cols = Set(Symbol.(names(work)))
    row_count = nrow(work)
    for col in cols_to_fill
        col in available_cols || continue
        if pcm_config !== nothing
            holistic_debug_stage_log(
                pcm_config,
                "fill_missing_with_group_mean_start_group=" *
                join(string.(group_cols), ",") *
                ";col=" *
                String(col),
            )
        end
        work[!, col] = allowmissing(work[!, col])
        work[!, col] =
            map(x -> (x isa AbstractFloat && isnan(x)) ? missing : x, work[!, col])

        sums = Dict{Tuple,Float64}()
        counts = Dict{Tuple,Int}()
        for row_idx = 1:row_count
            key = tuple((work[row_idx, group_col] for group_col in group_cols)...)
            value = work[row_idx, col]
            if !ismissing(value)
                sums[key] = get(sums, key, 0.0) + Float64(value)
                counts[key] = get(counts, key, 0) + 1
            end
        end
        if pcm_config !== nothing
            holistic_debug_stage_log(
                pcm_config,
                "fill_missing_with_group_mean_stats_done_group=" *
                join(string.(group_cols), ",") *
                ";col=" *
                String(col) *
                ";groups=" *
                string(length(counts)),
            )
        end
        for row_idx = 1:row_count
            value = work[row_idx, col]
            if is_holistic_missing(value)
                key = tuple((work[row_idx, group_col] for group_col in group_cols)...)
                if haskey(counts, key) && counts[key] > 0
                    work[row_idx, col] = sums[key] / counts[key]
                end
            end
        end
        if pcm_config !== nothing
            holistic_debug_stage_log(
                pcm_config,
                "fill_missing_with_group_mean_done_group=" *
                join(string.(group_cols), ",") *
                ";col=" *
                String(col),
            )
        end
    end
    work
end

function convert_columns_to_float64!(df::DataFrame, cols::Vector{Symbol})
    available_cols = Set(Symbol.(names(df)))
    for col in cols
        col in available_cols || continue
        df[!, col] = allowmissing(df[!, col])
        df[!, col] = map(
            x -> x isa Missing ? missing : parse_holistic_float_or_missing(x),
            df[!, col],
        )
    end
    return df
end

function append_rows_preserve_columns(base_df::DataFrame, rows_to_add::DataFrame)
    if nrow(rows_to_add) == 0
        return copy(base_df)
    end
    work = copy(base_df)
    add_df = copy(rows_to_add)
    for col in names(work)
        if !(col in names(add_df))
            add_df[!, col] = missings(nrow(add_df))
        end
    end
    for col in names(add_df)
        if !(col in names(work))
            work[!, col] = missings(nrow(work))
        end
    end
    return vcat(work, select(add_df, names(work)); cols = :union)
end

function normalize_holistic_case_path(case::AbstractString)
    case_path = String(case)
    if startswith(case_path, "HOPE/") || startswith(case_path, "HOPE\\")
        case_path = case_path[6:end]
    end
    case_path = rstrip(case_path, ['/', '\\'])
    if startswith(case_path, "ModelCases/") || startswith(case_path, "ModelCases\\")
        case_path = case_path[12:end]
    end

    for candidate in (
        case_path,
        joinpath("ModelCases", case_path),
        joinpath("ModelCases", basename(case_path)),
    )
        if isdir(candidate)
            return candidate
        end
    end
    throw(ArgumentError("Holistic case directory not found: $(case)"))
end

function load_case_config_for_holistic(
    case::AbstractString;
    context::AbstractString = "run_hope_holistic",
)
    case_path = normalize_holistic_case_path(case)
    settings_file = joinpath(case_path, "Settings", "HOPE_model_settings.yml")
    isfile(settings_file) ||
        throw(ArgumentError("Settings file not found: $(settings_file)"))
    config = open(settings_file) do io
        YAML.load(io)
    end
    if resource_aggregation_enabled(config)
        config["aggregation_settings"] = load_aggregation_settings(case_path, config)
    end
    endogenous_rep_day, _, _ = resolve_rep_day_mode(config; context = context)
    if endogenous_rep_day == 1
        config["rep_day_settings"] = load_rep_day_settings(case_path, config)
    end
    return case_path, config
end

normalize_holistic_type(type_name) = replace(String(type_name), "_CCS" => "")

function holistic_fill_columns(
    df::DataFrame,
    by_cols::Vector{Vector{Symbol}},
    fill_cols::Vector{Symbol};
    pcm_config::Union{Nothing,Dict} = nothing,
)
    work = copy(df)
    available_cols = Set(Symbol.(names(work)))
    valid_fill_cols = [col for col in fill_cols if col in available_cols]
    if pcm_config !== nothing
        holistic_debug_stage_log(
            pcm_config,
            "holistic_fill_columns_convert_start_cols=" *
            join(string.(valid_fill_cols), ","),
        )
    end
    convert_columns_to_float64!(work, valid_fill_cols)
    if pcm_config !== nothing
        holistic_debug_stage_log(pcm_config, "holistic_fill_columns_convert_done")
    end

    group_specs = copy(by_cols)
    if :Type in available_cols
        if pcm_config !== nothing
            holistic_debug_stage_log(
                pcm_config,
                "holistic_fill_columns_normalized_type_start",
            )
        end
        work[!, :_NormalizedType] = normalize_holistic_type.(work[!, "Type"])
        push!(group_specs, [:Zone, :_NormalizedType])
        push!(group_specs, [:_NormalizedType])
        available_cols = Set(Symbol.(names(work)))
        if pcm_config !== nothing
            holistic_debug_stage_log(
                pcm_config,
                "holistic_fill_columns_normalized_type_done",
            )
        end
    end

    for group_cols in group_specs
        valid_group_cols = [col for col in group_cols if col in available_cols]
        isempty(valid_group_cols) && continue
        if pcm_config !== nothing
            holistic_debug_stage_log(
                pcm_config,
                "holistic_fill_columns_group_start=" * join(string.(valid_group_cols), ","),
            )
        end
        work = fill_missing_with_group_mean(
            work,
            valid_group_cols,
            valid_fill_cols;
            pcm_config = pcm_config,
        )
        if pcm_config !== nothing
            holistic_debug_stage_log(
                pcm_config,
                "holistic_fill_columns_group_done=" * join(string.(valid_group_cols), ","),
            )
        end
    end
    if :_NormalizedType in Symbol.(names(work))
        if pcm_config !== nothing
            holistic_debug_stage_log(
                pcm_config,
                "holistic_fill_columns_normalized_type_drop",
            )
        end
        select!(work, Not(:_NormalizedType))
    end
    return work
end

function holistic_fill_defaults!(df::DataFrame, default_map::Dict{Symbol,Float64})
    available_cols = Set(Symbol.(names(df)))
    for (col, default) in default_map
        col in available_cols || continue
        df[!, col] = allowmissing(df[!, col])
        df[!, col] = map(x -> begin
            parsed = parse_holistic_float_or_missing(x)
            ismissing(parsed) ? default : parsed
        end, df[!, col])
    end
    return df
end

function finalize_pcm_gendata_for_holistic(gendata::DataFrame, pcm_config::Dict)
    fill_cols = [
        Symbol("Pmax (MW)"),
        Symbol("Pmin (MW)"),
        Symbol("Cost (\$/MWh)"),
        :EF,
        :CC,
        :FOR,
        :RM_SPIN,
        :RU,
        :RD,
        :Flag_thermal,
        :Flag_VRE,
        :Flag_mustrun,
    ]
    holistic_debug_stage_log(
        pcm_config,
        "finalize_pcm_gendata_for_holistic_enter_rows=" * string(nrow(gendata)),
    )
    available_cols = Set(Symbol.(names(gendata)))
    for optional_col in [:RM_REG_UP, :RM_REG_DN, :RM_NSPIN, :AF]
        (optional_col in available_cols) && push!(fill_cols, optional_col)
    end
    if get(pcm_config, "unit_commitment", 0) != 0
        append!(
            fill_cols,
            [:Flag_UC, :Min_down_time, :Min_up_time, Symbol("Start_up_cost (\$/MW)")],
        )
    end

    holistic_debug_stage_log(
        pcm_config,
        "finalize_pcm_gendata_for_holistic_fill_columns_start",
    )
    work = holistic_fill_columns(
        gendata,
        [[:Zone, :Type], [:Type]],
        unique(fill_cols);
        pcm_config = pcm_config,
    )
    holistic_debug_stage_log(
        pcm_config,
        "finalize_pcm_gendata_for_holistic_fill_columns_done",
    )
    default_map = Dict{Symbol,Float64}(
        Symbol("Pmax (MW)") => 0.0,
        Symbol("Pmin (MW)") => 0.0,
        Symbol("Cost (\$/MWh)") => 0.0,
        :EF => 0.0,
        :CC => 0.0,
        :AF => 1.0,
        :FOR => 0.0,
        :RM_SPIN => 0.0,
        :RM_REG_UP => 0.0,
        :RM_REG_DN => 0.0,
        :RM_NSPIN => 0.0,
        :RU => 1.0,
        :RD => 1.0,
        :Flag_thermal => 0.0,
        :Flag_VRE => 0.0,
        :Flag_mustrun => 0.0,
        :Flag_UC => 0.0,
        :Min_down_time => 0.0,
        :Min_up_time => 0.0,
        Symbol("Start_up_cost (\$/MW)") => 0.0,
    )
    holistic_debug_stage_log(
        pcm_config,
        "finalize_pcm_gendata_for_holistic_fill_defaults_start",
    )
    result = holistic_fill_defaults!(work, default_map)
    holistic_debug_stage_log(
        pcm_config,
        "finalize_pcm_gendata_for_holistic_fill_defaults_done",
    )
    holistic_debug_stage_log(
        pcm_config,
        "finalize_pcm_gendata_for_holistic_exit_rows=" * string(nrow(result)),
    )
    return result
end

function finalize_pcm_storagedata_for_holistic(storagedata::DataFrame)
    fill_cols = [
        Symbol("Capacity (MWh)"),
        Symbol("Max Power (MW)"),
        Symbol("Charging efficiency"),
        Symbol("Discharging efficiency"),
        Symbol("Cost (\$/MWh)"),
        :EF,
        :CC,
        Symbol("Charging Rate"),
        Symbol("Discharging Rate"),
    ]
    work = holistic_fill_columns(storagedata, [[:Zone, :Type], [:Type]], fill_cols)
    default_map = Dict{Symbol,Float64}(
        Symbol("Capacity (MWh)") => 0.0,
        Symbol("Max Power (MW)") => 0.0,
        Symbol("Charging efficiency") => 1.0,
        Symbol("Discharging efficiency") => 1.0,
        Symbol("Cost (\$/MWh)") => 0.0,
        :EF => 0.0,
        :CC => 0.0,
        Symbol("Charging Rate") => 1.0,
        Symbol("Discharging Rate") => 1.0,
    )
    return holistic_fill_defaults!(work, default_map)
end

function finalize_pcm_inputs_for_holistic!(updated_input::Dict, pcm_config::Dict)
    holistic_debug_stage_log(pcm_config, "finalize_pcm_inputs_start")

    holistic_debug_stage_log(pcm_config, "finalize_pcm_gendata_start")
    updated_input["Gendata"] =
        finalize_pcm_gendata_for_holistic(updated_input["Gendata"], pcm_config)
    holistic_debug_stage_log(pcm_config, "finalize_pcm_gendata_done")

    holistic_debug_stage_log(pcm_config, "finalize_pcm_storagedata_start")
    updated_input["Storagedata"] =
        finalize_pcm_storagedata_for_holistic(updated_input["Storagedata"])
    holistic_debug_stage_log(pcm_config, "finalize_pcm_storagedata_done")

    holistic_debug_stage_log(pcm_config, "finalize_pcm_inputs_done")
    return updated_input
end

function pcm_gendata_for_holistic_persistence(updated_input::Dict, pcm_config::Dict)
    if resource_aggregation_enabled(pcm_config) && haskey(updated_input, "GendataRaw")
        return updated_input["GendataRaw"]
    end
    return updated_input["Gendata"]
end

function persist_pcm_inputs_for_holistic(
    case_path::AbstractString,
    pcm_config::Dict,
    updated_input::Dict,
)
    data_dir = joinpath(case_path, String(pcm_config["DataCase"]))
    mkpath(data_dir)

    written_paths = Dict{String,String}()

    gendata_path = joinpath(data_dir, "gendata.csv")
    CSV.write(
        gendata_path,
        pcm_gendata_for_holistic_persistence(updated_input, pcm_config),
        header = true,
    )
    written_paths["gendata"] = gendata_path

    if haskey(updated_input, "Storagedata")
        storagedata_path = joinpath(data_dir, "storagedata.csv")
        CSV.write(storagedata_path, updated_input["Storagedata"], header = true)
        written_paths["storagedata"] = storagedata_path
    end

    if haskey(updated_input, "Linedata")
        linedata_path = joinpath(data_dir, "linedata.csv")
        CSV.write(linedata_path, updated_input["Linedata"], header = true)
        written_paths["linedata"] = linedata_path
    end

    return written_paths
end

function extract_new_generation_rows(capacity_df::DataFrame)
    build_df = filter(
        row ->
            to_float_output(row["New_Build"], 0.0) > 0 &&
                to_float_output(row[Symbol("Capacity_FIN (MW)")], 0.0) > 0,
        capacity_df,
    )
    if nrow(build_df) == 0
        return DataFrame(
            :Zone => String[],
            :Type => String[],
            Symbol("Pmax (MW)") => Float64[],
        )
    end
    rows = DataFrame(
        Zone = String[string(row[:Zone]) for row in eachrow(build_df)],
        Type = String[string(row[:Technology]) for row in eachrow(build_df)],
    )
    rows[!, Symbol("Pmax (MW)")] = Float64[
        to_float_output(row[Symbol("Capacity_FIN (MW)")], 0.0) for row in eachrow(build_df)
    ]
    return combine(
        groupby(rows, [:Zone, :Type]),
        Symbol("Pmax (MW)") => sum => Symbol("Pmax (MW)"),
    )
end

function extract_new_storage_rows(es_capacity_df::DataFrame)
    build_df = filter(
        row ->
            to_float_output(row["New_Build"], 0.0) > 0 &&
                to_float_output(row[Symbol("Capacity (MW)")], 0.0) > 0,
        es_capacity_df,
    )
    if nrow(build_df) == 0
        return DataFrame(
            :Zone => String[],
            :Type => String[],
            Symbol("Capacity (MWh)") => Float64[],
            Symbol("Max Power (MW)") => Float64[],
        )
    end
    rows = DataFrame(
        Zone = String[string(row[:Zone]) for row in eachrow(build_df)],
        Type = String[string(row[:Technology]) for row in eachrow(build_df)],
    )
    rows[!, Symbol("Capacity (MWh)")] = Float64[
        to_float_output(row[Symbol("EnergyCapacity (MWh)")], 0.0) for
        row in eachrow(build_df)
    ]
    rows[!, Symbol("Max Power (MW)")] = Float64[
        to_float_output(row[Symbol("Capacity (MW)")], 0.0) for row in eachrow(build_df)
    ]
    return combine(
        groupby(rows, [:Zone, :Type]),
        Symbol("Capacity (MWh)") => sum => Symbol("Capacity (MWh)"),
        Symbol("Max Power (MW)") => sum => Symbol("Max Power (MW)"),
    )
end

function apply_line_builds!(linedata::DataFrame, line_builds::DataFrame)
    updated, _ = apply_line_builds_with_audit!(linedata, line_builds)
    return updated
end

time_series_zone_columns(df::DataFrame) = Set(
    String(col) for
    col in names(df) if !(String(col) in ["Time Period", "Month", "Day", "Hours", "NI"])
)

function holistic_spatial_basis(config::Dict)
    basis = lowercase(strip(string(get(config, "holistic_spatial_basis", "zone"))))
    basis in ("zone", "bus", "auto") || throw(
        ArgumentError(
            "holistic_spatial_basis must be 'zone', 'bus', or 'auto'; found $(basis).",
        ),
    )
    return basis
end

function corridor_signature_set(linedata::DataFrame)
    from_col = hasproperty(linedata, :From_zone) ? :From_zone : Symbol("From_zone")
    to_col = hasproperty(linedata, :To_zone) ? :To_zone : Symbol("To_zone")
    Set(
        let from_zone = string(row[from_col]), to_zone = string(row[to_col])
            string(min(from_zone, to_zone), "|", max(from_zone, to_zone))
        end for row in eachrow(linedata)
    )
end

function zone_reference_set(df::DataFrame, col::AbstractString)
    col_sym = Symbol(col)
    col_sym in Symbol.(names(df)) || return Set{String}()
    return Set(String.(skipmissing(df[!, col_sym])))
end

function collect_case_topology(
    case_label::AbstractString,
    case_path::AbstractString,
    config::Dict,
    input_data::Dict;
    spatial_basis::AbstractString = holistic_spatial_basis(config),
)
    basis = String(spatial_basis)
    use_pcm_nodal = basis == "bus" && uppercase(string(config["model_mode"])) == "PCM"
    node_table =
        use_pcm_nodal ? get(input_data, "Busdata", nothing) : input_data["Zonedata"]
    node_table === nothing &&
        throw(ArgumentError("PCM bus-basis holistic validation requires busdata."))
    node_column = use_pcm_nodal ? "Bus_id" : "Zone_id"
    nodes = Set(String.(node_table[!, node_column]))
    load_table =
        use_pcm_nodal ? get(input_data, "NodalLoaddata", nothing) :
        get(input_data, "Loaddata", nothing)
    load_nodes =
        load_table === nothing ? Set{String}() : time_series_zone_columns(load_table)
    reference_column = use_pcm_nodal ? "Bus_id" : "Zone"
    generator_nodes =
        haskey(input_data, "Gendata") ?
        zone_reference_set(input_data["Gendata"], reference_column) : Set{String}()
    storage_nodes =
        haskey(input_data, "Storagedata") ?
        zone_reference_set(input_data["Storagedata"], reference_column) : Set{String}()
    line_table =
        use_pcm_nodal && haskey(input_data, "Branchdata") ? input_data["Branchdata"] :
        get(input_data, "Linedata", nothing)
    from_column = use_pcm_nodal ? "from_bus" : "From_zone"
    to_column = use_pcm_nodal ? "to_bus" : "To_zone"
    line_from_nodes =
        line_table === nothing ? Set{String}() : zone_reference_set(line_table, from_column)
    line_to_nodes =
        line_table === nothing ? Set{String}() : zone_reference_set(line_table, to_column)
    line_nodes = union(line_from_nodes, line_to_nodes)
    corridor_table =
        line_table === nothing ? DataFrame() :
        rename(
            select(line_table, from_column, to_column),
            from_column => "From_zone",
            to_column => "To_zone",
        )
    corridors =
        line_table === nothing ? Set{String}() : corridor_signature_set(corridor_table)
    return Dict(
        "label" => case_label,
        "case_path" => case_path,
        "model_mode" => String(config["model_mode"]),
        "basis" => basis,
        "zones" => nodes,
        "load_zones" => load_nodes,
        "generator_zones" => generator_nodes,
        "storage_zones" => storage_nodes,
        "line_zones" => line_nodes,
        "corridors" => corridors,
    )
end

format_string_set(values::Set{String}) =
    isempty(values) ? "[]" : "[" * join(sort(collect(values)), ", ") * "]"

function validate_internal_topology_messages(topology::Dict)
    messages = String[]
    label = topology["label"]
    zones = topology["zones"]

    missing_load = setdiff(topology["load_zones"], zones)
    !isempty(missing_load) && push!(
        messages,
        "$(label): load_timeseries_regional has zones not present in zonedata.Zone_id: $(format_string_set(missing_load))",
    )

    missing_generators = setdiff(topology["generator_zones"], zones)
    !isempty(missing_generators) && push!(
        messages,
        "$(label): gendata has zones not present in zonedata.Zone_id: $(format_string_set(missing_generators))",
    )

    missing_storage = setdiff(topology["storage_zones"], zones)
    !isempty(missing_storage) && push!(
        messages,
        "$(label): storagedata has zones not present in zonedata.Zone_id: $(format_string_set(missing_storage))",
    )

    missing_lines = setdiff(topology["line_zones"], zones)
    !isempty(missing_lines) && push!(
        messages,
        "$(label): linedata has From_zone/To_zone values not present in zonedata.Zone_id: $(format_string_set(missing_lines))",
    )

    return messages
end

function validate_holistic_case_pair!(
    gtep_case::AbstractString,
    gtep_config::Dict,
    gtep_input::Dict,
    pcm_case::AbstractString,
    pcm_config::Dict,
    pcm_input::Dict,
)
    gtep_basis = holistic_spatial_basis(gtep_config)
    gtep_basis == "auto" && throw(
        ArgumentError("GTEP holistic_spatial_basis must be explicitly 'zone' or 'bus'."),
    )
    pcm_basis_configured = holistic_spatial_basis(pcm_config)
    pcm_basis = pcm_basis_configured == "auto" ? gtep_basis : pcm_basis_configured
    gtep_topology = collect_case_topology(
        "GTEP",
        gtep_case,
        gtep_config,
        gtep_input;
        spatial_basis = gtep_basis,
    )
    pcm_topology = collect_case_topology(
        "PCM",
        pcm_case,
        pcm_config,
        pcm_input;
        spatial_basis = pcm_basis,
    )

    messages = String[]
    uppercase(string(gtep_config["model_mode"])) == "GTEP" || push!(
        messages,
        "Holistic first-stage case must use model_mode: GTEP; found $(gtep_config["model_mode"]).",
    )
    uppercase(string(pcm_config["model_mode"])) == "PCM" || push!(
        messages,
        "Holistic second-stage case must use model_mode: PCM; found $(pcm_config["model_mode"]).",
    )
    append!(messages, validate_internal_topology_messages(gtep_topology))
    append!(messages, validate_internal_topology_messages(pcm_topology))

    gtep_topology["basis"] == pcm_topology["basis"] || push!(
        messages,
        "Holistic pair mismatch: GTEP uses $(gtep_topology["basis"])-basis validation while PCM uses $(pcm_topology["basis"])-basis validation.",
    )

    zone_only_in_gtep = setdiff(gtep_topology["zones"], pcm_topology["zones"])
    zone_only_in_pcm = setdiff(pcm_topology["zones"], gtep_topology["zones"])
    if !isempty(zone_only_in_gtep) || !isempty(zone_only_in_pcm)
        push!(
            messages,
            "Holistic pair mismatch: GTEP and PCM zonedata.Zone_id sets differ.",
        )
        !isempty(zone_only_in_gtep) &&
            push!(messages, "  Zones only in GTEP: $(format_string_set(zone_only_in_gtep))")
        !isempty(zone_only_in_pcm) &&
            push!(messages, "  Zones only in PCM: $(format_string_set(zone_only_in_pcm))")
    end

    corridor_only_in_gtep = setdiff(gtep_topology["corridors"], pcm_topology["corridors"])
    corridor_only_in_pcm = setdiff(pcm_topology["corridors"], gtep_topology["corridors"])
    if !isempty(corridor_only_in_gtep) || !isempty(corridor_only_in_pcm)
        push!(
            messages,
            "Holistic pair mismatch: GTEP and PCM linedata corridor sets differ.",
        )
        !isempty(corridor_only_in_gtep) && push!(
            messages,
            "  Corridors only in GTEP: $(format_string_set(corridor_only_in_gtep))",
        )
        !isempty(corridor_only_in_pcm) && push!(
            messages,
            "  Corridors only in PCM: $(format_string_set(corridor_only_in_pcm))",
        )
    end

    if !isempty(messages)
        details = join(messages, "\n")
        throw(
            ArgumentError(
                "run_hope_holistic requires a matched GTEP/PCM pair with a consistent configured spatial basis.\n" *
                "GTEP should define expansion decisions on the same zones or buses/corridors that PCM dispatches.\n" *
                "Please fix the reported mismatches or provide a harmonized paired case.\n\n" *
                details,
            ),
        )
    end
end

function prepare_pcm_inputs_from_gtep(gtep_output::Dict, pcm_input::Dict, pcm_config::Dict)
    holistic_debug_stage_log(pcm_config, "prepare_pcm_inputs_from_gtep_start")
    updated_input = deepcopy(pcm_input)
    holistic_debug_stage_log(pcm_config, "prepare_pcm_inputs_from_gtep_deepcopy_done")

    if resource_aggregation_enabled(pcm_config) &&
       !haskey(updated_input, "AFdata") &&
       haskey(updated_input, "GendataRaw")
        updated_input["Gendata"] = copy(updated_input["GendataRaw"])
        holistic_debug_stage_log(
            pcm_config,
            "prepare_pcm_inputs_from_gtep_using_raw_gendata",
        )
        holistic_debug_stage_log(
            pcm_config,
            "prepare_pcm_inputs_from_gtep_using_raw_gendata_rows=" *
            string(nrow(updated_input["Gendata"])),
        )
    end

    new_gen_rows = extract_new_generation_rows(gtep_output["capacity"])
    holistic_debug_stage_log(
        pcm_config,
        "prepare_pcm_inputs_from_gtep_new_generation_extracted",
    )
    if nrow(new_gen_rows) > 0
        updated_input["Gendata"] =
            append_rows_preserve_columns(updated_input["Gendata"], new_gen_rows)
        holistic_debug_stage_log(
            pcm_config,
            "prepare_pcm_inputs_from_gtep_new_generation_appended",
        )
    end

    new_storage_rows = extract_new_storage_rows(gtep_output["es_capacity"])
    holistic_debug_stage_log(
        pcm_config,
        "prepare_pcm_inputs_from_gtep_new_storage_extracted",
    )
    if nrow(new_storage_rows) > 0
        updated_input["Storagedata"] =
            append_rows_preserve_columns(updated_input["Storagedata"], new_storage_rows)
        holistic_debug_stage_log(
            pcm_config,
            "prepare_pcm_inputs_from_gtep_new_storage_appended",
        )
    end

    line_builds = filter(
        row ->
            to_float_output(row["New_Build"], 0.0) > 0 &&
                max(
                    to_float_output(row[Symbol(FORWARD_LINE_CAPACITY_COLUMN)], 0.0),
                    to_float_output(row[Symbol(REVERSE_LINE_CAPACITY_COLUMN)], 0.0),
                ) > 0,
        gtep_output["line"],
    )
    holistic_debug_stage_log(
        pcm_config,
        "prepare_pcm_inputs_from_gtep_line_builds_extracted",
    )
    if nrow(line_builds) > 0
        updated_input["Linedata"] =
            apply_line_builds!(copy(updated_input["Linedata"]), line_builds)
        holistic_debug_stage_log(
            pcm_config,
            "prepare_pcm_inputs_from_gtep_line_builds_applied",
        )
    end

    holistic_debug_stage_log(pcm_config, "prepare_pcm_inputs_from_gtep_finalize_start")
    finalize_pcm_inputs_for_holistic!(updated_input, pcm_config)
    if resource_aggregation_enabled(pcm_config)
        if haskey(updated_input, "AFdata")
            holistic_debug_stage_log(
                pcm_config,
                "prepare_pcm_inputs_from_gtep_reaggregation_skipped_afdata",
            )
        else
            holistic_debug_stage_log(
                pcm_config,
                "prepare_pcm_inputs_from_gtep_reaggregation_start",
            )
            raw_pcm_gendata = copy(updated_input["Gendata"])
            updated_input["GendataRaw"] = copy(raw_pcm_gendata)
            holistic_debug_stage_log(
                pcm_config,
                "prepare_pcm_inputs_from_gtep_reaggregation_raw_rows=" *
                string(nrow(raw_pcm_gendata)),
            )
            updated_input["Gendata"] = aggregate_gendata_pcm(raw_pcm_gendata, pcm_config)
            updated_input["AggregationAudit"] = build_pcm_aggregation_audit(
                raw_pcm_gendata,
                updated_input["Gendata"];
                config_set = pcm_config,
            )
            holistic_debug_stage_log(
                pcm_config,
                "prepare_pcm_inputs_from_gtep_reaggregation_done",
            )
            holistic_debug_stage_log(
                pcm_config,
                "prepare_pcm_inputs_from_gtep_reaggregation_done_rows=" *
                string(nrow(updated_input["Gendata"])),
            )
        end
    end
    holistic_debug_stage_log(pcm_config, "prepare_pcm_inputs_from_gtep_finalize_done")
    return updated_input
end

function release_gtep_state_for_pcm!(gtep_results)
    for key in ("solved_model", "input", "snapshot")
        if haskey(gtep_results, key)
            gtep_results[key] = nothing
        end
    end
    GC.gc()
    return gtep_results
end

function is_holistic_output_dir_name(name::AbstractString)
    return name in ("output", "output_holistic", "plot_output", "backup", "debug_report") ||
           startswith(name, "output_backup")
end

function sync_case_tree_without_outputs(
    source_dir::AbstractString,
    destination_dir::AbstractString,
)
    mkpath(destination_dir)
    for entry in readdir(source_dir)
        source_entry = joinpath(source_dir, entry)
        destination_entry = joinpath(destination_dir, entry)
        if isdir(source_entry)
            is_holistic_output_dir_name(entry) && continue
            sync_case_tree_without_outputs(source_entry, destination_entry)
        else
            cp(source_entry, destination_entry; force = true)
        end
    end
    return destination_dir
end

function set_holistic_debug_stage_file!(
    case_dir::AbstractString,
    debug_stage_file::AbstractString,
)
    settings_path = joinpath(case_dir, "Settings", "HOPE_model_settings.yml")
    lines = readlines(settings_path)
    replacement = "debug_stage_file: \"$(replace(normpath(String(debug_stage_file)), "\\" => "/"))\""
    replaced = false
    for idx in eachindex(lines)
        if startswith(strip(lines[idx]), "debug_stage_file:")
            lines[idx] = replacement
            replaced = true
            break
        end
    end
    if !replaced
        push!(lines, replacement)
    end
    open(settings_path, "w") do io
        for line in lines
            println(io, line)
        end
    end
    return settings_path
end

function prepare_fresh_holistic_case(
    source_case::AbstractString,
    tag::AbstractString;
    debug_stage_file::Union{Nothing,AbstractString} = nothing,
)
    source_case_dir = normalize_holistic_case_path(source_case)
    source_case_name = basename(source_case_dir)
    fresh_case_dir = normpath(
        joinpath(
            dirname(source_case_dir),
            string(
                source_case_name,
                "_",
                tag,
                "_",
                Dates.format(now(), dateformat"yyyymmdd_HHMMSS_s"),
            ),
        ),
    )
    sync_case_tree_without_outputs(source_case_dir, fresh_case_dir)
    if debug_stage_file !== nothing
        set_holistic_debug_stage_file!(fresh_case_dir, debug_stage_file)
    end
    return fresh_case_dir
end

"""
    run_hope_holistic_fresh(
        GTEP_source_case::AbstractString,
        PCM_source_case::AbstractString;
        gtep_tag::AbstractString = "gtep_run",
        pcm_tag::AbstractString  = "pcm_run",
        debug_stage_file::Union{Nothing,AbstractString} = nothing,
    ) -> Dict

Clone both source cases to fresh timestamped directories, then run `run_hope_holistic`.

Each cloned directory is named `<source>_<tag>_<timestamp>` and placed next to the source
case.  Input files are copied; existing `output/` trees are excluded so each run starts
from a clean state.

Returns the same `Dict` as `run_hope_holistic`, extended with keys
`"fresh_gtep_case_path"` and `"fresh_pcm_case_path"` pointing to the cloned directories.
"""
function run_hope_holistic_fresh(
    GTEP_source_case::AbstractString,
    PCM_source_case::AbstractString;
    gtep_tag::AbstractString = "gtep_run",
    pcm_tag::AbstractString = "pcm_run",
    debug_stage_file::Union{Nothing,AbstractString} = nothing,
    solver_override = nothing,
    gtep_solver_override = nothing,
    pcm_solver_override = nothing,
)
    fresh_gtep_case = prepare_fresh_holistic_case(
        GTEP_source_case,
        gtep_tag;
        debug_stage_file = debug_stage_file,
    )
    fresh_pcm_case = prepare_fresh_holistic_case(
        PCM_source_case,
        pcm_tag;
        debug_stage_file = debug_stage_file,
    )
    result = run_hope_holistic(
        fresh_gtep_case,
        fresh_pcm_case;
        solver_override = solver_override,
        gtep_solver_override = gtep_solver_override,
        pcm_solver_override = pcm_solver_override,
    )
    result["fresh_gtep_case_path"] = fresh_gtep_case
    result["fresh_pcm_case_path"] = fresh_pcm_case
    return result
end

"""
    _run_hope_holistic_impl(GTEP_case::AbstractString, PCM_case::AbstractString) -> Dict

Run the two-stage holistic GTEP→PCM workflow.

1. The GTEP stage solves the expansion planning problem for `GTEP_case`.
2. Retirements and new generator, storage, and transmission decisions are
   realized in an in-memory copy of the PCM inputs.
3. The PCM stage solves the production cost problem with the updated fleet.
4. Realized inputs, mapping audits, and a handoff manifest are written under the
   PCM output directory in `realized_inputs/`.

The source GTEP and PCM input directories are not modified. Stable identity
columns are optional; legacy cases use validated row or aggregate mappings.

Both case directories must share a consistent zonal topology; mismatches raise an
`ArgumentError` before any solve is attempted.

Returns a `Dict` with keys `"gtep_output"` and `"pcm_output"` containing the respective
result dictionaries.
"""
function _run_hope_holistic_impl(
    GTEP_case::AbstractString,
    PCM_case::AbstractString,
    gtep_solver_override = nothing,
    pcm_solver_override = nothing,
)
    println("Run Holistic Assessment: 'GTEP-PCM' mode!")
    gtep_path, gtep_config =
        load_case_config_for_holistic(GTEP_case; context = "run_hope_holistic")
    pcm_path, pcm_config =
        load_case_config_for_holistic(PCM_case; context = "run_hope_holistic")
    gtep_config["solver"] = _effective_solver_name(gtep_config, gtep_solver_override)
    pcm_config["solver"] = _effective_solver_name(pcm_config, pcm_solver_override)
    holistic_debug_stage_log_pair(
        gtep_config,
        pcm_config,
        "run_hope_holistic_configs_loaded",
    )

    println("Checking topology compatibility before solve")
    holistic_debug_stage_log_pair(
        gtep_config,
        pcm_config,
        "run_hope_holistic_topology_load_start",
    )
    gtep_input = load_data(gtep_config, gtep_path)
    pcm_input = load_data(pcm_config, pcm_path)
    holistic_debug_stage_log_pair(
        gtep_config,
        pcm_config,
        "run_hope_holistic_topology_load_done",
    )
    handoff_contract = validate_holistic_handoff_contract(
        gtep_path,
        gtep_config,
        gtep_input,
        pcm_path,
        pcm_config,
        pcm_input,
    )
    holistic_debug_stage_log_pair(
        gtep_config,
        pcm_config,
        "run_hope_holistic_topology_validated",
    )

    println("First stage: solving 'GTEP' mode!")
    source_gtep_hashes_before = _holistic_source_hashes(gtep_path, gtep_config)
    source_pcm_hashes_before = _holistic_source_hashes(pcm_path, pcm_config)
    holistic_debug_stage_log_pair(
        gtep_config,
        pcm_config,
        "run_hope_holistic_gtep_run_start",
    )
    gtep_results = run_hope(gtep_path; solver_override = gtep_config["solver"])
    holistic_debug_stage_log_pair(
        gtep_config,
        pcm_config,
        "run_hope_holistic_gtep_run_done",
    )
    gtep_output = gtep_results["output"]
    gtep_activity = holistic_model_activity_metrics(gtep_results["solved_model"], "gtep")
    release_gtep_state_for_pcm!(gtep_results)
    holistic_debug_stage_log_pair(
        gtep_config,
        pcm_config,
        "run_hope_holistic_gtep_release_done",
    )

    println("Second stage: preparing 'PCM' inputs from solved GTEP builds")
    holistic_debug_stage_log_pair(
        gtep_config,
        pcm_config,
        "run_hope_holistic_pcm_reload_start",
    )
    pcm_input = load_data(pcm_config, pcm_path)
    holistic_debug_stage_log_pair(
        gtep_config,
        pcm_config,
        "run_hope_holistic_pcm_reload_done",
    )
    updated_pcm_input = prepare_pcm_inputs_from_gtep_linked(
        gtep_output,
        gtep_input,
        gtep_config,
        pcm_input,
        pcm_config,
        handoff_contract["physical_realization"],
    )
    transfer_reconciliation = validate_holistic_transfer_reconciliation(
        gtep_output,
        gtep_input,
        pcm_input,
        updated_pcm_input,
        pcm_config,
    )
    holistic_debug_stage_log_pair(
        gtep_config,
        pcm_config,
        "run_hope_holistic_pcm_prepare_done",
    )
    transfer_summary = holistic_transfer_summary(updated_pcm_input)
    gtep_results["output"] = gtep_output

    println("Second stage: solving 'PCM' mode with GTEP-informed capacities")
    holistic_debug_stage_log_pair(
        gtep_config,
        pcm_config,
        "run_hope_holistic_pcm_model_build_start",
    )
    optimizer = initiate_solver(pcm_path, String(pcm_config["solver"]))
    pcm_model = create_PCM_model(pcm_config, updated_pcm_input, optimizer)
    holistic_debug_stage_log_pair(
        gtep_config,
        pcm_config,
        "run_hope_holistic_pcm_model_build_done",
    )
    solved_pcm_model = solve_model(pcm_config, updated_pcm_input, pcm_model)
    pcm_operational_state_trace =
        maybe_capture_pcm_operational_trace(pcm_config, updated_pcm_input, solved_pcm_model)
    pcm_activity = holistic_model_activity_metrics(solved_pcm_model, "pcm")
    holistic_debug_stage_log_pair(
        gtep_config,
        pcm_config,
        "run_hope_holistic_pcm_solve_done",
    )
    require_feasible_primal_solution(solved_pcm_model; context = "Holistic PCM stage")
    pcm_transfer_activity = holistic_pcm_transfer_activity_metrics(
        solved_pcm_model,
        updated_pcm_input,
        pcm_input,
        pcm_config,
    )

    pcm_outpath = joinpath(pcm_path, "output_holistic")
    holistic_debug_stage_log_pair(
        gtep_config,
        pcm_config,
        "run_hope_holistic_pcm_output_write_start",
    )
    pcm_output_write = write_output_with_metadata(
        pcm_outpath,
        pcm_config,
        updated_pcm_input,
        solved_pcm_model,
    )
    pcm_output = pcm_output_write.results
    actual_pcm_outpath = pcm_output_write.actual_outpath
    holistic_debug_stage_log_pair(
        gtep_config,
        pcm_config,
        "run_hope_holistic_pcm_input_persist_start",
    )
    persisted_pcm_input_paths = persist_realized_pcm_inputs_for_holistic(
        actual_pcm_outpath,
        pcm_config,
        updated_pcm_input;
        gtep_case_path = gtep_path,
        pcm_case_path = pcm_path,
        gtep_config = gtep_config,
        transfer_reconciliation = transfer_reconciliation,
    )
    source_gtep_hashes_after = _holistic_source_hashes(gtep_path, gtep_config)
    source_pcm_hashes_after = _holistic_source_hashes(pcm_path, pcm_config)
    validate_holistic_source_immutability!(
        handoff_contract,
        source_gtep_hashes_after,
        source_pcm_hashes_after,
        require_valid = false,
    )
    handoff_contract_paths =
        write_holistic_handoff_contract_report(actual_pcm_outpath, handoff_contract)
    handoff_contract["valid"] ||
        throw(ErrorException("Holistic workflow modified a source input file."))
    holistic_debug_stage_log_pair(
        gtep_config,
        pcm_config,
        "run_hope_holistic_pcm_input_persist_done",
    )
    holistic_debug_stage_log_pair(
        gtep_config,
        pcm_config,
        "run_hope_holistic_pcm_output_write_done",
    )

    println("Holistic two-stage 'GTEP-PCM' mode solved successfully.")
    holistic_debug_stage_log_pair(gtep_config, pcm_config, "run_hope_holistic_completed")
    return Dict(
        "gtep" => gtep_results,
        "pcm_case_path" => pcm_path,
        "pcm_output_path" => actual_pcm_outpath,
        "pcm_persisted_input_paths" => persisted_pcm_input_paths,
        "pcm_config" => pcm_config,
        "pcm_input" => updated_pcm_input,
        "pcm_solved_model" => solved_pcm_model,
        "pcm_operational_state_trace" => pcm_operational_state_trace,
        "pcm_output" => pcm_output,
        "transfer_summary" => transfer_summary,
        "transfer_reconciliation" => transfer_reconciliation,
        "handoff_contract" => handoff_contract,
        "handoff_contract_paths" => handoff_contract_paths,
        "gtep_activity" => gtep_activity,
        "pcm_activity" => pcm_activity,
        "pcm_transfer_activity" => pcm_transfer_activity,
        "source_gtep_hashes_before" => source_gtep_hashes_before,
        "source_gtep_hashes_after" => source_gtep_hashes_after,
        "source_pcm_hashes_before" => source_pcm_hashes_before,
        "source_pcm_hashes_after" => source_pcm_hashes_after,
    )
end

"""
    run_hope_holistic(GTEP_case::AbstractString, PCM_case::AbstractString;
                      solver_override=nothing,
                      gtep_solver_override=nothing,
                      pcm_solver_override=nothing) -> Dict

Run the two-stage holistic GTEP-to-PCM workflow. Optional solver extensions are
loaded before entering the compiled workflow so dynamically selected Gurobi,
CPLEX, and SCIP methods are visible during both model-construction stages.
Solver overrides affect only the current run and never edit either source case.
"""
function run_hope_holistic(
    GTEP_case::AbstractString,
    PCM_case::AbstractString;
    solver_override = nothing,
    gtep_solver_override = nothing,
    pcm_solver_override = nothing,
)
    _, gtep_config = load_case_config_for_holistic(GTEP_case; context = "run_hope_holistic")
    _, pcm_config = load_case_config_for_holistic(PCM_case; context = "run_hope_holistic")
    effective_gtep_override =
        gtep_solver_override === nothing ? solver_override : gtep_solver_override
    effective_pcm_override =
        pcm_solver_override === nothing ? solver_override : pcm_solver_override
    gtep_config["solver"] = _effective_solver_name(gtep_config, effective_gtep_override)
    pcm_config["solver"] = _effective_solver_name(pcm_config, effective_pcm_override)
    solver_names = unique(
        lowercase.(
            String[
                string(get(gtep_config, "solver", "")),
                string(get(pcm_config, "solver", "")),
            ],
        ),
    )
    optional_solver_requested = false
    for solver_name in solver_names
        if haskey(OPTIONAL_SOLVER_PACKAGES, solver_name)
            optional_solver_requested = true
            _ensure_optional_solver_loaded(solver_name)
        end
    end
    if optional_solver_requested
        return Base.invokelatest(
            _run_hope_holistic_impl,
            GTEP_case,
            PCM_case,
            effective_gtep_override,
            effective_pcm_override,
        )
    end
    return _run_hope_holistic_impl(
        GTEP_case,
        PCM_case,
        effective_gtep_override,
        effective_pcm_override,
    )
end
