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
    set_generation_software,
)

from . import board_model
from .geometry import (
    is_top as _is_top,
    place_point as _transform_point,
    rotate_local_offset as _rotate,
)
from .pad_source import iter_pads

WORKER_VERSION = "0.2.0"  # tracks plugin manifest / methods.WORKER_VERSION

# Reproducible-build sentinel: pins the otherwise-wall-clock TF.CreationDate /
# Excellon CREATED_BY stamp so byte-golden comparison is stable. Overridable via
# the creation_date argument (pass a real ISO timestamp for a dated artifact).
PINNED_CREATION_DATE = "1970-01-01T00:00:00"

# --- Documented geometry defaults (no pad geometry exists in the canonical
# board schema yet — these are placeholders, overridable per-pin via the
# schema's Extra passthrough; see docs/gerbers.md + board-yaml.md). ---
DEFAULT_SMD_PAD_W_MM = 1.0     # SMD pad width  (pin.Extra pad_width_mm overrides)
DEFAULT_SMD_PAD_H_MM = 0.6     # SMD pad height (pin.Extra pad_height_mm overrides)
DEFAULT_VIA_DIAMETER_MM = 0.8
DEFAULT_VIA_DRILL_MM = 0.4
DEFAULT_TRACE_WIDTH_MM = 0.25
DEFAULT_MASK_CLEARANCE_MM = 0.1   # per-side growth of a mask opening over its pad
SILK_LINE_WIDTH_MM = 0.15
SILK_COURTYARD_MARGIN_MM = 0.5    # box drawn around a component's pad extent
EDGE_CUTS_WIDTH_MM = 0.1

# Gerber output layer filenames (suffixes appended to the board base name).
_GERBER_SUFFIXES = ("F_Cu", "B_Cu", "F_Mask", "B_Mask", "F_SilkS", "Edge_Cuts")


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


def _harvest_silk_graphic(g: _Geometry, cx: float, cy: float, rot: float,
                          graphic: dict) -> None:
    """Transform one footprint F.SilkS graphic (component-LOCAL coords) into
    board-absolute geometry, appended to the matching ``g.silk_*`` bucket.

    Supported kinds (see footprints.py's ``_parse_graphics``): line, circle,
    poly, arc. Arc has two source forms: legacy KiCad ``(center, start, angle)``
    (``points`` has 2 entries + an ``angle`` field) drawn as a TRUE arc via
    gerber-writer's ``add_trace_arc``; and the 3-point ``(start, mid, end)``
    form, drawn as a polyline through those points (acceptable approximation
    per the round brief — no test fixture currently exercises this form).
    """
    kind = graphic.get("kind")
    width = _graphic_width(graphic)

    if kind == "line":
        st, en = graphic.get("start"), graphic.get("end")
        if not (isinstance(st, list) and isinstance(en, list)
                and len(st) >= 2 and len(en) >= 2):
            return
        p1 = _transform_point(cx, cy, rot, _num(st[0]), _num(st[1]))
        p2 = _transform_point(cx, cy, rot, _num(en[0]), _num(en[1]))
        g.silk_lines.append((p1[0], p1[1], p2[0], p2[1], width))

    elif kind == "circle":
        ct = graphic.get("center")
        radius = _opt_num(graphic.get("radius"))
        if not (isinstance(ct, list) and len(ct) >= 2 and radius and radius > 0):
            return
        pc = _transform_point(cx, cy, rot, _num(ct[0]), _num(ct[1]))
        g.silk_circles.append((pc[0], pc[1], radius, width))

    elif kind == "poly":
        pts = [p for p in _list(graphic.get("points")) if isinstance(p, list) and len(p) >= 2]
        if len(pts) < 2:
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
        elif len(pts) >= 2:
            # 3-point (start[, mid], end) form: polyline approximation.
            abs_pts = [_transform_point(cx, cy, rot, _num(p[0]), _num(p[1])) for p in pts]
            g.silk_polys.append((abs_pts, width, False))


# ---------------------------------------------------------------------------
# Board -> intermediate geometry (side-tagged so we can build both copper /
# both mask layers in one pass).
# ---------------------------------------------------------------------------


class _Geometry:
    """Flattened, absolute-coordinate geometry harvested from a board dict."""

    def __init__(self) -> None:
        # SMD pads: (x, y, w, h, angle, top?)
        self.smd_pads: list[tuple[float, float, float, float, float, bool]] = []
        # Through-hole pads / vias copper annuli: (x, y, diameter, function)
        self.th_annuli: list[tuple[float, float, float, str]] = []
        # Mask openings on each side: (x, y, kind, dims...) where kind is
        # 'rect' -> (w, h, angle) or 'circle' -> (d,)
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

        pin_extents: list[tuple[float, float]] = []
        # iter_pads PREFERS resolved comp["pads"] (real footprint geometry) and
        # otherwise reconstructs the exact per-pin fallback this loop used to read
        # inline — so gate-OFF (no comp["pads"]) is byte-identical (see pad_source).
        for pad in iter_pads(comp):
            ox, oy = _rotate(pad.x, pad.y, rot)
            px, py = cx + ox, cy + oy
            pin_extents.append((px, py))

            drill = pad.drill
            if drill is not None and drill > 0:
                # Through-hole pad: copper annulus on BOTH copper layers, mask
                # opening on both sides, drilled hole (plated unless flagged).
                annulus = pad.annulus or (drill * 2.0)
                g.th_annuli.append((px, py, annulus, "ComponentPad"))
                mask_d = annulus + 2 * mask_clearance
                g.mask_top.append((px, py, "circle", mask_d))
                g.mask_bot.append((px, py, "circle", mask_d))
                g.holes.append((px, py, drill, pad.plated))
            else:
                # SMD pad on the component's own side.
                w = pad.width or DEFAULT_SMD_PAD_W_MM
                h = pad.height or DEFAULT_SMD_PAD_H_MM
                g.smd_pads.append((px, py, w, h, rot, top))
                mask = (px, py, "rect", w + 2 * mask_clearance,
                        h + 2 * mask_clearance, rot)
                (g.mask_top if top else g.mask_bot).append(mask)

        # Silk: components with resolved footprint graphics (resolve_board's
        # component["graphics"]) get their REAL F.SilkS outline; components
        # without it keep the courtyard-box placeholder (non-breaking — the
        # byte-golden boards carry no 'graphics' field, so they take this
        # unchanged 'else' path). Bottom-side (B.SilkS) is out of scope here,
        # same as the pre-existing box code (which was already top-only).
        graphics = comp.get("graphics")
        has_graphics = isinstance(graphics, list) and len(graphics) > 0
        if has_graphics:
            if top:
                for graphic in graphics:
                    if isinstance(graphic, dict) and graphic.get("layer") == "F.SilkS":
                        _harvest_silk_graphic(g, cx, cy, rot, graphic)
        elif top and pin_extents:
            xs = [p[0] for p in pin_extents]
            ys = [p[1] for p in pin_extents]
            half_w = (max(xs) - min(xs)) / 2 + SILK_COURTYARD_MARGIN_MM
            half_h = (max(ys) - min(ys)) / 2 + SILK_COURTYARD_MARGIN_MM
            g.silk_boxes.append(((max(xs) + min(xs)) / 2, (max(ys) + min(ys)) / 2,
                                 max(half_w, SILK_COURTYARD_MARGIN_MM),
                                 max(half_h, SILK_COURTYARD_MARGIN_MM)))

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
        for hole in _list(board.get(key)):
            if not isinstance(hole, dict):
                continue
            hx, hy = _num(hole.get("x_mm")), _num(hole.get("y_mm"))
            dia = _opt_num(hole.get("diameter_mm")) or _opt_num(hole.get("drill_mm"))
            if dia is None or dia <= 0:
                continue
            plated = bool(hole.get("plated", default_plated))
            g.holes.append((hx, hy, dia, plated))

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
    # of the same size collapses to a single %ADD..% (verified in the spike).
    for (px, py, w, h, angle, top) in pads:
        if top != top_wanted:
            continue
        layer.add_pad(Rectangle(w, h, "SMDPad,CuDef"), (px, py), angle)


def _add_annuli(layer: DataLayer, annuli) -> None:
    for (px, py, dia, func) in annuli:
        layer.add_pad(Circle(dia, func), (px, py))


def _add_traces(layer: DataLayer, traces) -> None:
    for (x1, y1, x2, y2, w) in traces:
        layer.add_trace_line((x1, y1), (x2, y2), w, "Conductor")


def _add_mask(layer: DataLayer, openings) -> None:
    for op in openings:
        px, py, kind = op[0], op[1], op[2]
        if kind == "rect":
            _, _, _, w, h, angle = op
            layer.add_pad(Rectangle(w, h, ""), (px, py), angle)
        else:  # circle
            layer.add_pad(Circle(op[3], ""), (px, py))


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
    _add_traces(f_cu, g.traces_top)
    out["F_Cu"] = _dump(f_cu, creation_date)

    # B.Cu
    b_cu = DataLayer("Copper,L2,Bot,Signal", negative=False)
    _add_smd(b_cu, g.smd_pads, top_wanted=False)
    _add_annuli(b_cu, g.th_annuli)
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


def build_gerbers(board_dict: dict, out_dir: str | None = None,
                  name: str | None = None,
                  creation_date: str | None = None) -> dict[str, str]:
    """Compile a canonical board into fabrication files.

    Returns {filename: content} for six Gerber layers (F_Cu, B_Cu, F_Mask,
    B_Mask, F_SilkS, Edge_Cuts) plus PTH.drl / NPTH.drl (each drill file emitted
    only when the board actually has holes of that class).

    Filenames are ``{base}-{suffix}.gbr`` / ``{base}-PTH.drl`` where base is
    *name* (default the board's ``name`` field, else "board").

    If *out_dir* is given the files are also written there (UTF-8). Coordinate
    format is self-declared by gerber-writer per layer extent (not pinned 4.6);
    the CreationDate stamp is pinned for byte-reproducibility unless
    *creation_date* is supplied.
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

    return files
