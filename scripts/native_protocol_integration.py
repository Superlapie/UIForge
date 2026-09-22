#!/usr/bin/env python3
"""Native persistent-transport integration suite for Godot CI jobs."""

from __future__ import annotations

import concurrent.futures
import copy
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from ui_fallback import content_hash, dispatch_machine as fallback_dispatch  # noqa: E402
from ui_godot import (  # noqa: E402
    FRAME_SENTINEL,
    bootstrap_marker_path,
    machine_oneshot,
    project_dir,
    project_needs_bootstrap,
    run_native_once,
)
from uiforge_machine import MAX_REQUEST_BYTES  # noqa: E402

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


def assert_native_lifecycle(traces: list[dict], label: str) -> int:
    spawned = [item for item in traces if item.get("event") == "native_spawned"]
    stopped = [item for item in traces if item.get("event") == "native_stopped"]
    if len(spawned) != 1:
        raise IntegrationFailure(f"{label}: expected one native_spawned, got {spawned}")
    if len(stopped) != 1:
        raise IntegrationFailure(f"{label}: expected one native_stopped, got {stopped}")
    native_pid = int(spawned[0]["pid"])
    if int(stopped[0]["pid"]) != native_pid:
        raise IntegrationFailure(f"{label}: native_stopped pid mismatch")
    return native_pid


def spawn_serve(godot: str, *, chunked_send: bool = False) -> subprocess.Popen[str]:
    env = os.environ.copy()
    env["UIFORGE_TRACE_PROCESSES"] = "1"
    if chunked_send:
        env["UIFORGE_TEST_CHUNKED_SEND"] = "1"
        env["UIFORGE_TEST_CHUNK_SIZE"] = "64"
    proc = subprocess.Popen(
        [sys.executable, str(ROOT / "scripts" / "ui_godot.py"), godot, "serve", "--stdio"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
    )
    assert proc.stderr is not None

    collector: list[str] = []

    def drain_stderr() -> None:
        assert proc.stderr is not None
        for line in proc.stderr:
            collector.append(line)

    threading.Thread(target=drain_stderr, daemon=True).start()
    proc._uiforge_stderr_lines = collector  # type: ignore[attr-defined]
    return proc


def serve_traces(proc: subprocess.Popen[str]) -> list[dict]:
    lines = getattr(proc, "_uiforge_stderr_lines", [])
    return trace_events("".join(lines))


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


def send_raw_line(proc: subprocess.Popen[str], raw: bytes) -> dict:
    assert proc.stdin is not None
    assert proc.stdout is not None
    proc.stdin.buffer.write(raw + b"\n")
    proc.stdin.buffer.flush()
    return read_json_line(proc.stdout)


def assert_response(response: dict, expect: dict, label: str) -> None:
    if expect.get("success") is not None and bool(response.get("success")) != bool(expect["success"]):
        raise IntegrationFailure(f"{label}: success expected {expect['success']} got {response.get('success')} :: {response}")
    if expect.get("error_code") and response.get("error", {}).get("code") != expect["error_code"]:
        raise IntegrationFailure(f"{label}: error_code expected {expect['error_code']} got {response.get('error', {}).get('code')}")
    if "result_committed" in expect and response.get("result", {}).get("committed") is not expect["result_committed"]:
        raise IntegrationFailure(f"{label}: result committed expected {expect['result_committed']}")
    for key in expect.get("result_has", []):
        if key not in response.get("result", {}):
            raise IntegrationFailure(f"{label}: result missing {key}")


def build_request_raw(target_bytes: int, *, multibyte_pad: bool = False) -> bytes:
    pad_unit = "\u00e9" if multibyte_pad else "a"

    def encode(pad_len: int) -> bytes:
        request: dict[str, object] = {
            "protocol": "uiforge.machine",
            "protocol_version": 1,
            "request_id": "size-test",
            "method": "capabilities",
            "params": {"_pad": pad_unit * pad_len},
        }
        return json.dumps(request, separators=(",", ":"), ensure_ascii=False).encode("utf-8")

    low = 0
    high = target_bytes
    while low < high:
        mid = (low + high + 1) // 2
        if len(encode(mid)) <= target_bytes:
            low = mid
        else:
            high = mid - 1
    exact = encode(low)
    if len(exact) == target_bytes:
        return exact
    candidate = encode(low + 1)
    if len(candidate) == target_bytes:
        return candidate
    raise IntegrationFailure(f"could not build request of exactly {target_bytes} bytes, nearest {len(exact)}")


def copy_temp_document(source_rel: str, fixture_id: str, mutate: dict | None = None) -> str:
    temp_dir = ROOT / ".uiforge" / "integration_temp"
    temp_dir.mkdir(parents=True, exist_ok=True)
    temp_path = temp_dir / f"{fixture_id}.ui.json"
    shutil.copy(ROOT / source_rel, temp_path)
    if mutate:
        data = json.loads(temp_path.read_text(encoding="utf-8"))
        for key, value in mutate.items():
            if isinstance(value, dict) and isinstance(data.get(key), dict):
                data[key].update(value)
            else:
                data[key] = value
        temp_path.write_text(json.dumps(data, indent="\t", ensure_ascii=False) + "\n", encoding="utf-8")
    return str(temp_path.relative_to(ROOT)).replace("\\", "/")


def substitute_temp_paths(value: object, temp_path: str) -> object:
    if value == "__TEMP__":
        return temp_path
    if isinstance(value, dict):
        return {key: substitute_temp_paths(item, temp_path) for key, item in value.items()}
    if isinstance(value, list):
        return [substitute_temp_paths(item, temp_path) for item in value]
    return value


def prepare_fixture(fixture: dict) -> tuple[dict, str | None]:
    request = copy.deepcopy(fixture["request"])
    temp_path = None
    if fixture.get("temp_document_from"):
        temp_path = copy_temp_document(
            str(fixture["temp_document_from"]),
            str(fixture["id"]),
            fixture.get("mutate_temp_document"),
        )
        request = substitute_temp_paths(request, temp_path)
    return request, temp_path


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
    proc.wait(timeout=30)
    assert_native_lifecycle(serve_traces(proc), "persistent_handshake")
    if proc.returncode != 0:
        raise IntegrationFailure(f"serve exited {proc.returncode}")


def run_single_native_process(godot: str) -> None:
    proc = spawn_serve(godot)
    assert proc.stdout is not None
    read_json_line(proc.stdout)
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
    proc.wait(timeout=60)
    assert_native_lifecycle(serve_traces(proc), "persistent_100_requests")
    if proc.returncode != 0:
        raise IntegrationFailure(f"broker exit code {proc.returncode}")


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
    assert_native_lifecycle(serve_traces(proc), "explicit_shutdown")
    if proc.returncode != 0:
        raise IntegrationFailure(f"broker exit code {proc.returncode}")


def run_eof_shutdown(godot: str) -> None:
    proc = spawn_serve(godot)
    assert proc.stdout is not None
    read_json_line(proc.stdout)
    proc.stdin.close()
    proc.wait(timeout=30)
    assert_native_lifecycle(serve_traces(proc), "eof_shutdown")
    if proc.returncode != 0:
        raise IntegrationFailure(f"broker exit code {proc.returncode}")


def run_request_limits(godot: str) -> dict[str, object]:
    results: dict[str, object] = {}
    under = build_request_raw(MAX_REQUEST_BYTES - 1)
    proc = spawn_serve(godot)
    assert proc.stdout is not None
    read_json_line(proc.stdout)
    response = send_raw_line(proc, under)
    if not response.get("success"):
        raise IntegrationFailure(f"under-limit request failed: {response}")
    results["under_limit"] = {"bytes": len(under), "success": True}
    boundary = build_request_raw(MAX_REQUEST_BYTES)
    boundary_response = send_raw_line(proc, boundary)
    if not boundary_response.get("success"):
        raise IntegrationFailure(f"boundary request failed: {boundary_response}")
    results["boundary"] = {"bytes": len(boundary), "success": True}
    over = build_request_raw(MAX_REQUEST_BYTES + 1)
    over_response = send_raw_line(proc, over)
    if over_response.get("success") or over_response.get("error", {}).get("code") != "REQUEST_TOO_LARGE":
        raise IntegrationFailure(f"over-limit request should fail: {over_response}")
    results["one_byte_over"] = {"bytes": len(over), "error_code": over_response.get("error", {}).get("code")}
    recovery = send_request(proc, {
        "protocol": "uiforge.machine",
        "protocol_version": 1,
        "request_id": "after-over",
        "method": "capabilities",
        "params": {},
    })
    if not recovery.get("success"):
        raise IntegrationFailure(f"recovery after over-limit failed: {recovery}")
    results["recovery_after_over"] = True
    multibyte = build_request_raw(MAX_REQUEST_BYTES - 1, multibyte_pad=True)
    multibyte_response = send_raw_line(proc, multibyte)
    if not multibyte_response.get("success"):
        raise IntegrationFailure(f"multibyte near-limit request failed: {multibyte_response}")
    results["multibyte_near_limit"] = {"bytes": len(multibyte), "success": True}
    proc.stdin.close()
    proc.wait(timeout=30)

    proc = spawn_serve(godot, chunked_send=True)
    assert proc.stdout is not None
    read_json_line(proc.stdout)
    split_over = build_request_raw(MAX_REQUEST_BYTES + 1)
    split_response = send_raw_line(proc, split_over)
    if split_response.get("success") or split_response.get("error", {}).get("code") != "REQUEST_TOO_LARGE":
        raise IntegrationFailure(f"split oversized request should fail: {split_response}")
    split_recovery = send_request(proc, {
        "protocol": "uiforge.machine",
        "protocol_version": 1,
        "request_id": "after-split-over",
        "method": "capabilities",
        "params": {},
    })
    if not split_recovery.get("success"):
        raise IntegrationFailure(f"split oversized recovery failed: {split_recovery}")
    results["split_oversized_recovery"] = True
    proc.stdin.close()
    proc.wait(timeout=30)
    return results


def run_batch_persistent(godot: str) -> dict[str, bool]:
    outcomes = {
        "dry_run": False,
        "revision_conflict": False,
        "success": False,
        "dependent_ops": False,
        "middle_failure": False,
        "final_validation_failure": False,
    }
    temp_doc = copy_temp_document(FIXTURE, "batch_persistent")
    source_bytes = (ROOT / temp_doc).read_bytes()
    revision_payload = machine_oneshot(godot, {
        "protocol": "uiforge.machine",
        "protocol_version": 1,
        "request_id": "batch-rev",
        "method": "validate",
        "params": {"document": temp_doc},
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
            "document": temp_doc,
            "expected_revision": revision,
            "dry_run": True,
            "operations": [{"op": "set", "node": "root", "property": "layout.size", "value": "[420,300]"}],
        },
    })
    if not dry.get("success") or dry.get("result", {}).get("committed", True):
        raise IntegrationFailure(f"batch dry-run failed: {dry}")
    if (ROOT / temp_doc).read_bytes() != source_bytes:
        raise IntegrationFailure("batch dry-run mutated source")
    outcomes["dry_run"] = True

    conflict = send_request(proc, {
        "protocol": "uiforge.machine",
        "protocol_version": 1,
        "request_id": "batch-conflict",
        "method": "batch",
        "params": {
            "document": temp_doc,
            "expected_revision": "sha256:deadbeef",
            "operations": [{"op": "set", "node": "root", "property": "layout.size", "value": "[420,300]"}],
        },
    })
    if conflict.get("success") or conflict.get("error", {}).get("code") != "REVISION_CONFLICT":
        raise IntegrationFailure(f"batch conflict failed: {conflict}")
    if conflict.get("result", {}).get("committed") is not False:
        raise IntegrationFailure("batch conflict must preserve committed:false in result")
    if (ROOT / temp_doc).read_bytes() != source_bytes:
        raise IntegrationFailure("revision conflict mutated source")
    outcomes["revision_conflict"] = True

    dependent = send_request(proc, {
        "protocol": "uiforge.machine",
        "protocol_version": 1,
        "request_id": "batch-dependent",
        "method": "batch",
        "params": {
            "document": temp_doc,
            "expected_revision": revision,
            "operations": [
                {
                    "op": "add",
                    "parent": "root",
                    "node": {"id": "batch_child", "type": "Panel", "layout": {"position": [12, 12], "size": [64, 64]}, "children": []},
                },
                {"op": "set", "node": "batch_child", "property": "layout.size", "value": "[96,96]"},
            ],
        },
    })
    if not dependent.get("success") or not dependent.get("result", {}).get("committed"):
        raise IntegrationFailure(f"dependent batch failed: {dependent}")
    fresh_revision = machine_oneshot(godot, {
        "protocol": "uiforge.machine",
        "protocol_version": 1,
        "request_id": "batch-read-rev",
        "method": "validate",
        "params": {"document": temp_doc},
    })[1].get("result", {}).get("revision", "")
    if fresh_revision != dependent.get("result", {}).get("new_revision"):
        raise IntegrationFailure("batch success revision mismatch")
    revision = fresh_revision
    outcomes["dependent_ops"] = True
    outcomes["success"] = True

    revision = machine_oneshot(godot, {
        "protocol": "uiforge.machine",
        "protocol_version": 1,
        "request_id": "batch-middle-rev",
        "method": "validate",
        "params": {"document": temp_doc},
    })[1].get("result", {}).get("revision", "")
    before_middle = (ROOT / temp_doc).read_bytes()
    middle_fail = send_request(proc, {
        "protocol": "uiforge.machine",
        "protocol_version": 1,
        "request_id": "batch-middle-fail",
        "method": "batch",
        "params": {
            "document": temp_doc,
            "expected_revision": revision,
            "operations": [
                {"op": "set", "node": "root", "property": "layout.size", "value": "[400,300]"},
                {"op": "set", "node": "missing_node", "property": "layout.size", "value": "[1,1]"},
            ],
        },
    })
    if middle_fail.get("success"):
        raise IntegrationFailure("middle batch failure should not succeed")
    if middle_fail.get("result", {}).get("committed") is not False:
        raise IntegrationFailure("middle failure must preserve committed:false")
    if middle_fail.get("result", {}).get("failed_index") != 1:
        raise IntegrationFailure("middle failure must report failed_index")
    if (ROOT / temp_doc).read_bytes() != before_middle:
        raise IntegrationFailure("middle failure must leave source byte-identical")
    post_middle_bytes = (ROOT / temp_doc).read_bytes()
    outcomes["middle_failure"] = True

    invalid_final = send_request(proc, {
        "protocol": "uiforge.machine",
        "protocol_version": 1,
        "request_id": "batch-final-invalid",
        "method": "batch",
        "params": {
            "document": temp_doc,
            "expected_revision": revision,
            "operations": [{
                "op": "add",
                "parent": "root",
                "node": {"id": "invalid_batch_node", "type": "DefinitelyNotValid", "layout": {"size": [32, 32]}, "children": []},
            }],
        },
    })
    if invalid_final.get("success"):
        raise IntegrationFailure("final validation failure should not succeed")
    if (ROOT / temp_doc).read_bytes() != post_middle_bytes:
        raise IntegrationFailure("final validation failure must not write source")
    outcomes["final_validation_failure"] = True

    proc.stdin.close()
    proc.wait(timeout=30)
    return outcomes


def run_warm_bootstrap(godot: str) -> dict[str, object]:
    root = project_dir()
    marker = bootstrap_marker_path(root)
    marker_backup = marker.read_text(encoding="utf-8") if marker.exists() else None
    warm_result: dict[str, object] = {}
    if not project_needs_bootstrap(root):
        env = os.environ.copy()
        env["UIFORGE_TRACE_PROCESSES"] = "1"
        for label in ("warm_first", "warm_second"):
            proc = subprocess.run(
                [sys.executable, str(ROOT / "scripts" / "ui_godot.py"), godot, "capabilities"],
                capture_output=True,
                text=True,
                env=env,
            )
            bootstrap_spawns = [item for item in trace_events(proc.stderr) if item.get("event") == "bootstrap_spawned"]
            if bootstrap_spawns:
                raise IntegrationFailure(f"{label} warm auto-bootstrap launched editor unexpectedly: {bootstrap_spawns}")
            warm_result[f"{label}_bootstrap_count"] = 0
    else:
        warm_result["warm_skipped"] = "project_not_bootstrapped"

    marker.unlink(missing_ok=True)
    env = os.environ.copy()
    env["UIFORGE_TRACE_PROCESSES"] = "1"
    fresh = subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "ui_godot.py"), godot, "capabilities"],
        capture_output=True,
        text=True,
        env=env,
    )
    fresh_spawns = [item for item in trace_events(fresh.stderr) if item.get("event") == "bootstrap_spawned"]
    if len(fresh_spawns) != 1:
        raise IntegrationFailure(f"fresh state should bootstrap exactly once, got {fresh_spawns}")
    warm_result["fresh_bootstrap_count"] = len(fresh_spawns)
    if marker_backup is not None:
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text(marker_backup, encoding="utf-8")
    return warm_result


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


def run_shared_fixtures(godot: str) -> tuple[int, int]:
    fixtures = json.loads(CONFORMANCE_FIXTURES.read_text(encoding="utf-8"))
    executions = 0
    proc = spawn_serve(godot)
    assert proc.stdout is not None
    read_json_line(proc.stdout)
    for fixture in fixtures:
        transports = fixture.get("transports", [])
        expect = fixture["expect"]
        if "native_oneshot" in transports:
            request, _temp_path = prepare_fixture(fixture)
            _code, response = machine_oneshot(godot, request)
            assert_response(response, expect, f"oneshot:{fixture['id']}")
            executions += 1
        if "native_persistent" in transports:
            request, _temp_path = prepare_fixture(fixture)
            response = send_request(proc, request)
            assert_response(response, expect, f"persistent:{fixture['id']}")
            executions += 1
        if "fallback" in transports:
            request, _temp_path = prepare_fixture(fixture)
            response = fallback_dispatch(request)
            assert_response(response, expect, f"fallback:{fixture['id']}")
            executions += 1
    proc.stdin.close()
    proc.wait(timeout=60)
    return len(fixtures), executions


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
        "eof_shutdown": False,
        "batch_persistent": {},
        "request_limits": {},
        "warm_bootstrap": {},
        "concurrent_oneshot": False,
        "frame_noise": False,
        "shared_fixture_definitions": 0,
        "shared_fixture_executions": 0,
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
    run_eof_shutdown(godot)
    summary["eof_shutdown"] = True
    summary["batch_persistent"] = run_batch_persistent(godot)
    summary["request_limits"] = run_request_limits(godot)
    summary["warm_bootstrap"] = run_warm_bootstrap(godot)
    run_concurrent_oneshot(godot)
    summary["concurrent_oneshot"] = True
    run_frame_noise_ignored(godot)
    summary["frame_noise"] = True
    fixture_definitions, fixture_executions = run_shared_fixtures(godot)
    summary["shared_fixture_definitions"] = fixture_definitions
    summary["shared_fixture_executions"] = fixture_executions
    print(json.dumps({"success": True, "suite": "native_protocol_integration", "summary": summary}, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except IntegrationFailure as exc:
        print(json.dumps({"success": False, "suite": "native_protocol_integration", "error": str(exc)}), file=sys.stderr)
        raise SystemExit(1)
