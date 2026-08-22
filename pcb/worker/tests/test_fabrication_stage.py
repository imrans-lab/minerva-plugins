"""Declared fabrication stage vs the connectivity census (DCR 01a0033a12a9 ch. 3).

A via-only board has every net unrouted BY DESIGN — fiber-laser users cannot
drill, so they order a drilled, plated board and lase the copper runs later.
Before the stage existed the census had no vocabulary for that: the customer's
CORRECT board reported a wall of ``missing_copper``, indistinguishable from a
job someone abandoned half-routed.

What these tests pin is the line between DECLARING and SUPPRESSING, because
that line is the entire design and it is the thing a future refactor is most
likely to erase:

  * the stage reclassifies the completeness verdict;
  * it NEVER empties the lists, so nothing is hidden;
  * it NEVER touches the violation checks, which report copper that is WRONG
    rather than copper that is ABSENT.
"""

from pcb_worker import drc


def _unrouted_board(stage=None):
    """Two declared 2-pin nets and NO copper at all — the via-only shape.

    Every net is `missing_copper` on any stage; what differs is whether that
    counts as a defect.
    """
    board = {
        "name": "viasonly", "width_mm": 30, "height_mm": 20,
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.25},
        "components": [
            {"ref": "R1", "footprint": "R", "x_mm": 5, "y_mm": 10,
             "layer": "top",
             "pins": [{"number": "1", "x_mm": 0, "y_mm": 0,
                       "pad_width_mm": 1.0, "pad_height_mm": 1.0},
                      {"number": "2", "x_mm": 2, "y_mm": 0,
                       "pad_width_mm": 1.0, "pad_height_mm": 1.0}]},
            {"ref": "R2", "footprint": "R", "x_mm": 25, "y_mm": 10,
             "layer": "top",
             "pins": [{"number": "1", "x_mm": 0, "y_mm": 0,
                       "pad_width_mm": 1.0, "pad_height_mm": 1.0},
                      {"number": "2", "x_mm": 2, "y_mm": 0,
                       "pad_width_mm": 1.0, "pad_height_mm": 1.0}]}],
        "nets": [{"name": "N1", "pins": ["R1.1", "R2.1"]},
                 {"name": "N2", "pins": ["R1.2", "R2.2"]}],
        "traces": [],
        "vias": [{"x_mm": 15, "y_mm": 10, "drill_mm": 0.4, "diameter_mm": 0.8,
                  "from_layer": "top", "to_layer": "bottom"}],
    }
    if stage is not None:
        board["fabrication_stage"] = stage
    return board


def _shorting_board(stage):
    """A deferred board carrying a REAL violation: a trace on N1 driven

    straight over R2's N2 pad centre. wrong_net_pad must still fire — the
    stage excuses absent copper, never wrong copper.
    """
    board = _unrouted_board(stage)
    # routing_deferred, not vias_only: this board has a trace, and the write
    # gate refuses a vias_only board that carries one.
    board["fabrication_stage"] = stage
    board["traces"] = [
        {"net": "N1", "layer": "top", "width_mm": 0.25,
         "points": [{"x_mm": 5, "y_mm": 10}, {"x_mm": 27, "y_mm": 10}]}]
    return board


# --------------------------------------------------------------------------
# The declaration itself.
# --------------------------------------------------------------------------


def test_absent_stage_is_routed():
    """An undeclared board IS a routed board — the two must be the same board
    everywhere, or every pre-existing board silently changes meaning."""
    assert drc.fabrication_stage({}) == drc.FAB_STAGE_ROUTED
    assert drc.fabrication_stage({"fabrication_stage": ""}) == drc.FAB_STAGE_ROUTED
    assert drc.routing_is_deferred({}) is False


def test_routing_is_deferred_is_the_one_predicate():
    for stage, want in [(None, False), ("routed", False),
                        ("routing_deferred", True), ("vias_only", True)]:
        board = {} if stage is None else {"fabrication_stage": stage}
        assert drc.routing_is_deferred(board) is want, stage


def test_unknown_token_reads_as_routed_not_as_deferred():
    """The conservative direction. The Go write gate refuses an unknown token,
    so this only fires on a board that bypassed it — and the safe reading is
    the one where an unrouted net stays a DEFECT. A fallback the other way
    would silently excuse a board nobody meant to excuse."""
    assert drc.routing_is_deferred({"fabrication_stage": "vias-only"}) is False


# --------------------------------------------------------------------------
# What the stage changes.
# --------------------------------------------------------------------------


def test_routed_board_reports_unrouted_nets_as_incomplete():
    """The pre-DCR behaviour, pinned so the new branch cannot quietly become
    the only branch."""
    for board in (_unrouted_board(), _unrouted_board("routed")):
        census = drc.connectivity_completeness(board)
        assert census["complete"] is False
        assert census["missing_copper"] == ["N1", "N2"]
        assert census["routing_deferred"] is False
        assert census["expected_incomplete"] is False


def test_deferred_board_reports_the_same_nets_as_intended():
    for stage in ("routing_deferred", "vias_only"):
        census = drc.connectivity_completeness(_unrouted_board(stage))
        assert census["complete"] is True, stage
        # THE LOAD-BEARING ASSERTION. `complete: True` is only honest because
        # the nets are still named. A refactor that "simplified" this by
        # skipping the census on a deferred board would pass every other
        # assertion in this file and fail exactly here.
        assert census["missing_copper"] == ["N1", "N2"], stage
        assert census["expected_incomplete"] is True, stage
        assert census["fabrication_stage"] == stage
        assert census["routing_deferred"] is True


def test_deferred_but_fully_routed_board_is_not_flagged_as_expected_incomplete():
    """`expected_incomplete` means "deferred AND something is unrouted". A
    deferred board that happens to be finished has nothing to excuse."""
    board = _unrouted_board("routing_deferred")
    board["traces"] = [
        {"net": n, "layer": "top", "width_mm": 0.25,
         "points": [{"x_mm": 5 + i * 2, "y_mm": 10},
                    {"x_mm": 25 + i * 2, "y_mm": 10}]}
        for i, n in enumerate(("N1", "N2"))]
    census = drc.connectivity_completeness(board)
    assert census["complete"] is True
    assert census["missing_copper"] == []
    assert census["expected_incomplete"] is False


# --------------------------------------------------------------------------
# What the stage must NOT change. This is the suppression boundary.
# --------------------------------------------------------------------------


def test_violation_checks_still_fire_on_a_deferred_board():
    """A stage excuses copper that is ABSENT, never copper that is WRONG.

    If this ever goes green-by-silence the DCR's central promise is broken:
    declaring a stage would have become a way to mute DRC.
    """
    routed = drc.run_drc(_shorting_board("routed"))
    deferred = drc.run_drc(_shorting_board("routing_deferred"))
    assert routed["counts"]["wrong_net_pad"] > 0, "fixture must actually short"
    assert deferred["counts"]["wrong_net_pad"] == routed["counts"]["wrong_net_pad"]
    assert len(deferred["findings"]) == len(routed["findings"])


def test_run_drc_carries_the_declaration_only_on_a_deferred_board():
    """Absent-key convention: a routed board's reply shape is byte-unchanged,
    and a deferred board can never report `complete` without the reason."""
    routed = drc.run_drc(_unrouted_board("routed"))
    assert "fabrication_stage" not in routed
    assert "routing_deferred" not in routed
    assert routed["complete"] is False

    deferred = drc.run_drc(_unrouted_board("vias_only"))
    assert deferred["complete"] is True
    assert deferred["fabrication_stage"] == "vias_only"
    assert deferred["routing_deferred"] is True
    assert deferred["expected_incomplete"] is True
    assert deferred["missing_copper"] == ["N1", "N2"]


# --------------------------------------------------------------------------
# SR2FAB S9 — the declaration outliving the board it described.
# --------------------------------------------------------------------------


def _promote_check(board: dict) -> dict:
    from pcb_worker.methods import handle_request

    resp = handle_request({"id": "pc1", "method": "promote_check",
                           "params": {"board": board}})
    assert resp is not None and resp["id"] == "pc1"
    assert resp["ok"] is True, resp
    return resp["result"]


def test_a_deferred_board_that_has_since_been_routed_says_so():
    """SR2FAB S9. `routing_deferred` excuses unrouted nets because the board
    DECLARES routing is not its deliverable. A declaration is authored once and
    then forgotten, so a board that has since had copper laid on it still
    promotes on that excuse — and its census still reads complete:true, reached
    by declaration, on a board whose copper could have earned it honestly.

    ADVISORY only. The granular-promotion and declared-intent rulings stand, so
    this names the incongruence and changes no verdict."""
    board = _unrouted_board("routing_deferred")
    board["traces"] = [
        {"net": "N1", "layer": "top", "width_mm": 0.25,
         "points": [{"x_mm": 5, "y_mm": 10}, {"x_mm": 25, "y_mm": 10}]}]

    result = _promote_check(board)
    incongruence = result.get("advisory", {}).get("stage_incongruence")
    assert incongruence is not None, result.get("advisory")
    assert incongruence["trace_count"] == 1
    assert incongruence["fabrication_stage"] == "routing_deferred"
    # It names the verb that resolves it — an advisory a reader cannot act on
    # is a warning, not a finding.
    assert "minerva_pcb_fabrication_stage" in incongruence["note"]


def test_a_deferred_board_with_no_copper_is_congruent():
    """The whole point of the stage. A via-only board carrying no traces is
    exactly what it declared itself to be, and must not be nagged."""
    result = _promote_check(_unrouted_board("routing_deferred"))
    assert "stage_incongruence" not in result.get("advisory", {})
    # ...and the declared-intent advisory that DOES belong is still there.
    assert result["advisory"]["completeness"]["routing_deferred"] is True


def test_a_routed_board_with_traces_is_congruent():
    """A board that never deferred anything cannot be incongruent with a
    declaration it does not make. Guards the other direction: an advisory keyed
    on trace-count alone would fire on every ordinary board."""
    board = _unrouted_board("routed")
    board["traces"] = [
        {"net": "N1", "layer": "top", "width_mm": 0.25,
         "points": [{"x_mm": 5, "y_mm": 10}, {"x_mm": 25, "y_mm": 10}]}]
    result = _promote_check(board)
    assert "stage_incongruence" not in result.get("advisory", {})


def test_the_incongruence_advisory_changes_no_verdict():
    """NO GATE CHANGE was the station's constraint. The same board's refusals
    are identical whether the advisory fires or not — the only difference is
    that the reply now says which kind of complete it reached."""
    deferred = _unrouted_board("routing_deferred")
    routed_over = _unrouted_board("routing_deferred")
    routed_over["traces"] = [
        {"net": "N1", "layer": "top", "width_mm": 0.25,
         "points": [{"x_mm": 5, "y_mm": 10}, {"x_mm": 25, "y_mm": 10}]}]

    a = _promote_check(deferred)
    b = _promote_check(routed_over)
    assert "stage_incongruence" not in a.get("advisory", {})
    assert "stage_incongruence" in b.get("advisory", {})
    # Both still report the completeness the declaration bought them.
    assert a["advisory"]["completeness"]["complete"] is True
    assert b["advisory"]["completeness"]["complete"] is True
