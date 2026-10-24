from __future__ import annotations

import csv
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import yaml

PACKAGE_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PACKAGE_ROOT / "src"))

from hope_mcp_server.core import (  # noqa: E402
    hope_audit_holistic_study,
    hope_holistic_study_status,
    hope_launch_holistic_study,
    hope_prepare_holistic_study,
)


class HolisticMultiAgentProtocolTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.runs = self.root / "agent-runs"
        self.studies = self.root / "agent-studies"
        self.gtep = self._write_case("gtep_case", "GTEP")
        self.pcm = self._write_case("pcm_case", "PCM")
        self.env_patch = mock.patch.dict(
            "os.environ",
            {
                "HOPE_REPO_ROOT": str(self.root),
                "HOPE_MODELCASES_PATH": str(self.root / "ModelCases"),
                "HOPE_AGENT_RUNS_ROOT": str(self.runs),
                "HOPE_AGENT_STUDIES_ROOT": str(self.studies),
            },
            clear=False,
        )
        self.env_patch.start()

    def tearDown(self) -> None:
        self.env_patch.stop()
        self.temporary.cleanup()

    def _write_case(self, name: str, mode: str) -> Path:
        case = self.root / "ModelCases" / name
        (case / "Settings").mkdir(parents=True)
        (case / "Data").mkdir()
        (case / "Settings" / "HOPE_model_settings.yml").write_text(
            f"model_mode: {mode}\nsolver: highs\nDataCase: Data/\n",
            encoding="utf-8",
        )
        (case / "Data" / "input.csv").write_text(
            "name,value\ntest,1\n",
            encoding="utf-8",
        )
        return case

    def _prepare_and_launch(self, study_id: str = "multi-agent-test") -> dict:
        prepared = hope_prepare_holistic_study(
            "gtep_case",
            "pcm_case",
            study_id=study_id,
            solver="highs",
            agent_label="coordinator-A",
        )
        self.assertTrue(prepared["ok"], prepared)
        run_manifest = self.runs / study_id / "run_manifest.yml"
        with mock.patch(
            "hope_mcp_server.core.hope_run_holistic",
            return_value={
                "ok": True,
                "request_id": study_id,
                "job_id": "job-test",
                "status": "running",
                "reused": False,
                "manifest_path": str(run_manifest),
            },
        ):
            launched = hope_launch_holistic_study(study_id, agent_label="executor-B")
        self.assertTrue(launched["ok"], launched)
        self.assertEqual(launched["status"], "running")
        return prepared

    def _publish_fake_run(self, study_id: str, *, checks_pass: bool = True) -> None:
        study_path = self.studies / study_id / "study_manifest.yml"
        study = yaml.safe_load(study_path.read_text(encoding="utf-8"))
        workspace = self.runs / study_id
        output = workspace / "pcm_case" / "output"
        realized = output / "realized_inputs"
        realized.mkdir(parents=True)
        (realized / "handoff_contract.yml").write_text(
            yaml.safe_dump({"schema_version": 1, "valid": True}),
            encoding="utf-8",
        )
        (realized / "transfer_reconciliation.yml").write_text(
            yaml.safe_dump({"schema_version": 1, "valid": True}),
            encoding="utf-8",
        )
        coverage_path = output / "holistic_coverage.yml"
        coverage_path.write_text(
            yaml.safe_dump({"schema_version": 1, "all_passed": checks_pass}),
            encoding="utf-8",
        )
        checks_path = output / "holistic_acceptance_checks.csv"
        with checks_path.open("w", encoding="utf-8", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=["Check", "Passed"])
            writer.writeheader()
            writer.writerow({"Check": "test", "Passed": str(checks_pass).lower()})
        run_manifest = {
            "schema_version": 1,
            "operation": "GTEP-PCM",
            "request_id": study_id,
            "request_sha256": study["request_sha256"],
            "gtep_case_id": study["gtep_case_id"],
            "pcm_case_id": study["pcm_case_id"],
            "solver": study["solver"],
            "gtep_source_sha256": study["gtep_source_sha256"],
            "pcm_source_sha256": study["pcm_source_sha256"],
            "status": "PUBLISHED",
            "workspace_path": str(workspace),
            "manifest_path": str(workspace / "run_manifest.yml"),
            "result": {
                "pcm_output_path": str(output),
                "handoff_valid": True,
                "transfer_valid": True,
                "coverage_evaluated": True,
                "coverage_all_passed": checks_pass,
                "coverage_paths": {
                    "coverage_yaml": str(coverage_path),
                    "checks_csv": str(checks_path),
                },
            },
        }
        (workspace / "run_manifest.yml").write_text(
            yaml.safe_dump(run_manifest, sort_keys=False),
            encoding="utf-8",
        )

    def test_coordinator_prepare_is_idempotent_and_conflicts_are_rejected(self) -> None:
        first = hope_prepare_holistic_study(
            "gtep_case", "pcm_case", study_id="multi-agent-idempotent", solver="highs"
        )
        second = hope_prepare_holistic_study(
            "ModelCases/gtep_case",
            "ModelCases/pcm_case",
            study_id="multi-agent-idempotent",
            solver="highs",
        )
        conflict = hope_prepare_holistic_study(
            "gtep_case", "pcm_case", study_id="multi-agent-idempotent", solver="gurobi"
        )
        self.assertTrue(first["ok"], first)
        self.assertTrue(second["ok"], second)
        self.assertTrue(second["reused"])
        self.assertFalse(conflict["ok"])
        self.assertEqual(conflict["error_type"], "study_id_conflict")

    def test_executor_rejects_source_drift_before_launch(self) -> None:
        prepared = hope_prepare_holistic_study(
            "gtep_case", "pcm_case", study_id="multi-agent-drift", solver="highs"
        )
        self.assertTrue(prepared["ok"], prepared)
        (self.gtep / "Data" / "input.csv").write_text(
            "name,value\ntest,2\n",
            encoding="utf-8",
        )
        with mock.patch("hope_mcp_server.core.hope_run_holistic") as launch:
            result = hope_launch_holistic_study("multi-agent-drift")
        self.assertFalse(result["ok"])
        self.assertEqual(result["error_type"], "study_source_drift")
        launch.assert_not_called()

    def test_status_recovers_receipt_when_run_publishes_after_launch_write_error(self) -> None:
        prepared = hope_prepare_holistic_study(
            "gtep_case",
            "pcm_case",
            study_id="multi-agent-recovery",
            solver="highs",
            agent_label="coordinator-A",
        )
        self.assertTrue(prepared["ok"], prepared)
        study_path = self.studies / "multi-agent-recovery" / "study_manifest.yml"
        study = yaml.safe_load(study_path.read_text(encoding="utf-8"))
        study["status"] = "LAUNCHING"
        study["receipts"]["executor"] = {
            "agent_label": "executor-B",
            "started_at_unix": 1.0,
            "request_sha256": study["request_sha256"],
        }
        study_path.write_text(yaml.safe_dump(study, sort_keys=False), encoding="utf-8")
        self._publish_fake_run("multi-agent-recovery")

        recovered = hope_holistic_study_status("multi-agent-recovery")
        self.assertTrue(recovered["ok"], recovered)
        self.assertEqual(recovered["status"], "ready_for_audit")
        receipt = recovered["receipts"]["executor"]
        self.assertTrue(receipt["run_ok"])
        self.assertIn("completed_at_unix", receipt)
        self.assertTrue(receipt["run_manifest_path"].endswith("run_manifest.yml"))

    def test_separate_roles_publish_an_accepted_audit_receipt(self) -> None:
        self._prepare_and_launch("multi-agent-accepted")
        self._publish_fake_run("multi-agent-accepted")
        status = hope_holistic_study_status("multi-agent-accepted")
        self.assertTrue(status["ok"], status)
        self.assertEqual(status["status"], "ready_for_audit")

        audited = hope_audit_holistic_study(
            "multi-agent-accepted",
            agent_label="auditor-C",
        )
        self.assertTrue(audited["ok"], audited)
        self.assertEqual(audited["status"], "accepted")
        self.assertTrue(audited["audit"]["accepted"])
        self.assertEqual(set(audited["receipts"]), {"coordinator", "executor", "auditor"})
        self.assertTrue(Path(audited["audit"]["audit_report_path"]).is_file())

        repeated = hope_audit_holistic_study("multi-agent-accepted")
        self.assertTrue(repeated["ok"], repeated)
        self.assertTrue(repeated["reused"])

        relaunched = hope_launch_holistic_study("multi-agent-accepted")
        self.assertTrue(relaunched["ok"], relaunched)
        self.assertTrue(relaunched["reused"])
        self.assertEqual(relaunched["status"], "accepted")

    def test_auditor_rejects_failed_acceptance_evidence(self) -> None:
        self._prepare_and_launch("multi-agent-rejected")
        self._publish_fake_run("multi-agent-rejected", checks_pass=False)
        audited = hope_audit_holistic_study("multi-agent-rejected")
        self.assertTrue(audited["ok"], audited)
        self.assertEqual(audited["status"], "rejected")
        self.assertFalse(audited["audit"]["accepted"])


if __name__ == "__main__":
    unittest.main()
