# Repo Utils

This folder contains general repository utilities that are not specific to a single example case.

## Holistic Case Utilities

- `audit_holistic_case_pair.jl`: validate that a paired GTEP and PCM case use a topology-compatible holistic setup before solving.
- `audit_pcm_network_components.jl`: audit nodal PCM connectivity and identify demand-bearing components without local generation or storage.
- `build_md_holistic_full_pair.jl`: build the canonical Maryland full-year holistic benchmark pair.
- `build_md_restricted_linkage_pair.jl`: build the compact Maryland stress pair that verifies retirement, generation, storage, and transmission transfer with a machine-readable acceptance contract.
- `build_md_transfer_coverage_benchmark.py`: derive an isolated 8760-hour Maryland GTEP/July 656-bus PCM stress workspace from the canonical cases, with documented test-only assumptions that exercise retirement and transmission realization.
- `build_pjm_holistic_canonical_pair.jl`: build the canonical PJM holistic benchmark pair.
- `build_pjm_holistic_mixed_pair.jl`: build the mixed PJM holistic benchmark pair used for chronology and workflow experiments.
- `run_holistic_agent_job.jl`: thin command-line adapter used by MCP/agent jobs to run the core `HOPE.run_hope_holistic` workflow and update a persistent run manifest.

The transfer implementation itself is package code, not a utility script:

- `src/holistic_linkage.jl` realizes retirements and generation, storage, and transmission builds;
- `src/holistic_contract.jl` validates identity, topology, siting, provenance, and source immutability; and
- `src/run_holistic.jl` orchestrates the two solves and persists realized PCM inputs and audits.

Files under `artifacts/agent_runs/` and `artifacts/benchmarks/` are generated run
workspaces and are ignored by Git. They are not package modules, published
ModelCases inputs, or end-user deliverables.

Supporting notes and case-specific helpers for those benchmarks are organized under:

- `md_holistic_full_pair/`
- `pjm_holistic_canonical_pair/`
- `pjm_holistic_mixed_pair/`

## General Repository Utilities

- `generate_case_network_svgs.ps1`: regenerate SVG network figures used by case documentation.
- `generate_matpower_pcm_cases.jl`: build HOPE PCM case inputs from MATPOWER-style source data.
- `migrate_timeseries_time_columns.jl`: normalize legacy time-series input files to the current time-column layout.
- `serve_docs.ps1`: serve the generated `docs/build/` site locally for review.

## Holistic Benchmark Evidence

`report_holistic_benchmark.jl` converts a published GTEP-to-PCM run into a
human-readable and machine-readable evidence bundle. It checks the run,
handoff, transfer reconciliation, source immutability, candidate-to-bus
physical realization, retirement and transmission audits, and
evaluation-period operating evidence.

```powershell
julia --project=. tools/repo_utils/report_holistic_benchmark.jl `
  <run-workspace> [output-directory] [validation-slice.yml] [expected.yml]
```

Pass the validation-slice metadata for a warm-up run so the report separates
the warm-up and evaluation periods. Pass an expected-values YAML file to turn
the internal-consistency report into a numerical regression benchmark.
