from __future__ import annotations

import hashlib
import json
import os
import threading
import time
import uuid
from pathlib import Path
from typing import Any, Mapping, Sequence

import yaml


AGENT_TRACE_SCHEMA_VERSION = 1
AGENT_REPORT_SCHEMA_VERSION = 2
AGENT_EVALUATION_SCHEMA_VERSION = 4

FAILURE_SYSTEM_DESIGN = "system_design"
FAILURE_INTER_AGENT_MISALIGNMENT = "inter_agent_misalignment"
FAILURE_TASK_VERIFICATION = "task_verification"

SUPPORTED_ARCHITECTURES = {"single_agent", "centralized_roles"}
REQUIRED_CLAIMS = (
    "study_accepted",
    "run_published",
    "audit_accepted",
    "all_acceptance_checks_passed",
)

# This first task deliberately evaluates the stable Maryland benchmark only. New
# model combinations should receive their own versioned task instead of silently
# changing these thresholds.
EVALUATION_TASKS: dict[str, dict[str, Any]] = {
    "md-rps20-annual-gtep-july-pcm-v1": {
        "schema_version": 1,
        "description": "Annual Maryland GTEP to July PCM validation workflow.",
        "required_operations": [
            "hope_prepare_holistic_validation_study",
            "hope_launch_holistic_study",
            "hope_holistic_study_status",
            "hope_audit_holistic_study",
            "hope_submit_holistic_agent_report",
        ],
        "maximum_tool_calls": 25,
        "maximum_invalid_calls": 0,
        "minimum_evidence_paths": 3,
        "required_claims": list(REQUIRED_CLAIMS),
        "approval_required_operations": [],
    },
    "md-rps20-annual-gtep-july-pcm-v2": {
        "schema_version": 2,
        "description": (
            "Annual Maryland GTEP to July PCM workflow with traced long-poll monitoring."
        ),
        "required_operations": [
            "hope_prepare_holistic_validation_study",
            "hope_launch_holistic_study",
            "hope_wait_holistic_study",
            "hope_audit_holistic_study",
            "hope_submit_holistic_agent_report",
        ],
        "maximum_tool_calls": 30,
        "maximum_invalid_calls": 0,
        "minimum_evidence_paths": 3,
        "required_claims": list(REQUIRED_CLAIMS),
        "approval_required_operations": [],
        "required_monitoring_mode": "hope_mcp_only",
    },
    "md-rps20-annual-gtep-july-pcm-v3": {
        "schema_version": 3,
        "description": (
            "Annual Maryland GTEP to July PCM workflow with runtime-independent "
            "agent call budgeting."
        ),
        "required_operations": [
            "hope_prepare_holistic_validation_study",
            "hope_launch_holistic_study",
            "hope_wait_holistic_study",
            "hope_audit_holistic_study",
            "hope_submit_holistic_agent_report",
        ],
        "maximum_active_tool_calls": 10,
        "budget_exempt_operations": ["hope_wait_holistic_study"],
        "maximum_invalid_calls": 0,
        "maximum_duplicate_role_calls": 0,
        "minimum_evidence_paths": 3,
        "required_claims": list(REQUIRED_CLAIMS),
        "approval_required_operations": [],
        "required_monitoring_mode": "hope_mcp_only",
    },
}

_trace_lock = threading.Lock()


def _canonical_hash(value: Mapping[str, Any]) -> str:
    payload = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def _read_yaml(path: Path) -> dict[str, Any]:
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError(f"Expected a YAML mapping in {path}.")
    return data


def _write_yaml_atomic(path: Path, data: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    temporary.write_text(
        yaml.safe_dump(dict(data), sort_keys=False, allow_unicode=True),
        encoding="utf-8",
    )
    try:
        for attempt in range(6):
            try:
                os.replace(temporary, path)
                return
            except PermissionError:
                if attempt == 5:
                    raise
                time.sleep(0.05 * (attempt + 1))
    finally:
        if temporary.exists():
            temporary.unlink()


def _safe_value(value: Any, *, depth: int = 0) -> Any:
    """Keep trace arguments useful while bounding size and object complexity."""
    if depth > 4:
        return "<truncated>"
    if value is None or isinstance(value, (bool, int, float)):
        return value
    if isinstance(value, Path):
        return str(value)
    if isinstance(value, str):
        return value if len(value) <= 512 else value[:509] + "..."
    if isinstance(value, Mapping):
        return {
            str(key)[:128]: _safe_value(item, depth=depth + 1)
            for key, item in list(value.items())[:32]
        }
    if isinstance(value, Sequence) and not isinstance(value, (str, bytes, bytearray)):
        return [_safe_value(item, depth=depth + 1) for item in list(value)[:32]]
    return str(value)[:512]


def _result_summary(result: Mapping[str, Any]) -> dict[str, Any]:
    keys = (
        "ok",
        "status",
        "manifest_status",
        "error_type",
        "reused",
        "study_id",
        "job_id",
        "study_manifest_path",
        "manifest_path",
        "audit_report_path",
    )
    return {key: _safe_value(result.get(key)) for key in keys if key in result}


def append_tool_event(
    study_root: Path,
    *,
    study_id: str,
    operation: str,
    role: str,
    agent_label: str | None,
    arguments: Mapping[str, Any],
    result: Mapping[str, Any],
    started_at_unix: float,
    completed_at_unix: float | None = None,
) -> dict[str, Any]:
    """Append a server-observed, hash-chained MCP event to a study trace."""
    trace_path = study_root / "agent_trace.yml"
    completed = completed_at_unix if completed_at_unix is not None else time.time()
    with _trace_lock:
        if trace_path.is_file():
            trace = _read_yaml(trace_path)
        else:
            trace = {
                "schema_version": AGENT_TRACE_SCHEMA_VERSION,
                "study_id": study_id,
                "created_at_unix": started_at_unix,
                "events": [],
            }
        if trace.get("schema_version") != AGENT_TRACE_SCHEMA_VERSION:
            raise ValueError("Unsupported agent trace schema version.")
        if trace.get("study_id") != study_id:
            raise ValueError("Agent trace study_id does not match the study directory.")
        events = trace.setdefault("events", [])
        if not isinstance(events, list):
            raise ValueError("Agent trace events must be a list.")
        previous_hash = events[-1].get("event_sha256") if events else None
        payload = {
            "event_id": uuid.uuid4().hex,
            "sequence": len(events) + 1,
            "started_at_unix": float(started_at_unix),
            "completed_at_unix": float(completed),
            "duration_seconds": max(0.0, float(completed) - float(started_at_unix)),
            "operation": str(operation),
            "role": str(role),
            "agent_label": str(agent_label).strip() if agent_label else None,
            "arguments": _safe_value(arguments),
            "result": _result_summary(result),
            "previous_event_sha256": previous_hash,
        }
        payload["event_sha256"] = _canonical_hash(payload)
        events.append(payload)
        trace["updated_at_unix"] = float(completed)
        _write_yaml_atomic(trace_path, trace)
    return {
        "ok": True,
        "study_id": study_id,
        "event_id": payload["event_id"],
        "sequence": payload["sequence"],
        "trace_path": str(trace_path),
        "event_sha256": payload["event_sha256"],
    }


def _is_within(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
    except ValueError:
        return False
    return True


def _allowed_evidence_roots(study_root: Path, study: Mapping[str, Any]) -> list[Path]:
    roots = [study_root.resolve()]
    run_manifest_value = study.get("run_manifest_path")
    if run_manifest_value:
        run_manifest = Path(str(run_manifest_value)).expanduser().resolve()
        roots.append(run_manifest.parent)
    return roots


def _resolve_evidence_paths(
    evidence_paths: Sequence[str],
    *,
    study_root: Path,
    study: Mapping[str, Any],
) -> tuple[list[str], list[dict[str, Any]]]:
    roots = _allowed_evidence_roots(study_root, study)
    resolved: list[str] = []
    checks: list[dict[str, Any]] = []
    for raw in evidence_paths:
        candidate = Path(str(raw)).expanduser()
        if not candidate.is_absolute():
            candidate = study_root / candidate
        candidate = candidate.resolve()
        scoped = any(_is_within(candidate, root) for root in roots)
        exists = candidate.is_file()
        checks.append(
            {
                "path": str(candidate),
                "scoped": scoped,
                "exists": exists,
                "passed": scoped and exists,
            }
        )
        if scoped and exists:
            resolved.append(str(candidate))
    return resolved, checks


def submit_agent_report(
    study_root: Path,
    study: Mapping[str, Any],
    *,
    task_id: str,
    architecture: str,
    agent_label: str,
    claims: Mapping[str, bool],
    evidence_paths: Sequence[str],
    approvals: Sequence[Mapping[str, Any]] | None = None,
    monitoring_mode: str | None = None,
) -> dict[str, Any]:
    if task_id not in EVALUATION_TASKS:
        return {
            "ok": False,
            "error_type": "invalid_evaluation_task",
            "message": f"Unsupported evaluation task '{task_id}'.",
            "allowed_tasks": sorted(EVALUATION_TASKS),
        }
    normalized_architecture = str(architecture).strip().lower()
    if normalized_architecture not in SUPPORTED_ARCHITECTURES:
        return {
            "ok": False,
            "error_type": "invalid_agent_architecture",
            "message": "architecture must be single_agent or centralized_roles.",
        }
    normalized_label = str(agent_label).strip()
    if not normalized_label or len(normalized_label) > 128:
        return {
            "ok": False,
            "error_type": "invalid_agent_label",
            "message": "agent_label must be 1-128 characters.",
        }
    invalid_claims = [key for key, value in claims.items() if not isinstance(value, bool)]
    if invalid_claims:
        return {
            "ok": False,
            "error_type": "invalid_agent_claims",
            "message": "Every agent claim must be a Boolean value.",
            "invalid_claims": sorted(str(key) for key in invalid_claims),
        }
    normalized_claims = {str(key): value for key, value in claims.items()}
    missing = [key for key in REQUIRED_CLAIMS if key not in normalized_claims]
    if missing:
        return {
            "ok": False,
            "error_type": "missing_agent_claims",
            "message": "The final report is missing required claims.",
            "missing_claims": missing,
        }
    normalized_monitoring = (
        str(monitoring_mode).strip().lower() if monitoring_mode is not None else "unspecified"
    )
    if normalized_monitoring not in {
        "hope_mcp_only",
        "external_tools_used",
        "unspecified",
    }:
        return {
            "ok": False,
            "error_type": "invalid_monitoring_mode",
            "message": (
                "monitoring_mode must be hope_mcp_only, external_tools_used, or unspecified."
            ),
        }
    resolved_evidence, evidence_checks = _resolve_evidence_paths(
        evidence_paths,
        study_root=study_root,
        study=study,
    )
    if any(not item["passed"] for item in evidence_checks):
        return {
            "ok": False,
            "error_type": "invalid_evidence_path",
            "message": "Evidence must be an existing file inside the study or run workspace.",
            "evidence_checks": evidence_checks,
        }
    report_path = study_root / "agent_final_report.yml"
    report = {
        "schema_version": AGENT_REPORT_SCHEMA_VERSION,
        "study_id": study.get("study_id"),
        "task_id": task_id,
        "architecture": normalized_architecture,
        "agent_label": normalized_label,
        "submitted_at_unix": time.time(),
        "claims": normalized_claims,
        "evidence_paths": resolved_evidence,
        "approvals": [_safe_value(item) for item in (approvals or [])],
        "monitoring_mode": normalized_monitoring,
    }
    _write_yaml_atomic(report_path, report)
    return {
        "ok": True,
        "study_id": study.get("study_id"),
        "task_id": task_id,
        "architecture": normalized_architecture,
        "report_path": str(report_path),
        "evidence_count": len(resolved_evidence),
    }


def _verify_trace(trace: Mapping[str, Any], study_id: str) -> tuple[bool, list[str]]:
    errors: list[str] = []
    if trace.get("schema_version") != AGENT_TRACE_SCHEMA_VERSION:
        errors.append("unsupported trace schema_version")
    if trace.get("study_id") != study_id:
        errors.append("trace study_id mismatch")
    events = trace.get("events")
    if not isinstance(events, list):
        return False, errors + ["events is not a list"]
    previous: str | None = None
    for index, event in enumerate(events, start=1):
        if not isinstance(event, dict):
            errors.append(f"event {index} is not a mapping")
            continue
        if event.get("sequence") != index:
            errors.append(f"event {index} sequence mismatch")
        if event.get("previous_event_sha256") != previous:
            errors.append(f"event {index} previous hash mismatch")
        hashed = dict(event)
        actual_hash = hashed.pop("event_sha256", None)
        expected_hash = _canonical_hash(hashed)
        if actual_hash != expected_hash:
            errors.append(f"event {index} hash mismatch")
        previous = actual_hash
    return not errors, errors


def _read_optional_yaml(path: Path) -> dict[str, Any]:
    try:
        return _read_yaml(path) if path.is_file() else {}
    except (OSError, ValueError, yaml.YAMLError):
        return {}


def _sha256_file(path: Path | None) -> str | None:
    if path is None or not path.is_file():
        return None
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _latest_report_submission_context(trace: Mapping[str, Any]) -> dict[str, Any]:
    """Recover task metadata from a rejected final-report submission."""
    events = trace.get("events", [])
    if not isinstance(events, list):
        return {}
    for event in reversed(events):
        if not isinstance(event, dict):
            continue
        if event.get("operation") != "hope_submit_holistic_agent_report":
            continue
        arguments = event.get("arguments", {})
        return dict(arguments) if isinstance(arguments, dict) else {}
    return {}


def evaluate_agent_study(
    study_root: Path,
    study: Mapping[str, Any],
    *,
    task_id: str | None = None,
) -> dict[str, Any]:
    report_path = study_root / "agent_final_report.yml"
    trace_path = study_root / "agent_trace.yml"
    report = _read_optional_yaml(report_path)
    trace = _read_optional_yaml(trace_path)
    submission_context = _latest_report_submission_context(trace)
    selected_task_id = (
        task_id
        or str(report.get("task_id", "")).strip()
        or str(submission_context.get("task_id", "")).strip()
    )
    task = EVALUATION_TASKS.get(selected_task_id)
    if task is None:
        return {
            "ok": False,
            "error_type": "invalid_evaluation_task",
            "message": "Submit a report with a supported task_id before evaluation.",
            "allowed_tasks": sorted(EVALUATION_TASKS),
        }
    report_task_id = str(report.get("task_id", ""))
    if report and task_id is not None and report_task_id != selected_task_id:
        return {
            "ok": False,
            "error_type": "evaluation_task_mismatch",
            "message": (
                f"The submitted report uses task_id '{report_task_id}', not "
                f"'{selected_task_id}'. Submit a new report for the requested task."
            ),
            "report_task_id": report_task_id,
            "requested_task_id": selected_task_id,
        }
    study_id = str(study.get("study_id", ""))
    trace_valid, trace_errors = _verify_trace(trace, study_id)
    events = trace.get("events", []) if isinstance(trace.get("events"), list) else []
    operations = [str(event.get("operation", "")) for event in events if isinstance(event, dict)]

    audit_value = study.get("audit")
    audit_path_value = (
        audit_value.get("audit_report_path") if isinstance(audit_value, dict) else None
    )
    audit = _read_optional_yaml(Path(str(audit_path_value))) if audit_path_value else {}
    run_manifest_value = study.get("run_manifest_path")
    run_manifest = _read_optional_yaml(Path(str(run_manifest_value))) if run_manifest_value else {}
    acceptance_check = next(
        (
            item
            for item in audit.get("checks", [])
            if isinstance(item, dict) and item.get("check") == "acceptance_checks_passed"
        ),
        {},
    )
    actual_claims = {
        "study_accepted": str(study.get("status", "")).upper() == "ACCEPTED",
        "run_published": str(run_manifest.get("status", "")).upper() == "PUBLISHED",
        "audit_accepted": audit.get("accepted") is True,
        "all_acceptance_checks_passed": acceptance_check.get("passed") is True,
    }
    claimed = report.get("claims", {}) if isinstance(report.get("claims"), dict) else {}
    claim_checks = [
        {
            "claim": key,
            "claimed": claimed.get(key),
            "actual": actual_claims[key],
            "passed": claimed.get(key) is actual_claims[key],
        }
        for key in task["required_claims"]
    ]
    evidence, evidence_checks = _resolve_evidence_paths(
        report.get("evidence_paths", []),
        study_root=study_root,
        study=study,
    )
    required_missing = [item for item in task["required_operations"] if item not in operations]
    invalid_events = [
        event
        for event in events
        if isinstance(event, dict) and event.get("result", {}).get("ok") is False
    ]
    passive_operations = {"hope_wait_holistic_study"}
    passive_calls = sum(operation in passive_operations for operation in operations)
    active_calls = len(events) - passive_calls
    budget_exempt_operations = set(task.get("budget_exempt_operations", []))
    if "maximum_active_tool_calls" in task:
        budget_mode = "active_calls"
        budgeted_calls = sum(
            operation not in budget_exempt_operations for operation in operations
        )
        tool_call_limit = int(task["maximum_active_tool_calls"])
    else:
        budget_mode = "total_calls"
        budgeted_calls = len(events)
        tool_call_limit = int(task["maximum_tool_calls"])
    reusable_operations = {
        "hope_prepare_holistic_validation_study",
        "hope_launch_holistic_study",
        "hope_audit_holistic_study",
        "hope_submit_holistic_agent_report",
    }
    duplicate_calls = sum(max(0, operations.count(name) - 1) for name in reusable_operations)
    architecture = str(
        report.get("architecture") or submission_context.get("architecture") or ""
    )
    role_events = [
        event
        for event in events
        if isinstance(event, dict)
        and event.get("operation")
        in {
            "hope_prepare_holistic_validation_study",
            "hope_launch_holistic_study",
            "hope_audit_holistic_study",
        }
    ]
    labels = {str(event.get("agent_label")) for event in role_events if event.get("agent_label")}
    architecture_passed = (
        (architecture == "single_agent" and len(labels) == 1)
        or (architecture == "centralized_roles" and len(labels) >= 3)
    )
    approvals = report.get("approvals", []) if isinstance(report.get("approvals"), list) else []
    approved_operations = {
        str(item.get("operation"))
        for item in approvals
        if isinstance(item, dict) and item.get("approved") is True
    }
    missing_approvals = [
        name for name in task["approval_required_operations"] if name not in approved_operations
    ]
    required_monitoring_mode = task.get("required_monitoring_mode")
    monitoring_mode = str(
        report.get("monitoring_mode")
        or submission_context.get("monitoring_mode")
        or "unspecified"
    ).strip().lower()
    wait_calls = operations.count("hope_wait_holistic_study")
    monitoring_contract_passed = required_monitoring_mode is None or (
        monitoring_mode == required_monitoring_mode and wait_calls >= 1
    )
    checks = {
        "trace_integrity": trace_valid,
        "required_operations_present": not required_missing,
        "tool_call_budget": budgeted_calls <= tool_call_limit,
        "invalid_call_budget": len(invalid_events) <= int(task["maximum_invalid_calls"]),
        "claims_match_authoritative_artifacts": all(item["passed"] for item in claim_checks),
        "evidence_paths_valid": all(item["passed"] for item in evidence_checks),
        "minimum_evidence_met": len(evidence) >= int(task["minimum_evidence_paths"]),
        "architecture_roles_match": architecture_passed,
        "required_approvals_present": not missing_approvals,
        "monitoring_contract_compliance": monitoring_contract_passed,
    }
    duplicate_role_call_limit = task.get("maximum_duplicate_role_calls")
    if duplicate_role_call_limit is not None:
        checks["duplicate_role_call_budget"] = (
            duplicate_calls <= int(duplicate_role_call_limit)
        )
    model_passed = all(actual_claims.values())
    agent_passed = all(checks.values())
    failures: list[dict[str, Any]] = []
    if not trace_valid or not checks["tool_call_budget"]:
        failures.append(
            {
                "category": FAILURE_SYSTEM_DESIGN,
                "details": trace_errors
                or [
                    f"{budget_mode} budget exceeded: "
                    f"{budgeted_calls} > {tool_call_limit}"
                ],
            }
        )
    duplicate_role_calls_passed = checks.get("duplicate_role_call_budget", True)
    if (
        required_missing
        or not architecture_passed
        or missing_approvals
        or not duplicate_role_calls_passed
    ):
        failures.append(
            {
                "category": FAILURE_INTER_AGENT_MISALIGNMENT,
                "details": {
                    "missing_operations": required_missing,
                    "architecture_roles_match": architecture_passed,
                    "missing_approvals": missing_approvals,
                    "duplicate_role_calls": duplicate_calls,
                    "duplicate_role_call_limit": duplicate_role_call_limit,
                },
            }
        )
    failed_claims = [item for item in claim_checks if not item["passed"]]
    if (
        failed_claims
        or not report
        or not checks["invalid_call_budget"]
        or not checks["evidence_paths_valid"]
        or not checks["minimum_evidence_met"]
        or not monitoring_contract_passed
    ):
        failures.append(
            {
                "category": FAILURE_TASK_VERIFICATION,
                "details": {
                    "agent_report_present": bool(report),
                    "failed_claims": failed_claims,
                    "invalid_tool_calls": len(invalid_events),
                    "evidence_checks": evidence_checks,
                    "required_monitoring_mode": required_monitoring_mode,
                    "reported_monitoring_mode": monitoring_mode,
                    "wait_calls": wait_calls,
                },
            }
        )
    started = min((float(event.get("started_at_unix", 0.0)) for event in events), default=0.0)
    completed = max((float(event.get("completed_at_unix", 0.0)) for event in events), default=0.0)
    evaluation_path = study_root / "agent_evaluation_report.yml"
    resolved_run_manifest_path = Path(str(run_manifest_value)) if run_manifest_value else None
    resolved_audit_path = Path(str(audit_path_value)) if audit_path_value else None
    evaluation = {
        "schema_version": AGENT_EVALUATION_SCHEMA_VERSION,
        "study_id": study_id,
        "task_id": selected_task_id,
        "architecture": architecture,
        "evaluated_at_unix": time.time(),
        "model_passed": model_passed,
        "agent_passed": agent_passed,
        "agent_report_present": bool(report),
        "checks": checks,
        "metrics": {
            "total_tool_calls": len(events),
            "active_tool_calls": active_calls,
            "passive_tool_calls": passive_calls,
            "budgeted_tool_calls": budgeted_calls,
            "tool_call_budget_limit": tool_call_limit,
            "tool_call_budget_mode": budget_mode,
            "invalid_tool_calls": len(invalid_events),
            "duplicate_role_calls": duplicate_calls,
            "duplicate_role_call_limit": duplicate_role_call_limit,
            "status_poll_calls": operations.count("hope_holistic_study_status"),
            "wait_calls": wait_calls,
            "monitoring_mode": monitoring_mode,
            "elapsed_seconds": max(0.0, completed - started),
            "evidence_path_count": len(evidence),
            "verified_claims": sum(1 for item in claim_checks if item["passed"]),
            "total_claims": len(claim_checks),
            "false_safe_claims": sum(
                1 for item in claim_checks if item["claimed"] is True and item["actual"] is False
            ),
        },
        "authoritative_claims": actual_claims,
        "claim_checks": claim_checks,
        "missing_required_operations": required_missing,
        "trace_errors": trace_errors,
        "failures": failures,
        "authoritative_artifacts": {
            "study_status": str(study.get("status", "")).upper(),
            "request_sha256": str(study.get("request_sha256", "")),
            "run_status": str(run_manifest.get("status", "")).upper(),
            "audit_accepted": audit.get("accepted") if audit else None,
            "run_manifest_sha256": _sha256_file(resolved_run_manifest_path),
            "audit_report_sha256": _sha256_file(resolved_audit_path),
        },
        "artifact_paths": {
            "trace": str(trace_path),
            "agent_report": str(report_path) if report else None,
            "evaluation_report": str(evaluation_path),
        },
    }
    _write_yaml_atomic(evaluation_path, evaluation)
    return {
        "ok": True,
        "study_id": study_id,
        "task_id": selected_task_id,
        "model_passed": model_passed,
        "agent_passed": agent_passed,
        "checks": checks,
        "metrics": evaluation["metrics"],
        "failures": failures,
        "evaluation_report_path": str(evaluation_path),
    }
