extends SceneTree
## Geometric copper DRC reaches the user (docket 019f98b24284). A prior round
## (commit 24164ad) made the worker's `route` reply carry, per route,
## `drc_geometric` = {scope, verifies_geometry, verdict, violations} and, at the
## payload level, `drc_geometric_summary` = the candidate union (findings +
## per-candidate verdicts keyed route[<i>] + a SEPARATE `baseline` holding the
## board's own pre-existing violations). That data reached the wire and then
## was dropped on the floor at TWO layers:
##   1. panel_tools.gd _write_records_as_proposals forwarded ONLY drc_summary
##      (connectivity) — drc_geometric_summary never reached the panel, and the
##      per-proposal entries carried no geometric verdict either.
##   2. PCBPanel.gd _drc_status_suffix read ONLY drc_summary.
## This suite locks both layers so a proposal that shorts a different-net pad
## (invisible to the connectivity/centerline checker — bug 019f80b5124d) can no
## longer be accepted without the user being told.
##
## Run (via a Minerva scaffold as the Godot host — NEVER the live checkout):
##   godot --headless --path <minerva-scaffold>/src \
##     --script res://../../minerva-plugins/pcb/tests/gd/test_geometric_drc_surface.gd
##
## Testing-seam decision: the rendering logic (_drc_status_suffix and friends)
## was a private INSTANCE method on PCBPanel, which a headless test cannot
## construct cheaply just to exercise pure string formatting. It read no `self`
## state (only its `result: Dictionary` argument), so it is converted to
## `static func` (see PCBPanel.gd) — tests 1-6 below drive it with plain
## dictionaries, no panel/host needed. panel_tools.gd's _normalize_route_records
## is likewise already static/pure (tests 7-8). Only test 9 needs a REAL host
## (plugin_panel_driver, same pattern as test_parity_bridge.gd) because
## _write_records_as_proposals authors real annotations via host.call(...); that
## one test proves the two pure pieces are actually wired together end to end.
##
## Coverage:
##   1. clean geometric verdict renders "Geometric clean"
##   2. "violations" renders with a violation count
##   3. "indeterminate" renders as NEITHER clean NOR a violation count
##   4. an absent/empty drc_geometric_summary renders "" (a THIRD state from
##      indeterminate — no invented verdict)
##   5. both scopes present render as two distinguishable, non-blended
##      substrings
##   6. a baseline-only violation (candidate verdict "clean") still renders
##      clean — the board's own pre-existing dirt must not dirty a clean
##      proposal
##   7. panel_tools._normalize_route_records copies route.drc_geometric onto
##      its record
##   8. a route with no drc_geometric key (older worker) leaves the record
##      without one — absent-key contract, not an invented default
##   9. propose's reply carries drc_geometric_summary AND each proposal entry
##      carries its OWN drc_geometric verdict (specific-candidate attribution,
##      not just "something in the batch is dirty"). S5 (C4b, DCR
##      019f7095c395): drives panel_tools.gd _propose_into_workspace (lands a
##      workspace candidate) rather than the retired _dual_write_propose
##      (which also wrote a proposal annotation) — the reply SHAPE this test
##      pins is unchanged either way.

const PanelTools := preload("res://../../minerva-plugins/pcb/ui/panel_tools.gd")
const PCBPanel := preload("res://../../minerva-plugins/pcb/ui/PCBPanel.gd")
const PCB_PANEL_SCRIPT_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== Geometric copper DRC surface (019f98b24284) ===\n")
	_run_render_clean()
	_run_render_violations()
	_run_render_indeterminate()
	_run_render_absent()
	_run_render_both_scopes_distinguishable()
	_run_render_baseline_only_stays_clean()
	_run_normalize_copies_drc_geometric()
	_run_normalize_absent_key_contract()
	_run_dual_write_propose_attribution()
	_run_render_names_the_offending_net()
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


# ── fixtures: shapes matching ir_candidates.check_candidates / methods.py ─────

## Case (a) from ir_candidates.py's module docstring: ran, candidates clean.
func _geom_summary_clean() -> Dictionary:
	return {"ok": true, "scope": "geometric_candidate", "verifies_geometry": true,
		"verdict": "clean", "findings": [], "counts": {},
		"per_candidate": {"route[0]": {"revision": null, "verdict": "clean", "finding_count": 0}},
		"baseline": {"verdict": "clean", "findings": [], "counts": {}}}


## Case (b): ran, candidates violate — 2 introduced findings attributed to route[0].
func _geom_summary_violations() -> Dictionary:
	return {"ok": true, "scope": "geometric_candidate", "verifies_geometry": true,
		"verdict": "violations",
		"findings": [
			{"type": "clearance", "subjects": [{"candidate_id": "route[0]", "segment_id": "segment:0"}]},
			{"type": "clearance", "subjects": [{"candidate_id": "route[0]", "segment_id": "segment:1"}]},
		],
		"counts": {"clearance": 2},
		"per_candidate": {"route[0]": {"revision": null, "verdict": "violations", "finding_count": 2}},
		"baseline": {"verdict": "clean", "findings": [], "counts": {}}}


## Case (c): could NOT run at all — carries no findings/counts/per_candidate,
## exactly as ir_candidates.candidate_indeterminate produces (module docstring:
## "Case (c) carries NO findings/counts/per_candidate — nothing a caller could
## misread as an attributed clean").
func _geom_summary_indeterminate() -> Dictionary:
	return {"ok": false, "scope": "geometric_candidate", "verdict": "indeterminate",
		"error": {"kind": "unsupported_geometry", "message": "fixture", "diagnostics": []}}


## A candidate that is itself clean, but the BOARD (baseline) carries 12
## pre-existing violations — the exact count the docket cites for the real
## fixture board. The candidate-scoped verdict must still read "clean":
## baseline is reported SEPARATELY (ir_candidates.check_candidates) and must
## never fold into the proposal's own verdict.
func _geom_summary_baseline_only() -> Dictionary:
	var baseline_findings: Array = []
	for i in range(12):
		baseline_findings.append({"type": "clearance", "subjects": []})
	return {"ok": true, "scope": "geometric_candidate", "verifies_geometry": true,
		"verdict": "clean", "findings": [], "counts": {},
		"per_candidate": {"route[0]": {"revision": null, "verdict": "clean", "finding_count": 0}},
		"baseline": {"verdict": "violations", "findings": baseline_findings,
			"counts": {"clearance": 12}}}


# ── 1-6: rendering (pure static funcs, plain dicts, no panel/host) ────────────

func _run_render_clean() -> void:
	print("-- 1. clean geometric verdict renders clean --")
	var s := PCBPanel._geometric_status_suffix({"drc_geometric_summary": _geom_summary_clean()})
	check_eq("clean renders exact label", s, " — Geometric clean")


func _run_render_violations() -> void:
	print("-- 2. violations verdict renders with a count --")
	var s := PCBPanel._geometric_status_suffix({"drc_geometric_summary": _geom_summary_violations()})
	check_eq("violations renders exact count", s, " — Geometric: 2 violations")


func _run_render_indeterminate() -> void:
	print("-- 3. indeterminate renders as NEITHER clean NOR a violation count --")
	var s := PCBPanel._geometric_status_suffix({"drc_geometric_summary": _geom_summary_indeterminate()})
	# The REASON rides along: "unavailable" alone is unactionable, and error.kind
	# is a small stable vocabulary (parse | compile | unresolved_geometry |
	# unsupported_geometry | route | internal). The free-text message is
	# deliberately NOT surfaced — it can be an exception repr.
	check_eq("indeterminate renders the fail-closed label WITH its reason", s,
		" — Geometric: unavailable (unsupported_geometry)")
	check("indeterminate string does not contain 'clean'", not s.contains("clean"))
	check("indeterminate string does not contain 'violation'", not s.contains("violation"))
	check("indeterminate string does not leak the free-text message",
		not s.contains("fixture"))
	# A union with no error dict at all must still render, without an empty "()".
	var bare := PCBPanel._geometric_status_suffix({"drc_geometric_summary":
		{"ok": false, "scope": "geometric_candidate", "verdict": "indeterminate"}})
	check_eq("indeterminate without an error dict degrades cleanly", bare,
		" — Geometric: unavailable")


func _run_render_absent() -> void:
	print("-- 4. absent drc_geometric_summary renders nothing (no invented verdict) --")
	var s := PCBPanel._geometric_status_suffix({})
	check_eq("missing key renders empty string", s, "")
	var s2 := PCBPanel._geometric_status_suffix({"drc_geometric_summary": {}})
	check_eq("explicit empty dict also renders empty string", s2, "")


func _run_render_both_scopes_distinguishable() -> void:
	print("-- 5. both scopes present render as two distinguishable substrings --")
	var result := {
		"drc_summary": {"scope": "connectivity", "clean": true},
		"drc_geometric_summary": _geom_summary_violations(),
	}
	var s := PCBPanel._drc_status_suffix(result)
	check("carries the connectivity fragment", s.contains("Connectivity clean"))
	check("carries the geometric fragment", s.contains("Geometric: 2 violations"))
	# Not blended: each scope keeps its own " — " lead-in rather than being
	# folded into one combined phrase.
	check_eq("exactly two ' — ' separators (one per scope)", s.count(" — "), 2)


func _run_render_baseline_only_stays_clean() -> void:
	print("-- 6. a baseline-only violation does NOT mark the proposal dirty --")
	var s := PCBPanel._geometric_status_suffix({"drc_geometric_summary": _geom_summary_baseline_only()})
	check_eq("candidate-scoped verdict still reads clean despite 12 baseline violations", s, " — Geometric clean")


# ── 7-8: panel_tools.gd normalization (pure — _normalize_route_records takes no host) ─

func _run_normalize_copies_drc_geometric() -> void:
	print("-- 7. _normalize_route_records copies route.drc_geometric onto the record --")
	var geom := {"scope": "geometric_candidate", "verifies_geometry": true,
		"verdict": "violations", "violations": []}
	var result := {"routes": [{"net": "N1",
		"segments": [{"start": [0.0, 0.0], "end": [5.0, 0.0], "layer": "F.Cu"}],
		"vias": [], "drc_geometric": geom}]}
	var records: Array = PanelTools._normalize_route_records(result, [])
	check_eq("one record produced", records.size(), 1)
	var rec: Dictionary = records[0]
	check_eq("record carries the route's drc_geometric verdict",
		str((rec.get("drc_geometric", {}) as Dictionary).get("verdict", "")), "violations")


func _run_normalize_absent_key_contract() -> void:
	print("-- 8. a route with no drc_geometric key leaves the record without one --")
	var result := {"routes": [{"net": "N1",
		"segments": [{"start": [0.0, 0.0], "end": [5.0, 0.0], "layer": "F.Cu"}], "vias": []}]}
	var records: Array = PanelTools._normalize_route_records(result, [])
	check("older-worker-shaped route leaves no drc_geometric key on the record",
		not (records[0] as Dictionary).has("drc_geometric"))


# ── 9: end-to-end dual-write propose (real host, mirrors test_parity_bridge.gd) ─

func _run_dual_write_propose_attribution() -> void:
	print("-- 9. propose (S5): reply + candidate entry both carry the geometric verdict --")
	var driver = preload("res://test/helpers/plugin_panel_driver.gd").new()
	var panel = driver.load_panel(PCB_PANEL_SCRIPT_PATH)
	var host = panel.get_annotation_host()
	host.set_panel(panel)
	var data = panel.get_data()

	var geom_route := {"scope": "geometric_candidate", "verifies_geometry": true,
		"verdict": "violations", "violations": [{"type": "clearance"}]}
	var reply := {
		"routes": [{
			"net": "N1",
			"segments": [{"start": [0.0, 0.0], "end": [5.0, 0.0], "layer": "F.Cu"}],
			"vias": [],
			"drc_geometric": geom_route,
		}],
		"via_count": 0,
		"drc_geometric_summary": _geom_summary_violations(),
	}

	var out: Dictionary = PanelTools._propose_into_workspace(host, data, reply, [])
	check("propose ok", bool(out.get("success", false)))
	check_eq("one candidate landed", (out.get("proposals", []) as Array).size(), 1)
	var prop: Dictionary = (out.get("proposals", []) as Array)[0]
	check_eq("candidate entry carries its OWN drc_geometric verdict (not just the batch summary)",
		str((prop.get("drc_geometric", {}) as Dictionary).get("verdict", "")), "violations")
	var out_summary: Dictionary = out.get("drc_geometric_summary", {})
	check("top-level reply carries drc_geometric_summary", not out_summary.is_empty())
	check_eq("top-level summary verdict forwarded verbatim", str(out_summary.get("verdict", "")), "violations")
	check_eq("no proposal annotation written (S5)", host.get_annotations().size(), 0)

	driver.free_panel(panel)


# ── 10: the batch status line names WHICH proposal is dirty ───────────────────

## The user's job at this surface is to reject the bad proposal. A line reading
## "2 proposals — Geometric: 2 violations" tells them something is wrong and
## gives them no way to act on it. The per-proposal verdicts stamped by
## _write_records_as_proposals (test 9) exist precisely so the batch line can
## name the offender by NET — the label the canvas and the hint both use, unlike
## the union's `route[<i>]` keys, which are wire-level indices with no on-screen
## counterpart.
func _run_render_names_the_offending_net() -> void:
	print("-- 10. violations line names WHICH proposal is dirty --")
	var dirty := {"verdict": "violations"}
	var clean := {"verdict": "clean"}

	var one := PCBPanel._geometric_status_suffix({
		"drc_geometric_summary": _geom_summary_violations(),
		"proposals": [{"net": "SIG", "drc_geometric": dirty},
					  {"net": "GND", "drc_geometric": clean}]})
	check_eq("names only the violating net", one, " — Geometric: 2 violations on SIG")
	check("does not name the clean net", not one.contains("GND"))

	# Attribution is best-effort: an older worker stamps no per-proposal verdict,
	# and the line must fall back to the bare count rather than printing "on ".
	var none := PCBPanel._geometric_status_suffix({
		"drc_geometric_summary": _geom_summary_violations(),
		"proposals": [{"net": "SIG"}, {"net": "GND"}]})
	check_eq("unattributable falls back to the bare count", none,
		" — Geometric: 2 violations")
	check("no dangling 'on'", not none.contains(" on "))

	# A net named by two separate proposals is one name, not two.
	var dup := PCBPanel._geometric_status_suffix({
		"drc_geometric_summary": _geom_summary_violations(),
		"proposals": [{"net": "SIG", "drc_geometric": dirty},
					  {"net": "SIG", "drc_geometric": dirty}]})
	check_eq("duplicate nets are de-duplicated", dup, " — Geometric: 2 violations on SIG")

	# The label must not grow without bound with the batch size.
	var many: Array = []
	for i in range(6):
		many.append({"net": "N%d" % i, "drc_geometric": dirty})
	var capped := PCBPanel._geometric_status_suffix({
		"drc_geometric_summary": _geom_summary_violations(), "proposals": many})
	check("long net lists are capped", capped.contains("+3 more"))
	check("capped list still names the first three", capped.contains("N0, N1, N2"))
	check("capped list does not name the fourth", not capped.contains("N3,"))

	# Malformed entries must not crash the status line.
	var junk := PCBPanel._geometric_status_suffix({
		"drc_geometric_summary": _geom_summary_violations(),
		"proposals": ["not-a-dict", null, {"drc_geometric": dirty}]})
	check_eq("malformed proposals degrade to the bare count", junk,
		" — Geometric: 2 violations")
