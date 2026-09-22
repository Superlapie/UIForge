#!/usr/bin/env python3
"""Shared UIForge machine protocol helpers for Python transports."""

from __future__ import annotations

from typing import Any
PROTOCOL_ID = "uiforge.machine"
PROTOCOL_VERSION = 1
COMMAND_CONTRACT_VERSION = 1
MAX_REQUEST_BYTES = 1048576
INTERNAL_REQUEST_PREFIX = "UIFORGE_REQUEST\t"
INTERNAL_REQUEST_PREFIX_BYTES = len(INTERNAL_REQUEST_PREFIX.encode("utf-8"))
MAX_INTERNAL_LINE_BYTES = MAX_REQUEST_BYTES + INTERNAL_REQUEST_PREFIX_BYTES
FRAME_SENTINEL = "UIFORGE_MACHINE_V1\t"
CONNECT_PREFIX = "UIFORGE_CONNECT\t"

EXIT_SUCCESS = 0
EXIT_CLI_USAGE = 2
EXIT_VALIDATION = 3
EXIT_CONFLICT = 4
EXIT_IO_TRUST = 5
EXIT_INTERNAL = 70


def _is_exact_protocol_version(value: Any) -> bool:
    if isinstance(value, bool):
        return False
    return isinstance(value, int) and value == PROTOCOL_VERSION


def public_request_byte_length(raw: str) -> int:
    return len(raw.encode("utf-8"))


def validate_public_request_bytes(raw: bytes) -> tuple[bool, str | None]:
    if len(raw) > MAX_REQUEST_BYTES:
        return False, "REQUEST_TOO_LARGE"
    return True, None


def validate_request(payload: Any) -> dict[str, Any]:
    if not isinstance(payload, dict):
        return {"ok": False, "code": "MALFORMED_REQUEST", "message": "Request must be a JSON object."}
    protocol = payload.get("protocol")
    if not isinstance(protocol, str) or protocol != PROTOCOL_ID:
        return {"ok": False, "code": "PROTOCOL_MISMATCH", "message": "Unsupported protocol identifier."}
    if not _is_exact_protocol_version(payload.get("protocol_version")):
        version = payload.get("protocol_version")
        if isinstance(version, bool) or not isinstance(version, int):
            return {"ok": False, "code": "MALFORMED_REQUEST", "message": "protocol_version must be an integer."}
        return {
            "ok": False,
            "code": "UNSUPPORTED_PROTOCOL_VERSION",
            "message": f"Unsupported protocol version {version}.",
        }
    request_id = payload.get("request_id")
    if not isinstance(request_id, str) or not request_id:
        return {"ok": False, "code": "MALFORMED_REQUEST", "message": "request_id is required."}
    method = payload.get("method")
    if not isinstance(method, str) or not method:
        return {"ok": False, "code": "MALFORMED_REQUEST", "message": "Request method is required."}
    if "params" in payload:
        params = payload.get("params")
        if not isinstance(params, dict):
            return {"ok": False, "code": "MALFORMED_REQUEST", "message": "Request params must be an object when present."}
    return {"ok": True, "request": payload}


def machine_failure_result(legacy: dict[str, Any]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key in (
        "committed",
        "failed_index",
        "failed_op",
        "old_revision",
        "new_revision",
        "operations",
        "dry_run",
        "expected_revision",
        "current_revision",
        "revision",
        "document",
    ):
        if key in legacy:
            result[key] = legacy[key]
    if not result.get("committed") and "committed" not in legacy and legacy.get("success") is False:
        result["committed"] = False
    errors = legacy.get("errors", [])
    if isinstance(errors, list) and errors:
        first = errors[0]
        if isinstance(first, dict):
            for key in ("expected_revision", "current_revision", "index"):
                if key in first and key not in result:
                    result[key] = first[key]
    return result


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
