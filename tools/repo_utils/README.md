# Repo Utils

This folder contains general repository utilities that are not specific to a single example case.

## Holistic Case Utilities

- `audit_holistic_case_pair.jl`: validate that a paired GTEP and PCM case use a topology-compatible holistic setup before solving.
- `build_md_holistic_full_pair.jl`: build the canonical Maryland full-year holistic benchmark pair.
- `build_md_restricted_linkage_pair.jl`: build the compact Maryland stress pair that verifies retirement, generation, storage, and transmission transfer with a machine-readable acceptance contract.
- `build_pjm_holistic_canonical_pair.jl`: build the canonical PJM holistic benchmark pair.
- `build_pjm_holistic_mixed_pair.jl`: build the mixed PJM holistic benchmark pair used for chronology and workflow experiments.

Supporting notes and case-specific helpers for those benchmarks are organized under:

- `md_holistic_full_pair/`
- `pjm_holistic_canonical_pair/`
- `pjm_holistic_mixed_pair/`

## General Repository Utilities

- `generate_case_network_svgs.ps1`: regenerate SVG network figures used by case documentation.
- `generate_matpower_pcm_cases.jl`: build HOPE PCM case inputs from MATPOWER-style source data.
- `migrate_timeseries_time_columns.jl`: normalize legacy time-series input files to the current time-column layout.
- `serve_docs.ps1`: serve the generated `docs/build/` site locally for review.
