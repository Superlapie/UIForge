class_name UIForgeEditorSession
extends RefCounted

## Tracks disk revision, saved content revision, and document-scoped undo identity for the editor.

var disk_revision: String = ""
var saved_content_revision: String = ""
var document_session_id: int = 0

func reset_for_document(document: UIForgeDocument, loaded_disk_revision: String = "", has_persisted_source: bool = false) -> void:
	document_session_id += 1
	disk_revision = loaded_disk_revision
	if has_persisted_source:
		saved_content_revision = _content_revision(document)
	else:
		saved_content_revision = ""

func on_successful_save(document: UIForgeDocument, new_disk_revision: String = "") -> void:
	if document == null:
		return
	disk_revision = new_disk_revision if not new_disk_revision.is_empty() else _content_revision(document)
	saved_content_revision = _content_revision(document)

func is_dirty(document: UIForgeDocument) -> bool:
	if document == null:
		return false
	if saved_content_revision.is_empty():
		return true
	return _content_revision(document) != saved_content_revision

func current_session_id() -> int:
	return document_session_id

func _content_revision(document: UIForgeDocument) -> String:
	return UIForgeHash.document_revision(document)
