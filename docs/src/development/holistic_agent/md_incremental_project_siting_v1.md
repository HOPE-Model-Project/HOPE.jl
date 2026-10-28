# [Maryland Incremental Project-Siting Benchmark v1](@id md-incremental-project-siting-v1)

!!! warning "Geographically grounded synthetic benchmark"
    Maryland network buses and planning zones are real model identities. The
    project, permit, environmental, community, queue, land, cost, and firm-PJM
    assumptions are synthetic workflow test data, not claims about actual
    projects, permits, or interconnection positions.

## Purpose

The original Maryland GTEP-to-PCM validation case is intentionally a deterministic
linkage benchmark. Its declared candidates map directly to PCM buses, so it
does not test the scientific siting question. This benchmark isolates that
question without requiring another full annual GTEP and PCM solve:

> Where could a modest set of discrete new projects be permitted,
> interconnected, environmentally acceptable, and economically developed?

It validates the realization layer that sits between a zonal GTEP plan and a
nodal PCM system. It is not a new expansion-planning formulation and does not
claim that one weighted ranking is the physically true future.

## Capacity basis and project blocks

The benchmark assumes firm external PJM contribution so that Maryland is not
treated as an electrically isolated greenfield system. Starting from an
18,344.81 MW coincident peak and a 15% planning reserve margin, it declares:

| Capacity element | Accredited MW |
| --- | ---: |
| Requirement | 21,096.53 |
| Existing modeled Maryland resources | 6,765.71 |
| Assumed firm PJM contribution | 13,525.82 |
| **Residual need** | **805.00** |

The compact `CapacityPlan` contains nine blocks totaling 1,500 MW of generation
and 200 MW / 800 MWh of four-hour storage. With the declared capacity credits,
they contribute exactly 805 MW.

Project size is an upstream planning assumption in this benchmark. In
`discrete_project` mode, the realization engine requires a candidate's MW—and
storage MWh—to match its plan item exactly, selects one whole candidate, and
prevents reuse. It does not split a project among buses or treat a fractional
candidate decision as a physical generating unit. Operational unitization is a
separate, capacity-conserving PCM-template step.

## Hard screens, soft preferences, and human review

The catalog contains 27 candidates—three alternatives for every project block.
Hard screens remove candidates with any of the following evidence:

- denied, prohibited, rejected, or withdrawn permit status;
- failed environmental eligibility;
- withdrawn, rejected, or suspended queue status;
- interconnection headroom below project MW;
- available land below required land; or
- commercial-operation date after the required in-service year.

These restrictions are not objective penalties. No cost or resource-quality
advantage can compensate for them.

Eligible candidates are compared using normalized, policy-weighted site cost,
network stress, resource quality, brownfield status, evidence confidence,
environmental sensitivity, permitting complexity, community impact, and
interconnection cost. Conditional permitting and community-review flags remain
eligible but create an explicit `ReviewRequired` record. An agent may explain
or escalate that record; it may not represent it as an approval.

## Alternative realizations

The benchmark evaluates the same capacity plan under four declared policies:

1. `balanced_permitting` balances all evidence;
2. `least_cost` emphasizes site and interconnection cost;
3. `environmental_caution` emphasizes environmental and community effects;
4. `grid_ready` emphasizes network stress and interconnection readiness.

All variants must select nine distinct projects, conserve 1,700 MW and 800 MWh,
and avoid every hard-excluded candidate. Differences among their nodal project
sets are retained as siting uncertainty for later PCM assessment.

The validated synthetic inputs produce three distinct project portfolios:

| Variant | Lower-cost/grid-ready A projects | Lower-impact B projects | Human-review projects |
| --- | ---: | ---: | ---: |
| `balanced_permitting` | 3 | 6 | 6 |
| `least_cost` | 9 | 0 | 0 |
| `environmental_caution` | 0 | 9 | 9 |
| `grid_ready` | 3 | 6 | 6 |

`balanced_permitting` and `grid_ready` reach the same discrete portfolio for
this candidate set even though their objective values differ. That agreement
is retained rather than forcing artificial diversity. The least-cost and
environmental variants demonstrate the intended tradeoff, and every
human-review flag remains visible in the output.

## Reproduce

```powershell
julia --project=. tools/repo_utils/run_md_incremental_project_siting.jl `
  artifacts/computed_realization_runs/md_incremental_project_siting_v1
```

Inputs are under
`tools/repo_utils/examples/maryland_incremental_project_siting_v1/`. The output
is an immutable realization-set package with allocations, screening evidence,
a summary, and a hash manifest.

## What this benchmark establishes

This case establishes a useful version-1 downscaling boundary:

- GTEP or an approved scenario contract owns how much and what size to build;
- the realization engine owns defensible project-to-bus selection;
- hard evidence is distinct from policy preferences;
- unresolved approval evidence is routed to humans;
- alternative siting assumptions remain explicit; and
- PCM remains responsible for operational feasibility after a realization is
  converted into a model case.

It does not yet establish real Maryland project viability, endogenous project
sizing, AC interconnection feasibility, production-cost acceptance, or the
adaptive GTEP-realization-PCM revision loop.

## First PCM ensemble assessment

The next layer converts every variant through the existing deterministic
GTEP-to-PCM data contract, verifies identity and capacity reconciliation, and
solves each distinct physical portfolio using the same 168-hour Maryland PCM
settings. An explicit, reviewed operational-template registry accompanies the
benchmark so the test does not depend on silent legacy defaults.

All four variants passed the structural fast screen and transfer reconciliation.
The balanced and grid-ready variants are the same physical portfolio, so the
assessment solves that portfolio once and records reuse. The three distinct
portfolios all reached an optimal feasible PCM solution with zero load
shedding. They nevertheless produced about 222,580 MWh of Maryland RPS slack,
so all four policy variants were classified `ACCEPTANCE_FAILED` under the
declared zero-slack threshold.

This is a useful feedback result, not a failed downscaling algorithm and not a
PCM infeasibility. It says the realized plan is operable, but its technology
mix does not satisfy the operational RPS criterion in this PCM horizon. The
appropriate next agent action is therefore upstream review of the GTEP
technology mix, RPS assumptions, renewable availability, or firm clean-energy
contribution. Moving the same MW among buses cannot by itself cure that policy
shortfall. The assessment also reports `HUMAN_REVIEW` separately when model
thresholds pass but selected projects still lack required approval.

Reproduce the assessment with:

```powershell
julia --project=. tools/repo_utils/run_md_incremental_pcm_ensemble.jl `
  artifacts/computed_realization_runs/md_incremental_pcm_ensemble_v1 highs
```

## Bounded feedback package

The checked-in observed assessment can be routed through the first adaptive
feedback boundary without rerunning PCM:

```powershell
julia --project=. tools/repo_utils/generate_holistic_feedback.jl `
  tools/repo_utils/examples/maryland_incremental_project_siting_v1/ensemble_assessment_observed.yml `
  tools/repo_utils/examples/maryland_incremental_project_siting_v1/feedback_policy.yml `
  artifacts/computed_realization_runs/md_incremental_feedback_v1 `
  md-incremental-feedback-v1 1
```

The result contains two findings. The RPS shortfall appears in all four policy
variants and three distinct physical portfolios, so it is routed to the GTEP
owner as a planning-structural hypothesis. Its request permits a bounded search
over qualifying clean-energy candidates, but explicitly forbids lowering the
RPS target, changing the PCM threshold, or editing the parent plan. Because
three policy variants also select projects with conditional evidence, a second
request is routed to a human approver. Approval is recorded as a new artifact;
it is never inferred from silence.

This layer proposes no numerical capacity adjustment. The GTEP model must
produce the child `CapacityPlan` because it alone can reconcile the RPS finding
with reserve margin, candidate limits, costs, and the rest of the planning
formulation.

## Approved child-case boundary

HOPE can now materialize an approved child GTEP case with
`tools/repo_utils/materialize_gtep_child_scenario.jl`. The command requires five
explicit inputs: the parent case, revision request, approval decision, concrete
child specification, and a new destination. It never edits the parent.

The Maryland public GTEP case already contains large solar and wind candidate
limits. Therefore this benchmark does **not** check in or automatically approve
an arbitrary capacity increase: additional candidate headroom may not be the
binding cause of the operational RPS shortfall. A domain reviewer should first
decide whether the child experiment should change candidate availability,
renewable chronology or accreditation, clean imports, or another planning
assumption. Only the first option is currently allowlisted by the materializer.
Supporting another option requires its own typed operation, bounds, protected
fields, and tests.
