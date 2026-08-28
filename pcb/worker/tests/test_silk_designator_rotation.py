"""Authored reference-text ROTATION, hand-derived.

WHY A HAND-DERIVED CASE EXISTS AT ALL
-------------------------------------
019f77fd6d69's MEASURED gap (C7a brief, STEP 1) was: the pipeline SYNTHESIZES
the reference-designator stroke text from the component's ref string at a
fixed default local offset (``gerber.REFDES_LOCAL_Y_MM``), never reading the
footprint's OWN authored ``fp_text reference`` placement — so a footprint
whose designator field is positioned or ROTATED away from KiCad's generic
default renders in the wrong place. The fix (``footprints.py``
``_parse_reference_text`` / ``_is_captured_reference_fp_text``,
``footprint_def.ReferenceTextDefinition``, ``gerber._emit_refdes``'s new
``reference_text`` parameter) is proven for the POSITION half by a seal
against a real footprint
(``test_silk_text.py::test_ir_native_path_positions_designator_at_the_real_component_placement``,
against ``MountingHole_3.2mm_M3``, whose authored ``(at 0 -4.2)`` has no
rotation).

No footprint in the seed library authors a ROTATED reference fp_text (every
``fp_text reference`` in ``pcb/library/footprints`` omits the 3rd ``(at x y
ROT)`` token, i.e. rotation 0 — verified by grep across the seed lockfile's
``.pretty`` dirs). The two-step nested transform ``_emit_refdes`` applies
(text-local rotate-then-translate to the footprint's authored anchor, via
``place_point``, THEN the component's own placement transform) is therefore
UNEXERCISED by any real fixture for its rotation half. This file is that
missing case: a SYNTHETIC ``ReferenceTextDefinition`` with a nonzero
``rotation_deg``, hand-derived through KiCad's own clockwise convention (never
through the code under test), for the SIMPLEST glyph in the font so the
arithmetic below can be checked by hand rather than trusted.

HAND DERIVATION (do not re-derive a whole font — one glyph only)
-----------------------------------------------------------------
The glyph is ``'|'``: the only single-stroke, two-point glyph in
``board_font.GLYPHS`` that spans the full cap height, which makes both the
rotation and the baseline visible in two numbers. It is not a plausible
reference designator, and that is fine — ``_emit_refdes`` renders whatever ref
string it is handed, and a one-stroke glyph is what keeps this derivation
short enough to check.

``board_font.GLYPHS['|'] == (1, (((1, 0), (1, 6)),))`` — advance 1 grid unit,
ink at grid x=1 (a full unit of left bearing), from the cap row (y=0) to the
baseline row (y=6). ``UNIT = 1/6``, so at ``size=1.0`` the scale is 1/6 mm per
grid unit and ``text_width("|", 1.0) = 1 * 1/6 = 1/6`` (a lone glyph adds no
``GLYPH_GAP``). ``h_align="center"`` — what ``silk_source.refdes_strokes``
asks for — gives ``align_dx = -text_width / 2 = -1/12``, and each point is
``((gx + 0) * 1/6 + align_dx, (gy - 6) * 1/6)``:

  P1 = (1/6 - 1/12, (0 - 6)/6) = ( 1/12, -1.0)
  P2 = (1/6 - 1/12, (6 - 6)/6) = ( 1/12,  0.0)

i.e. the baseline sits at local y=0 and the capital rises 1.0 mm ABOVE it in
the Y-DOWN board frame — the font's definition of ``size``.

``reference_text = ReferenceTextDefinition(position=(2.0, -1.0),
rotation_deg=90.0, size_mm=1.0)`` — a synthetic footprint's designator sits
2mm right, 1mm up (Y-down convention: -1.0 is up) of the footprint origin,
and is itself rotated 90 degrees clockwise (a designator drawn sideways,
matching e.g. a connector authored with its text along the long edge).

``geometry.rotate_local_offset(px, py, deg)`` uses KiCad's own convention
(``radians(-deg)``, pinned by ``tests/test_rotation.py``); at deg=90 that
reduces EXACTLY to ``(px, py) -> (py, -px)`` (cos(-90)=0, sin(-90)=-1):

  rotate(P1, 90) = (-1.0, -1/12)
  rotate(P2, 90) = ( 0.0, -1/12)

Translate by ``reference_text.position`` (2.0, -1.0) -- this is
``place_point(2.0, -1.0, 90.0, *P)``, the FIRST of ``_emit_refdes``'s two
composed steps (see its docstring):

  fp_local(P1) = (-1.0 + 2.0, -1/12 - 1.0) = (1.0, -13/12)
  fp_local(P2) = ( 0.0 + 2.0, -1/12 - 1.0) = (2.0, -13/12)

The component sits at ``(10.0, 5.0)`` with ``rotation_deg=0.0`` (identity —
isolates the text-local rotation from any component-level rotation, so a
failure here can only be the NEW inner step, not the pre-existing outer one
already proven by the seal named above). The SECOND composed step,
``place_point(10.0, 5.0, 0.0, *fp_local)``, is identity-plus-translate:

  abs(P1) = (1.0 + 10.0, -13/12 + 5.0) = (11.0, 47/12)
  abs(P2) = (2.0 + 10.0, -13/12 + 5.0) = (12.0, 47/12)

``47/12 == 3.9166666666666665``.

These are BOARD-frame (Y-down) points -- ``_emit_refdes`` writes directly to
``_Geometry.silk_polys`` in that frame (the gerber-frame Y-flip is
``_Geometry.to_gerber_frame``, applied later by the harvest entry points, not
by ``_emit_refdes`` itself). Calling
``gerber._emit_refdes`` directly (same pattern ``test_silk_text.py`` already
uses for its unit-level cases) keeps this test at the ``_Geometry`` boundary,
so no frame flip applies.
"""

from __future__ import annotations

import pytest

from pcb_worker import gerber
from pcb_worker.footprint_def import ReferenceTextDefinition

# THE SAME TOLERANCE AND THE SAME COMPARISON SHAPE AS ``test_silk_text._TOL``
# (1e-9), and for the same stated reason: these coordinates come out of one
# font render plus one affine placement, so the only difference a correct
# implementation can show is IEEE-754 rounding mode — 1e-9 is ~7 orders of
# magnitude looser than double epsilon at O(1)-O(10) magnitudes.
#
# THE TRAP THIS HELPER EXISTS TO AVOID, which is why the comparison is written
# out per coordinate rather than as ``pts == pytest.approx([(x, y), ...])``:
# ``pytest.approx`` does NOT recurse into a nested sequence. Given a list of
# TUPLES it wraps each tuple in ``ApproxScalar``, whose ``__eq__`` returns False
# for a non-numeric actual — so the tolerance is silently discarded and the
# assertion degrades to EXACT tuple equality. That is what made this test red
# once already: the two sides agreed to ~1e-15 and the `abs=1e-6` in the source
# was doing nothing at all. pytest even prints "Mismatched elements: 0 / 2"
# while failing, which is the tell. It matters here again — the second point's
# y comes out as 3.916666666666667 against a hand-derived 47/12 that rounds to
# 3.9166666666666665.
_TOL = 1e-9


def _assert_points(got, want) -> None:
    assert len(got) == len(want), (got, want)
    for (gx, gy), (wx, wy) in zip(got, want):
        assert gx == pytest.approx(wx, abs=_TOL), (got, want)
        assert gy == pytest.approx(wy, abs=_TOL), (got, want)


def test_emit_refdes_honors_authored_reference_text_rotation():
    reference_text = ReferenceTextDefinition(
        position=(2.0, -1.0), rotation_deg=90.0, size_mm=1.0,
    )
    g = gerber._Geometry()
    gerber._emit_refdes(g, "|", 10.0, 5.0, 0.0, top=True, reference_text=reference_text)

    text_polys = [pts for (pts, width, closed) in g.silk_polys
                  if width == gerber.SILK_TEXT_WIDTH_MM]
    assert len(text_polys) == 1, "the '|' glyph is exactly one open stroke"
    pts = text_polys[0]
    _assert_points(pts, [(11.0, 47 / 12), (12.0, 47 / 12)])


def test_emit_refdes_falls_back_to_default_when_reference_text_is_absent():
    """The GUARD case: a footprint with no captured reference_text (the
    pre-019f77fd6d69 default) must render EXACTLY as before this unit —
    proving the new parameter is additive, not a silent behavior change for
    every footprint. Uses the SAME (cx, cy, rot) as the rotated case above so
    the two tests are otherwise comparable."""
    from pcb_worker.geometry import place_point
    from pcb_worker import board_font

    g = gerber._Geometry()
    gerber._emit_refdes(g, "|", 10.0, 5.0, 0.0, top=True, reference_text=None)

    expected_local = [
        (lx, ly + gerber.REFDES_LOCAL_Y_MM)
        for (lx, ly) in board_font.render(
            "|", size=gerber.REFDES_TEXT_SIZE_MM, h_align="center").polylines[0]
    ]
    expected = [place_point(10.0, 5.0, 0.0, lx, ly) for (lx, ly) in expected_local]

    text_polys = [pts for (pts, width, closed) in g.silk_polys
                  if width == gerber.SILK_TEXT_WIDTH_MM]
    assert len(text_polys) == 1
    # Same helper as the rotated case above — this line carried the identical
    # nested-approx trap and was passing only because both sides happened to be
    # bit-identical, i.e. it was an exact comparison wearing a tolerance.
    _assert_points(text_polys[0], expected)
