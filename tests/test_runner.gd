extends SceneTree

var failures: Array[String] = []

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	_test_example_documents()
	_test_duplicate_ids()
	_test_token_resolution()
	_test_document_operations()
	_test_compile_samples()
	_test_compile_full_property_fixture()
	_test_validation_contract()
	_test_malformed_document_validation()
	_test_transactional_cli_mutations()
	_test_canvas_drag_release()
	_test_material_system()
	if failures.is_empty():
		print(JSON.stringify({"success": true, "passed": 11, "failed": 0}))
		quit(0)
	else:
		print(JSON.stringify({"success": false, "passed": 11 - failures.size(), "failed": failures.size(), "failures": failures}, "\t"))
		quit(1)

func _test_material_system() -> void:
	var loaded := UIForgeSerializer.load_document("res://examples/specs/bank.ui.json")
	var path := "user://material_bank.tscn"
	_assert(UIForgeCompiler.new().compile_document(loaded.document, path, "", {"allow_outside_project": true, "force": true}).success, "material_bank_compiles")
	var instance := (load(path) as PackedScene).instantiate()
	var surface := instance.get_child(0) as TextureRect
	_assert(surface != null and surface.mouse_filter == Control.MOUSE_FILTER_IGNORE, "surface_behind_content_and_ignores_input")
	_assert(surface != null and surface.anchor_right == 1.0 and surface.anchor_bottom == 1.0, "surface_resizes_with_parent")
	instance.free()
	var hud := UIForgeSerializer.load_document("res://examples/specs/combat_hud.ui.json")
	path = "user://material_hud.tscn"
	_assert(UIForgeCompiler.new().compile_document(hud.document, path, "", {"allow_outside_project": true, "force": true}).success, "material_hud_compiles")
	instance = (load(path) as PackedScene).instantiate()
	var hit_target := instance.get_node("hud_medallion/medallion_action") as Button
	for state in ["normal", "hover", "pressed"]:
		var hit_style := hit_target.get_theme_stylebox(state) as StyleBoxFlat
		_assert(hit_style != null and hit_style.bg_color.a == 0.0 and hit_style.shadow_size == 0, "invisible_hit_target_%s" % state)
	instance.free()
	for state in ["normal", "hover", "pressed", "disabled"]:
		var doc := UIForgeDocument.from_dict({"schema_version": 1, "name": "state_test", "theme": "dark_fantasy", "viewport": {"width": 400, "height": 200}, "root": {"id": "button", "type": "PrimaryButton", "layout": {"size": [180, 36]}, "properties": {"text": "Confirm"}}})
		var preview := UIForgeCompiler.document_for_preview_state(doc, state)
		path = "user://material_%s.tscn" % state
		_assert(UIForgeCompiler.new().compile_document(preview, path, "", {"allow_outside_project": true, "force": true}).success, "compile_state_%s" % state)
		var button := (load(path) as PackedScene).instantiate() as Button
		var box := button.get_theme_stylebox("normal") as StyleBoxTexture
		var expected: String = {"normal": "button_enamel.svg", "hover": "button_hover.svg", "pressed": "button_pressed.svg", "disabled": "button_smoke.svg"}[state]
		_assert(box != null and box.texture.resource_path.ends_with(expected), "preview_texture_%s" % state)
		_assert(not doc.root().has("style"), "preview_does_not_mutate_source_%s" % state)
		button.free()

func _test_example_documents() -> void:
	for filename in ["inventory", "bank", "equipment", "quest_journal", "settings", "combat_hud"]:
		var loaded := UIForgeSerializer.load_document("res://examples/specs/%s.ui.json" % filename)
		_assert(loaded.get("document") != null, "load_%s" % filename)
		if loaded.get("document") != null:
			var result := UIForgeValidator.new().validate(loaded["document"])
			_assert(result.success, "validate_%s" % filename)

func _test_duplicate_ids() -> void:
	var loaded := UIForgeSerializer.load_document("res://tests/fixtures/invalid_duplicate.ui.json")
	var result := UIForgeValidator.new().validate(loaded["document"])
	_assert(not result.success, "duplicate_ids_rejected")

func _test_token_resolution() -> void:
	var theme := UIForgeTheme.load_named("dark_fantasy")
	_assert(theme.resolve("$colors.gold", null) == "#d7b269", "token_resolves")
	_assert(theme.resolve("$colors.missing", null) == null, "missing_token_is_null")

func _test_document_operations() -> void:
	var document := UIForgeSerializer.create_default("operations")
	var root_id := str(document.root().get("id", ""))
	_assert(document.add_child(root_id, {"id": "test_button", "type": "PrimaryButton", "properties": {"text": "Test"}}), "add_node")
	_assert(document.set_property("test_button", "properties.text", "Updated"), "set_property")
	_assert(document.get_property("test_button", "properties.text") == "Updated", "get_property")
	_assert(not document.find_node("test_button").is_empty(), "stable_id")
	_assert(not document.delete_node("test_button").is_empty(), "delete_node")
	var instance := UIForgeComponentLibrary.materialize({"id": "buy_button", "type": "ComponentInstance", "component": "ButtonPrimary", "overrides": {"properties": {"text": "BUY"}}}, {"ButtonPrimary": {"base": "PrimaryButton", "properties": {"text": "BUY"}}})
	_assert(instance.get("type", "") == "Button" and instance.get("properties", {}).get("text", "") == "BUY", "component_instance_override")
	var round_trip_path := "user://uiforge_round_trip.ui.json"
	_assert(UIForgeSerializer.save_document(document, round_trip_path).success, "atomic_save")
	var round_trip := UIForgeSerializer.load_document(round_trip_path)
	_assert(round_trip.get("document") != null and round_trip["document"].root().get("id", "") == root_id, "round_trip_stable_id")

func _test_compile_samples() -> void:
	var compiler := UIForgeCompiler.new()
	for filename in ["inventory", "bank", "equipment", "quest_journal", "settings", "combat_hud"]:
		var target := "user://uiforge_test_%s.tscn" % filename
		var result := compiler.compile_file("res://examples/specs/%s.ui.json" % filename, target, {"allow_outside_project": true, "force": true})
		_assert(result.success, "compile_%s" % filename)
		if filename == "bank" and result.success:
			var scene_text := FileAccess.get_file_as_string(target)
			for artwork in ["button_enamel.svg", "button_hover.svg", "button_pressed.svg"]:
				_assert(scene_text.contains(artwork), "material_state_%s" % artwork)

func _test_compile_full_property_fixture() -> void:
	var target := "user://uiforge_test_full_properties.tscn"
	var result := UIForgeCompiler.new().compile_file("res://tests/fixtures/full_properties.ui.json", target, {"allow_outside_project": true, "force": true})
	_assert(result.success, "compile_full_property_fixture")
	if result.success:
		_assert(load(target) as PackedScene != null, "load_full_property_fixture")
		_assert(FileAccess.get_file_as_string(target).contains("metadata/uiforge_transitions"), "compile_transition_metadata")
		_assert(FileAccess.get_file_as_string(target).contains("metadata/uiforge_effects"), "compile_effect_metadata")

func _test_malformed_document_validation() -> void:
	var malformed := UIForgeDocument.from_dict({"schema_version": 1, "name": "malformed", "viewport": {"width": 800, "height": 600}, "theme": "dark_fantasy", "root": {"id": "root", "type": "Panel", "layout": [], "properties": "bad", "children": {}}})
	var result := UIForgeValidator.new().validate(malformed)
	_assert(not result.success, "malformed_document_rejected")
	_assert(_has_diagnostic(result, "LAYOUT_INVALID"), "malformed_layout_diagnostic")
	_assert(_has_diagnostic(result, "PROPERTIES_INVALID"), "malformed_properties_diagnostic")
	_assert(_has_diagnostic(result, "CHILDREN_INVALID"), "malformed_children_diagnostic")

func _test_transactional_cli_mutations() -> void:
	var source := "user://uiforge_transactional.ui.json"
	var document := UIForgeSerializer.create_default("transactional")
	UIForgeSerializer.save_document(document, source)
	var invalid := UIForgeMutationPipeline.commit(source, func(working: UIForgeDocument) -> Dictionary:
		return UIForgeDocumentOperations.set_value(working, str(working.root().get("id", "")), "properties.columns", "0")
	)
	_assert(not invalid.success and not bool(invalid.get("committed", true)), "invalid_mutation_not_committed")
	var reloaded := UIForgeSerializer.load_document(source)
	_assert(reloaded["document"].get_property(str(reloaded["document"].root().get("id", "")), "properties.columns") == null, "source_untouched_after_invalid_mutation")

func _test_canvas_drag_release() -> void:
	var canvas := UIForgeCanvas.new()
	var document := UIForgeSerializer.create_default("canvas_drag")
	canvas.set_document(document)
	get_root().add_child(canvas)
	var root_id := str(document.root().get("id", ""))
	canvas.select_node(root_id)
	var start_position: Array = document.find_node(root_id).get("layout", {}).get("position", [80, 80])
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = Vector2(120, 120)
	canvas._gui_input(press)
	_assert(canvas.is_dragging or canvas.is_resizing, "canvas_drag_started")
	var motion := InputEventMouseMotion.new()
	motion.position = Vector2(180, 180)
	motion.relative = Vector2(60, 60)
	canvas._gui_input(motion)
	var moved_position: Array = document.find_node(root_id).get("layout", {}).get("position", start_position)
	_assert(moved_position != start_position, "canvas_drag_mutates_position")
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = Vector2(180, 180)
	canvas._gui_input(release)
	_assert(not canvas.is_dragging and not canvas.is_resizing, "canvas_drag_release_clears_state")
	_assert(canvas.drag_start_document.is_empty(), "canvas_drag_snapshot_cleared")
	canvas.queue_free()

func _test_validation_contract() -> void:
	var broken_resource := UIForgeDocument.from_dict({"schema_version": 1, "name": "broken_resource", "viewport": {"width": 800, "height": 600}, "theme": "dark_fantasy", "root": {"id": "root", "type": "Control", "children": [{"id": "missing_texture", "type": "Texture", "properties": {"texture": "res://does_not_exist.svg"}}]}})
	var resource_result := UIForgeValidator.new().validate(broken_resource)
	_assert(_has_diagnostic(resource_result, "RESOURCE_NOT_FOUND"), "broken_resource_rejected")
	var invalid_parent := UIForgeDocument.from_dict({"schema_version": 1, "name": "invalid_parent", "viewport": {"width": 800, "height": 600}, "theme": "dark_fantasy", "root": {"id": "root", "type": "Label", "children": [{"id": "child_button", "type": "Button"}]}})
	var parent_result := UIForgeValidator.new().validate(invalid_parent)
	_assert(_has_diagnostic(parent_result, "INVALID_PARENT_RELATIONSHIP"), "invalid_parent_rejected")
	var unknown_component := UIForgeDocument.from_dict({"schema_version": 1, "name": "unknown_component", "viewport": {"width": 800, "height": 600}, "theme": "dark_fantasy", "root": {"id": "root", "type": "ComponentInstance", "component": "MissingComponent"}})
	var component_result := UIForgeValidator.new().validate(unknown_component)
	_assert(_has_diagnostic(component_result, "UNKNOWN_COMPONENT"), "unknown_component_rejected")
	var unsupported_property := UIForgeDocument.from_dict({"schema_version": 1, "name": "unsupported_property", "viewport": {"width": 800, "height": 600}, "theme": "dark_fantasy", "root": {"id": "root", "type": "Label", "properties": {"not_a_godot_property": true}}})
	var property_result := UIForgeValidator.new().validate(unsupported_property)
	_assert(_has_diagnostic(property_result, "UNSUPPORTED_PROPERTY"), "unsupported_property_rejected")
	var invalid_id := UIForgeDocument.from_dict({"schema_version": 1, "name": "invalid_id", "viewport": {"width": 800, "height": 600}, "theme": "dark_fantasy", "root": {"id": "1bad", "type": "Label"}})
	var id_result := UIForgeValidator.new().validate(invalid_id)
	_assert(_has_diagnostic(id_result, "ID_INVALID"), "invalid_id_rejected")

func _has_diagnostic(result: Dictionary, code: String) -> bool:
	for diagnostic in result.get("diagnostics", []):
		if str(diagnostic.get("code", "")) == code:
			return true
	return false

func _assert(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)
