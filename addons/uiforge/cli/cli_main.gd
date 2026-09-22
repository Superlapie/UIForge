extends SceneTree

var args: PackedStringArray

func _init() -> void:
	args = OS.get_cmdline_user_args()
	call_deferred("_run")

func _run() -> void:
	if not args.is_empty() and str(args[0]) == "machine-oneshot":
		await _run_machine_oneshot(args.slice(1))
		return
	var result := await UIForgeCommandDispatcher.human_from_argv(args)
	_emit_human_result(result)

func _run_machine_oneshot(machine_args: PackedStringArray) -> void:
	if machine_args.is_empty():
		_emit_machine(UIForgeMachineProtocol.error_response("", "USAGE", "machine-oneshot requires a JSON request path or inline payload marker."))
		return
	var request: Dictionary = {}
	if str(machine_args[0]) == "--request-json":
		var parser := JSON.new()
		if parser.parse(str(machine_args[1]) if machine_args.size() > 1 else "") != OK or not parser.data is Dictionary:
			_emit_machine(UIForgeMachineProtocol.error_response("", "MALFORMED_REQUEST", "Invalid inline machine request JSON."))
			return
		request = parser.data
	else:
		var file := FileAccess.open(str(machine_args[0]), FileAccess.READ)
		if file == null:
			_emit_machine(UIForgeMachineProtocol.error_response("", "REQUEST_FILE_NOT_FOUND", "Machine request file not found."))
			return
		var parser := JSON.new()
		if parser.parse(file.get_as_text()) != OK or not parser.data is Dictionary:
			_emit_machine(UIForgeMachineProtocol.error_response("", "MALFORMED_REQUEST", "Machine request file is not valid JSON."))
			return
		request = parser.data
	var response := await UIForgeCommandDispatcher.dispatch_machine(request)
	_emit_machine(response)

func _emit_machine(response: Dictionary) -> void:
	print(UIForgeMachineProtocol.frame_line(response))
	quit(UIForgeMachineProtocol.exit_class_for_response(response))

func _emit_human_result(result: Dictionary) -> void:
	if result.has("capabilities"):
		result["backend"] = "godot-native"
	print(UIForgeMachineProtocol.frame_line(result))
	quit(0 if bool(result.get("success", false)) else 1)
