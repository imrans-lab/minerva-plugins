extends RefCounted
## Real renderer and dispatch: two requests, second-sheet identity, caller close.

func _json(value: Variant) -> Variant:
	return JSON.parse_string(JSON.stringify(value))

func _capture_into(registry: PluginToolRegistry, tool: String, arguments: Dictionary,
		replies: Array[Dictionary], context: MCPExecutionContext = null) -> void:
	replies.append(await registry.handle_tool_call(tool, arguments, context))

func run(check: Callable, pane: EditorPane, registry: PluginToolRegistry,
		broker: PluginScenePanelBroker, first: Editor, source: String, recipe: Array, first_png: String) -> void:
	var tree: SceneTree = pane.Tabs.get_tree()
	var original: Dictionary = _json(first.plugin_scene_root.call("_on_panel_save_request"))
	var second: Editor = pane.add_plugin_scene_editor("sheets", "sheets_panel", null, "PNG target two", "create")
	await tree.process_frame
	var panel: Control = second.plugin_scene_root
	var state: Dictionary = original.duplicate(true)
	state.charts[0]["title"] = "PNG target two"
	PluginScenePanelHost.invoke_load(panel, state)
	var sheet = panel.get("sheet")
	pane.Tabs.current_tab = pane.Tabs.get_tab_idx_from_control(first)
	check.call("chart fixture selects the first of two distinct live sheets", pane.Tabs.get_current_tab_control() == first
		and first.plugin_panel_key != second.plugin_panel_key and _json(state) != original)
	var names: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(source.path_join("scripts/legacy-tools.json")))
	var tool: String = names[recipe[0]]
	var arguments: Dictionary = recipe[1].duplicate(true)
	arguments["editor_name"] = second.tab_title
	arguments["chart_index"] = 0
	var replies: Array[Dictionary] = []
	for width: int in [64, 96]:
		var concurrent: Dictionary = arguments.duplicate(true)
		concurrent["width"] = width
		_capture_into(registry, tool, concurrent, replies)
	var deadline: int = Time.get_ticks_msec() + 5000
	while replies.size() < 2 and Time.get_ticks_msec() < deadline:
		await tree.process_frame
	var sizes: Array[int] = []
	var png: String = ""
	for result: Dictionary in replies:
		var image := Image.new()
		if result.get("success") == true and image.load_png_from_buffer(Marshalls.base64_to_raw(result.get("image_data", ""))) == OK and image.get_height() == 32:
			sizes.append(image.get_width())
			if image.get_width() == 64:
				png = result.image_data
	sizes.sort()
	check.call("two overlapping canonical chart requests return their own PNG sizes", sizes == [64, 96])
	var raw: String = await sheet.chart_canvases[0].capture_to_base64_png(64, 32)
	check.call("canonical image targets the second chart and matches its raw PNG", png == raw and png != first_png)
	check.call("overlapping captures leave the first complete model untouched", _json(first.plugin_scene_root.call("_on_panel_save_request")) == original)
	var stopped_context := MCPExecutionContext.create("module")
	var survivor_context := MCPExecutionContext.create("module")
	var stopped_replies: Array[Dictionary] = []
	var survivor_replies: Array[Dictionary] = []
	var simultaneous := {"seen": false, "armed": false}
	var cancel_one := func() -> void:
		simultaneous.seen = stopped_replies.is_empty() and survivor_replies.is_empty()
		stopped_context.cancel()
	var start_cancel := func(child: Node) -> void:
		if child is SubViewport and not simultaneous.armed:
			simultaneous.armed = true
			RenderingServer.frame_pre_draw.connect(cancel_one, CONNECT_ONE_SHOT)
	var target_canvas: Node = sheet.chart_canvases[0]
	target_canvas.child_entered_tree.connect(start_cancel)
	_capture_into(registry, tool, arguments, stopped_replies, stopped_context)
	_capture_into(registry, tool, arguments, survivor_replies, survivor_context)
	deadline = Time.get_ticks_msec() + 5000
	while (stopped_replies.is_empty() or survivor_replies.is_empty()) and Time.get_ticks_msec() < deadline:
		await tree.process_frame
	target_canvas.child_entered_tree.disconnect(start_cancel)
	if RenderingServer.frame_pre_draw.is_connected(cancel_one):
		RenderingServer.frame_pre_draw.disconnect(cancel_one)
	print("Concurrent capture measurements: ", JSON.stringify({"precondition": simultaneous, "stopped": stopped_replies, "survivor_success": survivor_replies[0].get("success") if survivor_replies.size() == 1 else false, "survivor_stopped": survivor_context.is_stopped()}))
	check.call("concurrent actual panel captures keep independent caller lifetimes", simultaneous.seen and stopped_replies.size() == 1
		and stopped_replies[0].get("error_code") == "cancelled" and survivor_replies.size() == 1 and survivor_replies[0].get("success") == true
		and not survivor_context.is_stopped() and _json(first.plugin_scene_root.call("_on_panel_save_request")) == original)
	var context := MCPExecutionContext.create("module")
	var started: Array[bool] = [false]
	var stop := func() -> void:
		context.cancel()
		second.queue_free()
	var arm := func(child: Node) -> void:
		if child is SubViewport:
			started[0] = true
			RenderingServer.frame_pre_draw.connect(stop, CONNECT_ONE_SHOT)
	var canvas: Node = sheet.chart_canvases[0]
	canvas.child_entered_tree.connect(arm)
	var ipc_pending: Dictionary = panel.get_node("_MinervaIPC").get("_pending")
	var backend = registry.plugin_manager.get_connection("sheets")
	var pending: Dictionary = backend.get("_pending")
	check.call("closing capture starts without backend or IPC work", ipc_pending.is_empty() and pending.is_empty())
	var cancelled: Dictionary = await registry.handle_tool_call(tool, arguments, context)
	await tree.process_frame
	await tree.process_frame
	if RenderingServer.frame_pre_draw.is_connected(stop):
		RenderingServer.frame_pre_draw.disconnect(stop)
	if is_instance_valid(canvas) and canvas.child_entered_tree.is_connected(arm):
		canvas.child_entered_tree.disconnect(arm)
	check.call("close during the real draw wait cancels without pending work or sheet mutation", started[0]
		and context.is_stopped() and cancelled.get("success") != true and cancelled.get("error_code") == "cancelled"
		and broker.get_panel_for_editor("PNG target two") == null and ipc_pending.is_empty() and pending.is_empty()
		and _json(first.plugin_scene_root.call("_on_panel_save_request")) == original)
	if is_instance_valid(second):
		second.free()
