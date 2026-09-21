class_name UIForgeTemplates
extends RefCounted
## Shared populated screen catalog for the editor and CLI.

static func catalog() -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://addons/uiforge/components/templates.json"))
	return parsed if parsed is Dictionary else {}

static func create(template_name: String, document_name: String) -> Dictionary:
	if template_name in ["blank", "window", "modal"]:
		return {"document": UIForgeSerializer.create_default(document_name), "errors": []}
	var entries := catalog()
	if not entries.has(template_name):
		return {"document": null, "errors": [{"code": "UNKNOWN_TEMPLATE", "message": "Unknown template: %s" % template_name}]}
	var result := UIForgeSerializer.load_document(str(entries[template_name].path))
	if result.get("document") != null:
		result.document.data["name"] = document_name
		result.document.source_path = ""
		result.document.data["metadata"]["template"] = template_name
	return result
