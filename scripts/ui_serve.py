#!/usr/bin/env python3
"""Persistent stdio machine server broker for UIForge."""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import threading
from pathlib import Path

from ui_godot import FRAME_SENTINEL, project_dir, project_needs_bootstrap, run_bootstrap

REQUEST_PREFIX = "UIFORGE_REQUEST\t"


def _read_line_from_socket(sock: socket.socket) -> str:
    chunks: list[bytes] = []
    while True:
        byte = sock.recv(1)
        if not byte:
            break
        if byte == b"\n":
            break
        chunks.append(byte)
    return b"".join(chunks).decode("utf-8", errors="replace")


def serve_stdio(godot_binary: str) -> int:
    root = project_dir()
    if project_needs_bootstrap(root):
        boot = run_bootstrap(godot_binary, root)
        if boot.returncode != 0:
            print(json.dumps({
                "protocol": "uiforge.machine",
                "protocol_version": 1,
                "request_id": "handshake",
                "success": False,
                "error": {"code": "GODOT_IMPORT_FAILED", "message": "Bootstrap failed."},
                "diagnostics": [],
                "meta": {"backend": "godot-native"},
            }), flush=True)
            return boot.returncode
    process = subprocess.Popen(
        [godot_binary, "--headless", "--path", str(root), "--script", "res://addons/uiforge/cli/machine_server.gd"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    assert process.stdout is not None
    handshake_line = ""
    for _ in range(20):
        line = process.stdout.readline().strip()
        if line.startswith(FRAME_SENTINEL):
            handshake_line = line
            break
    if not handshake_line.startswith(FRAME_SENTINEL):
        print(json.dumps({
            "protocol": "uiforge.machine",
            "protocol_version": 1,
            "request_id": "handshake",
            "success": False,
            "error": {"code": "SERVER_HANDSHAKE_FAILED", "message": "Native server did not emit handshake frame."},
            "diagnostics": [],
            "meta": {"backend": "godot-native"},
        }), flush=True)
        process.kill()
        return 70
    handshake = json.loads(handshake_line[len(FRAME_SENTINEL):])
    port = int(handshake.get("result", {}).get("port", 0))
    if port <= 0:
        print(json.dumps({
            "protocol": "uiforge.machine",
            "protocol_version": 1,
            "request_id": "handshake",
            "success": False,
            "error": {"code": "SERVER_HANDSHAKE_FAILED", "message": "Native server did not publish a port."},
            "diagnostics": [],
            "meta": {"backend": "godot-native"},
        }), flush=True)
        process.kill()
        return 70

    def pump_stderr() -> None:
        assert process.stderr is not None
        for line in process.stderr:
            sys.stderr.write(line)

    threading.Thread(target=pump_stderr, daemon=True).start()

    with socket.create_connection(("127.0.0.1", port)) as sock:
        sock_file = sock.makefile("rwb", buffering=0)
        print(json.dumps({
            "protocol": "uiforge.machine",
            "protocol_version": 1,
            "request_id": "handshake",
            "success": True,
            "result": {"ready": True, "backend": "godot-native", "transport": "stdio"},
            "diagnostics": [],
            "meta": {"backend": "godot-native", "native_port": port},
        }), flush=True)
        for line in sys.stdin:
            stripped = line.strip()
            if not stripped:
                continue
            try:
                request = json.loads(stripped)
            except json.JSONDecodeError:
                print(json.dumps({
                    "protocol": "uiforge.machine",
                    "protocol_version": 1,
                    "request_id": "",
                    "success": False,
                    "error": {"code": "MALFORMED_REQUEST", "message": "Request line was not valid JSON."},
                    "diagnostics": [],
                    "meta": {"backend": "godot-native"},
                }), flush=True)
                continue
            payload = REQUEST_PREFIX + json.dumps(request, separators=(",", ":")) + "\n"
            sock_file.write(payload.encode("utf-8"))
            response_line = _read_line_from_socket(sock)
            while response_line and not response_line.startswith(FRAME_SENTINEL):
                response_line = _read_line_from_socket(sock)
            if response_line.startswith(FRAME_SENTINEL):
                print(response_line[len(FRAME_SENTINEL):], flush=True)
            else:
                print(json.dumps({
                    "protocol": "uiforge.machine",
                    "protocol_version": 1,
                    "request_id": str(request.get("request_id", "")),
                    "success": False,
                    "error": {"code": "PROTOCOL_DESYNC", "message": "Native server returned an invalid response frame."},
                    "diagnostics": [],
                    "meta": {"backend": "godot-native"},
                }), flush=True)
    process.terminate()
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()
    return 0


if __name__ == "__main__":
    raise SystemExit(serve_stdio(sys.argv[1]))
