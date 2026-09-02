extends SceneTree
## WHAT A PROMOTION CHANGED — the promote reply's `design_delta`.
##
## Run (via a Minerva scaffold as the Godot host — NEVER the live checkout):
##   godot --headless --path <minerva-scaffold>/src \
##     --script res://../../minerva-plugins/pcb/tests/gd/test_promote_delta.gd
##
## WHAT IS AT STAKE. `design_delta` is the promote reply's advisory answer to
## "what did this write change in the design of record": per component, every
## authored field that differs from the file being overwritten with its old and
## new value; the components and nets added and removed; the per-net trace and
## via counts that moved. It never gates.
##
## THE ORACLE, in one sentence: the file on disk is the independent observation.
## Section 2 writes a prior file that differs from the live board in ONE named
## field, and the reply must name that ref and that field with its old and new
## value — an implementation that reports counts, or reports nothing, fails.
## Section 1's oracle is the hand-authored board pair: each case states the ONE
## difference it planted, so a diff that misses it or invents a second one reds.
##
##   Section 1 — the comparison itself, pure. Board dicts in, delta out: no
##     panel, no worker, no file.
##   Section 2 — the whole promote, through a fake worker that is a JSON codec
##     (its `pcb.deserialize` parses the prior file's bytes as JSON, so the test
##     controls the prior design exactly). Reply shape, the unchanged case, the
##     no-prior-file case, and the status line the Promote button leaves.
##
## FAILS AGAINST OLD: the reply carried `census_delta` and no `design_delta` at
## all, so every Section 2 assertion reds, and pcb_promote_delta.gd does not
## exist for Section 1 to load.

const PANEL_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"
const PromoteDelta := preload("res://../../minerva-plugins/pcb/ui/pcb_promote_delta.gd")

var _pass := 0
var _fail := 0


func check(desc: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s%s" % [desc, ("" if detail == "" else " — " + detail)])


func check_eq(desc: String, actual, expected) -> void:
	check("%s (expected %s, got %s)" % [desc, str(expected), str(actual)],
		actual == expected)


## Container equality by SERIALIZED form: `==` semantics for Dictionary have
## moved between Godot versions, and a JSON round trip is also what makes an
## int and a float of the same value compare as one (the same reason
## test_assembly_schema_roundtrip.gd compares this way).
func check_same(desc: String, actual, expected) -> void:
	check("%s (expected %s, got %s)" % [desc,
			JSON.stringify(expected), JSON.stringify(actual)],
		JSON.stringify(actual) == JSON.stringify(expected))


func _init() -> void:
	print("=== The promote reply names what changed ===\n")
	await process_frame
	_run_pure_diff()
	await _run_through_promote()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


# ── Section 1: the comparison itself ────────────────────────────────────────

## Two components, one net, one trace, one via — small enough that every case
## below states its whole difference in one line.
func _base_board() -> Dictionary:
	return {"version": 1, "name": "delta", "width_mm": 20.0, "height_mm": 20.0,
		"layers": ["top", "bottom"],
		"components": [
			{"ref": "U3", "footprint": "Package_SO:SOIC-8", "value": "10k",
				"x_mm": 5.0, "y_mm": 6.0, "rotation_deg": 0.0, "layer": "top",
				"pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}],
				"assembly": {"mpn": "RC0805FR-0710KL", "populate": true,
					"house_parts": {"jlcpcb": "C84376"},
					"placements": [{"ref": "U3A",
						"offset_mm": {"x": 0.0, "y": 0.0}, "rotation_deg": 0}]}},
			{"ref": "R4", "footprint": "Resistor_SMD:R_0805_2012Metric",
				"value": "1k", "x_mm": 9.0, "y_mm": 2.0, "rotation_deg": 90.0,
				"layer": "top"},
		],
		"nets": [{"name": "GND", "pins": ["U3.1"]}, {"name": "NC1", "pins": []}],
		"traces": [{"net": "GND", "layer": "top"}],
		"vias": [{"net": "GND", "x_mm": 3.0, "y_mm": 3.0}]}


## The one changed component's field map, or {} when this ref is not reported.
func _fields_for(delta: Dictionary, ref: String) -> Dictionary:
	for entry in (delta.get("components_changed", []) as Array):
		if str((entry as Dictionary).get("ref", "")) == ref:
			return (entry as Dictionary).get("fields", {})
	return {}


func _run_pure_diff() -> void:
	print("-- 1: the comparison itself --")

	# 1a: THE CASE THE COUNT DELTA COULD NOT SEE. One value, one component, and
	# every count on this board is identical before and after.
	var after: Dictionary = _base_board()
	(after["components"][0] as Dictionary)["value"] = "22k"
	var d: Dictionary = PromoteDelta.compute(_base_board(), after)
	check_eq("1a: exactly one component is reported changed",
		(d.get("components_changed", []) as Array).size(), 1)
	var u3 := _fields_for(d, "U3")
	check_eq("1a: …and exactly one of its fields", u3.keys().size(), 1)
	check_eq("1a: …the value, from the file's",
		str((u3.get("value", {}) as Dictionary).get("from", "")), "10k")
	check_eq("1a: …to the board's",
		str((u3.get("value", {}) as Dictionary).get("to", "")), "22k")
	check_eq("1a: …with nothing added or removed",
		(d.get("components_added", []) as Array).size()
			+ (d.get("components_removed", []) as Array).size()
			+ (d.get("nets_changed", []) as Array).size(), 0)
	check("1a: …and the status clause names the count",
		PromoteDelta.summary_text(d).contains("1 component(s) changed"),
		PromoteDelta.summary_text(d))

	# 1b: the same board twice changes nothing. An "everything differs"
	# implementation (comparing dicts whole, or resolve keys with them) reds
	# here and nowhere else.
	var same: Dictionary = PromoteDelta.compute(_base_board(), _base_board())
	check("1b: an unchanged board reports an empty delta",
		PromoteDelta.is_unchanged(same), JSON.stringify(same))
	check("1b: …every list present and empty",
		(same.get("components_changed", ["x"]) as Array).is_empty()
		and (same.get("nets_added", ["x"]) as Array).is_empty()
		and (same.get("nets_removed", ["x"]) as Array).is_empty()
		and (same.get("nets_changed", ["x"]) as Array).is_empty())
	check_eq("1b: …and says so on the status line",
		PromoteDelta.summary_text(same), "")

	# 1c: the geometry fields, and the tolerance under them. A move of 1 nm is
	# the file's decimals against the model's float, not an edit.
	var moved: Dictionary = _base_board()
	(moved["components"][1] as Dictionary)["x_mm"] = 9.000000001
	check("1c: a sub-nanometre difference is representation, not a move",
		PromoteDelta.is_unchanged(PromoteDelta.compute(_base_board(), moved)))
	(moved["components"][1] as Dictionary)["x_mm"] = 9.5
	(moved["components"][1] as Dictionary)["rotation_deg"] = 270.0
	(moved["components"][1] as Dictionary)["layer"] = "bottom"
	var r4 := _fields_for(PromoteDelta.compute(_base_board(), moved), "R4")
	check_eq("1c: a real move, a rotate and a side flip are three fields",
		r4.keys().size(), 3)
	check_eq("1c: …the move carries its old millimetres",
		float((r4.get("x_mm", {}) as Dictionary).get("from", 0.0)), 9.0)
	check_eq("1c: …and the flip its old side",
		str((r4.get("layer", {}) as Dictionary).get("from", "")), "top")

	# 1d: assembly identity, key by key. The block is where a board says which
	# part to buy, so "the assembly changed" is not an answer — WHICH field is.
	var bought: Dictionary = _base_board()
	var asm: Dictionary = (bought["components"][0] as Dictionary)["assembly"]
	asm["mpn"] = "CRCW080510K0FKEA"
	asm["comment"] = "10k 1%"
	asm["house_parts"] = {"jlcpcb": "C17414"}
	var asm_fields := _fields_for(PromoteDelta.compute(_base_board(), bought), "U3")
	check("1d: the changed mpn is named as its own field",
		asm_fields.has("assembly.mpn"), str(asm_fields.keys()))
	check_eq("1d: …carrying the part number the file had",
		str((asm_fields.get("assembly.mpn", {}) as Dictionary).get("from", "")),
		"RC0805FR-0710KL")
	check("1d: …an ADDED comment is a change too",
		asm_fields.has("assembly.comment"), str(asm_fields.keys()))
	check("1d: …and so is a re-keyed house part",
		asm_fields.has("assembly.house_parts"), str(asm_fields.keys()))
	check("1d: …while the untouched populate/placements stay silent",
		not asm_fields.has("assembly.populate")
		and not asm_fields.has("assembly.placements"), str(asm_fields.keys()))

	# 1e: a placement expansion IS assembly identity — it names the designators
	# a second physical part is soldered under.
	var expanded: Dictionary = _base_board()
	((expanded["components"][0] as Dictionary)["assembly"] as Dictionary)["placements"] = [
		{"ref": "U3A", "offset_mm": {"x": 0.0, "y": 0.0}, "rotation_deg": 0},
		{"ref": "U3B", "offset_mm": {"x": 5.0, "y": 0.0}, "rotation_deg": 180}]
	check("1e: an added placement is reported",
		_fields_for(PromoteDelta.compute(_base_board(), expanded), "U3")
			.has("assembly.placements"))

	# 1f: components and nets appearing and disappearing.
	var edited: Dictionary = _base_board()
	(edited["components"] as Array).remove_at(1)
	(edited["components"] as Array).append({"ref": "C9", "footprint": "",
		"x_mm": 1.0, "y_mm": 1.0, "rotation_deg": 0.0, "layer": "top"})
	(edited["nets"] as Array).remove_at(1)
	(edited["nets"] as Array).append({"name": "VBUS", "pins": []})
	var e: Dictionary = PromoteDelta.compute(_base_board(), edited)
	check_same("1f: the new component is added", e.get("components_added"), ["C9"])
	check_same("1f: the dropped one is removed",
		e.get("components_removed"), ["R4"])
	check_same("1f: the new net is added", e.get("nets_added"), ["VBUS"])
	check_same("1f: THE ORACLE — a net removed from the live board is reported",
		e.get("nets_removed"), ["NC1"])

	# 1g: per-net copper counts, reported only where they moved. NC1 carried no
	# copper, so dropping it moves no count; GND's does.
	var copper: Dictionary = _base_board()
	(copper["traces"] as Array).append({"net": "GND", "layer": "bottom"})
	(copper["vias"] as Array).clear()
	var c: Dictionary = PromoteDelta.compute(_base_board(), copper)
	check_eq("1g: one net's copper moved", (c.get("nets_changed", []) as Array).size(), 1)
	var gnd: Dictionary = (c.get("nets_changed", []) as Array)[0]
	check_eq("1g: …named", str(gnd.get("net", "")), "GND")
	check_same("1g: …its traces counted up", gnd.get("traces"),
		{"from": 1, "to": 2})
	check_same("1g: …and its vias counted down to none", gnd.get("vias"),
		{"from": 1, "to": 0})


# ── Section 2: through the whole promote ────────────────────────────────────

class FakeEditor extends RefCounted:
	var tab_title: String = ""


## A worker that is a JSON CODEC. `pcb.deserialize` parses the bytes it is
## handed as JSON, so the prior file this suite writes IS the prior design,
## exactly and without a YAML parser in the loop; `pcb.serialize` echoes the
## board back. Replies are posed at the live envelope depth
## ({success, result:{ok, result:{…}}}) — one level shallow would pass a test
## the real broker fails.
class CodecIPC extends Node:
	var captured: Array = []
	var _replies: Dictionary = {}

	func bind(panel_node) -> void:
		name = "_MinervaIPC"
		panel_node.add_child(self)
		panel_node.request.connect(_on_request)

	func _on_request(channel: String, payload: Dictionary, reply_id: String) -> void:
		captured.append({"channel": channel, "payload": payload})
		_replies[reply_id] = _answer(channel, payload)

	func await_reply(reply_id: String, _timeout_ms: int = 0) -> Dictionary:
		if not _replies.has(reply_id):
			return {"success": false, "error_code": "timeout",
				"error_message": "no captured request"}
		return (_replies[reply_id] as Dictionary).duplicate(true)

	func _answer(channel: String, payload: Dictionary) -> Dictionary:
		match channel:
			"pcb.promote_check":
				return {"success": true, "result": {"ok": true, "result": {
					"promotable": true, "refusals": [],
					"connectivity": {}, "geometric": {}, "assembly": {}}}}
			"pcb.deserialize":
				var parsed: Variant = JSON.parse_string(str(payload.get("yaml", "")))
				if not (parsed is Dictionary):
					return {"success": true, "result": {"ok": false,
						"error": "unparsable"}}
				return {"success": true, "result": {"ok": true,
					"result": {"board": parsed}}}
			"pcb.serialize":
				return {"success": true, "result": {"ok": true, "result": {
					"yaml": JSON.stringify(payload.get("board", {}))}}}
		return {"success": false, "error_code": "unexpected_channel",
			"error_message": channel}


func _scratch_dir() -> String:
	var abs := ProjectSettings.globalize_path("user://test_promote_delta")
	if DirAccess.dir_exists_absolute(abs):
		for f in DirAccess.get_files_at(abs):
			DirAccess.remove_absolute(abs.path_join(f))
	DirAccess.make_dir_recursive_absolute(abs)
	return abs


## The one-shot half of the status line — _set_status writes
## `_status_lead() + message`, and the lead is a standing board condition every
## line carries. Asserting the whole label would assert the lead too.
func _status_message(panel) -> String:
	var full := str(panel._status_label.text)
	var lead := str(panel._status_lead())
	return full.substr(lead.length()) if full.begins_with(lead) else full


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _run_through_promote() -> void:
	print("\n-- 2: through the whole promote --")
	var panel: Variant = load(PANEL_PATH).new()
	panel._on_panel_loaded({"editor": FakeEditor.new(), "file_path": ""})
	panel.get_data().from_board_dict(_base_board(), {})
	var ipc := CodecIPC.new()
	ipc.bind(panel)
	var dir := _scratch_dir()

	# The LIVE board as the panel itself emits it — the prior file is built by
	# editing a copy of exactly that, so the only difference between file and
	# board is the one this test plants. Deriving the file from a hand-written
	# literal instead would make every model normalisation read as a change.
	var live: Dictionary = panel.get_data().to_board_dict()

	# 2a: THE ORACLE. U3's value on disk is 10k; the live board says 22k.
	var target := dir.path_join("board.yaml")
	var prior: Dictionary = live.duplicate(true)
	for c in (prior["components"] as Array):
		if str((c as Dictionary).get("ref", "")) == "U3":
			(c as Dictionary)["value"] = "10k"
	panel.get_data().get_component("U3").value = "22k"
	_write(target, JSON.stringify(prior))

	var out: Dictionary = await panel.promote(target)
	check_eq("2a: the promote succeeds (%s)" % str(out.get("error", "")),
		bool(out.get("success", false)), true)
	check_eq("2a: the prior file parsed", str(out.get("prior_state", "")), "parsed")
	check("2a: the reply carries a design delta",
		out.get("design_delta", null) is Dictionary, str(out.keys()))
	var delta: Dictionary = out.get("design_delta", {})
	check_eq("2a: …naming exactly one changed component",
		(delta.get("components_changed", []) as Array).size(), 1)
	var entry: Dictionary = (delta.get("components_changed", []) as Array)[0]
	check_eq("2a: …the one this test edited", str(entry.get("ref", "")), "U3")
	var fields: Dictionary = entry.get("fields", {})
	check_same("2a: …in exactly the field it edited", fields.keys(), ["value"])
	check_eq("2a: …with the file's value as `from`",
		str((fields["value"] as Dictionary).get("from", "")), "10k")
	check_eq("2a: …and the board's as `to`",
		str((fields["value"] as Dictionary).get("to", "")), "22k")
	check("2a: …and the delta is ADVISORY — the file was still written",
		FileAccess.file_exists(target)
		and int(out.get("bytes", 0)) == FileAccess.get_file_as_string(target).length())

	# 2b: the status line carries the same answer the reply does. The BUTTON
	# takes no path — it writes
	# the adopted canonical source, which only load_board_from_yaml records, so
	# this rig states it directly rather than staging a whole document load.
	panel._canonical_source_path = target
	panel.get_data().get_component("U3").value = "33k"
	await panel._on_promote_button_pressed()
	check("2b: the status names the changed-component count",
		_status_message(panel).contains("1 component(s) changed"),
		_status_message(panel))
	check("2b: …after saying the file was promoted",
		_status_message(panel).begins_with("PROMOTED →"),
		_status_message(panel))

	# 2c: the file the last promote wrote IS the live board, so promoting again
	# with nothing touched must report nothing. An empty delta is present, not
	# absent: "this changed nothing" is an answer.
	var again: Dictionary = await panel.promote(target)
	check_eq("2c: the re-promote succeeds (%s)" % str(again.get("error", "")),
		bool(again.get("success", false)), true)
	check("2c: an unchanged board reports an empty delta",
		again.get("design_delta", null) is Dictionary
		and PromoteDelta.is_unchanged(again.get("design_delta", {})),
		JSON.stringify(again.get("design_delta", null)))
	await panel._on_promote_button_pressed()
	check("2c: …and the status line claims no change",
		not _status_message(panel).contains("component(s) changed"),
		_status_message(panel))

	# 2d: no prior file, nothing to diff against — the key is ABSENT rather
	# than an empty delta claiming the design of record was unchanged.
	var fresh := dir.path_join("first.yaml")
	var first: Dictionary = await panel.promote(fresh)
	check_eq("2d: the first promote to a path succeeds (%s)"
		% str(first.get("error", "")), bool(first.get("success", false)), true)
	check_eq("2d: …with no prior state", str(first.get("prior_state", "")), "absent")
	check("2d: …and no delta at all", not first.has("design_delta"),
		str(first.keys()))

	# 2e: an unreadable prior file is not a silent empty delta either.
	var broken := dir.path_join("broken.yaml")
	_write(broken, "this is not a board")
	var bad: Dictionary = await panel.promote(broken)
	check_eq("2e: the promote over unreadable bytes still succeeds (%s)"
		% str(bad.get("error", "")), bool(bad.get("success", false)), true)
	check_eq("2e: …saying the prior file did not parse",
		str(bad.get("prior_state", "")), "unreadable")
	check("2e: …and offering no delta", not bad.has("design_delta"),
		str(bad.keys()))
