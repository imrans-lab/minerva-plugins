extends RefCounted
## Compare complete results/models with the historical builtin capture.
## Only editor locators and generated chart IDs are normalized.

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
	var plugin: Editor = pane.add_plugin_scene_editor("sheets", "sheets_panel", null, "Canonical contract", "create")
	await pane.Tabs.get_tree().process_frame
	var panel: Control = plugin.plugin_scene_root
	var sheet = panel.get("sheet")
	PluginScenePanelHost.invoke_load(panel, baseline)
	var generated: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(source.path_join("tests/fixtures/tool-cases.json")))
	var frozen: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(source.path_join("tests/fixtures/builtin-tool-oracle.json")))
	var cases: Array = generated.parity
	var new_ids: Dictionary = {}
	var called: Dictionary = {}
	for index: int in range(cases.size()):
		var entry: Array = cases[index]
		var historical: Dictionary = frozen.cases[index]
		var legacy: String = entry[0]
		var canonical: String = names[legacy]
		var new_args: Dictionary = _json(entry[1])
		new_args["editor_name"] = "Canonical contract"
		var current: Dictionary = await registry.handle_tool_call(canonical, new_args)
		_chart_ids(sheet.charts, new_ids)
		called[canonical] = true
		var expected_success: bool = legacy != "minerva_get_chart_image"
		if canonical == "minerva_sheets_get_data":
			var used: Rect2i = sheet.spreadsheet_data.get_used_range()
			check.call("additive read metadata reports actual used bounds", current.get("used_row_count") == used.size.y and current.get("used_column_count") == used.size.x)
			current.erase("used_row_count")
			current.erase("used_column_count")
		var parity: bool = (historical.legacy == legacy and historical.arguments == _json(entry[1])
			and current.get("success") == expected_success
			and _json(_normalize(current, new_ids, names)) == historical.result
			and _json(_normalize(panel.call("_on_panel_save_request"), new_ids, names))
			== historical.model)
		check.call(canonical + " complete result and model match frozen builtin", parity)
		if not parity:
			print("PARITY old=" + JSON.stringify(historical.result).left(1200) + " new=" + JSON.stringify(current).left(1200))
		if legacy == "minerva_set_cell_formula":
			check.call("canonical formula independent result is5", sheet.spreadsheet_data.get_cell_value(1, 1) == 5)
		if legacy == "minerva_get_chart_image":
			var new_png: String = await sheet.chart_canvases[0].capture_to_base64_png(64, 32)
			var image := Image.new()
			check.call("raw chart still matches the historical64x32PNG", frozen.raw_chart_png == new_png
				and image.load_png_from_buffer(Marshalls.base64_to_raw(new_png)) == OK and image.get_size() == Vector2i(64, 32))
			var charts: RefCounted = load(source.path_join("tests/helpers/chart_contract.gd")).new()
			await charts.call("run", check, pane, registry, broker, plugin, source, entry, new_png)
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
	plugin.free()
