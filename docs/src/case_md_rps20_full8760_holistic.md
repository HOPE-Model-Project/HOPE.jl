# Maryland Full-Year 20% RPS Physical Holistic Benchmark

This is HOPE's canonical high-resolution Maryland GTEP-to-PCM benchmark. It
combines an aggregated planning view with a detailed physical operating view
without pretending that the two resolutions are identical:

- GTEP represents four Maryland planning zones plus an external boundary.
- PCM realizes those decisions on 656 transmission buses and 838 branches.
- Both source cases retain all 8760 chronological hours.
- Maryland has a moderate local 20% RPS; the external zone has no RPS target.

The paired ModelCases are:

- `MD_GTEP_RPS20_4zone_full8760_public_case`
- `MD_PCM_RPS20_transmission_full8760_public_case`

The assumptions behind spatial realization, parameter transfer, validation
scope, and computing limits are registered under stable IDs in the
[Holistic Linkage Assumption and Decision Log](holistic_assumption_log.md).

Their raw inputs are in, respectively:

- `Data_MD_GTEP_RPS20_4zone_full8760_public/`
- `Data_MD_PCM_RPS20_transmission_full8760_public/`

## Planning-to-operations contract

Stable asset and candidate identities, explicit candidate bus assignments, and
corridor/endpoint line mapping make the transfer deterministic. HOPE writes the
post-GTEP PCM tables to `output_holistic/realized_inputs/` and leaves the source
case unchanged. The physical-realization audit checks 271 existing generators,
12 generation candidates, 4 storage candidates, all 838 branches, and all 656
buses.

GTEP has one upward operating-reserve product, while PCM has 1% REG-UP, 3%
SPIN, and 3% NSPIN. The GTEP proxy is therefore 7% of load so planning does not
understate the aggregate upward capability required in operations.

The network is a geographically grounded synthetic reconstruction based on
OpenStreetMap, not an official PJM model. OSM provides topology and geography;
ratings, reactance, transformer details, generator mapping, and external
interfaces are documented assumptions. A July deliverability screen identified
one inferred 500 MW intra-PEPCO rating that bound during the only shedding hour.
The benchmark calibrates `OSM_L1528639488` to 600 MW in both directions and
records this assumption in `references/physical_deliverability_adjustments.csv`.

## Validation result

The full 8760-hour GTEP stage reached `OPTIMAL` with Gurobi 13.0.0, objective
2,396,599,492.17 USD, zero load shedding, and zero RPS slack. The network audit
found one connected component containing every Maryland planning zone and the
external boundary.

The strict handoff and detailed PCM formulation were validated on all 744 hours
of July while retaining the annual GTEP solve. PCM reached `OPTIMAL`, objective
201,932,586.63 USD, zero load shedding, zero RPS slack, and passed every
machine-readable acceptance check. This exercises nodal angle-based DCOPF,
unit commitment, all four reserve products, storage chronology, the local RPS,
transferred generation and storage, and source-case immutability.

The monolithic 656-bus by 8760-hour PCM construction was also attempted without
reducing the source inputs. It exhausted memory on the 32 GB validation
workstation at about 27.6 GB private memory. Consequently, an annual PCM result
is **not** claimed. The published case remains full-year and should be run on a
higher-memory machine. A future exact rolling-horizon implementation must carry
commitment, dispatch, storage state of charge, and annual REC accounting across
windows; simply solving independent months would change the model.

## Run and audit

Run the full pair on a sufficiently large machine:

```sh
julia --project=. ModelCases/MD_GTEP_RPS20_4zone_full8760_public_case/run_holistic_pair.jl
```

Validate the published inputs and mappings without solving:

```sh
python ModelCases/tools/md_transmission_case_related/build_md_rps20_full8760_holistic_pair.py --validate-only
julia --project=. tools/repo_utils/audit_holistic_case_pair.jl ModelCases/MD_GTEP_RPS20_4zone_full8760_public_case ModelCases/MD_PCM_RPS20_transmission_full8760_public_case
julia --project=. tools/repo_utils/audit_pcm_network_components.jl ModelCases/MD_PCM_RPS20_transmission_full8760_public_case
```

For bounded workstation validation, create an isolated July workspace. This
does not alter either published source case:

```sh
python ModelCases/tools/md_transmission_case_related/build_md_rps20_full8760_holistic_pair.py --validation-month 7 --validation-root artifacts/agent_runs/md-rps20-july-validation
julia --project=. artifacts/agent_runs/md-rps20-july-validation/run_pair.jl
```

The detailed solved-data report is in the PCM case's
[`references/VALIDATION.md`](https://github.com/HOPE-Model-Project/HOPEModelCases/blob/main/MD_PCM_RPS20_transmission_full8760_public_case/references/VALIDATION.md).
Its companion `july_linkage_validation_summary.csv` provides a compact
machine-readable record of the annual GTEP decisions, exact handoff
reconciliation, and July PCM operating results.
