extends SceneTree
## Which evaluation is the report on screen about?
##
## WHY THIS SUITE LOOKS THE WAY IT DOES
##
## The panel shouts one line when an evaluation finds trouble — a reference
## that would not load, a solid that runs into one. The owner's finding was
## that the line said nothing about WHICH evaluation it came from: an edit that
## fixed the fault left the same red bar standing, and there was no way to tell
## that from a fault that was still there. Closing it was not possible either,
## and it sat over the controls at the top of the panel.
##
## So what is pinned here is the report's IDENTITY, not its wording:
##
##   an interfering evaluation paints a stamped report;
##   closing it hides THAT report;
##   the NEXT evaluation, interfering just the same, reports again under its
##     own stamp — the dismissal does not carry over;
##   an evaluation that finds nothing clears the report rather than leaving
##     the previous one standing;
##   and last_eval carries the same state, because the owner reads the banner
##     and an agent reads the wire.
##
## The interference is real: a board is written out as an STL and mounted as a
## reference by the panel's own evaluation path, and the solid the worker
## "returns" is a block that runs through it. Nothing about the banner is asked
## of a stubbed check.
##
## The worker is stood in for the same way test_eval_await.gd does it — the
## suite watches the panel's `request` signal and hands the answer back through
## the broker — so this suite chooses what each evaluation finds.
##
## Run:
##   scripts/run-gd-tests.sh --plugin cad <path-to-minerva-checkout>

const PANEL_SCENE_PATH := "res://../../minerva-plugins/cad/ui/CADPanel.tscn"

const DocumentBufferScript := preload("res://Scripts/Services/Documents/DocumentBuffer.gd")
const PanelBrokerScript := preload("res://Scripts/Services/Plugins/PluginScenePanelBroker.gd")

## The board the solid runs into: 40 x 30 in x and y, 2 mm thick, sitting on
## the world origin. Written as an ASCII STL whose solid name becomes the
## reference's node name.
const BOARD_MIN := Vector3(0.0, 0.0, 0.0)
const BOARD_MAX := Vector3(40.0, 30.0, 2.0)
const BOARD_NAME := "board"

## The interfering solid: a post driven through the middle of the board.
const POST_MIN := Vector3(15.0, 10.0, -3.0)
const POST_MAX := Vector3(25.0, 20.0, 6.0)
## The same post lifted clear of the board's top face.
const CLEAR_LIFT := Vector3(0.0, 0.0, 8.0)

## Enough for the debounce, the worker round trip and the interference check's
## physics steps.
const SETTLE_SEC := 0.6

var _pass: int = 0
var _fail: int = 0
var _document_path: String = ""
var _board_path: String = ""


func _init() -> void:
	print("=== CAD Evaluation Banner Test ===\n")
	await process_frame
	await _run()
	_cleanup()
	await process_frame
	await process_frame
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func _run() -> void:
	_document_path = OS.get_user_data_dir().path_join("cad_banner_doc.mcad")
	_board_path = OS.get_user_data_dir().path_join("cad_banner_board.stl")
	_write_ascii_stl(_board_path, BOARD_NAME, BOARD_MIN, BOARD_MAX)
	_write_text(_document_path, "part = cube(10, 10, 10)\n")

	var rig := _make_rig("cad_panel_banner")
	if rig.is_empty():
		return
	var panel: Node = rig["panel"]
	_attach_document(rig, "part = cube(10, 10, 10)\n")

	# ── An evaluation that finds interference reports it, stamped ──────────
	await _answer_next(rig, _worker_answer(POST_MIN, POST_MAX))
	var first: Dictionary = _banner(panel)
	check("interference: the evaluation that found it says so on screen",
			bool(first.get("visible", false))
				and str(first.get("text", "")).contains("Interference"),
			"banner = %s" % str(first))
	check("interference: the report names the evaluation it belongs to, so it "
			+ "can be told from the one before it",
			not str(first.get("stamp", "")).is_empty()
				and not str(first.get("eval", "")).is_empty(),
			"banner = %s" % str(first))
	# Field by field: two Dictionaries built by separate calls are not the same
	# object, and what matters is that they say the same thing.
	var wire: Dictionary = _wire_banner(panel)
	check("interference: an agent reads the same report the owner does",
			bool(wire.get("visible", false)) == bool(first.get("visible", true))
				and str(wire.get("text", "")) == str(first.get("text", "<none>"))
				and str(wire.get("eval", "")) == str(first.get("eval", "<none>"))
				and str(wire.get("stamp", "")) == str(first.get("stamp", "<none>")),
			"last_eval.banner = %s vs banner = %s" % [str(wire), str(first)])

	# ── Closing it hides THAT report ───────────────────────────────────────
	panel._eval_banner.dismiss()
	var closed: Dictionary = _banner(panel)
	check("dismiss: the reader can close the report, and the wire says it was "
			+ "closed rather than never made",
			not bool(closed.get("visible", true))
				and bool(closed.get("dismissed", false))
				and str(closed.get("text", "")).contains("Interference")
				and bool(_wire_banner(panel).get("dismissed", false)),
			"banner = %s wire = %s" % [str(closed), str(_wire_banner(panel))])

	# ── THE ACCEPTANCE TEST: the next evaluation is not dismissed in advance ─
	(rig["buffer"] as Object).apply_edit("part = cube(11, 10, 10)\n")
	await _answer_next(rig, _worker_answer(POST_MIN, POST_MAX))
	var second: Dictionary = _banner(panel)
	check("later evaluation: a NEW report about the SAME fault shows itself — "
			+ "the closed one did not dismiss the evaluations after it",
			bool(second.get("visible", false))
				and not bool(second.get("dismissed", true))
				and str(second.get("text", "")).contains("Interference"),
			"banner = %s" % str(second))
	check("later evaluation: and it is stamped with its own evaluation, not "
			+ "the closed one's",
			str(second.get("eval", "")) != str(first.get("eval", ""))
				and not str(second.get("stamp", "")).is_empty(),
			"first = %s second = %s" % [str(first), str(second)])

	# ── A clean evaluation clears it ───────────────────────────────────────
	(rig["buffer"] as Object).apply_edit("part = cube(12, 10, 10)\n")
	await _answer_next(rig,
			_worker_answer(POST_MIN + CLEAR_LIFT, POST_MAX + CLEAR_LIFT))
	var cleared: Dictionary = _banner(panel)
	check("clean evaluation: the report is GONE, not left standing from the "
			+ "evaluation before it",
			not bool(cleared.get("visible", true))
				and str(cleared.get("text", "")).is_empty()
				and not bool(cleared.get("dismissed", true)),
			"banner = %s last_eval.interference = %s" % [
				str(cleared), str(_last_eval(panel).get("interference", {}))])

	# ── It cannot cover a control: it is anchored to the panel's bottom ────
	var banner_node: Control = panel._eval_banner as Control
	check("layout: the banner is anchored along the BOTTOM of the panel, where "
			+ "no layout puts a control, and passes the mouse through to the "
			+ "pane behind it",
			banner_node != null
				and is_equal_approx(banner_node.anchor_top, 1.0)
				and is_equal_approx(banner_node.anchor_bottom, 1.0)
				and banner_node.grow_vertical == Control.GROW_DIRECTION_BEGIN
				and banner_node.mouse_filter == Control.MOUSE_FILTER_IGNORE,
			"anchor_top=%s anchor_bottom=%s grow_vertical=%s mouse_filter=%s" % [
				str(banner_node.anchor_top) if banner_node != null else "<none>",
				str(banner_node.anchor_bottom) if banner_node != null else "<none>",
				str(banner_node.grow_vertical) if banner_node != null else "<none>",
				str(banner_node.mouse_filter) if banner_node != null else "<none>",
			])
	_teardown(rig)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

## Let the debounce fire, answer the evaluation it dispatched, and wait for the
## panel to finish painting — the interference check runs after the paint and
## costs physics steps, so the banner is not settled when the mesh is.
func _answer_next(rig: Dictionary, worker_payload: Dictionary) -> void:
	await create_timer(0.4).timeout
	var evaluations: Array = _evaluations(rig["dispatched"])
	if evaluations.is_empty():
		return
	var last: Dictionary = evaluations[evaluations.size() - 1]
	_reply(rig, str(last["reply_id"]), worker_payload)
	await create_timer(SETTLE_SEC).timeout


func _banner(panel: Node) -> Dictionary:
	if panel._eval_banner == null:
		return {}
	return panel._eval_banner.state_for_mcp()


## The banner as minerva_doc_read / minerva_cad_await_eval deliver it.
func _wire_banner(panel: Node) -> Dictionary:
	return _last_eval(panel).get("banner", {}) as Dictionary


func _last_eval(panel: Node) -> Dictionary:
	return panel._on_panel_save_request().get("last_eval", {}) as Dictionary


## An answer in the shape the worker emits: a box solid, and the board mounted
## as a reference beside it.
func _worker_answer(low: Vector3, high: Vector3) -> Dictionary:
	return {
		"ok": true,
		"result": {
			"shape_name": "part",
			"body_count": 1,
			"mesh": _box_mesh(low, high),
			"edges": [],
			"references": [{
				"name": BOARD_NAME,
				"path": _board_path,
				# Said out loud so the STL's silence about units is not itself
				# reported on the banner this suite is measuring.
				"units": "mm",
				"up": "z",
				"matrix": [
					[1.0, 0.0, 0.0, 0.0],
					[0.0, 1.0, 0.0, 0.0],
					[0.0, 0.0, 1.0, 0.0],
					[0.0, 0.0, 0.0, 1.0],
				],
			}],
		},
	}


## The eight corners and twelve triangles of an axis-aligned box, in the
## {vertices, faces} shape the worker returns.
func _box_mesh(low: Vector3, high: Vector3) -> Dictionary:
	var corners: Array = []
	for corner in _box_corners(low, high):
		corners.append([corner.x, corner.y, corner.z])
	return {"vertices": corners, "faces": _BOX_FACES}


const _BOX_FACES: Array = [
	[0, 1, 2], [0, 2, 3], [4, 6, 5], [4, 7, 6],
	[0, 4, 5], [0, 5, 1], [1, 5, 6], [1, 6, 2],
	[2, 6, 7], [2, 7, 3], [3, 7, 4], [3, 4, 0],
]


static func _box_corners(low: Vector3, high: Vector3) -> Array:
	return [
		Vector3(low.x, low.y, low.z), Vector3(high.x, low.y, low.z),
		Vector3(high.x, high.y, low.z), Vector3(low.x, high.y, low.z),
		Vector3(low.x, low.y, high.z), Vector3(high.x, low.y, high.z),
		Vector3(high.x, high.y, high.z), Vector3(low.x, high.y, high.z),
	]


## An ASCII STL of one box. The solid name becomes the reference's node name,
## which is what the interference line reports the offender by.
func _write_ascii_stl(path: String, solid_name: String,
		low: Vector3, high: Vector3) -> void:
	var corners: Array = _box_corners(low, high)
	var text := "solid %s\n" % solid_name
	for face in _BOX_FACES:
		text += "facet normal 0 0 0\n  outer loop\n"
		for index in (face as Array):
			var vertex: Vector3 = corners[int(index)]
			text += "    vertex %f %f %f\n" % [vertex.x, vertex.y, vertex.z]
		text += "  endloop\nendfacet\n"
	text += "endsolid %s\n" % solid_name
	_write_text(path, text)


func _write_text(path: String, text: String) -> void:
	var handle := FileAccess.open(path, FileAccess.WRITE)
	if handle != null:
		handle.store_string(text)
		handle.close()


## The real panel scene, the real broker, and a recorder for everything the
## panel asks the backend for. Same rig as test_eval_await.gd: the broker here
## has no PluginManager, so its dispatch trampoline is dropped and THIS SUITE
## is the backend.
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


func _attach_document(rig: Dictionary, text: String) -> void:
	var buffer = DocumentBufferScript.new(_document_path, text)
	rig["buffer"] = buffer
	(rig["broker"] as Object).attach_buffer_to_panel("cad", str(rig["panel_name"]), buffer)


func _reply(rig: Dictionary, reply_id: String, worker_payload: Dictionary) -> void:
	(rig["broker"] as Object)._deliver_reply(str(rig["panel_name"]), reply_id,
			{"success": true, "result": worker_payload})


func _evaluations(dispatched: Array) -> Array:
	var out: Array = []
	for entry in dispatched:
		if str((entry as Dictionary)["channel"]) == "cad.evaluate":
			out.append(entry)
	return out


func _teardown(rig: Dictionary) -> void:
	# Freed immediately, not queued: a queued free right before quit() never
	# gets its frame, which Godot reports as resources still in use at exit.
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
	for path in [_document_path, _board_path]:
		if str(path) != "" and FileAccess.file_exists(str(path)):
			DirAccess.remove_absolute(str(path))


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
