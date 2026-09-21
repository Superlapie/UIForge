extends SceneTree

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	var examples := {
		"inventory": "inventory_window",
		"bank": "bank_window",
		"equipment": "equipment_window",
		"quest_journal": "quest_window",
		"settings": "settings_window",
		"combat_hud": "combat_hud",
		"enemy_target_frame": "enemy_target_frame",
		"gameplay_sidebar": "gameplay_sidebar_collapsed",
		"gameplay_sidebar_expanded": "gameplay_sidebar_expanded"
	}
	for filename in examples:
		var path := "res://examples/scenes/%s.tscn" % filename
		var packed := load(path) as PackedScene
		if packed == null:
			failures.append("load:%s" % filename)
			continue
		var instance := packed.instantiate()
		if instance == null or str(instance.get_meta("aether_id", "")) != str(examples[filename]):
			failures.append("instantiate:%s" % filename)
		else:
			instance.queue_free()
	if failures.is_empty():
		print(JSON.stringify({"success": true, "loaded": examples.size(), "failed": 0}))
		quit(0)
	else:
		print(JSON.stringify({"success": false, "loaded": examples.size() - failures.size(), "failed": failures.size(), "failures": failures}))
		quit(1)
