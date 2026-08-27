"""The Minerva 5x7 board-text stroke font — printable ASCII, authored in-house.

WHY A SECOND FONT EXISTS, when ``stroke_font.py`` is right there
-----------------------------------------------------------------
Two independent reasons, and either one alone would be enough:

1. COVERAGE. ``stroke_font.py`` carries 26 glyphs — ``A-Z``, ``0-9`` and a ``?``
   fallback — because a reference designator ("R1", "U3") never needs more. Board
   text does: a copyright line needs lowercase, a comma, a period and a digit in
   the same string. Folding lowercase to uppercase (what ``stroke_font._glyph``
   does) is correct for a designator and wrong for a legend.

2. LICENCE. ``stroke_font.py``'s glyph data is a subset of KiCad's Newstroke,
   whose source file ``newstroke_font.cpp`` carries a **GPL-2.0-or-later** header
   (Copyright (C) 2010 vladimir uryvaev; Copyright (C) 1992-2019 KiCad
   Developers). This repository ships under a proprietary licence
   (``LICENSE.md``). Widening an embedded GPL-2 glyph table from 26 characters to
   95 deepens an exposure that should be shrinking, so this font does not extend
   Newstroke — it replaces nothing and borrows nothing.

   Every coordinate below was authored for this file against a 5x7 stroke grid.
   No glyph data was copied, converted or traced from Newstroke, Hershey, or any
   other font. It is deliberately plain: a 5x7 stroke alphabet is the "Courier of
   vector fonts", the shape you get from the grid rather than from a designer,
   and that is exactly what makes it safe to author from scratch.

   The pre-existing Newstroke exposure in ``stroke_font.py`` is NOT fixed here —
   see docs/tools.md. Unifying both surfaces on this font would fix it and give
   the board one typeface instead of two, at the cost of moving every committed
   refdes Gerber golden. That is its own change with its own bless.

THE GRID
--------
Glyphs are authored on INTEGER grid coordinates and scaled once, at render time,
so the data stays readable and diffable (a float table is neither).

    x: 0 .. 4     left to right
    y: 0 .. 8     top to bottom  —  board Y is DOWN, so is this
       y = 0      cap height / ascender top
       y = 2      x-height top (lowercase bodies start here)
       y = 6      BASELINE
       y = 8      descender bottom (g j p q y and the comma tail)

``UNIT = 1/6`` converts grid to mm at ``size=1.0``, which makes CAP HEIGHT the
definition of ``size``: text rendered at ``size_mm=1.5`` has 1.5 mm capitals.
That is the same thing ``stroke_font.REFDES_TEXT_SIZE_MM = 1.0`` means for a
designator, so the two fonts agree on what a size number denotes even though
they disagree on shape.

Baseline lands at y=0 in OUTPUT coordinates (``(gy - 6) * UNIT``), so a rendered
string sits ON its anchor rather than hanging below it.

WHAT THIS MODULE DOES NOT DO
----------------------------
It does not rotate and it does not translate. ``render`` returns glyph-LOCAL
polylines anchored at the origin, exactly as ``stroke_font.render`` does, and for
the identical reason quoted in that module: board geometry has ONE rotation
implementation (``geometry.place_point``), and baking a second one into a font
is how a sign error hides. Callers place the result.

It DOES mirror, because mirroring is a TEXT-LAYOUT decision, not a placement one:
back-side legend is mirror-written about the text's own anchor so it reads
correctly once the board is flipped. See ``render``'s ``mirror`` argument and the
"Back-side text" section of docs/board-yaml.md.

Its GDScript mirror is ``pcb/ui/model/pcb_board_font_data.gd``, generated from
this file by ``pcb/scripts/gen_board_font_gd.py`` and pinned value-for-value by
``worker/tests/test_board_font.py::test_gdscript_mirror_is_identical``. Same
arrangement, same reason, as ``worker/agent_router/layers.py`` and
``ui/model/pcb_layer_stack.gd``: two languages, one authored table.
"""
from __future__ import annotations

from dataclasses import dataclass

__all__ = [
    "UNIT", "CAP_ROWS", "BASELINE_ROW", "SPACE_ADVANCE", "GLYPH_GAP",
    "MISSING_GLYPH_CHAR", "GLYPHS", "RenderedText", "render", "text_width",
]

#: Grid-to-mm scale at ``size=1.0``. Six rows from cap top to baseline, so a
#: capital is exactly 1.0 mm tall at size 1.0.
UNIT = 1.0 / 6.0
#: Rows from cap top (y=0) to baseline (y=6).
CAP_ROWS = 6
#: The grid row output coordinates are measured from.
BASELINE_ROW = 6
#: Advance of a space, in grid units.
SPACE_ADVANCE = 4
#: Extra gap inserted between adjacent glyphs, in grid units. Kept OUT of the
#: per-glyph advance so a glyph's advance means "how wide this shape is", which
#: is what makes the table readable.
GLYPH_GAP = 1
#: The key under which the unknown-glyph box lives. It is deliberately not a
#: printable character: a caller that asks for a literal box gets one, and no
#: real character can be shadowed by the fallback.
MISSING_GLYPH_CHAR = "�"

# --- The table -------------------------------------------------------------
# ``char -> (advance_in_grid_units, strokes)``; each stroke is an OPEN polyline
# of >= 2 grid points. OPEN matters: a closing segment turns "C" into "O", the
# same trap stroke_font.refdes_strokes documents.
#
# Advance is the glyph's own body width; GLYPH_GAP is added between glyphs by
# render(), never here.
GLYPHS: dict[str, tuple[int, tuple[tuple[tuple[int, int], ...], ...]]] = {
    " ": (SPACE_ADVANCE, ()),
    "!": (1, (((1, 0), (1, 4)), ((1, 5), (1, 6)))),
    '"': (4, (((1, 0), (1, 2)), ((3, 0), (3, 2)))),
    "#": (4, (((1, 1), (0, 6)), ((3, 1), (2, 6)), ((0, 2), (4, 2)), ((0, 4), (4, 4)))),
    "$": (4, (((2, 0), (2, 6)),
              ((4, 2), (3, 1), (1, 1), (0, 2), (1, 3), (3, 3), (4, 4), (3, 5), (1, 5), (0, 4)))),
    "%": (4, (((0, 0), (1, 0), (1, 1), (0, 1), (0, 0)),
              ((4, 0), (0, 6)),
              ((3, 5), (4, 5), (4, 6), (3, 6), (3, 5)))),
    "&": (4, (((4, 6), (1, 1), (2, 0), (3, 1), (3, 2), (0, 4), (0, 5), (1, 6), (3, 6), (4, 4)),)),
    "'": (1, (((1, 0), (1, 2)),)),
    "(": (2, (((2, 0), (1, 1), (1, 5), (2, 6)),)),
    ")": (2, (((0, 0), (1, 1), (1, 5), (0, 6)),)),
    "*": (4, (((2, 1), (2, 5)), ((0, 2), (4, 4)), ((4, 2), (0, 4)))),
    "+": (4, (((2, 1), (2, 5)), ((0, 3), (4, 3)))),
    ",": (2, (((2, 5), (2, 6), (1, 7)),)),
    "-": (4, (((0, 3), (4, 3)),)),
    ".": (1, (((1, 5), (1, 6)),)),
    "/": (4, (((4, 0), (0, 6)),)),
    "0": (4, (((1, 0), (3, 0), (4, 1), (4, 5), (3, 6), (1, 6), (0, 5), (0, 1), (1, 0)),
              ((1, 5), (3, 1)))),
    "1": (4, (((1, 1), (2, 0), (2, 6)), ((0, 6), (4, 6)))),
    "2": (4, (((0, 1), (1, 0), (3, 0), (4, 1), (4, 2), (0, 6), (4, 6)),)),
    "3": (4, (((0, 0), (4, 0), (2, 2)),
              ((1, 2), (3, 2), (4, 3), (4, 5), (3, 6), (1, 6), (0, 5)))),
    "4": (4, (((3, 6), (3, 0), (0, 4), (4, 4)),)),
    "5": (4, (((4, 0), (0, 0), (0, 2), (3, 2), (4, 3), (4, 5), (3, 6), (1, 6), (0, 5)),)),
    "6": (4, (((4, 1), (3, 0), (1, 0), (0, 1), (0, 5), (1, 6), (3, 6), (4, 5), (4, 4),
               (3, 3), (1, 3), (0, 4)),)),
    "7": (4, (((0, 0), (4, 0), (1, 6)),)),
    "8": (4, (((1, 3), (0, 2), (0, 1), (1, 0), (3, 0), (4, 1), (4, 2), (3, 3), (1, 3),
               (0, 4), (0, 5), (1, 6), (3, 6), (4, 5), (4, 4), (3, 3)),)),
    "9": (4, (((0, 5), (1, 6), (3, 6), (4, 5), (4, 1), (3, 0), (1, 0), (0, 1), (0, 2),
               (1, 3), (3, 3), (4, 2)),)),
    ":": (1, (((1, 2), (1, 3)), ((1, 5), (1, 6)))),
    ";": (2, (((2, 2), (2, 3)), ((2, 5), (2, 6), (1, 7)))),
    "<": (3, (((3, 1), (0, 3), (3, 5)),)),
    "=": (4, (((0, 2), (4, 2)), ((0, 4), (4, 4)))),
    ">": (3, (((0, 1), (3, 3), (0, 5)),)),
    "?": (4, (((0, 1), (1, 0), (3, 0), (4, 1), (4, 2), (2, 3), (2, 4)), ((2, 5), (2, 6)))),
    "@": (4, (((3, 4), (2, 3), (1, 4), (2, 5), (3, 5), (3, 3)),
              ((3, 4), (4, 3), (4, 1), (3, 0), (1, 0), (0, 1), (0, 5), (1, 6), (3, 6)))),
    "A": (4, (((0, 6), (2, 0), (4, 6)), ((1, 4), (3, 4)))),
    "B": (4, (((0, 6), (0, 0), (3, 0), (4, 1), (4, 2), (3, 3), (0, 3)),
              ((3, 3), (4, 4), (4, 5), (3, 6), (0, 6)))),
    "C": (4, (((4, 1), (3, 0), (1, 0), (0, 1), (0, 5), (1, 6), (3, 6), (4, 5)),)),
    "D": (4, (((0, 6), (0, 0), (3, 0), (4, 1), (4, 5), (3, 6), (0, 6)),)),
    "E": (4, (((4, 0), (0, 0), (0, 6), (4, 6)), ((0, 3), (3, 3)))),
    "F": (4, (((4, 0), (0, 0), (0, 6)), ((0, 3), (3, 3)))),
    "G": (4, (((4, 1), (3, 0), (1, 0), (0, 1), (0, 5), (1, 6), (3, 6), (4, 5), (4, 3), (2, 3)),)),
    "H": (4, (((0, 0), (0, 6)), ((4, 0), (4, 6)), ((0, 3), (4, 3)))),
    "I": (2, (((0, 0), (2, 0)), ((1, 0), (1, 6)), ((0, 6), (2, 6)))),
    "J": (4, (((3, 0), (3, 5), (2, 6), (1, 6), (0, 5)),)),
    "K": (4, (((0, 0), (0, 6)), ((4, 0), (1, 3), (4, 6)))),
    "L": (4, (((0, 0), (0, 6), (4, 6)),)),
    "M": (4, (((0, 6), (0, 0), (2, 2), (4, 0), (4, 6)),)),
    "N": (4, (((0, 6), (0, 0), (4, 6), (4, 0)),)),
    "O": (4, (((1, 0), (3, 0), (4, 1), (4, 5), (3, 6), (1, 6), (0, 5), (0, 1), (1, 0)),)),
    "P": (4, (((0, 6), (0, 0), (3, 0), (4, 1), (4, 2), (3, 3), (0, 3)),)),
    "Q": (4, (((1, 0), (3, 0), (4, 1), (4, 5), (3, 6), (1, 6), (0, 5), (0, 1), (1, 0)),
              ((2, 4), (4, 6)))),
    "R": (4, (((0, 6), (0, 0), (3, 0), (4, 1), (4, 2), (3, 3), (0, 3)), ((2, 3), (4, 6)))),
    "S": (4, (((4, 1), (3, 0), (1, 0), (0, 1), (0, 2), (1, 3), (3, 3), (4, 4), (4, 5),
               (3, 6), (1, 6), (0, 5)),)),
    "T": (4, (((0, 0), (4, 0)), ((2, 0), (2, 6)))),
    "U": (4, (((0, 0), (0, 5), (1, 6), (3, 6), (4, 5), (4, 0)),)),
    "V": (4, (((0, 0), (2, 6), (4, 0)),)),
    "W": (4, (((0, 0), (1, 6), (2, 3), (3, 6), (4, 0)),)),
    "X": (4, (((0, 0), (4, 6)), ((4, 0), (0, 6)))),
    "Y": (4, (((0, 0), (2, 3), (4, 0)), ((2, 3), (2, 6)))),
    "Z": (4, (((0, 0), (4, 0), (0, 6), (4, 6)),)),
    "[": (2, (((2, 0), (1, 0), (1, 6), (2, 6)),)),
    "\\": (4, (((0, 0), (4, 6)),)),
    "]": (2, (((0, 0), (1, 0), (1, 6), (0, 6)),)),
    "^": (4, (((0, 2), (2, 0), (4, 2)),)),
    "_": (4, (((0, 7), (4, 7)),)),
    "`": (2, (((1, 0), (2, 1)),)),
    "a": (4, (((0, 3), (1, 2), (3, 2), (4, 3), (4, 6)),
              ((4, 5), (3, 4), (1, 4), (0, 5), (1, 6), (3, 6), (4, 5)))),
    "b": (4, (((0, 0), (0, 6)), ((0, 5), (1, 6), (3, 6), (4, 5), (4, 3), (3, 2), (1, 2), (0, 3)))),
    "c": (4, (((4, 3), (3, 2), (1, 2), (0, 3), (0, 5), (1, 6), (3, 6), (4, 5)),)),
    "d": (4, (((4, 0), (4, 6)), ((4, 3), (3, 2), (1, 2), (0, 3), (0, 5), (1, 6), (3, 6), (4, 5)))),
    "e": (4, (((0, 4), (4, 4), (4, 3), (3, 2), (1, 2), (0, 3), (0, 5), (1, 6), (3, 6), (4, 5)),)),
    "f": (3, (((3, 1), (2, 0), (1, 1), (1, 6)), ((0, 2), (3, 2)))),
    "g": (4, (((4, 2), (4, 7), (3, 8), (1, 8), (0, 7)),
              ((4, 3), (3, 2), (1, 2), (0, 3), (0, 5), (1, 6), (3, 6), (4, 5)))),
    "h": (4, (((0, 0), (0, 6)), ((0, 3), (1, 2), (3, 2), (4, 3), (4, 6)))),
    "i": (1, (((1, 0), (1, 1)), ((1, 2), (1, 6)))),
    "j": (3, (((3, 0), (3, 1)), ((3, 2), (3, 7), (2, 8), (1, 8), (0, 7)))),
    "k": (4, (((0, 0), (0, 6)), ((4, 2), (1, 4), (4, 6)), ((0, 4), (1, 4)))),
    "l": (2, (((1, 0), (1, 5), (2, 6)),)),
    "m": (4, (((0, 6), (0, 2)), ((0, 3), (1, 2), (2, 3), (2, 6)), ((2, 3), (3, 2), (4, 3), (4, 6)))),
    "n": (4, (((0, 6), (0, 2)), ((0, 3), (1, 2), (3, 2), (4, 3), (4, 6)))),
    "o": (4, (((1, 2), (3, 2), (4, 3), (4, 5), (3, 6), (1, 6), (0, 5), (0, 3), (1, 2)),)),
    "p": (4, (((0, 2), (0, 8)),
              ((0, 3), (1, 2), (3, 2), (4, 3), (4, 5), (3, 6), (1, 6), (0, 5)))),
    "q": (4, (((4, 2), (4, 8)),
              ((4, 3), (3, 2), (1, 2), (0, 3), (0, 5), (1, 6), (3, 6), (4, 5)))),
    "r": (4, (((0, 6), (0, 2)), ((0, 3), (1, 2), (3, 2)))),
    "s": (4, (((4, 3), (3, 2), (1, 2), (0, 3), (1, 4), (3, 4), (4, 5), (3, 6), (1, 6), (0, 5)),)),
    "t": (3, (((1, 0), (1, 5), (2, 6), (3, 5)), ((0, 2), (3, 2)))),
    "u": (4, (((0, 2), (0, 5), (1, 6), (3, 6), (4, 5)), ((4, 2), (4, 6)))),
    "v": (4, (((0, 2), (2, 6), (4, 2)),)),
    "w": (4, (((0, 2), (1, 6), (2, 4), (3, 6), (4, 2)),)),
    "x": (4, (((0, 2), (4, 6)), ((4, 2), (0, 6)))),
    "y": (4, (((0, 2), (0, 5), (1, 6), (3, 6), (4, 5)), ((4, 2), (4, 7), (3, 8), (1, 8)))),
    "z": (4, (((0, 2), (4, 2), (0, 6), (4, 6)),)),
    "{": (3, (((3, 0), (2, 1), (2, 2), (1, 3), (2, 4), (2, 5), (3, 6)),)),
    "|": (1, (((1, 0), (1, 6)),)),
    "}": (3, (((1, 0), (2, 1), (2, 2), (3, 3), (2, 4), (2, 5), (1, 6)),)),
    "~": (4, (((0, 4), (1, 3), (3, 4), (4, 3)),)),
    # The unknown-glyph box. A BOX, not "?": a question mark is a legitimate
    # character, so drawing one for a glyph we do not have is a lie the reader
    # cannot detect. A box is unmistakably "missing", which is the whole point.
    MISSING_GLYPH_CHAR: (4, (((0, 0), (4, 0), (4, 6), (0, 6), (0, 0)),)),
}


@dataclass(frozen=True)
class RenderedText:
    """One rendered string in glyph-LOCAL mm, anchored at the origin.

    ``polylines`` are OPEN stroke paths, baseline at y=0 and the anchor at x=0
    (``h_align="left"``) or the string centred on x=0 (``h_align="center"``).
    The caller applies rotation and translation.

    ``missing`` lists the characters that had no glyph and were drawn as a box,
    IN INPUT ORDER, deduplicated. It is the reply field the authoring verbs
    surface so "why is my legend full of boxes" is answerable without a rerun.
    """
    polylines: tuple[tuple[tuple[float, float], ...], ...]
    missing: tuple[str, ...]
    width_mm: float
    #: Local bounds (min_x, min_y, max_x, max_y) of the drawn strokes. Empty
    #: text yields a zero box at the origin rather than an inverted one.
    bounds: tuple[float, float, float, float]


def _advance(char: str) -> int:
    entry = GLYPHS.get(char)
    return GLYPHS[MISSING_GLYPH_CHAR][0] if entry is None else entry[0]


def text_width(text: str, size: float = 1.0) -> float:
    """Advance width of *text* at *size*, in mm — the same number
    :func:`render` puts in ``RenderedText.width_mm``.

    Grid units accumulate as INTEGERS and are scaled exactly once at the end.
    Scaling per glyph and summing would drift, and would disagree with render()
    for any size where UNIT * size is not exactly representable.
    """
    if not text:
        return 0.0
    units = sum(_advance(c) for c in text) + GLYPH_GAP * (len(text) - 1)
    return units * UNIT * size


def render(text: str, size: float = 1.0, *, mirror: bool = False,
           h_align: str = "left") -> RenderedText:
    """Render *text* to glyph-local stroke polylines.

    ``size`` is CAP HEIGHT in mm (a capital is exactly ``size`` tall).

    ``mirror`` X-reflects the whole string about its own anchor — this is what
    back-side (B.SilkS) legend takes, and the reflection is about the ANCHOR,
    never about the board origin, so mirroring does not MOVE the text. See
    docs/board-yaml.md "Back-side text" for the convention and the fixture
    numbers that pin it.

    The mirror is applied in the text's LOCAL frame, before any rotation the
    caller applies. That ordering is what makes a rotated back-side label behave
    like KiCad's ``(effects (justify mirror))``: the glyphs read correctly and
    the label still points the way the rotation asked for.

    Unknown characters render as a box and are reported in ``missing`` — they
    are never silently dropped, because a dropped character shortens a legend
    without saying so.
    """
    if h_align not in ("left", "center"):
        raise ValueError(f"unsupported h_align {h_align!r}")
    if not (isinstance(size, (int, float)) and not isinstance(size, bool) and size > 0):
        raise ValueError(f"size must be a positive number, got {size!r}")

    scale = UNIT * size
    width = text_width(text, size)
    align_dx = -width / 2.0 if h_align == "center" else 0.0

    polylines: list[tuple[tuple[float, float], ...]] = []
    missing: list[str] = []
    pen = 0  # grid units, integer
    for char in text:
        entry = GLYPHS.get(char)
        if entry is None:
            entry = GLYPHS[MISSING_GLYPH_CHAR]
            if char not in missing:
                missing.append(char)
        advance, strokes = entry
        for stroke in strokes:
            polylines.append(tuple(
                ((gx + pen) * scale + align_dx, (gy - BASELINE_ROW) * scale)
                for gx, gy in stroke
            ))
        pen += advance + GLYPH_GAP

    if mirror:
        # Reflect about the anchor (local x=0). For h_align="center" the anchor
        # is the string's own centre, so a centred label mirrors in place; for
        # "left" the anchor is the left edge, so the string flips to the other
        # side of it — which is what "reads correctly from the back" means when
        # the caller gave a left-anchored position.
        polylines = [tuple((-x, y) for x, y in stroke) for stroke in polylines]

    if polylines:
        xs = [x for stroke in polylines for x, _ in stroke]
        ys = [y for stroke in polylines for _, y in stroke]
        bounds = (min(xs), min(ys), max(xs), max(ys))
    else:
        bounds = (0.0, 0.0, 0.0, 0.0)

    return RenderedText(polylines=tuple(polylines), missing=tuple(missing),
                        width_mm=width, bounds=bounds)
