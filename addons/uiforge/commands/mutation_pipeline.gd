class_name UIForgeMutationPipeline
extends RefCounted

static func commit(path: String, mutate: Callable) -> Dictionary:
	return commit_with_revision(path, mutate, "")

static func commit_with_revision(path: String, mutate: Callable, expected_revision: String) -> Dictionary:
	var loaded := UIForgeSerializer.load_document(path)
	if loaded.get("document") == null:
		return {"success": false, "committed": false, "errors": loaded.get("errors", [])}
	var revision := str(loaded.get("revision_hash", ""))
	if not expected_revision.is_empty() and expected_revision != revision:
		return {"success": false, "committed": false, "errors": [{"code": "REVISION_CONFLICT", "message": "Expected revision does not match current document.", "expected_revision": expected_revision, "current_revision": revision}]}
	var working: UIForgeDocument = UIForgeDocument.from_dict(loaded["document"].to_dict(), path)
	var operation: Dictionary = mutate.call(working)
	if not bool(operation.get("success", false)):
		operation["committed"] = false
		return operation
	var validation := UIForgeValidator.new().validate(working)
	if not validation.success:
		return {"success": false, "committed": false, "errors": _error_diagnostics(validation.diagnostics), "warnings": validation.warnings, "diagnostics": validation.diagnostics}
	var saved := UIForgeSerializer.save_document(working, path, revision)
	if not saved.get("success", false):
		operation["success"] = false
		operation["committed"] = false
		operation["errors"] = saved.get("errors", [])
		return operation
	operation["success"] = true
	operation["committed"] = true
	operation["old_revision"] = revision
	operation["new_revision"] = UIForgeHash.document_revision(working)
	operation.erase("saved")
	return operation

static func commit_batch(path: String, operations: Array, expected_revision: String = "", dry_run: bool = false) -> Dictionary:
	var loaded := UIForgeSerializer.load_document(path)
	if loaded.get("document") == null:
		return {"success": false, "committed": false, "errors": loaded.get("errors", [])}
	var old_revision := str(loaded.get("revision_hash", ""))
	if not expected_revision.is_empty() and expected_revision != old_revision:
		return {"success": false, "committed": false, "errors": [{"code": "REVISION_CONFLICT", "message": "Expected revision does not match current document.", "expected_revision": expected_revision, "current_revision": old_revision}]}
	var working: UIForgeDocument = UIForgeDocument.from_dict(loaded["document"].to_dict(), path)
	var operation_results: Array = []
	for index in operations.size():
		var op: Variant = operations[index]
		if not op is Dictionary:
			return _batch_failure(old_revision, index, "MALFORMED_OPERATION", "Batch operation must be an object.", operation_results)
		var applied := _apply_batch_operation(working, op)
		operation_results.append({"index": index, "op": str(op.get("op", "")), "success": bool(applied.get("success", false))})
		if not bool(applied.get("success", false)):
			var error := applied.get("error", applied.get("errors", [{}]))
			var code := str(error.get("code", "OPERATION_FAILED")) if error is Dictionary else "OPERATION_FAILED"
			var message := str(error.get("message", "Batch operation failed.")) if error is Dictionary else "Batch operation failed."
			return _batch_failure(old_revision, index, code, message, operation_results, applied.get("diagnostics", []))
	var validation := UIForgeValidator.new().validate(working)
	if not validation.success:
		return {"success": false, "committed": false, "old_revision": old_revision, "new_revision": UIForgeHash.document_revision(working), "operations": operation_results, "errors": _error_diagnostics(validation.diagnostics), "diagnostics": validation.diagnostics}
	if dry_run:
		return {"success": true, "committed": false, "dry_run": true, "old_revision": old_revision, "new_revision": UIForgeHash.document_revision(working), "operations": operation_results}
	var saved := UIForgeSerializer.save_document(working, path, old_revision)
	if not saved.get("success", false):
		return {"success": false, "committed": false, "old_revision": old_revision, "operations": operation_results, "errors": saved.get("errors", [])}
	return {"success": true, "committed": true, "old_revision": old_revision, "new_revision": UIForgeHash.document_revision(working), "operations": operation_results}

static func _apply_batch_operation(document: UIForgeDocument, op: Dictionary) -> Dictionary:
	match str(op.get("op", "")):
		"set":
			return UIForgeDocumentOperations.set_value(document, str(op.get("node", "")), str(op.get("property", "")), str(op.get("value", "")))
		"add":
			var node_payload: Variant = op.get("node", op.get("value", {}))
			var raw_node := node_payload if node_payload is String else JSON.stringify(node_payload)
			return UIForgeDocumentOperations.add_value(document, str(op.get("parent", op.get("parent_id", ""))), raw_node)
		"delete":
			return UIForgeDocumentOperations.delete_value(document, str(op.get("node", "")))
		"move":
			return UIForgeDocumentOperations.move_value(document, str(op.get("node", "")), str(op.get("parent", op.get("parent_id", ""))), int(op.get("index", -1)))
		"duplicate":
			return UIForgeDocumentOperations.duplicate_value(document, str(op.get("node", "")), str(op.get("new_id", "")))
		_:
			return {"success": false, "error": {"code": "UNKNOWN_OPERATION", "message": "Unknown batch operation '%s'." % str(op.get("op", ""))}}

static func _batch_failure(old_revision: String, failed_index: int, code: String, message: String, operations: Array, diagnostics: Array = []) -> Dictionary:
	return {
		"success": false,
		"committed": false,
		"old_revision": old_revision,
		"failed_index": failed_index,
		"failed_op": operations[failed_index].get("op", "") if failed_index >= 0 and failed_index < operations.size() else "",
		"operations": operations,
		"errors": [{"code": code, "message": message, "index": failed_index}],
		"diagnostics": diagnostics,
	}

static func _error_diagnostics(diagnostics: Array) -> Array:
	var errors: Array = []
	for diagnostic in diagnostics:
		if str(diagnostic.get("severity", "")) == "error":
			errors.append(diagnostic)
	return errors
