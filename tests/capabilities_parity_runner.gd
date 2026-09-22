extends SceneTree

const BACKEND_SPECIFIC_KEYS := [
	"backend",
	"generator_version",
	"persistent_server",
	"supported_transports",
	"native_property_schemas",
]

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	var native_caps: Dictionary = _normalize_map(_canonicalize(UIForgeCapabilities.as_dict()))
	var fallback_caps: Dictionary = _normalize_map(_canonicalize(_load_fallback_capabilities()))
	if fallback_caps.is_empty():
		failures.append("fallback capabilities unavailable")
	else:
		failures.append_array(_diff_paths(native_caps, fallback_caps, ""))
	if failures.is_empty():
		print(JSON.stringify({"success": true, "checks": 1}))
		quit(0)
	for failure in failures:
		push_error(failure)
	print(JSON.stringify({"success": false, "failures": failures}))
	quit(1)

func _load_fallback_capabilities() -> Dictionary:
	var output_path := ProjectSettings.globalize_path("user://capabilities_parity_fallback.json")
	var output: PackedStringArray = []
	var err: PackedStringArray = []
	var exit_code := OS.execute("python3", PackedStringArray([
		ProjectSettings.globalize_path("res://scripts/compare_capabilities_parity.py"),
		"--fallback-only",
		"--output",
		output_path,
	]), output, true, true)
	if exit_code != 0:
		return {}
	if not FileAccess.file_exists(output_path):
		return {}
	var text := FileAccess.get_file_as_string(output_path)
	var payload: Variant = JSON.parse_string(text)
	return payload if payload is Dictionary else {}

func _canonicalize(value: Variant) -> Variant:
	return JSON.parse_string(JSON.stringify(value))

func _normalize_map(value: Variant) -> Variant:
	if value is Array:
		var items: Array = []
		for item in value:
			items.append(_normalize_map(item))
		if _looks_like_string_array(items):
			items.sort()
		return items
	if value is Dictionary:
		var normalized := {}
		for key in value.keys():
			var name := str(key)
			if name in BACKEND_SPECIFIC_KEYS:
				continue
			normalized[name] = _normalize_map(value[key])
		if normalized.has("available_commands") and normalized["available_commands"] is Array:
			var commands: Array = []
			for command in normalized["available_commands"]:
				if str(command) != "shutdown":
					commands.append(command)
			commands.sort()
			normalized["available_commands"] = commands
		if normalized.has("command_parameter_schemas") and normalized["command_parameter_schemas"] is Dictionary:
			normalized["command_parameter_schemas"].erase("shutdown")
		if normalized.has("properties") and normalized["properties"] is Dictionary:
			for category in normalized["properties"].keys():
				var paths: Array = normalized["properties"][category]
				if paths is Array:
					paths.sort()
					normalized["properties"][category] = paths
		if normalized.has("operations") and normalized["operations"] is Array:
			var operations: Array = normalized["operations"].duplicate()
			operations.sort()
			normalized["operations"] = operations
		if normalized.has("resource_safety_policy") and normalized["resource_safety_policy"] is Dictionary:
			var policy: Dictionary = normalized["resource_safety_policy"]
			for policy_key in policy.keys():
				if policy[policy_key] is Array:
					var items: Array = policy[policy_key].duplicate()
					items.sort()
					policy[policy_key] = items
		return normalized
	return value

func _looks_like_string_array(items: Array) -> bool:
	if items.is_empty():
		return false
	for item in items:
		if not (item is String):
			return false
	return true

func _diff_paths(left: Variant, right: Variant, prefix: String) -> Array[String]:
	var failures: Array[String] = []
	if typeof(left) != typeof(right):
		failures.append("%s: type mismatch" % prefix)
		return failures
	if left is Dictionary:
		var left_keys := (left as Dictionary).keys()
		var right_keys := (right as Dictionary).keys()
		for key in left_keys:
			if key not in right_keys:
				failures.append("%s.%s: missing on right" % [prefix, str(key)])
		for key in right_keys:
			if key not in left_keys:
				failures.append("%s.%s: extra on right" % [prefix, str(key)])
		for key in left_keys:
			if key in right_keys:
				var child_prefix := "%s.%s" % [prefix, str(key)] if not prefix.is_empty() else str(key)
				failures.append_array(_diff_paths(left[key], right[key], child_prefix))
	elif left is Array:
		var left_array := left as Array
		var right_array := right as Array
		if left_array.size() != right_array.size():
			failures.append("%s: list length %d vs %d" % [prefix, left_array.size(), right_array.size()])
			return failures
		for index in left_array.size():
			failures.append_array(_diff_paths(left_array[index], right_array[index], "%s[%d]" % [prefix, index]))
	elif left != right:
		failures.append("%s: %s != %s" % [prefix, str(left), str(right)])
	return failures
