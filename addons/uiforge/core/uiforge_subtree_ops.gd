class_name UIForgeSubtreeOps
extends RefCounted

const FOCUS_NEIGHBOR_KEYS: Array[String] = [
	"focus_neighbor_top", "focus_neighbor_bottom", "focus_neighbor_left", "focus_neighbor_right",
]

static func collect_document_ids(document: UIForgeDocument) -> Dictionary:
	var ids: Dictionary = {}
	for node in document.all_nodes():
		var node_id := str(node.get("id", ""))
		if not node_id.is_empty():
			ids[node_id] = true
	return ids

static func unique_root_id(base_id: String, reserved: Dictionary) -> String:
	var candidate := base_id
	var suffix := 2
	while reserved.has(candidate):
		candidate = "%s_%d" % [base_id, suffix]
		suffix += 1
	return candidate

static func clone_subtree(original: Dictionary, proposed_root_id: String, reserved: Dictionary) -> Dictionary:
	if original.is_empty():
		return {"ok": false, "errors": [{"code": "CLONE_EMPTY", "message": "Cannot clone an empty node."}]}
	var working_reserved := reserved.duplicate()
	var new_root_id := unique_root_id(proposed_root_id, working_reserved)
	working_reserved[new_root_id] = true
	var id_map: Dictionary = {}
	var errors: Array = []
	_build_id_map(original, new_root_id, working_reserved, id_map, errors)
	if not errors.is_empty():
		return {"ok": false, "errors": errors}
	var copy: Dictionary = original.duplicate(true)
	_apply_id_map(copy, id_map)
	rewrite_local_references(copy, id_map)
	return {"ok": true, "node": copy, "root_id": new_root_id, "id_map": id_map}

static func clone_subtrees(originals: Array, id_base_for_index: Callable, reserved: Dictionary) -> Dictionary:
	var working_reserved := reserved.duplicate()
	var clones: Array[Dictionary] = []
	var combined_map: Dictionary = {}
	for index in originals.size():
		if not originals[index] is Dictionary:
			continue
		var original: Dictionary = originals[index]
		var base_id: String = id_base_for_index.call(original, index)
		var planned := clone_subtree(original, base_id, working_reserved)
		if not planned.get("ok", false):
			return planned
		var clone: Dictionary = planned["node"]
		clones.append(clone)
		for old_id in planned.get("id_map", {}):
			combined_map[old_id] = planned["id_map"][old_id]
			working_reserved[planned["id_map"][old_id]] = true
	return {"ok": true, "nodes": clones, "id_map": combined_map}

static func duplicate_into_document(document: UIForgeDocument, node_id: String, proposed_root_id: String) -> Dictionary:
	var original := document.find_node(node_id)
	if original.is_empty() or document.find_parent(node_id).is_empty():
		return {"ok": false, "errors": [{"code": "DUPLICATE_FAILED", "node": node_id}]}
	var reserved := collect_document_ids(document)
	reserved.erase(node_id)
	var planned := clone_subtree(original, proposed_root_id, reserved)
	if not planned.get("ok", false):
		return planned
	var parent := document.find_parent(node_id)
	var children: Array = parent.get("children", [])
	for index in children.size():
		if str(children[index].get("id", "")) == node_id:
			children.insert(index + 1, planned["node"])
			return {"ok": true, "node": planned["node"], "root_id": planned["root_id"], "id_map": planned["id_map"]}
	return {"ok": false, "errors": [{"code": "DUPLICATE_FAILED", "node": node_id}]}

static func rewrite_local_references(node: Dictionary, id_map: Dictionary) -> void:
	if node.is_empty() or id_map.is_empty():
		return
	_rewrite_node_references(node, id_map)
	for child in node.get("children", []):
		if child is Dictionary:
			rewrite_local_references(child, id_map)

static func remap_node_path_reference(path: String, id_map: Dictionary) -> String:
	if path.is_empty() or id_map.is_empty():
		return path
	if id_map.has(path):
		return str(id_map[path])
	if path.begins_with("../"):
		var target := path.substr(3)
		if id_map.has(target):
			return "../%s" % id_map[target]
	if path.begins_with("./"):
		var target := path.substr(2)
		if id_map.has(target):
			return "./%s" % id_map[target]
	return path

static func _build_id_map(node: Dictionary, mapped_id: String, reserved: Dictionary, id_map: Dictionary, errors: Array) -> void:
	var old_id := str(node.get("id", ""))
	if old_id.is_empty():
		errors.append({"code": "SUBTREE_ID_MISSING", "message": "Subtree node is missing a stable id."})
		return
	id_map[old_id] = mapped_id
	var children: Array = node.get("children", [])
	for index in children.size():
		if not children[index] is Dictionary:
			continue
		var child: Dictionary = children[index]
		var child_old_id := str(child.get("id", ""))
		if child_old_id.is_empty():
			errors.append({"code": "SUBTREE_ID_MISSING", "message": "Subtree child is missing a stable id."})
			return
		var candidate := "%s_%d" % [mapped_id, index + 1]
		var suffix := 2
		while reserved.has(candidate):
			candidate = "%s_%d_%d" % [mapped_id, index + 1, suffix]
			suffix += 1
		reserved[candidate] = true
		_build_id_map(child, candidate, reserved, id_map, errors)

static func _apply_id_map(node: Dictionary, id_map: Dictionary) -> void:
	var old_id := str(node.get("id", ""))
	if id_map.has(old_id):
		node["id"] = id_map[old_id]
	for child in node.get("children", []):
		if child is Dictionary:
			_apply_id_map(child, id_map)

static func _rewrite_node_references(node: Dictionary, id_map: Dictionary) -> void:
	var properties: Dictionary = node.get("properties", {})
	if properties is Dictionary:
		for key in FOCUS_NEIGHBOR_KEYS:
			if properties.has(key):
				properties[key] = _rewrite_reference_value(properties[key], id_map)
		node["properties"] = properties
	var overrides: Dictionary = properties.get("godot_overrides", {}) if properties is Dictionary else {}
	if overrides is Dictionary:
		for key in overrides:
			overrides[key] = _rewrite_reference_value(overrides[key], id_map)
		if properties is Dictionary:
			properties["godot_overrides"] = overrides
			node["properties"] = properties
	for key in node.keys():
		if key in ["properties", "children", "layout", "metadata"]:
			continue
		node[key] = _rewrite_reference_value(node[key], id_map)
	if node.has("layout") and node["layout"] is Dictionary:
		node["layout"] = _rewrite_reference_value(node["layout"], id_map)
	if node.has("metadata") and node["metadata"] is Dictionary:
		node["metadata"] = _rewrite_reference_value(node["metadata"], id_map)

static func _rewrite_reference_value(value: Variant, id_map: Dictionary) -> Variant:
	if value is String:
		return remap_node_path_reference(value, id_map)
	if value is Dictionary:
		if value.has("$node_path"):
			var remapped: Dictionary = value.duplicate(true)
			remapped["$node_path"] = remap_node_path_reference(str(remapped["$node_path"]), id_map)
			return remapped
		if str(value.get("$type", "")) == "Array[NodePath]":
			var entries: Array = value.get("value", [])
			var rewritten: Array = []
			for entry in entries:
				if entry is Dictionary and entry.has("$node_path"):
					rewritten.append({"$node_path": remap_node_path_reference(str(entry["$node_path"]), id_map)})
				elif entry is String:
					rewritten.append(remap_node_path_reference(entry, id_map))
				else:
					rewritten.append(entry)
			return {"$type": "Array[NodePath]", "value": rewritten}
		var result: Dictionary = {}
		for key in value:
			result[key] = _rewrite_reference_value(value[key], id_map)
		return result
	if value is Array:
		var result_array: Array = []
		for entry in value:
			result_array.append(_rewrite_reference_value(entry, id_map))
		return result_array
	return value
