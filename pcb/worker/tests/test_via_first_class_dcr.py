"""Characterization + requirement tests for DCR 01a0033a12a9 — "a via is a
first-class entity, not an edit to a trace".

RUN BEFORE THE CHANGE, deliberately. Every question here is about what the code
does TODAY; running them after the DCR lands would conflate "this was always
true" with "the change made it true". Two of the three assert a REQUIREMENT the
owner stated and which must hold forever; the third CHARACTERIZES a known gap
and is expected to flip, on purpose, when a fabrication-stage signal lands.

Owner's concern, verbatim: "my concern in DRC is equally false positive. A
complete path that has a via added later, even if no layer jump in trace, is
still a valid path."
"""

from __future__ import annotations

from pcb_worker import drc


def _complete_net_board() -> dict:
    """R1.1 -> R2.1 on SIG, joined by ONE continuous top-layer trace.

    Deliberately a SINGLE segment pad-to-pad: the net is already complete before
    any via is added, so anything the via provokes is a false positive by
    construction.
    """
    return {
        "version": 1, "name": "viafirst", "width_mm": 30, "height_mm": 20,
        "components": [
            {"ref": "R1", "footprint": "R", "x_mm": 5, "y_mm": 10,
             "layer": "top", "pins": [{"number": "1", "x_mm": 0, "y_mm": 0,
                                       "pad_width_mm": 1.0, "pad_height_mm": 1.0}]},
            {"ref": "R2", "footprint": "R", "x_mm": 25, "y_mm": 10,
             "layer": "top", "pins": [{"number": "1", "x_mm": 0, "y_mm": 0,
                                       "pad_width_mm": 1.0, "pad_height_mm": 1.0}]}],
        "nets": [{"name": "SIG", "pins": ["R1.1", "R2.1"]}],
        "traces": [
            {"net": "SIG", "layer": "top", "width_mm": 0.25,
             "points": [{"x_mm": 5, "y_mm": 10}, {"x_mm": 25, "y_mm": 10}]}],
        "vias": [],
    }


# ── REQUIREMENT 1 ────────────────────────────────────────────────────────────

def test_a_via_on_an_already_complete_same_net_path_is_clean():
    """THE OWNER'S CASE. A complete top-layer path, then a via dropped onto it
    on the SAME net, with no layer change anywhere. That is a valid board — a
    test point, a stitching via, or a hole placed now to be routed against
    later. It must not produce a finding of any kind."""
    before = drc.run_drc(_complete_net_board())
    assert before["findings"] == [], f"fixture was not clean to begin with: {before}"
    assert before["complete"] is True

    board = _complete_net_board()
    board["vias"] = [{"x_mm": 15, "y_mm": 10, "drill_mm": 0.4,
                      "diameter_mm": 0.8, "from_layer": "top",
                      "to_layer": "bottom", "net": "SIG"}]
    after = drc.run_drc(board)

    assert after["findings"] == [], (
        "a via added to an already-complete same-net path was reported as a "
        f"violation: {after['findings']}")
    assert after["complete"] is True, "the via made a complete net read incomplete"


def test_the_same_via_with_no_net_declared_is_also_clean():
    """The same placement, but the via carries no net — the shape the canvas Via
    tool produces today, since it places an unassigned via. It sits on SIG's
    copper and must still not be a finding."""
    board = _complete_net_board()
    board["vias"] = [{"x_mm": 15, "y_mm": 10, "drill_mm": 0.4,
                      "diameter_mm": 0.8, "from_layer": "top",
                      "to_layer": "bottom"}]
    result = drc.run_drc(board)
    assert result["findings"] == [], result["findings"]
    assert result["complete"] is True


# ── REQUIREMENT 2 ────────────────────────────────────────────────────────────

def test_a_netless_via_does_not_merge_two_distinct_complete_nets():
    """drc.py:618 unions a NETLESS via deliberately. That union must not make
    two separate complete nets read as one — a false short, or a false
    completeness on a net that is not actually joined."""
    board = _complete_net_board()
    board["components"].append(
        {"ref": "R3", "footprint": "R", "x_mm": 5, "y_mm": 16, "layer": "top",
         "pins": [{"number": "1", "x_mm": 0, "y_mm": 0,
                   "pad_width_mm": 1.0, "pad_height_mm": 1.0}]})
    board["components"].append(
        {"ref": "R4", "footprint": "R", "x_mm": 25, "y_mm": 16, "layer": "top",
         "pins": [{"number": "1", "x_mm": 0, "y_mm": 0,
                   "pad_width_mm": 1.0, "pad_height_mm": 1.0}]})
    board["nets"].append({"name": "OTHER", "pins": ["R3.1", "R4.1"]})
    board["traces"].append(
        {"net": "OTHER", "layer": "top", "width_mm": 0.25,
         "points": [{"x_mm": 5, "y_mm": 16}, {"x_mm": 25, "y_mm": 16}]})
    # Netless, sitting on SIG's copper and nowhere near OTHER's.
    board["vias"] = [{"x_mm": 15, "y_mm": 10, "drill_mm": 0.4,
                      "diameter_mm": 0.8, "from_layer": "top",
                      "to_layer": "bottom"}]

    result = drc.run_drc(board)
    assert result["findings"] == [], result["findings"]
    assert result["complete"] is True, "a netless via broke completeness"
    shorts = [f for f in (result.get("findings") or [])
              if "short" in str(f.get("type", "")).lower()]
    assert shorts == [], f"a netless via produced a false short: {shorts}"


# ── CHARACTERIZATION (expected to flip when a fabrication stage lands) ───────

def test_CHARACTERIZATION_a_via_only_board_reports_incomplete_today():
    """A VIA-ONLY BOARD: nets declared, vias placed, NO traces at all. This is a
    real deliverable — fiber-laser users cannot drill vias, so they order the
    holes and lase the copper in a second step.

    THIS TEST DOCUMENTS A GAP, IT DOES NOT BLESS IT. The board is correct and
    the pipeline has no way to know that, so it reports the nets as unrouted.
    When the DCR's fabrication-stage signal lands, this assertion FLIPS on
    purpose — it is written so that flip is deliberate and visible in a diff
    rather than looking like a regression."""
    board = _complete_net_board()
    board["traces"] = []
    board["vias"] = [
        {"x_mm": 5, "y_mm": 10, "drill_mm": 0.4, "diameter_mm": 0.8,
         "from_layer": "top", "to_layer": "bottom", "net": "SIG"},
        {"x_mm": 25, "y_mm": 10, "drill_mm": 0.4, "diameter_mm": 0.8,
         "from_layer": "top", "to_layer": "bottom", "net": "SIG"}]

    result = drc.run_drc(board)
    # Recorded, not endorsed:
    assert result["complete"] is False, (
        "a via-only board now reports COMPLETE — if a fabrication stage "
        "landed, rewrite this test to assert the new behaviour deliberately")
    print("\nVIA-ONLY BOARD reports:",
          {k: result.get(k) for k in ("complete", "missing_copper", "counts")},
          "findings:", result["findings"])


# ── REQUIREMENT 3: the GEOMETRIC half of the owner's concern ────────────────
#
# run_drc above is connectivity-only (verifies_geometry: False). The remaining
# false-positive candidate lives in the geometric kernel: does a via sitting ON
# ITS OWN NET'S copper take the same-net exemption, or does it read as a
# hole-to-copper clearance violation? drc_geometric.py:340 names such an
# exemption; this proves it reaches the via/trace pair and not only pad/trace.

from pcb_worker.compile_board import compile_board
from pcb_worker.drc_geometric import run_geometric_drc
from pcb_worker.resolved_board import ResolutionSuccess


def _geometric(board: dict):
    result = compile_board(board)
    assert isinstance(result, ResolutionSuccess), [
        d.code for d in result.diagnostics]
    return run_geometric_drc(result.board)


def _compilable_board() -> dict:
    """The connectivity fixture cannot compile (no design_rules, and 'R' is not
    a resolvable footprint), so the geometric half uses the shape
    test_drc_geometric.py's own _base/_th_pad_comp builders use: declared design
    rules, and pads carried by through-hole pin geometry."""
    return {
        "version": 1, "name": "viafirst_geom", "width_mm": 40, "height_mm": 40,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [
            {"ref": "U1", "footprint": "TH_TestPoint", "x_mm": 10.0,
             "y_mm": 10.0, "rotation_deg": 0.0, "layer": "top",
             "pins": [{"number": "1", "x_mm": 0, "y_mm": 0,
                       "drill_mm": 0.5, "annulus_diameter_mm": 1.2}]},
            {"ref": "U2", "footprint": "TH_TestPoint", "x_mm": 30.0,
             "y_mm": 10.0, "rotation_deg": 0.0, "layer": "top",
             "pins": [{"number": "1", "x_mm": 0, "y_mm": 0,
                       "drill_mm": 0.5, "annulus_diameter_mm": 1.2}]}],
        "nets": [{"name": "SIG", "pins": ["U1.1", "U2.1"]}],
        "traces": [
            {"net": "SIG", "layer": "top", "width_mm": 0.3,
             "points": [{"x_mm": 10, "y_mm": 10}, {"x_mm": 30, "y_mm": 10}]}],
        "vias": [],
    }


def test_a_same_net_via_on_its_own_trace_is_geometrically_clean():
    """THE OWNER'S CASE, geometric half. A via placed on the copper it belongs
    to must not be a clearance violation against that copper — every board with
    a stitching via or a test point would be unfabricable otherwise."""
    clean = _geometric(_compilable_board())
    assert (clean.get("findings") or []) == [], (
        f"fixture was not geometrically clean before the via: {clean}")

    board = _compilable_board()
    board["vias"] = [{"x_mm": 20, "y_mm": 10, "drill_mm": 0.4,
                      "diameter_mm": 0.8, "from_layer": "top",
                      "to_layer": "bottom", "net": "SIG"}]
    result = _geometric(board)
    hole_findings = [f for f in (result.get("findings") or [])
                     if "hole" in str(f.get("code", f.get("type", ""))).lower()]
    assert hole_findings == [], (
        "a same-net via on its own trace was flagged by a hole/clearance "
        f"check: {hole_findings}")
    print("\nSAME-NET VIA ON OWN TRACE, geometric verdict:",
          result.get("verdict"), "| findings:", result.get("findings"))
