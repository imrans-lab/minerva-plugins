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

from . import board_model
from .geometry import (
    is_top as _is_top,
    place_point as _transform_point,
    rotate_local_offset as _rotate,
)
from .pad_source import iter_pads, placed_pad_to_geom, th_land
from .resolved_board import (
    ArcGeometry,
    CircleGeometry,
    Diagnostic,
    DiagnosticSeverity,
    EntityKind,
    HoleKind,
    LineGeometry,
    PlacedGraphic,
    PolygonGeometry,
    ProfileOutline,
    RectOutline,
    ResolvedBoard,
    RoundHole,
    Side,
    SourceRef,
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
DEFAULT_MASK_CLEARANCE_MM = 0.1   # per-side growth of a mask opening over its pad
SILK_LINE_WIDTH_MM = 0.15
SILK_COURTYARD_MARGIN_MM = 0.5    # box drawn around a component's pad extent
EDGE_CUTS_WIDTH_MM = 0.1

# Gerber output layer filenames (suffixes appended to the board base name).
_GERBER_SUFFIXES = ("F_Cu", "B_Cu", "F_Mask", "B_Mask", "F_SilkS", "Edge_Cuts")


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
    w = _opt_num(graphic.get("width"))
    return w if (w is not None and w > 0) else SILK_LINE_WIDTH_MM


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
    (``d == 2 * cross``): ``d > 0`` means the a->b->c turn is COUNTER-clockwise
    (gerber '+'/CCW), ``d < 0`` clockwise (gerber '-'). Returns ``None`` when the
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
    points, with chirality taken from the a->b->c turn in the gerber Y-up frame
    (consistent with the legacy convention). Only when the three points are
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
            # KiCad legacy arc 'angle' is measured in KiCad's Y-DOWN frame; the
            # gerber is plotted in board coords with no Y-flip, so the sweep
            # chirality INVERTS relative to gerber's Y-up CCW convention. A KiCad
            # negative 'angle' must therefore emit as a CW ('-') gerber arc and a
            # positive one as CCW ('+'). Empirically verified: the DIP-6 pin-1
            # notch (center,start,angle=-180) must bulge INTO the body (+y here),
            # which is CW/'-'; the opposite ('+') mirrors it outside the body.
            # Pinned by test_legacy_arc_bulges_into_body.
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
        # Traces per side: (x1, y1, x2, y2, width)
        self.traces_top: list[tuple[float, float, float, float, float]] = []
        self.traces_bot: list[tuple[float, float, float, float, float]] = []
        # Drill hits: (x, y, diameter, plated?)
        self.holes: list[tuple[float, float, float, bool]] = []
        # Silk courtyard boxes (top side, components WITHOUT graphics only):
        # (cx, cy, half_w, half_h)
        self.silk_boxes: list[tuple[float, float, float, float]] = []
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

    def warn(self, code: str, message: str, ref: SourceRef) -> None:
        self.diagnostics.append(
            Diagnostic(DiagnosticSeverity.WARNING, code, message, ref))


def _pad_mask_margin(pad, mask_clearance: float) -> float:
    """The effective per-side solder-mask margin for one pad: the pad's own
    ``solder_mask_margin`` when present, else the board's global clearance. The
    RAW type/finiteness of a per-pad margin is already vetted fail-closed in
    pad_source (_require_valid_solder_mask_margin), so here it is a float|None."""
    return pad.solder_mask_margin if pad.solder_mask_margin is not None else mask_clearance


def _mask_dim(base: float, margin: float, ref: Any, number: Any) -> float:
    """Enlarge a copper dimension by the mask margin (per side), failing CLOSED if
    the opening collapses to <= 0 (e.g. a large-negative margin) — that is not a
    manufacturable mask window. A merely-negative margin whose opening stays > 0
    is a legitimate KiCad mask-sliver feature and IS accepted."""
    dim = base + 2 * margin
    if dim <= 0:
        raise ValueError(
            f"component {ref!r} pad {number!r}: solder-mask opening dimension "
            f"{dim} <= 0 (margin {margin}) — fail-closed")
    return dim


def _emit_pads(g: _Geometry, pads, cx: float, cy: float, rot: float,
               top: bool, ref, mask_clearance: float) -> list[tuple[float, float]]:
    """Emit one component's pads into ``g`` — the SHARED, byte-sensitive pad path
    both the loose-dict harvest (``iter_pads(comp)``) and the IR-native harvest
    (``placed_pad_to_geom(placed)``) drive, so the two cannot diverge. ``pads`` is an
    iterable of :class:`PadGeom`; returns the pin extents for silk courtyard sizing."""
    pin_extents: list[tuple[float, float]] = []
    for pad in pads:
        ox, oy = _rotate(pad.x, pad.y, rot)
        px, py = cx + ox, cy + oy
        pin_extents.append((px, py))

        # Aperture rotation SOURCE: each pad's own ABSOLUTE rotation
        # (PlacedPad.rotation_deg — placement rot + footprint-local pad rot, baked by
        # the compiler) drives its aperture so per-pad rotation reaches fab. A pad
        # carrying no rotation falls back to the component rot (=0 under the IR's
        # identity placement) — a no-op there.
        pad_angle = pad.rotation if pad.rotation is not None else rot

        drill = pad.drill
        if drill is not None and drill > 0:
            # Through-hole pad: copper land on BOTH copper layers, mask opening on
            # both sides, drilled hole (plated unless flagged). th_land is the SHARED
            # decision (also used by kicad): a genuinely OBLONG land keeps its
            # width x height faithfully; an equal-axis land is the historical round
            # annulus (finding 019f8b7fd295). The DRILL stays round either way.
            shaped, land_shape, lw, lh, lrratio = th_land(pad)
            margin = _pad_mask_margin(pad, mask_clearance)
            if shaped:
                # Faithful oblong land on F.Cu AND B.Cu, mask opening in the same
                # aperture family enlarged per axis (no more circularizing).
                g.th_shaped.append((px, py, land_shape, lw, lh, lrratio, pad_angle))
                mw = _mask_dim(lw, margin, ref, pad.number)
                mh = _mask_dim(lh, margin, ref, pad.number)
                g.mask_top.append((px, py, land_shape, mw, mh, lrratio, pad_angle))
                g.mask_bot.append((px, py, land_shape, mw, mh, lrratio, pad_angle))
            else:
                annulus = pad.annulus or (drill * 2.0)
                g.th_annuli.append((px, py, annulus, "ComponentPad"))
                mask_d = _mask_dim(annulus, margin, ref, pad.number)
                # Round land: circular mask opening, enlarged by the per-pad margin.
                g.mask_top.append((px, py, "circle", mask_d, mask_d, None, 0.0))
                g.mask_bot.append((px, py, "circle", mask_d, mask_d, None, 0.0))
            g.holes.append((px, py, drill, pad.plated))
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
            margin = _pad_mask_margin(pad, mask_clearance)
            mw = _mask_dim(w, margin, ref, pad.number)
            mh = _mask_dim(h, margin, ref, pad.number)
            mask = (px, py, pad.shape, mw, mh, pad.corner_rratio, pad_angle)
            (g.mask_top if top else g.mask_bot).append(mask)
    return pin_extents


def _emit_silk(g: _Geometry, graphics, pin_extents: list[tuple[float, float]],
               cx: float, cy: float, rot: float, top: bool, ref) -> None:
    """Emit one component's F.SilkS — the SHARED silk path. A component with resolved
    footprint graphics gets its REAL F.SilkS outline; one without keeps the
    courtyard-box placeholder (byte-golden boards carry no graphics, so they take the
    box path unchanged). ``graphics`` is a list of graphic dicts or None. Bottom-side
    (B.SilkS) is out of scope, as in the original box code."""
    has_graphics = isinstance(graphics, list) and len(graphics) > 0
    if has_graphics:
        if top:
            for graphic in graphics:
                if isinstance(graphic, dict) and graphic.get("layer") == "F.SilkS":
                    _harvest_silk_graphic(g, cx, cy, rot, graphic, ref)
    elif top and pin_extents:
        xs = [p[0] for p in pin_extents]
        ys = [p[1] for p in pin_extents]
        half_w = (max(xs) - min(xs)) / 2 + SILK_COURTYARD_MARGIN_MM
        half_h = (max(ys) - min(ys)) / 2 + SILK_COURTYARD_MARGIN_MM
        g.silk_boxes.append(((max(xs) + min(xs)) / 2, (max(ys) + min(ys)) / 2,
                             max(half_w, SILK_COURTYARD_MARGIN_MM),
                             max(half_h, SILK_COURTYARD_MARGIN_MM)))


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
        g.mask_top.append((hx, hy, "circle", mask_d, mask_d, None, 0.0))
        g.mask_bot.append((hx, hy, "circle", mask_d, mask_d, None, 0.0))
    elif plated:
        g.warn("plated_hole_no_annulus_copper",
               f"plated hole {key}[{idx}] at ({hx}, {hy}) has no annulus_mm — "
               f"drilled but NO copper ring emitted (author annulus_mm)",
               SourceRef(EntityKind.HOLE, f"{key}[{idx}]", f"({hx}, {hy})"))


def _harvest(board: dict, mask_clearance: float) -> _Geometry:
    g = _Geometry()

    dr = board.get("design_rules") or {}
    if not isinstance(dr, dict):
        dr = {}
    dr_trace_w = _num(dr.get("trace_width_mm"), DEFAULT_TRACE_WIDTH_MM)
    dr_via_dia = _num(dr.get("via_diameter_mm"), DEFAULT_VIA_DIAMETER_MM)
    dr_via_drill = _num(dr.get("via_drill_mm"), DEFAULT_VIA_DRILL_MM)

    # --- Components: pads (SMD + TH), silk courtyards. ---
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
        pin_extents = _emit_pads(g, iter_pads(comp, require_smd_size=True),
                                 cx, cy, rot, top, ref, mask_clearance)
        _emit_silk(g, comp.get("graphics"), pin_extents, cx, cy, rot, top, ref)

    # --- Vias: copper annulus on both layers + plated drill. ---
    for via in _list(board.get("vias")):
        if not isinstance(via, dict):
            continue
        vx, vy = _num(via.get("x_mm")), _num(via.get("y_mm"))
        dia = _opt_num(via.get("diameter_mm")) or dr_via_dia
        drill = _opt_num(via.get("drill_mm")) or dr_via_drill
        g.th_annuli.append((vx, vy, dia, "ViaPad"))
        # Vias are tented by default -> no mask opening (matches the spike).
        g.holes.append((vx, vy, drill, True))

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

    return g


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
        layer.add_pad(_smd_aperture(shape, w, h, rratio), (px, py), angle)


def _shape_aperture(shape: str, w: float, h: float, rratio: float | None, func: str):
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
                     (KiCad's rratio convention; default 0.25 when unspecified).
                     A zero/absent radius degenerates to a plain Rectangle.
      * rect (and any unknown shape) -> Rectangle.
    """
    if shape == "circle":
        return Circle(w, func)
    if shape == "oval":
        return RoundedRectangle(w, h, min(w, h) / 2.0, func)
    if shape == "roundrect":
        ratio = rratio if rratio is not None else 0.25
        radius = ratio * min(w, h)
        if radius > 0:
            return RoundedRectangle(w, h, radius, func)
    return Rectangle(w, h, func)


def _smd_aperture(shape: str, w: float, h: float, rratio: float | None):
    """Copper-layer wrapper over _shape_aperture (func="SMDPad,CuDef"). Kept as a
    named entry for the copper path + the conformance unit test."""
    return _shape_aperture(shape, w, h, rratio, "SMDPad,CuDef")


def _add_annuli(layer: DataLayer, annuli) -> None:
    for (px, py, dia, func) in annuli:
        layer.add_pad(Circle(dia, func), (px, py))


def _add_shaped_th(layer: DataLayer, pads) -> None:
    # Oblong through-hole copper LANDS, flashed on BOTH copper layers (a TH pad's
    # copper is present on F.Cu and B.Cu). Reuses the SMD copper aperture family
    # (func="ComponentPad,CuDef" — the TH copper function) so a shaped land keeps
    # both extents faithfully instead of collapsing to a round annulus.
    for (px, py, shape, w, h, rratio, angle) in pads:
        layer.add_pad(_shape_aperture(shape, w, h, rratio, "ComponentPad,CuDef"),
                      (px, py), angle)


def _add_traces(layer: DataLayer, traces) -> None:
    for (x1, y1, x2, y2, w) in traces:
        layer.add_trace_line((x1, y1), (x2, y2), w, "Conductor")


def _add_mask(layer: DataLayer, openings) -> None:
    # ONE code path for SMD + TH mask openings: the opening uses the SAME aperture
    # family as its copper (via _shape_aperture, func=""), enlarged by the mask
    # margin. TH annuli arrive as shape "circle" (w==h==annulus+2*margin).
    for (px, py, shape, w, h, rratio, angle) in openings:
        layer.add_pad(_shape_aperture(shape, w, h, rratio, ""), (px, py), angle)


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


def _rect_path(cx: float, cy: float, half_w: float, half_h: float) -> GPath:
    p = GPath()
    p.moveto((cx - half_w, cy - half_h))
    p.lineto((cx + half_w, cy - half_h))
    p.lineto((cx + half_w, cy + half_h))
    p.lineto((cx - half_w, cy + half_h))
    p.lineto((cx - half_w, cy - half_h))
    return p


def _build_gerber_layers(board: dict, g: _Geometry, creation_date: str) -> dict[str, str]:
    min_x, min_y, max_x, max_y = board_model.board_bounds(board)

    out: dict[str, str] = {}

    # F.Cu
    f_cu = DataLayer("Copper,L1,Top,Signal", negative=False)
    _add_smd(f_cu, g.smd_pads, top_wanted=True)
    _add_annuli(f_cu, g.th_annuli)
    _add_shaped_th(f_cu, g.th_shaped)
    _add_traces(f_cu, g.traces_top)
    out["F_Cu"] = _dump(f_cu, creation_date)

    # B.Cu
    b_cu = DataLayer("Copper,L2,Bot,Signal", negative=False)
    _add_smd(b_cu, g.smd_pads, top_wanted=False)
    _add_annuli(b_cu, g.th_annuli)
    _add_shaped_th(b_cu, g.th_shaped)
    _add_traces(b_cu, g.traces_bot)
    out["B_Cu"] = _dump(b_cu, creation_date)

    # F.Mask
    f_mask = DataLayer("Soldermask,Top", negative=False)
    _add_mask(f_mask, g.mask_top)
    out["F_Mask"] = _dump(f_mask, creation_date)

    # B.Mask
    b_mask = DataLayer("Soldermask,Bot", negative=False)
    _add_mask(b_mask, g.mask_bot)
    out["B_Mask"] = _dump(b_mask, creation_date)

    # F.SilkS — real footprint silk (line/circle/poly/arc) for components with
    # resolved graphics; courtyard box placeholder for the rest (gerber-writer
    # has no glyph/text primitive; real reference-designator text is future
    # scope, unrelated to this round).
    f_silks = DataLayer("Legend,Top", negative=False)
    for (cx, cy, hw, hh) in g.silk_boxes:
        f_silks.add_traces_path(_rect_path(cx, cy, hw, hh), SILK_LINE_WIDTH_MM, "")
    _add_silk_lines(f_silks, g.silk_lines)
    _add_silk_circles(f_silks, g.silk_circles)
    _add_silk_polys(f_silks, g.silk_polys)
    _add_silk_arcs(f_silks, g.silk_arcs)
    out["F_SilkS"] = _dump(f_silks, creation_date)

    # Edge.Cuts — closed board-outline rectangle from origin + width/height.
    edge = DataLayer("Profile,NP")
    hw = (max_x - min_x)
    hh = (max_y - min_y)
    profile = GPath()
    profile.moveto((min_x, min_y))
    profile.lineto((min_x + hw, min_y))
    profile.lineto((min_x + hw, min_y + hh))
    profile.lineto((min_x, min_y + hh))
    profile.lineto((min_x, min_y))
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
# Public entry point.
# ---------------------------------------------------------------------------


def _placed_graphic_to_dict(graphic: PlacedGraphic) -> dict:
    """A board-ABSOLUTE :class:`PlacedGraphic` -> the silk-graphic dict
    ``_harvest_silk_graphic`` reads. Byte-identical to the retiring adapter's
    projection; under the IR's identity component placement the silk transform is a
    no-op so the absolute coords pass through. Coordinates are LISTS."""
    geom = graphic.geometry
    out: dict = {"layer": graphic.layer.id}
    if isinstance(geom, LineGeometry):
        out["kind"] = "line"
        out["start"] = [geom.a[0], geom.a[1]]
        out["end"] = [geom.b[0], geom.b[1]]
    elif isinstance(geom, CircleGeometry):
        out["kind"] = "circle"
        out["center"] = [geom.center[0], geom.center[1]]
        out["radius"] = geom.radius_mm
    elif isinstance(geom, ArcGeometry):
        out["kind"] = "arc"
        out["points"] = [[geom.start[0], geom.start[1]], [geom.mid[0], geom.mid[1]],
                         [geom.end[0], geom.end[1]]]
    elif isinstance(geom, PolygonGeometry):
        out["kind"] = "poly"
        out["points"] = [[p[0], p[1]] for p in geom.points]
    else:  # pragma: no cover - GraphicGeometry is a closed union
        raise TypeError(f"unsupported graphic geometry {type(geom)!r}")
    if graphic.width_mm is not None:
        out["width"] = graphic.width_mm
    return out


def _ir_outline_frame(outline) -> tuple[float, float, float, float]:
    """(origin_x, origin_y, width_mm, height_mm) of a ResolvedBoard outline — the IR
    board frame for Edge.Cuts + bounds. A ProfileOutline degrades to its outer
    contour's axis-aligned bounding box (as the retiring adapter did)."""
    if isinstance(outline, RectOutline):
        return outline.origin[0], outline.origin[1], outline.width_mm, outline.height_mm
    if isinstance(outline, ProfileOutline):
        pts: list[tuple[float, float]] = []
        for seg in outline.outer.segments:
            if isinstance(seg, LineGeometry):
                pts.extend((seg.a, seg.b))
            elif isinstance(seg, ArcGeometry):
                pts.extend((seg.start, seg.mid, seg.end))
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        return min(xs), min(ys), max(xs) - min(xs), max(ys) - min(ys)
    raise TypeError(f"unsupported board outline {type(outline)!r}")


# Board-hole class -> the (key, default_plated) the shared hole path uses, in the
# SAME order the loose-dict harvest iterates (mounting, then npth, then pth).
_IR_HOLE_ORDER = (
    (HoleKind.MOUNTING, "mounting_holes"),
    (HoleKind.NPTH, "npth_holes"),
    (HoleKind.PTH, "pth_holes"),
)


def _harvest_ir(board: ResolvedBoard, mask_clearance: float) -> _Geometry:
    """IR-NATIVE geometry harvest: read a :class:`ResolvedBoard` DIRECTLY into the
    flattened :class:`_Geometry`, with NO IR->loose-dict adapter (C5). Byte-identical
    to ``_harvest(ir_to_board_dict(board))`` — it drives the SAME shared emission
    (:func:`_emit_pads` / :func:`_emit_silk` / :func:`_emit_board_hole`) with the
    component at IDENTITY placement (position is already board-absolute in the IR
    PlacedPad), pinned by the emitter byte-equivalence test."""
    g = _Geometry()

    for comp in board.components:
        top = comp.placement.side is Side.TOP
        ref = comp.ref
        number_of = {p.source_id: p.number for p in board.footprint_for(comp).pads}
        pads = [placed_pad_to_geom(p, number_of.get(p.source_id, ""))
                for p in comp.placed_pads]
        pin_extents = _emit_pads(g, pads, 0.0, 0.0, 0.0, top, ref, mask_clearance)
        # Pass ALL placed graphics (NOT pre-filtered to F.SilkS): _emit_silk's
        # has-graphics check is layer-agnostic and its internal F.SilkS filter does
        # the selecting — exactly as the loose-dict path does. Pre-filtering here
        # would make a component with non-F.SilkS graphics (e.g. F.Fab/F.CrtYd only)
        # fall to the courtyard-box branch instead of emitting no silk (Fable C5a).
        graphics = [_placed_graphic_to_dict(gr) for gr in comp.placed_graphics]
        _emit_silk(g, graphics, pin_extents, 0.0, 0.0, 0.0, top, ref)

    for via in board.vias:
        g.th_annuli.append((via.position[0], via.position[1], via.diameter_mm, "ViaPad"))
        g.holes.append((via.position[0], via.position[1], via.drill_mm, True))

    for trace in board.traces:
        for seg in trace.segments:
            bucket = g.traces_top if _is_top(seg.layer.id) else g.traces_bot
            bucket.append((seg.a[0], seg.a[1], seg.b[0], seg.b[1], seg.width_mm))

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
    return g


def build_gerbers_ir(board: ResolvedBoard, out_dir: str | None = None,
                     name: str | None = None,
                     creation_date: str | None = None) -> GerberResult:
    """Compile a :class:`ResolvedBoard` (K2 IR) into fabrication files DIRECTLY — the
    IR-native fab entry the live path uses, with no IR->loose-dict adapter (C5).
    Byte-identical to ``build_gerbers(ir_to_board_dict(board))`` (emitter
    byte-equivalence test)."""
    # FAIL-CLOSED seal (carried from the retiring ir_to_board_dict): a captured
    # feature the gerber bridge does not map — a copper zone or a board-level graphic
    # — must RAISE, never vanish silently from a fabrication-bound file. compile_board
    # fail-closes zone/board-graphic DECLARATIONS today, so these are always empty;
    # the seal guards against a future IR silently dropping copper at fabrication.
    if board.zones:
        raise ValueError(
            f"build_gerbers_ir: board has {len(board.zones)} zone(s) the gerber bridge "
            f"does not map yet — refusing to emit fabrication that silently drops copper")
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

    ox, oy, width_mm, height_mm = _ir_outline_frame(board.outline)
    outline_dict = {"width_mm": width_mm, "height_mm": height_mm,
                    "origin": {"x_mm": ox, "y_mm": oy}}

    files: dict[str, str] = {}
    for suffix, text in _build_gerber_layers(outline_dict, g, date).items():
        files[f"{base}-{suffix}.gbr"] = text
    for suffix, text in _build_drill_files(g, date).items():
        files[f"{base}-{suffix}.drl"] = text

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

    The board dict is always the IR/placed dict produced by
    ``ir_adapter.ir_to_board_dict`` (identity component placement, board-absolute
    pad positions): each pad's own ``rotation`` — the ABSOLUTE combined angle the
    compiler baked into ``PlacedPad.rotation_deg`` — drives its copper/mask
    aperture, so per-pad rotation reaches fab.
    """
    base = name or (board_dict.get("name") if isinstance(board_dict.get("name"), str) else None) or "board"
    date = creation_date or PINNED_CREATION_DATE

    set_generation_software("Minerva", "pcb_worker/gerber.py", WORKER_VERSION)

    dr = board_dict.get("design_rules") or {}
    mask_clearance = DEFAULT_MASK_CLEARANCE_MM
    if isinstance(dr, dict):
        mc = _opt_num(dr.get("solder_mask_clearance_mm"))
        if mc is not None and mc >= 0:
            mask_clearance = mc

    g = _harvest(board_dict, mask_clearance)

    files: dict[str, str] = {}
    for suffix, text in _build_gerber_layers(board_dict, g, date).items():
        files[f"{base}-{suffix}.gbr"] = text
    for suffix, text in _build_drill_files(g, date).items():
        files[f"{base}-{suffix}.drl"] = text

    if isinstance(out_dir, str) and out_dir.strip():
        import os
        os.makedirs(out_dir, exist_ok=True)
        for fname, text in files.items():
            with open(os.path.join(out_dir, fname), "w", encoding="utf-8") as fh:
                fh.write(text)

    return GerberResult(files, diagnostics=g.diagnostics)
