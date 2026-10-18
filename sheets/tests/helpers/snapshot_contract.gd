extends RefCounted
## Real host capability, Note payload and Note's reopen path; no note stand-ins.

func run(check: Callable, pane: EditorPane, registry: PluginToolRegistry,
		broker: PluginScenePanelBroker, capabilities: CapabilityBroker, policy: PluginPolicy,
		panel: Control, cases: Array, names: Dictionary) -> Dictionary:
	var tree: SceneTree = pane.Tabs.get_tree()
	var host = tree.root.get_node("SingletonObject")
	var previous_notes: NotesContainer = host.notes_container
	var previous_ui: Variant = host.main_ui
	# Mount the real NotesContainer with the unique popup its scene expects.
	var notes: NotesContainer = load("res://Scenes/note/NotesContainer.gd").new()
	var popup := PersistentWindow.new()
	popup.name = "NewThreadPopup"
	notes.add_child(popup)
	popup.owner = notes
	popup.unique_name_in_owner = true
	tree.root.add_child(notes)
	host.notes_container = notes
	var main_ui = load("res://Scripts/UI/Controls/MainUI.gd").new()
	var chat := Control.new()
	tree.root.add_child(chat)
	main_ui.chat_pane = chat
	main_ui.editor_pane = pane.Tabs
	host.main_ui = main_ui
	var previous_context: Callable = capabilities.editor_note_context
	capabilities.editor_note_context = func() -> Dictionary:
		return {"broker": broker, "editors": pane.get_open_editors(), "tabs": pane.Tabs, "notes": host.notes_container}
	var unchanged: String = JSON.stringify(panel.call("_on_panel_save_request"))
	pane.Tabs.size = Vector2(960, 640)
	pane.Tabs.position = Vector2.ZERO
	tree.root.size = Vector2i(1280, 720)
	var first: Editor = pane.add_plugin_scene_editor("sheets", "sheets_panel", null, "First note witness", "create")
	var second: Editor = pane.add_plugin_scene_editor("sheets", "sheets_panel", null, "Budget", "create")
	await tree.process_frame
	first.plugin_scene_root.get("sheet").set_content("Witness,Value\nFirst,101")
	var target: Control = second.plugin_scene_root
	PluginScenePanelHost.invoke_load(target, JSON.parse_string(unchanged))
	var first_sheet = first.plugin_scene_root.get("sheet")
	var original_value: Variant = target.get("sheet").spreadsheet_data.get_cell_value(0, 0)
	first_sheet.spreadsheet_data.set_cell_value(0, 2, "=Budget!A1")
	check.call("independent cross-sheet reference resolves before Note Edit", first_sheet.spreadsheet_data.get_cell_value(0, 2) == original_value
		and str(original_value) != "#REF!")
	var first_before: Variant = JSON.parse_string(JSON.stringify(first.plugin_scene_root.call("_on_panel_save_request")))
	var second_before: Variant = JSON.parse_string(JSON.stringify(target.call("_on_panel_save_request")))
	await tree.process_frame
	check.call("snapshot fixture has a visible drawable target", target.is_visible_in_tree() and target.get_global_rect().has_area())
	check.call("snapshot targets the second of two different live Sheets", first.plugin_panel_key != second.plugin_panel_key
		and broker.get_panel_for_editor(first.tab_title) == first.plugin_scene_root
		and broker.get_panel_for_editor(second.tab_title) == target and first_before != second_before)
	pane.Tabs.current_tab = pane.Tabs.get_tab_idx_from_control(first)
	var called: Dictionary = {}
	for entry: Array in cases:
		var canonical: String = names[entry[0]]
		var arguments: Dictionary = entry[1].duplicate(true)
		arguments["editor_name"] = second.tab_title
		called[canonical] = true
		if canonical == "minerva_sheets_link_to_note":
			policy.revoke_capability("sheets", "host.notes.create_from_editor")
			check.call("snapshot denial precondition has no capability grant", not policy.is_capability_granted("sheets", "host.notes.create_from_editor"))
			var denied: Dictionary = await registry.handle_tool_call(canonical, arguments)
			check.call("snapshot capability without a grant refuses without adding notes", denied.get("success") == false and notes.get_notes().is_empty())
			policy.grant_capability("sheets", "host.notes.create_from_editor")
			var result: Dictionary = await registry.handle_tool_call(canonical, arguments)
			var created: Array[Note] = notes.get_notes()
			check.call("canonical snapshot creates one real plugin-data note", result.get("success") == true
				and result.get("snapshot") == true and created.size() == 1
				and created[0].type == Note.Type.PLUGIN_DATA and result.get("note_uuid") == created[0].uuid
				and result.get("linked_spreadsheet") == second.tab_title)
			check.call("snapshot capture restores the first sheet's visible tab", pane.Tabs.get_current_tab_control() == first)
			if created.size() == 1 and created[0].type == Note.Type.PLUGIN_DATA:
				var note: Note = created[0]
				var wrapper: Dictionary = JSON.parse_string(note.linked_plugin_payload)
				check.call("snapshot note contains the complete independent sheet model", wrapper.get("plugin_id") == "sheets"
					and wrapper.get("payload") == second_before)
				var before: int = pane.Tabs.get_tab_count()
				note.call("_open_linked_plugin_panel", pane)
				await tree.process_frame
				var reopened: Editor = pane.Tabs.get_child(pane.Tabs.get_child_count() - 1)
				check.call("real Note Edit reopens an identical spreadsheet snapshot", pane.Tabs.get_tab_count() == before + 1
					and reopened.associated_object == note and reopened.plugin_id == "sheets"
					and JSON.stringify(reopened.plugin_scene_root.call("_on_panel_save_request")) == unchanged)
				first_sheet.spreadsheet_data.recalculate_all()
				var original_lookup: Dictionary = await registry.handle_tool_call("minerva_sheets_get_data", {"editor_name": "Budget"})
				var snapshot_lookup: Dictionary = await registry.handle_tool_call("minerva_sheets_get_data", {"editor_name": reopened.tab_title})
				check.call("snapshot has a distinct address while original sheet references remain valid", reopened.tab_title != second.tab_title
					and original_lookup.get("success") == true and snapshot_lookup.get("success") == true
					and first_sheet.spreadsheet_data.get_cell_value(0, 2) == original_value)
				reopened.free()
				await tree.process_frame
			pane.Tabs.current_tab = pane.Tabs.get_tab_idx_from_control(first)
			var foreign: Dictionary = await capabilities.dispatch("sheets", "host.notes.create_from_editor", {"editor_name": "Legacy contract"})
			check.call("snapshot capability refuses an editor owned by another provider", foreign.get("success") == false and notes.get_notes().size() == 1)
			var replacement: NotesContainer = load("res://Scenes/note/NotesContainer.gd").new()
			var swap_notes := func() -> void: host.notes_container = replacement
			RenderingServer.frame_pre_draw.connect(swap_notes, CONNECT_ONE_SHOT)
			var replaced: Dictionary = await capabilities.dispatch("sheets", "host.notes.create_from_editor", {"editor_name": second.plugin_panel_key})
			check.call("notes replacement during real capture refuses without publishing", host.notes_container == replacement
				and replaced.get("success") == false and notes.get_notes().size() == 1 and replacement.get_notes().is_empty()
				and pane.Tabs.get_current_tab_control() == first)
			if RenderingServer.frame_pre_draw.is_connected(swap_notes):
				RenderingServer.frame_pre_draw.disconnect(swap_notes)
			host.notes_container = notes
			replacement.free()
			# c4814 staging falsifier: real caller cancellation may leave one note,
			# but it must neither change any sheet nor leave backend/IPC work running.
			var cancel_context := MCPExecutionContext.create("module")
			var capture_armed: Array[bool] = [false]
			var capture_started: Array[bool] = [false]
			var live_context: Callable = capabilities.editor_note_context
			var cancel_capture := func() -> void:
				capture_started[0] = target.is_visible_in_tree() and pane.Tabs.get_current_tab_control() == second
				cancel_context.cancel()
			var arm_capture := func() -> void:
				RenderingServer.frame_pre_draw.connect(cancel_capture, CONNECT_ONE_SHOT)
			capabilities.editor_note_context = func() -> Dictionary:
				if not capture_armed[0]:
					capture_armed[0] = true
					# Arm on the layout frame: the real capture then awaits this draw.
					tree.process_frame.connect(arm_capture, CONNECT_ONE_SHOT)
				return live_context.call()
			var backend = host.plugin_manager.get_connection("sheets")
			var backend_pending: Dictionary = backend.get("_pending")
			check.call("capture cancellation starts without backend work", backend_pending.is_empty())
			var notes_before: int = notes.get_notes().size()
			var cancelled: Dictionary = await registry.handle_tool_call(canonical, arguments, cancel_context)
			await tree.process_frame
			await tree.process_frame
			if RenderingServer.frame_pre_draw.is_connected(cancel_capture):
				RenderingServer.frame_pre_draw.disconnect(cancel_capture)
			if tree.process_frame.is_connected(arm_capture):
				tree.process_frame.disconnect(arm_capture)
			capabilities.editor_note_context = live_context
			var pending_ipc: Dictionary = target.get_node("_MinervaIPC").get("_pending")
			backend_pending = backend.get("_pending")
			check.call("real cancelled capture has only the accepted staged extra-note effect", capture_started[0]
				and cancel_context.is_stopped() and cancelled.get("error_code") == "cancelled"
				and notes.get_notes().size() >= notes_before and notes.get_notes().size() <= notes_before + 1
				and pending_ipc.is_empty() and backend_pending.is_empty())
			print("Staged capture cancellation extra notes: %d" % (notes.get_notes().size() - notes_before))
		else:
			var result: Dictionary = await registry.handle_tool_call(canonical, arguments)
			var status: RichTextLabel = target.get_node("Status")
			check.call("Nudge absence is explicit visible logged and copyable", result.get("success") == false
				and result.get("error_code") == "nudge_unavailable" and status.visible and status.selection_enabled)
		check.call(canonical + " preserves all independent complete sheet models", JSON.stringify(panel.call("_on_panel_save_request")) == unchanged
			and JSON.parse_string(JSON.stringify(first.plugin_scene_root.call("_on_panel_save_request"))) == first_before
			and JSON.parse_string(JSON.stringify(target.call("_on_panel_save_request"))) == second_before)
	first.free()
	second.free()
	capabilities.editor_note_context = previous_context
	host.notes_container = previous_notes
	host.main_ui = previous_ui
	notes.free()
	main_ui.free()
	chat.free()
	return called
