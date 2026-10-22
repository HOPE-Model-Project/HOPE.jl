from __future__ import annotations

import argparse
import hashlib
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml


PACKAGE_ROOT = Path(__file__).resolve().parents[1]
HOPE_REPO_ROOT = PACKAGE_ROOT.parents[1]
DEFAULT_MANIFEST = PACKAGE_ROOT / "powermcp_sync.yml"
SYNC_RECORD = "SYNCED_FROM_HOPE.yml"


@dataclass(frozen=True)
class SyncDifference:
    relative_path: Path
    state: str


def _read_manifest(path: Path) -> dict[str, Any]:
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError(f"Sync manifest must contain a mapping: {path}")
    if data.get("schema_version") != 1:
        raise ValueError(f"Unsupported sync manifest schema: {data.get('schema_version')}")
    return data


def _safe_relative_path(value: object) -> Path:
    relative = Path(str(value))
    if relative.is_absolute() or not relative.parts or ".." in relative.parts:
        raise ValueError(f"Managed path must be a safe relative path: {value!r}")
    return relative


def _managed_files(manifest: dict[str, Any]) -> list[Path]:
    values = manifest.get("managed_files")
    if not isinstance(values, list) or not values:
        raise ValueError("Sync manifest must define at least one managed_files entry")
    files = [_safe_relative_path(value) for value in values]
    if len(files) != len(set(files)):
        raise ValueError("Sync manifest contains duplicate managed_files entries")
    return files


def _normalized_digest(path: Path) -> str:
    content = path.read_bytes().replace(b"\r\n", b"\n")
    return hashlib.sha256(content).hexdigest()


def compare_managed_files(
    source_root: Path,
    destination_root: Path,
    managed_files: list[Path],
) -> list[SyncDifference]:
    differences: list[SyncDifference] = []
    for relative in managed_files:
        source = source_root / relative
        destination = destination_root / relative
        if not source.is_file():
            raise FileNotFoundError(f"Managed upstream file does not exist: {source}")
        if not destination.is_file():
            differences.append(SyncDifference(relative, "missing"))
        elif _normalized_digest(source) != _normalized_digest(destination):
            differences.append(SyncDifference(relative, "different"))
    return differences


def _git_output(repo_root: Path, *arguments: str) -> str:
    completed = subprocess.run(
        ["git", "-C", str(repo_root), *arguments],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return completed.stdout.strip()


def _upstream_revision(source_root: Path, managed_files: list[Path]) -> str:
    relative_files = [
        str((source_root / relative).relative_to(HOPE_REPO_ROOT))
        for relative in managed_files
    ]
    dirty = _git_output(HOPE_REPO_ROOT, "status", "--porcelain", "--", *relative_files)
    if dirty:
        raise RuntimeError(
            "Managed HOPE MCP files have uncommitted changes. Commit them before syncing "
            "so PowerMCP can record an auditable upstream revision."
        )
    return _git_output(HOPE_REPO_ROOT, "rev-parse", "HEAD")


def _resolve_destination(power_mcp_root: Path, manifest: dict[str, Any]) -> Path:
    resolved_root = power_mcp_root.expanduser().resolve()
    if not (resolved_root / ".git").exists():
        raise ValueError(f"PowerMCP root is not a Git checkout: {resolved_root}")
    downstream = manifest.get("downstream")
    if not isinstance(downstream, dict) or not downstream.get("path"):
        raise ValueError("Sync manifest is missing downstream.path")
    destination = (resolved_root / _safe_relative_path(downstream["path"])).resolve()
    try:
        destination.relative_to(resolved_root)
    except ValueError as exc:
        raise ValueError(f"Destination escapes the PowerMCP checkout: {destination}") from exc
    return destination


def _write_sync_record(destination_root: Path, revision: str) -> None:
    record = {
        "schema_version": 1,
        "upstream_repository": "https://github.com/HOPE-Model-Project/HOPE.jl",
        "upstream_path": "tools/hope_mcp_server",
        "upstream_commit": revision,
        "sync_manifest": "tools/hope_mcp_server/powermcp_sync.yml",
    }
    path = destination_root / SYNC_RECORD
    path.write_text(yaml.safe_dump(record, sort_keys=False), encoding="utf-8", newline="\n")


def synchronize(
    power_mcp_root: Path,
    *,
    apply_changes: bool,
    manifest_path: Path = DEFAULT_MANIFEST,
) -> list[SyncDifference]:
    manifest = _read_manifest(manifest_path)
    managed_files = _managed_files(manifest)
    destination_root = _resolve_destination(power_mcp_root, manifest)
    differences = compare_managed_files(PACKAGE_ROOT, destination_root, managed_files)
    if not apply_changes or not differences:
        return differences

    revision = _upstream_revision(PACKAGE_ROOT, managed_files)
    for difference in differences:
        source = PACKAGE_ROOT / difference.relative_path
        destination = destination_root / difference.relative_path
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
    _write_sync_record(destination_root, revision)
    return differences


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Check or copy the HOPE-owned MCP core and tests into a local PowerMCP checkout. "
            "PowerMCP-owned transport and packaging files are never overwritten."
        )
    )
    parser.add_argument(
        "--powermcp-root",
        required=True,
        type=Path,
        help="Path to a local Power-Agent/PowerMCP Git checkout.",
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--apply",
        action="store_true",
        help="Copy changed managed files and write HOPE/SYNCED_FROM_HOPE.yml.",
    )
    mode.add_argument(
        "--check",
        action="store_true",
        help="Report drift without modifying PowerMCP (the default).",
    )
    return parser


def main() -> int:
    args = _parser().parse_args()
    try:
        differences = synchronize(
            args.powermcp_root,
            apply_changes=args.apply,
        )
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as exc:
        print(f"HOPE MCP sync failed: {exc}", file=sys.stderr)
        return 2

    if not differences:
        print("PowerMCP's managed HOPE MCP files match this HOPE checkout.")
        return 0

    action = "Synchronized" if args.apply else "Drift detected in"
    print(f"{action} {len(differences)} managed file(s):")
    for difference in differences:
        print(f"- {difference.state}: {difference.relative_path.as_posix()}")
    return 0 if args.apply else 1


if __name__ == "__main__":
    raise SystemExit(main())
