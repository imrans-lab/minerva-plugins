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

import math
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
    """A minimal board carrying one resolved SMD pad of the given shape.

    The board is emitted through the IR fab path, where the component placement is
    IDENTITY and any pad rotation comes from the pad's own ABSOLUTE ``rotation``
    key — NOT the component ``rotation_deg`` (which the emitter reads only as a
    fallback). So a requested ``angle`` is baked onto
    the pad, exactly as the IR-native emitter bakes a placed pad's combined angle,
    keeping the component at rotation 0."""
    pad = {"number": "1", "type": "smd", "shape": shape,
           "position": {"x": 0, "y": 0}, "size": {"width": w, "height": h},
           "layers": ["F.Cu"]}
    if rratio is not None:
        pad["corner_rratio"] = rratio
    if angle:
        pad["rotation"] = angle
    return {
        "version": 2, "name": "conf", "width_mm": 20, "height_mm": 20,
        "layers": ["top", "bottom"],
        "design_rules": {"trace_width_mm": 0.25, "clearance_mm": 0.2,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [{"ref": "P1", "footprint": "F", "x_mm": 5, "y_mm": 5,
                        "rotation_deg": 0.0, "layer": "top", "pads": [pad]}],
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


def _th_pad_board(*, w: float = 2.0, h: float | None = None, drill: float = 1.0,
                  shape: str = "circle", raw_shape: str | None = None,
                  corner_rratio: float | None = None, pad_type: str = "thru_hole",
                  solder_mask_margin: float | None = None) -> dict:
    """A minimal board with one resolved THROUGH-HOLE pad. Its resolved copper width
    doubles as the round-annulus diameter (pad_source contract). `h` defaults to `w`
    (a square/round land); pass h != w for an OBLONG land. An oblong land needs a
    SHAPEABLE `shape` (oval/roundrect/rect) to emit faithfully; the default `circle`
    is round-only (an oblong circle fails closed — that is the point). `raw_shape`
    sets the AUTHORED-shape provenance (D1) that lets an EQUAL-AXIS land shape."""
    height = h if h is not None else w
    pad = {"number": "1", "type": pad_type, "shape": shape,
           "position": {"x": 0, "y": 0}, "size": {"width": w, "height": height},
           "drill": {"x": drill, "y": drill}, "layers": ["F.Cu", "B.Cu"]}
    if raw_shape is not None:
        pad["raw_shape"] = raw_shape
    if corner_rratio is not None:
        pad["corner_rratio"] = corner_rratio
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


# ===========================================================================
# ROUND 3 — GRAPHIC-PRIMITIVE (F.SilkS) conformance.
#
# The R3 regression: gerber._harvest_silk_graphic FLATTENED the modern KiCad 7/8
# three-point (start, mid, end) arc into a straight-segment polyline — a declared
# `arc` primitive emitted as lines, the exact flattening class this gate kills.
# The other primitives (line/circle/poly + the legacy center/start/angle arc) were
# already faithful; R3 locks them and fixes the three-point arc to a TRUE gerber
# arc via the SAME g.silk_arcs -> _add_silk_arcs emit path (no new emitter).
#
# Silk is COSMETIC (fab_capability: "Silk/fab/paste losses are warned, never
# fatal") so — unlike R1 copper / R2 mask — degenerate silk here is fail-SAFE
# (falls back to a polyline), NOT fail-closed. It must NEVER raise.
# ===========================================================================

from pcb_worker.fab_capability import SUPPORTED_GRAPHIC_PRIMITIVES


def _fsilk(board: dict) -> str:
    return gerber.build_gerbers(board, name="conf")["conf-F_SilkS.gbr"]


def _silk_board(graphics: list[dict], *, rot: float = 0.0) -> dict:
    """A minimal single-component board carrying F.SilkS `graphics` (the shape
    resolve_board emits), placed at (5, 5). One throwaway pad keeps the component
    well-formed; the silk path in _harvest reads only `graphics`."""
    return {
        "version": 2, "name": "conf", "width_mm": 20, "height_mm": 20,
        "layers": ["top", "bottom"],
        "design_rules": {"trace_width_mm": 0.25, "clearance_mm": 0.2},
        "components": [{"ref": "P1", "footprint": "F", "x_mm": 5, "y_mm": 5,
                        "rotation_deg": rot, "layer": "top",
                        "pads": [{"number": "1", "type": "smd", "shape": "rect",
                                  "position": {"x": 0, "y": 0},
                                  "size": {"width": 1, "height": 1},
                                  "layers": ["F.Cu"]}],
                        "graphics": graphics}],
    }


def _silk_fs_scale(text: str) -> tuple[int, int]:
    m = re.search(r"%FSLAX(\d)(\d)Y(\d)(\d)\*%", text)
    assert m, "no coordinate-format spec in silk gerber"
    return int(m.group(2)), int(m.group(4))


def _silk_draws(text: str) -> tuple[list, int]:
    """Parse the silk layer into (arcs, n_straight):

    arcs   -> list of (start, end, center, mode) for every G02/G03 D01 (mode
              2=CW / 3=CCW; center = start + (I, J)); a FULL circle has start==end.
    n_straight -> count of plain G01 straight-line interpolations (D01 without I/J).
    """
    xd, yd = _silk_fs_scale(text)
    mode, sx, sy = 1, None, None
    arcs: list = []
    n_straight = 0
    for raw in text.splitlines():
        s = raw.strip()
        if s == "G02*":
            mode = 2; continue
        if s == "G03*":
            mode = 3; continue
        if s == "G01*":
            mode = 1; continue
        m = re.match(r"X(-?\d+)Y(-?\d+)D02\*$", s)
        if m:
            sx, sy = int(m.group(1)) / 10 ** xd, int(m.group(2)) / 10 ** yd
            continue
        m = re.match(r"X(-?\d+)Y(-?\d+)I(-?\d+)J(-?\d+)D01\*$", s)
        if m and mode in (2, 3) and sx is not None:
            ex, ey = int(m.group(1)) / 10 ** xd, int(m.group(2)) / 10 ** yd
            ii, jj = int(m.group(3)) / 10 ** xd, int(m.group(4)) / 10 ** yd
            arcs.append(((sx, sy), (ex, ey), (sx + ii, sy + jj), mode))
            sx, sy = ex, ey
            continue
        m = re.match(r"X(-?\d+)Y(-?\d+)D01\*$", s)
        if m:
            if mode == 1:
                n_straight += 1
            sx, sy = int(m.group(1)) / 10 ** xd, int(m.group(2)) / 10 ** yd
    return arcs, n_straight


def _arc_midpoint(start, end, center, mode) -> tuple[float, float]:
    a0 = math.atan2(start[1] - center[1], start[0] - center[0])
    a1 = math.atan2(end[1] - center[1], end[0] - center[0])
    r = math.hypot(start[0] - center[0], start[1] - center[1])
    if mode == 3:  # CCW: sweep angle increasing
        while a1 <= a0:
            a1 += 2 * math.pi
    else:          # CW: sweep angle decreasing
        while a1 >= a0:
            a1 -= 2 * math.pi
    am = (a0 + a1) / 2.0
    return (center[0] + r * math.cos(am), center[1] + r * math.sin(am))


def _silk_signature(text: str) -> tuple[int, int, int]:
    """(full_circle_arcs, partial_arcs, straight_draws) — the primitive-shape
    fingerprint. It stays DISTINCT across line/circle/poly/arc iff none is
    flattened into another (e.g. an arc collapsing into straight segments)."""
    arcs, n_straight = _silk_draws(text)
    full = sum(1 for (s, e, _c, _m) in arcs
               if abs(s[0] - e[0]) < 1e-9 and abs(s[1] - e[1]) < 1e-9)
    return full, len(arcs) - full, n_straight


# --- Per-primitive faithful emission ---------------------------------------


def test_silk_line_emits_straight_draw():
    text = _fsilk(_silk_board([{"layer": "F.SilkS", "kind": "line",
                                "start": [-1, -1], "end": [1, 1], "width": 0.15}]))
    arcs, n_straight = _silk_draws(text)
    assert arcs == [], "a line must not emit an arc"
    assert n_straight == 1, f"line should be one straight draw, got {n_straight}"


def test_silk_circle_emits_true_full_circle_arc():
    # A circle is a SINGLE true-circle arc (start==end full-circle form), never a
    # sampled polygon.
    text = _fsilk(_silk_board([{"layer": "F.SilkS", "kind": "circle",
                                "center": [0, 0], "radius": 1.5, "width": 0.15}]))
    arcs, n_straight = _silk_draws(text)
    assert len(arcs) == 1, f"circle must be exactly one arc, got {len(arcs)}"
    start, end, center, _mode = arcs[0]
    assert start == end, "a full circle is emitted as a start==end 360-deg arc"
    # radius ~1.5 about the placed centre (5, 5).
    assert abs(math.hypot(start[0] - center[0], start[1] - center[1]) - 1.5) < 1e-3
    assert abs(center[0] - 5.0) < 1e-3 and abs(center[1] - 5.0) < 1e-3


def test_silk_circle_not_decomposed_into_segments():
    # Regression guard: the true circle must NOT decompose into many short straight
    # segments (the polygon-flatten failure this gate exists to prevent).
    _full, _partial, n_straight = _silk_signature(
        _fsilk(_silk_board([{"layer": "F.SilkS", "kind": "circle",
                             "center": [0, 0], "radius": 1.5, "width": 0.15}])))
    assert n_straight == 0, "circle was flattened into straight segments"


def test_silk_poly_emits_closed_path():
    text = _fsilk(_silk_board([{"layer": "F.SilkS", "kind": "poly",
                                "points": [[-1, -1], [1, -1], [1, 1], [-1, 1]],
                                "width": 0.15}]))
    arcs, n_straight = _silk_draws(text)
    assert arcs == [], "a poly must not emit an arc"
    # 4 corners closed back to the first -> 4 straight interpolations.
    assert n_straight == 4, f"expected a closed 4-segment path, got {n_straight}"


def test_silk_three_point_arc_emits_true_arc():
    # Modern KiCad 7/8 (start, mid, end) form. start(-1,0) mid(0,1) end(1,0):
    # circumcentre (0,0) -> placed (5,5), radius 1; midpoint bulges to +y.
    text = _fsilk(_silk_board([{"layer": "F.SilkS", "kind": "arc",
                                "points": [[-1, 0], [0, 1], [1, 0]], "width": 0.15}]))
    arcs, _n_straight = _silk_draws(text)
    assert len(arcs) == 1, f"a three-point arc must emit one true arc, got {len(arcs)}"
    start, end, center, mode = arcs[0]
    # Centre == circumcircle centre (placed local (0,0)).
    assert abs(center[0] - 5.0) < 1e-3 and abs(center[1] - 5.0) < 1e-3, \
        f"arc centre {center} != circumcentre (5,5)"
    # The arc passes THROUGH the mid point (placed local (0,1) -> (5,6)).
    mx, my = _arc_midpoint(start, end, center, mode)
    assert abs(mx - 5.0) < 1e-2 and abs(my - 6.0) < 1e-2, \
        f"arc geometric midpoint {(mx, my)} does not pass through mid (5,6)"


def test_silk_three_point_arc_not_flattened():
    # The R3 not-flattened guard: the three-point arc is a genuine arc, NOT a
    # polyline of straight segments.
    full, partial, n_straight = _silk_signature(
        _fsilk(_silk_board([{"layer": "F.SilkS", "kind": "arc",
                             "points": [[-1, 0], [0, 1], [1, 0]], "width": 0.15}])))
    assert (full, partial) == (0, 1), "three-point arc must be one partial arc"
    assert n_straight == 0, "three-point arc was flattened into straight segments"


def test_silk_three_point_arc_chirality_mirrors():
    # Mid on +y vs the mirrored mid on -y (same start/end) yield OPPOSITE gerber
    # orientations — chirality derives from the point order, consistent with the
    # legacy-arc convention pinned by test_legacy_arc_bulges_into_body.
    up = _silk_draws(_fsilk(_silk_board([{"layer": "F.SilkS", "kind": "arc",
        "points": [[-1, 0], [0, 1], [1, 0]], "width": 0.15}])))[0]
    down = _silk_draws(_fsilk(_silk_board([{"layer": "F.SilkS", "kind": "arc",
        "points": [[-1, 0], [0, -1], [1, 0]], "width": 0.15}])))[0]
    assert len(up) == 1 and len(down) == 1
    assert up[0][3] != down[0][3], \
        f"mirrored mid must flip chirality, got modes {up[0][3]} and {down[0][3]}"


def test_silk_collinear_three_point_arc_falls_back_without_raising():
    # Fail-SAFE (cosmetic, NOT fail-closed): three collinear points have an
    # undefined circumcentre (infinite radius) — an arc through them IS a line, so
    # it degrades to a polyline WITHOUT raising, and still emits something.
    text = _fsilk(_silk_board([{"layer": "F.SilkS", "kind": "arc",
                                "points": [[-1, 0], [0, 0], [1, 0]], "width": 0.15}]))
    arcs, n_straight = _silk_draws(text)
    assert arcs == [], "collinear points must not fabricate a spurious arc"
    assert n_straight >= 1, "collinear arc must still emit its chord as a polyline"


def test_silk_coincident_three_point_arc_does_not_raise():
    # Degenerate coincident points are also fail-SAFE — they must never raise.
    text = _fsilk(_silk_board([{"layer": "F.SilkS", "kind": "arc",
                                "points": [[0, 0], [0, 0], [0, 0]], "width": 0.15}]))
    arcs, _n = _silk_draws(text)
    assert arcs == [], "coincident points must not fabricate an arc"


def test_silk_near_collinear_three_point_arc_falls_back_no_overflow():
    # The collinear epsilon is absolute, so a NEAR-collinear triple can still solve
    # to a huge-but-finite radius whose centre lands off-board and would overflow
    # the gerber 4.6 coordinate format. Any arc past _ARC_MAX_RADIUS_MM is a straight
    # silk stroke — it must degrade to a polyline, not emit an off-board arc centre.
    # Mid point sagitta is ~5e-7 mm over a 4 mm chord -> radius ~4e6 mm >> the cap.
    text = _fsilk(_silk_board([{"layer": "F.SilkS", "kind": "arc",
                                "points": [[-2.0, 0.0], [0.0, 5.0e-7], [2.0, 0.0]],
                                "width": 0.15}]))
    arcs, n_straight = _silk_draws(text)
    assert arcs == [], "off-board huge-radius arc must fall back to a polyline"
    assert n_straight >= 1, "near-collinear arc must still emit its chord"
    # No emitted coordinate may exceed the plottable board range (overflow guard).
    for coord in re.findall(r"[XY](-?\d+)\*?", text):
        assert abs(int(coord)) < 10_000 * 10 ** 6, "coordinate overflowed 4.6 range"


def test_supported_graphic_primitives_are_not_flattened():
    # comment 628 analog for graphics: the declared primitives must each emit a
    # DISTINCT gerber shape — none silently collapsing into another's form.
    prims = {
        "line": [{"layer": "F.SilkS", "kind": "line",
                  "start": [-1, -1], "end": [1, 1], "width": 0.15}],
        "circle": [{"layer": "F.SilkS", "kind": "circle",
                    "center": [0, 0], "radius": 1.5, "width": 0.15}],
        "poly": [{"layer": "F.SilkS", "kind": "poly",
                  "points": [[-1, -1], [1, -1], [1, 1], [-1, 1]], "width": 0.15}],
        "arc": [{"layer": "F.SilkS", "kind": "arc",
                 "points": [[-1, 0], [0, 1], [1, 0]], "width": 0.15}],
    }
    # Every declared primitive is exercised (guards against silent scope drift).
    assert set(prims) == set(SUPPORTED_GRAPHIC_PRIMITIVES), \
        f"test set {set(prims)} != declared {set(SUPPORTED_GRAPHIC_PRIMITIVES)}"
    sigs = {k: _silk_signature(_fsilk(_silk_board(v))) for k, v in prims.items()}
    assert len(set(sigs.values())) == len(prims), f"graphic primitives collapsed: {sigs}"


# ===========================================================================
# Round 4: the WARNING side channel (GerberResult.diagnostics) + drill
# conformance. K3 doctrine (019f8a44484f comment 628): a captured fab feature
# that is dropped or approximated must never vanish SILENTLY. Silk/drill losses
# here are "warned, never fatal" — none of these paths may raise or fail-closed.
# ===========================================================================

from pcb_worker.resolved_board import DiagnosticSeverity


def _codes(result) -> list[str]:
    return [d.code for d in result.diagnostics]


def _drill_board(**extra) -> dict:
    """A board exercising every drill class: a plated TH pin (PTH), a via (PTH),
    a board-level plated pth_holes entry (PTH), and a non-plated mounting hole
    (NPTH). Distinct coordinates so each hole is identifiable in the .drl body."""
    board = {
        "version": 2, "name": "drill", "width_mm": 30, "height_mm": 30,
        "layers": ["top", "bottom"],
        "design_rules": {"trace_width_mm": 0.25, "clearance_mm": 0.2,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [{"ref": "J1", "footprint": "F", "x_mm": 5, "y_mm": 5,
                        "rotation_deg": 0, "layer": "top",
                        "pins": [{"number": "1", "x_mm": 0, "y_mm": 0,
                                  "drill_mm": 1.0, "annulus_diameter_mm": 1.8}]}],
        "vias": [{"x_mm": 10, "y_mm": 10, "drill_mm": 0.45, "diameter_mm": 0.9}],
        "pth_holes": [{"x_mm": 8, "y_mm": 8, "diameter_mm": 0.6}],
        "mounting_holes": [{"x_mm": 2, "y_mm": 20, "diameter_mm": 3.2,
                            "plated": False}],
    }
    board.update(extra)
    return board


# --- GerberResult: a files dict that ALSO carries diagnostics ---------------

def test_build_gerbers_returns_gerber_result_that_is_a_files_dict():
    result = gerber.build_gerbers(_valid_pad_board("rect"), name="conf")
    # It IS the files dict (indexing / iteration / equality unchanged).
    assert isinstance(result, gerber.GerberResult)
    assert isinstance(result, dict)
    assert "conf-F_Cu.gbr" in result
    assert isinstance(result["conf-F_Cu.gbr"], str) and result["conf-F_Cu.gbr"]
    assert set(result.items()) == set(dict(result).items())
    assert result == dict(result)
    # And it exposes the diagnostics side channel — empty on a clean board.
    assert result.diagnostics == []


# --- Silk degenerate drops -> WARNING, never a raise -----------------------

@pytest.mark.parametrize("graphic, reason", [
    ({"layer": "F.SilkS", "kind": "circle", "center": [0, 0], "radius": 0,
      "width": 0.15}, "zero-radius circle"),
    ({"layer": "F.SilkS", "kind": "line", "start": [0], "end": [1, 1],
      "width": 0.15}, "one-element line start"),
    ({"layer": "F.SilkS", "kind": "poly", "points": [[0, 0]], "width": 0.15},
     "single-point poly"),
])
def test_degenerate_silk_primitive_warns_and_still_emits(graphic, reason):
    board = _silk_board([graphic])
    # Must NOT raise (silk is cosmetic — warn, never fail-closed).
    result = gerber.build_gerbers(board, name="conf")
    # Files still emit (the degenerate primitive is simply absent from silk).
    assert "conf-F_SilkS.gbr" in result
    # The drop is surfaced as a WARNING carrying the owning component ref.
    warns = [d for d in result.diagnostics if d.code == "silk_primitive_unemitted"]
    assert warns, f"{reason}: expected a silk_primitive_unemitted warning"
    d = warns[0]
    assert d.severity is DiagnosticSeverity.WARNING
    assert d.source_ref.entity_id == "P1", f"{reason}: missing component context"


def test_collinear_three_point_arc_emits_arc_approximated_warning():
    # Reuse the R3 collinear fixture: three colinear points -> polyline fallback,
    # now ALSO flagged as an approximation (the curvature was lost, not silent).
    board = _silk_board([{"layer": "F.SilkS", "kind": "arc",
                          "points": [[-1, 0], [0, 0], [1, 0]], "width": 0.15}])
    result = gerber.build_gerbers(board, name="conf")
    # R3 behaviour intact: the polyline fallback still emits, no arc.
    arcs, n_straight = _silk_draws(result["conf-F_SilkS.gbr"])
    assert arcs == [] and n_straight >= 1
    # R4 addition: the approximation is announced.
    assert "silk_arc_approximated" in _codes(result)
    approx = [d for d in result.diagnostics if d.code == "silk_arc_approximated"][0]
    assert approx.severity is DiagnosticSeverity.WARNING
    assert approx.source_ref.entity_id == "P1"


def test_clean_silk_board_has_no_diagnostics():
    board = _silk_board([{"layer": "F.SilkS", "kind": "line",
                          "start": [-1, -1], "end": [1, 1], "width": 0.15}])
    assert gerber.build_gerbers(board, name="conf").diagnostics == []


# --- Drill PTH/NPTH split conformance (LOCK the working behaviour) ----------

def _drill_hits(text: str) -> list[tuple[float, float]]:
    """Every (x, y) drill hit in an Excellon body (X<..>Y<..>, 3-decimal mm)."""
    return [(float(x), float(y))
            for x, y in re.findall(r"^X(-?\d+\.\d+)Y(-?\d+\.\d+)$",
                                   text, re.MULTILINE)]


def test_drill_pth_npth_split_is_faithful():
    result = gerber.build_gerbers(_drill_board(), name="drill")
    assert "drill-PTH.drl" in result and "drill-NPTH.drl" in result
    pth = _drill_hits(result["drill-PTH.drl"])
    npth = _drill_hits(result["drill-NPTH.drl"])
    # Plated features (TH pin @5,5 ; via @10,10 ; pth_holes @8,8) land in PTH ONLY.
    assert (5.0, 5.0) in pth and (5.0, 5.0) not in npth      # TH pin
    assert (10.0, 10.0) in pth and (10.0, 10.0) not in npth  # via
    assert (8.0, 8.0) in pth and (8.0, 8.0) not in npth      # pth_holes entry
    # The non-plated mounting hole (@2,20) lands in NPTH ONLY.
    assert (2.0, 20.0) in npth and (2.0, 20.0) not in pth


def test_drill_degenerate_hole_warns_and_is_not_drilled():
    # A zero-diameter board hole is a captured-but-unemittable drill feature: it
    # must WARN (drill is fabrication-critical — silence is unacceptable) but must
    # NOT be drilled and must NOT raise (Extra passthrough of malformed input).
    board = _drill_board(mounting_holes=[{"x_mm": 2, "y_mm": 20,
                                          "diameter_mm": 0, "plated": False}])
    result = gerber.build_gerbers(board, name="drill")
    assert "drill_feature_unemitted" in _codes(result)
    d = [x for x in result.diagnostics if x.code == "drill_feature_unemitted"][0]
    assert d.severity is DiagnosticSeverity.WARNING
    assert "mounting_holes[0]" in d.source_ref.entity_id
    # The zero hole was NOT emitted; with no other NPTH candidate, NPTH is absent.
    assert "drill-NPTH.drl" not in result
    assert (2.0, 20.0) not in _drill_hits(result.get("drill-PTH.drl", ""))


# NOTE (W8.2 cutover): the two methods-level "gerbers forwards warnings" tests
# that lived here used a placeholder footprint ("F") + injected comp["pads"] +
# resolve_geometry:False to reach the emitter warning channel through the OLD
# best-effort fab path. Post-cutover the methods COMPILE first, so "F" fail-closes
# and that construction no longer reaches the emitter. The methods-forwarding
# capability (both the compile AND emitter warning channels, and the empty-warnings
# clean case) is now covered on the real IR path in tests/test_methods_ir_fab.py.
# The R1-R5 build_gerbers-direct conformance tests below are unaffected.


def test_refless_component_degenerate_silk_warns_with_sentinel_not_raises():
    # A component carrying no `ref` is valid input. Its degenerate silk must still
    # WARN (never silently vanish) and must NOT raise — Diagnostic requires a
    # non-empty entity_id, so _silk_ref falls back to a sentinel rather than
    # constructing an invalid Diagnostic. Pins that load-bearing fallback path.
    board = _silk_board([{"layer": "F.SilkS", "kind": "circle",
                          "center": [0, 0], "radius": 0, "width": 0.15}])
    board["components"][0].pop("ref")  # refless but otherwise well-formed
    result = gerber.build_gerbers(board, name="conf")  # must not raise
    warns = [d for d in result.diagnostics if d.code == "silk_primitive_unemitted"]
    assert warns, "refless component's dropped silk must still warn"
    assert warns[0].source_ref.entity_id  # non-empty (sentinel), Diagnostic-valid


# ===========================================================================
# Round 5: the KiCad emitter (kicad.py) under the SAME K3 bar as gerber.
# Declared capabilities must be emitted FAITHFULLY into the .kicad_pcb by the
# KiCad emitter too — the hard-coded `smd rect` (flattening circle/oval/roundrect)
# and the wholesale DROP of footprint silk graphics were the two infidelities.
# ===========================================================================

from pcb_worker import kicad


def _kpcb(board: dict, name: str = "conf") -> str:
    """The emitted .kicad_pcb text for a board."""
    return kicad.generate(board, base_name=name)[f"{name}.kicad_pcb"]


def _kicad_pad_shape_tokens(text: str) -> list[str]:
    """The shape token of every `(pad "N" smd <shape> ...)` in a .kicad_pcb."""
    return re.findall(r'\(pad "[^"]*" smd (\w+)', text)


# --- SMD pad SHAPE faithfulness (the R1 analog) -----------------------------

def test_kicad_rect_pad_emits_rect():
    assert "smd rect" in _kpcb(_valid_pad_board("rect"))


def test_kicad_circle_pad_emits_circle():
    # A circle pad emits `smd circle (size d d)`, not a flattened rect.
    text = _kpcb(_valid_pad_board("circle"))
    assert "smd circle" in text
    assert re.search(r"smd circle \(at [^)]*\) \(size 2\.0 2\.0\)", text)


def test_kicad_oval_pad_emits_oval():
    assert "smd oval" in _kpcb(_valid_pad_board("oval"))


def test_kicad_roundrect_pad_emits_roundrect_with_rratio():
    text = _kpcb(_valid_pad_board("roundrect"))  # rratio 0.25
    assert "smd roundrect" in text
    m = re.search(r"\(roundrect_rratio ([\d.]+)\)", text)
    assert m and float(m.group(1)) == 0.25


def test_kicad_supported_pad_shapes_are_not_flattened():
    # The four declared shapes produce four DISTINCT tokens (none collapse to rect).
    tokens = {
        _kicad_pad_shape_tokens(_kpcb(_valid_pad_board(s)))[0]
        for s in ("rect", "circle", "oval", "roundrect")
    }
    assert tokens == {"rect", "circle", "oval", "roundrect"}


def test_kicad_roundrect_rratio_tracks_corner_rratio():
    # Two different corner ratios -> two different emitted roundrect_rratio values.
    r1 = re.search(r"\(roundrect_rratio ([\d.]+)\)",
                   _kpcb(_pad_board("roundrect", rratio=0.1)))
    r2 = re.search(r"\(roundrect_rratio ([\d.]+)\)",
                   _kpcb(_pad_board("roundrect", rratio=0.4)))
    assert r1 and float(r1.group(1)) == 0.1
    assert r2 and float(r2.group(1)) == 0.4


# --- TH pad stays a faithful round annulus (R5 #5: intentional, not a flatten) --

def test_kicad_th_pad_stays_round_annulus():
    board = _drill_board()  # J1 has a TH pin
    assert "thru_hole circle" in _kpcb(board, name="drill")


# --- Footprint SILK GRAPHICS emission (was DROPPED before R5) ----------------

def test_kicad_silk_line_emitted():
    board = _silk_board([{"layer": "F.SilkS", "kind": "line",
                          "start": [-1, -1], "end": [1, 1], "width": 0.15}])
    text = _kpcb(board)
    assert "(fp_line" in text
    assert '(layer "F.SilkS")' in text


def test_kicad_silk_circle_emitted():
    board = _silk_board([{"layer": "F.SilkS", "kind": "circle",
                          "center": [0, 0], "radius": 1.0, "width": 0.15}])
    text = _kpcb(board)
    assert "(fp_circle" in text
    # center + end at center+radius (local coords, no transform).
    assert re.search(r"\(fp_circle \(center 0\.?0? 0\.?0?\) \(end 1\.0 0\.?0?\)", text)


def test_kicad_silk_three_point_arc_emitted():
    board = _silk_board([{"layer": "F.SilkS", "kind": "arc",
                          "points": [[-1, 0], [0, 1], [1, 0]], "width": 0.15}])
    text = _kpcb(board)
    assert "(fp_arc" in text
    # The mid point of the 3-point form is emitted (not dropped/approximated).
    assert re.search(r"\(fp_arc \(start [^)]*\) \(mid 0\.0 1\.0\) \(end", text)


def test_kicad_silk_poly_emitted():
    board = _silk_board([{"layer": "F.SilkS", "kind": "poly",
                          "points": [[0, 0], [1, 0], [1, 1]], "width": 0.15}])
    text = _kpcb(board)
    assert "(fp_poly" in text
    assert "(xy 0.0 0.0)" in text and "(xy 1.0 1.0)" in text


def test_kicad_supported_graphic_primitives_are_not_dropped():
    # All four declared graphic primitives emit their matching fp_* node.
    text = _kpcb(_silk_board([
        {"layer": "F.SilkS", "kind": "line", "start": [-1, -1], "end": [1, 1],
         "width": 0.15},
        {"layer": "F.SilkS", "kind": "circle", "center": [0, 0], "radius": 1.0,
         "width": 0.15},
        {"layer": "F.SilkS", "kind": "arc", "points": [[-1, 0], [0, 1], [1, 0]],
         "width": 0.15},
        {"layer": "F.SilkS", "kind": "poly", "points": [[0, 0], [1, 0], [1, 1]],
         "width": 0.15},
    ]))
    for node in ("(fp_line", "(fp_circle", "(fp_arc", "(fp_poly"):
        assert node in text, f"{node} was dropped"


# --- KicadResult: a files dict that ALSO carries diagnostics ----------------

def test_kicad_generate_returns_kicad_result_files_dict():
    result = kicad.generate(_valid_pad_board("rect"), base_name="conf")
    assert isinstance(result, kicad.KicadResult)
    assert isinstance(result, dict)
    assert "conf.kicad_pcb" in result
    assert isinstance(result["conf.kicad_pcb"], str) and result["conf.kicad_pcb"]
    assert result == dict(result)
    # Clean board -> empty diagnostics side channel.
    assert result.diagnostics == []


# --- Degenerate / unsupported silk -> WARNING, never a raise, not emitted ----

def test_kicad_zero_radius_silk_circle_warns_and_is_not_emitted():
    board = _silk_board([{"layer": "F.SilkS", "kind": "circle",
                          "center": [0, 0], "radius": 0, "width": 0.15}])
    result = kicad.generate(board, base_name="conf")  # must not raise
    assert "(fp_circle" not in result["conf.kicad_pcb"]
    warns = [d for d in result.diagnostics if d.code == "silk_primitive_unemitted"]
    assert warns and warns[0].severity is DiagnosticSeverity.WARNING
    assert warns[0].source_ref.entity_id == "P1"


def test_kicad_non_silk_graphic_layer_warns_and_is_not_emitted():
    board = _silk_board([{"layer": "F.Fab", "kind": "line",
                          "start": [-1, -1], "end": [1, 1], "width": 0.15}])
    result = kicad.generate(board, base_name="conf")
    codes = [d.code for d in result.diagnostics]
    assert "unsupported_graphic_layer" in codes
    d = next(x for x in result.diagnostics
             if x.code == "unsupported_graphic_layer")
    assert d.severity is DiagnosticSeverity.WARNING
    assert d.source_ref.entity_id == "P1"
    # The F.Fab graphic is NOT emitted as an fp_line.
    assert "(fp_line" not in result["conf.kicad_pcb"]


def test_kicad_degenerate_silk_does_not_raise():
    board = _silk_board([{"layer": "F.SilkS", "kind": "poly",
                          "points": [[0, 0]], "width": 0.15}])  # single-point poly
    result = kicad.generate(board, base_name="conf")  # must not raise
    assert "(fp_poly" not in result["conf.kicad_pcb"]
    assert "silk_primitive_unemitted" in [d.code for d in result.diagnostics]


def test_kicad_legacy_angle_arc_warns_not_emitted_wrong():
    # Legacy KiCad-6 (start,end,angle) form: emitter must NOT emit a wrong arc — it
    # warns instead (never a silent drop, never a wrong fp_arc).
    board = _silk_board([{"layer": "F.SilkS", "kind": "arc",
                          "points": [[-1, 0], [1, 0]], "angle": 90.0,
                          "width": 0.15}])
    result = kicad.generate(board, base_name="conf")
    assert "(fp_arc" not in result["conf.kicad_pcb"]
    assert "silk_primitive_unemitted" in [d.code for d in result.diagnostics]


def test_kicad_refless_component_degenerate_silk_warns_with_sentinel():
    board = _silk_board([{"layer": "F.SilkS", "kind": "circle",
                          "center": [0, 0], "radius": 0, "width": 0.15}])
    board["components"][0].pop("ref")  # refless but well-formed
    result = kicad.generate(board, base_name="conf")  # must not raise
    warns = [d for d in result.diagnostics if d.code == "silk_primitive_unemitted"]
    assert warns and warns[0].source_ref.entity_id  # non-empty sentinel


# NOTE (W8.2 cutover): the two methods-level "generate/kicad forwards warnings"
# tests here (placeholder "F" footprint + resolve_geometry:False) are superseded
# for the same reason as the gerbers pair above — see that note. The kicad
# methods-forwarding + clean-empty-warnings coverage now lives on the real IR path
# in tests/test_methods_ir_fab.py.


# ===========================================================================
# W1 A1: an SMD shape outside SUPPORTED_PAD_SHAPES was silently flattened to a
# rectangle by BOTH emitters with no diagnostic — the exact silent-flatten this
# gate kills, on fabrication-critical copper — so it must fail CLOSED.
#
# C2 (Codex finding 019f8b7fd295, supersedes the old A2 WARN): a genuinely OBLONG
# through-hole land (w != h) was circularized to a round annulus, DROPPING copper
# extent, with only a warning. Copper is FABRICATION_CRITICAL, so the doctrine is
# emit FAITHFULLY or fail closed — a warn is neither. Both emitters now emit the
# oblong land faithfully (obround / roundrect / rect copper on both layers via the
# shared pad_source.th_land; the drill stays round), so there is nothing to warn
# about. The signal is dimensional (w != h), NOT the shape token — a fallback TH
# pad defaults to shape "rect" while being a perfectly round land.
# ===========================================================================


@pytest.mark.parametrize("shape", ["trapezoid", "chamfered", "roundmutant", "octagon"])
def test_unknown_smd_shape_fails_closed_both_emitters(shape):
    board = _pad_board(shape)
    with pytest.raises(ValueError, match="not a supported pad shape"):
        gerber.build_gerbers(board, name="conf")
    with pytest.raises(ValueError, match="not a supported pad shape"):
        kicad.generate(board, base_name="conf")


def test_every_supported_smd_shape_still_passes_the_guard():
    # The fail-closed guard must not reject any DECLARED shape on either emitter.
    for shape in SUPPORTED_PAD_SHAPES:
        gerber.build_gerbers(_valid_pad_board(shape), name="conf")
        kicad.generate(_valid_pad_board(shape), base_name="conf")


def test_oblong_th_pad_emits_faithful_land_gerber():
    # An oblong TH land keeps BOTH extents as an obround on F.Cu AND B.Cu — never a
    # collapsed round annulus — with NO circularization warning (finding 019f8b7fd295).
    result = gerber.build_gerbers(_th_pad_board(w=2.0, h=1.0, shape="oval"), name="conf")
    assert "th_pad_shape_circularized" not in [d.code for d in result.diagnostics]
    for layer in ("conf-F_Cu.gbr", "conf-B_Cu.gbr"):
        assert re.search(r"%ADD\d+O,2\.0X1\.0\*%", result[layer]), (
            f"{layer} must carry the faithful obround TH land, not a round annulus")


def test_oblong_th_pad_emits_faithful_land_kicad():
    result = kicad.generate(_th_pad_board(w=2.0, h=1.0, shape="oval"), base_name="conf")
    assert "th_pad_shape_circularized" not in [d.code for d in result.diagnostics]
    pcb = result["conf.kicad_pcb"]
    assert "thru_hole oval" in pcb        # faithful shaped TH copper, not circle
    assert "(size 2.0 1.0)" in pcb        # both extents preserved
    assert "(drill 1.0)" in pcb           # the drill stays round


@pytest.mark.parametrize("bad_shape", ["circle", "custom", "trapezoid"])
def test_oblong_th_pad_unshapeable_fails_closed_both_emitters(bad_shape):
    # "faithfully OR fail closed": an OBLONG land whose shape has no faithful oblong
    # aperture (a circle cannot be oblong; custom/unknown has no aperture) must fail
    # CLOSED, never silently circularize (drop copper) or coerce to an obround.
    board = _th_pad_board(w=2.0, h=1.0, shape=bad_shape)
    with pytest.raises(ValueError, match="no.*faithful oblong copper aperture"):
        gerber.build_gerbers(board, name="conf")
    with pytest.raises(ValueError, match="no.*faithful oblong copper aperture"):
        kicad.generate(board, base_name="conf")


def test_th_land_decision_truth_table():
    # The SINGLE shared th_land decision BOTH emitters consume (anti-drift). Shaped
    # iff shapeable family (oval/roundrect/rect) AND (OBLONG w!=h OR an authored
    # CORNERED shape rect/roundrect). No coercion: an oblong circle/custom land is
    # fail-closed upstream by _require_faithful_shape. A DEFAULTED-rect equal-axis
    # land (raw_shape None) and an equal-axis oval stay round annuli (D1).
    from types import SimpleNamespace

    from pcb_worker.pad_source import th_land

    def pad(w, h, shape="rect", rr=None, raw_shape=None):
        return SimpleNamespace(width=w, height=h, shape=shape, corner_rratio=rr,
                               raw_shape=raw_shape)

    # OBLONG lands: shaped regardless of provenance.
    assert th_land(pad(2.0, 1.0, "oval")) == (True, "oval", 2.0, 1.0, None)
    assert th_land(pad(2.0, 1.0, "rect")) == (True, "rect", 2.0, 1.0, None)
    assert th_land(pad(2.0, 1.0, "roundrect", 0.25)) == (True, "roundrect", 2.0, 1.0, 0.25)
    assert th_land(pad(2.0, 1.0, "circle"))[0] is False    # oblong circle: gate's job
    assert th_land(pad(2.0, 1.0, "custom"))[0] is False     # unknown: gate's job
    # EQUAL-AXIS lands: shaped ONLY for an authored CORNERED shape (D1 c688).
    assert th_land(pad(1.5, 1.5, "rect", raw_shape="rect")) == (True, "rect", 1.5, 1.5, None)
    assert th_land(pad(1.5, 1.5, "roundrect", 0.2, raw_shape="roundrect")) == \
        (True, "roundrect", 1.5, 1.5, 0.2)
    assert th_land(pad(1.5, 1.5, "rect", raw_shape=None))[0] is False    # defaulted rect
    assert th_land(pad(1.5, 1.5, "oval", raw_shape="oval"))[0] is False  # authored oval = round
    assert th_land(pad(None, 1.0, "oval"))[0] is False      # missing dim
    assert th_land(pad(2.0, None, "oval"))[0] is False


def test_square_th_pad_does_not_warn_either_emitter():
    # A round/square TH land is faithfully a circular annulus — no warning noise.
    g = gerber.build_gerbers(_th_pad_board(w=1.5, h=1.5), name="conf")
    k = kicad.generate(_th_pad_board(w=1.5, h=1.5), base_name="conf")
    assert "th_pad_shape_circularized" not in [d.code for d in g.diagnostics]
    assert "th_pad_shape_circularized" not in [d.code for d in k.diagnostics]


def test_unplated_np_thru_hole_pad_emits_no_copper_both_emitters():
    # D3 (finding 019f8fe77068): an UNPLATED (np_thru_hole) footprint pad is a BARE
    # hole — gerber emits NO copper land (it used to invent a 2x-drill annulus), just
    # a drill-size mask opening, matching kicad's np_thru_hole (no copper ring). The
    # drill routes to NPTH on both.
    board = _th_pad_board(w=2.0, h=2.0, drill=2.0, pad_type="np_thru_hole")
    g = gerber.build_gerbers(board, name="conf")
    # No copper flash on either copper layer (no ComponentPad annulus for the pad).
    assert "ComponentPad" not in g["conf-F_Cu.gbr"]
    assert "ComponentPad" not in g["conf-B_Cu.gbr"]
    assert "conf-NPTH.drl" in g and "conf-PTH.drl" not in g   # bare hole -> NPTH only
    # A drill-size (2.0) mask opening is present (matches kicad np_thru_hole size==drill).
    assert re.search(r"%ADD\d+C,2\.0\*%", g["conf-F_Mask.gbr"])
    # kicad emits the bare np_thru_hole (no copper), never a thru_hole for it.
    pcb = kicad.generate(board, base_name="conf")["conf.kicad_pcb"]
    assert "np_thru_hole" in pcb
    assert "thru_hole circle" not in pcb.replace("np_thru_hole circle", "")


def test_authored_square_rect_th_pad_is_shaped_both_emitters():
    # D1 (finding 019f8b7fd295 c688): an EQUAL-AXIS land whose shape is genuinely
    # AUTHORED as rect (a real square pin-1 marker) keeps its corners in BOTH
    # emitters — no round-annulus flattening. gerber: a rect aperture; kicad: a
    # thru_hole rect.
    board = _th_pad_board(w=1.6, h=1.6, shape="rect", raw_shape="rect")
    g = gerber.build_gerbers(board, name="conf")
    assert re.search(r"%ADD\d+R,1\.6X1\.6\*%", g["conf-F_Cu.gbr"])
    assert re.search(r"%ADD\d+R,1\.6X1\.6\*%", g["conf-B_Cu.gbr"])
    assert "thru_hole rect" in kicad.generate(board, base_name="conf")["conf.kicad_pcb"]


def test_defaulted_rect_equal_axis_th_pad_stays_round():
    # The other half of D1: an equal-axis land whose rect shape was DEFAULTED (no
    # authored provenance) stays a round annulus — a plain round TH pad is untouched.
    board = _th_pad_board(w=1.6, h=1.6, shape="rect", raw_shape=None)
    g = gerber.build_gerbers(board, name="conf")
    assert re.search(r"%ADD\d+C,1\.6\*%", g["conf-F_Cu.gbr"])
    assert not re.search(r"%ADD\d+R,1\.6X1\.6\*%", g["conf-F_Cu.gbr"])


@pytest.mark.parametrize("bad_rratio", [-0.1, 0.6, float("inf")])
def test_th_roundrect_bad_corner_rratio_fails_closed(bad_rratio):
    # D1 hoisted the roundrect corner_rratio validation above the drill branch, so a
    # TH roundrect land (now shapeable) no longer skips it: a ratio outside [0, 0.5]
    # fails CLOSED in both emitters rather than flattening / crashing the aperture
    # writer on fabrication-critical copper.
    board = _th_pad_board(w=2.0, h=1.0, shape="roundrect", corner_rratio=bad_rratio)
    with pytest.raises(ValueError, match="corner_rratio"):
        gerber.build_gerbers(board, name="conf")
    with pytest.raises(ValueError, match="corner_rratio"):
        kicad.generate(board, base_name="conf")


def test_empty_or_missing_smd_shape_defaults_to_rect_no_raise():
    # An SMD pad with shape "" or no shape key legitimately defaults to "rect" (a
    # supported shape) in _from_resolved BEFORE the guard runs — it must NOT trip
    # the A1 unknown-shape fail-closed. Locks the no-false-reject boundary.
    empty = _pad_board("")
    missing = _pad_board("rect")
    missing["components"][0]["pads"][0].pop("shape")
    for board in (empty, missing):
        gerber.build_gerbers(board, name="conf")     # must not raise
        kicad.generate(board, base_name="conf")       # must not raise
