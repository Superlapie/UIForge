#!/usr/bin/env python3
"""Portable fallback parity tests for the machine protocol."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from ui_fallback import dispatch_machine  # noqa: E402
import shutil


class Batch3FallbackParityTests(unittest.TestCase):
    def test_fallback_capabilities_machine_envelope(self) -> None:
        response = dispatch_machine({
            "protocol": "uiforge.machine",
            "protocol_version": 1,
            "request_id": "fb-cap",
            "method": "capabilities",
            "params": {},
        })
        self.assertTrue(response.get("success"))
        self.assertEqual(response.get("meta", {}).get("backend"), "python-fallback")
        caps = response.get("result", {}).get("capabilities", {})
        self.assertFalse(caps.get("persistent_server", {}).get("supported"))
        self.assertTrue(caps.get("batch", {}).get("supported"))
        commands = caps.get("available_commands", [])
        schemas = caps.get("command_parameter_schemas", {})
        for command in commands:
            if command in {"capabilities", "shutdown"}:
                continue
            self.assertIn(command, schemas, f"missing schema for {command}")

    def test_fallback_validate_revision(self) -> None:
        fixture = str((ROOT / "examples/specs/inventory.ui.json").relative_to(ROOT))
        response = dispatch_machine({
            "protocol": "uiforge.machine",
            "protocol_version": 1,
            "request_id": "fb-validate",
            "method": "validate",
            "params": {"document": fixture},
        })
        self.assertTrue(response.get("success"))
        self.assertTrue(str(response.get("result", {}).get("revision", "")).startswith("sha256:"))

    def test_fallback_batch_dry_run(self) -> None:
        fixture = str((ROOT / "tests/conformance/fixtures/minimal.ui.json").relative_to(ROOT))
        validate = dispatch_machine({
            "protocol": "uiforge.machine",
            "protocol_version": 1,
            "request_id": "fb-rev",
            "method": "validate",
            "params": {"document": fixture},
        })
        revision = validate.get("result", {}).get("revision", "")
        response = dispatch_machine({
            "protocol": "uiforge.machine",
            "protocol_version": 1,
            "request_id": "fb-batch",
            "method": "batch",
            "params": {
                "document": fixture,
                "expected_revision": revision,
                "dry_run": True,
                "operations": [{"op": "set", "node": "root", "property": "layout.size", "value": "[420,300]"}],
            },
        })
        self.assertTrue(response.get("success"))
        self.assertFalse(response.get("result", {}).get("committed", True))

    def test_fallback_revision_conflict(self) -> None:
        fixture = str((ROOT / "tests/conformance/fixtures/minimal.ui.json").relative_to(ROOT))
        response = dispatch_machine({
            "protocol": "uiforge.machine",
            "protocol_version": 1,
            "request_id": "fb-conflict",
            "method": "batch",
            "params": {
                "document": fixture,
                "expected_revision": "sha256:deadbeef",
                "operations": [{"op": "set", "node": "root", "property": "layout.size", "value": "[420,300]"}],
            },
        })
        self.assertFalse(response.get("success"))
        self.assertEqual(response.get("error", {}).get("code"), "REVISION_CONFLICT")
        self.assertFalse(response.get("result", {}).get("committed", True))

    def test_fallback_advertised_commands_not_unknown(self) -> None:
        temp_dir = ROOT / ".uiforge" / "fallback_cmd_smoke"
        temp_dir.mkdir(parents=True, exist_ok=True)
        temp_doc = temp_dir / "command_smoke.ui.json"
        shutil.copy(ROOT / "tests/conformance/fixtures/minimal.ui.json", temp_doc)
        rel_doc = str(temp_doc.relative_to(ROOT)).replace("\\", "/")
        caps = dispatch_machine({
            "protocol": "uiforge.machine",
            "protocol_version": 1,
            "request_id": "fb-cap-list",
            "method": "capabilities",
            "params": {},
        }).get("result", {}).get("capabilities", {})
        commands = caps.get("available_commands", [])
        minimal_params = {
            "capabilities": {},
            "validate": {"document": rel_doc},
            "inspect": {"document": rel_doc, "scope": "tree"},
            "get": {"document": rel_doc, "node": "root", "property": "layout.size"},
            "set": {"document": rel_doc, "node": "root", "property": "layout.size", "value": "[400,300]"},
            "add": {"document": rel_doc, "parent": "root", "node": {"id": "tmp_node", "type": "Panel", "layout": {"size": [10, 10]}, "children": []}},
            "delete": {"document": rel_doc, "node": "child_a"},
            "move": {"document": rel_doc, "node": "child_a", "parent": "parent_b"},
            "duplicate": {"document": rel_doc, "node": "child_a", "new_id": "child_a_copy"},
            "batch": {"document": rel_doc, "dry_run": True, "operations": [{"op": "set", "node": "root", "property": "layout.size", "value": "[420,300]"}]},
            "new": {"template": "blank", "output": ".uiforge/fallback_new.ui.json"},
            "build": {"document": rel_doc, "output": ".uiforge/fallback_build.tscn"},
            "build-all": {"source_dir": "tests/conformance/fixtures", "output_dir": ".uiforge/build_all_out"},
            "render": {"document": rel_doc},
        }
        for command in commands:
            response = dispatch_machine({
                "protocol": "uiforge.machine",
                "protocol_version": 1,
                "request_id": f"fb-{command}",
                "method": command,
                "params": minimal_params.get(command, {}),
            })
            self.assertNotEqual(
                response.get("error", {}).get("code"),
                "UNKNOWN_METHOD",
                f"advertised command {command} returned UNKNOWN_METHOD",
            )

    def test_fallback_accepts_whole_float_protocol_version(self) -> None:
        response = dispatch_machine({
            "protocol": "uiforge.machine",
            "protocol_version": 1.0,
            "request_id": "fb-float",
            "method": "capabilities",
            "params": {},
        })
        self.assertTrue(response.get("success"))

    def test_fallback_malformed_protocol_version(self) -> None:
        response = dispatch_machine({
            "protocol": "uiforge.machine",
            "protocol_version": "banana",
            "request_id": "fb-banana",
            "method": "capabilities",
            "params": {},
        })
        self.assertFalse(response.get("success"))
        self.assertEqual(response.get("error", {}).get("code"), "MALFORMED_REQUEST")

    def test_fallback_rejects_fractional_protocol_version(self) -> None:
        response = dispatch_machine({
            "protocol": "uiforge.machine",
            "protocol_version": 1.5,
            "request_id": "fb-fraction",
            "method": "capabilities",
            "params": {},
        })
        self.assertFalse(response.get("success"))
        self.assertEqual(response.get("error", {}).get("code"), "UNSUPPORTED_PROTOCOL_VERSION")


if __name__ == "__main__":
    unittest.main()
