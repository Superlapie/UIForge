extends SceneTree

var failures: Array[String] = []
var checks := 0

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	for key in AetherTemplates.catalog():
		var created := AetherTemplates.create(key, "my_screen")
		_check(created.get("document") != null, "create_%s" % key)
		if created.get("document") == null:
			continue
		var doc: AetherDocument = created.document
		_check(doc.document_name() == "my_screen" and doc.source_path.is_empty(), "independent_%s" % key)
		var output := "user://atlas_test_%s.tscn" % key
		var compiled := AetherCompiler.new().compile_document(doc, output)
		_check(compiled.success, "compile_%s" % key)
		if compiled.success:
			var instance := (ResourceLoader.load(output, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene).instantiate()
			_check(instance is Control, "load_%s" % key)
			instance.free()
	_check(AetherTemplates.create("missing", "test").document == null, "unknown_template")
	var created := AetherTemplates.create("inventory", "inventory_test")
	var doc: AetherDocument = created.document
	var texture_node := doc.find_node("backpack_slots_00_icon")
	texture_node.properties.texture_region = [0, 0, -1, 362]
	_check(AetherValidator.new().validate(doc).errors > 0, "reject_negative_region")
	var studio := AetherStudio.new()
	root.add_child(studio)
	studio._create_new_document()
	var entries := AetherTemplates.catalog().keys()
	studio.template_select.select(entries.find("inventory") + 1)
	studio._create_selected_template()
	_check(studio.document_path.is_empty() and studio.dirty, "editor_template_is_unsaved_copy")
	_check(studio.viewport_select.get_selected_metadata() == studio.document.viewport_size(), "template_viewport_matches_toolbar")
	studio.canvas.refresh_native_preview()
	await process_frame
	await process_frame
	_check(studio.canvas.native_preview_valid, "canvas_uses_native_preview")
	var icon: TextureRect = studio.canvas.native_controls.get("backpack_slots_00_icon")
	_check(icon != null and icon.texture is AtlasTexture, "canvas_uses_atlas_texture")
	if icon != null and icon.texture is AtlasTexture:
		_check(icon.texture.region == Rect2(0, 0, 362, 362), "native_sprite_region")
	var first: Control = studio.canvas.native_controls.get("backpack_slots_00")
	var second: Control = studio.canvas.native_controls.get("backpack_slots_01")
	_check(first != null and second != null and second.position.x > first.position.x, "native_grid_layout")
	studio.canvas.select_node("backpack_slots_00_icon")
	_check(studio.property_inspector.field_controls.has("properties.texture_region"), "inspector_exposes_sprite_region")
	studio._on_inspector_apply({"properties.texture_region": null})
	_check(not studio.document.find_node("backpack_slots_00_icon").properties.has("texture_region"), "inspector_clears_region")
	studio.queue_free()
	await process_frame
	print(JSON.stringify({"success": failures.is_empty(), "checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)

func _check(condition: bool, name: String) -> void:
	checks += 1
	if not condition:
		failures.append(name)
