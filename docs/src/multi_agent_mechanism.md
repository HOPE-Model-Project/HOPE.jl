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
including stable request IDs, asynchronous status, reconnect-safe polling,
immutable source cases, handoff validation, operational templates, and
restricted and high-resolution integration tests. The next architectural work
should deepen physical realization and operational feedback between GTEP and
PCM before adding DART to the connected workflow.

See [Multi-Model and Multi-Agent System Design](multi_agent_system_design.md) for
the broader design rationale and development roadmap.
