extends SceneTree
## A model whose tessellation does not fit the control lane still renders.
##
## WHY THIS SUITE EXISTS
##
## The host bounds an ordinary scene-panel reply at
## PluginScenePanelBroker.MAX_PAYLOAD_BYTES (64 KiB) in BOTH directions and
## replaces an over-cap reply with a payload_too_large error. A cad.evaluate
## reply carries the whole tessellation, so every cad document past a toy came
## back as that error and the panel painted nothing: a total outage that no
## suite could see, because every other cad suite stands in for the worker and
## a stood-in reply is never weighed by the host.
##
## So this one uses the REAL chain and nothing else — a real PluginManager, a
## real PluginScenePanelBroker, the real cad-plugin Go binary with its Python
## worker, and the real CADPanel scene — and it weighs the reply before
## asserting on what was painted:
##
##   the DSL that goes out is far under the cap, so the reply is what is on
##     trial;
##   the reply really is over the cap (measured here, not assumed);
##   it is not a payload_too_large refusal;
##   and the geometry on screen is the geometry the worker sent — the panel's
##     vertex count is the worker's own, and the ArrayMesh in the iso viewport
##     holds three corners per face the worker sent.
##
## Reverting the panel's send seam to the `request` signal turns the weighed
## round trip red with payload_too_large, and the paint assertions with it.
##
## THE FIXTURE is one line of DSL. A sphere tessellates into thousands of
## triangles: measured against this worker over stdio, `part = sphere(r=20)`
## answers with 4,066 vertices / 8,002 faces — a 371 KB reply, 5.7× the cap —
## in about two seconds. Nothing is read from outside the repo.
##
## SKIP CONTRACT: when the Go binary is not built on this host the live
## sections do not run and the suite says so loudly. Its assertion pin
## therefore describes a host that has built the plugin.
##
## Run:
##   scripts/run-gd-tests.sh --plugin cad <path-to-minerva-checkout>

const PANEL_SCENE_PATH := "res://../../minerva-plugins/cad/ui/CADPanel.tscn"

## Host classes, preloaded by path rather than by class_name: this script is
## parsed from outside Minerva's res:// tree, and the paths are pinned in
## tests/gd/REQUIRED_HOST_FILES so a host refactor fails by name.
const DocumentBufferScript := preload("res://Scripts/Services/Documents/DocumentBuffer.gd")
const PANEL_BROKER_PATH := "res://Scripts/Services/Plugins/PluginScenePanelBroker.gd"
const PLUGIN_MANAGER_PATH := "res://Scripts/Services/Plugins/PluginManager.gd"

const CAD_PLUGIN_DIR_REL := "/github/minerva-plugins/cad"
const CAD_BINARY_REL := "/cad-plugin"
const CAD_MANIFEST_REL := "/manifest.json"

## PluginDefinition.State values this suite waits on. The setup pipeline
## (python_venv + go_build) leaves an install BUILDING until it lands.
const S_RUNNING := 2
const S_BUILDING := 6
const S_BUILD_FAILED := 7

const MANIFEST_PANEL := "cad_panel"
const EVALUATE_CHANNEL := "cad.evaluate"

## One line in, a tessellation out. See the class doc for the measurement.
const FIXTURE_SOURCE := "part = sphere(r=20)\n"

## The pane whose MeshInstance is read as "the answer is on screen".
const ISO_MESH_INSTANCE := (
	"ResponsiveContainer/WideLayout/VBoxContainer/GridContainer/IsoView/"
	+ "SubViewport/MeshRoot/MeshInstance"
)

## OCCT tessellating a sphere and a cold build123d import, with room to spare
## on a loaded machine.
const EVAL_TIMEOUT_MS := 180000

var _pass: int = 0
var _fail: int = 0
var _pm: Node = null
var _broker: Object = null
var _panel: Node = null
var _panel_key: String = ""
var _document_path: String = ""
## The worker's own counts for the fixture, read off the weighed reply.
var _worker_vertices: int = -1
var _worker_faces: int = -1


func _init() -> void:
	print("=== CAD bulk-reply seam test ===\n")
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
			await _step_the_reply_is_over_the_cap()
			await _step_the_panel_paints_what_the_worker_sent()
		else:
			printerr("SETUP FAILED — the real chain did not mount; live steps not run")
		await _teardown()

	_cleanup()
	# Two frames so the rendering server releases the freed panel's viewport
	# textures before quit; otherwise they are reported as leaked at exit.
	await process_frame
	await process_frame
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


# ---------------------------------------------------------------------------
# Mount — real PluginManager + real broker + real panel, production order
# ---------------------------------------------------------------------------

func _mount(manifest_path: String) -> bool:
	var pm_script: Script = load(PLUGIN_MANAGER_PATH)
	if pm_script == null:
		printerr("  PluginManager.gd did not load")
		return false
	_pm = pm_script.new()
	root.add_child(_pm)
	await process_frame
	if _pm._db == null:
		printerr("  PluginManager did not initialise its database")
		return false

	var def = _pm._db.get_by_id("cad")
	# An install predating the current manifest's channel list would make the
	# broker deny cad.evaluate by allowlist — a permission_denied that looks
	# nothing like the cap this suite is about. Refresh through the manager's
	# own API so the assertions are about the manifest standing now.
	if def != null and not (EVALUATE_CHANNEL in def.ui_ipc_messages):
		print("  installed cad definition predates the manifest's channel list "
				+ "— refreshing via remove_plugin + install_plugin")
		if def.state == S_RUNNING:
			await _pm.stop_plugin("cad")
		await _pm.remove_plugin("cad", false)
		def = null
	if def == null:
		var install_result: Dictionary = await _pm.install_plugin(manifest_path, true)
		check("setup: install_plugin returns ok",
				bool(install_result.get("ok", false)), str(install_result))
		def = _pm._db.get_by_id("cad")
		# The cad manifest carries a `setup` stanza, so install starts the
		# python_venv + go_build pipeline on a worker thread. Wait it out:
		# go_build rewrites the very binary start_plugin would exec, and a
		# pipeline still running at process exit crashes engine teardown.
		if def != null and def.state == S_BUILDING:
			print("  setup pipeline building (python_venv + go_build) — waiting…")
			var deadline_ms: int = Time.get_ticks_msec() + 900000
			while def.state == S_BUILDING and Time.get_ticks_msec() < deadline_ms:
				await create_timer(0.5).timeout
			check("setup: the build pipeline finished and did not fail",
					def.state != S_BUILDING and def.state != S_BUILD_FAILED,
					"state=%d" % def.state)
	if def == null:
		printerr("  cad definition never reached the plugin database")
		return false
	check("setup: the installed definition declares %s" % EVALUATE_CHANNEL,
			EVALUATE_CHANNEL in def.ui_ipc_messages,
			"installed ui_ipc_messages=%s" % str(def.ui_ipc_messages))
	if def.state == S_RUNNING:
		await _pm.stop_plugin("cad")
	var start_result: Dictionary = await _pm.start_plugin("cad")
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
	check("setup: the CAD panel scene instantiates", _panel != null, PANEL_SCENE_PATH)
	if _panel == null:
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
	check("setup: the host offers the bulk route this fix rides",
			ipc != null and ipc.has_method("request_bulk"),
			"helper=%s" % str(ipc))
	for _i in range(4):
		await process_frame
	return ipc != null


# ---------------------------------------------------------------------------
# The reply, weighed
# ---------------------------------------------------------------------------

## The panel's own send seam, so the envelope can be measured before anything
## unwraps it — same broker, same backend, same channel the render below rides.
func _step_the_reply_is_over_the_cap() -> void:
	print("-- the evaluation reply is bigger than the control lane allows --")
	var cap: int = load(PANEL_BROKER_PATH).MAX_PAYLOAD_BYTES
	var request_bytes: int = JSON.stringify({"source": FIXTURE_SOURCE}).to_utf8_buffer().size()
	check("the DSL that goes out is far under the control cap — the reply is "
			+ "what is on trial",
			request_bytes < cap, "request=%d cap=%d" % [request_bytes, cap])

	var envelope: Dictionary = await _panel.call_backend(
			EVALUATE_CHANNEL, {"source": FIXTURE_SOURCE}, EVAL_TIMEOUT_MS)
	var reply_bytes: int = JSON.stringify(envelope).to_utf8_buffer().size()
	print("  measured: reply=%d bytes, control cap=%d bytes" % [reply_bytes, cap])
	check("the reply really is over the control cap",
			reply_bytes > cap, "reply=%d cap=%d" % [reply_bytes, cap])
	check("the reply is not a payload_too_large refusal",
			str(envelope.get("error_code", "")).findn("too_large") == -1
				and str(envelope.get("error_message", "")).findn("too large") == -1,
			str(envelope).left(400))

	var worker_payload: Variant = envelope.get("result")
	var result: Dictionary = {}
	if worker_payload is Dictionary and (worker_payload as Dictionary).get("result") is Dictionary:
		result = (worker_payload as Dictionary)["result"]
	var mesh: Dictionary = result.get("mesh", {}) if result.get("mesh") is Dictionary else {}
	_worker_vertices = (mesh.get("vertices", []) as Array).size()
	_worker_faces = (mesh.get("faces", []) as Array).size()
	check("the worker answered with a tessellation, not an error",
			bool(envelope.get("success", false)) and _worker_vertices > 0 and _worker_faces > 0,
			"vertices=%d faces=%d envelope=%s" % [
				_worker_vertices, _worker_faces, str(envelope).left(400)])


# ---------------------------------------------------------------------------
# The paint, against the worker's own numbers
# ---------------------------------------------------------------------------

## The production open path: a DocumentBuffer attached to the panel, which is
## how a .mcad reaches it, and the evaluation it triggers awaited to its end.
func _step_the_panel_paints_what_the_worker_sent() -> void:
	print("-- the panel renders that model --")
	_document_path = OS.get_user_data_dir().path_join("cad_bulk_reply_seam.mcad")
	var document := FileAccess.open(_document_path, FileAccess.WRITE)
	if document != null:
		document.store_string(FIXTURE_SOURCE)
		document.close()
	var buffer = DocumentBufferScript.new(_document_path, FIXTURE_SOURCE)
	_broker.attach_buffer_to_panel("cad", _panel_key, buffer)

	var waited: Dictionary = await _panel.await_evaluation(EVAL_TIMEOUT_MS)
	var last_eval: Dictionary = waited.get("last_eval", {})
	check("the evaluation the open dispatched came back and painted",
			not bool(waited.get("timed_out", false))
				and str(last_eval.get("status", "")) == "ok",
			"waited=%s" % str(waited).left(400))
	check("the panel's vertex count is the worker's own",
			int(last_eval.get("vertex_count", -1)) == _worker_vertices,
			"panel=%s worker=%d" % [str(last_eval.get("vertex_count")), _worker_vertices])

	# The display expands each face into its own three corners, so the mesh in
	# the viewport is counted against the FACES the worker sent.
	var mesh_instance := _panel.get_node_or_null(ISO_MESH_INSTANCE) as MeshInstance3D
	var painted_vertices: int = -1
	if mesh_instance != null and mesh_instance.mesh != null \
			and mesh_instance.mesh.get_surface_count() > 0:
		var arrays: Array = mesh_instance.mesh.surface_get_arrays(0)
		painted_vertices = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	check("the geometry in the viewport is the tessellation the worker sent",
			painted_vertices == _worker_faces * 3,
			"painted=%d worker_faces=%d" % [painted_vertices, _worker_faces])


# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------

func _teardown() -> void:
	if _panel != null and is_instance_valid(_panel):
		if _broker != null and not _panel_key.is_empty():
			_broker.detach_buffer_from_panel("cad", _panel_key)
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
		check("teardown: stop_plugin returns ok",
				bool(stop_result.get("ok", false)), str(stop_result))
	AnnotationHostRegistry._reset_for_test()


func _cleanup() -> void:
	if _document_path != "" and FileAccess.file_exists(_document_path):
		DirAccess.remove_absolute(_document_path)


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
