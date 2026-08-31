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
#: The narrowest content width any page has (the ``max(..., 760.0)`` floor in
#: :func:`render`). Prose wrapped to THIS budget fits every page, whatever the
#: drawing's own width turns out to be — which is what lets the wrap be a fixed
#: constant instead of a per-board layout decision.
PROSE_BUDGET_PX = 760.0
HEADER_LINE_PX = 16.0
TABLE_LINE_PX = 15.0
#: Per-column MINIMUM widths; :func:`_column_widths` grows a column whose
#: widest cell or heading needs more, so the grid is stable on ordinary boards
#: and elastic on one with a forty-character designator.
TABLE_COLUMN_PX = (120.0, 96.0, 96.0, 74.0, 78.0)
#: Widest any table CELL (heading or value) may claim, in page pixels — about
#: 48 mono characters. Text past it is cut with a visible "..." by
#: :func:`_fit_text`, so a pathological designator widens its column to this
#: and no further: the page's width is bounded by the column COUNT, which the
#: profile fixes, never by cell content.
TABLE_CELL_MAX_PX = 360.0
#: Title lines kept before a visible "...". The board name is data and wraps
#: like the prose, but must not be able to grow the page without limit either.
TITLE_MAX_LINES = 3
#: Widest a placement label may claim, in board mm. Label boxes feed the drawn
#: extent — and through it the page width — so the designator half of a label
#: is capped here; the cut is visible, and the untruncated ref still rides in
#: the group's data-ref attribute.
LABEL_MAX_MM = 24.0
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


# --- text metrics, estimated DELIBERATELY WIDE ------------------------------
#
# The page has no font engine, so a line's width is bounded from per-glyph
# ADVANCE TABLES: DejaVu Sans / DejaVu Sans Bold hmtx advances (v2.37,
# units-per-em 2048 — the first face in the stylesheet's stack and the widest
# of them), each value padded 2% and ceiled to 3 decimals, so the table is an
# upper bound on the rendered advance rather than an estimate of it (the pad
# also absorbs kerning, which in this face only ever tightens).
#
# WHAT THE WIDTH GUARANTEE DOES AND DOES NOT COVER. For text made of TABLED
# glyphs the estimate is a true upper bound, so wrapped prose and fitted cells
# really render inside the page. A glyph OUTSIDE the tables renders in some
# fallback face this page cannot know, and no constant bounds every font on
# earth: :data:`_FALLBACK_EM` is not a render bound, it is a COUNT bound — it
# charges each off-table glyph so much that only a few fit any budget, and the
# caps below (title lines, table cells, placement labels) then bound the page
# itself. So no input, in any script, can grow the page without limit; a
# fallback face wider than the charge can still paint its short run past its
# own line's end, where the viewBox clips it at the page edge.

_ADVANCES_EM = {
    " ": 0.325, "!": 0.409, "\"": 0.470, "#": 0.855, "$": 0.649, "%": 0.970,
    "&": 0.796, "'": 0.281, "(": 0.398, ")": 0.398, "*": 0.510, "+": 0.855,
    ",": 0.325, "-": 0.369, ".": 0.325, "/": 0.344, "0": 0.649, "1": 0.649,
    "2": 0.649, "3": 0.649, "4": 0.649, "5": 0.649, "6": 0.649, "7": 0.649,
    "8": 0.649, "9": 0.649, ":": 0.344, ";": 0.344, "<": 0.855, "=": 0.855,
    ">": 0.855, "?": 0.542, "@": 1.020, "A": 0.698, "B": 0.700, "C": 0.713,
    "D": 0.786, "E": 0.645, "F": 0.587, "G": 0.791, "H": 0.767, "I": 0.301,
    "J": 0.301, "K": 0.669, "L": 0.569, "M": 0.881, "N": 0.764, "O": 0.803,
    "P": 0.616, "Q": 0.803, "R": 0.709, "S": 0.648, "T": 0.624, "U": 0.747,
    "V": 0.698, "W": 1.009, "X": 0.699, "Y": 0.624, "Z": 0.699, "[": 0.398,
    "\\": 0.344, "]": 0.398, "^": 0.855, "_": 0.510, "`": 0.510, "a": 0.626,
    "b": 0.648, "c": 0.561, "d": 0.648, "e": 0.628, "f": 0.360, "g": 0.648,
    "h": 0.647, "i": 0.284, "j": 0.284, "k": 0.591, "l": 0.284, "m": 0.994,
    "n": 0.647, "o": 0.625, "p": 0.648, "q": 0.648, "r": 0.420, "s": 0.532,
    "t": 0.400, "u": 0.647, "v": 0.604, "w": 0.835, "x": 0.604, "y": 0.604,
    "z": 0.536, "{": 0.649, "|": 0.344, "}": 0.649, "~": 0.855, "°": 0.510,
    "·": 0.325, "—": 1.020, "–": 0.510, "’": 0.325, "‘": 0.325, "“": 0.529,
    "”": 0.529, "±": 0.855, "×": 0.855, "µ": 0.649, "Ω": 0.780,
}
_ADVANCES_BOLD_EM = {
    " ": 0.356, "!": 0.466, "\"": 0.532, "#": 0.855, "$": 0.710, "%": 1.022,
    "&": 0.890, "'": 0.313, "(": 0.467, ")": 0.467, "*": 0.534, "+": 0.855,
    ",": 0.388, "-": 0.424, ".": 0.388, "/": 0.373, "0": 0.710, "1": 0.710,
    "2": 0.710, "3": 0.710, "4": 0.710, "5": 0.710, "6": 0.710, "7": 0.710,
    "8": 0.710, "9": 0.710, ":": 0.408, ";": 0.408, "<": 0.855, "=": 0.855,
    ">": 0.855, "?": 0.592, "@": 1.020, "A": 0.790, "B": 0.778, "C": 0.749,
    "D": 0.847, "E": 0.697, "F": 0.697, "G": 0.838, "H": 0.854, "I": 0.380,
    "J": 0.380, "K": 0.791, "L": 0.650, "M": 1.016, "N": 0.854, "O": 0.868,
    "P": 0.748, "Q": 0.868, "R": 0.786, "S": 0.735, "T": 0.696, "U": 0.829,
    "V": 0.790, "W": 1.126, "X": 0.787, "Y": 0.739, "Z": 0.740, "[": 0.467,
    "\\": 0.373, "]": 0.467, "^": 0.855, "_": 0.510, "`": 0.510, "a": 0.689,
    "b": 0.731, "c": 0.605, "d": 0.731, "e": 0.692, "f": 0.444, "g": 0.731,
    "h": 0.727, "i": 0.350, "j": 0.350, "k": 0.679, "l": 0.350, "m": 1.063,
    "n": 0.727, "o": 0.701, "p": 0.731, "q": 0.731, "r": 0.504, "s": 0.608,
    "t": 0.488, "u": 0.727, "v": 0.665, "w": 0.943, "x": 0.658, "y": 0.665,
    "z": 0.594, "{": 0.727, "|": 0.373, "}": 0.727, "~": 0.855, "°": 0.510,
    "·": 0.388, "—": 1.020, "–": 0.510, "’": 0.388, "‘": 0.388, "“": 0.671,
    "”": 0.671, "±": 0.855, "×": 0.855, "µ": 0.751, "Ω": 0.868,
}
#: DejaVu Sans Mono advances one width for every glyph in BOTH weights
#: (0.6021 em, v2.37), padded the same way. The emitted-rows table renders in
#: the ``mono`` class, whose narrow letters are WIDER than their sans
#: advances, so mono text must never be measured with the sans tables.
_MONO_EM = 0.615
#: Charged per glyph outside the tables. Wider than every glyph DejaVu Sans
#: carries in either weight (max 2.016 em, bold) — but what actually renders
#: is some fallback face this page cannot know, so this is NOT a bound on the
#: rendered width. Its job is the count bound the block comment above
#: describes: charge off-table glyphs enough that only a few fit any budget.
_FALLBACK_EM = 2.05


def _est_text_width(body: str, size: float, *, bold: bool = False,
                    mono: bool = False) -> float:
    """A width the rendered text will not exceed, in ``size``'s own unit."""
    if mono:
        return sum(_MONO_EM if ch in _ADVANCES_EM else _FALLBACK_EM
                   for ch in str(body)) * size
    table = _ADVANCES_BOLD_EM if bold else _ADVANCES_EM
    return sum(table.get(ch, _FALLBACK_EM) for ch in str(body)) * size


def _wrap(body: str, budget: float, size: float, *, bold: bool = False
          ) -> list[str]:
    """Greedy word wrap against :func:`_est_text_width`. Words are kept whole
    while they fit — so a phrase a test greps for survives intact when it fits
    one line — but a single token wider than the whole budget is split by
    characters: no input, board names included, may run off the page."""
    def over(text: str) -> bool:
        return _est_text_width(text, size, bold=bold) > budget

    lines: list[str] = []
    line = ""
    for word in str(body).split(" "):
        candidate = word if not line else f"{line} {word}"
        if line and over(candidate):
            lines.append(line)
            line = word
        else:
            line = candidate
        # A lone over-budget token cannot be placed by word wrapping at all:
        # peel full lines off its front, one character short of the budget.
        while over(line) and len(line) > 1:
            head = line
            while len(head) > 1 and over(head):
                head = head[:-1]
            lines.append(head)
            line = line[len(head):]
    if line:
        lines.append(line)
    return lines or [""]


def _fit_text(body: str, budget: float, size: float, *, bold: bool = False,
              mono: bool = False) -> str:
    """*body* when its estimated width fits *budget*, else its head plus a
    visible "..." — a cut a reader can SEE, never a silent one. The full value
    always exists somewhere machine-readable (a data- attribute, the CSVs), so
    what the cut costs is ink, not information."""
    text = str(body)
    if _est_text_width(text, size, bold=bold, mono=mono) <= budget:
        return text
    room = budget - _est_text_width("...", size, bold=bold, mono=mono)
    run, keep = 0.0, 0
    for ch in text:
        run += _est_text_width(ch, size, bold=bold, mono=mono)
        if run > room:
            break
        keep += 1
    return text[:keep] + "..."


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


def _arc_geometry(start, mid, end):
    """One three-point arc solve: ``(center, radius, start_angle, span, sweep)``
    or ``None`` for a collinear or absurd-radius triple.

    Shared by the emitted path, the swept extent AND the perimeter sampling the
    label layout dodges, so all three describe the same circle."""
    solved = _circumcenter(start, mid, end)
    if solved is None:
        return None
    (cx, cy), d = solved
    radius = math.hypot(start[0] - cx, start[1] - cy)
    if not math.isfinite(radius) or radius > silk_source._ARC_MAX_RADIUS_MM:
        return None
    # SWEEP is read off the frame the points are already in: `d > 0` is the
    # increasing-angle turn of THIS frame, and inside the drawing group SVG's
    # own positive sweep is the same direction. No sign correction anywhere.
    sweep = 1 if d > 0 else 0
    start_angle = math.atan2(start[1] - cy, start[0] - cx)
    theta = math.atan2(end[1] - cy, end[0] - cx) - start_angle
    span = theta % (2.0 * math.pi) if sweep else (-theta) % (2.0 * math.pi)
    return (cx, cy), radius, start_angle, span, sweep


def _arc_ink(start, mid, end, *, cls: str):
    """A three-point arc as an SVG elliptical-arc path, PLUS the points its ink
    actually occupies.

    The circumcentre solver is :mod:`silk_source`'s, aliased the way
    :mod:`gerber` aliases it, so the arc a person sees here and the arc a house
    receives on the fab layers are struck from one derivation. Collinear or
    absurd-radius triples fall back to a polyline, which is what such an arc
    physically is.

    THE EXTENT IS THE SWEPT ARC, NOT THE THREE CONTROL POINTS. An arc's
    outermost ink sits where it crosses an axis through its centre, and only a
    quarter-turn arc is guaranteed to reach such a crossing at one of its own
    ends. A major arc between two nearby endpoints reaches a full radius away
    from both. Those extents feed two consumers that both go wrong quietly if
    they are short: :meth:`_Drawing.contains`, which decides whether a placement
    sits off its own body and rings it in red if so, and the page's viewBox,
    which would crop a non-rectangular board outline off the drawing. So the
    path and its extent are returned from ONE solve and cannot disagree."""
    solved = _arc_geometry(start, mid, end)
    if solved is None:
        return _polyline((start, mid, end), cls=cls, closed=False), [start, mid, end]
    (cx, cy), radius, start_angle, span, sweep = solved
    large = 1 if span > math.pi else 0
    path = (f'<path class="{cls}" d="M {_n(start[0])},{_n(start[1])} '
            f'A {_n(radius)},{_n(radius)} 0 {large} {sweep} '
            f'{_n(end[0])},{_n(end[1])}"/>')
    return path, _arc_extent_points((cx, cy), radius, start_angle, span, sweep,
                                    start, end)


def _arc_extent_points(center, radius: float, start_angle: float, span: float,
                       sweep: int, start, end):
    """The endpoints of an arc plus every axis crossing its sweep passes.

    ``span`` is the unsigned turn and ``sweep`` its direction, exactly as
    :func:`_arc_ink` emitted them, so the points below are the ones the drawn
    path covers rather than the ones the source triple happened to name."""
    cx, cy = center
    points = [start, end]
    step = 1.0 if sweep else -1.0
    for quarter in range(4):
        angle = quarter * math.pi / 2.0
        # How far along the sweep this axis direction sits. Taken modulo a full
        # turn in the sweep's own direction, so "is it on the arc" is one
        # comparison against the span rather than four angle-wrapping cases.
        travelled = (step * (angle - start_angle)) % (2.0 * math.pi)
        if travelled <= span:
            points.append((cx + radius * math.cos(angle),
                           cy + radius * math.sin(angle)))
    return points


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
    #: One axis-aligned box per LAND, kept separate from ``points`` because the
    #: label layout dodges lands specifically — a label across a body outline
    #: is legible, a label across a pad row is not.
    pad_boxes: list[tuple[float, float, float, float]] = field(default_factory=list)
    #: Thin boxes along the BODY OUTLINE'S OWN STROKE, from the same graphics
    #: the outline is drawn from. The labels dodge these; the drawing's
    #: ``bounds()`` box is NOT a substitute, because remote pads stretch it
    #: past the body and a label can then cross the real outline while sitting
    #: comfortably inside the inflated box.
    body_bands: list[tuple[float, float, float, float]] = field(default_factory=list)
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
        return _arc_ink(start, mid, end, cls=cls)
    if isinstance(geometry, (PolygonGeometry, PolylineGeometry)):
        points = [to_frame(p) for p in geometry.points]
        closed = isinstance(geometry, PolygonGeometry)
        return _polyline(points, cls=cls, closed=closed), points
    return "", []


#: Deepest a sampled chord may sag inside the true curve, in mm. The bands in
#: :func:`_ink_bands` reach ``half`` (0.12 mm) past their chord on every axis,
#: and a curve point sits within its chord's sagitta of that chord — so with
#: the sagitta capped WELL below ``half``, a band around each chord always
#: CONTAINS the real curve rather than sitting inside it. Length-proportional
#: sampling (~1 mm chords) had no such bound: a 0.64 mm-radius arc's 1 mm
#: chord sags 0.185 mm, past the band edge, leaving a strip of real outline
#: no band covered.
_CURVE_SAG_MM = 0.02


def _curve_steps(radius: float, span: float) -> int:
    """Chords that sample *span* radians of a *radius* arc with sagitta
    ``radius * (1 - cos(span / 2n))`` at most :data:`_CURVE_SAG_MM`."""
    if radius <= _CURVE_SAG_MM:
        return 4
    half_angle = math.acos(1.0 - _CURVE_SAG_MM / radius)
    return max(4, int(math.ceil(span / (2.0 * half_angle))))


def _graphic_perimeter(geometry) -> list[list[tuple[float, float]]]:
    """The polylines one placed graphic's STROKE actually follows, in the
    emitted frame — the curve itself, not its bounding extent. Circles and
    arcs come back sampled with a bounded sagitta (:func:`_curve_steps`), so
    banding the pieces is guaranteed to band the whole curve."""
    to_frame = assembly_outputs.cpl_frame_point
    if isinstance(geometry, LineGeometry):
        return [[to_frame(geometry.a), to_frame(geometry.b)]]
    if isinstance(geometry, CircleGeometry):
        cx, cy = to_frame(geometry.center)
        radius = float(geometry.radius_mm)
        steps = _curve_steps(radius, 2.0 * math.pi)
        return [[(cx + radius * math.cos(2.0 * math.pi * i / steps),
                  cy + radius * math.sin(2.0 * math.pi * i / steps))
                 for i in range(steps + 1)]]
    if isinstance(geometry, ArcGeometry):
        start = to_frame(geometry.start)
        mid = to_frame(geometry.mid)
        end = to_frame(geometry.end)
        solved = _arc_geometry(start, mid, end)
        if solved is None:
            return [[start, mid, end]]
        (cx, cy), radius, start_angle, span, sweep = solved
        step = 1.0 if sweep else -1.0
        steps = _curve_steps(radius, span)
        return [[(cx + radius * math.cos(start_angle + step * span * i / steps),
                  cy + radius * math.sin(start_angle + step * span * i / steps))
                 for i in range(steps + 1)]]
    if isinstance(geometry, (PolygonGeometry, PolylineGeometry)):
        points = [to_frame(p) for p in geometry.points]
        if isinstance(geometry, PolygonGeometry) and len(points) > 1:
            points = points + [points[0]]
        return [points] if len(points) > 1 else []
    return []


def _ink_bands(paths, half: float = 0.12
               ) -> list[tuple[float, float, float, float]]:
    """Thin boxes hugging every stroke in *paths*, so a label dodging them
    dodges the INK. Each segment is cut into ~1 mm pieces first: one box per
    piece stays tight to a diagonal stroke where the whole segment's box would
    blanket the rectangle it spans."""
    boxes: list[tuple[float, float, float, float]] = []
    for path in paths:
        for (x1, y1), (x2, y2) in zip(path, path[1:]):
            pieces = max(1, int(math.ceil(math.hypot(x2 - x1, y2 - y1))))
            for i in range(pieces):
                ax = x1 + (x2 - x1) * i / pieces
                ay = y1 + (y2 - y1) * i / pieces
                bx = x1 + (x2 - x1) * (i + 1) / pieces
                by = y1 + (y2 - y1) * (i + 1) / pieces
                boxes.append((min(ax, bx) - half, min(ay, by) - half,
                              max(ax, bx) + half, max(ay, by) + half))
    return boxes


def _outline_ink(component, cls: str):
    """The component's BODY, and which layer answered.

    Fab first, because that layer is KiCad's own assembly drawing and is what
    the anchor was measured off. Silk second, and SAID SO on the page: a silk
    outline carries a cathode bar or a pin-1 notch, so its shape is not the
    part's. Lands last, as a box, for furniture that draws no body at all."""
    for basis, role in ((OUTLINE_FAB, LayerRole.FAB), (OUTLINE_SILK, LayerRole.SILK)):
        ink: list[str] = []
        points: list[tuple[float, float]] = []
        perimeters: list[list[tuple[float, float]]] = []
        for graphic in component.placed_graphics:
            if graphic.layer.role is not role:
                continue
            fragment, extent = _graphic_ink(graphic.geometry, cls)
            if fragment:
                ink.append(fragment)
                points.extend(extent)
                perimeters.extend(_graphic_perimeter(graphic.geometry))
        if ink:
            return basis, ink, points, perimeters
    return OUTLINE_LANDS, [], [], []


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
    pad_boxes: list[tuple[float, float, float, float]] = []
    for pad in component.placed_pads:
        fragment, extent = _pad_ink(pad, pad_cls)
        if fragment:
            pad_ink.append(fragment)
            pad_points.extend(extent)
            pad_boxes.append((min(p[0] for p in extent), min(p[1] for p in extent),
                              max(p[0] for p in extent), max(p[1] for p in extent)))

    basis, body_ink, body_points, perimeters = _outline_ink(component, body_cls)
    if basis == OUTLINE_LANDS:
        box = _lands_box(pad_points, body_cls)
        if box:
            body_ink = [box]
            # The lands box IS this drawing's body stroke, so its rectangle's
            # perimeter is what the labels dodge.
            xs = [p[0] for p in pad_points]
            ys = [p[1] for p in pad_points]
            corners = [(min(xs), min(ys)), (max(xs), min(ys)),
                       (max(xs), max(ys)), (min(xs), max(ys))]
            perimeters = [corners + corners[:1]]
        else:
            basis = OUTLINE_NONE

    mark, note = pin_one(board, component)
    drawing = _Drawing(ref=component.ref, populate=populate, side=side,
                       outline_basis=basis, ink=pad_ink + body_ink,
                       points=pad_points + body_points, pad_boxes=pad_boxes,
                       body_bands=_ink_bands(perimeters),
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
# The claim: one CPL row's crosshair, and where its label can actually go.
#
# A label drawn at a fixed offset from the crosshair lands ON the lands of any
# dense footprint and on its neighbour's label wherever parts sit close — and a
# label that cannot be read does not do its job. So each label's spot is
# SEARCHED: candidate positions ring the crosshair at growing distances, and
# the first one that covers no land, no crosshair ink and no earlier label
# wins. A label pushed past its own crosshair's immediate neighbourhood gets a
# thin leader back, so it still says which cross it belongs to.
# ---------------------------------------------------------------------------

#: Em-fraction extents of a label above and below its baseline (DejaVu Sans:
#: ascent 0.928, descent 0.236 — both padded up).
LABEL_ASCENT = 0.95
LABEL_DESCENT = 0.30
#: Clearance a label keeps from the things it dodges, in board mm.
LABEL_CLEAR_MM = 0.15
#: Crosshair-to-label-edge distances tried, nearest first, in board mm.
_LABEL_GAPS_MM = (1.2, 2.2, 3.6, 5.4, 8.0)
#: Past this gap a label is visually detached from its cross and gets a leader.
_LEADER_GAP_MM = 2.2


def _overlap_area(a, b) -> float:
    """Intersection area of two (min_x, min_y, max_x, max_y) boxes."""
    width = min(a[2], b[2]) - max(a[0], b[0])
    height = min(a[3], b[3]) - max(a[1], b[1])
    return width * height if width > 0 and height > 0 else 0.0


def _mark_boxes(x: float, y: float, rotation_deg: float
                ) -> list[tuple[float, float, float, float]]:
    """The boxes a crosshair's own ink occupies: the cross arms, and the tick
    segment at its actual emitted angle. Labels must not cover either."""
    radians = math.radians(rotation_deg)
    tick_x = x + TICK_MM * math.cos(radians)
    tick_y = y + TICK_MM * math.sin(radians)
    pad = TICK_DOT_MM + 0.1
    return [
        (x - CROSS_ARM_MM, y - CROSS_ARM_MM, x + CROSS_ARM_MM, y + CROSS_ARM_MM),
        (min(x, tick_x) - pad, min(y, tick_y) - pad,
         max(x, tick_x) + pad, max(y, tick_y) + pad),
    ]


def _label_body(cells) -> str:
    """The label's text — the emitted designator, rotation and side cells,
    fitted to :data:`LABEL_MAX_MM` without ever cutting the rotation or side.

    The designator is unbounded board data; rotation and side are the two facts
    a person needs to distinguish otherwise identical placement marks.  Fit
    only the unbounded field into the space left by that fixed suffix.  Fitting
    the combined string used to let a long reference erase both facts.
    """
    suffix = f"  {cells[4]}°  {cells[3]}"
    suffix_width = _est_text_width(suffix, REF_TEXT_MM, bold=True)
    ref = _fit_text(str(cells[0]), max(0.0, LABEL_MAX_MM - suffix_width),
                    REF_TEXT_MM, bold=True)
    return ref + suffix


def _label_plan(x: float, y: float, body: str, obstacles
                ) -> tuple[float, float, str, tuple, bool]:
    """Where one label goes: ``(baseline_x, baseline_y, anchor, box, leader)``.

    Candidates ring the crosshair — east, west, above, below, then the four
    diagonals — at each gap tier in turn, so the nearest readable spot wins.
    When no candidate is clear of every obstacle, the least-covered one is
    taken: a label overlapping a little is still better than a label always
    drawn on top of the pad row it started this search to escape."""
    width = _est_text_width(body, REF_TEXT_MM, bold=True)
    ascent = REF_TEXT_MM * LABEL_ASCENT
    descent = REF_TEXT_MM * LABEL_DESCENT

    def box_for(bx: float, by: float, anchor: str):
        left = (bx - width if anchor == "end"
                else bx - width / 2.0 if anchor == "middle" else bx)
        return (left, by - descent, left + width, by + ascent)

    best = None
    for gap in _LABEL_GAPS_MM:
        centred_y = y - REF_TEXT_MM * 0.35
        above_y = y + gap + descent
        below_y = y - gap - ascent
        candidates = (
            (x + gap, centred_y, "start"),   # east
            (x - gap, centred_y, "end"),     # west
            (x, above_y, "middle"),          # above (this frame's +y is up)
            (x, below_y, "middle"),          # below
            (x + gap, above_y, "start"),     # north-east
            (x - gap, above_y, "end"),       # north-west
            (x + gap, below_y, "start"),     # south-east
            (x - gap, below_y, "end"),       # south-west
        )
        for bx, by, anchor in candidates:
            box = box_for(bx, by, anchor)
            padded = (box[0] - LABEL_CLEAR_MM, box[1] - LABEL_CLEAR_MM,
                      box[2] + LABEL_CLEAR_MM, box[3] + LABEL_CLEAR_MM)
            score = sum(_overlap_area(padded, obstacle) for obstacle in obstacles)
            if score == 0.0:
                return bx, by, anchor, box, gap > _LEADER_GAP_MM
            if best is None or score < best[0]:
                best = (score, gap, bx, by, anchor, box)
    _, gap, bx, by, anchor, box = best
    return bx, by, anchor, box, gap > _LEADER_GAP_MM


def _mark(row, cells, drawing, basis: str, label_plan
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
    label_x, label_y, anchor, label_box, leader = label_plan
    if leader:
        # The nearest point of the label box, so the line is as short as the
        # search left it.
        near_x = min(max(x, label_box[0]), label_box[2])
        near_y = min(max(y, label_box[1]), label_box[3])
        ink.append(f'<path class="label-leader" d="M {_n(x)},{_n(y)} '
                   f'L {_n(near_x)},{_n(near_y)}"/>')
    ink.append(_text(label_x, label_y, _label_body(cells),
                     cls=f"{cls}-label", size_mm=REF_TEXT_MM, anchor=anchor))
    points.extend([(label_box[0], label_box[1]), (label_box[2], label_box[3])])
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
  .label-leader { fill: none; stroke: #d99b82; stroke-width: 0.07; }
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
    """The statement for a drawing that carries SEVERAL parts where a placement
    inherited the ONE anchor measured off the whole drawing.

    Nothing refuses that shape and nothing advises on it: the anchors WERE
    measured, they are the right distance apart, and every gate passes — the
    DCR's own worked example shipped that way and would have centred both socket
    rows between themselves. This page is the first place it can be seen, so it
    says out loud which parts to look at, and it stays a SENTENCE rather than a
    check because the boundary here is deliberately a person.

    A PARTIALLY authored expansion gets its OWN sentence naming the placements
    that inherited. Writing the anchor for one strip of a two-strip socket and
    forgetting the other is likelier than forgetting both, and it is quieter:
    the remaining placement keeps the parent's whole-body centre, which usually
    sits on the drawing and so draws no off-body ring either."""
    out: list[str] = []
    for component in board.components:
        places = component.physical_placements
        if len(places) < 2:
            continue
        inherited = [item.ref for item in places
                     if item.anchor_basis != ANCHOR_BASIS_AUTHORED]
        if not inherited:
            continue
        if len(inherited) == len(places):
            out.append(
                f"{', '.join(inherited)} — one drawing, "
                f"{len(places)} parts, and every anchor was measured off the WHOLE "
                f"drawing rather than stated per placement. Check each crosshair "
                f"sits on the part it names and not between them; "
                f"assembly.placements[].anchor_mm is how a placement states its own")
        else:
            out.append(
                f"{', '.join(inherited)} — one drawing, {len(places)} parts, and "
                f"a SIBLING placement on it states its own anchor_mm while "
                f"{'this one' if len(inherited) == 1 else 'these'} did not: the "
                f"anchor here is still the one measured off the WHOLE drawing. "
                f"Check each crosshair sits on the part it names")
    return out


def _column_widths(rows, cells_by_ref, columns) -> list[float]:
    """Column widths: the layout minimums, grown to fit the widest heading or
    cell actually in the column. A long designator therefore widens its column
    — and through the returned table width, the page — instead of running
    under its neighbour or off the page edge. The growth is bounded because
    :func:`_table` fits every heading and cell to :data:`TABLE_CELL_MAX_PX`
    before handing them here."""
    count = max([len(columns)] + [len(cells_by_ref[row.ref]) for row in rows])
    widths = [TABLE_COLUMN_PX[i] if i < len(TABLE_COLUMN_PX) else 80.0
              for i in range(count)]
    gap = 14.0  # clear space before the next column's text
    for i, heading in enumerate(columns):
        widths[i] = max(widths[i],
                        _est_text_width(heading, 12.0, bold=True) + gap)
    for row in rows:
        for i, cell in enumerate(cells_by_ref[row.ref]):
            widths[i] = max(widths[i],
                            _est_text_width(cell, 12.0, mono=True) + gap)
    return widths


def _table(rows, cells_by_ref, off_body_refs, columns, x: float, y: float
           ) -> tuple[list[str], float, float]:
    """The emitted CPL rows, as text, beside the picture: ``(ink, cursor,
    width)``, where ``width`` is what the page must reserve for the table.

    Present because the house's quote page shows a parsed table of the same
    rows, and comparing two tables is a check a person can actually complete —
    comparing a table against a drawing is not."""
    if not rows:
        return ([f'<text class="prose" x="{_n(x)}" y="{_n(y)}">no placements: '
                 f'every part on this board is marked not-populated</text>'],
                y + TABLE_LINE_PX, 0.0)
    ink: list[str] = []
    # Headings and cells are profile/board data of unbounded length; each is
    # fitted to the cell cap FIRST, so the widths below can grow a column to
    # the widest text that will actually be drawn, and no further.
    columns = [_fit_text(heading, TABLE_CELL_MAX_PX, 12.0, bold=True)
               for heading in columns]
    cells_by_ref = {ref: [_fit_text(cell, TABLE_CELL_MAX_PX, 12.0, mono=True)
                          for cell in cells]
                    for ref, cells in cells_by_ref.items()}
    widths = _column_widths(rows, cells_by_ref, columns)
    per_column = len(rows) if len(rows) <= TABLE_SPLIT_ROWS else (len(rows) + 1) // 2
    block_width = sum(widths) + TABLE_GUTTER_PX
    blocks = 1
    for index, row in enumerate(rows):
        column, line = divmod(index, per_column)
        blocks = max(blocks, column + 1)
        left = x + column * block_width
        top = y + (line + 1) * TABLE_LINE_PX
        if line == 0:
            for offset, heading in zip(_column_offsets(widths), columns):
                ink.append(f'<text class="cell-head" x="{_n(left + offset)}" '
                           f'y="{_n(y)}">{_esc(heading)}</text>')
            ink.append(f'<path class="rule" d="M {_n(left)},{_n(y + 4)} '
                       f'h {_n(sum(widths))}"/>')
        cls = "cell-off" if row.ref in off_body_refs else "cell"
        for offset, cell in zip(_column_offsets(widths), cells_by_ref[row.ref]):
            ink.append(f'<text class="{cls} mono" x="{_n(left + offset)}" '
                       f'y="{_n(top)}">{_esc(cell)}</text>')
    return ink, y + (per_column + 1) * TABLE_LINE_PX, block_width * blocks


def _column_offsets(widths):
    offset = 0.0
    for width in widths:
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
    # What every label must dodge: every land on the page, every drawn body
    # outline's OWN STROKE (its bounds() box is inflated by remote pads and
    # says nothing about where the outline actually runs), every crosshair's
    # ink (its neighbours' and its own), and each label already placed.
    pad_obstacles = [box for drawing in drawings for box in drawing.pad_boxes]
    for drawing in drawings:
        pad_obstacles.extend(drawing.body_bands)
    cross_obstacles = [box for row in emission.cpl
                       for box in _mark_boxes(float(row.x_mm), float(row.y_mm),
                                              float(row.rotation_deg))]
    placed_labels: list[tuple[float, float, float, float]] = []

    claim_ink: list[str] = []
    points: list[tuple[float, float]] = []
    off_body_refs: set[str] = set()
    for row in emission.cpl:
        plan = _label_plan(float(row.x_mm), float(row.y_mm),
                           _label_body(cells_by_ref[row.ref]),
                           pad_obstacles + cross_obstacles + placed_labels)
        placed_labels.append(plan[3])
        ink, extent, off_body = _mark(row, cells_by_ref[row.ref],
                                      by_ref.get(row.ref),
                                      basis_by_ref.get(row.ref, ""), plan)
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
    # The board NAME is board data, so the title wraps like the prose does —
    # a long name becomes more title lines, never ink past the page edge —
    # and the LINES are capped with a visible "..." so no name, however long,
    # grows the page without limit.
    title_lines = _wrap(f"{board.name} — assembly preview",
                        PROSE_BUDGET_PX, 17.0, bold=True)
    if len(title_lines) > TITLE_MAX_LINES:
        title_lines = title_lines[:TITLE_MAX_LINES]
        title_lines[-1] = _fit_text(title_lines[-1] + "...",
                                    PROSE_BUDGET_PX, 17.0, bold=True)
    for index, wrapped in enumerate(title_lines):
        if index:
            cursor += 22.0
        body.append(f'<text class="title" x="{_n(PAGE_PAD_PX)}" '
                    f'y="{_n(cursor)}">{_esc(wrapped)}</text>')
    cursor += HEADER_LINE_PX + 4.0
    # Prose is wrapped to the page's guaranteed MINIMUM content width, so no
    # header sentence can run past the right edge of any page this file emits.
    for cls, line in header:
        for wrapped in _wrap(line, PROSE_BUDGET_PX, 12.0,
                             bold=cls == "prose-strong"):
            body.append(f'<text class="{cls}" x="{_n(PAGE_PAD_PX)}" '
                        f'y="{_n(cursor)}">{_esc(wrapped)}</text>')
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
    # One group per DRAWING, the machine-readable half the placement groups
    # already have. A drawing and a placement are not the same thing — an
    # expansion is several placements over one drawing — so a reader (and a
    # test) has to be able to count each without inferring one from the other.
    for drawing in drawings:
        body.append(f'<g class="drawing" data-ref="{_esc(drawing.ref)}" '
                    f'data-outline-basis="{_esc(drawing.outline_basis)}">')
        body.extend(drawing.ink)
        body.append("</g>")
    body.extend(claim_ink)
    body.append("</g>")
    cursor += draw_h + 24.0

    notes = _notes(drawings) + _expansion_notes(board)
    if notes:
        body.append(f'<text class="cell-head" x="{_n(PAGE_PAD_PX)}" '
                    f'y="{_n(cursor)}">What this drawing does not claim</text>')
        cursor += HEADER_LINE_PX
        # Notes carry ref lists of unbounded length, so they wrap like the
        # header does — to the width every page is guaranteed to have.
        for note in notes:
            for wrapped in _wrap(note, PROSE_BUDGET_PX, 12.0):
                body.append(f'<text class="prose" x="{_n(PAGE_PAD_PX)}" '
                            f'y="{_n(cursor)}">{_esc(wrapped)}</text>')
                cursor += HEADER_LINE_PX
        cursor += 12.0

    body.append(f'<text class="cell-head" x="{_n(PAGE_PAD_PX)}" y="{_n(cursor)}">'
                f'The rows as emitted — compare these against the house\'s parsed '
                f'table</text>')
    cursor += HEADER_LINE_PX + 6.0
    table, cursor, table_width = _table(emission.cpl, cells_by_ref,
                                        off_body_refs, profile.cpl_columns,
                                        PAGE_PAD_PX, cursor)
    body.extend(table)

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
