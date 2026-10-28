# [Maryland Compact RPS Planning and Realization Experiment v1](@id md-compact-rps-planning-v1)

!!! warning "Workflow experiment, not a Maryland project forecast"
    The network identities and HOPE model inputs are real case data. Firm
    external supply, project development evidence, permitting, environmental,
    queue, land, and community-review attributes are synthetic experiment
    assumptions. They do not describe actual projects or approvals.

## Question

This experiment closes the gap left by the incremental project-siting
benchmark. Instead of giving the realization agent a hand-written capacity
plan, it asks GTEP to determine the technology, zone, and MW needed to satisfy
both planning reserve and the 20% local Maryland RPS. The resulting plan is
unitized, allocated among restricted PCM buses, and assessed in the nodal
168-hour July PCM.

The experiment tests a complete deterministic scientific boundary:

```text
RPS-constrained GTEP
  -> continuous CapacityPlan
  -> discrete project unitization
  -> restricted alternative nodal realizations
  -> PCM unit commitment and dispatch
  -> acceptance or human review
```

## Declared planning contract

The child GTEP case is copied immutably from
`MD_GTEP_RPS20_4zone_public_case`. It retains the 15% system planning reserve
margin and 20% local Maryland annual RPS. Four declared firm external-supply
proxies total 13,525.82 MW and are split among physical PCM boundary buses.
They are non-RPS resources. Their zero marginal decision cost represents a
sunk baseline-supply assumption, not a price forecast, physical PJM contract,
or contingency-deliverability claim.

Adding proxy generators changes positional `G<n>` generator indices. The
materializer therefore rebuilds the generator-availability table explicitly:

1. original existing-generator columns retain their original indices;
2. proxy columns receive declared static availability;
3. every candidate is reindexed after the proxies; and
4. solar and wind candidates receive their zonal hourly regional profiles.

Static availability fallback is forbidden for candidate VRE in this contract.
This detail is scientifically material. An earlier trial left candidate
profiles at their pre-proxy indices, causing candidate solar to use static
availability of 1.0. That trial selected only 3.22 GW and failed PCM RPS. The
corrected profile contract changed the optimal plan, so the failed trial is
retained as diagnostic evidence and is not treated as a valid comparison run.

## Corrected GTEP result and project units

The corrected HiGHS solve is optimal with zero load shedding and zero RPS
slack. It selects one continuous planning decision:

| Zone | Technology | Continuous build |
| --- | --- | ---: |
| DPL_MD | SolarPV | 4,807.474 MW |

GTEP owns that quantity, technology, and planning zone. A declared
capacity-conserving unitization policy converts it into nine equal projects of
534.164 MW. Unitization changes no total MW and makes project size auditable;
it is not an endogenous siting decision.

## Restricted nodal realization

The realization layer starts from actual DPL Maryland PCM bus and branch
identities. It considers 18 project candidates for the nine projects. The
validated hard screen leaves 11 eligible candidates:

| Hard-screen result | Candidate count |
| --- | ---: |
| Eligible | 11 |
| Insufficient incident-rating headroom for 534.164 MW | 4 |
| Permit denied | 1 |
| Environmental screen failed | 1 |
| Queue suspended | 1 |

The last three restrictions and all soft preference scores are synthetic. The
incident-rating proxy is derived from PCM topology but is not an AC
interconnection study. Each realization must select nine distinct buses,
conserve 4,807.474 MW exactly, and pass transfer reconciliation.

Four policies retain different development priorities: `balanced_permitting`,
`least_cost`, `environmental_caution`, and `grid_ready`. They produce three
distinct physical portfolios. `grid_ready` and `balanced_permitting` select the
same buses, so PCM solves that physical signature once and records reuse rather
than manufacturing artificial diversity.

## PCM assessment

Gurobi solves the three distinct 168-hour nodal unit-commitment models to
optimality. All four policy labels have the same aggregate operational result:

| Metric | Result |
| --- | ---: |
| New solar dispatch | 287,539.832 MWh |
| Load shedding | 0 MWh |
| RPS slack | 0 MWh |
| Termination / primal status | `OPTIMAL` / `FEASIBLE_POINT` |
| PCM objective | about USD 1.330 million |

`least_cost` selects nine fully approved synthetic candidates and is
`ACCEPTED`. The other three policies each select one conditional-permit or
community-review candidate. Their operational gates pass, but their terminal
classification is `HUMAN_REVIEW`. This distinction is intentional: solver
feasibility cannot grant a project approval.

## What this establishes

The experiment demonstrates the intended division of responsibility:

- GTEP determines the planning need and resource mix under declared policy and
  reserve constraints;
- unitization turns a continuous decision into reviewable project blocks;
- the realization engine selects defensible buses without changing zonal MW;
- PCM tests chronological nodal operation; and
- the verifier distinguishes operational acceptance from unresolved human
  approvals.

The result also demonstrates why workflow and data contracts matter. The most
important feedback was detection of a generator-index/profile mismatch that
materially changed the planning answer.

## Reproduce

Use new output directories; neither command overwrites an existing artifact.

```powershell
julia --project=. tools/repo_utils/run_md_compact_rps_planning.jl `
  artifacts/computed_realization_runs/md_compact_rps_planning_trial highs

julia --project=. tools/repo_utils/run_md_compact_rps_pcm_ensemble.jl `
  artifacts/computed_realization_runs/md_compact_rps_planning_trial `
  artifacts/computed_realization_runs/md_compact_rps_pcm_trial gurobi
```

The planning and realization policies are under
`tools/repo_utils/examples/md_compact_rps_planning_v1/`. Gurobi is recommended
for this large unit-commitment experiment; HiGHS found a feasible incumbent
but made poor progress closing the root gap.

## Limitations and next boundary

This is a useful vertical slice, not a siting forecast or complete reliability
study. It uses one July week, synthetic development evidence, a topology
headroom proxy, and declared external supply. It does not include AC power
flow, contingency deliverability, real permit or queue data, endogenous
project size, annual PCM operation, or probabilistic reliability.

The next scientific layer should replace one synthetic evidence family at a
time with reviewed data, while preserving this experiment as a deterministic
regression and retaining human approval for material assumptions.
