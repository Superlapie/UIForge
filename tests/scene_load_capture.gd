extends SceneTree

const LOAD_OK_SENTINEL := "UIFORGE_SCENE_LOAD_OK"
const RESULT_PATH := "user://scene_load_capture_result.txt"

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	_clear_result()
	if args.is_empty():
		_fail("Missing scene path argument.", 2)
		return
	var scene_path := str(args[0])
	var packed: Variant = ResourceLoader.load(scene_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
	if packed == null:
		_fail("ResourceLoader returned null for %s" % scene_path, 1)
		return
	var instance: Node = packed.instantiate()
	if instance == null:
		_fail("Could not instantiate %s" % scene_path, 1)
		return
	instance.free()
	_write_result(LOAD_OK_SENTINEL)
	print(LOAD_OK_SENTINEL)
	quit(0)

func _write_result(message: String) -> void:
	var file := FileAccess.open(RESULT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(message)
		file.close()

func _clear_result() -> void:
	var absolute := ProjectSettings.globalize_path(RESULT_PATH)
	if FileAccess.file_exists(absolute):
		DirAccess.remove_absolute(absolute)

func _fail(message: String, code: int) -> void:
	push_error(message)
	_write_result("ERROR:%s" % message)
	quit(code)

static func read_result() -> String:
	if not FileAccess.file_exists(RESULT_PATH):
		return ""
	var file := FileAccess.open(RESULT_PATH, FileAccess.READ)
	if file == null:
		return ""
	var text := file.get_as_text()
	file.close()
	return text.strip_edges()
