"""Minimal KiCad file generation from the canonical board contract.

WHY PLAIN PYTHON, NOT circuit_synth (recorded divergence — see docs/worker.md):
circuit_synth generates KiCad projects from ITS OWN Circuit object graph
(Python @circuit functions → Components carrying KiCad *symbol-library* refs →
its netlister + its own auto-placement). It cannot even construct a component
without KiCad symbol-library data present: `Component(symbol="Device:R")`
raises LibraryNotFound when KICAD_SYMBOL_DIR is unset (verified, v0.12.1).
Driving it faithfully from our canonical board would also mean surrendering our
explicit x_mm/y_mm/rotation_deg placement to its layout engine. Our contract's
whole point is that placement is authored, unit-tagged, and deterministic. So
generate() writes the KiCad s-expressions directly from the canonical fields —
honouring the exact geometry — which is dependency-light, deterministic, and
needs no library data. KiCad files are plain text; this is a faithful, if
minimal, emit (components as footprints, traces as segments, outline on
Edge.Cuts, vias). The .kicad_sch/.kicad_pro are minimal netlist-carrying
skeletons (a fully symbol-placed schematic needs symbol-library data — next
child scope).

All functions are pure: board dict → text.
"""

from __future__ import annotations

import json
from typing import Any

from agent_router import layers as _layers

# Canonical "top"/"bottom" -> KiCad copper name. T1.5: the SAME dict object as
# route_bridge._LAYER_MAP and kicad_io._CANON_TO_KICAD_LAYER (all three alias
# agent_router.layers.CANON_TO_KICAD) so the worker's copper-layer emitters can
# never drift again. kicad.py lives in pcb_worker, so importing the lower
# agent_router base package is the allowed (upward) direction.
#
# _copper_layer's body below is UNCHANGED and its behaviour is byte-identical:
# the shared map has no "" key, but _copper_layer's final `return "F.Cu"`
# already maps an empty string (and any non-string / falsy input) to "F.Cu",
# and a non-empty unknown/already-KiCad name still passes through unchanged and
# un-case-folded ("F.Cu"->"F.Cu", "Edge.Cuts"->"Edge.Cuts").
_LAYER_MAP = _layers.CANON_TO_KICAD


def _num(v: Any, default: float = 0.0) -> float:
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else default


def _opt_num(v: Any) -> float | None:
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def _copper_layer(name: Any) -> str:
    if isinstance(name, str) and name in _LAYER_MAP:
        return _LAYER_MAP[name]
    if isinstance(name, str) and name:
        return name  # already a KiCad layer id (e.g. "F.Cu")
    return "F.Cu"


def _list(v: Any) -> list:
    return v if isinstance(v, list) else []


def _esc(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')


def _bounds(board: dict) -> tuple[float, float, float, float]:
    origin = board.get("origin") or {}
    ox = _num(origin.get("x_mm")) if isinstance(origin, dict) else 0.0
    oy = _num(origin.get("y_mm")) if isinstance(origin, dict) else 0.0
    return (ox, oy, ox + _num(board.get("width_mm")), oy + _num(board.get("height_mm")))


def _net_table(board: dict) -> tuple[dict[str, int], dict[str, dict[str, int]]]:
    """Return (net_name→index, ref→{pad→net_index}) derived from board nets.

    Net indices start at 1 (KiCad reserves net 0 for unconnected).
    """
    net_index: dict[str, int] = {}
    pad_net: dict[str, dict[str, int]] = {}
    for i, net in enumerate(_list(board.get("nets")), start=1):
        if not isinstance(net, dict):
            continue
        name = net.get("name")
        if isinstance(name, str) and name:
            net_index[name] = i
        for pinref in _list(net.get("pins")):
            if isinstance(pinref, str) and "." in pinref:
                ref, _, pad = pinref.rpartition(".")
                pad_net.setdefault(ref, {})[pad] = i
    return net_index, pad_net


def generate_kicad_pcb(board: dict) -> str:
    """Emit a minimal .kicad_pcb (s-expression) for the canonical board.

    Renders: board outline on Edge.Cuts, each component as a `footprint` node
    with its pads, each trace as `segment` nodes, each via as a `via` node.
    Coordinates pass through 1:1 (KiCad's .kicad_pcb unit is mm).
    """
    min_x, min_y, max_x, max_y = _bounds(board)
    net_index, pad_net = _net_table(board)
    net_name_of = {i: n for n, i in net_index.items()}

    out: list[str] = []
    out.append("(kicad_pcb (version 20221018) (generator pcb_worker)")
    out.append("  (general (thickness 1.6))")
    out.append('  (paper "A4")')
    out.append("  (layers")
    out.append('    (0 "F.Cu" signal)')
    out.append('    (31 "B.Cu" signal)')
    out.append('    (44 "Edge.Cuts" user)')
    out.append('    (35 "F.SilkS" user)')
    out.append("  )")
    out.append("  (setup)")

    # Net declarations (net 0 is the unconnected net, required by KiCad).
    out.append('  (net 0 "")')
    for name, i in net_index.items():
        out.append(f'  (net {i} "{_esc(name)}")')

    # Board outline (Edge.Cuts rectangle from origin + width/height).
    for (x1, y1, x2, y2) in _rect_edges(min_x, min_y, max_x, max_y):
        out.append(
            f'  (gr_line (start {x1} {y1}) (end {x2} {y2}) '
            f'(layer "Edge.Cuts") (width 0.15))'
        )

    # Components → footprints.
    for comp in _list(board.get("components")):
        if isinstance(comp, dict):
            out.append(_footprint(comp, pad_net, net_name_of))

    # Traces → segments (one per consecutive point pair).
    for tr in _list(board.get("traces")):
        if not isinstance(tr, dict):
            continue
        layer = _copper_layer(tr.get("layer"))
        width = _num(tr.get("width_mm"), 0.25)
        net_no = net_index.get(tr.get("net"), 0)
        pts = [p for p in _list(tr.get("points")) if isinstance(p, dict)]
        for a, b in zip(pts, pts[1:]):
            out.append(
                f'  (segment (start {_num(a.get("x_mm"))} {_num(a.get("y_mm"))}) '
                f'(end {_num(b.get("x_mm"))} {_num(b.get("y_mm"))}) '
                f'(width {width}) (layer "{layer}") (net {net_no}))'
            )

    # Vias.
    for via in _list(board.get("vias")):
        if not isinstance(via, dict):
            continue
        size = _num(via.get("diameter_mm"), 0.8)
        drill = _num(via.get("drill_mm"), 0.4)
        net_no = net_index.get(via.get("net"), 0)
        out.append(
            f'  (via (at {_num(via.get("x_mm"))} {_num(via.get("y_mm"))}) '
            f'(size {size}) (drill {drill}) (layers "F.Cu" "B.Cu") (net {net_no}))'
        )

    out.append(")")
    return "\n".join(out) + "\n"


def _footprint(comp: dict, pad_net: dict[str, dict[str, int]], net_name_of: dict[int, str]) -> str:
    ref = str(comp.get("ref") or "?")
    fp = comp.get("footprint") or "unknown"
    x, y = _num(comp.get("x_mm")), _num(comp.get("y_mm"))
    rot = _num(comp.get("rotation_deg"))
    layer = _copper_layer(comp.get("layer"))
    value = comp.get("value") or ""
    pads_nets = pad_net.get(ref, {})

    lines = [f'  (footprint "{_esc(str(fp))}" (layer "{layer}") (at {x} {y} {rot})']
    lines.append(f'    (fp_text reference "{_esc(ref)}" (at 0 -1.5) (layer "F.SilkS"))')
    lines.append(f'    (fp_text value "{_esc(str(value))}" (at 0 1.5) (layer "F.Fab"))')

    for pin in _list(comp.get("pins")):
        if not isinstance(pin, dict):
            continue
        num = pin.get("number")
        if num is None:
            continue
        num_s = str(num)
        px, py = _num(pin.get("x_mm")), _num(pin.get("y_mm"))
        drill = pin.get("drill_mm")
        net_no = pads_nets.get(num_s)
        net_expr = ""
        if net_no:
            net_expr = f' (net {net_no} "{_esc(net_name_of.get(net_no, ""))}")'
        if isinstance(drill, (int, float)) and not isinstance(drill, bool):
            # Through-hole pad. annulus geometry is carried in Extra when present.
            annulus = pin.get("annulus_diameter_mm", drill * 2)
            lines.append(
                f'    (pad "{_esc(num_s)}" thru_hole circle (at {px} {py}) '
                f'(size {_num(annulus)} {_num(annulus)}) (drill {_num(drill)}) '
                f'(layers "*.Cu"){net_expr})'
            )
        else:
            # SMD rect pad. Honour the pin's declared pad geometry when present
            # (pad_width_mm / pad_height_mm — the SAME keys gerber.py reads in
            # _harvest, so kicad + gerber stay consistent); fall back to the
            # 1x0.6mm nominal only when the pin omits them.
            pw = _opt_num(pin.get("pad_width_mm"))
            ph = _opt_num(pin.get("pad_height_mm"))
            w = pw if pw is not None else 1
            h = ph if ph is not None else 0.6
            lines.append(
                f'    (pad "{_esc(num_s)}" smd rect (at {px} {py}) '
                f'(size {w} {h}) (layers "{layer}" "F.Paste" "F.Mask"){net_expr})'
            )
    lines.append("  )")
    return "\n".join(lines)


def _rect_edges(x1, y1, x2, y2):
    return [
        (x1, y1, x2, y1),
        (x2, y1, x2, y2),
        (x2, y2, x1, y2),
        (x1, y2, x1, y1),
    ]


def generate_kicad_pro(board: dict) -> str:
    """Emit a minimal .kicad_pro (KiCad project file — JSON since KiCad 6)."""
    name = board.get("name") or "board"
    doc = {
        "board": {"design_settings": {}},
        "meta": {"filename": f"{name}.kicad_pro", "version": 1},
        "pcbnew": {},
        "schematic": {},
        "sheets": [],
        "libraries": {"pinned_footprint_libs": [], "pinned_symbol_libs": []},
    }
    return json.dumps(doc, indent=2) + "\n"


def generate_kicad_sch(board: dict) -> str:
    """Emit a minimal .kicad_sch skeleton carrying the netlist as text.

    A fully symbol-placed schematic needs KiCad symbol-library data to resolve
    each component to a graphical symbol; that is next-child scope. This emits a
    structurally-headed schematic with a text block enumerating components and
    nets so the electrical intent round-trips as human-readable source.
    """
    out: list[str] = []
    out.append("(kicad_sch (version 20230121) (generator pcb_worker)")
    out.append('  (paper "A4")')
    out.append(f'  (title_block (title "{_esc(str(board.get("name") or "board"))}"))')
    y = 20.0
    for comp in _list(board.get("components")):
        if not isinstance(comp, dict):
            continue
        label = f'{comp.get("ref", "?")} {comp.get("value", "")} [{comp.get("footprint", "")}]'
        out.append(f'  (text "{_esc(label)}" (at 20 {y} 0) (effects (font (size 1.27 1.27))))')
        y += 5
    y = 20.0
    for net in _list(board.get("nets")):
        if not isinstance(net, dict):
            continue
        label = f'net {net.get("name", "?")}: {", ".join(str(p) for p in _list(net.get("pins")))}'
        out.append(f'  (text "{_esc(label)}" (at 120 {y} 0) (effects (font (size 1.27 1.27))))')
        y += 5
    out.append(")")
    return "\n".join(out) + "\n"


def generate(board: dict, base_name: str | None = None) -> dict[str, str]:
    """Generate the three KiCad files for a canonical board.

    Returns {"<name>.kicad_pcb": text, "<name>.kicad_sch": text,
             "<name>.kicad_pro": text}.
    """
    name = base_name or (board.get("name") if isinstance(board.get("name"), str) else None) or "board"
    return {
        f"{name}.kicad_pcb": generate_kicad_pcb(board),
        f"{name}.kicad_sch": generate_kicad_sch(board),
        f"{name}.kicad_pro": generate_kicad_pro(board),
    }
