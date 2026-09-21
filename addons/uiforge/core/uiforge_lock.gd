class_name UIForgeLock
extends RefCounted

const STALE_SECONDS: int = 300
const NEW_LOCK_GRACE_SECONDS: int = 5

static func acquire(target_absolute: String) -> Dictionary:
	var lock_dir := "%s.uiforge_lock" % target_absolute
	var owner_nonce := _random_nonce()
	for attempt in 4:
		var created := _try_create_lock_dir(lock_dir, owner_nonce)
		if created.get("ok", false):
			return created
		if _try_reclaim_stale_lock(lock_dir):
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

static func _try_create_lock_dir(lock_dir: String, owner_nonce: String) -> Dictionary:
	var err := DirAccess.make_dir_absolute(lock_dir)
	if err == OK:
		var meta := {
			"owner_nonce": owner_nonce,
			"pid": OS.get_process_id(),
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

static func _try_reclaim_stale_lock(lock_dir: String) -> bool:
	if not DirAccess.dir_exists_absolute(lock_dir):
		return false
	var meta := _read_lock_meta(lock_dir)
	var started := int(meta.get("started", 0))
	var age := Time.get_unix_time_from_system() - started if started > 0 else NEW_LOCK_GRACE_SECONDS + 1
	if age < NEW_LOCK_GRACE_SECONDS:
		return false
	if not meta.is_empty():
		var pid := int(meta.get("pid", 0))
		if pid > 0 and _pid_alive(pid) and age < STALE_SECONDS:
			return false
	if age < STALE_SECONDS and meta.is_empty():
		return false
	var expected_nonce := str(meta.get("owner_nonce", ""))
	var reclaim_path := "%s.reclaim_%s" % [lock_dir, _random_nonce()]
	if DirAccess.rename_absolute(lock_dir, reclaim_path) != OK:
		return false
	var reclaimed_meta := _read_lock_meta(reclaim_path)
	if str(reclaimed_meta.get("owner_nonce", "")) != expected_nonce:
		DirAccess.rename_absolute(reclaim_path, lock_dir)
		return false
	_remove_lock_dir(reclaim_path)
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
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed if parsed is Dictionary else {}

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

static func _pid_alive(pid: int) -> bool:
	if pid <= 0:
		return false
	if OS.get_name() == "Windows":
		return true
	return DirAccess.dir_exists_absolute("/proc/%d" % pid)

static func _random_nonce() -> String:
	return "%d_%d_%d" % [Time.get_unix_time_from_system(), Time.get_ticks_usec(), randi()]
