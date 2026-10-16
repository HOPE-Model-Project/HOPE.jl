# Holistic Handoff and Physical-Realization Contracts

HOPE validates a GTEP-to-PCM pair through a solver-independent handoff contract
before either optimization starts. The contract separates three kinds of
information:

1. **Transferred physical state:** assets, retirements, new generation and
   storage, branches, ratings, locations, and stable identities.
2. **Recomputed operational state:** PCM commitment, dispatch, reserves,
   storage state, and prices.
3. **Model-local assumptions:** policy interpretation, temporal reduction,
   aggregation, network formulation, and solver controls.

This separation prevents a planning assumption from being silently treated as
a physical PCM asset while preserving standalone GTEP and PCM operation.

## Preflight validation

Use the public API to validate a pair without invoking a solver:

```julia
using HOPE

report = HOPE.validate_holistic_handoff_contract(
    "ModelCases/MD_GTEP_RPS20_4zone_public_case",
    "ModelCases/MD_PCM_RPS20_transmission_public_case",
)
```

Or use the repository command:

```powershell
julia --project=. tools/repo_utils/audit_holistic_case_pair.jl `
  ModelCases/MD_GTEP_RPS20_4zone_public_case `
  ModelCases/MD_PCM_RPS20_transmission_public_case
```

The validator checks:

- model modes, spatial bases, planning nodes, loads, and corridors;
- nonblank and unique `Asset_ID` and `Candidate_ID` values when supplied;
- cross-stage resolution of existing assets;
- candidate `Bus_id` values and agreement with PCM `busdata.Zone_id`;
- candidate transmission realization through `Corridor_ID` or explicit PCM
  endpoints;
- declared bus, branch, and planning-node counts;
- source-register existence and provenance columns; and
- SHA-256 fingerprints for every file under both source `DataCase` folders.

Legacy cases do not need a new contract file. They retain the validated legacy
row or aggregate mapping and receive a warning-level `physical_realization_contract`
check. A case that supplies `Settings/HOPE_physical_realization.yml` opts into
the stricter physical checks.

## Versioned physical-realization schema

The normative version-1 field definition is stored at
`schemas/holistic_physical_realization_v1.yml`. A case contract begins with:

```yaml
schema_version: 1
artifact_type: HOPE.physical_realization
workflow: GTEP-PCM
```

Version 1 supports these resource-siting rules:

- `explicit_bus`: each GTEP candidate identifies an exact PCM `Bus_id`;
- `legacy_zone`: retain the compatible historical zonal mapping.

It supports these transmission rules, evaluated in declared priority order:

- `corridor_id`;
- `explicit_endpoints` using `PCM_from_bus` and `PCM_to_bus`; and
- `proportional_parallel_corridor` for compatible zonal networks.

The contract also records the source register, licensing or terms, transformations,
and confidence labels that distinguish observed, derived, inferred, and assumed
network fields. OpenStreetMap-derived topology therefore remains distinguishable
from inferred electrical parameters and assumed candidate siting.

## Runtime integrity and reports

`run_hope_holistic` automatically discovers the GTEP case contract, validates it
before solving, and fingerprints every source data file. After PCM completes,
HOPE recomputes the fingerprints and fails if a source input changed.

The output contains two additional artifacts under `realized_inputs/`:

- `handoff_contract.yml`: version, validation results, physical contract, and
  complete source fingerprints;
- `handoff_contract_checks.csv`: one row per topology, identity, realization,
  provenance, or immutability assertion.

The returned result dictionary also provides `handoff_contract` and
`handoff_contract_paths`.

This deterministic package is suitable for a future model agent: the agent can
exchange a compact manifest and hashes while the numerical tables remain the
source of truth.
