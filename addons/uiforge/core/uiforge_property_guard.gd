class_name UIForgePropertyGuard
extends RefCounted

const THEME_OVERRIDE_PREFIXES: Array[String] = [
	"theme_override_colors/", "theme_override_constants/", "theme_override_fonts/",
	"theme_override_font_sizes/", "theme_override_icons/", "theme_override_styles/",
]
const BLOCKED_PROPERTIES: Array[String] = [
	"script", "process_thread_group", "process_thread_messages",
	"process_thread_group_order",
]
const BLOCKED_RESOURCE_HINTS: Array[String] = ["script", "gdscript", "csharp", "shader", "packedscene", "scene"]

static func validate_override(property_name: String, native_type: String, allow_unsafe: bool = false) -> Dictionary:
	var name := str(property_name)
	if name.is_empty() or name.contains("\n") or name.contains("\r") or name.contains("="):
		return _error("GODOT_OVERRIDE_INVALID", "Property path '%s' contains invalid syntax." % name)
	if name.begins_with("metadata/") or name.begins_with("metadata\\"):
		return _error("GODOT_OVERRIDE_FORBIDDEN", "Cannot write metadata through godot_overrides.")
	for reserved in UIForgeMetadata.GENERATED_KEYS + UIForgeMetadata.LEGACY_GENERATED_KEYS:
		if name == reserved or name.ends_with("/%s" % reserved):
			return _error("GODOT_OVERRIDE_FORBIDDEN", "Property '%s' is reserved for generated metadata." % name)
	for blocked in BLOCKED_PROPERTIES:
		if name == blocked or name.ends_with("/%s" % blocked):
			return _error("GODOT_OVERRIDE_FORBIDDEN", "Property '%s' is blocked by default." % name, allow_unsafe)
	if not allow_unsafe and _is_execution_surface(name):
		return _error("GODOT_OVERRIDE_UNSAFE", "Property '%s' can attach executable resources and is blocked by default." % name, allow_unsafe)
	if _is_theme_override(name):
		return _validate_theme_override(name)
	return _validate_native_property(name, native_type)

static func validate_overrides(overrides: Variant, native_type: String, node_id: String, allow_unsafe: bool = false) -> Array:
	var diagnostics: Array = []
	if overrides == null:
		return diagnostics
	if not overrides is Dictionary:
		diagnostics.append({
			"severity": "error", "code": "GODOT_OVERRIDES_INVALID", "message": "properties.godot_overrides must be an object.",
			"node": node_id, "recommendation": "Use native Godot property paths mapped to JSON values.",
		})
		return diagnostics
	for property_name in overrides:
		var diagnostic := validate_override(str(property_name), native_type, allow_unsafe)
		if not diagnostic.is_empty():
			diagnostic["node"] = node_id
			diagnostics.append(diagnostic)
	return diagnostics

static func _validate_theme_override(name: String) -> Dictionary:
	var parts := name.split("/")
	if parts.size() != 2 or parts[0].is_empty() or parts[1].is_empty():
		return _error("GODOT_OVERRIDE_INVALID", "Theme override path '%s' is malformed." % name)
	if not UIForgeMetadata.is_valid_identifier(parts[1]):
		return _error("GODOT_OVERRIDE_INVALID", "Theme override key '%s' must be a Godot-safe identifier." % parts[1])
	return {}

static func _validate_native_property(name: String, native_type: String) -> Dictionary:
	if name.contains("/"):
		return _error("GODOT_OVERRIDE_UNKNOWN", "Unknown or unsupported property path '%s'." % name)
	if ClassDB.class_exists(native_type):
		for property_info in ClassDB.class_get_property_list(native_type):
			if str(property_info.get("name", "")) == name:
				return {}
	return _error("GODOT_OVERRIDE_UNKNOWN", "Unknown property '%s' for %s." % [name, native_type])

static func _is_theme_override(name: String) -> bool:
	for prefix in THEME_OVERRIDE_PREFIXES:
		if name.begins_with(prefix):
			return true
	return false

static func _is_execution_surface(name: String) -> bool:
	var lowered := name.to_lower()
	for token in BLOCKED_RESOURCE_HINTS:
		if lowered.contains(token):
			return true
	return false

static func _error(code: String, message: String, allow_unsafe: bool = false) -> Dictionary:
	var recommendation := "Remove the override or pass an explicit unsafe opt-in if your workflow truly requires it."
	if allow_unsafe:
		recommendation = "This workflow requested unsafe overrides; enable unsafe compilation explicitly."
	return {"severity": "error", "code": code, "message": message, "node": "", "recommendation": recommendation}
