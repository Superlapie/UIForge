extends SceneTree
## Capture the actual editor canvas with the complete editable atlas.
## xvfb-run -a godot --path . --script res://scripts/render_atlas_studio.gd

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	root.size = Vector2i(1920, 1080)
	var studio := AetherStudio.new()
	root.add_child(studio)
	studio.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var created := AetherTemplates.create("ui_atlas", "ui_atlas")
	if created.get("document") == null:
		printerr(created)
		quit(1)
		return
	studio.set_document(created.document, "res://examples/atlas/ui_atlas.ui.json")
	studio.canvas.set_viewport_preview(Vector2i(1672, 941))
	studio.canvas.refresh_native_preview()
	for frame in 12:
		await process_frame
	studio.canvas.zoom_to_fit()
	await process_frame
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute("res://.aether/renders/atlas")
	var result := root.get_texture().get_image().save_png("res://.aether/renders/atlas/studio.png")
	print(JSON.stringify({"success": result == OK and studio.canvas.native_preview_valid, "image": ".aether/renders/atlas/studio.png"}))
	quit(0 if result == OK and studio.canvas.native_preview_valid else 1)
