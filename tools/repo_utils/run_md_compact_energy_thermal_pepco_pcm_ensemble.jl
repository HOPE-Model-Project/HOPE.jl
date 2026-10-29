include(joinpath(@__DIR__, "run_md_compact_rps_pcm_ensemble.jl"))

const ENERGY_THERMAL_PEPCO_EXAMPLE =
    joinpath(MODEL_CASES, "MD_COMPACT_ENERGY_THERMAL_PEPCO_FEEDBACK_V1")

if abspath(PROGRAM_FILE) == @__FILE__
    exit(run_compact_pcm_ensemble(ENERGY_THERMAL_PEPCO_EXAMPLE, ARGS))
end
