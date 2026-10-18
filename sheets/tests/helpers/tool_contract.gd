extends RefCounted
## Full-host comparison with the unchanged builtin. Only editor locators and
## generated chart IDs are normalized; no response or model fields are dropped.

func _normalize(value: Variant, ids: Dictionary, names: Dictionary) -> Variant:
	if value is String:
		if ids.has(value):
			return ids[value]
		var text: String = value
		for original: String in names:
			text = text.replace(original, str(names[original]))
		return text
	if value is Dictionary:
		var result: Dictionary = {}
		for key: Variant in value:
			result[key] = _normalize(value[key], ids, names)
		return result
	if value is Array:
		var result: Array = []
		for item: Variant in value:
			result.append(_normalize(item, ids, names))
		return result
	return value

func _json(value: Variant) -> Variant:
	return JSON.parse_string(JSON.stringify(value))

func _chart_ids(charts: Array, ids: Dictionary) -> void:
	for chart: RefCounted in charts:
		var id: String = chart.get("id")
		if not ids.has(id):
			ids[id] = "chart:%d" % ids.size()

func run(check: Callable, pane: EditorPane, registry: PluginToolRegistry,
		broker: PluginScenePanelBroker, source: String, capabilities: CapabilityBroker, policy: PluginPolicy) -> void:
	var baseline: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://test/fixtures/spreadsheet_contract/baseline.minsheet"))
	var names: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(source.path_join("scripts/legacy-tools.json")))
	names["Legacy contract"] = "contract editor"
	names["Canonical contract"] = "contract editor"
	var builtin: Editor = Editor.create(Editor.Type.SPREADSHEET, null, "Legacy contract", null, false)
	pane.Tabs.add_child(builtin)
	var plugin: Editor = pane.add_plugin_scene_editor("sheets", "sheets_panel", null, "Canonical contract", "create")
	await pane.Tabs.get_tree().process_frame
	var panel: Control = plugin.plugin_scene_root
	var sheet = panel.get("sheet")
	builtin.spreadsheet_editor.deserialize(baseline)
	PluginScenePanelHost.invoke_load(panel, baseline)
	# Autoload-dependent builtin modules are intentionally loaded at runtime.
	var old_tools = load("res://Scripts/Services/MCP/Modules/MCPSpreadsheetTools.gd").new(null)
	var old_filters = load("res://Scripts/Services/MCP/Modules/MCPSpreadsheetFilterTools.gd").new(null)
	var generated: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(source.path_join("tests/fixtures/tool-cases.json")))
	var cases: Array = generated.parity
	var old_ids: Dictionary = {}
	var new_ids: Dictionary = {}
	var called: Dictionary = {}
	for entry: Array in cases:
		var legacy: String = entry[0]
		var canonical: String = names[legacy]
		var old_args: Dictionary = _json(entry[1])
		old_args["editor_name"] = "Legacy contract"
		var new_args: Dictionary = old_args.duplicate(true)
		new_args["editor_name"] = "Canonical contract"
		var previous: Dictionary
		if legacy.begins_with("minerva_spreadsheet_autofilter_"):
			previous = await old_filters.handle(legacy, old_args)
		else:
			previous = await old_tools.handle(legacy, old_args)
		var current: Dictionary = await registry.handle_tool_call(canonical, new_args)
		_chart_ids(builtin.spreadsheet_editor.charts, old_ids)
		_chart_ids(sheet.charts, new_ids)
		called[canonical] = true
		var expected_success: bool = legacy != "minerva_get_chart_image"
		var parity: bool = (current.get("success") == expected_success
			and _json(_normalize(current, new_ids, names)) == _json(_normalize(previous, old_ids, names))
			and _json(_normalize(panel.call("_on_panel_save_request"), new_ids, names))
			== _json(_normalize(builtin.spreadsheet_editor.serialize(), old_ids, names)))
		check.call(canonical + " complete result and model match builtin", parity)
		if not parity:
			print("PARITY old=" + JSON.stringify(previous).left(1200) + " new=" + JSON.stringify(current).left(1200))
		if legacy == "minerva_set_cell_formula":
			check.call("canonical formula independent result is5", sheet.spreadsheet_data.get_cell_value(1, 1) == 5)
		if legacy == "minerva_get_chart_image":
			var old_source: String = old_tools.get_script().get("source_code")
			var new_source: String = panel.get("_tools").get_script().get("source_code")
			check.call("XFAIL valid MCP chart image still references missing canvas on both sides",
				"_chart_canvas" not in builtin.spreadsheet_editor and "_chart_canvas" not in sheet
				and old_source.contains("var chart_canvas = editor.spreadsheet_editor._chart_canvas")
				and new_source.contains("var chart_canvas = editor.spreadsheet_editor._chart_canvas")
				and builtin.spreadsheet_editor.chart_canvases.size() == 1 and sheet.chart_canvases.size() == 1)
			# Raw domain capture is a separate proof, not a claim that MCP export works.
			var old_png: String = await builtin.spreadsheet_editor.chart_canvases[0].capture_to_base64_png(64, 32)
			var new_png: String = await sheet.chart_canvases[0].capture_to_base64_png(64, 32)
			var image := Image.new()
			check.call("raw domain chart capture yields a real64x32PNG", old_png == new_png
				and image.load_png_from_buffer(Marshalls.base64_to_raw(new_png)) == OK and image.get_size() == Vector2i(64, 32))
	var unchanged: Variant = _json(panel.call("_on_panel_save_request"))
	var second: Editor = pane.add_plugin_scene_editor("sheets", "sheets_panel", null, "Second contract", "create")
	await pane.Tabs.get_tree().process_frame
	var second_panel: Control = second.plugin_scene_root
	PluginScenePanelHost.invoke_load(second_panel, baseline)
	check.call("two live Sheets panels have distinct routing identities", second_panel != panel
		and second.plugin_panel_key != plugin.plugin_panel_key and broker.get_panel_for_editor("Second contract") == second_panel)
	var second_args: Dictionary
	for entry: Array in cases:
		if entry[0] == "minerva_update_spreadsheet_data":
			second_args = _json(entry[1])
	second_args["editor_name"] = "Second contract"
	var targeted: Dictionary = await registry.handle_tool_call("minerva_sheets_update_data", second_args)
	check.call("host dispatch mutates the second sheet and preserves the first", targeted.get("success") == true
		and second_panel.get("sheet").spreadsheet_data.get_cell_value(1, 0) == "changed"
		and _json(panel.call("_on_panel_save_request")) == unchanged)
	second.free()
	var snapshots: RefCounted = load(source.path_join("tests/helpers/snapshot_contract.gd")).new()
	called.merge(await snapshots.call("run", check, pane, registry, broker, capabilities, policy, panel, generated.staged, names))
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(source.path_join("manifest.json")))
	var expected: Dictionary = {}
	for tool: Dictionary in manifest.tools:
		if tool.get("executor") == "panel":
			expected[tool.name] = true
	check.call("every generated panel tool was exercised", called == expected)
	var by_key: Dictionary = await registry.handle_tool_call("minerva_sheets_get_data", {"editor_name": plugin.plugin_panel_key})
	check.call("canonical panel key resolves its own sheet", by_key.get("success") == true)
	var missing: Dictionary = await registry.handle_tool_call("minerva_sheets_update_data", {"csv_content": "bad"})
	check.call("missing editor locator refuses without mutation", missing.get("error_code") == PluginErrors.CODE_EDITOR_NAME_REQUIRED
		and _json(panel.call("_on_panel_save_request")) == unchanged)
	var foreign := MinervaPluginPanel.new()
	pane.Tabs.get_tree().root.add_child(foreign)
	broker.register_panel(foreign, "foreign_contract", "foreign-panel", PackedStringArray())
	var wrong: Dictionary = await registry.handle_tool_call("minerva_sheets_update_data", {"editor_name": "foreign-panel", "csv_content": "bad"})
	check.call("another plugin's registered panel refuses without mutation", wrong.get("error_code") == PluginErrors.CODE_PANEL_NOT_OWNED
		and _json(panel.call("_on_panel_save_request")) == unchanged)
	broker.unregister_panel("foreign_contract", "foreign-panel")
	foreign.free()
	PluginScenePanelHost.invoke_unload(panel)
	var stopped: Dictionary = await registry.handle_tool_call("minerva_sheets_update_data", {"editor_name": plugin.plugin_panel_key, "csv_content": "bad"})
	check.call("unloaded panel refuses without mutation", stopped.get("success") == false
		and _json(panel.call("_on_panel_save_request")) == unchanged)
	builtin.free()
	plugin.free()
