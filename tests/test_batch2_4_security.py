#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from uiforge_contract import (  # noqa: E402
    LOCK_STALE_SECONDS,
    NEW_LOCK_GRACE_SECONDS,
    _file_text_hash,
    _lock_dir,
    _lock_is_stale,
    _pid_alive_status,
    _query_process_identity,
    _read_lock_meta,
    _replace_meta_path,
    _try_reclaim_stale_lock,
    _write_replace_meta,
    acquire_lock,
    check_commit_replace_allowed,
    provenance_header,
    read_existing_output,
    recover_interrupted_replace,
    reclaim_stale_lock_verified,
    release_lock,
    write_text_atomically,
)

HUMAN_SCENE = '[gd_scene load_steps=1 format=3]\n\n[node name="HumanRoot" type="Control"]\n'
GENERATED_BODY = '[gd_scene load_steps=1 format=3]\n\n[node name="GeneratedRoot" type="Control"]\n'


def generated_scene(source_identity: str, source_hash: str) -> str:
    return "\n".join(provenance_header(source_identity, source_hash)) + "\n" + GENERATED_BODY


class Batch24SecurityTests(unittest.TestCase):
    def test_live_owner_not_stale_by_age(self) -> None:
        identity = _query_process_identity(__import__("os").getpid())
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "live.ui.json"
            target.write_text("{}", encoding="utf-8")
            lock_dir = _lock_dir(target)
            lock_dir.mkdir()
            (lock_dir / "owner.json").write_text(
                json.dumps(
                    {
                        "owner_nonce": "live-owner",
                        "pid": __import__("os").getpid(),
                        "process_start": identity.get("start_ticks", ""),
                        "started": time.time() - LOCK_STALE_SECONDS - 60,
                    }
                ),
                encoding="utf-8",
            )
            self.assertFalse(_lock_is_stale(lock_dir))
            self.assertFalse(_try_reclaim_stale_lock(lock_dir))

    def test_dead_owner_is_stale(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "dead.ui.json"
            target.write_text("{}", encoding="utf-8")
            lock_dir = _lock_dir(target)
            lock_dir.mkdir()
            (lock_dir / "owner.json").write_text(
                json.dumps({"owner_nonce": "dead-owner", "pid": 999999, "process_start": "0", "started": time.time() - NEW_LOCK_GRACE_SECONDS - 10}),
                encoding="utf-8",
            )
            self.assertTrue(_lock_is_stale(lock_dir))
            self.assertTrue(_try_reclaim_stale_lock(lock_dir))

    def test_provenance_after_recovery_rejects_human_scene(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "human.tscn"
            backup = destination.with_name(destination.name + ".uiforge_replace_backup")
            meta = _replace_meta_path(destination)
            backup.write_text(HUMAN_SCENE, encoding="utf-8")
            _write_replace_meta(
                meta,
                {
                    "transaction_id": "txn-provenance-backup",
                    "target": str(destination),
                    "stage": "backup",
                    "backup_hash": _file_text_hash(backup),
                    "new_hash": "sha256:" + "3" * 64,
                },
            )
            source = ROOT / "tests/conformance/fixtures/minimal.ui.json"
            source_id = f"res://tests/conformance/fixtures/minimal.ui.json"
            result = write_text_atomically(
                destination,
                generated_scene(source_id, "sha256:" + "0" * 64),
                source_id,
                force=False,
            )
            self.assertFalse(result.get("success"))
            codes = {item.get("code") for item in result.get("errors", []) if isinstance(item, dict)}
            self.assertIn("OUTPUT_NOT_UIFORGE_GENERATED", codes)
            self.assertEqual(destination.read_text(encoding="utf-8"), HUMAN_SCENE)

    def test_recovery_conflict_blocks_replace(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "screen.tscn"
            backup = destination.with_name(destination.name + ".uiforge_replace_backup")
            meta = _replace_meta_path(destination)
            destination.write_text(GENERATED_BODY, encoding="utf-8")
            backup.write_text(HUMAN_SCENE, encoding="utf-8")
            _write_replace_meta(
                meta,
                {
                    "transaction_id": "txn-commit-mismatch",
                    "target": str(destination),
                    "stage": "commit",
                    "backup_hash": _file_text_hash(backup),
                    "new_hash": "sha256:" + "f" * 64,
                },
            )
            recovery = recover_interrupted_replace(destination)
            self.assertFalse(recovery.get("ok"))
            self.assertEqual(recovery.get("errors", [{}])[0].get("code"), "REPLACE_RECOVERY_CONFLICT")
            self.assertTrue(backup.exists())

    def test_stale_reclaim_cannot_evict_replacement_owner(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "owned.ui.json"
            target.write_text("{}", encoding="utf-8")
            lock_dir = _lock_dir(target)
            lock_dir.mkdir()
            (lock_dir / "owner.json").write_text(
                json.dumps({"owner_nonce": "new-owner", "pid": 1, "process_start": "0", "started": 0.0}),
                encoding="utf-8",
            )
            self.assertFalse(reclaim_stale_lock_verified(lock_dir, "old-owner"))
            self.assertTrue(lock_dir.exists())
            self.assertEqual(_read_lock_meta(lock_dir).get("owner_nonce"), "new-owner")

    def test_current_process_detected_alive(self) -> None:
        identity = _query_process_identity(__import__("os").getpid())
        self.assertTrue(identity.get("ok"))
        self.assertEqual(
            _pid_alive_status({"pid": __import__("os").getpid(), "process_start": identity.get("start_ticks", "")}),
            "alive",
        )

    def test_bogus_pid_detected_dead(self) -> None:
        self.assertEqual(_pid_alive_status({"pid": 999999, "process_start": "0"}), "dead")


if __name__ == "__main__":
    unittest.main()
