class_name UIForgeDocument
extends RefCounted

var data: Dictionary = {}
var source_path: String = ""

func _init(initial_data: Dictionary = {}) -> void:
	data = initial_data.duplicate(true)
	if not data.has("schema_version"):
		data["schema_version"] = UIForgeTypes.SCHEMA_VERSION
	if not data.has("metadata"):
		data["metadata"] = {}

static func from_dict(value: Dictionary, path: String = "") -> UIForgeDocument:
	var document := UIForgeDocument.new(value)
	document.source_path = path
	return document

func to_dict() -> Dictionary:
	return data.duplicate(true)

func document_name() -> String:
	return str(data.get("name", "untitled"))

func viewport_size() -> Vector2i:
	var viewport: Dictionary = data.get("viewport", {})
	return Vector2i(int(viewport.get("width", 1920)), int(viewport.get("height", 1080)))

func root() -> Dictionary:
	var value: Variant = data.get("root", {})
	return value if value is Dictionary else {}

func set_root(value: Dictionary) -> void:
	data["root"] = value

func find_node(node_id: String) -> Dictionary:
	return _find_node_recursive(root(), node_id)

func find_parent(node_id: String) -> Dictionary:
	return _find_parent_recursive(root(), node_id)

func find_node_path(node_id: String) -> Array[String]:
	var result: Array[String] = []
	_find_path(root(), node_id, [], result)
	return result

func all_nodes() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	_collect_nodes(root(), result)
	return result

func set_property(node_id: String, property_path: String, value: Variant) -> bool:
	var node := find_node(node_id)
	if node.is_empty():
		return false
	return _set_path(node, property_path.split("."), value)

func get_property(node_id: String, property_path: String = "") -> Variant:
	var node := find_node(node_id)
	if node.is_empty():
		return null
	if property_path.is_empty():
		return node.duplicate(true)
	return _get_path(node, property_path.split("."))

func add_child(parent_id: String, node: Dictionary, index: int = -1) -> bool:
	var parent := find_node(parent_id)
	if parent.is_empty():
		return false
	if not parent.has("children") or not parent["children"] is Array:
		parent["children"] = []
	var children: Array = parent["children"]
	if index < 0 or index >= children.size():
		children.append(node)
	else:
		children.insert(index, node)
	return true

func delete_node(node_id: String) -> Dictionary:
	if str(root().get("id", "")) == node_id:
		return {}
	var parent := find_parent(node_id)
	if parent.is_empty():
		return {}
	var children: Array = parent.get("children", [])
	for index in children.size():
		if str(children[index].get("id", "")) == node_id:
			var removed: Dictionary = children[index]
			children.remove_at(index)
			return removed
	return {}

func move_node(node_id: String, new_parent_id: String, index: int = -1) -> bool:
	var moving := find_node(node_id)
	if moving.is_empty() or node_id == new_parent_id or _contains_id(moving, new_parent_id):
		return false
	var old_parent := find_parent(node_id)
	var old_index := -1
	var old_children: Array = old_parent.get("children", []) if not old_parent.is_empty() else []
	for candidate_index in old_children.size():
		if str(old_children[candidate_index].get("id", "")) == node_id:
			old_index = candidate_index
			break
	var node := delete_node(node_id)
	if node.is_empty():
		return false
	if not add_child(new_parent_id, node, index):
		if not old_parent.is_empty():
			var restored_children: Array = old_parent.get("children", [])
			if old_index < 0:
				restored_children.append(node)
			else:
				restored_children.insert(old_index, node)
		return false
	return true

func duplicate_node(node_id: String, new_id: String) -> Dictionary:
	var original := find_node(node_id)
	if original.is_empty() or not find_parent(node_id):
		return {}
	var copy: Dictionary = original.duplicate(true)
	_set_ids(copy, new_id)
	var parent := find_parent(node_id)
	var children: Array = parent.get("children", [])
	for index in children.size():
		if str(children[index].get("id", "")) == node_id:
			children.insert(index + 1, copy)
			return copy
	return {}

func _set_ids(node: Dictionary, base_id: String) -> void:
	node["id"] = base_id
	var children: Array = node.get("children", [])
	for index in children.size():
		var child: Dictionary = children[index]
		_set_ids(child, "%s_%d" % [base_id, index + 1])

func _walk(node: Dictionary, callback: Callable, parent: Dictionary = {}, index: int = -1) -> void:
	if node.is_empty():
		return
	callback.call(node, parent, index)
	var children: Array = node.get("children", [])
	for child_index in children.size():
		if children[child_index] is Dictionary:
			_walk(children[child_index], callback, node, child_index)

func _find_node_recursive(node: Dictionary, node_id: String) -> Dictionary:
	if node.is_empty():
		return {}
	if str(node.get("id", "")) == node_id:
		return node
	for child in node.get("children", []):
		if child is Dictionary:
			var found := _find_node_recursive(child, node_id)
			if not found.is_empty():
				return found
	return {}

func _find_parent_recursive(node: Dictionary, node_id: String) -> Dictionary:
	if node.is_empty():
		return {}
	for child in node.get("children", []):
		if not child is Dictionary:
			continue
		if str(child.get("id", "")) == node_id:
			return node
		var found := _find_parent_recursive(child, node_id)
		if not found.is_empty():
			return found
	return {}

func _collect_nodes(node: Dictionary, output: Array[Dictionary]) -> void:
	if node.is_empty():
		return
	output.append(node)
	for child in node.get("children", []):
		if child is Dictionary:
			_collect_nodes(child, output)

func _contains_id(node: Dictionary, target_id: String) -> bool:
	for child in node.get("children", []):
		if child is Dictionary:
			if str(child.get("id", "")) == target_id or _contains_id(child, target_id):
				return true
	return false

func _find_path(node: Dictionary, target: String, current: Array[String], output: Array[String]) -> bool:
	if node.is_empty():
		return false
	var next := current.duplicate()
	next.append(str(node.get("id", "")))
	if str(node.get("id", "")) == target:
		output.assign(next)
		return true
	for child in node.get("children", []):
		if child is Dictionary and _find_path(child, target, next, output):
			return true
	return false

func _set_path(container: Dictionary, path: Array[String], value: Variant) -> bool:
	if path.is_empty():
		return false
	var cursor: Dictionary = container
	for index in path.size() - 1:
		var key := path[index]
		if not cursor.has(key) or not cursor[key] is Dictionary:
			cursor[key] = {}
		cursor = cursor[key]
	cursor[path[-1]] = value
	return true

func _get_path(container: Dictionary, path: Array[String]) -> Variant:
	var cursor: Variant = container
	for key in path:
		if not cursor is Dictionary or not cursor.has(key):
			return null
		cursor = cursor[key]
	return cursor
