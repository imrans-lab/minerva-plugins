extends RefCounted
## Legacy note Edit through the real Note route; source snapshots never change.
const ValueDomain := preload("value_domain.gd")

func _note(value: Dictionary, pane: EditorPane) -> Node:
	var script: Script = load("res://Scripts/UI/Controls/Note.gd")
	var note: Node = script.deserialize(value, false)
	pane.Tabs.get_tree().root.add_child(note)
	return note

func _close(pane: EditorPane) -> void:
	for editor: Editor in pane.get_open_editors():
		editor.free()

func run(check: Callable, pane: EditorPane, manager: PluginManager, container: Node) -> void:
	# Run the real MainUI visibility method with real controls. The standalone
	# SceneTree fixture has no application MainUI scene or its unique-name nodes.
	var host: Node = pane.Tabs.get_tree().root.get_node("SingletonObject")
	var old_ui: Variant = host.get("main_ui")
	var main_ui: Control = load("res://Scripts/UI/Controls/MainUI.gd").new()
	var chat: Control = Control.new()
	main_ui.set("chat_pane", chat)
	main_ui.set("editor_pane", pane.Tabs)
	host.set("main_ui", main_ui)
	_close(pane)
	pane.Tabs.hide()
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://test/fixtures/spreadsheet_contract/linked-note.json"))
	var first: Node = _note(fixture, pane)
	var duplicate: Dictionary = fixture.duplicate(true)
	duplicate.UUID = "legacy-note-same-reference"
	var same: Node = _note(duplicate, pane)
	first.call("_on_edit_button_pressed")
	first.call("_on_edit_button_pressed")
	same.call("_on_edit_button_pressed")
	check.call("two legacy notes and repeated Edit open one visible panel", pane.Tabs.visible and pane.get_open_editors().size() == 1)
	var editor: Editor = pane.get_open_editors()[0]
	var sheet: Node = editor.plugin_scene_root.get("sheet")
	var data: RefCounted = sheet.get("spreadsheet_data")
	check.call("legacy note seeds independent markdown cells", data.call("get_cell_value", 0, 0) == "Name"
		and data.call("get_cell_value", 1, 0) == "keep" and data.call("get_cell_value", 1, 1) == 2)
	var values: ValueDomain = ValueDomain.new()
	var seed_model: Dictionary = PluginScenePanelHost.invoke_save(editor.plugin_scene_root, {})
	values.check_model_roundtrip(check, seed_model, "legacy note seed")
	var before: Dictionary = first.call("serialize")
	editor.tab_title = "Renamed legacy sheet"
	first.call("_on_edit_button_pressed")
	check.call("rename retains stable note reference and source bytes", pane.get_open_editors().size() == 1
		and ValueDomain.equal_json(first.call("serialize"), before) and editor.associated_object == null)
	var entries: Array = await container.call("serialize")
	check.call("legacy note reference is in host envelope only", entries[0].get("legacy_spreadsheet_reference") == fixture.LinkedSpreadsheet
		and not entries[0].plugin_state.payload.__panel_state.has("legacy_spreadsheet_reference"))
	_close(pane)
	var codec: Script = load("res://Scripts/UI/Controls/vboxEditor.gd")
	var restored: Array = await codec.deserialize(entries)
	for view: Editor in restored:
		pane.Tabs.add_child(view)
		pane.Tabs.set_tab_title(pane.Tabs.get_tab_idx_from_control(view), view.tab_title)
	await pane.Tabs.get_tree().process_frame
	first.call("_on_edit_button_pressed")
	check.call("project reopen keeps renamed reference without duplicate", pane.get_open_editors().size() == 1
		and pane.get_open_editors()[0].tab_title == "Renamed legacy sheet" and ValueDomain.equal_json(first.call("serialize"), before))
	var second_fixture: Dictionary = fixture.duplicate(true)
	second_fixture.UUID = "legacy-note-second-reference"
	second_fixture.LinkedSpreadsheet = "Second legacy note"
	second_fixture.Content = fixture.Content.replace("keep", "second")
	var second: Node = _note(second_fixture, pane)
	second.call("_on_edit_button_pressed")
	check.call("second note targets a second independent sheet", pane.get_open_editors().size() == 2
		and pane.get_open_editors()[1].plugin_scene_root.call("get_sheet_data").get_cell_value(1, 0) == "second"
		and pane.get_open_editors()[0].plugin_scene_root.call("get_sheet_data").get_cell_value(1, 0) == "keep")
	_close(pane)
	var definition: PluginDefinition = manager.get_db().get_by_id("sheets")
	manager.get_db()._plugins.erase("sheets")
	first.call("_on_edit_button_pressed")
	var absent: Editor = pane.get_open_editors()[0]
	check.call("absent provider shows copyable Retry and leaves note unchanged", not absent.plugin_scene_root.get_meta("_minerva_plugin_panel_load_ok", true)
		and absent.plugin_scene_root.find_children("*", "RichTextLabel", true, false).size() == 1
		and ValueDomain.equal_json(first.call("serialize"), before))
	var absent_entries: Array = await container.call("serialize")
	_close(pane)
	var pending: Array = await codec.deserialize(absent_entries)
	for view: Editor in pending:
		pane.Tabs.add_child(view)
		pane.Tabs.set_tab_title(pane.Tabs.get_tab_idx_from_control(view), view.tab_title)
	await pane.Tabs.get_tree().process_frame
	check.call("absent note seed survives project save/reopen", pending.size() == 1
		and ValueDomain.equal_json(pending[0].pending_plugin_entry, absent_entries[0]) and ValueDomain.equal_json(first.call("serialize"), before))
	absent = pending[0]
	manager.get_db()._plugins["sheets"] = definition
	first.call("_on_edit_button_pressed")
	check.call("Edit retries on the same editor and imports the original note", pane.get_open_editors().size() == 1
		and pane.get_open_editors()[0] == absent and absent.plugin_scene_root.call("get_sheet_data").get_cell_value(1, 0) == "keep"
		and ValueDomain.equal_json(first.call("serialize"), before))
	_close(pane)
	var model: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://test/fixtures/spreadsheet_contract/session.minproj"))
	var chart_fixture: Dictionary = fixture.duplicate(true)
	chart_fixture.UUID = "legacy-chart-note"
	chart_fixture.LinkedSpreadsheet = "Legacy chart note"
	chart_fixture.Content += "\n<!-- SPREADSHEET_CHARTS\n" + JSON.stringify(model.Editors[0].content.charts) + "\n-->"
	var chart_note: Node = _note(chart_fixture, pane)
	chart_note.call("_on_edit_button_pressed")
	var chart_editor: Editor = pane.get_open_editors()[0]
	var charts: Array = chart_editor.plugin_scene_root.get("sheet").get("charts")
	check.call("legacy note chart definitions import intact", charts.size() == 1 and ValueDomain.equal_json(charts[0].to_dict(), model.Editors[0].content.charts[0]))
	_close(pane)
	for content: String in ["", "not a table", fixture.Content + "\n<!-- SPREADSHEET_CHARTS\n[{broken\n-->"]:
		var malformed: Dictionary = fixture.duplicate(true)
		malformed.UUID = "legacy-partial:" + str(content.length())
		var note: Node = _note(malformed, pane)
		note.get_controls_container().content = content
		var original: Dictionary = note.call("serialize")
		note.call("_on_edit_button_pressed")
		var notice: RichTextLabel = pane.get_open_editors()[0].plugin_scene_root.get_node("Status")
		check.call("empty or malformed legacy note warns without rewriting source", notice.visible and notice.selection_enabled
			and notice.text.contains("Couldn't fully read") and ValueDomain.equal_json(note.call("serialize"), original))
		_close(pane)
		note.free()
	var ambiguous_editors: Array[Editor] = []
	for value: String in ["first independent", "second independent"]:
		var view: Editor = pane.add_plugin_scene_editor("sheets", "sheets_panel", null, value)
		view.tab_title = "Ambiguous legacy target"
		view.plugin_scene_root.call("get_sheet_data").set_cell_value(0, 0, value)
		ambiguous_editors.append(view)
	var ambiguous_fixture: Dictionary = fixture.duplicate(true)
	ambiguous_fixture.UUID = "legacy-ambiguous-note"
	ambiguous_fixture.LinkedSpreadsheet = "Ambiguous legacy target"
	var ambiguous_note: Node = _note(ambiguous_fixture, pane)
	ambiguous_note.call("_on_edit_button_pressed")
	ambiguous_note.call("_on_edit_button_pressed")
	var failure: Editor = pane.get_open_editors()[-1]
	check.call("ambiguous legacy titles refuse visibly without mutating either model", pane.get_open_editors().size() == 3
		and failure.plugin_scene_root.find_children("*", "RichTextLabel", true, false).size() == 1
		and ambiguous_editors[0].plugin_scene_root.call("get_sheet_data").get_cell_value(0, 0) == "first independent"
		and ambiguous_editors[1].plugin_scene_root.call("get_sheet_data").get_cell_value(0, 0) == "second independent")
	_close(pane)
	ambiguous_note.free()
	for note: Node in [first, same, second, chart_note]:
		note.free()
	host.set("main_ui", old_ui)
	chat.free()
	main_ui.free()
