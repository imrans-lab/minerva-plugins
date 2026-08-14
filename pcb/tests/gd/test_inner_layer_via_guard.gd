extends SceneTree
## EPOCH NLC station C1a — a via insert never silently re-layers an inner-layer
## run (item 019fff6080fd, opened by the GA A1 co-design HITL).
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
## WHY THE ORACLE IS THE PERSISTED ANNOTATION, NOT THE RETURN VALUE. The
## process law for this epoch asked for emitted Gerbers as C1's oracle, on the
## premise that the corrupted layers reached fabricated copper. THEY DO NOT,
## and a Gerber assertion here would have passed for the wrong reason —
## route_bridge.materialize_detailed_hints (route_bridge.py:1653) builds its
## route from the hint's SINGLE kind_payload.layer with "vias": [], and
## hints_to_router uses waypoints + preferred_layer; neither reads
## kind_payload.segments[].layer or kind_payload.vias. The live consumer of
## these fields is the CANVAS, so the furthest-downstream thing that can be
## asserted mechanically is what got STORED on the host. That is still a
## different representation from the code under test: these assertions read
## back through PcbAnnotationHost.get_by_id after the real MCP verb
## (PanelTools._add_via, a different file) has run, so a toggle that lies is
## caught at the point the lie becomes durable. See the epoch record for the
## corrected diagnosis.
##
## REUSE SCAN: panel/host boot + check helpers copied from
## test_parity_bridge.gd (plugin_panel_driver, host.set_panel). The hint
## envelope is built with host.build_route_hint_envelope, the same builder
## _seed_source_hint uses there — no hand-rolled annotation dicts. No
## workspace/candidate machinery is involved: _add_via's bridged sync needs a
## correlated candidate, and these groups deliberately have none, so the
## annotation half is exercised alone.

const PanelTools := preload("res://../../minerva-plugins/pcb/ui/panel_tools.gd")
const PCB_PANEL_SCRIPT_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== Inner-layer via guard (NLC C1a) ===\n")
	_run_inner_layer_refuses()
	_run_two_layer_still_toggles()
	_run_canonical_spelling_still_toggles()
	_run_miss_is_still_a_miss()
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
