"""Canonical-board → :class:`ResolvedBoard` compiler (K2, hermetic-CAM keystone).

This module is the SOLE constructor of the placed-geometry projection.  It takes
a canonical board dict (docs/board-yaml.md — the same shape ``resolve_board``
consumes) plus the sha-verified seed footprint library and returns a
:class:`ResolutionResult`:

* :class:`ResolutionSuccess` — a valid-by-construction :class:`ResolvedBoard`
  plus WARNING/INFO diagnostics for non-fatal feature omissions, OR
* :class:`ResolutionFailure` — one or more ERROR diagnostics and NO board.

It is STRICT and FAIL-CLOSED (K1 Sol reconcile, keystone comment 608): no
invented geometry, no defaults.  A pad with no declared copper size, a hole that
is not round, a via that is not through, a board that is not a two-layer rect —
every capability outside the bounded v1 subset is an ERROR, never a silent
substitution.  Feature markers the parser attached (K1) are ADJUDICATED here by
a :class:`CapabilityPolicy`: a marker whose loss corrupts a requested
fabrication output is fatal; a documentation/silk/fab omission becomes a WARNING
and is stripped from the interned footprint definition (the IR forbids any
residual marker — see ``ResolvedBoard.__post_init__``).

Gating: this module is default-OFF by *non-wiring*.  Nothing in the live worker
path imports it; K3 repoints the emitters onto the IR behind an explicit flag.
So merely landing this file changes no existing behaviour.

Placement: the ONE transform (``geometry.PlacementTransform``, mirror included)
materializes every ``PlacedPad``/``PlacedGraphic`` ONCE.  Source identity
(placed entity → footprint source id) and the transform version are recorded and
asserted by ``ResolvedBoard`` construction.
"""

from __future__ import annotations

from dataclasses import replace
from pathlib import Path
from typing import Iterable, Union

from .canonical_id import content_id, derive_id
from .footprint_def import FootprintDefinition, PadDefinition
from .footprints import FootprintLookupError, resolve_footprint
from .geometry import PlacementTransform
from .resolved_board import (
    ArcGeometry,
    BoardProvenance,
    CircleGeometry,
    Diagnostic,
    DiagnosticSeverity,
    EntityKind,
    GraphicGeometry,
    Layer,
    LayerRole,
    LayerStack,
    LineGeometry,
    ManufacturingConstraints,
    NetClass,
    PhysicalStackup,
    Placement,
    PlacedGraphic,
    PlacedPad,
    PolygonGeometry,
    RectOutline,
    ResolvedBoard,
    ResolvedComponent,
    ResolvedDesignRules,
    ResolvedHole,
    ResolvedLayer,
    ResolvedNet,
    ResolvedTrace,
    ResolvedTraceSegment,
    ResolvedVia,
    ResolutionFailure,
    ResolutionResult,
    ResolutionSuccess,
    RoundHole,
    RoutingDefaults,
    RuleProfileRef,
    Side,
    SourceRef,
    StackupEntry,
    StackupKind,
    UnsupportedFeature,
    ViaKind,
)

# The transform whose sign/mirror convention placed geometry commits to; pinned
# by geometry.PlacementTransform + k1_bottom_oracle.  Recorded on provenance so a
# future convention change is a detectable identity change, not silent drift.
TRANSFORM_VERSION = "kicad-flip-v1"
COMPILER_VERSION = "pcb-k2/1"

# Coincidence tolerance (mm) — a board that declares per-pin local positions must
# agree with the resolved footprint pad of the same number, else silk desyncs
# from copper.  Same threshold the legacy resolve path enforces.
COINCIDENCE_TOL_MM = 0.01

# Canonical board layer ids (v1: exactly two copper layers) → KiCad aliases.
_TOP_ID, _BOTTOM_ID = "top", "bottom"
_COPPER_ALIAS = {_TOP_ID: "F.Cu", _BOTTOM_ID: "B.Cu"}

# Technical (non-copper) layers the IR advertises for v1 boards.
_TECHNICAL_LAYER_IDS = (
    "F.SilkS", "B.SilkS", "F.Mask", "B.Mask",
    "F.Paste", "B.Paste", "F.Fab", "B.Fab",
    "F.CrtYd", "B.CrtYd", "Edge.Cuts",
)

# v1 fabrication outputs a marker can corrupt.  A blocking-domain marker is fatal
# only when its output is actually requested (keystone comment 618 point 2).
V1_FAB_OUTPUTS: tuple[str, ...] = (
    "copper", "drill", "mask", "paste", "silk", "fab", "documentation", "edge",
)

# Conservative manufacturing floor (a VERSIONED, digest-pinned rule source — the
# only sanctioned origin for a design-rule minimum, keystone comment 608
# fail-closed sweep).  Board-authored clearance overrides min_clearance below.
_V1_MANUFACTURING_FLOOR = {
    "min_trace_width_mm": 0.127,
    "min_clearance_mm": 0.127,
    "min_drill_mm": 0.2,
    "min_finished_hole_mm": 0.2,
    "min_annular_ring_mm": 0.13,
    "min_hole_to_hole_mm": 0.25,
    "min_mask_sliver_mm": 0.1,
    "solder_mask_clearance_mm": 0.05,
    "solder_mask_expansion_mm": 0.0,
    "copper_to_edge_mm": 0.3,
}


def _v1_rule_profile() -> RuleProfileRef:
    digest = content_id({"floor": _V1_MANUFACTURING_FLOOR, "profile": "v1-conservative"})
    return RuleProfileRef(id="v1-fab-conservative", version="1", digest=digest[:32])


V1_RULE_PROFILE = _v1_rule_profile()


class DefaultCapabilityPolicy:
    """v1 fatality policy (implements the :class:`CapabilityPolicy` protocol).

    A parser marker is fatal iff it *defaults* to blocking AND its loss corrupts
    a requested output.  Documentation/silk/fab omissions and context-inert
    markers (``zone_connect`` with no zones) are non-blocking and become
    warnings.  ``requested_outputs`` narrows fatality: emitting only a drill file
    means a copper-only defect need not fail the whole compile.
    """

    def is_blocking(
        self,
        marker: UnsupportedFeature,
        board_context: object,
        requested_outputs: tuple[str, ...],
    ) -> bool:
        if not marker.default_blocking:
            return False
        if not requested_outputs:
            return True
        if marker.domain.value in requested_outputs:
            return True
        return any(output in requested_outputs for output in marker.affected_outputs)


class _Diagnostics:
    """Accumulator that also tracks whether any ERROR was recorded."""

    def __init__(self) -> None:
        self._items: list[Diagnostic] = []
        self.has_error = False

    def add(self, severity: DiagnosticSeverity, code: str, message: str,
            source_ref: SourceRef) -> None:
        self._items.append(Diagnostic(severity, code, message, source_ref))
        if severity is DiagnosticSeverity.ERROR:
            self.has_error = True

    def error(self, code: str, message: str, ref: SourceRef) -> None:
        self.add(DiagnosticSeverity.ERROR, code, message, ref)

    def warning(self, code: str, message: str, ref: SourceRef) -> None:
        self.add(DiagnosticSeverity.WARNING, code, message, ref)

    def tuple(self) -> tuple[Diagnostic, ...]:
        return tuple(self._items)


def _board_ref(entity_id: str = "<board>", detail: Union[str, None] = None) -> SourceRef:
    return SourceRef(EntityKind.BOARD, entity_id, detail)


# ---------------------------------------------------------------------------
# Board frame: outline, layer stack, design rules.
# ---------------------------------------------------------------------------


def _require_two_layer(board: dict, diags: _Diagnostics) -> bool:
    layers = board.get("layers")
    if layers is None:
        # A board that omits the layer list is the canonical two-layer default
        # only when it declares nothing exotic; treat absence as top+bottom.
        return True
    if not isinstance(layers, list) or [str(x) for x in layers] != [_TOP_ID, _BOTTOM_ID]:
        diags.error(
            "unsupported_layer_stack",
            f"v1 compiles exactly two copper layers [top, bottom]; got {layers!r}",
            _board_ref(),
        )
        return False
    return True


def _build_outline(board: dict, diags: _Diagnostics) -> Union[RectOutline, None]:
    width, height = board.get("width_mm"), board.get("height_mm")
    if not _is_positive_number(width) or not _is_positive_number(height):
        diags.error(
            "unsupported_outline",
            f"v1 requires a rectangular outline with positive width_mm/height_mm; "
            f"got width_mm={width!r} height_mm={height!r}",
            _board_ref(),
        )
        return None
    return RectOutline(origin=(0.0, 0.0), width_mm=float(width), height_mm=float(height))


def _build_layer_stack() -> LayerStack:
    copper = (
        ResolvedLayer(id=_TOP_ID, kicad_alias=_COPPER_ALIAS[_TOP_ID], stack_index=0),
        ResolvedLayer(id=_BOTTOM_ID, kicad_alias=_COPPER_ALIAS[_BOTTOM_ID], stack_index=1),
    )
    stackup = PhysicalStackup(entries=(
        StackupEntry(id="F.Cu", order=0, kind=StackupKind.COPPER,
                     thickness_mm=0.035, material="copper", copper_layer_id=_TOP_ID),
        StackupEntry(id="dielectric", order=1, kind=StackupKind.DIELECTRIC,
                     thickness_mm=1.51, material="FR4"),
        StackupEntry(id="B.Cu", order=2, kind=StackupKind.COPPER,
                     thickness_mm=0.035, material="copper", copper_layer_id=_BOTTOM_ID),
    ))
    technical = tuple(Layer.from_id(layer_id) for layer_id in _TECHNICAL_LAYER_IDS)
    return LayerStack(copper=copper, stackup=stackup, technical=technical)


def _build_design_rules(board: dict, diags: _Diagnostics) -> Union[ResolvedDesignRules, None]:
    rules = board.get("design_rules")
    if not isinstance(rules, dict):
        diags.error("missing_design_rules",
                    "board has no design_rules block; v1 refuses to invent trace/via/clearance",
                    _board_ref())
        return None
    trace_width = rules.get("trace_width_mm")
    via_diameter = rules.get("via_diameter_mm")
    via_drill = rules.get("via_drill_mm")
    clearance = rules.get("clearance_mm")
    for name, value in (("trace_width_mm", trace_width), ("via_diameter_mm", via_diameter),
                        ("via_drill_mm", via_drill), ("clearance_mm", clearance)):
        if not _is_positive_number(value):
            diags.error("invalid_design_rule",
                        f"design_rules.{name} must be a positive number; got {value!r}",
                        _board_ref())
    if diags.has_error:
        return None
    if float(via_drill) >= float(via_diameter):
        diags.error("invalid_design_rule",
                    f"via_drill_mm ({via_drill}) must be smaller than via_diameter_mm ({via_diameter})",
                    _board_ref())
        return None
    minimums = replace_floor_clearance(float(clearance))
    return ResolvedDesignRules(
        defaults=RoutingDefaults(
            trace_width_mm=float(trace_width),
            via_diameter_mm=float(via_diameter),
            via_drill_mm=float(via_drill),
        ),
        minimums=minimums,
        allowed_via_kinds=(ViaKind.THROUGH,),
        net_classes=(),
        rule_profile=V1_RULE_PROFILE,
    )


def replace_floor_clearance(board_clearance_mm: float) -> ManufacturingConstraints:
    """v1 manufacturing floor with the board's authored clearance as min_clearance.

    The board's declared clearance is a RESOLVED design value (what DRC enforces),
    not an invented default; every other minimum comes from the versioned,
    digest-pinned v1 rule profile.
    """
    floor = dict(_V1_MANUFACTURING_FLOOR)
    floor["min_clearance_mm"] = board_clearance_mm
    return ManufacturingConstraints(**floor)


# ---------------------------------------------------------------------------
# Footprint adjudication + interning.
# ---------------------------------------------------------------------------


def _adjudicate_footprint(
    definition: FootprintDefinition,
    ref: str,
    policy: DefaultCapabilityPolicy,
    requested_outputs: tuple[str, ...],
    board: dict,
    diags: _Diagnostics,
) -> Union[FootprintDefinition, None]:
    """Adjudicate every parser marker on *definition*; return a marker-free clone.

    Blocking markers become ERROR diagnostics (and the footprint yields ``None``);
    non-blocking markers become WARNINGs and are stripped so the resulting
    definition satisfies the IR's no-residual-marker invariant.
    """
    blocked = False

    def judge(markers: Iterable[UnsupportedFeature]) -> None:
        nonlocal blocked
        for marker in markers:
            if policy.is_blocking(marker, board, requested_outputs):
                diags.error(
                    "unsupported_feature",
                    f"footprint {ref!r}: {marker.feature} on {marker.domain.value} "
                    f"({marker.detail}) corrupts a requested fabrication output",
                    marker.source_ref,
                )
                blocked = True
            else:
                diags.warning(
                    "feature_omitted",
                    f"footprint {ref!r}: {marker.feature} on {marker.domain.value} "
                    f"({marker.detail}) is not fabricated in v1",
                    marker.source_ref,
                )

    judge(definition.unsupported)
    for pad in definition.pads:
        judge(pad.unsupported)

    if blocked:
        return None
    stripped_pads = tuple(replace(pad, unsupported=()) for pad in definition.pads)
    return replace(definition, pads=stripped_pads, unsupported=())


def _check_pad_capabilities(
    pad: PadDefinition, ref: str, diags: _Diagnostics,
) -> bool:
    """Fail-closed guards for the bounded v1 pad subset. True == acceptable."""
    ok = True
    pad_ref = SourceRef(EntityKind.PAD, pad.source_id, f"component {ref}")
    if not pad.shape.is_supported:
        diags.error("unsupported_pad_shape",
                    f"component {ref!r} pad {pad.number!r}: shape {pad.shape.value} "
                    f"is outside the v1 rect/roundrect/circle/oval subset",
                    pad_ref)
        ok = False
    has_copper = any(layer.role is LayerRole.COPPER for layer in pad.layers)
    if has_copper and pad.size is None:
        diags.error("missing_pad_size",
                    f"component {ref!r} pad {pad.number!r}: copper pad has no declared "
                    f"size; v1 refuses to invent one",
                    pad_ref)
        ok = False
    if pad.drill is not None and pad.drill.shape not in ("round", "circle"):
        diags.error("unsupported_hole",
                    f"component {ref!r} pad {pad.number!r}: {pad.drill.shape} drill is "
                    f"outside the v1 round-hole subset",
                    pad_ref)
        ok = False
    return ok


# ---------------------------------------------------------------------------
# Placed-geometry projection.
# ---------------------------------------------------------------------------


def _to_geometry(graphic) -> GraphicGeometry:
    """Map a footprint-local GraphicDefinition to a local GraphicGeometry."""
    kind = type(graphic).__name__
    if kind == "LineGraphic":
        return LineGeometry(graphic.a, graphic.b)
    if kind == "CircleGraphic":
        return CircleGeometry(graphic.center, graphic.radius_mm)
    if kind == "ArcGraphic":
        return ArcGeometry(graphic.start, graphic.mid, graphic.end)
    return PolygonGeometry(graphic.points)


def _place_component(
    comp: dict,
    component_id: str,
    definition: FootprintDefinition,
    side: Side,
    pin_net: dict[tuple[str, str], str],
    ref: str,
) -> tuple[tuple[PlacedPad, ...], tuple[PlacedGraphic, ...]]:
    transform = PlacementTransform(
        position=(float(comp["x_mm"]), float(comp["y_mm"])),
        rotation_deg=float(comp.get("rotation_deg") or 0.0),
        side=side,
    )
    placed_pads: list[PlacedPad] = []
    for pad in definition.pads:
        net_id = pin_net.get((ref, pad.number))
        size = (float(pad.size[0]), float(pad.size[1])) if pad.size is not None else None
        placed_pads.append(PlacedPad(
            id=derive_id("placed-pad", component_id, pad.source_id),
            component_id=component_id,
            source_id=pad.source_id,
            net_id=net_id,
            pad_type=pad.pad_type,
            shape=pad.shape,
            position=transform.point(pad.position),
            size=size,
            rotation_deg=transform.angle(pad.rotation_deg),
            corner_rratio=pad.corner_rratio,
            drill=pad.drill,
            annulus=None,
            solder_mask_margin=pad.solder_mask_margin,
            solder_paste_margin=pad.solder_paste_margin,
            layers=transform.layers(pad.layers),
            side=side,
        ))
    placed_graphics: list[PlacedGraphic] = []
    for graphic in definition.graphics:
        placed_graphics.append(PlacedGraphic(
            id=derive_id("placed-graphic", component_id, graphic.source_id),
            component_id=component_id,
            source_id=graphic.source_id,
            layer=transform.layer(graphic.layer),
            geometry=transform.graphic(_to_geometry(graphic)),
            width_mm=graphic.width_mm,
        ))
    return tuple(placed_pads), tuple(placed_graphics)


def _check_coincidence(comp: dict, definition: FootprintDefinition, ref: str,
                       diags: _Diagnostics) -> None:
    """If the board declares per-pin local positions, prove they match the
    footprint pads of the same number (fail-closed — silk/copper desync)."""
    pins = comp.get("pins")
    if not isinstance(pins, list):
        return
    pad_by_number: dict[str, PadDefinition] = {}
    for pad in definition.pads:
        pad_by_number.setdefault(pad.number, pad)
    for pin in pins:
        if not isinstance(pin, dict):
            continue
        number = str(pin.get("number"))
        px, py = pin.get("x_mm"), pin.get("y_mm")
        if not _is_number(px) or not _is_number(py):
            continue
        pad = pad_by_number.get(number)
        pad_ref = SourceRef(EntityKind.PAD, f"{ref}.{number}", f"component {ref}")
        if pad is None:
            diags.error("pin_without_pad",
                        f"component {ref!r} pin {number!r} has no matching footprint pad",
                        pad_ref)
            continue
        dx, dy = pad.position[0] - float(px), pad.position[1] - float(py)
        if (dx * dx + dy * dy) ** 0.5 > COINCIDENCE_TOL_MM:
            diags.error("pin_pad_desync",
                        f"component {ref!r} pin {number!r}: declared local ({px}, {py}) "
                        f"vs footprint pad {pad.position} exceeds {COINCIDENCE_TOL_MM}mm",
                        pad_ref)


# ---------------------------------------------------------------------------
# Nets, traces, vias, holes.
# ---------------------------------------------------------------------------


def _split_pin_ref(token: str) -> Union[tuple[str, str], None]:
    if not isinstance(token, str) or "." not in token:
        return None
    ref, number = token.rsplit(".", 1)
    if not ref or not number:
        return None
    return ref, number


def _build_nets_index(board: dict, diags: _Diagnostics) -> tuple[dict[str, str], dict[str, int], dict[tuple[str, str], str], list[tuple[str, str, int, list[str]]]]:
    """Return (name→net_id, name→index, (ref,num)→net_id, ordered net descriptors).

    Net index is assigned in canonical NAME-sorted order (KiCad reserves 0), so a
    semantically-harmless reordering of the board's net list does not renumber
    the board (keystone comment 608, Q3).
    """
    raw_nets = board.get("nets") or []
    name_to_id: dict[str, str] = {}
    name_to_index: dict[str, int] = {}
    pin_net: dict[tuple[str, str], str] = {}
    descriptors: list[tuple[str, str, int, list[str]]] = []
    names = []
    for net in raw_nets:
        if not isinstance(net, dict):
            continue
        name = net.get("name")
        if not isinstance(name, str) or not name:
            diags.error("invalid_net", f"net without a name: {net!r}", _board_ref())
            continue
        if name in name_to_id:
            diags.error("duplicate_net", f"net {name!r} declared more than once", _board_ref())
            continue
        names.append(name)
        name_to_id[name] = derive_id("net", name)
    for index, name in enumerate(sorted(names), start=1):
        name_to_index[name] = index
    for net in raw_nets:
        if not isinstance(net, dict):
            continue
        name = net.get("name")
        if not isinstance(name, str) or name not in name_to_id:
            continue
        pin_tokens: list[str] = []
        for token in net.get("pins") or []:
            parsed = _split_pin_ref(token)
            if parsed is None:
                diags.error("invalid_pin_ref",
                            f"net {name!r}: pin ref {token!r} is not 'REF.NUMBER'",
                            _board_ref())
                continue
            pin_net[parsed] = name_to_id[name]
            pin_tokens.append(token)
        descriptors.append((name_to_id[name], name, name_to_index[name], pin_tokens))
    return name_to_id, name_to_index, pin_net, descriptors


def _build_traces(board: dict, net_id_by_name: dict[str, str],
                  diags: _Diagnostics) -> tuple[ResolvedTrace, ...]:
    traces: list[ResolvedTrace] = []
    for ordinal, raw in enumerate(board.get("traces") or []):
        if not isinstance(raw, dict):
            continue
        net_name = raw.get("net")
        net_id = net_id_by_name.get(net_name) if isinstance(net_name, str) else None
        trace_ref = SourceRef(EntityKind.TRACE, f"trace:{ordinal}", f"net {net_name}")
        if net_id is None:
            diags.error("trace_unknown_net",
                        f"trace {ordinal}: references unknown net {net_name!r}", trace_ref)
            continue
        layer_id = str(raw.get("layer") or "")
        layer = Layer.from_id(layer_id) if layer_id else None
        if layer is None or layer.id not in _COPPER_ALIAS:
            diags.error("trace_bad_layer",
                        f"trace {ordinal}: layer {layer_id!r} is not a v1 copper layer", trace_ref)
            continue
        width = raw.get("width_mm")
        if not _is_positive_number(width):
            diags.error("trace_bad_width",
                        f"trace {ordinal}: width_mm {width!r} is not positive", trace_ref)
            continue
        points = _extract_points(raw.get("points"))
        if len(points) < 2:
            diags.error("trace_degenerate",
                        f"trace {ordinal}: needs at least two points, got {len(points)}", trace_ref)
            continue
        trace_id = derive_id("trace", net_id, str(ordinal))
        segments: list[ResolvedTraceSegment] = []
        seg_ordinal = 0
        degenerate = False
        for a, b in zip(points, points[1:]):
            if a == b:
                diags.error("trace_degenerate",
                            f"trace {ordinal}: zero-length segment at {a}", trace_ref)
                degenerate = True
                break
            segments.append(ResolvedTraceSegment(
                id=derive_id("segment", trace_id, str(seg_ordinal)),
                a=a, b=b, width_mm=float(width), layer=layer,
            ))
            seg_ordinal += 1
        if degenerate or not segments:
            continue
        traces.append(ResolvedTrace(id=trace_id, net_id=net_id, segments=tuple(segments)))
    return tuple(traces)


def _build_vias(board: dict, net_id_by_name: dict[str, str],
                diags: _Diagnostics) -> tuple[ResolvedVia, ...]:
    vias: list[ResolvedVia] = []
    for ordinal, raw in enumerate(board.get("vias") or []):
        if not isinstance(raw, dict):
            continue
        net_name = raw.get("net")
        net_id = net_id_by_name.get(net_name) if isinstance(net_name, str) else None
        via_ref = SourceRef(EntityKind.VIA, f"via:{ordinal}", f"net {net_name}")
        if net_id is None:
            diags.error("via_unknown_net",
                        f"via {ordinal}: references unknown net {net_name!r}", via_ref)
            continue
        x, y = raw.get("x_mm"), raw.get("y_mm")
        diameter, drill = raw.get("diameter_mm"), raw.get("drill_mm")
        from_layer, to_layer = str(raw.get("from_layer") or ""), str(raw.get("to_layer") or "")
        if not (_is_number(x) and _is_number(y)):
            diags.error("via_bad_position", f"via {ordinal}: non-finite position", via_ref)
            continue
        if not (_is_positive_number(diameter) and _is_positive_number(drill)):
            diags.error("via_bad_size",
                        f"via {ordinal}: diameter_mm/drill_mm must be positive "
                        f"(got {diameter!r}/{drill!r})", via_ref)
            continue
        if float(drill) >= float(diameter):
            diags.error("via_bad_size",
                        f"via {ordinal}: drill {drill} must be smaller than diameter {diameter}",
                        via_ref)
            continue
        if from_layer not in _COPPER_ALIAS or to_layer not in _COPPER_ALIAS or from_layer == to_layer:
            diags.error("via_bad_span",
                        f"via {ordinal}: span {from_layer!r}->{to_layer!r} is not a legal "
                        f"v1 through-via across [top, bottom]", via_ref)
            continue
        vias.append(ResolvedVia(
            id=derive_id("via", net_id, str(ordinal)),
            position=(float(x), float(y)),
            diameter_mm=float(diameter),
            drill_mm=float(drill),
            net_id=net_id,
            kind=ViaKind.THROUGH,
            from_layer=from_layer,
            to_layer=to_layer,
            tented_front=False,
            tented_back=False,
        ))
    return tuple(vias)


def _build_holes(board: dict, diags: _Diagnostics) -> tuple[ResolvedHole, ...]:
    from .resolved_board import HoleKind

    holes: list[ResolvedHole] = []
    for ordinal, raw in enumerate(board.get("mounting_holes") or []):
        if not isinstance(raw, dict):
            continue
        x, y, diameter = raw.get("x_mm"), raw.get("y_mm"), raw.get("diameter_mm")
        hole_ref = SourceRef(EntityKind.HOLE, f"mounting:{ordinal}")
        if not (_is_number(x) and _is_number(y) and _is_positive_number(diameter)):
            diags.error("hole_bad_geometry",
                        f"mounting hole {ordinal}: needs finite x/y and positive diameter", hole_ref)
            continue
        plated = bool(raw.get("plated", False))
        kind = HoleKind.PTH if plated else HoleKind.NPTH
        holes.append(ResolvedHole(
            id=derive_id("hole", "mounting", str(ordinal)),
            feature=RoundHole(position=(float(x), float(y)), diameter_mm=float(diameter)),
            plated=plated,
            kind=kind,
        ))
    return tuple(holes)


# ---------------------------------------------------------------------------
# Small numeric helpers.
# ---------------------------------------------------------------------------


def _is_number(value) -> bool:
    import math
    return (not isinstance(value, bool) and isinstance(value, (int, float))
            and math.isfinite(value))


def _is_positive_number(value) -> bool:
    return _is_number(value) and value > 0


def _extract_points(raw_points) -> list[tuple[float, float]]:
    points: list[tuple[float, float]] = []
    if not isinstance(raw_points, list):
        return points
    for item in raw_points:
        if isinstance(item, dict):
            x, y = item.get("x_mm"), item.get("y_mm")
        elif isinstance(item, (list, tuple)) and len(item) >= 2:
            x, y = item[0], item[1]
        else:
            continue
        if _is_number(x) and _is_number(y):
            points.append((float(x), float(y)))
    return points


# ---------------------------------------------------------------------------
# Top-level compile.
# ---------------------------------------------------------------------------


def compile_board(
    board: dict,
    *,
    policy: Union[DefaultCapabilityPolicy, None] = None,
    requested_outputs: tuple[str, ...] = V1_FAB_OUTPUTS,
    library_root: Union[str, Path, None] = None,
    lockfile: Union[str, Path, None] = None,
) -> ResolutionResult:
    """Compile a canonical board dict into a :class:`ResolutionResult`.

    Returns :class:`ResolutionSuccess` (board + non-fatal diagnostics) or
    :class:`ResolutionFailure` (ERROR diagnostics, no board).  Never raises for
    an INPUT defect — only genuine programmer errors propagate.
    """
    if policy is None:
        policy = DefaultCapabilityPolicy()
    diags = _Diagnostics()

    if not isinstance(board, dict):
        diags.error("invalid_board", "board must be a mapping", _board_ref())
        return ResolutionFailure(diagnostics=diags.tuple())

    name = board.get("name")
    if not isinstance(name, str) or not name:
        diags.error("invalid_board", "board has no name", _board_ref())

    two_layer = _require_two_layer(board, diags)
    outline = _build_outline(board, diags)
    layer_stack = _build_layer_stack() if two_layer else None
    design_rules = _build_design_rules(board, diags)

    net_id_by_name, _net_index, pin_net, net_descriptors = _build_nets_index(board, diags)

    interned: dict[str, FootprintDefinition] = {}
    components: list[ResolvedComponent] = []
    pad_ids_by_net: dict[str, list[str]] = {net_id: [] for _, net_id in net_id_by_name.items()}

    for position, comp in enumerate(board.get("components") or []):
        if not isinstance(comp, dict):
            continue
        ref = str(comp.get("ref") or "")
        comp_ref = SourceRef(EntityKind.COMPONENT, ref or f"<component:{position}>")
        fp_ref = comp.get("footprint")
        if not ref:
            diags.error("invalid_component", f"component {position} has no ref", comp_ref)
            continue
        if not isinstance(fp_ref, str) or not fp_ref:
            diags.error("invalid_component", f"component {ref!r} has no footprint ref", comp_ref)
            continue
        if not (_is_number(comp.get("x_mm")) and _is_number(comp.get("y_mm"))):
            diags.error("invalid_component",
                        f"component {ref!r} has no finite x_mm/y_mm placement", comp_ref)
            continue

        try:
            parsed = resolve_footprint(fp_ref, library_root=library_root, lockfile=lockfile)
        except FootprintLookupError as exc:
            diags.error("footprint_unresolved",
                        f"component {ref!r}: {exc}", comp_ref)
            continue

        definition = FootprintDefinition.from_kicad_parsed(parsed)
        clean = _adjudicate_footprint(definition, fp_ref, policy, requested_outputs, board, diags)
        if clean is None:
            continue
        if not all(_check_pad_capabilities(pad, ref, diags) for pad in clean.pads):
            continue
        _check_coincidence(comp, clean, ref, diags)

        side = Side.BOTTOM if str(comp.get("layer") or _TOP_ID).lower() in ("bottom", "b.cu", "back") else Side.TOP
        component_id = derive_id("component", ref)
        placed_pads, placed_graphics = _place_component(
            comp, component_id, clean, side, pin_net, ref)

        interned.setdefault(clean.content_id, clean)
        from .footprint_def import Provenance
        provenance = clean.provenance or Provenance()
        components.append(ResolvedComponent(
            id=component_id,
            ref=ref,
            footprint_id=clean.content_id,
            placement=Placement(
                position=(float(comp["x_mm"]), float(comp["y_mm"])),
                rotation_deg=float(comp.get("rotation_deg") or 0.0),
                side=side,
            ),
            placed_pads=placed_pads,
            placed_graphics=placed_graphics,
            provenance=provenance,
        ))
        for pad in placed_pads:
            if pad.net_id is not None:
                pad_ids_by_net.setdefault(pad.net_id, []).append(pad.id)

    nets = _finalize_nets(net_descriptors, pad_ids_by_net, pin_net, components, diags)
    traces = _build_traces(board, net_id_by_name, diags)
    vias = _build_vias(board, net_id_by_name, diags)
    holes = _build_holes(board, diags)

    if diags.has_error or outline is None or layer_stack is None or design_rules is None:
        return ResolutionFailure(diagnostics=_ensure_error(diags))

    provenance = BoardProvenance(
        compiler_version=f"{COMPILER_VERSION}+transform/{TRANSFORM_VERSION}",
        source_digest=content_id(board)[:32],
        library_lock_ref=content_id(_safe_lock(lockfile))[:32],
        rule_profile_ref=V1_RULE_PROFILE,
    )

    try:
        resolved = ResolvedBoard(
            id=derive_id("board", name),
            name=name,
            outline=outline,
            layer_stack=layer_stack,
            design_rules=design_rules,
            footprint_definitions=tuple(interned.values()),
            nets=nets,
            components=tuple(components),
            traces=traces,
            vias=vias,
            holes=holes,
            zones=(),
            board_graphics=(),
            provenance=provenance,
        )
    except (ValueError, TypeError) as exc:
        # A construction invariant we did not pre-screen: surface it as an error
        # rather than crash, so the compiler is total over its declared input.
        diags.error("board_invariant", f"resolved board rejected: {exc}", _board_ref())
        return ResolutionFailure(diagnostics=_ensure_error(diags))

    return ResolutionSuccess(board=resolved, diagnostics=diags.tuple())


def _finalize_nets(
    descriptors: list[tuple[str, str, int, list[str]]],
    pad_ids_by_net: dict[str, list[str]],
    pin_net: dict[tuple[str, str], str],
    components: list[ResolvedComponent],
    diags: _Diagnostics,
) -> tuple[ResolvedNet, ...]:
    """Assemble ResolvedNets from placed-pad membership.

    A net whose declared pins never resolved to a placed pad (e.g. a pin ref to a
    component that failed to compile) is an ERROR — fail-closed, no silent
    empty net.
    """
    placed_pad_ids = {pad.id for comp in components for pad in comp.placed_pads}
    nets: list[ResolvedNet] = []
    for net_id, name, index, _pins in descriptors:
        pad_refs = pad_ids_by_net.get(net_id, [])
        # Deterministic order + dedup while preserving first appearance.
        seen: set[str] = set()
        ordered: list[str] = []
        for pad_id in pad_refs:
            if pad_id in placed_pad_ids and pad_id not in seen:
                seen.add(pad_id)
                ordered.append(pad_id)
        if not ordered:
            diags.error("empty_net",
                        f"net {name!r} has no resolved placed pads",
                        SourceRef(EntityKind.NET, net_id, f"net {name}"))
            continue
        nets.append(ResolvedNet(id=net_id, name=name, index=index, pad_refs=tuple(ordered)))
    return tuple(nets)


def _ensure_error(diags: _Diagnostics) -> tuple[Diagnostic, ...]:
    items = diags.tuple()
    if any(d.severity is DiagnosticSeverity.ERROR for d in items):
        return items
    # A failure with only warnings cannot construct ResolutionFailure; add a
    # synthetic error so the envelope is well-formed (defensive; should not fire).
    return items + (Diagnostic(DiagnosticSeverity.ERROR, "compile_failed",
                               "board could not be resolved", _board_ref()),)


def _safe_lock(lockfile: Union[str, Path, None]) -> dict:
    from .footprints import load_lockfile
    try:
        return load_lockfile(lockfile)
    except Exception:  # noqa: BLE001 — provenance digest is best-effort on a bad lock path
        return {}
