extends SceneTree
## Connectivity DRC-at-propose baseline partition reaches the user (docket
## 019f9da15929). Round C2c (`methods.py` `_attach_route_drc`,
## docket 019f9cc386b6) split the connectivity `drc_summary` into what the
## PROPOSAL introduces (`clean`/`violation_count`, unchanged) and what the
## BOARD already had (`baseline`). The worker put that partition on the wire
## and PCBPanel.gd's `_connectivity_status_suffix` threw the second half away
## at the last step — a dirty board's pre-existing violations were invisible
## next to a clean proposal, and worse, an INDETERMINATE baseline (base DRC
## run itself faulted) had no rendering path at all.
##
## THE TRAP this suite exists to lock (project hint 019fa0e84932): `baseline`
## is present on BOTH the determinate and indeterminate top-level branches of
## `_attach_route_drc` — checking for its presence protects nothing. What
## goes absent is ONE LEVEL DOWN: an indeterminate baseline
## ({"clean": null, "error": str}) carries NO `violation_count` key. Reading
## `int(baseline.get("violation_count", 0))` unconditionally renders "0
## pre-existing" for a board whose state is UNKNOWN — a confident wrong
## answer. Test 4 below is the load-bearing one: it fails if that shortcut
## ever gets reintroduced.
##
## Run (via a Minerva scaffold as the Godot host — NEVER the live checkout):
##   godot --headless --path <minerva-scaffold>/src \
##     --script res://../../minerva-plugins/pcb/tests/gd/test_connectivity_baseline_surface.gd
##
## Testing-seam: `_connectivity_status_suffix` (and its `_baseline_suffix`
## helper) is a `static func` reading no `self` state — same seam
## `test_geometric_drc_surface.gd` established for its sibling — so every
## test here drives it with plain fixture dictionaries, no panel/host needed.
##
## Coverage:
##   1. determinate clean proposal + determinate clean baseline
##   2. determinate clean proposal + baseline WITH pre-existing violations
##      ("0 introduced / 3 pre-existing" — a dirty board must not make a
##      clean proposal look dirty)
##   3. determinate violations + determinate baseline
##   4. INDETERMINATE baseline (no violation_count) -> renders "unknown", and
##      the rendered string must carry NO digit and must not borrow the
##      determinate-empty label ("none")
##   5. indeterminate top-level `clean` (post run faulted) with a
##      DETERMINATE baseline (base run succeeded on its own) -> the board's
##      known state is still reported; the proposal half reads unavailable
##   6. absent `drc_summary` entirely -> still returns "" (unchanged)
##   7. baseline key absent from an otherwise-determinate summary (older
##      worker that never emitted the partition) -> no parenthetical, exact
##      pre-partition rendering preserved
##   8. connectivity (with baseline) and geometric fragments remain two
##      distinguishable, non-blended substrings on the combined status line

const PCBPanel := preload("res://../../minerva-plugins/pcb/ui/PCBPanel.gd")

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== Connectivity DRC baseline surface (019f9da15929) ===\n")
	_run_clean_proposal_clean_baseline()
	_run_clean_proposal_dirty_baseline()
	_run_violations_with_determinate_baseline()
	_run_indeterminate_baseline()
	_run_indeterminate_top_level_determinate_baseline()
	_run_absent_summary()
	_run_absent_baseline_key()
	_run_both_scopes_distinguishable()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


# ── assertion helpers ─────────────────────────────────────────────────────────

## True if `s` contains any decimal digit. Used by test 4 to prove an
## indeterminate baseline renders NO count at all — stronger and more durable
## than naming one forbidden literal, which goes stale the moment the rendered
## vocabulary changes.
func _has_digit(s: String) -> bool:
	for c in s:
		if c >= "0" and c <= "9":
			return true
	return false


func check(desc: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s" % desc)


func check_eq(desc: String, actual, expected) -> void:
	check("%s (expected %s, got %s)" % [desc, str(expected), str(actual)], actual == expected)


# ── 1: determinate clean proposal, determinate clean baseline ─────────────────

func _run_clean_proposal_clean_baseline() -> void:
	print("-- 1. clean proposal + clean baseline --")
	var result := {"drc_summary": {"scope": "connectivity", "clean": true,
		"violation_count": 0,
		"baseline": {"clean": true, "violation_count": 0, "findings": []}}}
	var s := PCBPanel._connectivity_status_suffix(result)
	check_eq("renders clean proposal with a clean baseline", s,
		" — Connectivity clean (pre-existing: none)")


# ── 2: determinate clean proposal, baseline WITH pre-existing violations ──────

func _run_clean_proposal_dirty_baseline() -> void:
	print("-- 2. clean proposal + dirty baseline (0 introduced / 3 pre-existing) --")
	var baseline_findings: Array = []
	for i in range(3):
		baseline_findings.append({"type": "crossing"})
	var result := {"drc_summary": {"scope": "connectivity", "clean": true,
		"violation_count": 0,
		"baseline": {"clean": false, "violation_count": 3, "findings": baseline_findings}}}
	var s := PCBPanel._connectivity_status_suffix(result)
	check_eq("a dirty board does not make a clean proposal look dirty", s,
		" — Connectivity clean (pre-existing: 3)")


# ── 3: determinate violations, determinate baseline ────────────────────────────

func _run_violations_with_determinate_baseline() -> void:
	print("-- 3. violations proposal + determinate baseline --")
	var result := {"drc_summary": {"scope": "connectivity", "clean": false,
		"violation_count": 2,
		"baseline": {"clean": true, "violation_count": 0, "findings": []}}}
	var s := PCBPanel._connectivity_status_suffix(result)
	check_eq("renders both the introduced count and the baseline count", s,
		" — Connectivity: 2 violations (pre-existing: none)")


# ── 4: INDETERMINATE baseline — the load-bearing test ─────────────────────────

func _run_indeterminate_baseline() -> void:
	print("-- 4. indeterminate baseline renders unknown, NEVER a 0 count --")
	# Mirrors methods.py: when the base DRC run itself faults, error is always
	# set (post_error or a synthesized message), so the top-level clean is
	# also None here — this is the shape _attach_route_drc actually produces.
	var result := {"drc_summary": {"scope": "connectivity", "clean": null,
		"error": "connectivity baseline could not be computed: kaboom",
		"baseline": {"clean": null, "error": "kaboom"}}}
	var s := PCBPanel._connectivity_status_suffix(result)
	check_eq("renders the fail-closed 'unknown' baseline label", s,
		" — Connectivity: unavailable (pre-existing: unknown)")
	# The load-bearing assertion: an indeterminate baseline must never render as
	# a count, and MUST NOT be confused with a real, determinate empty result.
	#
	# THESE GUARDS TRACK THE RENDERED VOCABULARY AND MUST BE UPDATED WITH IT.
	# They once read `not s.contains("pre-existing: 0")`, which went VACUOUS the
	# moment the determinate-empty rendering changed from "0" to "none" — the
	# assertion kept passing while guarding nothing. Whatever string the
	# determinate-empty case renders, THAT is what this test must prove absent
	# here; a guard naming a string the code can no longer emit is not a guard.
	check("does not render the determinate-empty label ('none')",
		not s.contains("pre-existing: none"))
	check("does not contain a digit anywhere (no invented pre-existing count)",
		not _has_digit(s))


# ── 5: indeterminate top-level clean, DETERMINATE baseline ────────────────────

func _run_indeterminate_top_level_determinate_baseline() -> void:
	print("-- 5. post run faulted but the base run succeeded independently --")
	# Per methods.py's own docstring: "the baseline half is answerable on its
	# own: the base run can succeed even when the post run faults, and
	# reporting the board's real state then is strictly better than
	# withholding it." No top-level violation_count (the proposal question
	# has no answer), but baseline carries a real, determinate count.
	var result := {"drc_summary": {"scope": "connectivity", "clean": null,
		"error": "post-proposal drc run faulted",
		"baseline": {"clean": false, "violation_count": 3, "findings": []}}}
	var s := PCBPanel._connectivity_status_suffix(result)
	check_eq("proposal half reads unavailable, baseline half reports its known state",
		s, " — Connectivity: unavailable (pre-existing: 3)")


# ── 6: absent drc_summary entirely — unchanged behaviour ──────────────────────

func _run_absent_summary() -> void:
	print("-- 6. absent drc_summary renders empty string (unchanged) --")
	var s := PCBPanel._connectivity_status_suffix({})
	check_eq("missing key renders empty string", s, "")
	var s2 := PCBPanel._connectivity_status_suffix({"drc_summary": {}})
	check_eq("explicit empty dict also renders empty string", s2, "")


# ── 7: baseline key itself absent (older worker) — no parenthetical ───────────

func _run_absent_baseline_key() -> void:
	print("-- 7. an older worker's summary with no baseline key renders unchanged --")
	var result := {"drc_summary": {"scope": "connectivity", "clean": true}}
	var s := PCBPanel._connectivity_status_suffix(result)
	check_eq("no baseline key -> no parenthetical, pre-partition rendering preserved",
		s, " — Connectivity clean")


# ── 8: connectivity (with baseline) and geometric stay distinguishable ────────

func _run_both_scopes_distinguishable() -> void:
	print("-- 8. connectivity+baseline and geometric remain non-blended substrings --")
	var result := {
		"drc_summary": {"scope": "connectivity", "clean": true, "violation_count": 0,
			"baseline": {"clean": false, "violation_count": 3, "findings": []}},
		"drc_geometric_summary": {"ok": true, "scope": "geometric_candidate",
			"verifies_geometry": true, "verdict": "violations",
			"findings": [{"type": "clearance"}, {"type": "clearance"}],
			"counts": {"clearance": 2},
			"per_candidate": {"route[0]": {"revision": null, "verdict": "violations",
				"finding_count": 2}},
			"baseline": {"verdict": "clean", "findings": [], "counts": {}}},
	}
	var s := PCBPanel._drc_status_suffix(result)
	check("carries the connectivity fragment with its baseline parenthetical",
		s.contains("Connectivity clean (pre-existing: 3)"))
	check("carries the geometric fragment", s.contains("Geometric: 2 violations"))
	# The baseline parenthetical is part of the connectivity fragment (not a
	# third " — " scope), so exactly two separators: one per top-level scope.
	check_eq("exactly two ' — ' separators (one per scope, baseline is not a third)",
		s.count(" — "), 2)
	# ORDER, not just presence. `contains` and a separator count are both
	# order-blind: an adversarial review swapped _drc_status_suffix's two
	# operands and every assertion above still passed, while the user-visible
	# chip silently reversed. Connectivity is the cheaper, always-available
	# check and reads first; geometric is the complement added BESIDE it, never
	# in front of it. Assert the whole line so the ordering cannot drift
	# unobserved — this is the only test that sees both fragments at once.
	check("connectivity fragment precedes the geometric one",
		s.find("Connectivity") < s.find("Geometric"))
	check_eq("full combined status line, in order", s,
		" — Connectivity clean (pre-existing: 3) — Geometric: 2 violations")
