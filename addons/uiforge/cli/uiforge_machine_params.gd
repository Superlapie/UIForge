class_name UIForgeMachineParams
extends RefCounted

static func validate_command_params(method: String, params: Variant) -> Dictionary:
	if not params is Dictionary:
		return _invalid("params", "Request params must be an object when present.")
	var schemas: Dictionary = UIForgeCapabilities.as_dict().get("command_parameter_schemas", {})
	if not schemas.has(method):
		return {"ok": true, "params": params}
	var schema: Dictionary = schemas[method].get("params", {})
	for field_name in params.keys():
		if not schema.has(field_name):
			continue
		var field_error := _validate_field(str(field_name), params[field_name], str(schema[field_name]))
		if not field_error.is_empty():
			return field_error
	for field_name in schema.keys():
		var type_name := str(schema[field_name])
		if type_name.ends_with("?"):
			continue
		if not params.has(field_name):
			return _invalid(field_name, "Required parameter '%s' is missing." % field_name)
	if method == "batch":
		return _validate_batch_params(params)
	return {"ok": true, "params": params}

static func _validate_batch_params(params: Dictionary) -> Dictionary:
	var operations: Variant = params.get("operations")
	if typeof(operations) != TYPE_ARRAY:
		return _invalid("operations", "Parameter 'operations' must be an array.")
	var batch_schemas: Dictionary = UIForgeCapabilities.as_dict().get("batch_operation_schemas", {})
	for index in range(operations.size()):
		var operation: Variant = operations[index]
		if not operation is Dictionary:
			return _invalid("operations[%d]" % index, "Batch operation must be an object.")
		var op_name := str(operation.get("op", ""))
		if not batch_schemas.has(op_name):
			return _invalid("operations[%d].op" % index, "Unknown batch operation '%s'." % op_name)
		var op_schema: Dictionary = batch_schemas[op_name]
		for field_name in operation.keys():
			if field_name == "op":
				continue
			if not op_schema.has(field_name):
				continue
			var field_error := _validate_field("operations[%d].%s" % [index, field_name], operation[field_name], str(op_schema[field_name]))
			if not field_error.is_empty():
				return field_error
		for field_name in op_schema.keys():
			var type_name := str(op_schema[field_name])
			if type_name.ends_with("?"):
				continue
			if not operation.has(field_name):
				return _invalid("operations[%d].%s" % [index, field_name], "Required batch field '%s' is missing." % field_name)
	return {"ok": true, "params": params}

static func _validate_field(field_path: String, value: Variant, type_name: String) -> Dictionary:
	var optional := type_name.ends_with("?")
	var base_type := type_name.trim_suffix("?")
	if "|" in base_type:
		var alternatives := base_type.split("|", false)
		for alternative in alternatives:
			if _validate_field(field_path, value, str(alternative).strip_edges()).is_empty():
				return {}
		return _invalid(field_path, "Parameter '%s' must be one of: %s." % [field_path, base_type.replace("|", ", ")])
	if base_type == "any":
		return {}
	match base_type:
		"string":
			if typeof(value) != TYPE_STRING:
				return _invalid(field_path, "Parameter '%s' must be a string." % field_path)
		"boolean":
			if typeof(value) != TYPE_BOOL:
				return _invalid(field_path, "Parameter '%s' must be a boolean." % field_path)
		"integer":
			if not _is_whole_number(value):
				return _invalid(field_path, "Parameter '%s' must be an integer." % field_path)
		"array":
			if typeof(value) != TYPE_ARRAY:
				return _invalid(field_path, "Parameter '%s' must be an array." % field_path)
		"object":
			if not value is Dictionary:
				return _invalid(field_path, "Parameter '%s' must be an object." % field_path)
		_:
			return _invalid(field_path, "Unsupported parameter schema '%s'." % type_name)
	return {}

static func _is_whole_number(value: Variant) -> bool:
	if typeof(value) == TYPE_INT:
		return true
	if typeof(value) == TYPE_FLOAT:
		var numeric := float(value)
		return is_finite(numeric) and numeric == floor(numeric)
	return false

static func _invalid(field_path: String, message: String) -> Dictionary:
	return {
		"ok": false,
		"code": "MALFORMED_PARAMS",
		"message": message,
		"field": field_path,
	}
