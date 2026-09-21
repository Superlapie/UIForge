class_name UIForgeSerializer
extends RefCounted

static func load_document(path: String) -> Dictionary:
	if not FileAccess.file_exists(UIForgePaths.normalize_requested(path)):
		_recover_missing_source(path)
	if not FileAccess.file_exists(UIForgePaths.normalize_requested(path)):
		return {"document": null, "revision_hash": "", "errors": [{"code": "FILE_NOT_FOUND", "message": "Document not found: %s" % path}]}
	var absolute := UIForgePaths.normalize_requested(path)
	var file := FileAccess.open(absolute, FileAccess.READ)
	if file == null:
		return {"document": null, "revision_hash": "", "errors": [{"code": "FILE_OPEN_FAILED", "message": "Could not open: %s" % path}]}
	var text := file.get_as_text()
	file.close()
	var parser := JSON.new()
	var error := parser.parse(text)
	if error != OK or not parser.data is Dictionary:
		return {"document": null, "revision_hash": "", "errors": [{"code": "JSON_PARSE_ERROR", "message": parser.get_error_message(), "line": parser.get_error_line()}]}
	var revision_hash := UIForgeHash.content_hash(parser.data)
	return {"document": UIForgeDocument.from_dict(parser.data, path), "revision_hash": revision_hash, "errors": []}

static func save_document(document: UIForgeDocument, path: String = "", expected_revision: String = "") -> Dictionary:
	var target := path if not path.is_empty() else document.source_path
	if target.is_empty():
		return {"success": false, "committed": false, "errors": [{"code": "NO_PATH", "message": "A document path is required."}]}
	var payload := JSON.stringify(document.to_dict(), "\t") + "\n"
	var saved := UIForgeTransaction.write_source_atomically(target, payload, expected_revision)
	if saved.get("success", false):
		document.source_path = target
	return saved

static func create_default(document_name: String = "untitled") -> UIForgeDocument:
	return UIForgeDocument.from_dict({
		"schema_version": UIForgeTypes.SCHEMA_VERSION,
		"name": document_name,
		"viewport": {"width": 1920, "height": 1080},
		"theme": "dark_fantasy",
		"metadata": {"created_by": "uiforge"},
		"root": {
			"id": "%s_root" % document_name.to_snake_case(),
			"type": "WindowFrame",
			"layout": {"position": [80, 80], "size": [960, 640]},
			"properties": {"title": document_name.capitalize().replace("_", " ")},
			"children": []
		}
	})

static func _recover_missing_source(path: String) -> void:
	var absolute := UIForgePaths.normalize_requested(path)
	var backup_path := "%s.uiforge_backup" % absolute
	var pending_path := "%s.uiforge_pending" % absolute
	UIForgeTransaction._recover_interrupted_source(absolute, backup_path, pending_path)
