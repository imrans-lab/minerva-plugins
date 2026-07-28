"""A minimal single-stroke ("Newstroke"/Hershey-family) vector font, subset to
the characters a KiCad reference designator actually uses: ``A-Z``, ``0-9``,
plus a ``?`` fallback glyph for anything outside that set.

Why this exists
----------------
Gerber silk is DRAWN GEOMETRY — RS-274X (and the pinned ``gerber-writer``
0.4.3.3 writer this worker uses) has no text/font/glyph primitive at all
(confirmed: ``gerber_writer`` ships only ``writer.py`` / ``macros.py`` /
``padmasters.py`` / ``lutils.py``). Putting a reference designator like "R1" on
F.SilkS therefore means emitting the character strokes as polylines, the same
way KiCad itself draws its own default silkscreen text.

Where the glyph data comes from
--------------------------------
KiCad's own default PCB text font is "Newstroke", a single-stroke vector font
KiCad ships as ``newstroke_font.cpp``. This worker does NOT depend on KiCad or
parse that C++ file. Instead, the ``_GLYPHS`` table below is a SUBSET of the
same font, extracted (offline, at authoring time — not at import time or test
time) from ``gerbonara==1.6.3``'s ``gerbonara/newstroke.py`` + its bundled
``gerbonara/data/newstroke_font.cpp``. gerbonara is this repo's dev-only
fabrication-verification dependency (pyproject.toml ``[project.optional-
dependencies].dev`` — "not a runtime dependency, no FCIB"); this module does
NOT import gerbonara, at runtime or otherwise. It only reproduces a small,
literal, unrotated subset of the glyph coordinate data as a citation-carrying
constant, the same way ``newstroke_font.cpp`` itself is just numbers.

Extraction recipe (reproducible, not run automatically)::

    from gerbonara.newstroke import Newstroke
    ns = Newstroke.load()
    width, strokes = ns.glyphs['A']   # -> (0.857143, ((...), (...)))

Each glyph is ``(advance_width, strokes)`` where ``strokes`` is a tuple of
point-tuples (an OPEN polyline each — never implicitly closed). Coordinates are
already in gerbonara's normalised font units (``STROKE_FONT_SCALE = 1/21``,
``FONT_OFFSET = -10``) — the same Y-DOWN convention this worker uses
end-to-end for board/footprint coordinates (see ``geometry.py``'s module
docstring: KiCad's file frame grows Y downward, and this codebase carries that
convention through unflipped). A size of 1.0 renders a nominal ~1mm cap height
with proportions matching KiCad's own default text size (1mm / 1mm, matched
here to ``gerber.SILK_LINE_WIDTH_MM`` for the stroke width, same as the
existing F.Fab designator precedent in kicad.py).

This module renders GLYPH-LOCAL, UNROTATED polylines only. Placing the result
on the board (translation + KiCad clockwise rotation) is the caller's job, via
``geometry.place_point`` — exactly as every other footprint-local primitive in
this worker is placed. Rotation is deliberately NOT a parameter here: baking a
rotation into two different places (font render + board transform) is how a
sign error hides.
"""

from __future__ import annotations

# Default advance width between two space characters, in font units at size=1.0
# (gerbonara's own DEFAULT_SPACE_WIDTH — cited, not imported).
SPACE_WIDTH = 0.6

# (advance_width, strokes) per character. strokes is a tuple of OPEN polylines
# (tuples of (x, y) point-tuples); no polyline here is implicitly closed.
# Subset of KiCad's Newstroke font: A-Z, 0-9, '?' (fallback glyph for any
# character outside that set — a reference designator is always upper-alpha +
# digits, but this keeps the renderer total rather than raising).
_GLYPHS: dict[str, tuple[float, tuple[tuple[tuple[float, float], ...], ...]]] = {
    'A': (0.857143, (((0.190476, -0.333333), (0.666667, -0.333333)), ((0.095238, -0.047619), (0.428571, -1.047619), (0.761905, -0.047619)),)),
    'B': (1.0, (((0.571429, -0.571429), (0.714286, -0.52381), (0.761905, -0.47619), (0.809524, -0.380952), (0.809524, -0.238095), (0.761905, -0.142857), (0.714286, -0.095238), (0.619048, -0.047619), (0.238095, -0.047619), (0.238095, -1.047619), (0.571429, -1.047619), (0.666667, -1.0), (0.714286, -0.952381), (0.761905, -0.857143), (0.761905, -0.761905), (0.714286, -0.666667), (0.666667, -0.619048), (0.571429, -0.571429), (0.238095, -0.571429)),)),
    'C': (1.0, (((0.809524, -0.142857), (0.761905, -0.095238), (0.619048, -0.047619), (0.52381, -0.047619), (0.380952, -0.095238), (0.285714, -0.190476), (0.238095, -0.285714), (0.190476, -0.47619), (0.190476, -0.619048), (0.238095, -0.809524), (0.285714, -0.904762), (0.380952, -1.0), (0.52381, -1.047619), (0.619048, -1.047619), (0.761905, -1.0), (0.809524, -0.952381)),)),
    'D': (1.0, (((0.238095, -0.047619), (0.238095, -1.047619), (0.47619, -1.047619), (0.619048, -1.0), (0.714286, -0.904762), (0.761905, -0.809524), (0.809524, -0.619048), (0.809524, -0.47619), (0.761905, -0.285714), (0.714286, -0.190476), (0.619048, -0.095238), (0.47619, -0.047619), (0.238095, -0.047619)),)),
    'E': (0.904762, (((0.238095, -0.571429), (0.571429, -0.571429)), ((0.714286, -0.047619), (0.238095, -0.047619), (0.238095, -1.047619), (0.714286, -1.047619)),)),
    'F': (0.857143, (((0.571429, -0.571429), (0.238095, -0.571429)), ((0.238095, -0.047619), (0.238095, -1.047619), (0.714286, -1.047619)),)),
    'G': (1.0, (((0.761905, -1.0), (0.666667, -1.047619), (0.52381, -1.047619), (0.380952, -1.0), (0.285714, -0.904762), (0.238095, -0.809524), (0.190476, -0.619048), (0.190476, -0.47619), (0.238095, -0.285714), (0.285714, -0.190476), (0.380952, -0.095238), (0.52381, -0.047619), (0.619048, -0.047619), (0.761905, -0.095238), (0.809524, -0.142857), (0.809524, -0.47619), (0.619048, -0.47619)),)),
    'H': (1.047619, (((0.238095, -0.047619), (0.238095, -1.047619)), ((0.238095, -0.571429), (0.809524, -0.571429)), ((0.809524, -0.047619), (0.809524, -1.047619)),)),
    'I': (0.47619, (((0.238095, -0.047619), (0.238095, -1.047619)),)),
    'J': (0.761905, (((0.52381, -1.047619), (0.52381, -0.333333), (0.47619, -0.190476), (0.380952, -0.095238), (0.238095, -0.047619), (0.142857, -0.047619)),)),
    'K': (1.0, (((0.238095, -0.047619), (0.238095, -1.047619)), ((0.809524, -0.047619), (0.380952, -0.619048)), ((0.809524, -1.047619), (0.238095, -0.47619)),)),
    'L': (0.809524, (((0.714286, -0.047619), (0.238095, -0.047619), (0.238095, -1.047619)),)),
    'M': (1.142857, (((0.238095, -0.047619), (0.238095, -1.047619), (0.571429, -0.333333), (0.904762, -1.047619), (0.904762, -0.047619)),)),
    'N': (1.047619, (((0.238095, -0.047619), (0.238095, -1.047619), (0.809524, -0.047619), (0.809524, -1.047619)),)),
    'O': (1.047619, (((0.428571, -1.047619), (0.619048, -1.047619), (0.714286, -1.0), (0.809524, -0.904762), (0.857143, -0.714286), (0.857143, -0.380952), (0.809524, -0.190476), (0.714286, -0.095238), (0.619048, -0.047619), (0.428571, -0.047619), (0.333333, -0.095238), (0.238095, -0.190476), (0.190476, -0.380952), (0.190476, -0.714286), (0.238095, -0.904762), (0.333333, -1.0), (0.428571, -1.047619)),)),
    'P': (1.0, (((0.238095, -0.047619), (0.238095, -1.047619), (0.619048, -1.047619), (0.714286, -1.0), (0.761905, -0.952381), (0.809524, -0.857143), (0.809524, -0.714286), (0.761905, -0.619048), (0.714286, -0.571429), (0.619048, -0.52381), (0.238095, -0.52381)),)),
    'Q': (1.047619, (((0.904762, 0.047619), (0.809524, 0.0), (0.714286, -0.095238), (0.571429, -0.238095), (0.47619, -0.285714), (0.380952, -0.285714)), ((0.428571, -0.047619), (0.333333, -0.095238), (0.238095, -0.190476), (0.190476, -0.380952), (0.190476, -0.714286), (0.238095, -0.904762), (0.333333, -1.0), (0.428571, -1.047619), (0.619048, -1.047619), (0.714286, -1.0), (0.809524, -0.904762), (0.857143, -0.714286), (0.857143, -0.380952), (0.809524, -0.190476), (0.714286, -0.095238), (0.619048, -0.047619), (0.428571, -0.047619)),)),
    'R': (1.0, (((0.809524, -0.047619), (0.47619, -0.52381)), ((0.238095, -0.047619), (0.238095, -1.047619), (0.619048, -1.047619), (0.714286, -1.0), (0.761905, -0.952381), (0.809524, -0.857143), (0.809524, -0.714286), (0.761905, -0.619048), (0.714286, -0.571429), (0.619048, -0.52381), (0.238095, -0.52381)),)),
    'S': (0.952381, (((0.190476, -0.095238), (0.333333, -0.047619), (0.571429, -0.047619), (0.666667, -0.095238), (0.714286, -0.142857), (0.761905, -0.238095), (0.761905, -0.333333), (0.714286, -0.428571), (0.666667, -0.47619), (0.571429, -0.52381), (0.380952, -0.571429), (0.285714, -0.619048), (0.238095, -0.666667), (0.190476, -0.761905), (0.190476, -0.857143), (0.238095, -0.952381), (0.285714, -1.0), (0.380952, -1.047619), (0.619048, -1.047619), (0.761905, -1.0)),)),
    'T': (0.761905, (((0.095238, -1.047619), (0.666667, -1.047619)), ((0.380952, -0.047619), (0.380952, -1.047619)),)),
    'U': (1.047619, (((0.238095, -1.047619), (0.238095, -0.238095), (0.285714, -0.142857), (0.333333, -0.095238), (0.428571, -0.047619), (0.619048, -0.047619), (0.714286, -0.095238), (0.761905, -0.142857), (0.809524, -0.238095), (0.809524, -1.047619)),)),
    'V': (0.857143, (((0.095238, -1.047619), (0.428571, -0.047619), (0.761905, -1.047619)),)),
    'W': (1.142857, (((0.142857, -1.047619), (0.380952, -0.047619), (0.571429, -0.761905), (0.761905, -0.047619), (1.0, -1.047619)),)),
    'X': (0.952381, (((0.142857, -1.047619), (0.809524, -0.047619)), ((0.809524, -1.047619), (0.142857, -0.047619)),)),
    'Y': (0.857143, (((0.428571, -0.52381), (0.428571, -0.047619)), ((0.095238, -1.047619), (0.428571, -0.52381), (0.761905, -1.047619)),)),
    'Z': (0.952381, (((0.142857, -1.047619), (0.809524, -1.047619), (0.142857, -0.047619), (0.809524, -0.047619)),)),
    '0': (0.952381, (((0.428571, -1.047619), (0.52381, -1.047619), (0.619048, -1.0), (0.666667, -0.952381), (0.714286, -0.857143), (0.761905, -0.666667), (0.761905, -0.428571), (0.714286, -0.238095), (0.666667, -0.142857), (0.619048, -0.095238), (0.52381, -0.047619), (0.428571, -0.047619), (0.333333, -0.095238), (0.285714, -0.142857), (0.238095, -0.238095), (0.190476, -0.428571), (0.190476, -0.666667), (0.238095, -0.857143), (0.285714, -0.952381), (0.333333, -1.0), (0.428571, -1.047619)),)),
    '1': (0.952381, (((0.761905, -0.047619), (0.190476, -0.047619)), ((0.47619, -0.047619), (0.47619, -1.047619), (0.380952, -0.904762), (0.285714, -0.809524), (0.190476, -0.761905)),)),
    '2': (0.952381, (((0.190476, -0.952381), (0.238095, -1.0), (0.333333, -1.047619), (0.571429, -1.047619), (0.666667, -1.0), (0.714286, -0.952381), (0.761905, -0.857143), (0.761905, -0.761905), (0.714286, -0.619048), (0.142857, -0.047619), (0.761905, -0.047619)),)),
    '3': (0.952381, (((0.142857, -1.047619), (0.761905, -1.047619), (0.428571, -0.666667), (0.571429, -0.666667), (0.666667, -0.619048), (0.714286, -0.571429), (0.761905, -0.47619), (0.761905, -0.238095), (0.714286, -0.142857), (0.666667, -0.095238), (0.571429, -0.047619), (0.285714, -0.047619), (0.190476, -0.095238), (0.142857, -0.142857)),)),
    '4': (0.952381, (((0.666667, -0.714286), (0.666667, -0.047619)), ((0.428571, -1.095238), (0.190476, -0.380952), (0.809524, -0.380952)),)),
    '5': (0.952381, (((0.714286, -1.047619), (0.238095, -1.047619), (0.190476, -0.571429), (0.238095, -0.619048), (0.333333, -0.666667), (0.571429, -0.666667), (0.666667, -0.619048), (0.714286, -0.571429), (0.761905, -0.47619), (0.761905, -0.238095), (0.714286, -0.142857), (0.666667, -0.095238), (0.571429, -0.047619), (0.333333, -0.047619), (0.238095, -0.095238), (0.190476, -0.142857)),)),
    '6': (0.952381, (((0.666667, -1.047619), (0.47619, -1.047619), (0.380952, -1.0), (0.333333, -0.952381), (0.238095, -0.809524), (0.190476, -0.619048), (0.190476, -0.238095), (0.238095, -0.142857), (0.285714, -0.095238), (0.380952, -0.047619), (0.571429, -0.047619), (0.666667, -0.095238), (0.714286, -0.142857), (0.761905, -0.238095), (0.761905, -0.47619), (0.714286, -0.571429), (0.666667, -0.619048), (0.571429, -0.666667), (0.380952, -0.666667), (0.285714, -0.619048), (0.238095, -0.571429), (0.190476, -0.47619)),)),
    '7': (0.952381, (((0.142857, -1.047619), (0.809524, -1.047619), (0.380952, -0.047619)),)),
    '8': (0.952381, (((0.380952, -0.619048), (0.285714, -0.666667), (0.238095, -0.714286), (0.190476, -0.809524), (0.190476, -0.857143), (0.238095, -0.952381), (0.285714, -1.0), (0.380952, -1.047619), (0.571429, -1.047619), (0.666667, -1.0), (0.714286, -0.952381), (0.761905, -0.857143), (0.761905, -0.809524), (0.714286, -0.714286), (0.666667, -0.666667), (0.571429, -0.619048), (0.380952, -0.619048), (0.285714, -0.571429), (0.238095, -0.52381), (0.190476, -0.428571), (0.190476, -0.238095), (0.238095, -0.142857), (0.285714, -0.095238), (0.380952, -0.047619), (0.571429, -0.047619), (0.666667, -0.095238), (0.714286, -0.142857), (0.761905, -0.238095), (0.761905, -0.428571), (0.714286, -0.52381), (0.666667, -0.571429), (0.571429, -0.619048)),)),
    '9': (0.952381, (((0.285714, -0.047619), (0.47619, -0.047619), (0.571429, -0.095238), (0.619048, -0.142857), (0.714286, -0.285714), (0.761905, -0.47619), (0.761905, -0.857143), (0.714286, -0.952381), (0.666667, -1.0), (0.571429, -1.047619), (0.380952, -1.047619), (0.285714, -1.0), (0.238095, -0.952381), (0.190476, -0.857143), (0.190476, -0.619048), (0.238095, -0.52381), (0.285714, -0.47619), (0.380952, -0.428571), (0.571429, -0.428571), (0.666667, -0.47619), (0.714286, -0.52381), (0.761905, -0.619048)),)),
    '?': (0.857143, (((0.380952, -0.142857), (0.428571, -0.095238), (0.380952, -0.047619), (0.333333, -0.095238), (0.380952, -0.142857), (0.380952, -0.047619)), ((0.190476, -1.0), (0.285714, -1.047619), (0.52381, -1.047619), (0.619048, -1.0), (0.666667, -0.904762), (0.666667, -0.809524), (0.619048, -0.714286), (0.571429, -0.666667), (0.47619, -0.619048), (0.428571, -0.571429), (0.380952, -0.47619), (0.380952, -0.428571)),)),
}

_MISSING_GLYPH = _GLYPHS['?']


def _glyph(c: str) -> tuple[float, tuple[tuple[tuple[float, float], ...], ...]]:
    return _GLYPHS.get(c.upper(), _MISSING_GLYPH)


def text_width(text: str, size: float = 1.0) -> float:
    """Total advance width of *text* rendered at *size*, in the same units
    :func:`render` places its points in (mm, when size is in mm)."""
    x = 0.0
    for c in text:
        if c == " ":
            x += SPACE_WIDTH * size
            continue
        width, strokes = _glyph(c)
        glyph_w = max(width, max((px for st in strokes for px, _py in st), default=0.0))
        x += glyph_w * size
    return x


def render(text: str, size: float = 1.0, x0: float = 0.0, y0: float = 0.0,
          h_align: str = "center") -> list[list[tuple[float, float]]]:
    """Render *text* as a list of OPEN polylines (each a list of (x, y) point
    tuples) in glyph-LOCAL, UNROTATED space, anchored at (*x0*, *y0*).

    ``h_align``: "left" anchors the first glyph's origin at x0; "center"
    (default) centers the full string's advance width on x0. Vertical
    placement is always baseline-relative (matches the font data: a
    character's lowest stroke point sits near y=0 in glyph-local units before
    the *y0* offset).

    Rotation is NOT applied here — callers transform the returned points with
    the board's own placement transform (``geometry.place_point``), so there
    is exactly one rotation implementation for board geometry (DRY, same
    reasoning as geometry.py's module docstring for pads/silk).
    """
    if h_align not in ("left", "center"):
        raise ValueError(f"unsupported h_align {h_align!r}")

    align_dx = -text_width(text, size) / 2.0 if h_align == "center" else 0.0

    polylines: list[list[tuple[float, float]]] = []
    x = 0.0
    for c in text:
        if c == " ":
            # x accumulates in GLYPH-LOCAL (unscaled) units here, exactly like
            # the regular-glyph branch below (`x += glyph_w`, no `* size`) —
            # every point is scaled ONCE, at emit time: `(px + x) * size`.
            # Scaling the advance here too would double-scale it (SPACE_WIDTH
            # * size accumulated, then multiplied by size again below), which
            # silently breaks scale-linearity and disagreement with
            # text_width() for any size != 1.0 and any string containing a
            # space. See render()'s docstring / stroke_font tests for the
            # discriminating fixture ("R1 C2" at size=2.0).
            x += SPACE_WIDTH
            continue
        width, strokes = _glyph(c)
        glyph_w = width
        for st in strokes:
            polylines.append([
                ((px + x) * size + align_dx + x0, py * size + y0)
                for px, py in st
            ])
            glyph_w = max(glyph_w, max(px for px, _py in st))
        x += glyph_w
    return polylines
