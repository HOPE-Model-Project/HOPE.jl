from __future__ import annotations

import argparse
import csv
import hashlib
import json
import statistics
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence

import yaml


SUMMARY_SCHEMA_VERSION = 2

RUN_FIELDS = (
    "study_id",
    "task_id",
    "architecture",
    "model_passed",
    "agent_passed",
    "total_tool_calls",
    "active_tool_calls",
    "passive_tool_calls",
    "budgeted_tool_calls",
    "invalid_tool_calls",
    "duplicate_role_calls",
    "status_poll_calls",
    "wait_calls",
    "elapsed_seconds",
    "verified_claims",
    "total_claims",
    "false_safe_claims",
    "failure_categories",
    "request_sha256",
    "gtep_source_sha256",
    "pcm_source_sha256",
    "solver",
    "condition_signature",
    "evaluation_report_path",
)

MATCH_FIELDS = (
    "task_id",
    "request_sha256",
    "gtep_source_sha256",
    "pcm_source_sha256",
    "solver",
)


def _read_yaml_mapping(path: Path) -> dict[str, Any]:
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError(f"Expected a YAML mapping in {path}.")
    return data


def _condition_signature(values: Mapping[str, Any]) -> str:
    payload = {field: values.get(field) for field in MATCH_FIELDS}
    serialized = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(serialized.encode("utf-8")).hexdigest()


def _failure_categories(report: Mapping[str, Any]) -> str:
    failures = report.get("failures", [])
    if not isinstance(failures, list):
        return ""
    categories = {
        str(item.get("category", "")).strip()
        for item in failures
        if isinstance(item, dict) and str(item.get("category", "")).strip()
    }
    return ";".join(sorted(categories))


def _manifest_hash(manifest: Mapping[str, Any], key: str) -> str:
    direct = manifest.get(f"{key}_source_sha256")
    if direct:
        return str(direct)
    fingerprint = manifest.get(f"{key}_source_fingerprint")
    if isinstance(fingerprint, dict) and fingerprint.get("sha256"):
        return str(fingerprint["sha256"])
    return ""


def _file_sha256(path: Path | None) -> str | None:
    if path is None or not path.is_file():
        return None
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _evaluation_staleness(
    report_path: Path,
    report: Mapping[str, Any],
    manifest_path: Path,
    manifest: Mapping[str, Any],
) -> tuple[bool, str]:
    artifacts = report.get("authoritative_artifacts", {})
    run_value = manifest.get("run_manifest_path")
    audit_value = manifest.get("audit", {})
    audit_path_value = (
        audit_value.get("audit_report_path") if isinstance(audit_value, dict) else None
    )
    current = {
        "run_manifest_sha256": _file_sha256(Path(str(run_value))) if run_value else None,
        "audit_report_sha256": _file_sha256(Path(str(audit_path_value)))
        if audit_path_value
        else None,
    }
    if isinstance(artifacts, dict) and "study_status" in artifacts:
        changed = [
            name
            for name, value in current.items()
            if artifacts.get(name) != value
        ]
        if str(artifacts.get("study_status", "")).upper() != str(
            manifest.get("status", "")
        ).upper():
            changed.append("study_status")
        if str(artifacts.get("request_sha256", "")) != str(
            manifest.get("request_sha256", "")
        ):
            changed.append("request_sha256")
        if changed:
            return True, "authoritative artifacts changed after evaluation: " + ", ".join(changed)
        return False, ""

    authoritative_paths = [manifest_path]
    if run_value:
        authoritative_paths.append(Path(str(run_value)))
    if audit_path_value:
        authoritative_paths.append(Path(str(audit_path_value)))
    newer = [
        path.name
        for path in authoritative_paths
        if path.is_file() and path.stat().st_mtime_ns > report_path.stat().st_mtime_ns
    ]
    if newer:
        return True, "legacy evaluation predates authoritative artifacts: " + ", ".join(newer)
    return False, ""


def load_experiment_run(report_path: Path, study_root: Path) -> dict[str, Any]:
    report = _read_yaml_mapping(report_path)
    manifest_path = report_path.parent / "study_manifest.yml"
    manifest = _read_yaml_mapping(manifest_path)
    metrics = report.get("metrics", {})
    if not isinstance(metrics, dict):
        raise ValueError(f"Expected metrics mapping in {report_path}.")

    study_id = str(report.get("study_id", "")).strip()
    task_id = str(report.get("task_id", "")).strip()
    architecture = str(report.get("architecture", "")).strip()
    if not study_id or not task_id or not architecture:
        raise ValueError(
            f"Evaluation report {report_path} is missing study_id, task_id, or architecture."
        )

    preparation = manifest.get("preparation", {})
    evaluation_stale, stale_reason = _evaluation_staleness(
        report_path, report, manifest_path, manifest
    )
    solver = manifest.get("solver")
    if not solver and isinstance(preparation, dict):
        solver = preparation.get("solver")
    row: dict[str, Any] = {
        "study_id": study_id,
        "task_id": task_id,
        "architecture": architecture,
        "model_passed": report.get("model_passed") is True,
        "agent_passed": report.get("agent_passed") is True,
        "failure_categories": _failure_categories(report),
        "request_sha256": str(manifest.get("request_sha256", "")),
        "gtep_source_sha256": _manifest_hash(manifest, "gtep"),
        "pcm_source_sha256": _manifest_hash(manifest, "pcm"),
        "solver": str(solver or ""),
        "evaluation_report_path": str(report_path.resolve().relative_to(study_root.resolve())),
        "evaluation_stale": evaluation_stale,
        "stale_reason": stale_reason,
    }
    for name in RUN_FIELDS:
        if name in row or name in {"condition_signature", "evaluation_report_path"}:
            continue
        row[name] = metrics.get(name)
    row["condition_signature"] = _condition_signature(row)
    return row


def _incomplete_study_context(study_dir: Path) -> dict[str, str]:
    context = {"task_id": "", "architecture": ""}
    final_report_path = study_dir / "agent_final_report.yml"
    if final_report_path.is_file():
        try:
            report = _read_yaml_mapping(final_report_path)
        except (OSError, ValueError, yaml.YAMLError):
            report = {}
        context["task_id"] = str(report.get("task_id", "")).strip()
        context["architecture"] = str(report.get("architecture", "")).strip()
    trace_path = study_dir / "agent_trace.yml"
    if trace_path.is_file() and (not context["task_id"] or not context["architecture"]):
        try:
            trace = _read_yaml_mapping(trace_path)
        except (OSError, ValueError, yaml.YAMLError):
            trace = {}
        events = trace.get("events", [])
        if isinstance(events, list):
            for event in reversed(events):
                if not isinstance(event, dict):
                    continue
                if event.get("operation") != "hope_submit_holistic_agent_report":
                    continue
                arguments = event.get("arguments", {})
                if isinstance(arguments, dict):
                    context["task_id"] = context["task_id"] or str(
                        arguments.get("task_id", "")
                    ).strip()
                    context["architecture"] = context["architecture"] or str(
                        arguments.get("architecture", "")
                    ).strip()
                break
    return context


def discover_experiment_runs(
    study_root: Path,
    *,
    task_id: str | None = None,
    architectures: Sequence[str] | None = None,
    study_id_prefix: str | None = None,
    excluded_study_ids: Sequence[str] | None = None,
) -> tuple[
    list[dict[str, Any]],
    list[dict[str, str]],
    list[dict[str, str]],
]:
    selected_architectures = {item.strip() for item in architectures or [] if item.strip()}
    excluded = {item.strip() for item in excluded_study_ids or [] if item.strip()}
    rows: list[dict[str, Any]] = []
    skipped: list[dict[str, str]] = []
    incomplete: list[dict[str, str]] = []
    study_dirs = sorted(path for path in study_root.iterdir() if path.is_dir())
    for study_dir in study_dirs:
        if study_dir.name in excluded:
            skipped.append({"path": str(study_dir), "reason": "study ID explicitly excluded"})
            continue
        if study_id_prefix and not study_dir.name.startswith(study_id_prefix):
            continue
        report_path = study_dir / "agent_evaluation_report.yml"
        if not report_path.is_file():
            if not (study_dir / "study_manifest.yml").is_file():
                continue
            context = _incomplete_study_context(study_dir)
            if task_id:
                if context["task_id"] and context["task_id"] != task_id:
                    continue
                if not context["task_id"] and not study_id_prefix:
                    continue
            if (
                selected_architectures
                and context["architecture"]
                and context["architecture"] not in selected_architectures
            ):
                continue
            incomplete.append(
                {
                    "study_id": study_dir.name,
                    "task_id": context["task_id"],
                    "architecture": context["architecture"],
                    "reason": "agent_evaluation_report.yml not found",
                    "study_manifest_path": str(study_dir / "study_manifest.yml"),
                }
            )
            continue
        try:
            row = load_experiment_run(report_path, study_root)
        except (OSError, ValueError, yaml.YAMLError) as error:
            skipped.append({"path": str(report_path), "reason": str(error)})
            incomplete.append(
                {
                    "study_id": study_dir.name,
                    "task_id": "",
                    "architecture": "",
                    "reason": "agent evaluation report is unreadable",
                    "study_manifest_path": str(study_dir / "study_manifest.yml"),
                }
            )
            continue
        if task_id and row["task_id"] != task_id:
            continue
        if selected_architectures and row["architecture"] not in selected_architectures:
            continue
        if row.get("evaluation_stale"):
            incomplete.append(
                {
                    "study_id": study_dir.name,
                    "task_id": str(row["task_id"]),
                    "architecture": str(row["architecture"]),
                    "reason": str(row.get("stale_reason") or "agent evaluation is stale"),
                    "study_manifest_path": str(study_dir / "study_manifest.yml"),
                }
            )
            continue
        rows.append(row)
    return rows, skipped, incomplete


def _numeric_values(rows: Iterable[Mapping[str, Any]], field: str) -> list[float]:
    values: list[float] = []
    for row in rows:
        value = row.get(field)
        if isinstance(value, bool) or value is None:
            continue
        if isinstance(value, (int, float)):
            values.append(float(value))
    return values


def _mean(rows: Sequence[Mapping[str, Any]], field: str) -> float | None:
    values = _numeric_values(rows, field)
    return round(statistics.fmean(values), 3) if values else None


def _median(rows: Sequence[Mapping[str, Any]], field: str) -> float | None:
    values = _numeric_values(rows, field)
    return round(statistics.median(values), 3) if values else None


def _population_sd(rows: Sequence[Mapping[str, Any]], field: str) -> float | None:
    values = _numeric_values(rows, field)
    return round(statistics.pstdev(values), 3) if len(values) > 1 else None


def summarize_groups(rows: Sequence[Mapping[str, Any]]) -> list[dict[str, Any]]:
    groups: dict[tuple[str, str], list[Mapping[str, Any]]] = {}
    for row in rows:
        key = (str(row["task_id"]), str(row["architecture"]))
        groups.setdefault(key, []).append(row)

    summaries: list[dict[str, Any]] = []
    for (task_id, architecture), members in sorted(groups.items()):
        trial_count = len(members)
        model_passes = sum(row.get("model_passed") is True for row in members)
        agent_passes = sum(row.get("agent_passed") is True for row in members)
        failure_counts: dict[str, int] = {}
        for row in members:
            for category in str(row.get("failure_categories", "")).split(";"):
                if category:
                    failure_counts[category] = failure_counts.get(category, 0) + 1
        summaries.append(
            {
                "task_id": task_id,
                "architecture": architecture,
                "trials": trial_count,
                "model_passes": model_passes,
                "model_pass_rate": round(model_passes / trial_count, 4),
                "agent_passes": agent_passes,
                "agent_pass_rate": round(agent_passes / trial_count, 4),
                "active_calls_mean": _mean(members, "active_tool_calls"),
                "active_calls_median": _median(members, "active_tool_calls"),
                "passive_calls_mean": _mean(members, "passive_tool_calls"),
                "budgeted_calls_mean": _mean(members, "budgeted_tool_calls"),
                "elapsed_seconds_mean": _mean(members, "elapsed_seconds"),
                "elapsed_seconds_median": _median(members, "elapsed_seconds"),
                "elapsed_seconds_population_sd": _population_sd(
                    members, "elapsed_seconds"
                ),
                "invalid_tool_calls_total": int(
                    sum(_numeric_values(members, "invalid_tool_calls"))
                ),
                "duplicate_role_calls_total": int(
                    sum(_numeric_values(members, "duplicate_role_calls"))
                ),
                "false_safe_claims_total": int(
                    sum(_numeric_values(members, "false_safe_claims"))
                ),
                "failure_counts": failure_counts,
            }
        )
    return summaries


def check_matched_conditions(rows: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    values_by_field: dict[str, list[str]] = {}
    mismatched: list[str] = []
    missing: list[str] = []
    for field in MATCH_FIELDS:
        values = sorted({str(row.get(field, "")).strip() for row in rows})
        values_by_field[field] = values
        if "" in values:
            missing.append(field)
        if len(values) != 1:
            mismatched.append(field)
    return {
        "matched": bool(rows) and not mismatched and not missing,
        "fields": values_by_field,
        "mismatched_fields": mismatched,
        "missing_fields": missing,
        "condition_signatures": sorted(
            {str(row.get("condition_signature", "")) for row in rows}
        ),
    }


def build_experiment_summary(
    rows: Sequence[Mapping[str, Any]],
    *,
    study_root: Path,
    task_id: str | None,
    skipped: Sequence[Mapping[str, str]],
    study_id_prefix: str | None = None,
    incomplete: Sequence[Mapping[str, str]] = (),
    required_architectures: Sequence[str] = (),
    expected_trials_per_architecture: int | None = None,
) -> dict[str, Any]:
    architecture_counts = {
        architecture: sum(row.get("architecture") == architecture for row in rows)
        for architecture in required_architectures
    }
    trial_target_met = expected_trials_per_architecture is None or all(
        count == expected_trials_per_architecture
        for count in architecture_counts.values()
    )
    matched_conditions = check_matched_conditions(rows)
    ready_for_comparison = (
        matched_conditions["matched"]
        and not incomplete
        and trial_target_met
        and (
            not required_architectures
            or set(architecture_counts) == set(required_architectures)
        )
    )
    return {
        "schema_version": SUMMARY_SCHEMA_VERSION,
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "study_root": str(study_root.resolve()),
        "task_id_filter": task_id,
        "study_id_prefix_filter": study_id_prefix,
        "trial_count": len(rows),
        "ready_for_comparison": ready_for_comparison,
        "completion": {
            "expected_trials_per_architecture": expected_trials_per_architecture,
            "required_architectures": list(required_architectures),
            "evaluated_trials_by_architecture": architecture_counts,
            "trial_target_met": trial_target_met,
            "incomplete_study_count": len(incomplete),
        },
        "matched_conditions": matched_conditions,
        "groups": summarize_groups(rows),
        "runs": [dict(row) for row in rows],
        "incomplete_studies": [dict(item) for item in incomplete],
        "skipped_reports": [dict(item) for item in skipped],
    }


def _format(value: Any) -> str:
    if value is None:
        return "n/a"
    if isinstance(value, float):
        return f"{value:.3f}".rstrip("0").rstrip(".")
    return str(value)


def render_markdown(summary: Mapping[str, Any]) -> str:
    matched = summary["matched_conditions"]
    lines = [
        "# HOPE agent experiment summary",
        "",
        f"- Trials: {summary['trial_count']}",
        f"- Task filter: `{summary.get('task_id_filter') or 'all'}`",
        f"- Study ID prefix: `{summary.get('study_id_prefix_filter') or 'all'}`",
        f"- Ready for comparison: **{'yes' if summary['ready_for_comparison'] else 'no'}**",
        f"- Matched conditions: **{'yes' if matched['matched'] else 'no'}**",
        f"- Incomplete studies: {summary['completion']['incomplete_study_count']}",
        "",
    ]
    if not matched["matched"]:
        lines.extend(
            [
                f"- Mismatched fields: `{', '.join(matched['mismatched_fields']) or 'none'}`",
                f"- Missing fields: `{', '.join(matched['missing_fields']) or 'none'}`",
                "",
            ]
        )
    lines.extend(
        [
            "## Architecture summary",
            "",
            "| Architecture | Trials | Model pass | Agent pass | Active calls (mean) | "
            "Passive calls (mean) | Elapsed seconds (mean) | False-safe claims |",
            "|---|---:|---:|---:|---:|---:|---:|---:|",
        ]
    )
    for group in summary["groups"]:
        lines.append(
            "| {architecture} | {trials} | {model_passes}/{trials} | "
            "{agent_passes}/{trials} | {active} | {passive} | {elapsed} | {false_safe} |".format(
                architecture=group["architecture"],
                trials=group["trials"],
                model_passes=group["model_passes"],
                agent_passes=group["agent_passes"],
                active=_format(group["active_calls_mean"]),
                passive=_format(group["passive_calls_mean"]),
                elapsed=_format(group["elapsed_seconds_mean"]),
                false_safe=group["false_safe_claims_total"],
            )
        )
    lines.extend(
        [
            "",
            "## Individual trials",
            "",
            "| Study | Architecture | Model | Agent | Active | Passive | Elapsed (s) | Failures |",
            "|---|---|---:|---:|---:|---:|---:|---|",
        ]
    )
    for row in summary["runs"]:
        lines.append(
            "| `{study}` | {architecture} | {model} | {agent} | {active} | "
            "{passive} | {elapsed} | {failures} |".format(
                study=row["study_id"],
                architecture=row["architecture"],
                model="pass" if row["model_passed"] else "fail",
                agent="pass" if row["agent_passed"] else "fail",
                active=_format(row.get("active_tool_calls")),
                passive=_format(row.get("passive_tool_calls")),
                elapsed=_format(row.get("elapsed_seconds")),
                failures=row.get("failure_categories") or "none",
            )
        )
    if summary["incomplete_studies"]:
        lines.extend(["", "## Incomplete studies", ""])
        for item in summary["incomplete_studies"]:
            lines.append(f"- `{item['study_id']}`: {item['reason']}")
    if summary["skipped_reports"]:
        lines.extend(["", "## Skipped reports", ""])
        for item in summary["skipped_reports"]:
            lines.append(f"- `{item['path']}`: {item['reason']}")
    lines.append("")
    return "\n".join(lines)


def write_experiment_summary(summary: Mapping[str, Any], output_dir: Path) -> dict[str, str]:
    output_dir.mkdir(parents=True, exist_ok=True)
    yaml_path = output_dir / "agent_experiment_summary.yml"
    runs_csv_path = output_dir / "agent_experiment_runs.csv"
    groups_csv_path = output_dir / "agent_experiment_groups.csv"
    markdown_path = output_dir / "agent_experiment_summary.md"

    yaml_path.write_text(
        yaml.safe_dump(dict(summary), sort_keys=False, allow_unicode=True),
        encoding="utf-8",
    )
    with runs_csv_path.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(RUN_FIELDS))
        writer.writeheader()
        writer.writerows(
            {field: row.get(field) for field in RUN_FIELDS}
            for row in summary["runs"]
        )
    group_fields = [
        "task_id",
        "architecture",
        "trials",
        "model_passes",
        "model_pass_rate",
        "agent_passes",
        "agent_pass_rate",
        "active_calls_mean",
        "active_calls_median",
        "passive_calls_mean",
        "budgeted_calls_mean",
        "elapsed_seconds_mean",
        "elapsed_seconds_median",
        "elapsed_seconds_population_sd",
        "invalid_tool_calls_total",
        "duplicate_role_calls_total",
        "false_safe_claims_total",
        "failure_counts",
    ]
    with groups_csv_path.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=group_fields)
        writer.writeheader()
        for group in summary["groups"]:
            row = dict(group)
            row["failure_counts"] = json.dumps(row["failure_counts"], sort_keys=True)
            writer.writerow(row)
    markdown_path.write_text(render_markdown(summary), encoding="utf-8")
    return {
        "summary_yaml": str(yaml_path),
        "runs_csv": str(runs_csv_path),
        "groups_csv": str(groups_csv_path),
        "summary_markdown": str(markdown_path),
    }


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Aggregate HOPE holistic-agent evaluation reports."
    )
    parser.add_argument("--study-root", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--task-id")
    parser.add_argument(
        "--study-id-prefix",
        help="Include only studies whose IDs begin with this prefix.",
    )
    parser.add_argument(
        "--architecture",
        action="append",
        choices=("single_agent", "centralized_roles"),
        help="Architecture to include; repeat to include more than one.",
    )
    parser.add_argument(
        "--exclude-study-id",
        action="append",
        help="Exclude this exact study ID; repeat to exclude more than one.",
    )
    parser.add_argument(
        "--expected-trials-per-architecture",
        type=int,
        help="Require this many evaluated trials for each selected architecture.",
    )
    args = parser.parse_args(argv)
    if (
        args.expected_trials_per_architecture is not None
        and args.expected_trials_per_architecture < 1
    ):
        parser.error("--expected-trials-per-architecture must be positive.")
    rows, skipped, incomplete = discover_experiment_runs(
        args.study_root,
        task_id=args.task_id,
        architectures=args.architecture,
        study_id_prefix=args.study_id_prefix,
        excluded_study_ids=args.exclude_study_id,
    )
    if not rows:
        parser.error("No matching agent evaluation reports were found.")
    summary = build_experiment_summary(
        rows,
        study_root=args.study_root,
        task_id=args.task_id,
        skipped=skipped,
        study_id_prefix=args.study_id_prefix,
        incomplete=incomplete,
        required_architectures=args.architecture or (),
        expected_trials_per_architecture=args.expected_trials_per_architecture,
    )
    paths = write_experiment_summary(summary, args.output_dir)
    print(f"Summarized {len(rows)} trial(s).")
    print(f"Incomplete studies: {len(incomplete)}")
    print(f"Ready for comparison: {summary['ready_for_comparison']}")
    print(f"Matched conditions: {summary['matched_conditions']['matched']}")
    for name, path in paths.items():
        print(f"{name}: {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
