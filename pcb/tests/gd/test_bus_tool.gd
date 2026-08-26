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
const PcbRoutingWorkspace := preload("res://../../minerva-plugins/pcb/ui/model/pcb_routing_workspace.gd")
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
	# AWAITED (unlike every synchronous test above): panel_tools.handle() is a
	# coroutine end to end (see panel_tools.gd's own class-doc note) because it
	# awaits internally on other branches. A bare call without await here would
	# still COMPILE, but this test's post-await assertions would resume on some
	# later, unscheduled tick — possibly after _init() has printed Results and
	# quit() — and silently not count.
	await _test_mcp_direct_verb_matches_the_gesture()
	await _test_a_bad_bus_reaches_the_agent_and_the_ghost()
	await _test_the_station_verb_matches_the_station_gesture()
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
# list is then exactly the bus, and pitch = 0.1 + 0.3 + 0.1 = 0.5 gives lanes
# [-0.5, 0.0, +0.5] (pinned by test_pcb_bus_geometry.gd, consumed here).

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
## it pins source stations 1.0/0.5/0.0 and target stations 0.0/0.5/1.0 and the
## three routes below. This fixture is that case translated by (+20, +20) —
## spine (20,20)→(120,20), the same pads moved with it — so the routes are the
## pinned ones plus the same offset, and nothing about the geometry is being
## re-derived here.
func _expected_routes() -> Dictionary:
	return {
		"NA": [SRC_A, Vector2(21.0, 10.0), Vector2(21.0, 19.5),
			Vector2(120.0, 19.5), Vector2(120.0, 40.0), TGT_A],
		"NB": [SRC_B, Vector2(20.5, 12.0), Vector2(20.5, 20.0),
			Vector2(119.5, 20.0), Vector2(119.5, 42.0), TGT_B],
		"NC": [SRC_C, Vector2(20.0, 14.0), Vector2(20.0, 20.5),
			Vector2(119.0, 20.5), Vector2(119.0, 44.0), TGT_C],
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

	# Two of three targets: still not committable.
	canvas._handle_bus_click(TGT_A, false)
	canvas._handle_bus_click(TGT_B, false)
	canvas._commit_bus()
	check("Enter with 2 of 3 nets targeted writes nothing", _board_state(data) == quiet,
			str(_board_state(data)))
	check("…and names the net still missing one",
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
	check("…the picks are untouched", canvas._bus_nets == (["NA", "NB"] as Array[String]),
			"got %s" % str(canvas._bus_nets))
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
	check("the live preview still calls this bus refused, naming both nets",
			live_refusal.contains("NB") and live_refusal.contains("NC"), live_refusal)

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
# [-0.5, 0.0, +0.5], source stations 1.0/0.5/0.0, target stations 0.0/0.5/1.0 —
# all pinned by test_bus_breakout_geometry.gd and consumed here) plus the via
# rules this board declares NONE of, so the 0.8mm / 0.4mm fallback applies:
#
#   via pitch = 0.4 + 0.3 + 0.4 = 1.1mm, wider than the 0.5mm track pitch, so
#   the lanes widen to [-1.1, 0.0, +1.1] at the station and NA/NC jog 1.1mm
#   either side of it (x 68.9 and x 71.1). NB is already on the spine and does
#   not move, so it has no jog at all.
#
# The three vias therefore sit on x = 70, the station's own perpendicular, at
# y 18.9 / 20.0 / 21.1 — 1.1mm apart, which is the clearance claim measured
# below rather than assumed.

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
		"NA|top": [SRC_A, Vector2(21.0, 10.0), Vector2(21.0, 19.5),
			Vector2(68.9, 19.5), Vector2(68.9, 18.9), Vector2(70.0, 18.9)],
		"NA|bottom": [Vector2(70.0, 18.9), Vector2(71.1, 18.9),
			Vector2(71.1, 19.5), Vector2(120.0, 19.5), Vector2(120.0, 40.0), TGT_A],
		"NB|top": [SRC_B, Vector2(20.5, 12.0), Vector2(20.5, 20.0), Vector2(70.0, 20.0)],
		"NB|bottom": [Vector2(70.0, 20.0), Vector2(119.5, 20.0),
			Vector2(119.5, 42.0), TGT_B],
		"NC|top": [SRC_C, Vector2(20.0, 14.0), Vector2(20.0, 20.5),
			Vector2(68.9, 20.5), Vector2(68.9, 21.1), Vector2(70.0, 21.1)],
		"NC|bottom": [Vector2(70.0, 21.1), Vector2(71.1, 21.1),
			Vector2(71.1, 20.5), Vector2(119.0, 20.5), Vector2(119.0, 44.0), TGT_C],
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
	check("a second layer switch is refused, naming the station it already has",
			_last(msgs).contains("already has a via station") and int(canvas._bus_station_index) == 1,
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
	var want_vias := {"NA": Vector2(70.0, 18.9), "NB": Vector2(70.0, 20.0),
		"NC": Vector2(70.0, 21.1)}
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
	check("the torn-plan probe starts from a routed station plan",
			bool(torn.get("ok", false)) and (torn.get("via_station_splits", []) as Array).size() == 3, str(torn.get("error", "")))
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
