extends RefCounted
## File import, not a giant RPC request; verification must read only metadata.

func run(check: Callable, pane: EditorPane, registry: PluginToolRegistry) -> void:
	var path: String = ProjectSettings.globalize_path("user://large-read-verification.csv")
	var file := FileAccess.open(path, FileAccess.WRITE)
	check.call("large import fixture can be written", file != null)
	if file == null:
		return
	file.store_line("Header")
	for index: int in range(5000):
		file.store_line("record%d-" % index + "x".repeat(1800))
	file.close()
	var original: PackedByteArray = FileAccess.get_file_as_bytes(path)
	check.call("large import source is actually above8MiB", original.size() > 8 * 1024 * 1024)
	var before: int = pane.Tabs.get_tab_count()
	var args := {"name": "Large verified import", "file_path": path}
	var first: Dictionary = await registry.handle_tool_call("minerva_sheets_create_editor", args)
	var again: Dictionary = await registry.handle_tool_call("minerva_sheets_create_editor", args)
	check.call("actual Go backend verifies all5001 imported rows above8MiB", first.get("success") == true and first.get("rows_imported") == 5001)
	check.call("repeat large file creation reuses one tab and keeps row counts", again.get("success") == true and again.get("rows_imported") == 5001 and pane.Tabs.get_tab_count() == before + 1 and first.get("editor_name") == again.get("editor_name"))
	check.call("large import and verification never overwrite the source", FileAccess.get_file_as_bytes(path) == original)
	for editor: Editor in pane.get_open_editors():
		if editor.file == path:
			var data = editor.plugin_scene_root.call("get_sheet_data")
			check.call("large import retains complete first and last values", data.get_cell_value(0, 0) == "Header" and data.get_cell_value(5000, 0) == "record4999-" + "x".repeat(1800))
			editor.free()
