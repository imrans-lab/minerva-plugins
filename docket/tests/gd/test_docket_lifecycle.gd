extends SceneTree

var passed := 0
var failed := 0
var pm
var registry
var state: String

func _initialize() -> void:
	_run.call_deferred()

func check(label: String, condition: bool) -> bool:
	if condition:
		passed += 1
	else:
		failed += 1
		printerr("FAIL: ", label)
	return condition

func call_mapped(name: String, args: Dictionary) -> Dictionary:
	var result: Dictionary = await registry.handle_tool_call("minerva_" + name, args)
	check(name + " succeeded: " + str(result), result.get("success", false))
	return result

func start() -> bool:
	var result: Dictionary = await pm.start_plugin("docket")
	if not check("generic start: " + str(result), result.get("ok", false)):
		return false
	var conn = pm.get_connection("docket")
	if not check("real connection", conn != null):
		return false
	var tools: Array = await conn.list_tools()
	check("exported tools/list", not tools.is_empty())
	var mapped: Array = registry.get_plugin_tools("docket")
	check("all discovered tools mapped", mapped.size() == tools.size())
	# Separate negative oracle with the host's actual integrated Docket names.
	var builtin_names: Array = []
	var builtins = load("res://Scripts/Services/Docket/Tools/tool_registry.gd").new()
	for name in builtins._build_tools():
		builtin_names.append("minerva_" + str(name))
	var collision = load("res://Scripts/Services/Plugins/PluginToolRegistry.gd").new(pm)
	collision.set_builtin_tool_names(builtin_names)
	var refused: Dictionary = collision.register_plugin_tools("docket", mapped)
	check("built-in collision visibly refused: " + str(refused), not refused.get("ok", false) and str(refused.get("error", "")).contains("conflicts with a built-in Minerva tool"))
	check("collision registered nothing", collision.get_plugin_tools("docket").is_empty())
	for tool in mapped:
		check("single Docket prefix", str(tool.name).begins_with("minerva_docket_") and not str(tool.name).begins_with("minerva_docket_docket_"))
	return check("child GUI PID published", FileAccess.file_exists(state.get_base_dir().path_join("child.pid")))

func stop() -> void:
	var pid := int(FileAccess.get_file_as_string(state.get_base_dir().path_join("child.pid")))
	check("child was alive", pid > 0 and OS.is_process_running(pid))
	var before := Time.get_ticks_msec()
	var result: Dictionary = await pm.stop_plugin("docket", true)
	check("generic stop", result.get("ok", false))
	check("settled within host grace", Time.get_ticks_msec() - before < 10000)
	check("no surviving GUI", not OS.is_process_running(pid))
	check("launcher settled", not FileAccess.file_exists(state.get_base_dir().path_join("child.pid")))

func _run() -> void:
	await process_frame
	var plugin_dir := OS.get_environment("MINERVA_DOCKET_PLUGIN_DIR")
	var data_dir := OS.get_environment("MINERVA_PLUGIN_DATA_DIR")
	if not check("executor supplied absolute scratch data and source dirs", plugin_dir.is_absolute_path() and data_dir.is_absolute_path()):
		finish()
		return
	state = data_dir.path_join("official/state")
	var binary := plugin_dir.path_join("docket-plugin.exe")
	if not check("source-built launcher prerequisite", FileAccess.file_exists(binary)):
		finish()
		return
	var output: Array = []
	if not check("producer prepares manifest before bounded startup", OS.execute(binary, ["manifest", "lifecycle-manifest.json"], output, true) == 0):
		finish()
		return
	var manager_script: Script = load("res://Scripts/Services/Plugins/PluginManager.gd")
	pm = manager_script.new()
	root.add_child(pm)
	await process_frame
	registry = load("res://Scripts/Services/Plugins/PluginToolRegistry.gd").new(pm)
	root.get_node("SingletonObject").plugin_tool_registry = registry
	var installed: Dictionary = await pm.install_plugin(plugin_dir.path_join("lifecycle-manifest.json"), true)
	if not check("real manifest install", installed.get("ok", false)):
		finish()
		return
	var deadline := Time.get_ticks_msec() + 720000
	while pm.get_plugin_status("docket").get("state_name", "") == "BUILDING" and Time.get_ticks_msec() < deadline:
		await create_timer(0.1).timeout
	if await start():
		var path := state.path_join("lifecycle.dct")
		var project := await call_mapped("docket_project_add", {"path": path, "create": true})
		var name: String = str(project.get("name", ""))
		var title := "lifecycle-" + str(Time.get_ticks_usec())
		var created := await call_mapped("docket_create", {"project": name, "type": "chore", "title": title})
		var id: String = str(created.get("id", ""))
		check("durable item identity", not id.is_empty())
		await stop()
		if await start():
			# Restore is explicit; no change to the generic host autostart settings.
			await call_mapped("docket_project_add", {"path": path})
			var recovered := await call_mapped("docket_get", {"project": name, "id": id})
			check("write survived graceful restart", recovered.get("title", "") == title)
			check("disable autostart persists", pm.get_db().set_autostart("docket", false))
			await stop()
			check("disabled in generic DB", not pm.get_db().get_by_id("docket").autostart)
	finish()

func finish() -> void:
	if pm != null:
		pm.shutdown_all()
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(0 if failed == 0 else 1)
