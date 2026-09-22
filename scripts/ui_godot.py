#!/usr/bin/env python3
"""Native Godot CLI transport with lazy bootstrap and framed machine protocol."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from uiforge_machine import MAX_REQUEST_BYTES, validate_public_request_bytes

FRAME_SENTINEL = "UIFORGE_MACHINE_V1\t"
BOOTSTRAP_MARKER = ".uiforge/bootstrap_complete"
IMPORT_LOG = ".uiforge/import_boot.log"


def project_dir() -> Path:
    return Path(__file__).resolve().parents[1]


def bootstrap_marker_path(root: Path) -> Path:
    return root / BOOTSTRAP_MARKER


def project_needs_bootstrap(root: Path) -> bool:
    if os.environ.get("UIFORGE_FORCE_BOOTSTRAP") == "1":
        return True
    godot_dir = root / ".godot"
    if not godot_dir.exists():
        return True
    marker = bootstrap_marker_path(root)
    if not marker.exists():
        return True
    try:
        if godot_dir.stat().st_mtime > marker.stat().st_mtime:
            return True
    except OSError:
        return True
    return False


def run_bootstrap(godot_binary: str, root: Path) -> subprocess.CompletedProcess[str]:
    marker_parent = bootstrap_marker_path(root).parent
    marker_parent.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["UIFORGE_BOOTSTRAP"] = "1"
    command = [godot_binary, "--headless", "--editor", "--path", str(root), "--quit"]
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
    if os.environ.get("UIFORGE_TRACE_PROCESSES") == "1":
        print(json.dumps({"uiforge_trace": {"event": "bootstrap_spawned", "pid": process.pid}}), file=sys.stderr, flush=True)
    stdout, stderr = process.communicate(timeout=180)
    completed = subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
    import_log = root / IMPORT_LOG
    import_log.parent.mkdir(parents=True, exist_ok=True)
    import_log.write_text((completed.stdout or "") + "\n" + (completed.stderr or ""), encoding="utf-8")
    if completed.returncode == 0:
        bootstrap_marker_path(root).write_text(str(time.time()), encoding="utf-8")
    if os.environ.get("UIFORGE_TRACE_PROCESSES") == "1":
        print(json.dumps({"uiforge_trace": {"event": "bootstrap_stopped", "pid": process.pid, "returncode": completed.returncode}}), file=sys.stderr, flush=True)
    return completed


def godot_command(godot_binary: str, root: Path, ui_args: list[str]) -> list[str]:
    render_with_virtual_display = len(ui_args) > 0 and ui_args[0] == "render" and not os.environ.get("DISPLAY") and shutil.which("xvfb-run")
    command = ([shutil.which("xvfb-run"), "-a", godot_binary] if render_with_virtual_display else [godot_binary, "--headless"])
    command.extend(["--path", str(root), "--script", "res://addons/uiforge/cli/cli_main.gd", "--", *ui_args])
    return [part for part in command if part]


def parse_framed_stdout(stdout: str) -> dict[str, object] | None:
    frames: list[dict[str, object]] = []
    for line in stdout.splitlines():
        if line.startswith(FRAME_SENTINEL):
            frames.append(json.loads(line[len(FRAME_SENTINEL):]))
    if not frames:
        return None
    if len(frames) > 1:
        return {
            "protocol": "uiforge.machine",
            "protocol_version": 1,
            "request_id": "",
            "success": False,
            "error": {"code": "PROTOCOL_DESYNC", "message": "Multiple framed responses were returned."},
            "diagnostics": [],
            "meta": {"backend": "godot-native"},
        }
    return frames[0]


def run_native_once(godot_binary: str, ui_args: list[str], *, bootstrap: bool | None = None) -> tuple[int, dict[str, object]]:
    root = project_dir()
    did_bootstrap = False
    if bootstrap is None:
        bootstrap = project_needs_bootstrap(root)
    if bootstrap:
        did_bootstrap = True
        boot = run_bootstrap(godot_binary, root)
        if boot.returncode != 0:
            return boot.returncode, {
                "protocol": "uiforge.machine",
                "protocol_version": 1,
                "request_id": "",
                "success": False,
                "error": {
                    "code": "GODOT_IMPORT_FAILED",
                    "message": "Godot could not initialize/import the project before the CLI command.",
                },
                "diagnostics": [],
                "meta": {"backend": "godot-native", "bootstrap": True},
            }
    command = godot_command(godot_binary, root, ui_args)
    process = subprocess.run(command, capture_output=True, text=True)
    if os.environ.get("UIFORGE_TRACE_PROCESSES") == "1":
        print(json.dumps({"uiforge_trace": {"bootstrap": did_bootstrap, "command": command}}), file=sys.stderr)
    payload = parse_framed_stdout(process.stdout)
    if payload is None:
        payload = {
            "success": False,
            "errors": [{
                "code": "GODOT_CLI_NO_FRAME",
                "message": "Godot did not return a framed CLI result.",
                "stderr": process.stderr.strip()[-2000:],
                "stdout": process.stdout.strip()[-4000:],
            }],
        }
    if did_bootstrap:
        payload.setdefault("meta", {})
        if isinstance(payload["meta"], dict):
            payload["meta"]["bootstrap"] = True
    return process.returncode, payload


def machine_oneshot(godot_binary: str, request: dict[str, object]) -> tuple[int, dict[str, object]]:
    root = project_dir()
    raw = json.dumps(request, ensure_ascii=False, separators=(",", ":"))
    ok, size_error = validate_public_request_bytes(raw.encode("utf-8"))
    if not ok:
        return 2, {
            "protocol": "uiforge.machine",
            "protocol_version": 1,
            "request_id": str(request.get("request_id", "")),
            "success": False,
            "error": {"code": size_error, "message": "Request exceeds max size."},
            "result": {},
            "diagnostics": [],
            "meta": {"backend": "godot-native"},
        }
    request_dir = root / ".uiforge"
    request_dir.mkdir(parents=True, exist_ok=True)
    handle = tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        suffix=".json",
        prefix="uiforge_req_",
        dir=str(request_dir),
        delete=False,
    )
    request_path = Path(handle.name)
    try:
        json.dump(request, handle, ensure_ascii=False)
        handle.close()
        code, payload = run_native_once(godot_binary, ["machine-oneshot", str(request_path)])
        return code, payload
    finally:
        try:
            request_path.unlink(missing_ok=True)
        except OSError:
            pass


def exit_class_from_payload(payload: dict[str, object]) -> int:
    if payload.get("success"):
        return 0
    error = payload.get("error", {})
    code_name = error.get("code", "") if isinstance(error, dict) else ""
    if code_name in {"REVISION_CONFLICT", "WRITE_CONFLICT"}:
        return 4
    if code_name in {"OUTPUT_OUTSIDE_WORKSPACE", "PATH_CANONICALIZATION_FAILED", "FILE_NOT_FOUND"}:
        return 5
    if code_name in {"USAGE", "MALFORMED_REQUEST", "UNKNOWN_METHOD", "PROTOCOL_MISMATCH"}:
        return 2
    return 3


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(json.dumps({"success": False, "errors": [{"code": "LAUNCHER_USAGE", "message": "ui_godot.py <godot_binary> <ui_args...>"}]}))
        return 2
    godot_binary = argv[0]
    ui_args = argv[1:]
    if ui_args[:1] == ["serve"]:
        if len(ui_args) > 1 and ui_args[1] not in ("--stdio",):
            print(json.dumps({"success": False, "error": {"code": "USAGE", "message": "Use ui serve --stdio"}}))
            return 2
        from ui_serve import serve_stdio

        return serve_stdio(godot_binary)
    if ui_args[:1] == ["batch"]:
        if len(ui_args) < 2:
            print(json.dumps({"success": False, "error": {"code": "USAGE", "message": "ui batch <file.ui.json> [--stdin]"}}))
            return 2
        params: dict[str, object] = {"document": ui_args[1].replace("\\", "/")}
        if "--stdin" in ui_args:
            params.update(json.loads(sys.stdin.read()))
        request = {
            "protocol": "uiforge.machine",
            "protocol_version": 1,
            "request_id": os.environ.get("UIFORGE_REQUEST_ID", "batch-cli"),
            "method": "batch",
            "params": params,
        }
        code, payload = machine_oneshot(godot_binary, request)
        print(json.dumps(payload, ensure_ascii=False))
        return 0 if payload.get("success") else exit_class_from_payload(payload)
    if ui_args[:1] == ["--machine"]:
        if len(ui_args) < 2:
            print(json.dumps({"success": False, "error": {"code": "USAGE", "message": "--machine requires method"}}))
            return 2
        request = {
            "protocol": "uiforge.machine",
            "protocol_version": 1,
            "request_id": os.environ.get("UIFORGE_REQUEST_ID", "req-cli"),
            "method": ui_args[1],
            "params": {},
        }
        if "--params" in ui_args:
            params_index = ui_args.index("--params")
            params_path = Path(ui_args[params_index + 1])
            request["params"] = json.loads(params_path.read_text(encoding="utf-8"))
        code, payload = machine_oneshot(godot_binary, request)
        print(json.dumps(payload, ensure_ascii=False))
        if payload.get("success"):
            return 0
        error = payload.get("error", {})
        code_name = error.get("code", "") if isinstance(error, dict) else ""
        if code_name in {"REVISION_CONFLICT", "WRITE_CONFLICT"}:
            return 4
        if code_name in {"OUTPUT_OUTSIDE_WORKSPACE", "PATH_CANONICALIZATION_FAILED", "FILE_NOT_FOUND"}:
            return 5
        if code_name in {"USAGE", "MALFORMED_REQUEST", "UNKNOWN_METHOD"}:
            return 2
        return 3 if not payload.get("success") else 0
    exit_code, payload = run_native_once(godot_binary, ui_args)
    if payload.get("protocol") == "uiforge.machine":
        print(json.dumps(payload, indent="\t", ensure_ascii=False))
        return exit_class_from_payload(payload) if not payload.get("success") else 0
    print(json.dumps(payload, indent="\t", ensure_ascii=False))
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
