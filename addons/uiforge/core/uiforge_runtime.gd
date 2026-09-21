class_name UIForgeRuntime
extends RefCounted

## Small language-neutral helpers for generated scenes. Gameplay code remains in the game.
## Generated nodes carry metadata/aether_id, metadata/aether_action, and metadata/aether_binding.

static func find_by_id(root: Node, node_id: String) -> Node:
	if root == null:
		return null
	if str(root.get_meta("aether_id", "")) == node_id or root.name == node_id:
		return root
	for child in root.get_children():
		var found := find_by_id(child, node_id)
		if found != null:
			return found
	return null

static func set_text(root: Node, node_id: String, value: String) -> bool:
	var target := find_by_id(root, node_id)
	if target == null or not (target is Label or target is Button or target is RichTextLabel or target is LineEdit):
		return false
	target.set("text", value)
	return true

static func set_value(root: Node, node_id: String, value: float) -> bool:
	var target := find_by_id(root, node_id)
	if target == null or not target.has_method("set_value"):
		return false
	target.set_value(value)
	return true

static func action_id(node: Node) -> String:
	return str(node.get_meta("aether_action", ""))

static func binding_id(node: Node) -> String:
	return str(node.get_meta("aether_binding", ""))

static func transition_config(node: Node) -> Dictionary:
	var parsed: Variant = JSON.parse_string(str(node.get_meta("aether_transitions", "{}")))
	return parsed if parsed is Dictionary else {}

static func effect_config(node: Node) -> Variant:
	var raw := str(node.get_meta("aether_effects", "{}"))
	var parsed: Variant = JSON.parse_string(raw)
	return parsed if parsed != null else raw

static func play_transition(target: Control, preset: String, duration: float = 0.18) -> Tween:
	var tween := target.create_tween()
	var safe_duration := max(duration, 0.01)
	var original_modulate := target.modulate
	var original_scale := target.scale
	var original_position := target.position
	tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	match preset.to_lower():
		"fade":
			target.modulate.a = 0.0
			tween.tween_property(target, "modulate:a", original_modulate.a, safe_duration)
		"scale", "button_press":
			target.scale = original_scale * (0.96 if preset.to_lower() == "scale" else 0.94)
			tween.tween_property(target, "scale", original_scale, safe_duration)
		"slide":
			target.position = original_position + Vector2(0, 12)
			tween.tween_property(target, "position", original_position, safe_duration)
		"hover":
			target.modulate = original_modulate.darkened(0.08)
			tween.tween_property(target, "modulate", original_modulate, safe_duration)
		"panel_reveal":
			target.modulate.a = 0.0
			target.scale = original_scale * 0.98
			tween.parallel().tween_property(target, "modulate:a", original_modulate.a, safe_duration)
			tween.parallel().tween_property(target, "scale", original_scale, safe_duration)
		_:
			tween.tween_interval(safe_duration)
	return tween

static func connect_action(root: Node, node_id: String, callback: Callable) -> bool:
	var target := find_by_id(root, node_id)
	if target == null or not target.has_signal("pressed"):
		return false
	if not target.is_connected("pressed", callback):
		target.connect("pressed", callback)
	return true
