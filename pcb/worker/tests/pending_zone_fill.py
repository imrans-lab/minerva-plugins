"""PARKED — zone-fill cases authored during C6, not collected this epoch.

Named ``pending_*`` so pytest's default ``test_*`` discovery never picks it up
(verified: ``--collect-only`` reports zero of these). It is checked in inert, and
it py-compiles, so it cannot rot silently while it waits.

WHAT IS PARKED HERE, AND WHY IT IS NOT IN THE LIVE SUITE. The executable tests
that shipped with C6 prove the fill is RIGHT (oracle parity), REPRODUCIBLE
(determinism gate) and FAIL-CLOSED at the four emitter seals. These add the
hand-derived arithmetic and the refusal matrix — the cases whose value is that a
human worked out the answer independently of the code, which is exactly the kind
of test the epoch's regime holds until the boundary so the numbers get read
rather than run.

The hand-computed coordinates below were derived on paper from the clearance
definition (a Minkowski sum with a disc of radius = clearance), NOT copied out of
the filler's output. That is the whole point of them: a test whose expected value
came from the implementation proves the implementation equals itself.
"""

from __future__ import annotations

import copy
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
# 5. STATED v1 GAPS — parked as the record of what v1 does NOT do.
#    These document behaviour, they do not bless it.
# --------------------------------------------------------------------------


def test_GAP_min_thickness_sliver_is_kept():
    """v1 KEEPS a copper ribbon thinner than KiCad's 0.25 mm min-thickness.

    Measured against the oracle at implementation time: a mounting hole placed so
    its clearance void stopped 0.2 mm short of the pour edge left a 0.64 x 0.2 mm
    ribbon that KiCad dropped and we kept — a 0.128 mm^2 disagreement that
    survived a 130 um dilation, so a shape difference rather than a boundary
    approximation.

    Not a defect under the current contract: no min-thickness is authorable
    (``ResolvedZone.min_thickness_mm`` exists in the IR and is never populated),
    and dropping copper the author drew needs a rule the author wrote. It IS a
    fabrication concern — a sliver that thin can lift or under-etch — so it is
    recorded here rather than left to be rediscovered.
    """
    pytest.skip("documents a stated v1 gap; unskip when min-thickness is authorable")


def test_GAP_isolated_island_is_kept():
    """v1 KEEPS a pour fragment connected to no same-net copper; KiCad drops it.

    An island is live copper attached to nothing — an antenna, and on a ground
    pour a small one at that. KiCad removes them by default. v1 does not, for the
    same reason as above: the rule is not authorable. A fixture containing one
    cannot reach oracle parity, which is why the C6 fixture is laid out to avoid
    producing one.
    """
    pytest.skip("documents a stated v1 gap; unskip when island removal is authorable")


def test_GAP_hole_to_copper_clearance_is_not_modeled():
    """Our schema has no hole-to-copper rule, so holes get the COPPER clearance.

    ``ManufacturingConstraints`` carries ``min_hole_to_hole_mm`` and
    ``min_annular_ring_mm`` but nothing for hole-to-copper. KiCad's default is
    0.25 mm; our zone clearance on the C6 fixture is 0.20 mm, and the 50 um
    difference is the LARGEST single term in the oracle parity gap (0.4626 of
    0.5487 mm^2). Fabrication-relevant: a drill that wanders can break into
    copper 0.2 mm away.
    """
    pytest.skip("documents a missing schema field; unskip when the rule exists")
