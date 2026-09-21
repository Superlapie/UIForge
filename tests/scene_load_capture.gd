extends SceneTree

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		push_error("Missing scene path argument.")
		quit(1)
		return
	var scene_path := str(args[0])
	var packed: Variant = ResourceLoader.load(scene_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
	if packed == null:
		push_error("ResourceLoader returned null for %s" % scene_path)
		quit(1)
		return
	var instance: Node = packed.instantiate()
	if instance == null:
		push_error("Could not instantiate %s" % scene_path)
		quit(1)
		return
	instance.free()
	quit(0)
