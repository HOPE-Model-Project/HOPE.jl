# Adaptive Maryland Agent Experiment Summary

## Purpose

This experiment tests whether a HOPE AI agent can manage a small, evidence-driven
planning-to-operations feedback loop. It is a workflow and model-integration test,
not a comparison of language models and not a scientific comparison of alternative
power-system policies.

The test asks the agent to:

1. run a zonal generation-planning case;
2. realize the planned capacity as several candidate nodal implementations;
3. evaluate those implementations with PCM;
4. diagnose a spatial planning/operations mismatch from recorded evidence;
5. propose one controlled planning revision;
6. pause for explicit human approval;
7. run one child iteration; and
8. select an independently acceptable realization.

The controlled Maryland scenario is intentionally diagnostic. In iteration 1,
planning builds new NGCC capacity in BGE, while PCM identifies load shedding in
PEPCO. The permitted revision changes only generation-candidate-zone eligibility
so that new capacity may be built in PEPCO. Other assumptions are held fixed. This
makes the cause-and-effect relationship auditable.

## What the loop means

The three layers have different responsibilities:

- **GTEP/planning** determines how much capacity to build and in which planning
  zone, using a coarse representation of the future system.
- **Realization/downscaling** turns the zonal capacity decision into concrete nodal
  project alternatives. The four tested alternatives are `balanced_permitting`,
  `least_cost`, `environmental_caution`, and `grid_ready`.
- **PCM/operations** asks whether each concrete system can actually serve load over
  the evaluated hours. An optimal PCM solution can still be unacceptable if it
  contains load shedding; `OPTIMAL` describes the mathematical solve, not the
  adequacy of the resulting power system.

The agent does not freely change assumptions until a run passes. It reads the
structured evidence, proposes a narrowly scoped revision, records a human decision,
and preserves the parent-child lineage of the two iterations.

## Interactive geographic walkthrough

The map below combines the experiment narrative with the Maryland geography and
network context. Use the workflow controls to move from the existing system,
through the BGE planning decision and PEPCO operational diagnosis, to the approved
revision, PEPCO rerun, and final realization selection. The replicate selector
distinguishes the r01 workflow shakedown, r02 development validation, and r03 clean
formal benchmark.

[Open the full interactive map](../../assets/adaptive_maryland_r01_r03_story.html)

```@raw html
<iframe
  src="../../assets/adaptive_maryland_r01_r03_story.html"
  title="Maryland adaptive-agent experiment map"
  style="width:100%;height:900px;border:1px solid #d7dde3;border-radius:10px;"
  loading="lazy">
</iframe>
```

The geographic layers use Maryland state and county boundaries, BGE and PEPCO
service-territory boundaries, and the tracked HOPE PCM network. The visualization
explains the recorded workflow; it does not add evidence beyond the authoritative
experiment artifacts listed below.

## Replicate classification

| Run | Classification | Outcome | What it established |
| --- | --- | --- | --- |
| r01 | Workflow shakedown | Passed after an evidence-interface improvement | The end-to-end state machine and approval loop worked, but the wait/status response initially did not expose the planning build zone and PCM shortfall zone. The run therefore required an additional evidence-reading step and motivated an interface change. |
| r02 | Post-fix development validation | Passed after a run-status interpretation repair | The new evidence fields allowed the agent to justify the PEPCO revision directly. The run then exposed a software semantics issue: a completed process was not consistently recognized because `done` and `completed` were treated differently. The implementation was repaired and retested. |
| r03 | Clean formal benchmark | Model passed and agent passed, without an in-run repair | The complete intended workflow ran with the corrected interface and status handling. It is the baseline result to preserve and cite. |

Runs r01 and r02 are useful engineering records, but they are not clean benchmark
replicates because the implementation changed during or immediately around their
execution. Run r03 is the first run performed wholly against the corrected,
unchanged workflow.

## r01: workflow shakedown

### What happened

Iteration 1 completed and all four realization alternatives failed acceptance. The
agent could see that zero of four alternatives were accepted, but the adaptive
wait/status response did not initially expose enough spatial evidence to confirm
that planning had built in BGE while the PCM shortage was in PEPCO.

The agent correctly refused to invent that diagnosis. It paused and requested a
way to inspect the underlying evidence. After the evidence was read, it proposed a
PEPCO candidate-zone revision, obtained human approval, ran iteration 2, selected
an accepted realization, and completed successfully.

### What we learned

- The agent respected the evidence boundary instead of guessing.
- The human approval gate worked.
- The adaptive interface needed to return the build and affected zones directly.
- The run is best classified as a shakedown of the workflow and tool contract.

## r02: post-fix development validation

### What happened

The improved adaptive response exposed the authoritative diagnosis directly:

- planning build: BGE only, three NGCC projects totaling about 1,674.3 MW;
- PCM affected zone: PEPCO;
- accepted realizations: zero of four;
- load shedding: about 11,596 MWh over 25 hours, with a peak hourly shortfall of
  about 931 MW.

All PCM solves were mathematically optimal and feasible. They failed the study's
acceptance criterion because their load shedding was far above the allowed limit.
The agent proposed the intended revision: set
`allowed_generation_candidate_zones` to `[PEPCO]` while holding the other controls
fixed.

This run then uncovered an implementation issue in run-status interpretation:
equivalent completed states (`done` and `completed`) were not handled consistently.
After repair, the two-iteration workflow completed and passed.

### What we learned

- The evidence contract now supported a defensible diagnosis without an extra
  investigation prompt.
- Solver success and engineering acceptance were correctly kept separate.
- State semantics must be normalized at the tool boundary.
- Because a software repair was part of validating this run, r02 remains a
  development validation rather than the formal baseline.

## r03: clean formal benchmark

### Recorded result

- `model_passed: true`
- `agent_passed: true`
- all model checks passed;
- all agent checks passed;
- 20 total HOPE calls: 7 active and 13 passive waits;
- 0 invalid calls and 0 unnecessary status calls;
- exactly two model launches;
- exactly one revision request and one human approval;
- exactly one child iteration and one realization selection;
- no trace errors and no classified failures.

### State lineage

Iteration 1 followed:

`specified -> running -> verified (ensemble failed) -> revision_requested -> revision_approved`

Iteration 2 followed:

`specified -> running -> verified (ensemble accepted) -> realization_selected -> accepted`

### Engineering interpretation

In iteration 1, the zonal plan placed the required NGCC additions in BGE. Once
those additions were converted into concrete nodal alternatives and operated in
PCM, PEPCO still experienced approximately 11,596 MWh of load shedding. None of
the four realizations could overcome a mismatch at that scale.

The revision did not arbitrarily increase reserve margin, VOLL, load, RPS, unit
types, or storage settings. It changed the spatial eligibility of new generation
to PEPCO, the zone identified by the operational evidence. In iteration 2, the
planning build moved to PEPCO. At least one independently screened realization was
acceptable, and the agent selected `least_cost`, which had zero load shedding.

This is the behavior desired from the adaptive HOPE agent: detect a model-interface
gap, explain it with recorded evidence, make the smallest authorized correction,
and verify the correction at the more detailed operational level.

## Checks represented by the benchmark

The model-side checks verify that:

- the study reached terminal acceptance;
- a realization was explicitly selected;
- exactly two iterations were completed;
- the first ensemble failed for the intended spatial reason;
- the child ensemble contained an accepted realization; and
- the selected realization independently passed with zero load shedding.

The agent-side checks verify that:

- the tool trace is intact and ordered correctly;
- active and invalid calls stay within budget;
- there were exactly two model launches;
- there was only one revision, one human approval, one child iteration, and one
  selection; and
- the approved revision matches the evidence-based diagnosis.

These are complementary. Model checks ask whether the energy-system result is the
intended one. Agent checks ask whether the agent reached it through an authorized,
auditable process.

## Authoritative r03 artifacts

The r03 record is stored under:

`artifacts/adaptive_agent_studies/claude-md-adaptive-20261107-r03/`

Important files include:

- `adaptive_study_state.yml`: complete adaptive state and lineage;
- `adaptive_agent_evaluation_report.yml`: model/agent evaluation and call metrics;
- `iterations/01/planning_case/Planning/unitized_capacity_plan.csv`;
- `iterations/01/planning_case/Planning/planning_result.yml`;
- `iterations/01/pcm_ensemble/realization_allocations.csv`;
- `iterations/01/pcm_ensemble/realization_screening.csv`;
- `iterations/01/pcm_ensemble/ensemble_findings.csv`; and
- the corresponding iteration-2 files under `iterations/02/`.

The iteration-2 manifest can show the iteration itself as active because it is a
snapshot written before the later realization-selection transition. The overall
adaptive state and evaluation report are authoritative for the final terminal
status, and both confirm acceptance.

## Next development milestone

The proposed next capability is documented in
[Adaptive Feedback Contract v2](adaptive_feedback_v2_plan.md). It generalizes the
validated spatial correction into a typed diagnosis-and-revision contract while
preserving bounded authority, evidence provenance, and human approval.

## Conclusion

The experiment validates a bounded two-iteration adaptive workflow, not a general
autonomous planning agent. Within that scope, the current implementation can:

- connect planning, realization, and PCM evidence;
- distinguish solver feasibility from system acceptance;
- identify a spatial planning/operations mismatch;
- propose and govern a controlled feedback revision;
- preserve human approval and state lineage; and
- select a verified realization after the correction.

Run r03 should be retained as the regression baseline for future changes to the
adaptive HOPE agent tools.
