extends SceneTree
## The CANVAS bus tool (ToolMode.BUS) — the pin-to-pin gesture and the plan the
## two MCP bus verbs share with it.
##
## Run:
##   godot --headless --path src --script ../../minerva-plugins/pcb/tests/gd/test_bus_tool.gd
##
## STYLE NOTE: this suite follows test_pcb_trace_tool.gd's LIGHT rig (a bare
## pcb_canvas.gd instance + a StubPadHost + direct calls into the tool's own
## methods), not test_pcb_canvas_input_probe.gd's heavy armed-mount/Window
## recipe — the bus tool, like the trace tool, owns its click outright and needs
## no annotation-overlay/universal-select machinery to exercise.
##
## ── THE ORACLES ──────────────────────────────────────────────────────────────
## Every claim below is checked against something the tool does not author:
##
##   GEOMETRY — the SERIALIZED traces (data.to_board_dict()["traces"]), compared
##     against point lists derived by hand. The straight-bundle numbers are NOT
##     re-derived here: they are test_bus_breakout_geometry.gd's own pinned
##     straight bundle translated by (+20, +20), spine and pads together, so a
##     reviewer checks a translation rather than a second derivation.
##   NOTHING WAS COMMITTED — the serialized trace list, data.history.size() AND
##     data.change_journal.size(), all three read either side of the gesture. A
##     status string is not evidence that no copper landed; the board is.
##   REFUSALS REACH THE USER — the bus_tool_message signal's text, required to
##     NAME the offending nets/pads, not merely to be non-empty.
##   A BAD BUS STILL LANDS — the serialized trace list and history.size() after
##     a bus that breaks a rule, plus a segment-overlap scan over the COMMITTED
##     points proving the copper really does cross. "Nothing was committed" is
##     asserted only where the geometry could not exist at all.
##   MANHATTAN — every segment of every committed trace, measured for a non-zero
##     dx AND dy. That test asserts on the copper, not on the spine buffer the
##     axis snap writes.
##   MCP PARITY — two INDEPENDENTLY driven boards (one through the canvas
##     handlers, one through panel_tools.handle) compared point for point, plus
##     the manifest's own required-args lists for both bus verbs.
##   WHERE A NET MAY END — the fixture's OWN net pin lists minus the source pad
##     (eligibility) and plain pad-centre distance (the suggestion), both
##     derived in this file; plus the pick path itself, driven onto every pad
##     the guidance offers, and the landed target read back afterwards.
##   WHERE A NET IS HEADED — the airline's own two endpoints: the `from` against
##     the fixture's spine-click coordinates (and, with a rubber band live, the
##     axis snap applied to a hover point by hand), the `to` against the
##     fixture's pad coordinates, and every `to` fed back through
##     _bus_target_at, which must name the ref the airline claims.
##
## WHAT IS NOT PINNED HERE: the lane arithmetic (test_pcb_bus_geometry.gd) and
## the pad-to-pad breakout geometry, bends and crossing rules
## (test_bus_breakout_geometry.gd). This suite is about the GESTURE and the
## wiring, and consumes those pins rather than repeating them.

const PCBData := preload("res://../../minerva-plugins/pcb/ui/model/pcb_data.gd")
const PcbCanvasScript := preload("res://../../minerva-plugins/pcb/ui/pcb_canvas.gd")
const PanelToolsScript := preload("res://../../minerva-plugins/pcb/ui/panel_tools.gd")
const ComponentScript := preload("res://../../minerva-plugins/pcb/ui/model/pcb_component.gd")
const PcbRoutingWorkspace := preload("res://../../minerva-plugins/pcb/ui/model/pcb_routing_workspace.gd")
const PcbBusLabels := preload("res://../../minerva-plugins/pcb/ui/model/pcb_bus_labels.gd")
const BusGeom := preload("res://../../minerva-plugins/pcb/ui/model/pcb_bus_geometry.gd")
const PcbPadApproach := preload("res://../../minerva-plugins/pcb/ui/model/pcb_pad_approach.gd")
const PcbRatsnest := preload("res://../../minerva-plugins/pcb/ui/model/pcb_ratsnest.gd")
const MANIFEST_PATH := "res://../../minerva-plugins/pcb/manifest.json"

## Coordinate tolerance, in mm. Vector2 is 32-bit float regardless of build
## precision and these points are built through an offset normal at magnitudes
## past 100mm; 1e-4 mm is 0.1 micron, four orders below any fab tolerance, so it
## still fails every real geometry bug (a track on the wrong lane misses by
## 0.5mm, a leg at the wrong station by the same).
const EPS := 1e-4

var _pass := 0
var _fail := 0


## The pad oracle the tool asks for pads. Mirrors test_pcb_trace_tool.gd's own
## StubPadHost verbatim (each light suite owns its copy — this is a private test
## double, not shared production code).
class StubPadHost extends RefCounted:
	## The production pad-picking rule, so this double cannot drift from it.
	const PCBComponentScript := preload("res://../../minerva-plugins/pcb/ui/model/pcb_component.gd")
	## [{component, pin, position, lands?}]. `lands` are optional footprint
	## lands in the SAME shape pcb_component.pads carries, and because this stub
	## measures in an identity frame their `position` is world mm.
	var pads: Array = []
	func pad_at(world_pos: Vector2, radius: float, _filter: Variant = null) -> Dictionary:
		var best: Dictionary = {}
		var best_d := INF
		for p in pads:
			# The production rule, CALLED not copied: distance to the pad's
			# copper. A stub carrying the old centre-distance rule would keep
			# this suite green against a contract that no longer exists.
			var d: float = PCBComponentScript.pin_copper_distance_from(
				Vector2.ZERO, Transform2D.IDENTITY, p["position"],
				p.get("lands", []), world_pos)
			if d > radius:
				continue
			# host.pad_at's TIE-BREAK as well as its distance: equal distances
			# group under is_equal_approx and the lower (component, pin) wins.
			# Ranking by strict `<` would keep whichever pad came first in this
			# array, so the double would answer a click exactly between two
			# pads differently from the surface it stands in for.
			if best.is_empty() or (d < best_d and not is_equal_approx(d, best_d)):
				best_d = d
				best = p
			elif is_equal_approx(d, best_d) and _pad_precedes(p, best):
				best = p
		return best

	static func _pad_precedes(a: Dictionary, b: Dictionary) -> bool:
		var a_comp := str(a.get("component", ""))
		var b_comp := str(b.get("component", ""))
		if a_comp != b_comp:
			return a_comp < b_comp
		return str(a.get("pin", "")) < str(b.get("pin", ""))


## Minimal host for panel_tools.handle() — the ONLY duck-typed method the
## dispatch path needs (see panel_tools.gd's _get_data): get_board_data().
class StubMcpHost extends RefCounted:
	var data
	func get_board_data():
		return data


func _init() -> void:
	print("=== PCB canvas BUS tool: pin to pin ===\n")
	_test_tool_mode_enum_position()
	_test_zone_vertex_edit_exclusion()
	_test_pin_to_pin_gesture()
	_test_nothing_lands_until_the_bus_is_finished()
	_test_a_trace_is_not_a_bus_anchor()
	_test_target_pick_matches_the_pad_hit_test()
	_test_a_click_on_the_pads_copper_is_that_pad()
	_test_the_two_pickers_agree_on_a_tie()
	_test_double_click_grammar()
	_test_the_finished_bus_commits_from_a_landed_target()
	_test_manhattan_from_sloppy_clicks()
	_test_a_crossing_commits_and_is_named()
	_test_propose_is_pad_to_pad_and_writes_no_copper()
	_test_where_each_net_may_end()
	_test_the_airline_says_where_each_net_is_headed()
	_test_manifest_requires_pads_on_both_verbs()
	_test_a_layer_switch_mid_path_is_a_via_station()
	_test_foreign_copper_is_named_and_still_lands()
	# AWAITED (unlike every synchronous test above): panel_tools.handle() is a
	# coroutine end to end (see panel_tools.gd's own class-doc note) because it
	# awaits internally on other branches. A bare call without await here would
	# still COMPILE, but this test's post-await assertions would resume on some
	# later, unscheduled tick — possibly after _init() has printed Results and
	# quit() — and silently not count.
	await _test_mcp_direct_verb_matches_the_gesture()
	await _test_a_bad_bus_reaches_the_agent_and_the_ghost()
	await _test_the_station_verb_matches_the_station_gesture()
	await _test_foreign_copper_reaches_the_agent_the_gesture_and_the_ghost()
	_test_a_leg_on_a_layer_its_pad_is_not_on_is_named()
	await _test_an_off_layer_leg_reaches_the_agent()
	_test_a_station_via_names_the_layer_it_lands_on()
	_test_a_station_that_walls_a_pad_off_is_named()
	await _test_a_crowding_station_still_lands()
	await _test_the_journal_records_what_stood_at_commit()
	_test_unreachable_targets_still_name_the_layer_to_start_on()
	_test_an_open_lane_commits_as_a_free_end()
	await _test_the_open_verb_matches_the_open_gesture()
	await _test_dry_run_reads_the_bus_and_writes_nothing()
	await _test_approach_sides_and_leave_one_open()
	_test_every_lane_wears_its_net()
	_test_lane_order_is_a_visible_choice()
	_test_a_neighbouring_pad_outranks_the_glyph()
	_test_the_live_plan_is_the_commit_plan()
	_test_an_all_open_station_bus_lands_deliberately()
	await _test_a_crossing_bus_is_told_a_clean_order()
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


# ── FIXTURE ───────────────────────────────────────────────────────────────────
#
# Three nets to bus, each with a SOURCE pad on the left and a TARGET pad on the
# right, plus one net that is never picked (the illegal-target probe).
#
#   NA  U1 (10,10) → V1 (130,40)
#   NB  U2 (10,12) → V2 (130,42)
#   NC  U3 (10,14) → V3 (130,44)     V3.1 is a 6.0 x 0.6mm LAND, not a point
#   NX  W1 (60,50) → W2 (70,50)      never picked
#
# Every pad but V3.1 is a bare point pin. V3.1 carries real pad geometry so the
# suite can click copper that is far from a pad's centre — see section 4b.
#
# The board declares trace_width_mm 0.2 and clearance_mm 0.3, so every net's
# width auto-derives to 0.2 with no seeded copper at all — the serialized trace
# list is then exactly the bus, and the rule pitch 0.1 + 0.3 + 0.1 = 0.5, laid
# 0.01 wider at 0.51, gives lanes [-0.51, 0.0, +0.51] (pinned by
# test_pcb_bus_geometry.gd, consumed here).

## V3.1's land, width x height in mm. 6.0 long on X, so its copper reaches
## +-3.0mm from the pin centre — well past the 1.27mm TRACE_PAD_SNAP_MM a pick
## measures with. Only 0.6 tall on Y, deliberately: V2.1 sits 2.0mm above, and
## a taller land would reach into V2.1's own 1.27mm slack and make the two pads
## equidistant from this suite's existing off-centre probe.
const V3_LAND_MM := Vector2(6.0, 0.6)


func _board() -> Dictionary:
	return {
		"version": 1, "name": "BusBoard", "width_mm": 140.0, "height_mm": 60.0,
		"grid_mm": 2.54,
		"layers": ["top", "bottom"],
		"design_rules": {"clearance_mm": 0.3, "trace_width_mm": 0.2},
		"components": [
			_part("U1", 10.0, 10.0), _part("U2", 10.0, 12.0), _part("U3", 10.0, 14.0),
			_part("V1", 130.0, 40.0), _part("V2", 130.0, 42.0),
			_part("V3", 130.0, 44.0, V3_LAND_MM),
			_part("W1", 60.0, 50.0), _part("W2", 70.0, 50.0),
		],
		"nets": [
			{"name": "NA", "pins": ["U1.1", "V1.1"]},
			{"name": "NB", "pins": ["U2.1", "V2.1"]},
			{"name": "NC", "pins": ["U3.1", "V3.1"]},
			{"name": "NX", "pins": ["W1.1", "W2.1"]},
		],
	}


## `land`, when non-zero, is the pin's pad width x height in mm. Canonical
## boards carry pad geometry ON the pin (pad_width_mm/pad_height_mm) and
## pcb_component synthesizes the render land from it, so this is the authored
## form — no hand-built `pads` array anywhere.
func _part(ref: String, x: float, y: float, land: Vector2 = Vector2.ZERO) -> Dictionary:
	var pin := {"number": "1", "x_mm": 0.0, "y_mm": 0.0}
	if land != Vector2.ZERO:
		pin["pad_width_mm"] = land.x
		pin["pad_height_mm"] = land.y
	return {"ref": ref, "footprint": "IC_DIP", "x_mm": x, "y_mm": y, "rotation_deg": 0.0,
		"pins": [pin]}


const SRC_A := Vector2(10.0, 10.0)
const SRC_B := Vector2(10.0, 12.0)
const SRC_C := Vector2(10.0, 14.0)
const TGT_A := Vector2(130.0, 40.0)
const TGT_B := Vector2(130.0, 42.0)
const TGT_C := Vector2(130.0, 44.0)
## Clear board, well outside every pad's TRACE_PAD_SNAP_MM (1.27mm) radius.
const PATH_1 := Vector2(20.0, 20.0)
const PATH_2 := Vector2(120.0, 20.0)
const EMPTY := Vector2(60.0, 20.0)
## The middle spine vertex a via station lands on, and the two layers it joins.
## Clear board like PATH_1/PATH_2, and on their axis so the spine crosses it
## straight — the only shape a station is built for.
const STATION := Vector2(70.0, 20.0)
## Where the PATH-ending double-click lands. Clear board like the two above,
## and deliberately OFF the spine's axis: the vertex its first press places
## snaps to (120, 34), a leg no duplicate-point dedup would swallow, so a spine
## that kept it commits visibly different copper.
const DBL_END := Vector2(122.0, 34.0)

## The bus this fixture commits, hand-checked.
##
## test_bus_breakout_geometry.gd's straight bundle is spine (0,0)→(100,0) with
## sources (-10,-10)/(-10,-8)/(-10,-6) and targets (110,20)/(110,22)/(110,24);
## it pins source stations 1.02/0.51/0.0 and target stations 0.0/0.51/1.02 and the
## three routes below. This fixture is that case translated by (+20, +20) —
## spine (20,20)→(120,20), the same pads moved with it — so the routes are the
## pinned ones plus the same offset, and nothing about the geometry is being
## re-derived here.
func _expected_routes() -> Dictionary:
	return {
		"NA": [SRC_A, Vector2(21.02, 10.0), Vector2(21.02, 19.49),
			Vector2(120.0, 19.49), Vector2(120.0, 40.0), TGT_A],
		"NB": [SRC_B, Vector2(20.51, 12.0), Vector2(20.51, 20.0),
			Vector2(119.49, 20.0), Vector2(119.49, 42.0), TGT_B],
		"NC": [SRC_C, Vector2(20.0, 14.0), Vector2(20.0, 20.51),
			Vector2(118.98, 20.51), Vector2(118.98, 44.0), TGT_C],
	}


## Fresh canvas + data + stub pad host, armed to BUS. Snap disabled so authored
## points land exactly where clicked, matching the numbers above to the bit.
func _rig() -> Array:
	var canvas = PcbCanvasScript.new()
	var data = PCBData.new()
	data.from_board_dict(_board())
	canvas.data = data
	canvas.zoom = 8.0
	canvas.snap_to_grid = false
	var host := StubPadHost.new()
	host.pads = [
		{"component": "U1", "pin": "1", "position": SRC_A},
		{"component": "U2", "pin": "1", "position": SRC_B},
		{"component": "U3", "pin": "1", "position": SRC_C},
		{"component": "V1", "pin": "1", "position": TGT_A},
		{"component": "V2", "pin": "1", "position": TGT_B},
		# The ONE pad with copper of its own. Same land the board dict authors
		# for V3.1 — the two pickers each read their own source, and section 4b
		# is what holds the two readings to the same answer.
		{"component": "V3", "pin": "1", "position": TGT_C, "lands": [
			{"number": "1", "shape": "rect", "position": TGT_C,
				"size": V3_LAND_MM, "rotation": 0.0},
		]},
		{"component": "W1", "pin": "1", "position": Vector2(60.0, 50.0)},
		{"component": "W2", "pin": "1", "position": Vector2(70.0, 50.0)},
	]
	canvas.set_pin_inspector_host(host)
	canvas.set_tool_mode(canvas.ToolMode.BUS)
	return [canvas, data, host]


## Pick the three sources, path the bundle, land the three targets — the whole
## gesture up to (but NOT including) the commit.
func _drive_full_gesture(canvas) -> void:
	canvas._handle_bus_click(SRC_A, false)     # NA
	canvas._handle_bus_click(SRC_B, false)     # NB
	canvas._handle_bus_click(SRC_C, false)     # NC
	canvas._handle_bus_click(PATH_1, false)    # ends SOURCES, vertex 1
	canvas._handle_bus_click(PATH_2, false)    # vertex 2
	canvas._handle_bus_click(TGT_A, false)     # ends PATH, target NA
	canvas._handle_bus_click(TGT_B, false)
	canvas._handle_bus_click(TGT_C, false)


## A PHYSICAL double-click, as the two presses Godot actually delivers: an
## ordinary click, then the same position again with double_click set. Driving
## only the second press would hide whatever the first one did to the tool.
func _double_click(canvas, at: Vector2) -> void:
	canvas._handle_bus_click(at, false)
	canvas._handle_bus_click(at, true)


func _serialized_traces(data) -> Array:
	return (data.to_board_dict().get("traces", []) as Array)


## Serialized traces keyed "net|layer". A bus with a via station lands TWO
## traces per net, one per layer run, so keying by net alone would silently keep
## whichever of the pair sorted last.
func _traces_by_net_and_layer(data) -> Dictionary:
	var out := {}
	for t in _serialized_traces(data):
		var d: Dictionary = t
		out["%s|%s" % [str(d.get("net", "")), str(d.get("layer", ""))]] = d
	return out


func _serialized_vias(data) -> Array:
	return (data.to_board_dict().get("vias", []) as Array)


## Serialized vias keyed by net — one per net for a one-station bus.
func _vias_by_net(data) -> Dictionary:
	var out := {}
	for v in _serialized_vias(data):
		out[str((v as Dictionary).get("net", ""))] = v
	return out


func _traces_by_net(data) -> Dictionary:
	var out := {}
	for t in _serialized_traces(data):
		out[str((t as Dictionary).get("net", ""))] = t
	return out


func _points_of(trace: Dictionary) -> Array:
	var out: Array = []
	for p in (trace.get("points", []) as Array):
		var d: Dictionary = p
		out.append(Vector2(float(d.get("x_mm", d.get("x", 0.0))), float(d.get("y_mm", d.get("y", 0.0)))))
	return out


func _check_route(net: String, got: Array, want: Array) -> void:
	var ok := got.size() == want.size()
	if ok:
		for i in range(got.size()):
			if (got[i] as Vector2).distance_to(want[i] as Vector2) > EPS:
				ok = false
				break
	check("%s runs its whole hand-derived route, source pad to target pad" % net, ok,
		"\n    want: %s\n    got:  %s" % [str(want), str(got)])


## Everything an "and nothing was written" claim is measured against.
func _board_state(data) -> Array:
	return [_serialized_traces(data).size(), data.history.size(), data.change_journal.size()]


func _collect(canvas) -> Array:
	var msgs: Array = []
	canvas.bus_tool_message.connect(func(t: String) -> void: msgs.append(t))
	return msgs


func _last(msgs: Array) -> String:
	return str(msgs[msgs.size() - 1]) if not msgs.is_empty() else "(no message)"


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
			+ "handle must not draw/hit-resolve while the bus tool owns the click",
			not canvas._zone_vertex_edit_active())
	canvas.free()


# ── 1. THE WHOLE PIN-TO-PIN GESTURE ───────────────────────────────────────────
#
# ORACLE: the serialized traces (their exact point lists, hand-derived above),
# data.history and data.change_journal — read BEFORE the commit as well as
# after, because the claim under test is not only "the right copper lands" but
# "it lands on the commit and on nothing else". The click that finishes the
# gesture (the last target) is measured for silence on the board; only Enter
# writes.

func _test_pin_to_pin_gesture() -> void:
	print("\n-- (1) pads → path → pads → Enter: the bus reaches every pad --")
	var rig := _rig()
	var canvas = rig[0]
	var data = rig[1]
	var msgs := _collect(canvas)

	var before := _board_state(data)
	_drive_full_gesture(canvas)

	check("picked in click order: [NA, NB, NC] (T11 — never re-sorted)",
			canvas._bus_nets == (["NA", "NB", "NC"] as Array[String]),
			"got %s" % str(canvas._bus_nets))
	check("the gesture is FINISHED — every net has a target",
			canvas._bus_target_refs == (["V1.1", "V2.1", "V3.1"] as Array[String]),
			"got %s" % str(canvas._bus_target_refs))
	check("…and finishing it wrote NOTHING: traces, history and journal all unmoved",
			_board_state(data) == before,
			"before=%s after=%s" % [str(before), str(_board_state(data))])
	check("the tool says it is ready to commit, naming the verb",
			_last(msgs).contains("Enter") and _last(msgs).contains("every net has a target"),
			_last(msgs))

	canvas._commit_bus()

	var by_net := _traces_by_net(data)
	check("3 traces landed, one per net, and nothing else",
			_serialized_traces(data).size() == 3 and by_net.size() == 3,
			"got %s" % str(by_net.keys()))
	var want := _expected_routes()
	for net in ["NA", "NB", "NC"]:
		if not by_net.has(net):
			check("bus trace for %s exists" % net, false)
			continue
		_check_route(net, _points_of(by_net[net]), want[net])
		check("%s carries the board's declared 0.2mm width" % net,
				is_equal_approx(float((by_net[net] as Dictionary).get("width_mm",
					(by_net[net] as Dictionary).get("width", 0.0))), 0.2))
	if by_net.size() == 3:
		var ends := {"NA": [SRC_A, TGT_A], "NB": [SRC_B, TGT_B], "NC": [SRC_C, TGT_C]}
		var on_source := true
		var on_target := true
		for net in ends.keys():
			var pts := _points_of(by_net[net])
			var want_pads: Array = ends[net]
			on_source = on_source and (pts[0] as Vector2).distance_to(want_pads[0] as Vector2) <= EPS
			on_target = on_target and (pts[pts.size() - 1] as Vector2).distance_to(want_pads[1] as Vector2) <= EPS
		check("every route STARTS on its own source pad", on_source)
		check("…and ENDS on its own target pad", on_target)

	check("history grew by EXACTLY ONE step for the whole bus (journal delta 1)",
			data.history.size() == int(before[1]) + 1,
			"before=%d after=%d" % [int(before[1]), data.history.size()])
	check("the tool disarmed itself after committing",
			canvas._bus_nets.is_empty() and canvas._bus_spine_points.is_empty()
				and canvas._bus_target_refs.is_empty())
	check("undo() removes ALL 3 traces together", data.undo() and data.get_trace_count() == 0,
			"got %d traces" % data.get_trace_count())

	canvas.free()


# ── 2. NOTHING LANDS UNTIL THE BUS IS FINISHED ────────────────────────────────
#
# ORACLE: the whole board state triple, sampled after every gesture that must
# not write — Enter in each unfinished phase, an illegal target pad, and the
# Esc ladder all the way out. A status string can lie about what happened; the
# trace list, the history and the change journal cannot.

func _test_nothing_lands_until_the_bus_is_finished() -> void:
	print("\n-- (2) an unfinished bus cannot be committed, by any route --")
	var rig := _rig()
	var canvas = rig[0]
	var data = rig[1]
	var msgs := _collect(canvas)
	var quiet := _board_state(data)

	# Enter with nothing picked at all.
	canvas._commit_bus()
	check("Enter while picking sources writes nothing", _board_state(data) == quiet)
	check("…and names the verb the user owes", _last(msgs).contains("pads"), _last(msgs))

	# Enter with a path but no targets.
	canvas._handle_bus_click(SRC_A, false)
	canvas._handle_bus_click(SRC_B, false)
	canvas._handle_bus_click(SRC_C, false)
	canvas._handle_bus_click(PATH_1, false)
	canvas._handle_bus_click(PATH_2, false)
	canvas._commit_bus()
	check("Enter with a path but no targets writes nothing", _board_state(data) == quiet,
			str(_board_state(data)))
	check("…and says a target pad is what is missing",
			_last(msgs).contains("target"), _last(msgs))

	# A pad on a net that is not in the bus is refused BY NAME and does not end
	# the PATH phase — checked behaviourally: the next empty click still places
	# a spine vertex instead of answering with the targets line.
	var msg_count := msgs.size()
	canvas._handle_bus_click(Vector2(60.0, 50.0), false)   # W1.1, net NX
	check("an off-bus pad is refused, naming the pad AND its net",
			_last(msgs).contains("W1.1") and _last(msgs).contains("NX"), _last(msgs))
	check("…and the tool is still pathing (phase unchanged)",
			canvas._bus_phase == canvas.BusPhase.PATH)
	msg_count = msgs.size()
	canvas._handle_bus_click(Vector2(60.0, 20.0), false)
	check("…so the next clear-board click still places a vertex, silently",
			msgs.size() == msg_count and canvas._bus_spine_points.size() == 3,
			"messages +%d, %d spine points" % [msgs.size() - msg_count, canvas._bus_spine_points.size()])

	# A net's OWN source pad is not a legal target for it.
	canvas._handle_bus_click(SRC_B, false)
	check("a net's own source pad is refused as its target, by name",
			_last(msgs).contains("U2.1") and _last(msgs).contains("source"), _last(msgs))

	# Two of three targets: landing them writes nothing by itself, and the tool
	# names the net still open — a commit from here would land NC's lane
	# open-ended (section 15), which is why this block no longer presses Enter.
	canvas._handle_bus_click(TGT_A, false)
	canvas._handle_bus_click(TGT_B, false)
	check("landing 2 of 3 targets writes nothing", _board_state(data) == quiet,
			str(_board_state(data)))
	check("…and the tool names the net still without one",
			_last(msgs).contains("NC"), _last(msgs))

	# The Esc ladder peels one phase per press and abandons without copper.
	canvas._cancel_bus_step(true)
	check("Esc 1: targets dropped, path kept",
			canvas._bus_spine_points.size() == 3 and canvas._bus_target_refs == (["", "", ""] as Array[String]),
			"%d points, targets %s" % [canvas._bus_spine_points.size(), str(canvas._bus_target_refs)])
	canvas._cancel_bus_step(true)
	check("Esc 2: path dropped, the picked nets kept in order",
			canvas._bus_spine_points.is_empty()
				and canvas._bus_nets == (["NA", "NB", "NC"] as Array[String]))
	canvas._cancel_bus_step(true)
	check("Esc 3: the picks are cleared too", canvas._bus_nets.is_empty())
	var msg_count_end := msgs.size()
	canvas._cancel_bus_step(true)
	check("Esc 4 with nothing armed is a true no-op (no message)", msgs.size() == msg_count_end)
	check("the whole abandoned gesture wrote NOTHING to the board",
			_board_state(data) == quiet, str(_board_state(data)))

	# And a plain tool switch abandons an armed bus silently, still writing
	# nothing.
	canvas._handle_bus_click(SRC_A, false)
	canvas._handle_bus_click(SRC_B, false)
	canvas._handle_bus_click(PATH_1, false)
	var msg_count_switch := msgs.size()
	canvas.set_tool_mode(canvas.ToolMode.SELECT)
	check("a plain tool switch resets every phase's state",
			canvas._bus_nets.is_empty() and canvas._bus_spine_points.is_empty()
				and canvas._bus_phase == canvas.BusPhase.SOURCES)
	check("…silently (the user chose the switch)", msgs.size() == msg_count_switch)
	check("…and still nothing on the board", _board_state(data) == quiet)

	canvas.free()


# ── 3. COPPER IS NOT CLEAR BOARD (SOURCES ONLY) ───────────────────────────────
#
# The click that ends SOURCES becomes the path's FIRST VERTEX, so "not a pad"
# cannot mean "start the path here" when the thing under the cursor is a trace:
# that one click would both change phase and drop a vertex on existing copper.
# In SOURCES a trace click is inert and says so. From PATH on the rule is the
# opposite, deliberately — the bus commits on its own frozen layer, so a spine
# crossing copper is legitimate; both halves are pinned here.
#
# ORACLE: the phase enum and the spine array (the two things a phase change
# would move), the emitted text, and the board-state triple.

func _test_a_trace_is_not_a_bus_anchor() -> void:
	print("\n-- (3) a trace click while picking sources is inert --")
	var rig := _rig()
	var canvas = rig[0]
	var data = rig[1]
	var msgs := _collect(canvas)
	# Copper on the never-picked net, crossing the spine's own line at x=60 and
	# well clear of every pad's 1.27mm snap radius.
	data.create_trace_entity("NX", "top",
		PackedVector2Array([Vector2(60.0, 5.0), Vector2(60.0, 45.0)]), 0.2)
	var quiet := _board_state(data)
	var on_copper := Vector2(60.0, 20.0)

	check("the seeded trace really is under that point — measured with the same "
			+ "hit test the tool asks, not assumed",
			canvas._trace_at(on_copper) != "", "_trace_at found nothing")
	check("…and no pad is", canvas._trace_pad_at(on_copper).is_empty())

	canvas._handle_bus_click(SRC_A, false)
	canvas._handle_bus_click(SRC_B, false)
	canvas._handle_bus_click(on_copper, false)
	check("the phase did not advance — still picking sources",
			canvas._bus_phase == canvas.BusPhase.SOURCES,
			"phase %d" % canvas._bus_phase)
	check("…and no vertex was placed", canvas._bus_spine_points.is_empty(),
			"%d spine points" % canvas._bus_spine_points.size())
	check("…refused BY NAME: a trace is not a bus anchor, and a click clear of "
			+ "the copper is what starts the path",
			_last(msgs).contains("trace") and _last(msgs).contains("not a bus anchor")
				and _last(msgs).contains("clear of the copper"), _last(msgs))
	# WHERE the path starts is pinned here rather than in its own case: this is
	# the one SOURCES-phase moment in the suite with the full net list picked,
	# which is exactly when the teach line has to say it. A spine begun beside
	# the pin column leaves every source pad inside the corridor, so "clear of
	# the pads" alone is the sentence that walks a user into that finding.
	check("…the picks are untouched, and the teach line says where the path "
			+ "starts — past the source pads the way the bus runs, not merely clear of them",
			canvas._bus_nets == (["NA", "NB"] as Array[String])
				and canvas.bus_teach_line().contains("past the source pads")
				and canvas.bus_teach_line().contains("reach back")
				and not canvas.bus_teach_line().contains("BEHIND"),
			"picks %s / teach %s" % [str(canvas._bus_nets), canvas.bus_teach_line()])
	check("…and nothing was written", _board_state(data) == quiet, str(_board_state(data)))

	# The PATH phase is PERMISSIVE, and that is the whole scope of the rule.
	canvas._handle_bus_click(PATH_1, false)
	var msg_count := msgs.size()
	canvas._handle_bus_click(on_copper, false)
	check("once pathing, a vertex over that same copper is placed, silently",
			canvas._bus_spine_points.size() == 2 and msgs.size() == msg_count,
			"%d points, messages +%d" % [canvas._bus_spine_points.size(), msgs.size() - msg_count])
	if canvas._bus_spine_points.size() == 2:
		check("…and it really did land ON the trace (the axis snap holds y=20)",
				canvas._trace_at(canvas._bus_spine_points[1]) != "",
				"vertex %s" % str(canvas._bus_spine_points[1]))

	canvas.free()


# ── 4. THE TARGET PICK AGREES WITH THE PAD HIT TEST ───────────────────────────
#
# A ringed pad must be clickable anywhere the pad hit test accepts it: the
# target pick's radius IS the one _trace_pad_at hands the pad host
# (TRACE_PAD_SNAP_MM), so a click near the edge of that radius lands the target
# instead of falling through to the refusal. The refusal's own half is pinned
# with it — the pad it names is the pad the hit test resolved, so "that is this
# net's own source" is only ever said about a pad that is.
#
# ORACLE: _trace_pad_at's own answer at the same point (the pick is measured
# against the hit test, not against a re-derived distance), plus the target
# array and the emitted text.

func _test_target_pick_matches_the_pad_hit_test() -> void:
	print("\n-- (4) an off-centre click on a legal pad is accepted, not refused --")
	var rig := _rig()
	var canvas = rig[0]
	var msgs := _collect(canvas)

	canvas._handle_bus_click(SRC_A, false)
	canvas._handle_bus_click(SRC_B, false)
	canvas._handle_bus_click(SRC_C, false)
	canvas._handle_bus_click(PATH_1, false)
	canvas._handle_bus_click(PATH_2, false)

	# 1.2mm off V2.1's centre: inside the 1.27mm the pad hit test is asked for,
	# and 2.3mm from V1.1/V3.1, so exactly one pad can claim it.
	var off_centre := TGT_B + Vector2(1.2, 0.0)
	check("the PAD hit test resolves that click to V2.1",
			str(canvas._trace_pad_at(off_centre).get("ref", "")) == "V2.1",
			str(canvas._trace_pad_at(off_centre)))
	canvas._handle_bus_click(off_centre, false)
	check("…so the pick accepts it as NB's target rather than refusing it",
			canvas._bus_target_refs[1] == "V2.1", "targets %s" % str(canvas._bus_target_refs))
	check("…naming the net and the pad", _last(msgs).contains("NB")
			and _last(msgs).contains("V2.1"), _last(msgs))

	# And where the pick DOES refuse, it refuses the pad the hit test resolved.
	var off_source := SRC_B + Vector2(1.2, 0.0)
	check("the PAD hit test resolves this one to U2.1 — NB's own source",
			str(canvas._trace_pad_at(off_source).get("ref", "")) == "U2.1",
			str(canvas._trace_pad_at(off_source)))
	canvas._handle_bus_click(off_source, false)
	check("…and THAT is the pad the refusal names, as NB's source",
			_last(msgs).contains("U2.1") and _last(msgs).contains("source"), _last(msgs))
	check("…leaving the target already landed alone", canvas._bus_target_refs[1] == "V2.1",
			"targets %s" % str(canvas._bus_target_refs))

	canvas.free()


# ── 4b. A CLICK ANYWHERE ON A PAD'S COPPER IS THAT PAD ────────────────────────
#
# V3.1 is a 6.0 x 0.6mm land, so its copper runs x=127..133 at y=44. A point
# 2.5mm along it is ON the pad and 2.5mm from the pin centre — nearly twice the
# 1.27mm TRACE_PAD_SNAP_MM a pick measures with. Rank pad CENTRES and there is
# no pad there at all: the TARGETS click falls through to the "nothing here"
# status and NC never gets a target, on copper the user can plainly see.
#
# Both of the canvas's pad picks are driven, because they read DIFFERENT
# sources: _trace_pad_at goes through the pad host, _bus_target_at straight off
# the board model. They must give one answer.
#
# ORACLE: the authored land, 6.0mm long and centred on the pin — |dx| <= 3.0 is
# copper, |dx| >= 3.0 + 1.27 is neither copper nor slack — plus the tool's own
# committed target list (_bus_target_refs), which is state, not a message.

func _test_a_click_on_the_pads_copper_is_that_pad() -> void:
	print("\n-- (4b) a click on the far end of a long land lands that pad --")
	var rig := _rig()
	var canvas = rig[0]

	canvas._handle_bus_click(SRC_A, false)
	canvas._handle_bus_click(SRC_B, false)
	canvas._handle_bus_click(SRC_C, false)
	canvas._handle_bus_click(PATH_1, false)
	canvas._handle_bus_click(PATH_2, false)

	var on_far_copper := TGT_C + Vector2(2.5, 0.0)
	check("the PAD hit test resolves the far end of V3.1's land to V3.1",
			str(canvas._trace_pad_at(on_far_copper).get("ref", "")) == "V3.1",
			str(canvas._trace_pad_at(on_far_copper)))
	canvas._handle_bus_click(on_far_copper, false)
	check("…and the TARGET pick agrees — NC's target is landed, not refused",
			canvas._bus_target_refs[2] == "V3.1",
			"targets %s" % str(canvas._bus_target_refs))

	# The rule is the copper PLUS the same slack, not an unbounded pad: 4.5mm
	# out is 1.5mm clear of the land's end, past the 1.27mm.
	var off_the_end := TGT_C + Vector2(4.5, 0.0)
	check("a click 1.5mm clear of the land's end is not that pad",
			canvas._trace_pad_at(off_the_end).is_empty(),
			str(canvas._trace_pad_at(off_the_end)))
	check("…and the target pick does not claim it either",
			canvas._bus_target_at(off_the_end).is_empty(),
			str(canvas._bus_target_at(off_the_end)))

	canvas.free()


# ── 5. THE DOUBLE-CLICK GRAMMAR ───────────────────────────────────────────────
#
# Godot delivers a physical double-click as TWO press events; the second
# carries double_click=true. The picking guard that survived from the two-phase
# tool is pinned here alongside the rule that the press which LANDS a target can
# never also commit it, and the PATH ending: a double-click clear of the pads
# ends the path, and because its OWN first press placed a vertex there, ending
# must drop that vertex again. The one double-click ON a pad that DOES commit is
# section 5b's, and this section is what holds it to that one case.
#
# ORACLE: the picked-net list for the pick claims, the board-state triple for
# the commit claims, and for the PATH ending the COMMITTED COPPER — a path
# ended by double-click at DBL_END must commit the same hand-derived routes as
# the pad-ended gesture, which a stray vertex (a leg down to y=34, past any
# duplicate-point dedup) could not do. The refusal is measured against the text
# the pad ending emits for the same too-short path, not a copy of it.

func _test_double_click_grammar() -> void:
	print("\n-- (5) double-click: never re-toggles a pick, never commits from a pad --")
	var rig := _rig()
	var canvas = rig[0]
	var data = rig[1]

	canvas._handle_bus_click(SRC_A, false)   # press 1 picks NA
	canvas._handle_bus_click(SRC_A, true)    # press 2 of the same double-click
	check("NA is picked exactly once, not toggled back off by the second press",
			canvas._bus_nets == (["NA"] as Array[String]), "got %s" % str(canvas._bus_nets))
	canvas._handle_bus_click(SRC_A, false)
	check("…but a real second single-click on the same pad still removes it",
			canvas._bus_nets.is_empty(), "got %s" % str(canvas._bus_nets))

	_drive_full_gesture(canvas)
	var ready := _board_state(data)
	canvas._handle_bus_click(TGT_C, true)
	check("the press that LANDS the last target can never also write copper — "
			+ "its double-click's second press commits NOTHING",
			_board_state(data) == ready, str(_board_state(data)))

	canvas._handle_bus_click(EMPTY, true)
	check("a double-click clear of the pads DOES commit (the mouse twin of Enter)",
			_serialized_traces(data).size() == 3, "got %d" % _serialized_traces(data).size())
	check("…in one journal step", data.history.size() == int(ready[1]) + 1)
	canvas.free()

	# The PATH ending. DBL_END's first press places a vertex the double-click
	# must take back; if it stayed, the spine would turn down to y=34 and no
	# route below would land where the pad-ended gesture puts it.
	rig = _rig()
	canvas = rig[0]
	data = rig[1]
	canvas._handle_bus_click(SRC_A, false)
	canvas._handle_bus_click(SRC_B, false)
	canvas._handle_bus_click(SRC_C, false)
	canvas._handle_bus_click(PATH_1, false)    # ends SOURCES, vertex 1
	canvas._handle_bus_click(PATH_2, false)    # vertex 2
	# The ending performed below has to be NAMED before it can be performed —
	# nothing else on screen carries the gesture. Checked on bus_teach_line(),
	# the string the draw path itself renders.
	check("the PATH teach line names BOTH endings — the pad, and the double-click",
			canvas.bus_teach_line().contains("double-click")
				and canvas.bus_teach_line().contains("pad per net"),
			canvas.bus_teach_line())
	# The canvas STORES the canonical id; the user reads the toolbar's name, so
	# the line has to carry the second.
	check("…names the layer the way the toolbar does",
			canvas._bus_layer == "top" and canvas.bus_teach_line().contains("F.Cu"),
			"layer %s: %s" % [canvas._bus_layer, canvas.bus_teach_line()])
	canvas._handle_bus_click(DBL_END, false)   # press 1 of the double-click
	canvas._handle_bus_click(DBL_END, true)    # press 2 ends the path
	check("a double-click clear of the pads ends PATH", canvas.bus_phase() == canvas.BusPhase.TARGETS,
			"phase %d" % canvas.bus_phase())
	check("…on exactly the vertices placed before it — no stray vertex under the cursor",
			canvas._bus_spine_points == PackedVector2Array([PATH_1, PATH_2]),
			"got %s" % str(canvas._bus_spine_points))
	canvas._handle_bus_click(TGT_A, false)
	canvas._handle_bus_click(TGT_B, false)
	canvas._handle_bus_click(TGT_C, false)
	canvas._commit_bus()
	var by_net := _traces_by_net(data)
	check("the double-click-ended path commits the same bus as the pad-ended one",
			by_net.size() == 3, "got %s" % str(by_net.keys()))
	var want := _expected_routes()
	for net in ["NA", "NB", "NC"]:
		if not by_net.has(net):
			check("bus trace for %s exists" % net, false)
			continue
		_check_route(net, _points_of(by_net[net]), want[net])
	canvas.free()

	# A first press that appended NOTHING must cost nothing: refused on the
	# never-picked net's pad, the double-click then lands clear of it and has no
	# vertex of its own to take back.
	rig = _rig()
	canvas = rig[0]
	data = rig[1]
	for p in [SRC_A, SRC_B, SRC_C, PATH_1, PATH_2]:
		canvas._handle_bus_click(p, false)
	var kept: PackedVector2Array = canvas._bus_spine_points.duplicate()
	canvas._handle_bus_click(Vector2(60.0, 50.0), false)   # press 1: NX's pad, illegal
	canvas._handle_bus_click(DBL_END, true)                 # press 2
	check("a refused first press leaves the double-click nothing to take back",
			canvas._bus_phase == canvas.BusPhase.TARGETS and canvas._bus_spine_points == kept,
			"phase %d, spine %s" % [int(canvas._bus_phase), str(canvas._bus_spine_points)])
	canvas.free()

	# A one-vertex path refuses whichever gesture asks to end it, and the
	# refusal leaves the tool exactly as it found it.
	rig = _rig()
	canvas = rig[0]
	data = rig[1]
	var msgs := _collect(canvas)
	var before := _board_state(data)
	canvas._handle_bus_click(SRC_A, false)
	canvas._handle_bus_click(SRC_B, false)
	canvas._handle_bus_click(SRC_C, false)
	canvas._handle_bus_click(PATH_1, false)    # ends SOURCES, vertex 1
	canvas._handle_bus_click(PATH_2, false)    # press 1 of the double-click
	canvas._handle_bus_click(PATH_2, true)     # press 2 — only 1 placed vertex
	var refusal := _last(msgs)
	check("a double-click on a path too short to bus is refused, phase unmoved",
			canvas.bus_phase() == canvas.BusPhase.PATH and refusal.contains("at least 2 points"),
			"phase %d, %s" % [canvas.bus_phase(), refusal])
	check("…and the vertex its own first press placed is gone again",
			canvas._bus_spine_points == PackedVector2Array([PATH_1]),
			"got %s" % str(canvas._bus_spine_points))
	canvas._handle_bus_click(TGT_A, false)     # the pad ending, same short path
	check("…in the same words the pad ending refuses in", _last(msgs) == refusal,
			"\n    pad:    %s\n    double: %s" % [_last(msgs), refusal])
	check("and neither refusal wrote anything", _board_state(data) == before,
			str(_board_state(data)))

	canvas.free()


# ── 5b. FINISHING THE BUS FROM ITS OWN TARGET PAD ─────────────────────────────
#
# The gesture a user reaches for once every net is targeted: the cursor is
# already on the pads, so they double-click one. Its FIRST press is an ordinary
# TARGETS click on a pad that already IS that net's target, which clears it — so
# the second press has to take that clear back before it can commit, and the
# whole double-click is atomic the way the PATH ending's is. That is also what
# separates this gesture from the press that LANDS a target (section 5): only a
# press that CLEARED one leaves anything to take back.
#
# ORACLE: the COMMITTED COPPER — the same hand-derived routes _expected_routes()
# pins for the Enter-committed bus, in one journal step — plus the board-state
# triple for the two gestures that must write nothing, the target array read
# back for the half-way states, and bus_teach_line(), the string the draw path
# itself renders, for the words that teach the gesture.

func _test_the_finished_bus_commits_from_a_landed_target() -> void:
	print("\n-- (5b) a finished bus commits from a double-click on its own target pad --")
	var rig := _rig()
	var canvas = rig[0]
	var data = rig[1]
	_drive_full_gesture(canvas)
	var ready := _board_state(data)

	check("the TARGETS teach line names every way to finish the bus",
			canvas.bus_teach_line().contains("double-click")
				and canvas.bus_teach_line().contains("landed target")
				and canvas.bus_teach_line().contains("clear of the pads")
				and canvas.bus_teach_line().contains("Enter"),
			canvas.bus_teach_line())

	canvas._handle_bus_click(TGT_A, false)   # press 1: NA's own target, cleared
	check("press 1 clears that net's target, exactly as a lone click does",
			canvas._bus_target_refs[0].is_empty() and _board_state(data) == ready,
			"refs %s, board %s" % [str(canvas._bus_target_refs), str(_board_state(data))])
	canvas._handle_bus_click(TGT_A, true)    # press 2: takes the clear back, commits
	var by_net := _traces_by_net(data)
	check("press 2 commits the bus the user had finished", by_net.size() == 3,
			"got %s" % str(by_net.keys()))
	check("…in one journal step", data.history.size() == int(ready[1]) + 1,
			"history %d" % data.history.size())
	# The routes are the pad-ended gesture's own: a press 2 that committed
	# without restoring NA's target could not produce NA's copper at all.
	var want := _expected_routes()
	for net in ["NA", "NB", "NC"]:
		if not by_net.has(net):
			check("bus trace for %s exists" % net, false)
			continue
		_check_route(net, _points_of(by_net[net]), want[net])
	canvas.free()

	# NOT every net targeted: the same double-click still means what it has
	# always meant — clear that net's target, write nothing.
	rig = _rig()
	canvas = rig[0]
	data = rig[1]
	canvas._handle_bus_click(SRC_A, false)
	canvas._handle_bus_click(SRC_B, false)
	canvas._handle_bus_click(SRC_C, false)
	canvas._handle_bus_click(PATH_1, false)
	canvas._handle_bus_click(PATH_2, false)
	canvas._handle_bus_click(TGT_A, false)   # ends PATH, target NA
	canvas._handle_bus_click(TGT_C, false)   # NC targeted; NB left open
	var quiet := _board_state(data)
	_double_click(canvas, TGT_A)
	check("an UNFINISHED bus does not commit from a target pad — the clear stands",
			canvas._bus_target_refs[0].is_empty() and _board_state(data) == quiet,
			"refs %s, board %s" % [str(canvas._bus_target_refs), str(_board_state(data))])
	canvas.free()

	# A BUS THAT BREAKS A RULE COMMITS THROUGH THIS GESTURE: corrections need
	# copper to correct, so the finish gesture lands the traces and says what
	# broke rather than arguing.
	rig = _rig()
	canvas = rig[0]
	data = rig[1]
	var msgs := _collect(canvas)
	canvas._handle_bus_click(SRC_C, false)   # reverse pick order: the lanes cross
	canvas._handle_bus_click(SRC_B, false)
	canvas._handle_bus_click(SRC_A, false)
	canvas._handle_bus_click(PATH_1, false)
	canvas._handle_bus_click(PATH_2, false)
	canvas._handle_bus_click(TGT_C, false)
	canvas._handle_bus_click(TGT_B, false)
	canvas._handle_bus_click(TGT_A, false)
	quiet = _board_state(data)
	_double_click(canvas, TGT_C)             # NC is _bus_nets[0] in this order
	check("a crossing bus COMMITS through this gesture — 3 traces, one journal step",
			_traces_by_net(data).size() == 3
				and data.history.size() == int(quiet[1]) + 1,
			"board %s (was %s)" % [str(_board_state(data)), str(quiet)])
	check("…and the message names both crossing nets",
			_last(msgs).contains("NB") and _last(msgs).contains("NC"), _last(msgs))
	canvas.free()


# ── 6. MANHATTAN BY CONSTRUCTION ──────────────────────────────────────────────
#
# ORACLE: every segment of the COMMITTED copper, measured for a simultaneous
# non-zero dx and dy — not the spine buffer, which is what the axis snap writes.
# The sloppy click is 3mm off axis over a 100mm run; if the snap were dropped,
# bundle_routes would refuse the diagonal outright and nothing would land, and
# if it merely rounded, the routes would miss their hand-derived points.

func _test_manhattan_from_sloppy_clicks() -> void:
	print("\n-- (6) an off-axis click still makes axis-aligned copper --")
	var rig := _rig()
	var canvas = rig[0]
	var data = rig[1]

	canvas._handle_bus_click(SRC_A, false)
	canvas._handle_bus_click(SRC_B, false)
	canvas._handle_bus_click(SRC_C, false)
	canvas._handle_bus_click(PATH_1, false)
	canvas._handle_bus_click(Vector2(120.0, 23.0), false)   # 3mm off the axis
	canvas._handle_bus_click(TGT_A, false)
	canvas._handle_bus_click(TGT_B, false)
	canvas._handle_bus_click(TGT_C, false)
	canvas._commit_bus()

	var by_net := _traces_by_net(data)
	check("the bus committed despite the off-axis click", by_net.size() == 3,
			"got %s" % str(by_net.keys()))
	var diagonals := 0
	for net in by_net.keys():
		var pts := _points_of(by_net[net])
		for i in range(pts.size() - 1):
			var d: Vector2 = (pts[i + 1] as Vector2) - (pts[i] as Vector2)
			if absf(d.x) > EPS and absf(d.y) > EPS:
				diagonals += 1
	check("no committed segment moves on both axes (90-degree bends only)",
			diagonals == 0, "%d diagonal segments" % diagonals)
	var want := _expected_routes()
	for net in ["NA", "NB", "NC"]:
		if not by_net.has(net):
			check("bus trace for %s exists" % net, false)
			continue
		_check_route(net, _points_of(by_net[net]), want[net])

	canvas.free()


# ── 7. A CROSSING COMMITS, BY NAME ────────────────────────────────────────────
#
# Picking the same three nets in the REVERSE perpendicular order puts NB's lane
# inside NC's breakout band and NC's pad inside NB's: each would have to leave
# the bundle before the other. pcb_bus_geometry names that rather than
# re-sorting the picks — and, since the geometry can still be drawn, the bus
# LANDS so the user has traces to correct.
#
# THE PREVIEW IS UNCHANGED: the plan is still `ok == false`, so the spine keeps
# its refusal tint and the panel keeps holding the reason — only the commit
# moved.
#
# ORACLES, none of them the emitted message alone:
#   THE COPPER LANDED — the serialized trace list and history.size().
#   THE COPPER REALLY CROSSES — a segment-box overlap scan written here over
#     the COMMITTED points, so the finding is about physical copper, not about
#     an ordering rule that fired on nothing.
#   THE REASON REACHED THE USER — the message names both nets and the end.
#   THE PREVIEW STILL REFUSES — canvas.bus_refusal() read BEFORE the commit.

func _test_a_crossing_commits_and_is_named() -> void:
	print("\n-- (7) two nets that cannot both go first: named, and committed anyway --")
	var rig := _rig()
	var canvas = rig[0]
	var data = rig[1]
	var msgs := _collect(canvas)
	var quiet := _board_state(data)

	canvas._handle_bus_click(SRC_C, false)   # NC first — reverse of the lanes
	canvas._handle_bus_click(SRC_B, false)   # NB
	canvas._handle_bus_click(SRC_A, false)   # NA
	canvas._handle_bus_click(PATH_1, false)
	canvas._handle_bus_click(PATH_2, false)
	canvas._handle_bus_click(TGT_C, false)
	canvas._handle_bus_click(TGT_B, false)
	canvas._handle_bus_click(TGT_A, false)

	var live_refusal: String = str(canvas.bus_refusal())
	# THE CLASS, not only the words: this plan HAS geometry, so the finish
	# gesture below lands it. The panel leads its status line with these two
	# readings, and telling this apart from a plan that writes nothing is the
	# whole difference between "will land with N findings" and "REFUSED".
	check("the live preview names both nets, and reports the plan as one that "
			+ "still LANDS — buildable, with findings to count",
			live_refusal.contains("NB") and live_refusal.contains("NC")
				and bool(canvas.bus_plan_buildable())
				and int(canvas.bus_finding_count()) >= 1,
			"%s (buildable=%s findings=%d)" % [live_refusal,
				str(canvas.bus_plan_buildable()), int(canvas.bus_finding_count())])

	canvas._commit_bus()

	check("the bus COMMITTED anyway — 3 traces in one journal step",
			_traces_by_net(data).size() == 3
				and data.history.size() == int(quiet[1]) + 1,
			"board %s (was %s)" % [str(_board_state(data)), str(quiet)])
	check("the message names BOTH nets that cross",
			_last(msgs).contains("NB") and _last(msgs).contains("NC"), _last(msgs))
	check("…and which END of the bus they cross at", _last(msgs).contains("source"), _last(msgs))
	check("…and says the copper landed so it can be corrected",
			_last(msgs).contains("Added bus") and _last(msgs).contains("correct"),
			_last(msgs))

	var by_net := _traces_by_net(data)
	var touching := 0
	var nets := ["NA", "NB", "NC"]
	for i in range(nets.size()):
		for j in range(i + 1, nets.size()):
			if not (by_net.has(nets[i]) and by_net.has(nets[j])):
				continue
			if _copper_touches(_points_of(by_net[nets[i]]), _points_of(by_net[nets[j]])):
				touching += 1
	check("the committed copper really does cross — the finding is about copper, not a rule",
			touching > 0, "%d touching pairs" % touching)

	check("one undo removes the whole bad bus", data.undo() and data.get_trace_count() == 0)
	canvas.free()


## Do two AXIS-ALIGNED polylines share a point? Written here, over the
## SERIALIZED copper, and deliberately not the module's own routine: an
## axis-aligned segment is its own bounding box, so "the boxes overlap" and
## "the segments meet" are the same statement.
func _copper_touches(a: Array, b: Array) -> bool:
	for i in range(a.size() - 1):
		for j in range(b.size() - 1):
			var a0: Vector2 = a[i]
			var a1: Vector2 = a[i + 1]
			var b0: Vector2 = b[j]
			var b1: Vector2 = b[j + 1]
			if minf(a0.x, a1.x) <= maxf(b0.x, b1.x) + EPS \
					and minf(b0.x, b1.x) <= maxf(a0.x, a1.x) + EPS \
					and minf(a0.y, a1.y) <= maxf(b0.y, b1.y) + EPS \
					and minf(b0.y, b1.y) <= maxf(a0.y, a1.y) + EPS:
				return true
	return false


# ── 8. THE PROPOSE PATH INHERITS THE SAME PAD-TO-PAD PLAN ─────────────────────
#
# bus_propose_plan is the function BOTH the canvas Shift+Enter and
# minerva_pcb_workspace_propose_bus call. Pinned here directly, with a real
# RoutingWorkspace, because the geometry a ghost carries is the geometry a
# commit would carry.
#
# ORACLE: the candidate segments' own endpoints (first point of the first
# segment, last point of the last) against the pads, and the board-state triple
# for "a proposal is not a write".

func _test_propose_is_pad_to_pad_and_writes_no_copper() -> void:
	print("\n-- (8) proposing lands pad-to-pad ghosts and touches no copper --")
	var data = PCBData.new()
	data.from_board_dict(_board())
	var ws = PcbRoutingWorkspace.new()
	var quiet := _board_state(data)

	var incomplete: Dictionary = PanelToolsScript.bus_plan(
		data, ["NA", "NB", "NC"], PackedVector2Array([PATH_1, PATH_2]), "top",
		PackedStringArray(["U1.1", "U2.1", "U3.1"]), PackedStringArray())
	check("a target-less plan is OK to preview but reports complete == false",
			bool(incomplete.get("ok", false)) and not bool(incomplete.get("complete", true)),
			str(incomplete.get("error", "")))
	var refused: Dictionary = PanelToolsScript.bus_propose_plan(ws, data, incomplete)
	check("…and proposing it is REFUSED", not bool(refused.get("ok", true)),
			str(refused.get("error", "")))
	check("…with nothing ingested", ws.list_candidates().is_empty())

	var plan: Dictionary = PanelToolsScript.bus_plan(
		data, ["NA", "NB", "NC"], PackedVector2Array([PATH_1, PATH_2]), "top",
		PackedStringArray(["U1.1", "U2.1", "U3.1"]), PackedStringArray(["V1.1", "V2.1", "V3.1"]))
	check("the finished plan is complete", bool(plan.get("ok", false)) and bool(plan.get("complete", false)),
			str(plan.get("error", "")))

	var out: Dictionary = PanelToolsScript.bus_propose_plan(ws, data, plan)
	check("3 ghost candidates landed", bool(out.get("ok", false)) and int(out.get("proposed", 0)) == 3,
			str(out.get("error", "")))
	check("the board is untouched — no copper, no history, no journal entry",
			_board_state(data) == quiet, str(_board_state(data)))

	var pads := {"NA": [SRC_A, TGT_A], "NB": [SRC_B, TGT_B], "NC": [SRC_C, TGT_C]}
	for cand in ws.list_candidates():
		var segs: Array = cand.segments
		if segs.is_empty():
			check("candidate for %s has segments" % str(cand.net), false)
			continue
		var first: Array = (segs[0] as Dictionary).get("points", [])
		var last: Array = (segs[segs.size() - 1] as Dictionary).get("points", [])
		var want: Array = pads.get(str(cand.net), [Vector2.ZERO, Vector2.ZERO])
		check("%s's ghost starts on its source pad and ends on its target pad" % str(cand.net),
				(first[0] as Vector2).distance_to(want[0]) <= EPS
					and (last[last.size() - 1] as Vector2).distance_to(want[1]) <= EPS,
				"first=%s last=%s want=%s" % [str(first[0]), str(last[last.size() - 1]), str(want)])


# ── 9. BOTH MCP VERBS DEMAND THE PADS ─────────────────────────────────────────
#
# ORACLE: the shipped manifest itself. The two verbs share one arg parser, so
# the schema is where a caller learns the contract — and a verb that still
# advertised nets+points alone would be advertising a bus that stops short of
# the pads.

func _test_manifest_requires_pads_on_both_verbs() -> void:
	print("\n-- (9) the manifest requires sources+targets on both bus verbs --")
	var text := FileAccess.get_file_as_string(MANIFEST_PATH)
	check("manifest.json is readable", not text.is_empty(), MANIFEST_PATH)
	if text.is_empty():
		return
	var parsed = JSON.parse_string(text)
	check("manifest.json parses", parsed is Dictionary)
	if not (parsed is Dictionary):
		return
	var wanted := {"minerva_pcb_route_bus_direct": false, "minerva_pcb_workspace_propose_bus": false}
	for tool in ((parsed as Dictionary).get("tools", []) as Array):
		var name := str((tool as Dictionary).get("name", ""))
		if not wanted.has(name):
			continue
		wanted[name] = true
		var required: Array = (((tool as Dictionary).get("input_schema", {}) as Dictionary).get("required", []) as Array)
		var props: Dictionary = ((tool as Dictionary).get("input_schema", {}) as Dictionary).get("properties", {})
		check("%s requires sources AND targets" % name,
				"sources" in required and "targets" in required, str(required))
		check("%s documents both as pin-ref arrays" % name,
				props.has("sources") and props.has("targets"))
		# The via station is OPTIONAL — it must be documented but must never
		# join `required`, or every single-layer bus call becomes a schema error.
		check("%s documents the via station as an optional pair" % name,
				props.has("via_station_index") and props.has("via_station_layer")
					and not ("via_station_index" in required)
					and not ("via_station_layer" in required), str(required))
	for name in wanted.keys():
		check("%s is registered" % name, bool(wanted[name]))


# ── 9b. THE VIA STATION ───────────────────────────────────────────────────────
#
# ORACLE: the SERIALIZED board — six traces keyed by net AND layer, three vias,
# one new history entry — against point lists derived by hand from the fixture's
# own numbers, exactly as _expected_routes derives the single-layer bus.
#
# THE DERIVATION, from the fixture's 0.2mm tracks at 0.3mm clearance (lanes
# [-0.51, 0.0, +0.51], source stations 1.02/0.51/0.0, target stations
# 0.0/0.51/1.02 — all pinned by test_bus_breakout_geometry.gd and consumed
# here) plus the via rules this board declares NONE of, so the 0.8mm / 0.4mm
# fallback applies:
#
#   via pitch = 0.4 + 0.3 + 0.4 = 1.1mm, laid at 1.11, wider than the 0.51mm
#   track pitch, so the lanes widen to [-1.11, 0.0, +1.11] at the station and
#   NA/NC jog 1.11mm either side of it (x 68.89 and x 71.11). NB is already on
#   the spine and does not move, so it has no jog at all.
#
# The three vias therefore sit on x = 70, the station's own perpendicular, at
# y 18.89 / 20.0 / 21.11 — 1.11mm apart, past the 1.1mm clearance claim
# measured below rather than assumed.

## Pick, path, switch layer, place the station, finish and commit.
func _drive_station_gesture(canvas) -> void:
	canvas._handle_bus_click(SRC_A, false)     # NA
	canvas._handle_bus_click(SRC_B, false)     # NB
	canvas._handle_bus_click(SRC_C, false)     # NC
	canvas._handle_bus_click(PATH_1, false)    # ends SOURCES, spine vertex 0
	# THE LAYER SWITCH, made the way every surface makes it: the toolbar Layer
	# chooser and minerva_pcb_view_state both write this property.
	canvas.working_layer = "bottom"
	canvas._handle_bus_click(STATION, false)   # vertex 1 — the via station
	canvas._handle_bus_click(PATH_2, false)    # vertex 2
	canvas._handle_bus_click(TGT_A, false)     # ends PATH, target NA
	canvas._handle_bus_click(TGT_B, false)
	canvas._handle_bus_click(TGT_C, false)


## The six runs the station bus commits, hand-derived above.
func _expected_station_runs() -> Dictionary:
	return {
		"NA|top": [SRC_A, Vector2(21.02, 10.0), Vector2(21.02, 19.49),
			Vector2(68.89, 19.49), Vector2(68.89, 18.89), Vector2(70.0, 18.89)],
		"NA|bottom": [Vector2(70.0, 18.89), Vector2(71.11, 18.89),
			Vector2(71.11, 19.49), Vector2(120.0, 19.49), Vector2(120.0, 40.0), TGT_A],
		"NB|top": [SRC_B, Vector2(20.51, 12.0), Vector2(20.51, 20.0), Vector2(70.0, 20.0)],
		"NB|bottom": [Vector2(70.0, 20.0), Vector2(119.49, 20.0),
			Vector2(119.49, 42.0), TGT_B],
		"NC|top": [SRC_C, Vector2(20.0, 14.0), Vector2(20.0, 20.51),
			Vector2(68.89, 20.51), Vector2(68.89, 21.11), Vector2(70.0, 21.11)],
		"NC|bottom": [Vector2(70.0, 21.11), Vector2(71.11, 21.11),
			Vector2(71.11, 20.51), Vector2(118.98, 20.51), Vector2(118.98, 44.0), TGT_C],
	}


func _test_a_layer_switch_mid_path_is_a_via_station() -> void:
	print("\n-- (9b) a layer switch mid-path vias the bus onto the new layer --")
	var rig := _rig()
	var canvas = rig[0]
	var data = rig[1]
	var msgs := _collect(canvas)

	canvas._handle_bus_click(SRC_A, false)
	canvas._handle_bus_click(SRC_B, false)
	canvas._handle_bus_click(SRC_C, false)
	canvas._handle_bus_click(PATH_1, false)
	var before := _board_state(data)
	canvas.working_layer = "bottom"
	check("the switch does not cancel the path", canvas.bus_phase() == canvas.BusPhase.PATH)
	check("…nor re-aim the copper already drawn — the bus is still on top",
			str(canvas._bus_layer) == "top", str(canvas._bus_layer))
	check("…and it says a station is armed",
			_last(msgs).contains("Via station armed"), _last(msgs))
	check("…having written nothing", _board_state(data) == before, str(_board_state(data)))
	# The switch is AUTHORING, not view: the run already drawn on top has to stay
	# on screen, or the user vias onto a layer and loses sight of what they left.
	# Read through is_layer_visible, the predicate the draw loop uses.
	check("…and BOTH layers are still drawn — arming a station is not a view change",
			bool(canvas.is_layer_visible("top")) and bool(canvas.is_layer_visible("bottom")))
	check("…with the view filter untouched", str(canvas.trace_layer_filter) == "all",
			str(canvas.trace_layer_filter))

	canvas._handle_bus_click(STATION, false)
	check("the station lands on the vertex just clicked",
			int(canvas._bus_station_index) == 1, str(canvas._bus_station_index))
	# ONE station per bus: the second switch is refused by name rather than
	# quietly moving the station out from under the geometry drawn around it.
	canvas.working_layer = "top"
	# AND IT NAMES THE WAY OUT, which is NOT "pick this layer again". The run
	# past the station is on the station's layer, so a bus that has to END on
	# F.Cu must have STARTED on B.Cu; advice that sent the user back to the same
	# start layer would walk them into this same refusal a second time.
	check("a second layer switch is refused, naming the station it already has "
			+ "AND the start layer that would end the bus where it was asked for",
			_last(msgs).contains("already has a via station")
				and int(canvas._bus_station_index) == 1
				and _last(msgs).contains("switches once")
				and _last(msgs).contains("To END on F.Cu")
				and _last(msgs).contains("START on B.Cu")
				and _last(msgs).contains("Esc")
				and _last(msgs).contains("Layer chooser to B.Cu"),
			_last(msgs))

	canvas._handle_bus_click(PATH_2, false)
	canvas._handle_bus_click(TGT_A, false)
	canvas._handle_bus_click(TGT_B, false)
	canvas._handle_bus_click(TGT_C, false)
	canvas._commit_bus()

	var runs := _traces_by_net_and_layer(data)
	check("three nets landed SIX traces — one per layer run",
			_serialized_traces(data).size() == 6 and runs.size() == 6,
			str(_serialized_traces(data).size()))
	for key in _expected_station_runs().keys():
		if not runs.has(key):
			check("%s exists" % key, false, str(runs.keys()))
			continue
		_check_route(str(key), _points_of(runs[key]), _expected_station_runs()[key])

	var vias := _vias_by_net(data)
	check("one via per net", _serialized_vias(data).size() == 3 and vias.size() == 3,
			str(_serialized_vias(data)))
	var want_vias := {"NA": Vector2(70.0, 18.89), "NB": Vector2(70.0, 20.0),
		"NC": Vector2(70.0, 21.11)}
	for net in want_vias.keys():
		if not vias.has(net):
			check("%s carries a via" % net, false, str(vias.keys()))
			continue
		var v: Dictionary = vias[net]
		var at := Vector2(float(v.get("x_mm", 0.0)), float(v.get("y_mm", 0.0)))
		check("%s\'s via sits on the station\'s perpendicular at its own lane offset" % net,
				at.distance_to(want_vias[net]) <= EPS, "%s vs %s" % [str(at), str(want_vias[net])])
		check("%s\'s via is a THROUGH via at the board\'s own fallback size" % net,
				str(v.get("from_layer", "")) == "top" and str(v.get("to_layer", "")) == "bottom"
					and absf(float(v.get("diameter_mm", 0.0)) - 0.8) <= EPS
					and absf(float(v.get("drill_mm", 0.0)) - 0.4) <= EPS,
				str(v))

	# ADJACENT-VIA CLEARANCE, measured on the committed board: 0.8mm pads at the
	# board's 0.3mm clearance owe 1.1mm centre to centre.
	var tightest := INF
	var placed: Array = _serialized_vias(data)
	for i in range(placed.size()):
		for j in range(i + 1, placed.size()):
			var a := Vector2(float((placed[i] as Dictionary).get("x_mm", 0.0)),
				float((placed[i] as Dictionary).get("y_mm", 0.0)))
			var b := Vector2(float((placed[j] as Dictionary).get("x_mm", 0.0)),
				float((placed[j] as Dictionary).get("y_mm", 0.0)))
			tightest = minf(tightest, a.distance_to(b))
	check("no two vias come closer than the 1.1mm via pitch", tightest >= 1.1 - 1e-3,
			"%.6f" % tightest)

	# MANHATTAN ON THE COPPER, both layers — measured on what was serialized,
	# not on the spine buffer the axis snap wrote.
	var diagonals := 0
	for t in _serialized_traces(data):
		var pts := _points_of(t)
		for i in range(pts.size() - 1):
			var d: Vector2 = (pts[i + 1] as Vector2) - (pts[i] as Vector2)
			if absf(d.x) > EPS and absf(d.y) > EPS:
				diagonals += 1
	check("every committed segment is still axis-aligned", diagonals == 0)

	check("the whole two-layer bus is ONE undo step",
			data.history.size() == before[1] + 1,
			"%d -> %d" % [before[1], data.history.size()])
	check("the summary counts the vias and names both layers",
			_last(msgs).contains("3 vias") and _last(msgs).contains("F.Cu")
				and _last(msgs).contains("B.Cu"), _last(msgs))
	canvas.free()


# ── 10. MCP PARITY: THE DIRECT VERB == THE GESTURE ─────────────────────────────
#
# ORACLE: two boards driven independently — one through the canvas handlers,
# one through panel_tools.handle — compared point for point. Same fixture, same
# ordered nets, same pads, same spine.

func _test_mcp_direct_verb_matches_the_gesture() -> void:
	print("\n-- (10) minerva_pcb_route_bus_direct == the canvas gesture, pad to pad --")
	var rig := _rig()
	var canvas_a = rig[0]
	var data_a = rig[1]
	_drive_full_gesture(canvas_a)
	canvas_a._commit_bus()
	var by_net_a := _traces_by_net(data_a)

	var data_b := PCBData.new()
	data_b.from_board_dict(_board())
	var host_b := StubMcpHost.new()
	host_b.data = data_b
	var quiet := _board_state(data_b)

	# The pads are not optional on this verb any more: a call without them is
	# the bus that stops short of the copper it is meant to reach.
	var no_pads: Dictionary = await PanelToolsScript.handle(host_b, "minerva_pcb_route_bus_direct", {
		"editor_name": "PCB1", "nets": ["NA", "NB", "NC"],
		"points": [{"x_mm": 20.0, "y_mm": 20.0}, {"x_mm": 120.0, "y_mm": 20.0}],
		"layer": "top",
	})
	check("a call with no sources/targets is refused", not bool(no_pads.get("success", true)),
			str(no_pads))
	check("…naming the missing arg", str(no_pads.get("error", "")).contains("sources"),
			str(no_pads.get("error", "")))
	check("…and writing nothing", _board_state(data_b) == quiet, str(_board_state(data_b)))

	# A pad that is not on the net it is offered for is refused too — the one
	# check the geometry underneath cannot make for itself.
	var wrong_net: Dictionary = await PanelToolsScript.handle(host_b, "minerva_pcb_route_bus_direct", {
		"editor_name": "PCB1", "nets": ["NA", "NB", "NC"],
		"sources": ["U1.1", "U2.1", "U3.1"], "targets": ["V1.1", "V2.1", "W2.1"],
		"points": [{"x_mm": 20.0, "y_mm": 20.0}, {"x_mm": 120.0, "y_mm": 20.0}],
		"layer": "top",
	})
	check("a target pad on the WRONG net is refused, naming pad and both nets",
			not bool(wrong_net.get("success", true))
				and str(wrong_net.get("error", "")).contains("W2.1")
				and str(wrong_net.get("error", "")).contains("NX")
				and str(wrong_net.get("error", "")).contains("NC"),
			str(wrong_net.get("error", "")))
	check("…and writing nothing", _board_state(data_b) == quiet, str(_board_state(data_b)))

	var result: Dictionary = await PanelToolsScript.handle(host_b, "minerva_pcb_route_bus_direct", {
		"editor_name": "PCB1", "nets": ["NA", "NB", "NC"],
		"sources": ["U1.1", "U2.1", "U3.1"], "targets": ["V1.1", "V2.1", "V3.1"],
		"points": [{"x_mm": 20.0, "y_mm": 20.0}, {"x_mm": 120.0, "y_mm": 20.0}],
		"layer": "top",
	})
	check("the MCP call succeeded", bool(result.get("success", false)), str(result))
	check("it reports 3 trace ids", (result.get("trace_ids", []) as Array).size() == 3,
			str(result.get("trace_ids", [])))

	var by_net_b := _traces_by_net(data_b)
	check("both boards ended with the same trace COUNT",
			by_net_a.size() == by_net_b.size(),
			"gesture=%d tool=%d" % [by_net_a.size(), by_net_b.size()])
	for net in ["NA", "NB", "NC"]:
		if not (by_net_a.has(net) and by_net_b.has(net)):
			check("%s exists on both boards" % net, false)
			continue
		var pa := _points_of(by_net_a[net])
		var pb := _points_of(by_net_b[net])
		var same := pa.size() == pb.size()
		if same:
			for i in range(pa.size()):
				if (pa[i] as Vector2).distance_to(pb[i] as Vector2) > EPS:
					same = false
					break
		check("%s: the gesture and the tool authored the SAME polyline" % net, same,
				"\n    gesture: %s\n    tool:    %s" % [str(pa), str(pb)])

	check("board A: one undo removes its whole bus", data_a.undo() and data_a.get_trace_count() == 0)
	check("board B: one undo removes its whole bus", data_b.undo() and data_b.get_trace_count() == 0)

	canvas_a.free()


# ── 9. WHERE EACH NET MAY END, AND THE SUGGESTION AMONG THOSE ENDINGS ─────────
#
# A bus track does NOT have one predetermined target. Every pad on its net but
# the source pad is a legal ending, so a three-pad net offers TWO of them, and
# the tool has to say which is likely without hiding the rest.
#
# The fan-out fixture below lists ND's FAR pad first, so "the first candidate",
# "the last candidate" and "the nearest candidate" are three different answers
# and only one of them passes.
#
# ORACLES:
#   ELIGIBILITY — the fixture's own net pin lists, minus the source pad, read
#     out of the board dict here.
#   THE ENDINGS ARE REAL — every pad the guidance offers is fed to the pick path
#     (_bus_target_at) and then CLICKED, and the tool's own committed target
#     list is read back. A pad the guidance marks that the click refuses fails.
#   THE SUGGESTION — the nearest eligible pad, by plain distance between the
#     fixture's coordinates.
#   FROM THE FIRST PICK — the same rows are demanded in SOURCES, PATH and
#     TARGETS and compared phase to phase, so guidance that only appeared once
#     targets were being landed would fail.

## Fan-out fixture: ND has THREE pads (two legal endings), NE has two — the
## bus's minimum of two nets, with only one of them ambiguous.
const FAN_SRC := Vector2(10.0, 10.0)
## Listed FIRST in ND's pins and 110mm out; the pin list is not distance order.
const FAN_FAR := Vector2(120.0, 10.0)
## Listed LAST and 30mm out.
const FAN_NEAR := Vector2(40.0, 10.0)
const FAN2_SRC := Vector2(10.0, 12.0)
const FAN2_TGT := Vector2(120.0, 12.0)
## Spine vertices, 13mm clear of every pad row (TRACE_PAD_SNAP_MM is 1.27mm).
const FAN_PATH_1 := Vector2(20.0, 25.0)
const FAN_PATH_2 := Vector2(110.0, 25.0)


func _fanout_board() -> Dictionary:
	return {
		"version": 1, "name": "FanBoard", "width_mm": 140.0, "height_mm": 60.0,
		"grid_mm": 2.54,
		"layers": ["top", "bottom"],
		"design_rules": {"clearance_mm": 0.3, "trace_width_mm": 0.2},
		"components": [
			_part("U4", FAN_SRC.x, FAN_SRC.y), _part("Z4", FAN_FAR.x, FAN_FAR.y),
			_part("Y4", FAN_NEAR.x, FAN_NEAR.y),
			_part("U5", FAN2_SRC.x, FAN2_SRC.y), _part("Z5", FAN2_TGT.x, FAN2_TGT.y),
		],
		"nets": [
			{"name": "ND", "pins": ["U4.1", "Z4.1", "Y4.1"]},
			{"name": "NE", "pins": ["U5.1", "Z5.1"]},
		],
	}


func _fanout_rig() -> Array:
	var canvas = PcbCanvasScript.new()
	var data = PCBData.new()
	data.from_board_dict(_fanout_board())
	canvas.data = data
	canvas.zoom = 8.0
	canvas.snap_to_grid = false
	var host := StubPadHost.new()
	host.pads = [
		{"component": "U4", "pin": "1", "position": FAN_SRC},
		{"component": "Z4", "pin": "1", "position": FAN_FAR},
		{"component": "Y4", "pin": "1", "position": FAN_NEAR},
		{"component": "U5", "pin": "1", "position": FAN2_SRC},
		{"component": "Z5", "pin": "1", "position": FAN2_TGT},
	]
	canvas.set_pin_inspector_host(host)
	canvas.set_tool_mode(canvas.ToolMode.BUS)
	return [canvas, data, host]


## Every pad on `net` except `source`, straight out of a board dict's own net
## list — the eligibility oracle, owing nothing to the canvas.
func _eligible_from_fixture(board: Dictionary, net: String, source: String) -> PackedStringArray:
	var out := PackedStringArray()
	for n in (board.get("nets", []) as Array):
		var nd := n as Dictionary
		if str(nd.get("name", "")) != net:
			continue
		for pin in (nd.get("pins", []) as Array):
			if str(pin) != source:
				out.append(str(pin))
	out.sort()
	return out


func _guidance_row(canvas, net: String) -> Dictionary:
	for row in canvas.bus_target_guidance():
		if str((row as Dictionary).get("net", "")) == net:
			return row
	return {}


func _candidate_refs(row: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	for c in (row.get("candidates", []) as Array):
		out.append(str((c as Dictionary).get("ref", "")))
	out.sort()
	return out


func _candidate_at(row: Dictionary, ref: String) -> Vector2:
	for c in (row.get("candidates", []) as Array):
		var cd := c as Dictionary
		if str(cd.get("ref", "")) == ref:
			var at: Vector2 = cd.get("at", Vector2.ZERO)
			return at
	return Vector2.ZERO


## A stable text rendering of the whole guidance — compared phase to phase, and
## a string rather than the rows themselves so the comparison does not rest on
## Dictionary equality semantics.
func _guidance_summary(rows: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for row in rows:
		var r := row as Dictionary
		out.append("%d %s from %s -> [%s] likely %s target %s" % [
			int(r.get("index", -1)), str(r.get("net", "")), str(r.get("source_ref", "")),
			", ".join(_candidate_refs(r)), str(r.get("suggested_ref", "")),
			str(r.get("target_ref", ""))])
	return out


func _test_where_each_net_may_end() -> void:
	print("\n-- (9) eligible endings from the first pick, and a suggestion among them --")
	var rig := _fanout_rig()
	var canvas = rig[0]
	var board := _fanout_board()

	# Two picks and not one click more: still SOURCES, no path, no target.
	canvas._handle_bus_click(FAN_SRC, false)    # ND, from U4.1
	canvas._handle_bus_click(FAN2_SRC, false)   # NE, from U5.1
	check("still in SOURCES — what follows owes nothing to a later phase",
			canvas._bus_phase == canvas.BusPhase.SOURCES)

	var sources_rows: Array = canvas.bus_target_guidance()
	check("both picked nets are already described", sources_rows.size() == 2,
			"got %d rows" % sources_rows.size())

	var nd := _guidance_row(canvas, "ND")
	var want_nd := _eligible_from_fixture(board, "ND", "U4.1")
	check("ND's three-pad net offers TWO endings — the fixture's own other pads %s"
			% str(want_nd),
			_candidate_refs(nd) == want_nd, "got %s" % str(_candidate_refs(nd)))

	# ORACLE: distance between the fixture's own coordinates. Y4.1 is 30mm out
	# and listed LAST; Z4.1 is 110mm out and listed FIRST.
	var nearer := "Y4.1" if FAN_SRC.distance_to(FAN_NEAR) < FAN_SRC.distance_to(FAN_FAR) else "Z4.1"
	check("the suggestion is the NEAREST ending, not the first-listed one",
			str(nd.get("suggested_ref", "")) == nearer,
			"suggested %s, nearest is %s" % [str(nd.get("suggested_ref", "")), nearer])
	check("…and it is one of the endings on offer, never a pad from outside them",
			want_nd.has(str(nd.get("suggested_ref", ""))))

	# A marked pad is a clickable pad — both of them, not only the suggested one.
	for ref in want_nd:
		var at := _candidate_at(nd, str(ref))
		var picked: Dictionary = canvas._bus_target_at(at)
		check("%s: the pad the guidance marks is the pad the pick resolves" % str(ref),
				str(picked.get("ref", "")) == str(ref), "picked %s" % str(picked))

	var ne := _guidance_row(canvas, "NE")
	check("NE's two-pad net offers exactly one ending, and suggests it",
			_candidate_refs(ne) == _eligible_from_fixture(board, "NE", "U5.1")
				and str(ne.get("suggested_ref", "")) == "Z5.1",
			"candidates %s, suggested %s" % [str(_candidate_refs(ne)), str(ne.get("suggested_ref", ""))])

	# The phases: the answer must not wait for the one that lands targets.
	var in_sources := _guidance_summary(sources_rows)
	canvas._handle_bus_click(FAN_PATH_1, false)   # ends SOURCES, vertex 1
	canvas._handle_bus_click(FAN_PATH_2, false)   # vertex 2
	check("PATH reached", canvas._bus_phase == canvas.BusPhase.PATH)
	check("the endings on offer are the SAME ones the SOURCES phase named",
			_guidance_summary(canvas.bus_target_guidance()) == in_sources,
			"\n    sources: %s\n    path:    %s" % [str(in_sources),
				str(_guidance_summary(canvas.bus_target_guidance()))])

	canvas._handle_bus_click(FAN_NEAR, false)     # ends PATH, ND → Y4.1
	check("TARGETS reached, ND landed on the pad it was steered to",
			canvas._bus_phase == canvas.BusPhase.TARGETS
				and canvas._bus_target_refs[0] == "Y4.1",
			"phase %d, targets %s" % [canvas._bus_phase, str(canvas._bus_target_refs)])

	var nd_landed := _guidance_row(canvas, "ND")
	check("with a target landed, ND still reports BOTH endings",
			_candidate_refs(nd_landed) == want_nd,
			"got %s" % str(_candidate_refs(nd_landed)))
	check("…and still names the same likely one",
			str(nd_landed.get("suggested_ref", "")) == nearer,
			"got %s" % str(nd_landed.get("suggested_ref", "")))

	# The alternative was never decoration: clicking it re-targets the net.
	canvas._handle_bus_click(FAN_FAR, false)
	check("clicking the OTHER ending replaces ND's target — the suggestion was "
			+ "never that net's only legal ending",
			canvas._bus_target_refs[0] == "Z4.1", "targets %s" % str(canvas._bus_target_refs))

	canvas.free()

	# Un-picking a net takes its guidance with it: nothing is marked for a net
	# that is no longer in the bus.
	var rig2 := _rig()
	var canvas2 = rig2[0]
	canvas2._handle_bus_click(SRC_A, false)
	check("one pick, one row", canvas2.bus_target_guidance().size() == 1)
	canvas2._handle_bus_click(SRC_A, false)
	check("un-picking the net removes its row", canvas2.bus_target_guidance().is_empty(),
			str(canvas2.bus_target_guidance()))
	canvas2.free()


## Where the cursor hovers while the rubber band is live, and the point the
## axis snap turns it into. |dx| from the last vertex (110,25) is 50 and |dy| is
## 15, so the segment runs HORIZONTALLY and keeps that vertex's y — derived here
## by hand, not read back off the canvas.
const AIRLINE_HOVER := Vector2(60.0, 40.0)
const AIRLINE_HOVER_SNAPPED := Vector2(60.0, 25.0)


func _airline_row(rows: Array, net: String) -> Dictionary:
	for row in rows:
		if str((row as Dictionary).get("net", "")) == net:
			return row
	return {}


## One airline, checked whole: which pad it points at, whether it reads as
## landed, and both endpoints against coordinates this file names.
func _check_airline(rows: Array, net: String, from: Vector2, to: Vector2,
		ref: String, landed: bool) -> void:
	var r := _airline_row(rows, net)
	var got_from: Vector2 = r.get("from", Vector2.ZERO)
	var got_to: Vector2 = r.get("to", Vector2.ZERO)
	check("%s's airline runs %s -> %s (%s, %s)" % [net, str(from), str(to), ref,
				"landed" if landed else "suggested"],
			not r.is_empty() and got_from.distance_to(from) <= EPS
				and got_to.distance_to(to) <= EPS
				and str(r.get("ref", "")) == ref
				and bool(r.get("landed", false)) == landed,
			"got %s" % str(r))


func _test_the_airline_says_where_each_net_is_headed() -> void:
	print("\n-- (10) an airline per net, from the spine's live end to its pad --")
	var rig := _fanout_rig()
	var canvas = rig[0]
	var data = rig[1]

	canvas._handle_bus_click(FAN_SRC, false)    # ND, from U4.1
	canvas._handle_bus_click(FAN2_SRC, false)   # NE, from U5.1
	check("with no spine there is nothing to leave FROM, so no airlines — the "
			+ "rings alone answer SOURCES",
			canvas.bus_airline_items().is_empty(),
			str(canvas.bus_airline_items()))

	# ONE vertex is enough: the question "where does this trace want to go" is
	# asked the moment there is a live end to ask it from.
	canvas._handle_bus_click(FAN_PATH_1, false)   # ends SOURCES, vertex 1
	var first: Array = canvas.bus_airline_items()
	check("from the FIRST vertex on, both picked nets have an airline",
			first.size() == 2, "got %d: %s" % [first.size(), str(first)])
	_check_airline(first, "ND", FAN_PATH_1, FAN_NEAR, "Y4.1", false)
	_check_airline(first, "NE", FAN_PATH_1, FAN2_TGT, "Z5.1", false)

	# THE ONE SOURCE OF TRUTH, checked rather than asserted: every pad an
	# airline points at is the pad a click there resolves to. A second opinion
	# about "likely" would fail here even if it drew a plausible line.
	for row in first:
		var r := row as Dictionary
		var at: Vector2 = r.get("to", Vector2.ZERO)
		var picked: Dictionary = canvas._bus_target_at(at)
		check("%s: the pad its airline points at is the pad a click there picks"
					% str(r.get("net", "")),
				str(picked.get("ref", "")) == str(r.get("ref", "")),
				"airline says %s, pick says %s" % [str(r.get("ref", "")), str(picked)])
		check("%s: the airline is drawn in that net's own colour" % str(r.get("net", "")),
				(r.get("color", Color.BLACK) as Color) == data.get_net(str(r.get("net", ""))).color,
				"got %s" % str(r.get("color", "")))

	canvas._handle_bus_click(FAN_PATH_2, false)   # vertex 2
	_check_airline(canvas.bus_airline_items(), "ND", FAN_PATH_2, FAN_NEAR, "Y4.1", false)

	# A LIVE RUBBER BAND MOVES THE ORIGIN. Driven through the real motion
	# handler, so the airline leaves the same point the spine's own preview
	# segment does — including the axis snap.
	var mm := InputEventMouseMotion.new()
	mm.position = canvas.world_to_screen(AIRLINE_HOVER)
	canvas._handle_mouse_motion(mm)
	var hovering: Array = canvas.bus_airline_items()
	_check_airline(hovering, "ND", AIRLINE_HOVER_SNAPPED, FAN_NEAR, "Y4.1", false)
	_check_airline(hovering, "NE", AIRLINE_HOVER_SNAPPED, FAN2_TGT, "Z5.1", false)

	# Landing ND's target ends PATH, which retires the rubber band: the origin
	# falls back to the last placed vertex for BOTH nets, and only ND's airline
	# changes tense.
	canvas._handle_bus_click(FAN_NEAR, false)     # ND → Y4.1
	var landed: Array = canvas.bus_airline_items()
	_check_airline(landed, "ND", FAN_PATH_2, FAN_NEAR, "Y4.1", true)
	_check_airline(landed, "NE", FAN_PATH_2, FAN2_TGT, "Z5.1", false)

	# Re-targeting ND onto its OTHER ending moves the airline with the pick.
	canvas._handle_bus_click(FAN_FAR, false)
	_check_airline(canvas.bus_airline_items(), "ND", FAN_PATH_2, FAN_FAR, "Z4.1", true)

	# Guidance only: none of the above wrote copper or moved the phase off
	# TARGETS.
	check("the airlines changed nothing — still TARGETS, still no traces",
			canvas._bus_phase == canvas.BusPhase.TARGETS
				and _serialized_traces(data).is_empty(),
			"phase %d, %d traces" % [canvas._bus_phase, _serialized_traces(data).size()])

	canvas.free()


## TIE FIXTURE. Distances chosen to be exact in binary floating point (1.0mm
## each side), so the tie is a genuine tie and not a rounding accident that
## drifts one pad out of the snap radius.
const TIE_SRC_1 := Vector2(10.0, 10.0)
const TIE_SRC_2 := Vector2(10.0, 12.0)
## Enumerated FIRST, because its net is picked first.
const TIE_FIRST_SEEN := Vector2(20.0, 20.0)
## Lexicographically first by component ref, so the tie-break must choose it
## over the pad above.
const TIE_LOWEST_REF := Vector2(22.0, 20.0)
const TIE_MID := Vector2(21.0, 20.0)


func _tie_board() -> Dictionary:
	return {
		"version": 1, "name": "TieBoard", "width_mm": 60.0, "height_mm": 40.0,
		"grid_mm": 2.54,
		"layers": ["top", "bottom"],
		"design_rules": {"clearance_mm": 0.3, "trace_width_mm": 0.2},
		"components": [
			_part("U8", TIE_SRC_1.x, TIE_SRC_1.y),
			_part("Z8", TIE_FIRST_SEEN.x, TIE_FIRST_SEEN.y),
			_part("U9", TIE_SRC_2.x, TIE_SRC_2.y),
			_part("A8", TIE_LOWEST_REF.x, TIE_LOWEST_REF.y),
		],
		"nets": [
			{"name": "NT1", "pins": ["U8.1", "Z8.1"]},
			{"name": "NT2", "pins": ["U9.1", "A8.1"]},
		],
	}


## ONE CLICK, TWO PICKERS, ONE PAD.
##
## _bus_target_at and the shared pad hit test are separate walks over separate
## sources, so a click EQUIDISTANT from two pads is the input where their
## ranking can disagree while both are still honestly "nearest". The bus list is
## walked in PICK order, which this fixture arranges to meet Z8.1 first, while
## the tie-break both pickers are supposed to share must answer A8.1.
##
## The comparison against the hit test only has falsifying power because
## StubPadHost carries the production TIE-BREAK and not just the production
## DISTANCE: a double that also kept its first find would agree with a broken
## bus picker and prove nothing. The third check does not lean on either picker.
func _test_the_two_pickers_agree_on_a_tie() -> void:
	var canvas = PcbCanvasScript.new()
	var data = PCBData.new()
	data.from_board_dict(_tie_board())
	canvas.data = data
	canvas.zoom = 8.0
	canvas.snap_to_grid = false
	var host := StubPadHost.new()
	host.pads = [
		{"component": "U8", "pin": "1", "position": TIE_SRC_1},
		{"component": "Z8", "pin": "1", "position": TIE_FIRST_SEEN},
		{"component": "U9", "pin": "1", "position": TIE_SRC_2},
		{"component": "A8", "pin": "1", "position": TIE_LOWEST_REF},
	]
	canvas.set_pin_inspector_host(host)
	canvas.set_tool_mode(canvas.ToolMode.BUS)

	canvas._handle_bus_click(TIE_SRC_1, false)
	canvas._handle_bus_click(TIE_SRC_2, false)

	# The fixture's own coordinates, not either picker, say this is a tie.
	check("the fixture really is a tie",
			is_equal_approx(TIE_FIRST_SEEN.distance_to(TIE_MID),
				TIE_LOWEST_REF.distance_to(TIE_MID)),
			"%f vs %f" % [TIE_FIRST_SEEN.distance_to(TIE_MID),
				TIE_LOWEST_REF.distance_to(TIE_MID)])

	var by_bus: Dictionary = canvas._bus_target_at(TIE_MID)
	var by_hit_test: Dictionary = canvas._trace_pad_at(TIE_MID)
	check("the bus picker names a pad at the tie", not by_bus.is_empty())
	check("the shared hit test names a pad at the tie", not by_hit_test.is_empty())
	check("both pickers resolve one click to one pad",
			str(by_bus.get("ref", "")) == str(by_hit_test.get("ref", "")),
			"bus %s vs hit test %s"
				% [str(by_bus.get("ref", "")), str(by_hit_test.get("ref", ""))])
	# Independent of both: the documented policy is that the lower (component,
	# pin) wins a tie, and the fixture names which pad that is.
	check("the tie goes to the lower component ref, not to whichever was seen first",
			str(by_bus.get("ref", "")) == "A8.1", "got %s" % str(by_bus.get("ref", "")))
	canvas.free()


# ── 11. THE BAD BUS REACHES THE AGENT AND THE GHOST ───────────────────────────
#
# The canvas gesture (section 7) is one of three doorways onto the same plan.
# This pins the other two on the SAME reverse-order crossing, plus the line that
# must NOT move: a bus with no geometry at all still writes nothing.
#
# ORACLES:
#   THE COPPER — the serialized trace list and history.size() on a board driven
#     only through panel_tools.handle. The verb's own reply is not evidence.
#   THE FINDINGS ARE ATTACHED, NOT MERELY RETURNED — read back out of a real
#     RoutingWorkspace through findings_for_candidate(), the same reader the
#     canvas witness renderer uses, and matched against the candidate id each
#     one claims as its subject.
#   UNBUILDABLE IS STILL UNBUILDABLE — an undeclared net through the MCP verb
#     and a diagonal spine through bus_plan, both measured on the board.

func _test_a_bad_bus_reaches_the_agent_and_the_ghost() -> void:
	print("\n-- (11) a bad bus commits through MCP and proposes with its findings --")
	var data := PCBData.new()
	data.from_board_dict(_board())
	var host := StubMcpHost.new()
	host.data = data
	var quiet := _board_state(data)

	# Section 7's crossing, through the agent's doorway.
	var crossed: Dictionary = await PanelToolsScript.handle(host, "minerva_pcb_route_bus_direct", {
		"editor_name": "PCB1", "nets": ["NC", "NB", "NA"],
		"sources": ["U3.1", "U2.1", "U1.1"], "targets": ["V3.1", "V2.1", "V1.1"],
		"points": [{"x_mm": 20.0, "y_mm": 20.0}, {"x_mm": 120.0, "y_mm": 20.0}],
		"layer": "top",
	})
	check("the verb reports success — the copper landed", bool(crossed.get("success", false)),
			str(crossed))
	check("…3 traces in one journal step, read off the board itself",
			_traces_by_net(data).size() == 3 and data.history.size() == int(quiet[1]) + 1,
			str(_board_state(data)))
	var findings: Array = crossed.get("findings", []) if crossed.get("findings", []) is Array else []
	check("…and the broken rules came back as findings", not findings.is_empty(), str(crossed))
	var named := false
	for f in findings:
		var msg := str((f as Dictionary).get("message", ""))
		if msg.contains("NB") and msg.contains("NC"):
			named = true
	check("…at least one naming both crossing nets", named, str(findings))
	check("…and the note tells the caller it landed anyway",
			str(crossed.get("note", "")).contains("landed anyway"), str(crossed.get("note", "")))
	check("one undo removes the whole bad bus", data.undo() and data.get_trace_count() == 0)

	var before := _board_state(data)

	# UNBUILDABLE 1: an undeclared net. Nothing to draw, so nothing lands.
	var absent: Dictionary = await PanelToolsScript.handle(host, "minerva_pcb_route_bus_direct", {
		"editor_name": "PCB1", "nets": ["NA", "NOT_A_NET"],
		"sources": ["U1.1", "U2.1"], "targets": ["V1.1", "V2.1"],
		"points": [{"x_mm": 20.0, "y_mm": 20.0}, {"x_mm": 120.0, "y_mm": 20.0}],
		"layer": "top",
	})
	check("an undeclared net is still refused outright",
			not bool(absent.get("success", true)), str(absent))
	check("…and writes nothing", _board_state(data) == before, str(_board_state(data)))

	# UNBUILDABLE 2: a diagonal spine. No rounding here is one a fab would agree
	# with, so there is no geometry to hand back and none to commit.
	var diagonal: Dictionary = PanelToolsScript.bus_plan(
		data, ["NA", "NB", "NC"], PackedVector2Array([PATH_1, Vector2(120.0, 33.0)]), "top",
		PackedStringArray(["U1.1", "U2.1", "U3.1"]), PackedStringArray(["V1.1", "V2.1", "V3.1"]))
	check("a diagonal spine plans as UNBUILDABLE, with no geometry at all",
			not bool(diagonal.get("ok", true)) and not bool(diagonal.get("buildable", true))
				and not diagonal.has("polylines"),
			str(diagonal.get("error", "")))
	check("…and bus_commit_plan refuses it even when handed it directly",
			not bool(PanelToolsScript.bus_commit_plan(data, diagonal, "unbuildable").get("ok", true)))
	check("…still nothing written", _board_state(data) == before, str(_board_state(data)))

	# THE GHOST HALF: the same crossing, proposed instead of committed.
	var ws = PcbRoutingWorkspace.new()
	var plan: Dictionary = PanelToolsScript.bus_plan(
		data, ["NC", "NB", "NA"], PackedVector2Array([PATH_1, PATH_2]), "top",
		PackedStringArray(["U3.1", "U2.1", "U1.1"]), PackedStringArray(["V3.1", "V2.1", "V1.1"]))
	check("the crossing plan is BAD BUT BUILDABLE, and complete",
			not bool(plan.get("ok", true)) and bool(plan.get("buildable", false))
				and bool(plan.get("complete", false)),
			str(plan.get("error", "")))
	var out: Dictionary = PanelToolsScript.bus_propose_plan(ws, data, plan)
	check("it proposes 3 ghosts anyway",
			bool(out.get("ok", false)) and int(out.get("proposed", 0)) == 3,
			str(out.get("error", "")))
	check("…and the board is still untouched", _board_state(data) == before, str(_board_state(data)))

	var carried := 0
	var misfiled := 0
	for cand in ws.list_candidates():
		var cid := str(cand.candidate_id)
		var stored: Array = ws.findings_for_candidate(cid)
		if stored.is_empty():
			continue
		carried += 1
		for f in stored:
			var fd: Dictionary = f
			var nets: Array = fd.get("nets", []) if fd.get("nets", []) is Array else []
			if not nets.is_empty() and not (str(cand.net) in nets):
				misfiled += 1
			var subjects: Array = fd.get("subjects", []) if fd.get("subjects", []) is Array else []
			if subjects.is_empty() \
					or str((subjects[0] as Dictionary).get("candidate_id", "")) != cid:
				misfiled += 1
	check("every ghost carries the findings that name its own net, filed under itself",
			carried == 3 and misfiled == 0,
			"%d ghosts with findings, %d mis-filed" % [carried, misfiled])

# ── 12. MCP PARITY FOR THE VIA STATION ────────────────────────────────────────
#
# ORACLE: the same two-board comparison test 10 makes, on the station gesture —
# one board driven through the canvas handlers with a layer switch, one through
# minerva_pcb_route_bus_direct with via_station_index/via_station_layer, then
# compared run for run AND via for via. Plus the half-specified station, which
# must be refused rather than half-honoured: an index with no layer would
# silently commit the single-layer bus the caller did not ask for.

func _test_the_station_verb_matches_the_station_gesture() -> void:
	print("\n-- (12) the station args == the layer-switch gesture --")
	var rig := _rig()
	var canvas_a = rig[0]
	var data_a = rig[1]
	_drive_station_gesture(canvas_a)
	canvas_a._commit_bus()
	var runs_a := _traces_by_net_and_layer(data_a)

	var data_b := PCBData.new()
	data_b.from_board_dict(_board())
	var host_b := StubMcpHost.new()
	host_b.data = data_b
	var quiet := _board_state(data_b)
	var spine: Array = [{"x_mm": PATH_1.x, "y_mm": PATH_1.y},
		{"x_mm": STATION.x, "y_mm": STATION.y}, {"x_mm": PATH_2.x, "y_mm": PATH_2.y}]

	var half: Dictionary = await PanelToolsScript.handle(host_b, "minerva_pcb_route_bus_direct", {
		"editor_name": "PCB1", "nets": ["NA", "NB", "NC"],
		"sources": ["U1.1", "U2.1", "U3.1"], "targets": ["V1.1", "V2.1", "V3.1"],
		"points": spine, "layer": "top", "via_station_index": 1,
	})
	check("a station index with no layer is refused, naming both args",
			not bool(half.get("success", true))
				and str(half.get("error", "")).contains("via_station_index")
				and str(half.get("error", "")).contains("via_station_layer"),
			str(half.get("error", "")))
	check("…and writing nothing", _board_state(data_b) == quiet, str(_board_state(data_b)))

	var bent: Dictionary = await PanelToolsScript.handle(host_b, "minerva_pcb_route_bus_direct", {
		"editor_name": "PCB1", "nets": ["NA", "NB", "NC"],
		"sources": ["U1.1", "U2.1", "U3.1"], "targets": ["V1.1", "V2.1", "V3.1"],
		"points": [{"x_mm": 20.0, "y_mm": 20.0}, {"x_mm": 70.0, "y_mm": 20.0},
			{"x_mm": 70.0, "y_mm": 30.0}, {"x_mm": 120.0, "y_mm": 30.0}],
		"layer": "top", "via_station_index": 1, "via_station_layer": "bottom",
	})
	check("a station on a BEND is refused — a station is a via, not a corner",
			not bool(bent.get("success", true))
				and str(bent.get("error", "")).contains("bends"),
			str(bent.get("error", "")))
	check("…and writing nothing", _board_state(data_b) == quiet, str(_board_state(data_b)))

	# A JSON number is a float on arrival; 1.9 is not a vertex and must not
	# quietly become vertex 1.
	var fractional: Dictionary = await PanelToolsScript.handle(host_b, "minerva_pcb_route_bus_direct", {
		"editor_name": "PCB1", "nets": ["NA", "NB", "NC"],
		"sources": ["U1.1", "U2.1", "U3.1"], "targets": ["V1.1", "V2.1", "V3.1"],
		"points": spine, "layer": "top", "via_station_index": 1.9, "via_station_layer": "bottom",
	})
	check("a fractional station index is refused, not truncated",
			not bool(fractional.get("success", true))
				and str(fractional.get("error", "")).contains("integer"),
			str(fractional.get("error", "")))
	check("…and writing nothing", _board_state(data_b) == quiet, str(_board_state(data_b)))

	# A plan that names a station layer but has lost its cuts is refused by the
	# writer before it touches the board — not landed as a single-layer bus.
	var torn: Dictionary = PanelToolsScript.bus_plan(data_b, ["NA", "NB", "NC"],
		PackedVector2Array([PATH_1, STATION, PATH_2]), "top",
		PackedStringArray(["U1.1", "U2.1", "U3.1"]), PackedStringArray(["V1.1", "V2.1", "V3.1"]),
		0.0, 1, "bottom")
	# BUILDABLE, not clean: V3.1 is a top-only land and this station takes
	# the bus to bottom, so the plan carries that pad's off-layer finding —
	# the probe only needs a routed station plan to tear.
	check("the torn-plan probe starts from a routed station plan",
			bool(torn.get("buildable", false)) and (torn.get("via_station_splits", []) as Array).size() == 3, str(torn.get("error", "")))
	torn["via_station_splits"] = [torn["via_station_splits"][0]]
	var torn_out: Dictionary = PanelToolsScript.bus_commit_plan(data_b, torn, "torn")
	check("a station plan with a missing cut is refused, naming the mismatch",
			not bool(torn_out.get("ok", true)) and str(torn_out.get("error", "")).contains("split"),
			str(torn_out.get("error", "")))
	check("…and writing nothing", _board_state(data_b) == quiet, str(_board_state(data_b)))

	var result: Dictionary = await PanelToolsScript.handle(host_b, "minerva_pcb_route_bus_direct", {
		"editor_name": "PCB1", "nets": ["NA", "NB", "NC"],
		"sources": ["U1.1", "U2.1", "U3.1"], "targets": ["V1.1", "V2.1", "V3.1"],
		"points": spine, "layer": "top",
		"via_station_index": 1, "via_station_layer": "bottom",
	})
	check("the station call succeeded", bool(result.get("success", false)), str(result))
	check("it reports six traces and three vias",
			(result.get("trace_ids", []) as Array).size() == 6
				and (result.get("via_ids", []) as Array).size() == 3,
			str(result))
	check("it names the layer the bus continues on",
			str(result.get("via_station_layer", "")) == "bottom", str(result))

	var runs_b := _traces_by_net_and_layer(data_b)
	check("both boards ended with the same run COUNT", runs_a.size() == runs_b.size(),
			"gesture=%d tool=%d" % [runs_a.size(), runs_b.size()])
	for key in _expected_station_runs().keys():
		if not (runs_a.has(key) and runs_b.has(key)):
			check("%s exists on both boards" % key, false,
					"%s / %s" % [str(runs_a.keys()), str(runs_b.keys())])
			continue
		var pa := _points_of(runs_a[key])
		var pb := _points_of(runs_b[key])
		var same := pa.size() == pb.size()
		if same:
			for i in range(pa.size()):
				if (pa[i] as Vector2).distance_to(pb[i] as Vector2) > EPS:
					same = false
					break
		check("%s: the gesture and the tool authored the SAME run" % key, same,
				"gesture=%s tool=%s" % [str(pa), str(pb)])

	var vias_a := _vias_by_net(data_a)
	var vias_b := _vias_by_net(data_b)
	var via_mismatch := ""
	for net in ["NA", "NB", "NC"]:
		if not (vias_a.has(net) and vias_b.has(net)):
			via_mismatch = "%s missing" % net
			continue
		var a := Vector2(float((vias_a[net] as Dictionary).get("x_mm", 0.0)),
			float((vias_a[net] as Dictionary).get("y_mm", 0.0)))
		var b := Vector2(float((vias_b[net] as Dictionary).get("x_mm", 0.0)),
			float((vias_b[net] as Dictionary).get("y_mm", 0.0)))
		if a.distance_to(b) > EPS:
			via_mismatch = "%s: %s vs %s" % [net, str(a), str(b)]
	check("the gesture and the tool dropped the SAME three vias", via_mismatch.is_empty(),
			via_mismatch)
	canvas_a.free()


# ── 13. BUS COPPER THAT LANDS ON ANOTHER NET'S COPPER ─────────────────────────
#
# THE LIVE DEFECT this section exists for: a three-net bus committed target legs
# that ran straight down a 1mm-pitch LGA's pad COLUMNS, through four pads
# belonging to other nets. Every rule the tool had measured the bus against
# ITSELF, so the findings named only the bus's own crossings and the four shorts
# went unreported.
#
# THE FIXTURE reproduces the SHAPE rather than the board: a through-hole source
# column on the left, a spine that turns south, and a target part whose picked
# pads sit BEYOND foreign-net pads on the same column — so each track's last
# leg, which runs down its own pad's column, has to cross one. Seeded alongside
# them are the other two kinds of copper a bus can land on: a foreign VIA a hair
# inside clearance of a lane (the near-miss branch, which no pad here reaches)
# and a foreign TRACE across one leg.
#
# THE GEOMETRY, derived from the fixture's own numbers — 0.2mm tracks at 0.2mm
# clearance give a 0.4mm rule pitch, laid at 0.41, and lanes [-0.205, +0.205];
# both ends order the two tracks by the caller's order, so their departure
# stations are 0.0 and 0.41:
#
#   NA  (10,10) (14,10) (14,9.795) (30.205,9.795) (30.205,24) (31,24) (31,28)
#   NB  (10,12.54) (14.41,12.54) (14.41,10.205) (29.795,10.205) (29.795,23.59)
#       (29,23.59) (29,28)
#
# NA's last leg runs x=31 from y 24 to 28 and so passes through T1.3 (FVCC, a
# 0.6mm land at (31,26)) and across the seeded FGND trace at y=27; NB's runs
# x=29 and passes through T1.1 (FGND at (29,26)). NA's long lane at y=9.795
# runs 0.545mm from the seeded via at (22,9.25).
#
# ORACLES:
#   THE FINDING SET — the (bus net, foreign item) pairs above, compared against
#     the WHOLE finding list. Equality, not membership: it also says nothing
#     ELSE about this bus is broken, which is what makes the four attributable.
#   THE MEASUREMENT — the via near-miss's own arithmetic: 0.545mm centre to
#     lane, less the 0.400mm via radius and the 0.100mm track half-width, is
#     0.045mm of bare board where the board's rules ask 0.200mm.
#   THE LAYER — the same bus planned on `bottom`, where the target part's SMD
#     lands and the seeded trace are not. Only the through-the-stack copper (the
#     via) may still be named there.
#   THE BOARD — the serialized trace list and history.size() either side of the
#     MCP call: a bad bus still lands, in one journal step.
#   THE EXISTING FIXTURE — section 1's clean bus, which must gain no finding at
#     all; this rule may not start refusing buses that were always legal.

## The LGA fixture's spine: east out of the source column, then south into the
## target part. The last segment's axis is what makes each track's final leg run
## DOWN a pad column, which is the whole shape of the live defect.
const LGA_PATH_1 := Vector2(14.0, 10.0)
const LGA_PATH_2 := Vector2(30.0, 10.0)
const LGA_PATH_3 := Vector2(30.0, 24.0)
const LGA_SRC_A := Vector2(10.0, 10.0)     # U1.1, net NA
const LGA_SRC_B := Vector2(10.0, 12.54)    # U1.2, net NB
const LGA_TGT_A := Vector2(31.0, 28.0)     # T1.4, net NA — T1.3 (FVCC) sits above it
const LGA_TGT_B := Vector2(29.0, 28.0)     # T1.2, net NB — T1.1 (FGND) sits above it
## The seeded foreign via, 0.545mm off NA's lane (y 9.795).
const LGA_VIA_AT := Vector2(22.0, 9.25)
## What that leaves between the two coppers' EDGES, in mm, against a 0.200mm rule.
const LGA_VIA_GAP_MM := 0.045
const LGA_CLEARANCE_MM := 0.2
## The finding type under test, spelled OUT rather than read off the
## implementation: it is a wire value a consumer branches on, so this file is
## where a rename has to be noticed. The two are held equal below.
const FOREIGN := "bus_foreign_copper"
## Likewise the off-layer pad rule's wire value, held equal to the tool's below.
const OFF_LAYER := "bus_pad_off_layer"
## And the station-corridor rule's.
const CROWDS := "bus_station_crowds_pad"


## A through-hole pin of the source column: a 0.8mm drill in a 1.6mm annulus, so
## its copper is a 0.8mm-radius disc present on BOTH copper layers.
func _tht_pin(number: String, x: float, y: float) -> Dictionary:
	return {"number": number, "x_mm": x, "y_mm": y,
		"drill_mm": 0.8, "annulus_diameter_mm": 1.6}


## One 0.6mm square land of the target part — SMD, and therefore TOP only.
func _lga_pin(number: String, x: float, y: float) -> Dictionary:
	return {"number": number, "x_mm": x, "y_mm": y,
		"pad_width_mm": 0.6, "pad_height_mm": 0.6}


func _lga_board() -> Dictionary:
	return {
		"version": 1, "name": "LgaBusBoard", "width_mm": 60.0, "height_mm": 60.0,
		"grid_mm": 2.54,
		"layers": ["top", "bottom"],
		"design_rules": {"clearance_mm": LGA_CLEARANCE_MM, "trace_width_mm": 0.2},
		"components": [
			{"ref": "U1", "footprint": "IC_DIP", "x_mm": 10.0, "y_mm": 10.0,
				"rotation_deg": 0.0, "pins": [
					_tht_pin("1", 0.0, 0.0), _tht_pin("2", 0.0, 2.54),
					_tht_pin("3", 0.0, 5.08)]},
			{"ref": "T1", "footprint": "IC_DIP", "x_mm": 30.0, "y_mm": 28.0,
				"rotation_deg": 0.0, "pins": [
					_lga_pin("1", -1.0, -2.0), _lga_pin("2", -1.0, 0.0),
					_lga_pin("3", 1.0, -2.0), _lga_pin("4", 1.0, 0.0)]},
		],
		"nets": [
			{"name": "NA", "pins": ["U1.1", "T1.4"]},
			{"name": "NB", "pins": ["U1.2", "T1.2"]},
			{"name": "FGND", "pins": ["U1.3", "T1.1"]},
			{"name": "FVCC", "pins": ["T1.3"]},
		],
	}


## The LGA board with its two pieces of PRE-EXISTING foreign copper seeded on.
## Returns [data, via_id, trace_id] — the two ids are minted by the model, so
## the expected finding set below is built from what the board says they are
## rather than from a spelling this file guesses.
func _lga_rig_data() -> Array:
	var data := PCBData.new()
	data.from_board_dict(_lga_board())
	var via_id := str(data.add_via({"position": LGA_VIA_AT, "net_name": "FVCC",
		"size": 0.8, "drill": 0.4, "from_layer": "top", "to_layer": "bottom"}))
	var trace = data.create_trace_entity("FGND", "top",
		PackedVector2Array([Vector2(32.0, 27.0), Vector2(30.0, 27.0)]), 0.25)
	# The seed is its own undo step. from_board_dict leaves ONE history entry
	# ("Load"), taken before this copper existed, so without a second one the
	# bus's undo would step past the seeded via and trace as well and the "one
	# undo removes the bus" check below would be measuring the wrong thing.
	data.save_to_history("Seed foreign copper")
	return [data, via_id, str(trace.id) if trace != null else ""]


## The plan the whole section measures, on `layer`.
func _lga_plan(data, layer: String) -> Dictionary:
	return PanelToolsScript.bus_plan(
		data, ["NA", "NB"],
		PackedVector2Array([LGA_PATH_1, LGA_PATH_2, LGA_PATH_3]), layer,
		PackedStringArray(["U1.1", "U1.2"]), PackedStringArray(["T1.4", "T1.2"]))


## Every finding in a plan, as sorted "<type>|<bus net>|<foreign item>" keys —
## the shape the expected sets below are written in. A finding of any OTHER type
## keys on its type alone, so an unexpected rule break cannot hide inside a
## comparison that only looks at foreign copper.
func _finding_keys(findings: Array) -> Array:
	var keys: Array = []
	for raw in findings:
		var f: Dictionary = raw
		var type := str(f.get("type", ""))
		if type != FOREIGN:
			keys.append(type)
			continue
		var nets: Array = f.get("nets", []) if f.get("nets", []) is Array else []
		keys.append("%s|%s|%s" % [type, str(nets[0]) if not nets.is_empty() else "",
			str(f.get("foreign_ref", ""))])
	keys.sort()
	return keys


func _findings_of(plan: Dictionary) -> Array:
	return plan.get("findings", []) if plan.get("findings", []) is Array else []


## The one finding naming `ref`, or {} — so an assertion can talk about a
## specific piece of copper rather than about "some finding".
func _finding_naming(findings: Array, ref: String) -> Dictionary:
	for raw in findings:
		var f: Dictionary = raw
		if str(f.get("foreign_ref", "")) == ref:
			return f
	return {}


func _test_foreign_copper_is_named_and_still_lands() -> void:
	print("\n-- (13) bus copper on another net's pad/via/trace is named --")
	check("the type this suite pins is the type the tool emits",
			PanelToolsScript.BUS_FINDING_FOREIGN_COPPER == FOREIGN,
			str(PanelToolsScript.BUS_FINDING_FOREIGN_COPPER))
	var rig := _lga_rig_data()
	var data = rig[0]
	var via_id: String = rig[1]
	var trace_id: String = rig[2]
	check("the fixture seeded a foreign via and a foreign trace",
			not via_id.is_empty() and not trace_id.is_empty()
				and _serialized_traces(data).size() == 1,
			"via=%s trace=%s traces=%d" % [via_id, trace_id, _serialized_traces(data).size()])

	var plan: Dictionary = _lga_plan(data, "top")
	check("the plan is BAD BUT BUILDABLE, and complete",
			not bool(plan.get("ok", true)) and bool(plan.get("buildable", false))
				and bool(plan.get("complete", false)),
			str(plan.get("error", "")))

	var findings: Array = _findings_of(plan)
	var expected: Array = [
		"%s|NA|T1.3" % FOREIGN,        # the LGA pad NA's leg runs down through
		"%s|NA|%s" % [FOREIGN, trace_id],
		"%s|NA|%s" % [FOREIGN, via_id],
		"%s|NB|T1.1" % FOREIGN,        # the LGA pad NB's leg runs down through
	]
	expected.sort()
	check("the four pieces of foreign copper are named, and nothing else broke",
			_finding_keys(findings) == expected,
			"got %s want %s" % [str(_finding_keys(findings)), str(expected)])

	var pad_hit: Dictionary = _finding_naming(findings, "T1.3")
	check("the pad finding names the bus net, the pad, ITS net and the layer",
			str(pad_hit.get("message", "")).contains("NA")
				and str(pad_hit.get("message", "")).contains("T1.3")
				and str(pad_hit.get("message", "")).contains("FVCC")
				and str(pad_hit.get("layer", "")) == "top"
				and str(pad_hit.get("foreign_net", "")) == "FVCC",
			str(pad_hit))
	check("…and calls overlapping copper a short, not a gap",
			float(pad_hit.get("measured_mm", 1.0)) <= 0.0
				and str(pad_hit.get("message", "")).contains("one piece of copper"),
			str(pad_hit.get("message", "")))
	check("…carrying a witness the ghost renderer can draw",
			(pad_hit.get("closest", []) as Array).size() == 2
				and (pad_hit.get("witness", []) as Array).size() == 2
				and (pad_hit.get("midpoint", []) as Array).size() == 2,
			str(pad_hit))

	var via_hit: Dictionary = _finding_naming(findings, via_id)
	check("the via finding measures the gap the fixture builds, against the board's rule",
			absf(float(via_hit.get("measured_mm", 0.0)) - LGA_VIA_GAP_MM) <= 1e-3
				and absf(float(via_hit.get("required_mm", 0.0)) - LGA_CLEARANCE_MM) <= 1e-3,
			"measured=%s required=%s" % [str(via_hit.get("measured_mm", "")),
				str(via_hit.get("required_mm", ""))])
	check("…and reads as a clearance miss, not a short",
			str(via_hit.get("message", "")).contains("runs")
				and str(via_hit.get("message", "")).contains("FVCC"),
			str(via_hit.get("message", "")))

	# THE LAYER RULE. The target part's lands are SMD and the seeded trace is on
	# top; only the via and the through-hole source column cross the stack. The
	# two top-only TARGET pads are then under legs on bottom, which is the
	# off-layer rule's own case (14) and keys on its type alone here.
	var below: Dictionary = _lga_plan(data, "bottom")
	var below_expected: Array = ["%s|NA|%s" % [FOREIGN, via_id], OFF_LAYER, OFF_LAYER]
	below_expected.sort()
	check("on the other layer only the through-the-stack copper is still foreign",
			_finding_keys(_findings_of(below)) == below_expected,
			str(_finding_keys(_findings_of(below))))

	# THE CONTROL. Section 1's fixture routes a clean bus past pads on three
	# other nets; this rule must not start refusing it.
	var clean_data := PCBData.new()
	clean_data.from_board_dict(_board())
	var clean: Dictionary = PanelToolsScript.bus_plan(
		clean_data, ["NA", "NB", "NC"], PackedVector2Array([PATH_1, PATH_2]), "top",
		PackedStringArray(["U1.1", "U2.1", "U3.1"]),
		PackedStringArray(["V1.1", "V2.1", "V3.1"]))
	check("the clean fixture bus gains no foreign-copper finding",
			bool(clean.get("ok", false)) and _findings_of(clean).is_empty(),
			str(clean.get("error", "")))


func _test_foreign_copper_reaches_the_agent_the_gesture_and_the_ghost() -> void:
	print("\n-- (13b) …and reaches the verb, the status line and the ghosts --")

	# THE VERB: the copper lands anyway, and the findings come back with it.
	var rig := _lga_rig_data()
	var data = rig[0]
	var via_id: String = rig[1]
	var host := StubMcpHost.new()
	host.data = data
	var quiet := _board_state(data)
	var result: Dictionary = await PanelToolsScript.handle(host, "minerva_pcb_route_bus_direct", {
		"editor_name": "PCB1", "nets": ["NA", "NB"],
		"sources": ["U1.1", "U1.2"], "targets": ["T1.4", "T1.2"],
		"points": [{"x_mm": LGA_PATH_1.x, "y_mm": LGA_PATH_1.y},
			{"x_mm": LGA_PATH_2.x, "y_mm": LGA_PATH_2.y},
			{"x_mm": LGA_PATH_3.x, "y_mm": LGA_PATH_3.y}],
		"layer": "top",
	})
	check("the verb reports success — the copper landed", bool(result.get("success", false)),
			str(result))
	check("…2 bus traces on top of the seeded one, in ONE journal step",
			_serialized_traces(data).size() == int(quiet[0]) + 2
				and data.history.size() == int(quiet[1]) + 1,
			"board %s (was %s)" % [str(_board_state(data)), str(quiet)])
	var reply_keys := _finding_keys(result.get("findings", []) as Array)
	check("…and the reply carries all four foreign-copper findings",
			reply_keys.size() == 4 and str(reply_keys[0]).begins_with(FOREIGN),
			str(reply_keys))
	check("…with the note telling the caller it landed anyway",
			str(result.get("note", "")).contains("landed anyway")
				and str(result.get("note", "")).contains("T1.3"),
			str(result.get("note", "")))
	# THE WHOLE REPLY, not just `note`: the agent reads every field, so a start-
	# layer suggestion re-entering the verb on ANY key is caught here.
	check("…and no field of the reply advises a layer to start the bus on",
			not str(result).contains("start it on")
				and not str(result).contains("Layer chooser"),
			str(result))
	check("one undo removes the bus and leaves the seeded copper",
			data.undo() and _serialized_traces(data).size() == int(quiet[0]))

	# THE GESTURE: the same bus drawn by hand, reported in the status line.
	var gesture_rig := _lga_rig_data()
	var gesture_data = gesture_rig[0]
	var canvas = PcbCanvasScript.new()
	canvas.data = gesture_data
	canvas.zoom = 8.0
	canvas.snap_to_grid = false
	var pad_host := StubPadHost.new()
	pad_host.pads = [
		{"component": "U1", "pin": "1", "position": LGA_SRC_A},
		{"component": "U1", "pin": "2", "position": LGA_SRC_B},
		{"component": "U1", "pin": "3", "position": Vector2(10.0, 15.08)},
		{"component": "T1", "pin": "1", "position": Vector2(29.0, 26.0)},
		{"component": "T1", "pin": "2", "position": LGA_TGT_B},
		{"component": "T1", "pin": "3", "position": Vector2(31.0, 26.0)},
		{"component": "T1", "pin": "4", "position": LGA_TGT_A},
	]
	canvas.set_pin_inspector_host(pad_host)
	canvas.set_tool_mode(canvas.ToolMode.BUS)
	var msgs := _collect(canvas)
	canvas._handle_bus_click(LGA_SRC_A, false)    # NA
	canvas._handle_bus_click(LGA_SRC_B, false)    # NB
	# THE LAYER TEACH, read at the two moments it is offered. This is the
	# ORDINARY through-hole-to-SMD bus: U1's sources are through-hole (copper
	# both sides) and every T1 land is F.Cu-only, so the path as drawn reaches
	# its targets. Nothing may be said here about starting on the other side —
	# which side such a bus runs on is the designer's call, not the tool's — and
	# the teach line still has to teach the gesture it always taught.
	var sources_teach: String = canvas.bus_teach_line()
	canvas._handle_bus_click(LGA_PATH_1, false)   # ends SOURCES
	var path_began: String = _last(msgs)
	canvas._handle_bus_click(LGA_PATH_2, false)
	canvas._handle_bus_click(LGA_PATH_3, false)
	canvas._handle_bus_click(LGA_TGT_A, false)    # ends PATH, target NA
	canvas._handle_bus_click(LGA_TGT_B, false)    # target NB
	canvas._commit_bus()
	check("the gesture committed the same two traces, and NEITHER moment "
			+ "advised a start layer for a bus whose targets it can already reach",
			_serialized_traces(gesture_data).size() == 3
				and sources_teach.contains("2 nets picked")
				and sources_teach.contains("rings mark where each may end")
				and not sources_teach.contains("start it on")
				and not sources_teach.contains("Layer chooser")
				and path_began.contains("Path for [NA → NB] on F.Cu")
				and not path_began.contains("start it on")
				and not path_began.contains("Layer chooser"),
			"%s || teach: %s || began: %s" % [str(_board_state(gesture_data)),
				sources_teach, path_began])
	check("the status line names the foreign pad, its net and the pad NB crosses",
			_last(msgs).contains("T1.3") and _last(msgs).contains("FVCC")
				and _last(msgs).contains("T1.1"), _last(msgs))
	check("…and still says the copper landed so it can be corrected",
			_last(msgs).contains("Added bus") and _last(msgs).contains("correct"),
			_last(msgs))
	canvas.free()

	# THE GHOSTS: each candidate carries the findings that name ITS net.
	var ghost_rig := _lga_rig_data()
	var ghost_data = ghost_rig[0]
	var ghost_via: String = ghost_rig[1]
	var ws = PcbRoutingWorkspace.new()
	var plan: Dictionary = _lga_plan(ghost_data, "top")
	var before := _board_state(ghost_data)
	var out: Dictionary = PanelToolsScript.bus_propose_plan(ws, ghost_data, plan)
	check("both ghosts landed and the board is untouched",
			int(out.get("proposed", 0)) == 2 and _board_state(ghost_data) == before,
			"%s / %s" % [str(out.get("error", "")), str(_board_state(ghost_data))])
	var per_net := {}
	for cand in ws.list_candidates():
		per_net[str(cand.net)] = _finding_keys(ws.findings_for_candidate(str(cand.candidate_id)))
	check("NA's ghost carries its three and NB's carries its one",
			(per_net.get("NA", []) as Array).size() == 3
				and (per_net.get("NB", []) as Array) == ["%s|NB|T1.1" % FOREIGN],
			str(per_net))
	check("…and NA's own via finding is filed under NA",
			("%s|NA|%s" % [FOREIGN, ghost_via]) in (per_net.get("NA", []) as Array),
			str(per_net.get("NA", [])))


# ── 14. A BUS LEG THAT LANDS ON A LAYER ITS OWN PAD IS NOT ON ────────────────
#
# THE LIVE DEFECT: a bus on B.Cu from a through-hole column to an SMD part on
# top, with no station. The legs ended on bottom under top-only pads — copper
# that joins nothing, an open — and the tool said nothing; connectivity DRC
# found the dangling ends afterwards.
#
# THE FIXTURE is section 13's LGA board: U1's pins are through-hole, T1's lands
# are 0.6mm SMD squares on the side T1 is placed on (top). The same bus planned
# on bottom is the defect; the same bus with a station back to top is not.
#
# ORACLES:
#   THE FINDING — one per top-only target pad, naming the pad, the layers it
#     IS on and the layer the leg lands on, read against the fixture's own
#     facts (T1.4 and T1.2; top; bottom) and never a through-hole source pad.
#   THE STATION — a station to top makes the target legs land on top, so no
#     off-layer finding remains; buildable, so the geometry itself is not the
#     reason the finding went away.
#   THE BOARD — trace count and history either side of the verb: the copper
#     still lands, in one journal step, with the findings in the reply.

## The spine of the station variant: section 13's LGA path with a straight
## interior vertex between its first two, for the station to sit on.
const LGA_STATION_AT := Vector2(26.0, 10.0)


## The off-layer findings of `findings`, keyed by the pad each one names.
func _off_layer_by_pad(findings: Array) -> Dictionary:
	var out: Dictionary = {}
	for raw in findings:
		var f: Dictionary = raw
		if str(f.get("type", "")) == OFF_LAYER:
			out[str(f.get("pad_ref", ""))] = f
	return out


func _test_a_leg_on_a_layer_its_pad_is_not_on_is_named() -> void:
	print("\n-- (14) a leg landing on a layer its own pad has no copper on is named --")
	check("the type this suite pins is the type the tool emits",
			PanelToolsScript.BUS_FINDING_PAD_OFF_LAYER == OFF_LAYER,
			str(PanelToolsScript.BUS_FINDING_PAD_OFF_LAYER))
	var data := PCBData.new()
	data.from_board_dict(_lga_board())

	var below: Dictionary = _lga_plan(data, "bottom")
	check("the bottom bus is BAD BUT BUILDABLE",
			not bool(below.get("ok", true)) and bool(below.get("buildable", false)),
			str(below.get("error", "")))
	var by_pad := _off_layer_by_pad(_findings_of(below))
	var pads: Array = by_pad.keys()
	pads.sort()
	check("exactly the two top-only target pads are named, never the through-hole sources",
			pads == ["T1.2", "T1.4"], str(pads))
	var hit: Dictionary = by_pad.get("T1.4", {})
	check("the finding names the bus net, the pad, its copper layers and the landing layer",
			str(hit.get("message", "")).contains("NA")
				and str(hit.get("message", "")).contains("T1.4")
				and str(hit.get("message", "")).contains("top")
				and str(hit.get("message", "")).contains("bottom")
				and (hit.get("pad_layers", []) as Array) == ["top"]
				and str(hit.get("layer", "")) == "bottom"
				and str(hit.get("net_name", "")) == "NA",
			str(hit))
	check("…calls it an open and says how a station fixes it",
			str(hit.get("message", "")).contains("open")
				and str(hit.get("message", "")).contains("Layer chooser")
				and str(hit.get("message", "")).contains("via_station_layer"),
			str(hit.get("message", "")))
	check("…carrying a witness at the pad the ghost renderer can draw",
			(hit.get("closest", []) as Array).size() == 2
				and absf(float((hit.get("closest", [0, 0]) as Array)[0]) - LGA_TGT_A.x) <= EPS
				and absf(float((hit.get("closest", [0, 0]) as Array)[1]) - LGA_TGT_A.y) <= EPS,
			str(hit.get("closest", [])))

	# THE CONTROL on the same layer: T1's lands are on top, so a top bus lands
	# every leg on copper. Section 13 already pins its foreign-copper set.
	check("the same bus on top raises no off-layer finding",
			_off_layer_by_pad(_findings_of(_lga_plan(data, "top"))).is_empty(),
			str(_finding_keys(_findings_of(_lga_plan(data, "top")))))

	# THE STATION: bottom out of the through-hole column, up to top before the
	# SMD part. The target legs are then on the pads' own layer.
	var stationed: Dictionary = PanelToolsScript.bus_plan(
		data, ["NA", "NB"],
		PackedVector2Array([LGA_PATH_1, LGA_STATION_AT, LGA_PATH_2, LGA_PATH_3]), "bottom",
		PackedStringArray(["U1.1", "U1.2"]), PackedStringArray(["T1.4", "T1.2"]),
		0.0, 1, "top")
	check("with a station to top the plan is buildable and no off-layer finding remains",
			bool(stationed.get("buildable", false))
				and _off_layer_by_pad(_findings_of(stationed)).is_empty(),
			"error=%s findings=%s" % [str(stationed.get("error", "")),
				str(_finding_keys(_findings_of(stationed)))])

	# AN UNPLATED HOLE IS NOT COPPER. A pin whose only land is np_thru_hole has
	# no barrel and no ring, so it is on no layer: as a bus anchor it is off
	# every layer, and as board copper it is nothing a bus can be foreign to.
	var npth = ComponentScript.from_dict({"id": "H1", "name": "H1", "position": {"x": 5.0, "y": 5.0},
		"pads": [{"number": "1", "type": "np_thru_hole", "shape": "circle",
			"position": {"x": 0.0, "y": 0.0}, "size": {"width": 3.0, "height": 3.0},
			"drill": {"x": 3.0, "y": 3.0}, "layers": ["F.Cu", "B.Cu"]}]})
	var copper: Dictionary = PanelToolsScript._bus_pad_layers(npth, "1")
	check("an np_thru_hole land is known-no-copper, on no layer",
			bool(copper.get("no_copper", false)) and not bool(copper.get("all_layers", true))
				and (copper.get("layers", {}) as Dictionary).is_empty(),
			str(copper))
	var npth_hits: Array = PanelToolsScript._bus_pad_off_layer_findings(
		[{"ref": "H1.1", "net": "NA", "centre": Vector2(5.0, 5.0),
			"all_layers": false, "layers": {}, "no_copper": true}], "top", "target")
	check("…so a leg landing on it is named off-layer, as an unplated hole",
			npth_hits.size() == 1
				and str((npth_hits[0] as Dictionary).get("message", "")).contains("unplated")
				and str((npth_hits[0] as Dictionary).get("pad_ref", "")) == "H1.1",
			str(npth_hits))


func _test_an_off_layer_leg_reaches_the_agent() -> void:
	print("\n-- (14b) …and the verb lands the copper and returns the finding --")
	var data := PCBData.new()
	data.from_board_dict(_lga_board())
	var host := StubMcpHost.new()
	host.data = data
	var quiet := _board_state(data)
	var result: Dictionary = await PanelToolsScript.handle(host, "minerva_pcb_route_bus_direct", {
		"editor_name": "PCB1", "nets": ["NA", "NB"],
		"sources": ["U1.1", "U1.2"], "targets": ["T1.4", "T1.2"],
		"points": [{"x_mm": LGA_PATH_1.x, "y_mm": LGA_PATH_1.y},
			{"x_mm": LGA_PATH_2.x, "y_mm": LGA_PATH_2.y},
			{"x_mm": LGA_PATH_3.x, "y_mm": LGA_PATH_3.y}],
		"layer": "bottom",
	})
	check("the verb reports success — the copper landed", bool(result.get("success", false)),
			str(result))
	check("…2 bus traces, in ONE journal step",
			_serialized_traces(data).size() == int(quiet[0]) + 2
				and data.history.size() == int(quiet[1]) + 1,
			"board %s (was %s)" % [str(_board_state(data)), str(quiet)])
	var by_pad := _off_layer_by_pad(result.get("findings", []) as Array)
	var pads: Array = by_pad.keys()
	pads.sort()
	check("…and the reply names both top-only target pads", pads == ["T1.2", "T1.4"], str(pads))
	check("…with the note telling the caller it landed anyway, naming a pad and the station args",
			str(result.get("note", "")).contains("landed anyway")
				and str(result.get("note", "")).contains("T1.4")
				and str(result.get("note", "")).contains("via_station_index"),
			str(result.get("note", "")))


## A through via touches every copper layer, so what it lands on is named on
## THAT copper's own layer. The pad sits beside the run, not under it: the
## via's 0.4mm radius reaches its edge and the 0.125mm half-track plus 0.2mm
## clearance does not, so only the via can be the finding — a run-layer stamp
## cannot hide behind a track-layer one.
func _test_a_station_via_names_the_layer_it_lands_on() -> void:
	print("\n-- (13c) a station via's finding is on the copper's layer, not the bus's --")
	var via_at := Vector2(40.0, 40.0)
	for side in ["bottom", "top"]:
		var board := _lga_board()
		(board["components"] as Array).append({"ref": "B1", "footprint": "IC_DIP",
			"x_mm": via_at.x, "y_mm": via_at.y + 0.68, "rotation_deg": 0.0,
			"layer": side, "pins": [_lga_pin("1", 0.0, 0.0)]})
		(board["nets"] as Array).append({"name": "FSIDE", "pins": ["B1.1"]})
		var data := PCBData.new()
		data.from_board_dict(board)
		var findings: Array = PanelToolsScript._bus_foreign_copper_findings(
			data, PackedStringArray(["NA"]), [0.25],
			[PackedVector2Array([via_at - Vector2(10.0, 0.0), via_at, via_at + Vector2(10.0, 0.0)])],
			"top", "bottom", [1], [via_at], 0.8, LGA_CLEARANCE_MM)
		var hit := _finding_naming(findings, "B1.1")
		check("the %s-only pad beside the station is found once, by the via" % side,
			findings.size() == 1 and not hit.is_empty(), str(_finding_keys(findings)))
		check("…and the finding says %s" % side,
			str(hit.get("layer", "")) == side, str(hit.get("layer", "")))


# ── 13e. A STATION VIA THAT WALLS A PAD OFF ───────────────────────────────────
#
# THE LIVE DEFECT: a station's vias sat one clearance from a foreign pad's edge.
# Legal copper, and the pad could no longer be reached from that side. The
# foreign-copper pass measures clearance and was rightly silent.
#
# THE FIXTURE is the LGA board with a station at (26,10) on the straight first
# run, bottom to top. 0.2mm tracks at 0.2mm clearance and the 0.8mm fallback
# via give a 1.0mm via pitch, laid at 1.01, so the two vias sit at (26, 9.495)
# for NA and (26, 10.505) for NB, ring edges 0.4mm out. A 0.6mm square land
# P1.1 on its own net is placed on the station's own column BELOW NB's via,
# its top edge y 10.905 + gap: at gap 0.25 the ring and the land clear the
# 0.2mm rule and not the 0.2 + 2 x 0.2 = 0.6mm corridor; at gap 0.7 they clear
# both. NB's own copper past the station lies at y <= 10.61, so the land is
# never a foreign-copper hit itself.
#
# ORACLES: the finding's pad, net, measured and required, read against those
# hand-derived figures; its absence at 0.7; and the board triple plus via count
# through the verb — the station still lands.

## P1's pin centre for a given ring-to-land gap: NB's via top edge (10.905) plus
## the gap plus half the 0.6mm land.
func _crowd_board(gap: float) -> Dictionary:
	var board := _lga_board()
	(board["components"] as Array).append({"ref": "P1", "footprint": "IC_DIP",
		"x_mm": LGA_STATION_AT.x, "y_mm": 10.905 + gap + 0.3, "rotation_deg": 0.0,
		"pins": [_lga_pin("1", 0.0, 0.0)]})
	(board["nets"] as Array).append({"name": "FP", "pins": ["P1.1"]})
	return board


func _crowd_findings(gap: float) -> Array:
	var data := PCBData.new()
	data.from_board_dict(_crowd_board(gap))
	var plan: Dictionary = PanelToolsScript.bus_plan(
		data, ["NA", "NB"],
		PackedVector2Array([LGA_PATH_1, LGA_STATION_AT, LGA_PATH_2, LGA_PATH_3]), "bottom",
		PackedStringArray(["U1.1", "U1.2"]), PackedStringArray(["T1.4", "T1.2"]),
		0.0, 1, "top")
	var out: Array = []
	for raw in _findings_of(plan):
		if str((raw as Dictionary).get("type", "")) == CROWDS:
			out.append(raw)
	return out


func _test_a_station_that_walls_a_pad_off_is_named() -> void:
	print("\n-- (13e) a station via one clearance from a pad walls it off, and says so --")
	check("the type this suite pins is the type the tool emits",
			PanelToolsScript.BUS_FINDING_STATION_CROWDS_PAD == CROWDS,
			str(PanelToolsScript.BUS_FINDING_STATION_CROWDS_PAD))
	var crowded := _crowd_findings(0.25)
	check("the land 0.25mm from NB's ring is named once, by NB",
			crowded.size() == 1
				and str((crowded[0] as Dictionary).get("foreign_ref", "")) == "P1.1"
				and str((crowded[0] as Dictionary).get("foreign_net", "")) == "FP"
				and str((crowded[0] as Dictionary).get("net_name", "")) == "NB",
			str(crowded))
	var hit: Dictionary = crowded[0] if not crowded.is_empty() else {}
	check("…measuring 0.25mm against the 0.6mm corridor",
			absf(float(hit.get("measured_mm", 0.0)) - 0.25) <= 1e-3
				and absf(float(hit.get("required_mm", 0.0)) - 0.6) <= 1e-3,
			"measured=%s required=%s" % [str(hit.get("measured_mm", "")), str(hit.get("required_mm", ""))])
	check("…saying the pad is walled off and that the station should move along the spine",
			str(hit.get("message", "")).contains("P1.1")
				and str(hit.get("message", "")).contains("walls")
				and str(hit.get("message", "")).contains("along the spine"),
			str(hit.get("message", "")))
	check("…with a witness from NB's via to the land",
			(hit.get("closest", []) as Array).size() == 2
				and absf(float((hit.get("closest", [0, 0]) as Array)[0]) - 26.0) <= EPS
				and absf(float((hit.get("closest", [0, 0]) as Array)[1]) - 10.505) <= EPS
				and (hit.get("witness", []) as Array).size() == 2,
			str(hit))
	check("the same land 0.7mm away is not named", _crowd_findings(0.7).is_empty(),
			str(_crowd_findings(0.7)))


func _test_a_crowding_station_still_lands() -> void:
	print("\n-- (13f) …and the verb still drops the station, returning the finding --")
	var data := PCBData.new()
	data.from_board_dict(_crowd_board(0.25))
	var host := StubMcpHost.new()
	host.data = data
	var quiet := _board_state(data)
	var result: Dictionary = await PanelToolsScript.handle(host, "minerva_pcb_route_bus_direct", {
		"editor_name": "PCB1", "nets": ["NA", "NB"],
		"sources": ["U1.1", "U1.2"], "targets": ["T1.4", "T1.2"],
		"points": [{"x_mm": LGA_PATH_1.x, "y_mm": LGA_PATH_1.y},
			{"x_mm": LGA_STATION_AT.x, "y_mm": LGA_STATION_AT.y},
			{"x_mm": LGA_PATH_2.x, "y_mm": LGA_PATH_2.y},
			{"x_mm": LGA_PATH_3.x, "y_mm": LGA_PATH_3.y}],
		"layer": "bottom", "via_station_index": 1, "via_station_layer": "top",
	})
	check("the verb reports success — the station landed", bool(result.get("success", false)),
			str(result))
	check("…4 traces and 2 vias, in ONE journal step",
			_serialized_traces(data).size() == int(quiet[0]) + 4
				and _serialized_vias(data).size() == 2
				and data.history.size() == int(quiet[1]) + 1,
			"board %s (was %s) vias %d" % [str(_board_state(data)), str(quiet),
				_serialized_vias(data).size()])
	var named := false
	for raw in result.get("findings", []) as Array:
		if str((raw as Dictionary).get("type", "")) == CROWDS \
				and str((raw as Dictionary).get("foreign_ref", "")) == "P1.1":
			named = true
	check("…and the reply names the walled-off pad, in the note too",
			named and str(result.get("note", "")).contains("P1.1"),
			str(result.get("note", "")))


# ── 13g. THE JOURNAL SAYS WHAT STOOD AT COMMIT ────────────────────────────────
#
# The model journals one add_trace row per trace it creates; those rows say
# nothing about the bus they belong to. bus_commit_plan appends ONE more row
# per bus carrying the finding types with counts, the copper they name, and
# the ids created — so the journal can say afterwards which findings stood
# when the copper landed.
#
# ORACLES: the newest row read through the verb's own accessor (and the verb),
# against section 13's known finding set on the seeded LGA board (four
# foreign-copper findings naming T1.3 and T1.1 among them) and against the
# clean section-1 bus (a row with zero findings). The add_trace rows are still
# there, one per trace, ahead of it.

## The newest journal row, as the verb reads it.
func _newest_journal_row(data) -> Dictionary:
	var rows: Array = data.get_change_journal()
	return rows[rows.size() - 1] if not rows.is_empty() else {}


func _test_the_journal_records_what_stood_at_commit() -> void:
	print("\n-- (13g) a bus commit journals its findings and ids in one row --")
	var rig := _lga_rig_data()
	var data = rig[0]
	var before: int = data.change_journal.size()
	var plan: Dictionary = _lga_plan(data, "top")
	var result: Dictionary = PanelToolsScript.bus_commit_plan(data, plan, "Add bus (2 nets)")
	check("the bad-but-buildable bus committed", bool(result.get("ok", false)),
			str(result.get("error", "")))
	check("the journal grew by the two add_trace rows plus ONE bus row",
			data.change_journal.size() == before + 3,
			"grew by %d" % (data.change_journal.size() - before))
	var row := _newest_journal_row(data)
	var details: Dictionary = row.get("details", {})
	check("the newest row is the bus row", str(row.get("action", "")) == "add_bus", str(row))
	check("…counting the four foreign-copper findings and nothing else",
			details.get("finding_types", {}) == {FOREIGN: 4}
				and int(details.get("finding_count", -1)) == 4,
			str(details.get("finding_types", {})))
	var named: Array = []
	for raw in details.get("findings", []) as Array:
		named.append(str((raw as Dictionary).get("foreign_ref", "")))
	check("…naming the two pads the legs ran through",
			"T1.3" in named and "T1.1" in named, str(named))
	check("…and carrying the nets, the layer and the two trace ids it created",
			(details.get("nets", []) as Array) == ["NA", "NB"]
				and str(details.get("layer", "")) == "top"
				and (details.get("trace_ids", []) as Array) == (result.get("trace_ids", []) as Array)
				and (details.get("trace_ids", []) as Array).size() == 2
				and (details.get("via_ids", []) as Array).is_empty(),
			str(details))
	var rows: Array = data.get_change_journal()
	check("the add_trace rows before it keep their shape",
			rows.size() >= 3
				and str((rows[rows.size() - 2] as Dictionary).get("action", "")) == "add_trace"
				and str((rows[rows.size() - 3] as Dictionary).get("action", "")) == "add_trace",
			str(rows.slice(maxi(0, rows.size() - 3))))
	check("one undo still removes the bus", data.undo() and _serialized_traces(data).size() == 1)

	# THE CLEAN BUS: the row exists with zero findings, so its presence is a
	# record, not a verdict. Read through the MCP verb this time.
	var clean_data := PCBData.new()
	clean_data.from_board_dict(_board())
	var host := StubMcpHost.new()
	host.data = clean_data
	var landed: Dictionary = await PanelToolsScript.handle(host, "minerva_pcb_route_bus_direct", {
		"editor_name": "PCB1", "nets": ["NA", "NB", "NC"],
		"sources": ["U1.1", "U2.1", "U3.1"], "targets": ["V1.1", "V2.1", "V3.1"],
		"points": [{"x_mm": PATH_1.x, "y_mm": PATH_1.y}, {"x_mm": PATH_2.x, "y_mm": PATH_2.y}],
		"layer": "top",
	})
	check("the clean bus landed with no findings",
			bool(landed.get("success", false)) and (landed.get("findings", []) as Array).is_empty(),
			str(landed))
	var read: Dictionary = await PanelToolsScript.handle(host, "minerva_pcb_get_change_journal", {
		"editor_name": "PCB1", "limit": 1})
	var entries: Array = read.get("entries", []) if read.get("entries", []) is Array else []
	var clean_row: Dictionary = entries[0] if not entries.is_empty() else {}
	var clean_details: Dictionary = clean_row.get("details", {})
	check("the verb's newest entry is the bus row, with zero findings and three trace ids",
			str(clean_row.get("action", "")) == "add_bus"
				and int(clean_details.get("finding_count", -1)) == 0
				and (clean_details.get("finding_types", {}) as Dictionary).is_empty()
				and (clean_details.get("trace_ids", []) as Array).size() == 3
				and (clean_details.get("nets", []) as Array) == ["NA", "NB", "NC"],
			str(clean_row))


# ── 13d. THE ONE START-LAYER NOTE LEFT ────────────────────────────────────────
#
# The bus tool says which layer to START on in exactly one case: NO candidate
# target has copper on the working layer and they all sit on one other layer.
# The bus as drawn cannot land at all — a geometric fact about the board, not a
# preference about how to route it.
#
# ORACLES:
#   THE TEACH/STATUS STRINGS — read at BOTH moments the note is offered (the
#     SOURCES teach line, and the message emitted as the first path click
#     freezes the layer), required to name the working layer, the side every
#     target is on, and the chooser that fixes it.
#   THE SAME BOARD WITH THE CHOOSER TAKEN — working layer B.Cu, where the very
#     same pads ARE reachable flat and the note must go silent. This is the half
#     that fails if the note ever fires on a bus that can land.
#   THE BOARD TRIPLE — traces/history/journal, unchanged while the note is only
#     advice, then +2 traces in ONE journal step once the B.Cu bus commits.

## The LGA board with the target part flipped onto the BOTTOM side: every T1
## land is then B.Cu-only, while U1's through-hole sources still reach both.
func _bottom_target_board() -> Dictionary:
	var board := _lga_board()
	for raw_comp in (board["components"] as Array):
		var comp: Dictionary = raw_comp
		if str(comp.get("ref", "")) == "T1":
			comp["layer"] = "bottom"
	return board


## [canvas, data] on that board, bus tool live, working layer set BEFORE any
## pick so the chooser is the only thing that differs between the two halves.
func _bottom_target_rig(layer: String) -> Array:
	var data := PCBData.new()
	data.from_board_dict(_bottom_target_board())
	var canvas = PcbCanvasScript.new()
	canvas.data = data
	canvas.zoom = 8.0
	canvas.snap_to_grid = false
	var pad_host := StubPadHost.new()
	pad_host.pads = [
		{"component": "U1", "pin": "1", "position": LGA_SRC_A},
		{"component": "U1", "pin": "2", "position": LGA_SRC_B},
		{"component": "T1", "pin": "2", "position": LGA_TGT_B},
		{"component": "T1", "pin": "4", "position": LGA_TGT_A},
	]
	canvas.set_pin_inspector_host(pad_host)
	canvas.set_tool_mode(canvas.ToolMode.BUS)
	canvas.working_layer = layer
	return [canvas, data]


func _test_unreachable_targets_still_name_the_layer_to_start_on() -> void:
	print("\n-- (13d) targets with no copper on the working layer name the chooser --")
	var rig := _bottom_target_rig("top")
	var canvas = rig[0]
	var data = rig[1]
	var msgs := _collect(canvas)
	var quiet := _board_state(data)
	canvas._handle_bus_click(LGA_SRC_A, false)    # NA
	canvas._handle_bus_click(LGA_SRC_B, false)    # NB
	var sources_teach: String = canvas.bus_teach_line()
	canvas._handle_bus_click(LGA_PATH_1, false)   # ends SOURCES — freezes F.Cu
	var path_began: String = _last(msgs)
	check("the SOURCES teach line names the working layer, the side every target "
			+ "is on, and the chooser that fixes it",
			sources_teach.contains("No target pad for these nets has copper on F.Cu")
				and sources_teach.contains("every one is on B.Cu")
				and sources_teach.contains("Layer chooser to B.Cu"),
			sources_teach)
	check("…and the same words land again as the first path click freezes the layer",
			path_began.contains("No target pad for these nets has copper on F.Cu")
				and path_began.contains("Layer chooser to B.Cu"),
			path_began)
	check("…having written nothing — this is advice, not a refusal",
			_board_state(data) == quiet, "%s (was %s)" % [str(_board_state(data)), str(quiet)])
	canvas.free()

	# THE CHOOSER TAKEN. Same pads, same clicks, working layer B.Cu: the targets
	# are now reachable flat, so the note goes silent and the bus lands.
	var ok_rig := _bottom_target_rig("bottom")
	var ok_canvas = ok_rig[0]
	var ok_data = ok_rig[1]
	var ok_msgs := _collect(ok_canvas)
	var before := _board_state(ok_data)
	ok_canvas._handle_bus_click(LGA_SRC_A, false)
	ok_canvas._handle_bus_click(LGA_SRC_B, false)
	var ok_teach: String = ok_canvas.bus_teach_line()
	ok_canvas._handle_bus_click(LGA_PATH_1, false)
	var ok_began: String = _last(ok_msgs)
	ok_canvas._handle_bus_click(LGA_PATH_2, false)
	ok_canvas._handle_bus_click(LGA_PATH_3, false)
	ok_canvas._handle_bus_click(LGA_TGT_A, false)
	ok_canvas._handle_bus_click(LGA_TGT_B, false)
	ok_canvas._commit_bus()
	check("on B.Cu the note is silent — and both moments still teach the gesture",
			ok_teach.contains("2 nets picked")
				and not ok_teach.contains("No target pad")
				and not ok_teach.contains("Layer chooser")
				and ok_began.contains("Path for [NA → NB] on B.Cu")
				and not ok_began.contains("No target pad")
				and not ok_began.contains("Layer chooser"),
			"teach: %s || began: %s" % [ok_teach, ok_began])
	check("…and the bus committed its two B.Cu runs in ONE journal step",
			_serialized_traces(ok_data).size() == int(before[0]) + 2
				and ok_data.history.size() == int(before[1]) + 1,
			"board %s (was %s)" % [str(_board_state(ok_data)), str(before)])
	var landed := _traces_by_net_and_layer(ok_data)
	check("…one trace per net, both on bottom",
			landed.has("NA|bottom") and landed.has("NB|bottom"), str(landed.keys()))
	ok_canvas.free()


# ── 15. OPEN-ENDED BUS: a net without a target ends at its lane's end ─────────
#
# The bus is a generator of parallel traces, and an author may land the lanes
# and finish some legs by hand. A net left without a target commits with its
# trace ending OPEN at the end of its lane — a free end — while the landed nets
# route exactly as a bus of just those nets would.
#
# HAND-DERIVED. NA is left open; its lane is the -0.51 offset (y = 19.49) of
# the spine (20,20)->(120,20), so its route is the source leg the full bus
# gives it — (10,10),(21.02,10),(21.02,19.49) — then the lane to the spine's
# end: (120,19.49). With NA out of the target ladder, NB (offset 0) leaves
# FIRST at station 0.0 (x = 120.0) and NC one laid pitch (0.51) inward at
# x = 119.49 — where the full bus had NB at 119.49 and NC at 118.98. NB's leg
# at x = 120 from y = 20 down to 42 sits one laid pitch (0.51) from NA's open
# lane end at (120,19.49), so the clearance rule measures 0.51 against a 0.5
# requirement and raises nothing.
#
# ORACLE: the serialized traces (count, per-net points), data.history, the
# add_bus journal row's open_nets, free_trace_end_at on the model, and the
# status message — the verb section compares its copper to this gesture's.

func _open_routes() -> Dictionary:
	return {
		"NA": [SRC_A, Vector2(21.02, 10.0), Vector2(21.02, 19.49), Vector2(120.0, 19.49)],
		"NB": [SRC_B, Vector2(20.51, 12.0), Vector2(20.51, 20.0),
			Vector2(120.0, 20.0), Vector2(120.0, 42.0), TGT_B],
		"NC": [SRC_C, Vector2(20.0, 14.0), Vector2(20.0, 20.51),
			Vector2(119.49, 20.51), Vector2(119.49, 44.0), TGT_C],
	}


func _test_an_open_lane_commits_as_a_free_end() -> void:
	print("\n-- (15) a net without a target commits with its lane ending open --")
	var rig := _rig()
	var canvas = rig[0]
	var data = rig[1]
	var msgs := _collect(canvas)
	canvas._handle_bus_click(SRC_A, false)
	canvas._handle_bus_click(SRC_B, false)
	canvas._handle_bus_click(SRC_C, false)
	canvas._handle_bus_click(PATH_1, false)
	canvas._handle_bus_click(PATH_2, false)
	canvas._handle_bus_click(TGT_B, false)   # ends PATH, target NB
	canvas._handle_bus_click(TGT_C, false)   # NC landed; NA left open

	# The teach line and the guidance both say NA would end open.
	check("the TARGETS teach line offers the open-ended commit and names NA",
			canvas.bus_teach_line().contains("NA") and canvas.bus_teach_line().to_lower().contains("open"),
			canvas.bus_teach_line())
	var endings: Dictionary = {}
	for row in canvas.bus_target_guidance():
		endings[str(row["net"])] = str(row["ending"])
	check("guidance reads NA -> open, NB -> V2.1, NC -> V3.1",
			endings == {"NA": "open", "NB": "V2.1", "NC": "V3.1"}, str(endings))

	var before := _board_state(data)
	var j0: int = data.change_journal.size()
	_double_click(canvas, EMPTY)             # clear of the pads: the commit
	var by_net := _traces_by_net(data)
	check("three traces landed, one per net", by_net.size() == 3, str(by_net.keys()))
	check("…in ONE history step", data.history.size() == int(before[1]) + 1,
			"history %d (was %d)" % [data.history.size(), int(before[1])])
	var want := _open_routes()
	for net in ["NA", "NB", "NC"]:
		if not by_net.has(net):
			check("bus trace for %s exists" % net, false)
			continue
		_check_route(net, _points_of(by_net[net]), want[net])
	var bus_rows: Array = []
	for e in data.change_journal.slice(j0):
		if str((e as Dictionary).get("action", "")) == "add_bus":
			bus_rows.append(e)
	check("exactly one add_bus journal row, naming NA as the open net",
			bus_rows.size() == 1
				and ((bus_rows[0] as Dictionary).get("details", {}) as Dictionary).get("open_nets", []) == ["NA"],
			str(bus_rows))
	check("the status line says one lane ends open, names NA and the Trace tool",
			_last(msgs).contains("1 lane") and _last(msgs).contains("open")
				and _last(msgs).contains("NA") and _last(msgs).contains("Trace tool"),
			_last(msgs))
	# THE FREE END: the model offers NA's lane end as a trace end to continue.
	var free_end: Dictionary = data.free_trace_end_at(Vector2(120.0, 19.49), data.TRACE_SNAP_MM)
	check("NA's lane end (120,19.49) is a FREE end of NA's trace",
			by_net.has("NA") and str(free_end.get("trace_id", "")) == str(by_net["NA"].get("id", ""))
				and str(free_end.get("end", "")) == "end", str(free_end))
	check("…and a landed end is not (NB's end sits on its pad)",
			data.free_trace_end_at(TGT_B, data.TRACE_SNAP_MM).is_empty())
	check("one undo removes the whole open-ended bus", data.undo() and data.get_trace_count() == 0)
	canvas.free()

	# WITH A STATION: the open lane crosses the via and ends on the station
	# layer. NA's top run is the full station bus's own (source leg, fan-out into
	# the via at (70,18.89)); its bottom run leaves the via, fans back to the
	# lane (71.11,18.89)->(71.11,19.49) and runs to the spine's end (120,19.49).
	rig = _rig()
	canvas = rig[0]
	data = rig[1]
	canvas._handle_bus_click(SRC_A, false)
	canvas._handle_bus_click(SRC_B, false)
	canvas._handle_bus_click(SRC_C, false)
	canvas._handle_bus_click(PATH_1, false)
	canvas.working_layer = "bottom"
	canvas._handle_bus_click(STATION, false)
	canvas._handle_bus_click(PATH_2, false)
	canvas._handle_bus_click(TGT_B, false)
	canvas._handle_bus_click(TGT_C, false)
	var quiet := _board_state(data)
	_double_click(canvas, EMPTY)
	var runs := _traces_by_net_and_layer(data)
	check("station bus: six runs and three vias landed in one step",
			runs.size() == 6 and _serialized_vias(data).size() == 3
				and data.history.size() == int(quiet[1]) + 1,
			"runs %s vias %d" % [str(runs.keys()), _serialized_vias(data).size()])
	if runs.has("NA|top") and runs.has("NA|bottom"):
		_check_route("NA|top", _points_of(runs["NA|top"]), _expected_station_runs()["NA|top"])
		_check_route("NA|bottom (open)", _points_of(runs["NA|bottom"]),
			[Vector2(70.0, 18.89), Vector2(71.11, 18.89), Vector2(71.11, 19.49), Vector2(120.0, 19.49)])
		var open_end: Dictionary = data.free_trace_end_at(Vector2(120.0, 19.49), data.TRACE_SNAP_MM)
		check("the open end is the BOTTOM run's free end",
				str(open_end.get("trace_id", "")) == str(runs["NA|bottom"].get("id", ""))
					and str(open_end.get("end", "")) == "end", str(open_end))
	else:
		check("NA's two runs exist", false, str(runs.keys()))
	canvas.free()


func _test_the_open_verb_matches_the_open_gesture() -> void:
	print("\n-- (15b) minerva_pcb_route_bus_direct with a \"\" target == the open gesture --")
	var data := PCBData.new()
	data.from_board_dict(_board())
	var host := StubMcpHost.new()
	host.data = data
	var quiet := _board_state(data)
	var result: Dictionary = await PanelToolsScript.handle(host, "minerva_pcb_route_bus_direct", {
		"editor_name": "PCB1", "nets": ["NA", "NB", "NC"],
		"sources": ["U1.1", "U2.1", "U3.1"], "targets": ["", "V2.1", "V3.1"],
		"points": [{"x_mm": 20.0, "y_mm": 20.0}, {"x_mm": 120.0, "y_mm": 20.0}],
		"layer": "top",
	})
	check("the verb accepts an empty target for NA", bool(result.get("success", false)), str(result))
	check("…reporting open_nets == [NA] and saying so in the note",
			(result.get("open_nets", []) as Array) == ["NA"]
				and str(result.get("note", "")).contains("open") and str(result.get("note", "")).contains("NA"),
			str(result))
	check("…with no findings raised for the target NA does not have",
			(result.get("findings", []) as Array).is_empty(), str(result.get("findings", [])))
	check("…in one history step", data.history.size() == int(quiet[1]) + 1)
	var by_net := _traces_by_net(data)
	var want := _open_routes()
	for net in ["NA", "NB", "NC"]:
		if not by_net.has(net):
			check("verb trace for %s exists" % net, false)
			continue
		_check_route("verb %s" % net, _points_of(by_net[net]), want[net])

	# ── nets_detail: the reply carries what the NEXT verb needs ──────────────
	# ORACLE: the board's own serialized traces (ids, layers, points) and what
	# minerva_pcb_add_trace does with the reply's free_end passed VERBATIM —
	# the extension must land on NA's existing trace id, growing that trace by
	# the point given. Nothing here is read back from the code under test
	# except the object under test itself.
	var detail: Array = result.get("nets_detail", []) if result.get("nets_detail", []) is Array else []
	check("nets_detail carries one entry per net, in bus order",
			detail.size() == 3 and str((detail[0] as Dictionary).get("net", "")) == "NA"
				and int((detail[1] as Dictionary).get("lane_index", -1)) == 1
				and str((detail[2] as Dictionary).get("net", "")) == "NC", str(detail))
	if detail.size() == 3:
		for i in range(3):
			var entry: Dictionary = detail[i]
			var net: String = str(entry.get("net", ""))
			var runs: Array = entry.get("traces", []) if entry.get("traces", []) is Array else []
			var board_trace: Dictionary = by_net.get(net, {})
			var pts: Array = []
			for raw in (runs[0] as Dictionary).get("points", []) if runs.size() == 1 else []:
				pts.append(Vector2(float((raw as Array)[0]), float((raw as Array)[1])))
			check("%s: the reply names the board's own trace id and layer" % net,
					runs.size() == 1 and str((runs[0] as Dictionary).get("trace_id", "")) == str(board_trace.get("id", "?"))
						and str((runs[0] as Dictionary).get("layer", "")) == "top", str(runs))
			_check_route("%s (nets_detail points)" % net, pts, _points_of(board_trace))
		var na: Dictionary = detail[0]
		var nb: Dictionary = detail[1]
		check("NB landed on V2.1 and says so", bool(nb.get("landed", false))
				and str(nb.get("target", "")) == "V2.1" and str(nb.get("source", "")) == "U2.1"
				and not nb.has("free_end"), str(nb))
		check("NA is open, with its free end at the lane's end (120, 19.49) on top",
				not bool(na.get("landed", true)) and str(na.get("target", "x")) == ""
					and absf(float(na.get("free_end_x_mm", 0.0)) - 120.0) <= EPS
					and absf(float(na.get("free_end_y_mm", 0.0)) - 19.49) <= EPS
					and str(na.get("free_end_layer", "")) == "top", str(na))
		var free_end: Variant = na.get("free_end", null)
		check("NA's free_end is add_trace's start-anchor shape, naming NA's trace",
				free_end is Dictionary and str((free_end as Dictionary).get("trace_id", "")) == str(by_net["NA"].get("id", "?"))
					and str((free_end as Dictionary).get("end", "")) == "end", str(free_end))
		# THE HANDOFF: the anchor goes in verbatim, and the same trace grows.
		var grown: Dictionary = await PanelToolsScript.handle(host, "minerva_pcb_add_trace", {
			"editor_name": "PCB1", "start": free_end, "points": [[120.0, 30.0]],
		})
		var na_after: Dictionary = _traces_by_net(data).get("NA", {})
		var na_pts: Array = _points_of(na_after)
		check("add_trace accepts the free_end verbatim and extends NA's SAME trace",
				bool(grown.get("success", false)) and str(grown.get("trace_id", "")) == str(by_net["NA"].get("id", "?"))
					and str(grown.get("extended_from", "")) == "end"
					and _traces_by_net(data).size() == 3
					and na_pts.size() == want["NA"].size() + 1
					and (na_pts[na_pts.size() - 1] as Vector2).distance_to(Vector2(120.0, 30.0)) <= EPS,
				str(grown))

	# The PROPOSAL twin mirrors it: three ghosts, NA's ending at its lane's end.
	var data_p := PCBData.new()
	data_p.from_board_dict(_board())
	var ws = PcbRoutingWorkspace.new()
	var plan: Dictionary = PanelToolsScript.bus_plan(data_p, ["NA", "NB", "NC"],
		PackedVector2Array([PATH_1, PATH_2]), "top",
		PackedStringArray(["U1.1", "U2.1", "U3.1"]), PackedStringArray(["", "V2.1", "V3.1"]))
	check("the open plan is complete (committable) and names NA open",
			bool(plan.get("complete", false)) and (plan.get("open_nets", []) as Array) == ["NA"],
			str(plan.get("open_nets", [])))
	var out: Dictionary = PanelToolsScript.bus_propose_plan(ws, data_p, plan)
	check("bus_propose_plan proposes three ghosts and reports open_nets == [NA]",
			bool(out.get("ok", false)) and int(out.get("proposed", 0)) == 3
				and (out.get("open_nets", []) as Array) == ["NA"], str(out))
	var na_ghost: Dictionary = {}
	for c in out.get("candidates", []) as Array:
		if str((c as Dictionary).get("net", "")) == "NA":
			na_ghost = c
	check("NA's ghost has three segments (source leg + lane, no target leg)",
			int(na_ghost.get("segment_count", -1)) == 3, str(na_ghost))
	check("…and nothing was committed by the proposal", _serialized_traces(data_p).is_empty())
	# The proposal's nets_detail: same geometry, keyed to its ghost, no board ids.
	var ghost_detail: Array = out.get("nets_detail", []) if out.get("nets_detail", []) is Array else []
	var ghost_na: Dictionary = ghost_detail[0] if ghost_detail.size() == 3 else {}
	var ghost_pts: Array = []
	for raw in ((ghost_na.get("traces", [{}]) as Array)[0] as Dictionary).get("points", []):
		ghost_pts.append(Vector2(float((raw as Array)[0]), float((raw as Array)[1])))
	check("the proposal's nets_detail keys NA's lane to its ghost, with no trace id and a null free_end",
			ghost_detail.size() == 3 and str(ghost_na.get("candidate_id", "")) == str(na_ghost.get("candidate_id", "?"))
				and str(((ghost_na.get("traces", [{}]) as Array)[0] as Dictionary).get("trace_id", "x")) == ""
				and ghost_na.get("free_end", "x") == null
				and absf(float(ghost_na.get("free_end_x_mm", 0.0)) - 120.0) <= EPS,
			str(ghost_na))
	_check_route("NA ghost (nets_detail points)", ghost_pts, want["NA"])


# ── 16. LANE IDENTITY: every lane wears its net, end to end ──────────────────
#
# "I couldn't tell what wire would go to what pad." The words a lane carries
# are built by pcb_bus_labels.gd (pinned here without a canvas), and the same
# fields ride bus_target_guidance() rows — lane_index, color, ending — so an
# agent reads the mapping the human sees. The colour is the ratsnest's: the
# bundle colour PcbRatsnest.extract reports for a net IS the lane colour.
#
# ORACLE: the helper's own strings, the guidance rows per phase, and the
# ratsnest's extract() output for the same board.

func _test_every_lane_wears_its_net() -> void:
	print("\n-- (16) every lane wears its net: labels, numbers, colours --")
	# The helper alone.
	check("ending: no target before TARGETS reads '?'", PcbBusLabels.ending("", false) == "?")
	check("ending: no target in TARGETS reads 'open'", PcbBusLabels.ending("", true) == "open")
	check("ending: a landed target is its ref", PcbBusLabels.ending("V1.1", true) == "V1.1")
	check("lane_label reads 'NA → V1.1'", PcbBusLabels.lane_label("NA", "V1.1") == "NA → V1.1")
	check("lane_line reads '2 NB  U2.1 → open'",
			PcbBusLabels.lane_line(2, "NB", "U2.1", "open") == "2 NB  U2.1 → open")
	check("lanes_summary joins the lines with ' · ' in lane order",
			PcbBusLabels.lanes_summary([
				{"lane_index": 1, "net": "NA", "source_ref": "U1.1", "ending": "V1.1"},
				{"lane_index": 2, "net": "NB", "source_ref": "U2.1", "ending": "?"}])
				== "1 NA  U1.1 → V1.1 · 2 NB  U2.1 → ?")
	check("the TARGETS rule names the pick order",
			PcbBusLabels.TARGETS_RULE.contains("order you picked the nets"), PcbBusLabels.TARGETS_RULE)

	var rig := _rig()
	var canvas = rig[0]
	var data = rig[1]
	canvas._handle_bus_click(SRC_A, false)
	canvas._handle_bus_click(SRC_B, false)
	canvas._handle_bus_click(SRC_C, false)
	# SOURCES: numbered in pick order, every ending still '?'.
	var rows: Array = canvas.bus_target_guidance()
	var lanes: Array = []
	var endings: Array = []
	for row in rows:
		lanes.append(int((row as Dictionary)["lane_index"]))
		endings.append(str((row as Dictionary)["ending"]))
	check("SOURCES: lanes are numbered 1, 2, 3 in pick order", lanes == [1, 2, 3], str(lanes))
	check("SOURCES: every ending is '?'", endings == ["?", "?", "?"], str(endings))
	# THE COLOUR IS THE RATSNEST'S. The bundle extract() reports for NA carries
	# the colour its airwires are drawn in; the lane row for NA must carry the
	# same one, through the same helper.
	var ratsnest_color: Variant = null
	for bundle in PcbRatsnest.extract(data):
		if str((bundle as Dictionary).get("net", "")) == "NA":
			ratsnest_color = (bundle as Dictionary).get("color")
	var na_row: Dictionary = _guidance_row(canvas, "NA")
	check("NA's lane colour is the ratsnest's colour for NA, and the helper's",
			ratsnest_color is Color and na_row.get("color") == ratsnest_color
				and PcbBusLabels.net_color(data.get_net("NA")) == ratsnest_color,
			"lane %s ratsnest %s" % [str(na_row.get("color")), str(ratsnest_color)])
	check("…and color_hex is that colour as html", str(na_row.get("color_hex", ""))
			== (ratsnest_color as Color).to_html(false) if ratsnest_color is Color else false)
	check("a net without a colour of its own falls back to white, like an airwire",
			PcbBusLabels.net_color(null) == Color.WHITE)

	canvas._handle_bus_click(PATH_1, false)
	canvas._handle_bus_click(PATH_2, false)
	check("PATH: the endings are still '?' — no target is askable yet",
			str(_guidance_row(canvas, "NA")["ending"]) == "?")
	canvas._handle_bus_click(TGT_A, false)     # ends PATH, lands NA
	check("TARGETS: the teach line leads with the pick-order rule",
			canvas.bus_teach_line().begins_with(PcbBusLabels.TARGETS_RULE), canvas.bus_teach_line())
	check("TARGETS: the lane lines read the landed ref and 'open' for the rest",
			canvas.bus_lane_lines() == PackedStringArray([
				"1 NA  U1.1 → V1.1", "2 NB  U2.1 → open", "3 NC  U3.1 → open"]),
			str(canvas.bus_lane_lines()))
	canvas.free()


# ── 17. LANE ORDER IS A VISIBLE CHOICE ───────────────────────────────────────
#
# Lane order is pick order. Clicking a pick's NUMBER (the label box to the
# right of its pip ring — never the pad itself, which still toggles the net)
# moves that net one lane outward, toward lane 1 on the left of the spine
# looking from sources to targets; Shift moves it inward; the ends are named
# no-ops. Every per-net array rotates together, so a landed target follows its
# net, and the plan follows the order: the copper a reordered gesture commits
# is the copper a fresh gesture picked in that order commits.
#
# ORACLE: _bus_nets after each click, the message channel, the target array
# after a TARGETS-phase reorder, and — for "the plan follows" — the serialized
# traces of two boards compared net by net.

## Where a click on pick `i`'s number lands, in world mm: the middle of the
## digit's box to the right of its ring, at this rig's zoom of 8
## (world_to_screen is world * 8 with no pan and no size here).
func _pip_number_click(canvas, i: int) -> Vector2:
	var pad: Vector2 = canvas._bus_net_points[i]
	return pad + Vector2((canvas.BUS_PICK_MARKER_RADIUS_PX + 3.0
		+ canvas.BUS_PIP_NUMBER_HIT_W_PX * 0.5) / canvas.zoom, 0.0)


func _test_lane_order_is_a_visible_choice() -> void:
	print("\n-- (17) clicking a pick's number moves its net one lane outward --")
	var rig := _rig()
	var canvas = rig[0]
	var data = rig[1]
	var msgs := _collect(canvas)
	canvas._handle_bus_click(SRC_A, false)
	canvas._handle_bus_click(SRC_B, false)
	canvas._handle_bus_click(SRC_C, false)

	# THE TOGGLE-VS-NUMBER RULE, pinned: the pad centre toggles, the number moves.
	canvas._handle_bus_click(SRC_A, false)
	check("a click ON the pad still toggles the net off", canvas._bus_nets == (["NB", "NC"] as Array[String]),
			str(canvas._bus_nets))
	canvas._handle_bus_click(SRC_A, false)
	check("…and back on, at the end of the order", canvas._bus_nets == (["NB", "NC", "NA"] as Array[String]),
			str(canvas._bus_nets))
	canvas._handle_bus_click(_pip_number_click(canvas, 2), false)   # NA's number
	check("a click on the NUMBER does not toggle — NA is still picked, one lane outward",
			canvas._bus_nets == (["NB", "NA", "NC"] as Array[String]), str(canvas._bus_nets))
	check("…the source refs and points moved with it",
			canvas._bus_net_refs[1] == "U1.1" and canvas._bus_net_points[1] == SRC_A,
			"%s %s" % [str(canvas._bus_net_refs), str(canvas._bus_net_points)])
	check("…and the message names the new lane", _last(msgs).contains("NA is now lane 2"), _last(msgs))
	canvas._handle_bus_click(_pip_number_click(canvas, 1), false)   # NA again
	check("a second click takes NA to lane 1", canvas._bus_nets == (["NA", "NB", "NC"] as Array[String]),
			str(canvas._bus_nets))
	canvas._handle_bus_click(_pip_number_click(canvas, 0), false)   # NA at lane 1: no-op
	check("at lane 1 the click is a no-op that says so",
			canvas._bus_nets == (["NA", "NB", "NC"] as Array[String])
				and _last(msgs) == PcbBusLabels.reorder_end_message("NA", false), _last(msgs))
	canvas._reorder_bus_lane(0, true)                                # Shift: inward
	check("Shift (inward) moves NA back to lane 2", canvas._bus_nets == (["NB", "NA", "NC"] as Array[String]),
			str(canvas._bus_nets))
	canvas._reorder_bus_lane(2, true)
	check("at the last lane inward is a no-op that says so",
			canvas._bus_nets == (["NB", "NA", "NC"] as Array[String])
				and _last(msgs) == PcbBusLabels.reorder_end_message("NC", true), _last(msgs))
	# THE CONTROL NEVER COMPETES WITH STARTING THE PATH: a click 3 mm right of a
	# pick — clear of the pads, past the digit — begins the path, as the teach
	# line tells a human to.
	canvas._handle_bus_click(SRC_A + Vector2(3.0, 0.0), false)
	check("a click 3 mm right of a pick starts the PATH rather than reordering",
			canvas.bus_phase() == canvas.BusPhase.PATH and canvas._bus_spine_points.size() == 1
				and canvas._bus_nets == (["NB", "NA", "NC"] as Array[String]),
			"phase %d spine %d nets %s" % [canvas._bus_phase, canvas._bus_spine_points.size(), str(canvas._bus_nets)])
	canvas._cancel_bus_step(false)             # back to SOURCES, picks kept

	# TARGETS: the landed targets rotate with their nets, and the teach line
	# says how.
	canvas._handle_bus_click(PATH_1, false)
	canvas._handle_bus_click(PATH_2, false)
	canvas._handle_bus_click(TGT_B, false)
	canvas._handle_bus_click(TGT_A, false)
	check("TARGETS teach line (targets still owed) carries the reorder rule",
			canvas.bus_teach_line().contains("numbered pip"), canvas.bus_teach_line())
	canvas._handle_bus_click(TGT_C, false)
	canvas._handle_bus_click(_pip_number_click(canvas, 2), false)   # NC outward
	check("in TARGETS the number click reorders too: [NB, NC, NA]",
			canvas._bus_nets == (["NB", "NC", "NA"] as Array[String]), str(canvas._bus_nets))
	check("…and each net keeps its landed target",
			canvas._bus_target_refs == (["V2.1", "V3.1", "V1.1"] as Array[String]),
			str(canvas._bus_target_refs))
	# THE PLAN FOLLOWS. Commit this reordered bus and a bus picked fresh in the
	# same order; the copper must agree net by net.
	_double_click(canvas, EMPTY)
	var reordered := _traces_by_net(data)
	var fresh := _rig()
	var canvas_f = fresh[0]
	canvas_f._handle_bus_click(SRC_B, false)
	canvas_f._handle_bus_click(SRC_C, false)
	canvas_f._handle_bus_click(SRC_A, false)
	canvas_f._handle_bus_click(PATH_1, false)
	canvas_f._handle_bus_click(PATH_2, false)
	canvas_f._handle_bus_click(TGT_A, false)
	canvas_f._handle_bus_click(TGT_B, false)
	canvas_f._handle_bus_click(TGT_C, false)
	canvas_f._commit_bus()
	var picked := _traces_by_net(fresh[1])
	check("both boards hold three traces", reordered.size() == 3 and picked.size() == 3)
	for net in ["NA", "NB", "NC"]:
		var same := reordered.has(net) and picked.has(net) \
			and _points_of(reordered[net]) == _points_of(picked[net])
		check("%s: the reordered gesture and the fresh pick in that order authored the SAME polyline" % net,
				same, "%s vs %s" % [str(_points_of(reordered.get(net, {}))), str(_points_of(picked.get(net, {})))])
	canvas.free()
	canvas_f.free()


# ── 17b. A CROSSING BUS IS TOLD WHICH ORDER WOULD BE CLEAN ───────────────────
#
# Advisory only — nothing re-sorts. The helper walks every order (n <= 4)
# through bundle_routes on the same spine and pads and returns the first with
# no end crossing. ORACLE: bundle_routes itself, re-run on the returned order,
# and the verb reply / gesture message carrying the sentence.

func _test_a_crossing_bus_is_told_a_clean_order() -> void:
	print("\n-- (17b) a crossing pick order is offered a clean one, as words --")
	var spine := PackedVector2Array([PATH_1, PATH_2])
	var widths: Array = [0.2, 0.2, 0.2]
	# The reverse pick order of the suite's fixture crosses at both ends (5b).
	var names := PackedStringArray(["NC", "NB", "NA"])
	var src := PackedVector2Array([SRC_C, SRC_B, SRC_A])
	var tgt := PackedVector2Array([TGT_C, TGT_B, TGT_A])
	var crossing := BusGeom.bundle_routes(spine, names, src, tgt, widths, 0.3)
	check("fixture: the reverse order crosses", _has_end_crossing(crossing), str(crossing.get("error", "")))
	var order := BusGeom.clean_pick_order(spine, names, src, tgt, widths, 0.3)
	check("the helper returns an order", order.size() == 3, str(order))
	if order.size() == 3:
		var s2 := PackedVector2Array()
		var t2 := PackedVector2Array()
		for name in order:
			var k := names.find(name)
			s2.append(src[k])
			t2.append(tgt[k])
		var clean := BusGeom.bundle_routes(spine, order, s2, t2, widths, 0.3)
		check("…and bundle_routes on that order has no end crossing",
				bool(clean.get("buildable", false)) and not _has_end_crossing(clean),
				str(clean.get("error", "")))
	check("a clean order is returned unchanged",
			BusGeom.clean_pick_order(spine, PackedStringArray(["NA", "NB", "NC"]),
				PackedVector2Array([SRC_A, SRC_B, SRC_C]), PackedVector2Array([TGT_A, TGT_B, TGT_C]),
				widths, 0.3) == PackedStringArray(["NA", "NB", "NC"]))
	# NO clean order: two nets whose targets are swapped relative to their
	# sources — either order crosses at one end (hand-derived in the section
	# doc of pcb_bus_geometry's departure ladder: the pad of the other net lies
	# inside this net's leg band at one end whichever lane it takes).
	var none := BusGeom.clean_pick_order(spine, PackedStringArray(["NA", "NB"]),
		PackedVector2Array([SRC_A, SRC_B]), PackedVector2Array([TGT_B, TGT_A]), [0.2, 0.2], 0.3)
	check("a swap that crosses either way gets NO order", none.is_empty(), str(none))
	check("five nets are not searched", BusGeom.clean_pick_order(spine,
			PackedStringArray(["A", "B", "C", "D", "E"]),
			PackedVector2Array([SRC_A, SRC_B, SRC_C, SRC_A, SRC_B]),
			PackedVector2Array([TGT_A, TGT_B, TGT_C, TGT_A, TGT_B]),
			[0.2, 0.2, 0.2, 0.2, 0.2], 0.3).is_empty())
	check("the sentence names the order", PcbBusLabels.clean_order_sentence(
			PackedStringArray(["NA", "NB", "NC"])) == "pick order NA, NB, NC would leave the bundle clean.")
	check("…and is empty for no order", PcbBusLabels.clean_order_sentence(PackedStringArray()) == "")

	# THE VERB carries it in its note, and the gesture's commit message too.
	var data := PCBData.new()
	data.from_board_dict(_board())
	var host := StubMcpHost.new()
	host.data = data
	var result: Dictionary = await PanelToolsScript.handle(host, "minerva_pcb_route_bus_direct", {
		"editor_name": "PCB1", "nets": ["NC", "NB", "NA"],
		"sources": ["U3.1", "U2.1", "U1.1"], "targets": ["V3.1", "V2.1", "V1.1"],
		"points": [{"x_mm": 20.0, "y_mm": 20.0}, {"x_mm": 120.0, "y_mm": 20.0}],
		"layer": "top",
	})
	check("the verb landed the crossing bus", bool(result.get("success", false)), str(result))
	check("…and its note carries the advisory sentence and the reply the order",
			str(result.get("note", "")).contains("would leave the bundle clean")
				and (result.get("clean_order", []) as Array).size() == 3, str(result))
	var rig := _rig()
	var canvas = rig[0]
	var msgs := _collect(canvas)
	canvas._handle_bus_click(SRC_C, false)
	canvas._handle_bus_click(SRC_B, false)
	canvas._handle_bus_click(SRC_A, false)
	canvas._handle_bus_click(PATH_1, false)
	canvas._handle_bus_click(PATH_2, false)
	canvas._handle_bus_click(TGT_C, false)
	canvas._handle_bus_click(TGT_B, false)
	canvas._handle_bus_click(TGT_A, false)
	check("the live plan's advisory is the same sentence",
			canvas.bus_advisory().begins_with("pick order") and canvas.bus_advisory().ends_with("clean."),
			canvas.bus_advisory())
	_double_click(canvas, EMPTY)
	check("the commit message carries it", _last(msgs).contains("would leave the bundle clean"), _last(msgs))
	canvas.free()


func _has_end_crossing(routed: Dictionary) -> bool:
	for f in (routed.get("findings", []) as Array):
		if str((f as Dictionary).get("type", "")) == BusGeom.FINDING_END_CROSSING:
			return true
	return false


# ── 17c. THE PAD WINS OVER THE GLYPH ─────────────────────────────────────────
#
# At 0.1" pitch and zoom 8 the digit box beside one pick (12–22 px right) sits
# on the next pad of the row (20.3 px right). A click on that pad has to pick
# its net, never move the neighbour's lane. ORACLE: _bus_nets after the click.

func _test_a_neighbouring_pad_outranks_the_glyph() -> void:
	print("\n-- (17c) a pad 2.54 mm right of a pick outranks the pick's number --")
	var rig := _rig()
	var canvas = rig[0]
	var host = rig[2]
	var board: Dictionary = _board()
	board["components"].append(_part("U4", 12.54, 10.0))
	board["components"].append(_part("U5", 12.54, 30.0))
	board["nets"].append({"name": "ND", "pins": ["U4.1", "U5.1"]})
	var data = PCBData.new()
	data.from_board_dict(board)
	canvas.data = data
	host.pads.append({"component": "U4", "pin": "1", "position": Vector2(12.54, 10.0)})
	host.pads.append({"component": "U5", "pin": "1", "position": Vector2(12.54, 30.0)})
	canvas._handle_bus_click(SRC_A, false)                    # NA
	canvas._handle_bus_click(Vector2(12.54, 10.0), false)     # U4.1, inside NA's digit box
	check("a click on the neighbouring pad ADDS its net rather than reordering",
			canvas._bus_nets == (["NA", "ND"] as Array[String]), str(canvas._bus_nets))
	canvas._handle_bus_click(SRC_B, false)                    # NB, lane 3
	canvas._handle_bus_click(_pip_number_click(canvas, 2), false)   # NB's digit: no pad there
	check("…while the glyph with no pad under it still reorders",
			canvas._bus_nets == (["NA", "NB", "ND"] as Array[String]), str(canvas._bus_nets))
	canvas.free()


# ── 17d. THE LIVE PLAN IS THE COMMIT PLAN ────────────────────────────────────
#
# In TARGETS the preview plans with the same target array the commit uses —
# "" per open net — so the ghost shows the landed legs and the open lanes and
# the held status judges the copper that would land. With NB (the middle
# lane, y = 20) left open, NA's leg at x = 120 runs from y = 19.49 through
# (120, 20), which is NB's open lane END: the clearance measurement reads a
# 0 mm gap and names both nets, BEFORE any commit. No pad moves: the fixture
# crosses as it stands once the middle net is the open one.

func _test_the_live_plan_is_the_commit_plan() -> void:
	print("\n-- (17d) in TARGETS the live plan carries the open nets the commit will land --")
	var rig := _rig()
	var canvas = rig[0]
	var data = rig[1]
	canvas._handle_bus_click(SRC_A, false)
	canvas._handle_bus_click(SRC_B, false)
	canvas._handle_bus_click(SRC_C, false)
	canvas._handle_bus_click(PATH_1, false)
	canvas._handle_bus_click(PATH_2, false)
	check("PATH: the live plan is the corridor-only preview (no target pins)",
			canvas._bus_plan_target_pins().is_empty() and not bool(canvas._bus_current_plan().get("complete", true)))
	canvas._handle_bus_click(TGT_A, false)   # ends PATH, lands NA
	canvas._handle_bus_click(TGT_C, false)   # NC landed; NB open
	var plan: Dictionary = canvas._bus_current_plan()
	check("TARGETS: the plan is planned with the live targets, \"\" for NB",
			canvas._bus_plan_target_pins() == PackedStringArray(["V1.1", "", "V3.1"]),
			str(canvas._bus_plan_target_pins()))
	check("…so it is complete and carries open_nets == [NB]",
			bool(plan.get("complete", false)) and (plan.get("open_nets", []) as Array) == ["NB"],
			str(plan.get("open_nets", [])))
	var polys: Array = plan.get("polylines", [])
	check("…and its ghosts are the landed legs plus the open lane ending at (120,20)",
			polys.size() == 3 and (polys[0] as PackedVector2Array)[(polys[0] as PackedVector2Array).size() - 1] == TGT_A
				and (polys[1] as PackedVector2Array)[(polys[1] as PackedVector2Array).size() - 1] == Vector2(120.0, 20.0),
			str(polys))
	check("the held refusal names the crossing of NA's leg and NB's open lane before commit",
			canvas.bus_refusal().contains("NA") and canvas.bus_refusal().contains("NB")
				and canvas.bus_finding_count() >= 1 and canvas.bus_plan_buildable(),
			canvas.bus_refusal())
	var before := _board_state(data)
	_double_click(canvas, EMPTY)
	check("…and the commit lands exactly that plan: 3 traces, NB open, in one step",
			_traces_by_net(data).size() == 3 and data.history.size() == int(before[1]) + 1
				and _points_of(_traces_by_net(data)["NB"])[_points_of(_traces_by_net(data)["NB"]).size() - 1] == Vector2(120.0, 20.0))
	canvas.free()


# ── 17e. AN ALL-OPEN STATION BUS, deliberately ───────────────────────────────
#
# Landing the lanes and finishing every leg by hand is allowed: every net open,
# through a via station, lands N top runs, N vias and N open bottom runs in
# one step, every bottom end free, and the sentence names all three nets.

func _test_an_all_open_station_bus_lands_deliberately() -> void:
	print("\n-- (17e) an all-open station bus lands lanes, vias and free ends --")
	var rig := _rig()
	var canvas = rig[0]
	var data = rig[1]
	var msgs := _collect(canvas)
	canvas._handle_bus_click(SRC_A, false)
	canvas._handle_bus_click(SRC_B, false)
	canvas._handle_bus_click(SRC_C, false)
	canvas._handle_bus_click(PATH_1, false)
	canvas.working_layer = "bottom"
	canvas._handle_bus_click(STATION, false)
	canvas._handle_bus_click(PATH_2, false)
	_double_click(canvas, DBL_END)            # ends PATH with no target landed
	check("fixture: TARGETS reached with every net open",
			canvas.bus_phase() == canvas.BusPhase.TARGETS and canvas._bus_nets_without_targets().size() == 3)
	var before := _board_state(data)
	var j0: int = data.change_journal.size()
	_double_click(canvas, EMPTY)
	var runs := _traces_by_net_and_layer(data)
	check("six runs and three vias landed in one history step",
			runs.size() == 6 and _serialized_vias(data).size() == 3
				and data.history.size() == int(before[1]) + 1,
			"runs %s vias %d" % [str(runs.keys()), _serialized_vias(data).size()])
	var free_ends := 0
	for net in ["NA", "NB", "NC"]:
		var run: Dictionary = runs.get("%s|bottom" % net, {})
		var pts := _points_of(run)
		if not pts.is_empty():
			var found: Dictionary = data.free_trace_end_at(pts[pts.size() - 1], data.TRACE_SNAP_MM)
			if str(found.get("trace_id", "")) == str(run.get("id", "")) and str(found.get("end", "")) == "end":
				free_ends += 1
	check("every bottom run ends free, past the via", free_ends == 3, "free ends %d" % free_ends)
	var bus_row: Dictionary = {}
	for e in data.change_journal.slice(j0):
		if str((e as Dictionary).get("action", "")) == "add_bus":
			bus_row = e
	check("the add_bus row names all three nets as open",
			(bus_row.get("details", {}) as Dictionary).get("open_nets", []) == ["NA", "NB", "NC"], str(bus_row))
	check("…and the status sentence names them",
			_last(msgs).contains("3 lane") and _last(msgs).contains("NA, NB, NC"), _last(msgs))
	canvas.free()


# ── 15c. dry_run: READ THE BUS, WRITE NOTHING ────────────────────────────────
#
# ORACLE: the board's own serialization (JSON of to_board_dict), history.size()
# and change_journal.size() before and after the dry run — byte-identical — and
# the COMMITTING call's reply on the very same inputs and board, which the dry
# run's reply must equal once the ids the commit legitimately minted (trace_ids,
# via_ids, the per-net trace_id/via_id/free_end) and the two mode-specific notes
# are set aside. Two buses, so both halves of the reply are exercised: a station
# bus with an open lane (vias, two runs per net, a free end) and a reversed-order
# bus that crosses (findings, note, clean_order).

## A reply with everything the commit minted, and the mode words, removed.
func _bus_reply_sans_ids(reply: Dictionary) -> Dictionary:
	var out: Dictionary = reply.duplicate(true)
	for key in ["trace_ids", "via_ids", "dry_run", "undo_note", "dry_run_note"]:
		out.erase(key)
	if out.has("note"):
		out["note"] = str(out["note"]).replace("would land anyway", "landed anyway")
	var detail: Array = out.get("nets_detail", []) if out.get("nets_detail", []) is Array else []
	for raw in detail:
		var entry: Dictionary = raw
		entry.erase("via_id")
		entry.erase("free_end")
		for run in (entry.get("traces", []) as Array):
			(run as Dictionary).erase("trace_id")
	return out


func _test_dry_run_reads_the_bus_and_writes_nothing() -> void:
	print("\n-- (15c) minerva_pcb_route_bus_direct dry_run: the commit's reply, and no write --")
	var cases: Array = [
		{"label": "station bus with an open lane", "args": {
			"editor_name": "PCB1", "nets": ["NA", "NB", "NC"],
			"sources": ["U1.1", "U2.1", "U3.1"], "targets": ["", "V2.1", "V3.1"],
			"points": [{"x_mm": 20.0, "y_mm": 20.0}, {"x_mm": 70.0, "y_mm": 20.0},
				{"x_mm": 120.0, "y_mm": 20.0}],
			"layer": "top", "via_station_index": 1, "via_station_layer": "bottom"}},
		{"label": "reversed pick order (crosses, with findings)", "args": {
			"editor_name": "PCB1", "nets": ["NC", "NB", "NA"],
			"sources": ["U3.1", "U2.1", "U1.1"], "targets": ["V3.1", "V2.1", "V1.1"],
			"points": [{"x_mm": 20.0, "y_mm": 20.0}, {"x_mm": 120.0, "y_mm": 20.0}],
			"layer": "top"}},
	]
	for case in cases:
		var label: String = str(case["label"])
		var args: Dictionary = case["args"]
		var data := PCBData.new()
		data.from_board_dict(_board())
		var host := StubMcpHost.new()
		host.data = data
		var board_before: String = JSON.stringify(data.to_board_dict())
		var history_before: int = data.history.size()
		var journal_before: int = data.change_journal.size()

		var dry_args: Dictionary = args.duplicate(true)
		dry_args["dry_run"] = true
		var dry: Dictionary = await PanelToolsScript.handle(host, "minerva_pcb_route_bus_direct", dry_args)
		check("%s: the dry run succeeds and says it is one" % label,
				bool(dry.get("success", false)) and bool(dry.get("dry_run", false))
					and dry.has("dry_run_note") and not dry.has("undo_note"), str(dry))
		check("%s: the dry run minted no ids" % label,
				(dry.get("trace_ids", []) as Array).is_empty() and (dry.get("via_ids", []) as Array).is_empty(),
				str(dry))
		check("%s: the board, its history and its journal are byte-identical after the dry run" % label,
				JSON.stringify(data.to_board_dict()) == board_before
					and data.history.size() == history_before
					and data.change_journal.size() == journal_before,
				"history %d -> %d, journal %d -> %d" % [history_before, data.history.size(),
					journal_before, data.change_journal.size()])

		var committed: Dictionary = await PanelToolsScript.handle(host, "minerva_pcb_route_bus_direct", args)
		check("%s: the same call without dry_run commits" % label,
				bool(committed.get("success", false)) and not bool(committed.get("dry_run", true))
					and committed.has("undo_note")
					and not (committed.get("trace_ids", []) as Array).is_empty()
					and data.history.size() == history_before + 1, str(committed))
		var dry_norm: String = JSON.stringify(_bus_reply_sans_ids(dry))
		var commit_norm: String = JSON.stringify(_bus_reply_sans_ids(committed))
		check("%s: minus the minted ids and the mode notes, the two replies are identical" % label,
				dry_norm == commit_norm, "\n    dry:    %s\n    commit: %s" % [dry_norm, commit_norm])
		# The dry run's per-net account carries the geometry but no board ids.
		var detail: Array = dry.get("nets_detail", []) if dry.get("nets_detail", []) is Array else []
		var idless := detail.size() == 3
		for raw in detail:
			var entry: Dictionary = raw
			if str(entry.get("via_id", "x")) != "" or (entry.has("free_end") and entry.get("free_end") != null):
				idless = false
			for run in (entry.get("traces", []) as Array):
				if str((run as Dictionary).get("trace_id", "x")) != "" \
						or ((run as Dictionary).get("points", []) as Array).size() < 2:
					idless = false
		check("%s: the dry run's nets_detail has every polyline and no id" % label, idless, str(detail))


# ── 18. WHICH SIDE A PAD CAN BE REACHED FROM, AND THE WAY OUT OF A MIRRORED PAIR
#
# ORACLES:
#   APPROACH SIDES — hand-derived from pitch, pad and rule: a 2x3 LGA on 1.0mm
#     pitch with 0.6mm lands, 0.2mm tracks at 0.2mm clearance. The reach strip
#     is 0.1 + 0.2 = 0.3mm each side of the pad's centre line; a same-column
#     neighbour sits ON that line and a same-row neighbour's 0.6mm land spans
#     it, so the middle pad of the west column is reachable from the west ONLY,
#     a corner pad from its two outer sides, and a lone land from all four.
#     Read through pin_approach_sides on the loaded component and through the
#     canvas's own bus_target_guidance rows.
#   THE WAY OUT — the LGA board with the header's pads ABOVE the spine start
#     and the two target pads swapped: the original pick order crosses at the
#     TARGET end, the reversed order crosses at the SOURCE end (each hand-
#     checked against _departure_stations' band rule below), so no pick order
#     is clean. The reply must say so with a CONCRETE targets array, and that
#     array fed straight back must land one net and leave the named one open.

## The 2x3 LGA: pins 1-3 down the west column (x -0.5), 4-6 down the east
## (x +0.5), rows y -1 / 0 / +1, 0.6mm square lands, at (40, 40).
func _lga_2x3_board() -> Dictionary:
	var board := _lga_board()
	(board["components"] as Array).append({"ref": "T2", "footprint": "IC_DIP",
		"x_mm": 40.0, "y_mm": 40.0, "rotation_deg": 0.0, "pins": [
			_lga_pin("1", -0.5, -1.0), _lga_pin("2", -0.5, 0.0), _lga_pin("3", -0.5, 1.0),
			_lga_pin("4", 0.5, -1.0), _lga_pin("5", 0.5, 0.0), _lga_pin("6", 0.5, 1.0)]})
	(board["components"] as Array).append({"ref": "W1", "footprint": "IC_DIP",
		"x_mm": 50.0, "y_mm": 50.0, "rotation_deg": 0.0, "pins": [_lga_pin("1", 0.0, 0.0)]})
	return board


## The LGA board MIRRORED: U1's header pads stacked ABOVE the spine's start
## (y 6 / 8, with FGND's at 10) and NA/NB landing on the swapped target pads.
## Source end (spine east from (14,10), n = (0,1)): pad perps NA -4, NB -2 vs
## lanes NA -0.205 / NB +0.205 — NB's pad lies in NA's band and NA's lane in
## NB's, so NB leaves first: consistent, no crossing. Target end (last segment
## south, perp = 30 - x): NA on T1.2 (29,28) is +1, NB on T1.4 (31,28) is -1 —
## each other's lane inside the other's band: a CROSSING. Reversed, the lanes
## swap sign: the target end clears and the SOURCE end becomes the cycle.
func _mirrored_lga_board() -> Dictionary:
	var board := _lga_board()
	var u1: Dictionary = (board["components"] as Array)[0]
	u1["y_mm"] = 6.0
	(u1["pins"] as Array)[1]["y_mm"] = 2.0
	(u1["pins"] as Array)[2]["y_mm"] = 4.0
	board["nets"] = [
		{"name": "NA", "pins": ["U1.1", "T1.2"]},
		{"name": "NB", "pins": ["U1.2", "T1.4"]},
		{"name": "FGND", "pins": ["U1.3", "T1.1"]},
		{"name": "FVCC", "pins": ["T1.3"]},
	]
	return board


func _test_approach_sides_and_leave_one_open() -> void:
	print("\n-- (18) approach_sides on the pad, and the leave-one-open way out --")
	var data := PCBData.new()
	data.from_board_dict(_lga_2x3_board())
	var rules: Array = PcbPadApproach.board_rules(data)
	check("the board's rules are the 0.2mm track at 0.2mm clearance this section derives from",
			absf(float(rules[0]) - 0.2) <= EPS and absf(float(rules[1]) - 0.2) <= EPS, str(rules))
	var t2 = data.get_component("T2")
	var w1 = data.get_component("W1")
	check("fixture: the 2x3 LGA carries six lands and the lone part one",
			t2 != null and t2.pads.size() == 6 and w1 != null and w1.pads.size() == 1)
	if t2 == null or w1 == null:
		return
	check("the west column's middle pad (T2.2) is reachable from the west only",
			PcbPadApproach.pin_approach_sides(t2, "2", float(rules[0]), float(rules[1])) == PackedStringArray(["west"]),
			str(PcbPadApproach.pin_approach_sides(t2, "2", float(rules[0]), float(rules[1]))))
	check("the east column's middle pad (T2.5) is reachable from the east only",
			PcbPadApproach.pin_approach_sides(t2, "5", float(rules[0]), float(rules[1])) == PackedStringArray(["east"]))
	check("a corner pad (T2.1, north-west) is reachable from north and west",
			PcbPadApproach.pin_approach_sides(t2, "1", float(rules[0]), float(rules[1])) == PackedStringArray(["north", "west"]))
	check("a lone land is reachable from all four sides",
			PcbPadApproach.pin_approach_sides(w1, "1", float(rules[0]), float(rules[1])).size() == 4)
	# The pure rule on bare rectangles: one 0.6mm neighbour 1.0mm to the east
	# closes the east side only; a neighbour clear of the strip closes nothing.
	check("the pure rule: an east neighbour in the strip closes east alone",
			PcbPadApproach.approach_sides(Rect2(-0.3, -0.3, 0.6, 0.6),
				[Rect2(0.7, -0.3, 0.6, 0.6)], 0.2, 0.2) == PackedStringArray(["north", "south", "west"]))
	check("…and one outside the strip (0.7mm north of the centre line) closes nothing",
			PcbPadApproach.approach_sides(Rect2(-0.3, -0.3, 0.6, 0.6),
				[Rect2(0.7, -1.3, 0.6, 0.6)], 0.2, 0.2).size() == 4)

	# The canvas's guidance rows describe the same pads the same way.
	var rig := _rig()
	var canvas = rig[0]
	canvas._handle_bus_click(SRC_A, false)
	var rows: Array = canvas.bus_target_guidance()
	var described := not rows.is_empty()
	for row in rows:
		for cand in (row as Dictionary).get("candidates", []):
			if not (cand as Dictionary).has("approach_sides") \
					or ((cand as Dictionary)["approach_sides"] as Array).size() != 4:
				described = false
	check("bus_target_guidance candidates carry approach_sides (a bare point pin: all four)", described, str(rows))
	canvas.free()

	# ── The mirrored pair ────────────────────────────────────────────────────
	var mirrored := PCBData.new()
	mirrored.from_board_dict(_mirrored_lga_board())
	var host := StubMcpHost.new()
	host.data = mirrored
	var args := {
		"editor_name": "PCB1", "nets": ["NA", "NB"],
		"sources": ["U1.1", "U1.2"], "targets": ["T1.2", "T1.4"],
		"points": [{"x_mm": LGA_PATH_1.x, "y_mm": LGA_PATH_1.y},
			{"x_mm": LGA_PATH_2.x, "y_mm": LGA_PATH_2.y},
			{"x_mm": LGA_PATH_3.x, "y_mm": LGA_PATH_3.y}],
		"layer": "top", "dry_run": true,
	}
	var seen: Dictionary = await PanelToolsScript.handle(host, "minerva_pcb_route_bus_direct", args)
	var crossing: Dictionary = {}
	for f in seen.get("findings", []):
		if str((f as Dictionary).get("type", "")) == BusGeom.FINDING_END_CROSSING:
			crossing = f
	check("the mirrored pair crosses at the TARGET end, and the finding says which end",
			bool(seen.get("success", false)) and not crossing.is_empty()
				and str(crossing.get("end", "")) == "target", str(seen.get("findings", [])))
	check("no pick order is clean (the reversed order crosses at the source end)",
			not seen.has("clean_order") or (seen.get("clean_order", []) as Array).is_empty(), str(seen))
	var open_net: String = str(seen.get("leave_open_net", ""))
	var open_targets: Array = seen.get("leave_open_targets", []) if seen.get("leave_open_targets", []) is Array else []
	check("the reply names the net to leave open and the concrete targets array",
			open_net in ["NA", "NB"] and open_targets.size() == 2
				and open_targets.count("") == 1
				and str(open_targets[(args["nets"] as Array).find(open_net)]) == "", str(seen))
	check("the note says it in as many words, targets array included",
			str(seen.get("note", "")).contains("no pick order lands both")
				and str(seen.get("note", "")).contains("leave one open")
				and str(seen.get("note", "")).contains("targets [")
				and str(seen.get("note", "")).contains("\"\""), str(seen.get("note", "")))
	check("…and the dry run wrote nothing", _serialized_traces(mirrored).is_empty())

	# FED BACK VERBATIM: the named net's lane ends open, the other lands.
	var again: Dictionary = args.duplicate(true)
	again.erase("dry_run")
	again["targets"] = open_targets
	var landed: Dictionary = await PanelToolsScript.handle(host, "minerva_pcb_route_bus_direct", again)
	var landed_crossing := false
	for f in landed.get("findings", []):
		if str((f as Dictionary).get("type", "")) == BusGeom.FINDING_END_CROSSING:
			landed_crossing = true
	check("the targets array from the reply lands the bus with the named lane open and no crossing",
			bool(landed.get("success", false)) and (landed.get("open_nets", []) as Array) == [open_net]
				and not landed_crossing and _traces_by_net(mirrored).size() == 2, str(landed))
	var detail: Array = landed.get("nets_detail", []) if landed.get("nets_detail", []) is Array else []
	var open_entry: Dictionary = {}
	for e in detail:
		if str((e as Dictionary).get("net", "")) == open_net:
			open_entry = e
	check("…and its free_end anchor is there for minerva_pcb_add_trace",
			open_entry.get("free_end", null) is Dictionary
				and str((open_entry["free_end"] as Dictionary).get("end", "")) == "end", str(open_entry))
