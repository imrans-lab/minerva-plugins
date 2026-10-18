extends RefCounted
## Canonical host routing through internal, loopback HTTP and chat entry points.

class CanonicalSkill extends SkillDefinition:
	var tool_deps: Array[String] = []


func _json(value: Variant) -> Variant:
	return JSON.parse_string(JSON.stringify(value))

func run(check: Callable, pane: EditorPane, registry: PluginToolRegistry, source: String) -> void:
	var tree: SceneTree = pane.Tabs.get_tree()
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(source.path_join("manifest.json")))
	check.call("complete canonical catalog exposes30 Sheets tools without host aliases", manifest.tools.size() == 30
		and manifest.tools.all(func(tool: Dictionary) -> bool: return str(tool.name).begins_with("minerva_sheets_"))
		and MinervaMCPServer.LEGACY_TOOL_ALIASES.is_empty())
	var first: Editor = pane.add_plugin_scene_editor("sheets", "sheets_panel", null, "First routing witness", "create")
	var second: Editor = pane.add_plugin_scene_editor("sheets", "sheets_panel", null, "Second routing witness", "create")
	await tree.process_frame
	first.plugin_scene_root.get("sheet").set_content("First,Value\nWitness,111")
	second.plugin_scene_root.get("sheet").set_content("Second,Value\nWitness,222")
	var first_before: Variant = _json(first.plugin_scene_root.call("_on_panel_save_request"))
	var second_before: Variant = _json(second.plugin_scene_root.call("_on_panel_save_request"))
	check.call("canonical routing has two different independent live sheets", first.plugin_panel_key != second.plugin_panel_key and first_before != second_before)
	var generated: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(source.path_join("tests/fixtures/tool-cases.json")))
	var arguments: Dictionary = {}
	var canonical: String = "minerva_sheets_get_data"
	for entry: Array in generated.parity:
		if entry[0] == "minerva_get_spreadsheet_data":
			arguments = entry[1].duplicate(true)
	arguments["editor_name"] = second.tab_title
	check.call("canonical read arguments come from the frozen schema fixture", arguments.get("format") == "json")
	# These host classes are loaded after the autoloads by the --script fixture.
	var chat_manager = load("res://Scripts/Services/MCP/MCPManager.gd").new()
	var server = load("res://Scripts/Services/MCP/MinervaMCPServer.gd").new(chat_manager)
	var policy = load("res://test/helpers/hosted_policy_fixture.gd").new()
	server.policy_engine = policy
	server._enabled_tool_sets = []
	server.server_enabled = true
	chat_manager.minerva_server = server
	var host = tree.root.get_node("SingletonObject")
	var previous_manager: MCPManager = host.mcp_manager
	host.mcp_manager = chat_manager
	# Exercise the existing production wiring, including universal membership.
	var prior_registered: Array[Dictionary] = []
	prior_registered.assign(registry.tools_registered.get_connections())
	var prior_unregistered: Array[Dictionary] = []
	prior_unregistered.assign(registry.tools_unregistered.get_connections())
	host._wire_plugin_tools_to_mcp()
	registry.register_plugin_tools("sheets", registry.plugin_manager.get_db().get_by_id("sheets").tools)
	var profile = load("res://Scripts/Services/Agents/AgentDefinition.gd").deserialize(_json({"id": "sheet_profile", "tool_sets": ["spreadsheet"]}))
	server._enabled_tool_sets = profile.tool_sets
	var found_all := true
	for tool: Dictionary in manifest.tools:
		var found: Dictionary = server._tool_search({"query": str(tool.name), "limit": 1})
		found_all = found_all and tool.name in found.get("activated", [])
	check.call("saved spreadsheet tool-set filter discovers every universal Sheets tool", profile.tool_sets == ["spreadsheet"] and found_all)
	var preset_history = load("res://Scripts/Models/ChatHistory.gd").new(null)
	preset_history.StaticToolMode = true
	preset_history.ActiveSkills.assign(["data_analysis"])
	var schemas: Array[Dictionary] = chat_manager.get_tools_for_chat(preset_history)
	var exposed: Array[String] = []
	for schema: Dictionary in schemas:
		exposed.append(str(schema.name))
	check.call("Data Analysis preset retains its saved spreadsheet filter", "spreadsheet" in host.get_skill_manager().get_effective_tool_sets(preset_history.ActiveSkills))
	check.call("Data Analysis get_tools includes every installed canonical Sheets tool", manifest.tools.all(func(tool: Dictionary) -> bool: return tool.name in exposed))
	server._enabled_tool_sets = []
	var workflow: Dictionary = {}
	for line: String in FileAccess.get_file_as_string("res://Data/master.dct").split("\n", false):
		var record: Variant = JSON.parse_string(line)
		if record is Dictionary and record.get("title") == "Spreadsheet Workflows":
			workflow = record
	check.call("actual master Spreadsheet Workflows has its complete canonical dependency list", workflow.get("tool_deps", []).size() == 20 and workflow.tool_deps.all(func(name: String) -> bool: return name.begins_with("minerva_sheets_")))
	var skill_module = null
	for module in server._modules:
		if module.get_script() == load("res://Scripts/Services/MCP/Modules/MCPSkillTools.gd"):
			skill_module = module
	var activation: Dictionary = skill_module._activate_dependencies(workflow.get("tool_deps", []))
	var expected_dependencies: Array[String] = []
	for dependency: String in workflow.get("tool_deps", []):
		expected_dependencies.append(dependency)
	check.call("actual master Spreadsheet Workflows activates every installed canonical dependency", activation.get("activated_tools") == expected_dependencies
		and activation.get("skipped_tools", ["missing"]).is_empty() and activation.get("unavailable_tools", ["missing"]).is_empty())
	var local_skills = host.get_skill_manager()
	var local := CanonicalSkill.new("sheets_canonical_focus_fixture", str(workflow.title))
	local.origin = "user"
	local.persistent = false
	local.instructions = str(workflow.steps)
	local.tool_deps.assign(workflow.tool_deps)
	local_skills.skills.append(local)
	var history = load("res://Scripts/Models/ChatHistory.gd").new(null)
	history.HistoryName = "Sheets focused canonical fixture"
	host.ChatList.append(history)
	var focused: Dictionary = await server.call_tool("minerva_create_focused_chat", {"name": history.HistoryName, "skills": [local.id]})
	check.call("focused chat creation enables every canonical dependency of the shipped canonical skill", focused.get("success") == true
		and focused.get("skills_resolved") == 1 and history.ConfiguredTools == expected_dependencies
		and expected_dependencies.all(func(name: String) -> bool: return name not in history.DisabledTools))
	history.ConfiguredTools.assign(workflow.tool_deps)
	var original_configuration: Array[String] = history.ConfiguredTools.duplicate()
	var serialized: Dictionary = _json(history.Serialize())
	host.ChatList.erase(history)
	var restored: ServiceHistory = ServiceHistory.Deserialize(serialized)
	host.ChatList.append(restored)
	var chat_pane = load("res://Scripts/UI/Views/ChatPane.gd").new()
	chat_pane._on_mcp_server_connected("minerva")
	check.call("restored focused chat reconnect enables canonical tools and preserves canonical configuration", restored.ConfiguredTools == original_configuration
		and expected_dependencies.all(func(name: String) -> bool: return name not in restored.DisabledTools)
		and local.tool_deps == workflow.tool_deps)
	chat_pane.free()
	host.ChatList.erase(restored)
	if restored.provider != null:
		restored.provider.free()
	local_skills.skills.erase(local)
	var expected: Array = [["Second", "Value"], ["Witness", 222]]
	var internal: Dictionary = await server.call_tool(canonical, arguments)
	check.call("internal canonical read selects the second sheet and labels its canonical name", internal.get("success") == true
		and not internal.has("alias_of") and _json(internal.get("data")) == _json(expected))
	var http := MinervaMCPHttpServer.new()
	tree.root.add_child(http)
	http._mcp_manager = chat_manager
	check.call("real Sheets canonical HTTP server starts on an isolated loopback port", http.start_server(0) == OK)
	var client := MCPServerConnection.new("sheets-routing-loopback", "http://127.0.0.1:%d" % http.get_port())
	var connected: Error = await client.connect_to_server()
	var discovered: Array = []
	if connected == OK:
		discovered = await client.list_tools()
	check.call("real Sheets canonical HTTP client discovers the canonical tool", connected == OK and discovered.any(func(tool: MCPToolDefinition) -> bool: return tool.name == canonical))
	if connected == OK:
		var wire: MCPToolCallOutcome = await client.call_tool_outcome(canonical, arguments)
		check.call("HTTP canonical read selects the second sheet and has no alias metadata on the wire", wire.application.get("success") == true
			and _json(wire.application.get("data")) == _json(expected)
			and wire.envelope != null and not wire.envelope.to_mcp_format().has("alias_of"))
	client.disconnect_from_server()
	http.stop_server()
	http.free()
	var chat: Dictionary = await chat_manager.execute_tool(canonical, arguments, "sheets-routing-fixture")
	check.call("real chat canonical read selects the second sheet and has no alias metadata", chat.get("success") == true
		and not chat.has("alias_of") and _json(chat.get("data")) == _json(expected))
	var cancelled := MCPExecutionContext.create("internal")
	cancelled.cancel()
	var stopped: Dictionary = await chat_manager.execute_tool(canonical, arguments, "", cancelled)
	check.call("cancelled canonical chat call has no alias metadata", stopped.get("error_code") == "cancelled" and not stopped.has("alias_of"))
	var rules: Array[Dictionary] = [{"id": "sheets-routing-denial", "title": "Canonical Sheets denial", "status": "active",
		"description": "---policy-rule---\n" + JSON.stringify({"tool_pattern": canonical, "effect": "block", "priority": 10}) + "\n---end-rule---"}]
	policy.set_policy_items(rules)
	var denied: Dictionary = await chat_manager.execute_tool(canonical, arguments)
	check.call("canonical chat calls evaluate policy on the tool name", policy.rule_count() == 1 and denied.get("allowed") == false and not denied.has("alias_of"))
	var empty_rules: Array[Dictionary] = []
	policy.set_policy_items(empty_rules)
	var unknown: Dictionary = await chat_manager.execute_tool("minerva_sheets_unknown_routing_fixture", {})
	check.call("unknown chat tool refuses without inventing alias metadata", unknown.get("success") == false and not unknown.has("alias_of"))
	var retired: Dictionary = await chat_manager.execute_tool("minerva_get_spreadsheet_data", arguments)
	check.call("retired spreadsheet tool names refuse instead of aliasing", retired.get("success") == false and not retired.has("alias_of"))
	check.call("all canonical surfaces preserve both independent complete sheet models", _json(first.plugin_scene_root.call("_on_panel_save_request")) == first_before
		and _json(second.plugin_scene_root.call("_on_panel_save_request")) == second_before)
	var add_chart: Dictionary = {}
	var image_args: Dictionary = {}
	for entry: Array in generated.parity:
		if entry[0] == "minerva_add_spreadsheet_chart":
			add_chart = entry[1].duplicate(true)
		if entry[0] == "minerva_get_chart_image":
			image_args = entry[1].duplicate(true)
	add_chart["editor_name"] = second.tab_title
	image_args["editor_name"] = second.tab_title
	image_args["chart_index"] = 0
	pane.Tabs.current_tab = pane.Tabs.get_tab_idx_from_control(first)
	var added: Dictionary = await registry.handle_tool_call("minerva_sheets_add_chart", add_chart)
	check.call("canonical image fixture creates a chart on the second sheet", added.get("success") == true and pane.Tabs.get_current_tab_control() == first)
	var canonical_image: Dictionary = await registry.handle_tool_call("minerva_sheets_get_chart_image", image_args)
	var routed_image: Dictionary = await server.call_tool("minerva_sheets_get_chart_image", image_args)
	var raw_image: String = await second.plugin_scene_root.get("sheet").chart_canvases[0].capture_to_base64_png(64, 32)
	var decoded := Image.new()
	check.call("canonical and routed PNG match the second raw chart", canonical_image.get("success") == true
		and routed_image.get("success") == true and not routed_image.has("alias_of")
		and canonical_image.get("image_data") == raw_image and routed_image.get("image_data") == raw_image
		and decoded.load_png_from_buffer(Marshalls.base64_to_raw(raw_image)) == OK and decoded.get_size() == Vector2i(64, 32)
		and _json(first.plugin_scene_root.call("_on_panel_save_request")) == first_before)
	first.free()
	second.free()
	for connection: Dictionary in registry.tools_registered.get_connections():
		if connection not in prior_registered:
			registry.tools_registered.disconnect(connection.callable)
	for connection: Dictionary in registry.tools_unregistered.get_connections():
		if connection not in prior_unregistered:
			registry.tools_unregistered.disconnect(connection.callable)
	host.mcp_manager = previous_manager
	chat_manager.free()
