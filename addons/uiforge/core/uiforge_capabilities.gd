class_name UIForgeCapabilities
extends RefCounted

static func command_names() -> Array[String]:
	var names: Array[String] = ["capabilities", "new", "validate", "inspect", "get", "set", "add", "delete", "move", "duplicate", "batch", "build", "build-all", "render", "shutdown"]
	names.sort()
	return names

static func as_dict() -> Dictionary:
	var properties := UIForgePropertyCatalog.capability_groups()
	var viewport_presets: Array[Dictionary] = []
	for size in UIForgeTypes.VIEWPORT_PRESETS:
		viewport_presets.append({"width": size.x, "height": size.y})
	var supported_types: Array[String] = []
	for type_name in UIForgeTypes.NATIVE_TYPES + UIForgeTypes.COMPONENT_TYPES:
		if type_name not in supported_types:
			supported_types.append(type_name)
	supported_types.sort()
	var components: Array = UIForgeComponentLibrary.definitions().keys()
	components.sort()
	return {
		"machine_protocol": UIForgeMachineProtocol.PROTOCOL_ID,
		"machine_protocol_versions": [UIForgeMachineProtocol.PROTOCOL_VERSION],
		"command_contract_version": UIForgeMachineProtocol.COMMAND_CONTRACT_VERSION,
		"backend": "godot-native",
		"schema_version": UIForgeTypes.SCHEMA_VERSION,
		"generator_version": UIForgeArtifact.GENERATOR_VERSION,
		"available_commands": command_names(),
		"command_parameter_schemas": _command_parameter_schemas(),
		"batch_operation_schemas": _batch_operation_schemas(),
		"supported_node_types": supported_types,
		"property_schemas": UIForgePropertyCatalog.capability_schemas(),
		"native_property_schemas": UIForgePropertyCatalog.native_property_schemas(),
		"components": components,
		"component_definitions": UIForgeComponentLibrary.definitions(),
		"states": UIForgeTypes.STATES.duplicate(),
		"viewport_presets": viewport_presets,
		"themes": ["dark_fantasy"],
		"properties": properties,
		"templates": UIForgeTemplates.catalog(),
		"operations": ["get", "set", "add", "delete", "move", "duplicate", "validate", "build", "render", "inspect", "new", "batch"],
		"resource_safety_policy": {
			"blocked_resource_classes": UIForgeResourceGuard.BLOCKED_TYPES.duplicate(),
			"blocked_extensions": UIForgeResourceGuard.BLOCKED_EXTENSIONS.duplicate(),
			"allowed_resource_classes": UIForgeResourceGuard.ALLOWED_TYPES.duplicate(),
		},
		"output_path_policy": {"workspace_relative": true, "allow_outside_project_flag": true},
		"optimistic_concurrency": {"supported": true, "revision_field": "revision", "expected_revision_param": "expected_revision"},
		"persistent_server": {"supported": true, "transport": "stdio", "protocol": UIForgeMachineProtocol.PROTOCOL_ID},
		"batch": {"supported": true, "atomic": true, "dry_run": true, "operations": ["set", "add", "delete", "move", "duplicate"]},
		"dry_run": {"supported": true, "methods": ["batch"]},
		"max_request_bytes": UIForgeMachineProtocol.MAX_REQUEST_BYTES,
		"protocol_version_semantics": {
			"rule": "protocol_version must be a finite integer-valued JSON number matching a supported version.",
			"accepted_examples": [1, 1.0],
			"rejected_examples": [1.5, "1", true, null],
		},
		"supported_render_states": UIForgeTypes.STATES.duplicate(),
		"supported_transports": ["human_cli", "machine_oneshot", "persistent_stdio"],
		"exit_codes": {
			"success": UIForgeMachineProtocol.ExitClass.SUCCESS,
			"cli_usage": UIForgeMachineProtocol.ExitClass.CLI_USAGE,
			"validation": UIForgeMachineProtocol.ExitClass.VALIDATION,
			"conflict": UIForgeMachineProtocol.ExitClass.CONFLICT,
			"io_trust": UIForgeMachineProtocol.ExitClass.IO_TRUST,
			"internal": UIForgeMachineProtocol.ExitClass.INTERNAL,
		},
	}

static func _command_parameter_schemas() -> Dictionary:
	return {
		"capabilities": {"params": {}},
		"new": {"params": {"template": "string", "output": "string", "force": "boolean?", "allow_outside_project": "boolean?"}},
		"validate": {"params": {"document": "string"}},
		"inspect": {"params": {"document": "string", "scope": "string", "node": "string?"}},
		"get": {"params": {"document": "string", "node": "string", "property": "string?"}},
		"set": {"params": {"document": "string", "node": "string", "property": "string", "value": "any", "expected_revision": "string?"}},
		"add": {"params": {"document": "string", "parent": "string", "node": "object|string", "expected_revision": "string?"}},
		"delete": {"params": {"document": "string", "node": "string", "expected_revision": "string?"}},
		"move": {"params": {"document": "string", "node": "string", "parent": "string", "index": "integer?", "expected_revision": "string?"}},
		"duplicate": {"params": {"document": "string", "node": "string", "new_id": "string", "expected_revision": "string?"}},
		"batch": {"params": {"document": "string", "operations": "array", "expected_revision": "string?", "dry_run": "boolean?"}},
		"build": {"params": {"document": "string", "output": "string?", "force": "boolean?", "allow_outside_project": "boolean?"}},
		"build-all": {"params": {"source_dir": "string?", "output_dir": "string?", "force": "boolean?", "allow_outside_project": "boolean?"}},
		"render": {"params": {"document": "string", "viewport": "string?", "output": "string?", "state": "string?", "force": "boolean?", "allow_outside_project": "boolean?"}},
		"shutdown": {"params": {}},
	}

static func _batch_operation_schemas() -> Dictionary:
	return {
		"set": {"node": "string", "property": "string", "value": "any"},
		"add": {"parent": "string", "node": "object"},
		"delete": {"node": "string"},
		"move": {"node": "string", "parent": "string", "index": "integer?"},
		"duplicate": {"node": "string", "new_id": "string"},
	}
