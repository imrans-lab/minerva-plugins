extends SceneTree
## EPOCH NLC station C1 — inner-layer vias: never silently re-layered (C1a,
## groups 1-4), and actually placeable (C1b, groups 5-6). Item 019fff6080fd,
## opened by the GA A1 co-design HITL.
##
## The two halves are one story told at two seams. A via has a SPAN (the hole,
## always top<->bottom under the v1 through-via model) and the run it sits on
## has a CONTINUATION LAYER (where the copper carries on). While the stack was
## two layers deep those were the same value, and both halves of this file are
## consequences of them no longer being so:
##   * the HINT half used to GUESS the continuation ("else F.Cu") — C1a makes it
##     refuse instead, because a guess about which copper layer a trace lands on
##     is not one to make silently;
##   * the CANDIDATE half used to validate the continuation with
##     is_legal_via_span, whose STACK_INDEX is {"top","bottom"} — so it refused
##     EVERY inner continuation on EVERY board ("I cannot propose any via at
##     all", the owner's HITL). C1b asks the right question of it instead.
##
## Run (via a Minerva checkout as the Godot host):
##   pcb/scripts/run-gd-tests.sh <path-to-minerva-checkout>
##
## THE DEFECT THIS PINS. pcb_route_hint_kind.gd's layer-run toggle used to read
##     return "B.Cu" if layer == "F.Cu" else "F.Cu"
## so EVERY layer it did not recognise answered "F.Cu". Inserting a via on an
## In1.Cu route therefore relabelled the whole downstream run to the TOP layer
## and reported success. Nothing warned, and the canvas then drew the hint on a
## layer the hint's own kind_payload.layer still disagreed with.
##
## WHY THE ORACLE IS THE PERSISTED ANNOTATION, NOT THE RETURN VALUE.
##
## HISTORY, because the reason CHANGED mid-epoch and a stale rationale is worse
## than none. The process law asked for emitted Gerbers as C1's oracle, on the
## premise that these layers reached fabricated copper. At C1a they did NOT:
## materialize_detailed_hints built from the hint's single kind_payload.layer
## with "vias": [], hints_to_router used waypoints + preferred_layer, and the
## only path that carried per-segment layers to a candidate was dormant. A
## Gerber assertion would have passed for the wrong reason, so the oracle became
## the persisted annotation.
##
## THAT PREMISE IS NOW VOID, AND BY THIS EPOCH'S OWN HAND: C1b (commit 9030439)
## taught route_bridge to materialize authored per-segment layers and vias
## VERBATIM, which CREATED the consumer whose absence justified the choice. A
## Gerber-level oracle is possible at HEAD and is owed — filed rather than
## silently skipped, because a rationale nobody re-reads is how a deliberate
## choice becomes an accident.
##
## What these assertions still buy, and why they stay: they read back through
## PcbAnnotationHost.get_by_id AFTER the real MCP verb (PanelTools._add_via, a
## different file) has run, so a toggle that lies is caught at the point the lie
## becomes durable — one seam earlier than emission, and it fails for a reason
## a reader can act on rather than a diff in a .gbr.
##
## REUSE SCAN: panel/host boot + check helpers copied from
## test_parity_bridge.gd (plugin_panel_driver, host.set_panel). The hint
## envelope is built with host.build_route_hint_envelope, the same builder
## _seed_source_hint uses there — no hand-rolled annotation dicts. No
## workspace/candidate machinery is involved: _add_via's bridged sync needs a
## correlated candidate, and these groups deliberately have none, so the
## annotation half is exercised alone.

const PanelTools := preload("res://../../minerva-plugins/pcb/ui/panel_tools.gd")
const PcbWorkspace := preload("res://../../minerva-plugins/pcb/ui/model/pcb_routing_workspace.gd")
const PcbRouteCandidate := preload("res://../../minerva-plugins/pcb/ui/model/pcb_route_candidate.gd")
const PCB_PANEL_SCRIPT_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== Inner-layer via guard (NLC C1a) ===\n")
	_run_inner_layer_refuses()
	_run_two_layer_still_toggles()
	_run_canonical_spelling_still_toggles()
	_run_miss_is_still_a_miss()
	_run_candidate_continuation_onto_inner()
	_run_candidate_refusals_survive()
	_run_authored_inner_layer_is_not_clobbered()
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


# ── fixture ───────────────────────────────────────────────────────────────────

## Boot a real PCBPanel + host and store ONE single_trace hint whose route is a
## single straight run (0,0)->(10,0) on `layer`, with no vias yet. Returns
## {driver, panel, host, ann_id}.
##
## The segment list is written onto the envelope explicitly: the builder seeds
## geometry from the polyline, and this suite's whole subject is the per-segment
## `layer` key, which must be the layer under test rather than whatever default
## the builder would pick.
func _hint_context(layer: String) -> Dictionary:
	var driver = preload("res://test/helpers/plugin_panel_driver.gd").new()
	var panel = driver.load_panel(PCB_PANEL_SCRIPT_PATH)
	var host = panel.get_annotation_host()
	host.set_panel(panel)

	var envelope: Dictionary = host.build_route_hint_envelope(
		0.0, 0.0, "", layer, "single_trace", [[0.0, 0.0], [10.0, 0.0]], "human")
	var kp: Dictionary = envelope.get("kind_payload", {})
	kp["net_names"] = ["N1"]
	kp["segments"] = [{"start": [0.0, 0.0], "end": [10.0, 0.0], "layer": layer}]
	kp["vias"] = []
	envelope["kind_payload"] = kp
	var ann_id := str(host.add_annotation_v2(envelope))

	return {"driver": driver, "panel": panel, "host": host, "ann_id": ann_id}


## Every stored segment's `layer`, read back from the HOST (never from the
## verb's own reply — the reply is the thing under test).
func _stored_layers(host, ann_id: String) -> Array:
	var kp: Dictionary = host.get_by_id(ann_id).get("kind_payload", {})
	var out: Array = []
	for seg in kp.get("segments", []):
		if seg is Dictionary:
			out.append(str((seg as Dictionary).get("layer", "")))
	return out


func _stored_via_count(host, ann_id: String) -> int:
	var kp: Dictionary = host.get_by_id(ann_id).get("kind_payload", {})
	var vias: Variant = kp.get("vias", [])
	return (vias as Array).size() if vias is Array else -1


# ── 1. an inner-layer run REFUSES, and nothing is written ─────────────────────

func _run_inner_layer_refuses() -> void:
	print("-- 1. via on an In1.Cu run: refused by name, annotation untouched --")
	var ctx := _hint_context("In1.Cu")
	var host = ctx["host"]
	var ann_id: String = ctx["ann_id"]

	check_eq("fixture stores one In1.Cu segment", _stored_layers(host, ann_id), ["In1.Cu"])
	check_eq("fixture stores no vias", _stored_via_count(host, ann_id), 0)

	# ON the run — (5,0) is the midpoint of (0,0)->(10,0), so this is a HIT.
	# A refusal here is about the LAYER, never about the geometry.
	var res: Dictionary = PanelTools._add_via(host, {"id": ann_id, "x": 5.0, "y": 0.0})
	check("add_via refuses", not bool(res.get("success", false)))
	check_eq("refusal is named unsupported_layer", str(res.get("error_code", "")), "unsupported_layer")
	check("refusal message names the layer it could not leave",
		str(res.get("error", "")).contains("In1.Cu"))

	# THE ORACLE. Before C1a this read back ["In1.Cu", "F.Cu"] with one via:
	# the tail of an inner-layer route silently moved to the top layer under a
	# success reply. A refusal that still mutated would fail here.
	check_eq("stored segments are UNCHANGED (no silent relabel to F.Cu)",
		_stored_layers(host, ann_id), ["In1.Cu"])
	check_eq("no via was appended", _stored_via_count(host, ann_id), 0)

	ctx["driver"].free_panel(ctx["panel"])


# ── 2. the two-layer case still works (both directions or neither) ────────────

func _run_two_layer_still_toggles() -> void:
	print("-- 2. via on an F.Cu run: still splits and still flips to B.Cu --")
	var ctx := _hint_context("F.Cu")
	var host = ctx["host"]
	var ann_id: String = ctx["ann_id"]

	var res: Dictionary = PanelTools._add_via(host, {"id": ann_id, "x": 5.0, "y": 0.0})
	check("add_via succeeds on F.Cu", bool(res.get("success", false)))
	check("a success carries no error_code", not res.has("error_code"))

	# A guard that refused EVERYTHING would satisfy group 1 while making the
	# tool useless — that is the half-mutation this group exists to kill.
	check_eq("the run was split in two", _stored_layers(host, ann_id).size(), 2)
	check_eq("head stays on F.Cu", _stored_layers(host, ann_id)[0], "F.Cu")
	check_eq("tail flips to B.Cu", _stored_layers(host, ann_id)[1], "B.Cu")
	check_eq("exactly one via was appended", _stored_via_count(host, ann_id), 1)

	ctx["driver"].free_panel(ctx["panel"])


# ── 3. the OTHER spelling of the same two layers still works ──────────────────

func _run_canonical_spelling_still_toggles() -> void:
	print("-- 3. via on a canonical \"bottom\" run: toggles, and stays canonical --")
	var ctx := _hint_context("bottom")
	var host = ctx["host"]
	var ann_id: String = ctx["ann_id"]

	# Segments on this payload are written by more than one producer, and
	# _layer_color reads both vocabularies (PcbLayerStack.inner_index_any). A
	# guard that matched only "F.Cu"/"B.Cu" would refuse this legitimate run —
	# the regression this group exists to catch, not a style preference.
	var res: Dictionary = PanelTools._add_via(host, {"id": ann_id, "x": 5.0, "y": 0.0})
	check("add_via succeeds on a canonical \"bottom\" run", bool(res.get("success", false)))
	check_eq("head stays on bottom", _stored_layers(host, ann_id)[0], "bottom")
	# Answered in the spelling it was ASKED in — a toggle that silently switched
	# vocabulary mid-payload would leave one hint carrying both.
	check_eq("tail flips to canonical top, not F.Cu", _stored_layers(host, ann_id)[1], "top")

	ctx["driver"].free_panel(ctx["panel"])


# ── 4. a MISS keeps its own name (the canvas fall-through depends on it) ──────

func _run_miss_is_still_a_miss() -> void:
	print("-- 4. via nowhere near the run: no_segment_at_point, not a layer error --")
	var ctx := _hint_context("In1.Cu")
	var host = ctx["host"]
	var ann_id: String = ctx["ann_id"]

	# Far off the run. The two refusals must stay distinguishable: the canvas
	# gesture CONSUMES an unsupported_layer click (and toasts) but falls through
	# on a miss so a candidate underneath can still take it.
	var res: Dictionary = PanelTools._add_via(host, {"id": ann_id, "x": 500.0, "y": 500.0})
	check("add_via refuses", not bool(res.get("success", false)))
	check_eq("refusal is named no_segment_at_point",
		str(res.get("error_code", "")), "no_segment_at_point")
	check_eq("annotation untouched by a miss too", _stored_layers(host, ann_id), ["In1.Cu"])

	ctx["driver"].free_panel(ctx["panel"])


# ── 5. THE HITL BLOCKER: a run may now continue onto an INNER layer ───────────
#
# "There is no tool to place a via for the human ... I cannot propose any via at
# all" (owner, N-layer co-design HITL). The cause was not the hint toggle: it
# was RoutingWorkspace.add_via testing the CONTINUATION layer with
# is_legal_via_span, whose STACK_INDEX holds exactly {"top","bottom"}, so every
# inner-layer continuation was refused illegal_via_span on every board.
#
# This group drives the model verb directly — no panel, no host — because the
# claim is about the workspace's own contract.

func _inner_candidate() -> Array:
	var ws = PcbWorkspace.new()
	var c = PcbRouteCandidate.new()
	c.net = "N1"
	c.add_segment(PcbRouteCandidate.make_segment("", "in1", 0.3, [Vector2(0, 0), Vector2(10, 0)]))
	var cid := str(ws.add_candidate(c))
	return [ws, cid]


func _run_candidate_continuation_onto_inner() -> void:
	print("-- 5. candidate via: an in1 run may continue on top; span stays through --")
	var pair := _inner_candidate()
	var ws = pair[0]
	var cid: String = pair[1]

	var res: Dictionary = ws.add_via(cid, Vector2(5.0, 0.0), "in1", "top")
	check("a via on an in1 run is ACCEPTED", bool(res.get("ok", false)))
	check_eq("the run continues on top", str(res.get("to_layer", "")), "top")

	# THE SEPARATION C1b EXISTS FOR. The run goes in1 -> top; the HOLE is still
	# a through via, top<->bottom. Recording the run's endpoints as the span is
	# what made an inner continuation look like a blind/buried via to every
	# downstream reader, and blind/buried is out of scope v1.
	check_eq("the via's own span is the THROUGH span, not in1->top",
		res.get("via_span", []), ["top", "bottom"])

	var c = ws.get_candidate(cid)
	check_eq("exactly one via exists", (c.vias as Array).size(), 1)
	var via: Dictionary = c.vias[0]
	check_eq("stored via from_layer is top", str(via.get("from_layer", "")), "top")
	check_eq("stored via to_layer is bottom", str(via.get("to_layer", "")), "bottom")
	# via_span_legal is what commit's pre-flight gates on: a via recorded as
	# in1->top would fail it, so this is the assertion that proves the fix
	# reaches copper rather than stopping at the reply.
	check("the stored via passes the commit pre-flight's span check", c.via_span_legal(via))

	# The head keeps in1, the tail continues on top.
	var layers: Array = []
	for s in c.segments:
		if s is Dictionary:
			layers.append(str((s as Dictionary).get("layer", "")))
	check_eq("head stays on in1, tail continues on top", layers, ["in1", "top"])


# ── 6. the two refusals that must SURVIVE the loosening ───────────────────────
#
# Loosening a gate is where guards die quietly: this group is the half-mutation
# check. A continuation that changes nothing, and one onto something that is not
# copper at all, must still be refused — by their own distinct names.

func _run_candidate_refusals_survive() -> void:
	print("-- 6. same-layer and non-copper continuations still refuse --")
	var pair := _inner_candidate()
	var ws = pair[0]
	var cid: String = pair[1]

	var same: Dictionary = ws.add_via(cid, Vector2(5.0, 0.0), "in1", "in1")
	check("a continuation onto the SAME layer refuses", not bool(same.get("ok", true)))
	check_eq("named illegal_via_span", str(same.get("error", "")),
		PcbWorkspace.ERR_ILLEGAL_VIA_SPAN)

	var junk: Dictionary = ws.add_via(cid, Vector2(5.0, 0.0), "in1", "F.SilkS")
	check("a continuation onto a NON-COPPER layer refuses", not bool(junk.get("ok", true)))
	check_eq("named continuation_layer_not_copper", str(junk.get("error", "")),
		PcbWorkspace.ERR_CONTINUATION_NOT_COPPER)

	var c = ws.get_candidate(cid)
	check_eq("every refusal was a no-op: still one unsplit segment",
		(c.segments as Array).size(), 1)
	check_eq("every refusal was a no-op: no via", (c.vias as Array).size(), 0)


# ── 7. THE GAP C1a's FIRST GUARD LEFT OPEN (cold review, finding 1) ───────────
#
# _recompute_layer_runs overwrites EVERY segment's layer from the running toggle
# value, so an authored layer is discarded before the toggle sees it. Guarding
# only the RUNNING layer therefore missed the case that matters most: a payload
# of [F.Cu, In1.Cu] starts on F.Cu — which IS toggleable — so the walk proceeded
# and relabelled the In1.Cu run "B.Cu" under a success reply.
#
# This is not a hypothetical payload. Epoch NLC C1b taught route_bridge to
# materialize authored per-segment layers VERBATIM, so a mixed-layer hint is
# first-class data that now reaches copper. Before this fix the hint editor
# destroyed exactly what the worker had just been taught to honour.

func _mixed_layer_context() -> Dictionary:
	var ctx := _hint_context("F.Cu")
	var host = ctx["host"]
	var ann: Dictionary = host.get_by_id(ctx["ann_id"])
	var kp: Dictionary = ann.get("kind_payload", {})
	kp["segments"] = [
		{"start": [0.0, 0.0], "end": [5.0, 0.0], "layer": "F.Cu"},
		{"start": [5.0, 0.0], "end": [10.0, 0.0], "layer": "In1.Cu"},
	]
	ann["kind_payload"] = kp
	host.update_annotation(str(ctx["ann_id"]), ann)
	return ctx


func _run_authored_inner_layer_is_not_clobbered() -> void:
	print("-- 7. a via on a MIXED [F.Cu, In1.Cu] run refuses, keeping In1.Cu --")
	var ctx := _mixed_layer_context()
	var host = ctx["host"]
	var ann_id: String = ctx["ann_id"]

	check_eq("fixture stores the mixed authored run",
		_stored_layers(host, ann_id), ["F.Cu", "In1.Cu"])

	# The click lands on the F.Cu head — a layer the toggle CAN resolve. The
	# old guard passed here and the walk then destroyed the In1.Cu tail.
	var res: Dictionary = PanelTools._add_via(host, {"id": ann_id, "x": 2.5, "y": 0.0})
	check("add_via refuses on a mixed authored payload", not bool(res.get("success", false)))
	check_eq("named unsupported_layer", str(res.get("error_code", "")), "unsupported_layer")
	check("the refusal names the authored layer it could not resolve",
		str(res.get("error", "")).contains("In1.Cu"))

	# THE ORACLE. Before this fix the readback was ["F.Cu", "B.Cu", "B.Cu"] —
	# a split, plus an authored inner run silently moved to the bottom layer,
	# under success:true.
	check_eq("the authored run is intact", _stored_layers(host, ann_id), ["F.Cu", "In1.Cu"])
	check_eq("no via was appended", _stored_via_count(host, ann_id), 0)

	ctx["driver"].free_panel(ctx["panel"])
