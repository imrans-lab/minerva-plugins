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
const PcbEntityId := preload("res://../../minerva-plugins/pcb/ui/model/pcb_entity_id.gd")

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
	_test_canonical_extras_survive_every_codec()
	_test_csv_import_extras_follow_identity()
	_test_canonical_field_names()
	_test_annotation_tolerance()
	_test_undo_redo()
	_test_via_undo_restore()
	_test_journal_symmetry()
	_test_spatial_query()
	_test_mounting_holes_roundtrip()
	_test_rotation_sign_lands_on_traces()
	_test_null_pad_size_is_skipped_not_invented()
	_test_pads_key_states_the_geometry_authority()
	_test_remove_net_journals_like_remove_trace()
	_test_clear_traces_journals_contents()
	_test_counters_never_lowered_by_clear_traces_and_clear()
	_test_remove_via_journal_identity()
	_test_restore_state_high_waters_trace_counter_in_isolation()

	# Campaign-2 boundary block (BT-08…11, 13…17, 24…26, 29).
	_test_group_serialization_roundtrip()
	_test_group_typed_offset_in_serialized_output()
	_test_group_undo_restores_member_positions()
	_test_group_rotation_is_rigid()
	_test_zone_edit_serialized_outline()
	_test_zone_edit_journal_deltas()
	_test_zone_refusals_are_the_models_own_strings()
	_test_zone_roundtrip_preserves_outline_net_layer()
	_test_width_roundtrips_through_serialization()
	_test_width_journal_deltas()
	_test_width_undo_restores_geometry_not_just_the_field()
	_test_width_bounds_live_in_exactly_one_file()
	_assert_every_section_ran()

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


## The `pads` KEY is a claim of geometry OWNERSHIP, so the panel may only state
## it when the component really carries lands. The worker's rule
## (inline_footprint.carries_full_geometry): a present `pads` list is the
## COMPLETE set of lands and the library is never consulted, so `pads: []` means
## exactly zero pads. Emitting it unconditionally sent every pins-only part over
## the wire claiming zero lands, and the worker refused the whole board with
## "component 'U1' pin '1' has no matching footprint pad".
##
## Three states, all three round-tripped through BOTH codecs — to_dict is the
## undo-history shape, so a snapshot must not change which state a part is in.
func _test_pads_key_states_the_geometry_authority() -> void:
	print("\n-- the pads key states who owns the geometry --")

	# (a) Pins-only: no lands anywhere, so nothing to state. Pin geometry is
	# absent too (no drill_mm/pad_width_mm), so nothing is synthesized either.
	var pins_only = _PCBComponent.new()
	pins_only.load_from_board_dict({
		"ref": "U1", "footprint": "TH_TestPoint", "x_mm": 10.0, "y_mm": 10.0,
		"pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}]})
	check("pins-only: the board dict states NO pads key",
			not pins_only.to_board_dict().has("pads"),
			"got %s" % str(pins_only.to_board_dict().get("pads", null)))
	check("pins-only: the legacy/undo dict states no pads key either",
			not pins_only.to_dict().has("pads"))
	var pins_only_restored = _PCBComponent.new()
	pins_only_restored.load_from_dict(pins_only.to_dict())
	check("pins-only: an undo snapshot round trip keeps the key absent",
			not pins_only_restored.to_board_dict().has("pads"))

	# (b) An AUTHORED empty list is a real answer — the bench's LOGO_R12, a
	# silk-only pseudo-component with zero copper. It must survive as `pads: []`,
	# never decay into the absent-key (resolve-me-from-the-library) state.
	var logo = _PCBComponent.new()
	logo.load_from_board_dict({
		"ref": "LOGO_R12", "footprint": "Minerva_Fixture:LOGO_Owl",
		"x_mm": 46.0, "y_mm": 140.0, "pads": [],
		"graphics": [{"layer": "F.SilkS", "kind": "circle",
			"center": [0.0, 0.0], "radius": 2.0, "width": 0.15}]})
	var logo_board: Dictionary = logo.to_board_dict()
	check("graphics-only: an authored empty pads list round-trips as pads: []",
			logo_board.has("pads") and (logo_board["pads"] as Array).is_empty(),
			"got %s" % str(logo_board.get("pads", "<absent>")))
	var logo_restored = _PCBComponent.new()
	logo_restored.load_from_dict(logo.to_dict())
	var logo_again: Dictionary = logo_restored.to_board_dict()
	check("graphics-only: an undo snapshot keeps the explicit empty list",
			logo_again.has("pads") and (logo_again["pads"] as Array).is_empty(),
			"got %s" % str(logo_again.get("pads", "<absent>")))

	# (c) Real lands travel, unchanged — the part whose footprint no library
	# stocks and whose own list is therefore the only geometry anywhere.
	var inline_part = _PCBComponent.new()
	inline_part.load_from_board_dict({
		"ref": "U12A", "footprint": "Bench_Nowhere_1206",
		"x_mm": 22.0, "y_mm": 140.0,
		"pins": [{"number": "1", "x_mm": -1.5, "y_mm": 0.0}],
		"pads": [{"number": "1", "type": "smd", "shape": "rect",
			"position": {"x": -1.5, "y": 0.0},
			"size": {"width": 1.2, "height": 1.6},
			"layers": ["F.Cu", "F.Mask", "F.Paste"]}]})
	var inline_board: Dictionary = inline_part.to_board_dict()
	var inline_pads: Array = inline_board.get("pads", [])
	check("inline lands: the authored land survives to the board dict",
			inline_pads.size() == 1
			and str((inline_pads[0] as Dictionary).get("number", "")) == "1",
			"got %s" % str(inline_pads))
	check("inline lands: the land is stated as pad geometry",
			inline_part.has_pad_geometry)

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
## never let a post-clear mint reproduce an id that was on the board before it —
## a collision the very next time an entity from before the clear reappears (e.g.
## via undo), which is what test_trace_identity_delete.gd's group 14 exercises
## end to end via the real import->undo->mint path.
##
## STATED FOR MINTED IDS: a mint is a persistent "trace:<32hex>" / "via:<32hex>"
## token rather than an ordinal, so the property holds by CONSTRUCTION rather
## than by a counter. This test therefore asserts the property itself — the
## post-clear mint is a persistent id and is not the pre-clear handle — rather
## than predicting an ordinal.
## The legacy ordinal counters still exist for SUPPLIED ordinal ids, which is
## what the explicit high ids below still exercise on the way in.
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
	check("the post-clear trace mint is a persistent id, not a reused ordinal",
			PcbEntityId.is_minted("trace", str(minted_trace.id))
				and str(minted_trace.id) != "trace_100", "got %s" % minted_trace.id)

	var minted_via_id: String = data.add_via({"position": Vector2(9, 9), "net_name": "Y"})
	check("the post-clear via mint is a persistent id, not a reused ordinal",
			PcbEntityId.is_minted("via", minted_via_id) and minted_via_id != "via_50",
			"got %s" % minted_via_id)

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
	check("clear() leaves the trace mint persistent and collision-free too",
			PcbEntityId.is_minted("trace", str(minted_trace2.id))
				and str(minted_trace2.id) != "trace_200", "got %s" % minted_trace2.id)

	var minted_via_id2: String = data2.add_via({"position": Vector2(9, 9), "net_name": "Y"})
	check("clear() leaves the via mint persistent and collision-free too",
			PcbEntityId.is_minted("via", minted_via_id2) and minted_via_id2 != "via_80",
			"got %s" % minted_via_id2)


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


# ══════════════════════════════════════════════════════════════════════════════
# CAMPAIGN-2 BOUNDARY BLOCK — BT-08…11 (group lifecycle, round A4),
# BT-13…17 (zone edit, A5), BT-24…26 + 29 (trace width, A7).
#
# ORACLE RULE, from the rounds' own verbatim oracles: assert in the SERIALIZED
# representation, not in canvas state and not through the setter that just ran.
# "host_owned JSON alone is a weak oracle" (A4 oracle 1) — so group membership
# and offsets are read back out of to_board_dict()/from_board_dict(), and trace
# width is checked through the GEOMETRY functions rather than the width field.
#
# SHARED HELPERS: this file's journal-delta counter is _journal_len() below. The
# same idiom is implemented once more in test_pcb_panel_tools.gd (its own
# process, no common base to share from) and is needed a third time by the
# canvas suite's BT-52 — recorded in the boundary report rather than solved by a
# cross-fence edit.
# ══════════════════════════════════════════════════════════════════════════════

const BOUNDARY_TRACE_PATH := MODEL_DIR + "pcb_trace.gd"
const BOUNDARY_PREFS_PATH := MODEL_DIR + "pcb_prefs.gd"
const BOUNDARY_DATA_SRC := MODEL_DIR + "pcb_data.gd"
const BOUNDARY_PANEL_SRC := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"


## SECTION REGISTRY — the structural answer to the silent-abort trap.
##
## A GDScript runtime error aborts the whole enclosing FUNCTION, not the line.
## Every assertion after it simply never runs, and a suite that counts only
## PASS/FAIL reports a clean green while an entire oracle executed nothing. This
## file lost four oracles that way (BT-24/25/26/29) before the guard existed; the
## only reason it surfaced was a mutation that failed to go red.
##
## So each boundary section declares itself on entry, and a final guard — which
## runs in _init AFTER every section, so an abort inside one cannot skip it —
## proves each declared section actually produced assertions.
var _section_marks: Array = []


func _begin_section(label: String) -> void:
	_section_marks.append({"label": label, "at": _pass_count + _fail_count})


## Called LAST. Every declared section must have contributed at least one
## assertion, and the section after it must have started later than it did.
func _assert_every_section_ran() -> void:
	print("\n-- boundary block: every section actually ran --")
	var silent: Array = []
	for i in range(_section_marks.size()):
		var mark: Dictionary = _section_marks[i]
		var next_at: int = int(_section_marks[i + 1]["at"]) if i + 1 < _section_marks.size() \
				else _pass_count + _fail_count
		if next_at - int(mark["at"]) <= 0:
			silent.append(str(mark["label"]))
	check("no boundary section produced ZERO assertions (silent: %s)" % str(silent),
			silent.is_empty())
	check("all 12 boundary sections declared themselves (%d)" % _section_marks.size(),
			_section_marks.size() == 12)


func _journal_len(data) -> int:
	return data.change_journal.size()


func _history_len(data) -> int:
	for member in ["_history", "history", "_undo_stack"]:
		var v: Variant = data.get(member)
		if v is Array:
			return (v as Array).size()
	return -1


func _read_src(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var t := f.get_as_text()
	f.close()
	return t


## A two-part group on a blank board. Returns [data, group_id].
func _boundary_group_fixture() -> Array:
	var data = _PCBData.new(80.0, 60.0)
	for entry in [["A1", Vector2(10.0, 10.0)], ["A2", Vector2(20.0, 10.0)],
			["A3", Vector2(20.0, 20.0)]]:
		var comp = _PCBComponent.new()
		comp.id = str(entry[0])
		comp.position = entry[1]
		comp.rotation = 0.0
		comp.pins = {"1": Vector2(0.0, 0.0)}
		data.add_component(comp)
	var gid: String = data.group_components(["A1", "A2", "A3"])
	return [data, gid]


## Every component's serialized position, keyed by ref. The SERIALIZED dict, not
## the live objects — that is the whole discipline of this block.
func _serialized_positions(data) -> Dictionary:
	var out := {}
	for entry in data.to_board_dict().get("components", []):
		var e: Dictionary = entry
		out[str(e.get("ref", e.get("id", "")))] = Vector2(
				float(e.get("x_mm", 0.0)), float(e.get("y_mm", 0.0)))
	return out


func _serialized_rotations(data) -> Dictionary:
	var out := {}
	for entry in data.to_board_dict().get("components", []):
		var e: Dictionary = entry
		out[str(e.get("ref", e.get("id", "")))] = float(e.get("rotation_deg", 0.0))
	return out


# ── BT-08. Group membership survives the SERIALIZATION path ──────────────────

## A4 oracle (1): "serialization round-trip through the pcb.serialize YAML path —
## group membership+offsets asserted in the SERIALIZED representation, not via
## canvas code; host_owned JSON alone is a weak oracle."
##
## So: to_board_dict() -> from_board_dict() into a SECOND model -> read
## properties["group_id"] off the RELOADED components. The canvas is never
## touched, and neither is the group API that wrote the stamp — a stamp that
## lives only in memory (or only in the host_owned blob) reds here.
func _test_group_serialization_roundtrip() -> void:
	_begin_section("BT-08")
	print("\n-- BT-08: group membership survives to_board_dict -> from_board_dict --")
	var fixture := _boundary_group_fixture()
	var data = fixture[0]
	var gid: String = fixture[1]
	check("the fixture really is grouped", not gid.is_empty())

	var reloaded = _PCBData.new(80.0, 60.0)
	reloaded.from_board_dict(data.to_board_dict())

	var stamps := {}
	for cid in ["A1", "A2", "A3"]:
		var comp = reloaded.get_component(cid)
		stamps[cid] = "" if comp == null else str(
				comp.properties.get(_PCBComponent.GROUP_PROPERTY_KEY, ""))
	check("all three members carry a group stamp after the round trip (%s)" % str(stamps),
			not str(stamps["A1"]).is_empty()
			and not str(stamps["A2"]).is_empty()
			and not str(stamps["A3"]).is_empty())
	check("...and it is the SAME stamp for all three (a per-component id would "
			+ "round-trip too, and would not be a group)",
			stamps["A1"] == stamps["A2"] and stamps["A2"] == stamps["A3"])
	# The reloaded model must also AGREE through its own group reader — two
	# representations of one fact.
	check("the reloaded model reports the three as one group's members",
			reloaded.group_member_ids(str(stamps["A1"])).size() == 3)


# ── BT-09. A typed offset IS member.position − anchor.position ───────────────

## A4 oracle (2), asserted as ARITHMETIC ON THE SERIALIZED DICT: the difference
## between the member's and the anchor's serialized positions must equal the
## offset that was typed. A mutation that applies the offset to the ANCHOR
## instead flips the sign/target and reds here without any UI in the picture.
func _test_group_typed_offset_in_serialized_output() -> void:
	_begin_section("BT-09")
	print("\n-- BT-09: typed offset == member.position - anchor.position, in the serialized dict --")
	var fixture := _boundary_group_fixture()
	var data = fixture[0]
	var gid: String = fixture[1]
	var anchor_id: String = data.group_anchor_id(gid)
	var member_id := "A3" if anchor_id != "A3" else "A2"

	var typed := Vector2(7.5, -3.25)
	var moved: bool = data.set_member_offset(member_id, typed)
	check("set_member_offset reports it moved the member", moved)

	var positions := _serialized_positions(data)
	var difference: Vector2 = (positions[member_id] as Vector2) - (positions[anchor_id] as Vector2)
	check("serialized (member - anchor) == the typed offset (typed %s, got %s)"
			% [str(typed), str(difference)], difference.is_equal_approx(typed))
	# The anchor must NOT have moved: that is the half a "apply it to the anchor"
	# mutation gets wrong while the difference could still look plausible.
	check("the anchor stayed where it was (%s)" % str(positions[anchor_id]),
			(positions[anchor_id] as Vector2).is_equal_approx(Vector2(10.0, 10.0))
			or anchor_id != "A1")


# ── BT-10. Undo restores member positions from journal snapshots ─────────────

## A4 oracle (3), read from the SERIALIZED dict on both sides of the gesture, so
## "undo worked" means the document came back — not that some in-memory field
## was reassigned.
func _test_group_undo_restores_member_positions() -> void:
	_begin_section("BT-10")
	print("\n-- BT-10: undo restores every member's serialized position --")
	var fixture := _boundary_group_fixture()
	var data = fixture[0]
	data.save_to_history("Baseline")
	var before := _serialized_positions(data)

	data.translate_group("A1", Vector2(12.0, 8.0))
	data.save_to_history("Move group")
	var after := _serialized_positions(data)
	var any_moved := false
	for cid in before:
		if not (before[cid] as Vector2).is_equal_approx(after[cid] as Vector2):
			any_moved = true
	check("the gesture actually moved the group (fixture is not a no-op)", any_moved)

	check("undo() reports it did something", data.undo())
	var restored := _serialized_positions(data)
	var mismatched: Array = []
	for cid in before:
		if not restored.has(cid) or not (before[cid] as Vector2).is_equal_approx(
				restored[cid] as Vector2):
			mismatched.append(cid)
	check("every member's serialized position is back (mismatched: %s)"
			% str(mismatched), mismatched.is_empty())
	check("...and that is ALL THREE members, not just the anchor",
			restored.size() == 3)


# ── BT-11. The rigid-body invariant ─────────────────────────────────────────

## A4 oracle (4), and the round's own must_fix: "for ANY delta, all member bodies
## turn by the same quantized amount positions orbit by (deform-detection: assert
## body-delta == orbit-delta)".
##
## Two INDEPENDENTLY DERIVED quantities per member:
##   * the BODY delta — the change in the component's own serialized
##     rotation_deg;
##   * the ORBIT delta — the change in the angle of (member − anchor), measured
##     from the serialized positions.
## A rigid body turns both by the same amount. A rotation path that quantizes one
## and not the other deforms the group, which looks fine at 90 degrees and wrong
## at 45 — hence the sweep.
func _test_group_rotation_is_rigid() -> void:
	_begin_section("BT-11")
	print("\n-- BT-11: body rotation delta == orbit delta, for every member, at every angle --")
	for requested in [45.0, 17.0, 90.0, 180.0, -45.0]:
		var fixture := _boundary_group_fixture()
		var data = fixture[0]
		var gid: String = fixture[1]
		var anchor_id: String = data.group_anchor_id(gid)

		var pos_before := _serialized_positions(data)
		var rot_before := _serialized_rotations(data)
		var turned: Array = data.rotate_group("A1", requested)
		var pos_after := _serialized_positions(data)
		var rot_after := _serialized_rotations(data)

		# The model quantizes to the nearest quarter turn through ONE authority.
		var expected: float = _PCBComponent.snap_rotation(requested)
		if fposmod(expected, 360.0) == 0.0:
			check("%.0f deg quantizes to a no-op and turns nothing" % requested,
					turned.is_empty())
			continue

		var deformed: Array = []
		for member_id in ["A1", "A2", "A3"]:
			if member_id == anchor_id:
				continue
			var body_delta: float = fposmod(
					float(rot_after[member_id]) - float(rot_before[member_id]), 360.0)
			var before_vec: Vector2 = (pos_before[member_id] as Vector2) \
					- (pos_before[anchor_id] as Vector2)
			var after_vec: Vector2 = (pos_after[member_id] as Vector2) \
					- (pos_after[anchor_id] as Vector2)
			# Screen-space y is down, so a positive KiCad-sign body rotation
			# corresponds to a NEGATIVE angle sweep in this coordinate system —
			# the same -deg convention rotate_group itself applies. Compare the
			# magnitudes after normalising both into [0, 360).
			var orbit_delta: float = fposmod(
					rad_to_deg(before_vec.angle() - after_vec.angle()), 360.0)
			if absf(body_delta - orbit_delta) > 0.01:
				deformed.append("%s body=%.3f orbit=%.3f" % [member_id, body_delta, orbit_delta])
			# And the member must not have changed its DISTANCE from the anchor:
			# an orbit is a rotation, never a scale.
			if absf(before_vec.length() - after_vec.length()) > 1e-4:
				deformed.append("%s radius %.4f -> %.4f"
						% [member_id, before_vec.length(), after_vec.length()])
		check("%.0f deg (quantized %.0f): every member is rigid (%s)"
				% [requested, expected, str(deformed)], deformed.is_empty())


# ── BT-13/14/15. Zone outline edits: serialized outline + journal deltas ────

func _boundary_zone_fixture() -> Array:
	var data = _PCBData.new(80.0, 60.0)
	var net = _PCBNet.new()
	net.name = "ZN"
	data.add_net(net)
	var zone: Dictionary = data.create_zone("ZN", "top", PackedVector2Array([
			Vector2(5.0, 5.0), Vector2(25.0, 5.0), Vector2(25.0, 20.0),
			Vector2(5.0, 20.0)]), "copper_pour")
	return [data, str(zone.get("id", ""))]


func _serialized_outline(data, zone_id: String) -> Array:
	for entry in data.to_board_dict().get("zones", []):
		var e: Dictionary = entry
		if str(e.get("id", "")) == zone_id:
			var pts: Array = []
			for p in e.get("outline", e.get("points", [])):
				var pd: Dictionary = p
				pts.append(Vector2(float(pd.get("x_mm", pd.get("x", 0.0))),
						float(pd.get("y_mm", pd.get("y", 0.0)))))
			return pts
	return []


## A5 oracle (1): the serialized outline after an edit == the expected point
## list. Read out of to_board_dict, never from the zone dictionary the setter
## just wrote.
func _test_zone_edit_serialized_outline() -> void:
	_begin_section("BT-13")
	print("\n-- BT-13: the edited outline, read out of to_board_dict --")
	var fixture := _boundary_zone_fixture()
	var data = fixture[0]
	var zone_id: String = fixture[1]
	check("the fixture zone exists", not zone_id.is_empty())
	check("its serialized outline has the 4 authored points",
			_serialized_outline(data, zone_id).size() == 4)

	var replacement := PackedVector2Array([
			Vector2(6.0, 6.0), Vector2(26.0, 6.0), Vector2(26.0, 21.0)])
	check("set_zone_outline accepts a 3-point outline",
			data.set_zone_outline(zone_id, replacement))
	var serialized := _serialized_outline(data, zone_id)
	check("the serialized outline is now the 3 new points (got %d)" % serialized.size(),
			serialized.size() == 3)
	var wrong: Array = []
	for i in range(mini(serialized.size(), replacement.size())):
		if not (serialized[i] as Vector2).is_equal_approx(replacement[i]):
			wrong.append(i)
	check("...point for point (mismatched indices: %s)" % str(wrong), wrong.is_empty())


## A5 oracles (2) and (4): ONE history step per gesture, and a REFUSED gesture
## leaves the journal alone.
func _test_zone_edit_journal_deltas() -> void:
	_begin_section("BT-14/15")
	print("\n-- BT-14/15: one step per gesture; a refused gesture journals nothing --")
	var fixture := _boundary_zone_fixture()
	var data = fixture[0]
	var zone_id: String = fixture[1]

	var j0 := _journal_len(data)
	var h0 := _history_len(data)
	data.set_zone_outline(zone_id, PackedVector2Array([
			Vector2(1.0, 1.0), Vector2(9.0, 1.0), Vector2(9.0, 9.0)]))
	data.save_to_history("Edit zone outline")
	check("a committed outline edit is ONE history step (delta %d)"
			% (_history_len(data) - h0), _history_len(data) - h0 == 1)
	# MEASURED, and it is the documented contract rather than a gap:
	# set_zone_outline is a LIVE-DRAG WRITER — "silent about a real write, vocal
	# about a refusal" (pcb_data.gd's own doc) — because a vertex drag emits one
	# write per mouse motion and journalling each would bury the gesture. The
	# JOURNAL entry belongs to whoever ends the gesture: the canvas' drag-end
	# commit, or panel_tools._set_zone_outline (pinned in
	# test_pcb_panel_tools.gd's BT-73 leg). Pinned as +0 here so a future edit
	# that "fixes" the silence by journalling per motion reds at this layer.
	check("the model-layer write itself journals nothing (delta %d) — the "
			% (_journal_len(data) - j0)
			+ "gesture's owner writes the entry, not the setter",
			_journal_len(data) - j0 == 0)

	# THE REFUSAL. A 2-point outline is not an outline; the model must refuse it
	# and leave both counters exactly where they were.
	var j1 := _journal_len(data)
	var h1 := _history_len(data)
	var accepted: bool = data.set_zone_outline(zone_id, PackedVector2Array([
			Vector2(0.0, 0.0), Vector2(1.0, 1.0)]))
	check("a 2-point outline is REFUSED", not accepted)
	check("a refused gesture journals nothing (delta %d)"
			% (_journal_len(data) - j1), _journal_len(data) - j1 == 0)
	check("...and pushes no history step", _history_len(data) - h1 == 0)
	check("...and the zone still carries its previous 3 points",
			_serialized_outline(data, zone_id).size() == 3)


## A5 oracle (3): the refusal STRINGS are the model's own, compared to the
## authority that owns each rule. Two call sites, one source.
func _test_zone_refusals_are_the_models_own_strings() -> void:
	_begin_section("BT-16")
	print("\n-- BT-16: zone_net_error / zone_layer_error own their own wording --")
	var fixture := _boundary_zone_fixture()
	var data = fixture[0]

	var net_refusal := str(data.zone_net_error("NOPE", "copper_pour"))
	check("an undeclared net on a copper pour is refused (%s)" % net_refusal,
			not net_refusal.is_empty())
	# A KEEPOUT is the exemption — the decomposition's whole point. A mutation
	# that deletes the exemption reds here and nowhere else.
	check("...but a keepout may carry no net at all",
			str(data.zone_net_error("", "keepout")).is_empty())

	var layer_refusal := str(data.zone_layer_error("F.Cu"))
	check("an undeclared (KiCad-alias) layer is refused (%s)" % layer_refusal,
			not layer_refusal.is_empty())
	check("...and a declared canonical layer is accepted",
			str(data.zone_layer_error("top")).is_empty())

	# The COMPOSITE authority must AGREE with each half for the same input —
	# that is what keeps a doubly-stale zone independently repairable rather
	# than collapsing back into one zone_author_error.
	check("zone_author_error surfaces the NET half verbatim",
			str(data.zone_author_error("NOPE", "top", 4, "copper_pour")) == net_refusal)
	check("zone_author_error surfaces the LAYER half verbatim",
			str(data.zone_author_error("ZN", "F.Cu", 4, "copper_pour")) == layer_refusal)


## A5 oracle (5): outline, net and layer all survive the round trip.
func _test_zone_roundtrip_preserves_outline_net_layer() -> void:
	_begin_section("BT-17")
	print("\n-- BT-17: to_board_dict/from_board_dict preserves outline + net + layer --")
	var fixture := _boundary_zone_fixture()
	var data = fixture[0]
	var zone_id: String = fixture[1]
	data.set_zone_outline(zone_id, PackedVector2Array([
			Vector2(2.0, 2.0), Vector2(12.0, 2.0), Vector2(12.0, 12.0)]))

	var reloaded = _PCBData.new(80.0, 60.0)
	reloaded.from_board_dict(data.to_board_dict())
	var zone: Dictionary = reloaded.get_zone(zone_id)
	check("the zone survived the round trip under its own id", not zone.is_empty())
	check("its outline came back with 3 points",
			_serialized_outline(reloaded, zone_id).size() == 3)
	check("its net came back", str(zone.get("net", "")) == "ZN")
	check("its layer came back", str(zone.get("layer", "")) == "top")


# ── BT-24/25/26/29. Trace width ─────────────────────────────────────────────

func _boundary_trace_fixture() -> Array:
	var data = _PCBData.new(80.0, 60.0)
	var trace = _PCBTrace.new()
	trace.id = "TW1"
	trace.net_name = "N1"
	trace.layer = "top"
	trace.width = 0.25
	# waypoints is Array[Vector2], NOT PackedVector2Array. Assigning the wrong
	# packed type is a RUNTIME error that aborts the WHOLE test function and
	# silently drops every assertion after it — which is exactly what happened to
	# BT-24/25/26/29 in this file's first draft: four oracles ran nothing while
	# the suite reported 124 passed / 0 failed. See _assert_every_section_ran().
	var pts: Array[Vector2] = [Vector2(10.0, 10.0), Vector2(40.0, 10.0)]
	trace.waypoints = pts
	# add_trace() returns VOID and stamps the id onto the object, so there is no
	# return value to assert. Prove the fixture landed by COUNTING instead.
	var before: int = data.get_trace_count() if data.has_method("get_trace_count") \
			else data.traces.size()
	data.add_trace(trace)
	var after: int = data.get_trace_count() if data.has_method("get_trace_count") \
			else data.traces.size()
	check("trace fixture landed on the board (%d -> %d)" % [before, after],
			after == before + 1)
	return [data, "TW1"]


func _serialized_trace_width(data, trace_id: String) -> float:
	for entry in data.to_board_dict().get("traces", []):
		var e: Dictionary = entry
		if str(e.get("id", "")) == trace_id:
			if e.has("width_mm"):
				return float(e["width_mm"])
			return float(e.get("width", -1.0))
	return -1.0


## A7 oracle (1): the width round-trips through SERIALIZATION.
func _test_width_roundtrips_through_serialization() -> void:
	_begin_section("BT-24")
	print("\n-- BT-24: the set width appears in the serialized dict --")
	var fixture := _boundary_trace_fixture()
	var data = fixture[0]
	check_width_set(data, "TW1", 0.8)
	check("the serialized trace carries 0.8 (got %.3f)"
			% _serialized_trace_width(data, "TW1"),
			is_equal_approx(_serialized_trace_width(data, "TW1"), 0.8))
	# The DISCRIMINATING fixture for "serialize the preference instead of the
	# trace's own width": the value set here is deliberately NOT the model's
	# default, so the two cannot coincide.
	check("0.8 is not the model default (%.3f), so a default-echoing serializer "
			% float(_PCBTrace.DEFAULT_WIDTH_MM) + "cannot pass by coincidence",
			not is_equal_approx(0.8, float(_PCBTrace.DEFAULT_WIDTH_MM)))

	var reloaded = _PCBData.new(80.0, 60.0)
	reloaded.from_board_dict(data.to_board_dict())
	check("...and it survives the reload",
			is_equal_approx(_serialized_trace_width(reloaded, "TW1"), 0.8))


func check_width_set(data, trace_id: String, width: float) -> void:
	var refusal := str(data.set_trace_width(trace_id, width))
	check("set_trace_width(%.3f) accepted (%s)" % [width, refusal], refusal.is_empty())


## A7 oracle (2): journal +1 on a real change, +0 on a no-op.
func _test_width_journal_deltas() -> void:
	_begin_section("BT-25")
	print("\n-- BT-25: journal +1 per real width change, +0 per no-op --")
	var fixture := _boundary_trace_fixture()
	var data = fixture[0]

	var j0 := _journal_len(data)
	check_width_set(data, "TW1", 0.6)
	check("a real width change journals exactly one entry (delta %d)"
			% (_journal_len(data) - j0), _journal_len(data) - j0 == 1)

	var j1 := _journal_len(data)
	check_width_set(data, "TW1", 0.6)
	check("setting the SAME width journals nothing (delta %d)"
			% (_journal_len(data) - j1), _journal_len(data) - j1 == 0)

	# A REFUSED width journals nothing either, and leaves the copper alone.
	var j2 := _journal_len(data)
	var refusal := str(data.set_trace_width("TW1", 40.0))
	check("an out-of-range width is refused (%s)" % refusal, not refusal.is_empty())
	check("a refused width journals nothing", _journal_len(data) - j2 == 0)
	check("...and the serialized width is untouched",
			is_equal_approx(_serialized_trace_width(data, "TW1"), 0.6))


## A7 oracle (3): undo restores the width AND the GEOMETRY that depends on it.
##
## The width FIELD is deliberately never asserted here. get_bounding_rect() and
## is_point_near() are the functions every hit-test and every render actually
## consults; a restore that puts the number back while leaving a cached rect
## stale is a bug the field assertion cannot see.
func _test_width_undo_restores_geometry_not_just_the_field() -> void:
	_begin_section("BT-26")
	print("\n-- BT-26: undo restores bounding rect + hit radius, not just the number --")
	var fixture := _boundary_trace_fixture()
	var data = fixture[0]
	data.save_to_history("Baseline")

	var trace = data.get_trace("TW1")
	var rect_before: Rect2 = trace.get_bounding_rect()
	# A probe point just outside the NARROW trace's half-width, and inside the
	# WIDE one's. 10.0 + 0.25/2 = 10.125, so 10.4 is outside at 0.25 and inside
	# at 1.2 (half-width 0.6).
	var probe := Vector2(25.0, 10.4)
	check("the probe is OUTSIDE the narrow trace to begin with",
			not trace.is_point_near(probe, 0.0))

	check_width_set(data, "TW1", 1.2)
	data.save_to_history("Widen")
	var widened = data.get_trace("TW1")
	check("widening grew the bounding rect (%.3f -> %.3f tall)"
			% [rect_before.size.y, widened.get_bounding_rect().size.y],
			widened.get_bounding_rect().size.y > rect_before.size.y + 1e-6)
	check("...and the probe is now INSIDE it", widened.is_point_near(probe, 0.0))

	check("undo() reports it did something", data.undo())
	var restored = data.get_trace("TW1")
	check("the bounding rect is back to its pre-widen size (%.3f)"
			% restored.get_bounding_rect().size.y,
			is_equal_approx(restored.get_bounding_rect().size.y, rect_before.size.y))
	check("...and the hit radius is back too: the probe is outside again",
			not restored.is_point_near(probe, 0.0))


## A7 oracle (6): the bounds live in exactly ONE file, and the refusal text is
## width_error()'s own.
##
## The grep half is the durable one. A second hard-coded copy of 0.1/5.0/0.25
## anywhere else is how the spin box, the model setter and the preference
## registry start disagreeing — the reviewer grep-verified single-source at ship,
## and this makes that verification standing.
func _test_width_bounds_live_in_exactly_one_file() -> void:
	_begin_section("BT-29")
	print("\n-- BT-29: one bounds authority; refusal text is width_error's own --")
	var data = _boundary_trace_fixture()[0]
	for bad in [40.0, 0.0, -1.0]:
		var tool_text := str(data.set_trace_width("TW1", bad))
		var model_text := str(_PCBTrace.width_error(bad))
		check("width %.2f: the model refuses" % bad, not model_text.is_empty())
		check("width %.2f: set_trace_width's refusal is width_error's, verbatim "
				% bad + "(%s == %s)" % [tool_text, model_text], tool_text == model_text)

	# THE SINGLE-SOURCE GREP. Only pcb_trace.gd may DECLARE the numbers; every
	# other file must reach them through MIN_WIDTH_MM / MAX_WIDTH_MM /
	# DEFAULT_WIDTH_MM.
	#
	# VACUITY GUARD, and it is not decoration: the first draft of this check read
	# four files, silently got "" for one of them, and therefore PASSED under a
	# mutation that planted a second copy of the bounds in PCBPanel.gd. A source
	# scan whose corpus can quietly become empty is the purest form of
	# assert-on-nothing. Every file is now proved READ before it is scanned, and
	# the scan is proved to FIND something (pcb_trace.gd) before its absence
	# elsewhere is allowed to mean anything.
	var scanned := [BOUNDARY_TRACE_PATH, BOUNDARY_PREFS_PATH, BOUNDARY_DATA_SRC,
			BOUNDARY_PANEL_SRC]
	var declarers: Array = []
	var unread: Array = []
	var re := RegEx.new()
	re.compile("const\\s+(MIN_WIDTH_MM|MAX_WIDTH_MM|DEFAULT_WIDTH_MM)\\s*:=")
	for path in scanned:
		var src := _read_src(path)
		if src.length() < 200:
			unread.append("%s (%d bytes)" % [path, src.length()])
			continue
		if re.search(src) != null:
			declarers.append(str(path).get_file())
	check("every file in the scan corpus was actually READ (unread: %s)" % str(unread),
			unread.is_empty())
	check("the scan corpus is the four files that could hold a copy (%d)" % scanned.size(),
			scanned.size() == 4)
	check("the scan FINDS the real authority (positive control): %s" % str(declarers),
			declarers.has("pcb_trace.gd"))
	check("exactly ONE file declares the width bounds (%s)" % str(declarers),
			declarers.size() == 1 and declarers[0] == "pcb_trace.gd")


## Codex review 1086 finding 3: the canonical passthrough must ride EVERY
## component codec, not just the canonical pair.
##
## The epoch fixed to_board_dict/load_from_board_dict first and stopped there.
## But PCBData._serialize_components uses the LEGACY to_dict() for UNDO
## HISTORY, and history round-trips rebuild components through
## load_from_dict() — so after a canonical load, one undo silently erased
## `assembly: exclude`, `mpn`, and the pins' drill/annulus overrides, and the
## next promote wrote that loss into the design of record. duplicate_component
## had the same hole. This test walks all three doorways.
func _test_canonical_extras_survive_every_codec() -> void:
	var authored := {
		"ref": "TP1", "footprint": "Minerva_Fixture:TP_MinAnnular_0p6",
		"x_mm": 6.5, "y_mm": 2.8, "rotation_deg": 0.0, "layer": "top",
		"assembly": "exclude", "mpn": "TEST-MPN",
		"pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0,
				"drill_mm": 0.6, "annulus_diameter_mm": 0.96}],
	}
	var comp = _PCBComponent.new()
	comp.load_from_board_dict(authored)

	# 1. the canonical pair (already covered elsewhere, asserted here as the
	#    positive control so a failure below is unambiguous).
	var direct: Dictionary = comp.to_board_dict()
	check("canonical round trip keeps assembly",
			str(direct.get("assembly", "")) == "exclude")
	check("canonical round trip keeps mpn",
			str(direct.get("mpn", "")) == "TEST-MPN")
	check("canonical round trip keeps the pin drill override",
			float((direct["pins"] as Array)[0].get("drill_mm", 0.0)) == 0.6)

	# 2. THE UNDO DOORWAY: legacy to_dict -> load_from_dict -> canonical out.
	var snapshot: Dictionary = comp.to_dict()
	var restored = _PCBComponent.new()
	restored.load_from_dict(snapshot)
	var after_undo: Dictionary = restored.to_board_dict()
	check("UNDO round trip keeps assembly (was silently erased)",
			str(after_undo.get("assembly", "")) == "exclude")
	check("UNDO round trip keeps mpn",
			str(after_undo.get("mpn", "")) == "TEST-MPN")
	var undo_pin: Dictionary = (after_undo["pins"] as Array)[0]
	check("UNDO round trip keeps the pin drill override",
			float(undo_pin.get("drill_mm", 0.0)) == 0.6)
	check("UNDO round trip keeps the pin annulus override",
			float(undo_pin.get("annulus_diameter_mm", 0.0)) == 0.96)

	# 3. THE DUPLICATE DOORWAY: a copy that lost these would be a different part.
	var copied: Dictionary = comp.duplicate_component().to_board_dict()
	check("DUPLICATE keeps assembly",
			str(copied.get("assembly", "")) == "exclude")
	check("DUPLICATE keeps the pin drill override",
			float((copied["pins"] as Array)[0].get("drill_mm", 0.0)) == 0.6)

	# 4. A component with NO extras must stay clean — the passthrough must not
	#    invent keys, or every legacy board would gain phantom fields.
	var plain = _PCBComponent.new()
	plain.load_from_board_dict({
		"ref": "R1", "footprint": "R_0805", "x_mm": 1.0, "y_mm": 1.0,
		"rotation_deg": 0.0, "layer": "top",
		"pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}]})
	var plain_out: Dictionary = plain.to_board_dict()
	check("a component with no extras gains no phantom keys",
			not plain_out.has("assembly") and not plain_out.has("mpn"))
	check("a plain pin gains no phantom geometry",
			not (plain_out["pins"] as Array)[0].has("drill_mm"))


## Codex review 1090 finding 2: the CSV importer must not carry
## identity-bearing extras onto a part whose identity the CSV just changed.
##
## from_csv overwrites by id, and this CSV carries FOOTPRINT and VALUE — both
## identity. Carrying `mpn` / `assembly: exclude` / pin overrides across a
## value or footprint change would emit a BOM naming the wrong orderable part,
## or keep a now-assembly-worthy part excluded. Unchanged identity must still
## preserve them (that is the loss the codec sweep closed); changed identity
## must drop them AND say so.
func _test_csv_import_extras_follow_identity() -> void:
	var header := "id,footprint,value,x,y,rotation,layer\n"

	# --- identity UNCHANGED: the complete imported library geometry and extras
	# must survive. Rebuilding a blank component's standard pins is not a merge.
	var data = _PCBData.new()
	var keeper = _PCBComponent.new()
	keeper.load_from_board_dict({
		"ref": "J1", "footprint": "Minerva_Fixture:DAM_MinWeb_2P",
		"x_mm": 1.0, "y_mm": 1.0,
		"rotation_deg": 0.0, "layer": "top", "value": "10k",
		"mpn": "TEN-K-PN", "assembly": "exclude",
		"pins": [
			{"number": "1", "x_mm": 0.0, "y_mm": 0.0},
			{"number": "2", "x_mm": 2.54, "y_mm": 0.0,
				"drill_mm": 0.6, "annulus_diameter_mm": 1.4},
		]})
	keeper.pads = [{"number": "2", "position": Vector2(2.54, 0.0)}]
	keeper.graphics = [{"type": "line", "width": 0.2}]
	data.components["J1"] = keeper
	data.from_csv(header + "J1,Minerva_Fixture:DAM_MinWeb_2P,10k,5,5,0,top\n")
	var same_component = data.components["J1"]
	var same: Dictionary = same_component.to_board_dict()
	check("CSV with the SAME identity keeps mpn",
			str(same.get("mpn", "")) == "TEN-K-PN")
	check("CSV with the SAME identity keeps assembly",
			str(same.get("assembly", "")) == "exclude")
	check("CSV with the SAME library identity keeps both imported pins",
			(same.get("pins", []) as Array).size() == 2)
	check("CSV with the SAME library identity keeps pin 2 geometry",
			float((same["pins"] as Array)[1].get("drill_mm", 0.0)) == 0.6
			and float((same["pins"] as Array)[1].get("annulus_diameter_mm", 0.0)) == 1.4)
	check("CSV with the SAME library identity keeps render geometry",
			same_component.pads.size() == 1 and same_component.graphics.size() == 1)
	check("CSV with the SAME identity still applies the new placement",
			abs(float(same.get("x_mm", 0.0)) - 5.0) < 0.001)

	# CSV export must use the same canonical footprint identity as board export,
	# and a placement-only CSV must not imply a blank identity change.
	var exported: String = data.to_csv()
	check("CSV export emits the authored library footprint, not CUSTOM",
			exported.contains("Minerva_Fixture:DAM_MinWeb_2P"))
	var exported_import = _PCBData.new()
	exported_import.from_csv(exported)
	check("CSV export/import retains the authored library footprint",
			str(exported_import.components["J1"].to_board_dict().get(
					"footprint", "")) == "Minerva_Fixture:DAM_MinWeb_2P")
	data.from_csv("id,x,y\nJ1,7,8\n")
	var placement_only: Dictionary = data.components["J1"].to_board_dict()
	check("placement-only CSV retains the library footprint identity",
			str(placement_only.get("footprint", "")) \
					== "Minerva_Fixture:DAM_MinWeb_2P")
	check("placement-only CSV retains pins and identity extras",
			(placement_only.get("pins", []) as Array).size() == 2 \
					and str(placement_only.get("mpn", "")) == "TEN-K-PN")

	# --- identity CHANGED (value 10k -> 1k): extras must NOT migrate.
	var data2 = _PCBData.new()
	var changed = _PCBComponent.new()
	changed.load_from_board_dict({
		"ref": "R1", "footprint": "R_0805", "x_mm": 1.0, "y_mm": 1.0,
		"rotation_deg": 0.0, "layer": "top", "value": "10k",
		"mpn": "TEN-K-PN",
		"pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0, "drill_mm": 0.6}]})
	data2.components["R1"] = changed
	var import_result: Dictionary = data2.from_csv(
			header + "R1,R_0805,1k,5,5,0,top\n")
	var after: Dictionary = data2.components["R1"].to_board_dict()
	check("a CHANGED value does not carry the old mpn onto the new part",
			not after.has("mpn"))
	check("a CHANGED value does not carry the old pin overrides",
			not (after["pins"] as Array)[0].has("drill_mm"))
	check("the CSV's new value is what landed",
			str(after.get("value", "")) == "1k")
	var drops: Array = import_result.get("dropped_identity_extras", [])
	var drop: Dictionary = drops[0] if not drops.is_empty() else {}
	check("identity-extra report names the affected component and field",
			str(drop.get("ref", "")) == "R1" \
					and (drop.get("identity_fields", []) as Array).has("value"))
	check("identity-extra report names discarded canonical keys",
			(drop.get("canonical_extra_keys", []) as Array).has("mpn"))
	var reported_pin_keys: Dictionary = drop.get("pin_extra_keys", {})
	check("identity-extra report names discarded per-pin keys",
			(reported_pin_keys.get("1", []) as Array).has("drill_mm"))

	# --- and the drop is REPORTED, never silent.
	var journal: Array = data2.get_change_journal() if data2.has_method("get_change_journal") else []
	var reported := false
	for entry in journal:
		if entry is Dictionary and str(entry.get("action", "")).find("import_csv") >= 0:
			var payload = entry.get("payload", entry)
			if str(payload).find("dropped_identity_extras") >= 0 \
					or str(entry).find("dropped_identity_extras") >= 0:
				reported = true
	check("the dropped extras are reported on the journal record, not silent",
			reported)
