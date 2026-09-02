extends SceneTree
## PAD FIDELITY, AND THE CHECKS A HUMAN NEVER SAW.
##
## Run (via a Minerva scaffold as the Godot host — NEVER the live checkout):
##   godot --headless --path <minerva-scaffold>/src \
##     --script res://../../minerva-plugins/pcb/tests/gd/test_pcb_pad_fidelity.gd
##
## ── WHAT EACH SECTION COVERS ─────────────────────────────────────────────────
##
##   1. THE PAD CODEC CARRIES WHAT THE WORKER EMITS. corner_rratio, raw_shape
##      and the two solder margins are the fab-affecting optionals the emitters
##      read; the panel used to drop all four, so every board saved from the
##      panel came back with its roundrects re-defaulted to the emitter's
##      corner ratio and its lands re-opened at the board-global mask
##      clearance. ORACLE: the board dict handed IN. A decode -> encode round
##      trip must return the same values under the same keys — and must leave
##      an absent key absent, because "the footprint authored none" is a
##      different fact from "it authored zero".
##
##   2. A ROUNDRECT LAND IS ITS OWN SHAPE, NOT THE STADIUM INSIDE IT. The
##      solver used to model every roundrect as the maximum-corner-radius
##      member, which drops the four corner regions. ORACLE: hand-derived
##      geometry. An 8.0 x 2.0mm land at corner ratio 0.25 has a 0.5mm corner
##      radius, so its corner arc is centred at local (3.5, 0.5). A trace
##      ending at local (3.8, 0.8) is 0.4243mm from that centre — 0.0757mm
##      INSIDE the real copper — while the same point is 1.1314mm from the
##      inscribed stadium's axis, 0.1314mm OUTSIDE it. The two shapes disagree
##      about this point, so the answer is a measurement of which one the
##      solver uses. A land that states NO ratio, and one at the maximal 0.5,
##      must both still read as the stadium: those are the cases where the
##      stadium is exact.
##
##   4. COPPER PAINTS IN MANUFACTURING ORDER. A trace and the through-hole
##      land it enters are ONE copper shape, and the drill clears the middle of
##      the barrel — so a canvas that paints the trace last shows copper running
##      straight across an open hole, a board no fab makes. ORACLE: the draw
##      ORDER itself. This canvas is immediate mode and the suites run headless
##      with no render device, so there is no child list to index and no pixel
##      to sample. Three observables, in increasing execution: the sequence of
##      passes PcbCopperDrawOrder.build() returns as data; the bucket
##      _bucket_smd_lands routes each land into (which layer's pass paints it,
##      and whether a paste-only aperture is painted at all); and the sequence
##      of painter calls _draw_copper() itself makes, recorded by a canvas
##      subclass that overrides every painter (recording_canvas.gd). The
##      fixture is the reported board: bottom copper running under a
##      top-mounted through-hole land.
##
##   3. AN INDETERMINATE LOAD-TIME CHECK REACHES A HUMAN. The load reply's
##      third answer — "this could not be measured" — was honest in JSON and
##      invisible on screen, which for a GUI-only owner is indistinguishable
##      from a pass. ORACLE: the reply itself. Whatever verdict object the
##      reply carries, the status lead must name it; a reply where every check
##      answered must produce no lead at all, or the signal means nothing.

const PCBData := preload("res://../../minerva-plugins/pcb/ui/model/pcb_data.gd")
const PCBComponent := preload("res://../../minerva-plugins/pcb/ui/model/pcb_component.gd")
const Ratsnest := preload("res://../../minerva-plugins/pcb/ui/model/pcb_ratsnest.gd")
const LoadChecks := preload("res://../../minerva-plugins/pcb/ui/model/pcb_load_checks.gd")
const PcbCopperDrawOrder := preload("res://../../minerva-plugins/pcb/ui/model/pcb_copper_draw_order.gd")
const PcbCanvasScript := preload("res://../../minerva-plugins/pcb/ui/pcb_canvas.gd")
## The canvas with every copper painter overridden to record instead of draw —
## the execution-path observable section 4 uses (see the file's own header).
const RecordingCanvas := preload("res://../../minerva-plugins/pcb/tests/gd/recording_canvas.gd")

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== pad fidelity + load-check visibility ===\n")
	_run_pad_codec_carries_the_fab_optionals()
	_run_roundrect_land_is_not_the_inscribed_stadium()
	_run_indeterminate_checks_reach_a_human()
	_run_copper_paints_in_manufacturing_order()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


# ── 1. the pad codec carries what the worker emits ────────────────────────────

## One component whose single pad carries every optional the worker emits.
func _authored_pad() -> Dictionary:
	return {"number": "1", "type": "smd", "shape": "roundrect",
		"position": {"x": -1.4, "y": 0.0},
		"size": {"width": 1.25, "height": 1.75},
		"drill": {"x": 0.0, "y": 0.0},
		"layers": ["F.Cu", "F.Mask", "F.Paste"],
		"corner_rratio": 0.2, "raw_shape": "roundrect",
		"solder_mask_margin": 0.05, "solder_paste_margin": -0.02}


func _component_with_pads(pads: Array) -> Dictionary:
	return {"ref": "JP1", "footprint": "Fuse:Fuse_1206_3216Metric",
		"x_mm": 20.0, "y_mm": 20.0, "rotation_deg": 0.0, "layer": "top",
		"pins": [{"number": "1", "x_mm": -1.4, "y_mm": 0.0}],
		"pads": pads}


func _run_pad_codec_carries_the_fab_optionals() -> void:
	print("-- 1. the pad codec carries the fab-affecting optionals --")
	var authored := _authored_pad()
	var comp = PCBComponent.new()
	comp.load_from_board_dict(_component_with_pads([authored]))
	check_eq("the authored pad survives decode", comp.pads.size(), 1)
	if comp.pads.size() != 1:
		return
	var decoded: Dictionary = comp.pads[0]
	check_eq("corner_rratio survives decode", decoded.get("corner_rratio"), 0.2)
	check_eq("raw_shape survives decode", decoded.get("raw_shape"), "roundrect")
	check_eq("solder_mask_margin survives decode", decoded.get("solder_mask_margin"), 0.05)
	check_eq("solder_paste_margin survives decode", decoded.get("solder_paste_margin"), -0.02)

	var round_tripped: Dictionary = comp.to_board_dict()
	var pads_out: Array = round_tripped.get("pads", [])
	check_eq("the pad survives encode", pads_out.size(), 1)
	if pads_out.size() != 1:
		return
	var out: Dictionary = pads_out[0]
	for key in PCBComponent.PAD_OPTIONAL_KEYS:
		check_eq("%s round-trips to the same value" % key, out.get(key), authored[key])

	# A pad that authored none of them must come back carrying none: an
	# invented 0.0 corner ratio is a SHARP-cornered land, which is not what a
	# footprint that stated nothing asked for.
	var plain := {"number": "2", "type": "smd", "shape": "rect",
		"position": {"x": 1.4, "y": 0.0},
		"size": {"width": 1.25, "height": 1.75},
		"drill": {"x": 0.0, "y": 0.0}, "layers": ["F.Cu"]}
	var bare = PCBComponent.new()
	bare.load_from_board_dict(_component_with_pads([plain]))
	var bare_out: Array = (bare.to_board_dict() as Dictionary).get("pads", [])
	check_eq("the bare pad survives encode", bare_out.size(), 1)
	if bare_out.size() != 1:
		return
	for key in PCBComponent.PAD_OPTIONAL_KEYS:
		check("an absent %s stays absent" % key, not (bare_out[0] as Dictionary).has(key))


# ── 2. a roundrect land is its own shape ──────────────────────────────────────

## An 8.0 x 2.0mm roundrect at the component origin. `ratio` null states no
## corner radius at all, which is the case that must stay the stadium.
func _roundrect_pad(ratio) -> Dictionary:
	var pad := {"number": "1", "type": "smd", "shape": "roundrect",
		"position": {"x": 0.0, "y": 0.0},
		"size": {"width": 8.0, "height": 2.0},
		"layers": ["F.Cu"]}
	if ratio != null:
		pad["corner_rratio"] = ratio
	return pad


## The land at (20, 20), a 0.05mm trace running in from the right and ending on
## the CORNER region at (23.8, 20.8), and a second pad on the same net at the
## trace's far end. Whether the net still owes a join is the measurement.
func _corner_probe_board(ratio):
	var d = PCBData.new()
	d.from_board_dict({
		"version": 1, "name": "corner-probe", "width_mm": 45.0, "height_mm": 45.0,
		"design_rules": {"clearance_mm": 0.2},
		"layers": ["top", "bottom"],
		"components": [
			{"ref": "P1", "footprint": "CUSTOM", "x_mm": 20.0, "y_mm": 20.0,
			 "rotation_deg": 0.0, "layer": "top",
			 "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}],
			 "pads": [_roundrect_pad(ratio)]},
			{"ref": "P2", "footprint": "CUSTOM", "x_mm": 30.0, "y_mm": 20.8,
			 "rotation_deg": 0.0, "layer": "top",
			 "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0,
					   "pad_width_mm": 1.0, "pad_height_mm": 1.0}]},
		],
		"nets": [{"name": "CORNER", "pins": ["P1.1", "P2.1"]}],
		"traces": [{"id": "t_corner", "net": "CORNER", "layer": "top",
			"width_mm": 0.05,
			"points": [{"x_mm": 30.0, "y_mm": 20.8}, {"x_mm": 23.8, "y_mm": 20.8}]}],
		"vias": [], "zones": [],
	})
	return d


func _remaining(result: Dictionary, net: String) -> int:
	for row in result.get("nets", []):
		if str((row as Dictionary).get("net", "")) == net:
			return int((row as Dictionary).get("remaining", 0))
	return 0


func _run_roundrect_land_is_not_the_inscribed_stadium() -> void:
	print("-- 2. a roundrect land is modelled at its authored corner radius --")
	# 0.25 of the 2.0mm short side = a 0.5mm corner radius. The trace end is
	# 0.0757mm inside that copper and 0.1314mm outside the inscribed stadium.
	check_eq("copper landing in the real corner joins the authored roundrect",
		_remaining(Ratsnest.compute(_corner_probe_board(0.25)), "CORNER"), 0)
	# The SAME copper against a land that states no corner radius: the model
	# falls back to the stadium every roundrect of this size contains, and the
	# corner is not copper it can vouch for.
	check_eq("…and does not join a land that states no corner radius",
		_remaining(Ratsnest.compute(_corner_probe_board(null)), "CORNER"), 1)
	# The maximal ratio IS the stadium, so it must answer like one.
	check_eq("…nor a land at the maximal 0.5 ratio, which is the stadium",
		_remaining(Ratsnest.compute(_corner_probe_board(0.5)), "CORNER"), 1)
	# A zero ratio is a sharp rectangle, which contains the corner point.
	check_eq("…and a zero ratio is a sharp rect, which does contain it",
		_remaining(Ratsnest.compute(_corner_probe_board(0.0)), "CORNER"), 0)


# ── 3. an indeterminate load-time check reaches a human ───────────────────────

func _run_indeterminate_checks_reach_a_human() -> void:
	print("-- 3. an indeterminate load-time check is shown, not just replied --")
	var clean := {"component_count": 4, "net_count": 2,
		"assembly": {"status": "pass", "findings": []},
		"board_health": {"complete": true, "missing_copper": [],
			"assembly": {"status": "pass", "findings": []}}}
	check_eq("a load where every check answered holds no lead",
		LoadChecks.status_lead(clean), "")

	var advisory := {"component_count": 4,
		"assembly": {"status": "indeterminate",
			"error": "assembly_check channel is down"},
		"board_health": {"complete": true}}
	var lead := LoadChecks.status_lead(advisory)
	check("an indeterminate assembly advisory leads the status line",
		lead.begins_with("CHECK INDETERMINATE:"))
	check("…and carries the check's own words for why",
		lead.contains("assembly_check channel is down"))
	check("…naming the check it came from", lead.contains("assembly"))

	# Not special-cased to assembly: any verdict object anywhere in the reply.
	var drc := {"board_drc": {"verdict": "indeterminate",
		"reason": "the board did not compile"}}
	var drc_lead := LoadChecks.status_lead(drc)
	check("a check the panel has never heard of is surfaced the same way",
		drc_lead.contains("board_drc") and drc_lead.contains("did not compile"))

	# The other shape the same fact takes: the check answered, but named
	# entities it could not judge.
	var partial := {"board_health": {"complete": null,
		"indeterminate": [{"net": "GND", "reason": "zone_copper"},
						  {"net": "+3V3", "reason": "zone_copper"}]}}
	check("a check that could not judge some entities says how many",
		LoadChecks.status_lead(partial).contains("2 item(s)"))
	check_eq("an EMPTY indeterminate list is not a finding",
		LoadChecks.status_lead({"board_health": {"indeterminate": []}}), "")

	# Two indeterminates, one lead — a human should not have to guess there
	# was a second one.
	var both := {"assembly": {"status": "indeterminate", "error": "no channel"},
		"board_drc": {"verdict": "indeterminate", "error": "no compile"}}
	check_eq("every indeterminate check is named, not just the first",
		LoadChecks.indeterminate_notes(both).size(), 2)


# ── 4. copper paints in manufacturing order ──────────────────────────

## Index of the pass with this kind and layer, or -1.
func _pass_index(plan: Array, kind: String, layer: String) -> int:
	for i in range(plan.size()):
		var step: Dictionary = plan[i]
		if str(step["kind"]) == kind and str(step["layer"]) == layer:
			return i
	return -1


## Index of the LAST pass of this kind, whatever layer it names, or -1.
func _last_pass_index(plan: Array, kind: String) -> int:
	var found := -1
	for i in range(plan.size()):
		if str((plan[i] as Dictionary)["kind"]) == kind:
			found = i
	return found


## Index of the first RecordingCanvas record of this kind, or of this kind with
## this exact id when one is given ("" means "any"). -1 when there is none.
func _rec_index(seq: Array, kind: String, id: String) -> int:
	for i in range(seq.size()):
		var rec: Dictionary = seq[i]
		if str(rec["kind"]) == kind and (id.is_empty() or str(rec["id"]) == id):
			return i
	return -1


## Index of the LAST record of this kind, or -1.
func _last_rec_index(seq: Array, kind: String) -> int:
	var found := -1
	for i in range(seq.size()):
		if str((seq[i] as Dictionary)["kind"]) == kind:
			found = i
	return found


## The reported board, as a loadable 2-layer board: bottom copper running under
## a top-mounted through-hole land, plus a top SMD land. Nothing else — every
## other entity would only add records between the ones being ordered.
func _draw_order_board():
	var d = PCBData.new()
	d.from_board_dict({
		"version": 1, "name": "draw-order", "width_mm": 40.0, "height_mm": 30.0,
		"layers": ["top", "bottom"],
		"components": [
			{"ref": "J1", "footprint": "CUSTOM", "x_mm": 10.0, "y_mm": 10.0,
			 "rotation_deg": 0.0, "layer": "top",
			 "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}],
			 "pads": [{"number": "1", "type": "thru_hole", "shape": "circle",
				"position": {"x": 0.0, "y": 0.0},
				"size": {"width": 1.6, "height": 1.6},
				"drill": 0.8, "layers": ["*.Cu"]}]},
			{"ref": "R1", "footprint": "CUSTOM", "x_mm": 20.0, "y_mm": 10.0,
			 "rotation_deg": 0.0, "layer": "top",
			 "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}],
			 "pads": [{"number": "1", "type": "smd", "shape": "rect",
				"position": {"x": 0.0, "y": 0.0},
				"size": {"width": 1.0, "height": 1.0}, "layers": ["F.Cu"]}]},
		],
		"nets": [{"name": "GND", "pins": ["J1.1", "R1.1"]}],
		"traces": [{"id": "t_bottom", "net": "GND", "layer": "bottom",
			"width_mm": 0.25,
			"points": [{"x_mm": 4.0, "y_mm": 10.0}, {"x_mm": 16.0, "y_mm": 10.0}]}],
		"vias": [], "zones": [],
	})
	return d


func _run_copper_paints_in_manufacturing_order() -> void:
	print("\n-- 4. copper: traces -> lands -> drills, per layer --")

	# The reported board, reduced: a 2-layer stack, copper on the bottom, and a
	# top-mounted part whose through-hole land the copper runs under.
	var plan: Array = PcbCopperDrawOrder.build(["top", "bottom"], ["bottom"], ["top"])

	var i_bottom_traces := _pass_index(plan, PcbCopperDrawOrder.TRACES, "bottom")
	var i_bottom_lands := _pass_index(plan, PcbCopperDrawOrder.SMD_LANDS, "bottom")
	var i_top_traces := _pass_index(plan, PcbCopperDrawOrder.TRACES, "top")
	var i_tht := _pass_index(plan, PcbCopperDrawOrder.THT_LANDS, "")
	var i_vias := _pass_index(plan, PcbCopperDrawOrder.VIAS, "")
	var i_drills := _pass_index(plan, PcbCopperDrawOrder.DRILLS, "")
	var i_last_traces := _last_pass_index(plan, PcbCopperDrawOrder.TRACES)

	check("THE BUG: the bottom trace paints BEFORE the through-hole land it "
			+ "runs under, so the trace ends under the land (%d < %d)"
					% [i_bottom_traces, i_tht],
			i_bottom_traces >= 0 and i_tht > i_bottom_traces)
	check("no copper of any layer paints after the through-hole lands (%d < %d)"
					% [i_last_traces, i_tht],
			i_last_traces >= 0 and i_tht > i_last_traces)
	check("the drill is a VOID over every piece of copper: it is the last pass "
			+ "of all (%d of %d)" % [i_drills, plan.size()],
			i_drills == plan.size() - 1)
	check("vias carry their ring with the lands and their hole with the drills "
			+ "(%d < %d < %d)" % [i_tht, i_vias, i_drills],
			i_tht < i_vias and i_vias < i_drills)

	check("stack order survives: bottom-most copper paints first (%d < %d)"
					% [i_bottom_traces, i_top_traces],
			i_bottom_traces < i_top_traces)
	check("PER LAYER, not one land pass at the end: the bottom lands paint "
			+ "before the TOP traces, so a top trace crossing over a bottom "
			+ "land still covers it (%d < %d)" % [i_bottom_lands, i_top_traces],
			i_bottom_lands >= 0 and i_bottom_lands < i_top_traces)
	check("...and each layer's lands paint directly after that layer's traces",
			i_bottom_lands == i_bottom_traces + 1)

	# Layer ids the declared stack never mentions: still painted, never dropped.
	var odd: Array = PcbCopperDrawOrder.build(["top", "bottom"], ["Mystery.Cu"], ["Mystery.Cu"])
	var i_odd_traces := _pass_index(odd, PcbCopperDrawOrder.TRACES, "Mystery.Cu")
	var i_odd_lands := _pass_index(odd, PcbCopperDrawOrder.SMD_LANDS, "Mystery.Cu")
	check("copper on an UNDECLARED layer still gets a pass — nothing an author "
			+ "wrote is silently undrawn", i_odd_traces >= 0)
	check("...and so do lands on one", i_odd_lands >= 0)
	check("...both above the declared stack, traces still under lands",
			i_odd_traces > _pass_index(odd, PcbCopperDrawOrder.TRACES, "top")
			and i_odd_traces < i_odd_lands)

	# The interleave is the stack's, not a hardcoded pair.
	var four: Array = PcbCopperDrawOrder.build(
			["top", "in1", "in2", "bottom"], ["in1"], ["top"])
	check_eq("every declared layer gets its own trace+land pair, plus the three "
			+ "board-wide passes", four.size(), 4 * 2 + 3)
	check("an inner layer paints in ITS stack position, under the layers above it",
			_pass_index(four, PcbCopperDrawOrder.TRACES, "in2")
					< _pass_index(four, PcbCopperDrawOrder.TRACES, "in1"))

	# WHICH PASS A LAND ACTUALLY LANDS IN, executed rather than planned.
	#
	# build() states the ORDER of the passes; _bucket_smd_lands is the other
	# half of _draw_copper — the routing that decides which pass each land is
	# handed to — and it is a pure function over a component, so it runs with
	# no render device. A land's layers are FOOTPRINT-LOCAL: a top-mounted part
	# whose footprint names B.Cu has bottom copper, and keying the whole part by
	# its mount side would paint that land on the wrong side of the board.
	var canvas = PcbCanvasScript.new()
	var mixed = PCBComponent.new()
	mixed.id = "U7"
	mixed.set_footprint_by_name("CUSTOM")
	mixed.layer = "top"
	mixed.has_pad_geometry = true
	mixed.pads = [
		{"number": "1", "type": "smd", "shape": "rect",
			"position": Vector2(-1.0, 0.0), "size": Vector2(1.0, 1.0),
			"rotation": 0.0, "drill": Vector2.ZERO, "layers": ["F.Cu"]},
		{"number": "2", "type": "smd", "shape": "rect",
			"position": Vector2(1.0, 0.0), "size": Vector2(1.0, 1.0),
			"rotation": 0.0, "drill": Vector2.ZERO, "layers": ["B.Cu"]},
	]
	var buckets := {}
	canvas._bucket_smd_lands(mixed, buckets)
	var top_numbers: Array = []
	for entry in buckets.get("top", []):
		top_numbers.append(str(((entry as Dictionary)["pad"] as Dictionary)["number"]))
	var bottom_numbers: Array = []
	for entry in buckets.get("bottom", []):
		bottom_numbers.append(str(((entry as Dictionary)["pad"] as Dictionary)["number"]))
	check("a top-mounted part's B.Cu land is bucketed into the BOTTOM pass, not "
			+ "its part's (top=%s bottom=%s)" % [str(top_numbers), str(bottom_numbers)],
			top_numbers == ["1"] and bottom_numbers == ["2"])

	# WHETHER A LAND IS COPPER AT ALL is the same declaration's other answer.
	# KiCad splits a thermal pad into unnumbered `(pad "" smd ...
	# (layers "F.Paste"))` stencil nodes: they are apertures, not lands, and
	# routing one onto the mount layer paints copper the fab never makes. The
	# legacy declaration — no `layers` key at all — is the opposite case and
	# must keep its historical copper. Both readings are the worker's
	# (pad_source.has_copper, which gerber's copper bucket and drc's pad
	# harvest gate on).
	var apertures = PCBComponent.new()
	apertures.id = "U8"
	apertures.set_footprint_by_name("CUSTOM")
	apertures.layer = "top"
	apertures.has_pad_geometry = true
	apertures.pads = [
		{"number": "", "type": "smd", "shape": "rect",
			"position": Vector2(-1.0, 0.0), "size": Vector2(1.0, 1.0),
			"rotation": 0.0, "drill": Vector2.ZERO,
			"layers": ["F.Paste", "F.Mask"]},
		{"number": "3", "type": "smd", "shape": "rect",
			"position": Vector2(1.0, 0.0), "size": Vector2(1.0, 1.0),
			"rotation": 0.0, "drill": Vector2.ZERO},
	]
	var aperture_buckets := {}
	canvas._bucket_smd_lands(apertures, aperture_buckets)
	var routed: Array = []
	for lid in aperture_buckets:
		for entry in aperture_buckets[lid]:
			routed.append("%s:%s" % [str(lid),
				str(((entry as Dictionary)["pad"] as Dictionary).get("number", ""))])
	check("a paste/mask-only aperture names no copper, so it is routed to NO "
			+ "copper pass — not to its part's mount side (routed=%s)" % str(routed),
			not routed.has("top:") and not routed.has("bottom:"))
	check("…while a land declaring no `layers` key at all is the LEGACY case and "
			+ "still falls back to the mount side (routed=%s)" % str(routed),
			routed == ["top:3"])
	canvas.free()

	# THE DISPATCH ITSELF, EXECUTED. build() states the pass order and
	# _bucket_smd_lands the routing; what remains unmeasured is that
	# _draw_copper() really walks that plan and hands each pass to the painter
	# it names. Every arm ends in a painter METHOD, so a subclass that records
	# instead of drawing (recording_canvas.gd) observes the whole sequence with
	# no render device — the older note here said GDScript could not spy on
	# those methods, which is simply not true of an overridable method.
	var rec = RecordingCanvas.new()
	rec.data = _draw_order_board()
	rec._draw_copper()
	var seq: Array = rec.records
	var r_trace := _rec_index(seq, "trace", "t_bottom")
	var r_smd := _rec_index(seq, "land", "R1.1")
	var r_tht := _rec_index(seq, "land", "J1.1")
	var r_last_trace := _last_rec_index(seq, "trace")
	var r_last_land := _last_rec_index(seq, "land")
	var r_first_drill := _rec_index(seq, "drill", "")
	check("the fixture actually painted: a bottom trace, a top SMD land and a "
			+ "top through-hole land all reached a painter (%s)" % str(seq),
			r_trace >= 0 and r_smd >= 0 and r_tht >= 0)
	check("EXECUTED: the bottom trace is painted before the top SMD land above "
			+ "it (%d < %d)" % [r_trace, r_smd], r_trace >= 0 and r_trace < r_smd)
	check("EXECUTED: the through-hole land is painted after every trace, so the "
			+ "trace ends UNDER the land it enters (%d < %d)"
					% [r_last_trace, r_tht],
			r_last_trace >= 0 and r_tht > r_last_trace)
	check("EXECUTED: every drill is a void over all copper — the first drill "
			+ "follows the last land (%d < %d)" % [r_last_land, r_first_drill],
			r_first_drill >= 0 and r_first_drill > r_last_land)
	check("EXECUTED: the drill of the through-hole land is its OWN land's hole, "
			+ "painted in the drill pass and not beside its copper",
			_rec_index(seq, "drill", "J1.1") > r_tht)
	rec.free()


func check(desc: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s" % desc)


func check_eq(desc: String, actual, expected) -> void:
	check("%s (expected %s, got %s)" % [desc, str(expected), str(actual)], actual == expected)
