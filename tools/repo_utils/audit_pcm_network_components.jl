using CSV
using DataFrames
using YAML

function usage(io::IO = stdout)
    println(io, "Usage: julia --project=. tools/repo_utils/audit_pcm_network_components.jl <pcm_case> [realized_inputs]")
end

function first_column(table::AbstractDataFrame, candidates::Vector{String})
    available = Set(string.(names(table)))
    for candidate in candidates
        candidate in available && return candidate
    end
    error("Missing required column; expected one of $(join(candidates, ", "))")
end

mutable struct UnionFind
    parent::Vector{Int}
    rank::Vector{Int}
end

UnionFind(n::Int) = UnionFind(collect(1:n), zeros(Int, n))

function find_root!(sets::UnionFind, item::Int)
    while sets.parent[item] != item
        sets.parent[item] = sets.parent[sets.parent[item]]
        item = sets.parent[item]
    end
    return item
end

function union_roots!(sets::UnionFind, left::Int, right::Int)
    left_root = find_root!(sets, left)
    right_root = find_root!(sets, right)
    left_root == right_root && return
    if sets.rank[left_root] < sets.rank[right_root]
        sets.parent[left_root] = right_root
    elseif sets.rank[left_root] > sets.rank[right_root]
        sets.parent[right_root] = left_root
    else
        sets.parent[right_root] = left_root
        sets.rank[left_root] += 1
    end
end

to_float(value) = ismissing(value) || isempty(strip(string(value))) ? 0.0 : parse(Float64, string(value))

function main(args::Vector{String} = ARGS)
    if length(args) < 1 || length(args) > 2
        usage(stderr)
        return 2
    end
    case_path = abspath(args[1])
    settings_path = joinpath(case_path, "Settings", "HOPE_model_settings.yml")
    isfile(settings_path) || error("Settings file not found: $(settings_path)")
    settings = YAML.load_file(settings_path)
    data_path = joinpath(case_path, string(settings["DataCase"]))
    realized_path = length(args) == 2 ? abspath(args[2]) : data_path

    buses = CSV.read(joinpath(data_path, "busdata.csv"), DataFrame)
    branches = CSV.read(joinpath(data_path, "branchdata.csv"), DataFrame)
    generators = CSV.read(joinpath(realized_path, "gendata.csv"), DataFrame)
    storage = CSV.read(joinpath(realized_path, "storagedata.csv"), DataFrame)

    bus_col = first_column(buses, ["Bus_id", "bus_id", "Bus"])
    zone_col = first_column(buses, ["Zone_id", "Zone", "zone_id"])
    demand_col = first_column(buses, ["Demand (MW)", "Load (MW)", "Pd", "PD"])
    from_col = first_column(branches, ["from_bus", "From_bus", "F_BUS"])
    to_col = first_column(branches, ["to_bus", "To_bus", "T_BUS"])
    gen_bus_col = first_column(generators, ["Bus_id", "bus_id", "Bus"])
    gen_capacity_col = first_column(generators, ["Pmax (MW)"])
    storage_bus_col = first_column(storage, ["Bus_id", "bus_id", "Bus"])
    storage_capacity_col = first_column(storage, ["Max Power (MW)"])

    bus_ids = string.(buses[!, bus_col])
    bus_index = Dict(id => index for (index, id) in pairs(bus_ids))
    length(bus_index) == length(bus_ids) || error("Bus IDs must be unique")
    sets = UnionFind(length(bus_ids))
    for row in eachrow(branches)
        from_bus = string(row[from_col])
        to_bus = string(row[to_col])
        haskey(bus_index, from_bus) || error("Unknown branch endpoint $(from_bus)")
        haskey(bus_index, to_bus) || error("Unknown branch endpoint $(to_bus)")
        union_roots!(sets, bus_index[from_bus], bus_index[to_bus])
    end

    roots = [find_root!(sets, index) for index in eachindex(bus_ids)]
    root_ids = Dict(root => number for (number, root) in pairs(sort(unique(roots))))
    component_of_bus = Dict(bus_ids[index] => root_ids[roots[index]] for index in eachindex(bus_ids))
    component_count = length(root_ids)
    rows = DataFrame(
        Component = collect(1:component_count),
        Buses = zeros(Int, component_count),
        Branches = zeros(Int, component_count),
        Zones = fill("", component_count),
        PeakDemandMW = zeros(component_count),
        GenerationMW = zeros(component_count),
        StorageMW = zeros(component_count),
    )
    zone_sets = [Set{String}() for _ in 1:component_count]
    for row in eachrow(buses)
        component = component_of_bus[string(row[bus_col])]
        rows[component, :Buses] += 1
        rows[component, :PeakDemandMW] += to_float(row[demand_col])
        push!(zone_sets[component], string(row[zone_col]))
    end
    for row in eachrow(branches)
        component = component_of_bus[string(row[from_col])]
        rows[component, :Branches] += 1
    end
    for row in eachrow(generators)
        bus = string(row[gen_bus_col])
        haskey(component_of_bus, bus) || error("Generator references unknown bus $(bus)")
        rows[component_of_bus[bus], :GenerationMW] += to_float(row[gen_capacity_col])
    end
    for row in eachrow(storage)
        bus = string(row[storage_bus_col])
        haskey(component_of_bus, bus) || error("Storage references unknown bus $(bus)")
        rows[component_of_bus[bus], :StorageMW] += to_float(row[storage_capacity_col])
    end
    rows[!, :Zones] = [join(sort(collect(zones)), "|") for zones in zone_sets]
    rows[!, :DemandWithoutSupply] =
        (rows.PeakDemandMW .> 0.0) .& ((rows.GenerationMW .+ rows.StorageMW) .<= 0.0)
    sort!(rows, [:PeakDemandMW, :Buses], rev = true)

    println("PCM_NETWORK_COMPONENTS=$(component_count)")
    println("PCM_LARGEST_COMPONENT_BUSES=$(maximum(rows.Buses))")
    println("PCM_DEMAND_COMPONENTS=$(count(rows.PeakDemandMW .> 0.0))")
    println("PCM_DEMAND_WITHOUT_LOCAL_SUPPLY_COMPONENTS=$(count(rows.DemandWithoutSupply))")
    show(stdout, MIME("text/plain"), rows)
    println()
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
