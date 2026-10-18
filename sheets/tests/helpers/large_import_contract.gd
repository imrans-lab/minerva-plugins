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

	var cell_path: String = ProjectSettings.globalize_path("user://large-first-cell.csv")
	file = FileAccess.open(cell_path, FileAccess.WRITE)
	file.store_string("Huge".repeat(20000) + "\ntail")
	file.close()
	var cell_source: PackedByteArray = FileAccess.get_file_as_bytes(cell_path)
	check.call("first-cell import really exceeds the read budget", cell_source.size() > 30 * 1024)
	var cell_before: int = pane.Tabs.get_tab_count()
	var cell_args := {"name": "Large first cell", "file_path": cell_path}
	var cell_first: Dictionary = await registry.handle_tool_call("minerva_sheets_create_editor", cell_args)
	var cell_again: Dictionary = await registry.handle_tool_call("minerva_sheets_create_editor", cell_args)
	check.call("actual backend accepts counts from a large-first-cell read refusal", cell_first.get("success") == true and cell_first.get("rows_imported") == 2)
	check.call("large-first-cell repeat preserves one tab and two rows", cell_again.get("success") == true and cell_again.get("rows_imported") == 2 and pane.Tabs.get_tab_count() == cell_before + 1)
	var refused: Dictionary = await registry.handle_tool_call("minerva_sheets_get_data", {"editor_name": cell_first.get("editor_name", "missing"), "range": "A1"})
	check.call("large-first-cell data read still refuses explicitly", refused.get("error_code") == "cell_too_large" and refused.get("used_row_count") == 2 and not refused.has("data"))
	check.call("large-first-cell verification preserves source bytes", FileAccess.get_file_as_bytes(cell_path) == cell_source)
	for editor: Editor in pane.get_open_editors():
		if editor.file == cell_path:
			editor.free()
