#!/usr/bin/env python3
"""Lightweight machine command parameter validation."""

from __future__ import annotations

import math
from typing import Any

COMMAND_PARAMETER_SCHEMAS: dict[str, dict[str, str]] = {
    "capabilities": {"params": {}},
    "new": {"params": {"template": "string", "output": "string", "force": "boolean?", "allow_outside_project": "boolean?"}},
    "validate": {"params": {"document": "string"}},
    "inspect": {"params": {"document": "string", "scope": "string", "node": "string?"}},
    "get": {"params": {"document": "string", "node": "string", "property": "string?"}},
    "set": {"params": {"document": "string", "node": "string", "property": "string", "value": "any", "expected_revision": "string?"}},
    "add": {"params": {"document": "string", "parent": "string", "node": "object|string", "expected_revision": "string?"}},
    "delete": {"params": {"document": "string", "node": "string", "expected_revision": "string?"}},
    "move": {"params": {"document": "string", "node": "string", "parent": "string", "index": "integer?", "expected_revision": "string?"}},
    "duplicate": {"params": {"document": "string", "node": "string", "new_id": "string", "expected_revision": "string?"}},
    "batch": {"params": {"document": "string", "operations": "array", "expected_revision": "string?", "dry_run": "boolean?"}},
    "build": {"params": {"document": "string", "output": "string?", "force": "boolean?", "allow_outside_project": "boolean?"}},
    "build-all": {"params": {"source_dir": "string?", "output_dir": "string?", "force": "boolean?", "allow_outside_project": "boolean?"}},
    "render": {"params": {"document": "string", "viewport": "string?", "output": "string?", "state": "string?", "force": "boolean?", "allow_outside_project": "boolean?"}},
    "shutdown": {"params": {}},
}

BATCH_OPERATION_SCHEMAS: dict[str, dict[str, str]] = {
    "set": {"node": "string", "property": "string", "value": "any"},
    "add": {"parent": "string", "node": "object"},
    "delete": {"node": "string"},
    "move": {"node": "string", "parent": "string", "index": "integer?"},
    "duplicate": {"node": "string", "new_id": "string"},
}


def _invalid(field_path: str, message: str) -> dict[str, Any]:
    return {"ok": False, "code": "MALFORMED_PARAMS", "message": message, "field": field_path}


def _is_whole_number(value: Any) -> bool:
    if isinstance(value, bool):
        return False
    if isinstance(value, int):
        return True
    if isinstance(value, float):
        return math.isfinite(value) and value == int(value)
    return False


def _validate_field(field_path: str, value: Any, type_name: str) -> dict[str, Any] | None:
    optional = type_name.endswith("?")
    base_type = type_name[:-1] if optional else type_name
    if base_type == "any":
        return None
    if base_type == "string":
        if not isinstance(value, str):
            return _invalid(field_path, f"Parameter '{field_path}' must be a string.")
        return None
    if base_type == "boolean":
        if not isinstance(value, bool):
            return _invalid(field_path, f"Parameter '{field_path}' must be a boolean.")
        return None
    if base_type == "integer":
        if not _is_whole_number(value):
            return _invalid(field_path, f"Parameter '{field_path}' must be an integer.")
        return None
    if base_type == "array":
        if not isinstance(value, list):
            return _invalid(field_path, f"Parameter '{field_path}' must be an array.")
        return None
    if base_type == "object":
        if not isinstance(value, dict):
            return _invalid(field_path, f"Parameter '{field_path}' must be an object.")
        return None
    if base_type == "object|string":
        if not isinstance(value, (dict, str)):
            return _invalid(field_path, f"Parameter '{field_path}' must be an object or string.")
        return None
    return _invalid(field_path, f"Unsupported parameter schema '{type_name}'.")


def validate_command_params(method: str, params: Any) -> dict[str, Any]:
    if not isinstance(params, dict):
        return _invalid("params", "Request params must be an object when present.")
    schema = COMMAND_PARAMETER_SCHEMAS.get(method, {}).get("params", {})
    for field_name, value in params.items():
        if field_name not in schema:
            continue
        field_error = _validate_field(field_name, value, schema[field_name])
        if field_error is not None:
            return field_error
    for field_name, type_name in schema.items():
        if type_name.endswith("?"):
            continue
        if field_name not in params:
            return _invalid(field_name, f"Required parameter '{field_name}' is missing.")
    if method == "batch":
        return _validate_batch_params(params)
    return {"ok": True, "params": params}


def _validate_batch_params(params: dict[str, Any]) -> dict[str, Any]:
    operations = params.get("operations")
    if not isinstance(operations, list):
        return _invalid("operations", "Parameter 'operations' must be an array.")
    for index, operation in enumerate(operations):
        if not isinstance(operation, dict):
            return _invalid(f"operations[{index}]", "Batch operation must be an object.")
        op_name = str(operation.get("op", ""))
        op_schema = BATCH_OPERATION_SCHEMAS.get(op_name)
        if op_schema is None:
            return _invalid(f"operations[{index}].op", f"Unknown batch operation '{op_name}'.")
        for field_name, value in operation.items():
            if field_name == "op" or field_name not in op_schema:
                continue
            field_error = _validate_field(f"operations[{index}].{field_name}", value, op_schema[field_name])
            if field_error is not None:
                return field_error
    return {"ok": True, "params": params}
