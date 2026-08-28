"""The board stroke font, and the parity of its GDScript mirror.

The font is the in-house 5x7 stroke alphabet EVERY string on a board is drawn
with (pcb_worker/board_font.py) — legend lines and reference designators alike.
It is the only glyph table in this repository; see board_font's module
docstring for why there is exactly one.

WHAT THE MIRROR TEST IS FOR. The panel cannot import Python, so the glyph table
is mirrored into ui/model/pcb_board_font_data.gd by
scripts/gen_board_font_gd.py. If the two ever drift, the editor draws one shape
and the fab receives another — a WYSIWYG lie that no other check in this repo
would catch, because each side is internally consistent. So the mirror is
compared here glyph-for-glyph, number-for-number, rather than trusted.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

from pcb_worker import board_font

GD_MIRROR = Path(__file__).resolve().parents[2] / "ui" / "model" / "pcb_board_font_data.gd"

_PRINTABLE_ASCII = [chr(c) for c in range(0x20, 0x7F)]


def test_covers_every_printable_ascii_character():
    """95 printable ASCII characters, none missing.

    The negative control for every other assertion here: a font that quietly
    lacked lowercase would still render "MINERVA V2" and still pass a
    "does it draw something" check, which is exactly how the refdes font's
    uppercase-folding went unnoticed as a limitation.
    """
    missing = [c for c in _PRINTABLE_ASCII if c not in board_font.GLYPHS]
    assert missing == [], f"printable ASCII characters with no glyph: {missing!r}"
    # The box is extra, and deliberately not a printable character.
    assert board_font.MISSING_GLYPH_CHAR in board_font.GLYPHS
    assert board_font.MISSING_GLYPH_CHAR not in _PRINTABLE_ASCII
    assert len(board_font.GLYPHS) == 96


def test_every_glyph_is_well_formed():
    """Every stroke has >= 2 points and stays inside the authored 5x7 grid.

    A one-point stroke draws NOTHING (draw_polyline and the Gerber path both
    need two), so it is a glyph that silently loses a feature — an "i" with no
    dot. An out-of-grid point is a typo that shifts one character relative to
    its neighbours.
    """
    for char, (advance, strokes) in board_font.GLYPHS.items():
        assert advance >= 1, f"{char!r} has advance {advance}"
        for index, stroke in enumerate(strokes):
            assert len(stroke) >= 2, f"{char!r} stroke {index} has {len(stroke)} point(s)"
            for gx, gy in stroke:
                assert 0 <= gx <= 4, f"{char!r} stroke {index}: x={gx} outside 0..4"
                assert 0 <= gy <= 8, f"{char!r} stroke {index}: y={gy} outside 0..8"


def test_size_is_cap_height():
    """`size` means CAP HEIGHT, exactly: an "M" at size 1.5 is 1.5 mm tall.

    Pinned because it is the one number a caller reasons about, and because a
    font whose size meant em-box or x-height would be silently 30-40% off in a
    way that only shows up on the fabricated board.
    """
    rendered = board_font.render("M", size=1.5)
    min_y = min(y for stroke in rendered.polylines for _x, y in stroke)
    max_y = max(y for stroke in rendered.polylines for _x, y in stroke)
    assert max_y == pytest.approx(0.0), "baseline must sit at y=0"
    assert min_y == pytest.approx(-1.5), "cap height must equal size"


def test_scale_is_linear_and_width_agrees_with_render():
    """text_width() is the same number render() lays out to, at any size.

    The font this one replaced shipped a double-scaling bug in exactly this
    relationship (its space advance was scaled twice, so render() and
    text_width() disagreed for any size != 1.0), so the discriminating fixture
    here is a string WITH A SPACE at a size != 1.0.
    """
    for size in (0.5, 1.0, 1.5, 2.0):
        rendered = board_font.render("R1 C2", size=size)
        laid_out = max(x for stroke in rendered.polylines for x, _y in stroke)
        assert rendered.width_mm == pytest.approx(board_font.text_width("R1 C2", size))
        # The advance includes the last glyph's right side bearing, so the drawn
        # extent is <= the advance but must scale with it.
        assert laid_out <= rendered.width_mm + 1e-9
        assert rendered.width_mm == pytest.approx(
            board_font.text_width("R1 C2", 1.0) * size)


def test_unknown_glyphs_render_a_box_and_are_reported():
    """A character with no glyph draws a BOX and is named in `missing`.

    Two halves, and both matter. Dropping it would shorten the legend without
    saying so; drawing "?" would be a lie the reader cannot detect, because "?"
    is itself a legitimate character this font has.
    """
    rendered = board_font.render("AµB☃", size=1.0)
    assert rendered.missing == ("µ", "☃")
    # Four characters were asked for and four were laid out — nothing dropped.
    assert rendered.width_mm == pytest.approx(board_font.text_width("AµB☃", 1.0))
    box_advance, box_strokes = board_font.GLYPHS[board_font.MISSING_GLYPH_CHAR]
    assert len(box_strokes) == 1 and len(box_strokes[0]) == 5, "the box is one closed rectangle"
    # "?" is a REAL glyph, so it must not be the fallback.
    assert board_font.GLYPHS["?"] != board_font.GLYPHS[board_font.MISSING_GLYPH_CHAR]


def test_mirror_reflects_about_the_anchor_not_the_origin():
    """Mirroring is X-reflection about the text's OWN anchor (local x=0).

    The distinction is the whole feature. Reflecting about the BOARD origin
    would move a label at x=10 to x=-10 — off most boards entirely — while
    reflecting about the anchor keeps the text where it was asked for and only
    changes which way it reads.
    """
    upright = board_font.render("Minerva v2", size=1.5)
    mirrored = board_font.render("Minerva v2", size=1.5, mirror=True)
    assert upright.width_mm == pytest.approx(11.5)
    assert upright.bounds[0] == pytest.approx(0.0)
    assert upright.bounds[2] == pytest.approx(11.5)
    assert mirrored.bounds[0] == pytest.approx(-11.5)
    assert mirrored.bounds[2] == pytest.approx(0.0)
    # Point-for-point, not merely extent-for-extent.
    assert len(mirrored.polylines) == len(upright.polylines)
    for up, mir in zip(upright.polylines, mirrored.polylines):
        assert [( -x, y) for x, y in up] == list(mir)
    # Negative control: a symmetric string would satisfy the extents above by
    # accident, so state what the mirror must NOT be.
    assert mirrored.polylines != upright.polylines


def test_centred_text_mirrors_in_place():
    """With h_align="center" the mirror leaves the bounding box where it was.

    This is the alignment a back-side label usually wants: the glyphs reverse,
    the block of text does not slide to the other side of its anchor.
    """
    upright = board_font.render("Minerva v2", size=1.5, h_align="center")
    mirrored = board_font.render("Minerva v2", size=1.5, h_align="center", mirror=True)
    assert mirrored.bounds[0] == pytest.approx(upright.bounds[0])
    assert mirrored.bounds[2] == pytest.approx(upright.bounds[2])
    assert mirrored.polylines != upright.polylines


def test_render_refuses_a_nonpositive_size():
    for bad in (0, -1.0):
        with pytest.raises(ValueError):
            board_font.render("A", size=bad)
    with pytest.raises(ValueError):
        board_font.render("A", h_align="right")


def _parse_gd_mirror() -> dict:
    """The GLYPHS literal out of the generated .gd file.

    The generator emits a body that is BOTH valid GDScript and valid JSON
    precisely so this can be an exact parse rather than a regex approximation of
    one.
    """
    text = GD_MIRROR.read_text(encoding="utf-8")
    marker = "const GLYPHS := "
    start = text.index(marker) + len(marker)
    body = text[start:].strip()
    # GDScript allows a trailing comma before the closing brace; JSON does not.
    body = re.sub(r",(\s*})", r"\1", body)
    return json.loads(body)


def test_gdscript_mirror_is_identical():
    """The generated GD table equals the Python table, value for value.

    THE FAILURE THIS CATCHES is silent and expensive: the panel derives its
    preview strokes from the GD table and the compiler derives the fabricated
    strokes from the Python one, so a drifted mirror means the editor shows a
    legend the board will not carry. Nothing else would notice — each side is
    internally consistent.

    Regenerate with `python3 pcb/scripts/gen_board_font_gd.py` when the font
    changes; never hand-edit the .gd file.
    """
    mirror = _parse_gd_mirror()
    assert set(mirror) == set(board_font.GLYPHS), (
        "glyph sets differ — regenerate pcb/ui/model/pcb_board_font_data.gd")
    for char, (advance, strokes) in board_font.GLYPHS.items():
        expected = [advance, [[list(pt) for pt in stroke] for stroke in strokes]]
        assert mirror[char] == expected, f"glyph {char!r} differs from the Python table"


def test_gdscript_mirror_carries_the_layout_constants():
    """The mirror's UNIT / BASELINE_ROW / SPACE_ADVANCE / GLYPH_GAP match too.

    The glyph table alone is not the contract: identical glyphs laid out with a
    different gap or baseline still produce different artwork, and that is the
    subtler half of the same drift.
    """
    text = GD_MIRROR.read_text(encoding="utf-8")
    for name, value in (("UNIT", board_font.UNIT),
                        ("BASELINE_ROW", board_font.BASELINE_ROW),
                        ("SPACE_ADVANCE", board_font.SPACE_ADVANCE),
                        ("GLYPH_GAP", board_font.GLYPH_GAP)):
        match = re.search(rf"^const {name} := (.+)$", text, re.M)
        assert match, f"the GD mirror declares no {name}"
        assert float(match.group(1)) == pytest.approx(float(value)), \
            f"{name} differs from the Python table"
