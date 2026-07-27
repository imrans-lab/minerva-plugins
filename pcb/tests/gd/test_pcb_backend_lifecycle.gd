extends SceneTree
## Backend lifecycle tests: lazy start-on-demand + process-identity
## verification (docket bug 019f6c1e0399, "pcb panel works while backend
## subprocess is stopped").
##
## DIAGNOSIS this suite locks in: godot_scene panels are host-executed
## independent of the plugin's own Go backend subprocess
## (PluginScenePanelBroker mounts the panel regardless of PluginDefinition
## state) — so the PCB editor opens and edits fine while the backend is
## STOPPED, and only the first IPC round-trip (export/route/load) discovers
## it via a raw plugin_not_running reply. manifest.json's autostart:false is
## therefore a SYMPTOM, not the bug — a blanket autostart:true would spend a
## Python worker subprocess on every pcb-plugin install regardless of whether
## a session ever touches routing/export/load, so PCBPanel.gd instead starts
## the backend LAZILY, on the specific IPC call that needs it
## (_request_with_backend_ensure, wired into route_board / load_board_from_yaml
## / _on_export_yaml_pressed).
##
## The lazy-start bridge: no host_capability exists on CapabilityBroker's
## named dispatch table for "start my own plugin" — the only lever reachable
## from a scene panel is capability:mcp.proxy:<tool>, forwarded verbatim to
## MinervaMCPServer (same pattern the drive/movie-gen/3d-gen plugins already
## use to proxy their own host tools). manifest.json declares
## "mcp.proxy:minerva_plugin_start" + the capability channel accordingly.
##
## The identity check: minerva_plugin_start's own {ok:true} reflects
## PluginManager's state flag flipping to RUNNING — NOT proof this panel can
## actually reach and correctly identify the resulting process over IPC. A
## stale backend and a freshly-started one both answer a bare liveness check
## happily. So after every (re)start, PCBPanel.gd round-trips a
## locally-generated NONCE through the backend's "ping" tool
## (internal/tools/ping.go — an in-process Go tool, answers directly, no
## worker hop) and requires ok==true AND plugin=="pcb" AND echo==the exact
## nonce this call sent. NOTE ON THE BRIEF'S OWN CAVEAT: "ping" is sometimes
## described as a worker-internal JSON-RPC method that never reaches Minerva's
## MCP surface — that description is accurate for
## worker/pcb_worker/methods.py's "ping" (Go<->Python bridge only), but a
## DIFFERENT "ping" (internal/tools/ping.go) is registered as a real, in-process
## Go-level MCP ToolSpec and IS discoverable via tools/list once the backend is
## RUNNING. Section C below proves this empirically against the real binary
## (test_pcb_plugin_smoke.gd's Section B already independently confirms
## "ping present" in conn.list_tools()).
##
## Section A drives PCBPanel.gd's new helper methods directly
## (_reply_says_plugin_not_running / _verify_backend_identity /
## _start_and_verify_backend / _request_with_backend_ensure) against a
## SCRIPTED fake broker — the same "stub the broker/worker boundary headless"
## convention every other pcb IPC test in this directory already uses (see
## test_pcb_apply_route_hints.gd's own doc header: "the router WORKER is
## unreachable headless... STUBBED at the boundary"). This is what makes the
## FULL/HALF mutation proof possible: the fake broker's replies are exact and
## reproducible, so a weakened identity check or a disabled start mechanism
## changes the outcome deterministically.
##
## Section B asserts manifest.json actually authorizes what the GDScript
## relies on (the capability grant + the two declared channels) — the class
## of bug where the logic is right but the manifest wiring silently isn't.
##
## Section C is a REAL subprocess round-trip (extends test_pcb_plugin_smoke.gd's
## Section B pattern: fresh PluginManager, install+start the actual pcb-plugin
## Go binary, call the raw "ping" tool) proving the identity primitive itself
## works against production code, not just the scripted stand-in. Skipped
## gracefully if the Go binary isn't built on this host (same contract as
## every other Section-B-shaped test in this suite).
##
## Off-tree: PCBPanel.gd lives outside res://, loaded via load() by path; every
## panel/ipc reference here is duck-typed (Variant), never typed AS a plugin
## class, matching every other test in this directory.
##
## Run: godot --headless --path src --script test/test_pcb_backend_lifecycle.gd
## Or via the whole-suite runner: pcb/scripts/run-gd-tests.sh <minerva-checkout>

const PANEL_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"
const MANIFEST_PATH := "res://../../minerva-plugins/pcb/manifest.json"
const PLUGIN_DEFINITION_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginDefinition.gd"
const PLUGIN_MANAGER_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginManager.gd"

const PCB_PLUGIN_DIR_REL := "/github/minerva-plugins/pcb"
const PCB_BINARY_REL := "/pcb-plugin"
const PCB_MANIFEST_REL := "/manifest.json"

const S_RUNNING := 2

const START_CHANNEL := "capability:mcp.proxy:minerva_plugin_start"
const PING_CHANNEL := "ping"

var _pass_count: int = 0
var _fail_count: int = 0


## Records every request the panel emits and answers it (deferred, so the
## awaiting coroutine has already registered with MinervaIPC by the time the
## reply lands — mirrors the real broker's own async dispatch timing).
## handlers[channel] is a Callable(Dictionary payload) -> Dictionary; a
## channel with no registered handler answers with a loud, obviously-wrong
## "unscripted_channel" failure rather than hanging until timeout.
class FakeBroker:
	extends RefCounted
	var ipc: MinervaIPC
	var calls: Array = []
	var handlers: Dictionary = {}

	func _init(p_ipc: MinervaIPC) -> void:
		ipc = p_ipc

	func on_request(channel: String, payload: Dictionary, reply_id: String) -> void:
		calls.append({"channel": channel, "payload": payload.duplicate(true)})
		var reply: Dictionary
		if handlers.has(channel):
			reply = (handlers[channel] as Callable).call(payload)
		else:
			reply = {
				"success": false,
				"error_code": "unscripted_channel",
				"error_message": "FakeBroker has no scripted handler for '%s'" % channel,
			}
		ipc.call_deferred("_reply", reply_id, reply)

	func call_count(channel: String) -> int:
		var n := 0
		for c in calls:
			if str((c as Dictionary).get("channel", "")) == channel:
				n += 1
		return n

	func was_called(channel: String) -> bool:
		return call_count(channel) > 0


## Builds the REAL wire shape a scene panel sees for a successful "ping" call
## — confirmed against the actual Go binary in Section C, not assumed: every
## backend tool call is wrapped TWICE before it reaches the panel. (1) Go's
## main.go dispatch() wraps every tool's raw handler result as
## {ok:true, result:<raw>} before it leaves the process (main.go:347-349).
## (2) PluginScenePanelBroker._dispatch_to_plugin_backend sees that dict has
## an "ok" key and wraps it AGAIN via PluginErrors.backend_success, so the
## panel's ipc.await_reply() sees {success:true, result:{ok:true,
## result:<raw ping body>}}. body is HandlePing's own {ok,plugin,version,echo}.
func _ping_reply(body: Dictionary) -> Dictionary:
	return {"success": true, "result": {"ok": true, "result": body}}


func _init() -> void:
	print("=== PCB Backend Lifecycle Tests (bug 019f6c1e0399) ===\n")
	await process_frame

	print("########## SECTION A — lazy-start + identity primitives (scripted broker) ##########\n")
	_test_reply_says_plugin_not_running()
	await _test_verify_identity_matching_nonce()
	await _test_verify_identity_wrong_echo()
	await _test_verify_identity_wrong_plugin()
	await _test_verify_identity_not_ok()
	await _test_ensure_happy_path_no_start_needed()
	await _test_ensure_lazy_start_and_retry()
	await _test_ensure_start_fails_no_retry()
	await _test_ensure_identity_mismatch_after_start_no_retry()

	print("\n########## SECTION B — manifest actually authorizes the mechanism ##########\n")
	_test_manifest_declares_lifecycle_channels()

	print("\n########## SECTION C — real subprocess: the identity primitive vs. the actual binary ##########\n")
	await _test_real_ping_identity_roundtrip()

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


# ──────────────────────────────────────────────────────────────────────────────
# Harness
# ──────────────────────────────────────────────────────────────────────────────

func _bare_panel() -> Variant:
	var panel_script: Script = load(PANEL_PATH)
	if panel_script == null:
		return null
	var panel = panel_script.new()
	root.add_child(panel)
	return panel


## panel + a REAL MinervaIPC child (the same class/node PluginScenePanelBroker
## attaches in production) + a FakeBroker standing in for the broker/backend
## the panel would otherwise talk to.
func _panel_with_broker() -> Array:
	var panel = _bare_panel()
	if panel == null:
		return [null, null, null]
	var ipc := MinervaIPC.new()
	ipc.name = MinervaIPC.HELPER_NODE_NAME
	panel.add_child(ipc)
	var broker := FakeBroker.new(ipc)
	panel.request.connect(broker.on_request)
	return [panel, ipc, broker]


func _free_panel(panel: Variant) -> void:
	if panel != null and is_instance_valid(panel):
		panel.free()


# ──────────────────────────────────────────────────────────────────────────────
# Section A tests
# ──────────────────────────────────────────────────────────────────────────────

func _test_reply_says_plugin_not_running() -> void:
	print("-- _reply_says_plugin_not_running matches the broker's plugin_not_running shape --")
	var panel = _bare_panel()
	check("PCBPanel script loads", panel != null)
	if panel == null:
		return
	check("matches PluginErrors.plugin_not_running() verbatim",
			panel._reply_says_plugin_not_running({
				"success": false, "error_code": "plugin_not_running",
				"error_message": "Plugin is not running", "plugin_id": "pcb",
			}))
	check("matches on message substring alone (defensive — future wording changes)",
			panel._reply_says_plugin_not_running({
				"success": false, "error_message": "backend is not running right now",
			}))
	check("does NOT match an unrelated failure",
			not panel._reply_says_plugin_not_running({
				"success": false, "error_code": "worker_error", "error_message": "route failed",
			}))
	check("does NOT match a success reply",
			not panel._reply_says_plugin_not_running({"success": true, "result": {}}))
	_free_panel(panel)


func _test_verify_identity_matching_nonce() -> void:
	print("-- _verify_backend_identity: ok + plugin=pcb + matching echo -> true --")
	var trio := _panel_with_broker()
	var panel = trio[0]
	var ipc = trio[1]
	var broker: FakeBroker = trio[2]
	check("panel+ipc harness constructed", panel != null)
	if panel == null:
		return
	broker.handlers[PING_CHANNEL] = func(payload: Dictionary) -> Dictionary:
		return _ping_reply({
			"ok": true, "plugin": "pcb", "version": "0.2.0",
			"echo": str(payload.get("echo", "")),
		})
	var verified: bool = await panel._verify_backend_identity(ipc, 5000)
	check("identity verified when ping echoes the exact nonce back", verified)
	check("the ping channel was actually invoked", broker.was_called(PING_CHANNEL))
	_free_panel(panel)


func _test_verify_identity_wrong_echo() -> void:
	print("-- _verify_backend_identity: ok=true but echo does NOT match the nonce -> false --")
	## The exact "stale vs. fresh" ambiguity constraint 2 describes: a backend
	## that answers happily (ok:true) but isn't proven to be answering THIS
	## request. A liveness-only check would pass this; identity must not.
	var trio := _panel_with_broker()
	var panel = trio[0]
	var ipc = trio[1]
	var broker: FakeBroker = trio[2]
	check("panel+ipc harness constructed", panel != null)
	if panel == null:
		return
	broker.handlers[PING_CHANNEL] = func(_payload: Dictionary) -> Dictionary:
		return _ping_reply({
			"ok": true, "plugin": "pcb", "echo": "stale-reply-from-a-different-request",
		})
	var verified: bool = await panel._verify_backend_identity(ipc, 5000)
	check("identity NOT verified when echo mismatches (ok==true is not enough)", not verified)
	_free_panel(panel)


func _test_verify_identity_wrong_plugin() -> void:
	print("-- _verify_backend_identity: ok=true, echo matches, but plugin != 'pcb' -> false --")
	var trio := _panel_with_broker()
	var panel = trio[0]
	var ipc = trio[1]
	var broker: FakeBroker = trio[2]
	check("panel+ipc harness constructed", panel != null)
	if panel == null:
		return
	broker.handlers[PING_CHANNEL] = func(payload: Dictionary) -> Dictionary:
		return _ping_reply({
			"ok": true, "plugin": "cad", "echo": str(payload.get("echo", "")),
		})
	var verified: bool = await panel._verify_backend_identity(ipc, 5000)
	check("identity NOT verified when a DIFFERENT plugin answers", not verified)
	_free_panel(panel)


func _test_verify_identity_not_ok() -> void:
	print("-- _verify_backend_identity: ok=false -> false, regardless of echo/plugin --")
	var trio := _panel_with_broker()
	var panel = trio[0]
	var ipc = trio[1]
	var broker: FakeBroker = trio[2]
	check("panel+ipc harness constructed", panel != null)
	if panel == null:
		return
	broker.handlers[PING_CHANNEL] = func(payload: Dictionary) -> Dictionary:
		return _ping_reply({
			"ok": false, "plugin": "pcb", "echo": str(payload.get("echo", "")),
		})
	var verified: bool = await panel._verify_backend_identity(ipc, 5000)
	check("identity NOT verified when ok==false", not verified)
	_free_panel(panel)


func _test_ensure_happy_path_no_start_needed() -> void:
	print("-- _request_with_backend_ensure: backend already up -> no lazy-start spent --")
	var trio := _panel_with_broker()
	var panel = trio[0]
	var broker: FakeBroker = trio[2]
	check("panel+ipc harness constructed", panel != null)
	if panel == null:
		return
	broker.handlers["pcb.serialize"] = func(_payload: Dictionary) -> Dictionary:
		return {"success": true, "result": {"yaml": "board: {}\n"}}
	var result: Dictionary = await panel._request_with_backend_ensure(
			"pcb.serialize", {"board": {}}, 5000)
	check("result is the direct success reply", bool(result.get("success", false)))
	check("lazy-start capability was NEVER called (on-demand, not blanket)",
			not broker.was_called(START_CHANNEL))
	check("identity ping was NEVER called either (nothing to verify)",
			not broker.was_called(PING_CHANNEL))
	_free_panel(panel)


func _test_ensure_lazy_start_and_retry() -> void:
	print("-- _request_with_backend_ensure: plugin_not_running -> start -> verified -> retried -> success --")
	var trio := _panel_with_broker()
	var panel = trio[0]
	var broker: FakeBroker = trio[2]
	check("panel+ipc harness constructed", panel != null)
	if panel == null:
		return
	# NOTE: count via broker.call_count(), not a captured local int — a
	# GDScript lambda captures an outer local by VALUE at creation time, so
	# `var attempt := 0; func(): attempt += 1` does NOT accumulate across
	# separate .call() invocations of the SAME lambda (each call sees a fresh
	# copy of the snapshot, and the mutation is thrown away when the call
	# returns). broker.calls is a real Array on a real RefCounted object, so
	# it accumulates correctly across calls.
	broker.handlers["pcb.serialize"] = func(_payload: Dictionary) -> Dictionary:
		if broker.call_count("pcb.serialize") == 1:
			return {"success": false, "error_code": "plugin_not_running",
				"error_message": "Plugin is not running", "plugin_id": "pcb"}
		return {"success": true, "result": {"yaml": "board: {}\n"}}
	broker.handlers[START_CHANNEL] = func(_payload: Dictionary) -> Dictionary:
		return {"success": true, "result": {"ok": true}}
	broker.handlers[PING_CHANNEL] = func(payload: Dictionary) -> Dictionary:
		return _ping_reply({
			"ok": true, "plugin": "pcb", "echo": str(payload.get("echo", "")),
		})
	var result: Dictionary = await panel._request_with_backend_ensure(
			"pcb.serialize", {"board": {}}, 5000)
	check("lazy-start capability WAS called exactly once", broker.call_count(START_CHANNEL) == 1)
	check("identity ping WAS called", broker.was_called(PING_CHANNEL))
	check("original channel was retried (called twice total)", broker.call_count("pcb.serialize") == 2)
	check("final result is the retried success, not the original failure",
			bool(result.get("success", false)), "got: %s" % str(result))
	_free_panel(panel)


func _test_ensure_start_fails_no_retry() -> void:
	print("-- _request_with_backend_ensure: start itself fails -> original failure surfaced, never retried --")
	var trio := _panel_with_broker()
	var panel = trio[0]
	var broker: FakeBroker = trio[2]
	check("panel+ipc harness constructed", panel != null)
	if panel == null:
		return
	broker.handlers["pcb.route"] = func(_payload: Dictionary) -> Dictionary:
		return {"success": false, "error_code": "plugin_not_running",
			"error_message": "Plugin is not running"}
	broker.handlers[START_CHANNEL] = func(_payload: Dictionary) -> Dictionary:
		return {"success": false, "error_code": "mcp_tool_error",
			"error_message": "Plugin 'pcb' is in crash-loop — reset it first"}
	var result: Dictionary = await panel._request_with_backend_ensure("pcb.route", {}, 5000)
	check("original plugin_not_running reply is surfaced verbatim",
			str(result.get("error_code", "")) == "plugin_not_running")
	check("the failed channel was never retried", broker.call_count("pcb.route") == 1)
	check("ping was never called (start never succeeded — nothing to verify)",
			not broker.was_called(PING_CHANNEL))
	_free_panel(panel)


func _test_ensure_identity_mismatch_after_start_no_retry() -> void:
	print("-- _request_with_backend_ensure: start reports ok, ping answers as a DIFFERENT process -> no retry --")
	## The exact scenario constraint 2 names: "two backends — a stale one and
	## a freshly started one — will both answer a liveness probe happily."
	## minerva_plugin_start says {ok:true} (the state-flag/liveness signal)
	## but the identity round-trip that follows comes back mismatched — a
	## liveness-only check (ok==true) would treat this as verified and retry
	## anyway; a genuine identity check must refuse.
	var trio := _panel_with_broker()
	var panel = trio[0]
	var broker: FakeBroker = trio[2]
	check("panel+ipc harness constructed", panel != null)
	if panel == null:
		return
	broker.handlers["pcb.deserialize"] = func(_payload: Dictionary) -> Dictionary:
		return {"success": false, "error_code": "plugin_not_running",
			"error_message": "Plugin is not running"}
	broker.handlers[START_CHANNEL] = func(_payload: Dictionary) -> Dictionary:
		return {"success": true, "result": {"ok": true}}
	broker.handlers[PING_CHANNEL] = func(_payload: Dictionary) -> Dictionary:
		return _ping_reply({
			"ok": true, "plugin": "pcb", "echo": "not-the-nonce-this-call-sent",
		})
	var result: Dictionary = await panel._request_with_backend_ensure(
			"pcb.deserialize", {"yaml": ""}, 5000)
	check("result is still the ORIGINAL plugin_not_running failure",
			str(result.get("error_code", "")) == "plugin_not_running")
	check("the channel was never retried despite minerva_plugin_start succeeding",
			broker.call_count("pcb.deserialize") == 1)
	_free_panel(panel)


# ──────────────────────────────────────────────────────────────────────────────
# Section B: manifest wiring
# ──────────────────────────────────────────────────────────────────────────────

func _test_manifest_declares_lifecycle_channels() -> void:
	print("-- manifest.json actually authorizes what the GDScript relies on --")
	var f := FileAccess.open(MANIFEST_PATH, FileAccess.READ)
	check("manifest.json opens", f != null)
	if f == null:
		return
	var text := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	check("manifest.json parses as a Dictionary", parsed is Dictionary)
	if not (parsed is Dictionary):
		return
	var manifest: Dictionary = parsed

	var permissions: Dictionary = manifest.get("permissions", {})
	var host_caps: Array = permissions.get("host_capabilities", [])
	check("permissions.host_capabilities grants mcp.proxy:minerva_plugin_start",
			"mcp.proxy:minerva_plugin_start" in host_caps)

	var ui: Dictionary = manifest.get("ui", {})
	var ipc_messages: Array = ui.get("ipc_messages", [])
	check("ui.ipc_messages declares the lazy-start capability channel",
			START_CHANNEL in ipc_messages)
	check("ui.ipc_messages declares the ping identity channel",
			PING_CHANNEL in ipc_messages)

	check("autostart stays false — lazy start-on-demand is the mechanism, not blanket autostart",
			bool(manifest.get("autostart", true)) == false)

	var panels: Array = ui.get("panels", [])
	var pcb_panel: Dictionary = {}
	for p in panels:
		if p is Dictionary and str((p as Dictionary).get("name", "")) == "pcb_panel":
			pcb_panel = p
			break
	check("pcb_panel entry found in ui.panels", not pcb_panel.is_empty())
	var panel_channels: Array = pcb_panel.get("ipc_channels", [])
	check("pcb_panel.ipc_channels declares the lazy-start capability channel",
			START_CHANNEL in panel_channels)
	check("pcb_panel.ipc_channels declares the ping identity channel",
			PING_CHANNEL in panel_channels)


# ──────────────────────────────────────────────────────────────────────────────
# Section C: real subprocess round-trip
# ──────────────────────────────────────────────────────────────────────────────

func _test_real_ping_identity_roundtrip() -> void:
	print("-- REAL subprocess: the ping identity primitive against the actual Go binary --")
	var home: String = OS.get_environment("HOME")
	if home == "":
		home = OS.get_environment("USERPROFILE")
	var plugin_dir: String = OS.get_environment("MINERVA_PCB_PLUGIN_DIR")
	if plugin_dir == "" and home != "":
		plugin_dir = home + PCB_PLUGIN_DIR_REL
	var binary_path: String = plugin_dir + PCB_BINARY_REL
	if not FileAccess.file_exists(binary_path) and FileAccess.file_exists(binary_path + ".exe"):
		binary_path += ".exe"

	if plugin_dir == "" or not FileAccess.file_exists(binary_path):
		print("SKIP: pcb-plugin binary not built at '%s'." % binary_path)
		print("      (Go toolchain absent on this host — Section C not exercised.)")
		print("      Build with: cd %s && go build -o pcb-plugin ." % plugin_dir)
		return

	var manifest_path: String = plugin_dir + PCB_MANIFEST_REL

	var def_script: Script = load(PLUGIN_DEFINITION_SCRIPT_PATH)
	check("PluginDefinition script loads", def_script != null)
	if def_script == null:
		return

	var pm_script: Script = load(PLUGIN_MANAGER_SCRIPT_PATH)
	check("PluginManager.gd loads", pm_script != null)
	if pm_script == null:
		return
	var pm = pm_script.new()
	root.add_child(pm)
	await process_frame
	check("PluginManager initialised", pm._db != null)
	if pm._db == null:
		return

	var def = pm._db.get_by_id("pcb")
	if def == null:
		var install_result: Dictionary = await pm.install_plugin(manifest_path, true)
		check("install_plugin returns ok", install_result.get("ok", false) == true,
				"got: %s" % str(install_result))
		def = pm._db.get_by_id("pcb")
	check("PCB definition loaded into DB", def != null)
	if def == null:
		return
	if def.state == S_RUNNING:
		await pm.stop_plugin("pcb")

	var start_result: Dictionary = await pm.start_plugin("pcb")
	check("start_plugin returns ok", start_result.get("ok", false) == true,
			"got: %s" % str(start_result))

	var conn = pm.get_connection("pcb")
	check("connection exists post-start", conn != null)
	if conn != null:
		var nonce := "e2e-identity-%d" % Time.get_ticks_usec()
		var reply: Variant = await conn.call_tool(PING_CHANNEL, {"echo": nonce}, 10.0)
		check("ping tool call returned a Dictionary", reply is Dictionary, "got: %s" % str(reply))
		if reply is Dictionary:
			# One level of Go-side wrap at this raw-stdio call_tool boundary:
			# main.go's dispatch() always wraps a tool's raw handler result as
			# {ok:true, result:<raw>} (main.go:347-349) before it leaves the
			# process — confirmed empirically here, not assumed. HandlePing's
			# own body ({ok,plugin,version,echo}) is one level deeper than the
			# call_tool() return value itself.
			var envelope: Dictionary = reply
			check("Go dispatch envelope has ok == true", bool(envelope.get("ok", false)),
					"got: %s" % str(envelope))
			var body_variant: Variant = envelope.get("result", {})
			check("Go dispatch envelope carries a 'result' Dictionary (HandlePing's body)",
					body_variant is Dictionary, "got: %s" % str(envelope))
			if body_variant is Dictionary:
				var body: Dictionary = body_variant
				check("ping ok == true", bool(body.get("ok", false)), "got: %s" % str(body))
				check("ping plugin == 'pcb' (this IS the pcb backend, not some other plugin)",
						str(body.get("plugin", "")) == "pcb", "got: %s" % str(body))
				check("ping echo == the exact nonce this call sent (process-identity proof)",
						str(body.get("echo", "")) == nonce, "got: %s" % str(body))

	var stop_result: Dictionary = await pm.stop_plugin("pcb")
	check("stop_plugin returns ok", stop_result.get("ok", false) == true)


# ──────────────────────────────────────────────────────────────────────────────

func check(description: String, condition: bool, detail: String = "") -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		if detail != "":
			printerr("  FAIL: %s — %s" % [description, detail])
		else:
			printerr("  FAIL: %s" % description)
