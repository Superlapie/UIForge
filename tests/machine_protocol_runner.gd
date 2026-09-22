extends SceneTree

const FIXTURE := "res://tests/conformance/fixtures/minimal.ui.json"

var failures: Array[String] = []
var passed := 0

func _init() -> void:
	_run()

func _run() -> void:
	await _test_capabilities_self_description()
	await _test_machine_validate()
	_test_malformed_request()
	_test_missing_request_id()
	await _test_batch_dry_run()
	await _test_revision_conflict()
	await _test_batch_failure_detail()
	await _test_add_object_form()
	await _test_add_string_form()
	await _test_batch_required_fields()
	await _test_batch_valid_object_add()
	if failures.is_empty():
		print(JSON.stringify({"success": true, "passed": passed, "fixtures": passed}))
		quit(0)
		return
	print(JSON.stringify({"success": false, "passed": passed, "failures": failures}))
	quit(1)

func _test_capabilities_self_description() -> void:
	var response := await UIForgeCommandDispatcher.dispatch_machine({
		"protocol": "uiforge.machine",
		"protocol_version": 1,
		"request_id": "cap-self",
		"method": "capabilities",
		"params": {},
	})
	_assert(bool(response.get("success", false)), "capabilities_success")
	var caps: Dictionary = response.get("result", {}).get("capabilities", {})
	_assert(str(caps.get("machine_protocol", "")) == UIForgeMachineProtocol.PROTOCOL_ID, "capabilities_protocol_id")
	_assert(bool(caps.get("persistent_server", {}).get("supported", false)), "capabilities_persistent")
	_assert(bool(caps.get("batch", {}).get("supported", false)), "capabilities_batch")
	var schemas: Dictionary = caps.get("command_parameter_schemas", {})
	for command in caps.get("available_commands", []):
		_assert(schemas.has(str(command)), "capabilities_schema_%s" % str(command))

func _test_missing_request_id() -> void:
	var validated := UIForgeMachineProtocol.validate_request({
		"protocol": "uiforge.machine",
		"protocol_version": 1,
		"method": "capabilities",
		"params": {},
	})
	_assert(not bool(validated.get("ok", false)), "missing_request_id_failed")
	_assert(str(validated.get("code", "")) == "MALFORMED_REQUEST", "missing_request_id_code")

func _test_machine_validate() -> void:
	var response := await UIForgeCommandDispatcher.dispatch_machine({
		"protocol": "uiforge.machine",
		"protocol_version": 1,
		"request_id": "validate-self",
		"method": "validate",
		"params": {"document": "res://examples/specs/inventory.ui.json"},
	})
	_assert(bool(response.get("success", false)), "machine_validate_success")
	_assert(not str(response.get("result", {}).get("revision", "")).is_empty(), "machine_validate_revision")

func _test_malformed_request() -> void:
	var validated := UIForgeMachineProtocol.validate_request({"method": "validate"})
	_assert(not bool(validated.get("ok", false)), "malformed_request_failed")
	_assert(str(validated.get("code", "")) == "PROTOCOL_MISMATCH", "malformed_request_code")

func _test_batch_dry_run() -> void:
	var fixture := "res://tests/conformance/fixtures/minimal.ui.json"
	var loaded := UIForgeSerializer.load_document(fixture)
	_assert(loaded.get("document") != null, "batch_fixture_loaded")
	var response := await UIForgeCommandDispatcher.dispatch_machine({
		"protocol": "uiforge.machine",
		"protocol_version": 1,
		"request_id": "batch-dry",
		"method": "batch",
		"params": {
			"document": fixture,
			"expected_revision": str(loaded.get("revision_hash", "")),
			"dry_run": true,
			"operations": [
				{"op": "set", "node": "root", "property": "layout.size", "value": "[420,300]"},
			],
		},
	})
	_assert(bool(response.get("success", false)), "batch_dry_run_success")
	_assert(not bool(response.get("result", {}).get("committed", true)), "batch_dry_run_not_committed")

func _test_revision_conflict() -> void:
	var response := await UIForgeCommandDispatcher.dispatch_machine({
		"protocol": "uiforge.machine",
		"protocol_version": 1,
		"request_id": "rev-conflict",
		"method": "batch",
		"params": {
			"document": "res://examples/specs/inventory.ui.json",
			"expected_revision": "sha256:deadbeef",
			"operations": [{"op": "set", "node": "inventory_title", "property": "properties.text", "value": "\"Nope\""}],
		},
	})
	_assert(not bool(response.get("success", false)), "revision_conflict_failed")
	_assert(str(response.get("error", {}).get("code", "")) == "REVISION_CONFLICT", "revision_conflict_code")
	_assert(bool(response.get("result", {}).get("committed", true)) == false, "revision_conflict_committed_false")

func _test_batch_failure_detail() -> void:
	var response := await UIForgeCommandDispatcher.dispatch_machine({
		"protocol": "uiforge.machine",
		"protocol_version": 1,
		"request_id": "batch-fail-detail",
		"method": "batch",
		"params": {
			"document": "res://tests/conformance/fixtures/minimal.ui.json",
			"operations": [{"op": "set", "node": "missing_node", "property": "layout.size", "value": "[1,1]"}],
		},
	})
	_assert(not bool(response.get("success", false)), "batch_failure")
	_assert(response.get("result", {}).get("failed_index", -1) >= 0, "batch_failed_index")
	_assert(not bool(response.get("result", {}).get("committed", true)), "batch_failure_committed_false")

func _test_add_object_form() -> void:
	var temp_doc := _copy_temp_document("add_object")
	var response := await UIForgeCommandDispatcher.dispatch_machine({
		"protocol": "uiforge.machine",
		"protocol_version": 1,
		"request_id": "add-object",
		"method": "add",
		"params": {
			"document": temp_doc,
			"parent": "root",
			"node": {
				"id": "machine_added_panel",
				"type": "Panel",
				"layout": {"position": [10, 10], "size": [100, 80]},
				"children": [],
			},
		},
	})
	_assert(bool(response.get("success", false)), "add_object_success")
	var inspect := await UIForgeCommandDispatcher.dispatch_machine({
		"protocol": "uiforge.machine",
		"protocol_version": 1,
		"request_id": "add-object-inspect",
		"method": "get",
		"params": {"document": temp_doc, "node": "machine_added_panel", "property": "layout.size"},
	})
	_assert(bool(inspect.get("success", false)), "add_object_node_exists")

func _test_add_string_form() -> void:
	var temp_doc := _copy_temp_document("add_string")
	var response := await UIForgeCommandDispatcher.dispatch_machine({
		"protocol": "uiforge.machine",
		"protocol_version": 1,
		"request_id": "add-string",
		"method": "add",
		"params": {
			"document": temp_doc,
			"parent": "root",
			"node": "{\"id\":\"machine_added_panel_str\",\"type\":\"Panel\",\"layout\":{\"position\":[10,10],\"size\":[100,80]},\"children\":[]}",
		},
	})
	_assert(bool(response.get("success", false)), "add_string_success")
	var inspect := await UIForgeCommandDispatcher.dispatch_machine({
		"protocol": "uiforge.machine",
		"protocol_version": 1,
		"request_id": "add-string-inspect",
		"method": "get",
		"params": {"document": temp_doc, "node": "machine_added_panel_str", "property": "layout.size"},
	})
	_assert(bool(inspect.get("success", false)), "add_string_node_exists")

func _test_batch_required_fields() -> void:
	var temp_doc := _copy_temp_document("batch_required")
	var response_set := await UIForgeCommandDispatcher.dispatch_machine({
		"protocol": "uiforge.machine",
		"protocol_version": 1,
		"request_id": "batch-missing-set",
		"method": "batch",
		"params": {"document": temp_doc, "operations": [{"op": "set", "node": "root"}]},
	})
	_assert(not bool(response_set.get("success", false)), "batch_missing_set_fields_failed")
	_assert(str(response_set.get("error", {}).get("code", "")) == "MALFORMED_PARAMS", "batch_missing_set_fields_code")
	var response_move := await UIForgeCommandDispatcher.dispatch_machine({
		"protocol": "uiforge.machine",
		"protocol_version": 1,
		"request_id": "batch-missing-move",
		"method": "batch",
		"params": {"document": temp_doc, "operations": [{"op": "move", "node": "child_a"}]},
	})
	_assert(not bool(response_move.get("success", false)), "batch_missing_move_parent_failed")
	_assert(str(response_move.get("error", {}).get("code", "")) == "MALFORMED_PARAMS", "batch_missing_move_parent_code")
	var response_duplicate := await UIForgeCommandDispatcher.dispatch_machine({
		"protocol": "uiforge.machine",
		"protocol_version": 1,
		"request_id": "batch-missing-duplicate",
		"method": "batch",
		"params": {"document": temp_doc, "operations": [{"op": "duplicate", "node": "child_a"}]},
	})
	_assert(not bool(response_duplicate.get("success", false)), "batch_missing_duplicate_new_id_failed")
	_assert(str(response_duplicate.get("error", {}).get("code", "")) == "MALFORMED_PARAMS", "batch_missing_duplicate_new_id_code")
	var response_add := await UIForgeCommandDispatcher.dispatch_machine({
		"protocol": "uiforge.machine",
		"protocol_version": 1,
		"request_id": "batch-missing-add",
		"method": "batch",
		"params": {"document": temp_doc, "operations": [{"op": "add", "parent": "root"}]},
	})
	_assert(not bool(response_add.get("success", false)), "batch_missing_add_node_failed")
	_assert(str(response_add.get("error", {}).get("code", "")) == "MALFORMED_PARAMS", "batch_missing_add_node_code")

func _test_batch_valid_object_add() -> void:
	var temp_doc := _copy_temp_document("batch_valid_add")
	var before := FileAccess.get_file_as_string(ProjectSettings.globalize_path(temp_doc))
	var response := await UIForgeCommandDispatcher.dispatch_machine({
		"protocol": "uiforge.machine",
		"protocol_version": 1,
		"request_id": "batch-valid-add",
		"method": "batch",
		"params": {
			"document": temp_doc,
			"dry_run": true,
			"operations": [{
				"op": "add",
				"parent": "root",
				"node": {"id": "batch_added_panel", "type": "Panel", "layout": {"size": [32, 32]}, "children": []},
			}],
		},
	})
	_assert(bool(response.get("success", false)), "batch_valid_object_add_success")
	_assert(FileAccess.get_file_as_string(ProjectSettings.globalize_path(temp_doc)) == before, "batch_valid_object_add_no_write")

func _copy_temp_document(label: String) -> String:
	var temp_dir := "user://machine_protocol_temp"
	DirAccess.make_dir_recursive_absolute(temp_dir)
	var temp_res := "%s/%s.ui.json" % [temp_dir, label]
	DirAccess.copy_absolute(ProjectSettings.globalize_path(FIXTURE), ProjectSettings.globalize_path(temp_res))
	return temp_res

func _assert(condition: bool, name: String) -> void:
	if condition:
		passed += 1
		return
	failures.append(name)
