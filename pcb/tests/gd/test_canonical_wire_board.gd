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
## Run:
##   godot --headless --path src --script ../../minerva-plugins/pcb/tests/gd/test_canonical_wire_board.gd

const PANEL_TOOLS_PATH := "res://../../minerva-plugins/pcb/ui/panel_tools.gd"
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
	_check(not (mw[2] as Dictionary).has("pads"),
		"library-ref part (Lib:Part) drops pads — worker re-derives")
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

	print("\n=== Results: %d passed, %d failed ===" % [_passed, _fail])
	quit(1 if _fail > 0 else 0)
