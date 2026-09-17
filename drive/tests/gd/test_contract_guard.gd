extends SceneTree
## drive's CONTRACT GUARD — six domain-defined cases through the real host chain.
##
## WHY THIS SUITE EXISTS
##
## The host bounds an ordinary scene-panel reply at
## PluginScenePanelBroker.MAX_PAYLOAD_BYTES (64 KiB) in both directions. drive's
## list reply carries one row per tracked project, so a real user's Drive stops
## fitting the control lane somewhere around 230 projects and the panel shows
## nothing but "Could not load project list".
##
## test_bulk_reply_seam.gd closes that one case. This guard weighs the plugin
## against the same contract at BOTH sizes and in both moods:
##
##   1. null / empty document   — an empty Drive lists as an explicit empty
##                                set, not as a failure
##   2. small happy             — two tracked projects list and draw
##   3. small unhappy           — a verb the worker refuses, with nothing
##                                half-applied to the tracked set
##   4. large happy             — 400 tracked projects, a reply OVER the
##                                control cap, drawn row for row
##   5. large unhappy           — a MALFORMED state file holding those 400
##                                projects (see THE KNOWN RED below)
##   6. large-with-errors reply — the same 400 projects with every one of them
##                                in an unhappy status: drive's DECLARED lane
##                                is that this reply does not outgrow the happy
##                                one, and the declaration is measured
##
## drive's own definition of LARGE is TRACKED-FILE COUNT. Measured against the
## real binary over stdio: 400 registered entries answer in 122,918 bytes
## (1.9x the cap); the same 400 with every row local_ahead answer in 124,918 —
## 2,000 bytes more, which is exactly the five extra characters of the status
## word times four hundred rows. That is the declaration case 6 pins: a drive
## row is FIXED SHAPE whatever a project's status, and drive owns no per-row
## error text, so its unhappy reply cannot outgrow its happy one. The one
## per-item error list drive does own — sync's `errors` array — is unreachable
## without a cloud connection, so it is not on this guard's surface. Add a
## per-row error field and case 6 goes red, which is the point: the lane has to
## be re-declared deliberately.
##
## THE KNOWN RED (case 5). Measured against the real binary: a state file that
## is not valid JSON is read as an EMPTY state (main.rs load_state ends in
## `unwrap_or_default()`), reported as a Drive with no projects at all, and
## then OVERWRITTEN with that empty state — 400 tracked projects silently
## destroyed and the reply says everything is fine. Case 5 asserts the contract
## rather than the behaviour: a document the plugin cannot read is a refusal,
## never an empty document, and never a rewrite. It is expected to FAIL until
## load_state is fixed. Do not weaken it to make the suite green; that is the
## whole failure this guard exists to make visible.
##
## EVERYTHING IS REAL: the host's own PluginManager where there is one, the
## real PluginScenePanelBroker, the real drive-plugin binary, the real
## DrivePanel scene.
##
## SCRATCH-FOLDER CONTRACT (inherited from the bulk-reply suite, and not
## optional): drive locates its state from DRIVE_FOLDER, so this suite exports
## a scratch folder before starting the backend and then CONFIRMS from the
## worker's own status reply that the backend is using it. If the environment
## did not reach the subprocess, no case runs: this suite will not write a
## fixture into — or corrupt a state file inside — a real user's Drive.
##
## ORACLE: revert DrivePanel._send_request to the `request` signal and cases 4
## and 6 go red with payload_too_large — both replies are over the control cap
## — while cases 1, 2 and 3 stay green, because an empty Drive, two projects
## and a refusal all fit it many times over.
##
## SKIP CONTRACT: with the Rust binary unbuilt the live cases do not run and
## the suite says so loudly. Its assertion pin therefore describes a host that
## has built the plugin and installed it.
##
## Run: scripts/run-gd-tests.sh --plugin drive <path-to-minerva-checkout>

const ContractGuard := preload("res://../../minerva-plugins/scripts/contract_guard.gd")

const PANEL_SCENE_PATH := "res://../../minerva-plugins/drive/ui/DrivePanel.tscn"
const PANEL_BROKER_PATH := "res://Scripts/Services/Plugins/PluginScenePanelBroker.gd"
const PLUGIN_MANAGER_PATH := "res://Scripts/Services/Plugins/PluginManager.gd"

const DRIVE_PLUGIN_DIR_REL := "/github/minerva-plugins/drive"
const DRIVE_BINARY_REL := "/drive-plugin"
const DRIVE_MANIFEST_REL := "/manifest.json"

## PluginDefinition.State values the setup pipeline (cargo_build) passes through.
const S_RUNNING := 2
const S_BUILDING := 6
const S_BUILD_FAILED := 7

const MANIFEST_PANEL := "drive_panel"
const LIST_CHANNEL := "minerva_drive_list"
const STATUS_CHANNEL := "minerva_drive_status"
const ADD_CHANNEL := "minerva_drive_add"
const GUARD_CHANNELS := [LIST_CHANNEL, STATUS_CHANNEL, ADD_CHANNEL]

## drive's unit of large, and the count both large moods share.
const LARGE_PROJECTS := 400
const SMALL_PROJECTS := 2
const FIXTURE_NAME_PREFIX := "contract-guard-project-"

## The status a registered entry reports when its file on disk does not hash to
## the version drive recorded: work that has not reached the cloud. Every row in
## case 6 carries it.
const UNHAPPY_STATUS := "local_ahead"

## Generous: a cold backend may attempt (and fail) a cloud round trip first.
const LIST_TIMEOUT_MS := 60000

## Readiness probing: a short per-probe budget so an unanswered request costs
## one retry, and a long overall one so a genuinely dead backend is reported as
## dead rather than as a slow one.
const READY_PROBE_MS := 15000
const READY_DEADLINE_MS := 120000

var guard := ContractGuard.new()
var _pm: Node = null
## True only when this suite built the manager and must therefore free it.
var _owns_pm := false
var _broker: Object = null
var _panel: Node = null
var _panel_key := ""
var _scratch_folder := ""
## The keys a row carries in the happy large reply — case 6's comparison.
var _happy_row_keys: Array = []


func _init() -> void:
	print("=== Drive contract guard — six cases through the real host chain ===\n")
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
		# The empty state is written BEFORE the backend starts, so case 1 asks
		# about a Drive that was empty from the subprocess's first breath.
		_prepare_scratch()
		_write_state({}, [])
		var mounted: bool = await _mount(plugin_dir + DRIVE_MANIFEST_REL)
		if mounted:
			await _case_null_document()
			await _case_small_happy()
			await _case_small_unhappy()
			await _case_large_happy()
			await _case_large_unhappy()
			await _case_large_error_reply()
		else:
			printerr("SETUP FAILED — the real chain did not mount (or DRIVE_FOLDER "
					+ "did not reach the backend); cases not run rather than touch "
					+ "a real Drive folder")
		await _teardown()

	_cleanup()
	await process_frame
	quit(guard.results())


# ---------------------------------------------------------------------------
# Mount — the host's PluginManager + real broker + real panel
# ---------------------------------------------------------------------------

func _mount(manifest_path: String) -> bool:
	# ONE manager per plugin id, or none of this is a fair test: a second
	# PluginManager over the same plugin database gives the id two runtimes,
	# each with its own subprocess, and a request sent on one runtime's
	# connection is answered into the other's reader. So reuse the host's
	# manager whenever the autoload has one.
	_owns_pm = false
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
	if not guard.check("setup: the plugin manager initialised its database", _pm._db != null):
		return false

	var def = _pm._db.get_by_id("drive")
	# An install predating the current manifest's channel list would have the
	# broker deny a channel by allowlist — a permission_denied that looks
	# nothing like the contract under test.
	if def != null and not _declares_every_channel(def):
		print("  installed definition predates the manifest's channel list — "
				+ "refreshing via remove_plugin + install_plugin")
		if def.state == S_RUNNING:
			await _pm.stop_plugin("drive")
		await _pm.remove_plugin("drive", false)
		def = null
	if def == null:
		print("  installing the plugin from %s" % manifest_path)
		await _pm.install_plugin(manifest_path, true)
		def = _pm._db.get_by_id("drive")
		# The manifest carries a `setup` stanza, so install runs cargo_build on
		# a worker thread. Wait it out: the build rewrites the very binary
		# start_plugin would exec, and a pipeline still running at process exit
		# crashes engine teardown.
		if def != null and def.state == S_BUILDING:
			print("  setup pipeline building (cargo_build) — waiting...")
			var deadline_ms: int = Time.get_ticks_msec() + 900000
			while def.state == S_BUILDING and Time.get_ticks_msec() < deadline_ms:
				await create_timer(0.5).timeout
			if def.state == S_BUILDING or def.state == S_BUILD_FAILED:
				printerr("  setup pipeline did not land (state=%d)" % def.state)
	if def == null:
		printerr("  the drive definition never reached the plugin database")
		return false
	if not guard.check("setup: the installed definition declares every channel this "
			+ "guard rides", _declares_every_channel(def),
			"installed ui_ipc_messages=%s" % str(def.ui_ipc_messages)):
		return false

	if def.state == S_RUNNING:
		await _pm.stop_plugin("drive")
	var start_result: Dictionary = await _pm.start_plugin("drive")
	if not guard.check("setup: the backend starts", bool(start_result.get("ok", false)),
			str(start_result)):
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
	if _panel == null:
		printerr("  the Drive panel scene did not instantiate")
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
	if not guard.check("setup: the host offers the bulk route the large cases ride",
			ipc != null and ipc.has_method("request_bulk"), "helper=%s" % str(ipc)):
		return false
	for _i in range(4):
		await process_frame
	return await _confirm_scratch_folder()


func _declares_every_channel(def) -> bool:
	for ch in GUARD_CHANNELS:
		if not (ch in def.ui_ipc_messages):
			return false
	return true


## start_plugin returning ok means the subprocess launched, not that it is
## answering — the host's own tool discovery is still round-tripping on the same
## stdio pipe. Readiness is therefore a real round trip and nothing else, and
## the same round trip carries the safety gate: unless the backend names THIS
## suite's scratch folder, nothing below runs.
func _confirm_scratch_folder() -> bool:
	var envelope: Dictionary = {}
	var answered := false
	var deadline_ms: int = Time.get_ticks_msec() + READY_DEADLINE_MS
	while Time.get_ticks_msec() < deadline_ms:
		envelope = await _send(STATUS_CHANNEL, {}, READY_PROBE_MS)
		if bool(envelope.get("success", false)):
			answered = true
			break
		print("  backend not answering yet (%s) — retrying"
				% str(envelope.get("error_code", "?")))
		await create_timer(0.5).timeout
	if not guard.check("setup: the backend answered a status round trip", answered,
			ContractGuard.brief(envelope, 400)):
		return false
	var folder: String = str(_worker_result(envelope).get("folder", ""))
	return guard.check("setup: the backend is working in this suite's scratch folder",
			folder == _scratch_folder,
			"backend=%s scratch=%s" % [folder, _scratch_folder])


# ---------------------------------------------------------------------------
# Case 1 — null / empty document
# ---------------------------------------------------------------------------

## An empty Drive is a normal Drive, and the reply has to say so in a way a
## reader can tell apart from a failure: success, and an empty list of rows —
## never a refusal, and never a bare absence.
func _case_null_document() -> void:
	print("\n-- null/empty document: an empty Drive lists as an empty set --")
	var envelope: Dictionary = await _send(LIST_CHANNEL, {}, LIST_TIMEOUT_MS)
	guard.expect_success("null-document", envelope)
	guard.check_eq("null-document: the reply carries an explicit empty row list",
			_rows(envelope).size(), 0)


# ---------------------------------------------------------------------------
# Case 2 — small happy
# ---------------------------------------------------------------------------

func _case_small_happy() -> void:
	print("\n-- small happy: two tracked projects list and draw --")
	_write_state(_entries(SMALL_PROJECTS, false), [])
	var envelope: Dictionary = await _send(LIST_CHANNEL, {}, LIST_TIMEOUT_MS)
	guard.expect_success("small-happy", envelope)
	guard.check_eq("small-happy: the reply carries one row per tracked project",
			_rows(envelope).size(), SMALL_PROJECTS)
	guard.check_eq("small-happy: the panel draws one row per project",
			await _drawn_rows(), SMALL_PROJECTS)


# ---------------------------------------------------------------------------
# Case 3 — small unhappy
# ---------------------------------------------------------------------------

## The worker's own refusal: add without a path. The tracked set must be exactly
## what it was — a refused write that half-registers something is the partial
## state this forbids.
func _case_small_unhappy() -> void:
	print("\n-- small unhappy: a verb the worker refuses --")
	var envelope: Dictionary = await _send(ADD_CHANNEL, {"path": ""}, LIST_TIMEOUT_MS)
	guard.expect_refusal("small-unhappy", envelope)
	var after: Dictionary = await _send(LIST_CHANNEL, {}, LIST_TIMEOUT_MS)
	guard.expect_unchanged("small-unhappy", "the tracked project count",
			_rows(after).size(), SMALL_PROJECTS)


# ---------------------------------------------------------------------------
# Case 4 — large happy (the oracle case)
# ---------------------------------------------------------------------------

func _case_large_happy() -> void:
	print("\n-- large happy: 400 tracked projects, over the control cap --")
	_write_state(_entries(LARGE_PROJECTS, false), [])
	var cap: int = load(PANEL_BROKER_PATH).MAX_PAYLOAD_BYTES
	var request := {}
	var envelope: Dictionary = await _send(LIST_CHANNEL, request, LIST_TIMEOUT_MS)
	var weighed: Dictionary = guard.weigh("large-happy", request, envelope,
			"control cap %d B" % cap)
	guard.check("large-happy: the request that goes out is far under the control "
			+ "cap — the reply is what is on trial",
			int(weighed["request_bytes"]) < cap,
			"request=%d cap=%d" % [int(weighed["request_bytes"]), cap])
	guard.check("large-happy: the reply really is over the control cap",
			int(weighed["reply_bytes"]) > cap,
			"reply=%d cap=%d" % [int(weighed["reply_bytes"]), cap])
	guard.expect_not_oversize_refusal("large-happy", envelope)
	guard.expect_success("large-happy", envelope)

	var rows: Array = _rows(envelope)
	guard.check_eq("large-happy: the reply carries one row per tracked project",
			rows.size(), LARGE_PROJECTS)
	_happy_row_keys = (rows[0] as Dictionary).keys() if not rows.is_empty() else []
	_happy_row_keys.sort()
	guard.check_eq("large-happy: the panel draws every row the worker sent",
			await _drawn_rows(), LARGE_PROJECTS)


# ---------------------------------------------------------------------------
# Case 5 — large unhappy (see THE KNOWN RED in the class doc)
# ---------------------------------------------------------------------------

## A state file the plugin cannot parse is the malformed large document. Both
## assertions state the contract, not the behaviour:
##
##   * a document that cannot be read is a refusal, never an empty document —
##     "you have no projects" is the one answer that is worse than an error,
##     because a reader acts on it;
##   * and it is never REWRITTEN — the unreadable file is the only copy of what
##     was tracked, so overwriting it with a fresh empty state destroys the
##     tracked set outright.
##
## Measured against the real binary today: the reply is a success carrying zero
## rows, and the file is overwritten. Both assertions fail until load_state
## stops swallowing the parse error.
func _case_large_unhappy() -> void:
	print("\n-- large unhappy: a malformed state file holding 400 projects --")
	_corrupt_state()
	var envelope: Dictionary = await _send(LIST_CHANNEL, {}, LIST_TIMEOUT_MS)
	guard.weigh("large-unhappy", {}, envelope)
	guard.check("large-unhappy: a document the plugin cannot read is refused, "
			+ "never reported as an empty Drive",
			not (bool(envelope.get("success", false)) and _rows(envelope).is_empty()),
			ContractGuard.brief(envelope, 400))
	guard.check("large-unhappy: the unreadable document is left on disk, not "
			+ "overwritten with an empty one",
			_state_text() == _corrupt_text(),
			"state file now: %s" % _state_text().left(200))


# ---------------------------------------------------------------------------
# Case 6 — the large-with-errors reply (drive's declared lane)
# ---------------------------------------------------------------------------

## Every one of the 400 projects is in an unhappy status at once — the reply
## that says "nothing here is safe". drive's lane is that this reply is the SAME
## SHAPE as the happy one: a row carries a status word and no error text, so the
## bad news costs five characters a row rather than a payload. The declaration
## is measured (both weights ride the Results line) and pinned by the row-shape
## comparison, so adding a per-row error field forces a deliberate re-declaration
## rather than quietly crossing a host boundary.
func _case_large_error_reply() -> void:
	print("\n-- large-with-errors reply: 400 projects, every one of them behind --")
	_write_state(_entries(LARGE_PROJECTS, true), _tracked_paths(LARGE_PROJECTS))
	var cap: int = load(PANEL_BROKER_PATH).MAX_PAYLOAD_BYTES
	var envelope: Dictionary = await _send(LIST_CHANNEL, {}, LIST_TIMEOUT_MS)
	var weighed: Dictionary = guard.weigh("large-errors", {}, envelope,
			"control cap %d B" % cap)
	guard.expect_not_oversize_refusal("large-errors", envelope)
	guard.expect_success("large-errors", envelope)

	var rows: Array = _rows(envelope)
	var wrong: Array = []
	for row in rows:
		if str((row as Dictionary).get("status", "")) != UNHAPPY_STATUS:
			wrong.append(str((row as Dictionary).get("status", "")))
	guard.check("large-errors: every row reports the unhappy status (%d rows)"
			% rows.size(),
			rows.size() == LARGE_PROJECTS and wrong.is_empty(),
			"other statuses seen: %s" % str(wrong).left(200))

	var keys: Array = (rows[0] as Dictionary).keys() if not rows.is_empty() else []
	keys.sort()
	guard.check("large-errors: an unhappy row is the same shape as a happy one — "
			+ "drive carries no per-row error payload",
			keys == _happy_row_keys,
			"unhappy=%s happy=%s" % [str(keys), str(_happy_row_keys)])
	guard.check("large-errors: the all-bad-news reply crosses the same control "
			+ "boundary the happy one does (%d B vs cap %d B)"
			% [int(weighed["reply_bytes"]), cap],
			int(weighed["reply_bytes"]) > cap)


# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------

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
		var stop_result: Dictionary = await _pm.stop_plugin("drive")
		guard.check("teardown: the backend stops", bool(stop_result.get("ok", false)),
				str(stop_result))
		if _owns_pm and is_instance_valid(_pm):
			if _pm.get_parent() != null:
				_pm.get_parent().remove_child(_pm)
			_pm.free()
		_pm = null


# ---------------------------------------------------------------------------
# Fixtures — a scratch Drive folder, written here, removed at the end
# ---------------------------------------------------------------------------

func _prepare_scratch() -> void:
	_scratch_folder = OS.get_user_data_dir().path_join("drive_contract_guard")
	DirAccess.make_dir_recursive_absolute(_scratch_folder.path_join("tracked"))
	# Exported before the backend starts, so the subprocess inherits it. The
	# status round trip in the mount proves the subprocess actually saw it.
	OS.set_environment("DRIVE_FOLDER", _scratch_folder)


## Registered entries alone produce list rows: the status walk reports a row per
## entry whether or not its local path exists. `with_files` additionally writes
## each entry's file and registers its path as tracked, which makes every row
## report the unhappy status — the recorded hash is all zeroes and cannot match
## what is on disk.
func _entries(count: int, with_files: bool) -> Dictionary:
	var entries := {}
	for i in range(count):
		var name := "%s%03d.mnrv" % [FIXTURE_NAME_PREFIX, i]
		var path := _scratch_folder.path_join("tracked").path_join(name)
		if with_files:
			var f := FileAccess.open(path, FileAccess.WRITE)
			if f != null:
				f.store_string("contract guard fixture")
				f.close()
		entries[path] = {
			"proj_uuid": "00000000-0000-4000-8000-%012d" % i,
			"name": name,
			"base_version": 1,
			"base_hash": "0".repeat(64),
		}
	return entries


func _tracked_paths(count: int) -> Array:
	var out: Array = []
	for i in range(count):
		out.append(_scratch_folder.path_join("tracked").path_join(
				"%s%03d.mnrv" % [FIXTURE_NAME_PREFIX, i]))
	return out


func _write_state(entries: Dictionary, tracked: Array) -> void:
	var state := {
		"device_id": "drive-contract-guard",
		"entries": entries,
		"tracked": tracked,
		"drive_folder_override": "",
	}
	var f := FileAccess.open(_state_path(), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(state))
		f.close()


func _state_path() -> String:
	return _scratch_folder.path_join(".drive-state.json")


func _state_text() -> String:
	return FileAccess.get_file_as_string(_state_path())


## The malformed document: valid-looking, unparseable, and holding what the 400
## entries were — so what is destroyed by a silent reset is visible in the file
## itself.
func _corrupt_text() -> String:
	return "{ \"device_id\": \"drive-contract-guard\", \"entries\": { TRUNCATED"


func _corrupt_state() -> void:
	var f := FileAccess.open(_state_path(), FileAccess.WRITE)
	if f != null:
		f.store_string(_corrupt_text())
		f.close()


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


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

## The panel's own send seam, so every case rides the same broker, backend and
## permission checks the production panel does.
func _send(channel: String, payload: Dictionary, timeout_ms: int) -> Dictionary:
	return await _panel._send_request(
			_panel.get_node_or_null("_MinervaIPC"), channel, payload, timeout_ms)


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


func _rows(envelope: Dictionary) -> Array:
	var projects: Variant = _worker_result(envelope).get("projects", [])
	return projects if projects is Array else []


## The production refresh path — the same call the panel makes on load — and the
## rows it left in the tree.
func _drawn_rows() -> int:
	await _panel._fetch_list()
	await process_frame
	var tree: Tree = _panel._project_tree
	if tree == null or tree.get_root() == null:
		return -1
	return tree.get_root().get_children().size()
