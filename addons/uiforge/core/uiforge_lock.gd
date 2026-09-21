class_name UIForgeLock
extends RefCounted

const NEW_LOCK_GRACE_SECONDS: int = 5

static func acquire(target_absolute: String) -> Dictionary:
	var lock_dir := "%s.uiforge_lock" % target_absolute
	var owner_nonce := _secure_nonce()
	var process_identity := UIForgeProcess.current_process_identity()
	for attempt in 4:
		if DirAccess.dir_exists_absolute(_reclaim_guard_path(target_absolute)):
			OS.delay_msec(25 * (attempt + 1))
			continue
		var created := _try_create_lock_dir(lock_dir, owner_nonce, process_identity)
		if created.get("ok", false):
			return created
		if _try_reclaim_stale_lock(lock_dir, target_absolute):
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

static func release(lock_path: String, owner_nonce: String) -> void:
	if lock_path.is_empty() or owner_nonce.is_empty():
		return
	if not DirAccess.dir_exists_absolute(lock_path):
		return
	var meta := _read_lock_meta(lock_path)
	if str(meta.get("owner_nonce", "")) != owner_nonce:
		return
	_remove_lock_dir(lock_path)

static func reclaim_guard_path(target_absolute: String) -> String:
	return _reclaim_guard_path(target_absolute)

static func lock_is_stale(lock_dir: String) -> bool:
	return _lock_is_stale(lock_dir)

static func try_reclaim_stale_lock_verified(lock_dir: String, expected_nonce: String) -> bool:
	return _reclaim_lock_verified(lock_dir, expected_nonce)

static func reclaim_stale_lock(lock_dir: String, target_absolute: String) -> bool:
	return _try_reclaim_stale_lock(lock_dir, target_absolute)

static func _reclaim_guard_path(target_absolute: String) -> String:
	return "%s.uiforge_reclaim_guard" % target_absolute

static func _acquire_reclaim_guard(target_absolute: String) -> bool:
	var guard := _reclaim_guard_path(target_absolute)
	if DirAccess.dir_exists_absolute(guard):
		return false
	return DirAccess.make_dir_absolute(guard) == OK

static func _release_reclaim_guard(target_absolute: String) -> void:
	var guard := _reclaim_guard_path(target_absolute)
	if DirAccess.dir_exists_absolute(guard):
		DirAccess.remove_absolute(guard)

static func _try_create_lock_dir(lock_dir: String, owner_nonce: String, process_identity: Dictionary) -> Dictionary:
	var target_absolute := lock_dir.trim_suffix(".uiforge_lock")
	if DirAccess.dir_exists_absolute(_reclaim_guard_path(target_absolute)):
		return {"ok": false}
	var err := DirAccess.make_dir_absolute(lock_dir)
	if err == OK:
		var meta := {
			"owner_nonce": owner_nonce,
			"pid": OS.get_process_id(),
			"process_start": str(process_identity.get("start_ticks", "")),
			"started": Time.get_unix_time_from_system(),
			"hostname": OS.get_environment("HOSTNAME") if OS.has_environment("HOSTNAME") else "",
		}
		if not _write_lock_meta(lock_dir, meta):
			_remove_lock_dir(lock_dir)
			return {"ok": false}
		return {"ok": true, "lock_path": lock_dir, "owner_nonce": owner_nonce}
	if err == ERR_ALREADY_EXISTS:
		return {"ok": false}
	return {"ok": false, "errors": [{"code": "LOCK_CREATE_FAILED", "message": lock_dir}]}

static func _try_reclaim_stale_lock(lock_dir: String, target_absolute: String) -> bool:
	if not _acquire_reclaim_guard(target_absolute):
		return false
	if not _lock_is_stale(lock_dir):
		_release_reclaim_guard(target_absolute)
		return false
	var meta := _read_lock_meta(lock_dir)
	var expected_nonce := str(meta.get("owner_nonce", ""))
	if expected_nonce.is_empty():
		_release_reclaim_guard(target_absolute)
		return false
	if not _lock_is_stale(lock_dir):
		_release_reclaim_guard(target_absolute)
		return false
	var reclaimed := _reclaim_lock_verified(lock_dir, expected_nonce)
	_release_reclaim_guard(target_absolute)
	return reclaimed

static func _reclaim_lock_verified(lock_dir: String, expected_nonce: String) -> bool:
	if not DirAccess.dir_exists_absolute(lock_dir):
		return false
	var reclaim_path := "%s.reclaim_%s" % [lock_dir, _secure_nonce()]
	if DirAccess.rename_absolute(lock_dir, reclaim_path) != OK:
		return false
	var reclaimed_meta := _read_lock_meta(reclaim_path)
	if str(reclaimed_meta.get("owner_nonce", "")) != expected_nonce:
		DirAccess.rename_absolute(reclaim_path, lock_dir)
		return false
	_remove_lock_dir(reclaim_path)
	return true

static func _lock_is_stale(lock_dir: String) -> bool:
	if not DirAccess.dir_exists_absolute(lock_dir):
		return false
	var meta := _read_lock_meta(lock_dir)
	var started := int(meta.get("started", 0))
	var age := Time.get_unix_time_from_system() - started if started > 0 else NEW_LOCK_GRACE_SECONDS + 1
	if age < NEW_LOCK_GRACE_SECONDS:
		return false
	if meta.is_empty():
		return true
	var alive_status := UIForgeProcess.pid_alive(meta)
	if alive_status == UIForgeProcess.AliveStatus.ALIVE:
		return false
	if alive_status == UIForgeProcess.AliveStatus.UNKNOWN:
		return false
	return true

static func _write_lock_meta(lock_dir: String, meta: Dictionary) -> bool:
	var file := FileAccess.open("%s/owner.json" % lock_dir, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(meta))
	file.flush()
	file.close()
	return true

static func _read_lock_meta(lock_dir: String) -> Dictionary:
	var file := FileAccess.open("%s/owner.json" % lock_dir, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = _parse_json_text(file.get_as_text())
	file.close()
	return parsed if parsed is Dictionary else {}

static func _parse_json_text(text: String) -> Variant:
	if text.is_empty():
		return null
	var parser := JSON.new()
	if parser.parse(text) != OK:
		return null
	return parser.data

static func _remove_lock_dir(lock_dir: String) -> void:
	if not DirAccess.dir_exists_absolute(lock_dir):
		return
	var dir := DirAccess.open(lock_dir)
	if dir != null:
		dir.list_dir_begin()
		var entry := dir.get_next()
		while not entry.is_empty():
			if not dir.current_is_dir():
				dir.remove(entry)
			entry = dir.get_next()
		dir.list_dir_end()
	DirAccess.remove_absolute(lock_dir)

static func _secure_nonce() -> String:
	var crypto := Crypto.new()
	return crypto.generate_random_bytes(16).hex_encode()
