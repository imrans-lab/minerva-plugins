"""THE LOCAL ASSEMBLY PREVIEW: what WE claimed, drawn so a person can disagree
with it before paying for an assembly run.

WHY THIS FILE EXISTS. A house's own placement preview is the other half of this
check and it is mandatory — but theirs shows what THEY think the part is, turned
the way THEIR tape holds it. This one shows what WE claimed. Neither is the
truth; the DISAGREEMENT between them is the signal, and a drawing that hides a
disagreement to look tidy is worse than no drawing.

TWO LAYERS, DELIBERATELY DRAWN FROM TWO DIFFERENT PLACES:

  * THE DRAWING — body outlines, lands and the pin-1 land — comes from the
    compiled board's own placed geometry, the same ink the Gerbers carry.
  * THE CLAIM — a crosshair, a designator, a rotation tick and a side — comes
    from the CPL rows, verbatim.

They are NOT independently computed answers to one question, which would be a
second implementation waiting to drift. They are answers to two DIFFERENT
questions — "where did we draw this part" and "where did we tell the house to
put it" — plotted in one frame so the gap between them is a distance a person
can see. Every number on this page reaches it through
:func:`assembly_outputs.cpl_frame_point` (the board-to-emitted frame map) or
:func:`assembly_outputs.cpl_cells` (a row's emitted text), the same two
functions ``cpl.csv`` is written with. Nothing here formats a coordinate of its
own.

THE FRAME IS THE CPL'S FRAME, not the board's. X verbatim, Y negated, bottom-side
X UNMIRRORED — so a bottom part is drawn where the house is told to put it, seen
through the board from the top. That is the whole reason both sides share one
frame here: drawing the bottom mirrored would be a friendlier picture of a
coordinate system nobody uses.

ROTATION FALLS OUT OF THE FRAME. Inside the flipped drawing group SVG's own
``rotate(a)`` turns from +x toward +y, which is COUNTER-CLOCKWISE on screen —
the same convention the emitted ``Rotation`` column is in. The tick is therefore
drawn at the emitted angle with no sign arithmetic anywhere.

WHAT IS DRAWN FOR EACH PART, and what is not:

  * body outline: the component's placed fab-layer ink, else its silk, else the
    box of its lands. Whichever it was is NAMED on the page, because the three
    are not equally trustworthy — silk is drawn deliberately asymmetric.
  * lands: every pad, so a crosshair sitting BETWEEN two pin rows instead of on
    one is visible. This is the failure the per-placement ``anchor_mm`` key
    exists for, and a body box alone cannot show it.
  * pin 1: the land the footprint numbers ``1``. Marked on every part with more
    than one distinct pad number — see :func:`pin_one`, which explains why the
    rule is not narrower.
  * the claimed centroid, its designator, its rotation and its side.
  * a part the order deliberately does NOT populate: drawn greyed, labelled
    DNP, and carrying no crosshair, because it has no CPL row. An empty spot on
    a board is either deliberate or a part somebody dropped from the order, and
    those look identical unless the drawing says which.

DELIBERATELY LEFT OUT: copper, traces, zones, solder mask, silk legend text and
the design's own provenance stamp. This is not a fabrication preview — the
Gerbers and the fab preview answer that — and every extra layer here is ink
competing with the four things a person is meant to check.

A CROSSHAIR THAT LANDS OFF ITS OWN DRAWING IS DRAWN AS A FAULT: a red ring and a
leader back to the part it claims to be. That is not a check with a code and it
raises no advisory — the DCR puts this boundary at a human, not at a rule — but
a claim outside the ink it belongs to is the one disagreement worth spending
colour on.

AND IT IS NOT THE INTERESTING HALF OF THAT FAILURE. A wrong anchor usually lands
INSIDE the drawing — on the drawing's middle rather than on the part's, which is
what happens when several parts share one anchor measured off the whole drawing.
No ring fires for that and none should: it is a legal shape. Two things make it
visible instead — the LANDS, so a crosshair sitting between two pin rows rather
than on one can be seen, and a NAMED note listing every placement that inherited
an anchor it did not state. That is the trap the DCR's own worked example fell
into, and this page is the first place in the pipeline that can show it.

The output is a single self-contained SVG file. No script, no external stylesheet
and no web font: a person on a laptop opens it in a browser with no toolchain,
which is the only delivery that survives being the last check before payment.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

from . import assembly_outputs, ir_projection, silk_source
from .footprint_def import PadShape
from .resolved_board import (
    ANCHOR_BASIS_AUTHORED,
    ArcGeometry,
    CircleGeometry,
    LayerRole,
    LineGeometry,
    PolygonGeometry,
    PolylineGeometry,
)

#: The package slot this file fills (DCR 01a0542d902f, "Package layout").
PREVIEW_FILE = "assembly-preview.svg"

#: Rendering scale. The drawing group's user unit is ONE MILLIMETRE in the
#: emitted CPL frame, so every length below that is expressed in mm is a real
#: board dimension; this is only how many screen pixels one of them gets.
PX_PER_MM = 6.0
#: Blank board around the drawn extent, in mm, so a part on the rim is not cut
#: in half by the page edge.
MARGIN_MM = 3.0

# --- marker sizes, in board millimetres. Stroke WEIGHTS are not here: they
#     live in the stylesheet, which is the only place they are read.
CROSS_ARM_MM = 0.9
TICK_MM = 1.8
TICK_DOT_MM = 0.22
PIN_ONE_RADIUS_MM = 0.30
OFF_BODY_RADIUS_MM = 1.1
REF_TEXT_MM = 1.15
NOTE_TEXT_MM = 0.95

# --- page furniture, in screen pixels ---------------------------------------
PAGE_PAD_PX = 24.0
HEADER_LINE_PX = 16.0
TABLE_LINE_PX = 15.0
TABLE_COLUMN_PX = (120.0, 96.0, 96.0, 74.0, 78.0)
TABLE_GUTTER_PX = 34.0
#: Above this many placements the emitted-row table splits into two columns
#: rather than running the page metres long.
TABLE_SPLIT_ROWS = 22

#: Which body ink answers "where is this part", in the order it is looked for.
#: The same ladder :mod:`assembly_anchor` measures an anchor with, so the
#: outline a reader sees is the outline the anchor was taken off — a preview
#: drawn from a different layer than the anchor was measured from would show a
#: crosshair off-centre and no reason for it.
OUTLINE_FAB = "fab_outline"
OUTLINE_SILK = "silk"
OUTLINE_LANDS = "lands"
OUTLINE_NONE = "none"

_OUTLINE_NOTE = {
    OUTLINE_FAB: "body from the fab-layer outline",
    OUTLINE_SILK: "body from SILK — drawn asymmetric on purpose, so it is not "
                  "a body box; check this part against its datasheet",
    OUTLINE_LANDS: "no drawn body: the box shown is the lands",
    OUTLINE_NONE: "nothing drawn: this footprint has no outline and no sized land",
}


# ---------------------------------------------------------------------------
# SVG primitives. Everything below emits into the DRAWING GROUP, whose user
# unit is one millimetre of the emitted CPL frame with +y UP.
# ---------------------------------------------------------------------------


def _esc(value) -> str:
    """XML text/attribute escaping. Board data reaches this file — a designator,
    a footprint name, a board name — and a raw ``&`` produces a file a browser
    refuses to open at all rather than one that looks slightly wrong."""
    return (str(value).replace("&", "&amp;").replace("<", "&lt;")
            .replace(">", "&gt;").replace('"', "&quot;"))


def _n(value: float) -> str:
    """A coordinate in SVG path/attribute syntax. Four decimals of a millimetre
    is a tenth of a micron: below any board feature and stable across runs, so
    the file's bytes (and therefore its digest in the manifest) reproduce."""
    text = f"{float(value):.4f}".rstrip("0").rstrip(".")
    return "0" if text in ("", "-0") else text


def _text(x: float, y: float, body: str, *, cls: str, size_mm: float,
          anchor: str = "start") -> str:
    """A label in the drawing group.

    The group is y-FLIPPED so the board reads the right way up; text inside it
    would be flipped with it, so each label carries its own counter-flip. The
    net transform is a plain uniform scale, which is why ``font-size`` here is
    still a real millimetre height on the board."""
    return (f'<text transform="translate({_n(x)},{_n(y)}) scale(1,-1)" '
            f'class="{cls}" font-size="{_n(size_mm)}" text-anchor="{anchor}">'
            f'{_esc(body)}</text>')


def _polyline(points, *, cls: str, closed: bool) -> str:
    if len(points) < 2:
        return ""
    data = " ".join(f"{_n(x)},{_n(y)}" for x, y in points)
    tag = "polygon" if closed else "polyline"
    return f'<{tag} class="{cls}" points="{data}"/>'


#: The circumcentre solver, aliased the way :mod:`gerber` aliases it so a
#: three-point arc is solved in ONE place for the fab layers and for this page.
_circumcenter = silk_source._circumcenter


def _arc_path(start, mid, end, *, cls: str) -> str:
    """A three-point arc as an SVG elliptical-arc path.

    The circumcentre solver is :mod:`silk_source`'s, aliased the way
    :mod:`gerber` aliases it, so the arc a person sees here and the arc a house
    receives on the fab layers are struck from one derivation. Collinear or
    absurd-radius triples fall back to a polyline, which is what such an arc
    physically is."""
    solved = _circumcenter(start, mid, end)
    if solved is None:
        return _polyline((start, mid, end), cls=cls, closed=False)
    (cx, cy), d = solved
    radius = math.hypot(start[0] - cx, start[1] - cy)
    if not math.isfinite(radius) or radius > silk_source._ARC_MAX_RADIUS_MM:
        return _polyline((start, mid, end), cls=cls, closed=False)
    # SWEEP is read off the frame the points are already in: `d > 0` is the
    # increasing-angle turn of THIS frame, and inside the drawing group SVG's
    # own positive sweep is the same direction. No sign correction anywhere.
    sweep = 1 if d > 0 else 0
    theta = math.atan2(end[1] - cy, end[0] - cx) - math.atan2(start[1] - cy,
                                                              start[0] - cx)
    span = theta % (2.0 * math.pi) if sweep else (-theta) % (2.0 * math.pi)
    large = 1 if span > math.pi else 0
    return (f'<path class="{cls}" d="M {_n(start[0])},{_n(start[1])} '
            f'A {_n(radius)},{_n(radius)} 0 {large} {sweep} '
            f'{_n(end[0])},{_n(end[1])}"/>')


# ---------------------------------------------------------------------------
# The drawing: one component's ink, in the emitted frame.
# ---------------------------------------------------------------------------


@dataclass
class _Drawing:
    """One COMPONENT's ink — the drawing half of the page.

    A component is a drawing and a placement is a part; the two coincide for
    almost every component and deliberately do not for a synthetic expansion,
    where one drawing carries several parts. So the ink is collected per
    component and the crosshairs are plotted per placement, on top of it."""

    ref: str
    populate: bool
    side: str
    outline_basis: str
    ink: list[str] = field(default_factory=list)
    points: list[tuple[float, float]] = field(default_factory=list)
    pin_one: tuple[float, float] | None = None
    pin_one_note: str = ""

    def bounds(self):
        """The drawn extent in the emitted frame, or None for ink-less
        furniture."""
        if not self.points:
            return None
        xs = [p[0] for p in self.points]
        ys = [p[1] for p in self.points]
        return min(xs), min(ys), max(xs), max(ys)

    def contains(self, x: float, y: float) -> bool:
        box = self.bounds()
        if box is None:
            return True  # nothing drawn: there is no disagreement to show
        return box[0] <= x <= box[2] and box[1] <= y <= box[3]


def pin_one(board, component):
    """``(land, note)``: the placed land this footprint numbers ``1`` in the
    emitted frame, or ``None`` and a sentence saying why there is no mark.

    WHY EVERY MULTI-TERMINAL PART GETS THIS MARK and not some narrower set of
    "polarized" ones: board data cannot tell a resistor from an LED. The two
    sit on identical land patterns, carry identical geometry, and differ only
    in a part number this file has no dictionary for. Deciding orientation
    sensitivity from the reference-designator prefix or the pad count would
    guess, and the guess that fails is the one that leaves a reversed diode
    unmarked — the exact defect a pre-payment look is for. Marking a resistor's
    pin 1 costs a dot nobody needs to act on; the DCR is also explicit that no
    part-semantics database is in scope.

    A footprint with ONE distinct pad number has no end to get wrong (a test
    point, a mounting hole, a fiducial) and is left unmarked. So is one whose
    pads are unnumbered, or numbered without a ``1`` — and both cases are said
    out loud on the page, because an absent mark must never read as a part that
    was checked and found symmetric.

    The land is read from ``placed_pads``, which the compiler already put
    through the placement transform. Nothing here re-composes a position."""
    definition = next((d for d in board.footprint_definitions
                       if d.content_id == component.footprint_id), None)
    if definition is None:
        return None, "footprint definition not in the compiled board"
    numbers = {pad.source_id: pad.number for pad in definition.pads}
    distinct = {number for number in numbers.values() if number}
    if not distinct:
        return None, "no pin-1 mark: this footprint's pads carry no numbers"
    if len(distinct) == 1:
        return None, "no pin-1 mark: one terminal, so there is no end to reverse"
    for pad in component.placed_pads:
        if numbers.get(pad.source_id) == "1":
            return assembly_outputs.cpl_frame_point(pad.position), ""
    return None, "no pin-1 mark: this footprint numbers no pad 1"


def _pad_ink(pad, cls: str):
    """One land as SVG, plus the points its extent contributes.

    Drawn from the PLACED pad — position, size and rotation already composed by
    the compiler — so a land in this picture is the land in the Gerbers."""
    cx, cy = assembly_outputs.cpl_frame_point(pad.position)
    if pad.size is None:
        radius = 0.15
        return (f'<circle class="{cls}" cx="{_n(cx)}" cy="{_n(cy)}" '
                f'r="{_n(radius)}"/>'), [(cx - radius, cy - radius),
                                         (cx + radius, cy + radius)]
    half_w, half_h = float(pad.size[0]) / 2.0, float(pad.size[1]) / 2.0
    # A BOARD-frame angle used VERBATIM, for the same reason the emitted
    # Rotation column is: negating y turns the board's clockwise-positive angle
    # into a counter-clockwise-positive one, and SVG's own rotate() inside this
    # y-up group is counter-clockwise. The land therefore turns with the part.
    angle = float(pad.rotation_deg)
    corners = [(dx, dy) for dx in (-half_w, half_w) for dy in (-half_h, half_h)]
    radians = math.radians(angle)
    cos_a, sin_a = math.cos(radians), math.sin(radians)
    extent = [(cx + dx * cos_a - dy * sin_a, cy + dx * sin_a + dy * cos_a)
              for dx, dy in corners]
    spin = "" if angle == 0 else f' transform="rotate({_n(angle)},{_n(cx)},{_n(cy)})"'
    if pad.shape is PadShape.CIRCLE or (pad.shape is PadShape.OVAL
                                        and half_w == half_h):
        return (f'<circle class="{cls}" cx="{_n(cx)}" cy="{_n(cy)}" '
                f'r="{_n(half_w)}"/>'), extent
    corner = 0.0
    if pad.shape is PadShape.OVAL:
        corner = min(half_w, half_h)
    elif pad.shape is PadShape.ROUNDRECT:
        corner = min(half_w, half_h) * 2.0 * (pad.corner_rratio or 0.0)
    rounding = "" if corner <= 0 else f' rx="{_n(corner)}" ry="{_n(corner)}"'
    return (f'<rect class="{cls}" x="{_n(cx - half_w)}" y="{_n(cy - half_h)}" '
            f'width="{_n(half_w * 2)}" height="{_n(half_h * 2)}"'
            f'{rounding}{spin}/>'), extent


def _graphic_ink(geometry, cls: str):
    """One placed graphic as SVG, plus the points its extent contributes."""
    to_frame = assembly_outputs.cpl_frame_point
    if isinstance(geometry, LineGeometry):
        points = [to_frame(geometry.a), to_frame(geometry.b)]
        return _polyline(points, cls=cls, closed=False), points
    if isinstance(geometry, CircleGeometry):
        cx, cy = to_frame(geometry.center)
        radius = float(geometry.radius_mm)
        return (f'<circle class="{cls}" cx="{_n(cx)}" cy="{_n(cy)}" '
                f'r="{_n(radius)}"/>'), [(cx - radius, cy - radius),
                                         (cx + radius, cy + radius)]
    if isinstance(geometry, ArcGeometry):
        start = to_frame(geometry.start)
        mid = to_frame(geometry.mid)
        end = to_frame(geometry.end)
        return _arc_path(start, mid, end, cls=cls), [start, mid, end]
    if isinstance(geometry, (PolygonGeometry, PolylineGeometry)):
        points = [to_frame(p) for p in geometry.points]
        closed = isinstance(geometry, PolygonGeometry)
        return _polyline(points, cls=cls, closed=closed), points
    return "", []


def _outline_ink(component, cls: str):
    """The component's BODY, and which layer answered.

    Fab first, because that layer is KiCad's own assembly drawing and is what
    the anchor was measured off. Silk second, and SAID SO on the page: a silk
    outline carries a cathode bar or a pin-1 notch, so its shape is not the
    part's. Lands last, as a box, for furniture that draws no body at all."""
    for basis, role in ((OUTLINE_FAB, LayerRole.FAB), (OUTLINE_SILK, LayerRole.SILK)):
        ink: list[str] = []
        points: list[tuple[float, float]] = []
        for graphic in component.placed_graphics:
            if graphic.layer.role is not role:
                continue
            fragment, extent = _graphic_ink(graphic.geometry, cls)
            if fragment:
                ink.append(fragment)
                points.extend(extent)
        if ink:
            return basis, ink, points
    return OUTLINE_LANDS, [], []


def _lands_box(points, cls: str) -> str:
    """The box of a body-less footprint's lands, so a crosshair still has
    something to be centred on."""
    if not points:
        return ""
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    return (f'<rect class="{cls}" x="{_n(min(xs))}" y="{_n(min(ys))}" '
            f'width="{_n(max(xs) - min(xs))}" height="{_n(max(ys) - min(ys))}"/>')


def _drawing(board, component) -> _Drawing:
    populate = bool(component.assembly.populate) if component.assembly else True
    side = component.placement.side.value
    body_cls = ("body-dnp" if not populate
                else "body-top" if side == "top" else "body-bottom")
    pad_cls = "land-dnp" if not populate else "land"

    pad_ink: list[str] = []
    pad_points: list[tuple[float, float]] = []
    for pad in component.placed_pads:
        fragment, extent = _pad_ink(pad, pad_cls)
        if fragment:
            pad_ink.append(fragment)
            pad_points.extend(extent)

    basis, body_ink, body_points = _outline_ink(component, body_cls)
    if basis == OUTLINE_LANDS:
        box = _lands_box(pad_points, body_cls)
        if box:
            body_ink = [box]
        else:
            basis = OUTLINE_NONE

    mark, note = pin_one(board, component)
    drawing = _Drawing(ref=component.ref, populate=populate, side=side,
                       outline_basis=basis, ink=pad_ink + body_ink,
                       points=pad_points + body_points,
                       pin_one=mark, pin_one_note=note)
    if mark is not None:
        drawing.ink.append(
            f'<circle class="pin-one" cx="{_n(mark[0])}" cy="{_n(mark[1])}" '
            f'r="{_n(PIN_ONE_RADIUS_MM)}"/>')
        drawing.points.append(mark)
    if not populate:
        centre = drawing.bounds()
        if centre is not None:
            drawing.ink.append(_text((centre[0] + centre[2]) / 2.0,
                                     (centre[1] + centre[3]) / 2.0,
                                     "DNP", cls="dnp-label", size_mm=NOTE_TEXT_MM,
                                     anchor="middle"))
    return drawing


# ---------------------------------------------------------------------------
# The claim: one CPL row's crosshair.
# ---------------------------------------------------------------------------


def _mark(row, cells, drawing, basis: str
          ) -> tuple[list[str], list[tuple[float, float]], bool]:
    """One placement's crosshair, designator, rotation tick and — when it lands
    off its own drawing — the leader that says so.

    ``row.x_mm`` and ``row.y_mm`` are plotted VERBATIM. They are already in this
    page's frame because this page's frame IS the emitted one, so there is no
    arithmetic between the cell a house reads and the point a person looks at."""
    x, y = float(row.x_mm), float(row.y_mm)
    off_body = drawing is not None and not drawing.contains(x, y)
    cls = "claim-off" if off_body else "claim"
    ink = [
        f'<path class="{cls}" d="M {_n(x - CROSS_ARM_MM)},{_n(y)} '
        f'h {_n(CROSS_ARM_MM * 2)} M {_n(x)},{_n(y - CROSS_ARM_MM)} '
        f'v {_n(CROSS_ARM_MM * 2)}"/>',
        # The tick sits inside a rotate() taken straight from the emitted
        # Rotation cell: in this frame SVG's positive rotation IS the house's
        # counter-clockwise-positive convention, so a reader comparing this
        # picture with the house's preview is comparing the same number.
        f'<g transform="rotate({_n(row.rotation_deg)},{_n(x)},{_n(y)})">'
        f'<path class="{cls}-tick" d="M {_n(x)},{_n(y)} h {_n(TICK_MM)}"/>'
        f'<circle class="{cls}-tick" cx="{_n(x + TICK_MM)}" cy="{_n(y)}" '
        f'r="{_n(TICK_DOT_MM)}"/></g>',
    ]
    points = [(x - CROSS_ARM_MM, y - CROSS_ARM_MM),
              (x + TICK_MM, y + CROSS_ARM_MM)]
    if off_body:
        box = drawing.bounds()
        ink.append(f'<circle class="claim-off-ring" cx="{_n(x)}" cy="{_n(y)}" '
                   f'r="{_n(OFF_BODY_RADIUS_MM)}"/>')
        if box is not None:
            ink.append(f'<path class="claim-leader" d="M {_n(x)},{_n(y)} '
                       f'L {_n((box[0] + box[2]) / 2.0)},'
                       f'{_n((box[1] + box[3]) / 2.0)}"/>')
    label = f"{cells[0]}  {cells[4]}°  {cells[3]}"
    ink.append(_text(x + CROSS_ARM_MM * 0.4, y + CROSS_ARM_MM * 0.9, label,
                     cls=f"{cls}-label", size_mm=REF_TEXT_MM))
    # THE MACHINE-READABLE HALF, and it carries the EMITTED CELLS as text rather
    # than numbers of its own: what a test reads back off this drawing is
    # comparable to cpl.csv cell for cell, so a preview that ever stopped being
    # the same derivation fails a string comparison rather than a tolerance.
    flag = ' data-off-body="1"' if off_body else ""
    opening = (f'<g class="placement" data-ref="{_esc(cells[0])}" '
               f'data-x="{_esc(cells[1])}" data-y="{_esc(cells[2])}" '
               f'data-layer="{_esc(cells[3])}" data-rotation="{_esc(cells[4])}" '
               f'data-anchor-basis="{_esc(basis)}"{flag}>')
    return [opening, *ink, "</g>"], points, off_body


# ---------------------------------------------------------------------------
# The page.
# ---------------------------------------------------------------------------

_STYLE = """
  .page { fill: #ffffff; }
  text { font-family: 'DejaVu Sans', 'Helvetica Neue', Arial, sans-serif;
         fill: #16202b; }
  .mono { font-family: 'DejaVu Sans Mono', 'SFMono-Regular', Menlo, monospace; }
  .title { font-size: 17px; font-weight: 700; }
  .prose { font-size: 12px; fill: #43505e; }
  .prose-strong { font-size: 12px; fill: #16202b; font-weight: 600; }
  .rim { fill: none; stroke: #9aa7b4; stroke-width: 0.2; stroke-dasharray: 1.6 0.9; }
  .land { fill: #cfe0ef; stroke: none; }
  .land-dnp { fill: #e4e7ea; stroke: none; }
  .body-top { fill: none; stroke: #1f4f82; stroke-width: 0.14;
              stroke-linecap: round; stroke-linejoin: round; }
  .body-bottom { fill: none; stroke: #6c3fa0; stroke-width: 0.14;
                 stroke-dasharray: 0.7 0.45;
                 stroke-linecap: round; stroke-linejoin: round; }
  .body-dnp { fill: none; stroke: #99a3ad; stroke-width: 0.1;
              stroke-dasharray: 0.4 0.4; }
  .pin-one { fill: #16202b; stroke: none; }
  .claim { fill: none; stroke: #d1451f; stroke-width: 0.11; }
  .claim-tick { fill: #d1451f; stroke: #d1451f; stroke-width: 0.11; }
  .claim-label { fill: #b03a17; font-weight: 600; }
  .claim-off { fill: none; stroke: #b00020; stroke-width: 0.16; }
  .claim-off-tick { fill: #b00020; stroke: #b00020; stroke-width: 0.16; }
  .claim-off-label { fill: #b00020; font-weight: 700; }
  .claim-off-ring { fill: none; stroke: #b00020; stroke-width: 0.14; }
  .claim-leader { fill: none; stroke: #b00020; stroke-width: 0.08;
                  stroke-dasharray: 0.5 0.4; }
  .dnp-label { fill: #78838e; font-weight: 600; }
  .cell { font-size: 12px; fill: #16202b; }
  .cell-head { font-size: 12px; fill: #43505e; font-weight: 700; }
  .cell-off { font-size: 12px; fill: #b00020; font-weight: 700; }
  .rule { stroke: #d6dce2; stroke-width: 1; }
"""

#: The legend, as (css class, glyph kind, page-scale pen, wording). Drawn rather
#: than described, because a legend a reader has to translate is one they skip.
#: The pen is needed because board ink is measured in fractions of a millimetre
#: and a 0.14 mm sample line at page scale is invisible.
_LEGEND = (
    ("body-top", "line", "stroke-width:1.7",
     "body outline, top side — drawn from the board"),
    ("body-bottom", "line", "stroke-width:1.7;stroke-dasharray:4 2.5",
     "body outline, bottom side, seen through the board"),
    ("land", "box", "", "lands"),
    ("pin-one", "dot", "", "pin 1"),
    ("claim", "cross", "stroke-width:1.5",
     "centroid + rotation the pick-and-place file claims"),
    ("claim-off", "cross", "stroke-width:1.9",
     "that claim landed off its own part — look here first"),
    ("body-dnp", "line", "stroke-width:1.4;stroke-dasharray:2.5 2.5",
     "not populated: in the gerbers, absent from both CSVs"),
)


def _header_lines(board, profile, counts) -> list[tuple[str, str]]:
    """The page's prose, as (css class, text). Says what the frame is and what
    the reader is being asked to do, because a drawing whose conventions are
    unstated is a drawing that can be read two ways."""
    service = "no manufacturing tier claimed"
    if profile.service is not None:
        service = (f"{profile.service.id} · fab rules {profile.service.fab_profile}"
                   f" · places {', '.join(profile.service.constraints.assembly_sides)}")
    return [
        ("prose-strong", f"{profile.display_name} ({profile.id}) · {service}"),
        ("prose",
         f"{counts['placements']} placement(s) from {counts['components']} drawn "
         f"component(s); {counts['excluded']} not populated. Scale "
         f"{_n(PX_PER_MM)} px per mm."),
        ("prose",
         "COORDINATES AND ROTATIONS HERE ARE THE CELLS OF cpl.csv, printed by the "
         "same code that writes the file — not a second calculation of them."),
        ("prose",
         "Frame: X as emitted, Y as emitted (the board's Y negated), bottom-side X "
         "UNMIRRORED. Top view. Rotation is counter-clockwise-positive."),
        ("prose-strong",
         "Outlines and lands come from the board's own geometry; crosshairs come "
         "from the pick-and-place file. Where the two disagree, either the anchor "
         "this order claims or the footprint it was measured off is wrong."),
        ("prose",
         "This is half the check. The other half is the house's own placement "
         "preview, which shows THEIR part turned the way THEIR tape holds it — "
         "a disagreement between the two is the thing worth stopping for."),
    ]


def _legend_ink(x: float, y: float) -> tuple[list[str], float]:
    """The legend, drawn in PAGE pixels. Its glyphs are stroked at page scale
    rather than board scale, so a 0.14 mm outline is still visible as a sample."""
    ink: list[str] = []
    cursor = y
    for cls, kind, style, wording in _LEGEND:
        pen = f' style="{style}"' if style else ""
        if kind == "line":
            ink.append(f'<path class="{cls}"{pen} '
                       f'd="M {_n(x)},{_n(cursor - 4)} h 18"/>')
        elif kind == "box":
            ink.append(f'<rect class="{cls}" x="{_n(x)}" y="{_n(cursor - 8)}" '
                       f'width="18" height="7"/>')
        elif kind == "dot":
            ink.append(f'<circle class="{cls}" cx="{_n(x + 9)}" '
                       f'cy="{_n(cursor - 4)}" r="3.2"/>')
        else:
            ink.append(f'<path class="{cls}"{pen} '
                       f'd="M {_n(x)},{_n(cursor - 4)} h 18 '
                       f'M {_n(x + 9)},{_n(cursor - 11)} v 14"/>')
        ink.append(f'<text class="prose" x="{_n(x + 26)}" y="{_n(cursor)}">'
                   f'{_esc(wording)}</text>')
        cursor += HEADER_LINE_PX
    return ink, cursor


def _notes(drawings) -> list[str]:
    """Per-part statements the drawing itself cannot make: which layer the body
    came from when it was not the fab layer, and why a part carries no pin-1
    mark. Absence of a mark must never read as a part that was checked."""
    grouped: dict[str, list[str]] = {}
    for drawing in drawings:
        for statement in (
                _OUTLINE_NOTE[drawing.outline_basis]
                if drawing.outline_basis != OUTLINE_FAB else None,
                drawing.pin_one_note or None):
            if statement:
                grouped.setdefault(statement, []).append(drawing.ref)
    return [f"{', '.join(refs)} — {statement}"
            for statement, refs in grouped.items()]


def _expansion_notes(board) -> list[str]:
    """The statement for a drawing that carries SEVERAL parts and let every one
    of them inherit ONE anchor measured off the whole drawing.

    Nothing refuses that shape and nothing advises on it: the anchors WERE
    measured, they are the right distance apart, and every gate passes — the
    DCR's own worked example shipped that way and would have centred both socket
    rows between themselves. This page is the first place it can be seen, so it
    says out loud which parts to look at, and it stays a SENTENCE rather than a
    check because the boundary here is deliberately a person."""
    out: list[str] = []
    for component in board.components:
        places = component.physical_placements
        if len(places) < 2:
            continue
        if any(item.anchor_basis == ANCHOR_BASIS_AUTHORED for item in places):
            continue
        out.append(
            f"{', '.join(item.ref for item in places)} — one drawing, "
            f"{len(places)} parts, and every anchor was measured off the WHOLE "
            f"drawing rather than stated per placement. Check each crosshair "
            f"sits on the part it names and not between them; "
            f"assembly.placements[].anchor_mm is how a placement states its own")
    return out


def _table(rows, cells_by_ref, off_body_refs, columns, x: float, y: float
           ) -> tuple[list[str], float]:
    """The emitted CPL rows, as text, beside the picture.

    Present because the house's quote page shows a parsed table of the same
    rows, and comparing two tables is a check a person can actually complete —
    comparing a table against a drawing is not."""
    if not rows:
        return ([f'<text class="prose" x="{_n(x)}" y="{_n(y)}">no placements: '
                 f'every part on this board is marked not-populated</text>'],
                y + TABLE_LINE_PX)
    ink: list[str] = []
    per_column = len(rows) if len(rows) <= TABLE_SPLIT_ROWS else (len(rows) + 1) // 2
    block_width = sum(TABLE_COLUMN_PX) + TABLE_GUTTER_PX
    for index, row in enumerate(rows):
        column, line = divmod(index, per_column)
        left = x + column * block_width
        top = y + (line + 1) * TABLE_LINE_PX
        if line == 0:
            for offset, heading in zip(_column_offsets(), columns):
                ink.append(f'<text class="cell-head" x="{_n(left + offset)}" '
                           f'y="{_n(y)}">{_esc(heading)}</text>')
            ink.append(f'<path class="rule" d="M {_n(left)},{_n(y + 4)} '
                       f'h {_n(sum(TABLE_COLUMN_PX))}"/>')
        cls = "cell-off" if row.ref in off_body_refs else "cell"
        for offset, cell in zip(_column_offsets(), cells_by_ref[row.ref]):
            ink.append(f'<text class="{cls} mono" x="{_n(left + offset)}" '
                       f'y="{_n(top)}">{_esc(cell)}</text>')
    return ink, y + (per_column + 1) * TABLE_LINE_PX


def _column_offsets():
    offset = 0.0
    for width in TABLE_COLUMN_PX:
        yield offset
        offset += width


def _board_rim(board) -> tuple[str, list[tuple[float, float]]]:
    """The board edge, when it is a rectangle. A shaped outline is NOT
    approximated by its bounding box: a rim drawn in the wrong place would be
    read as a part sitting off the board."""
    try:
        origin_x, origin_y, width, height = ir_projection.outline_frame(board.outline)
    except (ValueError, TypeError):
        return "", []
    # The board's far Y edge is its LOW y here: the frame is the emitted one, so
    # the board's y-down span comes back inverted and the rect grows upward.
    left, low_y = assembly_outputs.cpl_frame_point((origin_x, origin_y + height))
    corners = [(left, low_y), (left + width, low_y + height)]
    return (f'<rect class="rim" x="{_n(left)}" y="{_n(low_y)}" '
            f'width="{_n(width)}" height="{_n(height)}"/>'), corners


def render(board, emission) -> str:
    """The whole preview for one compiled board and ONE emission of its rows.

    ``emission`` is the :class:`assembly_outputs.AssemblyEmission` the package's
    ``cpl.csv`` is rendered from — the same object, not a second walk of the
    same board. That is the single thing that makes this drawing evidence about
    the file a house receives rather than about a board that looks like it."""
    profile = emission.profile
    drawings = [_drawing(board, component) for component in board.components]
    by_ref = {}
    for component, drawing in zip(board.components, drawings):
        for physical in component.physical_placements:
            by_ref[physical.ref] = drawing

    cells_by_ref = {row.ref: assembly_outputs.cpl_cells(row, profile)
                    for row in emission.cpl}
    basis_by_ref = {physical.ref: physical.anchor_basis
                    for component in board.components
                    for physical in component.physical_placements}
    claim_ink: list[str] = []
    points: list[tuple[float, float]] = []
    off_body_refs: set[str] = set()
    for row in emission.cpl:
        ink, extent, off_body = _mark(row, cells_by_ref[row.ref],
                                      by_ref.get(row.ref),
                                      basis_by_ref.get(row.ref, ""))
        claim_ink.extend(ink)
        points.extend(extent)
        if off_body:
            off_body_refs.add(row.ref)

    rim, rim_points = _board_rim(board)
    points.extend(rim_points)
    for drawing in drawings:
        points.extend(drawing.points)
    if not points:
        points = [(0.0, 0.0), (10.0, 10.0)]

    min_x = min(p[0] for p in points) - MARGIN_MM
    max_x = max(p[0] for p in points) + MARGIN_MM
    min_y = min(p[1] for p in points) - MARGIN_MM
    max_y = max(p[1] for p in points) + MARGIN_MM
    draw_w = (max_x - min_x) * PX_PER_MM
    draw_h = (max_y - min_y) * PX_PER_MM

    counts = {"placements": len(emission.cpl), "components": len(board.components),
              "excluded": len(emission.excluded_refs)}
    header = _header_lines(board, profile, counts)

    body: list[str] = []
    cursor = PAGE_PAD_PX + 18.0
    body.append(f'<text class="title" x="{_n(PAGE_PAD_PX)}" y="{_n(cursor)}">'
                f'{_esc(board.name)} — assembly preview</text>')
    cursor += HEADER_LINE_PX + 4.0
    for cls, line in header:
        body.append(f'<text class="{cls}" x="{_n(PAGE_PAD_PX)}" y="{_n(cursor)}">'
                    f'{_esc(line)}</text>')
        cursor += HEADER_LINE_PX
    cursor += 8.0
    legend, cursor = _legend_ink(PAGE_PAD_PX, cursor)
    body.extend(legend)
    cursor += 12.0

    # The drawing group. Its user unit is one millimetre of the emitted frame,
    # and the y flip is what puts the board the right way up on a y-down page.
    origin_x = PAGE_PAD_PX - min_x * PX_PER_MM
    origin_y = cursor + max_y * PX_PER_MM
    body.append(f'<g transform="translate({_n(origin_x)},{_n(origin_y)}) '
                f'scale({_n(PX_PER_MM)},{_n(-PX_PER_MM)})">')
    if rim:
        body.append(rim)
    for drawing in drawings:
        body.extend(drawing.ink)
    body.extend(claim_ink)
    body.append("</g>")
    cursor += draw_h + 24.0

    notes = _notes(drawings) + _expansion_notes(board)
    if notes:
        body.append(f'<text class="cell-head" x="{_n(PAGE_PAD_PX)}" '
                    f'y="{_n(cursor)}">What this drawing does not claim</text>')
        cursor += HEADER_LINE_PX
        for note in notes:
            body.append(f'<text class="prose" x="{_n(PAGE_PAD_PX)}" '
                        f'y="{_n(cursor)}">{_esc(note)}</text>')
            cursor += HEADER_LINE_PX
        cursor += 12.0

    body.append(f'<text class="cell-head" x="{_n(PAGE_PAD_PX)}" y="{_n(cursor)}">'
                f'The rows as emitted — compare these against the house\'s parsed '
                f'table</text>')
    cursor += HEADER_LINE_PX + 6.0
    table, cursor = _table(emission.cpl, cells_by_ref, off_body_refs,
                           profile.cpl_columns, PAGE_PAD_PX, cursor)
    body.extend(table)

    block = sum(TABLE_COLUMN_PX) + TABLE_GUTTER_PX
    table_width = block * (2 if len(emission.cpl) > TABLE_SPLIT_ROWS else 1)
    page_w = max(draw_w, table_width, 760.0) + PAGE_PAD_PX * 2
    page_h = cursor + PAGE_PAD_PX

    return "\n".join([
        '<?xml version="1.0" encoding="UTF-8"?>',
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{_n(page_w)}" '
        f'height="{_n(page_h)}" viewBox="0 0 {_n(page_w)} {_n(page_h)}" '
        f'data-board="{_esc(board.name)}" data-profile="{_esc(profile.id)}">',
        f"<style>{_STYLE}</style>",
        f'<rect class="page" x="0" y="0" width="{_n(page_w)}" '
        f'height="{_n(page_h)}"/>',
        *body,
        "</svg>",
        "",
    ])
