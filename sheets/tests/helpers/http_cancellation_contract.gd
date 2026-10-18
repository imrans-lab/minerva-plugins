extends RefCounted
## The public HTTP stream owns cancellation; nested Sheets calls share its lifetime.
class Gate extends RefCounted:
	signal released
	var context: MCPExecutionContext = null

func _into(operation: Callable, replies: Array) -> void:
	replies.append(await operation.call())

func run(check: Callable, pane: EditorPane, registry: PluginToolRegistry, client: MCPServerConnection) -> void:
	var tree: SceneTree = pane.Tabs.get_tree()
	var connection = registry.plugin_manager.get_connection("sheets")
	var forward: Callable = connection.capability_request_handler
	var gate := Gate.new()
	connection.capability_request_handler = func(id: String, capability: String, args: Dictionary, parent_context: MCPExecutionContext = null) -> Dictionary:
		var reply: Dictionary = await forward.call(id, capability, args, parent_context)
		if capability == "host.documents.list_open" and gate.context == null:
			gate.context = parent_context
			await gate.released
		return reply
	var count: int = pane.Tabs.get_tab_count()
	var context := MCPExecutionContext.create("external_agent")
	var replies: Array = []
	_into(client.call_tool_with_context.bind("minerva_sheets_create_editor", {"name": "HTTP cancelled import", "csv_content": "Name\nCancelled"}, context), replies)
	var until := Time.get_ticks_msec() + 8000
	while gate.context == null and Time.get_ticks_msec() < until:
		await tree.process_frame
	check.call("actual HTTP call reaches nested capability before any tab is created", gate.context != null and pane.Tabs.get_tab_count() == count and replies.is_empty())
	if gate.context == null:
		connection.capability_request_handler = forward
		return
	var survivor_context := MCPExecutionContext.create("internal")
	var survivor: Array = []
	_into(registry.handle_tool_call.bind("minerva_sheets_create_editor", {"name": "HTTP queued survivor", "csv_content": "Name\nSurvivor"}, survivor_context), survivor)
	until = Time.get_ticks_msec() + 8000
	while connection.pending_request_count() != 2 and Time.get_ticks_msec() < until:
		await tree.process_frame
	check.call("HTTP cancellation queues an independent actual backend caller", connection.pending_request_count() == 2 and survivor.is_empty())
	context.cancel()
	until = Time.get_ticks_msec() + 8000
	while not gate.context.is_stopped() and Time.get_ticks_msec() < until:
		await tree.process_frame
	check.call("closing owned HTTP stream cancels its nested capability lifetime", gate.context.is_stopped() and not survivor_context.is_stopped())
	gate.released.emit()
	until = Time.get_ticks_msec() + 8000
	while (replies.is_empty() or survivor.is_empty()) and Time.get_ticks_msec() < until:
		await tree.process_frame
	# Real serial backend fence, reusing the completed survivor by identity.
	var fence: Dictionary = await connection.call_tool("minerva_sheets_create_editor", {"name": "HTTP queued survivor"})
	check.call("cancelled HTTP import creates only its queued survivor", replies.size() == 1 and replies[0].get("error_code") == "cancelled"
		and survivor.size() == 1 and survivor[0].get("success") == true and pane.Tabs.get_tab_count() == count + 1
		and fence.get("already_existed") == true and connection.pending_request_count() == 0)
	connection.capability_request_handler = forward
	for editor: Editor in pane.get_open_editors():
		if editor.tab_title in ["HTTP cancelled import", "HTTP queued survivor"]:
			editor.free()
