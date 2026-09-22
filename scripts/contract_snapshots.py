#!/usr/bin/env python3
"""Load authoritative UIForge contract snapshots exported from native Godot."""

from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
SNAPSHOT_DIR = ROOT / "contract" / "snapshots"


def _load_json(name: str) -> Any:
    path = SNAPSHOT_DIR / name
    return json.loads(path.read_text(encoding="utf-8"))


@lru_cache(maxsize=1)
def manifest() -> dict[str, Any]:
    return _load_json("manifest.json")


@lru_cache(maxsize=1)
def semantic_property_schemas() -> dict[str, list[dict[str, Any]]]:
    payload = _load_json("semantic_property_schemas.json")
    return {str(key): value for key, value in payload.items()}


@lru_cache(maxsize=1)
def property_groups() -> dict[str, list[str]]:
    payload = _load_json("property_groups.json")
    return {str(key): [str(item) for item in value] for key, value in payload.items()}


@lru_cache(maxsize=1)
def component_definitions() -> dict[str, dict[str, Any]]:
    payload = _load_json("component_definitions.json")
    return {str(key): dict(value) for key, value in payload.items()}


@lru_cache(maxsize=1)
def supported_node_types() -> list[str]:
    payload = _load_json("supported_node_types.json")
    return [str(item) for item in payload]


@lru_cache(maxsize=1)
def native_property_inventory() -> dict[str, Any]:
    return _load_json("native_property_inventory.json")


def component_names() -> set[str]:
    return set(component_definitions())


def native_type(node_type: str) -> str:
    definition = component_definitions().get(node_type)
    if definition and definition.get("native_type"):
        return str(definition["native_type"])
    native_map = {
        "RichText": "RichTextLabel",
        "Texture": "TextureRect",
        "Slider": "HSlider",
        "Grid": "GridContainer",
        "HBox": "HBoxContainer",
        "VBox": "VBoxContainer",
        "Separator": "HSeparator",
        "Spacer": "Control",
        "HSlider": "HSlider",
        "VSlider": "VSlider",
        "PanelContainer": "PanelContainer",
    }
    return native_map.get(node_type, node_type)


def style_name(node_type: str) -> str:
    definition = component_definitions().get(node_type, {})
    return str(definition.get("style", "panel"))


def fill_style_name(node_type: str) -> str:
    definition = component_definitions().get(node_type, {})
    return str(definition.get("fill_style", "button_primary"))


def native_property_names(class_name: str) -> set[str]:
    classes = native_property_inventory().get("classes", {})
    names = classes.get(class_name, [])
    return {str(name) for name in names}


def normalize_capabilities_for_parity(caps: dict[str, Any]) -> dict[str, Any]:
    normalized = json.loads(json.dumps(caps, sort_keys=True))
    for key in (
        "backend",
        "generator_version",
        "persistent_server",
        "supported_transports",
        "native_property_schemas",
    ):
        normalized.pop(key, None)
    commands = normalized.get("available_commands", [])
    if isinstance(commands, list) and "shutdown" in commands:
        normalized["available_commands"] = [command for command in commands if command != "shutdown"]
    return normalized


def diff_paths(left: Any, right: Any, prefix: str = "") -> list[str]:
    if type(left) != type(right):
        return [f"{prefix}: type mismatch {type(left).__name__} vs {type(right).__name__}"]
    if isinstance(left, dict):
        failures: list[str] = []
        left_keys = set(left)
        right_keys = set(right)
        for missing in sorted(left_keys - right_keys):
            failures.append(f"{prefix}.{missing}: missing on right")
        for extra in sorted(right_keys - left_keys):
            failures.append(f"{prefix}.{extra}: extra on right")
        for key in sorted(left_keys & right_keys):
            child_prefix = f"{prefix}.{key}" if prefix else str(key)
            failures.extend(diff_paths(left[key], right[key], child_prefix))
        return failures
    if isinstance(left, list):
        if len(left) != len(right):
            return [f"{prefix}: list length {len(left)} vs {len(right)}"]
        failures = []
        for index, (left_item, right_item) in enumerate(zip(left, right)):
            failures.extend(diff_paths(left_item, right_item, f"{prefix}[{index}]"))
        return failures
    if left != right:
        return [f"{prefix}: {left!r} != {right!r}"]
    return []
