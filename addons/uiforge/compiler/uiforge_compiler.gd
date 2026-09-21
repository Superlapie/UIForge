class_name UIForgeCompiler
extends RefCounted

var document: UIForgeDocument
var theme: UIForgeTheme
var source_path: String = ""
var subresource_lines: Array[String] = []
var ext_resources: Dictionary = {}
var style_ids: Dictionary = {}
var custom_components: Dictionary = {}

static func document_for_preview_state(input: UIForgeDocument, state: String) -> UIForgeDocument:
	var result := UIForgeDocument.from_dict(input.data, input.source_path)
	var normalized := state.to_lower()
	if normalized in ["", "normal"]:
		return result
	var active_state := "focused" if normalized == "focus" else normalized
	var theme := UIForgeTheme.from_document(result)
	_apply_preview_state(result.root(), active_state, theme)
	return result

static func _apply_preview_state(node: Dictionary, state: String, theme: UIForgeTheme) -> void:
	var states: Dictionary = node.get("states", {})
	var state_override: Dictionary = states.get(state, {})
	if state_override.is_empty() and state == "focused":
		state_override = states.get("focus", {})
	if state_override.is_empty() and state != "normal":
		var semantic_type := str(node.get("type", "Control"))
		var themed_style := theme.style(str(node.get("style", UIForgeComponentLibrary.style_name(semantic_type))))
		var texture_key := "%s_texture" % state
		if themed_style.has(texture_key):
			state_override["texture"] = themed_style[texture_key]
		if themed_style.has("%s_modulate" % state):
			state_override["normal_modulate"] = themed_style["%s_modulate" % state]
		var background_key := "%s_background" % state
		var border_key := "%s_border" % state
		if themed_style.has(background_key):
			state_override["background"] = themed_style[background_key]
		if themed_style.has(border_key):
			state_override["border"] = themed_style[border_key]
	if not state_override.is_empty():
		var base_style: Dictionary = theme.style(UIForgeComponentLibrary.style_name(str(node.get("type", "Control"))))
		var source_style: Variant = node.get("style", {})
		if source_style is String:
			base_style = theme.style(str(source_style))
		elif source_style is Dictionary:
			base_style.merge(source_style, true)
		base_style.merge(state_override, true)
		node["style"] = base_style
	if state == "disabled":
		var properties: Dictionary = node.get("properties", {})
		properties["disabled"] = true
		node["properties"] = properties
	for child in node.get("children", []):
		if child is Dictionary:
			_apply_preview_state(child, state, theme)

static func decoration_children(node: Dictionary) -> Array:
	var result: Array = []
	var raw: Variant = node.get("decorations", {})
	if raw is Dictionary:
		var names: Array[String] = []
		for name in raw:
			names.append(str(name))
		names.sort()
		for name in names:
			if raw[name] is Dictionary:
				result.append(_decoration_node(name, raw[name], str(node.get("id", "node"))))
	elif raw is Array:
		for index in raw.size():
			if raw[index] is Dictionary:
				result.append(_decoration_node(str(raw[index].get("id", "decoration_%02d" % (index + 1))), raw[index], str(node.get("id", "node"))))
	return result

static func _decoration_node(name: String, source: Dictionary, parent_id: String) -> Dictionary:
	var result := source.duplicate(true)
	result["id"] = str(result.get("id", "%s_%s" % [parent_id, name.to_snake_case()]))
	result["type"] = str(result.get("type", "Texture"))
	if not result.has("layout"):
		result["layout"] = {"position": result.get("position", [0, 0]), "size": result.get("size", [64, 64])}
	if not result.has("properties"):
		var properties: Dictionary = {}
		if result.has("texture"):
			properties["texture"] = result.get("texture")
		result["properties"] = properties
	return result

func compile_file(input_path: String, output_path: String = "") -> Dictionary:
	var loaded := UIForgeSerializer.load_document(input_path)
	if loaded.get("document") == null:
		return {"success": false, "errors": loaded.get("errors", [])}
	var target := output_path
	if target.is_empty():
		target = "%s.tscn" % input_path.trim_suffix(".ui.json")
	return compile_document(loaded["document"], target, input_path)

func compile_document(input: UIForgeDocument, output_path: String, original_source: String = "") -> Dictionary:
	document = input
	source_path = original_source if not original_source.is_empty() else input.source_path
	theme = UIForgeTheme.from_document(input)
	custom_components = input.data.get("components", {})
	subresource_lines = []
	ext_resources = {}
	style_ids = {}
	var validation := UIForgeValidator.new().validate(input, theme)
	var errors: Array = []
	for diagnostic in validation.get("diagnostics", []):
		if diagnostic.get("severity") == "error":
			errors.append(diagnostic)
	if not errors.is_empty():
		return {"success": false, "errors": errors, "warnings": validation.get("warnings", 0), "diagnostics": validation.get("diagnostics", [])}
	var root_node := _materialize_node(input.root())
	var node_lines: Array[String] = []
	_emit_node(root_node, ".", node_lines, true)
	var lines: Array[String] = []
	lines.append("; %s" % UIForgeTypes.GENERATED_MARKER)
	lines.append("; Source: %s" % source_path)
	lines.append("[gd_scene load_steps=%d format=3]" % (1 + subresource_lines.size() + ext_resources.size()))
	lines.append("")
	for resource in ext_resources.values():
		lines.append(str(resource.get("line", "")))
	if not ext_resources.is_empty():
		lines.append("")
	for subresource_line in subresource_lines:
		lines.append(subresource_line)
		lines.append("")
	lines.append_array(node_lines)
	var file := FileAccess.open(output_path, FileAccess.WRITE)
	if file == null:
		return {"success": false, "errors": [{"code": "OUTPUT_OPEN_FAILED", "message": "Could not write %s" % output_path}]}
	file.store_string("\n".join(lines) + "\n")
	file.flush()
	file.close()
	return {
		"success": true,
		"generated_scene": output_path,
		"source": source_path,
		"warnings": validation.get("warnings", 0),
		"diagnostics": validation.get("diagnostics", [])
	}

func _materialize_node(node: Dictionary) -> Dictionary:
	var result := UIForgeComponentLibrary.materialize(node, custom_components)
	var type_name := str(result.get("type", "Control"))
	if type_name == "ComponentInstance":
		result["type"] = "Control"
	return result

func _emit_node(node: Dictionary, parent_path: String, lines: Array[String], is_root: bool = false) -> void:
	var resolved := _materialize_node(node)
	var node_id := str(resolved.get("id", "node"))
	var node_name := String(node_id).validate_node_name()
	if node_name.is_empty():
		node_name = "Node_%s" % abs(node_id.hash())
	var native_type := UIForgeComponentLibrary.native_type(str(resolved.get("type", "Control")))
	var node_path := "." if is_root else (node_name if parent_path == "." else "%s/%s" % [parent_path, node_name])
	if is_root:
		lines.append("[node name=%s type=%s]" % [_quote(node_name), _quote(native_type)])
	else:
		lines.append("[node name=%s type=%s parent=%s]" % [_quote(node_name), _quote(native_type), _quote(parent_path)])
	lines.append("metadata/aether_id = %s" % _quote(node_id))
	lines.append("metadata/aether_type = %s" % _quote(str(resolved.get("type", "Control"))))
	lines.append("metadata/aether_generated = true")
	if resolved.has("action"):
		lines.append("metadata/aether_action = %s" % _quote(str(resolved.get("action", ""))))
	if resolved.has("binding"):
		lines.append("metadata/aether_binding = %s" % _quote(str(resolved.get("binding", ""))))
	if resolved.has("transitions"):
		lines.append("metadata/aether_transitions = %s" % _quote(JSON.stringify(resolved.get("transitions", {}))))
	if resolved.has("effects"):
		lines.append("metadata/aether_effects = %s" % _quote(JSON.stringify(resolved.get("effects", {}))))
	if resolved.has("metadata") and resolved.metadata is Dictionary:
		for metadata_key in resolved.metadata:
			lines.append("metadata/%s = %s" % [str(metadata_key), _variant_literal(resolved.metadata[metadata_key])])
	_emit_layout(resolved.get("layout", {}), lines)
	_emit_properties(resolved, native_type, node_id, lines)
	_emit_styles(resolved, native_type, node_id, lines)
	if not is_root:
		lines.append("")
	var children := _children_for(resolved)
	for child in children:
		if child is Dictionary:
			_emit_node(child, node_path, lines)

func _children_for(node: Dictionary) -> Array:
	var children: Array = []
	for child in node.get("children", []):
		if child is Dictionary:
			children.append(child)
	var node_id := str(node.get("id", "node"))
	var node_type := str(node.get("type", "Control"))
	var properties: Dictionary = node.get("properties", {})
	if node_type == "ItemGrid" and children.is_empty():
		var mock: Dictionary = node.get("mock_data", {})
		var count := int(mock.get("item_count", properties.get("mock_item_count", 0)))
		var occupied := int(mock.get("occupied_slots", count))
		var columns := int(properties.get("columns", 8))
		var total := max(count, int(properties.get("slot_count", occupied)))
		if total > 0:
			var mock_items: Array = mock.get("items", [])
			var stack_quantities: Array = mock.get("stack_quantities", [])
			var slot_size: float = _resolved_number(properties.get("slot_size", "$slot_size.md"), 54.0)
			for index in total:
				var slot_props: Dictionary = {}
				if index < occupied:
					var raw_item: Variant = mock_items[index] if index < mock_items.size() else "Item %02d" % (index + 1)
					var item_data: Dictionary = raw_item if raw_item is Dictionary else {}
					slot_props["label"] = str(item_data.get("name", raw_item))
					slot_props["count"] = int(item_data.get("count", stack_quantities[index] if index < stack_quantities.size() else index + 1))
					slot_props["icon"] = str(item_data.get("icon", _default_item_icon(index)))
					var rarity := str(item_data.get("rarity", "common"))
					if not rarity.is_empty():
						slot_props["rarity"] = rarity
				var slot_node: Dictionary = {"id": "%s_slot_%02d" % [node_id, index + 1], "type": "ItemSlot", "layout": {"min_size": [slot_size, slot_size]}, "properties": slot_props}
				if slot_props.has("rarity"):
					slot_node["style"] = {"border": "$rarity.%s" % str(slot_props["rarity"])}
				children.append(slot_node)
				if columns > 0 and index + 1 >= total:
					break
	children.append_array(decoration_children(node))
	if node_type in ["ItemSlot", "EquipmentSlot"] and children.is_empty():
		var label_text := str(properties.get("label", properties.get("text", "")))
		var count_text := str(properties.get("count", ""))
		var icon_path := str(properties.get("icon", properties.get("texture", "")))
		var slot_size := float(node.get("layout", {}).get("min_size", [58, 58])[0]) if node.get("layout", {}).get("min_size", [58, 58]) is Array else 58.0
		if not icon_path.is_empty() and icon_path.begins_with("res://"):
			children.append({"id": "%s_icon" % node_id, "type": "Texture", "layout": {"position": [8, 6], "size": [max(slot_size - 16.0, 16.0), max(slot_size - 24.0, 16.0)]}, "properties": {"texture": icon_path, "ignore_texture_size": true, "stretch_mode": 5}})
		if not label_text.is_empty() and icon_path.is_empty():
			var display_label := label_text if label_text.length() <= 8 else "%s…" % label_text.substr(0, 7)
			children.append({"id": "%s_icon_label" % node_id, "type": "Label", "layout": {"position": [5, 5], "size": [max(slot_size - 10.0, 24.0), max(slot_size - 24.0, 18.0)]}, "properties": {"text": display_label, "font_size": "$font_size.caption", "color": "$colors.text_secondary", "horizontal_alignment": "center", "vertical_alignment": "center", "clip_text": true, "text_overrun_behavior": 1}})
		elif not label_text.is_empty() and bool(properties.get("show_label", false)):
			var short_label := label_text if label_text.length() <= 9 else "%s…" % label_text.substr(0, 8)
			children.append({"id": "%s_label" % node_id, "type": "Label", "layout": {"position": [4, max(slot_size - 19.0, 18.0)], "size": [max(slot_size - 8.0, 24.0), 15]}, "properties": {"text": short_label, "font_size": "$font_size.micro", "color": "$colors.text_secondary", "horizontal_alignment": "center", "clip_text": true, "text_overrun_behavior": 1}})
		if not count_text.is_empty():
			children.append({"id": "%s_count" % node_id, "type": "Label", "layout": {"position": [max(slot_size - 28.0, 18.0), max(slot_size - 20.0, 18.0)], "size": [24, 16]}, "properties": {"text": count_text, "font_size": "$font_size.micro", "color": "$colors.gold_bright", "horizontal_alignment": "right"}})
	# Surface detail is a non-interactive native child, below all authored content.
	# Restrict to Panel: a container would otherwise lay the decoration out as content.
	if UIForgeComponentLibrary.native_type(node_type) == "Panel":
		var visual := theme.style(str(node.get("style", UIForgeComponentLibrary.style_name(node_type))))
		if node.get("style") is Dictionary:
			visual = theme.style(UIForgeComponentLibrary.style_name(node_type))
			visual.merge(theme.resolve_recursive(node.style), true)
			if node.style.has("background") and not node.style.has("surface_texture"):
				visual.erase("surface_texture")
		var surface := str(visual.get("surface_texture", ""))
		if not surface.is_empty():
			var inset := float(visual.get("surface_inset", 10))
			children.push_front({
				"id": "%s__surface" % node_id, "type": "Texture",
				"layout": {"anchors_preset": "full_rect", "offsets": {"left": inset, "top": inset, "right": -inset, "bottom": -inset}, "mouse_filter": 2},
				"properties": {"texture": surface, "expand_mode": 1, "stretch_mode": 6, "modulate": visual.get("surface_tint", "#ffffff80")},
				"metadata": {"aether_decoration": true}
			})
	return children

func _default_item_icon(index: int) -> String:
	var icons := ["sword", "shield", "potion", "herb", "gem", "scroll", "ring", "helm", "cloak", "ore", "coin"]
	return "res://examples/assets/ui/icons/%s.svg" % icons[index % icons.size()]

func _emit_layout(layout_value: Variant, lines: Array[String]) -> void:
	if not layout_value is Dictionary:
		return
	var layout: Dictionary = layout_value
	var position: Array = layout.get("position", [])
	var size: Array = layout.get("size", [])
	if position.size() >= 2:
		lines.append("offset_left = %s" % _number(position[0]))
		lines.append("offset_top = %s" % _number(position[1]))
		if size.size() < 2:
			lines.append("offset_right = %s" % _number(position[0]))
			lines.append("offset_bottom = %s" % _number(position[1]))
	if size.size() >= 2:
		var left := float(position[0]) if position.size() >= 2 else 0.0
		var top := float(position[1]) if position.size() >= 2 else 0.0
		lines.append("offset_right = %s" % _number(left + float(size[0])))
		lines.append("offset_bottom = %s" % _number(top + float(size[1])))
	var anchors: Dictionary = layout.get("anchors", {})
	for key in ["left", "top", "right", "bottom"]:
		if anchors.has(key):
			lines.append("anchor_%s = %s" % [key, _number(anchors[key])])
	var offsets: Dictionary = layout.get("offsets", {})
	for key in ["left", "top", "right", "bottom"]:
		if offsets.has(key):
			lines.append("offset_%s = %s" % [key, _number(offsets[key])])
	if layout.get("anchors_preset", "") == "full_rect":
		lines.append("anchors_preset = 15")
		lines.append("anchor_right = 1.0")
		lines.append("anchor_bottom = 1.0")
		lines.append("grow_horizontal = 2")
		lines.append("grow_vertical = 2")
	if layout.has("min_size") and layout.min_size is Array and layout.min_size.size() >= 2:
		lines.append("custom_minimum_size = Vector2(%s, %s)" % [_number(layout.min_size[0]), _number(layout.min_size[1])])
	if layout.has("max_size") and layout.max_size is Array and layout.max_size.size() >= 2:
		lines.append("custom_maximum_size = Vector2(%s, %s)" % [_number(layout.max_size[0]), _number(layout.max_size[1])])
	if layout.has("grow_horizontal"):
		lines.append("grow_horizontal = %d" % int(layout.grow_horizontal))
	if layout.has("grow_vertical"):
		lines.append("grow_vertical = %d" % int(layout.grow_vertical))
	if layout.has("size_flags_horizontal"):
		lines.append("size_flags_horizontal = %d" % int(layout.size_flags_horizontal))
	if layout.has("size_flags_vertical"):
		lines.append("size_flags_vertical = %d" % int(layout.size_flags_vertical))
	if layout.has("size_flags_stretch_ratio"):
		lines.append("size_flags_stretch_ratio = %s" % _number(layout.size_flags_stretch_ratio))
	if layout.has("pivot") and layout.pivot is Array and layout.pivot.size() >= 2:
		lines.append("pivot_offset = Vector2(%s, %s)" % [_number(layout.pivot[0]), _number(layout.pivot[1])])
	if layout.has("rotation_degrees"):
		lines.append("rotation = %s" % _number(float(layout.rotation_degrees) * PI / 180.0))
	if layout.has("scale") and layout.scale is Array and layout.scale.size() >= 2:
		lines.append("scale = Vector2(%s, %s)" % [_number(layout.scale[0]), _number(layout.scale[1])])
	if layout.has("z_index"):
		lines.append("z_index = %d" % int(layout.z_index))
	if layout.has("mouse_filter"):
		lines.append("mouse_filter = %d" % int(layout.mouse_filter))

func _emit_properties(node: Dictionary, native_type: String, node_id: String, lines: Array[String]) -> void:
	var properties: Dictionary = node.get("properties", {})
	var title := str(properties.get("title", ""))
	var text := str(properties.get("text", title))
	if not text.is_empty() and native_type in ["Label", "RichTextLabel", "Button", "CheckBox", "CheckButton", "MenuButton", "LinkButton", "LineEdit", "TextEdit"]:
		lines.append("text = %s" % _quote(text))
	if properties.has("placeholder") and native_type == "LineEdit":
		lines.append("placeholder_text = %s" % _quote(properties.placeholder))
	for key in ["visible", "clip_contents"]:
		if properties.has(key):
			lines.append("%s = %s" % [key, str(bool(properties[key])).to_lower()])
	for key in ["show_behind_parent", "top_level", "z_as_relative", "y_sort_enabled", "use_parent_material", "auto_translate"]:
		if properties.has(key):
			lines.append("%s = %s" % [key, str(bool(properties[key])).to_lower()])
	for key in ["clip_children", "light_mask", "visibility_layer", "texture_filter", "texture_repeat", "layout_direction", "mouse_default_cursor_shape"]:
		if properties.has(key):
			lines.append("%s = %d" % [key, int(properties[key])])
	if properties.has("tooltip"):
		lines.append("tooltip_text = %s" % _quote(str(properties.tooltip)))
	if properties.has("focus_mode"):
		lines.append("focus_mode = %d" % int(properties.focus_mode))
	for key in ["value", "min_value", "max_value", "step"]:
		if properties.has(key):
			var godot_key: String = "value" if key == "value" else key
			lines.append("%s = %s" % [godot_key, _number(properties[key])])
	if properties.has("columns") and native_type == "GridContainer":
		lines.append("columns = %d" % int(properties.columns))
	if properties.has("editable"):
		lines.append("editable = %s" % str(bool(properties.editable)).to_lower())
	if properties.has("disabled") and native_type in ["Button", "TextureButton", "CheckBox", "LinkButton"]:
		lines.append("disabled = %s" % str(bool(properties.disabled)).to_lower())
	if properties.has("autowrap"):
		lines.append("autowrap_mode = %d" % (3 if bool(properties.autowrap) else 0))
	if properties.has("alignment"):
		lines.append("horizontal_alignment = %d" % _alignment(properties.alignment))
	if properties.has("horizontal_alignment"):
		lines.append("horizontal_alignment = %d" % _alignment(properties.horizontal_alignment))
	if properties.has("vertical_alignment"):
		lines.append("vertical_alignment = %d" % _vertical_alignment(properties.vertical_alignment))
	if properties.has("show_percentage"):
		lines.append("show_percentage = %s" % str(bool(properties.show_percentage)).to_lower())
	for key in ["bbcode_enabled", "fit_content", "scroll_active", "toggle_mode", "button_pressed", "secret", "clear_button_enabled", "caret_blink", "selecting_enabled", "ticks_on_borders", "allow_greater", "allow_lesser", "ignore_texture_size", "flip_h", "flip_v"]:
		if properties.has(key):
			lines.append("%s = %s" % [key, str(bool(properties[key])).to_lower()])
	for key in ["max_length", "tick_count"]:
		if properties.has(key):
			lines.append("%s = %d" % [key, int(properties[key])])
	for key in ["horizontal_scroll_mode", "vertical_scroll_mode"]:
		if properties.has(key) and native_type == "ScrollContainer":
			lines.append("%s = %d" % [key, int(properties[key])])
	if properties.has("alignment"):
		lines.append("alignment = %d" % _alignment(properties.alignment))
	for key in ["clip_text", "flat", "expand_icon", "icon_alignment", "text_overrun_behavior"]:
		if properties.has(key) and native_type in ["Button", "CheckBox", "TextureButton", "LinkButton", "Label", "RichTextLabel"]:
			lines.append("%s = %d" % [key, _alignment(properties[key]) if key == "icon_alignment" else int(properties[key])])
	if properties.has("theme_type_variation") and not str(properties.theme_type_variation).is_empty():
		lines.append("theme_type_variation = %s" % _quote(str(properties.theme_type_variation)))
	for key in ["accessibility_name", "accessibility_description"]:
		if properties.has(key) and not str(properties[key]).is_empty():
			lines.append("%s = %s" % [key, _quote(str(properties[key]))])
	for direction in ["top", "bottom", "left", "right"]:
		var neighbor_key := "focus_neighbor_%s" % direction
		if properties.has(neighbor_key) and not str(properties[neighbor_key]).is_empty():
			lines.append("%s = NodePath(%s)" % [neighbor_key, _quote(str(properties[neighbor_key]))])
	if properties.has("separation") and native_type in ["HBoxContainer", "VBoxContainer", "GridContainer"]:
		lines.append("theme_override_constants/separation = %d" % int(properties.separation))
	if properties.has("gap") and native_type == "GridContainer":
		var gap: int = int(_resolved_number(properties.gap, 0.0))
		lines.append("theme_override_constants/h_separation = %d" % gap)
		lines.append("theme_override_constants/v_separation = %d" % gap)
	if properties.has("modulate"):
		lines.append("modulate = %s" % _color_literal(properties.modulate, Color.WHITE))
	elif properties.has("opacity"):
		lines.append("modulate = %s" % _color_literal([1.0, 1.0, 1.0, float(properties.opacity)], Color.WHITE))
	if properties.has("self_modulate"):
		lines.append("self_modulate = %s" % _color_literal(properties.self_modulate, Color.WHITE))
	if properties.has("material") and str(properties.material).begins_with("res://"):
		var material_id := _add_external_resource(str(properties.material), "Material")
		lines.append("material = ExtResource(\"%s\")" % material_id)
	if properties.has("theme") and str(properties.theme).begins_with("res://"):
		var theme_id := _add_external_resource(str(properties.theme), "Theme")
		lines.append("theme = ExtResource(\"%s\")" % theme_id)
	if properties.has("icon") and native_type in ["Button", "CheckBox", "TextureButton", "LinkButton"] and str(properties.icon).begins_with("res://"):
		var resource_id := _add_external_resource(str(properties.icon), "Texture2D")
		lines.append("icon = ExtResource(\"%s\")" % resource_id)
	if properties.has("texture") and native_type in ["TextureRect", "TextureButton", "NinePatchRect"] and str(properties.texture).begins_with("res://"):
		var texture_id := _add_external_resource(str(properties.texture), "Texture2D")
		var texture_value := "ExtResource(\"%s\")" % texture_id
		if properties.has("texture_region"):
			var region: Array = properties.texture_region
			var atlas_id := "AtlasTexture_%s" % _safe_id(node_id)
			subresource_lines.append("[sub_resource type=\"AtlasTexture\" id=\"%s\"]" % atlas_id)
			subresource_lines.append("atlas = %s" % texture_value)
			subresource_lines.append("region = Rect2(%s, %s, %s, %s)" % [_number(region[0]), _number(region[1]), _number(region[2]), _number(region[3])])
			subresource_lines.append("filter_clip = true\n")
			texture_value = "SubResource(\"%s\")" % atlas_id
		lines.append("%s = %s" % ["texture_normal" if native_type == "TextureButton" else "texture", texture_value])
	if properties.has("expand_mode") and native_type == "TextureRect":
		lines.append("expand_mode = %d" % int(properties.expand_mode))
	if properties.has("stretch_mode") and native_type == "TextureRect":
		lines.append("stretch_mode = %d" % int(properties.stretch_mode))
	if properties.has("ignore_texture_size") and native_type == "TextureRect":
		lines.append("ignore_texture_size = %s" % str(bool(properties.ignore_texture_size)).to_lower())
	if native_type == "NinePatchRect":
		for side in ["left", "top", "right", "bottom"]:
			var margin_key := "patch_margin_%s" % side
			if properties.has(margin_key):
				lines.append("%s = %d" % [margin_key, int(properties[margin_key])])
	var font_role := "heading" if str(properties.get("font_size", "")) in ["$font_size.title", "$font_size.heading"] else "default"
	var font_path := str(theme.resolve(properties.get("font", theme.data.get("fonts", {}).get(font_role, "")), ""))
	if native_type in ["Label", "RichTextLabel", "Button", "CheckBox", "CheckButton", "MenuButton", "LinkButton", "LineEdit", "TextEdit"] and font_path.begins_with("res://"):
		var font_id := _add_external_resource(font_path, "FontFile")
		var font_theme_key := "normal_font" if native_type == "RichTextLabel" else "font"
		lines.append("theme_override_fonts/%s = ExtResource(\"%s\")" % [font_theme_key, font_id])
	for font_property in ["font_size", "outline_size"]:
		if properties.has(font_property):
			var resolved_font_size: Variant = theme.resolve(properties[font_property], properties[font_property])
			var font_size_theme_key: String = "normal_font_size" if native_type == "RichTextLabel" and font_property == "font_size" else font_property
			lines.append("theme_override_font_sizes/%s = %d" % [font_size_theme_key, int(resolved_font_size)])
	for color_property in ["color", "font_color", "font_outline_color", "font_shadow_color"]:
		if properties.has(color_property):
			var color_value: Variant = theme.resolve(properties[color_property], properties[color_property])
			if native_type == "ColorRect" and color_property == "color":
				lines.append("color = %s" % _color_literal(color_value, Color.WHITE))
				continue
			var theme_color_name: String = "font_color" if color_property == "color" and native_type in ["Label", "Button", "CheckBox", "CheckButton", "LineEdit"] else color_property
			if native_type == "RichTextLabel" and color_property in ["color", "font_color"]:
				theme_color_name = "default_color"
			lines.append("theme_override_colors/%s = %s" % [theme_color_name, _color_literal(color_value, Color.WHITE)])
	_emit_godot_overrides(properties, lines)

func _emit_godot_overrides(properties: Dictionary, lines: Array[String]) -> void:
	var overrides: Variant = properties.get("godot_overrides", {})
	if not overrides is Dictionary:
		return
	# The typed catalog owns these common properties. Raw overrides are for
	# specialized or newly-added Godot properties and theme override paths.
	var typed_properties := {
		"text": true, "placeholder_text": true, "visible": true, "clip_contents": true,
		"show_behind_parent": true, "top_level": true, "z_as_relative": true,
		"y_sort_enabled": true, "use_parent_material": true, "clip_children": true,
		"light_mask": true, "visibility_layer": true, "texture_filter": true,
		"texture_repeat": true, "layout_direction": true, "mouse_default_cursor_shape": true,
		"tooltip_text": true, "focus_mode": true, "value": true, "min_value": true,
		"max_value": true, "step": true, "columns": true, "editable": true,
		"disabled": true, "autowrap_mode": true, "horizontal_alignment": true,
		"vertical_alignment": true, "show_percentage": true, "bbcode_enabled": true,
		"fit_content": true, "scroll_active": true, "toggle_mode": true,
		"button_pressed": true, "secret": true, "clear_button_enabled": true,
		"caret_blink": true, "selecting_enabled": true, "ticks_on_borders": true,
		"allow_greater": true, "allow_lesser": true, "ignore_texture_size": true,
		"flip_h": true, "flip_v": true, "max_length": true, "tick_count": true,
		"horizontal_scroll_mode": true, "vertical_scroll_mode": true, "alignment": true,
		"clip_text": true, "flat": true, "expand_icon": true, "icon_alignment": true,
		"text_overrun_behavior": true, "theme_type_variation": true,
		"accessibility_name": true, "accessibility_description": true, "auto_translate": true,
		"separation": true, "modulate": true, "self_modulate": true, "material": true,
		"theme": true, "icon": true, "texture": true, "expand_mode": true,
		"stretch_mode": true, "patch_margin_left": true, "patch_margin_top": true,
		"patch_margin_right": true, "patch_margin_bottom": true, "font": true,
		"font_size": true, "outline_size": true, "color": true, "font_color": true,
		"font_outline_color": true, "font_shadow_color": true
	}
	for property_name in overrides:
		var name := str(property_name)
		if name.is_empty() or typed_properties.has(name) or name.contains("\n") or name.contains("\r"):
			continue
		var literal := _godot_override_literal(name, overrides[property_name])
		if not literal.is_empty():
			lines.append("%s = %s" % [name, literal])

func _godot_override_literal(property_name: String, value: Variant) -> String:
	if value is Dictionary:
		var tagged_type := str(value.get("$type", ""))
		if not tagged_type.is_empty():
			return _typed_godot_literal(tagged_type, value.get("value", value.get("values", [])), property_name)
		var resource_path := str(value.get("$resource", value.get("resource", "")))
		if not resource_path.is_empty() and resource_path.begins_with("res://"):
			var resource_type := str(value.get("type", _resource_type_for_property(property_name)))
			var resource_id := _add_external_resource(resource_path, resource_type)
			return "ExtResource(\"%s\")" % resource_id
		var node_path := str(value.get("$node_path", ""))
		if not node_path.is_empty():
			return "NodePath(%s)" % _quote(node_path)
		var entries: Array[String] = []
		for key in value:
			entries.append("%s: %s" % [_quote(str(key)), _godot_override_literal(property_name, value[key])])
		return "{%s}" % ", ".join(entries)
	if value is String:
		var string_value := str(value)
		if string_value.begins_with("res://") and _looks_like_resource_property(property_name):
			var inferred_id := _add_external_resource(string_value, _resource_type_for_property(property_name))
			return "ExtResource(\"%s\")" % inferred_id
		if property_name.to_lower().contains("color"):
			return _color_literal(string_value, Color.WHITE)
		return _quote(string_value)
	if value is Array:
		return _array_literal(value, property_name)
	return _variant_literal(value)

func _typed_godot_literal(type_name: String, payload: Variant, property_name: String) -> String:
	var values: Array = payload if payload is Array else []
	match type_name:
		"Color":
			return _color_literal(payload, Color.WHITE)
		"Vector2", "Vector2i":
			if values.size() >= 2:
				return "%s(%s, %s)" % [type_name, _number(values[0]), _number(values[1])]
		"Vector3", "Vector3i":
			if values.size() >= 3:
				return "%s(%s, %s, %s)" % [type_name, _number(values[0]), _number(values[1]), _number(values[2])]
		"Vector4", "Vector4i":
			if values.size() >= 4:
				return "%s(%s, %s, %s, %s)" % [type_name, _number(values[0]), _number(values[1]), _number(values[2]), _number(values[3])]
		"Rect2", "Rect2i":
			if values.size() >= 4:
				return "%s(Vector2(%s, %s), Vector2(%s, %s))" % [type_name, _number(values[0]), _number(values[1]), _number(values[2]), _number(values[3])]
		"Transform2D":
			if values.size() >= 6:
				return "Transform2D(Vector2(%s, %s), Vector2(%s, %s), Vector2(%s, %s))" % [_number(values[0]), _number(values[1]), _number(values[2]), _number(values[3]), _number(values[4]), _number(values[5])]
		"Plane":
			if values.size() >= 4:
				return "Plane(Vector3(%s, %s, %s), %s)" % [_number(values[0]), _number(values[1]), _number(values[2]), _number(values[3])]
		"Quaternion":
			if values.size() >= 4:
				return "Quaternion(%s, %s, %s, %s)" % [_number(values[0]), _number(values[1]), _number(values[2]), _number(values[3])]
		"AABB":
			if values.size() >= 6:
				return "AABB(Vector3(%s, %s, %s), Vector3(%s, %s, %s))" % [_number(values[0]), _number(values[1]), _number(values[2]), _number(values[3]), _number(values[4]), _number(values[5])]
		"Basis":
			if values.size() >= 9:
				return "Basis(Vector3(%s, %s, %s), Vector3(%s, %s, %s), Vector3(%s, %s, %s))" % [_number(values[0]), _number(values[1]), _number(values[2]), _number(values[3]), _number(values[4]), _number(values[5]), _number(values[6]), _number(values[7]), _number(values[8])]
		"Transform3D":
			if values.size() >= 12:
				var basis_values := values.slice(0, 9)
				return "Transform3D(%s, Vector3(%s, %s, %s))" % [_typed_godot_literal("Basis", basis_values, property_name), _number(values[9]), _number(values[10]), _number(values[11])]
		"Array[NodePath]":
			var node_paths: Array[String] = []
			for entry in values:
				var path := str(entry.get("$node_path", "")) if entry is Dictionary else str(entry)
				node_paths.append("NodePath(%s)" % _quote(path))
			return "[%s]" % ", ".join(node_paths)
		"PackedByteArray", "PackedInt32Array", "PackedInt64Array", "PackedFloat32Array", "PackedFloat64Array", "PackedStringArray", "PackedVector2Array", "PackedVector3Array", "PackedColorArray":
			return "%s(%s)" % [type_name, _array_literal(values, property_name)]
	return _array_literal(values, property_name) if payload is Array else _variant_literal(payload)

func _array_literal(values: Array, property_name: String) -> String:
	var entries: Array[String] = []
	for entry in values:
		entries.append(_godot_override_literal(property_name, entry))
	return "[%s]" % ", ".join(entries)

func _looks_like_resource_property(property_name: String) -> bool:
	var lowered := property_name.to_lower()
	return lowered.contains("texture") or lowered.contains("icon") or lowered.contains("font") or lowered.contains("material") or lowered.contains("theme") or lowered.contains("shader") or lowered.contains("label_settings") or lowered.contains("syntax_highlighter") or lowered.contains("script") or lowered.contains("shortcut") or lowered.contains("button_group")

func _resource_type_for_property(property_name: String) -> String:
	var lowered := property_name.to_lower()
	if lowered.contains("font"):
		return "FontFile"
	if lowered.contains("material") or lowered.contains("shader"):
		return "Material"
	if lowered.contains("theme"):
		return "Theme"
	if lowered.contains("label_settings"):
		return "LabelSettings"
	if lowered.contains("syntax_highlighter"):
		return "SyntaxHighlighter"
	if lowered.contains("script"):
		return "Script"
	if lowered.contains("shortcut"):
		return "Shortcut"
	if lowered.contains("button_group"):
		return "ButtonGroup"
	return "Texture2D"

func _emit_styles(node: Dictionary, native_type: String, node_id: String, lines: Array[String]) -> void:
	var native_skin: Dictionary = theme.data.get("native_controls", {}).get(native_type, {})
	for key in native_skin.get("styles", {}):
		var skin_style := _make_style(node_id, str(key), str(native_skin.styles[key]), {})
		lines.append("theme_override_styles/%s = SubResource(\"%s\")" % [key, skin_style])
	for key in native_skin.get("icons", {}):
		var skin_icon := _add_external_resource(str(native_skin.icons[key]), "Texture2D")
		lines.append("theme_override_icons/%s = ExtResource(\"%s\")" % [key, skin_icon])
	if native_type in ["HSeparator", "VSeparator"]:
		var separator_id := _make_style(node_id, "normal", "separator", {})
		lines.append("theme_override_styles/separator = SubResource(\"%s\")" % separator_id)
		return
	if native_type not in ["Panel", "PanelContainer", "Button", "TextureButton", "CheckBox", "CheckButton", "OptionButton", "MenuButton", "LinkButton", "LineEdit", "ProgressBar", "TabBar", "ScrollContainer"]:
		return
	var node_type := str(node.get("type", "Control"))
	var style_name := str(node.get("style", UIForgeComponentLibrary.style_name(node_type)))
	if node.get("style") is Dictionary:
		style_name = UIForgeComponentLibrary.style_name(node_type)
	var style_override: Dictionary = node.get("style", {}) if node.get("style") is Dictionary else {}
	var states: Dictionary = node.get("states", {})
	var style_property := "panel"
	if native_type == "LineEdit":
		style_property = "normal"
	if native_type in ["Button", "TextureButton", "CheckBox", "CheckButton", "OptionButton", "MenuButton", "LinkButton"]:
		style_property = "normal"
	if native_type == "ProgressBar":
		var background_style_name := str(node.get("background_style", style_name))
		var default_fill_style := str(UIForgeComponentLibrary.definitions().get(node_type, {}).get("fill_style", "button_primary"))
		var fill_style_name := str(node.get("fill_style", default_fill_style))
		var background_id := _make_style(node_id, "background", background_style_name, style_override)
		var fill_id := _make_style(node_id, "fill", fill_style_name, {})
		lines.append("theme_override_styles/background = SubResource(\"%s\")" % background_id)
		lines.append("theme_override_styles/fill = SubResource(\"%s\")" % fill_id)
		return
	var normal_id := _make_style(node_id, "normal", style_name, style_override)
	lines.append("theme_override_styles/%s = SubResource(\"%s\")" % [style_property, normal_id])
	var base_style := theme.style(style_name)
	for state in ["hover", "pressed", "focus", "disabled", "selected"]:
		var state_style: Dictionary = states.get(state, {})
		if state_style.is_empty() and state == "focus":
			state_style = states.get("focused", {})
		if state == "selected" and state_style.is_empty() and not base_style.has("selected_texture") and not base_style.has("selected_background") and not base_style.has("selected_border") and not base_style.has("selected_modulate"):
			continue
		if state_style.is_empty() and not base_style.has("%s_texture" % state) and state != "hover" and state != "pressed" and state != "disabled" and state != "selected":
			continue
		var merged_state := style_override.duplicate(true)
		merged_state.merge(state_style, true)
		var state_id := _make_style(node_id, state, style_name, merged_state)
		if native_type in ["Button", "TextureButton", "CheckBox", "CheckButton", "OptionButton", "MenuButton", "LinkButton"]:
			var output_state: String = "pressed" if state == "selected" else ("focus" if state == "focus" else state)
			lines.append("theme_override_styles/%s = SubResource(\"%s\")" % [output_state, state_id])
		elif native_type == "LineEdit" and state in ["hover", "focus", "disabled"]:
			lines.append("theme_override_styles/%s = SubResource(\"%s\")" % [state, state_id])

func _make_style(node_id: String, state: String, style_name: String, override: Dictionary) -> String:
	var cache_key := "%s|%s|%s|%s" % [node_id, state, style_name, JSON.stringify(override)]
	if style_ids.has(cache_key):
		return style_ids[cache_key]
	var style := theme.style(style_name)
	var resolved_override := theme.resolve_recursive(override)
	# A fully specified inline style is intentionally allowed to opt out of a
	# theme texture. This is important for art plates and character previews:
	# they can use a flat inset without inheriting a nine-slice border texture.
	if resolved_override is Dictionary and resolved_override.has("background") and not resolved_override.has("texture"):
		# An invisible hit target must not inherit an opaque panel shadow.
		if not resolved_override.has("shadow_color"):
			style.erase("shadow_color")
			style.erase("shadow_size")
		for texture_key in ["texture", "hover_texture", "pressed_texture", "disabled_texture", "selected_texture", "focus_texture", "texture_margin_left", "texture_margin_top", "texture_margin_right", "texture_margin_bottom", "axis_stretch_horizontal", "axis_stretch_vertical"]:
			style.erase(texture_key)
	style.merge(resolved_override, true)
	# State artwork shares slice geometry, preserving corners in every state.
	if style.has("%s_texture" % state):
		style["texture"] = style["%s_texture" % state]
	var state_background_key := "%s_background" % state
	if style.has(state_background_key):
		style["background"] = style[state_background_key]
	var state_border_key := "%s_border" % state
	if style.has(state_border_key):
		style["border"] = style[state_border_key]
	var id := "StyleBox_%s_%s" % [_safe_id(node_id), _safe_id(state)]
	style_ids[cache_key] = id
	if style.has("texture") and str(style.texture).begins_with("res://"):
		var texture_id := _add_external_resource(str(style.texture), "Texture2D")
		var texture_block := "[sub_resource type=\"StyleBoxTexture\" id=\"%s\"]\ntexture = ExtResource(\"%s\")" % [id, texture_id]
		for margin in ["left", "top", "right", "bottom"]:
			if style.has("texture_margin_%s" % margin):
				texture_block += "\ntexture_margin_%s = %s" % [margin, _number(style["texture_margin_%s" % margin])]
		for axis in ["horizontal", "vertical"]:
			var axis_key := "axis_stretch_%s" % axis
			if style.has(axis_key):
				texture_block += "\n%s = %d" % [axis_key, int(style[axis_key])]
		var modulate_key := "%s_modulate" % state
		if style.has(modulate_key):
			texture_block += "\nmodulate_color = %s" % _color_literal(style[modulate_key], Color.WHITE)
		var texture_content_margin: Variant = style.get("content_margin", {})
		if texture_content_margin is Dictionary:
			for margin in ["left", "top", "right", "bottom"]:
				if texture_content_margin.has(margin):
					texture_block += "\ncontent_margin_%s = %s" % [margin, _number(texture_content_margin[margin])]
		subresource_lines.append(texture_block)
		return id
	var background := _color_literal(style.get("background", "$colors.surface"), Color("151a22"))
	var border := _color_literal(style.get("border", "$colors.border"), Color("645039"))
	var border_width := int(style.get("border_width", 1))
	var radius := int(style.get("radius", 4))
	var block := "[sub_resource type=\"StyleBoxFlat\" id=\"%s\"]\n" % id
	block += "bg_color = %s\n" % background
	block += "border_width_left = %d\nborder_width_top = %d\nborder_width_right = %d\nborder_width_bottom = %d\n" % [border_width, border_width, border_width, border_width]
	block += "border_color = %s\n" % border
	block += "corner_radius_top_left = %d\ncorner_radius_top_right = %d\ncorner_radius_bottom_right = %d\ncorner_radius_bottom_left = %d\n" % [radius, radius, radius, radius]
	var content_margin: Variant = style.get("content_margin", {})
	if content_margin is Dictionary:
		for margin in ["left", "top", "right", "bottom"]:
			if content_margin.has(margin):
				block += "content_margin_%s = %s\n" % [margin, _number(content_margin[margin])]
	if style.has("shadow_color"):
		block += "shadow_color = %s\n" % _color_literal(style.shadow_color, Color.TRANSPARENT)
		block += "shadow_size = %d\n" % int(style.get("shadow_size", 0))
	subresource_lines.append(block.trim_suffix("\n"))
	return id

func _add_external_resource(path: String, type_name: String) -> String:
	if ext_resources.has(path):
		return str(ext_resources[path].get("id", ""))
	var id := "%s_%d" % [type_name, ext_resources.size() + 1]
	ext_resources[path] = {"id": id, "line": "[ext_resource type=\"%s\" path=\"%s\" id=\"%s\"]" % [type_name, path, id]}
	return id

func _native_type(type_name: String) -> String:
	return UIForgeComponentLibrary.native_type(type_name)

func _alignment(value: Variant) -> int:
	if value is int or value is float:
		return int(value)
	return {"left": 0, "center": 1, "right": 2, "fill": 3}.get(str(value).to_lower(), 0)

func _vertical_alignment(value: Variant) -> int:
	if value is int or value is float:
		return int(value)
	return {"top": 0, "center": 1, "bottom": 2, "fill": 3}.get(str(value).to_lower(), 0)

func _color_literal(value: Variant, fallback: Color) -> String:
	var resolved: Variant = theme.resolve(value, value)
	var color := fallback
	if resolved is Color:
		color = resolved
	elif resolved is String:
		color = Color.from_string(str(resolved), fallback)
	elif resolved is Array and resolved.size() >= 3:
		color = Color(float(resolved[0]), float(resolved[1]), float(resolved[2]), float(resolved[3]) if resolved.size() > 3 else 1.0)
	return "Color(%0.6f, %0.6f, %0.6f, %0.6f)" % [color.r, color.g, color.b, color.a]

func _variant_literal(value: Variant) -> String:
	if value is String:
		return _quote(str(value))
	if value is bool:
		return str(value).to_lower()
	if value is int or value is float:
		return _number(value)
	return _quote(JSON.stringify(value))

func _number(value: Variant) -> String:
	return "%0.4f" % float(value)

func _resolved_number(value: Variant, fallback: float) -> float:
	var resolved: Variant = theme.resolve(value, value) if theme != null else value
	return float(resolved) if resolved is int or resolved is float else fallback

func _quote(value: String) -> String:
	return JSON.stringify(value)

func _safe_id(value: String) -> String:
	var safe := value.to_snake_case().replace("-", "_")
	return safe if not safe.is_empty() else "node"
