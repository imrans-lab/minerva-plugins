"""DEFERRED TEST Z3 (docket 019fb06e7415, authored at epoch GA-5) — the GC7
zone-clearance DISCRIMINATING PAIR the triage found missing.

Nothing anywhere drove an actual GC7 violation: the one real-kernel test
(test_zone_seals.test_geometric_drc_checks_a_filled_pour) asserts a CLEAN
verdict, which a GC7 that never fires also passes. And the same-net
exemption (drc_geometric's INLINE site, distinct from the shared GC2
helper) was entirely unpinned — the corpus half-mutant
gc7_same_net_exemption_treats_unassigned_as_shared targets exactly it.

THE FIXTURE IS DOCTORED, and the docstring must say so out loud (same
doctrine as test_route_rules' stand-in board): a normally-compiled board
cannot violate GC7, because zone_fill carves at the SAME resolved rule GC7
judges — the filler and the judge share one clearance derivation by design.
The violating state is real nonetheless: ResolvedZone.fill is public IR, a
foreign tool (or a future filler bug — which is what GC7 exists to catch)
can hand DRC a fill that encroaches. dataclasses.replace substitutes the
computed fill with the pour's own UNCARVED outline rectangle, i.e. copper
laid straight over the trace the filler would have avoided.

The PAIR is the point: identical geometry, only the trace's NET differs —
foreign fires, same-net is exempt. A check that fires on both (exemption
lost) or neither (kernel dead) fails one half.
"""

from __future__ import annotations

import copy
import dataclasses

import pyclipper

from pcb_worker import drc_geometric
from pcb_worker.compile_board import ResolutionSuccess, compile_board
from pcb_worker.drc_geometric import run_geometric_drc
from pcb_worker.resolved_board import DiagnosticSeverity, PolygonGeometry


_OUTLINE = [{"x_mm": 4.0, "y_mm": 4.0}, {"x_mm": 16.0, "y_mm": 4.0},
            {"x_mm": 16.0, "y_mm": 16.0}, {"x_mm": 4.0, "y_mm": 16.0}]


def _board(trace_net: str) -> dict:
    """GND pour over the board middle; one trace straight through it on
    ``trace_net``. R1 pins give both nets a real pad so compile accepts."""
    return {
        "version": 1, "name": "gc7-pair", "width_mm": 20, "height_mm": 20,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [
            {"ref": "R1", "footprint": "R_0805", "x_mm": 10, "y_mm": 18,
             "rotation_deg": 0, "layer": "top"},
        ],
        "nets": [{"name": "GND", "pins": ["R1.1"]},
                 {"name": "SIG", "pins": ["R1.2"]}],
        "traces": [{"net": trace_net, "layer": "top", "width_mm": 0.3,
                    "points": [{"x_mm": 5.0, "y_mm": 10.0},
                               {"x_mm": 15.0, "y_mm": 10.0}]}],
        "zones": [{"net": "GND", "layer": "top", "clearance_mm": 0.2,
                   "outline": copy.deepcopy(_OUTLINE)}],
    }


def _doctored(board: dict):
    """Compile, then replace the pour's carved fill with its UNCARVED outline
    rectangle — copper laid straight over the trace."""
    result = compile_board(board)
    assert isinstance(result, ResolutionSuccess), [
        d.code for d in result.diagnostics
        if d.severity is DiagnosticSeverity.ERROR]
    rb = result.board
    zone = rb.zones[0]
    solid = PolygonGeometry(points=tuple(
        (p["x_mm"], p["y_mm"]) for p in _OUTLINE))
    return dataclasses.replace(
        rb, zones=(dataclasses.replace(zone, fill=(solid,)),))


def test_a_foreign_net_encroachment_fires_gc7_naming_both_parties():
    rb = _doctored(_board(trace_net="SIG"))
    result = run_geometric_drc(rb)
    gc7 = [f for f in result["findings"] if f["type"] == "gc7_zone_clearance"]
    assert gc7, ("uncarved pour copper over a FOREIGN trace must fire GC7 — "
                 "a clean here means the kernel never ran or never bites")
    f = gc7[0]
    assert f["entity_id"] == rb.zones[0].id, "the finding names the ZONE"
    assert f.get("against_entity_id"), (
        "the asymmetric rule attributes the opposed party (the trace)")
    assert result["verdict"] != "clean"


def test_the_same_net_trace_in_the_same_position_is_exempt():
    """Identical copper, trace on the pour's OWN net: solid connect is the
    contract, no clearance applies, no finding. Losing the exemption's
    non-null guard (the corpus half-mutant) or the exemption itself makes
    this half red."""
    rb = _doctored(_board(trace_net="GND"))
    result = run_geometric_drc(rb)
    gc7 = [f for f in result["findings"] if f["type"] == "gc7_zone_clearance"]
    assert gc7 == [], (
        "same-net copper under a pour is the CONNECTION, not a violation")


def test_two_netless_parties_are_never_exempted():
    """KILLER for the corpus mutant gc7_same_net_exemption_treats_unassigned_
    as_shared (GA testex survivor triage). The exemption's non-null conjunct
    is what keeps two NETLESS parties checkable: a netless pour (doctored —
    the compiler refuses one upstream, but ResolvedZone is public IR and
    does not) over netless copper (a plated board hole's ring carries no
    net) must still produce a GC7 finding. Dropping the conjunct makes
    None == None read as "same net" and the encroachment silently exempt."""
    board = _board(trace_net="SIG")
    board["mounting_holes"] = [
        {"x_mm": 10.0, "y_mm": 8.0, "diameter_mm": 2.0, "plated": True,
         "annulus_mm": 3.0}]
    del board["traces"]  # the hole is the only foreign party under the pour
    result = compile_board(board)
    assert isinstance(result, ResolutionSuccess), [
        d.code for d in result.diagnostics
        if d.severity is DiagnosticSeverity.ERROR]
    rb = result.board
    zone = rb.zones[0]
    solid = PolygonGeometry(points=tuple(
        (p["x_mm"], p["y_mm"]) for p in _OUTLINE))
    doctored = dataclasses.replace(
        rb, zones=(dataclasses.replace(zone, net_id=None, fill=(solid,)),))
    findings = run_geometric_drc(doctored)["findings"]
    gc7 = [f for f in findings if f["type"] == "gc7_zone_clearance"]
    assert gc7, (
        "netless pour copper over netless board-hole copper must be CHECKED "
        "— unassigned is not shared, and exempting it is a missed short")


# ---------------------------------------------------------------------------
# THE COINCIDENT-BOUNDARY PAIR (docket 01a02873cad3).
#
# Everything above is DOCTORED — the fill is swapped for an uncarved rectangle,
# so none of it exercises what GC7 does to a fill the FILLER actually produced.
# That gap is why the bug shipped: on the live smart-remote-v2 board GC7 reported
# three clearance violations against a correctly carved pour, blocking promote,
# with measured overlaps of 1,858 to 24,927 nm^2 — boolean vertex rounding, not
# copper.
#
# These two are both REAL compiles, and they are a pair in the same sense as the
# doctored one: identical geometry, only the zone's authored clearance differs.
# Silent (clearance deferred, so the carve and the requirement resolve to the
# same number and the boundaries are coincident) must be CLEAN. Loud (a clearance
# authored BELOW the global minimum — the one case the filler and this check
# genuinely disagree about) must still FIRE. Passing only the first would mean
# the guard is a blanket exemption; passing only the second is the bug.
# ---------------------------------------------------------------------------


def _real_board(zone_clearance_mm: float | None) -> dict:
    """A pour with a foreign trace BENT inside it, compiled for real.

    THE BEND IS THE FIXTURE, and this was got backwards on the first attempt.
    The noise is minted where two obstacles' inflated bands OVERLAP EACH OTHER:
    the filler subtracts every obstacle in one ``CT_DIFFERENCE``, so adjacency is
    where Clipper creates intersection vertices and rounds them to the 1 nm grid.
    Two segments meeting at a corner are the cheapest such adjacency.

    Counter-intuitively, adding a via AT the bend makes the board CLEAN with or
    without the guard — the via's larger inflated disc swallows the join region
    and the minted vertices land in its interior. The first draft of this fixture
    put a via there and passed against the unfixed code, proving nothing. A
    straight run with a via mid-segment is clean too. Measured, not reasoned:
    across 60 arrangements (trace widths 0.15-1.2 mm, orthogonal bends, diagonal
    chevrons, zigzags, U-turns, sawtooth, with and without vias) the bends are
    what produce phantom overlaps.
    """
    board = {
        "version": 1, "name": "gc7-coincident", "width_mm": 20, "height_mm": 20,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [
            {"ref": "R1", "footprint": "R_0805", "x_mm": 10, "y_mm": 18,
             "rotation_deg": 0, "layer": "top"},
        ],
        "nets": [{"name": "GND", "pins": ["R1.1"]},
                 {"name": "SIG", "pins": ["R1.2"]}],
        "traces": [{"net": "SIG", "layer": "top", "width_mm": 0.3,
                    "points": [{"x_mm": 5.5, "y_mm": 10.0},
                               {"x_mm": 10.0, "y_mm": 10.0},
                               {"x_mm": 10.0, "y_mm": 14.5}]}],
        "zones": [{"net": "GND", "layer": "top",
                   "outline": copy.deepcopy(_OUTLINE)}],
    }
    if zone_clearance_mm is not None:
        board["zones"][0]["clearance_mm"] = zone_clearance_mm
    return board


def _gc7_of(board: dict) -> list[dict]:
    result = compile_board(board)
    assert isinstance(result, ResolutionSuccess), [
        d.code for d in result.diagnostics
        if d.severity is DiagnosticSeverity.ERROR]
    assert result.board.zones[0].fill, (
        "the pour must actually be FILLED or GC7 skips it entirely and both "
        "halves of this pair become tautologies")
    findings = run_geometric_drc(result.board)["findings"]
    return [f for f in findings if f["type"] == "gc7_zone_clearance"]


def test_a_pour_that_defers_its_clearance_does_not_report_itself():
    """REGRESSION, docket 01a02873cad3. The DEFAULT configuration: the zone
    authors no ``clearance_mm``, so ``zone_fill._clearance_mm`` falls back to the
    board minimum — the identical number ``_effective_min_clearance`` judges it
    by. Carve and requirement are then mathematically coincident, and any
    intersection at all is quantization at the boolean's own vertices.

    This is not an exotic board. A pour that names no clearance is the common
    case, and before ``GC7_SLIVER_WIDTH_NM`` every one of them with foreign
    copper bending inside it reported violations that do not exist — refusing
    promote and naming a clearance failure on the largest piece of copper on the
    board. MEASURED here without the guard: two phantom overlaps of 15,344 and
    13,028 nm^2, the same order as the three seen live.
    """
    assert _gc7_of(_real_board(zone_clearance_mm=None)) == []


def test_a_pour_authoring_below_the_global_minimum_still_fires():
    """THE OTHER HALF, and what stops the guard being a blanket exemption.

    The one case filler and check genuinely disagree about:
    ``zone_fill._clearance_mm`` honours the author's number when it exceeds every
    class minimum, so a zone authoring 0.05 mm carves 0.05 mm, while
    ``_effective_min_clearance`` here knows nothing of the zone and demands the
    board's 0.2 mm. The pour really does sit 0.15 mm inside the required band.

    THE MARGIN IS FIVE ORDERS OF MAGNITUDE, which is the whole safety argument
    for the guard. Measured on this exact fixture: the real overlap is ~1.54 mm^2
    and survives deflation at 100,000 nm of width, against a widest-ever-measured
    phantom of 2 nm (see ``GC7_SLIVER_WIDTH_NM`` — an earlier version of this
    docstring claimed 1 nm and called it a theoretical bound; both were wrong,
    and the sweep that appeared to confirm them covered trace bends only).
    Deriving the threshold from the 5,000 nm arc tolerance instead, as first
    proposed, would have masked both nanometre-scale under-carves pinned in this
    file (50 nm and 100 nm) and left only 30x of margin under the 0.15 mm one
    asserted here — it does still fire at 5,000 nm, so this test alone would not
    have caught that derivation. It would additionally have hidden the two sides'
    offset constants drifting apart.
    """
    gc7 = _gc7_of(_real_board(zone_clearance_mm=0.05))
    assert gc7, (
        "a pour carved BELOW the board minimum is the genuine catch GC7 has "
        "left; masking it would make the sliver guard a blanket exemption")
    assert all(f["required_mm"] == 0.2 for f in gc7), (
        "the rule reported is the board minimum this pour undercut, not the "
        "clearance it authored for itself")


def test_the_guard_is_tied_to_the_coordinate_quantum_not_the_arc_tolerance():
    """PINS THE THRESHOLD'S MAGNITUDE, which the pair above does not.

    The two tests above pass identically with the guard at 4 nm and at 5,000 nm —
    the phantom dies either way and the 0.15 mm under-carve survives either way,
    so nothing between them is constrained and the first proposed derivation
    (from ``zone_fill.ARC_TOLERANCE_NM``) would have shipped unchallenged.

    This board authors 0.1999 mm against a 0.2 mm board minimum: a real,
    deliberate under-carve of exactly 100 nm. That is 50x the widest phantom ever
    measured (2 nm) and 50x below the arc tolerance. MEASURED: reported at every
    threshold up to 50 nm, silent at 100 nm and above.

    The claim being defended is a narrow one — the guard may only mask what the
    1 nm coordinate grid cannot represent, never what is merely small. Arc
    tolerance is the wrong scale for that because it CANCELS: both sides now
    flatten round joins through the same constant, so it says nothing about how
    far the two boundaries can drift apart.
    """
    gc7 = _gc7_of(_real_board(zone_clearance_mm=0.1999))
    assert gc7, (
        "a 100 nm under-carve is representable copper and a real breach of the "
        "board minimum — a guard that swallows it is scaled to the wrong "
        "quantity, whatever else it fixes")


def _rotated_pad_board() -> dict:
    """Two foreign pads at ODD ROTATIONS, grazing, inside a deferred-clearance
    pour. Compiled for real.

    THE ARRANGEMENT CLASS THAT BROKE THE FIRST THRESHOLD. The original sweep
    behind ``GC7_SLIVER_WIDTH_NM`` covered trace bends only and never saw a
    phantom wider than 1 nm, which made a one-rounding-stage bound of 1 nm look
    confirmed. Rotated pads reach 2 nm routinely: this fixture's phantom is
    663,860 nm^2 — forty times the area of the bend case above, and still only
    2 nm across, which is the whole argument for testing width rather than area.

    It pins the guard from BELOW, which nothing else here does: at a threshold of
    1 nm this board reports a violation. Together with the 50 nm under-carve
    below it brackets the constant on both sides.
    """
    outline = [{"x_mm": 4.0, "y_mm": 4.0}, {"x_mm": 24.0, "y_mm": 4.0},
               {"x_mm": 24.0, "y_mm": 24.0}, {"x_mm": 4.0, "y_mm": 24.0}]
    return {
        "version": 1, "name": "gc7-rotated-pads", "width_mm": 30,
        "height_mm": 30, "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [
            {"ref": "R1", "footprint": "R_0805", "x_mm": 21.0, "y_mm": 26.0,
             "rotation_deg": 0, "layer": "top"},
            {"ref": "R2", "footprint": "R_0805", "x_mm": 9.0, "y_mm": 10.0,
             "rotation_deg": 113, "layer": "top"},
            {"ref": "R3", "footprint": "R_0805", "x_mm": 10.55, "y_mm": 11.3,
             "rotation_deg": 79, "layer": "top"},
        ],
        "nets": [{"name": "GND", "pins": ["R1.1"]},
                 {"name": "SIG", "pins": ["R1.2", "R2.1", "R2.2",
                                          "R3.1", "R3.2"]}],
        "zones": [{"net": "GND", "layer": "top", "outline": outline}],
    }


def test_grazing_rotated_pads_in_a_deferred_clearance_pour_are_clean(monkeypatch):
    """The bend fixture's blind spot. Same coincident-boundary mechanism, but
    the phantom here is twice as wide, which is what forced
    ``GC7_SLIVER_WIDTH_NM`` up from 2 to 4 — at 2 the guard sat exactly on the
    measured maximum and survived only on ``_is_sliver``'s strictly-wider-than
    boundary, with no headroom for a further rounding stage.

    THE FIRST ASSERTION IS WHAT STOPS THIS ROTTING INTO A VACUOUS PASS, and it is
    not hypothetical: this arrangement is LUCKY. Nudging R2 by a micrometre or a
    fifth of a degree leaves only about a third of the variants minting a phantom
    at all, and moving R3 by 5 um (``x_mm: 10.555``) kills it outright — at which
    point a bare ``== []`` would pass forever while pinning nothing, and no CI
    run would say a word. Lowering the threshold to 1 first and demanding the
    phantom APPEAR makes its existence self-verifying, so a future pyclipper
    whose rounding shifts this arrangement into the silent neighbourhood fails
    loudly instead of going quietly green.

    MEASURED SIDE EFFECT, recorded because the matrix depends on it and this is
    the only docstring that could say so: lowering the threshold here is also
    what couples the ``Execute`` delta to the constant. Hardcoding that delta as
    ``-2.0`` — numerically identical to ``-W / 2`` at the shipped value, and
    therefore invisible to every other test including the synthetic-band one —
    fails THIS assertion and nothing else. Anyone preserving the anti-vacuity
    property by some other means would silently drop that pin.
    """
    monkeypatch.setattr(drc_geometric, "GC7_SLIVER_WIDTH_NM", 1)
    assert _gc7_of(_rotated_pad_board()), (
        "this fixture no longer mints a phantom wider than 1 nm, so the clean "
        "assertion below has stopped testing the guard — re-derive the geometry "
        "against the current kernel rather than deleting this line")

    monkeypatch.undo()
    assert _gc7_of(_rotated_pad_board()) == []


def test_is_sliver_culls_exactly_at_the_shipped_threshold():
    """PINS THE CONSTANT AND THE HALVING, with no board and no arrangement luck.

    Every compiled fixture in this file leaves slack: thresholds anywhere in
    [2, 100) behave identically on all of them, and deflating by ``W`` instead of
    ``W / 2`` — an effective doubling of what gets culled — passes every one.
    Closing that with another compiled board would mean asserting sensitivity a
    few nanometres above the widest measured phantom, which is exactly the
    fragility the rotated-pad fixture above documents.

    Synthetic bands have no such problem. ``_is_sliver`` culls a band iff its
    true width is <= ``GC7_SLIVER_WIDTH_NM``, so requiring 4 nm culled AND 5 nm
    kept admits exactly one value of the constant, and the deflate-by-``W``
    mutation (which would cull everything up to 8 nm) fails the second half.
    Deterministic in the integer kernel, and it is the same calibration the
    threshold was derived from.
    """
    def band(width_nm: int):
        return [[(0, 0), (2_000_000, 0), (2_000_000, width_nm), (0, width_nm)]]

    assert drc_geometric._is_sliver(pyclipper, band(4)), (
        "a band no wider than the threshold is noise and must be culled")
    assert not drc_geometric._is_sliver(pyclipper, band(5)), (
        "a band wider than the threshold is copper and must survive — if this "
        "fails, either the constant grew or the deflation lost its halving")


def test_a_fifty_nanometre_under_carve_is_still_reported():
    """UPPER PIN on the threshold, tighter than the 100 nm case above.

    Without this, every value from 4 nm through 50 nm behaves identically on
    every other fixture in this file, so the constant could drift an order of
    magnitude in silence. A zone authoring 0.19995 mm against a 0.2 mm board
    minimum carves a real, representable 50 nm short. MEASURED: reported at
    thresholds up to 50, silent at 100 and above.

    50 nm is 12.5x the shipped guard and 25x the widest phantom ever measured,
    so this asserts no sensitivity the kernel cannot actually deliver.
    """
    gc7 = _gc7_of(_real_board(zone_clearance_mm=0.19995))
    assert gc7, (
        "a 50 nm under-carve is representable copper and a real breach of the "
        "board minimum; a guard that swallows it has drifted far past the "
        "coordinate quantum it is supposed to be scaled to")
