class_name UIForgeMutationPipeline
extends RefCounted

static func commit(path: String, mutate: Callable) -> Dictionary:
	var loaded := UIForgeSerializer.load_document(path)
	if loaded.get("document") == null:
		return {"success": false, "committed": false, "errors": loaded.get("errors", [])}
	var expected_revision := str(loaded.get("revision_hash", ""))
	var working: UIForgeDocument = UIForgeDocument.from_dict(loaded["document"].to_dict(), path)
	var operation: Dictionary = mutate.call(working)
	if not bool(operation.get("success", false)):
		operation["committed"] = false
		return operation
	var validation := UIForgeValidator.new().validate(working)
	if not validation.success:
		return {
			"success": false,
			"committed": false,
			"errors": _error_diagnostics(validation.diagnostics),
			"warnings": validation.warnings,
			"diagnostics": validation.diagnostics
		}
	var saved := UIForgeSerializer.save_document(working, path, expected_revision)
	if not saved.get("success", false):
		operation["success"] = false
		operation["committed"] = false
		operation["errors"] = saved.get("errors", [])
		return operation
	operation["success"] = true
	operation["committed"] = true
	operation.erase("saved")
	return operation

static func _error_diagnostics(diagnostics: Array) -> Array:
	var errors: Array = []
	for diagnostic in diagnostics:
		if str(diagnostic.get("severity", "")) == "error":
			errors.append(diagnostic)
	return errors
