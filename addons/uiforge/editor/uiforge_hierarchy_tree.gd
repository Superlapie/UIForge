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
	return {"aether_node_id": node_id}

func _can_drop_data(at_position: Vector2, data: Variant) -> bool:
	if not data is Dictionary or not data.has("aether_node_id"):
		return false
	var target := get_item_at_position(at_position)
	return target != null and not str(target.get_metadata(0)).is_empty()

func _drop_data(at_position: Vector2, data: Variant) -> void:
	if not data is Dictionary:
		return
	var target := get_item_at_position(at_position)
	if target == null:
		return
	node_drop_requested.emit(str(data.get("aether_node_id", "")), str(target.get_metadata(0)))
