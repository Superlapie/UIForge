extends SceneTree

const HUMAN_SCENE := "[gd_scene load_steps=1 format=3]\n\n[node name=\"HumanRoot\" type=\"Control\"]\n"
const GENERATED_SCENE_BODY := "[gd_scene load_steps=1 format=3]\n\n[node name=\"GeneratedRoot\" type=\"Control\"]\n"

var failures: Array[String] = []
var passed := 0

func _init() -> void:
	_run()

func _run() -> void:
	_test_paths()
	_test_locking()
	_test_process_liveness()
	_test_transactions()
	_test_output_replacement()
	_test_provenance_after_recovery()
	_test_scene_verification()
	_test_resource_provenance()
	if OS.get_name() == "Windows":
		_test_windows_junction_containment()
	else:
		_test_symlink_containment()
	if failures.is_empty():
		print(JSON.stringify({"success": true, "passed": passed, "failed": 0}))
		quit(0)
		return
	print(JSON.stringify({"success": false, "passed": passed, "failed": failures.size(), "failures": failures}, "\t"))
	quit(1)

const TRUST_ROOT := "res://.uiforge/trust"

func _trust_path(relative: String) -> String:
	return "%s/%s" % [TRUST_ROOT, relative]

func _trust_abs(relative: String) -> String:
	return ProjectSettings.globalize_path(_trust_path(relative))

func _prepare_trust_dir(relative: String) -> void:
	var absolute := _trust_abs(relative)
	DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())

func _test_paths() -> void:
	var workspace := UIForgePaths.workspace_root()
	_assert(not workspace.is_empty(), "paths_workspace_root")
	var cases := [
		["res://tests/conformance/fixtures/minimal.ui.json", true],
		[_trust_path("paths/sample.tscn"), true],
	]
	for entry in cases:
		var normalized := UIForgePaths.normalize_requested(str(entry[0]))
		_assert(not normalized.is_empty(), "paths_normalize_%s" % entry[0])
		if bool(entry[1]):
			var resolved := UIForgePaths.resolve_real_path(normalized)
			_assert(resolved.begins_with("/") or ":" in resolved, "paths_resolve_%s" % entry[0])
	var inside := UIForgePaths.validate_output(_trust_path("paths/inside.tscn"), UIForgePaths.ArtifactKind.SCENE, false)
	_assert(inside.ok, "paths_inside_workspace")
	var outside := UIForgePaths.validate_output("/tmp/uiforge_outside.tscn", UIForgePaths.ArtifactKind.SCENE, false)
	_assert(not outside.ok, "paths_outside_workspace_blocked")
	if not outside.errors.is_empty():
		_assert(str(outside.errors[0].get("code", "")) == "OUTPUT_OUTSIDE_WORKSPACE", "paths_outside_workspace_code")

func _test_locking() -> void:
	_prepare_trust_dir("lock/target.ui.json")
	var target := _trust_abs("lock/target.ui.json")
	if not FileAccess.file_exists(target):
		FileAccess.open(target, FileAccess.WRITE).close()
	var lock_a := UIForgeLock.acquire(target)
	_assert(lock_a.get("ok", false), "lock_acquire")
	var lock_b := UIForgeLock.acquire(target)
	_assert(not lock_b.get("ok", false), "lock_exclusive")
	UIForgeLock.release(str(lock_a.get("lock_path", "")), str(lock_a.get("owner_nonce", "")))
	var reacquire := UIForgeLock.acquire(target)
	_assert(reacquire.get("ok", false), "lock_reacquire_after_release")
	UIForgeLock.release(str(reacquire.get("lock_path", "")), str(reacquire.get("owner_nonce", "")))
	var stale_dir := "%s.uiforge_lock" % target
	DirAccess.make_dir_absolute(stale_dir)
	var identity := UIForgeProcess.current_process_identity()
	_write_owner_json(stale_dir, {
		"owner_nonce": "live-owner",
		"pid": OS.get_process_id(),
		"process_start": str(identity.get("start_ticks", "")),
		"started": Time.get_unix_time_from_system() - 3600,
	})
	_assert(not UIForgeLock.lock_is_stale(stale_dir), "lock_live_owner_not_stale_by_age")
	_assert(not UIForgeLock.reclaim_stale_lock(stale_dir, target), "lock_live_owner_not_reclaimed")
	DirAccess.remove_absolute(stale_dir)
	DirAccess.make_dir_absolute(stale_dir)
	_write_owner_json(stale_dir, {
		"owner_nonce": "dead-owner",
		"pid": 999999,
		"process_start": "0",
		"started": Time.get_unix_time_from_system() - 3600,
	})
	_assert(UIForgeLock.lock_is_stale(stale_dir), "lock_dead_owner_stale")
	_assert(UIForgeLock.reclaim_stale_lock(stale_dir, target), "lock_dead_owner_reclaimed")
	_assert(not DirAccess.dir_exists_absolute(stale_dir), "lock_dead_owner_removed")

func _test_process_liveness() -> void:
	var current := UIForgeProcess.current_process_identity()
	_assert(current.get("ok", false), "process_current_alive")
	var meta := {
		"pid": OS.get_process_id(),
		"process_start": str(current.get("start_ticks", "")),
	}
	_assert(UIForgeProcess.pid_alive(meta) == UIForgeProcess.AliveStatus.ALIVE, "process_current_status_alive")
	_assert(UIForgeProcess.pid_alive({"pid": 999999, "process_start": "0"}) == UIForgeProcess.AliveStatus.DEAD, "process_bogus_dead")

func _test_transactions() -> void:
	_prepare_trust_dir("txn/source.ui.json")
	var source_res := _trust_path("txn/source.ui.json")
	var fixture := ProjectSettings.globalize_path("res://tests/conformance/fixtures/minimal.ui.json")
	DirAccess.copy_absolute(fixture, _trust_abs("txn/source.ui.json"))
	var revision := str(UIForgeHash.file_revision(source_res).get("hash", ""))
	var payload := FileAccess.get_file_as_string(_trust_abs("txn/source.ui.json"))
	var first := UIForgeTransaction.write_source_atomically(source_res, payload, revision)
	_assert(first.get("success", false), "txn_source_write")
	var parsed: Variant = JSON.parse_string(payload)
	if parsed is Dictionary:
		var mutated: Dictionary = parsed.duplicate(true)
		mutated["metadata"] = {"external_change": true}
		FileAccess.open(_trust_abs("txn/source.ui.json"), FileAccess.WRITE).store_string(JSON.stringify(mutated, "\t") + "\n")
	var conflict := UIForgeTransaction.write_source_atomically(source_res, payload, revision)
	_assert(not conflict.get("success", false), "txn_revision_conflict")
	var pending := "%s.uiforge_pending" % _trust_abs("txn/source.ui.json")
	var backup := "%s.uiforge_backup" % _trust_abs("txn/source.ui.json")
	var meta := "%s.uiforge_txn" % _trust_abs("txn/source.ui.json")
	_assert(not FileAccess.file_exists(pending), "txn_pending_clean")
	_assert(not FileAccess.file_exists(backup), "txn_backup_clean")
	_assert(not FileAccess.file_exists(meta), "txn_meta_clean")

func _test_output_replacement() -> void:
	_prepare_trust_dir("replace/output.tscn")
	var dest_res := _trust_path("replace/output.tscn")
	var dest_abs := _trust_abs("replace/output.tscn")
	var backup_abs := "%s.uiforge_replace_backup" % dest_abs
	var meta_abs := "%s.uiforge_replace_txn" % dest_abs
	FileAccess.open(dest_abs, FileAccess.WRITE).store_string(HUMAN_SCENE)
	var staged := UIForgeTransaction.unique_temp_path(dest_abs, ".tscn")
	FileAccess.open(staged, FileAccess.WRITE).store_string(GENERATED_SCENE_BODY)
	var recovery := UIForgeTransaction.recover_interrupted_replace_for_path(dest_res)
	_assert(recovery.get("ok", false) and recovery.get("status", "") == "clean", "replace_recovery_initial")
	DirAccess.remove_absolute(dest_abs)
	FileAccess.open(backup_abs, FileAccess.WRITE).store_string(HUMAN_SCENE)
	_write_replace_meta(meta_abs, {
		"target": dest_abs,
		"stage": "backup",
		"backup_hash": _text_hash(backup_abs),
	})
	recovery = UIForgeTransaction.recover_interrupted_replace_for_path(dest_res)
	_assert(recovery.get("ok", false) and recovery.get("status", "") == "recovered", "replace_recovery_restore")
	_assert(FileAccess.get_file_as_string(dest_abs) == HUMAN_SCENE, "replace_recovery_restored_bytes")
	var replace_result := UIForgeTransaction.replace_file(staged, dest_abs)
	_assert(replace_result.get("ok", false), "replace_existing_destination")
	_assert(not FileAccess.file_exists(backup_abs), "replace_sidecars_clean")

func _test_provenance_after_recovery() -> void:
	_prepare_trust_dir("provenance/human.tscn")
	var dest_res := _trust_path("provenance/human.tscn")
	var dest_abs := _trust_abs("provenance/human.tscn")
	var backup_abs := "%s.uiforge_replace_backup" % dest_abs
	var meta_abs := "%s.uiforge_replace_txn" % dest_abs
	_cleanup_sidecars(dest_abs)
	FileAccess.open(backup_abs, FileAccess.WRITE).store_string(HUMAN_SCENE)
	_write_replace_meta(meta_abs, {
		"target": dest_abs,
		"stage": "backup",
		"backup_hash": _text_hash(backup_abs),
	})
	var source_path := "res://tests/conformance/fixtures/minimal.ui.json"
	var source_id := UIForgeArtifact.source_identity(source_path)
	var generated := _generated_scene_text(source_id, "sha256:0000000000000000000000000000000000000000000000000000000000000000")
	var result := UIForgeTransaction.write_text_atomically(dest_res, generated, {
		"source_identity": source_id,
		"force": false,
	})
	_assert(not result.get("success", false), "provenance_human_scene_rejected")
	_assert(_has_error_code(result, "OUTPUT_NOT_UIFORGE_GENERATED"), "provenance_human_scene_code")
	_assert(FileAccess.get_file_as_string(dest_abs) == HUMAN_SCENE, "provenance_human_scene_preserved")
	_cleanup_sidecars(dest_abs)
	var trusted := _generated_scene_text(source_id, UIForgeHash.content_hash({"schema_version": 1}))
	FileAccess.open(dest_abs, FileAccess.WRITE).store_string(trusted)
	var same_source := UIForgeTransaction.write_text_atomically(dest_res, trusted, {
		"source_identity": source_id,
		"force": false,
	})
	_assert(same_source.get("success", false), "provenance_same_source_allowed")
	var other_source := UIForgeArtifact.source_identity("res://tests/compiler_conformance/fixtures/foo-bar.ui.json")
	var mismatch := UIForgeTransaction.write_text_atomically(dest_res, trusted, {
		"source_identity": other_source,
		"force": false,
	})
	_assert(not mismatch.get("success", false), "provenance_different_source_rejected")
	_assert(_has_error_code(mismatch, "OUTPUT_SOURCE_MISMATCH"), "provenance_different_source_code")

func _test_scene_verification() -> void:
	_prepare_trust_dir("scene/valid.tscn")
	var valid_res := _trust_path("scene/valid.tscn")
	var valid_abs := _trust_abs("scene/valid.tscn")
	var source_id := UIForgeArtifact.source_identity("res://tests/conformance/fixtures/minimal.ui.json")
	FileAccess.open(valid_abs, FileAccess.WRITE).store_string(_generated_scene_text(source_id, "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
	var valid := UIForgeTransaction.verify_scene_syntax(valid_res)
	_assert(valid.get("ok", false), "scene_valid_accepted")
	var malformed_abs := _trust_abs("scene/malformed.tscn")
	FileAccess.open(malformed_abs, FileAccess.WRITE).store_string("not a scene")
	var malformed := UIForgeTransaction.verify_scene_syntax(_trust_path("scene/malformed.tscn"))
	_assert(not malformed.get("ok", false), "scene_malformed_rejected")
	var invalid_id_abs := _trust_abs("scene/invalid_id.tscn")
	var invalid_text := _generated_scene_text(source_id, "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
	invalid_text = invalid_text.replace("[gd_scene", "[gd_scene")
	invalid_text += "\n[ext_resource type=\"Texture2D\" path=\"res://icon.svg\" id=\"bad id\"]\n"
	FileAccess.open(invalid_id_abs, FileAccess.WRITE).store_string(invalid_text)
	var invalid := UIForgeTransaction.verify_scene_syntax(_trust_path("scene/invalid_id.tscn"))
	_assert(not invalid.get("ok", false), "scene_invalid_id_rejected")

func _test_resource_provenance() -> void:
	_prepare_trust_dir("provenance/existing.tscn")
	var create := UIForgeArtifact.check_create_allowed(_trust_path("provenance/new.tscn"), false)
	_assert(create.get("ok", false), "resource_create_allowed_missing")
	var existing := _trust_abs("provenance/existing.tscn")
	FileAccess.open(existing, FileAccess.WRITE).store_string(HUMAN_SCENE)
	var replace := UIForgeArtifact.check_replace_allowed(_trust_path("provenance/existing.tscn"), "res://tests/conformance/fixtures/minimal.ui.json", "", false)
	_assert(not replace.get("ok", false), "resource_human_replace_rejected")
	var force := UIForgeArtifact.check_replace_allowed(_trust_path("provenance/existing.tscn"), "res://tests/conformance/fixtures/minimal.ui.json", "", true)
	_assert(force.get("ok", false), "resource_force_allowed")

func _test_symlink_containment() -> void:
	if OS.get_name() == "Windows":
		return
	var workspace := UIForgePaths.workspace_root()
	var outside := "/tmp/uiforge_outside_%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(outside)
	var link_parent := "%s/trust_links" % workspace
	DirAccess.make_dir_recursive_absolute(link_parent)
	var link_path := "%s/escape_link" % link_parent
	var output: Array = []
	var exit_code := OS.execute("ln", ["-sfn", outside, link_path], output, true, false)
	if exit_code != 0:
		return
	var escape_target := "res://trust_links/escape_link/evil.tscn"
	var checked := UIForgePaths.validate_output(escape_target, UIForgePaths.ArtifactKind.SCENE, false)
	_assert(not checked.ok, "symlink_escape_blocked")
	OS.execute("rm", ["-rf", link_path], output, true, false)

func _test_windows_junction_containment() -> void:
	var workspace := UIForgePaths.workspace_root()
	var temp_root := OS.get_environment("TEMP") if OS.has_environment("TEMP") else "C:/Windows/Temp"
	var outside := "%s/uiforge_outside_%d" % [temp_root.replace("\\", "/"), Time.get_ticks_usec()]
	DirAccess.make_dir_recursive_absolute(outside)
	var link_parent := "%s/trust_junctions" % workspace
	DirAccess.make_dir_recursive_absolute(link_parent)
	var link_path := "%s/escape_link" % link_parent
	if DirAccess.dir_exists_absolute(link_path):
		OS.execute("cmd.exe", ["/c", "rmdir", link_path.replace("/", "\\")], [], true, false)
	var output: Array = []
	var ps_script := (
		"$target='%s'; $link='%s'; "
		+ "if (Test-Path -LiteralPath $link) { Remove-Item -LiteralPath $link -Force -Recurse -ErrorAction SilentlyContinue }; "
		+ "New-Item -ItemType Junction -Path $link -Target $target | Out-Null"
	) % [outside.replace("'", "''"), link_path.replace("'", "''")]
	var exit_code := OS.execute("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", ps_script], output, true, false)
	if exit_code != 0:
		exit_code = OS.execute(
			"cmd.exe",
			["/c", "mklink", "/J", link_path.replace("/", "\\"), outside.replace("/", "\\")],
			output,
			true,
			false
		)
	if exit_code != 0:
		failures.append("windows_junction_setup_failed")
		return
	var escape_target := "res://trust_junctions/escape_link/evil.tscn"
	var checked := UIForgePaths.validate_output(escape_target, UIForgePaths.ArtifactKind.SCENE, false)
	_assert(not checked.ok, "windows_junction_escape_blocked")
	if not checked.errors.is_empty():
		_assert(str(checked.errors[0].get("code", "")) == "OUTPUT_OUTSIDE_WORKSPACE", "windows_junction_escape_code")
	OS.execute("cmd.exe", ["/c", "rmdir", link_path.replace("/", "\\")], [], true, false)

func _generated_scene_text(source_identity_value: String, source_hash: String) -> String:
	var header_lines := UIForgeArtifact.provenance_header(source_identity_value, source_hash)
	return "\n".join(header_lines) + "\n" + GENERATED_SCENE_BODY

func _write_owner_json(lock_dir: String, payload: Dictionary) -> void:
	var file := FileAccess.open("%s/owner.json" % lock_dir, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(payload))
		file.close()

func _write_replace_meta(meta_abs: String, payload: Dictionary) -> void:
	var file := FileAccess.open(meta_abs, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(payload))
		file.close()

func _text_hash(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(file.get_as_text().to_utf8_buffer())
	file.close()
	return "sha256:%s" % context.finish().hex_encode()

func _cleanup_sidecars(dest_abs: String) -> void:
	if FileAccess.file_exists(dest_abs):
		DirAccess.remove_absolute(dest_abs)
	for suffix in [".uiforge_replace_backup", ".uiforge_replace_txn"]:
		var path := "%s%s" % [dest_abs, suffix]
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	for suffix in [".uiforge_lock", ".uiforge_reclaim_guard"]:
		var path := "%s%s" % [dest_abs, suffix]
		if DirAccess.dir_exists_absolute(path):
			DirAccess.remove_absolute(path)

func _has_error_code(result: Dictionary, code: String) -> bool:
	for item in result.get("errors", []):
		if str(item.get("code", "")) == code:
			return true
	return false

func _assert(condition: bool, name: String) -> void:
	if condition:
		passed += 1
	else:
		failures.append(name)
