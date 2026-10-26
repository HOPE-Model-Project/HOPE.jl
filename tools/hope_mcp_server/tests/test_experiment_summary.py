from __future__ import annotations

import csv
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

PACKAGE_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PACKAGE_ROOT / "src"))

from hope_mcp_server.experiment_summary import (  # noqa: E402
    build_experiment_summary,
    check_matched_conditions,
    discover_experiment_runs,
    render_markdown,
    summarize_groups,
    write_experiment_summary,
)


class ExperimentSummaryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.study_root = Path(self.temporary.name) / "agent_studies"
        self.study_root.mkdir()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_formal_protocol_freezes_exact_claim_keys_and_study_prefix(self) -> None:
        protocol = yaml.safe_load(
            (PACKAGE_ROOT / "experiments" / "md_rps20_v3_matched_trials.yml").read_text(
                encoding="utf-8"
            )
        )
        required = {
            "study_accepted",
            "run_published",
            "audit_accepted",
            "all_acceptance_checks_passed",
        }
        self.assertEqual(set(protocol["required_claims"]), required)
        for prompt_name in ("single_agent", "auditor"):
            prompt = protocol["prompt_templates"][prompt_name]
            for claim in required:
                self.assertIn(claim, prompt)
        for architecture in protocol["architectures"]:
            self.assertTrue(
                architecture["study_id_template"].startswith("claude-md-v3formal-")
            )
            self.assertEqual(len(architecture["formal_replicates"]), 5)
        architectures = {
            item["architecture"]: item for item in protocol["architectures"]
        }
        self.assertEqual(
            architectures["single_agent"]["formal_replicates"],
            ["02", "03", "04", "06", "07"],
        )
        self.assertEqual(
            architectures["centralized_roles"]["formal_replicates"],
            ["01", "02", "03", "04", "05"],
        )
        self.assertIn(
            "claude-md-v3exp-single-20261025-r01",
            protocol["pilot_studies_excluded_from_formal_repetitions"],
        )
        self.assertIn(
            "claude-md-v3formal-single-20261025-r01",
            protocol["pilot_studies_excluded_from_formal_repetitions"],
        )
        self.assertIn(
            "claude-md-v3formal-single-20261025-r05",
            protocol["pilot_studies_excluded_from_formal_repetitions"],
        )

    def _write_trial(
        self,
        study_id: str,
        architecture: str,
        *,
        elapsed: float,
        active_calls: int,
        agent_passed: bool = True,
        request_sha256: str = "request-hash",
        malformed: bool = False,
    ) -> None:
        study_dir = self.study_root / study_id
        study_dir.mkdir()
        if malformed:
            (study_dir / "agent_evaluation_report.yml").write_text(
                "- not\n- a\n- mapping\n", encoding="utf-8"
            )
            return
        manifest = {
            "study_id": study_id,
            "solver": "gurobi",
            "request_sha256": request_sha256,
            "gtep_source_sha256": "gtep-hash",
            "pcm_source_sha256": "pcm-hash",
        }
        report = {
            "schema_version": 3,
            "study_id": study_id,
            "task_id": "md-rps20-annual-gtep-july-pcm-v3",
            "architecture": architecture,
            "model_passed": True,
            "agent_passed": agent_passed,
            "metrics": {
                "total_tool_calls": active_calls + 20,
                "active_tool_calls": active_calls,
                "passive_tool_calls": 20,
                "budgeted_tool_calls": active_calls,
                "invalid_tool_calls": 0,
                "duplicate_role_calls": 0,
                "status_poll_calls": 1,
                "wait_calls": 20,
                "elapsed_seconds": elapsed,
                "verified_claims": 4,
                "total_claims": 4,
                "false_safe_claims": 0,
            },
            "failures": []
            if agent_passed
            else [{"category": "task_verification", "details": {}}],
        }
        (study_dir / "study_manifest.yml").write_text(
            yaml.safe_dump(manifest), encoding="utf-8"
        )
        (study_dir / "agent_evaluation_report.yml").write_text(
            yaml.safe_dump(report), encoding="utf-8"
        )

    def test_discovers_filters_and_summarizes_matched_trials(self) -> None:
        self._write_trial("single-01", "single_agent", elapsed=900.0, active_calls=5)
        self._write_trial("single-02", "single_agent", elapsed=1100.0, active_calls=7)
        self._write_trial(
            "multi-01", "centralized_roles", elapsed=1000.0, active_calls=6
        )
        self._write_trial("broken", "single_agent", elapsed=0.0, active_calls=0, malformed=True)

        rows, skipped, incomplete = discover_experiment_runs(
            self.study_root,
            task_id="md-rps20-annual-gtep-july-pcm-v3",
        )
        self.assertEqual(len(rows), 3)
        self.assertEqual(len(skipped), 1)
        self.assertEqual(len(incomplete), 1)
        self.assertTrue(check_matched_conditions(rows)["matched"])

        groups = summarize_groups(rows)
        single = next(item for item in groups if item["architecture"] == "single_agent")
        self.assertEqual(single["trials"], 2)
        self.assertEqual(single["model_pass_rate"], 1.0)
        self.assertEqual(single["agent_pass_rate"], 1.0)
        self.assertEqual(single["active_calls_mean"], 6.0)
        self.assertEqual(single["elapsed_seconds_mean"], 1000.0)
        self.assertEqual(single["elapsed_seconds_population_sd"], 100.0)

    def test_detects_unmatched_request_hashes(self) -> None:
        self._write_trial("single-01", "single_agent", elapsed=900.0, active_calls=5)
        self._write_trial(
            "multi-01",
            "centralized_roles",
            elapsed=900.0,
            active_calls=5,
            request_sha256="different-request",
        )
        rows, _, _ = discover_experiment_runs(self.study_root)
        matched = check_matched_conditions(rows)
        self.assertFalse(matched["matched"])
        self.assertIn("request_sha256", matched["mismatched_fields"])
        self.assertEqual(len(matched["condition_signatures"]), 2)

    def test_filters_architecture(self) -> None:
        self._write_trial("single-01", "single_agent", elapsed=900.0, active_calls=5)
        self._write_trial(
            "multi-01", "centralized_roles", elapsed=900.0, active_calls=5
        )
        rows, _, _ = discover_experiment_runs(
            self.study_root, architectures=["single_agent"]
        )
        self.assertEqual([row["study_id"] for row in rows], ["single-01"])

    def test_filters_formal_study_prefix(self) -> None:
        self._write_trial("pilot-multi-01", "centralized_roles", elapsed=900.0, active_calls=5)
        self._write_trial("formal-single-01", "single_agent", elapsed=900.0, active_calls=5)
        self._write_trial(
            "formal-multi-01", "centralized_roles", elapsed=900.0, active_calls=5
        )
        rows, _, _ = discover_experiment_runs(
            self.study_root, study_id_prefix="formal-"
        )
        self.assertEqual(
            [row["study_id"] for row in rows],
            ["formal-multi-01", "formal-single-01"],
        )

    def test_explicit_exclusion_removes_confounded_formal_trial(self) -> None:
        self._write_trial("formal-bad-01", "single_agent", elapsed=1.0, active_calls=3)
        self._write_trial("formal-good-01", "single_agent", elapsed=2.0, active_calls=4)

        rows, skipped, incomplete = discover_experiment_runs(
            self.study_root,
            study_id_prefix="formal-",
            excluded_study_ids=["formal-bad-01"],
        )

        self.assertEqual([row["study_id"] for row in rows], ["formal-good-01"])
        self.assertEqual(incomplete, [])
        self.assertEqual(len(skipped), 1)
        self.assertIn("explicitly excluded", skipped[0]["reason"])

    def test_stale_evaluation_is_incomplete_and_excluded_from_results(self) -> None:
        self._write_trial("formal-stale-01", "single_agent", elapsed=1.0, active_calls=3)
        study_dir = self.study_root / "formal-stale-01"
        report_path = study_dir / "agent_evaluation_report.yml"
        report = yaml.safe_load(report_path.read_text(encoding="utf-8"))
        report["authoritative_artifacts"] = {
            "study_status": "ACCEPTED",
            "request_sha256": "request-hash",
            "run_manifest_sha256": "old-run-hash",
            "audit_report_sha256": None,
        }
        report_path.write_text(yaml.safe_dump(report), encoding="utf-8")
        run_manifest = study_dir / "run_manifest.yml"
        run_manifest.write_text("status: PUBLISHED\n", encoding="utf-8")
        manifest_path = study_dir / "study_manifest.yml"
        manifest = yaml.safe_load(manifest_path.read_text(encoding="utf-8"))
        manifest.update(
            status="ACCEPTED",
            run_manifest_path=str(run_manifest),
        )
        manifest_path.write_text(yaml.safe_dump(manifest), encoding="utf-8")

        rows, skipped, incomplete = discover_experiment_runs(
            self.study_root,
            study_id_prefix="formal-",
        )

        self.assertEqual(rows, [])
        self.assertEqual(skipped, [])
        self.assertEqual(len(incomplete), 1)
        self.assertIn("authoritative artifacts changed", incomplete[0]["reason"])

    def test_incomplete_study_blocks_formal_comparison(self) -> None:
        self._write_trial(
            "formal-single-01", "single_agent", elapsed=900.0, active_calls=5
        )
        self._write_trial(
            "formal-multi-01", "centralized_roles", elapsed=900.0, active_calls=5
        )
        (self.study_root / "formal-multi-01" / "agent_evaluation_report.yml").unlink()

        rows, skipped, incomplete = discover_experiment_runs(
            self.study_root,
            task_id="md-rps20-annual-gtep-july-pcm-v3",
            study_id_prefix="formal-",
        )
        summary = build_experiment_summary(
            rows,
            study_root=self.study_root,
            task_id="md-rps20-annual-gtep-july-pcm-v3",
            skipped=skipped,
            incomplete=incomplete,
            study_id_prefix="formal-",
            required_architectures=["single_agent", "centralized_roles"],
            expected_trials_per_architecture=1,
        )

        self.assertEqual(len(incomplete), 1)
        self.assertFalse(summary["ready_for_comparison"])
        self.assertFalse(summary["completion"]["trial_target_met"])
        self.assertIn("formal-multi-01", render_markdown(summary))

    def test_task_filter_ignores_untagged_legacy_incomplete_study(self) -> None:
        legacy = self.study_root / "legacy-study"
        legacy.mkdir()
        (legacy / "study_manifest.yml").write_text(
            yaml.safe_dump({"study_id": "legacy-study"}), encoding="utf-8"
        )

        rows, skipped, incomplete = discover_experiment_runs(
            self.study_root,
            task_id="md-rps20-annual-gtep-july-pcm-v3",
        )

        self.assertEqual(rows, [])
        self.assertEqual(skipped, [])
        self.assertEqual(incomplete, [])

    def test_complete_matched_matrix_is_ready_for_comparison(self) -> None:
        self._write_trial(
            "formal-single-01", "single_agent", elapsed=900.0, active_calls=5
        )
        self._write_trial(
            "formal-multi-01", "centralized_roles", elapsed=900.0, active_calls=5
        )
        rows, skipped, incomplete = discover_experiment_runs(
            self.study_root, study_id_prefix="formal-"
        )
        summary = build_experiment_summary(
            rows,
            study_root=self.study_root,
            task_id="md-rps20-annual-gtep-july-pcm-v3",
            skipped=skipped,
            incomplete=incomplete,
            required_architectures=["single_agent", "centralized_roles"],
            expected_trials_per_architecture=1,
        )

        self.assertTrue(summary["ready_for_comparison"])
        self.assertTrue(summary["completion"]["trial_target_met"])

    def test_writes_yaml_csv_and_markdown_outputs(self) -> None:
        self._write_trial(
            "single-01",
            "single_agent",
            elapsed=900.0,
            active_calls=5,
            agent_passed=False,
        )
        rows, skipped, incomplete = discover_experiment_runs(self.study_root)
        summary = build_experiment_summary(
            rows,
            study_root=self.study_root,
            task_id="md-rps20-annual-gtep-july-pcm-v3",
            skipped=skipped,
            incomplete=incomplete,
        )
        output_dir = Path(self.temporary.name) / "summary"
        paths = write_experiment_summary(summary, output_dir)
        for value in paths.values():
            self.assertTrue(Path(value).is_file())

        markdown = render_markdown(summary)
        self.assertIn("single_agent", markdown)
        self.assertIn("task_verification", markdown)
        with Path(paths["runs_csv"]).open(encoding="utf-8", newline="") as stream:
            records = list(csv.DictReader(stream))
        self.assertEqual(records[0]["study_id"], "single-01")
        self.assertEqual(records[0]["agent_passed"], "False")


if __name__ == "__main__":
    unittest.main()
