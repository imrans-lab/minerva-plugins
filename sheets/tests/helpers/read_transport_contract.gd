extends RefCounted
## One response budget on real chat, HTTP, browser-control and backend IPC.
const Tools := preload("../../ui/MCPSpreadsheetTools.gd")
# Unmodified host serializer is the independent escaping/precision oracle.
const WireJSON := preload("res://Scripts/Services/MCP/MCPJsonSerialization.gd")

func _browser(tree: SceneTree, port: int, session: String, arguments: Dictionary) -> Dictionary:
	var request := HTTPRequest.new()
	tree.root.add_child(request)
	request.timeout = 10.0
	var headers := PackedStringArray(["Content-Type: application/json", "MCP-Protocol-Version: 2025-06-18", "MCP-Session-Id: " + session, "X-Minerva-Control: 1"])
	var payload := {"jsonrpc": "2.0", "id": 99, "method": "tools/call", "params": {"name": "minerva_sheets_get_data", "arguments": arguments}}
	var error: int = request.request("http://127.0.0.1:%d/mcp" % port, headers, HTTPClient.METHOD_POST, JSON.stringify(payload))
	if error != OK:
		request.queue_free()
		return {"request_error": error}
	var response: Array = await request.request_completed
	var decoded: Dictionary = JSON.parse_string(response[3].get_string_from_utf8())
	request.queue_free()
	return {"bytes": response[3].size(), "rpc_error": decoded.get("error", {}),
		"application": JSON.parse_string(decoded.get("result", {}).get("content", [{"text": "{}"}])[0].text)}

func run(check: Callable, pane: EditorPane, registry: PluginToolRegistry, chat_manager,
		http: MinervaMCPHttpServer, client: MCPServerConnection, source: String) -> void:
	var tree: SceneTree = pane.Tabs.get_tree()
	var editor: Editor = pane.add_plugin_scene_editor("sheets", "sheets_panel", null, "Read wire budget", "create")
	await tree.process_frame
	var data = editor.plugin_scene_root.call("get_sheet_data")
	var live_tools: Script = editor.plugin_scene_root.get("_tools").get_script()
	# Runtime load is required for the standalone runner's autoload context.
	var connection = load("res://Scripts/Services/MCP/MCPServerConnection.gd").new("sheets-read-wire", "", MCPServerConnection.TransportType.STDIO)
	connection.plugin_id = "sheets"
	connection.configure_stdio(source.path_join("tests/proxy/sheets-proxy"))
	connection.capability_request_handler = func(id: String, capability: String, args: Dictionary, context: MCPExecutionContext = null) -> Dictionary:
		return await registry.capability_broker.dispatch(id, capability, args, context)
	var connected: int = await connection.connect_to_server()
	check.call("read budget Go IPC probe connects", connected == OK)
	var measurements: Array[Dictionary] = []
	for format_: String in ["csv", "json", "markdown"]:
		var args := {"editor_name": editor.plugin_panel_key, "format": format_}
		var low: int = 0
		var high: int = 40000
		# Quotes, backslashes, controls and Unicode exercise both escaping passes.
		var unit: String = "\"\\\n\tΩ" + String.chr(1) + String.chr(11) + "\\v"
		while high - low > 1:
			var middle: int = int((low + high) * 0.5)
			data.set_cell_value(0, 0, unit.repeat(middle))
			if live_tools.read_data(data, args).get("success") == true:
				low = middle
			else:
				high = middle
		for over: bool in [false, true]:
			data.set_cell_value(0, 0, unit.repeat(high if over else low))
			var before: String = JSON.stringify(editor.plugin_scene_root.call("_on_panel_save_request"))
			var direct: Dictionary = live_tools.read_data(data, args)
			var chat: Dictionary = await chat_manager.execute_tool("minerva_sheets_get_data", args)
			var ordinary: Dictionary = await client.call_tool("minerva_sheets_get_data", args)
			var browser: Dictionary = await _browser(tree, http.get_port(), client._http_transport.session, args)
			var ipc: Dictionary = await connection.call_tool("probe", args) if connected == OK else {}
			var responses: Array = [direct, chat, ordinary, browser.get("application", {}), ipc.get("result", ipc)]
			check.call("every real path returns the same complete response %s over=%s" % [format_, over], responses.all(func(result: Dictionary) -> bool: return direct.keys().all(func(key: String) -> bool: return result.has(key) and JSON.parse_string(WireJSON.encode(result[key]).raw) == JSON.parse_string(WireJSON.encode(direct[key]).raw))))
			check.call("browser framing fits without transport refusal %s over=%s" % [format_, over], browser.get("rpc_error", {"missing": true}).is_empty() and browser.get("bytes", 65537) <= 65536)
			check.call("boundary result is full success or typed cell refusal %s over=%s" % [format_, over], (direct.get("error_code") == "cell_too_large" and not direct.has("data")) if over else (direct.get("success") == true and WireJSON.encode(direct).raw.to_utf8_buffer().size() >= Tools.READ_REPLY_BYTES - 128))
			check.call("wire reads never mutate the full model %s over=%s" % [format_, over], JSON.stringify(editor.plugin_scene_root.call("_on_panel_save_request")) == before)
			measurements.append({"format": format_, "over": over, "application_bytes": WireJSON.encode(direct).raw.to_utf8_buffer().size(), "chat_reply_bytes": WireJSON.encode(chat).raw.to_utf8_buffer().size(), "http_application_bytes": WireJSON.encode(ordinary).raw.to_utf8_buffer().size(), "browser_reply_bytes": browser.get("bytes"), "ipc_reply_bytes": WireJSON.encode(ipc).raw.to_utf8_buffer().size()})
	data.set_cell_value(0, 0, String.chr(1).repeat(10000))
	for format_: String in ["csv", "json", "markdown"]:
		var control: Dictionary = await _browser(tree, http.get_port(), client._http_transport.session, {"editor_name": editor.plugin_panel_key, "format": format_})
		check.call("10k U+0001 values get cell metadata before browser frame limit " + format_, control.get("rpc_error", {"missing": true}).is_empty() and control.get("bytes", 65537) <= 65536 and control.get("application", {}).get("error_code") == "cell_too_large" and control.get("application", {}).get("cell") == "A1" and control.get("application", {}).get("cell_bytes") == 10000)
	print("READ_WIRE_MEASUREMENTS " + JSON.stringify(measurements))
	connection.disconnect_from_server()
	editor.free()
