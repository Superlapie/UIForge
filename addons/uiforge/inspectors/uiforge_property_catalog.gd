class_name UIForgePropertyCatalog
extends RefCounted

## The editor, capabilities command, schema documentation, and compiler share
## this catalog. The semantic fields below keep common UI work approachable;
## the native property inventory below keeps the editor forward-compatible with
## the complete Godot 4.x Control/CanvasItem surface.

static func definitions(node_type: String) -> Array[Dictionary]:
	var native := UIForgeComponentLibrary.native_type(node_type)
	var fields: Array[Dictionary] = []
	_add_layout(fields)
	_add_common(fields, native)
	if native in ["Label", "RichTextLabel", "Button", "CheckBox", "CheckButton", "MenuButton", "LinkButton", "LineEdit", "TextEdit"]:
		_add_typography(fields, native)
	if native in ["Button", "TextureButton", "CheckBox", "CheckButton", "MenuButton", "LinkButton"]:
		_add_button(fields)
	if native == "LineEdit":
		_add_line_edit(fields)
	if native in ["HSlider", "VSlider", "Slider", "SpinBox"]:
		_add_slider(fields)
	if native == "ProgressBar":
		_add_progress(fields)
	if native in ["TextureRect", "TextureButton", "NinePatchRect"]:
		_add_texture(fields, native)
	if native in ["GridContainer", "HBoxContainer", "VBoxContainer", "MarginContainer", "CenterContainer", "PanelContainer", "ScrollContainer", "TabBar"]:
		_add_container(fields, native)
	_add_interaction(fields, native)
	_add_style(fields, native)
	if node_type in ["WindowFrame", "ModalDialog"]:
		fields.append({"path": "properties.title", "label": "Window title", "type": "string", "category": "Content", "default": ""})
	if node_type in ["ItemSlot", "EquipmentSlot"]:
		fields.append({"path": "properties.label", "label": "Slot label", "type": "string", "category": "Content", "default": ""})
		fields.append({"path": "properties.count", "label": "Stack count", "type": "string", "category": "Content", "default": ""})
		fields.append({"path": "properties.show_label", "label": "Show slot label", "type": "bool", "category": "Content", "default": false})
	if node_type == "ItemGrid":
		fields.append({"path": "properties.slot_size", "label": "Slot size / token", "type": "string", "category": "Layout", "default": "$slot_size.md"})
		fields.append({"path": "properties.gap", "label": "Slot gap / token", "type": "string", "category": "Layout", "default": "$spacing.sm"})
	return fields

static func capability_groups() -> Dictionary:
	var groups: Dictionary = {}
	for node_type in UIForgeTypes.NATIVE_TYPES + UIForgeTypes.COMPONENT_TYPES:
		for field in definitions(str(node_type)):
			var category := str(field.get("category", "Advanced"))
			if not groups.has(category):
				groups[category] = []
			var label := str(field.get("path", ""))
			if label not in groups[category]:
				groups[category].append(label)
	return groups

static func capability_schemas() -> Dictionary:
	var result: Dictionary = {}
	for node_type in UIForgeTypes.NATIVE_TYPES + UIForgeTypes.COMPONENT_TYPES:
		result[str(node_type)] = definitions(str(node_type))
	return result

static func native_property_schemas() -> Dictionary:
	var result: Dictionary = {}
	for node_type in UIForgeTypes.NATIVE_TYPES + UIForgeTypes.COMPONENT_TYPES:
		result[str(node_type)] = native_properties_for(str(node_type))
	return result

static func native_properties_for(node_type: String) -> Array[Dictionary]:
	var native := UIForgeComponentLibrary.native_type(node_type)
	var properties: Array[Dictionary] = []
	var seen: Dictionary = {}
	for raw in ClassDB.class_get_property_list(native):
		if not raw is Dictionary:
			continue
		var property_name := str(raw.get("name", ""))
		var usage := int(raw.get("usage", 0))
		if property_name.is_empty() or seen.has(property_name):
			continue
		# ClassDB includes category/group rows alongside real properties. They
		# are useful to Godot's own inspector but are not editable values.
		if usage & PROPERTY_USAGE_CATEGORY != 0 or usage & PROPERTY_USAGE_GROUP != 0 or usage & PROPERTY_USAGE_SUBGROUP != 0:
			continue
		seen[property_name] = true
		properties.append({
			"name": property_name,
			"type": int(raw.get("type", TYPE_NIL)),
			"value_type": native_field_type(raw),
			"variant_type": int(raw.get("type", TYPE_NIL)),
			"hint": int(raw.get("hint", PROPERTY_HINT_NONE)),
			"hint_string": str(raw.get("hint_string", "")),
			"usage": usage,
			"editable": usage & PROPERTY_USAGE_READ_ONLY == 0,
			"class_name": str(raw.get("class_name", ""))
		})
	return properties

static func native_field_type(property_info: Dictionary) -> String:
	var type := int(property_info.get("type", TYPE_NIL))
	match type:
		TYPE_BOOL:
			return "bool"
		TYPE_INT:
			return "int"
		TYPE_FLOAT:
			return "float"
		TYPE_COLOR:
			return "color"
		TYPE_ARRAY, TYPE_DICTIONARY, TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY:
			return "multiline_json"
		TYPE_VECTOR2, TYPE_VECTOR2I, TYPE_VECTOR3, TYPE_VECTOR3I, TYPE_VECTOR4, TYPE_VECTOR4I, TYPE_RECT2, TYPE_RECT2I, TYPE_TRANSFORM2D, TYPE_PLANE, TYPE_QUATERNION, TYPE_AABB, TYPE_BASIS, TYPE_TRANSFORM3D:
			return "json"
		TYPE_NODE_PATH:
			return "node_path"
		TYPE_OBJECT:
			return "resource"
		_:
			return "string"

static func _add_layout(fields: Array[Dictionary]) -> void:
	fields.append({"path": "layout.position", "label": "Position", "type": "vec2", "category": "Layout", "default": [0.0, 0.0]})
	fields.append({"path": "layout.size", "label": "Size", "type": "vec2", "category": "Layout", "default": [120.0, 40.0]})
	fields.append({"path": "layout.min_size", "label": "Minimum size", "type": "vec2", "category": "Layout", "default": [0.0, 0.0]})
	fields.append({"path": "layout.max_size", "label": "Maximum size", "type": "vec2", "category": "Layout", "default": [-1.0, -1.0]})
	fields.append({"path": "layout.anchors_preset", "label": "Anchors preset", "type": "enum", "category": "Layout", "options": {"top_left": "Top Left", "center": "Center", "bottom_right": "Bottom Right", "full_rect": "Full Rect"}})
	for side in ["left", "top", "right", "bottom"]:
		fields.append({"path": "layout.anchors.%s" % side, "label": "Anchor %s" % side.capitalize(), "type": "float", "category": "Layout", "default": 0.0})
		fields.append({"path": "layout.offsets.%s" % side, "label": "Offset %s" % side.capitalize(), "type": "float", "category": "Layout", "default": 0.0})
	fields.append({"path": "layout.grow_horizontal", "label": "Grow horizontal", "type": "enum", "category": "Layout", "options": {0: "Begin", 1: "End", 2: "Both"}})
	fields.append({"path": "layout.grow_vertical", "label": "Grow vertical", "type": "enum", "category": "Layout", "options": {0: "Begin", 1: "End", 2: "Both"}})
	fields.append({"path": "layout.size_flags_horizontal", "label": "Horizontal sizing", "type": "enum", "category": "Layout", "options": {0: "Shrink Begin", 1: "Fill", 2: "Expand", 3: "Expand Fill", 4: "Shrink Center", 8: "Shrink End"}})
	fields.append({"path": "layout.size_flags_vertical", "label": "Vertical sizing", "type": "enum", "category": "Layout", "options": {0: "Shrink Begin", 1: "Fill", 2: "Expand", 3: "Expand Fill", 4: "Shrink Center", 8: "Shrink End"}})
	fields.append({"path": "layout.size_flags_stretch_ratio", "label": "Stretch ratio", "type": "float", "category": "Layout", "default": 1.0})
	fields.append({"path": "layout.z_index", "label": "Z index", "type": "int", "category": "Layout", "default": 0})
	fields.append({"path": "layout.mouse_filter", "label": "Mouse filter", "type": "enum", "category": "Interaction", "options": {0: "Stop", 1: "Pass", 2: "Ignore"}})
	fields.append({"path": "layout.pivot", "label": "Pivot", "type": "vec2", "category": "Layout", "default": [0.0, 0.0]})
	fields.append({"path": "layout.rotation_degrees", "label": "Rotation", "type": "float", "category": "Layout", "default": 0.0})
	fields.append({"path": "layout.scale", "label": "Scale", "type": "vec2", "category": "Layout", "default": [1.0, 1.0]})

static func _add_common(fields: Array[Dictionary], native: String) -> void:
	if native in ["Label", "RichTextLabel", "Button", "CheckBox", "CheckButton", "MenuButton", "LinkButton", "LineEdit", "TextEdit"]:
		fields.append({"path": "properties.text", "label": "Text", "type": "multiline", "category": "Content", "default": ""})
	if native in ["Panel", "PanelContainer", "Button", "TextureButton", "CheckBox", "CheckButton", "LineEdit", "ProgressBar", "TabBar", "ScrollContainer"]:
		fields.append({"path": "style", "label": "Style reference", "type": "string", "category": "Style", "default": ""})
	fields.append({"path": "properties.tooltip", "label": "Tooltip", "type": "string", "category": "Interaction", "default": ""})
	if native in ["Button", "TextureButton", "CheckBox", "LinkButton"]:
		fields.append({"path": "properties.disabled", "label": "Disabled", "type": "bool", "category": "Interaction", "default": false})
	fields.append({"path": "properties.visible", "label": "Visible", "type": "bool", "category": "Advanced", "default": true})
	fields.append({"path": "properties.clip_contents", "label": "Clip contents", "type": "bool", "category": "Layout", "default": false})
	fields.append({"path": "properties.focus_mode", "label": "Focus mode", "type": "enum", "category": "Interaction", "options": {0: "None", 1: "Click", 2: "All"}})
	for direction in ["top", "bottom", "left", "right"]:
		fields.append({"path": "properties.focus_neighbor_%s" % direction, "label": "Focus neighbor %s" % direction.capitalize(), "type": "string", "category": "Interaction", "default": ""})
	fields.append({"path": "properties.mouse_default_cursor_shape", "label": "Cursor shape", "type": "enum", "category": "Interaction", "options": {0: "Arrow", 1: "I-beam", 2: "Pointing Hand", 3: "Cross", 4: "Wait", 5: "Busy", 6: "Drag", 7: "Resize Horizontal", 8: "Resize Vertical", 9: "Resize Diagonal", 10: "Resize Diagonal", 11: "Move", 12: "Forbidden", 13: "Help"}})
	fields.append({"path": "properties.modulate", "label": "Modulate", "type": "color", "category": "Style", "default": "#ffffff"})
	fields.append({"path": "properties.self_modulate", "label": "Self modulate", "type": "color", "category": "Style", "default": "#ffffff"})
	fields.append({"path": "properties.show_behind_parent", "label": "Draw behind parent", "type": "bool", "category": "Advanced", "default": false})
	fields.append({"path": "properties.top_level", "label": "Top level", "type": "bool", "category": "Advanced", "default": false})
	fields.append({"path": "properties.z_as_relative", "label": "Relative Z", "type": "bool", "category": "Advanced", "default": true})
	fields.append({"path": "properties.y_sort_enabled", "label": "Y sort", "type": "bool", "category": "Advanced", "default": false})
	fields.append({"path": "properties.use_parent_material", "label": "Use parent material", "type": "bool", "category": "Style", "default": false})
	fields.append({"path": "properties.clip_children", "label": "Clip children mode", "type": "enum", "category": "Advanced", "options": {0: "Disabled", 1: "Only Children", 2: "All"}})
	fields.append({"path": "properties.texture_filter", "label": "Texture filter", "type": "enum", "category": "Style", "options": {0: "Inherit", 1: "Nearest", 2: "Linear", 3: "Nearest Mipmap", 4: "Linear Mipmap"}})
	fields.append({"path": "properties.texture_repeat", "label": "Texture repeat", "type": "enum", "category": "Style", "options": {0: "Inherit", 1: "Disabled", 2: "Enabled"}})
	fields.append({"path": "properties.light_mask", "label": "Light mask", "type": "int", "category": "Advanced", "default": 1})
	fields.append({"path": "properties.visibility_layer", "label": "Visibility layer", "type": "int", "category": "Advanced", "default": 1})
	fields.append({"path": "properties.material", "label": "Material resource", "type": "resource", "category": "Style", "resource_kind": "material", "default": ""})
	fields.append({"path": "properties.theme", "label": "Godot Theme resource", "type": "resource", "category": "Style", "resource_kind": "theme", "default": ""})
	fields.append({"path": "properties.theme_type_variation", "label": "Theme type variation", "type": "string", "category": "Style", "default": ""})
	fields.append({"path": "properties.accessibility_name", "label": "Accessibility name", "type": "string", "category": "Accessibility", "default": ""})
	fields.append({"path": "properties.accessibility_description", "label": "Accessibility description", "type": "multiline", "category": "Accessibility", "default": ""})
	fields.append({"path": "properties.auto_translate", "label": "Auto translate", "type": "bool", "category": "Accessibility", "default": true})
	fields.append({"path": "properties.layout_direction", "label": "Layout direction", "type": "enum", "category": "Accessibility", "options": {0: "Inherited", 1: "LTR", 2: "RTL"}})
	# Godot adds properties across minor versions and specialized Control
	# subclasses. This typed escape hatch keeps those properties authorable
	# without changing the canonical document schema for every engine release.
	fields.append({"path": "properties.godot_overrides", "label": "Godot property overrides (JSON)", "type": "multiline_json", "category": "Advanced", "default": {}})

static func _add_typography(fields: Array[Dictionary], native: String) -> void:
	fields.append({"path": "properties.font", "label": "Font resource", "type": "resource", "category": "Typography", "resource_kind": "font", "default": ""})
	fields.append({"path": "properties.font_size", "label": "Font size / token", "type": "string", "category": "Typography", "default": "$font_size.body"})
	fields.append({"path": "properties.color", "label": "Text color / token", "type": "color", "category": "Typography", "default": "$colors.text_primary"})
	fields.append({"path": "properties.outline_size", "label": "Outline size", "type": "int", "category": "Typography", "default": 0})
	fields.append({"path": "properties.font_outline_color", "label": "Outline color / token", "type": "color", "category": "Typography", "default": "$colors.shadow"})
	fields.append({"path": "properties.font_shadow_color", "label": "Shadow color / token", "type": "color", "category": "Typography", "default": "$colors.shadow"})
	fields.append({"path": "properties.horizontal_alignment", "label": "Horizontal alignment", "type": "enum", "category": "Typography", "options": {0: "Left", 1: "Center", 2: "Right", 3: "Fill"}})
	fields.append({"path": "properties.vertical_alignment", "label": "Vertical alignment", "type": "enum", "category": "Typography", "options": {0: "Top", 1: "Center", 2: "Bottom", 3: "Fill"}})
	fields.append({"path": "properties.autowrap", "label": "Autowrap", "type": "bool", "category": "Typography", "default": false})
	fields.append({"path": "properties.clip_text", "label": "Clip text", "type": "bool", "category": "Typography", "default": false})
	fields.append({"path": "properties.text_overrun_behavior", "label": "Text overrun", "type": "enum", "category": "Typography", "options": {0: "No trim", 1: "Ellipsis", 2: "Word ellipsis", 3: "Trimming character", 4: "Word trimming character"}})
	if native == "RichTextLabel":
		fields.append({"path": "properties.bbcode_enabled", "label": "BBCode enabled", "type": "bool", "category": "Content", "default": false})
		fields.append({"path": "properties.fit_content", "label": "Fit content", "type": "bool", "category": "Layout", "default": false})
		fields.append({"path": "properties.scroll_active", "label": "Scroll active", "type": "bool", "category": "Interaction", "default": true})

static func _add_button(fields: Array[Dictionary]) -> void:
	fields.append({"path": "properties.toggle_mode", "label": "Toggle mode", "type": "bool", "category": "Interaction", "default": false})
	fields.append({"path": "properties.button_pressed", "label": "Pressed", "type": "bool", "category": "Interaction", "default": false})
	fields.append({"path": "properties.alignment", "label": "Button alignment", "type": "enum", "category": "Typography", "options": {0: "Left", 1: "Center", 2: "Right"}})
	fields.append({"path": "properties.flat", "label": "Flat button", "type": "bool", "category": "Style", "default": false})
	fields.append({"path": "properties.expand_icon", "label": "Expand icon", "type": "bool", "category": "Content", "default": false})
	fields.append({"path": "properties.icon_alignment", "label": "Icon alignment", "type": "enum", "category": "Content", "options": {0: "Left", 1: "Center", 2: "Right"}})

static func _add_line_edit(fields: Array[Dictionary]) -> void:
	fields.append({"path": "properties.placeholder", "label": "Placeholder", "type": "string", "category": "Content", "default": ""})
	fields.append({"path": "properties.editable", "label": "Editable", "type": "bool", "category": "Interaction", "default": true})
	fields.append({"path": "properties.secret", "label": "Secret input", "type": "bool", "category": "Interaction", "default": false})
	fields.append({"path": "properties.max_length", "label": "Maximum length", "type": "int", "category": "Content", "default": 0})
	fields.append({"path": "properties.clear_button_enabled", "label": "Clear button", "type": "bool", "category": "Interaction", "default": false})
	fields.append({"path": "properties.caret_blink", "label": "Caret blink", "type": "bool", "category": "Interaction", "default": true})
	fields.append({"path": "properties.selecting_enabled", "label": "Selecting enabled", "type": "bool", "category": "Interaction", "default": true})
	fields.append({"path": "properties.context_menu_enabled", "label": "Context menu", "type": "bool", "category": "Interaction", "default": true})
	fields.append({"path": "properties.select_all_on_focus", "label": "Select all on focus", "type": "bool", "category": "Interaction", "default": false})
	fields.append({"path": "properties.virtual_keyboard_enabled", "label": "Virtual keyboard", "type": "bool", "category": "Interaction", "default": true})

static func _add_slider(fields: Array[Dictionary]) -> void:
	fields.append({"path": "properties.value", "label": "Value", "type": "float", "category": "Content", "default": 0.0})
	fields.append({"path": "properties.min_value", "label": "Minimum", "type": "float", "category": "Content", "default": 0.0})
	fields.append({"path": "properties.max_value", "label": "Maximum", "type": "float", "category": "Content", "default": 100.0})
	fields.append({"path": "properties.step", "label": "Step", "type": "float", "category": "Content", "default": 1.0})
	fields.append({"path": "properties.editable", "label": "Editable", "type": "bool", "category": "Interaction", "default": true})
	fields.append({"path": "properties.tick_count", "label": "Tick count", "type": "int", "category": "Content", "default": 0})
	fields.append({"path": "properties.ticks_on_borders", "label": "Ticks on borders", "type": "bool", "category": "Content", "default": false})
	fields.append({"path": "properties.allow_greater", "label": "Allow greater", "type": "bool", "category": "Content", "default": false})
	fields.append({"path": "properties.allow_lesser", "label": "Allow lesser", "type": "bool", "category": "Content", "default": false})

static func _add_progress(fields: Array[Dictionary]) -> void:
	fields.append({"path": "background_style", "label": "Track style", "type": "string", "category": "Style", "default": "status_track"})
	fields.append({"path": "fill_style", "label": "Fill style", "type": "string", "category": "Style", "default": "button_primary"})
	fields.append({"path": "properties.value", "label": "Value", "type": "float", "category": "Content", "default": 0.0})
	fields.append({"path": "properties.min_value", "label": "Minimum", "type": "float", "category": "Content", "default": 0.0})
	fields.append({"path": "properties.max_value", "label": "Maximum", "type": "float", "category": "Content", "default": 100.0})
	fields.append({"path": "properties.show_percentage", "label": "Show percentage", "type": "bool", "category": "Content", "default": true})

static func _add_texture(fields: Array[Dictionary], native: String) -> void:
	fields.append({"path": "properties.texture_region", "label": "Sprite region [x, y, width, height] (pixels)", "type": "json", "category": "Content"})
	fields.append({"path": "properties.texture", "label": "Texture resource", "type": "resource", "category": "Content", "resource_kind": "texture", "default": ""})
	fields.append({"path": "properties.expand_mode", "label": "Expand mode", "type": "enum", "category": "Layout", "options": {0: "Keep Size", 1: "Ignore Size", 2: "Fit Width", 3: "Fit Width Proportional", 4: "Fit Height", 5: "Fit Height Proportional"}})
	fields.append({"path": "properties.stretch_mode", "label": "Stretch mode", "type": "enum", "category": "Layout", "options": {0: "Scale", 1: "Tile", 2: "Keep", 3: "Keep Centered", 4: "Keep Aspect", 5: "Keep Aspect Centered", 6: "Keep Aspect Covered"}})
	fields.append({"path": "properties.ignore_texture_size", "label": "Ignore texture size", "type": "bool", "category": "Layout", "default": false})
	fields.append({"path": "properties.flip_h", "label": "Flip horizontal", "type": "bool", "category": "Content", "default": false})
	fields.append({"path": "properties.flip_v", "label": "Flip vertical", "type": "bool", "category": "Content", "default": false})
	if native == "NinePatchRect":
		for side in ["left", "top", "right", "bottom"]:
			fields.append({"path": "properties.patch_margin_%s" % side, "label": "Patch margin %s" % side.capitalize(), "type": "int", "category": "Style", "default": 0})

static func _add_container(fields: Array[Dictionary], native: String) -> void:
	if native in ["GridContainer"]:
		fields.append({"path": "properties.columns", "label": "Columns", "type": "int", "category": "Layout", "default": 1})
	if native in ["HBoxContainer", "VBoxContainer", "GridContainer", "MarginContainer", "CenterContainer", "PanelContainer"]:
		fields.append({"path": "properties.separation", "label": "Separation", "type": "int", "category": "Layout", "default": 0})
		fields.append({"path": "properties.alignment", "label": "Container alignment", "type": "enum", "category": "Layout", "options": {0: "Begin", 1: "Center", 2: "End"}})
	if native == "ScrollContainer":
		fields.append({"path": "properties.horizontal_scroll_mode", "label": "Horizontal scroll", "type": "enum", "category": "Interaction", "options": {0: "Disabled", 1: "Auto", 2: "Always"}})
		fields.append({"path": "properties.vertical_scroll_mode", "label": "Vertical scroll", "type": "enum", "category": "Interaction", "options": {0: "Disabled", 1: "Auto", 2: "Always"}})

static func _add_interaction(fields: Array[Dictionary], _native: String) -> void:
	fields.append({"path": "action", "label": "Action identifier", "type": "string", "category": "Interaction", "default": ""})
	fields.append({"path": "binding", "label": "Binding identifier", "type": "string", "category": "Interaction", "default": ""})
	fields.append({"path": "transitions", "label": "Lightweight transitions JSON", "type": "multiline_json", "category": "Interaction", "default": {}})
	fields.append({"path": "effects", "label": "Effect presets JSON", "type": "multiline_json", "category": "Style", "default": {}})
	fields.append({"path": "metadata", "label": "Metadata JSON", "type": "json", "category": "Advanced", "default": {}})
	fields.append({"path": "decorations", "label": "Frame decorations JSON", "type": "multiline_json", "category": "Advanced", "default": {}})

static func _add_style(fields: Array[Dictionary], _native: String) -> void:
	fields.append({"path": "properties.opacity", "label": "Opacity", "type": "float", "category": "Style", "default": 1.0, "min": 0.0, "max": 1.0})
	fields.append({"path": "properties.icon", "label": "Icon resource", "type": "resource", "category": "Content", "resource_kind": "texture", "default": ""})
	if _native == "ColorRect":
		fields.append({"path": "properties.color", "label": "Fill color / token", "type": "color", "category": "Style", "default": "$colors.surface"})
