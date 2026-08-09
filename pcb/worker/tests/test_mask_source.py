"""The shared solder-mask opening owner (epoch CP2 station S4).

AUTHORED, NOT EXECUTED during CP2: this epoch writes tests at every station and
runs them for the first time at the boundary (S10), after the Codex round.

WHAT THESE TESTS ARE FOR. mask_source did not invent a single rule — every
branch in it was lifted out of ``gerber._emit_pads`` / ``_emit_board_hole`` /
``_emit_via``, each one traceable to a ratified finding. So the risk this suite
addresses is not "is the rule right", it is "did the rule SURVIVE the move".
The tests below therefore assert the specific, counter-intuitive behaviours that
a careless extraction would have quietly normalised away:

  * an unplated hole opens mask to the DRILL with NO margin (not the annulus,
    not the clearance-enlarged drill),
  * a tented via opens NOTHING even though its copper is right there,
  * a plated board hole with no annulus opens nothing and does not raise,
  * TOP precedes BOTTOM in every both-sides result, because the emitter appends
    in that order and the Gerber goldens are byte-sensitive to aperture order.
"""

from __future__ import annotations

import pytest

from pcb_worker import mask_source
from pcb_worker.pad_source import DEFAULT_MASK_CLEARANCE_MM, PadGeometryError, iter_pads
from pcb_worker.resolved_board import Side

CLEARANCE = 0.1


def _pad(**over) -> object:
    """One PadGeom via the neutral iterator, so these tests exercise the same
    construction path production does rather than hand-building a PadGeom whose
    field defaults could drift from the real one."""
    pin = {"number": "1", "x_mm": 0.0, "y_mm": 0.0}
    pin.update(over)
    comp = {"ref": "P1", "footprint": "F", "x_mm": 0.0, "y_mm": 0.0,
            "rotation_deg": 0.0, "layer": "top", "pins": [pin]}
    return iter_pads(comp, require_smd_size=True)[0]


def _smd(**over):
    base = {"pad_width_mm": 1.0, "pad_height_mm": 0.6}
    base.update(over)
    return _pad(**base)


def _th(**over):
    base = {"drill_mm": 0.8, "annulus_diameter_mm": 1.6}
    base.update(over)
    return _pad(**base)


# ---------------------------------------------------------------------------
# Sides and ordering.
# ---------------------------------------------------------------------------


def test_smd_pad_opens_mask_on_its_own_side_only():
    """An SMD pad is one-sided copper, so it is one-sided mask. Opening the far
    side would expose bare laminate where the fab expects mask."""
    for side in (Side.TOP, Side.BOTTOM):
        openings = mask_source.pad_openings(
            _smd(), 5.0, 5.0, 0.0, side, "P1", CLEARANCE)
        assert len(openings) == 1
        assert openings[0].side is side
        assert openings[0].origin == mask_source.ORIGIN_SMD_PAD


@pytest.mark.parametrize("make,kwargs", [
    (_th, {}),                                    # plated TH, round land
    (_th, {"pad_width_mm": 2.0, "pad_height_mm": 1.0}),   # plated TH, shaped
])
def test_through_hole_pads_open_both_sides_top_first(make, kwargs):
    """A through-hole pad's copper reaches both outer layers, so both masks open.

    ORDER IS ASSERTED, not incidental. The emitter appends these to its two
    buckets in sequence, and aperture order within a Gerber layer is part of the
    byte-identical golden contract — a reversal here would re-order every
    two-sided flash on the board.
    """
    openings = mask_source.pad_openings(
        make(**kwargs), 3.0, 4.0, 0.0, Side.TOP, "P1", CLEARANCE)
    assert [o.side for o in openings] == [Side.TOP, Side.BOTTOM]
    assert {o.origin for o in openings} == {mask_source.ORIGIN_TH_PAD}


def test_both_sides_openings_are_geometrically_identical():
    """The two sides of a through-hole opening are the same aperture. If they
    ever differ, one side of the board is being masked to a different size than
    the other for a feature that is physically symmetric."""
    top, bot = mask_source.pad_openings(
        _th(), 3.0, 4.0, 30.0, Side.TOP, "P1", CLEARANCE)
    assert top.as_emitter_tuple() == bot.as_emitter_tuple()


# ---------------------------------------------------------------------------
# The rules that a careless extraction would have normalised away.
# ---------------------------------------------------------------------------


def test_unplated_th_pad_opens_to_the_bare_drill_with_no_margin():
    """np_thru_hole: mask open to the DRILL, no copper ring, NO margin.

    The margin-free part is the easy thing to lose, because every other opening
    in this module is enlarged. It matches kicad's np_thru_hole, which carries an
    explicit ``(solder_mask_margin 0.0)`` — findings 019f8fe77068 / R4d, where
    the two emitters had diverged on exactly this and were reconciled.

    Unplated is expressed as ``plated: False`` on the pin, NOT as a
    ``pad_type`` key: the loose-dict factory DERIVES pad_type from the drill
    (``pad_source._from_pin``) and ignores an authored one, so a fixture that set
    pad_type would have silently tested the plated path instead. Measured, not
    assumed — the emitter's predicate is ``pad.plated and pad.pad_type !=
    "np_thru_hole"``, and this fixture fails the first half of it.
    """
    pad = _pad(drill_mm=1.2, plated=False)
    openings = mask_source.pad_openings(
        pad, 0.0, 0.0, 0.0, Side.TOP, "P1", CLEARANCE)
    assert [o.side for o in openings] == [Side.TOP, Side.BOTTOM]
    for o in openings:
        assert o.origin == mask_source.ORIGIN_NPTH_PAD
        assert o.shape == "circle"
        assert o.width == pytest.approx(1.2), \
            "the NPTH opening was enlarged — it must be the literal drill"
        assert o.height == pytest.approx(1.2)


def test_tented_via_opens_no_mask_at_all():
    """THE ONE ENTITY where copper and mask disagree. A tented via has an annulus
    on both sides and opens neither. A checker that inferred openings from copper
    would invent two apertures that are not on the board."""
    assert mask_source.via_openings(1.0, 2.0, 0.66, True, True, CLEARANCE) == ()


@pytest.mark.parametrize("tf,tb,expect", [
    (False, True, [Side.TOP]),
    (True, False, [Side.BOTTOM]),
    (False, False, [Side.TOP, Side.BOTTOM]),
])
def test_via_tenting_is_resolved_per_side(tf, tb, expect):
    """Per-side tenting (finding 019f8fe7cbaf) — a half-tented via opens exactly
    one side, and it is the UNtented one."""
    openings = mask_source.via_openings(1.0, 2.0, 0.66, tf, tb, CLEARANCE)
    assert [o.side for o in openings] == expect
    assert all(o.origin == mask_source.ORIGIN_VIA for o in openings)


def test_half_tented_via_sizes_both_sides_from_one_computation():
    """The dimension is computed once, outside the per-side branches. Two
    computations could not disagree today, but they are the shape of bug that
    appears the moment someone adds a per-side input."""
    (top,) = mask_source.via_openings(1.0, 2.0, 0.66, False, True, CLEARANCE)
    (bot,) = mask_source.via_openings(1.0, 2.0, 0.66, True, False, CLEARANCE)
    assert top.width == bot.width == pytest.approx(0.66 + 2 * CLEARANCE)


def test_plated_board_hole_without_annulus_opens_nothing_and_does_not_raise():
    """There is no land for an opening to follow, so there is no opening — and
    this is NOT the place that complains about it. The emitter warns (copper is
    fabrication-critical and the missing ring must not be silent) because it is
    the surface that can name the hole. Raising here would turn a warned,
    recoverable authoring gap into a refusal to fabricate."""
    assert mask_source.board_hole_openings(
        1.0, 1.0, 0.8, True, None, CLEARANCE, "mounting_holes[0]") == ()
    assert mask_source.board_hole_openings(
        1.0, 1.0, 0.8, True, 0.0, CLEARANCE, "mounting_holes[0]") == ()


def test_unplated_board_hole_opens_to_the_drill_on_both_sides():
    """Uniform with a footprint np_thru_hole pad (finding 019f901a9966, verified
    against pcbnew 9.0.9). The uniformity is the point: the same physical
    feature must not mask differently depending on whether it was authored as a
    board hole or as a pad."""
    openings = mask_source.board_hole_openings(
        1.0, 1.0, 0.9, False, None, CLEARANCE, "mounting_holes[0]")
    assert [o.side for o in openings] == [Side.TOP, Side.BOTTOM]
    for o in openings:
        assert o.origin == mask_source.ORIGIN_NPTH_BOARD_HOLE
        assert o.width == pytest.approx(0.9)


def test_plated_board_hole_opening_follows_the_annulus_plus_clearance():
    openings = mask_source.board_hole_openings(
        1.0, 1.0, 0.8, True, 1.5, CLEARANCE, "mounting_holes[0]")
    assert len(openings) == 2
    for o in openings:
        assert o.origin == mask_source.ORIGIN_BOARD_HOLE
        assert o.width == pytest.approx(1.5 + 2 * CLEARANCE)


# ---------------------------------------------------------------------------
# Dimensions, margins, fail-closed.
# ---------------------------------------------------------------------------


def test_smd_opening_is_the_pad_enlarged_per_axis_by_the_margin():
    (o,) = mask_source.pad_openings(
        _smd(pad_width_mm=1.0, pad_height_mm=0.6), 0.0, 0.0, 0.0,
        Side.TOP, "P1", CLEARANCE)
    assert o.width == pytest.approx(1.0 + 2 * CLEARANCE)
    assert o.height == pytest.approx(0.6 + 2 * CLEARANCE)
    assert o.shape == "rect", "the opening must follow the pad shape (R2)"


def test_per_pad_margin_overrides_the_global_clearance():
    (o,) = mask_source.pad_openings(
        _smd(solder_mask_margin=0.25), 0.0, 0.0, 0.0, Side.TOP, "P1", CLEARANCE)
    assert o.width == pytest.approx(1.0 + 2 * 0.25)


def test_a_collapsing_negative_margin_fails_closed():
    """Mask is fabrication-critical, so an opening that cannot be computed
    RAISES rather than emitting something plausible (bug 019f929b1416). The
    contrast with silk_source is deliberate and is stated in both modules: silk
    warns and drops because it is cosmetic."""
    with pytest.raises(PadGeometryError):
        mask_source.pad_openings(
            _smd(pad_width_mm=1.0, pad_height_mm=0.6, solder_mask_margin=-5.0),
            0.0, 0.0, 0.0, Side.TOP, "P1", CLEARANCE)


def test_opening_carries_the_placed_position_unchanged():
    """mask_source applies NO transform. Its callers hand it board-absolute
    coordinates (the emitter has applied the component placement; the IR's
    PlacedPad is already absolute), and a mirror or rotation applied here would
    be a second transform on top of one already done."""
    (o,) = mask_source.pad_openings(
        _smd(), 12.5, -3.25, 45.0, Side.TOP, "P1", CLEARANCE)
    assert (o.x, o.y) == (12.5, -3.25)
    assert o.angle_deg == 45.0


# ---------------------------------------------------------------------------
# The emitter-tuple contract and the clearance rule.
# ---------------------------------------------------------------------------


def test_as_emitter_tuple_matches_the_bucket_layout():
    """The 7-tuple the emitter's mask buckets hold. Field ORDER is the contract;
    it is defined next to the fields so the two cannot drift."""
    o = mask_source.circle_opening(1.0, 2.0, 0.5, Side.TOP, mask_source.ORIGIN_VIA)
    assert o.as_emitter_tuple() == (1.0, 2.0, "circle", 0.5, 0.5, None, 0.0)


def test_circle_opening_convention_is_square_unrotated_and_ratioless():
    """One place owns what "circular opening" means, so a round TH land, an NPTH
    drill opening and an untented via cannot end up with three spellings."""
    o = mask_source.circle_opening(0.0, 0.0, 1.25, Side.BOTTOM,
                                   mask_source.ORIGIN_TH_PAD)
    assert o.shape == "circle"
    assert o.width == o.height == 1.25
    assert o.corner_rratio is None
    assert o.angle_deg == 0.0


class _Minimums:
    def __init__(self, value):
        self.solder_mask_clearance_mm = value


class _Rules:
    def __init__(self, value):
        self.minimums = _Minimums(value)


class _Board:
    def __init__(self, value):
        self.design_rules = _Rules(value)


@pytest.mark.parametrize("authored,expected", [
    (0.25, 0.25),
    (0.0, 0.0),                          # explicit zero is a real answer
    (None, DEFAULT_MASK_CLEARANCE_MM),   # unauthored -> default
    (-1.0, DEFAULT_MASK_CLEARANCE_MM),   # meaningless at board scope -> default
])
def test_ir_mask_clearance_resolution(authored, expected):
    """The rule that used to live inline in ``gerber.build_gerbers_ir``. It moved
    because DRC sizes the same openings: had the checker re-derived the fallback,
    the emitter could size an opening at the authored clearance while the checker
    measured it at the default, and every mask check would be off by a constant.

    A stub board is used rather than a compiled one on purpose — this is a pure
    lookup rule and the test should fail for that rule's reasons only.
    """
    assert mask_source.resolve_ir_mask_clearance(_Board(authored)) == expected
