"""Single owner of SILK-LEGEND geometry for the PCB worker.

The silk analogue of :mod:`pad_source`, and it exists for the same reason: more
than one consumer needs the same geometry, and every extra copy of the harvest
is a chance for two surfaces to disagree about what is on the board.

WHY THIS MODULE EXISTS (epoch CP2, station S2)
----------------------------------------------
Before it, silk geometry had TWO owners and was about to get a third:

* ``gerber.py`` harvested footprint silk into its ``_Geometry`` buckets and
  SYNTHESIZED reference designators from the stroke font at emission time.
* ``kicad.py`` carried a hand-mirrored copy of the two width constants,
  documented as deliberate ("kicad.py must stay free of gerber_writer") and
  pinned by a cross-emitter equality test.
* Geometric DRC was about to need silk too, to check silk DFM floors.

A third copy inside DRC would have been the worst of the three, because it is
the one that would make DRC MEASURE DIFFERENT GEOMETRY THAN THE EMITTER EMITS
— a false clean, not merely a duplication. Hence one dependency-free owner that
all three import.

The constants specifically resolve the note ``gerber.py`` left next to them:
"the silk pair has to be mirrored in kicad.py because gerber.py drags
gerber_writer, whereas fab_capability imports nothing and BOTH emitters can
read it directly. One number, no mirror, no cross-emitter equality test
needed." This module is that second ``fab_capability`` — it imports no
gerber_writer, so the mirror is retired rather than re-pinned.

FRAME
-----
Everything here is in the BOARD frame (Y-DOWN), which is the frame the callers
already work in: ``gerber._Geometry.to_gerber_frame`` performs the Y negation
(and the accompanying arc-chirality flip) exactly once, at the emitter
boundary, and DRC's projection is board-frame throughout. Nothing in this
module knows the gerber frame exists.

DEGENERATE-GEOMETRY RULING (written down rather than inherited)
--------------------------------------------------------------
The harvest below WARNS AND DROPS malformed silk rather than failing closed,
because silk is cosmetic — the rule the original ``_harvest_silk_graphic``
docstring stated ("Silk is cosmetic, so degenerate forms never raise; contrast
R1/R2 copper/mask, which fail closed").

Once silk became a DFM CHECK SUBJECT that rule needed re-examining, because
under the cardinal rule ("never a false clean") geometry a checker cannot
measure is normally an INDETERMINATE, not a warning. The ruling, and its
reasoning, so a future reader does not have to re-derive it:

    DRC checks exactly the POST-DROP set — the same primitives this module
    hands the emitter. That is correct rather than lenient BECAUSE the two
    consumers share this one harvest: a dropped primitive is never fabricated,
    so there is no unmeasured geometry on the physical board to false-clean
    about. Every drop is reported (the caller turns each SilkWarning into a
    surface diagnostic), so none of them is silent.

    This holds ONLY while emitter and checker share this module. If a consumer
    ever grows its own silk harvest, that argument evaporates and the drop
    becomes a real indeterminate.

    The second sentence of that ruling was FALSE when first written: an ``arc``
    carrying fewer than two usable points fell through to a bare return with no
    warning at all. Inherited from the pre-extraction code and fixed in S3 (see
    the tail of :func:`_harvest_arc`). Recorded rather than quietly corrected,
    because "the docstring asserted a property the code did not have" is the
    failure mode this module's whole comment style is trying to avoid.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Union

from . import board_font
from .footprint_def import ReferenceTextDefinition
from .geometry import PlacementTransform, place_point, rotate_local_offset
from .resolved_board import Side

__all__ = [
    "SILK_TEXT_WIDTH_MM",
    "SILK_GRAPHIC_WIDTH_MM",
    "SILK_LINE_WIDTH_MM",
    "REFDES_TEXT_SIZE_MM",
    "REFDES_LOCAL_Y_MM",
    "SilkLine",
    "SilkCircle",
    "SilkArc",
    "SilkPoly",
    "SilkPrimitive",
    "SilkWarning",
    "SilkHarvest",
    "graphic_width",
    "harvest_graphic",
    "refdes_strokes",
    "SILK_LAYERS",
    "silk_side",
]

# WHICH LAYERS ARE SILK, and which side each one lands on.
#
# Owned here (epoch CP2 S3) rather than left as a per-consumer predicate. Before
# this, gerber.py tested `graphic["layer"] == "F.SilkS"` and kicad.py's IR bridge
# tested the same thing again, with DRC about to add a third spelling. That is
# the SAME drift class the geometry extraction closed, one level up: a checker
# that harvested B.SilkS while the emitter harvested only F.SilkS would measure
# geometry that is never fabricated, or clear geometry that is.
#
# WHAT IS AND IS NOT RETIRED, precisely — an earlier version of this comment
# claimed more than was true. gerber's harvest predicate and kicad's IR-bridge
# predicate both call silk_side now. kicad's `_footprint_graphics` still tests
# `layer != "F.SilkS"` and that one STAYS: it is not a "which layers are silk"
# question but a "which silk layers this emitter can render" one, and its answer
# is genuinely F-only. It warns on everything else, which is what makes the
# bridge's forwarding of B.SilkS loud instead of silent.
SILK_LAYERS: dict[str, "Side"] = {}


def silk_side(layer: Any) -> "Side | None":
    """The board side a silk layer id names, or ``None`` if it is not silk.

    ``None`` means "not a silk layer" — a courtyard, fab or copper graphic —
    and callers skip it. It does NOT mean "unknown", so this is not a
    fail-open: a genuinely unrecognised layer is simply not silk.
    """
    return SILK_LAYERS.get(layer) if isinstance(layer, str) else None

# --- Silk line widths: TWO constants, because KiCad's shipped footprint library
# uses TWO different numbers and one constant cannot say both (F1, decision record
# comment 872 on 019f783860c8). Measured on the KiCad 10.0.5 shipped library
# (Resistor_SMD/Capacitor_SMD/Package_QFP, 272 footprints): silk GRAPHIC strokes
# are 0.12 (1758 occurrences vs 24 at 0.15); silk TEXT thickness is 0.15 (1047
# occurrences, dominant). Following the LIBRARY is the ratified convention — the
# virgin-board `board_design_settings.defaults.silk_line_width` is a per-project
# authored value that varies board to board and is NOT the convention to match.
#
# These are FALLBACKS only: a graphic that AUTHORS a positive width keeps it
# (see graphic_width). The seed library authors 0.12 explicitly, so the split
# is byte-neutral on today's fixtures — it governs width-less sources.
#
# THE GRAPHIC FALLBACK ROSE 0.12 -> 0.15 IN EPOCH CP2 S6, and the reason is not
# that KiCad's library changed — it still measures 0.12-dominant, and the note
# above still describes where these numbers came from. What changed is that we
# now DECLARE a floor: JLCPCB publishes a minimum silkscreen line width of
# 0.15mm (capabilities page, re-fetched 2026-08-09), GC9 enforces it for any
# profile that declares it, and a DEFAULT that violates our own declared floor
# is indefensible — Minerva's own emission would have been the first thing the
# check flagged.
#
# MEASURED BLAST RADIUS BEFORE CHANGING IT (the gate this station required):
# ZERO silk graphics in the seed library are width-less, so this fallback
# governs nothing in the current corpus and the change moves no emitted byte.
# It is a correctness statement about what Minerva draws when nobody said,
# not a re-styling of existing artwork.
#
# WHAT THIS DOES *NOT* FIX, stated plainly because it is the live consequence:
# the four seed footprints that AUTHOR 0.12 explicitly (R_0805, C_0805,
# ESP32-S3-DevKitC, TH_TestPoint) still emit 0.12 and therefore still violate a
# declared 0.15 floor. Raising a fallback cannot repair authored artwork. Those
# footprints are sha256-pinned vendored copies (footprints.lock.json), so
# editing them is a provenance change, not a fix.
SILK_TEXT_WIDTH_MM = 0.15
SILK_GRAPHIC_WIDTH_MM = 0.15
# Back-compat alias for the historical single name. It means the TEXT width (its
# original 0.15 value); every graphic-line consumer reads SILK_GRAPHIC_WIDTH_MM.
SILK_LINE_WIDTH_MM = SILK_TEXT_WIDTH_MM

# Reference-designator TEXT geometry (K17: silk must carry "R1", not just
# outline graphics — gerber-writer has no text primitive, so this is drawn
# stroke geometry; see board_font.py). Stroke WIDTH is SILK_TEXT_WIDTH_MM: a
# designator IS text, so it takes the library's TEXT thickness rather than the
# graphic-line width — that distinction is exactly why the one constant these
# used to share had to be split.
#
# The two now hold the SAME number (0.15) after the S6 raise, so this line no
# longer changes any emitted byte. It stays because the constants are two
# AUTHORITIES, not two values: the day a profile moves the graphic floor, a
# designator must not follow it. Reading the right name is the whole point.
REFDES_TEXT_SIZE_MM = 1.0
# Local (component-frame) anchor, mirroring kicad.py's own hard-pinned
# designator offset precedent: `(fp_text reference ... (at 0 -1.5) ...)`.
REFDES_LOCAL_Y_MM = -1.5

# Populated here rather than at the __all__ block above so it can reference the
# imported Side enum. F.SilkS / B.SilkS are KiCad's two legend layers; there is
# no third.
SILK_LAYERS.update({"F.SilkS": Side.TOP, "B.SilkS": Side.BOTTOM})

# Collinearity epsilon for the 3-point-arc circumcentre. Points are board mm; a
# genuine silk arc has a triangle signed-area (|d|) many orders above this, while
# collinear/coincident points drive it to ~0 (infinite-radius circle => a line).
_ARC_COLLINEAR_EPS = 1e-9
# The signed-area epsilon is absolute, so a NEAR-collinear triple can still solve
# to a huge-but-finite radius whose centre falls outside the plottable board range
# and would overflow the gerber 4.6 coordinate format. Any arc past this radius is
# physically a straight silk stroke — fall back to a polyline (cosmetic fail-safe).
_ARC_MAX_RADIUS_MM = 1.0e4


def _place(cx: float, cy: float, rot: float, side: Side,
           lx: float, ly: float) -> tuple[float, float]:
    """Place ONE footprint-local point, honouring board side.

    TOP delegates straight to ``place_point`` — byte-identical to what this
    module did before bottom-side support existed, so no top-side output can
    move.

    BOTTOM goes through :class:`geometry.PlacementTransform`, which mirrors the
    local Y axis BEFORE applying the rotation. That convention is not invented
    here and must not be re-derived: it is pinned against
    ``k1_bottom_oracle.kicad_pcb``, generated by pcbnew 9.0.9 from an asymmetric
    top-side footprint after a native ``FOOTPRINT.Flip``. A hand-rolled mirror
    in the emitter — an X-flip, say, or a mirror applied after rotation — would
    agree with the oracle for symmetric artwork and silently disagree for
    everything else, which is the worst possible failure shape for a legend.
    """
    if side is Side.TOP:
        return place_point(cx, cy, rot, lx, ly)
    return PlacementTransform(position=(cx, cy), rotation_deg=rot,
                              side=Side.BOTTOM).point((lx, ly))


# Local numeric coercions. Deliberately duplicated rather than imported: the
# same three-line pair already lives in gerber.py, kicad.py, drc.py, pad_source.py
# and route_bridge.py, and this module's whole purpose is to REMOVE a dependency
# edge, not add one to whichever module happened to be chosen as the owner.
# Consolidating all six is a real (small) cleanup and is deliberately NOT bundled
# into a station whose contract is "no behaviour change".
def _num(v: Any, default: float = 0.0) -> float:
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else default


def _opt_num(v: Any) -> float | None:
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def _list(v: Any) -> list:
    return v if isinstance(v, list) else []


@dataclass(frozen=True)
class SilkLine:
    """A straight silk stroke, board-absolute."""
    x1: float
    y1: float
    x2: float
    y2: float
    width: float


@dataclass(frozen=True)
class SilkCircle:
    """A full silk circle, board-absolute. ``radius`` is untransformed on
    purpose — component placement is a rigid motion, so it cannot scale."""
    cx: float
    cy: float
    radius: float
    width: float


@dataclass(frozen=True)
class SilkArc:
    """A true circular silk arc, board-absolute.

    ``orientation`` is ``'+'`` or ``'-'``, a BOARD-frame chirality. The emitter
    converts it to the gerber frame together with the coordinates (a mirror
    reverses handedness); a consumer that stays in the board frame — DRC — uses
    it as-is.
    """
    start: tuple[float, float]
    end: tuple[float, float]
    center: tuple[float, float]
    orientation: str
    width: float


@dataclass(frozen=True)
class SilkPoly:
    """A silk polyline. ``closed`` distinguishes an authored footprint outline
    (which closes back to its first point) from a glyph stroke or an
    approximated arc chord (which must NOT gain a closing segment)."""
    points: tuple[tuple[float, float], ...]
    width: float
    closed: bool


SilkPrimitive = Union[SilkLine, SilkCircle, SilkArc, SilkPoly]


@dataclass(frozen=True)
class SilkWarning:
    """A primitive this module could not emit faithfully.

    Carries no SourceRef: the ref shape differs per consumer (the emitters tag
    a GRAPHIC SourceRef with the owning component; DRC tags its own entity id),
    so the caller attaches identity. ``code``/``message`` are the wording the
    gerber surface already emitted, kept verbatim so existing diagnostic
    assertions do not move.
    """
    code: str
    message: str


@dataclass(frozen=True)
class SilkHarvest:
    """Result of harvesting ONE source graphic: at most one primitive and at
    most one warning, which is why callers can append both without worrying
    about interleaving order."""
    primitives: tuple[SilkPrimitive, ...]
    warnings: tuple[SilkWarning, ...]


_EMPTY = SilkHarvest((), ())


def graphic_width(graphic: dict) -> float:
    """Stroke width for one silk GRAPHIC primitive (line/arc/circle/poly).

    Authored width wins; a width-less source falls back to the library GRAPHIC
    width, NOT the text width."""
    w = _opt_num(graphic.get("width"))
    return w if (w is not None and w > 0) else SILK_GRAPHIC_WIDTH_MM


def _circumcenter(a: tuple[float, float], b: tuple[float, float],
                  c: tuple[float, float]) -> tuple[tuple[float, float], float] | None:
    """Circumcentre of the triangle (a, b, c) and its orientation denominator.

    Returns ``(center, d)`` where ``d`` is twice the signed area of a->b->c
    (``d == 2 * cross``): ``d > 0`` means the a->b->c turn is in the
    INCREASING-angle direction of the frame the points are given in ('+'), ``d < 0``
    the decreasing one ('-'). Points reach here in the BOARD frame, so the caller's
    '+'/'-' is a board-frame chirality. Returns ``None`` when the three points are
    collinear or coincident (infinite radius — caller falls back to a polyline,
    since an arc through collinear points IS a line).
    """
    ax, ay = a
    bx, by = b
    cx, cy = c
    d = 2.0 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
    if abs(d) < _ARC_COLLINEAR_EPS:
        return None
    a2 = ax * ax + ay * ay
    b2 = bx * bx + by * by
    c2 = cx * cx + cy * cy
    ux = (a2 * (by - cy) + b2 * (cy - ay) + c2 * (ay - by)) / d
    uy = (a2 * (cx - bx) + b2 * (ax - cx) + c2 * (bx - ax)) / d
    return (ux, uy), d


def harvest_graphic(cx: float, cy: float, rot: float, graphic: dict,
                    side: Side = Side.TOP) -> SilkHarvest:
    """Transform one footprint silk graphic (component-LOCAL coords) into
    board-absolute geometry.

    Supported kinds (see footprints.py's ``_parse_graphics``): line, circle,
    poly, polyline, arc. ``poly`` CLOSES back to its first point; ``polyline``
    does not (glyph strokes and other open chains). Arc has two source forms, BOTH resolved to a TRUE circular arc:
    legacy KiCad ``(center, start, angle)`` (``points`` has 2 entries + an
    ``angle`` field); and the modern KiCad 7/8 3-point ``(start, mid, end)``
    form (``points`` has 3 entries, no ``angle``) — resolved through the
    circumcircle of the three transformed points, with chirality taken from the
    a->b->c turn in the BOARD frame. Only when the three points are
    collinear/coincident (infinite radius) does it fall back to a polyline — an
    arc through collinear points IS a line.

    Degenerate forms never raise; see this module's docstring for the ruling.
    """
    kind = graphic.get("kind")
    width = graphic_width(graphic)

    if kind == "line":
        st, en = graphic.get("start"), graphic.get("end")
        if not (isinstance(st, list) and isinstance(en, list)
                and len(st) >= 2 and len(en) >= 2):
            # Malformed endpoints — a captured silk line that cannot be emitted.
            # Cosmetic, so WARN (never fail-closed) so the drop is not silent.
            return SilkHarvest((), (SilkWarning(
                "silk_primitive_unemitted",
                "silk line dropped: malformed start/end (need two >=2-length "
                "points)"),))
        p1 = _place(cx, cy, rot, side, _num(st[0]), _num(st[1]))
        p2 = _place(cx, cy, rot, side, _num(en[0]), _num(en[1]))
        return SilkHarvest((SilkLine(p1[0], p1[1], p2[0], p2[1], width),), ())

    if kind == "circle":
        ct = graphic.get("center")
        radius = _opt_num(graphic.get("radius"))
        if not (isinstance(ct, list) and len(ct) >= 2 and radius and radius > 0):
            return SilkHarvest((), (SilkWarning(
                "silk_primitive_unemitted",
                "silk circle dropped: non-positive radius or malformed center"),))
        pc = _place(cx, cy, rot, side, _num(ct[0]), _num(ct[1]))
        return SilkHarvest((SilkCircle(pc[0], pc[1], radius, width),), ())

    if kind == "poly":
        pts = [p for p in _list(graphic.get("points"))
               if isinstance(p, list) and len(p) >= 2]
        if len(pts) < 2:
            return SilkHarvest((), (SilkWarning(
                "silk_primitive_unemitted",
                "silk poly dropped: fewer than 2 valid points"),))
        abs_pts = tuple(_place(cx, cy, rot, side, _num(p[0]), _num(p[1]))
                        for p in pts)
        return SilkHarvest((SilkPoly(abs_pts, width, True),), ())

    if kind == "polyline":
        # The OPEN twin of "poly", and the ONLY difference is the closed flag.
        # It exists because a glyph stroke must not gain a closing segment (a
        # closed "C" is an "O"), which is the same rule refdes_strokes states
        # for its own return type. Board text authored by
        # minerva_pcb_add_silk_text arrives on this branch.
        pts = [p for p in _list(graphic.get("points"))
               if isinstance(p, list) and len(p) >= 2]
        if len(pts) < 2:
            return SilkHarvest((), (SilkWarning(
                "silk_primitive_unemitted",
                "silk polyline dropped: fewer than 2 valid points"),))
        abs_pts = tuple(_place(cx, cy, rot, side, _num(p[0]), _num(p[1]))
                        for p in pts)
        return SilkHarvest((SilkPoly(abs_pts, width, False),), ())

    if kind == "arc":
        return _harvest_arc(cx, cy, rot, graphic, width, side)

    return _EMPTY


def _harvest_arc(cx: float, cy: float, rot: float, graphic: dict,
                 width: float, side: Side = Side.TOP) -> SilkHarvest:
    pts = [p for p in _list(graphic.get("points"))
           if isinstance(p, list) and len(p) >= 2]
    angle = _opt_num(graphic.get("angle"))

    if angle is not None and angle != 0.0 and len(pts) >= 2:
        # Legacy KiCad form: pts[0] is the arc CENTER, pts[1] is the arc START
        # point, and 'angle' is the sweep (same file-coordinate convention as
        # footprint (at x y rot) — reuse rotate_local_offset() as-is).
        ccx, ccy = _num(pts[0][0]), _num(pts[0][1])
        sx, sy = _num(pts[1][0]), _num(pts[1][1])
        vx, vy = sx - ccx, sy - ccy
        if vx == 0.0 and vy == 0.0:
            return SilkHarvest((), (SilkWarning(
                "silk_primitive_unemitted",
                "silk arc dropped: zero-length radius vector "
                "(center coincides with start)"),))
        evx, evy = rotate_local_offset(vx, vy, angle)
        ex, ey = ccx + evx, ccy + evy
        start_abs = _place(cx, cy, rot, side, sx, sy)
        end_abs = _place(cx, cy, rot, side, ex, ey)
        center_abs = _place(cx, cy, rot, side, ccx, ccy)
        # Chirality is decided HERE, in the BOARD frame (Y-DOWN) that every
        # other coordinate in this harvest is also expressed in. The emitter
        # converts it to the gerber frame ONCE, flipping '+'/'-' along with the
        # Y negation, because a mirror reverses handedness. Nothing about this
        # line changed when the frame boundary was introduced (bug
        # 019fa8011555), and nothing about it should: a second correction here
        # would cancel the conversion instead of composing with it. Empirically
        # verified in the board frame: the DIP-6 pin-1 notch
        # (center,start,angle=-180) must bulge INTO the body (+y in board
        # coords), which is this '-'; the opposite ('+') mirrors it outside the
        # body. Pinned by test_legacy_arc_bulges_into_body.
        orientation = "-" if angle < 0 else "+"
        if side is Side.BOTTOM:
            # A mirror reverses handedness, so the same sweep sign describes the
            # OPPOSITE bulge once the footprint is flipped.
            #
            # This branch needs the flip EXPLICITLY and the 3-point branch below
            # does not — an asymmetry worth stating, because it looks like an
            # oversight. Here the chirality is read off the authored `angle`,
            # which is a footprint-LOCAL quantity that _place never touches. In
            # the 3-point form chirality is computed from the signed area of the
            # already-PLACED points, so the mirror is baked into the inputs and
            # correcting again would cancel it.
            orientation = "+" if orientation == "-" else "-"
        return SilkHarvest(
            (SilkArc(start_abs, end_abs, center_abs, orientation, width),), ())

    if len(pts) >= 3:
        # Modern KiCad 7/8 three-point (start, mid, end) form: a TRUE arc
        # through the circumcircle of the transformed points.
        a = _place(cx, cy, rot, side, _num(pts[0][0]), _num(pts[0][1]))
        b = _place(cx, cy, rot, side, _num(pts[1][0]), _num(pts[1][1]))
        c = _place(cx, cy, rot, side, _num(pts[2][0]), _num(pts[2][1]))
        solved = _circumcenter(a, b, c)
        if solved is not None:
            center, _d = solved
            r2 = (a[0] - center[0]) ** 2 + (a[1] - center[1]) ** 2
            if r2 > _ARC_MAX_RADIUS_MM * _ARC_MAX_RADIUS_MM:
                # Near-collinear: finite but off-board centre — treat as a line.
                solved = None
        if solved is None:
            # Collinear / coincident / near-degenerate (infinite or off-board
            # radius). Fail-SAFE (cosmetic, not fail-closed) — fall back to the
            # polyline through the points; never risk a coordinate overflow.
            # The arc IS emitted (as its chord), but its curvature is lost, so
            # WARN that the shape was approximated (not a silent degrade).
            return SilkHarvest(
                (SilkPoly((a, b, c), width, False),),
                (SilkWarning(
                    "silk_arc_approximated",
                    "silk 3-point arc approximated as a polyline: collinear or "
                    "off-board (infinite/huge) circumradius"),))
        center, d = solved
        # d == 2*cross of a->b->c: positive => CCW turn => '+'; negative => CW
        # => '-'. Same chirality rule the legacy branch above encodes.
        orientation = "+" if d > 0 else "-"
        return SilkHarvest((SilkArc(a, c, center, orientation, width),), ())

    if len(pts) >= 2:
        # 2-point arc with no mid and no angle: underspecified — draw the chord
        # as a polyline. Its curvature is unknowable, so WARN that the arc was
        # approximated (not silent).
        abs_pts = tuple(_place(cx, cy, rot, side, _num(p[0]), _num(p[1]))
                        for p in pts)
        return SilkHarvest(
            (SilkPoly(abs_pts, width, False),),
            (SilkWarning(
                "silk_arc_approximated",
                "silk 2-point arc approximated as a polyline: underspecified "
                "(no mid point and no sweep angle)"),))

    # FEWER THAN 2 usable points. This used to fall through to a bare `return`
    # and drop the primitive with NO diagnostic — a genuinely SILENT discard,
    # inherited from the pre-extraction elif chain and found by the CP2 S2 cold
    # review, which caught this module's own docstring claiming drops are
    # "never silent" while this path existed.
    #
    # A deliberate behaviour change (S3), not part of S2's neutrality contract:
    # under the cardinal rule a silent discard is the defect, and warning costs
    # nothing. Real fixtures do not contain sub-2-point arcs, so no golden moves.
    return SilkHarvest((), (SilkWarning(
        "silk_primitive_unemitted",
        "silk arc dropped: fewer than 2 valid points, and no sweep angle to "
        "reconstruct one from"),))


def refdes_strokes(ref: Any, cx: float, cy: float, rot: float,
                   reference_text: ReferenceTextDefinition | None = None,
                   side: Side = Side.TOP) -> tuple[SilkPoly, ...]:
    """Synthesize one component's REFERENCE DESIGNATOR ("R1", "U3", ...) as
    board-absolute silk stroke geometry.

    THIS IS WHY THE MODULE OWNS MORE THAN "silk strokes". A designator is the
    most common silk on any board and it is NOT IN THE IR AT ALL — it exists
    only as glyph geometry synthesized here. A consumer that harvested only
    authored ``PlacedGraphic`` silk would be looking at a board with no
    designators on it, and would clear silk rules that the fabricated board
    violates. Every silk consumer must call this as well as
    :func:`harvest_graphic`.

    ``cx, cy, rot`` are the component's REAL board placement, independent of
    whatever :func:`harvest_graphic` was called with for the same component: on
    the IR-native harvest the graphics arrive already board-absolute (so that
    call runs at identity), but designator glyphs are rendered in glyph-LOCAL
    coordinates and must be placed by the component's actual placement
    transform regardless.

    ``reference_text`` (019f77fd6d69) is the footprint's OWN authored reference
    fp_text placement, when the caller has a footprint definition to consult.
    When given, the designator is drawn at the footprint's authored local
    anchor/rotation/size instead of the fixed ``REFDES_LOCAL_Y_MM`` default:
    glyphs are rendered anchored at the origin, then EACH point goes through
    the text's own local rotate-then-translate BEFORE the component's placement
    transform — a two-step nested transform, because the anchor is
    footprint-local, not board-absolute. The default (``None``, e.g. every call
    from the loose-dict harvest, which has no footprint definition) keeps the
    single-step placement.

    Returns OPEN polylines: a glyph stroke must NEVER gain a closing segment
    back to its first point, unlike an authored fp_poly outline. This is
    exactly why :func:`harvest_graphic` is not reused here — its "poly" kind is
    always ``closed=True``.
    """
    text = ref if isinstance(ref, str) else None
    if not text or not text.strip():
        return ()
    # AUTHORED-HIDDEN reference => NO designator, anywhere (owner ruling
    # 2026-08-12, bug 019ff2a6ce1b — supersedes the earlier ignore-the-flag
    # disposition). This is the ONE glyph owner, so suppressing here covers the
    # Gerber emitter, the DRC projection and the panel's resolve payload in a
    # single decision; a consumer that wanted to print a hidden designator
    # anyway would be un-WYSIWYG by construction. KiCad itself does not render
    # a hidden fp_text, so this is fidelity, not a Minerva convention.
    if reference_text is not None and reference_text.hidden:
        return ()

    if reference_text is not None:
        size = reference_text.size_mm
        rtx, rty = reference_text.position
        rt_rot = reference_text.rotation_deg
    else:
        size = REFDES_TEXT_SIZE_MM
        rtx = rty = rt_rot = None

    # ONE typeface per board: a designator takes the same in-house 5x7 font as
    # board legend (board_font), rendered CENTRED on its anchor — which is what
    # a designator wants and what a left-anchored legend line does not, hence
    # the h_align argument rather than a second font.
    #
    # board_font.render anchors the BASELINE at local y=0 and does not take a
    # y offset, so the default anchor is applied here. Mirroring is deliberately
    # NOT requested: bottom-side placement mirrors in _place (the pcbnew-pinned
    # PlacementTransform), and asking for it twice would cancel out.
    y0 = 0.0 if reference_text is not None else REFDES_LOCAL_Y_MM
    out: list[SilkPoly] = []
    for glyph_stroke in board_font.render(text, size=size,
                                          h_align="center").polylines:
        stroke = [(lx, ly + y0) for (lx, ly) in glyph_stroke]
        if reference_text is not None:
            # Step 1 is TEXT-LOCAL -> FOOTPRINT-LOCAL and stays side-agnostic:
            # the authored anchor is a footprint-local quantity, and mirroring
            # here as well as in step 2 would apply the flip twice.
            footprint_local = [place_point(rtx, rty, rt_rot, lx, ly)
                               for (lx, ly) in stroke]
            # Step 2 is FOOTPRINT-LOCAL -> BOARD, which is where side applies.
            abs_pts = [_place(cx, cy, rot, side, lx, ly)
                       for (lx, ly) in footprint_local]
        else:
            abs_pts = [_place(cx, cy, rot, side, lx, ly) for (lx, ly) in stroke]
        if len(abs_pts) >= 2:
            out.append(SilkPoly(tuple(abs_pts), SILK_TEXT_WIDTH_MM, False))
    return tuple(out)
