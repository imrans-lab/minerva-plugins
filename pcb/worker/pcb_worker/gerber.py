"""Fabrication-output generation: Gerber (RS-274X/X2) + Excellon drill files.

Pure Python, NO KiCad binary. The Gerber layers are produced by the pinned
``gerber-writer`` library (0.4.3.3 — Karel Tavernier / Ucamco, the format's own
spec author); the two Excellon drill files are emitted by this module directly,
because gerber-writer has ZERO drill support (confirmed by the validation spike,
pcb/spikes/gerber/REPORT.md — there is no drill module in the package at all).

This is the productionised successor of the spike's hand-built generate.py: it
compiles the *canonical board model* (board_model.load_board dict — the same
schema kicad.py consumes) into fabrication outputs, rather than hard-coding one
board's geometry against the library API.

Decisions carried from the spike (see docs/gerbers.md for the full rationale):

  * Coordinate format is NOT pinned to 4.6. gerber-writer self-declares
    ``%FSLAX_Y_*%`` from each layer's actual extent (3 integer digits for a
    board under ~1000 mm, so a 40x30 board emits ``%FSLAX36Y36*%``). This is
    fully RS-274X-legal — the format is self-describing and any consumer MUST
    read the %FS line. We do NOT override it; goldens are therefore only
    byte-portable at a fixed board size + library version (documented).
  * X2 attributes are emitted as backward-compatible ``G04 #@! TF...*`` /
    ``TA...*`` comment-attributes (gerber-writer's form), not ``%TF...*%``
    extended commands. Both are spec-legal; pygerber parses the comment form
    into a structured attribute dict. Interop note in docs/gerbers.md.
  * COORDINATE FRAME. The board model carries KiCad's file frame, which grows Y
    DOWNWARD; Gerber and Excellon are Y-UP. This module converts BOARD -> GERBER
    exactly once, in ``_Geometry.to_gerber_frame`` at the end of the harvest (the
    board outline, which does not pass through ``_Geometry``, converts alongside
    it in ``_build_gerber_layers``). Everything upstream of that boundary —
    including arc chirality — is board-frame; everything downstream is gerber
    frame. Read ``to_gerber_frame``'s docstring before touching a coordinate:
    emitting board Y unconverted mirrored every layer AND left rotated copper
    turned the wrong way (bug 019fa8011555).
  * PTH/NPTH split is OURS to own (Excellon has no first-class per-hole plated
    flag; the traditional convention is two separate files). Plated holes come
    from through-hole pads (pin.drill_mm) and vias; non-plated from board-level
    mounting holes / npth_holes, or any pad/hole flagged ``plated: false``.

Determinism: the only volatile bytes gerber-writer emits are the
``TF.CreationDate`` timestamp; this module pins it (SOURCE_DATE_EPOCH-style) so
output is byte-reproducible for golden comparison. Callers who want a real
wall-clock stamp pass ``creation_date=...``.
"""

from __future__ import annotations

import json
import re
from typing import Any

from gerber_writer import (
    Circle,
    DataLayer,
    Path as GPath,
    Rectangle,
    RoundedRectangle,
    set_generation_software,
)

from . import board_model, stroke_font
from .fab_capability import EDGE_CUTS_WIDTH_MM
from .footprint_def import ReferenceTextDefinition
from .geometry import (
    is_top as _is_top,
    place_point as _transform_point,
    rotate_local_offset as _rotate,
)
from .ir_projection import graphic_to_dict, outline_frame
from .pad_source import (
    DEFAULT_MASK_CLEARANCE_MM,
    has_paste,
    is_through_hole,
    iter_pads,
    mask_opening_dim,
    pad_mask_margin,
    paste_aperture,
    placed_pad_to_geom,
    require_th_annulus,
    resolve_global_mask_clearance,
    th_land,
)
from .resolved_board import (
    Diagnostic,
    DiagnosticSeverity,
    EntityKind,
    HoleKind,
    ResolvedBoard,
    RoundHole,
    Side,
    SourceRef,
    ZoneKind,
)

WORKER_VERSION = "0.2.0"  # tracks plugin manifest / methods.WORKER_VERSION

# Reproducible-build sentinel: pins the otherwise-wall-clock TF.CreationDate /
# Excellon CREATED_BY stamp so byte-golden comparison is stable. Overridable via
# the creation_date argument (pass a real ISO timestamp for a dated artifact).
PINNED_CREATION_DATE = "1970-01-01T00:00:00"

# --- Geometry defaults. The SMD pad-size PLACEHOLDER is GONE (Stage 2 step
# 4a-ii, bug 019f7736b236): a sizeless SMD pad now fails closed in pad_source
# (iter_pads(require_smd_size=True) below) instead of flashing a nominal
# rectangle. The via/trace/mask/silk/edge nominals below are genuine board-level
# defaults (overridable via design_rules), not per-pad placeholders. ---
DEFAULT_VIA_DIAMETER_MM = 0.8
DEFAULT_VIA_DRILL_MM = 0.4
DEFAULT_TRACE_WIDTH_MM = 0.25
# Copper clearance nominal, read ONLY by the raw loose-dict path's job-file
# design-rule block when the board authors no `design_rules.clearance_mm`. It is
# the value the canonical board-source contract documents (docs/board-yaml.md).
# The compiled IR path never reaches this: it reports the RESOLVED rule minimums
# off the ResolvedBoard, which carry the selected manufacturer profile's floor.
DEFAULT_CLEARANCE_MM = 0.2
# DEFAULT_MASK_CLEARANCE_MM is owned by pad_source (imported above) so both CAM
# emitters share one raw-board default; re-exported here for back-compat callers.
# --- Silk line widths: TWO constants, because KiCad's shipped footprint library
# uses TWO different numbers and one constant cannot say both (F1, decision record
# comment 872 on 019f783860c8). Measured on the KiCad 10.0.5 shipped library
# (Resistor_SMD/Capacitor_SMD/Package_QFP, 272 footprints): silk GRAPHIC strokes
# are 0.12 (1758 occurrences vs 24 at 0.15); silk TEXT thickness is 0.15 (1047
# occurrences, dominant). Following the LIBRARY is the ratified convention — the
# virgin-board `board_design_settings.defaults.silk_line_width` is a per-project
# authored value that varies board to board and is NOT the convention to match.
#
# These are FALLBACKS only: a graphic that AUTHORS a positive width keeps it
# (see _graphic_width). The seed library authors 0.12 explicitly, so the split
# is byte-neutral on today's fixtures — it governs width-less sources.
SILK_TEXT_WIDTH_MM = 0.15
SILK_GRAPHIC_WIDTH_MM = 0.12
# Back-compat alias for the historical single name. It means the TEXT width (its
# original 0.15 value); every graphic-line consumer reads SILK_GRAPHIC_WIDTH_MM.
SILK_LINE_WIDTH_MM = SILK_TEXT_WIDTH_MM
# EDGE_CUTS_WIDTH_MM is owned by fab_capability (imported above) and re-exported
# here under its historical name so every call site below is byte-unchanged. It
# is NOT defined here, unlike the silk widths: the silk pair has to be mirrored
# in kicad.py because gerber.py drags gerber_writer, whereas fab_capability
# imports nothing and BOTH emitters can read it directly. One number, no mirror,
# no cross-emitter equality test needed — the outline family in ir_parity
# compares it against what each emitter actually wrote.

# Reference-designator TEXT geometry (K17: silk must carry "R1", not just
# outline graphics — gerber-writer has no text primitive, so this is drawn
# stroke geometry; see stroke_font.py). Stroke WIDTH is SILK_TEXT_WIDTH_MM: a
# designator IS text, so it takes the library's TEXT thickness (0.15), not the
# graphic-line width (0.12) — that distinction is exactly why the one constant
# these used to share had to be split.
REFDES_TEXT_SIZE_MM = 1.0
# Local (component-frame) anchor, mirroring kicad.py's own hard-pinned
# designator offset precedent: `(fp_text reference ... (at 0 -1.5) ...)`.
REFDES_LOCAL_Y_MM = -1.5

# Gerber output layer filenames (suffixes appended to the board base name).
# KiCad's default fab plot set minus F.Fab (which KiCad's own .gbrjob classifies
# as AssemblyDrawing, i.e. not a fabrication layer). Pinned to
# fab_capability.EMITTED_GERBER_SUFFIXES by the drift test.
_GERBER_SUFFIXES = ("F_Cu", "B_Cu", "F_Paste", "B_Paste", "F_SilkS", "B_SilkS",
                    "F_Mask", "B_Mask", "Edge_Cuts")


class GerberResult(dict):
    """The ``{filename: content}`` files mapping (UNCHANGED semantics — it IS the
    files dict every caller already indexes / iterates) that ALSO carries the
    emitter's capability-conformance diagnostics as a side channel.

    K3 gate (019f8a44484f comment 628): a fab feature that was captured but not
    emitted must never vanish SILENTLY. build_gerbers returns this so callers can
    surface WARNING diagnostics (dropped silk primitives, arc approximations,
    malformed drill features) without any change to the file bytes or to the ~20
    callers that treat the return as a plain ``dict[str, str]``.

    CAVEAT (matters for the R5 KiCad emitter that copies this pattern): ``.copy()``
    returns a PLAIN ``dict`` — the ``diagnostics`` side channel is dropped. Read
    ``.diagnostics`` off the value build_gerbers returned, not off a copy of it.
    """

    def __init__(self, *args: Any, diagnostics: list[Diagnostic] | None = None,
                 **kwargs: Any) -> None:
        super().__init__(*args, **kwargs)
        self.diagnostics: list[Diagnostic] = list(diagnostics or [])


# ---------------------------------------------------------------------------
# Small typed helpers over the loosely-typed board dict (mirrors kicad.py).
# ---------------------------------------------------------------------------


def _num(v: Any, default: float = 0.0) -> float:
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else default


def _opt_num(v: Any) -> float | None:
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def _list(v: Any) -> list:
    return v if isinstance(v, list) else []


# _is_top / _rotate / _transform_point moved to geometry.py (single source of the
# component-placement transform); imported above as back-compat aliases so existing
# internal callers and drc's historical ``from .gerber import ...`` keep resolving.


def _graphic_width(graphic: dict) -> float:
    """Stroke width for one silk GRAPHIC primitive (line/arc/circle/poly).

    Authored width wins; a width-less source falls back to the library GRAPHIC
    width (0.12), NOT the text width. kicad._graphic_width is the byte-identical
    twin and reads the same constant, so the two emitters cannot drift."""
    w = _opt_num(graphic.get("width"))
    return w if (w is not None and w > 0) else SILK_GRAPHIC_WIDTH_MM


# Collinearity epsilon for the 3-point-arc circumcentre. Points are board mm; a
# genuine silk arc has a triangle signed-area (|d|) many orders above this, while
# collinear/coincident points drive it to ~0 (infinite-radius circle => a line).
_ARC_COLLINEAR_EPS = 1e-9
# The signed-area epsilon is absolute, so a NEAR-collinear triple can still solve
# to a huge-but-finite radius whose centre falls outside the plottable board range
# and would overflow the gerber 4.6 coordinate format. Any arc past this radius is
# physically a straight silk stroke — fall back to a polyline (cosmetic fail-safe).
_ARC_MAX_RADIUS_MM = 1.0e4


def _circumcenter(a: tuple[float, float], b: tuple[float, float],
                  c: tuple[float, float]) -> tuple[tuple[float, float], float] | None:
    """Circumcentre of the triangle (a, b, c) and its orientation denominator.

    Returns ``(center, d)`` where ``d`` is twice the signed area of a->b->c
    (``d == 2 * cross``): ``d > 0`` means the a->b->c turn is in the
    INCREASING-angle direction of the frame the points are given in ('+'), ``d < 0``
    the decreasing one ('-'). Points reach here in the BOARD frame, so the caller's
    '+'/'-' is a board-frame chirality; _Geometry.to_gerber_frame converts it along
    with the coordinates. Returns ``None`` when the
    three points are collinear or coincident (infinite radius — caller falls back
    to a polyline, since an arc through collinear points IS a line).
    """
    ax, ay = a
    bx, by = b
    cx, cy = c
    d = 2.0 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
    if abs(d) < _ARC_COLLINEAR_EPS:
        return None
    a2 = ax * ax + ay * ay
    b2 = bx * bx + by * by
    c2 = cx * cx + cy * cy
    ux = (a2 * (by - cy) + b2 * (cy - ay) + c2 * (ay - by)) / d
    uy = (a2 * (cx - bx) + b2 * (ax - cx) + c2 * (bx - ax)) / d
    return (ux, uy), d


def _silk_ref(ref: Any) -> SourceRef:
    """A GRAPHIC SourceRef tagged with the owning component ref (or a sentinel
    when the board component carries none). entity_id must be non-empty."""
    rid = ref if isinstance(ref, str) and ref else "<unknown>"
    return SourceRef(EntityKind.GRAPHIC, rid, "F.SilkS")


def _harvest_silk_graphic(g: _Geometry, cx: float, cy: float, rot: float,
                          graphic: dict, ref: Any = None) -> None:
    """Transform one footprint F.SilkS graphic (component-LOCAL coords) into
    board-absolute geometry, appended to the matching ``g.silk_*`` bucket.

    Supported kinds (see footprints.py's ``_parse_graphics``): line, circle,
    poly, arc. Arc has two source forms, BOTH drawn as a TRUE gerber arc via
    gerber-writer's ``add_trace_arc``: legacy KiCad ``(center, start, angle)``
    (``points`` has 2 entries + an ``angle`` field); and the modern KiCad 7/8
    3-point ``(start, mid, end)`` form (``points`` has 3 entries, no ``angle``) —
    emitted as an arc whose centre is the circumcircle of the three transformed
    points, with chirality taken from the a->b->c turn in the BOARD frame
    (consistent with the legacy convention, and converted to the gerber frame with
    the coordinates by _Geometry.to_gerber_frame). Only when the three points are
    collinear/coincident (infinite radius) does it fall back to a polyline — an
    arc through collinear points IS a line. Silk is cosmetic, so degenerate
    forms never raise (contrast R1/R2 copper/mask, which fail closed).
    """
    kind = graphic.get("kind")
    width = _graphic_width(graphic)

    if kind == "line":
        st, en = graphic.get("start"), graphic.get("end")
        if not (isinstance(st, list) and isinstance(en, list)
                and len(st) >= 2 and len(en) >= 2):
            # Malformed endpoints — a captured silk line that cannot be emitted.
            # Cosmetic, so WARN (never fail-closed) so the drop is not silent.
            g.warn("silk_primitive_unemitted",
                   "silk line dropped: malformed start/end (need two >=2-length "
                   "points)", _silk_ref(ref))
            return
        p1 = _transform_point(cx, cy, rot, _num(st[0]), _num(st[1]))
        p2 = _transform_point(cx, cy, rot, _num(en[0]), _num(en[1]))
        g.silk_lines.append((p1[0], p1[1], p2[0], p2[1], width))

    elif kind == "circle":
        ct = graphic.get("center")
        radius = _opt_num(graphic.get("radius"))
        if not (isinstance(ct, list) and len(ct) >= 2 and radius and radius > 0):
            g.warn("silk_primitive_unemitted",
                   "silk circle dropped: non-positive radius or malformed center",
                   _silk_ref(ref))
            return
        pc = _transform_point(cx, cy, rot, _num(ct[0]), _num(ct[1]))
        g.silk_circles.append((pc[0], pc[1], radius, width))

    elif kind == "poly":
        pts = [p for p in _list(graphic.get("points")) if isinstance(p, list) and len(p) >= 2]
        if len(pts) < 2:
            g.warn("silk_primitive_unemitted",
                   "silk poly dropped: fewer than 2 valid points", _silk_ref(ref))
            return
        abs_pts = [_transform_point(cx, cy, rot, _num(p[0]), _num(p[1])) for p in pts]
        g.silk_polys.append((abs_pts, width, True))

    elif kind == "arc":
        pts = [p for p in _list(graphic.get("points")) if isinstance(p, list) and len(p) >= 2]
        angle = _opt_num(graphic.get("angle"))
        if angle is not None and angle != 0.0 and len(pts) >= 2:
            # Legacy KiCad form: pts[0] is the arc CENTER, pts[1] is the arc
            # START point, and 'angle' is the sweep (same file-coordinate
            # convention as footprint (at x y rot) — reuse _rotate() as-is).
            ccx, ccy = _num(pts[0][0]), _num(pts[0][1])
            sx, sy = _num(pts[1][0]), _num(pts[1][1])
            vx, vy = sx - ccx, sy - ccy
            if vx == 0.0 and vy == 0.0:
                g.warn("silk_primitive_unemitted",
                       "silk arc dropped: zero-length radius vector "
                       "(center coincides with start)", _silk_ref(ref))
                return
            evx, evy = _rotate(vx, vy, angle)
            ex, ey = ccx + evx, ccy + evy
            start_abs = _transform_point(cx, cy, rot, sx, sy)
            end_abs = _transform_point(cx, cy, rot, ex, ey)
            center_abs = _transform_point(cx, cy, rot, ccx, ccy)
            # Chirality is decided HERE, in the BOARD frame (Y-DOWN) that every
            # other coordinate in this harvest is also expressed in, and is
            # converted to the gerber frame ONCE by _Geometry.to_gerber_frame —
            # which flips '+'/'-' along with the Y negation, because a mirror
            # reverses handedness. Nothing about this line changed when the frame
            # boundary was introduced (bug 019fa8011555), and nothing about it
            # should: a second correction here would cancel the conversion instead
            # of composing with it. Empirically verified in the board frame: the
            # DIP-6 pin-1 notch (center,start,angle=-180) must bulge INTO the body
            # (+y in board coords), which is this '-'; the opposite ('+') mirrors it
            # outside the body. Pinned by test_legacy_arc_bulges_into_body.
            orientation = "-" if angle < 0 else "+"
            g.silk_arcs.append((start_abs, end_abs, center_abs, orientation, width))
        elif len(pts) >= 3:
            # Modern KiCad 7/8 three-point (start, mid, end) form: emit a TRUE
            # gerber arc through the circumcircle of the transformed points.
            a = _transform_point(cx, cy, rot, _num(pts[0][0]), _num(pts[0][1]))
            b = _transform_point(cx, cy, rot, _num(pts[1][0]), _num(pts[1][1]))
            c = _transform_point(cx, cy, rot, _num(pts[2][0]), _num(pts[2][1]))
            solved = _circumcenter(a, b, c)
            if solved is not None:
                center, _d = solved
                r2 = (a[0] - center[0]) ** 2 + (a[1] - center[1]) ** 2
                if r2 > _ARC_MAX_RADIUS_MM * _ARC_MAX_RADIUS_MM:
                    # Near-collinear: finite but off-board centre — treat as a line.
                    solved = None
            if solved is None:
                # Collinear / coincident / near-degenerate (infinite or off-board
                # radius). Fail-SAFE (cosmetic, not fail-closed) — fall back to the
                # polyline through the points; never risk a coordinate overflow.
                # The arc IS emitted (as its chord), but its curvature is lost, so
                # WARN that the shape was approximated (not a silent degrade).
                g.warn("silk_arc_approximated",
                       "silk 3-point arc approximated as a polyline: collinear or "
                       "off-board (infinite/huge) circumradius", _silk_ref(ref))
                g.silk_polys.append(([a, b, c], width, False))
            else:
                center, d = solved
                # d == 2*cross of a->b->c: positive => CCW turn => gerber '+';
                # negative => CW => '-'. Same Y-up chirality rule the legacy
                # (center,start,angle) branch above encodes.
                orientation = "+" if d > 0 else "-"
                g.silk_arcs.append((a, c, center, orientation, width))
        elif len(pts) >= 2:
            # 2-point arc with no mid and no angle: underspecified — draw the
            # chord as a polyline (unchanged fallback). Its curvature is
            # unknowable, so WARN that the arc was approximated (not silent).
            g.warn("silk_arc_approximated",
                   "silk 2-point arc approximated as a polyline: underspecified "
                   "(no mid point and no sweep angle)", _silk_ref(ref))
            abs_pts = [_transform_point(cx, cy, rot, _num(p[0]), _num(p[1])) for p in pts]
            g.silk_polys.append((abs_pts, width, False))


# ---------------------------------------------------------------------------
# Board -> intermediate geometry (side-tagged so we can build both copper /
# both mask layers in one pass).
# ---------------------------------------------------------------------------


class _Geometry:
    """Flattened, absolute-coordinate geometry harvested from a board dict."""

    def __init__(self) -> None:
        # SMD pads: (x, y, w, h, angle, top?, shape, corner_rratio)
        self.smd_pads: list[tuple[float, float, float, float, float, bool, str, float | None]] = []
        # Through-hole pads / vias copper annuli (ROUND land): (x, y, diameter, function)
        self.th_annuli: list[tuple[float, float, float, str]] = []
        # Through-hole pads with a genuinely OBLONG copper land (th_land shaped):
        # (x, y, shape, w, h, corner_rratio, angle). Flashed as a SHAPED land on BOTH
        # copper layers (a TH pad's copper is present on F.Cu and B.Cu), reusing the
        # SMD _shape_aperture family so a 1.2x2.0 land keeps both extents instead of
        # collapsing to a round annulus (finding 019f8b7fd295). Round drill unchanged.
        self.th_shaped: list[tuple[float, float, str, float, float, float | None, float]] = []
        # Mask openings on each side, ONE uniform tuple built through
        # _shape_aperture (R2): (x, y, shape, w, h, corner_rratio, angle). SMD
        # openings carry the pad's own shape + enlarged dims; a TH annulus arrives
        # as shape "circle" with w==h==annulus+2*margin, rratio None, angle 0.
        self.mask_top: list[tuple] = []
        self.mask_bot: list[tuple] = []
        # SOLDER-PASTE stencil apertures per side, in the SAME uniform tuple the
        # mask buckets use — (x, y, shape, w, h, corner_rratio, angle) — so paste
        # flashes go through the one shared _shape_aperture branch that copper and
        # mask already use. Membership is per-PAD layer participation (pad_source.
        # has_paste), never inferred from pad_type, and the dims come from
        # pad_source.paste_aperture (the copper land offset by the pad's authored
        # solder_paste_margin; identical to the copper aperture when unauthored).
        self.paste_top: list[tuple] = []
        self.paste_bot: list[tuple] = []
        # Traces per side: (x1, y1, x2, y2, width)
        self.traces_top: list[tuple[float, float, float, float, float]] = []
        self.traces_bot: list[tuple[float, float, float, float, float]] = []
        # COPPER-POUR fill per side: one point ring per emitted region. Already
        # carved (clearance voids subtracted) and FRACTURED into self-touching
        # keyhole contours by pcb_worker.zone_fill, because the region primitive
        # these become — gerber_writer's add_region — has no hole support at all.
        # Rings only: a pour needs no width, no aperture and no per-region
        # attributes, which is why this bucket is a plain list of point lists
        # rather than the (x, y, shape, w, h, ...) tuple the flashed families use.
        self.zone_fill_top: list[list[tuple[float, float]]] = []
        self.zone_fill_bot: list[list[tuple[float, float]]] = []
        # Drill hits: (x, y, diameter, plated?)
        self.holes: list[tuple[float, float, float, bool]] = []
        # Real footprint silk (top side, components WITH graphics), harvested
        # from component["graphics"] (resolve_board) and transformed to board
        # coords with the same _rotate() convention as pads.
        self.silk_lines: list[tuple[float, float, float, float, float]] = []  # x1,y1,x2,y2,w
        self.silk_circles: list[tuple[float, float, float, float]] = []       # cx,cy,r,w
        # points, width, closed (fp_poly / mid-less arc fallback is open)
        self.silk_polys: list[tuple[list[tuple[float, float]], float, bool]] = []
        # start, end, center, orientation('+'/'-'), width
        self.silk_arcs: list[tuple[tuple[float, float], tuple[float, float],
                                   tuple[float, float], str, float]] = []
        # Capability-conformance diagnostics (K3 WARNING channel). Built in board
        # order by _harvest, so the list is deterministic. NEVER fatal here — silk
        # is cosmetic and board-level drill is an Extra passthrough; both are
        # "warned, never fatal" (contrast fabrication-critical copper/mask, which
        # fail closed upstream). A side channel only: it changes no emitted bytes.
        self.diagnostics: list[Diagnostic] = []
        # Which coordinate frame the buckets above are expressed in. Everything is
        # harvested in the BOARD frame (KiCad's file frame, Y-DOWN — see
        # geometry.py's module docstring) and converted ONCE, at the end of the
        # harvest, by :meth:`to_gerber_frame`. Guarded so a second conversion
        # cannot silently cancel the first.
        self.frame = "board"

    def warn(self, code: str, message: str, ref: SourceRef) -> None:
        self.diagnostics.append(
            Diagnostic(DiagnosticSeverity.WARNING, code, message, ref))

    def to_gerber_frame(self) -> "_Geometry":
        """BOARD frame (Y-DOWN) -> GERBER frame (Y-UP): negate every Y, in place.

        THE ONE FRAME BOUNDARY IN THE EMITTER (bug 019fa8011555). The board model
        carries KiCad's file frame, which grows Y DOWNWARD; RS-274X coordinates are
        Y-UP. Before this existed the harvest's board-frame Y went to gerber-writer
        unconverted, so every emitted layer was a vertical MIRROR of the board —
        and, worse, only the POSITIONS were mirrored: each pad's aperture ROTATION
        is already an absolute angle in the gerber sense, so a pad rotated off a
        multiple of 90 degrees had its copper rectangle turned the wrong way
        relative to where it sat (up to 60 degrees out). 0/90/180/270 were immune
        because a rectangle folds under 180-degree symmetry, which is why the whole
        suite passed over it. Pinned by
        tests/test_gerbers.py::test_aperture_rotation_agrees_with_pad_pair_bearing.

        ONLY the Y COORDINATES move. Aperture rotations are NOT negated: they are
        already gerber-frame angles, and negating both reintroduces the very
        mismatch this fixes.

        Arc CHIRALITY does move with the coordinates, because a mirror reverses
        handedness: the same three points swept the same way describe the opposite
        bulge once Y is negated. This is what retires the local compensation
        _harvest_silk_graphic used to carry ("plotted in board coords with no
        Y-flip, so the sweep chirality INVERTS") — chirality is now decided ONCE, in
        the board frame, and converted here with everything else.

        Applied at the END of the harvest (both _harvest and _harvest_ir) rather
        than at each of the nine gerber-writer write-sites, so there is exactly one
        place where the frame changes and no write-site can be added later that
        forgets it. The board OUTLINE does not pass through _Geometry — it is built
        straight from board bounds in :func:`_build_gerber_layers`, which converts
        it there with a pointer back to this method.
        """
        if self.frame != "board":
            raise ValueError(
                f"_Geometry.to_gerber_frame: geometry is already in the {self.frame!r} "
                f"frame — a second conversion would cancel the first")

        self.smd_pads = [(x, -y, w, h, a, top, shape, rr)
                         for (x, y, w, h, a, top, shape, rr) in self.smd_pads]
        self.th_annuli = [(x, -y, d, f) for (x, y, d, f) in self.th_annuli]
        self.th_shaped = [(x, -y, shape, w, h, rr, a)
                          for (x, y, shape, w, h, rr, a) in self.th_shaped]
        self.mask_top = [(x, -y, shape, w, h, rr, a)
                         for (x, y, shape, w, h, rr, a) in self.mask_top]
        self.mask_bot = [(x, -y, shape, w, h, rr, a)
                         for (x, y, shape, w, h, rr, a) in self.mask_bot]
        self.paste_top = [(x, -y, shape, w, h, rr, a)
                          for (x, y, shape, w, h, rr, a) in self.paste_top]
        self.paste_bot = [(x, -y, shape, w, h, rr, a)
                          for (x, y, shape, w, h, rr, a) in self.paste_bot]
        self.traces_top = [(x1, -y1, x2, -y2, w)
                           for (x1, y1, x2, y2, w) in self.traces_top]
        self.traces_bot = [(x1, -y1, x2, -y2, w)
                           for (x1, y1, x2, y2, w) in self.traces_bot]
        self.zone_fill_top = [[(x, -y) for (x, y) in ring] for ring in self.zone_fill_top]
        self.zone_fill_bot = [[(x, -y) for (x, y) in ring] for ring in self.zone_fill_bot]
        self.holes = [(x, -y, d, plated) for (x, y, d, plated) in self.holes]
        self.silk_lines = [(x1, -y1, x2, -y2, w)
                           for (x1, y1, x2, y2, w) in self.silk_lines]
        self.silk_circles = [(cx, -cy, r, w) for (cx, cy, r, w) in self.silk_circles]
        self.silk_polys = [([(px, -py) for (px, py) in pts], w, closed)
                           for (pts, w, closed) in self.silk_polys]
        self.silk_arcs = [((s[0], -s[1]), (e[0], -e[1]), (c[0], -c[1]),
                           "-" if orientation == "+" else "+", w)
                          for (s, e, c, orientation, w) in self.silk_arcs]

        self.frame = "gerber"
        return self


# The mask-opening collapse boundary is owned by pad_source.mask_opening_dim so BOTH
# CAM emitters (this module + kicad) fail closed at the exact same point on a
# collapsing negative per-pad solder_mask_margin (bug 019f929b1416). Kept under the
# historical private name so every call site below is byte-unchanged.
_mask_dim = mask_opening_dim


def _circle_mask(x: float, y: float, d: float) -> tuple:
    """A round, unrotated solder-mask opening of diameter ``d`` at ``(x, y)`` —
    the aperture tuple every circular mask flash shares (round TH land, NPTH
    drill-size opening, untented via). One place owns the (shape, w==h, no
    corner-ratio, 0° angle) convention so the mask emitters cannot drift."""
    return (x, y, "circle", d, d, None, 0.0)


def _emit_pads(g: _Geometry, pads, cx: float, cy: float, rot: float,
               top: bool, ref, mask_clearance: float) -> None:
    """Emit one component's pads into ``g`` — the SHARED, byte-sensitive pad path
    both the loose-dict harvest (``iter_pads(comp)``) and the IR-native harvest
    (``placed_pad_to_geom(placed)``) drive, so the two cannot diverge. ``pads`` is an
    iterable of :class:`PadGeom`."""
    for pad in pads:
        ox, oy = _rotate(pad.x, pad.y, rot)
        px, py = cx + ox, cy + oy

        # Aperture rotation SOURCE: each pad's own ABSOLUTE rotation
        # (PlacedPad.rotation_deg — placement rot + footprint-local pad rot, baked by
        # the compiler) drives its aperture so per-pad rotation reaches fab. A pad
        # carrying no rotation falls back to the component rot (=0 under the IR's
        # identity placement) — a no-op there.
        pad_angle = pad.rotation if pad.rotation is not None else rot

        drill = pad.drill
        if is_through_hole(pad):
            # An UNPLATED through-hole pad (np_thru_hole, or a pad flagged not plated)
            # is a BARE drilled hole — NO copper land (just a drill-size mask opening,
            # below), exactly as kicad emits np_thru_hole. Only a PLATED TH pad gets
            # the copper annulus / land (finding 019f8fe77068 — gerber must not invent
            # copper the kicad emitter leaves bare). The DRILL is emitted either way
            # (routed to PTH / NPTH by the plating flag). Same predicate
            # kicad._footprint uses.
            is_plated = pad.plated and pad.pad_type != "np_thru_hole"
            if is_plated:
                # th_land is the SHARED decision: a genuinely OBLONG land keeps its
                # width x height faithfully; an equal-axis land is the historical
                # round annulus (finding 019f8b7fd295). The drill stays round.
                shaped, land_shape, lw, lh, lrratio = th_land(pad)
                margin = pad_mask_margin(pad, mask_clearance)
                if shaped:
                    # Faithful oblong land on F.Cu AND B.Cu, mask opening in the same
                    # aperture family enlarged per axis (no more circularizing).
                    g.th_shaped.append((px, py, land_shape, lw, lh, lrratio, pad_angle))
                    mw = _mask_dim(lw, margin, ref, pad.number)
                    mh = _mask_dim(lh, margin, ref, pad.number)
                    g.mask_top.append((px, py, land_shape, mw, mh, lrratio, pad_angle))
                    g.mask_bot.append((px, py, land_shape, mw, mh, lrratio, pad_angle))
                    _emit_paste(g, pad, px, py, land_shape, lw, lh, lrratio,
                                pad_angle, ref)
                else:
                    # Round land: the plated TH copper ring. FAIL-CLOSED if the pad
                    # resolved no annulus — never the retired `pad.annulus or drill*2`
                    # invention (K4). The SHARED accessor keeps gerber + kicad
                    # identical on this contract.
                    annulus = require_th_annulus(pad, ref)
                    g.th_annuli.append((px, py, annulus, "ComponentPad"))
                    mask_d = _mask_dim(annulus, margin, ref, pad.number)
                    # Round land: circular mask opening, enlarged by the per-pad margin.
                    g.mask_top.append(_circle_mask(px, py, mask_d))
                    g.mask_bot.append(_circle_mask(px, py, mask_d))
                    # Stencil follows the ROUND land, not pad.shape (a defaulted-rect
                    # TH pad's copper IS a circle here — see th_land).
                    _emit_paste(g, pad, px, py, "circle", annulus, annulus, None,
                                0.0, ref)
            else:
                # UNPLATED (np_thru_hole): NO copper land — just a DRILL-size mask
                # opening on both sides, matching kicad's np_thru_hole `(size drill
                # drill)` on "*.Mask": a bare hole, mask open to the drill, no copper
                # ring (finding 019f8fe77068). Uses the literal drill (no mask margin);
                # kicad emits the SAME drill-size opening — its np_thru_hole carries an
                # explicit `(solder_mask_margin 0.0)` — so the two emitters AGREE on the
                # NPTH mask (R4d closed the earlier board-clearance divergence).
                g.mask_top.append(_circle_mask(px, py, drill))
                g.mask_bot.append(_circle_mask(px, py, drill))
            g.holes.append((px, py, drill, is_plated))
        else:
            # SMD pad on the component's own side. width/height are guaranteed
            # positive by the caller (require_smd_size — a sizeless SMD pad has
            # already raised PadGeometryError).
            w = pad.width
            h = pad.height
            g.smd_pads.append((px, py, w, h, pad_angle, top, pad.shape, pad.corner_rratio))
            # Mask opening follows the pad SHAPE (R2), enlarged per side by the
            # effective margin (per-pad solder_mask_margin, else the global
            # clearance); a large-negative margin that collapses the opening fails
            # closed in _mask_dim.
            margin = pad_mask_margin(pad, mask_clearance)
            mw = _mask_dim(w, margin, ref, pad.number)
            mh = _mask_dim(h, margin, ref, pad.number)
            mask = (px, py, pad.shape, mw, mh, pad.corner_rratio, pad_angle)
            (g.mask_top if top else g.mask_bot).append(mask)
            # Stencil aperture, from the SAME copper land the flash above used.
            _emit_paste(g, pad, px, py, pad.shape, w, h, pad.corner_rratio,
                        pad_angle, ref)


def _emit_paste(g: _Geometry, pad, px: float, py: float, shape: str,
                w: float, h: float, rratio: float | None, angle: float, ref) -> None:
    """Emit one pad's SOLDER-PASTE stencil apertures — the SHARED paste path for
    the SMD, shaped-TH and round-TH copper branches above.

    Participation is decided PER SIDE by the pad's own resolved layer list
    (``has_paste``), so a pad reaches F.Paste only if the footprint put it there.
    Nothing here keys off ``pad_type``: a through-hole pad whose footprint
    declares ``*.Paste`` gets a stencil opening (paste-in-hole reflow is real),
    and an SMD pad whose footprint omits ``F.Paste`` gets none. Both behaviours
    are measured against KiCad 10.0.5, not assumed.

    A pad on BOTH paste layers (a TH pad expanded from ``*.Paste``) flashes on
    both, matching KiCad — which is also why this cannot be folded into the
    single-sided ``top`` flag the copper path uses.

    ``shape/w/h/rratio`` is the COPPER LAND as actually emitted, not the raw pad
    fields, so the stencil can never describe copper the board does not have.
    """
    for want_top in (True, False):
        if not has_paste(pad, want_top):
            continue
        margin = pad.solder_paste_margin or 0.0
        ps, pw, ph, prr = paste_aperture(shape, w, h, rratio, margin, ref, pad.number)
        (g.paste_top if want_top else g.paste_bot).append(
            (px, py, ps, pw, ph, prr, angle))


def _emit_silk(g: _Geometry, graphics, cx: float, cy: float, rot: float,
               top: bool, ref) -> None:
    """Emit one component's F.SilkS — the SHARED silk path. A component with resolved
    footprint graphics gets its REAL F.SilkS outline; one WITHOUT graphics gets NO
    silk (K4: the procedural courtyard-box placeholder is retired — no resolved silk
    means no silk output, matching the kicad emitter, which never drew a box). A
    source that CLAIMED silk it could not emit still WARNs via _harvest_silk_graphic;
    silk-less-by-design is silent. ``graphics`` is a list of graphic dicts or None.
    Bottom-side (B.SilkS) is out of scope."""
    if not (isinstance(graphics, list) and graphics and top):
        return
    for graphic in graphics:
        if isinstance(graphic, dict) and graphic.get("layer") == "F.SilkS":
            _harvest_silk_graphic(g, cx, cy, rot, graphic, ref)


def _emit_refdes(g: _Geometry, ref: Any, cx: float, cy: float, rot: float,
                 top: bool, reference_text: ReferenceTextDefinition | None = None) -> None:
    """Emit one component's REFERENCE DESIGNATOR ("R1", "U3", ...) as F.SilkS
    stroke geometry (see stroke_font.py — gerber-writer has no text primitive,
    so a designator is drawn as open polylines, same as any other silk shape).

    Deliberately called OUTSIDE _emit_silk's graphics-present guard, and as a
    SEPARATE call, not folded into it: _emit_silk returns early when a
    footprint has no captured F.SilkS graphics at all (`if not (... and
    graphics and top)`), which is correct for outline silk (no graphics really
    does mean no outline) but would silently drop the designator too if this
    lived inside that guard — a footprint with no silk graphics must still get
    its "R1" (K17). Top-side only; B.SilkS is out of scope, matching
    _emit_silk's own documented restriction.

    ``cx, cy, rot`` are the component's REAL board placement, independent of
    whatever _emit_silk was called with for this same component: on the
    IR-native harvest (_harvest_ir) _emit_silk runs at identity (0, 0, 0)
    because PlacedGraphic geometry there is already board-absolute, but the
    designator text is rendered in glyph-LOCAL coordinates and must be placed
    by the component's actual placement transform regardless.

    ``reference_text`` (019f77fd6d69) is the footprint's OWN authored
    reference fp_text placement (``footprint_def.ReferenceTextDefinition``),
    when the IR-native harvest found one (``ResolvedBoard.footprint_for(comp)
    .reference_text``) — see ``_harvest_ir``. When given, the synthesized
    designator is drawn at the footprint's authored local anchor/rotation/size
    instead of the fixed ``REFDES_LOCAL_Y_MM`` default: glyphs are rendered
    anchored at the origin (``x0=y0=0``), then EACH point goes through the
    text's own local rotate-then-translate (``place_point`` with
    ``reference_text.position``/``.rotation_deg`` — the same primitive KiCad's
    own reader composes pad/graphic transforms with) BEFORE the component's
    placement transform (``cx, cy, rot``) — a two-step nested transform,
    because the anchor is footprint-local, not board-absolute. The default
    (``reference_text=None``, e.g. every call from the loose-dict harvest,
    which has no footprint definition to consult) keeps today's exact
    single-step placement, unchanged.
    """
    if not top:
        return
    text = ref if isinstance(ref, str) else None
    if not text or not text.strip():
        return
    if reference_text is not None:
        size = reference_text.size_mm
        rtx, rty = reference_text.position
        rt_rot = reference_text.rotation_deg
    else:
        size = REFDES_TEXT_SIZE_MM
        rtx = rty = rt_rot = None
    for stroke in stroke_font.render(text, size=size, x0=0.0,
                                     y0=(0.0 if reference_text is not None
                                         else REFDES_LOCAL_Y_MM)):
        if reference_text is not None:
            # Text-local rotate-then-translate to the footprint's authored
            # anchor, THEN the component's own board placement (see docstring).
            footprint_local = [_transform_point(rtx, rty, rt_rot, lx, ly) for (lx, ly) in stroke]
            abs_pts = [_transform_point(cx, cy, rot, lx, ly) for (lx, ly) in footprint_local]
        else:
            abs_pts = [_transform_point(cx, cy, rot, lx, ly) for (lx, ly) in stroke]
        if len(abs_pts) >= 2:
            # OPEN polyline (closed=False): a glyph stroke must NEVER gain a
            # closing segment back to its first point (unlike an authored
            # fp_poly outline, which IS meant to close). _harvest_silk_graphic
            # is not reused here for exactly this reason — it always marks a
            # "poly" kind closed=True.
            g.silk_polys.append((abs_pts, SILK_TEXT_WIDTH_MM, False))


def _emit_board_hole(g: _Geometry, key: str, idx: int, hx: float, hy: float,
                     dia: float, plated: bool, annulus: float | None,
                     mask_clearance: float) -> None:
    """Emit one board-level hole into ``g`` — the SHARED path for the loose-dict and
    IR-native harvests. Always drills; a PLATED hole with an AUTHORED annulus flashes
    the copper ring on BOTH copper layers + a matching mask opening (finding
    019f8dbb7104) — the SAME annulus the kicad thru_hole emits, no invented copper. A
    plated hole with no annulus (only reachable via a direct build_gerbers(raw dict)
    caller; the live path COMPILES first and fail-closes) drills but WARNs, never
    silent (copper is fabrication-critical)."""
    g.holes.append((hx, hy, dia, plated))
    if plated and annulus is not None and annulus > 0:
        g.th_annuli.append((hx, hy, annulus, "ComponentPad"))
        mask_d = _mask_dim(annulus, mask_clearance, f"{key}[{idx}]", "")
        g.mask_top.append(_circle_mask(hx, hy, mask_d))
        g.mask_bot.append(_circle_mask(hx, hy, mask_d))
    elif plated:
        g.warn("plated_hole_no_annulus_copper",
               f"plated hole {key}[{idx}] at ({hx}, {hy}) has no annulus_mm — "
               f"drilled but NO copper ring emitted (author annulus_mm)",
               SourceRef(EntityKind.HOLE, f"{key}[{idx}]", f"({hx}, {hy})"))
    else:
        # Unplated: no copper, but a DRILL-size mask opening on both sides — UNIFORM
        # with a footprint np_thru_hole pad and kicad's np_thru_hole (verified vs
        # pcbnew 9.0.9: an np pad IS on *.Mask and renders a size==drill opening). The
        # ratified NPTH mask rule (finding 019f901a9966).
        g.mask_top.append(_circle_mask(hx, hy, dia))
        g.mask_bot.append(_circle_mask(hx, hy, dia))


def _emit_via(g: _Geometry, vx: float, vy: float, dia: float, drill: float,
              tented_front: bool, tented_back: bool, mask_clearance: float) -> None:
    """Emit one via into ``g`` — the SHARED via path for the loose-dict and IR-native
    harvests. A via is a copper annulus (ViaPad) on both copper layers + a plated
    drill. Mask TENTING is per-side (finding 019f8fe7cbaf): a TENTED side (the
    default) has NO mask opening; an UNTENTED side exposes the annulus with a
    mask opening (dia enlarged by the board mask clearance, like a plated pad)."""
    g.th_annuli.append((vx, vy, dia, "ViaPad"))
    g.holes.append((vx, vy, drill, True))
    if not (tented_front and tented_back):
        md = _mask_dim(dia, mask_clearance, "via", f"({vx}, {vy})")
        if not tented_front:
            g.mask_top.append(_circle_mask(vx, vy, md))
        if not tented_back:
            g.mask_bot.append(_circle_mask(vx, vy, md))


def _harvest(board: dict, mask_clearance: float) -> _Geometry:
    g = _Geometry()

    dr = board.get("design_rules") or {}
    if not isinstance(dr, dict):
        dr = {}
    dr_trace_w = _num(dr.get("trace_width_mm"), DEFAULT_TRACE_WIDTH_MM)
    dr_via_dia = _num(dr.get("via_diameter_mm"), DEFAULT_VIA_DIAMETER_MM)
    dr_via_drill = _num(dr.get("via_drill_mm"), DEFAULT_VIA_DRILL_MM)

    # --- Components: pads (SMD + TH), real footprint silk. ---
    for comp in _list(board.get("components")):
        if not isinstance(comp, dict):
            continue
        cx, cy = _num(comp.get("x_mm")), _num(comp.get("y_mm"))
        rot = _num(comp.get("rotation_deg"))
        top = _is_top(comp.get("layer"))
        ref = comp.get("ref")

        # iter_pads PREFERS resolved comp["pads"] (real footprint geometry) and
        # otherwise reconstructs the per-pin fallback. require_smd_size=True is the
        # fail-closed contract: an SMD pad with no resolved/inline copper size
        # raises PadGeometryError rather than flashing a placeholder land
        # (bug 019f7736b236) — real runs resolve the board first (methods gate).
        _emit_pads(g, iter_pads(comp, require_smd_size=True),
                   cx, cy, rot, top, ref, mask_clearance)
        _emit_silk(g, comp.get("graphics"), cx, cy, rot, top, ref)
        _emit_refdes(g, ref, cx, cy, rot, top)

    # --- Vias: copper annulus on both layers + plated drill. ---
    for via in _list(board.get("vias")):
        if not isinstance(via, dict):
            continue
        vx, vy = _num(via.get("x_mm")), _num(via.get("y_mm"))
        dia = _opt_num(via.get("diameter_mm")) or dr_via_dia
        drill = _opt_num(via.get("drill_mm")) or dr_via_drill
        # Per-side tenting; DEFAULTS TENTED (no mask) when absent. The IR bridge
        # (_via_dicts) supplies tented_front/back; a legacy direct-dict caller that
        # authored the source-level `tented` key does NOT reach here (this loose path
        # reads only the per-side keys) — the live path compiles first.
        _emit_via(g, vx, vy, dia, drill, via.get("tented_front", True),
                  via.get("tented_back", True), mask_clearance)

    # --- Traces. ---
    for tr in _list(board.get("traces")):
        if not isinstance(tr, dict):
            continue
        top = _is_top(tr.get("layer"))
        w = _opt_num(tr.get("width_mm")) or dr_trace_w
        pts = [p for p in _list(tr.get("points")) if isinstance(p, dict)]
        bucket = g.traces_top if top else g.traces_bot
        for a, b in zip(pts, pts[1:]):
            bucket.append((_num(a.get("x_mm")), _num(a.get("y_mm")),
                           _num(b.get("x_mm")), _num(b.get("y_mm")), w))

    # --- Board-level non-plated / plated holes (schema Extra passthrough). ---
    # The canonical schema has no first-class mounting-hole entity yet; the
    # spike routed these through Extra keys 'mounting_holes' / 'npth_holes'.
    for key, default_plated in (("mounting_holes", False), ("npth_holes", False),
                                ("pth_holes", True)):
        for idx, hole in enumerate(_list(board.get(key))):
            if not isinstance(hole, dict):
                continue
            hx, hy = _num(hole.get("x_mm")), _num(hole.get("y_mm"))
            dia = _opt_num(hole.get("diameter_mm")) or _opt_num(hole.get("drill_mm"))
            if dia is None or dia <= 0:
                # Drill is fabrication-critical, but a board-level hole is an Extra
                # passthrough of malformed-OPTIONAL input — do NOT hard-fail. Still
                # emit no zero hole (keep the skip), but WARN so a captured-but-
                # unemitted drill feature is never silent (K3 gate).
                g.warn("drill_feature_unemitted",
                       f"drill feature dropped: {key}[{idx}] has non-positive "
                       f"diameter ({dia}) at ({hx}, {hy})",
                       SourceRef(EntityKind.HOLE, f"{key}[{idx}]",
                                 f"({hx}, {hy})"))
                continue
            # The pth_holes / npth_holes alias KEY is authoritative for plating (an
            # explicit `plated` is overridden by the key), matching Go's
            # NormalizeHoles + compile_board so no path diverges on the flag (Fable
            # D2). mounting_holes keeps its explicit plated.
            plated = (bool(hole.get("plated", default_plated))
                      if key == "mounting_holes" else default_plated)
            annulus = _opt_num(hole.get("annulus_mm"))
            _emit_board_hole(g, key, idx, hx, hy, dia, plated, annulus, mask_clearance)

    # The ONE frame boundary: everything above is harvested in the BOARD frame.
    return g.to_gerber_frame()


# ---------------------------------------------------------------------------
# Gerber layer builders (gerber-writer).
# ---------------------------------------------------------------------------


def _dump(layer: DataLayer, creation_date: str) -> str:
    """Serialise a DataLayer, pinning the volatile CreationDate for determinism."""
    text = layer.dumps_gerber()
    text = re.sub(
        r"(G04 #@! TF\.CreationDate,)[^*]*(\*)",
        lambda m: m.group(1) + creation_date + m.group(2),
        text,
        count=1,
    )
    return text + "\n"


def _add_smd(layer: DataLayer, pads, top_wanted: bool) -> None:
    # gerber-writer reuses one aperture per (shape, function); adding many pads
    # of the same size+shape collapses to a single %ADD..% (verified in the spike).
    for (px, py, w, h, angle, top, shape, rratio) in pads:
        if top != top_wanted:
            continue
        layer.add_pad(_smd_aperture(shape, w, h, rratio, angle), (px, py), angle)


# gerber-writer's own collapse threshold for "this RoundedRectangle is fully
# rounded" (writer.py, RoundedRectangle branch: TOLERANCE = 0.5e-3). Mirrored —
# not imported — because upstream declares it as a FUNCTION-LOCAL name inside the
# dump routine, so there is nothing importable to bind to. _obround_rotation_swap
# is pinned to upstream's behaviour by a canary test instead (see below).
_GW_OBROUND_TOLERANCE = 0.5e-3

# The angle is a float coming off a placed pad, so compare it with slack rather
# than by equality. NB the slack is only ever applied AFTER upstream's own exact
# `angle % 90 == 0` gate has already matched, so in practice `angle % 180` is
# exactly 0.0 or 90.0 here; the tolerance is belt-and-braces, not load-bearing.
_OBROUND_ANGLE_TOL_DEG = 1e-9


def _obround_rotation_swap(w: float, h: float, radius: float, angle: float) -> bool:
    """Does gerber-writer silently DROP this pad's rotation? (defect 019f9af6e899)

    gerber-writer optimises a FULLY-ROUNDED ``RoundedRectangle`` down to the
    STANDARD gerber obround aperture ``O,xXy`` (writer.py, the RoundedRectangle
    branch)::

        if ((min(x_size, y_size) - 2*radius) < TOLERANCE) and (angle % 90 == 0):
            ad_body = f'O,{x_size}X{y_size}'      # <- no rotation parameter
        else:
            ... aperture MACRO, which DOES carry the angle ...

    A standard aperture has no rotation parameter and we emit no ``%LR``, so the
    angle survives only in the X2 attribute COMMENT — metadata a CAM tool does not
    flash. Upstream's guard says ``angle % 90 == 0``, but an obround is symmetric
    only under 180 degrees, so at 90/270 the emitted extents are UNSWAPPED and the
    land is fabricated axis-aligned.

    True exactly for the defect set: fully rounded AND upstream will collapse AND
    the rotation is an odd multiple of 90 AND the extents actually differ. Callers
    correct it by swapping w/h into the aperture, which is sound precisely because
    ``min(w, h)`` is swap-invariant — the upstream branch condition is unchanged,
    so the aperture still collapses to ``O,``, just carrying the rotated extents.

    Deliberately NOT true for:
      * angle 0/180  — an obround folds under 180-degree symmetry; already correct.
      * angle 45 etc — upstream's ``% 90`` gate fails, so it takes the macro branch
                       and carries the angle itself. Swapping would CORRUPT it.
      * w == h       — the rotation folds away.
    """
    if w == h:
        return False
    if (min(w, h) - 2.0 * radius) >= _GW_OBROUND_TOLERANCE:
        return False           # not fully rounded: upstream emits a macro w/ angle
    if angle % 90 != 0:
        return False           # upstream's EXACT gate: macro branch, angle kept
    return abs((angle % 180.0) - 90.0) < _OBROUND_ANGLE_TOL_DEG


def _shape_aperture(shape: str, w: float, h: float, rratio: float | None, func: str,
                    angle: float):
    """Map a declared SUPPORTED_PAD_SHAPE to its faithful gerber aperture — the
    K3 capability-conformance requirement (019f7aed6d9e comment 628). Before this
    every SMD pad flashed a Rectangle, silently flattening circle/oval/roundrect.

    The SINGLE shape->aperture branch, shared by COPPER (func="SMDPad,CuDef") and
    SOLDER-MASK (func="", enlarged dims). Keeping one branch is the DRY gate — the
    mask opening MUST use the same aperture family as the copper it covers (R2:
    otherwise a circle/oval/roundrect land got a rectangular mask window, the same
    flattening class R1 killed for copper).

      * circle    -> Circle (width is the diameter).
      * oval      -> RoundedRectangle fully rounded on the short axis (an obround).
      * roundrect -> RoundedRectangle with radius = corner_rratio * min(w, h)
                     (KiCad's rratio convention). ``rratio`` is never None here for
                     a genuine roundrect pad — the default (0.25 when unauthored)
                     is resolved ONCE, upstream, onto the IR pad by
                     ``compile_board._place_component``, or fail-closed for the raw
                     loose-dict path by ``pad_source._require_faithful_shape``
                     (019fa73a4f88) — this function does not carry its own copy of
                     that default. An authored zero radius degenerates to a plain
                     Rectangle.
      * rect (and any unknown shape) -> Rectangle.

    ``angle`` is the pad's ABSOLUTE rotation — the same value the caller then hands
    to ``layer.add_pad``. It is needed HERE, at aperture-construction time, purely
    to work around gerber-writer dropping the rotation of a fully-rounded
    RoundedRectangle; see :func:`_obround_rotation_swap` (defect 019f9af6e899).

    ``angle`` is deliberately REQUIRED, not defaulted. A default would let a call
    site added later silently omit it, which does not fail any test — it just
    quietly reintroduces the severity-1 defect on that path's copper. All three
    call sites (_add_smd via _smd_aperture, _add_shaped_th, _add_mask) already
    carry the pad angle, so the parameter costs a caller nothing.
    """
    if shape == "circle":
        return Circle(w, func)

    # Both rounded families reduce to a radius, then share ONE construction point
    # below — so the rotation workaround exists in exactly one place, for copper
    # (SMD + TH) and solder mask alike. A `roundrect` authored at corner_rratio 0.5
    # is JUST as fully-rounded as an `oval` and hits the same upstream collapse, so
    # the correction is keyed on the emitted RADIUS, never on the shape token.
    radius: float | None = None
    if shape == "oval":
        radius = min(w, h) / 2.0
    elif shape == "roundrect":
        # rratio is resolved upstream (never None here for a real roundrect pad
        # that reached this function — see the docstring); no fallback lives here.
        candidate = rratio * min(w, h)
        if candidate > 0:
            radius = candidate      # authored zero degenerates to Rectangle

    if radius is not None:
        if _obround_rotation_swap(w, h, radius, angle):
            # KNOWN, ACCEPTED inconsistency: gerber-writer derives its X2 shape
            # ATTRIBUTE from the master's dimensions, so the swap also transposes
            # the comment — a 90-degree land emits `TAShape,RoundedRectangle,2.4,
            # 1.2,0.6,90.0`, which read literally describes the land the other way
            # round. Safe, and deliberately not chased here: X2 attributes are
            # METADATA that no CAM tool flashes; the FABRICATED geometry is the
            # `O,` aperture, which this swap makes correct. Fixing the attribute
            # would mean post-processing gerber-writer's output stream. Filed as
            # docket 019f9c9274d6 — do not "fix" it in this branch. That item
            # closes when gerber-writer fixes its own guard upstream, which is also
            # the moment test_gerbers.py::test_canary_gerber_writer_still_collapses
            # _fully_rounded_to_a_rotationless_obround starts failing.
            w, h = h, w
        return RoundedRectangle(w, h, radius, func)
    return Rectangle(w, h, func)


def _smd_aperture(shape: str, w: float, h: float, rratio: float | None,
                  angle: float):
    """Copper-layer wrapper over _shape_aperture (func="SMDPad,CuDef"). Kept as a
    named entry for the copper path + the conformance unit test."""
    return _shape_aperture(shape, w, h, rratio, "SMDPad,CuDef", angle)


def _add_annuli(layer: DataLayer, annuli) -> None:
    for (px, py, dia, func) in annuli:
        layer.add_pad(Circle(dia, func), (px, py))


def _add_shaped_th(layer: DataLayer, pads) -> None:
    # Oblong through-hole copper LANDS, flashed on BOTH copper layers (a TH pad's
    # copper is present on F.Cu and B.Cu). Reuses the SMD copper aperture family
    # (func="ComponentPad,CuDef" — the TH copper function) so a shaped land keeps
    # both extents faithfully instead of collapsing to a round annulus.
    for (px, py, shape, w, h, rratio, angle) in pads:
        layer.add_pad(_shape_aperture(shape, w, h, rratio, "ComponentPad,CuDef", angle),
                      (px, py), angle)


def _add_traces(layer: DataLayer, traces) -> None:
    for (x1, y1, x2, y2, w) in traces:
        layer.add_trace_line((x1, y1), (x2, y2), w, "Conductor")


def _add_zone_fill(layer: DataLayer, rings) -> None:
    """Write each pour region as ONE Gerber region graphics object.

    ``add_region`` is the only primitive in gerber-writer that emits filled
    2D area (G36/G37), and until now it had ZERO call sites in this worker —
    every other copper feature is a flashed aperture or a stroked path. Pour
    copper is the first geometry that is genuinely an arbitrary polygon.

    THE CONTOUR IS ALREADY A KEYHOLE. ``add_region`` cannot express a hole:
    ``negative=`` sets Gerber LAYER POLARITY (%LPC/%LPD), which flips whether an
    object is dark or clear — it does not punch a void into another object. So
    voids arrive here already fractured into self-touching rings by
    ``zone_fill``, one ``add_region`` per ring, all positive. This is the same
    representation KiCad's own filler produces, which is what lets the two be
    compared as copper rather than as fracture policies.

    ``lineto`` back to the start point is REQUIRED, not decorative: gerber-writer
    sets ``Path.contour`` from the last operator alone, and ``add_region``
    rejects a path whose final subpath does not close.
    """
    for ring in rings:
        if len(ring) < 3:
            # Unreachable from zone_fill (it raises on a degenerate contour), so
            # this is the belt to that braces: a 2-point "region" is a line, and
            # a fab file must never carry copper we cannot describe.
            raise ValueError(
                f"zone fill region has {len(ring)} point(s); a region needs at least 3")
        path = GPath()
        path.moveto(ring[0])
        for point in ring[1:]:
            path.lineto(point)
        path.lineto(ring[0])
        layer.add_region(path, "Conductor")


def _add_paste(layer: DataLayer, apertures) -> None:
    """Flash the stencil apertures. Same uniform tuple and the same
    ``_shape_aperture`` family as copper and mask, so a circle/oval/roundrect land
    keeps its shape on the stencil instead of collapsing to a rectangle — the R1/R2
    flattening class, closed here before it could open on a third layer family.
    ``func=""`` matches the mask path: the X2 aperture function is carried by the
    LAYER attribute (``SolderPaste,Top``), not per aperture."""
    for (px, py, shape, w, h, rratio, angle) in apertures:
        layer.add_pad(_shape_aperture(shape, w, h, rratio, "", angle), (px, py), angle)


def _add_mask(layer: DataLayer, openings) -> None:
    # ONE code path for SMD + TH mask openings: the opening uses the SAME aperture
    # family as its copper (via _shape_aperture, func=""), enlarged by the mask
    # margin. TH annuli arrive as shape "circle" (w==h==annulus+2*margin).
    for (px, py, shape, w, h, rratio, angle) in openings:
        layer.add_pad(_shape_aperture(shape, w, h, rratio, "", angle), (px, py), angle)


def _add_silk_lines(layer: DataLayer, lines) -> None:
    for (x1, y1, x2, y2, w) in lines:
        layer.add_trace_line((x1, y1), (x2, y2), w, "")


def _add_silk_circles(layer: DataLayer, circles) -> None:
    for (cx, cy, r, w) in circles:
        # start == end with a given center is gerber-writer's documented full
        # (360 deg) arc form (Path.arcto / _ArcTo docstring) — a TRUE circle,
        # not a sampled polyline.
        layer.add_trace_arc((cx + r, cy), (cx + r, cy), (cx, cy), "+", w, "")


def _add_silk_polys(layer: DataLayer, polys) -> None:
    for (pts, w, closed) in polys:
        if len(pts) < 2:
            continue
        p = GPath()
        p.moveto(pts[0])
        for pt in pts[1:]:
            p.lineto(pt)
        if closed and pts[0] != pts[-1]:
            p.lineto(pts[0])
        layer.add_traces_path(p, w, "")


def _add_silk_arcs(layer: DataLayer, arcs) -> None:
    for (start, end, center, orientation, w) in arcs:
        layer.add_trace_arc(start, end, center, orientation, w, "")


def _build_gerber_layers(board: dict, g: _Geometry, creation_date: str) -> dict[str, str]:
    min_x, min_y, max_x, max_y = board_model.board_bounds(board)

    out: dict[str, str] = {}

    # F.Cu
    f_cu = DataLayer("Copper,L1,Top,Signal", negative=False)
    _add_smd(f_cu, g.smd_pads, top_wanted=True)
    _add_annuli(f_cu, g.th_annuli)
    _add_shaped_th(f_cu, g.th_shaped)
    _add_traces(f_cu, g.traces_top)
    # Pour LAST on the layer: a Gerber layer is an ordered stream and every
    # object here is positive (dark), so the pour is additive to the pads and
    # traces it was carved around rather than something that could cover them.
    # Emitting it last also keeps the diff of a board that gains a pour confined
    # to the tail of the file.
    _add_zone_fill(f_cu, g.zone_fill_top)
    out["F_Cu"] = _dump(f_cu, creation_date)

    # B.Cu
    b_cu = DataLayer("Copper,L2,Bot,Signal", negative=False)
    _add_smd(b_cu, g.smd_pads, top_wanted=False)
    _add_annuli(b_cu, g.th_annuli)
    _add_shaped_th(b_cu, g.th_shaped)
    _add_traces(b_cu, g.traces_bot)
    _add_zone_fill(b_cu, g.zone_fill_bot)
    out["B_Cu"] = _dump(b_cu, creation_date)

    # F.Paste / B.Paste — the solder-paste stencils.
    #
    # Written UNCONDITIONALLY, including when a side has no paste at all: a board
    # with no bottom-side SMD gets a valid, aperture-less B_Paste, exactly as
    # KiCad 10.0.5 does (measured: it emits board-B_Paste.gbp for such a board).
    # A fab package whose layer is silently ABSENT is worse than one whose layer
    # is present and empty — the board house cannot distinguish "no bottom paste"
    # from "the file went missing".
    f_paste = DataLayer("SolderPaste,Top", negative=False)
    _add_paste(f_paste, g.paste_top)
    out["F_Paste"] = _dump(f_paste, creation_date)

    b_paste = DataLayer("SolderPaste,Bot", negative=False)
    _add_paste(b_paste, g.paste_bot)
    out["B_Paste"] = _dump(b_paste, creation_date)

    # F.Mask
    f_mask = DataLayer("Soldermask,Top", negative=False)
    _add_mask(f_mask, g.mask_top)
    out["F_Mask"] = _dump(f_mask, creation_date)

    # B.Mask
    b_mask = DataLayer("Soldermask,Bot", negative=False)
    _add_mask(b_mask, g.mask_bot)
    out["B_Mask"] = _dump(b_mask, creation_date)

    # F.SilkS — real footprint silk (line/circle/poly/arc) for components with
    # resolved graphics ONLY; a component without graphics contributes NO outline
    # silk (K4: the procedural courtyard-box placeholder is retired). The
    # component's reference designator (drawn stroke text, K17 — see
    # stroke_font.py; gerber-writer has no glyph/text primitive) is ADDITIVE to
    # g.silk_polys and is emitted for every top-side component regardless of
    # whether it has outline graphics at all (_emit_refdes, called outside
    # _emit_silk's graphics-present guard).
    f_silks = DataLayer("Legend,Top", negative=False)
    _add_silk_lines(f_silks, g.silk_lines)
    _add_silk_circles(f_silks, g.silk_circles)
    _add_silk_polys(f_silks, g.silk_polys)
    _add_silk_arcs(f_silks, g.silk_arcs)
    out["F_SilkS"] = _dump(f_silks, creation_date)

    # B.SilkS — STRUCTURALLY PRESENT, ALWAYS EMPTY. Read this before adding to it.
    #
    # The emitter has NO bottom-silk harvest: _emit_silk and _emit_refdes are
    # top-side only by their own documented restriction, so nothing ever reaches
    # this layer. It is written anyway, for the same reason B_Paste is: a fab
    # package that is missing one of KiCad's nine default layers is ambiguous,
    # and KiCad itself emits a valid aperture-less board-B_Silkscreen.gbo for a
    # board with no back legend.
    #
    # This file being EMPTY is NOT the same as this board having no back legend,
    # and that difference is deliberately kept loud: B.SilkS is excluded from
    # fab_capability.EMITTED_LAYERS, so a bottom-side component with captured
    # B.SilkS graphics still raises `captured_geometry_not_emitted` from the
    # compiler. Adding B.SilkS to EMITTED_LAYERS would silence that warning
    # without emitting one byte more silk — swapping a loud gap for a silent one.
    # When a real bottom-silk harvest lands, BOTH changes go in together.
    b_silks = DataLayer("Legend,Bot", negative=False)
    out["B_SilkS"] = _dump(b_silks, creation_date)

    # Edge.Cuts — closed board-outline rectangle from origin + width/height.
    #
    # The outline is the ONE piece of emitted geometry that does not pass through
    # _Geometry (it is derived from board bounds, not harvested), so it converts
    # BOARD frame -> GERBER frame right here. Same negation, same reason, same bug:
    # see :meth:`_Geometry.to_gerber_frame`. Negated PER VERTEX rather than by
    # exchanging the bounds, so the emitted path stays the exact mirror of the one
    # this always drew — same start corner, same winding — instead of silently
    # re-ordering the rectangle's vertices as well.
    edge = DataLayer("Profile,NP")
    hw = (max_x - min_x)
    hh = (max_y - min_y)
    y0, y1 = -min_y, -(min_y + hh)
    profile = GPath()
    profile.moveto((min_x, y0))
    profile.lineto((min_x + hw, y0))
    profile.lineto((min_x + hw, y1))
    profile.lineto((min_x, y1))
    profile.lineto((min_x, y0))
    edge.add_traces_path(profile, EDGE_CUTS_WIDTH_MM, "Profile")
    out["Edge_Cuts"] = _dump(edge, creation_date)

    return out


# ---------------------------------------------------------------------------
# Excellon drill files (OURS — gerber-writer has none).
# ---------------------------------------------------------------------------


def _excellon(holes: list[tuple[float, float, float]], comment: str,
              creation_date: str) -> str:
    """Emit one Excellon file: M48 header / tool table / metric decimal body.

    holes: [(x_mm, y_mm, diameter_mm)]. Tool numbers are assigned by ascending
    diameter (deterministic); hits are grouped per tool. Coordinate format is
    metric, absolute, 3.3 decimal (FMAT,2) — the same shape the spike proved.
    """
    # Dedup at the PRINTED precision (3 decimals) so two diameters differing
    # only past the emitted precision can never produce two tools with an
    # identical printed C<dia> (review note, gerber round).
    diameters = sorted({round(d, 3) for _, _, d in holes})
    tool_of = {d: i + 1 for i, d in enumerate(diameters)}

    lines = ["M48", f";{comment}",
             f";CREATED_BY=pcb_worker/gerber.py {creation_date}",
             ";FORMAT={3:3/ absolute / metric / decimal}",
             "FMAT,2", "METRIC"]
    for d in diameters:
        lines.append(f"T{tool_of[d]}C{d:.3f}")
    lines.append("%")
    lines.append("G90")
    lines.append("G05")
    # Group hits by tool (ascending tool number) for a compact, deterministic body.
    for d in diameters:
        lines.append(f"T{tool_of[d]}")
        for (x, y, hd) in holes:
            if round(hd, 3) == d:
                lines.append(f"X{x:.3f}Y{y:.3f}")
    lines.append("M30")
    return "\n".join(lines) + "\n"


def _build_drill_files(g: _Geometry, creation_date: str) -> dict[str, str]:
    pth = [(x, y, d) for (x, y, d, plated) in g.holes if plated]
    npth = [(x, y, d) for (x, y, d, plated) in g.holes if not plated]
    out: dict[str, str] = {}
    if pth:
        out["PTH"] = _excellon(pth, "PLATED THROUGH HOLES", creation_date)
    if npth:
        out["NPTH"] = _excellon(npth, "NON-PLATED HOLES", creation_date)
    return out


# ---------------------------------------------------------------------------
# Gerber X2 JOB FILE (.gbrjob) — the fabrication MANIFEST that travels with the
# layer set. Without it a board house receives a bag of files and has to guess
# the layer count, the stackup, the finished thickness and which file is which.
#
# EVERY structural decision below was MEASURED from a real KiCad 10.0.5 Gerber
# export of this repo's own spike board, not invented: the key set and ordering,
# the ProjectId GUID derivation, the FileFunction vocabulary, the Size convention,
# and the default stackup numbers. (The measurement was a dev-time comparison, NOT
# a runtime dependency — nothing here shells out to KiCad.) Where KiCad
# and the Gerber X2 spec offer a choice, KiCad wins (the ratified convention —
# decision record comment 872 on 019f783860c8).
# ---------------------------------------------------------------------------

# KiCad names the job file `<base>-job.gbrjob`, NOT `<base>.gbrjob`.
_GBRJOB_SUFFIX = "-job.gbrjob"

# (FileFunction, FilePolarity) per emitted Gerber suffix, in the JOB FILE's OWN
# vocabulary — which is NOT the same as the in-file ``TF.FileFunction`` token.
# Measured divergences (KiCad 10.0.5, same export, job vs file):
#     job "SolderPaste,Top"  <- file "Paste,Top"
#     job "SolderMask,Top"   <- file "Soldermask,Top"
#     job "Profile"          <- file "Profile,NP"
# Copper agrees. Reading the job value off the emitted layer's own function
# string would therefore produce a WRONG manifest, which is why this is an
# explicit table rather than a derivation.
#
# The paste/back-silk rows are present ahead of those layers being emitted so
# that adding them is purely a matter of producing the file: the manifest is
# built from the ACTUAL emitted file set (see _build_job_file), so an entry for
# a layer nobody emits is inert, never a phantom row.
_GBRJOB_FILE_ATTRIBUTES: dict[str, tuple[str, str]] = {
    "F_Cu": ("Copper,L1,Top", "Positive"),
    "B_Cu": ("Copper,L2,Bot", "Positive"),
    "F_Paste": ("SolderPaste,Top", "Positive"),
    "B_Paste": ("SolderPaste,Bot", "Positive"),
    "F_SilkS": ("Legend,Top", "Positive"),
    "B_SilkS": ("Legend,Bot", "Positive"),
    # Solder mask is the ONE negative-polarity layer: the file draws the
    # OPENINGS, and the manifest has to say so or the mask fabricates inverted.
    "F_Mask": ("SolderMask,Top", "Negative"),
    "B_Mask": ("SolderMask,Bot", "Negative"),
    "Edge_Cuts": ("Profile", "Positive"),
}

# Manifest ordering — KiCad's own relative order (copper, paste, legend, mask,
# profile). A stable order keeps the job file byte-reproducible.
_GBRJOB_SUFFIX_ORDER = ("F_Cu", "B_Cu", "F_Paste", "B_Paste",
                        "F_SilkS", "B_SilkS", "F_Mask", "B_Mask", "Edge_Cuts")

# Physical defaults for a v1 two-layer board. These are KiCad's own defaults, and
# they reproduce its numbers exactly: 1.6 total, 0.035 per copper layer, 0.01 per
# mask => a 1.51 dielectric, which is what KiCad wrote for the spike board.
_GBRJOB_BOARD_THICKNESS_MM = 1.6
_GBRJOB_COPPER_THICKNESS_MM = 0.035
_GBRJOB_MASK_THICKNESS_MM = 0.01
_GBRJOB_DIELECTRIC_MATERIAL = "FR4"
# KiCad writes the surface finish as "None" when the stackup declares none, and
# "rev?" as the revision when the title block carries none.
_GBRJOB_SURFACE_FINISH = "None"
_GBRJOB_REVISION = "rev?"
_GBRJOB_GUID_PAD = "X"
_GBRJOB_GUID_BYTES = 16


def _project_guid(project_file_name: str) -> str:
    """KiCad's ProjectId GUID for a project file name — its EXACT algorithm.

    Reverse-engineered from KiCad 10.0.5 output and verified byte-identical on
    four independent names (``board``/``a``/``zz``/a 26-character name, covering
    the short-pad, exact-fit and truncated cases):

      1. take the project FILE name INCLUDING the ``.kicad_pcb`` extension,
      2. right-pad with ``X`` (0x58) / truncate to 16 bytes,
      3. hex-encode (32 characters),
      4. INSERT ``4`` at index 12 and then ``9`` at index 16 — an INSERT, not a
         replace; the tail shifts right, which is the one detail that makes a
         plausible-looking reimplementation produce the wrong GUID,
      5. truncate back to 32 and format 8-4-4-4-12.

    Steps 4-5 are how KiCad forces the UUID version/variant nibbles. The result is
    a pure function of the name, so the job file stays byte-reproducible.
    """
    raw = (project_file_name.encode("utf-8")
           + _GBRJOB_GUID_PAD.encode("utf-8") * _GBRJOB_GUID_BYTES)[:_GBRJOB_GUID_BYTES]
    s = raw.hex()
    s = s[:12] + "4" + s[12:]
    s = s[:16] + "9" + s[16:]
    s = s[:32]
    return f"{s[0:8]}-{s[8:12]}-{s[12:16]}-{s[16:20]}-{s[20:32]}"


def _material_stackup(copper_names: list[str], board_thickness_mm: float) -> list[dict]:
    """KiCad's MaterialStackup for an N-copper-layer board, outside in.

    Legend / SolderPaste / SolderMask / (Copper, Dielectric)* / Copper /
    SolderMask / SolderPaste / Legend — the exact sequence and key set KiCad
    emitted for the two-layer case. The dielectric absorbs whatever the copper
    and mask do not, so the entries sum to the declared board thickness; a
    stackup too thin for its own copper clamps at zero rather than emitting a
    negative thickness a fab tool would reject.
    """
    n = len(copper_names)
    gaps = max(n - 1, 1)
    solid = n * _GBRJOB_COPPER_THICKNESS_MM + 2 * _GBRJOB_MASK_THICKNESS_MM
    dielectric = max(board_thickness_mm - solid, 0.0) / gaps
    out: list[dict] = [
        {"Type": "Legend", "Name": "Top Silk Screen"},
        {"Type": "SolderPaste", "Name": "Top Solder Paste"},
        {"Type": "SolderMask", "Thickness": _GBRJOB_MASK_THICKNESS_MM,
         "Name": "Top Solder Mask"},
    ]
    for i, cu in enumerate(copper_names):
        out.append({"Type": "Copper", "Thickness": _GBRJOB_COPPER_THICKNESS_MM,
                    "Name": cu})
        if i + 1 < n:
            nxt = copper_names[i + 1]
            out.append({
                "Type": "Dielectric",
                "Thickness": round(dielectric, 6),
                "Material": _GBRJOB_DIELECTRIC_MATERIAL,
                "Name": f"{cu}/{nxt}",
                "Notes": f"Type: dielectric layer {i + 1} (from {cu} to {nxt})",
            })
    out.extend([
        {"Type": "SolderMask", "Thickness": _GBRJOB_MASK_THICKNESS_MM,
         "Name": "Bottom Solder Mask"},
        {"Type": "SolderPaste", "Name": "Bottom Solder Paste"},
        {"Type": "Legend", "Name": "Bottom Silk Screen"},
    ])
    return out


def _ir_board_thickness(board: ResolvedBoard) -> float:
    """Finished board thickness from the IR's PHYSICAL stackup — the sum of every
    entry that declares one. Falls back to the v1 default when the stackup carries
    no thicknesses at all, so a board that never authored a stackup still gets a
    plausible manifest rather than a 0.0 mm board."""
    total = sum(entry.thickness_mm or 0.0
                for entry in board.layer_stack.stackup.entries)
    return round(total, 6) if total > 0 else _GBRJOB_BOARD_THICKNESS_MM


def _build_job_file(base: str, filenames: list[str], outline_w: float,
                    outline_h: float, clearance_mm: float,
                    min_line_width_mm: float, creation_date: str,
                    copper_names: list[str],
                    board_thickness_mm: float) -> str:
    """The ``.gbrjob`` manifest for one emitted file set.

    ``filenames`` is the ACTUAL emitted Gerber file list, so the manifest can
    never advertise a layer the fab house will not find in the package — the
    single most damaging thing a job file can get wrong.

    ``Size`` follows KiCad's convention: the outline extent GROWN BY the
    Edge.Cuts stroke width (KiCad reported 40.15 x 30.15 for this repo's 40 x 30
    spike board plotted with a 0.15 stroke), because the profile line straddles
    the nominal edge.
    """
    by_suffix = {}
    for fname in filenames:
        if fname.endswith(".gbr"):
            by_suffix[fname[len(base) + 1:-len(".gbr")]] = fname

    files_attributes = []
    for suffix in _GBRJOB_SUFFIX_ORDER:
        fname = by_suffix.get(suffix)
        if fname is None:
            continue
        function, polarity = _GBRJOB_FILE_ATTRIBUTES[suffix]
        files_attributes.append({"Path": fname, "FileFunction": function,
                                 "FilePolarity": polarity})

    job = {
        "Header": {
            "GenerationSoftware": {
                "Vendor": "Minerva",
                "Application": "pcb_worker/gerber.py",
                "Version": WORKER_VERSION,
            },
            "CreationDate": creation_date,
        },
        "GeneralSpecs": {
            "ProjectId": {
                "Name": base,
                # KiCad hashes the project FILE name, extension included.
                "GUID": _project_guid(f"{base}.kicad_pcb"),
                "Revision": _GBRJOB_REVISION,
            },
            "Size": {
                "X": round(outline_w + EDGE_CUTS_WIDTH_MM, 6),
                "Y": round(outline_h + EDGE_CUTS_WIDTH_MM, 6),
            },
            "LayerNumber": len(copper_names),
            "BoardThickness": board_thickness_mm,
            "Finish": _GBRJOB_SURFACE_FINISH,
        },
        "DesignRules": [{
            "Layers": "Outer",
            "PadToPad": clearance_mm,
            "PadToTrack": clearance_mm,
            "TrackToTrack": clearance_mm,
            "MinLineWidth": min_line_width_mm,
        }],
        "FilesAttributes": files_attributes,
        "MaterialStackup": _material_stackup(copper_names, board_thickness_mm),
    }
    return json.dumps(job, indent=2) + "\n"


# ---------------------------------------------------------------------------
# Public entry point.
# ---------------------------------------------------------------------------


# Board-hole class -> the (key, default_plated) the shared hole path uses, in the
# SAME order the loose-dict harvest iterates (mounting, then npth, then pth).
_IR_HOLE_ORDER = (
    (HoleKind.MOUNTING, "mounting_holes"),
    (HoleKind.NPTH, "npth_holes"),
    (HoleKind.PTH, "pth_holes"),
)


def _harvest_ir(board: ResolvedBoard, mask_clearance: float) -> _Geometry:
    """IR-NATIVE geometry harvest: read a :class:`ResolvedBoard` DIRECTLY into the
    flattened :class:`_Geometry`, with NO IR->loose-dict adapter (C5). It drives the
    SAME shared emission (:func:`_emit_pads` / :func:`_emit_silk` /
    :func:`_emit_board_hole`) as the loose-dict harvest, with the component at
    IDENTITY placement (position is already board-absolute in the IR PlacedPad),
    pinned by the gerber golden + oracle tests."""
    g = _Geometry()

    for comp in board.components:
        top = comp.placement.side is Side.TOP
        ref = comp.ref
        number_of = {p.source_id: p.number for p in board.footprint_for(comp).pads}
        pads = [placed_pad_to_geom(p, number_of.get(p.source_id, ""))
                for p in comp.placed_pads]
        _emit_pads(g, pads, 0.0, 0.0, 0.0, top, ref, mask_clearance)
        # Pass ALL placed graphics (NOT pre-filtered to F.SilkS): _emit_silk's
        # internal F.SilkS filter does the selecting — exactly as the loose-dict path
        # does. A component whose graphics are all non-F.SilkS (e.g. F.Fab/F.CrtYd)
        # simply emits no silk (no procedural box remains to fall back to).
        graphics = [graphic_to_dict(gr) for gr in comp.placed_graphics]
        _emit_silk(g, graphics, 0.0, 0.0, 0.0, top, ref)
        # UNLIKE _emit_silk above, the designator is NOT called at identity:
        # its geometry is glyph-LOCAL (footprint-frame), not board-absolute
        # like PlacedGraphic, so it needs the component's REAL placement
        # transform (comp.placement), applied explicitly here via the same
        # place_point (_transform_point) every other component-local
        # primitive in this worker goes through.
        #
        # 019f77fd6d69: pass the footprint's OWN authored reference-text
        # placement, when it has one, so the designator lands where the
        # footprint's author actually put it instead of always the fixed
        # default offset (see _emit_refdes's docstring for the two-step
        # transform this triggers). footprint_for is the SAME lookup the pad
        # numbering above already uses on this loop iteration.
        _emit_refdes(g, ref, comp.placement.position[0], comp.placement.position[1],
                     comp.placement.rotation_deg, top,
                     reference_text=board.footprint_for(comp).reference_text)

    for via in board.vias:
        _emit_via(g, via.position[0], via.position[1], via.diameter_mm, via.drill_mm,
                  via.tented_front, via.tented_back, mask_clearance)

    for trace in board.traces:
        for seg in trace.segments:
            bucket = g.traces_top if _is_top(seg.layer.id) else g.traces_bot
            bucket.append((seg.a[0], seg.a[1], seg.b[0], seg.b[1], seg.width_mm))

    # COPPER POURS. Only COPPER_POUR contributes copper: a KEEPOUT is a
    # prohibition on copper, not copper, so it emits nothing here — emitting it
    # would put metal exactly where the author said none may go. Its effect is
    # already baked in, as area subtracted from the pours that share its layer.
    #
    # The fill is READ, never computed here. compile_board owns it (it needs the
    # whole board to carve against), and a zone reaching a fabrication file with
    # fill=None is refused outright by build_gerbers_ir — an emitter that filled
    # its own zones would be a second filler nobody diffed against the first.
    for zone in board.zones:
        if zone.kind is not ZoneKind.COPPER_POUR or not zone.fill:
            continue
        bucket = g.zone_fill_top if _is_top(zone.layer.id) else g.zone_fill_bot
        for polygon in zone.fill:
            bucket.append([(x, y) for (x, y) in polygon.points])

    # Board holes: bucket by kind and iterate in the loose-dict harvest's order so a
    # multi-hole board's flash/drill stream is byte-identical.
    by_kind: dict[HoleKind, list] = {k: [] for k, _ in _IR_HOLE_ORDER}
    for hole in board.holes:
        by_kind[hole.kind].append(hole)
    for kind, key in _IR_HOLE_ORDER:
        for idx, hole in enumerate(by_kind[kind]):
            feature = hole.feature
            if not isinstance(feature, RoundHole):
                raise ValueError(
                    f"hole {hole.id!r} has a non-round feature {type(feature).__name__} "
                    f"the round-only fabrication path cannot drill")
            _emit_board_hole(g, key, idx, feature.position[0], feature.position[1],
                             feature.diameter_mm, hole.plated, hole.annulus_mm,
                             mask_clearance)
    # The ONE frame boundary: everything above is harvested in the BOARD frame.
    return g.to_gerber_frame()


def build_gerbers_ir(board: ResolvedBoard, out_dir: str | None = None,
                     name: str | None = None,
                     creation_date: str | None = None) -> GerberResult:
    """Compile a :class:`ResolvedBoard` (K2 IR) into fabrication files DIRECTLY — the
    IR-native fab entry the live path uses, with no IR->loose-dict adapter (C5).
    Pinned by the gerber golden + oracle (gerbonara / KiCad export) tests."""
    # FAIL-CLOSED seal (a captured feature the gerber bridge does not map — a copper
    # zone or a board-level graphic — must RAISE, never vanish silently from a
    # fabrication-bound file).
    # THIS SEAL IS LIVE FOR ZONES, not hypothetical. It used to read "compile_board
    # fail-closes zone DECLARATIONS today, so these are always empty" — true until
    # epoch 4, when compile_board began building ResolvedZone (with fill=None, i.e.
    # no computed copper). A zone now REACHES this function, and this raise is the
    # only thing stopping a board with an uncomputed pour from being emitted as
    # fabrication. Board graphics are still refused at compile, so that half of the
    # seal remains a guard against a future IR.
    unfilled = [z.id for z in board.zones
                if z.kind is ZoneKind.COPPER_POUR and z.fill is None]
    if unfilled:
        # NARROWED, not relaxed (C6). The seal used to reject ANY zone, because
        # no zone had ever carried a computed fill. Now the compiler fills pours,
        # so the condition that actually matters is FILL STATE, not presence:
        # what must never reach a fab file is a pour whose copper was never
        # computed. `fill=None` means INDETERMINATE copper; an empty tuple means
        # computed-and-empty, which is a real answer and is allowed through.
        #
        # A KEEPOUT is deliberately not checked: it emits no copper by
        # definition, so there is nothing it could silently drop. Its geometry is
        # already accounted for in the pours it carved.
        raise ValueError(
            f"build_gerbers_ir: board has {len(unfilled)} copper pour(s) with NO "
            f"computed fill ({', '.join(unfilled)}) — refusing to emit fabrication "
            f"that silently drops copper")
    if board.board_graphics:
        raise ValueError(
            f"build_gerbers_ir: board has {len(board.board_graphics)} board-level "
            f"graphic(s) the gerber bridge does not map yet — refusing to drop them silently")

    base = name or (board.name if isinstance(board.name, str) and board.name else None) or "board"
    date = creation_date or PINNED_CREATION_DATE
    set_generation_software("Minerva", "pcb_worker/gerber.py", WORKER_VERSION)

    mask_clearance = DEFAULT_MASK_CLEARANCE_MM
    mc = board.design_rules.minimums.solder_mask_clearance_mm
    if mc is not None and mc >= 0:
        mask_clearance = mc

    g = _harvest_ir(board, mask_clearance)

    ox, oy, width_mm, height_mm = outline_frame(board.outline)
    outline_dict = {"width_mm": width_mm, "height_mm": height_mm,
                    "origin": {"x_mm": ox, "y_mm": oy}}

    files: dict[str, str] = {}
    for suffix, text in _build_gerber_layers(outline_dict, g, date).items():
        files[f"{base}-{suffix}.gbr"] = text
    for suffix, text in _build_drill_files(g, date).items():
        files[f"{base}-{suffix}.drl"] = text

    # Job file (.gbrjob) — the IR path can source the REAL stackup: copper layer
    # names and the summed physical thickness come off the ResolvedBoard rather
    # than the two-layer default the loose-dict path has to assume.
    minimums = board.design_rules.minimums
    files[f"{base}{_GBRJOB_SUFFIX}"] = _build_job_file(
        base, list(files), width_mm, height_mm,
        clearance_mm=minimums.min_clearance_mm,
        min_line_width_mm=minimums.min_trace_width_mm,
        creation_date=date,
        copper_names=[layer.kicad_alias for layer in board.layer_stack.copper],
        board_thickness_mm=_ir_board_thickness(board),
    )

    if isinstance(out_dir, str) and out_dir.strip():
        import os
        os.makedirs(out_dir, exist_ok=True)
        for fname, text in files.items():
            with open(os.path.join(out_dir, fname), "w", encoding="utf-8") as fh:
                fh.write(text)

    return GerberResult(files, diagnostics=g.diagnostics)


def build_gerbers(board_dict: dict, out_dir: str | None = None,
                  name: str | None = None,
                  creation_date: str | None = None) -> GerberResult:
    """Compile a canonical board into fabrication files.

    Returns a GerberResult (a ``dict[str, str]`` subclass — a drop-in for the
    plain files dict every caller indexes / iterates) mapping {filename: content}
    for six Gerber layers (F_Cu, B_Cu, F_Mask, B_Mask, F_SilkS, Edge_Cuts) plus
    PTH.drl / NPTH.drl (each drill file emitted only when the board actually has
    holes of that class). ``.diagnostics`` carries the emitter's WARNING-channel
    capability-conformance diagnostics (empty on a clean board); it is a side
    channel and changes no file bytes.

    Filenames are ``{base}-{suffix}.gbr`` / ``{base}-PTH.drl`` where base is
    *name* (default the board's ``name`` field, else "board").

    If *out_dir* is given the files are also written there (UTF-8). Coordinate
    format is self-declared by gerber-writer per layer extent (not pinned 4.6);
    the CreationDate stamp is pinned for byte-reproducibility unless
    *creation_date* is supplied.

    This is the loose-dict entry (hand-built / legacy dicts, e.g. tests); the live
    path emits straight from the IR via :func:`build_gerbers_ir`. A placed dict
    carries board-absolute pad positions and each pad's own ``rotation`` (the
    ABSOLUTE combined angle) drives its copper/mask aperture, so per-pad rotation
    reaches fab.
    """
    base = name or (board_dict.get("name") if isinstance(board_dict.get("name"), str) else None) or "board"
    date = creation_date or PINNED_CREATION_DATE

    set_generation_software("Minerva", "pcb_worker/gerber.py", WORKER_VERSION)

    # Shared raw-board global-clearance resolver: absent -> raw default; an authored
    # value must be finite and non-negative, else fail CLOSED (bug 019f94b686b4) —
    # kicad.generate resolves it identically, so the two emitters never diverge.
    mask_clearance = resolve_global_mask_clearance(board_dict)

    g = _harvest(board_dict, mask_clearance)

    files: dict[str, str] = {}
    for suffix, text in _build_gerber_layers(board_dict, g, date).items():
        files[f"{base}-{suffix}.gbr"] = text
    for suffix, text in _build_drill_files(g, date).items():
        files[f"{base}-{suffix}.drl"] = text

    # Job file (.gbrjob). The loose-dict board carries no physical stackup, so
    # this path assumes the v1 two-layer default; the IR path reads the real one.
    dr = board_dict.get("design_rules")
    dr = dr if isinstance(dr, dict) else {}
    # Same bounds source _build_gerber_layers drew the Edge.Cuts profile from, so
    # the manifest's Size can never describe a different board than the profile.
    min_x, min_y, max_x, max_y = board_model.board_bounds(board_dict)
    files[f"{base}{_GBRJOB_SUFFIX}"] = _build_job_file(
        base, list(files), max_x - min_x, max_y - min_y,
        clearance_mm=_num(dr.get("clearance_mm"), DEFAULT_CLEARANCE_MM),
        min_line_width_mm=_num(dr.get("trace_width_mm"), DEFAULT_TRACE_WIDTH_MM),
        creation_date=date,
        copper_names=["F.Cu", "B.Cu"],
        board_thickness_mm=_GBRJOB_BOARD_THICKNESS_MM,
    )

    if isinstance(out_dir, str) and out_dir.strip():
        import os
        os.makedirs(out_dir, exist_ok=True)
        for fname, text in files.items():
            with open(os.path.join(out_dir, fname), "w", encoding="utf-8") as fh:
                fh.write(text)

    return GerberResult(files, diagnostics=g.diagnostics)
