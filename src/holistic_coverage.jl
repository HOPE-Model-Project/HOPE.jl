function _holistic_container_values(model::JuMP.Model, name::Symbol)
    haskey(JuMP.object_dictionary(model), name) || return Float64[]
    object = model[name]
    values_out = Float64[]
    for item in object
        value_out = try
            JuMP.value(item)
        catch
            continue
        end
        isfinite(value_out) && push!(values_out, Float64(value_out))
    end
    return values_out
end

function _holistic_sum(model::JuMP.Model, names::Vector{Symbol}; absolute::Bool = false)
    total = 0.0
    for name in names
        values_out = _holistic_container_values(model, name)
        total += absolute ? sum(abs, values_out) : sum(values_out)
    end
    return total
end

function _holistic_max_abs(model::JuMP.Model, name::Symbol)
    values_out = _holistic_container_values(model, name)
    return isempty(values_out) ? 0.0 : maximum(abs, values_out)
end

function holistic_model_activity_metrics(model::JuMP.Model, stage::AbstractString)
    prefix = lowercase(String(stage))
    return Dict{String,Any}(
        "$(prefix)_termination_status" => string(JuMP.termination_status(model)),
        "$(prefix)_primal_status" => string(JuMP.primal_status(model)),
        "$(prefix)_objective_value" => try
            JuMP.objective_value(model)
        catch
            NaN
        end,
        "$(prefix)_load_shedding_mwh" => _holistic_sum(model, [:p_LS]),
        "$(prefix)_dr_deferred_mwh" => _holistic_sum(model, [:dr_DF]),
        "$(prefix)_dr_payback_mwh" => _holistic_sum(model, [:dr_PB]),
        "$(prefix)_operating_reserve_mwh" => _holistic_sum(
            model,
            [
                :r_G_REG_UP,
                :r_G_REG_DN,
                :r_G_SPIN,
                :r_G_NSPIN,
                :r_S_REG_UP,
                :r_S_REG_DN,
                :r_S_SPIN,
                :r_S_NSPIN,
            ],
        ),
        "$(prefix)_transmission_loss_mwh" => _holistic_sum(model, [:LineLoss]),
        "$(prefix)_rps_slack_mwh" => _holistic_sum(model, [:pt_rps]),
        "$(prefix)_carbon_slack_tons" => _holistic_sum(model, [:em_emis]),
        "$(prefix)_commitment_on_hours" => _holistic_sum(model, [:o]),
        "$(prefix)_startup_count" => _holistic_sum(model, [:u]),
        "$(prefix)_shutdown_count" => _holistic_sum(model, [:v]),
        "$(prefix)_max_abs_line_flow_mw" => _holistic_max_abs(model, :f),
    )
end

function _holistic_rows_for_ids(table::AbstractDataFrame, ids::Set{String})
    isempty(ids) && return Int[]
    "Asset_ID" in names(table) || return Int[]
    return [row for row = 1:nrow(table) if string(table[row, "Asset_ID"]) in ids]
end

function _holistic_selected_sum(model::JuMP.Model, name::Symbol, rows::Vector{Int})
    isempty(rows) && return 0.0
    haskey(JuMP.object_dictionary(model), name) || return 0.0
    object = model[name]
    total = 0.0
    for row in rows
        for h in axes(object, 2)
            total += JuMP.value(object[row, h])
        end
    end
    return total
end

function _holistic_upgraded_line_metrics(
    model::JuMP.Model,
    updated_input::Dict,
    source_input::Dict,
    pcm_config::Dict,
)
    audit = get(
        get(updated_input, "LinkageAudit", Dict{String,Any}()),
        "line_allocations",
        DataFrame(),
    )
    nrow(audit) == 0 && return (0.0, 0.0)
    haskey(JuMP.object_dictionary(model), :f) || return (0.0, 0.0)
    line_key =
        Int(get(pcm_config, "network_model", 0)) in (2, 3) &&
        haskey(source_input, "Branchdata") ? "Branchdata" : "Linedata"
    source_lines = source_input[line_key]
    flow = model[:f]
    max_flow = 0.0
    max_above_source = -Inf
    for target in unique(Int.(audit.TargetRow))
        target in axes(flow, 1) || continue
        row_flow = maximum(abs(JuMP.value(flow[target, h])) for h in axes(flow, 2))
        forward = Float64(source_lines[target, Symbol("Forward Capacity (MW)")])
        reverse = Float64(source_lines[target, Symbol("Reverse Capacity (MW)")])
        max_flow = max(max_flow, row_flow)
        max_above_source = max(max_above_source, row_flow - max(forward, reverse))
    end
    return max_flow, isfinite(max_above_source) ? max_above_source : 0.0
end

function holistic_coverage_metrics(result::Dict)
    updated_input = result["pcm_input"]
    model = result["pcm_solved_model"]
    pcm_config = result["pcm_config"]
    source_input = load_data(pcm_config, result["pcm_case_path"])
    audit = get(updated_input, "LinkageAudit", Dict{String,Any}())
    generation = get(audit, "generation_builds", DataFrame())
    storage = get(audit, "storage_builds", DataFrame())
    generation_ids =
        nrow(generation) == 0 ? Set{String}() : Set(string.(generation.RealizedAssetID))
    storage_ids = nrow(storage) == 0 ? Set{String}() : Set(string.(storage.RealizedAssetID))
    generation_rows = _holistic_rows_for_ids(updated_input["Gendata"], generation_ids)
    storage_rows = _holistic_rows_for_ids(updated_input["Storagedata"], storage_ids)
    upgraded_flow, upgraded_above_source =
        _holistic_upgraded_line_metrics(model, updated_input, source_input, pcm_config)

    metrics = Dict{String,Any}()
    merge!(metrics, Dict(string(k) => v for (k, v) in result["transfer_summary"]))
    merge!(metrics, get(result, "gtep_activity", Dict{String,Any}()))
    merge!(
        metrics,
        get(result, "pcm_activity", holistic_model_activity_metrics(model, "pcm")),
    )
    metrics["pcm_new_generation_dispatch_mwh"] =
        _holistic_selected_sum(model, :p, generation_rows)
    metrics["pcm_new_storage_charge_mwh"] = _holistic_selected_sum(model, :c, storage_rows)
    metrics["pcm_new_storage_discharge_mwh"] =
        _holistic_selected_sum(model, :dc, storage_rows)
    metrics["pcm_upgraded_line_max_abs_flow_mw"] = upgraded_flow
    metrics["pcm_upgraded_line_flow_above_source_mw"] = upgraded_above_source
    metrics["source_gtep_unchanged"] =
        get(result, "source_gtep_hashes_before", Dict()) ==
        get(result, "source_gtep_hashes_after", Dict())
    metrics["source_pcm_unchanged"] =
        get(result, "source_pcm_hashes_before", Dict()) ==
        get(result, "source_pcm_hashes_after", Dict())
    return metrics
end

function _holistic_equivalent_setting(actual, expected)
    actual == expected && return true
    return string(actual) == string(expected)
end

function _holistic_acceptance_checks(
    metrics::Dict{String,Any},
    gtep_config::Dict,
    pcm_config::Dict,
    expectations::Dict,
)
    checks = DataFrame(
        Stage = String[],
        Check = String[],
        Actual = String[],
        Comparator = String[],
        Expected = String[],
        Passed = Bool[],
    )
    required_settings = get(expectations, "required_settings", Dict{String,Any}())
    for (stage, config) in (("gtep", gtep_config), ("pcm", pcm_config))
        for (key, expected) in get(required_settings, stage, Dict{String,Any}())
            actual = get(config, String(key), missing)
            push!(
                checks,
                (
                    stage,
                    "setting.$(key)",
                    string(actual),
                    "==",
                    string(expected),
                    _holistic_equivalent_setting(actual, expected),
                ),
            )
        end
    end
    for (metric_name, rule) in get(expectations, "thresholds", Dict{String,Any}())
        key = String(metric_name)
        actual = get(metrics, key, missing)
        if haskey(rule, "minimum")
            expected = Float64(rule["minimum"])
            passed = actual !== missing && Float64(actual) >= expected
            push!(checks, ("holistic", key, string(actual), ">=", string(expected), passed))
        end
        if haskey(rule, "maximum")
            expected = Float64(rule["maximum"])
            passed = actual !== missing && Float64(actual) <= expected
            push!(checks, ("holistic", key, string(actual), "<=", string(expected), passed))
        end
    end
    return checks
end

_coverage_flag(value::Bool) = value ? "true" : "false"

function _holistic_coverage_table(metrics::Dict, gtep_config::Dict, pcm_config::Dict)
    table = DataFrame(
        Stage = String[],
        Feature = String[],
        Configured = String[],
        Populated = String[],
        Exercised = String[],
        Restrictive = String[],
        Transferred = String[],
        Consumed = String[],
        Evidence = String[],
    )
    function add(
        stage,
        feature;
        configured,
        populated,
        exercised,
        restrictive = "not_measured",
        transferred = "not_applicable",
        consumed = "not_applicable",
        evidence = "",
    )
        push!(
            table,
            (
                String(stage),
                String(feature),
                configured isa Bool ? _coverage_flag(configured) : String(configured),
                populated isa Bool ? _coverage_flag(populated) : String(populated),
                exercised isa Bool ? _coverage_flag(exercised) : String(exercised),
                restrictive isa Bool ? _coverage_flag(restrictive) : String(restrictive),
                transferred isa Bool ? _coverage_flag(transferred) : String(transferred),
                consumed isa Bool ? _coverage_flag(consumed) : String(consumed),
                String(evidence),
            ),
        )
    end

    retired = Float64(get(metrics, "retired_generation_mw", 0.0))
    new_gen = Float64(get(metrics, "new_generation_mw", 0.0))
    new_storage = Float64(get(metrics, "new_storage_power_mw", 0.0))
    new_line = Float64(get(metrics, "line_forward_added_mw", 0.0))
    new_gen_dispatch = Float64(get(metrics, "pcm_new_generation_dispatch_mwh", 0.0))
    new_storage_discharge = Float64(get(metrics, "pcm_new_storage_discharge_mwh", 0.0))
    line_above_source = Float64(get(metrics, "pcm_upgraded_line_flow_above_source_mw", 0.0))

    add(
        "GTEP-PCM",
        "retirement_transfer";
        configured = true,
        populated = retired > 0,
        exercised = retired > 0,
        restrictive = retired > 0,
        transferred = retired > 0,
        consumed = retired > 0,
        evidence = "retired_generation_mw=$(retired)",
    )
    add(
        "GTEP-PCM",
        "generation_build_transfer";
        configured = true,
        populated = new_gen > 0,
        exercised = new_gen > 0,
        restrictive = new_gen > 0,
        transferred = new_gen > 0,
        consumed = new_gen_dispatch > 0,
        evidence = "build_mw=$(new_gen); pcm_dispatch_mwh=$(new_gen_dispatch)",
    )
    add(
        "GTEP-PCM",
        "storage_build_transfer";
        configured = true,
        populated = new_storage > 0,
        exercised = new_storage > 0,
        restrictive = new_storage > 0,
        transferred = new_storage > 0,
        consumed = new_storage_discharge > 0,
        evidence = "build_mw=$(new_storage); pcm_discharge_mwh=$(new_storage_discharge)",
    )
    add(
        "GTEP-PCM",
        "transmission_build_transfer";
        configured = true,
        populated = new_line > 0,
        exercised = new_line > 0,
        restrictive = new_line > 0,
        transferred = new_line > 0,
        consumed = line_above_source > 0,
        evidence = "added_mw=$(new_line); flow_above_source_mw=$(line_above_source)",
    )
    unchanged =
        Bool(get(metrics, "source_gtep_unchanged", false)) &&
        Bool(get(metrics, "source_pcm_unchanged", false))
    add(
        "GTEP-PCM",
        "source_case_immutability";
        configured = true,
        populated = true,
        exercised = true,
        restrictive = "not_applicable",
        transferred = "not_applicable",
        consumed = unchanged,
        evidence = "gtep_unchanged=$(get(metrics, "source_gtep_unchanged", false)); pcm_unchanged=$(get(metrics, "source_pcm_unchanged", false))",
    )

    add(
        "GTEP",
        "binary_investment";
        configured = get(gtep_config, "inv_dcs_bin", 0) == 1,
        populated = true,
        exercised = new_gen + new_storage + new_line > 0,
        restrictive = new_gen + new_storage + new_line > 0,
    )
    add(
        "GTEP",
        "zonal_planning_reserve";
        configured = get(gtep_config, "planning_reserve_mode", 0) == 2,
        populated = true,
        exercised = new_gen + new_storage > 0,
    )
    add(
        "GTEP",
        "operating_reserve";
        configured = get(gtep_config, "operation_reserve_mode", 0) == 1,
        populated = true,
        exercised = Float64(get(metrics, "gtep_operating_reserve_mwh", 0.0)) > 0,
        restrictive = Float64(get(metrics, "gtep_operating_reserve_mwh", 0.0)) > 0,
        evidence = "reserve_mwh=$(get(metrics, "gtep_operating_reserve_mwh", 0.0))",
    )
    add(
        "GTEP",
        "clean_energy_policy";
        configured = get(gtep_config, "clean_energy_policy", 0) != 0,
        populated = true,
        exercised = Float64(get(metrics, "gtep_rps_slack_mwh", 0.0)) >= 0,
        evidence = "rps_slack_mwh=$(get(metrics, "gtep_rps_slack_mwh", 0.0))",
    )
    add(
        "GTEP",
        "flexible_demand";
        configured = get(gtep_config, "flexible_demand", 0) == 1,
        populated = true,
        exercised = Float64(get(metrics, "gtep_dr_deferred_mwh", 0.0)) > 0,
        restrictive = Float64(get(metrics, "gtep_dr_deferred_mwh", 0.0)) > 0,
        evidence = "deferred_mwh=$(get(metrics, "gtep_dr_deferred_mwh", 0.0))",
    )
    add(
        "GTEP",
        "transmission_loss";
        configured = get(gtep_config, "transmission_loss", 0) == 1,
        populated = true,
        exercised = Float64(get(metrics, "gtep_transmission_loss_mwh", 0.0)) > 0,
        restrictive = Float64(get(metrics, "gtep_transmission_loss_mwh", 0.0)) > 0,
        evidence = "loss_mwh=$(get(metrics, "gtep_transmission_loss_mwh", 0.0))",
    )

    add(
        "PCM",
        "nodal_angle_dcopf";
        configured = get(pcm_config, "network_model", 0) == 2,
        populated = true,
        exercised = Float64(get(metrics, "pcm_max_abs_line_flow_mw", 0.0)) > 0,
        evidence = "max_abs_flow_mw=$(get(metrics, "pcm_max_abs_line_flow_mw", 0.0))",
    )
    add(
        "PCM",
        "unit_commitment";
        configured = get(pcm_config, "unit_commitment", 0) == 1,
        populated = true,
        exercised = Float64(get(metrics, "pcm_commitment_on_hours", 0.0)) > 0,
        restrictive = "not_measured",
        evidence = "on_hours=$(get(metrics, "pcm_commitment_on_hours", 0.0)); starts=$(get(metrics, "pcm_startup_count", 0.0))",
    )
    add(
        "PCM",
        "operating_reserve";
        configured = get(pcm_config, "operation_reserve_mode", 0) == 2,
        populated = true,
        exercised = Float64(get(metrics, "pcm_operating_reserve_mwh", 0.0)) > 0,
        restrictive = Float64(get(metrics, "pcm_operating_reserve_mwh", 0.0)) > 0,
        evidence = "reserve_mwh=$(get(metrics, "pcm_operating_reserve_mwh", 0.0))",
    )
    add(
        "PCM",
        "clean_energy_policy";
        configured = get(pcm_config, "clean_energy_policy", 0) != 0,
        populated = true,
        exercised = Float64(get(metrics, "pcm_rps_slack_mwh", 0.0)) >= 0,
        restrictive = "not_measured",
        evidence = "rps_slack_mwh=$(get(metrics, "pcm_rps_slack_mwh", 0.0))",
    )
    add(
        "PCM",
        "flexible_demand";
        configured = get(pcm_config, "flexible_demand", 0) == 1,
        populated = true,
        exercised = Float64(get(metrics, "pcm_dr_deferred_mwh", 0.0)) > 0,
        restrictive = Float64(get(metrics, "pcm_dr_deferred_mwh", 0.0)) > 0,
        evidence = "deferred_mwh=$(get(metrics, "pcm_dr_deferred_mwh", 0.0))",
    )
    add(
        "PCM",
        "transmission_loss";
        configured = get(pcm_config, "transmission_loss", 0) == 1,
        populated = true,
        exercised = Float64(get(metrics, "pcm_transmission_loss_mwh", 0.0)) > 0,
        restrictive = Float64(get(metrics, "pcm_transmission_loss_mwh", 0.0)) > 0,
        evidence = "loss_mwh=$(get(metrics, "pcm_transmission_loss_mwh", 0.0))",
    )
    return table
end

function write_holistic_coverage_report(
    result::Dict,
    expectations_path::AbstractString;
    require_all::Bool = true,
)
    expectations = YAML.load_file(expectations_path)
    metrics = holistic_coverage_metrics(result)
    gtep_config = result["gtep"]["config"]
    pcm_config = result["pcm_config"]
    checks = _holistic_acceptance_checks(metrics, gtep_config, pcm_config, expectations)
    coverage = _holistic_coverage_table(metrics, gtep_config, pcm_config)
    all_passed = all(checks.Passed)
    outpath = result["pcm_output_path"]
    csv_path = joinpath(outpath, "holistic_coverage.csv")
    yaml_path = joinpath(outpath, "holistic_coverage.yml")
    checks_path = joinpath(outpath, "holistic_acceptance_checks.csv")
    CSV.write(csv_path, coverage)
    CSV.write(checks_path, checks)
    document = Dict{String,Any}(
        "schema_version" => 1,
        "workflow" => "GTEP-PCM",
        "all_passed" => all_passed,
        "metrics" => metrics,
        "checks" => [
            Dict(string(name) => row[name] for name in names(checks)) for
            row in eachrow(checks)
        ],
        "coverage" => [
            Dict(string(name) => row[name] for name in names(coverage)) for
            row in eachrow(coverage)
        ],
    )
    open(yaml_path, "w") do io
        YAML.write(io, document)
    end
    result["holistic_coverage"] = document
    result["holistic_coverage_paths"] = Dict(
        "coverage_csv" => csv_path,
        "coverage_yaml" => yaml_path,
        "checks_csv" => checks_path,
    )
    if require_all && !all_passed
        failed = join(checks.Check[.!checks.Passed], ", ")
        throw(
            ErrorException(
                "Holistic acceptance checks failed: $(failed). See $(checks_path).",
            ),
        )
    end
    return Dict(
        "all_passed" => all_passed,
        "metrics" => metrics,
        "checks" => checks,
        "coverage" => coverage,
        "paths" => result["holistic_coverage_paths"],
    )
end
