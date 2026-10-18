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
	var called: Dictionary = {}
	for entry: Array in cases:
		var canonical: String = names[entry[0]]
		var arguments: Dictionary = entry[1].duplicate(true)
		arguments["editor_name"] = "Canonical contract"
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
				and created[0].type == Note.Type.PLUGIN_DATA and result.get("note_uuid") == created[0].uuid)
			if created.size() == 1:
				var note: Note = created[0]
				var wrapper: Dictionary = JSON.parse_string(note.linked_plugin_payload)
				check.call("snapshot note contains the complete independent sheet model", wrapper.get("plugin_id") == "sheets"
					and wrapper.get("payload") == JSON.parse_string(unchanged))
				var before: int = pane.Tabs.get_tab_count()
				note.call("_open_linked_plugin_panel", pane)
				await tree.process_frame
				var reopened: Editor = pane.Tabs.get_child(pane.Tabs.get_child_count() - 1)
				check.call("real Note Edit reopens an identical spreadsheet snapshot", pane.Tabs.get_tab_count() == before + 1
					and reopened.associated_object == note and reopened.plugin_id == "sheets"
					and JSON.stringify(reopened.plugin_scene_root.call("_on_panel_save_request")) == unchanged)
				reopened.free()
				await tree.process_frame
			var foreign: Dictionary = await capabilities.dispatch("sheets", "host.notes.create_from_editor", {"editor_name": "Legacy contract"})
			check.call("snapshot capability refuses an editor owned by another provider", foreign.get("success") == false and notes.get_notes().size() == 1)
			var replacement: NotesContainer = load("res://Scenes/note/NotesContainer.gd").new()
			var swap_notes := func() -> void: host.notes_container = replacement
			RenderingServer.frame_pre_draw.connect(swap_notes, CONNECT_ONE_SHOT)
			var replaced: Dictionary = await capabilities.dispatch("sheets", "host.notes.create_from_editor", {"editor_name": "Canonical contract"})
			check.call("notes replacement during real capture refuses without publishing", host.notes_container == replacement
				and replaced.get("success") == false and notes.get_notes().size() == 1 and replacement.get_notes().is_empty())
			if RenderingServer.frame_pre_draw.is_connected(swap_notes):
				RenderingServer.frame_pre_draw.disconnect(swap_notes)
			host.notes_container = notes
			replacement.free()
		else:
			var result: Dictionary = await registry.handle_tool_call(canonical, arguments)
			var status: RichTextLabel = panel.get_node("Status")
			check.call("Nudge absence is explicit visible logged and copyable", result.get("success") == false
				and result.get("error_code") == "nudge_unavailable" and status.visible and status.selection_enabled)
		check.call(canonical + " preserves the complete source model", JSON.stringify(panel.call("_on_panel_save_request")) == unchanged)
	capabilities.editor_note_context = previous_context
	host.notes_container = previous_notes
	host.main_ui = previous_ui
	notes.free()
	main_ui.free()
	chat.free()
	return called
