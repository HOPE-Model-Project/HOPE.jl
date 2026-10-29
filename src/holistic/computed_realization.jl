"""Deterministic constrained site-and-allocate downscaling for GTEP plans."""

const COMPUTED_REALIZATION_SCHEMA_VERSION = 1
const COMPUTED_REALIZATION_METHOD = "constrained_site_allocate_v1"

const COMPUTED_REALIZATION_WEIGHT_NAMES = (
    "site_cost",
    "network_stress",
    "resource_quality",
    "brownfield",
    "evidence_quality",
    "environmental_sensitivity",
    "permitting_complexity",
    "community_impact",
    "interconnection_cost",
    "fragmentation",
)

const COMPUTED_REALIZATION_DEFAULT_WEIGHTS = Dict(
    "site_cost" => 1.0,
    "network_stress" => 1.0,
    "resource_quality" => 1.0,
    "brownfield" => 0.5,
    "evidence_quality" => 0.5,
    "environmental_sensitivity" => 0.0,
    "permitting_complexity" => 0.0,
    "community_impact" => 0.0,
    "interconnection_cost" => 0.0,
    "fragmentation" => 0.05,
)

function _computed_require_columns(df::AbstractDataFrame, required, label::AbstractString)
    missing = setdiff(collect(required), names(df))
    isempty(missing) || throw(
        ArgumentError("$(label) is missing required columns: $(join(missing, ", "))."),
    )
    return nothing
end

function _computed_bool(value, default::Bool = false)
    (ismissing(value) || value === nothing) && return default
    value isa Bool && return value
    value isa Number && return value != 0
    text = lowercase(strip(string(value)))
    isempty(text) && return default
    text in ("true", "yes", "y", "1") && return true
    text in ("false", "no", "n", "0") && return false
    throw(ArgumentError("Cannot interpret '$(value)' as a Boolean value."))
end

function _computed_float(value, default::Float64, field::AbstractString)
    (ismissing(value) || value === nothing) && return default
    text = strip(string(value))
    isempty(text) && return default
    parsed = tryparse(Float64, replace(text, "," => ""))
    parsed === nothing && throw(ArgumentError("$(field) must be numeric; got '$(value)'."))
    isfinite(parsed) || throw(ArgumentError("$(field) must be finite; got $(parsed)."))
    return parsed
end

function _computed_value(
    df::AbstractDataFrame,
    row::Int,
    column::AbstractString,
    default::Float64,
)
    column in names(df) || return default
    return _computed_float(df[row, column], default, column)
end

function _computed_text_column(
    df::AbstractDataFrame,
    row::Int,
    column::AbstractString,
    default::AbstractString = "",
)
    column in names(df) || return String(default)
    return _holistic_text(df[row, column], String(default))
end

function _computed_normalized_penalty(
    values::Vector{Float64};
    higher_is_better::Bool = false,
)
    isempty(values) && return Float64[]
    lo, hi = extrema(values)
    isapprox(lo, hi; atol = 1e-12, rtol = 1e-12) && return zeros(length(values))
    scaled = (values .- lo) ./ (hi - lo)
    return higher_is_better ? 1.0 .- scaled : scaled
end

function _computed_policy_weights(policy::AbstractDict, variant::AbstractDict)
    weights = copy(COMPUTED_REALIZATION_DEFAULT_WEIGHTS)
    for source in (get(policy, "weights", Dict()), get(variant, "weights", Dict()))
        source isa AbstractDict ||
            throw(ArgumentError("Realization weights must be a mapping."))
        for (name, value) in source
            key = string(name)
            key in COMPUTED_REALIZATION_WEIGHT_NAMES ||
                throw(ArgumentError("Unknown realization objective weight '$(key)'."))
            parsed = _computed_float(value, 0.0, "weights.$(key)")
            parsed >= 0.0 || throw(ArgumentError("weights.$(key) must be nonnegative."))
            weights[key] = parsed
        end
    end
    return weights
end

function _computed_variants(policy::AbstractDict)
    variants = get(policy, "variants", nothing)
    if variants === nothing
        variants = Dict(
            "balanced_baseline" => Dict{String,Any}(),
            "existing_site_priority" =>
                Dict("weights" => Dict("brownfield" => 4.0, "site_cost" => 0.5)),
            "resource_network_priority" => Dict(
                "weights" => Dict(
                    "network_stress" => 2.0,
                    "resource_quality" => 2.0,
                    "brownfield" => 0.1,
                ),
            ),
        )
    end
    variants isa AbstractDict || throw(ArgumentError("variants must be a mapping."))
    order = if haskey(policy, "variant_order")
        string.(policy["variant_order"])
    else
        preferred =
            ["balanced_baseline", "existing_site_priority", "resource_network_priority"]
        present = Set(string.(keys(variants)))
        vcat(
            filter(name -> name in present, preferred),
            sort(collect(setdiff(present, Set(preferred)))),
        )
    end
    length(unique(order)) == length(order) ||
        throw(ArgumentError("variant_order must not contain duplicates."))
    Set(order) == Set(string.(keys(variants))) ||
        throw(ArgumentError("variant_order must name every variant exactly once."))
    return [
        name => begin
            value = variants[name]
            value isa AbstractDict ||
                throw(ArgumentError("Variant $(name) must be a mapping."))
            Dict{String,Any}(string(k) => v for (k, v) in value)
        end for name in order
    ]
end

"""
    validate_realization_policy(policy) -> Dict{String,Any}

Validate a version-1 computed-realization policy and return a string-keyed copy.
"""
function validate_realization_policy(policy::AbstractDict)
    normalized = Dict{String,Any}(string(k) => v for (k, v) in policy)
    get(normalized, "schema_version", nothing) == COMPUTED_REALIZATION_SCHEMA_VERSION ||
        throw(ArgumentError("Realization policy schema_version must be 1."))
    string(get(normalized, "artifact_type", "")) == "HOPE.realization_policy" ||
        throw(ArgumentError("artifact_type must be HOPE.realization_policy."))
    string(get(normalized, "method", "")) == COMPUTED_REALIZATION_METHOD ||
        throw(ArgumentError("method must be $(COMPUTED_REALIZATION_METHOD)."))
    solver = lowercase(string(get(normalized, "solver", "highs")))
    solver == "highs" || throw(
        ArgumentError(
            "Version 1 computed realization currently supports solver=highs only.",
        ),
    )
    tolerance = _computed_float(get(normalized, "tolerance_mw", 1e-6), 1e-6, "tolerance_mw")
    tolerance > 0.0 || throw(ArgumentError("tolerance_mw must be positive."))
    minimum = _computed_float(
        get(normalized, "minimum_allocation_mw", 0.0),
        0.0,
        "minimum_allocation_mw",
    )
    minimum >= 0.0 || throw(ArgumentError("minimum_allocation_mw must be nonnegative."))
    tie_break = _computed_float(
        get(normalized, "tie_break_epsilon", 1e-9),
        1e-9,
        "tie_break_epsilon",
    )
    tie_break >= 0.0 || throw(ArgumentError("tie_break_epsilon must be nonnegative."))
    allocation_mode =
        lowercase(strip(string(get(normalized, "allocation_mode", "continuous"))))
    allocation_mode in ("continuous", "discrete_project") ||
        throw(ArgumentError("allocation_mode must be continuous or discrete_project."))
    project_size_tolerance = _computed_float(
        get(normalized, "project_size_tolerance_mw", tolerance),
        tolerance,
        "project_size_tolerance_mw",
    )
    project_size_tolerance > 0.0 ||
        throw(ArgumentError("project_size_tolerance_mw must be positive."))
    for (_, variant) in _computed_variants(normalized)
        _computed_policy_weights(normalized, variant)
        excluded = get(variant, "exclude_candidate_ids", String[])
        excluded isa AbstractVector ||
            throw(ArgumentError("exclude_candidate_ids must be a list."))
    end
    normalized["solver"] = solver
    normalized["tolerance_mw"] = tolerance
    normalized["minimum_allocation_mw"] = minimum
    normalized["tie_break_epsilon"] = tie_break
    normalized["allocation_mode"] = allocation_mode
    normalized["project_size_tolerance_mw"] = project_size_tolerance
    return normalized
end

"""Load and validate a `HOPE.realization_policy` YAML file."""
function load_realization_policy(path::AbstractString)
    isfile(path) || throw(ArgumentError("Realization policy not found: $(path)"))
    policy = YAML.load_file(path)
    policy isa AbstractDict ||
        throw(ArgumentError("Realization policy must be a YAML mapping."))
    return validate_realization_policy(policy)
end

"""
    validate_capacity_plan(plan)

Validate the compact physical handoff requested from GTEP. Required columns are
`Plan_Item_ID`, `Resource_Kind`, `Zone`, `Type`, and `Build_MW`. Storage rows
also use `Build_MWh`.
"""
function validate_capacity_plan(plan::AbstractDataFrame; atol::Float64 = 1e-6)
    _computed_require_columns(
        plan,
        ["Plan_Item_ID", "Resource_Kind", "Zone", "Type", "Build_MW"],
        "CapacityPlan",
    )
    _holistic_assert_unique_ids(plan, "Plan_Item_ID", "CapacityPlan")
    for row = 1:nrow(plan)
        kind = lowercase(_computed_text_column(plan, row, "Resource_Kind"))
        kind in ("generation", "storage") || throw(
            ArgumentError("CapacityPlan.Resource_Kind must be generation or storage."),
        )
        isempty(_computed_text_column(plan, row, "Zone")) &&
            throw(ArgumentError("CapacityPlan.Zone must not be blank."))
        isempty(_computed_text_column(plan, row, "Type")) &&
            throw(ArgumentError("CapacityPlan.Type must not be blank."))
        build = _computed_value(plan, row, "Build_MW", NaN)
        isfinite(build) && build > atol ||
            throw(ArgumentError("CapacityPlan.Build_MW must be positive for row $(row)."))
        if kind == "storage"
            "Build_MWh" in names(plan) || throw(
                ArgumentError("CapacityPlan requires Build_MWh when storage is present."),
            )
            energy = _computed_value(plan, row, "Build_MWh", NaN)
            isfinite(energy) && energy > atol ||
                throw(ArgumentError("Storage Build_MWh must be positive for row $(row)."))
        end
    end
    return nothing
end

"""Load and validate a compact GTEP-to-realization capacity-plan CSV."""
function load_capacity_plan(path::AbstractString; atol::Float64 = 1e-6)
    isfile(path) || throw(ArgumentError("Capacity plan not found: $(path)"))
    plan = CSV.read(path, DataFrame)
    validate_capacity_plan(plan; atol = atol)
    return plan
end

"""
    validate_candidate_site_catalog(catalog) -> DataFrame

Validate candidate identities and numeric limits. The returned screening table
records hard candidate-level acceptance before plan matching and optimization.
"""
function validate_candidate_site_catalog(catalog::AbstractDataFrame; atol::Float64 = 1e-6)
    _computed_require_columns(
        catalog,
        [
            "Candidate_Site_ID",
            "Bus_id",
            "Resource_Kind",
            "Zone",
            "Type",
            "Candidate_Max_MW",
        ],
        "CandidateSiteCatalog",
    )
    _holistic_assert_unique_ids(catalog, "Candidate_Site_ID", "CandidateSiteCatalog")
    screening = DataFrame(
        CandidateSiteID = String[],
        SiteID = String[],
        BusID = String[],
        ResourceKind = String[],
        Zone = String[],
        Type = String[],
        ScreenedIn = Bool[],
        ScreenReason = String[],
        ReviewRequired = Bool[],
        ReviewReason = String[],
    )
    for row = 1:nrow(catalog)
        candidate_id = _computed_text_column(catalog, row, "Candidate_Site_ID")
        site_id = _computed_text_column(catalog, row, "Site_ID", candidate_id)
        bus_id = _computed_text_column(catalog, row, "Bus_id")
        kind = lowercase(_computed_text_column(catalog, row, "Resource_Kind"))
        zone = _computed_text_column(catalog, row, "Zone")
        resource_type = _computed_text_column(catalog, row, "Type")
        max_mw = _computed_value(catalog, row, "Candidate_Max_MW", NaN)
        reasons = String[]
        review_reasons = String[]
        isempty(site_id) && push!(reasons, "blank_site_id")
        isempty(bus_id) && push!(reasons, "blank_bus_id")
        kind in ("generation", "storage") || push!(reasons, "invalid_resource_kind")
        isempty(zone) && push!(reasons, "blank_zone")
        isempty(resource_type) && push!(reasons, "blank_type")
        (!isfinite(max_mw) || max_mw <= atol) &&
            push!(reasons, "nonpositive_candidate_max_mw")
        if "Eligible" in names(catalog) && !_computed_bool(catalog[row, "Eligible"], true)
            push!(reasons, "catalog_ineligible")
        end
        if "Network_Screen_Passed" in names(catalog) &&
           !_computed_bool(catalog[row, "Network_Screen_Passed"], true)
            push!(reasons, "network_screen_failed")
        end
        exclusion = _computed_text_column(catalog, row, "Exclusion_Reason")
        isempty(exclusion) || push!(reasons, "excluded:$(exclusion)")
        permit_status = lowercase(_computed_text_column(catalog, row, "Permit_Status"))
        permit_status in ("denied", "prohibited", "rejected", "withdrawn") &&
            push!(reasons, "permit_status_$(permit_status)")
        permit_status in ("conditional", "pre_application", "under_review") &&
            push!(review_reasons, "permit_status_$(permit_status)")
        if "Environmental_Eligible" in names(catalog) &&
           !_computed_bool(catalog[row, "Environmental_Eligible"], true)
            push!(reasons, "environmental_screen_failed")
        end
        queue_status = lowercase(_computed_text_column(catalog, row, "Queue_Status"))
        queue_status in ("withdrawn", "rejected", "suspended") &&
            push!(reasons, "queue_status_$(queue_status)")
        if "Interconnection_Headroom_MW" in names(catalog)
            headroom = _computed_value(catalog, row, "Interconnection_Headroom_MW", NaN)
            (!isfinite(headroom) || headroom + atol < max_mw) &&
                push!(reasons, "insufficient_interconnection_headroom")
        end
        if all(
            column -> column in names(catalog),
            ("Land_Available_Acres", "Land_Required_Acres"),
        )
            available = _computed_value(catalog, row, "Land_Available_Acres", NaN)
            required = _computed_value(catalog, row, "Land_Required_Acres", NaN)
            (!isfinite(available) || !isfinite(required) || available + atol < required) &&
                push!(reasons, "insufficient_land_area")
        end
        if all(
            column -> column in names(catalog),
            ("Commercial_Operation_Year", "Required_In_Service_Year"),
        )
            commercial_year =
                _computed_value(catalog, row, "Commercial_Operation_Year", NaN)
            required_year = _computed_value(catalog, row, "Required_In_Service_Year", NaN)
            (
                !isfinite(commercial_year) ||
                !isfinite(required_year) ||
                commercial_year > required_year + atol
            ) && push!(reasons, "commercial_operation_after_required_year")
        end
        if "Community_Review_Required" in names(catalog) &&
           _computed_bool(catalog[row, "Community_Review_Required"], false)
            push!(review_reasons, "community_review_required")
        end
        if kind == "storage" && "Candidate_Max_MWh" in names(catalog)
            max_mwh = _computed_value(catalog, row, "Candidate_Max_MWh", NaN)
            (!isfinite(max_mwh) || max_mwh <= atol) &&
                push!(reasons, "nonpositive_candidate_max_mwh")
        end
        for column in (
            "Site_Cost",
            "Network_Stress_Score",
            "Environmental_Sensitivity_Score",
            "Permitting_Complexity_Score",
            "Community_Impact_Score",
            "Interconnection_Cost_Score",
        )
            value = _computed_value(catalog, row, column, 0.0)
            value >= 0.0 || push!(reasons, "negative_$(lowercase(column))")
        end
        for (column, default) in
            (("Resource_Quality_Score", 0.0), ("Evidence_Confidence", 1.0))
            value = _computed_value(catalog, row, column, default)
            0.0 <= value <= 1.0 || push!(reasons, "$(lowercase(column))_outside_0_1")
        end
        push!(
            screening,
            (
                candidate_id,
                site_id,
                bus_id,
                kind,
                zone,
                resource_type,
                isempty(reasons),
                isempty(reasons) ? "eligible" : join(reasons, ";"),
                !isempty(review_reasons),
                isempty(review_reasons) ? "" : join(review_reasons, ";"),
            ),
        )
    end
    return screening
end

"""Load and validate a candidate-site catalog CSV."""
function load_candidate_site_catalog(path::AbstractString)
    isfile(path) || throw(ArgumentError("Candidate-site catalog not found: $(path)"))
    catalog = CSV.read(path, DataFrame)
    validate_candidate_site_catalog(catalog)
    return catalog
end

function _computed_matching_pairs(
    plan::AbstractDataFrame,
    catalog::AbstractDataFrame,
    screening::DataFrame,
    excluded::Set{String},
    allocation_mode::AbstractString,
    project_size_tolerance_mw::Float64,
)
    pairs = Tuple{Int,Int}[]
    for item = 1:nrow(plan), candidate = 1:nrow(catalog)
        screening.ScreenedIn[candidate] || continue
        screening.CandidateSiteID[candidate] in excluded && continue
        lowercase(_computed_text_column(plan, item, "Resource_Kind")) ==
        lowercase(_computed_text_column(catalog, candidate, "Resource_Kind")) || continue
        _computed_text_column(plan, item, "Zone") ==
        _computed_text_column(catalog, candidate, "Zone") || continue
        _computed_text_column(plan, item, "Type") ==
        _computed_text_column(catalog, candidate, "Type") || continue
        if allocation_mode == "discrete_project"
            build_mw = _computed_value(plan, item, "Build_MW", NaN)
            project_mw = _computed_value(catalog, candidate, "Candidate_Max_MW", NaN)
            isapprox(project_mw, build_mw; atol = project_size_tolerance_mw, rtol = 1e-8) ||
                continue
            if lowercase(_computed_text_column(plan, item, "Resource_Kind")) == "storage"
                build_mwh = _computed_value(plan, item, "Build_MWh", NaN)
                project_mwh = _computed_value(catalog, candidate, "Candidate_Max_MWh", NaN)
                isapprox(
                    project_mwh,
                    build_mwh;
                    atol = project_size_tolerance_mw,
                    rtol = 1e-8,
                ) || continue
            end
        end
        push!(pairs, (item, candidate))
    end
    return pairs
end

function _computed_candidate_components(
    plan::AbstractDataFrame,
    catalog::AbstractDataFrame,
    pairs::Vector{Tuple{Int,Int}},
)
    components = Dict{Tuple{Int,Int},NamedTuple}()
    for item = 1:nrow(plan)
        candidate_rows = [candidate for (i, candidate) in pairs if i == item]
        sort!(
            candidate_rows;
            by = candidate ->
                _computed_text_column(catalog, candidate, "Candidate_Site_ID"),
        )
        isempty(candidate_rows) && throw(
            ArgumentError(
                "No eligible candidate sites remain for Plan_Item_ID=$(_computed_text_column(plan, item, "Plan_Item_ID")).",
            ),
        )
        costs = [_computed_value(catalog, row, "Site_Cost", 0.0) for row in candidate_rows]
        network = [
            _computed_value(catalog, row, "Network_Stress_Score", 0.0) for
            row in candidate_rows
        ]
        resources = [
            _computed_value(catalog, row, "Resource_Quality_Score", 0.0) for
            row in candidate_rows
        ]
        evidence = [
            _computed_value(catalog, row, "Evidence_Confidence", 1.0) for
            row in candidate_rows
        ]
        environmental = [
            _computed_value(catalog, row, "Environmental_Sensitivity_Score", 0.0) for
            row in candidate_rows
        ]
        permitting = [
            _computed_value(catalog, row, "Permitting_Complexity_Score", 0.0) for
            row in candidate_rows
        ]
        community = [
            _computed_value(catalog, row, "Community_Impact_Score", 0.0) for
            row in candidate_rows
        ]
        interconnection = [
            _computed_value(catalog, row, "Interconnection_Cost_Score", 0.0) for
            row in candidate_rows
        ]
        cost_penalty = _computed_normalized_penalty(costs)
        network_penalty = _computed_normalized_penalty(network)
        resource_penalty = _computed_normalized_penalty(resources; higher_is_better = true)
        evidence_penalty = _computed_normalized_penalty(evidence; higher_is_better = true)
        environmental_penalty = _computed_normalized_penalty(environmental)
        permitting_penalty = _computed_normalized_penalty(permitting)
        community_penalty = _computed_normalized_penalty(community)
        interconnection_penalty = _computed_normalized_penalty(interconnection)
        for (index, candidate) in enumerate(candidate_rows)
            existing =
                "Existing_Site" in names(catalog) ?
                _computed_bool(catalog[candidate, "Existing_Site"], false) : false
            components[(item, candidate)] = (
                site_cost = cost_penalty[index],
                network_stress = network_penalty[index],
                resource_quality = resource_penalty[index],
                brownfield = existing ? 0.0 : 1.0,
                evidence_quality = evidence_penalty[index],
                environmental_sensitivity = environmental_penalty[index],
                permitting_complexity = permitting_penalty[index],
                community_impact = community_penalty[index],
                interconnection_cost = interconnection_penalty[index],
                rank = index,
            )
        end
    end
    return components
end

function _computed_site_caps(catalog::AbstractDataFrame, screening::DataFrame)
    rows_by_site = Dict{String,Vector{Int}}()
    for row = 1:nrow(catalog)
        screening.ScreenedIn[row] || continue
        push!(get!(rows_by_site, screening.SiteID[row], Int[]), row)
    end
    caps = Dict{String,Float64}()
    for (site, rows) in rows_by_site
        values = [
            _computed_value(catalog, row, "Site_Max_MW", Inf) for
            row in rows if "Site_Max_MW" in names(catalog) &&
            !ismissing(catalog[row, "Site_Max_MW"]) &&
            !isempty(strip(string(catalog[row, "Site_Max_MW"])))
        ]
        if isempty(values)
            caps[site] = Inf
        else
            all(
                isapprox(value, first(values); atol = 1e-8, rtol = 1e-8) for value in values
            ) || throw(ArgumentError("Site_Max_MW must be consistent for Site_ID=$(site)."))
            first(values) > 0.0 ||
                throw(ArgumentError("Site_Max_MW must be positive for Site_ID=$(site)."))
            caps[site] = first(values)
        end
    end
    return caps
end

function _computed_solve_variant(
    plan::AbstractDataFrame,
    catalog::AbstractDataFrame,
    screening::DataFrame,
    policy::AbstractDict,
    variant_name::String,
    variant::AbstractDict,
)
    tolerance = Float64(policy["tolerance_mw"])
    minimum = Float64(policy["minimum_allocation_mw"])
    tie_break = Float64(policy["tie_break_epsilon"])
    allocation_mode = string(policy["allocation_mode"])
    project_size_tolerance = Float64(policy["project_size_tolerance_mw"])
    excluded = Set(string.(get(variant, "exclude_candidate_ids", String[])))
    pairs = _computed_matching_pairs(
        plan,
        catalog,
        screening,
        excluded,
        allocation_mode,
        project_size_tolerance,
    )
    components = _computed_candidate_components(plan, catalog, pairs)
    weights = _computed_policy_weights(policy, variant)
    site_caps = _computed_site_caps(catalog, screening)

    model = Model(
        optimizer_with_attributes(
            HiGHS.Optimizer,
            "output_flag" => false,
            "threads" => 1,
            "mip_rel_gap" => 0.0,
            "primal_feasibility_tolerance" => min(tolerance, 1e-7),
        ),
    )
    pair_count = length(pairs)
    @variable(model, allocation[1:pair_count] >= 0.0)
    @variable(model, used[1:pair_count], Bin)

    for item = 1:nrow(plan)
        indices = [p for p = 1:pair_count if pairs[p][1] == item]
        build = _computed_value(plan, item, "Build_MW", NaN)
        @constraint(model, sum(allocation[p] for p in indices) == build)
        if allocation_mode == "discrete_project"
            for p in indices
                @constraint(model, allocation[p] == build * used[p])
            end
        end
        max_sites_value = _computed_float(
            get(
                variant,
                "max_sites_per_plan_item",
                get(policy, "max_sites_per_plan_item", length(indices)),
            ),
            Float64(length(indices)),
            "max_sites_per_plan_item",
        )
        isinteger(max_sites_value) ||
            throw(ArgumentError("max_sites_per_plan_item must be an integer."))
        max_sites = Int(max_sites_value)
        max_sites > 0 || throw(ArgumentError("max_sites_per_plan_item must be positive."))
        @constraint(model, sum(used[p] for p in indices) <= max_sites)
    end

    for candidate = 1:nrow(catalog)
        indices = [p for p = 1:pair_count if pairs[p][2] == candidate]
        isempty(indices) && continue
        max_mw = _computed_value(catalog, candidate, "Candidate_Max_MW", NaN)
        @constraint(model, sum(allocation[p] for p in indices) <= max_mw)
        allocation_mode == "discrete_project" &&
            @constraint(model, sum(used[p] for p in indices) <= 1)
        for p in indices
            @constraint(model, allocation[p] <= max_mw * used[p])
            minimum > 0.0 && @constraint(model, allocation[p] >= minimum * used[p])
        end
        if lowercase(_computed_text_column(catalog, candidate, "Resource_Kind")) ==
           "storage" && "Candidate_Max_MWh" in names(catalog)
            max_mwh = _computed_value(catalog, candidate, "Candidate_Max_MWh", Inf)
            energy_terms = []
            for p in indices
                item = pairs[p][1]
                ratio =
                    _computed_value(plan, item, "Build_MWh", 0.0) /
                    _computed_value(plan, item, "Build_MW", 1.0)
                push!(energy_terms, ratio * allocation[p])
            end
            isfinite(max_mwh) && @constraint(model, sum(energy_terms) <= max_mwh)
        end
    end

    for (site, cap) in site_caps
        isfinite(cap) || continue
        indices = [
            p for p = 1:pair_count if _computed_text_column(
                catalog,
                pairs[p][2],
                "Site_ID",
                _computed_text_column(catalog, pairs[p][2], "Candidate_Site_ID"),
            ) == site
        ]
        isempty(indices) || @constraint(model, sum(allocation[p] for p in indices) <= cap)
    end

    coefficient = Dict{Tuple{Int,Int},Float64}()
    for pair in pairs
        component = components[pair]
        coefficient[pair] =
            weights["site_cost"] * component.site_cost +
            weights["network_stress"] * component.network_stress +
            weights["resource_quality"] * component.resource_quality +
            weights["brownfield"] * component.brownfield +
            weights["evidence_quality"] * component.evidence_quality +
            weights["environmental_sensitivity"] * component.environmental_sensitivity +
            weights["permitting_complexity"] * component.permitting_complexity +
            weights["community_impact"] * component.community_impact +
            weights["interconnection_cost"] * component.interconnection_cost
    end
    @objective(
        model,
        Min,
        sum(
            (coefficient[pairs[p]] + tie_break * components[pairs[p]].rank) *
            allocation[p] + weights["fragmentation"] * used[p] for p = 1:pair_count
        ),
    )
    optimize!(model)
    status = termination_status(model)
    status == MOI.OPTIMAL || throw(
        ArgumentError(
            "Computed realization variant $(variant_name) did not solve to optimality (status=$(status)).",
        ),
    )
    primal_status(model) == MOI.FEASIBLE_POINT || throw(
        ArgumentError(
            "Computed realization variant $(variant_name) has no feasible point.",
        ),
    )

    allocations = DataFrame(
        Variant = String[],
        PlanItemID = String[],
        CandidateSiteID = String[],
        SiteID = String[],
        BusID = String[],
        ResourceKind = String[],
        Zone = String[],
        Type = String[],
        AllocatedMW = Float64[],
        AllocatedMWh = Float64[],
        ExistingSite = Bool[],
        SiteCostPenalty = Float64[],
        NetworkStressPenalty = Float64[],
        ResourceQualityPenalty = Float64[],
        BrownfieldPenalty = Float64[],
        EvidenceQualityPenalty = Float64[],
        EnvironmentalSensitivityPenalty = Float64[],
        PermittingComplexityPenalty = Float64[],
        CommunityImpactPenalty = Float64[],
        InterconnectionCostPenalty = Float64[],
        ReviewRequired = Bool[],
        ReviewReason = String[],
        WeightedScorePerMW = Float64[],
        ObjectiveContribution = Float64[],
    )
    for p = 1:pair_count
        allocated = value(allocation[p])
        allocated > tolerance || continue
        item, candidate = pairs[p]
        component = components[(item, candidate)]
        kind = lowercase(_computed_text_column(plan, item, "Resource_Kind"))
        energy =
            kind == "storage" ?
            allocated * _computed_value(plan, item, "Build_MWh", 0.0) /
            _computed_value(plan, item, "Build_MW", 1.0) : 0.0
        existing =
            "Existing_Site" in names(catalog) ?
            _computed_bool(catalog[candidate, "Existing_Site"], false) : false
        score = coefficient[(item, candidate)]
        fragment = value(used[p]) > 0.5 ? weights["fragmentation"] : 0.0
        review_required = screening.ReviewRequired[candidate]
        review_reason = screening.ReviewReason[candidate]
        push!(
            allocations,
            (
                variant_name,
                _computed_text_column(plan, item, "Plan_Item_ID"),
                _computed_text_column(catalog, candidate, "Candidate_Site_ID"),
                _computed_text_column(
                    catalog,
                    candidate,
                    "Site_ID",
                    _computed_text_column(catalog, candidate, "Candidate_Site_ID"),
                ),
                _computed_text_column(catalog, candidate, "Bus_id"),
                kind,
                _computed_text_column(plan, item, "Zone"),
                _computed_text_column(plan, item, "Type"),
                allocated,
                energy,
                existing,
                component.site_cost,
                component.network_stress,
                component.resource_quality,
                component.brownfield,
                component.evidence_quality,
                component.environmental_sensitivity,
                component.permitting_complexity,
                component.community_impact,
                component.interconnection_cost,
                review_required,
                review_reason,
                score,
                score * allocated + fragment,
            ),
        )
    end
    sort!(allocations, [:PlanItemID, :CandidateSiteID])
    return allocations, objective_value(model), string(status)
end

"""
    compute_nodal_realizations(capacity_plan, candidate_catalog, policy)

Generate a deterministic set of policy-labelled nodal realizations. The result
contains `allocations`, `screening`, and `summary` DataFrames plus the validated
policy.
"""
function compute_nodal_realizations(
    capacity_plan::AbstractDataFrame,
    candidate_catalog::AbstractDataFrame,
    policy::AbstractDict,
)
    normalized_policy = validate_realization_policy(policy)
    validate_capacity_plan(capacity_plan; atol = normalized_policy["tolerance_mw"])
    screening = validate_candidate_site_catalog(
        candidate_catalog;
        atol = normalized_policy["tolerance_mw"],
    )
    allocation_tables = DataFrame[]
    summary = DataFrame(
        Variant = String[],
        Status = String[],
        ObjectiveValue = Float64[],
        AllocatedMW = Float64[],
        AllocatedMWh = Float64[],
        UsedSites = Int[],
        PlanItems = Int[],
    )
    for (variant_name, variant) in _computed_variants(normalized_policy)
        allocations, objective, status = _computed_solve_variant(
            capacity_plan,
            candidate_catalog,
            screening,
            normalized_policy,
            variant_name,
            variant,
        )
        push!(allocation_tables, allocations)
        push!(
            summary,
            (
                variant_name,
                status,
                objective,
                sum(allocations.AllocatedMW),
                sum(allocations.AllocatedMWh),
                length(unique(allocations.SiteID)),
                length(unique(allocations.PlanItemID)),
            ),
        )
    end
    allocations = reduce((left, right) -> vcat(left, right), allocation_tables)
    return Dict{String,Any}(
        "allocations" => allocations,
        "screening" => screening,
        "summary" => summary,
        "policy" => normalized_policy,
    )
end

_computed_file_hash(path::AbstractString) = bytes2hex(sha256(read(path)))

"""
    write_computed_realization_set(plan_path, catalog_path, policy_path, output_path)

Run computed downscaling from CSV/YAML inputs and write an immutable-style
realization-set package containing allocations, screening evidence, summary,
and a SHA-256 manifest.
"""
function write_computed_realization_set(
    plan_path::AbstractString,
    catalog_path::AbstractString,
    policy_path::AbstractString,
    output_path::AbstractString,
    ;
    overwrite::Bool = false,
)
    policy = load_realization_policy(policy_path)
    plan = load_capacity_plan(plan_path; atol = policy["tolerance_mw"])
    catalog = load_candidate_site_catalog(catalog_path)
    result = compute_nodal_realizations(plan, catalog, policy)
    paths = Dict(
        "allocations" => joinpath(output_path, "nodal_allocations.csv"),
        "screening" => joinpath(output_path, "candidate_screening.csv"),
        "summary" => joinpath(output_path, "realization_summary.csv"),
        "manifest" => joinpath(output_path, "realization_set.yml"),
    )
    existing = filter(isfile, collect(values(paths)))
    isempty(existing) ||
        overwrite ||
        throw(
            ArgumentError(
                "Computed-realization output already exists and is immutable by default: $(join(existing, ", ")).",
            ),
        )
    mkpath(output_path)
    CSV.write(paths["allocations"], result["allocations"])
    CSV.write(paths["screening"], result["screening"])
    CSV.write(paths["summary"], result["summary"])
    output_hashes = Dict(
        basename(paths[name]) => _computed_file_hash(paths[name]) for
        name in ("allocations", "screening", "summary")
    )
    manifest = Dict{String,Any}(
        "schema_version" => COMPUTED_REALIZATION_SCHEMA_VERSION,
        "artifact_type" => "HOPE.realization_set",
        "method" => COMPUTED_REALIZATION_METHOD,
        "variants" => collect(result["summary"].Variant),
        "source_files" => Dict(
            "capacity_plan" => Dict(
                "path" => abspath(plan_path),
                "sha256" => _computed_file_hash(plan_path),
            ),
            "candidate_site_catalog" => Dict(
                "path" => abspath(catalog_path),
                "sha256" => _computed_file_hash(catalog_path),
            ),
            "realization_policy" => Dict(
                "path" => abspath(policy_path),
                "sha256" => _computed_file_hash(policy_path),
            ),
        ),
        "outputs" => output_hashes,
    )
    open(paths["manifest"], "w") do io
        YAML.write(io, manifest)
    end
    result["paths"] = paths
    result["manifest"] = manifest
    return result
end
