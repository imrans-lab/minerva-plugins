extends SceneTree
## council's CONTRACT GUARD — six domain-defined cases through the real host chain.
##
## WHY THIS SUITE EXISTS
##
## The host bounds an ordinary scene-panel message at
## PluginScenePanelBroker.MAX_PAYLOAD_BYTES (64 KiB) in both directions, and
## council moves THE WHOLE DOCUMENT in one message: the snapshot goes out on
## every seed and comes back on every export. So council is the plugin whose
## LARGE side is the REQUEST — a transcript of any real length is already past
## the control lane before a single reply is weighed.
##
##   1. null / empty document   — an empty snapshot is refused, and the engine
##                                keeps holding the document it had
##   2. small happy             — a two-run transcript seeds the engine
##   3. small unhappy           — a command written against a stale revision is
##                                refused `stale_revision`, and nothing moves
##   4. large happy             — a 61-run transcript, a request OVER the
##                                control cap, seeded whole
##   5. large unhappy           — a transcript past council's OWN declared
##                                document budget: refused by the engine, with
##                                the loaded document untouched
##   6. large-with-errors reply — the same 61-run transcript with every run
##                                invalid: the refusal carries a complaint list
##                                that outweighs the clean load's reply
##
## council's own definition of LARGE is TRANSCRIPT LENGTH. Measured against the
## real binary over stdio: a 61-run transcript weighs 217,444 bytes on the wire
## (3.3x the control cap) and seeds in a 239-byte reply; the same transcript
## with every run's status invalid is refused in 878 bytes of complaints — 3.7x
## the clean reply, for the identical document. That ratio is what case 6 pins.
## A 341-run transcript weighs 1,189,884 bytes, 13% past the document budget,
## which is case 5.
##
## COUNCIL'S DECLARED LANE, which case 5 holds: the document is bounded at
## MaxEnvelopeBytes (internal/session/envelope.go — 1 MiB, sized to leave room
## inside the host's 8 MiB bulk envelope), and a transcript past it is REFUSED
## by name with the numbers in the message, never truncated and never partially
## loaded. The complaint list of case 6 is bounded too: the validator reports a
## capped selection rather than one line per fault, so council's unhappy reply
## grows with the faults but can never outgrow its own document budget.
##
## THE RIG is test_council_panel.gd's, because it is the one that works: a real
## PluginDefinition from the real manifest, the real PluginScenePanelBroker and
## PluginScenePanelHost, the real council-plugin binary over a real
## MCPServerConnection, and only the plugin REGISTRY between them stubbed (the
## host's own manager would start a second runtime for the same plugin id).
## Every host script is loaded at RUN time by path and none is named as a type —
## see that suite's long note on the two-pass compile; one static reference
## anywhere reinstates the whole cascade.
##
## ORACLE: revert council's bulk send seam (CouncilBackend._send preferring
## MinervaIPC.request_bulk) and cases 4, 5 and 6 go red with payload_too_large —
## all three documents are past the control lane on the way OUT — while cases 1,
## 2 and 3 stay green, because an empty snapshot, a two-run transcript and a
## refused command all fit it many times over.
##
## SETUP: council-plugin must be built — (cd council && go build -o
## council-plugin ./) — and the Minerva checkout needs its GDExtensions built,
## like every suite that starts a real plugin subprocess. Without the binary the
## live cases fail by name rather than skipping.
##
## Run: scripts/run-gd-tests.sh --plugin council <path-to-minerva-checkout>

const ContractGuard := preload("res://../../minerva-plugins/scripts/contract_guard.gd")

const PLUGIN_DIR := "res://../../minerva-plugins/council"
const MANIFEST_PATH := PLUGIN_DIR + "/manifest.json"
const FIXTURE_PATH := PLUGIN_DIR + "/fixtures/project_snapshot.json"

## Host scripts, loaded at RUN time by path. See the class doc.
const MCP_CONNECTION_PATH := "res://Scripts/Services/MCP/MCPServerConnection.gd"
const PLUGIN_DEFINITION_PATH := "res://Scripts/Services/Plugins/PluginDefinition.gd"
const SCENE_PANEL_HOST_PATH := "res://Scripts/Services/Plugins/PluginScenePanelHost.gd"
const SCENE_PANEL_BROKER_PATH := "res://Scripts/Services/Plugins/PluginScenePanelBroker.gd"

const PLUGIN_ID := "council"
const PANEL_NAME := "council_panel"
const PANEL_KEY := "council_panel#guard"

const LOAD_CHANNEL := "minerva_council_load_snapshot"
const COMMAND_CHANNEL := "minerva_council_command"

## council's unit of large: runs of transcript. 60 padded runs beside the
## fixture's own is 217 KB — comfortably past the control lane while staying far
## inside the document budget. 340 is 1.19 MB, past the budget, which is case 5.
const LARGE_RUNS := 60
const SMALL_RUNS := 2
const OVER_BUDGET_RUNS := 340
const RUN_TEXT_PAD := 2000

## Mirrors internal/session/envelope.go MaxEnvelopeBytes — council's OWN bound
## on a document, not the host's. Case 5 builds a transcript past it, so a drift
## between the two numbers shows up here as a case that no longer proves what it
## says rather than as a silent pass.
const COUNCIL_DOCUMENT_BUDGET_BYTES := 1 << 20

## The refusal code council mints for a command written against a revision that
## has moved. Named, not sniffed: it is one of the Failure enum's own values.
const CODE_STALE := "stale_revision"
## Where council keeps a command refusal's code.
const REPLY_CODE_KEYS: Array[String] = ["error.code"]

const HOP_TIMEOUT_MS := 120000

var guard := ContractGuard.new()
var _vbox: Control = null
var _panel: Control = null
var _broker = null
var _manager = null
var _conn = null
var _host_script = null
var _singleton: Node = null
var _saved_plugin_manager = null
var _saved_panel_broker = null
## The project identity the last successful load put in the engine — every
## refusal after it is weighed against this.
var _held_project := ""


## Enough of an Editor for PluginScenePanelHost._build_ctx.
class FakeEditor extends RefCounted:
	var associated_object = null


## The plugin registry the host resolves the panel through. `def` is a REAL
## PluginDefinition; only the lookup around it is local to this suite.
class StubDB extends RefCounted:
	var def = null
	func get_by_id(id: String):
		return def if def != null and def.id == id else null


class StubManager extends RefCounted:
	var db = null
	var conn = null
	func get_db():
		return db
	func get_connection(_plugin_id: String):
		return conn
	func get_live_panels(_plugin_id: String) -> Array:
		return [{"panel_key": PANEL_KEY}]
	## The host calls this on whatever plugin_manager it finds at process exit;
	## without it the run ends in a script error even when every assertion passed.
	func shutdown_all() -> void:
		pass


## Stands in for the SingletonObject autoload only when the host has none.
class StubSingleton extends Node:
	var plugin_manager = null
	var plugin_scene_panel_broker = null


func _init() -> void:
	print("=== Council contract guard — six cases through the real host chain ===\n")
	await process_frame

	if await _setup():
		# Order matters: the small happy case seeds the engine, and every
		# refusal after it is weighed against the document it left standing.
		await _case_small_happy()
		await _case_null_document()
		await _case_small_unhappy()
		await _case_large_happy()
		await _case_large_unhappy()
		await _case_large_error_reply()
	_cleanup()
	await process_frame
	quit(guard.results())


# ---------------------------------------------------------------------------
# Setup — real definition, real broker, real host mount, real backend
# ---------------------------------------------------------------------------

func _setup() -> bool:
	var definition_script: GDScript = load(PLUGIN_DEFINITION_PATH)
	var broker_script: GDScript = load(SCENE_PANEL_BROKER_PATH)
	_host_script = load(SCENE_PANEL_HOST_PATH)
	if not guard.check("setup: the host's scene-panel scripts load and compile",
			definition_script != null and broker_script != null and _host_script != null):
		return false

	var def = definition_script.from_manifest(MANIFEST_PATH)
	if not guard.check("setup: the manifest parses into a PluginDefinition", def != null,
			MANIFEST_PATH):
		return false
	# The broker only dispatches to a RUNNING plugin; the connection below is
	# the process that makes that true. The enum is read off the script's
	# constant map because the class is not named here.
	var states: Dictionary = definition_script.get_script_constant_map().get("State", {})
	if not states.has("RUNNING"):
		printerr("  PluginDefinition no longer declares a RUNNING state")
		return false
	def.state = int(states["RUNNING"])

	var db := StubDB.new()
	db.def = def
	var manager := StubManager.new()
	manager.db = db
	_manager = manager
	_broker = broker_script.new(manager, null, null, null)

	_singleton = root.get_node_or_null("SingletonObject")
	if _singleton == null:
		_singleton = StubSingleton.new()
		_singleton.name = "SingletonObject"
		root.add_child(_singleton)
	# Point the host at this suite's registry, remembering what was there: the
	# autoload starts real plugins of its own and must be able to stop them.
	_saved_plugin_manager = _singleton.get("plugin_manager")
	_saved_panel_broker = _singleton.get("plugin_scene_panel_broker")
	_singleton.set("plugin_manager", manager)
	_singleton.set("plugin_scene_panel_broker", _broker)

	_conn = await _start_backend()
	manager.conn = _conn
	if not guard.check("setup: the council-plugin binary is built and speaking",
			_conn != null and _conn.server_connected,
			"build it first: (cd council && go build -o council-plugin ./)"):
		return false

	_vbox = Control.new()
	root.add_child(_vbox)
	_panel = _host_script.instantiate_into(
			_vbox, PLUGIN_ID, PANEL_NAME, FakeEditor.new(), PANEL_KEY)
	var helper: Node = _panel.get_node_or_null("_MinervaIPC") if _panel != null else null
	if not guard.check("setup: the panel mounts and the host offers the bulk route "
			+ "the large cases ride",
			helper != null and helper.has_method("request_bulk"),
			"panel=%s helper=%s" % [str(_panel), str(helper)]):
		return false
	return true


func _start_backend():
	var binary := ProjectSettings.globalize_path(PLUGIN_DIR).path_join("council-plugin")
	if not FileAccess.file_exists(binary):
		return null
	var transport: Script = load(MCP_CONNECTION_PATH)
	if transport == null:
		return null
	var conn = transport.new("council-guard")
	# The connection carries the plugin id into every notification it routes.
	conn.plugin_id = PLUGIN_ID
	conn.configure_stdio(binary, PackedStringArray())
	# connect_to_server awaits its transport; calling it without await hands
	# back a coroutine state, not an Error.
	if await conn.connect_to_server() != OK:
		return null
	return conn


# ---------------------------------------------------------------------------
# Case 2 — small happy (runs first: it seeds the document every refusal is
# weighed against)
# ---------------------------------------------------------------------------

func _case_small_happy() -> void:
	print("\n-- small happy: a two-run transcript seeds the engine --")
	var record := _transcript(SMALL_RUNS, RUN_TEXT_PAD, false, "prj-guard-small")
	var envelope: Dictionary = await _load(record)
	guard.expect_success("small-happy", envelope)
	var body: Dictionary = _body(envelope)
	guard.check("small-happy: the engine accepted the transcript and named it",
			bool(body.get("ok", false)) and str(body.get("project_id", "")) == "prj-guard-small",
			ContractGuard.brief(body))
	_held_project = await _loaded_project()
	guard.check_eq("small-happy: the engine is holding that document",
			_held_project, "prj-guard-small")


# ---------------------------------------------------------------------------
# Case 1 — null / empty document
# ---------------------------------------------------------------------------

## An empty snapshot is not a council document: it is refused, and — the half
## that matters — the engine goes on holding the transcript it already had.
## Replacing a real transcript with nothing because nothing was sent is the
## silent empty document this forbids.
func _case_null_document() -> void:
	print("\n-- null/empty document: refused, and the held transcript survives --")
	var envelope: Dictionary = await _load({})
	guard.expect_refusal("null-document", envelope)
	guard.expect_unchanged("null-document", "the document the engine holds",
			await _loaded_project(), _held_project)


# ---------------------------------------------------------------------------
# Case 3 — small unhappy
# ---------------------------------------------------------------------------

## A mutating command written against a revision that has moved. council's own
## refusal, with its own code — the one case here that is refused by the ENGINE
## rather than by the schema, so the reply is a successful transport carrying
## {ok:false, error:{code}}.
func _case_small_unhappy() -> void:
	print("\n-- small unhappy: a command written against a stale revision --")
	var reply: Dictionary = _body(await _command({
		"request_id": "guard-stale",
		"command": "session.create",
		"base_revision": 999999,
		"payload": {"question": "does a stale command move anything?"},
	}))
	var code := guard.expect_refusal("small-unhappy", reply, REPLY_CODE_KEYS)
	guard.check_eq("small-unhappy: the refusal is council's own stale-revision one",
			code, CODE_STALE)
	guard.expect_unchanged("small-unhappy", "the document the engine holds",
			await _loaded_project(), _held_project)


# ---------------------------------------------------------------------------
# Case 4 — large happy (the oracle case)
# ---------------------------------------------------------------------------

## council's large side is the REQUEST: the whole transcript travels out on
## every seed. So the measurement here is the request against the control cap,
## and the bulk route is what carries it.
func _case_large_happy() -> void:
	print("\n-- large happy: a 61-run transcript, past the control lane --")
	var record := _transcript(LARGE_RUNS, RUN_TEXT_PAD, false, "prj-guard-large")
	var cap: int = int(load(SCENE_PANEL_BROKER_PATH).get_script_constant_map()
			.get("MAX_PAYLOAD_BYTES", -1))
	var envelope: Dictionary = await _load(record)
	var weighed: Dictionary = guard.weigh("large-happy", {"snapshot": record}, envelope,
			"control cap %d B" % cap)
	guard.check("large-happy: the transcript that goes out really is over the "
			+ "control cap — the request is what is on trial",
			int(weighed["request_bytes"]) > cap,
			"request=%d cap=%d" % [int(weighed["request_bytes"]), cap])
	guard.expect_not_oversize_refusal("large-happy", envelope)
	guard.expect_success("large-happy", envelope)
	var body: Dictionary = _body(envelope)
	guard.check("large-happy: the engine accepted the whole transcript",
			bool(body.get("ok", false)) and str(body.get("project_id", "")) == "prj-guard-large",
			ContractGuard.brief(body))
	_held_project = await _loaded_project()
	guard.check_eq("large-happy: the engine is holding that document",
			_held_project, "prj-guard-large")


# ---------------------------------------------------------------------------
# Case 5 — large unhappy (council's declared document budget)
# ---------------------------------------------------------------------------

## A transcript past council's OWN bound. The host would carry it — the bulk
## envelope is eight times bigger — so what refuses it is the plugin's declared
## contract, which is exactly what this case exists to pin: over-budget is
## REFUSED, never truncated, and never partially applied.
func _case_large_unhappy() -> void:
	print("\n-- large unhappy: a transcript past council's own document budget --")
	var record := _transcript(OVER_BUDGET_RUNS, RUN_TEXT_PAD, false, "prj-guard-over")
	var envelope: Dictionary = await _load(record)
	var weighed: Dictionary = guard.weigh("large-unhappy", {"snapshot": record}, envelope,
			"council document budget %d B" % COUNCIL_DOCUMENT_BUDGET_BYTES)
	guard.check("large-unhappy: the fixture really is past council's document "
			+ "budget (%d B)" % int(weighed["request_bytes"]),
			int(weighed["request_bytes"]) > COUNCIL_DOCUMENT_BUDGET_BYTES,
			"request=%d budget=%d" % [
				int(weighed["request_bytes"]), COUNCIL_DOCUMENT_BUDGET_BYTES])
	guard.expect_not_oversize_refusal("large-unhappy", envelope)
	guard.expect_refusal("large-unhappy", envelope)
	guard.expect_unchanged("large-unhappy", "the document the engine holds",
			await _loaded_project(), _held_project)


# ---------------------------------------------------------------------------
# Case 6 — the large-with-errors reply
# ---------------------------------------------------------------------------

## The same 61-run transcript with every run's status outside the enum. What
## comes back is a complaint list, and it is the biggest reply this guard sees
## for a document the engine did not even accept — the unhappy answer to a large
## document costs more than the happy one, which is the boundary a clean-only
## suite never reaches.
func _case_large_error_reply() -> void:
	print("\n-- large-with-errors reply: 61 invalid runs, one complaint list --")
	var record := _transcript(LARGE_RUNS, RUN_TEXT_PAD, true, "prj-guard-large-bad")
	var envelope: Dictionary = await _load(record)
	guard.weigh("large-errors", {"snapshot": record}, envelope)
	guard.expect_not_oversize_refusal("large-errors", envelope)
	guard.expect_refusal("large-errors", envelope)

	var errors_bytes := guard.reply_bytes("large-errors")
	var clean_bytes := guard.reply_bytes("large-happy")
	guard.check("large-errors: the complaint reply outweighs the clean load's "
			+ "reply for the same document (%d B vs %d B)" % [errors_bytes, clean_bytes],
			errors_bytes > clean_bytes and clean_bytes > 0)
	guard.expect_unchanged("large-errors", "the document the engine holds",
			await _loaded_project(), _held_project)


# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

func _cleanup() -> void:
	if _panel != null and is_instance_valid(_panel):
		if _broker != null:
			_broker.unregister_panel(PLUGIN_ID, PANEL_KEY)
		_panel.queue_free()
		_panel = null
	if _vbox != null and is_instance_valid(_vbox):
		_vbox.queue_free()
		_vbox = null
	if _conn != null:
		guard.check("teardown: the backend connection closes",
				_conn.has_method("disconnect_from_server"), str(_conn))
		if _conn.has_method("disconnect_from_server"):
			_conn.disconnect_from_server()
		_conn = null
	# The host's own registry goes back before the process exits, or the host
	# shuts down against the stand-in and never stops the plugins it started.
	if _singleton != null and is_instance_valid(_singleton):
		_singleton.set("plugin_manager", _saved_plugin_manager)
		_singleton.set("plugin_scene_panel_broker", _saved_panel_broker)


# ---------------------------------------------------------------------------
# Fixtures — built from the checked-in worked example
# ---------------------------------------------------------------------------

## The checked-in fixture with `runs` extra runs appended to its session. Using
## the fixture as the prototype means this suite cannot drift into asserting
## against a record shape the engine would refuse — the Go contract tests
## validate that file against the schemas.
##
## Every appended run gets its own run, contribution and claim identities (a
## repeated claim id is itself a refusal), and its contribution text is padded
## to `pad` so the transcript's length is the only thing that grows. The
## fixture's OWN first run is kept as the session's first, because the session's
## outcomes name it.
##
## `broken` puts every appended run's status outside the enum — one complaint
## per run, which is case 6's whole subject.
func _transcript(runs: int, pad: int, broken: bool, project_id: String) -> Dictionary:
	var record: Dictionary = _parse(FileAccess.get_file_as_string(FIXTURE_PATH))
	var session: Dictionary = (record.get("sessions", []) as Array)[0]
	var proto: Dictionary = (session.get("runs", []) as Array)[0]
	var out: Array = [proto.duplicate(true)]
	for i in range(runs):
		var run: Dictionary = proto.duplicate(true)
		run["run_id"] = "run-guard-%03d" % i
		run["request_id"] = "req-guard-%03d" % i
		var contributions: Array = run.get("contributions", [])
		for j in range(contributions.size()):
			var contribution: Dictionary = contributions[j]
			contribution["contribution_id"] = "con-guard-%03d-%d" % [i, j]
			var claims: Array = contribution.get("claims", [])
			for k in range(claims.size()):
				(claims[k] as Dictionary)["claim_id"] = "clm-guard-%03d-%d-%d" % [i, j, k]
			if not str(contribution.get("text", "")).is_empty():
				contribution["text"] = "x".repeat(pad)
		if broken:
			run["status"] = "not-a-status"
		out.append(run)
	session["runs"] = out
	record["sessions"] = [session]
	record["project_id"] = project_id
	record.erase("view")
	return record


func _parse(text: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

## One seed, on the route CouncilBackend._send takes for this channel: the
## host's bulk lane, through the real broker, to the real backend. Returns the
## raw envelope so it can be weighed before anything unwraps it.
func _load(record: Dictionary) -> Dictionary:
	var helper: Node = _panel.get_node_or_null("_MinervaIPC")
	return await helper.request_bulk(
			LOAD_CHANNEL, {"snapshot": record, "mode": "replace"}, HOP_TIMEOUT_MS)


## One protocol command, same route.
func _command(request: Dictionary) -> Dictionary:
	var helper: Node = _panel.get_node_or_null("_MinervaIPC")
	return await helper.request_bulk(COMMAND_CHANNEL, request, HOP_TIMEOUT_MS)


## The backend's own payload inside the host's scene envelope.
func _body(envelope: Dictionary) -> Dictionary:
	var inner: Variant = envelope.get("result", null)
	return inner if inner is Dictionary else {}


## Which document the engine is holding right now, read back through the
## protocol rather than remembered — the only way a refusal that quietly
## replaced the document would be visible.
func _loaded_project() -> String:
	var reply: Dictionary = _body(await _command({
		"request_id": "guard-read-%d" % Time.get_ticks_usec(),
		"command": "snapshot.get",
		"payload": {},
	}))
	var payload: Variant = reply.get("payload", {})
	var snapshot: Variant = (payload as Dictionary).get("snapshot", {}) \
			if payload is Dictionary else {}
	return str((snapshot as Dictionary).get("project_id", "")) if snapshot is Dictionary else ""
