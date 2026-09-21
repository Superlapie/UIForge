class_name UIForgeComponentLibrary
extends RefCounted

static func definitions() -> Dictionary:
	return {
		"WindowFrame": {"native_type": "Panel", "style": "window"},
		"OrnatePanel": {"native_type": "Panel", "style": "panel"},
		"SimplePanel": {"native_type": "Panel", "style": "inset"},
		"SectionPanel": {"native_type": "Panel", "style": "panel"},
		"PrimaryButton": {"native_type": "Button", "style": "button_primary"},
		"SecondaryButton": {"native_type": "Button", "style": "button_secondary"},
		"IconButton": {"native_type": "TextureButton", "style": "button_secondary"},
		"CheckBox": {"native_type": "CheckBox", "style": "checkbox"},
		"CheckButton": {"native_type": "CheckButton", "style": "button_secondary"},
		"LineEdit": {"native_type": "LineEdit", "style": "inset"},
		"TabBar": {"native_type": "TabBar", "style": "tab"},
		"TabButton": {"native_type": "Button", "style": "tab"},
		"ItemSlot": {"native_type": "Panel", "style": "slot"},
		"ItemGrid": {"native_type": "GridContainer", "style": "inset"},
		"EquipmentSlot": {"native_type": "Panel", "style": "slot"},
		"EquipmentLayout": {"native_type": "Panel", "style": "inset"},
		"InventoryPanel": {"native_type": "Panel", "style": "panel"},
		"BankPanel": {"native_type": "Panel", "style": "panel"},
		"QuestEntry": {"native_type": "Button", "style": "list_row"},
		"QuestList": {"native_type": "VBoxContainer", "style": "inset"},
		"ScrollList": {"native_type": "ScrollContainer", "style": "inset"},
		"Tooltip": {"native_type": "Panel", "style": "panel"},
		"ContextMenu": {"native_type": "Panel", "style": "panel"},
		"ContextMenuEntry": {"native_type": "Button", "style": "button_secondary"},
		"ModalDialog": {"native_type": "Panel", "style": "window"},
		"ProgressDisplay": {"native_type": "ProgressBar", "style": "panel"},
		"StatusBar": {"native_type": "ProgressBar", "style": "panel"},
		"CurrencyDisplay": {"native_type": "HBoxContainer", "style": "inset"},
		"SearchBox": {"native_type": "LineEdit", "style": "inset"},
		"Dropdown": {"native_type": "OptionButton", "style": "inset"},
		"CheckToggle": {"native_type": "CheckButton", "style": "button_secondary"},
		"SidebarNavigation": {"native_type": "VBoxContainer", "style": "inset"},
		"SidebarEntry": {"native_type": "Button", "style": "list_row"},
		"GameplaySidebar": {"native_type": "Panel", "style": "sidebar_rail"},
		"GameplaySidebarTab": {"native_type": "Button", "style": "sidebar_tab"},
		"GameplaySidebarToggle": {"native_type": "Button", "style": "sidebar_toggle"},
		"EnemyTargetFrame": {"native_type": "Panel", "style": "target_frame"},
		"EnemyTargetHealthBar": {"native_type": "ProgressBar", "style": "target_track", "fill_style": "target_health"},
		"EnemyStatusEffect": {"native_type": "Panel", "style": "status_effect"},
		"CharacterPreviewFrame": {"native_type": "Panel", "style": "window"},
		"NotificationToast": {"native_type": "Panel", "style": "panel"},
		"LootPopup": {"native_type": "Panel", "style": "panel"},
		"CombatHUD": {"native_type": "Panel", "style": "hud_shell"},
		"ResourceBar": {"native_type": "ProgressBar", "style": "status_track"},
		"HealthBar": {"native_type": "ProgressBar", "style": "status_track", "fill_style": "status_health"},
		"PrayerBar": {"native_type": "ProgressBar", "style": "status_track", "fill_style": "status_prayer"},
		"RunBar": {"native_type": "ProgressBar", "style": "status_track", "fill_style": "status_run"},
		"SpecialBar": {"native_type": "ProgressBar", "style": "status_track", "fill_style": "status_special"},
		"HUDMedallion": {"native_type": "Panel", "style": "hud_medallion"},
		"ActionSlot": {"native_type": "Button", "style": "action_slot"}
	}

static func has(component_name: String) -> bool:
	return definitions().has(component_name)

static func materialize(node: Dictionary, custom_definitions: Dictionary = {}) -> Dictionary:
	var result: Dictionary = node.duplicate(true)
	var type := str(result.get("type", "Control"))
	if type == "ComponentInstance":
		var component_name := str(result.get("component", ""))
		var definition := _resolve_definition(component_name, custom_definitions, [])
		var base: Dictionary = definition.get("node", definition) if definition is Dictionary else {}
		result = _merge(base, result)
		if result.get("overrides", {}) is Dictionary:
			result = _merge(result, result.get("overrides", {}))
		result.erase("overrides")
		result["type"] = str(result.get("base_type", definition.get("native_type", UIForgeComponentLibrary.native_type(str(definition.get("base", "Control"))))))
		result["component"] = component_name
	return result

static func _resolve_definition(component_name: String, custom_definitions: Dictionary, chain: Array[String]) -> Dictionary:
	if component_name in chain:
		return {"native_type": "Control"}
	if custom_definitions.has(component_name):
		var custom: Dictionary = custom_definitions[component_name]
		var result: Dictionary = {}
		var base_name := str(custom.get("base", ""))
		if not base_name.is_empty():
			var next_chain := chain.duplicate()
			next_chain.append(component_name)
			result = _resolve_definition(base_name, custom_definitions, next_chain)
		result = _merge(result, custom)
		return result
	return definitions().get(component_name, {})

static func native_type(type_name: String) -> String:
	var definition: Dictionary = definitions().get(type_name, {})
	if definition.has("native_type"):
		return str(definition["native_type"])
	return {
		"RichText": "RichTextLabel",
		"Texture": "TextureRect",
		"Slider": "HSlider",
		"Grid": "GridContainer",
		"HBox": "HBoxContainer",
		"VBox": "VBoxContainer",
		"Separator": "HSeparator",
		"Spacer": "Control",
		"HSlider": "HSlider",
		"VSlider": "VSlider",
		"PanelContainer": "PanelContainer"
	}.get(type_name, type_name)

static func style_name(type_name: String) -> String:
	var definition: Dictionary = definitions().get(type_name, {})
	return str(definition.get("style", "panel"))

static func _merge(base: Dictionary, override: Dictionary) -> Dictionary:
	var result := base.duplicate(true)
	for key in override:
		if key == "properties" and result.get(key) is Dictionary and override[key] is Dictionary:
			var props: Dictionary = result[key].duplicate(true)
			props.merge(override[key], true)
			result[key] = props
		elif key == "layout" and result.get(key) is Dictionary and override[key] is Dictionary:
			var layout: Dictionary = result[key].duplicate(true)
			layout.merge(override[key], true)
			result[key] = layout
		else:
			result[key] = override[key]
	return result
