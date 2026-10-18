extends RefCounted
## Actual caller cancellation, serialized backend survivor and visible-import recovery.
class Hold extends RefCounted:
	signal released
	var held := false
	var editor_name := ""

func _into(registry: PluginToolRegistry, args: Dictionary, context: MCPExecutionContext, replies: Array) -> void:
	replies.append(await registry.handle_tool_call("minerva_sheets_create_editor", args, context))

func _editor(pane: EditorPane, title: String) -> Editor:
	for editor: Editor in pane.get_open_editors():
		if editor.tab_title == title:
			return editor
	return null

func run(check: Callable, pane: EditorPane, registry: PluginToolRegistry, source: String, host: Node) -> void:
	var tree: SceneTree = pane.Tabs.get_tree()
	# Autoload-dependent services are loaded at runtime in the --script fixture.
	var manager: MCPManager = host.get("mcp_manager")
	var previous_server = manager.minerva_server
	var previous_editors: Array[Editor] = pane.get_open_editors().duplicate()
	var server = load("res://Scripts/Services/MCP/MinervaMCPServer.gd").new(manager)
	server.policy_engine = load("res://test/helpers/hosted_policy_fixture.gd").new()
	manager.minerva_server = server
	for tool: Dictionary in registry.get_plugin_tools("sheets"):
		server.tool_budget_manager.activate_tool(tool.name, tool)
	var connection = registry.plugin_manager.get_connection("sheets")
	var forward: Callable = connection.capability_request_handler
	var witness: Dictionary = await registry.handle_tool_call("minerva_sheets_create_editor", {"name": "B6 baseline witness", "csv_content": "Witness,Value\nKeep,101"})
	var witness_editor: Editor = _editor(pane, str(witness.get("editor_name", "")))
	var witness_before: String = JSON.stringify(witness_editor.plugin_scene_root.call("_on_panel_save_request"))
	for phase: String in ["before_open", "verification"]:
		var gate := Hold.new()
		var context := MCPExecutionContext.create("internal")
		var replies: Array = []
		var args := {"name": "B6 cancelled " + phase, "csv_content": "Name,Value\nCancelled,1"}
		if phase == "verification":
			var path: String = ProjectSettings.globalize_path("user://b6-late-verification.csv")
			check.call("late-cancel input copies a real frozen CSV", DirAccess.copy_absolute(ProjectSettings.globalize_path("res://test/fixtures/spreadsheet_contract/sample.csv"), path) == OK)
			args = {"name": "B6 late verification", "file_path": path}
		connection.capability_request_handler = func(id: String, capability: String, arguments: Dictionary, parent_context: MCPExecutionContext = null) -> Dictionary:
			var reply: Dictionary = await forward.call(id, capability, arguments, parent_context)
			var selected: bool = capability == ("host.documents.list_open" if phase == "before_open" else "mcp.proxy:minerva_sheets_get_data")
			if selected and not gate.held:
				gate.editor_name = str(arguments.get("editor_name", ""))
				gate.held = true
				await gate.released
			return reply
		var count: int = pane.Tabs.get_tab_count()
		_into(registry, args, context, replies)
		var deadline: int = Time.get_ticks_msec() + 8000
		while not gate.held and Time.get_ticks_msec() < deadline:
			await tree.process_frame
		check.call("real baseline call reaches signal-held " + phase, gate.held)
		if not gate.held:
			break
		var before_cancel: String = ""
		if phase == "verification":
			var edited: Dictionary = await registry.handle_tool_call("minerva_sheets_update_data", {"editor_name": gate.editor_name, "cells": [{"cell": "B2", "value": "user edit"}]})
			check.call("late-cancel sheet is visible and accepts a real user edit", edited.get("success") == true and _editor(pane, gate.editor_name) != null)
			before_cancel = JSON.stringify(_editor(pane, gate.editor_name).plugin_scene_root.call("_on_panel_save_request"))
		var survivor_context := MCPExecutionContext.create("internal")
		var survivor: Array = []
		_into(registry, {"name": "B6 queued survivor " + phase, "csv_content": "Name\nSurvivor"}, survivor_context, survivor)
		deadline = Time.get_ticks_msec() + 8000
		while connection.pending_request_count() < 2 and Time.get_ticks_msec() < deadline:
			await tree.process_frame
		check.call("second request is pending behind the real serialized backend at " + phase, connection.pending_request_count() == 2 and survivor.is_empty())
		context.cancel()
		gate.released.emit()
		deadline = Time.get_ticks_msec() + 8000
		while (replies.is_empty() or survivor.is_empty()) and Time.get_ticks_msec() < deadline:
			await tree.process_frame
		# This real subsequent request acknowledges that the serialized backend has drained both calls.
		var fence: Dictionary = await connection.call_tool("minerva_sheets_create_editor", {"name": "B6 baseline witness"})
		check.call("queued noncancelled request completes and backend drains " + phase, survivor.size() == 1 and survivor[0].get("success") == true
			and fence.get("already_existed") == true and connection.pending_request_count() == 0)
		var unchanged: bool = JSON.stringify(witness_editor.plugin_scene_root.call("_on_panel_save_request")) == witness_before
		var late_kept: bool = phase != "verification" or JSON.stringify(_editor(pane, gate.editor_name).plugin_scene_root.call("_on_panel_save_request")) == before_cancel
		var result: Dictionary = replies[0] if replies.size() == 1 else {}
		print("B6_S0_CANCEL ", JSON.stringify({"phase": phase, "tab_delta": pane.Tabs.get_tab_count()-count, "cancelled": result,
			"survivor": survivor, "witness_unchanged": unchanged, "visible_user_edit_kept": late_kept, "pending": connection.pending_request_count()}))
		check.call("baseline cancellation is typed and unrelated data survives " + phase, result.get("error_code") == "cancelled" and unchanged and late_kept)
		if phase == "before_open":
			check.call("cancel before open creates only the queued survivor", pane.Tabs.get_tab_count() == count + 1 and _editor(pane, str(args.name)) == null)
		else:
			check.call("late cancelled import exposes its kept editor through native recovery", result.get("recovery", {}).get("editor_name") == gate.editor_name and pane.Tabs.get_tab_count() == count + 2)

	connection.capability_request_handler = forward
	var cad: PluginDefinition = registry.plugin_manager.get_db().install(source.get_base_dir().path_join("cad/manifest.json"))
	check.call("legacy actual CAD manifest loads", cad != null)
	if cad != null:
		registry.register_plugin_tools(cad.id, cad.tools)
		var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(source.get_base_dir().path_join("cad/manifest.json")))
		var legacy: Editor = pane.add_plugin_scene_editor(cad.id, str(manifest.ui.panels[0].name), null, "Legacy CAD handler", "create")
		await tree.process_frame
		check.call("actual CAD panel retains only its legacy two-argument handler", legacy != null and legacy.plugin_scene_root.has_method("handle_tool")
			and not legacy.plugin_scene_root.has_method("handle_tool_with_context"))
		if legacy != null:
			var viewed: Dictionary = await registry.handle_tool_call("minerva_cad_view_state", {"editor_name": legacy.tab_title})
			check.call("actual legacy CAD panel tool still dispatches through the unchanged fallback", viewed.get("success") == true)
		if legacy != null:
			legacy.free()
		registry.unregister_plugin_tools(cad.id)
		registry.plugin_manager.get_db().remove(cad.id)
	for editor: Editor in pane.get_open_editors():
		if editor not in previous_editors:
			editor.free()
	manager.minerva_server = previous_server
