"""Compact RPS planning experiments and deterministic project unitization."""

const COMPACT_PLANNING_PROXY_STATUS = "synthetic_firm_import_proxy"

function _compact_assert_aligned_profiles(
    reference::AbstractDataFrame,
    profile::AbstractDataFrame,
    label::AbstractString,
)
    time_columns = [
        name for
        name in ("Time Period", "Month", "Day", "Hours") if name in names(reference)
    ]
    isempty(time_columns) &&
        throw(ArgumentError("Generator availability has no recognized time columns."))
    _compact_required_columns(profile, time_columns, label)
    nrow(profile) == nrow(reference) || throw(
        ArgumentError(
            "$(label) has $(nrow(profile)) rows; generator availability has $(nrow(reference)).",
        ),
    )
    for name in time_columns
        isequal(profile[!, name], reference[!, name]) ||
            throw(ArgumentError("$(label) is not aligned on time column $(name)."))
    end
    return nothing
end

function _compact_write_explicit_availability!(
    child_data::AbstractString,
    original_generation_count::Int,
    child_generation::AbstractDataFrame,
)
    availability_path = joinpath(child_data, "gen_availability_timeseries.csv")
    candidate_path = joinpath(child_data, "gendata_candidate.csv")
    isfile(availability_path) ||
        throw(ArgumentError("Generator availability table not found: $(availability_path)"))
    isfile(candidate_path) ||
        throw(ArgumentError("Candidate generation table not found: $(candidate_path)"))
    availability = CSV.read(availability_path, DataFrame)
    candidates = CSV.read(candidate_path, DataFrame)
    _compact_required_columns(
        candidates,
        ["Type", "Zone", "AF", "Candidate_ID"],
        "Candidate generation table",
    )
    original_generation_count <= nrow(child_generation) ||
        throw(ArgumentError("Original generation count exceeds child generation count."))

    profile_tables = Dict{String,DataFrame}()
    for (resource_type, filename) in (
        "SolarPV" => "solar_timeseries_regional.csv",
        "WindOn" => "wind_timeseries_regional.csv",
        "WindOff" => "wind_timeseries_regional.csv",
    )
        path = joinpath(child_data, filename)
        isfile(path) || throw(
            ArgumentError(
                "Regional profile required for $(resource_type) is absent: $(path)",
            ),
        )
        profile = CSV.read(path, DataFrame)
        _compact_assert_aligned_profiles(availability, profile, filename)
        profile_tables[resource_type] = profile
    end

    # The appended firm-supply proxies are existing generators, so they shift
    # every candidate's positional G-index. Make those proxy columns explicit
    # before assigning candidate columns at their post-materialization indices.
    # Parent candidate columns may occupy these names at their old indices;
    # overwriting and then reordering is the intended deterministic reindexing.
    for index = (original_generation_count+1):nrow(child_generation)
        column = string("G", index)
        static_af = _child_number(child_generation[index, "AF"], "proxy AF")
        availability[!, column] = fill(static_af, nrow(availability))
    end
    candidate_offset = nrow(child_generation)
    profile_sources = Dict{String,String}()
    for (index, candidate) in enumerate(eachrow(candidates))
        column = string("G", candidate_offset + index)
        resource_type = _feedback_text(candidate.Type)
        zone = _feedback_text(candidate.Zone)
        if haskey(profile_tables, resource_type)
            profile = profile_tables[resource_type]
            zone in names(profile) || throw(
                ArgumentError(
                    "Regional $(resource_type) profile has no zone column $(zone) for candidate $(candidate.Candidate_ID).",
                ),
            )
            availability[!, column] = Float64.(profile[!, zone])
            profile_sources[_feedback_text(candidate.Candidate_ID)] =
                resource_type == "SolarPV" ? "solar_timeseries_regional.csv:$(zone)" :
                "wind_timeseries_regional.csv:$(zone)"
        else
            static_af = _child_number(candidate.AF, "candidate AF")
            availability[!, column] = fill(static_af, nrow(availability))
            profile_sources[_feedback_text(candidate.Candidate_ID)] = "static_AF"
        end
    end
    time_columns = [
        name for
        name in ("Time Period", "Month", "Day", "Hours") if name in names(availability)
    ]
    generator_columns =
        [string("G", index) for index = 1:(nrow(child_generation)+nrow(candidates))]
    _compact_required_columns(
        availability,
        generator_columns,
        "Reindexed generator availability table",
    )
    availability = select(availability, vcat(time_columns, generator_columns))
    CSV.write(availability_path, availability)
    return Dict(
        "availability_path" => availability_path,
        "candidate_profile_sources" => profile_sources,
        "proxy_columns_added" => nrow(child_generation) - original_generation_count,
        "candidate_columns_added" => nrow(candidates),
    )
end

function _compact_required_columns(table::AbstractDataFrame, columns, label)
    missing_columns = setdiff(String.(columns), names(table))
    isempty(missing_columns) ||
        throw(ArgumentError("$(label) is missing columns: $(join(missing_columns, ", "))."))
    return nothing
end

function _compact_proxy_row(
    generation::AbstractDataFrame,
    template_index::Int,
    proxy_id::AbstractString,
    bus_id::AbstractString,
    capacity_mw::Float64,
    external_zone::AbstractString,
    marginal_cost_per_mwh::Float64,
)
    proxy = Dict{String,Any}(
        name => generation[template_index, name] for name in names(generation)
    )
    for name in (
        "PlantCode",
        "CAMDUnitID",
        "County",
        "FIPS",
        "Latitude",
        "Longitude",
        "SourceProjectID",
        "SourceQueueStatus",
        "SourceInServiceYear",
        "SourceOnLineYear",
        "SourceRetirementYear",
        "SitingHostGeneratorID",
        "SitingHostPlantCode",
        "SitingHostPlantName",
    )
        name in names(generation) && (proxy[name] = missing)
    end
    updates = Dict{String,Any}(
        "GeneratorID" => String(proxy_id),
        "SourceRowID" => "SYNTHETIC_FIRM_IMPORT_ASSUMPTION",
        "PlantName" => "Synthetic firm PJM contribution",
        "UniqueID_Final" => String(proxy_id),
        "UnitID" => "1",
        "SourceTechnology" => "Firm external contribution proxy",
        "State" => String(external_zone),
        "Pmax (MW)" => capacity_mw,
        "Pmin (MW)" => 0.0,
        "Zone" => String(external_zone),
        "Type" => "NGCC",
        "Flag_thermal" => 1,
        "Flag_RET" => 0,
        "Flag_VRE" => 0,
        "Flag_mustrun" => 0,
        raw"Cost ($/MWh)" => marginal_cost_per_mwh,
        "CC" => 1.0,
        "AF" => 1.0,
        "FOR" => 0.0,
        "RM_SPIN" => 0.0,
        "RU" => 1.0,
        "RD" => 1.0,
        "Flag_UC" => 0,
        "Min_down_time" => 0,
        "Min_up_time" => 0,
        raw"Start_up_cost ($/MW)" => 0.0,
        "Flag_RPS" => 0,
        "CoordinateSource" => "synthetic planning assumption; declared PCM boundary bus",
        "ScenarioStatus" => COMPACT_PLANNING_PROXY_STATUS,
        "AggregationStatus" => "planning_proxy",
        "UnitCount" => 1,
        "OriginalGeneratorIDs" => "",
        "PlannedRetirementBy2035" => false,
        "RetirementDispositionNote" => "Not a physical generator; planning and operational external-supply proxy.",
        "SitingBasis" => "Approved compact-planning experiment assumption",
        "Bus_id" => String(bus_id),
        "LoadZone" => String(external_zone),
        "Asset_ID" => String(proxy_id),
        "Planning_Zone" => String(external_zone),
    )
    for (name, value) in updates
        name in names(generation) && (proxy[name] = value)
    end
    return proxy
end

"""
    materialize_compact_rps_gtep_case(parent_case, child_case, contributions; ...)

Create an immutable experimental GTEP child with a declared firm external
contribution split among physical PCM boundary buses. The proxy is existing,
non-RPS capacity. It changes no candidate envelope and does not claim that the
external contribution is a real PJM contract or a contingency-deliverable
resource.
"""
function materialize_compact_rps_gtep_case(
    parent_case::AbstractString,
    child_case::AbstractString,
    contributions::AbstractDataFrame;
    external_zone::AbstractString = "EXT",
    marginal_cost_per_mwh::Float64 = 0.0,
)
    marginal_cost_per_mwh >= 0.0 ||
        throw(ArgumentError("marginal_cost_per_mwh must be nonnegative."))
    _compact_required_columns(
        contributions,
        ["Proxy_ID", "Bus_id", "Capacity_MW"],
        "Firm-contribution table",
    )
    nrow(contributions) > 0 ||
        throw(ArgumentError("Firm-contribution table must contain at least one row."))
    proxy_ids = strip.(string.(contributions[!, "Proxy_ID"]))
    bus_ids = strip.(string.(contributions[!, "Bus_id"]))
    capacities =
        [_child_number(value, "Capacity_MW") for value in contributions.Capacity_MW]
    all(value -> !isempty(value), proxy_ids) ||
        throw(ArgumentError("Proxy_ID must be nonblank."))
    all(value -> !isempty(value), bus_ids) ||
        throw(ArgumentError("Bus_id must be nonblank."))
    length(unique(proxy_ids)) == length(proxy_ids) ||
        throw(ArgumentError("Proxy_ID values must be unique."))
    length(unique(bus_ids)) == length(bus_ids) ||
        throw(ArgumentError("Bus_id values must be unique."))
    all(>(0.0), capacities) || throw(ArgumentError("Capacity_MW must be positive."))

    parent_path, config = load_case_config_for_holistic(
        parent_case;
        context = "materialize_compact_rps_gtep_case",
    )
    lowercase(_feedback_text(get(config, "model_mode", ""))) == "gtep" ||
        throw(ArgumentError("Parent case must use model_mode GTEP."))
    Int(get(config, "planning_reserve_mode", 0)) > 0 ||
        throw(ArgumentError("Parent case must enforce planning reserve adequacy."))
    Int(get(config, "clean_energy_policy", 0)) > 0 ||
        throw(ArgumentError("Parent case must enforce a clean-energy policy."))
    child_path = abspath(child_case)
    ispath(child_path) && throw(ArgumentError("Child case already exists: $(child_path)"))
    data_directory = normpath(joinpath(parent_path, String(config["DataCase"])))
    generation_path = joinpath(data_directory, "gendata.csv")
    zone_path = joinpath(data_directory, "zonedata.csv")
    isfile(generation_path) ||
        throw(ArgumentError("Parent generation table not found: $(generation_path)"))
    isfile(zone_path) || throw(ArgumentError("Parent zone table not found: $(zone_path)"))
    zones = CSV.read(zone_path, DataFrame)
    _compact_required_columns(zones, ["Zone_id"], "Parent zone table")
    String(external_zone) in strip.(string.(zones.Zone_id)) ||
        throw(ArgumentError("External zone $(external_zone) is absent from zonedata.csv."))
    generation = CSV.read(generation_path, DataFrame)
    _compact_required_columns(
        generation,
        ["GeneratorID", "Zone", "Type", "Pmax (MW)", "Asset_ID"],
        "Parent generation table",
    )
    isempty(intersect(Set(proxy_ids), Set(strip.(string.(generation.GeneratorID))))) ||
        throw(ArgumentError("A firm-contribution Proxy_ID already exists in the parent."))
    template_index = findfirst(==("NGCC"), strip.(string.(generation.Type)))
    template_index === nothing &&
        throw(ArgumentError("Parent generation table has no NGCC template row."))

    _copy_gtep_child_tree(parent_path, child_path)
    child_data = normpath(joinpath(child_path, String(config["DataCase"])))
    child_generation_path = joinpath(child_data, "gendata.csv")
    child_generation = CSV.read(child_generation_path, DataFrame)
    allowmissing!(child_generation)
    for row in eachindex(proxy_ids)
        proxy = _compact_proxy_row(
            child_generation,
            template_index,
            proxy_ids[row],
            bus_ids[row],
            capacities[row],
            String(external_zone),
            marginal_cost_per_mwh,
        )
        push!(child_generation, proxy; cols = :setequal, promote = true)
    end
    CSV.write(child_generation_path, child_generation)
    availability_contract = _compact_write_explicit_availability!(
        child_data,
        nrow(generation),
        child_generation,
    )

    settings_path = joinpath(child_path, "Settings", "HOPE_model_settings.yml")
    child_settings = YAML.load_file(settings_path)
    child_settings["solver"] = "highs"
    YAML.write_file(settings_path, child_settings)
    experiment_directory = joinpath(child_path, "Experiment")
    mkpath(experiment_directory)
    contribution_path = joinpath(experiment_directory, "firm_external_contribution.csv")
    CSV.write(
        contribution_path,
        DataFrame(Proxy_ID = proxy_ids, Bus_id = bus_ids, Capacity_MW = capacities),
    )
    contract = Dict{String,Any}(
        "artifact_type" => "HOPE.compact_rps_planning_contract",
        "schema_version" => 1,
        "status" => "materialized_pending_gtep_solve",
        "parent_case" => abspath(parent_path),
        "child_case" => child_path,
        "external_zone" => String(external_zone),
        "firm_external_contribution_mw" => sum(capacities),
        "external_energy_marginal_cost_usd_per_mwh" => marginal_cost_per_mwh,
        "external_resource_is_rps_eligible" => false,
        "enforced_constraints" =>
            ["system_planning_reserve_margin", "maryland_local_annual_rps"],
        "changed_data_files" => ["gendata.csv", "gen_availability_timeseries.csv"],
        "candidate_availability_contract" => Dict(
            "method" => "explicit_post_materialization_generator_columns",
            "candidate_profile_sources" =>
                availability_contract["candidate_profile_sources"],
            "proxy_columns_added" => availability_contract["proxy_columns_added"],
            "candidate_columns_added" =>
                availability_contract["candidate_columns_added"],
            "static_fallback_allowed_for_vre" => false,
        ),
        "limitations" => [
            "External resources are synthetic boundary-supply proxies, not physical generators or interconnection rights.",
            "Zero marginal decision cost represents a sunk baseline supply contract, not a wholesale-price forecast.",
            "PCM must retain the same proxy IDs, capacities, and declared boundary buses.",
            "The experiment does not establish firm PJM deliverability under contingencies.",
        ],
        "source_hashes" => Dict(
            "parent_gendata.csv" => bytes2hex(sha256(read(generation_path))),
            "child_gendata.csv" => bytes2hex(sha256(read(child_generation_path))),
            "child_gen_availability_timeseries.csv" =>
                bytes2hex(sha256(read(availability_contract["availability_path"]))),
        ),
    )
    contract_path = joinpath(experiment_directory, "planning_contract.yml")
    YAML.write_file(contract_path, contract)
    parent_manifest_path = joinpath(parent_path, "manifest.yml")
    manifest = isfile(parent_manifest_path) ? YAML.load_file(parent_manifest_path) : Dict()
    manifest isa AbstractDict || (manifest = Dict())
    child_manifest = Dict{String,Any}(string(key) => value for (key, value) in manifest)
    child_manifest["case_name"] = basename(child_path)
    child_manifest["source_case"] = abspath(parent_path)
    child_manifest["status"] = "materialized_pending_gtep_solve"
    child_manifest["experiment_contract"] = "Experiment/planning_contract.yml"
    child_manifest["validation"] =
        Dict("status" => "NOT_RUN", "parent_validation_not_inherited" => true)
    YAML.write_file(joinpath(child_path, "manifest.yml"), child_manifest)
    return Dict(
        "child_case" => child_path,
        "contract" => contract,
        "paths" => Dict(
            "contract" => contract_path,
            "contributions" => contribution_path,
            "manifest" => joinpath(child_path, "manifest.yml"),
        ),
    )
end

function _unitization_resource_policy(policy::AbstractDict, resource_type::AbstractString)
    _feedback_text(get(policy, "artifact_type", "")) ==
    "HOPE.capacity_plan_unitization_policy" ||
        throw(ArgumentError("Unitization policy artifact_type is invalid."))
    get(policy, "schema_version", nothing) == 1 ||
        throw(ArgumentError("Unitization policy schema_version must be 1."))
    resources = get(policy, "resources", nothing)
    resources isa AbstractDict ||
        throw(ArgumentError("Unitization policy requires a resources mapping."))
    type_name = String(resource_type)
    haskey(resources, type_name) ||
        throw(ArgumentError("No unitization policy exists for type $(resource_type)."))
    rule = _child_string_dict(resources[type_name], "unitization rule")
    target = _child_number(get(rule, "target_mw", nothing), "target_mw")
    minimum = _child_number(get(rule, "minimum_mw", nothing), "minimum_mw")
    maximum = _child_number(get(rule, "maximum_mw", nothing), "maximum_mw")
    0.0 < minimum <= target <= maximum || throw(
        ArgumentError(
            "Unitization sizes for $(resource_type) must satisfy 0 < minimum <= target <= maximum.",
        ),
    )
    return (target = target, minimum = minimum, maximum = maximum)
end

"""
    unitize_capacity_plan(capacity_plan, policy)

Split each continuous GTEP build into equal, capacity-conserving project blocks
inside declared minimum, target, and maximum sizes. Equal blocks avoid an
arbitrary residual project. Storage duration is preserved exactly.
"""
function unitize_capacity_plan(
    capacity_plan::AbstractDataFrame,
    policy::AbstractDict;
    tolerance_mw::Float64 = 1e-6,
)
    validate_capacity_plan(capacity_plan; atol = tolerance_mw)
    projects = DataFrame(
        Plan_Item_ID = String[],
        Resource_Kind = String[],
        Zone = String[],
        Type = String[],
        Build_MW = Float64[],
        Build_MWh = Float64[],
    )
    audit = DataFrame(
        ParentPlanItemID = String[],
        ResourceKind = String[],
        Zone = String[],
        Type = String[],
        ParentMW = Float64[],
        ParentMWh = Float64[],
        ProjectCount = Int[],
        ProjectMW = Float64[],
        ProjectMWh = Float64[],
    )
    for item in eachrow(capacity_plan)
        parent_id = _feedback_text(item.Plan_Item_ID)
        kind = lowercase(_feedback_text(item.Resource_Kind))
        zone = _feedback_text(item.Zone)
        resource_type = _feedback_text(item.Type)
        total_mw = Float64(item.Build_MW)
        total_mwh = Float64(item.Build_MWh)
        rule = _unitization_resource_policy(policy, resource_type)
        minimum_count = max(1, ceil(Int, total_mw / rule.maximum - 1e-12))
        maximum_count = floor(Int, total_mw / rule.minimum + 1e-12)
        minimum_count <= maximum_count || throw(
            ArgumentError(
                "Build $(parent_id) cannot be divided inside its unitization size bounds.",
            ),
        )
        preferred_count = max(1, round(Int, total_mw / rule.target))
        project_count = clamp(preferred_count, minimum_count, maximum_count)
        project_mw = total_mw / project_count
        project_mwh = total_mwh / project_count
        for index = 1:project_count
            project_id = string(parent_id, "__PROJECT_", lpad(index, 2, '0'))
            push!(
                projects,
                (project_id, kind, zone, resource_type, project_mw, project_mwh),
            )
        end
        push!(
            audit,
            (
                parent_id,
                kind,
                zone,
                resource_type,
                total_mw,
                total_mwh,
                project_count,
                project_mw,
                project_mwh,
            ),
        )
    end
    validate_capacity_plan(projects; atol = tolerance_mw)
    isapprox(sum(projects.Build_MW), sum(capacity_plan.Build_MW); atol = tolerance_mw) ||
        throw(ArgumentError("Unitization did not conserve total MW."))
    isapprox(sum(projects.Build_MWh), sum(capacity_plan.Build_MWh); atol = tolerance_mw) ||
        throw(ArgumentError("Unitization did not conserve total MWh."))
    sort!(projects, :Plan_Item_ID)
    sort!(audit, :ParentPlanItemID)
    return Dict("capacity_plan" => projects, "audit" => audit)
end

"""Add the declared GTEP firm-import proxy rows to a PCM input dictionary."""
function add_compact_planning_proxies_to_pcm(
    pcm_input::AbstractDict,
    gtep_input::AbstractDict,
)
    updated = deepcopy(pcm_input)
    pcm_generation = _computed_required_key(updated, "Gendata", "PCM input")
    gtep_generation = _computed_required_key(gtep_input, "Gendata", "GTEP input")
    "ScenarioStatus" in names(gtep_generation) ||
        throw(ArgumentError("GTEP generation table has no ScenarioStatus column."))
    proxy_rows = findall(
        value -> _feedback_text(value) == COMPACT_PLANNING_PROXY_STATUS,
        gtep_generation.ScenarioStatus,
    )
    isempty(proxy_rows) &&
        throw(ArgumentError("GTEP input contains no compact-planning proxy rows."))
    existing_ids = Set(strip.(string.(pcm_generation.Asset_ID)))
    proxy_ids = strip.(string.(gtep_generation[proxy_rows, "Asset_ID"]))
    isempty(intersect(existing_ids, Set(proxy_ids))) ||
        throw(ArgumentError("A compact-planning proxy Asset_ID already exists in PCM."))
    appended = copy(gtep_generation[proxy_rows, :])
    updated["Gendata"] = vcat(pcm_generation, appended; cols = :union)
    return updated
end

"""
    build_unitized_project_catalog(capacity_plan, topology_catalog, branchdata)

Convert topology-screened candidate buses into a discrete-project catalog for
an equal-block unitized plan. Development evidence is explicitly synthetic;
network identities and incident-rating proxies come from the PCM topology.
"""
function build_unitized_project_catalog(
    capacity_plan::AbstractDataFrame,
    topology_catalog::AbstractDataFrame,
    branchdata::AbstractDataFrame;
    alternatives_per_group::Int = 12,
    hard_exclusions_per_group::Int = 3,
    review_candidates_per_group::Int = 3,
    tolerance_mw::Float64 = 1e-6,
)
    validate_capacity_plan(capacity_plan; atol = tolerance_mw)
    validate_candidate_site_catalog(topology_catalog)
    alternatives_per_group > hard_exclusions_per_group >= 0 ||
        throw(ArgumentError("alternatives_per_group must exceed hard exclusions."))
    review_candidates_per_group >= 0 ||
        throw(ArgumentError("review_candidates_per_group must be nonnegative."))
    incident = _computed_incident_capacity(branchdata)
    catalog_parts = DataFrame[]
    for group in groupby(capacity_plan, [:Resource_Kind, :Zone, :Type])
        kind = _feedback_text(first(group.Resource_Kind))
        zone = _feedback_text(first(group.Zone))
        resource_type = _feedback_text(first(group.Type))
        project_mw = unique(round.(Float64.(group.Build_MW); digits = 9))
        project_mwh = unique(round.(Float64.(group.Build_MWh); digits = 9))
        length(project_mw) == 1 && length(project_mwh) == 1 || throw(
            ArgumentError(
                "Unitized projects for $(zone)/$(resource_type) must have equal sizes.",
            ),
        )
        mw = only(project_mw)
        mwh = only(project_mwh)
        matches = topology_catalog[
            (lowercase.(
                string.(topology_catalog.Resource_Kind)
            ).==kind).&(string.(
                topology_catalog.Zone
            ).==zone).&(string.(topology_catalog.Type).==resource_type),
            :,
        ]
        sort!(matches, :Candidate_Site_ID)
        nrow(matches) >= alternatives_per_group || throw(
            ArgumentError(
                "Need $(alternatives_per_group) topology candidates for $(zone)/$(resource_type); found $(nrow(matches)).",
            ),
        )
        part = copy(first(matches, alternatives_per_group))
        count_needed = nrow(group)
        eligible_count = alternatives_per_group - hard_exclusions_per_group
        eligible_count >= count_needed || throw(
            ArgumentError(
                "Only $(eligible_count) eligible projects remain for $(count_needed) required $(zone)/$(resource_type) blocks.",
            ),
        )
        rank_fraction =
            alternatives_per_group == 1 ? [0.0] :
            collect(0:(alternatives_per_group-1)) ./ (alternatives_per_group - 1)
        part[!, "Candidate_Site_ID"] = [
            string("PROJECT_SITE__", uppercase(kind), "__", resource_type, "__", bus)
            for bus in part.Bus_id
        ]
        part[!, "Site_ID"] = string.(part.Bus_id)
        part[!, "Candidate_Max_MW"] .= mw
        part[!, "Candidate_Max_MWh"] =
            kind == "storage" ? fill(mwh, alternatives_per_group) :
            fill(missing, alternatives_per_group)
        part[!, "Site_Max_MW"] = fill(mw, alternatives_per_group)
        part[!, "Site_Cost"] = rank_fraction
        part[!, "Resource_Quality_Score"] = 0.6 .+ 0.35 .* rank_fraction
        part[!, "Evidence_Confidence"] = 0.75 .+ 0.2 .* (1.0 .- rank_fraction)
        part[!, "Environmental_Sensitivity_Score"] = 1.0 .- rank_fraction
        part[!, "Permitting_Complexity_Score"] = rank_fraction
        part[!, "Community_Impact_Score"] = 1.0 .- rank_fraction
        part[!, "Interconnection_Cost_Score"] = Float64.(part.Network_Stress_Score)
        permit_status = fill("approved", alternatives_per_group)
        environmental = fill(true, alternatives_per_group)
        queue_status = fill("active", alternatives_per_group)
        community_review = fill(false, alternatives_per_group)
        review_start = max(1, eligible_count - review_candidates_per_group + 1)
        for row = review_start:eligible_count
            permit_status[row] = "conditional"
            community_review[row] = true
        end
        hard_exclusions_per_group >= 1 && (permit_status[eligible_count+1] = "denied")
        hard_exclusions_per_group >= 2 && (environmental[eligible_count+2] = false)
        hard_exclusions_per_group >= 3 && (queue_status[eligible_count+3] = "suspended")
        part[!, "Permit_Status"] = permit_status
        part[!, "Environmental_Eligible"] = environmental
        part[!, "Queue_Status"] = queue_status
        part[!, "Community_Review_Required"] = community_review
        part[!, "Interconnection_Headroom_MW"] =
            [get(incident, _feedback_text(bus), 0.0) for bus in part.Bus_id]
        land_required = kind == "storage" ? 0.1 * mw : 20.0 * mw
        part[!, "Land_Required_Acres"] = fill(land_required, alternatives_per_group)
        part[!, "Land_Available_Acres"] = fill(1.2 * land_required, alternatives_per_group)
        part[!, "Commercial_Operation_Year"] = fill(2035, alternatives_per_group)
        part[!, "Required_In_Service_Year"] = fill(2035, alternatives_per_group)
        part[!, "Evidence_Source"] = [
            string(
                "synthetic development evidence on HOPE PCM bus; incident rating proxy=",
                round(get(incident, _feedback_text(bus), 0.0); digits = 3),
                " MW",
            ) for bus in part.Bus_id
        ]
        push!(catalog_parts, part)
    end
    catalog = reduce((left, right) -> vcat(left, right; cols = :union), catalog_parts)
    validate_candidate_site_catalog(catalog)
    sort!(catalog, [:Resource_Kind, :Zone, :Type, :Candidate_Site_ID])
    return catalog
end
