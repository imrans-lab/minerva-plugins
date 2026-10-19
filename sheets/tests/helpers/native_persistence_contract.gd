extends RefCounted
## Independent field/value oracles must not inherit the serializer's omissions.

func run(check: Callable, pane: EditorPane, host: Node) -> void:
	var tree: SceneTree = pane.Tabs.get_tree()
	var path := ProjectSettings.globalize_path("user://native-persistence-adversary.minsheet")
	var editor: Editor = pane.add_plugin_scene_editor("sheets", "sheets_panel", "", "Native persistence adversary", "")
	var sheet: Node = editor.plugin_scene_root.get("sheet")
	for entry: Array in [[0, 0, 1], [1, 0, 4], [1, 1, 5], [1, 2, 6],
		[0, 1, "=A1+1"], [0, 2, "=B1+1"], [0, 3, "=SUM(A1:C2)"]]:
		sheet.call("set_cell_value_with_history", entry[0], entry[1], entry[2])
	sheet.call("format_cell_with_history", 2, 2, {"bold": true, "bg_color": Color.RED, "number_format": "currency"})
	var data: RefCounted = sheet.get("spreadsheet_data")
	var blank: RefCounted = data.call("get_cell_if_exists", 2, 2)
	check.call("blank-format producer really has an EMPTY formatted cell", blank.call("is_empty") and blank.get("bold") and blank.get("bg_color") == Color.RED)
	check.call("adversarial native host Save succeeds", await editor.save_file_to_disc(path))
	var saved: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	var saved_blank: Dictionary = saved.cells.get("2,2", {})
	check.call("native file independently contains the blank cell's formatting", saved_blank.get("bold") == true
		and saved_blank.get("bg_color") == "ff0000ff" and saved_blank.get("number_format") == "currency")
	editor.free()
	var opened: Dictionary = host.call("open_file_at_path", path)
	editor = pane.Tabs.get_current_tab_control()
	await tree.create_timer(0.6).timeout
	sheet = editor.plugin_scene_root.get("sheet")
	data = sheet.get("spreadsheet_data")
	blank = data.call("get_cell_if_exists", 2, 2)
	check.call("native reopen independently restores blank formatting", opened.get("ok") == true and blank != null
		and blank.get("bold") and blank.get("bg_color") == Color.RED and blank.get("number_format") == "currency")
	sheet.call("set_cell_value_with_history", 0, 0, 2)
	check.call("native reopen edit updates the entire formula chain", data.call("get_cell_value", 0, 1) == 3
		and data.call("get_cell_value", 0, 2) == 4)
	check.call("native reopen edit updates the rectangular SUM", data.call("get_cell_value", 0, 3) == 24)
	sheet.call("set_cell_value_with_history", 1, 0, 40)
	check.call("rectangular SUM tracks a second-row precedent", data.call("get_cell_value", 0, 3) == 60)
	var second := path + ".second.minsheet"
	var written: bool = await editor.save_file_to_disc(second)
	var persisted: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(second))
	check.call("native Save persists correct updated formula caches", written and persisted.cells["0,1"].value == 3
		and persisted.cells["0,2"].value == 4 and persisted.cells["0,3"].value == 60)
	editor.free()
	opened = host.call("open_file_at_path", second)
	editor = pane.Tabs.get_current_tab_control()
	await tree.create_timer(0.6).timeout
	sheet = editor.plugin_scene_root.get("sheet")
	data = sheet.get("spreadsheet_data")
	sheet.call("set_cell_value_with_history", 0, 0, 3)
	check.call("second native reopen restores live chain and range dependencies", opened.get("ok") == true
		and data.call("get_cell_value", 0, 1) == 4 and data.call("get_cell_value", 0, 2) == 5
		and data.call("get_cell_value", 0, 3) == 63)
	editor.free()
