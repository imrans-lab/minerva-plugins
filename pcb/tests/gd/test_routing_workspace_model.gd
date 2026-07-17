extends SceneTree
## T1 (S2.1) — PcbRoutingWorkspace FOUNDATION domain-model tests. Pure GDScript
## model tests, worker-independent.
##
## Run (via a Minerva scaffold as the Godot host — NEVER the live checkout):
##   godot --headless --path <minerva-scaffold>/src \
##     --script res://../../minerva-plugins/pcb/tests/gd/test_routing_workspace_model.gd
## The preloads resolve res:// against the scaffold's src/ root, so
## ../../minerva-plugins reaches this plugin checkout beside it (same convention
## as test_layer_stack.gd).
##
## Coverage (8 groups):
##   1. Each model constructs + to_dict/from_dict round-trips ALL fields incl.
##      stable ids; workspace counter high-water restored after from_dict.
##   2. MULTI-PAD fixture: a 3-pin net candidate whose segments form >=2
##      DISCONNECTED paths — round-trips, each segment keeps its own layer.
##   3. Orthogonality of the disposition/validation axes.
##   4. Workspace signals fire with the right id.
##   5. PCBData.board_revision monotonic-forward incl. undo/redo.
##   6. INV-1 regression: undo restores vias WITH traces; redo returns both.
##   7. Batch-commit: begin/2 mutations/end => one history entry + one bump;
##      one undo reverts both.
##   8. Via-span legality surfaced through PcbLayerStack.

const PcbRouteTask := preload("res://../../minerva-plugins/pcb/ui/model/pcb_route_task.gd")
const PcbRouteCandidate := preload("res://../../minerva-plugins/pcb/ui/model/pcb_route_candidate.gd")
const PcbRoutingWorkspace := preload("res://../../minerva-plugins/pcb/ui/model/pcb_routing_workspace.gd")
const PCBData := preload("res://../../minerva-plugins/pcb/ui/model/pcb_data.gd")
const PcbLayerStack := preload("res://../../minerva-plugins/pcb/ui/model/pcb_layer_stack.gd")

var _pass := 0
var _fail := 0

# Signal recorders (group 4).
var _rec_added: Array = []
var _rec_changed: Array = []
var _rec_active: Array = []
var _rec_validation: Array = []


func _init() -> void:
	print("=== PcbRoutingWorkspace (T1 model) Tests ===\n")
	_run_roundtrip()
	_run_multipad()
	_run_orthogonality()
	_run_signals()
	_run_board_revision()
	_run_inv1_undo()
	_run_batch()
	_run_via_span()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


# ── assertion helpers ─────────────────────────────────────────────────────────

func check(desc: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s" % desc)


func check_eq(desc: String, actual, expected) -> void:
	check("%s (expected %s, got %s)" % [desc, str(expected), str(actual)], actual == expected)


# ── 1. construct + round-trip all fields ──────────────────────────────────────

func _run_roundtrip() -> void:
	print("-- 1. construct + to_dict/from_dict round-trip --")

	# RouteTask
	var task = PcbRouteTask.new()
	task.task_id = "task_1"
	task.net = "N1"
	task.endpoints = [
		{"component": "U1", "pin": "3", "position": Vector2(1, 2)},
		{"component": "U2", "pin": "7", "position": Vector2(9, 4)},
	]
	var task2 = PcbRouteTask.from_dict(task.to_dict())
	check_eq("task round-trip task_id", task2.task_id, "task_1")
	check_eq("task round-trip net", task2.net, "N1")
	check_eq("task round-trip endpoint count", task2.endpoints.size(), 2)
	check_eq("task round-trip endpoint pin", str(task2.endpoints[0].get("pin", "")), "3")
	check("task round-trip endpoint position is Vector2", task2.endpoints[0].get("position") is Vector2)
	check_eq("task round-trip endpoint position value", task2.endpoints[1].get("position"), Vector2(9, 4))

	# RouteCandidate (full field set)
	var cand = PcbRouteCandidate.new()
	cand.candidate_id = "cand_1"
	cand.task_id = "task_1"
	cand.net = "N1"
	cand.endpoints = task.endpoints.duplicate(true)
	cand.generation = 3
	cand.base_board_revision = 5
	cand.candidate_revision = 2
	var hint_ids: Array[String] = ["h1", "h2"]
	cand.source_hint_ids = hint_ids
	cand.add_segment(PcbRouteCandidate.make_segment("seg_1", "top", 0.3, [Vector2(0, 0), Vector2(5, 0)], false))
	cand.add_via(PcbRouteCandidate.make_via("via_1", Vector2(5, 0), "top", "bottom", 0.8, 0.4, true))
	cand.disposition = "pinned"
	cand.validation = "clean"

	var cand2 = PcbRouteCandidate.from_dict(cand.to_dict())
	check_eq("cand round-trip candidate_id", cand2.candidate_id, "cand_1")
	check_eq("cand round-trip task_id", cand2.task_id, "task_1")
	check_eq("cand round-trip net", cand2.net, "N1")
	# int fields tolerate whole-number floats from JSON — compare as int.
	check_eq("cand round-trip generation (int)", cand2.generation, 3)
	check_eq("cand round-trip base_board_revision (int)", cand2.base_board_revision, 5)
	check_eq("cand round-trip candidate_revision (int)", cand2.candidate_revision, 2)
	check_eq("cand round-trip source_hint_ids size", cand2.source_hint_ids.size(), 2)
	check_eq("cand round-trip source_hint_ids[0]", str(cand2.source_hint_ids[0]), "h1")
	check_eq("cand round-trip segment count", cand2.segments.size(), 1)
	check_eq("cand round-trip segment id", str(cand2.segments[0].get("id", "")), "seg_1")
	check_eq("cand round-trip segment layer", str(cand2.segments[0].get("layer", "")), "top")
	check("cand round-trip segment point is Vector2", cand2.segments[0].get("points")[1] is Vector2)
	check_eq("cand round-trip segment point value", cand2.segments[0].get("points")[1], Vector2(5, 0))
	check_eq("cand round-trip via count", cand2.vias.size(), 1)
	check_eq("cand round-trip via id", str(cand2.vias[0].get("id", "")), "via_1")
	check("cand round-trip via position is Vector2", cand2.vias[0].get("position") is Vector2)
	check_eq("cand round-trip via from_layer", str(cand2.vias[0].get("from_layer", "")), "top")
	check_eq("cand round-trip via to_layer", str(cand2.vias[0].get("to_layer", "")), "bottom")
	check_eq("cand round-trip via locked", bool(cand2.vias[0].get("locked", false)), true)
	check_eq("cand round-trip disposition axis", cand2.disposition, "pinned")
	check_eq("cand round-trip validation axis", cand2.validation, "clean")

	# RoutingWorkspace + counter high-water
	var ws = PcbRoutingWorkspace.new()
	var c1 = PcbRouteCandidate.new()
	c1.net = "N1"
	c1.add_segment(PcbRouteCandidate.make_segment("", "top", 0.3, [Vector2(0, 0), Vector2(1, 0)]))
	c1.add_via(PcbRouteCandidate.make_via("", Vector2(1, 0), "top", "bottom"))
	var id1 = ws.add_candidate(c1)  # mints cand_1, seg_1, via_1
	check_eq("ws minted candidate id", id1, "cand_1")
	check_eq("ws minted segment id", str(c1.segments[0].get("id", "")), "seg_1")
	check_eq("ws minted via id", str(c1.vias[0].get("id", "")), "via_1")
	ws.set_active(id1)
	ws.pin(id1)
	ws.selected_finding_id = "f_9"

	var ws2 = PcbRoutingWorkspace.from_dict(ws.to_dict())
	check_eq("ws round-trip candidate count", ws2.list_candidates().size(), 1)
	check_eq("ws round-trip active", ws2.active_candidate_id, "cand_1")
	check("ws round-trip pinned set", ws2.is_pinned("cand_1"))
	check_eq("ws round-trip selected_finding_id", ws2.selected_finding_id, "f_9")
	# High-water: next ids must NOT collide with loaded ones.
	check_eq("ws counter high-water candidate", ws2.next_candidate_id(), "cand_2")
	check_eq("ws counter high-water segment", ws2.next_segment_id(), "seg_2")
	check_eq("ws counter high-water via", ws2.next_via_id(), "via_2")

	# High-water from SCANNED ids even when stored counter is stale/low.
	var stale := {
		"candidates": {
			"cand_5": {"candidate_id": "cand_5", "net": "N", "segments": [
				{"id": "seg_9", "layer": "top", "width": 0.3, "points": [], "locked": false}
			], "vias": []}
		},
		"active_candidate_id": "", "pinned": [], "selected_finding_id": "",
		"counters": {"candidate": 0, "segment": 0, "via": 0},
	}
	var ws3 = PcbRoutingWorkspace.from_dict(stale)
	check_eq("ws high-water from scanned candidate id", ws3.next_candidate_id(), "cand_6")
	check_eq("ws high-water from scanned segment id", ws3.next_segment_id(), "seg_10")


# ── 2. multi-pad (>=2 disconnected paths, INV-3 trap) ─────────────────────────

func _run_multipad() -> void:
	print("-- 2. multi-pad: 3-pin net, >=2 disconnected segments --")
	var cand = PcbRouteCandidate.new()
	cand.candidate_id = "cand_mp"
	cand.net = "N3"
	# Two INDEPENDENT segments on DIFFERENT layers with NO shared endpoint —
	# a 3-pad net whose route is two disconnected paths. No single-chain assumed.
	cand.add_segment(PcbRouteCandidate.make_segment("seg_a", "top", 0.25, [Vector2(0, 0), Vector2(10, 0)]))
	cand.add_segment(PcbRouteCandidate.make_segment("seg_b", "bottom", 0.25, [Vector2(50, 50), Vector2(60, 50)]))
	check_eq("multipad has 2 segments", cand.segments.size(), 2)
	# The two paths do not touch — assert disjoint endpoints (no chain).
	var end_a: Vector2 = cand.segments[0].get("points")[1]
	var start_b: Vector2 = cand.segments[1].get("points")[0]
	check("multipad paths are disconnected", end_a != start_b)

	var cand2 = PcbRouteCandidate.from_dict(cand.to_dict())
	check_eq("multipad round-trip 2 segments", cand2.segments.size(), 2)
	check_eq("multipad seg_a layer preserved", str(cand2.segments[0].get("layer", "")), "top")
	check_eq("multipad seg_b layer preserved", str(cand2.segments[1].get("layer", "")), "bottom")
	check_eq("multipad seg_a id preserved", str(cand2.segments[0].get("id", "")), "seg_a")
	check_eq("multipad seg_b id preserved", str(cand2.segments[1].get("id", "")), "seg_b")


# ── 3. orthogonality of the two axes ──────────────────────────────────────────

func _run_orthogonality() -> void:
	print("-- 3. disposition/validation orthogonality --")
	var c = PcbRouteCandidate.new()
	check_eq("default disposition", c.disposition, "proposed")
	check_eq("default validation", c.validation, "unchecked")

	# Set disposition — validation must NOT move.
	c.disposition = "rejected"
	check_eq("disposition set", c.disposition, "rejected")
	check_eq("validation untouched after disposition set", c.validation, "unchecked")

	# Set validation — disposition must NOT move.
	c.validation = "violating"
	check_eq("validation set", c.validation, "violating")
	check_eq("disposition untouched after validation set", c.disposition, "rejected")

	# Invalid values are rejected (value unchanged), still no cross-talk.
	c.disposition = "bogus"
	check_eq("invalid disposition ignored", c.disposition, "rejected")
	check_eq("validation still intact", c.validation, "violating")
	c.validation = "nonsense"
	check_eq("invalid validation ignored", c.validation, "violating")
	check_eq("disposition still intact", c.disposition, "rejected")


# ── 4. workspace signals ──────────────────────────────────────────────────────

func _on_added(id: String) -> void: _rec_added.append(id)
func _on_changed(id: String) -> void: _rec_changed.append(id)
func _on_active(id: String) -> void: _rec_active.append(id)
func _on_validation(id: String) -> void: _rec_validation.append(id)


func _run_signals() -> void:
	print("-- 4. workspace signals fire with right id --")
	_rec_added.clear(); _rec_changed.clear(); _rec_active.clear(); _rec_validation.clear()
	var ws = PcbRoutingWorkspace.new()
	ws.candidate_added.connect(_on_added)
	ws.candidate_changed.connect(_on_changed)
	ws.active_candidate_changed.connect(_on_active)
	ws.validation_changed.connect(_on_validation)

	var c = PcbRouteCandidate.new()
	c.net = "N1"
	var id = ws.add_candidate(c)
	check("candidate_added fired", _rec_added.has(id))
	ws.set_active(id)
	check("active_candidate_changed fired with id", _rec_active.has(id))
	ws.set_validation(id, "clean")
	check("validation_changed fired with id", _rec_validation.has(id))
	check_eq("set_validation applied", ws.get_candidate(id).validation, "clean")
	ws.reject(id)
	check("candidate_changed fired on reject", _rec_changed.has(id))
	check_eq("reject set disposition", ws.get_candidate(id).disposition, "rejected")


# ── 5. PCBData.board_revision monotonic-forward ───────────────────────────────

func _run_board_revision() -> void:
	print("-- 5. board_revision monotonic-forward (incl. undo/redo) --")
	var data = PCBData.new()
	check_eq("board_revision starts at 0", data.board_revision, 0)

	# add_trace
	var t = data.new_trace()
	t.id = "t1"; t.net_name = "N1"; t.layer = "top"; t.width = 0.3
	t.waypoints.append(Vector2(0, 0)); t.waypoints.append(Vector2(5, 0))
	var r0 := int(data.board_revision)
	data.add_trace(t)
	check("add_trace bumps revision", data.board_revision > r0)

	# add_via
	var r1 := int(data.board_revision)
	data.add_via({"position": Vector2(5, 0), "size": 0.8, "drill": 0.4, "net_name": "N1", "from_layer": "top", "to_layer": "bottom"})
	check("add_via bumps revision", data.board_revision > r1)

	# move_component
	var comp = data.new_component()
	comp.id = "U1"; comp.position = Vector2(0, 0)
	data.add_component(comp)  # also a bump
	var r2 := int(data.board_revision)
	data.move_component("U1", Vector2(3, 3))
	check("move_component bumps revision", data.board_revision > r2)

	# remove_trace
	var r3 := int(data.board_revision)
	data.remove_trace("t1")
	check("remove_trace bumps revision", data.board_revision > r3)

	# from_csv is a forward in-place merge — it must advance the revision so a
	# candidate generated before a CSV import sees base_board_revision != current.
	var r_csv := int(data.board_revision)
	data.from_csv("id,footprint,x,y,rotation,layer,value\nR9,R_0603,10,10,0,top,10k\n")
	check("from_csv bumps revision", data.board_revision > r_csv)
	check("from_csv imported the component", data.has_component("R9"))

	# undo/redo bump FORWARD (never decrement).
	data.save_to_history("cp0")
	var t2 = data.new_trace()
	t2.id = "t2"; t2.net_name = "N2"; t2.layer = "top"; t2.width = 0.3
	t2.waypoints.append(Vector2(0, 0)); t2.waypoints.append(Vector2(1, 0))
	data.add_trace(t2)
	data.save_to_history("cp1")
	var r_before_undo := int(data.board_revision)
	data.undo()
	check("undo bumps revision FORWARD", data.board_revision > r_before_undo)
	var r_before_redo := int(data.board_revision)
	data.redo()
	check("redo bumps revision FORWARD", data.board_revision > r_before_redo)


# ── 6. INV-1 regression: undo keeps vias WITH traces ──────────────────────────

func _via_count_for_net(data, net: String) -> int:
	var n := 0
	for v in data.vias:
		if str(v.get("net_name", "")) == net:
			n += 1
	return n


func _run_inv1_undo() -> void:
	print("-- 6. INV-1: undo restores vias WITH traces; redo returns both --")
	var data = PCBData.new()
	data.save_to_history("baseline")
	# via-bearing state
	var t_top = data.new_trace()
	t_top.id = "u_top"; t_top.net_name = "N1"; t_top.layer = "top"; t_top.width = 0.3
	t_top.waypoints.append(Vector2(0, 0)); t_top.waypoints.append(Vector2(5, 0))
	data.add_trace(t_top)
	var t_bot = data.new_trace()
	t_bot.id = "u_bot"; t_bot.net_name = "N1"; t_bot.layer = "bottom"; t_bot.width = 0.3
	t_bot.waypoints.append(Vector2(5, 0)); t_bot.waypoints.append(Vector2(5, 5))
	data.add_trace(t_bot)
	data.add_via({"position": Vector2(5, 0), "size": 0.8, "drill": 0.4, "net_name": "N1", "from_layer": "top", "to_layer": "bottom"})
	data.save_to_history("add traces + via")
	# a later checkpoint so undo lands ON the via-bearing state
	var t_extra = data.new_trace()
	t_extra.id = "u_extra"; t_extra.net_name = "N2"; t_extra.layer = "top"; t_extra.width = 0.3
	t_extra.waypoints.append(Vector2(20, 0)); t_extra.waypoints.append(Vector2(25, 0))
	data.add_trace(t_extra)
	data.save_to_history("extra")
	check_eq("pre-undo 3 traces", data.get_trace_count(), 3)

	data.undo()
	check_eq("undo -> 2 traces", data.get_trace_count(), 2)
	check_eq("undo -> via restored WITH traces (not orphaned)", _via_count_for_net(data, "N1"), 1)

	data.undo()
	check_eq("undo -> baseline 0 traces", data.get_trace_count(), 0)
	check_eq("undo -> baseline 0 vias", data.vias.size(), 0)

	data.redo()
	check_eq("redo -> 2 traces", data.get_trace_count(), 2)
	check_eq("redo -> via returns", _via_count_for_net(data, "N1"), 1)


# ── 7. batch-commit ───────────────────────────────────────────────────────────

func _run_batch() -> void:
	print("-- 7. batch: one history entry + one bump; one undo reverts both --")
	var data = PCBData.new()
	data.save_to_history("baseline")  # checkpoint before the batch
	var hist_before := int(data.history.size())
	var rev_before := int(data.board_revision)

	data.begin_batch()
	var a = data.new_trace()
	a.id = "b1"; a.net_name = "N1"; a.layer = "top"; a.width = 0.3
	a.waypoints.append(Vector2(0, 0)); a.waypoints.append(Vector2(1, 0))
	data.add_trace(a)
	var b = data.new_trace()
	b.id = "b2"; b.net_name = "N1"; b.layer = "top"; b.width = 0.3
	b.waypoints.append(Vector2(1, 0)); b.waypoints.append(Vector2(2, 0))
	data.add_trace(b)
	# During the batch: no per-mutation bump yet.
	check_eq("no revision bump mid-batch", data.board_revision, rev_before)
	data.end_batch("add two traces")

	check_eq("batch adds exactly ONE history entry", data.history.size(), hist_before + 1)
	check_eq("batch does exactly ONE revision bump", data.board_revision, rev_before + 1)
	check_eq("both traces present after batch", data.get_trace_count(), 2)

	# One undo reverts BOTH mutations together.
	data.undo()
	check_eq("one undo reverts the whole batch", data.get_trace_count(), 0)


# ── 8. via-span legality via the shared contract ──────────────────────────────

func _run_via_span() -> void:
	print("-- 8. via-span legality surfaced via PcbLayerStack --")
	var c = PcbRouteCandidate.new()
	var legal = PcbRouteCandidate.make_via("via_1", Vector2(0, 0), "top", "bottom")
	c.add_via(legal)
	check("legal top<->bottom via passes candidate check", c.via_span_legal(legal))
	check("cross-check with PcbLayerStack", PcbLayerStack.is_legal_via_span("top", "bottom"))
	check("all_via_spans_legal true", c.all_via_spans_legal())
	check_eq("no illegal via ids", c.illegal_via_span_ids().size(), 0)

	# Illegal same-layer span — flagged (not silently dropped; still round-trips).
	var bad = PcbRouteCandidate.make_via("via_2", Vector2(1, 1), "top", "top")
	c.add_via(bad)
	check("same-layer via flagged illegal by candidate", not c.via_span_legal(bad))
	check("all_via_spans_legal now false", not c.all_via_spans_legal())
	check("illegal via id surfaced", c.illegal_via_span_ids().has("via_2"))
	# Round-trip keeps the illegal via (model does not drop it).
	var c2 = PcbRouteCandidate.from_dict(c.to_dict())
	check_eq("illegal via survives round-trip", c2.vias.size(), 2)
