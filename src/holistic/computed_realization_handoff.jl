"""Adapters between solved GTEP outputs, computed siting, and the PCM handoff."""

function _computed_required_key(mapping::AbstractDict, key::AbstractString, label)
    haskey(mapping, key) || throw(ArgumentError("$(label) is missing key $(key)."))
    return mapping[key]
end

function _computed_source_id(table::AbstractDataFrame, row::Int, prefix::AbstractString)
    return _holistic_id(table, row, HOLISTIC_CANDIDATE_ID, "$(prefix)_$(row)")
end

"""
    capacity_plan_from_gtep(gtep_output, gtep_input; atol=1e-6)

Convert positive solved generation and storage decisions into the compact,
immutable `HOPE.capacity_plan` table consumed by computed realization. Candidate
identities are retained as `Plan_Item_ID` values.
"""
function capacity_plan_from_gtep(
    gtep_output::AbstractDict,
    gtep_input::AbstractDict;
    atol::Float64 = 1e-6,
)
    generation_input = _computed_required_key(gtep_input, "Gendata_candidate", "GTEP input")
    storage_input =
        _computed_required_key(gtep_input, "Estoragedata_candidate", "GTEP input")
    generation_output = _holistic_candidate_output_rows(
        _computed_required_key(gtep_output, "capacity", "GTEP output"),
        nrow(generation_input),
        "Generation",
    )
    storage_output = _holistic_candidate_output_rows(
        _computed_required_key(gtep_output, "es_capacity", "GTEP output"),
        nrow(storage_input),
        "Storage",
    )

    plan = DataFrame(
        Plan_Item_ID = String[],
        Resource_Kind = String[],
        Zone = String[],
        Type = String[],
        Build_MW = Float64[],
        Build_MWh = Float64[],
    )
    for row = 1:nrow(generation_input)
        built = to_float_output(generation_output[row, Symbol("Capacity_FIN (MW)")], 0.0)
        is_new = to_float_output(generation_output[row, "New_Build"], 0.0) > 0.0
        is_new && built > atol || continue
        push!(
            plan,
            (
                _computed_source_id(generation_input, row, "GTEP_GEN_CANDIDATE"),
                "generation",
                _holistic_id(
                    generation_input,
                    row,
                    "Planning_Zone",
                    string(generation_input[row, "Zone"]),
                ),
                string(generation_input[row, "Type"]),
                built,
                0.0,
            ),
        )
    end
    for row = 1:nrow(storage_input)
        built = to_float_output(storage_output[row, Symbol("Capacity (MW)")], 0.0)
        energy = to_float_output(storage_output[row, Symbol("EnergyCapacity (MWh)")], 0.0)
        is_new = to_float_output(storage_output[row, "New_Build"], 0.0) > 0.0
        is_new && built > atol || continue
        storage_id = _computed_source_id(storage_input, row, "GTEP_STORAGE_CANDIDATE")
        energy > atol || throw(
            ArgumentError(
                "Built storage candidate $(storage_id) has nonpositive energy capacity.",
            ),
        )
        push!(
            plan,
            (
                _computed_source_id(storage_input, row, "GTEP_STORAGE_CANDIDATE"),
                "storage",
                _holistic_id(
                    storage_input,
                    row,
                    "Planning_Zone",
                    string(storage_input[row, "Zone"]),
                ),
                string(storage_input[row, "Type"]),
                built,
                energy,
            ),
        )
    end
    isempty(plan.Plan_Item_ID) && return plan
    validate_capacity_plan(plan; atol = atol)
    sort!(plan, :Plan_Item_ID)
    return plan
end

function _computed_incident_capacity(branchdata::AbstractDataFrame)
    totals = Dict{String,Float64}()
    isempty(branchdata) && return totals
    all(column -> column in names(branchdata), ("from_bus", "to_bus")) || return totals
    for row in eachrow(branchdata)
        forward =
            "Forward Capacity (MW)" in names(branchdata) ?
            to_float_output(row["Forward Capacity (MW)"], 0.0) : 0.0
        reverse =
            "Reverse Capacity (MW)" in names(branchdata) ?
            to_float_output(row["Reverse Capacity (MW)"], 0.0) : 0.0
        rating = max(forward, reverse, 0.0)
        for column in ("from_bus", "to_bus")
            bus = strip(string(row[column]))
            isempty(bus) || (totals[bus] = get(totals, bus, 0.0) + rating)
        end
    end
    return totals
end

"""
    build_candidate_site_catalog_from_pcm(generation_candidates,
        storage_candidates, pcm_gendata, pcm_busdata; branchdata=DataFrame(),
        sites_per_zone=3)

Build a conservative topology-screened catalog from existing PCM buses. Within
each planning zone it keeps the strongest existing-generation/interconnection
buses, ranked by installed generation and incident branch rating. Resource
quality is deliberately neutral: this builder does not invent land, queue, or
renewable-resource evidence.
"""
function build_candidate_site_catalog_from_pcm(
    generation_candidates::AbstractDataFrame,
    storage_candidates::AbstractDataFrame,
    pcm_gendata::AbstractDataFrame,
    pcm_busdata::AbstractDataFrame;
    branchdata::AbstractDataFrame = DataFrame(),
    sites_per_zone::Int = 3,
)
    sites_per_zone > 0 || throw(ArgumentError("sites_per_zone must be positive."))
    all(column -> column in names(pcm_busdata), ("Bus_id", "Zone_id")) ||
        throw(ArgumentError("PCM busdata must contain Bus_id and Zone_id."))
    bus_rows =
        Dict(strip(string(pcm_busdata[row, "Bus_id"])) => row for row = 1:nrow(pcm_busdata))
    installed = Dict{Tuple{String,String},Float64}()
    for row in eachrow(pcm_gendata)
        all(column -> column in names(pcm_gendata), ("Zone", "Bus_id", "Pmax (MW)")) ||
            break
        key = (strip(string(row["Zone"])), strip(string(row["Bus_id"])))
        installed[key] =
            get(installed, key, 0.0) + max(to_float_output(row["Pmax (MW)"], 0.0), 0.0)
    end
    incident = _computed_incident_capacity(branchdata)
    zone_candidates = Dict{String,Set{String}}()
    for table in (generation_candidates, storage_candidates)
        "Zone" in names(table) || continue
        for row in eachrow(table)
            zone =
                "Planning_Zone" in names(table) ? strip(string(row["Planning_Zone"])) :
                strip(string(row["Zone"]))
            if "Bus_id" in names(table)
                bus = strip(string(row["Bus_id"]))
                haskey(bus_rows, bus) &&
                    push!(get!(zone_candidates, zone, Set{String}()), bus)
            else
                get!(zone_candidates, zone, Set{String}())
            end
        end
    end
    for ((zone, bus), _) in installed
        haskey(bus_rows, bus) && push!(get!(zone_candidates, zone, Set{String}()), bus)
    end

    selected = Dict{String,Vector{String}}()
    for (zone, buses) in zone_candidates
        ranked = sort(
            collect(buses);
            by = bus ->
                (-get(installed, (zone, bus), 0.0), -get(incident, bus, 0.0), bus),
        )
        selected[zone] = first(ranked, min(sites_per_zone, length(ranked)))
        isempty(selected[zone]) &&
            throw(ArgumentError("No PCM candidate buses resolve for zone $(zone)."))
    end

    catalog = DataFrame(
        Candidate_Site_ID = String[],
        Site_ID = String[],
        Bus_id = String[],
        Resource_Kind = String[],
        Zone = String[],
        Type = String[],
        Candidate_Max_MW = Float64[],
        Candidate_Max_MWh = Union{Missing,Float64}[],
        Existing_Site = Bool[],
        Site_Cost = Float64[],
        Network_Stress_Score = Float64[],
        Resource_Quality_Score = Float64[],
        Evidence_Confidence = Float64[],
        Eligible = Bool[],
        Network_Screen_Passed = Bool[],
        Exclusion_Reason = String[],
        Latitude = Union{Missing,Float64}[],
        Longitude = Union{Missing,Float64}[],
        Evidence_Source = String[],
    )
    function append_candidates(table::AbstractDataFrame, kind::String)
        for row_index = 1:nrow(table)
            zone =
                "Planning_Zone" in names(table) ?
                strip(string(table[row_index, "Planning_Zone"])) :
                strip(string(table[row_index, "Zone"]))
            source_id = _computed_source_id(table, row_index, uppercase(kind))
            max_mw =
                kind == "generation" ? to_float_output(table[row_index, "Pmax (MW)"], 0.0) :
                to_float_output(table[row_index, "Max Power (MW)"], 0.0)
            max_mwh =
                kind == "storage" ?
                to_float_output(table[row_index, "Capacity (MWh)"], 0.0) : missing
            max_mw > 0.0 || continue
            zone_buses = get(selected, zone, String[])
            max_installed = maximum(
                (get(installed, (zone, bus), 0.0) for bus in zone_buses);
                init = 0.0,
            )
            max_incident =
                maximum((get(incident, bus, 0.0) for bus in zone_buses); init = 0.0)
            for bus in zone_buses
                bus_row = bus_rows[bus]
                existing_mw = get(installed, (zone, bus), 0.0)
                incident_mw = get(incident, bus, 0.0)
                site_cost = max_installed > 0.0 ? 1.0 - existing_mw / max_installed : 1.0
                stress = max_incident > 0.0 ? 1.0 - incident_mw / max_incident : 1.0
                latitude =
                    "Latitude" in names(pcm_busdata) ?
                    to_float_output(pcm_busdata[bus_row, "Latitude"], NaN) : NaN
                longitude =
                    "Longitude" in names(pcm_busdata) ?
                    to_float_output(pcm_busdata[bus_row, "Longitude"], NaN) : NaN
                push!(
                    catalog,
                    (
                        string(source_id, "__SITE__", bus),
                        bus,
                        bus,
                        kind,
                        zone,
                        string(table[row_index, "Type"]),
                        max_mw,
                        max_mwh,
                        existing_mw > 0.0,
                        clamp(site_cost, 0.0, 1.0),
                        clamp(stress, 0.0, 1.0),
                        0.5,
                        existing_mw > 0.0 ? 0.9 : 0.7,
                        true,
                        incident_mw > 0.0,
                        "",
                        isfinite(latitude) ? latitude : missing,
                        isfinite(longitude) ? longitude : missing,
                        "HOPE PCM topology screen; existing capacity=$(existing_mw) MW; incident rating proxy=$(incident_mw) MW",
                    ),
                )
            end
        end
    end
    append_candidates(generation_candidates, "generation")
    append_candidates(storage_candidates, "storage")
    validate_candidate_site_catalog(catalog)
    sort!(catalog, [:Resource_Kind, :Zone, :Type, :Candidate_Site_ID])
    return catalog
end

function _computed_parent_index(table::AbstractDataFrame)
    index = Dict{String,Int}()
    for row = 1:nrow(table)
        id = _computed_source_id(table, row, "CANDIDATE")
        haskey(index, id) && throw(ArgumentError("Duplicate GTEP Candidate_ID $(id)."))
        index[id] = row
    end
    return index
end

function _computed_materialized_id(plan_item, site_id)
    return string(plan_item, "__AT__", site_id)
end

"""
    materialize_computed_realization_handoff(gtep_output, gtep_input,
        allocations; variant)

Expand one selected realization variant into site-specific GTEP candidate and
capacity-output rows. The returned GTEP dictionaries can be passed unchanged to
`prepare_pcm_inputs_from_gtep_linked` and its existing reconciliation checks.
"""
function materialize_computed_realization_handoff(
    gtep_output::AbstractDict,
    gtep_input::AbstractDict,
    allocations::AbstractDataFrame;
    variant::AbstractString,
    atol::Float64 = 1e-6,
)
    selected = allocations[string.(allocations[!, "Variant"]).==String(variant), :]
    nrow(selected) > 0 ||
        throw(ArgumentError("Computed realization variant $(variant) has no allocations."))
    plan = capacity_plan_from_gtep(gtep_output, gtep_input; atol = atol)
    expected =
        Dict(row.Plan_Item_ID => (row.Build_MW, row.Build_MWh) for row in eachrow(plan))
    for row in groupby(selected, :PlanItemID)
        plan_id = string(first(row.PlanItemID))
        haskey(expected, plan_id) ||
            throw(ArgumentError("Allocation references unknown PlanItemID $(plan_id)."))
        build_mw, build_mwh = expected[plan_id]
        isapprox(sum(row.AllocatedMW), build_mw; atol = atol, rtol = 1e-8) ||
            throw(ArgumentError("Allocation MW does not conserve PlanItemID $(plan_id)."))
        isapprox(sum(row.AllocatedMWh), build_mwh; atol = atol, rtol = 1e-8) ||
            throw(ArgumentError("Allocation MWh does not conserve PlanItemID $(plan_id)."))
    end
    Set(string.(selected.PlanItemID)) == Set(keys(expected)) || throw(
        ArgumentError("Selected realization does not cover every built GTEP plan item."),
    )

    adapted_input = deepcopy(gtep_input)
    adapted_output = deepcopy(gtep_output)
    audit = DataFrame(
        Variant = String[],
        PlanItemID = String[],
        CandidateSiteID = String[],
        MaterializedCandidateID = String[],
        BusID = String[],
        ResourceKind = String[],
        AllocatedMW = Float64[],
        AllocatedMWh = Float64[],
    )
    for (kind, input_key, output_key, capacity_column, energy_column) in (
        ("generation", "Gendata_candidate", "capacity", "Capacity_FIN (MW)", nothing),
        (
            "storage",
            "Estoragedata_candidate",
            "es_capacity",
            "Capacity (MW)",
            "EnergyCapacity (MWh)",
        ),
    )
        source_candidates = gtep_input[input_key]
        parent_index = _computed_parent_index(source_candidates)
        source_output = _holistic_candidate_output_rows(
            gtep_output[output_key],
            nrow(source_candidates),
            titlecase(kind),
        )
        input_rows = DataFrame[]
        output_rows = DataFrame[]
        kind_allocations = selected[lowercase.(string.(selected.ResourceKind)).==kind, :]
        for allocation in eachrow(kind_allocations)
            plan_id = string(allocation.PlanItemID)
            parent = get(parent_index, plan_id, 0)
            parent > 0 || throw(
                ArgumentError("No $(kind) GTEP candidate matches PlanItemID $(plan_id)."),
            )
            site_id = string(allocation.CandidateSiteID)
            candidate_id = _computed_materialized_id(plan_id, site_id)
            candidate = copy(source_candidates[parent:parent, :])
            candidate[!, HOLISTIC_CANDIDATE_ID] = [candidate_id]
            candidate[!, "Parent_Candidate_ID"] = [plan_id]
            candidate[!, "Bus_id"] = [string(allocation.BusID)]
            candidate[!, "Planning_Zone"] = [string(allocation.Zone)]
            candidate[!, "Zone"] = [string(allocation.Zone)]
            if kind == "generation"
                original_max = to_float_output(source_candidates[parent, "Pmax (MW)"], 0.0)
                pmin_ratio =
                    original_max > 0.0 && "Pmin (MW)" in names(source_candidates) ?
                    to_float_output(source_candidates[parent, "Pmin (MW)"], 0.0) /
                    original_max : 0.0
                candidate[!, "Pmax (MW)"] = [Float64(allocation.AllocatedMW)]
                "Pmin (MW)" in names(candidate) && (
                    candidate[!, "Pmin (MW)"] =
                        [max(pmin_ratio * allocation.AllocatedMW, 0.0)]
                )
            else
                candidate[!, "Max Power (MW)"] = [Float64(allocation.AllocatedMW)]
                candidate[!, "Capacity (MWh)"] = [Float64(allocation.AllocatedMWh)]
            end
            push!(input_rows, candidate)

            output = copy(source_output[parent:parent, :])
            output[!, "EC_Category"] = ["Candidate"]
            output[!, "New_Build"] = [true]
            output[!, capacity_column] = [Float64(allocation.AllocatedMW)]
            "Capacity_INI (MW)" in names(output) && (output[!, "Capacity_INI (MW)"] = [0.0])
            "Capacity_RET (MW)" in names(output) && (output[!, "Capacity_RET (MW)"] = [0.0])
            energy_column !== nothing &&
                (output[!, energy_column] = [Float64(allocation.AllocatedMWh)])
            output[!, HOLISTIC_CANDIDATE_ID] = [candidate_id]
            push!(output_rows, output)
            push!(
                audit,
                (
                    String(variant),
                    plan_id,
                    site_id,
                    candidate_id,
                    string(allocation.BusID),
                    kind,
                    Float64(allocation.AllocatedMW),
                    Float64(allocation.AllocatedMWh),
                ),
            )
        end
        adapted_input[input_key] =
            isempty(input_rows) ? source_candidates[1:0, :] :
            reduce((a, b) -> vcat(a, b; cols = :union), input_rows)
        full_output = gtep_output[output_key]
        existing =
            "EC_Category" in names(full_output) ?
            full_output[string.(full_output.EC_Category).!="Candidate", :] :
            full_output[1:0, :]
        new_output =
            isempty(output_rows) ? source_output[1:0, :] :
            reduce((a, b) -> vcat(a, b; cols = :union), output_rows)
        adapted_output[output_key] = vcat(existing, new_output; cols = :union)
    end
    sort!(audit, [:ResourceKind, :PlanItemID, :CandidateSiteID])
    return Dict(
        "gtep_output" => adapted_output,
        "gtep_input" => adapted_input,
        "audit" => audit,
        "capacity_plan" => plan,
    )
end

"""
    prepare_pcm_inputs_from_computed_realization(...; variant)

Run computed siting and feed its selected variant through the established PCM
handoff. The return value contains the realized PCM input plus every intermediate
artifact needed for audit and transfer reconciliation.
"""
function prepare_pcm_inputs_from_computed_realization(
    gtep_output::AbstractDict,
    gtep_input::AbstractDict,
    gtep_config::Dict,
    pcm_input::Dict,
    pcm_config::Dict,
    candidate_catalog::AbstractDataFrame,
    policy::AbstractDict;
    variant::AbstractString = "balanced_baseline",
    physical_realization = nothing,
)
    plan = capacity_plan_from_gtep(gtep_output, gtep_input)
    nrow(plan) > 0 || throw(
        ArgumentError(
            "Solved GTEP output contains no positive generation or storage builds to realize.",
        ),
    )
    realization = compute_nodal_realizations(plan, candidate_catalog, policy)
    materialized = materialize_computed_realization_handoff(
        gtep_output,
        gtep_input,
        realization["allocations"];
        variant = variant,
        atol = policy isa AbstractDict ? Float64(get(policy, "tolerance_mw", 1e-6)) : 1e-6,
    )
    updated = prepare_pcm_inputs_from_gtep_linked(
        materialized["gtep_output"],
        materialized["gtep_input"],
        gtep_config,
        pcm_input,
        pcm_config,
        physical_realization,
    )
    updated["LinkageAudit"]["computed_realization"] = materialized["audit"]
    updated["LinkageAudit"]["computed_realization_variant"] = String(variant)
    return Dict(
        "pcm_input" => updated,
        "capacity_plan" => plan,
        "realization" => realization,
        "materialized_gtep_output" => materialized["gtep_output"],
        "materialized_gtep_input" => materialized["gtep_input"],
        "materialization_audit" => materialized["audit"],
    )
end

function _computed_contract_path(case_path::AbstractString, value, label::AbstractString)
    text = strip(string(value))
    isempty(text) && throw(ArgumentError("$(label) path is blank."))
    return isabspath(text) ? normpath(text) : normpath(joinpath(case_path, text))
end

function _computed_contract_method(contract::AbstractDict, kind::AbstractString)
    siting = get(contract, "resource_siting", Dict{String,Any}())
    rule = get(siting, kind, Dict{String,Any}())
    return lowercase(strip(string(get(rule, "method", "legacy_zone"))))
end

"""Return the normalized computed-realization declaration, or `nothing`."""
function computed_realization_contract_spec(
    physical_realization,
    gtep_case_path::AbstractString,
)
    physical_realization isa AbstractDict || return nothing
    methods = Dict(
        kind => _computed_contract_method(physical_realization, kind) for
        kind in ("generation", "storage")
    )
    active = [kind for (kind, method) in methods if method == "computed_allocation"]
    isempty(active) && return nothing
    length(active) == 2 || throw(
        ArgumentError(
            "Computed realization must be declared for both generation and storage; active=$(join(sort(active), ',')).",
        ),
    )
    declaration = get(physical_realization, "computed_realization", nothing)
    declaration isa AbstractDict || throw(
        ArgumentError(
            "A computed_allocation siting method requires a computed_realization mapping.",
        ),
    )
    catalog_path = _computed_contract_path(
        gtep_case_path,
        get(declaration, "candidate_site_catalog", ""),
        "computed_realization.candidate_site_catalog",
    )
    policy_path = _computed_contract_path(
        gtep_case_path,
        get(declaration, "realization_policy", ""),
        "computed_realization.realization_policy",
    )
    isfile(catalog_path) ||
        throw(ArgumentError("Candidate-site catalog not found: $(catalog_path)"))
    isfile(policy_path) ||
        throw(ArgumentError("Realization policy not found: $(policy_path)"))
    variant = strip(string(get(declaration, "selected_variant", "balanced_baseline")))
    isempty(variant) &&
        throw(ArgumentError("computed_realization.selected_variant is blank."))
    fast_screen = get(declaration, "fast_screen", Dict{String,Any}())
    fast_screen isa AbstractDict ||
        throw(ArgumentError("computed_realization.fast_screen must be a mapping."))
    ratio_raw = get(fast_screen, "max_allocation_to_incident_rating_ratio", nothing)
    max_ratio = ratio_raw === nothing ? Inf : Float64(ratio_raw)
    (isinf(max_ratio) || (isfinite(max_ratio) && max_ratio > 0.0)) || throw(
        ArgumentError(
            "fast_screen.max_allocation_to_incident_rating_ratio must be positive when supplied.",
        ),
    )
    return Dict{String,Any}(
        "candidate_site_catalog" => catalog_path,
        "realization_policy" => policy_path,
        "selected_variant" => variant,
        "require_pass" => _computed_bool(get(fast_screen, "require_pass", true), true),
        "max_allocation_to_incident_rating_ratio" => max_ratio,
    )
end

"""
    screen_computed_realization(allocations, pcm_input; variant,
        max_allocation_to_incident_rating_ratio=Inf)

Run deterministic pre-PCM structural screens. Every allocated bus must exist,
belong to the declared planning zone, and have at least one rated physical
branch. A bus-allocation/incident-rating threshold is enforced only when the
study contract supplies one; the measured ratio is always reported.
"""
function screen_computed_realization(
    allocations::AbstractDataFrame,
    pcm_input::AbstractDict;
    variant::AbstractString,
    max_allocation_to_incident_rating_ratio::Float64 = Inf,
)
    selected = allocations[string.(allocations[!, "Variant"]).==String(variant), :]
    nrow(selected) > 0 ||
        throw(ArgumentError("Realization variant $(variant) has no allocations to screen."))
    haskey(pcm_input, "Busdata") || throw(ArgumentError("PCM input has no Busdata table."))
    busdata = pcm_input["Busdata"]
    all(column -> column in names(busdata), ("Bus_id", "Zone_id")) ||
        throw(ArgumentError("PCM Busdata must contain Bus_id and Zone_id."))
    bus_zone = Dict(
        strip(string(row["Bus_id"])) => strip(string(row["Zone_id"])) for
        row in eachrow(busdata)
    )
    branchdata = get(pcm_input, "Branchdata", DataFrame())
    incident = _computed_incident_capacity(branchdata)
    checks = DataFrame(
        Check = String[],
        BusID = String[],
        Zone = String[],
        AllocatedMW = Float64[],
        IncidentRatingMW = Float64[],
        AllocationToIncidentRatio = Float64[],
        Limit = String[],
        Passed = Bool[],
        Evidence = String[],
    )
    for rows in groupby(selected, [:BusID, :Zone])
        bus = string(first(rows.BusID))
        zone = string(first(rows.Zone))
        allocated = sum(rows.AllocatedMW)
        exists = haskey(bus_zone, bus)
        zone_matches = exists && bus_zone[bus] == zone
        rating = get(incident, bus, 0.0)
        connected = rating > 0.0
        ratio = connected ? allocated / rating : Inf
        ratio_pass =
            isinf(max_allocation_to_incident_rating_ratio) ||
            ratio <= max_allocation_to_incident_rating_ratio + 1e-9
        push!(
            checks,
            (
                "bus_reference",
                bus,
                zone,
                allocated,
                rating,
                ratio,
                "bus exists",
                exists,
                exists ? "PCM zone=$(bus_zone[bus])" : "bus is absent from PCM Busdata",
            ),
        )
        push!(
            checks,
            (
                "planning_zone_consistency",
                bus,
                zone,
                allocated,
                rating,
                ratio,
                "allocation zone equals PCM Zone_id",
                zone_matches,
                exists ? "allocation=$(zone); pcm=$(bus_zone[bus])" :
                "bus reference failed",
            ),
        )
        push!(
            checks,
            (
                "physical_connectivity",
                bus,
                zone,
                allocated,
                rating,
                ratio,
                "incident rating > 0",
                connected,
                "summed incident directional rating proxy=$(rating) MW",
            ),
        )
        limit_text =
            isinf(max_allocation_to_incident_rating_ratio) ? "reported_only" :
            string(max_allocation_to_incident_rating_ratio)
        push!(
            checks,
            (
                "allocation_to_incident_rating",
                bus,
                zone,
                allocated,
                rating,
                ratio,
                limit_text,
                ratio_pass,
                "ratio=$(ratio); a finite limit is a study assumption, not a power-flow proof",
            ),
        )
    end
    valid = all(checks.Passed)
    return Dict{String,Any}(
        "schema_version" => 1,
        "variant" => String(variant),
        "valid" => valid,
        "checks" => checks,
        "summary" => Dict(
            "allocated_buses" => length(unique(selected.BusID)),
            "allocated_mw" => sum(selected.AllocatedMW),
            "allocated_mwh" => sum(selected.AllocatedMWh),
            "maximum_allocation_to_incident_rating_ratio" =>
                maximum(checks.AllocationToIncidentRatio),
            "enforced_ratio_limit" =>
                isinf(max_allocation_to_incident_rating_ratio) ? nothing :
                max_allocation_to_incident_rating_ratio,
        ),
    )
end

"""
    build_computed_realization_handoff_from_contract(...)

Resolve an opt-in physical-realization contract, compute all declared variants,
screen the selected variant, and return the materialized GTEP handoff bundle.
Returns `nothing` when the contract keeps the default declared/legacy siting path.
"""
function build_computed_realization_handoff_from_contract(
    gtep_output::AbstractDict,
    gtep_input::AbstractDict,
    pcm_input::AbstractDict,
    physical_realization,
    gtep_case_path::AbstractString,
)
    specification = computed_realization_contract_spec(physical_realization, gtep_case_path)
    specification === nothing && return nothing
    plan = capacity_plan_from_gtep(gtep_output, gtep_input)
    nrow(plan) > 0 || return Dict{String,Any}(
        "active" => false,
        "reason" => "no_positive_generation_or_storage_builds",
        "specification" => specification,
        "capacity_plan" => plan,
    )
    catalog = load_candidate_site_catalog(specification["candidate_site_catalog"])
    policy = load_realization_policy(specification["realization_policy"])
    variant = specification["selected_variant"]
    variant in policy["variant_order"] || throw(
        ArgumentError(
            "Selected realization variant $(variant) is absent from policy variant_order.",
        ),
    )
    realization = compute_nodal_realizations(plan, catalog, policy)
    fast_screen = screen_computed_realization(
        realization["allocations"],
        pcm_input;
        variant = variant,
        max_allocation_to_incident_rating_ratio = specification["max_allocation_to_incident_rating_ratio"],
    )
    specification["require_pass"] &&
        !fast_screen["valid"] &&
        throw(
            ArgumentError(
                "Computed-realization fast screen failed for variant $(variant).",
            ),
        )
    materialized = materialize_computed_realization_handoff(
        gtep_output,
        gtep_input,
        realization["allocations"];
        variant = variant,
        atol = policy["tolerance_mw"],
    )
    return Dict{String,Any}(
        "active" => true,
        "specification" => specification,
        "capacity_plan" => plan,
        "catalog" => catalog,
        "policy" => policy,
        "realization" => realization,
        "fast_screen" => fast_screen,
        "materialized_gtep_output" => materialized["gtep_output"],
        "materialized_gtep_input" => materialized["gtep_input"],
        "materialization_audit" => materialized["audit"],
    )
end
