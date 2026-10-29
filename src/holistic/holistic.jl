"""
Holistic planning, realization, assessment, and adaptive-study subsystem.

This file is an include aggregator, not a nested Julia module. All public names
remain in `HOPE`; the ordered includes make the subsystem boundary visible
without changing the package API.
"""

# Case input extensions used by the core data reader.
include("holistic_operational_templates.jl")

# Planning-to-operation linkage and physical realization.
include("holistic_linkage.jl")
include("computed_realization.jl")
include("computed_realization_handoff.jl")
include("holistic_coverage.jl")
include("realization_ensemble.jl")

# Findings, bounded revisions, and adaptive-study orchestration.
include("adaptive_feedback.jl")
include("adaptive_study.jl")
include("gtep_child_scenario.jl")
include("planning_feedback_diagnostic.jl")

# Contracts, executable workflows, compact experiments, and benchmarks.
include("holistic_contract.jl")
include("run_holistic.jl")
include("compact_planning_experiment.jl")
include("holistic_benchmark.jl")
