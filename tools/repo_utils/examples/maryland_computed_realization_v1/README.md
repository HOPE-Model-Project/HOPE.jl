# Maryland Computed-Realization Inputs

This directory contains the first reproducible Maryland candidate-site catalog
and realization policy for `constrained_site_allocate_v1`.

`candidate_site_catalog.csv` is generated from the public Maryland GTEP and PCM
cases by `tools/repo_utils/build_computed_site_catalog.jl`. It retains the three
highest-ranked existing interconnection buses in each of the four Maryland
planning zones, using existing installed capacity and incident branch ratings
as transparent topology proxies. The resulting catalog contains 48
technology-specific rows over 12 physical buses.

The catalog is suitable for workflow development and topology-screened PCM
handoff testing. It is not a claim that these buses are fully permitted,
queue-approved, environmentally acceptable, or optimal renewable sites.
Renewable resource quality is intentionally fixed at the neutral value `0.5`.

Regenerate the catalog from the repository root with:

```powershell
julia --project=. tools/repo_utils/build_computed_site_catalog.jl `
  ModelCases/MD_GTEP_RPS20_4zone_public_case/Data_MD_GTEP_RPS20_4zone_public `
  ModelCases/MD_PCM_RPS20_transmission_public_case/Data_MD_PCM_RPS20_transmission_public `
  tools/repo_utils/examples/maryland_computed_realization_v1/candidate_site_catalog.csv `
  3
```

At runtime, a solved GTEP result is converted with
`HOPE.capacity_plan_from_gtep`, allocated with
`HOPE.compute_nodal_realizations`, and transferred to PCM with
`HOPE.prepare_pcm_inputs_from_computed_realization`.
