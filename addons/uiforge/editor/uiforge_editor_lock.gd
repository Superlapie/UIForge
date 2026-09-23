class_name UIForgeEditorLock
extends RefCounted

## Structural/layout lock for editor operations. Copy and property inspection remain allowed.

static func is_locked(node: Dictionary) -> bool:
	return bool(node.get("metadata", {}).get("editor_locked", false))

static func blocks_structural_mutation(node: Dictionary) -> bool:
	return is_locked(node)

static func blocks_child_list_mutation(container: Dictionary) -> bool:
	return is_locked(container)

static func structural_block_message(node_id: String) -> Dictionary:
	return {
		"severity": "error",
		"code": "EDITOR_LOCKED",
		"message": "Node '%s' is editor-locked." % node_id,
		"node": node_id,
	}
