@tool
class_name UIForgeCanvas
extends Control

signal node_selected(node_id: String)
signal node_changed(node_id: String)
signal delete_requested(node_id: String)
signal duplicate_requested(node_id: String)
signal asset_drop_requested(path: String, target_node_id: String, design_position: Vector2)
signal copy_requested(node_ids: Array[String])
signal paste_requested

var document: UIForgeDocument
var undo_redo: EditorUndoRedoManager
var zoom: float = 0.62
var pan: Vector2 = Vector2(48, 42)
var preview_state: String = "normal"
var viewport_preview: Vector2i = Vector2i(1920, 1080)
var selected_ids: Array[String] = []
var is_panning: bool = false
var is_dragging: bool = false
var is_resizing: bool = false
var drag_start_mouse: Vector2
var drag_start_position: Vector2
var drag_start_size: Vector2
var drag_start_positions: Dictionary = {}
var drag_start_document: Dictionary = {}
var reference_texture: Texture2D
var texture_cache: Dictionary = {}
var grid_enabled: bool = true
var snap_enabled: bool = true
var snap_size: int = 8
var native_viewport: SubViewport
var native_root: Control
var native_controls: Dictionary = {}
var native_signature: String = ""
var native_refresh_time: float = 0.0
var native_preview_valid: bool = false

func _process(delta: float) -> void:
	native_refresh_time += delta
	if native_refresh_time < 0.25 or document == null or not is_visible_in_tree():
		return
	native_refresh_time = 0.0
	refresh_native_preview()

func refresh_native_preview() -> void:
	if document == null:
		return
	var signature := JSON.stringify(document.data) + preview_state
	if signature == native_signature:
		return
	native_signature = signature
	native_preview_valid = false
	native_controls.clear()
	var preview := UIForgeCompiler.document_for_preview_state(document, preview_state)
	var path := "user://uiforge_canvas_%s_%s.tscn" % [OS.get_process_id(), get_instance_id()]
	var compiled := UIForgeCompiler.new().compile_document(preview, path, document.source_path, {"allow_outside_project": true, "force": true})
	if not compiled.get("success", false):
		queue_redraw()
		return
	var packed := ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	if packed == null:
		return
	if native_viewport == null:
		native_viewport = SubViewport.new()
		native_viewport.transparent_bg = true
		native_viewport.disable_3d = true
		native_viewport.gui_disable_input = true
		native_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		add_child(native_viewport)
	native_viewport.size = document.viewport_size()
	if is_instance_valid(native_root):
		native_root.free()
	native_root = packed.instantiate() as Control
	native_viewport.add_child(native_root)
	_index_native_controls(native_root)
	native_preview_valid = true
	queue_redraw()

func _index_native_controls(node: Node) -> void:
	if node is Control:
		native_controls[str(node.get_meta("uiforge_id", node.get_meta("aether_id", node.name)))] = node
	for child in node.get_children():
		_index_native_controls(child)

func _exit_tree() -> void:
	var path := "user://uiforge_canvas_%s_%s.tscn" % [OS.get_process_id(), get_instance_id()]
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)

func _ready() -> void:
	mouse_default_cursor_shape = Control.CURSOR_ARROW
	focus_mode = Control.FOCUS_ALL
	queue_redraw()

func set_editor_undo_redo(value: EditorUndoRedoManager) -> void:
	undo_redo = value

func set_document(value: UIForgeDocument) -> void:
	document = value
	native_signature = ""
	native_preview_valid = false
	native_controls.clear()
	selected_ids.clear()
	refresh_reference()

func refresh_reference() -> void:
	_load_reference()
	queue_redraw()

func set_preview_state(value: String) -> void:
	preview_state = value.to_lower()
	queue_redraw()

func set_viewport_preview(value: Vector2i) -> void:
	viewport_preview = value
	if size.x > 0.0 and size.y > 0.0:
		zoom_to_fit()
	queue_redraw()

func select_node(node_id: String, additive: bool = false) -> void:
	if not additive:
		selected_ids.clear()
	if node_id.is_empty():
		queue_redraw()
		return
	if node_id in selected_ids:
		if additive:
			selected_ids.erase(node_id)
	else:
		selected_ids.append(node_id)
	node_selected.emit(node_id)
	queue_redraw()

func focus_selection() -> void:
	if document == null or selected_ids.is_empty():
		return
	var node := document.find_node(selected_ids[0])
	if node.is_empty():
		return
	var layout: Dictionary = node.get("layout", {})
	var size: Array = layout.get("size", [300, 200])
	var position: Array = layout.get("position", [0, 0])
	if size.size() >= 2 and position.size() >= 2:
		pan = size_to_fit(Vector2(float(size[0]), float(size[1])), Vector2(float(position[0]), float(position[1])))
		queue_redraw()

func zoom_to_fit() -> void:
	if document == null:
		return
	var target_size := Vector2(viewport_preview)
	var available := size - Vector2(80, 80)
	zoom = clamp(min(available.x / target_size.x, available.y / target_size.y), 0.1, 1.5)
	pan = (size - target_size * zoom) * 0.5
	queue_redraw()

func size_to_fit(selection_size: Vector2, selection_position: Vector2) -> Vector2:
	var center := size * 0.5
	return center - (selection_position + selection_size * 0.5) * _display_zoom()

func _display_scale() -> float:
	if document == null:
		return 1.0
	var viewport: Dictionary = document.data.get("viewport", {})
	var mode := str(viewport.get("scale_mode", "fit"))
	if mode == "fixed":
		return 1.0
	var design_size := Vector2(document.viewport_size())
	if design_size.x <= 0.0 or design_size.y <= 0.0:
		return 1.0
	var result := min(float(viewport_preview.x) / design_size.x, float(viewport_preview.y) / design_size.y)
	if mode == "integer":
		result = max(1.0, floor(result))
	return result

func _display_zoom() -> float:
	return zoom * _display_scale()

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("#20242b"))
	if document == null:
		draw_string(ThemeDB.fallback_font, Vector2(24, 32), "Open a .ui.json document to begin", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color("#a8b0bd"))
		return
	var canvas_rect := Rect2(pan, Vector2(viewport_preview) * zoom)
	if grid_enabled:
		_draw_grid(canvas_rect)
	draw_rect(canvas_rect, Color("#0b0f15"), true)
	draw_rect(canvas_rect, Color("#6d7788"), false, 1.0)
	var reference_data: Dictionary = document.data.get("reference", {})
	if not bool(reference_data.get("above_canvas", false)):
		_draw_reference(canvas_rect)
	if native_preview_valid:
		draw_texture_rect(native_viewport.get_texture(), Rect2(pan, Vector2(document.viewport_size()) * _display_zoom()), false)
		for node_id in selected_ids:
			var selected := document.find_node(node_id)
			if selected.is_empty():
				continue
			var selected_rect := _node_rect(selected, pan)
			draw_rect(selected_rect.grow(3.0), Color("#78b8e8"), false, 2.0)
			if selected_ids.size() == 1:
				draw_rect(Rect2(selected_rect.end - Vector2(8, 8), Vector2(8, 8)), Color("#d7b46f"), true)
	else:
		_draw_node(document.root(), pan, true)
	if bool(reference_data.get("above_canvas", false)):
		_draw_reference(canvas_rect)
	_draw_overlay(canvas_rect)

func _draw_grid(canvas_rect: Rect2) -> void:
	var grid_color := Color(0.30, 0.34, 0.40, 0.15)
	var step := max(8.0, 16.0 * _display_zoom())
	var x := fmod(canvas_rect.position.x, step)
	while x < size.x:
		draw_line(Vector2(x, 0), Vector2(x, size.y), grid_color, 1.0)
		x += step
	var y := fmod(canvas_rect.position.y, step)
	while y < size.y:
		draw_line(Vector2(0, y), Vector2(size.x, y), grid_color, 1.0)
		y += step

func _draw_overlay(canvas_rect: Rect2) -> void:
	var label := "%dx%d  ·  %d%%  ·  %s" % [viewport_preview.x, viewport_preview.y, int(_display_zoom() * 100.0), preview_state.to_upper()]
	draw_rect(Rect2(12, size.y - 34, 280, 24), Color(0.05, 0.07, 0.10, 0.92), true)
	draw_string(ThemeDB.fallback_font, Vector2(22, size.y - 17), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("#b7c0cc"))
	draw_string(ThemeDB.fallback_font, Vector2(canvas_rect.position.x + 10, canvas_rect.position.y - 8), "%dx%d design" % [document.viewport_size().x, document.viewport_size().y], HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color("#8794a6"))

func _draw_reference(canvas_rect: Rect2) -> void:
	if reference_texture == null:
		return
	var reference: Dictionary = document.data.get("reference", {})
	if not bool(reference.get("visible", true)):
		return
	var opacity := float(reference.get("opacity", 0.28))
	var scale := float(reference.get("scale", 1.0))
	var position_array: Array = reference.get("position", [0, 0])
	var position := Vector2(float(position_array[0]), float(position_array[1])) if position_array.size() >= 2 else Vector2.ZERO
	var display_zoom := _display_zoom()
	var texture_size := Vector2(reference_texture.get_size()) * display_zoom * scale
	var target := Rect2(canvas_rect.position + position * display_zoom, texture_size)
	draw_texture_rect(reference_texture, target, false, Color(1, 1, 1, opacity))

func _draw_node(node: Dictionary, parent_origin: Vector2, is_root: bool = false) -> void:
	var node_properties: Dictionary = node.get("properties", {})
	if node_properties.has("visible") and not bool(node_properties.get("visible", true)):
		return
	var rect := _node_rect(node, parent_origin, is_root)
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return
	var node_type := str(node.get("type", "Control"))
	var fill := _fill_for(node)
	if node_type in ["Label", "RichText"]:
		fill = Color.TRANSPARENT
	if node_type == "Separator":
		draw_line(rect.position + Vector2(0, rect.size.y * 0.5), rect.position + Vector2(rect.size.x, rect.size.y * 0.5), Color("#746347"), max(1.0, _display_zoom()))
	else:
		if fill.a > 0.0:
			draw_rect(rect, fill, true)
		_draw_asset_texture(node, rect)
		if node_type in ["WindowFrame", "OrnatePanel", "SimplePanel", "SectionPanel", "Panel", "ItemSlot", "EquipmentSlot", "CharacterPreviewFrame", "PrimaryButton", "SecondaryButton", "TabButton", "QuestEntry", "SidebarEntry", "SearchBox", "GameplaySidebar", "GameplaySidebarTab", "GameplaySidebarToggle", "EnemyTargetFrame", "EnemyStatusEffect"]:
			draw_rect(rect, _border_for(node), false, max(1.0, _display_zoom() * 1.5))
	_draw_text(node, rect)
	for child in _draw_children(node):
		if child is Dictionary:
			_draw_node(child, rect.position)
	if str(node.get("id", "")) in selected_ids:
		draw_rect(rect.grow(3.0), Color("#78b8e8"), false, 2.0)
		if selected_ids.size() == 1:
			var handle := Rect2(rect.end - Vector2(8, 8), Vector2(8, 8))
			draw_rect(handle, Color("#d7b46f"), true)

func _draw_asset_texture(node: Dictionary, rect: Rect2) -> void:
	var properties: Dictionary = node.get("properties", {})
	var node_type := str(node.get("type", ""))
	var has_full_texture := properties.has("texture") or node_type in ["Texture", "TextureRect", "NinePatchRect", "TextureButton", "IconButton"]
	var texture_path := str(properties.get("texture", "")) if has_full_texture else str(properties.get("icon", ""))
	if texture_path.is_empty():
		return
	var texture := _texture_for_path(texture_path)
	if texture == null:
		return
	var region: Variant = properties.get("texture_region")
	if region is Array and region.size() == 4:
		var numeric := true
		for value in region:
			if not (value is int or value is float):
				numeric = false
		if numeric:
			var atlas := AtlasTexture.new()
			atlas.atlas = texture
			atlas.region = Rect2(float(region[0]), float(region[1]), float(region[2]), float(region[3]))
			atlas.filter_clip = true
			texture = atlas
	var tint := Color.WHITE
	if properties.has("opacity"):
		tint.a = float(properties.opacity)
	if not has_full_texture and properties.has("icon"):
		var icon_size := min(rect.size.y - 12.0, rect.size.x - 12.0)
		var icon_rect := Rect2(rect.position + Vector2(6, 6), Vector2(icon_size, icon_size))
		draw_texture_rect(texture, icon_rect, false, tint)
	else:
		draw_texture_rect(texture, rect, false, tint)

func _texture_for_path(path: String) -> Texture2D:
	if texture_cache.has(path):
		return texture_cache[path]
	var texture := load(path) as Texture2D if ResourceLoader.exists(path) else null
	if texture != null:
		texture_cache[path] = texture
	return texture

func _draw_text(node: Dictionary, rect: Rect2) -> void:
	var properties: Dictionary = node.get("properties", {})
	var text := str(properties.get("text", properties.get("title", properties.get("label", ""))))
	if text.is_empty():
		return
	var color_value := _resolve_color(properties.get("color", "$colors.text_primary"), Color("#f3ead5"))
	var font_size := int(_resolve_value(properties.get("font_size", "$font_size.body"), 15))
	var baseline := rect.position + Vector2(10, min(rect.size.y - 7, max(font_size + 5, rect.size.y * 0.62)))
	draw_string(ThemeDB.fallback_font, baseline, text, HORIZONTAL_ALIGNMENT_LEFT, max(-1.0, rect.size.x - 18), max(8, int(font_size * _display_zoom())), color_value)

func _draw_children(node: Dictionary) -> Array:
	var children: Array = []
	for child in node.get("children", []):
		if child is Dictionary:
			children.append(child)
	if str(node.get("type", "")) == "ItemGrid" and children.is_empty():
		var mock: Dictionary = node.get("mock_data", {})
		var properties: Dictionary = node.get("properties", {})
		var count := int(mock.get("item_count", 0))
		var columns: int = max(1, int(properties.get("columns", 8)))
		var slot_size: float = float(_resolve_value(properties.get("slot_size", "$slot_size.md"), 54.0))
		var gap: float = float(_resolve_value(properties.get("gap", "$spacing.sm"), 0.0))
		for index in count:
			var column: int = index % columns
			var row: int = index / columns
			children.append({"id": "%s_slot_%02d" % [str(node.get("id", "grid")), index + 1], "type": "ItemSlot", "layout": {"position": [column * (slot_size + gap), row * (slot_size + gap)], "size": [slot_size, slot_size]}, "properties": {"label": "Item %02d" % (index + 1), "count": str(index + 1) if index < int(mock.get("occupied_slots", count)) else ""}})
	children.append_array(UIForgeCompiler.decoration_children(node))
	return children

func _node_rect(node: Dictionary, parent_origin: Vector2, is_root: bool = false) -> Rect2:
	if native_preview_valid and native_controls.has(str(node.get("id", ""))):
		var native_control: Control = native_controls[str(node.id)]
		var bounds: Rect2 = native_control.get_global_transform() * Rect2(Vector2.ZERO, native_control.size)
		return Rect2(pan + bounds.position * _display_zoom(), bounds.size * _display_zoom())
	var layout: Dictionary = node.get("layout", {})
	var position_array: Array = layout.get("position", [0, 0])
	var size_array: Array = layout.get("size", layout.get("min_size", [120, 40]))
	var position := Vector2(float(position_array[0]), float(position_array[1])) if position_array.size() >= 2 else Vector2.ZERO
	var node_size := Vector2(float(size_array[0]), float(size_array[1])) if size_array.size() >= 2 else Vector2(120, 40)
	if str(node.get("type", "")) == "ItemSlot" and layout.get("size", []).is_empty():
		node_size = Vector2(54, 54)
	return Rect2(parent_origin + position * _display_zoom(), node_size * _display_zoom())

func _fill_for(node: Dictionary) -> Color:
	var node_type := str(node.get("type", "Control"))
	var colors := {
		"WindowFrame": Color("#151a22e8"), "OrnatePanel": Color("#202733dd"), "SectionPanel": Color("#202733e8"),
		"GameplaySidebar": Color("#121821f0"), "EnemyTargetFrame": Color("#160f12f2"), "EnemyStatusEffect": Color("#201b16f0"),
		"SimplePanel": Color("#0d1118e8"), "Panel": Color("#151a22cc"), "ItemSlot": Color("#10151ddd"), "EquipmentSlot": Color("#10151ddd"),
		"PrimaryButton": Color("#31465bcc"), "SecondaryButton": Color("#0d1118dd"), "TabButton": Color("#203548dd"),
		"QuestEntry": Color("#151a22dd"), "SidebarEntry": Color("#151a22dd"), "SearchBox": Color("#0d1118ee"), "CharacterPreviewFrame": Color("#151a22cc")
	}
	var base: Color = colors.get(node_type, Color.TRANSPARENT)
	if document != null:
		var theme := UIForgeTheme.from_document(document)
		var style_value: Variant = node.get("style", UIForgeComponentLibrary.style_name(node_type))
		var style: Dictionary = theme.style(str(style_value)) if style_value is String else style_value.duplicate(true) if style_value is Dictionary else {}
		var state := preview_state if preview_state != "focused" else "focus"
		var state_override: Dictionary = node.get("states", {}).get(state, {})
		if state_override.is_empty() and state == "focus":
			state_override = node.get("states", {}).get("focused", {})
		style.merge(state_override, true)
		if style.has("background"):
			base = _resolve_color(style.get("background"), base)
	if node_type in ["PrimaryButton", "SecondaryButton", "TabButton", "QuestEntry", "SidebarEntry", "ItemSlot", "EquipmentSlot"]:
		match preview_state:
			"hover":
				return Color("#31465bcc")
			"pressed":
				return Color("#1d2c3ccc")
			"disabled":
				return Color("#1a1d22aa")
			"selected":
				return Color("#324d65dd")
	return base

func _border_for(node: Dictionary) -> Color:
	var node_type := str(node.get("type", "Control"))
	if document != null:
		var theme := UIForgeTheme.from_document(document)
		var style_value: Variant = node.get("style", UIForgeComponentLibrary.style_name(node_type))
		var style: Dictionary = theme.style(str(style_value)) if style_value is String else style_value.duplicate(true) if style_value is Dictionary else {}
		var state := preview_state if preview_state != "focused" else "focus"
		var state_override: Dictionary = node.get("states", {}).get(state, {})
		if state_override.is_empty() and state == "focus":
			state_override = node.get("states", {}).get("focused", {})
		style.merge(state_override, true)
		if style.has("border"):
			return _resolve_color(style.get("border"), Color("#645039"))
	if preview_state == "focused" and node_type in ["PrimaryButton", "SecondaryButton", "TabButton", "QuestEntry", "SidebarEntry", "LineEdit"]:
		return Color("#a9d3f0")
	return Color("#c9a96a") if node_type in ["WindowFrame", "PrimaryButton"] else Color("#645039")

func _resolve_value(value: Variant, fallback: Variant) -> Variant:
	if value is String and str(value).begins_with("$") and document != null:
		var theme := UIForgeTheme.from_document(document)
		return theme.resolve(value, fallback)
	return value

func _resolve_color(value: Variant, fallback: Color) -> Color:
	var resolved := _resolve_value(value, value)
	if resolved is String:
		return Color.from_string(str(resolved), fallback)
	return fallback

func _load_reference() -> void:
	reference_texture = null
	if document == null:
		return
	var reference: Dictionary = document.data.get("reference", {})
	var path := str(reference.get("path", ""))
	if path.is_empty():
		return
	if ResourceLoader.exists(path):
		reference_texture = load(path) as Texture2D
	else:
		var image := Image.new()
		if image.load(path) == OK:
			reference_texture = ImageTexture.create_from_image(image)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_zoom_at(event.position, 1.12)
			accept_event()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_zoom_at(event.position, 0.89)
			accept_event()
		elif event.button_index == MOUSE_BUTTON_MIDDLE:
			is_panning = event.pressed
			accept_event()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				var hit := _hit_test(event.position)
				if not hit.is_empty():
					var hit_id := str(hit.get("id", ""))
					var additive: bool = event.ctrl_pressed or event.meta_pressed
					if additive or hit_id not in selected_ids:
						select_node(hit_id, additive)
					var layout: Dictionary = hit.get("layout", {})
					var rect := _node_rect(hit, _origin_for_id(str(hit.get("id", ""))))
					is_resizing = selected_ids.size() == 1 and Rect2(rect.end - Vector2(14, 14), Vector2(18, 18)).has_point(event.position)
					is_dragging = not is_resizing
					drag_start_mouse = event.position
					drag_start_document = document.data.duplicate(true)
					drag_start_positions.clear()
					for selected_id in selected_ids:
						var selected_node := document.find_node(selected_id)
						var selected_layout: Dictionary = selected_node.get("layout", {})
						var selected_position: Array = selected_layout.get("position", [0, 0])
						if selected_position.size() >= 2:
							drag_start_positions[selected_id] = Vector2(float(selected_position[0]), float(selected_position[1]))
					var position_array: Array = layout.get("position", [0, 0])
					drag_start_position = Vector2(float(position_array[0]), float(position_array[1])) if position_array.size() >= 2 else Vector2.ZERO
					var size_array: Array = layout.get("size", [120, 40])
					drag_start_size = Vector2(float(size_array[0]), float(size_array[1])) if size_array.size() >= 2 else Vector2(120, 40)
				else:
					select_node("")
			else:
				if is_dragging or is_resizing:
					_commit_drag()
				is_dragging = false
				is_resizing = false
			accept_event()
	elif event is InputEventMouseMotion:
		if is_panning:
			pan += event.relative
			queue_redraw()
			accept_event()
		elif is_dragging and selected_ids.size() == 1:
			_apply_drag(event.position, false)
			accept_event()
		elif is_resizing and selected_ids.size() == 1:
			_apply_drag(event.position, true)
			accept_event()
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_DELETE and not selected_ids.is_empty():
			delete_requested.emit(selected_ids[0])
			accept_event()
		elif event.keycode == KEY_D and event.command_or_control_pressed and not selected_ids.is_empty():
			duplicate_requested.emit(selected_ids[0])
			accept_event()
		elif event.keycode == KEY_C and event.command_or_control_pressed and not selected_ids.is_empty():
			copy_requested.emit(selected_ids.duplicate())
			accept_event()
		elif event.keycode == KEY_V and event.command_or_control_pressed:
			paste_requested.emit()
			accept_event()
		elif event.keycode == KEY_F:
			focus_selection()
			accept_event()

func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	return not _asset_path_from_drop(data).is_empty()

func _drop_data(at_position: Vector2, data: Variant) -> void:
	var path := _asset_path_from_drop(data)
	if path.is_empty():
		return
	var hit := _hit_test(at_position)
	var target_id := str(hit.get("id", ""))
	var root_id := str(document.root().get("id", "")) if document != null else ""
	var parent_for_drop := root_id
	var target_node := document.find_node(target_id) if document != null and not target_id.is_empty() else {}
	if not target_node.is_empty() and str(target_node.get("type", "")) in UIForgeTypes.CONTAINER_TYPES:
		parent_for_drop = target_id
	var design_position := (at_position - pan) / _display_zoom() - _design_origin_for_id(parent_for_drop)
	asset_drop_requested.emit(path, target_id, design_position)

func _asset_path_from_drop(data: Variant) -> String:
	var path := ""
	if data is Dictionary:
		path = str(data.get("uiforge_asset_path", data.get("aether_asset_path", data.get("resource_path", ""))))
		if path.is_empty() and data.has("files"):
			var files: Variant = data.get("files")
			if files is Array or files is PackedStringArray:
				if files.size() > 0:
					path = str(files[0])
	elif data is String:
		path = str(data)
	if path.begins_with("res://"):
		return path
	if path.is_absolute_path():
		var project_root := ProjectSettings.globalize_path("res://").replace("\\", "/").trim_suffix("/")
		var normalized := path.replace("\\", "/")
		if normalized.begins_with(project_root + "/"):
			return "res://" + normalized.substr(project_root.length() + 1)
	return ""

func _zoom_at(pointer: Vector2, factor: float) -> void:
	var before := (pointer - pan) / _display_zoom()
	zoom = clamp(zoom * factor, 0.1, 2.5)
	pan = pointer - before * _display_zoom()
	queue_redraw()

func _design_origin_for_id(node_id: String) -> Vector2:
	if document == null or node_id.is_empty():
		return Vector2.ZERO
	var origin := Vector2.ZERO
	for path_id in document.find_node_path(node_id):
		var node := document.find_node(path_id)
		var layout: Dictionary = node.get("layout", {})
		var position: Array = layout.get("position", [0, 0])
		if position.size() >= 2:
			origin += Vector2(float(position[0]), float(position[1]))
	return origin

func _apply_drag(mouse: Vector2, resize: bool) -> void:
	if document == null or selected_ids.is_empty():
		return
	var delta := (mouse - drag_start_mouse) / _display_zoom()
	if snap_enabled:
		delta = Vector2(round(delta.x / snap_size) * snap_size, round(delta.y / snap_size) * snap_size)
	if resize and selected_ids.size() == 1:
		var node := document.find_node(selected_ids[0])
		if node.is_empty() or bool(node.get("metadata", {}).get("editor_locked", false)):
			return
		document.set_property(selected_ids[0], "layout.size", [max(24.0, drag_start_size.x + delta.x), max(24.0, drag_start_size.y + delta.y)])
	else:
		for selected_id in selected_ids:
			var start_position: Vector2 = drag_start_positions.get(selected_id, Vector2.ZERO)
			var selected_node := document.find_node(selected_id)
			if selected_node.is_empty() or bool(selected_node.get("metadata", {}).get("editor_locked", false)):
				continue
			document.set_property(selected_id, "layout.position", [start_position.x + delta.x, start_position.y + delta.y])
	node_changed.emit(selected_ids[0])
	queue_redraw()

func _commit_drag() -> void:
	if document == null or drag_start_document.is_empty():
		return
	if undo_redo != null:
		var before_snapshot := drag_start_document.duplicate(true)
		var after_snapshot := document.data.duplicate(true)
		undo_redo.create_action("UIForge %s" % ("Resize" if is_resizing else "Move"))
		undo_redo.add_do_method(self, "_apply_drag_document_snapshot", after_snapshot)
		undo_redo.add_undo_method(self, "_apply_drag_document_snapshot", before_snapshot)
		undo_redo.commit_action()
	drag_start_document.clear()

func _apply_drag_document_snapshot(snapshot: Dictionary) -> void:
	document.data = snapshot.duplicate(true)
	queue_redraw()

func _hit_test(point: Vector2) -> Dictionary:
	if document == null:
		return {}
	return _hit_node(document.root(), pan, point, true)

func _hit_node(node: Dictionary, parent_origin: Vector2, point: Vector2, is_root: bool = false) -> Dictionary:
	var node_properties: Dictionary = node.get("properties", {})
	if node_properties.has("visible") and not bool(node_properties.get("visible", true)):
		return {}
	if native_preview_valid and native_controls.has(str(node.get("id", ""))):
		var control: Control = native_controls[str(node.id)]
		if not control.is_visible_in_tree():
			return {}
		if control.clip_contents and not _node_rect(node, parent_origin, is_root).has_point(point):
			return {}
	var children := _draw_children(node)
	for index in range(children.size() - 1, -1, -1):
		var child: Dictionary = children[index]
		var hit := _hit_node(child, _node_rect(node, parent_origin, is_root).position, point)
		if not hit.is_empty():
			return hit if not document.find_node(str(hit.get("id", ""))).is_empty() else node
	var rect := _node_rect(node, parent_origin, is_root)
	return node if rect.has_point(point) else {}

func _origin_for_id(node_id: String) -> Vector2:
	if document == null:
		return pan
	var path := document.find_node_path(node_id)
	var origin := pan
	for id in path:
		var node := document.find_node(id)
		var layout: Dictionary = node.get("layout", {})
		var position: Array = layout.get("position", [0, 0])
		if id != node_id and position.size() >= 2:
			origin += Vector2(float(position[0]), float(position[1])) * _display_zoom()
	return origin
