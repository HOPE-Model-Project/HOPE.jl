from __future__ import annotations

import os
import time
from collections.abc import Callable
from typing import Any

from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings

from .adaptive_protocol import (
    hope_adaptive_study_status,
    hope_evaluate_adaptive_study,
    hope_launch_adaptive_iteration,
    hope_prepare_adaptive_study,
    hope_record_adaptive_revision_decision,
    hope_request_adaptive_revision,
    hope_select_adaptive_realization,
    hope_start_adaptive_child_iteration,
    hope_wait_adaptive_study,
    traced_adaptive_call,
)
from .core import (
    hope_aggregation_audit,
    hope_audit_holistic_study,
    hope_cancel_job,
    hope_case_info,
    hope_close_dashboard,
    hope_compare_cases,
    hope_debug_solver_environment,
    hope_debug_solver_environment_async,
    hope_emission_compliance,
    hope_evaluate_holistic_agent_study,
    hope_holistic_status,
    hope_holistic_study_status,
    hope_wait_holistic_study,
    hope_job_status,
    hope_launch_holistic_study,
    hope_nodal_prices,
    hope_open_dashboard,
    hope_output_summary,
    hope_read_output,
    hope_rep_day_audit,
    hope_run_erec,
    hope_run_holistic,
    hope_prepare_holistic_study,
    hope_prepare_holistic_validation_study,
    hope_run_hope,
    hope_submit_holistic_agent_report,
    hope_update_settings,
    hope_validate_case,
    hope_warmup,
    record_holistic_agent_tool_event,
)

DEFAULT_HOST = "127.0.0.1"
DEFAULT_STDIO_PORT = 8000
DEFAULT_CHATGPT_PORT = 8001


def _traced_holistic_call(
    *,
    operation: str,
    role: str,
    agent_label: str | None,
    arguments: dict[str, Any],
    call: Callable[[], dict[str, Any]],
) -> dict[str, Any]:
    """Record lifecycle calls without hiding the underlying lifecycle result."""
    started_at = time.time()
    result = call()
    study_id = result.get("study_id") or arguments.get("study_id")
    if study_id:
        trace_result = record_holistic_agent_tool_event(
            study_id=str(study_id),
            operation=operation,
            role=role,
            agent_label=agent_label,
            arguments=arguments,
            result=result,
            started_at_unix=started_at,
        )
        if not trace_result.get("ok"):
            return {
                **result,
                "trace_recorded": False,
                "trace_warning": trace_result,
            }
        result["trace_recorded"] = True
    return result


def configured_host(default: str = DEFAULT_HOST) -> str:
    return os.environ.get("HOPE_MCP_HOST", default)


def configured_port(default: int) -> int:
    raw = os.environ.get("HOPE_MCP_PORT")
    if raw is None:
        return default
    try:
        return int(raw)
    except ValueError:
        return default


def configured_public_hostname() -> str | None:
    raw = os.environ.get("HOPE_MCP_PUBLIC_HOSTNAME")
    if raw is None:
        return None
    value = raw.strip()
    return value or None


def configured_transport_security(
    *,
    read_only: bool,
    host: str,
) -> TransportSecuritySettings | None:
    public_hostname = configured_public_hostname()
    if public_hostname:
        allowed_hosts = [
            public_hostname,
            f"{public_hostname}:443",
            "127.0.0.1:*",
            "localhost:*",
            "[::1]:*",
        ]
        allowed_origins = [
            f"https://{public_hostname}",
            "http://127.0.0.1:*",
            "http://localhost:*",
            "http://[::1]:*",
        ]
        return TransportSecuritySettings(
            enable_dns_rebinding_protection=True,
            allowed_hosts=allowed_hosts,
            allowed_origins=allowed_origins,
        )

    if read_only and host not in ("127.0.0.1", "localhost", "::1"):
        return TransportSecuritySettings(enable_dns_rebinding_protection=False)

    return None


def create_mcp_server(
    *,
    read_only: bool = False,
    host: str | None = None,
    port: int | None = None,
) -> FastMCP:
    effective_host = host or configured_host()
    effective_port = port if port is not None else configured_port(
        DEFAULT_CHATGPT_PORT if read_only else DEFAULT_STDIO_PORT
    )
    server_name = "hope-mcp-readonly" if read_only else "hope-mcp"
    instructions = (
        "Read-only HOPE MCP server for ChatGPT remote access. "
        "Use any case directory name that exists under ModelCases "
        "(for example USA_64zone_GTEP_case or ISONE_PCM_250bus_case). "
        "This server exposes only read/fetch analysis tools and does not allow "
        "running cases, editing settings, or launching dashboards."
        if read_only
        else "HOPE MCP server for the local Julia repository. "
        "Use any case directory name that exists under ModelCases "
        "(for example USA_64zone_GTEP_case or ISONE_PCM_250bus_case). "
        "The legacy alias md_gtep_clean also still works. "
        "Typical workflow: hope_warmup -> hope_job_status (poll) -> hope_run_hope -> "
        "hope_job_status (poll) -> hope_output_summary / hope_read_output. "
        "For the registered annual-GTEP/monthly-PCM validation profile, start with "
        "hope_prepare_holistic_validation_study. For other role-separated GTEP-to-PCM "
        "studies start with hope_prepare_holistic_study. Then use "
        "hope_launch_holistic_study -> hope_wait_holistic_study (repeat if timed out) -> "
        "hope_audit_holistic_study. "
        "For the adaptive Maryland thermal feedback test, use "
        "hope_prepare_adaptive_study -> hope_launch_adaptive_iteration -> "
        "hope_wait_adaptive_study, then follow the returned next_action. "
        "If a Julia run needs to be stopped early, call hope_cancel_job with its job_id."
    )
    mcp = FastMCP(
        server_name,
        instructions=instructions,
        host=effective_host,
        port=effective_port,
        transport_security=configured_transport_security(
            read_only=read_only,
            host=effective_host,
        ),
    )
    register_read_tools(mcp)
    if not read_only:
        register_write_tools(mcp)
    return mcp


def register_read_tools(mcp: FastMCP) -> None:
    @mcp.tool(
        name="hope_case_info",
        description=(
            "Return metadata and output inventory for a HOPE case: model mode, solver, "
            "boolean settings, and list of output CSV files. "
            "Pass any ModelCases directory name as case_id."
        ),
    )
    def hope_case_info_tool(case_id: str = "md_gtep_clean") -> dict[str, Any]:
        return hope_case_info(case_id)

    @mcp.tool(
        name="hope_output_summary",
        description=(
            "Summarize existing HOPE output CSVs for a case without running Julia. "
            "Returns total system cost, per-zone costs, new generation builds, and new storage builds."
        ),
    )
    def hope_output_summary_tool(case_id: str = "md_gtep_clean") -> dict[str, Any]:
        return hope_output_summary(case_id)

    @mcp.tool(
        name="hope_validate_case",
        description=(
            "Check a case's HOPE_model_settings.yml for contradictions and suspicious combinations "
            "(e.g., write_shadow_prices=1 without network_model > 0, or both endogenous and external "
            "rep-day enabled). Also checks that the solver settings file and DataCase folder exist. "
            "Returns a list of warnings and an is_valid flag."
        ),
    )
    def hope_validate_case_tool(case_id: str = "md_gtep_clean") -> dict[str, Any]:
        return hope_validate_case(case_id)

    @mcp.tool(
        name="hope_read_output",
        description=(
            "Read any CSV file from a case's output/ directory. "
            "Optionally filter rows by column values using the 'filters' dict "
            "(e.g., filters={'Zone': 'MD', 'Technology': 'SolarPV'}). "
            "Typical files: system_cost.csv, capacity.csv, es_capacity.csv, dispatch.csv, "
            "load_shed.csv, carbon_emissions.csv, rps_target.csv, nodal_prices.csv, "
            "storage_dispatch.csv, representative_period_metadata.csv, resource_aggregation_summary.csv. "
            "Use hope_case_info to list all available output files first."
        ),
    )
    def hope_read_output_tool(
        case_id: str = "md_gtep_clean",
        filename: str = "system_cost.csv",
        filters: dict[str, str] | None = None,
        max_rows: int = 200,
    ) -> dict[str, Any]:
        return hope_read_output(
            case_id=case_id,
            filename=filename,
            filters=filters,
            max_rows=max_rows,
        )

    @mcp.tool(
        name="hope_emission_compliance",
        description=(
            "Parse carbon emission and RPS (Renewable Portfolio Standard) compliance results "
            "from a completed HOPE run. Returns per-state compliance status, violation amounts, "
            "and penalty costs for both carbon cap and RPS policies. "
            "Requires carbon_policy > 0 or clean_energy_policy=1 to produce output files."
        ),
    )
    def hope_emission_compliance_tool(case_id: str = "md_gtep_clean") -> dict[str, Any]:
        return hope_emission_compliance(case_id)

    @mcp.tool(
        name="hope_nodal_prices",
        description=(
            "Read locational marginal prices (LMPs) from a completed nodal or zonal HOPE run. "
            "Filter by zone/bus name and/or hour range. "
            "Requires network_model > 0 and write_shadow_prices=1 in HOPE_model_settings.yml. "
            "Returns LMP values by bus/zone and hour."
        ),
    )
    def hope_nodal_prices_tool(
        case_id: str = "md_gtep_clean",
        zone_or_bus: str | None = None,
        hour_start: int | None = None,
        hour_end: int | None = None,
        max_rows: int = 500,
    ) -> dict[str, Any]:
        return hope_nodal_prices(
            case_id=case_id,
            zone_or_bus=zone_or_bus,
            hour_start=hour_start,
            hour_end=hour_end,
            max_rows=max_rows,
        )

    @mcp.tool(
        name="hope_compare_cases",
        description=(
            "Compare system cost, capacity builds (MW by technology), storage builds (MWh by technology), "
            "and total CO2 emissions across two or more HOPE cases. "
            "Returns side-by-side tables and cost/emissions diffs relative to the first (baseline) case. "
            "Example: hope_compare_cases(['MD_GTEP_clean_case', 'USA_64zone_GTEP_case'])."
        ),
    )
    def hope_compare_cases_tool(case_ids: list[str]) -> dict[str, Any]:
        return hope_compare_cases(case_ids)

    @mcp.tool(
        name="hope_rep_day_audit",
        description=(
            "Summarize representative-period clustering results from a completed HOPE run. "
            "Returns period assignments (day -> period), period weights, total representative hours, "
            "and the compression ratio compared to a full 8760-hour year. "
            "Only available when endogenous_rep_day=1 or external_rep_day=1."
        ),
    )
    def hope_rep_day_audit_tool(case_id: str = "md_gtep_clean") -> dict[str, Any]:
        return hope_rep_day_audit(case_id)

    @mcp.tool(
        name="hope_aggregation_audit",
        description=(
            "Summarize resource aggregation results from a completed HOPE run. "
            "Returns the raw->aggregated generator cluster mapping, reduction ratio "
            "(e.g., 120 generators -> 30 clusters = 4x reduction), and total capacity by cluster. "
            "Only available when resource_aggregation=1."
        ),
    )
    def hope_aggregation_audit_tool(case_id: str = "md_gtep_clean") -> dict[str, Any]:
        return hope_aggregation_audit(case_id)


def register_write_tools(mcp: FastMCP) -> None:
    @mcp.tool(
        name="hope_warmup",
        description=(
            "Pre-compile the HOPE Julia environment in the background so subsequent hope_run_hope calls "
            "start fast. Returns a job_id immediately. Call hope_job_status to check progress. "
            "Run this once per Claude Desktop session before the first hope_run_hope."
        ),
    )
    def hope_warmup_tool() -> dict[str, Any]:
        return hope_warmup()

    @mcp.tool(
        name="hope_job_status",
        description=(
            "Poll the status of a background Julia job launched by hope_warmup, hope_run_hope, "
            "hope_run_holistic, or hope_run_erec. "
            "Returns status ('running' or 'done'), elapsed time, stdout tail, and on success the "
            "output summary. Call repeatedly until status is 'done'."
        ),
    )
    def hope_job_status_tool(job_id: str) -> dict[str, Any]:
        return hope_job_status(job_id)

    @mcp.tool(
        name="hope_cancel_job",
        description=(
            "Cancel a background Julia job launched by hope_warmup, hope_run_hope, "
            "hope_run_holistic, or hope_run_erec. "
            "Pass the job_id returned by the launch tool. "
            "Returns status='cancelled' when the subprocess is terminated successfully."
        ),
    )
    def hope_cancel_job_tool(job_id: str) -> dict[str, Any]:
        return hope_cancel_job(job_id)

    @mcp.tool(
        name="hope_debug_solver_environment",
        description=(
            "Run a short Julia probe in the same MCP-server environment used for HOPE jobs. "
            "Returns the active project, depot path, loaded HOPE source path, and the exact "
            "optimizer constructor JuMP sees for the selected solver. "
            "Use this when Claude appears to be running stale code or the wrong Julia environment."
        ),
    )
    def hope_debug_solver_environment_tool(
        case_id: str = "md_gtep_clean",
        solver: str | None = None,
        timeout_seconds: float = 120.0,
    ) -> dict[str, Any]:
        return hope_debug_solver_environment(
            case_id=case_id,
            solver=solver,
            timeout_seconds=timeout_seconds,
        )

    @mcp.tool(
        name="hope_debug_solver_environment_async",
        description=(
            "Launch the HOPE Julia environment probe as a background job and return a job_id immediately. "
            "Use hope_job_status to inspect stdout, stderr, and parsed probe fields without Claude timing out."
        ),
    )
    def hope_debug_solver_environment_async_tool(
        case_id: str = "md_gtep_clean",
        solver: str | None = None,
    ) -> dict[str, Any]:
        return hope_debug_solver_environment_async(case_id=case_id, solver=solver)

    @mcp.tool(
        name="hope_run_hope",
        description=(
            "Launch a HOPE single-case run as a background job. Returns a job_id immediately. "
            "Poll with hope_job_status until done. Works for GTEP, PCM, and DART model modes. "
            "Pass any ModelCases directory name as case_id."
        ),
    )
    def hope_run_hope_tool(case_id: str = "md_gtep_clean") -> dict[str, Any]:
        return hope_run_hope(case_id)

    @mcp.tool(
        name="hope_update_settings",
        description=(
            "Patch fields in a case's HOPE_model_settings.yml. "
            "Pass a 'changes' dict mapping setting keys to new values "
            "(e.g., {'carbon_policy': 2, 'solver': 'highs', 'network_model': 1}). "
            "Validates values, backs up the original file, and returns applied/rejected changes plus warnings. "
            "Key options - model_mode: GTEP|PCM|DART; solver: cbc|clp|highs|scip|gurobi|cplex; "
            "carbon_policy: 0|1|2; network_model: 0|1|2|3; unit_commitment: 0|1|2; "
            "clean_energy_policy: 0|1|2; planning_reserve_mode: 0|1|2; and any binary (0/1) setting."
        ),
    )
    def hope_update_settings_tool(
        case_id: str = "md_gtep_clean",
        changes: dict[str, Any] | None = None,
        backup: bool = True,
    ) -> dict[str, Any]:
        return hope_update_settings(case_id=case_id, changes=changes, backup=backup)

    @mcp.tool(
        name="hope_run_holistic",
        description=(
            "Run the two-stage GTEP->PCM holistic workflow as a background job. "
            "Stage 1 solves capacity expansion (GTEP) to determine optimal new builds and retirements. "
            "Stage 2 fixes the resulting fleet and runs a full PCM (production cost model) "
            "to validate operational feasibility and compute hourly dispatch + LMPs. "
            "Creates an isolated workspace and persistent manifest. Returns a request_id and job_id; "
            "poll with hope_holistic_status. Reusing the same request_id is idempotent."
        ),
    )
    def hope_run_holistic_tool(
        gtep_case_id: str,
        pcm_case_id: str,
        request_id: str | None = None,
        solver: str | None = None,
    ) -> dict[str, Any]:
        return hope_run_holistic(
            gtep_case_id=gtep_case_id,
            pcm_case_id=pcm_case_id,
            request_id=request_id,
            solver=solver,
        )

    @mcp.tool(
        name="hope_holistic_status",
        description=(
            "Return the persistent status and artifact locations for a GTEP->PCM request. "
            "Unlike job IDs, request IDs remain queryable after an MCP reconnect."
        ),
    )
    def hope_holistic_status_tool(request_id: str) -> dict[str, Any]:
        return hope_holistic_status(request_id)

    @mcp.tool(
        name="hope_prepare_holistic_study",
        description=(
            "Coordinator step for a role-separated GTEP->PCM study. Validate the two source "
            "cases, pin immutable input fingerprints and solver selection, and publish a durable "
            "study manifest without launching a solver. Reusing the same study_id is idempotent."
        ),
    )
    def hope_prepare_holistic_study_tool(
        gtep_case_id: str,
        pcm_case_id: str,
        study_id: str | None = None,
        solver: str | None = None,
        agent_label: str | None = None,
    ) -> dict[str, Any]:
        return _traced_holistic_call(
            operation="hope_prepare_holistic_study",
            role="coordinator",
            agent_label=agent_label,
            arguments={
                "gtep_case_id": gtep_case_id,
                "pcm_case_id": pcm_case_id,
                "study_id": study_id,
                "solver": solver,
            },
            call=lambda: hope_prepare_holistic_study(
                gtep_case_id=gtep_case_id,
                pcm_case_id=pcm_case_id,
                study_id=study_id,
                solver=solver,
                agent_label=agent_label,
            ),
        )

    @mcp.tool(
        name="hope_prepare_holistic_validation_study",
        description=(
            "Coordinator step for a registered bounded-memory validation profile. The Maryland "
            "profile keeps the published 8,760-hour GTEP case, creates an isolated PCM calendar "
            "month with preceding chronological warm-up hours, verifies temporal metadata and "
            "source immutability, and publishes a durable study manifest without solving."
        ),
    )
    def hope_prepare_holistic_validation_study_tool(
        study_id: str | None = None,
        profile: str = "md-rps20-annual-gtep-monthly-pcm",
        evaluation_month: int = 7,
        warmup_hours: int = 48,
        solver: str | None = "gurobi",
        agent_label: str | None = None,
    ) -> dict[str, Any]:
        return _traced_holistic_call(
            operation="hope_prepare_holistic_validation_study",
            role="coordinator",
            agent_label=agent_label,
            arguments={
                "study_id": study_id,
                "profile": profile,
                "evaluation_month": evaluation_month,
                "warmup_hours": warmup_hours,
                "solver": solver,
            },
            call=lambda: hope_prepare_holistic_validation_study(
                study_id=study_id,
                profile=profile,
                evaluation_month=evaluation_month,
                warmup_hours=warmup_hours,
                solver=solver,
                agent_label=agent_label,
            ),
        )

    @mcp.tool(
        name="hope_launch_holistic_study",
        description=(
            "Executor step for a prepared holistic study. Recheck the pinned source fingerprints "
            "and launch the existing deterministic, isolated GTEP->PCM workflow. Pass only the "
            "study_id; model data remain in durable artifacts."
        ),
    )
    def hope_launch_holistic_study_tool(
        study_id: str,
        agent_label: str | None = None,
    ) -> dict[str, Any]:
        return _traced_holistic_call(
            operation="hope_launch_holistic_study",
            role="executor",
            agent_label=agent_label,
            arguments={"study_id": study_id},
            call=lambda: hope_launch_holistic_study(
                study_id=study_id,
                agent_label=agent_label,
            ),
        )

    @mcp.tool(
        name="hope_holistic_study_status",
        description=(
            "Return reconnect-safe status, role receipts, and the next allowed action for a "
            "prepared or running holistic study."
        ),
    )
    def hope_holistic_study_status_tool(study_id: str) -> dict[str, Any]:
        return _traced_holistic_call(
            operation="hope_holistic_study_status",
            role="observer",
            agent_label=None,
            arguments={"study_id": study_id},
            call=lambda: hope_holistic_study_status(study_id),
        )

    @mcp.tool(
        name="hope_wait_holistic_study",
        description=(
            "Wait for up to 55 seconds for a holistic study to reach READY_FOR_AUDIT or "
            "another terminal state. If the bounded wait times out, call this tool again; "
            "it does not modify model inputs or launch another run."
        ),
    )
    def hope_wait_holistic_study_tool(
        study_id: str,
        timeout_seconds: float = 45.0,
        poll_interval_seconds: float = 5.0,
    ) -> dict[str, Any]:
        return _traced_holistic_call(
            operation="hope_wait_holistic_study",
            role="observer",
            agent_label=None,
            arguments={
                "study_id": study_id,
                "timeout_seconds": timeout_seconds,
                "poll_interval_seconds": poll_interval_seconds,
            },
            call=lambda: hope_wait_holistic_study(
                study_id,
                timeout_seconds=timeout_seconds,
                poll_interval_seconds=poll_interval_seconds,
            ),
        )

    @mcp.tool(
        name="hope_audit_holistic_study",
        description=(
            "Independent validation step for a completed holistic study. Verify the published run "
            "manifest, pinned source hashes, scoped artifact paths, handoff and transfer reports, "
            "and all acceptance checks before issuing an ACCEPTED or REJECTED audit receipt."
        ),
    )
    def hope_audit_holistic_study_tool(
        study_id: str,
        agent_label: str | None = None,
    ) -> dict[str, Any]:
        return _traced_holistic_call(
            operation="hope_audit_holistic_study",
            role="auditor",
            agent_label=agent_label,
            arguments={"study_id": study_id},
            call=lambda: hope_audit_holistic_study(
                study_id=study_id,
                agent_label=agent_label,
            ),
        )

    @mcp.tool(
        name="hope_submit_holistic_agent_report",
        description=(
            "Submit the agent's final claims and evidence for a completed holistic study. "
            "Evidence files must exist inside the durable study or run workspace. The report "
            "is not authoritative; hope_evaluate_holistic_agent_study checks it independently."
        ),
    )
    def hope_submit_holistic_agent_report_tool(
        study_id: str,
        claims: dict[str, bool],
        evidence_paths: list[str],
        task_id: str = "md-rps20-annual-gtep-july-pcm-v1",
        architecture: str = "centralized_roles",
        agent_label: str | None = None,
        approvals: list[dict[str, Any]] | None = None,
        monitoring_mode: str | None = None,
    ) -> dict[str, Any]:
        return hope_submit_holistic_agent_report(
            study_id=study_id,
            task_id=task_id,
            architecture=architecture,
            monitoring_mode=monitoring_mode,
            agent_label=agent_label,
            claims=claims,
            evidence_paths=evidence_paths,
            approvals=approvals,
        )

    @mcp.tool(
        name="hope_evaluate_holistic_agent_study",
        description=(
            "Independently score a holistic agent run from the server trace, final report, "
            "published model artifacts, and deterministic audit. Reports model correctness and "
            "agent-behavior correctness separately."
        ),
    )
    def hope_evaluate_holistic_agent_study_tool(
        study_id: str,
        task_id: str | None = None,
    ) -> dict[str, Any]:
        return hope_evaluate_holistic_agent_study(study_id=study_id, task_id=task_id)

    @mcp.tool(
        name="hope_prepare_adaptive_study",
        description=(
            "Create an immutable adaptive Maryland thermal study from the registered contract. "
            "This pins the iteration budget, acceptance policy, fixed assumptions, and solver "
            "choices without running a model. Reusing a study_id is idempotent."
        ),
    )
    def hope_prepare_adaptive_study_tool(
        study_id: str | None = None,
        planning_solver: str = "highs",
        pcm_solver: str = "gurobi",
        agent_label: str | None = None,
    ) -> dict[str, Any]:
        return traced_adaptive_call(
            operation="hope_prepare_adaptive_study",
            role="coordinator",
            agent_label=agent_label,
            arguments={
                "study_id": study_id,
                "planning_solver": planning_solver,
                "pcm_solver": pcm_solver,
            },
            call=lambda: hope_prepare_adaptive_study(
                study_id=study_id,
                planning_solver=planning_solver,
                pcm_solver=pcm_solver,
                agent_label=agent_label,
            ),
        )

    @mcp.tool(
        name="hope_launch_adaptive_iteration",
        description=(
            "Launch exactly one allowed GTEP-realization-PCM iteration from SPECIFIED. "
            "Iteration 1 uses the registered base case; iteration 2 is available only after "
            "the typed PEPCO siting revision has a recorded human approval."
        ),
    )
    def hope_launch_adaptive_iteration_tool(
        study_id: str,
        agent_label: str | None = None,
    ) -> dict[str, Any]:
        return traced_adaptive_call(
            operation="hope_launch_adaptive_iteration",
            role="executor",
            agent_label=agent_label,
            arguments={"study_id": study_id},
            call=lambda: hope_launch_adaptive_iteration(
                study_id,
                agent_label=agent_label,
            ),
        )

    @mcp.tool(
        name="hope_adaptive_study_status",
        description=(
            "Return reconnect-safe adaptive state, current verification, revision or selection, "
            "background-run status, and the single next allowed action."
        ),
    )
    def hope_adaptive_study_status_tool(study_id: str) -> dict[str, Any]:
        return traced_adaptive_call(
            operation="hope_adaptive_study_status",
            role="observer",
            agent_label=None,
            arguments={"study_id": study_id},
            call=lambda: hope_adaptive_study_status(study_id),
        )

    @mcp.tool(
        name="hope_wait_adaptive_study",
        description=(
            "Wait at most 55 seconds for the current adaptive iteration. A timeout is normal; "
            "call this tool again. It never launches, retries, or changes model assumptions."
        ),
    )
    def hope_wait_adaptive_study_tool(
        study_id: str,
        timeout_seconds: float = 45.0,
        poll_interval_seconds: float = 5.0,
    ) -> dict[str, Any]:
        return traced_adaptive_call(
            operation="hope_wait_adaptive_study",
            role="observer",
            agent_label=None,
            arguments={
                "study_id": study_id,
                "timeout_seconds": timeout_seconds,
                "poll_interval_seconds": poll_interval_seconds,
            },
            call=lambda: hope_wait_adaptive_study(
                study_id,
                timeout_seconds=timeout_seconds,
                poll_interval_seconds=poll_interval_seconds,
            ),
        )

    @mcp.tool(
        name="hope_request_adaptive_revision",
        description=(
            "Propose one typed revision after a failed verified ensemble. State the observed "
            "finding, exact changed fields, and controls intentionally held fixed. Protected "
            "acceptance criteria and iteration budgets cannot be changed."
        ),
    )
    def hope_request_adaptive_revision_tool(
        study_id: str,
        revision_type: str,
        finding: str,
        changes: dict[str, Any],
        unchanged_controls: list[str],
        agent_label: str | None = None,
    ) -> dict[str, Any]:
        return traced_adaptive_call(
            operation="hope_request_adaptive_revision",
            role="diagnostic-agent",
            agent_label=agent_label,
            arguments={
                "study_id": study_id,
                "revision_type": revision_type,
                "finding": finding,
                "changes": changes,
                "unchanged_controls": unchanged_controls,
            },
            call=lambda: hope_request_adaptive_revision(
                study_id,
                revision_type,
                finding=finding,
                changes=changes,
                unchanged_controls=unchanged_controls,
                agent_label=agent_label,
            ),
        )

    @mcp.tool(
        name="hope_record_adaptive_revision_decision",
        description=(
            "Human approval boundary for a pending adaptive revision. Record approved or rejected, "
            "the human approver identity, and rationale. This does not start a child iteration."
        ),
    )
    def hope_record_adaptive_revision_decision_tool(
        study_id: str,
        decision: str,
        approver: str,
        rationale: str,
    ) -> dict[str, Any]:
        return traced_adaptive_call(
            operation="hope_record_adaptive_revision_decision",
            role="human-approver",
            agent_label=approver,
            arguments={
                "study_id": study_id,
                "decision": decision,
                "approver": approver,
                "rationale": rationale,
            },
            call=lambda: hope_record_adaptive_revision_decision(
                study_id,
                decision,
                approver=approver,
                rationale=rationale,
            ),
        )

    @mcp.tool(
        name="hope_start_adaptive_child_iteration",
        description=(
            "Create the next immutable attempt only after its revision is approved. Enforces the "
            "iteration budget and rejects repeated revision cycles."
        ),
    )
    def hope_start_adaptive_child_iteration_tool(study_id: str) -> dict[str, Any]:
        return traced_adaptive_call(
            operation="hope_start_adaptive_child_iteration",
            role="coordinator",
            agent_label=None,
            arguments={"study_id": study_id},
            call=lambda: hope_start_adaptive_child_iteration(study_id),
        )

    @mcp.tool(
        name="hope_select_adaptive_realization",
        description=(
            "Select and freeze one realization only after independent ensemble verification. "
            "The named variant must be in accepted_variants; failed or review-required variants "
            "cannot be selected."
        ),
    )
    def hope_select_adaptive_realization_tool(
        study_id: str,
        variant: str,
        rationale: str,
        evidence: dict[str, Any] | None = None,
        agent_label: str | None = None,
    ) -> dict[str, Any]:
        return traced_adaptive_call(
            operation="hope_select_adaptive_realization",
            role="selection-agent",
            agent_label=agent_label,
            arguments={
                "study_id": study_id,
                "variant": variant,
                "rationale": rationale,
                "evidence": evidence or {},
            },
            call=lambda: hope_select_adaptive_realization(
                study_id,
                variant,
                rationale=rationale,
                evidence=evidence,
                agent_label=agent_label,
            ),
        )

    @mcp.tool(
        name="hope_evaluate_adaptive_study",
        description=(
            "Independently score the terminal adaptive run. model_passed verifies the two solved "
            "iterations and selected zero-shedding realization; agent_passed verifies the "
            "hash-chained call sequence, human approval boundary, budgets, and typed revision."
        ),
    )
    def hope_evaluate_adaptive_study_tool(study_id: str) -> dict[str, Any]:
        return hope_evaluate_adaptive_study(study_id)

    @mcp.tool(
        name="hope_run_erec",
        description=(
            "Run EREC (Equivalent Reliability Enhancement Capability) postprocessing on a completed HOPE run. "
            "EREC computes how much unserved energy each generation or storage resource avoids, "
            "quantifying each resource's reliability contribution. "
            "Requires save_postprocess_snapshot >= 1 in HOPE_model_settings.yml and a completed run. "
            "Optionally override voll_override ($/MWh Value of Lost Load) and delta_mw (marginal capacity step). "
            "Returns a job_id immediately. Poll with hope_job_status."
        ),
    )
    def hope_run_erec_tool(
        case_id: str = "md_gtep_clean",
        voll_override: float | None = None,
        delta_mw: float | None = None,
    ) -> dict[str, Any]:
        return hope_run_erec(
            case_id=case_id,
            voll_override=voll_override,
            delta_mw=delta_mw,
        )

    @mcp.tool(
        name="hope_open_dashboard",
        description=(
            "Launch the local HOPE Dash dashboard for a completed case run and return its URL. "
            "Automatically picks the GTEP dashboard (port 8051) for GTEP cases and the PCM dashboard "
            "(port 8050) for PCM cases. DART has no dashboard yet and returns an explicit unsupported-mode error. "
            "If a dashboard is already running on the target port, returns the existing URL immediately. "
            "After the browser URL opens, select the matching case from the dropdown in the UI. "
            "Requires Python with dash, plotly, pandas installed "
            "(set HOPE_PYTHON_BIN env var to point to that Python if needed). "
            "Optional 'port' overrides the default port."
        ),
    )
    def hope_open_dashboard_tool(
        case_id: str = "md_gtep_clean",
        port: int | None = None,
    ) -> dict[str, Any]:
        return hope_open_dashboard(case_id=case_id, port=port)

    @mcp.tool(
        name="hope_close_dashboard",
        description=(
            "Stop a running HOPE dashboard that was launched by hope_open_dashboard. "
            "If 'port' is given (8050 for PCM, 8051 for GTEP), stop only that dashboard. "
            "If omitted, stop all dashboards tracked by this session. "
            "Returns a list of stopped processes with their ports and exit codes. "
            "Only dashboards started in the current Claude Desktop session can be stopped this way."
        ),
    )
    def hope_close_dashboard_tool(port: int | None = None) -> dict[str, Any]:
        return hope_close_dashboard(port=port)


def main() -> None:
    create_mcp_server(read_only=False).run("stdio")


if __name__ == "__main__":
    main()
