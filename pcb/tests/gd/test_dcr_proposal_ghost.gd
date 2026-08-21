extends SceneTree
## ACCEPTANCE — DCR 01a022ab356c: "proposal" means ghost trace only (B+C+D).
##
## Scope ratified by the owner after independent review (comment 29 premise
## corrections + rubric scoring 95/105):
##   B — ONE-CALL SPAN-PROPOSE: workspace_propose accepts
##       spans:[{source_pin, dest_pin, width_mm?, note?, corridor?}], mints the
##       route intent INTERNALLY per span (same validation as add_route_intent
##       — atomic across BOTH stores: any invalid span refuses before anything
##       mints, annotation OR eager task), then routes the minted hints in the
##       same call. spans and hint_ids together are a UNION — one worker run
##       routes both. Reply grows minted_hint_ids. The intent annotation still
##       exists afterwards — the durable, citeable record; B is ergonomics
##       (two calls → one), not ontology.
##   C — ORPHAN REROUTE FALLBACK: workspace_reroute_route on a candidate whose
##       source hints are GONE (or that never had any — worker attributed [])
##       no longer refuses source_hints_missing / no_source_hints — it
##       degrades to a hint-less run scoped by the candidate's own task_id/
##       net/endpoint pin refs, lands the new generation on the SAME task
##       (superseding, never duplicating — the ingest task-key override; the
##       census stays one live candidate, one task per question), keeps the
##       endpoints on the fallback generation (so a SECOND orphan reroute
##       still scopes), and says so (hintless_fallback: true). A hint-alive
##       reroute stays byte-identical and does NOT carry the key.
##   D — VOCABULARY: the sidebar group header over the route-hint author tools
##       is "Intents", never "Proposals" (a proposal IS a ghost candidate; the
##       status line already counts candidates); the propose guidance note
##       teaches spans.
##
## RED/GREEN contract: Section 0 is the unchanged-behavior baseline (green
## before AND after). Sections B, C, D pin the new contract and MUST fail
## before the DCR lands — that proven red run is the acceptance baseline
## (fewer checks execute on red: conditionals gate on landed state).
##
## Harness: test_workspace_tools.gd's RouterShim idiom — the router worker is
## Python and does not run under the gd scaffold; everything under test here
## is panel-side, so the shim substitutes ONLY the worker's answer. The shim
## mirrors the worker's per-route attribution stamp dynamically (cold review
## blocker 2): an ids-mode selection is echoed into routes[0].hint_ids, so
## hints minted INSIDE the call under test still attribute — exactly as the
## real worker's _hint_ids_by_net does.
##
## Run: godot --headless --path src --script \
##   res://../../minerva-plugins/pcb/tests/gd/test_dcr_proposal_ghost.gd

const PanelTools := preload("res://../../minerva-plugins/pcb/ui/panel_tools.gd")
const PCB_PANEL_SCRIPT_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"

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


class FakeEditor extends RefCounted:
	var tab_title: String = ""


## Same substitution as test_workspace_tools.gd's RouterShim, trimmed to the
## forwards these scenarios reach, plus the dynamic attribution echo above.
class RouterShim extends RefCounted:
	var real
	var reply: Dictionary = {}
	var calls: Array = []

	func _init(real_host, router_reply: Dictionary) -> void:
		real = real_host
		reply = router_reply

	func run_router(selection: Dictionary, extra: Dictionary = {}) -> Dictionary:
		calls.append({"selection": selection, "extra": extra})
		var answer: Dictionary = reply.duplicate(true)
		# Worker-fidelity attribution: per-route hint_ids mirrors the selected
		# hints (empty for a hint-less run) — the real worker stamps exactly
		# this, and ingest attribution/task keying/width provenance all read it.
		var ids: Array = []
		if str(selection.get("mode", "")) == "ids" and selection.get("ids", []) is Array:
			ids = (selection.get("ids", []) as Array).duplicate()
		var routes: Array = answer.get("routes", []) if answer.get("routes", []) is Array else []
		for r in routes:
			if r is Dictionary:
				(r as Dictionary)["hint_ids"] = ids
		return {"ok": true, "result": answer}

	func get_board_data():
		return real.get_board_data()

	func get_panel():
		return real.get_panel()

	func get_all_annotations() -> Array:
		return real.get_all_annotations()

	func get_by_id(id: String) -> Dictionary:
		return real.get_by_id(id)

	## Full host arity (PcbAnnotationHost.gd:1176) — _add_route_intent passes
	## width + pin refs; a narrower shim signature hard-errors the call.
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


## Two-pin single-net board the span validation can resolve pins against.
func _two_pin_board() -> Dictionary:
	return {"version": 1, "name": "dcr-acc", "width_mm": 60.0, "height_mm": 40.0,
		"layers": ["top", "bottom"],
		"design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.25},
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


## Canned worker answer for net SIG; hint_ids is stamped dynamically by the
## shim from the selection (see RouterShim.run_router).
func _sig_reply() -> Dictionary:
	return {"routes": [{"net": "SIG",
		"segments": [{"start": [15.0, 20.0], "end": [45.0, 20.0], "layer": "F.Cu"}],
		"vias": [], "hint_ids": []}], "via_count": 0}


func _panel_context(mounted: bool = false) -> Dictionary:
	var driver = preload("res://test/helpers/plugin_panel_driver.gd").new()
	var panel = driver.load_panel(PCB_PANEL_SCRIPT_PATH)
	if mounted:
		get_root().add_child(panel)
		panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		panel.size = Vector2(900, 700)
		panel._on_panel_loaded({"editor": FakeEditor.new(), "file_path": ""})
		for _i in range(4):
			await process_frame
	var host = panel.get_annotation_host()
	host.set_panel(panel)
	panel.get_data().from_board_dict(_two_pin_board())
	var shim := RouterShim.new(host, _sig_reply())
	return {"driver": driver, "panel": panel, "host": host, "shim": shim,
		"ws": panel.get_routing_workspace(), "data": panel.get_data()}


func _free_ctx(ctx: Dictionary) -> void:
	ctx["driver"].free_panel(ctx["panel"])


func _args(extra: Dictionary = {}) -> Dictionary:
	var a: Dictionary = {"editor_name": "PCB"}
	a.merge(extra, true)
	return a


func _route_hint_count(host) -> int:
	var n := 0
	for ann in host.get_all_annotations():
		if ann is Dictionary and str((ann as Dictionary).get("kind", "")) == "pcb_route_hint":
			n += 1
	return n


func _sig_task_count(ws) -> int:
	var n := 0
	for tid in ws.tasks:
		if str(ws.tasks[tid].net) == "SIG":
			n += 1
	return n


func _first_cid(reply: Dictionary) -> String:
	var cands: Array = reply.get("candidates", []) if reply.get("candidates", []) is Array else []
	if cands.is_empty() or not (cands[0] is Dictionary):
		return ""
	return str((cands[0] as Dictionary).get("candidate_id", ""))


func _ids_as_set(v: Variant) -> Array:
	var out: Array = []
	if v is Array:
		for x in v:
			out.append(str(x))
	out.sort()
	return out


func _init() -> void:
	print("=== DCR 01a022ab356c acceptance: proposal == ghost (B+C+D) ===\n")
	await process_frame
	await _run_baseline()
	await _run_b_span_propose()
	await _run_b_union()
	await _run_b_atomic_refusal()
	await _run_b_shape_refusals()
	await _run_c_orphan_reroute()
	await _run_d_vocabulary()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


# ══ 0. baseline — unchanged behavior, green before AND after ═════════════════

func _run_baseline() -> void:
	print("-- 0. baseline: intent → propose still lands a ghost, no shadow annotation --")
	var ctx: Dictionary = await _panel_context()
	var shim: RouterShim = ctx["shim"]
	var minted: Dictionary = PanelTools._add_route_intent(shim, _args({
		"source_pin": "U1.1", "dest_pin": "J1.1", "width_mm": 0.5}))
	check("0a: intent minted", bool(minted.get("success", false)))
	var hid := str(minted.get("hint_id", ""))
	var anns_before := _route_hint_count(ctx["host"])
	var out: Dictionary = await PanelTools._workspace_propose(shim, _args({"hint_ids": [hid]}))
	check("0b: propose succeeded", bool(out.get("success", false)))
	check_eq("0c: one ghost landed", int(out.get("proposed", 0)), 1)
	check_eq("0d: propose wrote NO annotation",
		_route_hint_count(ctx["host"]), anns_before)
	_free_ctx(ctx)


# ══ B. one-call span-propose ═════════════════════════════════════════════════

func _run_b_span_propose() -> void:
	print("\n-- B. spans:[...] mints the intent internally and routes it, one call --")
	var ctx: Dictionary = await _panel_context()
	var shim: RouterShim = ctx["shim"]
	var host = ctx["host"]
	var anns_before := _route_hint_count(host)

	var out: Dictionary = await PanelTools._workspace_propose(shim, _args({
		"spans": [{"source_pin": "U1.1", "dest_pin": "J1.1", "width_mm": 0.9}]}))
	check("B1: span-propose succeeded", bool(out.get("success", false)))
	check_eq("B2: one ghost landed from the span", int(out.get("proposed", 0)), 1)
	var minted_ids: Array = out.get("minted_hint_ids", []) if out.get("minted_hint_ids", []) is Array else []
	check_eq("B3: reply names exactly one minted intent", minted_ids.size(), 1)
	check_eq("B4: the intent annotation EXISTS after the call (durable, citeable record)",
		_route_hint_count(host), anns_before + 1)
	if minted_ids.size() == 1:
		var ann: Dictionary = shim.get_by_id(str(minted_ids[0]))
		var kp: Dictionary = ann.get("kind_payload", {}) if ann.get("kind_payload", {}) is Dictionary else {}
		check("B5: minted intent carries the span's width (durable width channel)",
			is_equal_approx(float(kp.get("width_mm", 0.0)), 0.9))
		check("B6: minted intent carries a citeable ref",
			str(ann.get("ref", "")) != "")
	check("B7: the router was asked to route exactly the minted intent",
		shim.calls.size() == 1
		and str((shim.calls[0]["selection"] as Dictionary).get("mode", "")) == "ids"
		and _ids_as_set((shim.calls[0]["selection"] as Dictionary).get("ids", [])) == _ids_as_set(minted_ids))
	var cands: Array = out.get("candidates", []) if out.get("candidates", []) is Array else []
	check("B8: candidate width rides the hint channel (0.9, width_source hint)",
		cands.size() == 1
		and is_equal_approx(float((cands[0] as Dictionary).get("width_mm", 0.0)), 0.9)
		and str((cands[0] as Dictionary).get("width_source", "")) == "hint")
	_free_ctx(ctx)


func _run_b_union() -> void:
	print("\n-- B. spans + hint_ids together are a UNION: one run routes both --")
	var ctx: Dictionary = await _panel_context()
	var shim: RouterShim = ctx["shim"]
	var pre: Dictionary = PanelTools._add_route_intent(shim, _args({
		"source_pin": "U1.1", "dest_pin": "J1.1", "width_mm": 0.5}))
	check("B12: fixture open intent minted", bool(pre.get("success", false)))
	var hid := str(pre.get("hint_id", ""))

	# NOTE (re-review nit B): the shim stamps the FULL selection onto the one
	# SIG route — a cross-net stamp the real per-net worker never produces, so
	# the ingested task key here is a fixture fiction. Nothing below reads
	# post-ingest state on purpose; B14 pins the REQUEST side only. Do not
	# author census assertions against this fixture.
	var out: Dictionary = await PanelTools._workspace_propose(shim, _args({
		"hint_ids": [hid],
		"spans": [{"source_pin": "U1.2", "dest_pin": "J1.2", "width_mm": 0.4}]}))
	check("B13: union propose succeeded", bool(out.get("success", false)))
	var minted_ids: Array = out.get("minted_hint_ids", []) if out.get("minted_hint_ids", []) is Array else []
	var expected: Array = _ids_as_set(minted_ids + [hid])
	check("B14: ONE router run selected the union (existing hint + minted span intent)",
		shim.calls.size() == 1 and minted_ids.size() == 1
		and _ids_as_set((shim.calls[0]["selection"] as Dictionary).get("ids", [])) == expected)
	_free_ctx(ctx)


func _run_b_atomic_refusal() -> void:
	print("\n-- B. invalid span refuses ATOMICALLY: neither store mutates, no run --")
	var ctx: Dictionary = await _panel_context()
	var shim: RouterShim = ctx["shim"]
	var ws = ctx["ws"]
	var anns_before := _route_hint_count(ctx["host"])
	var tasks_before: int = ws.tasks.size()
	# Second span is cross-net (U1.1 on SIG, J1.2 on GND) — the whole call must
	# refuse BEFORE the first (valid) span mints anything.
	var out: Dictionary = await PanelTools._workspace_propose(shim, _args({
		"spans": [
			{"source_pin": "U1.1", "dest_pin": "J1.1", "width_mm": 0.9},
			{"source_pin": "U1.1", "dest_pin": "J1.2"},
		]}))
	check("B9: cross-net span refuses the call", not bool(out.get("success", true)))
	check_eq("B10: no intent annotation was minted by the refused call",
		_route_hint_count(ctx["host"]), anns_before)
	check_eq("B16: no eager TASK was minted either (both stores atomic — a mint-then-rollback fake fails here)",
		ws.tasks.size(), tasks_before)
	check_eq("B11: the router never ran", shim.calls.size(), 0)
	_free_ctx(ctx)


func _run_b_shape_refusals() -> void:
	print("\n-- B. span arg-shape refusals: empty-by-presence, unresolvable pin --")
	var ctx: Dictionary = await _panel_context()
	var shim: RouterShim = ctx["shim"]
	# spans PRESENT but empty is refused by name (the corridor precedent:
	# an explicitly empty array is never silently 'no spans').
	var out_empty: Dictionary = await PanelTools._workspace_propose(shim, _args({"spans": []}))
	check("B17: spans present-but-empty refuses by name",
		not bool(out_empty.get("success", true)))
	var anns_before := _route_hint_count(ctx["host"])
	var out_bad: Dictionary = await PanelTools._workspace_propose(shim, _args({
		"spans": [{"source_pin": "U9.9", "dest_pin": "J1.1"}]}))
	check("B18: unresolvable pin refuses the call", not bool(out_bad.get("success", true)))
	check_eq("B19: nothing minted by the refused call",
		_route_hint_count(ctx["host"]), anns_before)
	_free_ctx(ctx)


# ══ C. orphan reroute — candidate-carried terminal fallback ══════════════════

func _run_c_orphan_reroute() -> void:
	print("\n-- C. reroute survives hint loss: same task, superseded, honest, re-entrant --")
	var ctx: Dictionary = await _panel_context()
	var shim: RouterShim = ctx["shim"]
	var ws = ctx["ws"]

	var minted: Dictionary = PanelTools._add_route_intent(shim, _args({
		"source_pin": "U1.1", "dest_pin": "J1.1", "width_mm": 0.5}))
	var hid := str(minted.get("hint_id", ""))
	var prop: Dictionary = await PanelTools._workspace_propose(shim, _args({"hint_ids": [hid]}))
	var cid := _first_cid(prop)
	check("C0: fixture landed one candidate", not cid.is_empty())
	if cid.is_empty() or ws.get_candidate(cid) == null:
		_free_ctx(ctx)
		return
	var task_id := str(ws.get_candidate(cid).task_id)

	# ── hint-ALIVE reroute stays byte-identical: no fallback key, hint-scoped ──
	var alive: Dictionary = await PanelTools._workspace_reroute_route(shim, _args({"candidate_id": cid}))
	check("Cpre1: hint-alive reroute succeeds", bool(alive.get("success", false)))
	check("Cpre2: hint-alive reroute does NOT carry hintless_fallback (a blanket flag fails here)",
		not alive.has("hintless_fallback"))
	check("Cpre3: hint-alive reroute stayed hint-scoped",
		_ids_as_set((shim.calls[shim.calls.size() - 1]["selection"] as Dictionary).get("ids", [])) == [hid])
	var cid2 := _first_cid(alive)
	check("Cpre4: reroute landed a fresh generation", not cid2.is_empty() and cid2 != cid)
	if cid2.is_empty():
		_free_ctx(ctx)
		return

	# ── orphan it: the annotation dies, the candidate stays ──────────────────
	check("C1: hint deleted", shim.remove_annotation(hid))

	var out: Dictionary = await PanelTools._workspace_reroute_route(shim, _args({"candidate_id": cid2}))
	check("C2: orphan reroute SUCCEEDS (no source_hints_missing refusal)",
		bool(out.get("success", false)))
	check("C3: reply says the run degraded to hint-less scoping",
		bool(out.get("hintless_fallback", false)))
	var cid3 := _first_cid(out)
	check("C4: a new generation landed", not cid3.is_empty() and cid3 != cid2)
	var new_c = ws.get_candidate(cid3) if not cid3.is_empty() else null
	check("C5: new generation lands on the SAME task (ingest task-key override)",
		new_c != null and str(new_c.task_id) == task_id)
	var old_c = ws.get_candidate(cid2)
	check("C6: prior generation superseded, never a duplicate live answer",
		old_c != null and str(old_c.disposition) == "superseded")
	# Census, not just labels (cold review f4): one live candidate, one task —
	# a post-hoc task_id reassignment over a stray "SIG|" task fails here.
	check("C6b: exactly ONE live candidate answers the question",
		_ids_as_set(ws.live_candidate_ids()) == _ids_as_set([cid3]))
	check_eq("C6c: exactly one task exists for net SIG (no phantom key)",
		_sig_task_count(ws), 1)
	check("C7: router scope carried the candidate's task + endpoint pin refs",
		not shim.calls.is_empty() and _last_scope_has_terminals(shim, task_id))

	# ── RE-ENTRANCY (cold review f6): the fallback generation itself has no
	# hint provenance (worker attributed []) — the OTHER refusal branch
	# (no_source_hints). A second orphan reroute must still scope: endpoints
	# survive on fallback generations.
	var out2: Dictionary = await PanelTools._workspace_reroute_route(shim, _args({"candidate_id": cid3}))
	check("C8: SECOND orphan reroute succeeds (no_source_hints branch degraded too)",
		bool(out2.get("success", false)))
	check("C9: second fallback is honest too", bool(out2.get("hintless_fallback", false)))
	var cid4 := _first_cid(out2)
	check("C10: generation 3 lands on the same task, sole live answer",
		not cid4.is_empty() and ws.get_candidate(cid4) != null
		and str(ws.get_candidate(cid4).task_id) == task_id
		and _ids_as_set(ws.live_candidate_ids()) == _ids_as_set([cid4]))
	check("C11: second fallback still scoped by endpoints (they survived ingest)",
		_last_scope_has_terminals(shim, task_id))
	_free_ctx(ctx)


func _last_scope_has_terminals(shim: RouterShim, task_id: String) -> bool:
	var extra: Dictionary = shim.calls[shim.calls.size() - 1]["extra"]
	var scope: Dictionary = extra.get("scope", {}) if extra.get("scope", {}) is Dictionary else {}
	var tasks: Array = scope.get("tasks", []) if scope.get("tasks", []) is Array else []
	if tasks.size() != 1 or not (tasks[0] is Dictionary):
		return false
	var t: Dictionary = tasks[0]
	if str(t.get("task_id", "")) != task_id or str(t.get("net", "")) != "SIG":
		return false
	var eps: Array = t.get("endpoints", []) if t.get("endpoints", []) is Array else []
	return _ids_as_set(eps) == ["J1.1", "U1.1"]


# ══ D. vocabulary — proposal means ghost, everywhere the user reads ══════════

func _run_d_vocabulary() -> void:
	print("\n-- D. labels: the hint cluster is 'Intents'; guidance teaches spans --")
	var ctx: Dictionary = await _panel_context(true)
	var panel = ctx["panel"]

	# _add_group_label names its node text + "GroupLabel" (PCBPanel.gd:1386) —
	# node-name assertions beat text scans for the two headers themselves…
	check("D1: no 'ProposalsGroupLabel' node exists",
		panel.find_child("ProposalsGroupLabel", true, false) == null)
	check("D2: an 'IntentsGroupLabel' node exists over the hint author cluster",
		panel.find_child("IntentsGroupLabel", true, false) != null)
	# …and a case-insensitive text sweep catches renames that dodge the node
	# name ("Proposal Tools", "Proposals:"). Rooted at the SIDEBAR only
	# (re-review should-fix A): the STATUS line legitimately counts
	# "N proposals" — those ARE ghosts, the DCR's own ruling — so a whole-tree
	# sweep would go red against compliant text the moment a propose runs
	# before this walk. The Propose BUTTON is a Button, not a Label, so the
	# sidebar sweep stays honest.
	var labels: Array = []
	_collect_labels(panel._sidebar_content, labels)
	var offenders: Array = []
	for t in labels:
		if str(t).findn("proposal") != -1:
			offenders.append(t)
	check("D2b: no sidebar Label mentions 'proposal' at all (%s)" % str(offenders),
		offenders.is_empty())

	# The no-work guidance note teaches the one-call path.
	var ctx2: Dictionary = await _panel_context()
	var out: Dictionary = await PanelTools._workspace_propose(ctx2["shim"], _args())
	check("D3: empty-propose guidance mentions spans",
		str(out.get("note", "")).findn("spans") != -1)

	_free_ctx(ctx2)
	ctx["driver"].free_panel(panel)
	await process_frame


func _collect_labels(node: Node, out_texts: Array) -> void:
	if node is Label:
		out_texts.append(str((node as Label).text))
	for child in node.get_children():
		_collect_labels(child, out_texts)
