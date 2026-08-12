"""GC8 — solder-mask sliver (epoch CP2 station S5).

AUTHORED, NOT EXECUTED during CP2: this epoch writes tests at every station and
runs them for the first time after the Fable and Codex rounds that follow S8.

WHAT THIS CHECK IS FOR. ``min_mask_sliver_mm`` is a REQUIRED profile floor that,
until this station, had ZERO production readers — every appearance outside tests
was a declaration or a validation of the declaration. A required tier whose
justification is "a MISSING one of these must fail the load" is hollow while a
PRESENT one is never read by anything.

THE THREE REGIMES, which are the whole test surface. A sliver is the WEB of mask
left standing BETWEEN two openings:

    web >= floor      thick enough to survive processing.  Clean.
    0 < web < floor   a ribbon too thin to adhere.  THE VIOLATION.
    web <= 0          the openings merge; there is no web at all.  NOT a
                      violation, and flagging it would be wrong twice over — it
                      is not a sliver, and merged openings are a deliberate,
                      ordinary authoring outcome.

The middle regime is a BAND, not a floor comparison, and the tests below spend
most of their effort on the two boundaries of that band rather than on the easy
middle — because both boundaries are places a plausible implementation goes
quietly wrong, and the lower one goes wrong in the false-clean direction.
"""

from __future__ import annotations

import dataclasses
import math

import pytest

from pcb_worker import drc_geometric, mask_source
from pcb_worker.drc_geom_primitives import (
    Capsule,
    OrientedRect,
    RoundedRect,
    convex_edge_distance,
    AABB,
)
from pcb_worker.drc_geometric import (
    Projection,
    _check_gc8_mask_sliver,
    _mask_shape,
)
from pcb_worker.resolved_board import Side

FLOOR = 0.1


class _Minimums:
    def __init__(self, floor):
        self.min_mask_sliver_mm = floor


class _Rules:
    def __init__(self, floor):
        self.minimums = _Minimums(floor)


class _Board:
    """The narrowest stand-in GC8 actually reads.

    A compiled ResolvedBoard is deliberately NOT used here: GC8 consumes exactly
    ``rb.design_rules.minimums.min_mask_sliver_mm`` and the projection's mask
    tuple, so a stub keeps each failure attributable to the rule under test
    rather than to compilation. The end-to-end wiring is covered separately, in
    test_mask_projection.py, against the real coupon.
    """

    def __init__(self, floor=FLOOR):
        self.design_rules = _Rules(floor)


def _rect(x, y, w=1.0, h=1.0, side=Side.TOP, entity="p", angle=0.0):
    return mask_source.MaskOpening(
        x=x, y=y, shape="rect", width=w, height=h, corner_rratio=None,
        angle_deg=angle, side=side, origin=mask_source.ORIGIN_SMD_PAD,
        entity_id=entity)


def _run(openings, floor=FLOOR):
    proj = Projection(copper=(), holes=(), annular=(), mask=tuple(openings))
    return _check_gc8_mask_sliver(proj, _Board(floor))


def _gap_pair(gap: float, **kw):
    """Two 1mm squares whose facing edges are exactly ``gap`` apart."""
    return [_rect(0.0, 0.0, entity="a", **kw),
            _rect(1.0 + gap, 0.0, entity="b", **kw)]


# ---------------------------------------------------------------------------
# The band.
# ---------------------------------------------------------------------------


def test_a_web_below_the_floor_is_a_sliver():
    findings = _run(_gap_pair(0.05))
    assert len(findings) == 1
    f = findings[0]
    assert f["type"] == "gc8_mask_sliver"
    assert f["measured_mm"] == pytest.approx(0.05)
    assert f["required_mm"] == pytest.approx(FLOOR)


def test_a_web_above_the_floor_is_clean():
    assert _run(_gap_pair(0.2)) == []


def test_a_web_exactly_at_the_floor_passes():
    """AT the floor is a PASS, matching every other check in this module
    (``_violates`` treats a measurement within EPS of the floor as satisfying
    it). A board authored exactly to a published minimum must not be rejected by
    float noise."""
    assert _run(_gap_pair(FLOOR)) == []


def test_merged_openings_are_not_a_sliver():
    """THE REGIME A FLOOR COMPARISON GETS WRONG. Two overlapping openings have
    NO mask between them, so there is no ribbon to lift. A naive `web < floor`
    test reports a violation here — and reports it on every fine-pitch part
    whose pads share one opening, which is a normal thing to author."""
    assert _run(_gap_pair(-0.3)) == []


def test_exactly_touching_openings_are_not_a_sliver():
    """The lower edge of the band. Zero web is the merge case, not an
    infinitely-thin sliver: the check must exclude it, and excluding it at
    exactly 0 is what makes the band half-open."""
    assert _run(_gap_pair(0.0)) == []


def test_a_hairline_web_just_above_zero_is_still_a_sliver():
    """The counterpart to the test above, and the reason that one cannot be
    implemented as `web < EPS -> clean` carelessly. A web of 1 micron is the
    WORST case of this defect, not an edge case to be swallowed — it must
    report, or the check silently ignores exactly the slivers it exists to
    catch."""
    findings = _run(_gap_pair(0.001))
    assert len(findings) == 1
    assert findings[0]["measured_mm"] == pytest.approx(0.001)


# ---------------------------------------------------------------------------
# Sides.
# ---------------------------------------------------------------------------


def test_openings_on_opposite_sides_are_never_paired():
    """F.Mask and B.Mask are different physical films. A front opening and a back
    opening have no mask between them, so pairing them would manufacture
    findings out of geometry that never touches."""
    assert _run([_rect(0.0, 0.0, side=Side.TOP, entity="a"),
                 _rect(1.05, 0.0, side=Side.BOTTOM, entity="b")]) == []


def test_both_sides_are_checked():
    """The mirror of the test above: bottom openings must not be silently
    skipped. S3 made back silk real and S4 made back mask real, so a check that
    only walked the front would clear half of every two-sided board."""
    findings = _run([_rect(0.0, 0.0, side=Side.BOTTOM, entity="a"),
                     _rect(1.05, 0.0, side=Side.BOTTOM, entity="b")])
    assert len(findings) == 1
    assert findings[0]["layer"] == "B.Mask"


def test_the_finding_names_the_mask_layer_not_the_copper_layer():
    findings = _run(_gap_pair(0.05))
    assert findings[0]["layer"] == "F.Mask"


# ---------------------------------------------------------------------------
# Attribution.
# ---------------------------------------------------------------------------


def test_the_finding_names_both_participants_and_their_kinds():
    """A sliver is a property of a PAIR, so a finding a human can act on has to
    say which two features formed it and what kind each was — 'a sliver
    somewhere on F.Mask' is not actionable on a board with 200 openings."""
    findings = _run(_gap_pair(0.05))
    extra = findings[0]
    assert extra["entity_id"] == "a|b"
    participants = extra["participants"]
    assert [p["entity_id"] for p in participants] == ["a", "b"]
    assert all(p["origin"] == mask_source.ORIGIN_SMD_PAD for p in participants)


def test_findings_are_deterministic_in_participant_order():
    """Same board, same order, every run — so a golden or a diff of DRC output
    is stable. Insertion order is deliberately reversed here to prove the check
    sorts rather than inheriting the projection's order."""
    a, b = _gap_pair(0.05)
    assert _run([a, b])[0]["entity_id"] == _run([b, a])[0]["entity_id"]


def test_every_pair_is_reported_not_just_the_first():
    """Three openings in a row produce two adjacent slivers. A loop that broke
    on the first finding would report one and leave the board looking half as
    bad as it is."""
    findings = _run([_rect(0.0, 0.0, entity="a"),
                     _rect(1.05, 0.0, entity="b"),
                     _rect(2.10, 0.0, entity="c")])
    assert len(findings) == 2


# ---------------------------------------------------------------------------
# Aperture shapes — the exactness that keeps a sliver from hiding.
# ---------------------------------------------------------------------------


def test_circle_opening_maps_to_a_disc():
    shape = _mask_shape(mask_source.circle_opening(
        1.0, 2.0, 0.8, Side.TOP, mask_source.ORIGIN_VIA))
    assert isinstance(shape, Capsule)
    assert (shape.ax, shape.ay) == (shape.bx, shape.by) == (1.0, 2.0)
    assert shape.r == pytest.approx(0.4)


def test_two_circles_are_measured_edge_to_edge_not_centre_to_centre():
    """Centre distance minus nothing would read 1.0 here; the web is 0.2."""
    a = mask_source.circle_opening(0.0, 0.0, 0.8, Side.TOP,
                                   mask_source.ORIGIN_VIA, "a")
    b = mask_source.circle_opening(1.0, 0.0, 0.8, Side.TOP,
                                   mask_source.ORIGIN_VIA, "b")
    assert convex_edge_distance(_mask_shape(a), _mask_shape(b)) == \
        pytest.approx(0.2)


def test_oval_opening_maps_to_a_stadium_along_its_major_axis():
    opening = mask_source.MaskOpening(
        x=0.0, y=0.0, shape="oval", width=2.0, height=1.0, corner_rratio=None,
        angle_deg=0.0, side=Side.TOP, origin=mask_source.ORIGIN_TH_PAD)
    shape = _mask_shape(opening)
    assert isinstance(shape, Capsule)
    assert shape.r == pytest.approx(0.5)
    # Major axis is local-x (w > h): a half-length-0.5 segment swept by 0.5.
    assert (shape.ax, shape.bx) == pytest.approx((-0.5, 0.5))
    assert (shape.ay, shape.by) == pytest.approx((0.0, 0.0))


def test_tall_oval_puts_its_major_axis_on_local_y():
    opening = mask_source.MaskOpening(
        x=0.0, y=0.0, shape="oval", width=1.0, height=2.0, corner_rratio=None,
        angle_deg=0.0, side=Side.TOP, origin=mask_source.ORIGIN_TH_PAD)
    shape = _mask_shape(opening)
    assert (shape.ax, shape.bx) == pytest.approx((0.0, 0.0))
    assert (shape.ay, shape.by) == pytest.approx((-0.5, 0.5))


def test_roundrect_is_modeled_exactly_not_by_its_bounding_box():
    """THE FALSE-CLEAN THIS PREVENTS, stated as a measurement.

    Two roundrects whose corners face each other are FURTHER apart than their
    bounding boxes are. Modelling them by bounding box (the doctrine copper
    checks use, where oversizing is fail-safe) shrinks the measured web — and
    shrinking it can push a real sliver below zero, into the "merged, nothing to
    report" branch. Here the exact web is positive while the bounding-box web is
    smaller, and the check must use the exact one.
    """
    a = mask_source.MaskOpening(
        x=0.0, y=0.0, shape="roundrect", width=1.0, height=1.0,
        corner_rratio=0.5, angle_deg=0.0, side=Side.TOP,
        origin=mask_source.ORIGIN_SMD_PAD, entity_id="a")
    b = dataclasses.replace(a, x=1.05, y=1.05, entity_id="b")

    shape_a, shape_b = _mask_shape(a), _mask_shape(b)
    assert isinstance(shape_a, RoundedRect)

    exact = convex_edge_distance(shape_a, shape_b)
    boxed = convex_edge_distance(
        OrientedRect(0.0, 0.0, 0.5, 0.5, 0.0),
        OrientedRect(1.05, 1.05, 0.5, 0.5, 0.0))
    # rratio 0.5 on a 1mm square is a circle: centres are 1.05*sqrt(2) apart,
    # minus two 0.5 radii.
    assert exact == pytest.approx(1.05 * math.sqrt(2.0) - 1.0)
    assert exact > boxed, \
        "the bounding-box model under-reports this web — that is why it is not used"


def test_an_unmodelable_aperture_shape_fails_closed():
    """A shape GC8 cannot measure must RAISE, never be skipped. Skipping removes
    candidate pairs from the check, and fewer pairs means fewer slivers found,
    which reads as a healthier board."""
    from pcb_worker.ir_pads import UnsupportedGeometry

    opening = mask_source.MaskOpening(
        x=0.0, y=0.0, shape="trapezoid", width=1.0, height=1.0,
        corner_rratio=None, angle_deg=0.0, side=Side.TOP,
        origin=mask_source.ORIGIN_SMD_PAD)
    with pytest.raises(UnsupportedGeometry):
        _mask_shape(opening)


def test_rotation_is_honoured():
    """A rotated opening presents a different edge to its neighbour, so ignoring
    the angle measures the wrong web — and rotated pads are the common case on
    real boards, not an exotic one.

    Two 1.0 x 0.2 bars stacked 0.25 apart leave a 0.05 web and must flag. Turn
    both 90 degrees and they become 0.2 x 1.0, each spanning y = -0.5..0.5 — so
    they now OVERLAP and fall into the merged regime, reporting nothing. The
    assertion is the same either way, but the reason matters: this pair moves
    from "sliver" to "merged", NOT from "close" to "far apart", and a reader who
    believed the latter would be surprised by the next rotation case.
    """
    upright = _run([_rect(0.0, 0.0, w=1.0, h=0.2, entity="a"),
                    _rect(0.0, 0.25, w=1.0, h=0.2, entity="b")])
    assert len(upright) == 1, "0.05 web between two flat bars must flag"

    turned = _run([_rect(0.0, 0.0, w=1.0, h=0.2, entity="a", angle=90.0),
                   _rect(0.0, 0.25, w=1.0, h=0.2, entity="b", angle=90.0)])
    assert turned == [], \
        "turned 90 degrees the two bars overlap, which is the merged regime"


# ---------------------------------------------------------------------------
# The refusal path.
# ---------------------------------------------------------------------------


def test_no_openings_is_clean_not_an_error():
    """A board with no mask openings at all (no pads, no holes, no untented
    vias) has no slivers. Vacuous, but it must not raise."""
    assert _run([]) == []


def test_a_single_opening_cannot_form_a_sliver():
    assert _run([_rect(0.0, 0.0)]) == []


# ---------------------------------------------------------------------------
# THE BROAD PHASE (epoch CP2 S11) — and the proof it prunes nothing real.
#
# GC8 was all-pairs while GC10 next door already had an AABB gate, so a dense
# board paid the exact convex kernel on every opening pair on a side. The sweep
# added here only prunes pairs whose boxes are farther apart than the floor, and
# such a pair provably cannot land in the 0 < web < floor band the check reports.
#
# "Provably" is an argument, not a measurement, so these tests measure it: the
# broad-phase result must equal what all-pairs produced, on geometry chosen to
# sit AT the boundary where a pruning bug would first show.
# ---------------------------------------------------------------------------


def _all_pairs_reference(openings, floor=FLOOR):
    """GC8's narrow phase with NO broad phase — the all-pairs double loop this
    check used before the sweep, re-implemented here as the oracle.

    Deliberately a separate implementation rather than a flag on the production
    function: an equivalence test whose two sides share the code under test
    proves nothing.
    """
    from pcb_worker.drc_geometric import EPS, _violates

    out = []
    for side in (Side.TOP, Side.BOTTOM):
        ordered = sorted([o for o in openings if o.side is side],
                         key=lambda o: (o.entity_id or "", o.ref or "", o.x, o.y))
        shapes = [_mask_shape(o) for o in ordered]
        for i in range(len(ordered)):
            for j in range(i + 1, len(ordered)):
                web = convex_edge_distance(shapes[i], shapes[j])
                if web <= EPS or not _violates(web, floor):
                    continue
                out.append((ordered[i].entity_id, ordered[j].entity_id,
                            round(web, 6)))
    return out


def _measured(findings):
    return [(f["participants"][0]["entity_id"],
             f["participants"][1]["entity_id"],
             f["measured_mm"]) for f in findings]


@pytest.mark.parametrize("gap", [
    # AT the floor, and one float-noise step to either side of it. A broad phase
    # whose margin is even slightly too small drops the failing case here first.
    FLOOR, FLOOR - 1e-9, FLOOR + 1e-9,
    # Just inside and just outside the band's other end (the merged regime).
    1e-9, 0.0,
    # VIOLATIONS SPREAD ACROSS THE WHOLE BAND, not clustered at its ends. These
    # are the cases an under-sized margin loses FIRST: each is a genuine sliver
    # whose openings are far enough apart to be pruned by a margin any smaller
    # than the floor. Measured: with only 0 and FLOOR/2 here, quartering the
    # margin left the suite green.
    FLOOR * 0.6, FLOOR * 0.7, FLOOR * 0.9, FLOOR * 0.99, FLOOR / 2.0,
    # Comfortably clean — the pairs the sweep is SUPPOSED to prune.
    FLOOR * 2.0, 5.0, 50.0,
])
def test_the_broad_phase_agrees_with_all_pairs_at_the_threshold(gap):
    openings = _gap_pair(gap)
    assert _measured(_run(openings)) == _all_pairs_reference(openings)


def test_the_broad_phase_agrees_with_all_pairs_on_a_dense_grid():
    """A many-opening board where MOST pairs are far apart and a few are not —
    the case the sweep exists for, and the one where an off-by-one in the active
    list would silently lose a violating pair."""
    openings = []
    for row in range(6):
        for col in range(6):
            # Columns are spaced so neighbours within a row sit just under the
            # floor (a sliver, and near the far end of the band where an
            # under-sized margin prunes first) while rows are far apart.
            openings.append(_rect(col * (1.0 + FLOOR * 0.9), row * 8.0,
                                  entity=f"p{row}_{col}",
                                  side=Side.TOP if row % 2 == 0 else Side.BOTTOM))
    findings = _run(openings)
    assert _measured(findings) == _all_pairs_reference(openings)
    assert findings, "the dense fixture must actually produce slivers"


def test_the_broad_phase_agrees_with_all_pairs_on_rotated_and_mixed_shapes():
    """Mixed aperture families at a rotation. A box is a SUPERSET of the shape it
    bounds, so a rotated stadium's box overlaps where the stadium does not —
    the sweep must still hand the pair to the exact kernel rather than decide."""
    openings = [
        _rect(0.0, 0.0, w=2.0, h=0.6, entity="r0", angle=45.0),
        _rect(1.4, 1.4, w=2.0, h=0.6, entity="r1", angle=45.0),
        mask_source.circle_opening(3.0, 0.0, 1.0, Side.TOP,
                                   mask_source.ORIGIN_VIA, "v0"),
        mask_source.circle_opening(4.05, 0.0, 1.0, Side.TOP,
                                   mask_source.ORIGIN_VIA, "v1"),
        mask_source.MaskOpening(
            x=0.0, y=6.0, shape="oval", width=3.0, height=1.0,
            corner_rratio=None, angle_deg=30.0, side=Side.TOP,
            origin=mask_source.ORIGIN_SMD_PAD, entity_id="o0"),
        mask_source.MaskOpening(
            x=2.6, y=6.0, shape="oval", width=3.0, height=1.0,
            corner_rratio=None, angle_deg=30.0, side=Side.TOP,
            origin=mask_source.ORIGIN_SMD_PAD, entity_id="o1"),
    ]
    assert _measured(_run(openings)) == _all_pairs_reference(openings)


def test_the_broad_phase_is_actually_pruning():
    """NON-VACUITY. Every equivalence test above passes trivially if the sweep
    returns all pairs, which is exactly what a broken margin computation would
    do in the safe direction. Assert it prunes: 40 far-apart openings are
    780 all-pairs combinations and should yield almost none."""
    openings = [_rect(i * 20.0, 0.0, entity=f"far{i:02d}") for i in range(40)]
    boxes = [_mask_shape(o).aabb() for o in openings]
    pairs = drc_geometric._sweep_pairs(boxes, [o.entity_id for o in openings],
                                       FLOOR)
    assert len(pairs) < 40, (
        f"the sweep returned {len(pairs)} of 780 pairs — it is not pruning, so "
        f"every equivalence test above is vacuous")
    assert _measured(_run(openings)) == _all_pairs_reference(openings) == []


def _brute_force_pairs(boxes, margin):
    """Every index pair whose margin-inflated boxes overlap — the definition the
    sweep is an optimisation OF, evaluated directly."""
    out = []
    for i in range(len(boxes)):
        for j in range(i + 1, len(boxes)):
            a, b = boxes[i], boxes[j]
            if ((a.min_x - margin) <= (b.max_x + margin) + drc_geometric.EPS
                    and (b.min_x - margin) <= (a.max_x + margin) + drc_geometric.EPS
                    and (a.min_y - margin) <= (b.max_y + margin) + drc_geometric.EPS
                    and (b.min_y - margin) <= (a.max_y + margin) + drc_geometric.EPS):
                out.append((i, j))
    return out


def _box(x, y, w=1.0, h=1.0):
    return AABB(x - w / 2, y - h / 2, x + w / 2, y + h / 2)


@pytest.mark.parametrize("margin", [0.0, FLOOR, 1.0])
def test_the_sweep_returns_exactly_the_overlapping_pairs(margin):
    """THE SWEEP'S OWN CONTRACT, tested below the check that uses it.

    The GC8-level equivalence tests above can only see a pruning bug that
    changes a FINDING, and the sweep is deliberately conservative enough
    (both boxes inflated) that several real bugs hide inside that slack. This
    compares the sweep against the definition it optimises, so an off-by-one in
    the active list or a dropped inflation is caught where it happens.

    The fixture is built to include the exact-touch boundary in x and in y —
    the measure-zero case an `>=`-to-`>` slip loses — alongside separations just
    inside and just outside it.
    """
    reach = 1.0 + 2 * margin           # centre distance at which boxes just touch
    boxes = [
        _box(0.0, 0.0),
        _box(reach, 0.0),              # exact touch in x
        _box(reach - 1e-9, 0.0),       # a hair inside
        _box(reach + 1e-9, 0.0),       # a hair outside
        _box(0.0, reach),              # exact touch in y
        _box(0.0, reach + 1e-9),
        _box(reach, reach),            # diagonal, touching on both axes
        _box(50.0, 50.0),              # far from everything
        _box(0.0, 0.0, w=4.0, h=4.0),  # a big box swallowing several others
    ]
    keys = [f"b{i:02d}" for i in range(len(boxes))]
    assert sorted(drc_geometric._sweep_pairs(boxes, keys, margin)) == \
        _brute_force_pairs(boxes, margin)


def test_the_sweep_is_order_independent():
    """Determinism: the same boxes in a different input order must yield the
    same pairs (as index pairs into their own list), or a finding's participant
    order would depend on projection order."""
    boxes = [_box(0.0, 0.0), _box(1.05, 0.0), _box(2.10, 0.0), _box(30.0, 0.0)]
    keys = ["a", "b", "c", "d"]
    forward = drc_geometric._sweep_pairs(boxes, keys, FLOOR)
    reverse = drc_geometric._sweep_pairs(boxes[::-1], keys[::-1], FLOOR)
    n = len(boxes) - 1
    assert sorted(forward) == sorted(
        tuple(sorted((n - i, n - j))) for i, j in reverse)
