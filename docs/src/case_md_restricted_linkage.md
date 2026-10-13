# Maryland Restricted GTEP-to-PCM Linkage Benchmark

The restricted Maryland benchmark is a compact, deterministic acceptance test
for HOPE's GTEP-to-PCM workflow. It uses two real Maryland OpenStreetMap
transmission identifiers as the common physical basis, then applies deliberately
reduced ratings and synthetic 24-hour operating assumptions so that transfer
behavior is observable. It is a software integration benchmark, not a forecast
or calibrated Maryland system study.

The paired cases are:

- `ModelCases/MD_GTEP_restricted_linkage_case`
- `ModelCases/MD_PCM_restricted_linkage_case`

## What the benchmark exercises

The GTEP stage enables binary generation, storage, and transmission investment;
generator retirement; zonal planning reserve; spinning reserve; RPS; flexible
demand; transmission losses; and shadow-price output. The PCM stage enables
nodal angle-based DCOPF, binary unit commitment, REG-UP, REG-DOWN, SPIN, and
NSPIN reserves, RPS, flexible demand, storage chronology, transmission losses,
and shadow-price output.

The stress data are designed to make all four transferred decisions visible:

- 20 MW of existing generation retirement;
- 160 MW of new generation capacity;
- 30 MW / 120 MWh of new storage;
- 30 MW of new corridor capacity.

The PCM stage must then consume the transferred resources: new generation must
dispatch, new storage must discharge, and corridor flow must exceed the original
line rating. Both source case directories are hashed before and after the run to
verify that the workflow does not mutate source inputs.

Carbon-policy alternatives, resource aggregation, endogenous representative-day
selection, and interregional net interchange are intentionally outside this
pair. Carbon and RPS are alternative policy stressors here, while aggregation,
representative-day selection, and interchange are better isolated in dedicated
tests. The GTEP case does use an externally supplied representative-period
weight so its 24-hour operations are annualized.

## Run the pair

From the HOPE repository root:

```sh
julia --project=. ModelCases/MD_GTEP_restricted_linkage_case/run_holistic_pair.jl
```

HiGHS is the portable default. A `gurobi_settings.yml` file is included for
users who switch `solver` to `gurobi` in both case settings files.

## Machine-readable acceptance contract

The required settings and numerical thresholds live in
`MD_PCM_restricted_linkage_case/Settings/HOPE_holistic_acceptance.yml`.
Successful runs write the following files under the PCM case's
`output_holistic/` directory:

- `holistic_coverage.csv`: configured, populated, exercised, restrictive,
  transferred, and consumed status by feature;
- `holistic_coverage.yml`: the same evidence in structured form;
- `holistic_acceptance_checks.csv`: every setting and numerical threshold with
  its pass/fail result.

The runner fails if any required acceptance check fails. This makes the pair
suitable for regression testing and, later, agent-controlled workflow validation.

## Rebuild deterministically

```sh
julia --project=. tools/repo_utils/build_md_restricted_linkage_pair.jl
```

The builder regenerates both source cases and their manifests from versioned
logic, so manual edits to generated case files should be folded back into the
builder.
