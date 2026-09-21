@tool
class_name AetherNineSliceEditor
extends VBoxContainer

const PREVIEW_SCRIPT := preload("res://addons/aether_ui/editor/aether_nine_slice_preview.gd")

signal style_save_requested(style_name: String, payload: Dictionary)

var preview: AetherNineSlicePreview
var texture: Texture2D
var texture_path: String = ""
var margin_fields: Dictionary = {}
var file_dialog: FileDialog
var summary: Label
var preview_size_select: OptionButton
var style_name_field: LineEdit

func _ready() -> void:
	if get_child_count() == 0:
		_build()

func _build() -> void:
	var header := HBoxContainer.new()
	var title := Label.new()
	title.text = "NINE-SLICE STYLE"
	title.add_theme_color_override("font_color", Color("#c9a96a"))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var load_button := Button.new()
	load_button.text = "Load texture"
	load_button.pressed.connect(_open_texture)
	header.add_child(load_button)
	preview_size_select = OptionButton.new()
	for size_option in [Vector2i(320, 180), Vector2i(640, 360), Vector2i(1024, 512)]:
		preview_size_select.add_item("%dx%d" % [size_option.x, size_option.y])
		preview_size_select.set_item_metadata(preview_size_select.item_count - 1, Vector2(size_option))
	preview_size_select.item_selected.connect(_on_preview_size_selected)
	header.add_child(preview_size_select)
	add_child(header)
	var help := Label.new()
	help.text = "Drop a frame texture here or load one. Drag the blue guides or set margins; corners stay preserved while the center stretches."
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.add_theme_color_override("font_color", Color("#8d97a7"))
	add_child(help)
	preview = PREVIEW_SCRIPT.new()
	preview.custom_minimum_size = Vector2(300, 100)
	preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	preview.margins_changed.connect(_on_preview_margins_changed)
	preview.texture_drop_requested.connect(_on_texture_selected)
	add_child(preview)
	var fields := HBoxContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		var column := VBoxContainer.new()
		var label := Label.new()
		label.text = side.capitalize()
		column.add_child(label)
		var spin := SpinBox.new()
		spin.min_value = 0
		spin.max_value = 2048
		spin.value = 24
		spin.step = 1
		spin.value_changed.connect(_on_margin_changed.bind(side))
		column.add_child(spin)
		fields.add_child(column)
		margin_fields[side] = spin
	add_child(fields)
	var save_row := HBoxContainer.new()
	style_name_field = LineEdit.new()
	style_name_field.placeholder_text = "Reusable style name (e.g. ornate_frame)"
	style_name_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save_row.add_child(style_name_field)
	var save_button := Button.new()
	save_button.text = "Save reusable style"
	save_button.pressed.connect(_save_style)
	save_row.add_child(save_button)
	add_child(save_row)
	summary = Label.new()
	summary.text = "No texture selected · StyleBoxTexture output is supported by the compiler"
	summary.add_theme_color_override("font_color", Color("#8d97a7"))
	add_child(summary)
	file_dialog = FileDialog.new()
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.add_filter("*.png,*.jpg,*.jpeg,*.webp,*.svg", "Frame textures")
	file_dialog.file_selected.connect(_on_texture_selected)
	add_child(file_dialog)
	preview_size_select.select(0)
	preview.set_target_size(Vector2(320, 180))
	_sync_preview()

func _open_texture() -> void:
	file_dialog.popup_centered_ratio(0.7)

func _on_texture_selected(path: String) -> void:
	texture_path = _normalize_resource_path(path)
	texture = load(texture_path) as Texture2D
	_sync_preview()

func _normalize_resource_path(path: String) -> String:
	if path.begins_with("res://"):
		return path
	if path.is_absolute_path():
		var project_root := ProjectSettings.globalize_path("res://").replace("\\", "/").trim_suffix("/")
		var normalized := path.replace("\\", "/")
		if normalized.begins_with(project_root + "/"):
			return "res://" + normalized.substr(project_root.length() + 1)
	return path

func _can_drop_data(_position: Vector2, data: Variant) -> bool:
	var path := _asset_path(data)
	return path.get_extension().to_lower() in ["png", "jpg", "jpeg", "webp", "svg"]

func _drop_data(_position: Vector2, data: Variant) -> void:
	if _can_drop_data(Vector2.ZERO, data):
		_on_texture_selected(_asset_path(data))

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

func _on_preview_size_selected(index: int) -> void:
	if preview_size_select == null or preview == null:
		return
	preview.set_target_size(preview_size_select.get_item_metadata(index))

func _on_preview_margins_changed(value: Vector4) -> void:
	var sides := ["left", "top", "right", "bottom"]
	for index in sides.size():
		var spin: SpinBox = margin_fields.get(sides[index])
		if spin != null:
			spin.set_value_no_signal(value[index])
	_sync_preview()

func _on_margin_changed(_value: float, _side: String) -> void:
	_sync_preview()

func _save_style() -> void:
	var style_name := style_name_field.text.strip_edges() if style_name_field != null else ""
	if style_name.is_empty():
		style_name = texture_path.get_file().get_basename().to_snake_case() if not texture_path.is_empty() else "frame_style"
	style_name = style_name.to_snake_case()
	style_save_requested.emit(style_name, style_payload())
	if summary != null:
		summary.text = "Saved reusable style '%s' · %s" % [style_name, texture_path.get_file() if not texture_path.is_empty() else "procedural frame"]

func _sync_preview() -> void:
	if preview == null:
		return
	preview.texture = texture
	preview.margins = Vector4(_margin("left"), _margin("top"), _margin("right"), _margin("bottom"))
	preview.queue_redraw()
	if summary != null:
		summary.text = "%s  ·  margins L%d T%d R%d B%d" % [texture_path.get_file() if not texture_path.is_empty() else "No texture selected", int(preview.margins.x), int(preview.margins.y), int(preview.margins.z), int(preview.margins.w)]

func _margin(side: String) -> float:
	var spin: SpinBox = margin_fields.get(side)
	return spin.value if spin != null else 24.0

func style_payload() -> Dictionary:
	return {"texture": texture_path, "texture_margin_left": _margin("left"), "texture_margin_top": _margin("top"), "texture_margin_right": _margin("right"), "texture_margin_bottom": _margin("bottom")}
