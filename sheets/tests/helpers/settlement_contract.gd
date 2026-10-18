extends RefCounted
## One local-settlement matrix: real peer, broker, policy admission and sheet mutations.
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

func _into(operation: Callable, replies: Array) -> void:
	replies.append(await operation.call())

func _wait(tree: SceneTree, predicate: Callable, milliseconds: int = 6000) -> bool:
	var until := Time.get_ticks_msec() + milliseconds
	while not predicate.call() and Time.get_ticks_msec() < until:
		await tree.process_frame
	return predicate.call()

func _model(editor: Editor) -> String:
	return JSON.stringify(editor.plugin_scene_root.call("_on_panel_save_request"))

func _edit(registry: PluginToolRegistry, editor: Editor) -> Dictionary:
	return await registry.handle_tool_call("minerva_sheets_update_data", {"editor_name": editor.tab_title,
		"cells": [{"cell": "B2", "value": "intervening user edit"}]})

func run(check: Callable, pane: EditorPane, registry: PluginToolRegistry, host: Node) -> void:
	var tree: SceneTree = pane.Tabs.get_tree()
	var manager: MCPManager = host.get("mcp_manager")
	var previous_server = manager.minerva_server
	# These host services depend on autoloads and are loaded after the runner starts.
	var server = load("res://Scripts/Services/MCP/MinervaMCPServer.gd").new(manager)
	manager.minerva_server = server
	for tool: Dictionary in registry.get_plugin_tools("sheets"):
		server.tool_budget_manager.activate_tool(tool.name, tool)
	var target: Editor = pane.add_plugin_scene_editor("sheets", "sheets_panel", null, "Settlement target", "create")
	var witness: Editor = pane.add_plugin_scene_editor("sheets", "sheets_panel", null, "Settlement witness", "create")
	await tree.process_frame
	target.plugin_scene_root.get("sheet").set_content("Name,Value\nTarget,1")
	witness.plugin_scene_root.get("sheet").set_content("Name,Value\nWitness,2")
	var witness_before: String = _model(witness)
	var installed: Dictionary = await registry.plugin_manager.install_plugin(ProjectSettings.globalize_path("res://test/fixtures/parent_capability_probe/manifest.json"), true)
	check.call("settlement peer installs through the actual manager", installed.get("ok") == true)
	registry.plugin_policy.grant_capability("parent_fixture", "tool_call")
	var started: Dictionary = await registry.plugin_manager.start_plugin("parent_fixture")
	check.call("settlement peer starts and owns a real connection", started.get("ok") == true and registry.plugin_manager.get_connection("parent_fixture") != null)
	for mode: String in ["preflight", "raw", "nested", "private", "registry_schema", "external_schema", "rpc_error", "disconnect"]:
		var connection: MCPServerConnection = registry.plugin_manager.get_connection("parent_fixture")
		var gate := AdmissionGate.new()
		server.policy_engine = gate
		var context := MCPExecutionContext.create("internal")
		var observed := {"context": context}
		var original: Callable = connection.capability_request_handler
		connection.capability_request_handler = func(id: String, capability: String, args: Dictionary, parent_context: MCPExecutionContext = null) -> Dictionary:
			observed.context = parent_context
			return await original.call(id, capability, args, parent_context)
		var arguments := {"mode": "live", "capability": "mcp.proxy:minerva_sheets_update_data",
			"payload": {"editor_name": target.tab_title, "cells": [{"cell": "B2", "value": "STALE WRITE"}]}}
		var replies: Array = []
		var external: MCPManager = null
		if mode == "registry_schema":
			_into(registry.handle_tool_call.bind("minerva_parent_fixture_parent", arguments, context), replies)
		elif mode == "external_schema":
			external = load("res://Scripts/Services/MCP/MCPManager.gd").new()
			external.minerva_server = server
			external.servers["matrix_peer"] = connection
			var definition: MCPToolDefinition = null
			for tool: MCPToolDefinition in connection.tools:
				if tool.name == "parent":
					definition = MCPToolDefinition.from_dict(tool.to_mcp_format(), "matrix_peer")
			external.tool_registry["parent"] = definition
			external._tool_connection_owners["parent"] = connection
			_into(external.execute_tool.bind("parent", arguments, "", context), replies)
		elif mode == "private":
			_into(connection.request_method.bind("private/write", arguments), replies)
		else:
			_into(connection.call_tool_with_context.bind("parent", arguments, context), replies)
		var held: bool = await _wait(tree, func() -> bool: return gate.held)
		check.call("matrix %s holds an actual child in policy before peer settlement" % mode, held and replies.is_empty() and observed.context != null)
		if not held:
			context.cancel()
			gate.released.emit()
			break
		var changed: Dictionary = await _edit(registry, target)
		var before: String = _model(target)
		check.call("matrix %s preserves an independently made user edit" % mode, changed.get("success") == true)
		if mode == "preflight":
			var rejected: Dictionary = await connection.call_tool_with_context("hold", {"value": NAN}, context)
			check.call("matrix STDIO preflight preserves the outgoing rejection", rejected.has("error") and context.is_stopped())
		elif mode == "disconnect":
			registry.plugin_manager.stop_plugin("parent_fixture")
		else:
			var kind: String = "schema" if mode.ends_with("schema") else ("raw" if mode == "private" else mode)
			await connection.call_tool("release_parent", {"kind": kind})
		check.call("matrix %s receives its real parent result" % mode, await _wait(tree, func() -> bool: return replies.size() == 1))
		var result: Dictionary = replies[0] if replies.size() == 1 else {}
		var failed_context: MCPExecutionContext = observed.context
		if mode == "rpc_error":
			check.call("matrix valid peer RPC error retains code data and live lifetime", result.get("rpc_error", {}).get("code") == -32017
				and result.get("rpc_error", {}).get("data", {}).get("kept") == true and not failed_context.is_stopped())
			failed_context.cancel()
		else:
			check.call("matrix %s retires the admitted child before returning failure" % mode, failed_context.is_stopped() and result.get("success") != true)
			if mode == "disconnect":
				check.call("matrix explicit disconnect retains its original specific error", str(result.get("error", "")).contains("disconnected") and result.get("error_code") != "cancelled")
			elif mode.ends_with("schema"):
				check.call("matrix %s retains its original schema rejection" % mode, str(result.get("error", "")).contains("outputSchema") and result.get("error_code") == "schema_mismatch")
			else:
				check.call("matrix %s retains its original numeric rejection" % mode, (str(result.get("error", "")).to_lower().contains("num") or str(result.get("error", "")).contains("Nonfinite")))
		if mode != "rpc_error" and failed_context.is_stopped():
			var first_failure: String = JSON.stringify(failed_context.stopped_result())
			failed_context.lifetime.recovery["late"] = true
			failed_context.cancel()
			if failed_context.has_method("fail"):
				failed_context.fail({"error": "secondary failure", "error_code": "secondary"})
			check.call("matrix %s freezes first failure and recovery" % mode, JSON.stringify(failed_context.stopped_result()) == first_failure)
		print("SETTLEMENT_MATRIX ", mode, " ", JSON.stringify(result))
		gate.released.emit()
		await _wait(tree, func() -> bool: return gate.resumed)
		if mode != "disconnect":
			await connection.call_tool("counts", {})
		await tree.process_frame
		check.call("matrix %s cannot resume a stale mutation" % mode, gate.resumed and _model(target) == before and _model(witness) == witness_before)
		if external != null:
			external.servers.clear()
			external.free()
		if mode == "disconnect":
			await registry.plugin_manager.start_plugin("parent_fixture")
		else:
			connection.capability_request_handler = original
	registry.plugin_manager.stop_plugin("parent_fixture")
	registry.unregister_plugin_tools("parent_fixture")
	registry.plugin_manager.get_db().remove("parent_fixture")
	server.policy_engine = load("res://test/helpers/hosted_policy_fixture.gd").new()
	await _ipc_rows(check, pane, registry, server, target, witness, witness_before)
	var http: RefCounted = load(get_script().resource_path.get_base_dir().path_join("http_settlement_contract.gd")).new()
	await http.call("run", check, pane, registry, server, target, witness, witness_before)
	target.free()
	witness.free()
	manager.minerva_server = previous_server

func _ipc_rows(check: Callable, pane: EditorPane, registry: PluginToolRegistry, server: MinervaMCPServer,
		target: Editor, witness: Editor, witness_before: String) -> void:
	var tree: SceneTree = pane.Tabs.get_tree()
	var definition: PluginDefinition = registry.plugin_manager.get_db().get_by_id("sheets")
	var prior_channels: Array[String] = definition.ui_ipc_messages.duplicate()
	definition.ui_ipc_messages.append_array(["capability:mcp.proxy:minerva_sheets_update_data", "capability:host.not_declared"])
	registry.plugin_policy.grant_capability("sheets", "mcp.proxy:minerva_sheets_update_data")
	for mode: String in ["timeout", "close", "denied", "payload"]:
		var caller: Editor = pane.add_plugin_scene_editor("sheets", "sheets_panel", null, "IPC caller " + mode, "create")
		await tree.process_frame
		var ipc: MinervaIPC = caller.plugin_scene_root.get_node("_MinervaIPC")
		var gate := AdmissionGate.new()
		server.policy_engine = gate
		var context := MCPExecutionContext.create("internal")
		var replies: Array = []
		_into(context.run.bind(ipc.request_capability.bind("mcp.proxy:minerva_sheets_update_data",
			{"editor_name": target.tab_title, "cells": [{"cell": "B2", "value": "STALE IPC WRITE"}]}, context, 200 if mode == "timeout" else 5000)), replies)
		check.call("matrix IPC %s holds actual capability admission against another live panel" % mode,
			await _wait(tree, func() -> bool: return gate.held) and replies.is_empty() and caller.plugin_panel_key != target.plugin_panel_key)
		var changed: Dictionary = await _edit(registry, target)
		var before: String = _model(target)
		check.call("matrix IPC %s has an intervening user edit" % mode, changed.get("success") == true)
		if mode in ["denied", "payload"]:
			var failure: Dictionary = await ipc.request_capability("host.not_declared" if mode == "denied" else "mcp.proxy:minerva_sheets_update_data",
				{} if mode == "denied" else {"large": "x".repeat(PluginPayloadLimits.CONTROL_BYTES + 1)}, context)
			check.call("matrix IPC %s retires before publishing a specific refusal" % mode, context.is_stopped() and failure.get("success") == false
				and failure.get("error_code") == ("capability_not_granted" if mode == "denied" else "payload_too_large"))
		if mode == "close":
			registry.scene_panel_broker.unregister_panel("sheets", caller.plugin_panel_key)
		check.call("matrix IPC %s returns specific local failure with its lifetime stopped" % mode,
			await _wait(tree, func() -> bool: return replies.size() == 1) and context.is_stopped()
			and replies[0].get("error_code") == ({"timeout": "timeout", "close": "panel_unloading", "denied": "capability_not_granted", "payload": "payload_too_large"}[mode])
			and not str(replies[0].get("error_message", "")).is_empty())
		gate.released.emit()
		await _wait(tree, func() -> bool: return gate.resumed)
		await tree.process_frame
		check.call("matrix IPC %s cannot publish its delayed mutation" % mode, gate.resumed and _model(target) == before and _model(witness) == witness_before)
		caller.free()
	definition.ui_ipc_messages.assign(prior_channels)
