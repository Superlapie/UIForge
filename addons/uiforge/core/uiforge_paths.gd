class_name UIForgePaths
extends RefCounted

enum ArtifactKind { SOURCE, SCENE, IMAGE }

const EXTENSIONS: Dictionary = {
	ArtifactKind.SOURCE: [".ui.json"],
	ArtifactKind.SCENE: [".tscn"],
	ArtifactKind.IMAGE: [".png"],
}

static func workspace_root() -> String:
	return ProjectSettings.globalize_path("res://").trim_suffix("/")

static func normalize_requested(path: String) -> String:
	if path.is_empty():
		return ""
	var trimmed := path.strip_edges()
	if trimmed.begins_with("res://") or trimmed.begins_with("user://"):
		return ProjectSettings.globalize_path(trimmed)
	if not trimmed.begins_with("/"):
		return ProjectSettings.globalize_path("res://%s" % trimmed.replace("\\", "/"))
	return _canonical_absolute(trimmed)

static func validate_output(path: String, kind: ArtifactKind, allow_outside_project: bool) -> Dictionary:
	var errors: Array = []
	if path.is_empty():
		errors.append({"code": "OUTPUT_PATH_MISSING", "message": "An output path is required."})
		return {"ok": false, "normalized": "", "errors": errors}
	var absolute := normalize_requested(path)
	if absolute.is_empty():
		errors.append({"code": "OUTPUT_PATH_INVALID", "message": "Output path '%s' is invalid." % path})
		return {"ok": false, "normalized": "", "errors": errors}
	var expected: Array = EXTENSIONS.get(kind, [])
	var valid_extension := false
	for allowed in expected:
		if absolute.ends_with(str(allowed)):
			valid_extension = true
			break
	if not valid_extension:
		errors.append({
			"code": "OUTPUT_EXTENSION_INVALID",
			"message": "Output '%s' must use one of: %s." % [path, ", ".join(PackedStringArray(expected))],
			"path": path,
		})
	var workspace := workspace_root()
	if not allow_outside_project and not _is_within_workspace(absolute, workspace):
		errors.append({
			"code": "OUTPUT_OUTSIDE_WORKSPACE",
			"message": "Output '%s' is outside the project workspace. Pass --allow-outside-project to override." % path,
			"path": path,
		})
	return {"ok": errors.is_empty(), "normalized": absolute, "project_relative": _project_relative(absolute), "errors": errors}

static func validate_source_read(path: String) -> Dictionary:
	var checked := validate_output(path, ArtifactKind.SOURCE, true)
	if not checked.ok and checked.errors.size() == 1 and str(checked.errors[0].get("code", "")) == "OUTPUT_EXTENSION_INVALID":
		return {"ok": true, "normalized": checked.normalized, "project_relative": checked.project_relative, "errors": []}
	return checked

static func _canonical_absolute(path: String) -> String:
	var value := path.strip_edges().replace("\\", "/")
	var absolute := value.begins_with("/")
	var parts: Array[String] = []
	for part in value.split("/"):
		if part.is_empty() or part == ".":
			continue
		if part == "..":
			if not parts.is_empty():
				parts.pop_back()
			continue
		parts.append(part)
	var joined := "/".join(parts)
	if absolute:
		return "/%s" % joined
	return joined

static func _is_within_workspace(absolute: String, workspace: String) -> bool:
	var normalized := _canonical_absolute(absolute)
	var root := _canonical_absolute(workspace)
	if normalized == root:
		return true
	return normalized.begins_with("%s/" % root)

static func _project_relative(absolute: String) -> String:
	var project := workspace_root()
	var normalized := _canonical_absolute(absolute)
	if normalized.begins_with("%s/" % project):
		var relative := normalized.substr(project.length() + 1)
		return "res://%s" % relative
	if normalized == project:
		return "res://"
	return normalized
