extends RefCounted
## The actual Sheets Go backend hands off to real open-only foreign scenes.
func write(check: Callable, path: String, contents: String) -> void:
	var error := DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	check.call("foreign fixture opens " + path, error == OK and file != null)
	if file != null:
		file.store_string(contents)
		file.close()

func _save(editor: Editor, completion: Dictionary) -> void:
	completion["saved"] = await editor.prompt_close(true)
	completion["done"] = true

func run(check: Callable, pane: EditorPane, manager: PluginManager, server: MinervaMCPServer) -> void:
	var tree := pane.Tabs.get_tree()
	var directory := ProjectSettings.globalize_path("user://foreign-alias-contract")
	var manifest := {"id": "foreign_alias_fixture", "name": "Foreign", "version": "1.0.0", "host_api_version": "2",
		"backend": {"transport": "stdio", "entrypoint": "python3"},
		"ui": {"panels": [
			{"name": "main", "kind": "godot_scene", "entry_scene": "Panel.tscn", "scripts": ["Panel.gd"], "file_extensions": [".mdecklike"]},
			{"name": "paired", "kind": "godot_scene", "entry_scene": "Panel.tscn", "scripts": ["Panel.gd"], "file_extensions": [".twinfmt"], "render_mode": "paired_dsl"}]}}
	write(check, directory.path_join("manifest.json"), JSON.stringify(manifest))
	write(check, directory.path_join("Panel.gd"), 'extends "res://Scripts/Services/Plugins/MinervaPluginPanel.gd"\nvar document: Dictionary = {}\nfunc _on_panel_load_request(value: Variant) -> void:\n\tif value is Dictionary: document = value.duplicate(true)\n')
	write(check, directory.path_join("Panel.tscn"), '[gd_scene load_steps=2 format=3]\n[ext_resource type="Script" path="Panel.gd" id="1"]\n[node name="Foreign" type="Control"]\nscript = ExtResource("1")\n')
	var definition: PluginDefinition = manager.get_db().install(directory.path_join("manifest.json"))
	check.call("open-only foreign provider installs real native scenes", definition != null)
	if definition == null:
		return
	# This foreign fixture needs no backend methods: only its real scene is used.
	manager.get_db().update_state(definition.id, PluginDefinition.State.RUNNING)
	manager._ensure_runtime(definition.id)["ready"] = true
	for tool: String in ["minerva_sheets_create_editor"]:
		for extension: String in ["mdecklike", "twinfmt"]:
			var path := directory.path_join(tool + "." + extension)
			var original := '{"value":"foreign source"}'
			write(check, path, original)
			var arguments := {"name": "Ignored foreign title", "file_path": path}
			var before := pane.Tabs.get_tab_count()
			var result: Dictionary = await server.call_tool(tool, arguments)
			var expected_count := before + (2 if extension == "twinfmt" else 1)
			check.call(tool + " hands open-only " + extension + " to its owner without verification failure", result.get("success") == true
				and result.get("plugin_id") == definition.id and result.get("error_code", "") != "import_verification_failed"
				and result.get("note") == "name ignored for plugin-owned file" and pane.Tabs.get_tab_count() == expected_count)
			var again: Dictionary = await server.call_tool(tool, {"name": "", "file_path": path})
			check.call("foreign repeated creation reuses exact file identity " + extension, again.get("success") == true
				and again.get("editor_name") == result.get("editor_name") and not again.has("note")
				and pane.Tabs.get_tab_count() == expected_count and FileAccess.get_file_as_string(path) == original)
			var refused: Dictionary = await server.call_tool(tool, {"name": "Refused foreign", "file_path": path, "csv_content": "must not overwrite"})
			check.call("foreign initialization refuses before mutation " + extension, refused.get("success") == false and refused.get("error_code") == "invalid_arguments"
				and pane.Tabs.get_tab_count() == expected_count and FileAccess.get_file_as_string(path) == original)
			for editor: Editor in pane.get_open_editors():
				if editor.file == path:
					editor.free()
	# Canonical file-backed create must retain D9 even after switching to open.
	var csv_path := ProjectSettings.globalize_path("res://test/fixtures/spreadsheet_contract/sample.csv")
	var csv_bytes := FileAccess.get_file_as_bytes(csv_path)
	var created: Dictionary = await server.call_tool("minerva_sheets_create_editor", {"name": "Legacy CSV Save", "file_path": csv_path})
	var sheet: Editor = null
	for editor: Editor in pane.get_open_editors():
		if editor.tab_title == str(created.get("editor_name", "")):
			sheet = editor
	check.call("canonical CSV create returns its real native Sheets owner", created.get("success") == true and sheet != null and sheet.plugin_id == "sheets")
	if sheet != null:
		var dialog: FileDialog = sheet.get_node("FileDialog")
		dialog.use_native_dialog = false
		var saved: Dictionary = {}
		_save(sheet, saved)
		await tree.process_frame
		check.call("canonical CSV create Save prompts native conversion without touching source", dialog.visible
			and dialog.filters == PackedStringArray(["*.minsheet ; Plugin file"]) and FileAccess.get_file_as_bytes(csv_path) == csv_bytes)
		dialog.get_cancel_button().pressed.emit()
		await tree.process_frame
		await tree.process_frame
		check.call("canonical CSV Save As cancellation preserves binding and source", saved.get("done") == true
			and saved.get("saved") == false and sheet.file == csv_path and FileAccess.get_file_as_bytes(csv_path) == csv_bytes)
		sheet.free()
	manager.get_db().update_state(definition.id, PluginDefinition.State.STOPPED)
