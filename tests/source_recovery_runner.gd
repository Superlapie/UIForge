extends SceneTree

const FIXTURE := "res://tests/conformance/fixtures/minimal.ui.json"

var failures: Array[String] = []
var checks: int = 0
var _pause_stage := ""
var _pause_source := ""
var _reader_observation: Dictionary = {}

func _pause_hook(stage: String) -> void:
	if stage != _pause_stage:
		return
	_reader_observation = _observe_reader_recovery(_pause_source)

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	DirAccess.make_dir_recursive_absolute("user://source_recovery")
	_test_live_writer_after_backup()
	_test_live_writer_after_pending()
	_test_live_writer_before_promotion()
	_test_crashed_transaction_recovery()
	_test_reader_waits_for_live_writer()
	_test_unknown_liveness_blocks_recovery()
	if failures.is_empty():
		print(JSON.stringify({"success": true, "passed": checks, "failed": 0}))
		quit(0)
	else:
		print(JSON.stringify({"success": false, "passed": checks - failures.size(), "failed": failures.size(), "failures": failures}))
		quit(1)

func _test_live_writer_after_backup() -> void:
	_run_live_writer_window("after_backup")

func _test_live_writer_after_pending() -> void:
	_run_live_writer_window("after_pending")

func _test_live_writer_before_promotion() -> void:
	_run_live_writer_window("before_promotion")

func _run_live_writer_window(pause_stage: String) -> void:
	var source_res := "user://source_recovery/live_%s.ui.json" % pause_stage
	_prepare_source(source_res)
	var payload := _make_payload("live_%s" % pause_stage)
	_pause_stage = pause_stage
	_pause_source = source_res
	_reader_observation = {}
	UIForgeTransaction.source_write_pause_hook = _pause_hook
	var writer_result := UIForgeTransaction.write_source_atomically(source_res, payload, "")
	UIForgeTransaction.source_write_pause_hook = Callable()
	_assert(bool(writer_result.get("success", false)), "live_%s_writer_success" % pause_stage)
	_assert(not _reader_observation.is_empty(), "live_%s_hook_ran" % pause_stage)
	_assert(str(_reader_observation.get("recovery_status", "")) == "live_writer", "live_%s_recovery_live_writer" % pause_stage)
	_assert(not bool(_reader_observation.get("recovery_mutated", true)), "live_%s_reader_no_recovery" % pause_stage)
	_assert(bool(_reader_observation.get("backup_exists", false)), "live_%s_backup_preserved" % pause_stage)
	if pause_stage != "after_backup":
		_assert(bool(_reader_observation.get("pending_exists", false)), "live_%s_pending_preserved" % pause_stage)
	var final_loaded := UIForgeSerializer.load_document(source_res)
	_assert(final_loaded.get("document") != null, "live_%s_final_parse" % pause_stage)
	_assert(str(final_loaded.get("revision_hash", "")) == UIForgeHash.content_hash(_payload_dict("live_%s" % pause_stage)), "live_%s_final_revision" % pause_stage)
	_assert(not _has_stale_sidecars(source_res), "live_%s_no_sidecars" % pause_stage)

func _test_crashed_transaction_recovery() -> void:
	var source_res := "user://source_recovery/crashed.ui.json"
	_prepare_source(source_res)
	var absolute := ProjectSettings.globalize_path(source_res)
	var paths := _txn_paths(absolute)
	var payload := _make_payload("crashed")
	var file := FileAccess.open(absolute, FileAccess.WRITE)
	file.store_string(payload)
	file.close()
	DirAccess.rename_absolute(absolute, paths.backup)
	var pending := FileAccess.open(paths.pending, FileAccess.WRITE)
	pending.store_string(payload)
	pending.close()
	var meta := FileAccess.open(paths.meta, FileAccess.WRITE)
	meta.store_string(JSON.stringify({
		"transaction_id": "crash-test",
		"target": absolute,
		"expected_revision": "",
		"new_revision": UIForgeHash.content_hash(_payload_dict("crashed")),
		"pending_hash": _file_hash(paths.pending),
		"stage": "commit",
	}))
	meta.close()
	var recovery := UIForgeTransaction.try_recover_interrupted_source_for_path(source_res)
	_assert(str(recovery.get("status", "")) == "recovered", "crashed_recovery_status")
	var loaded := UIForgeSerializer.load_document(source_res)
	_assert(loaded.get("document") != null, "crashed_final_parse")
	_assert(not _has_stale_sidecars(source_res), "crashed_no_sidecars")

func _test_reader_waits_for_live_writer() -> void:
	var source_res := "user://source_recovery/wait.ui.json"
	_prepare_source(source_res)
	var absolute := ProjectSettings.globalize_path(source_res)
	var payload := _make_payload("wait")
	var paths := _txn_paths(absolute)
	var lock := UIForgeLock.acquire(absolute)
	_assert(bool(lock.get("ok", false)), "wait_lock_acquired")
	var lock_path := str(lock.get("lock_path", ""))
	var owner_nonce := str(lock.get("owner_nonce", ""))
	DirAccess.rename_absolute(absolute, paths.backup)
	var godot_bin := "godot"
	if OS.has_environment("GODOT_BIN"):
		godot_bin = OS.get_environment("GODOT_BIN")
	var project := ProjectSettings.globalize_path("res://")
	var worker := ProjectSettings.globalize_path("res://tests/source_recovery_reader_worker.gd")
	var pid := OS.create_process(godot_bin, ["--headless", "--path", project, "--script", worker, "--", source_res])
	OS.delay_msec(20)
	_assert(UIForgeLock.lock_blocks_recovery(absolute), "wait_lock_blocks_recovery")
	var pending := FileAccess.open(paths.pending, FileAccess.WRITE)
	pending.store_string(payload)
	pending.close()
	DirAccess.rename_absolute(paths.pending, absolute)
	DirAccess.remove_absolute(paths.backup)
	UIForgeLock.release(lock_path, owner_nonce)
	while OS.is_process_running(pid):
		OS.delay_msec(5)
	var result_path := "%s.reader_result" % absolute
	_assert(FileAccess.file_exists(result_path), "wait_reader_result_exists")
	var result_text := FileAccess.get_file_as_string(result_path)
	var parsed: Variant = JSON.parse_string(result_text)
	_assert(parsed is Dictionary, "wait_reader_result_json")
	_assert(bool(parsed.get("success", false)), "wait_reader_got_document")
	_assert(str(parsed.get("revision_hash", "")) == UIForgeHash.content_hash(_payload_dict("wait")), "wait_reader_revision")
	DirAccess.remove_absolute(result_path)

func _test_unknown_liveness_blocks_recovery() -> void:
	var source_res := "user://source_recovery/unknown_liveness.ui.json"
	_prepare_source(source_res)
	var absolute := ProjectSettings.globalize_path(source_res)
	var paths := _txn_paths(absolute)
	var lock := UIForgeLock.acquire(absolute)
	_assert(bool(lock.get("ok", false)), "unknown_lock_acquired")
	var lock_path := str(lock.get("lock_path", ""))
	var owner_nonce := str(lock.get("owner_nonce", ""))
	DirAccess.rename_absolute(absolute, paths.backup)
	UIForgeProcess.pid_alive_status_hook = func(_meta: Dictionary) -> UIForgeProcess.AliveStatus:
		return UIForgeProcess.AliveStatus.UNKNOWN
	var recovery := UIForgeTransaction.try_recover_interrupted_source_for_path(source_res)
	_assert(str(recovery.get("status", "")) == "live_writer", "unknown_recovery_live_writer")
	_assert(FileAccess.file_exists(paths.backup), "unknown_backup_preserved")
	_assert(DirAccess.dir_exists_absolute(lock_path), "unknown_lock_preserved")
	var load_result := UIForgeSerializer.load_document(source_res)
	var load_code := ""
	if load_result.get("errors") is Array and not load_result.errors.is_empty():
		load_code = str(load_result.errors[0].get("code", ""))
	_assert(load_code == "SOURCE_WRITE_IN_PROGRESS", "unknown_load_write_in_progress")
	_assert(FileAccess.file_exists(paths.backup), "unknown_backup_after_load")
	_assert(not FileAccess.file_exists(absolute), "unknown_source_still_absent")
	UIForgeProcess.pid_alive_status_hook = Callable()
	UIForgeLock.release(lock_path, owner_nonce)
	UIForgeProcess.pid_alive_status_hook = func(_meta: Dictionary) -> UIForgeProcess.AliveStatus:
		return UIForgeProcess.AliveStatus.DEAD
	var payload := _make_payload("unknown_dead_recovery")
	var pending := FileAccess.open(paths.pending, FileAccess.WRITE)
	pending.store_string(payload)
	pending.close()
	var meta := FileAccess.open(paths.meta, FileAccess.WRITE)
	meta.store_string(JSON.stringify({
		"transaction_id": "unknown-dead",
		"target": absolute,
		"expected_revision": "",
		"new_revision": UIForgeHash.content_hash(_payload_dict("unknown_dead_recovery")),
		"pending_hash": _file_hash(paths.pending),
		"stage": "commit",
	}))
	meta.close()
	var dead_recovery := UIForgeTransaction.try_recover_interrupted_source_for_path(source_res)
	_assert(str(dead_recovery.get("status", "")) == "recovered", "unknown_dead_recovery_status")
	UIForgeProcess.pid_alive_status_hook = Callable()
	var loaded := UIForgeSerializer.load_document(source_res)
	_assert(loaded.get("document") != null, "unknown_dead_final_parse")
	_assert(not _has_stale_sidecars(source_res), "unknown_dead_no_sidecars")

func _observe_reader_recovery(source_res: String) -> Dictionary:
	var recovery := UIForgeTransaction.try_recover_interrupted_source_for_path(source_res)
	var absolute := ProjectSettings.globalize_path(source_res)
	var paths := _txn_paths(absolute)
	return {
		"recovery_status": str(recovery.get("status", "")),
		"recovery_mutated": str(recovery.get("status", "")) == "recovered",
		"backup_exists": FileAccess.file_exists(paths.backup),
		"pending_exists": FileAccess.file_exists(paths.pending),
		"meta_exists": FileAccess.file_exists(paths.meta),
	}

func _prepare_source(source_res: String) -> void:
	var absolute := ProjectSettings.globalize_path(source_res)
	_cleanup_source(source_res)
	DirAccess.copy_absolute(ProjectSettings.globalize_path(FIXTURE), absolute)

func _cleanup_source(source_res: String) -> void:
	var absolute := ProjectSettings.globalize_path(source_res)
	for suffix in [".uiforge_backup", ".uiforge_pending", ".uiforge_txn", ".uiforge_lock", ".uiforge_reclaim_guard", ".reader_result"]:
		var sidecar := "%s%s" % [absolute, suffix]
		if FileAccess.file_exists(sidecar):
			DirAccess.remove_absolute(sidecar)
		if DirAccess.dir_exists_absolute(sidecar):
			UIForgeLock.release(sidecar, "")
	if FileAccess.file_exists(absolute):
		DirAccess.remove_absolute(absolute)

func _has_stale_sidecars(source_res: String) -> bool:
	var absolute := ProjectSettings.globalize_path(source_res)
	for suffix in [".uiforge_backup", ".uiforge_pending", ".uiforge_txn", ".uiforge_reclaim_guard"]:
		if FileAccess.file_exists("%s%s" % [absolute, suffix]):
			return true
	return DirAccess.dir_exists_absolute("%s.uiforge_lock" % absolute)

func _txn_paths(absolute: String) -> Dictionary:
	return {
		"backup": "%s.uiforge_backup" % absolute,
		"pending": "%s.uiforge_pending" % absolute,
		"meta": "%s.uiforge_txn" % absolute,
	}

func _payload_dict(label: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE))
	if parsed is Dictionary:
		var copy: Dictionary = parsed.duplicate(true)
		copy["name"] = label
		return copy
	return {}

func _make_payload(label: String) -> String:
	return JSON.stringify(_payload_dict(label), "\t") + "\n"

func _file_hash(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(file.get_as_text().to_utf8_buffer())
	file.close()
	return "sha256:%s" % context.finish().hex_encode()

func _assert(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)
