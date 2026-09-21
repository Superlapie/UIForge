#!/usr/bin/env python3
"""Portable fallback for the UIForge CLI when Godot is not installed.

It deliberately speaks the same JSON document protocol as the Godot CLI. The
authoritative editor/compiler is GDScript; this shim keeps AI document work,
validation, inspection, and deterministic scene generation available on CI or
on an authoring machine before Godot is installed.
"""

from __future__ import annotations

import copy
import json
import math
import re
import sys
from pathlib import Path
from typing import Any

from uiforge_contract import (
    check_create_allowed,
    check_replace_allowed,
    content_hash,
    load_theme_checked,
    provenance_header,
    resource_id_part,
    source_identity,
    validate_authored_metadata_key,
    validate_external_resource,
    validate_godot_override,
    validate_output,
    verify_scene_syntax,
    write_source_atomically,
    write_text_atomically,
)

ROOT = Path(__file__).resolve().parents[1]
THEME_PATH = ROOT / "addons/uiforge/themes/dark_fantasy.theme.json"
SCHEMA_VERSION = 1
ID_GRAMMAR = re.compile(r"^[A-Za-z][A-Za-z0-9_-]*$")
DOCUMENT_NAME_GRAMMAR = re.compile(r"^[A-Za-z0-9_-]+$")
TOP_LEVEL_KEYS = {
    "schema_version", "name", "viewport", "theme", "root", "components",
    "theme_overrides", "metadata", "mock_data", "reference",
}
NODE_KEYS = {
    "id", "name", "type", "component", "overrides", "base_type", "layout", "properties",
    "style", "background_style", "fill_style", "states", "action", "binding", "effects",
    "transitions", "metadata", "mock_data", "decorations", "children",
}
LAYOUT_KEYS = {
    "position", "size", "min_size", "max_size", "anchors", "offsets", "anchors_preset",
    "padding", "gap", "grow", "grow_horizontal", "grow_vertical", "size_flags_horizontal",
    "size_flags_vertical", "size_flags_stretch_ratio", "z_index", "mouse_filter", "pivot",
    "rotation_degrees", "scale", "layout_mode",
}
NATIVE_TYPES = {
    "Control", "Panel", "Label", "RichText", "Texture", "Button", "TextureButton",
    "CheckBox", "CheckButton", "Slider", "HSlider", "VSlider", "SpinBox", "ProgressBar", "LineEdit",
    "TextEdit", "OptionButton", "MenuButton", "LinkButton", "ScrollContainer", "Grid", "HBox",
    "VBox", "MarginContainer", "CenterContainer", "PanelContainer", "TabBar", "TabContainer",
    "AspectRatioContainer", "FlowContainer", "HSplitContainer", "VSplitContainer", "ColorRect", "NinePatchRect",
    "TabButton", "Separator", "Spacer",
}
COMPONENTS = {
    "WindowFrame": ("Panel", "window"), "OrnatePanel": ("Panel", "panel"),
    "SimplePanel": ("Panel", "inset"), "SectionPanel": ("Panel", "panel"),
    "PrimaryButton": ("Button", "button_primary"), "SecondaryButton": ("Button", "button_secondary"),
    "IconButton": ("TextureButton", "button_secondary"), "TabBar": ("TabBar", "tab"),
    "TabButton": ("Button", "tab"), "ItemSlot": ("Panel", "slot"), "ItemGrid": ("GridContainer", "inset"),
    "EquipmentSlot": ("Panel", "slot"), "EquipmentLayout": ("Panel", "inset"),
    "InventoryPanel": ("Panel", "panel"), "BankPanel": ("Panel", "panel"),
    "QuestEntry": ("Button", "button_secondary"), "QuestList": ("VBoxContainer", "inset"),
    "ScrollList": ("ScrollContainer", "inset"), "Tooltip": ("Panel", "panel"),
    "ContextMenu": ("Panel", "panel"), "ContextMenuEntry": ("Button", "button_secondary"),
    "ModalDialog": ("Panel", "window"), "ProgressDisplay": ("ProgressBar", "panel"),
    "StatusBar": ("ProgressBar", "panel"), "CurrencyDisplay": ("HBoxContainer", "inset"),
    "SearchBox": ("LineEdit", "inset"), "Dropdown": ("OptionButton", "inset"), "CheckToggle": ("CheckButton", "button_secondary"), "SidebarNavigation": ("VBoxContainer", "inset"),
    "SidebarEntry": ("Button", "button_secondary"), "GameplaySidebar": ("Panel", "sidebar_rail"),
    "GameplaySidebarTab": ("Button", "sidebar_tab"), "GameplaySidebarToggle": ("Button", "sidebar_toggle"),
    "EnemyTargetFrame": ("Panel", "target_frame"), "EnemyTargetHealthBar": ("ProgressBar", "target_track"),
    "EnemyStatusEffect": ("Panel", "status_effect"), "CharacterPreviewFrame": ("Panel", "window"),
    "NotificationToast": ("Panel", "panel"), "LootPopup": ("Panel", "panel"),
    "CombatHUD": ("Panel", "hud_shell"), "ResourceBar": ("ProgressBar", "status_track"),
    "HealthBar": ("ProgressBar", "status_track"), "PrayerBar": ("ProgressBar", "status_track"),
    "RunBar": ("ProgressBar", "status_track"), "SpecialBar": ("ProgressBar", "status_track"),
    "HUDMedallion": ("Panel", "hud_medallion"), "ActionSlot": ("Button", "action_slot"),
}
FILL_STYLES = {"HealthBar": "status_health", "PrayerBar": "status_prayer", "RunBar": "status_run", "SpecialBar": "status_special", "EnemyTargetHealthBar": "target_health"}
NATIVE_MAP = {
    "RichText": "RichTextLabel", "Texture": "TextureRect", "Slider": "HSlider",
    "Grid": "GridContainer", "HBox": "HBoxContainer", "VBox": "VBoxContainer",
    "Separator": "HSeparator", "Spacer": "Control",
}
PROPERTY_GROUPS = {
    "Layout": [
        "layout.position", "layout.size", "layout.min_size", "layout.max_size", "layout.anchors",
        "layout.offsets", "layout.anchors_preset", "layout.grow_horizontal", "layout.grow_vertical",
        "layout.size_flags_horizontal", "layout.size_flags_vertical", "layout.size_flags_stretch_ratio",
        "layout.pivot", "layout.rotation_degrees", "layout.scale", "properties.clip_contents",
        "properties.fit_content", "properties.expand_mode", "properties.stretch_mode", "properties.columns",
        "properties.separation", "properties.alignment",
    ],
    "Content": [
        "properties.text", "properties.title", "properties.label", "properties.count", "properties.show_label", "properties.icon", "properties.texture", "properties.texture_region", "properties.slot_size", "properties.gap", "properties.value", "properties.min_value",
        "properties.max_value", "properties.step", "properties.placeholder", "properties.max_length",
        "properties.tick_count", "properties.show_percentage", "properties.flip_h", "properties.flip_v",
    ],
    "Typography": [
        "properties.font", "properties.font_size", "properties.color", "properties.outline_size",
        "properties.font_outline_color", "properties.font_shadow_color", "properties.horizontal_alignment",
        "properties.vertical_alignment", "properties.autowrap", "properties.clip_text",
        "properties.text_overrun_behavior",
    ],
    "Style": [
        "style", "background_style", "fill_style", "properties.modulate", "properties.self_modulate", "properties.opacity", "properties.material",
        "properties.theme", "properties.theme_type_variation", "properties.texture_filter", "properties.texture_repeat",
    ],
    "Interaction": [
        "action", "binding", "effects", "properties.tooltip", "properties.disabled", "properties.editable",
        "properties.focus_mode", "properties.mouse_default_cursor_shape", "properties.toggle_mode",
        "properties.button_pressed", "properties.secret", "properties.clear_button_enabled", "properties.context_menu_enabled",
        "properties.horizontal_scroll_mode", "properties.vertical_scroll_mode",
    ],
    "Accessibility": ["properties.accessibility_name", "properties.accessibility_description", "properties.auto_translate", "properties.layout_direction"],
    "Advanced": ["properties.visible", "properties.show_behind_parent", "properties.top_level", "properties.z_as_relative", "properties.y_sort_enabled", "properties.godot_overrides", "decorations", "transitions", "metadata"],
}


def capability_property_schemas() -> dict[str, list[dict[str, Any]]]:
    """Expose the portable property contract when Godot is unavailable.

    The native CLI gets richer type/default information from the shared
    GDScript catalog. The fallback still returns a deterministic per-node
    schema so an agent can discover the same property paths in CI or on a
    machine that has not installed Godot yet.
    """
    schemas: dict[str, list[dict[str, Any]]] = {}
    all_types = sorted(NATIVE_TYPES | set(COMPONENTS))
    for node_type in all_types:
        fields: list[dict[str, Any]] = []
        for category, paths in PROPERTY_GROUPS.items():
            for path in paths:
                value_type = "string"
                if path in {"layout.position", "layout.size", "layout.min_size", "layout.max_size", "layout.pivot", "layout.scale"}:
                    value_type = "vec2"
                elif path.startswith("layout.anchors") or path.startswith("layout.offsets") or path in {"layout.size_flags_stretch_ratio", "properties.opacity", "properties.value", "properties.min_value", "properties.max_value", "properties.step"}:
                    value_type = "float"
                elif path in {"properties.columns", "properties.outline_size", "properties.max_length", "properties.tick_count"}:
                    value_type = "int"
                elif path.startswith("properties.") and path not in {"properties.text", "properties.icon", "properties.texture", "properties.font", "properties.font_size", "properties.color", "properties.font_outline_color", "properties.font_shadow_color", "properties.material", "properties.theme", "properties.theme_type_variation", "properties.tooltip", "properties.accessibility_name", "properties.accessibility_description", "properties.godot_overrides"}:
                    value_type = "bool"
                if path in {"metadata", "decorations", "transitions", "properties.godot_overrides", "properties.texture_region"}:
                    value_type = "json"
                fields.append({"path": path, "category": category, "type": value_type})
        schemas[node_type] = fields
    return schemas


def capability_native_properties() -> dict[str, list[dict[str, Any]]]:
    """Keep the native-property capability key stable without an engine.

    Godot's ClassDB is the authoritative source for this list. The fallback
    cannot introspect an engine that is not installed, so it returns an empty
    list per supported type while still exposing the portable semantic schema.
    """
    return {node_type: [] for node_type in sorted(NATIVE_TYPES | set(COMPONENTS))}


def is_valid_id(node_id: str) -> bool:
    return bool(node_id) and ID_GRAMMAR.fullmatch(str(node_id)) is not None


def is_valid_document_name(name: str) -> bool:
    return bool(name) and DOCUMENT_NAME_GRAMMAR.fullmatch(str(name)) is not None


def document_name_diagnostic(name: str) -> dict[str, Any]:
    if is_valid_document_name(name):
        return {}
    return {
        "severity": "error",
        "code": "DOCUMENT_NAME_INVALID",
        "message": f"Document name '{name}' must match {DOCUMENT_NAME_GRAMMAR.pattern}.",
        "node": "",
        "recommendation": "Use a stable document name with letters, numbers, underscores, and hyphens only.",
    }


def id_diagnostic(node_id: str, context_id: str = "") -> dict[str, Any]:
    if is_valid_id(node_id):
        return {}
    return {
        "severity": "error",
        "code": "ID_INVALID",
        "message": f"Node id '{node_id}' must match {ID_GRAMMAR.pattern}.",
        "node": context_id or node_id,
        "recommendation": "Use stable snake_case IDs that start with a letter and survive Godot node-name validation unchanged.",
    }


def contains_id(node: dict[str, Any], target_id: str) -> bool:
    for child in node.get("children", []):
        if not isinstance(child, dict):
            continue
        if str(child.get("id", "")) == target_id or contains_id(child, target_id):
            return True
    return False


def remap_ids(node: dict[str, Any], base_id: str) -> None:
    node["id"] = base_id
    children = node.get("children", [])
    if not isinstance(children, list):
        return
    for index, child in enumerate(children):
        if isinstance(child, dict):
            remap_ids(child, f"{base_id}_{index + 1}")


def collect_ids(node: dict[str, Any]) -> set[str]:
    ids: set[str] = set()
    for current, _parent in walk(node):
        node_id = str(current.get("id", ""))
        if node_id:
            ids.add(node_id)
    return ids


def commit_mutation(path: str, mutate) -> tuple[dict[str, Any], int]:
    loaded = load(path)
    data = loaded.get("document")
    if data is None:
        return {"success": False, "committed": False, "errors": loaded.get("errors", [])}, 1
    expected_revision = str(loaded.get("revision_hash", ""))
    working = copy.deepcopy(data)
    operation = mutate(working)
    if not operation.get("success"):
        operation["committed"] = False
        return operation, 1
    validation = validate(working)
    if not validation["success"]:
        return {
            "success": False,
            "committed": False,
            "errors": [item for item in validation["diagnostics"] if item.get("severity") == "error"],
            "warnings": validation["warnings"],
            "diagnostics": validation["diagnostics"],
        }, 1
    saved = save(path, working, expected_revision)
    if not saved.get("success", False):
        operation["success"] = False
        operation["committed"] = False
        operation["errors"] = saved.get("errors", [{"code": "SAVE_FAILED", "message": path}])
        return operation, 1
    operation["success"] = True
    operation["committed"] = True
    operation.pop("saved", None)
    return operation, 0


def fs_path(raw: str | Path) -> Path:
    value = str(raw)
    if value.startswith("res://"):
        return (ROOT / value.removeprefix("res://")).resolve()
    path = Path(value).expanduser()
    if not path.is_absolute():
        return (ROOT / path).resolve()
    return path.resolve()


def load(path: str) -> dict[str, Any]:
    try:
        value = json.loads(fs_path(path).read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {"document": None, "errors": [{"code": "FILE_NOT_FOUND", "message": path}]}
    except json.JSONDecodeError as exc:
        return {"document": None, "errors": [{"code": "JSON_PARSE_ERROR", "message": str(exc), "line": exc.lineno}]}
    if not isinstance(value, dict):
        return {"document": None, "revision_hash": "", "errors": [{"code": "DOCUMENT_NOT_OBJECT", "message": "The document root must be an object."}]}
    return {"document": value, "revision_hash": content_hash(value), "errors": []}


def save(path: str, data: dict[str, Any], expected_revision: str = "") -> dict[str, Any]:
    payload = json.dumps(data, indent="\t", ensure_ascii=False) + "\n"
    return write_source_atomically(path, payload, expected_revision)


def theme(document: dict[str, Any] | None = None) -> dict[str, Any]:
    theme_name = str((document or {}).get("theme", "dark_fantasy"))
    loaded = load_theme_checked(theme_name)
    return loaded.get("theme") or json.loads(THEME_PATH.read_text(encoding="utf-8"))


def merge_dicts(base: dict[str, Any], override: Any) -> dict[str, Any]:
    result = copy.deepcopy(base)
    if not isinstance(override, dict):
        return result
    for key, value in override.items():
        if isinstance(result.get(key), dict) and isinstance(value, dict):
            result[key] = merge_dicts(result[key], value)
        else:
            result[key] = copy.deepcopy(value)
    return result


def resolve(value: Any, tokens: dict[str, Any]) -> Any:
    if not isinstance(value, str) or not value.startswith("$"):
        return value
    current: Any = tokens
    for part in value[1:].split("."):
        if not isinstance(current, dict) or part not in current:
            return None
        current = current[part]
    return current


def walk(node: dict[str, Any], parent: dict[str, Any] | None = None):
    yield node, parent
    for child in node.get("children", []):
        if isinstance(child, dict):
            yield from walk(child, node)


def find(data: dict[str, Any], node_id: str) -> tuple[dict[str, Any] | None, dict[str, Any] | None]:
    for node, parent in walk(data.get("root", {})):
        if str(node.get("id", "")) == node_id:
            return node, parent
    return None, None


def is_whole_number(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) or (
        isinstance(value, float) and not isinstance(value, bool) and math.isfinite(value) and value == math.floor(value)
    )


def validate(data: dict[str, Any]) -> dict[str, Any]:
    diagnostics: list[dict[str, Any]] = []
    ids: set[str] = set()
    names: set[str] = set()

    def add(severity: str, code: str, message: str, node: str = "", recommendation: str = ""):
        diagnostics.append({"severity": severity, "code": code, "message": message, "node": node, "recommendation": recommendation})

    theme_loaded = load_theme_checked(str(data.get("theme", "")))
    for error in theme_loaded.get("errors", []):
        add(error.get("severity", "error"), error["code"], error["message"], error.get("node", ""), error.get("recommendation", ""))
    theme_data = theme_loaded.get("theme") or {}
    overrides = data.get("theme_overrides", {})
    if "theme_overrides" in data and not isinstance(overrides, dict):
        add("error", "THEME_OVERRIDES_INVALID", "theme_overrides must be an object.", "document", "Use theme_overrides: { tokens: {}, styles: {} }.")
        overrides = {}
    if isinstance(overrides, dict):
        if "tokens" in overrides and not isinstance(overrides.get("tokens"), dict):
            add("error", "THEME_OVERRIDES_INVALID", "theme_overrides.tokens must be an object.", "document")
        if "styles" in overrides and not isinstance(overrides.get("styles"), dict):
            add("error", "THEME_OVERRIDES_INVALID", "theme_overrides.styles must be an object.", "document")
    tokens = merge_dicts(theme_data.get("tokens", {}), overrides.get("tokens", {}) if isinstance(overrides, dict) else {})
    metadata_value = data.get("metadata", {})
    if metadata_value is not None and not isinstance(metadata_value, dict):
        add("error", "METADATA_INVALID", "metadata must be an object.", "document")
    elif isinstance(metadata_value, dict):
        for metadata_key in metadata_value:
            diagnostic = validate_authored_metadata_key(str(metadata_key))
            if diagnostic:
                add(diagnostic["severity"], diagnostic["code"], diagnostic["message"], diagnostic.get("node", "document"), diagnostic.get("recommendation", ""))
    components_value = data.get("components", {})
    if "components" in data and not isinstance(components_value, dict):
        add("error", "COMPONENTS_INVALID", "components must be an object.", "document")
    elif isinstance(components_value, dict):
        for component_name, definition in components_value.items():
            if not isinstance(definition, dict):
                add("error", "COMPONENT_INVALID", f"Component '{component_name}' must be an object.", str(component_name))

    def number_value(value: Any, field: str, node_id: str) -> float | None:
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            add("error", "LAYOUT_INVALID", f"{field} must be numeric.", node_id)
            return None
        return float(value)

    def vec2_numeric(values: Any, field: str, node_id: str) -> bool:
        if not isinstance(values, list) or len(values) < 2:
            add("error", "LAYOUT_INVALID", f"{field} must contain two numeric values.", node_id)
            return False
        return number_value(values[0], f"{field}[0]", node_id) is not None and number_value(values[1], f"{field}[1]", node_id) is not None

    for key in data.keys():
        if str(key) not in TOP_LEVEL_KEYS:
            add("error", "UNKNOWN_DOCUMENT_KEY", f"Unknown top-level key '{key}'.", "", "Remove the key or extend the UIForge V1 contract deliberately.")
    schema_version = data.get("schema_version")
    if not is_whole_number(schema_version) or int(schema_version) != SCHEMA_VERSION:
        add("error", "SCHEMA_VERSION_UNSUPPORTED", "Document schema_version must be 1.")
    document_name = str(data.get("name", ""))
    if not document_name:
        add("error", "DOCUMENT_NAME_MISSING", "Document name is required.")
    else:
        diagnostic = document_name_diagnostic(document_name)
        if diagnostic:
            add(diagnostic["severity"], diagnostic["code"], diagnostic["message"], diagnostic["node"], diagnostic.get("recommendation", ""))
    viewport_value = data.get("viewport", {})
    viewport = viewport_value if isinstance(viewport_value, dict) else {}
    if not isinstance(viewport_value, dict) and "viewport" in data:
        add("error", "VIEWPORT_INVALID", "viewport must be an object.", "viewport", "Use {\"width\": 1920, \"height\": 1080}.")
    width = viewport.get("width")
    height = viewport.get("height")
    if not is_whole_number(width) or int(width) <= 0 or not is_whole_number(height) or int(height) <= 0:
        add("error", "VIEWPORT_INVALID", "Viewport width and height must be positive integers.", "viewport")
    root = data.get("root")
    if not isinstance(root, dict):
        add("error", "ROOT_MISSING", "A document must contain a root node.")
        root = {}
    elif not isinstance(root.get("children", []), list) and "children" in root:
        add("error", "CHILDREN_INVALID", "children must be an array.", str(root.get("id", "")))

    def scan(value: Any, node_id: str):
        if isinstance(value, str) and value.startswith("$") and resolve(value, tokens) is None:
            add("error", "TOKEN_NOT_FOUND", f"Token '{value}' does not exist in the active theme.", node_id)
        elif isinstance(value, dict):
            for entry in value.values():
                scan(entry, node_id)
        elif isinstance(value, list):
            for entry in value:
                scan(entry, node_id)

    def scan_resources(value: Any, node_id: str):
        if isinstance(value, str) and value.startswith("res://") and not fs_path(value).exists():
            add("error", "RESOURCE_NOT_FOUND", f"Resource '{value}' was not found.", node_id, "Add the asset or remove the reference.")
        elif isinstance(value, dict):
            for entry in value.values():
                scan_resources(entry, node_id)
        elif isinstance(value, list):
            for entry in value:
                scan_resources(entry, node_id)

    for node, parent in walk(root):
        node_id = str(node.get("id", ""))
        node_type = str(node.get("type", ""))
        if not node_id:
            add("error", "NODE_ID_MISSING", "Every node needs a stable unique id.")
        elif not is_valid_id(node_id):
            diagnostic = id_diagnostic(node_id)
            add(diagnostic["severity"], diagnostic["code"], diagnostic["message"], diagnostic["node"], diagnostic.get("recommendation", ""))
        elif node_id in ids:
            add("error", "DUPLICATE_ID", f"Duplicate node id '{node_id}'.", node_id)
        else:
            ids.add(node_id)
        for key in node.keys():
            if str(key) not in NODE_KEYS:
                add("error", "UNKNOWN_NODE_KEY", f"Unknown node key '{key}'.", node_id, "Remove the key or extend the UIForge V1 contract deliberately.")
        if node_type not in NATIVE_TYPES and node_type not in COMPONENTS and node_type != "ComponentInstance":
            add("error", "UNKNOWN_NODE_TYPE", f"Unknown node type '{node_type}'.", node_id)
        if node_type == "ComponentInstance":
            component_name = str(node.get("component", ""))
            custom_components = data.get("components", {}) if isinstance(data.get("components", {}), dict) else {}
            if component_name not in COMPONENTS and component_name not in custom_components:
                add("error", "UNKNOWN_COMPONENT", f"Unknown component '{component_name}'.", node_id, "Define the component or query capabilities.")
        display_name = str(node.get("name", node_id))
        if display_name in names:
            add("warning", "DUPLICATE_NAME", f"Node name '{display_name}' is duplicated.", node_id)
        names.add(display_name)
        layout = node.get("layout", {})
        if not isinstance(layout, dict):
            add("error", "LAYOUT_INVALID", "layout must be an object.", node_id)
            layout = {}
        else:
            for key in layout.keys():
                if str(key) not in LAYOUT_KEYS:
                    add("error", "UNKNOWN_LAYOUT_KEY", f"Unknown layout key '{key}'.", node_id, "Remove the key or extend the UIForge V1 contract deliberately.")
        position = layout.get("position", []) if isinstance(layout, dict) else []
        size = layout.get("size", []) if isinstance(layout, dict) else []
        if "position" in layout and not vec2_numeric(position, "layout.position", node_id):
            position = []
        if "size" in layout and not vec2_numeric(size, "layout.size", node_id):
            size = []
        if len(position) >= 2 and len(size) >= 2:
            px = number_value(position[0], "layout.position[0]", node_id)
            py = number_value(position[1], "layout.position[1]", node_id)
            sx = number_value(size[0], "layout.size[0]", node_id)
            sy = number_value(size[1], "layout.size[1]", node_id)
            if None not in (px, py, sx, sy) and (px + sx > float(viewport.get("width", 1920)) + 2 or py + sy > float(viewport.get("height", 1080)) + 2):
                add("warning", "LAYOUT_OUTSIDE_VIEWPORT", "Node extends beyond the design viewport.", node_id)
        if node_type in {"Button", "TextureButton", "CheckBox", "CheckButton", "Slider", "HSlider", "VSlider", "SpinBox", "LineEdit", "OptionButton", "MenuButton", "LinkButton", "PrimaryButton", "SecondaryButton", "IconButton", "TabButton", "ItemSlot", "SidebarEntry"} and len(size) >= 2:
            sx = number_value(size[0], "layout.size[0]", node_id)
            sy = number_value(size[1], "layout.size[1]", node_id)
            if sx is not None and sy is not None and (sx < 32 or sy < 32):
                add("warning", "SMALL_HIT_TARGET", "Interactive node is smaller than the recommended 32px hit target.", node_id)
        properties = node.get("properties", {})
        if not isinstance(properties, dict):
            add("error", "PROPERTIES_INVALID", "properties must be an object.", node_id)
            properties = {}
        supported_properties = {"text", "title", "label", "count", "show_label", "columns", "slot_size", "gap", "value", "min_value", "max_value", "step", "placeholder", "max_length", "tick_count", "show_percentage", "texture_region", "texture", "icon", "font", "material", "theme", "font_size", "color", "opacity", "modulate", "self_modulate", "outline_size", "font_outline_color", "font_shadow_color", "horizontal_alignment", "vertical_alignment", "alignment", "autowrap", "clip_text", "text_overrun_behavior", "bbcode_enabled", "fit_content", "scroll_active", "disabled", "editable", "focus_mode", "tooltip", "toggle_mode", "button_pressed", "flat", "expand_icon", "icon_alignment", "secret", "clear_button_enabled", "caret_blink", "selecting_enabled", "context_menu_enabled", "select_all_on_focus", "virtual_keyboard_enabled", "ticks_on_borders", "allow_greater", "allow_lesser", "horizontal_scroll_mode", "vertical_scroll_mode", "separation", "visible", "clip_contents", "show_behind_parent", "top_level", "z_as_relative", "y_sort_enabled", "use_parent_material", "clip_children", "texture_filter", "texture_repeat", "light_mask", "visibility_layer", "theme_type_variation", "accessibility_name", "accessibility_description", "auto_translate", "layout_direction", "expand_mode", "stretch_mode", "ignore_texture_size", "flip_h", "flip_v", "patch_margin_left", "patch_margin_top", "patch_margin_right", "patch_margin_bottom", "godot_overrides"}
        if "texture_region" in properties:
            region = properties["texture_region"]
            valid = isinstance(region, list) and len(region) == 4 and all(isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) for v in region)
            valid = valid and region[0] >= 0 and region[1] >= 0 and region[2] > 0 and region[3] > 0
            if not valid or not str(properties.get("texture", "")).startswith("res://") or native(node.get("type", "")) not in {"TextureRect", "TextureButton", "NinePatchRect"}:
                add("error", "TEXTURE_REGION_INVALID", "Texture region needs a texture control, resource path, and [x, y, positive width, positive height] in pixels.", node_id)
        for property_name in properties:
            if str(property_name) not in supported_properties:
                add("error", "UNSUPPORTED_PROPERTY", f"Property '{property_name}' is not part of the semantic document contract.", node_id, "Use a supported property or properties.godot_overrides.")
        for key, value in properties.items():
            if (key == "color" or key.endswith("_color") or key == "background") and isinstance(value, str) and not value.startswith("$"):
                add("warning", "HARDCODED_STYLE_VALUE", f"Style value '{key}' is hardcoded; prefer a theme token.", node_id)
        scan(node.get("style", {}), node_id)
        scan(properties, node_id)
        scan(node.get("states", {}), node_id)
        scan(node.get("effects", {}), node_id)
        scan(node.get("decorations", {}), node_id)
        transitions = node.get("transitions", {})
        if transitions is not None and not isinstance(transitions, dict):
            add("error", "TRANSITIONS_INVALID", "transitions must be an object.", node_id)
        elif isinstance(transitions, dict):
            for transition_name, transition in transitions.items():
                if not isinstance(transition, dict):
                    add("error", "TRANSITION_INVALID", f"Transition '{transition_name}' must be an object.", node_id)
                    continue
                if str(transition.get("preset", "")) not in {"fade", "scale", "slide", "hover", "button_press", "panel_reveal"}:
                    add("error", "TRANSITION_PRESET_UNKNOWN", f"Unknown transition preset '{transition.get('preset', '')}'.", node_id)
                duration_raw = transition.get("duration", 0.18)
                if isinstance(duration_raw, bool) or not isinstance(duration_raw, (int, float)):
                    add("error", "TRANSITION_DURATION_INVALID", "Transition duration must be positive.", node_id)
                elif float(duration_raw) <= 0:
                    add("error", "TRANSITION_DURATION_INVALID", "Transition duration must be positive.", node_id)
        effects = node.get("effects", {})
        if not isinstance(effects, (dict, list, str)):
            add("error", "EFFECTS_INVALID", "effects must be an effect name, object, or array.", node_id)
        if "godot_overrides" in properties:
            overrides_value = properties.get("godot_overrides")
            if not isinstance(overrides_value, dict):
                add("error", "GODOT_OVERRIDES_INVALID", "properties.godot_overrides must be an object.", node_id)
            else:
                for property_name in overrides_value:
                    diagnostic = validate_godot_override(str(property_name))
                    if diagnostic:
                        add(diagnostic["severity"], diagnostic["code"], diagnostic["message"], node_id, diagnostic.get("recommendation", ""))
        if "metadata" in node:
            metadata_node = node.get("metadata")
            if not isinstance(metadata_node, dict):
                add("error", "METADATA_INVALID", "metadata must be an object.", node_id)
            else:
                for metadata_key in metadata_node:
                    diagnostic = validate_authored_metadata_key(str(metadata_key))
                    if diagnostic:
                        add(diagnostic["severity"], diagnostic["code"], diagnostic["message"], node_id, diagnostic.get("recommendation", ""))
        scan_resources(properties.get("godot_overrides", {}) if isinstance(properties, dict) else {}, node_id)
        scan_resources(node.get("effects", {}), node_id)
        scan_resources(node.get("decorations", {}), node_id)
        if "columns" in properties and (not is_whole_number(properties["columns"]) or int(properties["columns"]) < 1):
            add("error", "GRID_COLUMNS_INVALID", "Grid columns must be a positive integer.", node_id)
        if "action" in node and not isinstance(node.get("action"), str):
            add("error", "ACTION_INVALID", "action must be a string identifier.", node_id)
        if "binding" in node and not isinstance(node.get("binding"), str):
            add("error", "BINDING_INVALID", "binding must be a string identifier.", node_id)
        children_value = node.get("children", [])
        if "children" in node and not isinstance(children_value, list):
            add("error", "CHILDREN_INVALID", "children must be an array.", node_id)
        if parent and parent.get("type") in {"Label", "RichText", "Button", "TextureButton", "CheckBox", "CheckButton", "Slider", "HSlider", "VSlider", "SpinBox", "ProgressBar", "LineEdit", "TextEdit", "OptionButton", "MenuButton", "LinkButton", "ColorRect", "NinePatchRect", "Separator", "Spacer"}:
            add("error", "INVALID_PARENT_RELATIONSHIP", f"Node '{node_id}' is parented under leaf control '{parent.get('id', '')}'.", node_id)
    scan_resources(data.get("theme_overrides", {}), "document")
    error_count = sum(1 for item in diagnostics if item["severity"] == "error")
    warning_count = len(diagnostics) - error_count
    return {"success": error_count == 0, "errors": error_count, "warnings": warning_count, "diagnostics": diagnostics}


def quote(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def color(value: Any, fallback: str = "#151a22", tokens: dict[str, Any] | None = None) -> str:
    active_tokens = tokens if tokens is not None else theme().get("tokens", {})
    value = value if not isinstance(value, str) or not value.startswith("$") else resolve(value, active_tokens)
    if not isinstance(value, str):
        return "Color(0.08, 0.10, 0.13, 1.0)"
    raw = value.removeprefix("#")
    if len(raw) == 6:
        raw += "ff"
    try:
        channels = [int(raw[index:index + 2], 16) / 255 for index in (0, 2, 4, 6)]
        return "Color(%0.6f, %0.6f, %0.6f, %0.6f)" % tuple(channels)
    except ValueError:
        return color(fallback, tokens=active_tokens)


def native(node_type: str) -> str:
    return COMPONENTS.get(node_type, (NATIVE_MAP.get(node_type, node_type), "panel"))[0]


def style_name(node_type: str) -> str:
    if node_type in ("CheckBox", "QuestEntry", "SidebarEntry"):
        return "checkbox" if node_type == "CheckBox" else "list_row"
    return COMPONENTS.get(node_type, (node_type, "panel"))[1]


def merge_node(base: dict[str, Any], override: dict[str, Any]) -> dict[str, Any]:
    result = copy.deepcopy(base)
    for key, value in override.items():
        if key in {"layout", "properties"} and isinstance(result.get(key), dict) and isinstance(value, dict):
            result[key] = {**result[key], **copy.deepcopy(value)}
        else:
            result[key] = copy.deepcopy(value)
    return result


def materialize(node: dict[str, Any], custom: dict[str, Any]) -> dict[str, Any]:
    result = copy.deepcopy(node)
    if result.get("type") != "ComponentInstance":
        return result
    component_name = str(result.get("component", ""))
    definition: dict[str, Any] = {}
    if component_name in custom:
        custom_definition = custom[component_name]
        if not isinstance(custom_definition, dict):
            return result
        base_name = str(custom_definition.get("base", ""))
        if base_name:
            definition = materialize({"type": "ComponentInstance", "component": base_name}, custom)
        if isinstance(custom_definition, dict):
            definition = merge_node(definition, custom_definition)
    elif component_name in COMPONENTS:
        definition = {"type": component_name}
    base_definition = definition.get("node", definition)
    base_type = str(base_definition.get("type", component_name)) if isinstance(base_definition, dict) else component_name
    inferred_native = definition.get("native_type") or (COMPONENTS.get(base_type, (base_type, "panel"))[0])
    result = merge_node(base_definition, result)
    if isinstance(result.get("overrides"), dict):
        result = merge_node(result, result["overrides"])
    result.pop("overrides", None)
    native_type = result.get("native_type") or inferred_native
    result["type"] = str(native_type)
    return result


def decoration_children(node: dict[str, Any]) -> list[dict[str, Any]]:
    raw = node.get("decorations", {})
    result: list[dict[str, Any]] = []
    if isinstance(raw, dict):
        entries = [(str(name), value) for name, value in sorted(raw.items()) if isinstance(value, dict)]
    elif isinstance(raw, list):
        entries = [(str(value.get("id", f"decoration_{index + 1:02d}")), value) for index, value in enumerate(raw) if isinstance(value, dict)]
    else:
        entries = []
    parent_id = str(node.get("id", "node"))
    for name, value in entries:
        child = copy.deepcopy(value)
        child["id"] = str(child.get("id", f"{parent_id}_{name.lower().replace(' ', '_')}"))
        child["type"] = str(child.get("type", "Texture"))
        if "layout" not in child:
            child["layout"] = {"position": child.get("position", [0, 0]), "size": child.get("size", [64, 64])}
        if "properties" not in child:
            child["properties"] = {"texture": child["texture"]} if "texture" in child else {}
        result.append(child)
    return result


def scene_value(value: Any) -> str:
    if isinstance(value, bool):
        return str(value).lower()
    if isinstance(value, (int, float)):
        return f"{float(value):.4f}"
    return quote(str(value))


def godot_literal(property_name: str, value: Any, external_resource, tokens: dict[str, Any] | None = None) -> str:
    if isinstance(value, dict):
        resource_path = str(value.get("$resource", value.get("resource", "")))
        if resource_path.startswith("res://"):
            resource_type = str(value.get("type", "Texture2D"))
            return f'ExtResource("{external_resource(resource_path, resource_type)}")'
        node_path = str(value.get("$node_path", ""))
        if node_path:
            return f"NodePath({quote(node_path)})"
        return "{" + ", ".join(f"{quote(str(key))}: {godot_literal(property_name, item, external_resource, tokens)}" for key, item in value.items()) + "}"
    if isinstance(value, str):
        if value.startswith("res://") and any(token in property_name.lower() for token in ("texture", "icon", "font", "material", "theme", "shader", "label_settings", "syntax_highlighter")):
            lowered = property_name.lower()
            resource_type = "FontFile" if "font" in lowered else "Theme" if "theme" in lowered else "Material" if "material" in lowered or "shader" in lowered else "Texture2D"
            return f'ExtResource("{external_resource(value, resource_type)}")'
        if "color" in property_name.lower():
            return color(value, "#ffffff", tokens)
        return quote(value)
    if isinstance(value, list):
        if len(value) in (2, 3, 4) and all(isinstance(item, (int, float)) and not isinstance(item, bool) for item in value):
            return "Vector%d(%s)" % (len(value), ", ".join(f"{float(item):.4f}" for item in value))
        return "[" + ", ".join(godot_literal(property_name, item, external_resource, tokens) for item in value) + "]"
    return scene_value(value)


def build_tscn(data: dict[str, Any], source: str) -> str:
    theme_data = theme(data)
    overrides = data.get("theme_overrides", {})
    if isinstance(overrides, dict):
        theme_data = merge_dicts(theme_data, overrides)
    tokens = theme_data.get("tokens", {})
    styles = theme_data.get("styles", {})
    subresources: list[str] = []
    ext_resources: dict[str, dict[str, str]] = {}
    emitted_styles: dict[str, str] = {}
    custom_components = data.get("components", {}) if isinstance(data.get("components", {}), dict) else {}
    identity = source_identity(source)
    revision = content_hash(data)

    def external_resource(path: str, resource_type: str) -> str:
        cache_key = f"{path}|{resource_type}"
        if cache_key in ext_resources:
            return ext_resources[cache_key]["id"]
        resource_id = f"{resource_type}_{len(ext_resources) + 1}"
        ext_resources[cache_key] = {"id": resource_id, "type": resource_type, "path": path}
        return resource_id

    def make_style(node_id: str, state: str, node_style: Any) -> str:
        cache = f"{node_id}|{state}|{json.dumps(node_style, sort_keys=True)}"
        if cache in emitted_styles:
            return emitted_styles[cache]
        chosen = styles.get(node_style if isinstance(node_style, str) else "panel", styles.get("panel", {})).copy()
        if isinstance(node_style, dict):
            chosen.update(node_style)
        state_key = f"{state}_background"
        if state_key in chosen:
            chosen["background"] = chosen[state_key]
        safe = resource_id_part(node_id)
        resource_id = f"StyleBox_{safe}_{resource_id_part(state)}"
        texture_path = chosen.get(f"{state}_texture", chosen.get("texture"))
        if isinstance(texture_path, str) and texture_path.startswith("res://"):
            texture_resource = external_resource(texture_path, "Texture2D")
            block = [f'[sub_resource type="StyleBoxTexture" id="{resource_id}"]', f'texture = ExtResource("{texture_resource}")']
            for margin in ("left", "top", "right", "bottom"):
                key = f"texture_margin_{margin}"
                if key in chosen:
                    block.append(f"{key} = {float(chosen[key]):.4f}")
            if f"{state}_modulate" in chosen:
                block.append(f"modulate_color = {color(chosen[f'{state}_modulate'], '#ffffff', tokens)}")
            for side, value in chosen.get("content_margin", {}).items():
                block.append(f"content_margin_{side} = {float(resolve(value, tokens)):.4f}")
            subresources.append("\n".join(block))
            emitted_styles[cache] = resource_id
            return resource_id
        block = [f'[sub_resource type="StyleBoxFlat" id="{resource_id}"]', f"bg_color = {color(chosen.get('background', '#151a22'), tokens=tokens)}", "border_width_left = 1", "border_width_top = 1", "border_width_right = 1", "border_width_bottom = 1", f"border_color = {color(chosen.get('border', '#645039'), tokens=tokens)}"]
        radius = chosen.get("radius", 4)
        radius = resolve(radius, tokens) if isinstance(radius, str) else radius
        block.extend([f"corner_radius_top_left = {int(radius)}", f"corner_radius_top_right = {int(radius)}", f"corner_radius_bottom_right = {int(radius)}", f"corner_radius_bottom_left = {int(radius)}"])
        subresources.append("\n".join(block))
        emitted_styles[cache] = resource_id
        return resource_id

    header = provenance_header(identity, revision) + [f"; Source: {source}"]
    lines: list[str] = header + [f"[gd_scene load_steps=1 format=3]", ""]

    def emit(node: dict[str, Any], parent: str, root: bool = False):
        node = materialize(node, custom_components)
        node_type = str(node.get("type", "Control"))
        native_type = native(node_type)
        node_id = str(node.get("id", "Node"))
        node_name = re.sub(r"[^A-Za-z0-9_]", "_", node_id) or "Node"
        path = node_name if parent == "." else f"{parent}/{node_name}"
        if root:
            lines.append(f'[node name="{node_name}" type="{native_type}"]')
        else:
            lines.append(f'[node name="{node_name}" type="{native_type}" parent="{parent}"]')
        lines.extend([f"metadata/uiforge_id = {quote(node_id)}", f"metadata/uiforge_type = {quote(node_type)}", "metadata/uiforge_generated = true"])
        if "action" in node:
            lines.append(f"metadata/uiforge_action = {quote(str(node['action']))}")
        if "binding" in node:
            lines.append(f"metadata/uiforge_binding = {quote(str(node['binding']))}")
        if "transitions" in node:
            lines.append(f"metadata/uiforge_transitions = {quote(json.dumps(node.get('transitions', {}), separators=(',', ':')))}")
        if "effects" in node:
            lines.append(f"metadata/uiforge_effects = {quote(json.dumps(node.get('effects', {}), separators=(',', ':')))}")
        if isinstance(node.get("metadata"), dict):
            for metadata_key, metadata_value in node["metadata"].items():
                if validate_authored_metadata_key(str(metadata_key)):
                    continue
                lines.append(f"metadata/{metadata_key} = {scene_value(metadata_value)}")
        layout = node.get("layout", {})
        position = layout.get("position", []) if isinstance(layout, dict) else []
        size = layout.get("size", []) if isinstance(layout, dict) else []
        if len(position) >= 2:
            lines.extend([f"offset_left = {float(position[0]):.4f}", f"offset_top = {float(position[1]):.4f}"])
        if len(size) >= 2:
            x = float(position[0]) if len(position) >= 2 else 0
            y = float(position[1]) if len(position) >= 2 else 0
            lines.extend([f"offset_right = {x + float(size[0]):.4f}", f"offset_bottom = {y + float(size[1]):.4f}"])
        if isinstance(layout, dict) and len(layout.get("min_size", [])) >= 2:
            minimum = layout["min_size"]
            lines.append(f"custom_minimum_size = Vector2({float(minimum[0]):.4f}, {float(minimum[1]):.4f})")
        if isinstance(layout, dict):
            if layout.get("anchors_preset") == "full_rect":
                lines.extend(["anchor_right = 1.0", "anchor_bottom = 1.0", "grow_horizontal = 2", "grow_vertical = 2"])
            for side, value in layout.get("offsets", {}).items():
                lines.append(f"offset_{side} = {float(value):.4f}")
            for key in ("grow_horizontal", "grow_vertical", "size_flags_horizontal", "size_flags_vertical", "z_index", "mouse_filter"):
                if key in layout:
                    lines.append(f"{key} = {int(layout[key])}")
            if len(layout.get("pivot", [])) >= 2:
                lines.append(f"pivot_offset = Vector2({float(layout['pivot'][0]):.4f}, {float(layout['pivot'][1]):.4f})")
            if "rotation_degrees" in layout:
                lines.append(f"rotation = {float(layout['rotation_degrees']) * 3.141592653589793 / 180.0:.4f}")
            if len(layout.get("scale", [])) >= 2:
                lines.append(f"scale = Vector2({float(layout['scale'][0]):.4f}, {float(layout['scale'][1]):.4f})")
        properties = node.get("properties", {}) if isinstance(node.get("properties", {}), dict) else {}
        text = properties.get("text", properties.get("title", ""))
        if text and native_type in {"Label", "RichTextLabel", "Button", "CheckBox", "CheckButton", "MenuButton", "LinkButton", "LineEdit", "TextEdit"}:
            lines.append(f"text = {quote(str(text))}")
        if native_type == "LineEdit" and "placeholder" in properties:
            lines.append(f"placeholder_text = {quote(str(properties['placeholder']))}")
        if native_type == "GridContainer" and "columns" in properties:
            lines.append(f"columns = {int(properties['columns'])}")
        if native_type == "GridContainer" and "gap" in properties:
            gap = resolve(properties["gap"], tokens)
            if isinstance(gap, (int, float)):
                lines.append(f"theme_override_constants/h_separation = {int(gap)}")
                lines.append(f"theme_override_constants/v_separation = {int(gap)}")
        for key in ("value", "min_value", "max_value", "step"):
            if key in properties:
                lines.append(f"{key} = {scene_value(properties[key])}")
        for key in ("visible", "clip_contents", "show_behind_parent", "top_level", "z_as_relative", "y_sort_enabled", "use_parent_material", "editable", "disabled", "toggle_mode", "button_pressed", "secret", "clear_button_enabled", "selecting_enabled", "flip_h", "flip_v", "show_percentage"):
            if key in properties:
                lines.append(f"{key} = {str(bool(properties[key])).lower()}")
        if "tooltip" in properties:
            lines.append(f"tooltip_text = {quote(str(properties['tooltip']))}")
        if "focus_mode" in properties:
            lines.append(f"focus_mode = {int(properties['focus_mode'])}")
        for key in ("max_length", "tick_count"):
            if key in properties:
                lines.append(f"{key} = {int(properties[key])}")
        if "alignment" in properties:
            alignment = properties["alignment"] if isinstance(properties["alignment"], (int, float)) else 0
            lines.append(f"alignment = {int(alignment)}")
        if "color" in properties and native_type == "ColorRect":
            lines.append(f"color = {color(properties['color'], '#ffffff', tokens)}")
        for key in ("modulate", "self_modulate"):
            if key in properties:
                lines.append(f"{key} = {color(properties[key], '#ffffff', tokens)}")
        for key in ("expand_mode", "stretch_mode"):
            if key in properties:
                lines.append(f"{key} = {int(properties[key])}")
        if "texture" in properties and isinstance(properties["texture"], str) and properties["texture"].startswith("res://"):
            resource_id = external_resource(properties["texture"], "Texture2D")
            target_property = "texture_normal" if native_type == "TextureButton" else "texture"
            if "texture_region" in properties:
                region = properties["texture_region"]
                atlas_id = f"AtlasTexture_{resource_id_part(node_id)}"
                rect = ", ".join(f"{float(v):.4f}" for v in region)
                subresources.append(f'[sub_resource type="AtlasTexture" id="{atlas_id}"]\natlas = ExtResource("{resource_id}")\nregion = Rect2({rect})\nfilter_clip = true')
                lines.append(f'{target_property} = SubResource("{atlas_id}")')
            else:
                lines.append(f'{target_property} = ExtResource("{resource_id}")')
        if "icon" in properties and isinstance(properties["icon"], str) and properties["icon"].startswith("res://") and native_type in {"Button", "CheckBox", "TextureButton", "LinkButton"}:
            resource_id = external_resource(properties["icon"], "Texture2D")
            lines.append(f'icon = ExtResource("{resource_id}")')
        font_role = "heading" if properties.get("font_size") in ("$font_size.title", "$font_size.heading") else "default"
        font_path = resolve(properties.get("font", theme_data.get("fonts", {}).get(font_role, "")), tokens)
        if native_type in {"Label", "RichTextLabel", "Button", "LineEdit", "CheckBox", "CheckButton", "OptionButton"} and isinstance(font_path, str) and font_path.startswith("res://"):
            resource_id = external_resource(font_path, "FontFile")
            font_key = "normal_font" if native_type == "RichTextLabel" else "font"
            lines.append(f'theme_override_fonts/{font_key} = ExtResource("{resource_id}")')
        if "material" in properties and isinstance(properties["material"], str) and properties["material"].startswith("res://"):
            resource_id = external_resource(properties["material"], "Material")
            lines.append(f'material = ExtResource("{resource_id}")')
        for key in ("font_size", "outline_size"):
            if key in properties:
                value = resolve(properties[key], tokens)
                if isinstance(value, (int, float)):
                    lines.append(f"theme_override_font_sizes/{key} = {int(value)}")
        for key in ("color", "font_color"):
            if key in properties:
                if key == "color" and native_type == "ColorRect":
                    continue
                lines.append(f"theme_override_colors/{key} = {color(properties[key], '#ffffff', tokens)}")
        raw_overrides = properties.get("godot_overrides", {})
        native_skin = theme_data.get("native_controls", {}).get(native_type, {})
        for key, style_ref in native_skin.get("styles", {}).items():
            resource_id = make_style(node_id, key, style_ref)
            lines.append(f'theme_override_styles/{key} = SubResource("{resource_id}")')
        for key, icon_ref in native_skin.get("icons", {}).items():
            resource_id = external_resource(icon_ref, "Texture2D")
            lines.append(f'theme_override_icons/{key} = ExtResource("{resource_id}")')
        typed_properties = {"text", "placeholder_text", "visible", "clip_contents", "show_behind_parent", "top_level", "z_as_relative", "y_sort_enabled", "use_parent_material", "clip_children", "light_mask", "visibility_layer", "texture_filter", "texture_repeat", "layout_direction", "mouse_default_cursor_shape", "tooltip_text", "focus_mode", "value", "min_value", "max_value", "step", "columns", "editable", "disabled", "autowrap_mode", "horizontal_alignment", "vertical_alignment", "show_percentage", "bbcode_enabled", "fit_content", "scroll_active", "toggle_mode", "button_pressed", "secret", "clear_button_enabled", "caret_blink", "selecting_enabled", "ticks_on_borders", "allow_greater", "allow_lesser", "ignore_texture_size", "flip_h", "flip_v", "max_length", "tick_count", "horizontal_scroll_mode", "vertical_scroll_mode", "alignment", "clip_text", "flat", "expand_icon", "icon_alignment", "text_overrun_behavior", "theme_type_variation", "accessibility_name", "accessibility_description", "auto_translate", "separation", "modulate", "self_modulate", "material", "theme", "icon", "texture", "expand_mode", "stretch_mode", "patch_margin_left", "patch_margin_top", "patch_margin_right", "patch_margin_bottom", "font", "font_size", "outline_size", "color", "font_color", "font_outline_color", "font_shadow_color"}
        if isinstance(raw_overrides, dict):
            for property_name, raw_value in raw_overrides.items():
                property_name = str(property_name)
                if property_name in typed_properties or not property_name or "\n" in property_name or "\r" in property_name:
                    continue
                lines.append(f"{property_name} = {godot_literal(property_name, raw_value, external_resource, tokens)}")
        supported_styles = {"Panel", "Button", "TextureButton", "CheckBox", "LineEdit", "ProgressBar", "TabBar", "ScrollContainer"}
        if native_type in supported_styles:
            style = node.get("style", style_name(node_type))
            style_id = make_style(node_id, "normal", style)
            property_name = "normal" if native_type in {"Button", "TextureButton", "CheckBox", "LineEdit"} else "panel"
            if native_type == "ProgressBar":
                property_name = "background"
            lines.append(f'theme_override_styles/{property_name} = SubResource("{style_id}")')
            if native_type == "ProgressBar":
                fill_style = node.get("fill_style", FILL_STYLES.get(node_type, "button_primary"))
                fill_id = make_style(node_id, "fill", fill_style)
                lines.append(f'theme_override_styles/fill = SubResource("{fill_id}")')
            states = node.get("states", {}) if isinstance(node.get("states", {}), dict) else {}
            for state in ("hover", "pressed", "focus", "disabled", "selected"):
                base = styles.get(style, {}).copy() if isinstance(style, str) else dict(style)
                if (state in states or f"{state}_texture" in base or f"{state}_background" in base) and native_type in {"Button", "TextureButton", "CheckBox", "LineEdit"}:
                    base.update(states.get(state, {}))
                    state_id = make_style(node_id, state, base)
                    output_state = "pressed" if state == "selected" else state
                    if native_type != "LineEdit" or state in {"hover", "focus", "disabled"}:
                        lines.append(f'theme_override_styles/{output_state} = SubResource("{state_id}")')
        lines.append("")
        children = list(node.get("children", [])) if isinstance(node.get("children", []), list) else []
        if node_type == "ItemGrid" and not children:
            mock = node.get("mock_data", {}) if isinstance(node.get("mock_data", {}), dict) else {}
            count = int(mock.get("item_count", 0))
            occupied = int(mock.get("occupied_slots", count))
            properties = node.get("properties", {}) if isinstance(node.get("properties", {}), dict) else {}
            slot_size = resolve(properties.get("slot_size", "$slot_size.md"), tokens)
            slot_size = int(slot_size) if isinstance(slot_size, (int, float)) else 54
            for index in range(count):
                slot_properties = {"label": f"Item {index + 1:02d}", "count": index + 1} if index < occupied else {}
                child = {"id": f"{node_id}_slot_{index + 1:02d}", "type": "ItemSlot", "layout": {"min_size": [slot_size, slot_size]}, "properties": slot_properties}
                children.append(child)
        children.extend(decoration_children(node))
        visual = styles.get(style_name(node_type), {}).copy()
        if isinstance(node.get("style"), str):
            visual = styles.get(node["style"], {}).copy()
        elif isinstance(node.get("style"), dict):
            visual.update(node["style"])
        if native_type == "Panel" and visual.get("surface_texture"):
            inset = visual.get("surface_inset", 10)
            children.insert(0, {"id": f"{node_id}__surface", "type": "Texture", "layout": {"anchors_preset": "full_rect", "offsets": {"left": inset, "top": inset, "right": -inset, "bottom": -inset}, "mouse_filter": 2}, "properties": {"texture": visual["surface_texture"], "expand_mode": 1, "stretch_mode": 6, "self_modulate": visual.get("surface_tint", "#ffffff80")}})
        for child in children:
            if isinstance(child, dict):
                emit(child, path)

    emit(data["root"], ".", True)
    load_steps = 1 + len(subresources) + len(ext_resources)
    gd_scene_index = len(header)
    lines[gd_scene_index] = f"[gd_scene load_steps={load_steps} format=3]"
    external_lines = [
        f'[ext_resource type="{entry["type"]}" path={quote(entry["path"])} id="{entry["id"]}"]'
        for entry in ext_resources.values()
    ]
    resource_blocks = external_lines + ([""] if external_lines else []) + sum(([block, ""] for block in subresources), [])
    return "\n".join(lines[: gd_scene_index + 2] + resource_blocks + lines[gd_scene_index + 2 :]) + "\n"


def tree(node: dict[str, Any]) -> dict[str, Any]:
    return {"id": node.get("id", ""), "type": node.get("type", "Control"), "name": node.get("name", node.get("id", "")), "children": [tree(child) for child in node.get("children", []) if isinstance(child, dict)]}


def parse_value(raw: str) -> Any:
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return raw


def set_path(node: dict[str, Any], path: str, value: Any) -> bool:
    bits = path.split(".")
    cursor: dict[str, Any] = node
    for bit in bits[:-1]:
        if not isinstance(cursor.get(bit), dict):
            cursor[bit] = {}
        cursor = cursor[bit]
    cursor[bits[-1]] = value
    return True


def get_path(node: dict[str, Any], path: str) -> Any:
    cursor: Any = node
    if not path:
        return copy.deepcopy(node)
    for bit in path.split("."):
        if not isinstance(cursor, dict) or bit not in cursor:
            return None
        cursor = cursor[bit]
    return cursor


def template_catalog() -> dict[str, Any]:
    return json.loads((ROOT / "addons/uiforge/components/templates.json").read_text(encoding="utf-8"))


def capabilities() -> dict[str, Any]:
    return {"schema_version": 1, "templates": template_catalog(), "supported_node_types": sorted(NATIVE_TYPES | set(COMPONENTS)), "components": sorted(COMPONENTS), "states": ["normal", "hover", "pressed", "focused", "disabled", "selected"], "viewport_presets": [{"width": w, "height": h} for w, h in [(1280, 720), (1600, 900), (1920, 1080), (2560, 1440), (3840, 2160)]], "themes": ["dark_fantasy"], "properties": PROPERTY_GROUPS, "property_schemas": capability_property_schemas(), "native_properties": capability_native_properties(), "operations": ["get", "set", "add", "delete", "move", "duplicate", "validate", "build", "render", "inspect", "new"]}


def add_child(data: dict[str, Any], parent_id: str, node: dict[str, Any], index: int = -1) -> bool:
    parent, _ = find(data, parent_id)
    if parent is None:
        return False
    children = parent.setdefault("children", [])
    if not isinstance(children, list):
        return False
    if index < 0 or index >= len(children):
        children.append(node)
    else:
        children.insert(index, node)
    return True


def delete_node(data: dict[str, Any], node_id: str) -> dict[str, Any] | None:
    root = data.get("root", {})
    if isinstance(root, dict) and str(root.get("id", "")) == node_id:
        return None
    target, parent = find(data, node_id)
    if target is None or parent is None:
        return None
    siblings = parent.get("children", [])
    if not isinstance(siblings, list):
        return None
    siblings.remove(target)
    return target


def move_node(data: dict[str, Any], node_id: str, parent_id: str, index: int = -1) -> bool:
    moving, _ = find(data, node_id)
    if moving is None or node_id == parent_id or contains_id(moving, parent_id):
        return False
    target, old_parent = find(data, node_id)
    if target is None or old_parent is None:
        return False
    siblings = old_parent.get("children", [])
    if not isinstance(siblings, list):
        return False
    old_index = siblings.index(target)
    removed = delete_node(data, node_id)
    if removed is None:
        return False
    if not add_child(data, parent_id, removed, index):
        siblings.insert(old_index, removed)
        return False
    return True


def duplicate_node(data: dict[str, Any], node_id: str, new_id: str) -> dict[str, Any] | None:
    original, parent = find(data, node_id)
    if original is None or parent is None:
        return None
    duplicate = copy.deepcopy(original)
    remap_ids(duplicate, new_id)
    siblings = parent.get("children", [])
    if not isinstance(siblings, list):
        return None
    siblings.insert(siblings.index(original) + 1, duplicate)
    return duplicate


def operation_set(data: dict[str, Any], node_id: str, property_path: str, raw_value: str) -> dict[str, Any]:
    node, _ = find(data, node_id)
    if node is None:
        return {"success": False, "error": {"code": "NODE_NOT_FOUND", "node": node_id}}
    value = parse_value(raw_value)
    if not set_path(node, property_path, value):
        return {"success": False, "error": {"code": "SET_FAILED", "message": "Node or property path not found.", "node": node_id}}
    return {"success": True, "id": node_id, "property": property_path, "value": value}


def operation_add(data: dict[str, Any], parent_id: str, raw_node: str) -> dict[str, Any]:
    value = parse_value(raw_node)
    if not isinstance(value, dict):
        return {"success": False, "error": {"code": "NODE_JSON_INVALID", "message": "The new node must be a JSON object."}}
    node_id = str(value.get("id", ""))
    diagnostic = id_diagnostic(node_id)
    if diagnostic:
        return {"success": False, "error": diagnostic}
    if find(data, node_id)[0] is not None:
        return {"success": False, "error": {"code": "DUPLICATE_ID", "message": f"Node id '{node_id}' already exists.", "node": node_id}}
    if not add_child(data, parent_id, value):
        return {"success": False, "error": {"code": "ADD_FAILED", "parent": parent_id}}
    return {"success": True, "node": value, "parent": parent_id}


def operation_delete(data: dict[str, Any], node_id: str) -> dict[str, Any]:
    removed = delete_node(data, node_id)
    if removed is None:
        return {"success": False, "error": {"code": "DELETE_FAILED", "node": node_id}}
    return {"success": True, "deleted": removed}


def operation_move(data: dict[str, Any], node_id: str, parent_id: str, index: int = -1) -> dict[str, Any]:
    if not move_node(data, node_id, parent_id, index):
        return {"success": False, "error": {"code": "MOVE_FAILED", "node": node_id, "parent": parent_id}}
    return {"success": True, "node": node_id, "parent": parent_id, "index": index}


def operation_duplicate(data: dict[str, Any], node_id: str, new_id: str) -> dict[str, Any]:
    diagnostic = id_diagnostic(new_id, node_id)
    if diagnostic:
        return {"success": False, "error": diagnostic}
    if find(data, new_id)[0] is not None:
        return {"success": False, "error": {"code": "DUPLICATE_ID", "message": f"Node id '{new_id}' already exists.", "node": new_id}}
    duplicate = duplicate_node(data, node_id, new_id)
    if duplicate is None:
        return {"success": False, "error": {"code": "DUPLICATE_FAILED", "node": node_id}}
    return {"success": True, "node": duplicate}


def parse_cli_flags(argv: list[str], start_index: int) -> tuple[dict[str, bool], list[str], int]:
    flags = {"force": False, "allow_outside_project": False, "allow_unsafe": False}
    unknown: list[str] = []
    index = start_index
    while index < len(argv):
        token = argv[index]
        if token == "--force":
            flags["force"] = True
            index += 1
        elif token == "--allow-outside-project":
            flags["allow_outside_project"] = True
            index += 1
        elif token == "--allow-unsafe":
            flags["allow_unsafe"] = True
            index += 1
        elif token.startswith("--"):
            unknown.append(token)
            index += 1
        else:
            break
    return flags, unknown, index


def main(argv: list[str]) -> tuple[dict[str, Any], int]:
    if not argv or argv[0] in {"help", "--help", "-h"}:
        return {"success": True, "help": "Use ui capabilities, validate, inspect [document|tree|node], get, set, add, delete, move, duplicate, build, build-all, or render."}, 0
    command = argv[0]
    if command == "capabilities":
        return {"success": True, "capabilities": capabilities()}, 0
    if command == "new":
        if len(argv) < 3:
            return {"success": False, "errors": [{"code": "USAGE", "message": "ui new <template> <output.ui.json> [--force] [--allow-outside-project]"}]}, 1
        flags, unknown, _ = parse_cli_flags(argv, 3)
        if unknown:
            return {"success": False, "errors": [{"code": "UNKNOWN_OPTION", "message": f"Unknown option '{unknown[0]}'."}]}, 1
        path_check = validate_output(argv[2], ".ui.json", flags["allow_outside_project"])
        if not path_check["ok"]:
            return {"success": False, "committed": False, "errors": path_check["errors"]}, 1
        create_check = check_create_allowed(argv[2], flags["force"])
        if not create_check["ok"]:
            return {"success": False, "committed": False, "errors": create_check["errors"]}, 1
        name = fs_path(argv[2]).name.removesuffix(".ui.json")
        name_diagnostic = document_name_diagnostic(name)
        if name_diagnostic:
            return {"success": False, "committed": False, "errors": [name_diagnostic]}, 1
        catalog = template_catalog()
        template = argv[1]
        if template in catalog:
            loaded = load(catalog[template]["path"])
            if loaded.get("document") is None:
                return {"success": False, "committed": False, "errors": loaded.get("errors", [])}, 1
            data = loaded["document"]
            data["name"] = name
            data.setdefault("metadata", {})["template"] = template
        elif template in {"blank", "window", "modal"}:
            data = {"schema_version": 1, "name": name, "viewport": {"width": 1920, "height": 1080}, "theme": "dark_fantasy", "root": {"id": f"{name}_root", "type": "WindowFrame", "layout": {"position": [80, 80], "size": [960, 640]}, "properties": {"title": name.replace("_", " ").title()}, "children": []}}
        else:
            return {"success": False, "errors": [{"code": "UNKNOWN_TEMPLATE", "message": f"Unknown template: {template}"}]}, 1
        validation = validate(data)
        if not validation["success"]:
            return {
                "success": False,
                "committed": False,
                "errors": [item for item in validation["diagnostics"] if item.get("severity") == "error"],
                "diagnostics": validation["diagnostics"],
            }, 1
        saved = save(argv[2], data)
        if not saved.get("success", False):
            return {"success": False, "committed": False, "errors": saved.get("errors", []), "template": template}, 1
        saved["committed"] = True
        saved["template"] = template
        return saved, 0
    if command == "build-all":
        source_dir = fs_path(argv[1]) if len(argv) > 1 and not argv[1].startswith("--") else ROOT / "examples/specs"
        output_dir = fs_path(argv[2]) if len(argv) > 2 and not argv[2].startswith("--") else ROOT / "examples/scenes"
        option_index = 1
        if len(argv) > 1 and not argv[1].startswith("--"):
            option_index = 2
        if len(argv) > 2 and not argv[2].startswith("--"):
            option_index = 3
        flags, unknown, _ = parse_cli_flags(argv, option_index)
        if unknown:
            return {"success": False, "errors": [{"code": "UNKNOWN_OPTION", "message": f"Unknown option '{unknown[0]}'."}]}, 1
        built, failed = [], []
        for source in sorted(source_dir.glob("*.ui.json")):
            output = output_dir / (source.name.removesuffix(".ui.json") + ".tscn")
            result, code = main(["build", str(source), str(output)] + ([ "--force"] if flags["force"] else []) + (["--allow-outside-project"] if flags["allow_outside_project"] else []))
            (built if code == 0 else failed).append(result)
        return {"success": not failed, "built": built, "failed": failed}, 0 if not failed else 1
    if len(argv) < 2:
        return {"success": False, "errors": [{"code": "USAGE", "message": f"ui {command} requires a document."}]}, 1
    loaded = load(argv[1])
    data = loaded.get("document")
    if data is None:
        return {"success": False, "errors": loaded["errors"]}, 1
    if command == "validate":
        result = validate(data)
        result["document"] = argv[1]
        return result, 0 if result["success"] else 1
    if command == "inspect":
        scope = argv[2] if len(argv) > 2 else "tree"
        if scope == "document":
            root = data.get("root", {}) if isinstance(data.get("root", {}), dict) else {}
            return {"success": True, "document": {"schema_version": data.get("schema_version", 1), "name": data.get("name", ""), "source": argv[1], "viewport": data.get("viewport", {}), "theme": data.get("theme", "dark_fantasy"), "root_id": root.get("id", ""), "root_type": root.get("type", ""), "node_count": sum(1 for _node, _parent in walk(root)), "components": sorted((data.get("components", {}) if isinstance(data.get("components", {}), dict) else {}).keys()), "metadata": data.get("metadata", {}), "reference": data.get("reference", {})},}, 0
        if scope == "tree":
            return {"success": True, "tree": tree(data["root"])}, 0
        if scope == "node":
            if len(argv) < 4:
                return {"success": False, "errors": [{"code": "USAGE", "message": "ui inspect <file.ui.json> node <node_id>"}]}, 1
            node, parent = find(data, argv[3])
            if node is None:
                return {"success": False, "error": {"code": "NODE_NOT_FOUND", "node": argv[3]}}, 1
            return {"success": True, "id": argv[3], "parent": parent.get("id", "") if parent else "", "node": node}, 0
        if scope == "tokens":
            overrides = data.get("theme_overrides", {})
            theme_data = merge_dicts(theme(data), overrides) if isinstance(overrides, dict) else theme(data)
            return {"success": True, "theme": data.get("theme", "dark_fantasy"), "tokens": theme_data.get("tokens", {})}, 0
        if scope == "components":
            return {"success": True, "components": {k: {"native_type": v[0], "style": v[1]} for k, v in COMPONENTS.items()}, "custom": data.get("components", {})}, 0
        if scope == "diagnostics":
            result = validate(data)
            return {"success": result["success"], "diagnostics": result["diagnostics"]}, 0 if result["success"] else 1
        node, parent = find(data, scope)
        if node is not None:
            return {"success": True, "id": scope, "parent": parent.get("id", "") if parent else "", "node": node}, 0
    if command == "get":
        if len(argv) < 3:
            return {"success": False, "errors": [{"code": "USAGE", "message": "ui get <file> <node_id> [property.path]"}]}, 1
        node, parent = find(data, argv[2])
        if node is None:
            return {"success": False, "error": {"code": "NODE_NOT_FOUND", "node": argv[2]}}, 1
        return {"success": True, "id": argv[2], "parent": parent.get("id", "") if parent else "", "value": get_path(node, argv[3] if len(argv) > 3 else "")}, 0
    if command == "set":
        if len(argv) < 5:
            return {"success": False, "errors": [{"code": "USAGE", "message": "ui set <file> <node_id> <property.path> <value>"}]}, 1
        return commit_mutation(argv[1], lambda working: operation_set(working, argv[2], argv[3], argv[4]))
    if command == "add":
        if len(argv) < 4:
            return {"success": False, "errors": [{"code": "USAGE", "message": "ui add <file> <parent_id> '<node_json>'"}]}, 1
        return commit_mutation(argv[1], lambda working: operation_add(working, argv[2], argv[3]))
    if command == "delete":
        if len(argv) < 3:
            return {"success": False, "errors": [{"code": "USAGE", "message": "ui delete <file> <node_id>"}]}, 1
        return commit_mutation(argv[1], lambda working: operation_delete(working, argv[2]))
    if command == "move":
        if len(argv) < 4:
            return {"success": False, "errors": [{"code": "USAGE", "message": "ui move <file> <node_id> <new_parent_id> [index]"}]}, 1
        index = int(argv[4]) if len(argv) > 4 else -1
        return commit_mutation(argv[1], lambda working: operation_move(working, argv[2], argv[3], index))
    if command == "duplicate":
        if len(argv) < 4:
            return {"success": False, "errors": [{"code": "USAGE", "message": "ui duplicate <file> <node_id> <new_id>"}]}, 1
        return commit_mutation(argv[1], lambda working: operation_duplicate(working, argv[2], argv[3]))
    if command == "build":
        flags, unknown, _ = parse_cli_flags(argv, 3 if len(argv) > 2 and not argv[2].startswith("--") else 2)
        if unknown:
            return {"success": False, "errors": [{"code": "UNKNOWN_OPTION", "message": f"Unknown option '{unknown[0]}'."}]}, 1
        result = validate(data)
        if not result["success"]:
            return result, 1
        output = argv[2] if len(argv) > 2 and not argv[2].startswith("--") else argv[1].removesuffix(".ui.json") + ".tscn"
        path_check = validate_output(output, ".tscn", flags["allow_outside_project"])
        if not path_check["ok"]:
            return {"success": False, "errors": path_check["errors"]}, 1
        identity = source_identity(argv[1])
        revision = content_hash(data)
        replace_check = check_replace_allowed(output, identity, revision, flags["force"])
        if not replace_check["ok"]:
            return {"success": False, "errors": replace_check["errors"]}, 1
        scene_text = build_tscn(data, argv[1])
        committed = write_text_atomically(output, scene_text, verify=verify_scene_syntax)
        if not committed.get("success"):
            return {"success": False, "committed": False, "errors": committed.get("errors", [])}, 1
        return {"success": True, "committed": True, "generated_scene": output, "warnings": result["warnings"], "diagnostics": result["diagnostics"]}, 0
    if command == "render":
        return {"success": False, "errors": [{"code": "GODOT_UNAVAILABLE", "message": "PNG rendering requires a Godot 4 executable; install Godot and rerun the same command."}]}, 1
    return {"success": False, "errors": [{"code": "UNKNOWN_COMMAND", "message": command}]}, 1


if __name__ == "__main__":
    result, exit_code = main(sys.argv[1:])
    print(json.dumps(result, indent="\t", ensure_ascii=False))
    raise SystemExit(exit_code)
