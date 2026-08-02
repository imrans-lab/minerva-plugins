extends SceneTree
## Route-hint proposal attribution (docket 019f9c3a136c).
##
## panel_tools.gd used to RE-DERIVE a proposal's `proposal_for` by matching a
## route's net against each source hint's `kind_payload.net_names`, and — the
## bug — fell back to "every selected hint" whenever nothing matched by net
## name. A hint that names its net through `source_pins`/`dest_pins` instead
## (never through `net_names`) hit that fallback EVERY time, so every proposal
## in a batch claimed to answer every hint in the selection.
##
## This mattered because `minerva_pcb_proposal_accept` (S5/C4b, DCR
## 019f7095c395: RETIRED) used to CONSUME (delete) the hints named in
## `proposal_for` — blanket attribution meant accepting one proposal could
## silently delete a hint that was never actually answered. The same
## attribution now lands on the workspace CANDIDATE's `source_hint_ids`
## (panel_tools.gd _propose_into_workspace) instead of an annotation's
## `proposal_for`, and the same "verbatim, no fallback" concern still governs
## it — a wrongly-attributed candidate would let minerva_pcb_workspace_commit
## report the wrong consumed_hint_ids. `_materialize_routes` (the commit=true
## bulk path, scenario 7 below) is UNCHANGED by S5 and still deletes hints —
## that deletion path's own attribution is what scenario 7 pins.
##
## The fix: read the worker's own per-route `hint_ids` (methods.py
## `_hint_ids_by_net`, which resolves net_names + source_pins + dest_pins —
## strictly more than the panel could ever re-derive) verbatim, with NO
## fallback. Per the per-route `hint_ids` stamp in `methods.py` `_route`
## (the `if envelopes:` block and its spec comment):
##   - `hint_ids` key ABSENT   -> no hints were supplied at all (unhinted
##     whole-board run) -> proposal_for is EMPTY.
##   - `hint_ids` present, []  -> hints were supplied, none named this net
##     -> proposal_for is EMPTY.
##   - `hint_ids` present, non-empty -> those exact ids, verbatim.
## Absent and [] mean different things (no hint asked vs. no hint answered)
## but produce the same correct output (empty) — never "everything".
##
## Run (via a Minerva scaffold as the Godot host — NEVER the live checkout):
##   godot --headless --path <minerva-scaffold>/src \
##     --script res://../../minerva-plugins/pcb/tests/gd/test_proposal_attribution.gd
##
## Coverage (numbered in EXECUTION order — keep the `-- N.` print labels, this
## list, and the _init() call order in step; they drifted apart once already):
##   1. non-empty hint_ids -> source_hint_ids exactly those ids (pure,
##      _normalize_route_records, no host)
##   2. hint_ids: [] -> source_hint_ids EMPTY, not every source hint
##      (the reported bug's direct regression test)
##   3. no hint_ids key at all -> source_hint_ids EMPTY (pure)
##   4. multiple hint ids legitimately attributed to one route -> all survive
##   5. THE REPORTED SCENARIO end to end (real host, S5's
##      _propose_into_workspace): two hints that name their nets ONLY through
##      source_pins/dest_pins (no net_names — net-name matching could never
##      resolve these), two routes each carrying the worker's correct
##      per-route hint_ids; each landed candidate's source_hint_ids names only
##      its own hint, never the other's
##   6. absent hint_ids through the REAL host -> source_hint_ids EMPTY. The
##      host-level twin of 3: this round converted the repo's only two
##      host-level absent-key fixtures to present-key, leaving the wiring
##      (as opposed to the pure helper) unguarded on that path
##   7. the deletion path's "teeth" (_materialize_routes, real host+data):
##      a partial-failure bulk apply where an UNRELATED hint sits in the same
##      source_hints selection but answers neither route — the old net-name
##      fallback would delete it anyway (over-deletion); the fix must leave it
##      untouched

const PanelTools := preload("res://../../minerva-plugins/pcb/ui/panel_tools.gd")
const PCB_PANEL_SCRIPT_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== Route-hint proposal attribution (019f9c3a136c) ===\n")
	_run_populated_hint_ids()
	_run_empty_hint_ids_not_blanket()
	_run_absent_hint_ids()
	_run_multiple_hint_ids_survive()
	_run_reported_scenario_end_to_end()
	_run_absent_hint_ids_through_the_host()
	_run_deletion_path_teeth()
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


# ── 1-4: pure record-level attribution (_normalize_route_records, no host) ─

func _one_segment_route(net: String, extra: Dictionary = {}) -> Dictionary:
	var route := {
		"net": net,
		"segments": [{"start": [0.0, 0.0], "end": [5.0, 0.0], "layer": "F.Cu"}],
		"vias": [],
	}
	for k in extra:
		route[k] = extra[k]
	return route


func _run_populated_hint_ids() -> void:
	print("-- 1. non-empty hint_ids -> source_hint_ids is exactly those ids --")
	var result := {"routes": [_one_segment_route("N1", {"hint_ids": ["h1", "h2"]})]}
	var records: Array = PanelTools._normalize_route_records(result, [])
	check_eq("one record produced", records.size(), 1)
	check_eq("source_hint_ids matches worker's hint_ids verbatim",
		(records[0] as Dictionary).get("source_hint_ids", []), ["h1", "h2"])


func _run_empty_hint_ids_not_blanket() -> void:
	print("-- 2. hint_ids: [] -> source_hint_ids EMPTY, not every source hint (REGRESSION) --")
	# Three hints supplied to the propose call, but the worker found none of
	# them answered this net -> hint_ids: []. The OLD code would fall back to
	# ALL THREE ids here; that fallback is the bug this test locks shut.
	var source_hints := [
		{"id": "hA", "kind_payload": {}},
		{"id": "hB", "kind_payload": {}},
		{"id": "hC", "kind_payload": {}},
	]
	var result := {"routes": [_one_segment_route("N1", {"hint_ids": []})]}
	var records: Array = PanelTools._normalize_route_records(result, source_hints)
	check_eq("source_hint_ids is empty, NOT every selected hint",
		(records[0] as Dictionary).get("source_hint_ids", []), [])


func _run_absent_hint_ids() -> void:
	print("-- 3. no hint_ids key at all -> source_hint_ids EMPTY --")
	var source_hints := [{"id": "hA", "kind_payload": {}}]
	var result := {"routes": [_one_segment_route("N1")]}  # no hint_ids key
	check("fixture route really has no hint_ids key",
		not (result.get("routes", [])[0] as Dictionary).has("hint_ids"))
	var records: Array = PanelTools._normalize_route_records(result, source_hints)
	check_eq("source_hint_ids is empty when the worker sent no hint_ids key at all",
		(records[0] as Dictionary).get("source_hint_ids", []), [])


func _run_multiple_hint_ids_survive() -> void:
	print("-- 4. multiple hints legitimately attributed to one route all survive --")
	var result := {"routes": [_one_segment_route("N1", {"hint_ids": ["h1", "h2", "h3"]})]}
	var records: Array = PanelTools._normalize_route_records(result, [])
	var ids: Array = (records[0] as Dictionary).get("source_hint_ids", [])
	check_eq("all three ids present", ids.size(), 3)
	check("h1 present", "h1" in ids)
	check("h2 present", "h2" in ids)
	check("h3 present", "h3" in ids)


# ── 5-6: real-host paths (S5, C4b: _propose_into_workspace) ─────────────────
#
# S5 (C4b, DCR 019f7095c395) retired _dual_write_propose: PROPOSE now lands
# workspace candidates only (panel_tools.gd _propose_into_workspace), no
# annotation. Its reply's `proposals[]` entries are result-derived and carry
# `source_hint_ids` directly (the same attribution field _normalize_route_
# records already produced above) — there is no `proposal_for` key anymore
# (that named an ANNOTATION's own field; a candidate is not one). The
# attribution CONCERN under test — the worker's per-route hint_ids, verbatim,
# no net-name fallback — is unchanged; only where it lands moved.

## A REAL source-hint annotation on the host whose kind_payload names its net
## ONLY through source_pins/dest_pins (no net_names at all) — the exact shape
## the old net-name-matching code could never resolve, which is why it always
## hit the blanket fallback for hints authored this way.
func _seed_pin_only_hint(host, source_pin: String, dest_pin: String) -> String:
	var env: Dictionary = host.build_route_hint_envelope(
		0.0, 0.0, "", "F.Cu", "waypoint", [[0.0, 0.0], [5.0, 0.0]], "human")
	var kp: Dictionary = env.get("kind_payload", {})
	kp["source_pins"] = [source_pin]
	kp["dest_pins"] = [dest_pin]
	env["kind_payload"] = kp
	return str(host.add_annotation_v2(env))


## Absent `hint_ids` driven through the REAL host, not just the pure
## normalizer. Added on cold-review feedback: this round converted the only two
## host-level absent-key exercises in the repo (test_parity_bridge.gd and
## test_workspace_ingest.gd's `_multipad_reply` fixtures) into present-key ones,
## because with the blanket fallback gone they were simulating a reply shape a
## real worker cannot produce. That repair was correct, and it silently left the
## absent-key path guarded by a single PURE test (_run_absent_hint_ids). A
## regression in _dual_write_propose's wiring — as opposed to in the pure
## helper — would then have had nothing to fail against.
##
## The distinction being pinned: an absent `hint_ids` key means NO hints were
## supplied to the run at all (methods.py stamps every route whenever any hint
## was supplied), so the honest attribution is EMPTY. The deleted fallback
## claimed every selected hint here, which is what made accepting one proposal
## able to consume a hint nobody answered.
func _run_absent_hint_ids_through_the_host() -> void:
	print("-- 6. absent hint_ids through the real host -> source_hint_ids is EMPTY --")
	var driver = preload("res://test/helpers/plugin_panel_driver.gd").new()
	var panel = driver.load_panel(PCB_PANEL_SCRIPT_PATH)
	var host = panel.get_annotation_host()
	host.set_panel(panel)
	var data = panel.get_data()

	# Two real hints ARE selected — so a blanket fallback would have something
	# to wrongly claim. The route simply carries no attribution.
	var hint_a_id := _seed_pin_only_hint(host, "U1.1", "U2.1")
	var hint_b_id := _seed_pin_only_hint(host, "U3.1", "U4.1")
	var source_hints := [host.get_by_id(hint_a_id), host.get_by_id(hint_b_id)]

	var reply := {"routes": [_one_segment_route("SIG_A")], "via_count": 0}

	var out: Dictionary = PanelTools._propose_into_workspace(host, data, reply, source_hints)
	check("propose ok", bool(out.get("success", false)))
	var proposals: Array = out.get("proposals", [])
	check_eq("one candidate landed", proposals.size(), 1)

	var linked: Array = (proposals[0] as Dictionary).get("source_hint_ids", [])
	check_eq("source_hint_ids is empty for an unattributed route", linked, [])
	check("does not claim hint A", not (hint_a_id in linked))
	check("does not claim hint B", not (hint_b_id in linked))

	# No annotation is written either way (S5) — the host still holds exactly
	# the 2 seeded source hints.
	check_eq("no annotation added by propose", host.get_annotations().size(), 2)

	driver.free_panel(panel)


func _run_reported_scenario_end_to_end() -> void:
	print("-- 5. reported scenario: two pin-only hints, two candidates, no cross-talk --")
	var driver = preload("res://test/helpers/plugin_panel_driver.gd").new()
	var panel = driver.load_panel(PCB_PANEL_SCRIPT_PATH)
	var host = panel.get_annotation_host()
	host.set_panel(panel)
	var data = panel.get_data()

	var hint_a_id := _seed_pin_only_hint(host, "U1.1", "U2.1")
	var hint_b_id := _seed_pin_only_hint(host, "U3.1", "U4.1")
	var source_hints := [host.get_by_id(hint_a_id), host.get_by_id(hint_b_id)]

	# Simulates the worker's OWN correct resolution (methods.py
	# _hint_ids_by_net covers source_pins/dest_pins) — each route stamped with
	# exactly the one hint that answers it.
	var reply := {
		"routes": [
			_one_segment_route("SIG_A", {"hint_ids": [hint_a_id]}),
			_one_segment_route("SIG_B", {"hint_ids": [hint_b_id]}),
		],
		"via_count": 0,
	}

	var out: Dictionary = PanelTools._propose_into_workspace(host, data, reply, source_hints)
	check("propose ok", bool(out.get("success", false)))
	var proposals: Array = out.get("proposals", [])
	check_eq("two candidates landed", proposals.size(), 2)

	var prop_a: Dictionary = {}
	var prop_b: Dictionary = {}
	for p in proposals:
		if str((p as Dictionary).get("net", "")) == "SIG_A":
			prop_a = p
		elif str((p as Dictionary).get("net", "")) == "SIG_B":
			prop_b = p
	check("candidate for SIG_A found", not prop_a.is_empty())
	check("candidate for SIG_B found", not prop_b.is_empty())

	check_eq("candidate A names only hint A", prop_a.get("source_hint_ids", []), [hint_a_id])
	check_eq("candidate B names only hint B", prop_b.get("source_hint_ids", []), [hint_b_id])
	check("candidate A does NOT claim hint B", not (hint_b_id in (prop_a.get("source_hint_ids", []) as Array)))
	check("candidate B does NOT claim hint A", not (hint_a_id in (prop_b.get("source_hint_ids", []) as Array)))

	# No annotation is written either (S5) — the host still holds exactly the
	# 2 seeded source hints.
	check_eq("no annotation added by propose", host.get_annotations().size(), 2)

	driver.free_panel(panel)


# ── 6: deletion-path teeth (_materialize_routes, real host + data) ────────────

## Bulk apply of a 2-route result where net "B" fails to materialize (no usable
## segments) — this is the ONLY way to reach the per-net attribution branch in
## _materialize_routes (its partial-failure `else` branch); when every route succeeds the whole
## selection is deleted unconditionally and attribution is never consulted.
## source_hints carries a THIRD hint ("hC") that answers NEITHER route — under
## the old net-name-matching fallback, hC has no net_names at all, so matching
## would fail for every net and fall back to deleting ALL of source_hints,
## including hC. The fix must leave hC's annotation untouched.
##
## Route "B" also carries a via (docket 019fa109b43c, Defect B) even though it
## has no usable segments — the discriminating fixture for "a failed route
## contributes no vias": if _materialize_routes ever adds it back, this test
## must catch a via landing on the board with no copper and no history
## checkpoint behind it.
func _run_deletion_path_teeth() -> void:
	print("-- 7. deletion path: an unrelated selected hint is NOT swept up --")
	var driver = preload("res://test/helpers/plugin_panel_driver.gd").new()
	var panel = driver.load_panel(PCB_PANEL_SCRIPT_PATH)
	var host = panel.get_annotation_host()
	host.set_panel(panel)
	var data = panel.get_data()

	var hint_a_id := _seed_pin_only_hint(host, "U1.1", "U2.1")
	var hint_b_id := _seed_pin_only_hint(host, "U3.1", "U4.1")
	var hint_c_id := _seed_pin_only_hint(host, "U5.1", "U6.1")  # answers nothing here
	var source_hints := [host.get_by_id(hint_a_id), host.get_by_id(hint_b_id), host.get_by_id(hint_c_id)]

	var result := {
		"routes": [
			_one_segment_route("A", {"hint_ids": [hint_a_id]}),
			# No usable segments -> fails. Carries a via anyway (Defect B): a
			# real router reply could propose a via before giving up on the
			# rest of the net's copper.
			{"net": "B", "segments": [], "vias": [[3.0, 3.0]], "hint_ids": [hint_b_id]},
		],
		"via_count": 1,
	}

	var mat: Dictionary = PanelTools._materialize_routes(host, data, result, source_hints)
	check("net A materialized a trace", int(mat.get("traces_added", 0)) >= 1)
	check("net B recorded as failed", (mat.get("failed", []) as Array).size() >= 1)

	# Defect B: a route that produced no copper must not commit a via either —
	# such a via would sit outside the traces_added > 0 -> save_to_history
	# checkpoint (undo() would jump straight past it) AND would be a via with
	# no trace ever connecting to it. data.vias is the actual committed board
	# state, not just this call's reported via_ids — check both.
	check("no via committed for the failed route (Defect B)", data.vias.is_empty())
	check("materialize reports no via ids either", (mat.get("via_ids", []) as Array).is_empty())

	var consumed: Array = mat.get("consumed_hint_ids", [])
	check("hint A consumed (its net succeeded)", hint_a_id in consumed)
	# 019fa109b43c, Defect A — FIXED. Hint B is attributed to a route that
	# FAILED to materialize; it must NOT be consumed. Deleting it would assert
	# an answer that never happened — the user loses an instruction that was
	# never carried out. This assertion used to read the opposite way (see
	# git history / docket 019fa109b43c): it was deliberately pinned inverted,
	# as a KNOWN BUG characterization, so the fix would have to flip it rather
	# than have the coverage quietly deleted out from under the bug.
	check("hint B NOT consumed — its net FAILED to materialize",
		not (hint_b_id in consumed))
	check("hint B annotation still present on the host", not host.get_by_id(hint_b_id).is_empty())
	check("hint C NOT consumed — it answered neither route", not (hint_c_id in consumed))
	check("hint C annotation still present on the host", not host.get_by_id(hint_c_id).is_empty())

	driver.free_panel(panel)
