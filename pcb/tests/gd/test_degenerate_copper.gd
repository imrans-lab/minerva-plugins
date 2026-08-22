extends SceneTree
## SR2FAB S7: a segment whose two ends are the same point.
##
## THE FAILURE THIS PREVENTS, observed on smart-remote-v2. A zero-length segment
## reached the board through a commit. compile_board then refused the WHOLE
## board with trace_degenerate, which takes geometric DRC, the routing IR and
## promotion down with it — and the router's own refusal named only an ordinal
## ("trace 1: zero-length segment at (75.4, 80.0)"), so the board could be
## diagnosed but not repaired from the message. Recovery took an
## export_trace_geometry / hand-edit / import_trace_geometry round trip.
##
## The commit pre-flight already refused a segment with fewer than two POINTS.
## It counted points, not DISTINCT points, so two copies of one point sailed
## through as a legal two-point segment.
##
## RED/GREEN: sections 1-3 fail against pre-station code — the helper does not
## exist, the pre-flight admits the segment, and the ingest builds it.
##
## Run (via a Minerva scaffold as the Godot host):
##   godot --headless --path <minerva-scaffold>/src \
##     --script res://../../minerva-plugins/pcb/tests/gd/test_degenerate_copper.gd

const PcbData := preload("res://../../minerva-plugins/pcb/ui/model/pcb_data.gd")
const PcbWorkspace := preload("res://../../minerva-plugins/pcb/ui/model/pcb_routing_workspace.gd")
const PcbRouteCandidate := preload("res://../../minerva-plugins/pcb/ui/model/pcb_route_candidate.gd")

var _pass := 0
var _fail := 0


func check(desc: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s%s" % [desc, ("" if detail == "" else " — " + detail)])


func check_eq(desc: String, actual, expected) -> void:
	check("%s (expected %s, got %s)" % [desc, str(expected), str(actual)],
		actual == expected)


func _init() -> void:
	print("=== S7: degenerate copper ===\n")
	await process_frame
	_run_helper()
	_run_commit_preflight()
	_run_ingest()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


# ── 1: the collapse itself ──────────────────────────────────────────────────

func _run_helper() -> void:
	print("-- 1: coincident points collapse --")
	var eps: float = PcbWorkspace.COPPER_COINCIDENT_EPS_MM

	check_eq("two copies of one point collapse to one",
		PcbWorkspace.drop_coincident_points(
			[Vector2(75.4, 80.0), Vector2(75.4, 80.0)]).size(), 1)
	check_eq("a real segment keeps both ends",
		PcbWorkspace.drop_coincident_points(
			[Vector2(0, 0), Vector2(5, 0)]).size(), 2)
	check_eq("a duplicate in the MIDDLE of a run collapses, the run survives",
		PcbWorkspace.drop_coincident_points(
			[Vector2(0, 0), Vector2(0, 0), Vector2(5, 0)]).size(), 2)
	check_eq("…and only CONSECUTIVE duplicates collapse — a polyline may legally return",
		PcbWorkspace.drop_coincident_points(
			[Vector2(0, 0), Vector2(5, 0), Vector2(0, 0)]).size(), 3)
	check_eq("points closer than the epsilon are the same point",
		PcbWorkspace.drop_coincident_points(
			[Vector2(10.0, 10.0), Vector2(10.0 + eps * 0.5, 10.0)]).size(), 1)
	check_eq("points further apart than it are not",
		PcbWorkspace.drop_coincident_points(
			[Vector2(10.0, 10.0), Vector2(10.0 + eps * 10.0, 10.0)]).size(), 2)
	check_eq("anything that is not a point is not copper",
		PcbWorkspace.drop_coincident_points(
			[Vector2(0, 0), "nonsense", null, Vector2(5, 0)]).size(), 2)

	# The epsilon has to sit ABOVE float32 noise or it recognises nothing: at
	# real board coordinates one Vector2 ulp is already ~7.6e-6 mm.
	check("the epsilon is above single-precision noise at board coordinates",
		eps > 1e-5, str(eps))
	# ...and far below anything fabricable, so nothing real is ever collapsed.
	check("…and far below the narrowest manufacturable trace", eps < 0.01, str(eps))


# ── 2: the commit pre-flight ────────────────────────────────────────────────

func _rig(points: Array) -> Dictionary:
	var ws = PcbWorkspace.new()
	var data = PcbData.new()
	data.save_to_history("baseline")
	var c = PcbRouteCandidate.new()
	c.net = "N1"
	c.task_id = "N1|"
	c.add_segment(PcbRouteCandidate.make_segment("", "top", 0.3, points))
	return {"ws": ws, "data": data, "cid": str(ws.add_candidate(c))}


func _run_commit_preflight() -> void:
	print("\n-- 2: the commit pre-flight counts DISTINCT points --")

	# (a) THE BUG: two points, one place. The old count of 2 let this through.
	var rig := _rig([Vector2(75.4, 80.0), Vector2(75.4, 80.0)])
	var res: Dictionary = rig["ws"].commit(rig["cid"], rig["data"])
	check("a segment that draws nothing refuses the commit",
		not bool(res.get("ok", true)))
	check_eq("…named unmodelable_segment",
		str(res.get("error", "")), PcbWorkspace.ERR_UNMODELABLE_SEGMENT)
	check("…and the message says COLLAPSES, not 'has 2 points'",
		str(res.get("message", "")).contains("collapse"),
		str(res.get("message", "")))
	check_eq("NO copper reached the board", int(rig["data"].traces.size()), 0)
	check_eq("the disposition did NOT move",
		str(rig["ws"].get_candidate(rig["cid"]).disposition), "proposed")

	# (b) A duplicate BESIDE real geometry is normalized, not refused. Refusing
	#     would block a perfectly good route over an artifact that draws nothing.
	var rig2 := _rig([Vector2(0, 0), Vector2(0, 0), Vector2(5, 0)])
	var ok: Dictionary = rig2["ws"].commit(rig2["cid"], rig2["data"])
	check("a duplicate beside real copper commits", bool(ok.get("ok", false)),
		str(ok.get("error", "")))
	check_eq("…as ONE trace", int(rig2["data"].traces.size()), 1)
	if int(rig2["data"].traces.size()) == 1:
		# traces is {trace_id -> pcb_trace.gd}, and the polyline lives on
		# `waypoints` — the normalized points, not the authored three.
		var trace = (rig2["data"].traces as Dictionary).values()[0]
		check_eq("…carrying the two points it actually draws, not three",
			(trace.waypoints as Array).size(), 2)


# ── 3: nothing degenerate is built in the first place ───────────────────────

func _run_ingest() -> void:
	print("\n-- 3: ingest never builds one --")
	var ws = PcbWorkspace.new()
	var ids: Array = ws.ingest_routing_result({"routes": [{
		"net": "N1",
		"segments": [
			{"start": [0, 0], "end": [0, 0], "layer": "F.Cu"},
			{"start": [0, 0], "end": [5, 0], "layer": "F.Cu"},
		],
		"vias": [],
	}]})
	check_eq("the route still lands", ids.size(), 1)
	if ids.size() == 1:
		var c = ws.get_candidate(str(ids[0]))
		check_eq("…carrying only the segment that draws something",
			(c.segments as Array).size(), 1)
	check_eq("…and the drop is counted, not silent",
		int(ws.last_ingest_degenerate_segments), 1)

	# A route that collapses ENTIRELY yields no candidate at all — the
	# documented "" contract — rather than a ghost that renders nothing and can
	# only ever be rejected.
	var ws2 = PcbWorkspace.new()
	var none: Array = ws2.ingest_routing_result({"routes": [{
		"net": "N2",
		"segments": [{"start": [3, 3], "end": [3, 3], "layer": "F.Cu"}],
		"vias": [],
	}]})
	check_eq("a wholly degenerate route yields no candidate", none.size(), 0)
	check_eq("…and says how many segments went", int(ws2.last_ingest_degenerate_segments), 1)

	# The counter is PER-CALL: a later clean ingest must not report the earlier
	# call's drops.
	var clean: Array = ws2.ingest_routing_result({"routes": [{
		"net": "N3",
		"segments": [{"start": [0, 0], "end": [4, 0], "layer": "F.Cu"}],
		"vias": [],
	}]})
	check_eq("a clean ingest lands", clean.size(), 1)
	check_eq("…and reports zero drops, not the previous call's",
		int(ws2.last_ingest_degenerate_segments), 0)
