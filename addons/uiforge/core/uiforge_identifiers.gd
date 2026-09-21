class_name UIForgeIdentifiers
extends RefCounted

static var _godot_id_pattern: RegEx

static func _godot_id_regex() -> RegEx:
	if _godot_id_pattern == null:
		_godot_id_pattern = RegEx.create_from_string("^[A-Za-z0-9_]+$")
	return _godot_id_pattern

static func encode_resource_id_part(value: String) -> String:
	var canonical := str(value)
	if canonical.is_empty():
		return "node"
	return "id_%s" % canonical.to_utf8_buffer().hex_encode()

static func is_valid_godot_id(value: String) -> bool:
	return _godot_id_regex().search(str(value)) != null

static func validate_scene_text_ids(text: String) -> Dictionary:
	var errors: Array = []
	var regex := RegEx.new()
	regex.compile("id=\"([^\"]+)\"")
	for match in regex.search_all(text):
		var resource_id := str(match.get_string(1))
		if not is_valid_godot_id(resource_id):
			errors.append({
				"code": "SCENE_RESOURCE_ID_INVALID",
				"message": "Generated scene contains invalid Godot resource id '%s'." % resource_id,
			})
	return {"ok": errors.is_empty(), "errors": errors}
