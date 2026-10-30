from __future__ import annotations

import hashlib
import os
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

import yaml

from hope_mcp_server import agent_evaluation
from hope_mcp_server.adaptive_protocol import hope_evaluate_adaptive_study


def _publish_state(workspace: Path, study_id: str) -> None:
    state = {
        "artifact_type": "HOPE.adaptive_study_state",
        "schema_version": 1,
        "study_id": study_id,
        "stage": "REALIZATION_SELECTED",
        "terminal_status": "ACCEPTED",
        "iteration": 2,
        "attempts": [
            {
                "artifacts": {
                    "gtep": {"build_zones": ["BGE"]},
                    "pcm": {"affected_zones": ["PEPCO"]},
                },
                "verification": {"accepted": False, "accepted_variants": []},
                "revision": {
                    "status": "approved",
                    "revision_type": "candidate_zone_eligibility",
                    "request": {
                        "changes": {"allowed_generation_candidate_zones": ["PEPCO"]}
                    },
                },
            },
            {
                "artifacts": {
                    "pcm": {
                        "findings": [
                            {
                                "Variant": "least_cost",
                                "Accepted": True,
                                "LoadSheddingMWh": 0.0,
                            }
                        ]
                    }
                },
                "verification": {
                    "accepted": True,
                    "accepted_variants": ["least_cost"],
                },
                "selection": {"selected_variant": "least_cost"},
            },
        ],
    }
    workspace.mkdir(parents=True)
    state_path = workspace / "adaptive_study_state.yml"
    state_path.write_text(yaml.safe_dump(state, sort_keys=False), encoding="utf-8")
    manifest = {
        "artifact_type": "HOPE.adaptive_study_manifest",
        "schema_version": 1,
        "study_id": study_id,
        "state_sha256": hashlib.sha256(state_path.read_bytes()).hexdigest(),
    }
    (workspace / "manifest.yml").write_text(
        yaml.safe_dump(manifest, sort_keys=False), encoding="utf-8"
    )


class AdaptiveProtocolTests(unittest.TestCase):
    def test_adaptive_evaluator_separates_model_and_agent_checks(self) -> None:
        study_id = "adaptive-evaluator-r01"
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            workspace = root / study_id
            _publish_state(workspace, study_id)
            operations = [
                ("hope_prepare_adaptive_study", "coordinator", {}),
                ("hope_launch_adaptive_iteration", "executor", {}),
                ("hope_wait_adaptive_study", "observer", {}),
                (
                    "hope_request_adaptive_revision",
                    "diagnostic-agent",
                    {"revision_type": "candidate_zone_eligibility"},
                ),
                (
                    "hope_record_adaptive_revision_decision",
                    "human-approver",
                    {"decision": "approved", "approver": "human-reviewer"},
                ),
                ("hope_start_adaptive_child_iteration", "coordinator", {}),
                ("hope_launch_adaptive_iteration", "executor", {}),
                ("hope_wait_adaptive_study", "observer", {}),
                (
                    "hope_select_adaptive_realization",
                    "selection-agent",
                    {"variant": "least_cost"},
                ),
            ]
            started = time.time()
            for index, (operation, role, arguments) in enumerate(operations):
                agent_evaluation.append_tool_event(
                    workspace,
                    study_id=study_id,
                    operation=operation,
                    role=role,
                    agent_label=role,
                    arguments={"study_id": study_id, **arguments},
                    result={"ok": True, "study_id": study_id},
                    started_at_unix=started + index,
                    completed_at_unix=started + index + 0.1,
                )

            with mock.patch.dict(
                os.environ,
                {"HOPE_ADAPTIVE_STUDIES_ROOT": str(root)},
            ):
                result = hope_evaluate_adaptive_study(study_id)

            self.assertTrue(result["ok"])
            self.assertTrue(result["model_passed"])
            self.assertTrue(result["agent_passed"])
            self.assertEqual(result["selected_variant"], "least_cost")
            self.assertEqual(result["metrics"]["active_tool_calls"], 7)
            self.assertTrue(Path(result["evaluation_report_path"]).is_file())


if __name__ == "__main__":
    unittest.main()
