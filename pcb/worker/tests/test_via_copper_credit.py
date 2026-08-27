"""A VIA IS COPPER WITH EXTENT — what that changes in a DRC reply.

Every credit a via earns used to be a distance from its bare CENTRE to some
other feature's bare centre or endpoint, at the board's clearance. That is not
what a barrel is, and the gap showed up three ways at once:

  * the CENSUS credited a via against a segment's two ENDPOINTS only, so a via
    dropped on a run's INTERIOR — the ordinary way a probe pad is strapped to
    the plane under it — joined nothing, and the net reported an island its
    copper does not have;
  * the DANGLING credit measured a bare point against a bare point, so a wide
    run stopping on a via's annulus read as a loose end;
  * check A (wrong_net_pad) measured a centreline against a pad CENTRE, so an
    unplated mounting hole — copper nowhere, ``*.Cu`` on its pad line — read as
    a short, while a genuine short to the EDGE of a big foreign land did not.

All three now ask :mod:`copper_contact`, the one predicate the panel also runs.
The SHAPE-level agreement between the two sides is pinned by the shared vectors
(``pcb/spec/contact``, cases 200/210); this file is about what the rule changes
in a reply.

Boards here are synthetic and hand-built per ``testdata/POLICY.md``, and every
expected number is derived from the geometry in the docstring beside it.
"""

from __future__ import annotations

import copy

from pcb_worker import drc

CLEARANCE = 0.2


def _smd(number: str, x: float, y: float, w: float, h: float,
         shape: str = "rect", **extra) -> dict:
    pad = {"number": number, "type": "smd", "shape": shape,
           "position": {"x": x, "y": y},
           "size": {"width": w, "height": h},
           "layers": ["F.Cu", "F.Mask", "F.Paste"]}
    pad.update(extra)
    return pad


def _part(ref: str, x: float, y: float, pads: list) -> dict:
    """One component whose inline ``pads`` list is its whole geometry — no seed
    library ref is involved, so the pour below can compile."""
    return {"ref": ref, "footprint": "F", "x_mm": x, "y_mm": y,
            "rotation_deg": 0, "layer": "top",
            "pins": [{"number": p["number"],
                      "x_mm": p["position"]["x"], "y_mm": p["position"]["y"]}
                     for p in pads],
            "pads": pads}


def _probe_pad_strapped_to_a_plane() -> dict:
    """A two-land probe pad joined to the ground plane by ONE mid-run via.

    GND carries six pins in what should be TWO islands:

      * TP1.1 (6.6, 30) and TP1.2 (9.4, 30) — 1.25 x 1.75 lands, joined to each
        other by a 0.5 mm top run between their centres. The only thing joining
        that pair to the rest of the net is a 0.8 mm via at (8.0, 30.0): the
        run's exact midpoint, 1.4 mm from either end, and inside the bottom
        pour. J1's two plated 1.6 mm barrels stand in that same pour.
      * C1.1 (45, 50) and C2.1 (49, 50) — a genuine open, 20 mm clear of the
        plane and joined only to each other.
    """
    return {
        "version": 1, "name": "via-strap-bench",
        "width_mm": 60, "height_mm": 60,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": CLEARANCE, "trace_width_mm": 0.25,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [
            _part("TP1", 8.0, 30.0, [
                _smd("1", -1.4, 0.0, 1.25, 1.75, "roundrect",
                     corner_rratio=0.25),
                _smd("2", 1.4, 0.0, 1.25, 1.75, "roundrect",
                     corner_rratio=0.25)]),
            _part("J1", 20.0, 30.0, [
                {"number": "1", "type": "thru_hole", "shape": "circle",
                 "position": {"x": -2.54, "y": 0.0},
                 "size": {"width": 1.6, "height": 1.6},
                 "drill": {"x": 0.8, "y": 0.8},
                 "layers": ["*.Cu", "*.Mask"]},
                {"number": "2", "type": "thru_hole", "shape": "circle",
                 "position": {"x": 2.54, "y": 0.0},
                 "size": {"width": 1.6, "height": 1.6},
                 "drill": {"x": 0.8, "y": 0.8},
                 "layers": ["*.Cu", "*.Mask"]}]),
            _part("C1", 45.0, 50.0, [_smd("1", 0.0, 0.0, 1.0, 1.0)]),
            _part("C2", 49.0, 50.0, [_smd("1", 0.0, 0.0, 1.0, 1.0)]),
        ],
        "nets": [{"name": "GND",
                  "pins": ["TP1.1", "TP1.2", "J1.1", "J1.2",
                           "C1.1", "C2.1"]}],
        "traces": [
            {"net": "GND", "layer": "top", "width_mm": 0.5,
             "points": [{"x_mm": 6.6, "y_mm": 30.0},
                        {"x_mm": 9.4, "y_mm": 30.0}]},
            {"net": "GND", "layer": "top", "width_mm": 0.25,
             "points": [{"x_mm": 45.0, "y_mm": 50.0},
                        {"x_mm": 49.0, "y_mm": 50.0}]},
        ],
        "vias": [{"x_mm": 8.0, "y_mm": 30.0, "diameter_mm": 0.8,
                  "drill_mm": 0.4, "net": "GND",
                  "from_layer": "top", "to_layer": "bottom"}],
        "zones": [{"net": "GND", "layer": "bottom", "clearance_mm": CLEARANCE,
                   "outline": [{"x_mm": 2.0, "y_mm": 20.0},
                               {"x_mm": 30.0, "y_mm": 20.0},
                               {"x_mm": 30.0, "y_mm": 40.0},
                               {"x_mm": 2.0, "y_mm": 40.0}]}],
    }


def test_a_via_on_a_runs_interior_joins_that_run() -> None:
    """The census reports the two islands the copper has, not three.

    THE MUTATION IS HALF THE ORACLE. Delete the one via and the probe pair goes
    back to being its own island: a fix that credits everything would pass the
    first assertion and fail the second.
    """
    board = _probe_pad_strapped_to_a_plane()
    assert drc.net_pin_group_count(board, "GND") == 2

    without_the_via = copy.deepcopy(board)
    without_the_via["vias"] = []
    assert drc.net_pin_group_count(without_the_via, "GND") == 3

    # And the whole-board reply says the same thing, so no consumer sees a
    # different census from the one the kernel computed.
    result = drc.run_drc(board)
    assert result["partial"] == [{"net": "GND", "pin_groups": 2}]
    assert result["counts"]["dangling_endpoint"] == 0


def _run_ending_beside_a_via(end_x: float) -> dict:
    """A 1.0 mm run from (20, 10) west to ``end_x``, and a 0.8 mm via at
    (10, 10). Copper reaches 0.5 mm (half the run) + 0.4 mm (the annulus) =
    0.9 mm, so an end at x=10.6 is 0.3 mm inside the join and one at x=11.0 is
    0.1 mm clear of it. Both are far outside the 0.2 mm clearance the old
    centre-to-centre credit measured."""
    return {
        "version": 1, "name": "annulus-bench",
        "width_mm": 30, "height_mm": 20,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": CLEARANCE},
        "components": [], "nets": [],
        "traces": [{"net": "SIG", "layer": "top", "width_mm": 1.0,
                    "points": [{"x_mm": 20.0, "y_mm": 10.0},
                               {"x_mm": end_x, "y_mm": 10.0}]}],
        "vias": [{"x_mm": 10.0, "y_mm": 10.0, "diameter_mm": 0.8,
                  "drill_mm": 0.4, "net": "SIG",
                  "from_layer": "top", "to_layer": "bottom"}],
    }


def _dangling(board: dict) -> list:
    return sorted(f["at"] for f in drc.run_drc(board)["findings"]
                  if f["type"] == "dangling_endpoint")


def test_a_run_ending_on_a_vias_annulus_is_landed_on_it() -> None:
    """Only the far end (20, 10), which reaches nothing, is loose."""
    assert _dangling(_run_ending_beside_a_via(10.6)) == [[20.0, 10.0]]


def test_a_run_ending_clear_of_the_annulus_is_still_loose() -> None:
    """0.1 mm of laminate is still an open, and reporting it is the whole
    reason the credit is measured rather than assumed."""
    assert _dangling(_run_ending_beside_a_via(11.0)) == [[11.0, 10.0],
                                                        [20.0, 10.0]]


def _shorts_board() -> dict:
    """Two foreign lands beside one net's runs, one of which is not copper.

      * H1 is an unplated 3.2 mm mounting hole at (20, 10). Its pad line says
        ``*.Cu`` — where copper must be kept AWAY — and CAM plates nothing
        there. A SIG run passes straight through its centre.
      * U1 is a 4.0 x 4.0 PWR land centred at (10, 20), so its copper reaches
        y = 22.0. A zero-width SIG run at y = 22.1 clears that edge by 0.10 mm
        — inside the 0.2 mm clearance — while sitting 2.1 mm from the pad
        CENTRE, ten times the clearance away.
    """
    return {
        "version": 1, "name": "shorts-bench",
        "width_mm": 40, "height_mm": 30,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": CLEARANCE},
        "components": [
            _part("H1", 20.0, 10.0, [
                {"number": "1", "type": "np_thru_hole", "shape": "circle",
                 "position": {"x": 0.0, "y": 0.0},
                 "size": {"width": 3.2, "height": 3.2},
                 "drill": {"x": 3.2, "y": 3.2},
                 "layers": ["*.Cu", "*.Mask"]}]),
            _part("U1", 10.0, 20.0, [_smd("1", 0.0, 0.0, 4.0, 4.0)]),
            _part("U2", 30.0, 20.0, [_smd("1", 0.0, 0.0, 1.0, 1.0)]),
        ],
        "nets": [{"name": "PWR", "pins": ["U1.1"]},
                 {"name": "SIG", "pins": ["U2.1"]}],
        "traces": [
            {"net": "SIG", "layer": "top", "width_mm": 0.25,
             "points": [{"x_mm": 14.0, "y_mm": 10.0},
                        {"x_mm": 26.0, "y_mm": 10.0}]},
            {"net": "SIG", "layer": "top", "width_mm": 0.0,
             "points": [{"x_mm": 6.0, "y_mm": 22.1},
                        {"x_mm": 14.0, "y_mm": 22.1}]},
        ],
    }


def test_a_short_is_reported_against_the_land_not_the_pad_centre() -> None:
    """One finding, and it is the real one.

    A hole with no barrel cannot be shorted to, and a land whose EDGE crowds
    the run is shorted to however far away its centre sits. The old centre
    measure got both backwards at once: it reported H1 and missed U1.
    """
    shorts = [f for f in drc.run_drc(_shorts_board())["findings"]
              if f["type"] == "wrong_net_pad"]
    assert [(f["pad"]["ref"], f["at"]) for f in shorts] == [
        ("U1", [10.0, 22.1])]
