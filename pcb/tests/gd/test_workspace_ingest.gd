extends SceneTree
## T2 (S2.2) — RoutingWorkspace SHADOW-phase ingest tests.
##
## Run (via a Minerva scaffold as the Godot host — NEVER the live checkout):
##   godot --headless --path <minerva-scaffold>/src \
##     --script res://../../minerva-plugins/pcb/tests/gd/test_workspace_ingest.gd
## The preloads resolve res:// against the scaffold's src/ root, so
## ../../minerva-plugins reaches this plugin checkout beside it (same
## convention as test_layer_stack.gd / test_routing_workspace_model.gd).
##
## Coverage (7 groups):
##   1. Ingest a fixture router reply (multi-pad net, >=2 DISCONNECTED paths +
##      a via) -> candidate geometry matches exactly; base_board_revision
##      captured; source_hint_ids set.
##   2. Idempotent replace: re-ingesting the SAME task supersedes the prior
##      candidate (generation+1, not duplicated); a DIFFERENT task adds a new,
##      independent candidate.
##   3. Empty/no-routes reply -> no candidates, no crash.
##   4. ingest_record: a hint that names its net ONLY through source_pins/
##      dest_pins (net_names empty), alongside another selected unrelated
##      hint, is attributed EXACTLY to itself — not the whole selected set,
##      not empty (docket 019fa109766f). Endpoints/width resolve from that
##      same hint too, not the 0.25mm/empty defaults.
##   5. ingest_record: a route the worker attributed to NO hint gets empty
##      provenance/endpoints/default width — distinguishing "legitimately
##      unattributed" from the fixed pins-only case above.
##   7. ingest_record: the width the WORKER routed at (segment `width_mm`)
##      sizes the candidate's copper, and its `effective_width_source` names
##      the provenance; the hint-only re-derivation and its 0.25mm default are
##      the fallback.
##   6. FUNCTIONAL FLOOR (non-mocked, S5 workspace-only): a REAL PCBPanel
##      (booted via plugin_panel_driver) driving the EXACT production propose
##      seam (panel_tools._propose_into_workspace) with a fixture router
##      reply, proving the routing workspace got a candidate from the reply
##      AND the annotation host got NOTHING (S5, C4b, DCR 019f7095c395 retired
##      the dual-write's annotation half — this suite's own name commemorates
##      the T2 shadow phase that _propose_into_workspace's landing path
##      outlived). See the group's header comment for why this bypasses the
##      router-worker subprocess specifically (out of T2's fence — worker
##      *.py).

const PcbRoutingWorkspace := preload("res://../../minerva-plugins/pcb/ui/model/pcb_routing_workspace.gd")
const PcbLayerStack := preload("res://../../minerva-plugins/pcb/ui/model/pcb_layer_stack.gd")
const PanelTools := preload("res://../../minerva-plugins/pcb/ui/panel_tools.gd")
const PCB_PANEL_SCRIPT_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== RoutingWorkspace Ingest (T2 shadow) Tests ===\n")
	_run_ingest_geometry()
	_run_idempotent_replace()
	_run_empty_reply()
	_run_ingest_record_pins_only_attribution()
	_run_ingest_record_unattributed_is_empty()
	_run_ingest_record_routed_width_wins()
	_run_functional_floor_dual_write()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


# ── assertion helpers ─────────────────────────────────────────────────────────

func check(desc: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s" % desc)


func check_eq(desc: String, actual, expected) -> void:
	check("%s (expected %s, got %s)" % [desc, str(expected), str(actual)], actual == expected)


# ── fixture builders ────────────────────────────────────────────────────────

## A router reply for a 3-pad net whose route is TWO disconnected physical
## groups: {seg_a, seg_b} joined by a layer-changing via, and seg_c standing
## alone with no shared endpoint anywhere (INV-3 trap — no chain assumed).
## `hint_ids`, when passed, mirrors the worker's own per-route attribution
## stamp (docket 019f9c3a136c) — group 6 below drives this through
## panel_tools._propose_into_workspace, which reads that stamp verbatim rather
## than re-deriving it, so a caller simulating "a hint was supplied" must set
## it or the candidate will (correctly) come back unattributed. Groups 1-3 feed
## this straight to PcbRoutingWorkspace.ingest_routing_result, which does its
## own independent net-name resolution and ignores this key entirely.
func _multipad_reply(hint_ids: Array = []) -> Dictionary:
	return {
		"routes": [
			{
				"net": "N1",
				"segments": [
					{"start": [0.0, 0.0], "end": [5.0, 0.0], "layer": "F.Cu"},
					{"start": [5.0, 0.0], "end": [5.0, 5.0], "layer": "B.Cu"},
					{"start": [50.0, 50.0], "end": [60.0, 50.0], "layer": "F.Cu"},
				],
				"vias": [[5.0, 0.0]],
				"hint_ids": hint_ids,
			}
		],
		"via_count": 1,
	}


func _source_hints_n1() -> Array:
	return [
		{
			"id": "hint_1",
			"kind_payload": {
				"net_names": ["N1"],
				"width_mm": 0.3,
				"source_pins": ["U1.3"],
				"dest_pins": ["U2.7"],
			},
		},
	]


# ── 1. ingest geometry matches exactly ────────────────────────────────────────

func _run_ingest_geometry() -> void:
	print("-- 1. ingest fixture reply: exact geometry, revision, provenance --")
	var ws = PcbRoutingWorkspace.new()
	var ids := ws.ingest_routing_result(_multipad_reply(), _source_hints_n1(), 42)
	check_eq("one route -> one candidate", ids.size(), 1)

	var cand = ws.get_candidate(str(ids[0]))
	check("candidate resolves", cand != null)
	check_eq("candidate net", cand.net, "N1")
	check_eq("candidate segment count == 3 (exact, not merged)", cand.segments.size(), 3)
	check_eq("seg 0 layer canonical (F.Cu -> top)", str(cand.segments[0].get("layer", "")), "top")
	check_eq("seg 1 layer canonical (B.Cu -> bottom)", str(cand.segments[1].get("layer", "")), "bottom")
	check_eq("seg 2 layer canonical (F.Cu -> top)", str(cand.segments[2].get("layer", "")), "top")
	# Disconnection preserved: seg 2's start does not touch seg 0/1 endpoints.
	var seg2_start: Vector2 = cand.segments[2].get("points")[0]
	check("seg 2 disconnected from seg 0/1 (INV-3, no chain assumed)",
		seg2_start != cand.segments[0].get("points")[1] and seg2_start != cand.segments[1].get("points")[1])
	# Every segment got its own stable id (workspace-minted, non-empty, unique).
	var seg_ids := {}
	for seg in cand.segments:
		var sid := str(seg.get("id", ""))
		check("segment id non-empty", not sid.is_empty())
		check("segment id unique", not seg_ids.has(sid))
		seg_ids[sid] = true

	check_eq("candidate via count == 1", cand.vias.size(), 1)
	var via = cand.vias[0]
	check_eq("via position", via.get("position"), Vector2(5.0, 0.0))
	check_eq("via from_layer via T1.5 contract", str(via.get("from_layer", "")), "top")
	check_eq("via to_layer via T1.5 contract", str(via.get("to_layer", "")), "bottom")
	check("via span legal via PcbLayerStack", PcbLayerStack.is_legal_via_span(via.get("from_layer"), via.get("to_layer")))

	check_eq("base_board_revision captured", cand.base_board_revision, 42)
	check_eq("source_hint_ids set", cand.source_hint_ids.size(), 1)
	check_eq("source_hint_ids[0]", str(cand.source_hint_ids[0]), "hint_1")
	check_eq("generation starts at 1", cand.generation, 1)
	check_eq("disposition starts proposed", cand.disposition, "proposed")


# ── 2. idempotent replace ─────────────────────────────────────────────────────

func _run_idempotent_replace() -> void:
	print("-- 2. idempotent replace: same task supersedes, different task adds --")
	var ws = PcbRoutingWorkspace.new()
	var hints := _source_hints_n1()

	var ids1 := ws.ingest_routing_result(_multipad_reply(), hints, 10)
	check_eq("first ingest -> 1 candidate", ids1.size(), 1)
	var cand1_id := str(ids1[0])
	var task_key: String = str(ws.get_candidate(cand1_id).task_id)

	# Re-propose the SAME task (same net + same source_hint_ids) with a
	# slightly different route (simulates the router finding a new path).
	var reply2 := {
		"routes": [
			{
				"net": "N1",
				"segments": [
					{"start": [0.0, 0.0], "end": [2.0, 0.0], "layer": "F.Cu"},
				],
				"vias": [],
			}
		],
	}
	var ids2 := ws.ingest_routing_result(reply2, hints, 11)
	check_eq("re-ingest same task -> 1 NEW candidate id (not appended to old)", ids2.size(), 1)
	var cand2_id := str(ids2[0])
	check("re-ingest mints a DIFFERENT candidate id", cand2_id != cand1_id)
	check_eq("re-ingest lands on the SAME task_id", ws.get_candidate(cand2_id).task_id, task_key)

	check_eq("old candidate superseded (not duplicated)", ws.get_candidate(cand1_id).disposition, "superseded")
	check_eq("new candidate generation bumped", ws.get_candidate(cand2_id).generation, 2)
	check_eq("new candidate disposition proposed", ws.get_candidate(cand2_id).disposition, "proposed")
	check_eq("candidate count for that task stays 1 (non-superseded)", ws.candidates_for_task(task_key).size(), 1)
	check_eq("total candidates in workspace == 2 (audit trail kept)", ws.list_candidates().size(), 2)

	# A THIRD ingest for a genuinely DIFFERENT task (different net) adds a new,
	# independent candidate — the N1 task's bookkeeping is untouched.
	var reply3 := {
		"routes": [
			{
				"net": "N2",
				"segments": [
					{"start": [0.0, 0.0], "end": [1.0, 0.0], "layer": "F.Cu"},
				],
				"vias": [],
			}
		],
	}
	var ids3 := ws.ingest_routing_result(reply3, hints, 12)
	check_eq("different net -> 1 new candidate", ids3.size(), 1)
	var cand3_id := str(ids3[0])
	check("different-task candidate id is distinct", cand3_id != cand1_id and cand3_id != cand2_id)
	check("different-task candidate has a distinct task_id", ws.get_candidate(cand3_id).task_id != task_key)
	check_eq("N1 task still has exactly 1 live candidate", ws.candidates_for_task(task_key).size(), 1)
	check_eq("total candidates now 3", ws.list_candidates().size(), 3)


# ── 3. empty / no-routes reply ────────────────────────────────────────────────

func _run_empty_reply() -> void:
	print("-- 3. empty/no-routes reply -> no candidates, no crash --")
	var ws = PcbRoutingWorkspace.new()

	var ids_a := ws.ingest_routing_result({}, [], 0)
	check_eq("missing 'routes' key -> no ids", ids_a.size(), 0)
	check_eq("missing 'routes' key -> no candidates", ws.list_candidates().size(), 0)

	var ids_b := ws.ingest_routing_result({"routes": []}, _source_hints_n1(), 5)
	check_eq("empty 'routes' array -> no ids", ids_b.size(), 0)
	check_eq("empty 'routes' array -> no candidates", ws.list_candidates().size(), 0)


# ── 4. ingest_record: pins-only hint attribution (docket 019fa109766f) ───────

## The discriminating fixture the docket asked for: hint_pins names its net
## ONLY through source_pins/dest_pins — net_names is EMPTY, so the legacy
## net-name matcher (_hints_matching_net) would never find it. hint_other is
## a second, SELECTED-but-unrelated hint (a different net, non-empty
## net_names) so "everything" (the old blanket fallback) and "just
## hint_pins" (the fix) are distinguishable outcomes, not both merely
## non-empty. `record.source_hint_ids` mirrors exactly what
## panel_tools._normalize_route_records/_route_hint_ids stamps from the
## worker's real per-route `hint_ids` — the CORRECT attribution ingest_record
## must use verbatim.
func _run_ingest_record_pins_only_attribution() -> void:
	print("-- 4. ingest_record: pins-only hint gets exactly its own attribution --")
	var ws = PcbRoutingWorkspace.new()

	var hint_pins := {
		"id": "hint_pins",
		"kind_payload": {
			"net_names": [], "width_mm": 0.4,
			"source_pins": ["U3.1"], "dest_pins": ["U4.2"],
		},
	}
	var hint_other := {
		"id": "hint_other",
		"kind_payload": {
			"net_names": ["N9"], "width_mm": 0.9,
			"source_pins": ["U9.1"], "dest_pins": ["U9.2"],
		},
	}
	var record := {
		"net": "N3",
		"segments": [{"start": [0.0, 0.0], "end": [3.0, 0.0], "layer": "F.Cu"}],
		"vias": [],
		"source_hint_ids": ["hint_pins"],
		"source_hints": [hint_pins, hint_other],
	}

	var cand_id := str(ws.ingest_record(record, 9))
	check("ingest_record returns a candidate id", not cand_id.is_empty())
	var cand = ws.get_candidate(cand_id)
	check("candidate resolves", cand != null)
	if cand == null:
		return

	check_eq("source_hint_ids carries EXACTLY the pins-only hint (not all selected, not empty)",
		cand.source_hint_ids.size(), 1)
	check_eq("source_hint_ids[0] is hint_pins", str(cand.source_hint_ids[0]), "hint_pins")

	check_eq("endpoints resolved from the pins-only hint (not empty)", cand.endpoints.size(), 2)
	check_eq("endpoint 0 is source pin U3.1", cand.endpoints[0], {"component": "U3", "pin": "1"})
	check_eq("endpoint 1 is dest pin U4.2", cand.endpoints[1], {"component": "U4", "pin": "2"})

	check_eq("width is the pins-only hint's authored 0.4mm (not default 0.25, not hint_other's 0.9)",
		float(cand.segments[0].get("width")), 0.4)

	check_eq("task_key uses exactly the pins-only hint id", cand.task_id, "N3|hint_pins")


## Companion case: a route the worker attributed to NO hint at all must yield
## EMPTY provenance/endpoints/default width — never "every selected hint" (the
## bug) and never a symptom of a lazy fix either (this is a genuinely
## different, legitimately-unattributed scenario from the pins-only case
## above, not the same fixture).
func _run_ingest_record_unattributed_is_empty() -> void:
	print("-- 5. ingest_record: unattributed route -> empty provenance, not everything --")
	var ws = PcbRoutingWorkspace.new()
	var hint_other := {
		"id": "hint_other",
		"kind_payload": {
			"net_names": ["N9"], "width_mm": 0.9,
			"source_pins": ["U9.1"], "dest_pins": ["U9.2"],
		},
	}
	var record := {
		"net": "N4",
		"segments": [{"start": [0.0, 0.0], "end": [1.0, 0.0], "layer": "F.Cu"}],
		"vias": [],
		"source_hint_ids": [],
		"source_hints": [hint_other],
	}
	var cand_id := str(ws.ingest_record(record, 1))
	var cand = ws.get_candidate(cand_id)
	check("candidate resolves", cand != null)
	if cand == null:
		return
	check_eq("unattributed route -> EMPTY source_hint_ids (never the whole selected set)",
		cand.source_hint_ids.size(), 0)
	check_eq("unattributed route -> empty endpoints (no false attribution)", cand.endpoints.size(), 0)
	# 01a02c480d50: the 0.25mm this used to assert was INVENTED — no hint, no
	# routed width, no caller option supplied one. The candidate still lands
	# (a ghost is a question, not a board edit); it lands at 0.0, says
	# "unresolved", and commit refuses it by name rather than fabricating
	# copper at a width nobody chose.
	check_eq("unattributed route -> width 0.0, never an invented 0.25mm",
		float(cand.segments[0].get("width")), 0.0)
	check_eq("and the candidate SAYS the width is unresolved",
		str(cand.width_source), "unresolved")
	check_eq("task_key has an empty hint-id half", cand.task_id, "N4|")


# ── 6. functional floor: real PCBPanel, production propose seam (S5) ─────────

## Boots a REAL PCBPanel (not a fake/stand-in) via plugin_panel_driver, wires
## its real AnnotationHost -> panel back-reference the same way the mount flow
## (_on_panel_loaded/_build_ui) does — `host.set_panel(panel)` — WITHOUT
## running full UI mount (no Control tree / canvas needed for this seam), then
## drives panel_tools.gd's `_propose_into_workspace` DIRECTLY with a fixture
## router reply. `_propose_into_workspace` is the exact static function
## `_apply_route_hints` calls once it HAS a router reply — this test exercises
## that real production function, not a copy.
##
## S5 UPDATE (C4b, DCR 019f7095c395): this group used to be the T2 shadow-
## phase's "functional floor: production DUAL-WRITE seam" — proving ONE
## propose call updated BOTH the annotation host (a proposal) AND the routing
## workspace (a candidate). S5 retired the annotation half
## (_write_back_proposals/_dual_write_propose are gone); the workspace is the
## SOLE propose store now. This group now proves the opposite floor: propose
## updates the workspace ONLY, and writes NO annotation — the shadow-phase
## dual-write invariant this suite's name commemorates is exactly what got
## retired.
##
## Why not go through `_apply_route_hints`/`minerva_pcb_apply_route_hints`
## end-to-end instead? That path awaits `host.run_router` -> `panel.route_board`,
## which requires a live `_MinervaIPC` child node wired to a running pcb
## backend subprocess (PCBPanel.gd route_board ~1355) — only present when the
## panel is mounted inside a real Editor scene with the plugin broker running.
## That's headless-unreachable and, per this task's fence, the router worker
## (*.py) is explicitly OUT of scope. Driving `_propose_into_workspace` directly
## with a fixture reply is the documented fallback: same handler seam
## production calls, fixture reply substituted only for the worker hop.
func _run_functional_floor_dual_write() -> void:
	print("-- 6. functional floor: real PCBPanel, production propose seam (S5: workspace-only) --")
	var driver = preload("res://test/helpers/plugin_panel_driver.gd").new()
	var panel = driver.load_panel(PCB_PANEL_SCRIPT_PATH)
	check("real PCBPanel instantiated", panel != null)
	if panel == null:
		return

	var host = panel.get_annotation_host()
	check("panel has a real AnnotationHost", host != null)
	# Mirrors the mount-time wiring (_on_panel_loaded -> _build_ui) without
	# building the full Control/canvas tree — this seam needs only the
	# host->panel back-reference so host.get_panel() (which
	# _propose_into_workspace duck-types through) resolves.
	host.set_panel(panel)

	var pre_annotation_count: int = host.get_all_annotations().size()
	var pre_candidate_count: int = panel.get_routing_workspace().list_candidates().size()
	check_eq("workspace starts empty", pre_candidate_count, 0)

	var hints := _source_hints_n1()
	var out: Dictionary = PanelTools._propose_into_workspace(
		host, panel.get_data(), _multipad_reply(["hint_1"]), hints)

	check("_propose_into_workspace reports success", bool(out.get("success", false)))
	check_eq("_propose_into_workspace reports 1 candidate landed", int(out.get("proposed", 0)), 1)

	# S5: the annotation host is UNCHANGED — no proposal annotation is written.
	check_eq("annotation host UNCHANGED — no proposal annotation written",
		host.get_all_annotations().size(), pre_annotation_count)
	var proposals: Array = []
	for ann in host.get_all_annotations():
		if ann is Dictionary and str((ann as Dictionary).get("kind", "")) == "pcb_route_hint":
			var kp: Dictionary = (ann as Dictionary).get("kind_payload", {})
			if kp.has("proposal_for"):
				proposals.append(ann)
	check_eq("nothing on the host carries proposal_for", proposals.size(), 0)

	# Routing workspace got the candidate — the SOLE store propose writes now.
	var ws = panel.get_routing_workspace()
	check_eq("routing workspace got 1 candidate from the reply", ws.list_candidates().size(), pre_candidate_count + 1)
	var cand = ws.list_candidates()[0]
	check_eq("candidate net matches the reply", cand.net, "N1")
	check_eq("candidate segment count matches the reply", cand.segments.size(), 3)
	check_eq("candidate via count matches the reply", cand.vias.size(), 1)
	check_eq("candidate base_board_revision == live board_revision",
		cand.base_board_revision, int(panel.get_data().board_revision))
	check_eq("candidate source_hint_ids == [hint_1]", cand.source_hint_ids, ["hint_1"])

	driver.free_panel(panel)


# ── 7. the routed width is the candidate's width ─────────────────────────────

## The worker resolves the whole width precedence chain (caller option, hint,
## class minimum, the net's own copper, the board default) and stamps the answer
## on every segment as `width_mm`, plus its provenance as
## `effective_width_source`. The candidate's width is the copper that gets
## committed, so it must be that stamped width and not a re-derivation from the
## selected HINTS alone.
##
## The fixture states three DIFFERENT numbers, so a wrong answer identifies
## which path produced it: 0.8 is the routed width, 0.4 is what the selected
## hint gives, 0.25 is the hint derivation's own default.
func _run_ingest_record_routed_width_wins() -> void:
	print("-- 7. ingest_record: the ROUTER's width sizes the candidate --")
	var ws = PcbRoutingWorkspace.new()

	var hint := {
		"id": "hint_w",
		"kind_payload": {
			"net_names": ["VIN"], "width_mm": 0.4,
			"source_pins": ["U1.1"], "dest_pins": ["U4.2"],
		},
	}
	# Exactly the shape panel_tools._normalize_route_records produces from a
	# worker reply whose route carried effective_routing_rules: raw router
	# segments stamped with the routed width_mm, plus the once-resolved effective
	# width/source.
	var record := {
		"net": "VIN",
		"segments": [
			{"start": [0.0, 0.0], "end": [3.0, 0.0], "layer": "F.Cu", "width_mm": 0.8},
			{"start": [3.0, 0.0], "end": [3.0, 4.0], "layer": "F.Cu", "width_mm": 0.8},
		],
		"vias": [],
		"source_hint_ids": ["hint_w"],
		"source_hints": [hint],
		"width": 0.8,
		"effective_width_mm": 0.8,
		"effective_width_source": "net_copper",
	}

	var cand = ws.get_candidate(str(ws.ingest_record(record, 4)))
	check("candidate resolves", cand != null)
	if cand == null:
		return
	check_eq("segment 0 is the ROUTED 0.8mm (not the hint's 0.4, not the 0.25 default)",
		float(cand.segments[0].get("width")), 0.8)
	check_eq("segment 1 is the ROUTED 0.8mm too",
		float(cand.segments[1].get("width")), 0.8)
	check_eq("width_source names the net's own copper, not the ingest verdict",
		str(cand.width_source), "net_copper")

	# A caller that resolved its OWN exact per-trace width (bus propose)
	# outranks the routed stamp.
	var bus_record: Dictionary = record.duplicate(true)
	bus_record["net"] = "VBUS"
	bus_record["width_override"] = 0.6
	bus_record.erase("effective_width_source")
	var bus_cand = ws.get_candidate(str(ws.ingest_record(bus_record, 4)))
	check("bus candidate resolves", bus_cand != null)
	if bus_cand == null:
		return
	check_eq("an explicit width_override still wins over the routed stamp",
		float(bus_cand.segments[0].get("width")), 0.6)
	check_eq("...and reports itself as the caller's own width",
		str(bus_cand.width_source), "caller_option")
