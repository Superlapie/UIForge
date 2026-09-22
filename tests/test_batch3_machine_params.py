#!/usr/bin/env python3
"""Malformed machine parameter tests for fallback and shared fixtures."""

from __future__ import annotations

import json
import shutil
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from ui_fallback import dispatch_machine  # noqa: E402

FIXTURE = str((ROOT / "tests/conformance/fixtures/minimal.ui.json").relative_to(ROOT)).replace("\\", "/")


def _base_request(method: str, params: object, request_id: str = "bad-params") -> dict[str, object]:
    return {
        "protocol": "uiforge.machine",
        "protocol_version": 1,
        "request_id": request_id,
        "method": method,
        "params": params,
    }


MALFORMED_CASES: list[tuple[str, dict[str, object]]] = [
    ("validate_document", _base_request("validate", {"document": {"bad": True}})),
    ("inspect_scope", _base_request("inspect", {"document": FIXTURE, "scope": 42})),
    ("get_node", _base_request("get", {"document": FIXTURE, "node": 7})),
    ("set_value", _base_request("set", {"document": FIXTURE, "node": "root", "property": "layout.size", "value": "ok", "expected_revision": 99})),
    ("add_node_payload", _base_request("add", {"document": FIXTURE, "parent": "root", "node": ["bad"]})),
    ("delete_node", _base_request("delete", {"document": FIXTURE, "node": False})),
    ("move_index", _base_request("move", {"document": FIXTURE, "node": "child_a", "parent": "root", "index": {"bad": True}})),
    ("duplicate_new_id", _base_request("duplicate", {"document": FIXTURE, "node": "child_a", "new_id": 12})),
    ("batch_operations", _base_request("batch", {"document": FIXTURE, "operations": "not-an-array"})),
    ("batch_dry_run", _base_request("batch", {"document": FIXTURE, "dry_run": "yes", "operations": []})),
    ("new_template", _base_request("new", {"template": 1, "output": ".uiforge/bad_new.ui.json"})),
    ("build_document", _base_request("build", {"document": FIXTURE, "force": "true"})),
    ("build_all_source_dir", _base_request("build-all", {"source_dir": 9})),
    ("render_document", _base_request("render", {"document": FIXTURE, "state": 1})),
]


class Batch3MachineParamsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temp_dir = ROOT / ".uiforge" / "machine_params"
        cls.temp_dir.mkdir(parents=True, exist_ok=True)
        cls.temp_doc = cls.temp_dir / "params.ui.json"
        shutil.copy(ROOT / "tests/conformance/fixtures/minimal.ui.json", cls.temp_doc)
        cls.rel_doc = str(cls.temp_doc.relative_to(ROOT)).replace("\\", "/")

    def test_protocol_version_whole_float_accepted(self) -> None:
        response = dispatch_machine({
            "protocol": "uiforge.machine",
            "protocol_version": 1.0,
            "request_id": "float-version",
            "method": "capabilities",
            "params": {},
        })
        self.assertTrue(response.get("success"))

    def test_protocol_version_fraction_rejected(self) -> None:
        response = dispatch_machine({
            "protocol": "uiforge.machine",
            "protocol_version": 1.5,
            "request_id": "fraction-version",
            "method": "capabilities",
            "params": {},
        })
        self.assertFalse(response.get("success"))
        self.assertEqual(response.get("error", {}).get("code"), "UNSUPPORTED_PROTOCOL_VERSION")

    def test_malformed_params_do_not_crash(self) -> None:
        for label, request in MALFORMED_CASES:
            with self.subTest(label=label):
                response = dispatch_machine(request)
                self.assertFalse(response.get("success"), label)
                self.assertEqual(response.get("error", {}).get("code"), "MALFORMED_PARAMS", label)

    def test_rejected_write_does_not_mutate_source(self) -> None:
        before = self.temp_doc.read_bytes()
        response = dispatch_machine(_base_request(
            "set",
            {
                "document": self.rel_doc,
                "node": "root",
                "property": "layout.size",
                "value": "[999,999]",
                "expected_revision": {"bad": True},
            },
            "bad-set-write",
        ))
        self.assertFalse(response.get("success"))
        self.assertEqual(response.get("error", {}).get("code"), "MALFORMED_PARAMS")
        self.assertEqual(self.temp_doc.read_bytes(), before)

    def test_malformed_request_does_not_poison_next(self) -> None:
        bad = dispatch_machine(_base_request("move", {"document": FIXTURE, "node": "child_a", "parent": "root", "index": {"bad": True}}))
        self.assertEqual(bad.get("error", {}).get("code"), "MALFORMED_PARAMS")
        good = dispatch_machine({
            "protocol": "uiforge.machine",
            "protocol_version": 1,
            "request_id": "after-bad",
            "method": "capabilities",
            "params": {},
        })
        self.assertTrue(good.get("success"))

    def test_fallback_add_object_form(self) -> None:
        response = dispatch_machine(_base_request(
            "add",
            {
                "document": self.rel_doc,
                "parent": "root",
                "node": {
                    "id": "machine_added_panel",
                    "type": "Panel",
                    "layout": {"position": [10, 10], "size": [100, 80]},
                    "children": [],
                },
            },
            "add-object",
        ))
        self.assertTrue(response.get("success"), response)
        inspect = dispatch_machine(_base_request(
            "get",
            {"document": self.rel_doc, "node": "machine_added_panel", "property": "layout.size"},
            "add-object-get",
        ))
        self.assertTrue(inspect.get("success"), inspect)

    def test_fallback_add_string_form(self) -> None:
        response = dispatch_machine(_base_request(
            "add",
            {
                "document": self.rel_doc,
                "parent": "root",
                "node": "{\"id\":\"machine_added_panel_str\",\"type\":\"Panel\",\"layout\":{\"position\":[10,10],\"size\":[100,80]},\"children\":[]}",
            },
            "add-string",
        ))
        self.assertTrue(response.get("success"), response)

    def test_batch_required_fields_rejected(self) -> None:
        cases = [
            ("batch_missing_set", [{"op": "set", "node": "root"}]),
            ("batch_missing_move_parent", [{"op": "move", "node": "child_a"}]),
            ("batch_missing_duplicate_new_id", [{"op": "duplicate", "node": "child_a"}]),
            ("batch_missing_add_node", [{"op": "add", "parent": "root"}]),
        ]
        for label, operations in cases:
            with self.subTest(label=label):
                response = dispatch_machine(_base_request("batch", {"document": self.rel_doc, "operations": operations}, label))
                self.assertFalse(response.get("success"))
                self.assertEqual(response.get("error", {}).get("code"), "MALFORMED_PARAMS")

    def test_batch_bad_add_node_type(self) -> None:
        response = dispatch_machine(_base_request(
            "batch",
            {
                "document": self.rel_doc,
                "operations": [{"op": "add", "parent": "root", "node": "not-json-or-object"}],
            },
            "batch-bad-add-node",
        ))
        self.assertFalse(response.get("success"))
        self.assertEqual(response.get("error", {}).get("code"), "MALFORMED_PARAMS")

    def test_batch_bad_move_index(self) -> None:
        response = dispatch_machine(_base_request(
            "batch",
            {
                "document": self.rel_doc,
                "operations": [{"op": "move", "node": "child_a", "parent": "parent_b", "index": {"bad": True}}],
            },
            "batch-bad-move-index",
        ))
        self.assertFalse(response.get("success"))
        self.assertEqual(response.get("error", {}).get("code"), "MALFORMED_PARAMS")

    def test_batch_valid_object_add_dry_run(self) -> None:
        before = self.temp_doc.read_bytes()
        response = dispatch_machine(_base_request(
            "batch",
            {
                "document": self.rel_doc,
                "dry_run": True,
                "operations": [{
                    "op": "add",
                    "parent": "root",
                    "node": {"id": "batch_added_panel", "type": "Panel", "layout": {"size": [32, 32]}, "children": []},
                }],
            },
            "batch-valid-add",
        ))
        self.assertTrue(response.get("success"), response)
        self.assertEqual(self.temp_doc.read_bytes(), before)

    def test_batch_dependent_add_then_set_dry_run(self) -> None:
        before = self.temp_doc.read_bytes()
        response = dispatch_machine(_base_request(
            "batch",
            {
                "document": self.rel_doc,
                "dry_run": True,
                "operations": [
                    {
                        "op": "add",
                        "parent": "root",
                        "node": {"id": "batch_child", "type": "Panel", "layout": {"size": [32, 32]}, "children": []},
                    },
                    {"op": "set", "node": "batch_child", "property": "layout.size", "value": "[64,64]"},
                ],
            },
            "batch-dependent",
        ))
        self.assertTrue(response.get("success"), response)
        self.assertEqual(self.temp_doc.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
