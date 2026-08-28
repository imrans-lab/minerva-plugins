extends SceneTree
## Bug 01a007f1dd02 — the assembly advisory shipped the panel's ENRICHED board
## dict over the pcb.assembly_check / pcb.board_health broker channels, and on
## an ordinary 36-component board (smart-remote-v2) that payload was 116,260
## bytes against the host broker's 64 KiB cap (PluginScenePanelBroker
## MAX_PAYLOAD_BYTES): the broker refused, the advisory came back permanently
## indeterminate, and the placement-blocker gate went silently inert on
## exactly the boards big enough to need it.
##
## THE FIXTURE IS THE REPRO: testdata/payload_cap_fixture.json is a real
## worker tolerant-resolve output — the exact shape the load path ships — over
## a SYNTHETIC board: 30 generic parts (U1..U30, value GENERIC) on a grid,
## every footprint drawn from this plugin's own bundled seed library. It is
## deliberately NOT a real design: the defect is a function of enrichment
## VOLUME, not of any particular board, and a fixture that carried someone's
## actual placements would publish that design in a test file. Two parts are
## nudged onto their neighbours so the fixture also exercises a findings
## verdict rather than a bare pass.
##
## The first assertion group proves the fixture STILL exceeds the cap — so
## this suite re-demonstrates the defect condition on every run — and then
## proves canonical_wire_board() brings it under the plugin's own 60 KiB
## headroom target while dropping ONLY fields the worker provably never reads
## (poison-proven in worker/tests/test_board_health_resolve_first.py; the
## worker resolves tolerantly from the library chain on both channels — bug
## 01a01b6bc649).
##
## Regenerate the fixture: see the generator recorded on plugins docket bug
## 01a007f1dd02 — grid-place N parts over the resolvable seed footprints,
## tolerant-resolve, dump compact with sorted keys. Any board whose enriched
## form clears 64 KiB works; nothing here depends on the specific parts.
##
## SECTION F pins the OTHER half of the same trim: which components the trim is
## allowed to fire on. footprint_resolved used to round-trip through the
## component codec, so a by-ref board authored where the library HAD the ref
## reopened elsewhere still claiming resolved — and the trim dropped the pads
## off a part the second machine could not resolve either. The flag is session
## state now: set only from a resolve run here, stripped out of everything
## written to disk, and never restored from a document.
##
## Run:
##   godot --headless --path src --script ../../minerva-plugins/pcb/tests/gd/test_canonical_wire_board.gd

const PANEL_TOOLS_PATH := "res://../../minerva-plugins/pcb/ui/panel_tools.gd"
const COMPONENT_PATH := "res://../../minerva-plugins/pcb/ui/model/pcb_component.gd"
const DATA_PATH := "res://../../minerva-plugins/pcb/ui/model/pcb_data.gd"
const FIXTURE_PATH := "res://../../minerva-plugins/pcb/tests/gd/testdata/payload_cap_fixture.json"

## The host broker's request-payload ceiling (PluginScenePanelBroker.gd /
## PluginWebviewBroker.gd MAX_PAYLOAD_BYTES). Literal rather than a preload of
## the broker script: the value is pinned independently in two repos already
## (Minerva's brokers and this plugin's Go-side serialize guard at 60 KiB).
const BROKER_CAP := 65536
## The plugin's own headroom target (internal/board/yaml.go MaxPayloadBytes).
const HEADROOM_CAP := 60 * 1024

## Mirror of panel_tools._WIRE_DROP_COMPONENT_FIELDS minus `pads` (which is
## conditional). Deliberately a COPY, not a read of the const: if the drop
## list ever loses a render field, the aggregated absence checks below go red
## instead of silently shrinking with it.
const RENDER_TAIL := [
	"graphics", "refdes_graphics", "local_bounds", "width", "height",
	"bbox_center_offset", "properties", "color", "has_pad_geometry",
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


## Fake data model: hands _run_assembly_check the fat enriched dict as its
## to_board_dict(), the way a live PCBData whose components carry render
## detail would.
class FatData:
	extends RefCounted
	var board_revision: int = 7
	var board: Dictionary = {}
	func to_board_dict() -> Dictionary:
		return board


func _load_fixture() -> Dictionary:
	var f := FileAccess.open(FIXTURE_PATH, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return parsed if parsed is Dictionary else {}


func _init() -> void:
	var tools: Script = load(PANEL_TOOLS_PATH)
	_check(tools != null, "panel_tools.gd loads")

	var full: Dictionary = _load_fixture()
	_check(not full.is_empty(), "enriched fixture loads and parses")

	# ── A. The repro, then the fix, on the fixture ───────────────────────────
	var full_size := JSON.stringify({"board": full}).length()
	_check(full_size > BROKER_CAP,
		"REPRO: enriched payload exceeds the 64 KiB broker cap (%d bytes)" % full_size)

	var wire: Dictionary = tools.canonical_wire_board(full)
	var wire_size := JSON.stringify({"board": wire}).length()
	_check(wire_size <= HEADROOM_CAP,
		"FIX: canonical wire payload under the 60 KiB headroom target (%d bytes)" % wire_size)
	_check(wire_size * 4 <= full_size,
		"wire payload is at most a quarter of the enriched payload")

	# ── B. What was dropped, what survives ───────────────────────────────────
	var comps_full: Array = full.get("components", [])
	var comps_wire: Array = wire.get("components", [])
	_check(comps_wire.size() == comps_full.size(), "component count preserved")

	var tail_clean := true
	var resolved_pads_dropped := true
	var identity_kept := true
	var pins_kept := true
	for i in comps_full.size():
		var before: Dictionary = comps_full[i]
		var after: Dictionary = comps_wire[i]
		for field in RENDER_TAIL:
			if after.has(field):
				tail_clean = false
		# Every fixture component is library-resolved, so no wire component
		# may carry pads — the worker re-derives them.
		if bool(before.get("footprint_resolved", false)) and after.has("pads"):
			resolved_pads_dropped = false
		for field in ["ref", "footprint", "x_mm", "y_mm", "rotation_deg", "layer", "value"]:
			if before.has(field) and (not after.has(field) or after[field] != before[field]):
				identity_kept = false
		if before.has("pins") and (not after.has("pins") or after["pins"] != before["pins"]):
			pins_kept = false
	_check(tail_clean, "no wire component carries any render-tail field")
	_check(resolved_pads_dropped, "library-resolved components ship no pads")
	_check(identity_kept, "ref/footprint/position/rotation/layer/value survive verbatim")
	_check(pins_kept, "pins (canonical fab geometry) survive verbatim")

	var sections_kept := true
	for key in full:
		if key == "components":
			continue
		if not wire.has(key) or wire[key] != full[key]:
			sections_kept = false
	_check(sections_kept,
		"every non-component board section passes through identically (drop-list, not keep-list)")

	# ── C. The pads rule on synthetic components ─────────────────────────────
	var custom_pads := [{"number": "1", "position": {"x": 0.0, "y": 0.0},
		"size": {"width": 2.0, "height": 2.0}}]
	var mixed := {"components": [
		{"ref": "X1", "footprint": "CUSTOM", "pads": custom_pads,
			"pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}],
			"has_pad_geometry": true, "graphics": [{"junk": true}]},
		{"ref": "X2", "footprint": "RESISTOR", "pads": custom_pads},
		{"ref": "X3", "footprint": "Lib:Part", "pads": custom_pads},
		{"ref": "X4", "footprint": "WEIRD", "footprint_resolved": true, "pads": custom_pads},
	]}
	var mixed_wire: Dictionary = tools.canonical_wire_board(mixed)
	var mw: Array = mixed_wire["components"]
	_check((mw[0] as Dictionary).get("pads", []) == custom_pads,
		"CUSTOM part keeps pads — the panel's pads are its only geometry")
	_check((mw[1] as Dictionary).get("pads", []) == custom_pads,
		"parametric enum part (RESISTOR) keeps pads")
	# A COLON-SHAPED REF IS NOT A LIBRARY THIS HOST HAS. Keying the drop on the
	# shape of the string hands the worker, on a machine whose library lacks the
	# part, a component with no pads and a ref it cannot resolve — and under the
	# FULL/PARTIAL rule the `pads` KEY is the declaration that the BOARD owns the
	# geometry, so dropping it demotes a FULL part to a PARTIAL one. Only the
	# MEASURED resolve fact drops pads.
	_check((mw[2] as Dictionary).get("pads", []) == custom_pads,
		"library-SHAPED ref with no resolve behind it KEEPS pads — the key is the board's geometry authority, not a size optimisation")
	_check(not (mw[3] as Dictionary).has("pads"),
		"footprint_resolved part drops pads even without a colon ref")
	_check((mw[0] as Dictionary).get("pins") == mixed["components"][0]["pins"],
		"custom part keeps its pins alongside its pads")

	# ── D. Idempotency + malformed-input tolerance ───────────────────────────
	_check(tools.canonical_wire_board(wire) == wire,
		"idempotent: projecting the wire form again is the identity")
	_check(tools.canonical_wire_board({}) == {"components": []},
		"empty board projects to an empty canonical board")
	_check(tools.canonical_wire_board({"components": "junk"}) == {"components": []},
		"non-array components value degrades to an empty list, never a crash")
	var passthrough := {"components": [null, 42, "x"]}
	_check(tools.canonical_wire_board(passthrough)["components"] == [null, 42, "x"],
		"non-dict component entries pass through untouched")

	# ── E. The seam: _run_assembly_check puts the WIRE form on the channel ───
	var host := CaptureHost.new()
	var data := FatData.new()
	data.board = full
	var tri: Dictionary = await tools._run_assembly_check(host, data)
	_check(str(tri.get("status", "")) == "pass",
		"seam: canned channel reply round-trips to a pass tri-state")
	var sent_size := JSON.stringify({"board": host.captured_board}).length()
	_check(sent_size <= HEADROOM_CAP,
		"seam: the payload actually sent is under the headroom cap (%d bytes)" % sent_size)
	_check(host.captured_board == wire,
		"seam: the verb sends exactly the canonical wire form")

	# ── F. The trim decision is THIS session's resolve, not a saved flag ──────
	#
	# THE DEFECT F PINS. footprint_resolved round-tripped through the component
	# codec: a by-ref board authored where the library HAD the ref was saved
	# carrying the flag, and reopening it where the library does NOT have the
	# ref restored it verbatim. The trim above then dropped that component's
	# `pads` — and the worker on the second machine, with no library hit either,
	# was handed a PARTIAL part with no lands and no way to get them. Nothing
	# said so; the board simply stopped compiling.
	#
	# The oracle is the pair: the SAME saved document, loaded with and without a
	# live resolve behind it, must put pads on the wire in the first case and
	# not in the second.
	var comp_script: Script = load(COMPONENT_PATH)
	var data_script: Script = load(DATA_PATH)
	_check(comp_script != null and data_script != null,
		"pcb_component.gd and pcb_data.gd load")

	# A by-ref part as MACHINE A saved it: a library ref, real lands, and the
	# resolved flag A's library earned.
	var saved_comp := {
		"ref": "J9", "footprint": "Lib:PinHeader_1x02", "footprint_id": "Lib:PinHeader_1x02",
		"x_mm": 10.0, "y_mm": 10.0, "rotation_deg": 0.0, "layer": "top",
		"pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0},
			{"number": "2", "x_mm": 2.54, "y_mm": 0.0}],
		"pads": [
			{"number": "1", "position": {"x": 0.0, "y": 0.0},
				"size": {"width": 1.8, "height": 1.8}},
			{"number": "2", "position": {"x": 2.54, "y": 0.0},
				"size": {"width": 1.8, "height": 1.8}}],
		"has_pad_geometry": true,
		"footprint_resolved": true,
	}

	# MACHINE B: a plain document load. No resolve ran here, so nothing on this
	# host has said the ref is resolvable.
	var reopened = comp_script.new()
	reopened.load_from_board_dict(saved_comp)
	var reopened_dict: Dictionary = reopened.to_board_dict()
	_check(not reopened_dict.has("footprint_resolved"),
		"a saved footprint_resolved does not survive a document load — the flag is this session's, and this session has not resolved anything")
	var reopened_wire: Dictionary = tools.canonical_wire_board(
		{"components": [reopened_dict]})
	var reopened_wire_comp: Dictionary = reopened_wire["components"][0]
	_check((reopened_wire_comp.get("pads", []) as Array).size() == 2,
		"…so the reopened by-ref part still ships its lands — the worker here may not resolve the ref either, and a dropped `pads` KEY demotes it to PARTIAL")
	_check(str(reopened_wire_comp.get("footprint", "")) == "Lib:PinHeader_1x02",
		"…under its authored ref, so the worker can still try the library")

	# MACHINE A, or any host whose pcb.deserialize just resolved this board
	# against its OWN library: the caller says the flags are live, and the trim
	# fires — which is what keeps a by-ref board's wire small.
	var live = comp_script.new()
	live.load_from_board_dict(saved_comp, true)
	var live_dict: Dictionary = live.to_board_dict()
	_check(bool(live_dict.get("footprint_resolved", false)),
		"a load whose flags came from a live resolve keeps them")
	var live_wire: Dictionary = tools.canonical_wire_board({"components": [live_dict]})
	_check(not (live_wire["components"][0] as Dictionary).has("pads"),
		"…and the resolved by-ref part sheds its lands on the wire — the worker re-derives them from the library it just read")

	# A resolve performed IN this session (pcb_library_part.apply_geometry sets
	# exactly this field) reaches the wire the same way, with no document
	# involved at all — the case the old codec could not express, because the
	# flag only ever arrived through the canonical Extra passthrough.
	var added = comp_script.new()
	added.load_from_board_dict(saved_comp)
	added.footprint_resolved = true
	var added_wire: Dictionary = tools.canonical_wire_board(
		{"components": [added.to_board_dict()]})
	_check(not (added_wire["components"][0] as Dictionary).has("pads"),
		"a part resolved by THIS session's add path sheds its lands on the wire")

	# The save half: whatever the live board says, the document must not carry
	# the machine-local fact forward to the next machine.
	var saved_board: Dictionary = data_script.strip_session_state(
		{"width_mm": 40.0, "components": [live_dict, reopened_dict], "nets": []})
	var saved_clean := true
	for comp_v in (saved_board["components"] as Array):
		if (comp_v as Dictionary).has("footprint_resolved"):
			saved_clean = false
	_check(saved_clean,
		"the SAVED board dict carries no footprint_resolved on any component")
	var saved_first: Dictionary = saved_board["components"][0]
	_check(((saved_first.get("pads", []) as Array).size() == 2)
			and float(saved_board.get("width_mm", 0.0)) == 40.0,
		"…and strips nothing else — pads, identity and board sections are untouched")

	print("\n=== Results: %d passed, %d failed ===" % [_passed, _fail])
	quit(1 if _fail > 0 else 0)
