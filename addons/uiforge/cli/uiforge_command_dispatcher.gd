class_name UIForgeCommandDispatcher
extends RefCounted

const _MachineParams = preload("res://addons/uiforge/cli/uiforge_machine_params.gd")

static func dispatch(method: String, params: Dictionary = {}) -> Dictionary:
	match method:
		"capabilities":
			return _wrap_success(_capabilities())
		"new":
			return _wrap(_new_document(params))
		"validate":
			return _wrap(_validate_document(params))
		"inspect":
			return _wrap(_inspect_document(params))
		"get":
			return _wrap(_get_node(params))
		"set":
			return _wrap(_set_value(params))
		"add":
			return _wrap(_add_value(params))
		"delete":
			return _wrap(_delete_value(params))
		"move":
			return _wrap(_move_value(params))
		"duplicate":
			return _wrap(_duplicate_value(params))
		"build":
			return _wrap(_build_document(params))
		"build-all":
			return _wrap(_build_all(params))
		"render":
			return _wrap(await _render_document(params))
		"batch":
			return _wrap(_batch_document(params))
		"shutdown":
			return _wrap_success({"shutdown": true})
		_:
			return {"success": false, "errors": [{"code": "UNKNOWN_METHOD", "message": "Unknown method '%s'." % method}]}

static func dispatch_machine(request: Dictionary) -> Dictionary:
	var validated := UIForgeMachineProtocol.validate_request(request)
	if not bool(validated.get("ok", false)):
		return UIForgeMachineProtocol.error_response(
			str(request.get("request_id", "")),
			str(validated.get("code", "MALFORMED_REQUEST")),
			str(validated.get("message", "Malformed request."))
		)
	var payload: Dictionary = validated.request
	var method := str(payload.get("method", ""))
	var params: Dictionary = payload.get("params", {}) if payload.get("params", {}) is Dictionary else {}
	var request_id := str(payload.get("request_id", ""))
	var param_check: Dictionary = _MachineParams.validate_command_params(method, params)
	if not bool(param_check.get("ok", false)):
		return UIForgeMachineProtocol.error_response(
			request_id,
			str(param_check.get("code", "MALFORMED_PARAMS")),
			str(param_check.get("message", "Malformed params."))
		)
	var legacy := await dispatch(method, params)
	return _to_machine_response(request_id, legacy)

static func human_from_argv(args: PackedStringArray) -> Dictionary:
	if args.is_empty() or args[0] in ["help", "--help", "-h"]:
		return {"success": true, "help": _help_text(), "commands": UIForgeCapabilities.command_names()}
	var command := str(args[0])
	var params := _argv_to_params(command, args)
	return await dispatch(command, params)

static func _to_machine_response(request_id: String, legacy: Dictionary) -> Dictionary:
	if bool(legacy.get("success", false)):
		var result := legacy.duplicate(true)
		result.erase("success")
		return UIForgeMachineProtocol.success_response(request_id, result, legacy.get("diagnostics", []))
	var code := "COMMAND_FAILED"
	var message := "Command failed."
	if legacy.has("error") and legacy.error is Dictionary:
		code = str(legacy.error.get("code", code))
		message = str(legacy.error.get("message", message))
	elif not legacy.get("errors", []).is_empty() and legacy.errors[0] is Dictionary:
		code = str(legacy.errors[0].get("code", code))
		message = str(legacy.errors[0].get("message", message))
	var failure_result := UIForgeMachineProtocol.machine_failure_result(legacy)
	return UIForgeMachineProtocol.error_response(request_id, code, message, legacy.get("diagnostics", legacy.get("errors", [])), failure_result)

static func _wrap(result: Dictionary) -> Dictionary:
	if not result.has("success"):
		result["success"] = true
	return result

static func _wrap_success(result: Dictionary) -> Dictionary:
	result["success"] = true
	return result

static func _capabilities() -> Dictionary:
	return {"capabilities": UIForgeCapabilities.as_dict()}

static func _load(path: String) -> Dictionary:
	return UIForgeSerializer.load_document(path)

static func _with_revision(result: Dictionary, revision: String) -> Dictionary:
	if not revision.is_empty():
		result["revision"] = revision
	return result

static func _new_document(params: Dictionary) -> Dictionary:
	var template := str(params.get("template", ""))
	var output := str(params.get("output", ""))
	if template.is_empty() or output.is_empty():
		return {"success": false, "errors": [{"code": "USAGE", "message": "new requires template and output."}]}
	var flags := _params_flags(params)
	var path_check := UIForgePaths.validate_output(output, UIForgePaths.ArtifactKind.SOURCE, flags.allow_outside_project)
	if not path_check.ok:
		return {"success": false, "committed": false, "errors": path_check.errors}
	var create_check := UIForgeArtifact.check_create_allowed(output, flags.force)
	if not create_check.ok:
		return {"success": false, "committed": false, "errors": create_check.errors}
	var document_name := output.get_file().trim_suffix(".ui.json")
	var name_error := UIForgeID.document_name_diagnostic(document_name)
	if not name_error.is_empty():
		return {"success": false, "committed": false, "errors": [name_error]}
	var created := UIForgeTemplates.create(template, document_name)
	if created.get("document") == null:
		return {"success": false, "committed": false, "errors": created.errors}
	var document: UIForgeDocument = created.document
	var validation := UIForgeValidator.new().validate(document)
	if not validation.success:
		return {"success": false, "committed": false, "errors": _error_diagnostics(validation.diagnostics), "diagnostics": validation.diagnostics}
	var saved := UIForgeSerializer.save_document(document, output)
	if not saved.success:
		saved["success"] = false
		saved["committed"] = false
		return saved
	saved["success"] = true
	saved["committed"] = true
	saved["template"] = template
	return _with_revision(saved, str(saved.get("revision", UIForgeHash.document_revision(document))))

static func _validate_document(params: Dictionary) -> Dictionary:
	var path := str(params.get("document", params.get("path", "")))
	if path.is_empty():
		return {"success": false, "errors": [{"code": "USAGE", "message": "validate requires document."}]}
	var loaded := _load(path)
	if loaded.get("document") == null:
		return {"success": false, "errors": loaded.get("errors", [])}
	var validation := UIForgeValidator.new().validate(loaded["document"])
	return _with_revision({
		"success": validation.success,
		"errors": validation.errors,
		"warnings": validation.warnings,
		"diagnostics": validation.diagnostics,
		"document": path,
	}, str(loaded.get("revision_hash", "")))

static func _inspect_document(params: Dictionary) -> Dictionary:
	var path := str(params.get("document", params.get("path", "")))
	if path.is_empty():
		return {"success": false, "errors": [{"code": "USAGE", "message": "inspect requires document."}]}
	var loaded := _load(path)
	if loaded.get("document") == null:
		return {"success": false, "errors": loaded.get("errors", [])}
	var document: UIForgeDocument = loaded["document"]
	var scope := str(params.get("scope", "tree"))
	match scope:
		"document":
			return _with_revision({"success": true, "document": {"schema_version": document.data.get("schema_version", UIForgeTypes.SCHEMA_VERSION), "name": document.document_name(), "source": document.source_path, "viewport": document.data.get("viewport", {}), "theme": document.data.get("theme", "dark_fantasy"), "root_id": str(document.root().get("id", "")), "root_type": str(document.root().get("type", "")), "node_count": document.all_nodes().size(), "components": document.data.get("components", {}).keys(), "metadata": document.data.get("metadata", {}), "reference": document.data.get("reference", {})}}, str(loaded.get("revision_hash", "")))
		"tree":
			return _with_revision(UIForgeDocumentOperations.inspect_tree(document), str(loaded.get("revision_hash", "")))
		"node":
			var node_id := str(params.get("node", params.get("node_id", "")))
			if node_id.is_empty():
				return {"success": false, "errors": [{"code": "USAGE", "message": "inspect node requires node."}]}
			return _with_revision(UIForgeDocumentOperations.get_node(document, node_id), str(loaded.get("revision_hash", "")))
		"tokens":
			return _with_revision({"success": true, "theme": document.data.get("theme", "dark_fantasy"), "tokens": UIForgeTheme.from_document(document).tokens}, str(loaded.get("revision_hash", "")))
		"components":
			return _with_revision({"success": true, "components": UIForgeComponentLibrary.definitions(), "custom": document.data.get("components", {})}, str(loaded.get("revision_hash", "")))
		"diagnostics":
			var validation := UIForgeValidator.new().validate(document)
			return _with_revision({"success": validation.success, "diagnostics": validation.diagnostics}, str(loaded.get("revision_hash", "")))
		_:
			if not document.find_node(scope).is_empty():
				return _with_revision(UIForgeDocumentOperations.get_node(document, scope), str(loaded.get("revision_hash", "")))
			return {"success": false, "errors": [{"code": "UNKNOWN_SCOPE", "message": "Unknown inspect scope '%s'." % scope}]}

static func _get_node(params: Dictionary) -> Dictionary:
	var path := str(params.get("document", params.get("path", "")))
	var node_id := str(params.get("node", params.get("node_id", "")))
	if path.is_empty() or node_id.is_empty():
		return {"success": false, "errors": [{"code": "USAGE", "message": "get requires document and node."}]}
	var loaded := _load(path)
	if loaded.get("document") == null:
		return {"success": false, "errors": loaded.get("errors", [])}
	var document: UIForgeDocument = loaded["document"]
	var property_path := str(params.get("property", params.get("property_path", "")))
	var result := {"success": true, "id": node_id, "value": document.get_property(node_id, property_path)}
	if document.find_node(node_id).is_empty():
		result["success"] = false
		result["error"] = {"code": "NODE_NOT_FOUND", "node": node_id}
	return _with_revision(result, str(loaded.get("revision_hash", "")))

static func _set_value(params: Dictionary) -> Dictionary:
	return _mutation(str(params.get("document", params.get("path", ""))), func(document: UIForgeDocument) -> Dictionary:
		return UIForgeDocumentOperations.set_value(document, str(params.get("node", params.get("node_id", ""))), str(params.get("property", params.get("property_path", ""))), str(params.get("value", "")))
	, str(params.get("expected_revision", "")))

static func _add_value(params: Dictionary) -> Dictionary:
	return _mutation(str(params.get("document", params.get("path", ""))), func(document: UIForgeDocument) -> Dictionary:
		return UIForgeDocumentOperations.add_value(document, str(params.get("parent", params.get("parent_id", ""))), str(params.get("node_json", params.get("node", ""))))
	, str(params.get("expected_revision", "")))

static func _delete_value(params: Dictionary) -> Dictionary:
	return _mutation(str(params.get("document", params.get("path", ""))), func(document: UIForgeDocument) -> Dictionary:
		return UIForgeDocumentOperations.delete_value(document, str(params.get("node", params.get("node_id", ""))))
	, str(params.get("expected_revision", "")))

static func _move_value(params: Dictionary) -> Dictionary:
	return _mutation(str(params.get("document", params.get("path", ""))), func(document: UIForgeDocument) -> Dictionary:
		return UIForgeDocumentOperations.move_value(document, str(params.get("node", params.get("node_id", ""))), str(params.get("parent", params.get("parent_id", ""))), int(params.get("index", -1)))
	, str(params.get("expected_revision", "")))

static func _duplicate_value(params: Dictionary) -> Dictionary:
	return _mutation(str(params.get("document", params.get("path", ""))), func(document: UIForgeDocument) -> Dictionary:
		return UIForgeDocumentOperations.duplicate_value(document, str(params.get("node", params.get("node_id", ""))), str(params.get("new_id", "")))
	, str(params.get("expected_revision", "")))

static func _batch_document(params: Dictionary) -> Dictionary:
	var path := str(params.get("document", params.get("path", "")))
	if path.is_empty():
		return {"success": false, "errors": [{"code": "USAGE", "message": "batch requires document."}]}
	var operations: Array = params.get("operations", [])
	if not operations is Array or operations.is_empty():
		return {"success": false, "errors": [{"code": "USAGE", "message": "batch requires operations."}]}
	return UIForgeMutationPipeline.commit_batch(path, operations, str(params.get("expected_revision", "")), bool(params.get("dry_run", false)))

static func _mutation(path: String, mutate: Callable, expected_revision: String = "") -> Dictionary:
	if path.is_empty():
		return {"success": false, "errors": [{"code": "USAGE", "message": "Mutation requires document path."}]}
	if expected_revision.is_empty():
		return UIForgeMutationPipeline.commit(path, mutate)
	return UIForgeMutationPipeline.commit_with_revision(path, mutate, expected_revision)

static func _build_document(params: Dictionary) -> Dictionary:
	var source := str(params.get("document", params.get("path", "")))
	if source.is_empty():
		return {"success": false, "errors": [{"code": "USAGE", "message": "build requires document."}]}
	var output := str(params.get("output", ""))
	if output.is_empty():
		output = "%s.tscn" % source.trim_suffix(".ui.json")
	var flags := _params_flags(params)
	return UIForgeCompiler.new().compile_file(source, output, {"force": flags.force, "allow_outside_project": flags.allow_outside_project})

static func _build_all(params: Dictionary) -> Dictionary:
	var source_dir := str(params.get("source_dir", "examples/specs"))
	var output_dir := str(params.get("output_dir", "examples/scenes"))
	var flags := _params_flags(params)
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
		var result := UIForgeCompiler.new().compile_file("%s/%s" % [source_dir, source_file], output, {"force": flags.force, "allow_outside_project": flags.allow_outside_project})
		if result.success:
			built.append(result)
		else:
			failed.append(result)
	return {"success": failed.is_empty(), "built": built, "failed": failed}

static func _render_document(params: Dictionary) -> Dictionary:
	var source := str(params.get("document", params.get("path", "")))
	if source.is_empty():
		return {"success": false, "errors": [{"code": "USAGE", "message": "render requires document."}]}
	var size := Vector2i(int(params.get("width", 1920)), int(params.get("height", 1080)))
	if params.has("viewport"):
		var viewport_value := str(params.get("viewport", ""))
		if viewport_value.contains("x"):
			var pieces := viewport_value.split("x")
			if pieces.size() == 2:
				size = Vector2i(int(pieces[0]), int(pieces[1]))
	var output := str(params.get("output", ""))
	var state := str(params.get("state", "normal")).to_lower()
	var flags := _params_flags(params)
	if output.is_empty():
		output = ".uiforge/renders/%s_%dx%d.png" % [source.get_file().trim_suffix(".ui.json"), size.x, size.y]
	var output_check := UIForgePaths.validate_output(output, UIForgePaths.ArtifactKind.IMAGE, flags.allow_outside_project)
	if not output_check.ok:
		return {"success": false, "errors": output_check.errors}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output.get_base_dir()))
	var generated_scene := "%s_preview.tscn" % output.trim_suffix(".png")
	var loaded := UIForgeSerializer.load_document(source)
	if loaded.get("document") == null:
		return {"success": false, "errors": loaded.get("errors", [])}
	var render_document: UIForgeDocument = UIForgeCompiler.document_for_preview_state(loaded["document"], state)
	var compiled := UIForgeCompiler.new().compile_document(render_document, generated_scene, source, {"force": flags.force, "allow_outside_project": flags.allow_outside_project})
	if not compiled.success:
		return compiled
	var scene_tree := Engine.get_main_loop() as SceneTree
	if scene_tree == null:
		return {"success": false, "errors": [{"code": "INTERNAL", "message": "Render requires an active SceneTree."}]}
	var packed := load(ProjectSettings.globalize_path(generated_scene)) as PackedScene
	if packed == null:
		return {"success": false, "errors": [{"code": "SCENE_LOAD_FAILED", "message": generated_scene}]}
	var viewport := SubViewport.new()
	viewport.size = size
	viewport.transparent_bg = false
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	scene_tree.root.add_child(viewport)
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
	if instance is Control and not is_equal_approx(render_scale, 1.0):
		(instance as Control).position *= render_scale
	await scene_tree.process_frame
	await scene_tree.process_frame
	var image := viewport.get_texture().get_image()
	if image == null:
		viewport.queue_free()
		return {"success": false, "errors": [{"code": "HEADLESS_RENDER_UNAVAILABLE", "message": "Readable image unavailable on this backend."}], "generated_scene": generated_scene}
	var save_error := image.save_png(ProjectSettings.globalize_path(output))
	viewport.queue_free()
	if save_error != OK:
		return {"success": false, "errors": [{"code": "RENDER_WRITE_FAILED", "message": output}]}
	return {"success": true, "rendered_image": output, "viewport": {"width": size.x, "height": size.y}, "generated_scene": generated_scene, "state": state}

static func _params_flags(params: Dictionary) -> Dictionary:
	return {"force": bool(params.get("force", false)), "allow_outside_project": bool(params.get("allow_outside_project", false))}

static func _error_diagnostics(diagnostics: Array) -> Array:
	var errors: Array = []
	for diagnostic in diagnostics:
		if str(diagnostic.get("severity", "")) == "error":
			errors.append(diagnostic)
	return errors

static func _argv_to_params(command: String, args: PackedStringArray) -> Dictionary:
	var params := {}
	var flags := _cli_flags(args, 1)
	params["force"] = flags.force
	params["allow_outside_project"] = flags.allow_outside_project
	match command:
		"new":
			if args.size() >= 3:
				params["template"] = str(args[1])
				params["output"] = str(args[2])
		"validate", "build":
			if args.size() >= 2:
				params["document"] = str(args[1])
			if command == "build" and args.size() >= 3 and not str(args[2]).begins_with("--"):
				params["output"] = str(args[2])
		"inspect":
			if args.size() >= 2:
				params["document"] = str(args[1])
			if args.size() >= 3:
				params["scope"] = str(args[2])
			if args.size() >= 4 and str(args[2]) == "node":
				params["node"] = str(args[3])
		"get":
			if args.size() >= 3:
				params["document"] = str(args[1])
				params["node"] = str(args[2])
			if args.size() >= 4:
				params["property"] = str(args[3])
		"set":
			if args.size() >= 5:
				params["document"] = str(args[1])
				params["node"] = str(args[2])
				params["property"] = str(args[3])
				params["value"] = str(args[4])
		"add":
			if args.size() >= 4:
				params["document"] = str(args[1])
				params["parent"] = str(args[2])
				params["node_json"] = str(args[3])
		"delete":
			if args.size() >= 3:
				params["document"] = str(args[1])
				params["node"] = str(args[2])
		"move":
			if args.size() >= 4:
				params["document"] = str(args[1])
				params["node"] = str(args[2])
				params["parent"] = str(args[3])
			if args.size() >= 5:
				params["index"] = int(args[4])
		"duplicate":
			if args.size() >= 4:
				params["document"] = str(args[1])
				params["node"] = str(args[2])
				params["new_id"] = str(args[3])
		"build-all":
			if args.size() >= 2 and not str(args[1]).begins_with("--"):
				params["source_dir"] = str(args[1])
			if args.size() >= 3 and not str(args[2]).begins_with("--"):
				params["output_dir"] = str(args[2])
		"render":
			if args.size() >= 2:
				params["document"] = str(args[1])
			var index := 2
			while index < args.size():
				var token := str(args[index])
				if token == "--viewport" and index + 1 < args.size():
					params["viewport"] = str(args[index + 1])
					index += 2
				elif token == "--output" and index + 1 < args.size():
					params["output"] = str(args[index + 1])
					index += 2
				elif token == "--state" and index + 1 < args.size():
					params["state"] = str(args[index + 1])
					index += 2
				elif token == "--reference" and index + 1 < args.size():
					params["reference"] = str(args[index + 1])
					index += 2
				elif token == "--diff" and index + 1 < args.size():
					params["diff"] = str(args[index + 1])
					index += 2
				elif token == "--force":
					params["force"] = true
					index += 1
				elif token == "--allow-outside-project":
					params["allow_outside_project"] = true
					index += 1
				else:
					index += 1
	return params

static func _cli_flags(args: PackedStringArray, start_index: int) -> Dictionary:
	var flags := {"force": false, "allow_outside_project": false, "unknown": []}
	var index := start_index
	while index < args.size():
		var token := str(args[index])
		if token == "--force":
			flags.force = true
			index += 1
		elif token == "--allow-outside-project":
			flags.allow_outside_project = true
			index += 1
		elif token.begins_with("--"):
			flags.unknown.append(token)
			index += 1
		else:
			break
	return flags

static func _help_text() -> String:
	return "UIForge CLI\n\nui capabilities\nui validate <file.ui.json>\nui inspect <file.ui.json>\nui batch <file.ui.json> [--stdin]\nui serve --stdio\nui --machine <method>"
