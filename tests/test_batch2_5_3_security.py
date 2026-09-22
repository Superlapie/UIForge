#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from uiforge_contract import (  # noqa: E402
    NEW_LOCK_GRACE_SECONDS,
    _coerce_process_start,
    _directory_age_seconds,
    _lock_dir,
    _lock_is_stale,
    _owner_meta_valid,
    _parse_positive_int,
    _parse_timestamp,
    _pid_alive_status,
    _reclaim_abandoned_publication,
    _reclaim_guard_path,
    _reclaim_stale_directory,
    acquire_lock,
    release_lock,
)

GRACE_PLUS = NEW_LOCK_GRACE_SECONDS + 2

STRUCTURALLY_INVALID_METADATA = [
    ("invalid_pid", {"owner_nonce": "abc", "pid": "not-a-number", "started": 1}),
    ("invalid_started", {"owner_nonce": "abc", "pid": 123, "started": "not-a-number"}),
    ("invalid_nonce_type", {"owner_nonce": [], "pid": 123, "started": 123}),
    ("invalid_pid_type", {"owner_nonce": "abc", "pid": {}, "started": 123}),
    ("invalid_pid_bool", {"owner_nonce": "abc", "pid": True, "started": 123}),
]

MALFORMED_LIVENESS_CASES = [
    {"pid": "banana"},
    {"pid": None},
    {"pid": []},
    {"pid": {}},
    {"pid": True},
    {"pid": -1},
    {"pid": 10**30},
    {"started": "potato"},
    {"owner_nonce": []},
    {"owner_nonce": {}},
    {"process_start": []},
    {"process_start": {}},
]


def _age_directory(path: Path, seconds: float) -> None:
    old = time.time() - seconds
    if os.name == "nt":
        escaped = str(path).replace("'", "''")
        ps = (
            f"(Get-Item -LiteralPath '{escaped}').LastWriteTime = "
            f"[DateTimeOffset]::FromUnixTimeSeconds({int(old)}).LocalDateTime"
        )
        subprocess.run(
            ["powershell.exe", "-NoProfile", "-Command", ps],
            check=True,
            capture_output=True,
            text=True,
        )
        return
    os.utime(path, (old, old))


class Batch253SecurityTests(unittest.TestCase):
    def test_owner_meta_valid_rejects_structural_errors(self) -> None:
        for name, payload in STRUCTURALLY_INVALID_METADATA:
            with self.subTest(name=name):
                self.assertFalse(_owner_meta_valid(payload))

    def test_structurally_invalid_metadata_protected_while_fresh(self) -> None:
        for name, payload in STRUCTURALLY_INVALID_METADATA:
            with self.subTest(name=name):
                with tempfile.TemporaryDirectory() as directory:
                    target = Path(directory) / f"{name}.ui.json"
                    target.write_text("{}", encoding="utf-8")
                    lock_dir = _lock_dir(target)
                    lock_dir.mkdir()
                    (lock_dir / "owner.json").write_text(json.dumps(payload), encoding="utf-8")
                    self.assertLess(_directory_age_seconds(lock_dir), NEW_LOCK_GRACE_SECONDS)
                    self.assertFalse(_lock_is_stale(lock_dir))
                    self.assertFalse(acquire_lock(target).get("ok"))

    def test_structurally_invalid_metadata_recovered_after_grace(self) -> None:
        for name, payload in STRUCTURALLY_INVALID_METADATA:
            with self.subTest(name=name):
                with tempfile.TemporaryDirectory() as directory:
                    target = Path(directory) / f"{name}_stale.ui.json"
                    target.write_text("{}", encoding="utf-8")
                    lock_dir = _lock_dir(target)
                    lock_dir.mkdir()
                    (lock_dir / "owner.json").write_text(json.dumps(payload), encoding="utf-8")
                    _age_directory(lock_dir, GRACE_PLUS)
                    self.assertTrue(_lock_is_stale(lock_dir))
                    self.assertTrue(_reclaim_stale_directory(lock_dir))
                    self.assertFalse(lock_dir.exists())
                    self.assertFalse(list(Path(directory).glob("*.reclaim_*")))
                    acquired = acquire_lock(target)
                    self.assertTrue(acquired.get("ok"), acquired)
                    release_lock(acquired.get("lock_path"), str(acquired.get("owner_nonce")))

    def test_structurally_invalid_guard_recovered_after_grace(self) -> None:
        payload = {"owner_nonce": "abc", "pid": "not-a-number", "started": 1}
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "guard.ui.json"
            target.write_text("{}", encoding="utf-8")
            guard_dir = _reclaim_guard_path(target)
            guard_dir.mkdir()
            (guard_dir / "owner.json").write_text(json.dumps(payload), encoding="utf-8")
            _age_directory(guard_dir, GRACE_PLUS)
            self.assertTrue(_lock_is_stale(guard_dir))
            self.assertTrue(_reclaim_abandoned_publication(guard_dir))
            self.assertFalse(guard_dir.exists())
            acquired = acquire_lock(target)
            self.assertTrue(acquired.get("ok"), acquired)
            release_lock(acquired.get("lock_path"), str(acquired.get("owner_nonce")))

    def test_pid_alive_status_never_raises(self) -> None:
        for payload in MALFORMED_LIVENESS_CASES:
            with self.subTest(payload=payload):
                status = _pid_alive_status(payload)
                self.assertIn(status, {"alive", "dead", "unknown"})

    def test_owner_meta_parsers_never_raise(self) -> None:
        samples = [
            "banana",
            None,
            [],
            {},
            True,
            -1,
            10**30,
            "not-a-number",
            {"owner_nonce": "abc", "pid": "x", "started": "y", "process_start": []},
        ]
        for sample in samples:
            with self.subTest(sample=sample):
                _parse_positive_int(sample)
                _parse_timestamp(sample)
                _coerce_process_start(sample)
                _owner_meta_valid(sample if isinstance(sample, dict) else {"pid": sample, "started": 1, "owner_nonce": "abc"})

    def test_invalid_pid_regression(self) -> None:
        payload = {"owner_nonce": "abc", "pid": "not-a-number", "started": 1}
        self.assertFalse(_owner_meta_valid(payload))
        self.assertEqual(_pid_alive_status(payload), "dead")

    def test_invalid_started_regression(self) -> None:
        payload = {"owner_nonce": "abc", "pid": 123, "started": "not-a-number"}
        self.assertFalse(_owner_meta_valid(payload))
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "started.ui.json"
            target.write_text("{}", encoding="utf-8")
            lock_dir = _lock_dir(target)
            lock_dir.mkdir()
            (lock_dir / "owner.json").write_text(json.dumps(payload), encoding="utf-8")
            _age_directory(lock_dir, GRACE_PLUS)
            self.assertTrue(_reclaim_stale_directory(lock_dir))

    def test_invalid_nonce_regression(self) -> None:
        payload = {"owner_nonce": [], "pid": 123, "started": 123}
        self.assertFalse(_owner_meta_valid(payload))
        self.assertEqual(_pid_alive_status(payload), "dead")


if __name__ == "__main__":
    unittest.main()
