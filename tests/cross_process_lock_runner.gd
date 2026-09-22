extends SceneTree

const DEFAULT_ITERATIONS := 25

func _init() -> void:
	_run()

func _iteration_count() -> int:
	if OS.has_environment("UIFORGE_CROSS_PROCESS_ITERATIONS"):
		return max(1, int(OS.get_environment("UIFORGE_CROSS_PROCESS_ITERATIONS")))
	return DEFAULT_ITERATIONS

func _run() -> void:
	var failures: Array = []
	var iterations := _iteration_count()
	DirAccess.make_dir_recursive_absolute("user://cross_process_lock")
	var godot_bin := "godot"
	if OS.has_environment("GODOT_BIN"):
		godot_bin = OS.get_environment("GODOT_BIN")
	var project := ProjectSettings.globalize_path("res://")
	var worker := ProjectSettings.globalize_path("res://tests/cross_process_lock_worker.gd")
	var fixture := "res://tests/conformance/fixtures/minimal.ui.json"
	for iteration in range(iterations):
		var source_res := "user://cross_process_lock/race_%d.ui.json" % iteration
		var source_abs := ProjectSettings.globalize_path(source_res)
		DirAccess.copy_absolute(ProjectSettings.globalize_path(fixture), source_abs)
		var revision_result := UIForgeHash.file_revision(source_res)
		if not revision_result.get("ok", false):
			failures.append(_failure_record(iteration, source_abs, {}, {}, "revision_failed"))
			continue
		var revision := str(revision_result.get("hash", ""))
		var pid_a := OS.create_process(godot_bin, ["--headless", "--path", project, "--script", worker, "--", source_res, revision, "A"])
		var pid_b := OS.create_process(godot_bin, ["--headless", "--path", project, "--script", worker, "--", source_res, revision, "B"])
		while OS.is_process_running(pid_a) or OS.is_process_running(pid_b):
			OS.delay_msec(5)
		OS.delay_msec(25)
		var result_a := _read_result_file(source_abs, "A")
		var result_b := _read_result_file(source_abs, "B")
		if result_a.is_empty() or result_b.is_empty():
			failures.append(_failure_record(iteration, source_abs, {"raw": result_a}, {"raw": result_b}, "missing_result_files"))
			continue
		var parsed_a = _parse_result_json(result_a)
		var parsed_b = _parse_result_json(result_b)
		if not parsed_a is Dictionary or not parsed_b is Dictionary:
			failures.append(_failure_record(iteration, source_abs, parsed_a, parsed_b, "bad_result_json"))
			continue
		var successes := int(parsed_a.get("success", false)) + int(parsed_b.get("success", false))
		if successes != 1:
			failures.append(_failure_record(iteration, source_abs, parsed_a, parsed_b, "success_count_%d" % successes))
		var loaded := UIForgeSerializer.load_document(source_res)
		if loaded.get("document") == null:
			failures.append(_failure_record(iteration, source_abs, parsed_a, parsed_b, "invalid_json", loaded))
		for suffix in [".uiforge_backup", ".uiforge_pending", ".uiforge_txn", ".result_A", ".result_B", ".uiforge_reclaim_guard"]:
			if FileAccess.file_exists("%s%s" % [source_abs, suffix]):
				if suffix.ends_with("_A") or suffix.ends_with("_B"):
					DirAccess.remove_absolute("%s%s" % [source_abs, suffix])
					continue
				failures.append(_failure_record(iteration, source_abs, parsed_a, parsed_b, "stale_%s" % suffix.trim_prefix(".")))
		if DirAccess.dir_exists_absolute("%s.uiforge_lock" % source_abs):
			failures.append(_failure_record(iteration, source_abs, parsed_a, parsed_b, "stale_lock"))
		else:
			for marker in ["A", "B"]:
				var result_path := "%s.result_%s" % [source_abs, marker]
				if FileAccess.file_exists(result_path):
					DirAccess.remove_absolute(result_path)
	if failures.is_empty():
		print(JSON.stringify({"success": true, "iterations": iterations}))
		quit(0)
	else:
		print(JSON.stringify({"success": false, "iterations": iterations, "failures": failures}))
		quit(1)

func _failure_record(iteration: int, source_abs: String, result_a: Variant, result_b: Variant, reason: String, loaded: Dictionary = {}) -> Dictionary:
	var canonical_exists := FileAccess.file_exists(source_abs)
	var canonical_bytes := 0
	var canonical_sha256 := ""
	var json_error := ""
	var json_line := -1
	if canonical_exists:
		var file := FileAccess.open(source_abs, FileAccess.READ)
		if file != null:
			var text := file.get_as_text()
			canonical_bytes = text.to_utf8_buffer().size()
			var context := HashingContext.new()
			context.start(HashingContext.HASH_SHA256)
			context.update(text.to_utf8_buffer())
			canonical_sha256 = context.finish().hex_encode()
			file.close()
			var parser := JSON.new()
			if parser.parse(text) != OK:
				json_error = parser.get_error_message()
				json_line = parser.get_error_line()
	elif loaded.get("errors") is Array and not loaded.errors.is_empty():
		json_error = str(loaded.errors[0].get("message", ""))
		json_line = int(loaded.errors[0].get("line", -1))
	return {
		"iteration": iteration,
		"reason": reason,
		"result_a": result_a,
		"result_b": result_b,
		"canonical_exists": canonical_exists,
		"canonical_byte_length": canonical_bytes,
		"canonical_sha256": canonical_sha256,
		"json_error": json_error,
		"json_line": json_line,
		"lock_dir_exists": DirAccess.dir_exists_absolute("%s.uiforge_lock" % source_abs),
		"backup_exists": FileAccess.file_exists("%s.uiforge_backup" % source_abs),
		"backup_sha256": _file_sha256("%s.uiforge_backup" % source_abs),
		"pending_exists": FileAccess.file_exists("%s.uiforge_pending" % source_abs),
		"pending_sha256": _file_sha256("%s.uiforge_pending" % source_abs),
		"transaction_meta": _read_text_if_exists("%s.uiforge_txn" % source_abs),
		"reclaim_guard_exists": FileAccess.file_exists("%s.uiforge_reclaim_guard" % source_abs),
	}

func _file_sha256(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(file.get_buffer(file.get_length()))
	file.close()
	return context.finish().hex_encode()

func _read_text_if_exists(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text := file.get_as_text()
	file.close()
	return text

func _read_result_file(source_abs: String, marker: String) -> String:
	var path := "%s.result_%s" % [source_abs, marker]
	if not FileAccess.file_exists(path):
		return ""
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text := file.get_as_text()
	file.close()
	return text

func _parse_result_json(text: String) -> Variant:
	if text.is_empty():
		return null
	var parser := JSON.new()
	if parser.parse(text) != OK:
		return null
	return parser.data
