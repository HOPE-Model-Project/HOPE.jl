# HOPE-AI: Running HOPE with an LLM Agent

HOPE supports agentic AI control via the [Model Context Protocol (MCP)](https://modelcontextprotocol.io/introduction) — a standard that lets LLM hosts invoke tools, run models, and read results without any manual scripting. This page explains two supported setups:

- **Claude Desktop** with a local full-access `stdio` MCP server for running cases, changing settings, and opening dashboards.
- **ChatGPT web** with a remote read-only MCP server for inspecting cases and outputs through developer mode.

!!! note "PowerAgent community"
    The HOPE MCP server is part of [PowerAgent](https://poweragent.seas.harvard.edu/) — an open-source community for agentic AI in power systems, maintained by the [Power and AI Initiative (PAI)](https://pai.seas.harvard.edu/) at Harvard SEAS. The HOPE server is also distributed through [PowerMCP](https://github.com/Power-Agent/PowerMCP/tree/main/HOPE), a collection of MCP servers for power system software.

---

## Available Tools

Once configured, Claude Desktop has access to HOPE tools organized into six groups:

### Job Execution

| Tool | Description |
| ------ | ------------- |
| `hope_warmup` | Pre-compiles the Julia/HOPE environment in the background. Call once per session before the first run. Returns a `job_id` immediately. |
| `hope_run_hope` | Launches a HOPE single-case optimization run (GTEP, PCM, or DART) in the background. Returns a `job_id` immediately. |
| `hope_run_holistic` | Launches an isolated two-stage GTEP→PCM workflow. A stable `request_id` makes retries idempotent; source fingerprints prevent scenario crossover. |
| `hope_holistic_status` | Reads reconnect-safe GTEP→PCM status and artifact paths from the persistent request manifest. |
| `hope_run_erec` | Launches EREC (Equivalent Reliability Enhancement Capability) postprocessing on a completed run to quantify each resource's reliability contribution. Returns a `job_id` immediately. |
| `hope_job_status` | Polls any background job for progress. Returns elapsed time, stdout tail, and the full output summary when the job completes. |

### Settings Management

| Tool | Description |
|------|-------------|
| `hope_update_settings` | Patches any field in `HOPE_model_settings.yml` — e.g., change `carbon_policy`, `solver`, `network_model`, or `unit_commitment`. Validates each value, backs up the original file, and warns on contradictions. |
| `hope_validate_case` | Checks settings for contradictions and missing files (e.g., `write_shadow_prices=1` without `network_model > 0`, or a missing solver settings file). Returns a warning list and `is_valid` flag. |

### Output Reading

| Tool | Description |
| ------ | ------------- |
| `hope_case_info` | Reads case settings and output file inventory instantly — no Julia required. |
| `hope_output_summary` | Reads and summarizes existing output CSVs (planning cost/builds or DART acceptance, coverage, settlement, and solver status) instantly — no Julia required. |
| `hope_read_output` | Reads any specific output CSV with optional column filters — e.g., dispatch for a single zone, or capacity for one technology. |
| `hope_emission_compliance` | Parses `carbon_emissions.csv` and `rps_target.csv` to report per-state compliance status, violation amounts, and penalty costs. |
| `hope_nodal_prices` | Reads locational marginal prices (LMPs) from `nodal_prices.csv`, optionally filtered by bus/zone and hour range. |

### Scenario Comparison

| Tool | Description |
|------|-------------|
| `hope_compare_cases` | Compares system cost, capacity builds (MW by technology), storage builds (MWh), and CO2 emissions across two or more cases. Returns side-by-side tables and diffs relative to a baseline. |

### Audit Tools

| Tool | Description |
|------|-------------|
| `hope_rep_day_audit` | Summarizes representative-period clustering: period assignments, weights, total representative hours, and compression ratio vs. a full 8760-hour year. |
| `hope_aggregation_audit` | Summarizes resource aggregation: raw-to-cluster mapping, reduction ratio (e.g., 120 generators to 30 clusters), and per-cluster capacity. |

### Dashboard

| Tool | Description |
|------|-------------|
| `hope_open_dashboard` | Launches the GTEP or PCM dashboard for a completed case. DART has no dashboard yet and returns an explicit unsupported-mode response; its CSVs remain available through the output tools. |
| `hope_close_dashboard` | Stops a dashboard launched by `hope_open_dashboard`. Pass `port=8051` or `port=8050` to stop a specific dashboard, or omit `port` to stop all dashboards tracked in the current session. |

---

## Prerequisites

- **HOPE** cloned and Julia environment instantiated (see [Installation](@ref))
- **Python** >= 3.10 (the MCP server is a Python package)
- **uv** ([astral.sh/uv](https://astral.sh/uv)) — fast Python package manager
- **Claude Desktop** ([claude.ai/download](https://claude.ai/download)) or any MCP-compatible LLM host

---

## One-Time Setup

### Step 1 — Install uv

**Windows (PowerShell):**

```powershell
powershell -ExecutionPolicy ByPass -c "irm https://astral.sh/uv/install.ps1 | iex"
```

**macOS / Linux:**

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```

Restart your terminal after installation so `uv` is on your PATH.

### Step 2 — Sync the MCP server Python package

```bash
uv --directory /path/to/HOPE/tools/hope_mcp_server sync
```

This creates a local `.venv` inside `tools/hope_mcp_server/` with all dependencies (including the `mcp` package).

### Step 2b — Optional agent preflight check

Before the first solver-backed run in a new session, you can verify that Claude is
pointing at the correct HOPE Julia environment and that the requested solver can be
initialized:

```bash
julia --project=/path/to/HOPE /path/to/HOPE/tools/repo_utils/agent_preflight_check.jl \
  ModelCases/MD_GTEP_clean_case
```

To explicitly test a commercial solver such as Gurobi:

```bash
julia --project=/path/to/HOPE /path/to/HOPE/tools/repo_utils/agent_preflight_check.jl \
  ModelCases/MD_GTEP_clean_case --solver gurobi
```

The script prints a short pass/fail checklist and exits nonzero if the environment,
case path, solver package, license handshake, or `HOPE.initiate_solver(...)` path fails.

### Step 3 — Configure Claude Desktop

Locate your Claude Desktop config file:

- **Windows:** `%APPDATA%\Claude\claude_desktop_config.json`
  (typically `C:\Users\<user>\AppData\Roaming\Claude\claude_desktop_config.json`)
- **macOS:** `~/Library/Application Support/Claude/claude_desktop_config.json`

Add the `hope` server entry:

**Windows example:**

```json
{
  "mcpServers": {
    "hope": {
      "command": "uv",
      "args": [
        "--directory",
        "C:\\path\\to\\HOPE\\tools\\hope_mcp_server",
        "run",
        "hope-mcp-server"
      ],
      "env": {
        "HOPE_REPO_ROOT": "C:\\path\\to\\HOPE",
        "HOPE_JULIA_BIN": "C:\\Users\\<user>\\.julia\\juliaup\\julia-1.x.y+0.x64.w64.mingw32\\bin\\julia.exe"
      }
    }
  }
}
```

**macOS / Linux example:**

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
        "HOPE_JULIA_BIN": "/path/to/.julia/juliaup/julia-1.x.y+0.aarch64.apple.darwin14/bin/julia"
      }
    }
  }
}
```

!!! tip "Finding your Julia binary path"
    Run `julia -e 'println(Sys.BINDIR)'` in a terminal to print the exact path to your Julia binary directory. The binary is `julia` (macOS/Linux) or `julia.exe` (Windows) inside that directory. If `julia` is already on your system PATH, you can omit the `HOPE_JULIA_BIN` key entirely.

Restart Claude Desktop after editing the config.

### Step 4 — Optional ChatGPT web read-only setup

ChatGPT currently requires a **remote HTTPS MCP endpoint**. The simplest workflow is:

1. start the read-only HOPE server locally,
2. expose it through a tunnel such as **Cloudflare Tunnel**,
3. connect the resulting HTTPS `/mcp` URL in ChatGPT web developer mode.

The read-only ChatGPT entrypoint exposes only analysis tools such as `hope_case_info`, `hope_output_summary`, `hope_read_output`, and comparison/audit helpers. It does **not** expose `hope_run_hope`, `hope_update_settings`, or dashboard-launch tools.

!!! note "Current plan limitations"
    As of April 14, 2026, OpenAI's public help docs indicate that full MCP support is rolling out for **Business / Enterprise / Edu** plans, while **Pro** can connect remote MCPs with read/fetch permissions in developer mode. In our testing, a **Plus** account did not expose the custom MCP app flow needed for this setup. Check the current OpenAI docs and your account UI before relying on ChatGPT-side access.

**Step 4a — Start the read-only server locally**

**Windows (PowerShell):**

```powershell
$env:HOPE_REPO_ROOT = "C:\path\to\HOPE"
$env:HOPE_MCP_PORT = "8001"
$env:HOPE_MCP_HOST = "127.0.0.1"
$env:HOPE_MCP_PUBLIC_HOSTNAME = "hope.example.com"
& "C:\path\to\HOPE\tools\hope_mcp_server\.venv\Scripts\python.exe" -m hope_mcp_server.chatgpt
```

**macOS / Linux:**

```bash
HOPE_REPO_ROOT=/path/to/HOPE \
HOPE_MCP_PORT=8001 \
HOPE_MCP_HOST=127.0.0.1 \
HOPE_MCP_PUBLIC_HOSTNAME=hope.example.com \
/path/to/HOPE/tools/hope_mcp_server/.venv/bin/python -m hope_mcp_server.chatgpt
```

**Step 4b — Publish the local port through Cloudflare Tunnel**

1. Install `cloudflared`.
2. Create a Cloudflare Tunnel and install the connector on the machine running HOPE.
3. Add a **published application route** (public hostname), for example:
   - hostname: `hope.example.com`
   - service: `http://localhost:8001`
4. Keep the local HOPE server process running while the tunnel is active.

**Step 4c — Connect the MCP endpoint in ChatGPT web**

Use the tunnel URL with the MCP path:

```text
https://hope.example.com/mcp
```

If you test that URL with a plain browser or `curl`, you may see a `406 Not Acceptable` response asking for `text/event-stream`. That is expected: it means the route is reachable, but the client is not speaking MCP yet.

For the full current ChatGPT read-only deployment notes, see:

- [`tools/hope_mcp_server/README.md`](https://github.com/HOPE-Model-Project/HOPE.jl/blob/main/tools/hope_mcp_server/README.md)

---

## Typical Claude Desktop Session

Julia's first startup includes precompilation which can take several minutes. The recommended flow is:

**1. Warm up Julia (once per session)**

> *"Warm up Julia for HOPE."*

Claude calls `hope_warmup`, which launches Julia precompilation in the background and returns a `job_id`. Claude then polls `hope_job_status` until precompilation finishes (~3-5 min on first call, much faster on subsequent calls in the same session).

**2. Validate and optionally update settings**

> *"Check the md_gtep_clean case settings and enable the carbon cap."*

Claude calls `hope_validate_case` to detect any contradictions, then `hope_update_settings` to patch `carbon_policy: 1` into `HOPE_model_settings.yml`. The original file is backed up automatically.

**3. Run a HOPE case**

> *"Run the md_gtep_clean HOPE case."*

Claude calls `hope_run_hope` for a standalone model. For a two-stage GTEP-PCM run,
`hope_run_holistic` creates an isolated workspace and returns both a session-local
`job_id` and persistent `request_id`. Claude polls `hope_holistic_status` using the
request ID. The status remains available after an MCP reconnect, and retrying the
same request cannot silently start a conflicting scenario.

**4. Inspect results**

> *"Summarize the capacity investments. Are we in compliance with the carbon cap?"*

Claude calls `hope_output_summary` for the cost and build summary, then `hope_emission_compliance` to check carbon and RPS policy compliance — all instant, reading only the output CSVs.

**5. Drill into specifics**

> *"Show me the hourly dispatch for solar in zone MD."*

Claude calls `hope_read_output` with `filename="dispatch.csv"` and `filters={"Zone": "MD", "Technology": "SolarPV"}`.

**6. Compare scenarios**

> *"How does cost and emissions change if I also enable the RPS target? Run that version and compare."*

Claude calls `hope_update_settings` to enable `clean_energy_policy: 1`, re-runs with `hope_run_hope`, then calls `hope_compare_cases` to get a side-by-side diff of cost, capacity, and CO2.

---

## Supported Cases

The MCP server now discovers cases dynamically from `ModelCases/` by looking for case directories that contain:

```text
Settings/HOPE_model_settings.yml
```

Accepted case identifiers include:

- exact `ModelCases` directory names such as `USA_64zone_GTEP_case`
- prefixed paths such as `ModelCases/USA_64zone_GTEP_case`
- the legacy alias `md_gtep_clean`

No manual case registry update is needed when you add a new valid case folder under `ModelCases/`.

---

## Example Prompts

The prompts below demonstrate what you can ask Claude in a typical session. Copy them verbatim or adapt them to your case.

### Job Execution

**`hope_warmup` — Pre-compile Julia before the first run**

> "Warm up Julia for HOPE."
> "Initialize the HOPE Julia environment and let me know when it's ready."
> "Pre-compile HOPE so the first model run starts fast."

**`hope_run_hope` — Launch a single-case HOPE optimization**

> "Run the `md_gtep_clean` HOPE case."
> "Start a HOPE GTEP run for the Maryland clean energy case."
> "Launch a HOPE model run and tell me when it finishes."

**`hope_run_holistic` — Two-stage GTEP→PCM workflow**

> "Run the holistic two-stage analysis: first solve capacity expansion, then re-run production cost with the built fleet fixed."
> "Execute a holistic HOPE run for the `md_gtep_clean` case using the `md_pcm_clean` case for the PCM stage."
> "Use request ID `md-reference-2035-v1`, run the GTEP-to-PCM workflow with Gurobi, and keep polling its persistent status."

The tool rejects reversed model roles, unsupported solvers, unsafe request IDs,
and reuse of a request ID after either source case changes. It excludes old output
trees from the isolated copies. When the PCM case includes
`HOPE_holistic_acceptance.yml`, publication also requires all declared coverage
checks to pass.

**`hope_holistic_status` — Poll a persistent GTEP→PCM request**

> "What is the status of holistic request `md-reference-2035-v1`?"
> "After reconnecting, locate the realized PCM inputs and handoff report for request `md-reference-2035-v1`."

**`hope_run_erec` — EREC reliability postprocessing**

> "Run EREC on the completed `md_gtep_clean` run to compute each resource's reliability contribution."
> "After the GTEP run finishes, quantify how much capacity credit each new solar and wind plant earns."

**`hope_job_status` — Poll a background job**

> "What's the status of job `a3f8c21b`?"
> "Is the HOPE run still going? Give me the latest output."
> "Check whether the warmup job has finished."

---

### Settings Management

**`hope_update_settings` — Patch model settings**

> "Enable the carbon cap in the `md_gtep_clean` case."
> "Switch the solver to HiGHS for the Maryland case."
> "Turn on unit commitment and nodal network modeling."
> "Set the carbon price to \$50/ton in `md_gtep_clean`."
> "Disable the RPS target and enable the clean energy standard instead."
> "Enable shadow price output and make sure the network model is set to nodal."

**`hope_validate_case` — Check for contradictions before running**

> "Validate the `md_gtep_clean` case settings before I run it."
> "Check whether there are any contradictions or missing files in this case."
> "Is this case configured correctly to produce nodal prices?"

---

### Output Reading

**`hope_case_info` — Inspect settings and output file inventory**

> "What settings is the `md_gtep_clean` case using?"
> "List all the output files from the last HOPE run."

**`hope_output_summary` — Summarize cost and capacity results**

> "Summarize the results from the `md_gtep_clean` run."
> "What are the total system costs, new capacity builds, and storage investments?"
> "Give me a high-level overview of the capacity expansion results."

**`hope_read_output` — Read any specific output CSV**

> "Show me the dispatch for solar PV in zone MD."
> "Read the `capacity.csv` output and filter for wind technologies."
> "What does the `transmission_flows.csv` file look like for the first 24 hours?"
> "Show me storage charge/discharge for the BESS resources in zone PJM."

**`hope_emission_compliance` — Check carbon and RPS compliance**

> "Are we in compliance with the carbon cap? How close are we to the limit?"
> "Summarize per-state carbon and RPS compliance from the latest run."
> "Did any state violate its RPS target? What are the penalty costs?"

**`hope_nodal_prices` — Read locational marginal prices**

> "What are the average nodal prices across all buses?"
> "Show me the LMPs for buses in zone MD for hours 1–48."
> "Which bus had the highest LMP during the peak demand period?"

---

### Scenario Comparison

**`hope_compare_cases` — Side-by-side scenario comparison**

> "Compare costs and emissions between the baseline and the carbon cap cases."
> "How does capacity investment change if I enable the RPS target? Run that version and compare."
> "Show me a side-by-side table of capacity builds, system cost, and CO2 across the three Maryland scenarios."
> "What's the cost difference between the nodal and zonal network models?"

---

### Audit Tools

**`hope_rep_day_audit` — Representative period summary**

> "Summarize the representative-day clustering for the `md_gtep_clean` case."
> "How many representative periods are used, and what's the compression ratio versus a full year?"
> "Which weeks are mapped to each representative day?"

**`hope_aggregation_audit` — Resource aggregation summary**

> "How many generator clusters were created from the raw resource data?"
> "Summarize the resource aggregation: how many generators were grouped into how many clusters?"
> "Show me the per-cluster capacity for the wind aggregation."

---

### Dashboard

**`hope_open_dashboard` / `hope_close_dashboard` — Local interactive dashboard**

> "Open the dashboard for the `md_gtep_clean` case."
> "Launch the GTEP dashboard so I can explore capacity builds interactively."
> "Close the dashboard when I'm done."
> "Stop all running dashboards."

---

## Troubleshooting

**MCP server does not appear in Claude Desktop**
Verify the config JSON is valid (no trailing commas, no syntax errors). Restart Claude Desktop fully (quit and reopen).

**`uv` command not found**
Restart your terminal after installing `uv`, or manually add `~/.local/bin` (macOS/Linux) or `%USERPROFILE%\.local\bin` (Windows) to your PATH.

**Julia warmup job keeps running for a long time**
This is expected on the very first call — Julia downloads and compiles ~130 packages. Subsequent warmups in the same session are instant since the cache is warm.

**`hope_warmup` fails with AppLocker / Application Control blocking a DLL**
Set `JULIA_DEPOT_PATH` in Claude Desktop's config to a directory that your Windows policy explicitly trusts, then restart Claude Desktop and run `hope_warmup` again. On managed Windows machines, moving the depot outside `C:\Users` can help, but it is not sufficient by itself: a path like `E:\julia_depot` may still be blocked unless your IT policy allows that location or whitelists the blocked Julia artifact DLL (for example `libmetis_*.dll`).

**`hope_run_hope` fails with `hope_environment_not_instantiated`**
Call `hope_warmup` first and wait for it to complete before calling `hope_run_hope`.

**`hope_run_erec` fails with `snapshot_not_found`**
Set `save_postprocess_snapshot: 1` in `HOPE_model_settings.yml` (use `hope_update_settings`) and re-run the case before calling `hope_run_erec`.

**`hope_nodal_prices` returns `price_file_not_found`**
LMP output requires `network_model > 0` and `write_shadow_prices: 1` in settings. Use `hope_update_settings` to enable both, then re-run.

**Job ID not found**
Job IDs for ordinary background jobs are in-memory and only valid for the current
MCP server session. GTEP→PCM runs additionally have a persistent `request_id`; use
`hope_holistic_status(request_id)` after a restart instead of starting a duplicate
run.

---

## Further Resources

- [PowerAgent community](https://poweragent.seas.harvard.edu/)
- [PowerMCP repository](https://github.com/Power-Agent/PowerMCP) — MCP servers for HOPE, PyPSA, OpenDSS, PowerWorld, and more
- [Model Context Protocol docs](https://modelcontextprotocol.io/introduction)
- [PowerMCP Tutorial PDF](https://raw.githubusercontent.com/Power-Agent/PowerMCP/main/PowerMCP_Tutorial.pdf)
