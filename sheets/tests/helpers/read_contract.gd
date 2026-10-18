extends RefCounted
## Real mounted panels and the installed provider; expected values are independent.

func _read_into(registry: PluginToolRegistry, name_: String, results: Array[Dictionary]) -> void:
	results.append(await registry.handle_tool_call("minerva_sheets_get_data", {"editor_name": name_, "format": "json", "range": "A2:C4"}))

func run(check: Callable, pane: EditorPane, registry: PluginToolRegistry) -> void:
	var tree: SceneTree = pane.Tabs.get_tree()
	var first: Editor = pane.add_plugin_scene_editor("sheets", "sheets_panel", null, "Read witness", "create")
	var second: Editor = pane.add_plugin_scene_editor("sheets", "sheets_panel", null, "Read target", "create")
	await tree.process_frame
	first.plugin_scene_root.get("sheet").set_content("Other,111")
	var sheet = second.plugin_scene_root.get("sheet")
	sheet.set_content("H1,H2,H3\n1,2,3\n4,5,6\n7,8,9\n10,11,12")
	var witness: String = JSON.stringify(first.plugin_scene_root.call("_on_panel_save_request"))
	var original: String = JSON.stringify(second.plugin_scene_root.call("_on_panel_save_request"))
	var expected: Dictionary = {"csv": "1.0,2.0,3.0\n4.0,5.0,6.0\n7.0,8.0,9.0", "json": [[1.0,2.0,3.0],[4.0,5.0,6.0],[7.0,8.0,9.0]],
		"markdown": "| 1   | 2   | 3   |\n| --- | --- | --- |\n| 4   | 5   | 6   |\n| 7   | 8   | 9   |"}
	for format_: String in ["csv", "json", "markdown"]:
		var result: Dictionary = await registry.handle_tool_call("minerva_sheets_get_data", {"editor_name": second.tab_title, "format": format_, "range": "A2:C4"})
		check.call("exact A2:C4 values and sheet-relative offset " + format_, result.get("success") == true and result.get("data") == expected[format_]
			and result.get("data_starts_at_row") == 2 and result.get("column_count") == 3 and result.get("range") == "A2:C4")
	for invalid: String in ["A0", "B2:A1", "A1:AA1", "A1:A101", "A1:B2:C3", "A99999999999999999999999999", "ZZZZZZZZZZZZZZZZZZZZZZZZ1"]:
		var result: Dictionary = await registry.handle_tool_call("minerva_sheets_get_data", {"editor_name": second.tab_title, "range": invalid})
		check.call("invalid range visibly refuses: " + invalid, result.get("error_code") == "invalid_range" and not result.has("data"))
	check.call("valid and refused reads leave both complete models unchanged", JSON.stringify(second.plugin_scene_root.call("_on_panel_save_request")) == original
		and JSON.stringify(first.plugin_scene_root.call("_on_panel_save_request")) == witness)
	var pending: Array[Dictionary] = []
	_read_into(registry, second.plugin_panel_key, pending)
	_read_into(registry, second.plugin_panel_key, pending)
	var updated: Dictionary = await registry.handle_tool_call("minerva_sheets_update_data", {"editor_name": second.plugin_panel_key, "csv_content": "H1,H2,H3\n1,2,3\n4,5,6\n7,8,9"})
	var deadline: int = Time.get_ticks_msec() + 10000
	while pending.size() < 2 and Time.get_ticks_msec() < deadline:
		await tree.process_frame
	check.call("concurrent reads beside an update return complete ranges", updated.get("success") == true and pending.size() == 2 and pending.all(func(result: Dictionary) -> bool: return result.get("data") == expected.json))
	second.tab_title = first.tab_title
	var identity: Dictionary = await registry.handle_tool_call("minerva_sheets_get_data", {"editor_name": second.plugin_panel_key, "format": "json", "range": "A2:C4"})
	check.call("duplicate titles retain exact second-panel identity", identity.get("data") == expected.json and JSON.stringify(first.plugin_scene_root.call("_on_panel_save_request")) == witness)
	second.tab_title = "Renamed read target"
	var renamed: Dictionary = await registry.handle_tool_call("minerva_sheets_get_data", {"editor_name": second.tab_title, "format": "json", "range": "A2:C4"})
	check.call("renamed target remains addressable", renamed.get("data") == expected.json)
	var lines := PackedStringArray()
	var full: Array = []
	for row: int in range(10000):
		lines.append("row%d" % row)
		full.append(["row%d" % row])
	sheet.set_content("\n".join(lines))
	var page: Dictionary = await registry.handle_tool_call("minerva_sheets_get_data", {"editor_name": second.plugin_panel_key, "format": "json", "range": "A501:A1000"})
	check.call("10k-row page501-1000 matches independently generated full rows", page.get("data") == full.slice(500, 1000) and page.get("data_starts_at_row") == 501 and page.get("used_row_count") == 10000)
	var oversized: Dictionary = await registry.handle_tool_call("minerva_sheets_get_data", {"editor_name": second.plugin_panel_key, "format": "json"})
	var suggested: Dictionary = await registry.handle_tool_call("minerva_sheets_get_data", {"editor_name": second.plugin_panel_key, "format": "json", "range": oversized.get("suggested_range", "invalid")})
	check.call("oversized sheet refuses and its suggested range really fits", oversized.get("error_code") == "payload_too_large" and not oversized.has("data") and suggested.get("success") == true and suggested.get("data") == [["row0"]])
	sheet.set_content("Header,Other\nvalue,tail")
	var counts: Dictionary = await registry.handle_tool_call("minerva_sheets_get_data", {"editor_name": second.plugin_panel_key, "format": "json", "range": "A1"})
	check.call("used counts exclude blank trailing allocated rows", counts.get("used_row_count") == 2 and counts.get("used_column_count") == 2 and counts.get("row_count") == 10000 and counts.get("data") == [["Header"]])
	var long_text: String = "abcdefghijklmnopqrstuvwxyz0123456789Júlia"
	sheet.set_content("Header\n" + long_text)
	for format_: String in ["json", "markdown"]:
		var result: Dictionary = await registry.handle_tool_call("minerva_sheets_get_data", {"editor_name": second.plugin_panel_key, "format": format_})
		check.call("long Unicode cell is complete without ellipsis " + format_, result.get("success") == true and str(result.get("data")).contains(long_text) and not str(result.get("data")).contains("…"))
	var rendered: Array = second.plugin_scene_root.call("_on_panel_render_for_llm", {})
	check.call("LLM render preserves full long cell text", str(rendered[0].text).contains(long_text))
	sheet.set_content("Huge".repeat(20000))
	var too_large: Dictionary = await registry.handle_tool_call("minerva_sheets_get_data", {"editor_name": second.plugin_panel_key, "range": "A1"})
	check.call("oversized single cell names itself without a fake fitting range", too_large.get("error_code") == "cell_too_large" and too_large.get("cell") == "A1" and too_large.get("cell_bytes") == 80000 and not too_large.has("suggested_range") and not too_large.has("data"))
	rendered = second.plugin_scene_root.call("_on_panel_render_for_llm", {})
	check.call("oversized LLM render visibly refuses instead of ellipsis", JSON.parse_string(rendered[0].text).get("error_code") == "cell_too_large")
	sheet.set_content("")
	var blank: Dictionary = await registry.handle_tool_call("minerva_sheets_get_data", {"editor_name": second.plugin_panel_key, "range": "A1", "format": "json"})
	check.call("empty sheet still permits minimal import verification", blank.get("success") == true and blank.get("used_row_count") == 0 and blank.get("data") == [])
	first.free()
	second.free()
