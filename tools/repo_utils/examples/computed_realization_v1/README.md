# Computed realization v1 example

This small synthetic example exercises the deterministic
`constrained_site_allocate_v1` tool. It is an interface example, not a physical
Maryland or PJM siting claim.

From the repository root, run:

```powershell
julia --project=. tools/repo_utils/compute_nodal_realizations.jl `
  tools/repo_utils/examples/computed_realization_v1/capacity_plan.csv `
  tools/repo_utils/examples/computed_realization_v1/candidate_site_catalog.csv `
  tools/repo_utils/examples/computed_realization_v1/realization_policy.yml `
  artifacts/computed_realization_v1_example
```

The output package contains:

- `nodal_allocations.csv`: plan-item to candidate-site and PCM-bus allocations
  for every policy variant;
- `candidate_screening.csv`: hard screening decisions and reasons;
- `realization_summary.csv`: objective and conservation totals by variant; and
- `realization_set.yml`: input/output SHA-256 hashes and artifact metadata.

The example includes generation, four-hour storage, a capacity-constrained
existing NGCC site, and an excluded solar site. Source evidence and network
screen results are illustrative only.
