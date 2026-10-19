const HOLISTIC_CONTRACT_SCHEMA_VERSION = 1
const HOLISTIC_PHYSICAL_SCHEMA_VERSION = 1

function _holistic_contract_checks()
    return DataFrame(
        Check = String[],
        Scope = String[],
        Severity = String[],
        Passed = Bool[],
        Evidence = String[],
    )
end

function _holistic_contract_add!(
    checks::DataFrame,
    check::AbstractString,
    scope::AbstractString,
    passed::Bool,
    evidence::AbstractString;
    severity::AbstractString = "error",
)
    push!(
        checks,
        (String(check), String(scope), String(severity), passed, String(evidence)),
    )
    return nothing
end

_holistic_contract_valid(checks::DataFrame) =
    all(row.Passed || row.Severity != "error" for row in eachrow(checks))

function _holistic_contract_nonblank_unique!(
    checks::DataFrame,
    table::AbstractDataFrame,
    column::AbstractString,
    scope::AbstractString;
    required::Bool = false,
)
    if !(column in names(table))
        _holistic_contract_add!(
            checks,
            "$(scope).$(column)",
            scope,
            !required,
            required ? "required column is missing" :
            "optional column is absent; legacy mapping remains available";
            severity = required ? "error" : "warning",
        )
        return Set{String}()
    end
    values = [value === missing ? "" : strip(string(value)) for value in table[!, column]]
    nonblank = all(value -> !isempty(value), values)
    unique_values = length(unique(values)) == length(values)
    passed = nonblank && unique_values
    evidence = "rows=$(length(values)); nonblank=$(nonblank); unique=$(unique_values)"
    _holistic_contract_add!(checks, "$(scope).$(column)", scope, passed, evidence)
    return passed ? Set(values) : Set{String}()
end

"""
    holistic_case_fingerprint(case_path, config) -> Dict{String,String}

Return SHA-256 hashes for every file under the case's configured `DataCase`
directory, keyed by portable relative path.
"""
function holistic_case_fingerprint(case_path::AbstractString, config::Dict)
    data_dir = normpath(joinpath(case_path, String(config["DataCase"])))
    isdir(data_dir) ||
        throw(ArgumentError("Holistic data directory not found: $(data_dir)"))
    hashes = Dict{String,String}()
    for (root, _, files) in walkdir(data_dir)
        for filename in sort(files)
            path = joinpath(root, filename)
            relative = replace(relpath(path, data_dir), '\\' => '/')
            hashes[relative] = bytes2hex(sha256(read(path)))
        end
    end
    return hashes
end

"""
    load_holistic_physical_realization(path) -> Dict

Load and validate a versioned `HOPE.physical_realization` YAML contract.
"""
function load_holistic_physical_realization(path::AbstractString)
    isfile(path) || throw(ArgumentError("Physical-realization contract not found: $(path)"))
    contract = YAML.load_file(path)
    contract isa AbstractDict ||
        throw(ArgumentError("Physical-realization contract must be a YAML mapping."))
    version = Int(get(contract, "schema_version", 0))
    version == HOLISTIC_PHYSICAL_SCHEMA_VERSION || throw(
        ArgumentError(
            "Unsupported physical-realization schema_version $(version); expected $(HOLISTIC_PHYSICAL_SCHEMA_VERSION).",
        ),
    )
    string(get(contract, "artifact_type", "")) == "HOPE.physical_realization" || throw(
        ArgumentError(
            "physical-realization artifact_type must be HOPE.physical_realization.",
        ),
    )
    return Dict{String,Any}(string(key) => value for (key, value) in contract)
end

function _holistic_contract_case_file(
    specification::AbstractDict,
    gtep_case::AbstractString,
    pcm_case::AbstractString,
)
    role = lowercase(string(get(specification, "case", "")))
    role in ("gtep", "pcm") ||
        throw(ArgumentError("Contract file reference case must be 'gtep' or 'pcm'."))
    relative = string(get(specification, "path", ""))
    isempty(strip(relative)) &&
        throw(ArgumentError("Contract file reference path is blank."))
    base = role == "gtep" ? gtep_case : pcm_case
    return normpath(joinpath(base, relative))
end

function _holistic_contract_bus_checks!(
    checks::DataFrame,
    gtep_input::Dict,
    pcm_input::Dict,
    contract::Dict,
)
    haskey(pcm_input, "Busdata") || begin
        _holistic_contract_add!(
            checks,
            "physical_bus_table",
            "physical_realization",
            false,
            "PCM input has no Busdata table",
        )
        return
    end
    busdata = pcm_input["Busdata"]
    topology = get(contract, "topology", Dict{String,Any}())
    expected_counts = get(topology, "expected_counts", Dict{String,Any}())
    actual_counts = Dict(
        "planning_nodes" =>
            haskey(gtep_input, "Zonedata") ? nrow(gtep_input["Zonedata"]) : 0,
        "physical_nodes" => nrow(busdata),
        "physical_branches" =>
            haskey(pcm_input, "Branchdata") ? nrow(pcm_input["Branchdata"]) : 0,
    )
    for (name, actual) in actual_counts
        haskey(expected_counts, name) || continue
        expected = Int(expected_counts[name])
        _holistic_contract_add!(
            checks,
            "$(name)_count",
            "physical_realization",
            actual == expected,
            "expected=$(expected); actual=$(actual)",
        )
    end
    required_bus_columns = ("Bus_id", "Zone_id")
    bus_columns_ok = all(column in names(busdata) for column in required_bus_columns)
    _holistic_contract_add!(
        checks,
        "physical_bus_columns",
        "physical_realization",
        bus_columns_ok,
        "required=$(join(required_bus_columns, ',')); available=$(join(names(busdata), ','))",
    )
    bus_columns_ok || return
    bus_ids = _holistic_contract_nonblank_unique!(
        checks,
        busdata,
        "Bus_id",
        "pcm.busdata";
        required = true,
    )
    bus_to_zone = Dict(
        strip(string(busdata[row, "Bus_id"])) => strip(string(busdata[row, "Zone_id"]))
        for row = 1:nrow(busdata)
    )

    siting = get(contract, "resource_siting", Dict{String,Any}())
    for (kind, table_key) in
        (("generation", "Gendata_candidate"), ("storage", "Estoragedata_candidate"))
        rule = get(siting, kind, Dict{String,Any}())
        method = lowercase(string(get(rule, "method", "legacy_zone")))
        supported = method in ("explicit_bus", "legacy_zone")
        _holistic_contract_add!(
            checks,
            "$(kind)_siting_method",
            "physical_realization",
            supported,
            "method=$(method); supported=explicit_bus|legacy_zone",
        )
        haskey(gtep_input, table_key) || continue
        candidates = gtep_input[table_key]
        if method == "explicit_bus"
            has_bus = "Bus_id" in names(candidates)
            _holistic_contract_add!(
                checks,
                "$(kind)_candidate_bus_column",
                "physical_realization",
                has_bus,
                has_bus ? "Bus_id is present" : "Bus_id is required by explicit_bus",
            )
            has_bus || continue
            candidate_buses = [strip(string(value)) for value in candidates[!, "Bus_id"]]
            missing = sort(unique([bus for bus in candidate_buses if !(bus in bus_ids)]))
            _holistic_contract_add!(
                checks,
                "$(kind)_candidate_bus_references",
                "physical_realization",
                isempty(missing),
                isempty(missing) ? "all $(length(candidate_buses)) candidate rows resolve" :
                "missing buses=$(join(missing, ','))",
            )
            planning_column = string(get(rule, "planning_zone_column", "Planning_Zone"))
            if planning_column in names(candidates)
                mismatches = String[]
                for row = 1:nrow(candidates)
                    bus = strip(string(candidates[row, "Bus_id"]))
                    haskey(bus_to_zone, bus) || continue
                    planning_zone = strip(string(candidates[row, planning_column]))
                    planning_zone == bus_to_zone[bus] || push!(
                        mismatches,
                        "row=$(row):$(planning_zone)!=$(bus_to_zone[bus])",
                    )
                end
                _holistic_contract_add!(
                    checks,
                    "$(kind)_planning_zone_consistency",
                    "physical_realization",
                    isempty(mismatches),
                    isempty(mismatches) ? "candidate buses agree with PCM bus zones" :
                    join(mismatches, ";"),
                )
            end
        end
    end
end

function _holistic_contract_line_checks!(
    checks::DataFrame,
    gtep_input::Dict,
    pcm_input::Dict,
    contract::Dict,
)
    transmission = get(contract, "transmission_realization", Dict{String,Any}())
    methods = lowercase.(string.(get(transmission, "method_priority", ["corridor_id"])))
    supported = Set(("corridor_id", "explicit_endpoints", "proportional_parallel_corridor"))
    unsupported = sort([method for method in methods if !(method in supported)])
    _holistic_contract_add!(
        checks,
        "transmission_methods",
        "physical_realization",
        isempty(unsupported),
        isempty(unsupported) ? "methods=$(join(methods, ','))" :
        "unsupported=$(join(unsupported, ','))",
    )
    haskey(gtep_input, "Linedata_candidate") || return
    candidates = gtep_input["Linedata_candidate"]
    target_key = haskey(pcm_input, "Branchdata") ? "Branchdata" : "Linedata"
    targets = pcm_input[target_key]
    target_corridors =
        "Corridor_ID" in names(targets) ? Set(strip.(string.(targets[!, "Corridor_ID"]))) :
        Set{String}()
    target_pairs = Set{Tuple{String,String}}()
    if target_key == "Branchdata" &&
       all(column in names(targets) for column in ("from_bus", "to_bus"))
        for row in eachrow(targets)
            from_bus, to_bus = strip(string(row["from_bus"])), strip(string(row["to_bus"]))
            push!(target_pairs, minmax(from_bus, to_bus))
        end
    end
    unresolved = Int[]
    for row = 1:nrow(candidates)
        resolved = false
        if "corridor_id" in methods && "Corridor_ID" in names(candidates)
            resolved = strip(string(candidates[row, "Corridor_ID"])) in target_corridors
        end
        if !resolved &&
           "explicit_endpoints" in methods &&
           all(column in names(candidates) for column in ("PCM_from_bus", "PCM_to_bus"))
            pair = minmax(
                strip(string(candidates[row, "PCM_from_bus"])),
                strip(string(candidates[row, "PCM_to_bus"])),
            )
            resolved = pair in target_pairs
        end
        resolved || push!(unresolved, row)
    end
    _holistic_contract_add!(
        checks,
        "transmission_candidate_targets",
        "physical_realization",
        isempty(unresolved),
        isempty(unresolved) ? "all $(nrow(candidates)) candidate corridors resolve" :
        "unresolved candidate rows=$(join(unresolved, ','))",
    )
end

function _holistic_contract_provenance_checks!(
    checks::DataFrame,
    contract::Dict,
    gtep_case::AbstractString,
    pcm_case::AbstractString,
)
    provenance = get(contract, "provenance", Dict{String,Any}())
    register = get(provenance, "source_register", nothing)
    if !(register isa AbstractDict)
        _holistic_contract_add!(
            checks,
            "provenance_source_register",
            "provenance",
            false,
            "provenance.source_register is required",
        )
        return
    end
    path = _holistic_contract_case_file(register, gtep_case, pcm_case)
    exists = isfile(path)
    _holistic_contract_add!(
        checks,
        "provenance_source_register",
        "provenance",
        exists,
        exists ? path : "missing=$(path)",
    )
    exists || return
    table = CSV.read(path, DataFrame)
    required = Set(("Dataset", "Role", "Source", "License_or_terms", "Transformation"))
    missing = sort(collect(setdiff(required, Set(names(table)))))
    _holistic_contract_add!(
        checks,
        "provenance_source_register_columns",
        "provenance",
        isempty(missing),
        isempty(missing) ? "rows=$(nrow(table))" : "missing=$(join(missing, ','))",
    )
end

function _holistic_contract_identity_checks!(
    checks::DataFrame,
    gtep_input::Dict,
    pcm_input::Dict,
)
    gtep_generators = gtep_input["Gendata"]
    pcm_generators = pcm_input["Gendata"]
    gtep_has_assets = "Asset_ID" in names(gtep_generators)
    pcm_has_assets = "Asset_ID" in names(pcm_generators)
    paired = gtep_has_assets == pcm_has_assets
    _holistic_contract_add!(
        checks,
        "existing_asset_identity_mode",
        "identity",
        paired,
        paired ?
        (
            gtep_has_assets ? "Asset_ID supplied on both stages" :
            "legacy validated mapping"
        ) : "Asset_ID is present on only one stage",
    )
    if paired && gtep_has_assets
        gtep_ids = _holistic_contract_nonblank_unique!(
            checks,
            gtep_generators,
            "Asset_ID",
            "gtep.gendata";
            required = true,
        )
        pcm_ids = _holistic_contract_nonblank_unique!(
            checks,
            pcm_generators,
            "Asset_ID",
            "pcm.gendata";
            required = true,
        )
        missing = sort(collect(setdiff(gtep_ids, pcm_ids)))
        _holistic_contract_add!(
            checks,
            "existing_asset_crosswalk",
            "identity",
            isempty(missing),
            isempty(missing) ? "all $(length(gtep_ids)) GTEP assets resolve in PCM" :
            "missing PCM Asset_ID=$(join(missing, ','))",
        )
    end
    for (scope, key) in (
        ("gtep.generation_candidates", "Gendata_candidate"),
        ("gtep.storage_candidates", "Estoragedata_candidate"),
    )
        haskey(gtep_input, key) || continue
        _holistic_contract_nonblank_unique!(
            checks,
            gtep_input[key],
            "Candidate_ID",
            scope;
            required = false,
        )
    end
end

function _holistic_contract_resource_realization_checks!(
    checks::DataFrame,
    gtep_input::Dict,
    contract::Dict,
)
    if haskey(gtep_input, "Gendata_candidate")
        candidates = gtep_input["Gendata_candidate"]
        if "PCM_Unit_Size_MW" in names(candidates)
            invalid = Int[]
            configured = 0
            for row = 1:nrow(candidates)
                value = candidates[row, "PCM_Unit_Size_MW"]
                (ismissing(value) || isempty(strip(string(value)))) && continue
                configured += 1
                parsed = try
                    Float64(value)
                catch
                    tryparse(Float64, strip(string(value)))
                end
                (parsed isa Real && isfinite(parsed) && parsed > 0.0) || push!(invalid, row)
            end
            _holistic_contract_add!(
                checks,
                "generation_physical_unit_sizes",
                "physical_realization",
                isempty(invalid),
                isempty(invalid) ? "configured candidate rows=$(configured)" :
                "PCM_Unit_Size_MW must be positive at candidate rows=$(join(invalid, ','))",
            )
        end
    end

    retirement = get(contract, "retirement_realization", nothing)
    retirement isa AbstractDict || return
    method = lowercase(strip(string(get(retirement, "method", "proportional_capacity"))))
    supported_methods =
        ("proportional_capacity", "largest_first", "smallest_first", "priority")
    method_valid = method in supported_methods
    _holistic_contract_add!(
        checks,
        "retirement_realization_method",
        "physical_realization",
        method_valid,
        "method=$(method); supported=$(join(supported_methods, '|'))",
    )
    partial_policy = lowercase(
        strip(string(get(retirement, "partial_unit_policy", "allow_capacity_reduction"))),
    )
    partial_valid = partial_policy in ("allow_capacity_reduction", "reject")
    _holistic_contract_add!(
        checks,
        "retirement_partial_unit_policy",
        "physical_realization",
        partial_valid,
        "partial_unit_policy=$(partial_policy); supported=allow_capacity_reduction|reject",
    )
    method_valid || return
    if method == "priority"
        priority_column =
            strip(string(get(retirement, "priority_column", "Retirement_Priority")))
        raw_generators = get(gtep_input, "GendataRaw", gtep_input["Gendata"])
        has_priority = priority_column in names(raw_generators)
        _holistic_contract_add!(
            checks,
            "retirement_priority_column",
            "physical_realization",
            has_priority,
            has_priority ? "column=$(priority_column)" :
            "missing raw GTEP generator column=$(priority_column)",
        )
        has_priority || return
        invalid = Int[]
        for row = 1:nrow(raw_generators)
            value = raw_generators[row, priority_column]
            parsed = try
                Float64(value)
            catch
                tryparse(Float64, strip(string(value)))
            end
            (parsed isa Real && isfinite(parsed)) || push!(invalid, row)
        end
        _holistic_contract_add!(
            checks,
            "retirement_priority_values",
            "physical_realization",
            isempty(invalid),
            isempty(invalid) ? "all $(nrow(raw_generators)) values are finite" :
            "non-numeric or non-finite rows=$(join(invalid, ','))",
        )
    end
end

"""
    validate_holistic_handoff_contract(gtep_case, pcm_case; kwargs...) -> Dict

Validate topology, identity, physical realization, provenance, and source
fingerprints for a GTEP-to-PCM pair without invoking an optimizer. The
six-positional-argument method accepts already loaded configurations and input
dictionaries for tests and orchestrated workflows.
"""
function validate_holistic_handoff_contract(
    gtep_case::AbstractString,
    gtep_config::Dict,
    gtep_input::Dict,
    pcm_case::AbstractString,
    pcm_config::Dict,
    pcm_input::Dict;
    physical_contract = nothing,
    require_valid::Bool = true,
)
    checks = _holistic_contract_checks()
    topology_error = try
        validate_holistic_case_pair!(
            gtep_case,
            gtep_config,
            gtep_input,
            pcm_case,
            pcm_config,
            pcm_input,
        )
        nothing
    catch error
        error
    end
    _holistic_contract_add!(
        checks,
        "topology_compatibility",
        "topology",
        topology_error === nothing,
        topology_error === nothing ?
        "configured spatial bases and corridors are compatible" :
        sprint(showerror, topology_error),
    )
    _holistic_contract_identity_checks!(checks, gtep_input, pcm_input)

    contract = physical_contract
    if contract isa AbstractString
        contract = load_holistic_physical_realization(contract)
    elseif contract === nothing
        contract_path = joinpath(gtep_case, "Settings", "HOPE_physical_realization.yml")
        contract =
            isfile(contract_path) ? load_holistic_physical_realization(contract_path) :
            nothing
    elseif contract isa AbstractDict
        contract = Dict{String,Any}(string(key) => value for (key, value) in contract)
    else
        throw(ArgumentError("physical_contract must be a path, mapping, or nothing."))
    end

    _holistic_contract_add!(
        checks,
        "physical_realization_contract",
        "physical_realization",
        true,
        contract === nothing ? "not declared; legacy linkage rules apply" :
        "schema_version=$(get(contract, "schema_version", "missing"))";
        severity = contract === nothing ? "warning" : "error",
    )
    if contract !== nothing
        valid_header =
            Int(get(contract, "schema_version", 0)) == HOLISTIC_PHYSICAL_SCHEMA_VERSION &&
            string(get(contract, "artifact_type", "")) == "HOPE.physical_realization" &&
            string(get(contract, "workflow", "")) == "GTEP-PCM"
        _holistic_contract_add!(
            checks,
            "physical_realization_header",
            "physical_realization",
            valid_header,
            "schema_version=$(get(contract, "schema_version", "missing")); artifact_type=$(get(contract, "artifact_type", "missing")); workflow=$(get(contract, "workflow", "missing"))",
        )
        _holistic_contract_bus_checks!(checks, gtep_input, pcm_input, contract)
        _holistic_contract_line_checks!(checks, gtep_input, pcm_input, contract)
        _holistic_contract_resource_realization_checks!(checks, gtep_input, contract)
        _holistic_contract_provenance_checks!(checks, contract, gtep_case, pcm_case)
    end

    report = Dict{String,Any}(
        "schema_version" => HOLISTIC_CONTRACT_SCHEMA_VERSION,
        "workflow" => "GTEP-PCM",
        "valid" => _holistic_contract_valid(checks),
        "checks" => checks,
        "source_fingerprints" => Dict(
            "gtep" => holistic_case_fingerprint(gtep_case, gtep_config),
            "pcm" => holistic_case_fingerprint(pcm_case, pcm_config),
        ),
        "physical_realization" => contract,
    )
    if require_valid && !report["valid"]
        failed = join(checks.Check[(checks.Severity.=="error").&.!checks.Passed], ", ")
        throw(ArgumentError("Holistic handoff contract validation failed: $(failed)."))
    end
    return report
end

function validate_holistic_handoff_contract(
    gtep_case::AbstractString,
    pcm_case::AbstractString;
    physical_contract = nothing,
    require_valid::Bool = true,
)
    gtep_path, gtep_config = load_case_config_for_holistic(
        gtep_case;
        context = "validate_holistic_handoff_contract",
    )
    pcm_path, pcm_config = load_case_config_for_holistic(
        pcm_case;
        context = "validate_holistic_handoff_contract",
    )
    return validate_holistic_handoff_contract(
        gtep_path,
        gtep_config,
        load_data(gtep_config, gtep_path),
        pcm_path,
        pcm_config,
        load_data(pcm_config, pcm_path);
        physical_contract = physical_contract,
        require_valid = require_valid,
    )
end

"""
    validate_holistic_source_immutability!(report, gtep_after, pcm_after; require_valid=true)

Append source-integrity checks by comparing post-run fingerprints with the
preflight fingerprints stored in `report`.
"""
function validate_holistic_source_immutability!(
    report::Dict,
    gtep_after::AbstractDict,
    pcm_after::AbstractDict;
    require_valid::Bool = true,
)
    checks = report["checks"]
    before = report["source_fingerprints"]
    for (role, after) in (("gtep", gtep_after), ("pcm", pcm_after))
        unchanged = before[role] == after
        _holistic_contract_add!(
            checks,
            "$(role)_source_immutability",
            "source_integrity",
            unchanged,
            unchanged ? "all $(length(after)) source-data files unchanged" :
            "source-data fingerprint changed",
        )
    end
    report["valid"] = _holistic_contract_valid(checks)
    if require_valid && !report["valid"]
        throw(ErrorException("Holistic workflow modified a source input file."))
    end
    return report
end

"""
    write_holistic_handoff_contract_report(output_path, report) -> Dict

Write the handoff contract and its tabular checks under
`output_path/realized_inputs`.
"""
function write_holistic_handoff_contract_report(output_path::AbstractString, report::Dict)
    data_dir = joinpath(output_path, "realized_inputs")
    mkpath(data_dir)
    csv_path = joinpath(data_dir, "handoff_contract_checks.csv")
    yaml_path = joinpath(data_dir, "handoff_contract.yml")
    CSV.write(csv_path, report["checks"])
    document = Dict{String,Any}(
        "schema_version" => report["schema_version"],
        "workflow" => report["workflow"],
        "valid" => report["valid"],
        "source_fingerprints" => report["source_fingerprints"],
        "physical_realization" => report["physical_realization"],
        "checks" => [
            Dict(string(name) => row[name] for name in names(report["checks"])) for
            row in eachrow(report["checks"])
        ],
    )
    open(yaml_path, "w") do io
        YAML.write(io, document)
    end
    paths = Dict("checks_csv" => csv_path, "contract_yaml" => yaml_path)
    report["paths"] = paths
    return paths
end
