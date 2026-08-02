extends SceneTree
## DRC-at-propose E2E (docket 019f6f1492e0): real PCBPanel + REAL worker.
##
## Extends the C5 explicit-propose product contract (test_pcb_explicit_propose.gd)
## with the DRC-at-propose deliverable: after Propose routes open hints, each
## landed candidate's own `drc` verdict (pcb_worker.methods._attach_route_drc
## reusing drc.py's existing geometric checks verbatim) carries the worker's
## per-route DRC verdict, the propose envelope surfaces a top-level
## drc_summary, and the panel status label appends a DRC suffix.
##
## S5 (C4b, DCR 019f7095c395) UPDATE: propose no longer writes a proposal
## annotation (panel_tools.gd _propose_into_workspace), so the per-route `drc`
## verdict — formerly stamped on kind_payload.drc — now lands directly on the
## reply's own proposals[] entries instead (see the drc/drc_geometric parity
## note at that call site). The WorkflowAnnotationList dock badge deliverable
## is now a negative proof (no annotation ever carries drc, so no row ever
## grows a badge), and "accepting a violating proposal" is
## minerva_pcb_workspace_commit(candidate_id) — still informs, never blocks.
##
## Run: godot --headless --path . --script test/test_pcb_drc_propose.gd
## (from the Minerva WORKTREE's src/ directory — never the owner's live
## checkout, see CRITICAL SAFETY in the round brief).
##
## Fixture geometry (deliberately mirrors pcb/worker/tests/test_route_drc.py so
## the plugin-side and worker-side DRC coverage reason about the SAME shapes):
##   * SIG1: U1(10,20) <-> J1(50,20), straight pad-to-pad — CROSSES an existing
##     EXIST trace authored directly on the board at x=30 (y 5..35, same
##     "top" layer) -> its proposal must come back dirty.
##   * SIG2: U3(10,60) <-> J3(50,60), straight pad-to-pad, far from EXIST ->
##     its proposal must come back clean.
## Both hints are 'detailed' (0 interior waypoints, i.e. pad -> pad verbatim)
## so both the real worker AND this suite's canned stdio-boundary fallback
## (which always emits a straight pad-to-pad segment, ignoring waypoints)
## produce IDENTICAL routed geometry — the DRC assertions hold on either path.
##
## REUSE SCAN: mount/input/real-worker-stdio/FakeBrokerIpc conventions copied
## verbatim from test_pcb_explicit_propose.gd (same PANEL_PATH, same
## e2e_route_stdio.py bridge, same documented canned fallback). The existing
## suite's own scenarios (A-F) are left untouched — this is a fresh dedicated
## suite rather than a 7th scenario grafted onto that file's already-shared
## six-scenario fixture state, per the round brief's "(or a new suite modeled
## on it)" option.

const PANEL_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"
const REGISTRY_DRIVER := preload("res://test/helpers/panel_tool_registry_driver.gd")

const EDITOR_NAME := "DrcProposeProbe"
const PLUGIN_ROOT := "res://../../minerva-plugins/pcb"
const PCB_PLUGIN_ID := "pcb"

var _pass := 0
var _fail := 0
var _used_real_worker := false

var panel = null
var host = null
var data = null

const U1_PIN := Vector2(10.0, 20.0)
const J1_PIN := Vector2(50.0, 20.0)
const U3_PIN := Vector2(10.0, 60.0)
const J3_PIN := Vector2(50.0, 60.0)


class FakeEditor extends RefCounted:
	var tab_title: String = EDITOR_NAME
	var associated_object: Variant = ""


func _init() -> void:
	print("=== PCB DRC-at-Propose E2E (docket 019f6f1492e0) ===\n")
	await process_frame

	if not await _mount():
		printerr("SETUP FAILED — cannot mount PCB panel; aborting")
		quit(1)
		return

	await _test_propose_flags_dirty_and_clean_routes()

	panel.queue_free()
	await process_frame
	AnnotationHostRegistry._reset_for_test()

	print("\n=== Results: %d passed, %d failed (real_worker_used=%s) ===" % [_pass, _fail, str(_used_real_worker)])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


# ── mount + fixture (test_pcb_explicit_propose.gd conventions) ───────────────

func _mount() -> bool:
	panel = load(PANEL_PATH).new()
	if panel == null:
		return false
	get_root().add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.size = Vector2(900, 700)
	panel._on_panel_loaded({"editor": FakeEditor.new(), "file_path": ""})

	host = panel.get_annotation_host()
	data = panel.get_data()
	if host == null or data == null:
		return false

	_build_fixture_board(data)
	_seed_hints()

	for _i in range(4):
		await process_frame

	AnnotationHostRegistry._reset_for_test()
	AnnotationHostRegistry.register(EDITOR_NAME, host)
	return true


## SIG1 (U1<->J1) will collide with a hand-authored EXIST trace; SIG2
## (U3<->J3) sits far away and stays clean. EXIST is authored as a raw trace
## with NO matching net/components entry — board_to_router() (the router's
## own board builder) only reads canonical board "nets", never "traces", so
## an untracked EXIST trace cannot be auto-routed by the engine's "route every
## net with >=2 pads" behavior (see nudge hint
## pcb-plugin/router-reroutes-whole-board) — it exists purely as fixed copper
## for the DRC pass to check the new routes against, keeping this fixture
## deterministic.
func _build_fixture_board(d) -> void:
	d.board_width = 70.0
	d.board_height = 80.0
	# The worker's compile_board._build_design_rules fail-closed refuses a
	# board whose design_rules block omits/nulls any of the four positive-
	# number rules (design_rules.trace_width_mm/via_diameter_mm/via_drill_mm/
	# clearance_mm) — "v1 refuses to invent trace/via/clearance" — rather than
	# defaulting silently. This fixture's default (unset) design_rules = {}
	# therefore made every real-worker compile fail with
	# "design_rules.trace_width_mm must be a positive number; got None"
	# (docket 019fc22284537bdfa9861c159bad76b1 defect 2), keeping the
	# real-worker branch below unreachable. Fix is fixture-side: author real
	# rules, matching the canonical values other worker fixtures use
	# (pcb/worker/tests/test_ir_fab.py etc.) and the 0.25 width already
	# authored on the EXIST trace + both route hints below, so nothing in this
	# suite's geometry assumptions changes.
	d.design_rules = {
		"trace_width_mm": 0.25,
		"clearance_mm": 0.2,
		"via_diameter_mm": 0.8,
		"via_drill_mm": 0.4,
	}

	var u1 = d.new_component()
	u1.id = "U1"
	u1.position = U1_PIN
	u1.pins = {"SIG1": Vector2(0.0, 0.0)}
	d.add_component(u1)

	var j1 = d.new_component()
	j1.id = "J1"
	j1.position = J1_PIN
	j1.pins = {"SIG1": Vector2(0.0, 0.0)}
	d.add_component(j1)

	d.connect_pin_to_net("SIG1", "U1", "SIG1")
	d.connect_pin_to_net("SIG1", "J1", "SIG1")

	var u3 = d.new_component()
	u3.id = "U3"
	u3.position = U3_PIN
	u3.pins = {"SIG2": Vector2(0.0, 0.0)}
	d.add_component(u3)

	var j3 = d.new_component()
	j3.id = "J3"
	j3.position = J3_PIN
	j3.pins = {"SIG2": Vector2(0.0, 0.0)}
	d.add_component(j3)

	d.connect_pin_to_net("SIG2", "U3", "SIG2")
	d.connect_pin_to_net("SIG2", "J3", "SIG2")

	# EXIST is fixed pre-existing copper, not an auto-routable net — its trace
	# must still name a net the board actually declares (compile_board.py:
	# "trace 0: references unknown net 'EXIST'" otherwise, a real canonical-
	# format constraint the router-only path never exercised), and that net
	# must resolve to >=1 real placed pad (compile_board.py's _finalize_nets:
	# "net 'EXIST' has no resolved placed pads" otherwise — an unpinned net is
	# not a legal board any more than an untraced one is). One anchor
	# component, pinned at the EXIST trace's own start point, satisfies both
	# without breaking the fixture's actual invariant: board_to_router()'s
	# "route every net with >=2 pads" heuristic only fires at 2, so a
	# ONE-pad EXIST still never gets auto-rerouted (see the class doc above).
	var exist_anchor = d.new_component()
	exist_anchor.id = "EXIST_ANCHOR"
	exist_anchor.position = Vector2(30.0, 5.0)
	exist_anchor.pins = {"1": Vector2(0.0, 0.0)}
	d.add_component(exist_anchor)
	d.connect_pin_to_net("EXIST", "EXIST_ANCHOR", "1")

	var exist_trace = d.new_trace()
	exist_trace.net_name = "EXIST"
	exist_trace.layer = "top"
	exist_trace.width = 0.25
	# trace.waypoints is Array[Vector2] — append one at a time (matches
	# PCBPanel._materialize_routes' own convention) rather than assigning a
	# plain Array literal, which the typed-array setter rejects.
	exist_trace.waypoints.append(Vector2(30.0, 5.0))
	exist_trace.waypoints.append(Vector2(30.0, 35.0))
	d.add_trace(exist_trace)


## Hints built directly (host.build_route_hint_envelope), same pattern as
## test_pcb_explicit_propose.gd scenario E's fresh_hint_id — this suite's
## focus is the DRC wiring, not re-proving real-click hint authoring (already
## covered by scenario A of that suite).
func _seed_hints() -> void:
	var env1: Dictionary = host.build_route_hint_envelope(
		U1_PIN.x, U1_PIN.y, "", "F.Cu", "single_trace",
		[], "human", "detailed", 0.25, ["U1.SIG1"], ["J1.SIG1"])
	var id1 := str(host.add_annotation_v2(env1))
	check("setup: SIG1 (dirty) hint seeded", not id1.is_empty())

	var env2: Dictionary = host.build_route_hint_envelope(
		U3_PIN.x, U3_PIN.y, "", "F.Cu", "single_trace",
		[], "human", "detailed", 0.25, ["U3.SIG2"], ["J3.SIG2"])
	var id2 := str(host.add_annotation_v2(env2))
	check("setup: SIG2 (clean) hint seeded", not id2.is_empty())


# ── real-worker broker-fidelity fake (test_pcb_explicit_propose.gd convention) ─

class FakeBrokerIpc:
	extends Node
	var suite = null
	var _params: Dictionary = {}
	var _reply_id: String = ""

	func on_request(channel: String, params: Dictionary, reply_id: String) -> void:
		if channel == "pcb.route":
			_params = params
			_reply_id = reply_id

	func await_reply(reply_id: String, _timeout_ms: int = 0) -> Dictionary:
		if reply_id != _reply_id or suite == null:
			return {"success": false, "error_code": "timeout", "error_message": "no captured request"}
		var worker_env: Dictionary = suite.raw_worker_envelope(_params)
		return {"success": true, "result": worker_env}


## The GD board model's component "footprint" field (pcb_data.gd's
## to_board_dict()) is always the RENDER-ONLY FootprintType enum name
## (RESISTOR/CUSTOM/MODULE/…) — there is no component API that can carry a
## real KiCad library ref, and no fixture change alone can produce one.
## pcb_worker's compile_board.resolve_footprint() requires an EXACT
## pcb/library/footprints.lock.json key or refuses "footprint ref ... is not
## in the seed library lockfile" (fail-closed, Round E cutover 019f783860c8 —
## routing never approximates copper). TH_TestPoint is the lockfile's one
## single-pad thru_hole part (pad "1" at local origin 0,0 — see
## pcb/library/footprints/TestPoint.pretty/TH_TestPoint.kicad_mod) and is an
## exact physical match for this fixture's components, which are all
## single-pin stand-ins placed with a zero local pin offset. See docket
## 019fc22284537bdfa9861c159bad76b1 (this rig-fix item) for the full chase.
const _REAL_FOOTPRINT_REF := "TH_TestPoint"


## Rewrites a WIRE COPY of the request so its components resolve against the
## real worker's footprint library — never the request `raw_worker_envelope`
## captured for any other purpose (params itself, and _params on the fake, are
## left untouched, so an assertion on the ORIGINAL request shape is unaffected
## by this real-worker-only patch).
##
## Renumbering is necessary, not just the footprint ref: compile_board.py's
## _check_coincidence requires each authored pin's "number" to match a REAL
## pad number on the (now TH_TestPoint) footprint — "1", not this fixture's
## readability-motivated pin name ("SIG1"/"SIG2", chosen to equal the net
## name). A net's own pin refs ("Ref.PinName") must point at that same
## renumbered pin or compile_board's net-membership check fails closed too.
## The mapping is DERIVED from each component's own authored pin (never
## hardcoded "SIG1"->"1"), so this works unchanged if the fixture's pin names
## ever do.
func _with_resolvable_footprints(params: Dictionary) -> Dictionary:
	var wire: Dictionary = params.duplicate(true)
	var board: Dictionary = wire.get("board", {})
	var renumber: Dictionary = {}  # "CompRef.OldPinName" -> "CompRef.1"
	for c in (board.get("components", []) as Array):
		if not (c is Dictionary):
			continue
		var comp: Dictionary = c
		comp["footprint"] = _REAL_FOOTPRINT_REF
		var ref := str(comp.get("ref", ""))
		for p in (comp.get("pins", []) as Array):
			if p is Dictionary:
				var old_number := str((p as Dictionary).get("number", ""))
				renumber["%s.%s" % [ref, old_number]] = "%s.1" % ref
				(p as Dictionary)["number"] = "1"
	for n in (board.get("nets", []) as Array):
		if not (n is Dictionary):
			continue
		var pin_refs: Array = (n as Dictionary).get("pins", [])
		for i in range(pin_refs.size()):
			var old_ref := str(pin_refs[i])
			if renumber.has(old_ref):
				pin_refs[i] = renumber[old_ref]
	# The route hints (params.route_hints, separate from params.board) name
	# their endpoints the SAME "Ref.PinName" way — kind_payload.source_pins/
	# dest_pins — and need the identical rename or the router logs "pin ...
	# does not resolve to a pad on the board" and falls back to unhinted
	# engine-guided routing (silently losing this suite's whole "detailed
	# hint, pad-to-pad, identical geometry on either path" contract — see the
	# class doc above).
	for hint in (wire.get("route_hints", []) as Array):
		if not (hint is Dictionary):
			continue
		var kp: Variant = (hint as Dictionary).get("kind_payload")
		if not (kp is Dictionary):
			continue
		for key in ["source_pins", "dest_pins"]:
			var pins: Array = (kp as Dictionary).get(key, [])
			for i in range(pins.size()):
				var old_ref := str(pins[i])
				if renumber.has(old_ref):
					pins[i] = renumber[old_ref]
	return wire


func raw_worker_envelope(params: Dictionary) -> Dictionary:
	var binary_path := ProjectSettings.globalize_path(PLUGIN_ROOT + "/pcb-plugin")
	var wrapper_path := ProjectSettings.globalize_path(PLUGIN_ROOT + "/scripts/e2e_route_stdio.py")
	if FileAccess.file_exists(binary_path) and FileAccess.file_exists(wrapper_path):
		var req_uri := "user://drc_propose_route_request.json"
		var f := FileAccess.open(req_uri, FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify(_with_resolvable_footprints(params)))
			f.close()
			var req_abs := ProjectSettings.globalize_path(req_uri)
			var output: Array = []
			var exit_code := OS.execute("python3", [wrapper_path, binary_path, req_abs], output, true)
			DirAccess.remove_absolute(req_abs)
			if exit_code == 0 and not output.is_empty():
				var parsed: Variant = JSON.parse_string(str(output[0]))
				if parsed is Dictionary and bool((parsed as Dictionary).get("ok", false)):
					_used_real_worker = true
					return parsed
	_used_real_worker = false
	push_warning("[test_pcb_drc_propose] real pcb-plugin binary unavailable — " +
		"falling back to a documented canned single-segment result (no DRC)")
	return {"ok": true, "result": _canned_result_for(params)}


## Contract-allowed fallback (subprocess-boundary fake), reached ONLY when the
## real binary isn't built: one straight pad->pad segment per open hint,
## deliberately WITHOUT any drc/drc_summary keys (a real worker is required to
## exercise the DRC assertions below; when this path is taken the suite still
## proves propose-without-DRC degrades gracefully — no badge, no status
## suffix — rather than skip outright).
func _canned_result_for(params: Dictionary) -> Dictionary:
	var routes: Array = []
	for hint in params.get("route_hints", []):
		if not (hint is Dictionary):
			continue
		var kp: Dictionary = (hint as Dictionary).get("kind_payload", {})
		var src: Array = kp.get("source_pins", [])
		var dst: Array = kp.get("dest_pins", [])
		if src.is_empty() or dst.is_empty():
			continue
		var src_pos := _pin_world_pos(str(src[0]))
		var dst_pos := _pin_world_pos(str(dst[0]))
		var net := _net_for_pin(str(src[0]))
		routes.append({
			"net": net,
			"segments": [{"start": [src_pos.x, src_pos.y], "end": [dst_pos.x, dst_pos.y], "layer": "F.Cu"}],
			"vias": [],
		})
	return {"success": true, "via_count": 0, "routes": routes, "unrouted": []}


func _pin_world_pos(ref: String) -> Vector2:
	var parts := ref.split(".")
	if parts.size() != 2:
		return Vector2.ZERO
	var comp = data.get_component(parts[0])
	if comp == null:
		return Vector2.ZERO
	return comp.get_pin_world_position(parts[1])


func _net_for_pin(ref: String) -> String:
	var parts := ref.split(".")
	if parts.size() != 2:
		return ""
	for net_name in data.nets:
		var net = data.nets[net_name]
		for pin in net.pins:
			if str(pin.get("component_id", "")) == parts[0] and str(pin.get("pin_name", "")) == parts[1]:
				return net.name
	return ""


## Real input on the Propose button — same async-drain convention as
## test_pcb_explicit_propose.gd's _click_propose_button.
func _click_propose_button() -> void:
	panel._propose_button.pressed.emit()
	var guard := 0
	while panel._status_label.text == "Proposing routes…" and guard < 200:
		await process_frame
		guard += 1


# ── the scenario ───────────────────────────────────────────────────────────

func _test_propose_flags_dirty_and_clean_routes() -> void:
	print("-- Propose (real input, REAL worker when available) --")

	var fake := FakeBrokerIpc.new()
	fake.name = "_MinervaIPC"
	fake.suite = self
	panel.add_child(fake)
	panel.request.connect(fake.on_request)

	await _click_propose_button()

	check("which routing path ran is reported", true,
		"real_worker=%s (binary at <minerva-plugins>/pcb/pcb-plugin)" % str(_used_real_worker))

	if not _used_real_worker:
		printerr("SKIP-NOTE: real pcb-plugin binary unavailable — DRC assertions below " +
			"require the real worker (the canned fallback carries no drc/drc_summary). " +
			"Verifying graceful degradation only.")
		# Checks the CHIPS, not the word "DRC": since the honest-label rename
		# (019f958aa6db) no status text contains "DRC" at all, so the old
		# spelling of this claim had become vacuously true. Both suffix
		# builders emit " — <Scope>…", so their absence is the real degrade.
		check("no-DRC degrade: status label carries neither DRC chip",
			not panel._status_label.text.contains("— Connectivity")
				and not panel._status_label.text.contains("— Geometric"),
			"got '%s'" % panel._status_label.text)
		panel.request.disconnect(fake.on_request)
		fake.queue_free()
		return

	# -- envelope-level drc_summary (deliverable 1/2) --------------------------
	var reply: Dictionary = await panel.handle_tool("minerva_pcb_apply_route_hints", {"commit": false})
	check("propose ok", bool(reply.get("success", false)), str(reply))
	var summary: Dictionary = reply.get("drc_summary", {})
	check("drc_summary present", not summary.is_empty(), str(reply))
	check("drc_summary.clean is false (SIG1 collides)", summary.get("clean", true) == false, str(summary))
	check("drc_summary.violation_count >= 1", int(summary.get("violation_count", 0)) >= 1, str(summary))

	# -- status label (deliverable 3) ------------------------------------------
	# THE LABEL IS "Connectivity:", NOT "DRC:" — and that is the shipped, correct
	# name, not a cosmetic drift to chase. PCBPanel._connectivity_status_suffix
	# reads drc_summary.scope (default "connectivity") and title-cases it
	# precisely so this chip cannot imply a generic "DRC clean" when what ran was
	# the connectivity/topology checker (pad centres + trace centrelines) and NOT
	# geometric copper DRC — the honest-label ruling 019f958aa6db, landed in
	# 32ff10a. The geometric half is a SEPARATE chip ("Geometric: N violations",
	# _geometric_status_suffix). This assertion was authored against the
	# pre-rename text and is updated to the shipped vocabulary; filed as
	# 019fc342a660.
	check("status label reports a CONNECTIVITY violation count (honest label 019f958aa6db)",
		panel._status_label.text.findn("Connectivity:") != -1
			and panel._status_label.text.findn("violation") != -1,
		"got '%s'" % panel._status_label.text)
	check("...and it does NOT use the misleading bare 'DRC:' prefix the rename removed",
		panel._status_label.text.findn("DRC:") == -1,
		"got '%s'" % panel._status_label.text)

	# -- per-candidate drc (deliverable 2, S5/C4b moved off the annotation) -----
	# S5 (C4b, DCR 019f7095c395): propose no longer writes an annotation, so
	# there is no kind_payload.drc to read anymore — it was only ever stamped
	# there by the now-retired _write_one_proposal. The per-route connectivity
	# verdict now lands directly on THIS reply's own proposals[] entries
	# (panel_tools.gd _propose_into_workspace, extended for parity with
	# drc_geometric below) — read it from there instead.
	var dirty_entry: Dictionary = {}
	var clean_entry: Dictionary = {}
	for p in (reply.get("proposals", []) as Array):
		if not (p is Dictionary):
			continue
		match str((p as Dictionary).get("net", "")):
			"SIG1":
				dirty_entry = p
			"SIG2":
				clean_entry = p

	check("SIG1 candidate exists in the reply", not dirty_entry.is_empty(), str(reply.get("proposals", [])))
	check("SIG2 candidate exists in the reply", not clean_entry.is_empty(), str(reply.get("proposals", [])))
	check("no proposal annotation was written by propose (S5)", host.get_annotations().size() == 2,
		"count=%d" % host.get_annotations().size())

	if not dirty_entry.is_empty():
		var dirty_drc: Dictionary = dirty_entry.get("drc", {})
		check("SIG1 candidate drc.clean == false", dirty_drc.get("clean", true) == false, str(dirty_drc))
		check("SIG1 candidate drc.violations non-empty",
			(dirty_drc.get("violations", []) as Array).size() >= 1, str(dirty_drc))

	if not clean_entry.is_empty():
		var clean_drc: Dictionary = clean_entry.get("drc", {})
		check("SIG2 candidate drc.clean == true", clean_drc.get("clean", false) == true, str(clean_drc))
		check("SIG2 candidate drc.violations empty",
			(clean_drc.get("violations", []) as Array).size() == 0, str(clean_drc))

	# Propose is fully resolved — drop the route-worker fake before any further
	# dispatch (test_pcb_explicit_propose.gd convention: never leave a stale
	# "_MinervaIPC" node/connection lying around for a later dispatch to trip
	# over — see _cleanup_stale_registry_dispatch below).
	panel.request.disconnect(fake.on_request)
	fake.queue_free()
	await process_frame

	# MF-1 (narrow re-review, 2026-08-02): the MCP annotations_list negative
	# proof that used to live here ("no annotation carries kind_payload.drc
	# post-S5") is DELETED, not just inverted — it was written when this whole
	# branch (after the _used_real_worker early-return above) was
	# STRUCTURALLY unreachable in any environment: two independent rig defects
	# (e2e_route_stdio.py swallowing the binary's host.notify line; the
	# serialized board failing worker compile on a None
	# design_rules.trace_width_mm because this suite's own fixture authored no
	# design_rules block) kept _used_real_worker false unconditionally. Both
	# are FIXED as of docket 019fc22284537bdfa9861c159bad76b1 ("Workerless e2e
	# rig defects") — see _build_fixture_board's design_rules block and
	# e2e_route_stdio.py's recv_id loop — so this branch now executes. The
	# deleted assertion is NOT reinstated here (that call stands on its own;
	# an assertion removed for being unreachable does not become owed just
	# because reachability was restored). The equivalent proof still lives in
	# pcb/tests/gd/test_workspace_tools.gd (group 10d, un-parked at the epoch-C
	# boundary), which drives propose through a fixture RouterShim rather than
	# this rig.

	# -- WorkflowAnnotationList dock badge (deliverable 4, S5 moved pin) --------
	# S5 (C4b): no proposal annotation exists to carry kind_payload.drc, so the
	# badge mechanism has nothing to render — the dock lists ONLY the two plain
	# source hints, and NEITHER carries a `drc` key (propose never touches
	# hints). Proves the negative rather than a badge on a row that no longer
	# exists.
	var wf_list := WorkflowAnnotationList.new()
	get_root().add_child(wf_list)
	wf_list.set_host(host)
	await process_frame

	var listing: Array = wf_list.get_listing()
	check("dock lists exactly the 2 open hints, no proposal row", listing.size() == 2,
		"got %d" % listing.size())

	# Recursive: rows moved inside a capped ScrollContainer (dock-size fix).
	var groups_node := wf_list.find_child("WorkflowGroups", true, false)
	check("WorkflowGroups node mounted", groups_node != null)
	if groups_node != null:
		var any_badge := false
		for child in groups_node.get_children():
			if child is HBoxContainer and (child as Control).find_child("DrcBadge", false, false) != null:
				any_badge = true
		check("no row anywhere carries a DRC badge (no annotation carries drc post-S5)", not any_badge)

	wf_list.queue_free()
	await process_frame

	# -- commit a VIOLATING candidate still works (informs, never blocks) ------
	# S5 (C4b): the retired minerva_pcb_proposal_accept is replaced by
	# minerva_pcb_workspace_commit(candidate_id) — same "informs, never blocks"
	# contract (commit() does not consult validation/findings at all, see
	# panel_tools.gd _workspace_commit's own doc), same payoff (a trace lands
	# despite the violation). panel_tool_registry_driver.build() attaches its
	# OWN real "_MinervaIPC" helper node to `panel` (test_pcb_explicit_propose.gd's
	# documented platform-gap finding, scenario C) — clean it up afterward so it
	# can't collide with anything else. The route-worker `fake` above is already
	# disconnected/freed by this point, so there is nothing else to preserve.
	if not dirty_entry.is_empty():
		var dirty_cid := str(dirty_entry.get("candidate_id", ""))
		check("dirty candidate_id present in the reply", not dirty_cid.is_empty())
		var traces_before: int = data.get_trace_count()
		var registry: PluginToolRegistry = REGISTRY_DRIVER.new().build(
			panel, PCB_PLUGIN_ID, EDITOR_NAME, ["minerva_pcb_workspace_commit"])
		check("commit-dispatch registry built", registry != null)
		if registry != null:
			var commit_result: Dictionary = await registry.handle_tool_call("minerva_pcb_workspace_commit", {
				"editor_name": EDITOR_NAME, "candidate_id": dirty_cid,
			})
			check("committing a violating candidate still succeeds (informs, never blocks)",
				bool(commit_result.get("success", false)), str(commit_result))
			check("a trace was added despite the violation",
				data.get_trace_count() > traces_before,
				"before=%d after=%d" % [traces_before, data.get_trace_count()])
		_cleanup_stale_registry_dispatch()
		await process_frame


## Mirrors test_pcb_explicit_propose.gd's helper of the same name: a
## panel_tool_registry_driver dispatch leaves a real "_MinervaIPC" node +
## panel.request connection behind (a platform gap, out of this round's
## fence) — clean both by hand so nothing later collides with it.
func _cleanup_stale_registry_dispatch() -> void:
	for conn in panel.request.get_connections():
		panel.request.disconnect(conn["callable"])
	for child in panel.get_children():
		if str(child.name).begins_with("_MinervaIPC"):
			panel.remove_child(child)
			child.queue_free()


# ── helpers ────────────────────────────────────────────────────────────────

func check(desc: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		if detail != "":
			printerr("  FAIL: %s — %s" % [desc, detail])
		else:
			printerr("  FAIL: %s" % desc)
