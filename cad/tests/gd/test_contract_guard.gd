extends SceneTree
## cad's CONTRACT GUARD — six domain-defined cases through the real host chain.
##
## WHY THIS SUITE EXISTS
##
## The host bounds an ordinary scene-panel reply at
## PluginScenePanelBroker.MAX_PAYLOAD_BYTES (64 KiB) in both directions. A
## cad.evaluate reply carries the whole tessellation, so every document past a
## toy came back as payload_too_large and the panel painted nothing — a total
## outage invisible to every suite whose worker is a shim, because a stood-in
## reply is never weighed by the host.
##
## test_bulk_reply_seam.gd closes that one case. This guard weighs the plugin
## against the same contract at BOTH sizes and in both moods, because the
## failures cluster where those axes cross: the reply that carries geometry is
## the big one, and the reply that carries a FINDINGS LIST grows with the
## document too.
##
##   1. null / empty document   — refused by the worker, and the model already
##                                on screen is not blanked
##   2. small happy             — a 10 mm cube evaluates and paints
##   3. small unhappy           — an unknown function is refused `translate`,
##                                and the painted model survives it
##   4. large happy             — a 20 mm sphere whose evaluate reply is OVER
##                                the control cap arrives whole
##   5. large unhappy           — a document that builds a 64-hole plate and
##                                THEN names an unknown function: refused
##                                after the large build, nothing painted over
##   6. large-with-errors reply — the feature findings for that plate: one
##                                record per hole, a reply that outweighs the
##                                same call on the clean large model AND is
##                                itself over the control cap
##
## cad's own definitions of LARGE are TESSELLATION SIZE and FEATURE COUNT.
## Measured against this worker: a 20 mm sphere tessellates to 4,066 vertices /
## 8,002 faces — a 407 KB reply, 6.2x the control cap — and the 64-bore plate's
## feature reply is 75 KB against 369 bytes for the same question asked of the
## sphere. Both large replies are over the cap; the findings one is over it for
## a different reason, which is the point of holding both.
##
## EVERYTHING IS REAL: a real PluginManager, the real PluginScenePanelBroker,
## the real cad-plugin Go binary with its Python worker, the real CADPanel
## scene. Nothing between an assertion and the subprocess is a double.
##
## WHERE THE REFUSALS LIVE. A worker refusal rides a SUCCESSFUL transport: the
## broker envelope says success, and the payload inside it says {ok:false,
## error:{kind, message}}. So the structural refusal is asserted on that
## payload (its code is `error.kind`), and the envelope is checked separately
## for the one thing only it can say — that the host carried the reply at all.
##
## ORACLE: revert the panel's bulk send seam (CADPanel._send_request preferring
## MinervaIPC.request_bulk) and case 4 goes red — the tessellation no longer
## fits the control lane and comes back payload_too_large, taking the paint
## assertions with it. Case 6 goes red with it, for the other reason: its
## findings list is over the cap too. Cases 1, 2, 3 and 5 stay green — a cube,
## an empty document and a refusal are all far under it — so the run says which
## of the two large paths broke.
##
## THE PAINTED MODEL IS THE STATE PROBE, and the cases run in an order that
## gives it teeth: the small happy case paints first, and every refusal after
## it must leave that geometry standing. A failed edit that blanks the viewport
## is the partial state this forbids.
##
## SKIP CONTRACT: with the Go binary unbuilt the live cases do not run and the
## suite says so loudly. Its assertion pin therefore describes a host that has
## built the plugin and installed it.
##
## Run: scripts/run-gd-tests.sh --plugin cad <path-to-minerva-checkout>

const ContractGuard := preload("res://../../minerva-plugins/scripts/contract_guard.gd")

const PANEL_SCENE_PATH := "res://../../minerva-plugins/cad/ui/CADPanel.tscn"
const PANEL_BROKER_PATH := "res://Scripts/Services/Plugins/PluginScenePanelBroker.gd"
const PLUGIN_MANAGER_PATH := "res://Scripts/Services/Plugins/PluginManager.gd"

const CAD_PLUGIN_DIR_REL := "/github/minerva-plugins/cad"
const CAD_BINARY_REL := "/cad-plugin"
const CAD_MANIFEST_REL := "/manifest.json"

## PluginDefinition.State values the setup pipeline passes through.
const S_RUNNING := 2
const S_BUILDING := 6
const S_BUILD_FAILED := 7

const MANIFEST_PANEL := "cad_panel"
const EVALUATE_CHANNEL := "cad.evaluate"
const FEATURES_CHANNEL := "cad.cylindrical_features"
const GUARD_CHANNELS := [EVALUATE_CHANNEL, FEATURES_CHANNEL]

## The worker's refusals are named, not sniffed: an unknown function is a
## translate-time refusal, the taxonomy the worker's own committed vectors pin.
const CODE_TRANSLATE := "translate"

## Where cad keeps the code on a refusal: the worker payload's own
## error.kind, never the message text beside it. Every cad refusal has one, so
## no case here has to fall back to asserting shape alone.
const WORKER_CODE_KEYS: Array[String] = ["error.kind"]

## The fixtures. Small is a single primitive; large is the sphere whose
## tessellation does not fit the control lane.
const SMALL_SOURCE := "part = cube(10, 10, 10)\n"
const LARGE_SOURCE := "part = sphere(r=20)\n"
const EMPTY_SOURCE := "   \n"
## An unknown function: valid syntax, no such name. Refused at translate time
## before any geometry is built.
const SMALL_REFUSED_SOURCE := "part = boxx(1, 1, 1)\n"

## The plate, cad's other unit of large: one solid with HOLE_COUNT bores cut
## out of it. Every bore is the same diameter, so the feature reply can be
## checked against the fixture's own number rather than against a transcript.
const HOLE_COUNT := 64
const HOLE_COLUMNS := 8
const HOLE_RADIUS_MM := 1.7
const HOLE_PITCH_MM := 30.0
const PLATE_SPAN_MM := 300.0
const PLATE_THICKNESS_MM := 10.0

## The feature window both feature calls use — one derivation, so the clean
## model and the plate are asked exactly the same question.
const FEATURE_MIN_DIA_MM := 1.0
const FEATURE_MAX_DIA_MM := 20.0

## OCCT tessellating a sphere behind a cold build123d import, and the plate's
## 64 booleans (measured at 3.4 s for the build and 4.5 s for the feature read
## on a warm worker), with room to spare on a loaded machine.
const EVAL_TIMEOUT_MS := 180000
const PLATE_TIMEOUT_MS := 300000

## Past the panel's own 0.25 s text_changed debounce, so an evaluation is
## actually in flight before it is awaited.
const DEBOUNCE_SETTLE_SEC := 0.6

## The pane whose MeshInstance is read as "the answer is on screen".
const ISO_MESH_INSTANCE := (
	"ResponsiveContainer/WideLayout/VBoxContainer/GridContainer/IsoView/"
	+ "SubViewport/MeshRoot/MeshInstance"
)

var guard := ContractGuard.new()
var _pm: Node = null
var _broker: Object = null
var _panel: Node = null
var _panel_key: String = ""
## Buffer version counter: each push is a new version, as an editor's would be.
var _version := 0
## What the viewport held after the last happy case — every refusal is weighed
## against this.
var _painted_vertices := -1


func _init() -> void:
	print("=== CAD contract guard — six cases through the real host chain ===\n")
	await process_frame

	var home: String = OS.get_environment("HOME")
	if home == "":
		home = OS.get_environment("USERPROFILE")
	var plugin_dir: String = OS.get_environment("MINERVA_CAD_PLUGIN_DIR")
	if plugin_dir == "" and home != "":
		plugin_dir = home + CAD_PLUGIN_DIR_REL
	var binary_path: String = plugin_dir + CAD_BINARY_REL
	if not FileAccess.file_exists(binary_path) and FileAccess.file_exists(binary_path + ".exe"):
		binary_path += ".exe"

	if plugin_dir == "" or not FileAccess.file_exists(binary_path):
		print("SKIP: cad-plugin binary not built at '%s'." % binary_path)
		print("      Build with: cd %s && go build -o cad-plugin ." % plugin_dir)
	else:
		var mounted: bool = await _mount(plugin_dir + CAD_MANIFEST_REL)
		if mounted:
			# Order matters: the small happy case paints the model every
			# refusal after it is weighed against (see the class doc).
			await _case_small_happy()
			await _case_null_document()
			await _case_small_unhappy()
			await _case_large_happy()
			await _case_large_unhappy()
			await _case_large_error_reply()
		else:
			printerr("SETUP FAILED — the real chain did not mount; cases not run")
		await _teardown()

	# Two frames so the rendering server releases the freed panel's viewport
	# textures before quit; otherwise they are reported as leaked at exit.
	await process_frame
	await process_frame
	quit(guard.results())


# ---------------------------------------------------------------------------
# Mount — real PluginManager + real broker + real panel, production order
# ---------------------------------------------------------------------------

## Install-if-absent, refresh a stale install, start, register, load. Only
## POST-CONDITIONS assert; the conditional repair paths print, so the assertion
## pin describes this suite's contract rather than the host's install state.
func _mount(manifest_path: String) -> bool:
	var pm_script: Script = load(PLUGIN_MANAGER_PATH)
	if pm_script == null:
		printerr("  PluginManager.gd did not load")
		return false
	_pm = pm_script.new()
	root.add_child(_pm)
	await process_frame
	if not guard.check("setup: the plugin manager initialised its database", _pm._db != null):
		return false

	var def = _pm._db.get_by_id("cad")
	# An install predating the current manifest's channel list would have the
	# broker deny a channel by allowlist — a permission_denied that looks
	# nothing like the contract under test. Refresh through the manager's own
	# API so the assertions describe the manifest standing now.
	if def != null and not _declares_every_channel(def):
		print("  installed definition predates the manifest's channel list — "
				+ "refreshing via remove_plugin + install_plugin")
		if def.state == S_RUNNING:
			await _pm.stop_plugin("cad")
		await _pm.remove_plugin("cad", false)
		def = null
	if def == null:
		print("  installing the plugin from %s" % manifest_path)
		await _pm.install_plugin(manifest_path, true)
		def = _pm._db.get_by_id("cad")
		# The manifest carries a `setup` stanza, so install runs python_venv +
		# go_build on a worker thread. Wait it out: the build rewrites the very
		# binary start_plugin would exec, and a pipeline still running at
		# process exit crashes engine teardown.
		if def != null and def.state == S_BUILDING:
			print("  setup pipeline building (python_venv + go_build) — waiting...")
			var deadline_ms: int = Time.get_ticks_msec() + 900000
			while def.state == S_BUILDING and Time.get_ticks_msec() < deadline_ms:
				await create_timer(0.5).timeout
			if def.state == S_BUILDING or def.state == S_BUILD_FAILED:
				printerr("  setup pipeline did not land (state=%d)" % def.state)
	if def == null:
		printerr("  the cad definition never reached the plugin database")
		return false
	if not guard.check("setup: the installed definition declares every channel this "
			+ "guard rides", _declares_every_channel(def),
			"installed ui_ipc_messages=%s" % str(def.ui_ipc_messages)):
		return false

	if def.state == S_RUNNING:
		await _pm.stop_plugin("cad")
	var start_result: Dictionary = await _pm.start_plugin("cad")
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
		printerr("  the CAD panel scene did not instantiate")
		return false
	root.add_child(_panel)

	# Register before the load hook, the order PluginScenePanelHost guarantees:
	# registration is what attaches the MinervaIPC helper the panel sends on.
	_panel_key = "%s#%d" % [MANIFEST_PANEL, _panel.get_instance_id()]
	_broker.register_panel(_panel, "cad", _panel_key, declared, MANIFEST_PANEL)
	_panel._on_panel_loaded({
		"plugin_id": "cad",
		"panel_name": MANIFEST_PANEL,
		"panel_key": _panel_key,
		"broker": _broker,
		"host_api_version": "1",
	})
	var ipc: Node = _panel.get_node_or_null("_MinervaIPC")
	if not guard.check("setup: the host offers the bulk route the large cases ride",
			ipc != null and ipc.has_method("request_bulk"), "helper=%s" % str(ipc)):
		return false
	# Automatic builds are what make a text push evaluate; the panel defaults
	# to it, and stating it here keeps the cases independent of that default.
	var mode_reply: Dictionary = _panel.set_build_mode("automatic")
	if not guard.check("setup: the panel builds automatically, so a text push "
			+ "evaluates", bool(mode_reply.get("success", false)), str(mode_reply)):
		return false
	for _i in range(4):
		await process_frame
	return true


func _declares_every_channel(def) -> bool:
	for ch in GUARD_CHANNELS:
		if not (ch in def.ui_ipc_messages):
			return false
	return true


# ---------------------------------------------------------------------------
# Case 2 — small happy (runs first: it paints the model every refusal is
# weighed against)
# ---------------------------------------------------------------------------

func _case_small_happy() -> void:
	print("\n-- small happy: a 10 mm cube evaluates and paints --")
	var last_eval: Dictionary = await _push_source(SMALL_SOURCE, EVAL_TIMEOUT_MS)
	guard.check("small-happy: the evaluation came back ok",
			str(last_eval.get("status", "")) == "ok", ContractGuard.brief(last_eval))
	_painted_vertices = _painted()
	guard.expect_document("small-happy", "the vertices painted in the viewport",
			_painted_vertices)


# ---------------------------------------------------------------------------
# Case 1 — null / empty document
# ---------------------------------------------------------------------------

## Two halves of "nothing in". The worker refuses an empty document outright —
## asserted on the channel, where the refusal is a reply and not an omission.
## The PANEL deliberately does not even dispatch one (an emptied buffer would
## otherwise toast on every keystroke), so what is asserted there is the thing
## that matters either way: the model on screen is not blanked by nothing.
func _case_null_document() -> void:
	print("\n-- null/empty document: refused, and the viewport keeps its model --")
	var payload: Dictionary = await _evaluate_payload(EMPTY_SOURCE, EVAL_TIMEOUT_MS)
	guard.expect_refusal("null-document", payload, WORKER_CODE_KEYS)

	await _push_source(EMPTY_SOURCE, EVAL_TIMEOUT_MS)
	guard.expect_unchanged("null-document", "the vertices painted in the viewport",
			_painted(), _painted_vertices)


# ---------------------------------------------------------------------------
# Case 3 — small unhappy
# ---------------------------------------------------------------------------

func _case_small_unhappy() -> void:
	print("\n-- small unhappy: an unknown function is refused by name --")
	var payload: Dictionary = await _evaluate_payload(SMALL_REFUSED_SOURCE, EVAL_TIMEOUT_MS)
	var code := guard.expect_refusal("small-unhappy", payload, WORKER_CODE_KEYS)
	guard.check_eq("small-unhappy: the refusal is a translate-time one", code, CODE_TRANSLATE)

	var last_eval: Dictionary = await _push_source(SMALL_REFUSED_SOURCE, EVAL_TIMEOUT_MS)
	guard.check("small-unhappy: the panel reports the same refusal to its caller",
			str(last_eval.get("status", "")) == "error"
				and str(last_eval.get("error_kind", "")) == CODE_TRANSLATE,
			ContractGuard.brief(last_eval))
	guard.expect_unchanged("small-unhappy", "the vertices painted in the viewport",
			_painted(), _painted_vertices)


# ---------------------------------------------------------------------------
# Case 4 — large happy (the oracle case)
# ---------------------------------------------------------------------------

## The channel round trip is weighed before anything unwraps it — same broker,
## same backend, same channel the panel's own evaluation rides.
func _case_large_happy() -> void:
	print("\n-- large happy: a tessellation bigger than the control lane allows --")
	var cap: int = load(PANEL_BROKER_PATH).MAX_PAYLOAD_BYTES
	var request := {"source": LARGE_SOURCE}
	var envelope: Dictionary = await _panel.call_backend(
			EVALUATE_CHANNEL, request, EVAL_TIMEOUT_MS)
	var weighed: Dictionary = guard.weigh("large-happy", request, envelope,
			"control cap %d B" % cap)
	guard.check("large-happy: the DSL that goes out is far under the control cap "
			+ "— the reply is what is on trial",
			int(weighed["request_bytes"]) < cap,
			"request=%d cap=%d" % [int(weighed["request_bytes"]), cap])
	guard.check("large-happy: the reply really is over the control cap",
			int(weighed["reply_bytes"]) > cap,
			"reply=%d cap=%d" % [int(weighed["reply_bytes"]), cap])
	guard.expect_not_oversize_refusal("large-happy", envelope)

	var payload: Dictionary = _worker_payload(envelope)
	guard.expect_success("large-happy", payload)
	var mesh: Dictionary = _result_of(payload).get("mesh", {})
	guard.expect_document("large-happy", "the vertices the worker tessellated",
			(mesh.get("vertices", []) as Array).size())

	# The same feature question, asked of the clean large model: case 6's
	# baseline, weighed by the same helper so the two numbers share a
	# derivation.
	var clean: Dictionary = await _weigh_features("large-happy(features)",
			LARGE_SOURCE, EVAL_TIMEOUT_MS)
	guard.expect_success("large-happy(features)", _worker_payload(clean))


# ---------------------------------------------------------------------------
# Case 5 — large unhappy
# ---------------------------------------------------------------------------

## A document that builds the whole plate and only THEN names a function that
## does not exist: the refusal arrives after cad's large work rather than
## instead of it, which is the case a small typo fixture cannot reach. The
## refusal must still be structured, and the model on screen must survive it.
func _case_large_unhappy() -> void:
	print("\n-- large unhappy: a 64-hole plate built, then refused --")
	var source := _plate_source() + "part = boxx(part)\n"
	var request := {"source": source}
	var envelope: Dictionary = await _panel.call_backend(
			EVALUATE_CHANNEL, request, PLATE_TIMEOUT_MS)
	guard.weigh("large-unhappy", request, envelope)
	guard.expect_not_oversize_refusal("large-unhappy", envelope)
	var code := guard.expect_refusal("large-unhappy",
			_worker_payload(envelope), WORKER_CODE_KEYS)
	guard.check_eq("large-unhappy: the refusal is the same translate-time one the "
			+ "small document got", code, CODE_TRANSLATE)

	await _push_source(source, PLATE_TIMEOUT_MS)
	guard.expect_unchanged("large-unhappy", "the vertices painted in the viewport",
			_painted(), _painted_vertices)


# ---------------------------------------------------------------------------
# Case 6 — the large-with-errors reply
# ---------------------------------------------------------------------------

## What grows here is the FINDINGS LIST, not the geometry: one record per bore,
## so the reply that reports what is wrong with a document is bigger than the
## reply that reports a clean one — the same call, the same question, a boundary
## the clean answer never reaches.
func _case_large_error_reply() -> void:
	print("\n-- large-with-errors reply: one feature record per hole --")
	var envelope: Dictionary = await _weigh_features("large-errors",
			_plate_source(), PLATE_TIMEOUT_MS)
	guard.expect_not_oversize_refusal("large-errors", envelope)
	var payload: Dictionary = _worker_payload(envelope)
	guard.expect_success("large-errors", payload)

	var result: Dictionary = _result_of(payload)
	var cylinders: Array = result.get("cylinders", [])
	guard.check_eq("large-errors: the reply names every bore the fixture cut",
			cylinders.size(), _count_holes(_plate_source()))

	var wrong: Array = []
	for entry in cylinders:
		var dia: float = float((entry as Dictionary).get("dia_mm", 0.0))
		if absf(dia - HOLE_RADIUS_MM * 2.0) > 0.01:
			wrong.append(dia)
	guard.check("large-errors: every record measures the fixture's own bore "
			+ "diameter (%.2f mm)" % (HOLE_RADIUS_MM * 2.0), wrong.is_empty(),
			"off-diameter records: %s" % str(wrong).left(200))

	var errors_bytes := guard.reply_bytes("large-errors")
	var clean_bytes := guard.reply_bytes("large-happy(features)")
	guard.check("large-errors: the findings-bearing reply outweighs the same call "
			+ "on the clean large model (%d B vs %d B)" % [errors_bytes, clean_bytes],
			errors_bytes > clean_bytes and clean_bytes > 0)

	# The boundary the clean answer never reaches: 64 bores of findings do not
	# fit the control lane, though the same question about a clean model fits
	# it a hundred times over.
	var cap: int = load(PANEL_BROKER_PATH).MAX_PAYLOAD_BYTES
	guard.check("large-errors: the findings reply is itself over the control cap "
			+ "(%d B vs cap %d B) — a boundary the clean reply never reaches"
			% [errors_bytes, cap], errors_bytes > cap)


# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------

func _teardown() -> void:
	if _panel != null and is_instance_valid(_panel):
		if _broker != null and not _panel_key.is_empty():
			_broker.unregister_panel("cad", _panel_key)
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
		var stop_result: Dictionary = await _pm.stop_plugin("cad")
		guard.check("teardown: the backend stops", bool(stop_result.get("ok", false)),
				str(stop_result))
	AnnotationHostRegistry._reset_for_test()


# ---------------------------------------------------------------------------
# Fixtures — generated here, nothing read from outside the repo
# ---------------------------------------------------------------------------

## One plate, HOLE_COUNT bores of one diameter cut out of it on a grid. Built
## rather than pasted so the hole count and the feature window stay one number
## each, and so `_count_holes` can read the count back off the text the worker
## was given rather than off the loop that wrote it.
func _plate_source() -> String:
	var out := "part = cube(%.1f, %.1f, %.1f)\n" % [
		PLATE_SPAN_MM, PLATE_SPAN_MM, PLATE_THICKNESS_MM]
	for i in range(HOLE_COUNT):
		var x := 20.0 + float(i % HOLE_COLUMNS) * HOLE_PITCH_MM
		var y := 20.0 + floor(float(i) / float(HOLE_COLUMNS)) * HOLE_PITCH_MM
		out += "part = part - translate([%.1f, %.1f, -1], cylinder(h=%.1f, r=%.2f))\n" % [
			x, y, PLATE_THICKNESS_MM + 2.0, HOLE_RADIUS_MM]
	return out


## Count the bores by reading the source text, independently of the loop that
## wrote it — the number the feature reply must agree with.
func _count_holes(source: String) -> int:
	var n := 0
	for line in source.split("\n"):
		if line.findn("cylinder(") != -1:
			n += 1
	return n


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

## Push source the way an editor does (a versioned text_changed) and wait for
## the evaluation it triggers. The panel debounces the push by 0.25 s, so the
## settle wait is what puts an evaluation in flight before it is awaited.
## Returns the panel's own last_eval — the dict an MCP caller reads.
func _push_source(source: String, timeout_ms: int) -> Dictionary:
	_version += 1
	_panel.receive("text_changed", {"version": _version, "text": source})
	await create_timer(DEBOUNCE_SETTLE_SEC).timeout
	var waited: Dictionary = await _panel.await_evaluation(timeout_ms)
	var last_eval: Dictionary = waited.get("last_eval", {})
	if bool(waited.get("timed_out", false)):
		printerr("  the evaluation did not settle in %d ms" % timeout_ms)
	return last_eval


## One evaluate round trip, unwrapped to the worker's own {ok, result|error}.
func _evaluate_payload(source: String, timeout_ms: int) -> Dictionary:
	var envelope: Dictionary = await _panel.call_backend(
			EVALUATE_CHANNEL, {"source": source}, timeout_ms)
	return _worker_payload(envelope)


## One weighed feature round trip, asked exactly as the fastener check asks it.
func _weigh_features(case_name: String, source: String, timeout_ms: int) -> Dictionary:
	var request := {
		"source": source,
		"sense": "concave",
		"closed_only": false,
		"min_dia_mm": FEATURE_MIN_DIA_MM,
		"max_dia_mm": FEATURE_MAX_DIA_MM,
	}
	var envelope: Dictionary = await _panel.call_backend(
			FEATURES_CHANNEL, request, timeout_ms)
	guard.weigh(case_name, request, envelope)
	return envelope


## The worker's own payload inside the host's scene envelope: the broker wraps
## {ok, result|error} in {success, result}, and a worker refusal rides a
## SUCCESSFUL transport, so the two layers answer different questions.
func _worker_payload(envelope: Dictionary) -> Dictionary:
	var inner: Variant = envelope.get("result", null)
	return inner if inner is Dictionary else {}


func _result_of(payload: Dictionary) -> Dictionary:
	var inner: Variant = payload.get("result", null)
	return inner if inner is Dictionary else {}


## The vertices standing in the iso viewport, or -1 when nothing is painted.
## The display expands each face into its own three corners, so this counts
## corners, not the worker's vertex list — it is compared only against itself.
func _painted() -> int:
	var mesh_instance := _panel.get_node_or_null(ISO_MESH_INSTANCE) as MeshInstance3D
	if mesh_instance == null or mesh_instance.mesh == null \
			or mesh_instance.mesh.get_surface_count() == 0:
		return -1
	var arrays: Array = mesh_instance.mesh.surface_get_arrays(0)
	return (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
