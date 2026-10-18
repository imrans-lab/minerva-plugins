extends RefCounted
## Real HTTP settlement shares one native lifetime with an admitted host write.
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

func _wait(tree: SceneTree, predicate: Callable) -> bool:
	var until := Time.get_ticks_msec() + 6000
	while not predicate.call() and Time.get_ticks_msec() < until:
		await tree.process_frame
	return predicate.call()

func _model(editor: Editor) -> String:
	return JSON.stringify(editor.plugin_scene_root.call("_on_panel_save_request"))

func run(check: Callable, pane: EditorPane, registry: PluginToolRegistry, server: MinervaMCPServer,
		target: Editor, witness: Editor, witness_before: String) -> void:
	var tree: SceneTree = pane.Tabs.get_tree()
	var peer = ClassDB.instantiate("SubProcess")
	tree.root.add_child(peer)
	check.call("HTTP settlement peer starts", peer.start("python3", PackedStringArray(["-u",
		ProjectSettings.globalize_path("res://test/fixtures/http_mcp_probe/server.py")])))
	var address := {"base": ""}
	await _wait(tree, func() -> bool:
		while peer.has_output():
			var value: Variant = JSON.parse_string(peer.read_line())
			if value is Dictionary and value.has("port"):
				address.base = "http://127.0.0.1:%d" % int(value.port)
		return not address.base.is_empty())
	check.call("HTTP settlement peer publishes actual loopback endpoint", not address.base.is_empty())
	if address.base.is_empty():
		peer.free()
		return
	var client := MCPServerConnection.new("http-settlement", address.base)
	for mode: String in ["preflight", "raw", "nested", "timeout", "disconnect", "rpc_error", "success"]:
		check.call("HTTP matrix %s negotiates actual peer" % mode, await client.connect_to_server() == OK)
		var context := MCPExecutionContext.create("internal")
		var gate := AdmissionGate.new()
		server.policy_engine = gate
		var child: Array = []
		_into(registry.capability_broker.dispatch.bind("sheets", "mcp.proxy:minerva_sheets_update_data",
			{"editor_name": target.tab_title, "cells": [{"cell": "B2", "value": "STALE HTTP WRITE"}]}, context), child)
		check.call("HTTP matrix %s holds actual native write in shared lifetime" % mode,
			await _wait(tree, func() -> bool: return gate.held) and child.is_empty())
		var edit: Dictionary = await registry.handle_tool_call("minerva_sheets_update_data",
			{"editor_name": target.tab_title, "cells": [{"cell": "B2", "value": "HTTP intervening edit"}]})
		var before: String = _model(target)
		check.call("HTTP matrix %s records an independent user edit" % mode, edit.get("success") == true)
		var replies: Array = []
		if mode == "timeout":
			var negotiation = load("res://Scripts/Services/MCP/MCPStdioNegotiation.gd")
			var message: Dictionary = negotiation.modern_request("tools/call", "matrix-timeout", {"name": "sleep", "arguments": {"ms": 700}})
			# Exercise the real request's own deadline, independently of caller cancellation.
			_into(client._http_transport._send.bind(message, client.protocol_profile.protocol_version, {}, 0.05, context), replies)
		else:
			var tool: String = {"preflight": "echo", "raw": "unsafe", "nested": "unsafe-nested", "disconnect": "sleep", "rpc_error": "matrix-rpc-error", "success": "echo"}[mode]
			_into(client.call_tool_with_context.bind(tool,
				{"value": NAN} if mode == "preflight" else {"ms": 700}, context), replies)
			if mode == "disconnect":
				check.call("HTTP disconnect owns a submitted live stream", await _wait(tree, func() -> bool:
					for request in client._http_transport._active.values():
						if request.submitted:
							return true
					return false))
				client.disconnect_from_server()
		check.call("HTTP matrix %s settles actual transport" % mode, await _wait(tree, func() -> bool: return replies.size() == 1))
		var result: Dictionary = replies[0] if replies.size() == 1 else {}
		if mode in ["rpc_error", "success"]:
			check.call("HTTP matrix %s preserves peer outcome without retirement" % mode, not context.is_stopped()
				and (result.get("rpc_error", {}).get("code") == -32017 and result.rpc_error.data.kept == true if mode == "rpc_error" else not result.has("error")))
			context.cancel()
		else:
			check.call("HTTP matrix %s retires the shared lifetime with original failure" % mode, context.is_stopped()
				and context.stopped_result().get("error") == result.get("error") and result.has("error")
				and (str(result.error).contains("deadline") if mode == "timeout" else result.get("error_code") != "cancelled" or mode == "disconnect"))
		print("SETTLEMENT_MATRIX HTTP ", mode, " ", JSON.stringify(result))
		gate.released.emit()
		await _wait(tree, func() -> bool: return gate.resumed and child.size() == 1)
		await tree.process_frame
		check.call("HTTP matrix %s cannot publish delayed mutation" % mode,
			gate.resumed and _model(target) == before and _model(witness) == witness_before)
	client.disconnect_from_server()
	peer.stop()
	peer.free()
