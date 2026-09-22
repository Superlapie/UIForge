extends SceneTree

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		quit(1)
		return
	var source_res := str(args[0])
	var loaded := UIForgeSerializer.load_document(source_res)
	var absolute := ProjectSettings.globalize_path(source_res)
	var result_path := "%s.reader_result" % absolute
	var file := FileAccess.open(result_path, FileAccess.WRITE)
	if file == null:
		quit(1)
		return
	file.store_string(JSON.stringify({
		"success": loaded.get("document") != null,
		"revision_hash": str(loaded.get("revision_hash", "")),
		"errors": loaded.get("errors", []),
	}))
	file.close()
	quit(0)
