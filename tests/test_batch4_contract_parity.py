#!/usr/bin/env python3
"""Batch 4 contract parity tests for catalog, overrides, and capabilities."""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from contract_snapshots import (  # noqa: E402
    component_definitions,
    diff_paths,
    native_property_names,
    normalize_capabilities_for_parity,
    property_groups,
    semantic_property_schemas,
)
from ui_fallback import capabilities, dispatch_machine, godot_literal, typed_godot_literal, validate  # noqa: E402
from uiforge_contract import validate_godot_override  # noqa: E402


class Batch4ContractParityTests(unittest.TestCase):
    def test_semantic_property_schemas_match_snapshot(self) -> None:
        fallback_schemas = capabilities()["property_schemas"]
        failures = diff_paths(semantic_property_schemas(), fallback_schemas)
        self.assertEqual(failures, [], "\n".join(failures))

    def test_component_definitions_match_snapshot(self) -> None:
        fallback_defs = capabilities()["component_definitions"]
        failures = diff_paths(component_definitions(), fallback_defs)
        self.assertEqual(failures, [], "\n".join(failures))

    def test_property_groups_match_snapshot(self) -> None:
        fallback_groups = capabilities()["properties"]
        failures = diff_paths(property_groups(), fallback_groups)
        self.assertEqual(failures, [], "\n".join(failures))

    def test_component_catalog_includes_missing_batch3_entries(self) -> None:
        definitions = component_definitions()
        for name in ("CheckBox", "CheckButton", "LineEdit"):
            self.assertIn(name, definitions)
        self.assertEqual(definitions["QuestEntry"]["style"], "list_row")
        self.assertEqual(definitions["SidebarEntry"]["style"], "list_row")
        self.assertEqual(definitions["HealthBar"]["fill_style"], "status_health")

    def test_capabilities_portable_fields_match_snapshot_contract(self) -> None:
        failures = diff_paths(
            {
                "property_schemas": semantic_property_schemas(),
                "component_definitions": component_definitions(),
                "properties": property_groups(),
                "components": sorted(component_definitions()),
            },
            {
                "property_schemas": capabilities()["property_schemas"],
                "component_definitions": capabilities()["component_definitions"],
                "properties": capabilities()["properties"],
                "components": capabilities()["components"],
            },
        )
        self.assertEqual(failures, [], "\n".join(failures))

    def test_fallback_machine_capabilities_normalize_cleanly(self) -> None:
        response = dispatch_machine({
            "protocol": "uiforge.machine",
            "protocol_version": 1,
            "request_id": "batch4-cap",
            "method": "capabilities",
            "params": {},
        })
        self.assertTrue(response.get("success"))
        caps = normalize_capabilities_for_parity(response["result"]["capabilities"])
        self.assertIn("property_schemas", caps)
        self.assertIn("component_definitions", caps)
        self.assertNotIn("backend", caps)

    def test_bogus_bare_godot_property_rejected(self) -> None:
        diagnostic = validate_godot_override("totally_made_up_property", "Panel")
        self.assertEqual(diagnostic.get("code"), "GODOT_OVERRIDE_UNKNOWN")

    def test_valid_specialized_native_property_accepted(self) -> None:
        self.assertEqual(validate_godot_override("caret_blink_interval", "LineEdit"), {})
        self.assertEqual(validate_godot_override("theme_override_constants/minimum_character_width", "LineEdit"), {})

    def test_invalid_property_on_wrong_type_rejected(self) -> None:
        diagnostic = validate_godot_override("caret_blink_interval", "Panel")
        self.assertEqual(diagnostic.get("code"), "GODOT_OVERRIDE_UNKNOWN")

    def test_typed_rect2_literal(self) -> None:
        literal = typed_godot_literal("Rect2", [0, 0, 128, 64], "region_rect", lambda *_: "")
        self.assertEqual(literal, "Rect2(Vector2(0, 0), Vector2(128, 64))")

    def test_typed_color_literal(self) -> None:
        literal = typed_godot_literal("Color", "#ffcc00", "self_modulate", lambda *_: "", {"colors.gold": "#d7b269"})
        self.assertTrue(literal.startswith("Color("))

    def test_typed_array_node_path_literal(self) -> None:
        literal = typed_godot_literal("Array[NodePath]", ["../A", "../B"], "focus_neighbor_top", lambda *_: "")
        self.assertIn('NodePath("../A")', literal)
        self.assertIn('NodePath("../B")', literal)

    def test_plain_numeric_array_not_vector_guessed(self) -> None:
        literal = godot_literal("pivot_offset", [10, 20], lambda *_: "")
        self.assertEqual(literal, "[10.0000, 20.0000]")
        self.assertNotIn("Vector2", literal)

    def test_validation_rejects_bogus_override(self) -> None:
        document = {
            "schema_version": 1,
            "name": "bogus_override",
            "viewport": {"width": 640, "height": 480},
            "theme": "dark_fantasy",
            "root": {
                "id": "root",
                "type": "Panel",
                "layout": {"size": [100, 100]},
                "properties": {"godot_overrides": {"totally_made_up_property": 1}},
                "children": [],
            },
        }
        result = validate(document)
        self.assertFalse(result["success"])
        codes = {item.get("code") for item in result.get("diagnostics", [])}
        self.assertIn("GODOT_OVERRIDE_UNKNOWN", codes)

    def test_allow_unsafe_remains_rejected(self) -> None:
        from tests.test_batch2_1_security import run_cli

        with __import__("tempfile").TemporaryDirectory() as directory:
            source = Path(directory) / "screen.ui.json"
            target = Path(directory) / "screen.tscn"
            source.write_text((ROOT / "tests/conformance/fixtures/minimal.ui.json").read_text(encoding="utf-8"), encoding="utf-8")
            payload, code, _ = run_cli("build", str(source), str(target), "--allow-unsafe", "--allow-outside-project")
            self.assertNotEqual(code, 0)
            codes = {item.get("code") for item in payload.get("errors", []) if isinstance(item, dict)}
            self.assertIn("UNKNOWN_OPTION", codes)


if __name__ == "__main__":
    unittest.main()
