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

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== pad fidelity + load-check visibility ===\n")
	_run_pad_codec_carries_the_fab_optionals()
	_run_roundrect_land_is_not_the_inscribed_stadium()
	_run_indeterminate_checks_reach_a_human()
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
		"width": 4.6, "height": 2.3, "has_pad_geometry": true,
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
		"grid_mm": 2.54, "design_rules": {"clearance_mm": 0.2},
		"layers": ["top", "bottom"],
		"components": [
			{"ref": "P1", "footprint": "CUSTOM", "x_mm": 20.0, "y_mm": 20.0,
			 "rotation_deg": 0.0, "layer": "top", "width": 9.0, "height": 3.0,
			 "has_pad_geometry": true,
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


func check(desc: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s" % desc)


func check_eq(desc: String, actual, expected) -> void:
	check("%s (expected %s, got %s)" % [desc, str(expected), str(actual)], actual == expected)
