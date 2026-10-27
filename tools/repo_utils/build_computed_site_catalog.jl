using HOPE
using CSV
using DataFrames

function usage(io::IO = stdout)
    println(
        io,
        "Usage: julia --project=. tools/repo_utils/build_computed_site_catalog.jl " *
        "<gtep_data_directory> <pcm_data_directory> <output.csv> [sites_per_zone]",
    )
end

function main(args::Vector{String} = ARGS)
    length(args) in (3, 4) || (usage(stderr); return 2)
    gtep_dir, pcm_dir, output_path = abspath.(args[1:3])
    sites_per_zone = length(args) == 4 ? parse(Int, args[4]) : 3
    required = Dict(
        "generation candidates" => joinpath(gtep_dir, "gendata_candidate.csv"),
        "storage candidates" => joinpath(gtep_dir, "storagedata_candidate.csv"),
        "PCM generation" => joinpath(pcm_dir, "gendata.csv"),
        "PCM buses" => joinpath(pcm_dir, "busdata.csv"),
        "PCM branches" => joinpath(pcm_dir, "branchdata.csv"),
    )
    missing = ["$(label): $(path)" for (label, path) in required if !isfile(path)]
    isempty(missing) || throw(ArgumentError("Missing input files: $(join(missing, "; "))."))
    catalog = HOPE.build_candidate_site_catalog_from_pcm(
        CSV.read(required["generation candidates"], DataFrame),
        CSV.read(required["storage candidates"], DataFrame),
        CSV.read(required["PCM generation"], DataFrame),
        CSV.read(required["PCM buses"], DataFrame);
        branchdata = CSV.read(required["PCM branches"], DataFrame),
        sites_per_zone = sites_per_zone,
    )
    mkpath(dirname(output_path))
    CSV.write(output_path, catalog)
    println("HOPE_CANDIDATE_SITE_CATALOG=$(output_path)")
    println("HOPE_CANDIDATE_SITE_ROWS=$(nrow(catalog))")
    println("HOPE_CANDIDATE_SITE_BUSES=$(length(unique(catalog.Bus_id)))")
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    try
        exit(main())
    catch error
        showerror(stderr, error)
        println(stderr)
        exit(1)
    end
end
