#!/usr/bin/env python3
"""Native persistent-transport integration suite for Godot CI jobs."""

from __future__ import annotations

import concurrent.futures
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from ui_fallback import dispatch_machine as fallback_dispatch  # noqa: E402
from ui_godot import FRAME_SENTINEL, machine_oneshot, project_dir  # noqa: E402

FIXTURE = "tests/conformance/fixtures/minimal.ui.json"
CONFORMANCE_FIXTURES = ROOT / "tests/machine_protocol/fixtures/conformance.json"


class IntegrationFailure(Exception):
    pass


def require_godot() -> str:
    godot = os.environ.get("GODOT_BIN", "")
    if godot and Path(godot).exists():
        return godot
    for candidate in ("godot", "godot4", "./godot.exe", "godot.exe"):
        found = shutil.which(candidate) or (str(ROOT / candidate) if (ROOT / candidate).exists() else "")
        if found and Path(found).exists():
            return found
    raise IntegrationFailure("GODOT_BIN is required for native protocol integration tests.")


def trace_events(stderr: str) -> list[dict]:
    events: list[dict] = []
    for line in stderr.splitlines():
        line = line.strip()
        if not line.startswith('{"uiforge_trace":'):
            continue
        payload = json.loads(line)
        trace = payload.get("uiforge_trace", {})
        if isinstance(trace, dict):
            events.append(trace)
    return events


def spawn_serve(godot: str) -> subprocess.Popen[str]:
    env = os.environ.copy()
    env["UIFORGE_TRACE_PROCESSES"] = "1"
    return subprocess.Popen(
        [sys.executable, str(ROOT / "scripts" / "ui_godot.py"), godot, "serve", "--stdio"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
    )


def read_json_line(stream) -> dict:
    line = stream.readline()
    if not line:
        raise IntegrationFailure("Expected JSON line but stream closed.")
    return json.loads(line)


def send_request(proc: subprocess.Popen[str], request: dict) -> dict:
    assert proc.stdin is not None
    assert proc.stdout is not None
    proc.stdin.write(json.dumps(request) + "\n")
    proc.stdin.flush()
    return read_json_line(proc.stdout)


def assert_response(response: dict, expect: dict, label: str) -> None:
    if expect.get("success") is not None and bool(response.get("success")) != bool(expect["success"]):
        raise IntegrationFailure(f"{label}: success expected {expect['success']} got {response.get('success')} :: {response}")
    if expect.get("error_code") and response.get("error", {}).get("code") != expect["error_code"]:
        raise IntegrationFailure(f"{label}: error_code expected {expect['error_code']} got {response.get('error', {}).get('code')}")
    for key in expect.get("result_has", []):
        if key not in response.get("result", {}):
            raise IntegrationFailure(f"{label}: result missing {key}")


def run_persistent_handshake(godot: str) -> None:
    proc = spawn_serve(godot)
    assert proc.stdout is not None
    handshake = read_json_line(proc.stdout)
    if not handshake.get("success"):
        raise IntegrationFailure(f"handshake failed: {handshake}")
    response = send_request(proc, {
        "protocol": "uiforge.machine",
        "protocol_version": 1,
        "request_id": "integration-cap",
        "method": "get",
        "params": {"document": FIXTURE, "node": "root", "property": "layout.size"},
    })
    if response.get("request_id") != "integration-cap" or not response.get("success"):
        raise IntegrationFailure(f"capabilities over persistent failed: {response}")
    proc.stdin.close()
    stderr = proc.stderr.read() if proc.stderr is not None else ""
    proc.wait(timeout=30)
    if proc.returncode != 0:
        raise IntegrationFailure(f"serve exited {proc.returncode}")


def run_single_native_process(godot: str) -> int:
    proc = spawn_serve(godot)
    assert proc.stdout is not None
    read_json_line(proc.stdout)
    traces = []
    native_pid = proc.pid
    for index in range(100):
        response = send_request(proc, {
            "protocol": "uiforge.machine",
            "protocol_version": 1,
            "request_id": f"seq-{index}",
            "method": "get",
            "params": {"document": FIXTURE, "node": "root", "property": "layout.size"},
        })
        if response.get("request_id") != f"seq-{index}" or not response.get("success"):
            raise IntegrationFailure(f"persistent sequence failed at {index}: {response}")
    proc.stdin.close()
    stderr = proc.stderr.read() if proc.stderr is not None else ""
    proc.wait(timeout=60)
    traces = trace_events(stderr)
    spawn_events = [item for item in traces if item.get("event") == "native_spawned"]
    if len(spawn_events) != 1:
        raise IntegrationFailure(f"expected one native_spawned event, got {spawn_events}")
    return native_pid


def run_persistent_stress(godot: str, count: int = 500) -> None:
    proc = spawn_serve(godot)
    assert proc.stdout is not None
    read_json_line(proc.stdout)
    methods = [
        ("validate", {"document": FIXTURE}),
        ("inspect", {"document": FIXTURE, "scope": "tree"}),
        ("get", {"document": FIXTURE, "node": "root", "property": "layout.size"}),
    ]
    for index in range(count):
        method, params = methods[index % len(methods)]
        response = send_request(proc, {
            "protocol": "uiforge.machine",
            "protocol_version": 1,
            "request_id": f"stress-{index}",
            "method": method,
            "params": params,
        })
        if response.get("request_id") != f"stress-{index}" or not response.get("success"):
            raise IntegrationFailure(f"stress failed at {index}: {response}")
    proc.stdin.close()
    proc.wait(timeout=180)


def run_malformed_recovery(godot: str) -> None:
    proc = spawn_serve(godot)
    assert proc.stdout is not None
    read_json_line(proc.stdout)
    assert proc.stdin is not None
    proc.stdin.write("{not-json\n")
    proc.stdin.flush()
    bad = read_json_line(proc.stdout)
    if bad.get("success"):
        raise IntegrationFailure("malformed JSON should fail")
    good = send_request(proc, {
        "protocol": "uiforge.machine",
        "protocol_version": 1,
        "request_id": "after-bad",
        "method": "get",
        "params": {"document": FIXTURE, "node": "root"},
    })
    if not good.get("success"):
        raise IntegrationFailure(f"recovery failed: {good}")
    proc.stdin.close()
    proc.wait(timeout=30)


def run_explicit_shutdown(godot: str) -> None:
    proc = spawn_serve(godot)
    assert proc.stdout is not None
    read_json_line(proc.stdout)
    response = send_request(proc, {
        "protocol": "uiforge.machine",
        "protocol_version": 1,
        "request_id": "shutdown-1",
        "method": "shutdown",
        "params": {},
    })
    if not response.get("success"):
        raise IntegrationFailure(f"shutdown failed: {response}")
    try:
        proc.wait(timeout=15)
    except subprocess.TimeoutExpired:
        proc.kill()
        raise IntegrationFailure("broker did not exit after explicit shutdown")
    if proc.returncode != 0:
        raise IntegrationFailure(f"broker exit code {proc.returncode}")


def run_batch_persistent(godot: str) -> None:
    revision_payload = machine_oneshot(godot, {
        "protocol": "uiforge.machine",
        "protocol_version": 1,
        "request_id": "batch-rev",
        "method": "validate",
        "params": {"document": FIXTURE},
    })[1]
    revision = revision_payload.get("result", {}).get("revision", "")
    proc = spawn_serve(godot)
    assert proc.stdout is not None
    read_json_line(proc.stdout)
    dry = send_request(proc, {
        "protocol": "uiforge.machine",
        "protocol_version": 1,
        "request_id": "batch-dry",
        "method": "batch",
        "params": {
            "document": FIXTURE,
            "expected_revision": revision,
            "dry_run": True,
            "operations": [{"op": "set", "node": "root", "property": "layout.size", "value": "[420,300]"}],
        },
    })
    if not dry.get("success") or dry.get("result", {}).get("committed", True):
        raise IntegrationFailure(f"batch dry-run failed: {dry}")
    conflict = send_request(proc, {
        "protocol": "uiforge.machine",
        "protocol_version": 1,
        "request_id": "batch-conflict",
        "method": "batch",
        "params": {
            "document": FIXTURE,
            "expected_revision": "sha256:deadbeef",
            "operations": [{"op": "set", "node": "root", "property": "layout.size", "value": "[420,300]"}],
        },
    })
    if conflict.get("success") or conflict.get("error", {}).get("code") != "REVISION_CONFLICT":
        raise IntegrationFailure(f"batch conflict failed: {conflict}")
    if conflict.get("result", {}).get("committed") is not False:
        raise IntegrationFailure("batch conflict must preserve committed:false in result")
    proc.stdin.close()
    proc.wait(timeout=30)


def run_concurrent_oneshot(godot: str) -> None:
    def worker(index: int) -> str:
        _code, payload = machine_oneshot(godot, {
            "protocol": "uiforge.machine",
            "protocol_version": 1,
            "request_id": f"concurrent-{index}",
            "method": "get",
            "params": {
                "document": FIXTURE,
                "node": "root",
                "property": "layout.size" if index % 2 == 0 else "layout.position",
            },
        })
        if payload.get("request_id") != f"concurrent-{index}":
            raise IntegrationFailure(f"request id mismatch for worker {index}")
        return str(payload.get("result", {}).get("value"))

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        values = list(pool.map(worker, range(16)))
    if len(set(values)) < 2:
        raise IntegrationFailure("concurrent one-shot requests returned identical payloads unexpectedly")


def run_frame_noise_ignored(godot: str) -> None:
    root = project_dir()
    request = {
        "protocol": "uiforge.machine",
        "protocol_version": 1,
        "request_id": "noise-test",
        "method": "get",
        "params": {"document": FIXTURE, "node": "root", "property": "layout.size"},
    }
    handle = tempfile.NamedTemporaryFile(mode="w", suffix=".json", dir=root / ".uiforge", delete=False)
    path = Path(handle.name)
    try:
        json.dump(request, handle)
        handle.close()
        command = [
            godot,
            "--headless",
            "--path",
            str(root),
            "--script",
            "res://addons/uiforge/cli/cli_main.gd",
            "--",
            "machine-oneshot",
            str(path),
        ]
        completed = subprocess.run(command, capture_output=True, text=True)
        stdout = '{"noise": true}\n' + completed.stdout + '\n{"noise": true}\n'
        frames = [line for line in stdout.splitlines() if line.startswith(FRAME_SENTINEL)]
        if len(frames) != 1:
            raise IntegrationFailure(f"expected exactly one frame in noisy stdout, found {len(frames)}")
    finally:
        path.unlink(missing_ok=True)


def run_shared_fixtures(godot: str) -> int:
    fixtures = json.loads(CONFORMANCE_FIXTURES.read_text(encoding="utf-8"))
    count = 0
    proc = spawn_serve(godot)
    assert proc.stdout is not None
    read_json_line(proc.stdout)
    for fixture in fixtures:
        transports = fixture.get("transports", [])
        request = fixture["request"]
        expect = fixture["expect"]
        if "native_oneshot" in transports:
            _code, response = machine_oneshot(godot, request)
            assert_response(response, expect, f"oneshot:{fixture['id']}")
            count += 1
        if "native_persistent" in transports:
            response = send_request(proc, request)
            assert_response(response, expect, f"persistent:{fixture['id']}")
            count += 1
        if "fallback" in transports:
            response = fallback_dispatch(request)
            assert_response(response, expect, f"fallback:{fixture['id']}")
            count += 1
    proc.stdin.close()
    proc.wait(timeout=30)
    return count


def main() -> int:
    godot = require_godot()
    summary = {
        "godot": godot,
        "platform": sys.platform,
        "persistent_handshake": False,
        "persistent_process_invariant": False,
        "persistent_stress_500": False,
        "malformed_recovery": False,
        "explicit_shutdown": False,
        "batch_persistent": False,
        "concurrent_oneshot": False,
        "frame_noise": False,
        "shared_fixture_cases": 0,
    }
    run_persistent_handshake(godot)
    summary["persistent_handshake"] = True
    run_single_native_process(godot)
    summary["persistent_process_invariant"] = True
    run_persistent_stress(godot, 500)
    summary["persistent_stress_500"] = True
    run_malformed_recovery(godot)
    summary["malformed_recovery"] = True
    run_explicit_shutdown(godot)
    summary["explicit_shutdown"] = True
    run_batch_persistent(godot)
    summary["batch_persistent"] = True
    run_concurrent_oneshot(godot)
    summary["concurrent_oneshot"] = True
    run_frame_noise_ignored(godot)
    summary["frame_noise"] = True
    summary["shared_fixture_cases"] = run_shared_fixtures(godot)
    print(json.dumps({"success": True, "suite": "native_protocol_integration", "summary": summary}, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except IntegrationFailure as exc:
        print(json.dumps({"success": False, "suite": "native_protocol_integration", "error": str(exc)}), file=sys.stderr)
        raise SystemExit(1)
