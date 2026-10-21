const HOLISTIC_OPERATIONAL_TEMPLATE_FILENAME = "operational_resource_templates.csv"

const HOLISTIC_GENERATION_OPERATIONAL_COLUMNS = [
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
]

const HOLISTIC_STORAGE_OPERATIONAL_COLUMNS = [
    "Charging efficiency",
    "Discharging efficiency",
    "Cost (\$/MWh)",
    "EF",
    "CC",
    "Charging Rate",
    "Discharging Rate",
    "reg_up_capability_mw",
    "reg_down_capability_mw",
    "spin_capability_mw",
    "nspin_capability_mw",
    "reg_up_offer_per_mw_hour",
    "reg_down_offer_per_mw_hour",
    "spin_offer_per_mw_hour",
    "nspin_offer_per_mw_hour",
]

_holistic_template_missing(value) =
    ismissing(value) ||
    value === nothing ||
    (value isa AbstractFloat && isnan(value)) ||
    (value isa AbstractString && begin
        stripped = strip(value)
        isempty(stripped) || lowercase(stripped) == "nan"
    end)

function _holistic_template_text(value, default = "")
    _holistic_template_missing(value) && return default
    text = strip(string(value))
    return isempty(text) ? default : text
end

function _holistic_template_float(value)
    value isa Number && return Float64(value)
    return parse(Float64, strip(string(value)))
end

function _holistic_empty_operational_parameter_audit()
    return DataFrame(
        ResourceKind = String[],
        CandidateID = String[],
        AssetID = String[],
        OperationalTemplateID = String[],
        Parameter = String[],
        Value = String[],
        Source = String[],
    )
end

function _holistic_template_kind(value)
    kind = lowercase(_holistic_template_text(value))
    kind == "generator" && return "generation"
    kind in ("storage", "generation") || throw(
        ArgumentError(
            "Operational template Resource_Kind must be generation or storage; got $(value).",
        ),
    )
    return kind
end

"""
    validate_operational_resource_templates(templates) -> DataFrame

Validate the optional PCM-side operational template registry. Template IDs are
globally unique and each row applies to either new generation or new storage.
Thermal generation templates must enable unit commitment.
"""
function validate_operational_resource_templates(templates::AbstractDataFrame)
    required = ["Operational_Template_ID", "Resource_Kind", "Type"]
    missing_columns = setdiff(required, names(templates))
    isempty(missing_columns) || throw(
        ArgumentError(
            "Operational template registry is missing columns: $(join(missing_columns, ", ")).",
        ),
    )

    ids = [
        _holistic_template_text(value) for value in templates[!, "Operational_Template_ID"]
    ]
    any(isempty, ids) &&
        throw(ArgumentError("Operational_Template_ID must not contain blank values."))
    length(ids) == length(unique(ids)) ||
        throw(ArgumentError("Operational_Template_ID values must be globally unique."))

    for row = 1:nrow(templates)
        kind = _holistic_template_kind(templates[row, "Resource_Kind"])
        type_name = _holistic_template_text(templates[row, "Type"])
        isempty(type_name) && throw(
            ArgumentError("Operational template $(ids[row]) must provide a nonblank Type."),
        )
        if kind == "generation" &&
           "Flag_thermal" in names(templates) &&
           !_holistic_template_missing(templates[row, "Flag_thermal"]) &&
           _holistic_template_float(templates[row, "Flag_thermal"]) >= 0.5
            "Flag_UC" in names(templates) || throw(
                ArgumentError(
                    "Thermal operational template $(ids[row]) must provide Flag_UC = 1.",
                ),
            )
            !_holistic_template_missing(templates[row, "Flag_UC"]) &&
                _holistic_template_float(templates[row, "Flag_UC"]) >= 0.5 || throw(
                ArgumentError(
                    "Thermal operational template $(ids[row]) must provide Flag_UC = 1.",
                ),
            )
        end
    end
    return DataFrame(templates)
end

"""
    load_operational_resource_templates(case_path, config) -> DataFrame

Load `operational_resource_templates.csv` from the configured PCM `DataCase`.
The file is optional so existing HOPE cases remain backward compatible.
"""
function load_operational_resource_templates(case_path::AbstractString, config::Dict)
    data_dir = joinpath(case_path, String(config["DataCase"]))
    path = joinpath(data_dir, HOLISTIC_OPERATIONAL_TEMPLATE_FILENAME)
    isfile(path) || return DataFrame()
    return validate_operational_resource_templates(CSV.read(path, DataFrame))
end

function _holistic_template_lookup(templates::AbstractDataFrame)
    lookup = Dict{String,Int}()
    for row = 1:nrow(templates)
        lookup[_holistic_template_text(templates[row, "Operational_Template_ID"])] = row
    end
    return lookup
end

function _holistic_widen_column!(table::DataFrame, column::AbstractString)
    if column in names(table)
        table[!, column] = Any[value for value in table[!, column]]
    else
        table[!, column] = Any[missing for _ = 1:nrow(table)]
    end
    return table
end

function _holistic_parameter_audit_row(
    row,
    resource_kind::AbstractString,
    template_id::AbstractString,
    parameter::AbstractString,
    value,
    source::AbstractString,
)
    candidate_id =
        :Candidate_ID in propertynames(row) ? _holistic_template_text(row.Candidate_ID) : ""
    asset_id = :Asset_ID in propertynames(row) ? _holistic_template_text(row.Asset_ID) : ""
    return (
        String(resource_kind),
        candidate_id,
        asset_id,
        String(template_id),
        String(parameter),
        string(value),
        String(source),
    )
end

function _holistic_enforce_new_thermal_commitment!(
    rows::DataFrame,
    audit::DataFrame,
    template_ids::AbstractVector{<:AbstractString},
)
    nrow(rows) == 0 && return rows
    "Flag_thermal" in names(rows) || return rows
    _holistic_widen_column!(rows, "Flag_UC")
    for row_index = 1:nrow(rows)
        thermal = rows[row_index, "Flag_thermal"]
        _holistic_template_missing(thermal) && continue
        _holistic_template_float(thermal) >= 0.5 || continue
        current = rows[row_index, "Flag_UC"]
        if _holistic_template_missing(current) || _holistic_template_float(current) < 0.5
            rows[row_index, "Flag_UC"] = 1
            push!(
                audit,
                _holistic_parameter_audit_row(
                    rows[row_index, :],
                    "generation",
                    template_ids[row_index],
                    "Flag_UC",
                    1,
                    "thermal_commitment_policy",
                ),
            )
        end
    end
    return rows
end

"""
    apply_operational_resource_templates(rows, templates; resource_kind)

Populate missing PCM operating parameters on newly realized resources. Explicit
candidate values take precedence, then the referenced PCM template, followed by
the existing PCM group-average/default logic. For new thermal generation,
`Flag_UC = 1` is enforced even when a legacy candidate contains a zero placeholder.
"""
function apply_operational_resource_templates(
    rows::AbstractDataFrame,
    templates::AbstractDataFrame;
    resource_kind::AbstractString,
)
    kind = _holistic_template_kind(resource_kind)
    work = DataFrame(rows)
    audit = _holistic_empty_operational_parameter_audit()
    nrow(work) == 0 && return work, audit

    template_ids = [
        "Operational_Template_ID" in names(work) ?
        _holistic_template_text(work[row, "Operational_Template_ID"]) : "" for
        row = 1:nrow(work)
    ]
    if nrow(templates) == 0
        if any(id -> !isempty(id), template_ids)
            @warn "Operational_Template_ID is present but the PCM case has no operational_resource_templates.csv; using candidate values and legacy PCM fallbacks."
        end
        kind == "generation" &&
            _holistic_enforce_new_thermal_commitment!(work, audit, template_ids)
        return work, audit
    end

    validated = validate_operational_resource_templates(templates)
    lookup = _holistic_template_lookup(validated)
    allowed_columns =
        kind == "generation" ? HOLISTIC_GENERATION_OPERATIONAL_COLUMNS :
        HOLISTIC_STORAGE_OPERATIONAL_COLUMNS

    for row_index = 1:nrow(work)
        template_id = template_ids[row_index]
        isempty(template_id) && continue
        haskey(lookup, template_id) || throw(
            ArgumentError(
                "No operational template named $(template_id) for realized $(kind) candidate.",
            ),
        )
        template_row = lookup[template_id]
        template_kind = _holistic_template_kind(validated[template_row, "Resource_Kind"])
        template_kind == kind || throw(
            ArgumentError(
                "Operational template $(template_id) is for $(template_kind), not $(kind).",
            ),
        )
        if "Type" in names(work)
            candidate_type = _holistic_template_text(work[row_index, "Type"])
            template_type = _holistic_template_text(validated[template_row, "Type"])
            lowercase(candidate_type) == lowercase(template_type) || throw(
                ArgumentError(
                    "Operational template $(template_id) has Type=$(template_type), but candidate has Type=$(candidate_type).",
                ),
            )
        end

        for parameter in allowed_columns
            parameter in names(validated) || continue
            template_value = validated[template_row, parameter]
            _holistic_template_missing(template_value) && continue
            _holistic_widen_column!(work, parameter)
            current = work[row_index, parameter]
            source = if _holistic_template_missing(current)
                work[row_index, parameter] = template_value
                "template:$(template_id)"
            else
                "candidate"
            end
            push!(
                audit,
                _holistic_parameter_audit_row(
                    work[row_index, :],
                    kind,
                    template_id,
                    parameter,
                    work[row_index, parameter],
                    source,
                ),
            )
        end
    end

    kind == "generation" &&
        _holistic_enforce_new_thermal_commitment!(work, audit, template_ids)
    return work, audit
end
