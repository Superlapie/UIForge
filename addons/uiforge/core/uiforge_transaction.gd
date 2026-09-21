class_name UIForgeTransaction
extends RefCounted

static func unique_temp_path(absolute: String, extension: String = "") -> String:
	var directory := absolute.get_base_dir()
	var base := absolute.get_file()
	var nonce := "%d_%d" % [Time.get_ticks_usec(), randi()]
	var suffix := extension if not extension.is_empty() else absolute.get_extension()
	if suffix.is_empty():
		return "%s/.uiforge_tmp_%s_%s" % [directory, base, nonce]
	var stem := base
	if base.contains("."):
		stem = base.get_basename()
	return "%s/.uiforge_tmp_%s_%s%s" % [directory, stem, nonce, extension if extension.begins_with(".") else ".%s" % extension]

static func replace_file(source_absolute: String, dest_absolute: String) -> int:
	if FileAccess.file_exists(dest_absolute):
		var remove_error := DirAccess.remove_absolute(dest_absolute)
		if remove_error != OK:
			return remove_error
	return DirAccess.rename_absolute(source_absolute, dest_absolute)

static func write_text_atomically(
	target_path: String,
	content: String,
	options: Dictionary = {}
) -> Dictionary:
	var absolute := UIForgePaths.normalize_requested(target_path)
	if absolute.is_empty():
		return {"success": false, "committed": false, "errors": [{"code": "OUTPUT_PATH_INVALID", "message": target_path}]}
	var extension := ".%s" % absolute.get_extension() if not absolute.get_extension().is_empty() else ""
	var temp_path := unique_temp_path(absolute, extension)
	var file := FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		return {"success": false, "committed": false, "errors": [{"code": "FILE_WRITE_FAILED", "message": "Could not write temporary artifact: %s" % temp_path}]}
	file.store_string(content)
	file.flush()
	file.close()
	var verify: Callable = options.get("verify", Callable())
	if verify.is_valid():
		var verify_result: Variant = verify.call(temp_path)
		if verify_result is Dictionary and not bool(verify_result.get("ok", true)):
			DirAccess.remove_absolute(temp_path)
			return {"success": false, "committed": false, "errors": verify_result.get("errors", [{"code": "VERIFY_FAILED", "message": temp_path}])}
	var lock := UIForgeLock.acquire(absolute)
	if not lock.get("ok", false):
		DirAccess.remove_absolute(temp_path)
		return {"success": false, "committed": false, "errors": lock.get("errors", [])}
	var lock_path := str(lock.get("lock_path", ""))
	var source_identity := str(options.get("source_identity", ""))
	var force := bool(options.get("force", false))
	if not source_identity.is_empty():
		var commit_check := UIForgeArtifact.check_commit_replace_allowed(target_path, source_identity, force)
		if not commit_check.get("ok", false):
			UIForgeLock.release(lock_path)
			DirAccess.remove_absolute(temp_path)
			return {"success": false, "committed": false, "errors": commit_check.get("errors", [])}
	var replace_error := replace_file(temp_path, absolute)
	UIForgeLock.release(lock_path)
	if replace_error != OK:
		if FileAccess.file_exists(temp_path):
			DirAccess.remove_absolute(temp_path)
		return {"success": false, "committed": false, "errors": [{"code": "ATOMIC_RENAME_FAILED", "message": "Could not replace %s" % target_path}]}
	return {"success": true, "committed": true, "path": target_path, "errors": []}

static func write_source_atomically(target_path: String, content: String, expected_revision: String = "") -> Dictionary:
	var absolute := UIForgePaths.normalize_requested(target_path)
	if absolute.is_empty():
		return {"success": false, "committed": false, "errors": [{"code": "OUTPUT_PATH_INVALID", "message": target_path}]}
	var lock := UIForgeLock.acquire(absolute)
	if not lock.get("ok", false):
		return {"success": false, "committed": false, "errors": lock.get("errors", [])}
	var lock_path := str(lock.get("lock_path", ""))
	var txn_paths := _transaction_paths(absolute)
	_recover_interrupted_source(absolute, txn_paths)
	if not expected_revision.is_empty() and FileAccess.file_exists(absolute):
		var current := UIForgeHash.file_revision(target_path)
		if not current.get("ok", false):
			UIForgeLock.release(lock_path)
			return {"success": false, "committed": false, "errors": current.get("errors", [])}
		if str(current.get("hash", "")) != expected_revision:
			UIForgeLock.release(lock_path)
			return {
				"success": false,
				"committed": false,
				"errors": [{
					"code": "WRITE_CONFLICT",
					"message": "Source changed since it was loaded; refusing to overwrite %s." % target_path,
					"path": target_path,
				}],
			}
	var temp_path := unique_temp_path(absolute, ".ui.json")
	var file := FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		UIForgeLock.release(lock_path)
		return {"success": false, "committed": false, "errors": [{"code": "FILE_WRITE_FAILED", "message": "Could not write: %s" % temp_path}]}
	file.store_string(content)
	file.flush()
	file.close()
	var txn_id := "%d_%d" % [Time.get_unix_time_from_system(), randi()]
	_write_txn_meta(txn_paths.meta, {
		"transaction_id": txn_id,
		"expected_revision": expected_revision,
		"stage": "pending",
		"target": absolute,
	})
	if FileAccess.file_exists(absolute):
		if FileAccess.file_exists(txn_paths.backup):
			DirAccess.remove_absolute(txn_paths.backup)
		var backup_error := DirAccess.rename_absolute(absolute, txn_paths.backup)
		if backup_error != OK:
			_cleanup_txn(txn_paths)
			DirAccess.remove_absolute(temp_path)
			UIForgeLock.release(lock_path)
			return {"success": false, "committed": false, "errors": [{"code": "BACKUP_RENAME_FAILED", "message": "Could not protect %s" % target_path}]}
	var pending_error := DirAccess.rename_absolute(temp_path, txn_paths.pending)
	if pending_error != OK:
		if FileAccess.file_exists(txn_paths.backup):
			DirAccess.rename_absolute(txn_paths.backup, absolute)
		_cleanup_txn(txn_paths)
		DirAccess.remove_absolute(temp_path)
		UIForgeLock.release(lock_path)
		return {"success": false, "committed": false, "errors": [{"code": "ATOMIC_RENAME_FAILED", "message": "Could not stage %s" % target_path}]}
	_write_txn_meta(txn_paths.meta, {
		"transaction_id": txn_id,
		"expected_revision": expected_revision,
		"stage": "commit",
		"target": absolute,
	})
	var replace_error := replace_file(txn_paths.pending, absolute)
	if replace_error != OK:
		if FileAccess.file_exists(txn_paths.backup):
			DirAccess.rename_absolute(txn_paths.backup, absolute)
		if FileAccess.file_exists(txn_paths.pending):
			DirAccess.remove_absolute(txn_paths.pending)
		_cleanup_txn(txn_paths)
		UIForgeLock.release(lock_path)
		return {"success": false, "committed": false, "errors": [{"code": "ATOMIC_RENAME_FAILED", "message": "Could not replace %s" % target_path}]}
	if FileAccess.file_exists(txn_paths.backup):
		DirAccess.remove_absolute(txn_paths.backup)
	_cleanup_txn(txn_paths)
	UIForgeLock.release(lock_path)
	return {"success": true, "committed": true, "path": target_path, "errors": []}

static func verify_scene_syntax(temp_path: String) -> Dictionary:
	var file := FileAccess.open(temp_path, FileAccess.READ)
	if file == null:
		return {"ok": false, "errors": [{"code": "VERIFY_READ_FAILED", "message": temp_path}]}
	var text := file.get_as_text()
	file.close()
	if not text.contains("[gd_scene"):
		return {"ok": false, "errors": [{"code": "SCENE_SYNTAX_INVALID", "message": "Generated scene is missing [gd_scene] header."}]}
	var parsed := UIForgeArtifact.parse_scene_header(text)
	if not parsed.get("ok", false):
		return {"ok": false, "errors": parsed.get("errors", [{"code": "SCENE_PROVENANCE_INVALID", "message": "Generated scene has invalid provenance."}])}
	if not parsed.get("header", {}).get("trusted", false):
		return {"ok": false, "errors": [{"code": "SCENE_PROVENANCE_INVALID", "message": "Generated scene is missing trusted UIForge provenance header."}]}
	var packed: Variant = _load_packed_scene_for_verify(temp_path)
	if packed == null:
		return {"ok": false, "errors": [{"code": "SCENE_SYNTAX_INVALID", "message": "Godot could not parse generated scene at %s." % temp_path}]}
	return {"ok": true, "errors": []}

static func _load_packed_scene_for_verify(temp_path: String) -> Variant:
	var safe_path := "/tmp/uiforge_verify_%d_%d.tscn" % [Time.get_ticks_usec(), randi()]
	if FileAccess.file_exists(safe_path):
		DirAccess.remove_absolute(safe_path)
	var source_file := FileAccess.open(temp_path, FileAccess.READ)
	if source_file == null:
		return null
	var dest_file := FileAccess.open(safe_path, FileAccess.WRITE)
	if dest_file == null:
		source_file.close()
		return ResourceLoader.load(temp_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
	dest_file.store_string(source_file.get_as_text())
	dest_file.close()
	source_file.close()
	var packed: Variant = ResourceLoader.load(safe_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
	if FileAccess.file_exists(safe_path):
		DirAccess.remove_absolute(safe_path)
	return packed

class TxnPaths:
	var backup: String
	var pending: String
	var meta: String

static func _transaction_paths(absolute: String) -> TxnPaths:
	var paths := TxnPaths.new()
	paths.backup = "%s.uiforge_backup" % absolute
	paths.pending = "%s.uiforge_pending" % absolute
	paths.meta = "%s.uiforge_txn" % absolute
	return paths

static func _write_txn_meta(meta_path: String, payload: Dictionary) -> void:
	var file := FileAccess.open(meta_path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(payload))
	file.close()

static func _read_txn_meta(meta_path: String) -> Dictionary:
	if not FileAccess.file_exists(meta_path):
		return {}
	var file := FileAccess.open(meta_path, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed if parsed is Dictionary else {}

static func _cleanup_txn(paths: TxnPaths) -> void:
	for sidecar in [paths.meta, paths.pending]:
		if FileAccess.file_exists(sidecar):
			DirAccess.remove_absolute(sidecar)

static func recover_interrupted_source_for_path(target_path: String) -> void:
	var absolute := UIForgePaths.normalize_requested(target_path)
	if absolute.is_empty():
		return
	_recover_interrupted_source(absolute, _transaction_paths(absolute))

static func _recover_interrupted_source(absolute: String, paths: TxnPaths) -> void:
	var meta := _read_txn_meta(paths.meta)
	if FileAccess.file_exists(paths.pending):
		var promote := false
		if not FileAccess.file_exists(absolute):
			promote = _source_content_valid(paths.pending)
		elif meta.get("stage", "") == "commit":
			promote = _source_content_valid(paths.pending)
		if promote:
			if FileAccess.file_exists(absolute):
				DirAccess.remove_absolute(absolute)
			replace_file(paths.pending, absolute)
		else:
			if FileAccess.file_exists(paths.pending):
				DirAccess.remove_absolute(paths.pending)
	if not FileAccess.file_exists(absolute) and FileAccess.file_exists(paths.backup):
		DirAccess.rename_absolute(paths.backup, absolute)
	_cleanup_txn(paths)

static func _source_content_valid(path: String) -> bool:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed is Dictionary
