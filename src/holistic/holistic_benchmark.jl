const HOLISTIC_BENCHMARK_SCHEMA_VERSION = 1

function _benchmark_required_file(path::AbstractString, label::AbstractString)
    isfile(path) || throw(ArgumentError("Missing $(label): $(path)"))
    return path
end

function _benchmark_csv(path::AbstractString, label::AbstractString)
    return CSV.read(_benchmark_required_file(path, label), DataFrame)
end

function _benchmark_yaml(path::AbstractString, label::AbstractString)
    value = YAML.load_file(_benchmark_required_file(path, label))
    value isa AbstractDict ||
        throw(ArgumentError("$(label) must be a YAML mapping: $(path)"))
    return value
end

_benchmark_bool(value) = value === true || lowercase(strip(string(value))) == "true"

function _benchmark_float(value, default::Float64 = 0.0)
    ismissing(value) && return default
    value isa Number && return Float64(value)
    text = strip(string(value))
    isempty(text) && return default
    return parse(Float64, text)
end

function _benchmark_column(table::DataFrame, candidates::Vector{String})
    available = Set(names(table))
    for candidate in candidates
        candidate in available && return candidate
    end
    return nothing
end

function _benchmark_find_data_file(case_path::AbstractString, filename::AbstractString)
    direct = joinpath(case_path, filename)
    isfile(direct) && return direct
    matches = String[]
    for (directory, _, files) in walkdir(case_path)
        filename in files || continue
        occursin(r"(^|[\\/])output(_holistic)?([\\/]|$)", directory) && continue
        push!(matches, joinpath(directory, filename))
    end
    length(matches) == 1 && return only(matches)
    isempty(matches) &&
        throw(ArgumentError("Could not find $(filename) under $(case_path)."))
    throw(ArgumentError("Found multiple input copies of $(filename) under $(case_path)."))
end

function _benchmark_csv_rows(path::AbstractString)
    return nrow(CSV.read(path, DataFrame))
end

function _benchmark_check!(
    checks::DataFrame,
    stage::AbstractString,
    check::AbstractString,
    expected,
    actual,
    comparator::AbstractString,
    passed::Bool,
    evidence::AbstractString,
)
    push!(
        checks,
        (
            Stage = String(stage),
            Check = String(check),
            Expected = string(expected),
            Actual = string(actual),
            Comparator = String(comparator),
            Passed = passed,
            Evidence = String(evidence),
        ),
    )
    return passed
end

function _benchmark_numeric_check!(
    checks::DataFrame,
    stage::AbstractString,
    check::AbstractString,
    expected,
    actual,
    evidence::AbstractString;
    atol::Float64 = 1.0e-5,
)
    expected_value = _benchmark_float(expected)
    actual_value = _benchmark_float(actual)
    return _benchmark_check!(
        checks,
        stage,
        check,
        expected_value,
        actual_value,
        "isapprox",
        isapprox(actual_value, expected_value; atol = atol, rtol = 0.0),
        evidence,
    )
end

function _benchmark_metric(metrics::AbstractDict, key::AbstractString, default = 0.0)
    return haskey(metrics, key) ? metrics[key] : default
end

function _benchmark_slice_metadata(
    run_workspace::AbstractString,
    validation_slice_path,
    solve_hours::Int,
)
    path =
        validation_slice_path === nothing ?
        joinpath(run_workspace, "validation_slice.yml") :
        abspath(String(validation_slice_path))
    if isfile(path)
        slice = _benchmark_yaml(path, "validation slice metadata")
        warmup = Int(round(_benchmark_float(get(slice, "pcm_warmup_hours", 0))))
        evaluation = Int(
            round(
                _benchmark_float(get(slice, "pcm_evaluation_hours", solve_hours - warmup)),
            ),
        )
        start_hour = Int(
            round(_benchmark_float(get(slice, "pcm_evaluation_start_hour", warmup + 1))),
        )
        end_hour = Int(
            round(
                _benchmark_float(
                    get(slice, "pcm_evaluation_end_hour", start_hour + evaluation - 1),
                ),
            ),
        )
        start_hour >= 1 ||
            throw(ArgumentError("PCM evaluation start hour must be positive."))
        end_hour <= solve_hours ||
            throw(ArgumentError("PCM evaluation end hour exceeds output horizon."))
        evaluation == end_hour - start_hour + 1 ||
            throw(ArgumentError("PCM evaluation-hour metadata is internally inconsistent."))
        return Dict{String,Any}(
            "path" => path,
            "warmup_hours" => warmup,
            "evaluation_hours" => evaluation,
            "evaluation_start_hour" => start_hour,
            "evaluation_end_hour" => end_hour,
            "evaluation_month" => get(slice, "pcm_month", nothing),
        )
    end
    return Dict{String,Any}(
        "path" => nothing,
        "warmup_hours" => 0,
        "evaluation_hours" => solve_hours,
        "evaluation_start_hour" => 1,
        "evaluation_end_hour" => solve_hours,
        "evaluation_month" => nothing,
    )
end

function _benchmark_hour_columns(table::DataFrame)
    pairs = Tuple{Int,String}[]
    for name in names(table)
        matched = match(r"^h(\d+)$", name)
        matched === nothing && continue
        push!(pairs, (parse(Int, matched.captures[1]), name))
    end
    sort!(pairs; by = first)
    return pairs
end

function _benchmark_sum_hours(table::DataFrame, columns::Vector{String})
    total = 0.0
    for column in columns, value in table[!, column]
        total += _benchmark_float(value)
    end
    return total
end

function _benchmark_evaluation_metrics(
    output_path::AbstractString,
    realized_path::AbstractString,
    slice::AbstractDict,
)
    power =
        _benchmark_csv(joinpath(output_path, "power_hourly.csv"), "PCM hourly generation")
    hour_pairs = _benchmark_hour_columns(power)
    isempty(hour_pairs) &&
        throw(ArgumentError("PCM power_hourly.csv has no h<number> columns."))
    solve_hours = last(hour_pairs)[1]
    start_hour = Int(slice["evaluation_start_hour"])
    end_hour = Int(slice["evaluation_end_hour"])
    evaluation_columns =
        [name for (hour, name) in hour_pairs if start_hour <= hour <= end_hour]
    length(evaluation_columns) == Int(slice["evaluation_hours"]) || throw(
        ArgumentError("PCM power output does not contain the requested evaluation hours."),
    )

    realized_generation =
        _benchmark_csv(joinpath(realized_path, "gendata.csv"), "realized generators")
    candidate_id_column = _benchmark_column(realized_generation, ["Candidate_ID"])
    candidate_power =
        if nrow(realized_generation) == nrow(power) && candidate_id_column !== nothing
            candidate_rows = [
                row for row = 1:nrow(realized_generation) if
                !ismissing(realized_generation[row, candidate_id_column]) &&
                !isempty(strip(string(realized_generation[row, candidate_id_column])))
            ]
            power[candidate_rows, :]
        else
            category_column = _benchmark_column(power, ["EC_Category"])
            category_column === nothing ? power[1:0, :] :
            power[string.(power[!, category_column]).=="Candidate", :]
        end
    candidate_dispatch = _benchmark_sum_hours(candidate_power, evaluation_columns)

    summary = _benchmark_csv(
        joinpath(output_path, "Analysis", "Summary_System_Hourly.csv"),
        "PCM hourly system summary",
    )
    nrow(summary) == solve_hours || throw(
        ArgumentError("PCM hourly summary and generation output have different horizons."),
    )
    evaluation_rows = start_hour:end_hour
    emissions_column = _benchmark_column(summary, ["TotalEmissions_ton"])
    charge_column = _benchmark_column(summary, ["StorageCharge_MW"])
    discharge_column = _benchmark_column(summary, ["StorageDischarge_MW"])
    load_shed_column = _benchmark_column(summary, ["LoadShedding_MW"])
    curtailment_column = _benchmark_column(summary, ["Curtailment_MW"])
    sum_column(column) =
        column === nothing ? 0.0 :
        sum(_benchmark_float(value) for value in summary[evaluation_rows, column])

    variable_cost = missing
    if nrow(realized_generation) == nrow(power)
        cost_column = _benchmark_column(realized_generation, ["Cost (\$/MWh)"])
        if cost_column !== nothing
            variable_cost = sum(
                _benchmark_float(realized_generation[row, cost_column]) * sum(
                    _benchmark_float(power[row, column]) for column in evaluation_columns
                ) for row = 1:nrow(power)
            )
        end
    end

    return Dict{String,Any}(
        "evaluation_new_generation_dispatch_mwh" => candidate_dispatch,
        "evaluation_storage_charge_mwh" => sum_column(charge_column),
        "evaluation_storage_discharge_mwh" => sum_column(discharge_column),
        "evaluation_emissions_tons" => sum_column(emissions_column),
        "evaluation_load_shedding_mwh" => sum_column(load_shed_column),
        "evaluation_curtailment_mwh" => sum_column(curtailment_column),
        "evaluation_variable_generation_cost_usd" => variable_cost,
    )
end

function _benchmark_physical_realization(realized_path::AbstractString)
    generation_builds = _benchmark_csv(
        joinpath(realized_path, "generation_builds_audit.csv"),
        "generation build audit",
    )
    storage_builds = _benchmark_csv(
        joinpath(realized_path, "storage_builds_audit.csv"),
        "storage build audit",
    )
    generators =
        _benchmark_csv(joinpath(realized_path, "gendata.csv"), "realized generators")
    storage = _benchmark_csv(joinpath(realized_path, "storagedata.csv"), "realized storage")

    generator_by_asset = Dict(
        string(row["Asset_ID"]) => row for row in eachrow(generators) if
        !ismissing(row["Asset_ID"]) && !isempty(strip(string(row["Asset_ID"])))
    )
    storage_by_asset = Dict(
        string(row["Asset_ID"]) => row for row in eachrow(storage) if
        !ismissing(row["Asset_ID"]) && !isempty(strip(string(row["Asset_ID"])))
    )
    physical = DataFrame(
        ResourceKind = String[],
        CandidateID = String[],
        RealizedAssetID = String[],
        Zone = String[],
        Type = String[],
        BusID = String[],
        Latitude = Union{Missing,Float64}[],
        Longitude = Union{Missing,Float64}[],
        BuiltPowerMW = Float64[],
        BuiltEnergyMWh = Union{Missing,Float64}[],
        OperationalTemplateID = String[],
        ParameterSource = String[],
    )
    for build in eachrow(generation_builds)
        asset_id = string(build["RealizedAssetID"])
        haskey(generator_by_asset, asset_id) || throw(
            ArgumentError(
                "Generation build $(asset_id) is absent from realized gendata.csv.",
            ),
        )
        realized = generator_by_asset[asset_id]
        push!(
            physical,
            (
                "generation",
                string(build["CandidateID"]),
                asset_id,
                string(build["Zone"]),
                string(build["Type"]),
                string(realized["Bus_id"]),
                _benchmark_optional_float(realized, "Latitude"),
                _benchmark_optional_float(realized, "Longitude"),
                _benchmark_float(build["BuiltMW"]),
                missing,
                string(build["OperationalTemplateID"]),
                string(build["ParameterSource"]),
            ),
        )
    end
    for build in eachrow(storage_builds)
        asset_id = string(build["RealizedAssetID"])
        haskey(storage_by_asset, asset_id) || throw(
            ArgumentError(
                "Storage build $(asset_id) is absent from realized storagedata.csv.",
            ),
        )
        realized = storage_by_asset[asset_id]
        push!(
            physical,
            (
                "storage",
                string(build["CandidateID"]),
                asset_id,
                string(build["Zone"]),
                string(build["Type"]),
                string(realized["Bus_id"]),
                _benchmark_optional_float(realized, "Latitude"),
                _benchmark_optional_float(realized, "Longitude"),
                _benchmark_float(build["BuiltPowerMW"]),
                _benchmark_float(build["BuiltEnergyMWh"]),
                string(build["OperationalTemplateID"]),
                string(build["ParameterSource"]),
            ),
        )
    end
    return physical, generation_builds, storage_builds
end

function _benchmark_optional_float(row, column::AbstractString)
    Symbol(column) in propertynames(row) || return missing
    value = row[column]
    ismissing(value) && return missing
    text = strip(string(value))
    isempty(text) && return missing
    return _benchmark_float(value)
end

function _benchmark_build_summary(physical::DataFrame)
    summary = combine(
        groupby(physical, [:ResourceKind, :Zone, :Type]),
        :BuiltPowerMW => sum => :BuiltPowerMW,
        :BuiltEnergyMWh => (values -> sum(skipmissing(values))) => :BuiltEnergyMWh,
        nrow => :RealizedAssets,
    )
    sort!(summary, [:ResourceKind, :Zone, :Type])
    return summary
end

function _benchmark_expected_value_checks!(
    checks::DataFrame,
    summary::AbstractDict,
    expected_path,
)
    expected_path === nothing && return checks
    baseline = _benchmark_yaml(abspath(String(expected_path)), "benchmark baseline")
    expected_metrics = get(baseline, "expected_metrics", Dict{String,Any}())
    for (key, specification) in expected_metrics
        metric = string(key)
        haskey(summary, metric) || begin
            _benchmark_check!(
                checks,
                "reference baseline",
                metric,
                get(specification, "value", "defined"),
                "missing",
                "exists",
                false,
                basename(String(expected_path)),
            )
            continue
        end
        expected = get(specification, "value", nothing)
        actual = summary[metric]
        if expected isa Number
            atol = _benchmark_float(get(specification, "atol", 0.0))
            rtol = _benchmark_float(get(specification, "rtol", 0.0))
            passed = isapprox(
                _benchmark_float(actual),
                _benchmark_float(expected);
                atol = atol,
                rtol = rtol,
            )
            _benchmark_check!(
                checks,
                "reference baseline",
                metric,
                expected,
                actual,
                "isapprox(atol=$(atol), rtol=$(rtol))",
                passed,
                basename(String(expected_path)),
            )
        else
            passed = string(actual) == string(expected)
            _benchmark_check!(
                checks,
                "reference baseline",
                metric,
                expected,
                actual,
                "==",
                passed,
                basename(String(expected_path)),
            )
        end
    end
    return checks
end

function _benchmark_markdown_table(io::IO, table::DataFrame, columns)
    labels = first.(columns)
    names_to_use = last.(columns)
    println(io, "| ", join(labels, " | "), " |")
    println(io, "| ", join(fill("---", length(labels)), " | "), " |")
    for row in eachrow(table)
        values = String[]
        for name in names_to_use
            value = row[name]
            push!(values, ismissing(value) ? "" : replace(string(value), "|" => "\\|"))
        end
        println(io, "| ", join(values, " | "), " |")
    end
end

function _benchmark_write_markdown(
    path::AbstractString,
    summary::AbstractDict,
    checks::DataFrame,
    builds::DataFrame,
    physical::DataFrame,
    retirements::DataFrame,
    line_allocations::DataFrame,
)
    open(path, "w") do io
        println(io, "# GTEP-to-PCM benchmark evidence")
        println(io)
        println(io, "Overall result: **", summary["all_passed"] ? "PASS" : "FAIL", "**.")
        println(io)
        println(
            io,
            "This report follows one solved planning decision through physical realization and operational use. It was generated from the run artifacts; it is not a manually transcribed result.",
        )
        println(io)
        println(io, "## Scope and provenance")
        println(io)
        println(io, "- Run ID: `", summary["run_id"], "`")
        println(io, "- Solver: `", summary["solver"], "`")
        println(io, "- Run status: `", summary["run_status"], "`")
        println(io, "- GTEP chronology: ", summary["gtep_hours"], " hours")
        println(
            io,
            "- PCM solve chronology: ",
            summary["pcm_solve_hours"],
            " hours (",
            summary["pcm_warmup_hours"],
            " warm-up + ",
            summary["pcm_evaluation_hours"],
            " evaluation)",
        )
        println(
            io,
            "- Physical network: ",
            summary["physical_nodes"],
            " buses and ",
            summary["physical_branches"],
            " branches",
        )
        println(io, "- Source GTEP fingerprint: `", summary["gtep_source_sha256"], "`")
        println(io, "- Source PCM fingerprint: `", summary["pcm_source_sha256"], "`")
        println(io)
        println(io, "## GTEP decisions delivered to PCM")
        println(io)
        _benchmark_markdown_table(
            io,
            builds,
            [
                "Resource" => "ResourceKind",
                "Zone" => "Zone",
                "Type" => "Type",
                "Power (MW)" => "BuiltPowerMW",
                "Energy (MWh)" => "BuiltEnergyMWh",
                "Assets" => "RealizedAssets",
            ],
        )
        println(io)
        println(io, "### Retirement and transmission transfer")
        println(io)
        if nrow(retirements) > 0
            _benchmark_markdown_table(
                io,
                retirements,
                [
                    "Asset" => "AssetID",
                    "Zone" => "Zone",
                    "Type" => "Type",
                    "Mapping" => "MappingMode",
                    "Initial MW" => "InitialMW",
                    "Retired MW" => "RetiredMW",
                    "Final MW" => "FinalMW",
                ],
            )
        else
            println(io, "No retirement was selected in this solve.")
        end
        println(io)
        if nrow(line_allocations) > 0
            _benchmark_markdown_table(
                io,
                line_allocations,
                [
                    "Corridor" => "CorridorID",
                    "From" => "FromZone",
                    "To" => "ToZone",
                    "Mapping" => "MappingMode",
                    "Forward added (MW)" => "ForwardAddedMW",
                    "Reverse added (MW)" => "ReverseAddedMW",
                ],
            )
        else
            println(io, "No transmission addition was selected in this solve.")
        end
        println(io)
        println(io, "## Physical realization")
        println(io)
        println(
            io,
            "GTEP decides capacity by planning zone. The case-owned realization contract assigns each selected candidate to a predefined transmission bus; OSM supplies the synthetic topology/geography, while electrical ratings and candidate siting remain documented assumptions.",
        )
        println(io)
        _benchmark_markdown_table(
            io,
            physical,
            [
                "Kind" => "ResourceKind",
                "Candidate" => "CandidateID",
                "Realized asset" => "RealizedAssetID",
                "Zone" => "Zone",
                "Type" => "Type",
                "Bus" => "BusID",
                "MW" => "BuiltPowerMW",
                "MWh" => "BuiltEnergyMWh",
                "Operational template" => "OperationalTemplateID",
            ],
        )
        println(io)
        println(io, "## PCM operational evidence")
        println(io)
        println(io, "| Metric | Value | Unit |")
        println(io, "| --- | ---: | --- |")
        for (label, key, unit) in (
            ("GTEP objective", "gtep_objective_usd", "USD (annual planning objective)"),
            ("PCM objective", "pcm_objective_usd", "USD (complete solve horizon)"),
            (
                "Evaluation variable generation cost",
                "evaluation_variable_generation_cost_usd",
                "USD",
            ),
            (
                "Transferred new-generation dispatch",
                "evaluation_new_generation_dispatch_mwh",
                "MWh",
            ),
            ("Storage charge", "evaluation_storage_charge_mwh", "MWh"),
            ("Storage discharge", "evaluation_storage_discharge_mwh", "MWh"),
            ("Maximum upgraded-corridor flow", "pcm_upgraded_line_max_abs_flow_mw", "MW"),
            (
                "Upgraded-corridor flow above source rating",
                "pcm_upgraded_line_flow_above_source_mw",
                "MW",
            ),
            ("Emissions", "evaluation_emissions_tons", "tons"),
            ("Load shedding", "evaluation_load_shedding_mwh", "MWh"),
            ("RPS slack", "pcm_rps_slack_mwh", "MWh (complete solve horizon)"),
        )
            value = get(summary, key, missing)
            println(
                io,
                "| ",
                label,
                " | ",
                ismissing(value) ? "not available" : string(value),
                " | ",
                unit,
                " |",
            )
        end
        println(io)
        println(io, "## Consistency checks")
        println(io)
        _benchmark_markdown_table(
            io,
            checks,
            [
                "Stage" => "Stage",
                "Check" => "Check",
                "Expected" => "Expected",
                "Actual" => "Actual",
                "Pass" => "Passed",
                "Evidence" => "Evidence",
            ],
        )
        println(io)
        println(io, "## Interpretation boundary")
        println(io)
        println(
            io,
            "Capacity, identity, siting, and transferred parameters are direct handoff invariants and must reconcile exactly within numerical tolerance. GTEP and PCM objective values, operating costs, dispatch, and emissions are diagnostic outputs, not equality checks: GTEP is an annual planning model, while PCM uses a shorter operational horizon, finer network resolution, unit commitment, and additional reserve products.",
        )
    end
    return path
end

"""
    write_holistic_benchmark_report(run_workspace; output_path, validation_slice_path, expected_path, require_all)

Build a deterministic evidence bundle from a completed GTEP-to-PCM run. The
bundle contains a human-readable Markdown report, machine-readable YAML summary,
pass/fail CSV, build summary, and candidate-to-bus physical-realization table.
The function reads solved artifacts only and never modifies either source case.
"""
function write_holistic_benchmark_report(
    run_workspace::AbstractString;
    output_path::AbstractString = joinpath(run_workspace, "benchmark"),
    validation_slice_path = nothing,
    expected_path = nothing,
    require_all::Bool = true,
)
    workspace = abspath(String(run_workspace))
    manifest = _benchmark_yaml(joinpath(workspace, "run_manifest.yml"), "run manifest")
    gtep_case =
        isdir(joinpath(workspace, "gtep_case")) ? joinpath(workspace, "gtep_case") :
        string(get(manifest, "gtep_case_path", ""))
    pcm_case =
        isdir(joinpath(workspace, "pcm_case")) ? joinpath(workspace, "pcm_case") :
        string(get(manifest, "pcm_case_path", ""))
    isdir(gtep_case) || throw(ArgumentError("GTEP run case is missing: $(gtep_case)"))
    isdir(pcm_case) || throw(ArgumentError("PCM run case is missing: $(pcm_case)"))
    pcm_output = joinpath(pcm_case, "output_holistic")
    realized_path = joinpath(pcm_output, "realized_inputs")

    coverage =
        _benchmark_yaml(joinpath(pcm_output, "holistic_coverage.yml"), "coverage report")
    transfer = _benchmark_yaml(
        joinpath(realized_path, "transfer_reconciliation.yml"),
        "transfer reconciliation",
    )
    handoff =
        _benchmark_yaml(joinpath(realized_path, "handoff_contract.yml"), "handoff contract")
    metrics = get(coverage, "metrics", Dict{String,Any}())
    transfer_metrics = get(transfer, "metrics", Dict{String,Any}())
    physical, _, _ = _benchmark_physical_realization(realized_path)
    builds = _benchmark_build_summary(physical)
    retirement_path = joinpath(realized_path, "retirements_audit.csv")
    retirements = if isfile(retirement_path)
        audit = CSV.read(retirement_path, DataFrame)
        if "Layer" in names(audit) && any(string.(audit.Layer) .== "raw")
            audit[string.(audit.Layer).=="raw", :]
        else
            audit
        end
    else
        DataFrame()
    end
    line_allocations_path = joinpath(realized_path, "line_allocations_audit.csv")
    line_allocations =
        isfile(line_allocations_path) ? CSV.read(line_allocations_path, DataFrame) :
        DataFrame()

    power =
        _benchmark_csv(joinpath(pcm_output, "power_hourly.csv"), "PCM hourly generation")
    solve_hours = length(_benchmark_hour_columns(power))
    slice = _benchmark_slice_metadata(workspace, validation_slice_path, solve_hours)
    operational = _benchmark_evaluation_metrics(pcm_output, realized_path, slice)
    gtep_source_case = string(get(manifest, "gtep_source_path", ""))
    pcm_source_case = string(get(manifest, "pcm_source_path", ""))
    gtep_input_case = try
        _benchmark_find_data_file(gtep_case, "load_timeseries_regional.csv")
        gtep_case
    catch err
        isdir(gtep_source_case) || rethrow(err)
        gtep_source_case
    end
    pcm_input_case = try
        _benchmark_find_data_file(pcm_case, "busdata.csv")
        pcm_case
    catch err
        isdir(pcm_source_case) || rethrow(err)
        pcm_source_case
    end
    gtep_hours = _benchmark_csv_rows(
        _benchmark_find_data_file(gtep_input_case, "load_timeseries_regional.csv"),
    )
    realized_generators =
        _benchmark_csv(joinpath(realized_path, "gendata.csv"), "realized generators")
    realized_storage =
        _benchmark_csv(joinpath(realized_path, "storagedata.csv"), "realized storage")
    branches =
        _benchmark_csv(joinpath(realized_path, "branchdata.csv"), "realized branches")
    buses = _benchmark_csv(
        _benchmark_find_data_file(pcm_input_case, "busdata.csv"),
        "PCM buses",
    )

    checks = DataFrame(
        Stage = String[],
        Check = String[],
        Expected = String[],
        Actual = String[],
        Comparator = String[],
        Passed = Bool[],
        Evidence = String[],
    )
    _benchmark_check!(
        checks,
        "workflow",
        "run published",
        "PUBLISHED",
        get(manifest, "status", ""),
        "==",
        get(manifest, "status", "") == "PUBLISHED",
        "run_manifest.yml",
    )
    _benchmark_check!(
        checks,
        "GTEP",
        "termination status",
        "OPTIMAL",
        _benchmark_metric(metrics, "gtep_termination_status", ""),
        "==",
        _benchmark_metric(metrics, "gtep_termination_status", "") == "OPTIMAL",
        "holistic_coverage.yml",
    )
    _benchmark_check!(
        checks,
        "PCM",
        "termination status",
        "OPTIMAL",
        _benchmark_metric(metrics, "pcm_termination_status", ""),
        "==",
        _benchmark_metric(metrics, "pcm_termination_status", "") == "OPTIMAL",
        "holistic_coverage.yml",
    )
    _benchmark_check!(
        checks,
        "handoff",
        "contract valid",
        true,
        get(handoff, "valid", false),
        "==",
        _benchmark_bool(get(handoff, "valid", false)),
        "handoff_contract.yml",
    )
    _benchmark_check!(
        checks,
        "handoff",
        "transfer valid",
        true,
        get(transfer, "valid", false),
        "==",
        _benchmark_bool(get(transfer, "valid", false)),
        "transfer_reconciliation.yml",
    )
    _benchmark_check!(
        checks,
        "workflow",
        "coverage passed",
        true,
        get(coverage, "all_passed", false),
        "==",
        _benchmark_bool(get(coverage, "all_passed", false)),
        "holistic_coverage.yml",
    )
    _benchmark_check!(
        checks,
        "workflow",
        "GTEP source unchanged",
        true,
        _benchmark_metric(metrics, "source_gtep_unchanged", false),
        "==",
        _benchmark_bool(_benchmark_metric(metrics, "source_gtep_unchanged", false)),
        "holistic_coverage.yml",
    )
    _benchmark_check!(
        checks,
        "workflow",
        "PCM source unchanged",
        true,
        _benchmark_metric(metrics, "source_pcm_unchanged", false),
        "==",
        _benchmark_bool(_benchmark_metric(metrics, "source_pcm_unchanged", false)),
        "holistic_coverage.yml",
    )
    for check in get(transfer, "checks", Any[])
        _benchmark_check!(
            checks,
            "transfer",
            string(check["Check"]),
            check["Expected"],
            check["Actual"],
            "isapprox",
            _benchmark_bool(check["Passed"]),
            "transfer_reconciliation.yml",
        )
    end
    expected_generation = _benchmark_metric(transfer_metrics, "expected_new_generation_mw")
    expected_storage_power =
        _benchmark_metric(transfer_metrics, "expected_new_storage_power_mw")
    expected_storage_energy =
        _benchmark_metric(transfer_metrics, "expected_new_storage_energy_mwh")
    _benchmark_numeric_check!(
        checks,
        "physical realization",
        "new generation delivered",
        expected_generation,
        sum(physical[physical.ResourceKind.=="generation", :BuiltPowerMW]),
        "generation_builds_audit.csv + gendata.csv",
    )
    _benchmark_numeric_check!(
        checks,
        "physical realization",
        "storage power delivered",
        expected_storage_power,
        sum(physical[physical.ResourceKind.=="storage", :BuiltPowerMW]),
        "storage_builds_audit.csv + storagedata.csv",
    )
    _benchmark_numeric_check!(
        checks,
        "physical realization",
        "storage energy delivered",
        expected_storage_energy,
        sum(skipmissing(physical[physical.ResourceKind.=="storage", :BuiltEnergyMWh])),
        "storage_builds_audit.csv + storagedata.csv",
    )
    _benchmark_check!(
        checks,
        "physical realization",
        "all realized buses populated",
        true,
        all(!isempty(strip(value)) for value in physical.BusID),
        "==",
        all(!isempty(strip(value)) for value in physical.BusID),
        "physical_realization.csv",
    )
    _benchmark_check!(
        checks,
        "PCM",
        "evaluation load shedding",
        "<= 1.0e-6",
        operational["evaluation_load_shedding_mwh"],
        "<=",
        operational["evaluation_load_shedding_mwh"] <= 1.0e-6,
        "Summary_System_Hourly.csv evaluation rows",
    )
    _benchmark_check!(
        checks,
        "PCM",
        "transferred generation dispatched",
        "> 0",
        operational["evaluation_new_generation_dispatch_mwh"],
        ">",
        operational["evaluation_new_generation_dispatch_mwh"] > 0.0,
        "power_hourly.csv rows matched to realized Candidate_ID",
    )
    _benchmark_check!(
        checks,
        "PCM",
        "RPS slack",
        "<= 1.0e-6",
        _benchmark_metric(metrics, "pcm_rps_slack_mwh"),
        "<=",
        _benchmark_float(_benchmark_metric(metrics, "pcm_rps_slack_mwh")) <= 1.0e-6,
        "holistic_coverage.yml",
    )

    physical_contract = get(handoff, "physical_realization", Dict{String,Any}())
    topology = get(physical_contract, "topology", Dict{String,Any}())
    summary = Dict{String,Any}(
        "schema_version" => HOLISTIC_BENCHMARK_SCHEMA_VERSION,
        "artifact_type" => "HOPE.GTEP_PCM_benchmark",
        "run_id" => string(get(manifest, "request_id", basename(workspace))),
        "run_status" => string(get(manifest, "status", "")),
        "solver" => string(get(manifest, "solver", "")),
        "gtep_source_sha256" => string(get(manifest, "gtep_source_sha256", "")),
        "pcm_source_sha256" => string(get(manifest, "pcm_source_sha256", "")),
        "gtep_hours" => gtep_hours,
        "pcm_solve_hours" => solve_hours,
        "pcm_warmup_hours" => slice["warmup_hours"],
        "pcm_evaluation_hours" => slice["evaluation_hours"],
        "pcm_evaluation_start_hour" => slice["evaluation_start_hour"],
        "pcm_evaluation_end_hour" => slice["evaluation_end_hour"],
        "pcm_evaluation_month" => slice["evaluation_month"],
        "physical_nodes" => nrow(buses),
        "physical_branches" => nrow(branches),
        "planning_basis" => string(get(topology, "planning_basis", "")),
        "gtep_objective_usd" =>
            _benchmark_float(_benchmark_metric(metrics, "gtep_objective_value")),
        "pcm_objective_usd" =>
            _benchmark_float(_benchmark_metric(metrics, "pcm_objective_value")),
        "new_generation_mw" => _benchmark_float(expected_generation),
        "new_storage_power_mw" => _benchmark_float(expected_storage_power),
        "new_storage_energy_mwh" => _benchmark_float(expected_storage_energy),
        "retired_generation_mw" =>
            _benchmark_float(_benchmark_metric(metrics, "retired_generation_mw")),
        "line_forward_added_mw" =>
            _benchmark_float(_benchmark_metric(metrics, "line_forward_added_mw")),
        "line_reverse_added_mw" =>
            _benchmark_float(_benchmark_metric(metrics, "line_reverse_added_mw")),
        "pcm_upgraded_line_max_abs_flow_mw" => _benchmark_float(
            _benchmark_metric(metrics, "pcm_upgraded_line_max_abs_flow_mw"),
        ),
        "pcm_upgraded_line_flow_above_source_mw" => _benchmark_float(
            _benchmark_metric(metrics, "pcm_upgraded_line_flow_above_source_mw"),
        ),
        "realized_generator_rows" => nrow(realized_generators),
        "realized_storage_rows" => nrow(realized_storage),
        "pcm_rps_slack_mwh" =>
            _benchmark_float(_benchmark_metric(metrics, "pcm_rps_slack_mwh")),
        "comparison_policy" => Dict(
            "capacity_identity_siting_parameters" => "must_reconcile",
            "cost_dispatch_emissions" => "reported_not_equal_across_different_models_and_horizons",
        ),
    )
    merge!(summary, operational)
    _benchmark_expected_value_checks!(checks, summary, expected_path)
    summary["all_passed"] = all(checks.Passed)
    summary["passed_checks"] = count(checks.Passed)
    summary["total_checks"] = nrow(checks)

    mkpath(output_path)
    paths = Dict{String,String}(
        "summary_yaml" => joinpath(output_path, "benchmark_summary.yml"),
        "checks_csv" => joinpath(output_path, "benchmark_checks.csv"),
        "builds_csv" => joinpath(output_path, "build_decisions.csv"),
        "physical_realization_csv" => joinpath(output_path, "physical_realization.csv"),
        "retirements_csv" => joinpath(output_path, "retirements.csv"),
        "transmission_builds_csv" => joinpath(output_path, "transmission_builds.csv"),
        "report_markdown" => joinpath(output_path, "benchmark_report.md"),
    )
    open(paths["summary_yaml"], "w") do io
        YAML.write(io, summary)
    end
    CSV.write(paths["checks_csv"], checks)
    CSV.write(paths["builds_csv"], builds)
    CSV.write(paths["physical_realization_csv"], physical)
    CSV.write(paths["retirements_csv"], retirements)
    CSV.write(paths["transmission_builds_csv"], line_allocations)
    _benchmark_write_markdown(
        paths["report_markdown"],
        summary,
        checks,
        builds,
        physical,
        retirements,
        line_allocations,
    )
    if require_all && !summary["all_passed"]
        failed = join(checks[.!checks.Passed, :Check], ", ")
        report_path = paths["report_markdown"]
        throw(
            ErrorException(
                "GTEP-to-PCM benchmark failed: $(failed). Report: $(report_path)",
            ),
        )
    end
    return Dict("summary" => summary, "checks" => checks, "paths" => paths)
end
