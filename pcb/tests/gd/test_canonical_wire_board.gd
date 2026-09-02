extends SceneTree
## THE CANONICAL DICT IS THE WIRE.
##
## The model's to_board_dict() emits the DESIGN and nothing else, and this
## host's resolve (silk, lands, designator anchors, the resolved fact) arrives
## BESIDE the board as pcb.deserialize's `resolved` map and lives on the model,
## never in the dict. That is what keeps the dict a real board sends over the
## pcb.assembly_check / pcb.board_health broker channels under the host
## broker's 64 KiB cap without a projection in between.
##
## THE FIXTURE IS THE REPRO, reshaped: testdata/payload_cap_fixture.json is a
## real worker tolerant-resolve output over a SYNTHETIC board — 30 generic
## parts (U1..U30, value GENERIC) on a grid, every footprint drawn from this
## plugin's own bundled seed library — split into {board, resolved}. The
## resolved half alone exceeds the plugin's 60 KiB headroom target; the dict
## the model puts on the wire after adopting it does not.
##
## SECTION F pins the session flag: footprint_resolved is set only from a
## resolve run here, never restored from a document, and never written into
## one — so a by-ref board authored where the library HAD the ref, reopened
## where it does not, cannot claim resolved.
##
## Run:
##   godot --headless --path src --script ../../minerva-plugins/pcb/tests/gd/test_canonical_wire_board.gd

const PANEL_TOOLS_PATH := "res://../../minerva-plugins/pcb/ui/panel_tools.gd"
const COMPONENT_PATH := "res://../../minerva-plugins/pcb/ui/model/pcb_component.gd"
const DATA_PATH := "res://../../minerva-plugins/pcb/ui/model/pcb_data.gd"
const FIXTURE_PATH := "res://../../minerva-plugins/pcb/tests/gd/testdata/payload_cap_fixture.json"

## The plugin's own headroom target (internal/board/yaml.go MaxPayloadBytes).
const HEADROOM_CAP := 60 * 1024

## Every key that is render or session state, and so must never appear on a
## canonical component dict. A COPY of the model's knowledge, deliberately: if
## the model starts emitting one of these again, this goes red.
const RENDER_TAIL := [
	"graphics", "refdes_graphics", "refdes_anchor", "local_bounds", "width",
	"height", "bbox_center_offset", "properties", "color", "has_pad_geometry",
	"footprint_id", "label_visible", "locked", "footprint_resolved",
]

var _passed := 0
var _fail := 0


func _check(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
		print("PASS: %s" % label)
	else:
		_fail += 1
		printerr("FAIL: %s" % label)


## Fake channel host for the _run_assembly_check seam: captures the board the
## verb actually puts on the wire and answers with a canned pass. No
## get_panel method, so _feed_assembly_cache is a documented no-op.
class CaptureHost:
	extends RefCounted
	var captured_board: Dictionary = {}
	func assembly_check(board: Dictionary) -> Dictionary:
		captured_board = board
		return {"ok": true, "result": {"status": "pass", "findings": []}}


func _load_fixture() -> Dictionary:
	var f := FileAccess.open(FIXTURE_PATH, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return parsed if parsed is Dictionary else {}


func _init() -> void:
	var tools: Script = load(PANEL_TOOLS_PATH)
	var comp_script: Script = load(COMPONENT_PATH)
	var data_script: Script = load(DATA_PATH)
	_check(tools != null and comp_script != null and data_script != null,
		"panel_tools.gd, pcb_component.gd and pcb_data.gd load")

	var fixture: Dictionary = _load_fixture()
	var board: Dictionary = fixture.get("board", {})
	var resolved: Dictionary = fixture.get("resolved", {})
	_check(not board.is_empty() and not resolved.is_empty(), "fixture loads: board + resolved")

	# ── A. The repro: the resolve is big, the wire dict is not ─────────────
	var resolved_size := JSON.stringify(resolved).length()
	_check(resolved_size > HEADROOM_CAP,
		"REPRO: this host's resolve of 30 parts exceeds the headroom cap (%d bytes)" % resolved_size)

	var data = data_script.new()
	data.from_board_dict(board, resolved)
	_check(data.components.size() == (board["components"] as Array).size(),
		"every fixture component loaded")
	var adopted := 0
	for cid in data.components:
		var comp = data.components[cid]
		# A silk-only part (the owl logo) resolves to graphics and zero lands.
		if comp.footprint_resolved and (not comp.pads.is_empty() or not comp.graphics.is_empty()):
			adopted += 1
	_check(adopted == (board["components"] as Array).size(),
		"…and every one adopted its resolved geometry and flag onto the MODEL (%d)" % adopted)

	var wire: Dictionary = data.to_board_dict()
	var wire_size := JSON.stringify({"board": wire}).length()
	_check(wire_size <= HEADROOM_CAP,
		"FIX: the dict the model puts on the wire is under the headroom cap (%d bytes)" % wire_size)

	# ── B. What the dict carries, what it does not ─────────────────────────
	var tail_clean := true
	var no_resolved_pads := true
	var identity_kept := true
	var identity_mismatch := ""
	var comps_in: Array = board["components"]
	var by_ref := {}
	for c in (wire["components"] as Array):
		by_ref[str((c as Dictionary).get("ref", ""))] = c
	for before_v in comps_in:
		var before: Dictionary = before_v
		var after: Dictionary = by_ref.get(str(before.get("ref", "")), {})
		for field in RENDER_TAIL:
			if after.has(field):
				tail_clean = false
		# Every fixture component is library-resolved: its lands are this
		# host's, so no dict may carry them.
		if after.has("pads"):
			no_resolved_pads = false
		# Positions round-trip through the model's float32 Vector2, so numbers
		# compare within that precision; identity strings compare exactly.
		for field in ["ref", "footprint", "x_mm", "y_mm", "rotation_deg", "value"]:
			if not before.has(field):
				continue
			var same: bool = after.has(field) and (
				is_equal_approx(float(before[field]), float(after[field]))
				if before[field] is float or before[field] is int else after[field] == before[field])
			if not same:
				identity_kept = false
				identity_mismatch = "%s.%s: %s -> %s" % [str(before.get("ref", "")), field,
					str(before.get(field)), str(after.get(field, "<absent>"))]
	_check(tail_clean, "no wire component carries any render or session field")
	# The BOARD root has a session field of its own: the drawing pitch, which
	# describes an editor rather than the copper and lives in the panel's
	# session state (ui/model/pcb_session_state.gd).
	_check(not wire.has("grid_mm"), "the wire board carries no grid_mm")
	_check(no_resolved_pads, "library-resolved components ship no pads — the lands are the library's")
	_check(identity_kept, "ref/footprint/position/rotation/value survive verbatim %s" % identity_mismatch)

	# ── C. The pads rule: the KEY is the board's geometry authority ────────
	var custom_pads := [{"number": "1", "position": {"x": 0.0, "y": 0.0},
		"size": {"width": 2.0, "height": 2.0}}]
	var owner = comp_script.new()
	owner.load_from_board_dict({"ref": "X1", "footprint": "CUSTOM", "pads": custom_pads,
		"pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}], "graphics": []})
	_check((owner.to_board_dict().get("pads", []) as Array).size() == 1,
		"a part that owns its lands emits the pads key")
	owner.adopt_resolved({"pads": [{"number": "9", "position": {"x": 5.0, "y": 5.0},
		"size": {"width": 1.0, "height": 1.0}}], "has_pad_geometry": true, "footprint_resolved": true})
	var owner_dict: Dictionary = owner.to_board_dict()
	_check(str((owner_dict["pads"] as Array)[0].get("number", "")) == "1",
		"…and a resolve cannot replace them: authored lands win over this host's library")
	_check(owner.footprint_resolved,
		"…while the resolved FACT is still adopted, so the badge can retire")

	var library_part = comp_script.new()
	library_part.load_from_board_dict({"ref": "X2", "footprint": "Lib:Part",
		"pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}]},
		{"pads": custom_pads, "has_pad_geometry": true, "footprint_resolved": true})
	_check(library_part.pads.size() == 1 and library_part.has_pad_geometry,
		"a library part renders the lands this host resolved")
	_check(not library_part.to_board_dict().has("pads"),
		"…and never states them as its own on the wire")

	# ── D. Tolerance ───────────────────────────────────────────────────────
	_check(not library_part.adopt_resolved({}), "an empty resolve entry changes nothing")
	_check(data.adopt_resolved({"NOPE": {"footprint_resolved": true}, "U1": "junk"}) == 0,
		"a resolve for an unknown ref, or a non-dict entry, is ignored")

	# ── E. The seam: _run_assembly_check puts to_board_dict on the channel ─
	var host := CaptureHost.new()
	var tri: Dictionary = await tools._run_assembly_check(host, data)
	_check(str(tri.get("status", "")) == "pass",
		"seam: canned channel reply round-trips to a pass tri-state")
	_check(host.captured_board == data.to_board_dict(),
		"seam: the verb sends exactly the canonical dict")

	# ── F. The session flag follows THIS host's resolve, not a document ────
	#
	# A by-ref part as MACHINE A saved it: a library ref and the lands it
	# authored. Nothing in a document can say "resolved".
	var saved_comp := {
		"ref": "J9", "footprint": "Lib:PinHeader_1x02",
		"x_mm": 10.0, "y_mm": 10.0, "rotation_deg": 0.0, "layer": "top",
		"pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0},
			{"number": "2", "x_mm": 2.54, "y_mm": 0.0}],
		"pads": [
			{"number": "1", "position": {"x": 0.0, "y": 0.0},
				"size": {"width": 1.8, "height": 1.8}},
			{"number": "2", "position": {"x": 2.54, "y": 0.0},
				"size": {"width": 1.8, "height": 1.8}}],
	}

	# MACHINE B: a plain document load. No resolve ran here.
	var reopened = comp_script.new()
	reopened.load_from_board_dict(saved_comp)
	_check(not reopened.footprint_resolved,
		"a document load leaves footprint_resolved false — this session has resolved nothing")
	var reopened_dict: Dictionary = reopened.to_board_dict()
	_check((reopened_dict.get("pads", []) as Array).size() == 2,
		"…and the reopened by-ref part still ships the lands it authored, so the worker here can build it")
	_check(str(reopened_dict.get("footprint", "")) == "Lib:PinHeader_1x02",
		"…under its authored ref, so the worker can still try the library")

	# MACHINE A, or any host whose pcb.deserialize just resolved this board
	# against its OWN library: the resolve entry sets the flag.
	var live = comp_script.new()
	live.load_from_board_dict(saved_comp, {"footprint_resolved": true})
	_check(live.footprint_resolved, "a load with this host's resolve beside it carries the flag")
	_check(not live.to_board_dict().has("footprint_resolved"),
		"…and the flag never reaches the dict, so no document can carry it forward")

	# The save half: whatever the live board says, the document must not carry
	# the machine-local fact forward to the next machine. There is one board
	# shape — the component dicts above ARE what a save writes.
	var saved_board: Dictionary = {"width_mm": 40.0,
		"components": [live.to_board_dict(), reopened_dict], "nets": []}
	var saved_clean := true
	for comp_v in (saved_board["components"] as Array):
		if (comp_v as Dictionary).has("footprint_resolved"):
			saved_clean = false
	_check(saved_clean, "the SAVED board dict carries no footprint_resolved on any component")
	_check((saved_board["components"][0].get("pads", []) as Array).size() == 2,
		"…while the lands the by-value part authored survive into it")

	print("\n=== Results: %d passed, %d failed ===" % [_passed, _fail])
	quit(1 if _fail > 0 else 0)
