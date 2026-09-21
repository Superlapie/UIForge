@tool
class_name AetherPropertyInspector
extends ScrollContainer

signal apply_requested(changes: Dictionary)

const RESOURCE_FIELD_SCRIPT := preload("res://addons/aether_ui/inspectors/aether_resource_field.gd")
const NATIVE_PREFIX := "__native__:"

var body: VBoxContainer
var current_node: Dictionary = {}
var current_id: String = ""
var field_controls: Dictionary = {}

func _ready() -> void:
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	body = VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 6)
	add_child(body)
	_show_empty()

func set_node(node: Dictionary) -> void:
	current_node = node.duplicate(true)
	current_id = str(current_node.get("id", ""))
	_rebuild()

func clear_node() -> void:
	current_node = {}
	current_id = ""
	_rebuild()

func _rebuild() -> void:
	if body == null:
		return
	for child in body.get_children():
		child.free()
	field_controls.clear()
	if current_node.is_empty():
		_show_empty()
		return
	var header := Label.new()
	header.text = "%s  ·  %s" % [current_id, str(current_node.get("type", "Control"))]
	header.add_theme_color_override("font_color", Color("c9a96a"))
	header.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(header)
	var hint := Label.new()
	hint.text = "Typed Godot properties · edits stay in the JSON source model"
	hint.add_theme_color_override("font_color", Color("8d97a7"))
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(hint)
	var last_category := ""
	for spec in AetherPropertyCatalog.definitions(str(current_node.get("type", "Control"))):
		var category := str(spec.get("category", "Advanced"))
		if category != last_category:
			_add_category(category)
			last_category = category
		_add_field(spec)
	var native_specs := _native_specs(str(current_node.get("type", "Control")))
	if not native_specs.is_empty():
		_add_category("Godot Native Properties")
		var native_hint := Label.new()
		native_hint.text = "%d engine properties · specialized/new 4.x properties stay source-compatible" % native_specs.size()
		native_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		native_hint.add_theme_color_override("font_color", Color("#8d97a7"))
		body.add_child(native_hint)
		for spec in native_specs:
			_add_field(spec)
	var apply := Button.new()
	apply.text = "Apply inspector changes"
	apply.tooltip_text = "Commit all visible property edits as one undoable operation."
	apply.pressed.connect(_on_apply)
	body.add_child(apply)
	var footer := Label.new()
	footer.text = "Drag assets onto the canvas or resource fields. Token values remain editable as $tokens."
	footer.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	footer.add_theme_color_override("font_color", Color("8d97a7"))
	body.add_child(footer)

func _show_empty() -> void:
	var empty_state := Label.new()
	empty_state.text = "Select an element to edit layout, content, style, typography, interaction, and metadata."
	empty_state.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	empty_state.add_theme_color_override("font_color", Color("8d97a7"))
	body.add_child(empty_state)

func _add_category(category: String) -> void:
	var separator := HSeparator.new()
	body.add_child(separator)
	var label := Label.new()
	label.text = category.to_upper()
	label.add_theme_color_override("font_color", Color("c9a96a"))
	label.add_theme_font_size_override("font_size", 11)
	body.add_child(label)

func _add_field(spec: Dictionary) -> void:
	var path := str(spec.get("path", ""))
	if field_controls.has(path):
		return
	var effective_spec: Dictionary = spec.duplicate(true)
	var is_native := bool(effective_spec.get("native", false))
	var native_name := str(effective_spec.get("native_name", ""))
	if is_native:
		var override_state := _native_override_state(native_name)
		effective_spec["_native_present"] = bool(override_state.get("present", false))
		effective_spec["_native_initial"] = override_state.get("value", null)
		effective_spec["_native_default"] = _native_default(str(effective_spec.get("type", "string")))
	var label := Label.new()
	label.text = str(effective_spec.get("label", path))
	label.tooltip_text = path
	label.add_theme_color_override("font_color", Color("aeb7c5"))
	body.add_child(label)
	var value: Variant = _value_at(path)
	if path == "style" and value is Dictionary:
		effective_spec["type"] = "multiline_json"
		effective_spec["default"] = {}
	if is_native and not bool(effective_spec.get("_native_present", false)):
		value = effective_spec.get("_native_default", null)
	if value == null and effective_spec.has("default"):
		value = effective_spec.get("default")
	var field_type := str(effective_spec.get("type", "string"))
	if value == null and field_type == "enum":
		var enum_options: Dictionary = effective_spec.get("options", {})
		if not enum_options.is_empty():
			value = enum_options.keys()[0]
	var controls: Array[Control] = []
	match field_type:
		"vec2":
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 4)
			var x := _line_edit("x")
			var y := _line_edit("y")
			var vector: Array = value if value is Array else [0.0, 0.0]
			x.text = str(vector[0]) if vector.size() > 0 else "0"
			y.text = str(vector[1]) if vector.size() > 1 else "0"
			row.add_child(x)
			row.add_child(y)
			controls = [x, y]
			body.add_child(row)
		"bool":
			var check := CheckBox.new()
			check.text = "Enabled"
			check.button_pressed = bool(value)
			body.add_child(check)
			controls = [check]
		"enum":
			var option := OptionButton.new()
			option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var options: Dictionary = effective_spec.get("options", {})
			for option_value in options.keys():
				option.add_item(str(options[option_value]))
				option.set_item_metadata(option.item_count - 1, option_value)
			var selected := -1
			for index in option.item_count:
				if str(option.get_item_metadata(index)) == str(value):
					selected = index
					break
			if selected >= 0:
				option.select(selected)
			body.add_child(option)
			controls = [option]
		_:
			if field_type == "multiline_json":
				var editor := TextEdit.new()
				editor.custom_minimum_size.y = 120
				editor.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				editor.placeholder_text = _placeholder_for(effective_spec)
				editor.text = _text_value(value, field_type)
				editor.tooltip_text = path
				body.add_child(editor)
				controls = [editor]
			else:
				var line: LineEdit
				if field_type == "resource":
					line = RESOURCE_FIELD_SCRIPT.new()
				else:
					line = LineEdit.new()
				line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				line.placeholder_text = _placeholder_for(effective_spec)
				line.text = _text_value(value, field_type)
				line.tooltip_text = path
				body.add_child(line)
				controls = [line]
	if is_native and not bool(effective_spec.get("editable", true)):
		for control in controls:
			if control is Control:
				control.mouse_filter = Control.MOUSE_FILTER_IGNORE
				control.modulate = Color(1, 1, 1, 0.45)
	field_controls[path] = {"spec": effective_spec, "controls": controls}

func _native_specs(node_type: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for property_info in AetherPropertyCatalog.native_properties_for(node_type):
		var property_name := str(property_info.get("name", ""))
		if property_name.is_empty() or _is_semantic_native_property(property_name):
			continue
		var field_type := str(property_info.get("value_type", "string"))
		result.append({
			"path": "%s%s" % [NATIVE_PREFIX, property_name],
			"label": property_name,
			"type": field_type,
			"category": "Godot Native Properties",
			"native": true,
				"native_name": property_name,
				"editable": bool(property_info.get("editable", true)),
				"hint_string": str(property_info.get("hint_string", "")),
				"variant_type": int(property_info.get("variant_type", TYPE_NIL)),
				"class_name": str(property_info.get("class_name", "")),
			"default": _native_default(field_type)
		})
	return result

func _is_semantic_native_property(property_name: String) -> bool:
	return property_name in [
		"text", "placeholder_text", "visible", "clip_contents", "show_behind_parent", "top_level",
		"z_as_relative", "y_sort_enabled", "use_parent_material", "clip_children", "light_mask",
		"visibility_layer", "texture_filter", "texture_repeat", "layout_direction",
		"mouse_default_cursor_shape", "tooltip_text", "focus_mode", "value", "min_value", "max_value",
		"step", "columns", "editable", "disabled", "autowrap_mode", "horizontal_alignment",
		"vertical_alignment", "show_percentage", "bbcode_enabled", "fit_content", "scroll_active",
		"toggle_mode", "button_pressed", "secret", "clear_button_enabled", "caret_blink",
		"selecting_enabled", "ticks_on_borders", "allow_greater", "allow_lesser", "ignore_texture_size",
		"flip_h", "flip_v", "max_length", "tick_count", "horizontal_scroll_mode", "vertical_scroll_mode",
		"alignment", "clip_text", "flat", "expand_icon", "icon_alignment", "text_overrun_behavior",
		"theme_type_variation", "accessibility_name", "accessibility_description", "auto_translate",
		"separation", "modulate", "self_modulate", "material", "theme", "icon", "texture", "expand_mode",
		"stretch_mode", "patch_margin_left", "patch_margin_top", "patch_margin_right", "patch_margin_bottom",
		"font", "font_size", "outline_size", "color", "font_color", "font_outline_color", "font_shadow_color",
		"script", "resource_local_to_scene", "resource_name", "resource_path", "owner", "scene_file_path",
		"offset_left", "offset_top", "offset_right", "offset_bottom", "anchor_left", "anchor_top", "anchor_right",
		"anchor_bottom", "grow_horizontal", "grow_vertical", "size_flags_horizontal", "size_flags_vertical",
		"size_flags_stretch_ratio", "custom_minimum_size", "custom_maximum_size", "pivot_offset", "rotation",
		"scale", "z_index", "mouse_filter"
	]

func _native_override_state(property_name: String) -> Dictionary:
	var properties: Dictionary = current_node.get("properties", {})
	var overrides: Dictionary = properties.get("godot_overrides", {})
	if overrides is Dictionary and overrides.has(property_name):
		return {"present": true, "value": overrides[property_name]}
	return {"present": false, "value": null}

func _native_default(field_type: String) -> Variant:
	match field_type:
		"bool":
			return false
		"int":
			return 0
		"float":
			return 0.0
		"multiline_json":
			return {}
		"json":
			return []
		_:
			return ""

func _line_edit(placeholder: String) -> LineEdit:
	var field := LineEdit.new()
	field.placeholder_text = placeholder
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return field

func _placeholder_for(spec: Dictionary) -> String:
	if spec.get("type") == "node_path":
		return "../Node or NodePath"
	if spec.get("type") == "color":
		return "#RRGGBB or $colors.token"
	if spec.get("type") == "resource":
		return "res://asset.tres"
	if spec.get("type") in ["json", "multiline_json"]:
		return "{}"
	if spec.has("hint_string") and not str(spec.get("hint_string", "")).is_empty():
		return str(spec.get("hint_string"))
	return str(spec.get("default", ""))

func _text_value(value: Variant, field_type: String) -> String:
	if value == null:
		return ""
	if field_type in ["json", "multiline_json"]:
		return JSON.stringify(value)
	if field_type == "resource" and value is Dictionary:
		return str(value.get("$resource", value.get("resource", "")))
	if field_type == "node_path" and value is Dictionary:
		return str(value.get("$node_path", ""))
	if value is Dictionary and value.has("$type"):
		return JSON.stringify(value.get("value", value.get("values", [])))
	return str(value)

func _value_at(path: String) -> Variant:
	if path.begins_with(NATIVE_PREFIX):
		return _native_override_state(path.trim_prefix(NATIVE_PREFIX)).get("value", null)
	var cursor: Variant = current_node
	for piece in path.split("."):
		if not cursor is Dictionary or not cursor.has(piece):
			return null
		cursor = cursor[piece]
	return cursor

func _on_apply() -> void:
	var changes: Dictionary = {}
	for path in field_controls:
		var record: Dictionary = field_controls[path]
		var spec: Dictionary = record.get("spec", {})
		var controls: Array = record.get("controls", [])
		if controls.is_empty():
			continue
		if path == "properties.texture_region" and (controls[0] as LineEdit).text.strip_edges().is_empty():
			changes[path] = null
			continue
		if bool(spec.get("native", false)) and (not bool(spec.get("editable", true)) or not _native_field_changed(spec, controls)):
			continue
		changes[path] = _read_value(spec, controls)
	apply_requested.emit(changes)

func _native_field_changed(spec: Dictionary, controls: Array) -> bool:
	var value := _read_value(spec, controls)
	var baseline: Variant = spec.get("_native_initial", spec.get("_native_default", null))
	if not bool(spec.get("_native_present", false)) and value is Dictionary:
		if value.has("$type"):
			value = value.get("value", value.get("values", []))
		elif value.has("$node_path"):
			value = value.get("$node_path", "")
	return JSON.stringify(value) != JSON.stringify(baseline)

func _read_value(spec: Dictionary, controls: Array) -> Variant:
	var field_type := str(spec.get("type", "string"))
	if field_type == "vec2":
		return [_number_from((controls[0] as LineEdit).text, 0.0), _number_from((controls[1] as LineEdit).text, 0.0)]
	if field_type == "bool":
		return (controls[0] as CheckBox).button_pressed
	if field_type == "enum":
		return (controls[0] as OptionButton).get_selected_metadata()
	var text := (controls[0] as TextEdit).text if field_type == "multiline_json" else (controls[0] as LineEdit).text
	match field_type:
		"int":
			return int(text) if not text.strip_edges().is_empty() else int(spec.get("default", 0))
		"float":
			return float(text) if not text.strip_edges().is_empty() else float(spec.get("default", 0.0))
		"json", "multiline_json":
			var parsed: Variant = JSON.parse_string(text)
			if bool(spec.get("native", false)):
				return _native_value(spec, parsed if parsed != null else {})
			return parsed if parsed != null else {}
		"node_path":
			if bool(spec.get("native", false)):
				return {"$node_path": text}
			return text
		_:
			if bool(spec.get("native", false)) and field_type == "resource":
				if text.strip_edges().is_empty():
					return ""
				return {"$resource": text.strip_edges(), "type": str(spec.get("class_name", "Resource"))}
			if bool(spec.get("native", false)) and field_type == "color":
				return {"$type": "Color", "value": text}
			return text

func _native_value(spec: Dictionary, parsed: Variant) -> Variant:
	var class_type := str(spec.get("class_name", ""))
	if class_type == "NodePath" and parsed is Array:
		return {"$type": "Array[NodePath]", "value": parsed}
	var type_name := _native_type_name(int(spec.get("variant_type", TYPE_NIL)))
	if type_name.is_empty():
		return parsed
	return {"$type": type_name, "value": parsed}

func _native_type_name(variant_type: int) -> String:
	match variant_type:
		TYPE_VECTOR2: return "Vector2"
		TYPE_VECTOR2I: return "Vector2i"
		TYPE_VECTOR3: return "Vector3"
		TYPE_VECTOR3I: return "Vector3i"
		TYPE_VECTOR4: return "Vector4"
		TYPE_VECTOR4I: return "Vector4i"
		TYPE_RECT2: return "Rect2"
		TYPE_RECT2I: return "Rect2i"
		TYPE_TRANSFORM2D: return "Transform2D"
		TYPE_PLANE: return "Plane"
		TYPE_QUATERNION: return "Quaternion"
		TYPE_AABB: return "AABB"
		TYPE_BASIS: return "Basis"
		TYPE_TRANSFORM3D: return "Transform3D"
		TYPE_PACKED_BYTE_ARRAY: return "PackedByteArray"
		TYPE_PACKED_INT32_ARRAY: return "PackedInt32Array"
		TYPE_PACKED_INT64_ARRAY: return "PackedInt64Array"
		TYPE_PACKED_FLOAT32_ARRAY: return "PackedFloat32Array"
		TYPE_PACKED_FLOAT64_ARRAY: return "PackedFloat64Array"
		TYPE_PACKED_STRING_ARRAY: return "PackedStringArray"
		TYPE_PACKED_VECTOR2_ARRAY: return "PackedVector2Array"
		TYPE_PACKED_VECTOR3_ARRAY: return "PackedVector3Array"
		TYPE_PACKED_COLOR_ARRAY: return "PackedColorArray"
		_:
			return ""

func _number_from(text: String, fallback: float) -> float:
	return float(text) if not text.strip_edges().is_empty() else fallback
