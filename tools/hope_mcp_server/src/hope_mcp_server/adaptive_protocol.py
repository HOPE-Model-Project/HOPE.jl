from __future__ import annotations

import hashlib
import os
import subprocess
import tempfile
import threading
import time
from pathlib import Path
from typing import Any, Callable

import yaml

from . import agent_evaluation
from .core import (
    _jobs,
    _launch_job,
    _normalize_agent_label,
    _process_is_alive,
    _write_yaml_atomic,
    error_result,
    get_repo_root,
    hope_job_status,
    normalize_holistic_request_id,
    read_yaml,
    success_result,
    validate_julia_command,
)

ADAPTIVE_TASK_ID = "md-compact-energy-thermal-adaptive-v1"
ADAPTIVE_SPEC_RELATIVE_PATH = (
    Path("configs")
    / "adaptive_studies"
    / "md_compact_energy_thermal_feedback_loop_v1.yml"
)
ADAPTIVE_CLI_RELATIVE_PATH = Path("tools") / "repo_utils" / "adaptive_study_cli.jl"
ADAPTIVE_WORKER_RELATIVE_PATH = (
    Path("tools") / "repo_utils" / "run_adaptive_thermal_iteration.jl"
)
_adaptive_lock = threading.Lock()


def adaptive_studies_root(repo_root: Path) -> Path:
    configured = os.environ.get("HOPE_ADAPTIVE_STUDIES_ROOT")
    if configured:
        return Path(configured).expanduser().resolve()
    return (repo_root / "artifacts" / "adaptive_agent_studies").resolve()


def _workspace(study_id: str) -> Path:
    return adaptive_studies_root(get_repo_root()) / study_id


def _state_path(study_id: str) -> Path:
    return _workspace(study_id) / "adaptive_study_state.yml"


def _protocol_path(study_id: str) -> Path:
    return _workspace(study_id) / "protocol.yml"


def _normalize_study_id(study_id: str | None) -> tuple[str | None, dict[str, Any] | None]:
    return normalize_holistic_request_id(study_id)


def _read_state(study_id: str) -> tuple[dict[str, Any] | None, dict[str, Any] | None]:
    path = _state_path(study_id)
    if not path.is_file():
        return None, error_result(
            "adaptive_study_not_found",
            f"No adaptive study found with study_id '{study_id}'.",
            study_id=study_id,
        )
    try:
        state = read_yaml(path)
        manifest = read_yaml(path.parent / "manifest.yml")
    except (OSError, ValueError, yaml.YAMLError) as exc:
        return None, error_result(
            "invalid_adaptive_study",
            str(exc),
            study_id=study_id,
        )
    actual_hash = hashlib.sha256(path.read_bytes()).hexdigest()
    if manifest.get("state_sha256") != actual_hash:
        return None, error_result(
            "adaptive_state_hash_mismatch",
            "The adaptive state does not match its published manifest.",
            study_id=study_id,
        )
    if state.get("study_id") != study_id:
        return None, error_result(
            "adaptive_study_id_mismatch",
            "The adaptive state study_id does not match its workspace.",
            study_id=study_id,
        )
    return state, None


def _read_protocol(study_id: str) -> dict[str, Any]:
    path = _protocol_path(study_id)
    return read_yaml(path) if path.is_file() else {}


def _write_protocol(study_id: str, protocol: dict[str, Any]) -> None:
    protocol["updated_at_unix"] = time.time()
    _write_yaml_atomic(_protocol_path(study_id), protocol)


def _julia_command(script: Path, *args: str) -> tuple[list[str] | None, dict[str, Any] | None]:
    repo_root = get_repo_root()
    julia, error = validate_julia_command(repo_root)
    if error is not None:
        return None, error
    assert julia is not None
    if not script.is_file():
        return None, error_result(
            "adaptive_runner_unavailable",
            f"Adaptive Julia entrypoint not found: {script}",
        )
    return [
        julia,
        "--startup-file=no",
        f"--project={repo_root}",
        str(script),
        *args,
    ], None


def _run_cli(
    command_name: str,
    study_id: str,
    payload: dict[str, Any] | None = None,
) -> dict[str, Any]:
    repo_root = get_repo_root()
    workspace = _workspace(study_id)
    cli = repo_root / ADAPTIVE_CLI_RELATIVE_PATH
    payload_path: Path | None = None
    arguments = [command_name, str(workspace)]
    try:
        if payload is not None:
            workspace.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.NamedTemporaryFile(
                mode="w",
                encoding="utf-8",
                suffix=".yml",
                prefix=f".{study_id}-{command_name}-",
                dir=workspace.parent,
                delete=False,
            ) as handle:
                yaml.safe_dump(payload, handle, sort_keys=False)
                payload_path = Path(handle.name)
            arguments.append(str(payload_path))
        command, error = _julia_command(cli, *arguments)
        if error is not None:
            return error
        assert command is not None
        completed = subprocess.run(
            command,
            cwd=repo_root,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=120,
            check=False,
        )
        if completed.returncode != 0:
            return error_result(
                "adaptive_transition_failed",
                completed.stderr.strip() or "The adaptive state transition failed.",
                study_id=study_id,
                command_name=command_name,
                stdout=completed.stdout.strip(),
            )
        return success_result(stdout=completed.stdout.strip())
    except subprocess.TimeoutExpired:
        return error_result(
            "adaptive_transition_timeout",
            "The adaptive state transition exceeded 120 seconds.",
            study_id=study_id,
            command_name=command_name,
        )
    finally:
        if payload_path is not None:
            try:
                payload_path.unlink()
            except OSError:
                pass


def _adaptive_response(
    study_id: str,
    state: dict[str, Any],
    protocol: dict[str, Any],
    *,
    reused: bool = False,
) -> dict[str, Any]:
    stage = str(state.get("stage", "UNKNOWN")).upper()
    terminal = str(state.get("terminal_status", "UNKNOWN")).upper()
    running = str(protocol.get("run_status", "")).upper() == "RUNNING"
    if running:
        next_action = "Call hope_wait_adaptive_study; do not launch another iteration."
    elif terminal != "ACTIVE":
        next_action = "The adaptive study is terminal; inspect its immutable state and evidence."
    else:
        next_action = {
            "SPECIFIED": "Call hope_launch_adaptive_iteration.",
            "VERIFIED": (
                "Select an accepted realization, or request one typed revision if none passed."
            ),
            "REVISION_REQUESTED": "A human must call hope_record_adaptive_revision_decision.",
            "REVISION_APPROVED": "Call hope_start_adaptive_child_iteration.",
        }.get(stage, "Inspect the adaptive state before proceeding.")
    attempt = state.get("attempts", [{}])[-1]
    return success_result(
        study_id=study_id,
        task_id=protocol.get("task_id", ADAPTIVE_TASK_ID),
        stage=stage.lower(),
        terminal_status=terminal.lower(),
        iteration=state.get("iteration"),
        verification=attempt.get("verification"),
        revision=attempt.get("revision"),
        selection=attempt.get("selection"),
        run_status=str(protocol.get("run_status", "IDLE")).lower(),
        job_id=protocol.get("job_id"),
        process_pid=protocol.get("process_pid"),
        workspace_path=str(_workspace(study_id)),
        state_path=str(_state_path(study_id)),
        reused=reused,
        next_action=next_action,
    )


def hope_prepare_adaptive_study(
    study_id: str | None = None,
    *,
    planning_solver: str = "highs",
    pcm_solver: str = "gurobi",
    agent_label: str | None = None,
) -> dict[str, Any]:
    normalized, error = _normalize_study_id(study_id)
    if error is not None:
        return error
    assert normalized is not None
    coordinator, error = _normalize_agent_label(agent_label, "adaptive-coordinator")
    if error is not None:
        return error
    planning = str(planning_solver).strip().lower()
    pcm = str(pcm_solver).strip().lower()
    if planning not in {"highs", "gurobi"} or pcm not in {"highs", "gurobi"}:
        return error_result(
            "invalid_solver",
            "planning_solver and pcm_solver must be 'highs' or 'gurobi'.",
        )
    repo_root = get_repo_root()
    template_path = repo_root / ADAPTIVE_SPEC_RELATIVE_PATH
    if not template_path.is_file():
        return error_result(
            "adaptive_spec_unavailable",
            f"Adaptive study template not found: {template_path}",
        )
    with _adaptive_lock:
        existing, existing_error = _read_state(normalized)
        if existing is not None:
            protocol = _read_protocol(normalized)
            requested = (planning, pcm)
            configured = (
                str(protocol.get("planning_solver", "")),
                str(protocol.get("pcm_solver", "")),
            )
            if requested != configured:
                return error_result(
                    "study_id_conflict",
                    "study_id already uses different solver settings.",
                    study_id=normalized,
                )
            return _adaptive_response(normalized, existing, protocol, reused=True)
        if existing_error and existing_error.get("error_type") != "adaptive_study_not_found":
            return existing_error
        try:
            spec = read_yaml(template_path)
        except (OSError, ValueError, yaml.YAMLError) as exc:
            return error_result("invalid_adaptive_spec", str(exc))
        spec["study_id"] = normalized
        workspace_parent = _workspace(normalized).parent
        workspace_parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            suffix=".yml",
            prefix=f".{normalized}-spec-",
            dir=workspace_parent,
            delete=False,
        ) as handle:
            yaml.safe_dump(spec, handle, sort_keys=False)
            generated_spec = Path(handle.name)
        try:
            command, command_error = _julia_command(
                repo_root / ADAPTIVE_CLI_RELATIVE_PATH,
                "initialize",
                str(_workspace(normalized)),
                str(generated_spec),
            )
            if command_error is not None:
                return command_error
            assert command is not None
            completed = subprocess.run(
                command,
                cwd=repo_root,
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=120,
                check=False,
            )
            if completed.returncode != 0:
                return error_result(
                    "adaptive_prepare_failed",
                    completed.stderr.strip() or "Adaptive preparation failed.",
                    study_id=normalized,
                )
        finally:
            try:
                generated_spec.unlink()
            except OSError:
                pass
        state, error = _read_state(normalized)
        if error is not None:
            return error
        assert state is not None
        now = time.time()
        protocol = {
            "artifact_type": "HOPE.adaptive_agent_protocol",
            "schema_version": 1,
            "study_id": normalized,
            "task_id": ADAPTIVE_TASK_ID,
            "planning_solver": planning,
            "pcm_solver": pcm,
            "run_status": "IDLE",
            "created_at_unix": now,
            "updated_at_unix": now,
            "receipts": {
                "coordinator": {
                    "agent_label": coordinator,
                    "completed_at_unix": now,
                }
            },
        }
        _write_protocol(normalized, protocol)
    return _adaptive_response(normalized, state, protocol)


def _refresh_adaptive_run(study_id: str, protocol: dict[str, Any]) -> dict[str, Any]:
    if str(protocol.get("run_status", "")).upper() != "RUNNING":
        return protocol
    job_id = str(protocol.get("job_id", ""))
    if job_id in _jobs:
        job = hope_job_status(job_id)
        if job.get("status") == "running":
            return protocol
        protocol["run_status"] = "PUBLISHED" if job.get("status") == "completed" else "FAILED"
        protocol["last_job"] = job
        _write_protocol(study_id, protocol)
        return protocol
    if _process_is_alive(protocol.get("process_pid")):
        return protocol
    iteration = int(protocol.get("running_iteration", 0) or 0)
    iteration_manifest = _workspace(study_id) / "iterations" / f"{iteration:02d}" / "manifest.yml"
    try:
        durable = read_yaml(iteration_manifest) if iteration_manifest.is_file() else {}
    except (OSError, ValueError, yaml.YAMLError):
        durable = {}
    protocol["run_status"] = (
        "PUBLISHED" if str(durable.get("status", "")).upper() == "PUBLISHED" else "FAILED"
    )
    protocol["iteration_manifest_path"] = str(iteration_manifest)
    _write_protocol(study_id, protocol)
    return protocol


def hope_adaptive_study_status(study_id: str) -> dict[str, Any]:
    normalized, error = _normalize_study_id(study_id)
    if error is not None:
        return error
    assert normalized is not None
    state, error = _read_state(normalized)
    if error is not None:
        return error
    assert state is not None
    with _adaptive_lock:
        protocol_before = _read_protocol(normalized)
        was_running = str(protocol_before.get("run_status", "")).upper() == "RUNNING"
        protocol = _refresh_adaptive_run(normalized, protocol_before)
    if was_running and str(protocol.get("run_status", "")).upper() != "RUNNING":
        refreshed, refresh_error = _read_state(normalized)
        if refresh_error is not None:
            return refresh_error
        assert refreshed is not None
        state = refreshed
    return _adaptive_response(normalized, state, protocol)


def hope_launch_adaptive_iteration(
    study_id: str,
    *,
    agent_label: str | None = None,
) -> dict[str, Any]:
    executor, error = _normalize_agent_label(agent_label, "adaptive-executor")
    if error is not None:
        return error
    status = hope_adaptive_study_status(study_id)
    if not status.get("ok"):
        return status
    if status.get("run_status") == "running":
        status["reused"] = True
        return status
    if status.get("terminal_status") != "active" or status.get("stage") != "specified":
        return error_result(
            "adaptive_iteration_not_launchable",
            "An adaptive iteration can launch only from an active SPECIFIED state.",
            study_id=study_id,
            stage=status.get("stage"),
            terminal_status=status.get("terminal_status"),
        )
    protocol = _read_protocol(study_id)
    repo_root = get_repo_root()
    command, error = _julia_command(
        repo_root / ADAPTIVE_WORKER_RELATIVE_PATH,
        str(_workspace(study_id)),
        str(protocol["planning_solver"]),
        str(protocol["pcm_solver"]),
    )
    if error is not None:
        return error
    assert command is not None
    with _adaptive_lock:
        current_protocol = _refresh_adaptive_run(study_id, _read_protocol(study_id))
        if str(current_protocol.get("run_status", "")).upper() == "RUNNING":
            current_state, state_error = _read_state(study_id)
            if state_error is not None:
                return state_error
            assert current_state is not None
            return _adaptive_response(study_id, current_state, current_protocol, reused=True)
        current_state, state_error = _read_state(study_id)
        if state_error is not None:
            return state_error
        assert current_state is not None
        if (
            current_state.get("terminal_status") != "ACTIVE"
            or current_state.get("stage") != "SPECIFIED"
        ):
            return error_result(
                "adaptive_iteration_not_launchable",
                "Adaptive state changed before launch; inspect status before proceeding.",
                study_id=study_id,
                stage=current_state.get("stage"),
                terminal_status=current_state.get("terminal_status"),
            )
        protocol = current_protocol
        job_id = _launch_job(
            command,
            repo_root,
            case_id=study_id,
            job_kind="adaptive_iteration",
            request_id=study_id,
            workspace_path=str(_workspace(study_id)),
        )
        job = _jobs[job_id]
        now = time.time()
        receipts = dict(protocol.get("receipts", {}))
        receipts[f"executor_iteration_{status['iteration']}"] = {
            "agent_label": executor,
            "started_at_unix": now,
            "job_id": job_id,
        }
        protocol.update(
            run_status="RUNNING",
            running_iteration=status["iteration"],
            job_id=job_id,
            process_pid=job.process.pid,
            receipts=receipts,
        )
        _write_protocol(study_id, protocol)
    state, error = _read_state(study_id)
    if error is not None:
        return error
    assert state is not None
    return _adaptive_response(study_id, state, protocol)


def hope_wait_adaptive_study(
    study_id: str,
    *,
    timeout_seconds: float = 45.0,
    poll_interval_seconds: float = 5.0,
) -> dict[str, Any]:
    timeout = max(0.0, min(float(timeout_seconds), 55.0))
    interval = max(0.1, min(float(poll_interval_seconds), 10.0))
    deadline = time.monotonic() + timeout
    while True:
        result = hope_adaptive_study_status(study_id)
        if not result.get("ok") or result.get("run_status") != "running":
            return result
        if time.monotonic() >= deadline:
            result["timed_out"] = True
            return result
        time.sleep(min(interval, max(0.0, deadline - time.monotonic())))


def _transition(
    study_id: str,
    command_name: str,
    payload: dict[str, Any] | None = None,
) -> dict[str, Any]:
    status = hope_adaptive_study_status(study_id)
    if not status.get("ok"):
        return status
    if status.get("run_status") == "running":
        return error_result(
            "adaptive_iteration_running",
            "Wait for the running iteration before changing adaptive state.",
            study_id=study_id,
        )
    with _adaptive_lock:
        result = _run_cli(command_name, study_id, payload)
    if not result.get("ok"):
        return result
    return hope_adaptive_study_status(study_id)


def hope_request_adaptive_revision(
    study_id: str,
    revision_type: str,
    *,
    finding: str,
    changes: dict[str, Any],
    unchanged_controls: list[str],
    agent_label: str | None = None,
) -> dict[str, Any]:
    _, error = _normalize_agent_label(agent_label, "adaptive-diagnostic-agent")
    if error is not None:
        return error
    return _transition(
        study_id,
        "request-revision",
        {
            "revision_type": revision_type,
            "request": {
                "finding": finding,
                "changes": changes,
                "unchanged_controls": unchanged_controls,
            },
        },
    )


def hope_record_adaptive_revision_decision(
    study_id: str,
    decision: str,
    *,
    approver: str,
    rationale: str,
) -> dict[str, Any]:
    return _transition(
        study_id,
        "record-decision",
        {"decision": decision, "approver": approver, "rationale": rationale},
    )


def hope_start_adaptive_child_iteration(study_id: str) -> dict[str, Any]:
    return _transition(study_id, "start-child")


def hope_select_adaptive_realization(
    study_id: str,
    variant: str,
    *,
    rationale: str,
    evidence: dict[str, Any] | None = None,
    agent_label: str | None = None,
) -> dict[str, Any]:
    _, error = _normalize_agent_label(agent_label, "adaptive-selection-agent")
    if error is not None:
        return error
    return _transition(
        study_id,
        "select",
        {"variant": variant, "rationale": rationale, "evidence": evidence or {}},
    )


def record_adaptive_agent_tool_event(
    *,
    study_id: str,
    operation: str,
    role: str,
    agent_label: str | None,
    arguments: dict[str, Any],
    result: dict[str, Any],
    started_at_unix: float,
) -> dict[str, Any]:
    state, error = _read_state(study_id)
    if error is not None:
        return error
    assert state is not None
    try:
        return agent_evaluation.append_tool_event(
            _workspace(study_id),
            study_id=study_id,
            operation=operation,
            role=role,
            agent_label=agent_label,
            arguments=arguments,
            result=result,
            started_at_unix=started_at_unix,
        )
    except (OSError, ValueError, yaml.YAMLError) as exc:
        return error_result("agent_trace_write_failed", str(exc), study_id=study_id)


def _ordered_subsequence(operations: list[str], required: list[str]) -> bool:
    cursor = 0
    for operation in operations:
        if cursor < len(required) and operation == required[cursor]:
            cursor += 1
    return cursor == len(required)


def _adaptive_variant_finding(attempt: dict[str, Any], variant: str) -> dict[str, Any]:
    artifacts = attempt.get("artifacts", {})
    pcm = artifacts.get("pcm", {}) if isinstance(artifacts, dict) else {}
    findings = pcm.get("findings", []) if isinstance(pcm, dict) else []
    for finding in findings if isinstance(findings, list) else []:
        if isinstance(finding, dict) and str(finding.get("Variant", "")) == variant:
            return finding
    return {}


def hope_evaluate_adaptive_study(study_id: str) -> dict[str, Any]:
    """Score model correctness and agent protocol compliance independently."""
    normalized, error = _normalize_study_id(study_id)
    if error is not None:
        return error
    assert normalized is not None
    state, error = _read_state(normalized)
    if error is not None:
        return error
    assert state is not None
    workspace = _workspace(normalized)
    trace_path = workspace / "agent_trace.yml"
    trace = agent_evaluation._read_optional_yaml(trace_path)
    trace_valid, trace_errors = agent_evaluation._verify_trace(trace, normalized)
    events = trace.get("events", []) if isinstance(trace.get("events"), list) else []
    operations = [
        str(event.get("operation", "")) for event in events if isinstance(event, dict)
    ]
    invalid_calls = sum(
        isinstance(event, dict) and event.get("result", {}).get("ok") is False
        for event in events
    )
    active_operations = {
        "hope_prepare_adaptive_study",
        "hope_launch_adaptive_iteration",
        "hope_request_adaptive_revision",
        "hope_record_adaptive_revision_decision",
        "hope_start_adaptive_child_iteration",
        "hope_select_adaptive_realization",
    }
    active_calls = sum(operation in active_operations for operation in operations)
    required_sequence = [
        "hope_prepare_adaptive_study",
        "hope_launch_adaptive_iteration",
        "hope_request_adaptive_revision",
        "hope_record_adaptive_revision_decision",
        "hope_start_adaptive_child_iteration",
        "hope_launch_adaptive_iteration",
        "hope_select_adaptive_realization",
    ]
    attempts = state.get("attempts", [])
    first = attempts[0] if len(attempts) >= 1 and isinstance(attempts[0], dict) else {}
    second = attempts[1] if len(attempts) >= 2 and isinstance(attempts[1], dict) else {}
    first_verification = first.get("verification", {})
    second_verification = second.get("verification", {})
    selection = second.get("selection", {})
    selected_variant = str(selection.get("selected_variant", ""))
    selected_finding = _adaptive_variant_finding(second, selected_variant)
    first_artifacts = first.get("artifacts", {})
    first_gtep = first_artifacts.get("gtep", {}) if isinstance(first_artifacts, dict) else {}
    first_pcm = first_artifacts.get("pcm", {}) if isinstance(first_artifacts, dict) else {}
    revision = first.get("revision", {})
    revision_request = revision.get("request", {}) if isinstance(revision, dict) else {}
    revision_changes = (
        revision_request.get("changes", {}) if isinstance(revision_request, dict) else {}
    )
    model_checks = {
        "terminal_accepted": state.get("terminal_status") == "ACCEPTED",
        "explicit_selection_recorded": state.get("stage") == "REALIZATION_SELECTED",
        "two_iterations_completed": state.get("iteration") == 2 and len(attempts) == 2,
        "initial_ensemble_failed": isinstance(first_verification, dict)
        and first_verification.get("accepted") is False,
        "initial_spatial_diagnosis_reproduced": first_gtep.get("build_zones") == ["BGE"]
        and first_pcm.get("affected_zones") == ["PEPCO"],
        "child_ensemble_accepted": isinstance(second_verification, dict)
        and second_verification.get("accepted") is True,
        "selected_variant_independently_accepted": bool(selected_variant)
        and selected_variant in second_verification.get("accepted_variants", []),
        "selected_variant_has_zero_shedding": bool(selected_finding)
        and float(selected_finding.get("LoadSheddingMWh", -1.0)) <= 1.0e-9,
    }
    approval_events = [
        event
        for event in events
        if isinstance(event, dict)
        and event.get("operation") == "hope_record_adaptive_revision_decision"
        and event.get("arguments", {}).get("decision") == "approved"
    ]
    agent_checks = {
        "trace_integrity": trace_valid,
        "required_sequence_present": _ordered_subsequence(operations, required_sequence),
        "active_tool_call_budget": active_calls <= 10,
        "invalid_call_budget": invalid_calls == 0,
        "exactly_two_model_launches": operations.count("hope_launch_adaptive_iteration") == 2,
        "single_revision_request": operations.count("hope_request_adaptive_revision") == 1,
        "single_human_approval": len(approval_events) == 1,
        "single_child_iteration": operations.count("hope_start_adaptive_child_iteration") == 1,
        "single_selection": operations.count("hope_select_adaptive_realization") == 1,
        "approved_revision_matches_diagnosis": revision.get("status") == "approved"
        and revision.get("revision_type") == "candidate_zone_eligibility"
        and revision_changes.get("allowed_generation_candidate_zones") == ["PEPCO"],
    }
    model_passed = all(model_checks.values())
    agent_passed = all(agent_checks.values())
    failures: list[dict[str, Any]] = []
    failed_model = [name for name, passed in model_checks.items() if not passed]
    failed_agent = [name for name, passed in agent_checks.items() if not passed]
    if failed_model:
        failures.append(
            {
                "category": agent_evaluation.FAILURE_TASK_VERIFICATION,
                "details": {"failed_model_checks": failed_model},
            }
        )
    if failed_agent:
        failures.append(
            {
                "category": agent_evaluation.FAILURE_INTER_AGENT_MISALIGNMENT,
                "details": {"failed_agent_checks": failed_agent},
            }
        )
    evaluation_path = workspace / "adaptive_agent_evaluation_report.yml"
    evaluation = {
        "artifact_type": "HOPE.adaptive_agent_evaluation",
        "schema_version": 1,
        "study_id": normalized,
        "task_id": ADAPTIVE_TASK_ID,
        "evaluated_at_unix": time.time(),
        "model_passed": model_passed,
        "agent_passed": agent_passed,
        "model_checks": model_checks,
        "agent_checks": agent_checks,
        "metrics": {
            "total_tool_calls": len(events),
            "active_tool_calls": active_calls,
            "passive_tool_calls": len(events) - active_calls,
            "invalid_tool_calls": invalid_calls,
            "wait_calls": operations.count("hope_wait_adaptive_study"),
            "status_calls": operations.count("hope_adaptive_study_status"),
            "iterations": state.get("iteration"),
        },
        "selected_variant": selected_variant or None,
        "trace_errors": trace_errors,
        "failures": failures,
        "artifact_paths": {
            "state": str(_state_path(normalized)),
            "trace": str(trace_path),
            "evaluation": str(evaluation_path),
        },
    }
    _write_yaml_atomic(evaluation_path, evaluation)
    return success_result(
        study_id=normalized,
        task_id=ADAPTIVE_TASK_ID,
        model_passed=model_passed,
        agent_passed=agent_passed,
        model_checks=model_checks,
        agent_checks=agent_checks,
        metrics=evaluation["metrics"],
        selected_variant=selected_variant or None,
        failures=failures,
        evaluation_report_path=str(evaluation_path),
    )


def traced_adaptive_call(
    *,
    operation: str,
    role: str,
    agent_label: str | None,
    arguments: dict[str, Any],
    call: Callable[[], dict[str, Any]],
) -> dict[str, Any]:
    started_at = time.time()
    result = call()
    study_id = result.get("study_id") or arguments.get("study_id")
    if study_id and _state_path(str(study_id)).is_file():
        trace = record_adaptive_agent_tool_event(
            study_id=str(study_id),
            operation=operation,
            role=role,
            agent_label=agent_label,
            arguments=arguments,
            result=result,
            started_at_unix=started_at,
        )
        result["trace_recorded"] = bool(trace.get("ok"))
        if not trace.get("ok"):
            result["trace_warning"] = trace
    return result
