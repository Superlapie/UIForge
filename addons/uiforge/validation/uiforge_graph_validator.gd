class_name UIForgeGraphValidator
extends RefCounted

static func validate_materialized_graph(document: UIForgeDocument, theme: UIForgeTheme, compiler: UIForgeCompiler) -> Array:
	var diagnostics: Array = []
	var ids: Dictionary = {}
	var sibling_names: Dictionary = {}
	_collect(document.root(), ".", compiler, theme, ids, sibling_names, diagnostics)
	return diagnostics

static func _collect(
	node: Dictionary,
	parent_path: String,
	compiler: UIForgeCompiler,
	theme: UIForgeTheme,
	ids: Dictionary,
	sibling_names: Dictionary,
	diagnostics: Array
) -> void:
	if not node is Dictionary:
		diagnostics.append(_diag("NODE_INVALID", "Every emitted node must be an object.", parent_path))
		return
	var materialized: Dictionary = {}
	if compiler != null:
		materialized = compiler._materialize_node(node)
	else:
		materialized = node
	var node_id := str(materialized.get("id", ""))
	if node_id.is_empty():
		diagnostics.append(_diag("GENERATED_ID_MISSING", "Generated node is missing a canonical id.", parent_path))
	elif not UIForgeID.is_valid(node_id):
		diagnostics.append(UIForgeID.diagnostic(node_id))
	elif ids.has(node_id):
		diagnostics.append(_diag("GENERATED_ID_COLLISION", "Generated node id '%s' is duplicated in the materialized graph." % node_id, node_id))
	else:
		ids[node_id] = true
	var node_name := String(node_id).validate_node_name()
	if node_name.is_empty():
		node_name = "Node_%s" % abs(node_id.hash())
	var sibling_key := "%s|%s" % [parent_path, node_name]
	if sibling_names.has(sibling_key):
		diagnostics.append(_diag("GENERATED_NAME_COLLISION", "Generated Godot node name '%s' is duplicated under '%s'." % [node_name, parent_path], node_id))
	else:
		sibling_names[sibling_key] = true
	var children: Array = []
	if compiler != null:
		children = compiler._children_for(materialized)
	else:
		for child in materialized.get("children", []):
			if child is Dictionary:
				children.append(child)
	var child_path := node_name if parent_path == "." else "%s/%s" % [parent_path, node_name]
	for child in children:
		if child is Dictionary:
			_collect(child, child_path, compiler, theme, ids, sibling_names, diagnostics)

static func _diag(code: String, message: String, node_id: String) -> Dictionary:
	return {
		"severity": "error",
		"code": code,
		"message": message,
		"node": node_id,
		"recommendation": "Adjust authored ids or generated helper configuration to keep the materialized graph unique.",
	}
