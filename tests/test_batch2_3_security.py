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
    NEW_LOCK_GRACE_SECONDS,
    _file_text_hash,
    _lock_dir,
    _read_lock_meta,
    _replace_meta_path,
    _try_reclaim_stale_lock,
    _write_replace_meta,
    acquire_lock,
    recover_interrupted_replace,
    reclaim_stale_lock_verified,
    release_lock,
    replace_file,
)

MINIMAL_SCENE = "[gd_scene load_steps=1 format=3]\n\n[node name=\"Root\" type=\"Control\"]\n"
UPDATED_SCENE = "[gd_scene load_steps=1 format=3]\n\n[node name=\"Updated\" type=\"Control\"]\n"


class Batch23SecurityTests(unittest.TestCase):
    def test_recover_restores_missing_destination_from_replace_backup(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "screen.tscn"
            backup = destination.with_name(destination.name + ".uiforge_replace_backup")
            meta = _replace_meta_path(destination)
            backup.write_text(MINIMAL_SCENE, encoding="utf-8")
            _write_replace_meta(
                meta,
                {
                    "transaction_id": "txn-backup-restore",
                    "target": str(destination),
                    "stage": "backup",
                    "backup_hash": _file_text_hash(backup),
                    "new_hash": "sha256:" + "1" * 64,
                },
            )
            recover_interrupted_replace(destination)
            self.assertTrue(destination.exists())
            self.assertEqual(destination.read_text(encoding="utf-8"), MINIMAL_SCENE)
            self.assertFalse(backup.exists())
            self.assertFalse(meta.exists())

    def test_recover_cleans_backup_after_committed_replace(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "screen.tscn"
            backup = destination.with_name(destination.name + ".uiforge_replace_backup")
            meta = _replace_meta_path(destination)
            destination.write_text(UPDATED_SCENE, encoding="utf-8")
            backup.write_text(MINIMAL_SCENE, encoding="utf-8")
            _write_replace_meta(
                meta,
                {
                    "transaction_id": "txn-commit-clean",
                    "target": str(destination),
                    "stage": "commit",
                    "backup_hash": _file_text_hash(backup),
                    "new_hash": _file_text_hash(destination),
                },
            )
            recover_interrupted_replace(destination)
            self.assertEqual(destination.read_text(encoding="utf-8"), UPDATED_SCENE)
            self.assertFalse(backup.exists())
            self.assertFalse(meta.exists())

    def test_recover_orphan_backup_without_meta_restores_missing_destination(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "screen.tscn"
            backup = destination.with_name(destination.name + ".uiforge_replace_backup")
            backup.write_text(MINIMAL_SCENE, encoding="utf-8")
            recover_interrupted_replace(destination)
            self.assertEqual(destination.read_text(encoding="utf-8"), MINIMAL_SCENE)
            self.assertFalse(backup.exists())

    def test_direct_replace_failure_preserves_existing_destination(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "screen.tscn"
            staging = Path(directory) / "screen.tmp.tscn"
            destination.write_text(MINIMAL_SCENE, encoding="utf-8")
            staging.write_text(UPDATED_SCENE, encoding="utf-8")
            with mock.patch("uiforge_contract.os.replace", side_effect=OSError("forced failure")):
                with self.assertRaises(OSError):
                    replace_file(staging, destination)
            self.assertEqual(destination.read_text(encoding="utf-8"), MINIMAL_SCENE)

    def test_stale_reclaim_cannot_evict_replacement_owner(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "owned.ui.json"
            target.write_text("{}", encoding="utf-8")
            lock_dir = _lock_dir(target)
            lock_dir.mkdir()
            (lock_dir / "owner.json").write_text(
                json.dumps({"owner_nonce": "new-owner", "pid": 1, "started": 0.0}),
                encoding="utf-8",
            )
            self.assertFalse(reclaim_stale_lock_verified(lock_dir, "old-owner"))
            self.assertTrue(lock_dir.exists())
            self.assertEqual(_read_lock_meta(lock_dir).get("owner_nonce"), "new-owner")

    def test_stale_reclaim_succeeds_when_owner_unchanged(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "stale.ui.json"
            target.write_text("{}", encoding="utf-8")
            lock_dir = _lock_dir(target)
            lock_dir.mkdir()
            (lock_dir / "owner.json").write_text(
                json.dumps({"owner_nonce": "stale-owner", "pid": 999999, "process_start": "0", "started": time.time() - NEW_LOCK_GRACE_SECONDS - 10}),
                encoding="utf-8",
            )
            self.assertTrue(_try_reclaim_stale_lock(lock_dir))
            self.assertFalse(lock_dir.exists())
            acquired = acquire_lock(target)
            self.assertTrue(acquired["ok"], acquired)
            release_lock(acquired["lock_path"], str(acquired["owner_nonce"]))

    def test_replace_sidecars_absent_after_successful_recovery(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "screen.tscn"
            backup = destination.with_name(destination.name + ".uiforge_replace_backup")
            meta = _replace_meta_path(destination)
            backup.write_text(MINIMAL_SCENE, encoding="utf-8")
            _write_replace_meta(
                meta,
                {
                    "transaction_id": "txn-backup-sidecars",
                    "target": str(destination),
                    "stage": "backup",
                    "backup_hash": _file_text_hash(backup),
                    "new_hash": "sha256:" + "2" * 64,
                },
            )
            recover_interrupted_replace(destination)
            self.assertFalse(backup.exists())
            self.assertFalse(meta.exists())
            self.assertFalse(list(Path(directory).glob("*.uiforge_replace_*")))


if __name__ == "__main__":
    unittest.main()
