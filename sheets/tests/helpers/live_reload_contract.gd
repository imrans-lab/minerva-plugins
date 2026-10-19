extends RefCounted
## Real packaged scenes, host save, generation swap and undo replay.

func run(check: Callable, pane: EditorPane, manager: PluginManager) -> void:
	var tree: SceneTree = pane.Tabs.get_tree()
	var definition: PluginDefinition = manager.get_db().get_by_id("sheets")
	var editors: Array[Editor] = []
	var models: Array[Dictionary] = []
	var saved_bytes: Array[PackedByteArray] = []
	var saved_paths: Array[String] = []
	for index: int in range(2):
		var editor: Editor = pane.add_plugin_scene_editor("sheets", "sheets_panel", null, "Live history %d" % index, "create")
		await tree.process_frame
		var sheet = editor.plugin_scene_root.get("sheet")
		sheet.set_content("A,B\n1,2")
		var path := ProjectSettings.globalize_path("user://live-history-%d.minsheet" % index)
		check.call("live reload witness saves through the real host", await editor.save_file_to_disc(path))
		saved_paths.append(path)
		saved_bytes.append(FileAccess.get_file_as_bytes(path))
		for value: int in [10, 20, 30]:
			sheet.set_cell_value_with_history(1, 0, value + index)
		sheet.undo()
		check.call("both live witnesses have unsaved edits and mixed history", editor._plugin_scene_modified
			and sheet.get_undo_count() == 2 and sheet.history.get_redo_count() == 1)
		models.append(PluginScenePanelHost.invoke_save(editor.plugin_scene_root, {}))
		editors.append(editor)
	var clean: Editor = pane.add_plugin_scene_editor("sheets", "sheets_panel", null, "Clean chart witness", "create")
	await tree.process_frame
	clean.plugin_scene_root.get("sheet").set_content("A,B\n1,2")
	var chart: Dictionary = await clean.plugin_scene_root.call("handle_tool", "minerva_sheets_add_chart",
		{"editor_name": clean.plugin_panel_key, "x_range": "A1:A2", "series": ["B1:B2"]})
	await tree.process_frame
	await tree.process_frame
	check.call("clean chart witness is produced by the real chart tool and host save", chart.get("success") == true
		and await clean.save_file_to_disc(ProjectSettings.globalize_path("user://live-clean-chart.minsheet")))
	var clean_model: Dictionary = PluginScenePanelHost.invoke_save(clean.plugin_scene_root, {})
	check.call("chart witness is clean before reload", not clean._plugin_scene_modified and clean_model.charts.size() == 1)
	var changes: Array[int] = [0]
	var observe := func() -> void: changes[0] += 1
	var clean_sheet: Control = clean.plugin_scene_root.get("sheet")
	clean_sheet.connect("content_changed", observe)
	clean_sheet.call("deserialize", clean_model)
	await tree.process_frame
	await tree.process_frame
	check.call("ordinary deserialize and its add_chart keep default change notifications", changes[0] > 0 and clean._plugin_scene_modified)
	clean_sheet.disconnect("content_changed", observe)
	check.call("ordinary chart witness is clean again through host save", await clean.save_file_to_disc(clean.file) and not clean._plugin_scene_modified)
	var scene_path: String = definition.data_directory.path_join("ui/SheetsPanel.tscn")
	var original: String = FileAccess.get_file_as_string(scene_path)
	var scene_file := FileAccess.open(scene_path, FileAccess.WRITE)
	scene_file.store_string(original + '\n[node name="QualificationMarker" type="Label" parent="."]\nlayout_mode = 2\ntext = "H2 LINUX MARKER"\n')
	scene_file.close()
	var result: Dictionary = await manager.reload_scene_plugin("sheets")
	check.call("packaged Sheets opts in and actually swaps the marker", manager.supports_scene_live_reload("sheets") and result.get("ok") == true)
	await tree.process_frame
	await tree.process_frame
	check.call("clean chart-bearing panel stays clean after deferred live reconstruction", clean.plugin_scene_root.has_node("QualificationMarker")
		and not clean._plugin_scene_modified and PluginScenePanelHost.invoke_save(clean.plugin_scene_root, {}) == clean_model)
	clean.free()
	for index: int in range(editors.size()):
		var editor: Editor = editors[index]
		var panel: Node = editor.plugin_scene_root
		var sheet = panel.get("sheet")
		check.call("marker swap preserves each complete model dirty flag and history depths", panel.has_node("QualificationMarker")
			and PluginScenePanelHost.invoke_save(panel, {}) == models[index] and editor._plugin_scene_modified
			and sheet.get_undo_count() == 2 and sheet.history.get_redo_count() == 1)
		for value: int in [10 + index, 1]:
			check.call("each retained undo restores its exact prior value", sheet.undo() and sheet.spreadsheet_data.get_cell_value(1, 0) == value)
		var copy_path := ProjectSettings.globalize_path("user://live-history-copy-%d.minsheet" % index)
		check.call("saved file bytes exclude live history and remain identical", await editor.save_file_to_disc(copy_path)
			and FileAccess.get_file_as_bytes(copy_path) == saved_bytes[index]
			and FileAccess.get_file_as_bytes(saved_paths[index]) == saved_bytes[index])
		for value: int in [10, 20, 30]:
			check.call("each retained redo restores its exact next value", sheet.redo() and sheet.spreadsheet_data.get_cell_value(1, 0) == value + index)
		check.call("undo after replay returns the captured complete model", sheet.undo() and PluginScenePanelHost.invoke_save(panel, {}) == models[index])
	var old_roots: Array = editors.map(func(editor: Editor) -> int: return editor.plugin_scene_root.get_instance_id())
	var pending: Dictionary = manager.installed_scene_update("sheets")
	check.call("Sheets marketplace updates retain the exact restart-pending contract", pending.get("ok") == true
		and pending.get("message") == "Update installed; restart to load the new panels"
		and not (await manager.reload_scene_plugin("sheets")).get("ok", true)
		and editors.map(func(editor: Editor) -> int: return editor.plugin_scene_root.get_instance_id()) == old_roots)
	for index: int in range(editors.size()):
		var sheet = editors[index].plugin_scene_root.get("sheet")
		check.call("restart-pending old Sheets panels remain editable", sheet.redo() and sheet.spreadsheet_data.get_cell_value(1, 0) == 30 + index)
		editors[index].free()
