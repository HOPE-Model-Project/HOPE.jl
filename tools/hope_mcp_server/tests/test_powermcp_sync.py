from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

PACKAGE_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PACKAGE_ROOT / "scripts"))

from sync_to_powermcp import compare_managed_files, synchronize  # noqa: E402


class PowerMCPSyncTests(unittest.TestCase):
    def test_compare_ignores_line_ending_differences(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "source"
            destination = root / "destination"
            source.mkdir()
            destination.mkdir()
            (source / "file.py").write_bytes(b"one\ntwo\n")
            (destination / "file.py").write_bytes(b"one\r\ntwo\r\n")

            differences = compare_managed_files(
                source,
                destination,
                [Path("file.py")],
            )

        self.assertEqual(differences, [])

    def test_apply_copies_only_managed_files(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            power_mcp = Path(tmp) / "PowerMCP"
            destination = power_mcp / "HOPE"
            (power_mcp / ".git").mkdir(parents=True)
            destination.mkdir()
            downstream_owned = destination / "pyproject.toml"
            downstream_owned.write_text("power-mcp-owned\n", encoding="utf-8")

            with mock.patch(
                "sync_to_powermcp._upstream_revision",
                return_value="a" * 40,
            ):
                differences = synchronize(power_mcp, apply_changes=True)

            self.assertTrue(differences)
            self.assertEqual(
                downstream_owned.read_text(encoding="utf-8"),
                "power-mcp-owned\n",
            )
            self.assertTrue((destination / "src/hope_mcp_server/core.py").is_file())
            self.assertTrue(
                (destination / "tests/test_holistic_agent_integration.py").is_file()
            )
            self.assertFalse((destination / "tests/test_core.py").exists())
            self.assertIn(
                "upstream_commit: " + "a" * 40,
                (destination / "SYNCED_FROM_HOPE.yml").read_text(encoding="utf-8"),
            )


if __name__ == "__main__":
    unittest.main()
