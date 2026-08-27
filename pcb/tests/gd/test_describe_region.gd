extends SceneTree
## minerva_pcb_describe_region, and layers_touched on both it and
## minerva_pcb_list_vias.
##
## Run (via a Minerva checkout as the Godot host — NEVER the live checkout):
##   pcb/scripts/run-gd-tests.sh <path-to-minerva-checkout>
##
## THE GAP. Understanding the ground around ONE part otherwise costs five verbs
## and a hand cross-reference: list_zones + describe_zone per zone +
## get_components (the whole board) + spatial_query + pin_info. spatial_query
## already sweeps a rectangle, but its copper block returns bare ID LISTS — no
## pad nets, no zone outlines, no trace free ends — so the answers still have to
## be reassembled by hand.
##
## THE FIXTURE is the LGA board test_bus_tool.gd's foreign-copper section uses
## (a THT source column, a 4-pad SMD target part, four nets), re-declared here
## rather than imported: this suite adds copper of its own (an open lane, a
## station via, a filled pour, a keepout, a boundary-crossing run) and a fixture
## shared with another suite is a fixture neither may change. The GEOMETRY is
## hand-derived and stated as constants below, so every assertion reads its
## expected value off the fixture rather than off the implementation.
##
## FAILS AGAINST OLD trivially and completely: panel_tools.handle returns {} for
## an unrecognised tool name (contract §2.4 -> tool_unhandled), so on the base
## commit every describe_region assertion below reads success=false. The
## layers_touched half fails against old too — list_vias emitted no such key.
##
## REUSE SCAN: panel mount + check helpers follow test_direct_copper_verbs.gd,
## which follows test_view_state.gd, which follows test_parity_bridge.gd.

const PanelTools := preload("res://../../minerva-plugins/pcb/ui/panel_tools.gd")
const PcbRegionDescribe := preload("res://../../minerva-plugins/pcb/ui/model/pcb_region_describe.gd")
const PcbCopperContact := preload("res://../../minerva-plugins/pcb/ui/model/pcb_copper_contact.gd")
const PCB_PANEL_SCRIPT_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"

## Board mm tolerance for a coordinate comparison. Board coordinates ride
## through float32 Vector2 and leave quantized to 0.1 um (panel_tools._mm), so
## an exact == against a GDScript float64 literal is a coin toss on the last
## bit; 1e-6 mm is four orders of magnitude below the quantum and cannot mask a
## real disagreement.
const EPS_MM := 1.0e-6

# ── THE FIXTURE, hand-derived ────────────────────────────────────────────────
## The region every "what is here" assertion is made against: x 14..38, y 14..38.
const REGION := Rect2(14.0, 14.0, 24.0, 24.0)
## A rectangle of bare board — nothing of any kind is authored inside it.
const EMPTY_REGION := Rect2(48.0, 4.0, 6.0, 6.0)

## T1's four SMD lands, world mm (part at (30,28), pads at local (+-1, -2/0)).
const T1_1 := Vector2(29.0, 26.0)   # FGND
const T1_2 := Vector2(29.0, 28.0)   # NB
const T1_3 := Vector2(31.0, 26.0)   # FVCC
const T1_4 := Vector2(31.0, 28.0)   # NA
## U1's through-hole column, world mm. OUTSIDE the region on purpose — a part
## the rectangle does not touch must not be listed.
const U1_3 := Vector2(10.0, 15.08)  # FGND

## THE OPEN LANE: net NA, top, landed on T1.4 and stopping in bare board.
const OPEN_LANE_START := T1_4
const OPEN_LANE_FREE_END := Vector2(36.0, 28.0)
## THE STATION VIA and the single run that reaches it — on TOP only, so its
## BOTTOM side meets nothing at all. Nothing else in this fixture is on bottom.
const VIA_AT := Vector2(20.0, 20.0)
const VIA_FEED_START := Vector2(14.0, 20.0)
## THE POUR: net FGND, top, a 3x3 mm square well clear of every other conductor.
const POUR_MIN := Vector2(34.0, 30.0)
const POUR_MAX := Vector2(37.0, 33.0)
## THE KEEPOUT: no net, top, inside the region and touching nothing.
const KEEPOUT_MIN := Vector2(16.0, 30.0)
const KEEPOUT_MAX := Vector2(19.0, 33.0)
## THE BOUNDARY-CROSSING RUN: starts on U1.3 (outside), crosses the region, ends
## outside it again. Its middle is the only part inside.
const CROSSER := [Vector2(10.0, 15.08), Vector2(10.0, 36.0), Vector2(44.0, 36.0)]

const TRACE_WIDTH_MM := 0.25

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== describe_region + layers_touched ===\n")
	await _run_pads_and_parts()
	await _run_open_lane_free_end()
	await _run_pour_and_keepout()
	await _run_station_via_layers_touched()
	await _run_list_vias_agrees()
	await _run_empty_region_is_an_answer()
	await _run_boundary_crossing_trace_is_whole()
	await _run_layer_filter()
	await _run_notes()
	await _run_refusals()
	_run_via_span_module()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func check(desc: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s" % desc)


func check_eq(desc: String, actual, expected) -> void:
	check("%s (expected %s, got %s)" % [desc, str(expected), str(actual)], actual == expected)


func check_near(desc: String, actual: float, expected: float) -> void:
	check("%s (expected %s, got %s)" % [desc, str(expected), str(actual)],
		absf(actual - expected) <= EPS_MM)


func check_point(desc: String, actual, expected: Vector2) -> void:
	if not (actual is Dictionary):
		check("%s — a {x_mm,y_mm} point (got %s)" % [desc, str(actual)], false)
		return
	var d: Dictionary = actual
	check_near("%s x_mm" % desc, float(d.get("x_mm", NAN)), expected.x)
	check_near("%s y_mm" % desc, float(d.get("y_mm", NAN)), expected.y)


# ── FIXTURE ──────────────────────────────────────────────────────────────────

class FakeEditor extends RefCounted:
	var tab_title: String = "RegionProbe"
	var associated_object: Variant = ""


## A through-hole pin: a 0.8mm drill in a 1.6mm annulus, so its copper is a disc
## on EVERY copper layer.
func _tht_pin(number: String, x: float, y: float) -> Dictionary:
	return {"number": number, "x_mm": x, "y_mm": y,
		"drill_mm": 0.8, "annulus_diameter_mm": 1.6}


## One 0.6mm square land — SMD, and therefore TOP only.
func _smd_pin(number: String, x: float, y: float) -> Dictionary:
	return {"number": number, "x_mm": x, "y_mm": y,
		"pad_width_mm": 0.6, "pad_height_mm": 0.6}


func _board() -> Dictionary:
	return {
		"version": 1, "name": "RegionBoard", "width_mm": 60.0, "height_mm": 60.0,
		"grid_mm": 2.54,
		"layers": ["top", "bottom"],
		"design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.2},
		"components": [
			{"ref": "U1", "footprint": "IC_DIP", "x_mm": 10.0, "y_mm": 10.0,
				"rotation_deg": 0.0, "pins": [
					_tht_pin("1", 0.0, 0.0), _tht_pin("2", 0.0, 2.54),
					_tht_pin("3", 0.0, 5.08)]},
			{"ref": "T1", "footprint": "IC_DIP", "x_mm": 30.0, "y_mm": 28.0,
				"rotation_deg": 0.0, "pins": [
					_smd_pin("1", -1.0, -2.0), _smd_pin("2", -1.0, 0.0),
					_smd_pin("3", 1.0, -2.0), _smd_pin("4", 1.0, 0.0)]},
		],
		"nets": [
			{"name": "NA", "pins": ["U1.1", "T1.4"]},
			{"name": "NB", "pins": ["U1.2", "T1.2"]},
			{"name": "FGND", "pins": ["U1.3", "T1.1"]},
			{"name": "FVCC", "pins": ["T1.3"]},
		],
	}


func _rect_outline(lo: Vector2, hi: Vector2) -> PackedVector2Array:
	return PackedVector2Array([lo, Vector2(hi.x, lo.y), hi, Vector2(lo.x, hi.y)])


## A panel MOUNTED IN THE REAL TREE with the fixture board and every piece of
## copper the assertions below name. Returns {panel, host, data, via_id, ...}.
func _ctx() -> Dictionary:
	var panel: Variant = load(PCB_PANEL_SCRIPT_PATH).new()
	get_root().add_child(panel)
	panel.position = Vector2.ZERO
	panel.size = Vector2(1100, 700)
	panel._on_panel_loaded({"editor": FakeEditor.new(), "file_path": ""})
	for _i in range(6):
		await process_frame

	var host = panel.get_annotation_host()
	host.set_panel(panel)
	var data = panel.get_data()
	data.from_board_dict(_board())

	var open_lane = data.create_trace_entity("NA", "top",
		PackedVector2Array([OPEN_LANE_START, OPEN_LANE_FREE_END]), TRACE_WIDTH_MM)
	var feed = data.create_trace_entity("NB", "top",
		PackedVector2Array([VIA_FEED_START, VIA_AT]), TRACE_WIDTH_MM)
	var crosser = data.create_trace_entity("FGND", "top",
		PackedVector2Array(CROSSER), TRACE_WIDTH_MM)
	var via_id := str(data.add_via({"position": VIA_AT, "net_name": "NB",
		"size": 0.8, "drill": 0.4, "from_layer": "top", "to_layer": "bottom"}))

	var pour: Dictionary = data.create_zone("FGND", "top",
		_rect_outline(POUR_MIN, POUR_MAX), "copper_pour")
	var keepout: Dictionary = data.create_zone("", "top",
		_rect_outline(KEEPOUT_MIN, KEEPOUT_MAX), "keepout")
	# The pour's COMPILED fill — one region, the whole square. Without it the
	# pour conducts nothing (see PcbZoneCopper's header), which is a different
	# board from the one these assertions describe.
	var fill_ring: Array = []
	for p in _rect_outline(POUR_MIN, POUR_MAX):
		fill_ring.append({"x_mm": (p as Vector2).x, "y_mm": (p as Vector2).y})
	data.adopt_zone_fill([{"id": str(pour.get("id", "")), "fill": [fill_ring]}])

	return {
		"panel": panel, "host": host, "data": data, "via_id": via_id,
		"open_lane_id": str(open_lane.id) if open_lane != null else "",
		"feed_id": str(feed.id) if feed != null else "",
		"crosser_id": str(crosser.id) if crosser != null else "",
		"pour_id": str(pour.get("id", "")), "keepout_id": str(keepout.get("id", "")),
	}


func _unmount(ctx: Dictionary) -> void:
	var panel = ctx.get("panel")
	if panel != null and panel is Node:
		(panel as Node).queue_free()
	await process_frame


func _describe(ctx: Dictionary, region: Rect2, layer: String = "") -> Dictionary:
	return await PanelTools.handle(ctx["host"], "minerva_pcb_describe_region", {
		"editor_name": "RegionProbe",
		"x_mm": region.position.x, "y_mm": region.position.y,
		"width_mm": region.size.x, "height_mm": region.size.y,
		"layer": layer,
	})


func _entry_by(rows: Array, key: String, value: String) -> Dictionary:
	for row in rows:
		if row is Dictionary and str((row as Dictionary).get(key, "")) == value:
			return row
	return {}


# ── 1. THE PADS, with their nets, in one read ────────────────────────────────
#
# ORACLE 1: the region holds exactly ONE part (T1), and its four pads come back
# as THE pad row carrying the nets the board declares. U1 is 20mm away and must
# be absent — a region read that swept the whole board would be indistinguishable
# from get_components, which is the verb this one exists to replace.

func _run_pads_and_parts() -> void:
	print("\n-- 1. the pads in the region, with their nets --")
	var ctx := await _ctx()
	var reply := await _describe(ctx, REGION)
	check("the verb answers", bool(reply.get("success", false)))

	var comps: Array = reply.get("components", [])
	check_eq("O1: exactly one component in the region", comps.size(), 1)
	var t1 := _entry_by(comps, "ref", "T1")
	check("O1: it is T1", not t1.is_empty())
	check("O1: U1, 20mm outside the rectangle, is NOT listed",
		_entry_by(comps, "ref", "U1").is_empty())
	check_point("O1: T1 sits at its authored position", t1.get("position"), Vector2(30.0, 28.0))

	var pads: Array = t1.get("pads", [])
	check_eq("O1: all four lands are reported", pads.size(), 4)
	var expected := {"1": ["FGND", T1_1], "2": ["NB", T1_2],
		"3": ["FVCC", T1_3], "4": ["NA", T1_4]}
	for pin in ["1", "2", "3", "4"]:
		var row := _entry_by(pads, "pin", pin)
		check("O1: T1.%s is present" % pin, not row.is_empty())
		if row.is_empty():
			continue
		check_eq("O1: T1.%s net" % pin, str(row.get("net", "")),
			str((expected[pin] as Array)[0]))
		check_point("O1: T1.%s land" % pin, row.get("position"),
			(expected[pin] as Array)[1])
		# THE pad row, not a shape invented here: the same keys
		# get_selection/pin_info emit (PcbPadRow.row).
		check("O1: T1.%s carries the whole pad row" % pin,
			row.get("kind", "") == "pad" and row.has("ref") and row.has("component")
			and row.has("layer") and row.has("side") and row.has("approach_sides")
			and row.has("roles"))
		check_eq("O1: T1.%s ref is the one address form" % pin,
			str(row.get("ref", "")), "T1.%s" % pin)
	await _unmount(ctx)


# ── 2. THE OPEN LANE ─────────────────────────────────────────────────────────
#
# ORACLE 2: the NA run is landed on T1.4 at one end and stops in bare board at
# the other, so exactly ONE of its ends is free and it is the one at
# OPEN_LANE_FREE_END. The whole point of the field is that an agent can see the
# lane is unfinished without re-deriving contact itself.
#
# ORACLE 2b: free_ends is trace_end_is_joined NEGATED and nothing else — asserted
# against the model directly, over every trace the read returns. A second rule
# with the same name is the failure this pins.

func _run_open_lane_free_end() -> void:
	print("\n-- 2. an open lane's free end --")
	var ctx := await _ctx()
	var data = ctx["data"]
	var reply := await _describe(ctx, REGION)
	var traces: Array = reply.get("traces", [])

	var lane := _entry_by(traces, "trace_id", str(ctx["open_lane_id"]))
	check("O2: the open lane is in the region", not lane.is_empty())
	check_eq("O2: on its net", str(lane.get("net", "")), "NA")
	check_eq("O2: on its layer", str(lane.get("layer", "")), "top")
	check_near("O2: at its authored width", float(lane.get("width_mm", 0.0)), TRACE_WIDTH_MM)
	var free: Array = lane.get("free_ends", [])
	check_eq("O2: exactly one end is free", free.size(), 1)
	if free.size() == 1:
		check_eq("O2: it is the END, not the pad-landed START",
			str((free[0] as Dictionary).get("end", "")), "end")
		check_point("O2: at the point the lane stops", free[0], OPEN_LANE_FREE_END)

	var feed := _entry_by(traces, "trace_id", str(ctx["feed_id"]))
	var feed_free: Array = feed.get("free_ends", [])
	check_eq("O2: the via feed has one free end too", feed_free.size(), 1)
	if feed_free.size() == 1:
		check_eq("O2: and it is the START — the far end sits on the via",
			str((feed_free[0] as Dictionary).get("end", "")), "start")

	for row in traces:
		var t: Dictionary = row
		var reported := {}
		for f in (t.get("free_ends", []) as Array):
			reported[str((f as Dictionary).get("end", ""))] = true
		for end in ["start", "end"]:
			check("O2b: %s.%s — free_ends agrees with trace_end_is_joined"
					% [str(t.get("trace_id", "")), end],
				reported.has(end) != data.trace_end_is_joined(str(t.get("trace_id", "")), end))
	await _unmount(ctx)


# ── 3. THE POUR (and the keepout beside it) ──────────────────────────────────
#
# ORACLE 3: the pour comes back with its OUTLINE — the thing that used to cost a
# separate describe_zone per zone — and with fill_region_count, which is what
# separates "there is ground here" from "there is a request for ground here".
# ORACLE 3b: the keepout is reported APART from the pour. They are one entity
# type in the model and two different things to a reader.

func _run_pour_and_keepout() -> void:
	print("\n-- 3. the pour outline, and the keepout beside it --")
	var ctx := await _ctx()
	var reply := await _describe(ctx, REGION)

	var zones: Array = reply.get("zones", [])
	check_eq("O3: one copper pour in the region", zones.size(), 1)
	var pour := _entry_by(zones, "zone_id", str(ctx["pour_id"]))
	check("O3: it is the pour we authored", not pour.is_empty())
	check_eq("O3: its kind", str(pour.get("kind", "")), "copper_pour")
	check_eq("O3: its net", str(pour.get("net", "")), "FGND")
	check_eq("O3: its layer", str(pour.get("layer", "")), "top")
	check_eq("O3: four outline points", (pour.get("outline", []) as Array).size(), 4)
	check_eq("O3: point_count agrees with the outline it ships",
		int(pour.get("point_count", -1)), (pour.get("outline", []) as Array).size())
	var outline: Array = pour.get("outline", [])
	if outline.size() == 4:
		check_point("O3: outline corner 0", outline[0], POUR_MIN)
		check_point("O3: outline corner 2", outline[2], POUR_MAX)
	check_eq("O3: the pour CONDUCTS — one compiled fill region",
		int(pour.get("fill_region_count", -1)), 1)

	var keepouts: Array = reply.get("keepouts", [])
	check_eq("O3b: one keepout in the region", keepouts.size(), 1)
	var keepout := _entry_by(keepouts, "zone_id", str(ctx["keepout_id"]))
	check("O3b: reported apart from the pour, not mixed into zones[]",
		not keepout.is_empty() and _entry_by(zones, "zone_id", str(ctx["keepout_id"])).is_empty())
	check_eq("O3b: its kind", str(keepout.get("kind", "")), "keepout")
	check("O3b: a keepout emits no copper, so it carries no fill count",
		not keepout.has("fill_region_count"))
	check_eq("O3b: it ships its outline too",
		(keepout.get("outline", []) as Array).size(), 4)
	await _unmount(ctx)


# ── 4. THE STATION VIA ───────────────────────────────────────────────────────
#
# ORACLE 4: the via SPANS top<->bottom (every through via does) and TOUCHES only
# top — one run lands on it from above and nothing at all exists on bottom. The
# span alone could never show that, which is the whole reason the field exists.
# The verb NAMES it and judges nothing: no "stranded", no finding, no refusal.

func _run_station_via_layers_touched() -> void:
	print("\n-- 4. a station via's layers_touched --")
	var ctx := await _ctx()
	var data = ctx["data"]
	var reply := await _describe(ctx, REGION)

	var vias: Array = reply.get("vias", [])
	check_eq("O4: one via in the region", vias.size(), 1)
	var via := _entry_by(vias, "via_id", str(ctx["via_id"]))
	check("O4: it is the station via", not via.is_empty())
	check_point("O4: at its authored point", via, VIA_AT)
	check_eq("O4: on its net", str(via.get("net_name", "")), "NB")
	check_eq("O4: the barrel SPANS both copper layers",
		via.get("layers_spanned", []), ["top", "bottom"])
	check_eq("O4: but its copper only MEETS top",
		via.get("layers_touched", []), ["top"])
	check("O4: the reply passes no verdict on that — no finding, no refusal",
		bool(reply.get("success", false)) and not reply.has("error")
		and not reply.has("findings"))

	# The same answer straight off the module, so a wiring change cannot make
	# the two disagree quietly.
	check_eq("O4: the module agrees with the verb",
		PcbRegionDescribe.layers_touched(data, data.get_via(str(ctx["via_id"]))),
		["top"])

	# MUTATION-PROOF: give the bottom side something to meet and the answer must
	# grow. Without this, "always returns [top]" would pass every check above.
	data.create_trace_entity("NB", "bottom",
		PackedVector2Array([VIA_AT, Vector2(VIA_AT.x, VIA_AT.y + 6.0)]), TRACE_WIDTH_MM)
	check_eq("O4: bottom copper landing on the via makes it touch bottom too",
		PcbRegionDescribe.layers_touched(data, data.get_via(str(ctx["via_id"]))),
		["top", "bottom"])
	await _unmount(ctx)


# ── 5. list_vias carries the same row ────────────────────────────────────────
#
# ORACLE 5: minerva_pcb_list_vias reports layers_touched too, and its entry for a
# given via is IDENTICAL to the one describe_region gives — they are built by one
# function (pcb_region_describe.via_entry), and this is what pins that.

func _run_list_vias_agrees() -> void:
	print("\n-- 5. list_vias carries layers_touched, identically --")
	var ctx := await _ctx()
	var listed := await PanelTools.handle(ctx["host"], "minerva_pcb_list_vias",
		{"editor_name": "RegionProbe"})
	check("the verb answers", bool(listed.get("success", false)))
	check_eq("O5: the board's one via is listed", int(listed.get("via_count", -1)), 1)
	var from_list := _entry_by(listed.get("vias", []), "via_id", str(ctx["via_id"]))
	check("O5: list_vias reports layers_touched", from_list.has("layers_touched"))
	check_eq("O5: and it says top only", from_list.get("layers_touched", []), ["top"])

	var region_reply := await _describe(ctx, REGION)
	var from_region := _entry_by(region_reply.get("vias", []), "via_id", str(ctx["via_id"]))
	# Compared as JSON, not with ==, so the claim is about the CONTENT of the two
	# rows rather than about whichever equality semantics the engine gives
	# Dictionary today.
	check("O5: the two surfaces describe ONE via identically",
		JSON.stringify(from_list) == JSON.stringify(from_region))
	await _unmount(ctx)


# ── 6. AN EMPTY REGION IS AN ANSWER ──────────────────────────────────────────
#
# ORACLE 6: a rectangle of bare board answers success with empty arrays — never
# an error, never a missing key. `searched` is what lets a reader tell "nothing
# is here" from "nothing was looked for", and the second reading is the dangerous
# one: it invites routing straight through copper the query never examined.

func _run_empty_region_is_an_answer() -> void:
	print("\n-- 6. a region containing nothing --")
	var ctx := await _ctx()
	var reply := await _describe(ctx, EMPTY_REGION)
	check("O6: it succeeds", bool(reply.get("success", false)))
	check("O6: no error", not reply.has("error"))
	for key in ["components", "traces", "vias", "zones", "keepouts", "cutouts", "notes"]:
		check("O6: %s is an EMPTY ARRAY, not absent" % key,
			reply.get(key, null) is Array and (reply[key] as Array).is_empty())
	var searched: Array = reply.get("searched", [])
	for key in ["components", "traces", "vias", "zones", "keepouts", "cutouts", "notes"]:
		check("O6: searched names %s, so the empty array means nothing is there" % key,
			key in searched)
	check_point("O6: the reply names the rectangle it searched",
		reply.get("region_mm"), EMPTY_REGION.position)
	await _unmount(ctx)


# ── 7. A TRACE CROSSING THE BOUNDARY ─────────────────────────────────────────
#
# ORACLE 7: the FGND run starts outside the rectangle, crosses it and ends
# outside again. It is listed WHOLE — all three authored points, both endpoints
# beyond the boundary. A clipped polyline would describe copper that does not
# exist, and where a run goes is most of why the region was asked about.

func _run_boundary_crossing_trace_is_whole() -> void:
	print("\n-- 7. a trace crossing the boundary, listed whole --")
	var ctx := await _ctx()
	var reply := await _describe(ctx, REGION)
	var crosser := _entry_by(reply.get("traces", []), "trace_id", str(ctx["crosser_id"]))
	check("O7: the crossing run is in the region", not crosser.is_empty())
	var pts: Array = crosser.get("points", [])
	check_eq("O7: all three authored points survive", pts.size(), 3)
	if pts.size() == 3:
		check_point("O7: it still starts on U1.3, outside the rectangle", pts[0], CROSSER[0])
		check_point("O7: it still bends where it was authored", pts[1], CROSSER[1])
		check_point("O7: it still ends outside the rectangle", pts[2], CROSSER[2])
	check("O7: its start is outside the region", not REGION.has_point(CROSSER[0]))
	check("O7: its end is outside the region", not REGION.has_point(CROSSER[2]))
	var free: Array = crosser.get("free_ends", [])
	check_eq("O7: its far end is free, and it is reported even though it lies outside",
		free.size(), 1)
	if free.size() == 1:
		check_point("O7: at the point the run really ends", free[0], CROSSER[2])
	await _unmount(ctx)


# ── 8. THE LAYER FILTER ──────────────────────────────────────────────────────
#
# ORACLE 8: `layer` filters everything that HAS a copper layer, and never a
# component. Asking for bottom on this fixture leaves no traces, no pours and no
# keepouts, but KEEPS T1 (a part is a physical object, not copper on one layer)
# with an EMPTY pads array (its SMD lands are top), and keeps the via, whose
# barrel spans bottom.

func _run_layer_filter() -> void:
	print("\n-- 8. the layer filter --")
	var ctx := await _ctx()

	var top := await _describe(ctx, REGION, "top")
	check_eq("O8: layer is echoed canonically", str(top.get("layer", "")), "top")
	check_eq("O8: top keeps all three runs", (top.get("traces", []) as Array).size(), 3)
	check_eq("O8: top keeps the pour", (top.get("zones", []) as Array).size(), 1)
	var t1_top := _entry_by(top.get("components", []), "ref", "T1")
	check_eq("O8: and all four of T1's top lands",
		(t1_top.get("pads", []) as Array).size(), 4)

	var bottom := await _describe(ctx, REGION, "bottom")
	check("O8: bottom still succeeds", bool(bottom.get("success", false)))
	check_eq("O8: no run is on bottom", (bottom.get("traces", []) as Array).size(), 0)
	check_eq("O8: no pour is on bottom", (bottom.get("zones", []) as Array).size(), 0)
	check_eq("O8: no keepout is on bottom", (bottom.get("keepouts", []) as Array).size(), 0)
	check_eq("O8: the via is KEPT — its barrel spans bottom",
		(bottom.get("vias", []) as Array).size(), 1)
	var t1_bottom := _entry_by(bottom.get("components", []), "ref", "T1")
	check("O8: T1 is KEPT — a part is not copper on one layer", not t1_bottom.is_empty())
	check_eq("O8: but none of its SMD lands are on bottom",
		(t1_bottom.get("pads", []) as Array).size(), 0)

	# A KiCad spelling is the same layer. Same answer, or the canon step is dead.
	var kicad := await _describe(ctx, REGION, "F.Cu")
	check_eq("O8: \"F.Cu\" is \"top\"", str(kicad.get("layer", "")), "top")
	check("O8: and answers identically",
		JSON.stringify(kicad.get("traces", [])) == JSON.stringify(top.get("traces", [])))
	await _unmount(ctx)


# ── 9. NOTES ─────────────────────────────────────────────────────────────────
#
# ORACLE 9: an annotation whose ANCHOR POINT lies inside the rectangle is
# reported; one anchored outside is not. Driven at the module (both anchor wire
# shapes, deterministic) and through the live host (the wiring).

func _run_notes() -> void:
	print("\n-- 9. the notes anchored inside --")
	var inside := {"id": "ann_in", "kind": "note",
		"anchor": {"type": "pcb/board.point", "id": {"x": 30.0, "y": 28.0}},
		"kind_payload": {"text": "check the ground return here"}}
	var outside := {"id": "ann_out", "kind": "note",
		"anchor": {"type": "pcb/board.point", "id": {"x": 5.0, "y": 5.0}},
		"kind_payload": {"text": "elsewhere"}}
	# A pad anchor carries {component, pin} in id and its board point in the
	# snapshot — the other half of the wire shape anchor_point reads.
	var pad_anchored := {"id": "ann_pad", "kind": "note",
		"anchor": {"type": "pcb/pad", "id": {"component": "T1", "pin": "4"},
			"snapshot": {"position": [T1_4.x, T1_4.y]}},
		"kind_payload": {"text": "T1.4 is the open lane"}}

	var notes := PcbRegionDescribe.notes_in_region(
		[inside, outside, pad_anchored], REGION)
	check_eq("O9: two of the three anchor inside the rectangle", notes.size(), 2)
	check("O9: the board-point note is one", not _entry_by(notes, "id", "ann_in").is_empty())
	check("O9: the pad-anchored note is the other",
		not _entry_by(notes, "id", "ann_pad").is_empty())
	check("O9: the far note is absent", _entry_by(notes, "id", "ann_out").is_empty())
	var one := _entry_by(notes, "id", "ann_in")
	check_eq("O9: its text rides along", str(one.get("text", "")),
		"check the ground return here")
	check_point("O9: and the point it was dropped on", one.get("position"), Vector2(30.0, 28.0))
	check_point("O9: a pad anchor resolves through its snapshot",
		_entry_by(notes, "id", "ann_pad").get("position"), T1_4)

	var ctx := await _ctx()
	ctx["host"].set_annotations([inside, outside])
	var reply := await _describe(ctx, REGION)
	var live: Array = reply.get("notes", [])
	check_eq("O9: through the live host, one note is inside", live.size(), 1)
	check_eq("O9: and it is the near one", str((live[0] as Dictionary).get("id", "")), "ann_in")
	await _unmount(ctx)


# ── 10. REFUSALS ─────────────────────────────────────────────────────────────
#
# ORACLE 10: a rectangle with no size is an author error, not an empty answer —
# an agent that omitted a field must be told, not handed [] to misread as "the
# board is clear here". Each refusal NAMES the field.

func _run_refusals() -> void:
	print("\n-- 10. refusals --")
	var ctx := await _ctx()
	var host = ctx["host"]

	var missing := await PanelTools.handle(host, "minerva_pcb_describe_region",
		{"editor_name": "RegionProbe", "x_mm": 0.0, "y_mm": 0.0, "width_mm": 5.0})
	check("O10: an omitted height_mm is refused", not bool(missing.get("success", true)))
	check("O10: and the refusal names it", str(missing.get("error", "")).contains("height_mm"))

	var zero := await _describe(ctx, Rect2(10.0, 10.0, 0.0, 5.0))
	check("O10: a zero-width rectangle is refused", not bool(zero.get("success", true)))
	check("O10: the refusal names both size fields",
		str(zero.get("error", "")).contains("width_mm")
		and str(zero.get("error", "")).contains("height_mm"))

	var negative := await _describe(ctx, Rect2(10.0, 10.0, 5.0, -5.0))
	check("O10: a negative height is refused, not silently normalised",
		not bool(negative.get("success", true)))

	var bad_layer := await _describe(ctx, REGION, "F.SilkS")
	check("O10: a non-copper layer is refused", not bool(bad_layer.get("success", true)))
	check("O10: and the refusal names the layer asked for",
		str(bad_layer.get("error", "")).contains("F.SilkS"))
	await _unmount(ctx)


# ── 11. via_span, the one derivation ─────────────────────────────────────────
#
# ORACLE 11: the span walk is PcbCopperContact.via_span, which pcb_ratsnest now
# delegates to. A through via takes every layer between its two ends — two on a
# two-layer board, four on a four-layer one — and a span naming a layer the stack
# does not declare answers with its two ends rather than guessing.

func _run_via_span_module() -> void:
	print("\n-- 11. via_span --")
	var through := {"from_layer": "top", "to_layer": "bottom"}
	check_eq("O11: two-layer through span",
		PcbCopperContact.via_span(through, PackedStringArray(["top", "bottom"])),
		["top", "bottom"])
	check_eq("O11: four-layer through span takes the inners with it",
		PcbCopperContact.via_span(through,
			PackedStringArray(["top", "in1", "in2", "bottom"])),
		["top", "in1", "in2", "bottom"])
	check_eq("O11: reversed ends give the same span, in stack order",
		PcbCopperContact.via_span({"from_layer": "bottom", "to_layer": "top"},
			PackedStringArray(["top", "in1", "bottom"])),
		["top", "in1", "bottom"])
	check_eq("O11: KiCad spellings canonicalise",
		PcbCopperContact.via_span({"from_layer": "F.Cu", "to_layer": "B.Cu"},
			PackedStringArray(["top", "bottom"])),
		["top", "bottom"])
	check_eq("O11: an undeclared end answers with its two ends, never a guess",
		PcbCopperContact.via_span({"from_layer": "top", "to_layer": "in7"},
			PackedStringArray(["top", "bottom"])),
		["top", "in7"])
