extends SceneTree
## THE RESOLVED-PLACEMENT MEMO NEVER OUTLIVES THE BOARD IT DESCRIBES.
##
## Run (via a Minerva scaffold as the Godot host — NEVER the live checkout):
##   godot --headless --path <minerva-scaffold>/src \
##     --script res://../../minerva-plugins/pcb/tests/gd/test_assembly_placements_memo.gd
##
## WHAT IS AT STAKE. PCBPanel.assembly_placements memoizes the compiler's reply
## because get_components / describe_component are hot reads and the answer is
## a strict compile. The memo's coordinates are board millimetres, so it is only
## ever right for the board it was computed on. The trap is a whole-board LOAD:
## the model deliberately leaves board_revision alone for a load (pcb_data.gd,
## LOAD-FAMILY EXCLUSIONS), so a memo keyed on the revision alone would answer
## a read on board B with board A's placements for every ref the two share.
##
## THE REAL PATH, NOT A STUB OF IT. The panel is the real PCBPanel, loaded the
## way the file-restore path loads it (_on_panel_load_request), and the reads
## go through panel_tools._get_components exactly as the verb does. The one
## thing stood in for is the broker: a child node named _MinervaIPC whose
## await_reply answers the placement channel from the board that request
## carried — each component's anchor x is that component's own x_mm — so the
## reply is a FUNCTION of the board asked about, and "A's numbers" and "B's
## numbers" are distinguishable by a single field. The load path makes a round
## trip of its own (pcb.deserialize, for designator anchors); the stub answers
## it with no board, so it neither counts as a read nor changes the model.
##
## FAILS AGAINST OLD: section C's first check goes red — the memo keyed on the
## revision alone serves A's anchor after B is loaded. Section E's first check
## goes red against the panel that returned an in-flight reply regardless: it
## handed A's placements to a caller that then listed B's components.

const PANEL_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"
const PANEL_TOOLS_PATH := "res://../../minerva-plugins/pcb/ui/panel_tools.gd"
const DRIVER := preload("res://test/helpers/plugin_panel_driver.gd")

const FOOTPRINT := "Resistor_SMD:R_0805_2012Metric"
const BOARD_A_X := 10.0
const BOARD_B_X := 20.0
const MOVED_X := 30.0
const MOVED_AGAIN_X := 35.0

var _pass := 0
var _fail := 0

var _driver = null
var _panel = null
var _host = null
var _data = null
var _tools: Script = null
var _ipc: StubIPC = null
var _board_dir := ""


## Stands in for the broker bridge. The panel emits `request` and then awaits
## `_MinervaIPC.await_reply`; this node files every request under its reply id
## and answers each from the payload THAT request carried, so a request that
## lands mid-round-trip (a load's pcb.deserialize inside a read) cannot replace
## the board the outer read asked about. Only pcb.assembly_placements is
## counted and answered with placements; every other channel gets a success
## envelope with no `board`, which _adopt_worker_anchors treats as nothing to
## adopt and the load runs to completion. `before_reply` runs inside the
## placement round trip, between the request and its answer — the window a
## load can fall into while a read is in flight.
class StubIPC:
	extends Node
	const PLACEMENTS := "pcb.assembly_placements"
	var calls: int = 0
	var requests: Dictionary = {}  # reply_id -> {channel, payload}
	var before_reply: Callable = Callable()

	func _init() -> void:
		name = "_MinervaIPC"

	func on_request(channel: String, payload: Dictionary, reply_id: String) -> void:
		requests[reply_id] = {"channel": channel, "payload": payload}

	func await_reply(reply_id: String, _timeout_ms: int) -> Dictionary:
		var req: Dictionary = requests.get(reply_id, {})
		if str(req.get("channel", "")) != PLACEMENTS:
			return {"success": true, "result": {}}
		calls += 1
		if before_reply.is_valid():
			before_reply.call()
		var payload: Dictionary = req.get("payload", {})
		var board: Dictionary = payload.get("board", {})
		var entries: Array = []
		for comp_v in (board.get("components", []) as Array):
			var comp: Dictionary = comp_v
			var x: float = float(comp.get("x_mm", 0.0))
			var y: float = float(comp.get("y_mm", 0.0))
			entries.append({"component": str(comp.get("ref", "")),
				"footprint": str(comp.get("footprint", "")),
				"populate": true, "paste": "auto",
				"physical": [{"ref": str(comp.get("ref", "")),
					"origin": {"x_mm": x, "y_mm": y},
					"anchor": {"x_mm": x, "y_mm": y},
					"anchor_basis": "fab_outline", "rotation_deg": 0.0,
					"side": "top", "footprint": str(comp.get("footprint", ""))}]})
		return {"success": true, "result": {"resolved": true, "components": entries}}


func _init() -> void:
	print("=== The resolved-placement memo across a board load ===\n")
	if not _setup():
		printerr("SETUP FAILED — cannot load the plugin panel; aborting")
		quit(1)
		return
	await _run_first_read_asks_the_worker()
	await _run_second_read_is_the_memo()
	await _run_load_of_another_board_misses()
	await _run_edit_misses()
	await _run_load_during_a_read_is_not_memoized()
	await _run_load_during_both_attempts_is_unavailable()
	_teardown()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func check(desc: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("PASS: %s" % desc)
	else:
		_fail += 1
		printerr("FAIL: %s%s" % [desc, "" if detail.is_empty() else "  (%s)" % detail])


func _setup() -> bool:
	_tools = load(PANEL_TOOLS_PATH)
	_driver = DRIVER.new()
	_panel = _driver.load_panel(PANEL_PATH)
	if _tools == null or _panel == null:
		return false
	_host = _panel.get_annotation_host()
	if _host == null:
		return false
	_host.set_panel(_panel)
	_data = _panel.get_data()
	if _data == null:
		return false
	_ipc = StubIPC.new()
	_panel.add_child(_ipc)
	_panel.request.connect(_ipc.on_request)
	_board_dir = _driver.make_temp_board_dir("pcb_placements_memo")
	return true


func _teardown() -> void:
	if _panel is Node:
		(_panel as Node).free()


## One resistor, U1, at `x` — the ref both boards share.
func _board(x: float) -> Dictionary:
	return {
		"name": "PlacementMemo", "width_mm": 60.0, "height_mm": 40.0,
		"layers": ["top", "bottom"],
		"components": [
			{"ref": "U1", "footprint": FOOTPRINT, "x_mm": x, "y_mm": 15.0,
				"rotation_deg": 0.0, "layer": "top", "pins": []},
		],
	}


## The file-restore load path, with the canonical board shape.
func _load(x: float, file_stem: String) -> void:
	_driver.drive_load_merged(_panel, _board_dir + "/" + file_stem + ".pcb", _board(x))


## U1's resolved anchor x as get_components reports it, or NAN when the reply
## carries no placement for it.
func _u1_anchor_x() -> float:
	return _u1_anchor_x_of(await _tools._get_components(_host, {}))


func _u1_anchor_x_of(reply: Dictionary) -> float:
	for comp_v in (reply.get("components", []) as Array):
		var comp: Dictionary = comp_v
		if str(comp.get("id", "")) != "U1":
			continue
		var places: Array = comp.get("physical_placements", [])
		if places.is_empty():
			return NAN
		return float(((places[0] as Dictionary).get("anchor", {}) as Dictionary).get("x_mm", NAN))
	return NAN


# ── A. the first read compiles ───────────────────────────────────────────────

func _run_first_read_asks_the_worker() -> void:
	print("\n-- A. the first read goes to the worker --")
	_load(BOARD_A_X, "a")
	var x: float = await _u1_anchor_x()
	check("board A's read carries A's anchor", x == BOARD_A_X, str(x))
	check("and it cost one round trip", _ipc.calls == 1, str(_ipc.calls))


# ── B. the memo answers an unchanged board ───────────────────────────────────

func _run_second_read_is_the_memo() -> void:
	print("\n-- B. an unchanged board is answered from the memo --")
	var x: float = await _u1_anchor_x()
	check("the second read carries the same anchor", x == BOARD_A_X, str(x))
	check("and cost no round trip", _ipc.calls == 1, str(_ipc.calls))


# ── C. a load is a different board under the same revision ───────────────────

func _run_load_of_another_board_misses() -> void:
	print("\n-- C. loading board B misses the memo --")
	var revision_before: int = int(_data.board_revision)
	_load(BOARD_B_X, "b")
	# The premise the two-key memo exists for: a whole-board load leaves the
	# revision where it was, so the revision alone cannot tell B from A.
	check("a load leaves board_revision alone (the trap this guards)",
		int(_data.board_revision) == revision_before,
		"%d -> %d" % [revision_before, int(_data.board_revision)])
	var x: float = await _u1_anchor_x()
	check("board B's read carries B's anchor, not A's", x == BOARD_B_X, str(x))
	check("and went back to the worker", _ipc.calls == 2, str(_ipc.calls))
	var again: float = await _u1_anchor_x()
	check("B is then memoized in its turn", again == BOARD_B_X and _ipc.calls == 2,
		"%s after %d calls" % [str(again), _ipc.calls])


# ── D. an edit still misses the way it always did ────────────────────────────

func _run_edit_misses() -> void:
	print("\n-- D. a move misses the memo --")
	_data.move_component("U1", Vector2(MOVED_X, 15.0))
	var x: float = await _u1_anchor_x()
	check("the moved part reads at its new place", x == MOVED_X, str(x))
	check("through a fresh round trip", _ipc.calls == 3, str(_ipc.calls))


# ── E. a load that lands while a read is in flight ───────────────────────────

func _run_load_during_a_read_is_not_memoized() -> void:
	print("\n-- E. a load during the round trip is never handed to the caller --")
	# A move forces the read to the worker; board B is loaded under that round
	# trip before the worker answers about the moved board. The caller lists
	# B's components AFTER the reply comes back, so the reply about the moved
	# board must not reach it: the panel asks again, about B.
	_data.move_component("U1", Vector2(MOVED_AGAIN_X, 15.0))
	_ipc.before_reply = func() -> void:
		_ipc.before_reply = Callable()
		_load(BOARD_B_X, "b_again")
	var x: float = await _u1_anchor_x()
	check("the read that crossed the load answers about board B, not the moved board",
		x == BOARD_B_X, str(x))
	check("through the crossed round trip plus one retry", _ipc.calls == 5, str(_ipc.calls))
	var again: float = await _u1_anchor_x()
	check("the retry's reply is the memo for B", again == BOARD_B_X and _ipc.calls == 5,
		"%s after %d calls" % [str(again), _ipc.calls])


# ── F. a load under both attempts ────────────────────────────────────────────

func _run_load_during_both_attempts_is_unavailable() -> void:
	print("\n-- F. a load under both attempts reports placements unavailable --")
	# The retry is bounded: with the board replaced under the request and then
	# under the retry, no reply describes the live board, and the read must
	# say so rather than pick one. Two loads, then the stub stops interfering.
	_data.move_component("U1", Vector2(MOVED_X, 15.0))
	var memo_keys_before: Array = [_panel._placements_revision, _panel._placements_generation]
	var loads_left: Array = [2]
	_ipc.before_reply = func() -> void:
		loads_left[0] -= 1
		if loads_left[0] <= 0:
			_ipc.before_reply = Callable()
		_load(BOARD_B_X, "b_twice")
	var reply: Dictionary = await _tools._get_components(_host, {})
	var reason: String = str(reply.get("physical_placements_unavailable", ""))
	check("the reply carries a reason instead of a placement",
		not reason.is_empty() and reason.contains("changed"), reason)
	check("and U1 carries no placement from either crossed reply",
		is_nan(_u1_anchor_x_of(reply)), str(_u1_anchor_x_of(reply)))
	check("after exactly two attempts", _ipc.calls == 7, str(_ipc.calls))
	check("no memo was filed by a reply that crossed a load",
		[_panel._placements_revision, _panel._placements_generation] == memo_keys_before,
		str([_panel._placements_revision, _panel._placements_generation]))
	var x: float = await _u1_anchor_x()
	check("the next read is about board B", x == BOARD_B_X, str(x))
	check("through a fresh round trip", _ipc.calls == 8, str(_ipc.calls))
