class_name UIForgeResourceGuard
extends RefCounted

const ALLOWED_TYPES: Array[String] = [
	"Texture2D", "CompressedTexture2D", "ImageTexture", "AtlasTexture", "FontFile",
	"FontVariation", "Theme", "Material", "ShaderMaterial", "CanvasItemMaterial",
	"LabelSettings", "Shortcut", "ButtonGroup", "StyleBoxFlat", "StyleBoxTexture",
]
const BLOCKED_EXTENSIONS: Array[String] = [".gd", ".cs", ".tscn", ".scn", ".shader", ".gdshader"]
const BLOCKED_TYPES: Array[String] = [
	"Script", "GDScript", "CSharpScript", "PackedScene", "Shader",
]
const FALLBACK_COMPATIBILITY: Dictionary = {
	"Texture2D": ["CompressedTexture2D", "ImageTexture", "AtlasTexture", "PortableCompressedTexture2D"],
	"FontFile": ["FontVariation"],
	"Material": ["ShaderMaterial", "CanvasItemMaterial"],
	"StyleBoxFlat": ["StyleBoxTexture", "StyleBoxEmpty"],
}

static func cache_key(path: String, type_name: String) -> String:
	return "%s|%s" % [path, canonical_type(type_name)]

static func canonical_type(type_name: String) -> String:
	return str(type_name).strip_edges()

static func validate_external(path: String, requested_type: String, property_name: String, node_id: String = "") -> Dictionary:
	var resource_type := canonical_type(requested_type)
	if path.is_empty() or not path.begins_with("res://"):
		return _error("RESOURCE_PATH_INVALID", "External resource path must begin with res://.", node_id, property_name)
	if path.contains("\n") or path.contains("\r") or path.contains("\""):
		return _error("RESOURCE_PATH_INVALID", "External resource path contains invalid characters.", node_id, property_name)
	var extension := path.get_extension()
	if not extension.is_empty() and (".%s" % extension.to_lower()) in BLOCKED_EXTENSIONS:
		return _error("RESOURCE_TYPE_BLOCKED", "Resource path '%s' uses blocked extension '.%s'." % [path, extension], node_id, property_name)
	if resource_type in BLOCKED_TYPES:
		return _error("RESOURCE_TYPE_BLOCKED", "Resource type '%s' is blocked by default." % resource_type, node_id, property_name)
	if UIForgePropertyGuard._is_execution_surface(property_name):
		return _error("RESOURCE_TYPE_BLOCKED", "Resource property '%s' is blocked by default." % property_name, node_id, property_name)
	if not resource_type.is_empty() and not resource_type in ALLOWED_TYPES:
		return _error("RESOURCE_TYPE_UNKNOWN", "Resource type '%s' is not in the UIForge whitelist." % resource_type, node_id, property_name)
	if ResourceLoader.exists(path):
		var loaded: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		if loaded != null:
			var loaded_type := loaded.get_class()
			if not resource_type.is_empty() and not types_compatible(loaded_type, resource_type):
				return _error("RESOURCE_TYPE_MISMATCH", "Resource '%s' resolves to %s, not %s." % [path, loaded_type, resource_type], node_id, property_name)
			if loaded_type in BLOCKED_TYPES:
				return _error("RESOURCE_TYPE_BLOCKED", "Resource '%s' resolves to blocked type %s." % [path, loaded_type], node_id, property_name)
	return {}

static func types_compatible(actual: String, requested: String) -> bool:
	if actual == requested:
		return true
	if ClassDB.is_parent_class(actual, requested):
		return true
	var allowed: Variant = FALLBACK_COMPATIBILITY.get(requested, [])
	if actual in allowed:
		return true
	return false

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

static func _error(code: String, message: String, node_id: String, property_name: String) -> Dictionary:
	return {
		"severity": "error",
		"code": code,
		"message": message,
		"node": node_id,
		"property": property_name,
		"recommendation": "Use a supported non-executable resource type and res:// path.",
	}
