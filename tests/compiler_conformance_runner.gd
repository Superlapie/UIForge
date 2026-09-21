extends SceneTree

const MANIFEST_PATH := "res://tests/compiler_conformance/manifest.json"

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var manifest_file := FileAccess.open(MANIFEST_PATH, FileAccess.READ)
	if manifest_file == null:
		push_error("Missing compiler conformance manifest.")
		quit(1)
		return
	var manifest: Variant = JSON.parse_string(manifest_file.get_as_text())
	manifest_file.close()
	var fixtures: Array = manifest.get("fixtures", []) if manifest is Dictionary else []
	var failures: Array[String] = []
	DirAccess.make_dir_recursive_absolute("user://compiler_conformance")
	for entry in fixtures:
		if not entry is Dictionary:
			continue
		var fixture_id := str(entry.get("id", "fixture"))
		var source := str(entry.get("source", ""))
		if source.is_empty() or not FileAccess.file_exists(source):
			failures.append("%s missing source %s" % [fixture_id, source])
			continue
		var fallback_path := "user://compiler_conformance/fallback_%s.tscn" % fixture_id
		var native_path := "user://compiler_conformance/native_%s.tscn" % fixture_id
		var fallback_result := _build_with_fallback(source, fallback_path)
		if not fallback_result.get("success", false):
			failures.append("%s fallback build failed: %s" % [fixture_id, JSON.stringify(fallback_result.get("errors", []))])
			continue
		var native_result := UIForgeCompiler.new().compile_file(source, native_path, {"force": true, "allow_outside_project": true})
		if not native_result.get("success", false):
			failures.append("%s native build failed: %s" % [fixture_id, JSON.stringify(native_result.get("errors", []))])
			continue
		var fallback_scene: PackedScene = ResourceLoader.load(fallback_path, "PackedScene")
		var native_scene: PackedScene = ResourceLoader.load(native_path, "PackedScene")
		if fallback_scene == null or native_scene == null:
			failures.append("%s could not load generated scenes" % fixture_id)
			continue
		var fallback_root := fallback_scene.instantiate()
		var native_root := native_scene.instantiate()
		var fallback_snapshot := _normalized_snapshot(fallback_root)
		var native_snapshot := _normalized_snapshot(native_root)
		fallback_root.free()
		native_root.free()
		if JSON.stringify(fallback_snapshot) != JSON.stringify(native_snapshot):
			failures.append("%s semantic snapshot mismatch" % fixture_id)
	if failures.is_empty():
		print(JSON.stringify({"success": true, "fixtures": fixtures.size()}))
	else:
		for failure in failures:
			push_error(failure)
		print(JSON.stringify({"success": false, "failures": failures}))
	quit(0 if failures.is_empty() else 1)

func _build_with_fallback(source: String, output: String) -> Dictionary:
	var abs_source := ProjectSettings.globalize_path(source)
	var abs_output := ProjectSettings.globalize_path(output)
	var cli := ProjectSettings.globalize_path("res://scripts/ui_fallback.py")
	var output_lines: PackedStringArray = []
	var err_lines: PackedStringArray = []
	var exit_code := OS.execute("python3", PackedStringArray([cli, "build", abs_source, abs_output, "--force", "--allow-outside-project"]), output_lines, true, false)
	if exit_code != 0:
		var payload: Variant = JSON.parse_string("\n".join(output_lines))
		if payload is Dictionary:
			return {"success": false, "errors": payload.get("errors", [{"code": "FALLBACK_BUILD_FAILED"}])}
		return {"success": false, "errors": [{"code": "FALLBACK_BUILD_FAILED", "message": "\n".join(output_lines + err_lines)}]}
	return {"success": true, "errors": []}

func _normalized_snapshot(node: Node) -> Array:
	var entries: Array = []
	_collect_snapshot_entries(node, entries)
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.get("uiforge_id", "")) < str(b.get("uiforge_id", ""))
	)
	return entries

func _collect_snapshot_entries(node: Node, entries: Array) -> void:
	entries.append({
		"uiforge_id": str(node.get_meta("uiforge_id", node.get_meta("aether_id", ""))),
		"uiforge_type": str(node.get_meta("uiforge_type", node.get_meta("aether_type", ""))),
		"type": node.get_class(),
	})
	for child in node.get_children():
		_collect_snapshot_entries(child, entries)

func _snapshot(node: Node) -> Dictionary:
	var result := {
		"name": node.name,
		"type": node.get_class(),
		"uiforge_id": str(node.get_meta("uiforge_id", node.get_meta("aether_id", ""))),
		"uiforge_type": str(node.get_meta("uiforge_type", node.get_meta("aether_type", ""))),
		"metadata": {},
		"children": [],
	}
	for key in node.get_meta_list():
		var meta_key := str(key)
		if meta_key.begins_with("uiforge_") or meta_key.begins_with("aether_"):
			result["metadata"][meta_key] = str(node.get_meta(key))
	for child in node.get_children():
		result["children"].append(_snapshot(child))
	result["children"].sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.get("uiforge_id", a.get("name", ""))) < str(b.get("uiforge_id", b.get("name", "")))
	)
	return result
