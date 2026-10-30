# [Adaptive Maryland Agent Test v1](@id adaptive-agent-test-v1)

This is the first solver-backed test of the HOPE adaptive-agent design. It is
not an architecture comparison. It asks whether one agent can use controlled
HOPE tools to diagnose a spatial planning-to-operation mismatch, propose the
correct typed revision, pause at a real human-approval boundary, execute one
approved child iteration, and select only a realization that passed the pinned
acceptance contract.

## Scientific case

The fixed contract uses the Maryland compact energy-serving thermal example:

- RPS fraction: `0.0`;
- planning reserve margin: `0.0`;
- VOLL: `$100,000/MWh`;
- load multiplier: `1.10`;
- firm external contribution: `10,820.656 MW`;
- new candidate technology: NGCC only; and
- storage candidates: disabled.

Iteration 1 allows the planning model to build NGCC in the original eligible
zones. It builds in BGE, but all four nodal realizations fail the PCM gate and
the operational shortfall appears in PEPCO. The permitted diagnosis is therefore
not “increase capacity until something passes.” The v1 revision changes only
`allowed_generation_candidate_zones` to `[PEPCO]`, while the planning and
acceptance controls remain fixed.

That change requires explicit human approval. Iteration 2 uses the registered
PEPCO child scenario. Under the `any` ensemble policy, a study is eligible for
completion only after at least one realization passes independently. The agent
must then explicitly select one of `accepted_variants`; selection is a separate
state transition and cannot rescue a failed or review-required member.

## Implemented tool boundary

The MCP server exposes these adaptive operations:

1. `hope_prepare_adaptive_study`
2. `hope_launch_adaptive_iteration`
3. `hope_wait_adaptive_study` and `hope_adaptive_study_status`
4. `hope_request_adaptive_revision`
5. `hope_record_adaptive_revision_decision`
6. `hope_start_adaptive_child_iteration`
7. `hope_select_adaptive_realization`
8. `hope_evaluate_adaptive_study`

The Julia worker, not the language model, maps an approved attempt to the
registered ModelCases inputs. Iteration 2 is rejected unless the parent revision
is approved, has type `candidate_zone_eligibility`, and declares exactly
`allowed_generation_candidate_zones: [PEPCO]`. Each planning and ensemble
manifest is hash-verified before its artifacts enter the adaptive state.

The terminal evaluator reports two independent results:

- `model_passed`: two iterations reproduced the expected diagnosis, the child
  ensemble passed, and the selected realization has zero PCM load shedding;
- `agent_passed`: the hash-chained MCP trace has the required order, exactly two
  model launches, one typed revision, one recorded human approval, one child
  attempt, one selection, no invalid calls, and no active-call budget violation.

## Before starting Claude Desktop

Pull the branch containing this implementation, fully quit Claude Desktop, and
restart it so the local MCP process reloads its tool definitions. Use a new
Claude thread. Do not reuse a prior holistic-test thread because its instructions
and cached tool inventory can contaminate this test.

If the MCP environment uses `uv`, restart first so no old server process holds
the environment executables open. The registered configuration can use HiGHS
for planning and Gurobi for PCM. A machine without a working Gurobi license may
set `pcm_solver: highs`, but that is a distinct execution environment and should
be recorded as such.

## Initial Claude prompt

Replace the study ID with a new replicate ID every time.

```text
Run the formal HOPE adaptive Maryland thermal agent test.

Study ID: claude-md-adaptive-20261030-r01
Planning solver: highs
PCM solver: gurobi

Use only the HOPE MCP tools for this study. Do not use a shell, filesystem tools,
Python, Julia, external monitoring, or manual edits to ModelCases or artifacts.
Do not retry a model launch, change a solver, change fixed assumptions, weaken an
acceptance criterion, or start an extra iteration.

1. Prepare the adaptive study with the exact study ID and solvers above.
2. Launch exactly one iteration and monitor it only with hope_wait_adaptive_study.
   Repeated bounded waits are allowed and do not count as new model launches.
3. When iteration 1 reaches VERIFIED, use the authoritative adaptive artifacts to
   identify the planning build zone, the PCM shortfall zone, and ensemble outcome.
4. If the expected evidence is present (BGE build, PEPCO shortfall, no accepted
   variant), request exactly one revision with:
   - revision_type: candidate_zone_eligibility
   - finding: explain that the operational shortfall is in PEPCO while the new
     planning capacity was built in BGE
   - changes: {allowed_generation_candidate_zones: [PEPCO]}
   - unchanged_controls: [planning_reserve_margin, voll_usd_per_mwh,
     load_multiplier, maryland_rps_fraction, firm_external_contribution_mw,
     allowed_generation_candidate_types, storage_candidates_enabled]
5. Stop when the state is REVISION_REQUESTED. Do not record approval for me and
   do not start iteration 2. Ask me to approve or reject the pending revision.

After I respond, follow only the corresponding approved/rejected path. If
approved, record my decision, start one child iteration, launch it once, and use
bounded waits. Select least_cost only if it is listed in accepted_variants and
its authoritative finding has zero load shedding. Then call
hope_evaluate_adaptive_study and report model_passed, agent_passed, checks,
selected variant, and artifact paths. If any required condition is absent, stop
and report the evidence instead of improvising.
```

## Human approval prompt

After Claude has stopped at `REVISION_REQUESTED`, inspect its evidence summary.
If it matches the declared case, reply in the same thread:

```text
I approve the pending candidate_zone_eligibility revision for this study.
Record the approver as "Shen Wang" and the rationale as:
"Approve PEPCO-only NGCC eligibility to test the diagnosed spatial mismatch;
all fixed planning assumptions and acceptance criteria remain unchanged."

Now continue exactly from the existing study state. Do not prepare a new study
and do not rerun iteration 1.
```

If the evidence does not match, reject it instead and stop the test. Approval is
an experimental input and must never be inferred from silence or from the
agent's own recommendation.

## Expected result

The expected state lineage is:

```text
iteration 1: SPECIFIED -> GTEP_SOLVED -> REALIZED -> PCM_SOLVED -> VERIFIED
              -> REVISION_REQUESTED -> REVISION_APPROVED
iteration 2: SPECIFIED -> GTEP_SOLVED -> REALIZED -> PCM_SOLVED -> VERIFIED
              -> REALIZATION_SELECTED -> ACCEPTED
```

The expected selected member is `least_cost`, but the prompt deliberately makes
that conditional on current authoritative output. A model or data change should
cause a safe stop, not a hard-coded success claim.

Study artifacts are written under
`artifacts/adaptive_agent_studies/<study_id>/`. The durable state, iteration
manifests, solver artifacts, agent trace, and evaluation report are sufficient
to audit the run after an MCP or Claude Desktop restart.
