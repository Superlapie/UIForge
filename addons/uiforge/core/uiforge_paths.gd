class_name UIForgePaths
extends RefCounted

enum ArtifactKind { SOURCE, SCENE, IMAGE }

const EXTENSIONS: Dictionary = {
	ArtifactKind.SOURCE: [".ui.json"],
	ArtifactKind.SCENE: [".tscn"],
	ArtifactKind.IMAGE: [".png"],
}

static func workspace_root() -> String:
	return ProjectSettings.globalize_path("res://").replace("\\", "/").trim_suffix("/")

static func normalize_requested(path: String) -> String:
	if path.is_empty():
		return ""
	var trimmed := path.strip_edges()
	if trimmed.begins_with("res://") or trimmed.begins_with("user://"):
		return ProjectSettings.globalize_path(trimmed).replace("\\", "/")
	if trimmed.is_absolute_path():
		return _godot_absolute(trimmed)
	return ProjectSettings.globalize_path("res://%s" % trimmed.replace("\\", "/")).replace("\\", "/")

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

static func resolve_real_path(absolute: String) -> String:
	var path := _godot_absolute(absolute)
	if path.is_empty():
		return path
	var cursor := path
	var suffix := ""
	while not cursor.is_empty() and not DirAccess.dir_exists_absolute(cursor) and not FileAccess.file_exists(cursor):
		var base := cursor.get_file()
		if base.is_empty():
			break
		suffix = "/%s%s" % [base, suffix]
		cursor = cursor.get_base_dir()
	if cursor.is_empty():
		return path
	var resolved_base := _realpath_directory(cursor)
	if suffix.is_empty():
		return resolved_base
	return ("%s%s" % [resolved_base, suffix]).replace("\\", "/").simplify_path()

static func _realpath_directory(dir_path: String) -> String:
	var normalized := _godot_absolute(dir_path)
	if OS.get_name() == "Windows":
		return _windows_resolved_path(normalized)
	var output: Array = []
	var exit_code := OS.execute("realpath", ["-m", normalized], output, true, false)
	if exit_code == 0 and not output.is_empty():
		return str(output[0]).strip_edges().replace("\\", "/")
	return normalized.simplify_path()

static func _windows_resolved_path(path: String) -> String:
	var output: Array = []
	var escaped := path.replace("'", "''")
	var script := (
		"$item = Get-Item -LiteralPath '%s' -Force -ErrorAction SilentlyContinue; "
		+ "if ($null -eq $item) { exit 2 }; "
		+ "Write-Output $item.FullName"
	) % escaped
	var exit_code := OS.execute("powershell", ["-NoProfile", "-Command", script], output, true, false)
	if exit_code == 0 and not output.is_empty():
		return str(output[0]).strip_edges().replace("\\", "/")
	return normalized_fallback(path)

static func normalized_fallback(path: String) -> String:
	return _godot_absolute(path).simplify_path()

static func _godot_absolute(path: String) -> String:
	return path.replace("\\", "/").simplify_path()

static func _is_within_workspace(absolute: String, workspace: String) -> bool:
	var normalized := resolve_real_path(absolute).to_lower() if OS.get_name() == "Windows" else resolve_real_path(absolute)
	var root := resolve_real_path(workspace).to_lower() if OS.get_name() == "Windows" else resolve_real_path(workspace)
	if normalized == root:
		return true
	return normalized.begins_with("%s/" % root)

static func _project_relative(absolute: String) -> String:
	var project := workspace_root()
	var normalized := resolve_real_path(absolute)
	var project_resolved := resolve_real_path(project)
	if OS.get_name() == "Windows":
		normalized = normalized.to_lower()
		project_resolved = project_resolved.to_lower()
	if normalized.begins_with("%s/" % project_resolved):
		var relative := normalized.substr(project_resolved.length() + 1)
		return "res://%s" % relative
	if normalized == project_resolved:
		return "res://"
	return normalized
