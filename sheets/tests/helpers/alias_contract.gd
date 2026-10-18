extends RefCounted
## Actual host routing through internal, loopback HTTP and chat entry points.

func _json(value: Variant) -> Variant:
	return JSON.parse_string(JSON.stringify(value))

func run(check: Callable, pane: EditorPane, registry: PluginToolRegistry, source: String) -> void:
	var tree: SceneTree = pane.Tabs.get_tree()
	var map: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(source.path_join("scripts/legacy-tools.json")))
	var frozen: Array = JSON.parse_string(FileAccess.get_file_as_string(source.path_join("scripts/frozen-tools.json")))
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(source.path_join("manifest.json")))
	var aliases: Dictionary[String, String] = MinervaMCPServer.SHEETS_LEGACY_ALIASES
	var legacy_names: Array = []
	var canonical_names: Array = []
	for tool: Dictionary in frozen:
		legacy_names.append(tool.name)
	for tool: Dictionary in manifest.tools:
		canonical_names.append(tool.name)
	legacy_names.sort()
	canonical_names.sort()
	var alias_names: Array = aliases.keys()
	var alias_targets: Array = aliases.values()
	alias_names.sort()
	alias_targets.sort()
	check.call("inactive alias table equals the single map and both complete catalogs", aliases == map
		and alias_names == legacy_names and alias_targets == canonical_names)
	var first: Editor = pane.add_plugin_scene_editor("sheets", "sheets_panel", null, "First alias witness", "create")
	var second: Editor = pane.add_plugin_scene_editor("sheets", "sheets_panel", null, "Second alias witness", "create")
	await tree.process_frame
	first.plugin_scene_root.get("sheet").set_content("First,Value\nWitness,111")
	second.plugin_scene_root.get("sheet").set_content("Second,Value\nWitness,222")
	var first_before: Variant = _json(first.plugin_scene_root.call("_on_panel_save_request"))
	var second_before: Variant = _json(second.plugin_scene_root.call("_on_panel_save_request"))
	check.call("alias routing has two different independent live sheets", first.plugin_panel_key != second.plugin_panel_key and first_before != second_before)
	var generated: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(source.path_join("tests/fixtures/tool-cases.json")))
	var arguments: Dictionary = {}
	var legacy: String = "minerva_get_spreadsheet_data"
	var canonical: String = aliases[legacy]
	for entry: Array in generated.parity:
		if entry[0] == legacy:
			arguments = entry[1].duplicate(true)
	arguments["editor_name"] = second.tab_title
	check.call("alias read arguments come from the frozen schema fixture", arguments.get("format") == "json")
	# These host classes are loaded after the autoloads by the --script fixture.
	var chat_manager = load("res://Scripts/Services/MCP/MCPManager.gd").new()
	var server = load("res://Scripts/Services/MCP/MinervaMCPServer.gd").new(chat_manager, aliases)
	var policy = load("res://test/helpers/hosted_policy_fixture.gd").new()
	server.policy_engine = policy
	server._enabled_tool_sets = []
	server.server_enabled = true
	chat_manager.minerva_server = server
	for tool: Dictionary in registry.get_plugin_tools("sheets"):
		var definition: MCPToolDefinition = MCPToolDefinition.from_dict(tool.get("mcp_definition", tool), "minerva")
		chat_manager.tool_registry[definition.name] = definition
		server.tool_budget_manager.activate_tool(definition.name, tool)
	var expected: Array = [["Second", "Value"], ["Witness", 222]]
	var internal: Dictionary = await server.call_tool(legacy, arguments)
	check.call("internal legacy read selects the second sheet and labels its canonical target", internal.get("success") == true
		and internal.get("alias_of") == canonical and _json(internal.get("data")) == _json(expected))
	var http := MinervaMCPHttpServer.new()
	tree.root.add_child(http)
	http._mcp_manager = chat_manager
	check.call("real Sheets alias HTTP server starts on an isolated loopback port", http.start_server(0) == OK)
	var client := MCPServerConnection.new("sheets-alias-loopback", "http://127.0.0.1:%d" % http.get_port())
	var connected: Error = await client.connect_to_server()
	var discovered: Array = []
	if connected == OK:
		discovered = await client.list_tools()
	check.call("real Sheets alias HTTP client discovers the canonical tool", connected == OK and discovered.any(func(tool: MCPToolDefinition) -> bool: return tool.name == canonical))
	if connected == OK:
		var wire: MCPToolCallOutcome = await client.call_tool_outcome(legacy, arguments)
		check.call("HTTP legacy read selects the second sheet and preserves alias_of on the wire", wire.application.get("success") == true
			and _json(wire.application.get("data")) == _json(expected)
			and wire.envelope != null and wire.envelope.to_mcp_format().get("alias_of") == canonical)
	client.disconnect_from_server()
	http.stop_server()
	http.free()
	var chat: Dictionary = await chat_manager.execute_tool(legacy, arguments, "sheets-alias-fixture")
	check.call("real chat legacy read selects the second sheet and retains alias_of", chat.get("success") == true
		and chat.get("alias_of") == canonical and _json(chat.get("data")) == _json(expected))
	var cancelled := MCPExecutionContext.create("internal")
	cancelled.cancel()
	var stopped: Dictionary = await chat_manager.execute_tool(legacy, arguments, "", cancelled)
	check.call("cancelled chat alias retains its canonical label", stopped.get("error_code") == "cancelled" and stopped.get("alias_of") == canonical)
	var rules: Array[Dictionary] = [{"id": "sheets-alias-denial", "title": "Canonical Sheets denial", "status": "active",
		"description": "---policy-rule---\n" + JSON.stringify({"tool_pattern": canonical, "effect": "block", "priority": 10}) + "\n---end-rule---"}]
	policy.set_policy_items(rules)
	var denied: Dictionary = await chat_manager.execute_tool(legacy, arguments)
	check.call("chat aliases evaluate policy on the canonical name", policy.rule_count() == 1 and denied.get("allowed") == false and denied.get("alias_of") == canonical)
	var empty_rules: Array[Dictionary] = []
	policy.set_policy_items(empty_rules)
	var unknown: Dictionary = await chat_manager.execute_tool("minerva_sheets_unknown_alias_fixture", {})
	check.call("unknown chat tool refuses without inventing alias metadata", unknown.get("success") == false and not unknown.has("alias_of"))
	var builtin: Editor = Editor.create(Editor.Type.SPREADSHEET, null, "Builtin alias witness", null, false)
	pane.adopt_editor(builtin)
	builtin.spreadsheet_editor.set_content("Builtin,Value\nWitness,333")
	var default_server = load("res://Scripts/Services/MCP/MinervaMCPServer.gd").new(chat_manager)
	default_server.policy_engine = policy
	var default_args: Dictionary = arguments.duplicate(true)
	default_args["editor_name"] = builtin.tab_title
	var production: Dictionary = await default_server.call_tool(legacy, default_args)
	check.call("production default table stays empty and dispatches the builtin", MinervaMCPServer.LEGACY_TOOL_ALIASES.is_empty()
		and default_server.canonical_tool_name(legacy) == legacy and not production.has("alias_of")
		and production.get("success") == true and _json(production.get("data")) == _json([["Builtin", "Value"], ["Witness", 333]]))
	check.call("all alias surfaces preserve both independent complete sheet models", _json(first.plugin_scene_root.call("_on_panel_save_request")) == first_before
		and _json(second.plugin_scene_root.call("_on_panel_save_request")) == second_before)
	builtin.free()
	first.free()
	second.free()
	chat_manager.free()
