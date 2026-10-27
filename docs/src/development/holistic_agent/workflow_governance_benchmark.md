# [HOPE Workflow-Governance Agent Benchmark](@id workflow-governance-benchmark)

## Classification

This benchmark is a **workflow-governance benchmark** for the HOPE AI-agent
tooling. It is not a benchmark of cooperating GTEP, physical-realization, and
PCM specialist agents.

Both evaluated architectures invoked the same deterministic HOPE transaction:

```text
annual GTEP -> case-defined physical realization -> July PCM -> acceptance audit
```

The scientific unit was therefore unchanged. The independent variable was only
the organization of the LLM workflow around that unit:

- `single_agent`: one Claude thread prepared, launched, monitored, audited,
  reported, and evaluated the transaction;
- `centralized_roles`: separate coordinator, executor, and auditor threads
  performed those same lifecycle operations through a shared durable study.

The benchmark answers whether HOPE can safely support one agent or separated
governance roles around a composite workflow. It does **not** answer whether a
GTEP agent, realization agent, and PCM agent can improve a scenario through
model-specific reasoning and feedback.

## Why the benchmark was needed

Before exposing individual models to cooperating agents, HOPE needed a reliable
agent-facing control plane. The benchmark exercised the following implemented
capabilities:

- durable study preparation, launch, status recovery, audit, and evaluation;
- immutable request identifiers and source fingerprints;
- independent coordinator, executor, and auditor receipts;
- hash-chained server-observed tool traces;
- idempotent lifecycle operations and duplicate-role-call rejection;
- bounded active-call accounting that excludes passive long polling;
- scoped evidence submission and authoritative claim verification;
- separation of `model_passed` from `agent_passed`;
- stale-evaluation detection and explicit exclusion of confounded trials; and
- comparable executor-runtime measurement that excludes manual thread handoffs.

These are product and governance properties of the HOPE AI-agent tool. They are
foundational for later model-specialist agents, even though they do not establish
that additional scientific agents improve a model result.

## Protocol

The versioned protocol is
`tools/hope_mcp_server/experiments/md_rps20_v3_matched_trials.yml`. Ten valid
formal trials used the same Maryland source cases, Gurobi solver, annual GTEP,
July PCM evaluation month, 48-hour PCM warm-up, task rules, claims, and evidence
requirements.

The valid single-agent studies were repetitions 02, 03, 04, 06, and 07. The
valid centralized-role studies were repetitions 01 through 05. Two formal-prefix
single-agent studies were preserved but explicitly excluded:

- repetition 01 submitted and evaluated before the model run reached a terminal
  state;
- repetition 05 was reused after acceptance, adding duplicate role-bearing calls
  to its trace.

The replacement studies and evaluator changes prevent either failure from being
hidden through survivorship bias.

## Results

| Metric | Single agent | Centralized roles |
| --- | ---: | ---: |
| Valid trials | 5 | 5 |
| Model passes | 5/5 | 5/5 |
| Agent passes | 5/5 | 5/5 |
| Mean active calls | 6.0 | 6.0 |
| Mean passive waits | 19.0 | 20.6 |
| Mean executor runtime | 933.402 s | 975.991 s |
| Executor-runtime population SD | 195.201 s | 52.742 s |
| Invalid tool calls | 0 | 0 |
| Duplicate role calls | 0 | 0 |
| False-safe claims | 0 | 0 |
| Classified failures | 0 | 0 |

All ten trials shared the same task ID, request hash, GTEP source hash, PCM
source hash, solver, and condition signature. The experiment summary therefore
reports `ready_for_comparison: true`, matched conditions, and zero incomplete
studies.

Centralized roles were 42.589 seconds, or 4.56%, slower on average. With five
observations per architecture, an exploratory exact two-sided permutation test
for the mean runtime difference produced `p = 0.698`. This is not evidence of a
runtime advantage or disadvantage. The smaller centralized runtime dispersion
is descriptive and requires more observations before interpretation.

`workflow_elapsed_seconds` is not used for architecture performance. It includes
uncontrolled time spent opening and transferring between Claude threads. The
comparable metric is `run_elapsed_seconds`, derived from the executor receipt's
launch-completion to run-completion interval.

Generated local summaries are stored under
`artifacts/agent_experiments/md-rps20-v3-matched/` as YAML, Markdown, per-run
CSV, and per-architecture CSV files.

## Conclusion

The benchmark found no difference in correctness, agent compliance, evidence
quality, or active tool decisions. It supports the following bounded conclusion:

> HOPE's current MCP study lifecycle can reliably support both a single LLM
> workflow agent and separated coordinator/executor/auditor roles around the
> same deterministic composite GTEP-to-PCM transaction.

It does not support a claim that role separation improves HOPE's scientific
results, nor that a model-specialist multi-agent architecture is better than one
scientific agent.

## Product status after the benchmark

| Capability | Status | Meaning |
| --- | --- | --- |
| HOPE exposed as structured LLM tools | Implemented | An MCP-capable agent can run models, inspect results, validate settings, and use the durable holistic lifecycle. |
| Safe composite GTEP-to-PCM agent workflow | Implemented for the registered benchmark path | The transaction is persistent, auditable, reconnect-safe, and independently evaluated. |
| Workflow-governance role separation | Implemented and benchmarked | Coordinator, executor, and auditor roles can operate on one durable study without shared chat context. |
| General scientific scenario agent | Partial | HOPE has many required tools and contracts, but no finalized agent policy for composing arbitrary studies and revisions. |
| GTEP, realization, and PCM specialist agents | Not implemented as a cooperative agent system | The stages remain inside the deterministic composite transaction rather than separate agent-controlled contracts. |
| Bounded cross-model scientific feedback | Design stage | Revision requests, authority boundaries, convergence rules, and human approvals still require a product specification. |

Accordingly, the HOPE AI-agent **tool foundation is implemented**, while the
original cooperating model-specialist agent design is **not finished**. The next
design work should focus on the product contract for scientific agents rather
than additional comparisons of governance roles around the existing composite
transaction.

See [Multi-Model and Multi-Agent System Design](@ref multi-agent-system-design)
for the broader architecture and [HOPE Multi-Agent Mechanism](multi_agent_mechanism.md)
for the implemented lifecycle and trace mechanisms.
