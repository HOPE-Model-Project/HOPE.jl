# Maryland 20% RPS Public-Data Holistic Benchmark

This benchmark links an aggregated four-zone Maryland GTEP case to a
656-bus transmission-level PCM realization under a moderate 20% local RPS.

The paired ModelCases are:

- `MD_GTEP_RPS20_4zone_public_case`
- `MD_PCM_RPS20_transmission_public_case`

The physical network is a documented OpenStreetMap-derived reconstruction,
not an official PJM model. GTEP candidate resources carry predefined physical
bus identities so zonal investments can be transferred deterministically to
PCM without modifying either source case.

## Enabled workflow features

The GTEP stage enables local RPS compliance, system planning reserve, spinning
reserve, generation and storage investment, and transmission-expansion
options. The PCM stage enables nodal angle-based DCOPF, unit commitment,
REG-UP, REG-DOWN, SPIN, NSPIN, storage chronology, and the same local RPS.

Transmission losses and flexible demand are disabled because the public-data
case does not contain validated resistance or demand-response inputs. The
compact restricted Maryland linkage benchmark separately exercises retirement,
line expansion, demand response, and loss transfer under deliberately stressed
assumptions.

## Run

```julia
using HOPE
HOPE.run_hope_holistic(
    "ModelCases/MD_GTEP_RPS20_4zone_public_case",
    "ModelCases/MD_PCM_RPS20_transmission_public_case",
)
```

The case runner also evaluates its acceptance contract:

```sh
julia --project=. ModelCases/MD_GTEP_RPS20_4zone_public_case/run_holistic_pair.jl
```

## Validated result

The complete pair was validated with Gurobi 13.0.0. Both stages reached
`OPTIMAL`, with zero load shedding and zero RPS slack. GTEP built 29,021.0 MW
of generation and 6,188.4 MW / 24,753.5 MWh of storage. The nodal PCM stage
dispatched transferred generation and storage, carried all four operating-
reserve products, and passed every machine-readable acceptance check. Hashes
confirmed that neither source input tree changed during the workflow.

## Physical interpretation

The GTEP model sees four Maryland planning zones plus an external boundary.
Candidate rows include `Bus_id`, `Planning_Zone`, and stable candidate identity.
The PCM model retains 656 reconstructed transmission buses, 838 branches, and
explicit external-boundary buses with bounded net interchange.

OSM supplies geographic and corridor evidence. Line reactance, ratings,
transformers, generator siting, and the external corridor proxy are inferred
assumptions recorded in the case provenance tables. The resulting case should
be described as a geographically grounded synthetic benchmark.
