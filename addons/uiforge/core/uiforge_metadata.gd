class_name UIForgeMetadata
extends RefCounted

const RESERVED_PREFIX: String = "uiforge_"
const LEGACY_RESERVED_PREFIX: String = "aether_"
const GENERATED_KEYS: Array[String] = [
	"uiforge_id", "uiforge_type", "uiforge_generated", "uiforge_action",
	"uiforge_binding", "uiforge_transitions", "uiforge_effects", "uiforge_decoration",
]
const LEGACY_GENERATED_KEYS: Array[String] = [
	"aether_id", "aether_type", "aether_generated", "aether_action",
	"aether_binding", "aether_transitions", "aether_effects", "aether_decoration",
]

static func is_valid_identifier(name: String) -> bool:
	return RegEx.create_from_string("^[A-Za-z_][A-Za-z0-9_]*$").search(str(name)) != null

static func validate_authored_key(key: String) -> Dictionary:
	var name := str(key)
	if name.is_empty():
		return _error("METADATA_KEY_INVALID", "Metadata keys must be non-empty identifiers.")
	if name.begins_with(RESERVED_PREFIX):
		return _error("METADATA_KEY_RESERVED", "Metadata key '%s' uses the reserved uiforge_* namespace." % name, name)
	if name.begins_with(LEGACY_RESERVED_PREFIX):
		return _error("METADATA_KEY_RESERVED", "Metadata key '%s' uses the reserved legacy aether_* namespace." % name, name)
	if name in GENERATED_KEYS or name in LEGACY_GENERATED_KEYS:
		return _error("METADATA_KEY_RESERVED", "Metadata key '%s' is reserved for generated artifacts." % name, name)
	if not UIForgeMetadata.is_valid_identifier(name):
		return _error("METADATA_KEY_INVALID", "Metadata key '%s' must be a Godot-safe identifier." % name, name)
	return {}

static func read_node_id(node: Node) -> String:
	if node == null:
		return ""
	if node.has_meta("uiforge_id"):
		return str(node.get_meta("uiforge_id", ""))
	return str(node.get_meta("aether_id", ""))

static func read_generated_flag(node: Node) -> bool:
	if node == null:
		return false
	if node.has_meta("uiforge_generated"):
		return bool(node.get_meta("uiforge_generated", false))
	return bool(node.get_meta("aether_generated", false))

static func read_meta(node: Node, key: String, fallback: Variant = "") -> Variant:
	if node == null:
		return fallback
	var modern := "uiforge_%s" % key
	if node.has_meta(modern):
		return node.get_meta(modern, fallback)
	var legacy := "aether_%s" % key
	if node.has_meta(legacy):
		return node.get_meta(legacy, fallback)
	return fallback

static func _error(code: String, message: String, key: String = "") -> Dictionary:
	return {"severity": "error", "code": code, "message": message, "node": key, "recommendation": "Use a non-reserved identifier for authored metadata."}
