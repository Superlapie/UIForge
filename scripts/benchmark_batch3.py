#!/usr/bin/env python3
"""Batch 3 startup and persistent throughput benchmarks."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from ui_godot import machine_oneshot, run_native_once  # noqa: E402


def godot_bin() -> str:
    env = os.environ.get("GODOT_BIN", "")
    if env and Path(env).exists():
        return env
    found = subprocess.run(["bash", "-lc", "command -v godot"], capture_output=True, text=True)
    if found.returncode == 0 and found.stdout.strip():
        return found.stdout.strip()
    raise SystemExit("Godot not available")


def timed(label: str, fn) -> dict:
    start = time.perf_counter()
    result = fn()
    elapsed = time.perf_counter() - start
    payload = {"label": label, "seconds": elapsed}
    if isinstance(result, tuple) and len(result) == 2:
        payload["exit_code"] = result[0]
        if isinstance(result[1], dict):
            payload["success"] = bool(result[1].get("success"))
    return payload


def persistent_read_benchmark(godot: str, count: int = 100) -> dict:
    proc = subprocess.Popen(
        [sys.executable, str(ROOT / "scripts" / "ui_godot.py"), godot, "serve", "--stdio"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    assert proc.stdout is not None
    assert proc.stdin is not None
    start = time.perf_counter()
    json.loads(proc.stdout.readline())
    for index in range(count):
        request = {
            "protocol": "uiforge.machine",
            "protocol_version": 1,
            "request_id": f"bench-{index}",
            "method": "get",
            "params": {
                "document": "tests/conformance/fixtures/minimal.ui.json",
                "node": "root",
                "property": "layout.size",
            },
        }
        proc.stdin.write(json.dumps(request) + "\n")
        proc.stdin.flush()
        response = json.loads(proc.stdout.readline())
        if not response.get("success"):
            proc.kill()
            raise RuntimeError(response)
    elapsed = time.perf_counter() - start
    proc.stdin.close()
    proc.wait(timeout=60)
    return {"label": f"persistent_{count}_get", "seconds": elapsed, "requests": count}


def main() -> int:
    godot = godot_bin()
    fixture = "examples/specs/inventory.ui.json"
    results = {
        "platform": sys.platform,
        "godot": godot,
        "cases": [],
    }
    results["cases"].append(timed("cold_capabilities", lambda: run_native_once(godot, ["capabilities"], bootstrap=True)))
    results["cases"].append(timed("warm_capabilities_1", lambda: run_native_once(godot, ["capabilities"], bootstrap=False)))
    results["cases"].append(timed("warm_capabilities_2", lambda: run_native_once(godot, ["capabilities"], bootstrap=False)))
    results["cases"].append(timed("warm_validate", lambda: run_native_once(godot, ["validate", fixture], bootstrap=False)))
    request = {
        "protocol": "uiforge.machine",
        "protocol_version": 1,
        "request_id": "bench-cap",
        "method": "capabilities",
        "params": {},
    }
    results["cases"].append(timed("machine_capabilities", lambda: machine_oneshot(godot, request)))
    one_shot_reads = timed("oneshot_100_get", lambda: [
        machine_oneshot(godot, {
            "protocol": "uiforge.machine",
            "protocol_version": 1,
            "request_id": f"oneshot-{index}",
            "method": "get",
            "params": {
                "document": "tests/conformance/fixtures/minimal.ui.json",
                "node": "root",
                "property": "layout.size",
            },
        })
        for index in range(100)
    ])
    results["cases"].append(one_shot_reads)
    persistent = persistent_read_benchmark(godot, 100)
    results["cases"].append(persistent)
    if one_shot_reads["seconds"] > 0:
        results["persistent_to_oneshot_ratio"] = one_shot_reads["seconds"] / persistent["seconds"]
    out = ROOT / ".uiforge/benchmarks/batch3.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(results, indent=2), encoding="utf-8")
    print(json.dumps({"success": True, "artifact": str(out), "cases": len(results["cases"])}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
