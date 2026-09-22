#!/usr/bin/env python3
"""Persistent stdio machine server broker for UIForge."""

from __future__ import annotations

import json
import os
import queue
import secrets
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

from ui_godot import FRAME_SENTINEL, project_dir, project_needs_bootstrap, run_bootstrap
from uiforge_machine import (
    CONNECT_PREFIX,
    MAX_REQUEST_BYTES,
    error_response,
    success_response,
    validate_request,
)

REQUEST_PREFIX = "UIFORGE_REQUEST\t"
HANDSHAKE_TIMEOUT_SECONDS = 30.0
SHUTDOWN_WAIT_SECONDS = 10.0


def _trace(event: dict[str, object]) -> None:
    if os.environ.get("UIFORGE_TRACE_PROCESSES") == "1":
        print(json.dumps({"uiforge_trace": event}), file=sys.stderr, flush=True)


def _error_envelope(request_id: str, code: str, message: str) -> dict[str, object]:
    return error_response(request_id, code, message, backend="godot-native")


def _read_bounded_line(source, *, max_bytes: int = MAX_REQUEST_BYTES) -> tuple[bytes | None, str | None]:
    chunks: list[bytes] = []
    total = 0
    while True:
        chunk = source.read(1)
        if chunk == b"":
            return None, None
        if chunk == b"\n":
            return b"".join(chunks), None
        total += len(chunk)
        if total > max_bytes:
            while chunk != b"\n" and chunk != b"":
                chunk = source.read(1)
            return None, "REQUEST_TOO_LARGE"
        chunks.append(chunk)


def _read_framed_handshake(stdout, timeout_seconds: float) -> tuple[str, str | None]:
    deadline = time.monotonic() + timeout_seconds
    lines: queue.Queue[str | None] = queue.Queue()

    def reader() -> None:
        assert stdout is not None
        try:
            for line in stdout:
                lines.put(line.rstrip("\r\n"))
        finally:
            lines.put(None)

    threading.Thread(target=reader, daemon=True).start()
    while time.monotonic() < deadline:
        try:
            line = lines.get(timeout=max(0.05, min(0.5, deadline - time.monotonic())))
        except queue.Empty:
            continue
        if line is None:
            break
        if line.startswith(FRAME_SENTINEL):
            return line, None
    return "", "SERVER_HANDSHAKE_TIMEOUT"


def _terminate_process_tree(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=SHUTDOWN_WAIT_SECONDS)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=SHUTDOWN_WAIT_SECONDS)


def _read_line_from_socket(sock: socket.socket, *, max_bytes: int | None = None) -> tuple[str, str | None]:
    chunks: list[bytes] = []
    total = 0
    while True:
        byte = sock.recv(1)
        if not byte:
            return "", "PROTOCOL_DESYNC"
        if byte == b"\n":
            break
        if max_bytes is not None:
            total += len(byte)
            if total > max_bytes:
                while byte != b"\n" and byte:
                    byte = sock.recv(1)
                return "", "REQUEST_TOO_LARGE"
        chunks.append(byte)
    return b"".join(chunks).decode("utf-8", errors="replace"), None


def serve_stdio(godot_binary: str) -> int:
    root = project_dir()
    if project_needs_bootstrap(root):
        boot = run_bootstrap(godot_binary, root)
        if boot.returncode != 0:
            print(json.dumps(_error_envelope("handshake", "GODOT_IMPORT_FAILED", "Bootstrap failed.")), flush=True)
            return boot.returncode

    session_token = secrets.token_hex(16)
    env = os.environ.copy()
    env["UIFORGE_SERVER_TOKEN"] = session_token
    process = subprocess.Popen(
        [godot_binary, "--headless", "--path", str(root), "--script", "res://addons/uiforge/cli/machine_server.gd"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
        env=env,
    )
    assert process.stdout is not None
    _trace({"event": "native_spawned", "pid": process.pid})
    handshake_line, handshake_error = _read_framed_handshake(process.stdout, HANDSHAKE_TIMEOUT_SECONDS)
    if handshake_error == "SERVER_HANDSHAKE_TIMEOUT" or not handshake_line.startswith(FRAME_SENTINEL):
        print(json.dumps(_error_envelope("handshake", handshake_error or "SERVER_HANDSHAKE_FAILED", "Native server did not emit handshake frame.")), flush=True)
        _terminate_process_tree(process)
        _trace({"event": "native_stopped", "pid": process.pid, "reason": "handshake_failed"})
        return 70
    handshake = json.loads(handshake_line[len(FRAME_SENTINEL):])
    port = int(handshake.get("result", {}).get("port", 0))
    if port <= 0:
        print(json.dumps(_error_envelope("handshake", "SERVER_HANDSHAKE_FAILED", "Native server did not publish a port.")), flush=True)
        _terminate_process_tree(process)
        _trace({"event": "native_stopped", "pid": process.pid, "reason": "missing_port"})
        return 70

    def pump_stderr() -> None:
        assert process.stderr is not None
        for line in process.stderr:
            sys.stderr.write(line)

    threading.Thread(target=pump_stderr, daemon=True).start()

    shutdown_requested = False
    with socket.create_connection(("127.0.0.1", port), timeout=5) as sock:
        sock.sendall((CONNECT_PREFIX + session_token + "\n").encode("utf-8"))
        print(json.dumps(success_response(
            "handshake",
            {"ready": True, "backend": "godot-native", "transport": "stdio"},
            backend="godot-native",
        )), flush=True)
        _trace({"event": "native_ready", "pid": process.pid})

        stdin_buffer = sys.stdin.buffer
        while True:
            line_bytes, size_error = _read_bounded_line(stdin_buffer)
            if line_bytes is None and size_error is None:
                break
            if size_error == "REQUEST_TOO_LARGE":
                print(json.dumps(_error_envelope("", "REQUEST_TOO_LARGE", "Request exceeds max size.")), flush=True)
                continue
            stripped = line_bytes.decode("utf-8", errors="replace").strip()
            if not stripped:
                continue
            try:
                request = json.loads(stripped)
            except json.JSONDecodeError:
                print(json.dumps(_error_envelope("", "MALFORMED_REQUEST", "Request line was not valid JSON.")), flush=True)
                continue
            validated = validate_request(request)
            if not validated.get("ok"):
                print(json.dumps(_error_envelope(
                    str(request.get("request_id", "")) if isinstance(request, dict) else "",
                    str(validated.get("code", "MALFORMED_REQUEST")),
                    str(validated.get("message", "Malformed request.")),
                )), flush=True)
                continue
            payload = REQUEST_PREFIX + json.dumps(validated["request"], separators=(",", ":")) + "\n"
            sock.sendall(payload.encode("utf-8"))
            response_line, socket_size_error = _read_line_from_socket(sock, max_bytes=None)
            while response_line and not response_line.startswith(FRAME_SENTINEL) and socket_size_error is None:
                response_line, socket_size_error = _read_line_from_socket(sock, max_bytes=None)
            if socket_size_error == "REQUEST_TOO_LARGE":
                print(json.dumps(_error_envelope(str(validated["request"].get("request_id", "")), "REQUEST_TOO_LARGE", "Request exceeds max size.")), flush=True)
                continue
            if response_line.startswith(FRAME_SENTINEL):
                response_payload = json.loads(response_line[len(FRAME_SENTINEL):])
                print(json.dumps(response_payload, separators=(",", ":")), flush=True)
                if (
                    str(validated["request"].get("method", "")) == "shutdown"
                    and bool(response_payload.get("success", False))
                ):
                    shutdown_requested = True
                    break
            else:
                print(json.dumps(_error_envelope(str(validated["request"].get("request_id", "")), "PROTOCOL_DESYNC", "Native server returned an invalid response frame.")), flush=True)

    _terminate_process_tree(process)
    _trace({"event": "native_stopped", "pid": process.pid, "reason": "shutdown" if shutdown_requested else "eof"})
    return 0


if __name__ == "__main__":
    raise SystemExit(serve_stdio(sys.argv[1]))
