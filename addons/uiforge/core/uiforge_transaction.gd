class_name UIForgeTransaction
extends RefCounted

static var source_write_pause_hook: Callable = Callable()
static var _replace_hash_pattern: RegEx
static var _replace_transaction_id_pattern: RegEx

static func _hash_regex() -> RegEx:
	if _replace_hash_pattern == null:
		_replace_hash_pattern = RegEx.create_from_string("^sha256:[0-9a-f]{64}$")
	return _replace_hash_pattern

static func _transaction_id_regex() -> RegEx:
	if _replace_transaction_id_pattern == null:
		_replace_transaction_id_pattern = RegEx.create_from_string("^[0-9a-f]{32}$")
	return _replace_transaction_id_pattern

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

static func replace_file(source_absolute: String, dest_absolute: String) -> Dictionary:
	var recovery := _recover_interrupted_replace(dest_absolute)
	if not recovery.get("ok", false):
		return {"ok": false, "errors": recovery.get("errors", [{"code": "REPLACE_RECOVERY_CONFLICT"}])}
	if not FileAccess.file_exists(source_absolute):
		return {"ok": false, "errors": [{"code": "FILE_WRITE_FAILED", "message": "Missing staged file %s" % source_absolute}]}
	if not FileAccess.file_exists(dest_absolute):
		if DirAccess.rename_absolute(source_absolute, dest_absolute) == OK:
			_cleanup_replace_sidecars(dest_absolute)
			return {"ok": true, "errors": []}
		return {"ok": false, "errors": [{"code": "ATOMIC_RENAME_FAILED", "message": "Could not create %s" % dest_absolute}]}
	var backup_path := "%s.uiforge_replace_backup" % dest_absolute
	var meta_path := _replace_meta_path(dest_absolute)
	var backup_hash := _file_text_hash(dest_absolute)
	var new_hash := _file_text_hash(source_absolute)
	var transaction_id := _secure_transaction_id()
	_write_replace_meta(meta_path, {
		"transaction_id": transaction_id,
		"target": dest_absolute,
		"stage": "backup",
		"backup_hash": backup_hash,
		"new_hash": new_hash,
	})
	if FileAccess.file_exists(backup_path):
		DirAccess.remove_absolute(backup_path)
	var backup_error := DirAccess.rename_absolute(dest_absolute, backup_path)
	if backup_error != OK:
		_cleanup_replace_meta(meta_path)
		return {"ok": false, "errors": [{"code": "BACKUP_RENAME_FAILED", "message": "Could not protect %s" % dest_absolute}]}
	_write_replace_meta(meta_path, {
		"transaction_id": transaction_id,
		"target": dest_absolute,
		"stage": "commit",
		"backup_hash": backup_hash,
		"new_hash": new_hash,
	})
	var replace_error := DirAccess.rename_absolute(source_absolute, dest_absolute)
	if replace_error != OK:
		if FileAccess.file_exists(backup_path):
			DirAccess.rename_absolute(backup_path, dest_absolute)
		_cleanup_replace_sidecars(dest_absolute)
		return {"ok": false, "errors": [{"code": "ATOMIC_RENAME_FAILED", "message": "Could not replace %s" % dest_absolute}]}
	_write_replace_meta(meta_path, {
		"transaction_id": transaction_id,
		"target": dest_absolute,
		"stage": "complete",
		"backup_hash": backup_hash,
		"new_hash": _file_text_hash(dest_absolute),
	})
	if FileAccess.file_exists(backup_path):
		DirAccess.remove_absolute(backup_path)
	_cleanup_replace_sidecars(dest_absolute)
	return {"ok": true, "errors": []}

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
	var owner_nonce := str(lock.get("owner_nonce", ""))
	var source_identity := str(options.get("source_identity", ""))
	var force := bool(options.get("force", false))
	var recovery := _recover_interrupted_replace(absolute)
	if not recovery.get("ok", false):
		UIForgeLock.release(lock_path, owner_nonce)
		DirAccess.remove_absolute(temp_path)
		return {"success": false, "committed": false, "errors": recovery.get("errors", [{"code": "REPLACE_RECOVERY_CONFLICT"}])}
	if not source_identity.is_empty():
		var commit_check := UIForgeArtifact.check_commit_replace_allowed(target_path, source_identity, force)
		if not commit_check.get("ok", false):
			UIForgeLock.release(lock_path, owner_nonce)
			DirAccess.remove_absolute(temp_path)
			return {"success": false, "committed": false, "errors": commit_check.get("errors", [])}
	var replace_result := replace_file(temp_path, absolute)
	UIForgeLock.release(lock_path, owner_nonce)
	if not replace_result.get("ok", false):
		if FileAccess.file_exists(temp_path):
			DirAccess.remove_absolute(temp_path)
		return {"success": false, "committed": false, "errors": replace_result.get("errors", [{"code": "ATOMIC_RENAME_FAILED", "message": target_path}])}
	return {"success": true, "committed": true, "path": target_path, "errors": []}

static func write_source_atomically(target_path: String, content: String, expected_revision: String = "") -> Dictionary:
	var absolute := UIForgePaths.normalize_requested(target_path)
	if absolute.is_empty():
		return {"success": false, "committed": false, "errors": [{"code": "OUTPUT_PATH_INVALID", "message": target_path}]}
	var lock := UIForgeLock.acquire(absolute)
	if not lock.get("ok", false):
		return {"success": false, "committed": false, "errors": lock.get("errors", [])}
	var lock_path := str(lock.get("lock_path", ""))
	var owner_nonce := str(lock.get("owner_nonce", ""))
	var txn_paths := _transaction_paths(absolute)
	var new_revision := _json_revision_from_text(content)
	_recover_interrupted_source_locked(absolute, txn_paths)
	if not expected_revision.is_empty() and FileAccess.file_exists(absolute):
		var current := UIForgeHash.file_revision(target_path)
		if not current.get("ok", false):
			UIForgeLock.release(lock_path, owner_nonce)
			return {"success": false, "committed": false, "errors": current.get("errors", [])}
		if str(current.get("hash", "")) != expected_revision:
			UIForgeLock.release(lock_path, owner_nonce)
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
		UIForgeLock.release(lock_path, owner_nonce)
		return {"success": false, "committed": false, "errors": [{"code": "FILE_WRITE_FAILED", "message": "Could not write: %s" % temp_path}]}
	file.store_string(content)
	file.flush()
	file.close()
	var txn_id := "%d_%d" % [Time.get_unix_time_from_system(), randi()]
	var pending_hash := _file_text_hash(temp_path)
	_write_txn_meta(txn_paths.meta, {
		"transaction_id": txn_id,
		"target": absolute,
		"expected_revision": expected_revision,
		"new_revision": new_revision,
		"pending_hash": pending_hash,
		"stage": "pending",
	})
	if FileAccess.file_exists(absolute):
		if FileAccess.file_exists(txn_paths.backup):
			DirAccess.remove_absolute(txn_paths.backup)
		var backup_error := DirAccess.rename_absolute(absolute, txn_paths.backup)
		if backup_error != OK:
			_cleanup_txn(txn_paths)
			DirAccess.remove_absolute(temp_path)
			UIForgeLock.release(lock_path, owner_nonce)
			return {"success": false, "committed": false, "errors": [{"code": "BACKUP_RENAME_FAILED", "message": "Could not protect %s" % target_path}]}
	_maybe_pause("after_backup")
	var pending_error := DirAccess.rename_absolute(temp_path, txn_paths.pending)
	if pending_error != OK:
		if FileAccess.file_exists(txn_paths.backup):
			DirAccess.rename_absolute(txn_paths.backup, absolute)
		_cleanup_txn(txn_paths)
		DirAccess.remove_absolute(temp_path)
		UIForgeLock.release(lock_path, owner_nonce)
		return {"success": false, "committed": false, "errors": [{"code": "ATOMIC_RENAME_FAILED", "message": "Could not stage %s" % target_path}]}
	_maybe_pause("after_pending")
	_write_txn_meta(txn_paths.meta, {
		"transaction_id": txn_id,
		"target": absolute,
		"expected_revision": expected_revision,
		"new_revision": new_revision,
		"pending_hash": pending_hash,
		"stage": "commit",
	})
	_maybe_pause("before_promotion")
	var replace_result := replace_file(txn_paths.pending, absolute)
	if not replace_result.get("ok", false):
		if FileAccess.file_exists(txn_paths.backup):
			DirAccess.rename_absolute(txn_paths.backup, absolute)
		if FileAccess.file_exists(txn_paths.pending):
			DirAccess.remove_absolute(txn_paths.pending)
		_cleanup_txn(txn_paths)
		UIForgeLock.release(lock_path, owner_nonce)
		return {"success": false, "committed": false, "errors": replace_result.get("errors", [{"code": "ATOMIC_RENAME_FAILED", "message": target_path}])}
	if FileAccess.file_exists(txn_paths.backup):
		DirAccess.remove_absolute(txn_paths.backup)
	_cleanup_txn(txn_paths)
	_cleanup_sidecars(absolute)
	UIForgeLock.release(lock_path, owner_nonce)
	return {"success": true, "committed": true, "path": target_path, "errors": []}

static func verify_scene_syntax(temp_path: String) -> Dictionary:
	var file := FileAccess.open(temp_path, FileAccess.READ)
	if file == null:
		return {"ok": false, "errors": [{"code": "VERIFY_READ_FAILED", "message": temp_path}]}
	var text := file.get_as_text()
	file.close()
	if not text.contains("[gd_scene"):
		return {"ok": false, "errors": [{"code": "SCENE_SYNTAX_INVALID", "message": "Generated scene is missing [gd_scene] header."}]}
	var id_check := UIForgeIdentifiers.validate_scene_text_ids(text)
	if not id_check.get("ok", false):
		return {"ok": false, "errors": id_check.get("errors", [])}
	var parsed := UIForgeArtifact.parse_scene_header(text)
	if not parsed.get("ok", false):
		return {"ok": false, "errors": parsed.get("errors", [{"code": "SCENE_PROVENANCE_INVALID", "message": "Generated scene has invalid provenance."}])}
	if not parsed.get("header", {}).get("trusted", false):
		return {"ok": false, "errors": [{"code": "SCENE_PROVENANCE_INVALID", "message": "Generated scene is missing trusted UIForge provenance header."}]}
	var verify_path := _verify_temp_path()
	var verify_absolute := ProjectSettings.globalize_path(verify_path)
	DirAccess.make_dir_recursive_absolute(verify_absolute.get_base_dir())
	var copy := FileAccess.open(verify_absolute, FileAccess.WRITE)
	if copy == null:
		return {"ok": false, "errors": [{"code": "VERIFY_WRITE_FAILED", "message": verify_path}]}
	copy.store_string(text)
	copy.close()
	var packed: Variant = ResourceLoader.load(verify_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
	if FileAccess.file_exists(verify_absolute):
		DirAccess.remove_absolute(verify_absolute)
	if packed == null:
		return {"ok": false, "errors": [{"code": "SCENE_SYNTAX_INVALID", "message": "Godot could not parse generated scene."}]}
	return {"ok": true, "errors": []}

static func _verify_temp_path() -> String:
	DirAccess.make_dir_recursive_absolute("user://uiforge_verify")
	return "user://uiforge_verify/verify_%d_%d.tscn" % [Time.get_ticks_usec(), randi()]

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
	var parsed: Variant = _parse_json_text(file.get_as_text())
	file.close()
	return parsed if parsed is Dictionary else {}

static func _cleanup_txn(paths: TxnPaths) -> void:
	for sidecar in [paths.meta, paths.pending]:
		if FileAccess.file_exists(sidecar):
			DirAccess.remove_absolute(sidecar)

static func _cleanup_sidecars(absolute: String) -> void:
	var paths := _transaction_paths(absolute)
	_cleanup_txn(paths)
	if FileAccess.file_exists(paths.backup):
		DirAccess.remove_absolute(paths.backup)

static func recover_interrupted_replace_for_path(target_path: String) -> Dictionary:
	var absolute := UIForgePaths.normalize_requested(target_path)
	if absolute.is_empty():
		return {"ok": false, "status": "conflict", "errors": [{"code": "OUTPUT_PATH_INVALID", "message": target_path}]}
	return _recover_interrupted_replace(absolute)

static func _replace_meta_path(absolute: String) -> String:
	return "%s.uiforge_replace_txn" % absolute

static func _write_replace_meta(meta_path: String, payload: Dictionary) -> void:
	var file := FileAccess.open(meta_path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(payload))
	file.close()

static func _read_replace_meta(meta_path: String) -> Dictionary:
	if not FileAccess.file_exists(meta_path):
		return {}
	var file := FileAccess.open(meta_path, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = _parse_json_text(file.get_as_text())
	file.close()
	return parsed if parsed is Dictionary else {}

static func _cleanup_replace_meta(meta_path: String) -> void:
	if FileAccess.file_exists(meta_path):
		DirAccess.remove_absolute(meta_path)

static func _cleanup_replace_sidecars(absolute: String) -> void:
	_cleanup_replace_meta(_replace_meta_path(absolute))

static func _recover_interrupted_replace(dest_absolute: String) -> Dictionary:
	var backup_path := "%s.uiforge_replace_backup" % dest_absolute
	var meta_path := _replace_meta_path(dest_absolute)
	var meta := _read_replace_meta(meta_path)
	var backup_exists := FileAccess.file_exists(backup_path)
	var dest_exists := FileAccess.file_exists(dest_absolute)
	if not meta.is_empty() and str(meta.get("target", "")) != dest_absolute:
		return _replace_conflict("REPLACE_TXN_INVALID", "Replace transaction target mismatch for %s." % dest_absolute)
	if not dest_exists and backup_exists:
		if meta.is_empty():
			if DirAccess.rename_absolute(backup_path, dest_absolute) != OK:
				return _replace_conflict("REPLACE_RECOVERY_CONFLICT", "Could not restore orphan backup for %s." % dest_absolute)
			return {"ok": true, "status": "recovered", "errors": []}
		var stage := str(meta.get("stage", ""))
		if stage == "backup":
			var valid := _validate_replace_meta(meta, dest_absolute, "backup")
			if not valid.get("ok", false):
				return _replace_conflict(str(valid.get("code", "REPLACE_TXN_INVALID")), str(valid.get("message", "")))
			if str(meta.get("backup_hash", "")) != _file_text_hash(backup_path):
				return _replace_conflict("REPLACE_BACKUP_INVALID", "Replace backup hash mismatch for %s." % dest_absolute)
			if DirAccess.rename_absolute(backup_path, dest_absolute) != OK:
				return _replace_conflict("REPLACE_RECOVERY_CONFLICT", "Could not restore backup for %s." % dest_absolute)
			_cleanup_replace_sidecars(dest_absolute)
			return {"ok": true, "status": "recovered", "errors": []}
		if stage == "commit":
			var valid_commit := _validate_replace_meta(meta, dest_absolute, "commit")
			if not valid_commit.get("ok", false):
				return _replace_conflict(str(valid_commit.get("code", "REPLACE_TXN_INVALID")), str(valid_commit.get("message", "")))
			if str(meta.get("backup_hash", "")) != _file_text_hash(backup_path):
				return _replace_conflict("REPLACE_BACKUP_INVALID", "Replace backup hash mismatch for %s." % dest_absolute)
			if DirAccess.rename_absolute(backup_path, dest_absolute) != OK:
				return _replace_conflict("REPLACE_RECOVERY_CONFLICT", "Could not restore backup for %s." % dest_absolute)
			_cleanup_replace_sidecars(dest_absolute)
			return {"ok": true, "status": "recovered", "errors": []}
		return _replace_conflict("REPLACE_RECOVERY_CONFLICT", "Ambiguous missing destination with backup for %s." % dest_absolute)
	if dest_exists and backup_exists:
		if meta.is_empty():
			return _replace_conflict("REPLACE_RECOVERY_CONFLICT", "Destination and backup exist without metadata for %s." % dest_absolute)
		var stage := str(meta.get("stage", ""))
		if stage == "backup":
			return _replace_conflict("REPLACE_RECOVERY_CONFLICT", "Interrupted backup stage for %s." % dest_absolute)
		if stage in ["commit", "complete"]:
			var valid := _validate_replace_meta(meta, dest_absolute, stage)
			if not valid.get("ok", false):
				return _replace_conflict(str(valid.get("code", "REPLACE_TXN_INVALID")), str(valid.get("message", "")))
			var dest_hash := _file_text_hash(dest_absolute)
			var backup_hash := _file_text_hash(backup_path)
			if dest_hash != str(meta.get("new_hash", "")):
				return _replace_conflict("REPLACE_RECOVERY_CONFLICT", "Committed destination hash mismatch for %s." % dest_absolute)
			if backup_hash != str(meta.get("backup_hash", "")):
				return _replace_conflict("REPLACE_BACKUP_INVALID", "Backup hash mismatch for %s." % dest_absolute)
			DirAccess.remove_absolute(backup_path)
			_cleanup_replace_meta(meta_path)
			return {"ok": true, "status": "clean", "errors": []}
		return _replace_conflict("REPLACE_TXN_INVALID", "Unknown replace stage '%s' for %s." % [stage, dest_absolute])
	if dest_exists and not backup_exists:
		if meta.is_empty():
			return {"ok": true, "status": "clean", "errors": []}
		var stage := str(meta.get("stage", ""))
		if stage == "backup":
			var valid_backup := _validate_replace_meta(meta, dest_absolute, "backup")
			if not valid_backup.get("ok", false):
				return _replace_conflict(str(valid_backup.get("code", "REPLACE_TXN_INVALID")), str(valid_backup.get("message", "")))
			if _file_text_hash(dest_absolute) != str(meta.get("backup_hash", "")):
				return _replace_conflict("REPLACE_BACKUP_INVALID", "Destination hash mismatch for %s." % dest_absolute)
			_cleanup_replace_sidecars(dest_absolute)
			return {"ok": true, "status": "clean", "errors": []}
		if stage in ["commit", "complete"]:
			var valid := _validate_replace_meta(meta, dest_absolute, stage)
			if not valid.get("ok", false):
				return _replace_conflict(str(valid.get("code", "REPLACE_TXN_INVALID")), str(valid.get("message", "")))
			if _file_text_hash(dest_absolute) != str(meta.get("new_hash", "")):
				return _replace_conflict("REPLACE_RECOVERY_CONFLICT", "Destination hash mismatch for %s." % dest_absolute)
			_cleanup_replace_meta(meta_path)
			return {"ok": true, "status": "clean", "errors": []}
		return _replace_conflict("REPLACE_TXN_INVALID", "Stale replace metadata for %s." % dest_absolute)
	if not dest_exists and not backup_exists and not meta.is_empty():
		return _replace_conflict("REPLACE_TXN_INVALID", "Replace metadata without artifacts for %s." % dest_absolute)
	return {"ok": true, "status": "clean", "errors": []}

static func _replace_conflict(code: String, message: String) -> Dictionary:
	return {"ok": false, "status": "conflict", "errors": [{"code": code, "message": message}]}

static func _validate_replace_meta(meta: Dictionary, dest_absolute: String, stage: String) -> Dictionary:
	if str(meta.get("target", "")) != dest_absolute:
		return {"ok": false, "code": "REPLACE_TXN_INVALID", "message": "Replace transaction target mismatch."}
	if str(meta.get("stage", "")) != stage:
		return {"ok": false, "code": "REPLACE_TXN_INVALID", "message": "Replace transaction stage mismatch."}
	if str(meta.get("transaction_id", "")).is_empty() or _transaction_id_regex().search(str(meta.get("transaction_id", ""))) == null:
		return {"ok": false, "code": "REPLACE_TXN_INVALID", "message": "Replace transaction id invalid."}
	for field in ["backup_hash", "new_hash"]:
		var value := str(meta.get(field, ""))
		if value.is_empty() or _hash_regex().search(value) == null:
			return {"ok": false, "code": "REPLACE_TXN_INVALID", "message": "Replace transaction hash metadata invalid."}
	return {"ok": true, "errors": []}

static func _secure_transaction_id() -> String:
	var crypto := Crypto.new()
	return crypto.generate_random_bytes(16).hex_encode()

static func recover_interrupted_source_for_path(target_path: String) -> Dictionary:
	return try_recover_interrupted_source_for_path(target_path)

static func try_recover_interrupted_source_for_path(target_path: String) -> Dictionary:
	var absolute := UIForgePaths.normalize_requested(target_path)
	if absolute.is_empty():
		return {"ok": false, "status": "invalid", "errors": [{"code": "OUTPUT_PATH_INVALID", "message": target_path}]}
	if UIForgeLock.live_lock_held(absolute):
		return {"ok": false, "status": "live_writer", "errors": []}
	var lock := UIForgeLock.acquire(absolute)
	if not lock.get("ok", false):
		if UIForgeLock.live_lock_held(absolute):
			return {"ok": false, "status": "live_writer", "errors": []}
		return {"ok": false, "status": "blocked", "errors": lock.get("errors", [])}
	var lock_path := str(lock.get("lock_path", ""))
	var owner_nonce := str(lock.get("owner_nonce", ""))
	var paths := _transaction_paths(absolute)
	_recover_interrupted_source_locked(absolute, paths)
	_cleanup_completed_transaction(absolute, paths)
	UIForgeLock.release(lock_path, owner_nonce)
	return {"ok": true, "status": "recovered", "errors": []}

static func _recover_interrupted_source_locked(absolute: String, paths: TxnPaths) -> void:
	var meta := _read_txn_meta(paths.meta)
	if FileAccess.file_exists(paths.pending):
		if _pending_may_promote(absolute, paths, meta):
			if FileAccess.file_exists(absolute):
				DirAccess.remove_absolute(absolute)
			var replace_result := replace_file(paths.pending, absolute)
			if not replace_result.get("ok", false) and FileAccess.file_exists(paths.backup):
				DirAccess.rename_absolute(paths.backup, absolute)
		else:
			if FileAccess.file_exists(paths.pending):
				DirAccess.remove_absolute(paths.pending)
	if not FileAccess.file_exists(absolute) and FileAccess.file_exists(paths.backup):
		DirAccess.rename_absolute(paths.backup, absolute)
	_cleanup_txn(paths)

static func _cleanup_completed_transaction(absolute: String, paths: TxnPaths) -> void:
	if not FileAccess.file_exists(absolute):
		return
	var meta := _read_txn_meta(paths.meta)
	if meta.is_empty():
		if FileAccess.file_exists(paths.backup):
			DirAccess.remove_absolute(paths.backup)
		if FileAccess.file_exists(paths.pending):
			DirAccess.remove_absolute(paths.pending)
		return
	var live_revision := _json_revision_from_file(absolute)
	if str(meta.get("new_revision", "")) == live_revision and str(meta.get("stage", "")) == "commit":
		if FileAccess.file_exists(paths.backup):
			DirAccess.remove_absolute(paths.backup)
		_cleanup_txn(paths)

static func _pending_may_promote(absolute: String, paths: TxnPaths, meta: Dictionary) -> bool:
	if meta.is_empty():
		return false
	if str(meta.get("target", "")) != absolute:
		return false
	if not FileAccess.file_exists(paths.pending):
		return false
	var pending_hash := _file_text_hash(paths.pending)
	if str(meta.get("pending_hash", "")) != pending_hash:
		return false
	var stage := str(meta.get("stage", ""))
	if stage != "commit" and FileAccess.file_exists(absolute):
		return false
	if not pending_hash.is_empty() and str(meta.get("new_revision", "")).is_empty():
		return false
	return true

static func _json_revision_from_text(text: String) -> String:
	var parsed: Variant = _parse_json_text(text)
	if parsed is Dictionary:
		return UIForgeHash.content_hash(parsed)
	return ""

static func _parse_json_text(text: String) -> Variant:
	if text.is_empty():
		return null
	var parser := JSON.new()
	if parser.parse(text) != OK:
		return null
	return parser.data

static func _json_revision_from_file(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var revision := _json_revision_from_text(file.get_as_text())
	file.close()
	return revision

static func _file_text_hash(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var hash_value := "sha256:%s" % _sha256_text(file.get_as_text())
	file.close()
	return hash_value

static func _sha256_text(text: String) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(text.to_utf8_buffer())
	return context.finish().hex_encode()

static func _maybe_pause(stage: String) -> void:
	if source_write_pause_hook.is_valid():
		source_write_pause_hook.call(stage)
