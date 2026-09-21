class_name UIForgeResourceGuard
extends RefCounted

const ALLOWED_TYPES: Array[String] = [
	"Texture2D", "CompressedTexture2D", "ImageTexture", "AtlasTexture", "FontFile",
	"FontVariation", "Theme", "Material", "ShaderMaterial", "CanvasItemMaterial",
	"LabelSettings", "Shortcut", "ButtonGroup", "StyleBoxFlat", "StyleBoxTexture",
]
const BLOCKED_TYPES: Array[String] = [
	"Script", "GDScript", "CSharpScript", "PackedScene", "Shader",
]

static func cache_key(path: String, type_name: String) -> String:
	return "%s|%s" % [path, canonical_type(type_name)]

static func canonical_type(type_name: String) -> String:
	return str(type_name).strip_edges()

static func validate_external(path: String, requested_type: String, property_name: String, allow_unsafe: bool = false) -> Dictionary:
	var resource_type := canonical_type(requested_type)
	if path.is_empty() or not path.begins_with("res://"):
		return _error("RESOURCE_PATH_INVALID", "External resource path must begin with res://.")
	if path.contains("\n") or path.contains("\r") or path.contains("\""):
		return _error("RESOURCE_PATH_INVALID", "External resource path contains invalid characters.")
	if not allow_unsafe and resource_type in BLOCKED_TYPES:
		return _error("RESOURCE_TYPE_BLOCKED", "Resource type '%s' is blocked by default." % resource_type)
	if not allow_unsafe and UIForgePropertyGuard._is_execution_surface(property_name):
		return _error("RESOURCE_TYPE_BLOCKED", "Resource property '%s' is blocked by default." % property_name)
	if not resource_type.is_empty() and not resource_type in ALLOWED_TYPES and not allow_unsafe:
		return _error("RESOURCE_TYPE_UNKNOWN", "Resource type '%s' is not in the UIForge whitelist." % resource_type)
	if ResourceLoader.exists(path):
		var loaded: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		if loaded != null:
			var loaded_type := loaded.get_class()
			if not resource_type.is_empty() and loaded_type != resource_type and not _types_compatible(loaded_type, resource_type):
				return _error("RESOURCE_TYPE_MISMATCH", "Resource '%s' resolves to %s, not %s." % [path, loaded_type, resource_type])
			if not allow_unsafe and loaded_type in BLOCKED_TYPES:
				return _error("RESOURCE_TYPE_BLOCKED", "Resource '%s' resolves to blocked type %s." % [path, loaded_type])
	return {}

static func infer_type(property_name: String, native_type: String) -> String:
	var lowered := property_name.to_lower()
	if lowered.contains("font"):
		return "FontFile"
	if lowered.contains("theme"):
		return "Theme"
	if lowered.contains("material"):
		return "Material"
	if lowered.contains("label_settings"):
		return "LabelSettings"
	if lowered.contains("shortcut"):
		return "Shortcut"
	if lowered.contains("button_group"):
		return "ButtonGroup"
	return "Texture2D"

static func quote_path(path: String) -> String:
	return JSON.stringify(path)

static func _types_compatible(actual: String, requested: String) -> bool:
	if actual == requested:
		return true
	if actual.ends_with(requested) or requested.ends_with(actual):
		return true
	if actual == "CompressedTexture2D" and requested == "Texture2D":
		return true
	return false

static func _error(code: String, message: String) -> Dictionary:
	return {"severity": "error", "code": code, "message": message, "node": "", "recommendation": "Use a supported non-executable resource type and res:// path."}
