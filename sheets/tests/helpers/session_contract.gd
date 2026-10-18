extends RefCounted
## Real project/editor mounts and opaque fallbacks, with frozen B0 models.

func _json(value: Variant) -> Variant:
	return JSON.parse_string(JSON.stringify(value))

func _close(pane: EditorPane) -> void:
	for editor: Editor in pane.get_open_editors():
		editor.free()

func _open(entries: Array, pane: EditorPane) -> Array:
	var container_script = load("res://Scripts/UI/Controls/vboxEditor.gd")
	var views: Array = await container_script.deserialize(_json(entries))
	for view: Editor in views:
		var entered: Array[Node] = []
		view.set_meta("session_chart_entries", entered)
		var sheet: Node = view.plugin_scene_root.get_node_or_null("Sheet")
		if sheet != null:
			sheet.ready.connect(func() -> void:
				var charts: Control = sheet.get("chart_container")
				charts.child_entered_tree.connect(func(child: Node) -> void: entered.append(child))
			, CONNECT_ONE_SHOT)
		pane.Tabs.add_child(view)
		pane.Tabs.set_tab_title(pane.Tabs.get_tab_idx_from_control(view), view.tab_title)
	await pane.Tabs.get_tree().process_frame
	await pane.Tabs.get_tree().process_frame
	return views

func _opaque(check: Callable, original: Array, pane: EditorPane, container: Node) -> Array:
	var entries: Array = _json(original)
	var views: Array = []
	for pass_index: int in 2:
		_close(pane)
		views = await _open(entries, pane)
		entries = _json(await container.call("serialize"))
		check.call("opaque complete entries survive save/reopen%d" % pass_index, entries == _json(original))
	return views

func run(check: Callable, pane: EditorPane, manager: PluginManager, container: Node) -> void:
	var compatibility: Script = load("res://Scripts/Services/Plugins/SpreadsheetSession.gd")
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://test/fixtures/spreadsheet_contract/session.minproj"))
	var legacy: Dictionary = fixture.Editors[0].duplicate(true)
	legacy.file = null # Unsaved, fileless is the load-bearing migration case.
	legacy.name = "Duplicate session title"
	legacy.content.cells["0,2"] = {"type": 4, "formula": "=1<2", "value": true}
	var second: Dictionary = legacy.duplicate(true)
	second.content.cells["0,0"].value = "Second independent model"
	var entries: Array = [legacy, second]
	_close(pane)
	manager.stop_plugin("sheets")
	check.call("legacy conversion begins with a stopped real provider", not manager.get_plugin_status("sheets").get("running", false))
	for pass_index: int in 3:
		var views: Array = await _open(entries, pane)
		check.call("legacy migration restores two distinct panels pass%d" % pass_index, views.size() == 2
			and views[0].plugin_panel_key != views[1].plugin_panel_key)
		for index: int in views.size():
			var view: Editor = views[index]
			var entered: Array = view.get_meta("session_chart_entries")
			check.call("one deserialize mounts each chart exactly once sheet%d pass%d" % [index, pass_index], entered.size() == legacy.content.charts.size())
			check.call("duplicate title preserves full sheet%d pass%d" % [index, pass_index], view.tab_title == legacy.name
				and view.pending_plugin_entry.is_empty()
				and _json(PluginScenePanelHost.invoke_save(view.plugin_scene_root, {})) == [legacy.content, second.content][index])
		check.call("production legacy/native restore has the real provider ready pass%d" % pass_index, manager.get_plugin_status("sheets").get("ready", false))
		entries = _json(await container.call("serialize"))
		check.call("saved migration uses Sheets envelope pass%d" % pass_index, entries.size() == 2 and entries[1].get("type") == Editor.Type.PLUGIN_SCENE)
		_close(pane)
	var native: Dictionary = entries[1]
	var definition: PluginDefinition = manager.get_db().get_by_id("sheets")
	manager.stop_plugin("sheets")
	check.call("stopped backend is absent before UI-only restore", manager.get_connection("sheets") == null)
	var stopped: Editor = Editor.create_plugin_scene("sheets", "sheets_panel")
	stopped.pending_plugin_entry = native.duplicate(true)
	pane.Tabs.add_child(stopped)
	await pane.Tabs.get_tree().process_frame
	compatibility.restore(stopped, native, manager)
	check.call("stopped backend restores complete second UI model", stopped.pending_plugin_entry.is_empty()
		and _json(PluginScenePanelHost.invoke_save(stopped.plugin_scene_root, {})) == second.content and manager.get_connection("sheets") == null)
	_close(pane)
	definition.state = PluginDefinition.State.CRASH_LOOP
	var crashed: Array = await _open([native], pane)
	check.call("crash-loop startup refusal still restores complete UI", crashed.size() == 1 and crashed[0].pending_plugin_entry.is_empty()
		and manager.get_connection("sheets") == null and _json(PluginScenePanelHost.invoke_save(crashed[0].plugin_scene_root, {})) == second.content)
	_close(pane)
	definition.state = PluginDefinition.State.STOPPED
	var restarted: Array = await _open([native], pane)
	check.call("ordinary project restore restarts real provider", manager.get_plugin_status("sheets").get("ready", false)
		and restarted[0].pending_plugin_entry.is_empty())
	_close(pane)
	# A missing declaration is the actual absent-provider branch; restore it
	# before Retry so the same editor/key can remount a real installed panel.
	manager.get_db()._plugins.erase("sheets")
	var opaque: Array = await _opaque(check, [legacy, native], pane, container)
	check.call("absent provider retains complete legacy and native raw entries", _json(await container.call("serialize")) == [legacy, native])
	check.call("opaque second tab has selectable Retry diagnosis", opaque[1].plugin_scene_root.find_children("*", "RichTextLabel", true, false).size() == 1
		and opaque[1].plugin_scene_root.find_children("*", "Button", true, false).size() == 1)
	var key: String = opaque[1].plugin_panel_key
	manager.get_db()._plugins["sheets"] = definition
	compatibility.retry(weakref(opaque[1]), manager)
	compatibility.retry(weakref(opaque[1]), manager)
	await pane.Tabs.get_tree().process_frame
	check.call("double Retry keeps second identity and first opaque entry", opaque[1].plugin_panel_key == key and opaque[1].pending_plugin_entry.is_empty()
		and opaque[0].pending_plugin_entry == legacy and manager.get_live_panels("sheets").size() == 1
		and _json(PluginScenePanelHost.invoke_save(opaque[1].plugin_scene_root, {})) == second.content)
	_close(pane)
	var cases: RefCounted = load(ProjectSettings.globalize_path("res://../../minerva-plugins/sheets/tests/helpers/snapshot_cases.gd")).new()
	var invalid_entries: Array = cases.entries(native, check)
	for entry: Dictionary in invalid_entries:
		var refused_views: Array = await _opaque(check, [entry], pane, container)
		var refusal: Control = refused_views[0].plugin_scene_root
		var labels: Array[Node] = refusal.find_children("*", "RichTextLabel", true, false)
		check.call("refusal is mounted selectable with Retry before Save", refusal.is_inside_tree() and refusal.is_visible_in_tree()
			and labels.size() == 1 and labels[0].get("selection_enabled") == true
			and refusal.find_children("*", "Button", true, false).size() == 1)
		check.call("malformed/future snapshot remains opaque with no file write", _json(await container.call("serialize")) == [entry]
			and not await refused_views[0].save_file_to_disc("user://refused-session.minsheet")
			and not FileAccess.file_exists("user://refused-session.minsheet"))
		_close(pane)

	var panels: Array = definition.ui_panels.duplicate(true)
	definition.ui_panels[0]["kind"] = "html"
	var failed_mount: Array = await _opaque(check, [legacy], pane, container)
	check.call("installed but unmountable provider preserves complete entry", _json(await container.call("serialize")) == [legacy]
		and not failed_mount[0].plugin_scene_root.get_meta("_minerva_plugin_panel_load_ok", true))
	definition.ui_panels = panels
	compatibility.retry(weakref(failed_mount[0]), manager)
	await pane.Tabs.get_tree().process_frame
	check.call("Retry after mount repair restores full model", failed_mount[0].pending_plugin_entry.is_empty()
		and _json(PluginScenePanelHost.invoke_save(failed_mount[0].plugin_scene_root, {})) == legacy.content)
	_close(pane)
	var waiting: Editor = Editor.create_plugin_scene("sheets", "sheets_panel")
	waiting.pending_plugin_entry = native.duplicate(true)
	pane.Tabs.add_child(waiting)
	await pane.Tabs.get_tree().process_frame
	manager.stop_plugin("sheets")
	compatibility.retry(weakref(waiting), manager)
	check.call("real startup suspends Retry", waiting.plugin_restore_busy)
	waiting.free()
	var deadline: int = Time.get_ticks_msec() + 10000
	while not manager.get_plugin_status("sheets").get("ready", false) and Time.get_ticks_msec() < deadline:
		await pane.Tabs.get_tree().process_frame
	check.call("close during startup leaves no remounted editor", pane.get_open_editors().is_empty()
		and manager.get_live_panels("sheets").is_empty() and manager.get_plugin_status("sheets").get("ready", false))
	# Close after mounting but before a refused ready restore swaps its surface.
	var closing: Editor = Editor.create_plugin_scene("sheets", "sheets_panel")
	closing.pending_plugin_entry = native.duplicate(true)
	var future: Dictionary = native.duplicate(true)
	future.plugin_state.payload.__panel_state = {"version": 99}
	compatibility.restore(closing, future, manager)
	pane.Tabs.add_child(closing)
	closing.free()
	await pane.Tabs.get_tree().process_frame
	check.call("close before deferred restore leaves no panel registration", manager.get_live_panels("sheets").is_empty())
