@tool
extends EditorPlugin

const STUDIO_SCRIPT := preload("res://addons/uiforge/editor/uiforge_studio.gd")

var studio: Control

func _enter_tree() -> void:
	studio = STUDIO_SCRIPT.new()
	studio.name = "UIForgeStudio"
	studio.set_meta("aether_editor_plugin", true)
	if studio.has_method("set_editor_undo_redo"):
		studio.set_editor_undo_redo(get_undo_redo())
	add_control_to_dock(DOCK_SLOT_LEFT_BR, studio)
	add_tool_menu_item("UIForge", Callable(self, "_focus_studio"))

func _exit_tree() -> void:
	remove_tool_menu_item("UIForge")
	if is_instance_valid(studio):
		remove_control_from_docks(studio)
		studio.queue_free()
	studio = null

func _focus_studio() -> void:
	if is_instance_valid(studio):
		studio.grab_focus()
		studio.show()
