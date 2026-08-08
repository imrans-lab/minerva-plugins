extends SceneTree
## Epoch UX3 station 12 (docket 019fdf920d5d): the K5 and K12 goal checks as
## CONTRACT tests — model-level, over the real workspace and board model.
##
## K5 — "draft state lives in the SIDECARS; the canonical file NEVER carries
## it except via promotion": author through rejected + frozen proposals and
## assert (a) the workspace sidecar holds every one of them, (b) the CANONICAL
## board dict (what pcb.serialize writes to the file) carries no candidate,
## proposal, or annotation key and no copper from any uncommitted candidate,
## (c) COMMIT — the promotion pipeline's input — is the only path that moves
## draft geometry into the canonical surface.
##
## K12 — "several findings, repair one, accept a subset — the remainder
## untouched": three candidates with stored findings; repair one through the
## guarded edit verb; commit a subset; assert the remainder's geometry and
## dispositions are byte-untouched (INV-2's verdict staling is the one
## sanctioned change — it is the contract, not a violation of it).
##
## Run (via a Minerva scaffold as the Godot host — NEVER the live checkout):
##   godot --headless --path <minerva-scaffold>/src \
##     --script res://../../minerva-plugins/pcb/tests/gd/test_ux3_contracts.gd

const PcbRouteCandidate := preload("res://../../minerva-plugins/pcb/ui/model/pcb_route_candidate.gd")
const PcbRoutingWorkspace := preload("res://../../minerva-plugins/pcb/ui/model/pcb_routing_workspace.gd")
const PcbDataScript := preload("res://../../minerva-plugins/pcb/ui/model/pcb_data.gd")

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== Epoch UX3 contract tests (K5 draft containment, K12 subset accept) ===\n")
	_run_k5_draft_containment()
	_run_k12_subset_accept()
	_run_fingerprint_v2()
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


func _hint(id: String, net: String) -> Dictionary:
	return {"id": id, "kind_payload": {"net_names": [net], "width_mm": 0.3}}


func _route(net: String, y: float) -> Dictionary:
	return {"routes": [{
		"net": net,
		"segments": [{"start": [0.0, y], "end": [8.0, y], "layer": "F.Cu"}],
		"vias": [],
	}]}


func _board():
	var data = PcbDataScript.new()
	data.from_board_dict({
		"version": 1, "name": "k5", "width_mm": 30.0, "height_mm": 30.0,
		"grid_mm": 2.54, "design_rules": {"clearance_mm": 0.2},
		"components": [], "nets": [{"name": "N1", "pins": []},
			{"name": "N2", "pins": []}, {"name": "N3", "pins": []}],
		"traces": [], "vias": [],
	})
	return data


# ── K5 ────────────────────────────────────────────────────────────────────────

func _run_k5_draft_containment() -> void:
	print("-- K5: rejected + frozen drafts live in the sidecar, never the canonical file --")
	var data = _board()
	var ws = PcbRoutingWorkspace.new()
	var a: String = str(ws.ingest_routing_result(_route("N1", 2.0), [_hint("h1", "N1")], 1)[0])
	var b: String = str(ws.ingest_routing_result(_route("N2", 6.0), [_hint("h2", "N2")], 1)[0])
	var c: String = str(ws.ingest_routing_result(_route("N3", 10.0), [_hint("h3", "N3")], 1)[0])
	check("reject one", ws.reject(a))
	check("freeze one", ws.freeze(b))
	# c stays proposed.

	# (a) the SIDECAR holds every draft, dispositions intact.
	var side: Dictionary = ws.to_sidecar_dict()
	var side_cands: Dictionary = side.get("candidates", {})
	check_eq("sidecar holds all three drafts", side_cands.size(), 3)
	check_eq("…the rejected one, as rejected",
		str((side_cands.get(a, {}) as Dictionary).get("disposition", "")), "rejected")
	check_eq("…the frozen one, as frozen",
		str((side_cands.get(b, {}) as Dictionary).get("disposition", "")), "frozen")
	check("…and the frozen id in the durable frozen set",
		(side.get("frozen", []) as Array).has(b))

	# (b) the CANONICAL board dict — pcb.serialize's exact input — carries NO
	# draft state and no draft copper. Key-set assertion, not just counts: a
	# future key smuggling proposals into the file must fail HERE by name.
	var canon: Dictionary = data.to_board_dict()
	for forbidden in ["candidates", "proposals", "route_hints", "annotations",
			"workspace", "frozen", "pinned"]:
		check("canonical dict carries no '%s' key" % forbidden, not canon.has(forbidden))
	check_eq("no uncommitted draft became copper (0 traces)",
		(canon.get("traces", []) as Array).size(), 0)

	# (c) COMMIT is the one door: committing the proposed draft lands exactly
	# its copper in the canonical dict; the rejected/frozen drafts still don't.
	var res: Dictionary = ws.commit(c, data)
	check("commit lands", bool(res.get("ok", false)))
	var canon2: Dictionary = data.to_board_dict()
	check_eq("exactly the committed candidate's copper is canonical now",
		(canon2.get("traces", []) as Array).size(), 1)
	check("the frozen draft is STILL not in the canonical dict",
		str((ws.get_candidate(b)).disposition) == "frozen"
		and (canon2.get("traces", []) as Array).size() == 1)


# ── K12 ───────────────────────────────────────────────────────────────────────

func _run_k12_subset_accept() -> void:
	print("-- K12: repair one, accept a subset, remainder untouched --")
	var data = _board()
	var ws = PcbRoutingWorkspace.new()
	var a: String = str(ws.ingest_routing_result(_route("N1", 2.0), [_hint("h1", "N1")], 1)[0])
	var b: String = str(ws.ingest_routing_result(_route("N2", 6.0), [_hint("h2", "N2")], 1)[0])
	var c: String = str(ws.ingest_routing_result(_route("N3", 10.0), [_hint("h3", "N3")], 1)[0])

	# Several findings, through the guarded reply path (one per candidate).
	ws.begin_check()
	var findings: Array = []
	for pair in [[a, 2.0], [b, 6.0], [c, 10.0]]:
		findings.append({"type": "gc2_copper_clearance",
			"measured_mm": 0.1, "required_mm": 0.2, "layer": "F.Cu",
			"closest": [4.0, float(pair[1])], "witness": [4.0, float(pair[1]) + 0.1],
			"subjects": [{"candidate_id": str(pair[0])}]})
	ws.apply_check_result({
		"board_token": ws.board_token,
		"workspace_generation": ws.workspace_generation(),
		"per_candidate": {a: "violating", b: "violating", c: "violating"},
		"findings": findings,
	})
	check_eq("three candidates carry findings",
		int(ws.findings_for_candidate(a).size() + ws.findings_for_candidate(b).size()
			+ ws.findings_for_candidate(c).size()), 3)

	# REPAIR ONE (a): the guarded edit verb — the same path the junction drag
	# and edit_candidate ride. The board did not move, so b/c verdicts stand.
	var a_geom_before: String = str((ws.get_candidate(a).segments[0] as Dictionary).get("points", []))
	var c_geom_before: String = str((ws.get_candidate(c).segments[0] as Dictionary).get("points", []))
	var mj: Dictionary = ws.move_junction(a, Vector2(8.0, 2.0), Vector2(8.0, 3.0))
	check("the repair verb lands on the one candidate", bool(mj.get("ok", false)))
	check_eq("…which is now stale (its own verdict must be re-earned)",
		str(ws.get_candidate(a).validation), "stale")
	check_eq("the un-repaired b keeps its verdict", str(ws.get_candidate(b).validation), "violating")
	check_eq("the un-repaired c keeps its verdict", str(ws.get_candidate(c).validation), "violating")

	# ACCEPT A SUBSET: commit b alone (batch form, one member).
	var batch: Dictionary = ws.commit_batch([b], data)
	check("subset commit lands", bool(batch.get("ok", false)))
	check_eq("…b is committed", str(ws.get_candidate(b).disposition), "committed")

	# REMAINDER UNTOUCHED: a and c keep their dispositions and their exact
	# geometry; INV-2's staling of live verdicts is the one sanctioned change.
	check_eq("a's disposition untouched", str(ws.get_candidate(a).disposition), "proposed")
	check_eq("c's disposition untouched", str(ws.get_candidate(c).disposition), "proposed")
	check_eq("c's geometry byte-untouched",
		str((ws.get_candidate(c).segments[0] as Dictionary).get("points", [])), c_geom_before)
	check("a's repaired geometry stands (the repair was not rolled back)",
		str((ws.get_candidate(a).segments[0] as Dictionary).get("points", [])) != a_geom_before)
	check_eq("c's verdict is stale (INV-2: the accepted subset changed the set)",
		str(ws.get_candidate(c).validation), "stale")
	# Codex 1056 finding 3a: the store's OWN contract (mark_stale's header)
	# is that staling DROPS stored findings — a finding names subject
	# identity, and a set change may have destroyed those subjects; keeping
	# them is exactly the "stale findings render against new geometry"
	# failure INV-2 exists to prevent. The worklist is re-earned by the next
	# Check, not carried. (The original oracle asserted survival — wrong.)
	check_eq("…and its stored findings were DROPPED with the verdict (re-earned on the next check)",
		ws.findings_for_candidate(c).size(), 0)
	check_eq("exactly one trace of copper landed (the subset, nothing else)",
		(data.to_board_dict().get("traces", []) as Array).size(), 1)


# ── F4 (station-11 cold review): fingerprint v2 round-trip stability ─────────
# The v1 fingerprint hashed the whole GD dict, so GD-only session keys
# (locked, colors, enrichment) fed it — and the first promotion's
# serialize→deserialize round trip, which drops every non-canonical key,
# orphaned the routing sidecar. v2 hashes the canonical-survivor projection.

const PcbRoutingSidecar := preload("res://../../minerva-plugins/pcb/ui/model/pcb_routing_sidecar.gd")

func _run_fingerprint_v2() -> void:
	print("-- F4: v2 fingerprint ignores GD-only keys, catches canonical moves, legacy compat --")
	var data = _board()
	var dict_a: Dictionary = data.to_board_dict()

	# A GD-only key difference (the round trip's exact effect) is INVISIBLE
	# to v2 — simulate by stripping a session-only key from a component-ful
	# board... the seeded board has no components, so assert on traces: add a
	# locked flag divergence.
	var dict_b: Dictionary = dict_a.duplicate(true)
	var comps: Array = dict_b.get("components", [])
	dict_b["components"] = comps  # (empty here; the trace case below carries the load)
	var t_a: Dictionary = {"id": "t1", "net": "N1", "layer": "top", "width_mm": 0.3,
		"points": [{"x_mm": 0.0, "y_mm": 0.0}, {"x_mm": 5.0, "y_mm": 0.0}], "locked": true}
	var t_b: Dictionary = t_a.duplicate(true)
	t_b.erase("locked")  # what the canonical round trip does to the entry
	var with_locked: Dictionary = dict_a.duplicate(true)
	with_locked["traces"] = [t_a]
	var without_locked: Dictionary = dict_a.duplicate(true)
	without_locked["traces"] = [t_b]
	check("v2: a GD-only key (locked) does NOT move the fingerprint",
		PcbRoutingSidecar.compute_board_fingerprint_v2(with_locked)
			== PcbRoutingSidecar.compute_board_fingerprint_v2(without_locked))
	check("v1 would have moved (the defect being fixed)",
		PcbRoutingSidecar.compute_board_fingerprint(with_locked)
			!= PcbRoutingSidecar.compute_board_fingerprint(without_locked))
	# A CANONICAL move still moves v2 — the guard keeps its teeth.
	var moved: Dictionary = with_locked.duplicate(true)
	(((moved["traces"] as Array)[0] as Dictionary)["points"] as Array)[1] = {"x_mm": 9.0, "y_mm": 0.0}
	check("v2: a canonical geometry change DOES move the fingerprint",
		PcbRoutingSidecar.compute_board_fingerprint_v2(with_locked)
			!= PcbRoutingSidecar.compute_board_fingerprint_v2(moved))

	# Codex 1056 finding 1: ZONES are routing-relevant since station 2 made
	# keepouts router obstacles — editing one MUST move the fingerprint (a
	# candidate routed around the old region is stale against the new one).
	var with_keepout: Dictionary = with_locked.duplicate(true)
	with_keepout["zones"] = [{"id": "z1", "kind": "keepout", "layer": "top",
		"outline": [{"x_mm": 1.0, "y_mm": 1.0}, {"x_mm": 4.0, "y_mm": 1.0},
			{"x_mm": 4.0, "y_mm": 4.0}]}]
	check("v2: adding a keepout zone moves the fingerprint",
		PcbRoutingSidecar.compute_board_fingerprint_v2(with_locked)
			!= PcbRoutingSidecar.compute_board_fingerprint_v2(with_keepout))
	var keepout_moved: Dictionary = with_keepout.duplicate(true)
	((((keepout_moved["zones"] as Array)[0] as Dictionary)["outline"] as Array)[2] as Dictionary)["x_mm"] = 8.0
	check("v2: EDITING a keepout's outline moves the fingerprint",
		PcbRoutingSidecar.compute_board_fingerprint_v2(with_keepout)
			!= PcbRoutingSidecar.compute_board_fingerprint_v2(keepout_moved))
	# Cutouts + board holes are physical keepouts — covered too.
	var with_cutout: Dictionary = with_locked.duplicate(true)
	with_cutout["cutouts"] = [{"id": "c1", "outline": [{"x_mm": 2.0, "y_mm": 2.0},
		{"x_mm": 3.0, "y_mm": 2.0}, {"x_mm": 3.0, "y_mm": 3.0}]}]
	check("v2: a cutout moves the fingerprint",
		PcbRoutingSidecar.compute_board_fingerprint_v2(with_locked)
			!= PcbRoutingSidecar.compute_board_fingerprint_v2(with_cutout))
	var with_pth: Dictionary = with_locked.duplicate(true)
	with_pth["pth_holes"] = [{"x_mm": 5.0, "y_mm": 5.0, "diameter_mm": 1.0, "drill_mm": 0.6}]
	check("v2: a PTH board hole moves the fingerprint (missing from v1 AND Codex's list)",
		PcbRoutingSidecar.compute_board_fingerprint_v2(with_locked)
			!= PcbRoutingSidecar.compute_board_fingerprint_v2(with_pth))
	# The deliberate EXCLUSIONS hold: grid_mm (snap UI) does not move it.
	var with_grid: Dictionary = with_locked.duplicate(true)
	with_grid["grid_mm"] = 1.27
	check("v2: grid_mm (snap UI, not a routing input) does NOT move the fingerprint",
		PcbRoutingSidecar.compute_board_fingerprint_v2(with_locked)
			== PcbRoutingSidecar.compute_board_fingerprint_v2(with_grid))

	# ── writer stamps v2; loader compares v2 ─────────────────────────────────
	var ws = PcbRoutingWorkspace.new()
	ws.ingest_routing_result(_route("N1", 2.0), [_hint("h1", "N1")], 1)
	var path := "user://ux3_fp_v2_probe.pcbskel"
	check("save lands", PcbRoutingSidecar.save_workspace(path, ws, with_locked, 1) == OK)
	var env: Dictionary = PcbRoutingSidecar.read_envelope(path)
	check_eq("the envelope is stamped fingerprint_version 2",
		int(env.get("fingerprint_version", 1)), 2)
	# Loading against the ROUND-TRIPPED dict (locked dropped) is CLEAN — the
	# post-promotion reload that used to quarantine.
	var loaded = PcbRoutingWorkspace.new()
	var status: Dictionary = PcbRoutingSidecar.load_into_workspace(path, loaded, without_locked, 1)
	check_eq("post-round-trip load is CLEAN under v2", str(status.get("status", "")), "loaded_clean")

	# ── legacy envelope (no fingerprint_version): compared with v1, still clean
	var legacy_env: Dictionary = env.duplicate(true)
	legacy_env.erase("fingerprint_version")
	legacy_env["board_fingerprint"] = PcbRoutingSidecar.compute_board_fingerprint(with_locked)
	check("legacy envelope written", PcbRoutingSidecar.write_envelope(path, legacy_env) == OK)
	var loaded2 = PcbRoutingWorkspace.new()
	var status2: Dictionary = PcbRoutingSidecar.load_into_workspace(path, loaded2, with_locked, 1)
	check_eq("a pre-v2 sidecar still loads clean against its own v1 hash",
		str(status2.get("status", "")), "loaded_clean")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PcbRoutingSidecar.sidecar_path_for(path)))
