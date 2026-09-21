class_name UIForgeLock
extends RefCounted

const STALE_SECONDS: int = 300

static func acquire(target_absolute: String) -> Dictionary:
	var lock_path := "%s.uiforge_lock" % target_absolute
	for attempt in 4:
		if not FileAccess.file_exists(lock_path):
			var token_path := UIForgeTransaction.unique_temp_path(lock_path, ".lock")
			var file := FileAccess.open(token_path, FileAccess.WRITE)
			if file == null:
				return {"ok": false, "errors": [{"code": "LOCK_CREATE_FAILED", "message": lock_path}]}
			file.store_string(JSON.stringify({
				"pid": OS.get_process_id(),
				"started": Time.get_unix_time_from_system(),
			}))
			file.flush()
			file.close()
			if DirAccess.rename_absolute(token_path, lock_path) == OK:
				return {"ok": true, "lock_path": lock_path}
			if FileAccess.file_exists(token_path):
				DirAccess.remove_absolute(token_path)
		elif _lock_is_stale(lock_path):
			DirAccess.remove_absolute(lock_path)
			continue
		OS.delay_msec(25 * (attempt + 1))
	return {
		"ok": false,
		"errors": [{
			"code": "WRITE_CONFLICT",
			"message": "Could not acquire commit lock for %s." % target_absolute,
			"path": target_absolute,
		}],
	}

static func release(lock_path: String) -> void:
	if not lock_path.is_empty() and FileAccess.file_exists(lock_path):
		DirAccess.remove_absolute(lock_path)

static func _lock_is_stale(lock_path: String) -> bool:
	var file := FileAccess.open(lock_path, FileAccess.READ)
	if file == null:
		return true
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not parsed is Dictionary:
		return true
	var started := int(parsed.get("started", 0))
	if started <= 0:
		return true
	return Time.get_unix_time_from_system() - started > STALE_SECONDS
