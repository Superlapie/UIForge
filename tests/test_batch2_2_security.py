#!/usr/bin/env python3
from __future__ import annotations

import json
import multiprocessing
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from uiforge_contract import (  # noqa: E402
    acquire_lock,
    content_hash,
    file_revision,
    parse_scene_header,
    provenance_header,
    recover_interrupted_source,
    release_lock,
    replace_file,
    resource_id_part,
    types_compatible,
    validate_scene_text_ids,
    verify_scene_syntax,
    write_source_atomically,
    write_text_atomically,
)

CLI = ROOT / "scripts/ui_fallback.py"
MINIMAL = ROOT / "tests/conformance/fixtures/minimal.ui.json"
FOO_BAR = ROOT / "tests/compiler_conformance/fixtures/foo-bar.ui.json"
CROSS_PROCESS_ITERATIONS = 25


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
    return found


def _write_worker(source: str, revision: str, marker: str, queue: multiprocessing.Queue) -> None:
    result: dict = {"success": False, "errors": [{"code": "WORKER_FAILED"}]}
    try:
        sys.path.insert(0, str(ROOT / "scripts"))
        from uiforge_contract import write_source_atomically as write_source

        path = Path(source)
        document = None
        for _ in range(20):
            try:
                document = json.loads(path.read_text(encoding="utf-8"))
                break
            except FileNotFoundError:
                time.sleep(0.01)
        if document is None:
            raise FileNotFoundError(source)
        document.setdefault("metadata", {})["marker"] = marker
        result = write_source(path, json.dumps(document, indent="\t") + "\n", revision)
    except Exception as exc:
        result = {"success": False, "errors": [{"code": "WORKER_EXCEPTION", "message": str(exc)}]}
    finally:
        queue.put(result)


class Batch22SecurityTests(unittest.TestCase):
    def test_resource_id_part_is_unique_and_valid(self) -> None:
        samples = ["foo-bar", "foo_bar", "foo__bar", "foo_-bar"]
        encoded = [resource_id_part(value) for value in samples]
        self.assertEqual(len(set(encoded)), len(samples))
        for value in encoded:
            self.assertRegex(value, r"^[A-Za-z0-9_]+$")

    def test_foo_bar_fixture_build_has_valid_scene_ids(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "foo-bar.tscn"
            payload, code, stderr = run_cli("build", str(FOO_BAR), str(target), "--force", "--allow-outside-project")
            self.assertEqual(code, 0, payload)
            scene = target.read_text(encoding="utf-8")
            id_check = validate_scene_text_ids(scene)
            self.assertTrue(id_check["ok"], id_check["errors"])
            self.assertNotIn("scene unique ID", stderr)

    def test_subprocess_concurrent_writes_from_same_revision(self) -> None:
        ctx = multiprocessing.get_context("spawn")
        for _ in range(CROSS_PROCESS_ITERATIONS):
            with tempfile.TemporaryDirectory() as directory:
                source = Path(directory) / "race.ui.json"
                source.write_text(MINIMAL.read_text(encoding="utf-8"), encoding="utf-8")
                revision = file_revision(source)["hash"]
                queue: multiprocessing.Queue = ctx.Queue()
                processes = [
                    ctx.Process(target=_write_worker, args=(str(source), revision, "A", queue)),
                    ctx.Process(target=_write_worker, args=(str(source), revision, "B", queue)),
                ]
                for process in processes:
                    process.start()
                for process in processes:
                    process.join()
                results = [queue.get(timeout=60) for _ in processes]
                successes = [item for item in results if item.get("success")]
                conflicts = [item for item in results if not item.get("success")]
                self.assertEqual(len(successes), 1)
                self.assertEqual(len(conflicts), 1)
                self.assertTrue({"WRITE_CONFLICT", "LOCK_CREATE_FAILED", "FILE_WRITE_FAILED"} & codes(conflicts[0]))
                saved = json.loads(source.read_text(encoding="utf-8"))
                self.assertIn(saved["metadata"]["marker"], {"A", "B"})
                for pattern in ("*.uiforge_backup", "*.uiforge_pending", "*.uiforge_txn", "*.uiforge_lock"):
                    self.assertEqual(list(source.parent.glob(pattern)), [], pattern)

    def test_lock_release_is_ownership_safe(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "owned.ui.json"
            target.write_text("{}", encoding="utf-8")
            first = acquire_lock(target)
            self.assertTrue(first["ok"], first)
            second = acquire_lock(target)
            self.assertFalse(second["ok"])
            release_lock(first["lock_path"], "wrong-nonce")
            self.assertTrue(first["lock_path"].exists())
            release_lock(first["lock_path"], str(first["owner_nonce"]))
            self.assertFalse(first["lock_path"].exists())
            third = acquire_lock(target)
            self.assertTrue(third["ok"], third)
            release_lock(first["lock_path"], str(first["owner_nonce"]))
            self.assertTrue(third["lock_path"].exists())
            release_lock(third["lock_path"], str(third["owner_nonce"]))

    def test_replace_file_preserves_destination_on_failure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "scene.tscn"
            staging = Path(directory) / "scene.tmp.tscn"
            original = "[gd_scene]\n\n[node name=\"Root\" type=\"Control\"]\n"
            replacement = "[gd_scene]\n\n[node name=\"Broken\" type=\"Control\"]\n"
            destination.write_text(original, encoding="utf-8")
            staging.write_text(replacement, encoding="utf-8")
            with mock.patch("uiforge_contract.os.replace", side_effect=[None, OSError("forced failure"), None]):
                with self.assertRaises(OSError):
                    replace_file(staging, destination)
            self.assertEqual(destination.read_text(encoding="utf-8"), original)

    def test_transaction_recovery_rejects_untrusted_pending(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "txn.ui.json"
            live = json.loads(MINIMAL.read_text(encoding="utf-8"))
            live.setdefault("metadata", {})["state"] = "live"
            source.write_text(json.dumps(live, indent="\t") + "\n", encoding="utf-8")
            pending = source.with_name(source.name + ".uiforge_pending")
            pending.write_text(
                '{"schema_version":1,"name":"stale","root":{"id":"stale_root","type":"Control","layout":{"position":[0,0],"size":[10,10]},"children":[]}}\n',
                encoding="utf-8",
            )
            source.with_name(source.name + ".uiforge_txn").write_text(json.dumps({"stage": "pending"}), encoding="utf-8")
            recover_interrupted_source(source)
            saved = json.loads(source.read_text(encoding="utf-8"))
            self.assertEqual(saved["metadata"]["state"], "live")
            self.assertFalse(pending.exists())

    def test_transaction_recovery_promotes_valid_commit_stage(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "txn.ui.json"
            pending_doc = json.loads(MINIMAL.read_text(encoding="utf-8"))
            pending_doc.setdefault("metadata", {})["state"] = "pending_commit"
            pending_text = json.dumps(pending_doc, indent="\t") + "\n"
            pending = source.with_name(source.name + ".uiforge_pending")
            pending.write_text(pending_text, encoding="utf-8")
            pending_hash = f"sha256:{__import__('hashlib').sha256(pending_text.encode('utf-8')).hexdigest()}"
            source.with_name(source.name + ".uiforge_txn").write_text(
                json.dumps(
                    {
                        "transaction_id": "txn-1",
                        "target": str(source),
                        "expected_revision": "",
                        "new_revision": content_hash(pending_doc),
                        "pending_hash": pending_hash,
                        "stage": "commit",
                    }
                ),
                encoding="utf-8",
            )
            recover_interrupted_source(source)
            saved = json.loads(source.read_text(encoding="utf-8"))
            self.assertEqual(saved["metadata"]["state"], "pending_commit")

    def test_transaction_recovery_cleans_completed_sidecars(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "txn.ui.json"
            document = json.loads(MINIMAL.read_text(encoding="utf-8"))
            source.write_text(json.dumps(document, indent="\t") + "\n", encoding="utf-8")
            revision = content_hash(document)
            source.with_name(source.name + ".uiforge_backup").write_text("{}", encoding="utf-8")
            source.with_name(source.name + ".uiforge_txn").write_text(
                json.dumps({"target": str(source), "new_revision": revision, "stage": "commit"}),
                encoding="utf-8",
            )
            recover_interrupted_source(source)
            self.assertFalse(source.with_name(source.name + ".uiforge_backup").exists())
            self.assertFalse(source.with_name(source.name + ".uiforge_txn").exists())

    def test_provenance_duplicate_generator_and_schema(self) -> None:
        header_lines = provenance_header("res://x.ui.json", "sha256:" + "a" * 64)
        duplicate = header_lines + ["; uiforge_generator: extra", "; uiforge_schema: 1", "[gd_scene]\n"]
        parsed = parse_scene_header("\n".join(duplicate))
        self.assertFalse(parsed["ok"])
        self.assertIn("OUTPUT_PROVENANCE_INVALID", codes(parsed))

    def test_unsupported_provenance_version_is_rejected(self) -> None:
        parsed = parse_scene_header("; UIFORGE_GENERATED_V2\n; uiforge_source: res://x.ui.json\n[gd_scene]\n")
        self.assertFalse(parsed["header"]["trusted"])
        self.assertIn("OUTPUT_PROVENANCE_INVALID", codes(parsed))

    def test_types_compatible_direction(self) -> None:
        self.assertTrue(types_compatible("CompressedTexture2D", "Texture2D"))
        self.assertFalse(types_compatible("Texture2D", "CompressedTexture2D"))
        self.assertTrue(types_compatible("ShaderMaterial", "Material"))
        self.assertFalse(types_compatible("Material", "ShaderMaterial"))

    def test_verify_scene_syntax_rejects_invalid_ids(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            scene = Path(directory) / "bad.tscn"
            header = provenance_header("res://x.ui.json", "sha256:" + "b" * 64)
            scene.write_text("\n".join(header + ['[gd_scene load_steps=2 format=3]', '', '[sub_resource type="StyleBoxFlat" id="bad-id"]', ""]) , encoding="utf-8")
            result = verify_scene_syntax(scene)
            self.assertFalse(result["ok"])
            self.assertIn("SCENE_RESOURCE_ID_INVALID", codes(result))

    @unittest.skipUnless(os.name == "nt", "Windows-specific path coverage")
    def test_windows_drive_and_backslash_paths(self) -> None:
        from uiforge_contract import fs_path, validate_output

        checked = validate_output("C:\\project\\screen.tscn", ".tscn", allow_outside_project=True)
        self.assertTrue(checked["ok"], checked)
        path = fs_path("C:/project/examples/screen.tscn")
        self.assertIn("screen.tscn", str(path))


if __name__ == "__main__":
    unittest.main()
