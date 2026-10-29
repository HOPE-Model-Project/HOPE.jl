include(joinpath(@__DIR__, "run_md_compact_rps_planning.jl"))

const ENERGY_THERMAL_EXAMPLE =
    joinpath(MODEL_CASES, "MD_COMPACT_ENERGY_THERMAL_REALIZATION_EXAMPLE_V1")

if abspath(PROGRAM_FILE) == @__FILE__
    exit(run_compact_planning(ENERGY_THERMAL_EXAMPLE, ARGS))
end
