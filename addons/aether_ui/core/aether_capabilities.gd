class_name AetherCapabilities
extends RefCounted

static func as_dict() -> Dictionary:
	var properties := AetherPropertyCatalog.capability_groups()
	var viewport_presets: Array[Dictionary] = []
	for size in AetherTypes.VIEWPORT_PRESETS:
		viewport_presets.append({"width": size.x, "height": size.y})
	var supported_types: Array[String] = []
	for type_name in AetherTypes.NATIVE_TYPES + AetherTypes.COMPONENT_TYPES:
		if type_name not in supported_types:
			supported_types.append(type_name)
	return {
		"schema_version": AetherTypes.SCHEMA_VERSION,
		"templates": AetherTemplates.catalog(),
		"supported_node_types": supported_types,
		"components": AetherComponentLibrary.definitions().keys(),
		"states": AetherTypes.STATES,
		"viewport_presets": viewport_presets,
		"themes": ["dark_fantasy"],
		"properties": properties,
		"property_schemas": AetherPropertyCatalog.capability_schemas(),
		"native_properties": AetherPropertyCatalog.native_property_schemas(),
		"operations": ["get", "set", "add", "delete", "move", "duplicate", "validate", "build", "render", "inspect", "new"]
	}
