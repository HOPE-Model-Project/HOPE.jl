from __future__ import annotations

import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

import yaml

PACKAGE_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PACKAGE_ROOT / "src"))

from hope_mcp_server.agent_evaluation import (  # noqa: E402
    _read_optional_yaml,
    _read_yaml,
    _safe_value,
    _verify_trace,
    _write_yaml_atomic,
    append_tool_event,
    evaluate_agent_study,
    submit_agent_report,
)
from hope_mcp_server.core import (  # noqa: E402
    hope_evaluate_holistic_agent_study,
    hope_submit_holistic_agent_report,
)


class AgentEvaluationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.study_root = Path(self.temporary.name) / "study"
        self.run_root = Path(self.temporary.name) / "run"
        self.study_root.mkdir()
        self.run_root.mkdir()
        self.study_id = "evaluation-test"
        self.run_manifest = self.run_root / "run_manifest.yml"
        self.audit_report = self.study_root / "audit_report.yml"
        self.run_manifest.write_text(
            yaml.safe_dump({"schema_version": 1, "status": "PUBLISHED"}),
            encoding="utf-8",
        )
        self.audit_report.write_text(
            yaml.safe_dump(
                {
                    "schema_version": 1,
                    "accepted": True,
                    "checks": [
                        {"check": "acceptance_checks_passed", "passed": True}
                    ],
                }
            ),
            encoding="utf-8",
        )
        self.study = {
            "schema_version": 1,
            "study_id": self.study_id,
            "status": "ACCEPTED",
            "run_manifest_path": str(self.run_manifest),
            "audit": {"audit_report_path": str(self.audit_report)},
        }
        (self.study_root / "study_manifest.yml").write_text(
            yaml.safe_dump(self.study), encoding="utf-8"
        )
        self.evidence = [
            self.study_root / "study_manifest.yml",
            self.run_manifest,
            self.audit_report,
        ]

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _event(self, operation: str, role: str, label: str, *, ok: bool = True) -> None:
        started = time.time()
        append_tool_event(
            self.study_root,
            study_id=self.study_id,
            operation=operation,
            role=role,
            agent_label=label,
            arguments={"study_id": self.study_id},
            result={"ok": ok, "study_id": self.study_id},
            started_at_unix=started,
            completed_at_unix=started + 0.01,
        )

    def _complete_trace_and_report(self) -> None:
        self._event("hope_prepare_holistic_validation_study", "coordinator", "agent-A")
        self._event("hope_launch_holistic_study", "executor", "agent-B")
        self._event("hope_holistic_study_status", "observer", "agent-B")
        self._event("hope_audit_holistic_study", "auditor", "agent-C")
        result = submit_agent_report(
            self.study_root,
            self.study,
            task_id="md-rps20-annual-gtep-july-pcm-v1",
            architecture="centralized_roles",
            agent_label="agent-C",
            claims={
                "study_accepted": True,
                "run_published": True,
                "audit_accepted": True,
                "all_acceptance_checks_passed": True,
            },
            evidence_paths=[str(path) for path in self.evidence],
        )
        self.assertTrue(result["ok"], result)
        self._event("hope_submit_holistic_agent_report", "reporter", "agent-C")

    def test_accepted_model_and_compliant_agent_are_scored_separately(self) -> None:
        self._complete_trace_and_report()
        result = evaluate_agent_study(self.study_root, self.study)
        self.assertTrue(result["ok"], result)
        self.assertTrue(result["model_passed"])
        self.assertTrue(result["agent_passed"])
        self.assertEqual(result["metrics"]["verified_claims"], 4)
        self.assertEqual(result["metrics"]["false_safe_claims"], 0)
        self.assertTrue(Path(result["evaluation_report_path"]).is_file())

    def test_v2_accepts_traced_wait_and_hope_only_attestation(self) -> None:
        self._event("hope_prepare_holistic_validation_study", "coordinator", "agent-A")
        self._event("hope_launch_holistic_study", "executor", "agent-A")
        self._event("hope_wait_holistic_study", "observer", "agent-A")
        self._event("hope_audit_holistic_study", "auditor", "agent-A")
        result = submit_agent_report(
            self.study_root,
            self.study,
            task_id="md-rps20-annual-gtep-july-pcm-v2",
            architecture="single_agent",
            agent_label="agent-A",
            claims={
                "study_accepted": True,
                "run_published": True,
                "audit_accepted": True,
                "all_acceptance_checks_passed": True,
            },
            evidence_paths=[str(path) for path in self.evidence],
            monitoring_mode="hope_mcp_only",
        )
        self.assertTrue(result["ok"], result)
        self._event("hope_submit_holistic_agent_report", "reporter", "agent-A")
        evaluated = evaluate_agent_study(self.study_root, self.study)
        self.assertTrue(evaluated["agent_passed"], evaluated)
        self.assertTrue(evaluated["checks"]["monitoring_contract_compliance"])
        self.assertEqual(evaluated["metrics"]["wait_calls"], 1)
        self.assertEqual(evaluated["metrics"]["monitoring_mode"], "hope_mcp_only")

    def test_v2_rejects_external_monitoring_attestation(self) -> None:
        self._event("hope_prepare_holistic_validation_study", "coordinator", "agent-A")
        self._event("hope_launch_holistic_study", "executor", "agent-A")
        self._event("hope_wait_holistic_study", "observer", "agent-A")
        self._event("hope_audit_holistic_study", "auditor", "agent-A")
        result = submit_agent_report(
            self.study_root,
            self.study,
            task_id="md-rps20-annual-gtep-july-pcm-v2",
            architecture="single_agent",
            agent_label="agent-A",
            claims={key: True for key in (
                "study_accepted",
                "run_published",
                "audit_accepted",
                "all_acceptance_checks_passed",
            )},
            evidence_paths=[str(path) for path in self.evidence],
            monitoring_mode="external_tools_used",
        )
        self.assertTrue(result["ok"], result)
        self._event("hope_submit_holistic_agent_report", "reporter", "agent-A")
        evaluated = evaluate_agent_study(self.study_root, self.study)
        self.assertFalse(evaluated["agent_passed"])
        self.assertFalse(evaluated["checks"]["monitoring_contract_compliance"])
        self.assertEqual(evaluated["failures"][-1]["category"], "task_verification")

    def test_invalid_monitoring_mode_is_rejected(self) -> None:
        result = submit_agent_report(
            self.study_root,
            self.study,
            task_id="md-rps20-annual-gtep-july-pcm-v2",
            architecture="single_agent",
            agent_label="agent-A",
            claims={key: True for key in (
                "study_accepted",
                "run_published",
                "audit_accepted",
                "all_acceptance_checks_passed",
            )},
            evidence_paths=[str(path) for path in self.evidence],
            monitoring_mode="background_script",
        )
        self.assertFalse(result["ok"])
        self.assertEqual(result["error_type"], "invalid_monitoring_mode")

    def test_false_safe_claim_fails_agent_even_when_trace_is_valid(self) -> None:
        self.study["status"] = "REJECTED"
        self.audit_report.write_text(
            yaml.safe_dump(
                {
                    "schema_version": 1,
                    "accepted": False,
                    "checks": [
                        {"check": "acceptance_checks_passed", "passed": False}
                    ],
                }
            ),
            encoding="utf-8",
        )
        self._complete_trace_and_report()
        result = evaluate_agent_study(self.study_root, self.study)
        self.assertFalse(result["model_passed"])
        self.assertFalse(result["agent_passed"])
        self.assertEqual(result["metrics"]["false_safe_claims"], 3)
        self.assertEqual(result["failures"][-1]["category"], "task_verification")

    def test_tampered_trace_is_detected(self) -> None:
        self._complete_trace_and_report()
        trace_path = self.study_root / "agent_trace.yml"
        trace = yaml.safe_load(trace_path.read_text(encoding="utf-8"))
        trace["events"][0]["operation"] = "tampered"
        trace_path.write_text(yaml.safe_dump(trace, sort_keys=False), encoding="utf-8")
        result = evaluate_agent_study(self.study_root, self.study)
        self.assertFalse(result["agent_passed"])
        self.assertFalse(result["checks"]["trace_integrity"])
        self.assertIn("hash mismatch", " ".join(result["failures"][0]["details"]))

    def test_evidence_outside_study_and_run_is_rejected(self) -> None:
        outside = Path(self.temporary.name) / "outside.yml"
        outside.write_text("unsafe: true\n", encoding="utf-8")
        result = submit_agent_report(
            self.study_root,
            self.study,
            task_id="md-rps20-annual-gtep-july-pcm-v1",
            architecture="single_agent",
            agent_label="agent-A",
            claims={key: True for key in (
                "study_accepted",
                "run_published",
                "audit_accepted",
                "all_acceptance_checks_passed",
            )},
            evidence_paths=[str(outside)],
        )
        self.assertFalse(result["ok"])
        self.assertEqual(result["error_type"], "invalid_evidence_path")

    def test_non_boolean_claim_is_rejected(self) -> None:
        result = submit_agent_report(
            self.study_root,
            self.study,
            task_id="md-rps20-annual-gtep-july-pcm-v1",
            architecture="single_agent",
            agent_label="agent-A",
            claims={
                "study_accepted": "true",  # type: ignore[dict-item]
                "run_published": True,
                "audit_accepted": True,
                "all_acceptance_checks_passed": True,
            },
            evidence_paths=[str(path) for path in self.evidence],
        )
        self.assertFalse(result["ok"])
        self.assertEqual(result["error_type"], "invalid_agent_claims")

    def test_report_input_validation_is_explicit(self) -> None:
        claims = {
            "study_accepted": True,
            "run_published": True,
            "audit_accepted": True,
            "all_acceptance_checks_passed": True,
        }
        cases = (
            ({"task_id": "unknown"}, "invalid_evaluation_task"),
            ({"architecture": "peer_to_peer"}, "invalid_agent_architecture"),
            ({"agent_label": ""}, "invalid_agent_label"),
            ({"claims": {"study_accepted": True}}, "missing_agent_claims"),
        )
        defaults = {
            "task_id": "md-rps20-annual-gtep-july-pcm-v1",
            "architecture": "single_agent",
            "agent_label": "agent-A",
            "claims": claims,
        }
        for changes, expected in cases:
            with self.subTest(error_type=expected):
                options = {**defaults, **changes}
                result = submit_agent_report(
                    self.study_root,
                    self.study,
                    evidence_paths=[str(path) for path in self.evidence],
                    **options,
                )
                self.assertFalse(result["ok"])
                self.assertEqual(result["error_type"], expected)

    def test_trace_and_yaml_validation_detect_malformed_documents(self) -> None:
        invalid_yaml = self.study_root / "not-a-mapping.yml"
        invalid_yaml.write_text("- one\n- two\n", encoding="utf-8")
        with self.assertRaises(ValueError):
            _read_yaml(invalid_yaml)
        self.assertEqual(_read_optional_yaml(invalid_yaml), {})

        valid, errors = _verify_trace(
            {"schema_version": 99, "study_id": "wrong", "events": "bad"},
            self.study_id,
        )
        self.assertFalse(valid)
        self.assertEqual(len(errors), 3)
        valid, errors = _verify_trace(
            {
                "schema_version": 1,
                "study_id": self.study_id,
                "events": ["bad", {"sequence": 9, "previous_event_sha256": "bad"}],
            },
            self.study_id,
        )
        self.assertFalse(valid)
        self.assertTrue(any("not a mapping" in item for item in errors))
        self.assertTrue(any("sequence mismatch" in item for item in errors))
        self.assertTrue(any("previous hash mismatch" in item for item in errors))

        for document, message in (
            ({"schema_version": 99, "study_id": self.study_id, "events": []}, "schema"),
            ({"schema_version": 1, "study_id": "wrong", "events": []}, "study"),
            ({"schema_version": 1, "study_id": self.study_id, "events": {}}, "events"),
        ):
            (self.study_root / "agent_trace.yml").write_text(
                yaml.safe_dump(document), encoding="utf-8"
            )
            with self.subTest(message=message), self.assertRaises(ValueError):
                self._event("test", "test", "agent-A")

    def test_atomic_writer_retries_and_cleans_up_after_failure(self) -> None:
        destination = self.study_root / "atomic.yml"
        with mock.patch(
            "hope_mcp_server.agent_evaluation.os.replace",
            side_effect=[PermissionError("locked"), None],
        ), mock.patch("hope_mcp_server.agent_evaluation.time.sleep") as sleep:
            _write_yaml_atomic(destination, {"ok": True})
        sleep.assert_called_once()

        with mock.patch(
            "hope_mcp_server.agent_evaluation.os.replace",
            side_effect=PermissionError("locked"),
        ), mock.patch("hope_mcp_server.agent_evaluation.time.sleep"):
            with self.assertRaises(PermissionError):
                _write_yaml_atomic(destination, {"ok": False})
        self.assertEqual(list(self.study_root.glob(".*.tmp")), [])

    def test_safe_trace_values_are_bounded_and_serializable(self) -> None:
        class CustomValue:
            def __str__(self) -> str:
                return "custom"

        nested = {"a": {"b": {"c": {"d": {"e": "too deep"}}}}}
        self.assertIn("<truncated>", str(_safe_value(nested)))
        self.assertEqual(_safe_value(Path("evidence.yml")), "evidence.yml")
        self.assertEqual(_safe_value(CustomValue()), "custom")

    def test_evaluation_requires_known_task_and_submitted_report(self) -> None:
        invalid = evaluate_agent_study(self.study_root, self.study, task_id="unknown")
        self.assertEqual(invalid["error_type"], "invalid_evaluation_task")
        missing = evaluate_agent_study(
            self.study_root,
            self.study,
            task_id="md-rps20-annual-gtep-july-pcm-v1",
        )
        self.assertEqual(missing["error_type"], "agent_report_not_found")

    def test_core_report_and_evaluation_api_use_durable_study(self) -> None:
        self._event("hope_prepare_holistic_validation_study", "coordinator", "agent-A")
        self._event("hope_launch_holistic_study", "executor", "agent-B")
        self._event("hope_holistic_study_status", "observer", "agent-B")
        self._event("hope_audit_holistic_study", "auditor", "agent-C")
        manifest_path = self.study_root / "study_manifest.yml"
        loaded = (self.study, manifest_path, None)
        with mock.patch("hope_mcp_server.core._load_holistic_study", return_value=loaded):
            submitted = hope_submit_holistic_agent_report(
                self.study_id,
                claims={
                    "study_accepted": True,
                    "run_published": True,
                    "audit_accepted": True,
                    "all_acceptance_checks_passed": True,
                },
                evidence_paths=[str(path) for path in self.evidence],
                architecture="centralized_roles",
                agent_label="agent-C",
            )
            evaluated = hope_evaluate_holistic_agent_study(self.study_id)
        self.assertTrue(submitted["ok"], submitted)
        self.assertTrue(evaluated["ok"], evaluated)
        self.assertTrue(evaluated["model_passed"])
        self.assertTrue(evaluated["agent_passed"])

if __name__ == "__main__":
    unittest.main()
