"""Canonical-board → :class:`ResolvedBoard` compiler (K2, hermetic-CAM keystone).

This module is the SOLE constructor of the placed-geometry projection.  It takes
a canonical board dict (``pcb/docs/board-yaml.md`` — the same shape
``resolve_board`` consumes) plus the sha-verified seed footprint library and
returns a :class:`ResolutionResult`:

* :class:`ResolutionSuccess` — a valid-by-construction :class:`ResolvedBoard`
  plus WARNING/INFO diagnostics for non-fatal feature omissions, OR
* :class:`ResolutionFailure` — one or more ERROR diagnostics and NO board.

STRICT and FAIL-CLOSED (K1 Sol reconcile, keystone comment 608; K2 review 621).
Successful compilation must NEVER silently drop or alter authored geometry: a
malformed collection, a non-mapping entity, a malformed trace point, an
unrecognized-but-present feature (zones), an unknown component side, a lost
origin — each is an ERROR, never a silent substitution or a filtered element.
There are no invented geometry defaults (no {1,1} pad, no fabricated stackup
thickness) and no design-rule value weaker than the selected manufacturer floor.

Parser feature markers (K1) are ADJUDICATED by a :class:`CapabilityPolicy`.  K2
is AUTHORITATIVE (``default_blocking`` is only the parser's conservative hint):
a marker whose domain corrupts a REQUESTED fabrication output is fatal; a
documentation/silk/fab omission becomes a WARNING and is stripped from the
interned footprint definition (the IR forbids any residual marker).  The
requested-output profile and the captured-graphic capability check are aligned
with what the K3 emitter actually produces, so the IR never advertises geometry
K3 cannot emit.

Gating: default-OFF by *non-wiring*.  Nothing in the live worker path imports
this; K3 repoints the emitters onto the IR behind an explicit flag.

Placement: the ONE transform (``geometry.PlacementTransform``, mirror included)
materializes every ``PlacedPad``/``PlacedGraphic`` ONCE; the transform-version
authority is imported from ``geometry`` and recorded on board provenance.
"""

from __future__ import annotations

from dataclasses import replace
from pathlib import Path
from typing import Union

from agent_router.layers import CANON_TO_KICAD, STACK_INDEX

from .canonical_id import content_id, derive_id
from .footprint_def import (
    ArcGraphic,
    CircleGraphic,
    FootprintDefinition,
    LineGraphic,
    PadDefinition,
    PolyGraphic,
    Provenance,
)
from .footprints import (
    FootprintLookupError,
    load_lockfile,
    resolve_footprint,
)
from .geometry import PlacementTransform, TRANSFORM_VERSION
from .resolved_board import (
    ArcGeometry,
    BoardProvenance,
    CircleGeometry,
    Diagnostic,
    DiagnosticSeverity,
    EntityKind,
    FeatureDomain,
    GraphicGeometry,
    HoleKind,
    Layer,
    LayerRole,
    LayerStack,
    LineGeometry,
    ManufacturingConstraints,
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

COMPILER_VERSION = "pcb-k2/1"

# Coincidence tolerance (mm) — a board that declares per-pin local positions must
# agree with the resolved footprint pad of the same number, else silk desyncs
# from copper.  Same threshold the legacy resolve path enforces.
COINCIDENCE_TOL_MM = 0.01

# Canonical two-layer board (the ONLY v1 stack).  Copper ids + KiCad aliases +
# stack order all come from agent_router.layers — the single worker-side
# authority — so this module cannot drift from the router/emitter mapping.
_TOP_ID, _BOTTOM_ID = "top", "bottom"

# The layers today's K3 emitter (gerber.py `_GERBER_SUFFIXES` + the PTH/NPTH
# Excellon split) actually produces.  Captured footprint geometry outside this
# set is DOCUMENTATION-ONLY and is warned, never silently promised as emittable.
K3_EMITTED_LAYERS = frozenset({
    "F.Cu", "B.Cu", "F.Mask", "B.Mask", "F.SilkS", "Edge.Cuts",
})

# The fabrication outputs v1 requests — exactly what K3 emits.  Deliberately
# excludes paste and fab: K3 produces neither, so their loss cannot corrupt a
# produced output (it is warned as captured-but-unemitted instead of failing).
V1_FAB_OUTPUTS: tuple[str, ...] = ("copper", "drill", "mask", "silk", "edge")

# Domains whose loss corrupts real copper/hole fabrication when requested.
_FAB_DOMAINS = frozenset({
    FeatureDomain.COPPER, FeatureDomain.DRILL,
    FeatureDomain.MASK, FeatureDomain.PASTE,
})

# Technical (non-copper) layers the IR advertises for v1 boards.
_TECHNICAL_LAYER_IDS = (
    "F.SilkS", "B.SilkS", "F.Mask", "B.Mask",
    "F.Paste", "B.Paste", "F.Fab", "B.Fab",
    "F.CrtYd", "B.CrtYd", "Edge.Cuts",
)

# Conservative manufacturing floor (a VERSIONED, digest-pinned rule source — the
# only sanctioned origin for a design-rule minimum, keystone comment 608
# fail-closed sweep).  The board's authored clearance may only TIGHTEN
# min_clearance above this floor, never weaken it (K2 review 621 MF5).
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
    return RuleProfileRef(id="v1-fab-conservative", version="1", digest=digest)


V1_RULE_PROFILE = _v1_rule_profile()


class DefaultCapabilityPolicy:
    """v1 fatality policy (implements the :class:`CapabilityPolicy` protocol).

    K2 is authoritative: fatality is decided by the marker's fabrication DOMAIN
    against the requested outputs, NOT by the parser's ``default_blocking`` hint.
    A copper/drill/mask/paste marker is fatal when that output is requested; a
    documentation/silk/fab omission is non-fatal (warned).  ``zone_connect`` is
    context-sensitive — inert unless the board actually declares zones.
    """

    def is_blocking(
        self,
        marker: UnsupportedFeature,
        board_context: object,
        requested_outputs: tuple[str, ...],
    ) -> bool:
        if marker.feature == "zone_connect":
            return bool(isinstance(board_context, dict) and board_context.get("zones"))
        if marker.domain in _FAB_DOMAINS:
            return marker.domain.value in requested_outputs
        return False


class _Diagnostics:
    """Accumulator that tracks whether any ERROR was recorded."""

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

    def info(self, code: str, message: str, ref: SourceRef) -> None:
        self.add(DiagnosticSeverity.INFO, code, message, ref)

    def tuple(self) -> tuple[Diagnostic, ...]:
        return tuple(self._items)


def _board_ref(entity_id: str = "<board>", detail: Union[str, None] = None) -> SourceRef:
    return SourceRef(EntityKind.BOARD, entity_id, detail)


# ---------------------------------------------------------------------------
# Small numeric helpers.
# ---------------------------------------------------------------------------


def _is_number(value) -> bool:
    import math
    return (not isinstance(value, bool) and isinstance(value, (int, float))
            and math.isfinite(value))


def _is_positive_number(value) -> bool:
    return _is_number(value) and value > 0


def _dict_items(board: dict, key: str, entity_code: str, diags: _Diagnostics) -> list[dict]:
    """Return the list at ``board[key]``, ERRORing (not skipping) on a non-list
    container or any non-mapping element.  Fail-closed: a malformed member never
    vanishes into a smaller-but-valid board."""
    raw = board.get(key)
    if raw is None:
        return []
    if not isinstance(raw, list):
        diags.error(f"invalid_{entity_code}", f"board.{key} must be a list, got {type(raw).__name__}",
                    _board_ref())
        return []
    out: list[dict] = []
    for index, item in enumerate(raw):
        if not isinstance(item, dict):
            diags.error(f"invalid_{entity_code}",
                        f"board.{key}[{index}] is not a mapping ({item!r})", _board_ref())
            continue
        out.append(item)
    return out


# ---------------------------------------------------------------------------
# Board frame: origin/outline, layer stack, design rules.
# ---------------------------------------------------------------------------


def _require_two_layer(board: dict, diags: _Diagnostics) -> bool:
    layers = board.get("layers")
    if layers is None:
        return True  # absence == the canonical two-layer default
    if not isinstance(layers, list) or [str(x) for x in layers] != [_TOP_ID, _BOTTOM_ID]:
        diags.error("unsupported_layer_stack",
                    f"v1 compiles exactly two copper layers [top, bottom]; got {layers!r}",
                    _board_ref())
        return False
    return True


def _build_outline(board: dict, diags: _Diagnostics) -> Union[RectOutline, None]:
    width, height = board.get("width_mm"), board.get("height_mm")
    if not _is_positive_number(width) or not _is_positive_number(height):
        diags.error("unsupported_outline",
                    f"v1 requires a rectangular outline with positive width_mm/height_mm; "
                    f"got width_mm={width!r} height_mm={height!r}", _board_ref())
        return None
    # Honor the first-class board origin (board-yaml.md) rather than resetting it.
    origin = (0.0, 0.0)
    raw_origin = board.get("origin")
    if raw_origin is not None:
        if (not isinstance(raw_origin, dict)
                or not _is_number(raw_origin.get("x_mm"))
                or not _is_number(raw_origin.get("y_mm"))):
            diags.error("unsupported_outline",
                        f"board.origin must be {{x_mm, y_mm}} with finite values; got {raw_origin!r}",
                        _board_ref())
            return None
        origin = (float(raw_origin["x_mm"]), float(raw_origin["y_mm"]))
    return RectOutline(origin=origin, width_mm=float(width), height_mm=float(height))


def _build_layer_stack() -> LayerStack:
    ordered = sorted(STACK_INDEX.items(), key=lambda kv: kv[1])
    copper = tuple(
        ResolvedLayer(id=canon, kicad_alias=CANON_TO_KICAD[canon], stack_index=index)
        for canon, index in ordered
    )
    # Physical stack: DECLARE the layer order but assert NO thickness/material the
    # source did not supply (K2 review 621 MF5; tagged-union seam allows None).
    entries: list[StackupEntry] = []
    order = 0
    for position, (canon, _index) in enumerate(ordered):
        entries.append(StackupEntry(id=CANON_TO_KICAD[canon], order=order,
                                    kind=StackupKind.COPPER, copper_layer_id=canon))
        order += 1
        if position < len(ordered) - 1:
            entries.append(StackupEntry(id=f"dielectric-{position}", order=order,
                                        kind=StackupKind.DIELECTRIC))
            order += 1
    technical = tuple(Layer.from_id(layer_id) for layer_id in _TECHNICAL_LAYER_IDS)
    return LayerStack(copper=copper, stackup=PhysicalStackup(entries=tuple(entries)),
                      technical=technical)


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
    bad = False
    for name, value in (("trace_width_mm", trace_width), ("via_diameter_mm", via_diameter),
                        ("via_drill_mm", via_drill), ("clearance_mm", clearance)):
        if not _is_positive_number(value):
            diags.error("invalid_design_rule",
                        f"design_rules.{name} must be a positive number; got {value!r}", _board_ref())
            bad = True
    if bad:
        return None
    if float(via_drill) >= float(via_diameter):
        diags.error("invalid_design_rule",
                    f"via_drill_mm ({via_drill}) must be smaller than via_diameter_mm ({via_diameter})",
                    _board_ref())
        return None
    return ResolvedDesignRules(
        defaults=RoutingDefaults(
            trace_width_mm=float(trace_width),
            via_diameter_mm=float(via_diameter),
            via_drill_mm=float(via_drill),
        ),
        minimums=_floor_with_clearance(float(clearance)),
        allowed_via_kinds=(ViaKind.THROUGH,),
        net_classes=(),
        rule_profile=V1_RULE_PROFILE,
    )


def _floor_with_clearance(board_clearance_mm: float) -> ManufacturingConstraints:
    """v1 manufacturing floor; the board's authored clearance may only TIGHTEN
    min_clearance above the profile floor, never weaken it (K2 review 621 MF5)."""
    floor = dict(_V1_MANUFACTURING_FLOOR)
    floor["min_clearance_mm"] = max(_V1_MANUFACTURING_FLOOR["min_clearance_mm"], board_clearance_mm)
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
    """Adjudicate every parser marker on *definition*; return a marker-free clone
    that RETAINS its source provenance (so the pre-adjudication identity stays
    recoverable — K2 review 621 MF4).  Blocking markers become ERRORs (and the
    footprint yields ``None``); non-blocking markers become WARNINGs and are
    stripped so the definition satisfies the IR no-residual-marker invariant."""
    blocked = False

    def judge(markers) -> None:
        nonlocal blocked
        for marker in markers:
            if policy.is_blocking(marker, board, requested_outputs):
                diags.error("unsupported_feature",
                            f"footprint {ref!r}: {marker.feature} on {marker.domain.value} "
                            f"({marker.detail}) corrupts a requested fabrication output",
                            marker.source_ref)
                blocked = True
            else:
                diags.warning("feature_omitted",
                              f"footprint {ref!r}: {marker.feature} on {marker.domain.value} "
                              f"({marker.detail}) is not fabricated in v1", marker.source_ref)

    judge(definition.unsupported)
    for pad in definition.pads:
        judge(pad.unsupported)

    if blocked:
        return None
    stripped_pads = tuple(replace(pad, unsupported=()) for pad in definition.pads)
    return replace(definition, pads=stripped_pads, unsupported=())


def _check_pad_capabilities(pad: PadDefinition, ref: str, diags: _Diagnostics) -> bool:
    """Fail-closed guards for the bounded v1 pad subset. True == acceptable.
    Records ALL failing conditions (does not short-circuit) for debuggability."""
    ok = True
    pad_ref = SourceRef(EntityKind.PAD, pad.source_id, f"component {ref}")
    if not pad.shape.is_supported:
        diags.error("unsupported_pad_shape",
                    f"component {ref!r} pad {pad.number!r}: shape {pad.shape.value} "
                    f"is outside the v1 rect/roundrect/circle/oval subset", pad_ref)
        ok = False
    has_copper = any(layer.role is LayerRole.COPPER for layer in pad.layers)
    if has_copper and pad.size is None:
        diags.error("missing_pad_size",
                    f"component {ref!r} pad {pad.number!r}: copper pad has no declared size; "
                    f"v1 refuses to invent one", pad_ref)
        ok = False
    if pad.drill is not None and pad.drill.shape not in ("round", "circle"):
        diags.error("unsupported_hole",
                    f"component {ref!r} pad {pad.number!r}: {pad.drill.shape} drill is outside "
                    f"the v1 round-hole subset", pad_ref)
        ok = False
    return ok


def _resolved_pad_layers(pad: PadDefinition, side: Side, ref: str,
                         diags: _Diagnostics) -> Union[tuple[Layer, ...], None]:
    """Expand a footprint pad's copper/mask/paste participation to EXPLICIT
    resolved layers by pad type + side (K2 review 621 MF2), matching what K3
    emits.  No ``*.Cu``/``*.Mask`` wildcard may survive into a PlacedPad."""
    top = side is Side.TOP
    if pad.pad_type == "thru_hole":
        # Plated TH: copper annulus + mask opening on BOTH sides.
        return (Layer.from_id("F.Cu"), Layer.from_id("B.Cu"),
                Layer.from_id("F.Mask"), Layer.from_id("B.Mask"))
    if pad.pad_type == "np_thru_hole":
        return ()  # non-plated mechanical hole — no copper/mask participation
    if pad.pad_type == "smd":
        if top:
            return (Layer.from_id("F.Cu"), Layer.from_id("F.Mask"), Layer.from_id("F.Paste"))
        return (Layer.from_id("B.Cu"), Layer.from_id("B.Mask"), Layer.from_id("B.Paste"))
    diags.error("unresolved_pad_layers",
                f"component {ref!r} pad {pad.number!r}: pad type {pad.pad_type!r} has no "
                f"resolved layer participation in v1",
                SourceRef(EntityKind.PAD, pad.source_id, f"component {ref}"))
    return None


# ---------------------------------------------------------------------------
# Placed-geometry projection.
# ---------------------------------------------------------------------------


def _to_geometry(graphic) -> GraphicGeometry:
    """Map a footprint-local GraphicDefinition variant to a local GraphicGeometry."""
    if isinstance(graphic, LineGraphic):
        return LineGeometry(graphic.a, graphic.b)
    if isinstance(graphic, CircleGraphic):
        return CircleGeometry(graphic.center, graphic.radius_mm)
    if isinstance(graphic, ArcGraphic):
        return ArcGeometry(graphic.start, graphic.mid, graphic.end)
    if isinstance(graphic, PolyGraphic):
        return PolygonGeometry(graphic.points)
    raise TypeError(f"unknown GraphicDefinition variant {type(graphic)!r}")


def _place_component(
    comp: dict,
    component_id: str,
    definition: FootprintDefinition,
    side: Side,
    pin_net: dict[tuple[str, str], str],
    ref: str,
    diags: _Diagnostics,
) -> Union[tuple[tuple[PlacedPad, ...], tuple[PlacedGraphic, ...]], None]:
    transform = PlacementTransform(
        position=(float(comp["x_mm"]), float(comp["y_mm"])),
        rotation_deg=float(comp.get("rotation_deg") or 0.0),
        side=side,
    )
    placed_pads: list[PlacedPad] = []
    for pad in definition.pads:
        layers = _resolved_pad_layers(pad, side, ref, diags)
        if layers is None:
            return None
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
            layers=layers,
            side=side,
        ))
    placed_graphics: list[PlacedGraphic] = []
    unemitted: set[str] = set()
    for graphic in definition.graphics:
        placed_layer = transform.layer(graphic.layer)
        if placed_layer.id not in K3_EMITTED_LAYERS:
            unemitted.add(placed_layer.id)
        placed_graphics.append(PlacedGraphic(
            id=derive_id("placed-graphic", component_id, graphic.source_id),
            component_id=component_id,
            source_id=graphic.source_id,
            layer=placed_layer,
            geometry=transform.graphic(_to_geometry(graphic)),
            width_mm=graphic.width_mm,
        ))
    if unemitted:
        diags.warning("captured_graphic_not_emitted",
                      f"component {ref!r}: captured graphics on {sorted(unemitted)} are "
                      f"documentation-only — outside the K3 emitter capability",
                      SourceRef(EntityKind.COMPONENT, ref))
    return tuple(placed_pads), tuple(placed_graphics)


def _check_coincidence(comp: dict, definition: FootprintDefinition, ref: str,
                       diags: _Diagnostics) -> None:
    """If the board declares per-pin local positions, prove they match the
    footprint pads of the same number (fail-closed — silk/copper desync)."""
    pins = comp.get("pins")
    if pins is None:
        return
    if not isinstance(pins, list):
        diags.error("invalid_component",
                    f"component {ref!r}: pins must be a list", SourceRef(EntityKind.COMPONENT, ref))
        return
    pad_by_number: dict[str, PadDefinition] = {}
    for pad in definition.pads:
        pad_by_number.setdefault(pad.number, pad)
    for index, pin in enumerate(pins):
        if not isinstance(pin, dict):
            diags.error("invalid_component",
                        f"component {ref!r}: pins[{index}] is not a mapping",
                        SourceRef(EntityKind.COMPONENT, ref))
            continue
        number = str(pin.get("number"))
        px, py = pin.get("x_mm"), pin.get("y_mm")
        if not _is_number(px) or not _is_number(py):
            continue  # a pin with no local position cannot be coincidence-checked
        pad = pad_by_number.get(number)
        pad_ref = SourceRef(EntityKind.PAD, f"{ref}.{number}", f"component {ref}")
        if pad is None:
            diags.error("pin_without_pad",
                        f"component {ref!r} pin {number!r} has no matching footprint pad", pad_ref)
            continue
        dx, dy = pad.position[0] - float(px), pad.position[1] - float(py)
        if (dx * dx + dy * dy) ** 0.5 > COINCIDENCE_TOL_MM:
            diags.error("pin_pad_desync",
                        f"component {ref!r} pin {number!r}: declared local ({px}, {py}) vs "
                        f"footprint pad {pad.position} exceeds {COINCIDENCE_TOL_MM}mm", pad_ref)


# ---------------------------------------------------------------------------
# Nets, traces, vias, holes.
# ---------------------------------------------------------------------------


def _split_pin_ref(token) -> Union[tuple[str, str], None]:
    if not isinstance(token, str) or "." not in token:
        return None
    ref, number = token.rsplit(".", 1)
    if not ref or not number:
        return None
    return ref, number


def _build_nets_index(board: dict, diags: _Diagnostics):
    """Return (name→net_id, name→index, (ref,num)→net_id, ordered descriptors).

    Net ids are NAME-derived and the index is assigned in NAME-sorted order
    (KiCad reserves 0), so a semantically-harmless reorder of the board's net
    list does not renumber the board (keystone comment 608, Q3)."""
    raw_nets = _dict_items(board, "nets", "net", diags)
    name_to_id: dict[str, str] = {}
    name_to_index: dict[str, int] = {}
    pin_net: dict[tuple[str, str], str] = {}
    descriptors: list[tuple[str, str, int]] = []
    names: list[str] = []
    for net in raw_nets:
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
        name = net.get("name")
        if not isinstance(name, str) or name not in name_to_id:
            continue
        pins = net.get("pins")
        if pins is not None and not isinstance(pins, list):
            diags.error("invalid_net", f"net {name!r}: pins must be a list", _board_ref())
            continue
        for token in pins or []:
            parsed = _split_pin_ref(token)
            if parsed is None:
                diags.error("invalid_pin_ref",
                            f"net {name!r}: pin ref {token!r} is not 'REF.NUMBER'", _board_ref())
                continue
            pin_net[parsed] = name_to_id[name]
        descriptors.append((name_to_id[name], name, name_to_index[name]))
    return name_to_id, name_to_index, pin_net, descriptors


def _extract_points(raw_points, ordinal: int, ref: SourceRef,
                    diags: _Diagnostics) -> Union[list[tuple[float, float]], None]:
    """Strict point extraction: any malformed point FAILS the trace (never
    filtered-then-stitched — K2 review 621 MF1)."""
    if not isinstance(raw_points, list):
        diags.error("trace_bad_points", f"trace {ordinal}: points must be a list", ref)
        return None
    points: list[tuple[float, float]] = []
    for index, item in enumerate(raw_points):
        if isinstance(item, dict):
            x, y = item.get("x_mm"), item.get("y_mm")
        elif isinstance(item, (list, tuple)) and len(item) >= 2:
            x, y = item[0], item[1]
        else:
            diags.error("trace_bad_points", f"trace {ordinal}: point[{index}] is malformed ({item!r})", ref)
            return None
        if not (_is_number(x) and _is_number(y)):
            diags.error("trace_bad_points",
                        f"trace {ordinal}: point[{index}] has non-finite coordinates", ref)
            return None
        points.append((float(x), float(y)))
    return points


def _build_traces(board: dict, net_id_by_name: dict[str, str],
                  diags: _Diagnostics) -> tuple[ResolvedTrace, ...]:
    traces: list[ResolvedTrace] = []
    for ordinal, raw in enumerate(_dict_items(board, "traces", "trace", diags)):
        net_name = raw.get("net")
        net_id = net_id_by_name.get(net_name) if isinstance(net_name, str) else None
        trace_ref = SourceRef(EntityKind.TRACE, f"trace:{ordinal}", f"net {net_name}")
        if net_id is None:
            diags.error("trace_unknown_net", f"trace {ordinal}: references unknown net {net_name!r}", trace_ref)
            continue
        layer_id = str(raw.get("layer") or "")
        layer = Layer.from_id(layer_id) if layer_id else None
        if layer is None or layer.id not in CANON_TO_KICAD:
            diags.error("trace_bad_layer", f"trace {ordinal}: layer {layer_id!r} is not a v1 copper layer", trace_ref)
            continue
        width = raw.get("width_mm")
        if not _is_positive_number(width):
            diags.error("trace_bad_width", f"trace {ordinal}: width_mm {width!r} is not positive", trace_ref)
            continue
        points = _extract_points(raw.get("points"), ordinal, trace_ref, diags)
        if points is None:
            continue
        if len(points) < 2:
            diags.error("trace_degenerate", f"trace {ordinal}: needs at least two points, got {len(points)}", trace_ref)
            continue
        trace_id = _authored_or_ordinal_id("trace", raw, net_id, ordinal)
        segments: list[ResolvedTraceSegment] = []
        degenerate = False
        for seg_ordinal, (a, b) in enumerate(zip(points, points[1:])):
            if a == b:
                diags.error("trace_degenerate", f"trace {ordinal}: zero-length segment at {a}", trace_ref)
                degenerate = True
                break
            segments.append(ResolvedTraceSegment(
                id=derive_id("segment", trace_id, str(seg_ordinal)),
                a=a, b=b, width_mm=float(width), layer=layer,
            ))
        if degenerate or not segments:
            continue
        traces.append(ResolvedTrace(id=trace_id, net_id=net_id, segments=tuple(segments)))
    return tuple(traces)


def _build_vias(board: dict, net_id_by_name: dict[str, str],
                diags: _Diagnostics) -> tuple[ResolvedVia, ...]:
    vias: list[ResolvedVia] = []
    for ordinal, raw in enumerate(_dict_items(board, "vias", "via", diags)):
        net_name = raw.get("net")
        net_id = net_id_by_name.get(net_name) if isinstance(net_name, str) else None
        via_ref = SourceRef(EntityKind.VIA, f"via:{ordinal}", f"net {net_name}")
        if net_id is None:
            diags.error("via_unknown_net", f"via {ordinal}: references unknown net {net_name!r}", via_ref)
            continue
        x, y = raw.get("x_mm"), raw.get("y_mm")
        diameter, drill = raw.get("diameter_mm"), raw.get("drill_mm")
        from_layer, to_layer = str(raw.get("from_layer") or ""), str(raw.get("to_layer") or "")
        if not (_is_number(x) and _is_number(y)):
            diags.error("via_bad_position", f"via {ordinal}: non-finite position", via_ref)
            continue
        if not (_is_positive_number(diameter) and _is_positive_number(drill)):
            diags.error("via_bad_size",
                        f"via {ordinal}: diameter_mm/drill_mm must be positive (got {diameter!r}/{drill!r})", via_ref)
            continue
        if float(drill) >= float(diameter):
            diags.error("via_bad_size", f"via {ordinal}: drill {drill} must be smaller than diameter {diameter}", via_ref)
            continue
        if from_layer not in CANON_TO_KICAD or to_layer not in CANON_TO_KICAD or from_layer == to_layer:
            diags.error("via_bad_span",
                        f"via {ordinal}: span {from_layer!r}->{to_layer!r} is not a legal v1 "
                        f"through-via across [top, bottom]", via_ref)
            continue
        vias.append(ResolvedVia(
            id=_authored_or_ordinal_id("via", raw, net_id, ordinal),
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
    holes: list[ResolvedHole] = []
    # The canonical worker accepts mounting_holes plus the npth_holes/pth_holes
    # aliases producers use when they pre-split plating (board-yaml.md).
    for key, default_plated in (("mounting_holes", False), ("npth_holes", False), ("pth_holes", True)):
        for ordinal, raw in enumerate(_dict_items(board, key, "hole", diags)):
            x, y = raw.get("x_mm"), raw.get("y_mm")
            diameter = raw.get("diameter_mm")
            if diameter is None:
                diameter = raw.get("drill_mm")
            hole_ref = SourceRef(EntityKind.HOLE, f"{key}:{ordinal}")
            if not (_is_number(x) and _is_number(y) and _is_positive_number(diameter)):
                diags.error("hole_bad_geometry",
                            f"{key}[{ordinal}]: needs finite x/y and a positive diameter", hole_ref)
                continue
            plated = bool(raw.get("plated", default_plated))
            holes.append(ResolvedHole(
                id=_authored_or_ordinal_id("hole", raw, key, ordinal),
                feature=RoundHole(position=(float(x), float(y)), diameter_mm=float(diameter)),
                plated=plated,
                kind=HoleKind.PTH if plated else HoleKind.NPTH,
            ))
    return tuple(holes)


def _authored_or_ordinal_id(entity: str, raw: dict, *ordinal_parts) -> str:
    """Honor an authored ``id`` when present; otherwise mint a deterministic
    ORDINAL-derived id.  Ordinal ids are stable for a compile-from-scratch but
    NOT under reorder/insert — the compile emits an INFO diagnostic recording
    this so the mint-and-persist handoff (YAML v2) is visible (review 621 MF4)."""
    authored = raw.get("id")
    if isinstance(authored, str) and authored:
        return derive_id(entity, "authored", authored)
    return derive_id(entity, *(str(part) for part in ordinal_parts))


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
    an INPUT defect — only genuine programmer errors propagate."""
    if policy is None:
        policy = DefaultCapabilityPolicy()
    diags = _Diagnostics()

    if not isinstance(board, dict):
        diags.error("invalid_board", "board must be a mapping", _board_ref())
        return ResolutionFailure(diagnostics=diags.tuple())

    # Load the sha-verified lock ONCE; an unreadable/malformed lock is fatal —
    # provenance and footprint resolution both depend on it (review 621 MF4).
    try:
        lock = load_lockfile(lockfile)
        if not isinstance(lock, dict):
            raise ValueError("lockfile is not a mapping")
    except Exception as exc:  # noqa: BLE001 — surfaced as a structured error, not a crash
        diags.error("lock_unreadable", f"footprint lock could not be loaded: {exc}", _board_ref())
        return ResolutionFailure(diagnostics=diags.tuple())

    name = board.get("name")
    if not isinstance(name, str) or not name:
        diags.error("invalid_board", "board has no name", _board_ref())

    # Reject recognized-but-unsupported board geometry rather than silently
    # dropping it (review 621 MF1).
    for unsupported_key in ("zones", "board_graphics", "keepouts"):
        if board.get(unsupported_key):
            diags.error("unsupported_board_feature",
                        f"board declares {unsupported_key!r}, which v1 cannot fabricate",
                        _board_ref())

    two_layer = _require_two_layer(board, diags)
    outline = _build_outline(board, diags)
    layer_stack = _build_layer_stack() if two_layer else None
    design_rules = _build_design_rules(board, diags)

    net_id_by_name, _net_index, pin_net, net_descriptors = _build_nets_index(board, diags)

    interned: dict[str, FootprintDefinition] = {}
    components: list[ResolvedComponent] = []
    pad_ids_by_net: dict[str, list[str]] = {}

    for position, comp in enumerate(_dict_items(board, "components", "component", diags)):
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
            diags.error("invalid_component", f"component {ref!r} has no finite x_mm/y_mm placement", comp_ref)
            continue
        side = _resolve_side(comp.get("layer"), ref, comp_ref, diags)
        if side is None:
            continue

        try:
            parsed = resolve_footprint(fp_ref, library_root=library_root, lockfile=lockfile)
        except FootprintLookupError as exc:
            diags.error("footprint_unresolved", f"component {ref!r}: {exc}", comp_ref)
            continue

        entry = lock.get(fp_ref) or {}
        provenance = Provenance(
            source_id=fp_ref,
            sha256=entry.get("sha256"),
            license=entry.get("license"),
        )
        definition = FootprintDefinition.from_kicad_parsed(parsed, provenance=provenance)
        clean = _adjudicate_footprint(definition, fp_ref, policy, requested_outputs, board, diags)
        if clean is None:
            continue
        if not all([_check_pad_capabilities(pad, ref, diags) for pad in clean.pads]):
            continue
        _check_coincidence(comp, clean, ref, diags)

        component_id = derive_id("component", ref)
        placed = _place_component(comp, component_id, clean, side, pin_net, ref, diags)
        if placed is None:
            continue
        placed_pads, placed_graphics = placed

        interned.setdefault(clean.content_id, clean)
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
            value=str(comp.get("value") or ""),
        ))
        for pad in placed_pads:
            if pad.net_id is not None:
                pad_ids_by_net.setdefault(pad.net_id, []).append(pad.id)

    nets = _finalize_nets(net_descriptors, pad_ids_by_net, components, diags)
    traces = _build_traces(board, net_id_by_name, diags)
    vias = _build_vias(board, net_id_by_name, diags)
    holes = _build_holes(board, diags)

    if traces or vias or holes:
        diags.info("ordinal_ids",
                   "trace/via/hole ids are ordinal-derived and NOT stable under reorder/insert; "
                   "persisted authored identity is a YAML-v2 handoff",
                   _board_ref())

    if diags.has_error or outline is None or layer_stack is None or design_rules is None:
        return ResolutionFailure(diagnostics=_ensure_error(diags))

    provenance = BoardProvenance(
        compiler_version=f"{COMPILER_VERSION}+transform/{TRANSFORM_VERSION}",
        source_digest=content_id(board),
        library_lock_ref=content_id(lock),
        rule_profile_ref=V1_RULE_PROFILE,
    )

    try:
        resolved = ResolvedBoard(
            id=derive_id("board", name, str(board.get("version") or 1)),
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
        diags.error("board_invariant", f"resolved board rejected: {exc}", _board_ref())
        return ResolutionFailure(diagnostics=_ensure_error(diags))

    return ResolutionSuccess(board=resolved, diagnostics=diags.tuple())


def _resolve_side(raw_layer, ref: str, comp_ref: SourceRef,
                  diags: _Diagnostics) -> Union[Side, None]:
    """Map a component's authored side to Side, fail-closed on anything unknown
    (never default an unrecognized value to TOP — review 621 MF1)."""
    if raw_layer is None:
        return Side.TOP
    token = str(raw_layer).strip().lower()
    if token in ("top", "f.cu", "front"):
        return Side.TOP
    if token in ("bottom", "b.cu", "back"):
        return Side.BOTTOM
    diags.error("invalid_component",
                f"component {ref!r}: unknown layer/side {raw_layer!r}", comp_ref)
    return None


def _finalize_nets(descriptors, pad_ids_by_net, components, diags: _Diagnostics) -> tuple[ResolvedNet, ...]:
    """Assemble ResolvedNets from placed-pad membership.  A net whose declared
    pins never resolved to a placed pad is an ERROR — fail-closed, no silent
    empty net."""
    placed_pad_ids = {pad.id for comp in components for pad in comp.placed_pads}
    nets: list[ResolvedNet] = []
    for net_id, name, index in descriptors:
        seen: set[str] = set()
        ordered: list[str] = []
        for pad_id in pad_ids_by_net.get(net_id, []):
            if pad_id in placed_pad_ids and pad_id not in seen:
                seen.add(pad_id)
                ordered.append(pad_id)
        if not ordered:
            diags.error("empty_net", f"net {name!r} has no resolved placed pads",
                        SourceRef(EntityKind.NET, net_id, f"net {name}"))
            continue
        nets.append(ResolvedNet(id=net_id, name=name, index=index, pad_refs=tuple(ordered)))
    return tuple(nets)


def _ensure_error(diags: _Diagnostics) -> tuple[Diagnostic, ...]:
    items = diags.tuple()
    if any(d.severity is DiagnosticSeverity.ERROR for d in items):
        return items
    return items + (Diagnostic(DiagnosticSeverity.ERROR, "compile_failed",
                               "board could not be resolved", _board_ref()),)
