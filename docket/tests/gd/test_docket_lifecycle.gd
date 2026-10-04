extends SceneTree

var passed := 0
var failed := 0
var pm
var registry
var host
var previous_secret := ""
var master_digest := ""
var lifecycle_complete := false
var state: String
var exec_gate
var approvals := 0
var busy_results: Array[Dictionary] = []

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
	if not check("child GUI PID published", FileAccess.file_exists(state.get_base_dir().path_join("child.pid"))):
		return false
	var deadline := Time.get_ticks_msec() + 120000
	while host.state == "starting" and Time.get_ticks_msec() < deadline:
		await process_frame
	if not check("real DocketHost prepared", host.state == "ready"):
		return false
	check("canonical master bootstrapped", host.master_path == ProjectSettings.globalize_path(host.MASTER_USER) and not host.master_project().is_empty())
	check("bootstrap report identifies master", host.master_report.get("project", {}).get("path", "") == host.master_path)
	var authority = pm.get_panel_authority("docket")
	if not check("production per-child authority", authority != null and authority._secret.length() == 64):
		return false
	# Private fixtures inspect only fixed fields; never stringify requests/results.
	var accepted: Dictionary = await authority.host_request("status", {})
	var pid := int(FileAccess.get_file_as_string(state.get_base_dir().path_join("child.pid")))
	check("private authority accepted by actual child", accepted.get("result", {}).get("protocol", "") == "docket_panel_v1" and accepted.get("result", {}).get("pid", 0) == pid)
	var missing: Dictionary = await conn.request_method("docket/panel/status", {})
	check("missing token refused", missing.get("rpc_error", {}).get("code", 0) == -32001)
	if not previous_secret.is_empty():
		check("restart rotates child token", authority._secret != previous_secret)
		var stale: Dictionary = await conn.request_method("docket/panel/status", {"panel_secret": previous_secret})
		check("previous child token refused", stale.get("rpc_error", {}).get("code", 0) == -32001)
		check("canonical master survives restart", FileAccess.get_sha256(host.master_path) == master_digest)
	previous_secret = authority._secret
	master_digest = FileAccess.get_sha256(host.master_path)
	check("master vault metadata absent before challenge", vault_metadata_absent())
	var challenge: Dictionary = await authority.host_request("vault_challenge", {"path": host.master_path})
	check("host authority surfaces vault refusal", challenge.get("error_code", "") == "backend_error" and challenge.get("error_message", "") == "Vault request refused")
	# rc20 uses this same refusal for invalid parameters and an absent vault.
	var raw_challenge: Dictionary = await conn.request_method("docket/panel/vault_challenge", {"panel_secret": authority._secret, "path": host.master_path})
	var rpc_error: Dictionary = raw_challenge.get("rpc_error", {})
	check("actual child vault refusal", rpc_error.size() == 2 and rpc_error.has_all(["code", "message"]) and rpc_error.code == -32602 and rpc_error.message == "Vault request refused")
	check("vault challenge leaves master unchanged", FileAccess.get_sha256(host.master_path) == master_digest)
	check("master vault remains uninitialized without password", vault_metadata_absent() and host._vault_session._password.is_empty())
	print("REAL_CHILD_PID:", pid)
	return true

func acquisition_pins(pins: Dictionary) -> Dictionary:
	# Go marshals exported names, apart from the explicitly tagged key digest.
	var expected := {"key_sha256": pins.key_sha256, "Platforms": {}}
	for fields in [["tag", "Tag"], ["source", "Source"], ["url", "URL"], ["primary", "Primary"], ["signing", "Signing"]]:
		expected[fields[1]] = pins[fields[0]]
	for platform in pins.platforms:
		var pin: Dictionary = pins.platforms[platform]
		expected.Platforms[platform] = {"Asset": pin.asset, "SHA256": pin.sha256, "Entrypoint": pin.entrypoint}
	return expected

func vault_metadata_absent() -> bool:
	var meta = JSON.parse_string(FileAccess.get_file_as_string(host.master_path).get_slice("\n", 0))
	if not meta is Dictionary or meta.get("_type", "") != "meta":
		return false
	for key in meta:
		if str(key).begins_with("vault_"):
			return false
	return true

func stop() -> void:
	var pid := int(FileAccess.get_file_as_string(state.get_base_dir().path_join("child.pid")))
	check("child was alive", pid > 0 and _alive(pid))
	var before := Time.get_ticks_msec()
	var result: Dictionary = await pm.stop_plugin("docket", true)
	check("generic stop", result.get("ok", false))
	check("settled within host grace", Time.get_ticks_msec() - before < 10000)
	check("no surviving GUI", not _alive(pid))
	check("launcher settled", not FileAccess.file_exists(state.get_base_dir().path_join("child.pid")))

func create_large(project: String, title: String, article: String) -> void:
	busy_results.append(await call_mapped("docket_create", {"project": project, "type": "kb", "title": title, "article": article}))

func approve_prepare() -> void:
	var request: Dictionary = exec_gate._current_request
	var step: Dictionary = request.step
	var expected: bool = request.step_index == 1 and step.get("argv", []) == ["./docket-plugin.exe", "prepare"]
	if check("real dialog requests only declared prepare", expected):
		approvals += 1
		exec_gate.confirmed.emit()
	else:
		exec_gate.canceled.emit()
	exec_gate.hide()

func install_fixture(manifest_path: String) -> Dictionary:
	return await pm.install_plugin(manifest_path, true)

func expected_prepare_approvals() -> int:
	return 1

func lifecycle_project_path() -> String:
	return state.path_join("lifecycle.dct")

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
	# Release every embedded file handle before handing the same master to Docket.
	var singleton = root.get_node("SingletonObject")
	var embedded = singleton.docket_manager
	if embedded != null:
		check("embedded owner closed without save refusal", embedded.close_all().is_empty())
		singleton.docket_manager = null
		embedded.free()
	check("embedded owner removed", singleton.docket_manager == null)
	if singleton.docket_host != null:
		singleton.docket_host.free()
	var manager_script: Script = load("res://Scripts/Services/Plugins/PluginManager.gd")
	pm = manager_script.new()
	root.add_child(pm)
	await process_frame
	# Match SingletonObject policy wiring and PluginManagerPanel's real dialog seam.
	pm._policy_ref = load("res://Scripts/Services/Plugins/PluginPolicy.gd").new(pm.get_db())
	exec_gate = load("res://Scripts/UI/Controls/PluginManagerPanel/PluginExecApprovalGate.gd").new()
	root.add_child(exec_gate)
	exec_gate.about_to_popup.connect(func(): approve_prepare.call_deferred())
	pm.exec_approver = exec_gate.approve
	registry = load("res://Scripts/Services/Plugins/PluginToolRegistry.gd").new(pm, pm.get_policy())
	root.get_node("SingletonObject").plugin_tool_registry = registry
	var installed: Dictionary = await install_fixture(plugin_dir.path_join("lifecycle-manifest.json"))
	if not check("real manifest install", installed.get("ok", false)):
		finish()
		return
	var definition = pm.get_db().get_by_id("docket")
	check("installed production authority declaration", definition.panel_authority == PluginDefinition.PANEL_AUTHORITY_V1)
	check("host mode explicitly declared", definition.args == ["--host-authority"])
	host = load("res://Scripts/Services/DocketHost/DocketHost.gd").new()
	root.add_child(host)
	singleton.docket_host = host
	host.start(pm, false)
	var pins = JSON.parse_string(FileAccess.get_file_as_string(plugin_dir.path_join("release.lock.json")))
	var receipt = JSON.parse_string(FileAccess.get_file_as_string(state.get_base_dir().path_join("v0.3.0-rc.20-linux-amd64/acquisition.lock.json")))
	check("actual signed payload receipt matches source pins", receipt is Dictionary and receipt == acquisition_pins(pins))
	print("REAL_PAYLOAD:", pins.tag, " source=", pins.source, " asset_sha256=", pins.platforms["linux-amd64"].sha256)
	var deadline := Time.get_ticks_msec() + 720000
	while pm.get_plugin_status("docket").get("state_name", "") == "BUILDING" and Time.get_ticks_msec() < deadline:
		await create_timer(0.1).timeout
	check("prepare approval count matches fixture ownership", approvals == expected_prepare_approvals())
	if await start():
		var path := lifecycle_project_path()
		var project := await call_mapped("docket_project_add", {"path": path, "create": true})
		var name: String = str(project.get("name", ""))
		var title := "lifecycle-" + str(Time.get_ticks_usec())
		var article := "busy request\n".repeat(160000)
		# Queue another large request while the child is processing the first write.
		create_large(name, title + "-busy", article)
		var created := await call_mapped("docket_create", {"project": name, "type": "kb", "title": title, "article": article})
		while busy_results.is_empty():
			await process_frame
		check("concurrent large request succeeded", not str(busy_results[0].get("id", "")).is_empty())
		var id: String = str(created.get("id", ""))
		check("durable item identity", not id.is_empty())
		await stop()
		if await start():
			# DocketHost restores the prior session before becoming ready.
			var listed := await call_mapped("docket_project_list", {})
			var restored := false
			for entry in listed.get("projects", []):
				if entry.get("name", "") == name and str(entry.get("path", "")).simplify_path() == path.simplify_path():
					restored = true
			check("expected lifecycle project restored", restored)
			var recovered := await call_mapped("docket_get", {"project": name, "id": id})
			check("large write survived graceful restart", recovered.get("title", "") == title and recovered.get("article", "") == article)
			check("disable autostart persists", pm.get_db().set_autostart("docket", false))
			await stop()
			check("disabled in generic DB", not pm.get_db().get_by_id("docket").autostart)
			lifecycle_complete = true
	finish()

func finish() -> void:
	previous_secret = ""
	if lifecycle_complete and failed == 0:
		print("REAL_HOST_AUTHORITY_COMPLETE")
	if pm != null:
		pm.shutdown_all()
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(0 if failed == 0 else 1)


## OS.is_process_running only reports this process's own children; the GUI is the
## launcher's child, so ask the kernel directly (the oracle runs on Linux).
func _alive(pid: int) -> bool:
	return DirAccess.dir_exists_absolute("/proc/%d" % pid)
