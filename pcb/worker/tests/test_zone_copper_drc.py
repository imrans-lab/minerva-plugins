"""A FILLED POUR IS COPPER — what the connectivity DRC says once it can see one.

Every board here is driven through ``methods.handle_request`` — the real request
entry point, real footprint resolution, real compile, real fill. Nothing is
stubbed, because the thing under test is precisely whether the DRC and the
filler agree about one board.

WHAT EACH BOARD IS FOR, and what it said before this existed:

  1. A pour that finishes the job the traces did not      (was: indeterminate)
  2. A pour that must NOT finish another net's job        (guard)
  3. A pour that could not be filled, and a keepout       (was: indeterminate /
                                                           wrongly "has copper")
  4. A run that dead-ends on an unplated mounting hole    (was: silently clean)

The GND figures in board 1 and the island counts in board 4 are hand-derived in
the tests that use them.
"""

from __future__ import annotations

from pcb_worker import drc, methods

CLEARANCE_MM = 0.2

# R_0805's lands are 1.00 x 1.45 mm at +/-0.95 mm from the body centre, so a part
# at (5, 10) puts pad 1 at (4.05, 10) and pad 2 at (5.95, 10). Every coordinate
# below is derived from that.
PAD_OFFSET_MM = 0.95


def _rect(x0, y0, x1, y1):
    return [{"x_mm": x0, "y_mm": y0}, {"x_mm": x1, "y_mm": y0},
            {"x_mm": x1, "y_mm": y1}, {"x_mm": x0, "y_mm": y1}]


def _board(**extra):
    """Two 0805s on a 20x20 two-layer board: R1 at (5,10), R2 at (15,10). Pad 1
    of each is GND, pad 2 is SIG, and nothing is routed."""
    board = {
        "version": 1, "name": "pour-drc", "width_mm": 20, "height_mm": 20,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": CLEARANCE_MM, "trace_width_mm": 0.3,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [
            {"ref": "R1", "footprint": "R_0805", "x_mm": 5, "y_mm": 10,
             "rotation_deg": 0, "layer": "top"},
            {"ref": "R2", "footprint": "R_0805", "x_mm": 15, "y_mm": 10,
             "rotation_deg": 0, "layer": "top"}],
        "nets": [{"name": "GND", "pins": ["R1.1", "R2.1"]},
                 {"name": "SIG", "pins": ["R1.2", "R2.2"]}],
    }
    board.update(extra)
    return board


def _drc(board: dict) -> dict:
    reply = methods.handle_request({"id": 1, "method": "drc",
                                    "params": {"board": board}})
    assert reply.get("ok"), reply
    return reply["result"]


def _resolved(board: dict) -> dict:
    """The board with real footprint geometry attached — through the worker's own
    ``resolve`` request, the same geometry the DRC request measures."""
    reply = methods.handle_request({"id": 2, "method": "resolve",
                                    "params": {"board": board}})
    assert reply.get("ok"), reply
    return reply["result"]["board"]


def _indeterminate(result: dict) -> dict:
    return {row["net"]: row for row in result.get("indeterminate", [])}


def _partial(result: dict) -> dict:
    return {row["net"]: row["pin_groups"] for row in result.get("partial", [])}


def test_a_filled_pour_joins_the_pins_its_traces_leave_apart():
    """THE CASE THIS EXISTS FOR: a plane that finishes the routing.

    Board: a GND pour over (2,2)-(18,18) on TOP, plus one GND stub from R1's pad
    1 at (4.05,10) running up to (4.05,15).

    THE ISLANDS, by hand. GND has two pins — R1.1 at (4.05,10) and R2.1 at
    (14.05,10). The stub touches R1.1 and nothing else, so trace+via copper
    ALONE leaves two pin islands. The pour is on the same layer and connects
    SOLID (v1 does not carve around same-net copper), so its fill covers both
    lands: one island. Both numbers are asserted below rather than only the
    verdict, because "complete" would also be produced by a census that had
    quietly stopped counting.

    THE STUB'S FREE END at (4.05,15) sits 3.0mm inside the pour on its own net,
    which is a GND tap, not an open. Before the pour was copper it was reported
    as a dangling_endpoint — the false positive that made a correct board read
    as broken.

    FAILS AGAINST THE OLD MODEL on both counts: it reported
    dangling_endpoint at (4.05,15) and put GND in `indeterminate`.
    """
    board = _board(
        zones=[{"id": "z1", "kind": "copper_pour", "net": "GND",
                "layer": "top", "outline": _rect(2, 2, 18, 18)}],
        traces=[{"net": "GND", "layer": "top", "width_mm": 0.3,
                 "points": [{"x_mm": 4.05, "y_mm": 10},
                            {"x_mm": 4.05, "y_mm": 15}]}])

    result = _drc(board)
    assert result["counts"]["dangling_endpoint"] == 0, result["findings"]
    assert "GND" not in _indeterminate(result)
    assert "GND" not in _partial(result)
    assert "GND" not in result["missing_copper"]

    # The two hand-derived island counts, over the SAME resolved board the DRC
    # measured — one call each, so a change to either credit shows up as a
    # number rather than as a flipped verdict.
    from pcb_worker import zone_copper
    resolved = _resolved(board)
    pours, reason = zone_copper.pour_nodes(resolved)
    assert reason == "", reason
    args = (drc._harvest_pads(resolved), drc._harvest_segments(resolved),
            drc._harvest_vias(resolved), CLEARANCE_MM)
    assert drc._net_pin_groups("GND", *args, None) == 2
    assert drc._net_pin_groups("GND", *args, pours["GND"]) == 1


def test_a_pour_joins_only_its_own_net():
    """A plane is one potential. It must not close another net's gap, and a run
    that stops inside it must not be credited by it.

    Board: the same GND pour, plus a SIG stub from R1's pad 2 at (5.95,10)
    running 2.05mm to (8.0,10) — well inside the pour's outline, and stopping
    nowhere.

    SIG must read PARTIAL WITH TWO PIN GROUPS: its two pins are 10mm apart with
    one stub between them, and the GND plane covering the whole board does not
    change that. And the stub's end at (8.0,10) must still read DANGLING: the
    only thing near it is foreign copper, which is a short to be reported, never
    a landing.

    (The fill CARVES around foreign copper, so on this board the SIG end is not
    inside the fill either — it is held 0.2mm off by the clearance. The net gate
    is the belt to that braces: it is what keeps the credit right if the two
    ever meet, and it is the rule the panel's Trace tool needs, where a click
    happens before the run it would carve for exists.)
    """
    result = _drc(_board(
        zones=[{"id": "z1", "kind": "copper_pour", "net": "GND",
                "layer": "top", "outline": _rect(2, 2, 18, 18)}],
        traces=[{"net": "SIG", "layer": "top", "width_mm": 0.3,
                 "points": [{"x_mm": 5.95, "y_mm": 10},
                            {"x_mm": 8.0, "y_mm": 10}]}]))

    assert _partial(result) == {"SIG": 2}
    assert _indeterminate(result) == {}
    assert [(f["net"], f["at"]) for f in result["findings"]
            if f["type"] == "dangling_endpoint"] == [("SIG", [8.0, 10.0])]


def test_a_pour_that_could_not_be_filled_says_so_and_a_keepout_is_not_copper():
    """The two ways a zone fails to be copper, and neither may be guessed at.

    A POUR AUTHORING THERMAL RELIEF is refused by the filler (v1 connects solid,
    and filling it solid would discard an authored fabrication parameter). No
    fill means nothing was measured, so GND stays INDETERMINATE — and the row
    now carries the refusal itself, so a reader is told what to fix rather than
    only that something is unknown.

    A KEEPOUT is a prohibition on copper and emits none. GND's only zone here is
    a keepout, so GND has NO copper at all and belongs in missing_copper.

    FAILS AGAINST THE OLD MODEL: the indeterminate row carried no reason, and
    the keepout counted as "this net has a zone, so it has copper" — which
    turned a net with zero copper into an unanswerable one.
    """
    refused = _drc(_board(zones=[{
        "id": "z1", "kind": "copper_pour", "net": "GND", "layer": "top",
        "outline": _rect(2, 2, 18, 18),
        "thermal_gap_mm": 0.3, "thermal_bridge_width_mm": 0.4}]))
    row = _indeterminate(refused)["GND"]
    assert row["reason"] == "zone_copper"
    assert "thermal" in row["detail"]

    keepout = _drc(_board(zones=[{
        "id": "z1", "kind": "keepout", "net": "GND", "layer": "top",
        "outline": _rect(2, 2, 18, 18)}]))
    assert _indeterminate(keepout) == {}
    assert "GND" in keepout["missing_copper"]


def test_a_run_that_dead_ends_on_an_unplated_hole_reads_as_the_open_it_is():
    """An UNPLATED hole is drilled and never plated: no barrel, no copper.

    Its footprint pad says otherwise, and that is the trap. This board mounts the
    SHIPPED ``MountingHole:MountingHole_3.2mm_M3``, whose only pad is

        (pad 1 np_thru_hole circle (size 3.2 3.2) (drill 3.2) (layers *.Cu *.Mask))

    — NUMBERED, and declaring copper on every layer. A predicate that reads that
    layer list hands it a 3.2mm all-layer land, which is a via with a 3.2mm
    barrel that the board does not have. Nothing about this board is contrived:
    tying a mounting hole to ground is an ordinary thing to author, and it is
    exactly the thing that cannot work.

    Board. R1 at (5,12) and R2 at (15,12), pad 1 of each on GND, the hole at
    (10,10) named as a GND pin too. Two GND runs approach the hole and stop
    short of each other: one from R1.1 (4.05,12) down to (4.05,10) then right to
    (8.8,10), the other from (11.2,10) right to (14.05,10) then up to R2.1
    (14.05,12). The land's radius is 1.600mm, so both inner ends are ON it
    (|8.8-10| = 1.200 < 1.600), and they are 2.400mm apart from each other — far
    past any coincidence credit, so the hole is the ONLY thing that could join
    them.

    THE NUMBERS, by hand. GND declares three pins. R1.1 with its run is one
    island, R2.1 with its run is a second, and H1.1 reaches nothing at all,
    which makes it a third. Both inner ends are leaves landing on no copper, so
    both are dangling.

    FAILS AGAINST THE OLD MODEL, which reported ZERO dangling endpoints and no
    partial row at all: the hole bridged the two runs into one island and
    swallowed both open ends. A board with a 2.4mm gap in its ground read clean.
    """
    result = _drc({
        "version": 1, "name": "npth", "width_mm": 20, "height_mm": 20,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": CLEARANCE_MM, "trace_width_mm": 0.3,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [
            {"ref": "R1", "footprint": "R_0805", "x_mm": 5, "y_mm": 12,
             "rotation_deg": 0, "layer": "top"},
            {"ref": "R2", "footprint": "R_0805", "x_mm": 15, "y_mm": 12,
             "rotation_deg": 0, "layer": "top"},
            {"ref": "H1", "footprint": "MountingHole:MountingHole_3.2mm_M3",
             "x_mm": 10, "y_mm": 10, "rotation_deg": 0, "layer": "top"}],
        "nets": [{"name": "GND", "pins": ["R1.1", "R2.1", "H1.1"]},
                 {"name": "SIG", "pins": ["R1.2", "R2.2"]}],
        "traces": [
            {"net": "GND", "layer": "top", "width_mm": 0.3,
             "points": [{"x_mm": 4.05, "y_mm": 12}, {"x_mm": 4.05, "y_mm": 10},
                        {"x_mm": 8.8, "y_mm": 10}]},
            {"net": "GND", "layer": "top", "width_mm": 0.3,
             "points": [{"x_mm": 11.2, "y_mm": 10},
                        {"x_mm": 14.05, "y_mm": 10},
                        {"x_mm": 14.05, "y_mm": 12}]}],
    })

    assert _partial(result)["GND"] == 3
    assert sorted(f["at"] for f in result["findings"]
                  if f["type"] == "dangling_endpoint") == [[8.8, 10.0],
                                                           [11.2, 10.0]]
