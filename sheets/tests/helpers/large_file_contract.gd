extends RefCounted
## The realistic H1 model through each public file boundary before Windows Q.
const Dense := preload("dense_import_contract.gd")
const ValueDomain := preload("value_domain.gd")
const SaveContract := preload("save_contract.gd")

func _model(editor: Editor) -> Dictionary:
	return PluginScenePanelHost.invoke_save(editor.plugin_scene_root, {})

func _within(check: Callable, label: String, started: int) -> void:
	var elapsed: int = Time.get_ticks_msec() - started
	print("LARGE_FILE_MS ", label, "=", elapsed)
	check.call(label + " finishes within ten seconds", elapsed <= 10000)

func _find(pane: EditorPane, title: String) -> Editor:
	for editor: Editor in pane.get_open_editors():
		if editor.tab_title == title:
			return editor
	return null

func run(check: Callable, pane: EditorPane, host: Node, registry: PluginToolRegistry, manager: PluginManager) -> void:
	var tree: SceneTree = pane.Tabs.get_tree()
	var folder := ProjectSettings.globalize_path("user://large-file-contract")
	DirAccess.make_dir_recursive_absolute(folder)
	var csv := folder.path_join("H1 10k Zoë.csv")
	var file := FileAccess.open(csv, FileAccess.WRITE)
	file.store_string(Dense.fixture_csv())
	file.close()
	check.call("large file sweep uses the immutable H1 CSV", FileAccess.get_sha256(csv) == Dense.CSV_SHA256)
	var started: int = Time.get_ticks_msec()
	var created: Dictionary = await registry.handle_tool_call("minerva_sheets_create_editor", {"name": "Large file sweep", "file_path": csv})
	var editor: Editor = _find(pane, str(created.get("editor_name", "")))
	await RenderingServer.frame_post_draw
	_within(check, "large CSV create and render", started)
	check.call("large CSV create preserves the independent full model", editor != null and ValueDomain.equal_json(_model(editor), Dense.new()._expected_model()))
	if editor == null:
		return
	var panel: Node = editor.plugin_scene_root
	var sheet: Node = panel.get("sheet")
	sheet.call("format_cell_with_history", 4, 4, {"bold": true, "bg_color": Color.RED})
	var chart: Dictionary = await panel.call("handle_tool", "minerva_sheets_add_chart", {"editor_name": editor.tab_title,
		"type": "bar", "x_range": "A1:A3", "series": ["B1:B3"], "title": "Large file chart", "first_row_is_header": true})
	var enabled: Dictionary = await panel.call("handle_tool", "minerva_sheets_autofilter_enable", {"editor_name": editor.tab_title, "range": "A1:T10000"})
	var filtered: Dictionary = await panel.call("handle_tool", "minerva_sheets_autofilter_set", {"editor_name": editor.tab_title, "column": 1, "values": ["1"]})
	check.call("large file witness has a real chart, formats and active filter", chart.get("success") == true and enabled.get("success") == true
		and filtered.get("success") == true and filtered.get("visible_count") == 1)
	var expected: Dictionary = _model(editor)
	var native := folder.path_join("Save As Zoë.minsheet")
	started = Time.get_ticks_msec()
	var completion: Dictionary = {}
	var saves := SaveContract.new()
	saves._prompt(editor, completion)
	await tree.process_frame
	var dialog: FileDialog = editor.get_node("FileDialog")
	dialog.use_native_dialog = false
	dialog.current_path = native
	dialog.get_ok_button().pressed.emit()
	await tree.process_frame
	await tree.process_frame
	_within(check, "large native Save As", started)
	check.call("large native Save As writes the full model", completion.get("saved") == true and ValueDomain.equal_json(JSON.parse_string(FileAccess.get_file_as_string(native)), expected))
	started = Time.get_ticks_msec()
	check.call("large native Save in place preserves full model", await editor.save_file_to_disc(native)
		and ValueDomain.equal_json(JSON.parse_string(FileAccess.get_file_as_string(native)), expected))
	_within(check, "large native Save", started)
	editor.free()
	started = Time.get_ticks_msec()
	var opened: Dictionary = host.call("open_file_at_path", native)
	await RenderingServer.frame_post_draw
	editor = pane.Tabs.get_current_tab_control()
	_within(check, "large native host reopen and render", started)
	check.call("large native reopen keeps full model including chart and filter", opened.get("ok") == true and ValueDomain.equal_json(_model(editor), expected))
	panel = editor.plugin_scene_root
	sheet = panel.get("sheet")
	for extension: String in ["minsheet", "csv", "tsv", "xlsx"]:
		var destination := folder.path_join("toolbar." + extension)
		started = Time.get_ticks_msec()
		sheet.call("_on_export_pressed")
		await tree.process_frame
		var export_dialog: FileDialog = sheet.get("export_dialog")
		export_dialog.use_native_dialog = false
		export_dialog.current_path = destination
		export_dialog.get_ok_button().pressed.emit()
		await tree.process_frame
		if extension != "minsheet":
			var confirmation: ConfirmationDialog = sheet.get_node("ExportConfirmation")
			confirmation.get_ok_button().pressed.emit()
			await tree.process_frame
		_within(check, "large toolbar export " + extension, started)
		check.call(extension + " export preserves source full model and immutable CSV", FileAccess.file_exists(destination)
			and ValueDomain.equal_json(_model(editor), expected) and FileAccess.get_sha256(csv) == Dense.CSV_SHA256)
		started = Time.get_ticks_msec()
		var imported: Dictionary = host.call("open_file_at_path", destination)
		await RenderingServer.frame_post_draw
		var copy: Editor = pane.Tabs.get_current_tab_control()
		_within(check, "large host reimport " + extension, started)
		var observed: Dictionary = _model(copy)
		if extension == "minsheet":
			check.call("large native toolbar roundtrip preserves complete model", imported.get("ok") == true and ValueDomain.equal_json(observed, expected))
		else:
			var values_equal: bool = observed.cells.size() == expected.cells.size()
			for key: String in expected.cells:
				values_equal = values_equal and observed.cells.has(key) and observed.cells[key].value == expected.cells[key].value
			check.call(extension + " reimport preserves every cell value within declared format loss", imported.get("ok") == true and values_equal)
			if extension == "xlsx":
				check.call("large XLSX fresh host import preserves SUM formula and result", observed.cells["1,2"].formula == "=SUM(B2:B3)" and observed.cells["1,2"].value == 5)
		copy.free()
		check.call(extension + " reimport leaves original full model unchanged", ValueDomain.equal_json(_model(editor), expected))
	editor.free()
	started = Time.get_ticks_msec()
	created = await registry.handle_tool_call("minerva_sheets_create_editor", {"name": "Large native MCP reopen", "file_path": native})
	editor = _find(pane, str(created.get("editor_name", "")))
	await RenderingServer.frame_post_draw
	_within(check, "large native MCP create and render", started)
	check.call("large native MCP create preserves complete model", editor != null and ValueDomain.equal_json(_model(editor), expected))
	if editor == null:
		return
	started = Time.get_ticks_msec()
	manager.stop_plugin("sheets")
	var stopped: Dictionary = await registry.handle_tool_call("minerva_sheets_create_editor", {"name": "Stopped large-sheet provider"})
	check.call("large sheet backend loss refuses visibly and retains full model", stopped.get("success") == false and ValueDomain.equal_json(_model(editor), expected))
	var restarted: Dictionary = await manager.start_plugin("sheets")
	var retried: Dictionary = await registry.handle_tool_call("minerva_sheets_get_data", {"editor_name": editor.tab_title, "range": "B2:C3"})
	_within(check, "large backend restart and retry", started)
	check.call("large sheet recovery keeps the complete document", restarted.get("ok") == true and retried.get("success") == true and ValueDomain.equal_json(_model(editor), expected))
	var filter: Dictionary = await editor.plugin_scene_root.call("handle_tool", "minerva_sheets_autofilter_get", {"editor_name": editor.tab_title})
	check.call("large sheet filter survives every boundary and backend restart", filter.get("success") == true and filter.get("visible_count") == 1)
	editor.free()
