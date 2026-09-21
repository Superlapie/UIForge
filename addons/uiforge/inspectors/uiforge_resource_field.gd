@tool
class_name UIForgeResourceField
extends LineEdit

signal resource_dropped(path: String)

func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	return _asset_path(data) != ""

func _drop_data(_at_position: Vector2, data: Variant) -> void:
	var path := _asset_path(data)
	if path.is_empty():
		return
	text = path
	resource_dropped.emit(path)

func _asset_path(data: Variant) -> String:
	if data is Dictionary:
		var path := str(data.get("uiforge_asset_path", data.get("aether_asset_path", data.get("resource_path", ""))))
		if path.is_empty() and data.has("files"):
			var files: Variant = data.get("files")
			if files is Array or files is PackedStringArray:
				if files.size() > 0:
					path = str(files[0])
			return path
		return path
	if data is String and (str(data).begins_with("res://") or str(data).is_absolute_path()):
		return str(data)
	return ""
