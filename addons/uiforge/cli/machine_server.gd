extends SceneTree

const REQUEST_PREFIX := "UIFORGE_REQUEST\t"

var _server: TCPServer
var _peer: StreamPeerTCP
var _read_buffer: PackedByteArray = PackedByteArray()
var _running := true

func _init() -> void:
	call_deferred("_start")

func _start() -> void:
	_server = TCPServer.new()
	var err := _server.listen(int(OS.get_environment("UIFORGE_SERVER_PORT")) if OS.has_environment("UIFORGE_SERVER_PORT") else 0, "127.0.0.1")
	if err != OK:
		printerr(JSON.stringify({"success": false, "error": {"code": "SERVER_BIND_FAILED", "message": "Could not bind machine server."}}))
		quit(1)
		return
	print(UIForgeMachineProtocol.frame_line({
		"protocol": UIForgeMachineProtocol.PROTOCOL_ID,
		"protocol_version": UIForgeMachineProtocol.PROTOCOL_VERSION,
		"request_id": "handshake",
		"success": true,
		"result": {"ready": true, "port": _server.get_local_port()},
		"diagnostics": [],
		"meta": {"backend": "godot-native", "schema_version": UIForgeTypes.SCHEMA_VERSION, "command_contract_version": UIForgeMachineProtocol.COMMAND_CONTRACT_VERSION},
	}))
	while _running:
		if _peer == null and _server.is_connection_available():
			_peer = _server.take_connection()
		if _peer != null:
			if _peer.get_status() == StreamPeerTCP.STATUS_NONE or _peer.get_status() == StreamPeerTCP.STATUS_ERROR:
				_shutdown()
				return
			while _peer.get_available_bytes() > 0:
				var chunk: PackedByteArray = _peer.get_partial_data(_peer.get_available_bytes())[1]
				if chunk.is_empty():
					break
				_read_buffer.append_array(chunk)
			while true:
				var newline_index := _read_buffer.find(10)
				if newline_index < 0:
					break
				var line_bytes: PackedByteArray = _read_buffer.slice(0, newline_index)
				_read_buffer = _read_buffer.slice(newline_index + 1)
				var line := line_bytes.get_string_from_utf8().strip_edges()
				if line.is_empty() or not line.begins_with(REQUEST_PREFIX):
					continue
				await _handle_request_line(line)
		await process_frame

func _handle_request_line(line: String) -> void:
	var parser := JSON.new()
	if parser.parse(line.substr(REQUEST_PREFIX.length())) != OK or not parser.data is Dictionary:
		_send_response(UIForgeMachineProtocol.error_response("", "MALFORMED_REQUEST", "Request line was not valid JSON."))
		return
	var request: Dictionary = parser.data
	if JSON.stringify(request).length() > UIForgeMachineProtocol.MAX_REQUEST_BYTES:
		_send_response(UIForgeMachineProtocol.error_response(str(request.get("request_id", "")), "REQUEST_TOO_LARGE", "Request exceeds max size."))
		return
	var response := await UIForgeCommandDispatcher.dispatch_machine(request)
	_send_response(response)
	if str(request.get("method", "")) == "shutdown" and bool(response.get("success", false)):
		_shutdown()

func _send_response(payload: Dictionary) -> void:
	if _peer == null:
		return
	_peer.put_data((UIForgeMachineProtocol.frame_line(payload) + "\n").to_utf8_buffer())

func _shutdown() -> void:
	_running = false
	if _peer != null:
		_peer.disconnect_from_host()
		_peer = null
	if _server != null:
		_server.stop()
	quit(0)
