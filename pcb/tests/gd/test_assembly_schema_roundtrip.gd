extends SceneTree
## THE ASSEMBLY BLOCK SURVIVES A PROMOTE.
##
## Run (via a Minerva scaffold as the Godot host — NEVER the live checkout):
##   godot --headless --path <minerva-scaffold>/src \
##     --script res://../../minerva-plugins/pcb/tests/gd/test_assembly_schema_roundtrip.gd
##
## WHAT IS AT STAKE. `assembly` is the ONLY place a board says which part to buy
## and which designator each physical instance is placed under. The panel does
## not model it: it rides `PcbComponent.canonical_extra`, the verbatim
## passthrough for canonical keys the model has no field for. A passthrough that
## drops one key is invisible until an order goes out with the wrong part in it —
## which is exactly how `assembly: exclude` and `mpn` were lost once already
## (epoch CPN1).
##
## THE ORACLE, in one sentence: a promote → deserialize → load round trip that
## drops any assembly field or any placement ref fails this suite.
##
##   Section 1 — the panel half, no worker. The block goes through
##     from_board_dict → to_board_dict, through a duplicate, and through the
##     undo-history codec (to_dict/from_dict), and comes back identical. A board
##     with no assembly data grows no assembly key.
##   Section 2 — the REAL worker. The panel's board dict goes out over
##     pcb.serialize, comes back as canonical YAML, and re-enters through
##     pcb.deserialize. Every field and every placement ref is checked on the
##     board that arrives, and the LEGACY `assembly: exclude` scalar must arrive
##     migrated to the structured non-populated state.
##   Section 3 — the untouched case. A board that never heard of the block
##     round-trips through the same real worker with no assembly key anywhere.
##
## FAILS AGAINST OLD: the Go contract typed Component.Assembly as a STRING, so
## the structured block in Section 2 refuses at pcb.serialize before a byte of
## YAML is written.

const PcbComponent := preload("res://../../minerva-plugins/pcb/ui/model/pcb_component.gd")
const PLUGIN_ROOT := "res://../../minerva-plugins/pcb"
const BOARD_ID := "board:00000000000000000000000000000000"
const EPS := 0.0001

## The fully-authored block: every field the contract carries, plus a two-instance
## expansion whose refs are AUTHORED (never exporter-invented).
const FULL_ASSEMBLY := {
	"populate": true,
	"manufacturer": "Sullins",
	"mpn": "PPTC071LFBN-RC",
	"package": "PinSocket_1x07_P2.54mm",
	"comment": "1x7 2.54mm socket strip",
	"house_parts": {"jlcpcb": "C41376161"},
	"paste": "exclude",
	"placements": [
		{"ref": "J1S_A", "offset_mm": {"x": 0.0, "y": 0.0}, "rotation_deg": 0.0},
		{"ref": "J1S_B", "offset_mm": {"x": 22.86, "y": 0.0}, "rotation_deg": 180.0},
	],
}

var _pass := 0
var _fail := 0
var _used_real_worker := false
var _worker_fell_back := false


func _init() -> void:
	print("=== The assembly block survives a promote ===\n")
	_run_panel_passthrough()
	_run_real_worker_round_trip()
	_run_board_without_assembly()
	print("\n=== Results: %d passed, %d failed (real_worker_used=%s) ===" % [
		_pass, _fail, str(_used_real_worker)])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


## Dictionary `==` semantics have moved between Godot versions; a canonical
## block is compared by its SERIALIZED form, which also makes a failure legible.
func _same(a: Variant, b: Variant) -> bool:
	return JSON.stringify(a) == JSON.stringify(b)


func check(desc: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s%s" % [desc, ("" if detail == "" else " — " + detail)])


# ── fixture ───────────────────────────────────────────────────────────────────

## One canonical component dict. `assembly` is passed through verbatim so the
## same builder makes the structured, the legacy-scalar and the absent cases.
func _component(ref: String, x: float, assembly: Variant) -> Dictionary:
	var d := {
		"ref": ref, "footprint": "Resistor_SMD:R_0805_2012Metric",
		"x_mm": x, "y_mm": 10.0, "rotation_deg": 0.0, "layer": "top",
		"value": "10k",
		"pins": [{"number": "1", "x_mm": -0.9125, "y_mm": 0.0},
			{"number": "2", "x_mm": 0.9125, "y_mm": 0.0}],
	}
	if assembly != null:
		d["assembly"] = assembly
	return d


## C1 states nothing, FID1 carries the LEGACY scalar, J1S carries the full block.
func _board() -> Dictionary:
	return {
		"version": 2, "id": BOARD_ID, "name": "assembly-roundtrip",
		"width_mm": 60.0, "height_mm": 40.0, "layers": ["top", "bottom"],
		"design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
			"via_diameter_mm": 0.8, "via_drill_mm": 0.4},
		"components": [
			_component("C1", 5.0, null),
			_component("FID1", 15.0, "exclude"),
			_component("J1S", 30.0, FULL_ASSEMBLY.duplicate(true)),
		],
		"nets": [],
	}


func _component_by_ref(board: Dictionary, ref: String) -> Dictionary:
	for c in board.get("components", []):
		if c is Dictionary and str((c as Dictionary).get("ref", "")) == ref:
			return c
	return {}


# ── the real worker ───────────────────────────────────────────────────────────

func _worker_call(tool_name: String, request: Dictionary, fallback: Dictionary) -> Dictionary:
	var binary_path := ProjectSettings.globalize_path(PLUGIN_ROOT + "/pcb-plugin")
	var wrapper_path := ProjectSettings.globalize_path(PLUGIN_ROOT + "/scripts/e2e_route_stdio.py")
	if not FileAccess.file_exists(binary_path) or not FileAccess.file_exists(wrapper_path):
		_worker_fell_back = true
		_used_real_worker = false
		push_warning("[test_assembly_schema_roundtrip] real pcb-plugin binary not built — canned fallback")
		return fallback
	var req_uri := "user://assembly_schema_roundtrip_request.json"
	var f := FileAccess.open(req_uri, FileAccess.WRITE)
	if f == null:
		_worker_fell_back = true
		_used_real_worker = false
		printerr("[test_assembly_schema_roundtrip] REAL-WORKER INVOCATION FAILED: cannot write %s" % req_uri)
		return fallback
	f.store_string(JSON.stringify(request))
	f.close()
	var req_abs := ProjectSettings.globalize_path(req_uri)
	var output: Array = []
	var exit_code := OS.execute("python3",
		[wrapper_path, binary_path, req_abs, tool_name], output, true)
	DirAccess.remove_absolute(req_abs)
	var parsed: Variant = null
	if not output.is_empty():
		parsed = JSON.parse_string(str(output[0]))
	if exit_code == 0 and parsed is Dictionary and (parsed as Dictionary).has("ok"):
		if not _worker_fell_back:
			_used_real_worker = true
		return parsed
	_worker_fell_back = true
	_used_real_worker = false
	printerr("[test_assembly_schema_roundtrip] REAL-WORKER %s FAILED (exit=%d): %s" % [
		tool_name, exit_code, str(output[0]).left(500) if not output.is_empty() else "no output"])
	return fallback


func _result_of(reply: Dictionary) -> Dictionary:
	if not bool(reply.get("ok", false)):
		return {}
	var result: Variant = reply.get("result", reply)
	return result if result is Dictionary else {}


## The promote half: a panel board dict out, canonical YAML back.
func _promote_to_yaml(board: Dictionary) -> String:
	var res := _result_of(_worker_call("pcb.serialize", {"board": board}, {"ok": false}))
	return str(res.get("yaml", ""))


## The load half: canonical YAML in, a board dict back.
func _load_from_yaml(yaml_text: String) -> Dictionary:
	var res := _result_of(_worker_call("pcb.deserialize", {"yaml": yaml_text}, {"ok": false}))
	var b: Variant = res.get("board")
	return b if b is Dictionary else {}


# ── Section 1: the panel passthrough ──────────────────────────────────────────

func _run_panel_passthrough() -> void:
	print("── 1. The panel model carries the block verbatim ──")
	var authored := _component("J1S", 30.0, FULL_ASSEMBLY.duplicate(true))
	var comp: Variant = PcbComponent.from_board_dict(authored)
	var emitted: Dictionary = comp.to_board_dict()

	check("1a. the structured block survives from_board_dict -> to_board_dict",
		_same(emitted.get("assembly"), FULL_ASSEMBLY),
		JSON.stringify(emitted.get("assembly")))
	var placements: Array = (emitted.get("assembly", {}) as Dictionary).get("placements", [])
	check("1b. both AUTHORED placement refs survive, in order",
		placements.size() == 2
			and str((placements[0] as Dictionary).get("ref", "")) == "J1S_A"
			and str((placements[1] as Dictionary).get("ref", "")) == "J1S_B",
		str(placements))

	# The panel does NOT migrate: the codec owns that, and a panel that rewrote
	# the value would be a second, competing authority over the same key.
	var legacy: Variant = PcbComponent.from_board_dict(_component("FID1", 15.0, "exclude"))
	check("1c. the legacy scalar rides through the panel untouched",
		legacy.to_board_dict().get("assembly") == "exclude",
		str(legacy.to_board_dict().get("assembly")))

	var copy: Variant = comp.duplicate_component()
	check("1d. a duplicated component keeps the block (a copy that lost it is a different PART)",
		_same(copy.to_board_dict().get("assembly"), FULL_ASSEMBLY),
		JSON.stringify(copy.to_board_dict().get("assembly")))

	# Undo history reconstructs components from the LEGACY codec, so the block
	# has to survive that shape too or an undo silently erases the part identity.
	var restored: Variant = PcbComponent.from_dict(comp.to_dict())
	check("1e. the undo-history codec (to_dict/from_dict) keeps the block",
		_same(restored.to_board_dict().get("assembly"), FULL_ASSEMBLY),
		JSON.stringify(restored.to_board_dict().get("assembly")))

	var plain: Variant = PcbComponent.from_board_dict(_component("C1", 5.0, null))
	check("1f. a component with no assembly data grows no assembly key",
		not plain.to_board_dict().has("assembly"))


# ── Section 2: promote -> deserialize -> load, through the real worker ────────

func _run_real_worker_round_trip() -> void:
	print("── 2. Promote -> deserialize -> load keeps every field ──")
	var yaml_text := _promote_to_yaml(_board())
	check("2a. pcb.serialize accepted a board carrying the structured block",
		yaml_text != "",
		"empty yaml — the contract refused the block")
	check("2b. the emitted document carries the part identity",
		yaml_text.contains("PPTC071LFBN-RC") and yaml_text.contains("C41376161"))
	check("2c. the emitted document carries both authored placement refs",
		yaml_text.contains("J1S_A") and yaml_text.contains("J1S_B"))
	check("2d. the legacy scalar was MIGRATED, not re-emitted",
		not yaml_text.contains("assembly: exclude"),
		yaml_text)

	var back := _load_from_yaml(yaml_text)
	check("2e. pcb.deserialize returned a board",
		back.has("components") and (back["components"] as Array).size() == 3)

	var j1s := _component_by_ref(back, "J1S")
	var a: Dictionary = j1s.get("assembly", {}) if j1s.get("assembly") is Dictionary else {}
	check("2f. the block came back at all", not a.is_empty(), str(j1s))
	check("2g. populate survived as an authored true (not omitted away)",
		a.get("populate") == true, str(a.get("populate")))
	check("2h. manufacturer / mpn / package / comment all survived",
		str(a.get("manufacturer", "")) == "Sullins"
			and str(a.get("mpn", "")) == "PPTC071LFBN-RC"
			and str(a.get("package", "")) == "PinSocket_1x07_P2.54mm"
			and str(a.get("comment", "")) == "1x7 2.54mm socket strip",
		str(a))
	check("2i. house_parts survived, keyed by house",
		(a.get("house_parts", {}) as Dictionary).get("jlcpcb", "") == "C41376161",
		str(a.get("house_parts")))
	check("2j. paste survived", str(a.get("paste", "")) == "exclude", str(a.get("paste")))

	var back_placements: Array = a.get("placements", []) if a.get("placements") is Array else []
	check("2k. both placements survived, in authored order",
		back_placements.size() == 2
			and str((back_placements[0] as Dictionary).get("ref", "")) == "J1S_A"
			and str((back_placements[1] as Dictionary).get("ref", "")) == "J1S_B",
		str(back_placements))
	var second: Dictionary = back_placements[1] if back_placements.size() == 2 else {}
	var offset: Dictionary = second.get("offset_mm", {}) if second.get("offset_mm") is Dictionary else {}
	check("2l. the placement transform survived (offset + rotation)",
		abs(float(offset.get("x", -1.0)) - 22.86) < EPS
			and abs(float(offset.get("y", -1.0))) < EPS
			and abs(float(second.get("rotation_deg", -1.0)) - 180.0) < EPS,
		str(second))
	var first: Dictionary = back_placements[0] if back_placements.size() == 2 else {}
	var zero_offset: Dictionary = first.get("offset_mm", {}) if first.get("offset_mm") is Dictionary else {}
	check("2m. the AUTHORED ZERO offset survived as a stated zero, not an absent key",
		first.has("offset_mm")
			and abs(float(zero_offset.get("x", -1.0))) < EPS
			and abs(float(zero_offset.get("y", -1.0))) < EPS,
		str(first))

	var fid := _component_by_ref(back, "FID1")
	var fid_a: Dictionary = fid.get("assembly", {}) if fid.get("assembly") is Dictionary else {}
	check("2n. the legacy scalar arrived as the structured non-populated state",
		fid_a.get("populate") == false, str(fid.get("assembly")))

	var c1 := _component_by_ref(back, "C1")
	check("2o. a component that authored nothing still carries no assembly key",
		not c1.has("assembly"), str(c1.get("assembly")))

	# And the board that comes back re-enters the panel model losslessly — the
	# last hop of a real load.
	var reloaded: Variant = PcbComponent.from_board_dict(j1s)
	check("2p. the round-tripped block re-enters the panel model unchanged",
		_same(reloaded.to_board_dict().get("assembly"), a),
		JSON.stringify(reloaded.to_board_dict().get("assembly")))


# ── Section 3: a board that never heard of the block ──────────────────────────

func _run_board_without_assembly() -> void:
	print("── 3. A board with no assembly data loads exactly as it did ──")
	var plain_board := _board()
	plain_board["components"] = [_component("C1", 5.0, null), _component("R2", 20.0, null)]
	var yaml_text := _promote_to_yaml(plain_board)
	check("3a. it serializes", yaml_text != "")
	check("3b. no assembly key appears anywhere in the document",
		yaml_text != "" and not yaml_text.contains("assembly"),
		yaml_text)
	var back := _load_from_yaml(yaml_text)
	check("3c. it loads back with both components and no assembly key",
		(back.get("components", []) as Array).size() == 2
			and not _component_by_ref(back, "C1").has("assembly")
			and not _component_by_ref(back, "R2").has("assembly"),
		str(back.get("components")))
