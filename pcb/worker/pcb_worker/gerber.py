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
from .ir_projection import graphic_to_dict, outline_frame
from .pad_source import (
    DEFAULT_MASK_CLEARANCE_MM,
    is_through_hole,
    iter_pads,
    mask_opening_dim,
    pad_mask_margin,
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
# DEFAULT_MASK_CLEARANCE_MM is owned by pad_source (imported above) so both CAM
# emitters share one raw-board default; re-exported here for back-compat callers.
SILK_LINE_WIDTH_MM = 0.15
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
    # resolved graphics ONLY; a component without graphics contributes NO silk (K4:
    # the procedural courtyard-box placeholder is retired). Real reference-designator
    # text is future scope (gerber-writer has no glyph/text primitive).
    f_silks = DataLayer("Legend,Top", negative=False)
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

    for via in board.vias:
        _emit_via(g, via.position[0], via.position[1], via.diameter_mm, via.drill_mm,
                  via.tented_front, via.tented_back, mask_clearance)

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
    Pinned by the gerber golden + oracle (gerbonara / KiCad export) tests."""
    # FAIL-CLOSED seal (a captured feature the gerber bridge does not map — a copper
    # zone or a board-level graphic — must RAISE, never vanish silently from a
    # fabrication-bound file). compile_board
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

    ox, oy, width_mm, height_mm = outline_frame(board.outline)
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

    if isinstance(out_dir, str) and out_dir.strip():
        import os
        os.makedirs(out_dir, exist_ok=True)
        for fname, text in files.items():
            with open(os.path.join(out_dir, fname), "w", encoding="utf-8") as fh:
                fh.write(text)

    return GerberResult(files, diagnostics=g.diagnostics)
