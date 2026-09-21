@tool
class_name AetherNineSlicePreview
extends Control

signal margins_changed(value: Vector4)
signal texture_drop_requested(path: String)

var texture: Texture2D
var margins: Vector4 = Vector4(24, 24, 24, 24)
var target_size: Vector2 = Vector2(420, 240)
var dragging_side: String = ""

func _ready() -> void:
	mouse_default_cursor_shape = Control.CURSOR_CROSS

func set_target_size(value: Vector2) -> void:
	target_size = Vector2(max(value.x, 32.0), max(value.y, 32.0))
	queue_redraw()

func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	var path := _asset_path(data)
	return path.get_extension().to_lower() in ["png", "jpg", "jpeg", "webp", "svg"]

func _drop_data(_at_position: Vector2, data: Variant) -> void:
	var path := _asset_path(data)
	if not path.is_empty():
		texture_drop_requested.emit(path)

func _asset_path(data: Variant) -> String:
	if data is Dictionary:
		var path := str(data.get("aether_asset_path", data.get("resource_path", "")))
		if path.is_empty() and data.has("files"):
			var files: Variant = data.get("files")
			if files is Array or files is PackedStringArray:
				if files.size() > 0:
					path = str(files[0])
		return path
	if data is String:
		return str(data)
	return ""

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("#0b0f15"), true)
	var available: Vector2 = size - Vector2(28, 28)
	var display_scale: float = min(1.0, min(available.x / target_size.x, available.y / target_size.y))
	if display_scale <= 0.0:
		return
	var display_size: Vector2 = target_size * display_scale
	var origin: Vector2 = (size - display_size) * 0.5
	draw_set_transform(origin, 0.0, Vector2(display_scale, display_scale))
	draw_rect(Rect2(Vector2.ZERO, target_size), Color("#101722"), true)
	if texture != null:
		var style := StyleBoxTexture.new()
		style.texture = texture
		style.texture_margin_left = margins.x
		style.texture_margin_top = margins.y
		style.texture_margin_right = margins.z
		style.texture_margin_bottom = margins.w
		draw_style_box(style, Rect2(Vector2.ZERO, target_size))
	else:
		draw_rect(Rect2(Vector2.ZERO, target_size), Color("#202733"), true)
		draw_rect(Rect2(Vector2.ZERO, target_size), Color("#c9a96a"), false, 3.0)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	# Guides remain visible over the frame and scale with the preview target.
	draw_line(origin + Vector2(margins.x * display_scale, 0), origin + Vector2(margins.x * display_scale, display_size.y), Color("#6fa6d8"), 2.0)
	draw_line(origin + Vector2(display_size.x - margins.z * display_scale, 0), origin + Vector2(display_size.x - margins.z * display_scale, display_size.y), Color("#6fa6d8"), 2.0)
	draw_line(origin + Vector2(0, margins.y * display_scale), origin + Vector2(display_size.x, margins.y * display_scale), Color("#6fa6d8"), 2.0)
	draw_line(origin + Vector2(0, display_size.y - margins.w * display_scale), origin + Vector2(display_size.x, display_size.y - margins.w * display_scale), Color("#6fa6d8"), 2.0)
	draw_string(ThemeDB.fallback_font, origin + Vector2(8, 18), "%dx%d" % [int(target_size.x), int(target_size.y)], HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("#d8e4f2"))

func _gui_input(event: InputEvent) -> void:
	var available: Vector2 = size - Vector2(28, 28)
	var display_scale: float = min(1.0, min(available.x / target_size.x, available.y / target_size.y))
	if display_scale <= 0.0:
		return
	var display_size: Vector2 = target_size * display_scale
	var origin: Vector2 = (size - display_size) * 0.5
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var local: Vector2 = (event.position - origin) / display_scale
		if event.pressed:
			dragging_side = _side_at(local)
			if not dragging_side.is_empty():
				accept_event()
		else:
			dragging_side = ""
			accept_event()
	elif event is InputEventMouseMotion and not dragging_side.is_empty():
		var local_motion: Vector2 = (event.position - origin) / display_scale
		var next := margins
		match dragging_side:
			"left": next.x = clamp(local_motion.x, 0.0, target_size.x - next.z - 1.0)
			"right": next.z = clamp(target_size.x - local_motion.x, 0.0, target_size.x - next.x - 1.0)
			"top": next.y = clamp(local_motion.y, 0.0, target_size.y - next.w - 1.0)
			"bottom": next.w = clamp(target_size.y - local_motion.y, 0.0, target_size.y - next.y - 1.0)
		margins = next
		margins_changed.emit(margins)
		queue_redraw()
		accept_event()

func _side_at(local: Vector2) -> String:
	if local.x < -2.0 or local.y < -2.0 or local.x > target_size.x + 2.0 or local.y > target_size.y + 2.0:
		return ""
	var distances := {"left": abs(local.x - margins.x), "right": abs(local.x - (target_size.x - margins.z)), "top": abs(local.y - margins.y), "bottom": abs(local.y - (target_size.y - margins.w))}
	var closest := ""
	var distance := 12.0
	for side in distances:
		if float(distances[side]) < distance:
			distance = float(distances[side])
			closest = side
	return closest
