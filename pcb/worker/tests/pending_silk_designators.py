"""PARKED — authored reference-text ROTATION, hand-derived (epoch C, unit C7a).

NOT COLLECTED. The filename has no ``test_`` prefix, and ``pyproject.toml``
sets ``testpaths = ["tests"]`` with no ``python_files`` override, so pytest's
default ``test_*.py`` / ``*_test.py`` patterns never see this file — locally
or in ``.github/workflows/pcb.yml``, which runs the same ``python -m pytest
tests/ -q``. It is authored now and EXECUTED at the epoch boundary, when it is
renamed to ``test_silk_designator_rotation.py``. Until then it must stay
``py_compile``-clean, which is the only gate it is held to.

WHY THIS IS PARKED, NOT AN EXECUTABLE SEAL
-------------------------------------------
019f77fd6d69's MEASURED gap (C7a brief, STEP 1) was: the pipeline SYNTHESIZES
the reference-designator stroke text from the component's ref string at a
fixed default local offset (``gerber.REFDES_LOCAL_Y_MM``), never reading the
footprint's OWN authored ``fp_text reference`` placement — so a footprint
whose designator field is positioned or ROTATED away from KiCad's generic
default renders in the wrong place. The fix (``footprints.py``
``_parse_reference_text`` / ``_is_captured_reference_fp_text``,
``footprint_def.ReferenceTextDefinition``, ``gerber._emit_refdes``'s new
``reference_text`` parameter) is proven for the POSITION half by an
EXECUTABLE seal already landed this unit
(``test_silk_text.py::test_ir_native_path_positions_designator_at_the_real_component_placement``,
against the real ``MountingHole_3.2mm_M3`` seed footprint, whose authored
``(at 0 -4.2)`` has no rotation).

No footprint in the seed library authors a ROTATED reference fp_text (every
``fp_text reference`` in ``pcb/library/footprints`` omits the 3rd ``(at x y
ROT)`` token, i.e. rotation 0 — verified by grep across the seed lockfile's
``.pretty`` dirs). The two-step nested transform ``_emit_refdes`` applies
(text-local rotate-then-translate to the footprint's authored anchor, via
``place_point``, THEN the component's own placement transform) is therefore
UNEXERCISED by any real fixture for its rotation half. This file is that
missing case: a SYNTHETIC ``ReferenceTextDefinition`` with a nonzero
``rotation_deg``, hand-derived through KiCad's own clockwise convention (never
through the code under test), for the single simplest glyph in the font
(``'I'`` — one stroke, two points) so the arithmetic below can be checked by
hand rather than trusted.

HAND DERIVATION (do not re-derive a whole font — 'I' only)
------------------------------------------------------------
``stroke_font._GLYPHS['I']`` is a single OPEN 2-point stroke:
``((0.238095, -0.047619), (0.238095, -1.047619))``, advance width 0.47619.
``render("I", size=1.0, x0=0.0, y0=0.0)`` (h_align="center", the default)
centers the string: ``align_dx = -text_width("I") / 2 = -0.238095`` (text
width for a lone glyph is ``max(advance_width, max_x_over_points)`` =
``max(0.47619, 0.238095) = 0.47619``). Each point becomes
``((px + 0) * 1.0 + align_dx + 0.0, py * 1.0 + 0.0)``:

  P1 = (0.238095 - 0.238095, -0.047619) = (0.0, -0.047619)
  P2 = (0.238095 - 0.238095, -1.047619) = (0.0, -1.047619)

``reference_text = ReferenceTextDefinition(position=(2.0, -1.0),
rotation_deg=90.0, size_mm=1.0)`` — a synthetic footprint's designator sits
2mm right, 1mm up (Y-down convention: -1.0 is up) of the footprint origin,
and is itself rotated 90 degrees clockwise (a designator drawn sideways,
matching e.g. a connector authored with its text along the long edge).

``geometry.rotate_local_offset(px, py, deg)`` uses KiCad's own convention
(``radians(-deg)``, pinned by ``tests/test_rotation.py``); at deg=90 that
reduces EXACTLY to ``(px, py) -> (py, -px)`` (cos(-90)=0, sin(-90)=-1):

  rotate(P1, 90) = (-0.047619, -0.0)  = (-0.047619, 0.0)
  rotate(P2, 90) = (-1.047619, -0.0)  = (-1.047619, 0.0)

Translate by ``reference_text.position`` (2.0, -1.0) -- this is
``place_point(2.0, -1.0, 90.0, *P)``, the FIRST of ``_emit_refdes``'s two
composed steps (see its docstring):

  fp_local(P1) = (-0.047619 + 2.0, 0.0 - 1.0) = (1.952381, -1.0)
  fp_local(P2) = (-1.047619 + 2.0, 0.0 - 1.0) = (0.952381, -1.0)

The component sits at ``(10.0, 5.0)`` with ``rotation_deg=0.0`` (identity —
isolates the text-local rotation from any component-level rotation, so a
failure here can only be the NEW inner step, not the pre-existing outer one
already proven by the executable seal). The SECOND composed step,
``place_point(10.0, 5.0, 0.0, *fp_local)``, is identity-plus-translate:

  abs(P1) = (1.952381 + 10.0, -1.0 + 5.0) = (11.952381, 4.0)
  abs(P2) = (0.952381 + 10.0, -1.0 + 5.0) = (10.952381, 4.0)

These are BOARD-frame (Y-down) points -- ``_emit_refdes`` writes directly to
``_Geometry.silk_polys`` in that frame (the gerber-frame Y-flip is
``_Geometry.to_gerber_frame``, applied later by the harvest entry points, not
by ``_emit_refdes`` itself — see the executable seal's own note on
``gerber._Geometry.to_gerber_frame``, bug 019fa8011555). Calling
``gerber._emit_refdes`` directly (same pattern ``test_silk_text.py`` already
uses for its unit-level cases) keeps this test at the ``_Geometry`` boundary,
so no frame flip applies.
"""

from __future__ import annotations

import pytest

from pcb_worker import gerber
from pcb_worker.footprint_def import ReferenceTextDefinition


def test_emit_refdes_honors_authored_reference_text_rotation():
    reference_text = ReferenceTextDefinition(
        position=(2.0, -1.0), rotation_deg=90.0, size_mm=1.0,
    )
    g = gerber._Geometry()
    gerber._emit_refdes(g, "I", 10.0, 5.0, 0.0, top=True, reference_text=reference_text)

    text_polys = [pts for (pts, width, closed) in g.silk_polys
                  if width == gerber.SILK_TEXT_WIDTH_MM]
    assert len(text_polys) == 1, "the 'I' glyph is exactly one open stroke"
    pts = text_polys[0]
    assert pts == pytest.approx([(11.952381, 4.0), (10.952381, 4.0)], abs=1e-6)


def test_emit_refdes_falls_back_to_default_when_reference_text_is_absent():
    """The GUARD case: a footprint with no captured reference_text (the
    pre-019f77fd6d69 default) must render EXACTLY as before this unit —
    proving the new parameter is additive, not a silent behavior change for
    every footprint. Uses the SAME (cx, cy, rot) as the rotated case above so
    the two tests are otherwise comparable."""
    from pcb_worker.geometry import place_point
    from pcb_worker import stroke_font

    g = gerber._Geometry()
    gerber._emit_refdes(g, "I", 10.0, 5.0, 0.0, top=True, reference_text=None)

    expected_local = stroke_font.render(
        "I", size=gerber.REFDES_TEXT_SIZE_MM, x0=0.0, y0=gerber.REFDES_LOCAL_Y_MM)
    expected = [place_point(10.0, 5.0, 0.0, lx, ly) for (lx, ly) in expected_local[0]]

    text_polys = [pts for (pts, width, closed) in g.silk_polys
                  if width == gerber.SILK_TEXT_WIDTH_MM]
    assert len(text_polys) == 1
    assert text_polys[0] == pytest.approx(expected, abs=1e-6)
