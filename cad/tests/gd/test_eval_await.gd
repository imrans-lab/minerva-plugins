extends SceneTree
## Waiting for an evaluation the worker is still computing.
##
## WHY THIS SUITE LOOKS THE WAY IT DOES
##
## A heavy document (three lofts, ~100 booleans) takes the worker minutes. The
## panel's await used to end at a fixed limit, after which the worker's answer
## arrived at an IPC helper with nobody waiting for it and was dropped as a
## stale reply: nothing painted, and last_eval — the only thing an agent can
## read — said "pending" forever. Raising the limit only moves the cliff, so
## what is pinned here is that a reply landing after MANY expiries of the
## panel's own await window still paints, that a panel which does give up says
## so with the time it waited, and that opening a document costs the worker ONE
## evaluation rather than two.
##
## The worker is stood in for: the suite watches the panel's `request` signal
## and hands the answer back the way the host does (broker reply delivery), so
## the timing of the reply — the whole subject — is the suite's to choose.
## The panel's await window and give-up budget are shortened to milliseconds;
## nothing else about the wait changes.
##
## Run:
##   scripts/run-gd-tests.sh --plugin cad <path-to-minerva-checkout>

const PANEL_SCENE_PATH := "res://../../minerva-plugins/cad/ui/CADPanel.tscn"

## Host classes, preloaded by path rather than by class_name: this script is
## parsed from outside Minerva's res:// tree, and the paths are pinned in
## tests/gd/REQUIRED_HOST_FILES so a host refactor fails by name.
const DocumentBufferScript := preload("res://Scripts/Services/Documents/DocumentBuffer.gd")
const PanelBrokerScript := preload("res://Scripts/Services/Plugins/PluginScenePanelBroker.gd")

const SOURCE := "part = cube(10, 10, 10)\n"
const EDITED_SOURCE := "part = cube(20, 10, 10)\n"

## The pane whose MeshInstance is read as "the answer is on screen". The iso
## view is the one that shows the shaded solid in every width class.
const ISO_MESH_INSTANCE := (
	"ResponsiveContainer/WideLayout/VBoxContainer/GridContainer/IsoView/"
	+ "SubViewport/MeshRoot/MeshInstance"
)

## Short enough that half a second of waiting crosses it many times over.
const CHUNK_MS := 60
## Long enough that the waits in this suite never reach it, except where a
## give-up is what is being tested.
const PATIENT_GIVE_UP_MS := 30000

var _pass: int = 0
var _fail: int = 0
var _document_path: String = ""


func _init() -> void:
	print("=== CAD Evaluation Await Test ===\n")
	await process_frame
	await _run()
	_cleanup()
	# Two frames so the rendering server releases the freed panels' viewport
	# textures before quit; otherwise they are reported as leaked at exit.
	await process_frame
	await process_frame
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func _run() -> void:
	_document_path = OS.get_user_data_dir().path_join("cad_eval_await_doc.mcad")
	var document := FileAccess.open(_document_path, FileAccess.WRITE)
	if document != null:
		document.store_string(SOURCE)
		document.close()

	await _test_a_slow_answer_is_still_painted()
	await _test_one_open_is_one_evaluation()
	await _test_giving_up_is_said_out_loud()
	await _test_a_newer_evaluation_still_preempts_an_older_one()
	await _test_awaiting_covers_the_debounce_as_well_as_the_worker()


# ---------------------------------------------------------------------------
# THE ACCEPTANCE TEST: however long the worker took, the answer is painted
# ---------------------------------------------------------------------------

func _test_a_slow_answer_is_still_painted() -> void:
	var rig := _make_rig("cad_panel_slow")
	if rig.is_empty():
		return
	var panel: Node = rig["panel"]
	panel._eval_await_chunk_ms = CHUNK_MS
	panel._eval_give_up_ms = PATIENT_GIVE_UP_MS

	_attach_document(rig, SOURCE)
	var dispatched: Array = rig["dispatched"]
	var evaluations: Array = _evaluations(dispatched)
	check("open: attaching the document dispatched one evaluation",
			evaluations.size() == 1,
			"dispatched %s" % str(dispatched))
	if evaluations.is_empty():
		_teardown(rig)
		return

	# Far longer than the panel's own await window — the reply the old panel
	# threw away as stale lands here.
	await create_timer(CHUNK_MS * 8 / 1000.0).timeout
	check("wait: an evaluation the worker has not answered yet is still pending, "
			+ "not abandoned, after many expiries of the await window",
			_status(panel) == "pending",
			"last_eval = %s" % str(_last_eval(panel)))

	_reply(rig, str((evaluations[0] as Dictionary)["reply_id"]), _worker_answer())
	await create_timer(0.3).timeout

	check("paint: the late answer is recorded as the evaluation's result",
			_status(panel) == "ok"
				and int(_last_eval(panel).get("vertex_count", 0)) == 8,
			"last_eval = %s" % str(_last_eval(panel)))
	var mesh_instance := panel.get_node_or_null(ISO_MESH_INSTANCE) as MeshInstance3D
	check("paint: the late answer reaches the viewport as geometry",
			mesh_instance != null and mesh_instance.mesh != null,
			"mesh_instance=%s mesh=%s" % [
				str(mesh_instance),
				str(mesh_instance.mesh) if mesh_instance != null else "<no node>",
			])
	_teardown(rig)


# ---------------------------------------------------------------------------
# One open, one evaluation — in either delivery order
# ---------------------------------------------------------------------------

func _test_one_open_is_one_evaluation() -> void:
	for load_first in [true, false]:
		var rig := _make_rig("cad_panel_open_%s" % str(load_first))
		if rig.is_empty():
			return
		var panel: Node = rig["panel"]
		panel._eval_await_chunk_ms = CHUNK_MS
		panel._eval_give_up_ms = PATIENT_GIVE_UP_MS

		# What the host does on an open: it hands the panel the file AND
		# attaches the buffer the paired text editor shows. Both carry the
		# same source; only one of them is worth a worker's time.
		if load_first:
			panel._on_panel_load_request({"file_path": _document_path})
			_attach_document(rig, SOURCE)
		else:
			_attach_document(rig, SOURCE)
			panel._on_panel_load_request({"file_path": _document_path})

		# Long enough for the typing debounce to have fired had one been armed.
		await create_timer(0.6).timeout
		var evaluations: Array = _evaluations(rig["dispatched"])
		check("open (load %s attach): the document is evaluated ONCE"
				% ("before" if load_first else "after"),
				evaluations.size() == 1,
				"%d evaluations dispatched: %s" % [
					evaluations.size(), str(rig["dispatched"])])
		if not evaluations.is_empty():
			var payload: Dictionary = (evaluations[0] as Dictionary)["payload"]
			check("open (load %s attach): that evaluation carries a request_id, "
					% ("before" if load_first else "after")
					+ "so a newer one can cancel it",
					not str(payload.get("request_id", "")).is_empty(),
					"payload = %s" % str(payload))
		_teardown(rig)


# ---------------------------------------------------------------------------
# Giving up is a fact the reader gets, not silence
# ---------------------------------------------------------------------------

func _test_giving_up_is_said_out_loud() -> void:
	var rig := _make_rig("cad_panel_giveup")
	if rig.is_empty():
		return
	var panel: Node = rig["panel"]
	panel._eval_await_chunk_ms = 30
	panel._eval_give_up_ms = 120

	_attach_document(rig, SOURCE)
	# The worker never answers. Well past the give-up budget.
	await create_timer(0.6).timeout

	var last_eval: Dictionary = _last_eval(panel)
	check("give-up: the abandoned evaluation reports timeout with the time it waited",
			str(last_eval.get("status", "")) == "timeout"
				and int(last_eval.get("elapsed_ms", 0)) >= 120,
			"last_eval = %s" % str(last_eval))
	var banner := panel._error_banner as CanvasItem
	var banner_text: String = str(panel._error_banner_label.text) if panel._error_banner_label != null else ""
	check("give-up: the user is told on screen, with the wait in the message",
			banner != null and banner.visible and banner_text.contains("gave up"),
			"visible=%s text='%s'" % [
				str(banner.visible) if banner != null else "<no banner>", banner_text])
	_teardown(rig)


# ---------------------------------------------------------------------------
# Cancel-on-supersede still holds
# ---------------------------------------------------------------------------

func _test_a_newer_evaluation_still_preempts_an_older_one() -> void:
	var rig := _make_rig("cad_panel_supersede")
	if rig.is_empty():
		return
	var panel: Node = rig["panel"]
	panel._eval_await_chunk_ms = CHUNK_MS
	panel._eval_give_up_ms = PATIENT_GIVE_UP_MS

	_attach_document(rig, SOURCE)
	var first: Array = _evaluations(rig["dispatched"])
	if first.is_empty():
		_teardown(rig)
		return
	var first_entry: Dictionary = first[0]
	var first_request_id: String = str((first_entry["payload"] as Dictionary).get("request_id", ""))

	# The user types: the buffer's edit reaches the panel as text_changed and,
	# once the debounce has run, becomes a second evaluation.
	(rig["buffer"] as Object).apply_edit(EDITED_SOURCE)
	await create_timer(0.5).timeout

	var cancelled_ids: Array = []
	for entry in rig["dispatched"]:
		if str((entry as Dictionary)["channel"]) == "cad.cancel_eval":
			cancelled_ids.append(str(((entry as Dictionary)["payload"] as Dictionary).get("request_id", "")))
	check("supersede: the newer evaluation cancelled the older one by request id",
			cancelled_ids.has(first_request_id) and _evaluations(rig["dispatched"]).size() == 2,
			"cancelled=%s dispatched=%s" % [str(cancelled_ids), str(rig["dispatched"])])

	# The displaced worker answers anyway. Waiting without a limit must not
	# mean painting an answer about text nobody is looking at any more.
	_reply(rig, str(first_entry["reply_id"]), _worker_answer())
	await create_timer(0.2).timeout
	check("supersede: the displaced evaluation's answer is not painted",
			_status(panel) == "pending",
			"last_eval = %s" % str(_last_eval(panel)))

	var second: Array = _evaluations(rig["dispatched"])
	_reply(rig, str((second[1] as Dictionary)["reply_id"]), _worker_answer())
	await create_timer(0.3).timeout
	check("supersede: the newest evaluation's answer is the one that paints",
			_status(panel) == "ok",
			"last_eval = %s" % str(_last_eval(panel)))
	_teardown(rig)


# ---------------------------------------------------------------------------
# Waiting on a buffer edit: the debounce is part of the wait
# ---------------------------------------------------------------------------

## minerva_doc_edit reaches the panel as a buffer text_changed, which arms the
## debounce and returns. For the quarter-second before that timer fires there
## is no evaluation in flight and last_eval still holds the PREVIOUS result:
## a wait that only watched for status "pending" would return immediately and
## hand the caller the geometry the edit replaced.
func _test_awaiting_covers_the_debounce_as_well_as_the_worker() -> void:
	var rig := _make_rig("cad_panel_await_verb")
	if rig.is_empty():
		return
	var panel: Node = rig["panel"]
	panel._eval_await_chunk_ms = CHUNK_MS
	panel._eval_give_up_ms = PATIENT_GIVE_UP_MS

	_attach_document(rig, SOURCE)
	var opened: Array = _evaluations(rig["dispatched"])
	if opened.is_empty():
		_teardown(rig)
		return
	_reply(rig, str((opened[0] as Dictionary)["reply_id"]), _worker_answer())
	await create_timer(0.2).timeout

	# The edit lands. Nothing has been dispatched yet — the debounce is armed.
	(rig["buffer"] as Object).apply_edit(EDITED_SOURCE)
	# A lambda captures by VALUE, so the result comes back through a shared
	# Dictionary rather than through an assignment the caller would never see.
	var outcome: Dictionary = {"settled": false, "reply": {}}
	var wait := func() -> void:
		var answer: Dictionary = await panel.await_evaluation(5000)
		outcome["reply"] = answer
		outcome["settled"] = true
	wait.call()
	await create_timer(0.1).timeout
	check("await: an edit still inside the debounce is not settled — the "
			+ "previous result is not the answer to this edit",
			not bool(outcome["settled"]),
			"the wait returned %s while the debounce was still running"
				% str(outcome["reply"]))

	# The debounce fires, the evaluation goes out, and the worker answers.
	await create_timer(0.4).timeout
	var dispatched: Array = _evaluations(rig["dispatched"])
	if dispatched.size() >= 2:
		_reply(rig, str((dispatched[1] as Dictionary)["reply_id"]), _worker_answer())
	await create_timer(0.4).timeout
	check("await: it returns once the panel has PAINTED, with the status it "
			+ "painted and the time it waited",
			bool(outcome["settled"])
				and not bool((outcome["reply"] as Dictionary).get("timed_out", true))
				and str(((outcome["reply"] as Dictionary).get("last_eval", {})
					as Dictionary).get("status", "")) == "ok"
				and int((outcome["reply"] as Dictionary).get("waited_ms", 0)) >= 100,
			"waited = %s" % str(outcome["reply"]))
	_teardown(rig)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

## The real panel scene, the real broker, and a recorder for everything the
## panel asks the backend for. Returns {} when the scene will not instantiate,
## which is reported once rather than crashing every later assertion.
func _make_rig(panel_name: String) -> Dictionary:
	var packed: PackedScene = load(PANEL_SCENE_PATH)
	var panel: Node = packed.instantiate() if packed != null else null
	check("setup: the CAD panel scene instantiates", panel != null,
			"could not instantiate %s" % PANEL_SCENE_PATH)
	if panel == null:
		return {}
	root.add_child(panel)

	var broker = PanelBrokerScript.new()
	broker.register_panel(panel, "cad", panel_name,
			PackedStringArray(["cad.evaluate", "cad.cancel_eval"]))
	# register_panel also wires the panel's `request` signal to the broker's
	# own dispatch, and THIS SUITE IS THE BACKEND: the broker here has no
	# PluginManager, so it has no manifest to validate the panel against and
	# no running plugin connection to forward to — it would answer every
	# request with permission_denied within a millisecond, and the worker
	# reply this suite delivers by hand would arrive at an IPC helper with
	# nobody waiting. Only the trampoline is dropped; the broker keeps doing
	# the parts the suite needs (the IPC helper, the buffer attach, and
	# reply delivery).
	for connection in panel.get_signal_connection_list("request"):
		panel.disconnect("request", (connection as Dictionary)["callable"] as Callable)
	panel._on_panel_loaded({
		"plugin_id": "cad",
		"panel_name": panel_name,
		"broker": broker,
		"host_api_version": "1",
	})

	var dispatched: Array = []
	panel.request.connect(func(channel: String, payload: Dictionary, reply_id: String) -> void:
		dispatched.append({"channel": channel, "payload": payload, "reply_id": reply_id}))

	return {
		"panel": panel,
		"broker": broker,
		"panel_name": panel_name,
		"dispatched": dispatched,
	}


## Attach a DocumentBuffer holding `text` — the substrate's own open path.
func _attach_document(rig: Dictionary, text: String) -> void:
	var buffer = DocumentBufferScript.new(_document_path, text)
	rig["buffer"] = buffer
	(rig["broker"] as Object).attach_buffer_to_panel("cad", str(rig["panel_name"]), buffer)


## Hand a worker reply back the way the host does.
func _reply(rig: Dictionary, reply_id: String, worker_payload: Dictionary) -> void:
	(rig["broker"] as Object)._deliver_reply(str(rig["panel_name"]), reply_id,
			{"success": true, "result": worker_payload})


## A worker answer for a unit cube: eight vertices, twelve triangles.
func _worker_answer() -> Dictionary:
	var vertices: Array = []
	for corner in [
		Vector3(0, 0, 0), Vector3(10, 0, 0), Vector3(10, 10, 0), Vector3(0, 10, 0),
		Vector3(0, 0, 10), Vector3(10, 0, 10), Vector3(10, 10, 10), Vector3(0, 10, 10),
	]:
		vertices.append([corner.x, corner.y, corner.z])
	var faces: Array = [
		[0, 1, 2], [0, 2, 3], [4, 6, 5], [4, 7, 6],
		[0, 4, 5], [0, 5, 1], [1, 5, 6], [1, 6, 2],
		[2, 6, 7], [2, 7, 3], [3, 7, 4], [3, 4, 0],
	]
	return {
		"ok": true,
		"result": {
			"shape_name": "part",
			"body_count": 1,
			"mesh": {"vertices": vertices, "faces": faces},
			"edges": [],
		},
	}


## Only the evaluations, in dispatch order — cancels and other channels are
## noise for a count of "how many times was the worker asked to evaluate".
func _evaluations(dispatched: Array) -> Array:
	var out: Array = []
	for entry in dispatched:
		if str((entry as Dictionary)["channel"]) == "cad.evaluate":
			out.append(entry)
	return out


## last_eval as an agent reads it — through the panel's save payload, which is
## what minerva_doc_read returns.
func _last_eval(panel: Node) -> Dictionary:
	var saved: Dictionary = panel._on_panel_save_request()
	return saved.get("last_eval", {}) as Dictionary


func _status(panel: Node) -> String:
	return str(_last_eval(panel).get("status", ""))


func _teardown(rig: Dictionary) -> void:
	# Freed immediately, not queued: the last rig is torn down right before
	# quit(), and a queued free never gets its frame, which Godot reports as
	# resources still in use at exit.
	var panel: Node = rig.get("panel", null)
	var broker: Object = rig.get("broker", null)
	if panel != null and is_instance_valid(panel):
		if broker != null:
			broker.detach_buffer_from_panel("cad", str(rig["panel_name"]))
		if panel.get_parent() != null:
			panel.get_parent().remove_child(panel)
		panel.free()
	if broker is Node and is_instance_valid(broker) and (broker as Node).get_parent() == null:
		(broker as Node).free()


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
