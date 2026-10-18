extends Node
signal completed(code: int)
var passed: int = 0
var failed: int = 0

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
		host.plugin_editor_registry, host.creatable_item_registry, host.plugin_tool_registry]
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
		check(extension + " stays on the builtin after source install", host.plugin_editor_registry.resolve_file(extension).get("builtin") == "spreadsheet")
	if definition != null:
		var started: Dictionary = await manager.start_plugin("sheets")
		check("actual Sheets backend initializes", started.get("ok", false) == true)
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
			var button: Button = panel.get_node("Toolbar/Format") if panel != null else null
			check("raw PNG icon loads outside the import database", button != null and button.icon != null)
			var protected_path := ProjectSettings.globalize_path("res://test/fixtures/spreadsheet_contract/baseline.minsheet")
			var protected_bytes := FileAccess.get_file_as_bytes(protected_path)
			var saved: bool = await editor.save_file_to_disc(protected_path)
			check("staging save refuses without overwriting an existing sheet", not saved
				and FileAccess.get_file_as_bytes(protected_path) == protected_bytes)
			await _proxy_probe(host, source, registry, policy, capabilities, definition, editor.tab_title)
		for extension: String in ["csv", "minsheet"]:
			var filename := "sample.csv" if extension == "csv" else "baseline.minsheet"
			var path := ProjectSettings.globalize_path("res://test/fixtures/spreadsheet_contract/" + filename)
			var before := FileAccess.get_file_as_bytes(path)
			var opened: Dictionary = host.open_file_at_path(path)
			var builtin: Editor = MCPToolUtils.find_editor_by_name(str(opened.get("editor_name", "")))
			check("existing " + extension + " opens as a populated builtin without mutation", opened.get("ok") == true
				and builtin != null and builtin.type == Editor.Type.SPREADSHEET
				and builtin.spreadsheet_editor.spreadsheet_data.get_used_range().size != Vector2i.ZERO
				and FileAccess.get_file_as_bytes(path) == before)
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
	manager.free()
	ui.restore()
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	completed.emit(1 if failed else 0)

func _proxy_probe(host, source: String, registry: PluginToolRegistry, policy: PluginPolicy,
		capabilities: CapabilityBroker, definition: PluginDefinition, editor_name: String) -> void:
	# Register an ephemeral probe tool on the real source panel, never the shipped catalog.
	var tool := {"name": "minerva_sheets_probe", "executor": "panel", "description": "Staging transport probe",
		"input_schema": {"type": "object", "properties": {"editor_name": {"type": "string"}}, "required": ["editor_name"]}}
	var registration := registry.register_plugin_tools("sheets", [tool])
	check("proxy probe registers a real panel tool", registration.get("ok") == true)
	var saved_server = host.mcp_manager.minerva_server
	var server = load("res://Scripts/Services/MCP/MinervaMCPServer.gd").new()
	host.mcp_manager.minerva_server = server
	server.tool_budget_manager.activate_tool("minerva_sheets_probe", tool)
	policy.grant_capability("sheets", "mcp.proxy:minerva_sheets_probe")
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
		check("Go backend mcp.proxy reaches its own source panel", body.get("success") == false and body.get("error_code") == "sheets_staging"
			and str(body.get("error_message", "")).begins_with("Spreadsheet editing"))
	connection.disconnect_from_server()
	host.mcp_manager.minerva_server = saved_server
	registry.register_plugin_tools("sheets", definition.tools)
