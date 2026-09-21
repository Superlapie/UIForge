#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "scripts/ui_fallback.py"
MINIMAL = ROOT / "tests/conformance/fixtures/minimal.ui.json"


def run_cli(*args: str) -> tuple[dict, int, str]:
    process = subprocess.run(["python3", str(CLI), *args], cwd=ROOT, capture_output=True, text=True)
    stdout = process.stdout.strip()
    payload = json.loads(stdout) if stdout else {"success": False, "errors": [{"code": "EMPTY_STDOUT"}]}
    return payload, process.returncode, process.stderr


def codes(payload: dict) -> set[str]:
    found: set[str] = set()
    for key in ("errors", "diagnostics"):
        value = payload.get(key, [])
        if not isinstance(value, list):
            continue
        for item in value:
            if isinstance(item, dict) and item.get("code"):
                found.add(str(item["code"]))
    error = payload.get("error")
    if isinstance(error, dict) and error.get("code"):
        found.add(str(error["code"]))
    return found


class Batch2SecurityTests(unittest.TestCase):
    def test_rejected_build_preserves_hand_authored_scene(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "screen.ui.json"
            target = Path(directory) / "screen.tscn"
            source.write_text(MINIMAL.read_text(encoding="utf-8"), encoding="utf-8")
            original = "[gd_scene load_steps=1 format=3]\n\n[node name=\"Hand\" type=\"Control\"]\n"
            target.write_text(original, encoding="utf-8")
            payload, code, stderr = run_cli("build", str(source), str(target), "--allow-outside-project")
            self.assertFalse(stderr.strip(), msg=stderr)
            self.assertNotEqual(code, 0)
            self.assertIn("OUTPUT_NOT_UIFORGE_GENERATED", codes(payload))
            self.assertEqual(target.read_text(encoding="utf-8"), original)

    def test_same_source_generated_scene_can_update(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "screen.ui.json"
            target = Path(directory) / "screen.tscn"
            source.write_text(MINIMAL.read_text(encoding="utf-8"), encoding="utf-8")
            first, code, _ = run_cli("build", str(source), str(target), "--allow-outside-project")
            self.assertEqual(code, 0, first)
            second, code, _ = run_cli("build", str(source), str(target), "--allow-outside-project")
            self.assertEqual(code, 0, second)
            self.assertIn("UIFORGE_GENERATED_V1", target.read_text(encoding="utf-8"))

    def test_force_overrides_provenance_protection(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "screen.ui.json"
            target = Path(directory) / "screen.tscn"
            other = Path(directory) / "other.ui.json"
            source.write_text(MINIMAL.read_text(encoding="utf-8"), encoding="utf-8")
            other.write_text(MINIMAL.read_text(encoding="utf-8").replace("minimal", "other"), encoding="utf-8")
            run_cli("build", str(source), str(target), "--allow-outside-project")
            payload, code, _ = run_cli("build", str(other), str(target), "--allow-outside-project")
            self.assertNotEqual(code, 0)
            self.assertIn("OUTPUT_SOURCE_MISMATCH", codes(payload))
            forced, code, _ = run_cli("build", str(other), str(target), "--force", "--allow-outside-project")
            self.assertEqual(code, 0, forced)

    def test_ui_new_is_create_only(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "fresh.ui.json"
            target.write_text("{}", encoding="utf-8")
            payload, code, _ = run_cli("new", "blank", str(target), "--allow-outside-project")
            self.assertNotEqual(code, 0)
            self.assertIn("OUTPUT_ALREADY_EXISTS", codes(payload))
            self.assertEqual(target.read_text(encoding="utf-8"), "{}")

    def test_write_conflict_does_not_clobber_newer_source(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "case.ui.json"
            source.write_text(MINIMAL.read_text(encoding="utf-8"), encoding="utf-8")
            revision = json.loads(subprocess.check_output(
                ["python3", "-c", "import json,sys; from pathlib import Path; sys.path.insert(0,'scripts'); from uiforge_contract import file_revision; print(json.dumps(file_revision(sys.argv[1])))", str(source)],
                cwd=ROOT,
                text=True,
            ))
            first = json.loads(source.read_text(encoding="utf-8"))
            second = json.loads(source.read_text(encoding="utf-8"))
            first["metadata"] = {"author": "A"}
            second["metadata"] = {"author": "B"}
            saved_a = subprocess.run(
                ["python3", "-c", "import json,sys; sys.path.insert(0,'scripts'); from uiforge_contract import write_source_atomically; payload=write_source_atomically(sys.argv[1], sys.argv[2], sys.argv[3]); print(json.dumps(payload)); raise SystemExit(0 if payload.get('success') else 1)", str(source), json.dumps(first, indent='\t') + '\n', revision["hash"]],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertEqual(saved_a.returncode, 0, saved_a.stderr)
            source.write_text(json.dumps(second, indent="\t") + "\n", encoding="utf-8")
            saved_b = subprocess.run(
                ["python3", "-c", "import json,sys; sys.path.insert(0,'scripts'); from uiforge_contract import write_source_atomically; payload=write_source_atomically(sys.argv[1], sys.argv[2], sys.argv[3]); print(json.dumps(payload)); raise SystemExit(0 if payload.get('success') else 1)", str(source), json.dumps(second, indent='\t') + '\n', revision["hash"]],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(saved_b.returncode, 0)
            self.assertIn("WRITE_CONFLICT", saved_b.stdout)
            saved = json.loads(source.read_text(encoding="utf-8"))
            self.assertEqual(saved["metadata"]["author"], "B")

    def test_hostile_theme_and_component_shapes_do_not_crash(self) -> None:
        for fixture in (
            "theme_overrides_string.ui.json",
            "theme_overrides_tokens_string.ui.json",
            "components_string.ui.json",
            "component_not_object.ui.json",
            "theme_not_found.ui.json",
        ):
            with self.subTest(fixture=fixture):
                path = ROOT / "tests/conformance/fixtures/invalid" / fixture
                payload, code, stderr = run_cli("validate", str(path))
                self.assertFalse(stderr.strip(), msg=stderr)
                self.assertNotEqual(code, 0)
                self.assertFalse(payload.get("success", True))

    def test_metadata_and_override_spoofing_is_rejected(self) -> None:
        document = json.loads(MINIMAL.read_text(encoding="utf-8"))
        document.setdefault("root", {}).setdefault("properties", {})["godot_overrides"] = {
            "metadata/uiforge_generated": True,
            "script": "res://addons/uiforge/cli/cli_main.gd",
        }
        document["root"]["metadata"] = {"uiforge_generated": True, "bad key": "x"}
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "spoof.ui.json"
            source.write_text(json.dumps(document, indent="\t") + "\n", encoding="utf-8")
            payload, code, _ = run_cli("validate", str(source))
            self.assertNotEqual(code, 0)
            found = codes(payload)
            self.assertTrue({"METADATA_KEY_INVALID", "METADATA_KEY_RESERVED", "GODOT_OVERRIDE_FORBIDDEN", "GODOT_OVERRIDE_UNSAFE"} & found)

    def test_new_scenes_emit_uiforge_namespace_only(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "abi.ui.json"
            target = Path(directory) / "abi.tscn"
            run_cli("new", "blank", str(source), "--allow-outside-project")
            payload, code, _ = run_cli("build", str(source), str(target), "--allow-outside-project")
            self.assertEqual(code, 0, payload)
            scene = target.read_text(encoding="utf-8")
            self.assertIn("metadata/uiforge_id", scene)
            self.assertNotIn("metadata/aether_id", scene)

    def test_output_policy_rejects_outside_workspace(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            outside = Path(directory) / "outside.tscn"
            source = Path(directory) / "inside.ui.json"
            source.write_text(MINIMAL.read_text(encoding="utf-8"), encoding="utf-8")
            payload, code, _ = run_cli("build", str(source), str(outside))
            self.assertNotEqual(code, 0)
            self.assertIn("OUTPUT_OUTSIDE_WORKSPACE", codes(payload))


if __name__ == "__main__":
    unittest.main()
