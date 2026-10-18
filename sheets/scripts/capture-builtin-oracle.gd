extends RefCounted
## Historical test-data generator; never shipped or run by ordinary verification.
## Invoke only in the pinned pre-cutover host job while the builtin still exists.

func capture(pane: EditorPane, source: String, output: String) -> bool:
	var builtin_root := "res://Scripts/UI/Controls/SpreadsheetEditor/"
	if not FileAccess.file_exists(builtin_root + "SpreadsheetEditor.gd") or FileAccess.file_exists(output):
		push_error("Builtin oracle requires the original subtree and a new output file")
		return false
	var baseline: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://test/fixtures/spreadsheet_contract/baseline.minsheet"))
	var fixtures: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(source.path_join("tests/fixtures/tool-cases.json")))
	var names: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(source.path_join("scripts/legacy-tools.json")))
	names["Legacy contract"] = "contract editor"
	var normalizer: RefCounted = load(source.path_join("tests/helpers/tool_contract.gd")).new()
	var builtin: Editor = Editor.create(Editor.Type.SPREADSHEET, null, "Legacy contract", null, false)
	pane.Tabs.add_child(builtin)
	await pane.Tabs.get_tree().process_frame
	builtin.spreadsheet_editor.deserialize(baseline)
	# These host modules depend on autoloads, so load them after the host starts.
	var tools = load("res://Scripts/Services/MCP/Modules/MCPSpreadsheetTools.gd").new(null)
	var filters = load("res://Scripts/Services/MCP/Modules/MCPSpreadsheetFilterTools.gd").new(null)
	var ids: Dictionary = {}
	var records: Array[Dictionary] = []
	var raw_chart: String = ""
	for entry: Array in fixtures.parity:
		var legacy: String = entry[0]
		var arguments: Dictionary = entry[1].duplicate(true)
		arguments["editor_name"] = builtin.tab_title
		var previous: Dictionary = await (filters.handle(legacy, arguments) if legacy.begins_with("minerva_spreadsheet_autofilter_") else tools.handle(legacy, arguments))
		normalizer._chart_ids(builtin.spreadsheet_editor.charts, ids)
		records.append({"legacy": legacy, "arguments": entry[1],
			"result": normalizer._normalize(previous, ids, names),
			"model": normalizer._normalize(builtin.spreadsheet_editor.serialize(), ids, names)})
		if legacy == "minerva_get_chart_image":
			raw_chart = await builtin.spreadsheet_editor.chart_canvases[0].capture_to_base64_png(64, 32)
	builtin.free()
	var export_models: Dictionary = _exports(source, output.get_base_dir(), baseline)
	var reused_models: Dictionary = _imports(baseline)
	# B3 deliberately changed these contracts; their real runtime fixtures stay.
	# Historical parity covers 27 cases plus 10 explicitly excluded recipes.
	var exclusions: Array[Dictionary] = []
	for entry: Array in fixtures.staged:
		exclusions.append({"group": "staged", "legacy": entry[0], "arguments": entry[1],
			"reason": "B3 snapshot note replaces the old live link; runtime snapshot contract retained." if entry[0] == "minerva_link_spreadsheet_to_note" else "B3 explicit Nudge refusal replaces external export; runtime refusal contract retained."})
	for entry: Array in fixtures.creation:
		exclusions.append({"group": "creation", "legacy": entry[0], "arguments": entry[1],
			"reason": "B3 Go generic creation replaces builtin orchestration; real runtime creation contract retained."})
	var image := Image.new()
	if records.size() != fixtures.parity.size() or export_models.size() != 4 or reused_models.size() != 3 or image.load_png_from_buffer(Marshalls.base64_to_raw(raw_chart)) != OK or image.get_size() != Vector2i(64, 32):
		push_error("Builtin oracle capture failed its case/export/PNG preconditions")
		return false
	var file := FileAccess.open(output, FileAccess.WRITE)
	if file == null:
		push_error("Cannot write builtin oracle: %s" % output)
		return false
	file.store_string(JSON.stringify({"host_commit": OS.get_environment("SHEETS_CAPTURE_HOST_REVISION"),
		"plugins_commit": OS.get_environment("SHEETS_CAPTURE_PLUGINS_REVISION"),
		"catalog_sha256": FileAccess.get_sha256(source.path_join("scripts/frozen-tools.json")),
		"cases": records, "excluded_cases": exclusions, "export_models": export_models,
		"reused_import_models": reused_models, "raw_chart_png": raw_chart,
		"known_gap": "Valid builtin MCP chart export references missing _chart_canvas; invalid-index refusal and raw PNG captured."}, "\t") + "\n")
	var written: bool = file.get_error() == OK
	file.close()
	return written

func _imports(baseline: Dictionary) -> Dictionary:
	# Preserve the existing sequential reused-model witness, separately from
	# fresh export/reopen observations (CSV retains dimensions/freeze/filter).
	var data = load("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetData.gd").new()
	var files: Script = load("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetFileHandler.gd")
	data.load_from_dict(baseline)
	var models: Dictionary = {}
	for extension: String in ["csv", "tsv", "xlsx"]:
		if files.import_file("res://test/fixtures/spreadsheet_contract/sample." + extension, data) != OK:
			return {}
		models[extension] = JSON.parse_string(JSON.stringify(data.to_dict()))
	return models

func _exports(source: String, directory: String, baseline: Dictionary) -> Dictionary:
	# Dynamic runtime loads keep this historical generator out of shipped resources.
	var builtin_data = load("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetData.gd").new()
	var builtin_files: Script = load("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetFileHandler.gd")
	var plugin_data = load(source.path_join("ui/domain/SpreadsheetData.gd")).new()
	var plugin_files: Script = load(source.path_join("ui/domain/SpreadsheetFileHandler.gd"))
	var models: Dictionary = {}
	for extension: String in ["minsheet", "csv", "tsv", "xlsx"]:
		builtin_data.load_from_dict(baseline)
		plugin_data.load_from_dict(baseline)
		var old_path: String = directory.path_join("builtin." + extension)
		var new_path: String = directory.path_join("plugin." + extension)
		if builtin_files.export_file(old_path, builtin_data) != OK or plugin_files.export_file(new_path, plugin_data) != OK:
			return {}
		var old_reopened = load("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetData.gd").new()
		var new_reopened = load(source.path_join("ui/domain/SpreadsheetData.gd")).new()
		if builtin_files.import_file(old_path, old_reopened) != OK or plugin_files.import_file(new_path, new_reopened) != OK:
			return {}
		var old_model: Variant = JSON.parse_string(JSON.stringify(old_reopened.to_dict()))
		if old_model != JSON.parse_string(JSON.stringify(new_reopened.to_dict())):
			return {}
		models[extension] = old_model
	return models
