extends SceneTree

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

func _assert(condition: bool, name: String) -> void:
	if condition:
		passed += 1
		return
	failures.append(name)
