extends SceneTree
## Trace/via IDENTITY in the MCP trace surface, and targeted deletion
## (docket 019f809798d1).
##
## The reported gap was "no way to delete a subset of traces": the only removal
## path was import_trace_geometry, which clears the whole board and re-imports,
## so removing one trace cost an export of everything, an out-of-tool filter and
## a full re-import through context.
##
## The ROOT CAUSE was one level down. _export_trace_geometry had each trace's id
## in hand (it iterates get_trace_ids and calls get_trace) and threw it away,
## emitting anonymous {start,end,width,layer,net_name} segments; vias came out
## id-less too. Nothing in the payload NAMED a piece of copper, so coordinates
## were the only handle — which is why the reported session rendered a PNG just
## to learn the coordinate orientation and then hand-wrote clip geometry. A
## delete tool without identity in the export would have been unusable, so the
## three parts land together:
##   1. export stamps trace_id on every segment and id on every via
##   2. import HONOURS a supplied trace_id/via id instead of renumbering
##      positionally ("trace_%d" % trace_count), so export -> filter -> import
##      round-trips identity
##   3. minerva_pcb_delete_traces removes exactly the named ids / net
##
## Run (via a Minerva scaffold as the Godot host — NEVER the live checkout):
##   godot --headless --path <minerva-scaffold>/src \
##     --script res://../../minerva-plugins/pcb/tests/gd/test_trace_identity_delete.gd
##
## Coverage (numbered in EXECUTION order — keep the `-- N.` print labels, this
## list and the _init() call order in step):
##   1. export stamps a trace_id on EVERY segment, and the segments of one
##      polyline share it (they are one piece of copper, not a duplicate to be
##      collapsed); per-segment pairing checked against distinct coordinates
##   2. export stamps an id on every via, paired to the right via
##   3. delete by trace_ids removes exactly those; SURVIVORS asserted by id,
##      net, layer and geometry, not by count
##   4. delete by net_name removes that net's traces and no others — the two
##      GND traces differ in layer/width/coords so a mispairing is visible
##   5. valid + non-existent ids mixed: the valid ones are deleted AND the reply
##      NAMES the missing ones; absent-vs-empty discipline on missing_*/net_*
##   6. deleting multiple vias by id — the index-shift trap. An index-based loop
##      over indices captured up front deletes the WRONG via; the surviving
##      via's own net/position prove which one actually survived
##   7. round trip: export -> drop one trace + one via from the payload ->
##      import the remainder into a fresh board; ids, nets, layers and merged
##      polyline geometry all land as expected. 7b: a supplied numeric id listed
##      AFTER id-less segments does not collide with the auto-mint
##   8. undo after a delete restores the deleted trace AND via
##   9. a DUPLICATE supplied trace_id (9a across two layers, 9b across two nets)
##      keeps BOTH traces — the id is claimed once per import, not once per
##      trace_id|net|layer group
##  10. a board load reserves its trace ids so the FIRST subsequent auto-mint
##      cannot overwrite a loaded trace (10a from_board_dict, 10b load_from_dict,
##      10c a non-first id such as "trace_7")
##  11. trace_ids and net_name naming the SAME trace: deleted once, counted once
##  12. a DUPLICATE supplied VIA id: both vias land under DISTINCT ids, the
##      reply names what landed, and both stay individually deletable by id
##  13. an EMPTY-string id selector is reported in missing_*, never silently
##      skipped — including that it does NOT match a legacy via carrying no id
##  14. R1 (docket 019fa17326b5 / 019fa172dd21): the concrete import->clear_
##      traces->undo->mint sequence that would OVERWRITE a restored trace if
##      clear_traces() reset the id counter (it no longer does) or if
##      _restore_state() failed to high-water it back up (it now does) —
##      exercised through the real production caller, minerva_pcb_import_
##      trace_geometry (PanelTools._import_trace_geometry)

const PanelTools := preload("res://../../minerva-plugins/pcb/ui/panel_tools.gd")
const PCBData := preload("res://../../minerva-plugins/pcb/ui/model/pcb_data.gd")

var _pass := 0
var _fail := 0


## Minimal duck-typed host — panel_tools._get_data(host) only needs
## get_board_data() (same stand-in shape as test_layer_stack.gd's _StubHost).
class _StubHost extends RefCounted:
	var _data
	func _init(d) -> void:
		_data = d
	func get_board_data():
		return _data


func _init() -> void:
	print("=== Trace identity + targeted delete (019f809798d1) ===\n")
	_run_export_trace_ids()
	_run_export_via_ids()
	_run_delete_by_trace_ids()
	_run_delete_by_net_name()
	_run_delete_mixed_valid_and_missing()
	_run_delete_vias_index_shift_trap()
	_run_round_trip()
	_run_undo_after_delete()
	_run_duplicate_supplied_id()
	_run_board_load_high_water()
	_run_union_overlap()
	_run_duplicate_supplied_via_id()
	_run_empty_id_selectors()
	_run_import_undo_mint_no_overwrite()
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


# ── fixture ───────────────────────────────────────────────────────────────────

## Four traces and three vias, all DISTINCT in every field these tests select on.
## Deliberate design: the two GND traces (trace_b, trace_d) differ in layer,
## width and coordinates, so a bug that deletes/keeps the wrong one of a net pair
## is visible. Identical duplicates would only ever catch a DROPPED value, never
## a MISPAIRED one.
##
##   trace_a  net VCC  layer top     w 0.50  (0,0)->(1,0)->(2,0)   TWO segments
##   trace_b  net GND  layer bottom  w 0.40  (0,5)->(3,5)
##   trace_c  net SIG  layer top     w 0.30  (0,9)->(4,9)
##   trace_d  net GND  layer top     w 0.25  (0,12)->(6,12)
##
##   via_1    net VCC  (1,1)
##   via_2    net GND  (2,2)
##   via_3    net SIG  (3,3)
func _seed_board():
	var data = PCBData.new()
	_add_trace(data, "trace_a", "VCC", "top", 0.5,
		[Vector2(0, 0), Vector2(1, 0), Vector2(2, 0)])
	_add_trace(data, "trace_b", "GND", "bottom", 0.4,
		[Vector2(0, 5), Vector2(3, 5)])
	_add_trace(data, "trace_c", "SIG", "top", 0.3,
		[Vector2(0, 9), Vector2(4, 9)])
	_add_trace(data, "trace_d", "GND", "top", 0.25,
		[Vector2(0, 12), Vector2(6, 12)])
	data.add_via({"id": "via_1", "position": Vector2(1, 1), "size": 0.8, "drill": 0.4, "net_name": "VCC"})
	data.add_via({"id": "via_2", "position": Vector2(2, 2), "size": 0.8, "drill": 0.4, "net_name": "GND"})
	data.add_via({"id": "via_3", "position": Vector2(3, 3), "size": 0.8, "drill": 0.4, "net_name": "SIG"})
	return data


func _add_trace(data, id: String, net: String, layer: String, width: float, points: Array) -> void:
	var trace = data.new_trace()
	trace.id = id
	trace.net_name = net
	trace.layer = layer
	trace.width = width
	for p in points:
		trace.waypoints.append(p)
	data.add_trace(trace)


func _host_for(data):
	return _StubHost.new(data)


## Sorted trace ids currently on the board — survivor assertions compare against
## this so they name every survivor, never just a count.
func _ids(data) -> Array:
	var out: Array = []
	for id in data.get_trace_ids():
		out.append(str(id))
	out.sort()
	return out


func _via_ids(data) -> Array:
	var out: Array = []
	for v in data.vias:
		out.append(str((v as Dictionary).get("id", "")))
	return out


## Sorted net names of every trace on the board. Pairs with _ids: together they
## say WHICH copper survived, where a count says only how much.
func _nets_of(data) -> Array:
	var out: Array = []
	for id in data.get_trace_ids():
		out.append(str(data.get_trace(id).net_name))
	out.sort()
	return out


func _via_nets(data) -> Array:
	var out: Array = []
	for v in data.vias:
		out.append(str((v as Dictionary).get("net_name", "")))
	out.sort()
	return out


## First element, or "" when there is none. A bare arr[0] on an unexpectedly
## empty array raises an out-of-bounds SCRIPT ERROR that aborts the rest of the
## enclosing test function — which silently skips every later assertion in it,
## including whole sub-cases. Cost a real sub-case (9b) once; degrade instead.
func _first(arr: Array) -> String:
	return _at(arr, 0)


## Element `index` as String, or "" when out of range.
func _at(arr: Array, index: int) -> String:
	return str(arr[index]) if index >= 0 and index < arr.size() else ""


## The via dict at `index`, or {} when out of range. Same abort-proofing: these
## are the VIA arrays, whose contents the import-claim rules directly change.
func _via_at(data, index: int) -> Dictionary:
	if index < 0 or index >= data.vias.size():
		return {}
	return data.vias[index]


## Net / layer of a trace by id, or "" when no such trace exists — same
## abort-proofing rationale as _first.
func _net_of(data, id: String) -> String:
	var t = data.get_trace(id)
	return str(t.net_name) if t != null else ""


func _layer_of(data, id: String) -> String:
	var t = data.get_trace(id)
	return str(t.layer) if t != null else ""


func _waypoints_of(data, id: String) -> Array:
	var t = data.get_trace(id)
	return t.waypoints if t != null else []


## The single trace wearing `id`, plus the ids of everything else — lets a test
## assert both "the id landed on the right copper" and "nothing else vanished".
func _other_ids(data, id: String) -> Array:
	var out: Array = []
	for t in data.get_trace_ids():
		if str(t) != id:
			out.append(str(t))
	out.sort()
	return out


## The segment whose start point is `pt`, or {} — lets a test assert the
## trace_id attached to ONE specific segment rather than to the set as a whole.
func _segment_starting_at(segments: Array, pt: Vector2) -> Dictionary:
	for seg in segments:
		var s: Dictionary = (seg as Dictionary).get("start", {})
		if is_equal_approx(float(s.get("x", 0)), pt.x) and is_equal_approx(float(s.get("y", 0)), pt.y):
			return seg
	return {}


# ── 1: export stamps trace_id on every segment ────────────────────────────────

func _run_export_trace_ids() -> void:
	print("-- 1. export: every segment carries its trace_id; one polyline shares it --")
	var data = _seed_board()
	var out: Dictionary = PanelTools._export_trace_geometry(_host_for(data), {})
	check("export succeeded", bool(out.get("success", false)))

	var segments: Array = (out.get("trace_data", {}) as Dictionary).get("traces", [])
	check_eq("five segments exported (2+1+1+1)", segments.size(), 5)

	var without_id := 0
	for seg in segments:
		var tid := str((seg as Dictionary).get("trace_id", ""))
		if tid.is_empty():
			without_id += 1
	check_eq("no segment is missing its trace_id", without_id, 0)

	# trace_a is a 3-waypoint polyline -> 2 segments that MUST report the same
	# trace id. This is the relationship, not a defect: it is how a caller tells
	# which segments are one piece of copper.
	var seg_a0 := _segment_starting_at(segments, Vector2(0, 0))
	var seg_a1 := _segment_starting_at(segments, Vector2(1, 0))
	check("both trace_a segments found", not seg_a0.is_empty() and not seg_a1.is_empty())
	check_eq("first trace_a segment names trace_a", str(seg_a0.get("trace_id", "")), "trace_a")
	check_eq("second trace_a segment names the SAME trace", str(seg_a1.get("trace_id", "")), "trace_a")

	# Per-segment pairing against distinct coordinates — a bug that stamps every
	# segment with the FIRST trace's id passes the "no segment missing an id"
	# check above and fails here.
	check_eq("segment at (0,5) names trace_b",
		str(_segment_starting_at(segments, Vector2(0, 5)).get("trace_id", "")), "trace_b")
	check_eq("segment at (0,9) names trace_c",
		str(_segment_starting_at(segments, Vector2(0, 9)).get("trace_id", "")), "trace_c")
	check_eq("segment at (0,12) names trace_d",
		str(_segment_starting_at(segments, Vector2(0, 12)).get("trace_id", "")), "trace_d")

	# ...and the pairing is with the right net too (trace_b is the bottom-layer
	# GND one, trace_d the top-layer GND one).
	check_eq("segment at (0,5) is the BOTTOM-layer GND trace",
		str(_segment_starting_at(segments, Vector2(0, 5)).get("layer", "")), "B.Cu")
	check_eq("segment at (0,12) is the TOP-layer GND trace",
		str(_segment_starting_at(segments, Vector2(0, 12)).get("layer", "")), "F.Cu")


# ── 2: export stamps an id on every via ───────────────────────────────────────

func _run_export_via_ids() -> void:
	print("-- 2. export: every via carries its id, paired to the right via --")
	var data = _seed_board()
	var out: Dictionary = PanelTools._export_trace_geometry(_host_for(data), {})
	var vias: Array = (out.get("trace_data", {}) as Dictionary).get("vias", [])
	check_eq("three vias exported", vias.size(), 3)

	var missing_id := 0
	for v in vias:
		if str((v as Dictionary).get("id", "")).is_empty():
			missing_id += 1
	check_eq("no via is missing its id", missing_id, 0)

	# Pairing: the via at (2,2) is the GND one and must be via_2. A bug that
	# stamps every via with the first id, or reverses the order, fails here while
	# still passing the "none missing" check.
	for v in vias:
		var pos: Dictionary = (v as Dictionary).get("position", {})
		var px := float(pos.get("x", 0))
		if is_equal_approx(px, 1.0):
			check_eq("via at (1,1) is via_1", str((v as Dictionary).get("id", "")), "via_1")
			check_eq("via at (1,1) is the VCC via", str((v as Dictionary).get("net_name", "")), "VCC")
		elif is_equal_approx(px, 2.0):
			check_eq("via at (2,2) is via_2", str((v as Dictionary).get("id", "")), "via_2")
			check_eq("via at (2,2) is the GND via", str((v as Dictionary).get("net_name", "")), "GND")
		elif is_equal_approx(px, 3.0):
			check_eq("via at (3,3) is via_3", str((v as Dictionary).get("id", "")), "via_3")


# ── 3: delete by trace_ids ────────────────────────────────────────────────────

func _run_delete_by_trace_ids() -> void:
	print("-- 3. delete by trace_ids removes exactly those; survivors named --")
	var data = _seed_board()
	var out: Dictionary = PanelTools._delete_traces(_host_for(data),
		{"trace_ids": ["trace_a", "trace_c"]})
	check("delete succeeded", bool(out.get("success", false)))
	check_eq("deleted ids reported", out.get("deleted_trace_ids", []), ["trace_a", "trace_c"])
	check_eq("deleted count reported", int(out.get("deleted_trace_count", -1)), 2)
	check_eq("nothing was stale", out.get("missing_trace_ids", null), [])
	check_eq("remaining trace count", int(out.get("remaining_trace_count", -1)), 2)

	# SURVIVORS by name, not by count.
	check_eq("survivors are exactly trace_b and trace_d", _ids(data), ["trace_b", "trace_d"])
	check("trace_a really gone", data.get_trace("trace_a") == null)
	check("trace_c really gone", data.get_trace("trace_c") == null)

	# Survivors kept their own identity AND their own geometry — a delete that
	# rebuilt the board would pass the id check and fail these.
	var b = data.get_trace("trace_b")
	check_eq("trace_b still on net GND", str(b.net_name), "GND")
	check_eq("trace_b still on the bottom layer", str(b.layer), "bottom")
	check_eq("trace_b keeps its geometry", b.waypoints, [Vector2(0, 5), Vector2(3, 5)])
	var d = data.get_trace("trace_d")
	check_eq("trace_d still on the top layer", str(d.layer), "top")
	check_eq("trace_d keeps its geometry", d.waypoints, [Vector2(0, 12), Vector2(6, 12)])

	# Vias are untouched: nothing named one.
	check_eq("no via was deleted", int(out.get("deleted_via_count", -1)), 0)
	check_eq("all three vias remain", _via_ids(data), ["via_1", "via_2", "via_3"])
	# ABSENT, not empty: the caller supplied no via_ids, so there was no
	# missing-via question to answer. [] would falsely claim "we checked".
	check("missing_via_ids ABSENT when no via_ids were supplied",
		not out.has("missing_via_ids"))
	check("net_name keys ABSENT when no net_name was supplied",
		not out.has("net_name") and not out.has("net_match_count"))


# ── 4: delete by net_name ─────────────────────────────────────────────────────

func _run_delete_by_net_name() -> void:
	print("-- 4. delete by net_name removes that net's traces and no others --")
	var data = _seed_board()
	var out: Dictionary = PanelTools._delete_traces(_host_for(data), {"net_name": "GND"})
	check("delete succeeded", bool(out.get("success", false)))

	var deleted: Array = out.get("deleted_trace_ids", [])
	deleted.sort()
	check_eq("both GND traces deleted", deleted, ["trace_b", "trace_d"])
	check_eq("net match count reported", int(out.get("net_match_count", -1)), 2)
	check_eq("net name echoed", str(out.get("net_name", "")), "GND")
	check("missing_trace_ids ABSENT when no trace_ids were supplied",
		not out.has("missing_trace_ids"))

	check_eq("survivors are exactly trace_a and trace_c", _ids(data), ["trace_a", "trace_c"])
	check_eq("trace_a (VCC) untouched", str(data.get_trace("trace_a").net_name), "VCC")
	check_eq("trace_c (SIG) untouched", str(data.get_trace("trace_c").net_name), "SIG")

	# net_name selects TRACES only. The GND via is copper the caller did not
	# name; removing it would be a silent judgement about orphaned copper.
	check_eq("the GND via is NOT swept up by a net delete",
		_via_ids(data), ["via_1", "via_2", "via_3"])

	# A net nobody routed: match count is a real, computed ZERO (we looked), and
	# the call still succeeds with nothing deleted.
	var data2 = _seed_board()
	var out2: Dictionary = PanelTools._delete_traces(_host_for(data2), {"net_name": "NOSUCHNET"})
	check("unrouted net is not an error", bool(out2.get("success", false)))
	check_eq("net_match_count is a computed zero", int(out2.get("net_match_count", -1)), 0)
	check_eq("nothing deleted", out2.get("deleted_trace_ids", []), [])
	check_eq("board untouched", _ids(data2), ["trace_a", "trace_b", "trace_c", "trace_d"])


# ── 5: mixed valid + non-existent ids ─────────────────────────────────────────

func _run_delete_mixed_valid_and_missing() -> void:
	print("-- 5. valid + stale ids: valid deleted, stale NAMED in the reply --")
	var data = _seed_board()
	var out: Dictionary = PanelTools._delete_traces(_host_for(data), {
		"trace_ids": ["trace_a", "trace_zzz", "trace_c", "trace_nope"],
		"via_ids": ["via_2", "via_gone"],
	})
	# Partial success is a SUCCESS. A stale id means the caller holds a slightly
	# old view of the board, not that the request was malformed.
	check("partial application still reports success", bool(out.get("success", false)))
	check_eq("only the real trace ids were deleted",
		out.get("deleted_trace_ids", []), ["trace_a", "trace_c"])
	check_eq("the stale trace ids are NAMED, not just counted",
		out.get("missing_trace_ids", []), ["trace_zzz", "trace_nope"])
	check_eq("the real via was deleted", out.get("deleted_via_ids", []), ["via_2"])
	check_eq("the stale via id is NAMED", out.get("missing_via_ids", []), ["via_gone"])

	check_eq("survivors are exactly trace_b and trace_d", _ids(data), ["trace_b", "trace_d"])
	check_eq("surviving vias are via_1 and via_3", _via_ids(data), ["via_1", "via_3"])

	# A request where EVERY id is stale is still a success — "nothing matched"
	# is a legitimate terminal state, and the reply says exactly that.
	var data2 = _seed_board()
	var out2: Dictionary = PanelTools._delete_traces(_host_for(data2),
		{"trace_ids": ["ghost_1", "ghost_2"]})
	check("all-stale request is not an error", bool(out2.get("success", false)))
	check_eq("nothing deleted", out2.get("deleted_trace_ids", []), [])
	check_eq("both ghosts named", out2.get("missing_trace_ids", []), ["ghost_1", "ghost_2"])
	check_eq("board untouched", _ids(data2), ["trace_a", "trace_b", "trace_c", "trace_d"])

	# A request with NO selector at all IS malformed and must fail.
	var out3: Dictionary = PanelTools._delete_traces(_host_for(_seed_board()), {})
	check("a selector-less request is an error", not bool(out3.get("success", true)))


# ── 6: multiple via deletion — the index-shift trap ───────────────────────────

## THE TRAP, constructed so an index-based implementation gets it WRONG.
## Resolving via_1 -> index 0 and via_2 -> index 1 up front and then calling the
## positional remove_via(0), remove_via(1) removes via_1, and then — because the
## list has already shifted to [via_2, via_3] — index 1 is via_3. Such an
## implementation leaves via_2 alive and reports a perfectly correct count of 2.
## Only the surviving via's OWN identity distinguishes the two outcomes, which is
## why the three vias carry three different nets and positions.
func _run_delete_vias_index_shift_trap() -> void:
	print("-- 6. deleting two vias by id: index-shift trap --")
	var data = _seed_board()
	check_eq("fixture order is via_1, via_2, via_3", _via_ids(data), ["via_1", "via_2", "via_3"])

	var out: Dictionary = PanelTools._delete_traces(_host_for(data),
		{"via_ids": ["via_1", "via_2"]})
	check("delete succeeded", bool(out.get("success", false)))
	check_eq("both named vias reported deleted", out.get("deleted_via_ids", []), ["via_1", "via_2"])
	check_eq("no via id was stale", out.get("missing_via_ids", null), [])

	# The count alone cannot tell the correct outcome from the index-shifted one:
	# both leave exactly one via.
	check_eq("exactly one via remains", int(out.get("remaining_via_count", -1)), 1)
	check_eq("the survivor is via_3, NOT via_2", _via_ids(data), ["via_3"])
	# ...and its own fields confirm it, so even an id-relabelling bug is caught.
	var survivor: Dictionary = _via_at(data, 0)
	check_eq("survivor is the SIG via", str(survivor.get("net_name", "")), "SIG")
	check_eq("survivor sits at (3,3)", survivor.get("position", Vector2.ZERO), Vector2(3, 3))

	# The same trap from the other end: delete the FIRST and LAST via. A loop
	# over pre-captured indices [0, 2] removes via_1, then index 2 is out of
	# range on the shortened list, so via_3 quietly survives.
	var data2 = _seed_board()
	var out2: Dictionary = PanelTools._delete_traces(_host_for(data2),
		{"via_ids": ["via_1", "via_3"]})
	check_eq("first+last deletion reports both", out2.get("deleted_via_ids", []), ["via_1", "via_3"])
	check_eq("the survivor is via_2", _via_ids(data2), ["via_2"])
	check_eq("survivor is the GND via", str(_via_at(data2, 0).get("net_name", "")), "GND")

	# Traces are untouched: nothing named one.
	check_eq("no trace deleted by a via-only request",
		_ids(data2), ["trace_a", "trace_b", "trace_c", "trace_d"])


# ── 7: round trip ─────────────────────────────────────────────────────────────

func _run_round_trip() -> void:
	print("-- 7. export -> drop a subset -> import: ids and geometry survive --")
	var source = _seed_board()
	var exported: Dictionary = PanelTools._export_trace_geometry(_host_for(source), {})
	var payload: Dictionary = exported.get("trace_data", {})

	# The caller does its OWN filtering against the real coordinates it can now
	# associate with a named trace — this is the workflow that replaces the
	# region selector the delete tool deliberately does not offer.
	var kept_segments: Array = []
	for seg in (payload.get("traces", []) as Array):
		if str((seg as Dictionary).get("trace_id", "")) != "trace_b":
			kept_segments.append(seg)
	var kept_vias: Array = []
	for v in (payload.get("vias", []) as Array):
		if str((v as Dictionary).get("id", "")) != "via_2":
			kept_vias.append(v)
	# 5 exported segments minus trace_b's single segment.
	check_eq("filtered payload keeps 4 segments", kept_segments.size(), 4)
	check_eq("filtered payload keeps 2 vias", kept_vias.size(), 2)

	var target = PCBData.new()
	var imported: Dictionary = PanelTools._import_trace_geometry(_host_for(target),
		{"trace_data": {"traces": kept_segments, "vias": kept_vias}})
	check("import succeeded", bool(imported.get("success", false)))

	# Identity SURVIVED — the old positional "trace_%d" % trace_count renamed
	# everything on every import, so these ids would have come back as
	# trace_0/trace_1/trace_2 regardless of what was sent.
	check_eq("imported ids are the originals", _ids(target), ["trace_a", "trace_c", "trace_d"])
	# The reply must name the IDS, not merely count them: a size assertion cannot
	# tell "kept the right trace" from "kept the wrong one", and that is the whole
	# failure mode identity exists to expose.
	var reply_ids: Array = (imported.get("trace_ids", []) as Array).duplicate()
	reply_ids.sort()
	check_eq("import reply names the ids that landed", reply_ids,
		["trace_a", "trace_c", "trace_d"])
	check_eq("via ids survived", _via_ids(target), ["via_1", "via_3"])
	check("the deleted trace did not come back", target.get_trace("trace_b") == null)

	# trace_a's TWO exported segments reassembled into ONE polyline that still
	# wears the supplied id.
	var a = target.get_trace("trace_a")
	check("trace_a present", a != null)
	check_eq("trace_a is one polyline of 3 waypoints", a.waypoints.size(), 3)
	check_eq("trace_a geometry preserved", a.waypoints,
		[Vector2(0, 0), Vector2(1, 0), Vector2(2, 0)])
	check_eq("trace_a net preserved", str(a.net_name), "VCC")
	check_eq("trace_a layer preserved", str(a.layer), "top")
	check_eq("trace_a width preserved", float(a.width), 0.5)

	# The two same-net traces did NOT get merged into one by the net+layer
	# grouping: trace_d is GND on top, trace_c is SIG on top, and both stay
	# separate and correctly paired.
	check_eq("trace_c net preserved", str(target.get_trace("trace_c").net_name), "SIG")
	check_eq("trace_c geometry preserved", target.get_trace("trace_c").waypoints,
		[Vector2(0, 9), Vector2(4, 9)])
	check_eq("trace_d net preserved", str(target.get_trace("trace_d").net_name), "GND")
	check_eq("trace_d geometry preserved", target.get_trace("trace_d").waypoints,
		[Vector2(0, 12), Vector2(6, 12)])

	print("-- 7b. a supplied numeric id listed AFTER id-less segments does not collide --")
	# UPDATED per the owner ruling (docket 019fa172dd21 comment 868): clear_traces
	# no longer resets _next_trace_id to 1 (the counter never lowers — see the
	# ID COUNTER INVARIANT in pcb_data.gd). But the reserve-first pass this test
	# pins is NOT made redundant by that: on a FRESH board (as here) the counter
	# still starts at 1, so an id-less group processed first would mint
	# "trace_1" and the supplied "trace_1" would then overwrite it (traces is
	# keyed by id) — one trace of copper silently lost — regardless of whether
	# the board is fresh or came from a clear_traces() that no longer resets.
	# The reserve-first pass makes the outcome independent of this ordering
	# either way.
	var mixed = PCBData.new()
	var mixed_reply: Dictionary = PanelTools._import_trace_geometry(_host_for(mixed), {
		"trace_data": {
			"traces": [
				{"start": {"x": 0, "y": 0}, "end": {"x": 2, "y": 0},
					"width": 0.3, "layer": "F.Cu", "net_name": "ANON"},
				{"trace_id": "trace_1", "start": {"x": 0, "y": 4}, "end": {"x": 2, "y": 4},
					"width": 0.3, "layer": "F.Cu", "net_name": "NAMED"},
			],
			"vias": [
				{"position": {"x": 7, "y": 7}, "net_name": "ANON"},
				{"id": "via_1", "position": {"x": 8, "y": 8}, "net_name": "NAMED"},
			],
		},
	})
	check_eq("both traces landed", int(mixed_reply.get("trace_count", -1)), 2)
	check_eq("both traces are addressable (no id collision)", mixed.get_trace_ids().size(), 2)
	check("the supplied id survived", mixed.get_trace("trace_1") != null)
	check_eq("the supplied id belongs to the NAMED trace",
		_net_of(mixed, "trace_1"), "NAMED")
	# ...and the OTHER trace is the anonymous one, not a second copy of NAMED —
	# the count above cannot tell those two outcomes apart.
	check_eq("the anonymous trace survived under its own net",
		_nets_of(mixed), ["ANON", "NAMED"])
	var mixed_via_ids := _via_ids(mixed)
	check_eq("both vias landed", mixed_via_ids.size(), 2)
	check("via ids are distinct", _at(mixed_via_ids, 0) != _at(mixed_via_ids, 1))
	check("the supplied via id survived", "via_1" in mixed_via_ids)
	check_eq("and both vias kept their own nets", _via_nets(mixed), ["ANON", "NAMED"])


# ── 8: undo ───────────────────────────────────────────────────────────────────

func _run_undo_after_delete() -> void:
	print("-- 8. undo after a delete restores the deleted trace and via --")
	var data = _seed_board()
	# The pre-delete snapshot the undo will return to. In production this is the
	# "Load" snapshot from_board_dict takes, or whatever the previous action
	# left; _import_trace_geometry relies on the same precondition.
	data.save_to_history("baseline")

	var out: Dictionary = PanelTools._delete_traces(_host_for(data),
		{"trace_ids": ["trace_a"], "via_ids": ["via_1"]})
	check("delete succeeded", bool(out.get("success", false)))
	check_eq("board thinned", _ids(data), ["trace_b", "trace_c", "trace_d"])
	check_eq("via removed", _via_ids(data), ["via_2", "via_3"])
	check("undo is available after the delete", data.can_undo())

	check("undo reported success", data.undo())
	check_eq("all four traces are back", _ids(data),
		["trace_a", "trace_b", "trace_c", "trace_d"])
	var a = data.get_trace("trace_a")
	check_eq("restored trace keeps its net", str(a.net_name), "VCC")
	check_eq("restored trace keeps its geometry", a.waypoints,
		[Vector2(0, 0), Vector2(1, 0), Vector2(2, 0)])
	check_eq("the via is back too, with its id", _via_ids(data), ["via_1", "via_2", "via_3"])
	check_eq("restored via keeps its position",
		_via_at(data, 0).get("position", Vector2.ZERO), Vector2(1, 1))

	# A delete that removed NOTHING must not push a no-op onto the history:
	# an undo step that undoes nothing is noise the user has to click through.
	var data2 = _seed_board()
	data2.save_to_history("baseline")
	var depth_before: int = data2.history.size()
	var out2: Dictionary = PanelTools._delete_traces(_host_for(data2), {"trace_ids": ["ghost"]})
	check("no-op delete still succeeds", bool(out2.get("success", false)))
	check_eq("no history entry added for a no-op delete", data2.history.size(), depth_before)


# ── 9: a DUPLICATE supplied trace_id must not destroy copper ──────────────────

## Regression for a defect this feature INTRODUCED (positional renumbering made
## it impossible before): honouring a supplied trace_id means two segments can
## claim the SAME id, and PCBData.traces is an id-keyed Dictionary, so the second
## claimant silently OVERWRITES the first. One piece of copper disappears while
## the import reply reports both as landed.
##
## The importer's group key is trace_id|net|layer, so one id on two layers (or
## two nets) is TWO groups — the within-group "first polyline keeps the id, the
## rest are minted fresh" rule does not reach across them. The claim has to be
## import-wide.
##
## Both cases are asserted by IDENTITY, never by count: the correct outcome and
## the destructive one differ only in WHICH trace survives when the count is
## right (and here the count is wrong too, but a future variant might not be).
func _run_duplicate_supplied_id() -> void:
	print("-- 9. a duplicate supplied trace_id keeps both traces (id claimed once) --")

	print("   9a. same id, two LAYERS")
	var layers_board = PCBData.new()
	var reply_a: Dictionary = PanelTools._import_trace_geometry(_host_for(layers_board), {
		"trace_data": {"traces": [
			{"trace_id": "trace_x", "start": {"x": 0, "y": 0}, "end": {"x": 2, "y": 0},
				"width": 0.3, "layer": "F.Cu", "net_name": "DUP"},
			{"trace_id": "trace_x", "start": {"x": 0, "y": 4}, "end": {"x": 2, "y": 4},
				"width": 0.3, "layer": "B.Cu", "net_name": "DUP"},
		], "vias": []},
	})
	check("import succeeded", bool(reply_a.get("success", false)))
	check_eq("BOTH traces are on the board — no copper destroyed",
		layers_board.get_trace_ids().size(), 2)
	check_eq("reply claims exactly as many ids as landed",
		(reply_a.get("trace_ids", []) as Array).size(), layers_board.get_trace_ids().size())
	var reply_a_ids: Array = reply_a.get("trace_ids", [])
	check("the reply does not name the same id twice",
		reply_a_ids.size() < 2 or reply_a_ids[0] != reply_a_ids[1])
	check_eq("reported trace_count matches the board",
		int(reply_a.get("trace_count", -1)), layers_board.get_trace_ids().size())

	# The first claimant keeps the id; the second is minted fresh. Assert WHICH
	# copper wears it — a count alone passes while the wrong trace survives.
	check("the supplied id is on the board", layers_board.get_trace("trace_x") != null)
	check_eq("trace_x is the F.Cu (top) one, the first claimant",
		_layer_of(layers_board, "trace_x"), "top")
	var other_layer_ids := _other_ids(layers_board, "trace_x")
	check_eq("exactly one other trace exists", other_layer_ids.size(), 1)
	check_eq("and it is the B.Cu (bottom) one, under a minted id",
		_layer_of(layers_board, _first(other_layer_ids)), "bottom")
	check_eq("its geometry is the bottom trace's, not a copy of the top's",
		_waypoints_of(layers_board, _first(other_layer_ids)),
		[Vector2(0, 4), Vector2(2, 4)])

	print("   9ab. same id, ONE group, two disconnected polylines")
	# The within-GROUP half of the same rule: identical net AND layer, so both
	# segments land in one trace_id|net|layer group, but they do not touch, so
	# _build_polylines_from_segments yields two polylines. The first keeps the id,
	# the second is minted. This case is what distinguishes "the claim is
	# per-group" from "there is no claim at all".
	var split_board = PCBData.new()
	var reply_split: Dictionary = PanelTools._import_trace_geometry(_host_for(split_board), {
		"trace_data": {"traces": [
			{"trace_id": "trace_s", "start": {"x": 0, "y": 0}, "end": {"x": 2, "y": 0},
				"width": 0.3, "layer": "F.Cu", "net_name": "SPLIT"},
			{"trace_id": "trace_s", "start": {"x": 40, "y": 0}, "end": {"x": 42, "y": 0},
				"width": 0.3, "layer": "F.Cu", "net_name": "SPLIT"},
		], "vias": []},
	})
	check("import succeeded", bool(reply_split.get("success", false)))
	check_eq("both disconnected runs survived", split_board.get_trace_ids().size(), 2)
	check_eq("trace_s is the first run", _waypoints_of(split_board, "trace_s"),
		[Vector2(0, 0), Vector2(2, 0)])
	var other_split_ids := _other_ids(split_board, "trace_s")
	check_eq("exactly one other trace exists", other_split_ids.size(), 1)
	check_eq("and it is the far run, under a minted id",
		_waypoints_of(split_board, _first(other_split_ids)), [Vector2(40, 0), Vector2(42, 0)])
	check_eq("reported trace_count matches the board",
		int(reply_split.get("trace_count", -1)), split_board.get_trace_ids().size())

	print("   9b. same id, two NETS")
	var nets_board = PCBData.new()
	var reply_b: Dictionary = PanelTools._import_trace_geometry(_host_for(nets_board), {
		"trace_data": {"traces": [
			{"trace_id": "trace_y", "start": {"x": 0, "y": 0}, "end": {"x": 2, "y": 0},
				"width": 0.3, "layer": "F.Cu", "net_name": "NET_ONE"},
			{"trace_id": "trace_y", "start": {"x": 0, "y": 4}, "end": {"x": 2, "y": 4},
				"width": 0.3, "layer": "F.Cu", "net_name": "NET_TWO"},
		], "vias": []},
	})
	check("import succeeded", bool(reply_b.get("success", false)))
	check_eq("BOTH traces are on the board — no copper destroyed",
		nets_board.get_trace_ids().size(), 2)
	check_eq("both nets survived", _nets_of(nets_board), ["NET_ONE", "NET_TWO"])
	check_eq("trace_y is NET_ONE, the first claimant",
		_net_of(nets_board, "trace_y"), "NET_ONE")
	var other_net_ids := _other_ids(nets_board, "trace_y")
	check_eq("exactly one other trace exists", other_net_ids.size(), 1)
	check_eq("and it is NET_TWO, under a minted id",
		_net_of(nets_board, _first(other_net_ids)), "NET_TWO")

	# The minted id must also not collide with the claimed one on a LATER add.
	var extra = nets_board.new_trace()
	extra.net_name = "NET_THREE"
	extra.layer = "top"
	extra.waypoints.append(Vector2(0, 8))
	extra.waypoints.append(Vector2(2, 8))
	nets_board.add_trace(extra)
	check_eq("a later auto-mint lands beside them, not on top", nets_board.get_trace_ids().size(), 3)
	check_eq("all three nets present", _nets_of(nets_board), ["NET_ONE", "NET_THREE", "NET_TWO"])


# ── 10: board load must high-water the trace-id counter ───────────────────────

## The advertised invariant of this feature is "a minted id can never collide
## with an id that arrived from outside". from_board_dict and load_from_dict
## write traces[trace.id] directly, bypassing add_trace, and neither advanced
## _next_trace_id — which starts at 1. So loading a board whose FIRST trace is
## "trace_1" and then drawing one trace mints "trace_1" again and the loaded
## trace is overwritten on the very next action. Not "after five mints": the
## first one.
##
## _load_vias already high-waters on this exact path, so before this fix traces
## and vias behaved differently on the same load.
func _run_board_load_high_water() -> void:
	print("-- 10. a board load reserves its trace ids against the next mint --")

	print("   10a. from_board_dict (canonical board dict)")
	var source = PCBData.new()
	_add_trace(source, "trace_1", "OLD_NET", "top", 0.3, [Vector2(0, 0), Vector2(2, 0)])
	var board_dict: Dictionary = source.to_board_dict()

	var loaded = PCBData.new()
	loaded.from_board_dict(board_dict)
	check_eq("the board loaded one trace", loaded.get_trace_ids().size(), 1)
	check_eq("it kept its id", _ids(loaded), ["trace_1"])

	# One new trace with NO id — exactly what drawing a trace in the panel does.
	var drawn = loaded.new_trace()
	drawn.net_name = "NEW_NET"
	drawn.layer = "top"
	drawn.width = 0.3
	drawn.waypoints.append(Vector2(0, 6))
	drawn.waypoints.append(Vector2(2, 6))
	loaded.add_trace(drawn)

	check_eq("the loaded trace was NOT overwritten by the first new one",
		loaded.get_trace_ids().size(), 2)
	check_eq("the pre-existing trace_1 still has its ORIGINAL net",
		_net_of(loaded, "trace_1"), "OLD_NET")
	check_eq("both nets are on the board", _nets_of(loaded), ["NEW_NET", "OLD_NET"])
	check_eq("trace_1 kept its own geometry", _waypoints_of(loaded, "trace_1"),
		[Vector2(0, 0), Vector2(2, 0)])

	print("   10b. load_from_dict (legacy .minpcb dict)")
	var source2 = PCBData.new()
	_add_trace(source2, "trace_1", "OLD_NET", "top", 0.3, [Vector2(0, 0), Vector2(2, 0)])
	var legacy_dict: Dictionary = source2.to_dict()

	var loaded2 = PCBData.new()
	loaded2.load_from_dict(legacy_dict)
	check_eq("the legacy board loaded one trace", _ids(loaded2), ["trace_1"])

	var drawn2 = loaded2.new_trace()
	drawn2.net_name = "NEW_NET"
	drawn2.layer = "top"
	drawn2.width = 0.3
	drawn2.waypoints.append(Vector2(0, 6))
	drawn2.waypoints.append(Vector2(2, 6))
	loaded2.add_trace(drawn2)

	check_eq("the loaded trace was NOT overwritten", loaded2.get_trace_ids().size(), 2)
	check_eq("the pre-existing trace_1 still has its ORIGINAL net",
		_net_of(loaded2, "trace_1"), "OLD_NET")
	check_eq("both nets are on the board", _nets_of(loaded2), ["NEW_NET", "OLD_NET"])

	print("   10c. a non-first id high-waters past its own suffix")
	# "trace_7" must push the counter past 7, not merely off 1 — otherwise the
	# collision reappears on the seventh trace drawn.
	var source3 = PCBData.new()
	_add_trace(source3, "trace_7", "OLD_NET", "top", 0.3, [Vector2(0, 0), Vector2(2, 0)])
	var loaded3 = PCBData.new()
	loaded3.from_board_dict(source3.to_board_dict())
	for i in range(8):
		var t = loaded3.new_trace()
		t.net_name = "FILL_%d" % i
		t.layer = "top"
		t.waypoints.append(Vector2(0, 10 + i))
		t.waypoints.append(Vector2(2, 10 + i))
		loaded3.add_trace(t)
	check_eq("eight mints beside one loaded trace = nine traces",
		loaded3.get_trace_ids().size(), 9)
	check_eq("trace_7 still carries its original net",
		_net_of(loaded3, "trace_7"), "OLD_NET")


# ── 11: union overlap between trace_ids and net_name ──────────────────────────

## trace_ids and net_name are a UNION, and they can name the SAME trace. Without
## the `selected` guard in the net pass, that trace is queued twice: it appears
## twice in deleted_trace_ids, inflates deleted_trace_count, and the second
## remove_trace is a silent no-op the reply presents as a second deletion.
## Nothing in the suite exercised the two selectors together before this.
func _run_union_overlap() -> void:
	print("-- 11. a trace named by BOTH selectors is deleted once, counted once --")
	var data = _seed_board()
	# trace_b is named explicitly AND is on net GND (with trace_d).
	var out: Dictionary = PanelTools._delete_traces(_host_for(data),
		{"trace_ids": ["trace_b"], "net_name": "GND"})
	check("delete succeeded", bool(out.get("success", false)))

	var deleted: Array = out.get("deleted_trace_ids", [])
	check_eq("the overlapping trace appears exactly ONCE", deleted.count("trace_b"), 1)
	var deleted_sorted: Array = deleted.duplicate()
	deleted_sorted.sort()
	check_eq("both GND traces deleted, no duplicates", deleted_sorted, ["trace_b", "trace_d"])
	check_eq("the count agrees with the id list", int(out.get("deleted_trace_count", -1)),
		deleted.size())
	check_eq("the count is 2, not an inflated 3", int(out.get("deleted_trace_count", -1)), 2)
	check_eq("net_match_count still reports the net's real size",
		int(out.get("net_match_count", -1)), 2)
	check_eq("the explicitly named id was NOT reported stale",
		out.get("missing_trace_ids", null), [])
	check_eq("survivors are exactly trace_a and trace_c", _ids(data), ["trace_a", "trace_c"])
	check_eq("and they kept their own nets", _nets_of(data), ["SIG", "VCC"])
	check_eq("remaining count agrees with the board",
		int(out.get("remaining_trace_count", -1)), data.get_trace_ids().size())

	# Overlap where the named id is the ONLY trace on the net: the union must
	# still collapse to one deletion, not report the same trace from both passes.
	var data2 = _seed_board()
	var out2: Dictionary = PanelTools._delete_traces(_host_for(data2),
		{"trace_ids": ["trace_c"], "net_name": "SIG"})
	check_eq("single-overlap deletes one trace", out2.get("deleted_trace_ids", []), ["trace_c"])
	check_eq("and counts it once", int(out2.get("deleted_trace_count", -1)), 1)
	check_eq("survivors intact", _ids(data2), ["trace_a", "trace_b", "trace_d"])

	# The same collapse WITHIN one selector: a caller that repeats an id must not
	# see it deleted twice either. This is the other half of the dedupe — the
	# cross-selector case above cannot catch a regression in this one.
	var data3 = _seed_board()
	var out3: Dictionary = PanelTools._delete_traces(_host_for(data3),
		{"trace_ids": ["trace_b", "trace_b", "trace_d"]})
	check_eq("a repeated id is deleted once", out3.get("deleted_trace_ids", []),
		["trace_b", "trace_d"])
	check_eq("and counted once", int(out3.get("deleted_trace_count", -1)), 2)
	check_eq("the repeat was not reported stale", out3.get("missing_trace_ids", null), [])
	check_eq("survivors are exactly trace_a and trace_c", _ids(data3), ["trace_a", "trace_c"])


# ── 12: a DUPLICATE supplied via id must not break via identity ───────────────

## The via twin of group 9, and reachable for the same reason: this feature
## started passing caller-supplied via ids through import, where add_via used to
## always mint. Two vias supplying one id both wore it, and because
## PCBData.remove_via_by_id resolves the FIRST match only, the second was
## permanently undeletable by id while delete_traces cheerfully reported that id
## as deleted. No copper is lost (vias are a list, nothing is overwritten) — what
## breaks is identity, and the reply's honesty with it.
func _run_duplicate_supplied_via_id() -> void:
	print("-- 12. a duplicate supplied via id: both vias land, ids stay distinct --")
	var board = PCBData.new()
	var reply: Dictionary = PanelTools._import_trace_geometry(_host_for(board), {
		"trace_data": {"traces": [], "vias": [
			{"id": "via_9", "position": {"x": 1, "y": 1}, "net_name": "ONE"},
			{"id": "via_9", "position": {"x": 2, "y": 2}, "net_name": "TWO"},
		]},
	})
	check("import succeeded", bool(reply.get("success", false)))
	check_eq("both vias landed", board.vias.size(), 2)
	check_eq("both nets survived", _via_nets(board), ["ONE", "TWO"])

	var ids := _via_ids(board)
	check_eq("two via ids on the board", ids.size(), 2)
	check("the two via ids are DISTINCT", _at(ids, 0) != _at(ids, 1))
	check("the supplied id was kept by one of them", "via_9" in ids)
	check_eq("the FIRST claimant wears it — the ONE via",
		str(_via_at(board, 0).get("id", "")), "via_9")
	check_eq("and it is the ONE via, not the TWO one",
		str(_via_at(board, 0).get("net_name", "")), "ONE")
	check("the second via wears a different, minted id",
		str(_via_at(board, 1).get("id", "")) != "via_9")
	check_eq("the second via is the TWO one",
		str(_via_at(board, 1).get("net_name", "")), "TWO")

	# The reply must name what actually landed, not what was asked for.
	var reply_ids: Array = reply.get("via_ids", [])
	check_eq("reply names two ids", reply_ids.size(), 2)
	check("reply does not name the same id twice", _at(reply_ids, 0) != _at(reply_ids, 1))
	check_eq("reply matches the board exactly", reply_ids, ids)

	# ...and the identity contract holds downstream: deleting the claimed id
	# removes exactly one via and the survivor is still addressable by its own id.
	var out: Dictionary = PanelTools._delete_traces(_host_for(board), {"via_ids": ["via_9"]})
	check_eq("deleting via_9 removes exactly one via", int(out.get("remaining_via_count", -1)), 1)
	check_eq("and it was the ONE via", _via_nets(board), ["TWO"])
	check("no via wearing via_9 survives", not ("via_9" in _via_ids(board)))
	var survivor_id := _first(_via_ids(board))
	check("the survivor still has an id", not survivor_id.is_empty())

	var out2: Dictionary = PanelTools._delete_traces(_host_for(board), {"via_ids": [survivor_id]})
	check_eq("the survivor is deletable by its own id", out2.get("deleted_via_ids", []), [survivor_id])
	check_eq("board is now empty of vias", board.vias.size(), 0)


# ── 13: an EMPTY id selector must be reported, never swallowed ────────────────

## {"trace_ids": [""]} used to return missing_trace_ids: [] — "we checked your
## ids, none were stale" about a call that checked nothing. That is the
## absent-vs-empty rule broken in the worst direction: a confident all-clear.
##
## Reachable, not theoretical: a via restored from a board file predating stable
## via ids has NO "id" key, so a caller mapping `.get("id", "")` over an exported
## via list genuinely sends "".
##
## An empty id is REPORTED as missing rather than rejected — it is an unusable
## handle (a stale selector), not a malformed request, which is the same reason a
## non-existent id does not fail the call.
func _run_empty_id_selectors() -> void:
	print("-- 13. an empty-string id is reported missing, not silently skipped --")
	var data = _seed_board()
	var out: Dictionary = PanelTools._delete_traces(_host_for(data),
		{"trace_ids": [""], "via_ids": [""]})
	check("the call still succeeds", bool(out.get("success", false)))
	check_eq("the empty trace id is REPORTED, not swallowed",
		out.get("missing_trace_ids", []), [""])
	check_eq("the empty via id is REPORTED, not swallowed",
		out.get("missing_via_ids", []), [""])
	check_eq("nothing was deleted", out.get("deleted_trace_ids", []), [])
	check_eq("no via was deleted", out.get("deleted_via_ids", []), [])
	check_eq("the board is untouched", _ids(data),
		["trace_a", "trace_b", "trace_c", "trace_d"])
	check_eq("the vias are untouched", _via_ids(data), ["via_1", "via_2", "via_3"])

	# Mixed with a real id: the good one applies, the empty one is named.
	var data2 = _seed_board()
	var out2: Dictionary = PanelTools._delete_traces(_host_for(data2),
		{"trace_ids": ["trace_a", ""]})
	check_eq("the real id was deleted", out2.get("deleted_trace_ids", []), ["trace_a"])
	check_eq("the empty one is named alongside it", out2.get("missing_trace_ids", []), [""])
	check_eq("survivors are the other three", _ids(data2),
		["trace_b", "trace_c", "trace_d"])

	# A repeated empty id collapses like any other repeat — reported once.
	var data3 = _seed_board()
	var out3: Dictionary = PanelTools._delete_traces(_host_for(data3),
		{"trace_ids": ["", ""]})
	check_eq("a repeated empty id is reported once", out3.get("missing_trace_ids", []), [""])

	# THE GUARD THAT MATTERS: a board carrying a via with NO id key at all (the
	# legacy shape that makes "" reachable in the first place). An empty selector
	# must not match it. Without PCBData.find_via_index's empty-id guard,
	# str(via.get("id", "")) == "" is TRUE for this via and it would be deleted.
	var legacy = PCBData.new()
	legacy.vias.append({"position": Vector2(4, 4), "size": 0.8, "drill": 0.4,
		"net_name": "LEGACY"})
	check_eq("fixture via really has no id key", str(_via_at(legacy, 0).get("id", "")), "")
	var out4: Dictionary = PanelTools._delete_traces(_host_for(legacy), {"via_ids": [""]})
	check("the call succeeds", bool(out4.get("success", false)))
	check_eq("the id-less via was NOT deleted by an empty selector",
		legacy.vias.size(), 1)
	check_eq("and it is still the LEGACY via",
		str(_via_at(legacy, 0).get("net_name", "")), "LEGACY")
	check_eq("the empty selector is reported missing", out4.get("missing_via_ids", []), [""])
	check_eq("nothing was reported deleted", out4.get("deleted_via_ids", []), [])

	# That via is genuinely unaddressable — the export says so by OMITTING the id
	# key, which is the honest signal a caller needs.
	var exported: Dictionary = PanelTools._export_trace_geometry(_host_for(legacy), {})
	var exported_vias: Array = (exported.get("trace_data", {}) as Dictionary).get("vias", [])
	check_eq("one via exported", exported_vias.size(), 1)
	check("the export OMITS the id key rather than emitting an empty one",
		not (exported_vias[0] as Dictionary).has("id"))


# ── 14: R1 concrete failure — import->clear_traces->undo->mint overwrite ──────

## THE EXACT SEQUENCE from docket 019fa172dd21 comment 868, run against the
## REAL production caller of clear_traces() (PanelTools._import_trace_geometry,
## i.e. the live minerva_pcb_import_trace_geometry MCP tool) rather than calling
## PCBData.clear_traces() directly:
##
##   board loaded with trace_1..trace_10 (counter -> 11)
##   -> minerva_pcb_import_trace_geometry with 2 id-less traces
##      (clear_traces() used to drop the counter to 1; no longer does)
##   -> 2 traces minted (counter -> 3 before the fix, -> 13 after)
##   -> _import_trace_geometry's own save_to_history snapshots the 2-trace state
##   -> undo() restores trace_1..trace_10
##      (_restore_state used to leave the counter wherever import left it;
##      now it also reserves every restored trace id, though on this path the
##      counter was never lowered in the first place)
##   -> the next id-less add_trace: BEFORE either fix this mints "trace_3" and
##      OVERWRITES the just-restored trace_3 (traces is an id-keyed
##      Dictionary) — copper destroyed, no journal entry for the loss. AFTER
##      both fixes it mints "trace_13" (or higher) and nothing is overwritten.
func _run_import_undo_mint_no_overwrite() -> void:
	print("-- 14. clear_traces + undo + mint must not overwrite a restored trace (R1) --")

	# Step 1: a board with trace_1..trace_10, loaded the way a real board load
	# would be (from_board_dict), so the trace-id counter high-waters to 11
	# exactly as production does.
	var source = PCBData.new()
	for i in range(1, 11):
		_add_trace(source, "trace_%d" % i, "NET_%d" % i, "top", 0.25,
			[Vector2(i, 0), Vector2(i, 1)])
	var board = PCBData.new()
	board.from_board_dict(source.to_board_dict())
	check_eq("board loaded with all ten original traces", board.get_trace_ids().size(), 10)

	# Step 2: minerva_pcb_import_trace_geometry with 2 id-less traces — the live
	# production caller of clear_traces(). Internally this clears the board,
	# mints two fresh traces, and calls save_to_history("Import traces") itself.
	var import_out: Dictionary = PanelTools._import_trace_geometry(_host_for(board), {
		"trace_data": {
			"traces": [
				{"start": {"x": 20, "y": 0}, "end": {"x": 20, "y": 1},
					"width": 0.25, "layer": "F.Cu", "net_name": "IMPORTED_A"},
				{"start": {"x": 21, "y": 0}, "end": {"x": 21, "y": 1},
					"width": 0.25, "layer": "F.Cu", "net_name": "IMPORTED_B"},
			],
			"vias": [],
		},
	})
	check("import succeeded", bool(import_out.get("success", false)))
	check_eq("clear_traces + import left exactly the 2 imported traces",
		board.get_trace_ids().size(), 2)

	# Step 3: undo — restores trace_1..trace_10 from the "Load" snapshot
	# from_board_dict took, via the same history the import call's own
	# save_to_history pushed onto.
	check("undo is available", board.can_undo())
	check("undo succeeds", board.undo())
	check_eq("all ten original traces are back", board.get_trace_ids().size(), 10)
	check("trace_3 specifically survived the undo", board.get_trace("trace_3") != null)
	check_eq("trace_3 kept its original net", _net_of(board, "trace_3"), "NET_3")
	check_eq("trace_3 kept its original geometry",
		_waypoints_of(board, "trace_3"), [Vector2(3, 0), Vector2(3, 1)])

	# Step 4: THE OVERWRITE CHECK. The next id-less add_trace — exactly what
	# drawing one more trace in the panel does. Before the fix this mints
	# "trace_3" (counter was left at 3 by the import's two id-less mints on a
	# counter clear_traces had reset to 1) and silently overwrites the trace_3
	# this test just confirmed survived undo.
	var minted = board.new_trace()
	minted.net_name = "FRESH"
	minted.layer = "top"
	minted.waypoints.append(Vector2(0, 50))
	minted.waypoints.append(Vector2(1, 50))
	board.add_trace(minted)

	check_eq("eleven traces now on the board — the new mint landed BESIDE the ten, not on top",
		board.get_trace_ids().size(), 11)
	check("the restored trace_3 is untouched by the new mint",
		board.get_trace("trace_3") != null and _net_of(board, "trace_3") == "NET_3")

	# THE DISCRIMINATING FACT: the mint must not collide with ANY of the ten
	# restored ids — asserted directly rather than only via the count above.
	var collided := false
	for i in range(1, 11):
		if minted.id == "trace_%d" % i:
			collided = true
	check("the minted id does not collide with any of the ten restored ids (minted id was %s)"
		% minted.id, not collided)
