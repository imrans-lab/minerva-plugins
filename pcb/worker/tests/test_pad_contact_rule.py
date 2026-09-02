"""The ONE pad-contact rule, as the connectivity DRC reports it.

Boards here are hand-built and self-contained; every expected value is derived
from the geometry in the docstring beside it. The shape-level agreement between
this side and the panel's is pinned separately by the shared vectors
(spec/contact, run by test_copper_contact_vectors.py) — these tests are about
what the RULE changes in a DRC reply.

Two things the pre-rule kernel could not do, and one it must keep doing:

  * credit copper that reaches a pad's LAND but not its CENTRE (a wide run
    ending off-centre; a stub on the corner of a big exposed pad; a run driven
    straight THROUGH a land), and
  * still report an end that genuinely stops short of the copper.
"""

from __future__ import annotations

from pathlib import Path

import yaml

from pcb_worker import (compile_board, copper_contact, drc, ir_connectivity,
                        methods, pad_source)

PARITY_CORNERS = Path(__file__).resolve().parent / "testdata" / "parity_corners.yaml"
HITL_BENCH = Path(__file__).resolve().parent / "testdata" / "hitl_bench.yaml"

CLEARANCE = 0.2


def _run(board: dict) -> dict:
    return drc.run_drc(board)


def _of_type(result: dict, t: str) -> list[dict]:
    return [f for f in result["findings"] if f["type"] == t]


def _pad(ref: str, x: float, y: float, w: float, h: float) -> dict:
    """One single-pin component whose land is a w x h rectangle centred on it."""
    return {"ref": ref, "footprint": "F", "x_mm": x, "y_mm": y,
            "rotation_deg": 0,
            "pins": [{"number": "1", "x_mm": 0, "y_mm": 0,
                      "pad_width_mm": w, "pad_height_mm": h}]}


def _board(name: str, components: list, nets: list, traces: list) -> dict:
    return {"version": 1, "name": name, "width_mm": 40, "height_mm": 30,
            "design_rules": {"clearance_mm": CLEARANCE},
            "components": components, "nets": nets, "traces": traces}


def test_a_wide_run_landing_off_centre_is_landed():
    """Two 1.3 x 4.5 lands (half-extents 0.65 / 2.25) centred at (10,10) and
    (12.5,10), joined by a 1.0mm run whose ends sit at (10.25,10.25) and
    (12.25,10.25).

    Each end is 0.25mm off its land's centre in BOTH axes — inside the land by
    0.40mm in x and 2.00mm in y — so it is on the copper. Its distance to the
    pad CENTRE is 0.354mm, past the 0.2mm clearance the kernel used to compare,
    which is why this board reported both ends dangling AND the net partial.
    """
    board = _board(
        "off-centre",
        [_pad("J1", 10.0, 10.0, 1.3, 4.5), _pad("J2", 12.5, 10.0, 1.3, 4.5)],
        [{"name": "VBAT", "pins": ["J1.1", "J2.1"]}],
        [{"net": "VBAT", "layer": "top", "width_mm": 1.0,
          "points": [{"x_mm": 10.25, "y_mm": 10.25},
                     {"x_mm": 12.25, "y_mm": 10.25}]}])
    r = _run(board)
    assert _of_type(r, "dangling_endpoint") == []
    assert r["complete"] is True
    assert "partial" not in r


def test_a_run_that_stops_a_millimetre_short_still_dangles():
    """A 1.0 x 1.0 land at (10,10) and the 1.3 x 4.5 land at (12.5,10). A
    0.25mm run leaves J1's centre and stops at (10.725, 10.0).

    Its end cap spans x = 10.60 .. 10.85: clear of J1's edge at 10.50 by
    0.10mm, and clear of J2's near edge at 12.5 - 0.65 = 11.85 by one clean
    millimetre of bare laminate.

    The rule must be able to say no, or it is not a rule.
    """
    board = _board(
        "short",
        [_pad("J1", 10.0, 10.0, 1.0, 1.0), _pad("J2", 12.5, 10.0, 1.3, 4.5)],
        [{"name": "VBAT", "pins": ["J1.1", "J2.1"]}],
        [{"net": "VBAT", "layer": "top", "width_mm": 0.25,
          "points": [{"x_mm": 10.0, "y_mm": 10.0},
                     {"x_mm": 10.725, "y_mm": 10.0}]}])
    r = _run(board)
    dangling = _of_type(r, "dangling_endpoint")
    assert len(dangling) == 1
    assert dangling[0]["at"] == [10.725, 10.0]
    assert dangling[0]["net"] == "VBAT"
    assert r["complete"] is False
    assert r["partial"] == [{"net": "VBAT", "pin_groups": 2}]


def test_a_run_driven_through_a_land_joins_it():
    """A 0.25mm run from A.1 (5,10) to B.1 (25,10) passes a tap pad T.1 whose
    1.75 x 1.25 land is centred at (15, 10.3) — half-extents 0.875 / 0.625.

    The run's centreline is 0.30mm off that centre, further than the 0.2mm the
    kernel's interior credit allowed, so the tap used to read as its own island
    and the net as partial. It is 0.325mm INSIDE the copper (0.625 + 0.125 of
    swept half-width), and the run never ends on it — which is exactly the
    board shape that made an owner add a 0.2mm stub to be believed.
    """
    board = _board(
        "tap",
        [_pad("A", 5.0, 10.0, 1.0, 1.0), _pad("B", 25.0, 10.0, 1.0, 1.0),
         _pad("T", 15.0, 10.3, 1.75, 1.25)],
        [{"name": "SIG", "pins": ["A.1", "B.1", "T.1"]}],
        [{"net": "SIG", "layer": "top", "width_mm": 0.25,
          "points": [{"x_mm": 5.0, "y_mm": 10.0},
                     {"x_mm": 25.0, "y_mm": 10.0}]}])
    r = _run(board)
    assert _of_type(r, "dangling_endpoint") == []
    assert r["complete"] is True
    assert "partial" not in r


def test_one_run_written_both_ways_reports_one_short():
    """The board carries the SAME run twice, once as A->B and once as B->A,
    both crossing the foreign GND land at (15,10).

    A segment is the same copper whichever way its ends are written, so this is
    ONE short. An along-run dedup key built from the endpoints in authored order
    keys the two spellings apart and bills the board twice for one fault.
    """
    run = [{"x_mm": 5.0, "y_mm": 10.0}, {"x_mm": 25.0, "y_mm": 10.0}]
    board = _board(
        "both-ways",
        [_pad("S1", 5.0, 10.0, 1.0, 1.0), _pad("S2", 25.0, 10.0, 1.0, 1.0),
         _pad("F", 15.0, 10.0, 1.0, 1.0)],
        [{"name": "SIG", "pins": ["S1.1", "S2.1"]},
         {"name": "GND", "pins": ["F.1"]}],
        [{"net": "SIG", "layer": "top", "width_mm": 0.25, "points": run},
         {"net": "SIG", "layer": "top", "width_mm": 0.25,
          "points": list(reversed(run))}])
    r = _run(board)
    shorts = _of_type(r, "wrong_net_pad")
    assert len(shorts) == 1
    assert shorts[0]["pad"] == {"ref": "F", "pin": "1", "net": "GND"}
    assert shorts[0]["at"] == [15.0, 10.0]


def test_two_foreign_pads_crowding_one_end_are_both_named():
    """A SIG run ends at (10,10) with a GND land 0.15mm above it and a VCC land
    0.15mm below — both inside the 0.2mm clearance.

    The end shorts to BOTH. Naming only the NEAREST tells the reader to move the
    trace clear of one land while the other still forbids the same point.
    """
    board = _board(
        "crowded",
        [_pad("S1", 5.0, 10.0, 1.0, 1.0),
         _pad("F1", 10.0, 9.85, 0.3, 0.3), _pad("F2", 10.0, 10.15, 0.3, 0.3)],
        [{"name": "SIG", "pins": ["S1.1"]},
         {"name": "GND", "pins": ["F1.1"]},
         {"name": "VCC", "pins": ["F2.1"]}],
        [{"net": "SIG", "layer": "top", "width_mm": 0.25,
          "points": [{"x_mm": 5.0, "y_mm": 10.0},
                     {"x_mm": 10.0, "y_mm": 10.0}]}])
    r = _run(board)
    shorts = _of_type(r, "wrong_net_pad")
    assert len(shorts) == 2
    assert all(f["at"] == [10.0, 10.0] for f in shorts)
    assert sorted(f["pad"]["ref"] for f in shorts) == ["F1", "F2"]
    assert sorted(f["pad"]["net"] for f in shorts) == ["GND", "VCC"]


def test_the_projected_board_carries_the_land_the_rule_needs():
    """The kernel is reached two ways — over a resolved raw board (the `drc`
    method) and over a COMPILED board projected into its dict language
    (ir_connectivity.connectivity_board, which is what the route reply's DRC
    runs on). The rule needs real pad EXTENT; a projection carrying only pin
    CENTRES would leave the route path answering with the coincidence disc
    while the standalone method answered with the copper.

    Measured over the parity-corners fixture: every projected pad states a
    positive land size, and its contact node reaches a probe 0.5mm off the pad
    centre — which a 0.2mm coincidence disc cannot do.

    About LAND EXTENT only; whether the two paths agree on WHERE each land sits
    is the separate assertion below.
    """
    board = methods._maybe_resolve(
        yaml.safe_load(PARITY_CORNERS.read_text(encoding="utf-8")), {})
    rb = compile_board.compile_board(board).board
    projected = ir_connectivity.connectivity_board(rb)

    lands = [pad for comp in projected["components"] for pad in comp["pads"]]
    assert lands, "the projection carried no pad lands"
    for land in lands:
        size = land.get("size") or {}
        assert float(size.get("width", 0)) > 0 and float(size.get("height", 0)) > 0, land

    # Every land here is at least 1.0mm across, so a probe 0.5mm off ANY pad
    # centre is on that pad's copper — and 0.5mm past the 0.2mm disc a
    # land-less projection would fall back to.
    for pad in drc._harvest_pads(projected):
        probe = copper_contact.endpoint_node((pad.x + 0.5, pad.y), 0.0, None)
        assert copper_contact.nodes_touch(probe, pad.contact), (
            f"{pad.ref}.{pad.pin} projected without usable land geometry")


def test_the_two_paths_place_one_board_identically_bottom_side_included():
    """WHERE a pad's copper is, answered twice, and the two answers must match.

    The kernel is fed from two directions and each derives placement its own
    way, so this is a real cross-check rather than a tautology:

      * the RAW path (``drc._harvest_pads`` over the resolved board dict) starts
        from footprint-LOCAL offsets and places them itself, through
        ``geometry.component_transform``;
      * the PROJECTED path hands it ``ir_connectivity.connectivity_board``,
        whose pads are already ABSOLUTE — placed by the compiler, off a
        ``FootprintDefinition``, in a different module.

    The fixture's U2 is the case that separates them: a bottom-side DIP socket
    turned 90 degrees, with pin 4 at local (7.62, 5.08). Bottom mirrors local y
    to -5.08; the quarter turn (clockwise in this y-down frame) sends
    (7.62, -5.08) to (-5.08, -7.62); the placement at (28, 20) lands it at
    (22.92, 12.38). Skipping the mirror puts it at (33.08, 12.38) — 10.16mm
    away, over copper that is not there.

    The two censuses are not identical in MEMBERSHIP, deliberately: the
    projection drops U3's unplated pad, because a bare mechanical hole is not an
    electrical entity, while the raw harvest keeps it as copper-free geometry.
    That difference is about what a hole IS, not about where anything sits, so
    it is named here rather than smoothed over.
    """
    board = methods._maybe_resolve(
        yaml.safe_load(PARITY_CORNERS.read_text(encoding="utf-8")), {})
    rb = compile_board.compile_board(board).board
    projected = ir_connectivity.connectivity_board(rb)

    harvested = drc._harvest_pads(board)

    def positions(pads):
        return {(p.ref, p.pin): (round(p.x, 6), round(p.y, 6)) for p in pads}

    raw = positions(harvested)
    ir = positions(drc._harvest_pads(projected))
    assert set(raw) - set(ir) == {("U3", "3")}
    assert {k: v for k, v in raw.items() if k in ir} == ir

    assert raw[("U2", "4")] == (22.92, 12.38)

    # And the SIDE the raw path reports for a bottom-mounted SMD part, whose
    # footprint states F.Cu — so its layer is DERIVED from the placement rather
    # than authored. This one used to come back on the top of the board.
    #
    # Read through `occupies`, the ONE derivation — the pad's layer set lives on
    # its contact node and has no second copy on the _Pad to assert against.
    by_pin = {(p.ref, p.pin): p for p in harvested}
    assert by_pin[("SW10", "1")].occupies("bottom")
    assert not by_pin[("SW10", "1")].occupies("top")
    # A through-hole land spans the stack whichever side its part is mounted on,
    # so it occupies BOTH sides rather than picking one.
    assert by_pin[("U2", "4")].occupies("top")
    assert by_pin[("U2", "4")].occupies("bottom")


def _bench() -> dict:
    return yaml.safe_load(HITL_BENCH.read_text(encoding="utf-8"))


def _dangling(board: dict) -> set:
    return {(f["net"], tuple(f["at"]))
            for f in _run(board)["findings"] if f["type"] == "dangling_endpoint"}


def test_inline_authored_lands_are_the_contact_geometry():
    """A part the footprint library cannot supply authors its lands INLINE, and
    those lands are the copper the rule measures — the same reading the fab
    emitters take (iter_pads prefers comp["pads"]).

    THE KEY IS NOT THE FACT. resolve only writes comp["has_pad_geometry"] on
    its success path, so an inline-geometry part carries real pads and NO such
    key; the resolved-vs-fallback fact is the pad LIST
    (pad_source.has_resolved_pads). A consumer that reads the key instead
    discards the lands and falls back to a coincidence disc at the pin centre —
    which is what the panel did, reporting copper sitting ON these lands as a
    free end while this side called it joined (bug 01a044a6d964).

    The bench's R9 row is exactly that geometry, and both probes are decided by
    a property of the LAND rather than of the pin centre: U9A's own rotation 90
    (2.0 x 0.6 land standing tall) and U9B's corner_rratio 0.25 (a 0.5mm corner
    radius on a 2.0 x 2.0 roundrect). tests/gd/test_copper_contact_vectors.gd
    pins the panel to these same four answers.
    """
    board = methods._maybe_resolve(_bench(), {})
    parts = {c["ref"]: c for c in board["components"]}
    for ref in ("U9A", "U9B"):
        assert "has_pad_geometry" not in parts[ref], (
            f"{ref} now carries the key — this test's premise has moved")
        assert pad_source.has_resolved_pads(parts[ref]), ref

    # Both R9 ends sit ON their land: 0.2mm inside the rotated one, 0.076mm
    # inside the roundrect's corner region.
    assert not {d for d in _dangling(_bench()) if d[0].startswith("R9")}

    # And both flip when the land property that decides them is taken away.
    unrotated = _bench()
    for comp in unrotated["components"]:
        if comp["ref"] == "U9A":
            comp["pads"][0].pop("rotation")
    assert ("R9_A", (22.0, 104.8)) in _dangling(unrotated)

    moved = _bench()
    for trace in moved["traces"]:
        if trace["net"] == "R9_B":
            trace["points"][-1] = {"x_mm": 46.9, "y_mm": 104.9}
    assert ("R9_B", (46.9, 104.9)) in _dangling(moved)
