extends SceneTree
## Only the exact public SDK is in this project. Host orchestration, tools,
## notes and project packaging are covered separately by full-host fixtures.
const SDK := preload("res://Scripts/Services/Plugins/MinervaPluginPanel.gd")
var passed: int = 0
var failed: int = 0
var fixtures: String = OS.get_environment("SHEETS_MODEL_FIXTURES")

func _init() -> void:
	process_frame.connect(run, CONNECT_ONE_SHOT)

func check(label: String, condition: bool) -> void:
	if condition:
		passed += 1
		print("PASS: " + label)
	else:
		failed += 1
		printerr("FAIL: " + label)

func json_value(value: Variant) -> Variant:
	return JSON.parse_string(JSON.stringify(value))

func oracle(filename: String) -> Variant:
	return JSON.parse_string(FileAccess.get_file_as_string(fixtures.path_join(filename)))

func import_document(panel: SDK, filename: String) -> void:
	panel.set_meta(SDK.DOCUMENT_ACTION_META, "import")
	panel._on_panel_load_request({"file_path": fixtures.path_join(filename)})
	panel.remove_meta(SDK.DOCUMENT_ACTION_META)

func run() -> void:
	create_timer(60.0).timeout.connect(func() -> void:
		printerr("FAIL: public SDK oracle stalled")
		quit(1))
	var scene: PackedScene = load(OS.get_environment("SHEETS_PLUGIN_ROOT").path_join("ui/SheetsPanel.tscn"))
	var panel: SDK = scene.instantiate()
	root.add_child(panel)
	await process_frame
	var expected: Dictionary = oracle("baseline.minsheet")
	for extension: String in ["minsheet", "csv", "tsv", "xlsx"]:
		panel.free()
		panel = scene.instantiate()
		root.add_child(panel)
		await process_frame
		var filename := "baseline.minsheet" if extension == "minsheet" else "sample." + extension
		var expected_name := filename if extension == "minsheet" else extension + "-expected.json"
		var before := FileAccess.get_file_as_bytes(fixtures.path_join(filename))
		import_document(panel, filename)
		check(extension + " complete model matches frozen B0", json_value(panel._on_panel_save_request()) == oracle(expected_name))
		check(extension + " original bytes unchanged", before == FileAccess.get_file_as_bytes(fixtures.path_join(filename)))
		var snapshot: Variant = json_value(panel._on_panel_save_request())
		panel._on_panel_load_request(snapshot)
		check(extension + " native model snapshot round-trips", json_value(panel._on_panel_save_request()) == snapshot)
		if extension == "xlsx":
			check("XFAIL B0 XLSX inline string remains absent", panel.get("sheet").spreadsheet_data.get_cell_display(1, 0).is_empty())
	panel.free()
	panel = scene.instantiate()
	root.add_child(panel)
	await process_frame
	import_document(panel, "baseline.minsheet")
	# Off-tree domain types are loaded dynamically; no host-private global types.
	var data = panel.get("sheet").spreadsheet_data
	data.recalculate_all()
	check("independent formula 2+3 evaluates to 5", data.get_cell_display(3, 1) == "5")
	check("filter preserves hidden cells", not data.autofilter.is_row_visible(2) and data.get_cell_display(2, 0) == "hide")
	data.autofilter.clear()
	check("clearing filter restores hidden rows", data.autofilter.is_row_visible(2))
	import_document(panel, "baseline.minsheet")
	var native_path := "user://model-roundtrip.minsheet"
	var files: Script = load(OS.get_environment("SHEETS_PLUGIN_ROOT").path_join("ui/domain/SpreadsheetFileHandler.gd"))
	check("native model exports", files.export_file(native_path, data) == OK)
	panel.set_meta(SDK.DOCUMENT_ACTION_META, "open")
	panel._on_panel_load_request({"file_path": ProjectSettings.globalize_path(native_path)})
	panel.remove_meta(SDK.DOCUMENT_ACTION_META)
	check("native file reopens complete model", json_value(panel._on_panel_save_request()) == expected)
	for invalid: String in ["malformed.minsheet", "not-an-object.minsheet"]:
		var before := FileAccess.get_file_as_bytes(fixtures.path_join(invalid))
		import_document(panel, invalid)
		var status: Label = panel.get_node("Status")
		check(invalid + " visibly refuses and preserves model/input", status.visible and not status.text.is_empty()
			and json_value(panel._on_panel_save_request()) == expected
			and before == FileAccess.get_file_as_bytes(fixtures.path_join(invalid)))
	var future_bytes := FileAccess.get_file_as_bytes(fixtures.path_join("future.minsheet"))
	import_document(panel, "future.minsheet")
	check("XFAIL B0 future version accepted and downgraded", json_value(panel._on_panel_save_request()) == expected)
	check("future input bytes unchanged", future_bytes == FileAccess.get_file_as_bytes(fixtures.path_join("future.minsheet")))
	var session: Dictionary = oracle("session.minproj")
	panel._on_panel_load_request(session.Editors[0].content)
	await process_frame
	check("mounted chart content round-trips complete model", json_value(panel._on_panel_save_request()) == session.Editors[0].content)
	check("XFAIL B0 native model still omits chart UI", panel.get("sheet").spreadsheet_data.to_dict().charts.is_empty())
	panel.free()
	print("=== Public SDK model: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed else 0)
