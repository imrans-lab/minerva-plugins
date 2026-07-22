"""CAM capability-conformance suite (K3 acceptance gate — 019f7aed6d9e comment 628).

Proves that every declared fab capability is emitted FAITHFULLY, not flattened.
This is the gate that must be green before gerber/KiCad/DRC switch onto the
ResolvedBoard IR. Round 1 covers pad SHAPE + rotation on gerber; later rounds add
TH annulus, mask margins, graphic primitives, PTH/NPTH split, and the KiCad
emitter under the same harness.

The regression this locks: gerber.py used to flash EVERY SMD pad as a Rectangle,
silently collapsing circle/oval/roundrect. Each declared SUPPORTED_PAD_SHAPE must
now produce its own faithful gerber aperture:
    rect      -> R  (rectangle)
    circle    -> C  (circle, diameter)
    oval      -> O  (obround)
    roundrect -> %AMRoundedRectangle macro
"""
from __future__ import annotations

import re

import pytest

from pcb_worker import gerber
from pcb_worker.fab_capability import SUPPORTED_PAD_SHAPES
from pcb_worker.gerber import _smd_aperture

# Expected copper-aperture signature per declared pad shape. A signature is the
# gerber aperture template letter (R/C/O) or the macro name — the thing that would
# be identical for all four if the emitter were still flattening to a rectangle.
_EXPECTED_APERTURE = {
    "rect": "R",
    "circle": "C",
    "oval": "O",
    "roundrect": "RoundedRectangle",  # aperture macro
}


def _pad_board(shape: str, *, w: float = 2.0, h: float = 1.0,
               rratio: float | None = None, angle: float = 0.0) -> dict:
    """A minimal board carrying one resolved SMD pad of the given shape."""
    pad = {"number": "1", "type": "smd", "shape": shape,
           "position": {"x": 0, "y": 0}, "size": {"width": w, "height": h},
           "layers": ["F.Cu"]}
    if rratio is not None:
        pad["corner_rratio"] = rratio
    return {
        "version": 2, "name": "conf", "width_mm": 20, "height_mm": 20,
        "layers": ["top", "bottom"],
        "design_rules": {"trace_width_mm": 0.25, "clearance_mm": 0.2,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [{"ref": "P1", "footprint": "F", "x_mm": 5, "y_mm": 5,
                        "rotation_deg": angle, "layer": "top", "pads": [pad]}],
    }


def _fcu(board: dict) -> str:
    files = gerber.build_gerbers(board, name="conf")
    return files["conf-F_Cu.gbr"]


def _aperture_defs(text: str) -> list[str]:
    """The %ADD aperture-definition bodies (after the D-code) on a layer."""
    return re.findall(r"%ADD\d+([^*]+)\*%", text)


def _aperture_signature(text: str) -> str:
    """The single copper aperture's template — the token before the first comma:
    'R'/'C'/'O' for a standard aperture, or the macro name ('RoundedRectangle',
    'Rectangle') for a macro aperture. This is what collapses to a constant across
    shapes if the emitter flattens. NB the standard rectangle 'R' and the macro
    'RoundedRectangle'/'Rectangle' all start with 'R', so split on ',' — do not
    index the first character."""
    defs = _aperture_defs(text)
    assert len(defs) == 1, f"expected exactly one copper aperture, got {defs}"
    return defs[0].split(",", 1)[0]


# ---------------------------------------------------------------------------
# Per-shape faithful emission.
# ---------------------------------------------------------------------------


def test_rect_pad_emits_rectangle_aperture():
    assert "%ADD10R,2.0X1.0*%" in _fcu(_pad_board("rect"))


def test_circle_pad_emits_circle_aperture():
    # A circle flashes a true C aperture with the diameter, not a square land.
    assert "%ADD10C,2.0*%" in _fcu(_pad_board("circle"))


def test_oval_pad_emits_obround_aperture():
    # An oval is a true obround (O), not a rectangle.
    assert "%ADD10O,2.0X1.0*%" in _fcu(_pad_board("oval"))


def test_roundrect_pad_emits_rounded_macro():
    text = _fcu(_pad_board("roundrect", rratio=0.25))
    assert "%AMRoundedRectangle*" in text
    assert re.search(r"%ADD\d+RoundedRectangle,", text)


@pytest.mark.parametrize("shape", sorted(SUPPORTED_PAD_SHAPES))
def test_every_supported_pad_shape_emits_its_faithful_aperture(shape):
    # comment 628: EVERY declared SUPPORTED_PAD_SHAPE must be emitted faithfully.
    rratio = 0.25 if shape == "roundrect" else None
    assert _aperture_signature(_fcu(_pad_board(shape, rratio=rratio))) == _EXPECTED_APERTURE[shape]


def test_supported_pad_shapes_are_not_flattened():
    # The core regression guard: the four declared shapes must produce four
    # DISTINCT apertures. If any pair collapses, the emitter is flattening again.
    sigs = {
        s: _aperture_signature(_fcu(_pad_board(s, rratio=0.25 if s == "roundrect" else None)))
        for s in SUPPORTED_PAD_SHAPES
    }
    assert len(set(sigs.values())) == len(SUPPORTED_PAD_SHAPES), f"shapes collapsed: {sigs}"


# ---------------------------------------------------------------------------
# Rotation + roundrect radius fidelity.
# ---------------------------------------------------------------------------


def test_pad_rotation_is_applied_not_dropped():
    # A rotated rectangle becomes a rotation-carrying aperture macro; the angle
    # must survive into the emitted geometry (not be silently dropped).
    straight = _fcu(_pad_board("rect", angle=0.0))
    rotated = _fcu(_pad_board("rect", angle=90.0))
    assert "%ADD10R,2.0X1.0*%" in straight  # axis-aligned: plain rectangle
    assert "%AMRectangle*" in rotated
    assert re.search(r"%ADD\d+Rectangle,[^*]*X90\.0", rotated)


def test_roundrect_radius_tracks_corner_rratio():
    # The corner radius must derive from the pad's actual rratio, not a constant.
    wide = _aperture_defs(_fcu(_pad_board("roundrect", rratio=0.5)))[0]
    tight = _aperture_defs(_fcu(_pad_board("roundrect", rratio=0.1)))[0]
    assert wide != tight, "roundrect radius ignored the corner_rratio"


def test_roundrect_zero_rratio_degenerates_to_rectangle():
    # rratio 0 is a plain rectangle — no zero-radius macro.
    assert _aperture_signature(_fcu(_pad_board("roundrect", rratio=0.0))) == "R"


# ---------------------------------------------------------------------------
# Aperture-mapping unit (fast, type-level).
# ---------------------------------------------------------------------------


def test_smd_aperture_maps_each_shape_to_its_primitive():
    from gerber_writer import Circle, Rectangle, RoundedRectangle
    assert isinstance(_smd_aperture("rect", 2.0, 1.0, None), Rectangle)
    assert isinstance(_smd_aperture("circle", 2.0, 2.0, None), Circle)
    assert isinstance(_smd_aperture("oval", 2.0, 1.0, None), RoundedRectangle)
    assert isinstance(_smd_aperture("roundrect", 2.0, 1.0, 0.25), RoundedRectangle)
    # Unknown shape falls back to a rectangle (never crashes the emitter).
    assert isinstance(_smd_aperture("mystery", 2.0, 1.0, None), Rectangle)
