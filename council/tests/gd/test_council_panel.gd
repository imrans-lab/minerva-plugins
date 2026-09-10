extends SceneTree
## Council's native panel, driven through the host paths that actually mount and
## persist it — PluginScenePanelHost, PluginScenePanelBroker, and the real
## council-plugin backend over stdio.
##
## WHAT EACH SECTION'S ORACLE IS, because "it passed" is not a result unless the
## thing that decided is named:
##
##   1 MOUNT — the oracle is the HOST. PluginDefinition.from_manifest parses
##     council/manifest.json, and PluginScenePanelHost.instantiate_into resolves
##     the entry scene, preloads every declared script, audits the PackedScene
##     against that whitelist and registers with the broker. A manifest that
##     names a script the scene does not use, or a scene that pulls one the
##     manifest does not declare, produces a placeholder Control here — so the
##     assertion "the mounted root implements the save hook" is a manifest test,
##     not a smoke test.
##
##   2 SAVE / RELOAD — the oracle is Editor.gd's own serializer. The suite
##     stringifies the save payload exactly as the host's PLUGIN_SCENE
##     host_owned branch does (JSON.stringify(payload, "\\t")) and re-opens it in
##     the document shape Editor.gd._load_plugin_scene_file builds. Byte-for-byte
##     means the two strings are identical, with a control that the record is
##     not empty so an empty-vs-empty comparison cannot pass.
##
##   3 UNREADABLE DOCUMENTS — the oracle is the file on disk. Whatever the panel
##     was given back has to be the same bytes the file held, through both the
##     file path and the project's __panel_state path.
##
##   4 NOTE — the oracle is Note.create_plugin_data_note, whose JSON.stringify →
##     JSON.parse wrapper the suite reproduces before restoring, so a value JSON
##     cannot carry fails here rather than in a user's project.
##
##   5 ENVELOPE SIZE — the oracle is the host's own constant. The suite reads
##     PluginScenePanelBroker.MAX_PAYLOAD_BYTES and measures what the wrapper
##     will really hand the broker, wrapper keys included. The interesting case
##     is a record that fits the cap on its own and does NOT fit once wrapped:
##     that message is exactly the one a payload-only check would have passed and
##     the broker would then have dropped.
##
##   6 TWO PROJECTS, ONE STORE — the oracle is the real backend. One
##     council-plugin process holds exactly one snapshot, so two panels showing
##     two projects share it. The suite mounts two panels, gives each its own
##     record, and drives real session.bind_chat mutations through the real
##     transport, asserting that neither record ever contains the other's
##     session and that a panel cannot mutate a session it does not hold.
##
## WHAT IS A STAND-IN AND WHY. The plugin REGISTRY is: a duck-typed manager whose
## db returns a real PluginDefinition parsed from the real manifest, and whose
## connection is a real MCPServerConnection to the real backend binary. The
## alternative is PluginManager.install_plugin, which writes Council into the
## user's own Minerva installation and rebuilds its binary as a side effect of
## running a test. Nothing else here is stood in for: the panel, the mount, the
## broker, the IPC helper, the transport and the engine are all the real ones.
##
## SETUP: the backend binary must be built first — section 6 fails by name
## without it:
##   (cd council && go build -o council-plugin ./)
##
## A NOTE ON `--check-only`: it is clean on this file, and that is a consequence
## of the rule above rather than a coincidence. The suite names no host script
## statically, so check-only compiles this file alone and never follows the
## broker chain — which means a green check-only says the SUITE parses and says
## nothing at all about the host scripts it loads at run time. The evidence that
## the chain compiles is execution, not this gate.
##
## HARNESS NOISE THIS SUITE PRODUCES, and why none of it is allowlisted: loading
## Minerva's autoload in a headless script run prints four "Node not found"
## engine errors from singleton_object.gd's @onready paths into a UI tree that
## does not exist (:1590, :1789, :1825, :2152), plus CEF startup chatter and
## RID-leak warnings at exit. They are `ERROR:` lines, not `SCRIPT ERROR:` or
## `ERROR: Failed to load script`, so the runner's fatal-diagnostic scan does not
## see them, and nothing here depends on the nodes they name. Allowlisting them
## would only make the allowlist a place where real diagnostics could hide.
##
## Run:
##   council/scripts/run-gd-tests.sh <path-to-minerva-checkout>

const PLUGIN_DIR := "res://../../minerva-plugins/council"
const MANIFEST_PATH := PLUGIN_DIR + "/manifest.json"
const FIXTURE_PATH := PLUGIN_DIR + "/fixtures/project_snapshot.json"
## The populated worked example: two rounds, two non-human advisors, the council
## a person opens in the live check. Section 8 needs a run whose seats a retry
## may actually re-ask, which the smaller fixture's human seat cannot give.
const POPULATED_FIXTURE_PATH := PLUGIN_DIR + "/fixtures/workshop_complete.mcouncil"
## A document in the shape Council wrote before the record carried a schema
## version or a project identity. Section 7 opens it for real.
const OLDER_FIXTURE_PATH := PLUGIN_DIR + "/fixtures/migrations/snapshot_v0_pre_project_identity.json"
## The record class itself, loaded at run time in section 11 so the derivation
## can be exercised without a panel around it.
const RECORD_SCRIPT_PATH := PLUGIN_DIR + "/ui/council_record.gd"
## What section 11 reads out of the worked example, named here so a fixture that
## changes shape fails the section's SETUP assertion by name instead of quietly
## weakening every assertion after it. `con-3` and `con-5` are the two rounds'
## syntheses, which the derivation treats as contributions of the chair's seat.
const CONTEXT_SESSION := "ses-recurring-order"
const COMPLETE_IDS := ["con-1", "con-3", "con-4", "con-5"]
const INCOMPLETE_ID := "con-2"
## Text put into that incomplete contribution to build section 11's VARIANT of
## the fixture. The shipped one has no text at all, so in it "left out because it
## is not complete" and "left out because there is nothing to quote" are the same
## outcome; giving it words separates them.
const UNFINISHED_TEXT := "The capacity seat never finished saying this."
## What `{"snapshot": …}` costs in the serialised form: 12 characters of key and
## colon plus the closing brace. It is the whole point of measuring the message
## rather than the record.
const WRAPPER_OVERHEAD := 13
const PANEL_NAME := "council_panel"
const PLUGIN_ID := "council"

const CouncilBackend := preload("res://../../minerva-plugins/council/ui/council_backend.gd")

## EVERY host script is loaded at RUN time, by path, and none is named as a type.
##
## This is not style. `godot --script` compiles a suite TWICE, and the first pass
## runs BEFORE the autoloads register. Anything the suite names statically — a
## preload, or merely typing a variable with a host class_name — is compiled in
## that pass, along with everything it depends on; and PluginScenePanelBroker
## reaches CapabilityBroker.gd:541 and MCPServerConnection.gd:84, both of which
## name the `SingletonObject` identifier. Those fail, the failure is CACHED, and
## the damage is not confined to the suite: a poisoned run shows the
## host's own `initialize_plugins` (singleton_object.gd:567) then dying with
## "Nonexistent function 'new' in base 'GDScript'", and every later `load()` of
## the same path handing back the already-failed script.
##
## Loading at run time is enough on its own, because by then the autoloads exist
## and nothing has poisoned the cache — but only if the suite is clean in BOTH
## directions: one static reference anywhere reinstates the whole cascade.
## Deliberately NOT ResourceLoader.CACHE_MODE_IGNORE: that would compile a second
## copy of the broker with its own script identity, and PluginScenePanelHost
## casts what it finds with `as PluginScenePanelBroker`, which the copy would
## fail — the panel would then mount with no broker at all.
##
## cad/tests/gd/test_mcp_boundary.gd:29-35 carries the same note for
## PluginToolRegistry, and loads it the same way.
const MCP_CONNECTION_PATH := "res://Scripts/Services/MCP/MCPServerConnection.gd"
const PLUGIN_DEFINITION_PATH := "res://Scripts/Services/Plugins/PluginDefinition.gd"
const SCENE_PANEL_HOST_PATH := "res://Scripts/Services/Plugins/PluginScenePanelHost.gd"
const SCENE_PANEL_BROKER_PATH := "res://Scripts/Services/Plugins/PluginScenePanelBroker.gd"

const MINERVA_IPC_PATH := "res://Scripts/Services/Plugins/MinervaIPC.gd"
const EVENT_BROKER_PATH := "res://Scripts/Services/Plugins/PluginEventBroker.gd"

## The child node the broker attaches on registration, read off MinervaIPC's
## own constant in _setup (a const initialiser would be a first-pass load).
var _ipc_helper_node: String = ""

var _pass: int = 0
var _fail: int = 0
var _vbox: Control = null
var _panel_a: Control = null
var _panel_b: Control = null
var _broker = null  # PluginScenePanelBroker, loaded at run time (see above)
var _manager = null  # the StubDB/StubManager pair the host resolves the panel through
var _conn = null    # MCPServerConnection, likewise
var _host_script = null  # PluginScenePanelHost, likewise

## What SingletonObject held before the suite pointed it at its own registry, so
## cleanup can put the host's real one back. Without that the host shuts down
## against the stand-in — and never stops the plugins it actually started.
var _saved_plugin_manager = null
var _saved_panel_broker = null
var _singleton: Node = null
var _temp_dir: String = ""
var _emitted_channels: Array[String] = []


## One bind_chat exchange that can be left running. `start()` is called WITHOUT
## await, so it executes up to the exchange's first await and returns; the second
## one then begins while the first is still in flight, which is the only way the
## lease's queue is exercised at all. `settle()` is await-safe either way: a
## call that finished before anyone waited on it does not hang.
class Exchange extends RefCounted:
	signal finished()
	var reply: Dictionary = {}
	var done: bool = false

	func start(suite, panel: Control, session_id: String, chat_id: String) -> void:
		reply = await suite._bind_chat(panel, session_id, chat_id)
		done = true
		finished.emit()

	func settle() -> void:
		if not done:
			await finished


## Enough of an Editor for PluginScenePanelHost._build_ctx, which reads
## `associated_object` and puts the editor itself in ctx.
class FakeEditor extends RefCounted:
	var associated_object = null


## The plugin registry the host resolves the panel through. `def` is a real
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

	## What singleton_object.gd's plugin-event fan-out iterates
	## (_push_to_plugin_panels, singleton_object.gd:745-756). The real manager
	## fills this from panel registration; the suite mounts its two panels by
	## hand, so it names the same two keys.
	func get_live_panels(_plugin_id: String) -> Array:
		return [{"panel_key": "council_panel#a"}, {"panel_key": "council_panel#b"}]

	## The host calls this on whatever plugin_manager it finds when the process
	## exits (singleton_object.gd:1538). Without it the run ends in a script
	## error and a non-zero exit even when every assertion passed. Cleanup puts
	## the real manager back before then; this is the guard for the paths where
	## it cannot (an early quit, a crash between here and there).
	func shutdown_all() -> void:
		pass


## Stands in for the SingletonObject autoload only when the host does not
## provide one (headless runs without autoloads). Carries the two fields
## PluginScenePanelHost reads.
class StubSingleton extends Node:
	var plugin_manager = null
	var plugin_scene_panel_broker = null


func _init() -> void:
	print("=== Council native panel ===\n")
	await process_frame
	_temp_dir = OS.get_user_data_dir().path_join("council_panel_test")
	DirAccess.make_dir_recursive_absolute(_temp_dir)

	if await _setup():
		_section_1_mount()
		_section_2_save_reload()
		_section_3_unreadable()
		_section_4_note()
		await _section_5_envelope_size()
		await _section_6_two_projects()
		await _section_7_migration()
		await _section_8_interrupted_run()
		await _section_9_recovering_a_closed_panel()
		await _section_10_a_change_with_no_panel_in_it()
		await _section_11_the_text_a_session_hands_over()

	_cleanup()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

func _setup() -> bool:
	var definition_script: GDScript = load(PLUGIN_DEFINITION_PATH)
	var broker_script: GDScript = load(SCENE_PANEL_BROKER_PATH)
	_host_script = load(SCENE_PANEL_HOST_PATH)
	var ipc_script: GDScript = load(MINERVA_IPC_PATH)
	_ipc_helper_node = str(ipc_script.get_script_constant_map().get("HELPER_NODE_NAME", "")) if ipc_script != null else ""
	check("setup: the host's scene-panel scripts load and compile",
			definition_script != null and broker_script != null and _host_script != null,
			"definition=%s broker=%s host=%s" % [
				str(definition_script), str(broker_script), str(_host_script)])
	if definition_script == null or broker_script == null or _host_script == null:
		return false

	var def = definition_script.from_manifest(MANIFEST_PATH)
	check("setup: the manifest parses into a PluginDefinition", def != null,
			"PluginDefinition.from_manifest returned null for %s" % MANIFEST_PATH)
	if def == null:
		return false
	# The broker only dispatches to a RUNNING plugin; the connection below is the
	# process that makes that true. The enum is read off the script's constant
	# map because the class is not named here (see the constants above).
	var states: Dictionary = definition_script.get_script_constant_map().get("State", {})
	check("setup: PluginDefinition still declares a RUNNING state",
			states.has("RUNNING"), str(states.keys()))
	if not states.has("RUNNING"):
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
	# autoload starts real plugins of its own and has to be able to shut them
	# down again when the process exits.
	_saved_plugin_manager = _singleton.get("plugin_manager")
	_saved_panel_broker = _singleton.get("plugin_scene_panel_broker")
	_singleton.set("plugin_manager", manager)
	_singleton.set("plugin_scene_panel_broker", _broker)

	# Section 6 attaches the real backend to this same manager.
	_conn = await _start_backend()
	manager.conn = _conn

	_vbox = Control.new()
	root.add_child(_vbox)
	_panel_a = _mount("council_panel#a")
	_panel_b = _mount("council_panel#b")
	return _panel_a != null and _panel_b != null


## Mount one panel the way the host does, under its own per-tab registry key.
func _mount(panel_key: String) -> Control:
	var editor := FakeEditor.new()
	var mounted: Control = _host_script.instantiate_into(
		_vbox, PLUGIN_ID, PANEL_NAME, editor, panel_key)
	if mounted != null and mounted.has_signal("request"):
		mounted.request.connect(func(channel: String, _p: Dictionary, _r: String) -> void:
			_emitted_channels.append(channel))
	return mounted


func _start_backend():
	var binary := ProjectSettings.globalize_path(PLUGIN_DIR).path_join("council-plugin")
	if not FileAccess.file_exists(binary):
		return null
	var transport: Script = load(MCP_CONNECTION_PATH)
	if transport == null:
		return null
	var conn = transport.new("council-test")
	# The connection carries the plugin id into every notification it routes;
	# without it the event broker cannot find the definition and drops the event
	# as an unknown plugin's (MCPServerConnection.gd:73, :984-986).
	conn.plugin_id = PLUGIN_ID
	conn.configure_stdio(binary, PackedStringArray())
	# The backend's own notifications need somewhere to go. MCPServerConnection
	# hands a `minerva/plugin_event` to whatever event_broker it was given
	# (MCPServerConnection.gd:934, :985-988); with none it warns and drops.
	# The broker is the REAL PluginEventBroker over the REAL PluginDefinition,
	# so the manifest's `events` declaration is what decides whether an event
	# name is a declared one.
	var event_broker_script: Script = load(EVENT_BROKER_PATH)
	if event_broker_script != null and _manager != null:
		var events = event_broker_script.new(_manager.get_db(), null)
		events.plugin_event.connect(_fan_out_plugin_event)
		conn.event_broker = events
	# connect_to_server awaits its transport (MCPServerConnection.gd:101-109);
	# calling it without await hands back a coroutine state, not an Error.
	if await conn.connect_to_server() != OK:
		return null
	return conn


## The host's own fan-out, reproduced over this suite's registry: every live
## panel of the plugin gets the push, addressed by its per-tab registration key
## (singleton_object.gd:745-756). The push itself is the REAL broker call, with
## its ownership check and its audit.
func _fan_out_plugin_event(plugin_id: String, event_name: String, payload: Dictionary) -> void:
	if _broker == null or _manager == null:
		return
	for entry in _manager.get_live_panels(plugin_id):
		var panel_key: String = str((entry as Dictionary).get("panel_key", ""))
		if panel_key.is_empty():
			continue
		_broker.push_to_panel(plugin_id, panel_key, event_name, payload)


# ---------------------------------------------------------------------------
# 1. The mount
# ---------------------------------------------------------------------------

func _section_1_mount() -> void:
	print("\n1 mount:")
	# A placeholder Control is what every failure path in instantiate_into
	# returns, and it implements none of the hooks.
	check("the mounted root is the Council panel, not a diagnostic placeholder",
			_panel_a != null and _panel_a.has_method("_on_panel_save_request")
			and _panel_a.has_method("_on_panel_load_request"),
			"mounted %s" % ("null" if _panel_a == null else _panel_a.get_class()))
	check("the broker registered the panel under its own per-tab key",
			_broker.get_panel_owner("council_panel#a") == PLUGIN_ID
			and _broker.get_panel_owner("council_panel#b") == PLUGIN_ID,
			"owners: %s / %s" % [_broker.get_panel_owner("council_panel#a"),
				_broker.get_panel_owner("council_panel#b")])
	check("the broker attached its IPC helper, so the panel can reach the backend",
			_panel_a.get_node_or_null(_ipc_helper_node) != null)

	# A new tab: no file, nothing merged. The panel must open an empty council.
	#
	# It is written at the OLDEST migratable version and carries no project_id:
	# the identity is required by the schema and minted by the engine's
	# migration ladder, so the wrapper declares the version its empty document
	# really is rather than claiming a current one it cannot produce. The first
	# seed migrates it, exactly as it migrates a document written by an older
	# Council (section 7).
	_panel_a._on_panel_load_request({"file_path": ""})
	var fresh: Dictionary = _panel_a._on_panel_save_request()
	check("an empty document opens an empty council the ladder can bring up to date",
			str(fresh.get("record_kind", "")) == "council_project_snapshot"
			and int(fresh.get("schema_version", -1)) == 0
			and not fresh.has("project_id")
			and int(fresh.get("snapshot_revision", 0)) == 1
			and (fresh.get("sessions", []) as Array).is_empty(),
			str(fresh).left(160))


# ---------------------------------------------------------------------------
# 2. Save, reload, byte-for-byte
# ---------------------------------------------------------------------------

func _section_2_save_reload() -> void:
	print("\n2 save and reload:")
	var record: Dictionary = _fixture()
	var path := _temp_dir.path_join("round_trip.mcouncil")

	# Panel A holds the record and saves it exactly as Editor.gd would.
	_panel_a._on_panel_load_request(_document_for(path, record))
	var written := JSON.stringify(_panel_a._on_panel_save_request(), "\t")
	_write(path, written)

	check("control: the saved document is a populated council, not an empty one",
			written.contains("ses-recurring-order") and written.length() > 4000,
			"%d chars" % written.length())

	# Panel B is untouched until this line: everything asserted next came from
	# the file, not from state the first panel left lying around.
	_panel_b._on_panel_load_request(_document_for(path, _parse(written)))
	var reread := JSON.stringify(_panel_b._on_panel_save_request(), "\t")
	check("a saved council reloads and saves again byte-for-byte", reread == written,
			"%d chars in, %d out; first difference at %d" % [
				written.length(), reread.length(), _first_difference(written, reread)])

	# The project lane uses the same hook, and its payload is JSON too.
	var project_state: Dictionary = _parse(JSON.stringify(_panel_b._on_panel_save_request()))
	_panel_a._on_panel_load_request(project_state)
	check("the same record survives the project's __panel_state round trip",
			JSON.stringify(_panel_a._on_panel_save_request(), "\t") == written)


# ---------------------------------------------------------------------------
# 3. A document Council cannot read is preserved, not replaced
# ---------------------------------------------------------------------------

func _section_3_unreadable() -> void:
	print("\n3 unreadable documents:")
	var cases := {
		"prose.mcouncil": "This is not JSON at all.\nIt is someone's notes.\n",
		"other.mcouncil": "{\n\t\"kind\": \"something else\",\n\t\"value\": 42\n}",
		"newer.mcouncil": "{\n\t\"schema_version\": 2,\n\t\"record_kind\": \"council_project_snapshot\"\n}",
	}
	for name in cases:
		var path := _temp_dir.path_join(name)
		var original: String = cases[name]
		_write(path, original)
		_panel_a._on_panel_load_request(_document_from_disk(path))
		var payload: Dictionary = _panel_a._on_panel_save_request()
		var bytes: Variant = payload.get("_bytes", null)
		check("%s: the panel hands the host the original bytes to write back" % name,
				bytes is PackedByteArray
				and (bytes as PackedByteArray).get_string_from_utf8() == original,
				str(payload).left(160))
		check("%s: and the same bytes in the encoding JSON can carry" % name,
				Marshalls.base64_to_raw(str(payload.get("_bytes_base64", "")))
					.get_string_from_utf8() == original,
				str(payload.get("_bytes_base64", "")).left(80))
		check("%s: the panel says why it will not edit the document" % name,
				str(payload.get("_council_unreadable", "")).length() > 20,
				str(payload.get("_council_unreadable", "")))

		# THE PROJECT LANE IS NOT THE FILE LANE. vboxEditor.gd:499 stores this
		# same dictionary as __panel_state and ProjectPackage.gd:303 runs the
		# whole project through JSON.stringify, which serialises a
		# PackedByteArray as a QUOTED STRING of its str() form — it parses back
		# as a String, not as bytes. A restore that only knew the
		# PackedByteArray shape would find nothing here, adopt the wrapper
		# dictionary as "the original document", and overwrite the user's file
		# on the next save. So the round trip is driven for real, and the shape
		# that caused it is pinned rather than assumed.
		var through_project: Dictionary = _parse(JSON.stringify(payload))
		check("%s: JSON does not carry the PackedByteArray — the base64 sibling does" % name,
				not (through_project.get("_bytes", null) is PackedByteArray)
				and through_project.get("_bytes_base64", "") is String
				and str(through_project.get("_bytes_base64", "")).length() > 0,
				"_bytes is %s, _bytes_base64 is %s" % [
					type_string(typeof(through_project.get("_bytes", null))),
					type_string(typeof(through_project.get("_bytes_base64", null)))])
		_panel_b._on_panel_load_request(through_project)
		var after: Variant = _panel_b._on_panel_save_request().get("_bytes", null)
		check("%s: the bytes survive the project round trip" % name,
				after is PackedByteArray
				and (after as PackedByteArray).get_string_from_utf8() == original,
				"got %s" % str(after).left(120))

	# While it holds a document it cannot read, the panel refuses to change
	# anything rather than replacing the file with an empty council.
	var before := _emitted_channels.size()
	_panel_b._on_page_message(JSON.stringify({
		"schema_version": 1, "envelope": "request", "request_id": "refuse-1",
		"command": "session.bind_chat", "base_revision": 1,
		"payload": {"session_id": "ses-recurring-order", "chat_id": "chat-x"}}))
	check("a command against an unreadable document reaches no backend at all",
			_emitted_channels.size() == before,
			"emitted %s" % str(_emitted_channels.slice(before)))
	check("the unreadable document is still the thing that would be saved",
			_panel_b._on_panel_save_request().has("_bytes"))


# ---------------------------------------------------------------------------
# 4. The note round trip
# ---------------------------------------------------------------------------

func _section_4_note() -> void:
	print("\n4 note:")
	var record: Dictionary = _fixture()
	_panel_a._on_panel_load_request(_document_for("", record))
	var saved := JSON.stringify(_panel_a._on_panel_save_request(), "\t")

	var note: Dictionary = _panel_a._on_panel_create_note_request(
		{"plugin_id": PLUGIN_ID, "panel_name": PANEL_NAME, "tab_title": "Council"})
	check("the note is a plugin_data note, which is what can reopen the panel",
			str(note.get("kind", "")) == "plugin_data"
			and str(note.get("plugin_id", "")) == PLUGIN_ID
			and str(note.get("panel_name", "")) == PANEL_NAME,
			str(note).left(160))
	var caption := str(note.get("preview_alt_text", ""))
	check("the caption names the session, since it is the only text a note carries",
			caption.contains("Council session on:") and not caption.contains("\n"),
			caption)

	# Exactly the wrapper Note.create_plugin_data_note writes and reads back.
	var wrapper := JSON.stringify({
		"version": 1, "plugin_id": PLUGIN_ID, "panel_name": PANEL_NAME,
		"payload": note.get("payload", {})})
	var inner: Dictionary = (_parse(wrapper).get("payload", {}) as Dictionary)

	_panel_b._on_panel_load_request({"file_path": ""})
	var restored: Variant = _panel_b._on_panel_restore_from_note(inner)
	check("restore reports success as a plain bool — the hook is not awaited by the host",
			restored is bool and restored == true, str(restored))
	check("the reopened panel holds the same council the note was made from",
			JSON.stringify(_panel_b._on_panel_save_request(), "\t") == saved)

	check("a payload that is not a Council record is refused",
			_panel_b._on_panel_restore_from_note({"kind": "something else"}) == false)
	check("a refused restore leaves the panel's record alone",
			JSON.stringify(_panel_b._on_panel_save_request(), "\t") == saved)


# ---------------------------------------------------------------------------
# 5. The envelope the host will actually measure
# ---------------------------------------------------------------------------

func _section_5_envelope_size() -> void:
	print("\n5 envelope size:")
	# The oracle is still the host's own constant; it is read off the loaded
	# script rather than through the class name, for the reason at the top.
	var cap: int = int(load(SCENE_PANEL_BROKER_PATH).get_script_constant_map()
			.get("MAX_PAYLOAD_BYTES", -1))
	check("the wrapper's ceiling is the host's own constant, not a second opinion",
			CouncilBackend.HOST_IPC_PAYLOAD_LIMIT == cap,
			"wrapper %d, host %d" % [CouncilBackend.HOST_IPC_PAYLOAD_LIMIT, cap])

	# A record that fits the cap on its own and does not fit once the wrapper has
	# put it in the message the broker measures. This is the case a payload-only
	# check passes and the broker then drops.
	var record: Dictionary = _record_sized_just_under(cap)
	var alone := JSON.stringify(record).length()
	var wrapped := CouncilBackend.measure({"snapshot": record})
	check("setup: the fixture landed in the window where the claim is testable",
			alone > cap - WRAPPER_OVERHEAD and alone <= cap,
			"%d is outside (%d, %d]" % [alone, cap - WRAPPER_OVERHEAD, cap])
	check("the record alone fits the host cap", alone <= cap, "%d vs %d" % [alone, cap])
	check("the same record does not fit once it is in the message that travels",
			wrapped > cap, "wrapped %d vs %d (overhead %d)" % [wrapped, cap, wrapped - alone])
	check("every contribution is still within the schema's own field ceiling",
			_longest_contribution(record) <= 32768, "%d" % _longest_contribution(record))

	var backend = CouncilBackend.new(_panel_a, "council_panel#a")
	var before := _emitted_channels.size()
	var outcome: Dictionary = await backend.relay({
		"schema_version": 1, "envelope": "request", "request_id": "too-big",
		"command": "snapshot.get", "payload": {}}, record)
	var reply: Dictionary = outcome.get("reply", {})
	check("an over-cap record is refused with payload_too_large, not dropped",
			bool(reply.get("ok", true)) == false
			and str((reply.get("error", {}) as Dictionary).get("code", "")) == "payload_too_large",
			str(reply).left(200))
	check("nothing was handed to the broker for it to refuse a second time",
			_emitted_channels.size() == before,
			"emitted %s" % str(_emitted_channels.slice(before)))


# ---------------------------------------------------------------------------
# 6. Two projects, one backend store
# ---------------------------------------------------------------------------

func _section_6_two_projects() -> void:
	print("\n6 two projects, one store:")
	check("setup: the council-plugin binary is built and speaking",
			_conn != null and _conn.server_connected,
			"build it first: (cd council && go build -o council-plugin ./)")
	if _conn == null or not _conn.server_connected:
		return

	var record_a: Dictionary = _fixture_as_session("ses-project-a", "Project A question")
	var record_b: Dictionary = _fixture_as_session("ses-project-b", "Project B question")
	_panel_a._on_panel_load_request(_document_for("", record_a))
	_panel_b._on_panel_load_request(_document_for("", record_b))

	var bound_a: Dictionary = await _bind_chat(_panel_a, "ses-project-a", "chat-a")
	check("panel A binds a chat to its own session through the real engine",
			bool(bound_a.get("ok", false)), str(bound_a).left(200))
	check("the engine is loaded with panel A's record",
			CouncilBackend.lease_holder() == "council_panel#a",
			CouncilBackend.lease_holder())

	var intended_view := {"selected_session_id": "ses-project-a"}
	var view_exchange := Exchange.new()
	view_exchange.start(self, _panel_a, "ses-project-a", "chat-a-view")
	await _panel_a._wrapper_command("wrapper.set_view", {"payload": {"view": intended_view}}, "set-view", 1)
	await view_exchange.settle()
	check("engine refresh preserves the wrapper's current view",
			_panel_a._on_panel_save_request().get("view", {}) == intended_view)
	await _bind_chat(_panel_a, "ses-project-a", "chat-a")
	var bound_b: Dictionary = await _bind_chat(_panel_b, "ses-project-b", "chat-b")
	check("panel B binds its own session, which re-seeds the one store",
			bool(bound_b.get("ok", false)), str(bound_b).left(200))
	check("the engine is now loaded with panel B's record",
			CouncilBackend.lease_holder() == "council_panel#b",
			CouncilBackend.lease_holder())

	var after_a: Dictionary = _panel_a._on_panel_save_request()
	var after_b: Dictionary = _panel_b._on_panel_save_request()
	check("panel A kept only its own session, bound to its own chat",
			_session_ids(after_a) == PackedStringArray(["ses-project-a"])
			and _chat_of(after_a, "ses-project-a") == "chat-a",
			"%s / %s" % [str(_session_ids(after_a)), _chat_of(after_a, "ses-project-a")])
	check("panel B kept only its own session, bound to its own chat",
			_session_ids(after_b) == PackedStringArray(["ses-project-b"])
			and _chat_of(after_b, "ses-project-b") == "chat-b",
			"%s / %s" % [str(_session_ids(after_b)), _chat_of(after_b, "ses-project-b")])

	# The sharpest form of the question: B naming A's session by id.
	var trespass: Dictionary = await _bind_chat(_panel_b, "ses-project-a", "chat-b")
	check("a panel cannot mutate a session that is not in its own record",
			bool(trespass.get("ok", true)) == false, str(trespass).left(200))
	check("panel A's chat binding is untouched by the attempt",
			_chat_of(_panel_a._on_panel_save_request(), "ses-project-a") == "chat-a")

	# And A can still speak: the re-seed is what makes that true.
	var reread: Dictionary = await _relay(_panel_a, {
		"schema_version": 1, "envelope": "request", "request_id": "a-reread",
		"command": "snapshot.get", "payload": {}})
	var seen: Dictionary = ((reread.get("payload", {}) as Dictionary).get("snapshot", {}))
	check("the engine serves panel A its own record again, with no trace of B's",
			_session_ids(seen) == PackedStringArray(["ses-project-a"]),
			str(_session_ids(seen)))

	# CONTENTION. Everything above ran one exchange at a time, which is the case
	# the lease is least interesting in. Fired without awaiting between them, B's
	# exchange starts while A's is still in flight and has to queue behind it —
	# and each must still come back holding only its own council.
	var run_a := Exchange.new()
	var run_b := Exchange.new()
	run_a.start(self, _panel_a, "ses-project-a", "chat-a-again")
	run_b.start(self, _panel_b, "ses-project-b", "chat-b-again")
	await run_a.settle()
	await run_b.settle()
	check("two exchanges in flight at once both complete",
			bool(run_a.reply.get("ok", false)) and bool(run_b.reply.get("ok", false)),
			"A=%s B=%s" % [str(run_a.reply).left(120), str(run_b.reply).left(120)])
	check("neither concurrent exchange left the other holding the wrong council",
			_chat_of(_panel_a._on_panel_save_request(), "ses-project-a") == "chat-a-again"
			and _chat_of(_panel_b._on_panel_save_request(), "ses-project-b") == "chat-b-again"
			and _session_ids(_panel_a._on_panel_save_request()) == PackedStringArray(["ses-project-a"])
			and _session_ids(_panel_b._on_panel_save_request()) == PackedStringArray(["ses-project-b"]),
			"A=%s B=%s" % [
				_chat_of(_panel_a._on_panel_save_request(), "ses-project-a"),
				_chat_of(_panel_b._on_panel_save_request(), "ses-project-b")])

	# A THIRD DOCUMENT IN THE SAME PANEL. Opening another council does not close
	# the tab, so the engine may still be holding the one this panel had a moment
	# ago and the holder still names this panel. Unless the load hook gives that
	# claim up, the next exchange skips the seed and answers from the previous
	# document — and the panel adopts that export as its own.
	var record_c: Dictionary = _fixture_as_session("ses-project-c", "Project C question")
	_panel_a._on_panel_load_request(_document_for("", record_c))
	var reread_c: Dictionary = await _relay(_panel_a, {
		"schema_version": 1, "envelope": "request", "request_id": "a-reread-c",
		"command": "snapshot.get", "payload": {}})
	var seen_c: Dictionary = ((reread_c.get("payload", {}) as Dictionary).get("snapshot", {}))
	check("a panel that opens a different document is re-seeded, not answered from the old one",
			_session_ids(seen_c) == PackedStringArray(["ses-project-c"]),
			str(_session_ids(seen_c)))
	check("and the panel still holds the document it was given",
			_session_ids(_panel_a._on_panel_save_request()) == PackedStringArray(["ses-project-c"]),
			str(_session_ids(_panel_a._on_panel_save_request())))

	# AN EXCHANGE OVERTAKEN BY A LOAD. This is the host's ordinary restore order,
	# not an exotic race: Editor._ready loads the file and defers a rehydrate,
	# and vboxEditor._restore_panel_state hands the panel the project's copy a
	# frame later — so an exchange is regularly still in flight when the panel
	# adopts a different document. Its answer describes the document that has
	# gone. It must not be adopted over the new one, and it must not hand off a
	# lease it is still holding.
	# Force the overtaken exchange to seed before it can send its command.
	await _relay(_panel_b, {"schema_version": 1, "envelope": "request",
		"request_id": "b-before-swap", "command": "snapshot.get", "payload": {}})
	var overtaken := Exchange.new()
	overtaken.start(self, _panel_a, "ses-project-c", "chat-c-overtaken")
	var record_d: Dictionary = _fixture_as_session("ses-project-d", "Project D question")
	_panel_a._on_panel_load_request(_document_for("", record_d))
	await overtaken.settle()
	check("an exchange overtaken by a load is refused rather than applied",
			bool(overtaken.reply.get("ok", true)) == false
			and str((overtaken.reply.get("error", {}) as Dictionary).get("code", "")) == "stale_revision",
			str(overtaken.reply).left(200))
	check("the overtaken exchange did not overwrite the freshly opened document",
			_session_ids(_panel_a._on_panel_save_request()) == PackedStringArray(["ses-project-d"]),
			str(_session_ids(_panel_a._on_panel_save_request())))
	var after_swap: Dictionary = await _relay(_panel_a, {
		"schema_version": 1, "envelope": "request", "request_id": "after-seed-swap",
		"command": "snapshot.get", "payload": {}})
	check("a seed overtaken by a load cannot answer later reads from the old document",
			_session_ids(after_swap.get("payload", {}).get("snapshot", {}))
			== PackedStringArray(["ses-project-d"]), str(after_swap).left(300))
	var taker := CouncilBackend.lease_taker()
	check("the lease is free, or held by a panel that is still live",
			taker == ""
			or ((taker == "council_panel#a" or taker == "council_panel#b")
				and is_instance_valid(CouncilBackend.lease_taker_panel())),
			"taken_by=%s panel=%s" % [taker, str(CouncilBackend.lease_taker_panel())])


# ---------------------------------------------------------------------------
# 7. A document written by an older Council
# ---------------------------------------------------------------------------

## The oracle is the engine's migration ladder (internal/contract/migrate.go),
## reached through the real backend: the panel does not migrate anything, it
## opens the older document, hands it over, and persists what comes back. What
## is asserted here is the panel's half — that an older document is OPENED and
## not preserved as an unreadable foreign file, and that the migrated form is
## the one the project then holds.
func _section_7_migration() -> void:
	print("\n7 an older document:")
	if _conn == null or not _conn.server_connected:
		check("7: the council-plugin binary is built and speaking", false,
				"build it first: (cd council && go build -o council-plugin ./)")
		return
	var older: Dictionary = _parse(FileAccess.get_file_as_string(OLDER_FIXTURE_PATH))
	check("control: the migration fixture really is an older document",
			int(older.get("schema_version", -1)) == 0 and not older.has("project_id"),
			"schema_version=%s project_id=%s" % [
				str(older.get("schema_version", "missing")), str(older.get("project_id", "missing"))])

	var path := _temp_dir.path_join("older.mcouncil")
	_write(path, JSON.stringify(older, "\t"))
	_panel_a._on_panel_load_request(_document_from_disk(path))
	check("an older document is opened, not preserved as something Council cannot read",
			not _panel_a._on_panel_save_request().has("_bytes"),
			str(_panel_a._on_panel_save_request()).left(160))

	# Seeding the engine is what applies the migration; the rewritten record
	# comes back through the same path a demoted one does.
	await _relay(_panel_a, {
		"schema_version": 1, "envelope": "request", "request_id": "migrate-read",
		"command": "snapshot.get", "payload": {}})
	var migrated: Dictionary = _panel_a._on_panel_save_request()
	check("the record the project now holds is in this build's shape",
			int(migrated.get("schema_version", 0)) == 1
			and str(migrated.get("project_id", "")).begins_with("prj-"),
			"schema_version=%s project_id=%s" % [
				str(migrated.get("schema_version", "")), str(migrated.get("project_id", ""))])
	check("a rewritten document takes a new revision",
			int(migrated.get("snapshot_revision", 0)) == int(older.get("snapshot_revision", 0)) + 1,
			"%d from %d" % [int(migrated.get("snapshot_revision", 0)),
				int(older.get("snapshot_revision", 0))])

	# Reopening the migrated form must migrate nothing: an identity re-minted on
	# every load would make each reopen look like a different project.
	var identity := str(migrated.get("project_id", ""))
	var revision := int(migrated.get("snapshot_revision", 0))
	_panel_a._on_panel_load_request(_document_for("", migrated))
	await _relay(_panel_a, {
		"schema_version": 1, "envelope": "request", "request_id": "migrate-reread",
		"command": "snapshot.get", "payload": {}})
	var reopened: Dictionary = _panel_a._on_panel_save_request()
	check("reopening a current document mints nothing and moves nothing",
			str(reopened.get("project_id", "")) == identity
			and int(reopened.get("snapshot_revision", 0)) == revision,
			"%s@%d then %s@%d" % [identity, revision,
				str(reopened.get("project_id", "")), int(reopened.get("snapshot_revision", 0))])


# ---------------------------------------------------------------------------
# 8. Saved during a run, backend restarted, reopened, continued explicitly
# ---------------------------------------------------------------------------

## The oracle is the engine's interruption rule (contract.RehydrateOnLoad) read
## back through the panel's own saved record, plus the seat list of the run a
## retry starts.
##
## "No duplicate model calls" is asserted here as "the seat that already
## answered is not in the continued round" — the record is the only place this
## suite can see it, because nothing in a headless run answers
## host.providers.chat and so no model call is made at all. The COUNTING form of
## the same claim is TestSavedMidRunDocumentContinuesWithoutDuplicateCalls,
## where a fake host records every call.
func _section_8_interrupted_run() -> void:
	print("\n8 an interrupted run:")
	if _conn == null or not _conn.server_connected:
		check("8: the council-plugin binary is built and speaking", false,
				"build it first: (cd council && go build -o council-plugin ./)")
		return
	var saved: Dictionary = _saved_mid_run()
	var interrupted_run: Dictionary = _run_of(saved, "ses-recurring-order", "run-1")
	check("control: the saved document holds a run still in flight, with one seat already answered",
			str(interrupted_run.get("status", "")) == "running"
			and _seat_status(interrupted_run, "seat-costing") == "complete"
			and _seat_status(interrupted_run, "seat-capacity") == "running",
			str(interrupted_run.get("status", "")))

	# THE RESTART. A new backend process holds nothing: no ledger, no live runs,
	# no working snapshot. Everything asserted below came out of the document.
	await _restart_backend()
	check("the backend restarted and is speaking again",
			_conn != null and _conn.server_connected)
	if _conn == null or not _conn.server_connected:
		return

	_panel_a._on_panel_load_request(_document_for("", saved))
	await _relay(_panel_a, {
		"schema_version": 1, "envelope": "request", "request_id": "reopen-interrupted",
		"command": "snapshot.get", "payload": {}})
	var reopened: Dictionary = _panel_a._on_panel_save_request()
	var demoted: Dictionary = _run_of(reopened, "ses-recurring-order", "run-1")
	check("the run that was in flight is a visible failure, not something still running",
			str(demoted.get("status", "")) == "failed"
			and str((demoted.get("failure", {}) as Dictionary).get("code", "")) == "interrupted",
			"%s / %s" % [str(demoted.get("status", "")),
				str((demoted.get("failure", {}) as Dictionary).get("code", ""))])
	check("the answer that was already paid for survived the restart",
			_seat_status(demoted, "seat-costing") == "complete",
			_seat_status(demoted, "seat-costing"))
	check("reopening started nothing: the session holds the runs it was saved with",
			_run_ids(reopened, "ses-recurring-order") == PackedStringArray(["run-1", "run-2"]),
			str(_run_ids(reopened, "ses-recurring-order")))

	# THE EXPLICIT CONTINUE. No seat_ids: the claim under test is the ENGINE's
	# own choice of who to re-ask (cmdRunRetry consults the seats that did not
	# answer), and naming the seat here would make the assertion below true by
	# construction. The limits are narrowed so the round fails fast on a host
	# that answers no model call, which is every headless run: what is under test
	# is who the round consults, not what they say.
	var continued: Dictionary = await _relay(_panel_a, {
		"schema_version": 1, "envelope": "request", "request_id": "continue-interrupted",
		"command": "run.retry",
		"base_revision": int(_panel_a._on_panel_save_request().get("snapshot_revision", 1)),
		"wait_seconds": 5,
		"payload": {
			"session_id": "ses-recurring-order", "run_id": "run-1",
			"limits": {"per_member_timeout_seconds": 1, "run_budget_seconds": 2}}})
	check("the continue is accepted", bool(continued.get("ok", false)),
			str(continued).left(240))
	var retried_id := str((continued.get("payload", {}) as Dictionary).get("run_id", ""))
	var after: Dictionary = _panel_a._on_panel_save_request()
	var retry_run: Dictionary = _run_of(after, "ses-recurring-order", retried_id)
	check("the continued round re-asks only the seat that never answered",
			_seat_ids(retry_run) == PackedStringArray(["seat-capacity"]),
			str(_seat_ids(retry_run)))
	check("and the earlier round keeps its own answer rather than being re-run",
			_seat_status(_run_of(after, "ses-recurring-order", "run-1"), "seat-costing") == "complete")


# ---------------------------------------------------------------------------
# 9. The panel closed while the round kept going
# ---------------------------------------------------------------------------

## When the panel goes away mid-round the engine carries on, and what it
## produces afterwards is in the engine and nowhere else — the wrapper was not
## there to persist it. Reopening hands back the record as it was BEFORE, and
## taking that record would throw the work away.
##
## The oracle is the engine's own recovery rule, read through the panel: after
## reopening with the older copy, the panel must hold the LATER state. The work
## done "while the panel was away" is a real mutation driven through the real
## backend, because a mutation the engine applied and the wrapper never saw is
## exactly the situation.
func _section_9_recovering_a_closed_panel() -> void:
	print("\n9 a panel that closed mid-round:")
	if _conn == null or not _conn.server_connected:
		check("9: the council-plugin binary is built and speaking", false,
				"build it first: (cd council && go build -o council-plugin ./)")
		return
	var record: Dictionary = _fixture_as_session("ses-closing", "A question being considered")
	_panel_a._on_panel_load_request(_document_for("", record))
	var before: Dictionary = _panel_a._on_panel_save_request()

	# The engine advances the document past what the panel persisted. In
	# production this is a contribution landing after the tab closed; here it is
	# a real command through the real transport, which leaves the engine in the
	# same place: holding a later state of this document than the wrapper has.
	var bound: Dictionary = await _bind_chat(_panel_a, "ses-closing", "chat-after-close")
	check("the engine accepted work against the open document",
			bool(bound.get("ok", false)), str(bound).left(200))

	# The panel comes back with the copy it had persisted BEFORE that work.
	_panel_a._on_panel_load_request(_document_for("", before))
	await _relay(_panel_a, {
		"schema_version": 1, "envelope": "request", "request_id": "recover-read",
		"command": "snapshot.get", "payload": {}})
	var recovered: Dictionary = _panel_a._on_panel_save_request()
	check("reopening recovers the later state instead of overwriting it with the older copy",
			_chat_of(recovered, "ses-closing") == "chat-after-close",
			"binding is %s at revision %d" % [_chat_of(recovered, "ses-closing"),
				int(recovered.get("snapshot_revision", 0))])
	check("and the recovered record is still this document",
			str(recovered.get("project_id", "")) == str(before.get("project_id", "")),
			"%s vs %s" % [str(recovered.get("project_id", "")), str(before.get("project_id", ""))])

	# A LAGGING FILE COPY, WHICH THE ENGINE CANNOT TELL FROM A REOPEN. The copy
	# carries the same project identity and a lower revision, and everything it
	# names is still in the newer record — so the engine's own test says "later
	# state of this document" and would hand the copy the other tab's work. What
	# separates them is something only the wrapper knows: another panel is the
	# lease holder, so this is a panel joining a document somebody else is
	# working in, and the seed must be a plain replace.
	#
	# The setup is what makes the assertion able to FAIL: panel B is given the
	# SAME document, already at the later state, so the engine holds a record
	# that satisfies every one of its own recovery conditions against the copy A
	# is about to open. A wrapper that sent "reopen" here would merge them.
	_panel_b._on_panel_load_request(_document_for("", recovered))
	await _relay(_panel_b, {
		"schema_version": 1, "envelope": "request", "request_id": "hold-later-state",
		"command": "snapshot.get", "payload": {}})
	check("setup: the other panel holds this same document at its later state",
			CouncilBackend.lease_holder() == "council_panel#b"
			and _chat_of(_panel_b._on_panel_save_request(), "ses-closing") == "chat-after-close",
			"holder=%s binding=%s" % [CouncilBackend.lease_holder(),
				_chat_of(_panel_b._on_panel_save_request(), "ses-closing")])
	_panel_a._on_panel_load_request(_document_for("", before))
	await _relay(_panel_a, {
		"schema_version": 1, "envelope": "request", "request_id": "lagging-copy",
		"command": "snapshot.get", "payload": {}})
	var lagging: Dictionary = _panel_a._on_panel_save_request()
	check("a lagging copy opened while another panel holds the document is replaced, not merged",
			_chat_of(lagging, "ses-closing") == _chat_of(before, "ses-closing")
			and int(lagging.get("snapshot_revision", 0)) == int(before.get("snapshot_revision", 0)),
			"binding %s at revision %d" % [_chat_of(lagging, "ses-closing"),
				int(lagging.get("snapshot_revision", 0))])

	# The rule is narrow in the other direction too: another project's document
	# REPLACES what the engine holds. A recovery that fired across projects would
	# be the cross-project mutation the whole design refuses.
	var other: Dictionary = _fixture_as_session("ses-elsewhere", "Another project's question")
	_panel_b._on_panel_load_request(_document_for("", other))
	var elsewhere: Dictionary = await _relay(_panel_b, {
		"schema_version": 1, "envelope": "request", "request_id": "recover-other-project",
		"command": "snapshot.get", "payload": {}})
	var seen: Dictionary = ((elsewhere.get("payload", {}) as Dictionary).get("snapshot", {}))
	check("another project's document is loaded as itself, never recovered into",
			_session_ids(seen) == PackedStringArray(["ses-elsewhere"]),
			str(_session_ids(seen)))


# ---------------------------------------------------------------------------
# 10. A change with no panel in the exchange
# ---------------------------------------------------------------------------

## The bug this section is the regression for: a chat turn and an MCP tool call
## commit through the engine with no panel involved, and the panel used to serve
## reads and saves from a record that knew nothing about them.
##
## THE ORACLE IS THE PANEL'S OWN SAVE PAYLOAD — the dictionary the host writes
## into the project (vboxEditor.gd:494-499) and into a .mcouncil file
## (Editor.gd:1727). The round is started straight down the MCP tool door on the
## REAL connection, so nothing in the panel is asked to mutate anything; whatever
## turns up in the saved record afterwards got there through the change signal,
## the fan-out and the panel's own convergence, all of them the real ones. The
## backend's engine decides what the round becomes: a headless run answers no
## model call, so the contributions arrive failed, and it is their PRESENCE in
## the saved document — a run the panel never started — that is under test.
##
## Ownership is asserted in both directions: the panel holding another council
## must be byte-identical afterwards, which is what "not by whichever tab was
## focused" means when it is measured rather than claimed.
func _section_10_a_change_with_no_panel_in_it() -> void:
	print("\n10 a change with no panel in it:")
	if _conn == null or not _conn.server_connected:
		check("10: the council-plugin binary is built and speaking", false,
				"build it first: (cd council && go build -o council-plugin ./)")
		return

	# The other council, which must not move.
	var elsewhere: Dictionary = _fixture_as_session("ses-untouched", "A question in another project")
	_panel_b._on_panel_load_request(_document_for("", elsewhere))
	await _settle_exchanges()
	var untouched_before := JSON.stringify(_panel_b._on_panel_save_request(), "\t")

	# The council the round runs in, seeded so the engine is holding it.
	var record: Dictionary = _parse(FileAccess.get_file_as_string(POPULATED_FIXTURE_PATH))
	record["project_id"] = "prj-gd-no-panel"
	record.erase("view")
	_panel_a._on_panel_load_request(_document_for("", record))
	await _relay(_panel_a, {"schema_version": 1, "envelope": "request",
		"request_id": "sync-seed", "command": "snapshot.get", "payload": {}})
	# Nothing of either panel's may still be queued. The round below goes down
	# the tool door WITHOUT the wrapper's lease — which is what an agent's MCP
	# call is — so a panel exchange that seeds while it runs replaces the
	# document the round is running in and the engine refuses the round (§5.5).
	# That is the pre-existing two-panels-one-engine property, not the thing
	# under test, and letting it fire here would test the contention instead.
	await _settle_exchanges()
	var before: Dictionary = _panel_a._on_panel_save_request()
	check("setup: the engine is loaded with the document this panel holds, with nothing else queued",
			CouncilBackend.lease_holder() == "council_panel#a"
			and CouncilBackend.lease_taker() == ""
			and str(before.get("project_id", "")) == "prj-gd-no-panel",
			"holder=%s taker=%s project=%s" % [CouncilBackend.lease_holder(),
				CouncilBackend.lease_taker(), str(before.get("project_id", ""))])
	var runs_before := _run_ids(before, "ses-recurring-order")

	# The host connects content_changed to the tab's dirty flag
	# (Editor.gd:323-324 → :2068-2069), so counting it is how this suite sees
	# "the document will be saved" without an Editor.
	var marked := [0]
	var on_change := func() -> void: marked[0] += 1
	_panel_a.content_changed.connect(on_change)

	# THE MUTATION WITH NO PANEL. A tools/call on the real connection is exactly
	# what an agent's MCP call is, and what a chat turn reaches the same engine
	# through. The limits are narrowed so the round fails fast on a host that
	# answers no model call, which is every headless run.
	var started: Dictionary = await _conn.call_tool("minerva_council_command", {
		"schema_version": 1, "envelope": "request",
		"request_id": "direct-round", "command": "run.start",
		"base_revision": int(before.get("snapshot_revision", 1)),
		"wait_seconds": 5,
		"payload": {
			"session_id": "ses-recurring-order", "kind": "follow_up",
			"prompt": "Does the costing still hold if the order doubles?",
			"limits": {"per_member_timeout_seconds": 1, "run_budget_seconds": 2}}})
	check("the engine accepted a round nothing in the panel started",
			bool(started.get("ok", false)), str(started).left(240))
	var run_id := str((started.get("payload", {}) as Dictionary).get("run_id", ""))

	# The signal travels over the backend's stdout, is drained by the host on its
	# own schedule and is answered by an exchange of the panel's own, so the wait
	# is on the RESULT rather than on a fixed number of frames.
	# The poll reads the held record's REVISION, not the save hook and not a
	# snapshot: save is what warns and re-schedules a convergence while the panel
	# is behind, and a snapshot is a deep copy of the whole document — either one,
	# once a frame for up to twenty seconds, is a lot of work to answer a question
	# an integer answers. The record itself is read once, below.
	var moved := func() -> bool:
		return _panel_a._record.revision() > int(before.get("snapshot_revision", 0))
	await _wait_until(moved, 20.0)
	var saved: Dictionary = _panel_a._on_panel_save_request()
	var landed: Dictionary = _run_of(saved, "ses-recurring-order", run_id)
	check("a round driven with no panel in the exchange is in the document the panel saves",
			not run_id.is_empty() and not landed.is_empty(),
			"run %s in %s" % [run_id, str(_run_ids(saved, "ses-recurring-order"))])
	check("and the contributions of that round came with it",
			_seat_ids(landed).size() > 0, str(_seat_ids(landed)))
	check("the round is a new one, not one the document already held",
			not runs_before.has(run_id), "%s was already in %s" % [run_id, str(runs_before)])
	# The round reaches rest inside the command that started it, so the reply's
	# own snapshot_revision IS the revision the engine ended at. Asserting
	# equality with it, rather than "higher than before", is what makes this a
	# claim about converging ON THE ENGINE instead of about having moved at all.
	check("the saved record is at the revision the engine reached, not the one the panel had",
			int(saved.get("snapshot_revision", 0)) == int(started.get("snapshot_revision", 0))
			and int(saved.get("snapshot_revision", 0)) != int(before.get("snapshot_revision", 0)),
			"panel %d, engine %d, was %d" % [int(saved.get("snapshot_revision", 0)),
				int(started.get("snapshot_revision", 0)),
				int(before.get("snapshot_revision", 0))])
	check("the tab was marked changed, so the host's save writes it",
			marked[0] > 0, "content_changed fired %d times" % marked[0])
	_panel_a.content_changed.disconnect(on_change)
	check("the panel holding another council is untouched",
			JSON.stringify(_panel_b._on_panel_save_request(), "\t") == untouched_before,
			str(_session_ids(_panel_b._on_panel_save_request())))

	# Equal revision cannot authorize a write into another document with matching
	# session IDs. An identity check after the mutation would be too late.
	var same_revision: Dictionary = saved.duplicate(true)
	same_revision["project_id"] = "prj-equal-revision-foreign"
	await _conn.call_tool("minerva_council_load_snapshot", {"snapshot": same_revision})
	var guarded: Dictionary = await _bind_chat(_panel_a, "ses-recurring-order", "chat-must-not-bind")
	var foreign_after: Dictionary = await _conn.call_tool("minerva_council_export_snapshot", {})
	check("equal revision does not authorize a write into another council",
			not bool(guarded.get("ok", false))
			and (foreign_after.get("snapshot", {}) as Dictionary) == same_revision,
			str(guarded).left(200))

	# A delayed event must not seed A's old snapshot after B takes the engine.
	await _relay(_panel_b, {"schema_version": 1, "envelope": "request",
		"request_id": "sync-holder-b", "command": "snapshot.get", "payload": {}})
	var held_b: Dictionary = await _conn.call_tool("minerva_council_export_snapshot", {})
	_panel_a.receive("council.record_changed", {
		"project_id": str(saved.get("project_id", "")),
		"snapshot_revision": int(saved.get("snapshot_revision", 0)) + 1})
	_panel_a._on_panel_save_request()
	check("save while convergence is queued warns that the held copy is behind",
			_panel_a._banner.visible, _panel_a._banner.text.left(120))
	await _panel_a._converge()
	var still_b: Dictionary = await _conn.call_tool("minerva_council_export_snapshot", {})
	check("a delayed convergence cannot replace the current holder with an older panel copy",
			still_b.get("snapshot", {}) == held_b.get("snapshot", {})
			and CouncilBackend.lease_holder() == "council_panel#b"
			and _panel_a._sync_pending,
			"holder=%s pending=%s" % [CouncilBackend.lease_holder(), str(_panel_a._sync_pending)])
	_panel_a._on_panel_load_request(_document_for("", saved))
	await _settle_exchanges()

	# THE LEASE IS A GODOT-SIDE FACT, AND minerva_council_load_snapshot IS A LIVE
	# TOOL. Loading another council straight down the tool door leaves this panel
	# still named as the engine's holder, so its next exchange skips the seed and
	# reads back a record that is not its own. The revision is moved clear of this
	# document's so the exchange really does try to adopt what comes back —
	# otherwise the refusal would never be reached and the assertion would pass
	# for the wrong reason.
	var intruder: Dictionary = _fixture_as_session("ses-intruder", "Another council entirely")
	intruder["snapshot_revision"] = int(saved.get("snapshot_revision", 0)) + 3
	var displaced: Dictionary = await _conn.call_tool("minerva_council_load_snapshot",
			{"snapshot": intruder, "mode": "replace"})
	check("setup: another council was loaded into the engine behind the panel's back",
			bool(displaced.get("ok", false))
			and CouncilBackend.lease_holder() == "council_panel#a",
			"loaded=%s holder=%s" % [str(displaced).left(120), CouncilBackend.lease_holder()])
	_panel_a.receive("council.record_changed", {
		"project_id": str(saved.get("project_id", "")),
		"snapshot_revision": int(saved.get("snapshot_revision", 0)) + 1})
	var refused := func() -> bool: return _panel_a._banner.visible
	await _wait_until(refused, 20.0)
	var kept: Dictionary = _panel_a._on_panel_save_request()
	check("a record for another council is refused rather than adopted",
			str(kept.get("project_id", "")) == "prj-gd-no-panel"
			and _session_ids(kept) == PackedStringArray(["ses-recurring-order"]),
			"%s / %s" % [str(kept.get("project_id", "")), str(_session_ids(kept))])
	check("and the panel says so rather than letting the tab save it",
			_panel_a._banner.visible and _panel_a._banner.text.contains("a different council"),
			_panel_a._banner.text.left(140))

	# THE BACKEND GONE. The panel is told the council moved and cannot read it
	# back. `receive` is the call the host itself makes when it delivers a plugin
	# event (PluginScenePanelBroker.gd:988); with no backend there is nothing to
	# raise one, so the suite makes that single call and everything after it is
	# the panel's own.
	_conn.disconnect_from_server()
	_manager.conn = null
	_panel_a.receive("council.record_changed", {
		"project_id": str(saved.get("project_id", "")),
		"snapshot_revision": int(saved.get("snapshot_revision", 0)) + 1})
	# The banner is already up from the leg above, so the wait is on its TEXT
	# changing to this failure's reason rather than on it becoming visible.
	var said_so := func() -> bool: return _panel_a._banner.text.contains("is not running")
	await _wait_until(said_so, 20.0)
	var written: Dictionary = _panel_a._on_panel_save_request()
	check("with the backend gone the panel says the council is behind rather than saving quietly",
			_panel_a._banner.visible and _panel_a._banner.text.contains("is not running"),
			"visible=%s text=%s" % [str(_panel_a._banner.visible), _panel_a._banner.text.left(120)])
	check("and what it wrote is still the council it holds, not an empty document",
			not _run_of(written, "ses-recurring-order", run_id).is_empty()
			and str(written.get("project_id", "")) == "prj-gd-no-panel",
			str(_run_ids(written, "ses-recurring-order")))


## The one text a session hands over, and the two callers that must not be able
## to disagree about it.
##
## THE ORACLE IS THE FIXTURE. `workshop_complete.mcouncil` is the checked-in
## worked example, validated against the schemas by the Go contract tests: what
## belongs in the derivation is read out of it here, never re-derived by a second
## copy of the rule. The setup assertion pins the shape the rest of the section
## names, so a fixture that gains a contribution fails by name rather than
## silently making "nothing that is not complete" true of a smaller record.
##
## WHY IT IS LAST AND WHY IT NEEDS NO BACKEND. `context_text` reads the held
## record and nothing else, so the record half runs on a bare CouncilRecord and
## the panel half only needs a MOUNTED panel — the wrapper commands never reach
## the engine. Section 10 leaves the backend disconnected, and this section is
## the one that does not care.
##
## HOW THE HANDOFF'S TEXT IS OBSERVED WITHOUT A CHAT. `send_to_chat` puts the
## text on the panel's own `request` signal, addressed to the host capability
## `capability:mcp.proxy:minerva_send_message`; that emission IS what a chat
## would receive, so the suite reads it there. The broker this suite built has no
## capability_broker, so the hop then fails fast and the reply is a transport
## error — deliberately not asserted on, because the claim under test is what was
## handed over, not what a host that is not here would have done with it.
func _section_11_the_text_a_session_hands_over() -> void:
	print("\n11 the text a session hands to a chat:")
	var record_script: GDScript = load(RECORD_SCRIPT_PATH)
	var fixture: Dictionary = _parse(FileAccess.get_file_as_string(POPULATED_FIXTURE_PATH))
	var session: Dictionary = _session_of(fixture, CONTEXT_SESSION)

	# What the fixture says, as ids and as text. Everything below is asserted
	# against these, so the section can only be as right as the fixture is.
	var complete := PackedStringArray()
	var complete_texts := PackedStringArray()
	var incomplete := PackedStringArray()
	for part_v in _parts_of(session):
		var part: Dictionary = part_v
		if str(part.get("status", "")) == "complete":
			complete.append(str(part.get("contribution_id", "")))
			complete_texts.append(str(part.get("text", "")).strip_edges())
		else:
			incomplete.append(str(part.get("contribution_id", "")))
	var record = record_script.new()
	check("setup: the worked example holds the four complete contributions this section names, one that is not, and adopts",
			record.adopt(fixture)
			and complete == PackedStringArray(COMPLETE_IDS)
			and incomplete == PackedStringArray([INCOMPLETE_ID])
			and not complete_texts.has("")
			and str(_part_of(session, INCOMPLETE_ID).get("text", "")).is_empty(),
			"complete=%s incomplete=%s" % [str(complete), str(incomplete)])

	var full: String = record.context_text(CONTEXT_SESSION, PackedStringArray())
	var lines := full.split("\n")
	check("the derivation opens with the session's own question and its status",
			lines.size() > 2
			and lines[0].contains(str(session.get("question", "")))
			and lines[1].contains(str(session.get("status", ""))),
			full.left(160))

	var absent := PackedStringArray()
	for i in COMPLETE_IDS.size():
		if not full.contains(complete_texts[i]):
			absent.append(COMPLETE_IDS[i])
	check("every complete contribution and each round's synthesis is in it, verbatim",
			absent.is_empty(), "missing %s" % str(absent))
	# Counting the blocks is what makes the previous assertion an "exactly":
	# `contains` alone would pass a text that also carried something else.
	check("and nothing that is not complete: it carries those four and no more",
			_context_blocks(full).size() == COMPLETE_IDS.size(),
			str(_context_blocks(full)))
	# THE FIELDS, not just the count. This report's job is ATTRIBUTION of the
	# arguments a user chose to send, so each block has to name the seat and the
	# member that produced it — a block heading that lost a field, or swapped the
	# two, would still be one line starting with "[".
	var first: Dictionary = _part_of(session, COMPLETE_IDS[0])
	var first_head := "[%s / %s]" % [str(first.get("seat_id", "")), str(first.get("member_id", ""))]
	check("each block is headed by its own seat and member, in that order",
			_context_blocks(full).has(first_head)
			and full.contains("%s %s" % [first_head, complete_texts[0]]),
			"%s not heading a block in %s" % [first_head, str(_context_blocks(full))])

	# render-for-LLM passes no session id and the handoff passes the one the page
	# named. If those resolved differently the two callers would be reading two
	# sessions, and "one derivation" would say nothing. A ONE-session record
	# cannot tell "the selected session" from "the only session", so the claim is
	# made against a copy carrying a second one AFTER it: the fallback is the
	# last session, and `view.selected_session_id` still names the first.
	var two_sessions: Dictionary = _parse(FileAccess.get_file_as_string(POPULATED_FIXTURE_PATH))
	var second: Dictionary = _session_of(two_sessions, CONTEXT_SESSION).duplicate(true)
	second["session_id"] = "ses-second"
	second["question"] = "A second question, in the same council"
	(two_sessions["sessions"] as Array).append(second)
	var two_record = record_script.new()
	two_record.adopt(two_sessions)
	var by_default: String = two_record.context_text("", PackedStringArray())
	check("an empty session id resolves to the session the view selected, not the last one",
			by_default == full and not by_default.contains(str(second["question"])),
			"differ at %d of %d" % [_first_difference(by_default, full), full.length()])
	# …and not the FIRST one either. The fixture's view selects the session that
	# is also sessions[0], so the assertion above passes just as well for a
	# derivation that never reads `view` at all. Moving the selection to the
	# appended session is what separates the three candidate rules: only a
	# derivation that reads the view follows it.
	(two_sessions["view"] as Dictionary)["selected_session_id"] = "ses-second"
	two_record.adopt(two_sessions)
	var by_selection: String = two_record.context_text("", PackedStringArray())
	check("and it follows the view when the selected session is not the first one",
			by_selection.contains(str(second["question"]))
			and not by_selection.contains(str(session.get("question", ""))),
			by_selection.left(160))

	# THE VARIANT: the same fixture with words in the contribution that failed.
	var variant: Dictionary = _parse(FileAccess.get_file_as_string(POPULATED_FIXTURE_PATH))
	var unfinished: Dictionary = _part_of(_session_of(variant, CONTEXT_SESSION), INCOMPLETE_ID)
	unfinished["text"] = UNFINISHED_TEXT
	var variant_record = record_script.new()
	variant_record.adopt(variant)
	var variant_full: String = variant_record.context_text(CONTEXT_SESSION, PackedStringArray())
	check("a contribution that is not complete is left out for its status, not for want of text",
			not variant_full.contains(UNFINISHED_TEXT)
			and _context_blocks(variant_full).size() == COMPLETE_IDS.size(),
			str(_context_blocks(variant_full)))
	var picked: String = variant_record.context_text(
			CONTEXT_SESSION, PackedStringArray([INCOMPLETE_ID]))
	check("a selection takes the contribution it names whatever its status",
			picked.contains(UNFINISHED_TEXT) and _context_blocks(picked).size() == 1,
			str(_context_blocks(picked)))

	var selected := PackedStringArray(["con-1", "con-4"])
	var narrowed: String = record.context_text(CONTEXT_SESSION, selected)
	var wrong := PackedStringArray()
	for i in COMPLETE_IDS.size():
		if narrowed.contains(complete_texts[i]) != selected.has(COMPLETE_IDS[i]):
			wrong.append(COMPLETE_IDS[i])
	check("a selection narrows to exactly the contributions it names",
			wrong.is_empty() and _context_blocks(narrowed).size() == selected.size(),
			"wrong %s in %s" % [str(wrong), str(_context_blocks(narrowed))])

	# THE TWO CALLERS. Both read the record the panel holds, so the panel has to
	# be holding this same document; adopting it defers a rehydrate, which is an
	# exchange, so it drains before anything is measured.
	_panel_b._on_panel_load_request(_document_for("", fixture.duplicate(true)))
	await _settle_exchanges()
	var held: Dictionary = _panel_b._on_panel_save_request()
	var bound_chat := _chat_of(fixture, CONTEXT_SESSION)
	# The revision is part of the setup claim: an engine that seeded or migrated
	# this record would have handed back a later one, and the panel would then be
	# holding a document the assertions above were not made about.
	check("setup: the panel holds the worked example unchanged, bound to the chat the fixture names",
			_session_ids(held) == PackedStringArray([CONTEXT_SESSION])
			and int(held.get("snapshot_revision", -1)) == int(fixture.get("snapshot_revision", -2))
			and _chat_of(held, CONTEXT_SESSION) == bound_chat and not bound_chat.is_empty(),
			"%s / rev %d / %s" % [str(_session_ids(held)),
				int(held.get("snapshot_revision", -1)), _chat_of(held, CONTEXT_SESSION)])

	var rendered: Array = _panel_b._on_panel_render_for_llm({})
	var one_text_part: bool = rendered.size() == 1 and rendered[0] is Dictionary \
			and str((rendered[0] as Dictionary).get("type", "")) == "text"
	var rendered_text: String = str((rendered[0] as Dictionary).get("text", "")) \
			if one_text_part else ""
	check("render-for-LLM hands back the record's derivation and adds nothing to it",
			one_text_part and rendered_text == full,
			"parts=%d, differ at %d of %d" % [rendered.size(),
				_first_difference(rendered_text, full), full.length()])

	# Everything the panel puts on the wire, filtered to the send capability:
	# the wrapper's own exchanges travel the same signal.
	var handed: Array[Dictionary] = []
	var watch := func(channel: String, payload: Dictionary, _reply_id: String) -> void:
		if channel == CouncilBackend.SEND_MESSAGE_CHANNEL:
			handed.append(payload)
	_panel_b.request.connect(watch)
	await _wrapper(_panel_b, "wrapper.chat_handoff",
			{"session_id": CONTEXT_SESSION, "contribution_ids": []})
	var handed_text: String = str(handed[0].get("message", "")) if handed.size() == 1 else ""
	check("the handoff hands the host exactly the text render-for-LLM returned",
			handed.size() == 1 and handed_text == rendered_text,
			"%d sends, differ at %d of %d" % [handed.size(),
				_first_difference(handed_text, rendered_text), rendered_text.length()])
	check("addressed to the chat the session itself is bound to",
			handed.size() == 1 and str(handed[0].get("chat_id", "")) == bound_chat,
			str(handed).left(160))

	# THE UNBOUND SESSION. The binding is the only thing that changes; the text
	# would be the same one that was just sent, so a send here would be a send to
	# whichever chat the panel could find — the thing the backend refuses to do.
	var unbound: Dictionary = _parse(FileAccess.get_file_as_string(POPULATED_FIXTURE_PATH))
	_session_of(unbound, CONTEXT_SESSION).erase("chat_binding")
	_panel_b._on_panel_load_request(_document_for("", unbound))
	await _settle_exchanges()
	handed.clear()
	var refusal: Dictionary = await _wrapper(_panel_b, "wrapper.chat_handoff",
			{"session_id": CONTEXT_SESSION, "contribution_ids": []})
	var refused: Dictionary = refusal.get("error", {}) if refusal.get("error", {}) is Dictionary else {}
	check("a session bound to no chat is refused by the send path, by name",
			not bool(refusal.get("ok", true)) and str(refused.get("code", "")) == "missing_chat",
			str(refusal).left(200))
	check("and nothing was handed to the host",
			handed.is_empty(), str(handed).left(160))
	_panel_b.request.disconnect(watch)


## Let every panel exchange that is running or queued finish.
##
## Adopting a document DEFERS a rehydrate, and a rehydrate is an exchange on the
## one engine that seeds it. So a step that reaches the backend outside the
## wrapper's lease has to let those drain first, or it is racing a Load with its
## own work. The frames come first because a deferred call has not started yet:
## checking the lease immediately would find it free and prove nothing.
func _settle_exchanges() -> void:
	await process_frame
	await process_frame
	var idle := func() -> bool: return CouncilBackend.lease_taker() == ""
	await _wait_until(idle, 20.0)


## Wait for a condition the host reaches on its own schedule — a notification
## drained from the backend's stdout, then an exchange of the panel's — rather
## than for a fixed number of frames, which would be either flaky or slow.
func _wait_until(condition: Callable, seconds: float) -> bool:
	var deadline: int = Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await process_frame
	return bool(condition.call())


func _restart_backend() -> void:
	if _conn != null:
		_conn.disconnect_from_server()
	_conn = await _start_backend()
	if _manager != null:
		_manager.conn = _conn


## The document a panel persists while a round is still going: one seat has
## answered, one is still out, and the run says so. Built from the populated
## fixture because the engine never writes this state — a run reaches rest
## inside the command that started it — and the interruption rule exists for it.
func _saved_mid_run() -> Dictionary:
	var record: Dictionary = _parse(FileAccess.get_file_as_string(POPULATED_FIXTURE_PATH))
	var session: Dictionary = record["sessions"][0]
	var run: Dictionary = _run_of(record, "ses-recurring-order", "run-1")
	run["status"] = "running"
	run.erase("failure")
	run.erase("ended_at")
	run.erase("synthesis")
	for c_v in run.get("contributions", []):
		var contribution: Dictionary = c_v
		if str(contribution.get("seat_id", "")) == "seat-capacity":
			contribution["status"] = "running"
			contribution.erase("failure")
			contribution.erase("text")
			contribution["claims"] = []
	# Status is derived from the run set, and a run in flight makes the session
	# running. Writing anything else would be a record the engine refuses.
	session["status"] = "running"
	return record


func _run_of(record: Dictionary, session_id: String, run_id: String) -> Dictionary:
	for s_v in record.get("sessions", []):
		var session: Dictionary = s_v
		if str(session.get("session_id", "")) != session_id:
			continue
		for r_v in session.get("runs", []):
			var run: Dictionary = r_v
			if str(run.get("run_id", "")) == run_id:
				return run
	return {}


func _run_ids(record: Dictionary, session_id: String) -> PackedStringArray:
	var ids := PackedStringArray()
	for s_v in record.get("sessions", []):
		var session: Dictionary = s_v
		if str(session.get("session_id", "")) != session_id:
			continue
		for r_v in session.get("runs", []):
			ids.append(str((r_v as Dictionary).get("run_id", "")))
	return ids


func _seat_ids(run: Dictionary) -> PackedStringArray:
	var ids := PackedStringArray()
	for c_v in run.get("contributions", []):
		ids.append(str((c_v as Dictionary).get("seat_id", "")))
	return ids


func _seat_status(run: Dictionary, seat_id: String) -> String:
	for c_v in run.get("contributions", []):
		var contribution: Dictionary = c_v
		if str(contribution.get("seat_id", "")) == seat_id:
			return str(contribution.get("status", ""))
	return ""


func _bind_chat(panel: Control, session_id: String, chat_id: String) -> Dictionary:
	var record: Dictionary = panel._on_panel_save_request()
	return await _relay(panel, {
		"schema_version": 1, "envelope": "request",
		"request_id": "bind-%s-%s" % [session_id, chat_id],
		"command": "session.bind_chat",
		"base_revision": int(record.get("snapshot_revision", 1)),
		"payload": {"session_id": session_id, "chat_id": chat_id}})


## Drive one request the way the page does: straight into the panel's own
## message handler, so the reply is the one the page would have seen.
func _relay(panel: Control, request: Dictionary) -> Dictionary:
	return await panel._relay_to_engine(request)


## Drive one wrapper request — the panel's own operations, which never reach the
## engine — exactly as `_on_page_message` dispatches it. The one difference is
## that the reply is RETURNED rather than eval'd into the page: headless has no
## bridge, so a reply sent that way would sit in the panel's outbox or vanish
## into a CEF that may or may not have signalled ready.
func _wrapper(panel: Control, command: String, payload: Dictionary) -> Dictionary:
	var request_id := "gd-%s" % command
	return await panel._wrapper_command(command, {
		"schema_version": 1, "envelope": "request", "request_id": request_id,
		"command": command, "payload": payload}, request_id, panel._record.revision())


# ---------------------------------------------------------------------------
# Fixtures and helpers
# ---------------------------------------------------------------------------

## The checked-in worked example, which the Go contract tests validate against
## the schemas. Using it means this suite cannot drift into asserting against a
## record shape the engine would refuse.
func _fixture() -> Dictionary:
	return _parse(FileAccess.get_file_as_string(FIXTURE_PATH))


## The same fixture as one project's record: one session, re-identified so the
## two projects in section 6 are distinguishable by id and by question.
func _fixture_as_session(session_id: String, question: String) -> Dictionary:
	var record: Dictionary = _fixture()
	var sessions: Array = record.get("sessions", [])
	var session: Dictionary = sessions[0]
	session["session_id"] = session_id
	session["question"] = question
	record["sessions"] = [session]
	# Each stands for a DIFFERENT project, so each carries its own durable
	# identity. Sharing the fixture's id would make them one document as far as
	# the engine is concerned, which is the thing these sections are about.
	record["project_id"] = "prj-gd-%s" % session_id
	record.erase("view")
	return record


## The document shape Editor.gd._load_plugin_scene_file hands a panel: file_path
## plus the parsed JSON body merged in.
func _document_for(path: String, record: Dictionary) -> Dictionary:
	var doc: Dictionary = {"file_path": path}
	doc.merge(record, true)
	return doc


## The same shape, but built from what is actually on disk — including the
## raw_text branch for a body that is not a JSON object.
func _document_from_disk(path: String) -> Dictionary:
	var doc: Dictionary = {"file_path": path}
	var content := FileAccess.get_file_as_string(path)
	if not content.is_empty():
		# JSON.new().parse, not JSON.parse_string: this is the call Editor.gd
		# makes (_load_plugin_scene_file), and it reports a non-JSON body through
		# its return value instead of pushing an engine error for every file the
		# panel is meant to treat as prose.
		var json := JSON.new()
		if json.parse(content) == OK and json.data is Dictionary:
			doc.merge(json.data as Dictionary, true)
		else:
			doc["raw_text"] = content
	return doc


## A council whose serialised form lands in the ONLY window where the claim
## under test is visible: at most `cap` on its own, and over `cap` once the
## wrapper has put it in `{"snapshot": …}`. That wrapper costs exactly
## WRAPPER_OVERHEAD characters, so the window is [cap - 12, cap] — a record
## outside it makes both assertions pass for the wrong reason (a coarse growth
## loop that overshoots leaves "fits alone" failing and "does not fit wrapped"
## trivially true, which validates nothing).
##
## The padding is spread across the contributions and then ONE of them is
## adjusted to the exact length, character by character: the padding is plain
## ASCII, so one character in the field is one character in the serialised form.
## Each stays under the schema's own 32768 ceiling for the field, so the record
## the size check refuses is one the engine would otherwise have accepted.
func _record_sized_just_under(cap: int) -> Dictionary:
	var record: Dictionary = _fixture()
	var texts: Array = []
	for run_v in (record["sessions"][0] as Dictionary).get("runs", []):
		for c in (run_v as Dictionary).get("contributions", []):
			texts.append(c)
	if texts.is_empty():
		return record

	var padding := 0
	while JSON.stringify(record).length() < cap and padding < 28000:
		padding += 1024
		for c in texts:
			(c as Dictionary)["text"] = "x".repeat(padding)

	# Trim (or top up) the last contribution until the whole record is exactly
	# `cap` characters. Every step is one character in and one character out.
	var adjustable: Dictionary = texts[texts.size() - 1]
	var length: int = str(adjustable["text"]).length()
	var delta: int = cap - JSON.stringify(record).length()
	length = maxi(0, length + delta)
	adjustable["text"] = "x".repeat(length)
	return record


## The longest contribution text in a record, so a padded fixture can be shown
## to stay inside the schema's per-field ceiling.
func _longest_contribution(record: Dictionary) -> int:
	var longest := 0
	for s_v in record.get("sessions", []):
		for run_v in (s_v as Dictionary).get("runs", []):
			for c in (run_v as Dictionary).get("contributions", []):
				longest = maxi(longest, str((c as Dictionary).get("text", "")).length())
	return longest


func _session_ids(record: Dictionary) -> PackedStringArray:
	var ids := PackedStringArray()
	for s in record.get("sessions", []):
		ids.append(str((s as Dictionary).get("session_id", "")))
	return ids


## The session `session_id` names, BY REFERENCE into `record` — a caller that
## writes into what it gets back is editing the record it came from, which is how
## section 11 builds its variant of the fixture without a second file.
func _session_of(record: Dictionary, session_id: String) -> Dictionary:
	for s in record.get("sessions", []):
		var session: Dictionary = s
		if str(session.get("session_id", "")) == session_id:
			return session
	return {}


## Everything in a session that the context derivation may quote, in the order it
## walks them: each round's contributions, then that round's synthesis. Reading
## the fixture, not deciding anything about it.
func _parts_of(session: Dictionary) -> Array:
	var parts: Array = []
	for r_v in session.get("runs", []):
		var run: Dictionary = r_v
		parts.append_array(run.get("contributions", []) as Array)
		if run.get("synthesis", null) is Dictionary:
			parts.append(run["synthesis"])
	return parts


func _part_of(session: Dictionary, contribution_id: String) -> Dictionary:
	for part_v in _parts_of(session):
		var part: Dictionary = part_v
		if str(part.get("contribution_id", "")) == contribution_id:
			return part
	return {}


## The contribution blocks in a derived context text. Each one starts a line with
## "[seat / member] ", which is the only line shape the derivation indents that
## way, so counting them counts contributions — the assertion "and nothing else"
## needs a count, and `contains` cannot give one.
func _context_blocks(text: String) -> PackedStringArray:
	var blocks := PackedStringArray()
	for line in text.split("\n"):
		if line.begins_with("["):
			blocks.append(line.get_slice("]", 0) + "]")
	return blocks


func _chat_of(record: Dictionary, session_id: String) -> String:
	for s in record.get("sessions", []):
		var session: Dictionary = s
		if str(session.get("session_id", "")) == session_id:
			return str((session.get("chat_binding", {}) as Dictionary).get("chat_id", ""))
	return ""


func _parse(text: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		check("setup: %s is writable" % path, false, error_string(FileAccess.get_open_error()))
		return
	f.store_string(text)
	f.close()


## Where two strings first differ, so a byte-for-byte failure names the place
## rather than making a reader diff two 13 KB blobs by eye.
func _first_difference(a: String, b: String) -> int:
	var limit: int = mini(a.length(), b.length())
	for i in range(limit):
		if a[i] != b[i]:
			return i
	return limit


func _cleanup() -> void:
	# Put the host's own plugin registry back before it shuts down. The autoload
	# starts real plugins during its _ready and stops them from _exit_tree; left
	# pointing at this suite's stand-in it would stop nothing.
	if _singleton != null and is_instance_valid(_singleton):
		_singleton.set("plugin_manager", _saved_plugin_manager)
		_singleton.set("plugin_scene_panel_broker", _saved_panel_broker)
	for panel in [_panel_a, _panel_b]:
		if panel != null and is_instance_valid(panel) and panel.has_method("_on_panel_unload"):
			panel._on_panel_unload()
	if _conn != null:
		_conn.disconnect_from_server()
	if _vbox != null and is_instance_valid(_vbox):
		root.remove_child(_vbox)
		_vbox.free()
	var dir := DirAccess.open(_temp_dir)
	if dir != null:
		for file in dir.get_files():
			DirAccess.remove_absolute(_temp_dir.path_join(file))


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
