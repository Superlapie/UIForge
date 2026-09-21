extends SceneTree

var args: PackedStringArray

func _init() -> void:
	args = OS.get_cmdline_user_args()
	call_deferred("_run")

func _run() -> void:
	var result := await _dispatch()
	print(JSON.stringify(result, "\t"))
	quit(0 if bool(result.get("success", false)) else 1)

func _dispatch() -> Dictionary:
	if args.is_empty() or args[0] in ["help", "--help", "-h"]:
		return {"success": true, "help": _help_text(), "commands": ["capabilities", "new", "validate", "inspect", "get", "set", "add", "delete", "move", "duplicate", "build", "build-all", "render"]}
	var command := str(args[0])
	match command:
		"capabilities":
			return {"success": true, "capabilities": UIForgeCapabilities.as_dict()}
		"new":
			return _new_document()
		"validate":
			return _validate_document()
		"inspect":
			return _inspect_document()
		"get":
			return _get_node()
		"set":
			return _set_value()
		"add":
			return _add_value()
		"delete":
			return _delete_value()
		"move":
			return _move_value()
		"duplicate":
			return _duplicate_value()
		"build":
			return _build_document()
		"build-all":
			return _build_all()
		"render":
			return await _render_document()
		_:
			return {"success": false, "errors": [{"code": "UNKNOWN_COMMAND", "message": "Unknown command '%s'." % command}], "help": _help_text()}

func _load(path: String) -> Dictionary:
	return UIForgeSerializer.load_document(path)

func _new_document() -> Dictionary:
	if args.size() < 3:
		return {"success": false, "errors": [{"code": "USAGE", "message": "Usage: ui new <template> <output.ui.json>"}]}
	var template := str(args[1])
	var output := str(args[2])
	var created := UIForgeTemplates.create(template, output.get_file().trim_suffix(".ui.json"))
	if created.get("document") == null:
		return {"success": false, "errors": created.errors}
	var document: UIForgeDocument = created.document
	var saved := UIForgeSerializer.save_document(document, output)
	saved["template"] = template
	return saved

func _validate_document() -> Dictionary:
	if args.size() < 2:
		return {"success": false, "errors": [{"code": "USAGE", "message": "Usage: ui validate <document.ui.json>"}]}
	var loaded := _load(str(args[1]))
	if loaded.get("document") == null:
		return {"success": false, "errors": loaded.get("errors", [])}
	var validation := UIForgeValidator.new().validate(loaded["document"])
	return {"success": validation.success, "errors": validation.errors, "warnings": validation.warnings, "diagnostics": validation.diagnostics, "document": str(args[1])}

func _inspect_document() -> Dictionary:
	if args.size() < 2:
			return {"success": false, "errors": [{"code": "USAGE", "message": "Usage: ui inspect <document.ui.json> [document|tree|node <node_id>|tokens|components|diagnostics]"}]}
	var loaded := _load(str(args[1]))
	if loaded.get("document") == null:
		return {"success": false, "errors": loaded.get("errors", [])}
	var document: UIForgeDocument = loaded["document"]
	var scope := str(args[2]) if args.size() > 2 else "tree"
	match scope:
		"document":
			return {"success": true, "document": {"schema_version": document.data.get("schema_version", UIForgeTypes.SCHEMA_VERSION), "name": document.document_name(), "source": document.source_path, "viewport": document.data.get("viewport", {}), "theme": document.data.get("theme", "dark_fantasy"), "root_id": str(document.root().get("id", "")), "root_type": str(document.root().get("type", "")), "node_count": document.all_nodes().size(), "components": document.data.get("components", {}).keys(), "metadata": document.data.get("metadata", {}), "reference": document.data.get("reference", {})}}
		"tree":
			return UIForgeDocumentOperations.inspect_tree(document)
		"node":
			if args.size() < 4:
				return {"success": false, "errors": [{"code": "USAGE", "message": "Usage: ui inspect <document.ui.json> node <node_id>"}]}
			return UIForgeDocumentOperations.get_node(document, str(args[3]))
		"tokens":
			return {"success": true, "theme": document.data.get("theme", "dark_fantasy"), "tokens": UIForgeTheme.from_document(document).tokens}
		"components":
			return {"success": true, "components": UIForgeComponentLibrary.definitions(), "custom": document.data.get("components", {})}
		"diagnostics":
			var validation := UIForgeValidator.new().validate(document)
			return {"success": validation.success, "diagnostics": validation.diagnostics}
		_:
			if not document.find_node(scope).is_empty():
				return UIForgeDocumentOperations.get_node(document, scope)
			return {"success": false, "errors": [{"code": "UNKNOWN_SCOPE", "message": "Unknown inspect scope '%s'." % scope}]}

func _get_node() -> Dictionary:
	if args.size() < 3:
		return {"success": false, "errors": [{"code": "USAGE", "message": "Usage: ui get <document.ui.json> <node_id> [property.path]"}]}
	var loaded := _load(str(args[1]))
	if loaded.get("document") == null:
		return {"success": false, "errors": loaded.get("errors", [])}
	var document: UIForgeDocument = loaded["document"]
	var property_path := str(args[3]) if args.size() > 3 else ""
	var result := {"success": true, "id": str(args[2]), "value": document.get_property(str(args[2]), property_path)}
	if document.find_node(str(args[2])).is_empty():
		result["success"] = false
		result["error"] = {"code": "NODE_NOT_FOUND", "node": str(args[2])}
	return result

func _set_value() -> Dictionary:
	if args.size() < 5:
		return {"success": false, "errors": [{"code": "USAGE", "message": "Usage: ui set <document.ui.json> <node_id> <property.path> <value>"}]}
	var path := str(args[1])
	var node_id := str(args[2])
	var property_path := str(args[3])
	var raw_value := str(args[4])
	return UIForgeMutationPipeline.commit(path, func(document: UIForgeDocument) -> Dictionary:
		return UIForgeDocumentOperations.set_value(document, node_id, property_path, raw_value)
	)

func _add_value() -> Dictionary:
	if args.size() < 4:
		return {"success": false, "errors": [{"code": "USAGE", "message": "Usage: ui add <document.ui.json> <parent_id> '<node_json>'"}]}
	var path := str(args[1])
	var parent_id := str(args[2])
	var raw_node := str(args[3])
	return UIForgeMutationPipeline.commit(path, func(document: UIForgeDocument) -> Dictionary:
		return UIForgeDocumentOperations.add_value(document, parent_id, raw_node)
	)

func _delete_value() -> Dictionary:
	if args.size() < 3:
		return {"success": false, "errors": [{"code": "USAGE", "message": "Usage: ui delete <document.ui.json> <node_id>"}]}
	var path := str(args[1])
	var node_id := str(args[2])
	return UIForgeMutationPipeline.commit(path, func(document: UIForgeDocument) -> Dictionary:
		return UIForgeDocumentOperations.delete_value(document, node_id)
	)

func _move_value() -> Dictionary:
	if args.size() < 4:
		return {"success": false, "errors": [{"code": "USAGE", "message": "Usage: ui move <document.ui.json> <node_id> <new_parent_id> [index]"}]}
	var path := str(args[1])
	var node_id := str(args[2])
	var parent_id := str(args[3])
	var index := int(args[4]) if args.size() > 4 else -1
	return UIForgeMutationPipeline.commit(path, func(document: UIForgeDocument) -> Dictionary:
		return UIForgeDocumentOperations.move_value(document, node_id, parent_id, index)
	)

func _duplicate_value() -> Dictionary:
	if args.size() < 4:
		return {"success": false, "errors": [{"code": "USAGE", "message": "Usage: ui duplicate <document.ui.json> <node_id> <new_id>"}]}
	var path := str(args[1])
	var node_id := str(args[2])
	var new_id := str(args[3])
	return UIForgeMutationPipeline.commit(path, func(document: UIForgeDocument) -> Dictionary:
		return UIForgeDocumentOperations.duplicate_value(document, node_id, new_id)
	)

func _build_document() -> Dictionary:
	if args.size() < 2:
		return {"success": false, "errors": [{"code": "USAGE", "message": "Usage: ui build <document.ui.json> [output.tscn]"}]}
	var source := str(args[1])
	var output := str(args[2]) if args.size() > 2 else "%s.tscn" % source.trim_suffix(".ui.json")
	return UIForgeCompiler.new().compile_file(source, output)

func _build_all() -> Dictionary:
	var source_dir := str(args[1]) if args.size() > 1 else "examples/specs"
	var output_dir := str(args[2]) if args.size() > 2 else "examples/scenes"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output_dir))
	var directory := DirAccess.open(source_dir)
	if directory == null:
		return {"success": false, "errors": [{"code": "DIRECTORY_NOT_FOUND", "message": source_dir}]}
	var built: Array = []
	var failed: Array = []
	var source_files: Array[String] = []
	directory.list_dir_begin()
	var filename := directory.get_next()
	while not filename.is_empty():
		if not directory.current_is_dir() and filename.ends_with(".ui.json"):
			source_files.append(filename)
		filename = directory.get_next()
	directory.list_dir_end()
	source_files.sort()
	for source_file in source_files:
		var output := "%s/%s.tscn" % [output_dir, source_file.trim_suffix(".ui.json")]
		var result := UIForgeCompiler.new().compile_file("%s/%s" % [source_dir, source_file], output)
		if result.success:
			built.append(result)
		else:
			failed.append(result)
	return {"success": failed.is_empty(), "built": built, "failed": failed}

func _render_document() -> Dictionary:
	if args.size() < 2:
		return {"success": false, "errors": [{"code": "USAGE", "message": "Usage: ui render <document.ui.json> [--viewport 1920x1080] [--output path.png]"}]}
	var source := str(args[1])
	var size := Vector2i(1920, 1080)
	var output := ""
	var state := "normal"
	var reference_path := ""
	var diff_output := ""
	var index := 2
	while index < args.size():
		if args[index] == "--viewport" and index + 1 < args.size():
			var pieces := str(args[index + 1]).split("x")
			if pieces.size() == 2:
				size = Vector2i(int(pieces[0]), int(pieces[1]))
			index += 2
		elif args[index] == "--output" and index + 1 < args.size():
			output = str(args[index + 1])
			index += 2
		elif args[index] == "--state" and index + 1 < args.size():
			state = str(args[index + 1])
			index += 2
		elif args[index] == "--reference" and index + 1 < args.size():
			reference_path = str(args[index + 1])
			index += 2
		elif args[index] == "--diff" and index + 1 < args.size():
			diff_output = str(args[index + 1])
			index += 2
		else:
			index += 1
	if output.is_empty():
		output = ".aether/renders/%s_%dx%d.png" % [source.get_file().trim_suffix(".ui.json"), size.x, size.y]
	var output_dir := output.get_base_dir()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output_dir))
	# Keep the temporary scene beside the requested image. This makes parallel
	# agent renders safe even when different output directories reuse a filename.
	var generated_scene := "%s_preview.tscn" % output.trim_suffix(".png")
	var loaded := UIForgeSerializer.load_document(source)
	if loaded.get("document") == null:
		return {"success": false, "errors": loaded.get("errors", [])}
	var render_document: UIForgeDocument = UIForgeCompiler.document_for_preview_state(loaded["document"], state)
	var compiled := UIForgeCompiler.new().compile_document(render_document, generated_scene, source)
	if not compiled.success:
		return compiled
	var packed := load(ProjectSettings.globalize_path(generated_scene)) as PackedScene
	if packed == null:
		return {"success": false, "errors": [{"code": "SCENE_LOAD_FAILED", "message": generated_scene}]}
	var viewport := SubViewport.new()
	viewport.size = size
	viewport.transparent_bg = false
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	get_root().add_child(viewport)
	var instance := packed.instantiate()
	viewport.add_child(instance)
	var design_size := Vector2(render_document.viewport_size())
	var viewport_data: Dictionary = render_document.data.get("viewport", {})
	var scale_mode := str(viewport_data.get("scale_mode", "fit"))
	var render_scale := 1.0
	if design_size.x > 0.0 and design_size.y > 0.0 and scale_mode != "fixed":
		render_scale = min(float(size.x) / design_size.x, float(size.y) / design_size.y)
		if scale_mode == "integer":
			render_scale = max(1.0, floor(render_scale))
	instance.scale = Vector2.ONE * render_scale
	# A Control's own offsets are not transformed by its scale because they
	# position it in the parent viewport. Scale that authored root position as
	# well so compact edge-anchored documents remain visible at preview sizes
	# smaller than their design resolution.
	if instance is Control and not is_equal_approx(render_scale, 1.0):
		var root_control := instance as Control
		root_control.position *= render_scale
	await process_frame
	await process_frame
	var image := viewport.get_texture().get_image()
	if image == null:
		viewport.queue_free()
		return {"success": false, "errors": [{"code": "HEADLESS_RENDER_UNAVAILABLE", "message": "Godot created a scene viewport but this display/rendering backend did not expose a readable image. Run the same command on a GPU-capable or virtual-display backend."}], "generated_scene": generated_scene}
	var save_error := image.save_png(ProjectSettings.globalize_path(output))
	viewport.queue_free()
	if save_error != OK:
		return {"success": false, "errors": [{"code": "RENDER_WRITE_FAILED", "message": output}]}
	var result := {"success": true, "rendered_image": output, "viewport": {"width": size.x, "height": size.y}, "generated_scene": generated_scene, "state": state}
	if not reference_path.is_empty():
		var reference_image := Image.new()
		var reference_fs := ProjectSettings.globalize_path(reference_path) if reference_path.begins_with("res://") else reference_path
		if reference_image.load(reference_fs) == OK:
			result["reference_image"] = reference_path
			if not diff_output.is_empty():
				DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(diff_output.get_base_dir()))
				var diff := _make_diff(image, reference_image, size)
				var diff_error := diff.save_png(ProjectSettings.globalize_path(diff_output))
				if diff_error == OK:
					result["diff_image"] = diff_output
				else:
					result["warnings"] = [{"code": "DIFF_WRITE_FAILED", "message": diff_output}]
		else:
			result["warnings"] = [{"code": "REFERENCE_LOAD_FAILED", "message": reference_path}]
	return result

func _make_diff(rendered: Image, reference: Image, size: Vector2i) -> Image:
	var resized := reference.duplicate()
	resized.resize(size.x, size.y, Image.INTERPOLATE_BILINEAR)
	var diff := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	for y in size.y:
		for x in size.x:
			var a: Color = rendered.get_pixel(x, y)
			var b: Color = resized.get_pixel(x, y)
			var delta := Color(abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b), 1.0)
			diff.set_pixel(x, y, delta)
	return diff

func _help_text() -> String:
	return "UIForge CLI\n\n" + "ui capabilities\nui validate <file.ui.json>\nui inspect <file.ui.json> [document|tree|node <node_id>|tokens|components|diagnostics]\nui get <file.ui.json> <node_id> [property.path]\nui set <file.ui.json> <node_id> <property.path> <value>\nui add <file.ui.json> <parent_id> '<node_json>'\nui delete <file.ui.json> <node_id>\nui move <file.ui.json> <node_id> <new_parent_id> [index]\nui duplicate <file.ui.json> <node_id> <new_id>\nui build <file.ui.json> [output.tscn]\nui build-all [source_dir] [output_dir]\nui render <file.ui.json> --viewport 1920x1080 [--state hover] [--output file.png] [--reference reference.png --diff diff.png]"
