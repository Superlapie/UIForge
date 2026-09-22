class_name UIForgeLock
extends RefCounted

const NEW_LOCK_GRACE_SECONDS: int = 5

static var publication_recovery_interleave_hook: Callable = Callable()

static func acquire(target_absolute: String) -> Dictionary:
	var lock_dir := "%s.uiforge_lock" % target_absolute
	var owner_nonce := _secure_nonce()
	var process_identity := UIForgeProcess.current_process_identity()
	for attempt in 4:
		if not _ensure_reclaim_guard_clear(target_absolute):
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
	var meta := _read_owner_meta(lock_path)
	if str(meta.get("owner_nonce", "")) != owner_nonce:
		return
	_remove_lock_dir(lock_path)

static func reclaim_guard_path(target_absolute: String) -> String:
	return _reclaim_guard_path(target_absolute)

static func lock_is_stale(lock_dir: String) -> bool:
	return _lock_is_stale(lock_dir)

static func guard_is_stale(guard_dir: String) -> bool:
	return _guard_is_stale(guard_dir)

static func directory_age_seconds(lock_dir: String) -> float:
	return _directory_age_seconds(lock_dir)

static func publication_is_initializing(lock_dir: String) -> bool:
	return DirAccess.dir_exists_absolute(lock_dir) and _directory_age_seconds(lock_dir) < float(NEW_LOCK_GRACE_SECONDS)

static func try_reclaim_stale_lock_verified(lock_dir: String, expected_nonce: String) -> bool:
	return _reclaim_lock_verified(lock_dir, expected_nonce)

static func reclaim_stale_lock(lock_dir: String, target_absolute: String) -> bool:
	return _try_reclaim_stale_lock(lock_dir, target_absolute)

static func begin_reclaim_guard(target_absolute: String) -> Dictionary:
	return _begin_reclaim_guard(target_absolute)

static func release_reclaim_guard(target_absolute: String, guard_nonce: String) -> void:
	_release_reclaim_guard_owned(target_absolute, guard_nonce)

static func reclaim_stale_guard(guard_dir: String, target_absolute: String) -> bool:
	return _reclaim_stale_guard_verified(guard_dir, target_absolute)

static func reclaim_abandoned_publication(lock_dir: String) -> bool:
	return _reclaim_abandoned_publication(lock_dir)

static func _reclaim_guard_path(target_absolute: String) -> String:
	return "%s.uiforge_reclaim_guard" % target_absolute

static func _ensure_reclaim_guard_clear(target_absolute: String) -> bool:
	var guard := _reclaim_guard_path(target_absolute)
	if not DirAccess.dir_exists_absolute(guard):
		return true
	if _guard_is_stale(guard):
		return _reclaim_stale_guard_verified(guard, target_absolute)
	return false

static func _begin_reclaim_guard(target_absolute: String) -> Dictionary:
	if not _ensure_reclaim_guard_clear(target_absolute):
		return {"ok": false}
	var guard := _reclaim_guard_path(target_absolute)
	var guard_nonce := _secure_nonce()
	var process_identity := UIForgeProcess.current_process_identity()
	if DirAccess.make_dir_absolute(guard) != OK:
		return {"ok": false}
	if not _write_owner_meta(guard, guard_nonce, process_identity):
		_remove_lock_dir(guard)
		return {"ok": false}
	return {"ok": true, "guard_nonce": guard_nonce, "guard_path": guard}

static func _release_reclaim_guard_owned(target_absolute: String, guard_nonce: String) -> void:
	var guard := _reclaim_guard_path(target_absolute)
	if guard_nonce.is_empty() or not DirAccess.dir_exists_absolute(guard):
		return
	var meta := _read_owner_meta(guard)
	if str(meta.get("owner_nonce", "")) != guard_nonce:
		return
	_remove_lock_dir(guard)

static func _reclaim_stale_guard_verified(guard_dir: String, target_absolute: String) -> bool:
	if not DirAccess.dir_exists_absolute(guard_dir):
		return true
	if not _guard_is_stale(guard_dir):
		return false
	return _reclaim_stale_directory(guard_dir)

static func _guard_is_stale(guard_dir: String) -> bool:
	return _lock_is_stale(guard_dir)

static func _try_create_lock_dir(lock_dir: String, owner_nonce: String, process_identity: Dictionary) -> Dictionary:
	var err := DirAccess.make_dir_absolute(lock_dir)
	if err == OK:
		if not _write_owner_meta(lock_dir, owner_nonce, process_identity):
			_remove_lock_dir(lock_dir)
			return {"ok": false}
		return {"ok": true, "lock_path": lock_dir, "owner_nonce": owner_nonce}
	if err == ERR_ALREADY_EXISTS:
		return {"ok": false}
	return {"ok": false, "errors": [{"code": "LOCK_CREATE_FAILED", "message": lock_dir}]}

static func _try_reclaim_stale_lock(lock_dir: String, target_absolute: String) -> bool:
	var guard := _begin_reclaim_guard(target_absolute)
	if not guard.get("ok", false):
		return false
	var guard_nonce := str(guard.get("guard_nonce", ""))
	var reclaimed := false
	if _lock_is_stale(lock_dir):
		reclaimed = _reclaim_stale_directory(lock_dir)
	_release_reclaim_guard_owned(target_absolute, guard_nonce)
	return reclaimed

static func _reclaim_stale_directory(lock_dir: String) -> bool:
	if not _lock_is_stale(lock_dir):
		return false
	var meta := _read_owner_meta(lock_dir)
	if _owner_meta_valid(meta):
		return _reclaim_lock_verified(lock_dir, str(meta.get("owner_nonce", "")))
	return _reclaim_abandoned_publication(lock_dir)

static func _reclaim_lock_verified(lock_dir: String, expected_nonce: String) -> bool:
	if expected_nonce.is_empty() or not DirAccess.dir_exists_absolute(lock_dir):
		return false
	var reclaim_path := "%s.reclaim_%s" % [lock_dir, _secure_nonce()]
	if DirAccess.rename_absolute(lock_dir, reclaim_path) != OK:
		return false
	var reclaimed_meta := _read_owner_meta(reclaim_path)
	if str(reclaimed_meta.get("owner_nonce", "")) != expected_nonce:
		DirAccess.rename_absolute(reclaim_path, lock_dir)
		return false
	_remove_lock_dir(reclaim_path)
	return true

static func _reclaim_abandoned_publication(lock_dir: String) -> bool:
	if not DirAccess.dir_exists_absolute(lock_dir):
		return true
	var reclaim_path := "%s.reclaim_%s" % [lock_dir, _secure_nonce()]
	if DirAccess.rename_absolute(lock_dir, reclaim_path) != OK:
		return false
	if publication_recovery_interleave_hook.is_valid():
		publication_recovery_interleave_hook.call(reclaim_path, lock_dir)
	var reclaimed_meta := _read_owner_meta(reclaim_path)
	if _owner_meta_valid(reclaimed_meta):
		var alive_status := UIForgeProcess.pid_alive(reclaimed_meta)
		if alive_status == UIForgeProcess.AliveStatus.ALIVE or alive_status == UIForgeProcess.AliveStatus.UNKNOWN:
			if not DirAccess.dir_exists_absolute(lock_dir):
				DirAccess.rename_absolute(reclaim_path, lock_dir)
			return false
		return _reclaim_lock_verified(reclaim_path, str(reclaimed_meta.get("owner_nonce", "")))
	_remove_lock_dir(reclaim_path)
	return true

static func _lock_is_stale(lock_dir: String) -> bool:
	if not DirAccess.dir_exists_absolute(lock_dir):
		return false
	var dir_age := _directory_age_seconds(lock_dir)
	var meta := _read_owner_meta(lock_dir)
	if not _owner_meta_valid(meta):
		if dir_age < float(NEW_LOCK_GRACE_SECONDS):
			return false
		return true
	var started := int(meta.get("started", 0))
	var age := Time.get_unix_time_from_system() - started if started > 0 else dir_age
	if age < NEW_LOCK_GRACE_SECONDS:
		return false
	var alive_status := UIForgeProcess.pid_alive(meta)
	if alive_status == UIForgeProcess.AliveStatus.ALIVE:
		return false
	if alive_status == UIForgeProcess.AliveStatus.UNKNOWN:
		return false
	return true

static func _owner_meta_valid(meta: Dictionary) -> bool:
	if meta.is_empty():
		return false
	if str(meta.get("owner_nonce", "")).is_empty():
		return false
	return meta.has("pid")

static func _directory_age_seconds(lock_dir: String) -> float:
	if not DirAccess.dir_exists_absolute(lock_dir):
		return 0.0
	var modified := FileAccess.get_modified_time(lock_dir)
	if modified <= 0:
		var output: Array = []
		if OS.get_name() == "Windows":
			var ps := "(Get-Item -LiteralPath '%s').LastWriteTimeUtc.ToUnixTimeSeconds()" % lock_dir.replace("'", "''")
			if OS.execute("powershell.exe", ["-NoProfile", "-Command", ps], output, true, false) == 0 and not output.is_empty():
				modified = int(str(output[0]).strip_edges())
		elif OS.execute("stat", ["-c", "%Y", lock_dir], output, true, false) == 0 and not output.is_empty():
			modified = int(str(output[0]).strip_edges())
	if modified <= 0:
		return 0.0
	var age := float(Time.get_unix_time_from_system()) - float(modified)
	return max(0.0, age)

static func _write_owner_meta(lock_dir: String, owner_nonce: String, process_identity: Dictionary = {}) -> bool:
	var identity := process_identity if not process_identity.is_empty() else UIForgeProcess.current_process_identity()
	var meta := {
		"owner_nonce": owner_nonce,
		"pid": OS.get_process_id(),
		"process_start": str(identity.get("start_ticks", "")),
		"started": Time.get_unix_time_from_system(),
		"hostname": OS.get_environment("HOSTNAME") if OS.has_environment("HOSTNAME") else "",
	}
	var file := FileAccess.open("%s/owner.json" % lock_dir, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(meta))
	file.flush()
	file.close()
	return true

static func _read_owner_meta(lock_dir: String) -> Dictionary:
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
