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

import ast
import inspect
import math
import re

import pytest

from pcb_worker import board_font, gerber
from pcb_worker.fab_capability import SUPPORTED_PAD_SHAPES
from pcb_worker.gerber import _smd_aperture


def _numeric_literal_bindings(module) -> set[str]:
    """Every MODULE-LEVEL name *module* binds directly to a numeric literal.

    Reads the source, because the question is about provenance and provenance is
    a source-level fact. At runtime ``X = 0.15`` and ``X = other.X`` are
    indistinguishable once both are the float 0.15; only the text says which one
    a module wrote. Module level only — a numeric default or local inside a
    function is not a shared-constant declaration and is not what this guards.
    """
    tree = ast.parse(inspect.getsource(module))
    bound: set[str] = set()
    for node in tree.body:
        targets = []
        if isinstance(node, ast.Assign):
            targets = node.targets
        elif isinstance(node, ast.AnnAssign) and node.value is not None:
            targets = [node.target]
        else:
            continue
        value = node.value
        # Unary minus counts: `= -1.5` is still a literal declaration.
        if isinstance(value, ast.UnaryOp) and isinstance(value.op, (ast.USub, ast.UAdd)):
            value = value.operand
        if isinstance(value, ast.Constant) and isinstance(value.value, (int, float)) \
                and not isinstance(value.value, bool):
            bound.update(t.id for t in targets if isinstance(t, ast.Name))
    return bound


def _attribute_bindings(module) -> dict[str, str]:
    """Every MODULE-LEVEL ``X = pkg.attr`` binding, as ``{"X": "pkg.attr"}``.

    The companion to ``_numeric_literal_bindings``, and it exists because CP2
    S6 raised the graphic silk fallback to 0.15 — the SAME value the text
    constant already held. Every runtime check that the two names stay
    correctly wired (``==``, and even ``is``, since equal float constants may
    be folded to one object) went vacuous the moment the numbers matched: a
    module that mis-wired ``SILK_TEXT_WIDTH_MM = silk_source.SILK_GRAPHIC_WIDTH_MM``
    would satisfy all of them.

    Only the SOURCE still distinguishes the two authorities, so only the source
    can pin them. Attribute chains are flattened to dotted text, so
    ``silk_source.SILK_TEXT_WIDTH_MM`` reads back exactly as written.
    """
    def dotted(node: ast.AST) -> str | None:
        parts: list[str] = []
        while isinstance(node, ast.Attribute):
            parts.append(node.attr)
            node = node.value
        if not isinstance(node, ast.Name):
            return None
        parts.append(node.id)
        return ".".join(reversed(parts))

    tree = ast.parse(inspect.getsource(module))
    out: dict[str, str] = {}
    for node in tree.body:
        if not isinstance(node, ast.Assign) or not isinstance(node.value, ast.Attribute):
            continue
        rhs = dotted(node.value)
        if rhs is None:
            continue
        for t in node.targets:
            if isinstance(t, ast.Name):
                out[t.id] = rhs
    return out

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
    # The pad angle is a REQUIRED argument (no default) so a future call site cannot
    # silently omit it and reintroduce the rotated-obround defect — 019f9af6e899.
    assert isinstance(_smd_aperture("rect", 2.0, 1.0, None, 0.0), Rectangle)
    assert isinstance(_smd_aperture("circle", 2.0, 2.0, None, 0.0), Circle)
    assert isinstance(_smd_aperture("oval", 2.0, 1.0, None, 0.0), RoundedRectangle)
    assert isinstance(_smd_aperture("roundrect", 2.0, 1.0, 0.25, 0.0), RoundedRectangle)
    # Unknown shape falls back to a rectangle (never crashes the emitter).
    assert isinstance(_smd_aperture("mystery", 2.0, 1.0, None, 0.0), Rectangle)


def test_shape_aperture_requires_an_explicit_angle():
    # Pin the no-default contract itself: omitting the angle must be a hard TypeError
    # at the call, not a silent fall back to 0.0 that drops a rotated land's rotation.
    with pytest.raises(TypeError):
        gerber._shape_aperture("oval", 2.0, 1.0, None, "SMDPad,CuDef")


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


# --- Global (board-level) solder-mask clearance: shared raw resolver (019f94b686b4) ---
from pcb_worker import kicad  # noqa: E402
from pcb_worker.compile_board import compile_board  # noqa: E402


def _global_clearance_board(clearance) -> dict:
    """A RAW board with one resolved 2.0x1.0 SMD pad AND one untented via, optionally
    carrying an authored ``design_rules.solder_mask_clearance_mm``. Exercises both
    mask-aperture paths (pad + via) that a global clearance feeds."""
    board = {
        "version": 2, "name": "conf", "width_mm": 20, "height_mm": 20,
        "layers": ["top", "bottom"],
        "design_rules": {"trace_width_mm": 0.25, "clearance_mm": 0.2,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [{"ref": "R1", "footprint": "F", "x_mm": 5, "y_mm": 5,
                        "rotation_deg": 0, "layer": "top",
                        "pads": [{"number": "1", "type": "smd", "shape": "rect",
                                  "position": {"x": 0, "y": 0},
                                  "size": {"width": 2.0, "height": 1.0},
                                  "layers": ["F.Cu"]}]}],
        "nets": [{"name": "N", "pins": ["R1.1"]}],
        # UNTENTED via: the canonical per-side keys the raw emitters actually read
        # are tented_front / tented_back (each DEFAULTS True/tented when absent) — a
        # source-level `tented` key never reaches the loose-dict path. Both False =>
        # the via mask opens (gerber flashes it, kicad emits `(tenting none)`), so the
        # via mask-aperture path is genuinely exercised by the global clearance.
        "vias": [{"net": "N", "x_mm": 10, "y_mm": 10, "diameter_mm": 0.8,
                  "drill_mm": 0.4, "from_layer": "top", "to_layer": "bottom",
                  "tented_front": False, "tented_back": False}],
    }
    if clearance is not None:
        board["design_rules"]["solder_mask_clearance_mm"] = clearance
    return board


_RAW_EMITTERS = [
    pytest.param(lambda b: gerber.build_gerbers(b, name="conf"), id="gerber"),
    pytest.param(lambda b: kicad.generate_kicad_pcb(b), id="kicad"),
]


@pytest.mark.parametrize("emit", _RAW_EMITTERS)
@pytest.mark.parametrize("bad", [-1.0, float("nan"), float("-inf"), float("inf")],
                         ids=["neg", "nan", "neg-inf", "pos-inf"])
def test_raw_global_mask_clearance_invalid_fails_closed(emit, bad):
    # bug 019f94b686b4: an authored global solder_mask_clearance_mm that is negative,
    # NaN, or +-Inf must FAIL CLOSED in BOTH raw emitters — never silently rewritten
    # to the 0.1 default (-1/NaN/-Inf) nor leaked as malformed +Inf aperture geometry
    # (KiCad `(pad_to_mask_clearance inf)` / Gerber `%ADD...inf...%`). The shared
    # resolver rejects it before any pad/via opening is computed.
    with pytest.raises(ValueError, match="solder_mask_clearance_mm"):
        emit(_global_clearance_board(bad))


@pytest.mark.parametrize("emit", _RAW_EMITTERS)
@pytest.mark.parametrize("good", [0.0, 0.3])
def test_raw_global_mask_clearance_valid_emits(emit, good):
    # A finite, non-negative authored global clearance (INCLUDING exactly 0) is
    # honored by both raw emitters — no fail-closed, real output produced.
    assert emit(_global_clearance_board(good))


def test_raw_global_mask_clearance_absent_uses_default():
    # No authored global clearance -> the documented raw default (0.1mm/side): the
    # 2x1 SMD land -> F.Mask opening 2.2x1.2, the Ø0.8 untented via -> 1.0.
    fmask = gerber.build_gerbers(_global_clearance_board(None), name="conf")["conf-F_Mask.gbr"]
    assert "R,2.2X1.2" in fmask
    assert "C,1.0" in fmask  # via Ø0.8 + 2*0.1


def test_raw_global_mask_clearance_explicit_null_uses_default():
    # An EXPLICITLY null clearance (field PRESENT, value null/None) is treated as
    # absent -> the raw default (0.1), not fail-closed. Distinct from omitting the
    # field: this pins that `solder_mask_clearance_mm: null` is honored as "unset".
    board = _global_clearance_board(None)
    board["design_rules"]["solder_mask_clearance_mm"] = None  # explicit JSON null
    fmask = gerber.build_gerbers(board, name="conf")["conf-F_Mask.gbr"]
    assert "R,2.2X1.2" in fmask
    assert kicad.generate_kicad_pcb(board)  # kicad likewise emits, no fail-closed


@pytest.mark.parametrize("good", [0.0, 0.3])
def test_raw_global_mask_clearance_feeds_gerber_opening(good):
    # The authored global clearance actually drives BOTH gerber mask openings it
    # feeds — the 2x1 SMD land (copper + 2*clearance/side) AND the Ø0.8 untented via
    # (dia + 2*clearance) — proving it is used, not ignored, on both aperture paths.
    w, h, via_dia = 2.0, 1.0, 0.8
    fmask = gerber.build_gerbers(_global_clearance_board(good), name="conf")["conf-F_Mask.gbr"]
    assert f"R,{w + 2 * good}X{h + 2 * good}" in fmask   # SMD pad mask
    assert f"C,{via_dia + 2 * good}" in fmask            # untented via mask


@pytest.mark.parametrize("good", [0.0, 0.3])
def test_raw_global_mask_clearance_feeds_kicad_setup_and_pad(good):
    # Symmetric to the gerber-opening test: the authored global clearance reaches
    # BOTH the KiCad board `(setup (pad_to_mask_clearance ...))` and the per-pad
    # `(solder_mask_margin ...)` — proving it FLOWS THROUGH, not merely "emits". The
    # untented via carries `(tenting none)` so its mask opens (matching gerber's flash).
    pcb = kicad.generate_kicad_pcb(_global_clearance_board(good))
    assert f"(pad_to_mask_clearance {good})" in pcb
    assert f"(solder_mask_margin {good})" in pcb
    assert "(tenting none)" in pcb


@pytest.mark.parametrize("authored", [0.9, 0.0])
def test_production_ir_mask_clearance_pinned_to_v1_floor(authored):
    # Production compile does NOT model the authored global clearance (Extra
    # passthrough): the ResolvedBoard IR pins it to the v1 manufacturing floor
    # (0.05mm), so the +Inf/negative raw-emitter defect is unreachable on the
    # canonical path regardless of what the source authored.
    board = {"version": 1, "name": "x", "width_mm": 10, "height_mm": 10,
             "layers": ["top", "bottom"],
             "design_rules": {"trace_width_mm": 0.25, "clearance_mm": 0.2,
                              "via_diameter_mm": 0.8, "via_drill_mm": 0.4,
                              "solder_mask_clearance_mm": authored},
             "components": [], "nets": []}
    resolved = compile_board(board).board
    assert resolved.design_rules.minimums.solder_mask_clearance_mm == 0.05


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


def _refdes_straight_count(ref: str = "P1") -> int:
    """How many G01 straight-line segments _emit_refdes's OWN designator text
    draws for `_silk_board`'s component (ref "P1" by default) — additive on
    EVERY `_silk_board` fixture below regardless of which primitive is under
    test, since K17 emits a reference designator for every top-side component
    independent of whatever silk graphics (if any) it authored. Each glyph
    stroke of N points contributes (N - 1) straight interpolations (one
    moveto + (N-1) linetos, per _add_silk_polys)."""
    return sum(len(stroke) - 1
               for stroke in board_font.render(ref).polylines)


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
    # 1 authored line + P1's own reference-designator strokes (K17, additive —
    # _silk_board's component always has ref "P1", which always gets a
    # designator regardless of which primitive this test exercises).
    expected = 1 + _refdes_straight_count()
    assert n_straight == expected, f"line should be one straight draw, got {n_straight}"


def test_silk_circle_emits_true_full_circle_arc():
    # A circle is a SINGLE true-circle arc (start==end full-circle form), never a
    # sampled polygon.
    text = _fsilk(_silk_board([{"layer": "F.SilkS", "kind": "circle",
                                "center": [0, 0], "radius": 1.5, "width": 0.15}]))
    arcs, n_straight = _silk_draws(text)
    assert len(arcs) == 1, f"circle must be exactly one arc, got {len(arcs)}"
    start, end, center, _mode = arcs[0]
    assert start == end, "a full circle is emitted as a start==end 360-deg arc"
    # radius ~1.5 about the placed centre, board (5, 5) -> GERBER (5, -5): fab
    # files are Y-UP while the board model is Y-DOWN (gerber._Geometry
    # .to_gerber_frame, bug 019fa8011555).
    assert abs(math.hypot(start[0] - center[0], start[1] - center[1]) - 1.5) < 1e-3
    assert abs(center[0] - 5.0) < 1e-3 and abs(center[1] + 5.0) < 1e-3


def test_silk_circle_not_decomposed_into_segments():
    # Regression guard: the true circle must NOT decompose into many short straight
    # segments (the polygon-flatten failure this gate exists to prevent). The only
    # straight draws present must be P1's own designator strokes (K17, additive) —
    # NONE attributable to the circle itself.
    _full, _partial, n_straight = _silk_signature(
        _fsilk(_silk_board([{"layer": "F.SilkS", "kind": "circle",
                             "center": [0, 0], "radius": 1.5, "width": 0.15}])))
    assert n_straight == _refdes_straight_count(), \
        "circle was flattened into straight segments"


def test_silk_poly_emits_closed_path():
    text = _fsilk(_silk_board([{"layer": "F.SilkS", "kind": "poly",
                                "points": [[-1, -1], [1, -1], [1, 1], [-1, 1]],
                                "width": 0.15}]))
    arcs, n_straight = _silk_draws(text)
    assert arcs == [], "a poly must not emit an arc"
    # 4 corners closed back to the first -> 4 straight interpolations, PLUS
    # P1's own reference-designator strokes (K17, additive).
    expected = 4 + _refdes_straight_count()
    assert n_straight == expected, f"expected a closed 4-segment path, got {n_straight}"


def test_silk_three_point_arc_emits_true_arc():
    # Modern KiCad 7/8 (start, mid, end) form. start(-1,0) mid(0,1) end(1,0):
    # circumcentre (0,0) -> placed board (5,5), radius 1; the mid bulges to +y in
    # the BOARD frame. Emitted coordinates are GERBER frame (Y-UP), so both the
    # centre and the mid appear negated in y — one conversion, in
    # gerber._Geometry.to_gerber_frame (bug 019fa8011555). The arc still passes
    # THROUGH its mid point, which is what this test is really about; a
    # conversion that moved the coordinates but not the chirality would break it.
    text = _fsilk(_silk_board([{"layer": "F.SilkS", "kind": "arc",
                                "points": [[-1, 0], [0, 1], [1, 0]], "width": 0.15}]))
    arcs, _n_straight = _silk_draws(text)
    assert len(arcs) == 1, f"a three-point arc must emit one true arc, got {len(arcs)}"
    start, end, center, mode = arcs[0]
    # Centre == circumcircle centre (placed local (0,0) -> board (5,5)).
    assert abs(center[0] - 5.0) < 1e-3 and abs(center[1] + 5.0) < 1e-3, \
        f"arc centre {center} != circumcentre board (5,5) -> gerber (5,-5)"
    # The arc passes THROUGH the mid point (placed local (0,1) -> board (5,6)).
    mx, my = _arc_midpoint(start, end, center, mode)
    assert abs(mx - 5.0) < 1e-2 and abs(my + 6.0) < 1e-2, \
        f"arc geometric midpoint {(mx, my)} does not pass through mid board (5,6)"


def test_silk_three_point_arc_not_flattened():
    # The R3 not-flattened guard: the three-point arc is a genuine arc, NOT a
    # polyline of straight segments. The only straight draws present must be
    # P1's own designator strokes (K17, additive) — NONE attributable to the arc.
    full, partial, n_straight = _silk_signature(
        _fsilk(_silk_board([{"layer": "F.SilkS", "kind": "arc",
                             "points": [[-1, 0], [0, 1], [1, 0]], "width": 0.15}])))
    assert (full, partial) == (0, 1), "three-point arc must be one partial arc"
    assert n_straight == _refdes_straight_count(), \
        "three-point arc was flattened into straight segments"


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
    # Excellon shares the GERBER frame with the copper it belongs to, so the
    # board-frame y is negated (gerber._Geometry.to_gerber_frame, bug
    # 019fa8011555) — a drill file in a different frame from its own copper would
    # put every hole at the mirror of its pad.
    assert (5.0, -5.0) in pth and (5.0, -5.0) not in npth      # TH pin
    assert (10.0, -10.0) in pth and (10.0, -10.0) not in npth  # via
    assert (8.0, -8.0) in pth and (8.0, -8.0) not in npth      # pth_holes entry
    # The non-plated mounting hole (@2,20) lands in NPTH ONLY.
    assert (2.0, -20.0) in npth and (2.0, -20.0) not in pth


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


@pytest.mark.parametrize("layer", ["F.SilkS", "B.SilkS"])
def test_dropped_silk_warns_about_the_layer_it_was_actually_on(layer):
    """A dropped silk primitive names ITS OWN layer, not a hardcoded front.

    ``_silk_ref`` tagged every silk warning "F.SilkS" from when that was the
    only layer the emitter harvested. CP2 S3 routed bottom graphics through the
    same function and the hardcode survived it, so a malformed B.SilkS primitive
    reported a defect on the layer it is not on. A diagnostic that points at the
    wrong side of the board is worse than a vague one: it is actionable and
    wrong, and it sends the reader to inspect artwork that is fine.

    Parametrised over both layers rather than testing only the bug's side —
    fixing the bottom case by breaking the top one would otherwise pass.
    """
    board = _silk_board([{"layer": layer, "kind": "circle",
                          "center": [0, 0], "radius": 0, "width": 0.15}])
    result = gerber.build_gerbers(board, name="conf")
    warns = [d for d in result.diagnostics if d.code == "silk_primitive_unemitted"]
    assert warns, f"degenerate {layer} circle must warn, not vanish"
    assert warns[0].source_ref.detail == layer, (
        f"warning for a {layer} primitive names "
        f"{warns[0].source_ref.detail!r} instead")


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


# ---------------------------------------------------------------------------
# Roundrect corner-ratio default resolution (019fa73a4f88): the raw/loose-dict
# entry point NEVER goes through compile_board, so it can carry no resolved
# default — an unauthored ratio must now fail CLOSED at the shared pad_source
# guard rather than being silently defaulted to 0.25 by either emitter (design
# call (b): fail-closed at pad_source._require_faithful_shape).
# ---------------------------------------------------------------------------


def test_smd_roundrect_no_authored_rratio_fails_closed_both_emitters():
    board = _pad_board("roundrect")  # rratio omitted entirely -> corner_rratio absent
    with pytest.raises(ValueError, match="corner_rratio"):
        gerber.build_gerbers(board, name="conf")
    with pytest.raises(ValueError, match="corner_rratio"):
        kicad.generate(board, base_name="conf")


def test_th_roundrect_no_authored_rratio_fails_closed_both_emitters():
    # An OBLONG TH land is shapeable (roundrect qualifies), so it runs through the
    # SAME corner_rratio gate as SMD — an unauthored ratio must fail closed here
    # too, not just on the copper-land branch.
    board = _th_pad_board(w=2.0, h=1.0, shape="roundrect")  # corner_rratio omitted
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


# ===========================================================================
# ROTATED FULLY-ROUNDED LAND — gerber-writer drops the rotation (019f9af6e899).
#
# gerber-writer optimises a FULLY-ROUNDED RoundedRectangle down to the STANDARD
# gerber obround aperture `O,xXy`, which has NO rotation parameter, and we emit no
# %LR. Upstream gates that collapse on `angle % 90 == 0`, but an obround is
# symmetric only under 180 degrees — so at 90/270 it emitted UNSWAPPED extents and
# the land was FABRICATED AXIS-ALIGNED. The 90 survived only in the X2 attribute
# COMMENT, which is metadata no CAM tool flashes.
#
# _shape_aperture now swaps w/h for exactly that case. Because `min(w, h)` is
# swap-invariant the aperture still collapses to `O,` — it just carries the rotated
# extents. The correction is keyed on the emitted RADIUS, so it covers `oval` AND a
# `roundrect` authored at corner_rratio 0.5 (equally fully-rounded), and it lands in
# the single shared _shape_aperture branch, so COPPER (SMD + TH) and SOLDER MASK are
# all fixed at once. All three were wrong; all three are asserted here.
# ===========================================================================


def _rotate_pad(board: dict, angle: float) -> dict:
    """Bake an ABSOLUTE rotation onto a board's single pad, leaving the component at
    rotation 0 — the same injection-after-reuse trick _mask_pad_board uses, so the
    TH builder does not need its own angle parameter."""
    board["components"][0]["pads"][0]["rotation"] = angle
    return board


def test_rotated_oval_smd_land_swaps_obround_extents():
    # A 2.0 x 1.0 oval SMD land at 90 degrees is 1.0 wide and 2.0 tall. Before the
    # fix this flashed the UNROTATED '%ADD10O,2.0X1.0*%'.
    text = _fcu(_pad_board("oval", w=2.0, h=1.0, angle=90.0))
    assert "%ADD10O,1.0X2.0*%" in text
    assert "%ADD10O,2.0X1.0*%" not in text


def test_rotated_oval_th_land_swaps_obround_extents_on_both_layers():
    # The TH copper path (_add_shaped_th) shares _shape_aperture, so an oblong TH
    # land was wrong on F.Cu AND B.Cu too.
    result = gerber.build_gerbers(
        _rotate_pad(_th_pad_board(w=2.0, h=1.0, shape="oval"), 90.0), name="conf")
    for layer in ("conf-F_Cu.gbr", "conf-B_Cu.gbr"):
        assert re.search(r"%ADD\d+O,1\.0X2\.0\*%", result[layer]), (
            f"{layer} fabricates the rotated TH land axis-aligned")
        assert not re.search(r"%ADD\d+O,2\.0X1\.0\*%", result[layer])


def test_rotated_oval_mask_opening_swaps_obround_extents():
    # TRAP 2: the mask window goes through the SAME branch, so a rotated oblong land
    # got a wrong copper land AND a wrong solder-mask opening. The opening is the
    # ENLARGED copper, then rotated — so the margin is applied on the pre-swap axes.
    m = _DEFAULT_MARGIN
    text = _fmask(_mask_pad_board("oval", w=2.0, h=1.0, angle=90.0))
    assert f"%ADD10O,{1.0 + 2 * m}X{2.0 + 2 * m}*%" in text
    assert f"%ADD10O,{2.0 + 2 * m}X{1.0 + 2 * m}*%" not in text


def test_fully_rounded_roundrect_at_90_is_corrected_too():
    # TRAP 1: the defect is NOT specific to the `oval` token. A roundrect authored at
    # corner_rratio 0.5 computes radius = 0.5 * min(w, h) — just as fully rounded —
    # and hits the identical upstream collapse. A fix keyed on shape == "oval" would
    # leave this hole open, so the correction is keyed on the emitted radius.
    text = _fcu(_pad_board("roundrect", w=2.0, h=1.0, rratio=0.5, angle=90.0))
    assert "%ADD10O,1.0X2.0*%" in text
    assert "%ADD10O,2.0X1.0*%" not in text


@pytest.mark.parametrize("angle", [0.0, 180.0])
def test_axis_aligned_oval_land_is_unchanged(angle):
    # NON-REGRESSION: an obround folds under 180-degree symmetry, so 0 and 180 were
    # already correct and must keep emitting the ORIGINAL bytes. Asserted on copper
    # and mask together, since both share the branch that changed.
    m = _DEFAULT_MARGIN
    assert "%ADD10O,2.0X1.0*%" in _fcu(_pad_board("oval", w=2.0, h=1.0, angle=angle))
    assert f"%ADD10O,{2.0 + 2 * m}X{1.0 + 2 * m}*%" in \
        _fmask(_mask_pad_board("oval", w=2.0, h=1.0, angle=angle))


# ===========================================================================
# ROUND 4 — SILK LINE WIDTH: text stroke and graphic stroke are two SEPARATE
# authorities, and both emitters must read the same two.
#
# The R4 regression (F1, decision record comment 872 on 019f783860c8): ONE
# constant (gerber.SILK_LINE_WIDTH_MM = 0.15, mirrored as kicad._SILK_LINE_WIDTH_MM)
# was doing TWO jobs — reference-designator text stroke AND the fallback width for
# a footprint graphic that authors none. KiCad's shipped footprint library uses two
# different numbers for those two jobs: TEXT thickness 0.15, GRAPHIC lines 0.12
# (measured on the KiCad 10.0.5 library: 1758 graphics at 0.12 vs 24 at 0.15; 1047
# texts at 0.15). Collapsing them onto 0.15 drew every width-less footprint outline
# 25% too fat.
#
# RETARGETED IN EPOCH CP2 (Codex finding 1). S6 raised the GRAPHIC fallback
# 0.12 -> 0.15, because JLCPCB publishes a 0.15mm minimum silk line width, GC9
# now enforces it, and a default that violates our own declared floor is
# indefensible. The two constants therefore hold the SAME value today.
#
# That is a real loss of discriminating power and it is stated rather than
# papered over: no assertion on the emitted bytes can now tell which of the two
# constants fed a stroke, because both produce "0.15". What these tests can
# still prove, and now do:
#   * the emitted width is 0.15 on BOTH CAM surfaces for a width-less graphic,
#     and 0.12 appears nowhere (0.12 in the output means a stale local literal);
#   * an AUTHORED width still wins over the fallback — including the seed
#     library's authored 0.12, which is why both pinned goldens are byte-
#     unchanged by the raise;
#   * the two names remain SEPARATE bindings wired to their own authority,
#     checked at SOURCE level (_attribute_bindings), since that is the only
#     check the equal values did not render vacuous.
# ===========================================================================

from pcb_worker import kicad as _kicad


def _widthless_silk_line() -> list[dict]:
    """One F.SilkS line authoring NO width — the case the fallback governs."""
    return [{"layer": "F.SilkS", "kind": "line", "start": [-1.0, 0.0], "end": [1.0, 0.0]}]


def test_silk_text_and_graphic_widths_are_separate_constants():
    """Two authorities, currently holding one value.

    Both are 0.15 since S6. The R4 property this guards is no longer "the
    numbers differ" — it is that the two NAMES survive, so a future profile can
    move one without dragging the other. Equal values make that unprovable at
    runtime, so it is proven at source level below.
    """
    assert gerber.SILK_TEXT_WIDTH_MM == 0.15
    assert gerber.SILK_GRAPHIC_WIDTH_MM == 0.15

    # Both names must still EXIST as independent module-level bindings. A
    # re-merge (deleting one and aliasing it to the other) is the R4 regression
    # and is what this now catches in place of the value inequality.
    from pcb_worker import silk_source
    for name in ("SILK_TEXT_WIDTH_MM", "SILK_GRAPHIC_WIDTH_MM"):
        assert name in _attribute_bindings(gerber), \
            f"gerber.{name} is no longer bound from silk_source"
        assert name in _numeric_literal_bindings(silk_source), \
            (f"silk_source.{name} is no longer a declared literal — the two "
             "silk authorities must not collapse into one")


def test_silk_widths_agree_across_both_cam_emitters():
    """The cross-emitter guard the Edge.Cuts stroke never had.

    RETARGETED IN EPOCH CP2 (station S2). This used to guard a DUPLICATION:
    kicad.py carried hand-mirrored literals because gerber.py pulls in
    gerber_writer at module level and kicad.py must stay free of it, so equality
    had to be asserted or the two would silently drift — which is exactly how
    Edge.Cuts ended up 0.1 in one emitter and 0.15 in the other.

    The duplication is now GONE: silk_source owns the numbers, imports no
    gerber_writer, and both emitters (plus geometric DRC) read it. Equality is
    therefore true by construction, and a test that only asserted
    ``0.15 == 0.15`` would be a tautology dressed as a guard.

    So this now asserts the SOURCE rather than the values — that each emitter's
    name still resolves to silk_source's. Re-introducing a bare literal in
    either emitter fails here, which is the drift this test has always been
    about."""
    from pcb_worker import silk_source

    # The VALUE contract first — a plain equality that fails loudly and
    # legibly if the numbers ever diverge, whatever the mechanism.
    assert gerber.SILK_TEXT_WIDTH_MM == _kicad._SILK_TEXT_WIDTH_MM
    assert gerber.SILK_GRAPHIC_WIDTH_MM == _kicad._SILK_GRAPHIC_WIDTH_MM

    # Then the SOURCE contract, in the order of how much each check proves.
    #
    # `is` on the FLOATS is kept but DEMOTED, because the claim first written
    # here was too strong: it said a re-introduced `= 0.15` literal "is a
    # distinct object and fails this". CPython does not intern floats, so that
    # is true of CPython today — but float identity is an implementation
    # detail, not a language guarantee, and a runtime that did intern equal
    # float constants would turn this line into a silent tautology. A check
    # that can quietly stop checking is exactly the failure mode this epoch is
    # about, so it no longer carries the argument alone.
    assert gerber.SILK_TEXT_WIDTH_MM is silk_source.SILK_TEXT_WIDTH_MM
    assert gerber.SILK_GRAPHIC_WIDTH_MM is silk_source.SILK_GRAPHIC_WIDTH_MM
    assert _kicad._SILK_TEXT_WIDTH_MM is silk_source.SILK_TEXT_WIDTH_MM
    assert _kicad._SILK_GRAPHIC_WIDTH_MM is silk_source.SILK_GRAPHIC_WIDTH_MM

    # DEMOTED FURTHER IN CP2, and this is the important part. Since S6 the two
    # silk constants hold the SAME value, so every assertion above — `==` and
    # `is` alike — passes on a CROSSED wiring: bind
    # gerber.SILK_TEXT_WIDTH_MM to silk_source.SILK_GRAPHIC_WIDTH_MM and
    # nothing above notices, because both sides are the one float 0.15.
    #
    # Source is the only surviving witness of which authority each name reads,
    # so assert the binding TEXT, per name, on both emitters.
    for module, prefix in ((gerber, ""), (_kicad, "_")):
        bindings = _attribute_bindings(module)
        for name in ("SILK_TEXT_WIDTH_MM", "SILK_GRAPHIC_WIDTH_MM"):
            assert bindings.get(f"{prefix}{name}") == f"silk_source.{name}", (
                f"{module.__name__}.{prefix}{name} reads "
                f"{bindings.get(f'{prefix}{name}')!r}, not silk_source.{name} — "
                "the two silk authorities hold equal values today, so a crossed "
                "binding is invisible to every runtime check in this test")

    # FUNCTION identity, which IS a real guarantee: two `def`s are always
    # distinct objects in any Python. ONE shared width-policy implementation,
    # not two byte-identical twins.
    assert gerber._graphic_width is silk_source.graphic_width
    assert _kicad._graphic_width is silk_source.graphic_width

    # And the check that actually carries the "no re-introduced literal" claim,
    # by reading the source rather than inferring from object identity: neither
    # emitter may BIND these names to a numeric literal. Assignment from
    # silk_source (an attribute access) is the only accepted form.
    for module in (gerber, _kicad):
        for binding in _numeric_literal_bindings(module):
            assert "SILK" not in binding.upper(), (
                f"{module.__name__} binds {binding} to a numeric literal — the "
                "silk width policy belongs to silk_source, and a local literal "
                "is the drift station S2 removed")


def test_widthless_silk_graphic_emits_the_graphic_width_on_gerber():
    """A width-less silk line flashes a 0.15 circle aperture — never 0.12.

    0.15 is the S6 fallback AND the declared JLCPCB floor, so this is the
    emitted-byte proof that Minerva's own default no longer violates the rule
    GC9 enforces. A 0.12 aperture here means a stale local literal survived
    somewhere between silk_source and the file.
    """
    text = _fsilk(_silk_board(_widthless_silk_line()))
    assert "%ADD10C,0.15*%" in text, text
    # Scoped to APERTURE definitions rather than the whole file: a bare
    # "0.12 not in text" would also be reading the header and coordinate
    # stream, which is measuring the wrong thing (the _kicad_silk_lines
    # helper below documents the same trap for Edge.Cuts).
    apertures = [ln for ln in text.splitlines() if ln.startswith("%ADD")]
    assert apertures, text
    assert not any("0.12" in ln for ln in apertures), apertures


def _kicad_silk_lines(text: str) -> list[str]:
    """Just the F.SilkS fp_line rows — deliberately NOT a whole-file substring
    search. The board's Edge.Cuts rows carry their own hardcoded 0.15 stroke
    (divergence bug 019fa73b1470, fixed separately), so an unscoped "0.15 is
    absent" assertion would be measuring the wrong layer entirely."""
    return [ln for ln in text.splitlines()
            if "fp_line" in ln and 'layer "F.SilkS"' in ln]


def test_widthless_silk_graphic_emits_the_graphic_width_on_kicad():
    """Same board, same number, other emitter — read back from the .kicad_pcb."""
    silk = _kicad_silk_lines(_kicad.generate_kicad_pcb(_silk_board(_widthless_silk_line())))
    assert silk, "expected an F.SilkS fp_line"
    assert all("(width 0.15)" in ln for ln in silk), silk
    assert not any("(width 0.12)" in ln for ln in silk), silk


def test_authored_silk_width_still_wins_over_the_fallback():
    """NON-REGRESSION: the split changes only the FALLBACK. A graphic that authors
    its own width keeps it — which is why the seed library (all 0.12-authored) and
    both pinned goldens are byte-unchanged by this."""
    authored = [{"layer": "F.SilkS", "kind": "line", "start": [-1.0, 0.0],
                 "end": [1.0, 0.0], "width": 0.3}]
    assert "%ADD10C,0.3*%" in _fsilk(_silk_board(authored))
    silk = _kicad_silk_lines(_kicad.generate_kicad_pcb(_silk_board(authored)))
    assert silk and all("(width 0.3)" in ln for ln in silk), silk


def test_authored_012_survives_the_s6_fallback_raise():
    """The case the S6 raise must NOT have touched, pinned explicitly.

    Four seed footprints (R_0805, C_0805, ESP32-S3-DevKitC, TH_TestPoint)
    author 0.12 and are sha256-pinned vendored copies, so raising the fallback
    could not and did not repair them — they still emit 0.12 and still violate
    the declared 0.15 floor, which GC9 reports as an advisory. That is the
    recorded S6 disposition, not an oversight.

    It is also precisely why both pinned goldens stayed byte-identical through
    this epoch. A "fix" that clamped authored widths up to the floor would move
    every one of those bytes, so it belongs under a test rather than under a
    comment.
    """
    authored = [{"layer": "F.SilkS", "kind": "line", "start": [-1.0, 0.0],
                 "end": [1.0, 0.0], "width": 0.12}]
    assert "%ADD10C,0.12*%" in _fsilk(_silk_board(authored))
    silk = _kicad_silk_lines(_kicad.generate_kicad_pcb(_silk_board(authored)))
    assert silk and all("(width 0.12)" in ln for ln in silk), silk


def test_reference_designator_strokes_keep_the_text_width():
    """The discriminating half, rebuilt on an AUTHORED width.

    This test used to separate the two authorities using the FALLBACK: a
    width-less graphic drew 0.12 while the refdes beside it drew 0.15, so both
    apertures appeared on one layer from one component. S6 made the fallback
    0.15 too, which would leave the two indistinguishable — and a test that can
    no longer tell its two subjects apart is a vacuous test, not a passing one.

    So the graphic now AUTHORS 0.3. The emitted separation is real again: a
    refdes takes the 0.15 text policy rather than the authored 0.3 beside it.
    Because the two fallback authorities both hold 0.15 today, the separate
    executable-name pin in test_silk_source is what catches a crossed
    TEXT/GRAPHIC authority inside refdes_strokes itself.
    """
    authored = [{"layer": "F.SilkS", "kind": "line", "start": [-1.0, 0.0],
                 "end": [1.0, 0.0], "width": 0.3}]
    board = _silk_board(authored)
    board["components"][0]["ref"] = "R1"
    text = _fsilk(board)

    apertures = [ln for ln in text.splitlines() if ln.startswith("%ADD")]
    # BOTH widths present on the same layer, from the same component: the
    # authored graphic at 0.3 and the designator strokes at the text width.
    assert any("0.3*%" in ln for ln in apertures), apertures
    assert any(f"{gerber.SILK_TEXT_WIDTH_MM}*%" in ln for ln in apertures), apertures
    assert gerber.SILK_TEXT_WIDTH_MM == 0.15


# ---------------------------------------------------------------------------
# SOLDER PASTE — the stencil layers (F.Paste / B.Paste).
#
# Every number asserted below was MEASURED off KiCad 10.0.5's own Gerber export
# of the same board, never reasoned from what a stencil "should" be. The
# verification package at /home/imran/paste-verify rebuilds those measurements
# from scratch (ours and KiCad's, same compiled IR, side by side).
#
# The headline measurement, and the one most likely to be "corrected" by someone
# who knows stencil design: with NO authored paste margin, KiCad's paste aperture
# is the SAME SIZE as the copper. Not inset. A 1.6x0.8 copper land gets a 1.6x0.8
# stencil opening. Inset comes from an authored solder_paste_margin, and from
# nowhere else.
# ---------------------------------------------------------------------------


def _paste_pad_board(shape: str, *, w: float = 2.0, h: float = 1.0,
                     rratio: float | None = None,
                     paste_margin: float | None = None,
                     layers: list[str] | None = None,
                     side: str = "top") -> dict:
    """One SMD pad that participates in copper + paste on the given side."""
    face = "F" if side == "top" else "B"
    pad = {"number": "1", "type": "smd", "shape": shape,
           "position": {"x": 0, "y": 0}, "size": {"width": w, "height": h},
           "layers": layers if layers is not None else [f"{face}.Cu", f"{face}.Paste"]}
    if rratio is not None:
        pad["corner_rratio"] = rratio
    if paste_margin is not None:
        pad["solder_paste_margin"] = paste_margin
    return {
        "version": 2, "name": "conf", "width_mm": 20, "height_mm": 20,
        "layers": ["top", "bottom"],
        "design_rules": {"trace_width_mm": 0.25, "clearance_mm": 0.2,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [{"ref": "P1", "footprint": "F", "x_mm": 5, "y_mm": 5,
                        "rotation_deg": 0.0, "layer": side, "pads": [pad]}],
    }


def _layer(board: dict, suffix: str) -> str:
    return gerber.build_gerbers(board, name="conf")[f"conf-{suffix}.gbr"]


def _flash_count(text: str) -> int:
    return len(re.findall(r"D0?3\*", text))


@pytest.mark.parametrize("shape,kwargs", [
    ("rect", {}),
    ("circle", {"w": 2.0, "h": 2.0}),
    ("oval", {}),
    ("roundrect", {"rratio": 0.25}),
])
def test_paste_aperture_equals_the_copper_aperture_when_no_margin_authored(shape, kwargs):
    """THE measured rule, across every supported shape.

    With no authored paste margin the stencil aperture is BYTE-IDENTICAL to the
    copper aperture — same template letter, same dimensions, same macro. Measured
    on KiCad 10.0.5: R,1.600000X0.800000 copper -> R,1.600000X0.800000 paste;
    likewise for circle, obround and roundrect.

    This also kills the shape-flattening class on a third layer family: a fix
    that flashed every stencil opening as a rectangle passes a rect-only test and
    fails here on circle/oval/roundrect.
    """
    board = _paste_pad_board(shape, **kwargs)
    assert _aperture_defs(_layer(board, "F_Paste")) == _aperture_defs(_layer(board, "F_Cu"))


def test_paste_is_emitted_on_the_BOTTOM_side_too():
    """The discriminating case. A single-sided fixture passes with the whole
    bottom-side paste path dead, so this pins the bottom half on its own: a
    bottom-side SMD pad's stencil goes to B.Paste, and F.Paste stays empty."""
    board = _paste_pad_board("rect", side="bottom")
    assert _flash_count(_layer(board, "B_Paste")) == 1
    assert _aperture_defs(_layer(board, "B_Paste")) == _aperture_defs(_layer(board, "B_Cu"))
    assert _flash_count(_layer(board, "F_Paste")) == 0


def test_pad_that_declares_no_paste_layer_gets_no_stencil_opening():
    """Participation is read off the pad's LAYER LIST, never inferred from
    pad_type. An SMD pad the footprint put on copper+mask only contributes
    nothing to the stencil — measured: KiCad emits no paste flash for it."""
    board = _paste_pad_board("rect", layers=["F.Cu", "F.Mask"])
    assert _flash_count(_layer(board, "F_Paste")) == 0
    assert _flash_count(_layer(board, "F_Cu")) == 1


def test_through_hole_pad_gets_paste_only_when_its_footprint_declares_it():
    """Both halves measured on KiCad 10.0.5, on one board:

      * a TH pad on ``"*.Cu" "*.Mask"`` (what KiCad's shipped library actually
        declares) puts NOTHING on either paste layer;
      * the same pad on ``"*.Cu" "*.Mask" "*.Paste"`` puts its C,1.700000
        aperture on BOTH paste layers.

    So "no paste on through-hole" is a consequence of the library's layer lists,
    not a rule to hard-code — and hard-coding it would break paste-in-hole
    reflow, which is a real process. Driving off the layer list reproduces
    KiCad's behaviour on ordinary boards AND honours the deliberate case.
    """
    def th_board(layers):
        return {
            "version": 2, "name": "conf", "width_mm": 20, "height_mm": 20,
            "layers": ["top", "bottom"],
            "design_rules": {"trace_width_mm": 0.25, "clearance_mm": 0.2,
                             "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
            "components": [{"ref": "P1", "footprint": "F", "x_mm": 5, "y_mm": 5,
                            "rotation_deg": 0.0, "layer": "top",
                            "pads": [{"number": "1", "type": "thru_hole",
                                      "shape": "circle",
                                      "position": {"x": 0, "y": 0},
                                      "size": {"width": 1.7, "height": 1.7},
                                      "drill": {"x": 1.0, "y": 1.0},
                                      "layers": layers}]}],
        }

    bare = th_board(["F.Cu", "B.Cu", "F.Mask", "B.Mask"])
    assert _flash_count(_layer(bare, "F_Paste")) == 0
    assert _flash_count(_layer(bare, "B_Paste")) == 0
    assert _flash_count(_layer(bare, "F_Cu")) == 1     # copper is still there

    pasted = th_board(["F.Cu", "B.Cu", "F.Mask", "B.Mask", "F.Paste", "B.Paste"])
    assert _flash_count(_layer(pasted, "F_Paste")) == 1
    assert _flash_count(_layer(pasted, "B_Paste")) == 1
    assert "C,1.7" in _layer(pasted, "F_Paste")


def test_vias_never_get_paste():
    """Measured: a via's C,0.800000 annulus appears in F.Cu and B.Cu and in
    NEITHER paste layer. A via is not a pad and carries no footprint layer list,
    so nothing routes it to the stencil."""
    board = {
        "version": 2, "name": "conf", "width_mm": 20, "height_mm": 20,
        "layers": ["top", "bottom"],
        "design_rules": {"trace_width_mm": 0.25, "clearance_mm": 0.2,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [],
        "vias": [{"x_mm": 10.0, "y_mm": 10.0, "drill_mm": 0.4, "diameter_mm": 0.8}],
    }
    assert _flash_count(_layer(board, "F_Cu")) == 1
    assert _flash_count(_layer(board, "F_Paste")) == 0
    assert _flash_count(_layer(board, "B_Paste")) == 0


@pytest.mark.parametrize("margin,expected", [
    (-0.1, "R,1.8X0.8"),    # rect shrinks per side and STAYS a sharp rectangle
    (0.0, "R,2.0X1.0"),     # authored zero == the copper aperture exactly
])
def test_rect_paste_margin_offsets_the_copper(margin, expected):
    """Measured: rect 1.6x0.8 with margin -0.1 -> R,1.400000X0.600000. Same rule
    on this fixture's 2.0x1.0 land. An authored 0.0 must behave exactly as an
    unauthored margin, not as a special case."""
    board = _paste_pad_board("rect", paste_margin=margin)
    assert _aperture_defs(_layer(board, "F_Paste")) == [expected]


def test_positive_rect_paste_margin_rounds_the_corners():
    """Measured, and NOT guessable: growing a plain rect outward gives KiCad a
    ROUNDED rectangle whose corner radius equals the margin (rect 1.6x0.8 with
    margin +0.2 -> RoundRect radius 0.2). The outward offset of a sharp corner is
    an arc, so a fix that just scales width/height and keeps sharp corners is
    measurably wrong here."""
    board = _paste_pad_board("rect", paste_margin=0.2)
    defs = _aperture_defs(_layer(board, "F_Paste"))
    assert len(defs) == 1
    # The copper is a plain R; the stencil must NOT be.
    assert _aperture_defs(_layer(board, "F_Cu")) == ["R,2.0X1.0"]
    assert defs[0].split(",", 1)[0] == "RoundedRectangle", defs
    # gerber_writer's RoundedRectangle macro is parameterised as
    #   <half-width>X<half-height>X<inner half-extents...>X<corner DIAMETER>X...
    # so the 2.0x1.0 land grown by 0.2/side is 2.4x1.4 -> halves 1.2X0.7, and the
    # corner radius 0.2 appears as the diameter 0.4.
    assert defs[0].startswith("RoundedRectangle,1.2X0.7X"), defs
    assert "X0.4X" in defs[0], defs


def test_roundrect_paste_margin_adds_to_the_RADIUS_not_the_ratio():
    """THE trap in the offset rule, measured.

    A roundrect 1.6x0.8 at rratio 0.25 has radius 0.2. With margin +0.2 KiCad
    emits radius 0.4 -- the margin ADDED to the radius, inner corner rectangle
    held fixed. Re-applying the 0.25 ratio to the grown 2.0x1.2 outline would
    give 0.3 instead: close enough to look right, wrong on the stencil.

    So this test discriminates the correct morphological offset from the
    plausible-looking "scale the box, keep the ratio" version.
    """
    from pcb_worker.pad_source import paste_aperture

    shape, w, h, rratio = paste_aperture("roundrect", 1.6, 0.8, 0.25, 0.2, "P1", "1")
    assert shape == "roundrect"
    assert (w, h) == (pytest.approx(2.0), pytest.approx(1.2))
    assert rratio * min(w, h) == pytest.approx(0.4)     # measured KiCad radius
    assert rratio * min(w, h) != pytest.approx(0.3)     # the naive-scale answer

    # And the negative direction, also measured: radius 0.2, margin -0.1 -> 0.1.
    shape, w, h, rratio = paste_aperture("roundrect", 1.6, 0.8, 0.25, -0.1, "P1", "1")
    assert shape == "roundrect"
    assert (w, h) == (pytest.approx(1.4), pytest.approx(0.6))
    assert rratio * min(w, h) == pytest.approx(0.1)


@pytest.mark.parametrize("shape,w,h,margin,expect", [
    ("circle", 1.2, 1.2, -0.1, ("circle", 1.0, 1.0)),   # measured C,1.000000
    ("circle", 1.2, 1.2, 0.2, ("circle", 1.6, 1.6)),    # measured C,1.600000
    ("oval", 1.6, 0.8, -0.1, ("oval", 1.4, 0.6)),       # measured O,1.4X0.6
    ("oval", 1.6, 0.8, 0.2, ("oval", 2.0, 1.2)),        # measured O,2.0X1.2
])
def test_circle_and_oval_paste_margins_match_kicad(shape, w, h, margin, expect):
    """The remaining measured pairs, straight off KiCad 10.0.5's export."""
    from pcb_worker.pad_source import paste_aperture

    got = paste_aperture(shape, w, h, None, margin, "P1", "1")
    assert (got[0], round(got[1], 6), round(got[2], 6)) == expect


def test_paste_margin_that_collapses_the_aperture_fails_closed():
    """A stencil opening offset away to nothing is a dead joint, not a small
    one. Same fail-closed boundary the solder-mask path uses."""
    from pcb_worker.pad_source import PadGeometryError, paste_aperture

    with pytest.raises(PadGeometryError):
        paste_aperture("rect", 1.0, 0.5, None, -0.4, "P1", "1")


def test_authored_paste_margin_actually_reaches_the_emitter_from_the_IR():
    """THE PLUMBING TEST.

    The IR carried ``solder_paste_margin`` on PlacedPad long before anything
    could use it: PadGeom had no such field and ``placed_pad_to_geom`` dropped
    it. Any paste emitted before that was plumbed could only have been
    SYNTHESISED from the copper land — fictional geometry.

    This asserts the datum survives the whole IR-native path by its EFFECT on the
    emitted bytes: the same pad, differing only in authored margin, must produce
    different stencil apertures. A re-broken plumb makes both identical.
    """
    from pcb_worker.pad_source import PadGeom, _from_resolved

    pad = _from_resolved({"number": "1", "type": "smd", "shape": "rect",
                          "position": {"x": 0, "y": 0},
                          "size": {"width": 2.0, "height": 1.0},
                          "layers": ["F.Cu", "F.Paste"],
                          "solder_paste_margin": -0.1})
    assert isinstance(pad, PadGeom)
    assert pad.solder_paste_margin == -0.1, "the margin did not survive into PadGeom"

    plain = _aperture_defs(_layer(_paste_pad_board("rect"), "F_Paste"))
    inset = _aperture_defs(_layer(_paste_pad_board("rect", paste_margin=-0.1), "F_Paste"))
    assert plain != inset, (plain, inset)


def test_empty_paste_and_back_silk_layers_are_valid_empty_files():
    """A board with no bottom-side content still ships B.Paste and B.SilkS, as
    KiCad does. They must be REAL Gerber — format spec, units, M02* — carrying no
    apertures, not zero-length stubs and not absent."""
    files = gerber.build_gerbers(_paste_pad_board("rect"), name="conf")
    for suffix in ("B_Paste", "B_SilkS"):
        text = files[f"conf-{suffix}.gbr"]
        assert "%MOMM*%" in text, suffix
        assert re.search(r"%FSLAX\d\dY\d\d\*%", text), suffix
        assert text.strip().endswith("M02*"), suffix
        assert "%ADD" not in text, f"{suffix} should carry no apertures:\n{text}"


def test_fab_layer_is_still_not_emitted():
    """F.Fab stays OUT. KiCad's own .gbrjob classifies it AssemblyDrawing,Top —
    KiCad itself says it is not a fabrication layer. Adding paste must not have
    dragged the whole documentation set along with it."""
    files = gerber.build_gerbers(_paste_pad_board("rect"), name="conf")
    assert not any("Fab" in name for name in files), sorted(files)
