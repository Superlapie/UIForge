class_name UIForgeProcess
extends RefCounted

enum AliveStatus { ALIVE, DEAD, UNKNOWN }

static var pid_alive_status_hook: Callable = Callable()

static func query_process_identity(pid: int) -> Dictionary:
	if pid <= 0:
		return {"ok": false}
	if OS.get_name() == "Windows":
		return _query_windows(pid)
	return _query_unix(pid)

static func current_process_identity() -> Dictionary:
	return query_process_identity(OS.get_process_id())

static func pid_alive(meta: Dictionary) -> AliveStatus:
	if pid_alive_status_hook.is_valid():
		return pid_alive_status_hook.call(meta)
	if typeof(meta) != TYPE_DICTIONARY:
		return AliveStatus.DEAD
	var pid := _positive_meta_int(meta.get("pid"))
	if pid <= 0:
		return AliveStatus.DEAD
	var stored_start := ""
	if meta.has("process_start"):
		var process_start: Variant = meta.get("process_start")
		if process_start == null:
			stored_start = ""
		elif typeof(process_start) == TYPE_STRING:
			stored_start = str(process_start)
		elif typeof(process_start) == TYPE_INT or typeof(process_start) == TYPE_FLOAT:
			stored_start = str(process_start)
		else:
			return AliveStatus.DEAD
	var identity := query_process_identity(pid)
	if not identity.get("ok", false):
		if identity.get("dead", false):
			return AliveStatus.DEAD
		return AliveStatus.UNKNOWN
	var live_start := str(identity.get("start_ticks", ""))
	if not stored_start.is_empty():
		if live_start.is_empty():
			return AliveStatus.UNKNOWN
		if live_start != stored_start:
			return AliveStatus.DEAD
	return AliveStatus.ALIVE

static func _query_windows(pid: int) -> Dictionary:
	var output: Array = []
	var script := (
		"$p = Get-Process -Id %d -ErrorAction SilentlyContinue; "
		+ "if ($null -eq $p) { exit 2 }; "
		+ "Write-Output (\"{0}|{1}\" -f $p.Id, $p.StartTime.ToFileTimeUtc())"
	) % pid
	var exit_code := OS.execute("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", script], output, true, false)
	if exit_code == 2:
		return {"ok": false, "dead": true}
	if exit_code == 0 and not output.is_empty():
		var parts := str(output[0]).strip_edges().split("|")
		if parts.size() >= 2:
			return {"ok": true, "pid": int(parts[0]), "start_ticks": parts[1]}
	return _query_windows_tasklist(pid)

static func _query_windows_tasklist(pid: int) -> Dictionary:
	var output: Array = []
	var exit_code := OS.execute("cmd.exe", ["/c", "tasklist /FI \"PID eq %d\" /NH /FO CSV" % pid], output, true, false)
	var combined := " ".join(PackedStringArray(output)).strip_edges()
	if combined.is_empty() or "No tasks are running" in combined or "INFO: No tasks" in combined:
		return {"ok": false, "dead": true}
	if str(pid) in combined:
		return {"ok": true, "pid": pid, "start_ticks": ""}
	if exit_code != 0:
		return {"ok": false, "unknown": true}
	return {"ok": false, "dead": true}

static func _query_unix(pid: int) -> Dictionary:
	if not DirAccess.dir_exists_absolute("/proc/%d" % pid):
		return {"ok": false, "dead": true}
	var exit_code := OS.execute("kill", ["-0", str(pid)], [], true, false)
	if exit_code != 0:
		return {"ok": false, "dead": true}
	var file := FileAccess.open("/proc/%d/stat" % pid, FileAccess.READ)
	if file == null:
		return {"ok": true, "pid": pid, "start_ticks": ""}
	var raw := file.get_as_text()
	file.close()
	if raw.is_empty():
		return {"ok": true, "pid": pid, "start_ticks": ""}
	var parts := raw.split(")", true, 1)
	if parts.size() < 2:
		return {"ok": false, "unknown": true}
	var tail := parts[1].strip_edges().split(" ", false)
	if tail.size() < 20:
		return {"ok": true, "pid": pid, "start_ticks": ""}
	return {"ok": true, "pid": pid, "start_ticks": tail[19]}

static func _positive_meta_int(value: Variant) -> int:
	if typeof(value) == TYPE_INT:
		return int(value) if int(value) > 0 else 0
	if typeof(value) == TYPE_FLOAT:
		var as_float := float(value)
		if not is_finite(as_float) or as_float != floor(as_float):
			return 0
		var as_int := int(as_float)
		return as_int if as_int > 0 else 0
	return 0
