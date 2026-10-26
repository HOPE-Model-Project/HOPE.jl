# HOPE Multi-Agent Mechanism

## Purpose

HOPE's multi-agent mechanism is the operating layer that lets people and AI
assistants use GTEP, PCM, DART, and supporting calculations as one traceable
analysis system. An LLM application can provide the conversational interface,
but the LLM does not replace the models or decide how their data are joined.
HOPE's deterministic linkage code remains the authority for validation,
translation, execution, and provenance.

This separation is important because agent conversations can be interrupted,
retried, or resumed in a different application. Model-to-model information must
therefore travel through durable, versioned artifacts rather than through an
agent's conversational memory.

## Operating architecture

```text
User / analyst
      |
      v
LLM application (Claude Desktop, ChatGPT, IDE, or another MCP client)
      |
      v
HOPE MCP tools and workflow controller
      |
      +--------------------+--------------------+
      |                    |                    |
      v                    v                    v
    GTEP                  PCM                  DART
      |                    ^                    ^
      +---- validated -----+---- artifacts -----+
            handoff package, manifests, reports
```

The LLM application is the **cockpit**: it interprets the user's study request,
selects the appropriate HOPE workflow, explains progress, and presents results.
The HOPE workflow layer is the **control system**: it enforces schemas,
preconditions, stable identities, unit conventions, case immutability, and
acceptance checks. The optimization models are the **engines**.

## Agent responsibilities

A mature deployment may use several specialized agents, although the same
mechanism also works with one coordinating agent:

- **Study coordinator** translates the research question into model runs,
  scenarios, and acceptance criteria.
- **GTEP agent** prepares and solves capacity-expansion cases and publishes the
  resulting fleet and transmission decisions.
- **Physical-realization agent** maps aggregated planning decisions to valid
  buses, sites, and corridors using declared allocation rules and records every
  assumption.
- **PCM agent** constructs an operational case, runs chronological production
  cost analysis, and diagnoses whether the planned system is operable.
- **DART agent** can later evaluate day-ahead/real-time schedules, uncertainty,
  reserves, and settlement behavior when that linkage is enabled.
- **Validation agent** checks cross-model conservation, coverage, provenance,
  solver status, and source-case immutability before results are accepted.

These are logical roles rather than mandatory processes. A user studying only
one HOPE model should still be able to invoke that model directly without the
multi-model workflow.

## GTEP-to-PCM workflow

The current implemented mechanism follows this sequence:

1. Resolve explicit GTEP and PCM case identifiers from the ModelCases catalog.
2. Validate both source cases and record their fingerprints.
3. Solve GTEP and publish a versioned handoff package containing investment,
   retirement, and transmission decisions plus provenance.
4. Realize planning decisions in the PCM network. Existing assets retain their
   stable identities; new assets receive deterministic identities, locations,
   sizes, and operational templates.
5. Build a derived PCM case in a new run directory. Source cases are never
   modified.
6. Validate data coverage and cross-model consistency before solving PCM.
7. Solve PCM and publish a run manifest, linkage report, acceptance report, and
   model outputs.
8. Return a compact status summary to the LLM client. The same request ID can be
   retried safely, and status can be recovered after a client reconnect.

For the Maryland benchmark, the intended fidelity pattern is an annual GTEP
planning run followed by a chronological July PCM run on the detailed network.
This is a linkage and operability benchmark, not a claim that one month replaces
a full-year production-cost study.

## First role-separated protocol

HOPE now exposes a minimal durable protocol for testing cooperation among
agents without changing the GTEP, physical-realization, or PCM mathematics:

1. A coordinator calls `hope_prepare_holistic_study`. HOPE validates the model
   roles, fingerprints both source cases, pins the solver, and publishes a
   `PREPARED` study manifest.
2. An executor calls `hope_launch_holistic_study` using only the study ID. HOPE
   rejects changed source inputs, then delegates the numerical work to the
   existing isolated and idempotent `hope_run_holistic` transaction.
3. Any client can call `hope_holistic_study_status` after a disconnect, or use
   `hope_wait_holistic_study` for a bounded server-side long poll. The durable
   study record reconciles its state with the durable run manifest and reports
   the next allowed action.
4. A validation agent calls `hope_audit_holistic_study`. It independently reads
   the published run and verifies source hashes, request identity, artifact
   scope, handoff and transfer validity, coverage, and every acceptance check.
   It then publishes an `ACCEPTED` or `REJECTED` audit receipt.

Study records default to `artifacts/agent_studies/`; run records remain under
`artifacts/agent_runs/`. The roots can be changed with
`HOPE_AGENT_STUDIES_ROOT` and `HOPE_AGENT_RUNS_ROOT`.

The coordinator, executor, and auditor are logical roles. They can be three LLM
agents, three tasks in one agent application, or one agent invoking the steps
sequentially. Agent labels are provenance labels, not authentication. This is
the first multi-agent experiment, not a claim that the internal GTEP,
realization, and PCM stages are already independent restartable services.

For the high-resolution Maryland benchmark, the coordinator instead calls
`hope_prepare_holistic_validation_study` with profile
`md-rps20-annual-gtep-monthly-pcm`. This registered preparation step keeps the
8,760-hour GTEP case, derives a requested calendar month of the 656-bus PCM case,
and optionally prepends prior chronological hours for unit-commitment and storage
warm-up. The derived cases live inside the study workspace and are pinned by
hash; the published ModelCases remain read-only. After preparation, executor,
status, and auditor behavior is identical to the general protocol above.

## Durable communication contract

Agents exchange references to artifacts, not unstructured copies of model data.
Each workflow run should retain:

- a unique request and run identifier;
- source case IDs and immutable source fingerprints;
- model and schema versions;
- solver and configuration snapshots;
- the GTEP-to-PCM handoff package;
- physical-realization and operational-template assumptions;
- validation, coverage, and acceptance results;
- output paths and terminal run status.

This contract prevents data crossover between simultaneous studies and makes a
run auditable even if an LLM session is lost.

## User interaction modes

HOPE should support three equally valid entry points:

1. **Single-model mode** -- run GTEP, PCM, or DART independently with normal HOPE
   settings and inputs.
2. **Guided linked mode** -- ask an LLM application to run a predefined workflow,
   inspect validation findings, and explain the results.
3. **Automated study mode** -- execute a declared scenario matrix with approval
   gates for material assumption changes and publication of accepted results.

In all modes, the same underlying HOPE cases, schemas, linkage functions, and
acceptance rules apply. The interface may change; the model contract does not.

## Human authority and approval gates

Agents may propose assumptions and diagnose failures, but humans retain control
over decisions that change study meaning. Explicit approval should be required
for actions such as selecting a different siting rule, filling material data
gaps, relaxing constraints, changing policy assumptions, or replacing a failed
run with a materially different scenario. Routine validation, polling, safe
retries, and creation of derived cases can remain automated.

## Current scope and next evolution

The repository currently demonstrates the GTEP-to-PCM portion of this mechanism,
including stable request and study IDs, coordinator/executor/auditor receipts,
asynchronous status, reconnect-safe polling, immutable source cases, handoff
validation, operational templates, and restricted and high-resolution
integration tests.

The literature-informed next step is evaluation, not further agent splitting.
HOPE preserves the first versioned evaluation task,
`md-rps20-annual-gtep-july-pcm-v1`, and provides
`md-rps20-annual-gtep-july-pcm-v2` for reproducing the first traced-wait
baseline. V2 requires the
traced `hope_wait_holistic_study` operation and a `hope_mcp_only` monitoring
attestation, together with server-observed traces, scoped
evidence submission, and an independent artifact-based scorer. These pieces
should be used with the completed annual-GTEP/July-PCM benchmark to compare:

1. the deterministic Julia workflow;
2. one LLM agent using the supported MCP tools; and
3. the current coordinator/executor/auditor protocol.

All three conditions should use the same cases, acceptance contract, tool surface,
and approximate computation budget. An independent evaluator should recompute
acceptance from artifacts and separately score task compliance, evidence-backed
reporting, invalid or duplicate calls, reconnect behavior, unsafe conclusions,
approval compliance, latency, and cost. Agent traces are hash-chained and the
evaluator classifies failures as system-design, inter-agent-misalignment, or
task-verification failures. It keeps the deterministic `model_passed` result
separate from `agent_passed`, so a good solve cannot conceal poor tool use or
unsupported reporting. The remaining work is to run repeated matched trials and
compare their distributions rather than judge the architectures from one
successful demonstration.

The HOPE trace observes only calls crossing the HOPE MCP boundary. It cannot
independently detect a local watcher, shell command, or another connector. The
monitoring attestation makes the intended boundary explicit; independent proof
of exclusive HOPE-tool use requires host-level telemetry.

The recommended v3 task removes solver-runtime bias from the efficiency gate.
It keeps passive wait calls in the trace and metrics but applies its 10-call
budget only to active tool decisions. Evaluations report total, active, passive,
and budgeted calls separately. It also requires zero duplicate role-bearing
calls: repeating prepare, launch, audit, or report submission fails the v3 agent
evaluation even if the lifecycle operation is idempotent. V1 and v2 remain
unchanged so their completed trials can still be reproduced exactly.

The first end-to-end v3 centralized-role pilot passed both model and agent
evaluation. It used 29 total calls, of which 23 were passive waits and only six
were active decisions. That pilot validates the runtime-neutral accounting, but
one successful run is not evidence that the role-separated architecture is
better. The controlled protocol in
`tools/hope_mcp_server/experiments/md_rps20_v3_matched_trials.yml` therefore
specifies five fresh single-agent and five fresh centralized-role repetitions.
The `hope-agent-experiment-summary` command checks their request, source-case,
and solver hashes before comparing pass rates, tool behavior, elapsed time,
false-safe claims, and classified failures.

For architecture comparisons, elapsed time is the executor receipt's interval
from launch completion to run completion. This covers the launched model job
but excludes uncontrolled pauses while a human opens the next role thread. The
evaluator also retains the complete trace span as `workflow_elapsed_seconds`;
that value is useful for diagnosing handoff delays but is not a model-runtime
metric.

The lifecycle is now enforced at the server boundary rather than left to prompt
obedience. HOPE rejects final-report submission and agent evaluation until the
study is `ACCEPTED`, `REJECTED`, or `FAILED`. A trace-write problem is returned
as a warning alongside the underlying lifecycle result, so an agent cannot
mistake a locked trace file for a failed model. Evaluation reports pin the
authoritative run and audit hashes, and the experiment summarizer excludes
scores that have become stale because those artifacts changed afterward.

A prompt-design pilot that used descriptive output fields instead of the four
required claim keys was rejected before evaluation. The current protocol names
those keys explicitly. The evaluator can now score a rejected or missing final
report as agent failure while still recognizing a successful model run, and the
experiment summary blocks comparison when any formal study lacks an evaluation
artifact. This prevents failed trials from being lost through survivorship bias.
The first formal-prefix single-agent attempt on 2026-10-25 is also explicitly
excluded: it submitted and evaluated while the run was still active, although
the run later published successfully. It is retained as system-design evidence,
not counted as a scientific architecture replicate. Single-agent replicate 05
is likewise retained but excluded because the accepted study was later reused,
adding a second prepare and report submission to its trace. Replicate 07 replaces
it in the five-run formal matrix.

Only after this comparison should HOPE decide whether GTEP, physical realization,
and PCM benefit from separate persistent agents. Meanwhile, physical-realization
and operational-feedback development can continue as deterministic model work.
DART should be added to the connected workflow after the GTEP-to-PCM evaluation
protocol is stable, so added model scope is not confused with added agent
complexity.

See [Multi-Model and Multi-Agent System Design](multi_agent_system_design.md) for
the broader design rationale and development roadmap.
