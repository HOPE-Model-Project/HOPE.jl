# HOPE MCP Server

This package provides two MCP server entrypoints for the HOPE Julia repository:

- `hope-mcp-server`
  - local full-access `stdio` server for Claude Desktop
- `hope-mcp-server-chatgpt`
  - remote read-only `streamable-http` server for ChatGPT web developer mode

Both variants resolve cases dynamically from `ModelCases/` by looking for
`Settings/HOPE_model_settings.yml`.

## Relationship to PowerMCP

This directory is the upstream development copy of the HOPE-specific MCP
adapter. `Power-Agent/PowerMCP` vendors a downstream copy under `HOPE/` so it
can distribute HOPE together with its other power-system connectors. The two
directories are intentionally duplicated; they are not a symlink or Git
submodule.

HOPE owns the model-aware core and cross-repository integration tests. PowerMCP
owns the MCP SDK version, transport entrypoints, package metadata, lockfile,
installation documentation, and its layout-specific unit tests. The exact
boundary is recorded in `powermcp_sync.yml`. After
committing an upstream HOPE change, check a local PowerMCP checkout with:

```bash
python tools/hope_mcp_server/scripts/sync_to_powermcp.py \
  --powermcp-root /path/to/PowerMCP --check
```

Apply the managed-file update with `--apply`, then review and test the resulting
PowerMCP changes before committing them there. The sync records the originating
HOPE commit in `PowerMCP/HOPE/SYNCED_FROM_HOPE.yml` and refuses to publish
uncommitted managed source files.

## Tool split

Claude/local full-access server:

- `hope_warmup`
- `hope_job_status`
- `hope_cancel_job`
- `hope_debug_solver_environment`
- `hope_debug_solver_environment_async`
- `hope_case_info`
- `hope_output_summary`
- `hope_run_hope`
- `hope_update_settings`
- `hope_validate_case`
- `hope_read_output`
- `hope_emission_compliance`
- `hope_nodal_prices`
- `hope_compare_cases`
- `hope_run_holistic`
- `hope_holistic_status`
- `hope_prepare_holistic_study`
- `hope_prepare_holistic_validation_study`
- `hope_launch_holistic_study`
- `hope_holistic_study_status`
- `hope_wait_holistic_study`
- `hope_audit_holistic_study`
- `hope_submit_holistic_agent_report`
- `hope_evaluate_holistic_agent_study`
- `hope_run_erec`
- `hope_rep_day_audit`
- `hope_aggregation_audit`
- `hope_open_dashboard`
- `hope_close_dashboard`

## Agent evaluation

The deterministic holistic audit and the agent evaluation answer different
questions. `hope_audit_holistic_study` verifies the model run and its transfer
artifacts. The agent evaluation verifies whether an LLM used the workflow
correctly and reported the result faithfully.

Lifecycle calls made through the MCP server are recorded in a hash-chained
`agent_trace.yml` under the durable study directory. After the model audit, the
agent calls `hope_submit_holistic_agent_report` with four claims and at least
three evidence files scoped to the study or run workspace:

- `study_accepted`
- `run_published`
- `audit_accepted`
- `all_acceptance_checks_passed`

Then an independent evaluator calls `hope_evaluate_holistic_agent_study`. Its
report keeps `model_passed` separate from `agent_passed`, measures tool use and
retries, verifies evidence and claims against authoritative artifacts, and
classifies failures as system-design, inter-agent-misalignment, or
task-verification failures. Task
`md-rps20-annual-gtep-july-pcm-v1` preserves the first benchmark contract.
Task `md-rps20-annual-gtep-july-pcm-v2` requires the traced
`hope_wait_holistic_study` long-poll operation and a `hope_mcp_only` monitoring
attestation. Its thresholds are intentionally fixed so future benchmark changes
require a new task version.

The monitoring attestation declares that the agent used only HOPE MCP lifecycle
tools while waiting. The server can verify its own traced calls, but it cannot
independently observe local scripts, shell commands, or other client tools.
Independent verification of that stronger claim requires host-level telemetry.

ChatGPT remote read-only server:

- `hope_case_info`
- `hope_output_summary`
- `hope_validate_case`
- `hope_read_output`
- `hope_emission_compliance`
- `hope_nodal_prices`
- `hope_compare_cases`
- `hope_rep_day_audit`
- `hope_aggregation_audit`

## One-time setup

1. Sync the Python package with `uv`:

```bash
uv --directory /path/to/HOPE/tools/hope_mcp_server sync
```

2. Make sure the HOPE Julia environment is instantiated:

```bash
julia --project=/path/to/HOPE -e "using Pkg; Pkg.instantiate(); Pkg.precompile()"
```

3. Optional but recommended for agent-controlled runs: verify the active HOPE environment
   and solver setup before the first model launch:

```bash
julia --project=/path/to/HOPE /path/to/HOPE/tools/repo_utils/agent_preflight_check.jl \
  ModelCases/MD_GTEP_clean_case
```

For commercial solvers, the preflight script checks both package loading and solver
initialization. Example:

```bash
julia --project=/path/to/HOPE /path/to/HOPE/tools/repo_utils/agent_preflight_check.jl \
  ModelCases/MD_GTEP_clean_case --solver gurobi
```

Gurobi, CPLEX, and SCIP are optional (weak) dependencies of HOPE. Their Julia
wrapper packages must be installed in an environment on Julia's load path, using
the same Julia version and `JULIA_DEPOT_PATH` as the MCP server. On macOS or
Linux, for example:

```bash
JULIA_DEPOT_PATH=/path/to/julia_depot julia -e \
  'import Pkg; Pkg.activate(); Pkg.add("Gurobi")'
```

The corresponding Windows PowerShell commands are:

```powershell
$env:JULIA_DEPOT_PATH = "E:\julia_depot"
& "C:\path\to\julia.exe" -e 'import Pkg; Pkg.activate(); Pkg.add("Gurobi")'
```

Repeat the installation after upgrading to a new Julia minor version because it
uses a new version environment, such as `@v1.13`. Before launching a new
standalone or holistic model job, the MCP performs a lightweight package-discovery
check. A missing wrapper returns `optional_solver_unavailable`; a probe failure or
timeout returns `optional_solver_probe_failed`. Neither condition launches the
model or creates a new holistic workspace. This lightweight check does not test
the native solver library or license; use the full preflight command above for
that.

## Claude Desktop config

Add this server entry to your Claude Desktop MCP config:

```json
{
  "mcpServers": {
    "hope": {
      "command": "uv",
      "args": [
        "--directory",
        "/path/to/HOPE/tools/hope_mcp_server",
        "run",
        "hope-mcp-server"
      ],
      "env": {
        "HOPE_REPO_ROOT": "/path/to/HOPE",
        "HOPE_JULIA_BIN": "/path/to/julia",
        "JULIA_DEPOT_PATH": "/path/to/julia_depot",
        "HOPE_AGENT_RUNS_ROOT": "/path/to/agent_runs"
      }
    }
  }
}
```

## ChatGPT read-only remote server

Start the read-only server locally on your machine:

```bash
HOPE_REPO_ROOT=/path/to/HOPE \
HOPE_MCP_PUBLIC_HOSTNAME=hope.example.com \
HOPE_MCP_HOST=127.0.0.1 \
HOPE_MCP_PORT=8001 \
uv --directory /path/to/HOPE/tools/hope_mcp_server run hope-mcp-server-chatgpt
```

Important notes:

- This entrypoint uses FastMCP `streamable-http`.
- It is intended for ChatGPT web developer mode, not Claude Desktop.
- It does not expose case-running or settings-writing tools.
- If you publish the service behind Cloudflare Tunnel or another reverse proxy,
  set `HOPE_MCP_PUBLIC_HOSTNAME` to the public hostname so FastMCP accepts the
  forwarded `Host` header.
- ChatGPT currently requires a remote HTTPS-reachable MCP endpoint, so you will
  typically place a tunnel or reverse proxy in front of this local process.

Suggested exposure options:

- Cloudflare Tunnel
- Tailscale Funnel
- a reverse proxy on your own HTTPS domain

## Case IDs

Both servers accept:

- exact `ModelCases` directory names such as `USA_64zone_GTEP_case`
- prefixed paths such as `ModelCases/USA_64zone_GTEP_case`
- the legacy alias `md_gtep_clean`

Case discovery uses `HOPE_MODELCASES_PATH` when it is set and otherwise falls
back to `<HOPE_REPO_ROOT>/ModelCases`. This permits generated validation cases
to remain outside the registered ModelCases checkout.

## Agent-safe GTEP-to-PCM runs

`hope_run_holistic(gtep_case_id, pcm_case_id, request_id, solver)` validates the
two model roles, fingerprints their settings and input data, and copies them into
an isolated per-request workspace before launching Julia. Existing model outputs
are not copied. The default workspace root is `artifacts/agent_runs/`; set
`HOPE_AGENT_RUNS_ROOT` to place these run records elsewhere.

This workflow requires a HOPE.jl checkout containing
`tools/repo_utils/run_holistic_agent_job.jl`, first shipped with revision
`8126f0f`. The MCP server checks for the runner before copying either case and
returns `incompatible_hope_checkout` when an older checkout is configured.

Use a stable `request_id` when a caller may retry after a timeout. Repeating the
same request ID with identical source fingerprints returns the existing run;
reusing it for different cases, inputs, or a different solver is rejected. Poll
`hope_holistic_status(request_id)` for reconnect-safe status and artifact paths.
Each workspace contains `run_manifest.yml`, isolated GTEP and PCM cases, realized
PCM inputs, handoff audits, and model outputs. If the PCM case supplies
`Settings/HOPE_holistic_acceptance.yml`, the Julia wrapper also requires all
declared capability checks to pass before publishing the run.

The manifest records both the preparing MCP process and the launched Julia PID.
After a reconnect, a nonterminal manifest whose owning process is no longer
alive is converted to a durable failed result instead of remaining `running`
forever. Public status values are stable across reconnects: successful runs are
`done`, failed runs return `ok: false` with `status: failed`, and cancellations
are `cancelled`.

Agent workspaces are retained intentionally as auditable run records. HOPE does
not delete them automatically; operators should archive or remove completed
request directories under `HOPE_AGENT_RUNS_ROOT` according to their own data
retention policy.

### Role-separated multi-agent studies

The full local server also exposes a four-step durable protocol:

- `hope_prepare_holistic_study(...)` for the study coordinator;
- `hope_prepare_holistic_validation_study(...)` to materialize the registered
  annual-GTEP/monthly-PCM Maryland profile in an isolated study workspace;
- `hope_launch_holistic_study(study_id, ...)` for the workflow executor;
- `hope_holistic_study_status(study_id)` for reconnect-safe monitoring; and
- `hope_wait_holistic_study(study_id, ...)` for bounded server-side long-polling;
- `hope_audit_holistic_study(study_id, ...)` for independent acceptance.

Preparation does not launch Julia. It pins the source fingerprints and request
hash in `artifacts/agent_studies/<study_id>/study_manifest.yml`. Execution
rechecks those fingerprints before delegating to `hope_run_holistic`. Audit
reads the durable run evidence and writes `audit_report.yml`, then records an
`ACCEPTED` or `REJECTED` receipt. Set `HOPE_AGENT_STUDIES_ROOT` to relocate
study manifests. These are logical roles and can be called by separate agents
or sequentially by one MCP client.

Executor receipts distinguish lifecycle progress from outcome: `run_status`
reports `running`, `done`, `failed`, or `cancelled`; `run_ok` is `null` while a
run is active, `true` after successful completion, and `false` after terminal
failure or cancellation.

## Local run

Full local server:

```bash
uv --directory /path/to/HOPE/tools/hope_mcp_server run hope-mcp-server
```

Read-only remote server:

```bash
HOPE_REPO_ROOT=/path/to/HOPE \
HOPE_MCP_PUBLIC_HOSTNAME=hope.example.com \
HOPE_MCP_PORT=8001 \
uv --directory /path/to/HOPE/tools/hope_mcp_server run hope-mcp-server-chatgpt
```

## Test

```bash
uv --directory /path/to/HOPE/tools/hope_mcp_server run \
  python -m unittest discover -s tests -v
```

The normal suite mocks solver launches. To run the restricted GTEP-to-PCM
agent integration test through the real MCP workflow, set the opt-in flag and
optionally choose a solver:

```bash
HOPE_RUN_HOLISTIC_AGENT_INTEGRATION=1 \
HOPE_HOLISTIC_AGENT_SOLVER=gurobi \
uv --directory /path/to/HOPE/tools/hope_mcp_server run \
  python -m unittest discover -s tests -p test_holistic_agent_integration.py -v
```

The integration test requires the restricted Maryland GTEP and PCM cases under
`ModelCases/`. It asserts optimal termination, handoff and transfer validity,
capability coverage, source immutability, and status recovery after a simulated
MCP reconnect.

To exercise the same restricted case through separate coordinator, executor,
and auditor calls on Windows:

```powershell
.\scripts\run_holistic_multi_agent_integration.ps1 -Solver gurobi
```

This opt-in test publishes all three role receipts, removes the in-memory job
mapping to simulate a reconnect, and accepts the study only after independently
checking its manifests and scientific evidence.

The opt-in high-resolution test keeps the annual 8760-hour four-zone GTEP stage
and derives an isolated calendar-month slice of the 656-bus PCM case. On Windows,
run the July test with:

```powershell
.\scripts\run_md_july_agent_integration.ps1
```

The launcher defaults to July and Gurobi. Optional arguments include
`-Month`, `-Solver`, and `-TimeoutSeconds`. For an interactive multi-agent run,
the coordinator can call `hope_prepare_holistic_validation_study` with profile
`md-rps20-annual-gtep-monthly-pcm`, the desired month, and the number of prior
warm-up hours. HOPE materializes the derived cases under that study's artifact
directory, validates the temporal manifest, fingerprints the derived inputs,
and leaves both published ModelCases unchanged. The executor and auditor then
use the normal `hope_launch_holistic_study` and `hope_audit_holistic_study`
steps. This is intentionally excluded from the normal test suite because it
performs a full annual GTEP solve and a detailed monthly nodal PCM solve.

If an agent launches a long-running Julia job and needs to stop it early, call
`hope_cancel_job(job_id)` with the `job_id` returned by `hope_warmup`,
`hope_run_hope`, `hope_run_holistic`, or `hope_run_erec`.

For holistic runs, prefer `hope_holistic_status(request_id)` over relying only on
the session-local job ID. The Julia worker writes `PUBLISHED` or `FAILED` to the
persistent manifest even when the MCP client disconnects.

If Claude appears to be running stale code or the wrong Julia environment, call
`hope_debug_solver_environment(case_id, solver, timeout_seconds)` to inspect the active project,
depot path, loaded `HOPE.jl` path, and the exact optimizer constructor JuMP sees.

If the synchronous debug probe risks hitting Claude-side request timeouts, call
`hope_debug_solver_environment_async(case_id, solver)` and then poll with
`hope_job_status(job_id)` to retrieve the full probe stdout, stderr, and parsed fields.

## Dashboard launch notes

The `hope_open_dashboard` tool launches the HOPE dashboards from the repository
root and, on Windows, intentionally shells out through `cmd.exe /d /c` instead
of invoking Python directly. This mirrors the manual Command Prompt launch path
that has proven reliable with Claude Desktop and the local MCP server.

The tool also:

- sanitizes inherited Python environment variables that can interfere with Dash startup
- sets `HOPE_MODELCASES_PATH` so the dashboard can discover `ModelCases/`
- sets `HOPE_DASHBOARD_PORT` so the runner scripts can bind the requested port
- writes startup logs to `tools/hope_dashboard/logs/`

If `hope_open_dashboard` reports a startup timeout or immediate crash, check the
returned `log_path` first.
