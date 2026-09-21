#!/usr/bin/env python3
from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "scripts/ui_fallback.py"
FIXTURE = ROOT / "tests/conformance/fixtures/minimal.ui.json"


def run(*args: str) -> tuple[dict, int]:
    process = subprocess.run(["python3", str(CLI), *args], cwd=ROOT, capture_output=True, text=True)
    return json.loads(process.stdout), process.returncode


class UIForgeConformanceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.document = Path(self.tempdir.name) / "case.ui.json"
        self.document.write_text(FIXTURE.read_text(encoding="utf-8"), encoding="utf-8")

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def test_invalid_mutation_is_not_committed(self) -> None:
        original = self.document.read_text(encoding="utf-8")
        result, code = run("set", str(self.document), "child_a", "properties.columns", "0")
        self.assertNotEqual(code, 0, result)
        self.assertFalse(result.get("success", True))
        self.assertFalse(result.get("committed", True))
        self.assertEqual(self.document.read_text(encoding="utf-8"), original)
        self.assertIn("GRID_COLUMNS_INVALID", {item["code"] for item in result.get("diagnostics", result.get("errors", []))})

    def test_duplicate_remaps_descendant_ids(self) -> None:
        result, code = run("duplicate", str(self.document), "parent_b", "parent_b_copy")
        self.assertEqual(code, 0, result)
        self.assertTrue(result.get("committed"))
        data = json.loads(self.document.read_text(encoding="utf-8"))
        ids = [node["id"] for node, _parent in _walk(data["root"])]
        self.assertEqual(len(ids), len(set(ids)))
        self.assertIn("parent_b_copy", ids)
        self.assertIn("parent_b_copy_1", ids)

    def test_move_honors_index_and_blocks_cycles(self) -> None:
        blocked, blocked_code = run("move", str(self.document), "parent_b", "child_b1")
        self.assertNotEqual(blocked_code, 0)
        self.assertFalse(blocked.get("committed", True))

        result, code = run("move", str(self.document), "child_a", "root", "0")
        self.assertEqual(code, 0, result)
        data = json.loads(self.document.read_text(encoding="utf-8"))
        child_ids = [child["id"] for child in data["root"]["children"]]
        self.assertEqual(child_ids[0], "child_a")

    def test_invalid_id_is_rejected_on_add(self) -> None:
        original = self.document.read_text(encoding="utf-8")
        node = json.dumps({"id": "1bad", "type": "Label", "properties": {"text": "nope"}})
        result, code = run("add", str(self.document), "root", node)
        self.assertNotEqual(code, 0, result)
        self.assertIn("ID_INVALID", {item.get("code") for item in result.get("errors", [result.get("error", {})])})
        self.assertEqual(self.document.read_text(encoding="utf-8"), original)

    def test_malformed_layout_returns_structured_diagnostics(self) -> None:
        broken = json.loads(FIXTURE.read_text(encoding="utf-8"))
        broken["root"]["layout"] = []
        path = Path(self.tempdir.name) / "broken.ui.json"
        path.write_text(json.dumps(broken), encoding="utf-8")
        result, code = run("validate", str(path))
        self.assertNotEqual(code, 0)
        self.assertFalse(result["success"])
        codes = {item["code"] for item in result["diagnostics"]}
        self.assertIn("LAYOUT_INVALID", codes)


def _walk(node: dict, parent: dict | None = None):
    yield node, parent
    for child in node.get("children", []):
        if isinstance(child, dict):
            yield from _walk(child, node)


if __name__ == "__main__":
    unittest.main(verbosity=2)
