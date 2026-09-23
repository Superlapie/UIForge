extends SceneTree

var failures: Array[String] = []
var checks: int = 0
var scenarios: Dictionary = {}

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	_test_revision_retention_and_save_conflict()
	_test_dirty_savepoint_semantics()
	_test_cross_document_undo_isolation()
	_test_canvas_drag_resize_undo_reconciliation()
	_test_parentability_contract()
	_test_subtree_id_collisions_and_nodepath_remap()
	_test_editor_lock_semantics()
	_test_reusable_custom_component_materialization()
	_report()
	if failures.is_empty():
		print(JSON.stringify({"success": true, "passed": checks, "failed": 0, "scenarios": scenarios}))
		quit(0)
	else:
		print(JSON.stringify({"success": false, "passed": checks - failures.size(), "failed": failures.size(), "failures": failures, "scenarios": scenarios}, "\t"))
		quit(1)

func _report() -> void:
	scenarios = {
		"revision_retention_and_save_conflict": _scenario_count(["load_retains_disk_revision", "external_edit_save_conflict", "conflict_preserves_external_source", "reload_then_save_succeeds"]),
		"dirty_savepoint_semantics": _scenario_count(["edit_marks_dirty", "undo_to_saved_cleans", "redo_marks_dirty", "save_cleans", "undo_after_save_dirty", "redo_back_to_savepoint_clean"]),
		"cross_document_undo_isolation": _scenario_count(["undo_after_switch_keeps_document_b", "new_document_blocks_old_undo"]),
		"canvas_undo_reconciliation": _scenario_count(["canvas_move_undo_restores_layout", "canvas_resize_undo_restores_layout", "canvas_undo_reconciles_dirty"]),
		"parentability_contract": _scenario_count(["panel_accepts_child", "button_rejects_child", "quest_entry_rejects_child", "searchbox_rejects_child", "custom_container_accepts_child", "custom_leaf_rejects_child", "validator_matches_editor_parentability"]),
		"subtree_ops": _scenario_count(["descendant_duplicate_collision_prevented", "paste_subtree_collision_prevented", "local_focus_neighbor_remapped", "external_focus_neighbor_preserved"]),
		"editor_lock": _scenario_count(["locked_reparent_rejected", "locked_reorder_rejected", "locked_duplicate_rejected", "copy_still_allowed"]),
		"custom_component_instances": _scenario_count(["two_instance_scoped_ids_unique", "nested_component_scoped_ids_unique", "runtime_find_by_id_resolves_instance_child"]),
	}

func _scenario_count(labels: Array[String]) -> Dictionary:
	var passed := 0
	for label in labels:
		if label not in failures:
			passed += 1
	return {"passed": passed, "total": labels.size()}

func _assert(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)

func _make_studio() -> UIForgeStudio:
	var studio := UIForgeStudio.new()
	get_root().add_child(studio)
	return studio

func _test_revision_retention_and_save_conflict() -> void:
	var temp_path := "user://uiforge_integrity_conflict.ui.json"
	var document := UIForgeSerializer.create_default("integrity_conflict")
	document.data["root"]["properties"]["title"] = "Revision A"
	var first_save := UIForgeSerializer.save_document(document, temp_path)
	_assert(first_save.get("success", false), "load_retains_disk_revision_setup")
	var loaded := UIForgeSerializer.load_document(temp_path)
	_assert(str(loaded.get("revision_hash", "")).begins_with("sha256:"), "load_retains_disk_revision")
	var studio := _make_studio()
	studio.set_document(loaded["document"], temp_path, str(loaded.get("revision_hash", "")))
	_assert(studio.editor_session.disk_revision == str(loaded.get("revision_hash", "")), "load_retains_disk_revision")
	_assert(studio.editor_session.saved_content_revision == UIForgeHash.document_revision(studio.document), "load_retains_disk_revision")
	document.data["root"]["properties"]["title"] = "Revision B"
	UIForgeSerializer.save_document(document, temp_path)
	studio.document.data["root"]["properties"]["title"] = "Local edit"
	_assert(studio.editor_session.is_dirty(studio.document), "external_edit_save_conflict")
	var conflict := UIForgeSerializer.save_document(studio.document, temp_path, studio.editor_session.disk_revision)
	_assert(not conflict.get("success", false), "external_edit_save_conflict")
	var conflict_code := ""
	if conflict.get("errors", []) is Array and conflict["errors"].size() > 0:
		conflict_code = str(conflict["errors"][0].get("code", ""))
	_assert(conflict_code == "WRITE_CONFLICT", "external_edit_save_conflict")
	var external_loaded := UIForgeSerializer.load_document(temp_path)
	_assert(str(external_loaded["document"].data["root"]["properties"]["title"]) == "Revision B", "conflict_preserves_external_source")
	_assert(str(studio.document.data["root"]["properties"]["title"]) == "Local edit", "conflict_preserves_external_source")
	_assert(studio.editor_session.is_dirty(studio.document), "conflict_preserves_external_source")
	studio._load_document_path(temp_path)
	studio.document.data["root"]["properties"]["title"] = "Reloaded edit"
	var ok := UIForgeSerializer.save_document(studio.document, temp_path, studio.editor_session.disk_revision)
	_assert(ok.get("success", false), "reload_then_save_succeeds")
	studio.queue_free()
	if FileAccess.file_exists(temp_path):
		DirAccess.remove_absolute(temp_path)

func _test_dirty_savepoint_semantics() -> void:
	var studio := _make_studio()
	var document := UIForgeSerializer.create_default("savepoint")
	var temp_path := "user://uiforge_integrity_savepoint.ui.json"
	var initial_save := UIForgeSerializer.save_document(document, temp_path)
	_assert(initial_save.get("success", false), "edit_marks_dirty")
	var loaded := UIForgeSerializer.load_document(temp_path)
	studio.set_document(loaded["document"], temp_path, str(loaded.get("revision_hash", "")))
	_assert(not studio.dirty, "edit_marks_dirty")
	var baseline := studio.document.data.duplicate(true)
	studio.document.data["root"]["properties"]["title"] = "Edited"
	var edited := studio.document.data.duplicate(true)
	studio._reconcile_editor_state()
	_assert(studio.dirty, "edit_marks_dirty")
	studio.reconcile_document_snapshot(baseline, studio.editor_session.current_session_id())
	_assert(not studio.dirty, "undo_to_saved_cleans")
	studio.reconcile_document_snapshot(edited, studio.editor_session.current_session_id())
	_assert(studio.dirty, "redo_marks_dirty")
	var saved := UIForgeSerializer.save_document(studio.document, temp_path, studio.editor_session.disk_revision)
	_assert(saved.get("success", false), "save_cleans")
	studio.editor_session.on_successful_save(studio.document, UIForgeHash.file_revision(temp_path).get("hash", ""))
	studio._reconcile_editor_state()
	_assert(not studio.dirty, "save_cleans")
	var after_save := studio.document.data.duplicate(true)
	studio.document.data["root"]["properties"]["title"] = "After save edit"
	studio._reconcile_editor_state()
	_assert(studio.dirty, "undo_after_save_dirty")
	studio.reconcile_document_snapshot(after_save, studio.editor_session.current_session_id())
	_assert(not studio.dirty, "redo_back_to_savepoint_clean")
	studio.queue_free()
	if FileAccess.file_exists(temp_path):
		DirAccess.remove_absolute(temp_path)

func _test_cross_document_undo_isolation() -> void:
	var studio := _make_studio()
	var doc_a := UIForgeSerializer.create_default("doc_a")
	studio.set_document(doc_a, "")
	var before := doc_a.data.duplicate(true)
	doc_a.data["root"]["properties"]["title"] = "A edited"
	var session_a: int = studio.editor_session.current_session_id()
	studio._record_document_change("Edit A", before)
	var doc_b := UIForgeSerializer.create_default("doc_b")
	doc_b.data["root"]["properties"]["title"] = "B"
	studio.set_document(doc_b, "")
	studio.reconcile_document_snapshot(doc_a.data.duplicate(true), session_a)
	_assert(str(studio.document.data["root"]["properties"]["title"]) == "B", "undo_after_switch_keeps_document_b")
	var doc_new := UIForgeSerializer.create_default("doc_new")
	studio.set_document(doc_new, "")
	studio.reconcile_document_snapshot(doc_a.data.duplicate(true), session_a)
	_assert(str(studio.document.document_name()) == "doc_new", "new_document_blocks_old_undo")
	studio.queue_free()

func _test_canvas_drag_resize_undo_reconciliation() -> void:
	var studio := _make_studio()
	var document := UIForgeSerializer.create_default("canvas_undo")
	var root_id := str(document.root().get("id", ""))
	var panel := {"id": "drag_panel", "type": "Panel", "layout": {"position": [40, 40], "size": [120, 80]}, "children": []}
	document.add_child(root_id, panel)
	studio.set_document(document, "")
	document.data["viewport"]["scale_mode"] = "fixed"
	studio.canvas.set_viewport_preview(document.viewport_size())
	studio.canvas.zoom = 1.0
	studio.canvas.snap_enabled = false
	studio.canvas.studio = studio
	studio.canvas.selected_ids = ["drag_panel"]
	var before_move := document.data.duplicate(true)
	studio.canvas.drag_start_document = before_move
	studio.canvas.drag_start_mouse = Vector2(0, 0)
	studio.canvas.drag_start_positions = {"drag_panel": Vector2(40, 40)}
	studio.canvas.is_dragging = true
	studio.canvas._apply_drag(Vector2(32, 0), false)
	var moved: Variant = document.get_property("drag_panel", "layout.position")
	_assert(float(moved[0]) == 72.0 and float(moved[1]) == 40.0, "canvas_move_undo_restores_layout")
	var session_id: int = studio.editor_session.current_session_id()
	studio.reconcile_document_snapshot(before_move, session_id)
	var restored: Variant = document.get_property("drag_panel", "layout.position")
	_assert(float(restored[0]) == 40.0 and float(restored[1]) == 40.0, "canvas_move_undo_restores_layout")
	_assert(studio.editor_session.is_dirty(studio.document), "canvas_undo_reconciles_dirty")
	var before_resize := document.data.duplicate(true)
	studio.canvas.selected_ids = ["drag_panel"]
	studio.canvas.drag_start_mouse = Vector2(0, 0)
	studio.canvas.drag_start_size = Vector2(120, 80)
	studio.canvas.is_resizing = true
	studio.canvas.is_dragging = true
	studio.canvas._apply_drag(Vector2(40, 20), true)
	var resized: Variant = document.get_property("drag_panel", "layout.size")
	_assert(float(resized[0]) == 160.0 and float(resized[1]) == 100.0, "canvas_resize_undo_restores_layout")
	studio.reconcile_document_snapshot(before_resize, session_id)
	var size_restored: Variant = document.get_property("drag_panel", "layout.size")
	_assert(float(size_restored[0]) == 120.0 and float(size_restored[1]) == 80.0, "canvas_resize_undo_restores_layout")
	studio.queue_free()

func _test_parentability_contract() -> void:
	var custom := {
		"LeafCard": {"base": "PrimaryButton", "node": {"type": "Button"}},
		"BoxCard": {"base": "SimplePanel", "node": {"type": "Panel"}},
	}
	var panel := {"id": "panel", "type": "Panel"}
	var button := {"id": "button", "type": "Button"}
	var quest := {"id": "quest", "type": "QuestEntry"}
	var search := {"id": "search", "type": "SearchBox"}
	var custom_container := {"id": "box", "type": "ComponentInstance", "component": "BoxCard"}
	var custom_leaf := {"id": "leaf", "type": "ComponentInstance", "component": "LeafCard"}
	_assert(UIForgeParentability.can_contain_children(panel, custom), "panel_accepts_child")
	_assert(not UIForgeParentability.can_contain_children(button, custom), "button_rejects_child")
	_assert(not UIForgeParentability.can_contain_children(quest, custom), "quest_entry_rejects_child")
	_assert(not UIForgeParentability.can_contain_children(search, custom), "searchbox_rejects_child")
	_assert(UIForgeParentability.can_contain_children(custom_container, custom), "custom_container_accepts_child")
	_assert(not UIForgeParentability.can_contain_children(custom_leaf, custom), "custom_leaf_rejects_child")
	var doc := UIForgeDocument.from_dict({
		"schema_version": 1, "name": "parentability", "viewport": {"width": 800, "height": 600}, "theme": "dark_fantasy",
		"components": custom,
		"root": {"id": "root", "type": "Panel", "children": [{"id": "child", "type": "Label", "layout": {"position": [0, 0], "size": [10, 10]}}]}
	})
	doc.root()["children"].clear()
	doc.add_child(str(doc.root().get("id", "")), {"id": "bad", "type": "Label", "layout": {"position": [0, 0], "size": [10, 10]}})
	doc.root()["children"].clear()
	doc.root()["children"] = [{"id": "bad", "type": "Label", "layout": {"position": [0, 0], "size": [10, 10]}}]
	var under_button := UIForgeDocument.from_dict({
		"schema_version": 1, "name": "parentability", "viewport": {"width": 800, "height": 600}, "theme": "dark_fantasy",
		"root": {"id": "root", "type": "QuestEntry", "children": [{"id": "bad", "type": "Label", "layout": {"position": [0, 0], "size": [10, 10]}}]}
	})
	var validation := UIForgeValidator.new().validate(under_button)
	_assert(not validation.success, "validator_matches_editor_parentability")

func _test_subtree_id_collisions_and_nodepath_remap() -> void:
	var document := UIForgeDocument.from_dict({
		"schema_version": 1, "name": "subtree", "viewport": {"width": 800, "height": 600}, "theme": "dark_fantasy",
		"root": {
			"id": "root", "type": "Panel",
			"children": [
				{"id": "panel_copy_1", "type": "Label", "layout": {"position": [0, 0], "size": [10, 10]}},
				{
					"id": "panel", "type": "Panel", "layout": {"position": [20, 20], "size": [120, 80]},
					"children": [{"id": "panel_1", "type": "Label", "layout": {"position": [0, 0], "size": [10, 10]}}]
				}
			]
		}
	})
	var duplicate := document.duplicate_node("panel", "panel_copy")
	_assert(not duplicate.is_empty(), "descendant_duplicate_collision_prevented")
	var ids: Dictionary = {}
	for node in document.all_nodes():
		var node_id := str(node.get("id", ""))
		_assert(not ids.has(node_id), "descendant_duplicate_collision_prevented")
		ids[node_id] = true
	var original := document.find_node("panel").duplicate(true)
	var reserved: Dictionary = UIForgeSubtreeOps.collect_document_ids(document)
	var pasted: Dictionary = UIForgeSubtreeOps.clone_subtree(original, "panel_copy", reserved)
	_assert(pasted.get("ok", false), "paste_subtree_collision_prevented")
	var focus_doc := UIForgeDocument.from_dict(JSON.parse_string(FileAccess.get_file_as_string("res://tests/compiler_conformance/fixtures/focus_neighbor_remap.ui.json")))
	var group := focus_doc.find_node("focus_group")
	var cloned: Dictionary = UIForgeSubtreeOps.clone_subtree(group, "focus_group_copy", UIForgeSubtreeOps.collect_document_ids(focus_doc))
	_assert(cloned.get("ok", false), "local_focus_neighbor_remapped")
	var copy_group: Dictionary = cloned["node"]
	var left := _find_in_subtree(copy_group, "focus_group_copy_1")
	var right := _find_in_subtree(copy_group, "focus_group_copy_2")
	_assert(str(left.get("properties", {}).get("focus_neighbor_right", "")) == "focus_group_copy_2", "local_focus_neighbor_remapped")
	_assert(str(right.get("properties", {}).get("focus_neighbor_left", "")) == "focus_group_copy_1", "local_focus_neighbor_remapped")
	var external := focus_doc.find_node("external_anchor")
	_assert(str(external.get("properties", {}).get("focus_neighbor_top", "")) == "left_button", "external_focus_neighbor_preserved")

func _find_in_subtree(node: Dictionary, node_id: String) -> Dictionary:
	if str(node.get("id", "")) == node_id:
		return node
	for child in node.get("children", []):
		if child is Dictionary:
			var found := _find_in_subtree(child, node_id)
			if not found.is_empty():
				return found
	return {}

func _test_editor_lock_semantics() -> void:
	var studio := _make_studio()
	var document := UIForgeSerializer.create_default("lock_test")
	var root_id := str(document.root().get("id", ""))
	document.add_child(root_id, {"id": "locked_panel", "type": "Panel", "metadata": {"editor_locked": true}, "layout": {"position": [0, 0], "size": [100, 100]}, "children": []})
	document.add_child(root_id, {"id": "free_panel", "type": "Panel", "layout": {"position": [120, 0], "size": [100, 100]}, "children": []})
	studio.set_document(document, "")
	studio.canvas.select_node("locked_panel")
	studio._on_tree_node_drop("free_panel", "locked_panel")
	_assert(document.find_parent("free_panel").get("id", "") != "locked_panel", "locked_reparent_rejected")
	studio.canvas.select_node("locked_panel")
	studio._move_selected_by(1)
	var parent_after := document.find_parent("locked_panel")
	var children_after: Array = parent_after.get("children", [])
	var index_after: int = -1
	for i in children_after.size():
		if str(children_after[i].get("id", "")) == "locked_panel":
			index_after = i
			break
	_assert(index_after == 0, "locked_reorder_rejected")
	studio._on_canvas_duplicate("locked_panel")
	_assert(document.find_node("locked_panel_copy").is_empty(), "locked_duplicate_rejected")
	studio._on_canvas_copy(["locked_panel"])
	_assert(studio.clipboard_nodes.size() == 1, "copy_still_allowed")
	studio.queue_free()

func _test_reusable_custom_component_materialization() -> void:
	var source := "res://tests/compiler_conformance/fixtures/two_instance_custom_component.ui.json"
	var loaded := UIForgeSerializer.load_document(source)
	_assert(loaded.get("document") != null, "two_instance_scoped_ids_unique")
	var document: UIForgeDocument = loaded["document"]
	var custom: Dictionary = document.data.get("components", {})
	var card_a: Dictionary = UIForgeComponentLibrary.materialize(document.find_node("card_a"), custom)
	var card_b: Dictionary = UIForgeComponentLibrary.materialize(document.find_node("card_b"), custom)
	var ids: Dictionary = {}
	for child_id in ["card_a__title", "card_b__title"]:
		_assert(not ids.has(child_id), "two_instance_scoped_ids_unique")
		ids[child_id] = true
	_assert(_find_child_id(card_a, "card_a__title") != "", "two_instance_scoped_ids_unique")
	_assert(_find_child_id(card_b, "card_b__title") != "", "two_instance_scoped_ids_unique")
	var nested_source := "res://tests/compiler_conformance/fixtures/nested_custom_component.ui.json"
	var nested_loaded := UIForgeSerializer.load_document(nested_source)
	var nested_doc: UIForgeDocument = nested_loaded["document"]
	var nested_custom: Dictionary = nested_doc.data.get("components", {})
	var nested: Dictionary = UIForgeComponentLibrary.materialize(nested_doc.root(), nested_custom)
	_assert(_find_child_id(nested, "nested_custom_root__inner_label") != "", "nested_component_scoped_ids_unique")
	var output := "user://uiforge_integrity_two_instance.tscn"
	var compiled := UIForgeCompiler.new().compile_file(source, output, {"force": true, "allow_outside_project": true})
	_assert(compiled.get("success", false), "runtime_find_by_id_resolves_instance_child")
	var packed := load(output) as PackedScene
	_assert(packed != null, "runtime_find_by_id_resolves_instance_child")
	var root := packed.instantiate()
	_assert(UIForgeRuntime.find_by_id(root, "card_a__title") != null, "runtime_find_by_id_resolves_instance_child")
	_assert(UIForgeRuntime.find_by_id(root, "card_b__title") != null, "runtime_find_by_id_resolves_instance_child")
	root.free()

func _find_child_id(node: Dictionary, target: String) -> String:
	if str(node.get("id", "")) == target:
		return target
	for child in node.get("children", []):
		if child is Dictionary:
			var found := _find_child_id(child, target)
			if not found.is_empty():
				return found
	return ""
