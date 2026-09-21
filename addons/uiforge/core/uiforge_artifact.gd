class_name UIForgeArtifact
extends RefCounted

const HEADER_VERSION: String = "UIFORGE_GENERATED_V1"
const GENERATOR_VERSION: String = "uiforge/0.1.0"

static func provenance_header(source_identity: String, source_hash: String) -> Array[String]:
	return [
		"; %s" % HEADER_VERSION,
		"; uiforge_source: %s" % source_identity,
		"; uiforge_source_hash: %s" % source_hash,
		"; uiforge_generator: %s" % GENERATOR_VERSION,
		"; uiforge_schema: %d" % UIForgeTypes.SCHEMA_VERSION,
		"; %s" % UIForgeTypes.GENERATED_MARKER,
	]

static func build_scene_header(source_identity: String, source_hash: String) -> String:
	return "\n".join(provenance_header(source_identity, source_hash))

static func parse_scene_header(text: String) -> Dictionary:
	var lines := text.split("\n", false)
	var result := {
		"is_uiforge": false,
		"version": "",
		"source": "",
		"source_hash": "",
		"generator": "",
		"schema": -1,
	}
	for line in lines:
		var trimmed := str(line).strip_edges()
		if not trimmed.begins_with(";"):
			break
		if trimmed == "; %s" % HEADER_VERSION:
			result["is_uiforge"] = true
			result["version"] = HEADER_VERSION
			continue
		if trimmed.begins_with("; uiforge_source:"):
			result["source"] = trimmed.substr("; uiforge_source:".length()).strip_edges()
		elif trimmed.begins_with("; uiforge_source_hash:"):
			result["source_hash"] = trimmed.substr("; uiforge_source_hash:".length()).strip_edges()
		elif trimmed.begins_with("; uiforge_generator:"):
			result["generator"] = trimmed.substr("; uiforge_generator:".length()).strip_edges()
		elif trimmed.begins_with("; uiforge_schema:"):
			result["schema"] = int(trimmed.substr("; uiforge_schema:".length()).strip_edges())
	return result

static func check_replace_allowed(output_path: String, source_identity: String, source_hash: String, force: bool) -> Dictionary:
	if force:
		return {"ok": true, "errors": []}
	var absolute := UIForgePaths.normalize_requested(output_path)
	if not FileAccess.file_exists(absolute):
		return {"ok": true, "errors": []}
	var file := FileAccess.open(absolute, FileAccess.READ)
	if file == null:
		return {"ok": false, "errors": [{"code": "OUTPUT_OPEN_FAILED", "message": "Could not read existing output: %s" % output_path}]}
	var header := parse_scene_header(file.get_as_text())
	file.close()
	if not header.get("is_uiforge", false):
		return {
			"ok": false,
			"errors": [{
				"code": "OUTPUT_NOT_UIFORGE_GENERATED",
				"message": "Refusing to overwrite '%s' because it is not a UIForge-generated artifact. Pass --force to override." % output_path,
				"path": output_path,
			}],
		}
	var existing_source := str(header.get("source", ""))
	var existing_hash := str(header.get("source_hash", ""))
	if existing_source != source_identity or existing_hash != source_hash:
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
