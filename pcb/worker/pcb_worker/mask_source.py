"""Single owner of SOLDER-MASK OPENING geometry for the PCB worker.

The third neutral owner, after :mod:`pad_source` (copper land dimensions) and
:mod:`silk_source` (legend geometry), and it exists for a sharper reason than
either of them.

WHY THIS MODULE EXISTS (epoch CP2, station S4)
----------------------------------------------
``pad_source`` already owned the mask DIMENSION rule — ``mask_opening_dim``
(the collapse boundary), ``pad_mask_margin`` (per-pad margin vs global
clearance), ``resolve_global_mask_clearance``. What it did NOT own was the
ENUMERATION: *which* entities open the mask at all, on *which* sides. That
knowledge lived only inside ``gerber.py``'s emit path, spread across six
decisions in three functions:

    SMD pad          -> one opening, the component's own side
    plated TH pad    -> both sides, shaped or round per ``pad_source.th_land``
    unplated TH pad  -> both sides, DRILL-sized, and NO margin
    plated board hole-> both sides, from the authored annulus
    unplated board hole -> both sides, DRILL-sized, no margin
    via              -> per side, and only where that side is UNTENTED

Station S5 needs that enumeration to check a mask-sliver floor. There were only
two ways to give it one, and only one of them is safe:

    (a) a shared owner the EMITTER adopts, so the checker measures the exact
        apertures the fab receives;
    (b) DRC re-deriving the apertures independently.

(b) is the drift hazard station S2 removed for silk, and it is WORSE here. A
missed silk primitive makes a checker narrower than the artwork; a missed MASK
APERTURE in a sliver check produces a FALSE CLEAN — the checker reports no
sliver because it never saw the two openings that form one. Under the cardinal
rule ("never a false clean, never silently discarded geometry") that is not an
acceptable failure mode, so this module is (a): ``gerber.py`` no longer decides
where mask opens, it asks here and adapts the answer into its buckets.

THE TENTING ASYMMETRY, stated once because it is the easiest thing to get wrong
------------------------------------------------------------------------------
Every other entity here opens mask on a side because something CONDUCTIVE is
exposed there. A via is the exception: a tented via has copper on that side and
NO opening, so "has copper" and "opens mask" are genuinely different questions,
and a checker that assumed the first implies the second would invent apertures
that are not on the board. Per-side tenting is therefore a first-class input,
not a filter applied afterwards.

FRAME
-----
Board frame (Y-DOWN), like :mod:`silk_source` and for the same reason: the
Y negation happens exactly once, at ``gerber._Geometry.to_gerber_frame``.
Nothing here knows the gerber frame exists.

FAIL-CLOSED, unlike silk
------------------------
Silk warns-and-drops because it is cosmetic. Mask is fabrication-critical
(``fab_capability.FABRICATION_CRITICAL_OUTPUTS`` lists it), so a mask opening
that cannot be computed RAISES — ``mask_opening_dim`` already fails closed on a
negative per-pad margin that collapses the opening (bug 019f929b1416), and this
module propagates rather than softening it. A board whose mask cannot be
determined must not be fabricated.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from .pad_source import (
    DEFAULT_MASK_CLEARANCE_MM,
    is_through_hole,
    mask_opening_dim,
    pad_mask_margin,
    require_th_annulus,
    th_land,
)
from .resolved_board import Side


def resolve_ir_mask_clearance(rb: Any) -> float:
    """The board-global mask clearance for a :class:`ResolvedBoard`.

    The IR counterpart of ``pad_source.resolve_global_mask_clearance`` (which
    answers the same question for a loose dict), and it lives here for the same
    reason the enumeration does: it was inline in ``gerber.build_gerbers_ir``,
    so a checker asking "how big is this opening" had to either re-derive it or
    be handed it. Re-deriving a DEFAULT is a quiet way for two surfaces to
    disagree — the emitter would size an opening at the authored clearance while
    the checker measured it at 0.1.

    A missing or NEGATIVE authored value falls back to the default rather than
    raising: a negative global clearance is not a per-pad margin (which does
    fail closed when it collapses an opening) and has no defensible meaning at
    board scope.
    """
    mc = rb.design_rules.minimums.solder_mask_clearance_mm
    if mc is not None and mc >= 0:
        return float(mc)
    return DEFAULT_MASK_CLEARANCE_MM

# Aperture-family origins, so a consumer (a finding, a diagnostic, a filter) can
# say WHICH KIND of feature opened the mask without re-deriving it from shape.
# "npth_pad" is deliberately distinct from "th_pad": they differ in the rule
# applied (drill-size and no margin vs land-size plus margin), and a check that
# wants to exempt bare mechanical holes needs to be able to see the difference.
ORIGIN_SMD_PAD = "smd_pad"
ORIGIN_TH_PAD = "th_pad"
ORIGIN_NPTH_PAD = "npth_pad"
ORIGIN_BOARD_HOLE = "board_hole"
ORIGIN_NPTH_BOARD_HOLE = "npth_board_hole"
ORIGIN_VIA = "via"


@dataclass(frozen=True)
class MaskOpening:
    """One solder-mask aperture, board frame.

    The field set is exactly ``gerber.py``'s historical mask tuple
    ``(x, y, shape, w, h, corner_rratio, angle)`` plus the two things that tuple
    could not carry: which SIDE the opening is on (the emitter encoded that
    positionally, by which of two buckets it appended to) and what KIND of
    feature opened it. Both are needed by a checker and neither is recoverable
    from the geometry alone.

    ``width``/``height`` are the FINISHED opening — margin already applied. A
    consumer must never re-apply a margin to these.
    """
    x: float
    y: float
    shape: str                      # "circle" | "rect" | "oval" | "roundrect"
    width: float
    height: float
    corner_rratio: float | None
    angle_deg: float
    side: Side
    origin: str
    entity_id: str | None = None    # pad number / hole key / via label, when known
    ref: str | None = None          # owning component ref, when there is one

    def as_emitter_tuple(self) -> tuple:
        """The 7-tuple ``gerber._Geometry.mask_top`` / ``mask_bot`` store.

        Kept HERE rather than in the emitter so that the tuple layout and the
        dataclass cannot drift apart: the one place that knows the field order
        is the one place that defines the fields.
        """
        return (self.x, self.y, self.shape, self.width, self.height,
                self.corner_rratio, self.angle_deg)


def circle_opening(x: float, y: float, diameter: float, side: Side,
                   origin: str, entity_id: str | None = None,
                   ref: str | None = None) -> MaskOpening:
    """A round, unrotated mask opening — the shape every circular aperture in
    this module shares (round TH land, NPTH drill-size opening, untented via).

    This is ``gerber._circle_mask``'s convention, moved: one place owns the
    ``(shape="circle", w == h, no corner ratio, 0 degrees)`` quadruple so the
    emitters and the checker cannot drift on what "circular opening" means.
    """
    return MaskOpening(x=x, y=y, shape="circle", width=diameter, height=diameter,
                       corner_rratio=None, angle_deg=0.0, side=side,
                       origin=origin, entity_id=entity_id, ref=ref)


def _both_sides(make) -> tuple[MaskOpening, ...]:
    """TOP then BOTTOM, in that order.

    The order is load-bearing and not merely tidy: the emitter appends these to
    its two buckets in sequence, and the Gerber goldens are byte-sensitive to
    aperture order within a layer. TOP-then-BOTTOM is what ``gerber.py`` did at
    every one of its six sites before this module existed.
    """
    return (make(Side.TOP), make(Side.BOTTOM))


def pad_openings(pad: Any, px: float, py: float, pad_angle: float,
                 comp_side: Side, ref: Any, mask_clearance: float,
                 ) -> tuple[MaskOpening, ...]:
    """Every mask opening one PAD contributes, at its placed position.

    ``pad`` is a :class:`pad_source.PadGeom`; ``px``/``py`` are already
    board-absolute (the caller has applied the component placement), and
    ``pad_angle`` is the pad's ABSOLUTE aperture rotation.

    The branch structure mirrors ``gerber._emit_pads`` exactly, because it IS
    that logic — moved, not reimplemented. Each branch is annotated with the
    finding that established it, since these are ratified fabrication rules and
    several of them are counter-intuitive.
    """
    number = pad.number

    if not is_through_hole(pad):
        # SMD: one opening, on the component's own side, following the pad
        # SHAPE (R2) and enlarged by the effective margin. A large-negative
        # per-pad margin that collapses the opening fails closed in
        # mask_opening_dim rather than emitting a zero aperture.
        margin = pad_mask_margin(pad, mask_clearance)
        return (MaskOpening(
            x=px, y=py, shape=pad.shape,
            width=mask_opening_dim(pad.width, margin, ref, number),
            height=mask_opening_dim(pad.height, margin, ref, number),
            corner_rratio=pad.corner_rratio, angle_deg=pad_angle,
            side=comp_side, origin=ORIGIN_SMD_PAD,
            entity_id=str(number) if number is not None else None,
            ref=ref if isinstance(ref, str) else None),)

    # Through-hole. The plating predicate is the same one gerber._emit_pads and
    # kicad._footprint use; an np_thru_hole is a BARE hole whatever its flags.
    is_plated = pad.plated and pad.pad_type != "np_thru_hole"
    entity_id = str(number) if number is not None else None
    ref_name = ref if isinstance(ref, str) else None

    if not is_plated:
        # UNPLATED: a DRILL-size opening on both sides, with NO margin. Matches
        # kicad's np_thru_hole, which carries an explicit
        # `(solder_mask_margin 0.0)` on "*.Mask" — mask open to the drill, no
        # copper ring (finding 019f8fe77068; R4d closed the earlier
        # board-clearance divergence between the two emitters).
        return _both_sides(lambda side: circle_opening(
            px, py, pad.drill, side, ORIGIN_NPTH_PAD, entity_id, ref_name))

    margin = pad_mask_margin(pad, mask_clearance)
    shaped, land_shape, lw, lh, lrratio = th_land(pad)
    if shaped:
        # A genuinely OBLONG land keeps its width x height faithfully, and the
        # opening is enlarged per axis in the same aperture family — no
        # circularizing (finding 019f8b7fd295).
        mw = mask_opening_dim(lw, margin, ref, number)
        mh = mask_opening_dim(lh, margin, ref, number)
        return _both_sides(lambda side: MaskOpening(
            x=px, y=py, shape=land_shape, width=mw, height=mh,
            corner_rratio=lrratio, angle_deg=pad_angle, side=side,
            origin=ORIGIN_TH_PAD, entity_id=entity_id, ref=ref_name))

    # Round land: the plated TH copper ring. FAIL-CLOSED if the pad resolved no
    # annulus — never the retired `pad.annulus or drill*2` invention (K4).
    annulus = require_th_annulus(pad, ref)
    mask_d = mask_opening_dim(annulus, margin, ref, number)
    return _both_sides(lambda side: circle_opening(
        px, py, mask_d, side, ORIGIN_TH_PAD, entity_id, ref_name))


def board_hole_openings(hx: float, hy: float, dia: float, plated: bool,
                        annulus: float | None, mask_clearance: float,
                        entity_id: str | None = None,
                        ) -> tuple[MaskOpening, ...]:
    """Every mask opening one BOARD-LEVEL hole contributes.

    A PLATED hole with an authored annulus opens mask to the annulus plus the
    board clearance on both sides (finding 019f8dbb7104). An UNPLATED hole opens
    mask to the DRILL on both sides — uniform with a footprint np_thru_hole and
    with kicad's np_thru_hole (verified against pcbnew 9.0.9: an np pad IS on
    *.Mask and renders a size==drill opening; the ratified rule is finding
    019f901a9966).

    A plated hole with NO annulus contributes NOTHING here and is not an error
    at this layer: the emitter warns about the missing copper ring (copper is
    fabrication-critical and the omission must never be silent), and there is no
    land for an opening to follow. Returning () rather than raising keeps the
    diagnostic where it can name the hole.
    """
    if plated:
        if annulus is None or annulus <= 0:
            return ()
        mask_d = mask_opening_dim(annulus, mask_clearance, entity_id or "hole", "")
        return _both_sides(lambda side: circle_opening(
            hx, hy, mask_d, side, ORIGIN_BOARD_HOLE, entity_id))
    return _both_sides(lambda side: circle_opening(
        hx, hy, dia, side, ORIGIN_NPTH_BOARD_HOLE, entity_id))


def npth_feature_openings(x: float, y: float, width: float, height: float,
                          angle_deg: float, entity_id: str | None = None,
                          ) -> tuple[MaskOpening, ...]:
    """Both sides, drill-sized, NO margin — the NPTH rule for a piece of a
    NON-ROUND unplated feature (an oval hole, or one segment of a slot).

    Same physical rule as the round case in :func:`board_hole_openings`; only the
    aperture shape differs. It is a separate entry point because the CALLER owns
    the decomposition — an oval is one piece, a slot is one piece per path
    segment — and that decomposition already exists, exactly once, in the
    checker's hole projection. Duplicating it here to keep one function would
    have created a second reading of the same geometry.

    WHY THIS IS MODELED AT ALL, given the Gerber emitter refuses non-round board
    holes outright (``gerber._harvest_ir`` raises): because refusing here too
    costs real findings for nothing. Such a board produces no fab package, so
    there is no emitted aperture for a projected one to disagree with — the
    emitter/checker parity claim is vacuous rather than violated. Meanwhile DRC
    still has a job to do on that board, and declaring its mask undetermined
    forced a WHOLESALE indeterminate that suppressed gc1-gc7, which model slots
    perfectly well. Modelling the opening keeps those checks alive and lets GC8
    measure the slivers around a slot honestly.
    """
    shape = "circle" if abs(width - height) <= 1e-12 else "oval"
    return _both_sides(lambda side: MaskOpening(
        x=x, y=y, shape=shape, width=width, height=height,
        corner_rratio=None, angle_deg=angle_deg, side=side,
        origin=ORIGIN_NPTH_BOARD_HOLE, entity_id=entity_id))


def via_openings(vx: float, vy: float, dia: float, tented_front: bool,
                 tented_back: bool, mask_clearance: float,
                 entity_id: str | None = None) -> tuple[MaskOpening, ...]:
    """Mask openings for one VIA — per side, and only where UNTENTED.

    Tenting is per-side (finding 019f8fe7cbaf): a TENTED side (the default) has
    NO opening even though the copper annulus is there; an UNTENTED side exposes
    the annulus with an opening enlarged by the board mask clearance, like a
    plated pad.

    The dimension is computed ONCE, outside the per-side branches, so a
    half-tented via cannot end up with two differently-sized openings — and so
    the fail-closed collapse check runs even when only one side is exposed.
    """
    if tented_front and tented_back:
        return ()
    md = mask_opening_dim(dia, mask_clearance, "via", f"({vx}, {vy})")
    out: list[MaskOpening] = []
    if not tented_front:
        out.append(circle_opening(vx, vy, md, Side.TOP, ORIGIN_VIA, entity_id))
    if not tented_back:
        out.append(circle_opening(vx, vy, md, Side.BOTTOM, ORIGIN_VIA, entity_id))
    return tuple(out)
