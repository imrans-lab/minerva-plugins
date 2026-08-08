extends SceneTree
## The CANVAS bus tool (ToolMode.BUS, S3 picker + S4 armed tool) — campaign 2
## epoch C, unit 5, DCR 019fb572b888.
##
## UN-PARKED at the epoch-C boundary (Station 1, un-park + execute): moved
## from pcb/tests/pending/ into pcb/tests/gd/ and added to EXPECTED_SUITES —
## it now runs as part of the normal run-gd-tests.sh sweep.
##
## Run:
##   godot --headless --path src --script ../../minerva-plugins/pcb/tests/gd/test_bus_tool.gd
##
## STYLE NOTE: this suite follows test_pcb_trace_tool.gd's LIGHT rig (a bare
## pcb_canvas.gd instance + a StubPadHost + direct calls into the tool's own
## methods), not test_pcb_canvas_input_probe.gd's heavy armed-mount/Window
## recipe — BT-93 (the trace tool, the closest precedent for a brand-new
## canvas draw tool) is the closer analog: the bus tool, like the trace tool,
## owns its click outright and needs no annotation-overlay/universal-select
## machinery to exercise. "Esc/disarm grammar" below borrows the input
## probe's ARMED/DISARM vocabulary, not its mount.
##
## WHAT IS PINNED, per the C5 brief's six requested groups:
##   1. S3 picker order semantics (T11 — caller's order) + remove-by-reclick
##   2. mixed-width 3-net offsets, reusing test_pcb_bus_geometry.gd's OWN
##      pinned numbers ([1.0, 0.2, 0.2] @ 0.2 -> [-0.6, +0.2, +0.6]) rather
##      than re-deriving the geometry
##   3. the INNER-FOLD GUARD refusal (pcb_bus_geometry.gd:78-82's documented
##      gap, assigned to this tool layer) — 3 WIDE nets, hand-derived offset
##   4. single-journal-step undo (one save_to_history for the whole bus)
##   5. MCP parity: minerva_pcb_route_bus_direct vs the canvas gesture, on the
##      SAME input, via the shared panel_tools.bus_plan/bus_commit_plan core
##   6. the Esc/right-click TWO-STEP ladder + the full-reset re-click disarm
## Plus two structural pins the brief's traps name directly: the ToolMode
## enum's append-only position, and the _zone_vertex_edit_active() exclusion
## (the B4-U3/F1 class bug CUTOUT already fixed once, BUS repeats the fix
## for). Plus two REGRESSION pins added at cold review (N5): a physical
## double-click during PICKING must pick exactly once, not re-toggle the net
## off (a real bug found and fixed this round); and the inner-fold guard
## refusal is independently pinned on the MCP path (minerva_pcb_route_bus_
## direct), not only proved by the gesture-side test's shared-function
## construction.
##
## INDEPENDENT REPRESENTATION, throughout: the SERIALIZED trace entities
## (data.to_board_dict()'s "traces") and data.history — never the tool's own
## _bus_nets/_bus_spine_points buffers, which are the thing under test.

const PCBData := preload("res://../../minerva-plugins/pcb/ui/model/pcb_data.gd")
const PcbCanvasScript := preload("res://../../minerva-plugins/pcb/ui/pcb_canvas.gd")
const PanelToolsScript := preload("res://../../minerva-plugins/pcb/ui/panel_tools.gd")

var _pass := 0
var _fail := 0


## The pad oracle the tool asks for pads. Mirrors test_pcb_trace_tool.gd's own
## StubPadHost verbatim (each parked/light suite owns its copy — this is a
## private test double, not shared production code).
class StubPadHost extends RefCounted:
	var pads: Array = []   # [{component, pin, position}]
	func pad_at(world_pos: Vector2, radius: float, _filter: Variant = null) -> Dictionary:
		var best: Dictionary = {}
		var best_d := INF
		for p in pads:
			var d: float = (p["position"] as Vector2).distance_to(world_pos)
			if d <= radius and d < best_d:
				best_d = d
				best = p
		return best


## Minimal host for panel_tools.handle() — the ONLY duck-typed method the
## dispatch path needs (see panel_tools.gd's _get_data): get_board_data().
class StubMcpHost extends RefCounted:
	var data
	func get_board_data():
		return data


func _init() -> void:
	print("=== PCB canvas BUS tool (C5, DCR 019fb572b888 S3+S4) ===\n")
	_test_tool_mode_enum_position()
	_test_zone_vertex_edit_exclusion()
	_test_picker_order_and_remove_by_reclick()
	_test_double_click_does_not_retoggle_during_picking()
	_test_mixed_width_offsets_reusing_geometry_pins()
	_test_inner_fold_refusal_three_wide_nets()
	_test_propose_doorway_teach_line()
	# AWAITED (unlike every synchronous test above): both call
	# panel_tools.handle(), a coroutine end to end (see panel_tools.gd's own
	# class-doc note) because it awaits internally on other branches. A bare
	# call without await here would still COMPILE, but the test's own
	# post-await assertions would resume on some later, unscheduled tick —
	# possibly after this _init() has already printed Results and quit() —
	# and silently not count. Mirrors test_pcb_panel_tools.gd's own _init(),
	# which awaits every helper that touches handle_tool/handle for the same
	# reason.
	await _test_mcp_parity()
	await _test_mcp_inner_fold_refusal()
	_test_esc_ladder_and_reclick_disarm()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func check(desc: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		if detail.is_empty():
			printerr("  FAIL: %s" % desc)
		else:
			printerr("  FAIL: %s — %s" % [desc, detail])


## Six single-pin components (U1..U6), each its own single-pin net (N1..N6),
## on a 2-layer board. clearance_mm 0.2 matches test_pcb_bus_geometry.gd's own
## pinned clearance throughout, so the mixed/wide-net groups below can reuse
## its exact numbers without re-deriving anything.
func _board() -> Dictionary:
	return {
		"version": 1, "name": "BusBoard", "width_mm": 80.0, "height_mm": 60.0,
		"grid_mm": 2.54,
		"layers": ["top", "bottom"],
		"design_rules": {"clearance_mm": 0.2},
		"components": [
			{"ref": "U1", "footprint": "IC_DIP", "x_mm": 10.0, "y_mm": 10.0,
				"rotation_deg": 0.0, "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}]},
			{"ref": "U2", "footprint": "IC_DIP", "x_mm": 20.0, "y_mm": 10.0,
				"rotation_deg": 0.0, "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}]},
			{"ref": "U3", "footprint": "IC_DIP", "x_mm": 30.0, "y_mm": 10.0,
				"rotation_deg": 0.0, "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}]},
			{"ref": "U4", "footprint": "IC_DIP", "x_mm": 10.0, "y_mm": 20.0,
				"rotation_deg": 0.0, "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}]},
			{"ref": "U5", "footprint": "IC_DIP", "x_mm": 20.0, "y_mm": 20.0,
				"rotation_deg": 0.0, "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}]},
			{"ref": "U6", "footprint": "IC_DIP", "x_mm": 30.0, "y_mm": 20.0,
				"rotation_deg": 0.0, "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}]},
		],
		"nets": [
			{"name": "N1", "pins": ["U1.1"]},
			{"name": "N2", "pins": ["U2.1"]},
			{"name": "N3", "pins": ["U3.1"]},
			{"name": "N4", "pins": ["U4.1"]},
			{"name": "N5", "pins": ["U5.1"]},
			{"name": "N6", "pins": ["U6.1"]},
		],
	}


## Fresh canvas + data + stub pad host, armed to BUS. Mirrors test_pcb_trace_
## tool.gd's own _rig(): snap disabled so authored points land exactly where
## clicked, matching the hand-derived numbers below to the bit.
func _rig() -> Array:
	var canvas = PcbCanvasScript.new()
	var data = PCBData.new()
	data.from_board_dict(_board())
	canvas.data = data
	canvas.zoom = 8.0
	canvas.snap_to_grid = false
	var host := StubPadHost.new()
	host.pads = [
		{"component": "U1", "pin": "1", "position": Vector2(10.0, 10.0)},
		{"component": "U2", "pin": "1", "position": Vector2(20.0, 10.0)},
		{"component": "U3", "pin": "1", "position": Vector2(30.0, 10.0)},
		{"component": "U4", "pin": "1", "position": Vector2(10.0, 20.0)},
		{"component": "U5", "pin": "1", "position": Vector2(20.0, 20.0)},
		{"component": "U6", "pin": "1", "position": Vector2(30.0, 20.0)},
	]
	canvas.set_pin_inspector_host(host)
	canvas.set_tool_mode(canvas.ToolMode.BUS)
	return [canvas, data, host]


func _serialized_traces(data) -> Array:
	return (data.to_board_dict().get("traces", []) as Array)


## Pre-author one existing trace per net, at the given width, so
## _bus_net_width (delegating to panel_tools.bus_net_width) resolves that
## width for a NEW bus joining the net — the documented "widest existing
## trace on the net" rule. Placed well away from the pick pads / spine so it
## cannot be hit-tested by either.
func _seed_widths(data, nets: Array, widths: Array) -> void:
	for i in range(nets.size()):
		var y := 50.0 + float(i) * 2.0
		data.create_trace_entity(str(nets[i]), "top",
			[Vector2(50.0, y), Vector2(60.0, y)], float(widths[i]))


# ── 0. STRUCTURAL PINS (the brief's own named traps) ──────────────────────────

func _test_tool_mode_enum_position() -> void:
	print("-- structural: ToolMode.BUS is APPENDED, not inserted --")
	var canvas = PcbCanvasScript.new()
	check("BUS == 11 (append-only enum; CUTOUT stays 10, ERASER stays 9 — "
			+ "PCBPanel's raw-int status tables were bumped alongside this)",
			canvas.ToolMode.BUS == 11, "got %d" % canvas.ToolMode.BUS)
	check("CUTOUT unchanged at 10", canvas.ToolMode.CUTOUT == 10)
	canvas.free()


func _test_zone_vertex_edit_exclusion() -> void:
	print("-- structural: BUS is excluded from _zone_vertex_edit_active (B4-U3/F1 class) --")
	var rig := _rig()
	var canvas = rig[0]
	check("with BUS armed, _zone_vertex_edit_active() is false — a zone vertex "
			+ "handle must not draw/hit-resolve while the bus tool owns the click "
			+ "(the exact bug class CUTOUT's own fix records)",
			not canvas._zone_vertex_edit_active())
	canvas.free()


# ── 1. S3 PICKER: ORDER + REMOVE-BY-RECLICK ───────────────────────────────────

func _test_picker_order_and_remove_by_reclick() -> void:
	print("\n-- S3 (1): picker order is the CLICK order (T11), and a re-click removes --")
	var rig := _rig()
	var canvas = rig[0]
	var msgs: Array = []
	canvas.bus_tool_message.connect(func(t: String) -> void: msgs.append(t))

	canvas._handle_bus_click(Vector2(10.0, 10.0), false)   # N1
	canvas._handle_bus_click(Vector2(20.0, 10.0), false)   # N2
	canvas._handle_bus_click(Vector2(30.0, 10.0), false)   # N3
	check("picked in click order: [N1, N2, N3]",
			canvas._bus_nets == (["N1", "N2", "N3"] as Array[String]),
			"got %s" % str(canvas._bus_nets))
	check("the last message names all three and the count",
			msgs[msgs.size() - 1].contains("N1") and msgs[msgs.size() - 1].contains("N2")
				and msgs[msgs.size() - 1].contains("N3") and msgs[msgs.size() - 1].contains("3 picked"),
			str(msgs[msgs.size() - 1]))

	# Re-click an ALREADY-LISTED net's pad removes it (S3's own contract).
	canvas._handle_bus_click(Vector2(20.0, 10.0), false)   # N2 again
	check("re-clicking N2's pad removes it: [N1, N3]",
			canvas._bus_nets == (["N1", "N3"] as Array[String]),
			"got %s" % str(canvas._bus_nets))
	check("the removal message says so", msgs[msgs.size() - 1].contains("Removed N2"),
			str(msgs[msgs.size() - 1]))

	# Re-adding N2 appends at the END (click order, not the original slot) —
	# proves order is truly re-authored by the picker, not restored from a
	# remembered position.
	canvas._handle_bus_click(Vector2(20.0, 10.0), false)   # N2 a third time
	check("re-adding N2 appends at the end: [N1, N3, N2]",
			canvas._bus_nets == (["N1", "N3", "N2"] as Array[String]),
			"got %s" % str(canvas._bus_nets))

	# A pad on no net, and empty space, both refuse without mutating the list.
	var before: Array = canvas._bus_nets.duplicate()
	canvas._handle_bus_click(Vector2(70.0, 55.0), false)   # empty board
	check("a click on empty space picks nothing",
			canvas._bus_nets == before, "got %s" % str(canvas._bus_nets))
	check("…and says why", msgs[msgs.size() - 1].contains("pad") and msgs[msgs.size() - 1].contains("trace"),
			str(msgs[msgs.size() - 1]))

	canvas.free()


## 1b. REGRESSION PIN (cold review N5): a physical double-click during PICKING
## must not re-toggle the net it picked. Godot delivers a double-click as TWO
## separate press events — the first (double_click=false) already performs
## the pick; without _handle_bus_click's own guard, the second
## (double_click=true) would fall through into _handle_bus_pick_click AGAIN
## and immediately remove the SAME net (S3's re-click-removes rule), netting
## a double-click on a pad to "nothing picked" on what looked like one click.
func _test_double_click_does_not_retoggle_during_picking() -> void:
	print("\n-- S3 (1b, regression): a double-click on a pad during PICKING picks ONCE --")
	var rig := _rig()
	var canvas = rig[0]

	# The two-event sequence a REAL physical double-click produces.
	canvas._handle_bus_click(Vector2(10.0, 10.0), false)   # press 1: picks N1
	canvas._handle_bus_click(Vector2(10.0, 10.0), true)    # press 2: double_click=true
	check("N1 is picked exactly once, not toggled back off by the second press",
			canvas._bus_nets == (["N1"] as Array[String]),
			"got %s" % str(canvas._bus_nets))

	# A GENUINE second, separate click (not a double-click event) on the same
	# pad is still the documented remove-by-reclick — the guard above must not
	# have swallowed that grammar too.
	canvas._handle_bus_click(Vector2(10.0, 10.0), false)
	check("…but a real second single-click on the same pad still removes it",
			canvas._bus_nets.is_empty(), "got %s" % str(canvas._bus_nets))

	canvas.free()


# ── 2. MIXED-WIDTH 3-NET OFFSETS — reusing test_pcb_bus_geometry.gd's OWN pin ──

func _test_mixed_width_offsets_reusing_geometry_pins() -> void:
	print("\n-- S4 (2): mixed-width 3-net offsets, straight spine (translate-only) --")
	# PINNED ELSEWHERE, reused verbatim (test_pcb_bus_geometry.gd
	# _run_cumulative_offsets, "MIXED" block): cumulative_offsets([1.0, 0.2,
	# 0.2], 0.2) == [-0.6, +0.2, +0.6]. Not re-derived here — only consumed.
	var rig := _rig()
	var canvas = rig[0]
	var data = rig[1]
	_seed_widths(data, ["N1", "N2", "N3"], [1.0, 0.2, 0.2])

	canvas._handle_bus_click(Vector2(10.0, 10.0), false)   # N1 (1.0mm)
	canvas._handle_bus_click(Vector2(20.0, 10.0), false)   # N2 (0.2mm)
	canvas._handle_bus_click(Vector2(30.0, 10.0), false)   # N3 (0.2mm)
	canvas._start_bus_draw()
	check("draw phase armed", canvas._bus_drawing)

	# STRAIGHT spine (0,0)->(10,0): d=(1,0), n=(-d.y,d.x)=(0,1) — a PLAIN
	# perpendicular translate (offset_polyline's own documented "exactly 2
	# distinct points" case), so a track at offset `o` is simply y=o along the
	# whole spine. No miter math is exercised or re-derived here.
	canvas._handle_bus_click(Vector2(0.0, 0.0), false)
	canvas._handle_bus_click(Vector2(10.0, 0.0), false)
	canvas._commit_bus()

	var traces := _serialized_traces(data)
	check("3 new traces landed (seed traces at y=50/52/54 are also present, so 6 total)",
			traces.size() == 6, "got %d" % traces.size())

	var by_net := {}
	for t in traces:
		var pts: Array = t.get("points", [])
		# Only the newly-committed bus traces run through (0,0)/(10,0) — the
		# seeded width traces sit at y>=50 and are excluded here so each net
		# maps to exactly the trace this test cares about.
		if pts.size() == 2 and float(pts[0].get("y_mm", pts[0].get("y", 999.0))) < 10.0:
			by_net[str(t.get("net", ""))] = t

	check("all three bus nets landed", by_net.size() == 3, "got %s" % str(by_net.keys()))
	var expect := {"N1": -0.6, "N2": 0.2, "N3": 0.6}
	var expect_width := {"N1": 1.0, "N2": 0.2, "N3": 0.2}
	for net in expect.keys():
		if not by_net.has(net):
			check("bus trace for %s exists" % net, false)
			continue
		var t: Dictionary = by_net[net]
		var pts: Array = t.get("points", [])
		var y0 := float(pts[0].get("y_mm", pts[0].get("y", 0.0)))
		var y1 := float(pts[1].get("y_mm", pts[1].get("y", 0.0)))
		check("%s track sits at y=%.3f (both points)" % [net, float(expect[net])],
				is_equal_approx(y0, float(expect[net])) and is_equal_approx(y1, float(expect[net])),
				"got y0=%.4f y1=%.4f want %.4f" % [y0, y1, float(expect[net])])
		check("%s keeps its seeded width %.2f" % [net, float(expect_width[net])],
				is_equal_approx(float(t.get("width_mm", t.get("width", 0.0))), float(expect_width[net])),
				"got %s" % str(t.get("width_mm", t.get("width", 0.0))))

	canvas.free()


# ── 3. INNER-FOLD GUARD — 3 WIDE nets, a short segment, hand-derived offset ────

func _test_inner_fold_refusal_three_wide_nets() -> void:
	print("\n-- S4 (3): the inner-fold guard refuses a segment shorter than the widest offset --")
	# HAND-DERIVED (uniform, translate-only spine — the same simple formula
	# test_pcb_bus_geometry.gd's own "uniform trio" pins, at a different
	# width so the class read as genuinely WIDE nets):
	#   pitch_between(2.0, 2.0, 0.2) = 1.0 + 0.2 + 1.0 = 2.2
	#   cumulative_offsets([2.0, 2.0, 2.0], 0.2): positions [0, 2.2, 4.4],
	#   centre 2.2 -> [-2.2, 0.0, +2.2]. max|offset| = 2.2.
	var rig := _rig()
	var canvas = rig[0]
	var data = rig[1]
	_seed_widths(data, ["N1", "N2", "N3"], [2.0, 2.0, 2.0])

	canvas._handle_bus_click(Vector2(10.0, 10.0), false)   # N1
	canvas._handle_bus_click(Vector2(20.0, 10.0), false)   # N2
	canvas._handle_bus_click(Vector2(30.0, 10.0), false)   # N3
	canvas._start_bus_draw()

	# Spine (0,0)->(10,0)->(10,1.0): segment 1->2 has length 1.000mm, which is
	# SHORTER than the widest offset 2.200mm — the inner track (at -2.2 or
	# +2.2) would fold back on itself on that segment.
	canvas._handle_bus_click(Vector2(0.0, 0.0), false)
	canvas._handle_bus_click(Vector2(10.0, 0.0), false)
	canvas._handle_bus_click(Vector2(10.0, 1.0), false)
	check("3 spine points placed", canvas._bus_spine_points.size() == 3,
			"got %d" % canvas._bus_spine_points.size())

	var msgs: Array = []
	canvas.bus_tool_message.connect(func(t: String) -> void: msgs.append(t))
	var traces_before := _serialized_traces(data).size()
	canvas._commit_bus()

	check("commit was refused — no new traces landed",
			_serialized_traces(data).size() == traces_before,
			"before=%d after=%d" % [traces_before, _serialized_traces(data).size()])
	check("still drawing — the spine is KEPT, not thrown away (another click/wider "
			+ "corner is the fix, not a redraw from scratch)",
			canvas._bus_drawing and canvas._bus_spine_points.size() == 3)
	check("the refusal NAMES the segment (1→2) and the offending offset (2.200mm)",
			not msgs.is_empty() and msgs[msgs.size() - 1].contains("segment 1")
				and msgs[msgs.size() - 1].contains("2.200")
				and msgs[msgs.size() - 1].contains("1.000")
				and msgs[msgs.size() - 1].contains("fold"),
			str(msgs[msgs.size() - 1]) if not msgs.is_empty() else "(no message)")

	canvas.free()


## 3b. REGRESSION PIN (cold review N5): the inner-fold guard is inside
## panel_tools.bus_plan, the ONE shared implementation — but the gesture path
## above only PROVES that by construction, not by an independent exercise of
## the MCP call. This pins the MCP side directly: if the guard were ever
## bypassed on that path alone (e.g. a future edit routes
## minerva_pcb_route_bus_direct around bus_plan), this test reds
## independently of the gesture test above. SAME hand-derived numbers as
## group 3 (3x2.0mm @ 0.2mm clearance -> offsets [-2.2, 0, 2.2], the short
## segment 1->2 at 1.000mm) — reused, not re-derived.
func _test_mcp_inner_fold_refusal() -> void:
	print("\n-- (3b, regression) MCP-side inner-fold refusal, independent of the gesture --")
	var data := PCBData.new()
	data.from_board_dict(_board())
	_seed_widths(data, ["N1", "N2", "N3"], [2.0, 2.0, 2.0])
	var host := StubMcpHost.new()
	host.data = data

	var args := {
		"editor_name": "PCB1",
		"nets": ["N1", "N2", "N3"],
		"points": [{"x_mm": 0.0, "y_mm": 0.0}, {"x_mm": 10.0, "y_mm": 0.0}, {"x_mm": 10.0, "y_mm": 1.0}],
		"layer": "top",
	}
	var traces_before := _serialized_traces(data).size()
	var result: Dictionary = await PanelToolsScript.handle(host, "minerva_pcb_route_bus_direct", args)

	check("the MCP call itself reports failure",
			not bool(result.get("success", true)), str(result))
	check("the error NAMES the segment (1→2) and the offending offset (2.200mm), "
			+ "the SAME wording the gesture's refusal carries",
			str(result.get("error", "")).contains("segment 1")
				and str(result.get("error", "")).contains("2.200")
				and str(result.get("error", "")).contains("1.000")
				and str(result.get("error", "")).contains("fold"),
			str(result.get("error", "")))
	check("no trace was created via the MCP path either",
			_serialized_traces(data).size() == traces_before,
			"before=%d after=%d" % [traces_before, _serialized_traces(data).size()])


# ── 4. SINGLE-JOURNAL-STEP UNDO ────────────────────────────────────────────────

func _test_single_journal_step_undo() -> void:
	print("\n-- S4 (4): the whole bus is ONE undo step (journal delta 1) --")
	var rig := _rig()
	var canvas = rig[0]
	var data = rig[1]

	canvas._handle_bus_click(Vector2(10.0, 10.0), false)   # N1
	canvas._handle_bus_click(Vector2(20.0, 10.0), false)   # N2
	canvas._handle_bus_click(Vector2(30.0, 10.0), false)   # N3
	canvas._start_bus_draw()
	canvas._handle_bus_click(Vector2(0.0, 0.0), false)
	canvas._handle_bus_click(Vector2(10.0, 0.0), false)

	var traces_before: int = data.get_trace_count()
	var history_before: int = data.history.size()
	canvas._commit_bus()

	check("3 traces landed (one per net)", data.get_trace_count() == traces_before + 3,
			"before=%d after=%d" % [traces_before, data.get_trace_count()])
	check("history grew by EXACTLY ONE step for the whole bus (journal delta 1)",
			data.history.size() == history_before + 1,
			"before=%d after=%d" % [history_before, data.history.size()])
	check("the tool disarmed its draw state after commit",
			not canvas._bus_drawing and canvas._bus_nets.is_empty())

	check("undo() removes ALL 3 traces together", data.undo(),
			"undo() returned false")
	check("trace count is back to the pre-bus count",
			data.get_trace_count() == traces_before,
			"got %d want %d" % [data.get_trace_count(), traces_before])

	canvas.free()


# ── 5. MCP PARITY: minerva_pcb_route_bus_direct == the canvas gesture ─────────

func _test_mcp_parity() -> void:
	print("\n-- (5) MCP parity: minerva_pcb_route_bus_direct == the canvas gesture on the same input --")
	# Board A: driven through the canvas gesture.
	var rig_a := _rig()
	var canvas_a = rig_a[0]
	var data_a = rig_a[1]
	canvas_a._handle_bus_click(Vector2(10.0, 10.0), false)   # N1
	canvas_a._handle_bus_click(Vector2(20.0, 10.0), false)   # N2
	canvas_a._handle_bus_click(Vector2(30.0, 10.0), false)   # N3
	canvas_a._start_bus_draw()
	canvas_a._handle_bus_click(Vector2(0.0, 0.0), false)
	canvas_a._handle_bus_click(Vector2(10.0, 0.0), false)
	canvas_a._commit_bus()
	var traces_a := _serialized_traces(data_a)

	# Board B: IDENTICAL fixture, driven through the MCP tool with the SAME
	# ordered net list, the SAME spine, and the SAME layer the canvas gesture
	# resolved to (trace_author_layer() on this rig's "all" filter -> "top",
	# TRACE_DEFAULT_LAYER — named explicitly here since an MCP call has no
	# toolbar to fall back on).
	var data_b := PCBData.new()
	data_b.from_board_dict(_board())
	var host_b := StubMcpHost.new()
	host_b.data = data_b
	var args := {
		"editor_name": "PCB1",
		"nets": ["N1", "N2", "N3"],
		"points": [{"x_mm": 0.0, "y_mm": 0.0}, {"x_mm": 10.0, "y_mm": 0.0}],
		"layer": "top",
	}
	var result: Dictionary = await PanelToolsScript.handle(host_b, "minerva_pcb_route_bus_direct", args)
	check("the MCP call succeeded", bool(result.get("success", false)), str(result))
	check("it reports 3 trace ids", (result.get("trace_ids", []) as Array).size() == 3,
			str(result.get("trace_ids", [])))
	var traces_b := _serialized_traces(data_b)

	check("both boards ended with the same trace COUNT",
			traces_a.size() == traces_b.size(),
			"gesture=%d tool=%d" % [traces_a.size(), traces_b.size()])

	# Compare by net (order-independent id-wise, but T11 is separately pinned
	# in group 1 above — this check is about GEOMETRY parity, not order).
	var by_net_a := {}
	for t in traces_a:
		by_net_a[str(t.get("net", ""))] = t
	var by_net_b := {}
	for t in traces_b:
		by_net_b[str(t.get("net", ""))] = t
	for net in ["N1", "N2", "N3"]:
		check("%s exists on both boards" % net,
				by_net_a.has(net) and by_net_b.has(net))
		if not (by_net_a.has(net) and by_net_b.has(net)):
			continue
		var wa := float(by_net_a[net].get("width_mm", by_net_a[net].get("width", 0.0)))
		var wb := float(by_net_b[net].get("width_mm", by_net_b[net].get("width", 0.0)))
		check("%s: same width (gesture=%.4f tool=%.4f)" % [net, wa, wb],
				is_equal_approx(wa, wb))
		var pa: Array = by_net_a[net].get("points", [])
		var pb: Array = by_net_b[net].get("points", [])
		check("%s: same point count" % net, pa.size() == pb.size(),
				"gesture=%d tool=%d" % [pa.size(), pb.size()])
		if pa.size() == pb.size():
			for i in range(pa.size()):
				var xa := float(pa[i].get("x_mm", pa[i].get("x", 0.0)))
				var ya := float(pa[i].get("y_mm", pa[i].get("y", 0.0)))
				var xb := float(pb[i].get("x_mm", pb[i].get("x", 0.0)))
				var yb := float(pb[i].get("y_mm", pb[i].get("y", 0.0)))
				check("%s point %d matches (gesture=(%.3f,%.3f) tool=(%.3f,%.3f))"
						% [net, i, xa, ya, xb, yb],
						is_equal_approx(xa, xb) and is_equal_approx(ya, yb))

	# Undo parity too: both are one journal step.
	check("board A: one undo removes its whole bus", data_a.undo() and data_a.get_trace_count() == 0)
	check("board B: one undo removes its whole bus", data_b.undo() and data_b.get_trace_count() == 0)

	canvas_a.free()


# ── 6. ESC/RIGHT-CLICK LADDER + FULL-RESET RE-CLICK DISARM ────────────────────

func _test_esc_ladder_and_reclick_disarm() -> void:
	print("\n-- (6) Esc/right-click TWO-STEP ladder, then a full disarm --")
	var rig := _rig()
	var canvas = rig[0]
	var msgs: Array = []
	canvas.bus_tool_message.connect(func(t: String) -> void: msgs.append(t))

	canvas._handle_bus_click(Vector2(10.0, 10.0), false)   # N1
	canvas._handle_bus_click(Vector2(20.0, 10.0), false)   # N2
	canvas._start_bus_draw()
	canvas._handle_bus_click(Vector2(0.0, 0.0), false)     # one spine vertex
	check("armed: 2 nets picked, drawing, 1 spine point",
			canvas._bus_nets.size() == 2 and canvas._bus_drawing
				and canvas._bus_spine_points.size() == 1)

	# STEP 1 of the ladder: cancels the SPINE ONLY, net list kept.
	canvas._cancel_bus_step(true)
	check("ladder step 1: spine cancelled", not canvas._bus_drawing
			and canvas._bus_spine_points.is_empty())
	check("ladder step 1: the net list is KEPT (2 nets)",
			canvas._bus_nets.size() == 2, "got %s" % str(canvas._bus_nets))
	check("…announced, naming the kept count",
			msgs[msgs.size() - 1].contains("cancelled") and msgs[msgs.size() - 1].contains("kept"),
			str(msgs[msgs.size() - 1]))

	# STEP 2 of the ladder: now that nothing is drawing, Esc clears the picks.
	canvas._cancel_bus_step(true)
	check("ladder step 2: net picks cleared", canvas._bus_nets.is_empty())
	check("…announced", msgs[msgs.size() - 1].contains("cleared"), str(msgs[msgs.size() - 1]))

	# A THIRD press with nothing left to cancel is a true no-op (no crash, no
	# spurious message) — the ladder bottoms out cleanly.
	var msg_count_before := msgs.size()
	canvas._cancel_bus_step(true)
	check("a third press with nothing armed emits no message",
			msgs.size() == msg_count_before)

	# FULL RESET via set_tool_mode's re-click-disarm path (announce_cancel =
	# true): picks AND an in-progress spine are BOTH discarded in one go,
	# unlike the ladder's incremental peel above.
	canvas._handle_bus_click(Vector2(10.0, 10.0), false)   # N1
	canvas._handle_bus_click(Vector2(20.0, 10.0), false)   # N2
	canvas._start_bus_draw()
	canvas._handle_bus_click(Vector2(0.0, 0.0), false)
	check("armed again: 2 nets, drawing, 1 point",
			canvas._bus_nets.size() == 2 and canvas._bus_drawing)
	canvas.set_tool_mode(canvas.ToolMode.SELECT, true)   # re-click disarm
	check("full disarm: net list AND spine both gone",
			canvas._bus_nets.is_empty() and not canvas._bus_drawing
				and canvas._bus_spine_points.is_empty())
	check("…announced as a disarm", msgs[msgs.size() - 1].contains("disarmed"),
			str(msgs[msgs.size() - 1]))

	# A PLAIN tool switch (announce_cancel = false, the default — the user
	# already knows) resets SILENTLY, same convention TRACE/ZONE/CUTOUT use.
	canvas.set_tool_mode(canvas.ToolMode.BUS)
	canvas._handle_bus_click(Vector2(10.0, 10.0), false)
	canvas._handle_bus_click(Vector2(20.0, 10.0), false)
	var msg_count_before2 := msgs.size()
	canvas.set_tool_mode(canvas.ToolMode.SELECT)   # plain switch, no announce
	check("plain switch: state reset", canvas._bus_nets.is_empty())
	check("…but SILENTLY (no new message)", msgs.size() == msg_count_before2)

	canvas.free()


# ── HITL-7a (docket 019fe0391d06): the propose doorway is TAUGHT at the mouse ─
# Shift+dbl-click proposes ghosts (the mouse twin of Shift+Enter — same
# _commit_bus(propose) call, asserted by reading the same drawing-phase teach
# line a user reads; the gesture's key-modifier read is untestable headless,
# so the taught contract is the pin).

func _test_propose_doorway_teach_line() -> void:
	print("\n-- HITL-7a: drawing teach line names BOTH propose gestures --")
	var rig := _rig()
	var canvas = rig[0]
	var msgs: Array = []
	canvas.bus_tool_message.connect(func(t: String) -> void: msgs.append(t))
	canvas._handle_bus_click(Vector2(10.0, 10.0), false)   # N1
	canvas._handle_bus_click(Vector2(20.0, 10.0), false)   # N2
	canvas._start_bus_draw()
	check("drawing started", canvas._bus_drawing)
	var teach := str(msgs[msgs.size() - 1]) if not msgs.is_empty() else ""
	check("the teach line names Shift+Enter", teach.contains("Shift+Enter"))
	check("…AND the mouse twin Shift+dbl-click (HITL-7a: it was keyboard-only and invisible)",
		teach.contains("Shift+dbl-click"))
	check("…and says plainly which verb makes COPPER vs PROPOSES",
		teach.contains("COPPER") and teach.contains("PROPOSES"))
