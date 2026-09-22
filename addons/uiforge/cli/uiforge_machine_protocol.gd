class_name UIForgeMachineProtocol
extends RefCounted

const PROTOCOL_ID := "uiforge.machine"
const PROTOCOL_VERSION := 1
const COMMAND_CONTRACT_VERSION := 1
const FRAME_SENTINEL := "UIFORGE_MACHINE_V1\t"
const CONNECT_PREFIX := "UIFORGE_CONNECT\t"
const MAX_REQUEST_BYTES := 1048576

enum ExitClass {
	SUCCESS = 0,
	CLI_USAGE = 2,
	VALIDATION = 3,
	CONFLICT = 4,
	IO_TRUST = 5,
	INTERNAL = 70,
}

static func validate_request(payload: Variant) -> Dictionary:
	if not payload is Dictionary:
		return _invalid("MALFORMED_REQUEST", "Request must be a JSON object.")
	var protocol_value: Variant = payload.get("protocol")
	if typeof(protocol_value) != TYPE_STRING or str(protocol_value) != PROTOCOL_ID:
		return _invalid("PROTOCOL_MISMATCH", "Unsupported protocol identifier.")
	var version_value: Variant = payload.get("protocol_version")
	if typeof(version_value) == TYPE_BOOL:
		return _invalid("MALFORMED_REQUEST", "protocol_version must be an integer.")
	if typeof(version_value) != TYPE_INT and typeof(version_value) != TYPE_FLOAT:
		return _invalid("MALFORMED_REQUEST", "protocol_version must be an integer.")
	if int(version_value) != PROTOCOL_VERSION:
		return _invalid("UNSUPPORTED_PROTOCOL_VERSION", "Unsupported protocol version %s." % str(version_value), ExitClass.CLI_USAGE)
	var request_id_value: Variant = payload.get("request_id")
	if typeof(request_id_value) != TYPE_STRING or str(request_id_value).is_empty():
		return _invalid("MALFORMED_REQUEST", "request_id is required.")
	var method_value: Variant = payload.get("method")
	if typeof(method_value) != TYPE_STRING or str(method_value).is_empty():
		return _invalid("MALFORMED_REQUEST", "Request method is required.")
	if payload.has("params"):
		var params_value: Variant = payload.get("params")
		if not params_value is Dictionary:
			return _invalid("MALFORMED_REQUEST", "Request params must be an object when present.")
	return {"ok": true, "request": payload}

static func machine_failure_result(legacy: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for key in ["committed", "failed_index", "failed_op", "old_revision", "new_revision", "operations", "dry_run", "expected_revision", "current_revision", "revision", "document"]:
		if legacy.has(key):
			result[key] = legacy[key]
	if not result.has("committed") and not bool(legacy.get("success", false)):
		result["committed"] = false
	if legacy.has("errors") and legacy.errors is Array and not legacy.errors.is_empty() and legacy.errors[0] is Dictionary:
		var first: Dictionary = legacy.errors[0]
		for key in ["expected_revision", "current_revision", "index"]:
			if first.has(key) and not result.has(key):
				result[key] = first[key]
	return result

static func success_response(request_id: String, result: Dictionary, diagnostics: Array = []) -> Dictionary:
	return {
		"protocol": PROTOCOL_ID,
		"protocol_version": PROTOCOL_VERSION,
		"request_id": request_id,
		"success": true,
		"result": result if result != null else {},
		"diagnostics": normalize_diagnostics(diagnostics),
		"meta": _meta(),
	}

static func error_response(request_id: String, code: String, message: String, diagnostics: Array = [], result: Dictionary = {}) -> Dictionary:
	return {
		"protocol": PROTOCOL_ID,
		"protocol_version": PROTOCOL_VERSION,
		"request_id": request_id,
		"success": false,
		"error": {"code": code, "message": message},
		"result": result if result != null else {},
		"diagnostics": normalize_diagnostics(diagnostics),
		"meta": _meta(),
	}

static func normalize_diagnostics(raw: Array) -> Array:
	var normalized: Array = []
	for item in raw:
		if not item is Dictionary:
			continue
		var entry: Dictionary = {
			"severity": str(item.get("severity", "error")),
			"code": str(item.get("code", "UNKNOWN")),
			"message": str(item.get("message", "")),
		}
		for key in ["path", "node", "property", "json_pointer", "recommendation"]:
			if item.has(key) and not str(item.get(key, "")).is_empty():
				entry[key] = str(item.get(key))
		normalized.append(entry)
	return normalized

static func exit_class_for_response(response: Dictionary) -> int:
	if bool(response.get("success", false)):
		return ExitClass.SUCCESS
	var code := str(response.get("error", {}).get("code", ""))
	match code:
		"USAGE", "MALFORMED_REQUEST", "UNKNOWN_COMMAND", "UNKNOWN_METHOD", "UNSUPPORTED_PROTOCOL_VERSION", "PROTOCOL_MISMATCH", "REQUEST_TOO_LARGE":
			return ExitClass.CLI_USAGE
		"REVISION_CONFLICT", "WRITE_CONFLICT":
			return ExitClass.CONFLICT
		"OUTPUT_OUTSIDE_WORKSPACE", "PATH_CANONICALIZATION_FAILED", "LOCK_CREATE_FAILED", "FILE_NOT_FOUND", "FILE_OPEN_FAILED":
			return ExitClass.IO_TRUST
		_:
			if code.ends_with("_FAILED") or code.begins_with("PATH_"):
				return ExitClass.IO_TRUST
			return ExitClass.VALIDATION

static func frame_line(payload: Dictionary) -> String:
	return "%s%s" % [FRAME_SENTINEL, JSON.stringify(payload)]

static func parse_framed_line(line: String) -> Variant:
	var trimmed := line.strip_edges()
	if trimmed.is_empty():
		return null
	if trimmed.begins_with(FRAME_SENTINEL):
		var parser := JSON.new()
		if parser.parse(trimmed.substr(FRAME_SENTINEL.length())) != OK:
			return null
		return parser.data
	return null

static func _meta() -> Dictionary:
	return {
		"backend": "godot-native",
		"schema_version": UIForgeTypes.SCHEMA_VERSION,
		"command_contract_version": COMMAND_CONTRACT_VERSION,
	}

static func _invalid(code: String, message: String, exit_class: int = ExitClass.CLI_USAGE) -> Dictionary:
	return {"ok": false, "code": code, "message": message, "exit_class": exit_class}
