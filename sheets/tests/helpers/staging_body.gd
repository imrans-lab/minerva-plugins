extends Node
signal completed(code: int)
var passed: int = 0
var failed: int = 0

func check(label: String, condition: bool) -> void:
	if condition:
		passed += 1
		print("PASS: " + label)
	else:
		failed += 1
		printerr("FAIL: " + label)

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	await get_tree().create_timer(3.0).timeout
	# The host autoload has no global class; runtime loading is required by --script.
	var host = get_tree().root.get_node("SingletonObject")
	var ui := preload("res://test/helpers/chat_host_render_fixture.gd").new()
	ui.install(host)
	var old: Array = [host.plugin_manager, host.plugin_scene_panel_broker, host.editor_pane,
		host.plugin_editor_registry, host.creatable_item_registry, host.plugin_tool_registry]
	var manager := PluginManager.new()
	manager._db = PluginDB.new()
	var database: PluginDB = manager.get_db()
	var policy := PluginPolicy.new(database, null, false)
	var registry := PluginToolRegistry.new(manager, policy)
	manager.configure_dependency_tools(registry)
	var broker := PluginScenePanelBroker.new(manager, policy, CapabilityBroker.new(policy))
	registry.scene_panel_broker = broker
	host.plugin_manager = manager
	host.plugin_tool_registry = registry
	host.plugin_scene_panel_broker = broker
	get_tree().root.add_child(manager)
	manager.set_process(false)
	var pane := EditorPane.new()
	var tabs := TabContainer.new()
	get_tree().root.add_child(tabs)
	pane.Tabs = tabs
	pane.buffer_control_editor = Control.new()
	host.editor_pane = pane
	host.creatable_item_registry = CreatableItemRegistry.new()
	host.plugin_editor_registry = PluginEditorRegistry.new()
	host._wire_plugin_editor_extensions(manager)
	var source := ProjectSettings.globalize_path("res://../../minerva-plugins/sheets")
	var definition: PluginDefinition = database.install(source.path_join("manifest.json"))
	check("actual Sheets source manifest installs", definition != null)
	if definition != null:
		var started: Dictionary = await manager.start_plugin("sheets")
		check("actual Sheets backend initializes", started.get("ok", false) == true)
		check("Sheets backend reports running", manager.get_plugin_status("sheets").get("running", false) == true)
		host._register_plugin_editor_items("sheets")
		var item: CreatableItemRegistry.CreatableItem = host.creatable_item_registry.get_item("new_minsheet")
		check("new_minsheet is registered with a callback", item != null and item.create_callback.is_valid())
		if item != null:
			item.create_callback.call()
			await get_tree().process_frame
		check("source editor item creates exactly one tab", tabs.get_tab_count() == 1)
		if tabs.get_tab_count() == 1:
			var editor: Editor = tabs.get_child(0)
			var panel: Node = editor.plugin_scene_root
			check("source panel mounted once through the create handoff", panel != null and panel.get("create_count") == 1)
			check("raw PNG icon loads outside the import database", panel != null and panel.get("icon_loaded") == true)
		definition.class_names.assign(["WrongPrefix_Panel"])
		check("wrong class prefix is refused explicitly", definition.validate_class_names({}, []).get("error") == "class_name_bad_prefix")
		var packed: PackedScene = load(source.path_join("ui/SheetsPanel.tscn"))
		check("unlisted scene script is refused", not PluginScenePanelHost._audit_packed_scene(packed, PackedStringArray()))
		manager.stop_plugin("sheets")
	tabs.free()
	pane.buffer_control_editor.free()
	pane.free()
	host.plugin_manager = old[0]
	host.plugin_scene_panel_broker = old[1]
	host.editor_pane = old[2]
	host.plugin_editor_registry = old[3]
	host.creatable_item_registry = old[4]
	host.plugin_tool_registry = old[5]
	manager.free()
	ui.restore()
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	completed.emit(1 if failed else 0)
