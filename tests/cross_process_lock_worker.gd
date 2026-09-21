extends SceneTree

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 3:
		quit(2)
		return
	var source_path := str(args[0])
	var revision := str(args[1])
	var marker := str(args[2])
	var loaded := UIForgeSerializer.load_document(source_path)
	var result := {"success": false, "errors": [{"code": "LOAD_FAILED"}]}
	if loaded.get("document") != null:
		var document: UIForgeDocument = loaded["document"]
		var payload := document.data.duplicate(true)
		var metadata: Dictionary = payload.get("metadata", {})
		metadata["marker"] = marker
		payload["metadata"] = metadata
		result = UIForgeTransaction.write_source_atomically(source_path, JSON.stringify(payload, "\t") + "\n", revision)
	var absolute := UIForgePaths.normalize_requested(source_path)
	if not absolute.is_empty():
		var file := FileAccess.open("%s.result_%s" % [absolute, marker], FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(result))
			file.close()
	quit(0 if result.get("success", false) else 1)
