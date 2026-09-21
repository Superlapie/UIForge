class_name UIForgeCapabilities
extends RefCounted

static func as_dict() -> Dictionary:
	var properties := UIForgePropertyCatalog.capability_groups()
	var viewport_presets: Array[Dictionary] = []
	for size in UIForgeTypes.VIEWPORT_PRESETS:
		viewport_presets.append({"width": size.x, "height": size.y})
	var supported_types: Array[String] = []
	for type_name in UIForgeTypes.NATIVE_TYPES + UIForgeTypes.COMPONENT_TYPES:
		if type_name not in supported_types:
			supported_types.append(type_name)
	return {
		"schema_version": UIForgeTypes.SCHEMA_VERSION,
		"templates": UIForgeTemplates.catalog(),
		"supported_node_types": supported_types,
		"components": UIForgeComponentLibrary.definitions().keys(),
		"states": UIForgeTypes.STATES,
		"viewport_presets": viewport_presets,
		"themes": ["dark_fantasy"],
		"properties": properties,
		"property_schemas": UIForgePropertyCatalog.capability_schemas(),
		"native_properties": UIForgePropertyCatalog.native_property_schemas(),
		"operations": ["get", "set", "add", "delete", "move", "duplicate", "validate", "build", "render", "inspect", "new"]
	}
