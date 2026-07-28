extends SceneTree
## PCB panel MODEL test (Round A of the panel port).
##
## Run: godot --headless --path src --script test/test_pcb_panel_model.gd
##
## Exercises the off-tree ported board model at minerva-plugins/pcb/ui/model/
## (pcb_data.gd + siblings) — the model Round B's canvas/editor UI will consume
## verbatim. Pure GDScript behavior asserts, no Go binary, no autoloads.
##
## Coverage:
##   1. Canonical round-trip: model → to_board_dict() → model → to_board_dict()
##      deep-equal on a representative board.
##   2. Canonical field names present (spot-assert ref / x_mm / rotation_deg,
##      trace width_mm/points, net "Ref.Pad" pin strings).
##   3. from_board_dict TOLERATES + IGNORES annotation/route_hint keys (owned by
##      PcbAnnotationHost now); to_board_dict never emits them.
##   4. undo/redo round-trip on a mutation.
##   5. change_journal records EVERY mutation type symmetrically (the C-19 fix).
##   6. spatial query returns the expected neighbor set.
##
## Off-tree scripts are load()ed at runtime (res:// == src/, so
## res://../../minerva-plugins == C:/github/minerva-plugins) so a bad path FAILS a
## test rather than aborting the script at parse time.

const MODEL_DIR := "res://../../minerva-plugins/pcb/ui/model/"
const PCB_DATA_PATH := MODEL_DIR + "pcb_data.gd"
const PCB_COMPONENT_PATH := MODEL_DIR + "pcb_component.gd"
const PCB_NET_PATH := MODEL_DIR + "pcb_net.gd"
const PCB_TRACE_PATH := MODEL_DIR + "pcb_trace.gd"
const PCB_SPATIAL_PATH := MODEL_DIR + "pcb_spatial_index.gd"

var _pass_count: int = 0
var _fail_count: int = 0

var _PCBData: Script = null
var _PCBComponent: Script = null
var _PCBNet: Script = null
var _PCBTrace: Script = null
var _PCBSpatial: Script = null


func _init() -> void:
	print("=== PCB Panel Model Test ===\n")
	await process_frame

	_PCBData = load(PCB_DATA_PATH)
	_PCBComponent = load(PCB_COMPONENT_PATH)
	_PCBNet = load(PCB_NET_PATH)
	_PCBTrace = load(PCB_TRACE_PATH)
	_PCBSpatial = load(PCB_SPATIAL_PATH)
	check("all five model scripts load off-tree",
			_PCBData != null and _PCBComponent != null and _PCBNet != null
			and _PCBTrace != null and _PCBSpatial != null)
	if _PCBData == null:
		_finish()
		return

	_test_canonical_roundtrip()
	_test_canonical_field_names()
	_test_annotation_tolerance()
	_test_undo_redo()
	_test_via_undo_restore()
	_test_journal_symmetry()
	_test_spatial_query()
	_test_mounting_holes_roundtrip()
	_test_rotation_sign_lands_on_traces()
	_test_null_pad_size_is_skipped_not_invented()
	_test_remove_net_journals_like_remove_trace()
	_test_clear_traces_journals_contents()
	_test_counters_never_lowered_by_clear_traces_and_clear()
	_test_remove_via_journal_identity()
	_test_restore_state_high_waters_trace_counter_in_isolation()

	_finish()


## U4 (019f9509a54c): the worker no longer fabricates a 1.0x1.0mm land for a
## footprint pad that declares no (size ...) — resolve._pads_from_parsed now
## emits {"width": null, "height": null}, matching footprint_def's existing
## convention. That makes a stored NULL reachable here, and GDScript's
## Dictionary.get(key, default) returns the STORED NULL when the key is
## PRESENT-with-null; it only falls back to `default` when the key is ABSENT.
## So the pre-U4 `Vector2(pad_size.get("width", 1), ...)` would construct
## Vector2(null, null) and hard-error at runtime.
##
## This pins the guard, which shipped UNPINNED — the implementing unit correctly
## reported that no gd suite exercised this path and declined to invent a test
## outside its fence. An unpinned fail-closed guard is exactly what a later edit
## reverts silently.
##
## The DISCRIMINATING case is the null-VALUE pad. A pad with the "size" key
## ABSENT would pass either way (get() legitimately returns the default), so
## null-vs-absent is what does the work here.
##
## PAD ORDER IS LOAD-BEARING — do not "tidy" it. The two null pads come FIRST
## and the sized pad LAST. Reason, measured: a weakened guard does not merely
## admit a bad pad, it lets Vector2(1.6, null) throw, which ABORTS the loop
## mid-list. With the sized pad first, an abort still leaves exactly one pad and
## every assertion below passes — the test survives the mutation and pins
## nothing. Putting the sized pad last makes an abort observable as its absence.
## This exact vacuity was caught by half-mutating the guard to check width only;
## the first version of this test passed under it.
func _test_null_pad_size_is_skipped_not_invented() -> void:
	var comp = _PCBComponent.new()
	comp.load_from_dict({
		"id": "U9",
		"pads": [
			# THE DISCRIMINATING PAD: key present, value null (not absent).
			{"number": "1", "position": {"x": 0.0, "y": 0.0},
					"size": {"width": null, "height": null}, "type": "smd"},
			# ONE axis null is still no geometry. This is what kills a guard
			# that only checks width.
			{"number": "2", "position": {"x": 2.0, "y": 0.0},
					"size": {"width": 1.6, "height": null}, "type": "smd"},
			# Sized, and LAST: its survival proves the loop ran to completion.
			{"number": "3", "position": {"x": 4.0, "y": 0.0},
					"size": {"width": 1.6, "height": 0.9}, "type": "smd"},
		],
	})

	check("both null-size pads skipped, sized pad kept (1 of 3)",
			comp.pads.size() == 1,
			"got %d pads — a null dimension must mean 'no pad geometry', never an invented size"
					% comp.pads.size())
	if comp.pads.size() == 1:
		var kept: Dictionary = comp.pads[0]
		# Identity, not just count: proves the LAST pad survived, so the loop
		# completed rather than aborting on the half-null pad above it.
		check("the surviving pad is pad 3 — the loop ran to completion",
				str(kept.get("number", "")) == "3",
				"got pad %s; a mid-loop abort on the half-null pad would leave a different one"
						% str(kept.get("number", "")))
		check("it carries its authored size, not an invented one",
				kept.get("size", Vector2.ZERO).is_equal_approx(Vector2(1.6, 0.9)),
				"got %s" % str(kept.get("size", null)))
		check("no pad carries the invented 1.0x1.0 land",
				not kept.get("size", Vector2.ZERO).is_equal_approx(Vector2.ONE))


## R1 defect A (docket 019fa17326b5): remove_net must produce one journal entry
## and one trace_changed signal PER removed trace, identical to what
## remove_trace itself produces — not a bare `traces.erase()` that journals
## and signals nothing. Content-level, not count-level: the existing
## test_journal_symmetry only ever checked action-KIND membership, and its
## remove_net call had zero traces to remove at the time it ran (the trap
## documented in docket comment 867), so it passed against the broken
## implementation too.
func _test_remove_net_journals_like_remove_trace() -> void:
	print("\n-- remove_net journals + signals per trace, identical to remove_trace (defect A) --")
	var data = _PCBData.new(50.0, 40.0)

	var n = _PCBNet.new()
	n.name = "PWR"
	data.add_net(n)

	var t1 = _PCBTrace.new()
	t1.net_name = "PWR"
	t1.layer = "top"
	t1.add_waypoint(Vector2(0, 0))
	t1.add_waypoint(Vector2(1, 0))
	data.add_trace(t1)

	var t2 = _PCBTrace.new()
	t2.net_name = "PWR"
	t2.layer = "bottom"
	t2.add_waypoint(Vector2(0, 1))
	t2.add_waypoint(Vector2(1, 1))
	data.add_trace(t2)

	# A trace on a DIFFERENT net must survive remove_net("PWR") untouched.
	var t3 = _PCBTrace.new()
	t3.net_name = "GND"
	t3.layer = "top"
	t3.add_waypoint(Vector2(5, 5))
	t3.add_waypoint(Vector2(6, 6))
	data.add_trace(t3)

	var signaled: Array = []
	data.trace_changed.connect(func(tid): signaled.append(str(tid)))

	data.clear_change_journal()
	data.remove_net("PWR")

	check("both PWR traces are gone",
			data.get_trace(t1.id) == null and data.get_trace(t2.id) == null)
	check("the GND trace on a different net survives", data.get_trace(t3.id) != null)

	signaled.sort()
	var want_signaled: Array = [t1.id, t2.id]
	want_signaled.sort()
	check("trace_changed fired exactly once per removed trace (2), matching remove_trace",
			signaled == want_signaled,
			"got %s want %s" % [str(signaled), str(want_signaled)])

	var remove_trace_entries: Array = []
	var remove_net_entries: Array = []
	for entry in data.get_change_journal():
		var action := str(entry.get("action", ""))
		if action == "remove_trace":
			remove_trace_entries.append(entry)
		elif action == "remove_net":
			remove_net_entries.append(entry)

	check("exactly one remove_trace journal entry per removed trace (2), not zero",
			remove_trace_entries.size() == 2, "got %d" % remove_trace_entries.size())
	check("exactly one remove_net journal entry for the net itself",
			remove_net_entries.size() == 1, "got %d" % remove_net_entries.size())

	var journaled_ids: Array = []
	for entry in remove_trace_entries:
		var details: Dictionary = entry.get("details", {})
		journaled_ids.append(str(details.get("trace_id", "")))
		check("remove_trace entry names net_name PWR",
				str(details.get("net_name", "")) == "PWR",
				"got %s" % str(details.get("net_name", "")))
		check("remove_trace entry carries a layer field (matches remove_trace's own shape)",
				details.has("layer"))
		check("remove_trace entry carries a segment_count field",
				details.has("segment_count"))
	journaled_ids.sort()
	var want_ids: Array = [t1.id, t2.id]
	want_ids.sort()
	check("the journalled trace_ids are exactly the two removed PWR traces",
			journaled_ids == want_ids,
			"got %s want %s" % [str(journaled_ids), str(want_ids)])


## R1 defect C (unfiled, but the one with a live production caller): clear_traces
## must journal WHAT it destroyed (trace/via ids), not an empty {} — and must
## emit trace_changed per destroyed trace, same as removing them one at a time
## would. A count cannot distinguish a journalled deletion from an unjournalled
## one; this asserts CONTENTS.
func _test_clear_traces_journals_contents() -> void:
	print("\n-- clear_traces journals WHAT it destroyed, not just that it happened (defect C) --")
	var data = _PCBData.new(50.0, 40.0)

	var t1 = _PCBTrace.new()
	t1.net_name = "A"
	t1.add_waypoint(Vector2(0, 0))
	t1.add_waypoint(Vector2(1, 0))
	data.add_trace(t1)

	var t2 = _PCBTrace.new()
	t2.net_name = "B"
	t2.add_waypoint(Vector2(0, 2))
	t2.add_waypoint(Vector2(1, 2))
	data.add_trace(t2)

	data.add_via({"id": "via_x", "position": Vector2(4, 4), "net_name": "A"})

	var signaled: Array = []
	data.trace_changed.connect(func(tid): signaled.append(str(tid)))

	data.clear_change_journal()
	data.clear_traces()

	check("all traces gone", data.get_trace_count() == 0)
	check("all vias gone", data.vias.is_empty())

	var entries: Array = data.get_change_journal()
	check("exactly one clear_traces journal entry", entries.size() == 1,
			"got %d" % entries.size())
	if entries.size() == 1:
		var details: Dictionary = entries[0].get("details", {})
		var jt_ids: Array = (details.get("trace_ids", []) as Array).duplicate()
		jt_ids.sort()
		var want_ids: Array = [t1.id, t2.id]
		want_ids.sort()
		check("journal names the destroyed trace ids, not merely a count",
				jt_ids == want_ids, "got %s want %s" % [str(jt_ids), str(want_ids)])
		check("journal names the destroyed via id",
				(details.get("via_ids", []) as Array) == ["via_x"],
				"got %s" % str(details.get("via_ids", [])))

	signaled.sort()
	var want_signaled: Array = [t1.id, t2.id]
	want_signaled.sort()
	check("trace_changed fired once per destroyed trace, same as a per-item removal would",
			signaled == want_signaled, "got %s" % str(signaled))


## Owner ruling (docket 019fa172dd21 comment 868): clear_traces()/clear() must
## NEVER lower _next_trace_id / _next_via_id. Proven here by minting an
## explicit HIGH id, clearing, then minting an id-less one and asserting the
## new id keeps climbing rather than restarting at 1 — a restart would collide
## the very next time an entity from before the clear reappeared (e.g. via
## undo), which is exactly what test_trace_identity_delete.gd's group 14
## exercises end to end via the real import->undo->mint path.
func _test_counters_never_lowered_by_clear_traces_and_clear() -> void:
	print("\n-- clear_traces()/clear() never lower the id counters (owner ruling) --")

	# clear_traces()
	var data = _PCBData.new()
	var t_hi = _PCBTrace.new()
	t_hi.id = "trace_100"
	t_hi.net_name = "X"
	t_hi.add_waypoint(Vector2(0, 0))
	t_hi.add_waypoint(Vector2(1, 0))
	data.add_trace(t_hi)
	data.add_via({"id": "via_50", "position": Vector2(0, 0), "net_name": "X"})

	data.clear_traces()

	var minted_trace = data.new_trace()
	minted_trace.net_name = "Y"
	minted_trace.add_waypoint(Vector2(2, 2))
	minted_trace.add_waypoint(Vector2(3, 3))
	data.add_trace(minted_trace)
	check("trace counter climbed past 100 rather than resetting to 1",
			minted_trace.id == "trace_101", "got %s" % minted_trace.id)

	var minted_via_id: String = data.add_via({"position": Vector2(9, 9), "net_name": "Y"})
	check("via counter climbed past 50 rather than resetting to 1",
			minted_via_id == "via_51", "got %s" % minted_via_id)

	# clear() — same expectation, the ruling covers both methods.
	var data2 = _PCBData.new()
	var t_hi2 = _PCBTrace.new()
	t_hi2.id = "trace_200"
	t_hi2.net_name = "X"
	t_hi2.add_waypoint(Vector2(0, 0))
	t_hi2.add_waypoint(Vector2(1, 0))
	data2.add_trace(t_hi2)
	data2.add_via({"id": "via_80", "position": Vector2(0, 0), "net_name": "X"})

	data2.clear()

	var minted_trace2 = data2.new_trace()
	minted_trace2.net_name = "Y"
	minted_trace2.add_waypoint(Vector2(2, 2))
	minted_trace2.add_waypoint(Vector2(3, 3))
	data2.add_trace(minted_trace2)
	check("clear() also leaves the trace counter climbing, not reset (matches clear_traces)",
			minted_trace2.id == "trace_201", "got %s" % minted_trace2.id)

	var minted_via_id2: String = data2.add_via({"position": Vector2(9, 9), "net_name": "Y"})
	check("clear() leaves the via counter climbing too",
			minted_via_id2 == "via_81", "got %s" % minted_via_id2)


## R1 defect D (unfiled, small): remove_via(index) and remove_via_by_id(id)
## must journal the SAME identifying fields — an index alone cannot identify
## the destroyed via after the fact because indices shift on every removal.
func _test_remove_via_journal_identity() -> void:
	print("\n-- remove_via / remove_via_by_id journal the same identifying fields (defect D) --")
	var data = _PCBData.new()
	data.add_via({"id": "via_a", "position": Vector2(1, 1), "net_name": "NET_A"})
	data.add_via({"id": "via_b", "position": Vector2(2, 2), "net_name": "NET_B"})

	data.clear_change_journal()
	data.remove_via(0)   # positional removal of via_a

	var entries: Array = data.get_change_journal()
	check("remove_via produced one journal entry", entries.size() == 1)
	var d1: Dictionary = entries[0].get("details", {}) if entries.size() == 1 else {}
	check("remove_via(index) names the via_id", str(d1.get("via_id", "")) == "via_a",
			"got %s" % str(d1.get("via_id", "")))
	check("remove_via(index) names the net_name", str(d1.get("net_name", "")) == "NET_A")
	var pos1: Dictionary = d1.get("position", {})
	check("remove_via(index) names the position",
			float(pos1.get("x", -999.0)) == 1.0 and float(pos1.get("y", -999.0)) == 1.0,
			"got %s" % str(pos1))

	data.clear_change_journal()
	check("remove_via_by_id succeeds", data.remove_via_by_id("via_b"))
	var entries2: Array = data.get_change_journal()
	check("remove_via_by_id produced one journal entry", entries2.size() == 1)
	var d2: Dictionary = entries2[0].get("details", {}) if entries2.size() == 1 else {}
	check("remove_via_by_id names the via_id", str(d2.get("via_id", "")) == "via_b")
	check("remove_via_by_id names the net_name", str(d2.get("net_name", "")) == "NET_B")

	var keys1: Array = d1.keys()
	keys1.sort()
	var keys2: Array = d2.keys()
	keys2.sort()
	check("both removal paths journal the identical field set",
			keys1 == keys2, "keys1=%s keys2=%s" % [str(keys1), str(keys2)])


## R1 defect B (docket 019fa172dd21), pinned WITHOUT going through clear_traces/
## clear(). save_to_history() never snapshots the counters (only the
## entities), and undo/redo faithfully hand that snapshot to _restore_state —
## so a history entry containing an id-suffix the counter never advanced for
## is exactly the shape _restore_state must defend against on its own.
## `history`/`history_index` are plain public fields on PCBData (no
## underscore), so a test can forge one directly instead of only reaching this
## path indirectly through clear_traces (whose OWN fix, once applied, makes
## this path's own reservation redundant for every path reachable through the
## public API today — see the mutation-testing note in the campaign report).
## Forging bypasses that redundancy and pins _restore_state's reservation on
## its own.
func _test_restore_state_high_waters_trace_counter_in_isolation() -> void:
	print("\n-- _restore_state high-waters the trace counter on its own (defect B) --")
	var data = _PCBData.new()

	var forged = _PCBTrace.new()
	forged.id = "trace_1"
	forged.net_name = "FORGED"
	forged.add_waypoint(Vector2(0, 0))
	forged.add_waypoint(Vector2(1, 0))

	# undo() moves BACKWARD to history[history_index - 1], so the forged
	# snapshot carrying trace_1 must be the OLDER entry, with a normal (empty)
	# snapshot ahead of it as the "current" state undo steps back from. This
	# mirrors exactly what save_to_history would have produced, but skips ever
	# calling add_trace, so the counter (still at its fresh-board default of 1)
	# never got a chance to reserve past "trace_1" the normal way.
	data.history.append({
		"action": "forged",
		"components": {}, "nets": {},
		"traces": {"trace_1": forged.to_dict()},
		"vias": [], "mounting_holes": [],
	})
	data.history_index = 0
	data.save_to_history("after")  # appends the current (trace-less) state at index 1

	check("undo restores the forged trace_1", data.undo())
	check("trace_1 is on the board after the forged restore", data.get_trace("trace_1") != null)

	# The next id-less mint — exactly what drawing a trace does. Before the fix
	# this mints "trace_1" again (the counter was never reserved past it) and
	# SILENTLY OVERWRITES the just-restored one in the id-keyed `traces` dict.
	var minted = data.new_trace()
	minted.net_name = "FRESH"
	minted.add_waypoint(Vector2(2, 2))
	minted.add_waypoint(Vector2(3, 2))
	data.add_trace(minted)

	check("both traces are on the board — the mint did not overwrite the restored one",
			data.get_trace_count() == 2, "got %d" % data.get_trace_count())
	check("the restored trace_1 kept its own net (not overwritten)",
			data.get_trace("trace_1") != null and str(data.get_trace("trace_1").net_name) == "FORGED",
			"got %s" % (str(data.get_trace("trace_1").net_name) if data.get_trace("trace_1") != null else "<gone>"))
	check("the minted trace got its own id, not trace_1",
			minted.id != "trace_1", "got %s" % minted.id)


func _finish() -> void:
	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


# ──────────────────────────────────────────────────────────────────────────────
# Representative board builder (shared)
# ──────────────────────────────────────────────────────────────────────────────

## Build a representative board via the model API (components with pins + value,
## an auto-created power net, a routed trace, a via, design rules).
func _build_board():
	var data = _PCBData.new(50.0, 40.0)
	data.board_name = "Blinky"
	data.grid_size = 2.54
	data.design_rules = {"clearance_mm": 0.2, "trace_width_mm": 0.25, "via_diameter_mm": 0.8}

	var u1 = _PCBComponent.new()
	u1.id = "U1"
	u1.set_footprint_by_name("IC_DIP")
	u1.position = Vector2(20.0, 12.0)
	u1.rotation = 90.0
	u1.setup_standard_pins()
	u1.properties["value"] = "NE555"
	data.add_component(u1)

	var r1 = _PCBComponent.new()
	r1.id = "R1"
	r1.set_footprint_by_name("RESISTOR")
	r1.position = Vector2(34.0, 6.0)
	r1.setup_standard_pins()
	r1.properties["value"] = "10k"
	data.add_component(r1)

	# Net (auto-created by connect_pin_to_net) with two pins.
	data.connect_pin_to_net("VCC", "U1", "8")
	data.connect_pin_to_net("VCC", "R1", "1")

	# Routed trace.
	var t = _PCBTrace.new()
	t.net_name = "VCC"
	t.layer = "top"
	t.width = 0.25
	t.add_waypoint(Vector2(10.0, 5.0))
	t.add_waypoint(Vector2(20.0, 12.0))
	data.add_trace(t)

	# Via with an Extra "layers" key (rides canonical Extra).
	data.add_via({
		"position": Vector2(15.0, 8.0),
		"drill": 0.4,
		"size": 0.8,
		"net_name": "VCC",
		"layers": ["top", "bottom"]
	})
	return data


# ──────────────────────────────────────────────────────────────────────────────
# Tests
# ──────────────────────────────────────────────────────────────────────────────

func _test_canonical_roundtrip() -> void:
	print("-- canonical round-trip model→board_dict→model deep-equal --")
	var a = _build_board()
	var d1: Dictionary = a.to_board_dict()

	var b = _PCBData.new()
	b.from_board_dict(d1)
	var d2: Dictionary = b.to_board_dict()

	check("board_dict round-trips deep-equal (model→dict→model→dict)", d1 == d2,
			"d1 != d2\n  d1=%s\n  d2=%s" % [str(d1), str(d2)])
	# State-level spot checks on the reconstructed model.
	check("reconstructed model keeps both components", b.get_component_count() == 2)
	check("reconstructed model keeps the net", b.has_net("VCC"))
	check("reconstructed model keeps the trace", b.get_trace_count() == 1)
	check("reconstructed component value survives (U1=NE555)",
			b.get_component("U1") != null and b.get_component("U1").properties.get("value", "") == "NE555")
	check("reconstructed via count preserved", b.vias.size() == 1)


func _test_canonical_field_names() -> void:
	print("\n-- canonical field names present at the boundary --")
	var a = _build_board()
	var d: Dictionary = a.to_board_dict()

	check("board dict uses width_mm/height_mm/grid_mm",
			d.has("width_mm") and d.has("height_mm") and d.has("grid_mm"))
	check("board dict carries design_rules", d.has("design_rules")
			and (d["design_rules"] as Dictionary).has("clearance_mm"))
	check("components is a list (not id-map)", d.get("components", null) is Array)

	# Find U1 in the (sorted) component list.
	var u1_dict := {}
	for c in d.get("components", []):
		if str(c.get("ref", "")) == "U1":
			u1_dict = c
			break
	check("component uses canonical 'ref'", u1_dict.get("ref", "") == "U1")
	check("component uses canonical 'x_mm'/'y_mm'",
			u1_dict.get("x_mm", null) == 20.0 and u1_dict.get("y_mm", null) == 12.0)
	check("component uses canonical 'rotation_deg'", u1_dict.get("rotation_deg", null) == 90.0)
	check("component pins are {number,x_mm,y_mm}",
			u1_dict.get("pins", []) is Array and (u1_dict["pins"] as Array).size() > 0
			and (u1_dict["pins"][0] as Dictionary).has("number")
			and (u1_dict["pins"][0] as Dictionary).has("x_mm"))

	# Trace canonical fields.
	var traces: Array = d.get("traces", [])
	check("trace uses canonical 'width_mm'/'points'/'net'",
			traces.size() == 1 and (traces[0] as Dictionary).has("width_mm")
			and (traces[0] as Dictionary).has("points")
			and str((traces[0] as Dictionary).get("net", "")) == "VCC")

	# Net pins flattened to "Ref.Pad" strings.
	var nets: Array = d.get("nets", [])
	var vcc := {}
	for n in nets:
		if str(n.get("name", "")) == "VCC":
			vcc = n
			break
	check("net pins are flat 'Ref.Pad' strings",
			vcc.get("pins", []) is Array and "U1.8" in vcc.get("pins", []) and "R1.1" in vcc.get("pins", []),
			"pins=%s" % str(vcc.get("pins", [])))


func _test_annotation_tolerance() -> void:
	print("\n-- from_board_dict tolerates + ignores annotation/route_hint keys --")
	var a = _build_board()
	var d: Dictionary = a.to_board_dict()
	# The Go importer passes annotations/route_hints through opaquely; the model
	# must ignore them without error.
	d["annotations"] = [{"id": "ann_0001", "kind": "pcb_route_hint"}]
	d["route_hints"] = [{"id": "hint_1", "hint_type": "waypoint"}]

	var b = _PCBData.new()
	b.from_board_dict(d)
	check("board with annotation keys loads without error (components intact)",
			b.get_component_count() == 2 and b.has_net("VCC"))

	# Model owns no annotation storage; its own board_dict must not emit them.
	var d2: Dictionary = b.to_board_dict()
	check("model's to_board_dict does NOT emit 'annotations'", not d2.has("annotations"))
	check("model's to_board_dict does NOT emit 'route_hints'", not d2.has("route_hints"))


func _test_undo_redo() -> void:
	print("\n-- undo/redo round-trip on a mutation --")
	var data = _build_board()
	# Establish a clean undo baseline (from_board_dict does this on load; here we
	# snapshot the current built state as the baseline).
	data.save_to_history("baseline")
	var orig: Vector2 = data.get_component("R1").position

	var moved := Vector2(40.0, 20.0)
	data.move_component("R1", moved)
	data.save_to_history("move R1")

	check("can_undo after a mutation", data.can_undo())
	check("undo() succeeds", data.undo())
	check("undo restores original position",
			data.get_component("R1").position == orig,
			"got %s want %s" % [str(data.get_component("R1").position), str(orig)])
	check("can_redo after undo", data.can_redo())
	check("redo() succeeds", data.redo())
	check("redo re-applies the move",
			data.get_component("R1").position == moved,
			"got %s want %s" % [str(data.get_component("R1").position), str(moved)])


## F1 / Via Correctness GATE INV-1 (Codex 019f70ec149b): undo/redo must restore
## vias, not orphan them. Before the fix the undo codec omitted vias, so undoing
## an accepted via route removed its traces but left its vias floating.
func _test_via_undo_restore() -> void:
	print("\n-- undo/redo restores vias (F1 / GATE INV-1) --")
	var data = _build_board()  # _build_board seeds one via at (15, 8)
	data.save_to_history("baseline")
	var base_count: int = data.vias.size()
	check("baseline has one via", base_count == 1, "got %d" % base_count)

	# Simulate accepting a via-bearing route: add a via, then snapshot.
	data.add_via({
		"position": Vector2(30.0, 18.0), "drill": 0.4, "size": 0.8,
		"net_name": "VCC", "from_layer": "top", "to_layer": "bottom"
	})
	data.save_to_history("accept via route")
	check("after accept, two vias", data.vias.size() == 2, "got %d" % data.vias.size())

	# The fix: undo removes the accepted via instead of orphaning it.
	check("undo() succeeds", data.undo())
	check("undo restores via count (no orphan)", data.vias.size() == base_count,
			"got %d want %d" % [data.vias.size(), base_count])
	var restored_pos = data.vias[0].get("position") if data.vias.size() == 1 else null
	check("restored via keeps its position", restored_pos == Vector2(15.0, 8.0),
			"got %s" % str(restored_pos))

	# redo re-adds the accepted via.
	check("redo() succeeds", data.redo())
	check("redo re-adds the via", data.vias.size() == 2, "got %d" % data.vias.size())


func _test_journal_symmetry() -> void:
	print("\n-- change_journal records ALL mutation types symmetrically (C-19) --")
	var data = _PCBData.new(50.0, 40.0)
	data.clear_change_journal()

	# Exercise every mutating operation exactly once.
	var c = _PCBComponent.new()
	c.id = "U1"
	c.set_footprint_by_name("IC_DIP")
	c.setup_standard_pins()
	data.add_component(c)                                   # add_component
	data.move_component("U1", Vector2(5.0, 5.0))            # move_component
	data.rotate_component("U1", 90.0)                       # rotate_component

	var n = _PCBNet.new()
	n.name = "GND"
	data.add_net(n)                                         # add_net
	data.connect_pin_to_net("GND", "U1", "1")              # connect_net
	data.disconnect_pin_from_net("GND", "U1", "1")         # disconnect_net

	var t = _PCBTrace.new()
	t.net_name = "GND"
	t.add_waypoint(Vector2(0, 0))
	t.add_waypoint(Vector2(1, 1))
	data.add_trace(t)                                       # add_trace
	data.remove_trace(t.id)                                 # remove_trace

	data.add_via({"position": Vector2(1, 1), "drill": 0.4, "size": 0.8})  # add_via
	data.remove_via(0)                                      # remove_via
	data.add_via({"position": Vector2(2, 2)})              # (re-add so clear has content)
	data.clear_traces()                                    # clear_traces

	# THE TRAP (docket 019fa17326b5 comment 867): the ONLY trace ever put on
	# GND (t, above) was already removed by remove_trace before clear_traces
	# ran, so a bare `data.remove_net("GND")` here would have ZERO traces to
	# remove and would pass whether remove_net journals correctly or not — the
	# appearance of coverage, not coverage. Give GND a fresh trace so
	# remove_net below actually has real copper to clean up.
	var t_gnd = _PCBTrace.new()
	t_gnd.net_name = "GND"
	t_gnd.layer = "top"
	t_gnd.add_waypoint(Vector2(2, 2))
	t_gnd.add_waypoint(Vector2(3, 3))
	data.add_trace(t_gnd)

	data.set_board_size(60.0, 45.0)                        # resize_board
	data.remove_net("GND")                                 # remove_net (removes t_gnd for real)
	data.remove_component("U1")                            # remove_component

	var actions := {}
	for entry in data.get_change_journal():
		actions[str(entry.get("action", ""))] = true

	var expected := [
		"add_component", "move_component", "rotate_component",
		"add_net", "connect_net", "disconnect_net", "remove_net",
		"add_trace", "remove_trace", "clear_traces",
		"add_via", "remove_via", "resize_board", "remove_component",
	]
	var missing: Array = []
	for act in expected:
		if not actions.has(act):
			missing.append(act)
	check("journal records every mutation type symmetrically (14 kinds)",
			missing.is_empty(), "missing journal actions: %s" % str(missing))


func _test_spatial_query() -> void:
	print("\n-- spatial query returns expected neighbors --")
	var data = _PCBData.new(100.0, 100.0)
	for spec in [["U1", Vector2(10.0, 10.0)], ["R1", Vector2(20.0, 10.0)], ["C1", Vector2(80.0, 80.0)]]:
		var comp = _PCBComponent.new()
		comp.id = spec[0]
		comp.set_footprint_by_name("RESISTOR")
		comp.position = spec[1]
		comp.setup_standard_pins()
		data.add_component(comp)

	var idx = _PCBSpatial.new(data)
	var near: Array = idx.get_components_near("U1", 15.0)
	check("get_components_near returns the close neighbor (R1)", "R1" in near,
			"near=%s" % str(near))
	check("get_components_near excludes the far component (C1)", not ("C1" in near),
			"near=%s" % str(near))
	check("get_nearest_component finds R1 nearest to U1",
			idx.get_nearest_to_component("U1") == "R1")


func _test_mounting_holes_roundtrip() -> void:
	print("\n-- board-level mounting_holes load + round-trip (mirrors vias) --")
	var board := {
		"version": 1,
		"name": "MountingHoleBoard",
		"width_mm": 80.0,
		"height_mm": 110.0,
		"grid_mm": 2.54,
		"layers": ["top", "bottom"],
		"design_rules": {},
		"components": [],
		"nets": [],
		"traces": [],
		"vias": [],
		"mounting_holes": [
			{"x_mm": 5.0, "y_mm": 5.0, "diameter_mm": 3.2, "plated": false},
			{"x_mm": 75.0, "y_mm": 5.0, "diameter_mm": 3.2, "plated": false},
			{"x_mm": 5.0, "y_mm": 105.0, "diameter_mm": 3.2, "plated": false},
			{"x_mm": 75.0, "y_mm": 105.0, "diameter_mm": 3.2, "plated": false},
		]
	}

	var data = _PCBData.new()
	data.from_board_dict(board)

	check("mounting_holes loaded (4 holes)", data.mounting_holes.size() == 4,
			"got %d" % data.mounting_holes.size())

	var first: Dictionary = data.mounting_holes[0] if data.mounting_holes.size() > 0 else {}
	check("first hole position is Vector2(5, 5)",
			first.get("position", null) == Vector2(5.0, 5.0),
			"got %s" % str(first.get("position", null)))
	check("first hole diameter preserved (3.2)",
			is_equal_approx(float(first.get("diameter", 0.0)), 3.2),
			"got %s" % str(first.get("diameter", null)))
	check("first hole plated preserved (false)",
			first.get("plated", true) == false)

	var d2: Dictionary = data.to_board_dict()
	var out_holes: Array = d2.get("mounting_holes", [])
	check("to_board_dict round-trips mounting_holes count (4)",
			out_holes.size() == 4, "got %d" % out_holes.size())

	if out_holes.size() == 4:
		var h0: Dictionary = out_holes[0]
		check("round-tripped hole x_mm/y_mm/diameter_mm/plated match input",
				is_equal_approx(float(h0.get("x_mm", -1.0)), 5.0)
				and is_equal_approx(float(h0.get("y_mm", -1.0)), 5.0)
				and is_equal_approx(float(h0.get("diameter_mm", -1.0)), 3.2)
				and h0.get("plated", true) == false,
				"h0=%s" % str(h0))

	# Legacy to_dict/load_from_dict path (undo snapshots) must also preserve holes.
	var snap: Dictionary = data.to_dict()
	check("legacy to_dict serializes mounting_holes (4)",
			(snap.get("mounting_holes", []) as Array).size() == 4,
			"got %d" % (snap.get("mounting_holes", []) as Array).size())
	var data2 = _PCBData.new()
	data2.load_from_dict(snap)
	check("legacy load_from_dict restores mounting_holes (4)",
			data2.mounting_holes.size() == 4,
			"got %d" % data2.mounting_holes.size())
	if data2.mounting_holes.size() == 4:
		var lh: Dictionary = data2.mounting_holes[0]
		check("legacy-restored hole position + plated:false preserved",
				lh.get("position", null) == Vector2(5.0, 5.0)
				and lh.get("plated", true) == false,
				"lh=%s" % str(lh))


# ──────────────────────────────────────────────────────────────────────────────

## Rotation-convention regression: rotation_deg is KiCad-equivalent, so
## get_transform() applies R(-rotation) (matching the worker's radians(-deg)).
## MIC1 at its KiCad-sign rotation (90) must land its WS pad on the I2S_WS trace
## end. A +rotation panel (or a stale-negated 270 in the data) puts it off-board.
func _test_rotation_sign_lands_on_traces() -> void:
	print("\n-- rotation convention: KiCad-sign 90-deg pin lands on its trace --")
	var comp = _PCBComponent.new()
	comp.id = "MIC1"
	comp.position = Vector2(40.64, 106.68)   # smart-remote MIC1 placement
	comp.rotation = 90.0                      # KiCad-sign (canonical, corrected)
	comp.pins = {"4": Vector2(7.62, 5.08)}    # WS pad, footprint-local

	# I2S_WS trace terminates at (45.72, 99.06); R(-90) must reach it.
	var wp: Vector2 = comp.get_pin_world_position("4")
	check("MIC1.WS (rot90, KiCad conv) world pos on I2S_WS trace end (45.72, 99.06)",
			wp.is_equal_approx(Vector2(45.72, 99.06)),
			"got %s (a +rotation panel would give 35.56,114.3 off-board)" % str(wp))
	# And it must be inside the 80x110 board, not hanging off the bottom.
	check("MIC1.WS world pos is on-board (y <= 110)", wp.y <= 110.0,
			"got y=%.2f" % wp.y)


func check(description: String, condition: bool, detail: String = "") -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		if detail != "":
			printerr("  FAIL: %s — %s" % [description, detail])
		else:
			printerr("  FAIL: %s" % description)
