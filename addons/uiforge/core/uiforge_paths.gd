class_name UIForgePaths
extends RefCounted

enum ArtifactKind { SOURCE, SCENE, IMAGE }

const EXTENSIONS: Dictionary = {
	ArtifactKind.SOURCE: [".ui.json"],
	ArtifactKind.SCENE: [".tscn"],
	ArtifactKind.IMAGE: [".png"],
}

static var windows_resolver_force_failure: bool = false

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
	if not allow_outside_project:
		var containment := _containment_check(absolute, workspace_root())
		if not containment.get("ok", false):
			errors.append({
				"code": str(containment.get("code", "PATH_CANONICALIZATION_FAILED")),
				"message": str(containment.get("message", "Could not canonicalize output path for workspace containment.")),
				"path": path,
			})
		elif not bool(containment.get("within", false)):
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
	if OS.get_name() == "Windows":
		var resolved := resolve_physical_path(path)
		if resolved.get("ok", false):
			return str(resolved.get("path", path))
		return normalized_fallback(path)
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

static func resolve_physical_path(absolute: String) -> Dictionary:
	var path := _godot_absolute(absolute)
	if path.is_empty():
		return {"ok": false, "code": "PATH_CANONICALIZATION_FAILED", "message": "Empty path cannot be canonicalized."}
	if OS.get_name() == "Windows":
		return _windows_canonical_path_secure(path)
	var cursor := path
	var suffix := ""
	while not cursor.is_empty() and not DirAccess.dir_exists_absolute(cursor) and not FileAccess.file_exists(cursor):
		var base := cursor.get_file()
		if base.is_empty():
			break
		suffix = "/%s%s" % [base, suffix]
		cursor = cursor.get_base_dir()
	if cursor.is_empty():
		return {"ok": false, "code": "PATH_CANONICALIZATION_FAILED", "message": "Could not resolve existing prefix for %s." % path}
	var resolved_base := _realpath_directory_secure(cursor)
	if not resolved_base.get("ok", false):
		return resolved_base
	var resolved_path := str(resolved_base.get("path", cursor))
	if not suffix.is_empty():
		resolved_path = ("%s%s" % [resolved_path, suffix]).replace("\\", "/").simplify_path()
	return {"ok": true, "path": resolved_path}

static func _windows_canonical_path_secure(path: String) -> Dictionary:
	var cursor := path
	var suffix := ""
	while not cursor.is_empty() and not DirAccess.dir_exists_absolute(cursor) and not FileAccess.file_exists(cursor):
		var base := cursor.get_file()
		if base.is_empty():
			break
		suffix = "/%s%s" % [base, suffix]
		cursor = cursor.get_base_dir()
	if cursor.is_empty():
		cursor = path
	var resolved_base := _windows_resolve_existing_prefix_secure(cursor)
	if not resolved_base.get("ok", false):
		return resolved_base
	var resolved_path := str(resolved_base.get("path", cursor))
	if not suffix.is_empty():
		resolved_path = ("%s%s" % [resolved_path, suffix]).replace("\\", "/").simplify_path()
	return {"ok": true, "path": resolved_path}

static func _windows_resolve_existing_prefix_secure(existing_path: String) -> Dictionary:
	if windows_resolver_force_failure:
		return {
			"ok": false,
			"code": "PATH_CANONICALIZATION_FAILED",
			"message": "Windows path canonicalization is unavailable for %s." % existing_path,
		}
	var output: Array = []
	var escaped := existing_path.replace("'", "''")
	var script := (
		"function Resolve-UIForgeExistingPath([string]$InputPath) { "
		+ "$InputPath = $InputPath -replace '/','\\'; "
		+ "if (-not [System.IO.Path]::IsPathRooted($InputPath)) { Write-Output ($InputPath -replace '\\\\','/'); exit 0 }; "
		+ "$parts = New-Object System.Collections.Generic.List[string]; "
		+ "$current = $InputPath; "
		+ "while ($true) { "
		+ "$parent = [System.IO.Path]::GetDirectoryName($current); "
		+ "$leaf = [System.IO.Path]::GetFileName($current); "
		+ "if ($leaf) { $parts.Insert(0, $leaf) }; "
		+ "if ([string]::IsNullOrEmpty($parent) -or $parent -eq $current) { "
		+ "if (-not $leaf -and $current) { $parts.Insert(0, $current.TrimEnd('\\')) }; break }; "
		+ "$current = $parent }; "
		+ "if ($parts.Count -eq 0) { Write-Output ($InputPath -replace '\\\\','/'); exit 0 }; "
		+ "$resolved = $parts[0]; "
		+ "if ($resolved -match '^[A-Za-z]:$') { $resolved = $resolved + '\\' }; "
		+ "for ($i = 1; $i -lt $parts.Count; $i++) { "
		+ "$candidate = Join-Path $resolved $parts[$i]; "
		+ "if (-not (Test-Path -LiteralPath $candidate)) { $resolved = $candidate; continue }; "
		+ "$item = Get-Item -LiteralPath $candidate -Force; "
		+ "if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { "
		+ "$target = $item.Target; "
		+ "if ($target -is [System.Array]) { $target = $target[0] }; "
		+ "if ($target -and -not [System.IO.Path]::IsPathRooted($target)) { "
		+ "$target = Join-Path ([System.IO.Path]::GetDirectoryName($candidate)) $target }; "
		+ "$resolved = [System.IO.Path]::GetFullPath($target) "
		+ "} else { $resolved = $item.FullName } }; "
		+ "Write-Output ($resolved -replace '\\\\','/') }; "
		+ "Resolve-UIForgeExistingPath '%s'"
	) % escaped
	var exit_code := OS.execute("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", script], output, true, false)
	if exit_code == 0 and not output.is_empty():
		return {"ok": true, "path": str(output[0]).strip_edges().replace("\\", "/")}
	return {
		"ok": false,
		"code": "PATH_CANONICALIZATION_FAILED",
		"message": "Windows path canonicalization failed for %s." % existing_path,
	}

static func _realpath_directory_secure(dir_path: String) -> Dictionary:
	var normalized := _godot_absolute(dir_path)
	if OS.get_name() == "Windows":
		return _windows_resolve_existing_prefix_secure(normalized)
	var output: Array = []
	var exit_code := OS.execute("realpath", ["-m", normalized], output, true, false)
	if exit_code == 0 and not output.is_empty():
		return {"ok": true, "path": str(output[0]).strip_edges().replace("\\", "/")}
	return {
		"ok": false,
		"code": "PATH_CANONICALIZATION_FAILED",
		"message": "Could not canonicalize directory %s." % normalized,
	}

static func _realpath_directory(dir_path: String) -> String:
	var resolved := _realpath_directory_secure(dir_path)
	if resolved.get("ok", false):
		return str(resolved.get("path", dir_path))
	return normalized_fallback(dir_path)

static func normalized_fallback(path: String) -> String:
	return _godot_absolute(path).simplify_path()

static func _godot_absolute(path: String) -> String:
	return path.replace("\\", "/").simplify_path()

static func _containment_check(absolute: String, workspace: String) -> Dictionary:
	var resolved := resolve_physical_path(absolute)
	if not resolved.get("ok", false):
		return resolved
	var root := resolve_physical_path(workspace)
	if not root.get("ok", false):
		return root
	var normalized := str(resolved.get("path", ""))
	var project_resolved := str(root.get("path", ""))
	if OS.get_name() == "Windows":
		normalized = normalized.to_lower()
		project_resolved = project_resolved.to_lower()
	if normalized == project_resolved:
		return {"ok": true, "within": true}
	return {"ok": true, "within": normalized.begins_with("%s/" % project_resolved)}

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
