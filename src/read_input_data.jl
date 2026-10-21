#Function use for aggregrating generation data:
to_float_agg(x, d = 0.0) =
    ismissing(x) || x === nothing || string(x) == "" ? d :
    (x isa Number ? Float64(x) : parse(Float64, string(x)))

function agg_weights_from_pmax(gdf::AbstractDataFrame)
    w = [max(to_float_agg(v, 0.0), 0.0) for v in gdf[!, Symbol("Pmax (MW)")]]
    sw = sum(w)
    if sw <= 0
        return fill(1.0, nrow(gdf))
    end
    return w
end

function wmean_col(
    gdf::AbstractDataFrame,
    col::Symbol,
    w::Vector{Float64};
    default::Float64 = 0.0,
)
    vals = [to_float_agg(v, default) for v in gdf[!, col]]
    sw = sum(w)
    if sw <= 0
        return isempty(vals) ? default : mean(vals)
    end
    return sum(vals .* w) / sw
end

flag_any(gdf::AbstractDataFrame, col::Symbol) =
    any(to_float_agg(v, 0.0) > 0 for v in gdf[!, col]) ? 1 : 0

function aggregated_num_units(gdf::AbstractDataFrame)
    if :NumUnits in Symbol.(names(gdf))
        return max(
            sum(max(1, round(Int, to_float_agg(v, 1.0))) for v in gdf[!, :NumUnits]),
            1,
        )
    end
    return max(nrow(gdf), 1)
end

function clustering_feature_matrix(gdf::AbstractDataFrame, config_set::AbstractDict)
    feature_names = aggregation_setting_string_list(
        config_set,
        "clustering_feature_columns",
        ["Cost (\$/MWh)", "FOR", "CC", "AF", "RU", "RD", "Pmax (MW)", "Pmin (MW)"],
    )
    available = [Symbol(col) for col in feature_names if col in names(gdf)]
    if isempty(available)
        return zeros(Float64, nrow(gdf), 0), String[]
    end
    mat = hcat(
        [
            Float64[to_float_agg(gdf[i, col], 0.0) for i = 1:nrow(gdf)] for col in available
        ]...,
    )
    if normalize_clustering_features_enabled(config_set)
        for j = 1:size(mat, 2)
            colvals = mat[:, j]
            μ = mean(colvals)
            σ = std(colvals)
            if σ > 0
                mat[:, j] .= (colvals .- μ) ./ σ
            else
                mat[:, j] .= 0.0
            end
        end
    end
    return mat, string.(available)
end

function feature_cluster_assignments(gdf::AbstractDataFrame, config_set::AbstractDict)
    n = nrow(gdf)
    n <= 1 && return ones(Int, n), 1, String[]
    if !feature_based_clustering_enabled(config_set)
        return ones(Int, n), 1, String[]
    end
    target_size = clustering_target_cluster_size(config_set)
    n <= target_size && return ones(Int, n), 1, String[]
    feature_matrix, feature_cols = clustering_feature_matrix(gdf, config_set)
    size(feature_matrix, 2) == 0 && return ones(Int, n), 1, String[]
    if all(
        all(
            isapprox(feature_matrix[i, j], feature_matrix[1, j]; atol = 1e-9) for
            j = 1:size(feature_matrix, 2)
        ) for i = 2:n
    )
        return ones(Int, n), 1, feature_cols
    end
    k = ceil(Int, n / target_size)
    max_clusters = clustering_max_clusters_per_group(config_set)
    if max_clusters > 0
        k = min(k, max_clusters)
    end
    k = clamp(k, 1, n)
    k == 1 && return ones(Int, n), 1, feature_cols
    result = kmeans(transpose(feature_matrix), k)
    assignments = collect(Int.(result.assignments))
    present_clusters = sort(unique(assignments))
    cluster_map = Dict(old => new for (new, old) in enumerate(present_clusters))
    return [cluster_map[a] for a in assignments], length(present_clusters), feature_cols
end

function grouped_row_indices_by_aggregation(
    df::DataFrame,
    config_set::AbstractDict = Dict{String,Any}();
    model_mode::AbstractString = "GTEP",
)
    key_cols = aggregation_grouping_keys(df, config_set, model_mode)
    groups = Dict{Tuple{Vararg{String}},Vector{Int}}()
    group_labels = Dict{Tuple{Vararg{String}},String}()
    order = Tuple{Vararg{String}}[]
    base_groups = Dict{Tuple{Vararg{String}},Vector{Int}}()
    base_order = Tuple{Vararg{String}}[]
    for (i, row) in enumerate(eachrow(df))
        base_key = if aggregation_should_merge_type(string(row["Type"]), config_set)
            Tuple(string(row[col]) for col in key_cols)
        else
            Tuple(vcat(["__separate__$(i)"], [string(row[col]) for col in key_cols]))
        end
        if !haskey(base_groups, base_key)
            base_groups[base_key] = Int[]
            push!(base_order, base_key)
        end
        push!(base_groups[base_key], i)
    end

    for base_key in base_order
        rows = base_groups[base_key]
        gdf = df[rows, :]
        assignments, num_clusters, feature_cols =
            feature_cluster_assignments(gdf, config_set)
        for cluster_idx = 1:num_clusters
            member_positions = findall(==(cluster_idx), assignments)
            isempty(member_positions) && continue
            member_rows = rows[member_positions]
            key =
                num_clusters == 1 ? base_key :
                Tuple(vcat(collect(base_key), ["__cluster__$(cluster_idx)"]))
            groups[key] = member_rows
            push!(order, key)
            base_label =
                join(["$(key_cols[j])=$(base_key[j])" for j in eachindex(key_cols)], "; ")
            if num_clusters == 1
                group_labels[key] = base_label
            else
                feature_label =
                    isempty(feature_cols) ? "" :
                    " [features=" * join(feature_cols, ",") * "]"
                group_labels[key] =
                    base_label *
                    "; FeatureCluster=$(cluster_idx)/$(num_clusters)" *
                    feature_label
            end
        end
    end
    return order, groups, key_cols, group_labels
end

function aggregate_gendata_gtep(
    df::DataFrame,
    config_set::AbstractDict = Dict{String,Any}(),
)
    work = copy(df)
    if !("AF" in names(work))
        work[!, :AF] = fill(1.0, nrow(work))
    end
    has_for = "FOR" in names(work)
    has_rps = "Flag_RPS" in names(work)
    out = DataFrame(
        :Zone => Any[],
        :Type => Any[],
        Symbol("Pmax (MW)") => Float64[],
        Symbol("Pmin (MW)") => Float64[],
        Symbol("Cost (\$/MWh)") => Float64[],
        :EF => Float64[],
        :CC => Float64[],
        :AF => Float64[],
        :FOR => Float64[],
        :Flag_thermal => Int[],
        :Flag_VRE => Int[],
        :Flag_RET => Int[],
        :Flag_mustrun => Int[],
    )
    if has_rps
        out[!, :Flag_RPS] = Int[]
    end

    order, groups, _, _ =
        grouped_row_indices_by_aggregation(work, config_set; model_mode = "GTEP")
    for key in order
        gdf = work[groups[key], :]
        w = agg_weights_from_pmax(gdf)
        if has_rps
            row = (
                gdf[1, :Zone],
                gdf[1, :Type],
                sum(to_float_agg(v, 0.0) for v in gdf[!, Symbol("Pmax (MW)")]),
                sum(to_float_agg(v, 0.0) for v in gdf[!, Symbol("Pmin (MW)")]),
                wmean_col(gdf, Symbol("Cost (\$/MWh)"), w; default = 0.0),
                wmean_col(gdf, :EF, w; default = 0.0),
                wmean_col(gdf, :CC, w; default = 0.0),
                wmean_col(gdf, :AF, w; default = 1.0),
                has_for ? wmean_col(gdf, :FOR, w; default = 0.0) : 0.0,
                flag_any(gdf, :Flag_thermal),
                flag_any(gdf, :Flag_VRE),
                flag_any(gdf, :Flag_RET),
                flag_any(gdf, :Flag_mustrun),
                flag_any(gdf, :Flag_RPS),
            )
            push!(out, row)
        else
            row = (
                gdf[1, :Zone],
                gdf[1, :Type],
                sum(to_float_agg(v, 0.0) for v in gdf[!, Symbol("Pmax (MW)")]),
                sum(to_float_agg(v, 0.0) for v in gdf[!, Symbol("Pmin (MW)")]),
                wmean_col(gdf, Symbol("Cost (\$/MWh)"), w; default = 0.0),
                wmean_col(gdf, :EF, w; default = 0.0),
                wmean_col(gdf, :CC, w; default = 0.0),
                wmean_col(gdf, :AF, w; default = 1.0),
                has_for ? wmean_col(gdf, :FOR, w; default = 0.0) : 0.0,
                flag_any(gdf, :Flag_thermal),
                flag_any(gdf, :Flag_VRE),
                flag_any(gdf, :Flag_RET),
                flag_any(gdf, :Flag_mustrun),
            )
            push!(out, row)
        end
    end
    return out
end

function aggregate_afdata_gtep(
    raw_gendata::DataFrame,
    aggregated_gendata::DataFrame,
    gendata_candidate::DataFrame,
    raw_afdata::DataFrame,
    config_set::AbstractDict = Dict{String,Any}(),
)
    time_cols = [
        col for col in ["Time Period", "Month", "Day", "Hours"] if col in names(raw_afdata)
    ]
    out = copy(raw_afdata[:, time_cols])
    order, groups, _, _ =
        grouped_row_indices_by_aggregation(raw_gendata, config_set; model_mode = "GTEP")

    for (new_idx, key) in enumerate(order)
        rows = groups[key]
        source_cols = [col for col in ["G$(i)" for i in rows] if col in names(raw_afdata)]
        if isempty(source_cols)
            continue
        end
        weights =
            [max(to_float_agg(raw_gendata[i, Symbol("Pmax (MW)")], 0.0), 0.0) for i in rows]
        if length(source_cols) == 1
            out[!, "G$(new_idx)"] = copy(raw_afdata[!, source_cols[1]])
        else
            sw = sum(weights)
            if sw <= 0
                weights = fill(1.0 / length(source_cols), length(source_cols))
            else
                weights = weights ./ sw
            end
            out[!, "G$(new_idx)"] = [
                sum(
                    weights[k] * to_float_agg(raw_afdata[h, source_cols[k]], 1.0) for
                    k in eachindex(source_cols)
                ) for h = 1:nrow(raw_afdata)
            ]
        end
    end

    num_raw_exist = nrow(raw_gendata)
    num_agg_exist = nrow(aggregated_gendata)
    for j = 1:nrow(gendata_candidate)
        source_col = "G$(num_raw_exist + j)"
        target_col = "G$(num_agg_exist + j)"
        if source_col in names(raw_afdata)
            out[!, target_col] = copy(raw_afdata[!, source_col])
        end
    end

    return out
end

function aggregate_gendata_pcm(df::DataFrame, config_set::Dict)
    work = copy(df)
    has_uc = config_set["unit_commitment"] != 0
    has_reg_up = :RM_REG_UP in names(work)
    has_reg_dn = :RM_REG_DN in names(work)
    has_nspin = :RM_NSPIN in names(work)

    out = DataFrame(
        :Zone => Any[],
        :Type => Any[],
        Symbol("Pmax (MW)") => Float64[],
        Symbol("Pmin (MW)") => Float64[],
        Symbol("Cost (\$/MWh)") => Float64[],
        :EF => Float64[],
        :CC => Float64[],
        :FOR => Float64[],
        :RM_SPIN => Float64[],
        :RU => Float64[],
        :RD => Float64[],
        :NumUnits => Int[],
        Symbol("ClusteredUnitPmax (MW)") => Float64[],
        Symbol("ClusteredUnitPmin (MW)") => Float64[],
        :Flag_thermal => Int[],
        :Flag_VRE => Int[],
        :Flag_mustrun => Int[],
    )
    if has_uc
        out[!, :Flag_UC] = Int[]
        out[!, Symbol("Start_up_cost (\$/MW)")] = Float64[]
        out[!, :Min_down_time] = Float64[]
        out[!, :Min_up_time] = Float64[]
    end
    if has_reg_up
        out[!, :RM_REG_UP] = Float64[]
    end
    if has_reg_dn
        out[!, :RM_REG_DN] = Float64[]
    end
    if has_nspin
        out[!, :RM_NSPIN] = Float64[]
    end

    order, groups, _, _ =
        grouped_row_indices_by_aggregation(work, config_set; model_mode = "PCM")
    for key in order
        gdf = work[groups[key], :]
        w = agg_weights_from_pmax(gdf)
        total_pmax = sum(to_float_agg(v, 0.0) for v in gdf[!, Symbol("Pmax (MW)")])
        total_pmin = sum(to_float_agg(v, 0.0) for v in gdf[!, Symbol("Pmin (MW)")])
        cluster_units = aggregated_num_units(gdf)
        cluster_unit_pmax = cluster_units > 0 ? total_pmax / cluster_units : total_pmax
        cluster_unit_pmin = cluster_units > 0 ? total_pmin / cluster_units : total_pmin
        row = Dict{Symbol,Any}(
            :Zone => gdf[1, :Zone],
            :Type => gdf[1, :Type],
            Symbol("Pmax (MW)") => total_pmax,
            Symbol("Pmin (MW)") => total_pmin,
            Symbol("Cost (\$/MWh)") =>
                wmean_col(gdf, Symbol("Cost (\$/MWh)"), w; default = 0.0),
            :EF => wmean_col(gdf, :EF, w; default = 0.0),
            :CC => wmean_col(gdf, :CC, w; default = 0.0),
            :FOR => wmean_col(gdf, :FOR, w; default = 0.0),
            :RM_SPIN => wmean_col(gdf, :RM_SPIN, w; default = 0.0),
            :RU => wmean_col(gdf, :RU, w; default = 0.0),
            :RD => wmean_col(gdf, :RD, w; default = 0.0),
            :NumUnits => cluster_units,
            Symbol("ClusteredUnitPmax (MW)") => cluster_unit_pmax,
            Symbol("ClusteredUnitPmin (MW)") => cluster_unit_pmin,
            :Flag_thermal => flag_any(gdf, :Flag_thermal),
            :Flag_VRE => flag_any(gdf, :Flag_VRE),
            :Flag_mustrun => flag_any(gdf, :Flag_mustrun),
        )
        if has_uc
            row[:Flag_UC] = flag_any(gdf, :Flag_UC)
            row[Symbol("Start_up_cost (\$/MW)")] =
                wmean_col(gdf, Symbol("Start_up_cost (\$/MW)"), w; default = 0.0)
            row[:Min_down_time] = wmean_col(gdf, :Min_down_time, w; default = 0.0)
            row[:Min_up_time] = wmean_col(gdf, :Min_up_time, w; default = 0.0)
        end
        if has_reg_up
            row[:RM_REG_UP] = wmean_col(gdf, :RM_REG_UP, w; default = 0.0)
        end
        if has_reg_dn
            row[:RM_REG_DN] = wmean_col(gdf, :RM_REG_DN, w; default = 0.0)
        end
        if has_nspin
            row[:RM_NSPIN] = wmean_col(gdf, :RM_NSPIN, w; default = 0.0)
        end
        push!(out, row)
    end
    return out
end

function normalized_agg_shares(weights::Vector{Float64})
    sw = sum(weights)
    if sw <= 0
        return isempty(weights) ? Float64[] : fill(1.0 / length(weights), length(weights))
    end
    return weights ./ sw
end

function build_gtep_aggregation_audit(
    raw_gendata::DataFrame,
    aggregated_gendata::DataFrame;
    config_set::AbstractDict = Dict{String,Any}(),
    raw_afdata::Union{Nothing,DataFrame} = nothing,
    aggregated_afdata::Union{Nothing,DataFrame} = nothing,
)
    order, groups, key_cols, group_labels =
        grouped_row_indices_by_aggregation(raw_gendata, config_set; model_mode = "GTEP")
    mapping_df = DataFrame(
        AggregatedResource = String[],
        Zone = String[],
        Type = String[],
        GroupingKey = String[],
        OriginalIndex = Int[],
        OriginalResource = String[],
        OriginalPmaxMW = Float64[],
        WeightPmaxMW = Float64[],
        WeightShare = Float64[],
    )
    summary_df = DataFrame(
        AggregatedResource = String[],
        Zone = String[],
        Type = String[],
        GroupingKey = String[],
        GroupSize = Int[],
        OriginalPmaxMW = Float64[],
        AggregatedPmaxMW = Float64[],
        AggregatedPminMW = Float64[],
        AggregatedCostPerMWh = Float64[],
        AggregatedCC = Float64[],
        AggregatedAF = Float64[],
        AggregatedFOR = Float64[],
        Flag_thermal = Int[],
        Flag_VRE = Int[],
        Flag_RET = Int[],
        Flag_mustrun = Int[],
    )
    af_summary_df = DataFrame(
        AggregatedResource = String[],
        Zone = String[],
        Type = String[],
        GroupingKey = String[],
        NumSourceColumns = Int[],
        AggregatedColumn = String[],
        SourceMeanAFMin = Float64[],
        SourceMeanAFMax = Float64[],
        SourceHourlyAFMin = Float64[],
        SourceHourlyAFMax = Float64[],
        AggregatedHourlyAFMin = Float64[],
        AggregatedHourlyAFMax = Float64[],
    )

    for (new_idx, key) in enumerate(order)
        rows = groups[key]
        gdf = raw_gendata[rows, :]
        weights =
            [max(to_float_agg(gdf[r, Symbol("Pmax (MW)")], 0.0), 0.0) for r = 1:nrow(gdf)]
        shares = normalized_agg_shares(weights)
        agg_nm = "G$(new_idx)"
        grouping_key = get(
            group_labels,
            key,
            join(["$(key_cols[j])=$(key[j])" for j in eachindex(key_cols)], "; "),
        )

        for (local_idx, raw_idx) in enumerate(rows)
            push!(
                mapping_df,
                (
                    agg_nm,
                    string(raw_gendata[raw_idx, "Zone"]),
                    string(raw_gendata[raw_idx, "Type"]),
                    grouping_key,
                    raw_idx,
                    "G$(raw_idx)",
                    to_float_agg(raw_gendata[raw_idx, Symbol("Pmax (MW)")], 0.0),
                    weights[local_idx],
                    shares[local_idx],
                ),
            )
        end

        agg_row = aggregated_gendata[new_idx, :]
        push!(
            summary_df,
            (
                agg_nm,
                string(gdf[1, "Zone"]),
                string(gdf[1, "Type"]),
                grouping_key,
                length(rows),
                sum(to_float_agg(v, 0.0) for v in gdf[!, Symbol("Pmax (MW)")]),
                to_float_agg(agg_row[Symbol("Pmax (MW)")], 0.0),
                to_float_agg(agg_row[Symbol("Pmin (MW)")], 0.0),
                to_float_agg(agg_row[Symbol("Cost (\$/MWh)")], 0.0),
                to_float_agg(agg_row[:CC], 0.0),
                to_float_agg(agg_row[:AF], 1.0),
                ("FOR" in names(aggregated_gendata)) ? to_float_agg(agg_row[:FOR], 0.0) :
                0.0,
                Int(to_float_agg(agg_row[:Flag_thermal], 0.0)),
                Int(to_float_agg(agg_row[:Flag_VRE], 0.0)),
                Int(to_float_agg(agg_row[:Flag_RET], 0.0)),
                Int(to_float_agg(agg_row[:Flag_mustrun], 0.0)),
            ),
        )

        if raw_afdata !== nothing && aggregated_afdata !== nothing
            source_cols =
                [col for col in ["G$(i)" for i in rows] if col in names(raw_afdata)]
            target_col = "G$(new_idx)"
            if !isempty(source_cols) && (target_col in names(aggregated_afdata))
                source_means = [mean(Float64.(raw_afdata[!, col])) for col in source_cols]
                source_hourly_min =
                    minimum(vcat([Float64.(raw_afdata[!, col]) for col in source_cols]...))
                source_hourly_max =
                    maximum(vcat([Float64.(raw_afdata[!, col]) for col in source_cols]...))
                agg_vals = Float64.(aggregated_afdata[!, target_col])
                push!(
                    af_summary_df,
                    (
                        agg_nm,
                        string(gdf[1, "Zone"]),
                        string(gdf[1, "Type"]),
                        grouping_key,
                        length(source_cols),
                        target_col,
                        minimum(source_means),
                        maximum(source_means),
                        source_hourly_min,
                        source_hourly_max,
                        minimum(agg_vals),
                        maximum(agg_vals),
                    ),
                )
            end
        end
    end

    return Dict(
        "mapping" => mapping_df,
        "summary" => summary_df,
        "af_summary" => af_summary_df,
        "mode" => "gtep_existing_generators",
    )
end

function build_pcm_aggregation_audit(
    raw_gendata::DataFrame,
    aggregated_gendata::DataFrame;
    config_set::AbstractDict = Dict{String,Any}(),
)
    order, groups, key_cols, group_labels =
        grouped_row_indices_by_aggregation(raw_gendata, config_set; model_mode = "PCM")
    mapping_df = DataFrame(
        AggregatedResource = String[],
        Zone = String[],
        Type = String[],
        GroupingKey = String[],
        OriginalIndex = Int[],
        OriginalResource = String[],
        OriginalPmaxMW = Float64[],
        WeightPmaxMW = Float64[],
        WeightShare = Float64[],
    )

    summary_rows = Dict{Symbol,Any}[]
    for (new_idx, key) in enumerate(order)
        rows = groups[key]
        gdf = raw_gendata[rows, :]
        weights =
            [max(to_float_agg(gdf[r, Symbol("Pmax (MW)")], 0.0), 0.0) for r = 1:nrow(gdf)]
        shares = normalized_agg_shares(weights)
        agg_nm = "G$(new_idx)"
        grouping_key = get(
            group_labels,
            key,
            join(["$(key_cols[j])=$(key[j])" for j in eachindex(key_cols)], "; "),
        )

        for (local_idx, raw_idx) in enumerate(rows)
            push!(
                mapping_df,
                (
                    agg_nm,
                    string(raw_gendata[raw_idx, "Zone"]),
                    string(raw_gendata[raw_idx, "Type"]),
                    grouping_key,
                    raw_idx,
                    "G$(raw_idx)",
                    to_float_agg(raw_gendata[raw_idx, Symbol("Pmax (MW)")], 0.0),
                    weights[local_idx],
                    shares[local_idx],
                ),
            )
        end

        agg_row = aggregated_gendata[new_idx, :]
        row = Dict{Symbol,Any}(
            :AggregatedResource => agg_nm,
            :Zone => string(gdf[1, "Zone"]),
            :Type => string(gdf[1, "Type"]),
            :GroupingKey => grouping_key,
            :GroupSize => length(rows),
            :OriginalPmaxMW =>
                sum(to_float_agg(v, 0.0) for v in gdf[!, Symbol("Pmax (MW)")]),
            :AggregatedPmaxMW => to_float_agg(agg_row[Symbol("Pmax (MW)")], 0.0),
            :AggregatedPminMW => to_float_agg(agg_row[Symbol("Pmin (MW)")], 0.0),
            :NumUnits =>
                ("NumUnits" in names(aggregated_gendata)) ?
                Int(round(to_float_agg(agg_row[:NumUnits], 1.0))) : 1,
            :ClusteredUnitPmaxMW =>
                ("ClusteredUnitPmax (MW)" in names(aggregated_gendata)) ?
                to_float_agg(agg_row[Symbol("ClusteredUnitPmax (MW)")], 0.0) :
                to_float_agg(agg_row[Symbol("Pmax (MW)")], 0.0),
            :ClusteredUnitPminMW =>
                ("ClusteredUnitPmin (MW)" in names(aggregated_gendata)) ?
                to_float_agg(agg_row[Symbol("ClusteredUnitPmin (MW)")], 0.0) :
                to_float_agg(agg_row[Symbol("Pmin (MW)")], 0.0),
            Symbol("AggregatedCostPerMWh") =>
                to_float_agg(agg_row[Symbol("Cost (\$/MWh)")], 0.0),
            :AggregatedCC => to_float_agg(agg_row[:CC], 0.0),
            :AggregatedFOR => to_float_agg(agg_row[:FOR], 0.0),
            :AggregatedRM_SPIN =>
                ("RM_SPIN" in names(aggregated_gendata)) ?
                to_float_agg(agg_row[:RM_SPIN], 0.0) : 0.0,
            :AggregatedRU =>
                ("RU" in names(aggregated_gendata)) ? to_float_agg(agg_row[:RU], 0.0) : 0.0,
            :AggregatedRD =>
                ("RD" in names(aggregated_gendata)) ? to_float_agg(agg_row[:RD], 0.0) : 0.0,
            :Flag_thermal => Int(to_float_agg(agg_row[:Flag_thermal], 0.0)),
            :Flag_VRE => Int(to_float_agg(agg_row[:Flag_VRE], 0.0)),
            :Flag_mustrun => Int(to_float_agg(agg_row[:Flag_mustrun], 0.0)),
        )
        if "Flag_UC" in names(aggregated_gendata)
            row[:Flag_UC] = Int(to_float_agg(agg_row[:Flag_UC], 0.0))
        end
        if "Start_up_cost (\$/MW)" in names(aggregated_gendata)
            row[Symbol("AggregatedStartUpCostPerMW")] =
                to_float_agg(agg_row[Symbol("Start_up_cost (\$/MW)")], 0.0)
        end
        if "Min_down_time" in names(aggregated_gendata)
            row[:AggregatedMinDownTime] = to_float_agg(agg_row[:Min_down_time], 0.0)
        end
        if "Min_up_time" in names(aggregated_gendata)
            row[:AggregatedMinUpTime] = to_float_agg(agg_row[:Min_up_time], 0.0)
        end
        if "RM_REG_UP" in names(aggregated_gendata)
            row[:AggregatedRM_REG_UP] = to_float_agg(agg_row[:RM_REG_UP], 0.0)
        end
        if "RM_REG_DN" in names(aggregated_gendata)
            row[:AggregatedRM_REG_DN] = to_float_agg(agg_row[:RM_REG_DN], 0.0)
        end
        if "RM_NSPIN" in names(aggregated_gendata)
            row[:AggregatedRM_NSPIN] = to_float_agg(agg_row[:RM_NSPIN], 0.0)
        end
        push!(summary_rows, row)
    end

    return Dict(
        "mapping" => mapping_df,
        "summary" => DataFrame(summary_rows),
        "mode" => "pcm_existing_generators",
    )
end

"""
    load_data(config_set::Dict, path::AbstractString) -> Dict

Load all input data for a HOPE case from the directory `path`.

`config_set` is the parsed `HOPE_model_settings.yml` dictionary. This legacy
table loader handles the `"GTEP"` and `"PCM"` modes, their `DataCase` folders,
and optional preprocessing such as resource aggregation and representative-day
selection. Standard `"DART"` cases use `load_dart_case` instead.

Returns a `Dict` whose keys include `"Gendata"`, `"Loaddata"`, `"Zonedata"`,
`"Linedata"`, and other model-mode-specific tables.
"""
function load_data(config_set::Dict, path::AbstractString)
    Data_case = config_set["DataCase"]
    model_mode = config_set["model_mode"]
    flexible_demand_raw = get(config_set, "flexible_demand", 0)
    flexible_demand =
        flexible_demand_raw isa Integer ? Int(flexible_demand_raw) :
        parse(Int, string(flexible_demand_raw))

    if model_mode == "GTEP"                 #read data for generation and transmission expansion model
        input_data = Dict()
        println("Reading Input_Data Files for GTEP mode")
        #input_data["VOLL"] = config_set["value_of_loss_load"]
        folderpath = joinpath(path, Data_case)
        files = readdir(folderpath)
        if any(endswith.(files, ".xlsx"))
            println(
                "The directory $folderpath contains .xlsx file, then try to read input data from GTEP_input_total.xlsx",
            )
            #xlsx_file = XLSX.readxlsx(path*Data_case*"GTEP_input_total.xlsx")
            xlsx_path = joinpath(folderpath, "GTEP_input_total.xlsx")

            #network
            println("Reading network")
            input_data["Zonedata"] = DataFrame(XLSX.readtable(xlsx_path, "zonedata"))
            input_data["Linedata"] = DataFrame(XLSX.readtable(xlsx_path, "linedata"))
            #technology
            println("Reading technology")
            gendata_raw = DataFrame(XLSX.readtable(xlsx_path, "gendata"))
            input_data["GendataRaw"] = copy(gendata_raw)
            if resource_aggregation_enabled(config_set)
                input_data["Gendata"] = aggregate_gendata_gtep(gendata_raw, config_set)
            else
                input_data["Gendata"] = gendata_raw
            end

            input_data["Storagedata"] = DataFrame(XLSX.readtable(xlsx_path, "storagedata"))
            if flexible_demand == 1
                try
                    input_data["DRdata"] = DataFrame(XLSX.readtable(xlsx_path, "flexddata"))
                catch
                    try
                        # Backward compatibility for older DR workbook templates
                        input_data["DRdata"] = DataFrame(
                            XLSX.readtable(
                                joinpath(folderpath, "flexddata.xlsx"),
                                "flexddata",
                            ),
                        )
                    catch
                        input_data["DRdata"] = DataFrame(
                            XLSX.readtable(
                                joinpath(folderpath, "flexddata.xlsx"),
                                "storagedata",
                            ),
                        )
                    end
                end
            end
            #time series
            println("Reading time series")
            input_data["Loaddata"] =
                DataFrame(XLSX.readtable(xlsx_path, "load_timeseries_regional"))
            normalize_timeseries_time_columns!(
                input_data["Loaddata"];
                context = "load_timeseries_regional",
            )
            input_data["NIdata"] =
                ("NI" in names(input_data["Loaddata"])) ? input_data["Loaddata"][:, "NI"] :
                zeros(nrow(input_data["Loaddata"]))
            if flexible_demand == 1
                input_data["DRtsdata"] =
                    DataFrame(XLSX.readtable(xlsx_path, "dr_timeseries_regional"))
                normalize_timeseries_time_columns!(
                    input_data["DRtsdata"];
                    context = "dr_timeseries_regional",
                )
                validate_aligned_time_columns!(
                    input_data["Loaddata"],
                    input_data["DRtsdata"],
                    "dr_timeseries_regional",
                )
            end
            #candidate
            println("Reading resource candidate")
            input_data["Estoragedata_candidate"] =
                DataFrame(XLSX.readtable(xlsx_path, "Estoragedata_candidate"))
            input_data["Linedata_candidate"] =
                DataFrame(XLSX.readtable(xlsx_path, "linedata_candidate"))
            input_data["Gendata_candidate"] =
                DataFrame(XLSX.readtable(xlsx_path, "gendata_candidate"))
            #policies
            println("Reading polices")
            input_data["CBPdata"] = DataFrame(XLSX.readtable(xlsx_path, "carbonpolicies"))
            #rpspolicydata
            input_data["RPSdata"] = DataFrame(XLSX.readtable(xlsx_path, "rpspolicies"))
            #penalty_cost, investment budgets, planning reserve margins etc. single parameters
            println("Reading single parameters")
            input_data["Singlepar"] =
                DataFrame(XLSX.readtable(xlsx_path, "single_parameter"))
            sheets = XLSX.sheetnames(XLSX.readxlsx(xlsx_path))
            if "gen_availability_timeseries" in sheets
                input_data["AFdata"] =
                    DataFrame(XLSX.readtable(xlsx_path, "gen_availability_timeseries"))
                normalize_timeseries_time_columns!(
                    input_data["AFdata"];
                    context = "gen_availability_timeseries",
                )
                validate_aligned_time_columns!(
                    input_data["Loaddata"],
                    input_data["AFdata"],
                    "gen_availability_timeseries",
                )
                if resource_aggregation_enabled(config_set)
                    raw_afdata = input_data["AFdata"]
                    input_data["AFdata"] = aggregate_afdata_gtep(
                        gendata_raw,
                        input_data["Gendata"],
                        input_data["Gendata_candidate"],
                        raw_afdata,
                        config_set,
                    )
                    input_data["AggregationAudit"] = build_gtep_aggregation_audit(
                        gendata_raw,
                        input_data["Gendata"];
                        config_set = config_set,
                        raw_afdata = raw_afdata,
                        aggregated_afdata = input_data["AFdata"],
                    )
                end
            else
                throw(
                    ArgumentError(
                        "Missing required generator availability timeseries input. Provide sheet 'gen_availability_timeseries' in GTEP_input_total.xlsx.",
                    ),
                )
            end
            if "rep_period_weights" in sheets
                input_data["RepWeightData"] =
                    DataFrame(XLSX.readtable(xlsx_path, "rep_period_weights"))
            end

            println("xlsx Files Successfully Load From $folderpath")

        else
            println(
                "No xlsx file found in the directory $folderpath, try to read data from .csv files",
            )

            #network
            #Zonedata=CSV.read("Data/zonedata.csv",DataFrame)
            println("Reading network")
            input_data["Zonedata"] =
                CSV.read(joinpath(folderpath, "zonedata.csv"), DataFrame) #110% Peak
            input_data["Linedata"] =
                CSV.read(joinpath(folderpath, "linedata.csv"), DataFrame)
            #technology
            println("Reading technology")
            gendata_raw = CSV.read(joinpath(folderpath, "gendata.csv"), DataFrame)
            input_data["GendataRaw"] = copy(gendata_raw)
            if resource_aggregation_enabled(config_set)
                input_data["Gendata"] = aggregate_gendata_gtep(gendata_raw, config_set)
            else
                input_data["Gendata"] = gendata_raw
            end

            input_data["Storagedata"] =
                CSV.read(joinpath(folderpath, "storagedata.csv"), DataFrame)
            if flexible_demand == 1
                input_data["DRdata"] =
                    CSV.read(joinpath(folderpath, "flexddata.csv"), DataFrame)
            end
            #time series
            println("Reading time series")
            input_data["Loaddata"] =
                CSV.read(joinpath(folderpath, "load_timeseries_regional.csv"), DataFrame)
            normalize_timeseries_time_columns!(
                input_data["Loaddata"];
                context = "load_timeseries_regional",
            )
            input_data["NIdata"] =
                ("NI" in names(input_data["Loaddata"])) ? input_data["Loaddata"][:, "NI"] :
                zeros(nrow(input_data["Loaddata"]))
            if flexible_demand == 1
                input_data["DRtsdata"] =
                    CSV.read(joinpath(folderpath, "dr_timeseries_regional.csv"), DataFrame)
                normalize_timeseries_time_columns!(
                    input_data["DRtsdata"];
                    context = "dr_timeseries_regional",
                )
                validate_aligned_time_columns!(
                    input_data["Loaddata"],
                    input_data["DRtsdata"],
                    "dr_timeseries_regional",
                )
            end
            #candidate
            println("Reading resource candidate")
            input_data["Estoragedata_candidate"] =
                CSV.read(joinpath(folderpath, "storagedata_candidate.csv"), DataFrame)
            input_data["Linedata_candidate"] =
                CSV.read(joinpath(folderpath, "linedata_candidate.csv"), DataFrame)
            input_data["Gendata_candidate"] =
                CSV.read(joinpath(folderpath, "gendata_candidate.csv"), DataFrame)
            #policies
            println("Reading polices")
            input_data["CBPdata"] =
                CSV.read(joinpath(folderpath, "carbonpolicies.csv"), DataFrame)
            #rpspolicydata=
            input_data["RPSdata"] =
                CSV.read(joinpath(folderpath, "rpspolicies.csv"), DataFrame)
            #penalty_cost, investment budgets, planning reserve margins etc. single parameters
            println("Reading single parameters")
            input_data["Singlepar"] =
                CSV.read(joinpath(folderpath, "single_parameter.csv"), DataFrame)
            af_csv = joinpath(folderpath, "gen_availability_timeseries.csv")
            if isfile(af_csv)
                input_data["AFdata"] = CSV.read(af_csv, DataFrame)
                normalize_timeseries_time_columns!(
                    input_data["AFdata"];
                    context = "gen_availability_timeseries",
                )
                validate_aligned_time_columns!(
                    input_data["Loaddata"],
                    input_data["AFdata"],
                    "gen_availability_timeseries",
                )
                if resource_aggregation_enabled(config_set)
                    raw_afdata = input_data["AFdata"]
                    input_data["AFdata"] = aggregate_afdata_gtep(
                        gendata_raw,
                        input_data["Gendata"],
                        input_data["Gendata_candidate"],
                        raw_afdata,
                        config_set,
                    )
                    input_data["AggregationAudit"] = build_gtep_aggregation_audit(
                        gendata_raw,
                        input_data["Gendata"];
                        config_set = config_set,
                        raw_afdata = raw_afdata,
                        aggregated_afdata = input_data["AFdata"],
                    )
                end
            else
                throw(
                    ArgumentError(
                        "Missing required generator availability timeseries input. Provide file 'gen_availability_timeseries.csv'.",
                    ),
                )
            end
            rep_weight_csv = joinpath(folderpath, "rep_period_weights.csv")
            if isfile(rep_weight_csv)
                input_data["RepWeightData"] = CSV.read(rep_weight_csv, DataFrame)
            end

            println("CSV Files Successfully Load From $folderpath")
        end



    elseif model_mode == "PCM"          #read data for production cost model
        input_data = Dict()
        println("Reading Input_Data Files for PCM mode")
        folderpath = joinpath(path, Data_case)
        files = readdir(folderpath)
        #input_data["VOLL"] = config_set["value_of_loss_load"]
        if any(endswith.(files, ".xlsx"))
            println(
                "The directory $folderpath contains .xlsx file, then try to read input data from PCM_input_total.xlsx",
            )
            #xlsx_file = XLSX.readxlsx(path*Data_case*"PCM_input_total.xlsx")
            xlsx_path = joinpath(folderpath, "PCM_input_total.xlsx")

            #network
            println("Reading network")
            input_data["Zonedata"] = DataFrame(XLSX.readtable(xlsx_path, "zonedata"))
            input_data["Linedata"] = DataFrame(XLSX.readtable(xlsx_path, "linedata"))
            try
                input_data["Busdata"] = DataFrame(XLSX.readtable(xlsx_path, "busdata"))
                println("Reading optional busdata")
            catch
                # Optional sheet: busdata
            end
            try
                input_data["Branchdata"] =
                    DataFrame(XLSX.readtable(xlsx_path, "branchdata"))
                println("Reading optional branchdata")
            catch
                # Optional sheet: branchdata
            end
            try
                input_data["PTDFdata"] = DataFrame(XLSX.readtable(xlsx_path, "ptdf_matrix"))
                println("Reading optional ptdf_matrix")
            catch
                # Optional sheet: ptdf_matrix
            end
            try
                input_data["PTDFNodalData"] =
                    DataFrame(XLSX.readtable(xlsx_path, "ptdf_matrix_nodal"))
                println("Reading optional ptdf_matrix_nodal")
            catch
                # Optional sheet: ptdf_matrix_nodal
            end
            #technology
            println("Reading technology")
            gendata_raw = DataFrame(XLSX.readtable(xlsx_path, "gendata"))
            input_data["GendataRaw"] = copy(gendata_raw)
            if resource_aggregation_enabled(config_set)
                input_data["Gendata"] = aggregate_gendata_pcm(gendata_raw, config_set)
                input_data["AggregationAudit"] = build_pcm_aggregation_audit(
                    gendata_raw,
                    input_data["Gendata"];
                    config_set = config_set,
                )
            else
                input_data["Gendata"] = gendata_raw
            end

            input_data["Storagedata"] = DataFrame(XLSX.readtable(xlsx_path, "storagedata"))
            if flexible_demand == 1
                input_data["DRdata"] = DataFrame(XLSX.readtable(xlsx_path, "flexddata"))
            end

            #time series
            println("Reading time series")
            input_data["Winddata"] =
                DataFrame(XLSX.readtable(xlsx_path, "wind_timeseries_regional"))
            input_data["Solardata"] =
                DataFrame(XLSX.readtable(xlsx_path, "solar_timeseries_regional"))
            input_data["Loaddata"] =
                DataFrame(XLSX.readtable(xlsx_path, "load_timeseries_regional"))
            normalize_timeseries_time_columns!(
                input_data["Loaddata"];
                context = "load_timeseries_regional",
            )
            normalize_timeseries_time_columns!(
                input_data["Winddata"];
                context = "wind_timeseries_regional",
            )
            normalize_timeseries_time_columns!(
                input_data["Solardata"];
                context = "solar_timeseries_regional",
            )
            validate_aligned_time_columns!(
                input_data["Loaddata"],
                input_data["Winddata"],
                "wind_timeseries_regional",
            )
            validate_aligned_time_columns!(
                input_data["Loaddata"],
                input_data["Solardata"],
                "solar_timeseries_regional",
            )
            try
                input_data["NodalLoaddata"] =
                    DataFrame(XLSX.readtable(xlsx_path, "load_timeseries_nodal"))
                normalize_timeseries_time_columns!(
                    input_data["NodalLoaddata"];
                    context = "load_timeseries_nodal",
                )
                validate_aligned_time_columns!(
                    input_data["Loaddata"],
                    input_data["NodalLoaddata"],
                    "load_timeseries_nodal",
                )
                println("Reading optional load_timeseries_nodal")
            catch
                # Optional sheet: load_timeseries_nodal
            end
            try
                input_data["NodalNIdata"] =
                    DataFrame(XLSX.readtable(xlsx_path, "ni_timeseries_nodal"))
                normalize_timeseries_time_columns!(
                    input_data["NodalNIdata"];
                    context = "ni_timeseries_nodal",
                )
                validate_aligned_time_columns!(
                    input_data["Loaddata"],
                    input_data["NodalNIdata"],
                    "ni_timeseries_nodal",
                )
                println("Reading optional ni_timeseries_nodal")
            catch
                # Optional sheet: ni_timeseries_nodal
            end
            try
                input_data["NodalNITargetdata"] =
                    DataFrame(XLSX.readtable(xlsx_path, "ni_timeseries_nodal_target"))
                normalize_timeseries_time_columns!(
                    input_data["NodalNITargetdata"];
                    context = "ni_timeseries_nodal_target",
                )
                validate_aligned_time_columns!(
                    input_data["Loaddata"],
                    input_data["NodalNITargetdata"],
                    "ni_timeseries_nodal_target",
                )
                println("Reading optional ni_timeseries_nodal_target")
            catch
                # Optional sheet: ni_timeseries_nodal_target
            end
            try
                input_data["NodalNICapdata"] =
                    DataFrame(XLSX.readtable(xlsx_path, "ni_timeseries_nodal_cap"))
                normalize_timeseries_time_columns!(
                    input_data["NodalNICapdata"];
                    context = "ni_timeseries_nodal_cap",
                )
                validate_aligned_time_columns!(
                    input_data["Loaddata"],
                    input_data["NodalNICapdata"],
                    "ni_timeseries_nodal_cap",
                )
                println("Reading optional ni_timeseries_nodal_cap")
            catch
                # Optional sheet: ni_timeseries_nodal_cap
            end
            try
                input_data["AFdata"] =
                    DataFrame(XLSX.readtable(xlsx_path, "gen_availability_timeseries"))
                normalize_timeseries_time_columns!(
                    input_data["AFdata"];
                    context = "gen_availability_timeseries",
                )
                validate_aligned_time_columns!(
                    input_data["Loaddata"],
                    input_data["AFdata"],
                    "gen_availability_timeseries",
                )
                println("Reading optional gen_availability_timeseries")
            catch
                # Optional sheet: gen_availability_timeseries
            end
            input_data["NIdata"] =
                ("NI" in names(input_data["Loaddata"])) ? input_data["Loaddata"][:, "NI"] :
                zeros(nrow(input_data["Loaddata"]))
            if flexible_demand == 1
                input_data["DRtsdata"] =
                    DataFrame(XLSX.readtable(xlsx_path, "dr_timeseries_regional"))
                normalize_timeseries_time_columns!(
                    input_data["DRtsdata"];
                    context = "dr_timeseries_regional",
                )
                validate_aligned_time_columns!(
                    input_data["Loaddata"],
                    input_data["DRtsdata"],
                    "dr_timeseries_regional",
                )
            end
            #policies
            println("Reading polices")
            input_data["CBPdata"] = DataFrame(XLSX.readtable(xlsx_path, "carbonpolicies"))
            #rpspolicydata=
            input_data["RPSdata"] = DataFrame(XLSX.readtable(xlsx_path, "rpspolicies"))
            #penalty_cost, investment budgets, planning reserve margins etc. single parameters
            println("Reading single parameters")
            input_data["Singlepar"] =
                DataFrame(XLSX.readtable(xlsx_path, "single_parameter"))
            sheets = XLSX.sheetnames(XLSX.readxlsx(xlsx_path))
            if "rep_period_weights" in sheets
                input_data["RepWeightData"] =
                    DataFrame(XLSX.readtable(xlsx_path, "rep_period_weights"))
            end

            println("xlsx Files Successfully Load From $folderpath")

        else
            println(
                "No xlsx file found in the directory $folderpath, try to read data from .csv files",
            )

            println("Reading network")
            input_data["Zonedata"] =
                CSV.read(joinpath(folderpath, "zonedata.csv"), DataFrame)
            input_data["Linedata"] =
                CSV.read(joinpath(folderpath, "linedata.csv"), DataFrame)
            bus_csv_path = joinpath(folderpath, "busdata.csv")
            if isfile(bus_csv_path)
                input_data["Busdata"] = CSV.read(bus_csv_path, DataFrame)
                println("Reading optional busdata.csv")
            end
            branch_csv_path = joinpath(folderpath, "branchdata.csv")
            if isfile(branch_csv_path)
                input_data["Branchdata"] = CSV.read(branch_csv_path, DataFrame)
                println("Reading optional branchdata.csv")
            end
            ptdf_csv_path = joinpath(folderpath, "ptdf_matrix.csv")
            if isfile(ptdf_csv_path)
                input_data["PTDFdata"] = CSV.read(ptdf_csv_path, DataFrame)
                println("Reading optional ptdf_matrix.csv")
            end
            ptdf_nodal_csv_path = joinpath(folderpath, "ptdf_matrix_nodal.csv")
            if isfile(ptdf_nodal_csv_path)
                input_data["PTDFNodalData"] = CSV.read(ptdf_nodal_csv_path, DataFrame)
                println("Reading optional ptdf_matrix_nodal.csv")
            end
            #technology
            println("Reading technology")
            gendata_raw = CSV.read(joinpath(folderpath, "gendata.csv"), DataFrame)
            input_data["GendataRaw"] = copy(gendata_raw)
            if resource_aggregation_enabled(config_set)
                input_data["Gendata"] = aggregate_gendata_pcm(gendata_raw, config_set)
                input_data["AggregationAudit"] = build_pcm_aggregation_audit(
                    gendata_raw,
                    input_data["Gendata"];
                    config_set = config_set,
                )
            else
                input_data["Gendata"] = gendata_raw
            end

            input_data["Storagedata"] =
                CSV.read(joinpath(folderpath, "storagedata.csv"), DataFrame)
            if flexible_demand == 1
                input_data["DRdata"] =
                    CSV.read(joinpath(folderpath, "flexddata.csv"), DataFrame)
            end

            #time series
            println("Reading time series")
            input_data["Winddata"] =
                CSV.read(joinpath(folderpath, "wind_timeseries_regional.csv"), DataFrame)
            input_data["Solardata"] =
                CSV.read(joinpath(folderpath, "solar_timeseries_regional.csv"), DataFrame)
            input_data["Loaddata"] =
                CSV.read(joinpath(folderpath, "load_timeseries_regional.csv"), DataFrame)
            normalize_timeseries_time_columns!(
                input_data["Loaddata"];
                context = "load_timeseries_regional",
            )
            normalize_timeseries_time_columns!(
                input_data["Winddata"];
                context = "wind_timeseries_regional",
            )
            normalize_timeseries_time_columns!(
                input_data["Solardata"];
                context = "solar_timeseries_regional",
            )
            validate_aligned_time_columns!(
                input_data["Loaddata"],
                input_data["Winddata"],
                "wind_timeseries_regional",
            )
            validate_aligned_time_columns!(
                input_data["Loaddata"],
                input_data["Solardata"],
                "solar_timeseries_regional",
            )
            nodal_load_csv_path = joinpath(folderpath, "load_timeseries_nodal.csv")
            if isfile(nodal_load_csv_path)
                input_data["NodalLoaddata"] = CSV.read(nodal_load_csv_path, DataFrame)
                normalize_timeseries_time_columns!(
                    input_data["NodalLoaddata"];
                    context = "load_timeseries_nodal",
                )
                validate_aligned_time_columns!(
                    input_data["Loaddata"],
                    input_data["NodalLoaddata"],
                    "load_timeseries_nodal",
                )
                println("Reading optional load_timeseries_nodal.csv")
            end
            nodal_ni_csv_path = joinpath(folderpath, "ni_timeseries_nodal.csv")
            if isfile(nodal_ni_csv_path)
                input_data["NodalNIdata"] = CSV.read(nodal_ni_csv_path, DataFrame)
                normalize_timeseries_time_columns!(
                    input_data["NodalNIdata"];
                    context = "ni_timeseries_nodal",
                )
                validate_aligned_time_columns!(
                    input_data["Loaddata"],
                    input_data["NodalNIdata"],
                    "ni_timeseries_nodal",
                )
                println("Reading optional ni_timeseries_nodal.csv")
            end
            nodal_ni_target_csv_path =
                joinpath(folderpath, "ni_timeseries_nodal_target.csv")
            if isfile(nodal_ni_target_csv_path)
                input_data["NodalNITargetdata"] =
                    CSV.read(nodal_ni_target_csv_path, DataFrame)
                normalize_timeseries_time_columns!(
                    input_data["NodalNITargetdata"];
                    context = "ni_timeseries_nodal_target",
                )
                validate_aligned_time_columns!(
                    input_data["Loaddata"],
                    input_data["NodalNITargetdata"],
                    "ni_timeseries_nodal_target",
                )
                println("Reading optional ni_timeseries_nodal_target.csv")
            end
            nodal_ni_cap_csv_path = joinpath(folderpath, "ni_timeseries_nodal_cap.csv")
            if isfile(nodal_ni_cap_csv_path)
                input_data["NodalNICapdata"] = CSV.read(nodal_ni_cap_csv_path, DataFrame)
                normalize_timeseries_time_columns!(
                    input_data["NodalNICapdata"];
                    context = "ni_timeseries_nodal_cap",
                )
                validate_aligned_time_columns!(
                    input_data["Loaddata"],
                    input_data["NodalNICapdata"],
                    "ni_timeseries_nodal_cap",
                )
                println("Reading optional ni_timeseries_nodal_cap.csv")
            end
            af_csv_path = joinpath(folderpath, "gen_availability_timeseries.csv")
            if isfile(af_csv_path)
                input_data["AFdata"] = CSV.read(af_csv_path, DataFrame)
                normalize_timeseries_time_columns!(
                    input_data["AFdata"];
                    context = "gen_availability_timeseries",
                )
                validate_aligned_time_columns!(
                    input_data["Loaddata"],
                    input_data["AFdata"],
                    "gen_availability_timeseries",
                )
                println("Reading optional gen_availability_timeseries.csv")
            end
            input_data["NIdata"] =
                ("NI" in names(input_data["Loaddata"])) ? input_data["Loaddata"][:, "NI"] :
                zeros(nrow(input_data["Loaddata"]))
            if flexible_demand == 1
                input_data["DRtsdata"] =
                    CSV.read(joinpath(folderpath, "dr_timeseries_regional.csv"), DataFrame)
                normalize_timeseries_time_columns!(
                    input_data["DRtsdata"];
                    context = "dr_timeseries_regional",
                )
                validate_aligned_time_columns!(
                    input_data["Loaddata"],
                    input_data["DRtsdata"],
                    "dr_timeseries_regional",
                )
            end
            #policies
            println("Reading policies")
            input_data["CBPdata"] =
                CSV.read(joinpath(folderpath, "carbonpolicies.csv"), DataFrame)
            #rpspolicydata=
            input_data["RPSdata"] =
                CSV.read(joinpath(folderpath, "rpspolicies.csv"), DataFrame)
            #penalty_cost, investment budgets, planning reserve margins etc. single parameters
            println("Reading single parameters")
            input_data["Singlepar"] =
                CSV.read(joinpath(folderpath, "single_parameter.csv"), DataFrame)
            rep_weight_csv = joinpath(folderpath, "rep_period_weights.csv")
            if isfile(rep_weight_csv)
                input_data["RepWeightData"] = CSV.read(rep_weight_csv, DataFrame)
            end

            println("CSV Files Successfully Load From $folderpath")
        end
    end
    if model_mode == "PCM"
        operational_template_path =
            joinpath(folderpath, HOLISTIC_OPERATIONAL_TEMPLATE_FILENAME)
        if isfile(operational_template_path)
            input_data["OperationalResourceTemplates"] =
                validate_operational_resource_templates(
                    CSV.read(operational_template_path, DataFrame),
                )
            println("Reading optional operational_resource_templates.csv")
        end
    end
    if haskey(input_data, "Linedata")
        parse_directional_line_limits(input_data["Linedata"]; context = "linedata")
    end
    if haskey(input_data, "Linedata_candidate")
        parse_directional_line_limits(
            input_data["Linedata_candidate"];
            context = "linedata_candidate",
        )
    end
    if haskey(input_data, "Branchdata")
        parse_directional_line_limits(input_data["Branchdata"]; context = "branchdata")
    end

    return input_data
end
