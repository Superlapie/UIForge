#!/usr/bin/env python3
"""Positive machine command conformance for fallback transport."""

from __future__ import annotations

import copy
import json
import shutil
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from ui_fallback import dispatch_machine  # noqa: E402

FIXTURES = json.loads((ROOT / "tests/machine_protocol/fixtures/positive_commands.json").read_text(encoding="utf-8"))
FIXTURE = str((ROOT / "tests/conformance/fixtures/minimal.ui.json").relative_to(ROOT)).replace("\\", "/")


def substitute_temp_paths(value: object, temp_path: str) -> object:
    if value == "__TEMP__":
        return temp_path
    if isinstance(value, dict):
        return {key: substitute_temp_paths(item, temp_path) for key, item in value.items()}
    if isinstance(value, list):
        return [substitute_temp_paths(item, temp_path) for item in value]
    return value


class Batch3PositiveCommandTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temp_dir = ROOT / ".uiforge" / "positive_commands"
        cls.temp_dir.mkdir(parents=True, exist_ok=True)

    def _prepare_fixture(self, fixture: dict) -> tuple[dict, str | None]:
        request = copy.deepcopy(fixture["request"])
        temp_path = None
        if fixture.get("temp_document_from"):
            temp_path = self.temp_dir / f"{fixture['id']}.ui.json"
            shutil.copy(ROOT / fixture["temp_document_from"], temp_path)
            rel = str(temp_path.relative_to(ROOT)).replace("\\", "/")
            request = substitute_temp_paths(request, rel)
            temp_path = rel
        return request, temp_path

    def test_fallback_positive_commands(self) -> None:
        runnable = [item for item in FIXTURES if "fallback" in item.get("transports", []) and item["id"] != "positive_shutdown"]
        self.assertGreaterEqual(len(runnable), 14)
        for fixture in runnable:
            with self.subTest(fixture=fixture["id"]):
                request, temp_path = self._prepare_fixture(fixture)
                response = dispatch_machine(request)
                expect = fixture["expect"]
                allowed = expect.get("allowed_error_codes", [])
                if allowed and not response.get("success"):
                    self.assertIn(response.get("error", {}).get("code"), allowed)
                    continue
                self.assertTrue(response.get("success"), response)
                for key in expect.get("result_has", []):
                    self.assertIn(key, response.get("result", {}))
                node_id = expect.get("node_exists")
                if node_id and temp_path:
                    inspect = dispatch_machine({
                        "protocol": "uiforge.machine",
                        "protocol_version": 1,
                        "request_id": f"{fixture['id']}-node",
                        "method": "get",
                        "params": {"document": temp_path, "node": node_id, "property": "layout.size"},
                    })
                    self.assertTrue(inspect.get("success"), inspect)


if __name__ == "__main__":
    unittest.main()
