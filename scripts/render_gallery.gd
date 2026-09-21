extends SceneTree
## Render the real compiled skeletons and button states, not a mockup.
## xvfb-run -a godot --path . --script res://scripts/render_gallery.gd

var failures: Array[String] = []

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	root.size = Vector2i(1800, 1120)
	root.content_scale_size = Vector2i(1800, 1120)
	RenderingServer.set_default_clear_color(Color("#080c10"))
	DirAccess.make_dir_recursive_absolute("res://.uiforge/renders/parity")
	var placements := {
		"inventory": [Vector2(30, 50), 1.0],
		"bank": [Vector2(290, 50), 1.0],
		"equipment": [Vector2(790, 50), 1.0],
		"settings": [Vector2(1170, 50), 1.0],
		"quest_journal": [Vector2(30, 600), 1.0],
		"combat_hud": [Vector2(790, 900), 1.0]
	}
	for key in placements:
		var loaded := UIForgeSerializer.load_document("res://examples/specs/%s.ui.json" % key)
		var path := "res://.uiforge/renders/parity/%s_gallery.tscn" % key
		if loaded.get("document") == null:
			failures.append("load:%s" % key)
			continue
		var result := UIForgeCompiler.new().compile_document(loaded.document, path)
		if not result.success:
			failures.append("compile:%s" % key)
			continue
		var packed := load(path) as PackedScene
		var control := packed.instantiate() as Control
		root.add_child(control)
		control.position = placements[key][0]
		control.scale = Vector2.ONE * float(placements[key][1])
		_caption(key.replace("_", " ").to_upper(), control.position - Vector2(0, 25))
	for index in 4:
		var state: String = ["normal", "hover", "pressed", "disabled"][index]
		var data := UIForgeDocument.from_dict({"schema_version": 1, "name": "button_sample", "theme": "dark_fantasy", "viewport": {"width": 200, "height": 50}, "root": {"id": "sample", "type": "PrimaryButton", "layout": {"size": [192, 38]}, "properties": {"text": "Confirm", "font_size": "$font_size.body"}}})
		data = UIForgeCompiler.document_for_preview_state(data, state)
		var path := "res://.uiforge/renders/parity/button_%s.tscn" % state
		var result := UIForgeCompiler.new().compile_document(data, path)
		if not result.success:
			failures.append("button:%s" % state)
			continue
		var control := (load(path) as PackedScene).instantiate() as Control
		root.add_child(control)
		control.position = Vector2(790 + (index % 2) * 250, 670 + (index / 2) * 80)
		_caption(state.to_upper(), control.position - Vector2(0, 24))
	for frame in 8:
		await process_frame
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var error := image.save_png("res://.uiforge/renders/parity/gallery.png")
	if error != OK:
		failures.append("save:%s" % error)
	print(JSON.stringify({"success": failures.is_empty(), "errors": failures, "image": ".uiforge/renders/parity/gallery.png"}))
	quit(0 if failures.is_empty() else 1)

func _caption(text: String, position: Vector2) -> void:
	var label := Label.new()
	label.text = text
	label.position = position
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", Color("#acb7bd"))
	root.add_child(label)
