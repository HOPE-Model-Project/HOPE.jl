"""Build an isolated high-resolution Maryland GTEP-to-PCM coverage benchmark.

The canonical ModelCases inputs are copied, never edited.  The derived case
retains the 8,760-hour four-zone GTEP chronology and the 656-bus PCM network,
with 48 June warm-up hours plus all 744 July evaluation hours.  Two explicit
test-only assumptions make the otherwise unselected transfer paths observable:

* the 2 MW G1149 retirement candidate must operate at its full output if kept;
* OSM_L62255589 is derated to 500 MW in the derived PCM input, while its
  mapped 1,000 MW GTEP candidate receives a small coverage-test credit.

These assumptions test retirement and transmission realization.  They are not
planning recommendations and must not be copied into the canonical case.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import importlib.util
import json
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
MODELCASES = REPO_ROOT / "ModelCases"
CANONICAL_BUILDER = (
    MODELCASES
    / "tools"
    / "md_transmission_case_related"
    / "build_md_rps20_full8760_holistic_pair.py"
)
SOURCE_GTEP = MODELCASES / "MD_GTEP_RPS20_4zone_full8760_public_case"
SOURCE_PCM = MODELCASES / "MD_PCM_RPS20_transmission_full8760_public_case"
GTEP_DATA = "Data_MD_GTEP_RPS20_4zone_full8760_public"
PCM_DATA = "Data_MD_PCM_RPS20_transmission_full8760_public"
DEFAULT_WORKSPACE = (
    REPO_ROOT
    / "artifacts"
    / "benchmarks"
    / "md-rps20-transfer-coverage"
    / "run_workspace"
)

RETIREMENT_ASSET_ID = "G1149"
RETIREMENT_PMIN_MW = 2.0
UPGRADE_CORRIDOR_ID = "OSM_L62255589"
UPGRADE_SOURCE_RATING_MW = 500.0
UPGRADE_CAPACITY_MW = 1000.0
UPGRADE_TEST_CREDIT_MILLION_USD = -0.001


def read_csv(path: Path) -> tuple[list[str], list[dict[str, str]]]:
    with path.open(newline="", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames is None:
            raise ValueError(f"Missing CSV header: {path}")
        return list(reader.fieldnames), list(reader)


def write_csv(path: Path, fields: list[str], rows: list[dict[str, str]]) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def select_one(rows: list[dict[str, str]], column: str, value: str) -> dict[str, str]:
    selected = [row for row in rows if row.get(column) == value]
    if len(selected) != 1:
        raise ValueError(
            f"Expected one row with {column}={value!r}; found {len(selected)}"
        )
    return selected[0]


def load_canonical_builder():
    spec = importlib.util.spec_from_file_location(
        "hope_md_full8760_builder", CANONICAL_BUILDER
    )
    if spec is None or spec.loader is None:
        raise ImportError(f"Cannot import {CANONICAL_BUILDER}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def tree_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    excluded = {"output", "output_holistic", "plot_output", "backup", "debug_report"}
    files = [
        item
        for item in path.rglob("*")
        if item.is_file()
        and not any(
            part in excluded
            or part.startswith("output_")
            or part.startswith("output_backup")
            for part in item.relative_to(path).parts
        )
    ]
    for item in sorted(files, key=lambda value: value.relative_to(path).as_posix()):
        relative = item.relative_to(path).as_posix().encode("utf-8")
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        with item.open("rb") as handle:
            for block in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(block)
    return digest.hexdigest()


def yaml_scalar(value: object) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    return json.dumps(str(value))


def write_manifest(path: Path, values: dict[str, object]) -> None:
    lines = [f"{key}: {yaml_scalar(value)}" for key, value in values.items()]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def apply_retirement_stress(gtep_data: Path, pcm_data: Path) -> None:
    for path in (gtep_data / "gendata.csv", pcm_data / "gendata.csv"):
        fields, rows = read_csv(path)
        row = select_one(rows, "Asset_ID", RETIREMENT_ASSET_ID)
        if float(row["Pmax (MW)"]) != RETIREMENT_PMIN_MW:
            raise ValueError(f"Unexpected {RETIREMENT_ASSET_ID} Pmax in {path}")
        if path.parent == gtep_data and row.get("Flag_RET") != "1":
            raise ValueError(f"{RETIREMENT_ASSET_ID} is not retirement eligible")
        row["Pmin (MW)"] = str(RETIREMENT_PMIN_MW)
        write_csv(path, fields, rows)


def apply_transmission_stress(gtep_data: Path, pcm_data: Path) -> None:
    candidate_path = gtep_data / "linedata_candidate.csv"
    fields, rows = read_csv(candidate_path)
    candidate = select_one(rows, "Corridor_ID", UPGRADE_CORRIDOR_ID)
    if float(candidate["Forward Capacity (MW)"]) != UPGRADE_CAPACITY_MW:
        raise ValueError(f"Unexpected {UPGRADE_CORRIDOR_ID} candidate capacity")
    candidate["Cost (M$)"] = str(UPGRADE_TEST_CREDIT_MILLION_USD)
    write_csv(candidate_path, fields, rows)

    branch_path = pcm_data / "branchdata.csv"
    fields, rows = read_csv(branch_path)
    branch = select_one(rows, "Corridor_ID", UPGRADE_CORRIDOR_ID)
    branch["Forward Capacity (MW)"] = str(UPGRADE_SOURCE_RATING_MW)
    branch["Reverse Capacity (MW)"] = str(UPGRADE_SOURCE_RATING_MW)
    write_csv(branch_path, fields, rows)


def write_acceptance(path: Path) -> None:
    path.write_text(
        """schema_version: 1
require_all: true
required_settings:
  gtep:
    clean_energy_policy: 2
    planning_reserve_mode: 1
    operation_reserve_mode: 1
    holistic_spatial_basis: zone
    transmission_expansion: 1
  pcm:
    clean_energy_policy: 2
    unit_commitment: 1
    operation_reserve_mode: 2
    network_model: 2
thresholds:
  retired_generation_mw:
    minimum: 1.999
  new_generation_mw:
    minimum: 0.001
  new_storage_power_mw:
    minimum: 0.001
  new_storage_energy_mwh:
    minimum: 0.001
  line_forward_added_mw:
    minimum: 999.999
  line_reverse_added_mw:
    minimum: 999.999
  pcm_new_generation_dispatch_mwh:
    minimum: 0.001
  pcm_new_storage_discharge_mwh:
    minimum: 0.001
  pcm_upgraded_line_max_abs_flow_mw:
    minimum: 0.001
  pcm_upgraded_line_flow_above_source_mw:
    minimum: 0.001
  operational_template_assets:
    minimum: 1
  new_thermal_generation_all_uc:
    minimum: 1
  gtep_operating_reserve_mwh:
    minimum: 0.001
  pcm_operating_reserve_mwh:
    minimum: 0.001
  gtep_rps_slack_mwh:
    maximum: 0.000001
  pcm_rps_slack_mwh:
    maximum: 0.000001
  pcm_load_shedding_mwh:
    maximum: 0.000001
""",
        encoding="utf-8",
    )


def write_scenario(path: Path) -> None:
    path.write_text(
        f"""schema_version: 1
benchmark_id: md-rps20-transfer-coverage
purpose: internal GTEP-to-PCM transfer coverage; not an end-user planning case
canonical_gtep_case: {SOURCE_GTEP.as_posix()}
canonical_pcm_case: {SOURCE_PCM.as_posix()}
gtep_hours: 8760
pcm_warmup_hours: 48
pcm_evaluation_month: 7
pcm_evaluation_hours: 744
assumptions:
  retirement:
    asset_id: {RETIREMENT_ASSET_ID}
    retained_minimum_output_mw: {RETIREMENT_PMIN_MW}
    interpretation: test-only retained-unit operating requirement that makes retirement observable
  transmission:
    corridor_id: {UPGRADE_CORRIDOR_ID}
    derived_pcm_source_rating_mw: {UPGRADE_SOURCE_RATING_MW}
    candidate_addition_mw: {UPGRADE_CAPACITY_MW}
    candidate_test_credit_million_usd: {UPGRADE_TEST_CREDIT_MILLION_USD}
    interpretation: test-only corridor stress and selection incentive; not a planning-cost assumption
prohibitions:
  - do not copy these forcing assumptions into the canonical Maryland benchmark
  - do not interpret the selected retirement or upgrade as a planning recommendation
""",
        encoding="utf-8",
    )


def write_runner(path: Path) -> None:
    path.write_text(
        r'''using Dates
using HOPE
using YAML

const ROOT = @__DIR__
const GTEP_CASE = joinpath(ROOT, "gtep_case")
const PCM_CASE = joinpath(ROOT, "pcm_case")
const MANIFEST_PATH = joinpath(ROOT, "run_manifest.yml")

function save_manifest(manifest)
    manifest["updated_at_utc"] = string(Dates.now(Dates.UTC))
    open(MANIFEST_PATH, "w") do io
        YAML.write(io, manifest)
    end
end

manifest = YAML.load_file(MANIFEST_PATH)
manifest["status"] = "RUNNING"
save_manifest(manifest)

try
    result = HOPE.run_hope_holistic(
        GTEP_CASE,
        PCM_CASE;
        solver_override = "gurobi",
    )
    report = HOPE.write_holistic_coverage_report(
        result,
        joinpath(PCM_CASE, "Settings", "HOPE_holistic_acceptance.yml");
        require_all = true,
    )
    manifest["status"] = "PUBLISHED"
    manifest["coverage_all_passed"] = report["all_passed"]
    manifest["gtep_case_path"] = GTEP_CASE
    manifest["pcm_case_path"] = PCM_CASE
    manifest["pcm_output_path"] = result["pcm_output_path"]
    save_manifest(manifest)
    println("Holistic coverage passed: ", report["all_passed"])
catch err
    manifest["status"] = "FAILED"
    manifest["error"] = sprint(showerror, err)
    save_manifest(manifest)
    rethrow()
end
''',
        encoding="utf-8",
    )


def build(workspace: Path) -> None:
    if workspace.exists():
        raise FileExistsError(
            f"Workspace already exists: {workspace}. Choose a new --workspace path."
        )
    for required in (CANONICAL_BUILDER, SOURCE_GTEP, SOURCE_PCM):
        if not required.exists():
            raise FileNotFoundError(required)

    builder = load_canonical_builder()
    builder.validate_generated_pair(
        SOURCE_GTEP / GTEP_DATA,
        SOURCE_PCM / PCM_DATA,
    )
    builder.materialize_pcm_month_validation(workspace, 7, 48)

    gtep_case = workspace / "gtep_case"
    pcm_case = workspace / "pcm_case"
    gtep_data = gtep_case / GTEP_DATA
    pcm_data = pcm_case / PCM_DATA
    apply_retirement_stress(gtep_data, pcm_data)
    apply_transmission_stress(gtep_data, pcm_data)
    write_acceptance(pcm_case / "Settings" / "HOPE_holistic_acceptance.yml")
    write_scenario(workspace / "coverage_scenario.yml")
    write_runner(workspace / "run_pair.jl")

    manifest = {
        "schema_version": 1,
        "request_id": "md-rps20-transfer-coverage-v1",
        "status": "PREPARED",
        "solver": "gurobi",
        "gtep_source_path": str(gtep_case.resolve()),
        "pcm_source_path": str(pcm_case.resolve()),
        "gtep_case_path": str(gtep_case.resolve()),
        "pcm_case_path": str(pcm_case.resolve()),
        "gtep_source_sha256": tree_sha256(gtep_case),
        "pcm_source_sha256": tree_sha256(pcm_case),
        "gtep_hours": 8760,
        "pcm_hours": 792,
        "pcm_warmup_hours": 48,
        "pcm_evaluation_hours": 744,
    }
    write_manifest(workspace / "run_manifest.yml", manifest)
    print(f"Prepared transfer-coverage benchmark: {workspace}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--workspace",
        type=Path,
        default=DEFAULT_WORKSPACE,
        help="New destination for the isolated derived run workspace.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    build(args.workspace.resolve())


if __name__ == "__main__":
    main()
