extends RefCounted
## The Windows H1 CSV through the real Go create(file_path) and live panel.

const CSV_SHA256: String = "82a066c19397d3885221438da1e0cb12519f82e591625d21cf792cb4c6f1d4e3"

func run(check: Callable, pane: EditorPane, registry: PluginToolRegistry) -> void:
	var lines: PackedStringArray = []
	var header: PackedStringArray = []
	for column: int in range(20):
		header.append("Column %d" % (column + 1))
	lines.append(",".join(header))
	for row: int in range(1, 10000):
		var values: PackedStringArray = []
		for column: int in range(20):
			values.append("=SUM(B2:B3)" if row == 1 and column == 2 else str(row + column))
		lines.append(",".join(values))
	var csv: String = "\r\n".join(lines) + "\r\n"
	var path: String = ProjectSettings.globalize_path("user://H1 10k rows Zoë.csv")
	var file := FileAccess.open(path, FileAccess.WRITE)
	check.call("H1 exact dense CSV fixture can be written", file != null)
	if file == null:
		return
	file.store_string(csv)
	file.close()
	check.call("H1 fixture matches the immutable Windows CSV", FileAccess.get_sha256(path) == CSV_SHA256)
	check.call("H1 uses a rendered display", DisplayServer.get_name() != "headless")
	var previous_size: Vector2 = pane.Tabs.size
	pane.Tabs.size = pane.Tabs.get_viewport_rect().size
	print("H1_DENSE_CREATE_BEGIN ticks_ms=%d" % Time.get_ticks_msec())
	var started: int = Time.get_ticks_msec()
	var result: Dictionary = await registry.handle_tool_call("minerva_sheets_create_editor", {"name": "H1 exact dense import", "file_path": path})
	print("H1_DENSE_RPC_END elapsed_ms=%d result=%s" % [Time.get_ticks_msec() - started, JSON.stringify(result)])
	var imported: Editor = null
	for editor: Editor in pane.get_open_editors():
		if editor.file == path:
			imported = editor
	check.call("H1 file-backed create leaves its real live panel mounted", imported != null and imported.plugin_scene_root != null)
	if imported == null or imported.plugin_scene_root == null:
		pane.Tabs.size = previous_size
		return
	# External panel types are dynamically loaded by the plugin generation.
	var sheet = imported.plugin_scene_root.get("sheet")
	var data = sheet.spreadsheet_data
	sheet.cells_canvas.queue_redraw()
	await RenderingServer.frame_post_draw
	var elapsed: int = Time.get_ticks_msec() - started
	print("H1_DENSE_RENDER_END elapsed_ms=%d" % elapsed)
	check.call("H1 real create and first rendered frame finish within ten seconds", result.get("success") == true and result.get("rows_imported") == 10000 and elapsed < 10000
		and sheet.cells_canvas.is_visible_in_tree() and sheet.cells_canvas.size.x > 0 and sheet.cells_canvas.size.y > 0)
	check.call("H1 real AutoFilter UI remains subscribed", sheet.autofilter_ui != null and data.data_changed.is_connected(sheet.autofilter_ui._on_sheet_changed))
	check.call("H1 complete model matches independently derived cells and metadata", data.to_dict() == _expected_model())
	check.call("H1 forward formula keeps its expression and recalculated value", data.get_cell_if_exists(1, 2).formula == "=SUM(B2:B3)" and data.get_cell_value(1, 2) == 5
		and data.get_cell_display(1, 2) == "5")
	check.call("H1 preserves imported dirty state without edit history", imported._plugin_scene_modified and not sheet.can_undo() and not sheet.can_redo())
	await _check_clipboard(check, sheet)
	check.call("H1 importing preserves every source byte", FileAccess.get_sha256(path) == CSV_SHA256)
	imported.free()
	pane.Tabs.size = previous_size
	_check_notifications(check, data.get_script())

func _check_notifications(check: Callable, data_script: GDScript) -> void:
	# The plugin generation supplies this runtime-loaded model class.
	var data = data_script.new()
	var snapshots: Array[Dictionary] = []
	var record := func() -> void: snapshots.append(data.to_dict())
	data.structure_changed.connect(record)
	data.data_changed.connect(record)
	data.from_csv("A,B,C\n1,2,=SUM(A2:B2)")
	check.call("CSV observers receive only the complete final model", snapshots.size() == 2
		and snapshots[0] == data.to_dict() and snapshots[1] == data.to_dict()
		and data.get_cell_display(1, 2) == "3" and not data.is_blocking_signals())
	snapshots.clear()
	data.set_block_signals(true)
	data.from_csv("A\n9")
	check.call("CSV restores an already-blocked caller without publishing", data.is_blocking_signals()
		and snapshots.is_empty() and data.get_cell_value(1, 0) == 9)
	data.set_block_signals(false)
	data.from_csv("")
	check.call("empty CSV restores notifications and publishes its final empty model", not data.is_blocking_signals()
		and snapshots.size() == 2 and data.cells.is_empty())
	snapshots.clear()
	data.from_csv("A\n=1/0")
	check.call("formula errors leave notifications restored and final model visible", not data.is_blocking_signals()
		and snapshots.size() == 2 and not data.get_cell_if_exists(1, 0).error.is_empty()
		and snapshots[0] == data.to_dict() and snapshots[1] == data.to_dict())
	data.structure_changed.disconnect(record)
	data.data_changed.disconnect(record)

func _expected_model() -> Dictionary:
	var cells: Dictionary = {}
	var rows: Array[Dictionary] = []
	var columns: Array[Dictionary] = []
	for row: int in range(10000):
		rows.append({"height": 24.0, "is_header": row == 0})
		for column: int in range(20):
			var cell: Dictionary = {"value": "Column %d" % (column + 1), "type": 1} if row == 0 else {"value": float(row + column), "type": 2}
			if row == 1 and column == 2:
				cell = {"value": 5.0, "type": 4, "formula": "=SUM(B2:B3)"}
			cells["%d,%d" % [row, column]] = cell
	for column: int in range(26):
		columns.append({"width": 100.0, "header_name": "", "is_date_column": false})
	return {"version": 1, "row_count": 10000, "column_count": 26, "header_row_count": 1,
		"frozen_rows": 0, "frozen_cols": 0, "columns": columns, "rows": rows, "cells": cells, "charts": []}

func _check_clipboard(check: Callable, sheet: Control) -> void:
	# Real clipboard and input dispatch under Xvfb; external panel type is dynamic.
	var data = sheet.get("spreadsheet_data")
	var read := func() -> Array: return [data.get_cell_value(4, 6), data.get_cell_value(4, 7), data.get_cell_value(5, 6), data.get_cell_value(5, 7)]
	var before: Array = read.call()
	var expected: Array = ["Zoë", "Ω", "漢字", 3.25]
	var clipboard_before: String = DisplayServer.clipboard_get()
	var text: String = "Zoë\tΩ\r\n漢字\t3.25"
	DisplayServer.clipboard_set(text)
	check.call("H1 real clipboard retains the exact CRLF tab Unicode fixture", DisplayServer.clipboard_get() == text)
	sheet.set("current_row", 4)
	sheet.set("current_col", 6)
	sheet.get("cells_canvas").grab_focus()
	await sheet.get_tree().process_frame
	var key := InputEventKey.new()
	key.keycode = KEY_V
	key.ctrl_pressed = true
	key.pressed = true
	Input.parse_input_event(key)
	var release := InputEventKey.new()
	release.keycode = KEY_V
	release.ctrl_pressed = true
	Input.parse_input_event(release)
	await sheet.get_tree().process_frame
	check.call("H1 rendered native paste stores four exact cells without CR", read.call() == expected and sheet.call("get_undo_count") == 1)
	check.call("H1 clipboard undo restores all prior cells", sheet.call("undo") and read.call() == before)
	check.call("H1 clipboard redo restores exact Unicode values", sheet.call("redo") and read.call() == expected)
	DisplayServer.clipboard_set(clipboard_before)
