extends RefCounted
## Real CEF documents call the native bridge while actual verification replies wait.

class VerificationGate extends RefCounted:
	signal released
	var hits: int = 0
	var enabled: bool = true
	var locator: String = ""

func _wait(tree: SceneTree, predicate: Callable, seconds: float = 20.0) -> bool:
	var deadline: int = Time.get_ticks_msec() + int(seconds * 1000.0)
	while not predicate.call() and Time.get_ticks_msec() < deadline:
		await tree.process_frame
	return predicate.call()

func _view(tree: SceneTree, html: String, replies: Array[bool]) -> Control:
	# This host class depends on autoloads and is loaded after the standalone runner starts.
	var view: Control = load("res://Scripts/UI/Controls/WebViewEditor/CefWebViewEditor.gd").new()
	view.set("plugin_id", "multimeter")
	view.set("plugin_panel_name", "multimeter_panel")
	view.size = Vector2(500, 250)
	view.connect("bridge_probe_completed", func(ok: bool) -> void: replies.append(ok))
	tree.root.add_child(view)
	view.call("set_html", html)
	return view

func run(check: Callable, pane: EditorPane, registry: PluginToolRegistry, host: Node,
		web: PluginWebviewBroker, recording_path: String) -> void:
	var tree: SceneTree = pane.Tabs.get_tree()
	check.call("native caller fixture has the actual CEF extension", ClassDB.class_exists("CefTexture"))
	if not ClassDB.class_exists("CefTexture"):
		return
	var previous_broker: Variant = host.get("plugin_webview_broker")
	host.set("plugin_webview_broker", web)
	var original_bytes: PackedByteArray = FileAccess.get_file_as_bytes(recording_path)
	for mode: String in ["concurrent", "close", "reload"]:
		var path: String = ProjectSettings.globalize_path("user://native-caller-%s.csv" % mode)
		check.call("native %s uses a copy of the actual recording" % mode, DirAccess.copy_absolute(recording_path, path) == OK)
		var connection = registry.plugin_manager.get_connection("sheets")
		var forward: Callable = connection.capability_request_handler
		var gate := VerificationGate.new()
		connection.capability_request_handler = func(id: String, capability: String, arguments: Dictionary) -> Dictionary:
			var reply: Dictionary = await forward.call(id, capability, arguments)
			if gate.enabled and capability == "mcp.proxy:minerva_sheets_get_data" and str(arguments.get("editor_name", "")).begins_with("native-caller-" + mode):
				gate.hits += 1
				gate.locator = str(arguments.get("editor_name", ""))
				await gate.released
			return reply
		var open_arguments := {"name": "Recording", "file_path": path}
		var script: String = "window.minerva.call('minerva_sheets_create_editor', %s).then(function(){report(true)},function(){report(false)});" % JSON.stringify(open_arguments)
		var html: String = "<!doctype html><script>function report(ok){window.minerva.pluginIPC('bridge.probe.ack',{success:ok}).catch(function(){});} " + script + "</script>"
		var first_replies: Array[bool] = []
		var second_replies: Array[bool] = []
		var count: int = pane.Tabs.get_tab_count()
		var first: Control = _view(tree, html, first_replies)
		var second: Control = _view(tree, html, second_replies)
		var pending: bool = await _wait(tree, func() -> bool: return gate.hits == 1 and first.get("_pending_ipc").size() == 1 and second.get("_pending_ipc").size() == 1 and connection._pending.size() == 2, 8.0)
		check.call("native %s holds real verification while both native caller RPCs are pending" % mode, pending
			and first.get("_pending_ipc").size() == 1 and second.get("_pending_ipc").size() == 1
			and first.get("_document").capability != second.get("_document").capability)
		if not pending:
			gate.enabled = false
			gate.released.emit()
			connection.capability_request_handler = forward
			first.queue_free()
			second.queue_free()
			host.set("plugin_webview_broker", previous_broker)
			return
		var held_editor: Editor = null
		for candidate: Editor in pane.get_open_editors():
			if candidate.tab_title == gate.locator or candidate.plugin_panel_key == gate.locator:
				held_editor = candidate
		var changed: Dictionary = await registry.handle_tool_call("minerva_sheets_update_data", {"editor_name": gate.locator, "cells": [{"cell": "B2", "value": "native-edit-" + mode}]})
		print("NATIVE_HELD_EDIT ", gate.locator, " ", JSON.stringify(changed))
		check.call("native %s edits the actual open model before queued replay" % mode, changed.get("success") == true)
		var first_generation: int = first.get("_document_generation")
		if mode == "close":
			first.queue_free()
			await tree.process_frame
		elif mode == "reload":
			first.call("set_html", "<!doctype html><script>window.minerva.pluginIPC('bridge.probe.ack',{success:true}).catch(function(){});</script>")
			check.call("real reload revokes old pending contexts and advances generation", first.get("_document_generation") > first_generation and first.get("_pending_ipc").is_empty())
		gate.enabled = false
		gate.released.emit()
		var surviving: bool = await _wait(tree, func() -> bool: return not second_replies.is_empty())
		check.call("native %s preserves the surviving caller's real reply" % mode, surviving and second_replies == [true] and second.get("_pending_ipc").is_empty())
		if mode == "concurrent":
			check.call("both actual concurrent documents receive their own replies", await _wait(tree, func() -> bool: return not first_replies.is_empty()) and first_replies == [true])
		elif mode == "close":
			check.call("closed native caller is freed without delivering a reply into its old document", not is_instance_valid(first) and first_replies.is_empty())
		else:
			check.call("replacement native document receives only its own generation acknowledgement", await _wait(tree, func() -> bool: return not first_replies.is_empty()) and first_replies == [true])
		var matching: Array[Editor] = []
		for editor: Editor in pane.get_open_editors():
			if editor.file == path:
				matching.append(editor)
		check.call("native %s reuses one file-backed identity without reimporting and preserves source bytes" % mode, pending and matching.size() == 1 and matching[0] == held_editor and pane.Tabs.get_tab_count() == count + 1
			and matching[0].plugin_scene_root.call("get_sheet_data").call("get_cell_value", 1, 1) == "native-edit-" + mode
			and FileAccess.get_file_as_bytes(path) == original_bytes and FileAccess.get_file_as_bytes(recording_path) == original_bytes)
		connection.capability_request_handler = forward
		if is_instance_valid(first):
			first.queue_free()
		second.queue_free()
		await tree.process_frame
		for editor: Editor in matching:
			editor.free()
	host.set("plugin_webview_broker", previous_broker)
