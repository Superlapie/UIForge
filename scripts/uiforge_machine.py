#!/usr/bin/env python3
"""Shared UIForge machine protocol helpers for Python transports."""

from __future__ import annotations

from typing import Any

PROTOCOL_ID = "uiforge.machine"
PROTOCOL_VERSION = 1
COMMAND_CONTRACT_VERSION = 1
MAX_REQUEST_BYTES = 1048576
FRAME_SENTINEL = "UIFORGE_MACHINE_V1\t"

EXIT_SUCCESS = 0
EXIT_CLI_USAGE = 2
EXIT_VALIDATION = 3
EXIT_CONFLICT = 4
EXIT_IO_TRUST = 5
EXIT_INTERNAL = 70


def validate_request(payload: Any) -> dict[str, Any]:
    if not isinstance(payload, dict):
        return {"ok": False, "code": "MALFORMED_REQUEST", "message": "Request must be a JSON object."}
    if str(payload.get("protocol", "")) != PROTOCOL_ID:
        return {"ok": False, "code": "PROTOCOL_MISMATCH", "message": "Unsupported protocol identifier."}
    if int(payload.get("protocol_version", 0)) != PROTOCOL_VERSION:
        return {
            "ok": False,
            "code": "UNSUPPORTED_PROTOCOL_VERSION",
            "message": f"Unsupported protocol version {payload.get('protocol_version', 0)}.",
        }
    if not str(payload.get("method", "")):
        return {"ok": False, "code": "MALFORMED_REQUEST", "message": "Request method is required."}
    params = payload.get("params", {})
    if params is not None and not isinstance(params, dict):
        return {"ok": False, "code": "MALFORMED_REQUEST", "message": "Request params must be an object when present."}
    return {"ok": True, "request": payload}


def _meta(backend: str) -> dict[str, Any]:
    return {
        "backend": backend,
        "schema_version": 1,
        "command_contract_version": COMMAND_CONTRACT_VERSION,
    }


def success_response(request_id: str, result: dict[str, Any], diagnostics: list[dict[str, Any]] | None = None, *, backend: str) -> dict[str, Any]:
    return {
        "protocol": PROTOCOL_ID,
        "protocol_version": PROTOCOL_VERSION,
        "request_id": request_id,
        "success": True,
        "result": result or {},
        "diagnostics": normalize_diagnostics(diagnostics or []),
        "meta": _meta(backend),
    }


def error_response(
    request_id: str,
    code: str,
    message: str,
    diagnostics: list[dict[str, Any]] | None = None,
    *,
    backend: str,
    result: dict[str, Any] | None = None,
) -> dict[str, Any]:
    return {
        "protocol": PROTOCOL_ID,
        "protocol_version": PROTOCOL_VERSION,
        "request_id": request_id,
        "success": False,
        "error": {"code": code, "message": message},
        "result": result or {},
        "diagnostics": normalize_diagnostics(diagnostics or []),
        "meta": _meta(backend),
    }


def normalize_diagnostics(raw: list[Any]) -> list[dict[str, Any]]:
    normalized: list[dict[str, Any]] = []
    for item in raw:
        if not isinstance(item, dict):
            continue
        entry: dict[str, Any] = {
            "severity": str(item.get("severity", "error")),
            "code": str(item.get("code", "UNKNOWN")),
            "message": str(item.get("message", "")),
        }
        for key in ("path", "node", "property", "json_pointer", "recommendation"):
            if key in item and str(item.get(key, "")):
                entry[key] = str(item[key])
        normalized.append(entry)
    return normalized


def exit_class_for_response(response: dict[str, Any]) -> int:
    if response.get("success"):
        return EXIT_SUCCESS
    code = str(response.get("error", {}).get("code", ""))
    if code in {
        "USAGE",
        "MALFORMED_REQUEST",
        "UNKNOWN_COMMAND",
        "UNKNOWN_METHOD",
        "UNSUPPORTED_PROTOCOL_VERSION",
        "PROTOCOL_MISMATCH",
        "REQUEST_TOO_LARGE",
    }:
        return EXIT_CLI_USAGE
    if code in {"REVISION_CONFLICT", "WRITE_CONFLICT"}:
        return EXIT_CONFLICT
    if code in {
        "OUTPUT_OUTSIDE_WORKSPACE",
        "PATH_CANONICALIZATION_FAILED",
        "LOCK_CREATE_FAILED",
        "FILE_NOT_FOUND",
        "FILE_OPEN_FAILED",
    } or code.endswith("_FAILED") or code.startswith("PATH_"):
        return EXIT_IO_TRUST
    return EXIT_VALIDATION


def frame_line(payload: dict[str, Any]) -> str:
    import json

    return FRAME_SENTINEL + json.dumps(payload, separators=(",", ":"))
