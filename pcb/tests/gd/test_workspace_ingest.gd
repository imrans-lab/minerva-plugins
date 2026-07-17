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
## Coverage (4 groups):
##   1. Ingest a fixture router reply (multi-pad net, >=2 DISCONNECTED paths +
##      a via) -> candidate geometry matches exactly; base_board_revision
##      captured; source_hint_ids set.
##   2. Idempotent replace: re-ingesting the SAME task supersedes the prior
##      candidate (generation+1, not duplicated); a DIFFERENT task adds a new,
##      independent candidate.
##   3. Empty/no-routes reply -> no candidates, no crash.
##   4. FUNCTIONAL FLOOR (non-mocked, dual-write): a REAL PCBPanel (booted via
##      plugin_panel_driver) driving the EXACT production dual-write seam
##      (panel_tools._dual_write_propose) with a fixture router reply, proving
##      BOTH the annotation host got a proposal AND the routing workspace got
##      a candidate from the SAME reply. See the group's header comment for
##      why this bypasses the router-worker subprocess specifically (out of
##      T2's fence — worker *.py).

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
func _multipad_reply() -> Dictionary:
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


# ── 4. functional floor: real PCBPanel, production dual-write seam ───────────

## Boots a REAL PCBPanel (not a fake/stand-in) via plugin_panel_driver, wires
## its real AnnotationHost -> panel back-reference the same way the mount flow
## (_on_panel_loaded/_build_ui) does — `host.set_panel(panel)` — WITHOUT
## running full UI mount (no Control tree / canvas needed for this seam), then
## drives panel_tools.gd's `_dual_write_propose` DIRECTLY with a fixture
## router reply. `_dual_write_propose` is the exact static function
## `_apply_route_hints` calls once it HAS a router reply (see panel_tools.gd
## ~911) — this test exercises that real production function, not a copy.
##
## Why not go through `_apply_route_hints`/`minerva_pcb_apply_route_hints`
## end-to-end instead? That path awaits `host.run_router` -> `panel.route_board`,
## which requires a live `_MinervaIPC` child node wired to a running pcb
## backend subprocess (PCBPanel.gd route_board ~1355) — only present when the
## panel is mounted inside a real Editor scene with the plugin broker running.
## That's headless-unreachable and, per this task's fence, the router worker
## (*.py) is explicitly OUT of scope. Driving `_dual_write_propose` directly
## with a fixture reply is the documented fallback: same handler seam
## production calls, fixture reply substituted only for the worker hop.
func _run_functional_floor_dual_write() -> void:
	print("-- 4. functional floor: real PCBPanel, production dual-write seam --")
	var driver = preload("res://test/helpers/plugin_panel_driver.gd").new()
	var panel = driver.load_panel(PCB_PANEL_SCRIPT_PATH)
	check("real PCBPanel instantiated", panel != null)
	if panel == null:
		return

	var host = panel.get_annotation_host()
	check("panel has a real AnnotationHost", host != null)
	# Mirrors the mount-time wiring (_on_panel_loaded -> _build_ui) without
	# building the full Control/canvas tree — this seam needs only the
	# host->panel back-reference so host.get_panel() (which _dual_write_propose
	# duck-types through) resolves.
	host.set_panel(panel)

	var pre_annotation_count: int = host.get_all_annotations().size()
	var pre_candidate_count: int = panel.get_routing_workspace().list_candidates().size()
	check_eq("workspace starts empty", pre_candidate_count, 0)

	var hints := _source_hints_n1()
	var out: Dictionary = PanelTools._dual_write_propose(host, _multipad_reply(), hints)

	check("_dual_write_propose reports success", bool(out.get("success", false)))
	check_eq("_dual_write_propose reports 1 proposal (annotation path unchanged)", int(out.get("proposed", 0)), 1)

	# Annotation host got a proposal (the SAME behavior _write_back_proposals
	# always had — this must NOT have changed).
	var proposals: Array = []
	for ann in host.get_all_annotations():
		if ann is Dictionary and str((ann as Dictionary).get("kind", "")) == "pcb_route_hint":
			var kp: Dictionary = (ann as Dictionary).get("kind_payload", {})
			if kp.get("proposal_for", []) == ["hint_1"]:
				proposals.append(ann)
	check_eq("annotation host got the proposal annotation", host.get_all_annotations().size(), pre_annotation_count + 1)
	check_eq("proposal links back to source hint_1", proposals.size(), 1)

	# Routing workspace got a candidate from the SAME reply, dual-write.
	var ws = panel.get_routing_workspace()
	check_eq("routing workspace got 1 candidate from the same reply", ws.list_candidates().size(), pre_candidate_count + 1)
	var cand = ws.list_candidates()[0]
	check_eq("shadow candidate net matches the reply", cand.net, "N1")
	check_eq("shadow candidate segment count matches the reply", cand.segments.size(), 3)
	check_eq("shadow candidate via count matches the reply", cand.vias.size(), 1)
	check_eq("shadow candidate base_board_revision == live board_revision",
		cand.base_board_revision, int(panel.get_data().board_revision))

	driver.free_panel(panel)
