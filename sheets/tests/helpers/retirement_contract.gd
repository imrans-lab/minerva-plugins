extends RefCounted
## Real backend retirement while host policy admission has not yet allowed a write.
class AdmissionGate extends PolicyEngine:
	signal released
	var held := false
	var resumed := false
	func admit(tool_name: String, _args: Dictionary, _caller: String = "") -> Dictionary:
		if tool_name == "minerva_sheets_update_data" and not held:
			held = true
			await released
			resumed = true
		return {"allowed": true, "observations": [], "injections": []}

func _into(connection: MCPServerConnection, args: Dictionary, timeout: float, replies: Array) -> void:
	replies.append(await connection.call_tool("minerva_sheets_create_editor", args, timeout))

func run(check: Callable, pane: EditorPane, registry: PluginToolRegistry, host: Node) -> void:
	var tree: SceneTree = pane.Tabs.get_tree()
	var manager: MCPManager = host.get("mcp_manager")
	var previous_server = manager.minerva_server
	# Host service depends on autoloads and is loaded after the --script runner starts.
	var server = load("res://Scripts/Services/MCP/MinervaMCPServer.gd").new(manager)
	manager.minerva_server = server
	for tool: Dictionary in registry.get_plugin_tools("sheets"):
		server.tool_budget_manager.activate_tool(tool.name, tool)
	var connection: MCPServerConnection = registry.plugin_manager.get_connection("sheets")
	var forward: Callable = connection.capability_request_handler
	for phase: String in ["restart", "timeout"]:
		var gate := AdmissionGate.new()
		server.policy_engine = gate
		var provenance := {"context": null}
		connection.capability_request_handler = func(id: String, capability: String, args: Dictionary, context: MCPExecutionContext = null) -> Dictionary:
			if capability == "mcp.proxy:minerva_sheets_update_data":
				provenance.context = context
			return await forward.call(id, capability, args, context)
		var title: String = "Retirement " + phase
		var replies: Array = []
		var count: int = pane.Tabs.get_tab_count()
		_into(connection, {"name": title, "csv_content": "Name,Value\nImported,1"}, 2.0 if phase == "timeout" else 10.0, replies)
		var until := Time.get_ticks_msec() + 8000
		while not gate.held and Time.get_ticks_msec() < until:
			await tree.process_frame
		check.call("retirement %s suspends actual CSV write in policy admission" % phase, gate.held and provenance.context != null and replies.is_empty() and connection.pending_request_count() == 1 and pane.Tabs.get_tab_count() == count + 1)
		var editor: Editor = null
		for candidate: Editor in pane.get_open_editors():
			if candidate.tab_title == title:
				editor = candidate
		if not gate.held or editor == null:
			gate.released.emit()
			break
		var edited: Dictionary = await registry.handle_tool_call("minerva_sheets_update_data", {"editor_name": title, "cells": [{"cell": "B2", "value": "intervening user edit"}]})
		var before: String = JSON.stringify(editor.plugin_scene_root.call("_on_panel_save_request"))
		check.call("retirement %s has an intervening real user edit before settlement" % phase, edited.get("success") == true)
		if phase == "restart":
			var generation: int = connection.process_generation()
			registry.plugin_manager.stop_plugin("sheets")
			var restarted: Dictionary = await registry.plugin_manager.start_plugin("sheets")
			var retired: MCPServerConnection = connection
			connection = registry.plugin_manager.get_connection("sheets")
			check.call("retirement starts an actual replacement backend", restarted.get("ok") == true and connection != null and connection != retired and retired.process_generation() > generation)
			forward = connection.capability_request_handler
		until = Time.get_ticks_msec() + 5000
		while replies.is_empty() and Time.get_ticks_msec() < until:
			await tree.process_frame
		check.call("retirement %s stops the admitted child before releasing policy" % phase, replies.size() == 1 and replies[0].has("error") and provenance.context.is_stopped())
		gate.released.emit()
		until = Time.get_ticks_msec() + 5000
		while not gate.resumed and Time.get_ticks_msec() < until:
			await tree.process_frame
		var fence: Dictionary = await connection.call_tool("minerva_sheets_create_editor", {"name": title})
		check.call("retirement %s cannot resume a stale write or replay the import" % phase, gate.resumed and fence.get("already_existed") == true and pane.Tabs.get_tab_count() == count + 1 and connection.pending_request_count() == 0 and JSON.stringify(editor.plugin_scene_root.call("_on_panel_save_request")) == before)
		editor.free()
	connection.capability_request_handler = forward
	manager.minerva_server = previous_server
