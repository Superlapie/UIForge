#!/usr/bin/env python3
from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "scripts/ui_fallback.py"


def run(*args: str) -> tuple[dict, int]:
    process = subprocess.run(["python3", str(CLI), *args], cwd=ROOT, capture_output=True, text=True)
    return json.loads(process.stdout), process.returncode


class AetherFallbackTests(unittest.TestCase):
    def test_atlas_templates_and_regions(self) -> None:
        caps, code = run("capabilities")
        self.assertEqual(code, 0)
        templates = caps["capabilities"]["templates"]
        self.assertIn("inventory", templates)
        self.assertIn("ui_atlas", templates)
        with tempfile.TemporaryDirectory() as directory:
            for key in templates:
                source = Path(directory) / f"{key}.ui.json"
                result, code = run("new", key, str(source))
                self.assertEqual(code, 0, (key, result))
                result, code = run("validate", str(source))
                self.assertEqual(code, 0, (key, result))
                result, code = run("build", str(source), str(source.with_suffix(".tscn")))
                self.assertEqual(code, 0, (key, result))
            source = Path(directory) / "inventory.ui.json"
            data = json.loads(source.read_text())
            self.assertEqual(data["metadata"]["template"], "inventory")
            scene = source.with_suffix(".tscn").read_text()
            self.assertIn('type="AtlasTexture"', scene)
            self.assertIn("region = Rect2(0.0000, 0.0000, 362.0000, 362.0000)", scene)
            for region in ([0, 0, -1, 10], [0, 0, 1], [0, 0, "bad", 10], [False, 0, 10, 10]):
                run("set", str(source), "backpack_slots_00_icon", "properties.texture_region", json.dumps(region))
                result, code = run("validate", str(source))
                self.assertNotEqual(code, 0)
                self.assertIn("TEXTURE_REGION_INVALID", {v["code"] for v in result["diagnostics"]})
            missing = Path(directory) / "unknown.ui.json"
            result, code = run("new", "unknown", str(missing))
            self.assertNotEqual(code, 0)
            self.assertFalse(missing.exists())

    def test_examples_are_valid_documents(self) -> None:
        for path in sorted((ROOT / "examples/specs").glob("*.ui.json")):
            result, code = run("validate", str(path))
            self.assertEqual(code, 0, (path, result))
            self.assertTrue(result["success"], path)

    def test_invalid_documents_fail_with_machine_diagnostics(self) -> None:
        result, code = run("validate", str(ROOT / "tests/fixtures/invalid_duplicate.ui.json"))
        self.assertNotEqual(code, 0)
        self.assertFalse(result["success"])
        self.assertIn("DUPLICATE_ID", {item["code"] for item in result["diagnostics"]})
        result, code = run("validate", str(ROOT / "tests/fixtures/invalid_token.ui.json"))
        self.assertNotEqual(code, 0)
        self.assertIn("TOKEN_NOT_FOUND", {item["code"] for item in result["diagnostics"]})
        document = {"schema_version": 1, "name": "invalid_contract", "viewport": {"width": 800, "height": 600}, "theme": "dark_fantasy", "root": {"id": "root", "type": "ComponentInstance", "component": "MissingComponent", "properties": {"not_a_godot_property": True}}}
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "invalid_contract.ui.json"
            source.write_text(json.dumps(document), encoding="utf-8")
            result, code = run("validate", str(source))
            self.assertNotEqual(code, 0)
            self.assertIn("UNKNOWN_COMPONENT", {item["code"] for item in result["diagnostics"]})
            self.assertIn("UNSUPPORTED_PROPERTY", {item["code"] for item in result["diagnostics"]})

    def test_inspect_and_stable_node_operation(self) -> None:
        source = ROOT / "examples/specs/inventory.ui.json"
        result, code = run("get", str(source), "inventory_grid", "properties.columns")
        self.assertEqual(code, 0)
        self.assertEqual(result["value"], 4)
        with tempfile.TemporaryDirectory() as directory:
            copy = Path(directory) / "inventory.ui.json"
            copy.write_text(source.read_text(encoding="utf-8"), encoding="utf-8")
            result, code = run("set", str(copy), "inventory_grid", "properties.columns", "10")
            self.assertEqual(code, 0)
            result, code = run("get", str(copy), "inventory_grid", "properties.columns")
            self.assertEqual(result["value"], 10)

    def test_all_examples_compile_to_generated_scenes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            result, code = run("build-all", str(ROOT / "examples/specs"), directory)
            self.assertEqual(code, 0, result)
            self.assertEqual(len(result["built"]), 9)
            for scene in Path(directory).glob("*.tscn"):
                text = scene.read_text(encoding="utf-8")
                self.assertIn("GENERATED BY UIForge", text)
                self.assertIn("metadata/aether_id", text)
                self.assertIn("[node", text)

    def test_capabilities_are_machine_readable(self) -> None:
        result, code = run("capabilities")
        self.assertEqual(code, 0)
        self.assertIn("ItemGrid", result["capabilities"]["components"])
        self.assertIn("1920", json.dumps(result["capabilities"]))

    def test_shipped_json_schema_accepts_examples(self) -> None:
        try:
            import jsonschema
        except ImportError:
            self.skipTest("jsonschema is optional; the schema file remains part of the project contract")
        schema = json.loads((ROOT / "schemas/aether-ui.schema.json").read_text(encoding="utf-8"))
        for path in sorted((ROOT / "examples/specs").glob("*.ui.json")) + sorted((ROOT / "examples/atlas").glob("*.ui.json")):
            jsonschema.Draft202012Validator(schema).validate(json.loads(path.read_text(encoding="utf-8")))

    def test_component_instance_is_materialized_by_fallback_compiler(self) -> None:
        document = {
            "schema_version": 1,
            "name": "component_instance",
            "viewport": {"width": 800, "height": 600},
            "theme": "dark_fantasy",
            "components": {"ConfirmButton": {"base": "PrimaryButton", "properties": {"text": "CONFIRM"}}},
            "root": {"id": "root", "type": "Control", "children": [{"id": "confirm", "type": "ComponentInstance", "component": "ConfirmButton", "overrides": {"properties": {"text": "YES"}}}]},
        }
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "component_instance.ui.json"
            output = Path(directory) / "component_instance.tscn"
            source.write_text(json.dumps(document), encoding="utf-8")
            result, code = run("build", str(source), str(output))
            self.assertEqual(code, 0, result)
            scene = output.read_text(encoding="utf-8")
            self.assertIn('type="Button"', scene)
            self.assertIn('text = "YES"', scene)

    def test_full_property_fixture_is_valid_and_buildable(self) -> None:
        source = ROOT / "tests/fixtures/full_properties.ui.json"
        result, code = run("validate", str(source))
        self.assertEqual(code, 0, result)
        self.assertTrue(result["success"], result)
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "full_properties.tscn"
            result, code = run("build", str(source), str(output))
            self.assertEqual(code, 0, result)
            scene = output.read_text(encoding="utf-8")
            self.assertIn("aether_gem.svg", scene)
            self.assertIn("metadata/aether_transitions", scene)
            self.assertIn("metadata/aether_effects", scene)

    def test_document_theme_override_and_native_property_escape_hatch(self) -> None:
        document = {
            "schema_version": 1,
            "name": "theme_override",
            "viewport": {"width": 800, "height": 600},
            "theme": "dark_fantasy",
            "theme_overrides": {"styles": {"gem_frame": {"texture": "res://examples/assets/aether_gem.svg", "texture_margin_left": 12, "texture_margin_top": 12, "texture_margin_right": 12, "texture_margin_bottom": 12}}},
            "root": {"id": "root", "type": "Panel", "style": "gem_frame", "children": [{"id": "label", "type": "Label", "properties": {"godot_overrides": {"theme_override_colors/font_color": "$colors.gold"}}}]},
        }
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "theme_override.ui.json"
            output = Path(directory) / "theme_override.tscn"
            source.write_text(json.dumps(document), encoding="utf-8")
            result, code = run("build", str(source), str(output))
            self.assertEqual(code, 0, result)
            scene = output.read_text(encoding="utf-8")
            self.assertIn("StyleBoxTexture", scene)
            self.assertIn("theme_override_colors/font_color", scene)


if __name__ == "__main__":
    unittest.main(verbosity=2)
