class_name UIForgeArtifact
extends RefCounted

const HEADER_VERSION: String = "UIFORGE_GENERATED_V1"
const GENERATOR_VERSION: String = "uiforge/0.1.0"
const MAX_HEADER_LINES: int = 32

static var _hash_pattern: RegEx

static func _hash_regex() -> RegEx:
	if _hash_pattern == null:
		_hash_pattern = RegEx.create_from_string("^sha256:[0-9a-f]{64}$")
	return _hash_pattern

static func provenance_header(source_identity: String, source_hash: String) -> Array[String]:
	return [
		"; %s" % HEADER_VERSION,
		"; uiforge_source: %s" % source_identity,
		"; uiforge_source_hash: %s" % source_hash,
		"; uiforge_generator: %s" % GENERATOR_VERSION,
		"; uiforge_schema: %d" % UIForgeTypes.SCHEMA_VERSION,
		"; %s" % UIForgeTypes.GENERATED_MARKER,
	]

static func read_existing_output(output_path: String) -> Dictionary:
	var absolute := UIForgePaths.normalize_requested(output_path)
	if absolute.is_empty():
		return {"ok": false, "errors": [{"code": "OUTPUT_PATH_INVALID", "message": output_path}]}
	if not FileAccess.file_exists(absolute):
		return {"ok": true, "exists": false, "text": "", "header": {}, "errors": []}
	var file := FileAccess.open(absolute, FileAccess.READ)
	if file == null:
		return {"ok": false, "errors": [{"code": "OUTPUT_OPEN_FAILED", "message": "Could not read existing output: %s" % output_path, "path": output_path}]}
	var text := file.get_as_text()
	file.close()
	var parsed := parse_scene_header(text)
	if not parsed.get("ok", false):
		return {"ok": false, "exists": true, "text": text, "header": parsed.get("header", {}), "errors": parsed.get("errors", [])}
	return {"ok": true, "exists": true, "text": text, "header": parsed.get("header", {}), "errors": []}

static func parse_scene_header(text: Variant) -> Dictionary:
	var header := {
		"is_uiforge": false,
		"version": "",
		"source": "",
		"source_hash": "",
		"generator": "",
		"schema": -1,
		"trusted": false,
	}
	var errors: Array = []
	if text == null:
		errors.append(_parse_error("OUTPUT_READ_FAILED", "Output text was null."))
		return {"ok": errors.is_empty(), "header": header, "errors": errors}
	var raw := str(text)
	if raw.is_empty():
		return {"ok": true, "header": header, "errors": errors}
	var duplicate_versions := 0
	var duplicate_sources := 0
	var duplicate_hashes := 0
	var comment_lines := 0
	for line in raw.split("\n", false):
		var trimmed := str(line).strip_edges()
		if not trimmed.begins_with(";"):
			break
		comment_lines += 1
		if comment_lines > MAX_HEADER_LINES:
			errors.append(_parse_error("OUTPUT_PROVENANCE_INVALID", "Provenance preamble exceeds supported size."))
			break
		if trimmed == "; %s" % HEADER_VERSION:
			duplicate_versions += 1
			header["is_uiforge"] = true
			header["version"] = HEADER_VERSION
			continue
		if trimmed.begins_with("; uiforge_source:"):
			duplicate_sources += 1
			header["source"] = trimmed.substr("; uiforge_source:".length()).strip_edges()
			continue
		if trimmed.begins_with("; uiforge_source_hash:"):
			duplicate_hashes += 1
			header["source_hash"] = trimmed.substr("; uiforge_source_hash:".length()).strip_edges()
			continue
		if trimmed.begins_with("; uiforge_generator:"):
			header["generator"] = trimmed.substr("; uiforge_generator:".length()).strip_edges()
			continue
		if trimmed.begins_with("; uiforge_schema:"):
			var schema_text := trimmed.substr("; uiforge_schema:".length()).strip_edges()
			if not schema_text.is_valid_int():
				errors.append(_parse_error("OUTPUT_PROVENANCE_INVALID", "Malformed uiforge_schema value."))
			else:
				header["schema"] = int(schema_text)
	if duplicate_versions > 1 or duplicate_sources > 1 or duplicate_hashes > 1:
		errors.append(_parse_error("OUTPUT_PROVENANCE_INVALID", "Duplicate provenance header fields."))
	if header.get("is_uiforge", false):
		errors.append_array(validate_provenance(header))
	header["trusted"] = header.get("is_uiforge", false) and errors.is_empty()
	return {"ok": errors.is_empty(), "header": header, "errors": errors}

static func validate_provenance(header: Dictionary) -> Array:
	var errors: Array = []
	var version := str(header.get("version", ""))
	if version != HEADER_VERSION:
		errors.append(_parse_error("OUTPUT_PROVENANCE_INVALID", "Unsupported provenance version '%s'." % version))
	if str(header.get("source", "")).is_empty():
		errors.append(_parse_error("OUTPUT_PROVENANCE_INVALID", "Missing uiforge_source."))
	var hash_value := str(header.get("source_hash", ""))
	if hash_value.is_empty():
		errors.append(_parse_error("OUTPUT_PROVENANCE_INVALID", "Missing uiforge_source_hash."))
	elif _hash_regex().search(hash_value) == null:
		errors.append(_parse_error("OUTPUT_PROVENANCE_INVALID", "Malformed uiforge_source_hash."))
	if str(header.get("generator", "")).is_empty():
		errors.append(_parse_error("OUTPUT_PROVENANCE_INVALID", "Missing uiforge_generator."))
	var schema := int(header.get("schema", -1))
	if schema < 0:
		errors.append(_parse_error("OUTPUT_PROVENANCE_INVALID", "Missing or malformed uiforge_schema."))
	return errors

static func check_replace_allowed(output_path: String, source_identity: String, _source_hash: String, force: bool) -> Dictionary:
	if force:
		return {"ok": true, "errors": []}
	var existing := read_existing_output(output_path)
	if not existing.get("ok", false):
		return {"ok": false, "errors": existing.get("errors", [])}
	if not existing.get("exists", false):
		return {"ok": true, "errors": []}
	var header: Dictionary = existing.get("header", {})
	if not header.get("is_uiforge", false):
		return {
			"ok": false,
			"errors": [{
				"code": "OUTPUT_NOT_UIFORGE_GENERATED",
				"message": "Refusing to overwrite '%s' because it is not a UIForge-generated artifact. Pass --force to override." % output_path,
				"path": output_path,
			}],
		}
	if not header.get("trusted", false):
		return {
			"ok": false,
			"errors": existing.get("errors", [{
				"code": "OUTPUT_PROVENANCE_INVALID",
				"message": "Existing output '%s' has invalid UIForge provenance." % output_path,
				"path": output_path,
			}]),
		}
	var existing_source := str(header.get("source", ""))
	if existing_source != source_identity:
		return {
			"ok": false,
			"errors": [{
				"code": "OUTPUT_SOURCE_MISMATCH",
				"message": "Refusing to overwrite '%s' generated from a different source. Pass --force to override." % output_path,
				"path": output_path,
				"existing_source": existing_source,
				"requested_source": source_identity,
			}],
		}
	return {"ok": true, "errors": []}

static func check_commit_replace_allowed(output_path: String, source_identity: String, force: bool) -> Dictionary:
	return check_replace_allowed(output_path, source_identity, "", force)

static func check_create_allowed(output_path: String, force: bool) -> Dictionary:
	if force or not FileAccess.file_exists(UIForgePaths.normalize_requested(output_path)):
		return {"ok": true, "errors": []}
	return {
		"ok": false,
		"errors": [{
			"code": "OUTPUT_ALREADY_EXISTS",
			"message": "Refusing to overwrite existing '%s'. Pass --force to replace it." % output_path,
			"path": output_path,
		}],
	}

static func source_identity(source_path: String) -> String:
	var checked := UIForgePaths.validate_source_read(source_path)
	if checked.ok and not str(checked.get("project_relative", "")).is_empty():
		return str(checked.project_relative)
	return source_path.replace("\\", "/")

static func _parse_error(code: String, message: String) -> Dictionary:
	return {"code": code, "message": message}
