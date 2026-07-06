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

import math
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


def _is_top(layer: Any) -> bool:
    """A component/trace is on the top side unless it explicitly says bottom."""
    if isinstance(layer, str):
        return layer.strip().lower() not in ("bottom", "b.cu", "back")
    return True


def _rotate(px: float, py: float, deg: float) -> tuple[float, float]:
    """Rotate a component-relative offset CCW by *deg* degrees."""
    if deg == 0.0:
        return px, py
    r = math.radians(deg)
    c, s = math.cos(r), math.sin(r)
    return px * c - py * s, px * s + py * c


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
        # Silk courtyard boxes (top side): (cx, cy, half_w, half_h)
        self.silk_boxes: list[tuple[float, float, float, float]] = []


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
        for pin in _list(comp.get("pins")):
            if not isinstance(pin, dict):
                continue
            ox, oy = _rotate(_num(pin.get("x_mm")), _num(pin.get("y_mm")), rot)
            px, py = cx + ox, cy + oy
            pin_extents.append((px, py))

            drill = _opt_num(pin.get("drill_mm"))
            if drill is not None and drill > 0:
                # Through-hole pad: copper annulus on BOTH copper layers, mask
                # opening on both sides, drilled hole (plated unless flagged).
                annulus = _opt_num(pin.get("annulus_diameter_mm")) or (drill * 2.0)
                g.th_annuli.append((px, py, annulus, "ComponentPad"))
                mask_d = annulus + 2 * mask_clearance
                g.mask_top.append((px, py, "circle", mask_d))
                g.mask_bot.append((px, py, "circle", mask_d))
                plated = pin.get("plated", True) is not False
                g.holes.append((px, py, drill, plated))
            else:
                # SMD pad on the component's own side.
                w = _opt_num(pin.get("pad_width_mm")) or DEFAULT_SMD_PAD_W_MM
                h = _opt_num(pin.get("pad_height_mm")) or DEFAULT_SMD_PAD_H_MM
                g.smd_pads.append((px, py, w, h, rot, top))
                mask = (px, py, "rect", w + 2 * mask_clearance,
                        h + 2 * mask_clearance, rot)
                (g.mask_top if top else g.mask_bot).append(mask)

        # Silk courtyard box (top-side components only) around the pad extent.
        if top and pin_extents:
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

    # F.SilkS — courtyard box placeholder per top component (gerber-writer has
    # no glyph/text primitive; real reference-designator text is future scope).
    f_silks = DataLayer("Legend,Top", negative=False)
    for (cx, cy, hw, hh) in g.silk_boxes:
        f_silks.add_traces_path(_rect_path(cx, cy, hw, hh), SILK_LINE_WIDTH_MM, "")
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
