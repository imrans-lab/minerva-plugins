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

from .geometry import place_point
from .pad_source import iter_pads, th_land
from .resolved_board import (
    ArcGeometry,
    BoardOutline,
    CircleGeometry,
    Diagnostic,
    DiagnosticSeverity,
    EntityKind,
    LineGeometry,
    PlacedGraphic,
    PlacedPad,
    PolygonGeometry,
    ProfileOutline,
    RectOutline,
    ResolvedBoard,
    ResolvedComponent,
    ResolvedHole,
    RoundHole,
    Side,
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
    # FULL canonical KiCad-9 layer table (finding 019f90c5c962). The emitter
    # references F/B.Mask, F/B.Paste, F.Fab, etc. in pad/footprint layer lists; a
    # layer NOT declared here is silently NOT PLOTTED by KiCad's Gerber exporter
    # (it exits 0 but emits no mask files), so the E3 NPTH mask + E4 via tenting
    # never reach fab. These ids/types are the EXACT stack pcbnew 9.0.9 writes for a
    # 2-layer board (verified via CreateEmptyBoard -> SaveBoard) — KiCad-9 renumbered
    # the stack (B.Cu=2 not 31, F.Mask=1, Edge.Cuts=25, F.SilkS=5 not 35), so the old
    # KiCad-7 numbers under the 20241229 (v9) stamp were internally inconsistent.
    out.append("  (layers")
    for decl in (
        '(0 "F.Cu" signal)', '(2 "B.Cu" signal)',
        '(9 "F.Adhes" user "F.Adhesive")', '(11 "B.Adhes" user "B.Adhesive")',
        '(13 "F.Paste" user)', '(15 "B.Paste" user)',
        '(5 "F.SilkS" user "F.Silkscreen")', '(7 "B.SilkS" user "B.Silkscreen")',
        '(1 "F.Mask" user)', '(3 "B.Mask" user)',
        '(17 "Dwgs.User" user "User.Drawings")', '(19 "Cmts.User" user "User.Comments")',
        '(21 "Eco1.User" user "User.Eco1")', '(23 "Eco2.User" user "User.Eco2")',
        '(25 "Edge.Cuts" user)', '(27 "Margin" user)',
        '(31 "F.CrtYd" user "F.Courtyard")', '(29 "B.CrtYd" user "B.Courtyard")',
        '(35 "F.Fab" user)', '(33 "B.Fab" user)',
    ):
        out.append("    " + decl)
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
    # Reference + value designator text go on the component's OWN-SIDE Fab layer:
    # B.Fab for a bottom (B.Cu) footprint, F.Fab otherwise. A bottom footprint's
    # documentation text belongs on B.Fab — pinning it to F.Fab left B.Fab empty and
    # put bottom designators on the wrong side (finding 019f8b715ca6). Fab (not
    # F.SilkS) because R5 emits the footprint's REAL silk graphics; a placeholder
    # reference glyph hard-pinned at local (0, -1.5) with no footprint-aware
    # placement datum would land ON that real silk and trip KiCad's silkscreen-
    # overlap DRC. Side-aware Fab designators are standard KiCad assembly practice
    # and keep the silk layer to the footprint's own faithful outline.
    fab_layer = "B.Fab" if layer == "B.Cu" else "F.Fab"
    # Text on a BACK layer must be MIRRORED or KiCad's DRC raises
    # nonmirrored_text_on_back_layer (verified vs pcbnew 9.0.9: a B.Fab fp_text
    # carries `(effects (justify mirror))`). Front text needs no effects.
    fab_effects = " (effects (justify mirror))" if fab_layer == "B.Fab" else ""
    value = comp.get("value") or ""
    pads_nets = pad_net.get(ref, {})

    lines = [f'  (footprint "{_esc(str(fp))}" (layer "{layer}") (at {x} {y} {rot})']
    lines.append(f'    (fp_text reference "{_esc(ref)}" (at 0 -1.5) (layer "{fab_layer}"){fab_effects})')
    lines.append(f'    (fp_text value "{_esc(str(value))}" (at 0 1.5) (layer "{fab_layer}"){fab_effects})')

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
            # resolved, else the pin's Extra annulus, else the 2x-drill nominal. The
            # land SHAPE is decided by the shared ``th_land`` (also gerber._harvest),
            # emitted below: an equal-axis DEFAULTED land is a round ``circle``
            # annulus, while an OBLONG or authored-cornered (rect/roundrect) land is a
            # faithful shaped land (finding 019f8b7fd295, D1) — the two fab emitters
            # AGREE (not round-only). The DRILL is always round
            # (SUPPORTED_HOLE_SHAPES = {round}).
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


# ===========================================================================
# IR->dict projection (C5b). Moved here from ir_adapter.py so the LIVE KiCad path
# (methods.generate_ir) no longer transits ir_adapter, mirroring the gerber
# precedent (gerber.build_gerbers_ir). The SHARED helpers (_outline_frame,
# _pad_number_map, _pad_to_dict, _graphic_to_dict) live here and are imported BACK
# by ir_adapter.ir_to_board_dict (the gerber test-only path); direction is
# ir_adapter -> kicad only (kicad must NOT import ir_adapter, which would cycle).
# PURE move — no emission-logic change; the projected dict is byte-identical to
# what ir_adapter produced before.
# ===========================================================================


def _outline_frame(outline: BoardOutline) -> tuple[float, float, float, float]:
    """(origin_x, origin_y, width_mm, height_mm) for the board frame. v1 compiles
    a :class:`RectOutline`; a :class:`ProfileOutline` (future) degrades to its
    outer-contour axis-aligned bounding box so Edge.Cuts still frames the board."""
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


def _pad_number_map(board: ResolvedBoard, component: ResolvedComponent) -> dict[str, str]:
    """``{footprint-pad source_id: pad number}`` for this component's footprint.

    A :class:`PlacedPad` carries its footprint ``source_id`` but not the human pad
    NUMBER; the emitter uses the number only for diagnostics / fail-closed pad
    context (never geometry), so recovering it from the interned footprint keeps
    error messages meaningful without touching any emitted byte."""
    definition = board.footprint_for(component)
    return {pad.source_id: pad.number for pad in definition.pads}


def _pad_to_dict(pad: PlacedPad, number: str) -> dict:
    """One :class:`PlacedPad` (BOARD-ABSOLUTE) → the emitter pad-dict shape
    ``pad_source._from_resolved`` reads.

    Geometry is ALREADY absolute + override-baked + side-mirrored (compile_board);
    nothing is re-applied. The TH annulus/drill contract is the load-bearing part:
    ``_from_resolved`` derives ``PadGeom.annulus`` from ``size.width`` (a resolved
    TH pad carries no separate annulus datum — its copper pad width DOUBLES as the
    annulus diameter). So a drilled pad's ``size`` here must be the EFFECTIVE
    annulus: the override-set :attr:`PlacedPad.annulus` when present (round), else
    the footprint copper land :attr:`PlacedPad.size`. ``drill.x`` carries the
    (possibly overridden) round drill; ``rotation`` is the absolute combined pad
    angle the gerber emitter applies to the aperture."""
    is_drilled = pad.drill is not None

    out: dict = {
        "number": number,
        "type": pad.pad_type,
        "shape": pad.shape.value,
        "position": {"x": pad.position[0], "y": pad.position[1]},
        "layers": [layer.id for layer in pad.layers],
        # ABSOLUTE combined angle — read only on the gerber placed path.
        "rotation": pad.rotation_deg,
    }

    # Size: for a drilled pad the width doubles as the annulus (see docstring); an
    # override annulus wins and is round. For an SMD pad it is the copper land.
    width: float | None
    height: float | None
    if is_drilled:
        if pad.annulus is not None:
            width = height = pad.annulus
        elif pad.size is not None:
            width, height = pad.size
        else:
            width = height = None
    else:
        # SMD pads always carry a size in the IR (compile_board fail-closes a
        # copper pad without one); guard defensively anyway.
        width, height = pad.size if pad.size is not None else (None, None)
    if width is not None and height is not None:
        out["size"] = {"width": width, "height": height}

    # Drill: {x, y} from the (possibly overridden) round drill; {0, 0} == no hole,
    # the same sentinel resolve emits (gerber treats drill > 0 as through-hole).
    if is_drilled:
        out["drill"] = {"x": pad.drill.size[0], "y": pad.drill.size[1]}
    else:
        out["drill"] = {"x": 0.0, "y": 0.0}

    # Fab-affecting optionals — present only when the IR carries them, so a plain
    # rect pad stays clean (mirrors resolve._pads_from_parsed).
    if pad.corner_rratio is not None:
        out["corner_rratio"] = pad.corner_rratio
    if pad.solder_mask_margin is not None:
        out["solder_mask_margin"] = pad.solder_mask_margin
    # D1 provenance — omitted when an OVERRIDE annulus (round) supersedes the
    # footprint shape, so an override-annulus pad stays a round annulus.
    if pad.raw_shape is not None and pad.annulus is None:
        out["raw_shape"] = pad.raw_shape
    return out


def _graphic_to_dict(graphic: PlacedGraphic) -> dict:
    """One :class:`PlacedGraphic` (BOARD-ABSOLUTE) → the silk-graphic dict shape
    ``gerber._harvest_silk_graphic`` reads. With the component placed at identity
    the harvest silk transform is a no-op, so the absolute coords pass through.
    Coordinates are emitted as LISTS (the harvest ``isinstance(..., list)`` guards
    reject tuples). Arcs use the modern 3-point ``(start, mid, end)`` form, which
    is exactly what :class:`ArcGeometry` carries."""
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
        out["points"] = [
            [geom.start[0], geom.start[1]],
            [geom.mid[0], geom.mid[1]],
            [geom.end[0], geom.end[1]],
        ]
    elif isinstance(geom, PolygonGeometry):
        out["kind"] = "poly"
        out["points"] = [[p[0], p[1]] for p in geom.points]
    else:  # pragma: no cover - GraphicGeometry is a closed union
        raise TypeError(f"unsupported graphic geometry {type(geom)!r}")
    if graphic.width_mm is not None:
        out["width"] = graphic.width_mm
    return out


def _to_footprint_local(px: float, py: float, rot: float,
                        x: float, y: float) -> tuple[float, float]:
    """Recover the KiCad footprint-LOCAL coordinate a board-ABSOLUTE point must be
    STORED as, by inverting a component placement's translate + rotate. KiCad
    reproduces the absolute on load by re-applying the footprint ``(at px py rot)``;
    the bottom-side MIRROR and the ABSOLUTE pad angle are already baked into the
    PlacedPad, so ONLY translate+rotate is inverted here. Verified vs the pcbnew
    9.0.9 oracle: ``place_point(0,0,-37, 51.794092-50, 37.395919-40) == (3.0,-1.0)``
    and the forward ``place_point(50,40,37, 3,-1)`` returns the absolute.

    Rounded to 6 decimals (KiCad's 1 nm native resolution) so the inverse rotation's
    float noise (a ``5.8e-17`` that should be ``0``) does not leak into the emitted
    ``(at)`` — clean, exactly-reproducible bytes, well within fab tolerance."""
    lx, ly = place_point(0.0, 0.0, -rot, x - px, y - py)
    return (round(lx, 6), round(ly, 6))


def _kicad_component_to_dict(board: ResolvedBoard,
                             component: ResolvedComponent) -> dict:
    """One :class:`ResolvedComponent` -> an emitter component dict at its REAL
    footprint placement (``x/y/rotation`` from :attr:`Placement`) with pad/graphic
    geometry in footprint-LOCAL coords.

    The PlacedPad is board-absolute (override-baked, bottom-mirrored, absolute
    combined angle, correctly-sided layers); :func:`_to_footprint_local` inverts the
    placement translate+rotate to recover the stored local POSITION, while the pad
    ANGLE (absolute) and LAYERS (sided) pass through unchanged — KiCad reads the pad
    ``(at)`` angle as absolute and does not re-flip a B.Cu footprint. KiCad's
    on-load translate+rotate reproduces the identical absolute geometry, so
    fabrication is unchanged while the footprint sits at its real placement (CPL /
    editability restored)."""
    number_of = _pad_number_map(board, component)
    definition = board.footprint_for(component)
    px, py = component.placement.position
    rot = component.placement.rotation_deg

    def _local_pad(pad: PlacedPad) -> dict:
        out = _pad_to_dict(pad, number_of.get(pad.source_id, ""))
        lx, ly = _to_footprint_local(px, py, rot, pad.position[0], pad.position[1])
        out["position"] = {"x": lx, "y": ly}   # local; angle + layers stay absolute/sided
        return out

    def _local_graphic(graphic: PlacedGraphic) -> dict:
        out = _graphic_to_dict(graphic)
        _localize_graphic_points(out, px, py, rot)
        return out

    return {
        "ref": component.ref,
        "value": component.value,
        "footprint": definition.name,
        "x_mm": px,
        "y_mm": py,
        "rotation_deg": rot,
        "layer": "top" if component.placement.side is Side.TOP else "bottom",
        "pads": [_local_pad(pad) for pad in component.placed_pads],
        # Only F.SilkS is rendered by the kicad emitter (bottom-side B.SilkS silk is
        # dropped as before — cosmetic, non-fabrication-critical). Localized so the
        # silk lands correctly under the real footprint (at), not double-transformed.
        "graphics": [
            _local_graphic(g) for g in component.placed_graphics
            if g.layer.id == "F.SilkS"
        ],
    }


def _localize_graphic_points(graphic_dict: dict, px: float, py: float,
                             rot: float) -> None:
    """In-place: rewrite a graphic dict's ABSOLUTE coordinate fields to footprint-
    LOCAL (``_to_footprint_local``). ``radius`` is rotation/translation-invariant, so
    only the point fields (start/end/center + the arc/poly points list) move."""
    def loc(pt: list) -> list:
        return list(_to_footprint_local(px, py, rot, pt[0], pt[1]))
    for key in ("start", "end", "center"):
        if key in graphic_dict:
            graphic_dict[key] = loc(graphic_dict[key])
    if "points" in graphic_dict:
        graphic_dict["points"] = [loc(p) for p in graphic_dict["points"]]


def _mounting_hole_refs(existing_refs: set[str], count: int) -> list[str]:
    """``count`` collision-free ``MountingHole`` refs (H1, H2, ...) that SKIP any
    ref a real component already uses. Without this a user component named ``H1``
    would duplicate a synthetic mounting-hole ref in the .kicad_pcb — a duplicate
    reference KiCad flags (Fable W8.2b note)."""
    used = set(existing_refs)
    out: list[str] = []
    n = 0
    while len(out) < count:
        n += 1
        ref = f"H{n}"
        if ref not in used:
            used.add(ref)
            out.append(ref)
    return out


def _kicad_mounting_hole_component(hole: ResolvedHole, ref: str) -> dict:
    """A board-level :class:`ResolvedHole` -> a synthetic ``MountingHole`` component
    the kicad emitter renders as one bare through-hole pad.

    KiCad represents a standalone drill as a footprint carrying a single drilled
    pad. We emit one ``MountingHole`` footprint at the hole's REAL position with the
    pad at footprint-LOCAL origin (0, 0), consistent with the real-placement
    component footprints — ``kicad._footprint`` translates the origin-local pad by
    the footprint ``(at)`` and drills it exactly where the IR says, and the hole
    footprint reads correctly in KiCad (its origin is on the drill).

    Plating drives the padstack via ``pad_source._from_resolved`` +
    ``kicad._footprint``: a NON-plated hole (NPTH / an unplated MOUNTING hole) is a
    bare ``np_thru_hole`` with size == drill (no copper, no net); a PLATED hole
    (PTH) is a ``thru_hole`` whose copper size is the hole's AUTHORED
    ``annulus_mm`` (finding 019f8dbb7104) — NOT an invented 2x-drill nominal, so the
    kicad annulus matches the gerber annulus exactly. The empty pad NUMBER matches
    KiCad's real mounting-hole footprints. FAIL-CLOSED on a non-round feature stays
    intact (the round-only drill seal); a plated hole always carries an authored
    annulus by the time it reaches here (the compiler fail-closes otherwise)."""
    feature = hole.feature
    if not isinstance(feature, RoundHole):
        raise ValueError(
            f"hole {hole.id!r} has a non-round feature {type(feature).__name__} the "
            f"round-only fabrication path cannot drill — refusing to drop it silently")
    diameter = feature.diameter_mm
    pad: dict = {
        "number": "",
        "type": "thru_hole" if hole.plated else "np_thru_hole",
        "shape": "circle",
        "position": {"x": 0.0, "y": 0.0},   # footprint-local; footprint (at) is the hole
        "drill": {"x": diameter, "y": diameter},
        "layers": ["*.Cu", "*.Mask"],
    }
    # NPTH/unplated: size == drill (no copper ring). PLATED: size == the AUTHORED
    # annulus (its copper ring diameter), which pad_source._from_resolved reads as
    # the thru_hole annulus — the same value the gerber bridge emits. A plated
    # ResolvedHole is GUARANTEED to carry an annulus (ResolvedHole.__post_init__
    # enforces it), so this is total, not a strippable assert.
    if hole.plated:
        pad["size"] = {"width": hole.annulus_mm, "height": hole.annulus_mm}
    else:
        pad["size"] = {"width": diameter, "height": diameter}
    return {
        "ref": ref,
        "value": "",
        "footprint": "MountingHole",
        "x_mm": feature.position[0],
        "y_mm": feature.position[1],
        "rotation_deg": 0.0,
        "layer": "top",
        "pads": [pad],
        "graphics": [],
    }


def _kicad_net_dicts(board: ResolvedBoard) -> list[dict]:
    """Each :class:`ResolvedNet` -> the ``{name, pins:["REF.PADNUM", ...]}`` dict
    kicad._net_table reads. A net's ``pad_refs`` are PlacedPad ids; kicad wants
    ``REF.PADNUM``, so each placed-pad id is resolved to its component ref + the
    footprint pad NUMBER (via source_id) — the same join kicad's pad_net expects."""
    pin_of: dict[str, str] = {}
    for component in board.components:
        number_of = {pad.source_id: pad.number
                     for pad in board.footprint_for(component).pads}
        for placed in component.placed_pads:
            pin_of[placed.id] = f"{component.ref}.{number_of.get(placed.source_id, '')}"
    return [
        {"name": net.name, "pins": [pin_of[ref] for ref in net.pad_refs]}
        for net in board.nets
    ]


def _kicad_trace_dicts(board: ResolvedBoard, net_name_of: dict[str, str]) -> list[dict]:
    """Like :func:`_trace_dicts` but tagged with the trace's NET NAME — kicad
    assigns each ``segment`` a net index from ``board["nets"]``, so a routed board
    keeps its copper on-net (gerber ignores nets, hence the divergent projection)."""
    out: list[dict] = []
    for trace in board.traces:
        name = net_name_of.get(trace.net_id, "")
        for seg in trace.segments:
            out.append({
                "layer": seg.layer.id,
                "width_mm": seg.width_mm,
                "net": name,
                "points": [
                    {"x_mm": seg.a[0], "y_mm": seg.a[1]},
                    {"x_mm": seg.b[0], "y_mm": seg.b[1]},
                ],
            })
    return out


def _kicad_via_dicts(board: ResolvedBoard, net_name_of: dict[str, str]) -> list[dict]:
    return [
        {
            "x_mm": via.position[0],
            "y_mm": via.position[1],
            "diameter_mm": via.diameter_mm,
            "drill_mm": via.drill_mm,
            "net": net_name_of.get(via.net_id, ""),
            "tented_front": via.tented_front,
            "tented_back": via.tented_back,
        }
        for via in board.vias
    ]


def _ir_board_dict(board: ResolvedBoard) -> dict:
    """Project a :class:`ResolvedBoard` (K2 IR) into the loosely-typed emitter
    board_dict that ``kicad.generate`` consumes, with each footprint at its REAL
    placement ``(at px py rot)`` and pad/graphic geometry in footprint-LOCAL coords.

    KiCad applies only translate+rotate on load (no native flip) and reads the pad
    ``(at)`` third value as the ABSOLUTE angle. The IR's board-absolute PlacedPad is
    projected back to the stored footprint-local POSITION by inverting the placement
    translate+rotate (:func:`_to_footprint_local`), while the absolute angle, sided
    layers, and baked-in overrides + bottom mirror pass through unchanged — KiCad's
    on-load transform reproduces the identical absolute geometry (fabrication /
    registration unchanged) while the footprint sits at its real placement, so the
    .kicad_pcb keeps component placement, editability, and assembly/CPL semantics
    (finding 019f8dbb6593). Additionally emits ``nets`` (kicad assigns
    pad/segment/via nets from them) and net-tagged traces/vias, which the gerber
    bridge omits. PURE + deterministic — the ResolvedBoard is only read.

    Board-level HOLES (mounting holes) are EMITTED faithfully: each round
    :class:`ResolvedHole` becomes a synthetic ``MountingHole`` footprint at the
    hole's real position carrying a single bare through-hole pad at footprint-local
    origin — an unplated hole as ``np_thru_hole`` (no copper), a plated one as
    ``thru_hole`` with a copper annulus (see :func:`_kicad_mounting_hole_component`).
    A non-round hole feature still RAISES (the round-only drill seal).

    FAIL-CLOSED seals (mirroring the gerber bridge): a captured feature the kicad
    emitter cannot render — a zone or a board-level graphic — must RAISE, never
    vanish silently from a fabrication-bound file. compile_board fail-closes
    zones/board-graphics upstream (always empty today), so these seal the adapter
    against a future IR silently dropping copper at the cutover."""
    if board.zones:
        raise ValueError(
            f"kicad._ir_board_dict: board has {len(board.zones)} zone(s) the kicad "
            f"bridge does not map yet — refusing to silently drop copper")
    if board.board_graphics:
        raise ValueError(
            f"kicad._ir_board_dict: board has {len(board.board_graphics)} board-level "
            f"graphic(s) the kicad bridge does not map yet — refusing to drop them silently")

    ox, oy, width_mm, height_mm = _outline_frame(board.outline)
    rules = board.design_rules
    net_name_of = {net.id: net.name for net in board.nets}

    # Real components first, then the synthetic mounting-hole footprints (in
    # board.holes order — deterministic). Their refs (H1, H2, ...) SKIP any real
    # component ref so the .kicad_pcb never carries a duplicate reference; they
    # carry no net, so nets/traces/vias are unaffected.
    components = [_kicad_component_to_dict(board, comp) for comp in board.components]
    hole_refs = _mounting_hole_refs({comp.ref for comp in board.components}, len(board.holes))
    components += [_kicad_mounting_hole_component(hole, ref)
                   for hole, ref in zip(board.holes, hole_refs)]

    return {
        "name": board.name,
        "width_mm": width_mm,
        "height_mm": height_mm,
        "origin": {"x_mm": ox, "y_mm": oy},
        "design_rules": {
            "trace_width_mm": rules.defaults.trace_width_mm,
            "via_diameter_mm": rules.defaults.via_diameter_mm,
            "via_drill_mm": rules.defaults.via_drill_mm,
            "solder_mask_clearance_mm": rules.minimums.solder_mask_clearance_mm,
        },
        "nets": _kicad_net_dicts(board),
        "components": components,
        "traces": _kicad_trace_dicts(board, net_name_of),
        "vias": _kicad_via_dicts(board, net_name_of),
    }


def generate_ir(board: ResolvedBoard, base_name: str | None = None) -> KicadResult:
    """Generate the three KiCad files DIRECTLY from a :class:`ResolvedBoard` (K2 IR)
    — the IR-native entry the live path uses, with no IR->loose-dict transit through
    ir_adapter (C5b, mirroring gerber.build_gerbers_ir). Projects the IR into the
    emitter board_dict via :func:`_ir_board_dict` then emits exactly as
    :func:`generate` does, so the returned KicadResult (files AND ``.diagnostics``)
    is byte-identical to ``generate(_ir_board_dict(board), base_name)``."""
    return generate(_ir_board_dict(board), base_name=base_name)
