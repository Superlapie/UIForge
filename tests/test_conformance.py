#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "scripts/ui_fallback.py"
MANIFEST = ROOT / "tests/conformance/manifest.json"
FIXTURES = ROOT / "tests/conformance/fixtures"
SCHEMA = ROOT / "schemas/uiforge.schema.json"
MINIMAL = FIXTURES / "minimal.ui.json"


def run_cli(*args: str) -> tuple[dict, int, str]:
    process = subprocess.run(["python3", str(CLI), *args], cwd=ROOT, capture_output=True, text=True)
    stdout = process.stdout.strip()
    payload = json.loads(stdout) if stdout else {"success": False, "errors": [{"code": "EMPTY_STDOUT"}]}
    return payload, process.returncode, process.stderr


def diagnostic_codes(payload: dict) -> set[str]:
    codes: set[str] = set()
    for item in payload.get("diagnostics", []):
        if isinstance(item, dict) and item.get("code"):
            codes.add(str(item["code"]))
    errors = payload.get("errors", [])
    if isinstance(errors, list):
        for item in errors:
            if isinstance(item, dict) and item.get("code"):
                codes.add(str(item["code"]))
    error = payload.get("error")
    if isinstance(error, dict) and error.get("code"):
        codes.add(str(error["code"]))
    return codes


class ManifestConformanceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
        try:
            import jsonschema

            cls.schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
            cls.schema_validator = jsonschema.Draft202012Validator(cls.schema)
        except ImportError:
            cls.schema_validator = None

    def test_shared_validation_vectors_match_manifest(self) -> None:
        for vector in self.manifest["validation_vectors"]:
            with self.subTest(vector=vector["id"]):
                path = FIXTURES / vector["file"]
                payload, code, stderr = run_cli("validate", str(path))
                self.assertFalse(stderr.strip(), msg=stderr)
                expect_valid = bool(vector["expect_valid"])
                self.assertEqual(bool(payload.get("success")), expect_valid, payload)
                self.assertEqual(code == 0, expect_valid, payload)
                for expected_code in vector.get("expect_codes", []):
                    self.assertIn(expected_code, diagnostic_codes(payload), payload)
                if "schema_valid" in vector and self.schema_validator is not None:
                    document = json.loads(path.read_text(encoding="utf-8"))
                    if vector["schema_valid"]:
                        self.schema_validator.validate(document)
                    else:
                        with self.assertRaises(Exception):
                            self.schema_validator.validate(document)


class MutationConformanceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.document = Path(self.tempdir.name) / "case.ui.json"
        self.document.write_text(MINIMAL.read_text(encoding="utf-8"), encoding="utf-8")

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def test_invalid_mutation_is_not_committed(self) -> None:
        original = self.document.read_text(encoding="utf-8")
        result, code, stderr = run_cli("set", str(self.document), "child_a", "properties.columns", "0")
        self.assertFalse(stderr.strip())
        self.assertNotEqual(code, 0, result)
        self.assertFalse(result.get("committed", True))
        self.assertEqual(self.document.read_text(encoding="utf-8"), original)
        self.assertIn("GRID_COLUMNS_INVALID", diagnostic_codes(result))

    def test_duplicate_remaps_descendant_ids(self) -> None:
        result, code, _stderr = run_cli("duplicate", str(self.document), "parent_b", "parent_b_copy")
        self.assertEqual(code, 0, result)
        self.assertTrue(result.get("committed"))
        data = json.loads(self.document.read_text(encoding="utf-8"))
        ids = [node["id"] for node, _parent in _walk(data["root"])]
        self.assertEqual(len(ids), len(set(ids)))
        self.assertIn("parent_b_copy_1", ids)

    def test_move_honors_index_and_blocks_cycles(self) -> None:
        blocked, blocked_code, _stderr = run_cli("move", str(self.document), "parent_b", "child_b1")
        self.assertNotEqual(blocked_code, 0)
        self.assertFalse(blocked.get("committed", True))
        result, code, _stderr = run_cli("move", str(self.document), "child_a", "root", "0")
        self.assertEqual(code, 0, result)
        child_ids = [child["id"] for child in json.loads(self.document.read_text())["root"]["children"]]
        self.assertEqual(child_ids[0], "child_a")

    def test_save_failure_returns_structured_json(self) -> None:
        read_only_dir = Path(self.tempdir.name) / "readonly"
        read_only_dir.mkdir()
        target = read_only_dir / "blocked.ui.json"
        target.write_text(MINIMAL.read_text(encoding="utf-8"), encoding="utf-8")
        os.chmod(read_only_dir, stat.S_IREAD | stat.S_IEXEC)
        try:
            result, code, stderr = run_cli("set", str(target), "child_a", "properties.text", "\"blocked\"")
        finally:
            os.chmod(read_only_dir, stat.S_IRWXU)
        self.assertFalse(stderr.strip())
        self.assertNotEqual(code, 0, result)
        self.assertFalse(result.get("success", True))
        self.assertFalse(result.get("committed", True))
        self.assertIn("FILE_WRITE_FAILED", diagnostic_codes(result))

    def test_new_rejects_invalid_document_name(self) -> None:
        target = Path(self.tempdir.name) / "1 bad.ui.json"
        result, code, stderr = run_cli("new", "blank", str(target), "--allow-outside-project")
        self.assertFalse(stderr.strip())
        self.assertNotEqual(code, 0, result)
        self.assertFalse(result.get("committed", True))
        self.assertIn("DOCUMENT_NAME_INVALID", diagnostic_codes(result))
        self.assertFalse(target.exists())


def _walk(node: dict, parent: dict | None = None):
    yield node, parent
    for child in node.get("children", []):
        if isinstance(child, dict):
            yield from _walk(child, node)


if __name__ == "__main__":
    unittest.main(verbosity=2)
