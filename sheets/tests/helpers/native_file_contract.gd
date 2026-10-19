extends RefCounted
## Native files must restore the same document as a project snapshot.
const ValueDomain := preload("value_domain.gd")
const Data := preload("../../ui/domain/SpreadsheetData.gd")
const Excel := preload("../../ui/domain/ExcelHandler.gd")

func run(check: Callable, pane: EditorPane, host: Node) -> void:
	var tree: SceneTree = pane.Tabs.get_tree()
	var folder := ProjectSettings.globalize_path("user://native-file-contract")
	DirAccess.make_dir_recursive_absolute(folder)
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(
		"res://test/fixtures/spreadsheet_contract/baseline.minsheet"))
	var editor: Editor = pane.add_plugin_scene_editor("sheets", "sheets_panel", "", "Native chart witness", "")
	var panel: Node = editor.plugin_scene_root
	PluginScenePanelHost.invoke_load(panel, fixture)
	var chart: Dictionary = await panel.call("handle_tool", "minerva_sheets_add_chart", {
		"editor_name": editor.tab_title, "type": "bar", "x_range": "A1:A3",
		"series": ["B1:B3"], "title": "Native chart witness", "first_row_is_header": true})
	await tree.process_frame
	var model: Dictionary = PluginScenePanelHost.invoke_save(panel, {})
	check.call("native witness uses the actual chart tool", chart.get("success") == true and model.charts.size() == 1)
	var path := folder.path_join("host-save.minsheet")
	check.call("native host Save writes the complete chart-bearing model", await editor.save_file_to_disc(path)
		and ValueDomain.equal_json(JSON.parse_string(FileAccess.get_file_as_string(path)), model))
	var written_charts: String = JSON.stringify(JSON.parse_string(FileAccess.get_file_as_string(path)).charts)
	# Drive the real toolbar's file dialog; .minsheet requires no lossy-format confirmation.
	var sheet: Node = panel.get("sheet")
	sheet.call("_on_export_pressed")
	await tree.process_frame
	var dialog: FileDialog = sheet.get("export_dialog")
	dialog.use_native_dialog = false
	var exported := folder.path_join("toolbar-export.minsheet")
	dialog.current_path = exported
	dialog.get_ok_button().pressed.emit()
	await tree.process_frame
	check.call("native toolbar export writes the complete chart-bearing model", FileAccess.file_exists(exported)
		and ValueDomain.equal_json(JSON.parse_string(FileAccess.get_file_as_string(exported)), model))
	editor.free()
	for native_path: String in [path, exported]:
		var opened: Dictionary = host.call("open_file_at_path", native_path)
		var reopened: Editor = pane.Tabs.get_current_tab_control()
		# Full restoration deliberately recalculates after its existing 500 ms timer.
		await tree.create_timer(0.6).timeout
		var restored: Dictionary = PluginScenePanelHost.invoke_save(reopened.plugin_scene_root, {})
		check.call(native_path.get_file() + " actual host file reopen preserves the full model", opened.get("ok") == true
			and ValueDomain.equal_json(restored, model))
		var restored_sheet: Node = reopened.plugin_scene_root.get("sheet")
		var restored_data: RefCounted = restored_sheet.get("spreadsheet_data")
		check.call(native_path.get_file() + " formula display recalculates after native reopen", restored_data.call("get_cell_display", 3, 1) == "5")
		var second := native_path + ".second.minsheet"
		check.call(native_path.get_file() + " second save retains byte-identical chart data", await reopened.save_file_to_disc(second)
			and JSON.stringify(JSON.parse_string(FileAccess.get_file_as_string(second)).charts) == written_charts)
		reopened.free()
	# Freeze the actual small XLSX output before replacing its string assembly.
	var small: Data = Data.new()
	small.load_from_dict(fixture)
	small.recalculate_all()
	var evidence := ProjectSettings.globalize_path("res://../qr2-focus-evidence")
	DirAccess.make_dir_recursive_absolute(evidence)
	var small_path := evidence.path_join("current-small.xlsx")
	check.call("small XLSX baseline exports through the real archive writer", Excel.export_xlsx(small_path, small) == OK)
	var comparator := ProjectSettings.globalize_path("res://../../minerva-plugins/sheets/tests/helpers/compare_xlsx.py")
	var baseline := ProjectSettings.globalize_path("res://../../minerva-plugins/sheets/tests/fixtures/native-file-baseline.xlsx")
	var comparison: Array = []
	var compared: int = OS.execute("python3", PackedStringArray([comparator, baseline, small_path]), comparison, true)
	print("XLSX_BYTE_COMPARISON ", comparison)
	check.call("small XLSX retains every archive byte except ZIP clock fields", compared == 0)
	var imported: Data = Data.new()
	var snapshots: Array[Dictionary] = []
	var record := func() -> void: snapshots.append(imported.to_dict())
	imported.structure_changed.connect(record)
	imported.data_changed.connect(record)
	var result: Error = Excel.import_xlsx(small_path, imported)
	check.call("XLSX observers receive only the complete final model", result == OK and snapshots.size() == 2
		and snapshots[0] == imported.to_dict() and snapshots[1] == imported.to_dict()
		and imported.get_cell_display(3, 1) == "5" and not imported.is_blocking_signals())
	snapshots.clear()
	imported.set_block_signals(true)
	result = Excel.import_xlsx(small_path, imported)
	check.call("XLSX restores an already-blocked caller without publishing", result == OK and snapshots.is_empty()
		and imported.is_blocking_signals() and imported.get_cell_value(3, 1) == 5)
	imported.set_block_signals(false)
	imported.structure_changed.disconnect(record)
	imported.data_changed.disconnect(record)
	var persistence := preload("native_persistence_contract.gd").new()
	await persistence.run(check, pane, host)
