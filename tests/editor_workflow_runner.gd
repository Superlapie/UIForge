extends SceneTree

var failures: Array[String] = []
var checks: int = 0

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var studio := UIForgeStudio.new()
	get_root().add_child(studio)
	_assert(not studio.asset_index_ready, "asset_index_not_ready_during_construction")
	_assert(studio.asset_paths.is_empty(), "asset_paths_empty_during_construction")
	await _test_asset_indexing(studio)
	var document := UIForgeSerializer.create_default("editor_workflow")
	studio.set_document(document)
	var root_id := str(document.root().get("id", ""))
	_assert(studio.asset_paths.has("res://examples/assets/uiforge_gem.svg"), "asset_browser_discovers_svg")
	studio._on_asset_drop("res://examples/assets/uiforge_gem.svg", root_id, Vector2(120, 96))
	var placed := document.find_node("texture_uiforge_gem")
	_assert(not placed.is_empty(), "canvas_asset_drop_creates_node")
	_assert(str(placed.get("properties", {}).get("texture", "")) == "res://examples/assets/uiforge_gem.svg", "placed_asset_reference_is_stable")
	studio.canvas.select_node("")
	_assert(studio.canvas._can_drop_data(Vector2.ZERO, {"uiforge_asset_path": "res://examples/assets/uiforge_gem.svg"}), "canvas_accepts_asset_drag_payload")
	studio.canvas._drop_data(Vector2(120, 96), {"uiforge_asset_path": "res://examples/assets/uiforge_gem.svg"})
	_assert(not document.find_node("texture_uiforge_gem_2").is_empty(), "canvas_drop_payload_places_asset")
	studio.canvas.select_node("texture_uiforge_gem")
	_assert(studio.property_inspector.field_controls.size() > 40, "inspector_exposes_native_godot_properties")
	studio._on_inspector_apply({"layout.size": [160.0, 160.0], "layout.rotation_degrees": 4.0, "properties.tooltip": "Gem", "metadata": {"test": true}})
	_assert(document.get_property("texture_uiforge_gem", "layout.size") == [160.0, 160.0], "inspector_writes_layout")
	_assert(float(document.get_property("texture_uiforge_gem", "layout.rotation_degrees")) == 4.0, "inspector_writes_transform")
	_assert(document.get_property("texture_uiforge_gem", "metadata.test") == true, "inspector_writes_metadata")
	studio._on_inspector_apply({"__native__:process_mode": 3})
	_assert(document.get_property("texture_uiforge_gem", "properties.godot_overrides.process_mode") == 3, "inspector_writes_native_property")
	UIForgeCanvas.native_preview_compile_count = 0
	studio.canvas.preview_dirty = false
	await process_frame
	await process_frame
	await process_frame
	var idle_compiles := UIForgeCanvas.native_preview_compile_count
	_assert(idle_compiles == 0, "canvas_idle_no_recompiles")
	studio._on_inspector_apply({"layout.size": [180.0, 180.0]})
	await process_frame
	await process_frame
	await process_frame
	_assert(UIForgeCanvas.native_preview_compile_count <= idle_compiles + 1, "inspector_apply_debounced_recompile")
	UIForgeCanvas.native_preview_compile_count = 0
	studio._on_asset_drop("res://examples/assets/uiforge_gem.svg", root_id, Vector2(220, 120))
	await process_frame
	await process_frame
	await process_frame
	_assert(UIForgeCanvas.native_preview_compile_count <= 1, "asset_drop_debounced_recompile")
	UIForgeCanvas.native_preview_compile_count = 0
	studio._on_tree_node_drop("texture_uiforge_gem", root_id)
	await process_frame
	await process_frame
	await process_frame
	_assert(UIForgeCanvas.native_preview_compile_count <= 1, "reparent_debounced_recompile")
	var before_undo := document.data.duplicate(true)
	studio._apply_document_snapshot(before_undo)
	await process_frame
	await process_frame
	await process_frame
	_assert(UIForgeCanvas.native_preview_compile_count <= 2, "undo_snapshot_rebuild")
	studio.canvas.set_viewport_preview(Vector2i(1280, 720))
	_assert(is_equal_approx(studio.canvas._display_scale(), 2.0 / 3.0), "viewport_preview_scales_fit_documents")
	var panel := {"id": "asset_panel", "type": "OrnatePanel", "layout": {"position": [300, 100], "size": [420, 320]}, "children": []}
	_assert(document.add_child(root_id, panel), "add_parent_for_reparent")
	studio._on_asset_drop("res://examples/assets/uiforge_gem.svg", "asset_panel", Vector2(24, 32))
	_assert(document.find_parent("texture_uiforge_gem_3").get("id", "") == "asset_panel", "asset_drop_targets_container")
	studio._on_tree_node_drop("texture_uiforge_gem", "asset_panel")
	_assert(document.find_parent("texture_uiforge_gem").get("id", "") == "asset_panel", "reparent_asset")
	var nine_slice := studio.find_child("Nine-slice", true, false) as UIForgeNineSliceEditor
	_assert(nine_slice != null, "nine_slice_editor_is_available")
	if nine_slice != null:
		nine_slice._drop_data(Vector2.ZERO, {"uiforge_asset_path": "res://examples/assets/uiforge_gem.svg"})
		nine_slice.style_name_field.text = "ornate_gem_frame"
		nine_slice._save_style()
		_assert(document.data.get("theme_overrides", {}).get("styles", {}).get("ornate_gem_frame", {}).get("texture", "") == "res://examples/assets/uiforge_gem.svg", "nine_slice_style_saved")
	document.find_node("asset_panel")["style"] = "ornate_gem_frame"
	var target := "user://uiforge_editor_workflow.tscn"
	var compiled := UIForgeCompiler.new().compile_document(document, target, "editor_workflow.ui.json", {"allow_outside_project": true, "force": true})
	_assert(compiled.success, "editor_workflow_compiles")
	_assert(load(target) as PackedScene != null, "editor_workflow_scene_loads")
	var compiled_text := FileAccess.get_file_as_string(target)
	_assert(compiled_text.contains("StyleBoxTexture"), "nine_slice_compiles_as_stylebox_texture")
	studio.queue_free()
	if failures.is_empty():
		print(JSON.stringify({"success": true, "passed": checks, "failed": 0}))
		quit(0)
	else:
		print(JSON.stringify({"success": false, "passed": checks - failures.size(), "failed": failures.size(), "failures": failures}, "\t"))
		quit(1)

func _assert(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)

func _await_asset_index(studio: UIForgeStudio) -> void:
	var guard := 0
	while not studio.asset_index_ready:
		guard += 1
		_assert(guard < 500, "asset_index_completed")
		await process_frame

func _build_synthetic_asset_tree(root: String) -> Array[String]:
	var expected: Array[String] = []
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(root))
	var flat_dir := "%s/flat_bulk" % root
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(flat_dir))
	for index in range(110):
		var asset_path := "%s/asset_%03d.png" % [flat_dir, index]
		FileAccess.open(asset_path, FileAccess.WRITE).store_string("PNG")
		expected.append(asset_path)
	FileAccess.open("%s/ignore.gd" % flat_dir, FileAccess.WRITE).store_string("extends Node")
	FileAccess.open("%s/.hidden.png" % flat_dir, FileAccess.WRITE).store_string("PNG")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("%s/.hidden_dir" % flat_dir))
	FileAccess.open("%s/.hidden_dir/secret.png" % flat_dir, FileAccess.WRITE).store_string("PNG")
	for index in range(82):
		var folder := "%s/group_%02d" % [root, index]
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
		var icon_path := "%s/icon_%02d.svg" % [folder, index]
		FileAccess.open(icon_path, FileAccess.WRITE).store_string("<svg/>")
		expected.append(icon_path)
		if index % 7 == 0:
			var nested := "%s/nested/deep/asset_%02d.webp" % [folder, index]
			DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(nested.get_base_dir()))
			FileAccess.open(nested, FileAccess.WRITE).store_string("WEBP")
			expected.append(nested)
	expected.sort()
	return expected

func _remove_tree(path: String) -> void:
	var absolute := ProjectSettings.globalize_path(path)
	if DirAccess.dir_exists_absolute(absolute):
		_remove_tree_recursive(absolute)

func _remove_tree_recursive(absolute: String) -> void:
	var directory := DirAccess.open(absolute)
	if directory == null:
		return
	directory.list_dir_begin()
	var entry := directory.get_next()
	while not entry.is_empty():
		var child := absolute.path_join(entry)
		if directory.current_is_dir():
			_remove_tree_recursive(child)
		else:
			DirAccess.remove_absolute(child)
		entry = directory.get_next()
	directory.list_dir_end()
	DirAccess.remove_absolute(absolute)

func _test_asset_indexing(studio: UIForgeStudio) -> void:
	var synthetic_root := "res://tests/synthetic_asset_index"
	_remove_tree(synthetic_root)
	var expected := _build_synthetic_asset_tree(synthetic_root)
	studio.asset_index_root = synthetic_root
	studio._refresh_assets()
	await _await_asset_index(studio)
	_assert(studio.asset_scan_steps >= 3, "asset_index_multiple_steps_for_bulk_directory")
	_assert(studio.asset_paths.size() == expected.size(), "asset_index_expected_count")
	for path in expected:
		_assert(studio.asset_paths.has(path), "asset_index_contains_%s" % path.get_file())
	var duplicates := {}
	for path in studio.asset_paths:
		duplicates[path] = int(duplicates.get(path, 0)) + 1
	for path in duplicates.keys():
		_assert(int(duplicates[path]) == 1, "asset_index_unique_%s" % path.get_file())
	var sorted_copy := studio.asset_paths.duplicate()
	sorted_copy.sort()
	_assert(sorted_copy == studio.asset_paths, "asset_index_sorted")
	var initial_scan_steps := studio.asset_scan_steps
	studio._on_asset_filter_changed("group_01")
	_assert(studio.asset_scan_steps == initial_scan_steps, "asset_filter_does_not_rescan")
	studio._refresh_assets()
	_assert(not studio.asset_index_ready, "asset_refresh_rebuilds")
	await _await_asset_index(studio)
	_assert(studio.asset_paths.size() == expected.size(), "asset_refresh_expected_count")
	_remove_tree(synthetic_root)
	studio.asset_index_root = "res://"
	studio._refresh_assets()
	await _await_asset_index(studio)
