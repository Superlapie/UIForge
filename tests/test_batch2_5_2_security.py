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
    PUBLICATION_RECOVERY_INTERLEAVE_HOOK,
    _directory_age_seconds,
    _lock_dir,
    _lock_is_stale,
    _query_process_identity,
    _reclaim_abandoned_publication,
    _reclaim_guard_path,
    _reclaim_stale_directory,
    _reclaim_stale_guard_verified,
    acquire_lock,
    release_lock,
)

GRACE_PLUS = NEW_LOCK_GRACE_SECONDS + 2


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


class Batch252SecurityTests(unittest.TestCase):
    def test_fresh_ownerless_lock_is_protected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "fresh_lock.ui.json"
            target.write_text("{}", encoding="utf-8")
            lock_dir = _lock_dir(target)
            lock_dir.mkdir()
            self.assertLess(_directory_age_seconds(lock_dir), NEW_LOCK_GRACE_SECONDS)
            self.assertFalse(_lock_is_stale(lock_dir))
            acquired = acquire_lock(target)
            self.assertFalse(acquired.get("ok"))

    def test_stale_ownerless_lock_is_recovered(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "stale_lock.ui.json"
            target.write_text("{}", encoding="utf-8")
            lock_dir = _lock_dir(target)
            lock_dir.mkdir()
            _age_directory(lock_dir, GRACE_PLUS)
            self.assertTrue(_lock_is_stale(lock_dir))
            self.assertTrue(_reclaim_stale_directory(lock_dir))
            self.assertFalse(lock_dir.exists())
            acquired = acquire_lock(target)
            self.assertTrue(acquired.get("ok"), acquired)
            release_lock(acquired.get("lock_path"), str(acquired.get("owner_nonce")))

    def test_fresh_ownerless_guard_is_protected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "fresh_guard.ui.json"
            target.write_text("{}", encoding="utf-8")
            guard_dir = _reclaim_guard_path(target)
            guard_dir.mkdir()
            self.assertLess(_directory_age_seconds(guard_dir), NEW_LOCK_GRACE_SECONDS)
            self.assertFalse(_lock_is_stale(guard_dir))
            self.assertFalse(_reclaim_stale_guard_verified(guard_dir))

    def test_stale_ownerless_guard_is_recovered(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "stale_guard.ui.json"
            target.write_text("{}", encoding="utf-8")
            guard_dir = _reclaim_guard_path(target)
            guard_dir.mkdir()
            _age_directory(guard_dir, GRACE_PLUS)
            self.assertTrue(_reclaim_stale_guard_verified(guard_dir))
            self.assertFalse(guard_dir.exists())
            acquired = acquire_lock(target)
            self.assertTrue(acquired.get("ok"), acquired)
            release_lock(acquired.get("lock_path"), str(acquired.get("owner_nonce")))

    def test_malformed_metadata_recovered_after_grace(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "malformed.ui.json"
            target.write_text("{}", encoding="utf-8")
            lock_dir = _lock_dir(target)
            lock_dir.mkdir()
            (lock_dir / "owner.json").write_text("{", encoding="utf-8")
            _age_directory(lock_dir, GRACE_PLUS)
            self.assertTrue(_lock_is_stale(lock_dir))
            self.assertTrue(_reclaim_abandoned_publication(lock_dir))
            self.assertFalse(lock_dir.exists())
            self.assertFalse(list(Path(directory).glob("*.reclaim_*")))

    def test_torn_metadata_recovered_after_grace(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "torn.ui.json"
            target.write_text("{}", encoding="utf-8")
            lock_dir = _lock_dir(target)
            lock_dir.mkdir()
            (lock_dir / "owner.json").write_text('{"owner_nonce":', encoding="utf-8")
            _age_directory(lock_dir, GRACE_PLUS)
            self.assertTrue(_reclaim_abandoned_publication(lock_dir))
            acquired = acquire_lock(target)
            self.assertTrue(acquired.get("ok"), acquired)
            release_lock(acquired.get("lock_path"), str(acquired.get("owner_nonce")))

    def test_live_owner_appearing_during_recovery_is_preserved(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "race.ui.json"
            target.write_text("{}", encoding="utf-8")
            lock_dir = _lock_dir(target)
            lock_dir.mkdir()
            _age_directory(lock_dir, GRACE_PLUS)
            identity = _query_process_identity(os.getpid())

            def inject_live_owner(reclaim_path: Path, canonical_path: Path) -> None:
                payload = {
                    "owner_nonce": "live-race-owner",
                    "pid": os.getpid(),
                    "process_start": str(identity.get("start_ticks", "")),
                    "started": time.time(),
                }
                (reclaim_path / "owner.json").write_text(json.dumps(payload), encoding="utf-8")

            import uiforge_contract as contract

            previous = contract.PUBLICATION_RECOVERY_INTERLEAVE_HOOK
            contract.PUBLICATION_RECOVERY_INTERLEAVE_HOOK = inject_live_owner
            try:
                self.assertFalse(_reclaim_abandoned_publication(lock_dir))
            finally:
                contract.PUBLICATION_RECOVERY_INTERLEAVE_HOOK = previous
            self.assertTrue(lock_dir.exists())
            meta = json.loads((lock_dir / "owner.json").read_text(encoding="utf-8"))
            self.assertEqual(meta.get("owner_nonce"), "live-race-owner")
            self.assertFalse(list(Path(directory).glob("*.reclaim_*")))


if __name__ == "__main__":
    unittest.main()
