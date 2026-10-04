extends "res://../../minerva-plugins/docket/tests/gd/test_docket_lifecycle.gd"
## Initialized signed child oracle; inherited lifecycle still exercises real restart/write.
var password := ""
var values: Array[String] = []
var broker
var server
var vault_complete := false
var starts := 0
var child_ids: Array[int] = []
var held := false
var reached := false
var intercepted := 0

func _run() -> void:
	await process_frame
	var singleton = root.get_node("SingletonObject")
	if singleton.docket_manager != null:
		check("producer embedded handles closed", singleton.docket_manager.close_all().is_empty())
		singleton.docket_manager.free()
		singleton.docket_manager = null
	password = Crypto.new().generate_random_bytes(24).hex_encode()
	for i in 2:
		values.append(Crypto.new().generate_random_bytes(24).hex_encode())
	var data := OS.get_environment("MINERVA_PLUGIN_DATA_DIR")
	var producer_state := data.path_join("vault-producer")
	DirAccess.make_dir_recursive_absolute(producer_state)
	var prefs := producer_state.path_join("docket_prefs.json")
	var file := FileAccess.open(prefs, FileAccess.WRITE)
	file.store_string(JSON.stringify({"vault_password": password}))
	file.close()
	var producer = load("res://Scripts/Services/MCP/MCPServerConnection.gd").new()
	var binary := data.path_join("official/v0.3.0-rc.20-linux-amd64/docket.x86_64")
	producer.configure_stdio(binary, ["--quiet", "--", "--stdio", "--state-dir", producer_state,
		"--file", ProjectSettings.globalize_path("user://master.dct")])
	var connected: int = await producer.connect_to_server()
	check("signed standalone producer connected", connected == OK)
	if connected == OK:
		var created: Dictionary = await producer.call_tool("docket_secret_set", {"handle": "producer-entry", "value": values[0]}, 120.0)
		check("ordinary producer initialized vault", not created.has("error") and created.get("success", true))
		remember_children()
		check("producer PID measured", not child_ids.is_empty())
	producer.disconnect_from_server()
	check("producer prefs removed before consumer", DirAccess.remove_absolute(prefs) == OK and not FileAccess.file_exists(prefs))
	check("producer stopped before consumer", children_dead())
	if failed > 0:
		finish()
		return
	server = singleton.mcp_manager.minerva_server
	await super._run()

func start() -> bool:
	starts += 1
	var started: Dictionary = await pm.start_plugin("docket")
	if not check("initialized consumer start", started.get("ok", false)):
		return false
	var deadline := Time.get_ticks_msec() + 120000
	while host.state == "starting" and Time.get_ticks_msec() < deadline:
		await process_frame
	if not check("initialized host ready", host.state == "ready"):
		return false
	var authority = pm.get_panel_authority("docket")
	var descriptor: Dictionary = await authority.host_request("vault_challenge", {"path": host.master_path})
	check("initialized challenge identifies canonical opening", descriptor.get("result", {}).get("path", "") == host.master_path
		and descriptor.get("result", {}).get("open_generation", "") == host.master_project().get("open_generation", ""))
	remember_children()
	if starts == 1:
		var before := FileAccess.get_sha256(host.master_path)
		await host.unlock_vault(values[1])
		check("wrong password refused without retention", host._vault_session._password.is_empty()
			and host._vault_session._unlocked.is_empty() and FileAccess.get_sha256(host.master_path) == before)
		await host.unlock_vault(password)
		check("correct password retained privately", host._vault_session._password == password and not host._vault_session._unlocked.is_empty())
		broker = load("res://Scripts/Services/Plugins/CapabilityBroker.gd").new(pm.get_policy(), load("res://Scripts/Services/Plugins/PluginAuditLog.gd").new())
		for plugin in ["fixture-a", "fixture-b"]:
			for op in ["get", "set", "delete"]:
				pm.get_policy().grant_capability(plugin, "secrets:%s:entry" % op)
		await scenarios()
	else:
		check("restart private token rotates", authority._secret != previous_secret)
		var stale: Dictionary = await pm.get_connection("docket").request_method("docket/panel/vault_challenge", {"panel_secret": previous_secret, "path": host.master_path})
		check("previous challenge token refused", stale.get("rpc_error", {}).get("code", 0) == -32001)
		while host._vault_session._unlocked.is_empty() and Time.get_ticks_msec() < deadline:
			await process_frame
		check("automatic private unlock on restart", not host._vault_session._unlocked.is_empty())
		var recovered := await secret("fixture-a", "get")
		check("restart same master secret", recovered.get("result", {}).get("value") == values[0])
		vault_complete = true
	previous_secret = authority._secret
	return true

## Secret-bearing results stay in memory; labels never depend on payloads.
func secret(plugin: String, op: String, value: String = "", context: MCPExecutionContext = null) -> Dictionary:
	return await broker.dispatch(plugin, "secrets:%s:entry" % op, {"value": value} if op == "set" else {}, context)

func flush_master() -> void:
	var result: Dictionary = await pm.get_connection("docket").call_tool("docket_flush", {"project": host.master_project().name})
	check("master flushed", not result.has("error"))

func scenarios() -> void:
	var missing := await secret("fixture-a", "get")
	check("missing envelope preserved", missing.get("success", false) and missing.get("result", {}).get("value", "unexpected") == null and missing.result.get("exists") == false)
	for pair in [["fixture-a", values[0]], ["fixture-b", values[1]]]:
		var written := await secret(pair[0], "set", pair[1])
		var read := await secret(pair[0], "get")
		check("two plugin namespaces isolated", written.get("success", false) and read.get("result", {}).get("value") == pair[1] and read.result.get("handle") == "entry")
	var deleted := await secret("fixture-b", "delete")
	missing = await secret("fixture-b", "get")
	check("delete and missing envelope", deleted.get("success", false) and missing.get("result", {}).get("exists") == false)
	await flush_master()
	var before := FileAccess.get_sha256(host.master_path)
	pm.get_policy().revoke_capability("fixture-a", "secrets:set:entry")
	var denied := await secret("fixture-a", "set", values[1])
	check("plugin policy denies without mutation", not denied.get("success", false) and FileAccess.get_sha256(host.master_path) == before)
	pm.get_policy().grant_capability("fixture-a", "secrets:set:entry")
	var policy: Dictionary = await server.call_tool("minerva_docket_create", {"project": host.master_project().name, "type": "policy", "status": "active", "title": "Fixture deny secret set",
		"description": "---policy-rule---\n" + JSON.stringify({"effect": "block", "priority": 10, "tool_pattern": "^minerva_docket_secret_set$"}) + "\n---end-rule---"})
	check("durable server policy created", not str(policy.get("id", "")).is_empty())
	await flush_master()
	before = FileAccess.get_sha256(host.master_path)
	denied = await secret("fixture-a", "set", values[1])
	check("normal server policy denies without mutation", not denied.get("success", false) and denied.get("error_message", "").contains("Blocked by policy") and FileAccess.get_sha256(host.master_path) == before)
	var retired: Dictionary = await server.call_tool("minerva_docket_update", {"project": host.master_project().name, "id": policy.get("id", ""), "status": "draft"})
	check("fixture server policy retired", not retired.has("error"))
	await flush_master()
	before = FileAccess.get_sha256(host.master_path)
	var context := MCPExecutionContext.create("vault-fixture")
	context.cancel()
	var stopped := await secret("fixture-a", "set", values[1], context)
	check("stopped before send writes nothing", stopped.get("error_code", "") == "cancelled" and not context.lifetime.dispatched and FileAccess.get_sha256(host.master_path) == before)
	# Hold the actual host guard, then reopen the master on the actual child.
	pm.set_backend_tool_guard("docket", guarded)
	held = true
	var pending: Array = []
	(func(): pending.append(await secret("fixture-a", "set", values[1]))).call()
	await wait_reached()
	var conn = pm.get_connection("docket")
	var removed: Dictionary = await conn.call_tool("docket_project_remove", {"name": host.master_project().name})
	var added: Dictionary = await conn.call_tool("docket_project_add", {"path": host.master_path})
	check("real master reopened for stale binding", not removed.has("error") and not added.has("error"))
	held = false
	await wait_result(pending)
	check("stale opening no retarget", pending.size() == 1 and not pending[0].get("success", false) and pending[0].get("stale", false) and not pending[0].get("sent", true))
	# Hold a second call across an actual plugin process replacement.
	reached = false
	held = true
	pending.clear()
	(func(): pending.append(await secret("fixture-a", "set", values[1]))).call()
	await wait_reached()
	var stopped_process: Dictionary = await pm.stop_plugin("docket", true)
	var restarted: Dictionary = await pm.start_plugin("docket")
	check("actual stale process replaced", stopped_process.get("ok", false) and restarted.get("ok", false))
	var deadline := Time.get_ticks_msec() + 120000
	while (host.state == "starting" or host._vault_session._unlocked.is_empty()) and Time.get_ticks_msec() < deadline:
		await process_frame
	remember_children()
	held = false
	await wait_result(pending)
	check("stale process no retarget or replay", pending.size() == 1 and pending[0].get("stale", false) and not pending[0].get("sent", true))
	var unchanged := await secret("fixture-a", "get")
	check("stale calls left durable secret unchanged", unchanged.get("result", {}).get("value") == values[0])
	# Cancel synchronously at the real backend completion signal: sent truth
	# must survive the public lifetime envelope and never replay the write.
	context = MCPExecutionContext.create("vault-fixture")
	var cancel_on_reply := func(id: String, tool: String):
		if id == "docket" and tool == "docket_secret_set":
			context.cancel()
	pm.backend_tool_called.connect(cancel_on_reply)
	var unknown := await secret("fixture-a", "set", values[0], context)
	pm.backend_tool_called.disconnect(cancel_on_reply)
	check("sent cancellation unconfirmed and no replay", unknown.get("error_code", "") == "cancelled" and unknown.get("recovery", {}).get("outcome", "") == "unknown" and intercepted == 3)
	pm.set_backend_tool_guard("docket", host._guard)

func guarded(tool: String, arguments: Dictionary, caller: String, binding: Dictionary = {}) -> String:
	if tool == "docket_secret_set":
		intercepted += 1
		reached = true
		while held:
			await process_frame
	return await host._guard(tool, arguments, caller, binding)

func wait_reached() -> void:
	var deadline := Time.get_ticks_msec() + 10000
	while not reached and Time.get_ticks_msec() < deadline:
		await process_frame
	check("real guard hold reached", reached)

func wait_result(results: Array) -> void:
	var deadline := Time.get_ticks_msec() + 120000
	while results.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	check("bounded real reply received", results.size() == 1)

func remember_children() -> void:
	for name in DirAccess.get_directories_at("/proc"):
		if not name.is_valid_int():
			continue
		var cmd := proc_text("/proc/" + name + "/cmdline")
		if cmd.contains("docket.x86_64") or cmd.contains("docket-plugin.exe"):
			var pid := int(name)
			if not pid in child_ids:
				child_ids.append(pid)
				print("REAL_VAULT_PID:", pid)
			for needle in [password] + values:
				check("secret absent from child argv and environment", not cmd.contains(needle) and not proc_text("/proc/" + name + "/environ").contains(needle))

func proc_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	return file.get_buffer(65536).get_string_from_ascii() if file != null else ""

func children_dead() -> bool:
	return child_ids.all(func(pid: int): return not _alive(pid))

func scan_files(path: String) -> void:
	for name in DirAccess.get_files_at(path):
		var bytes := FileAccess.get_file_as_bytes(path.path_join(name))
		for needle in [password] + values:
			check("secret absent from retained consumer files", not bytes.get_string_from_ascii().contains(needle))
	for name in DirAccess.get_directories_at(path):
		scan_files(path.path_join(name))

func finish() -> void:
	if host != null:
		var session = host._vault_session
		host.free()
		host = null
		check("exit clears private password and unlock references", session._password.is_empty() and session._unlocked.is_empty())
	check("all producer GUI and launcher PIDs dead", children_dead())
	if not password.is_empty():
		scan_files(OS.get_user_data_dir())
		scan_files(OS.get_environment("MINERVA_PLUGIN_DATA_DIR"))
		var log := FileAccess.open("/tmp/job/Minerva/vault-process-evidence/real-lifecycle.log", FileAccess.READ)
		check("actual retained runtime log readable", log != null)
		var log_text := log.get_as_text() if log != null else ""
		for needle in [password] + values:
			check("secret absent from retained runtime log", not log_text.contains(needle))
		if broker != null:
			var audit := JSON.stringify(broker.audit_log.get_entries())
			for needle in [password] + values:
				check("secret absent from broker audit", not audit.contains(needle))
	password = ""
	values.clear()
	if vault_complete and lifecycle_complete and failed == 0:
		print("REAL_VAULT_SCENARIOS_COMPLETE")
	super.finish()
