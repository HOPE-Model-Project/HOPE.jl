# Maryland incremental project-siting benchmark v1

This is a geographically grounded, synthetic benchmark for the HOPE computed
realization tool. It asks a deliberately narrower and more realistic question
than the original Maryland workflow smoke test:

> Given a small zonal capacity plan, which discrete projects could plausibly
> host it after permit, environmental, interconnection, land, schedule, and
> community-review evidence is considered?

The transmission bus identities and zone structure come from the public HOPE
Maryland topology. All project, permit, environmental, community, queue, land,
cost, and firm-capacity values are synthetic. They exercise the decision
contracts and must not be interpreted as claims about real Maryland projects.

## Why the plan is incremental

The Maryland benchmark has a coincident peak of 18,344.81 MW. With a 15%
planning reserve margin, the capacity requirement is 21,096.53 MW. Existing
modeled Maryland resources contribute 6,765.71 MW of accredited capacity. This
benchmark assumes 13,525.82 MW of firm PJM contribution outside the modeled
Maryland fleet, leaving an 805 MW incremental accredited requirement.

The synthetic plan meets that residual exactly under its declared capacity
credits:

| Technology | Nameplate plan | Capacity credit | Accredited contribution |
| --- | ---: | ---: | ---: |
| Solar PV | 800 MW | 25% | 200 MW |
| Onshore wind | 300 MW | 15% | 45 MW |
| NGCC repower | 400 MW | 90% | 360 MW |
| Four-hour battery | 200 MW / 800 MWh | 100% | 200 MW |
| **Total** | **1,700 MW + 800 MWh** | | **805 MW** |

The plan contains nine project blocks. The upstream planning study determines
their sizes. The realization optimizer does not invent unit sizes; it selects
one whole matching candidate for each block. A later PCM adapter may unitize a
selected block into reviewed operational templates without changing its total
MW or MWh.

## Candidate and decision design

`candidate_project_catalog.csv` contains 27 alternatives: three candidates for
each of the nine plan items. For every item, two alternatives survive screening
and express a real tradeoff, while one fails a hard screen such as a denied
permit, environmental exclusion, insufficient interconnection headroom,
insufficient land, late commercial-operation date, or inactive queue status.

Hard screens are applied before optimization and cannot be offset by a low
cost. Surviving projects are ranked by a versioned weighted objective covering
site cost, network stress, resource quality, brownfield use, evidence quality,
environmental sensitivity, permitting complexity, community impact, and
interconnection cost. Conditional or under-review evidence does not silently
become approval: it is carried to the output as `ReviewRequired`.

Four policy variants expose siting uncertainty:

- `balanced_permitting`
- `least_cost`
- `environmental_caution`
- `grid_ready`

Every variant conserves the same nine project blocks. Differences are alternative
realizations of one plan, not different GTEP solutions.

For the checked-in synthetic data, least-cost selects nine A alternatives with
no review flags, environmental-caution selects nine B alternatives with nine
review flags, and balanced/grid-ready select a three-A/six-B mix. The latter two
policies happen to agree on the discrete portfolio; the tool reports that
agreement instead of forcing artificial diversity.

## Run

From the repository root:

```powershell
julia --project=. tools/repo_utils/run_md_incremental_project_siting.jl `
  artifacts/computed_realization_runs/md_incremental_project_siting_v1
```

The destination is immutable by default. Use a new destination for another run.
The package contains the selected nodal projects, screening evidence, variant
summary, and a manifest with SHA-256 hashes of every source and output.

## Assess the alternatives in PCM

After reviewing the siting inputs, run every distinct physical portfolio under
identical PCM settings:

```powershell
julia --project=. tools/repo_utils/run_md_incremental_pcm_ensemble.jl `
  artifacts/computed_realization_runs/md_incremental_pcm_ensemble_v1 highs
```

The runner performs fast screens and transfer reconciliation before solving.
It reports model infeasibility, operational acceptance failure, unresolved
human approval, and acceptance as separate outcomes. Identical physical
portfolios reuse one solve and record the source variant explicitly.

## Generate bounded feedback

`ensemble_assessment_observed.yml` records the verified first ensemble result.
Create typed findings and approval-gated revision requests with:

```powershell
julia --project=. tools/repo_utils/generate_holistic_feedback.jl `
  tools/repo_utils/examples/maryland_incremental_project_siting_v1/ensemble_assessment_observed.yml `
  tools/repo_utils/examples/maryland_incremental_project_siting_v1/feedback_policy.yml `
  artifacts/computed_realization_runs/md_incremental_feedback_v1 `
  md-incremental-feedback-v1 1
```

The policy authorizes only a bounded child-scenario search. It does not lower
assessment thresholds, edit the accepted capacity plan, or allow a PCM agent
to dictate a planning decision.

An approved request can be materialized with
`tools/repo_utils/materialize_gtep_child_scenario.jl` after a reviewer supplies
a matching `HOPE.revision_decision` and concrete
`HOPE.gtep_child_scenario_spec`. No Maryland approval or numerical revision is
checked in here. The public parent already has large renewable candidate upper
bounds, so increasing them without first identifying a binding planning
constraint would not be a defensible experiment.

## Diagnose the planning feedback

Run the read-only evidence check before authoring any concrete child-case
specification:

```powershell
julia --project=. tools/repo_utils/diagnose_md_incremental_planning_feedback.jl `
  artifacts/computed_realization_runs/md_incremental_planning_diagnostic_v1
```

For the checked-in evidence, the result is
`capacity_plan_policy_contract_gap`. The validated parent GTEP passes RPS and
retains about 9.76 GW of qualifying candidate headroom, while this benchmark's
compact `CapacityPlan` enforced reserve adequacy but not annual RPS. The tool
therefore refuses to support a candidate-headroom revision and recommends
deriving the next `CapacityPlan` from an RPS-constrained GTEP solve.
