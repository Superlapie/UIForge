class_name UIForgeDocumentOperations
extends RefCounted

static func parse_value(raw: String) -> Variant:
	var parser := JSON.new()
	if parser.parse(raw) == OK:
		return parser.data
	return raw

static func get_node(document: UIForgeDocument, node_id: String) -> Dictionary:
	var node := document.find_node(node_id)
	if node.is_empty():
		return {"success": false, "error": {"code": "NODE_NOT_FOUND", "node": node_id}}
	return {"success": true, "id": node_id, "node": node.duplicate(true), "parent": document.find_parent(node_id).get("id", "")}

static func inspect_tree(document: UIForgeDocument) -> Dictionary:
	return {"success": true, "tree": _tree_node(document.root())}

static func set_value(document: UIForgeDocument, node_id: String, property_path: String, raw_value: String) -> Dictionary:
	var value := parse_value(raw_value)
	if not document.set_property(node_id, property_path, value):
		return {"success": false, "error": {"code": "SET_FAILED", "message": "Node or property path not found.", "node": node_id}}
	return {"success": true, "node": document.find_node(node_id), "property": property_path, "value": value}

static func add_value(document: UIForgeDocument, parent_id: String, raw_node: String) -> Dictionary:
	var value := parse_value(raw_node)
	if not value is Dictionary:
		return {"success": false, "error": {"code": "NODE_JSON_INVALID", "message": "The new node must be a JSON object."}}
	var node_id := str(value.get("id", ""))
	var id_error := UIForgeID.diagnostic(node_id)
	if not id_error.is_empty():
		return {"success": false, "error": id_error}
	if not document.find_node(node_id).is_empty():
		return {"success": false, "error": {"code": "DUPLICATE_ID", "message": "Node id '%s' already exists." % node_id, "node": node_id}}
	var custom_components := _custom_components(document)
	var added := document.add_child_checked(parent_id, value, custom_components)
	if not added.get("ok", false):
		return {"success": false, "error": added.get("errors", [{"code": "ADD_FAILED", "parent": parent_id}])[0]}
	return {"success": true, "node": value, "parent": parent_id}

static func delete_value(document: UIForgeDocument, node_id: String) -> Dictionary:
	var removed := document.delete_node(node_id)
	if removed.is_empty():
		return {"success": false, "error": {"code": "DELETE_FAILED", "node": node_id}}
	return {"success": true, "deleted": removed}

static func move_value(document: UIForgeDocument, node_id: String, parent_id: String, index: int = -1) -> Dictionary:
	var moved := document.move_node_checked(node_id, parent_id, _custom_components(document), index)
	if not moved.get("ok", false):
		return {"success": false, "error": moved.get("errors", [{"code": "MOVE_FAILED", "node": node_id, "parent": parent_id}])[0]}
	return {"success": true, "node": node_id, "parent": parent_id, "index": index}

static func duplicate_value(document: UIForgeDocument, node_id: String, new_id: String) -> Dictionary:
	var id_error := UIForgeID.diagnostic(new_id, node_id)
	if not id_error.is_empty():
		return {"success": false, "error": id_error}
	if not document.find_node(new_id).is_empty():
		return {"success": false, "error": {"code": "DUPLICATE_ID", "message": "Node id '%s' already exists." % new_id, "node": new_id}}
	var copy := document.duplicate_node(node_id, new_id)
	if copy.is_empty():
		return {"success": false, "error": {"code": "DUPLICATE_FAILED", "node": node_id}}
	return {"success": true, "node": copy}

static func _custom_components(document: UIForgeDocument) -> Dictionary:
	var components_value: Variant = document.data.get("components", {})
	return components_value if components_value is Dictionary else {}

static func _tree_node(node: Dictionary) -> Dictionary:
	var result := {"id": node.get("id", ""), "type": node.get("type", "Control"), "name": node.get("name", node.get("id", "")), "children": []}
	for child in node.get("children", []):
		if child is Dictionary:
			result["children"].append(_tree_node(child))
	return result
