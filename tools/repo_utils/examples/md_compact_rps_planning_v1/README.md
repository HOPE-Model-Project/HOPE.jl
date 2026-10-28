# Maryland compact RPS planning experiment v1

This example drives an RPS- and reserve-constrained Maryland GTEP plan through
project unitization, restricted nodal realization, and July PCM assessment.

Inputs:

- `firm_external_contribution.csv`: 13,525.82 MW of synthetic, non-RPS firm
  external supply split among four declared PCM boundary buses;
- `unitization_policy.yml`: deterministic capacity-conserving project sizes;
- `realization_policy.yml`: four siting preference variants with hard screens;
  and
- `operational_resource_templates.csv`: reviewed PCM construction templates.

Run with new output paths:

```powershell
julia --project=. tools/repo_utils/run_md_compact_rps_planning.jl `
  artifacts/computed_realization_runs/md_compact_rps_planning_trial highs

julia --project=. tools/repo_utils/run_md_compact_rps_pcm_ensemble.jl `
  artifacts/computed_realization_runs/md_compact_rps_planning_trial `
  artifacts/computed_realization_runs/md_compact_rps_pcm_trial gurobi
```

The validated result builds 4,807.474 MW of DPL Maryland solar and unitizes it
as nine 534.164 MW projects. Eleven of eighteen candidate buses survive hard
screening. All physical portfolios pass PCM RPS and load-shedding gates;
`least_cost` is accepted, while the other policy labels retain one explicit
human-review project.

The external-supply and development-evidence fields are synthetic workflow
assumptions, not claims about actual Maryland projects, permits, queues, or PJM
deliverability.
