extends SceneTree

const REQUEST_PREFIX := "UIFORGE_REQUEST\t"

var _server: TCPServer
var _peer: StreamPeerTCP
var _read_buffer: PackedByteArray = PackedByteArray()
var _running := true
var _connected := false
var _expected_token := ""

func _init() -> void:
	_expected_token = OS.get_environment("UIFORGE_SERVER_TOKEN") if OS.has_environment("UIFORGE_SERVER_TOKEN") else ""
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
					if _read_buffer.size() > UIForgeMachineProtocol.MAX_REQUEST_BYTES:
						_drain_oversized_request()
					break
				var line_bytes: PackedByteArray = _read_buffer.slice(0, newline_index)
				_read_buffer = _read_buffer.slice(newline_index + 1)
				if line_bytes.size() > UIForgeMachineProtocol.MAX_REQUEST_BYTES:
					await _handle_oversized_request()
					continue
				var line := line_bytes.get_string_from_utf8().strip_edges()
				if line.is_empty():
					continue
				if not _connected:
					if not _accept_connect_line(line):
						_send_response(UIForgeMachineProtocol.error_response("", "CONNECT_FAILED", "Invalid server connect token."))
						_shutdown()
						return
					_connected = true
					continue
				if not line.begins_with(REQUEST_PREFIX):
					continue
				await _handle_request_line(line.substr(REQUEST_PREFIX.length()))
		await process_frame

func _accept_connect_line(line: String) -> bool:
	if _expected_token.is_empty():
		return line.begins_with(UIForgeMachineProtocol.CONNECT_PREFIX)
	if not line.begins_with(UIForgeMachineProtocol.CONNECT_PREFIX):
		return false
	return line.substr(UIForgeMachineProtocol.CONNECT_PREFIX.length()) == _expected_token

func _drain_oversized_request() -> void:
	var newline_index := _read_buffer.find(10)
	if newline_index >= 0:
		_read_buffer = _read_buffer.slice(newline_index + 1)
	else:
		_read_buffer = PackedByteArray()

func _handle_oversized_request() -> void:
	_send_response(UIForgeMachineProtocol.error_response("", "REQUEST_TOO_LARGE", "Request exceeds max size."))
	_drain_oversized_request()

func _handle_request_line(raw_json: String) -> void:
	var parser := JSON.new()
	if parser.parse(raw_json) != OK or not parser.data is Dictionary:
		_send_response(UIForgeMachineProtocol.error_response("", "MALFORMED_REQUEST", "Request line was not valid JSON."))
		return
	var request: Dictionary = parser.data
	var validated := UIForgeMachineProtocol.validate_request(request)
	if not bool(validated.get("ok", false)):
		_send_response(UIForgeMachineProtocol.error_response(
			str(request.get("request_id", "")),
			str(validated.get("code", "MALFORMED_REQUEST")),
			str(validated.get("message", "Malformed request."))
		))
		return
	var response := await UIForgeCommandDispatcher.dispatch_machine(validated.request)
	_send_response(response)
	if str(validated.request.get("method", "")) == "shutdown" and bool(response.get("success", false)):
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
