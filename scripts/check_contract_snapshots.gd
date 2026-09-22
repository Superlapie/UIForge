extends SceneTree

const OUTPUT_DIR := "res://contract/snapshots/"

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	var godot_version := "%s.%s.%s.%s.%s" % [
		Engine.get_version_info().get("major", 0),
		Engine.get_version_info().get("minor", 0),
		Engine.get_version_info().get("patch", 0),
		Engine.get_version_info().get("status", ""),
		Engine.get_version_info().get("hash", ""),
	]
	var native_classes := _collect_native_classes()
	var inventory: Dictionary = {"godot_version": godot_version, "classes": {}}
	for native_class in native_classes:
		inventory["classes"][native_class] = _property_names_for_class(native_class)
	var expected := {
		"manifest.json": {
			"schema_version": 1,
			"godot_version": godot_version,
			"snapshot_files": [
				"semantic_property_schemas.json",
				"property_groups.json",
				"component_definitions.json",
				"supported_node_types.json",
				"native_property_inventory.json",
			],
		},
		"semantic_property_schemas.json": _normalize_value(UIForgePropertyCatalog.capability_schemas()),
		"property_groups.json": _normalize_value(UIForgePropertyCatalog.capability_groups()),
		"component_definitions.json": _normalize_value(UIForgeComponentLibrary.definitions()),
		"supported_node_types.json": _normalize_value(_supported_node_types()),
		"native_property_inventory.json": _normalize_value(inventory),
	}
	for filename in expected.keys():
		var path := "%s%s" % [OUTPUT_DIR, filename]
		if not FileAccess.file_exists(path):
			failures.append("missing snapshot %s" % path)
			continue
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			failures.append("cannot read snapshot %s" % path)
			continue
		var committed: Variant = JSON.parse_string(file.get_as_text())
		file.close()
		if _canonical_text(committed) != _canonical_text(expected[filename]):
			failures.append("stale snapshot %s" % filename)
	if failures.is_empty():
		print(JSON.stringify({"success": true, "snapshots": expected.keys()}))
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		print(JSON.stringify({"success": false, "failures": failures}))
		quit(1)

func _supported_node_types() -> Array[String]:
	var supported: Array[String] = []
	for type_name in UIForgeTypes.NATIVE_TYPES + UIForgeTypes.COMPONENT_TYPES:
		if type_name not in supported:
			supported.append(type_name)
	for component_name in UIForgeComponentLibrary.definitions().keys():
		if component_name not in supported:
			supported.append(str(component_name))
	supported.sort()
	return supported

func _collect_native_classes() -> Array[String]:
	var classes: Dictionary = {}
	for type_name in UIForgeTypes.NATIVE_TYPES:
		classes[UIForgeComponentLibrary.native_type(str(type_name))] = true
	for component_name in UIForgeComponentLibrary.definitions().keys():
		var definition: Dictionary = UIForgeComponentLibrary.definitions()[component_name]
		classes[str(definition.get("native_type", "Control"))] = true
	var names: Array[String] = []
	for native_class in classes.keys():
		names.append(str(native_class))
	names.sort()
	return names

func _property_names_for_class(native_class: String) -> Array[String]:
	var names: Array[String] = []
	var seen: Dictionary = {}
	if not ClassDB.class_exists(native_class):
		return names
	for raw in ClassDB.class_get_property_list(native_class):
		if not raw is Dictionary:
			continue
		var property_name := str(raw.get("name", ""))
		var usage := int(raw.get("usage", 0))
		if property_name.is_empty() or seen.has(property_name):
			continue
		if usage & PROPERTY_USAGE_CATEGORY != 0 or usage & PROPERTY_USAGE_GROUP != 0 or usage & PROPERTY_USAGE_SUBGROUP != 0:
			continue
		seen[property_name] = true
		names.append(property_name)
	names.sort()
	return names

func _normalize_value(value: Variant) -> Variant:
	if value is Array:
		var items: Array = []
		for item in value:
			items.append(_normalize_value(item))
		return items
	if value is Dictionary:
		var keys: Array = value.keys()
		keys.sort()
		var normalized := {}
		for key in keys:
			normalized[str(key)] = _normalize_value(value[key])
		return normalized
	return value

func _canonical_text(value: Variant) -> String:
	return JSON.stringify(JSON.parse_string(JSON.stringify(_normalize_value(value))), "\t") + "\n"
