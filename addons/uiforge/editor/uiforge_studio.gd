@tool
class_name UIForgeStudio
extends VBoxContainer

const CANVAS_SCRIPT := preload("res://addons/uiforge/canvas/uiforge_canvas.gd")
const NINE_SLICE_SCRIPT := preload("res://addons/uiforge/editor/uiforge_nine_slice_editor.gd")
const INSPECTOR_SCRIPT := preload("res://addons/uiforge/inspectors/uiforge_property_inspector.gd")
const ASSET_LIST_SCRIPT := preload("res://addons/uiforge/editor/uiforge_asset_list.gd")
const HIERARCHY_TREE_SCRIPT := preload("res://addons/uiforge/editor/uiforge_hierarchy_tree.gd")

var editor_undo_redo: EditorUndoRedoManager
var document: UIForgeDocument
var document_path: String = ""
var dirty: bool = false
var editor_session: UIForgeEditorSession = UIForgeEditorSession.new()

var toolbar: HBoxContainer
var tree: UIForgeHierarchyTree
var canvas: UIForgeCanvas
var inspector: VBoxContainer
var property_inspector: UIForgePropertyInspector
var inspector_header: Label
var state_select: OptionButton
var viewport_select: OptionButton
var custom_viewport_dialog: ConfirmationDialog
var custom_viewport_width: SpinBox
var custom_viewport_height: SpinBox
var theme_select: OptionButton
var diagnostics_view: RichTextLabel
var reference_opacity: SpinBox
var reference_scale: SpinBox
var reference_visible: CheckBox
var reference_above: CheckBox
var reference_locked: CheckBox
var reference_position: LineEdit
var component_list: ItemList
var asset_list: UIForgeAssetList
var asset_search: LineEdit
var asset_paths: Array[String] = []
var asset_index_ready: bool = false
var asset_index_scanning: bool = false
var asset_scan_steps: int = 0
var asset_index_root: String = "res://"
var _asset_scan_queue: Array[String] = []
var _asset_scan_dir: DirAccess = null
var _asset_scan_dir_path: String = ""
const ASSET_SCAN_BUDGET := 48
const ASSET_EXTENSIONS := ["png", "jpg", "jpeg", "webp", "svg", "ttf", "otf", "woff", "woff2", "tres", "res", "material", "gdshader", "shader", "json"]
static var asset_scan_calls_during_init: int = 0
var status_label: Label
var file_dialog: FileDialog
var unsaved_dialog: ConfirmationDialog
var dialog_mode: String = "open"
var pending_discard_action: String = ""
var pending_discard_path: String = ""
var preview_window: Window
var synchronizing_selection: bool = false
var clipboard_nodes: Array[Dictionary] = []
var template_dialog: ConfirmationDialog
var template_select: OptionButton

func _ready() -> void:
	if get_child_count() == 0:
		_build_ui()
	if document == null:
		set_document(UIForgeSerializer.create_default("untitled"), "")

func set_editor_undo_redo(value: EditorUndoRedoManager) -> void:
	editor_undo_redo = value
	if canvas != null:
		canvas.set_editor_undo_redo(value)

func _build_ui() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_build_toolbar()
	var main_split := HSplitContainer.new()
	main_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_split.split_offset = 230
	add_child(main_split)
	var hierarchy_panel := _panel_with_title("HIERARCHY")
	main_split.add_child(hierarchy_panel)
	tree = HIERARCHY_TREE_SCRIPT.new()
	tree.hide_root = true
	tree.columns = 1
	tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tree.item_selected.connect(_on_tree_selected)
	tree.node_drop_requested.connect(_on_tree_node_drop)
	hierarchy_panel.get_node("Body").add_child(tree)
	var center_inspector := HSplitContainer.new()
	center_inspector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center_inspector.size_flags_vertical = Control.SIZE_EXPAND_FILL
	center_inspector.split_offset = 680
	main_split.add_child(center_inspector)
	canvas = CANVAS_SCRIPT.new()
	canvas.name = "DesignCanvas"
	canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	canvas.custom_minimum_size = Vector2(500, 400)
	canvas.node_selected.connect(_on_canvas_selected)
	canvas.node_changed.connect(_on_canvas_changed)
	canvas.delete_requested.connect(_on_canvas_delete)
	canvas.duplicate_requested.connect(_on_canvas_duplicate)
	canvas.asset_drop_requested.connect(_on_asset_drop)
	canvas.copy_requested.connect(_on_canvas_copy)
	canvas.paste_requested.connect(_on_canvas_paste)
	center_inspector.add_child(canvas)
	property_inspector = INSPECTOR_SCRIPT.new()
	property_inspector.name = "Inspector"
	property_inspector.custom_minimum_size = Vector2(310, 0)
	property_inspector.size_flags_vertical = Control.SIZE_EXPAND_FILL
	property_inspector.apply_requested.connect(_on_inspector_apply)
	center_inspector.add_child(property_inspector)
	_build_bottom_panel()
	_build_file_dialog()
	_build_unsaved_dialog()

func _build_toolbar() -> void:
	toolbar = HBoxContainer.new()
	toolbar.custom_minimum_size.y = 38
	toolbar.add_theme_constant_override("separation", 5)
	add_child(toolbar)
	_add_toolbar_button("New", _on_new)
	_add_toolbar_button("Open", _on_open)
	_add_toolbar_button("Save", _on_save)
	_add_toolbar_button("Validate", _on_validate)
	_add_toolbar_button("Build", _on_build)
	_add_toolbar_button("Preview", _on_preview)
	_add_toolbar_button("Fit", _on_fit)
	_add_toolbar_button("Grid", _toggle_grid)
	_add_toolbar_button("Snap", _toggle_snap)
	_add_toolbar_button("Reference", _on_reference)
	_add_toolbar_button("Duplicate", _duplicate_selected)
	_add_toolbar_button("Delete", _delete_selected)
	_add_toolbar_button("Up", _move_selected_up)
	_add_toolbar_button("Down", _move_selected_down)
	_add_toolbar_button("Hide", _toggle_selected_visibility)
	_add_toolbar_button("Lock", _toggle_selected_lock)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(spacer)
	var theme_label := Label.new()
	theme_label.text = "Theme"
	theme_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	toolbar.add_child(theme_label)
	theme_select = OptionButton.new()
	theme_select.add_item("dark_fantasy")
	theme_select.item_selected.connect(_on_theme_selected)
	toolbar.add_child(theme_select)
	var state_label := Label.new()
	state_label.text = "State"
	state_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	toolbar.add_child(state_label)
	state_select = OptionButton.new()
	for state in UIForgeTypes.STATES:
		state_select.add_item(state.capitalize())
		state_select.set_item_metadata(state_select.item_count - 1, state)
	state_select.item_selected.connect(_on_state_selected)
	toolbar.add_child(state_select)
	var viewport_label := Label.new()
	viewport_label.text = "Viewport"
	viewport_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	toolbar.add_child(viewport_label)
	viewport_select = OptionButton.new()
	for preset in UIForgeTypes.VIEWPORT_PRESETS:
		viewport_select.add_item("%dx%d" % [preset.x, preset.y])
		viewport_select.set_item_metadata(viewport_select.item_count - 1, preset)
	viewport_select.item_selected.connect(_on_viewport_selected)
	toolbar.add_child(viewport_select)
	_add_toolbar_button("Custom…", _open_custom_viewport)

func _add_toolbar_button(label: String, callback: Callable) -> void:
	var button := Button.new()
	button.text = label
	button.tooltip_text = label
	button.pressed.connect(callback)
	toolbar.add_child(button)

func _panel_with_title(title: String) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.custom_minimum_size.x = 210
	var body := VBoxContainer.new()
	body.name = "Body"
	body.add_theme_constant_override("separation", 6)
	var label := Label.new()
	label.text = title
	label.add_theme_color_override("font_color", Color("#c9a96a"))
	label.add_theme_font_size_override("font_size", 12)
	body.add_child(label)
	panel.add_child(body)
	return panel

func _build_bottom_panel() -> void:
	var bottom := TabContainer.new()
	bottom.custom_minimum_size.y = 155
	bottom.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(bottom)
	var components := VBoxContainer.new()
	components.name = "Components"
	var component_toolbar := HBoxContainer.new()
	var component_hint := Label.new()
	component_hint.text = "Reusable components"
	component_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	component_toolbar.add_child(component_hint)
	var add_component := Button.new()
	add_component.text = "Add selected"
	add_component.pressed.connect(_add_selected_component)
	component_toolbar.add_child(add_component)
	components.add_child(component_toolbar)
	component_list = ItemList.new()
	component_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	component_list.max_columns = 4
	component_list.select_mode = ItemList.SELECT_SINGLE
	for component_name in UIForgeComponentLibrary.definitions().keys():
		component_list.add_item(str(component_name))
		component_list.set_item_metadata(component_list.item_count - 1, component_name)
	component_list.item_activated.connect(_on_component_activated)
	components.add_child(component_list)
	bottom.add_child(components)
	var assets := VBoxContainer.new()
	assets.name = "Assets"
	var asset_toolbar := HBoxContainer.new()
	asset_search = LineEdit.new()
	asset_search.placeholder_text = "Filter project assets"
	asset_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	asset_search.text_changed.connect(_on_asset_filter_changed)
	asset_toolbar.add_child(asset_search)
	var refresh_assets := Button.new()
	refresh_assets.text = "Refresh"
	refresh_assets.pressed.connect(_refresh_assets)
	asset_toolbar.add_child(refresh_assets)
	assets.add_child(asset_toolbar)
	asset_list = ASSET_LIST_SCRIPT.new()
	asset_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	asset_list.item_activated.connect(_on_asset_activated)
	assets.add_child(asset_list)
	bottom.add_child(assets)
	call_deferred("_refresh_assets")
	var theme_view := RichTextLabel.new()
	theme_view.name = "Theme"
	theme_view.bbcode_enabled = true
	theme_view.fit_content = true
	theme_view.text = "[color=#c9a96a][b]DARK FANTASY THEME[/b][/color]\n\nToken references keep the five sample screens coherent.\n\n[color=#8d97a7]%s[/color]" % JSON.stringify(UIForgeTheme.load_named("dark_fantasy").tokens, "  ")
	bottom.add_child(theme_view)
	var reference_panel := VBoxContainer.new()
	reference_panel.name = "Reference"
	var reference_hint := Label.new()
	reference_hint.text = "Reference image controls"
	reference_hint.add_theme_color_override("font_color", Color("c9a96a"))
	reference_panel.add_child(reference_hint)
	reference_position = LineEdit.new()
	reference_position.placeholder_text = "Position x,y"
	reference_position.text_submitted.connect(_on_reference_control_changed)
	reference_panel.add_child(reference_position)
	var opacity_row := HBoxContainer.new()
	var opacity_label := Label.new()
	opacity_label.text = "Opacity"
	opacity_label.custom_minimum_size.x = 72
	opacity_row.add_child(opacity_label)
	reference_opacity = SpinBox.new()
	reference_opacity.min_value = 0.0
	reference_opacity.max_value = 1.0
	reference_opacity.step = 0.05
	reference_opacity.value = 0.28
	reference_opacity.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reference_opacity.value_changed.connect(_on_reference_control_changed)
	opacity_row.add_child(reference_opacity)
	reference_panel.add_child(opacity_row)
	var scale_row := HBoxContainer.new()
	var scale_label := Label.new()
	scale_label.text = "Scale"
	scale_label.custom_minimum_size.x = 72
	scale_row.add_child(scale_label)
	reference_scale = SpinBox.new()
	reference_scale.min_value = 0.05
	reference_scale.max_value = 8.0
	reference_scale.step = 0.05
	reference_scale.value = 1.0
	reference_scale.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reference_scale.value_changed.connect(_on_reference_control_changed)
	scale_row.add_child(reference_scale)
	reference_panel.add_child(scale_row)
	reference_visible = CheckBox.new()
	reference_visible.text = "Visible"
	reference_visible.button_pressed = true
	reference_visible.toggled.connect(_on_reference_control_changed)
	reference_panel.add_child(reference_visible)
	reference_above = CheckBox.new()
	reference_above.text = "Show above canvas"
	reference_above.toggled.connect(_on_reference_control_changed)
	reference_panel.add_child(reference_above)
	reference_locked = CheckBox.new()
	reference_locked.text = "Lock reference"
	reference_locked.button_pressed = true
	reference_locked.toggled.connect(_on_reference_control_changed)
	reference_panel.add_child(reference_locked)
	bottom.add_child(reference_panel)
	var nine_slice := NINE_SLICE_SCRIPT.new()
	nine_slice.name = "Nine-slice"
	nine_slice.style_save_requested.connect(_on_nine_slice_style_save)
	bottom.add_child(nine_slice)
	var diagnostics := VBoxContainer.new()
	diagnostics.name = "Diagnostics"
	diagnostics_view = RichTextLabel.new()
	diagnostics_view.name = "DiagnosticsView"
	diagnostics_view.bbcode_enabled = true
	diagnostics_view.fit_content = true
	diagnostics_view.scroll_active = true
	diagnostics_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	diagnostics.add_child(diagnostics_view)
	bottom.add_child(diagnostics)
	status_label = Label.new()
	status_label.text = "Ready"
	status_label.custom_minimum_size.y = 20
	status_label.add_theme_color_override("font_color", Color("#8d97a7"))
	add_child(status_label)

func _notify_document_changed() -> void:
	if canvas != null:
		canvas.invalidate_native_preview()

func _custom_components() -> Dictionary:
	if document == null:
		return {}
	var components_value: Variant = document.data.get("components", {})
	return components_value if components_value is Dictionary else {}

func _reconcile_editor_state() -> void:
	dirty = editor_session.is_dirty(document)
	_update_status()

func _reconcile_document_view() -> void:
	if canvas != null:
		canvas.set_document(document)
	_notify_document_changed()
	_refresh_tree()
	_update_inspector()
	_reconcile_editor_state()

func reconcile_document_snapshot(snapshot: Dictionary, session_id: int) -> void:
	if session_id != editor_session.current_session_id():
		return
	document.data = snapshot.duplicate(true)
	_reconcile_document_view()

func reconcile_node_snapshot(node_id: String, value: Dictionary, session_id: int) -> void:
	if session_id != editor_session.current_session_id():
		return
	_replace_node(node_id, value)
	_reconcile_document_view()

func _refresh_assets() -> void:
	if asset_index_scanning:
		return
	asset_index_scanning = true
	asset_index_ready = false
	asset_scan_steps = 0
	asset_paths.clear()
	_asset_scan_dir = null
	_asset_scan_dir_path = ""
	_asset_scan_queue = [asset_index_root]
	call_deferred("_scan_assets_step")

func _scan_assets_step() -> void:
	if not asset_index_scanning:
		return
	asset_scan_steps += 1
	var budget := ASSET_SCAN_BUDGET
	while budget > 0:
		if _asset_scan_dir == null:
			if _asset_scan_queue.is_empty():
				break
			_asset_scan_dir_path = _asset_scan_queue.pop_front()
			_asset_scan_dir = DirAccess.open(_asset_scan_dir_path)
			if _asset_scan_dir == null:
				budget -= 1
				continue
			_asset_scan_dir.list_dir_begin()
		var filename := _asset_scan_dir.get_next()
		if filename.is_empty():
			_asset_scan_dir.list_dir_end()
			_asset_scan_dir = null
			_asset_scan_dir_path = ""
			continue
		budget -= 1
		if filename.begins_with("."):
			continue
		var child_path := _asset_scan_dir_path.path_join(filename)
		if _asset_scan_dir.current_is_dir():
			_asset_scan_queue.append(child_path)
		elif filename.get_extension().to_lower() in ASSET_EXTENSIONS:
			asset_paths.append(child_path)
	if _asset_scan_queue.is_empty() and _asset_scan_dir == null:
		asset_paths.sort()
		asset_index_scanning = false
		asset_index_ready = true
		_refresh_asset_list(asset_search.text if asset_search != null else "")
		return
	call_deferred("_scan_assets_step")

func _refresh_asset_list(query: String = "") -> void:
	if asset_list == null:
		return
	asset_list.clear()
	var filter := query.to_lower()
	for path in asset_paths:
		if filter.is_empty() or path.to_lower().contains(filter):
			asset_list.add_item("%s  ·  %s" % [path.get_file(), path.get_extension().to_upper()])
			asset_list.set_item_metadata(asset_list.item_count - 1, path)
	if asset_list.item_count == 0:
		asset_list.add_item("No matching project assets; procedural styling is active.")

func _on_asset_filter_changed(value: String) -> void:
	_refresh_asset_list(value)

func _on_asset_activated(index: int) -> void:
	if asset_list == null or index < 0 or index >= asset_list.item_count:
		return
	var path := str(asset_list.get_item_metadata(index))
	if not path.is_empty():
		_apply_asset_to_selection(path)

func _on_asset_drop(path: String, target_node_id: String, design_position: Vector2) -> void:
	if document == null:
		return
	path = _normalize_asset_path(path)
	if path.is_empty():
		return
	var node_id := target_node_id
	if (node_id.is_empty() or node_id == str(document.root().get("id", "root"))) and not canvas.selected_ids.is_empty() and not document.find_node(canvas.selected_ids[0]).is_empty():
		node_id = canvas.selected_ids[0]
	if _apply_asset_to_node(path, node_id):
		return
	var extension := path.get_extension().to_lower()
	if extension not in ["png", "jpg", "jpeg", "webp", "svg"]:
		status_label.text = "Drop ignored: %s is not a placeable visual asset" % path.get_file()
		return
	var root_id := str(document.root().get("id", "root"))
	var placement_parent_id := root_id
	var target_node := document.find_node(target_node_id)
	if not target_node.is_empty() and target_node_id != root_id and UIForgeParentability.can_contain_children(target_node, _custom_components()):
		placement_parent_id = target_node_id
	elif (target_node_id.is_empty() or target_node_id == root_id) and not canvas.selected_ids.is_empty():
		var selected_parent := document.find_node(canvas.selected_ids[0])
		if not selected_parent.is_empty() and UIForgeParentability.can_contain_children(selected_parent, _custom_components()):
			placement_parent_id = canvas.selected_ids[0]
	var base_id := "texture_%s" % path.get_file().get_basename().to_snake_case()
	var candidate := base_id
	var suffix := 2
	while not document.find_node(candidate).is_empty():
		candidate = "%s_%d" % [base_id, suffix]
		suffix += 1
	var size := Vector2(128, 128)
	var texture := load(path) as Texture2D
	if texture != null and texture.get_size().x > 0 and texture.get_size().y > 0:
		var source_size := texture.get_size()
		var scale := min(256.0 / max(source_size.x, source_size.y), 1.0)
		size = source_size * scale
	var node := {"id": candidate, "type": "Texture", "layout": {"position": [design_position.x, design_position.y], "size": [size.x, size.y]}, "properties": {"texture": path, "stretch_mode": 5}}
	var before := document.data.duplicate(true)
	var added := document.add_child_checked(placement_parent_id, node, _custom_components())
	if added.get("ok", false):
		_record_document_change("Place asset", before)
		canvas.select_node(candidate)
		_refresh_tree()
		_reconcile_editor_state()

func _selected_node() -> Dictionary:
	if document == null or canvas == null or canvas.selected_ids.is_empty():
		return {}
	return document.find_node(canvas.selected_ids[0])

func _duplicate_selected() -> void:
	if canvas == null or canvas.selected_ids.is_empty() or document == null:
		return
	_on_canvas_duplicate(canvas.selected_ids[0])

func _delete_selected() -> void:
	if canvas == null or canvas.selected_ids.is_empty():
		return
	_on_canvas_delete(canvas.selected_ids[0])

func _move_selected_up() -> void:
	_move_selected_by(-1)

func _move_selected_down() -> void:
	_move_selected_by(1)

func _move_selected_by(delta: int) -> void:
	if document == null or canvas.selected_ids.is_empty():
		return
	var node_id := canvas.selected_ids[0]
	var node := document.find_node(node_id)
	if UIForgeEditorLock.blocks_structural_mutation(node):
		status_label.text = "Node is editor-locked"
		return
	var parent := document.find_parent(node_id)
	if parent.is_empty() or UIForgeEditorLock.blocks_child_list_mutation(parent):
		status_label.text = "Parent container is editor-locked"
		return
	var children: Array = parent.get("children", [])
	var current_index := -1
	for index in children.size():
		if str(children[index].get("id", "")) == node_id:
			current_index = index
			break
	var target_index := current_index + delta
	if current_index < 0 or target_index < 0 or target_index >= children.size():
		return
	var before := document.data.duplicate(true)
	if document.move_node(node_id, str(parent.get("id", "")), target_index):
		_record_document_change("Reorder UI node", before)
		_refresh_tree()
		_reconcile_editor_state()

func _toggle_selected_visibility() -> void:
	var node := _selected_node()
	if node.is_empty():
		return
	var before := document.data.duplicate(true)
	var properties: Dictionary = node.get("properties", {})
	properties["visible"] = not bool(properties.get("visible", true))
	node["properties"] = properties
	_record_document_change("Toggle UI visibility", before)
	_refresh_tree()
	canvas.queue_redraw()
	_reconcile_editor_state()

func _toggle_selected_lock() -> void:
	var node := _selected_node()
	if node.is_empty():
		return
	var before := document.data.duplicate(true)
	var metadata: Dictionary = node.get("metadata", {})
	metadata["editor_locked"] = not bool(metadata.get("editor_locked", false))
	node["metadata"] = metadata
	_record_document_change("Toggle UI lock", before)
	_refresh_tree()
	_reconcile_editor_state()

func _apply_asset_to_selection(path: String) -> void:
	path = _normalize_asset_path(path)
	var node_id := str(canvas.selected_ids[0]) if not canvas.selected_ids.is_empty() else ""
	if not _apply_asset_to_node(path, node_id):
		status_label.text = "Drag %s onto the canvas to place it" % path.get_file()

func _apply_asset_to_node(path: String, node_id: String) -> bool:
	if node_id.is_empty() or document == null:
		return false
	var node := document.find_node(node_id)
	if node.is_empty():
		return false
	var extension := path.get_extension().to_lower()
	var before := document.data.duplicate(true)
	var properties: Dictionary = node.get("properties", {})
	var node_type := str(node.get("type", ""))
	if extension in ["png", "jpg", "jpeg", "webp", "svg"] and node_type in ["Texture", "TextureRect", "NinePatchRect", "IconButton", "TextureButton"]:
		properties["texture"] = path
	elif extension in ["png", "jpg", "jpeg", "webp", "svg"] and node_type in ["Button", "CheckBox", "CheckButton", "LinkButton", "PrimaryButton", "SecondaryButton", "TabButton", "QuestEntry", "SidebarEntry"]:
		properties["icon"] = path
	elif extension in ["ttf", "otf"] and node_type in ["Label", "RichText", "Button", "CheckBox", "CheckButton", "MenuButton", "LinkButton", "LineEdit", "TextEdit", "PrimaryButton", "SecondaryButton", "TabButton", "QuestEntry", "SidebarEntry"]:
		properties["font"] = path
	elif extension in ["tres", "res", "material"]:
		properties["material"] = path
	else:
		return false
	node["properties"] = properties
	_record_document_change("Assign asset", before)
	canvas.queue_redraw()
	_update_inspector()
	_reconcile_editor_state()
	return true

func _normalize_asset_path(path: String) -> String:
	if path.begins_with("res://"):
		return path
	if path.is_absolute_path():
		var project_root := ProjectSettings.globalize_path("res://").replace("\\", "/").trim_suffix("/")
		var normalized := path.replace("\\", "/")
		if normalized.begins_with(project_root + "/"):
			return "res://" + normalized.substr(project_root.length() + 1)
	return ""

func _build_file_dialog() -> void:
	file_dialog = FileDialog.new()
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.add_filter("*.ui.json", "UIForge documents")
	file_dialog.file_selected.connect(_on_file_selected)
	add_child(file_dialog)

func _build_unsaved_dialog() -> void:
	unsaved_dialog = ConfirmationDialog.new()
	unsaved_dialog.title = "Unsaved UIForge changes"
	unsaved_dialog.confirmed.connect(_on_discard_confirmed)
	add_child(unsaved_dialog)

func _request_discard(action: String, path: String = "") -> void:
	if not editor_session.is_dirty(document):
		if action == "new":
			_create_new_document()
		elif action == "open_dialog":
			_show_open_dialog()
		elif action == "open_path":
			_load_document_path(path)
		return
	pending_discard_action = action
	pending_discard_path = path
	unsaved_dialog.dialog_text = "Discard unsaved changes to %s?" % (document.document_name() if document != null else "this document")
	unsaved_dialog.popup_centered(Vector2i(420, 160))

func _on_discard_confirmed() -> void:
	var action := pending_discard_action
	var path := pending_discard_path
	pending_discard_action = ""
	pending_discard_path = ""
	if action == "new":
		_create_new_document()
	elif action == "open_dialog":
		_show_open_dialog()
	elif action == "open_path":
		_load_document_path(path)

func _show_open_dialog() -> void:
	dialog_mode = "open"
	file_dialog.clear_filters()
	file_dialog.add_filter("*.ui.json", "UIForge documents")
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	file_dialog.popup_centered_ratio(0.7)

func _load_document_path(path: String) -> void:
	var loaded := UIForgeSerializer.load_document(path)
	if loaded.get("document") == null:
		_show_diagnostics(loaded.get("errors", []))
		return
	set_document(loaded["document"], path, str(loaded.get("revision_hash", "")))
	status_label.text = "Opened %s" % path.get_file()

func set_document(value: UIForgeDocument, path: String = "", loaded_disk_revision: String = "") -> void:
	document = value
	document_path = path
	editor_session.reset_for_document(document, loaded_disk_revision, not path.is_empty())
	if canvas != null:
		canvas.set_document(document)
		canvas.studio = self
		canvas.set_editor_undo_redo(editor_undo_redo)
		_set_preview_size(document.viewport_size())
	if theme_select != null:
		var current_theme := str(document.data.get("theme", "dark_fantasy"))
		for index in theme_select.item_count:
			if theme_select.get_item_text(index) == current_theme:
				theme_select.select(index)
				break
	_sync_reference_controls()
	_refresh_tree()
	_update_inspector()
	_reconcile_editor_state()

func _refresh_tree() -> void:
	if tree == null or document == null:
		return
	synchronizing_selection = true
	tree.clear()
	var root_item := tree.create_item()
	_add_tree_node(root_item, document.root())
	if not canvas.selected_ids.is_empty():
		_select_tree_id(root_item, canvas.selected_ids[0])
	synchronizing_selection = false

func _add_tree_node(parent_item: TreeItem, node: Dictionary) -> void:
	var item := parent_item.create_child()
	var properties: Dictionary = node.get("properties", {})
	var metadata: Dictionary = node.get("metadata", {})
	var visibility_marker := "" if bool(properties.get("visible", true)) else "  · HIDDEN"
	var lock_marker := "  · LOCKED" if bool(metadata.get("editor_locked", false)) else ""
	item.set_text(0, "%s  [%s]%s%s" % [str(node.get("id", "")), str(node.get("type", "Control")), visibility_marker, lock_marker])
	item.set_tooltip_text(0, "Stable id: %s" % str(node.get("id", "")))
	item.set_metadata(0, str(node.get("id", "")))
	for child in node.get("children", []):
		if child is Dictionary:
			_add_tree_node(item, child)

func _select_tree_id(item: TreeItem, node_id: String) -> bool:
	if str(item.get_metadata(0)) == node_id:
		item.select(0)
		return true
	for child in item.get_children():
		if _select_tree_id(child, node_id):
			item.set_collapsed(false)
			return true
	return false

func _on_tree_selected() -> void:
	if synchronizing_selection:
		return
	var item := tree.get_selected()
	if item != null:
		canvas.select_node(str(item.get_metadata(0)))
		_update_inspector()

func _on_tree_node_drop(node_id: String, parent_id: String) -> void:
	if document == null or node_id.is_empty() or parent_id.is_empty() or node_id == parent_id:
		return
	var moving := document.find_node(node_id)
	if UIForgeEditorLock.blocks_structural_mutation(moving):
		status_label.text = "Node is editor-locked"
		return
	var parent := document.find_node(parent_id)
	if parent.is_empty():
		return
	if UIForgeEditorLock.blocks_child_list_mutation(parent):
		status_label.text = "Parent container is editor-locked"
		return
	var parent_error := UIForgeParentability.assert_can_accept_child(parent_id, parent, _custom_components(), node_id)
	if not parent_error.is_empty():
		_show_diagnostics([parent_error])
		return
	var before := document.data.duplicate(true)
	if not document.move_node(node_id, parent_id):
		return
	_record_document_change("Reparent UI node", before)
	canvas.select_node(node_id)
	_refresh_tree()
	_reconcile_editor_state()

func _record_document_change(action_name: String, before: Dictionary) -> void:
	var before_snapshot := before.duplicate(true)
	var after_snapshot := document.data.duplicate(true)
	var session_id := editor_session.current_session_id()
	if editor_undo_redo == null:
		_notify_document_changed()
		_reconcile_editor_state()
		return
	editor_undo_redo.create_action(action_name)
	editor_undo_redo.add_do_method(self, "reconcile_document_snapshot", after_snapshot, session_id)
	editor_undo_redo.add_undo_method(self, "reconcile_document_snapshot", before_snapshot, session_id)
	editor_undo_redo.commit_action()
	_notify_document_changed()
	_reconcile_editor_state()

func _apply_document_snapshot(snapshot: Dictionary) -> void:
	reconcile_document_snapshot(snapshot, editor_session.current_session_id())

func _on_canvas_selected(_node_id: String) -> void:
	if synchronizing_selection:
		return
	_refresh_tree()
	_update_inspector()

func _on_canvas_changed(_node_id: String) -> void:
	_notify_document_changed()
	_refresh_tree()
	_reconcile_editor_state()

func _update_inspector() -> void:
	if property_inspector == null:
		return
	if canvas == null or canvas.selected_ids.is_empty() or document == null:
		property_inspector.clear_node()
		return
	var node := document.find_node(canvas.selected_ids[0])
	if node.is_empty():
		property_inspector.clear_node()
		return
	property_inspector.set_node(node)

func _on_inspector_apply(changes: Dictionary) -> void:
	if document == null or canvas.selected_ids.is_empty():
		return
	var node_id := canvas.selected_ids[0]
	var node := document.find_node(node_id)
	if node.is_empty():
		return
	var before := node.duplicate(true)
	for path in changes:
		var value: Variant = changes[path]
		if str(path).begins_with(UIForgePropertyInspector.NATIVE_PREFIX):
			var native_name := str(path).trim_prefix(UIForgePropertyInspector.NATIVE_PREFIX)
			var properties: Dictionary = node.get("properties", {})
			var overrides: Dictionary = properties.get("godot_overrides", {})
			if not overrides is Dictionary:
				overrides = {}
			overrides[native_name] = value
			properties["godot_overrides"] = overrides
			node["properties"] = properties
		elif path in ["action", "binding"] and str(value).strip_edges().is_empty():
			node.erase(path)
		elif path == "properties.texture_region" and value == null:
			node.get("properties", {}).erase("texture_region")
		else:
			document.set_property(node_id, str(path), value)
	if editor_undo_redo != null:
		var after := node.duplicate(true)
		var session_id := editor_session.current_session_id()
		editor_undo_redo.create_action("UIForge property change")
		editor_undo_redo.add_do_method(self, "reconcile_node_snapshot", node_id, after.duplicate(true), session_id)
		editor_undo_redo.add_undo_method(self, "reconcile_node_snapshot", node_id, before.duplicate(true), session_id)
		editor_undo_redo.commit_action()
	_refresh_tree()
	canvas.queue_redraw()
	_update_inspector()
	_reconcile_editor_state()

func _replace_node(node_id: String, value: Dictionary) -> void:
	var target := document.find_node(node_id)
	if not target.is_empty():
		target.clear()
		target.merge(value, true)
		_notify_document_changed()
		canvas.queue_redraw()
		_update_inspector()

func _apply_node_snapshot(node_id: String, value: Dictionary) -> void:
	reconcile_node_snapshot(node_id, value, editor_session.current_session_id())

func _on_new() -> void:
	_request_discard("new")

func _create_new_document() -> void:
	if template_dialog == null:
		template_dialog = ConfirmationDialog.new()
		template_dialog.title = "New UI from template"
		template_dialog.ok_button_text = "Create"
		template_select = OptionButton.new()
		template_select.custom_minimum_size = Vector2(400, 40)
		template_select.add_item("Blank window")
		template_select.set_item_metadata(0, "blank")
		var entries := UIForgeTemplates.catalog()
		for key in entries:
			template_select.add_item(str(entries[key].title))
			template_select.set_item_metadata(template_select.item_count - 1, key)
		template_dialog.add_child(template_select)
		template_dialog.confirmed.connect(_create_selected_template)
		add_child(template_dialog)
	template_dialog.popup_centered(Vector2i(440, 130))

func _create_selected_template() -> void:
	var key := str(template_select.get_selected_metadata())
	var created := UIForgeTemplates.create(key, "untitled" if key == "blank" else key)
	if created.get("document") == null:
		_show_diagnostics(created.errors)
		return
	set_document(created.document, "")
	status_label.text = "New %s document · choose Save to create the source file" % key
	_reconcile_editor_state()

func _on_open() -> void:
	_request_discard("open_dialog")

func _on_save() -> void:
	if document_path.is_empty():
		dialog_mode = "save"
		file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
		file_dialog.popup_centered_ratio(0.7)
		return
	var expected_revision := editor_session.disk_revision if not editor_session.disk_revision.is_empty() else ""
	var result := UIForgeSerializer.save_document(document, document_path, expected_revision)
	if result.get("success", false):
		var saved_revision := UIForgeHash.file_revision(document_path)
		editor_session.on_successful_save(document, str(saved_revision.get("hash", "")))
		_reconcile_editor_state()
	else:
		_show_diagnostics(result.get("errors", []))
		if not expected_revision.is_empty():
			status_label.text = "Save blocked: source changed externally · reload to continue on the newer revision"
		_reconcile_editor_state()

func _on_file_selected(path: String) -> void:
	if dialog_mode == "reference":
		if document != null:
			var before := document.data.duplicate(true)
			document.data["reference"] = {"path": path, "opacity": 0.28, "scale": 1.0, "position": [0, 0], "visible": true, "locked": true}
			_record_document_change("Set UIForge reference", before)
			canvas.set_document(document)
			_sync_reference_controls()
			_reconcile_editor_state()
		return
	if dialog_mode == "save":
		var result := UIForgeSerializer.save_document(document, path)
		if result.get("success", false):
			document_path = path
			var saved_revision := UIForgeHash.file_revision(path)
			editor_session.on_successful_save(document, str(saved_revision.get("hash", "")))
			_reconcile_editor_state()
		else:
			_show_diagnostics(result.get("errors", []))
		return
	if editor_session.is_dirty(document):
		_request_discard("open_path", path)
		return
	_load_document_path(path)

func _on_validate() -> void:
	if document == null:
		return
	var result := UIForgeValidator.new().validate(document)
	_show_diagnostics(result.diagnostics)
	status_label.text = "Validation: %d errors · %d warnings" % [result.errors, result.warnings]

func _on_build() -> void:
	if document == null:
		return
	var validation := UIForgeValidator.new().validate(document)
	_show_diagnostics(validation.diagnostics)
	if not validation.success:
		status_label.text = "Build blocked by validation errors"
		return
	var output := ""
	if not document_path.is_empty():
		output = "%s.tscn" % document_path.trim_suffix(".ui.json")
	else:
		output = "user://%s.tscn" % document.document_name()
	var result := UIForgeCompiler.new().compile_document(document, output, document_path)
	if result.success:
		status_label.text = "Built %s" % output
	else:
		_show_diagnostics(result.errors)

func _on_preview() -> void:
	if document == null:
		return
	if is_instance_valid(preview_window):
		preview_window.queue_free()
		preview_window = null
		return
	var validation := UIForgeValidator.new().validate(document)
	_show_diagnostics(validation.diagnostics)
	if not validation.success:
		status_label.text = "Preview blocked by validation errors"
		return
	var state := str(state_select.get_selected_metadata()) if state_select != null else "normal"
	var preview_document := UIForgeCompiler.document_for_preview_state(document, state)
	var preview_path := "user://uiforge_preview_%s.tscn" % document.document_name()
	var result := UIForgeCompiler.new().compile_document(preview_document, preview_path, document_path)
	if not result.success:
		_show_diagnostics(result.errors)
		return
	var packed := load(preview_path) as PackedScene
	if packed == null:
		_show_diagnostics([{"severity": "error", "code": "PREVIEW_SCENE_LOAD_FAILED", "message": preview_path, "node": ""}])
		return
	preview_window = Window.new()
	preview_window.title = "UIForge Preview · %s" % document.document_name()
	preview_window.size = canvas.viewport_preview
	preview_window.min_size = Vector2i(640, 360)
	preview_window.transient = true
	preview_window.exclusive = false
	var preview_root := packed.instantiate()
	preview_root.set_meta("uiforge_preview", true)
	var design_size := Vector2(preview_document.viewport_size())
	var viewport_data: Dictionary = preview_document.data.get("viewport", {})
	var scale_mode := str(viewport_data.get("scale_mode", "fit"))
	if scale_mode != "fixed" and design_size.x > 0.0 and design_size.y > 0.0:
		var preview_scale := min(float(canvas.viewport_preview.x) / design_size.x, float(canvas.viewport_preview.y) / design_size.y)
		if scale_mode == "integer":
			preview_scale = max(1.0, floor(preview_scale))
		preview_root.scale = Vector2.ONE * preview_scale
	preview_window.add_child(preview_root)
	get_tree().root.add_child(preview_window)
	preview_window.close_requested.connect(_on_preview_closed)
	preview_window.popup_centered()
	status_label.text = "Preview open · click Preview again to close"

func _on_preview_closed() -> void:
	preview_window = null

func _on_fit() -> void:
	canvas.zoom_to_fit()

func _toggle_grid() -> void:
	canvas.grid_enabled = not canvas.grid_enabled
	canvas.queue_redraw()

func _toggle_snap() -> void:
	canvas.snap_enabled = not canvas.snap_enabled

func _on_reference() -> void:
	dialog_mode = "reference"
	file_dialog.clear_filters()
	file_dialog.add_filter("*.png,*.jpg,*.jpeg,*.webp,*.svg", "Reference images")
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	file_dialog.popup_centered_ratio(0.7)

func _sync_reference_controls() -> void:
	if document == null or reference_opacity == null:
		return
	var reference: Dictionary = document.data.get("reference", {})
	reference_opacity.set_value_no_signal(float(reference.get("opacity", 0.28)))
	reference_scale.set_value_no_signal(float(reference.get("scale", 1.0)))
	reference_visible.set_pressed_no_signal(bool(reference.get("visible", true)))
	reference_above.set_pressed_no_signal(bool(reference.get("above_canvas", false)))
	reference_locked.set_pressed_no_signal(bool(reference.get("locked", true)))
	var position: Array = reference.get("position", [0, 0])
	reference_position.text = "%s, %s" % [position[0], position[1]] if position.size() >= 2 else "0, 0"

func _on_reference_control_changed(_value: Variant = null) -> void:
	if document == null or reference_opacity == null:
		return
	var reference: Dictionary = document.data.get("reference", {})
	if reference.is_empty():
		return
	var before := document.data.duplicate(true)
	reference["opacity"] = reference_opacity.value
	reference["scale"] = reference_scale.value
	reference["visible"] = reference_visible.button_pressed
	reference["above_canvas"] = reference_above.button_pressed
	reference["locked"] = reference_locked.button_pressed
	reference["position"] = _parse_pair_text(reference_position.text, reference.get("position", [0, 0]))
	document.data["reference"] = reference
	_record_document_change("Edit UIForge reference", before)
	canvas.refresh_reference()
	_reconcile_editor_state()

func _parse_pair_text(value: String, fallback: Array) -> Array:
	var pieces := value.replace("[", "").replace("]", "").split(",")
	if pieces.size() < 2:
		return fallback
	return [float(pieces[0].strip_edges()), float(pieces[1].strip_edges())]

func _on_state_selected(index: int) -> void:
	var state := str(state_select.get_item_metadata(index))
	canvas.set_preview_state(state)
	_update_inspector()

func _on_viewport_selected(index: int) -> void:
	var selected: Vector2i = viewport_select.get_item_metadata(index)
	canvas.set_viewport_preview(selected)

func _open_custom_viewport() -> void:
	if custom_viewport_dialog == null:
		custom_viewport_dialog = ConfirmationDialog.new()
		custom_viewport_dialog.title = "Custom viewport preview"
		custom_viewport_dialog.confirmed.connect(_apply_custom_viewport)
		var body := VBoxContainer.new()
		var width_label := Label.new()
		width_label.text = "Width"
		body.add_child(width_label)
		custom_viewport_width = SpinBox.new()
		custom_viewport_width.min_value = 320
		custom_viewport_width.max_value = 8192
		custom_viewport_width.step = 1
		body.add_child(custom_viewport_width)
		var height_label := Label.new()
		height_label.text = "Height"
		body.add_child(height_label)
		custom_viewport_height = SpinBox.new()
		custom_viewport_height.min_value = 240
		custom_viewport_height.max_value = 8192
		custom_viewport_height.step = 1
		body.add_child(custom_viewport_height)
		custom_viewport_dialog.add_child(body)
		add_child(custom_viewport_dialog)
	var current := canvas.viewport_preview
	custom_viewport_width.value = current.x
	custom_viewport_height.value = current.y
	custom_viewport_dialog.popup_centered(Vector2i(280, 190))

func _apply_custom_viewport() -> void:
	if canvas == null or custom_viewport_width == null or custom_viewport_height == null:
		return
	_set_preview_size(Vector2i(int(custom_viewport_width.value), int(custom_viewport_height.value)))

func _set_preview_size(value: Vector2i) -> void:
	canvas.set_viewport_preview(value)
	if viewport_select == null:
		return
	for index in viewport_select.item_count:
		if viewport_select.get_item_metadata(index) == value:
			viewport_select.select(index)
			return
	viewport_select.add_item("%dx%d" % [value.x, value.y])
	viewport_select.set_item_metadata(viewport_select.item_count - 1, value)
	viewport_select.select(viewport_select.item_count - 1)
	_update_status()

func _on_theme_selected(index: int) -> void:
	if document == null or theme_select == null:
		return
	var before := document.data.duplicate(true)
	document.data["theme"] = str(theme_select.get_item_text(index))
	_record_document_change("Change UIForge theme", before)
	canvas.set_document(document)
	_reconcile_editor_state()

func _on_nine_slice_style_save(style_name: String, payload: Dictionary) -> void:
	if document == null:
		return
	var before := document.data.duplicate(true)
	var overrides: Dictionary = document.data.get("theme_overrides", {})
	var styles: Dictionary = overrides.get("styles", {})
	styles[style_name] = payload.duplicate(true)
	overrides["styles"] = styles
	document.data["theme_overrides"] = overrides
	_record_document_change("Save nine-slice style", before)
	canvas.set_document(document)
	_reconcile_editor_state()

func _add_selected_component() -> void:
	if component_list == null or component_list.get_selected_items().is_empty():
		return
	_on_component_activated(component_list.get_selected_items()[0])

func _on_component_activated(index: int) -> void:
	if document == null:
		return
	var component_name := str(component_list.get_item_metadata(index))
	var parent_id := str(document.root().get("id", ""))
	if not canvas.selected_ids.is_empty() and not document.find_node(canvas.selected_ids[0]).is_empty():
		var selected_parent := document.find_node(canvas.selected_ids[0])
		if UIForgeParentability.can_contain_children(selected_parent, _custom_components()):
			parent_id = canvas.selected_ids[0]
	var base_id := component_name.to_snake_case()
	var candidate := base_id
	var suffix := 2
	while not document.find_node(candidate).is_empty():
		candidate = "%s_%d" % [base_id, suffix]
		suffix += 1
	var node := {"id": candidate, "type": component_name, "layout": {"position": [24, 24], "size": [240, 64]}, "properties": {}}
	if component_name in ["PrimaryButton", "SecondaryButton", "TabButton", "QuestEntry", "SidebarEntry"]:
		node["properties"]["text"] = component_name.replace("Button", "").replace("Entry", "")
	if component_name == "SearchBox":
		node["properties"]["placeholder"] = "Search"
	var parent := document.find_node(parent_id)
	var parent_error := UIForgeParentability.assert_can_accept_child(parent_id, parent, _custom_components(), candidate)
	if not parent_error.is_empty():
		_show_diagnostics([parent_error])
		return
	var before := document.data.duplicate(true)
	var added := document.add_child_checked(parent_id, node, _custom_components())
	if not added.get("ok", false):
		return
	_record_document_change("Add UIForge component", before)
	canvas.select_node(candidate)
	_refresh_tree()
	_reconcile_editor_state()

func _on_canvas_delete(node_id: String) -> void:
	if document == null or node_id == str(document.root().get("id", "")):
		return
	var node := document.find_node(node_id)
	if UIForgeEditorLock.blocks_structural_mutation(node):
		status_label.text = "Node is editor-locked"
		return
	var before := document.data.duplicate(true)
	var removed := document.delete_node(node_id)
	if not removed.is_empty():
		_record_document_change("Delete UI node", before)
		canvas.select_node("")
		_refresh_tree()
		_reconcile_editor_state()

func _on_canvas_duplicate(node_id: String) -> void:
	if document == null:
		return
	var original := document.find_node(node_id)
	if UIForgeEditorLock.blocks_structural_mutation(original):
		status_label.text = "Node is editor-locked"
		return
	var before := document.data.duplicate(true)
	var candidate := "%s_copy" % node_id
	var suffix := 2
	while not document.find_node(candidate).is_empty():
		candidate = "%s_%d" % [node_id, suffix]
		suffix += 1
	var copy := document.duplicate_node(node_id, candidate)
	if not copy.is_empty():
		_record_document_change("Duplicate UI node", before)
		canvas.select_node(candidate)
		_refresh_tree()
		_reconcile_editor_state()

func _on_canvas_copy(node_ids: Array[String]) -> void:
	clipboard_nodes.clear()
	if document == null:
		return
	for node_id in node_ids:
		var node := document.find_node(node_id)
		if not node.is_empty():
			clipboard_nodes.append(node.duplicate(true))
	if not clipboard_nodes.is_empty():
		DisplayServer.clipboard_set(JSON.stringify(clipboard_nodes))
		status_label.text = "Copied %d node(s)" % clipboard_nodes.size()

func _on_canvas_paste() -> void:
	if document == null:
		return
	var nodes := clipboard_nodes.duplicate(true)
	if nodes.is_empty():
		var external := DisplayServer.clipboard_get()
		var parsed: Variant = JSON.parse_string(external)
		if parsed is Array:
			nodes = parsed
	if nodes.is_empty():
		return
	var parent_id := str(document.root().get("id", ""))
	if not canvas.selected_ids.is_empty():
		var selected_parent := document.find_node(canvas.selected_ids[0])
		if not selected_parent.is_empty() and UIForgeParentability.can_contain_children(selected_parent, _custom_components()):
			parent_id = canvas.selected_ids[0]
	var parent := document.find_node(parent_id)
	if UIForgeEditorLock.blocks_child_list_mutation(parent):
		status_label.text = "Parent container is editor-locked"
		return
	var parent_error := UIForgeParentability.assert_can_accept_child(parent_id, parent, _custom_components())
	if not parent_error.is_empty():
		_show_diagnostics([parent_error])
		return
	var before := document.data.duplicate(true)
	var reserved := UIForgeSubtreeOps.collect_document_ids(document)
	var pasted_ids: Array[String] = []
	for original in nodes:
		if not original is Dictionary:
			continue
		var base_id := "%s_copy" % str(original.get("id", "node"))
		var planned := UIForgeSubtreeOps.clone_subtree(original, base_id, reserved)
		if not planned.get("ok", false):
			_show_diagnostics(planned.get("errors", []))
			return
		var copy: Dictionary = planned["node"]
		reserved[str(planned.get("root_id", ""))] = true
		for mapped_id in planned.get("id_map", {}).values():
			reserved[str(mapped_id)] = true
		if not document.add_child(parent_id, copy):
			return
		pasted_ids.append(str(planned.get("root_id", "")))
	if pasted_ids.is_empty():
		return
	_record_document_change("Paste UI nodes", before)
	canvas.selected_ids = pasted_ids
	_refresh_tree()
	_update_inspector()
	_reconcile_editor_state()

func _show_diagnostics(items: Array) -> void:
	if diagnostics_view == null:
		return
	diagnostics_view.clear()
	if items.is_empty():
		diagnostics_view.append_text("[color=#8dbb7d]✓ No diagnostics[/color]")
		return
	for item in items:
		var color := "#d87973" if str(item.get("severity", "error")) == "error" else "#e0b86e"
		diagnostics_view.append_text("[color=%s][b]%s[/b][/color] %s  [color=#8d97a7](%s)[/color]\n" % [color, str(item.get("code", "")), str(item.get("message", "")), str(item.get("node", ""))])

func _update_status() -> void:
	if status_label == null:
		return
	var marker := "*" if dirty else ""
	status_label.text = "%s%s  ·  %s" % [marker, document.document_name() if document != null else "untitled", document_path if not document_path.is_empty() else "unsaved"]
