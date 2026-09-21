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
	_test_material_system()
	if failures.is_empty():
		print(JSON.stringify({"success": true, "passed": 8, "failed": 0}))
		quit(0)
	else:
		print(JSON.stringify({"success": false, "passed": 8 - failures.size(), "failed": failures.size(), "failures": failures}, "\t"))
		quit(1)

func _test_material_system() -> void:
	var loaded := AetherSerializer.load_document("res://examples/specs/bank.ui.json")
	var path := "user://material_bank.tscn"
	_assert(AetherCompiler.new().compile_document(loaded.document, path).success, "material_bank_compiles")
	var instance := (load(path) as PackedScene).instantiate()
	var surface := instance.get_child(0) as TextureRect
	_assert(surface != null and surface.mouse_filter == Control.MOUSE_FILTER_IGNORE, "surface_behind_content_and_ignores_input")
	_assert(surface != null and surface.anchor_right == 1.0 and surface.anchor_bottom == 1.0, "surface_resizes_with_parent")
	instance.free()
	var hud := AetherSerializer.load_document("res://examples/specs/combat_hud.ui.json")
	path = "user://material_hud.tscn"
	_assert(AetherCompiler.new().compile_document(hud.document, path).success, "material_hud_compiles")
	instance = (load(path) as PackedScene).instantiate()
	var hit_target := instance.get_node("hud_medallion/medallion_action") as Button
	for state in ["normal", "hover", "pressed"]:
		var hit_style := hit_target.get_theme_stylebox(state) as StyleBoxFlat
		_assert(hit_style != null and hit_style.bg_color.a == 0.0 and hit_style.shadow_size == 0, "invisible_hit_target_%s" % state)
	instance.free()
	for state in ["normal", "hover", "pressed", "disabled"]:
		var doc := AetherDocument.from_dict({"schema_version": 1, "name": "state_test", "theme": "dark_fantasy", "viewport": {"width": 400, "height": 200}, "root": {"id": "button", "type": "PrimaryButton", "layout": {"size": [180, 36]}, "properties": {"text": "Confirm"}}})
		var preview := AetherCompiler.document_for_preview_state(doc, state)
		path = "user://material_%s.tscn" % state
		_assert(AetherCompiler.new().compile_document(preview, path).success, "compile_state_%s" % state)
		var button := (load(path) as PackedScene).instantiate() as Button
		var box := button.get_theme_stylebox("normal") as StyleBoxTexture
		var expected: String = {"normal": "button_enamel.svg", "hover": "button_hover.svg", "pressed": "button_pressed.svg", "disabled": "button_smoke.svg"}[state]
		_assert(box != null and box.texture.resource_path.ends_with(expected), "preview_texture_%s" % state)
		_assert(not doc.root().has("style"), "preview_does_not_mutate_source_%s" % state)
		button.free()

func _test_example_documents() -> void:
	for filename in ["inventory", "bank", "equipment", "quest_journal", "settings", "combat_hud"]:
		var loaded := AetherSerializer.load_document("res://examples/specs/%s.ui.json" % filename)
		_assert(loaded.get("document") != null, "load_%s" % filename)
		if loaded.get("document") != null:
			var result := AetherValidator.new().validate(loaded["document"])
			_assert(result.success, "validate_%s" % filename)

func _test_duplicate_ids() -> void:
	var loaded := AetherSerializer.load_document("res://tests/fixtures/invalid_duplicate.ui.json")
	var result := AetherValidator.new().validate(loaded["document"])
	_assert(not result.success, "duplicate_ids_rejected")

func _test_token_resolution() -> void:
	var theme := AetherTheme.load_named("dark_fantasy")
	_assert(theme.resolve("$colors.gold", null) == "#d7b269", "token_resolves")
	_assert(theme.resolve("$colors.missing", null) == null, "missing_token_is_null")

func _test_document_operations() -> void:
	var document := AetherSerializer.create_default("operations")
	var root_id := str(document.root().get("id", ""))
	_assert(document.add_child(root_id, {"id": "test_button", "type": "PrimaryButton", "properties": {"text": "Test"}}), "add_node")
	_assert(document.set_property("test_button", "properties.text", "Updated"), "set_property")
	_assert(document.get_property("test_button", "properties.text") == "Updated", "get_property")
	_assert(not document.find_node("test_button").is_empty(), "stable_id")
	_assert(not document.delete_node("test_button").is_empty(), "delete_node")
	var instance := AetherComponentLibrary.materialize({"id": "buy_button", "type": "ComponentInstance", "component": "ButtonPrimary", "overrides": {"properties": {"text": "BUY"}}}, {"ButtonPrimary": {"base": "PrimaryButton", "properties": {"text": "BUY"}}})
	_assert(instance.get("type", "") == "Button" and instance.get("properties", {}).get("text", "") == "BUY", "component_instance_override")
	var round_trip_path := "user://aether_round_trip.ui.json"
	_assert(AetherSerializer.save_document(document, round_trip_path).success, "atomic_save")
	var round_trip := AetherSerializer.load_document(round_trip_path)
	_assert(round_trip.get("document") != null and round_trip["document"].root().get("id", "") == root_id, "round_trip_stable_id")

func _test_compile_samples() -> void:
	var compiler := AetherCompiler.new()
	for filename in ["inventory", "bank", "equipment", "quest_journal", "settings", "combat_hud"]:
		var target := "user://aether_test_%s.tscn" % filename
		var result := compiler.compile_file("res://examples/specs/%s.ui.json" % filename, target)
		_assert(result.success, "compile_%s" % filename)
		if filename == "bank" and result.success:
			var scene_text := FileAccess.get_file_as_string(target)
			for artwork in ["button_enamel.svg", "button_hover.svg", "button_pressed.svg"]:
				_assert(scene_text.contains(artwork), "material_state_%s" % artwork)

func _test_compile_full_property_fixture() -> void:
	var target := "user://aether_test_full_properties.tscn"
	var result := AetherCompiler.new().compile_file("res://tests/fixtures/full_properties.ui.json", target)
	_assert(result.success, "compile_full_property_fixture")
	if result.success:
		_assert(load(target) as PackedScene != null, "load_full_property_fixture")
		_assert(FileAccess.get_file_as_string(target).contains("metadata/aether_transitions"), "compile_transition_metadata")
		_assert(FileAccess.get_file_as_string(target).contains("metadata/aether_effects"), "compile_effect_metadata")

func _test_validation_contract() -> void:
	var broken_resource := AetherDocument.from_dict({"schema_version": 1, "name": "broken_resource", "viewport": {"width": 800, "height": 600}, "theme": "dark_fantasy", "root": {"id": "root", "type": "Control", "children": [{"id": "missing_texture", "type": "Texture", "properties": {"texture": "res://does_not_exist.svg"}}]}})
	var resource_result := AetherValidator.new().validate(broken_resource)
	_assert(_has_diagnostic(resource_result, "RESOURCE_NOT_FOUND"), "broken_resource_rejected")
	var invalid_parent := AetherDocument.from_dict({"schema_version": 1, "name": "invalid_parent", "viewport": {"width": 800, "height": 600}, "theme": "dark_fantasy", "root": {"id": "root", "type": "Label", "children": [{"id": "child_button", "type": "Button"}]}})
	var parent_result := AetherValidator.new().validate(invalid_parent)
	_assert(_has_diagnostic(parent_result, "INVALID_PARENT_RELATIONSHIP"), "invalid_parent_rejected")
	var unknown_component := AetherDocument.from_dict({"schema_version": 1, "name": "unknown_component", "viewport": {"width": 800, "height": 600}, "theme": "dark_fantasy", "root": {"id": "root", "type": "ComponentInstance", "component": "MissingComponent"}})
	var component_result := AetherValidator.new().validate(unknown_component)
	_assert(_has_diagnostic(component_result, "UNKNOWN_COMPONENT"), "unknown_component_rejected")
	var unsupported_property := AetherDocument.from_dict({"schema_version": 1, "name": "unsupported_property", "viewport": {"width": 800, "height": 600}, "theme": "dark_fantasy", "root": {"id": "root", "type": "Label", "properties": {"not_a_godot_property": true}}})
	var property_result := AetherValidator.new().validate(unsupported_property)
	_assert(_has_diagnostic(property_result, "UNSUPPORTED_PROPERTY"), "unsupported_property_rejected")

func _has_diagnostic(result: Dictionary, code: String) -> bool:
	for diagnostic in result.get("diagnostics", []):
		if str(diagnostic.get("code", "")) == code:
			return true
	return false

func _assert(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)
