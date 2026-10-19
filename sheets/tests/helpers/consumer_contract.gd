extends RefCounted
## Real CSV producer, native panel broker, Sheets backend, and Nametag stdio pipeline.

func _editor(pane: EditorPane, title: String) -> Editor:
	for editor: Editor in pane.get_open_editors():
		if editor.tab_title == title:
			return editor
	return null

func run(check: Callable, pane: EditorPane, registry: PluginToolRegistry, source: String, host: Node) -> void:
	var tree: SceneTree = pane.Tabs.get_tree()
	var previous_server = host.mcp_manager.minerva_server
	var server = load("res://Scripts/Services/MCP/MinervaMCPServer.gd").new(host.mcp_manager)
	server.policy_engine = load("res://test/helpers/hosted_policy_fixture.gd").new()
	host.mcp_manager.minerva_server = server
	for tool: Dictionary in registry.get_plugin_tools("sheets"):
		server.tool_budget_manager.activate_tool(tool.name, tool)
	var manager: PluginManager = registry.plugin_manager
	var policy: PluginPolicy = registry.plugin_policy
	var consumers: String = source.get_base_dir()
	var mm: PluginDefinition = manager.get_db().install(consumers.path_join("multimeter/manifest.json"))
	check.call("consumer fixture loads the actual MultiMeter manifest", mm != null)
	if mm == null:
		host.mcp_manager.minerva_server = previous_server
		return
	for capability: String in mm.host_capabilities:
		policy.grant_capability(mm.id, capability)
	var web := PluginWebviewBroker.new(manager, policy, registry.capability_broker)
	web.register_plugin_panel(mm.id, "multimeter_panel")
	var web_two := PluginWebviewBroker.new(manager, policy, registry.capability_broker)
	web_two.register_plugin_panel(mm.id, "multimeter_panel")
	var path: String = consumers.path_join("multimeter/b5-recording.csv")
	var before: PackedByteArray = FileAccess.get_file_as_bytes(path)
	var receipt: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path + ".json"))
	check.call("real recording fixture contains a stopped three-measurement CSV", receipt.get("success") == true and receipt.get("rows") == 3 and not before.is_empty())
	var collision: Editor = pane.add_plugin_scene_editor("sheets", "sheets_panel", null, path.get_file(), "create")
	await tree.process_frame
	var unrelated_path: String = ProjectSettings.globalize_path("user://unrelated-recording.csv")
	var unrelated_bytes: PackedByteArray = "Unrelated\nKeep recording".to_utf8_buffer()
	var unrelated_file := FileAccess.open(unrelated_path, FileAccess.WRITE)
	unrelated_file.store_buffer(unrelated_bytes)
	unrelated_file.close()
	var unrelated_recording: Dictionary = await registry.handle_tool_call("minerva_sheets_create_editor", {"name": "Recording", "file_path": unrelated_path})
	_editor(pane, str(unrelated_recording.get("editor_name", ""))).tab_title = "Recording"
	unrelated_recording["editor_name"] = "Recording"
	var recording_before: Dictionary = await registry.handle_tool_call("minerva_sheets_get_data", {"editor_name": unrelated_recording.get("editor_name", ""), "format": "json"})
	var count: int = pane.Tabs.get_tab_count()
	var args := {"name": "Recording", "file_path": path}
	var first: Dictionary = await web.handle_ipc_message("multimeter_panel", "mcp.proxy:minerva_sheets_create_editor", args)
	var again: Dictionary = await web_two.handle_ipc_message("multimeter_panel", "mcp.proxy:minerva_sheets_create_editor", args)
	print("CONSUMER_CREATE ", JSON.stringify([first, again]))
	var opened: Dictionary = first.get("result", {})
	var editor: Editor = _editor(pane, str(opened.get("editor_name", "")))
	check.call("two real panel brokers open one file identity despite a title collision", first.get("success") == true and again.get("success") == true
		and again.get("result", {}).get("editor_name") == opened.get("editor_name") and pane.Tabs.get_tab_count() == count + 1 and editor != collision and editor != null)
	if editor != null:
		# Sheets counts the CSV header; record_stop.rows counts measurements only.
		check.call("recording imports every measurement and Unicode unit without changing bytes", opened.get("rows_imported") == int(receipt.rows) + 1
			and editor.plugin_scene_root.call("get_sheet_data").call("get_cell_value", 3, 2) == "Ω" and FileAccess.get_file_as_bytes(path) == before)
		var chart: Dictionary = await registry.handle_tool_call("minerva_sheets_add_chart", {"editor_name": editor.tab_title, "series": ["B2:B4"], "title": "Recording", "x_range": "A2:A4"})
		var png: Dictionary = await registry.handle_tool_call("minerva_sheets_get_chart_image", {"editor_name": editor.tab_title, "chart_index": 0, "width": 64, "height": 32})
		var image := Image.new()
		check.call("recording chart returns an actual decodable PNG", chart.get("success") == true and png.get("success") == true
			and image.load_png_from_buffer(Marshalls.base64_to_raw(str(png.get("image_data", "")))) == OK and image.get_size() == Vector2i(64, 32))
	var recording_after: Dictionary = await registry.handle_tool_call("minerva_sheets_get_data", {"editor_name": unrelated_recording.get("editor_name", ""), "format": "json"})
	check.call("file-backed Recording ignores an unrelated fixed title and preserves its cells", unrelated_recording.get("success") == true
		and recording_after == recording_before and opened.get("editor_name") != unrelated_recording.get("editor_name")
		and FileAccess.get_file_as_bytes(unrelated_path) == unrelated_bytes)
	var native_callers: RefCounted = load(source.path_join("tests/helpers/native_caller_contract.gd")).new()
	await native_callers.call("run", check, pane, registry, host, web, path)
	var denied: Dictionary = await web.handle_ipc_message("multimeter_panel", "mcp.proxy:minerva_sheets_delete_row", {})
	check.call("ungranted Sheets mutation is explicitly denied by the real panel broker", denied.get("success") == false and denied.get("error_code") == "capability_not_granted")
	var unrelated_roster: Dictionary = await registry.handle_tool_call("minerva_sheets_create_editor", {"name": "Roster", "csv_content": "Unrelated\nKeep roster"})
	var roster_before: Dictionary = await registry.handle_tool_call("minerva_sheets_get_data", {"editor_name": unrelated_roster.get("editor_name", ""), "format": "json"})
	var roster_bytes: String = JSON.stringify(_editor(pane, str(unrelated_roster.get("editor_name", ""))).plugin_scene_root.call("get_sheet_data").call("to_dict"))
	var reused: Dictionary = await registry.handle_tool_call("minerva_sheets_create_editor", {"name": "Roster", "csv_content": "Wrong\nDo not import"})
	var refused_roster: Dictionary = await registry.handle_tool_call("minerva_sheets_get_data", {"editor_name": reused.get("editor_name", ""), "format": "json"})
	check.call("actual already_existed collision leaves the unrelated roster unchanged", unrelated_roster.get("success") == true
		and reused.get("success") == true and reused.get("already_existed") == true and refused_roster == roster_before)
	# The skill's collision branch leaves that tab untouched and chooses a fresh name.
	var roster: Dictionary = await registry.handle_tool_call("minerva_sheets_create_editor", {"name": "Nametag roster", "csv_content": "Name,Subtitle,ID\nZoë,,EMP-007\n李,Guide,EMP-008"})
	var read: Dictionary = await registry.handle_tool_call("minerva_sheets_get_data", {"editor_name": roster.get("editor_name", ""), "format": "json", "range": "A1:C3"})
	print("CONSUMER_ROSTER ", JSON.stringify([roster, read]))
	var expected: Array = [["Name", "Subtitle", "ID"], ["Zoë", null, "EMP-007"], ["李", "Guide", "EMP-008"]]
	check.call("canonical roster pipeline preserves blanks Unicode and text identifiers", read.get("success") == true and read.get("data") == expected)
	var chat_roster: Dictionary = await registry.handle_tool_call("minerva_sheets_create_editor", {"name": "Nametag chat roster"})
	var chat_written: Dictionary = await registry.handle_tool_call("minerva_sheets_update_data", {"editor_name": chat_roster.get("editor_name", ""), "csv_content": "Name\nChat person"})
	var chat_read: Dictionary = await registry.handle_tool_call("minerva_sheets_get_data", {"editor_name": chat_roster.get("editor_name", ""), "format": "json"})
	check.call("fresh chat roster population targets the returned new editor identity", chat_roster.get("success") == true and not chat_roster.get("already_existed", false)
		and chat_written.get("success") == true and chat_read.get("data") == [["Name"], ["Chat person"]])
	var roster_after: Dictionary = await registry.handle_tool_call("minerva_sheets_get_data", {"editor_name": unrelated_roster.get("editor_name", ""), "format": "json"})
	check.call("fresh CSV and chat roster workflows preserve unrelated sheet bytes and cells", roster_after == roster_before
		and roster.get("editor_name") != unrelated_roster.get("editor_name") and chat_roster.get("editor_name") != unrelated_roster.get("editor_name")
		and JSON.stringify(_editor(pane, str(unrelated_roster.get("editor_name", ""))).plugin_scene_root.call("get_sheet_data").call("to_dict")) == roster_bytes)
	var enabled: Dictionary = await registry.handle_tool_call("minerva_sheets_autofilter_enable", {"editor_name": roster.get("editor_name", ""), "range": "A1:C3"})
	var filtered: Dictionary = await registry.handle_tool_call("minerva_sheets_autofilter_set", {"editor_name": roster.get("editor_name", ""), "column": 3, "values": ["EMP-008"]})
	var visible: Dictionary = await registry.handle_tool_call("minerva_sheets_autofilter_get", {"editor_name": roster.get("editor_name", "")})
	var unfiltered: Dictionary = await registry.handle_tool_call("minerva_sheets_get_data", {"editor_name": roster.get("editor_name", ""), "format": "json"})
	var cleared: Dictionary = await registry.handle_tool_call("minerva_sheets_autofilter_clear", {"editor_name": roster.get("editor_name", ""), "remove": true})
	check.call("shipped canonical AutoFilter workflow uses sheet-relative rows while data reads retain hidden rows", enabled.get("success") == true and filtered.get("success") == true
		and visible.get("success") == true and Array(visible.get("visible_rows", [])) == [3] and unfiltered.get("data") == expected and cleared.get("success") == true)
	var rows: Array[Dictionary] = []
	for values: Array in read.get("data", []).slice(1):
		rows.append({"Name": values[0], "Subtitle": values[1], "ID": values[2]})
	var nametag: PluginDefinition = manager.get_db().install(consumers.path_join("nametag-maker/manifest.json"))
	check.call("actual Nametag consumer manifest loads", nametag != null)
	if nametag != null:
		var available: Dictionary = host.mcp_manager.tool_registry.duplicate()
		for tool: Dictionary in registry.get_plugin_tools("sheets"):
			available[tool.name] = true
		var seeded: Array = PluginSkillSeeder.resolve_deps(nametag, available)
		print("CONSUMER_SKILL_DEPS ", JSON.stringify(seeded))
		check.call("Nametag skill has no unresolved dependencies with Sheets installed", seeded.size() == 1 and seeded[0].unsatisfied.is_empty())
		for tool: Dictionary in registry.get_plugin_tools("sheets"):
			available.erase(tool.name)
		var missing: Array = PluginSkillSeeder.resolve_deps(nametag, available)
		var record: Dictionary = PluginSkillSeeder.build_install_record(nametag.id, missing[0].skill, missing[0].unsatisfied)
		check.call("missing Sheets hides the Nametag skill with its exact named dependencies", PluginSkillRecord.has_unsatisfied_deps(record)
			and missing[0].unsatisfied.size() == 7 and missing[0].unsatisfied.all(func(name: String) -> bool: return name.begins_with("minerva_sheets_")))
		for capability: String in nametag.host_capabilities:
			policy.grant_capability(nametag.id, capability)
		var connection = load("res://Scripts/Services/MCP/MCPServerConnection.gd").new("b5-nametag", "", MCPServerConnection.TransportType.STDIO)
		connection.plugin_id = nametag.id
		connection.configure_stdio(consumers.path_join("nametag-maker/nametag-maker-plugin"))
		connection.capability_request_handler = func(id: String, capability: String, arguments: Dictionary, context: MCPExecutionContext = null) -> Dictionary:
			return await registry.capability_broker.dispatch(id, capability, arguments, context)
		check.call("real Nametag backend negotiates stdio", await connection.connect_to_server() == OK)
		for absent: bool in [false, true]:
			if absent:
				registry.unregister_plugin_tools("sheets")
			var out: String = ProjectSettings.globalize_path("user://b5-tags-%s.mtags" % absent)
			var built: Dictionary = await connection.call_tool("nametag_build_from_sheet", {"rows_json": JSON.stringify(rows), "mapping": {"title": "Name", "subtitle": "Subtitle", "lines": [{"label": "ID", "column": "ID"}]}, "out_path": out, "preview_first_only": true})
			print("CONSUMER_NAMETAG ", JSON.stringify(built))
			var document: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(out)) if FileAccess.file_exists(out) else {}
			var tags: Array = document.get("generate", {}).get("rows", [])
			check.call("real Nametag explicit-row build preserves exact tags sheets_absent=%s" % absent, built.get("success") == true and tags == [{"title": "Zoë", "subtitle": "", "lines": [{"label": "ID", "value": "EMP-007"}]}, {"title": "李", "subtitle": "Guide", "lines": [{"label": "ID", "value": "EMP-008"}]}])
		connection.disconnect_from_server()
		manager.get_db().remove(nametag.id)
	registry.register_plugin_tools("sheets", manager.get_db().get_by_id("sheets").tools)
	var recovered_count: int = pane.Tabs.get_tab_count()
	registry.unregister_plugin_tools("sheets")
	var absent_reply: Dictionary = await web.handle_ipc_message("multimeter_panel", "mcp.proxy:minerva_sheets_create_editor", args)
	check.call("absent provider returns a typed native refusal without opening or changing the file", absent_reply.get("success") == false and not str(absent_reply.get("error_code", "")).is_empty()
		and pane.Tabs.get_tab_count() == recovered_count and FileAccess.get_file_as_bytes(path) == before)
	registry.register_plugin_tools("sheets", manager.get_db().get_by_id("sheets").tools)
	for crashed: bool in [false, true]:
		if crashed:
			# Stop only this fixture's actual child without the manager's normal-stop path.
			manager.get_connection("sheets")._subprocess.stop()
			var deadline: int = Time.get_ticks_msec() + 3000
			while manager.get_plugin_status("sheets").get("running", false) and Time.get_ticks_msec() < deadline:
				await tree.process_frame
		else:
			manager.stop_plugin("sheets")
		var refusal: Dictionary = await web.handle_ipc_message("multimeter_panel", "mcp.proxy:minerva_sheets_create_editor", args)
		print("CONSUMER_PROVIDER_DOWN ", crashed, " ", JSON.stringify(refusal))
		check.call("stopped or crashed actual provider refuses without changing the recording crashed=%s" % crashed, not manager.get_plugin_status("sheets").get("running", true)
			and refusal.get("success") == false and not str(refusal.get("error_code", "")).is_empty()
			and pane.Tabs.get_tab_count() == recovered_count and FileAccess.get_file_as_bytes(path) == before)
		var restart: Dictionary = await manager.start_plugin("sheets")
		var retry: Dictionary = await web.handle_ipc_message("multimeter_panel", "mcp.proxy:minerva_sheets_create_editor", args)
		check.call("retry after actual provider start reuses exactly one tab crashed=%s" % crashed, restart.get("ok") == true and retry.get("success") == true
			and retry.get("result", {}).get("editor_name") == opened.get("editor_name") and pane.Tabs.get_tab_count() == recovered_count)
	var interrupted_path: String = ProjectSettings.globalize_path("user://b5-interrupted-recording.csv")
	check.call("interrupted verification fixture copies the real recording", DirAccess.copy_absolute(path, interrupted_path) == OK)
	var sheets_connection = manager.get_connection("sheets")
	var forward: Callable = sheets_connection.capability_request_handler
	var interruption := {"seen": false}
	sheets_connection.capability_request_handler = func(id: String, capability: String, arguments: Dictionary, context: MCPExecutionContext = null) -> Dictionary:
		var reply: Dictionary = await forward.call(id, capability, arguments, context)
		if capability == "mcp.proxy:minerva_sheets_get_data" and str(arguments.get("editor_name", "")).begins_with("b5-interrupted-recording"):
			interruption.seen = true
			# The real file is open and the real read finished, before its reply reaches Go.
			sheets_connection._subprocess.stop()
		return reply
	var interrupted_count: int = pane.Tabs.get_tab_count()
	var interrupted: Dictionary = await web.handle_ipc_message("multimeter_panel", "mcp.proxy:minerva_sheets_create_editor", {"name": "Recording", "file_path": interrupted_path})
	print("CONSUMER_INTERRUPTED_VERIFY ", JSON.stringify(interrupted))
	# Cancellation semantics are the separately tracked B6 gate; B5 proves identity only.
	check.call("provider interruption during real verification never opens a second tab", interruption.seen and pane.Tabs.get_tab_count() == interrupted_count + 1
		and FileAccess.get_file_as_bytes(interrupted_path) == before)
	var resumed: Dictionary = await manager.start_plugin("sheets")
	var resumed_open: Dictionary = await web.handle_ipc_message("multimeter_panel", "mcp.proxy:minerva_sheets_create_editor", {"name": "Recording", "file_path": interrupted_path})
	check.call("explicit retry after interrupted verification reuses its one file-backed tab", resumed.get("ok") == true and resumed_open.get("success") == true and pane.Tabs.get_tab_count() == interrupted_count + 1)
	check.call("all consumer calls leave the original recording intact", FileAccess.get_file_as_bytes(path) == before)
	for entry: Editor in pane.get_open_editors():
		if entry == collision or entry == editor or entry.file == interrupted_path or entry.tab_title in [roster.get("editor_name", ""), unrelated_roster.get("editor_name", ""), chat_roster.get("editor_name", ""), unrelated_recording.get("editor_name", "")]:
			entry.free()
	manager.get_db().remove(mm.id)
	host.mcp_manager.minerva_server = previous_server
