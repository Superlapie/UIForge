@tool
class_name UIForgeHierarchyTree
extends Tree

signal node_drop_requested(node_id: String, parent_id: String)

func _get_drag_data(at_position: Vector2) -> Variant:
	var item := get_item_at_position(at_position)
	if item == null:
		return null
	var node_id := str(item.get_metadata(0))
	if node_id.is_empty():
		return null
	var preview := Label.new()
	preview.text = str(item.get_text(0))
	preview.add_theme_color_override("font_color", Color("c9a96a"))
	set_drag_preview(preview)
	return {"uiforge_node_id": node_id}

func _can_drop_data(at_position: Vector2, data: Variant) -> bool:
	if not data is Dictionary:
		return false
	var dragged_id := str(data.get("uiforge_node_id", data.get("aether_node_id", "")))
	if dragged_id.is_empty():
		return false
	var target := get_item_at_position(at_position)
	return target != null and not str(target.get_metadata(0)).is_empty()

func _drop_data(at_position: Vector2, data: Variant) -> void:
	if not data is Dictionary:
		return
	var target := get_item_at_position(at_position)
	if target == null:
		return
	var dragged_id := str(data.get("uiforge_node_id", data.get("aether_node_id", "")))
	node_drop_requested.emit(dragged_id, str(target.get_metadata(0)))
