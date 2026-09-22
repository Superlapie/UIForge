#!/usr/bin/env python3
"""Windows ui.cmd smoke coverage for Batch 3 agent workflows."""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run_cmd(args: list[str], *, input_text: str | None = None) -> subprocess.CompletedProcess[str]:
    command = ["cmd", "/c", str(ROOT / "scripts" / "ui.cmd"), *args]
    return subprocess.run(
        command,
        cwd=ROOT,
        input=input_text,
        capture_output=True,
        text=True,
        timeout=120,
    )


def read_persistent_handshake(stdout: str) -> dict:
    line = stdout.splitlines()[0] if stdout.splitlines() else ""
    return json.loads(line)


def main() -> int:
    if sys.platform != "win32":
        print(json.dumps({"success": True, "skipped": True, "reason": "Windows-only smoke script"}))
        return 0

    capabilities = run_cmd(["capabilities"])
    if capabilities.returncode != 0:
        raise SystemExit(f"ui.cmd capabilities failed: {capabilities.stderr}")

    temp_dir = ROOT / ".uiforge" / "cmd_smoke"
    temp_dir.mkdir(parents=True, exist_ok=True)
    temp_doc = temp_dir / "cmd_batch.ui.json"
    shutil.copy(ROOT / "tests/conformance/fixtures/minimal.ui.json", temp_doc)
    rel_doc = str(temp_doc.relative_to(ROOT)).replace("/", "\\")
    batch = run_cmd(["batch", rel_doc, "--stdin"], input_text=json.dumps({
        "dry_run": True,
        "operations": [{"op": "set", "node": "root", "property": "layout.size", "value": "[420,300]"}],
    }))
    if batch.returncode != 0:
        raise SystemExit(f"ui.cmd batch dry-run failed: {batch.stderr}")

    proc = subprocess.Popen(
        ["cmd", "/c", str(ROOT / "scripts" / "ui.cmd"), "serve", "--stdio"],
        cwd=ROOT,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    assert proc.stdout is not None
    assert proc.stdin is not None
    handshake = read_persistent_handshake(proc.stdout.readline())
    if not handshake.get("success"):
        raise SystemExit(f"ui.cmd persistent handshake failed: {handshake}")
    proc.stdin.write(json.dumps({
        "protocol": "uiforge.machine",
        "protocol_version": 1,
        "request_id": "cmd-shutdown",
        "method": "shutdown",
        "params": {},
    }) + "\n")
    proc.stdin.flush()
    shutdown = json.loads(proc.stdout.readline())
    if not shutdown.get("success"):
        raise SystemExit(f"ui.cmd explicit shutdown failed: {shutdown}")
    proc.stdin.close()
    proc.wait(timeout=60)
    if proc.returncode != 0:
        raise SystemExit(f"ui.cmd serve exited {proc.returncode}")

    print(json.dumps({
        "success": True,
        "workflows": ["capabilities", "batch_dry_run", "persistent_handshake", "persistent_shutdown"],
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
