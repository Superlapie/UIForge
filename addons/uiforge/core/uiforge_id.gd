class_name UIForgeID
extends RefCounted

const GRAMMAR := "^[A-Za-z][A-Za-z0-9_-]*$"
const DOCUMENT_NAME_GRAMMAR := "^[A-Za-z0-9_-]+$"

static var _regex: RegEx
static var _document_name_regex: RegEx

static func _pattern() -> RegEx:
	if _regex == null:
		_regex = RegEx.new()
		_regex.compile(GRAMMAR)
	return _regex

static func _document_name_pattern() -> RegEx:
	if _document_name_regex == null:
		_document_name_regex = RegEx.new()
		_document_name_regex.compile(DOCUMENT_NAME_GRAMMAR)
	return _document_name_regex

static func is_valid(node_id: String) -> bool:
	if node_id.is_empty():
		return false
	return _pattern().search(node_id) != null

static func is_valid_document_name(name: String) -> bool:
	if name.is_empty():
		return false
	return _document_name_pattern().search(name) != null

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

static func document_name_diagnostic(name: String) -> Dictionary:
	if is_valid_document_name(name):
		return {}
	return {
		"severity": "error",
		"code": "DOCUMENT_NAME_INVALID",
		"message": "Document name '%s' must match %s." % [name, DOCUMENT_NAME_GRAMMAR],
		"node": "",
		"recommendation": "Use a stable document name with letters, numbers, underscores, and hyphens only."
	}

static func godot_node_name(node_id: String) -> String:
	return String(node_id).validate_node_name()

static func preserves_godot_identity(node_id: String) -> bool:
	return is_valid(node_id) and godot_node_name(node_id) == node_id
