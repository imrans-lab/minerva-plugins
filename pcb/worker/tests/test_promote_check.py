"""The K13 promotion gate (Epoch UX3 station 11, docket 019fdf91b3ac).

``promote_check`` composes the full authoritative verdict — connectivity DRC,
geometric DRC (GC1-GC7) and the assembly tri-state — FAIL CLOSED: promotable
only when every check ran to a determinate clean/pass. "Could not check" is a
refusal, never a pass; there is no acknowledge-through anywhere in the gate.

Synthetic boards per ``testdata/POLICY.md``.
"""

from __future__ import annotations

import copy

from pcb_worker.methods import _HANDLERS


def _call(board) -> dict:
    return _HANDLERS["promote_check"]({"params": {"board": board}})


def _clean_board() -> dict:
    """Two parts, one net, one generous routed trace — clean end to end."""
    return {
        "version": 1, "name": "promote-clean", "width_mm": 30, "height_mm": 20,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [
            {"ref": "R1", "footprint": "R_0805", "x_mm": 5, "y_mm": 10,
             "rotation_deg": 0, "layer": "top"},
            {"ref": "R2", "footprint": "R_0805", "x_mm": 25, "y_mm": 10,
             "rotation_deg": 0, "layer": "top"},
        ],
        "nets": [{"name": "SIG", "pins": ["R1.2", "R2.1"]}],
        "traces": [{"net": "SIG", "layer": "top", "width_mm": 0.3,
                    "points": [{"x_mm": 5.95, "y_mm": 10.0},
                               {"x_mm": 24.05, "y_mm": 10.0}]}],
    }


def test_clean_board_is_promotable():
    reply = _call(_clean_board())
    assert reply["ok"] is True
    res = reply["result"]
    assert res["refusals"] == [], res["refusals"]
    assert res["promotable"] is True
    # The three sub-reports ride whole, so a caller can SHOW findings.
    assert res["geometric"]["verdict"] == "clean"
    assert res["assembly"]["status"] == "pass"
    assert res["connectivity"].get("findings", []) == []


def test_geometric_violation_refuses_by_name():
    board = _clean_board()
    board["traces"][0]["width_mm"] = 0.05   # under every min-width floor
    res = _call(board)["result"]
    assert res["promotable"] is False
    assert any("geometric" in r for r in res["refusals"]), res["refusals"]


def test_unparseable_board_is_a_refusal_never_a_pass():
    res = _call({"nonsense": True})["result"]
    assert res["promotable"] is False
    assert res["refusals"], "an unverifiable board must name its refusals"


def test_connectivity_finding_refuses():
    board = _clean_board()
    # Second net whose trace CROSSES the first on the same layer.
    board["nets"].append({"name": "SIG2", "pins": []})
    board["traces"].append({"net": "SIG2", "layer": "top", "width_mm": 0.3,
                            "points": [{"x_mm": 15.0, "y_mm": 5.0},
                                       {"x_mm": 15.0, "y_mm": 15.0}]})
    res = _call(board)["result"]
    assert res["promotable"] is False
    assert res["refusals"], res


def test_unrouted_board_promotes_with_completeness_advisory():
    """DELIBERATELY REVERSED (Epoch UX4 station 9, DCR 019fe07523ca S6 —
    OWNER RULING 1, epoch record 019fe06d282d comment 1059: "promotion should
    be granular. For example, I might promote a GND trace, but not another
    trace because I want to move a component").

    This test previously pinned UX3 cold-review F1's reading — "an unrouted
    board is not a design of record" — as a REFUSAL. The owner ruled that
    reading conflates "wrong" with "not finished": a clean-but-partial board
    PROMOTES, and the census's absence-detection (the F1 machinery, fully
    intact) now surfaces as result.advisory.completeness naming the unrouted
    nets. Indeterminate census still refuses (correctness stays absolute —
    see test_indeterminate_census_still_refuses below)."""
    board = _clean_board()
    board["traces"] = []
    res = _call(board)["result"]
    assert res["promotable"] is True, res["refusals"]
    assert res["refusals"] == [], res["refusals"]
    adv = res.get("advisory", {}).get("completeness")
    assert adv is not None, "the unrouted nets must ride the advisory block"
    assert adv["complete"] is False
    assert "SIG" in [str(n) for n in adv["missing_copper"]]


def test_complete_board_reply_carries_no_advisory_block():
    """Absent-when-empty: a fully routed board's reply is byte-identical to
    the pre-UX4 shape — no advisory key at all."""
    res = _call(_clean_board())["result"]
    assert "advisory" not in res, res.get("advisory")


def test_indeterminate_census_still_refuses():
    """The ruling's own boundary: completeness (False) is advisory, but an
    INDETERMINATE census (complete is None — the census could not run) is a
    correctness problem and still refuses. Vehicle: a net pin naming a
    component that does not exist makes the census unverifiable."""
    board = _clean_board()
    board["nets"][0]["pins"] = ["NOPE.1", "R2.1"]
    res = _call(board)["result"]
    complete = res["connectivity"].get("complete")
    if complete is None:
        assert res["promotable"] is False
        assert any("indeterminate" in r for r in res["refusals"]), res["refusals"]
    else:
        # If the census resolves this board after all, the case is moot for
        # this vehicle — but it must NOT have promoted with a phantom pin
        # unverified: either a finding or an advisory must have surfaced.
        assert (res["refusals"] or res.get("advisory")), res


def test_caller_knobs_cannot_weaken_the_gate():
    """Cold review F5: the gate builds its own sub-check params — a caller's
    resolve_geometry:false (or any other knob) must not ride through.
    RE-VEHICLED with station 9 (the old vehicle was the unrouted refusal,
    which the owner ruling made advisory): a geometric VIOLATION is the
    correctness refusal a knob must never suppress."""
    board = _clean_board()
    board["traces"][0]["width_mm"] = 0.05   # under every min-width floor
    reply = _HANDLERS["promote_check"]({"params": {
        "board": board, "resolve_geometry": False}})
    res = reply["result"]
    assert res["promotable"] is False, (
        "the geometric refusal must hold regardless of caller knobs")
    assert any("geometric" in r for r in res["refusals"]), res["refusals"]


def test_non_dict_board_refuses_uniformly():
    """Cold review F7: the gate's input contract is one canonical board dict —
    a {yaml:...} payload refuses up front, not after two green legs."""
    reply = _HANDLERS["promote_check"]({"params": {"yaml": "name: x"}})
    res = reply["result"]
    assert res["promotable"] is False
    assert "canonical board dict" in str(res["refusals"])
