class_name UIForgeSerializer
extends RefCounted

const SOURCE_WRITE_WAIT_MS := 500
const SOURCE_WRITE_WAIT_STEP_MS := 5

static func load_document(path: String) -> Dictionary:
	var absolute := UIForgePaths.normalize_requested(path)
	if absolute.is_empty():
		return {"document": null, "revision_hash": "", "errors": [{"code": "OUTPUT_PATH_INVALID", "message": path}]}
	if FileAccess.file_exists(absolute):
		return _read_document_file(path, absolute)
	var waited_ms := 0
	while waited_ms < SOURCE_WRITE_WAIT_MS:
		if FileAccess.file_exists(absolute):
			return _read_document_file(path, absolute)
		if UIForgeLock.live_lock_held(absolute):
			OS.delay_msec(SOURCE_WRITE_WAIT_STEP_MS)
			waited_ms += SOURCE_WRITE_WAIT_STEP_MS
			continue
		var recovery := UIForgeTransaction.try_recover_interrupted_source_for_path(path)
		if str(recovery.get("status", "")) == "live_writer":
			OS.delay_msec(SOURCE_WRITE_WAIT_STEP_MS)
			waited_ms += SOURCE_WRITE_WAIT_STEP_MS
			continue
		if FileAccess.file_exists(absolute):
			return _read_document_file(path, absolute)
		break
	if FileAccess.file_exists(absolute):
		return _read_document_file(path, absolute)
	if UIForgeLock.live_lock_held(absolute):
		return {
			"document": null,
			"revision_hash": "",
			"errors": [{
				"code": "SOURCE_WRITE_IN_PROGRESS",
				"message": "Document write is in progress for %s." % path,
				"path": path,
			}],
		}
	var recovery := UIForgeTransaction.try_recover_interrupted_source_for_path(path)
	if str(recovery.get("status", "")) == "live_writer":
		return {
			"document": null,
			"revision_hash": "",
			"errors": [{
				"code": "SOURCE_WRITE_IN_PROGRESS",
				"message": "Document write is in progress for %s." % path,
				"path": path,
			}],
		}
	if FileAccess.file_exists(absolute):
		return _read_document_file(path, absolute)
	return {"document": null, "revision_hash": "", "errors": [{"code": "FILE_NOT_FOUND", "message": "Document not found: %s" % path}]}

static func _read_document_file(path: String, absolute: String) -> Dictionary:
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
