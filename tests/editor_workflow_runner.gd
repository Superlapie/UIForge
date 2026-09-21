extends SceneTree

var failures: Array[String] = []
var checks: int = 0

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var studio := UIForgeStudio.new()
	get_root().add_child(studio)
	await process_frame
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
