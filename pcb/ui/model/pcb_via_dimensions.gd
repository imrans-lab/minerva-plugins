extends RefCounted
## PcbViaDimensions — THE one rule for how big a via's pad and drill are.
##
## Every via this plugin creates — a router candidate's layer-change via, a
## standalone `minerva_pcb_propose_via` ghost, a bus station via, the copper a
## commit writes — takes its diameter and drill from the SAME place: the board's
## authored `design_rules` (`via_diameter_mm` / `via_drill_mm`), with an explicit
## per-call override outranking them and a last-resort constant only when the
## board declares nothing.
##
## ── 0.0 IS THE ONLY "NOBODY HAS SAID YET" ────────────────────────────────────
## The size is resolved at PROPOSAL time, here, and never rescued downstream: a
## rescue can only recognise an unset value, so a non-zero default stamped
## anywhere upstream survives it. A via born at 0.8 renders and commits at 0.8 on
## a board whose rules say 0.6, while the direct-commit paths (bus_commit_plan,
## place_via) honour 0.6 — two paths, one hole, two answers. Callers that have no
## board pass {} and get the constants: the honest headless answer, not a silent
## override of real rules.
##
## Off-tree plugin: NO class_name; reached by relative preload.

## Last-resort pad diameter, mm — used ONLY when neither the caller nor the
## board's design_rules names one. Matches the value the direct-commit paths
## have always fallen back to, so removing the scattered literals changed no
## board that never authored a rule.
const DEFAULT_DIAMETER_MM := 0.8

## Last-resort drill diameter, mm. Same contract as DEFAULT_DIAMETER_MM.
const DEFAULT_DRILL_MM := 0.4


## Resolve {diameter, drill} in mm from a board's `design_rules` dictionary.
##
## Precedence, highest first:
##   1. `diameter_mm` / `drill_mm` — an explicit per-call size. > 0.0 only;
##      0.0 (the default) means "not specified", never "zero-sized".
##   2. `design_rules.via_diameter_mm` / `via_drill_mm` — the board's authored
##      rule, which is what acceptance writes.
##   3. DEFAULT_DIAMETER_MM / DEFAULT_DRILL_MM.
##
## The two axes resolve INDEPENDENTLY: a board that authors a diameter but no
## drill gets its diameter and the constant drill, rather than being pushed
## wholesale to one tier or the other.
static func resolve(design_rules, diameter_mm: float = 0.0, drill_mm: float = 0.0) -> Dictionary:
	var dr: Dictionary = design_rules if design_rules is Dictionary else {}
	var diameter := diameter_mm
	if diameter <= 0.0:
		diameter = float(dr.get("via_diameter_mm", 0.0))
	if diameter <= 0.0:
		diameter = DEFAULT_DIAMETER_MM
	var drill := drill_mm
	if drill <= 0.0:
		drill = float(dr.get("via_drill_mm", 0.0))
	if drill <= 0.0:
		drill = DEFAULT_DRILL_MM
	return {"diameter": diameter, "drill": drill}


## resolve() against a live board object (duck-typed: anything exposing a
## `design_rules` property). A null/rule-less board resolves to the constants —
## the same answer a headless caller gets, so a test fixture and a mounted panel
## never disagree about a board that authored nothing.
static func from_board(board, diameter_mm: float = 0.0, drill_mm: float = 0.0) -> Dictionary:
	var dr = null
	# `in` rather than a bare property read: `board` is duck-typed, and a stub
	# board in a headless fixture legitimately has no design_rules at all.
	if board != null and is_instance_valid(board) and "design_rules" in board:
		dr = board.design_rules
	return resolve(dr, diameter_mm, drill_mm)
