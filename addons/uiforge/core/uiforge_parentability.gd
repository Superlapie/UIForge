class_name UIForgeParentability
extends RefCounted

const NATIVE_CONTAINER_TYPES: Array[String] = [
	"Control", "Panel", "PanelContainer", "ScrollContainer", "GridContainer", "HBoxContainer",
	"VBoxContainer", "MarginContainer", "CenterContainer", "TabContainer", "TabBar",
	"AspectRatioContainer", "FlowContainer", "HSplitContainer", "VSplitContainer",
]

static func can_contain_children(node: Dictionary, custom_components: Dictionary = {}) -> bool:
	if node.is_empty():
		return false
	var node_type := str(node.get("type", ""))
	if node_type in UIForgeTypes.CONTAINER_TYPES:
		return true
	if node_type == "ComponentInstance":
		return _component_instance_can_contain(node, custom_components)
	var native_type := _resolved_native_type(node_type, custom_components)
	if native_type in NATIVE_CONTAINER_TYPES:
		return true
	return false

static func can_accept_child(parent: Dictionary, child: Dictionary, custom_components: Dictionary = {}) -> bool:
	return can_contain_children(parent, custom_components)

static func parentability_error(parent_id: String, parent: Dictionary, child_id: String = "") -> Dictionary:
	var parent_type := str(parent.get("type", ""))
	var message := "Node '%s' cannot contain children." % parent_id
	if child_id.is_empty():
		message = "That node cannot contain children."
	return {
		"severity": "error",
		"code": "INVALID_PARENT_RELATIONSHIP",
		"message": message,
		"node": child_id if not child_id.is_empty() else parent_id,
		"parent_type": parent_type,
	}

static func assert_can_accept_child(parent_id: String, parent: Dictionary, custom_components: Dictionary = {}, child_id: String = "") -> Dictionary:
	if can_contain_children(parent, custom_components):
		return {}
	return parentability_error(parent_id, parent, child_id)

static func _component_instance_can_contain(node: Dictionary, custom_components: Dictionary) -> bool:
	var component_name := str(node.get("component", ""))
	var definition := UIForgeComponentLibrary.resolve_definition(component_name, custom_components, [])
	var template: Dictionary = definition.get("node", definition) if definition is Dictionary else {}
	if template.is_empty():
		return false
	var template_type := str(template.get("type", definition.get("native_type", "Control")))
	if template_type == "ComponentInstance":
		return _component_instance_can_contain(template, custom_components)
	if template_type in UIForgeTypes.CONTAINER_TYPES:
		return true
	return _resolved_native_type(template_type, custom_components) in NATIVE_CONTAINER_TYPES

static func _resolved_native_type(type_name: String, custom_components: Dictionary) -> String:
	if type_name == "ComponentInstance":
		return "Control"
	if UIForgeComponentLibrary.has(type_name):
		return UIForgeComponentLibrary.native_type(type_name)
	return UIForgeComponentLibrary.native_type(type_name)
