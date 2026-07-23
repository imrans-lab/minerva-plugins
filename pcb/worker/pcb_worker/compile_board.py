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

import copy
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Union

from agent_router.layers import CANON_TO_KICAD, STACK_INDEX

from .canonical_id import CanonicalizationError, content_id, derive_id
from .fab_capability import (
    EMITTED_LAYERS,
    FABRICATION_CRITICAL_OUTPUTS,
    SUPPORTED_HOLE_SHAPES,
    SUPPORTED_PAD_SHAPES,
)
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

# Emitter capability + the fatal-output profile come from the ONE neutral
# authority (fab_capability), imported by K2 AND every emitter, so they cannot
# drift independently (K2 review 623, decision a).  Captured footprint geometry
# on a layer outside EMITTED_LAYERS is DOCUMENTATION-ONLY and warned.
K3_EMITTED_LAYERS = EMITTED_LAYERS

# Fabrication-critical outputs a captured-feature loss may corrupt.  Cosmetic
# (silk/fab) and unemitted (paste) losses are warned, never fatal.
V1_FAB_OUTPUTS: tuple[str, ...] = FABRICATION_CRITICAL_OUTPUTS

# Domains eligible to be FATAL when their output is requested (review 623 R5:
# RULES included so a dropped design-rule marker can block, since the IR feeds
# DRC/routing).  A marker outside these domains is always non-fatal (warned).
_FATAL_DOMAINS = frozenset({
    FeatureDomain.COPPER, FeatureDomain.DRILL, FeatureDomain.MASK,
    FeatureDomain.PASTE, FeatureDomain.RULES,
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
            # Inert unless the board actually declares zones for it to affect.
            return bool(isinstance(board_context, dict) and board_context.get("zones"))
        if marker.domain not in _FATAL_DOMAINS:
            return False
        # Fatal when the marker's own domain OR any of its explicitly-attributed
        # affected outputs is one the caller requested (review 623 R5).
        if marker.domain.value in requested_outputs:
            return True
        return any(output in requested_outputs for output in marker.affected_outputs)


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


def _build_design_rules(board: dict, requested_outputs: tuple[str, ...],
                        diags: _Diagnostics) -> Union[ResolvedDesignRules, None]:
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
    # The canonical schema declares diff-pair rules the v1 IR does not model.
    # Route the loss through the SAME output policy as any other rule loss
    # (review 625.4): fatal when 'rules' is a requested output (the IR feeds
    # DRC/routing), a warning when compiling CAM-only without rules.
    if any(rules.get(k) is not None for k in ("diff_pair_gap_mm", "diff_pair_width_mm")):
        if "rules" in requested_outputs:
            diags.error("unsupported_design_rule",
                        "diff_pair_gap_mm/diff_pair_width_mm are declared but not modeled in the "
                        "v1 IR; dropping them is fatal because 'rules' was requested (DRC/routing)",
                        _board_ref())
            return None
        diags.warning("unsupported_design_rule",
                      "diff_pair_gap_mm/diff_pair_width_mm are declared but not modeled in the "
                      "v1 IR; ignored for this CAM-only ('rules' not requested) compile", _board_ref())
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
    Records ALL failing conditions (does not short-circuit) for debuggability.
    Enforces pad-type/layer/drill LEGALITY so a contradictory definition (an SMD
    pad with no copper, a through-hole pad with no drill, an SMD pad carrying a
    drill) never compiles into an internally inconsistent PlacedPad (review 625.2)."""
    ok = True
    pad_ref = SourceRef(EntityKind.PAD, pad.source_id, f"component {ref}")

    def fail(code: str, detail: str) -> None:
        nonlocal ok
        diags.error(code, f"component {ref!r} pad {pad.number!r}: {detail}", pad_ref)
        ok = False

    if pad.shape.value not in SUPPORTED_PAD_SHAPES:
        fail("unsupported_pad_shape",
             f"shape {pad.shape.value} is outside the supported {sorted(SUPPORTED_PAD_SHAPES)} subset")
    if pad.drill is not None and pad.drill.shape not in SUPPORTED_HOLE_SHAPES:
        fail("unsupported_hole", f"{pad.drill.shape} drill is outside the v1 round-hole subset")

    has_copper = any(layer.role is LayerRole.COPPER for layer in pad.layers)
    if has_copper and pad.size is None:
        fail("missing_pad_size", "copper pad has no declared size; v1 refuses to invent one")

    # Pad-type legality: the three seed pad types have distinct, non-overlapping
    # geometry contracts.  A definition that violates its own type is malformed.
    if pad.pad_type == "smd":
        if not has_copper:
            fail("illegal_pad_definition", "SMD pad declares no copper layer")
        if pad.drill is not None:
            fail("illegal_pad_definition", "SMD pad must not carry a drill")
    elif pad.pad_type in ("thru_hole", "np_thru_hole"):
        if pad.drill is None:
            fail("illegal_pad_definition", f"{pad.pad_type} pad has no drill")
    return ok


_WILDCARD_EXPANSION = {
    "*.Cu": ("F.Cu", "B.Cu"),
    "*.Mask": ("F.Mask", "B.Mask"),
    "*.Paste": ("F.Paste", "B.Paste"),
}


def _resolved_pad_layers(pad: PadDefinition, transform: PlacementTransform, ref: str,
                         diags: _Diagnostics) -> Union[tuple[Layer, ...], None]:
    """Expand the footprint pad's DECLARED layer selectors to explicit resolved
    layers — wildcards to both sides, explicit F.*/B.* mirrored by placement
    side — carrying exactly the participation the library declared (K2 review
    623 R1).  Nothing is synthesized: a pad that declares no layers resolves to
    none, and an unexpandable selector is a fail-closed error.  No ``*.Cu`` /
    ``*.Mask`` wildcard survives into a PlacedPad."""
    resolved: list[Layer] = []
    seen: set[str] = set()

    def add(layer: Layer) -> None:
        if layer.id not in seen:
            seen.add(layer.id)
            resolved.append(layer)

    for layer in pad.layers:
        if layer.is_wildcard:
            expansion = _WILDCARD_EXPANSION.get(layer.id)
            if expansion is None:
                diags.error("unresolved_pad_layers",
                            f"component {ref!r} pad {pad.number!r}: cannot expand layer "
                            f"selector {layer.id!r}",
                            SourceRef(EntityKind.PAD, pad.source_id, f"component {ref}"))
                return None
            for layer_id in expansion:
                add(Layer.from_id(layer_id))
        else:
            add(transform.layer(layer))  # mirror an explicit F/B layer by side
    return tuple(resolved)


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
    overrides: dict[str, dict],
    ref: str,
    diags: _Diagnostics,
) -> Union[tuple[tuple[PlacedPad, ...], tuple[PlacedGraphic, ...]], None]:
    transform = PlacementTransform(
        position=(float(comp["x_mm"]), float(comp["y_mm"])),
        rotation_deg=float(comp.get("rotation_deg") or 0.0),
        side=side,
    )
    unemitted: set[str] = set()
    placed_pads: list[PlacedPad] = []
    for pad in definition.pads:
        layers = _resolved_pad_layers(pad, transform, ref, diags)
        if layers is None:
            return None
        unemitted.update(layer.id for layer in layers if layer.id not in K3_EMITTED_LAYERS)
        net_id = pin_net.get((ref, pad.number))
        # Footprint values are the default; a validated per-pin `override`
        # (correlated by pad/pin number) wins ONLY on the fields it carries. A
        # footprint carrying duplicate pad numbers applies the same override to
        # each (validation correlated only the first) — acceptable: same pad
        # number == same electrical pad (Fable SB1 note 3).
        size = (float(pad.size[0]), float(pad.size[1])) if pad.size is not None else None
        drill = pad.drill
        annulus = None
        pad_type = pad.pad_type
        override = overrides.get(pad.number)
        if override:
            size, drill, annulus, pad_type = _apply_pin_override(
                pad, override, size, drill, annulus, pad_type, ref, diags)
        placed_pads.append(PlacedPad(
            id=derive_id("placed-pad", component_id, pad.source_id),
            component_id=component_id,
            source_id=pad.source_id,
            net_id=net_id,
            pad_type=pad_type,
            shape=pad.shape,
            position=transform.point(pad.position),
            size=size,
            rotation_deg=transform.angle(pad.rotation_deg),
            corner_rratio=pad.corner_rratio,
            drill=drill,
            annulus=annulus,
            solder_mask_margin=pad.solder_mask_margin,
            solder_paste_margin=pad.solder_paste_margin,
            layers=layers,
            side=side,
            raw_shape=pad.raw_shape,   # D1 provenance (authored footprint shape)
        ))
    # A validated override that correlates to NO footprint pad would apply to
    # nothing and vanish silently — a fail-closed violation (a sanctioned
    # fabrication deviation lost without a trace). Surface it (Fable SB1 note 1).
    placed_numbers = {pad.number for pad in definition.pads}
    for number in overrides:
        if number not in placed_numbers:
            diags.error("override_without_pad",
                        f"component {ref!r} pin {number!r}: a validated pin `override` "
                        f"correlates to no footprint pad — the deviation would apply to "
                        f"nothing",
                        SourceRef(EntityKind.PAD, f"{ref}.{number}", f"component {ref}"))
    placed_graphics: list[PlacedGraphic] = []
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
        diags.warning("captured_geometry_not_emitted",
                      f"component {ref!r}: captured pad/graphic participation on "
                      f"{sorted(unemitted)} is documentation-only — outside the emitter "
                      f"capability profile",
                      SourceRef(EntityKind.COMPONENT, ref))
    return tuple(placed_pads), tuple(placed_graphics)


def _apply_pin_override(
    pad: PadDefinition,
    override: dict,
    size: Union[tuple[float, float], None],
    drill,
    annulus: Union[float, None],
    pad_type: str,
    ref: str,
    diags: _Diagnostics,
) -> tuple[Union[tuple[float, float], None], object, Union[float, None], str]:
    """Fold a VALIDATED (type-checked) pin `override` onto the footprint-derived
    pad fields, returning ``(size, drill, annulus, pad_type)``.  The footprint is
    the default; the override wins ONLY where a key is present.  Positive/range
    checks live here (not in the type-only validator, for Go-codec parity): a
    non-positive numeric override is a fail-closed ``invalid_pin_override`` ERROR
    and that field is left at the footprint default (so PlacedPad can never be
    constructed with an illegal value and crash the compile).

    Field semantics:
      * ``pad_width_mm`` / ``pad_height_mm`` override one or both size axes; a
        partial override keeps the footprint's other axis.
      * ``annulus_diameter_mm`` sets PlacedPad.annulus.
      * ``drill_mm`` resizes the pad's round drill.  On a drill-less (SMD) pad it
        is REJECTED (``override_drill_on_drilless_pad``) — an SMD→through-hole
        conversion needs copper/mask reconciliation out of scope for the IR
        override channel, and applying it would build an inconsistent PlacedPad.
      * ``plated`` (bool) flips a THROUGH-HOLE pad between plated (``thru_hole``)
        and non-plated (``np_thru_hole``), updating both pad_type and the drill's
        plating flag.  On a drill-less (SMD) pad plating is meaningless — a
        documented no-op (no field change, no diagnostic)."""
    pad_ref = SourceRef(EntityKind.PAD, f"{ref}.{pad.number}", f"component {ref}")

    def positive(key, value) -> bool:
        if _is_positive_number(value):
            return True
        diags.error("invalid_pin_override",
                    f"component {ref!r} pin {pad.number!r}: override.{key} must be a "
                    f"positive number, got {value!r}", pad_ref)
        return False

    # Size axes (partial override keeps the footprint's untouched axis).
    width, height = override.get("pad_width_mm"), override.get("pad_height_mm")
    if width is not None or height is not None:
        new_w = size[0] if size is not None else None
        new_h = size[1] if size is not None else None
        if width is not None and positive("pad_width_mm", width):
            new_w = float(width)
        if height is not None and positive("pad_height_mm", height):
            new_h = float(height)
        if (new_w is None) != (new_h is None):
            diags.error("invalid_pin_override",
                        f"component {ref!r} pin {pad.number!r}: override sizes one axis but the "
                        f"footprint pad has no size on the other — cannot form a pad size", pad_ref)
        elif new_w is not None:
            size = (new_w, new_h)

    # Annulus.
    ann = override.get("annulus_diameter_mm")
    if ann is not None and positive("annulus_diameter_mm", ann):
        annulus = float(ann)

    # Drill size (round).  Rejected on a drill-less pad.
    drill_mm = override.get("drill_mm")
    if drill_mm is not None and positive("drill_mm", drill_mm):
        if drill is None:
            diags.error("override_drill_on_drilless_pad",
                        f"component {ref!r} pin {pad.number!r}: override.drill_mm on a pad with no "
                        f"footprint drill (pad_type {pad.pad_type!r}); a through-hole conversion is "
                        f"out of scope for the IR override channel", pad_ref)
        else:
            if drill.size[0] != drill.size[1]:
                # A scalar drill_mm override collapses a non-round (slot/oval)
                # footprint drill to a round hole — a fab change; never silent
                # (Fable SB1 note 2).
                diags.warning("override_drill_squared_slot",
                              f"component {ref!r} pin {pad.number!r}: override.drill_mm replaces a "
                              f"non-round footprint drill {drill.size} with a round {float(drill_mm)}mm "
                              f"hole", pad_ref)
            drill = replace(drill, size=(float(drill_mm), float(drill_mm)))

    # Plating — through-hole only; a no-op on an SMD (drill-less) pad.
    plated = override.get("plated")
    if isinstance(plated, bool) and drill is not None:
        drill = replace(drill, plated=plated)
        pad_type = "thru_hole" if plated else "np_thru_hole"

    # Validate the FOLDED override state, not just each field in isolation: an
    # override that AUTHORS a copper annulus while also making the pad UNPLATED
    # (np_thru_hole) is contradictory — an unplated hole carries no copper ring, so
    # the annulus would be silently discarded at emission (finding 019f8fe77068).
    # Fail CLOSED rather than drop the authored value.
    if pad_type == "np_thru_hole" and override.get("annulus_diameter_mm") is not None:
        diags.error("override_annulus_on_unplated_pad",
                    f"component {ref!r} pin {pad.number!r}: override authors "
                    f"annulus_diameter_mm but the pad is unplated (np_thru_hole) — an "
                    f"unplated hole carries no copper ring; drop one or the other", pad_ref)

    return size, drill, annulus, pad_type


# Inline per-pin FABRICATION geometry the canonical YAML still carries but that
# the hermetic library footprint is authoritative over (K2 review 625.1).  The
# migration authority fold (019f802ca3af; SB3 super-review 019f8b7fc709): a typed
# pin `override` is the sanctioned deviation channel, and these inline fab keys
# ARE the override keys (same names), so an override synthesized from inline
# geometry is ``{k: pin[k] for k in inline_keys}``.  This legacy inline geometry
# is folded per-compile with fail-closed classification:
#   * MATCHES the footprint (redundant) → dropped silently;
#   * DIVERGES but is VERIFIABLE → auto-MIGRATED to a synthesized typed override
#     and APPLIED (the authored v1 fab deviation is PRESERVED, never ignored);
#   * AMBIGUOUS (no matching pad, or an unverifiable/wrong-type value) → a
#     fail-closed ERROR, because a v1→v2 migration must not mint a v2 board whose
#     fabrication meaning silently changed.
_INLINE_FAB_KEYS = ("drill_mm", "annulus_diameter_mm", "pad_width_mm", "pad_height_mm", "plated")

# Numeric keys of a typed pin `override` (schema-v2 sanctioned deviation); `plated`
# is a separate boolean.  Type-checked ONLY here — matching the Go PinOverride
# codec, which rejects wrong types at unmarshal.  Value-range semantics belong to
# the shared board-v2 spec (Round D), enforced identically on both sides to avoid
# validator drift (comment 629).
_OVERRIDE_NUM_KEYS = ("drill_mm", "annulus_diameter_mm", "pad_width_mm", "pad_height_mm")


def _check_coincidence(comp: dict, definition: FootprintDefinition, ref: str,
                       diags: _Diagnostics) -> dict[str, dict]:
    """Prove each declared pin's LOCAL position matches the footprint pad of the
    same number (fail-closed — silk/copper desync), run the pin-geometry authority
    fold (019f802ca3af), and RETURN the well-formed typed overrides keyed by pin
    number so :func:`_place_component` can apply them to the resolved IR.

    Authority (per the hermetic-CAM keystone) is the LOCKED footprint for any pad
    field a pin does NOT override; a validated typed `override` is the sanctioned
    v2 deviation channel and now supersedes the footprint per-field in the IR
    (019f88a0c84f — applied in _place_component).  The fold runs per-compile,
    version-independent — a board freshly migrated to v2 still carries inline
    geometry the Go migration did not strip, so every compile must normalize it
    (SB3, super-review 019f8b7fc709):
      * a typed pin `override` is validated here (fail-closed on malformed types);
        the well-formed ones are returned for the IR to apply and are NOT
        deprecated;
      * legacy inline drill/annulus/size/plating is classified per pin:
        redundant (MATCHES the footprint) → dropped silently; divergent-but-
        VERIFIABLE → auto-migrated into a synthesized typed override that is
        returned so the IR APPLIES the authored deviation (INFO
        ``inline_pin_geometry_migrated``); ambiguous (no matching pad, or an
        unverifiable value) → a fail-closed ERROR
        (``inline_geometry_without_pad`` / ``inline_geometry_unverifiable``),
        never a silent fab-semantics change.

    Returns ``{pin_number: override_dict}`` for every override — typed or migrated
    from inline — that passed validation (a malformed one emits
    ``invalid_pin_override`` here and is NOT returned, so it is never applied)."""
    validated_overrides: dict[str, dict] = {}
    pins = comp.get("pins")
    if pins is None:
        return validated_overrides
    if not isinstance(pins, list):
        diags.error("invalid_component",
                    f"component {ref!r}: pins must be a list", SourceRef(EntityKind.COMPONENT, ref))
        return validated_overrides
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
        pad = pad_by_number.get(number)
        pad_ref = SourceRef(EntityKind.PAD, f"{ref}.{number}", f"component {ref}")

        # Pin-geometry authority fold. A typed `override` is the sanctioned v2
        # deviation channel: validate it, and let it supersede any legacy inline
        # geometry on the same pin (folded away silently). Otherwise the inline
        # geometry is folded per-compile — redundant → dropped, divergent-but-
        # verifiable → migrated to a synthesized override, ambiguous → fail-closed.
        override = pin.get("override")
        if override is not None and _validate_pin_override(override, ref, number, diags):
            # Well-formed: hand it to the IR builder, which applies it per-field
            # over the footprint default (019f88a0c84f).  Correlated by pin number
            # to the like-numbered footprint pad in _place_component.
            validated_overrides[number] = override
        inline_keys = [k for k in _INLINE_FAB_KEYS if pin.get(k) is not None]
        if inline_keys and override is None:
            _fold_inline_geometry(pin, pad, number, inline_keys, ref,
                                  validated_overrides, diags)
        px, py = pin.get("x_mm"), pin.get("y_mm")
        has_x, has_y = _is_number(px), _is_number(py)
        if not has_x and not has_y:
            continue  # no declared local position — nothing to coincidence-check
        if has_x != has_y:
            diags.error("pin_partial_position",
                        f"component {ref!r} pin {number!r} declares only one of x_mm/y_mm", pad_ref)
            continue
        if pad is None:
            diags.error("pin_without_pad",
                        f"component {ref!r} pin {number!r} has no matching footprint pad", pad_ref)
            continue
        dx, dy = pad.position[0] - float(px), pad.position[1] - float(py)
        if (dx * dx + dy * dy) ** 0.5 > COINCIDENCE_TOL_MM:
            diags.error("pin_pad_desync",
                        f"component {ref!r} pin {number!r}: declared local ({px}, {py}) vs "
                        f"footprint pad {pad.position} exceeds {COINCIDENCE_TOL_MM}mm", pad_ref)
    return validated_overrides


# Outcome tags for the ONE shared per-pin inline-geometry classification.
_INLINE_REDUNDANT = "redundant"
_INLINE_MIGRATE = "migrate"
_INLINE_AMBIGUOUS = "ambiguous"


@dataclass(frozen=True)
class _InlineClassification:
    """Single-source verdict for a pin's legacy inline fabrication geometry.

    Exactly ONE outcome:
      * REDUNDANT → the inline merely restates the footprint; drop it;
      * MIGRATE   → divergent-but-verifiable; ``override`` is the synthesized typed
        override ``{k: pin[k] for k in inline_keys}`` to apply/persist, and
        ``conflicts`` describes the divergence (for the INFO message);
      * AMBIGUOUS → ``error_code``/``error_message`` carry the fail-closed diagnostic.

    Both the compile fold (:func:`_fold_inline_geometry`) and the source rewrite
    (:func:`normalize_board`) consume THIS one verdict, so an override the compiler
    APPLIES and an override normalize PERSISTS can never disagree (SB4 anti-drift)."""
    outcome: str
    override: Union[dict, None] = None
    conflicts: tuple = ()
    error_code: Union[str, None] = None
    error_message: Union[str, None] = None


def _classify_inline_geometry(pin: dict, pad: Union[PadDefinition, None], number: str,
                              inline_keys: list[str], ref: str) -> _InlineClassification:
    """Classify a pin's legacy inline fabrication geometry into exactly one of
    REDUNDANT / MIGRATE / AMBIGUOUS (SB3/SB5, super-review 019f8b7fc709; SB4).

    PURE: records no diagnostics and mutates nothing — the caller acts on the
    verdict.  This is the SOLE inline-geometry decision; the compile fold and
    normalize both call it, so their outcomes cannot drift.  A MIGRATE override
    that would form an illegal PlacedPad still fail-closes downstream in
    ``_apply_pin_override`` (compile) — not double-handled here."""
    fields = ", ".join(inline_keys)
    if pad is None:
        return _InlineClassification(
            _INLINE_AMBIGUOUS,
            error_code="inline_geometry_without_pad",
            error_message=(
                f"component {ref!r} pin {number!r}: legacy inline fabrication geometry "
                f"({fields}) has no matching footprint pad to correlate the deviation "
                f"against — ambiguous, cannot migrate to a typed pin `override`"))
    if not _inline_geometry_verifiable(pin, inline_keys):
        return _InlineClassification(
            _INLINE_AMBIGUOUS,
            error_code="inline_geometry_unverifiable",
            error_message=(
                f"component {ref!r} pin {number!r}: legacy inline fabrication geometry "
                f"({fields}) is not verifiable (wrong value type) — cannot form a "
                f"trustworthy typed pin `override`"))
    conflicts = _inline_geometry_conflicts(pin, pad, number)
    if not conflicts:
        return _InlineClassification(_INLINE_REDUNDANT)  # restates the footprint
    # Divergent but valid → migrate the authored deviation into a typed override.
    synthesized = {k: pin[k] for k in inline_keys}
    return _InlineClassification(_INLINE_MIGRATE, override=synthesized,
                                 conflicts=tuple(conflicts))


def _migrated_info_message(ref: str, number: str, inline_keys: list[str],
                           conflicts) -> str:
    """The ONE ``inline_pin_geometry_migrated`` INFO text, shared by the compile
    fold and normalize so both report an auto-migration identically (naming the
    fields + the divergences)."""
    fields = ", ".join(inline_keys)
    return (f"component {ref!r} pin {number!r}: legacy inline fabrication geometry "
            f"({fields}) diverges from the locked footprint and was auto-migrated to "
            f"a typed pin `override` so the authored deviation is PRESERVED and applied "
            f"({'; '.join(conflicts)}); migrate the source to a typed override")


def _override_apply_rejection(pad: PadDefinition, override: dict,
                              ref: str) -> Union[Diagnostic, None]:
    """Dry-run a synthesized MIGRATE override through the SAME apply-time guards
    :func:`_apply_pin_override` enforces during placement (positive/range checks,
    drill-on-drill-less-pad, one-axis-size), against the resolved *pad*.  Returns
    the first ERROR diagnostic the apply would raise, else ``None``.

    normalize uses this so it NEVER persists an override the compiler would reject
    at apply time (which would mint a source every future compile fail-closes on).
    Reuses ``_apply_pin_override`` verbatim — no forked validity logic."""
    probe = _Diagnostics()
    size = (float(pad.size[0]), float(pad.size[1])) if pad.size is not None else None
    _apply_pin_override(pad, override, size, pad.drill, None, pad.pad_type, ref, probe)
    for d in probe.tuple():
        if d.severity is DiagnosticSeverity.ERROR:
            return d
    return None


def _fold_inline_geometry(pin: dict, pad: Union[PadDefinition, None], number: str,
                          inline_keys: list[str], ref: str,
                          validated_overrides: dict[str, dict], diags: _Diagnostics) -> None:
    """Compile-path adapter over the shared :func:`_classify_inline_geometry`
    verdict.  Called only when the pin carries inline fab keys and NO explicit
    typed `override`.  Three outcomes:

      * redundant → dropped silently — the inline merely restates the footprint;
      * divergent but VERIFIABLE → the synthesized typed override is validated and
        added to *validated_overrides* so the IR APPLIES the deviation, with an
        INFO ``inline_pin_geometry_migrated`` (the authored v1 fab intent is
        PRESERVED, never ignored);
      * ambiguous → fail-closed ERROR (``inline_geometry_without_pad`` /
        ``inline_geometry_unverifiable``); a v1→v2 migration must never mint a v2
        board whose fabrication meaning silently changed."""
    pad_ref = SourceRef(EntityKind.PAD, f"{ref}.{number}", f"component {ref}")
    verdict = _classify_inline_geometry(pin, pad, number, inline_keys, ref)
    if verdict.outcome == _INLINE_REDUNDANT:
        return  # redundant — restates the footprint; drop silently
    if verdict.outcome == _INLINE_AMBIGUOUS:
        diags.error(verdict.error_code, verdict.error_message, pad_ref)
        return
    # MIGRATE — synthesize+apply the authored deviation as a typed override.
    synthesized = verdict.override
    if _validate_pin_override(synthesized, ref, number, diags):
        validated_overrides[number] = synthesized
        diags.info("inline_pin_geometry_migrated",
                   _migrated_info_message(ref, number, inline_keys, verdict.conflicts),
                   pad_ref)


def _inline_geometry_conflicts(pin: dict, pad: PadDefinition, number: str) -> list[str]:
    """Divergences between a pin's inline geometry and its resolved footprint pad."""
    out: list[str] = []
    drill = pin.get("drill_mm")
    if _is_number(drill) and pad.drill is not None and abs(float(drill) - pad.drill.size[0]) > COINCIDENCE_TOL_MM:
        out.append(f"pin {number} drill {drill} vs footprint {pad.drill.size[0]}")
    if _is_number(drill) and pad.drill is None:
        out.append(f"pin {number} declares a drill but the footprint pad has none")
    for axis, key in ((0, "pad_width_mm"), (1, "pad_height_mm")):
        val = pin.get(key)
        if not _is_number(val):
            continue
        if pad.size is None:
            # Inline sizes a pad the footprint gives no size (a size-less
            # np_thru_hole) — a divergence the fold must NOT treat as redundant
            # and silently drop (Fable SB3 note 1); mirrors the drill-vs-no-drill
            # case above.
            out.append(f"pin {number} declares {key} but the footprint pad has no size")
        elif abs(float(val) - pad.size[axis]) > COINCIDENCE_TOL_MM:
            out.append(f"pin {number} {key} {val} vs footprint {pad.size[axis]}")
    annulus = pin.get("annulus_diameter_mm")
    if _is_number(annulus):
        if pad.size is None:
            out.append(f"pin {number} declares an annulus but the footprint pad has no size")
        elif abs(float(annulus) - pad.size[0]) > COINCIDENCE_TOL_MM:
            out.append(f"pin {number} annulus {annulus} vs footprint pad diameter {pad.size[0]}")
    plated = pin.get("plated")
    if isinstance(plated, bool) and pad.drill is not None and plated != pad.drill.plated:
        out.append(f"pin {number} plated {plated} vs footprint {pad.drill.plated}")
    return out


def _inline_geometry_verifiable(pin: dict, inline_keys) -> bool:
    """True only if every present inline fabrication value is the right TYPE to
    compare against a footprint pad (numbers for the mm keys, bool for `plated`).
    A garbage value (e.g. drill_mm: "big") is present but un-comparable — the fold
    cannot prove it redundant, so it must surface it rather than drop it silently
    (_inline_geometry_conflicts skips non-numbers, which would otherwise hide it)."""
    for key in inline_keys:
        val = pin.get(key)
        if key == "plated":
            if not isinstance(val, bool):
                return False
        elif not _is_number(val):
            return False
    return True


def _validate_pin_override(override, ref: str, number: str, diags: _Diagnostics) -> bool:
    """Fail-closed type check of a typed pin `override` — the schema-v2 sanctioned
    channel for an intentional deviation from the locked footprint. The footprint
    stays authoritative for every pad field a pin does NOT override; a validated
    override is applied per-field to the resolved IR by :func:`_place_component`
    (019f88a0c84f).  This gate is type-checking ONLY (positive/value-range checks
    happen at apply time), to stay in parity with the Go PinOverride codec, which
    likewise rejects only wrong types at unmarshal.

    Returns True when the override is well-formed (no diagnostic emitted)."""
    pad_ref = SourceRef(EntityKind.PAD, f"{ref}.{number}", f"component {ref}")
    if not isinstance(override, dict):
        diags.error("invalid_pin_override",
                    f"component {ref!r} pin {number!r}: override must be a mapping, "
                    f"got {type(override).__name__}", pad_ref)
        return False
    ok = True
    for key in _OVERRIDE_NUM_KEYS:
        val = override.get(key)
        if val is not None and not _is_number(val):
            ok = False
            diags.error("invalid_pin_override",
                        f"component {ref!r} pin {number!r}: override.{key} must be a number, "
                        f"got {val!r}", pad_ref)
    plated = override.get("plated")
    if plated is not None and not isinstance(plated, bool):
        ok = False
        diags.error("invalid_pin_override",
                    f"component {ref!r} pin {number!r}: override.plated must be a boolean, "
                    f"got {plated!r}", pad_ref)
    return ok


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


def _build_nets_index(board: dict, board_id: str, diags: _Diagnostics):
    """Return (name→net_id, name→index, (ref,num)→net_id, ordered descriptors).

    Net ids are board-namespaced + NAME-derived; the index is assigned in
    NAME-sorted order (KiCad reserves 0), so a semantically-harmless reorder of
    the board's net list does not renumber the board (keystone comment 608, Q3).
    A pin owned by two nets is a fail-closed error, never last-write-wins (K2
    review 623 R3).  Each descriptor carries its declared pins so a pin that
    never resolves to a placed pad can be diagnosed, not silently dropped."""
    raw_nets = _dict_items(board, "nets", "net", diags)
    name_to_id: dict[str, str] = {}
    name_to_index: dict[str, int] = {}
    pin_net: dict[tuple[str, str], str] = {}
    pin_owner: dict[tuple[str, str], str] = {}
    descriptors: list[tuple[str, str, int, list[tuple[str, str]]]] = []
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
        name_to_id[name] = derive_id("net", board_id, name)
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
        declared: list[tuple[str, str]] = []
        for token in pins or []:
            parsed = _split_pin_ref(token)
            if parsed is None:
                diags.error("invalid_pin_ref",
                            f"net {name!r}: pin ref {token!r} is not 'REF.NUMBER'", _board_ref())
                continue
            prior = pin_owner.get(parsed)
            if prior is not None and prior != name:
                diags.error("duplicate_pin_ownership",
                            f"pin {parsed[0]}.{parsed[1]} is claimed by both {prior!r} and {name!r}",
                            _board_ref())
                continue
            pin_owner[parsed] = name
            pin_net[parsed] = name_to_id[name]
            declared.append(parsed)
        descriptors.append((name_to_id[name], name, name_to_index[name], declared))
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
        elif isinstance(item, (list, tuple)) and len(item) == 2:
            x, y = item[0], item[1]
        else:
            # A 3-tuple point etc. is malformed — do not silently drop the extra.
            diags.error("trace_bad_points", f"trace {ordinal}: point[{index}] is malformed ({item!r})", ref)
            return None
        if not (_is_number(x) and _is_number(y)):
            diags.error("trace_bad_points",
                        f"trace {ordinal}: point[{index}] has non-finite coordinates", ref)
            return None
        points.append((float(x), float(y)))
    return points


def _build_traces(board: dict, board_id: str, net_id_by_name: dict[str, str],
                  schema_version: int, diags: _Diagnostics) -> tuple[ResolvedTrace, ...]:
    traces: list[ResolvedTrace] = []
    for ordinal, raw in enumerate(_dict_items(board, "traces", "trace", diags)):
        net_name = raw.get("net")
        net_id = net_id_by_name.get(net_name) if isinstance(net_name, str) else None
        trace_ref = SourceRef(EntityKind.TRACE, f"trace:{ordinal}", f"net {net_name}")
        if not _validate_child_id("trace", raw, trace_ref, schema_version, diags):
            continue
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
        trace_id = _resolve_child_id("trace", board_id, raw, (net_id, ordinal), schema_version)
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


def _build_vias(board: dict, board_id: str, net_id_by_name: dict[str, str],
                schema_version: int, diags: _Diagnostics) -> tuple[ResolvedVia, ...]:
    vias: list[ResolvedVia] = []
    for ordinal, raw in enumerate(_dict_items(board, "vias", "via", diags)):
        net_name = raw.get("net")
        net_id = net_id_by_name.get(net_name) if isinstance(net_name, str) else None
        via_ref = SourceRef(EntityKind.VIA, f"via:{ordinal}", f"net {net_name}")
        if not _validate_child_id("via", raw, via_ref, schema_version, diags):
            continue
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
        # Via mask TENTING is AUTHORED by the source and DEFAULTS TENTED (the
        # historical CAM behavior): a tented via has no mask opening; an untented via
        # exposes its annulus (finding 019f8fe7cbaf). A single `tented` bool sets both
        # sides (the v1 symmetric case); a non-bool fails closed.
        raw_tented = raw.get("tented", True)
        if not isinstance(raw_tented, bool):
            diags.error("via_bad_tented",
                        f"via {ordinal}: tented must be a boolean, got {raw_tented!r}", via_ref)
            continue
        vias.append(ResolvedVia(
            id=_resolve_child_id("via", board_id, raw, (net_id, ordinal), schema_version),
            position=(float(x), float(y)),
            diameter_mm=float(diameter),
            drill_mm=float(drill),
            net_id=net_id,
            kind=ViaKind.THROUGH,
            from_layer=from_layer,
            to_layer=to_layer,
            tented_front=raw_tented,
            tented_back=raw_tented,
        ))
    return tuple(vias)


def _build_holes(board: dict, board_id: str, schema_version: int,
                 diags: _Diagnostics) -> tuple[ResolvedHole, ...]:
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
            if not _validate_child_id("hole", raw, hole_ref, schema_version, diags):
                continue
            if not (_is_number(x) and _is_number(y) and _is_positive_number(diameter)):
                diags.error("hole_bad_geometry",
                            f"{key}[{ordinal}]: needs finite x/y and a positive diameter", hole_ref)
                continue
            if key == "mounting_holes":
                raw_plated = raw.get("plated", default_plated)
                if not isinstance(raw_plated, bool):
                    # A string "false" must NOT coerce to a plated hole (review 623 R2).
                    diags.error("hole_bad_plating",
                                f"{key}[{ordinal}]: plated must be a boolean, got {raw_plated!r}", hole_ref)
                    continue
            else:
                # pth_holes / npth_holes: the alias KEY is the plating declaration and
                # is AUTHORITATIVE — an explicit `plated` is overridden by the key,
                # matching Go's NormalizeHoles so the two paths cannot diverge on a
                # fab-critical flag (Fable D2). A contradicting explicit value WARNs
                # (never silent) but the key wins.
                raw_plated = default_plated
                explicit = raw.get("plated")
                if isinstance(explicit, bool) and explicit != default_plated:
                    diags.warning("alias_plating_overridden",
                                  f"{key}[{ordinal}]: explicit plated={explicit} overridden by "
                                  f"the {key!r} alias (the key declares plating); folded as "
                                  f"plated={default_plated}", hole_ref)
            # AUTHORED annulus (finding 019f8dbb7104): a PLATED board hole's copper
            # ring must be AUTHORED, not invented — so both emitters emit the SAME
            # copper (no kicad-2x-drill vs gerber-drill-only divergence).
            raw_annulus = raw.get("annulus_mm")
            annulus: Union[float, None] = None
            if raw_plated:
                if not _is_positive_number(raw_annulus):
                    # Fail CLOSED: no invented copper on a fabrication-critical plated
                    # hole. The source must author annulus_mm (> the drill diameter).
                    diags.error("plated_hole_needs_annulus",
                                f"{key}[{ordinal}]: a plated hole must author a positive "
                                f"'annulus_mm' (its copper ring diameter); got {raw_annulus!r}",
                                hole_ref)
                    continue
                if float(raw_annulus) <= float(diameter):
                    diags.error("hole_annulus_not_bigger_than_drill",
                                f"{key}[{ordinal}]: annulus_mm {raw_annulus} must exceed the "
                                f"drill diameter {diameter} to leave a copper ring", hole_ref)
                    continue
                annulus = float(raw_annulus)
            elif raw_annulus is not None:
                # An unplated hole carries no copper — an authored annulus is a
                # contradiction, not silently dropped.
                diags.error("unplated_hole_has_annulus",
                            f"{key}[{ordinal}]: an unplated hole cannot carry an "
                            f"'annulus_mm' (no copper); got {raw_annulus!r}", hole_ref)
                continue
            holes.append(ResolvedHole(
                id=_resolve_child_id("hole", board_id, raw, (key, ordinal), schema_version),
                feature=RoundHole(position=(float(x), float(y)), diameter_mm=float(diameter)),
                plated=raw_plated,
                kind=HoleKind.PTH if raw_plated else HoleKind.NPTH,
                annulus_mm=annulus,
            ))
    return tuple(holes)


_MINTED_HEX_LEN = 32  # 128-bit mint → 32 lowercase hex chars


def _is_minted_id(entity: str, value) -> bool:
    """True iff ``value`` is a well-formed minted id ``"<entity>:<32 lc hex>"`` —
    byte-for-byte the shape the Go v1→v2 migration writes (migrate.go
    ``isMintedID``).  Anything else (absent, a legacy ordinal-shaped ``trace_1``,
    a foreign shape) is UNMINTED, which for a v2 board is fatal."""
    if not isinstance(value, str):
        return False
    prefix = entity + ":"
    if len(value) != len(prefix) + _MINTED_HEX_LEN:
        return False
    if not value.startswith(prefix):
        return False
    return all(c in "0123456789abcdef" for c in value[len(prefix):])


def _authored_id_ok(raw: dict, ref: SourceRef, diags: _Diagnostics) -> bool:
    """A present-but-non-string authored ``id`` is an error, not silently
    replaced by an ordinal (K2 review 625.3)."""
    authored = raw.get("id")
    if authored is not None and not (isinstance(authored, str) and authored):
        diags.error("invalid_authored_id",
                    f"authored id {authored!r} must be a non-empty string", ref)
        return False
    return True


def _validate_child_id(entity: str, raw: dict, ref: SourceRef,
                       schema_version: int, diags: _Diagnostics) -> bool:
    """Version-dispatched id precondition for a trace/via/hole.

    v2 REQUIRES a persisted minted id and fails closed without one — a v2 board
    that reaches an identity-dependent compile without minted ids has skipped the
    migration, and routing/DRC against unstable identity is the exact hazard this
    gate exists to prevent.  v1 keeps the permissive authored-or-ordinal bridge."""
    if schema_version >= 2:
        pid = raw.get("id")
        if not _is_minted_id(entity, pid):
            diags.error("unminted_persistent_id",
                        f"{entity} lacks a persisted minted id (got {pid!r}); a v2 board must be "
                        f"migrated (ids minted at pcb.deserialize) before an identity-dependent "
                        f"compile", ref)
            return False
        return True
    return _authored_id_ok(raw, ref, diags)


def _resolve_child_id(entity: str, board_id: str, raw: dict,
                      ordinal_parts: tuple, schema_version: int) -> str:
    """The final child id: the persisted minted id in v2 (already validated by
    :func:`_validate_child_id`), or the v1 authored/ordinal-derived id."""
    if schema_version >= 2:
        return raw["id"]
    return _authored_or_ordinal_id(entity, board_id, raw, *ordinal_parts)


def _authored_or_ordinal_id(entity: str, board_id: str, raw: dict, *ordinal_parts) -> str:
    """Honor an authored ``id`` when present; otherwise mint a deterministic
    ORDINAL-derived id.  Both forms are BOARD-NAMESPACED (review 623 R4) so the
    same authored/ordinal id in two boards yields distinct ids.  Ordinal ids are
    stable for a compile-from-scratch but NOT under reorder/insert — the compile
    emits an INFO diagnostic recording this so the mint-and-persist handoff
    (YAML v2) is visible (review 621 MF4)."""
    authored = raw.get("id")
    if isinstance(authored, str) and authored:
        return derive_id(entity, board_id, "authored", authored)
    return derive_id(entity, board_id, *(str(part) for part in ordinal_parts))


# ---------------------------------------------------------------------------
# Top-level compile.
# ---------------------------------------------------------------------------


# Human messages for the shared-boundary codes validate_board_v2 returns as bare
# strings; the CODE is the contract (matched by vectors + Go), the message is
# operator context. Kept beside compile_board's early gate that emits them.
_BOUNDARY_MESSAGES = {
    "unsupported_schema_version": "canonical board schema requires an integer version 1 or 2 (present)",
    "unminted_persistent_id": "a v2 board and every trace/via/hole require a minted \"<kind>:<32hex>\" id",
    "duplicate_persistent_id": "a persistent id is duplicated within its entity domain",
    "invalid_board_structure": "a top-level entity collection is malformed or carries a null item",
    "invalid_pin_override": "a pin override field has the wrong type",
}


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

    # Shared-boundary gate FIRST (findings 019f88bac172 / 019f8b7fb07e): the
    # production compiler must run the SAME structural + persistent-id validator
    # the Go codec and the committed vectors use, so a duplicate persistent id or a
    # null / identity-less list item fails CLOSED here with its EXPLICIT shared code
    # — not later as a generic ``board_invariant`` raised by ResolvedBoard
    # construction (previously the only thing that caught duplicate ids). Imported
    # lazily because board_validate imports predicates FROM this module (cycle).
    from .board_validate import validate_board_v2
    seen_codes: set[str] = set()
    for code in validate_board_v2(board):
        if code in seen_codes:
            continue
        seen_codes.add(code)
        diags.error(code, _BOUNDARY_MESSAGES.get(code, code), _board_ref())
    if seen_codes:
        return ResolutionFailure(diagnostics=diags.tuple())

    # Dispatch on the schema version FIRST: the canonical contract types version
    # as an integer, so it must be PRESENT and exactly int 1 or int 2 — a missing
    # field, a float 1.0, or any other value must never be interpreted (review
    # 630).  v1 keeps the ordinal-id bridge; v2 REQUIRES persisted minted ids
    # (fail-closed, item 019f802ca3af Round C).
    version = board.get("version")
    if type(version) is not int or version not in (1, 2):
        diags.error("unsupported_schema_version",
                    f"canonical board schema requires an integer version 1 or 2 (present); got "
                    f"{version!r} of type {type(version).__name__}", _board_ref())
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
    # The board id namespaces every derived child id (net/component/segment) so
    # the same ref/net in two boards yields distinct ids (K2 review 623 R4).
    #   v2: it MUST be the persisted, minted board id (fail-closed) — the whole
    #       point of the migration is that identity is stable, not re-derived.
    #   v1: it stays content-derived (the pre-migration bridge).
    if version >= 2:
        persisted_board_id = board.get("id")
        if _is_minted_id("board", persisted_board_id):
            board_id = persisted_board_id
        else:
            diags.error("unminted_persistent_id",
                        f"v2 board lacks a persisted minted id (got {persisted_board_id!r}); it must "
                        f"be migrated (ids minted at pcb.deserialize) before an identity-dependent "
                        f"compile", _board_ref())
            board_id = derive_id("board", str(name or "<unnamed>"), "unminted-v2")
    else:
        board_id = derive_id("board", str(name or "<unnamed>"), str(version))

    # Reject recognized-but-unsupported board features by PRESENCE, not
    # truthiness — an empty-mapping ``zones: {}`` is still a declaration we must
    # refuse rather than treat as absent (review 623 R2).  An explicitly empty
    # list declares nothing and is allowed.
    for unsupported_key in ("zones", "board_graphics", "keepouts"):
        value = board.get(unsupported_key)
        if value is None or (isinstance(value, list) and not value):
            continue
        diags.error("unsupported_board_feature",
                    f"board declares {unsupported_key!r} ({value!r}), which v1 cannot fabricate",
                    _board_ref())

    two_layer = _require_two_layer(board, diags)
    outline = _build_outline(board, diags)
    layer_stack = _build_layer_stack() if two_layer else None
    design_rules = _build_design_rules(board, requested_outputs, diags)

    net_id_by_name, _net_index, pin_net, net_descriptors = _build_nets_index(board, board_id, diags)

    interned: dict[str, FootprintDefinition] = {}
    components: list[ResolvedComponent] = []
    pad_ids_by_net: dict[str, list[str]] = {}
    resolved_pins: set[tuple[str, str]] = set()

    for position, comp in enumerate(_dict_items(board, "components", "component", diags)):
        raw_ref = comp.get("ref")
        ref = raw_ref if isinstance(raw_ref, str) else ""
        comp_ref = SourceRef(EntityKind.COMPONENT, ref or f"<component:{position}>")
        fp_ref = comp.get("footprint")
        if not isinstance(raw_ref, str) or not raw_ref:
            # A non-string ref (int 123, a mapping) must fail, not be stringified.
            diags.error("invalid_component",
                        f"component {position} has a non-string/empty ref {raw_ref!r}", comp_ref)
            continue
        if not isinstance(fp_ref, str) or not fp_ref:
            diags.error("invalid_component", f"component {ref!r} has no footprint ref", comp_ref)
            continue
        if not (_is_number(comp.get("x_mm")) and _is_number(comp.get("y_mm"))):
            diags.error("invalid_component", f"component {ref!r} has no finite x_mm/y_mm placement", comp_ref)
            continue
        rotation = comp.get("rotation_deg")
        if rotation is not None and not _is_number(rotation):
            diags.error("invalid_component",
                        f"component {ref!r} has non-finite rotation_deg {rotation!r}", comp_ref)
            continue
        raw_value = comp.get("value")
        if raw_value is not None and not isinstance(raw_value, str):
            # The canonical contract types Component.Value as a string; a present
            # non-string value must not be stringified into the identity-bearing
            # IR (would corrupt KiCad/BOM output — review 630).
            diags.error("invalid_component",
                        f"component {ref!r} value must be a string, got {raw_value!r}", comp_ref)
            continue
        side = _resolve_side(comp.get("layer"), ref, comp_ref, diags)
        if side is None:
            continue

        entry = lock.get(fp_ref)
        if entry is not None and (not isinstance(entry, dict)
                                  or not isinstance(entry.get("path"), str)
                                  or not isinstance(entry.get("sha256"), str)):
            diags.error("lock_entry_malformed",
                        f"component {ref!r}: lock entry for {fp_ref!r} is malformed", comp_ref)
            continue
        try:
            parsed = resolve_footprint(fp_ref, library_root=library_root, lock=lock)
        except FootprintLookupError as exc:
            diags.error("footprint_unresolved", f"component {ref!r}: {exc}", comp_ref)
            continue

        entry = entry or {}
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
        pin_overrides = _check_coincidence(comp, clean, ref, diags)

        component_id = derive_id("component", board_id, ref)
        placed = _place_component(comp, component_id, clean, side, pin_net, pin_overrides, ref, diags)
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
                rotation_deg=float(rotation or 0.0),
                side=side,
            ),
            placed_pads=placed_pads,
            placed_graphics=placed_graphics,
            provenance=provenance,
            value=raw_value or "",
        ))
        for pad in clean.pads:
            resolved_pins.add((ref, pad.number))
        for pad in placed_pads:
            if pad.net_id is not None:
                pad_ids_by_net.setdefault(pad.net_id, []).append(pad.id)

    nets = _finalize_nets(net_descriptors, pad_ids_by_net, resolved_pins, components, diags)
    traces = _build_traces(board, board_id, net_id_by_name, version, diags)
    vias = _build_vias(board, board_id, net_id_by_name, version, diags)
    holes = _build_holes(board, board_id, version, diags)

    # The ordinal-id bridge diagnostic is a v1-only artifact: v2 ids are the
    # persisted minted identity (validated above), not ordinal-derived, so there
    # is nothing to warn about.
    if version == 1 and (traces or vias or holes):
        diags.info("ordinal_ids",
                   "trace/via/hole ids are ordinal-derived and board-namespaced but NOT stable "
                   "under reorder/insert; persisted authored identity is a YAML-v2 handoff that "
                   "must land before any DRC/routing consumer switches onto the IR",
                   _board_ref())

    if diags.has_error or outline is None or layer_stack is None or design_rules is None:
        return ResolutionFailure(diagnostics=_ensure_error(diags))

    try:
        source_digest = content_id(board)
        library_lock_ref = content_id(lock)
    except CanonicalizationError as exc:
        # e.g. an out-of-I-JSON-range integer inside an opaque annotation blob:
        # a digest is a hard requirement, so fail closed rather than raise.
        diags.error("uncanonicalizable_board",
                    f"board cannot be canonicalized for a provenance digest: {exc}", _board_ref())
        return ResolutionFailure(diagnostics=_ensure_error(diags))
    provenance = BoardProvenance(
        compiler_version=f"{COMPILER_VERSION}+transform/{TRANSFORM_VERSION}",
        source_digest=source_digest,
        library_lock_ref=library_lock_ref,
        rule_profile_ref=V1_RULE_PROFILE,
    )

    try:
        resolved = ResolvedBoard(
            id=board_id,
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


def _footprint_pad_map(fp_ref, *, library_root, lock) -> dict[str, PadDefinition]:
    """Resolve a component's footprint to a ``{pad_number: PadDefinition}`` map via
    the SAME footprint-resolution path the compile fold classifies against
    (``resolve_footprint`` → :class:`FootprintDefinition`), so normalize correlates
    each pin to exactly the pad the compiler would.  Best-effort: a missing/invalid
    ref or an unresolvable footprint yields an empty map, which makes any inline pin
    on that component AMBIGUOUS (fail-closed), never silently migrated.  Marker
    adjudication is intentionally skipped — it only strips feature markers and never
    alters pad drill/size geometry, which is all the classification reads."""
    if not isinstance(fp_ref, str) or not fp_ref:
        return {}
    try:
        parsed = resolve_footprint(fp_ref, library_root=library_root, lock=lock)
    except (FootprintLookupError, KeyError, TypeError, ValueError, OSError):
        # Unresolvable OR a malformed lock entry (missing path/sha, wrong type) →
        # no pads. Any inline pin then classifies AMBIGUOUS (fail-closed), never
        # silently migrated. A broken lock must not crash normalize.
        return {}
    definition = FootprintDefinition.from_kicad_parsed(parsed)
    pad_by_number: dict[str, PadDefinition] = {}
    for pad in definition.pads:
        pad_by_number.setdefault(pad.number, pad)
    return pad_by_number


def normalize_board(
    source_board: dict,
    *,
    library_root: Union[str, Path, None] = None,
    lockfile: Union[str, Path, None] = None,
) -> tuple[Union[dict, None], tuple[Diagnostic, ...]]:
    """Rewrite a canonical SOURCE board to its normalized v2 shape — the "sync-back"
    the compile fold never performs (SB4).  PURE: returns ``(normalized_board,
    diagnostics)`` and NEVER writes to disk; the host owns persistence.

    For each component pin that carries legacy inline fabrication geometry
    (``_INLINE_FAB_KEYS``) and NO explicit typed ``override``, the SAME
    :func:`_classify_inline_geometry` verdict the compiler applies decides:

      * REDUNDANT → delete the inline fab keys (it merely restated the footprint);
        records an INFO ``inline_pin_geometry_dropped``;
      * MIGRATE   → set ``pin["override"]`` to the synthesized typed override and
        delete the inline fab keys (the authored deviation is PRESERVED as the
        sanctioned v2 channel); records an INFO ``inline_pin_geometry_migrated``
        (same code/shape the compile fold emits).  The synthesized override is
        FIRST dry-run through the compiler's apply-time guards
        (:func:`_override_apply_rejection`): if the compiler would reject it at
        apply (non-positive value, drill on a drill-less pad, …), the pin is
        fail-closed instead — normalize must never persist a source every future
        compile rejects;
      * AMBIGUOUS → a fail-closed ERROR diagnostic; the WHOLE normalize fails (no
        board returned) — a half-normalized source is worse than none.

    A pin that already has an explicit ``override`` keeps it, but any legacy inline
    fab keys it ALSO carries are SUPERSEDED by the override (fold doctrine) and are
    dropped (INFO ``inline_pin_geometry_dropped``).  A pin with no inline geometry
    is left UNCHANGED.  The returned board is a CLEAN canonical source (SAME shape
    as the input): footprints are resolved for CLASSIFICATION only and their pads
    are never leaked into the output (no ``comp["pads"]``/``graphics``).  IDEMPOTENT
    — a second pass is a no-op (rewritten pins now carry ``override`` and/or no
    inline).

    INVARIANT: a board normalize SUCCEEDS on must compile; a board compile rejects,
    normalize also rejects."""
    diags = _Diagnostics()
    if not isinstance(source_board, dict):
        diags.error("invalid_board", "board must be a mapping", _board_ref())
        return None, diags.tuple()

    try:
        lock = load_lockfile(lockfile)
        if not isinstance(lock, dict):
            raise ValueError("lockfile is not a mapping")
    except Exception as exc:  # noqa: BLE001 — structured error, not a crash
        diags.error("lock_unreadable", f"footprint lock could not be loaded: {exc}", _board_ref())
        return None, diags.tuple()

    # Never mutate the caller's input; footprint resolution reads a fresh copy so
    # no resolve artifact can leak into the returned board.
    board = copy.deepcopy(source_board)
    components = board.get("components")
    if not isinstance(components, list):
        return board, diags.tuple()  # nothing to normalize

    # Collect mutations first and apply them ONLY if no pin was ambiguous, so an
    # ambiguous board is returned un-normalized (fail-closed, all-or-nothing).
    pending: list[tuple[dict, list[str], Union[dict, None]]] = []
    for comp in components:
        if not isinstance(comp, dict):
            continue
        pins = comp.get("pins")
        if not isinstance(pins, list):
            continue
        ref = comp.get("ref") if isinstance(comp.get("ref"), str) else ""
        pad_by_number = _footprint_pad_map(comp.get("footprint"),
                                           library_root=library_root, lock=lock)
        for pin in pins:
            if not isinstance(pin, dict):
                continue
            number = str(pin.get("number"))
            pad_ref = SourceRef(EntityKind.PAD, f"{ref}.{number}", f"component {ref}")
            inline_keys = [k for k in _INLINE_FAB_KEYS if pin.get(k) is not None]

            # An explicit override supersedes any legacy inline (fold doctrine):
            # keep the override, drop the superseded inline keys.
            if pin.get("override") is not None:
                if inline_keys:
                    diags.info("inline_pin_geometry_dropped",
                               f"component {ref!r} pin {number!r}: legacy inline fabrication "
                               f"geometry ({', '.join(inline_keys)}) is superseded by the pin's "
                               f"explicit typed `override` and was dropped from the source", pad_ref)
                    pending.append((pin, inline_keys, None))
                continue

            if not inline_keys:
                continue  # no inline geometry — leave as-is

            pad = pad_by_number.get(number)
            verdict = _classify_inline_geometry(pin, pad, number, inline_keys, ref)
            if verdict.outcome == _INLINE_AMBIGUOUS:
                diags.error(verdict.error_code, verdict.error_message, pad_ref)
                continue
            if verdict.outcome == _INLINE_REDUNDANT:
                diags.info("inline_pin_geometry_dropped",
                           f"component {ref!r} pin {number!r}: legacy inline fabrication geometry "
                           f"({', '.join(inline_keys)}) is redundant (restates the locked "
                           f"footprint) and was dropped from the source", pad_ref)
                pending.append((pin, inline_keys, None))
            else:  # MIGRATE — but never persist an override the compiler would reject.
                rejection = _override_apply_rejection(pad, verdict.override, ref)
                if rejection is not None:
                    diags.error(rejection.code, rejection.message, rejection.source_ref)
                    continue
                diags.info("inline_pin_geometry_migrated",
                           _migrated_info_message(ref, number, inline_keys, verdict.conflicts),
                           pad_ref)
                pending.append((pin, inline_keys, verdict.override))

    if diags.has_error:
        return None, diags.tuple()  # ambiguous → whole normalize fails, no board

    for pin, inline_keys, override in pending:
        for key in inline_keys:
            del pin[key]
        if override is not None:
            pin["override"] = override
    return board, diags.tuple()


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


def _finalize_nets(descriptors, pad_ids_by_net, resolved_pins, components,
                   diags: _Diagnostics) -> tuple[ResolvedNet, ...]:
    """Assemble ResolvedNets from placed-pad membership.  EVERY declared pin must
    resolve to a placed pad — a well-formed reference to a nonexistent pad is an
    ERROR, never silently dropped (K2 review 623 R3).  A net with no resolved
    pads is likewise an error."""
    placed_pad_ids = {pad.id for comp in components for pad in comp.placed_pads}
    nets: list[ResolvedNet] = []
    for net_id, name, index, declared in descriptors:
        net_ref = SourceRef(EntityKind.NET, net_id, f"net {name}")
        for pin in declared:
            if pin not in resolved_pins:
                diags.error("net_pin_unresolved",
                            f"net {name!r}: pin {pin[0]}.{pin[1]} has no resolved placed pad", net_ref)
        seen: set[str] = set()
        ordered: list[str] = []
        for pad_id in pad_ids_by_net.get(net_id, []):
            if pad_id in placed_pad_ids and pad_id not in seen:
                seen.add(pad_id)
                ordered.append(pad_id)
        if not ordered:
            diags.error("empty_net", f"net {name!r} has no resolved placed pads", net_ref)
            continue
        nets.append(ResolvedNet(id=net_id, name=name, index=index, pad_refs=tuple(ordered)))
    return tuple(nets)


def _ensure_error(diags: _Diagnostics) -> tuple[Diagnostic, ...]:
    items = diags.tuple()
    if any(d.severity is DiagnosticSeverity.ERROR for d in items):
        return items
    return items + (Diagnostic(DiagnosticSeverity.ERROR, "compile_failed",
                               "board could not be resolved", _board_ref()),)
