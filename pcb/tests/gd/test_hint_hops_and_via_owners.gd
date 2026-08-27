extends SceneTree
## ACCEPTANCE — work item 01a04106bd + remoras 01a03b87473c / 01a02c480d50.
##
## Three defects, one station, all of them about a number or an owner that was
## INVENTED instead of resolved:
##
##   1. OWNERSHIP (01a04106bd). minerva_pcb_propose_via took neither the net nor
##      the hint a via serves, so the live HITL's four duck-under ghosts came
##      back with net "", task_id "" and source_hint_ids [] — the agent
##      recovered which hint each belonged to by matching coordinates to hint
##      segments BY EYE. `for_hint` records it; listings label an ownerless
##      ghost rather than leaving it indistinguishable from an owned one.
##   2. VIA SIZE (01a03b87473c). PcbRouteCandidate.make_via's 0.8/0.4 PARAMETER
##      DEFAULTS were what _create_candidate_for_route stamped onto every
##      ingested via, and _via_dimensions' rescue only fires on a ZERO stamp —
##      0.8 is never zero. A ghost rendered and committed at 0.8 on a board
##      whose rules said 0.6, while the direct-commit path honoured 0.6.
##   3. INVENTED WIDTH (01a02c480d50). Both panel paths that turn a route reply
##      into copper fell back to a literal 0.25mm when the reply carried no
##      width — silently, on the one path that ends in fabricated copper.
##
## Plus the panel half of layer-hop waypoints: a waypoint may carry `layer`,
## and a bend edit must not dissolve it. (The ROUTING half of that feature is
## worker-side and is proven in worker/tests/test_route_hint_layer_hops.py.)
##
## RED/GREEN: every section here FAILS against the pre-station code.
##   1c/1d — source_hint_ids/[owner] did not exist (propose_via had no for_hint).
##   2b/2c — the ingested via was 0.8/0.4 regardless of design_rules.
##   3b    — the widthless route produced 0.25mm copper instead of refusing.
##   4b    — the widthless propose landed a 0.25mm candidate.
##   5b    — with_bend_points rewrote every bend as [x, y], erasing the layer.
##   6b    — validate() ignored waypoint entry shape entirely.
##
## Harness: test_dcr_proposal_ghost.gd's driver + RouterShim idiom. The router
## worker is Python and does not run under the gd scaffold; everything under
## test here is panel-side, so the shim substitutes ONLY the worker's answer.
##
## Run: godot --headless --path src --script \
##   res://../../minerva-plugins/pcb/tests/gd/test_hint_hops_and_via_owners.gd

const PanelTools := preload("res://../../minerva-plugins/pcb/ui/panel_tools.gd")
const PcbHintWaypoint := preload("res://../../minerva-plugins/pcb/ui/model/pcb_hint_waypoint.gd")
const PcbViaDimensions := preload("res://../../minerva-plugins/pcb/ui/model/pcb_via_dimensions.gd")
const RouteHintKind := preload("res://../../minerva-plugins/pcb/ui/kinds/pcb_route_hint_kind.gd")
const PCB_PANEL_SCRIPT_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"

## The board's OWN via rule — deliberately neither 0.8 nor 0.4, so a via that
## still carries the old literals is visibly wrong rather than coincidentally
## right.
const BOARD_VIA_DIAMETER_MM := 0.6
const BOARD_VIA_DRILL_MM := 0.3

var _pass := 0
var _fail := 0


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
		absf(actual - expected) < 1e-6)


class FakeEditor extends RefCounted:
	var tab_title: String = ""


## Worker substitute — see test_dcr_proposal_ghost.gd's RouterShim.
class RouterShim extends RefCounted:
	var real
	var reply: Dictionary = {}

	func _init(real_host, router_reply: Dictionary) -> void:
		real = real_host
		reply = router_reply

	func run_router(selection: Dictionary, _extra: Dictionary = {}) -> Dictionary:
		var answer: Dictionary = reply.duplicate(true)
		var ids: Array = []
		if str(selection.get("mode", "")) == "ids" and selection.get("ids", []) is Array:
			ids = (selection.get("ids", []) as Array).duplicate()
		for r in (answer.get("routes", []) as Array):
			if r is Dictionary:
				(r as Dictionary)["hint_ids"] = ids
		return {"ok": true, "result": answer}

	func get_board_data():
		return real.get_board_data()

	func get_panel():
		return real.get_panel()

	func get_all_annotations() -> Array:
		return real.get_all_annotations()

	func get_annotations() -> Array:
		return real.get_all_annotations()

	func get_by_id(id: String) -> Dictionary:
		return real.get_by_id(id)

	func build_route_hint_envelope(x: float, y: float, text: String = "",
			layer: String = "F.Cu", hint_type: String = "waypoint",
			waypoints: Array = [], author_kind: String = "human",
			detail_level: String = "", width_mm: Variant = null,
			source_pins: Array = [], dest_pins: Array = []) -> Dictionary:
		return real.build_route_hint_envelope(x, y, text, layer, hint_type,
			waypoints, author_kind, detail_level, width_mm, source_pins, dest_pins)

	func add_annotation_v2(envelope: Dictionary) -> String:
		return str(real.add_annotation_v2(envelope))

	func remove_annotation(id: String) -> bool:
		return bool(real.remove_annotation(id))

	func update_annotation(id: String, new_annotation: Dictionary) -> bool:
		return bool(real.update_annotation(id, new_annotation))

	func reconcile_strip_superseded_marker(hint_id: String) -> Dictionary:
		return real.reconcile_strip_superseded_marker(hint_id)


func _two_pin_board() -> Dictionary:
	return {"version": 1, "name": "hops", "width_mm": 60.0, "height_mm": 40.0,
		"layers": ["top", "bottom"],
		"design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.25,
			"via_diameter_mm": BOARD_VIA_DIAMETER_MM,
			"via_drill_mm": BOARD_VIA_DRILL_MM},
		"components": [
			{"ref": "U1", "footprint": "HEADER", "x_mm": 15.0, "y_mm": 20.0,
				"rotation_deg": 0.0, "layer": "top", "pins": [
					{"number": "1", "x_mm": 0.0, "y_mm": 0.0,
						"pad_width_mm": 1.7, "pad_height_mm": 1.7},
					{"number": "2", "x_mm": 0.0, "y_mm": 2.54,
						"pad_width_mm": 1.7, "pad_height_mm": 1.7}]},
			{"ref": "J1", "footprint": "HEADER", "x_mm": 45.0, "y_mm": 20.0,
				"rotation_deg": 0.0, "layer": "top", "pins": [
					{"number": "1", "x_mm": 0.0, "y_mm": 0.0,
						"pad_width_mm": 1.7, "pad_height_mm": 1.7},
					{"number": "2", "x_mm": 0.0, "y_mm": 2.54,
						"pad_width_mm": 1.7, "pad_height_mm": 1.7}]},
		],
		"nets": [{"name": "SIG", "pins": ["U1.1", "J1.1"]},
			{"name": "GND", "pins": ["U1.2", "J1.2"]}],
		"traces": [], "vias": []}


## A worker answer for SIG that HOPS: two runs and one via between them.
## `stamped_width` <= 0 emits the shape an older worker sent — no per-segment
## width_mm and no effective_routing_rules — which is exactly the input the
## 0.25mm literal used to answer.
func _hop_reply(stamped_width: float) -> Dictionary:
	var a: Dictionary = {"start": [15.0, 20.0], "end": [30.0, 20.0], "layer": "F.Cu"}
	var b: Dictionary = {"start": [30.0, 20.0], "end": [45.0, 20.0], "layer": "B.Cu"}
	if stamped_width > 0.0:
		a["width_mm"] = stamped_width
		b["width_mm"] = stamped_width
	var route: Dictionary = {"net": "SIG", "segments": [a, b],
		"vias": [[30.0, 20.0]], "hint_ids": []}
	if stamped_width > 0.0:
		route["effective_routing_rules"] = {
			"trace_width_mm": {"value": stamped_width, "source": "board_rules"}}
	return {"routes": [route], "via_count": 1}


func _panel_context() -> Dictionary:
	var driver = preload("res://test/helpers/plugin_panel_driver.gd").new()
	var panel = driver.load_panel(PCB_PANEL_SCRIPT_PATH)
	var host = panel.get_annotation_host()
	host.set_panel(panel)
	panel.get_data().from_board_dict(_two_pin_board())
	return {"driver": driver, "panel": panel, "host": host,
		"ws": panel.get_routing_workspace(), "data": panel.get_data()}


func _free_ctx(ctx: Dictionary) -> void:
	ctx["driver"].free_panel(ctx["panel"])


func _args(extra: Dictionary = {}) -> Dictionary:
	var a: Dictionary = {"editor_name": "PCB"}
	a.merge(extra, true)
	return a


func _row_for(reply: Dictionary, cid: String) -> Dictionary:
	for row in (reply.get("candidates", []) as Array):
		if row is Dictionary and str((row as Dictionary).get("candidate_id", "")) == cid:
			return row
	return {}


func _init() -> void:
	print("=== 01a04106bd + 01a03b87473c + 01a02c480d50 acceptance ===\n")
	await process_frame
	await _s1_via_ownership()
	await _s2_via_size_from_design_rules()
	await _s3_materialize_fails_closed_on_width()
	await _s4_propose_fails_closed_on_width()
	_s5_bend_edit_preserves_layer()
	_s6_waypoint_validation()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


# ══ 1. a proposed via names the hint it serves ═══════════════════════════════

func _s1_via_ownership() -> void:
	print("-- 1. propose_via for_hint: owner + inherited net; no owner is LABELLED --")
	var ctx: Dictionary = await _panel_context()
	var shim := RouterShim.new(ctx["host"], _hop_reply(0.3))

	var minted: Dictionary = PanelTools._add_route_intent(shim, _args({
		"source_pin": "U1.1", "dest_pin": "J1.1"}))
	check("1a: a route intent exists to own the via", bool(minted.get("success", false)))
	var hid := str(minted.get("hint_id", ""))

	var owned: Dictionary = PanelTools._propose_via(shim, _args({
		"x_mm": 30.0, "y_mm": 20.0, "for_hint": hid}))
	check("1b: an owned via proposal succeeds", bool(owned.get("success", false)))
	check_eq("1c: the reply names its owner", str(owned.get("for_hint", "")), hid)
	check_eq("1d: it INHERITED the hint's net without being told",
		str(owned.get("net_name", "")), "SIG")

	var listed: Dictionary = PanelTools._workspace_list(shim, _args())
	var owned_row: Dictionary = _row_for(listed, str(owned.get("candidate_id", "")))
	check("1e: the owned ghost is listed", not owned_row.is_empty())
	check_eq("1f: it lists UNDER the hint", owned_row.get("source_hint_ids", []), [hid])
	check_eq("1g: and says so in one word", str(owned_row.get("owner", "")), "hint %s" % hid)
	check("1h: an owned ghost is NOT flagged unowned", not owned_row.has("unowned"))

	# The old four-ghost form must keep working — an unassigned via is a real
	# workflow (via-only boards drilled first, copper lased later).
	var orphan: Dictionary = PanelTools._propose_via(shim, _args({
		"x_mm": 22.0, "y_mm": 27.0}))
	check("1i: an ownerless via is STILL ALLOWED", bool(orphan.get("success", false)))
	check_eq("1j: its reply says owner none", str(orphan.get("owner", "")), "none")
	var listed2: Dictionary = PanelTools._workspace_list(shim, _args())
	var orphan_row: Dictionary = _row_for(listed2, str(orphan.get("candidate_id", "")))
	check_eq("1k: and the LISTING labels it unowned", str(orphan_row.get("owner", "")), "none")
	check("1l: with an explicit unowned flag an agent can filter on",
		bool(orphan_row.get("unowned", false)))
	check("1m: and a note saying how to fix it",
		str(orphan_row.get("unowned_note", "")).contains("for_hint"))

	# INV: recording an owner must not put the via in the hint's ANSWER slot —
	# a via ghost is not a route candidate, and two live answers to one question
	# is exactly the duplicate-task shape ingest works hard to avoid.
	check_eq("1n: the owned ghost claims no task", str(owned_row.get("task_id", "")), "")
	_free_ctx(ctx)


# ══ 2. every proposed via is sized by the BOARD ══════════════════════════════

func _s2_via_size_from_design_rules() -> void:
	print("\n-- 2. via diameter/drill come from design_rules at PROPOSAL time --")
	var ctx: Dictionary = await _panel_context()
	var shim := RouterShim.new(ctx["host"], _hop_reply(0.3))

	# 2a: the rule itself, stated once, in the one place that owns it.
	var resolved: Dictionary = PcbViaDimensions.resolve(
		{"via_diameter_mm": BOARD_VIA_DIAMETER_MM, "via_drill_mm": BOARD_VIA_DRILL_MM})
	check_near("2a: the shared rule reads the board's diameter",
		float(resolved["diameter"]), BOARD_VIA_DIAMETER_MM)
	check_near("2a2: and the board's drill", float(resolved["drill"]), BOARD_VIA_DRILL_MM)
	var overridden: Dictionary = PcbViaDimensions.resolve(
		{"via_diameter_mm": BOARD_VIA_DIAMETER_MM}, 1.2, 0.0)
	check_near("2a3: an explicit size still outranks the board", float(overridden["diameter"]), 1.2)
	check_near("2a4: 0.0 means 'not specified', never zero-sized",
		float(overridden["drill"]), PcbViaDimensions.DEFAULT_DRILL_MM)

	# 2b: THE REMORA. A router candidate's layer-change via — the via nobody
	# passes a size for — used to be born at make_via's 0.8/0.4 defaults.
	var minted: Dictionary = PanelTools._add_route_intent(shim, _args({
		"source_pin": "U1.1", "dest_pin": "J1.1"}))
	var proposed: Dictionary = await PanelTools._workspace_propose(shim, _args({
		"hint_ids": [str(minted.get("hint_id", ""))]}))
	check("2b0: the hop route landed a candidate", int(proposed.get("proposed", 0)) == 1)
	var ws = ctx["ws"]
	var cand = ws.get_candidate(str((proposed["candidates"][0] as Dictionary)["candidate_id"]))
	check("2b1: the candidate carries the hop via", cand != null and cand.vias.size() == 1)
	if cand != null and cand.vias.size() == 1:
		var v: Dictionary = cand.vias[0]
		check_near("2b: an INGESTED via takes the board's diameter, not 0.8",
			float(v.get("diameter", 0.0)), BOARD_VIA_DIAMETER_MM)
		check_near("2c: and the board's drill, not 0.4",
			float(v.get("drill", 0.0)), BOARD_VIA_DRILL_MM)

	# 2d: the standalone proposal path answers identically — the two must not
	# disagree about one hole, which is what the remora is about.
	var ghost: Dictionary = PanelTools._propose_via(shim, _args({"x_mm": 22.0, "y_mm": 27.0}))
	check_near("2d: a propose_via ghost takes the board's diameter too",
		float(ghost.get("size_mm", 0.0)), BOARD_VIA_DIAMETER_MM)
	check_near("2e: and its drill", float(ghost.get("drill_mm", 0.0)), BOARD_VIA_DRILL_MM)
	_free_ctx(ctx)


# ══ 3. the copper-creating path refuses rather than inventing a width ════════

func _s3_materialize_fails_closed_on_width() -> void:
	print("\n-- 3. apply/commit with an unstamped reply creates NO copper --")
	var ctx: Dictionary = await _panel_context()
	var host = ctx["host"]
	var data = ctx["data"]

	# A widthless hint, so no hint width can rescue the reply either. This is
	# the ONLY input that ever reached the 0.25mm literal.
	var hint_id := str(host.add_route_hint_at(15.0, 20.0, "", "F.Cu", "single_trace", []))
	var hints: Array = [host.get_by_id(hint_id)]
	# data.traces is a Dictionary (trace_id -> pcb_trace.gd), not an Array.
	var traces_before: int = data.traces.size()

	var out: Dictionary = PanelTools._materialize_routes(host, data, _hop_reply(0.0), hints)
	check_eq("3a: nothing was applied", int(out.get("traces_added", 0)), 0)
	check_eq("3b: AND NO COPPER LANDED (old code drew it at 0.25mm)",
		data.traces.size(), traces_before)
	var failed: Array = out.get("failed", [])
	check("3c: the refusal is reported, not silent", failed.size() == 1)
	if failed.size() == 1:
		var reason := str((failed[0] as Dictionary).get("reason", ""))
		check("3d: and NAMES what it could not resolve", reason.contains("width"))
		check_eq("3e: against the right net", str((failed[0] as Dictionary).get("net", "")), "SIG")
	check_eq("3f: a refused route consumes no hint", out.get("consumed_hint_ids", []), [])
	check_eq("3g: and creates no orphan vias for a route that laid no copper",
		out.get("via_ids", []), [])

	# The same reply WITH a stamp still lands copper — the refusal is about the
	# missing width, not about hop routes.
	var ok: Dictionary = PanelTools._materialize_routes(host, data, _hop_reply(0.35), hints)
	check_eq("3h: a stamped reply still applies (one trace per layer run)",
		int(ok.get("traces_added", 0)), 2)
	var landed_ids: Array = ok.get("trace_ids", [])
	var widths_ok := landed_ids.size() == 2
	for tid in landed_ids:
		var t = data.traces.get(str(tid))
		if t == null or absf(float(t.width) - 0.35) > 1e-6:
			widths_ok = false
	check("3i: at the width the router reported, not a literal", widths_ok)
	_free_ctx(ctx)


# ══ 4. an unresolvable width is named at propose and REFUSED at commit ═══════
#
# The refusal belongs to COPPER, not to the ghost: a candidate is a question,
# not a board edit. So the propose lands it and labels it, and commit — the
# copper-creating path — is what fails closed.

func _s4_propose_fails_closed_on_width() -> void:
	print("\n-- 4. unresolvable width: ghost labelled, commit refuses, no copper --")
	var ctx: Dictionary = await _panel_context()
	var shim := RouterShim.new(ctx["host"], _hop_reply(0.0))
	var host = ctx["host"]
	var data = ctx["data"]

	var hint_id := str(host.add_route_hint_at(15.0, 20.0, "", "F.Cu", "single_trace", []))
	var out: Dictionary = await PanelTools._workspace_propose(shim, _args({"hint_ids": [hint_id]}))
	check("4a: the call succeeds — an unresolved width is feedback, not an error",
		bool(out.get("success", false)))
	check_eq("4b: the ghost still lands (a candidate is a question)",
		int(out.get("proposed", 0)), 1)
	var cid := str((out["candidates"][0] as Dictionary)["candidate_id"])
	var cand = ctx["ws"].get_candidate(cid)
	check("4c: at width 0.0 — NOT the invented 0.25mm",
		cand != null and absf(float((cand.segments[0] as Dictionary).get("width", -1.0))) < 1e-9)
	check_eq("4d: and it SAYS the width is unresolved, not 'default'",
		str(cand.width_source), "unresolved")
	var missing: Array = out.get("unresolved_widths", [])
	check("4e: the propose reply names it", missing.size() == 1)
	if missing.size() == 1:
		check_eq("4e2: by net", str((missing[0] as Dictionary).get("net", "")), "SIG")
		check("4e3: with a reason mentioning the width",
			str((missing[0] as Dictionary).get("reason", "")).contains("width"))

	# THE FAIL-CLOSED ORACLE: the copper-creating path refuses.
	var traces_before: int = data.traces.size()
	var committed: Dictionary = ctx["ws"].commit(cid, data)
	check("4i: COMMIT REFUSES (old code would have fabricated 0.25mm copper)",
		not bool(committed.get("ok", false)))
	check_eq("4j: by name", str(committed.get("error", "")), "unmodelable_segment")
	check_eq("4k: and no copper landed", data.traces.size(), traces_before)

	# A HINT-authored width is a real source and must still rescue the same
	# unstamped reply — fail-closed, not fail-often.
	var ctx2: Dictionary = await _panel_context()
	var shim2 := RouterShim.new(ctx2["host"], _hop_reply(0.0))
	var minted: Dictionary = PanelTools._add_route_intent(shim2, _args({
		"source_pin": "U1.1", "dest_pin": "J1.1", "width_mm": 0.5}))
	var out2: Dictionary = await PanelTools._workspace_propose(shim2, _args({
		"hint_ids": [str(minted.get("hint_id", ""))]}))
	check_eq("4f: a hint-authored width still lands the ghost",
		int(out2.get("proposed", 0)), 1)
	check_eq("4g: with no refusal recorded", (out2.get("unresolved_widths", []) as Array).size(), 0)
	var cand2 = ctx2["ws"].get_candidate(str((out2["candidates"][0] as Dictionary)["candidate_id"]))
	check("4h: at the hint's 0.5mm, not 0.25",
		cand2 != null and absf(float((cand2.segments[0] as Dictionary).get("width", 0.0)) - 0.5) < 1e-6)
	_free_ctx(ctx2)
	_free_ctx(ctx)


# ══ 5. a bend edit must not dissolve a layer hop ═════════════════════════════

func _s5_bend_edit_preserves_layer() -> void:
	print("\n-- 5. moving a bend keeps its layer (and so keeps its via) --")
	var kind = RouteHintKind.new()
	var ann: Dictionary = {
		"kind": "pcb_route_hint",
		"kind_payload": {
			"hint_type": "single_trace", "layer": "F.Cu",
			"dest_point": [45.0, 20.0],
			"waypoints": [
				[20.0, 20.0],
				{"x": 30.0, "y": 20.0, "layer": "bottom"},
				[38.0, 20.0],
			],
		},
	}
	var bends: Array = kind.bend_points(ann)
	check_eq("5a: all three corners are bends regardless of shape", bends.size(), 3)
	check("5a2: including the dict-shaped one, at its real position",
		(bends[1] as Vector2) == Vector2(30.0, 20.0))

	var moved: Array = bends.duplicate()
	moved[1] = Vector2(31.5, 21.0)
	var edited: Dictionary = kind.with_bend_points(ann, moved)
	var wps: Array = (edited["kind_payload"] as Dictionary)["waypoints"]
	check_eq("5b: THE HOP SURVIVES THE DRAG (old code rewrote it as [x, y])",
		PcbHintWaypoint.layer_of(wps[1]), "bottom")
	check("5b2: and moved to where it was dragged",
		PcbHintWaypoint.position_of(wps[1]) == [31.5, 21.0])
	check("5c: a plain corner stays plain — nothing gains a layer",
		PcbHintWaypoint.layer_of(wps[0]).is_empty()
		and PcbHintWaypoint.layer_of(wps[2]).is_empty())
	check_eq("5d: exactly one hop, so exactly one via",
		PcbHintWaypoint.layer_change_indices(wps).size(), 1)


# ══ 6. waypoint shape/layer validation ═══════════════════════════════════════

func _s6_waypoint_validation() -> void:
	print("\n-- 6. a waypoint layer that is not copper is refused at validate --")
	var kind = RouteHintKind.new()

	var good: Dictionary = {
		"kind": "pcb_route_hint",
		"anchor": {"plugin": "pcb", "type": "board.point", "id": {"x": 15.0, "y": 20.0}},
		"kind_payload": {"hint_type": "single_trace", "layer": "F.Cu",
			"waypoints": [[20.0, 20.0], {"x": 30.0, "y": 20.0, "layer": "B.Cu"}]},
	}
	check_eq("6a: a KiCad copper name on a waypoint validates clean",
		kind.validate(good).size(), 0)

	var bad: Dictionary = good.duplicate(true)
	((bad["kind_payload"] as Dictionary)["waypoints"] as Array)[1] = \
		{"x": 30.0, "y": 20.0, "layer": "F.SilkS"}
	var errs: Array = kind.validate(bad)
	check("6b: a NON-COPPER waypoint layer is an error (old code ignored it)",
		errs.size() == 1)
	if errs.size() == 1:
		check_eq("6c: reported against the offending index",
			str((errs[0] as Dictionary).get("field", "")), "kind_payload.waypoints[1]")

	# Declared-stack membership is deliberately NOT this layer's job — validate
	# has an annotation, not a board. Prove the rule exists where the board is.
	check("6d: the shared rule refuses an undeclared layer when given the stack",
		not PcbHintWaypoint.error_for(
			{"x": 1.0, "y": 1.0, "layer": "in5"}, ["top", "bottom"]).is_empty())
	check("6e: and accepts it when the board declares it",
		PcbHintWaypoint.error_for(
			{"x": 1.0, "y": 1.0, "layer": "in5"}, ["top", "in5", "bottom"]).is_empty())
