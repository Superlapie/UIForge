extends SceneTree

const MANIFEST_PATH := "res://tests/conformance/manifest.json"
const FIXTURES_DIR := "res://tests/conformance/fixtures/"

var failures: Array[String] = []

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var manifest := _load_manifest()
	for vector in manifest.get("validation_vectors", []):
		_run_validation_vector(vector)
	if failures.is_empty():
		print(JSON.stringify({"success": true, "passed": manifest.get("validation_vectors", []).size(), "failed": 0}))
		quit(0)
	else:
		print(JSON.stringify({"success": false, "passed": manifest.get("validation_vectors", []).size() - failures.size(), "failed": failures.size(), "failures": failures}, "\t"))
		quit(1)

func _load_manifest() -> Dictionary:
	var text := FileAccess.get_file_as_string(MANIFEST_PATH)
	var parser := JSON.new()
	if parser.parse(text) != OK or not parser.data is Dictionary:
		failures.append("manifest_load_failed")
		return {}
	return parser.data

func _run_validation_vector(vector: Dictionary) -> void:
	var vector_id := str(vector.get("id", "unknown"))
	var relative_path := str(vector.get("file", ""))
	var expect_valid := bool(vector.get("expect_valid", false))
	var expect_codes: Array = vector.get("expect_codes", [])
	var document_path := "%s%s" % [FIXTURES_DIR, relative_path]
	var loaded := UIForgeSerializer.load_document(document_path)
	if loaded.get("document") == null:
		_fail(vector_id, "document_load_failed")
		return
	var validation := UIForgeValidator.new().validate(loaded["document"])
	if validation.success != expect_valid:
		_fail(vector_id, "validator_success_mismatch")
		return
	var codes := _diagnostic_codes(validation.get("diagnostics", []))
	for code in expect_codes:
		if str(code) not in codes:
			_fail(vector_id, "missing_code_%s" % code)
	var cli_result := _run_cli_validate(document_path)
	if bool(cli_result.get("success", false)) != expect_valid:
		_fail(vector_id, "cli_success_mismatch")
	var cli_codes := _diagnostic_codes(cli_result.get("diagnostics", []))
	for code in expect_codes:
		if str(code) not in cli_codes:
			_fail(vector_id, "cli_missing_code_%s" % code)

func _run_cli_validate(document_path: String) -> Dictionary:
	var project_dir := ProjectSettings.globalize_path("res://")
	var ui_script := "%s/scripts/ui" % project_dir
	var output: Array = []
	var exit_code := OS.execute("/bin/sh", [ui_script, "validate", document_path], output, true, false)
	var stdout := "\n".join(output)
	var parser := JSON.new()
	for index in stdout.length():
		if stdout[index] != "{":
			continue
		if parser.parse(stdout.substr(index)) == OK and parser.data is Dictionary:
			return parser.data
	return {"success": false, "diagnostics": [{"code": "CLI_JSON_PARSE_FAILED", "message": stdout}]}

func _diagnostic_codes(diagnostics: Variant) -> Array[String]:
	var codes: Array[String] = []
	if diagnostics is Array:
		for diagnostic in diagnostics:
			if diagnostic is Dictionary:
				codes.append(str(diagnostic.get("code", "")))
	return codes

func _fail(vector_id: String, reason: String) -> void:
	failures.append("%s:%s" % [vector_id, reason])
