class_name UIForgeID
extends RefCounted

const GRAMMAR := "^[A-Za-z][A-Za-z0-9_-]*$"

static var _regex: RegEx

static func _pattern() -> RegEx:
	if _regex == null:
		_regex = RegEx.new()
		_regex.compile(GRAMMAR)
	return _regex

static func is_valid(node_id: String) -> bool:
	if node_id.is_empty():
		return false
	return _pattern().search(node_id) != null

static func diagnostic(node_id: String, context_id: String = "") -> Dictionary:
	if is_valid(node_id):
		return {}
	return {
		"severity": "error",
		"code": "ID_INVALID",
		"message": "Node id '%s' must match %s." % [node_id, GRAMMAR],
		"node": context_id if not context_id.is_empty() else node_id,
		"recommendation": "Use stable snake_case IDs that start with a letter and survive Godot node-name validation unchanged."
	}

static func godot_node_name(node_id: String) -> String:
	return String(node_id).validate_node_name()

static func preserves_godot_identity(node_id: String) -> bool:
	return is_valid(node_id) and godot_node_name(node_id) == node_id
