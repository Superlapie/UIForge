class_name UIForgeHash
extends RefCounted

static func document_revision(document: UIForgeDocument) -> String:
	return content_hash(document.to_dict())

static func content_hash(data: Dictionary) -> String:
	return "sha256:%s" % _sha256_text(_canonical_json(data))

static func file_revision(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "hash": "", "errors": [{"code": "FILE_NOT_FOUND", "message": "Document not found: %s" % path}]}
	var absolute := UIForgePaths.normalize_requested(path)
	var file := FileAccess.open(absolute, FileAccess.READ)
	if file == null:
		return {"ok": false, "hash": "", "errors": [{"code": "FILE_OPEN_FAILED", "message": "Could not open: %s" % path}]}
	var text := file.get_as_text()
	file.close()
	var parser := JSON.new()
	var error := parser.parse(text)
	if error != OK or not parser.data is Dictionary:
		return {"ok": false, "hash": "", "errors": [{"code": "JSON_PARSE_ERROR", "message": parser.get_error_message(), "line": parser.get_error_line()}]}
	return {"ok": true, "hash": content_hash(parser.data), "errors": []}

static func _canonical_json(value: Variant) -> String:
	return JSON.stringify(_sort_recursive(value), "", false)

static func _sort_recursive(value: Variant) -> Variant:
	if value is Dictionary:
		var keys: Array = value.keys()
		keys.sort()
		var result: Dictionary = {}
		for key in keys:
			result[key] = _sort_recursive(value[key])
		return result
	if value is Array:
		var result_array: Array = []
		for entry in value:
			result_array.append(_sort_recursive(entry))
		return result_array
	return value

static func _sha256_text(text: String) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(text.to_utf8_buffer())
	return context.finish().hex_encode()
