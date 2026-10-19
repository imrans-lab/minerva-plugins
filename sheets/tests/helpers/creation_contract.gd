extends RefCounted
## Frozen-schema calls through the actual installed Go backend and host services.

func _json(value: Variant) -> Variant:
	return JSON.parse_string(JSON.stringify(value))

func _editor(pane: EditorPane, title: String) -> Editor:
	for candidate: Editor in pane.get_open_editors():
		if candidate.tab_title == title:
			return candidate
	return null

func _create_into(registry: PluginToolRegistry, arguments: Dictionary, results: Array[Dictionary]) -> void:
	results.append(await registry.handle_tool_call("minerva_sheets_create_editor", arguments))

func run(check: Callable, pane: EditorPane, manager: PluginManager, registry: PluginToolRegistry,
		broker: PluginScenePanelBroker, policy: PluginPolicy, source: String) -> void:
	var host = pane.Tabs.get_tree().root.get_node("SingletonObject")
	var saved_server: Variant = host.mcp_manager.minerva_server
	var server = load("res://Scripts/Services/MCP/MinervaMCPServer.gd").new(host.mcp_manager)
	check.call("creation host server initializes its real native tool modules", server.get_tool_count() > 0)
	# Keep the real PolicyEngine with an explicit readable hermetic rule owner.
	server.policy_engine = load("res://test/helpers/hosted_policy_fixture.gd").new()
	var admission: Dictionary = await server.policy_engine.admit("minerva_create_plugin_editor", {}, "")
	check.call("creation has a readable policy owner and an admitted native tool", admission.get("allowed") == true)
	host.mcp_manager.minerva_server = server
	for tool: Dictionary in registry.get_plugin_tools("sheets"):
		server.tool_budget_manager.activate_tool(tool.name, tool)
	for tool: String in ["minerva_create_plugin_editor", "minerva_open_file", "minerva_sheets_update_data", "minerva_sheets_get_data"]:
		policy.grant_capability("sheets", "mcp.proxy:" + tool)
	policy.grant_capability("sheets", "host.documents.list_open")
	var dense_import: RefCounted = load(source.path_join("tests/helpers/dense_import_contract.gd")).new()
	await dense_import.call("run", check, pane, registry)
	var fixtures: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(source.path_join("tests/fixtures/tool-cases.json")))
	var paths: Dictionary = {"$csv_path": ProjectSettings.globalize_path("res://test/fixtures/spreadsheet_contract/sample.csv"),
		"$minsheet_path": ProjectSettings.globalize_path("res://test/fixtures/spreadsheet_contract/baseline.minsheet"),
		"$missing_path": ProjectSettings.globalize_path("user://missing-creation-input.csv")}
	check.call("creation missing-file precondition is an absent absolute path", str(paths["$missing_path"]).is_absolute_path()
		and not FileAccess.file_exists(paths["$missing_path"]))
	var original_csv: PackedByteArray = FileAccess.get_file_as_bytes(paths["$csv_path"])
	var original_native: PackedByteArray = FileAccess.get_file_as_bytes(paths["$minsheet_path"])
	var witnesses: Array[Editor] = []
	var witness_models: Array[Variant] = []
	for witness_index: int in range(2):
		var witness_editor: Editor = pane.add_plugin_scene_editor("sheets", "sheets_panel", null, "Creation witness %d" % witness_index, "create")
		await pane.Tabs.get_tree().process_frame
		witness_editor.plugin_scene_root.get("sheet").set_content("Witness,Value\n%d,%d" % [witness_index, witness_index + 100])
		witnesses.append(witness_editor)
		witness_models.append(_json(witness_editor.plugin_scene_root.call("_on_panel_save_request")))
	check.call("creation starts beside two independent live Sheets", witnesses[0].plugin_panel_key != witnesses[1].plugin_panel_key
		and witness_models[0] != witness_models[1])
	check.call("creation uses the real running ready provider", manager.get_plugin_status("sheets").get("ready", false))
	var concurrent: Array[Dictionary] = []
	var concurrent_count: int = pane.Tabs.get_tab_count()
	for name: String in ["Concurrent create one", "Concurrent create two"]:
		var concurrent_args: Dictionary = fixtures.creation[0][1].duplicate(true)
		concurrent_args["name"] = name
		_create_into(registry, concurrent_args, concurrent)
	var deadline: int = Time.get_ticks_msec() + 10000
	while concurrent.size() < 2 and Time.get_ticks_msec() < deadline:
		await pane.Tabs.get_tree().process_frame
	check.call("two concurrent real host creates each receive a distinct live Sheet", concurrent.size() == 2
		and concurrent[0].get("success") == true and concurrent[1].get("success") == true
		and concurrent[0].get("editor_name") != concurrent[1].get("editor_name")
		and pane.Tabs.get_tab_count() == concurrent_count + 2)
	for concurrent_result: Dictionary in concurrent:
		var concurrent_editor: Editor = _editor(pane, str(concurrent_result.get("editor_name", "")))
		if concurrent_editor != null:
			concurrent_editor.free()
	for index: int in range(5):
		var arguments: Dictionary = fixtures.creation[index][1].duplicate(true)
		if arguments.has("file_path"):
			arguments["file_path"] = paths[arguments.file_path]
		var count: int = pane.Tabs.get_tab_count()
		var result: Dictionary = await registry.handle_tool_call("minerva_sheets_create_editor", arguments)
		print("Creation case%d result: %s" % [index, JSON.stringify(result)])
		if index == 4:
			check.call("actual backend missing-file creation refuses without a tab", result.get("success") == false and pane.Tabs.get_tab_count() == count)
			continue
		var editor: Editor = _editor(pane, str(result.get("editor_name", "")))
		check.call("actual backend creates exactly one Sheets tab case%d" % index, result.get("success") == true
			and pane.Tabs.get_tab_count() == count + 1 and editor != null and editor.plugin_id == "sheets")
		if editor == null:
			continue
		var panel: Control = editor.plugin_scene_root
		var sheet = panel.get("sheet")
		if index == 0:
			check.call("name-only creation preserves the requested title and starts empty", editor.tab_title == arguments.name
				and sheet.spreadsheet_data.get_used_range().size == Vector2i.ZERO)
		elif index == 1:
			check.call("initial CSV is applied through the canonical panel tool", sheet.spreadsheet_data.get_cell_value(1, 1) == 17
				and result.get("rows_imported") == 2)
			var existing: Variant = _json(panel.call("_on_panel_save_request"))
			var reused: Dictionary = await registry.handle_tool_call("minerva_sheets_create_editor", fixtures.creation[7][1])
			check.call("existing named creation does not open a tab or replace its contents", reused.get("already_existed") == true
				and pane.Tabs.get_tab_count() == count + 1 and _json(panel.call("_on_panel_save_request")) == existing)
		else:
			var expected_path: String = "res://test/fixtures/spreadsheet_contract/" + ("csv-expected.json" if index == 2 else "baseline.minsheet")
			var expected: Variant = JSON.parse_string(FileAccess.get_file_as_string(expected_path))
			check.call("file-backed creation preserves the complete frozen model case%d" % index,
				_json(panel.call("_on_panel_save_request")) == expected and result.get("rows_imported", 0) > 0)
		editor.free()
	var fail_args: Dictionary = fixtures.creation[6][1].duplicate(true)
	var before_partial: int = pane.Tabs.get_tab_count()
	var revoke_update := func(_id: String, _key: String) -> void:
		policy.revoke_capability("sheets", "mcp.proxy:minerva_sheets_update_data")
	broker.panel_registered.connect(revoke_update, CONNECT_ONE_SHOT)
	var partial: Dictionary = await registry.handle_tool_call("minerva_sheets_create_editor", fail_args)
	print("Creation partial result: " + JSON.stringify(partial))
	if broker.panel_registered.is_connected(revoke_update):
		broker.panel_registered.disconnect(revoke_update)
	policy.grant_capability("sheets", "mcp.proxy:minerva_sheets_update_data")
	var surviving: Editor = _editor(pane, str(partial.get("editor_name", "")))
	check.call("second-step failure visibly names the surviving tab", partial.get("success") == false and partial.get("error_code") == "initial_content_failed"
		and surviving != null and pane.Tabs.get_tab_count() == before_partial + 1
		and str(partial.get("error_message", "")).contains(surviving.tab_title))
	if surviving != null:
		surviving.free()
	check.call("creation never overwrites either imported source", FileAccess.get_file_as_bytes(paths["$csv_path"]) == original_csv
		and FileAccess.get_file_as_bytes(paths["$minsheet_path"]) == original_native)
	check.call("creation leaves both existing complete sheet models unchanged",
		_json(witnesses[0].plugin_scene_root.call("_on_panel_save_request")) == witness_models[0]
		and _json(witnesses[1].plugin_scene_root.call("_on_panel_save_request")) == witness_models[1])
	for existing_editor: Editor in witnesses:
		existing_editor.free()
	var foreign: RefCounted = load(source.path_join("tests/helpers/foreign_creation_contract.gd")).new()
	await foreign.run(check, pane, manager, server)
	var large_import: RefCounted = load(source.path_join("tests/helpers/large_import_contract.gd")).new()
	await large_import.call("run", check, pane, registry)
	manager.stop_plugin("sheets")
	var stopped_count: int = pane.Tabs.get_tab_count()
	var stopped: Dictionary = await registry.handle_tool_call("minerva_sheets_create_editor", fixtures.creation[5][1])
	check.call("stopped provider refuses creation without opening a tab", stopped.get("success") == false and pane.Tabs.get_tab_count() == stopped_count)
	host.mcp_manager.minerva_server = saved_server
