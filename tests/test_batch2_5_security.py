#!/usr/bin/env python3
from __future__ import annotations

import json
import secrets
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from uiforge_contract import (  # noqa: E402
    NEW_LOCK_GRACE_SECONDS,
    _begin_reclaim_guard,
    _ensure_reclaim_guard_clear,
    _file_text_hash,
    _read_lock_meta,
    _reclaim_guard_path,
    _reclaim_stale_guard_verified,
    _release_reclaim_guard_owned,
    _replace_meta_path,
    _validate_replace_meta,
    _write_replace_meta,
    acquire_lock,
    recover_interrupted_replace,
    release_lock,
)

MINIMAL_SCENE = "[gd_scene load_steps=1 format=3]\n\n[node name=\"Root\" type=\"Control\"]\n"
UPDATED_SCENE = "[gd_scene load_steps=1 format=3]\n\n[node name=\"Updated\" type=\"Control\"]\n"


VALID_TXN = "0123456789abcdef0123456789abcdef"


def _full_meta(destination: Path, stage: str, backup_hash: str, new_hash: str, txn_id: str = VALID_TXN) -> dict[str, str]:
    return {
        "transaction_id": txn_id,
        "target": str(destination),
        "stage": stage,
        "backup_hash": backup_hash,
        "new_hash": new_hash,
    }


class Batch25SecurityTests(unittest.TestCase):
    def test_live_reclaim_guard_blocks_acquisition(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "target.ui.json"
            target.write_text("{}", encoding="utf-8")
            guard = _begin_reclaim_guard(target)
            self.assertTrue(guard.get("ok"))
            acquired = acquire_lock(target)
            self.assertFalse(acquired.get("ok"))
            _release_reclaim_guard_owned(target, str(guard.get("guard_nonce", "")))

    def test_dead_reclaim_guard_is_recovered(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "stale.ui.json"
            target.write_text("{}", encoding="utf-8")
            guard_dir = _reclaim_guard_path(target)
            guard_dir.mkdir()
            (guard_dir / "owner.json").write_text(
                json.dumps(
                    {
                        "owner_nonce": "dead-guard",
                        "pid": 999999,
                        "process_start": "0",
                        "started": time.time() - NEW_LOCK_GRACE_SECONDS - 10,
                    }
                ),
                encoding="utf-8",
            )
            self.assertTrue(_ensure_reclaim_guard_clear(target))
            self.assertFalse(guard_dir.exists())

    def test_wrong_nonce_cannot_release_guard(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "owned.ui.json"
            target.write_text("{}", encoding="utf-8")
            guard = _begin_reclaim_guard(target)
            self.assertTrue(guard.get("ok"))
            _release_reclaim_guard_owned(target, "wrong-nonce")
            self.assertTrue(_reclaim_guard_path(target).exists())
            _release_reclaim_guard_owned(target, str(guard.get("guard_nonce", "")))
            self.assertFalse(_reclaim_guard_path(target).exists())

    def test_new_guard_protected_during_grace_period(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "fresh.ui.json"
            target.write_text("{}", encoding="utf-8")
            guard = _begin_reclaim_guard(target)
            self.assertTrue(guard.get("ok"))
            self.assertFalse(_reclaim_stale_guard_verified(_reclaim_guard_path(target)))
            _release_reclaim_guard_owned(target, str(guard.get("guard_nonce", "")))

    def test_crashed_reclaimer_does_not_block_future_writes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "recover.ui.json"
            target.write_text("{}", encoding="utf-8")
            guard_dir = _reclaim_guard_path(target)
            guard_dir.mkdir()
            (guard_dir / "owner.json").write_text(
                json.dumps(
                    {
                        "owner_nonce": "crashed-guard",
                        "pid": 999999,
                        "process_start": "0",
                        "started": time.time() - NEW_LOCK_GRACE_SECONDS - 10,
                    }
                ),
                encoding="utf-8",
            )
            acquired = acquire_lock(target)
            self.assertTrue(acquired.get("ok"), acquired)
            release_lock(acquired.get("lock_path"), str(acquired.get("owner_nonce")))
            self.assertFalse(guard_dir.exists())
            self.assertFalse(list(Path(directory).glob("*.reclaim_*")))

    def test_recovered_guard_leaves_no_sidecars(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "sidecar.ui.json"
            target.write_text("{}", encoding="utf-8")
            guard_dir = _reclaim_guard_path(target)
            guard_dir.mkdir()
            (guard_dir / "owner.json").write_text(
                json.dumps(
                    {
                        "owner_nonce": "sidecar-guard",
                        "pid": 999999,
                        "process_start": "0",
                        "started": time.time() - NEW_LOCK_GRACE_SECONDS - 10,
                    }
                ),
                encoding="utf-8",
            )
            self.assertTrue(_reclaim_stale_guard_verified(guard_dir))
            self.assertFalse(guard_dir.exists())
            self.assertFalse(list(Path(directory).glob("*.reclaim_*")))

    def test_malformed_commit_metadata_preserves_backup(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "screen.tscn"
            backup = destination.with_name(destination.name + ".uiforge_replace_backup")
            meta = _replace_meta_path(destination)
            destination.write_text(UPDATED_SCENE, encoding="utf-8")
            backup.write_text(MINIMAL_SCENE, encoding="utf-8")
            _write_replace_meta(meta, {"target": str(destination), "stage": "commit"})
            recovery = recover_interrupted_replace(destination)
            self.assertFalse(recovery.get("ok"))
            self.assertEqual(recovery.get("errors", [{}])[0].get("code"), "REPLACE_TXN_INVALID")
            self.assertTrue(backup.exists())
            self.assertTrue(destination.exists())

    def test_replacement_recovery_state_table(self) -> None:
        cases: list[tuple[str, dict[str, object], str, bool, bool, bool]] = [
            ("dest_missing_backup_orphan", {"dest": False, "backup": True, "meta": False}, "recovered", True, False, False),
            ("dest_backup_commit_hashes_match", {"dest": True, "backup": True, "meta": True, "stage": "commit", "match": True}, "clean", False, False, False),
            ("dest_backup_commit_missing_new_hash", {"dest": True, "backup": True, "meta": True, "stage": "commit", "missing_new": True}, "conflict", True, True, True),
            ("dest_backup_commit_wrong_new_hash", {"dest": True, "backup": True, "meta": True, "stage": "commit", "match": False}, "conflict", True, True, True),
            ("dest_backup_backup_stage", {"dest": True, "backup": True, "meta": True, "stage": "backup", "match": True}, "conflict", True, True, True),
            ("dest_only_stale_complete", {"dest": True, "backup": False, "meta": True, "stage": "complete", "match": True}, "clean", False, False, False),
            ("dest_backup_no_meta", {"dest": True, "backup": True, "meta": False}, "conflict", True, True, False),
            ("meta_only", {"dest": False, "backup": False, "meta": True, "stage": "backup"}, "conflict", False, False, True),
        ]
        for name, spec, expected_status, keep_dest, keep_backup, keep_meta in cases:
            with self.subTest(name=name):
                with tempfile.TemporaryDirectory() as directory:
                    destination = Path(directory) / "state.tscn"
                    backup = destination.with_name(destination.name + ".uiforge_replace_backup")
                    meta = _replace_meta_path(destination)
                    if spec.get("dest"):
                        destination.write_text(UPDATED_SCENE, encoding="utf-8")
                    if spec.get("backup"):
                        backup.write_text(MINIMAL_SCENE, encoding="utf-8")
                    if spec.get("meta"):
                        stage = str(spec.get("stage", "commit"))
                        dest_hash = _file_text_hash(destination) if destination.exists() else "sha256:" + "a" * 64
                        backup_hash = _file_text_hash(backup) if backup.exists() else "sha256:" + "b" * 64
                        if spec.get("missing_new"):
                            payload = {
                                "transaction_id": VALID_TXN,
                                "target": str(destination),
                                "stage": stage,
                                "backup_hash": backup_hash,
                            }
                        elif spec.get("match") is False:
                            payload = _full_meta(destination, stage, backup_hash, "sha256:" + "f" * 64, VALID_TXN)
                        else:
                            payload = _full_meta(destination, stage, backup_hash, dest_hash, secrets.token_hex(16))
                        _write_replace_meta(meta, payload)
                    recovery = recover_interrupted_replace(destination)
                    if expected_status == "conflict":
                        self.assertFalse(recovery.get("ok"), recovery)
                    else:
                        self.assertTrue(recovery.get("ok"), recovery)
                        self.assertEqual(recovery.get("status"), expected_status)
                    if expected_status == "recovered":
                        self.assertTrue(destination.exists())
                        self.assertFalse(backup.exists())
                    elif expected_status == "clean":
                        self.assertTrue(destination.exists())
                        self.assertFalse(backup.exists())
                        self.assertFalse(meta.exists())
                    else:
                        self.assertEqual(destination.exists(), keep_dest)
                        self.assertEqual(backup.exists(), keep_backup)
                        self.assertEqual(meta.exists(), keep_meta)

    def test_validate_replace_meta_requires_complete_fields(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "screen.tscn"
            destination.write_text(MINIMAL_SCENE, encoding="utf-8")
            valid = _validate_replace_meta(
                _full_meta(destination, "commit", _file_text_hash(destination), _file_text_hash(destination)),
                destination,
                "commit",
            )
            self.assertTrue(valid.get("ok"))
            invalid = _validate_replace_meta({"target": str(destination), "stage": "commit"}, destination, "commit")
            self.assertFalse(invalid.get("ok"))
            self.assertEqual(invalid.get("code"), "REPLACE_TXN_INVALID")


if __name__ == "__main__":
    unittest.main()
