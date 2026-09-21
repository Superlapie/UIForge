extends SceneTree

const MANIFEST_PATH := "res://tests/compiler_conformance/manifest.json"
const GENERATED_META_KEYS := [
	"uiforge_id", "uiforge_type", "uiforge_generated", "uiforge_action", "uiforge_binding",
	"uiforge_transitions", "uiforge_effects", "uiforge_decoration",
	"aether_id", "aether_type", "aether_generated", "aether_action", "aether_binding",
	"aether_transitions", "aether_effects", "aether_decoration",
]

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
		for label in ["fallback", "native"]:
			var scene_path := fallback_path if label == "fallback" else native_path
			var scene_errors := _scene_must_be_clean(scene_path)
			if not scene_errors.is_empty():
				failures.append("%s %s engine/id errors: %s" % [fixture_id, label, "; ".join(scene_errors)])
		var fallback_scene: PackedScene = ResourceLoader.load(fallback_path, "PackedScene")
		var native_scene: PackedScene = ResourceLoader.load(native_path, "PackedScene")
		if fallback_scene == null or native_scene == null:
			failures.append("%s could not load generated scenes" % fixture_id)
			continue
		var fallback_root := fallback_scene.instantiate()
		var native_root := native_scene.instantiate()
		var fallback_snapshot := _semantic_snapshot_list(fallback_root)
		var native_snapshot := _semantic_snapshot_list(native_root)
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
	var exit_code := OS.execute("python3", PackedStringArray([cli, "build", abs_source, abs_output, "--force", "--allow-outside-project"]), output_lines, true, true)
	var combined := "\n".join(output_lines + err_lines)
	if "ERROR:" in combined and "scene unique ID" in combined:
		return {"success": false, "errors": [{"code": "ENGINE_ERROR", "message": combined}]}
	if exit_code != 0:
		var payload: Variant = JSON.parse_string("\n".join(output_lines))
		if payload is Dictionary:
			return {"success": false, "errors": payload.get("errors", [{"code": "FALLBACK_BUILD_FAILED"}])}
		return {"success": false, "errors": [{"code": "FALLBACK_BUILD_FAILED", "message": combined}]}
	return {"success": true, "errors": []}

func _scene_must_be_clean(scene_path: String) -> Array[String]:
	var failures: Array[String] = []
	var file := FileAccess.open(scene_path, FileAccess.READ)
	if file == null:
		return ["missing scene %s" % scene_path]
	var text := file.get_as_text()
	file.close()
	var id_check := UIForgeIdentifiers.validate_scene_text_ids(text)
	if not id_check.get("ok", false):
		for item in id_check.get("errors", []):
			if item is Dictionary:
				failures.append(str(item.get("message", item)))
	failures.append_array(_capture_load_errors(scene_path))
	return failures

func _capture_load_errors(scene_path: String) -> Array[String]:
	var godot_bin := "godot"
	if OS.has_environment("GODOT_BIN"):
		godot_bin = OS.get_environment("GODOT_BIN")
	var project := ProjectSettings.globalize_path("res://")
	var script := ProjectSettings.globalize_path("res://tests/scene_load_capture.gd")
	var out: PackedStringArray = []
	var err: PackedStringArray = []
	OS.execute(godot_bin, PackedStringArray(["--headless", "--path", project, "--script", script, "--", scene_path]), out, true, true)
	var errors: Array[String] = []
	for line in out + err:
		var trimmed := str(line).strip_edges()
		if trimmed.contains("ERROR:"):
			errors.append(trimmed)
	return errors

func _semantic_snapshot_list(node: Node) -> Array:
	var entries: Array = []
	_collect_semantic_entries(node, "", entries)
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.get("uiforge_id", "")) < str(b.get("uiforge_id", ""))
	)
	return entries

func _collect_semantic_entries(node: Node, parent_id: String, entries: Array) -> void:
	var node_id := UIForgeMetadata.read_node_id(node)
	var next_parent := node_id if not node_id.is_empty() else parent_id
	if not node_id.is_empty():
		entries.append(_semantic_entry(node, parent_id))
	for child in node.get_children():
		_collect_semantic_entries(child, next_parent, entries)

func _semantic_entry(node: Node, parent_id: String) -> Dictionary:
	var node_id := UIForgeMetadata.read_node_id(node)
	return {
		"parent_id": parent_id,
		"type": node.get_class(),
		"uiforge_id": node_id,
		"uiforge_type": str(UIForgeMetadata.read_meta(node, "type", "")),
		"metadata": _authored_metadata(node),
		"action": _normalize_meta_value(str(UIForgeMetadata.read_meta(node, "action", ""))),
		"binding": _normalize_meta_value(str(UIForgeMetadata.read_meta(node, "binding", ""))),
		"transitions": _normalize_meta_value(str(UIForgeMetadata.read_meta(node, "transitions", ""))),
		"effects": _normalize_meta_value(str(UIForgeMetadata.read_meta(node, "effects", ""))),
		"layout": _round_values(_layout_snapshot(node)),
		"properties": _round_values(_property_snapshot(node)),
	}

func _normalize_meta_value(raw: String) -> Variant:
	if raw.is_empty():
		return ""
	var trimmed := raw.strip_edges()
	if trimmed.begins_with("{") or trimmed.begins_with("["):
		var parsed: Variant = JSON.parse_string(trimmed)
		if parsed != null:
			return parsed
	return raw

func _round_values(value: Variant) -> Variant:
	if value is float:
		return int(round(value))
	if value is Array:
		var items: Array = []
		for item in value:
			items.append(_round_values(item))
		return items
	if value is Dictionary:
		var normalized := {}
		for key in value.keys():
			normalized[key] = _round_values(value[key])
		return normalized
	return value

func _authored_metadata(node: Node) -> Dictionary:
	var result := {}
	for key in node.get_meta_list():
		var meta_key := str(key)
		if meta_key in GENERATED_META_KEYS:
			continue
		if meta_key.begins_with("uiforge_") or meta_key.begins_with("aether_"):
			continue
		result[meta_key] = str(node.get_meta(key))
	var keys := result.keys()
	keys.sort()
	var ordered := {}
	for key in keys:
		ordered[key] = result[key]
	return ordered

func _layout_snapshot(node: Node) -> Dictionary:
	if not node is Control:
		return {}
	var control := node as Control
	return {
		"position": [control.position.x, control.position.y],
		"size": [control.size.x, control.size.y],
		"anchors": [control.anchor_left, control.anchor_top, control.anchor_right, control.anchor_bottom],
		"offsets": [control.offset_left, control.offset_top, control.offset_right, control.offset_bottom],
		"visible": control.visible,
		"mouse_filter": control.mouse_filter,
	}

func _property_snapshot(node: Node) -> Dictionary:
	var result := {}
	if node is Label:
		var label := node as Label
		result["text"] = label.text
		result["horizontal_alignment"] = label.horizontal_alignment
	elif node is Button:
		var button := node as Button
		result["text"] = button.text
		result["disabled"] = button.disabled
		result["toggle_mode"] = button.toggle_mode
	elif node is LineEdit:
		result["text"] = (node as LineEdit).text
		result["placeholder"] = (node as LineEdit).placeholder_text
	elif node is Range:
		var range_node := node as Range
		result["value"] = range_node.value
		result["min_value"] = range_node.min_value
		result["max_value"] = range_node.max_value
	elif node is TextureRect:
		var texture := (node as TextureRect).texture
		if texture != null:
			result["texture"] = {"path": texture.resource_path, "class": texture.get_class()}
	elif node is ProgressBar:
		var bar := node as ProgressBar
		result["value"] = bar.value
		result["min_value"] = bar.min_value
		result["max_value"] = bar.max_value
	return result
