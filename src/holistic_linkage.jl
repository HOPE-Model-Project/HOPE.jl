"""Backward-compatible, auditable GTEP-to-PCM realization utilities."""

const HOLISTIC_ASSET_ID = "Asset_ID"
const HOLISTIC_CANDIDATE_ID = "Candidate_ID"
const HOLISTIC_CORRIDOR_ID = "Corridor_ID"

function _holistic_empty_retirement_audit()
    return DataFrame(
        Layer = String[],
        AssetID = String[],
        GTEPRows = String[],
        PCMRows = String[],
        Zone = String[],
        Type = String[],
        MappingMode = String[],
        InitialMW = Float64[],
        RetiredMW = Float64[],
        FinalMW = Float64[],
        RetentionFactor = Float64[],
    )
end

function _holistic_empty_generation_build_audit()
    return DataFrame(
        CandidateRow = Int[],
        CandidateID = String[],
        RealizedAssetID = String[],
        Zone = String[],
        Type = String[],
        CandidateMW = Float64[],
        BuiltMW = Float64[],
        OperationalTemplateID = String[],
        ParameterSource = String[],
    )
end

function _holistic_empty_storage_build_audit()
    return DataFrame(
        CandidateRow = Int[],
        CandidateID = String[],
        RealizedAssetID = String[],
        Zone = String[],
        Type = String[],
        CandidatePowerMW = Float64[],
        BuiltPowerMW = Float64[],
        CandidateEnergyMWh = Float64[],
        BuiltEnergyMWh = Float64[],
        OperationalTemplateID = String[],
        ParameterSource = String[],
    )
end

function _holistic_empty_line_audit()
    return DataFrame(
        CandidateRow = Int[],
        CorridorID = String[],
        FromZone = String[],
        ToZone = String[],
        TargetRow = Int[],
        TargetCorridorID = String[],
        MappingMode = String[],
        ForwardAddedMW = Float64[],
        ReverseAddedMW = Float64[],
    )
end

_holistic_has_column(df::AbstractDataFrame, name::AbstractString) = name in names(df)

function _holistic_text(value, default = "")
    if ismissing(value) || value === nothing
        return default
    end
    text = strip(string(value))
    return isempty(text) ? default : text
end

function _holistic_id(df::AbstractDataFrame, row::Int, column::AbstractString, fallback)
    _holistic_has_column(df, column) || return fallback
    return _holistic_text(df[row, column], fallback)
end

function _holistic_assert_unique_ids(df::AbstractDataFrame, column::AbstractString, label)
    _holistic_has_column(df, column) || return nothing
    ids = [_holistic_text(v) for v in df[!, column]]
    any(isempty, ids) &&
        throw(ArgumentError("$(label).$(column) must not contain blank values."))
    length(unique(ids)) == length(ids) ||
        throw(ArgumentError("$(label).$(column) must contain unique values."))
    return nothing
end

function _holistic_generator_signature(df::AbstractDataFrame, row::Int)
    cols = (
        "Zone",
        "Type",
        "Flag_RET",
        "Flag_mustrun",
        "Flag_VRE",
        "Flag_thermal",
    )
    values = String[]
    for col in cols
        if _holistic_has_column(df, col)
            value = col == "Type" ? replace(string(df[row, col]), "_CCS" => "") :
                    string(df[row, col])
            push!(values, strip(value))
        end
    end
    return Tuple(values)
end

function _holistic_rows_are_aligned(
    source::AbstractDataFrame,
    target::AbstractDataFrame;
    atol::Float64 = 1e-6,
)
    nrow(source) == nrow(target) || return false
    for row = 1:nrow(source)
        _holistic_generator_signature(source, row) ==
            _holistic_generator_signature(target, row) || return false
        source_pmax = to_float_output(source[row, Symbol("Pmax (MW)")], 0.0)
        target_pmax = to_float_output(target[row, Symbol("Pmax (MW)")], 0.0)
        isapprox(source_pmax, target_pmax; atol = atol, rtol = 1e-8) || return false
    end
    return true
end

function _holistic_retention_factors(
    capacity_df::DataFrame,
    gtep_gendata::DataFrame;
    atol::Float64 = 1e-7,
)
    required = ["EC_Category", "Capacity_INI (MW)", "Capacity_RET (MW)", "Capacity_FIN (MW)"]
    missing = setdiff(required, names(capacity_df))
    isempty(missing) || throw(
        ArgumentError(
            "GTEP capacity output is missing retirement columns: $(join(missing, ", ")).",
        ),
    )
    existing = capacity_df[string.(capacity_df[!, "EC_Category"]) .== "Existing", :]
    nrow(existing) == nrow(gtep_gendata) || throw(
        ArgumentError(
            "GTEP capacity output has $(nrow(existing)) existing rows, but the solved GTEP table has $(nrow(gtep_gendata)).",
        ),
    )
    factors = ones(Float64, nrow(existing))
    for row = 1:nrow(existing)
        initial = to_float_output(existing[row, Symbol("Capacity_INI (MW)")], 0.0)
        retired = to_float_output(existing[row, Symbol("Capacity_RET (MW)")], 0.0)
        final = to_float_output(existing[row, Symbol("Capacity_FIN (MW)")], initial - retired)
        initial >= -atol || throw(ArgumentError("GTEP initial capacity cannot be negative."))
        retired >= -atol || throw(ArgumentError("GTEP retired capacity cannot be negative."))
        final >= -atol || throw(ArgumentError("GTEP final capacity cannot be negative."))
        if initial <= atol
            abs(retired) <= atol && abs(final) <= atol || throw(
                ArgumentError("A zero-capacity GTEP resource has a nonzero retirement decision."),
            )
            factors[row] = 1.0
        else
            isapprox(final, initial - retired; atol = 1e-5, rtol = 1e-7) || throw(
                ArgumentError(
                    "GTEP retirement output is inconsistent at existing row $(row): initial=$(initial), retired=$(retired), final=$(final).",
                ),
            )
            factor = final / initial
            -atol <= factor <= 1.0 + atol || throw(
                ArgumentError("GTEP retention factor must lie in [0, 1]."),
            )
            factors[row] = clamp(factor, 0.0, 1.0)
        end
    end
    return factors
end

function _holistic_scale_generator_rows!(
    table::DataFrame,
    rows::Vector{Int},
    factor::Float64,
)
    for column in ("Pmax (MW)", "Pmin (MW)")
        _holistic_has_column(table, column) || continue
        table[!, column] = Float64[to_float_output(v, 0.0) for v in table[!, column]]
        for row in rows
            table[row, column] = max(table[row, column] * factor, 0.0)
        end
    end
    return table
end

function _holistic_apply_retention_factors!(
    target::DataFrame,
    source::DataFrame,
    factors::Vector{Float64};
    layer::AbstractString,
    atol::Float64 = 1e-7,
)
    length(factors) == nrow(source) ||
        throw(ArgumentError("Retirement factors do not align with the GTEP source table."))
    audit = _holistic_empty_retirement_audit()
    all(isapprox(f, 1.0; atol = atol) for f in factors) && return audit

    source_has_ids = _holistic_has_column(source, HOLISTIC_ASSET_ID)
    target_has_ids = _holistic_has_column(target, HOLISTIC_ASSET_ID)
    if source_has_ids != target_has_ids
        throw(
            ArgumentError(
                "Retirement mapping found Asset_ID on only one side of the GTEP/PCM handoff. Add Asset_ID to both tables or neither table.",
            ),
        )
    end

    if source_has_ids
        _holistic_assert_unique_ids(source, HOLISTIC_ASSET_ID, "GTEP $(layer)")
        _holistic_assert_unique_ids(target, HOLISTIC_ASSET_ID, "PCM $(layer)")
        target_index = Dict(string(target[i, HOLISTIC_ASSET_ID]) => i for i = 1:nrow(target))
        for source_row = 1:nrow(source)
            factor = factors[source_row]
            isapprox(factor, 1.0; atol = atol) && continue
            asset_id = string(source[source_row, HOLISTIC_ASSET_ID])
            haskey(target_index, asset_id) || throw(
                ArgumentError("PCM is missing Asset_ID $(asset_id) required by GTEP retirement."),
            )
            target_row = target_index[asset_id]
            initial = to_float_output(target[target_row, Symbol("Pmax (MW)")], 0.0)
            _holistic_scale_generator_rows!(target, [target_row], factor)
            push!(
                audit,
                (
                    String(layer),
                    asset_id,
                    string(source_row),
                    string(target_row),
                    string(source[source_row, "Zone"]),
                    string(source[source_row, "Type"]),
                    "asset_id",
                    initial,
                    initial * (1.0 - factor),
                    initial * factor,
                    factor,
                ),
            )
        end
        return audit
    end

    if _holistic_rows_are_aligned(source, target)
        for row = 1:nrow(source)
            factor = factors[row]
            isapprox(factor, 1.0; atol = atol) && continue
            initial = to_float_output(target[row, Symbol("Pmax (MW)")], 0.0)
            _holistic_scale_generator_rows!(target, [row], factor)
            push!(
                audit,
                (
                    String(layer),
                    "legacy-row-$(row)",
                    string(row),
                    string(row),
                    string(source[row, "Zone"]),
                    string(source[row, "Type"]),
                    "validated_row",
                    initial,
                    initial * (1.0 - factor),
                    initial * factor,
                    factor,
                ),
            )
        end
        return audit
    end

    source_groups = Dict{Tuple,Vector{Int}}()
    for row = 1:nrow(source)
        push!(get!(source_groups, _holistic_generator_signature(source, row), Int[]), row)
    end
    target_groups = Dict{Tuple,Vector{Int}}()
    for row = 1:nrow(target)
        push!(get!(target_groups, _holistic_generator_signature(target, row), Int[]), row)
    end
    for (signature, source_rows) in source_groups
        changed = [row for row in source_rows if !isapprox(factors[row], 1.0; atol = atol)]
        isempty(changed) && continue
        group_factors = unique([round(factors[row]; digits = 10) for row in source_rows])
        length(group_factors) == 1 || throw(
            ArgumentError(
                "Legacy aggregate retirement is ambiguous for GTEP rows $(source_rows). Add Asset_ID or use compatible aggregation mappings.",
            ),
        )
        haskey(target_groups, signature) || throw(
            ArgumentError(
                "No PCM resource group matches retiring GTEP rows $(source_rows). Add Asset_ID or harmonize the paired cases.",
            ),
        )
        target_rows = target_groups[signature]
        source_initial = sum(
            to_float_output(source[row, Symbol("Pmax (MW)")], 0.0) for row in source_rows
        )
        target_initial = sum(
            to_float_output(target[row, Symbol("Pmax (MW)")], 0.0) for row in target_rows
        )
        isapprox(source_initial, target_initial; atol = 1e-5, rtol = 1e-7) || throw(
            ArgumentError(
                "GTEP and PCM capacities differ for a retiring aggregate group: GTEP=$(source_initial) MW, PCM=$(target_initial) MW. Add Asset_ID or a mapping file.",
            ),
        )
        factor = factors[first(source_rows)]
        _holistic_scale_generator_rows!(target, target_rows, factor)
        first_source = first(source_rows)
        push!(
            audit,
            (
                String(layer),
                "",
                join(source_rows, ";"),
                join(target_rows, ";"),
                string(source[first_source, "Zone"]),
                string(source[first_source, "Type"]),
                "aggregate_signature",
                target_initial,
                target_initial * (1.0 - factor),
                target_initial * factor,
                factor,
            ),
        )
    end
    return audit
end

function _holistic_raw_retention_factors(
    gtep_input::Dict,
    gtep_config::Dict,
    model_factors::Vector{Float64},
)
    model_table = gtep_input["Gendata"]
    raw_table = get(gtep_input, "GendataRaw", model_table)
    if nrow(raw_table) == nrow(model_table) &&
       _holistic_rows_are_aligned(raw_table, model_table)
        return copy(model_factors)
    end
    resource_aggregation_enabled(gtep_config) || throw(
        ArgumentError(
            "GTEP raw and model generator tables differ without resource aggregation enabled.",
        ),
    )
    order, groups, _, _ =
        grouped_row_indices_by_aggregation(raw_table, gtep_config; model_mode = "GTEP")
    length(order) == length(model_factors) || throw(
        ArgumentError("GTEP aggregation mapping does not align with retirement output."),
    )
    raw_factors = ones(Float64, nrow(raw_table))
    for (aggregate_row, key) in enumerate(order)
        raw_factors[groups[key]] .= model_factors[aggregate_row]
    end
    return raw_factors
end

function apply_gtep_retirements!(
    updated_pcm_input::Dict,
    gtep_output::Dict,
    gtep_input::Dict,
    gtep_config::Dict,
)
    capacity_df = gtep_output["capacity"]
    model_factors =
        _holistic_retention_factors(capacity_df, gtep_input["Gendata"])
    model_audit = _holistic_apply_retention_factors!(
        updated_pcm_input["Gendata"],
        gtep_input["Gendata"],
        model_factors;
        layer = "model",
    )

    if haskey(updated_pcm_input, "GendataRaw")
        gtep_raw = get(gtep_input, "GendataRaw", gtep_input["Gendata"])
        raw_factors = _holistic_raw_retention_factors(gtep_input, gtep_config, model_factors)
        raw_audit = _holistic_apply_retention_factors!(
            updated_pcm_input["GendataRaw"],
            gtep_raw,
            raw_factors;
            layer = "raw",
        )
        return vcat(model_audit, raw_audit; cols = :union)
    end
    return model_audit
end

const HOLISTIC_GENERATOR_TRANSFER_COLUMNS = Set([
    "Zone",
    "Type",
    "Pmax (MW)",
    "Pmin (MW)",
    "Cost (\$/MWh)",
    "EF",
    "CC",
    "AF",
    "FOR",
    "RM_SPIN",
    "RM_REG_UP",
    "RM_REG_DN",
    "RM_NSPIN",
    "RU",
    "RD",
    "Flag_thermal",
    "Flag_VRE",
    "Flag_mustrun",
    "Flag_UC",
    "Min_down_time",
    "Min_up_time",
    "Start_up_cost (\$/MW)",
    "Bus_id",
    HOLISTIC_ASSET_ID,
    HOLISTIC_CANDIDATE_ID,
    "Operational_Template_ID",
    "no_load_cost_per_hour",
    "shutdown_cost",
    "startup_limit_fraction",
    "shutdown_limit_fraction",
    "quick_start_eligible",
    "quick_start_time_minutes",
    "nspin_capability_mw",
    "reg_up_offer_per_mw_hour",
    "reg_down_offer_per_mw_hour",
    "spin_offer_per_mw_hour",
    "nspin_offer_per_mw_hour",
])

const HOLISTIC_STORAGE_TRANSFER_COLUMNS = Set([
    "Zone",
    "Type",
    "Capacity (MWh)",
    "Max Power (MW)",
    "Charging efficiency",
    "Discharging efficiency",
    "Cost (\$/MWh)",
    "EF",
    "CC",
    "Charging Rate",
    "Discharging Rate",
    "Bus_id",
    HOLISTIC_ASSET_ID,
    HOLISTIC_CANDIDATE_ID,
    "Operational_Template_ID",
    "reg_up_capability_mw",
    "reg_down_capability_mw",
    "spin_capability_mw",
    "nspin_capability_mw",
    "reg_up_offer_per_mw_hour",
    "reg_down_offer_per_mw_hour",
    "spin_offer_per_mw_hour",
    "nspin_offer_per_mw_hour",
])

function _holistic_candidate_output_rows(output::DataFrame, expected::Int, label)
    rows = if _holistic_has_column(output, "EC_Category")
        output[string.(output[!, "EC_Category"]) .== "Candidate", :]
    elseif nrow(output) == expected
        # Transmission output has historically contained candidate rows only.
        # Accept that legacy shape so existing cases need no schema update.
        output
    else
        throw(ArgumentError("$(label) output is missing EC_Category and cannot be aligned by row count."))
    end
    nrow(rows) == expected || throw(
        ArgumentError(
            "$(label) output has $(nrow(rows)) candidate rows, but its input has $(expected).",
        ),
    )
    return rows
end

function realize_generation_builds(
    capacity_df::DataFrame,
    candidates::DataFrame,
    pcm_gendata::DataFrame,
)
    output_rows = _holistic_candidate_output_rows(capacity_df, nrow(candidates), "Generation")
    built_indices = [
        row for row = 1:nrow(candidates) if
        to_float_output(output_rows[row, "New_Build"], 0.0) > 0.0 &&
        to_float_output(output_rows[row, Symbol("Capacity_FIN (MW)")], 0.0) > 0.0
    ]
    isempty(built_indices) && return (
        DataFrame(
            :Zone => String[],
            :Type => String[],
            Symbol("Pmax (MW)") => Float64[],
        ),
        _holistic_empty_generation_build_audit(),
    )

    keep = [
        col for col in names(candidates) if
        col in names(pcm_gendata) || col in HOLISTIC_GENERATOR_TRANSFER_COLUMNS
    ]
    for required in ("Zone", "Type", "Pmax (MW)")
        required in keep || push!(keep, required)
    end
    rows = copy(candidates[built_indices, keep])
    rows[!, Symbol("Pmax (MW)")] = Float64[
        to_float_output(output_rows[index, Symbol("Capacity_FIN (MW)")], 0.0) for
        index in built_indices
    ]
    if _holistic_has_column(rows, "Pmin (MW)")
        rows[!, Symbol("Pmin (MW)")] = Float64[
            let original = to_float_output(candidates[index, Symbol("Pmax (MW)")], 0.0),
                realized = to_float_output(output_rows[index, Symbol("Capacity_FIN (MW)")], 0.0)
                ratio = original > 0.0 ? realized / original : 0.0
                to_float_output(candidates[index, Symbol("Pmin (MW)")], 0.0) * ratio
            end for index in built_indices
        ]
    end

    if !_holistic_has_column(rows, HOLISTIC_ASSET_ID) &&
       (_holistic_has_column(rows, HOLISTIC_CANDIDATE_ID) ||
        _holistic_has_column(pcm_gendata, HOLISTIC_ASSET_ID))
        rows[!, HOLISTIC_ASSET_ID] = [
            _holistic_has_column(candidates, HOLISTIC_CANDIDATE_ID) ?
            string(candidates[index, HOLISTIC_CANDIDATE_ID], "__UNIT_001") :
            "GTEP_GEN_CANDIDATE_$(index)__UNIT_001" for index in built_indices
        ]
    end

    audit = _holistic_empty_generation_build_audit()
    for (local_row, candidate_row) in enumerate(built_indices)
        candidate_id = _holistic_id(
            candidates,
            candidate_row,
            HOLISTIC_CANDIDATE_ID,
            "legacy-candidate-row-$(candidate_row)",
        )
        asset_id = _holistic_id(rows, local_row, HOLISTIC_ASSET_ID, "")
        template_id =
            _holistic_id(candidates, candidate_row, "Operational_Template_ID", "")
        push!(
            audit,
            (
                candidate_row,
                candidate_id,
                asset_id,
                string(candidates[candidate_row, "Zone"]),
                string(candidates[candidate_row, "Type"]),
                to_float_output(candidates[candidate_row, Symbol("Pmax (MW)")], 0.0),
                to_float_output(output_rows[candidate_row, Symbol("Capacity_FIN (MW)")], 0.0),
                template_id,
                "candidate_then_pcm_fallback",
            ),
        )
    end
    return rows, audit
end

function realize_storage_builds(
    es_capacity_df::DataFrame,
    candidates::DataFrame,
    pcm_storage::DataFrame,
)
    output_rows = _holistic_candidate_output_rows(es_capacity_df, nrow(candidates), "Storage")
    built_indices = [
        row for row = 1:nrow(candidates) if
        to_float_output(output_rows[row, "New_Build"], 0.0) > 0.0 &&
        to_float_output(output_rows[row, Symbol("Capacity (MW)")], 0.0) > 0.0
    ]
    isempty(built_indices) && return (
        DataFrame(
            :Zone => String[],
            :Type => String[],
            Symbol("Capacity (MWh)") => Float64[],
            Symbol("Max Power (MW)") => Float64[],
        ),
        _holistic_empty_storage_build_audit(),
    )

    keep = [
        col for col in names(candidates) if
        col in names(pcm_storage) || col in HOLISTIC_STORAGE_TRANSFER_COLUMNS
    ]
    for required in ("Zone", "Type", "Capacity (MWh)", "Max Power (MW)")
        required in keep || push!(keep, required)
    end
    rows = copy(candidates[built_indices, keep])
    rows[!, Symbol("Capacity (MWh)")] = Float64[
        to_float_output(output_rows[index, Symbol("EnergyCapacity (MWh)")], 0.0) for
        index in built_indices
    ]
    rows[!, Symbol("Max Power (MW)")] = Float64[
        to_float_output(output_rows[index, Symbol("Capacity (MW)")], 0.0) for
        index in built_indices
    ]
    if !_holistic_has_column(rows, HOLISTIC_ASSET_ID) &&
       (_holistic_has_column(rows, HOLISTIC_CANDIDATE_ID) ||
        _holistic_has_column(pcm_storage, HOLISTIC_ASSET_ID))
        rows[!, HOLISTIC_ASSET_ID] = [
            _holistic_has_column(candidates, HOLISTIC_CANDIDATE_ID) ?
            string(candidates[index, HOLISTIC_CANDIDATE_ID], "__UNIT_001") :
            "GTEP_STORAGE_CANDIDATE_$(index)__UNIT_001" for index in built_indices
        ]
    end

    audit = _holistic_empty_storage_build_audit()
    for (local_row, candidate_row) in enumerate(built_indices)
        candidate_id = _holistic_id(
            candidates,
            candidate_row,
            HOLISTIC_CANDIDATE_ID,
            "legacy-storage-candidate-row-$(candidate_row)",
        )
        asset_id = _holistic_id(rows, local_row, HOLISTIC_ASSET_ID, "")
        template_id =
            _holistic_id(candidates, candidate_row, "Operational_Template_ID", "")
        push!(
            audit,
            (
                candidate_row,
                candidate_id,
                asset_id,
                string(candidates[candidate_row, "Zone"]),
                string(candidates[candidate_row, "Type"]),
                to_float_output(candidates[candidate_row, Symbol("Max Power (MW)")], 0.0),
                to_float_output(output_rows[candidate_row, Symbol("Capacity (MW)")], 0.0),
                to_float_output(candidates[candidate_row, Symbol("Capacity (MWh)")], 0.0),
                to_float_output(
                    output_rows[candidate_row, Symbol("EnergyCapacity (MWh)")],
                    0.0,
                ),
                template_id,
                "candidate_then_pcm_fallback",
            ),
        )
    end
    return rows, audit
end

function _holistic_allocation_weights(values::Vector{Float64})
    nonnegative = max.(values, 0.0)
    total = sum(nonnegative)
    return total > 0.0 ? nonnegative ./ total : fill(1.0 / length(values), length(values))
end

function apply_line_builds_with_audit!(
    linedata::DataFrame,
    line_builds::DataFrame;
    network_model::Int = 1,
)
    audit = _holistic_empty_line_audit()
    nrow(line_builds) == 0 && return linedata, audit
    forward_col = Symbol(FORWARD_LINE_CAPACITY_COLUMN)
    reverse_col = Symbol(REVERSE_LINE_CAPACITY_COLUMN)
    linedata[!, forward_col] = Float64[to_float_output(v, 0.0) for v in linedata[!, forward_col]]
    linedata[!, reverse_col] = Float64[to_float_output(v, 0.0) for v in linedata[!, reverse_col]]
    endpoint_from =
        network_model in (2, 3) && _holistic_has_column(linedata, "from_bus") ?
        "from_bus" : "From_zone"
    endpoint_to =
        network_model in (2, 3) && _holistic_has_column(linedata, "to_bus") ?
        "to_bus" : "To_zone"

    for build_row = 1:nrow(line_builds)
        from_zone = string(line_builds[build_row, "From_zone"])
        to_zone = string(line_builds[build_row, "To_zone"])
        corridor_id = _holistic_id(
            line_builds,
            build_row,
            HOLISTIC_CORRIDOR_ID,
            "legacy-corridor-row-$(build_row)",
        )
        build_forward =
            to_float_output(line_builds[build_row, forward_col], 0.0)
        build_reverse =
            to_float_output(line_builds[build_row, reverse_col], 0.0)

        matches = Int[]
        orientations = Bool[]
        mapping_mode = "zonal_corridor"
        if _holistic_has_column(line_builds, HOLISTIC_CORRIDOR_ID) &&
           _holistic_has_column(linedata, HOLISTIC_CORRIDOR_ID) &&
           !isempty(_holistic_text(line_builds[build_row, HOLISTIC_CORRIDOR_ID], ""))
            id = string(line_builds[build_row, HOLISTIC_CORRIDOR_ID])
            matches = findall(i -> string(linedata[i, HOLISTIC_CORRIDOR_ID]) == id, 1:nrow(linedata))
            length(matches) == 1 || throw(
                ArgumentError(
                    "Corridor_ID $(id) must match exactly one PCM transmission row; found $(length(matches)).",
                ),
            )
            target_row = first(matches)
            direct =
                string(linedata[target_row, endpoint_from]) == from_zone &&
                string(linedata[target_row, endpoint_to]) == to_zone
            reverse =
                string(linedata[target_row, endpoint_from]) == to_zone &&
                string(linedata[target_row, endpoint_to]) == from_zone
            direct || reverse || throw(
                ArgumentError(
                    "Corridor_ID $(id) resolves to PCM row $(target_row), but its endpoints do not match $(from_zone)<->$(to_zone).",
                ),
            )
            orientations = [direct]
            mapping_mode = "corridor_id"
        else
            for row = 1:nrow(linedata)
                direct =
                    string(linedata[row, endpoint_from]) == from_zone &&
                    string(linedata[row, endpoint_to]) == to_zone
                reverse =
                    string(linedata[row, endpoint_from]) == to_zone &&
                    string(linedata[row, endpoint_to]) == from_zone
                if direct || reverse
                    push!(matches, row)
                    push!(orientations, direct)
                end
            end
            isempty(matches) && throw(
                ArgumentError(
                    "GTEP transmission build $(from_zone)->$(to_zone) has no PCM corridor mapping.",
                ),
            )
            if length(matches) > 1
                network_model in (0, 1) || throw(
                    ArgumentError(
                        "GTEP corridor $(from_zone)<->$(to_zone) maps to multiple nodal PCM branches. Add Corridor_ID or an explicit branch mapping.",
                    ),
                )
                mapping_mode = "proportional_parallel_corridor"
            end
        end

        logical_forward = Float64[
            orientations[k] ? linedata[row, forward_col] : linedata[row, reverse_col] for
            (k, row) in enumerate(matches)
        ]
        logical_reverse = Float64[
            orientations[k] ? linedata[row, reverse_col] : linedata[row, forward_col] for
            (k, row) in enumerate(matches)
        ]
        forward_weights = _holistic_allocation_weights(logical_forward)
        reverse_weights = _holistic_allocation_weights(logical_reverse)
        for (k, target_row) in enumerate(matches)
            forward_add = build_forward * forward_weights[k]
            reverse_add = build_reverse * reverse_weights[k]
            if orientations[k]
                linedata[target_row, forward_col] += forward_add
                linedata[target_row, reverse_col] += reverse_add
            else
                linedata[target_row, forward_col] += reverse_add
                linedata[target_row, reverse_col] += forward_add
            end
            target_id =
                _holistic_id(linedata, target_row, HOLISTIC_CORRIDOR_ID, "")
            push!(
                audit,
                (
                    build_row,
                    corridor_id,
                    from_zone,
                    to_zone,
                    target_row,
                    target_id,
                    mapping_mode,
                    forward_add,
                    reverse_add,
                ),
            )
        end
    end
    return linedata, audit
end

function _holistic_realize_planning_zones_from_bus!(
    rows::DataFrame,
    updated_input::Dict,
;
    label::AbstractString,
)
    nrow(rows) == 0 && return rows
    _holistic_has_column(rows, "Bus_id") || return rows
    haskey(updated_input, "Busdata") || throw(
        ArgumentError("$(label) has Bus_id but PCM busdata is unavailable."),
    )
    busdata = updated_input["Busdata"]
    for required in ("Bus_id", "Zone_id")
        _holistic_has_column(busdata, required) || throw(
            ArgumentError("PCM busdata must include $(required) for nodal build realization."),
        )
    end
    bus_to_zone = Dict(
        string(busdata[row, "Bus_id"]) => string(busdata[row, "Zone_id"]) for
        row = 1:nrow(busdata)
    )
    realized_zones = String[]
    for row = 1:nrow(rows)
        bus_id = string(rows[row, "Bus_id"])
        haskey(bus_to_zone, bus_id) || throw(
            ArgumentError("$(label) references Bus_id $(bus_id), which is absent from PCM busdata."),
        )
        push!(realized_zones, bus_to_zone[bus_id])
    end
    rows[!, "Zone"] = realized_zones
    return rows
end

function _holistic_append_to_raw_if_distinct!(
    updated_input::Dict,
    key::AbstractString,
    rows::DataFrame,
    using_raw_for_model::Bool,
)
    if haskey(updated_input, key) && !using_raw_for_model
        updated_input[key] = append_rows_preserve_columns(updated_input[key], rows)
    end
    return nothing
end

function prepare_pcm_inputs_from_gtep_linked(
    gtep_output::Dict,
    gtep_input::Dict,
    gtep_config::Dict,
    pcm_input::Dict,
    pcm_config::Dict,
)
    updated_input = deepcopy(pcm_input)
    retirement_audit =
        apply_gtep_retirements!(updated_input, gtep_output, gtep_input, gtep_config)

    using_raw_for_model =
        resource_aggregation_enabled(pcm_config) &&
        !haskey(updated_input, "AFdata") &&
        haskey(updated_input, "GendataRaw")
    if using_raw_for_model
        updated_input["Gendata"] = copy(updated_input["GendataRaw"])
    end

    new_generation, generation_audit = realize_generation_builds(
        gtep_output["capacity"],
        gtep_input["Gendata_candidate"],
        updated_input["Gendata"],
    )
    _holistic_realize_planning_zones_from_bus!(
        new_generation,
        updated_input;
        label = "GTEP generation build",
    )
    updated_input["Gendata"] =
        append_rows_preserve_columns(updated_input["Gendata"], new_generation)
    _holistic_append_to_raw_if_distinct!(
        updated_input,
        "GendataRaw",
        new_generation,
        using_raw_for_model,
    )

    new_storage, storage_audit = realize_storage_builds(
        gtep_output["es_capacity"],
        gtep_input["Estoragedata_candidate"],
        updated_input["Storagedata"],
    )
    _holistic_realize_planning_zones_from_bus!(
        new_storage,
        updated_input;
        label = "GTEP storage build",
    )
    updated_input["Storagedata"] =
        append_rows_preserve_columns(updated_input["Storagedata"], new_storage)

    line_output = _holistic_candidate_output_rows(
        gtep_output["line"],
        nrow(gtep_input["Linedata_candidate"]),
        "Transmission",
    )
    built_line_indices = [
        row for row = 1:nrow(line_output) if
        to_float_output(line_output[row, "New_Build"], 0.0) > 0.0 &&
        max(
            to_float_output(line_output[row, Symbol(FORWARD_LINE_CAPACITY_COLUMN)], 0.0),
            to_float_output(line_output[row, Symbol(REVERSE_LINE_CAPACITY_COLUMN)], 0.0),
        ) > 0.0
    ]
    line_builds = copy(line_output[built_line_indices, :])
    if _holistic_has_column(gtep_input["Linedata_candidate"], HOLISTIC_CORRIDOR_ID) &&
       !_holistic_has_column(line_builds, HOLISTIC_CORRIDOR_ID)
        line_builds[!, HOLISTIC_CORRIDOR_ID] =
            gtep_input["Linedata_candidate"][built_line_indices, HOLISTIC_CORRIDOR_ID]
    end
    network_model_raw = get(pcm_config, "network_model", 1)
    network_model =
        network_model_raw isa Integer ? Int(network_model_raw) : parse(Int, string(network_model_raw))
    line_table_key =
        network_model in (2, 3) && haskey(updated_input, "Branchdata") ?
        "Branchdata" : "Linedata"
    updated_input[line_table_key], line_audit = apply_line_builds_with_audit!(
        copy(updated_input[line_table_key]),
        line_builds;
        network_model = network_model,
    )

    finalize_pcm_inputs_for_holistic!(updated_input, pcm_config)
    if resource_aggregation_enabled(pcm_config)
        if haskey(updated_input, "AFdata")
            # Preserve the existing PCM AF-column behavior for backward compatibility.
            # Candidate VRE without a generator-level column uses its zonal profile.
        else
            raw_pcm_gendata = copy(updated_input["Gendata"])
            updated_input["GendataRaw"] = copy(raw_pcm_gendata)
            updated_input["Gendata"] = aggregate_gendata_pcm(raw_pcm_gendata, pcm_config)
            updated_input["AggregationAudit"] = build_pcm_aggregation_audit(
                raw_pcm_gendata,
                updated_input["Gendata"];
                config_set = pcm_config,
            )
        end
    end
    updated_input["LinkageAudit"] = Dict(
        "retirements" => retirement_audit,
        "generation_builds" => generation_audit,
        "storage_builds" => storage_audit,
        "line_allocations" => line_audit,
    )
    return updated_input
end

function holistic_transfer_summary(updated_input::Dict)
    audit = get(updated_input, "LinkageAudit", Dict{String,Any}())
    retirements = get(audit, "retirements", _holistic_empty_retirement_audit())
    generation =
        get(audit, "generation_builds", _holistic_empty_generation_build_audit())
    storage = get(audit, "storage_builds", _holistic_empty_storage_build_audit())
    lines = get(audit, "line_allocations", _holistic_empty_line_audit())
    raw_retirements =
        nrow(retirements) == 0 ? retirements : retirements[retirements.Layer .== "raw", :]
    retirement_basis = nrow(raw_retirements) > 0 ? raw_retirements : retirements
    return Dict(
        "retirement_rows" => nrow(retirement_basis),
        "retired_generation_mw" =>
            nrow(retirement_basis) == 0 ? 0.0 : sum(retirement_basis.RetiredMW),
        "new_generation_rows" => nrow(generation),
        "new_generation_mw" => nrow(generation) == 0 ? 0.0 : sum(generation.BuiltMW),
        "new_storage_rows" => nrow(storage),
        "new_storage_power_mw" =>
            nrow(storage) == 0 ? 0.0 : sum(storage.BuiltPowerMW),
        "new_storage_energy_mwh" =>
            nrow(storage) == 0 ? 0.0 : sum(storage.BuiltEnergyMWh),
        "new_line_rows" => length(unique(lines.CandidateRow)),
        "line_forward_added_mw" =>
            nrow(lines) == 0 ? 0.0 : sum(lines.ForwardAddedMW),
        "line_reverse_added_mw" =>
            nrow(lines) == 0 ? 0.0 : sum(lines.ReverseAddedMW),
    )
end

function _holistic_source_hashes(case_path::AbstractString, config::Dict)
    data_dir = joinpath(case_path, String(config["DataCase"]))
    hashes = Dict{String,String}()
    for filename in ("gendata.csv", "storagedata.csv", "linedata.csv", "branchdata.csv")
        path = joinpath(data_dir, filename)
        isfile(path) && (hashes[filename] = bytes2hex(sha256(read(path))))
    end
    return hashes
end

function persist_realized_pcm_inputs_for_holistic(
    output_path::AbstractString,
    pcm_config::Dict,
    updated_input::Dict;
    gtep_case_path::AbstractString = "",
    pcm_case_path::AbstractString = "",
    gtep_config::Union{Nothing,Dict} = nothing,
)
    data_dir = joinpath(output_path, "realized_inputs")
    mkpath(data_dir)
    written = Dict{String,String}()
    tables = Dict(
        "gendata" => pcm_gendata_for_holistic_persistence(updated_input, pcm_config),
        "storagedata" => updated_input["Storagedata"],
        "linedata" => updated_input["Linedata"],
    )
    haskey(updated_input, "Branchdata") &&
        (tables["branchdata"] = updated_input["Branchdata"])
    for (name, table) in tables
        path = joinpath(data_dir, "$(name).csv")
        CSV.write(path, table, header = true)
        written[name] = path
    end

    audit = get(updated_input, "LinkageAudit", Dict{String,Any}())
    for (name, table) in audit
        table isa AbstractDataFrame || continue
        path = joinpath(data_dir, "$(name)_audit.csv")
        CSV.write(path, table, header = true)
        written["$(name)_audit"] = path
    end

    summary = holistic_transfer_summary(updated_input)
    manifest = Dict{String,Any}(
        "schema_version" => 1,
        "workflow" => "GTEP-PCM",
        "source_cases" => Dict(
            "gtep" => String(gtep_case_path),
            "pcm" => String(pcm_case_path),
        ),
        "identity_policy" => "Asset_ID when supplied; otherwise validated legacy row or aggregate mapping",
        "source_pcm_hashes" =>
            isempty(pcm_case_path) ? Dict{String,String}() :
            _holistic_source_hashes(pcm_case_path, pcm_config),
        "source_gtep_hashes" =>
            isempty(gtep_case_path) || gtep_config === nothing ? Dict{String,String}() :
            _holistic_source_hashes(gtep_case_path, gtep_config),
        "transfer_summary" => summary,
    )
    manifest_path = joinpath(data_dir, "handoff_manifest.yml")
    open(manifest_path, "w") do io
        YAML.write(io, manifest)
    end
    written["manifest"] = manifest_path
    return written
end
