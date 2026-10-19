extends RefCounted
const ValueDomain := preload("value_domain.gd")
const Data := preload("../../ui/domain/SpreadsheetData.gd")
const Files := preload("../../ui/domain/SpreadsheetFileHandler.gd")
const Excel := preload("../../ui/domain/ExcelHandler.gd")
const SaveErrors := preload("save_contract.gd").SaveErrors

func _select_export(sheet: Node, path: String, tree: SceneTree) -> void:
	sheet.call("_on_export_pressed")
	await tree.process_frame
	var dialog: FileDialog = sheet.get("export_dialog")
	dialog.use_native_dialog = false
	dialog.current_path = path
	dialog.get_ok_button().pressed.emit()
	await tree.process_frame

func run(check: Callable, pane: EditorPane) -> void:
	var tree: SceneTree = pane.Tabs.get_tree()
	var folder := ProjectSettings.globalize_path("user://export-contract")
	DirAccess.make_dir_recursive_absolute(folder)
	var source := ProjectSettings.globalize_path("res://test/fixtures/spreadsheet_contract/baseline.minsheet")
	var source_bytes := FileAccess.get_file_as_bytes(source)
	var editor: Editor = pane.add_plugin_scene_editor("sheets", "sheets_panel", source, "Export source", "")
	var panel: Node = editor.plugin_scene_root
	var sheet: Node = panel.get("sheet")
	# Live generations load their own model script, distinct from this test's preload.
	var data = sheet.get("spreadsheet_data")
	data.recalculate_all()
	var model: Dictionary = PluginScenePanelHost.invoke_save(panel, {})
	var dirty: bool = editor._plugin_scene_modified
	var other: Editor = pane.add_plugin_scene_editor("sheets", "sheets_panel", "", "Independent export", "")
	var other_data: RefCounted = other.plugin_scene_root.call("get_sheet_data")
	other_data.call("set_cell_value", 0, 0, "other document")
	var other_model: Dictionary = PluginScenePanelHost.invoke_save(other.plugin_scene_root, {})
	var errors := SaveErrors.new()
	OS.add_logger(errors)
	for extension: String in ["csv", "tsv", "xlsx"]:
		var destination := folder.path_join("copy." + extension)
		await _select_export(sheet, destination, tree)
		var confirmation: ConfirmationDialog = sheet.get_node("ExportConfirmation")
		check.call(extension + " export requires format-specific loss confirmation before write", confirmation.visible
			and confirmation.dialog_text.contains(extension.to_upper()) and confirmation.dialog_text.contains("charts")
			and not FileAccess.file_exists(destination) and not FileAccess.file_exists(destination + ".tmp"))
		sheet.call("_on_export_pressed")
		check.call(extension + " repeated export keeps the original confirmation", confirmation.visible and not sheet.get("export_dialog").visible)
		confirmation.get_cancel_button().pressed.emit()
		await tree.process_frame
		check.call(extension + " export cancel preserves complete model, source and dirty state", not FileAccess.file_exists(destination)
			and editor.file == source and editor._plugin_scene_modified == dirty and FileAccess.get_file_as_bytes(source) == source_bytes
			and ValueDomain.equal_json(PluginScenePanelHost.invoke_save(panel, {}), model))
		await _select_export(sheet, destination, tree)
		confirmation.get_ok_button().pressed.emit()
		await tree.process_frame
		var imported: Data = Data.new()
		check.call(extension + " confirmed export reopens in a fresh model", FileAccess.file_exists(destination) and Files.import_file(destination, imported) == OK)
		imported.recalculate_all()
		check.call(extension + " export retains independent cell-value oracle", imported.get_cell_display(1, 0) == "keep" and ValueDomain.equal_json(
			[imported.get_cell_value(1, 1), imported.get_cell_value(2, 1), imported.get_cell_value(3, 1)], [2, 3, 5]))
		check.call(extension + " leading-empty A4 remains blank while B4 retains5", imported.get_cell_display(3, 0).is_empty()
			and ValueDomain.equal_json(imported.get_cell_value(3, 1), 5))
		if extension == "xlsx":
			check.call("XLSX formula survives actual ZIP export and fresh import", imported.get_cell(3, 1).formula == "=SUM(B2:B3)" and ValueDomain.equal_json(imported.get_cell_value(3, 1), 5))
			ValueDomain.new().check_model_roundtrip(check, imported.to_dict(), "XLSX formula export")
		check.call(extension + " export leaves both live panels and source untouched", editor.file == source and editor._plugin_scene_modified == dirty
			and FileAccess.get_file_as_bytes(source) == source_bytes and ValueDomain.equal_json(PluginScenePanelHost.invoke_save(panel, {}), model)
			and ValueDomain.equal_json(PluginScenePanelHost.invoke_save(other.plugin_scene_root, {}), other_model))
		var blocked := folder.path_join("blocked." + extension)
		DirAccess.make_dir_recursive_absolute(blocked)
		var marker := blocked.path_join("marker")
		FileAccess.open(marker, FileAccess.WRITE).store_string("original")
		sheet.call("_on_export_file_selected", blocked)
		confirmation.get_ok_button().pressed.emit()
		await tree.process_frame
		var status: RichTextLabel = panel.get_node("Status")
		check.call(extension + " failed export is visible copyable logged and preserves files/model", status.visible and status.selection_enabled
			and errors.contains(status.text) and FileAccess.get_file_as_string(marker) == "original" and editor.file == source
			and editor._plugin_scene_modified == dirty and ValueDomain.equal_json(PluginScenePanelHost.invoke_save(panel, {}), model))
	# Physical archives exercise the same staged publication phase as real export.
	var expected_parts: Dictionary[String, String] = {"sheet.xml": "<sheet>expected</sheet>", "meta.xml": "<meta/>"}
	var old_target_bytes := FileAccess.get_file_as_bytes(folder.path_join("copy.xlsx"))
	var protected_path := folder.path_join("protected.xlsx")
	for corruption: String in ["truncated", "missing", "changed"]:
		var scratch := folder.path_join(corruption + ".zip.tmp")
		var zip := ZIPPacker.new()
		var prepared: bool = zip.open(scratch) == OK
		for name: String in expected_parts:
			if corruption == "missing" and name == "meta.xml":
				continue
			var text: String = "<sheet>changed</sheet>" if corruption == "changed" and name == "sheet.xml" else expected_parts[name]
			prepared = (zip.start_file(name) == OK and zip.write_file(text.to_utf8_buffer()) == OK) and prepared
		prepared = zip.close() == OK and prepared
		if corruption == "truncated":
			var archive_bytes := FileAccess.get_file_as_bytes(scratch)
			var truncated := FileAccess.open(scratch, FileAccess.WRITE)
			prepared = truncated.store_buffer(archive_bytes.slice(0, archive_bytes.size() >> 1)) and prepared
			truncated.close()
		var protected := FileAccess.open(protected_path, FileAccess.WRITE)
		prepared = protected.store_buffer(old_target_bytes) and prepared
		protected.close()
		check.call(corruption + " ZIP publication fixture has an existing valid target", prepared and not old_target_bytes.is_empty())
		check.call(corruption + " ZIP refuses before replacement and preserves existing target", Excel._publish_archive(protected_path, scratch, expected_parts) != OK
			and FileAccess.get_file_as_bytes(protected_path) == old_target_bytes and not FileAccess.file_exists(protected_path + ".tmp")
			and ValueDomain.equal_json(PluginScenePanelHost.invoke_save(panel, {}), model))
		DirAccess.remove_absolute(scratch)
	var fallback := folder.path_join("copy.unknown")
	sheet.call("_on_export_file_selected", fallback)
	var fallback_confirmation: ConfirmationDialog = sheet.get_node("ExportConfirmation")
	check.call("existing CSV fallback also requires explicit loss confirmation", fallback_confirmation.visible
		and fallback_confirmation.dialog_text.begins_with("CSV ") and not FileAccess.file_exists(fallback))
	fallback_confirmation.get_cancel_button().pressed.emit()
	OS.remove_logger(errors)
	# Closing a second panel during confirmation cannot later publish its path.
	var closed_path := folder.path_join("closed.csv")
	var other_sheet: Node = other.plugin_scene_root.get("sheet")
	await _select_export(other_sheet, closed_path, tree)
	other.free()
	await tree.process_frame
	check.call("closing during export confirmation writes nothing and leaves first panel intact", not FileAccess.file_exists(closed_path)
		and ValueDomain.equal_json(PluginScenePanelHost.invoke_save(panel, {}), model))
	editor.free()
