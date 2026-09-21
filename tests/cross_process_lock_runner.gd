extends SceneTree

const ITERATIONS := 25

func _init() -> void:
	_run()

func _run() -> void:
	var failures: Array[String] = []
	DirAccess.make_dir_recursive_absolute("user://cross_process_lock")
	var godot_bin := "godot"
	if OS.has_environment("GODOT_BIN"):
		godot_bin = OS.get_environment("GODOT_BIN")
	var project := ProjectSettings.globalize_path("res://")
	var worker := ProjectSettings.globalize_path("res://tests/cross_process_lock_worker.gd")
	var fixture := "res://tests/conformance/fixtures/minimal.ui.json"
	for iteration in range(ITERATIONS):
		var source_res := "user://cross_process_lock/race_%d.ui.json" % iteration
		var source_abs := ProjectSettings.globalize_path(source_res)
		DirAccess.copy_absolute(ProjectSettings.globalize_path(fixture), source_abs)
		var revision_result := UIForgeHash.file_revision(source_res)
		if not revision_result.get("ok", false):
			failures.append("iteration_%d_revision_failed" % iteration)
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
			failures.append("iteration_%d_missing_result_files" % iteration)
			continue
		var parsed_a = _parse_result_json(result_a)
		var parsed_b = _parse_result_json(result_b)
		if not parsed_a is Dictionary or not parsed_b is Dictionary:
			failures.append("iteration_%d_bad_result_json" % iteration)
			continue
		var successes := int(parsed_a.get("success", false)) + int(parsed_b.get("success", false))
		if successes != 1:
			failures.append("iteration_%d_success_count_%d" % [iteration, successes])
		var loaded := UIForgeSerializer.load_document(source_res)
		if loaded.get("document") == null:
			failures.append("iteration_%d_invalid_json" % iteration)
		for suffix in [".uiforge_backup", ".uiforge_pending", ".uiforge_txn", ".result_A", ".result_B", ".uiforge_reclaim_guard"]:
			if FileAccess.file_exists("%s%s" % [source_abs, suffix]):
				if suffix.ends_with("_A") or suffix.ends_with("_B"):
					DirAccess.remove_absolute("%s%s" % [source_abs, suffix])
					continue
				failures.append("iteration_%d_stale_%s" % [iteration, suffix])
		if DirAccess.dir_exists_absolute("%s.uiforge_lock" % source_abs):
			failures.append("iteration_%d_stale_lock" % iteration)
	if failures.is_empty():
		print(JSON.stringify({"success": true, "iterations": ITERATIONS}))
		quit(0)
	else:
		print(JSON.stringify({"success": false, "iterations": ITERATIONS, "failures": failures}))
		quit(1)

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
