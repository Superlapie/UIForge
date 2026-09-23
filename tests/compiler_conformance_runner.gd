extends SceneTree

const MANIFEST_PATH := "res://tests/compiler_conformance/manifest.json"
const GENERATED_META_KEYS := [
	"uiforge_id", "uiforge_type", "uiforge_generated", "uiforge_action", "uiforge_binding",
	"uiforge_transitions", "uiforge_effects", "uiforge_decoration",
	"aether_id", "aether_type", "aether_generated", "aether_action", "aether_binding",
	"aether_transitions", "aether_effects", "aether_decoration",
]
const FLOAT_PRECISION := 6
const LOAD_OK_SENTINEL := "UIFORGE_SCENE_LOAD_OK"

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
	if _normalize_float(0.1) == _normalize_float(0.4):
		failures.append("float precision collapsed distinct values")
	if _normalize_float(0.1000004) != _normalize_float(0.1000001):
		failures.append("float precision failed to normalize noise")
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
		var fallback_snapshot := _semantic_snapshot_root(fallback_root)
		var native_snapshot := _semantic_snapshot_root(native_root)
		failures.append_array(_fixture_assertions(entry, native_root, fallback_root))
		if fixture_id == "typed_literals":
			failures.append_array(_assert_typed_literals(native_root, fallback_root))
		if fixture_id == "plain_numeric_array":
			failures.append_array(_assert_plain_numeric_array(native_root, fallback_root))
		fallback_root.free()
		native_root.free()
		if JSON.stringify(fallback_snapshot) != JSON.stringify(native_snapshot):
			if not bool(entry.get("compare_snapshot", true)):
				pass
			else:
				failures.append("%s semantic snapshot mismatch" % fixture_id)
		if fixture_id == "sibling_order":
			var ordered := _authored_sibling_indices(native_snapshot, ["first", "second", "third"])
			if ordered.size() != 3 or ordered[0] >= ordered[1] or ordered[1] >= ordered[2]:
				failures.append("%s sibling_order child_index mismatch: %s" % [fixture_id, JSON.stringify(ordered)])
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
	var exit_code := OS.execute(godot_bin, PackedStringArray(["--headless", "--path", project, "--script", script, "--", scene_path]), out, true, true)
	var combined := out + err
	var errors: Array[String] = []
	var result_text := _read_scene_load_result()
	if exit_code != 0:
		errors.append("scene load subprocess failed with exit code %d for %s" % [exit_code, scene_path])
	for line in combined:
		var trimmed := str(line).strip_edges()
		if trimmed.contains("ERROR:"):
			errors.append(trimmed)
	if exit_code == 0 and result_text != LOAD_OK_SENTINEL:
		errors.append("scene load subprocess missing success sentinel for %s" % scene_path)
	return errors

func _read_scene_load_result() -> String:
	var result_path := ProjectSettings.globalize_path("user://scene_load_capture_result.txt")
	if not FileAccess.file_exists(result_path):
		return ""
	var file := FileAccess.open("user://scene_load_capture_result.txt", FileAccess.READ)
	if file == null:
		return ""
	var text := file.get_as_text().strip_edges()
	file.close()
	return text

func _semantic_snapshot_root(root: Node) -> Dictionary:
	var root_id := UIForgeMetadata.read_node_id(root)
	var entry := _semantic_entry(root, "", 0)
	entry["children"] = _semantic_children_snapshot(root, root_id)
	return entry

func _semantic_children_snapshot(node: Node, parent_id: String) -> Array:
	var children: Array = []
	var sibling_index := 0
	for child in node.get_children():
		var child_id := UIForgeMetadata.read_node_id(child)
		if child_id.is_empty():
			children.append_array(_semantic_children_snapshot(child, parent_id))
			continue
		var entry := _semantic_entry(child, parent_id, sibling_index)
		sibling_index += 1
		entry["children"] = _semantic_children_snapshot(child, child_id)
		children.append(entry)
	return children

func _authored_sibling_indices(snapshot: Dictionary, expected_ids: Array) -> Array:
	var indices: Array = []
	for child in snapshot.get("children", []):
		if not child is Dictionary:
			continue
		var child_id := str(child.get("uiforge_id", ""))
		if expected_ids.has(child_id):
			indices.append(int(child.get("child_index", -1)))
	return indices

func _fixture_assertions(entry: Dictionary, native_root: Node, fallback_root: Node) -> Array[String]:
	var failures: Array[String] = []
	var fixture_id := str(entry.get("id", "fixture"))
	var assertions: Array = entry.get("assertions", [])
	for item in assertions:
		if not item is Dictionary:
			continue
		var node_id := str(item.get("node_id", ""))
		var native_node := _find_node_by_id(native_root, node_id)
		var fallback_node := _find_node_by_id(fallback_root, node_id)
		if native_node == null or fallback_node == null:
			failures.append("%s missing node %s for assertion" % [fixture_id, node_id])
			continue
		if bool(item.get("exists", false)):
			continue
		if item.has("style_state"):
			var style_state := str(item.get("style_state", "normal"))
			var expected_class := str(item.get("style_class", ""))
			for label in ["native", "fallback"]:
				var node := native_node if label == "native" else fallback_node
				if not node is Control:
					failures.append("%s %s node %s is not a Control" % [fixture_id, label, node_id])
					continue
				var style := (node as Control).get_theme_stylebox(style_state)
				var actual_class := style.get_class() if style != null else ""
				if actual_class != expected_class:
					failures.append("%s %s style %s expected %s got %s" % [fixture_id, label, style_state, expected_class, actual_class])
			continue
		var property_name := str(item.get("property", ""))
		var expected: Variant = item.get("value")
		var native_value: Variant = _normalize_values(native_node.get(property_name))
		var fallback_value: Variant = _normalize_values(fallback_node.get(property_name))
		if JSON.stringify(native_value) != JSON.stringify(expected) or JSON.stringify(fallback_value) != JSON.stringify(expected):
			failures.append("%s assertion failed %s.%s expected %s native %s fallback %s" % [fixture_id, node_id, property_name, JSON.stringify(expected), JSON.stringify(native_value), JSON.stringify(fallback_value)])
	return failures

func _find_node_by_id(root: Node, node_id: String) -> Node:
	if UIForgeMetadata.read_node_id(root) == node_id:
		return root
	for child in root.get_children():
		var found := _find_node_by_id(child, node_id)
		if found != null:
			return found
	return null

func _assert_typed_literals(native_root: Node, fallback_root: Node) -> Array[String]:
	var failures: Array[String] = []
	var native_panel := _find_node_by_id(native_root, "typed_root")
	var fallback_panel := _find_node_by_id(fallback_root, "typed_root")
	if native_panel is Control and fallback_panel is Control:
		var expected_pivot := Vector2(12, 8)
		if (native_panel as Control).pivot_offset != expected_pivot or (fallback_panel as Control).pivot_offset != expected_pivot:
			failures.append("typed_literals pivot_offset mismatch")
		var expected_color := Color("#d7b269")
		var native_color := (native_panel as Control).get_theme_color("accent")
		var fallback_color := (fallback_panel as Control).get_theme_color("accent")
		if not _colors_close(native_color, expected_color) or not _colors_close(fallback_color, expected_color):
			failures.append("typed_literals theme accent color mismatch")
	return failures

func _colors_close(left: Color, right: Color) -> bool:
	return abs(left.r - right.r) < 0.001 and abs(left.g - right.g) < 0.001 and abs(left.b - right.b) < 0.001 and abs(left.a - right.a) < 0.001

func _assert_plain_numeric_array(_native_root: Node, _fallback_root: Node) -> Array[String]:
	var failures: Array[String] = []
	var native_file_path := "user://compiler_conformance/native_plain_numeric_array.tscn"
	var fallback_file_path := "user://compiler_conformance/fallback_plain_numeric_array.tscn"
	for label in ["native", "fallback"]:
		var scene_path := native_file_path if label == "native" else fallback_file_path
		if not FileAccess.file_exists(scene_path):
			failures.append("plain_numeric_array missing %s scene" % label)
			continue
		var text := FileAccess.get_file_as_string(scene_path)
		if "pivot_offset = Vector2(" in text:
			failures.append("plain_numeric_array %s scene must not coerce plain arrays into Vector2" % label)
		if "pivot_offset = [" not in text:
			failures.append("plain_numeric_array %s scene missing array literal pivot_offset" % label)
	return failures

func _semantic_entry(node: Node, parent_id: String, child_index: int) -> Dictionary:
	var node_id := UIForgeMetadata.read_node_id(node)
	return {
		"parent_id": parent_id,
		"child_index": child_index,
		"name": str(node.name),
		"type": node.get_class(),
		"uiforge_id": node_id,
		"uiforge_type": str(UIForgeMetadata.read_meta(node, "type", "")),
		"metadata": _authored_metadata(node),
		"action": _normalize_meta_value(str(UIForgeMetadata.read_meta(node, "action", ""))),
		"binding": _normalize_meta_value(str(UIForgeMetadata.read_meta(node, "binding", ""))),
		"transitions": _normalize_meta_value(str(UIForgeMetadata.read_meta(node, "transitions", ""))),
		"effects": _normalize_meta_value(str(UIForgeMetadata.read_meta(node, "effects", ""))),
		"layout": _normalize_values(_layout_snapshot(node)),
		"properties": _normalize_values(_property_snapshot(node)),
		"theme_overrides": _normalize_values(_theme_override_snapshot(node)),
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

func _normalize_float(value: float) -> float:
	var scale := pow(10.0, FLOAT_PRECISION)
	return round(value * scale) / scale

func _normalize_values(value: Variant) -> Variant:
	if value is float:
		return _normalize_float(value)
	if value is Array:
		var items: Array = []
		for item in value:
			items.append(_normalize_values(item))
		return items
	if value is Dictionary:
		var normalized := {}
		for key in value.keys():
			normalized[key] = _normalize_values(value[key])
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
		"scale": [control.scale.x, control.scale.y],
		"rotation": control.rotation,
		"visible": control.visible,
		"mouse_filter": control.mouse_filter,
	}

func _theme_override_snapshot(node: Node) -> Dictionary:
	var result := {}
	for prop in node.get_property_list():
		var prop_name := str(prop.get("name", ""))
		if not prop_name.begins_with("theme_override_"):
			continue
		var override_value: Variant = _normalize_resource_value(node.get(prop_name))
		if override_value == null:
			continue
		result[prop_name] = override_value
	return result

func _normalize_resource_value(value: Variant) -> Variant:
	if value == null:
		return null
	if value is Resource:
		var resource := value as Resource
		if resource is StyleBox:
			return {"class": resource.get_class()}
		var resource_path := resource.resource_path
		if resource_path.contains("::"):
			resource_path = resource_path.split("::", false, 1)[1]
		var payload := {
			"path": resource_path,
			"class": resource.get_class(),
		}
		if resource is Font:
			pass
		if resource is Texture2D:
			payload["size"] = [(resource as Texture2D).get_width(), (resource as Texture2D).get_height()]
		return payload
	if value is Color:
		var color := value as Color
		return [color.r, color.g, color.b, color.a]
	if value is float:
		return _normalize_float(value)
	return value

func _property_snapshot(node: Node) -> Dictionary:
	var result := {}
	if node is Label:
		var label := node as Label
		result["text"] = label.text
		result["horizontal_alignment"] = label.horizontal_alignment
		result["vertical_alignment"] = label.vertical_alignment
		if label.label_settings != null:
			result["label_settings"] = _normalize_resource_value(label.label_settings)
		if label.get("theme_font") != null:
			result["font"] = _normalize_resource_value(label.get("theme_font"))
	elif node is Button:
		var button := node as Button
		result["text"] = button.text
		result["disabled"] = button.disabled
		result["toggle_mode"] = button.toggle_mode
		if button.get("icon") != null:
			result["icon"] = _normalize_resource_value(button.get("icon"))
	elif node is TextureButton:
		var texture_button := node as TextureButton
		if texture_button.texture_normal != null:
			result["texture_normal"] = _normalize_resource_value(texture_button.texture_normal)
	elif node is LineEdit:
		result["text"] = (node as LineEdit).text
		result["placeholder"] = (node as LineEdit).placeholder_text
		result["caret_blink_interval"] = (node as LineEdit).caret_blink_interval
	elif node is Range:
		var range_node := node as Range
		result["value"] = range_node.value
		result["min_value"] = range_node.min_value
		result["max_value"] = range_node.max_value
		result["step"] = range_node.step
	elif node is TextureRect:
		var texture := (node as TextureRect).texture
		if texture != null:
			result["texture"] = _normalize_resource_value(texture)
		result["expand_mode"] = (node as TextureRect).expand_mode
		result["stretch_mode"] = (node as TextureRect).stretch_mode
	elif node is NinePatchRect:
		var patch := node as NinePatchRect
		if patch.texture != null:
			result["texture"] = _normalize_resource_value(patch.texture)
		var region: Rect2 = patch.region_rect
		result["region_rect"] = [region.position.x, region.position.y, region.size.x, region.size.y]
	elif node is ProgressBar:
		var bar := node as ProgressBar
		result["value"] = bar.value
		result["min_value"] = bar.min_value
		result["max_value"] = bar.max_value
	elif node.get("material") != null:
		result["material"] = _normalize_resource_value(node.get("material"))
	return result
