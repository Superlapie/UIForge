class_name UIForgeTheme
extends RefCounted

var data: Dictionary = {}
var tokens: Dictionary = {}

func _init(theme_data: Dictionary = {}) -> void:
	data = theme_data.duplicate(true)
	tokens = data.get("tokens", {}) if data.get("tokens", {}) is Dictionary else {}

static func available_theme_names() -> Array[String]:
	var names: Array[String] = []
	var directory := DirAccess.open("res://addons/uiforge/themes")
	if directory == null:
		return names
	directory.list_dir_begin()
	var filename := directory.get_next()
	while not filename.is_empty():
		if not directory.current_is_dir() and filename.ends_with(".theme.json"):
			names.append(filename.trim_suffix(".theme.json"))
		filename = directory.get_next()
	directory.list_dir_end()
	names.sort()
	return names

static func is_valid_theme_identifier(theme_name: String) -> bool:
	var normalized := str(theme_name).strip_edges()
	if normalized.is_empty() or normalized != theme_name:
		return false
	if "/" in normalized or "\\" in normalized or ".." in normalized or "." in normalized:
		return false
	for ch in normalized:
		if ord(ch) < 32:
			return false
	var pattern := RegEx.create_from_string("^[A-Za-z0-9_-]+$")
	return pattern.search(normalized) != null

static func load_named_checked(theme_name: String) -> Dictionary:
	var normalized := str(theme_name).strip_edges()
	if normalized.is_empty():
		return {"theme": null, "errors": [{"severity": "error", "code": "THEME_NOT_FOUND", "message": "Document theme name is required.", "recommendation": "Set theme to one of: %s." % ", ".join(available_theme_names())}]}
	if not is_valid_theme_identifier(normalized):
		return {
			"theme": null,
			"errors": [{
				"severity": "error",
				"code": "THEME_NAME_INVALID",
				"message": "Theme name '%s' is not a valid identifier." % normalized,
				"recommendation": "Use an exact theme id from addons/uiforge/themes/*.theme.json.",
			}],
		}
	var available := available_theme_names()
	if not normalized in available:
		return {
			"theme": null,
			"errors": [{
				"severity": "error",
				"code": "THEME_NOT_FOUND",
				"message": "Theme '%s' was not found." % normalized,
				"recommendation": "Choose one of: %s." % ", ".join(available),
			}],
		}
	var path := "res://addons/uiforge/themes/%s.theme.json" % normalized
	if not FileAccess.file_exists(path):
		return {
			"theme": null,
			"errors": [{
				"severity": "error",
				"code": "THEME_NOT_FOUND",
				"message": "Theme '%s' was not found." % normalized,
				"recommendation": "Choose one of: %s." % ", ".join(available_theme_names()),
			}],
		}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"theme": null, "errors": [{"severity": "error", "code": "THEME_PARSE_ERROR", "message": "Could not open theme '%s'." % normalized}]}
	var parser := JSON.new()
	var error := parser.parse(file.get_as_text())
	file.close()
	if error != OK or not parser.data is Dictionary:
		return {"theme": null, "errors": [{"severity": "error", "code": "THEME_PARSE_ERROR", "message": parser.get_error_message(), "line": parser.get_error_line()}]}
	return {"theme": UIForgeTheme.new(parser.data), "errors": []}

static func load_named(theme_name: String) -> UIForgeTheme:
	var loaded := load_named_checked(theme_name)
	return loaded.theme if loaded.theme != null else UIForgeTheme.new({})

static func from_document_checked(document: UIForgeDocument) -> Dictionary:
	var theme_name := str(document.data.get("theme", ""))
	var loaded := load_named_checked(theme_name)
	if loaded.theme == null:
		return loaded
	var result: UIForgeTheme = loaded.theme
	var overrides: Variant = document.data.get("theme_overrides", {})
	if overrides == null:
		return {"theme": result, "errors": []}
	if not overrides is Dictionary:
		return {
			"theme": null,
			"errors": [{
				"severity": "error",
				"code": "THEME_OVERRIDES_INVALID",
				"message": "theme_overrides must be an object.",
				"node": "document",
				"recommendation": "Use theme_overrides: { tokens: {}, styles: {} }.",
			}],
		}
	var override_tokens: Variant = overrides.get("tokens", {})
	var override_styles: Variant = overrides.get("styles", {})
	if overrides.has("tokens") and not override_tokens is Dictionary:
		return {"theme": null, "errors": [{"severity": "error", "code": "THEME_OVERRIDES_INVALID", "message": "theme_overrides.tokens must be an object.", "node": "document"}]}
	if overrides.has("styles") and not override_styles is Dictionary:
		return {"theme": null, "errors": [{"severity": "error", "code": "THEME_OVERRIDES_INVALID", "message": "theme_overrides.styles must be an object.", "node": "document"}]}
	if override_tokens is Dictionary:
		var merged_tokens: Dictionary = result.tokens.duplicate(true)
		_deep_merge(merged_tokens, override_tokens)
		result.tokens = merged_tokens
		result.data["tokens"] = result.tokens
	if override_styles is Dictionary:
		var styles: Dictionary = result.data.get("styles", {}) if result.data.get("styles", {}) is Dictionary else {}
		styles.merge(override_styles, true)
		result.data["styles"] = styles
	return {"theme": result, "errors": []}

static func from_document(document: UIForgeDocument) -> UIForgeTheme:
	var loaded := from_document_checked(document)
	return loaded.theme if loaded.get("theme") != null else UIForgeTheme.new({})

static func _deep_merge(target: Dictionary, source: Dictionary) -> void:
	for key in source:
		if target.get(key) is Dictionary and source[key] is Dictionary:
			_deep_merge(target[key], source[key])
		else:
			target[key] = source[key]

func resolve(reference: Variant, fallback: Variant = null) -> Variant:
	if not reference is String or not str(reference).begins_with("$"):
		return reference
	var path := str(reference).substr(1).split(".")
	var value: Variant = tokens
	for part in path:
		if not value is Dictionary or not value.has(part):
			return fallback
		value = value[part]
	return value

func resolve_recursive(value: Variant) -> Variant:
	if value is String and str(value).begins_with("$"):
		return resolve(value, value)
	if value is Dictionary:
		var result: Dictionary = {}
		for key in value:
			result[key] = resolve_recursive(value[key])
		return result
	if value is Array:
		var result_array: Array = []
		for entry in value:
			result_array.append(resolve_recursive(entry))
		return result_array
	return value

func style(style_name: String, fallback: String = "panel") -> Dictionary:
	var styles: Dictionary = data.get("styles", {}) if data.get("styles", {}) is Dictionary else {}
	var result: Variant = styles.get(style_name, styles.get(fallback, {}))
	return resolve_recursive(result) if result is Dictionary else {}

func component(component_name: String) -> Dictionary:
	var components: Dictionary = data.get("components", {}) if data.get("components", {}) is Dictionary else {}
	var value: Variant = components.get(component_name, {})
	return resolve_recursive(value) if value is Dictionary else {}

func effect(effect_name: String) -> Dictionary:
	var effects: Dictionary = data.get("effects", {}) if data.get("effects", {}) is Dictionary else {}
	var value: Variant = effects.get(effect_name, {})
	return resolve_recursive(value) if value is Dictionary else {}
