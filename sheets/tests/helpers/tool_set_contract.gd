extends RefCounted
## One manifest owner across validation, backend publication, MCP and search.
func run(check: Callable, registry: PluginToolRegistry, manager: MCPManager,
		server: MinervaMCPServer, manifest: Dictionary) -> void:
	for invalid: Variant in [null, 42, true, [], {}]:
		var malformed: Dictionary = JSON.parse_string(JSON.stringify(manifest))
		malformed.tools[0]["tool_set"] = invalid
		var invalid_definition := PluginDefinition.from_dict(malformed)
		check.call("non-string tool_set is visibly refused by manifest validation: " + str(invalid),
			invalid_definition == null or invalid_definition.validate().any(func(error: String) -> bool: return error.begins_with("tool_set_invalid:")))
		var rejected := registry.register_plugin_tools("sheets", malformed.tools)
		check.call("registry rejects malformed membership atomically: " + str(invalid), rejected.has("error")
			and registry.get_plugin_tools("sheets").size() == 30)
	var lifecycle_added: bool = not registry.plugin_manager.plugin_stopped.is_connected(registry.on_plugin_stopped)
	if lifecycle_added:
		registry.plugin_manager.plugin_stopped.connect(registry.on_plugin_stopped)
	var companion: Array = [{"name": "minerva_setprobe_shared", "description": "Shared category companion",
		"input_schema": {"type": "object", "properties": {}}, "tool_set": "spreadsheet"},
		{"name": "minerva_setprobe_undeclared", "description": "Uncategorized companion",
		"input_schema": {"type": "object", "properties": {}}}]
	check.call("another plugin may declare the existing spreadsheet category", registry.register_plugin_tools("setprobe", companion).get("ok") == true
		and manager.tool_registry["minerva_setprobe_shared"].tool_set == "spreadsheet"
		and manager.tool_registry["minerva_setprobe_undeclared"].tool_set == "")
	var category: Array[Dictionary] = server.tool_search_index.search("*", "spreadsheet", 1000)
	var category_names: Array = category.map(func(entry: Dictionary) -> String: return entry.name)
	check.call("category search includes Sheets and same-category companion, excludes undeclared companion", manifest.tools.all(func(tool: Dictionary) -> bool: return tool.name in category_names)
		and "minerva_setprobe_shared" in category_names and "minerva_setprobe_undeclared" not in category_names)
	var installed_definition: PluginDefinition = registry.plugin_manager.get_db().get_by_id("sheets")
	var connection: MCPServerConnection = registry.plugin_manager.get_connection("sheets")
	var backend_tool: MCPToolDefinition = connection.tools[0]
	var peer_membership: String = backend_tool.tool_set
	backend_tool.tool_set = "untrusted_peer_category"
	var refreshed := registry.publish_backend_tools("sheets", connection)
	check.call("backend wire metadata cannot replace current manifest membership", refreshed.get("ok") == true
		and registry.get_plugin_tools("sheets").all(func(entry: Dictionary) -> bool: return entry.get("tool_set") == "spreadsheet"))
	var declared_backend: Dictionary = {}
	for declared: Dictionary in installed_definition.tools:
		if declared.name == backend_tool.name:
			declared_backend = declared
	declared_backend["tool_set"] = "changed_manifest_category"
	registry.publish_backend_tools("sheets", connection)
	check.call("republishing uses current manifest membership rather than an old cache", manager.tool_registry[backend_tool.name].tool_set == "changed_manifest_category")
	declared_backend["tool_set"] = "spreadsheet"
	registry.publish_backend_tools("sheets", connection)
	backend_tool.tool_set = peer_membership
	registry.plugin_manager.stop_plugin("sheets")
	check.call("inactive panel tools keep their declared set", registry.get_plugin_tools("sheets").size() == 29
		and registry.get_plugin_tools("sheets").all(func(entry: Dictionary) -> bool: return entry.get("tool_set") == "spreadsheet"))
	var restarted: Dictionary = await registry.plugin_manager.start_plugin("sheets")
	check.call("actual backend restart/discovery restores all declared membership", restarted.get("ok") == true
		and registry.get_plugin_tools("sheets").size() == installed_definition.tools.size()
		and registry.get_plugin_tools("sheets").all(func(entry: Dictionary) -> bool: return entry.get("tool_set") == "spreadsheet")
		and manifest.tools.all(func(tool: Dictionary) -> bool: return manager.tool_registry[tool.name].tool_set == "spreadsheet"))
	if lifecycle_added:
		registry.plugin_manager.plugin_stopped.disconnect(registry.on_plugin_stopped)

func http_anti(check: Callable, client: MCPServerConnection) -> void:
	var denied: Dictionary = await client.call_tool("minerva_setprobe_undeclared", {})
	check.call("undeclared plugin tool retains the existing HTTP filter refusal", denied.get("rpc_error", {}).get("code") == -32602
		and str(denied.get("error", "")).contains("Tool set '' is not enabled"))
