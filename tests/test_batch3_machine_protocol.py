#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from ui_fallback import dispatch_machine  # noqa: E402
from ui_godot import FRAME_SENTINEL, machine_oneshot, project_needs_bootstrap, run_native_once  # noqa: E402


def _godot_bin() -> str:
    env = os.environ.get("GODOT_BIN", "")
    if env and Path(env).exists():
        return env
    for candidate in ("godot", "godot4"):
        found = subprocess.run(["bash", "-lc", f"command -v {candidate}"], capture_output=True, text=True)
        if found.returncode == 0 and found.stdout.strip():
            return found.stdout.strip()
    raise unittest.SkipTest("Godot binary unavailable")


def _count_machine_server_processes() -> int:
    result = subprocess.run(["pgrep", "-f", "machine_server.gd"], capture_output=True, text=True)
    if result.returncode != 0:
        return 0
    return len([line for line in result.stdout.splitlines() if line.strip()])


FIXTURE = str((ROOT / "tests/conformance/fixtures/minimal.ui.json").relative_to(ROOT)).replace("\\", "/")


class Batch3MachineProtocolTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.godot = _godot_bin()
        subprocess.run(["pkill", "-f", "machine_server.gd"], capture_output=True)

    def tearDown(self) -> None:
        subprocess.run(["pkill", "-f", "machine_server.gd"], capture_output=True)

    def test_capabilities_machine_envelope(self) -> None:
        code, payload = machine_oneshot(self.godot, {
            "protocol": "uiforge.machine",
            "protocol_version": 1,
            "request_id": "py-cap",
            "method": "capabilities",
            "params": {},
        })
        self.assertEqual(payload.get("protocol"), "uiforge.machine")
        self.assertTrue(payload.get("success"))
        caps = payload.get("result", {}).get("capabilities", {})
        self.assertEqual(caps.get("machine_protocol"), "uiforge.machine")
        self.assertTrue(caps.get("batch", {}).get("supported"))

    def test_warm_second_command_skips_bootstrap(self) -> None:
        if project_needs_bootstrap(ROOT):
            boot_code, _boot_payload = run_native_once(self.godot, ["capabilities"], bootstrap=True)
            self.assertEqual(boot_code, 0)
        os.environ["UIFORGE_TRACE_PROCESSES"] = "1"
        _first_code, first = run_native_once(self.godot, ["capabilities"], bootstrap=False)
        _second_code, second = run_native_once(self.godot, ["capabilities"], bootstrap=False)
        self.assertTrue(first.get("success"))
        self.assertTrue(second.get("success"))
        self.assertNotIn("bootstrap", second.get("meta", {}))

    def test_malformed_request_code(self) -> None:
        _code, payload = machine_oneshot(self.godot, {"method": "validate"})
        self.assertFalse(payload.get("success"))
        self.assertEqual(payload.get("error", {}).get("code"), "PROTOCOL_MISMATCH")

    def test_batch_dry_run(self) -> None:
        fixture = ROOT / "tests/conformance/fixtures/minimal.ui.json"
        inspect_code, inspect_payload = machine_oneshot(self.godot, {
            "protocol": "uiforge.machine",
            "protocol_version": 1,
            "request_id": "inspect-rev",
            "method": "validate",
            "params": {"document": str(fixture.relative_to(ROOT)).replace("\\", "/")},
        })
        revision = inspect_payload.get("result", {}).get("revision", "")
        code, payload = machine_oneshot(self.godot, {
            "protocol": "uiforge.machine",
            "protocol_version": 1,
            "request_id": "batch-dry",
            "method": "batch",
            "params": {
                "document": str(fixture.relative_to(ROOT)).replace("\\", "/"),
                "expected_revision": revision,
                "dry_run": True,
                "operations": [
                    {"op": "set", "node": "root", "property": "layout.size", "value": "[420,300]"},
                ],
            },
        })
        self.assertTrue(payload.get("success"), payload)
        self.assertFalse(payload.get("result", {}).get("committed", True))

    def test_persistent_handshake(self) -> None:
        proc = subprocess.Popen(
            [sys.executable, str(ROOT / "scripts" / "ui_godot.py"), self.godot, "serve", "--stdio"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        assert proc.stdout is not None
        assert proc.stdin is not None
        handshake = json.loads(proc.stdout.readline())
        self.assertTrue(handshake.get("success"))
        request = {
            "protocol": "uiforge.machine",
            "protocol_version": 1,
            "request_id": "serve-cap",
            "method": "capabilities",
            "params": {},
        }
        proc.stdin.write(json.dumps(request) + "\n")
        proc.stdin.flush()
        response = json.loads(proc.stdout.readline())
        self.assertEqual(response.get("request_id"), "serve-cap")
        self.assertTrue(response.get("success"))
        proc.stdin.close()
        proc.wait(timeout=30)

    def test_persistent_single_godot_process(self) -> None:
        proc = subprocess.Popen(
            [sys.executable, str(ROOT / "scripts" / "ui_godot.py"), self.godot, "serve", "--stdio"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        assert proc.stdout is not None
        assert proc.stdin is not None
        json.loads(proc.stdout.readline())
        before = _count_machine_server_processes()
        self.assertGreaterEqual(before, 1)
        for index in range(100):
            request = {
                "protocol": "uiforge.machine",
                "protocol_version": 1,
                "request_id": f"get-{index}",
                "method": "get",
                "params": {"document": FIXTURE, "node": "root", "property": "layout.size"},
            }
            proc.stdin.write(json.dumps(request) + "\n")
            proc.stdin.flush()
            response = json.loads(proc.stdout.readline())
            self.assertEqual(response.get("request_id"), f"get-{index}")
            self.assertTrue(response.get("success"))
        self.assertEqual(_count_machine_server_processes(), before)
        proc.stdin.close()
        proc.wait(timeout=60)
        self.assertEqual(proc.returncode, 0)

    def test_persistent_stress_500_requests(self) -> None:
        proc = subprocess.Popen(
            [sys.executable, str(ROOT / "scripts" / "ui_godot.py"), self.godot, "serve", "--stdio"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        assert proc.stdout is not None
        assert proc.stdin is not None
        json.loads(proc.stdout.readline())
        fixture = FIXTURE
        methods = [
            ("validate", {"document": fixture}),
            ("inspect", {"document": fixture, "scope": "tree"}),
            ("get", {"document": fixture, "node": "root", "property": "layout.size"}),
            ("get", {"document": fixture, "node": "root"}),
        ]
        for index in range(500):
            method, params = methods[index % len(methods)]
            request = {
                "protocol": "uiforge.machine",
                "protocol_version": 1,
                "request_id": f"stress-{index}",
                "method": method,
                "params": params,
            }
            proc.stdin.write(json.dumps(request) + "\n")
            proc.stdin.flush()
            response = json.loads(proc.stdout.readline())
            self.assertEqual(response.get("request_id"), f"stress-{index}", response)
            self.assertTrue(response.get("success"), response)
        proc.stdin.close()
        proc.wait(timeout=120)
        self.assertEqual(proc.returncode, 0)

    def test_malformed_request_does_not_kill_server(self) -> None:
        proc = subprocess.Popen(
            [sys.executable, str(ROOT / "scripts" / "ui_godot.py"), self.godot, "serve", "--stdio"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        assert proc.stdout is not None
        assert proc.stdin is not None
        json.loads(proc.stdout.readline())
        proc.stdin.write("{not-json\n")
        proc.stdin.flush()
        bad = json.loads(proc.stdout.readline())
        self.assertFalse(bad.get("success"))
        proc.stdin.write(json.dumps({
            "protocol": "uiforge.machine",
            "protocol_version": 1,
            "request_id": "after-bad",
            "method": "capabilities",
            "params": {},
        }) + "\n")
        proc.stdin.flush()
        good = json.loads(proc.stdout.readline())
        self.assertTrue(good.get("success"))
        proc.stdin.close()
        proc.wait(timeout=30)


class Batch3FallbackParityTests(unittest.TestCase):
    def test_fallback_capabilities_machine_envelope(self) -> None:
        response = dispatch_machine({
            "protocol": "uiforge.machine",
            "protocol_version": 1,
            "request_id": "fb-cap",
            "method": "capabilities",
            "params": {},
        })
        self.assertTrue(response.get("success"))
        self.assertEqual(response.get("meta", {}).get("backend"), "python-fallback")
        caps = response.get("result", {}).get("capabilities", {})
        self.assertFalse(caps.get("persistent_server", {}).get("supported"))
        self.assertTrue(caps.get("batch", {}).get("supported"))

    def test_fallback_validate_revision(self) -> None:
        fixture = str((ROOT / "examples/specs/inventory.ui.json").relative_to(ROOT))
        response = dispatch_machine({
            "protocol": "uiforge.machine",
            "protocol_version": 1,
            "request_id": "fb-validate",
            "method": "validate",
            "params": {"document": fixture},
        })
        self.assertTrue(response.get("success"))
        self.assertTrue(str(response.get("result", {}).get("revision", "")).startswith("sha256:"))

    def test_fallback_batch_dry_run(self) -> None:
        fixture = str((ROOT / "tests/conformance/fixtures/minimal.ui.json").relative_to(ROOT))
        validate = dispatch_machine({
            "protocol": "uiforge.machine",
            "protocol_version": 1,
            "request_id": "fb-rev",
            "method": "validate",
            "params": {"document": fixture},
        })
        revision = validate.get("result", {}).get("revision", "")
        response = dispatch_machine({
            "protocol": "uiforge.machine",
            "protocol_version": 1,
            "request_id": "fb-batch",
            "method": "batch",
            "params": {
                "document": fixture,
                "expected_revision": revision,
                "dry_run": True,
                "operations": [{"op": "set", "node": "root", "property": "layout.size", "value": "[420,300]"}],
            },
        })
        self.assertTrue(response.get("success"))
        self.assertFalse(response.get("result", {}).get("committed", True))

    def test_fallback_revision_conflict(self) -> None:
        fixture = str((ROOT / "tests/conformance/fixtures/minimal.ui.json").relative_to(ROOT))
        response = dispatch_machine({
            "protocol": "uiforge.machine",
            "protocol_version": 1,
            "request_id": "fb-conflict",
            "method": "batch",
            "params": {
                "document": fixture,
                "expected_revision": "sha256:deadbeef",
                "operations": [{"op": "set", "node": "root", "property": "layout.size", "value": "[420,300]"}],
            },
        })
        self.assertFalse(response.get("success"))
        self.assertEqual(response.get("error", {}).get("code"), "REVISION_CONFLICT")


if __name__ == "__main__":
    unittest.main()
