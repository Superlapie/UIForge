class_name UIForgeValidator
extends RefCounted

const TOP_LEVEL_KEYS: Array[String] = [
	"schema_version", "name", "viewport", "theme", "root", "components",
	"theme_overrides", "metadata", "mock_data", "reference"
]

var diagnostics: Array[Dictionary] = []
var ids: Dictionary = {}
var names: Dictionary = {}
var document: UIForgeDocument
var theme: UIForgeTheme

func validate(input: UIForgeDocument, theme_override: UIForgeTheme = null) -> Dictionary:
	document = input
	theme = theme_override if theme_override != null else UIForgeTheme.from_document(input)
	diagnostics = []
	ids = {}
	names = {}
	for key in document.data.keys():
		if str(key) not in TOP_LEVEL_KEYS:
			_add("error", "UNKNOWN_DOCUMENT_KEY", "Unknown top-level key '%s'." % key, "", "Remove the key or extend the UIForge V1 contract deliberately.")
	if int(document.data.get("schema_version", 0)) != UIForgeTypes.SCHEMA_VERSION:
		_add("error", "SCHEMA_VERSION_UNSUPPORTED", "Document schema_version must be %d." % UIForgeTypes.SCHEMA_VERSION, "", "Run a migration or update the document schema.")
	if str(document.data.get("name", "")).is_empty():
		_add("error", "DOCUMENT_NAME_MISSING", "Document name is required.", "", "Give the document a stable human-readable name.")
	var viewport: Dictionary = {}
	var viewport_value: Variant = document.data.get("viewport", {})
	if viewport_value is Dictionary:
		viewport = viewport_value
	else:
		_add("error", "VIEWPORT_INVALID", "viewport must be an object.", "viewport", "Use {\"width\": 1920, \"height\": 1080}.")
	if int(viewport.get("width", 0)) <= 0 or int(viewport.get("height", 0)) <= 0:
		_add("error", "VIEWPORT_INVALID", "Viewport width and height must be positive.", "viewport", "Use a design resolution such as 1920x1080.")
	var root_node := document.root()
	if root_node.is_empty():
		_add("error", "ROOT_MISSING", "A document must contain a root node.", "", "Add a root Control or WindowFrame.")
	else:
		_validate_node(root_node, "", viewport)
	var theme_overrides: Variant = document.data.get("theme_overrides", {})
	if theme_overrides is Dictionary:
		_scan_tokens(theme_overrides, "document")
	elif document.data.has("theme_overrides"):
		_add("error", "THEME_OVERRIDES_INVALID", "theme_overrides must be an object.", "document", "Use theme_overrides: { tokens: {}, styles: {} }.")
	_validate_custom_components()
	_validate_references()
	return result()

func result() -> Dictionary:
	var errors := 0
	var warnings := 0
	for diagnostic in diagnostics:
		if diagnostic.get("severity") == "error":
			errors += 1
		else:
			warnings += 1
	return {"success": errors == 0, "errors": errors, "warnings": warnings, "diagnostics": diagnostics}

func _validate_node(node: Variant, parent_id: String, viewport: Dictionary) -> void:
	if not node is Dictionary:
		_add("error", "NODE_INVALID", "Every node must be an object.", parent_id, "Replace the value with a node object.")
		return
	var node_id := str(node.get("id", ""))
	var node_type := str(node.get("type", ""))
	if node_id.is_empty():
		_add("error", "NODE_ID_MISSING", "Every node needs a stable unique id.", parent_id, "Use snake_case IDs that remain stable across edits.")
	elif not UIForgeID.is_valid(node_id):
		_add_diagnostic(UIForgeID.diagnostic(node_id))
	elif ids.has(node_id):
		_add("error", "DUPLICATE_ID", "Duplicate node id '%s'." % node_id, node_id, "Rename one node; AI operations address nodes by id.")
	else:
		ids[node_id] = true
	if node_type.is_empty():
		_add("error", "NODE_TYPE_MISSING", "Node '%s' has no type." % node_id, node_id, "Choose a native node or reusable component type.")
	elif not _known_type(node_type):
		_add("error", "UNKNOWN_NODE_TYPE", "Unknown node type '%s'." % node_type, node_id, "Query `ui capabilities` for supported types.")
	elif node_type == "ComponentInstance":
		var component_name := str(node.get("component", ""))
		var custom_components: Dictionary = {}
		var components_value: Variant = document.data.get("components", {})
		if components_value is Dictionary:
			custom_components = components_value
		elif document.data.has("components"):
			_add("error", "COMPONENTS_INVALID", "components must be an object.", "document", "Use components: { ... }.")
		if not UIForgeComponentLibrary.has(component_name) and not custom_components.has(component_name):
			_add("error", "UNKNOWN_COMPONENT", "Unknown component '%s'." % component_name, node_id, "Define the component or choose one from `ui capabilities`.")
	var display_name := str(node.get("name", node_id))
	if names.has(display_name):
		_add("warning", "DUPLICATE_NAME", "Node name '%s' is duplicated." % display_name, node_id, "Use distinct names for easier runtime lookup.")
	names[display_name] = true
	var layout: Dictionary = {}
	if node.has("layout"):
		var layout_value: Variant = node.get("layout")
		if layout_value is Dictionary:
			layout = layout_value
		else:
			_add("error", "LAYOUT_INVALID", "layout must be an object.", node_id, "Move layout values into a JSON object.")
	var properties: Dictionary = {}
	if node.has("properties"):
		var properties_value: Variant = node.get("properties")
		if properties_value is Dictionary:
			properties = properties_value
		else:
			_add("error", "PROPERTIES_INVALID", "properties must be an object.", node_id, "Use properties: { ... }.")
	var position: Array = []
	var size: Array = []
	if layout.has("position"):
		var position_value: Variant = layout.get("position")
		if position_value is Array:
			position = position_value
		else:
			_add("error", "LAYOUT_INVALID", "layout.position must be an array.", node_id, "Use [x, y].")
	if layout.has("size"):
		var size_value: Variant = layout.get("size")
		if size_value is Array:
			size = size_value
		else:
			_add("error", "LAYOUT_INVALID", "layout.size must be an array.", node_id, "Use [width, height].")
	if position.size() >= 2 and size.size() >= 2:
		var right := float(position[0]) + float(size[0])
		var bottom := float(position[1]) + float(size[1])
		if right > float(viewport.get("width", 1920)) + 2.0 or bottom > float(viewport.get("height", 1080)) + 2.0:
			_add("warning", "LAYOUT_OUTSIDE_VIEWPORT", "Node extends beyond the design viewport.", node_id, "Use anchors or a responsive container, or confirm the overflow is intentional.")
	if node_type in UIForgeTypes.INTERACTIVE_TYPES and size.size() >= 2 and (float(size[0]) < 32.0 or float(size[1]) < 32.0):
		_add("warning", "SMALL_HIT_TARGET", "Interactive node is smaller than the recommended 32px hit target.", node_id, "Increase its minimum size unless it is intentionally compact.")
	var children: Array = []
	if node.has("children"):
		var children_value: Variant = node.get("children")
		if children_value is Array:
			children = children_value
		else:
			_add("error", "CHILDREN_INVALID", "children must be an array.", node_id, "Use an array of node objects.")
	else:
		children = node.get("children", [])
	var parent_node := document.find_node(parent_id) if not parent_id.is_empty() else {}
	var parent_type := str(parent_node.get("type", ""))
	if parent_type in ["Label", "RichText", "Button", "TextureButton", "CheckBox", "CheckButton", "Slider", "HSlider", "VSlider", "SpinBox", "ProgressBar", "LineEdit", "TextEdit", "OptionButton", "MenuButton", "LinkButton", "ColorRect", "NinePatchRect", "Separator", "Spacer"]:
		_add("error", "INVALID_PARENT_RELATIONSHIP", "Node '%s' is parented under leaf control '%s'." % [node_id, parent_id], node_id, "Reparent it under a container such as Panel, VBox, or Grid.")
	for child in children:
		_validate_node(child, node_id, viewport)
	_validate_sibling_overlaps(children, node_id, str(node.get("type", "")))
	_validate_node_tokens(node, node_id)
	_validate_node_properties(node, node_id, properties, node_type)

func _validate_node_tokens(node: Dictionary, node_id: String) -> void:
	var inspect_values: Array = [node.get("style", {}), node.get("properties", {}), node.get("states", {}), node.get("effects", {}), node.get("decorations", {})]
	for value in inspect_values:
		_scan_tokens(value, node_id)
	var props: Dictionary = node.get("properties", {}) if node.get("properties", {}) is Dictionary else {}
	for key in props:
		var value: Variant = props[key]
		if (key == "color" or str(key).ends_with("_color") or key == "background") and value is String and not str(value).begins_with("$"):
			_add("warning", "HARDCODED_STYLE_VALUE", "Style value '%s' is hardcoded; prefer a theme token." % key, node_id, "Use values such as $colors.text_primary.")

func _scan_tokens(value: Variant, node_id: String) -> void:
	if value is String and str(value).begins_with("$"):
		if theme.resolve(value, null) == null:
			_add("error", "TOKEN_NOT_FOUND", "Token '%s' does not exist in the active theme." % value, node_id, "Query `ui inspect ... tokens` or choose an existing token.")
	elif value is Dictionary:
		for child in value.values():
			_scan_tokens(child, node_id)
	elif value is Array:
		for child in value:
			_scan_tokens(child, node_id)

func _validate_node_properties(node: Dictionary, node_id: String, properties: Dictionary, node_type: String) -> void:
	var supported_properties := ["text", "title", "label", "count", "show_label", "columns", "slot_size", "gap", "value", "min_value", "max_value", "step", "placeholder", "max_length", "tick_count", "show_percentage", "texture_region", "texture", "icon", "font", "material", "theme", "font_size", "color", "opacity", "modulate", "self_modulate", "outline_size", "font_outline_color", "font_shadow_color", "horizontal_alignment", "vertical_alignment", "alignment", "autowrap", "clip_text", "text_overrun_behavior", "bbcode_enabled", "fit_content", "scroll_active", "disabled", "editable", "focus_mode", "tooltip", "toggle_mode", "button_pressed", "flat", "expand_icon", "icon_alignment", "secret", "clear_button_enabled", "caret_blink", "selecting_enabled", "context_menu_enabled", "select_all_on_focus", "virtual_keyboard_enabled", "tick_count", "ticks_on_borders", "allow_greater", "allow_lesser", "horizontal_scroll_mode", "vertical_scroll_mode", "separation", "visible", "clip_contents", "show_behind_parent", "top_level", "z_as_relative", "y_sort_enabled", "use_parent_material", "clip_children", "texture_filter", "texture_repeat", "light_mask", "visibility_layer", "theme_type_variation", "accessibility_name", "accessibility_description", "auto_translate", "layout_direction", "expand_mode", "stretch_mode", "ignore_texture_size", "flip_h", "flip_v", "patch_margin_left", "patch_margin_top", "patch_margin_right", "patch_margin_bottom", "godot_overrides"]
	for property_name in properties:
		if str(property_name) not in supported_properties:
			_add("error", "UNSUPPORTED_PROPERTY", "Property '%s' is not part of the semantic document contract." % property_name, node_id, "Use a supported property or place the native Godot property under properties.godot_overrides.")
	if properties.has("texture_region"):
		var region: Variant = properties.get("texture_region")
		var valid: bool = region is Array and region.size() == 4
		if valid:
			for value in region:
				if not (value is int or value is float):
					valid = false
		if valid:
			valid = region[0] >= 0 and region[1] >= 0 and region[2] > 0 and region[3] > 0
		if not valid or not str(properties.get("texture", "")).begins_with("res://") or UIForgeComponentLibrary.native_type(node_type) not in ["TextureRect", "TextureButton", "NinePatchRect"]:
			_add("error", "TEXTURE_REGION_INVALID", "Texture region needs a texture control, resource path, and [x, y, positive width, positive height] in pixels.", node_id, "Choose a sprite rectangle with positive dimensions.")
	if properties.has("godot_overrides"):
		var overrides_value: Variant = properties.get("godot_overrides")
		if not overrides_value is Dictionary:
			_add("error", "GODOT_OVERRIDES_INVALID", "properties.godot_overrides must be an object.", node_id, "Use native Godot property paths mapped to JSON values.")
	if properties.has("columns") and (not (properties["columns"] is int or properties["columns"] is float) or int(properties["columns"]) < 1):
		_add("error", "GRID_COLUMNS_INVALID", "Grid columns must be a positive integer.", node_id, "Set properties.columns to 1 or more.")
	if properties.has("value") and not (properties["value"] is float or properties["value"] is int):
		_add("error", "PROPERTY_TYPE_INVALID", "value must be numeric.", node_id, "Use a number for sliders and progress displays.")
	if node.has("action"):
		var action_value: Variant = node.get("action")
		if not action_value is String:
			_add("error", "ACTION_INVALID", "action must be a string identifier.", node_id, "Use a language-neutral identifier such as bank.withdraw.")
	if node.has("binding"):
		var binding_value: Variant = node.get("binding")
		if not binding_value is String:
			_add("error", "BINDING_INVALID", "binding must be a string identifier.", node_id, "Use a placeholder path such as inventory.used.")
	if node.has("effects"):
		var effects_value: Variant = node.get("effects")
		if not (effects_value is Dictionary or effects_value is Array or effects_value is String):
			_add("error", "EFFECTS_INVALID", "effects must be an effect name, object, or array.", node_id, "Use a theme effect name or a list/object of effect presets.")
	if node.has("transitions"):
		var transitions_value: Variant = node.get("transitions")
		if not transitions_value is Dictionary:
			_add("error", "TRANSITIONS_INVALID", "transitions must be an object.", node_id, "Use transition names mapped to preset/duration objects.")
		else:
			for transition_name in transitions_value:
				var transition: Variant = transitions_value[transition_name]
				if not transition is Dictionary:
					_add("error", "TRANSITION_INVALID", "Transition '%s' must be an object." % transition_name, node_id, "Set preset and duration.")
					continue
				var preset := str(transition.get("preset", ""))
				if preset not in ["fade", "scale", "slide", "hover", "button_press", "panel_reveal"]:
					_add("error", "TRANSITION_PRESET_UNKNOWN", "Unknown transition preset '%s'." % preset, node_id, "Use fade, scale, slide, hover, button_press, or panel_reveal.")
				if float(transition.get("duration", 0.18)) <= 0.0:
					_add("error", "TRANSITION_DURATION_INVALID", "Transition duration must be positive.", node_id, "Use a duration such as 0.18.")

func _validate_sibling_overlaps(children: Array, parent_id: String, parent_type: String) -> void:
	if parent_type in UIForgeTypes.CONTAINER_TYPES or children.size() < 2:
		return
	for first_index in children.size():
		if not children[first_index] is Dictionary:
			continue
		var first: Dictionary = children[first_index]
		var first_rect := _node_rect(first)
		if first_rect.size.x <= 0.0 or first_rect.size.y <= 0.0:
			continue
		for second_index in range(first_index + 1, children.size()):
			if not children[second_index] is Dictionary:
				continue
			var second: Dictionary = children[second_index]
			var second_rect := _node_rect(second)
			if first_rect.intersects(second_rect) and _is_interactive(first) and _is_interactive(second):
				_add("warning", "OVERLAPPING_CONTROLS", "Interactive siblings '%s' and '%s' overlap." % [first.get("id", ""), second.get("id", "")], second.get("id", ""), "Use containers, alignment, or explicit intentional-overlap metadata.")

func _node_rect(node: Dictionary) -> Rect2:
	var layout: Dictionary = node.get("layout", {}) if node.get("layout", {}) is Dictionary else {}
	var position: Array = layout.get("position", [0, 0]) if layout.get("position", [0, 0]) is Array else [0, 0]
	var size: Array = layout.get("size", [0, 0]) if layout.get("size", [0, 0]) is Array else [0, 0]
	if position.size() < 2 or size.size() < 2:
		return Rect2()
	return Rect2(Vector2(float(position[0]), float(position[1])), Vector2(float(size[0]), float(size[1])))

func _is_interactive(node: Dictionary) -> bool:
	return str(node.get("type", "")) in UIForgeTypes.INTERACTIVE_TYPES or str(node.get("action", "")).is_empty() == false

func _validate_custom_components() -> void:
	var definitions_value: Variant = document.data.get("components", {})
	if not definitions_value is Dictionary:
		if document.data.has("components"):
			_add("error", "COMPONENTS_INVALID", "components must be an object.", "document", "Use components: { ... }.")
		return
	var definitions: Dictionary = definitions_value
	if definitions.is_empty():
		return
	var visiting: Dictionary = {}
	var visited: Dictionary = {}
	for component_name in definitions:
		_check_component_cycle(str(component_name), definitions, visiting, visited, [])

func _check_component_cycle(name: String, definitions: Dictionary, visiting: Dictionary, visited: Dictionary, chain: Array[String]) -> void:
	if visited.has(name):
		return
	if visiting.has(name):
		_add("error", "COMPONENT_CYCLE", "Circular component dependency: %s -> %s." % [" -> ".join(chain), name], name, "Break the cycle by using a primitive or a lower-level component.")
		return
	visiting[name] = true
	var next_chain := chain.duplicate()
	next_chain.append(name)
	var definition: Dictionary = definitions.get(name, {}) if definitions.get(name, {}) is Dictionary else {}
	var base := str(definition.get("base", ""))
	if definitions.has(base):
		_check_component_cycle(base, definitions, visiting, visited, next_chain)
	visiting.erase(name)
	visited[name] = true

func _validate_references() -> void:
	for node in document.all_nodes():
		var node_id := str(node.get("id", ""))
		var properties: Dictionary = node.get("properties", {}) if node.get("properties", {}) is Dictionary else {}
		for key in ["texture", "icon", "font", "material"]:
			if properties.has(key) and properties[key] is String and str(properties[key]).begins_with("res://"):
				if not ResourceLoader.exists(str(properties[key])):
					_add("error", "RESOURCE_NOT_FOUND", "Resource '%s' was not found." % properties[key], node_id, "Add the asset or remove the reference.")
		var overrides: Variant = properties.get("godot_overrides", {})
		if overrides is Dictionary:
			_scan_resource_references(overrides, node_id)
		_scan_resource_references(node.get("effects", {}), node_id)
		_scan_resource_references(node.get("decorations", {}), node_id)
		_scan_resource_references(node.get("style", {}), node_id)
	_scan_resource_references(document.data.get("theme_overrides", {}), "document")
	_scan_resource_references(theme.data.get("styles", {}), "theme")
	_scan_resource_references(theme.data.get("fonts", {}), "theme")
	_scan_resource_references(theme.data.get("native_controls", {}), "theme")

func _scan_resource_references(value: Variant, node_id: String) -> void:
	if value is String and str(value).begins_with("res://") and not ResourceLoader.exists(str(value)):
		_add("error", "RESOURCE_NOT_FOUND", "Resource '%s' was not found." % value, node_id, "Add the asset or remove the reference.")
	elif value is Dictionary:
		for child in value.values():
			_scan_resource_references(child, node_id)
	elif value is Array:
		for child in value:
			_scan_resource_references(child, node_id)

func _known_type(type_name: String) -> bool:
	return type_name in UIForgeTypes.NATIVE_TYPES or type_name in UIForgeTypes.COMPONENT_TYPES or type_name == "ComponentInstance"

func _add(severity: String, code: String, message: String, node_id: String, recommendation: String) -> void:
	diagnostics.append({"severity": severity, "code": code, "message": message, "node": node_id, "recommendation": recommendation})

func _add_diagnostic(diagnostic: Dictionary) -> void:
	if diagnostic.is_empty():
		return
	diagnostics.append(diagnostic)
