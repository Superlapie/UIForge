class_name AetherSerializer
extends RefCounted

static func load_document(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"document": null, "errors": [{"code": "FILE_NOT_FOUND", "message": "Document not found: %s" % path}]}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"document": null, "errors": [{"code": "FILE_OPEN_FAILED", "message": "Could not open: %s" % path}]}
	var text := file.get_as_text()
	file.close()
	var parser := JSON.new()
	var error := parser.parse(text)
	if error != OK or not parser.data is Dictionary:
		return {"document": null, "errors": [{"code": "JSON_PARSE_ERROR", "message": parser.get_error_message(), "line": parser.get_error_line()}]}
	return {"document": AetherDocument.from_dict(parser.data, path), "errors": []}

static func save_document(document: AetherDocument, path: String = "") -> Dictionary:
	var target := path if not path.is_empty() else document.source_path
	if target.is_empty():
		return {"success": false, "errors": [{"code": "NO_PATH", "message": "A document path is required."}]}
	var absolute_target := ProjectSettings.globalize_path(target)
	var absolute_temp := "%s.aether_tmp" % absolute_target
	var absolute_backup := "%s.aether_backup" % absolute_target
	# Recover a previous source if the editor was interrupted after moving it
	# aside but before the replacement completed.
	if not FileAccess.file_exists(absolute_target) and FileAccess.file_exists(absolute_backup):
		DirAccess.rename_absolute(absolute_backup, absolute_target)
	var file := FileAccess.open(absolute_temp, FileAccess.WRITE)
	if file == null:
		return {"success": false, "errors": [{"code": "FILE_WRITE_FAILED", "message": "Could not write: %s" % absolute_temp}]}
	file.store_string(JSON.stringify(document.to_dict(), "\t"))
	file.flush()
	file.close()
	if FileAccess.file_exists(absolute_backup):
		DirAccess.remove_absolute(absolute_backup)
	if FileAccess.file_exists(absolute_target):
		var backup_error := DirAccess.rename_absolute(absolute_target, absolute_backup)
		if backup_error != OK:
			DirAccess.remove_absolute(absolute_temp)
			return {"success": false, "errors": [{"code": "BACKUP_RENAME_FAILED", "message": "Could not protect %s" % target}]}
	var rename_error := DirAccess.rename_absolute(absolute_temp, absolute_target)
	if rename_error != OK:
		if FileAccess.file_exists(absolute_backup):
			DirAccess.rename_absolute(absolute_backup, absolute_target)
		if FileAccess.file_exists(absolute_temp):
			DirAccess.remove_absolute(absolute_temp)
		return {"success": false, "errors": [{"code": "ATOMIC_RENAME_FAILED", "message": "Could not replace %s" % target}]}
	if FileAccess.file_exists(absolute_backup):
		DirAccess.remove_absolute(absolute_backup)
	document.source_path = target
	return {"success": true, "path": target, "errors": []}

static func create_default(document_name: String = "untitled") -> AetherDocument:
	return AetherDocument.from_dict({
		"schema_version": AetherTypes.SCHEMA_VERSION,
		"name": document_name,
		"viewport": {"width": 1920, "height": 1080},
		"theme": "dark_fantasy",
		"metadata": {"created_by": "aether_ui"},
		"root": {
			"id": "%s_root" % document_name.to_snake_case(),
			"type": "WindowFrame",
			"layout": {"position": [80, 80], "size": [960, 640]},
			"properties": {"title": document_name.capitalize().replace("_", " ")},
			"children": []
		}
	})
