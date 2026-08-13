"""ZONE FILL — hand-derived arithmetic and the refusal matrix.

LIVE AND COLLECTED. This file was authored during C6 as ``pending_zone_fill.py``,
deliberately outside pytest's ``test_*`` discovery, and its docstring said so.
It has since been renamed into the suite, and that paragraph went on claiming
"``--collect-only`` reports zero of these" while every test in it ran — a
docstring asserting its own file was inert. Corrected here, in the same change
that removed three silent skips from it, because a stale claim about what is
covered is the same failure as a skip that reads as green.

WHAT IS HERE. The executable tests that shipped with C6 prove the fill is RIGHT
(oracle parity), REPRODUCIBLE (determinism gate) and FAIL-CLOSED at the four
emitter seals. These add the hand-derived arithmetic and the refusal matrix —
the cases whose value is that a human worked out the answer independently of the
code.

The hand-computed coordinates below were derived on paper from the clearance
definition (a Minkowski sum with a disc of radius = clearance), NOT copied out of
the filler's output. That is the whole point of them: a test whose expected value
came from the implementation proves the implementation equals itself.
"""

from __future__ import annotations

import copy
import json
import math
from dataclasses import replace

import pytest

from pcb_worker import gerber, kicad
from pcb_worker.compile_board import compile_board
from pcb_worker.resolved_board import (
    DiagnosticSeverity,
    ResolutionFailure,
    ResolutionSuccess,
    ZoneKind,
)
from pcb_worker.zone_fill import (
    NM_PER_MM,
    ZoneFillError,
    fill_area_mm2,
    fill_board_zones,
)

# --------------------------------------------------------------------------
# Fixture builders
# --------------------------------------------------------------------------


def _board(zones, *, clearance=0.2, components=None, nets=None, **extra):
    board = {
        "version": 1, "name": "pending-zone", "width_mm": 20, "height_mm": 20,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": clearance, "trace_width_mm": 0.3,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": components if components is not None else [
            {"ref": "R1", "footprint": "R_0805", "x_mm": 10, "y_mm": 10,
             "rotation_deg": 0, "layer": "top"}],
        "nets": nets if nets is not None else [
            {"name": "GND", "pins": ["R1.1"]}, {"name": "SIG", "pins": ["R1.2"]}],
        "zones": zones,
    }
    board.update(extra)
    return board


def _rect(x0, y0, x1, y1):
    return [{"x_mm": x0, "y_mm": y0}, {"x_mm": x1, "y_mm": y0},
            {"x_mm": x1, "y_mm": y1}, {"x_mm": x0, "y_mm": y1}]


def _errors(result):
    return [d.code for d in result.diagnostics
            if d.severity is DiagnosticSeverity.ERROR]


def _pour(board):
    return next(z for z in board.zones if z.kind is ZoneKind.COPPER_POUR)


# --------------------------------------------------------------------------
# 1. HAND-DERIVED CARVE — a tiny pour minus one foreign pad.
# --------------------------------------------------------------------------


def test_hand_derived_area_of_a_pour_minus_one_foreign_pad():
    """The arithmetic, done on paper.

    Board: a 10 x 10 mm pour from (5,5) to (15,15) = 100.000000 mm^2.
    Obstacle: R1's pad 2 on net SIG. R_0805 lands are 1.00 x 1.45 mm, and pad 2
    sits at (10 + 0.95, 10) with no rotation.
    Clearance: 0.2 mm, and a clearance is the Minkowski sum with a disc of that
    radius — so the void is the pad rectangle GROWN by 0.2 on every side with
    QUARTER-DISC corners, not a plain 1.4 x 1.85 rectangle.

        void = (1.00 + 2(0.2)) x (1.45 + 2(0.2))        the enlarged box
             - 4 corner squares of 0.2 x 0.2            which the box counts
             + one full disc of radius 0.2              which the corners are

             = 1.40 * 1.85 - 4(0.04) + pi(0.04)
             = 2.590000 - 0.160000 + 0.125664
             = 2.555664 mm^2

        fill = 100.000000 - 2.555664 = 97.444336 mm^2

    Same-net pad 1 is NOT subtracted (v1 connects solid), which is why only one
    void appears in a pour that covers both pads.

    THE TOLERANCE IS DERIVED, NOT FITTED. The filler flattens the corner
    quarter-discs into segments at ARC_TOLERANCE_NM = 5 um, INSCRIBED, so the
    computed void is slightly smaller than the exact figure and the computed fill
    slightly larger. The area an inscribed approximation can lose on a circle of
    radius r with sagitta at most t is bounded by (2/3) * perimeter * t:

        (2/3) * 2*pi*0.2 * 0.005 = 0.00419 mm^2

    so 0.005 mm^2 is the budget. Observed on the first run: 0.00372 mm^2 — inside
    the bound, which is the check that the bound is the right explanation and not
    a number picked to fit. (The first version of this test said 0.002 and FAILED;
    the tolerance was wrong, not the filler. That is the value of deriving it: a
    tolerance guessed low gets corrected by arithmetic, a tolerance guessed high
    hides whatever it was too wide to see.)

    0.005 mm^2 stays far below every failure this is meant to catch: a missing
    corner treatment or a miter join would each move the void by 0.034 mm^2,
    seven times the budget, and a void missed entirely by 2.56 mm^2.
    """
    result = compile_board(_board([{"net": "GND", "layer": "top",
                                    "outline": _rect(5, 5, 15, 15)}]))
    assert isinstance(result, ResolutionSuccess), _errors(result)
    expected = 100.0 - (1.40 * 1.85 - 4 * 0.04 + math.pi * 0.04)
    assert fill_area_mm2(_pour(result.board)) == pytest.approx(expected, abs=0.005)


def test_same_net_pad_is_not_carved():
    """The pour must MERGE with same-net copper, not carve around it.

    Stated as its own case because the failure is silent and severe: a pour that
    carves its own net is a pour connected to nothing, and it looks completely
    normal on a plot. Proven by counting voids — exactly one (the foreign pad),
    not two.
    """
    import pyclipper as pc

    result = compile_board(_board([{"net": "GND", "layer": "top",
                                    "outline": _rect(5, 5, 15, 15)}]))
    rings = pc.SimplifyPolygons(
        [[(int(round(x * NM_PER_MM)), int(round(y * NM_PER_MM)))
          for (x, y) in poly.points] for poly in _pour(result.board).fill],
        pc.PFT_NONZERO)
    holes = [r for r in rings if not pc.Orientation(r)]
    assert len(holes) == 1, (
        f"expected ONE void (foreign pad only); got {len(holes)} — the same-net "
        f"pad was carved, disconnecting the pour from the net it names")


# --------------------------------------------------------------------------
# 2. KEEPOUT SUBTRACTION — hand-derived, and the net-scoping rule.
# --------------------------------------------------------------------------


def test_keepout_subtracts_its_exact_area():
    """A keepout is subtracted EXACTLY — no clearance band around it.

    A keepout is a boundary, not a feature: copper may come right up to its edge.
    So a 4 x 3 mm keepout removes exactly 12.000000 mm^2, with no inflation. If
    the filler ever inflated keepouts by the clearance the way it inflates
    copper, this catches it (12 mm^2 would become 14.9 mm^2).

    Placed clear of the pads so the two voids do not merge and confuse the sum.
    """
    zones = [{"net": "GND", "layer": "top", "outline": _rect(2, 2, 18, 18)},
             {"kind": "keepout", "layer": "top", "outline": _rect(3, 3, 7, 6)}]
    with_keepout = compile_board(_board(zones))
    without = compile_board(_board([zones[0]]))
    assert isinstance(with_keepout, ResolutionSuccess), _errors(with_keepout)
    delta = fill_area_mm2(_pour(without.board)) - fill_area_mm2(_pour(with_keepout.board))
    assert delta == pytest.approx(12.0, abs=1e-6)


def test_keepout_emits_no_copper_of_its_own():
    """A keepout carries no fill and contributes no Gerber region."""
    zones = [{"net": "GND", "layer": "top", "outline": _rect(2, 2, 18, 18)},
             {"kind": "keepout", "layer": "top", "outline": _rect(3, 3, 7, 6)}]
    board = compile_board(_board(zones)).board
    keepout = next(z for z in board.zones if z.kind is ZoneKind.KEEPOUT)
    assert keepout.fill is None, (
        "a keepout must carry NO fill — not an empty tuple, which would claim a "
        "computed pour that came out empty. It has nothing to compute.")
    files = gerber.build_gerbers_ir(board, name="ko")
    assert files["ko-F_Cu.gbr"].count("G36") == len(_pour(board).fill)


def test_net_scoped_keepout_only_subtracts_from_its_own_net():
    """A keepout NAMING a net constrains only that net's pours.

    Netless == applies to every pour; net-scoped == applies to that net's pours
    alone. Both validators already model this asymmetry; the filler must too, or
    a SIG-scoped keepout would silently eat a GND pour.
    """
    outline = _rect(2, 2, 18, 18)
    plain = compile_board(_board([{"net": "GND", "layer": "top", "outline": outline}]))
    scoped = compile_board(_board([
        {"net": "GND", "layer": "top", "outline": outline},
        {"kind": "keepout", "net": "SIG", "layer": "top", "outline": _rect(3, 3, 7, 6)}]))
    assert fill_area_mm2(_pour(scoped.board)) == pytest.approx(
        fill_area_mm2(_pour(plain.board)), abs=1e-9), (
        "a SIG-scoped keepout must not subtract from a GND pour")


def test_keepout_on_the_other_layer_does_not_subtract():
    """Layer scoping. A bottom keepout cannot cut a top pour."""
    outline = _rect(2, 2, 18, 18)
    plain = compile_board(_board([{"net": "GND", "layer": "top", "outline": outline}]))
    other = compile_board(_board([
        {"net": "GND", "layer": "top", "outline": outline},
        {"kind": "keepout", "layer": "bottom", "outline": _rect(3, 3, 7, 6)}]))
    assert fill_area_mm2(_pour(other.board)) == pytest.approx(
        fill_area_mm2(_pour(plain.board)), abs=1e-9)


# --------------------------------------------------------------------------
# 3. REFUSALS — every one names the zone, and none approximates copper.
# --------------------------------------------------------------------------


def test_authored_thermal_relief_is_REFUSED_not_ignored():
    """THE pending-owner-ruling case (accumulator R-d).

    ``thermal_gap_mm`` and ``thermal_bridge_width_mm`` are real, modeled,
    round-tripping fields. v1 fill implements SOLID connect only. The failure
    mode being prevented is not a crash — it is a board that compiles, fabs, and
    solders badly: solid-tying every ground pad on a HAND-SOLDERED board sinks
    the iron's heat into the plane and produces cold joints on exactly the ground
    pins. Silently ignoring an authored fabrication parameter is the failure
    class this campaign exists to close, so the compile fails and names the zone.
    """
    result = compile_board(_board([{
        "net": "GND", "layer": "top", "outline": _rect(5, 5, 15, 15),
        "thermal_gap_mm": 0.5, "thermal_bridge_width_mm": 0.5}]))
    assert isinstance(result, ResolutionFailure)
    assert "zone_fill_failed" in _errors(result)
    message = " ".join(d.message for d in result.diagnostics)
    assert "thermal" in message and "SOLID" in message


def test_self_intersecting_outline_is_refused():
    """A bow-tie outline has no unambiguous interior — refuse, do not pick one.

    Two readings exist (even-odd gives two triangles, nonzero gives one), they
    differ by real copper, and nothing in the board says which the author meant.
    """
    bowtie = [{"x_mm": 5, "y_mm": 5}, {"x_mm": 15, "y_mm": 15},
              {"x_mm": 15, "y_mm": 5}, {"x_mm": 5, "y_mm": 15}]
    result = compile_board(_board([{"net": "GND", "layer": "top", "outline": bowtie}]))
    assert isinstance(result, ResolutionFailure)
    assert "zone_fill_failed" in _errors(result)


# --- the four pour-pair cases. Only ONE of them is a conflict. -------------
#
# The refusal used to fire on any two different-net pours SHARING A LAYER, which
# is far too broad: a GND pour and a 5V pour side by side on the top layer is how
# a real board is built. The test is now actual polygon intersection, so these
# four cases are the contract.


def test_OVERLAPPING_different_net_pours_are_refused():
    """The one genuine conflict: two nets claiming the SAME copper.

    Refused at COMPILE rather than left to DRC, and the reason is specific.
    GC7 checks a pour against ``drc_geometric.project_board``, which flattens
    pads, traces, vias and board-hole copper — never zone fill. Nothing anywhere
    models pour-versus-pour. Each pour is also filled independently and neither
    carves around the other, so both would claim the overlap and emit literally
    shorted copper that no check on the board reports. And ``priority`` is in the
    IR but never populated, so there is no authored answer to resolve it with.
    """
    result = compile_board(_board([
        {"net": "GND", "layer": "top", "outline": _rect(2, 2, 12, 12)},
        {"net": "SIG", "layer": "top", "outline": _rect(8, 8, 18, 18)}]))
    assert isinstance(result, ResolutionFailure)
    assert "zone_fill_failed" in _errors(result)
    message = " ".join(d.message for d in result.diagnostics)
    assert "mm^2" in message, "the refusal should quantify the overlap it found"


def test_DISJOINT_different_net_pours_are_allowed():
    """THE PRODUCT-BOARD SHAPE. A GND pour and a 5V pour on one layer.

    This is the case the over-broad refusal broke. Two pours on a layer is not a
    conflict; two pours claiming the same copper is. Nothing here overlaps, so
    nothing here is ambiguous.
    """
    result = compile_board(_board([
        {"net": "GND", "layer": "top", "outline": _rect(2, 2, 9, 18)},
        {"net": "SIG", "layer": "top", "outline": _rect(11, 2, 18, 18)}]))
    assert isinstance(result, ResolutionSuccess), _errors(result)
    assert len([z for z in result.board.zones
                if z.kind is ZoneKind.COPPER_POUR]) == 2


def test_OVERLAPPING_same_net_pours_are_allowed():
    """Same potential, so an overlap is a UNION and not a short.

    Worth stating because the naive fix for the case above — "refuse any two
    pours that intersect" — would reject this, and two overlapping GND pours are
    a completely ordinary way to describe an L-shaped ground plane.
    """
    result = compile_board(_board([
        {"net": "GND", "layer": "top", "outline": _rect(2, 2, 12, 12)},
        {"net": "GND", "layer": "top", "outline": _rect(8, 8, 18, 18)}]))
    assert isinstance(result, ResolutionSuccess), _errors(result)


def test_DISJOINT_same_net_pours_are_allowed():
    """Two islands of one net — legitimate, and each fills independently."""
    result = compile_board(_board([
        {"net": "GND", "layer": "top", "outline": _rect(2, 2, 9, 9)},
        {"net": "GND", "layer": "top", "outline": _rect(11, 11, 18, 18)}]))
    assert isinstance(result, ResolutionSuccess), _errors(result)


def test_different_net_pours_on_DIFFERENT_layers_never_conflict():
    """Overlapping outlines on opposite layers are not on the same copper."""
    result = compile_board(_board([
        {"net": "GND", "layer": "top", "outline": _rect(2, 2, 18, 18)},
        {"net": "SIG", "layer": "bottom", "outline": _rect(2, 2, 18, 18)}]))
    assert isinstance(result, ResolutionSuccess), _errors(result)


def test_a_pour_swallowed_by_a_keepout_is_empty_not_absent():
    """``()`` is a COMPUTED empty pour and is not the same fact as ``None``.

    An emitter must be able to tell "we worked it out and there is no copper"
    from "we never worked it out". The first is fabricable; the second is a
    refusal.
    """
    result = compile_board(_board([
        {"net": "GND", "layer": "top", "outline": _rect(6, 6, 10, 10)},
        {"kind": "keepout", "layer": "top", "outline": _rect(5, 5, 11, 11)}]))
    assert isinstance(result, ResolutionSuccess), _errors(result)
    pour = _pour(result.board)
    assert pour.fill == ()
    assert "zone_fill_empty" in [d.code for d in result.diagnostics]
    gerber.build_gerbers_ir(result.board, name="empty")  # fabricable, not refused


def test_unfilled_pour_never_reaches_any_emitter():
    """All four seals, restated over a hand-stripped board."""
    from pcb_worker.route_bridge import _reject_unroutable_board
    from pcb_worker.drc_geometric import run_geometric_drc

    board = compile_board(_board([{"net": "GND", "layer": "top",
                                   "outline": _rect(5, 5, 15, 15)}])).board
    stripped = replace(board, zones=(replace(board.zones[0], fill=None),))
    with pytest.raises(ValueError):
        gerber.build_gerbers_ir(stripped, name="x")
    with pytest.raises(ValueError):
        kicad._ir_board_dict(stripped)
    assert run_geometric_drc(stripped)["verdict"] == "indeterminate"
    _reject_unroutable_board(stripped)  # a POUR is routable; only keepouts are not


# --------------------------------------------------------------------------
# 4. DETERMINISM, re-asserted at the IR level.
# --------------------------------------------------------------------------


def test_fill_geometry_is_identical_across_runs():
    """The determinism gate compares emitted BYTES; this compares the polygons.

    Both are worth having: the gate would catch a non-deterministic fill only
    through the Gerber it produces, which means a fill that varied in a way the
    emitter rounds away would slip past. Vertex-for-vertex equality on the IR is
    the tighter statement, and it is the one the "exact integer arithmetic"
    claim actually makes.
    """
    src = _board([{"net": "GND", "layer": "top", "outline": _rect(3, 3, 17, 17)},
                  {"kind": "keepout", "layer": "top", "outline": _rect(4, 4, 6, 6)}])
    first = _pour(compile_board(copy.deepcopy(src)).board)
    second = _pour(compile_board(copy.deepcopy(src)).board)
    assert [p.points for p in first.fill] == [p.points for p in second.fill]


def test_fill_is_quantized_to_whole_nanometres():
    """Every emitted vertex is an exact integer number of nanometres.

    The determinism claim rests on the booleans running in an integer domain. A
    coordinate that is not a whole nanometre means something re-entered float
    space between the boolean and the IR, and the "structural, not tested-for"
    reproducibility argument no longer holds.
    """
    board = compile_board(_board([{"net": "GND", "layer": "top",
                                   "outline": _rect(3, 3, 17, 17)}])).board
    for polygon in _pour(board).fill:
        for (x, y) in polygon.points:
            assert abs(x * NM_PER_MM - round(x * NM_PER_MM)) < 1e-6
            assert abs(y * NM_PER_MM - round(y * NM_PER_MM)) < 1e-6


# --------------------------------------------------------------------------
# 5. UNFABRICABLE FILL REGIONS — islands and slivers are REFUSED.
#
#    These three cases used to be SILENT pytest.skip()s carrying prose about
#    what v1 did not do. A skip reads as coverage in a green tally, so the
#    tally said 3 green over three known-broken behaviours. They are now
#    executable, and the one piece that genuinely cannot be built inside this
#    schema is xfail-with-reason rather than skipped.
#
#    EVERY EXPECTED NUMBER BELOW IS HAND-DERIVED from the clearance definition
#    and the profile's published floor, exactly as section 1 derives its areas.
#    None was read off the filler.
# --------------------------------------------------------------------------

# v1-fab-conservative's published minimum feature. Quoted as a literal rather
# than read from the profile at test time: a test that imports the number it is
# checking cannot notice the number changing.
MIN_FEATURE_MM = 0.127


def _severing_trace(y_mm):
    """A SIG trace running clear across the pour at ``y_mm``, 0.3 mm wide.

    Its clearance void reaches 0.15 (half width) + 0.2 (clearance) = 0.35 mm
    each side of the centreline, so the void's near edge sits at y - 0.35. The
    trace starts and ends OUTSIDE the pour, so the void spans the pour's full
    width and the strip below it is a separate region.
    """
    return [{"net": "SIG", "layer": "top", "width_mm": 0.3,
             "points": [{"x_mm": 2.0, "y_mm": y_mm}, {"x_mm": 18.0, "y_mm": y_mm}]}]


def test_a_sub_floor_fill_fragment_is_REFUSED_and_named():
    """A fill region nowhere as wide as the fab's minimum feature is refused.

    THE ARITHMETIC, on paper. Pour (3,3)-(17,17). A SIG trace at y = 3.47 puts
    its void's near edge at 3.47 - 0.35 = 3.12, so the strip left between the
    pour's bottom edge and that void is

        y from 3.00 to 3.12   ->   0.120 mm tall
        x from 3.00 to 17.00  ->  14.000 mm long
        area = 14.000 * 0.120 =  1.680000 mm^2

    and 0.120 mm is below v1-fab-conservative's 0.127 mm min_trace_width_mm, so
    no part of that strip etches reliably. The refusal must NAME it: an author
    told only "zone failed" has to rediscover which piece and why.

    WHY REFUSED RATHER THAN CULLED. KiCad sheds this strip silently, at its
    zone's own min_thickness. Our schema has no such field to read, so culling
    would mean deleting the author's copper by a rule invented here. See
    zone_fill._refuse_unfabricable_regions.
    """
    result = compile_board(_board(
        [{"net": "GND", "layer": "top", "outline": _rect(3, 3, 17, 17)}],
        traces=_severing_trace(3.47)))
    assert isinstance(result, ResolutionFailure)
    assert "zone_fill_failed" in _errors(result)
    message = next(d.message for d in result.diagnostics
                   if d.code == "zone_fill_failed")
    assert "SLIVER" in message
    assert "1.680000 mm^2" in message, message
    assert f"{MIN_FEATURE_MM} mm minimum feature" in message, message
    # The bounding box locates the offending piece on the board.
    assert "(3.0000,3.0000)-(17.0000,3.1200)" in message, message


def test_a_fill_fragment_attached_to_no_same_net_copper_is_REFUSED_and_named():
    """An island — live copper attached to nothing — is refused, not emitted.

    THE ARITHMETIC. Same pour, but the trace moves to y = 4.35 so its void's
    near edge lands at 4.35 - 0.35 = 4.00 and the strip below is

        y from 3.00 to 4.00   ->  1.000 mm tall   (7.9x the 0.127 floor, so
                                                   this is NOT a sliver)
        x from 3.00 to 17.00  -> 14.000 mm long
        area = 14.000 * 1.000 = 14.000000 mm^2

    The strip contains no GND copper: R1's GND pad is at (9.05, 10), far above
    it. The rest of the pour keeps that pad and is therefore attached.

    THE HEIGHT IS LOAD-BEARING. At 1.000 mm this region is comfortably
    manufacturable, so the ONLY thing wrong with it is that it connects to
    nothing — which is what makes this a test of the island rule and not of the
    sliver rule wearing its name.

    MEASURED AGAINST THE ORACLE (KiCad 9.0.9): pcbnew's ZONE_FILLER deletes a
    severed fragment like this one, and restoring it requires setting
    island_removal_mode away from its default. So the FAULT is real and
    independently confirmed; only the response (refuse vs cull) differs, for
    the reason the sliver test states.
    """
    result = compile_board(_board(
        [{"net": "GND", "layer": "top", "outline": _rect(3, 3, 17, 17)}],
        traces=_severing_trace(4.35)))
    assert isinstance(result, ResolutionFailure)
    assert "zone_fill_failed" in _errors(result)
    message = next(d.message for d in result.diagnostics
                   if d.code == "zone_fill_failed")
    assert "ISLAND" in message
    assert "14.000000 mm^2" in message, message
    assert "(3.0000,3.0000)-(17.0000,4.0000)" in message, message
    # Named by the AUTHORED net name, not by the internal net id hash.
    assert "overlaps no GND copper on top" in message, message
    assert "severed from the rest of this pour" in message, message


def test_sliver_wins_over_island_when_one_region_is_both():
    """Fixed precedence, so the message does not depend on evaluation order.

    The 0.120 mm strip of the sliver case is ALSO attached to no GND copper, so
    both faults hold of it. The report names the sliver: "cannot be etched" is a
    fact about the fab and outranks "connects to nothing", which is a fact about
    the netlist. An author sent to fix the netlist first would reconnect a strip
    that still cannot be made.
    """
    result = compile_board(_board(
        [{"net": "GND", "layer": "top", "outline": _rect(3, 3, 17, 17)}],
        traces=_severing_trace(3.47)))
    message = next(d.message for d in result.diagnostics
                   if d.code == "zone_fill_failed")
    assert "SLIVER" in message
    assert "ISLAND" not in message, message
    assert "1 region(s)" in message, message


def test_a_sound_pour_trips_NEITHER_refusal():
    """The no-false-positive seal, and the reason the two checks are safe to add.

    A plain pour over both of R1's pads has one region, is far wider than the
    floor everywhere, and holds the GND pad. Neither check may fire. Without
    this, a check that refused everything would pass all three tests above.
    """
    result = compile_board(_board(
        [{"net": "GND", "layer": "top", "outline": _rect(3, 3, 17, 17)}]))
    assert isinstance(result, ResolutionSuccess), _errors(result)
    assert _pour(result.board).fill


def test_a_convex_corner_is_not_mistaken_for_a_sliver():
    """The sliver test is topological, so corner geometry cannot trip it.

    KiCad's min-thickness pass rounds every convex corner, because it deflates
    and re-inflates. A check built that way would have to tell corner rounding
    from a real defect by area, i.e. by a fitted threshold. This one asks only
    whether the region still contains a disc of radius floor/2 — which a square
    corner does — so a pour made ENTIRELY of sharp corners stays clean.
    """
    result = compile_board(_board(
        [{"net": "GND", "layer": "top",
          "outline": [{"x_mm": 3, "y_mm": 3}, {"x_mm": 17, "y_mm": 3},
                      {"x_mm": 17, "y_mm": 17}, {"x_mm": 11, "y_mm": 17},
                      {"x_mm": 11, "y_mm": 11}, {"x_mm": 3, "y_mm": 11}]}]))
    assert isinstance(result, ResolutionSuccess), _errors(result)


def test_the_island_rule_is_scoped_to_pours_that_HAVE_same_net_copper():
    """The check's reference set, pinned — this is why two older tests still pass.

    A GND pour placed clear of every GND feature has no same-net copper on its
    layer at all. "Island" means the carve SEVERED a piece from the net's
    copper; with no such copper there is nothing to be severed from, and a check
    that answered anyway would report every region of every floating pour while
    having lost the ability to tell a severed fragment from an intact one.

    So the rule is scoped, and the scope is sealed here rather than left as an
    accident of the code — which is what makes the remaining hole (the xfail
    below) a stated boundary instead of an unnoticed one.
    """
    result = compile_board(_board([
        {"net": "GND", "layer": "top", "outline": _rect(2, 2, 9, 9)}]))
    assert isinstance(result, ResolutionSuccess), _errors(result)
    assert _pour(result.board).fill


@pytest.mark.xfail(
    strict=True,
    reason="STATED GAP, not a flake: a pour with NO same-net copper on its layer "
           "is filled and emitted. It is floating copper, and KiCad would delete "
           "all of it, but it is a WHOLE-POUR fact rather than the severed-"
           "fragment fact the island rule is about, and the existing suite "
           "blesses it (test_DISJOINT_same_net_pours_are_allowed). Closing it is "
           "a separate behaviour change with its own diagnostic, NOT blocked on "
           "the thermal ruling R-d.")
def test_GAP_a_pour_attached_to_no_same_net_copper_at_all_is_still_emitted():
    """The residue of the island gap, stated as a failing expectation."""
    result = compile_board(_board([
        {"net": "GND", "layer": "top", "outline": _rect(2, 2, 9, 9)}]))
    assert isinstance(result, ResolutionFailure)
    assert "zone_fill_failed" in _errors(result)


@pytest.mark.xfail(
    strict=True,
    reason="STATED GAP, not a flake: a sub-floor NECK inside an otherwise sound "
           "region is not detected. Catching it needs the deflate/re-inflate "
           "opening KiCad performs, which rounds every convex corner and so "
           "cannot be told from a real defect without a fitted area threshold. "
           "The honest form is an authored ResolvedZone.min_thickness_mm applied "
           "as KiCad applies it — a board-schema change that also needs the Go "
           "validator to carry the field, or validate and compile would disagree "
           "about a fabrication parameter. OUT OF SCOPE for a pcb/worker-only "
           "change; NOT blocked on the thermal ruling R-d.")
def test_GAP_a_sub_floor_neck_inside_a_sound_region_is_not_detected():
    """The residue of the min-thickness gap, stated as a failing expectation.

    A mounting hole whose void stops 0.120 mm short of the pour edge leaves a
    crescent of copper that is thinner than the 0.127 mm floor at its waist but
    is CONNECTED to the pour around both ends. The region as a whole is wide,
    so the region-level deflation survives and nothing is reported.

    Hole at (10, 16.68), diameter 2.0 -> void radius 1.0 + 0.2 = 1.2, so the
    void's top reaches 16.68 + 1.2 = 17.88 against a pour edge at 18.00: a
    0.120 mm waist.

    This is the case KiCad DOES catch, at its zone min_thickness. Recorded as an
    xfail so the tally counts it as a known open rather than as coverage.
    """
    result = compile_board(_board(
        [{"net": "GND", "layer": "top", "outline": _rect(2, 2, 18, 18)}],
        mounting_holes=[{"x_mm": 10.0, "y_mm": 16.68, "diameter_mm": 2.0,
                         "plated": False}]))
    assert isinstance(result, ResolutionFailure)
    assert "zone_fill_failed" in _errors(result)


# --------------------------------------------------------------------------
# 6. HOLE-TO-COPPER — the rule the schema could not previously state.
#
#    Was a silent skip reading "documents a missing schema field". The field
#    now exists as ManufacturingConstraints.min_hole_to_copper_mm, OPTIONAL so
#    that a profile which publishes no such number is not made to invent one.
# --------------------------------------------------------------------------

# A floor identical to v1-fab-conservative except where a test says otherwise.
# Spelled out rather than loaded and mutated: a fixture that copies the shipped
# profile would silently follow it if it changed, and these expectations are
# hand-computed against these exact numbers.
_BASE_FLOOR = {
    "min_trace_width_mm": 0.127, "min_clearance_mm": 0.127, "min_drill_mm": 0.2,
    "min_finished_hole_mm": 0.2, "min_annular_ring_mm": 0.13,
    "min_hole_to_hole_mm": 0.25, "min_mask_sliver_mm": 0.1,
    "solder_mask_clearance_mm": 0.05, "solder_mask_expansion_mm": 0.0,
    "copper_to_edge_mm": 0.3,
}


def _profile(tmp_path, **floor_overrides):
    """Write a one-off profile and return its id."""
    floor = dict(_BASE_FLOOR)
    floor.update(floor_overrides)
    (tmp_path / "probe-fab.json").write_text(
        json.dumps({"id": "probe-fab", "version": "1", "floor": floor}),
        encoding="utf-8")
    return "probe-fab"


def _holed_board(profile_id):
    """Pour (5,5)-(15,15) with ONE netless unplated hole at (7,13), d = 2.0.

    The hole sits clear of R1's pads (which are at y = 10) so its void never
    merges with the pad void and the two areas stay separately derivable.
    """
    board = _board([{"net": "GND", "layer": "top", "outline": _rect(5, 5, 15, 15)}],
                   mounting_holes=[{"x_mm": 7.0, "y_mm": 13.0,
                                    "diameter_mm": 2.0, "plated": False}])
    board["design_rules"]["rule_profile"] = profile_id
    return board


def _fill_of(board, tmp_path):
    result = compile_board(board, profile_root=tmp_path)
    assert isinstance(result, ResolutionSuccess), _errors(result)
    return fill_area_mm2(_pour(result.board))


def test_a_profile_stating_hole_to_copper_widens_the_drill_void(tmp_path):
    """The rule reaches the copper, and by exactly the derived amount.

    THE ARITHMETIC. The hole's radius is 1.0 mm. A clearance is a Minkowski sum
    with a disc, so the void around a round hole is a disc of radius
    (1.0 + gap) and its area is pi(1.0 + gap)^2.

        gap = 0.2 (the zone clearance, no hole rule)  -> pi(1.2)^2 = 4.523893
        gap = 0.5 (min_hole_to_copper_mm = 0.5)       -> pi(1.5)^2 = 7.068583

        the pour loses exactly the annulus between them:
            pi(1.5^2 - 1.2^2) = pi(0.81) = 2.544690 mm^2

    THE TOLERANCE IS DERIVED, as everywhere else in this file. Both voids are
    inscribed polygon approximations at ARC_TOLERANCE_NM = 5 um, so each
    UNDER-states its circle by at most (2/3) * perimeter * t:

        r = 1.2 ->  (2/3)(2*pi*1.2)(0.005) = 0.025133
        r = 1.5 ->  (2/3)(2*pi*1.5)(0.005) = 0.031416

    The difference of the two errors lies in [-0.025133, +0.031416], so 0.035
    mm^2 is the budget and nothing smaller than the effect is being tested: the
    annulus is 2.54 mm^2, seventy times the budget.
    """
    strict = _profile(tmp_path, min_hole_to_copper_mm=0.5)
    with_rule = _fill_of(_holed_board(strict), tmp_path)

    (tmp_path / "loose-fab.json").write_text(
        json.dumps({"id": "loose-fab", "version": "1", "floor": dict(_BASE_FLOOR)}),
        encoding="utf-8")
    without_rule = _fill_of(_holed_board("loose-fab"), tmp_path)

    lost = without_rule - with_rule
    assert lost == pytest.approx(math.pi * (1.5 ** 2 - 1.2 ** 2), abs=0.035)


def test_a_profile_omitting_hole_to_copper_carves_at_the_copper_clearance(tmp_path):
    """The fallback, pinned as a NUMBER rather than as "unchanged".

    A profile that states no hole-to-copper rule leaves the pour carving the
    hole at the ordinary 0.2 mm zone clearance — v1's behaviour, now a stated
    fallback. Pinned against the hand-derived total so that "no rule" cannot
    quietly start meaning "some other rule":

        pour                     10 x 10           = 100.000000 mm^2
        minus R1 pad 2's void    (section 1)       =  -2.555664
        minus the hole's void    pi(1.0 + 0.2)^2   =  -4.523893
                                                     ------------
                                                      92.920443 mm^2

    Budget: the two inscribed voids under-state by at most 0.004189 and 0.025133
    respectively, so 0.030 mm^2.
    """
    plain = _profile(tmp_path)
    assert "min_hole_to_copper_mm" not in _BASE_FLOOR
    expected = 100.0 - (1.40 * 1.85 - 4 * 0.04 + math.pi * 0.04) - math.pi * 1.2 ** 2
    assert _fill_of(_holed_board(plain), tmp_path) == pytest.approx(expected, abs=0.030)


def test_hole_to_copper_does_NOT_reinstate_the_same_net_stitching_via_moat(tmp_path):
    """The trap this rule could most easily have re-opened.

    A same-net plated via inside its own pour is deliberately NOT carved at all
    (see zone_fill._obstacle_paths): its barrel is the pour's own net, so it is
    the connection rather than a hazard, and carving it moats the via and
    silently disconnects the pour. A hole-to-copper rule applied to EVERY hole
    would put that moat straight back — at a LARGER radius than the bug that was
    fixed, since the whole point of the rule is a bigger number.

    So the rule is applied after the same-net-plated skip, and this pins it: an
    aggressive 0.9 mm hole-to-copper (which would carve a void of radius
    1.0 + 0.9 = 1.9 mm around a 0.4 mm via land, obliterating it) must leave the
    fill EXACTLY as it is without the rule.
    """
    board_kwargs = dict(
        vias=[{"x_mm": 8.0, "y_mm": 8.0, "drill_mm": 0.4, "diameter_mm": 0.8,
               "net": "GND", "from_layer": "top", "to_layer": "bottom"}])
    strict = _profile(tmp_path, min_hole_to_copper_mm=0.9)
    board = _board([{"net": "GND", "layer": "top", "outline": _rect(5, 5, 15, 15)}],
                   **board_kwargs)
    board["design_rules"]["rule_profile"] = strict
    with_rule = _fill_of(board, tmp_path)

    (tmp_path / "loose-fab.json").write_text(
        json.dumps({"id": "loose-fab", "version": "1", "floor": dict(_BASE_FLOOR)}),
        encoding="utf-8")
    board2 = _board([{"net": "GND", "layer": "top", "outline": _rect(5, 5, 15, 15)}],
                    **board_kwargs)
    board2["design_rules"]["rule_profile"] = "loose-fab"
    without_rule = _fill_of(board2, tmp_path)

    assert with_rule == without_rule, (
        "a hole-to-copper rule carved the same-net stitching via — the moat bug "
        "is back, and the pour is silently open")


def test_hole_to_copper_is_a_FLOOR_not_a_replacement(tmp_path):
    """A hole rule BELOW the copper clearance must not shrink the void.

    Both numbers are floors, so the carve takes the maximum. A rule that simply
    replaced the clearance would let a permissive hole number undercut the
    copper clearance a foreign via still has to respect.
    """
    lax = _profile(tmp_path, min_hole_to_copper_mm=0.05)
    with_lax = _fill_of(_holed_board(lax), tmp_path)

    (tmp_path / "loose-fab.json").write_text(
        json.dumps({"id": "loose-fab", "version": "1", "floor": dict(_BASE_FLOOR)}),
        encoding="utf-8")
    without_rule = _fill_of(_holed_board("loose-fab"), tmp_path)

    assert with_lax == without_rule, (
        "a 0.05 mm hole rule shrank the void below the 0.2 mm copper clearance")


def test_foreign_nets_class_widens_the_carve():
    """KILLER for the corpus mutant zone_fill_clearance_ignores_the_foreign_
    nets_class (GA testex survivor triage — the Z2 half survived because no
    test drove a pour whose FOREIGN participant's class demands the wider
    gap). Same hand-derived fixture as the headline carve test, plus a net
    class on SIG (the foreign pad's net) with min_clearance_mm 0.4: the
    void's ring grows from 0.2 to 0.4 on every side.

        void = (1.00 + 0.8) * (1.45 + 0.8) - 4(0.16) + pi(0.16)
             = 4.050000 - 0.640000 + 0.502655 = 3.912655 mm^2
        fill = 100.000000 - 3.912655 = 96.087345 mm^2

    The mutant folds only the ZONE's own net (GND, class-less), leaving the
    0.2 ring and area 97.444336 — 1.36 mm^2 off, four hundred times the
    derived tolerance ((2/3) * 2*pi*0.4 * 0.005 = 0.0084)."""
    board = _board([{"net": "GND", "layer": "top",
                     "outline": _rect(5, 5, 15, 15)}])
    board["design_rules"] = dict(
        board["design_rules"],
        net_classes=[{"name": "Fat", "members": ["SIG"],
                      "min_clearance_mm": 0.4}])
    result = compile_board(board)
    assert isinstance(result, ResolutionSuccess), _errors(result)
    expected = 100.0 - (1.80 * 2.25 - 4 * 0.16 + math.pi * 0.16)
    assert fill_area_mm2(_pour(result.board)) == pytest.approx(expected, abs=0.009)
