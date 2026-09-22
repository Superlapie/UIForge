#!/usr/bin/env python3
from __future__ import annotations

import secrets
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from uiforge_contract import (  # noqa: E402
    _begin_reclaim_guard,
    _file_text_hash,
    _release_reclaim_guard,
    _release_reclaim_guard_owned,
    _reclaim_guard_path,
    _replace_meta_path,
    _validate_replace_meta,
    _write_replace_meta,
    recover_interrupted_replace,
    validate_output,
)

MINIMAL_SCENE = "[gd_scene load_steps=1 format=3]\n\n[node name=\"Root\" type=\"Control\"]\n"
UPDATED_SCENE = "[gd_scene load_steps=1 format=3]\n\n[node name=\"Updated\" type=\"Control\"]\n"
VALID_TXN = "0123456789abcdef0123456789abcdef"
VALID_TXN_B = "fedcba9876543210fedcba9876543210"


def _full_meta(destination: Path, stage: str, backup_hash: str, new_hash: str, txn_id: str = VALID_TXN) -> dict[str, str]:
    return {
        "transaction_id": txn_id,
        "target": str(destination),
        "stage": stage,
        "backup_hash": backup_hash,
        "new_hash": new_hash,
    }


class Batch251SecurityTests(unittest.TestCase):
    def test_resolver_failure_rejects_containment(self) -> None:
        if sys.platform != "win32":
            self.skipTest("Windows resolver failure regression requires Windows path logic.")
        target = ROOT / ".uiforge/trust/resolver_fail.tscn"
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(MINIMAL_SCENE, encoding="utf-8")
        with mock.patch("uiforge_contract.FORCE_WINDOWS_PATH_RESOLVER_FAILURE", True):
            result = validate_output(f"res://.uiforge/trust/resolver_fail.tscn", ".tscn", False)
        self.assertFalse(result.get("ok"))
        codes = {item.get("code") for item in result.get("errors", []) if isinstance(item, dict)}
        self.assertIn("PATH_CANONICALIZATION_FAILED", codes)

    def test_pre_backup_crash_cleans_stale_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "screen.tscn"
            meta = _replace_meta_path(destination)
            destination.write_text(MINIMAL_SCENE, encoding="utf-8")
            backup_hash = _file_text_hash(destination)
            _write_replace_meta(meta, _full_meta(destination, "backup", backup_hash, "sha256:" + "1" * 64, VALID_TXN_B))
            recovery = recover_interrupted_replace(destination)
            self.assertTrue(recovery.get("ok"), recovery)
            self.assertEqual(recovery.get("status"), "clean")
            self.assertEqual(destination.read_text(encoding="utf-8"), MINIMAL_SCENE)
            self.assertFalse(meta.exists())

    def test_pre_backup_crash_hash_mismatch_conflicts(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "screen.tscn"
            meta = _replace_meta_path(destination)
            destination.write_text(MINIMAL_SCENE, encoding="utf-8")
            _write_replace_meta(meta, _full_meta(destination, "backup", "sha256:" + "f" * 64, "sha256:" + "1" * 64))
            recovery = recover_interrupted_replace(destination)
            self.assertFalse(recovery.get("ok"))
            self.assertEqual(recovery.get("errors", [{}])[0].get("code"), "REPLACE_BACKUP_INVALID")

    def test_pre_install_commit_crash_restores_backup(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "screen.tscn"
            backup = destination.with_name(destination.name + ".uiforge_replace_backup")
            meta = _replace_meta_path(destination)
            backup.write_text(MINIMAL_SCENE, encoding="utf-8")
            new_hash = "sha256:" + "2" * 64
            _write_replace_meta(meta, _full_meta(destination, "commit", _file_text_hash(backup), new_hash))
            recovery = recover_interrupted_replace(destination)
            self.assertTrue(recovery.get("ok"), recovery)
            self.assertEqual(recovery.get("status"), "recovered")
            self.assertEqual(destination.read_text(encoding="utf-8"), MINIMAL_SCENE)
            self.assertFalse(backup.exists())
            self.assertFalse(meta.exists())

    def test_guard_release_without_nonce_is_noop(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "owned.ui.json"
            target.write_text("{}", encoding="utf-8")
            guard = _begin_reclaim_guard(target)
            self.assertTrue(guard.get("ok"))
            nonce = str(guard.get("guard_nonce", ""))
            _release_reclaim_guard(target, "")
            self.assertTrue(_reclaim_guard_path(target).exists())
            _release_reclaim_guard(target, "wrong-nonce")
            self.assertTrue(_reclaim_guard_path(target).exists())
            _release_reclaim_guard_owned(target, nonce)
            self.assertFalse(_reclaim_guard_path(target).exists())

    def test_invalid_transaction_ids_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "screen.tscn"
            destination.write_text(MINIMAL_SCENE, encoding="utf-8")
            for txn_id in ("x", "txn-test", " " + VALID_TXN, VALID_TXN + "0"):
                with self.subTest(transaction_id=txn_id):
                    result = _validate_replace_meta(
                        _full_meta(destination, "commit", _file_text_hash(destination), _file_text_hash(destination), txn_id),
                        destination,
                        "commit",
                    )
                    self.assertFalse(result.get("ok"))
                    self.assertEqual(result.get("code"), "REPLACE_TXN_INVALID")

    def test_replacement_recovery_state_table_expanded(self) -> None:
        cases: list[tuple[str, dict[str, object], str]] = [
            ("clean_empty", {}, "clean"),
            ("dest_only_no_meta", {"dest": True}, "clean"),
            ("orphan_backup", {"backup": True}, "recovered"),
            ("dest_backup_no_meta", {"dest": True, "backup": True}, "conflict"),
            ("pre_backup_crash", {"dest": True, "meta": True, "stage": "backup", "pre_backup": True}, "clean"),
            ("backup_stage_after_rename", {"backup": True, "meta": True, "stage": "backup"}, "recovered"),
            ("commit_before_install", {"backup": True, "meta": True, "stage": "commit", "pre_install": True}, "recovered"),
            ("dest_backup_commit_clean", {"dest": True, "backup": True, "meta": True, "stage": "commit", "match": True}, "clean"),
            ("dest_backup_backup_stage", {"dest": True, "backup": True, "meta": True, "stage": "backup"}, "conflict"),
            ("complete_clean", {"dest": True, "meta": True, "stage": "complete", "match": True}, "clean"),
            ("meta_only", {"meta": True, "stage": "backup"}, "conflict"),
            ("target_mismatch", {"dest": True, "meta": True, "stage": "backup", "bad_target": True}, "conflict"),
            ("old_hash_mismatch", {"dest": True, "backup": True, "meta": True, "stage": "commit", "bad_backup_hash": True}, "conflict"),
            ("new_hash_mismatch", {"dest": True, "backup": True, "meta": True, "stage": "commit", "bad_new_hash": True}, "conflict"),
            ("malformed_meta", {"dest": True, "backup": True, "meta": True, "stage": "commit", "malformed": True}, "conflict"),
        ]
        for name, spec, expected_status in cases:
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
                        backup_hash = _file_text_hash(backup) if backup.exists() else dest_hash
                        if spec.get("pre_backup"):
                            backup_hash = dest_hash
                        target = str(Path("/other/target.tscn")) if spec.get("bad_target") else str(destination)
                        if spec.get("malformed"):
                            payload = {"target": str(destination), "stage": stage}
                        elif spec.get("bad_backup_hash"):
                            payload = _full_meta(destination, stage, "sha256:" + "b" * 64, dest_hash)
                        elif spec.get("bad_new_hash"):
                            payload = _full_meta(destination, stage, backup_hash, "sha256:" + "f" * 64)
                        elif spec.get("pre_install"):
                            payload = _full_meta(destination, "commit", backup_hash, "sha256:" + "2" * 64)
                        elif spec.get("match") is False:
                            payload = _full_meta(destination, stage, backup_hash, "sha256:" + "f" * 64)
                        else:
                            payload = _full_meta(Path(target) if spec.get("bad_target") else destination, stage, backup_hash, dest_hash, secrets.token_hex(16))
                            payload["target"] = target
                        _write_replace_meta(meta, payload)
                    recovery = recover_interrupted_replace(destination)
                    if expected_status == "conflict":
                        self.assertFalse(recovery.get("ok"), recovery)
                    else:
                        self.assertTrue(recovery.get("ok"), recovery)
                        self.assertEqual(recovery.get("status"), expected_status)


if __name__ == "__main__":
    unittest.main()
