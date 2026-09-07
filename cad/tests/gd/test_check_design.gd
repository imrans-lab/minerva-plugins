extends SceneTree
## minerva_cad_check_design: three checks, one verdict, only the failing rows.
##
## The acceptance loop asks "is this design still wrong, and where" after every
## edit. It used to be three verbs and three reply shapes, and the reader had
## to merge them. This verb runs the same three checks and folds them.
##
## ORACLE. A design with exactly three things wrong in it — one real crash, one
## 0.9 mm pinch under a 1 mm requirement, and one nudged post whose screw will
## not go in — must come back with exactly those three rows and verdict fail,
## and the same design with those contacts declared as intended and the post
## straightened must come back pass. Nothing here measures geometry: the three
## checks are answered by a stand-in panel with canned reports, because what is
## under test is the FOLD — which rows travel, what the verdict is, and what
## the counts say about the rows that did not.
##
## The stand-in is the smallest rig that drives the real verb layer: the three
## check methods a CADPanel answers, plus the gauge and feature modules the
## fastener leg's hole census reaches for (it finds no holes, which is enough —
## the pairing is the panel's, not the verb's).
##
## Run:
##   godot --headless --path <minerva>/src --script \
##     res://../../minerva-plugins/cad/tests/gd/test_check_design.gd

const PanelTools := preload("res://../../minerva-plugins/cad/ui/panel_tools.gd")
## Each binding evaluated once per document. The count it saves is what the
## evaluate-once case reads.
const PartCache := preload("res://../../minerva-plugins/cad/ui/scripts/part_cache.gd")
## The resolver the cache is filled through, driven directly for the case
## where the document moves while the worker is evaluating a binding.
const PartScope := preload("res://../../minerva-plugins/cad/ui/scripts/part_scope.gd")

## The gap this design has to keep, in millimetres, and the pinch that fails it.
const REQUIRED_MM := 1.0
const PINCH_MM := 0.9
## Crossing points the one interfering pair was found at. More than the verb
## keeps, so the reply has something to count as hidden.
const CROSSINGS := 5

var _pass: int = 0
var _fail: int = 0


func _init() -> void:
	print("=== CAD check_design (three checks, one verdict) ===\n")
	await process_frame
	await _run()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("  ok   %s" % label)
	else:
		_fail += 1
		printerr("FAIL: %s — %s" % [label, detail])


func _run() -> void:
	await _check_the_three_faults_are_the_three_rows()
	await _check_a_clean_design_with_declared_contacts_passes()
	await _check_an_undecidable_node_is_not_a_clean_answer()
	await _check_a_busy_collider_is_retried_not_reported()
	await _check_a_running_clearance_comes_back_as_a_ticket()
	await _check_a_certified_failure_the_filter_hides_still_fails()
	await _check_parts_each_carry_their_own_ticket()
	await _check_an_uncertified_exclusion_is_advisory_not_a_failure()
	await _check_a_violation_behind_the_limit_still_fails()
	await _check_a_finished_part_failing_is_not_lost_behind_a_ticket()
	await _check_parts_share_one_clearance_window()
	await _check_every_binding_is_evaluated_once()
	await _check_a_part_of_the_old_document_is_not_filed_under_the_new()
	await _check_a_ticket_start_leg_never_aggregates_to_pass()
	await _check_a_stale_leg_never_folds_to_pass()
	await _check_a_leg_with_no_verdict_never_aggregates_to_pass()
	await _check_a_transient_worker_failure_is_not_remembered()


# ---------------------------------------------------------------------------
# The oracle
# ---------------------------------------------------------------------------

func _check_the_three_faults_are_the_three_rows() -> void:
	var panel := _panel()
	panel.interference = _interference_report([_crash()])
	panel.clearance = _clearance_report([_pinch(), _gap(2.5), _gap(3.0), _gap(4.0)])
	panel.fasteners = _fastener_report([_nudged_post(), _good_screw()])

	var reply: Dictionary = await PanelTools.handle(panel,
			"minerva_cad_check_design",
			{"required_mm": REQUIRED_MM, "screw": {"dia_mm": 3.0, "length_mm": 8.0}})

	check("one crash, one pinch and one nudged post read as verdict fail",
			str(reply.get("verdict", "")) == "fail"
				and int(reply.get("failing_rows", 0)) == 3,
			"verdict = %s, failing_rows = %s" % [str(reply.get("verdict", "")),
				str(reply.get("failing_rows", ""))])

	var crashes: Array = reply["interference"]
	check("the crash travels as the one interference row, naming the node",
			crashes.size() == 1
				and str((crashes[0] as Dictionary)["node"]) == "board/Body",
			"interference = %s" % str(crashes))

	var pinches: Array = reply["clearance"]
	check("the 0.9 mm pinch is the one clearance row — the three gaps that "
			+ "cleared did not travel",
			pinches.size() == 1
				and absf(float((pinches[0] as Dictionary)["min_mm"]) - PINCH_MM) < 1e-6,
			"clearance = %s" % str(pinches))

	var screws: Array = reply["fasteners"]
	check("the nudged post is the one fastener row — the screw that goes in "
			+ "did not travel",
			screws.size() == 1
				and str((screws[0] as Dictionary)["node"]) == "board/PostHole",
			"fasteners = %s" % str(screws))

	var hidden: Dictionary = reply["hidden_counts"]
	check("what it did not show is COUNTED: every clearance pair, every screw "
			+ "and the crossing points behind the row",
			int(hidden.get("clearance_pairs_total", 0)) == 4
				and int(hidden.get("fastener_screws", 0)) == 2
				and int(hidden.get("interference_points", 0)) == CROSSINGS
				and int(hidden.get("interference_points_hidden", 0)) > 0,
			"hidden_counts = %s" % str(hidden))

	var checks: Dictionary = reply["checks"]
	check("and the reply says all three checks ran",
			str(checks.get("interference", "")) == "ran"
				and str(checks.get("clearance", "")) == "ran"
				and str(checks.get("fasteners", "")) == "ran",
			"checks = %s" % str(checks))
	panel.free()


func _check_a_clean_design_with_declared_contacts_passes() -> void:
	var panel := _panel()
	# The board RESTS on the bosses: the contact is the design working, and
	# the checks excuse it because it was declared.
	var interference := _interference_report([])
	interference["expected_contacts"] = [{
		"reference": "board", "node": "board/Body", "measured": "overlap",
		"measured_mm": 0.002, "excluded": true,
	}]
	interference["expected_contacts_unmatched"] = []
	panel.interference = interference
	var seated := _gap(0.0)
	seated["touching"] = true
	seated["pass"] = true
	seated["required_mm"] = 0.0
	panel.clearance = _clearance_report([seated, _gap(2.0)])
	panel.fasteners = _fastener_report([_good_screw()])

	var reply: Dictionary = await PanelTools.handle(panel,
			"minerva_cad_check_design", {
				"required_mm": REQUIRED_MM,
				"screw": {"dia_mm": 3.0, "length_mm": 8.0},
				"expected_contacts": [{"reference": "board", "node": "board/Body",
					"why": "the board seats on the bosses"}],
			})

	check("a clean design whose intended contacts are declared reads pass, "
			+ "with no rows at all",
			str(reply.get("verdict", "")) == "pass"
				and (reply["interference"] as Array).is_empty()
				and (reply["clearance"] as Array).is_empty()
				and (reply["fasteners"] as Array).is_empty(),
			"reply = %s" % str(reply))

	# WHAT EACH LEG WAS ASKED. The verdict above is folded from canned
	# reports, so it would read the same if the verb had dropped the
	# declarations, the required gap or the screw on the way in. The three
	# legs are asked one question each and each one has to carry the caller's
	# terms: the declared contact reaches interference and clearance by node,
	# the gap reaches clearance, and the screw reaches the fastener leg.
	var declared_i: Array = panel.interference_args.get("expected_contacts", []) as Array
	var declared_c: Array = panel.clearance_args.get("expected_contacts", []) as Array
	check("each leg is asked the caller's own question: the declared contact "
			+ "reaches interference and clearance, required_mm reaches "
			+ "clearance and the screw reaches the fastener leg",
			declared_i.size() == 1
				and str((declared_i[0] as Dictionary).get("node", "")) == "board/Body"
				and declared_c.size() == 1
				and str((declared_c[0] as Dictionary).get("node", "")) == "board/Body"
				and absf(float(panel.clearance_args.get("required_mm", 0.0))
					- REQUIRED_MM) < 1e-6
				and absf(float((panel.fastener_args.get("screw", {}) as Dictionary)
					.get("dia_mm", 0.0)) - 3.0) < 1e-6,
			"interference = %s, clearance = %s, fasteners = %s" % [
				str(panel.interference_args), str(panel.clearance_args),
				str(panel.fastener_args)])

	# The same design, asked about without a screw.
	panel.fasteners = _fastener_report([])
	var no_screw: Dictionary = await PanelTools.handle(panel,
			"minerva_cad_check_design", {"required_mm": REQUIRED_MM})
	check("leaving `screw` out skips the fastener leg without making the "
			+ "verdict advisory — it is a scope, not something undecided",
			str(no_screw.get("verdict", "")) == "pass"
				and str((no_screw["checks"] as Dictionary).get("fasteners", ""))
					.begins_with("not asked for"),
			"verdict = %s, checks = %s" % [str(no_screw.get("verdict", "")),
				str(no_screw.get("checks", {}))])
	panel.free()


func _check_an_undecidable_node_is_not_a_clean_answer() -> void:
	var panel := _panel()
	var interference := _interference_report([])
	interference["undecidable"] = [{"reference": "board", "node": "board/Shield",
		"reason": "every probe landed in a cavity"}]
	panel.interference = interference
	panel.clearance = _clearance_report([_gap(2.0)])
	panel.fasteners = _fastener_report([_good_screw()])

	var reply: Dictionary = await PanelTools.handle(panel,
			"minerva_cad_check_design",
			{"required_mm": REQUIRED_MM, "screw": {"dia_mm": 3.0, "length_mm": 8.0}})
	check("a node whose containment could not be decided makes the verdict "
			+ "advisory, not pass, and the note says why",
			str(reply.get("verdict", "")) == "advisory"
				and int(reply.get("failing_rows", 0)) == 0
				and str(reply.get("notes", [])).contains("containment"),
			"verdict = %s, notes = %s" % [str(reply.get("verdict", "")),
				str(reply.get("notes", []))])
	panel.free()


func _check_a_busy_collider_is_retried_not_reported() -> void:
	var panel := _panel()
	# Interference and fasteners share the panel's one solid collider. The
	# panel's OWN per-evaluation check holds it for the first two asks.
	panel.busy_replies = 2
	panel.interference = _interference_report([])
	panel.clearance = _clearance_report([_gap(2.0)])
	panel.fasteners = _fastener_report([_good_screw()])

	var reply: Dictionary = await PanelTools.handle(panel,
			"minerva_cad_check_design",
			{"required_mm": REQUIRED_MM, "screw": {"dia_mm": 3.0, "length_mm": 8.0}})
	check("a leg refused with `busy` is asked again until it answers — the "
			+ "verb never reports the collider refusal as a result",
			panel.interference_calls == 3
				and str((reply["checks"] as Dictionary).get("interference", "")) == "ran"
				and str(reply.get("verdict", "")) == "pass",
			"asked %d times, checks = %s, verdict = %s" % [panel.interference_calls,
				str(reply.get("checks", {})), str(reply.get("verdict", ""))])
	panel.free()


func _check_a_running_clearance_comes_back_as_a_ticket() -> void:
	var panel := _panel()
	panel.interference = _interference_report([_crash()])
	panel.clearance = {"checked": false, "status": "running",
		"ticket": "clearance-4", "pairs": [], "elapsed_ms": 2000,
		"reason": "the measurement is still running in the worker"}
	panel.fasteners = _fastener_report([_good_screw()])

	var reply: Dictionary = await PanelTools.handle(panel,
			"minerva_cad_check_design",
			{"required_mm": REQUIRED_MM, "screw": {"dia_mm": 3.0, "length_mm": 8.0}})
	check("a clearance that outruns the window comes back as ONE ticket, with "
			+ "the interference and fastener rows already in hand",
			str(reply.get("status", "")) == "running"
				and str(reply.get("ticket", "")) == "clearance-4"
				and str((reply.get("tickets", {}) as Dictionary)
					.get("clearance", "")) == "clearance-4"
				and (reply["interference"] as Array).size() == 1,
			"reply = %s" % str(reply))
	check("and its verdict is still fail — a leg nobody could finish never "
			+ "turns a crash into a clean answer",
			str(reply.get("verdict", "")) == "fail"
				and str((reply["checks"] as Dictionary).get("clearance", ""))
					.contains("running"),
			"verdict = %s, checks = %s" % [str(reply.get("verdict", "")),
				str(reply.get("checks", {}))])
	panel.free()


## ORACLE: a 1.005 mm gap under a 1.0 mm requirement on a solid tessellated to
## 0.01 mm is a CERTIFIED failure — bound_mm 0.995 < 1.0 — even though the raw
## distance clears the bar, and the fold must say fail with that row. A leg
## whose own verdict is false for a reason no row carries (a stale
## interference join) must read advisory, never pass.
func _check_a_certified_failure_the_filter_hides_still_fails() -> void:
	var panel := _panel()
	panel.interference = _interference_report([])
	var pinch := _gap(REQUIRED_MM + 0.005)
	pinch["bound_mm"] = REQUIRED_MM - 0.005
	pinch["pass"] = false
	panel.clearance = _clearance_report([pinch, _gap(2.5)])
	panel.fasteners = _fastener_report([_good_screw()])
	var reply: Dictionary = await PanelTools.handle(panel,
			"minerva_cad_check_design",
			{"required_mm": REQUIRED_MM, "screw": {"dia_mm": 3.0, "length_mm": 8.0}})
	var rows: Array = reply["clearance"]
	check("a pair that clears required_mm by less than the bounded tolerance "
			+ "is a certified failure: it travels as the one clearance row "
			+ "and the verdict is fail",
			str(reply.get("verdict", "")) == "fail"
				and rows.size() == 1
				and absf(float((rows[0] as Dictionary)["min_mm"]) - (REQUIRED_MM + 0.005)) < 1e-6,
			"reply = %s" % str(reply))

	var stale := _clearance_report([_gap(2.5)])
	stale["pass"] = false
	stale["pass_reason"] = "interference evidence unavailable: no interference "\
		+ "report describes this source"
	panel.clearance = stale
	var unproven: Dictionary = await PanelTools.handle(panel,
			"minerva_cad_check_design",
			{"required_mm": REQUIRED_MM, "screw": {"dia_mm": 3.0, "length_mm": 8.0}})
	check("a clearance leg whose own pass is false for a reason no row "
			+ "carries reads advisory with that reason, never pass",
			str(unproven.get("verdict", "")) == "advisory"
				and str(unproven.get("notes", [])).contains("interference evidence"),
			"verdict = %s, notes = %s" % [str(unproven.get("verdict", "")),
				str(unproven.get("notes", []))])
	panel.free()


## ORACLE: with parts=["bottom", "top"] the clearance leg runs once per part,
## and when both outrun the window the reply must carry BOTH tickets, keyed by
## part, so each measurement can be collected; a ticket that did not travel is
## a measurement nobody can collect.
func _check_parts_each_carry_their_own_ticket() -> void:
	var panel := _panel()
	panel.interference = _interference_report([])
	panel.clearance = {"checked": false, "status": "running",
		"ticket": "per-part", "pairs": [], "elapsed_ms": 2000,
		"reason": "the measurement is still running in the worker"}
	panel.fasteners = _fastener_report([_good_screw()])
	var reply: Dictionary = await PanelTools.handle(panel,
			"minerva_cad_check_design",
			{"required_mm": REQUIRED_MM, "parts": ["bottom", "top"]})
	var tickets: Dictionary = (reply.get("tickets", {}) as Dictionary) \
		.get("clearance", {}) as Dictionary
	check("two parts still measuring come back as two tickets under "
			+ "tickets.clearance, one per part, with status running",
			str(reply.get("status", "")) == "running"
				and tickets.size() == 2
				and str(tickets.get("bottom", "")) == "clearance-bottom"
				and str(tickets.get("top", "")) == "clearance-top"
				and str(reply.get("ticket_note", "")).contains("minerva_cad_check_clearance"),
			"reply = %s" % str(reply))
	panel.free()


## ORACLE: a declared contact whose overlap measures 0.05 mm inside a 0.1 mm
## allowance is excused on a sampled depth (excused_uncertified), and a
## declared region leaves its pair ungraded outside the box
## (ungraded_outside_region). Neither establishes a violation: the verdict
## is advisory, both rows travel under uncertified_rows, and failing_rows is
## 0. Put a real 0.9 mm pinch beside them and the verdict is fail with
## exactly that one failing row, the two uncertified rows still apart.
func _check_an_uncertified_exclusion_is_advisory_not_a_failure() -> void:
	var panel := _panel()
	panel.interference = _interference_report([])
	var seated := _gap(0.0)
	seated["interference"] = true
	seated["overlap_mm"] = 0.05
	seated["expected"] = true
	seated["required_mm"] = 0.0
	seated["pass"] = false
	seated["excused_uncertified"] = true
	var regional := _gap(2.0)
	regional["expected"] = true
	regional["declared_region"] = true
	regional["pass"] = false
	regional["ungraded_outside_region"] = true
	var report := _clearance_report([seated, regional, _gap(3.0)])
	report["advisory"] = true
	report["pass_reason"] = "2 declared contact(s) could only be applied "\
		+ "advisorily; pass is withheld rather than certified"
	panel.clearance = report
	panel.fasteners = _fastener_report([_good_screw()])
	var declared := [{"reference": "board", "node": "board/Body_0",
		"allowance_mm": 0.1, "why": "seats on the bosses"}]
	var reply: Dictionary = await PanelTools.handle(panel,
			"minerva_cad_check_design", {"required_mm": REQUIRED_MM,
				"screw": {"dia_mm": 3.0, "length_mm": 8.0},
				"expected_contacts": declared})
	var uncertified: Array = reply.get("uncertified_rows", []) as Array
	check("an overlap inside its allowance on a sampled depth and a region "
			+ "declaration are advisory: verdict advisory, failing_rows 0, "
			+ "both rows under uncertified_rows",
			str(reply.get("verdict", "")) == "advisory"
				and int(reply.get("failing_rows", -1)) == 0
				and (reply["clearance"] as Array).is_empty()
				and uncertified.size() == 2
				and int(reply.get("uncertified", 0)) == 2,
			"reply = %s" % str(reply))

	report["pairs"] = [seated, _pinch(), regional]
	panel.clearance = report
	var mixed: Dictionary = await PanelTools.handle(panel,
			"minerva_cad_check_design", {"required_mm": REQUIRED_MM,
				"screw": {"dia_mm": 3.0, "length_mm": 8.0},
				"expected_contacts": declared})
	var rows: Array = mixed["clearance"]
	check("a real pinch beside them still fails, as the one failing row, "
			+ "with the two uncertified rows kept apart from it",
			str(mixed.get("verdict", "")) == "fail"
				and int(mixed.get("failing_rows", 0)) == 1
				and rows.size() == 1
				and absf(float((rows[0] as Dictionary)["min_mm"]) - PINCH_MM) < 1e-6
				and int(mixed.get("uncertified", 0)) == 2,
			"mixed = %s" % str(mixed))
	panel.free()


## ORACLE: ten declared overlaps at 0 mm, each excused uncertifiably inside
## its allowance, followed by an undeclared 0.2 mm gap under required_mm 0.5.
## The default limit is ten and the overlaps are closest, so the ONLY row the
## filter shows are the ten advisory ones — yet the violation is established
## and counted by the leg (pairs_failing 1). The verdict must read that count:
## fail, with failing_rows 0 (nothing shown failed) and
## hidden_counts.failing_rows_hidden 1. Raising the limit shows the row and
## the hidden count goes away, so the two numbers are one derivation.
func _check_a_violation_behind_the_limit_still_fails() -> void:
	var panel := _panel()
	panel.interference = _interference_report([])
	var pairs: Array = []
	for index in range(10):
		var seated := _gap(0.0)
		seated["node"] = "board/Boss_%d" % index
		seated["interference"] = true
		seated["overlap_mm"] = 0.05
		seated["expected"] = true
		seated["required_mm"] = 0.0
		seated["pass"] = false
		seated["excused_uncertified"] = true
		pairs.append(seated)
	var violation := _gap(0.2)
	violation["pass"] = false
	pairs.append(violation)
	var report := _clearance_report(pairs)
	report["advisory"] = true
	report["pass_reason"] = "10 declared contact(s) could only be applied "\
		+ "advisorily; pass is withheld rather than certified"
	panel.clearance = report
	panel.fasteners = _fastener_report([_good_screw()])
	var declared := [{"reference": "board", "node": "board/Boss_0",
		"allowance_mm": 0.1, "why": "seats on the bosses"}]
	var args := {"required_mm": 0.5, "screw": {"dia_mm": 3.0, "length_mm": 8.0},
		"expected_contacts": declared}
	var reply: Dictionary = await PanelTools.handle(panel,
			"minerva_cad_check_design", args)
	var hidden: Dictionary = reply.get("hidden_counts", {}) as Dictionary
	check("ten uncertified overlaps fill the default limit and the 0.2 mm "
			+ "violation behind them still reads fail: failing_rows 0, "
			+ "failing_rows_hidden 1, ten uncertified rows, a note saying so",
			str(reply.get("verdict", "")) == "fail"
				and int(reply.get("failing_rows", -1)) == 0
				and (reply["clearance"] as Array).is_empty()
				and int(hidden.get("failing_rows_hidden", 0)) == 1
				and int(hidden.get("clearance_pairs_failing", 0)) == 1
				and int(reply.get("uncertified", 0)) == 10
				and str(reply.get("notes", [])).contains("did not travel"),
			"reply = %s" % str(reply))

	args["limit"] = 20
	var widened: Dictionary = await PanelTools.handle(panel,
			"minerva_cad_check_design", args)
	var rows: Array = widened["clearance"]
	var widened_hidden: Dictionary = widened.get("hidden_counts", {}) as Dictionary
	check("with limit raised the same violation travels as the one failing "
			+ "row, failing_rows 1, and nothing is counted as hidden",
			str(widened.get("verdict", "")) == "fail"
				and int(widened.get("failing_rows", -1)) == 1
				and rows.size() == 1
				and absf(float((rows[0] as Dictionary)["min_mm"]) - 0.2) < 1e-6
				and not widened_hidden.has("failing_rows_hidden"),
			"widened = %s" % str(widened))
	panel.free()


## ORACLE: parts=["bottom", "top"]; bottom's clearance finishes with a 0.9 mm
## pinch and top's is still running. The reply must be verdict fail with
## bottom's row in it, and top's ticket must travel ONLY under
## tickets.clearance — never as this verb's own `ticket`, which collects one
## leg and would fold a verdict without bottom's row.
func _check_a_finished_part_failing_is_not_lost_behind_a_ticket() -> void:
	var panel := _panel()
	panel.interference = _interference_report([])
	panel.clearance_by_part = {
		"bottom": _clearance_report([_pinch(), _gap(2.5)]),
		"top": {"checked": false, "status": "running", "ticket": "per-part",
			"pairs": [], "elapsed_ms": 2000,
			"reason": "the measurement is still running in the worker"},
	}
	panel.fasteners = _fastener_report([_good_screw()])
	var reply: Dictionary = await PanelTools.handle(panel,
			"minerva_cad_check_design",
			{"required_mm": REQUIRED_MM, "parts": ["bottom", "top"]})
	var rows: Array = reply["clearance"]
	var tickets: Dictionary = (reply.get("tickets", {}) as Dictionary) \
		.get("clearance", {}) as Dictionary
	check("bottom's pinch is a failing row and the verdict is fail even "
			+ "though top is still measuring",
			str(reply.get("verdict", "")) == "fail"
				and rows.size() == 1
				and str((rows[0] as Dictionary).get("part", "")) == "bottom",
			"reply = %s" % str(reply))
	check("top's ticket travels under tickets.clearance only — no "
			+ "check_design ticket is offered that would fold top alone",
			str(reply.get("status", "")) == "running"
				and not reply.has("ticket")
				and tickets.size() == 1
				and str(tickets.get("top", "")) == "clearance-top"
				and str(reply.get("ticket_note", "")).contains("minerva_cad_check_clearance"),
			"reply = %s" % str(reply))
	panel.free()


## ORACLE: with two parts, both clearance legs are STARTED (wait_ms 0) before
## either is waited on, and then collected against one shared window; a
## part that settles inside it is folded from its collected report. The
## stand-in logs every clearance call in order: two starts, then two
## collects carrying a positive wait, and top's collected pinch is a row.
func _check_parts_share_one_clearance_window() -> void:
	var panel := _panel()
	panel.interference = _interference_report([])
	panel.clearance = {"checked": false, "status": "running",
		"ticket": "per-part", "pairs": [], "elapsed_ms": 2000,
		"reason": "the measurement is still running in the worker"}
	panel.collect_replies = {"clearance-top": _clearance_report([_pinch()])}
	panel.fasteners = _fastener_report([_good_screw()])
	var reply: Dictionary = await PanelTools.handle(panel,
			"minerva_cad_check_design",
			{"required_mm": REQUIRED_MM, "parts": ["bottom", "top"]})
	var calls: Array = panel.clearance_calls
	check("both legs start with no wait before either is collected, and "
			+ "the collects carry the shared window",
			calls.size() == 4
				and str(calls[0]) == "start:bottom:wait=0"
				and str(calls[1]) == "start:top:wait=0"
				and str(calls[2]).begins_with("collect:clearance-bottom:wait=")
				and not str(calls[2]).ends_with("wait=0")
				and str(calls[3]).begins_with("collect:clearance-top:wait="),
			"calls = %s" % str(calls))
	var rows: Array = reply["clearance"]
	var tickets: Dictionary = (reply.get("tickets", {}) as Dictionary) \
		.get("clearance", {}) as Dictionary
	check("top settled inside the window and its pinch is folded as top's "
			+ "row; bottom is still running and keeps its ticket",
			str(reply.get("verdict", "")) == "fail"
				and rows.size() == 1
				and str((rows[0] as Dictionary).get("part", "")) == "top"
				and tickets.size() == 1
				and str(tickets.get("bottom", "")) == "clearance-bottom",
			"reply = %s" % str(reply))
	panel.free()


# ---------------------------------------------------------------------------
# The reports the three checks would have measured
# ---------------------------------------------------------------------------

func _interference_report(pairs: Array) -> Dictionary:
	return {
		"checked": true, "units": "mm",
		"pass": pairs.is_empty(),
		"count": pairs.size(),
		"point_count": pairs.size() * CROSSINGS,
		"pairs": pairs,
		"undecidable": [],
		"records_digest": "board|v1",
	}


func _crash() -> Dictionary:
	var points: Array = []
	for index in range(CROSSINGS):
		var at: Array = [1.0 + float(index) * 0.1, 2.0, 3.0]
		points.append({"world": at, "local": at})
	return {
		"reference": "board", "node": "board/Body",
		"points_mm": points, "point_count": CROSSINGS,
		"penetration_mm": 0.42,
	}


func _clearance_report(pairs: Array) -> Dictionary:
	var clean := true
	for entry in pairs:
		if not bool((entry as Dictionary).get("pass", false)):
			clean = false
	return {
		"checked": true, "units": "mm", "status": "complete",
		"pass": clean,
		"required_mm": REQUIRED_MM,
		"quantization_mm": 0.0,
		"tolerance_bounded": true,
		"tessellation_tolerance_mm": 0.01,
		"pairs": pairs,
	}


func _pinch() -> Dictionary:
	var pair := _gap(PINCH_MM)
	pair["pass"] = false
	return pair


func _gap(distance_mm: float) -> Dictionary:
	return {
		"reference": "board", "node": "board/Body_%s" % distance_mm,
		"min_mm": distance_mm, "bound_mm": distance_mm,
		"pass": distance_mm >= REQUIRED_MM,
		"solid_point_mm": {"world": [0.0, 0.0, 0.0]},
		"reference_point_mm": {"world": [0.0, 0.0, distance_mm],
			"local": [0.0, 0.0, distance_mm]},
	}


func _fastener_report(screws: Array) -> Dictionary:
	var failed := 0
	for entry in screws:
		if not bool((entry as Dictionary).get("pass", false)):
			failed += 1
	return {
		"checked": true, "units": "mm",
		"count": screws.size(),
		"failed": failed,
		"pass": failed == 0 and not screws.is_empty(),
		"screws": screws,
		"unpaired": {},
	}


func _nudged_post() -> Dictionary:
	return {
		"reference": "board", "node": "board/PostHole",
		"axis_source": "b_rep",
		"coaxiality": {"offset_start_mm": 0.6, "allowed_mm": 0.2, "pass": false},
		"path_clear": true, "engagement_mm": 6.0, "engagement_ok": true,
		"pass": false,
		"why": "the post is 0.6 mm off the hole's axis, and the clearance "
			+ "hole allows 0.2 mm",
	}


func _good_screw() -> Dictionary:
	return {
		"reference": "board", "node": "board/CornerHole",
		"axis_source": "b_rep",
		"coaxiality": {"offset_start_mm": 0.02, "allowed_mm": 0.2, "pass": true},
		"path_clear": true, "engagement_mm": 6.0, "engagement_ok": true,
		"pass": true, "why": "",
	}


## ORACLE: COUNT THE EVALUATIONS. minerva_cad_check_design over four parts
## runs three legs, and every leg used to reach a binding by evaluating the
## whole document with that binding as its trailing expression — twelve worker
## translates for four shapes, at tens of seconds each on a lofted enclosure,
## which spends the caller's whole MCP window and returns nothing.
##
## The stand-in counts every evaluate it is asked for. Four parts, three legs,
## one call: the count must be FOUR. Twelve is the shipped behaviour and one
## is a cache that has stopped keying on the binding — both fail here.
##
## And then the document changes. The cache is keyed on the document's source
## digest, so the next call must pay for all four again: a cache that served
## the old document's parts would answer about a shape that no longer exists,
## which is worse than the cost it saves.
func _check_every_binding_is_evaluated_once() -> void:
	PartCache.clear()
	var panel := _panel()
	panel.document_source = "bottom = cube(10, 10, 10)\ntop = cube(10, 10, 2)\n"\
		+ "door = cube(4, 4, 1)\nshells = bottom + top\n"
	panel.interference = _interference_report([])
	panel.clearance = _clearance_report([_gap(2.5)])
	panel.fasteners = _fastener_report([_good_screw()])
	var parts := ["bottom", "top", "door", "shells"]
	var args := {"required_mm": REQUIRED_MM, "parts": parts,
		"screw": {"dia_mm": 3.0, "length_mm": 8.0}}

	var reply: Dictionary = await PanelTools.handle(panel,
			"minerva_cad_check_design", args)
	check("evaluate-once: four parts and three legs cost FOUR worker "
			+ "evaluations, not twelve",
			panel.evaluate_calls == parts.size(),
			"evaluate_calls = %d for %d parts" % [panel.evaluate_calls,
				parts.size()])
	check("evaluate-once: and all four parts are still cached SEPARATELY — "
			+ "one entry each, so no leg was answered about another binding",
			PartCache.part_count(panel) == parts.size()
				and str(PartCache.part(panel, "door").get("source", "")) \
					.ends_with("\ndoor\n"),
			"cached = %d, door source = %s" % [PartCache.part_count(panel),
				str(PartCache.part(panel, "door").get("source", ""))])

	# ALL THREE LEGS ARE COMPLETE FOR EVERY PART. A reply that reached its
	# verdict by skipping legs would also have a low evaluation count.
	var checks_ran: Dictionary = reply.get("checks", {}) as Dictionary
	check("evaluate-once: the one reply still carries all three legs, "
			+ "complete, with a verdict over the lot and no ticket left over",
			str(checks_ran.get("interference", "")) == "ran"
				and str(checks_ran.get("clearance", "")) == "ran"
				and str(checks_ran.get("fasteners", "")) == "ran"
				and str(reply.get("verdict", "")) == "pass"
				and not reply.has("ticket")
				and not reply.has("tickets"),
			"reply = %s" % str(reply))

	# THE SAME CALL AGAIN COSTS NOTHING. The document has not moved, so every
	# binding is already known.
	panel.evaluate_calls = 0
	await PanelTools.handle(panel, "minerva_cad_check_design", args)
	check("evaluate-once: asking again about the same document evaluates "
			+ "nothing at all",
			panel.evaluate_calls == 0,
			"evaluate_calls = %d" % panel.evaluate_calls)

	# THE DOCUMENT MOVES. Every part of the old source is a different shape.
	panel.document_source += "lid = cube(2, 2, 2)\n"
	panel.evaluate_calls = 0
	await PanelTools.handle(panel, "minerva_cad_check_design", args)
	check("evaluate-once: the next evaluation of the document invalidates "
			+ "every binding — all four are asked for again",
			panel.evaluate_calls == parts.size()
				and PartCache.part_count(panel) == parts.size(),
			"evaluate_calls = %d, cached = %d" % [panel.evaluate_calls,
				PartCache.part_count(panel)])
	panel.free()
	PartCache.clear()


## ORACLE: a resolve that goes to the worker for the document at S1 must not
## file its answer once the document is at S2. The stand-in's worker answers a
## frame later; in that frame the document is edited and the store retained
## for the new digest (what any other verb's first leg does). The answer that
## comes back is about S1 and the store must hold nothing under S2 — a slot
## that filed it would hand every later leg a part of a document that no
## longer exists — and the caller is told the answer was not kept.
func _check_a_part_of_the_old_document_is_not_filed_under_the_new() -> void:
	PartCache.clear()
	var panel := _panel()
	panel.document_source = "bottom = cube(10, 10, 10)\ntop = cube(10, 10, 2)\n"
	var outcome: Dictionary = {"resolved": {}}
	var resolve := func() -> void:
		outcome["resolved"] = await PartScope.resolve(panel, "top")
	resolve.call()
	# The worker has been asked (one frame's delay stands in for it) and the
	# document moves under it.
	panel.document_source += "lid = cube(2, 2, 2)\n"
	PartCache.retain(panel, PartCache.digest(panel.document_source))
	await process_frame
	await process_frame
	var resolved: Dictionary = outcome["resolved"]
	check("moved-under: a binding evaluated from the source before an edit "
			+ "is answered but NOT filed under the document standing now — "
			+ "the store holds no part for it and the answer says it was not "
			+ "kept",
			panel.evaluate_calls == 1
				and not resolved.is_empty()
				and not resolved.has("error")
				and PartCache.part_count(panel) == 0
				and PartCache.part(panel, "top").is_empty()
				and str(resolved.get("note", "")).contains("moved past"),
			"evaluate_calls = %d, cached = %d, resolved = %s" % [
				panel.evaluate_calls, PartCache.part_count(panel),
				str(resolved)])
	panel.free()
	PartCache.clear()


## ORACLE: parts=["top"] with wait_ms=0, and the leg comes
## straight back with a ticket having measured nothing. The per-part fold is
## shared by every check verb, so the verdict it prints is the one the reader
## acts on — and a leg that carries no `pass` at all must never be read as one.
func _check_a_ticket_start_leg_never_aggregates_to_pass() -> void:
	var panel := _panel()
	panel.interference = _interference_report([])
	panel.clearance = {"checked": false, "status": "running",
		"ticket": "per-part", "pairs": [], "elapsed_ms": 1,
		"reason": "the measurement is still running in the worker"}
	var reply: Dictionary = await PanelTools.handle(panel,
			"minerva_cad_check_clearance",
			{"required_mm": REQUIRED_MM, "parts": ["top"], "wait_ms": 0})
	check("a clearance leg that only started, and measured nothing, is never "
			+ "aggregated as pass — the verdict says so and names the ticket",
			reply.get("pass", null) != true
				and int(reply.get("failed", 0)) == 1
				and str(reply.get("pass_reason", "")).contains("clearance-top"),
			"reply = %s" % str(reply))
	panel.free()


## ORACLE: a leg that MEASURED, passed, and is stamped stale.
##
## The freshness gate refuses a check before it starts, so a stale reply can
## only come from a leg that was already measuring when the document moved
## under it — the reply is a true answer about geometry the document has left
## behind, and the only thing saying so is its `stale` stamp. The fold read the
## rows and the counts and never that stamp, so a clean-but-stale leg folded
## to verdict "pass" and the design reply carried no stale for the verb layer's
## own stamp to OR into. Both are asserted here: not-pass with the reason, and
## the stamp travelling.
func _check_a_stale_leg_never_folds_to_pass() -> void:
	var panel := _panel()
	var stale := _interference_report([])
	stale["stale"] = true
	stale["stale_reason"] = "the references were re-posed while this check ran"
	panel.interference = stale
	panel.clearance = _clearance_report([_gap(2.0)])

	var reply: Dictionary = await PanelTools.handle(panel,
			"minerva_cad_check_design", {"required_mm": REQUIRED_MM})
	check("a leg that measured geometry the document has moved past is never "
			+ "folded to pass: the verdict is advisory, the reason names the "
			+ "leg and the stamp, and the design reply carries `stale` so the "
			+ "verb layer's own stamp cannot report a settled document",
			str(reply.get("verdict", "")) != "pass"
				and bool(reply.get("stale", false))
				and str(reply.get("stale_reason", "")).contains("re-posed")
				and str((reply.get("checks", {}) as Dictionary)
					.get("interference", "")).begins_with("ran, but stale"),
			"reply = %s" % str(reply))
	panel.free()


## ORACLE: a per-part leg that measured and graded NOTHING.
##
## minerva_cad_material reports what is there and carries no `pass` at all, and
## the per-part fold read a missing key as true — so `parts` on any such verb
## answered pass:true whatever the rows said. A clearance report with its
## verdict removed stands in for that shape here; what is asserted is the fold,
## which is shared by every verb that takes `parts`.
func _check_a_leg_with_no_verdict_never_aggregates_to_pass() -> void:
	var panel := _panel()
	panel.interference = _interference_report([])
	var ungraded := _clearance_report([_gap(2.0)])
	ungraded.erase("pass")
	panel.clearance = ungraded

	var reply: Dictionary = await PanelTools.handle(panel,
			"minerva_cad_check_clearance",
			{"required_mm": REQUIRED_MM, "parts": ["top"]})
	check("a part leg that grades nothing yields NO aggregate verdict — pass "
			+ "is null and a note says why — rather than the true a missing "
			+ "key used to be read as",
			reply.get("pass", true) == null
				and int(reply.get("failed", -1)) == 0
				and str(reply.get("pass_reason", "")).contains("no verdict"),
			"reply = %s" % str(reply))
	panel.free()


## ORACLE: one timeout must not answer for the document's whole life.
##
## A binding the worker REFUSED is the same refusal every time it is asked, so
## it is cached. A request that timed out, was cancelled or never reached the
## worker says nothing about the binding — and caching it made a single slow
## evaluation reply "part did not evaluate" to every later call until the
## source changed. The stand-in fails once transiently, then answers.
func _check_a_transient_worker_failure_is_not_remembered() -> void:
	var panel := _panel()
	panel.interference = _interference_report([])
	panel.clearance = _clearance_report([_gap(2.0)])
	PartCache.clear()
	panel.backend_failures = 1

	var refused: Dictionary = await PanelTools.handle(panel,
			"minerva_cad_check_clearance",
			{"required_mm": REQUIRED_MM, "parts": ["top"]})
	var evaluations_after_timeout := panel.evaluate_calls
	var again: Dictionary = await PanelTools.handle(panel,
			"minerva_cad_check_clearance",
			{"required_mm": REQUIRED_MM, "parts": ["top"]})
	check("a timeout is not cached: the first call reports the part as "
			+ "unevaluated, and the SECOND reaches the worker again and "
			+ "measures — a cached transient would answer 'did not evaluate' "
			+ "for the life of the document without asking",
			not bool(((refused["parts"] as Array)[0] as Dictionary)
					.get("checked", true))
				and panel.evaluate_calls > evaluations_after_timeout
				and bool(((again["parts"] as Array)[0] as Dictionary)
					.get("checked", false)),
			"refused = %s / again = %s / evaluations = %d" % [str(refused),
				str(again), panel.evaluate_calls])
	panel.free()
	PartCache.clear()


# ---------------------------------------------------------------------------
# The rig
# ---------------------------------------------------------------------------

func _panel() -> _DesignStandIn:
	var panel := _DesignStandIn.new()
	root.add_child(panel)
	return panel


## A panel that answers the three check methods with canned reports, and
## nothing else. The fastener verb runs a hole census on the way in, so the
## gauge and the feature module are here too — they find nothing, which is all
## this fold needs from them.
class _DesignStandIn extends Node:
	var interference: Dictionary = {}
	var clearance: Dictionary = {}
	var fasteners: Dictionary = {}
	## Refuse the interference check this many times before answering, the way
	## the panel's own per-evaluation check does while it holds the collider.
	var busy_replies: int = 0
	var interference_calls: int = 0
	## The args each leg was actually handed. The verb builds these from the
	## caller's, and a stand-in that ignored them would make the pass-through
	## unfalsifiable: the same canned reports come back whatever is asked.
	var interference_args: Dictionary = {}
	var clearance_args: Dictionary = {}
	var fastener_args: Dictionary = {}
	## Per-part canned clearance replies (part -> report), read before
	## `clearance` when the part is named there; and per-ticket replies for
	## a collect, which otherwise answers "still running".
	var clearance_by_part: Dictionary = {}
	var collect_replies: Dictionary = {}
	## Every clearance call in order: "start:<part>:wait=<ms|default>" or
	## "collect:<ticket>:wait=<ms>".
	var clearance_calls: Array = []
	## Worker evaluations this panel was asked for, and the document they are
	## asked about. The count is the oracle for evaluate-once: three legs over
	## four parts must cost four evaluations and not twelve.
	var evaluate_calls: int = 0
	## Evaluations to fail TRANSIENTLY before answering — the shape a worker
	## timeout arrives in, which says nothing about the binding asked for.
	var backend_failures: int = 0
	var document_source: String = "bottom = cube(10, 10, 10)\ntop = cube(10, 10, 2)\n"

	var _gauge: _GaugeStandIn = null
	var _features: _FeatureStandIn = null

	func _init() -> void:
		_gauge = _GaugeStandIn.new()
		add_child(_gauge)
		_features = _FeatureStandIn.new()

	func get_reference_digest() -> String:
		return "design|v1"

	func get_reference_state() -> Array:
		return [{"name": "board", "parts": [], "pose": Transform3D.IDENTITY,
			"world_aabb": AABB()}]

	func get_mesh_gauge() -> Node:
		return _gauge

	func get_mesh_features() -> RefCounted:
		return _features

	func ensure_gauge_built() -> void:
		pass

	func check_interference(args: Dictionary) -> Dictionary:
		interference_calls += 1
		interference_args = args.duplicate(true)
		if busy_replies > 0:
			busy_replies -= 1
			return {"checked": false, "busy": true, "holder_ticket": 7,
				"holder_age_ms": 30, "count": 0, "pairs": [],
				"reason": "the evaluation's own check holds the geometry"}
		return interference.duplicate(true)

	func check_clearance(args: Dictionary) -> Dictionary:
		var ticket := str(args.get("ticket", ""))
		if not ticket.is_empty():
			clearance_calls.append("collect:%s:wait=%d" % [ticket,
				int(args.get("wait_ms", 0))])
			return (collect_replies.get(ticket, {"checked": false,
				"status": "running", "ticket": ticket, "pairs": [],
				"elapsed_ms": 1, "reason": "still running"}) as Dictionary) \
				.duplicate(true)
		clearance_args = args.duplicate(true)
		# A part-scoped leg is asked with that part's source, which ends in
		# the binding's name; its ticket is named after it so the fold can be
		# seen to keep the two apart.
		var source := str(args.get("source", "")).strip_edges()
		var part := source.get_slice("\n", source.get_slice_count("\n") - 1)
		clearance_calls.append("start:%s:wait=%s" % [part,
			str(args.get("wait_ms", "default"))])
		var reply: Dictionary = (clearance_by_part.get(part, clearance) \
			as Dictionary).duplicate(true)
		if reply.has("ticket") and not source.is_empty():
			reply["ticket"] = "clearance-" + part
		return reply

	## What part_scope asks a panel for when `parts` is given: the document's
	## source and a worker that evaluates one binding of it. The mesh is a
	## single triangle — enough to be "solid geometry" for the fold under test.
	func get_document_state() -> Dictionary:
		return {"source": document_source, "last_eval": {"shape_name": "top"}}

	func call_backend(_channel: String, args: Dictionary,
			_timeout_ms: int = 30000) -> Dictionary:
		evaluate_calls += 1
		await (Engine.get_main_loop() as SceneTree).process_frame
		if backend_failures > 0:
			backend_failures -= 1
			return {"success": false, "error_code": "timeout",
				"error_message": "the worker did not answer in time"}
		var source := str(args.get("source", "")).strip_edges()
		return {"success": true, "result": {"ok": true, "result": {
			"shape_name": source.get_slice("\n", source.get_slice_count("\n") - 1),
			"mesh": {"vertices": [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]],
				"faces": [[0, 1, 2]]},
		}}}

	func check_fasteners(args: Dictionary) -> Dictionary:
		fastener_args = args.duplicate(true)
		return fasteners.duplicate(true)


## Enough gauge for the hole census to run and report nothing.
class _GaugeStandIn extends Node:
	func mask_for(_reference: String) -> int:
		return 1

	func get_shape_count() -> int:
		return 0

	func submit(_kind: String, _args: Dictionary) -> Dictionary:
		return {"seeds": [], "holes": []}


## Enough segmentation for the hole census to propose nothing.
class _FeatureStandIn extends RefCounted:
	func get_analysis_count() -> int:
		return 0

	func features_for_async(_key: String, _parts: Array, _angle: float,
			_tree: SceneTree) -> Dictionary:
		return {"candidates": [], "elapsed_ms": 0}
