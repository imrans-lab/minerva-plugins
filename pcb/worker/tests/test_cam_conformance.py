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


def _valid_pad_board(shape: str, *, angle: float = 0.0) -> dict:
    """A board carrying one pad of `shape` with VALID geometry for that shape (a
    circle is square; a roundrect gets a mid-range corner ratio)."""
    if shape == "circle":
        return _pad_board("circle", w=2.0, h=2.0, angle=angle)
    if shape == "roundrect":
        return _pad_board("roundrect", rratio=0.25, angle=angle)
    return _pad_board(shape, angle=angle)


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
    assert "%ADD10C,2.0*%" in _fcu(_pad_board("circle", w=2.0, h=2.0))


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
    assert _aperture_signature(_fcu(_valid_pad_board(shape))) == _EXPECTED_APERTURE[shape]


def test_supported_pad_shapes_are_not_flattened():
    # The core regression guard: the four declared shapes must produce four
    # DISTINCT apertures. If any pair collapses, the emitter is flattening again.
    sigs = {s: _aperture_signature(_fcu(_valid_pad_board(s))) for s in SUPPORTED_PAD_SHAPES}
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


# ---------------------------------------------------------------------------
# Fail-closed on degenerate geometry (fail-closed-fab doctrine): an emitter must
# never silently corrupt or flatten copper — it must error with pad context.
# ---------------------------------------------------------------------------


def test_circle_pad_with_unequal_sides_fails_closed():
    # A circle with width != height has no faithful circular aperture; emitting
    # C,width would silently drop the height axis.
    with pytest.raises(ValueError, match="circle"):
        gerber.build_gerbers(_pad_board("circle", w=2.0, h=1.0), name="conf")


@pytest.mark.parametrize("rratio", [-0.2, 0.9, "0.4", True, float("nan")])
def test_roundrect_bad_corner_rratio_fails_closed(rratio):
    # A negative ratio would silently flatten to a rectangle (the exact defect
    # this gate kills); >0.5 / non-numeric / NaN must also error with context,
    # not crash the aperture writer or silently default.
    with pytest.raises(ValueError):
        gerber.build_gerbers(_pad_board("roundrect", rratio=rratio), name="conf")


def test_roundrect_valid_rratio_boundary_is_accepted():
    # The [0, 0.5] boundary is valid: 0 -> rectangle, 0.5 -> fully rounded.
    assert _aperture_signature(_fcu(_pad_board("roundrect", rratio=0.0))) == "R"
    assert _fcu(_pad_board("roundrect", rratio=0.5))  # emits without error


def test_rotated_non_rect_shape_is_faithful():
    # A rotated oval must still be an obround carrying the rotation (Fable R1 note:
    # rotation coverage beyond the rectangle).
    text = _fcu(_pad_board("oval", angle=90.0))
    assert "%AMObround*" in text or re.search(r"%ADD\d+O", text)


def test_smd_aperture_maps_each_shape_to_its_primitive():
    from gerber_writer import Circle, Rectangle, RoundedRectangle
    assert isinstance(_smd_aperture("rect", 2.0, 1.0, None), Rectangle)
    assert isinstance(_smd_aperture("circle", 2.0, 2.0, None), Circle)
    assert isinstance(_smd_aperture("oval", 2.0, 1.0, None), RoundedRectangle)
    assert isinstance(_smd_aperture("roundrect", 2.0, 1.0, 0.25), RoundedRectangle)
    # Unknown shape falls back to a rectangle (never crashes the emitter).
    assert isinstance(_smd_aperture("mystery", 2.0, 1.0, None), Rectangle)


# ===========================================================================
# ROUND 2 — SOLDER-MASK opening conformance.
#
# The R2 regression: gerber._harvest hardcoded EVERY SMD mask opening as a
# rectangle regardless of pad.shape, so a circle/oval/roundrect land got a
# RECTANGULAR mask window — the same flattening class R1 killed for copper,
# still present on F.Mask/B.Mask. The mask opening must now use the SAME aperture
# family as the copper it covers (via the shared _shape_aperture helper),
# enlarged by the mask margin.
# ===========================================================================

# Default per-side mask growth (gerber.DEFAULT_MASK_CLEARANCE_MM) — the enlargement
# applied when neither a per-pad solder_mask_margin nor a design-rule clearance is set.
_DEFAULT_MARGIN = gerber.DEFAULT_MASK_CLEARANCE_MM


def _fmask(board: dict) -> str:
    files = gerber.build_gerbers(board, name="conf")
    return files["conf-F_Mask.gbr"]


def _mask_pad_board(shape: str, *, w: float = 2.0, h: float = 1.0,
                    rratio: float | None = None,
                    solder_mask_margin: float | None = None,
                    angle: float = 0.0) -> dict:
    """A minimal single-SMD-pad board, optionally carrying a per-pad
    solder_mask_margin. Reuses _pad_board's shape/geometry, then injects the
    margin directly (exactly how R1 injected corner_rratio — the resolve->dict
    serialization of this field is DEFERRED, out of fence)."""
    board = _pad_board(shape, w=w, h=h, rratio=rratio, angle=angle)
    if solder_mask_margin is not None:
        board["components"][0]["pads"][0]["solder_mask_margin"] = solder_mask_margin
    return board


def _valid_mask_pad_board(shape: str, *, solder_mask_margin: float | None = None) -> dict:
    """_valid_pad_board (shape-appropriate geometry) with an optional per-pad margin."""
    if shape == "circle":
        return _mask_pad_board("circle", w=2.0, h=2.0, solder_mask_margin=solder_mask_margin)
    if shape == "roundrect":
        return _mask_pad_board("roundrect", rratio=0.25, solder_mask_margin=solder_mask_margin)
    return _mask_pad_board(shape, solder_mask_margin=solder_mask_margin)


def _th_pad_board(*, w: float = 2.0, drill: float = 1.0,
                  solder_mask_margin: float | None = None) -> dict:
    """A minimal board with one resolved THROUGH-HOLE pad (round annulus). Its
    resolved copper width doubles as the annulus diameter (pad_source contract)."""
    pad = {"number": "1", "type": "thru_hole", "shape": "circle",
           "position": {"x": 0, "y": 0}, "size": {"width": w, "height": w},
           "drill": {"x": drill, "y": drill}, "layers": ["F.Cu", "B.Cu"]}
    if solder_mask_margin is not None:
        pad["solder_mask_margin"] = solder_mask_margin
    return {
        "version": 2, "name": "conf", "width_mm": 20, "height_mm": 20,
        "layers": ["top", "bottom"],
        "design_rules": {"trace_width_mm": 0.25, "clearance_mm": 0.2},
        "components": [{"ref": "P1", "footprint": "F", "x_mm": 5, "y_mm": 5,
                        "rotation_deg": 0, "layer": "top", "pads": [pad]}],
    }


@pytest.mark.parametrize("shape", sorted(SUPPORTED_PAD_SHAPES))
def test_mask_opening_matches_pad_aperture_family(shape):
    # The mask window for each declared shape uses the MATCHING aperture family —
    # a circle land no longer gets a rectangular mask window (the R2 defect).
    assert _aperture_signature(_fmask(_valid_mask_pad_board(shape))) == _EXPECTED_APERTURE[shape]


def test_supported_pad_shapes_mask_not_flattened():
    # Symmetric to test_supported_pad_shapes_are_not_flattened (copper): the four
    # declared shapes must produce four DISTINCT mask apertures.
    sigs = {s: _aperture_signature(_fmask(_valid_mask_pad_board(s))) for s in SUPPORTED_PAD_SHAPES}
    assert len(set(sigs.values())) == len(SUPPORTED_PAD_SHAPES), f"mask shapes collapsed: {sigs}"


def test_rect_mask_opening_enlarged_by_default_clearance():
    # Byte-contract sanity: a 2x1 rect land grows by the default clearance per side.
    w, h = 2.0, 1.0
    exp = f"%ADD10R,{w + 2 * _DEFAULT_MARGIN}X{h + 2 * _DEFAULT_MARGIN}*%"
    assert exp in _fmask(_mask_pad_board("rect", w=w, h=h))


def test_per_pad_solder_mask_margin_enlarges_opening():
    # An explicit per-pad solder_mask_margin overrides the global clearance: the
    # opening grows by 2*margin and differs from the default-clearance opening.
    margin = 0.4
    w, h = 2.0, 1.0
    custom = _aperture_defs(_fmask(_mask_pad_board("rect", w=w, h=h, solder_mask_margin=margin)))[0]
    default = _aperture_defs(_fmask(_mask_pad_board("rect", w=w, h=h)))[0]
    assert custom != default, "per-pad solder_mask_margin was ignored"
    assert f"R,{w + 2 * margin}X{h + 2 * margin}" == custom


def test_negative_margin_that_stays_positive_is_accepted():
    # A merely-negative margin (opening still > 0) is a legitimate KiCad mask-sliver
    # feature: it emits without error, with an opening SMALLER than the copper.
    w, h = 2.0, 1.0
    margin = -0.1
    sig = _aperture_defs(_fmask(_mask_pad_board("rect", w=w, h=h, solder_mask_margin=margin)))[0]
    assert sig == f"R,{w + 2 * margin}X{h + 2 * margin}"
    # opening dims strictly smaller than the 2x1 copper land
    assert (w + 2 * margin) < w and (h + 2 * margin) < h


@pytest.mark.parametrize("margin", [
    float("nan"), float("inf"), float("-inf"),  # non-finite
    "0.4", True, False,                          # non-numeric / bool (raw-type gate)
    -5.0,                                         # large-negative -> opening dim < 0
    -0.5,                                         # boundary: h=1.0 -> dim exactly 0.0 (<= 0)
])
def test_degenerate_solder_mask_margin_fails_closed(margin):
    # Non-finite (NaN/±inf), non-numeric string, and bool per-pad margins are caught
    # by the raw-type gate in pad_source; a margin that collapses an opening to <= 0
    # (large-negative, or the exact-zero boundary at margin=-0.5 on h=1.0) is caught
    # by the geometric gate in gerber._harvest. Each must raise ValueError with the
    # pad context. -0.5 pins the `<= 0` boundary (dim 0.0 fails, not just dim < 0).
    with pytest.raises(ValueError, match="P1"):
        gerber.build_gerbers(_mask_pad_board("rect", w=2.0, h=1.0, solder_mask_margin=margin),
                             name="conf")


def test_th_mask_honors_per_pad_margin_and_stays_circular():
    # A through-hole pad's mask opening tracks annulus + 2*margin and stays a
    # circle (declared TH copper = round annulus; SUPPORTED_HOLE_SHAPES = round).
    w, margin = 2.0, 0.5
    text = _fmask(_th_pad_board(w=w, solder_mask_margin=margin))
    # resolved TH copper width doubles as the annulus diameter (pad_source contract).
    assert f"%ADD10C,{w + 2 * margin}*%" in text
