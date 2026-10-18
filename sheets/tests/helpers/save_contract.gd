extends RefCounted
const ValueDomain := preload("value_domain.gd")
const Atomic := preload("res://Scripts/Services/Plugins/AtomicFile.gd")

# Godot's real error stream proves the failure is logged as well as displayed.
class SaveErrors extends Logger:
	var messages: Array[String] = []
	var mutex := Mutex.new()
	func _log_error(_function: String, _file: String, _line: int, code: String,
			rationale: String, _notify: bool, _type: int, _backtraces: Array[ScriptBacktrace]) -> void:
		mutex.lock()
		messages.append(code + rationale)
		mutex.unlock()
	func contains(message: String) -> bool:
		mutex.lock()
		var found: bool = messages.has(message)
		mutex.unlock()
		return found

# Completion is observed independently while the real FileDialog is driven.
func _prompt(editor: Editor, result: Dictionary) -> void:
	result["saved"] = await editor.prompt_close(true)
	result["done"] = true

func run(check: Callable, pane: EditorPane, host: Node) -> void:
	var tree: SceneTree = pane.Tabs.get_tree()
	var directory := ProjectSettings.globalize_path("user://native-save-contract")
	DirAccess.make_dir_recursive_absolute(directory)
	var manager: PluginManager = host.get("plugin_manager")
	var definition: PluginDefinition = manager.get_db().get_by_id("sheets")
	var original_panels: Array[Dictionary] = definition.ui_panels.duplicate(true)
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(
		ProjectSettings.globalize_path("res://../../minerva-plugins/sheets/manifest.json")))
	manifest.ui.panels[0]["native_save_extensions"] = [".minsheet"]
	var parsed: PluginDefinition = PluginDefinition.from_dict(manifest)
	check.call("test manifest parses native subset for a non-live-reload provider", parsed != null and "live_reload" not in parsed.capabilities)
	definition.ui_panels.assign(parsed.ui_panels)
	var errors := SaveErrors.new()
	OS.add_logger(errors)
	for extension: String in ["csv", "tsv", "xlsx"]:
		var source := ProjectSettings.globalize_path("res://test/fixtures/spreadsheet_contract/sample." + extension)
		var source_bytes := FileAccess.get_file_as_bytes(source)
		var opened: Dictionary = host.call("open_file_at_path", source)
		var editor: Editor = pane.Tabs.get_current_tab_control()
		check.call(extension + " save fixture opens real imported panel", opened.get("ok") == true and editor.plugin_scene_root != null)
		check.call(extension + " normal DB mount applies declared native formats", editor.plugin_native_save_extensions == [".minsheet"])
		var sheet: Node = editor.plugin_scene_root.get("sheet")
		sheet.call("set_cell_value_with_history", 0, 0, "save witness " + extension)
		var model: Dictionary = PluginScenePanelHost.invoke_save(editor.plugin_scene_root, {})
		var dialog: FileDialog = editor.get_node("FileDialog")
		dialog.use_native_dialog = false
		var canceled: Dictionary = {}
		_prompt(editor, canceled)
		await tree.process_frame
		check.call(extension + " Save opens native-only Save As", dialog.visible and dialog.filters == PackedStringArray(["*.minsheet ; Plugin file"])
			and dialog.current_file.ends_with(".minsheet"))
		check.call(extension + " overlapping Save refuses without closing first prompt", not await editor.prompt_close(true) and dialog.visible)
		dialog.get_cancel_button().pressed.emit()
		await tree.process_frame
		await tree.process_frame
		check.call(extension + " cancel preserves source bytes, binding, dirty state and full model", canceled.get("done") == true and canceled.get("saved") == false
			and FileAccess.get_file_as_bytes(source) == source_bytes and editor.file == source and editor._plugin_scene_modified
			and ValueDomain.equal_json(PluginScenePanelHost.invoke_save(editor.plugin_scene_root, {}), model))
		var selected: Dictionary = {}
		_prompt(editor, selected)
		await tree.process_frame
		var destination := directory.path_join("saved-" + extension + ".minsheet")
		dialog.current_path = destination
		dialog.get_ok_button().pressed.emit()
		await tree.process_frame
		await tree.process_frame
		check.call(extension + " native Save As persists full model and retains source", selected.get("done") == true and selected.get("saved") == true
			and editor.file == destination and not editor._plugin_scene_modified and FileAccess.get_file_as_bytes(source) == source_bytes
			and ValueDomain.equal_json(JSON.parse_string(FileAccess.get_file_as_string(destination)), model))
		sheet.call("set_cell_value_with_history", 0, 1, "in-place")
		var updated: Dictionary = PluginScenePanelHost.invoke_save(editor.plugin_scene_root, {})
		check.call(extension + " native Save writes in place without prompt", await editor.prompt_close(true) and not dialog.visible
			and ValueDomain.equal_json(JSON.parse_string(FileAccess.get_file_as_string(destination)), updated))
		# A missing parent refuses before publication; the real Editor keeps its state.
		sheet.call("set_cell_value_with_history", 1, 0, "still dirty")
		check.call(extension + " failed write retains prior file and dirty state", not await editor.save_file_to_disc(directory.path_join("absent/out.minsheet"))
			and editor.file == destination and editor._plugin_scene_modified and ValueDomain.equal_json(JSON.parse_string(FileAccess.get_file_as_string(destination)), updated))
		var failure: AcceptDialog = editor.get_node("SaveFailure")
		var failure_text: RichTextLabel = failure.get_node("Message")
		check.call(extension + " save failure is visible and copyable", failure.visible and failure_text.selection_enabled and not failure_text.text.is_empty())
		check.call(extension + " displayed write failure is in the real error log", errors.contains(failure_text.text))
		failure.hide()
		var blocked_target := directory.path_join("blocked-" + extension + ".minsheet")
		DirAccess.make_dir_recursive_absolute(blocked_target)
		Atomic.write(blocked_target.path_join("marker"), "original")
		check.call(extension + " failed replacement retains binding, dirty state and destination", not await editor.save_file_to_disc(blocked_target)
			and editor.file == destination and editor._plugin_scene_modified and FileAccess.get_file_as_string(blocked_target.path_join("marker")) == "original")
		failure.hide()
		editor.free()
	OS.remove_logger(errors)
	manifest.ui.panels[0].erase("native_save_extensions")
	parsed = PluginDefinition.from_dict(manifest)
	definition.ui_panels.assign(parsed.ui_panels)
	# Existing undeclared panels keep saving to their own imported extension.
	var legacy: Editor = pane.add_plugin_scene_editor("sheets", "sheets_panel", "", "Undeclared", "")
	var legacy_path := directory.path_join("legacy.csv")
	check.call("undeclared native formats retain save-in-place", await legacy.save_file_to_disc(legacy_path)
		and await legacy.prompt_close(true) and legacy.file == legacy_path and not legacy.get_node("FileDialog").visible)
	check.call("ordinary undeclared mount initializes this panel's own claims", legacy.plugin_native_save_extensions == [".minsheet", ".csv", ".tsv", ".xlsx"])
	# Reparse a CAD/PCB-style panel through the same DB and normal mount route.
	manifest.ui.panels[0].erase("native_save_extensions")
	manifest.ui.panels[0]["file_extensions"] = [".cad", ".pcb"]
	parsed = PluginDefinition.from_dict(manifest)
	definition.ui_panels.assign(parsed.ui_panels)
	legacy.free()
	legacy = pane.add_plugin_scene_editor("sheets", "sheets_panel", "", "Scoped claims", "")
	legacy.file = ""
	var scoped: Dictionary = {}
	_prompt(legacy, scoped)
	await tree.process_frame
	var scoped_dialog: FileDialog = legacy.get_node("FileDialog")
	check.call("filters use this panel's CAD/PCB claims only", scoped_dialog.filters == PackedStringArray(["*.cad ; Plugin file", "*.pcb ; Plugin file"]))
	var closed_destination := directory.path_join("closed.cad")
	scoped_dialog.current_path = closed_destination
	legacy.free()
	await tree.process_frame
	check.call("editor closed during prompt writes no file", not FileAccess.file_exists(closed_destination))
	definition.ui_panels.assign(original_panels)
	var frame_close: Editor = pane.add_plugin_scene_editor("sheets", "sheets_panel", "", "Frame close", "")
	var frame_result: Dictionary = {}
	_prompt(frame_close, frame_result)
	await tree.process_frame
	var frame_dialog: FileDialog = frame_close.get_node("FileDialog")
	# Cancel hides the dialog, resuming prompt_close into its one-frame await.
	frame_dialog.get_cancel_button().pressed.emit()
	frame_close.free()
	await tree.process_frame
	var fresh: Editor = pane.add_plugin_scene_editor("sheets", "sheets_panel", "", "Fresh save", "")
	var fresh_path := directory.path_join("fresh.minsheet")
	check.call("close during result frame does not prevent a fresh editor Save", await fresh.save_file_to_disc(fresh_path)
		and await fresh.prompt_close(true) and FileAccess.file_exists(fresh_path) and not fresh._plugin_save_prompt_busy)
	fresh.free()
	var bytes_path := directory.path_join("opaque.bin")
	var original := PackedByteArray([0, 255, 1, 2])
	check.call("atomic bytes write preserves exact binary payload", Atomic.write_bytes(bytes_path, original) and FileAccess.get_file_as_bytes(bytes_path) == original)
	# A nonempty destination directory allows prepare but forces replace to fail.
	var blocked := directory.path_join("blocked")
	DirAccess.make_dir_recursive_absolute(blocked)
	var marker := blocked.path_join("marker")
	Atomic.write(marker, "original")
	check.call("failed atomic replacement leaves destination untouched", not Atomic.write_bytes(blocked, original)
		and DirAccess.dir_exists_absolute(blocked) and FileAccess.get_file_as_string(marker) == "original"
		and FileAccess.get_file_as_bytes(blocked + ".tmp") == original)
