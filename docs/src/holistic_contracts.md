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

The current rules, known limitations, and proposed replacements are tracked by
stable IDs in the [Holistic Linkage Assumption and Decision Log](holistic_assumption_log.md).

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

### Spatial and parameter realization

With `explicit_bus`, GTEP can remain mathematically zonal while each candidate
row carries three linkage fields: `Planning_Zone`, `Bus_id`, and
`Candidate_ID`. GTEP selects the capacity associated with that candidate. The
linkage then creates one or more PCM rows at the declared bus, verifies that the
bus exists and belongs to the declared planning zone, and assigns stable
`<Candidate_ID>__UNIT_<sequence>` asset identities. HOPE does not infer a bus
from geography during this step.

The solved GTEP capacity determines the realized PCM `Pmax`. Without
`PCM_Unit_Size_MW`, one candidate becomes one aggregate PCM row. With that
column, HOPE splits the aggregate build into fixed-size physical units under the
rules below.

Existing resources remain owned by each model's source input. `Asset_ID`
provides the crosswalk, and a GTEP retirement changes the corresponding PCM
capacity; the linkage does not replace the PCM resource's other operational
parameters. For a new resource, candidate values are copied first. Missing PCM
numeric fields are filled from existing PCM resources in this order:

1. mean for the same `Zone` and `Type`;
2. mean for the same `Type`; and
3. a conservative code default.

`Operational_Template_ID` is currently retained in the realized row and audit
trail as provenance. It does not yet select a separate parameter-registry row.
Cases that require technology-specific commitment, ramp, reserve, startup, or
minimum-output behavior must therefore provide those values on the candidate
row. A future template registry can make this precedence explicit without
changing the GTEP or PCM formulations.

`legacy_zone` is backward compatibility for already compatible zonal pairs. It
is not a general zonal-to-nodal siting algorithm. A zonal-only GTEP paired with
a nodal PCM still needs linkage information such as an explicit bus, an
approved candidate-bus mapping table, or a documented allocation rule.

It also provides two optional, backward-compatible physical-fleet rules:

- Add `PCM_Unit_Size_MW` to a generation-candidate row to split its solved
  aggregate build into fixed-size PCM units. Each realized row receives a stable
  `<Candidate_ID>__UNIT_<sequence>` identity. A non-unit-commitment candidate may
  have one smaller final unit; a `Flag_UC = 1` candidate must build an integer
  number of units. If the column is absent, HOPE preserves the historical
  one-candidate/one-PCM-row behavior.
- Add `retirement_realization` to the physical contract to choose
  `largest_first`, `smallest_first`, or an explicit numeric `priority` for
  disaggregating an aggregate GTEP retirement among physical units. The default
  remains `proportional_capacity`. `partial_unit_policy` can allow one capacity
  reduction or reject a transfer that cannot retire whole units exactly.

For example:

```yaml
retirement_realization:
  method: priority
  priority_column: Retirement_Priority
  partial_unit_policy: reject
```

These rules change only the realization of solved planning decisions; they do
not change the GTEP or PCM mathematical formulations.

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
- `transfer_reconciliation.yml`: independent capacity-conservation and identity
  results for the solved GTEP decisions and realized PCM tables;
- `transfer_reconciliation_checks.csv`: one machine-readable row per retirement,
  generation, storage, transmission, operating-bound, or stable-ID assertion.

The reconciliation runs before the PCM model is constructed. It compares the
solved GTEP decisions with both the source and realized PCM physical tables and
fails fast if capacity is lost or duplicated. Directional transmission additions
are also checked through the linkage audit, while the physical table check uses
total bidirectional capacity so reversed branch orientation is handled correctly.

The returned result dictionary also provides `handoff_contract` and
`handoff_contract_paths`.

This deterministic package is suitable for a future model agent: the agent can
exchange a compact manifest and hashes while the numerical tables remain the
source of truth.
