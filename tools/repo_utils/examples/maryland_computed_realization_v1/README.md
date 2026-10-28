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

## Automatic holistic-run activation

`HOPE_physical_realization.computed.example.yml` is an opt-in replacement for
the Maryland GTEP case's `Settings/HOPE_physical_realization.yml`. Use it only
in a fresh study workspace; the repository's canonical case remains on
`explicit_bus` for regression stability.

When both resource-siting methods are `computed_allocation`,
`run_hope_holistic` automatically performs the following after GTEP solves and
before PCM is constructed:

1. create the immutable capacity plan;
2. generate every policy-declared realization;
3. select the named variant;
4. verify bus references, planning-zone consistency, and physical connectivity;
5. report allocation-to-incident-rating ratios and enforce a threshold only if
   the contract explicitly supplies one; and
6. materialize the selected allocation through the existing PCM linkage.

The realized-input directory records the plan, all allocations, catalog
screening, realization summary, materialization audit, and fast-screen checks.
