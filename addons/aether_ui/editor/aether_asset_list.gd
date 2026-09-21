@tool
class_name AetherAssetList
extends ItemList

func _get_drag_data(at_position: Vector2) -> Variant:
	var index := get_item_at_position(at_position, true)
	if index < 0 or index >= item_count:
		return null
	var path := str(get_item_metadata(index))
	if path.is_empty() or not path.begins_with("res://"):
		return null
	var preview := Label.new()
	preview.text = path.get_file()
	preview.add_theme_color_override("font_color", Color("c9a96a"))
	set_drag_preview(preview)
	return {"aether_asset_path": path, "aether_asset_kind": path.get_extension().to_lower()}
