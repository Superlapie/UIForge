class_name UIForgeTransaction
extends RefCounted

static func write_text_atomically(
	target_path: String,
	content: String,
	precondition: Callable = Callable(),
	verify: Callable = Callable()
) -> Dictionary:
	var absolute := UIForgePaths.normalize_requested(target_path)
	if absolute.is_empty():
		return {"success": false, "committed": false, "errors": [{"code": "OUTPUT_PATH_INVALID", "message": target_path}]}
	if precondition.is_valid() and not bool(precondition.call()):
		return {"success": false, "committed": false, "errors": [{"code": "PRECONDITION_FAILED", "message": "Write precondition failed for %s" % target_path}]}
	var temp_path := _unique_temp_path(absolute)
	var file := FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		return {"success": false, "committed": false, "errors": [{"code": "FILE_WRITE_FAILED", "message": "Could not write temporary artifact: %s" % temp_path}]}
	file.store_string(content)
	file.flush()
	file.close()
	if verify.is_valid():
		var verify_result: Variant = verify.call(temp_path)
		if verify_result is Dictionary and not bool(verify_result.get("ok", true)):
			DirAccess.remove_absolute(temp_path)
			var errors: Array = verify_result.get("errors", [{"code": "VERIFY_FAILED", "message": temp_path}])
			return {"success": false, "committed": false, "errors": errors}
	var rename_error := DirAccess.rename_absolute(temp_path, absolute)
	if rename_error != OK:
		DirAccess.remove_absolute(temp_path)
		return {"success": false, "committed": false, "errors": [{"code": "ATOMIC_RENAME_FAILED", "message": "Could not replace %s" % target_path}]}
	return {"success": true, "committed": true, "path": target_path, "errors": []}

static func write_source_atomically(target_path: String, content: String, expected_revision: String = "") -> Dictionary:
	var absolute := UIForgePaths.normalize_requested(target_path)
	var backup_path := "%s.uiforge_backup" % absolute
	var pending_path := "%s.uiforge_pending" % absolute
	_recover_interrupted_source(absolute, backup_path, pending_path)
	if not expected_revision.is_empty() and FileAccess.file_exists(absolute):
		var current := UIForgeHash.file_revision(target_path)
		if not current.get("ok", false):
			return {"success": false, "committed": false, "errors": current.get("errors", [])}
		if str(current.get("hash", "")) != expected_revision:
			return {
				"success": false,
				"committed": false,
				"errors": [{
					"code": "WRITE_CONFLICT",
					"message": "Source changed since it was loaded; refusing to overwrite %s." % target_path,
					"path": target_path,
				}],
			}
	var temp_path := _unique_temp_path(absolute)
	var file := FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		return {"success": false, "committed": false, "errors": [{"code": "FILE_WRITE_FAILED", "message": "Could not write: %s" % temp_path}]}
	file.store_string(content)
	file.flush()
	file.close()
	if FileAccess.file_exists(absolute):
		if FileAccess.file_exists(backup_path):
			DirAccess.remove_absolute(backup_path)
		var backup_error := DirAccess.rename_absolute(absolute, backup_path)
		if backup_error != OK:
			DirAccess.remove_absolute(temp_path)
			return {"success": false, "committed": false, "errors": [{"code": "BACKUP_RENAME_FAILED", "message": "Could not protect %s" % target_path}]}
	var pending_error := DirAccess.rename_absolute(temp_path, pending_path)
	if pending_error != OK:
		if FileAccess.file_exists(backup_path):
			DirAccess.rename_absolute(backup_path, absolute)
		DirAccess.remove_absolute(temp_path)
		return {"success": false, "committed": false, "errors": [{"code": "ATOMIC_RENAME_FAILED", "message": "Could not stage %s" % target_path}]}
	var replace_error := DirAccess.rename_absolute(pending_path, absolute)
	if replace_error != OK:
		if FileAccess.file_exists(backup_path):
			DirAccess.rename_absolute(backup_path, absolute)
		if FileAccess.file_exists(pending_path):
			DirAccess.remove_absolute(pending_path)
		return {"success": false, "committed": false, "errors": [{"code": "ATOMIC_RENAME_FAILED", "message": "Could not replace %s" % target_path}]}
	if FileAccess.file_exists(backup_path):
		DirAccess.remove_absolute(backup_path)
	return {"success": true, "committed": true, "path": target_path, "errors": []}

static func verify_scene_syntax(temp_path: String) -> Dictionary:
	var file := FileAccess.open(temp_path, FileAccess.READ)
	if file == null:
		return {"ok": false, "errors": [{"code": "VERIFY_READ_FAILED", "message": temp_path}]}
	var text := file.get_as_text()
	file.close()
	if not text.contains("[gd_scene"):
		return {"ok": false, "errors": [{"code": "SCENE_SYNTAX_INVALID", "message": "Generated scene is missing [gd_scene] header."}]}
	var header := UIForgeArtifact.parse_scene_header(text)
	if not header.get("is_uiforge", false):
		return {"ok": false, "errors": [{"code": "SCENE_PROVENANCE_INVALID", "message": "Generated scene is missing UIForge provenance header."}]}
	return {"ok": true, "errors": []}

static func _recover_interrupted_source(absolute: String, backup_path: String, pending_path: String) -> void:
	if FileAccess.file_exists(pending_path):
		if FileAccess.file_exists(absolute):
			DirAccess.remove_absolute(absolute)
		DirAccess.rename_absolute(pending_path, absolute)
	elif not FileAccess.file_exists(absolute) and FileAccess.file_exists(backup_path):
		DirAccess.rename_absolute(backup_path, absolute)

static func _unique_temp_path(absolute: String) -> String:
	var directory := absolute.get_base_dir()
	var base := absolute.get_file()
	var nonce := "%d_%d" % [Time.get_ticks_usec(), randi()]
	return "%s/.uiforge_tmp_%s_%s" % [directory, base, nonce]
