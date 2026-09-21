class_name AetherTheme
extends RefCounted

var data: Dictionary = {}
var tokens: Dictionary = {}

func _init(theme_data: Dictionary = {}) -> void:
	data = theme_data.duplicate(true)
	tokens = data.get("tokens", {})

static func load_named(theme_name: String) -> AetherTheme:
	var path := "res://addons/aether_ui/themes/%s.theme.json" % theme_name
	if not FileAccess.file_exists(path):
		path = "res://addons/aether_ui/themes/dark_fantasy.theme.json"
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return AetherTheme.new(_fallback_data())
	var parser := JSON.new()
	parser.parse(file.get_as_text())
	file.close()
	return AetherTheme.new(parser.data if parser.data is Dictionary else _fallback_data())

static func from_document(document: AetherDocument) -> AetherTheme:
	var result := load_named(str(document.data.get("theme", "dark_fantasy")))
	var overrides: Dictionary = document.data.get("theme_overrides", {})
	if overrides is Dictionary:
		var override_tokens: Dictionary = overrides.get("tokens", {})
		var override_styles: Dictionary = overrides.get("styles", {})
		if override_tokens is Dictionary:
			var merged_tokens: Dictionary = result.tokens.duplicate(true)
			_deep_merge(merged_tokens, override_tokens)
			result.tokens = merged_tokens
			result.data["tokens"] = result.tokens
		if override_styles is Dictionary:
			var styles: Dictionary = result.data.get("styles", {})
			styles.merge(override_styles, true)
			result.data["styles"] = styles
	return result

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
	var styles: Dictionary = data.get("styles", {})
	var result: Variant = styles.get(style_name, styles.get(fallback, {}))
	return resolve_recursive(result) if result is Dictionary else {}

func component(component_name: String) -> Dictionary:
	var components: Dictionary = data.get("components", {})
	var value: Variant = components.get(component_name, {})
	return resolve_recursive(value) if value is Dictionary else {}

func effect(effect_name: String) -> Dictionary:
	var effects: Dictionary = data.get("effects", {})
	var value: Variant = effects.get(effect_name, {})
	return resolve_recursive(value) if value is Dictionary else {}

static func _fallback_data() -> Dictionary:
	return {
		"schema_version": 1,
		"name": "dark_fantasy",
		"tokens": {"colors": {"surface": "#151a22", "text_primary": "#f3ead5", "border": "#645039", "border_highlight": "#c9a96a"}, "spacing": {"md": 12}, "font_size": {"body": 15}},
		"styles": {"panel": {"background": "$colors.surface", "border": "$colors.border", "border_width": 1}}
	}
