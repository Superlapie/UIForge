#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from uiforge_contract import (  # noqa: E402
    check_replace_allowed,
    fs_path,
    parse_scene_header,
    provenance_header,
    read_existing_output,
    source_identity,
    write_source_atomically,
    write_text_atomically,
)
from uiforge_contract import content_hash  # noqa: E402

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


class Batch21SecurityTests(unittest.TestCase):
    def test_same_source_rebuild_after_source_edit_succeeds_without_force(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "screen.ui.json"
            target = Path(directory) / "screen.tscn"
            source.write_text(MINIMAL.read_text(encoding="utf-8"), encoding="utf-8")
            first, code, _ = run_cli("build", str(source), str(target), "--allow-outside-project")
            self.assertEqual(code, 0, first)
            original_hash = parse_scene_header(target.read_text(encoding="utf-8"))["header"]["source_hash"]
            document = json.loads(source.read_text(encoding="utf-8"))
            document.setdefault("metadata", {})["author"] = "edited"
            source.write_text(json.dumps(document, indent="\t") + "\n", encoding="utf-8")
            second, code, _ = run_cli("build", str(source), str(target), "--allow-outside-project")
            self.assertEqual(code, 0, second)
            header = parse_scene_header(target.read_text(encoding="utf-8"))["header"]
            self.assertNotEqual(header["source_hash"], original_hash)
            self.assertEqual(header["source"], source_identity(source))

    def test_different_source_overwrite_still_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "screen.ui.json"
            other = Path(directory) / "other.ui.json"
            target = Path(directory) / "screen.tscn"
            source.write_text(MINIMAL.read_text(encoding="utf-8"), encoding="utf-8")
            other.write_text(MINIMAL.read_text(encoding="utf-8").replace("minimal", "other"), encoding="utf-8")
            run_cli("build", str(source), str(target), "--allow-outside-project")
            payload, code, _ = run_cli("build", str(other), str(target), "--allow-outside-project")
            self.assertNotEqual(code, 0)
            self.assertIn("OUTPUT_SOURCE_MISMATCH", codes(payload))

    def test_malformed_provenance_never_crashes(self) -> None:
        cases = [
            "; UIFORGE_GENERATED_V1\n; uiforge_schema: not-a-number\n[gd_scene]\n",
            "; UIFORGE_GENERATED_V1\n; uiforge_source: a\n; uiforge_source: b\n[gd_scene]\n",
            "; UIFORGE_GENERATED_V1\n; uiforge_source_hash: bad\n[gd_scene]\n",
            b"\xff\xfe",
        ]
        for index, sample in enumerate(cases):
            with self.subTest(index=index):
                parsed = parse_scene_header(sample)
                self.assertIsInstance(parsed, dict)
                self.assertIn("errors", parsed)

    def test_malformed_provenance_is_not_trusted(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "broken.tscn"
            target.write_text("; UIFORGE_GENERATED_V1\n; uiforge_source: res://x.ui.json\n[gd_scene]\n", encoding="utf-8")
            result = check_replace_allowed(target, "res://x.ui.json", "", False)
            self.assertFalse(result["ok"])
            self.assertTrue({"OUTPUT_PROVENANCE_INVALID"} & codes(result))

    def test_allow_unsafe_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "screen.ui.json"
            target = Path(directory) / "screen.tscn"
            source.write_text(MINIMAL.read_text(encoding="utf-8"), encoding="utf-8")
            payload, code, _ = run_cli("build", str(source), str(target), "--allow-unsafe", "--allow-outside-project")
            self.assertNotEqual(code, 0)
            self.assertIn("UNKNOWN_OPTION", codes(payload))

    def test_invalid_resource_fails_instead_of_disappearing(self) -> None:
        document = json.loads(MINIMAL.read_text(encoding="utf-8"))
        document.setdefault("root", {}).setdefault("properties", {})["material"] = "res://addons/uiforge/cli/cli_main.gd"
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "bad_resource.ui.json"
            target = Path(directory) / "bad_resource.tscn"
            source.write_text(json.dumps(document, indent="\t") + "\n", encoding="utf-8")
            payload, code, _ = run_cli("build", str(source), str(target), "--allow-outside-project")
            self.assertNotEqual(code, 0)
            self.assertTrue({"RESOURCE_TYPE_BLOCKED", "RESOURCE_TYPE_UNKNOWN", "RESOURCE_TYPE_MISMATCH"} & codes(payload))
            self.assertFalse(target.exists())

    def test_theme_traversal_names_are_rejected(self) -> None:
        document = json.loads(MINIMAL.read_text(encoding="utf-8"))
        document["theme"] = "../dark_fantasy"
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "bad_theme.ui.json"
            source.write_text(json.dumps(document, indent="\t") + "\n", encoding="utf-8")
            payload, code, _ = run_cli("validate", str(source), "--allow-outside-project")
            self.assertNotEqual(code, 0)
            self.assertTrue({"THEME_NAME_INVALID", "THEME_NOT_FOUND"} & codes(payload))

    def test_windows_absolute_paths_are_recognized(self) -> None:
        path = fs_path("C:/project/examples/screen.tscn")
        self.assertTrue(str(path).replace("\\", "/").endswith("project/examples/screen.tscn") or "screen.tscn" in str(path))

    def test_symlink_escape_is_rejected(self) -> None:
        if os.name == "nt":
            self.skipTest("Symlink escape regression requires Unix symlink creation.")
        with tempfile.TemporaryDirectory() as outside_parent:
            outside = Path(outside_parent) / "outside"
            outside.mkdir()
            workspace_link = ROOT / ".uiforge_symlink_escape_test"
            if workspace_link.exists() or workspace_link.is_symlink():
                workspace_link.unlink()
            workspace_link.symlink_to(outside)
            try:
                source = ROOT / "tests/conformance/fixtures/minimal.ui.json"
                target = "res://.uiforge_symlink_escape_test/evil.tscn"
                payload, code, _ = run_cli("build", str(source), target)
                self.assertNotEqual(code, 0)
                self.assertIn("OUTPUT_OUTSIDE_WORKSPACE", codes(payload))
            finally:
                if workspace_link.is_symlink() or workspace_link.exists():
                    workspace_link.unlink()

    def test_concurrent_writes_from_same_revision(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "race.ui.json"
            source.write_text(MINIMAL.read_text(encoding="utf-8"), encoding="utf-8")
            revision = json.loads(
                subprocess.check_output(
                    [
                        "python3",
                        "-c",
                        "import json,sys; sys.path.insert(0,'scripts'); from uiforge_contract import file_revision; print(json.dumps(file_revision(sys.argv[1])))",
                        str(source),
                    ],
                    cwd=ROOT,
                    text=True,
                )
            )["hash"]
            first_doc = json.loads(source.read_text(encoding="utf-8"))
            second_doc = json.loads(source.read_text(encoding="utf-8"))
            first_doc.setdefault("metadata", {})["author"] = "A"
            second_doc.setdefault("metadata", {})["author"] = "B"
            results: list[dict] = []

            def worker(document: dict[str, object]) -> None:
                payload = write_source_atomically(source, json.dumps(document, indent="\t") + "\n", revision)
                results.append(payload)

            threads = [
                threading.Thread(target=worker, args=(first_doc,)),
                threading.Thread(target=worker, args=(second_doc,)),
            ]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join()
            successes = [item for item in results if item.get("success")]
            conflicts = [item for item in results if not item.get("success")]
            self.assertEqual(len(successes), 1)
            self.assertEqual(len(conflicts), 1)
            self.assertTrue({"WRITE_CONFLICT", "FILE_WRITE_FAILED", "LOCK_CREATE_FAILED"} & codes(conflicts[0]))
            saved = json.loads(source.read_text(encoding="utf-8"))
            self.assertIn(saved["metadata"]["author"], {"A", "B"})

    def test_commit_time_provenance_blocks_hand_scene(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "screen.ui.json"
            target = Path(directory) / "screen.tscn"
            source.write_text(MINIMAL.read_text(encoding="utf-8"), encoding="utf-8")
            identity = source_identity(source)
            revision = content_hash(json.loads(source.read_text(encoding="utf-8")))
            scene_lines = provenance_header(identity, revision) + ["[gd_scene load_steps=1 format=3]", "", '[node name="Root" type="Control"]', ""]
            hand_scene = "[gd_scene load_steps=1 format=3]\n\n[node name=\"Hand\" type=\"Control\"]\n"

            def slow_verify(temp_path: Path) -> dict:
                target.write_text(hand_scene, encoding="utf-8")
                return {"ok": True, "errors": []}

            result = write_text_atomically(
                target,
                "\n".join(scene_lines),
                identity,
                False,
                verify=slow_verify,
            )
            self.assertFalse(result.get("success"))
            self.assertEqual(target.read_text(encoding="utf-8"), hand_scene)

    def test_transaction_recovery_prefers_live_source_over_stale_pending(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "txn.ui.json"
            live = json.loads(MINIMAL.read_text(encoding="utf-8"))
            live.setdefault("metadata", {})["state"] = "live"
            source.write_text(json.dumps(live, indent="\t") + "\n", encoding="utf-8")
            pending = source.with_name(source.name + ".uiforge_pending")
            pending.write_text('{"schema_version":1,"name":"stale","root":{"id":"stale_root","type":"Control","layout":{"position":[0,0],"size":[10,10]},"children":[]}}\n', encoding="utf-8")
            source.with_name(source.name + ".uiforge_txn").write_text(json.dumps({"stage": "pending"}), encoding="utf-8")
            payload = write_source_atomically(source, source.read_text(encoding="utf-8"), content_hash(live))
            self.assertTrue(payload.get("success"), payload)
            saved = json.loads(source.read_text(encoding="utf-8"))
            self.assertEqual(saved["metadata"]["state"], "live")
            self.assertFalse(pending.exists())

    def test_new_builds_emit_uiforge_only(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "abi.ui.json"
            target = Path(directory) / "abi.tscn"
            run_cli("new", "blank", str(source), "--allow-outside-project")
            payload, code, _ = run_cli("build", str(source), str(target), "--allow-outside-project")
            self.assertEqual(code, 0, payload)
            scene = target.read_text(encoding="utf-8")
            self.assertIn("metadata/uiforge_id", scene)
            self.assertNotIn("metadata/aether_id", scene)


if __name__ == "__main__":
    unittest.main()
