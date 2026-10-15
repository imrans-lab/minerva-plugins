extends SceneTree
## One combined-pin happy path, against the actual plugin and broker.

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	await process_frame
	var plugin_root := OS.get_environment("SMART_REMOTE_PLUGIN_ROOT")
	var definition_type = load("res://Scripts/Services/Plugins/PluginDefinition.gd")
	var definition = definition_type.from_manifest(plugin_root.path_join("manifest.json"))
	var manager = load("res://Scripts/Services/Plugins/PluginManager.gd").new()
	manager._db = load("res://Scripts/Services/Plugins/PluginDB.gd").new()
	definition.state = definition_type.State.RUNNING
	manager._db._plugins[definition.id] = definition
	var connection = load("res://Scripts/Services/MCP/MCPServerConnection.gd").new(definition.id)
	connection.configure_stdio("/usr/bin/env", ["DBUS_SYSTEM_BUS_ADDRESS=" + OS.get_environment("SMART_REMOTE_TEST_BUS"),
		OS.get_environment("SMART_REMOTE_PLUGIN_BIN"), "--data-dir", ProjectSettings.globalize_path("user://mouse-plugin"),
		"--bind", "127.0.0.1", "--port", "0", "--no-mdns"])
	if await connection.connect_to_server() != OK:
		quit(1)
		return
	manager._runtime[definition.id] = {"connection": connection}
	var policy = load("res://Scripts/Services/Plugins/PluginPolicy.gd").new()
	var capabilities = load("res://Scripts/Services/Plugins/CapabilityBroker.gd").new(policy)
	var broker = load("res://Scripts/Services/Plugins/PluginScenePanelBroker.gd").new(manager, policy, capabilities)
	# The unchanged panel loader uses plugin-owned scene files. Copy into this
	# disposable profile so relative scene scripts resolve normally.
	var directory := ProjectSettings.globalize_path("user://mouse-ui")
	DirAccess.make_dir_recursive_absolute(directory)
	for file: String in ["PairingPanel.tscn", "pairing_panel.gd"]:
		DirAccess.copy_absolute(plugin_root.path_join("ui").path_join(file), directory.path_join(file))
	var panel: Control = load("user://mouse-ui/PairingPanel.tscn").instantiate()
	root.add_child(panel)
	broker.register_panel(panel, definition.id, "mouse-panel", PackedStringArray(["minerva_smart_remote_pairing"]), "smart_remote_pairing")
	panel.call("_on_panel_loaded", {})
	var deadline := Time.get_ticks_msec() + 10000
	while panel.get_node("MouseStatus").text != "Mouse paired: yes" and Time.get_ticks_msec() < deadline:
		await process_frame
	var passed: bool = panel.get_node("MouseStatus").text == "Mouse paired: yes" and panel.get_node("MouseInstructions").text.contains("Smart Remote V2")
	panel.call("_on_panel_unload")
	broker.unregister_panel(definition.id, "mouse-panel")
	connection.disconnect_from_server()
	manager._runtime.clear()
	panel.free()
	manager.free()
	print("MOUSE_SETUP_PASS" if passed else "MOUSE_SETUP_FAIL")
	quit(0 if passed else 1)
