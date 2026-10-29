# Maryland Energy-Serving Thermal Feedback Loop

!!! warning "Workflow benchmark, not a Maryland project recommendation"
    The existing network and fleet identities come from the public HOPE
    Maryland cases. Firm imports and candidate-development evidence are
    declared workflow assumptions. The selected buses demonstrate agent
    decision logic; they are not recommended sites or interconnection results.

## Outcome

The loop converges after one planning correction and one realization
selection. The final portfolio contains three 558.096 MW NGCC projects in
`PEPCO`, totaling 1,674.287 MW. In the 168-hour PCM assessment, these projects
generate 69,238.557 MWh, load shedding is zero, and no human-review flag is
open.

The important result is not simply that a passing case was found. The loop
changed the correct model layer at each step:

1. iteration 0 found a cross-realization PEPCO shortfall, so the planning and
   realization boundary was revised from a statewide candidate choice to a
   PEPCO-local candidate choice;
2. iteration 1 found that one PEPCO nodal portfolio passed while three failed,
   so GTEP capacity was frozen and the accepted physical realization was
   selected; and
3. the loop stopped when the selected realization passed the pinned PCM gate.

## Pinned acceptance contract

The criteria are fixed before interpreting the iterations:

| Gate | Requirement |
| --- | --- |
| GTEP solve | Optimal solution and no planning load shedding |
| Capacity purpose | New generation must dispatch in PCM |
| PCM final realization | Load shedding no greater than `1e-6` MWh |
| Governance | Final realization must be `ACCEPTED`, with no unresolved human review |
| Provenance | Every revision creates immutable child artifacts |
| Assumption control | Load, firm imports, VOLL, RPS, PRM, and technology eligibility stay fixed during feedback |

The ensemble is diagnostic. Rejected alternatives remain visible, but the
final contract is evaluated against the explicitly selected physical
realization. The workflow must not call a failed alternative successful or
silently replace it.

## Fixed experiment assumptions

| Assumption | Value | Reason |
| --- | ---: | --- |
| PCM load | Original Maryland chronology multiplied by 1.10 | Creates an energy-serving expansion need |
| Firm external contribution | 10,820.656 MW | Transparent 20% haircut from the 13,525.820 MW baseline proxy |
| VOLL | USD 100,000/MWh | Already high enough to discourage avoidable shedding |
| Maryland RPS | 0%; disabled | Removes policy-driven renewable construction |
| Planning reserve margin | 0%; disabled | Ensures construction is driven by hourly energy balance |
| New generation technology | NGCC | Declared dispatchable-replacement procurement after renewable/storage envelopes are exhausted |
| Storage candidates | Disabled | Keeps the benchmark focused on thermal siting and dispatch |
| PCM acceptance | Zero load shedding within numerical tolerance | Hard operational gate |

The sampled PCM load ranges from 8,897 MW to 18,345 MW and averages 13,377 MW.
The original combination of 9,332 MW of existing Maryland nameplate capacity
and 13,526 MW of firm-import proxies exceeded the sampled peak. Therefore the
earlier thermal example built capacity for PRM accounting but did not dispatch
it. Raising VOLL alone could not change that result because no load was being
shed.

## Loop record

| Step | Controlled change | GTEP decision | PCM evidence | Decision |
| --- | --- | --- | --- | --- |
| 0: energy-driven baseline | +10% load, -20% firm imports, PRM/RPS off | 1,674.287 MW NGCC in `BGE` | All four realizations fail; 11,596.357--11,596.484 MWh shed, entirely in `PEPCO`; new NGCC dispatches about 50 GWh | Spatial deliverability failure; localize the build test to `PEPCO` |
| 1: PEPCO-local planning | Only eligible NGCC zone changes to `PEPCO` | Same 1,674.287 MW and essentially identical objective | One nodal portfolio passes; three shed 10,989.791--11,274.958 MWh | Freeze GTEP totals; ownership moves to realization |
| 2: verified realization | Select the accepted `least_cost` portfolio | No GTEP rerun | Zero shedding; 69,238.557 MWh new-NGCC dispatch; no review flags | Accept and stop |

### Iteration 0: energy need exists, but capacity is in the wrong zone

With statewide NGCC candidates, GTEP chooses one continuous 1,674.287 MW
decision in `BGE`. The deterministic unitizer creates three equal 558.096 MW
projects. GTEP reports zero shedding, and all four PCM portfolios dispatch the
new plants for approximately 50,002--50,028 MWh.

Nevertheless, every PCM portfolio fails:

| Metric | Iteration-0 result |
| --- | ---: |
| Accepted realizations | 0 of 4 |
| PCM load shedding | 11,596.357--11,596.484 MWh |
| Hours with shedding | 25 |
| Maximum hourly shortfall | 930.959 MW |
| Affected zone | `PEPCO` only |

This rules out the hypothesis that the new unit is merely unused reserve. It
is dispatched, but BGE capacity is not deliverable through the detailed PCM
network to the affected PEPCO nodes. Increasing statewide capacity or VOLL
would not be a targeted response.

The approved revision changes one field: eligible NGCC candidate zone becomes
`PEPCO`. Load, imports, costs, technology, RPS, PRM, and VOLL remain unchanged.

### Iteration 1: the zone is correct, but the bus still matters

GTEP again chooses 1,674.287 MW, now in `PEPCO`. The planning objective changes
only at floating-point scale, from USD 853,242,952.7136612 to USD
853,242,952.7136616. This confirms that the iteration is a spatial correction,
not a new capacity or economic assumption.

The nodal ensemble gives four different results:

| Policy | PCM classification | Load shedding (MWh) | New NGCC dispatch (MWh) | Human review |
| --- | --- | ---: | ---: | --- |
| `balanced_permitting` | `ACCEPTANCE_FAILED` | 11,038.024 | 55,320.593 | Yes |
| `least_cost` | `ACCEPTED` | 0 | 69,238.557 | No |
| `environmental_caution` | `ACCEPTANCE_FAILED` | 10,989.791 | 68,599.044 | Yes |
| `grid_ready` | `ACCEPTANCE_FAILED` | 11,274.958 | 50,649.416 | Yes |

All four portfolios pass the preflight connectivity and transfer checks. The
PCM results therefore reveal a limitation of those inexpensive screens: an
incident-rating or connectivity proxy is not a substitute for chronological
nodal dispatch. Internal PEPCO location changes whether the capacity can serve
the stressed load.

### Iteration 2: select and freeze the verified physical realization

Because a passing realization exists with unchanged zonal capacity, another
GTEP revision would be at the wrong layer. The realization agent selects the
verified `least_cost` portfolio:

| Project | PCM bus | Capacity (MW) | Review required |
| --- | --- | ---: | --- |
| `MD_PEPCO_NGCC_001__PROJECT_01` | `OSM_S53333783_230` | 558.096 | No |
| `MD_PEPCO_NGCC_001__PROJECT_02` | `OSM_S1085724426_230` | 558.096 | No |
| `MD_PEPCO_NGCC_001__PROJECT_03` | `OSM_S1485090638_69` | 558.096 | No |

The selected portfolio is `OPTIMAL` / `FEASIBLE_POINT`, sheds zero load, and
dispatches the new NGCC fleet for 69,238.557 MWh. The hard gates pass, so the
loop stops.

## Decision logic for a future agent test

The benchmark tests whether an agent follows this ownership logic:

```text
Run GTEP -> realize several nodal portfolios -> run PCM
    |
    +-- all or several distinct portfolios fail in the same zone
    |      -> diagnose a planning/zone deliverability issue
    |      -> propose one bounded, approved upstream revision
    |
    +-- at least one local portfolio passes and others fail
    |      -> freeze zonal capacity
    |      -> treat the issue as realization-local
    |      -> select a passing, approval-clean physical realization
    |
    +-- selected realization passes every hard gate
           -> record acceptance and stop
```

An agent should fail this benchmark if it:

- raises VOLL even though it is already high and the evidence is spatial;
- restores PRM and mislabels a reserve-driven build as an energy solution;
- adds generic statewide MW after the shortfall is localized to PEPCO;
- hides the three failed PEPCO alternatives;
- changes several assumptions simultaneously, preventing causal attribution;
- treats a cheap preflight screen as proof of nodal deliverability; or
- continues changing GTEP after an accepted physical realization exists.

## Artifacts and reproducibility

Machine-readable loop history:

`ModelCases/MD_COMPACT_ENERGY_THERMAL_REALIZATION_EXAMPLE_V1/feedback_loop_results.yml`

Iteration 0:

- planning: `artifacts/computed_realization_runs/md_compact_energy_thermal_planning_v1_run02`;
- PCM ensemble: `artifacts/computed_realization_runs/md_compact_energy_thermal_pcm_ensemble_v1_run02`.

Iteration 1 and final selection:

- approved child case: `ModelCases/MD_COMPACT_ENERGY_THERMAL_PEPCO_FEEDBACK_V1`;
- planning: `artifacts/computed_realization_runs/md_compact_energy_thermal_pepco_planning_v1_run01`;
- PCM ensemble: `artifacts/computed_realization_runs/md_compact_energy_thermal_pepco_pcm_ensemble_v1_run01`;
- final selected projects: `members/least_cost/selected_projects.csv` under that PCM ensemble.

Reproduce iteration 1 from the HOPE repository root:

```powershell
julia --project=. tools/repo_utils/run_md_compact_energy_thermal_pepco_planning.jl `
  artifacts/computed_realization_runs/md_compact_energy_thermal_pepco_planning_trial highs

julia --project=. tools/repo_utils/run_md_compact_energy_thermal_pepco_pcm_ensemble.jl `
  artifacts/computed_realization_runs/md_compact_energy_thermal_pepco_planning_trial `
  artifacts/computed_realization_runs/md_compact_energy_thermal_pepco_pcm_trial gurobi
```

## Limits of the conclusion

Acceptance is limited to this declared 168-hour PCM chronology and the public
network representation. It does not establish N-1 security, fuel availability,
gas-pipeline adequacy, emissions or air-quality compliance, water availability,
actual queue position, land control, permitting, community acceptance, or
project economics. Those should be separate assessment agents and hard gates
in a research study.
