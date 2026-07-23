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

from .pad_source import iter_pads, th_land
from .resolved_board import (
    Diagnostic,
    DiagnosticSeverity,
    EntityKind,
    SourceRef,
)


class KicadResult(dict):
    """The ``{filename: content}`` KiCad files mapping (UNCHANGED semantics — it IS
    the files dict the ~2 callers already index / iterate) that ALSO carries the
    emitter's capability-conformance diagnostics as a side channel.

    R5 K3 gate (019f8a44484f comment 628): a captured fab feature the KiCad emitter
    cannot emit faithfully (a degenerate footprint silk primitive, a graphic on a
    non-emitted layer) must never vanish SILENTLY. generate() returns this so
    methods.py can forward WARNING diagnostics without any change to the file bytes
    or to callers that treat the return as a plain ``dict[str, str]``. A DIRECT COPY
    of gerber.GerberResult's pattern (one shared side-channel contract, not a
    divergent reimplementation).

    CAVEAT (same as GerberResult): ``.copy()`` returns a PLAIN ``dict`` — the
    ``diagnostics`` side channel is dropped. Read ``.diagnostics`` off the value
    generate() returned, not off a copy of it.
    """

    def __init__(self, *args: Any, diagnostics: list[Diagnostic] | None = None,
                 **kwargs: Any) -> None:
        super().__init__(*args, **kwargs)
        self.diagnostics: list[Diagnostic] = list(diagnostics or [])

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


# Silk stroke width fallback — mirrors gerber._graphic_width / SILK_LINE_WIDTH_MM
# so kicad and gerber default a widthless footprint graphic to the SAME stroke.
_SILK_LINE_WIDTH_MM = 0.15


def _graphic_width(graphic: dict) -> float:
    w = _opt_num(graphic.get("width"))
    return w if (w is not None and w > 0) else _SILK_LINE_WIDTH_MM


def _graphic_ref(ref: Any, layer: Any) -> SourceRef:
    """A GRAPHIC SourceRef tagged with the owning component ref (or a sentinel
    when the board component carries none). entity_id must be non-empty — the same
    load-bearing fallback gerber._silk_ref uses so a refless component's dropped
    graphic still yields a valid Diagnostic instead of raising."""
    rid = ref if isinstance(ref, str) and ref else "<unknown>"
    detail = layer if isinstance(layer, str) and layer else "F.SilkS"
    return SourceRef(EntityKind.GRAPHIC, rid, detail)




def _pad_at(px: float, py: float, rotation: float | None) -> str:
    """The pad ``(at ...)`` s-expression. KiCad's pad ``(at)`` third value is the
    ABSOLUTE pad angle (footprint rotation + the pad's own local rotation), NOT a
    footprint-relative one — pcbnew stores it absolute and re-derives the relative
    part on load. The caller MUST therefore pass an ABSOLUTE angle. The IR fab
    bridge (ir_to_kicad_board_dict) satisfies this: it emits every footprint at
    identity ``(at 0 0 0)`` and passes ``PlacedPad.rotation_deg`` (already the
    absolute combined angle), so the emitted value is correct.

    Emitted ONLY when a non-zero angle is present, so a pad with no rotation
    (``None``) or zero emits ``(at px py)`` — byte-identical to the pre-W8 emission
    (the legacy-resolve goldens carry no rotated pads).

    CAVEAT (legacy path, retiring at the W8.2 cutover — filed follow-up): the
    legacy ``resolve`` dict path feeds ``PadGeom.rotation`` a footprint-LOCAL angle
    (SB2), which is wrong-as-absolute for a component placed at a non-zero
    rotation. Not fixed here (that path is being replaced by this IR bridge, and a
    fix would churn goldens that encode the pre-existing value); the IR path — the
    one W8.2 wires into fab — is correct."""
    if rotation is not None and rotation != 0.0:
        return f"(at {px} {py} {_num(rotation)})"
    return f"(at {px} {py})"


def _smd_tech_layers(copper_layer: str) -> tuple[str, str]:
    """(paste, mask) technical layers on the SAME side as an SMD pad's copper.

    Before W8.1b kicad hardcoded ``F.Paste``/``F.Mask``, so a B.Cu (bottom) SMD pad
    emitted its paste + mask on the FRONT — an inconsistent padstack KiCad DRC
    flags ("copper and mask layers on different sides of the board"). Deriving the
    side from the copper layer keeps them consistent. GOLDEN-NEUTRAL: a front
    (``F.Cu``, or any non-``B.Cu``) pad still yields ``F.Paste``/``F.Mask``
    unchanged; only a bottom pad — previously wrong and untested by any kicad
    golden — changes (the IR already tags such pads ``B.Mask``/``B.Paste``)."""
    if copper_layer == "B.Cu":
        return "B.Paste", "B.Mask"
    return "F.Paste", "F.Mask"


def _smd_shape_tokens(pad) -> tuple[str, float, float, str]:
    """Map a declared SUPPORTED_PAD_SHAPE to its faithful KiCad pad shape token +
    size + optional roundrect_rratio suffix — the K3 conformance analog of gerber's
    _shape_aperture (019f7aed6d9e comment 628). Before this, kicad hard-coded
    ``smd rect``, silently flattening circle/oval/roundrect.

      * rect      -> ``rect`` (size w h).
      * circle    -> ``circle`` (size d d) with d = width (pad_source guarantees
                     w==h for a circle upstream, so width IS the diameter).
      * oval      -> ``oval`` (size w h).
      * roundrect -> ``roundrect`` (size w h) + ``(roundrect_rratio R)`` so the
                     corner radius is FAITHFUL (R from corner_rratio, default 0.25
                     when None — matching gerber's _shape_aperture default), not a
                     constant.

    SMD geometry is already fail-closed upstream (iter_pads(require_smd_size=True):
    circle w!=h, bad roundrect rratio), so this just emits the faithful token — it
    does NOT re-validate.
    """
    shape = pad.shape
    w, h = pad.width, pad.height
    if shape == "circle":
        return "circle", w, w, ""
    if shape == "oval":
        return "oval", w, h, ""
    if shape == "roundrect":
        ratio = pad.corner_rratio if pad.corner_rratio is not None else 0.25
        return "roundrect", w, h, f" (roundrect_rratio {ratio})"
    return "rect", w, h, ""


def _footprint_graphics(comp: dict, ref: Any,
                        diagnostics: list[Diagnostic]) -> list[str]:
    """Emit ``comp["graphics"]`` F.SilkS entries as native KiCad footprint
    graphics in component-LOCAL coords (no transform — KiCad draws these under the
    footprint's own ``(at x y rot)``, unlike gerber which pre-transforms to board
    absolute). The stroke uses the file's inline ``(width W)`` convention (the same
    gr_line/edges use above), not a ``(stroke ...)`` block.

    K3: a captured graphic that cannot be emitted faithfully WARNS (cosmetic —
    never fatal, never raises): a non-F.SilkS layer -> ``unsupported_graphic_layer``;
    a degenerate primitive (missing endpoints, radius<=0, <2 poly pts, an
    unsupported/underspecified arc form) -> ``silk_primitive_unemitted``. The legacy
    KiCad-6 (start,end,angle) arc form is NOT emitted (its center/start/sweep
    interpretation is ambiguous here) — warned, never emitted WRONG.
    """
    lines: list[str] = []
    for g in _list(comp.get("graphics")):
        if not isinstance(g, dict):
            continue
        layer = g.get("layer")
        if layer != "F.SilkS":
            diagnostics.append(Diagnostic(
                DiagnosticSeverity.WARNING, "unsupported_graphic_layer",
                f"footprint graphic on layer {layer!r} not emitted "
                "(only F.SilkS is emitted)", _graphic_ref(ref, layer)))
            continue
        kind = g.get("kind")
        w = _graphic_width(g)
        if kind == "line":
            st, en = g.get("start"), g.get("end")
            if not (isinstance(st, list) and isinstance(en, list)
                    and len(st) >= 2 and len(en) >= 2):
                diagnostics.append(Diagnostic(
                    DiagnosticSeverity.WARNING, "silk_primitive_unemitted",
                    "silk line dropped: malformed start/end", _graphic_ref(ref, layer)))
                continue
            lines.append(
                f'    (fp_line (start {_num(st[0])} {_num(st[1])}) '
                f'(end {_num(en[0])} {_num(en[1])}) (width {w}) (layer "F.SilkS"))')
        elif kind == "circle":
            ct = g.get("center")
            radius = _opt_num(g.get("radius"))
            if not (isinstance(ct, list) and len(ct) >= 2 and radius and radius > 0):
                diagnostics.append(Diagnostic(
                    DiagnosticSeverity.WARNING, "silk_primitive_unemitted",
                    "silk circle dropped: non-positive radius or malformed center",
                    _graphic_ref(ref, layer)))
                continue
            cx0, cy0 = _num(ct[0]), _num(ct[1])
            lines.append(
                f'    (fp_circle (center {cx0} {cy0}) (end {cx0 + radius} {cy0}) '
                f'(width {w}) (layer "F.SilkS"))')
        elif kind == "poly":
            pts = [p for p in _list(g.get("points"))
                   if isinstance(p, list) and len(p) >= 2]
            if len(pts) < 2:
                diagnostics.append(Diagnostic(
                    DiagnosticSeverity.WARNING, "silk_primitive_unemitted",
                    "silk poly dropped: fewer than 2 valid points",
                    _graphic_ref(ref, layer)))
                continue
            pts_expr = " ".join(f'(xy {_num(p[0])} {_num(p[1])})' for p in pts)
            lines.append(
                f'    (fp_poly (pts {pts_expr}) (width {w}) (layer "F.SilkS"))')
        elif kind == "arc":
            pts = [p for p in _list(g.get("points"))
                   if isinstance(p, list) and len(p) >= 2]
            angle = _opt_num(g.get("angle"))
            if len(pts) >= 3:
                # Modern KiCad 7/8 three-point (start, mid, end) form — emit directly.
                s, m, e = pts[0], pts[1], pts[2]
                lines.append(
                    f'    (fp_arc (start {_num(s[0])} {_num(s[1])}) '
                    f'(mid {_num(m[0])} {_num(m[1])}) '
                    f'(end {_num(e[0])} {_num(e[1])}) '
                    f'(width {w}) (layer "F.SilkS"))')
            elif angle is not None and angle != 0.0 and len(pts) >= 2:
                # Legacy KiCad-6 (start,end,angle) form: emitting an fp_arc needs a
                # mid point, and the center/start/sweep interpretation is ambiguous
                # against this emitter's data — WARN rather than emit a WRONG arc.
                diagnostics.append(Diagnostic(
                    DiagnosticSeverity.WARNING, "silk_primitive_unemitted",
                    "silk arc dropped: legacy angle form unsupported by kicad emitter",
                    _graphic_ref(ref, layer)))
            else:
                diagnostics.append(Diagnostic(
                    DiagnosticSeverity.WARNING, "silk_primitive_unemitted",
                    "silk arc dropped: underspecified (need 3 points or an angle form)",
                    _graphic_ref(ref, layer)))
    return lines


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


def generate_kicad_pcb(board: dict, diagnostics: list[Diagnostic] | None = None) -> str:
    """Emit a minimal .kicad_pcb (s-expression) for the canonical board.

    Renders: board outline on Edge.Cuts, each component as a `footprint` node
    with its pads + F.SilkS graphics, each trace as `segment` nodes, each via as a
    `via` node. Coordinates pass through 1:1 (KiCad's .kicad_pcb unit is mm).

    ``diagnostics`` (when supplied) collects the emitter's K3 WARNING channel
    (captured-but-unemitted footprint graphics) in board/component order.
    """
    if diagnostics is None:
        diagnostics = []
    min_x, min_y, max_x, max_y = _bounds(board)
    net_index, pad_net = _net_table(board)
    net_name_of = {i: n for n, i in net_index.items()}

    out: list[str] = []
    # KiCad-9 board file version. Bumped from the KiCad-7 stamp (20221018) when the
    # via emitter began writing the KiCad-9 `(tenting ...)` grammar (finding
    # 019f9022facc): a board carrying v9 tokens must declare v9 so a v7/v8 tool
    # fails loudly on version rather than silently mis-parsing. 20241229 is the exact
    # version pcbnew 9.0.9 writes (verified via SaveBoard).
    out.append("(kicad_pcb (version 20241229) (generator pcb_worker)")
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
            out.append(_footprint(comp, pad_net, net_name_of, diagnostics))

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
        # Per-side mask tenting (finding 019f9022facc): honor the canonical
        # tented_front/back so KiCad agrees with the Gerber emitter instead of
        # deferring to the board's design-rule default. The `(tenting ...)` token
        # names the sides that ARE tented (mask covers the via); an UNTENTED side
        # is exposed. Verified vs pcbnew 9.0.9 SetFront/BackTentingMode round-trip:
        # both tented -> "front back", front-only -> "front", back-only -> "back",
        # neither -> "none". Emitted EXPLICITLY in every case (never FROM_RULES) so
        # the two emitters cannot silently diverge. Default (key absent) is tented,
        # matching gerber._emit_via's via.get("tented_front", True).
        tented = [s for s, t in (("front", via.get("tented_front", True)),
                                 ("back", via.get("tented_back", True))) if t]
        tenting = f'(tenting {" ".join(tented)})' if tented else "(tenting none)"
        out.append(
            f'  (via (at {_num(via.get("x_mm"))} {_num(via.get("y_mm"))}) '
            f'(size {size}) (drill {drill}) (layers "F.Cu" "B.Cu") '
            f'{tenting} (net {net_no}))'
        )

    out.append(")")
    return "\n".join(out) + "\n"


def _footprint(comp: dict, pad_net: dict[str, dict[str, int]],
               net_name_of: dict[int, str],
               diagnostics: list[Diagnostic] | None = None) -> str:
    ref = str(comp.get("ref") or "?")
    fp = comp.get("footprint") or "unknown"
    x, y = _num(comp.get("x_mm")), _num(comp.get("y_mm"))
    rot = _num(comp.get("rotation_deg"))
    layer = _copper_layer(comp.get("layer"))
    value = comp.get("value") or ""
    pads_nets = pad_net.get(ref, {})

    lines = [f'  (footprint "{_esc(str(fp))}" (layer "{layer}") (at {x} {y} {rot})']
    # Reference + value designator text both go on F.Fab (documentation), NOT
    # F.SilkS. R5 now emits the footprint's REAL F.SilkS graphics; a placeholder
    # reference glyph hard-pinned at local (0, -1.5) — with no footprint-aware
    # placement datum — would land ON that real silk and trip KiCad's
    # silkscreen-overlap DRC (verified on the spike board's origin-centred silk
    # circle). Designators on F.Fab is standard KiCad assembly practice and keeps
    # the silk layer to the footprint's own faithful outline.
    lines.append(f'    (fp_text reference "{_esc(ref)}" (at 0 -1.5) (layer "F.Fab"))')
    lines.append(f'    (fp_text value "{_esc(str(value))}" (at 0 1.5) (layer "F.Fab"))')

    # iter_pads PREFERS resolved comp["pads"] (real footprint geometry — the SAME
    # source gerber._harvest reads, so kicad + gerber agree) and otherwise
    # reconstructs the per-pin fallback. require_smd_size=True fail-closes on a
    # sizeless SMD pad (no placeholder land — bug 019f7736b236); real runs resolve
    # the board first (methods gate).
    for pad in iter_pads(comp, require_smd_size=True):
        if pad.number is None:
            continue
        num_s = str(pad.number)
        px, py = pad.x, pad.y
        drill = pad.drill
        net_no = pads_nets.get(num_s)
        net_expr = ""
        if net_no:
            net_expr = f' (net {net_no} "{_esc(net_name_of.get(net_no, ""))}")'
        if drill is not None:
            # Through-hole pad. annulus geometry is the real copper dim when
            # resolved, else the pin's Extra annulus, else the 2x-drill nominal.
            # SHAPE INTENTIONALLY ``circle``, NOT an oversight: TH copper is a round
            # annulus (SUPPORTED_HOLE_SHAPES = {round}); the model carries a single
            # annulus diameter, not a shaped land, so `thru_hole circle (size a a)`
            # IS faithful — consistent with the gerber emitter's round-only TH.
            #
            # A NON-PLATED through-hole (a mounting hole / NPTH pad: pad_type
            # ``np_thru_hole`` or plated is False) is a BARE drilled hole with NO
            # copper annulus and NO net — the standard KiCad ``MountingHole``
            # padstack: ``np_thru_hole circle (size drill drill) (drill drill)
            # (layers "*.Cu" "*.Mask")``. It emits size == drill (no copper ring),
            # adds the "*.Mask" layer so the mask opens over the hole, and carries
            # no ``(net ...)``. A plated ``thru_hole`` stays byte-identical to today.
            plated = pad.plated and pad.pad_type != "np_thru_hole"
            if not plated:
                lines.append(
                    f'    (pad "{_esc(num_s)}" np_thru_hole circle '
                    f'{_pad_at(px, py, pad.rotation)} '
                    f'(size {_num(drill)} {_num(drill)}) (drill {_num(drill)}) '
                    f'(layers "*.Cu" "*.Mask"))'
                )
                continue
            # th_land is the SHARED decision (also gerber._harvest): a genuinely
            # OBLONG land emits a faithful shaped thru_hole (KiCad renders oval/
            # roundrect/rect TH copper natively), keeping width x height instead of
            # collapsing to a round annulus (finding 019f8b7fd295). An equal-axis
            # land stays the historical round `thru_hole circle`. Drill stays round.
            shaped, land_shape, lw, lh, lrratio = th_land(pad)
            if shaped:
                if land_shape == "roundrect":
                    ratio = lrratio if lrratio is not None else 0.25
                    tok, suffix = "roundrect", f" (roundrect_rratio {ratio})"
                elif land_shape == "oval":
                    tok, suffix = "oval", ""
                else:
                    tok, suffix = "rect", ""
                lines.append(
                    f'    (pad "{_esc(num_s)}" thru_hole {tok} {_pad_at(px, py, pad.rotation)} '
                    f'(size {_num(lw)} {_num(lh)}){suffix} (drill {_num(drill)}) '
                    f'(layers "*.Cu" "*.Mask"){net_expr})'
                )
            else:
                annulus = pad.annulus if pad.annulus is not None else drill * 2
                lines.append(
                    f'    (pad "{_esc(num_s)}" thru_hole circle {_pad_at(px, py, pad.rotation)} '
                    f'(size {_num(annulus)} {_num(annulus)}) (drill {_num(drill)}) '
                    f'(layers "*.Cu" "*.Mask"){net_expr})'
                )
        else:
            # SMD pad. width/height are guaranteed positive by
            # iter_pads(require_smd_size=True) above (a sizeless SMD pad has
            # already raised PadGeometryError) — the SAME real size gerber.py
            # reads in _harvest, so kicad + gerber stay consistent. The shape token
            # is now FAITHFUL (rect/circle/oval/roundrect) via _smd_shape_tokens —
            # no more hard-coded `rect` flattening (R5 K3 conformance).
            shape_tok, sw, sh, rratio_suffix = _smd_shape_tokens(pad)
            paste, mask = _smd_tech_layers(layer)
            lines.append(
                f'    (pad "{_esc(num_s)}" smd {shape_tok} {_pad_at(px, py, pad.rotation)} '
                f'(size {sw} {sh}){rratio_suffix} '
                f'(layers "{layer}" "{paste}" "{mask}"){net_expr})'
            )

    # Footprint F.SilkS graphics (line/circle/arc/poly) — DROPPED before R5; now
    # emitted in LOCAL coords under this footprint's own (at). Degenerate /
    # unsupported entries warn into `diagnostics` (never raise).
    if diagnostics is not None:
        # Pass the RAW ref (may be None) so _graphic_ref's non-empty sentinel is a
        # real path — mirrors gerber._harvest passing comp.get("ref") to _silk_ref.
        lines.extend(_footprint_graphics(comp, comp.get("ref"), diagnostics))
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


def generate(board: dict, base_name: str | None = None) -> KicadResult:
    """Generate the three KiCad files for a canonical board.

    Returns a KicadResult (a ``dict[str, str]`` subclass — a drop-in for the plain
    files dict every caller indexes / iterates) mapping
    {"<name>.kicad_pcb": text, "<name>.kicad_sch": text, "<name>.kicad_pro": text}.
    ``.diagnostics`` carries the emitter's K3 WARNING channel (captured-but-
    unemitted footprint graphics); empty on a clean board, a side channel that
    changes no file bytes.
    """
    name = base_name or (board.get("name") if isinstance(board.get("name"), str) else None) or "board"
    diagnostics: list[Diagnostic] = []
    files = {
        f"{name}.kicad_pcb": generate_kicad_pcb(board, diagnostics),
        f"{name}.kicad_sch": generate_kicad_sch(board),
        f"{name}.kicad_pro": generate_kicad_pro(board),
    }
    return KicadResult(files, diagnostics=diagnostics)
