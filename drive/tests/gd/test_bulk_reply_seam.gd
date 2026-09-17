extends SceneTree
## A tracked set whose list reply does not fit the control lane still renders.
##
## WHY THIS SUITE EXISTS
##
## The host bounds an ordinary scene-panel reply at
## PluginScenePanelBroker.MAX_PAYLOAD_BYTES (64 KiB) in BOTH directions and
## replaces an over-cap reply with a payload_too_large error. drive's list
## reply carries one row per tracked project — name, uuid, status, two
## versions and an absolute path, roughly 280 bytes of the decoded reply the
## broker weighs — so somewhere around 230 tracked projects the reply stops
## fitting and the panel shows nothing but "Could not load project list".
##
## So this suite uses the REAL chain and nothing else — a real PluginManager,
## a real PluginScenePanelBroker, the real drive-plugin binary, and the real
## DrivePanel scene — and it weighs the reply before asserting on what was
## drawn:
##
##   the request that goes out is far under the cap, so the reply is what is
##     on trial;
##   the reply really is over the cap (measured here, not assumed);
##   it is not a payload_too_large refusal;
##   and the rows on screen are the rows the worker sent — the tree holds one
##     item per project in the weighed reply, and the fixture's own projects
##     are all among them.
##
## Reverting DrivePanel._send_request to the `request` signal turns the
## weighed round trip red with payload_too_large and the row assertions with
## it.
##
## THE FIXTURE is generated here: a .drive-state.json holding
## FIXTURE_PROJECTS tracked entries, written into a scratch Drive folder. The
## entries do not need files behind them — a registered entry is a row whether
## or not its local path still exists — so nothing outside the scratch folder
## is read or written.
##
## SCRATCH-FOLDER CONTRACT: drive locates its state file from DRIVE_FOLDER (or
## ~/MinervaDrive when that is unset), so this suite exports DRIVE_FOLDER
## before starting the backend and then CONFIRMS, from the worker's own status
## reply, that the backend is using the scratch folder. If the environment did
## not reach the subprocess the live steps do not run: this suite will not
## write a fixture into a real user's Drive.
##
## READINESS CONTRACT: start_plugin returning ok means the subprocess
## launched, not that it is answering — the host's own tool discovery is still
## round-tripping on the same stdio pipe. The suite therefore waits on a real
## status round trip, retried on a short budget, and never on a sleep.
##
## SKIP CONTRACT: when the Rust binary is not built on this host the live
## sections do not run and the suite says so loudly. Its assertion pin
## therefore describes a host that has built the plugin.
##
## Run:
##   scripts/run-gd-tests.sh --plugin drive <path-to-minerva-checkout>

const PANEL_SCENE_PATH := "res://../../minerva-plugins/drive/ui/DrivePanel.tscn"

## Host classes, preloaded by path rather than by class_name: this script is
## parsed from outside Minerva's res:// tree, and the paths are pinned in
## tests/gd/REQUIRED_HOST_FILES so a host refactor fails by name.
const PANEL_BROKER_PATH := "res://Scripts/Services/Plugins/PluginScenePanelBroker.gd"
const PLUGIN_MANAGER_PATH := "res://Scripts/Services/Plugins/PluginManager.gd"

const DRIVE_PLUGIN_DIR_REL := "/github/minerva-plugins/drive"
const DRIVE_BINARY_REL := "/drive-plugin"
const DRIVE_MANIFEST_REL := "/manifest.json"

## PluginDefinition.State values this suite waits on. The setup pipeline
## (cargo_build) leaves an install BUILDING until it lands.
const S_RUNNING := 2
const S_BUILDING := 6
const S_BUILD_FAILED := 7

const MANIFEST_PANEL := "drive_panel"
const LIST_CHANNEL := "minerva_drive_list"
const STATUS_CHANNEL := "minerva_drive_status"

## Enough registered projects for the list reply to clear 64 KiB with room to
## spare: at ~280 bytes of decoded reply per row this is ~110 KB, 1.7x the
## cap. The suite MEASURES the result rather than trusting this number.
const FIXTURE_PROJECTS := 400
const FIXTURE_NAME_PREFIX := "bulk-lane-fixture-project-"

## Generous: a cold backend may attempt (and fail) a cloud round trip first.
const LIST_TIMEOUT_MS := 60000

## Readiness probing: a short per-probe budget so an unanswered request costs
## one retry, and a long overall one so a genuinely dead backend is still
## reported as dead rather than as a slow one.
const READY_PROBE_MS := 15000
const READY_DEADLINE_MS := 120000

var _pass: int = 0
var _fail: int = 0
var _pm: Node = null
## True only when this suite built the manager and must therefore free it.
var _owns_pm: bool = false
var _broker: Object = null
var _panel: Node = null
var _panel_key: String = ""
var _scratch_folder: String = ""
## The worker's own row count, read off the weighed reply.
var _worker_rows: int = -1


func _init() -> void:
	print("=== Drive bulk-reply seam test ===\n")
	await process_frame

	var home: String = OS.get_environment("HOME")
	if home == "":
		home = OS.get_environment("USERPROFILE")
	var plugin_dir: String = OS.get_environment("MINERVA_DRIVE_PLUGIN_DIR")
	if plugin_dir == "" and home != "":
		plugin_dir = home + DRIVE_PLUGIN_DIR_REL
	var binary_path: String = plugin_dir + DRIVE_BINARY_REL
	if not FileAccess.file_exists(binary_path) and FileAccess.file_exists(binary_path + ".exe"):
		binary_path += ".exe"

	if plugin_dir == "" or not FileAccess.file_exists(binary_path):
		print("SKIP: drive-plugin binary not built at '%s'." % binary_path)
		print("      Build with: cd %s && cargo build --release" % plugin_dir)
	else:
		_write_fixture_state()
		var mounted: bool = await _mount(plugin_dir + DRIVE_MANIFEST_REL)
		if mounted:
			var scratched: bool = await _step_the_backend_uses_the_scratch_folder()
			if scratched:
				await _step_the_list_reply_is_over_the_cap()
				await _step_the_panel_shows_every_row_the_worker_sent()
			else:
				printerr("SETUP FAILED — DRIVE_FOLDER did not reach the backend; "
						+ "live steps not run rather than touch a real Drive folder")
		else:
			printerr("SETUP FAILED — the real chain did not mount; live steps not run")
		await _teardown()

	_cleanup()
	await process_frame
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


# ---------------------------------------------------------------------------
# Fixture — a scratch Drive folder holding FIXTURE_PROJECTS registered entries
# ---------------------------------------------------------------------------

## Registered entries alone produce list rows: compute_status walks
## state.entries and reports a row per entry regardless of whether the local
## path still exists. So no fixture FILES are created, only the state file.
func _write_fixture_state() -> void:
	_scratch_folder = OS.get_user_data_dir().path_join("drive_bulk_reply_seam")
	DirAccess.make_dir_recursive_absolute(_scratch_folder)
	var entries: Dictionary = {}
	for i in range(FIXTURE_PROJECTS):
		var name: String = "%s%03d.mnrv" % [FIXTURE_NAME_PREFIX, i]
		var path: String = _scratch_folder.path_join("tracked").path_join(name)
		entries[path] = {
			"proj_uuid": "00000000-0000-4000-8000-%012d" % i,
			"name": name,
			"base_version": 1,
			"base_hash": "0".repeat(64),
		}
	var state := {
		"device_id": "drive-bulk-reply-seam",
		"entries": entries,
		"tracked": [],
		"drive_folder_override": "",
	}
	var f := FileAccess.open(_scratch_folder.path_join(".drive-state.json"), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(state))
		f.close()
	# Exported before the backend starts, so the subprocess inherits it. The
	# status step below proves the subprocess actually saw it.
	OS.set_environment("DRIVE_FOLDER", _scratch_folder)


# ---------------------------------------------------------------------------
# Mount — real PluginManager + real broker + real panel, production order
# ---------------------------------------------------------------------------

func _mount(manifest_path: String) -> bool:
	# ONE manager per plugin id, or none of this is a fair test. The headless
	# host boots its own plugin system, and a second PluginManager over the
	# same plugin database gives the id two runtimes: each starts its own
	# subprocess and runs its own tool discovery, the loser is named in the log
	# as "Plugin connection changed during tool discovery", and a request sent
	# on one runtime's connection is answered into the other's reader — the
	# awaiting panel is never told anything at all. So reuse the host's
	# manager whenever the autoload has one, and build a private one only on a
	# host that has no plugin system.
	_owns_pm = false
	# Reached through the tree rather than the autoload identifier so a host
	# without the singleton is a fallback, not a parse-time dependency.
	var singleton: Node = root.get_node_or_null("SingletonObject")
	if singleton != null and singleton.get("plugin_manager") != null:
		_pm = singleton.get("plugin_manager")
		print("  reusing the host's PluginManager (one runtime per plugin id)")
	else:
		var pm_script: Script = load(PLUGIN_MANAGER_PATH)
		if pm_script == null:
			printerr("  PluginManager.gd did not load")
			return false
		_pm = pm_script.new()
		_owns_pm = true
		root.add_child(_pm)
	await process_frame
	if _pm._db == null:
		printerr("  PluginManager did not initialise its database")
		return false

	var def = _pm._db.get_by_id("drive")
	# An install predating the current manifest's channel list would make the
	# broker deny the list channel by allowlist — a permission_denied that
	# looks nothing like the cap this suite is about. Refresh through the
	# manager's own API so the assertions are about the manifest standing now.
	if def != null and not (LIST_CHANNEL in def.ui_ipc_messages):
		print("  installed drive definition predates the manifest's channel list "
				+ "— refreshing via remove_plugin + install_plugin")
		if def.state == S_RUNNING:
			await _pm.stop_plugin("drive")
		await _pm.remove_plugin("drive", false)
		def = null
	if def == null:
		var install_result: Dictionary = await _pm.install_plugin(manifest_path, true)
		check("setup: install_plugin returns ok",
				bool(install_result.get("ok", false)), str(install_result))
		def = _pm._db.get_by_id("drive")
		# The drive manifest carries a `setup` stanza, so install starts a
		# cargo_build on a worker thread. Wait it out: the build rewrites the
		# very binary start_plugin would exec, and a pipeline still running at
		# process exit crashes engine teardown.
		if def != null and def.state == S_BUILDING:
			print("  setup pipeline building (cargo_build) — waiting…")
			var deadline_ms: int = Time.get_ticks_msec() + 900000
			while def.state == S_BUILDING and Time.get_ticks_msec() < deadline_ms:
				await create_timer(0.5).timeout
			check("setup: the build pipeline finished and did not fail",
					def.state != S_BUILDING and def.state != S_BUILD_FAILED,
					"state=%d" % def.state)
	if def == null:
		printerr("  drive definition never reached the plugin database")
		return false
	check("setup: the installed definition declares %s" % LIST_CHANNEL,
			LIST_CHANNEL in def.ui_ipc_messages,
			"installed ui_ipc_messages=%s" % str(def.ui_ipc_messages))
	if def.state == S_RUNNING:
		await _pm.stop_plugin("drive")
	var start_result: Dictionary = await _pm.start_plugin("drive")
	check("setup: start_plugin returns ok",
			bool(start_result.get("ok", false)), str(start_result))
	if not bool(start_result.get("ok", false)):
		return false

	# Policy, capability broker and audit log stay null: backend-channel
	# dispatch consults none of them, and _audit guards a null log itself.
	var broker_script: Script = load(PANEL_BROKER_PATH)
	if broker_script == null:
		printerr("  PluginScenePanelBroker.gd did not load")
		return false
	_broker = broker_script.new(_pm, null, null, null)

	var declared := PackedStringArray()
	for p in def.ui_panels:
		if p is Dictionary and str((p as Dictionary).get("name", "")) == MANIFEST_PANEL:
			for ch in (p as Dictionary).get("ipc_channels", []):
				declared.append(str(ch))
			break

	var packed: PackedScene = load(PANEL_SCENE_PATH)
	_panel = packed.instantiate() if packed != null else null
	check("setup: the Drive panel scene instantiates", _panel != null, PANEL_SCENE_PATH)
	if _panel == null:
		return false
	root.add_child(_panel)

	# Register before the load hook, the order PluginScenePanelHost guarantees:
	# registration is what attaches the MinervaIPC helper the panel sends on.
	_panel_key = "%s#%d" % [MANIFEST_PANEL, _panel.get_instance_id()]
	_broker.register_panel(_panel, "drive", _panel_key, declared, MANIFEST_PANEL)
	_panel._on_panel_loaded({
		"plugin_id": "drive",
		"panel_name": MANIFEST_PANEL,
		"panel_key": _panel_key,
		"broker": _broker,
		"host_api_version": "1",
	})
	var ipc: Node = _panel.get_node_or_null("_MinervaIPC")
	check("setup: the host offers the bulk route this fix rides",
			ipc != null and ipc.has_method("request_bulk"),
			"helper=%s" % str(ipc))
	for _i in range(4):
		await process_frame
	return ipc != null


# ---------------------------------------------------------------------------
# The scratch-folder guard
# ---------------------------------------------------------------------------

## The backend reports the folder it is actually working in. Unless that is the
## scratch folder this suite created, the fixture is not what the list reply
## describes and a real user's Drive might be. Refuse to go further.
func _step_the_backend_uses_the_scratch_folder() -> bool:
	print("-- the backend is working in this suite's scratch folder --")
	# start_plugin returning ok means the subprocess launched, not that it is
	# answering: the host's own tool discovery is still round-tripping on the
	# same stdio pipe. Readiness is therefore a real round trip and nothing
	# else — status is the cheapest one drive has and is documented never to
	# fail — retried on a short budget so a request issued into an unsettled
	# connection costs one retry instead of the whole suite.
	var envelope: Dictionary = {}
	var answered: bool = false
	var deadline_ms: int = Time.get_ticks_msec() + READY_DEADLINE_MS
	while Time.get_ticks_msec() < deadline_ms:
		envelope = await _panel._send_request(
				_panel.get_node_or_null("_MinervaIPC"), STATUS_CHANNEL, {}, READY_PROBE_MS)
		if bool(envelope.get("success", false)):
			answered = true
			break
		print("  backend not answering yet (%s) — retrying"
				% str(envelope.get("error_code", "?")))
		# A refusal comes back immediately, so back off rather than spin.
		await create_timer(0.5).timeout
	check("the backend answered a status round trip before the measurements begin",
			answered, "last envelope=%s" % str(envelope).left(400))
	if not answered:
		return false
	var folder: String = str(_worker_result(envelope).get("folder", ""))
	var ok: bool = folder == _scratch_folder
	check("the backend's effective Drive folder is the scratch folder",
			ok, "backend=%s scratch=%s envelope=%s" % [
				folder, _scratch_folder, str(envelope).left(400)])
	return ok


# ---------------------------------------------------------------------------
# The reply, weighed
# ---------------------------------------------------------------------------

## The panel's own send seam, so the envelope can be measured before anything
## unwraps it — same broker, same backend, same channel the rows below ride.
func _step_the_list_reply_is_over_the_cap() -> void:
	print("-- the project list is bigger than the control lane allows --")
	var cap: int = load(PANEL_BROKER_PATH).MAX_PAYLOAD_BYTES
	var request_bytes: int = JSON.stringify({}).to_utf8_buffer().size()
	check("the request that goes out is far under the control cap — the reply "
			+ "is what is on trial",
			request_bytes < cap, "request=%d cap=%d" % [request_bytes, cap])

	var envelope: Dictionary = await _panel._send_request(
			_panel.get_node_or_null("_MinervaIPC"), LIST_CHANNEL, {}, LIST_TIMEOUT_MS)
	var reply_bytes: int = JSON.stringify(envelope).to_utf8_buffer().size()
	print("  measured: reply=%d bytes, control cap=%d bytes" % [reply_bytes, cap])
	check("the reply really is over the control cap",
			reply_bytes > cap, "reply=%d cap=%d" % [reply_bytes, cap])
	check("the reply is not a payload_too_large refusal",
			str(envelope.get("error_code", "")).findn("too_large") == -1
				and str(envelope.get("error_message", "")).findn("too large") == -1,
			str(envelope).left(400))

	var projects: Array = _worker_result(envelope).get("projects", []) as Array
	_worker_rows = projects.size()
	check("the worker answered with the whole tracked set, not an error",
			bool(envelope.get("success", false)) and _worker_rows >= FIXTURE_PROJECTS,
			"rows=%d fixture=%d envelope=%s" % [
				_worker_rows, FIXTURE_PROJECTS, str(envelope).left(400)])


# ---------------------------------------------------------------------------
# The rows, against the worker's own count
# ---------------------------------------------------------------------------

## The production refresh path — the same call the panel makes on load — then
## the tree is counted against the number the weighed reply carried.
func _step_the_panel_shows_every_row_the_worker_sent() -> void:
	print("-- the panel lists every one of them --")
	await _panel._fetch_list()
	await process_frame

	var status_label: Label = _panel._status_label
	check("the panel reported no load failure",
			status_label == null or not status_label.visible
				or status_label.text.findn("Could not load project list") == -1,
			"status=%s" % (status_label.text if status_label != null else "<none>"))

	var tree: Tree = _panel._project_tree
	var drawn: int = -1
	var named: int = 0
	if tree != null and tree.get_root() != null:
		var rows: Array = tree.get_root().get_children()
		drawn = rows.size()
		for row in rows:
			if str((row as TreeItem).get_text(0)).begins_with(FIXTURE_NAME_PREFIX):
				named += 1
	check("the tree holds one row per project the worker sent",
			drawn == _worker_rows and _worker_rows > 0,
			"drawn=%d worker=%d" % [drawn, _worker_rows])
	check("every fixture project is among the drawn rows",
			named == FIXTURE_PROJECTS,
			"named=%d fixture=%d" % [named, FIXTURE_PROJECTS])


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

## Two levels of unwrap between the broker envelope and the worker's own
## payload: the broker's {success, result} wraps the tool result the host
## decoded out of content[0].text.
func _worker_result(envelope: Dictionary) -> Dictionary:
	var payload: Variant = envelope.get("result")
	if payload is Dictionary and (payload as Dictionary).get("result") is Dictionary:
		return (payload as Dictionary)["result"]
	if payload is Dictionary:
		return payload as Dictionary
	return {}


func _teardown() -> void:
	if _panel != null and is_instance_valid(_panel):
		if _broker != null and not _panel_key.is_empty():
			_broker.unregister_panel("drive", _panel_key)
		_panel._on_panel_unload()
		if _panel.get_parent() != null:
			_panel.get_parent().remove_child(_panel)
		# Freed immediately, not queued: a queued free right before quit()
		# never gets its frame, which Godot reports as resources still in use.
		_panel.free()
		_panel = null
	if _broker is Node and is_instance_valid(_broker as Node) \
			and (_broker as Node).get_parent() == null:
		(_broker as Node).free()
	if _pm != null:
		# Stopped either way — this suite started it. The manager itself is
		# left alone unless it is this suite's own.
		var stop_result: Dictionary = await _pm.stop_plugin("drive")
		check("teardown: stop_plugin returns ok",
				bool(stop_result.get("ok", false)), str(stop_result))
		if _owns_pm and is_instance_valid(_pm):
			if _pm.get_parent() != null:
				_pm.get_parent().remove_child(_pm)
			_pm.free()
		_pm = null


## The whole scratch tree, not just the fixture: the backend creates the
## effective Drive folder on every call and may materialise files under it, and
## anything left behind would seed the NEXT run's state with rows this suite
## did not write.
func _cleanup() -> void:
	if _scratch_folder == "":
		return
	_remove_tree(_scratch_folder)


func _remove_tree(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.include_hidden = true
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if entry != "." and entry != "..":
			var child: String = path.path_join(entry)
			if dir.current_is_dir():
				_remove_tree(child)
			else:
				DirAccess.remove_absolute(child)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)


func check(desc: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		if detail != "":
			printerr("  FAIL: %s — %s" % [desc, detail])
		else:
			printerr("  FAIL: %s" % desc)
