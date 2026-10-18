extends Node
signal completed(code: int)
var passed: int = 0
var failed: int = 0
var _project_container: Node
var _project_replies: Dictionary = {}

func check(label: String, condition: bool) -> void:
	if condition:
		passed += 1
		print("PASS: " + label)
	else:
		failed += 1
		printerr("FAIL: " + label)

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	await get_tree().create_timer(3.0).timeout
	# The host autoload has no global class; runtime loading is required by --script.
	var host = get_tree().root.get_node("SingletonObject")
	var ui := preload("res://test/helpers/chat_host_render_fixture.gd").new()
	ui.install(host)
	var old: Array = [host.plugin_manager, host.plugin_scene_panel_broker, host.editor_pane,
		host.plugin_editor_registry, host.creatable_item_registry, host.plugin_tool_registry, host.editor_container]
	var manager := PluginManager.new()
	manager._db = PluginDB.new()
	var database: PluginDB = manager.get_db()
	var policy := PluginPolicy.new(database, null, false)
	var registry := PluginToolRegistry.new(manager, policy)
	manager.configure_dependency_tools(registry)
	manager._policy_ref = policy
	var capabilities := CapabilityBroker.new(policy)
	var broker := PluginScenePanelBroker.new(manager, policy, capabilities)
	registry.scene_panel_broker = broker
	host.plugin_manager = manager
	host.plugin_tool_registry = registry
	host.plugin_scene_panel_broker = broker
	get_tree().root.add_child(manager)
	manager.set_process(false)
	var pane := EditorPane.new()
	var tabs := TabContainer.new()
	get_tree().root.add_child(tabs)
	pane.Tabs = tabs
	pane.buffer_control_editor = Control.new()
	host.editor_pane = pane
	host.creatable_item_registry = CreatableItemRegistry.new()
	host.plugin_editor_registry = PluginEditorRegistry.new()
	host._wire_plugin_editor_extensions(manager)
	var source := ProjectSettings.globalize_path("res://../../minerva-plugins/sheets")
	check("fixture plugin is initially absent", not database.has_plugin("sheets"))
	# A valid stale Go executable proves the installer rebuilds, without hitting
	# Go's deliberate refusal to overwrite an arbitrary non-object file.
	var stale_bytes := FileAccess.get_file_as_bytes(source.path_join("tests/proxy/sheets-proxy"))
	check("stale setup sentinel is a real compiled Go fixture", stale_bytes.size() > 1000)
	check("stale fixture binary can be staged", DirAccess.copy_absolute(source.path_join("tests/proxy/sheets-proxy"), source.path_join("sheets-plugin")) == OK)
	var installed: Dictionary = await manager.install_plugin(source.path_join("manifest.json"), true)
	var definition: PluginDefinition = database.get_by_id("sheets")
	check("public source installer starts the declared setup", installed.get("ok") == true and installed.get("building") == true)
	while definition != null and definition.state == manager.S_BUILDING:
		await get_tree().process_frame
	check("declared setup replaces the stale binary", definition != null and definition.state == manager.S_INSTALLED
		and manager.get_setup_envelope("sheets").is_empty()
		and FileAccess.get_file_as_bytes(source.path_join("sheets-plugin")) != stale_bytes)
	for extension: String in [".minsheet", ".csv", ".tsv", ".xlsx"]:
		check(extension + " is claimed by the installed Sheets loader", host.plugin_editor_registry.resolve_file(extension).get("plugin_id") == "sheets")
	if definition != null:
		var started: Dictionary = await manager.start_plugin("sheets")
		check("actual Sheets backend initializes", started.get("ok", false) == true)
		manager.get_connection("sheets").tool_result_received.connect(_project_reply)
		check("Sheets backend reports running", manager.get_plugin_status("sheets").get("running", false) == true)
		host._register_plugin_editor_items("sheets")
		var item: CreatableItemRegistry.CreatableItem = host.creatable_item_registry.get_item("new_minsheet")
		check("new_minsheet is registered with a callback", item != null and item.create_callback.is_valid())
		var registrations: Array[String] = []
		broker.panel_registered.connect(func(id: String, _panel: String) -> void: registrations.append(id))
		if item != null:
			item.create_callback.call()
			await get_tree().process_frame
		check("source editor item creates exactly one tab", tabs.get_tab_count() == 1)
		if tabs.get_tab_count() == 1:
			var editor: Editor = tabs.get_child(0)
			var panel: Node = editor.plugin_scene_root
			check("source panel mounted once through the create handoff", panel != null and registrations == ["sheets"])
			var sheet = panel.get("sheet") if panel != null else null
			var button: Button = sheet.get("_bold_btn") if sheet != null else null
			check("raw PNG icon loads outside the import database", button != null and button.icon != null)
			var expected: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://test/fixtures/spreadsheet_contract/baseline.minsheet"))
			PluginScenePanelHost.invoke_load(panel, expected)
			var protected_path := ProjectSettings.globalize_path("user://sheets-hosting-save.minsheet")
			var saved: bool = await editor.save_file_to_disc(protected_path)
			check("host-owned save preserves the complete native model", saved
				and JSON.parse_string(FileAccess.get_file_as_string(protected_path)) == expected)
			await _proxy_probe(host, source, registry, policy, capabilities, definition, editor.tab_title)
		var guard := PluginGenerationStore.new("sheets_guard_probe")
		var domain_source := FileAccess.get_file_as_string(source.path_join("ui/domain/SpreadsheetEditor.gd"))
		check("shipped spreadsheet source satisfies the public-resource guard", guard.normalize_resource("ui/domain/SpreadsheetEditor.gd", domain_source).get("ok") == true)
		for forbidden: String in ["res://Scripts/UI/Controls/Note.gd", "uid://private-probe"]:
			var planted := domain_source + '\nconst ForbiddenProbe := preload("' + forbidden + '")\n'
			check("private resource injection is refused: " + forbidden, guard.normalize_resource("ui/domain/SpreadsheetEditor.gd", planted).get("ok") == false)
		await _hosting_contract(host, pane, manager)
		var contract: RefCounted = load(source.path_join("tests/helpers/tool_contract.gd")).new()
		await contract.call("run", check, pane, registry, broker, source)

		definition.class_names.assign(["WrongPrefix_Panel"])
		check("wrong class prefix is refused explicitly", definition.validate_class_names({}, []).get("error") == "class_name_bad_prefix")
		var packed: PackedScene = load(source.path_join("ui/SheetsPanel.tscn"))
		check("unlisted scene script is refused", not PluginScenePanelHost._audit_packed_scene(packed, PackedStringArray()))
		manager.stop_plugin("sheets")
	check("fixture installation is removed from persistent DB", database.remove("sheets") and not PluginDB.new().has_plugin("sheets"))
	tabs.free()
	pane.buffer_control_editor.free()
	pane.free()
	host.plugin_manager = old[0]
	host.plugin_scene_panel_broker = old[1]
	host.editor_pane = old[2]
	host.plugin_editor_registry = old[3]
	host.creatable_item_registry = old[4]
	host.plugin_tool_registry = old[5]
	host.editor_container = old[6]
	if _project_container != null:
		_project_container.free()
	manager.free()
	ui.restore()
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	completed.emit(1 if failed else 0)

func _proxy_probe(host, source: String, registry: PluginToolRegistry, policy: PluginPolicy,
		capabilities: CapabilityBroker, definition: PluginDefinition, editor_name: String) -> void:
	# Use the real generated catalog and a real read tool on the mounted panel.
	var tool: Dictionary = {}
	for candidate: Dictionary in definition.tools:
		if candidate.get("name") == "minerva_sheets_get_data":
			tool = candidate
	var registration := registry.register_plugin_tools("sheets", definition.tools)
	check("proxy probe registers the real panel catalog", registration.get("ok") == true and not tool.is_empty())
	var saved_server = host.mcp_manager.minerva_server
	var server = load("res://Scripts/Services/MCP/MinervaMCPServer.gd").new()
	host.mcp_manager.minerva_server = server
	server.tool_budget_manager.activate_tool("minerva_sheets_get_data", tool)
	policy.grant_capability("sheets", "mcp.proxy:minerva_sheets_get_data")
	var connection = load("res://Scripts/Services/MCP/MCPServerConnection.gd").new("sheets-probe", "", MCPServerConnection.TransportType.STDIO)
	connection.plugin_id = "sheets"
	connection.configure_stdio(source.path_join("tests/proxy/sheets-proxy"))
	connection.capability_request_handler = func(id: String, capability: String, args: Dictionary) -> Dictionary:
		return await capabilities.dispatch(id, capability, args)
	var connected: int = await connection.connect_to_server()
	check("Go probe backend negotiates the real legacy transport", connected == OK)
	if connected == OK:
		# call_tool deliberately returns the decoded application result, not wire content.
		var body: Dictionary = await connection.call_tool("probe", {"editor_name": editor_name})
		print("Proxy capability reply: " + JSON.stringify(body))
		var value: Dictionary = body.get("result", {})
		check("Go backend mcp.proxy reaches its own source panel", body.get("success") == true and value.get("format") == "csv"
			and value.get("row_count") == 4 and value.get("column_count") == 3)
	connection.disconnect_from_server()
	host.mcp_manager.minerva_server = saved_server
	registry.register_plugin_tools("sheets", definition.tools)


func _project_reply(tool_name: String, result: Dictionary) -> void:
	if tool_name.begins_with("sheets."):
		print("R17 channel " + tool_name + ": " + JSON.stringify(result))
		_project_replies[tool_name] = result.duplicate(true)

func _json_value(value: Variant) -> Variant:
	return JSON.parse_string(JSON.stringify(value))

func _hosting_contract(host: Node, pane: EditorPane, manager: PluginManager) -> void:
	var fixtures := "res://test/fixtures/spreadsheet_contract/"
	for extension: String in ["minsheet", "csv", "tsv", "xlsx"]:
		var filename := "baseline.minsheet" if extension == "minsheet" else "sample." + extension
		var oracle := filename if extension == "minsheet" else extension + "-expected.json"
		var path := ProjectSettings.globalize_path(fixtures + filename)
		var before := FileAccess.get_file_as_bytes(path)
		var opened: Dictionary = host.open_file_at_path(path)
		await get_tree().process_frame
		var editor: Editor = pane.Tabs.get_current_tab_control()
		check(extension + " uses the installed plugin loader", opened.get("ok") == true
			and editor != null and editor.type == Editor.Type.PLUGIN_SCENE and editor.plugin_id == "sheets")
		var panel: Node = editor.plugin_scene_root
		check(extension + " complete plugin model matches the frozen B0 oracle",
			_json_value(panel.call("_on_panel_save_request")) == JSON.parse_string(FileAccess.get_file_as_string(fixtures + oracle)))
		check(extension + " import leaves original bytes intact", FileAccess.get_file_as_bytes(path) == before)
	var import_editor: Editor = pane.Tabs.get_current_tab_control()
	var import_panel: Node = import_editor.plugin_scene_root
	var fallback: Editor = pane.add_plugin_scene_editor("sheets", "sheets_panel",
		ProjectSettings.globalize_path(fixtures + "sample.csv"), "No snapshot", "")
	await get_tree().process_frame
	check("actionless no-snapshot backing file loads its complete model", _json_value(fallback.plugin_scene_root.call("_on_panel_save_request"))
		== JSON.parse_string(FileAccess.get_file_as_string(fixtures + "csv-expected.json")))
	fallback.free()
	var stable_snapshot: Dictionary = import_panel.call("_on_panel_save_request")
	for invalid: String in ["malformed.minsheet", "not-an-object.minsheet", "missing.minsheet"]:
		var invalid_path := ProjectSettings.globalize_path(fixtures + invalid)
		var invalid_bytes := FileAccess.get_file_as_bytes(invalid_path) if FileAccess.file_exists(invalid_path) else PackedByteArray()
		PluginScenePanelHost.invoke_document_handoff(import_panel, {"file_path": invalid_path}, "import")
		var notice: RichTextLabel = import_panel.get_node("Status")
		check(invalid + " visibly refuses without clearing model or changing input", notice.visible and notice.selection_enabled and not notice.text.is_empty()
			and _json_value(import_panel.call("_on_panel_save_request")) == _json_value(stable_snapshot)
			and (invalid_bytes == FileAccess.get_file_as_bytes(invalid_path) if FileAccess.file_exists(invalid_path) else invalid_bytes.is_empty()))
	var future_path := ProjectSettings.globalize_path(fixtures + "future.minsheet")
	var future_bytes := FileAccess.get_file_as_bytes(future_path)
	PluginScenePanelHost.invoke_document_handoff(import_panel, {"file_path": future_path}, "open")
	check("XFAIL future native version keeps the frozen accepted-and-downgraded behavior", _json_value(import_panel.call("_on_panel_save_request"))
		== JSON.parse_string(FileAccess.get_file_as_string(fixtures + "baseline.minsheet"))
		and FileAccess.get_file_as_bytes(future_path) == future_bytes)
	var imported_sheet = import_panel.get("sheet")
	imported_sheet.history.clear()
	check("public undo and redo refuse empty history", not PluginScenePanelHost.invoke_undo(import_panel)
		and not PluginScenePanelHost.invoke_redo(import_panel))
	imported_sheet.set_cell_value_with_history(0, 0, "hook edit")
	check("public undo reverts the model", PluginScenePanelHost.invoke_undo(import_panel)
		and imported_sheet.spreadsheet_data.get_cell_display(0, 0) == "Name")
	check("public redo reapplies the model", PluginScenePanelHost.invoke_redo(import_panel)
		and imported_sheet.spreadsheet_data.get_cell_display(0, 0) == "hook edit")
	var rendered: Array = PluginScenePanelHost.invoke_render_for_llm(import_panel, {})
	check("public LLM render returns current markdown", rendered == [{"type": "text", "text": imported_sheet.spreadsheet_data.to_markdown()}])
	# Full-host-only parity oracle: compare the unchanged builtin's reused model.
	var builtin_data = load("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetData.gd").new()
	var builtin_files: Script = load("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetFileHandler.gd")
	builtin_data.load_from_dict(JSON.parse_string(FileAccess.get_file_as_string(fixtures + "baseline.minsheet")))
	PluginScenePanelHost.invoke_load(import_panel, JSON.parse_string(FileAccess.get_file_as_string(fixtures + "baseline.minsheet")))
	for extension: String in ["csv", "tsv", "xlsx"]:
		var path := ProjectSettings.globalize_path(fixtures + "sample." + extension)
		var result: Error = builtin_files.import_file(path, builtin_data)
		PluginScenePanelHost.invoke_document_handoff(import_panel, {"file_path": path}, "import")
		check(extension + " reused-model import matches builtin", result == OK
			and _json_value(import_panel.call("_on_panel_save_request")) == _json_value(builtin_data.to_dict()))
	var source: Editor = pane.Tabs.get_current_tab_control()
	source.tab_title = "Reference source"
	var source_panel: Node = source.plugin_scene_root
	var source_data = source_panel.call("get_sheet_data")
	source_data.set_cell_value(0, 0, 7)
	var target: Editor = pane.add_plugin_scene_editor("sheets", "sheets_panel", null, "Formula sheet", "create")
	await get_tree().process_frame
	var target_panel: Node = target.plugin_scene_root
	var target_data = target_panel.call("get_sheet_data")
	target_data.set_cell_value(0, 0, "='Reference source'!A1+1")
	target_data.recalculate_all()
	check("cross-sheet reference resolves an open target", target_data.get_cell_value(0, 0) == 8)
	source.tab_title = "Reference renamed"
	target_data.recalculate_all()
	check("renaming removes the old reference name", target_data.get_cell_display(0, 0) == "#ERROR" and target_data.get_cell(0, 0).error == "#REF!")
	target_data.set_cell_value(0, 0, "='Reference renamed'!A1+1")
	target_data.recalculate_all()
	check("renamed target resolves through its current title", target_data.get_cell_value(0, 0) == 8)
	PluginScenePanelHost.invoke_load(source_panel, JSON.parse_string(FileAccess.get_file_as_string(fixtures + "baseline.minsheet")))
	var replacement_data = source_panel.call("get_sheet_data")
	replacement_data.set_cell_value(0, 0, 11)
	target_data.recalculate_all()
	check("registered title resolves a replaced model", replacement_data != source_data and target_data.get_cell_value(0, 0) == 12)
	var duplicate_editor: Editor = pane.add_plugin_scene_editor("sheets", "sheets_panel", null, "Duplicate", "create")
	await get_tree().process_frame
	duplicate_editor.tab_title = source.tab_title
	target_data.recalculate_all()
	check("ambiguous sheet titles show the existing reference error", target_data.get_cell_display(0, 0) == "#ERROR" and target_data.get_cell(0, 0).error == "#REF!")
	duplicate_editor.free()
	target_data.recalculate_all()
	check("closing the duplicate restores unambiguous lookup", target_data.get_cell_value(0, 0) == 12)
	PluginScenePanelHost.invoke_unload(source_panel)
	target_data.recalculate_all()
	check("unloading a live panel removes lookup", is_instance_valid(source_panel) and target_data.get_cell(0, 0).error == "#REF!")
	source.free()
	target_data.recalculate_all()
	check("closed target produces a reference error", target_data.get_cell_display(0, 0) == "#ERROR" and target_data.get_cell(0, 0).error == "#REF!")
	for child: Control in pane.Tabs.get_children():
		child.free()
	for extension: String in ["minsheet", "csv", "tsv", "xlsx"]:
		await _project_roundtrip(host, pane, manager, fixtures, extension)

func _project_roundtrip(host: Node, pane: EditorPane, manager: PluginManager, fixtures: String, extension: String) -> void:
	_project_replies.clear()
	if _project_container != null:
		_project_container.free()
	var container_script = load("res://Scripts/UI/Controls/vboxEditor.gd")
	_project_container = container_script.new()
	_project_container.set("editor_pane", pane)
	get_tree().root.add_child(_project_container)
	host.editor_container = _project_container
	var workspace := ProjectSettings.globalize_path("user://sheets-project-contract-" + extension)
	check("project workspace starts clean", not DirAccess.dir_exists_absolute(workspace))
	DirAccess.make_dir_recursive_absolute(workspace)
	var source_name := "sheet." + extension
	var fixture_name := "baseline.minsheet" if extension == "minsheet" else "sample." + extension
	var oracle_name := fixture_name if extension == "minsheet" else extension + "-expected.json"
	var source := workspace.path_join(source_name)
	check("stage independent project source " + extension, DirAccess.copy_absolute(fixtures + fixture_name, source) == OK)
	var expected: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(fixtures + oracle_name))
	var opened: Dictionary = host.open_file_at_path(source)
	check("project source opens as Sheets", opened.get("ok") == true and pane.Tabs.get_tab_count() == 1)
	await get_tree().process_frame
	var current: Editor = pane.Tabs.get_current_tab_control()
	var data = current.plugin_scene_root.call("get_sheet_data")
	if extension == "xlsx":
		data.set_cell_value(1, 2, 99)
		expected.cells["1,2"].value = 99
	else:
		data.set_cell_value(0, 0, "unsaved snapshot")
		expected.cells["0,0"].value = "unsaved snapshot"
	expected = _json_value(expected) # Normalize the edited numeric oracle across JSON.
	var entries: Array = await _project_container.call("serialize")
	check("real serialize channel succeeded", _project_replies.get("sheets.serialize") == {"tab_state": {}, "sidecar_paths": [], "success": true})
	check("real project serialization captures opaque complete panel state", entries.size() == 1
		and _json_value(entries[0].plugin_state.payload.__panel_state) == expected)
	var project := {"Editors": entries}
	var project_path := workspace.path_join("session.minproj")
	var file := FileAccess.open(project_path, FileAccess.WRITE)
	check("real minproj file opens for writing", file != null)
	if file == null:
		return
	file.store_string(JSON.stringify(project))
	file.close()
	for child: Control in pane.Tabs.get_children():
		child.free()
	var saved: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(project_path))
	var views: Array = await container_script.deserialize(saved.Editors)
	for view: Control in views:
		pane.Tabs.add_child(view)
	await get_tree().process_frame
	check("real deserialize channel succeeded", _project_replies.get("sheets.deserialize") == {"ok": true, "success": true})
	check("minproj reopens an identical complete plugin model", views.size() == 1
		and _json_value(views[0].plugin_scene_root.call("_on_panel_save_request")) == expected)
	for view: Control in views:
		view.free()
	var package = load("res://Scripts/Models/ProjectPackage.gd").new()
	var extras: Array = await package.collect_plugin_exports(project, manager, workspace)
	check("real export channel succeeded with no sidecars", extras.is_empty() and _project_replies.get("sheets.collect_export") == {"files": [], "success": true})
	var archive := OS.get_environment("SHEETS_PACKAGE_OUT")
	if archive.is_empty():
		archive = workspace.path_join("sheets.minpackage")
	archive = archive.get_basename() + "-" + extension + ".minpackage"
	DirAccess.make_dir_recursive_absolute(archive.get_base_dir())
	check("real minpackage stores the plugin project and native file", package.save_package(project,
		PackedStringArray([source]), PackedStringArray([source_name]), archive) == OK)
	var package_input := OS.get_environment("SHEETS_PACKAGE_IN")
	if package_input.is_empty():
		package_input = archive
	else:
		package_input = package_input.get_basename() + "-" + extension + ".minpackage"
	check("R17 package input exists", FileAccess.file_exists(package_input))
	var open_result: int = package.open_package(package_input)
	check("real package reader accepts the archive", open_result == OK)
	if open_result != OK:
		return
	var destination := workspace.path_join("unpacked")
	check("unpack destination starts empty", not DirAccess.dir_exists_absolute(destination))
	var unpacked_path := destination.path_join("project.minproj")
	check("real package unpacks into a fresh directory", package.unpack(destination, unpacked_path) == OK)
	package.close()
	var unpacked: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(unpacked_path))
	await package.apply_plugin_exports(unpacked, destination, manager)
	check("real apply export channel succeeded", _project_replies.get("sheets.apply_export") == {"ok": true, "success": true})
	check("unpacked bytes match frozen independent source", FileAccess.get_sha256(destination.path_join(source_name))
		== FileAccess.get_sha256(fixtures + fixture_name))
	var restored: Array = await container_script.deserialize(unpacked.Editors)
	for view: Control in restored:
		pane.Tabs.add_child(view)
	await get_tree().process_frame
	check("unpacked package restores the complete plugin model", restored.size() == 1
		and _json_value(restored[0].plugin_scene_root.call("_on_panel_save_request")) == expected)
	if not OS.get_environment("SHEETS_PACKAGE_IN").is_empty():
		print("R17 fresh-profile import used external package: " + package_input)
	for view: Control in restored:
		view.free()
