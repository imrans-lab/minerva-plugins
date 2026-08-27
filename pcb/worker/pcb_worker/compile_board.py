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
import math
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Iterable, Union

from agent_router.layers import (CANON_TO_KICAD, canon_to_kicad,
                                 inner_layer_index, is_copper, kicad_to_canon)

from . import bless
from . import board_graphics as board_graphics_mod
from . import inline_footprint
from .board_schema import (
    _BOUNDARY_MESSAGES,
    _OVERRIDE_NUM_KEYS,
    _is_minted_id,
    _is_number,
)
from .board_validate import validate_board_v2
from .canonical_id import CanonicalizationError, content_id, derive_id
from .fab_capability import (
    EMITTED_LAYERS,
    FABRICATION_CRITICAL_OUTPUTS,
    ROUTING_CRITICAL_OUTPUTS,
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
    SEED_LAYER,
    FootprintLookupError,
    load_library_chain,
    lookup_footprint_layer,
    resolve_footprint_layered,
)
from .geometry import (
    BOTTOM_LAYER_NAMES,
    PlacementTransform,
    TOP_LAYER_NAMES,
    TRANSFORM_VERSION,
)
from .zone_fill import (
    CulledRegion,
    default_zone_minima,
    ZoneFillError,
    _to_nm as _zone_to_nm,
    fill_area_mm2,
    fill_board_zones,
    refuse_non_simple_ring as _zone_refuse_non_simple_ring,
)
from .manufacturer_profile import (
    DEFAULT_PROFILE_ROOT,
    LoadedRuleProfile,
    RuleProfileError,
    load_rule_profile,
)
from .resolved_board import (
    ArcGeometry,
    BoardProvenance,
    CircleGeometry,
    ConnectMode,
    Contour,
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
    NetClass,
    PhysicalStackup,
    Placement,
    PlacedGraphic,
    PlacedPad,
    PolygonGeometry,
    ProfileOutline,
    RectOutline,
    ResolvedBoard,
    ResolvedComponent,
    ResolvedCutout,
    ResolvedDesignRules,
    ResolvedHole,
    ResolvedLayer,
    ResolvedNet,
    ResolvedTrace,
    ResolvedTraceSegment,
    ResolvedVia,
    ResolvedZone,
    ResolutionFailure,
    ResolutionResult,
    ResolutionSuccess,
    RoundHole,
    RoutingDefaults,
    Side,
    SourceRef,
    StackupEntry,
    StackupKind,
    ThermalSettings,
    UnsupportedFeature,
    ViaKind,
    ZoneKind,
)

COMPILER_VERSION = "pcb-k2/1"

# Coincidence tolerance (mm) — a board that declares per-pin local positions must
# agree with the resolved footprint pad of the same number, else silk desyncs
# from copper.  Same threshold the legacy resolve path enforces.
COINCIDENCE_TOL_MM = 0.01

# The canonical DEFAULT stack (a board that declares no ``layers`` key).
# Copper ids + KiCad aliases come from agent_router.layers — the single
# worker-side authority — so this module cannot drift from the router/emitter
# mapping.  Since epoch GA-1 a board may declare a DEEPER stack
# (top, in1..in(N-2), bottom); the declaration is validated by the shared
# boundary (``validate_board_v2``) and gated against the selected
# manufacturer profile's ``max_copper_layers`` capability, not against this
# pair.
_TOP_ID, _BOTTOM_ID = "top", "bottom"

# Emitter capability + the fatal-output profile come from the ONE neutral
# authority (fab_capability), imported by K2 AND every emitter, so they cannot
# drift independently (K2 review 623, decision a).  Captured footprint geometry
# on a layer outside EMITTED_LAYERS is DOCUMENTATION-ONLY and warned -- UNLESS
# the layer is copper (see ``_is_emitted_layer`` / ``_place_component``): a
# copper trace/pad that never reaches a gerber is not documentation, it is
# fabrication silently missing what the board author authored (019fa73a8732).
K3_EMITTED_LAYERS = EMITTED_LAYERS

# The KiCad roundrect corner-ratio convention default (corner radius = ratio *
# min(w, h)), resolved ONCE here — the single site named by 019fa73a4f88 — and
# baked onto the IR pad (PlacedPad.corner_rratio) so neither fab emitter carries
# its own copy of this default. Applied ONLY to a roundrect pad that authors no
# ratio (see ``_place_component``); a rect/circle/oval pad, and an AUTHORED 0.0
# on a roundrect pad, both pass through untouched — this is a default fill-in,
# never a geometry override.
DEFAULT_ROUNDRECT_RRATIO = 0.25


def _is_emitted_layer(layer_id: str, copper_aliases: frozenset[str]) -> bool:
    """Membership in THIS BOARD's fabricated layer set, canonical-id aware.

    Copper participation is judged against ``copper_aliases`` -- the KiCad
    aliases of the board's OWN resolved stack (epoch GA-1: the stack is
    declared per board, so "copper the emitter cannot write" is a per-board
    question, no longer a global one).  Non-copper participation keeps the
    global ``K3_EMITTED_LAYERS`` accept-set: mask/paste/silk/edge capability
    does not vary with copper depth.

    ``top``/``bottom``/``in<k>`` are the SAME copper layers as
    ``F.Cu``/``B.Cu``/``In<k>.Cu`` under the canonical name -- a footprint or
    board that spells them the canonical way must not be misreported as
    declaring copper outside the stack, so copper ids are folded through
    ``canon_to_kicad`` (idempotent for already-KiCad names) before the
    membership test.
    """
    if is_copper(layer_id):
        return canon_to_kicad(layer_id) in copper_aliases
    return layer_id in K3_EMITTED_LAYERS

# Fabrication-critical outputs a captured-feature loss may corrupt. WHICH
# domains those are, and why, is stated ONCE at the definition in
# fab_capability.py -- deliberately not restated here. This comment previously
# carried its own copy of the rationale ("Cosmetic (silk/fab) and unemitted
# (paste) losses are warned, never fatal"), and that copy went stale unnoticed
# when paste emission shipped, leaving the compiler asserting paste was
# non-fatal while the tuple it annotates made it fatal. Duplicating the
# rationale is what let one copy rot; point at the definition instead.
V1_FAB_OUTPUTS: tuple[str, ...] = FABRICATION_CRITICAL_OUTPUTS
# The requested-output profile canonical ROUTING compiles against (Round E).
V1_ROUTING_OUTPUTS: tuple[str, ...] = ROUTING_CRITICAL_OUTPUTS

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

# Manufacturing floor origin (K21, docket 019f762004dc): a VERSIONED,
# digest-pinned rule source is the only sanctioned origin for a design-rule
# minimum (keystone comment 608 fail-closed sweep) — the board's authored
# clearance may only TIGHTEN min_clearance above the SELECTED profile's floor,
# never weaken it (K2 review 621 MF5; see ``_floor_with_clearance``).
#
# The floor used to be a hardcoded dict here. It is now a LOADABLE, PINNED,
# FAIL-CLOSED profile (``manufacturer_profile.load_rule_profile``): a board
# selects one by id via ``design_rules.rule_profile``; a board that selects
# nothing gets the SAME v1 numbers as before, now shipped as a real profile
# file (``pcb/library/profiles/v1-fab-conservative.json``) rather than a
# Python literal, loaded through the identical fail-closed path any other
# profile takes. There is no separate "hardcoded default" code path to drift
# from the shipped file.
DEFAULT_RULE_PROFILE_ID = "v1-fab-conservative"


def _default_rule_profile() -> LoadedRuleProfile:
    # Eager at import time (mirrors the prior ``V1_RULE_PROFILE = _v1_rule_profile()``
    # module-level constant): a broken default profile file must fail the
    # instant this module is imported, not silently the first time a board
    # omits ``rule_profile``.
    return load_rule_profile(DEFAULT_RULE_PROFILE_ID)


_DEFAULT_RULE_PROFILE = _default_rule_profile()
V1_RULE_PROFILE = _DEFAULT_RULE_PROFILE.ref


@dataclass(frozen=True)
class AdjudicationContext:
    """What the policy is allowed to know about the marker it is judging.

    The :class:`CapabilityPolicy` protocol types its second parameter ``object``
    ("whatever the caller had"), and for every marker except ``zone_connect``
    nothing is read from it at all. ``zone_connect`` needs the owning pad's net
    and copper layers to tell a pour it could touch from one it could not, and
    :func:`_adjudicate_footprint` already has both in scope -- so they are
    handed over as a named record rather than smuggled through a wider dict or
    duplicated onto every marker.

    ``pad`` is ``None`` for a marker on the footprint itself rather than on one
    of its pads; relevance then falls back to the board-wide pour test, which is
    the conservative reading of an inherited default.
    """

    board: dict
    ref: str = ""
    pad: PadDefinition | None = None


class DefaultCapabilityPolicy:
    """v1 fatality policy (implements the :class:`CapabilityPolicy` protocol).

    K2 is authoritative: fatality is decided by the marker's fabrication DOMAIN
    against the requested outputs, NOT by the parser's ``default_blocking`` hint.
    A copper/drill/mask/paste marker is fatal when that output is requested; a
    documentation/silk/fab omission is non-fatal (warned).  ``zone_connect`` is
    decided by its VALUE first and its RELEVANCE second — see
    :func:`_zone_connect_blocks`.
    """

    def is_blocking(
        self,
        marker: UnsupportedFeature,
        board_context: object,
        requested_outputs: tuple[str, ...],
    ) -> bool:
        if marker.feature == "zone_connect":
            return _zone_connect_blocks(marker, board_context)
        if marker.domain not in _FATAL_DOMAINS:
            return False
        # Fatal when the marker's own domain OR any of its explicitly-attributed
        # affected outputs is one the caller requested (review 623 R5).
        if marker.domain.value in requested_outputs:
            return True
        return any(output in requested_outputs for output in marker.affected_outputs)


# KiCad's ZONE_CONNECTION enum, as the pad/footprint token spells it.
_ZONE_CONNECT_NONE = 0        # isolate: the pour must carve around this pad
_ZONE_CONNECT_THERMAL = 1     # spokes bridging pad to pour across a gap
_ZONE_CONNECT_SOLID = 2       # merge pad into pour -- what v1 fill does
_ZONE_CONNECT_THT_THERMAL = 3 # thermal on a through-hole pad, solid on an SMD one

# The pad types ``zone_connect 3`` treats as SMD, i.e. everything that lands its
# copper on one face rather than spanning a drilled barrel. Named as a POSITIVE
# set, not as "not through-hole": a pad type nobody has seen before then falls
# outside it and blocks, instead of being waved through as surface-mount.
# ``connect`` is preserved as its own token by ``semantic_pad_type`` while
# ``normalize_pad_type`` folds it to smd, so testing == "smd" would refuse a
# board over a pad that is electrically surface-mount.
_SURFACE_PAD_TYPES = frozenset(("smd", "connect"))


def _zone_connect_value(marker: UnsupportedFeature) -> Union[int, None]:
    """The marker's integer value, or ``None`` when it cannot be read.

    ``None`` is NOT a synonym for "absent": a token whose value the tokenizer
    produced but that is not an integer is a zone-connect instruction nobody can
    interpret, and the caller blocks on it. ``bool`` is excluded deliberately —
    it is an ``int`` subclass and ``True`` would read as thermal."""
    raw = marker.value
    if isinstance(raw, bool):
        return None
    if isinstance(raw, int):
        return raw
    if isinstance(raw, str):
        try:
            return int(raw.strip())
        except ValueError:
            return None
    return None


def _zone_connect_blocks(marker: UnsupportedFeature, context: object) -> bool:
    """Whether a ``zone_connect`` marker corrupts the copper v1 would fill.

    VALUE FIRST. v1's fill connects same-net copper SOLID and nothing else --
    the pour simply does not carve around it (see ``zone_fill`` module docs) --
    so ``2`` is not an approximation of the author's instruction, it IS the
    author's instruction, and it never blocks however the board is shaped. ``3``
    means thermal-on-through-hole, solid-on-SMD, so on an SMD pad it is ``2`` by
    another spelling.

    Everything else asks for geometry v1 does not fill: ``0`` asks for isolation
    and gets a solid tie (star grounds and deliberate thermal breaks silently
    disappear), ``1`` asks for spokes and gets a solid tie (the cold-joint case
    the zone-level ``_refuse_thermal`` already refuses rather than mis-fills).
    Warning about those at pad scope while refusing them at zone scope would
    make v1's strictness depend on where the author typed the same intent.

    RELEVANCE SECOND, and only as a way to say yes-but-it-cannot-matter-here: a
    connect style is inert unless some pour could actually reach this pad.
    """
    value = _zone_connect_value(marker)
    if value == _ZONE_CONNECT_SOLID:
        return False
    pad = context.pad if isinstance(context, AdjudicationContext) else None
    if (value == _ZONE_CONNECT_THT_THERMAL
            and pad is not None and pad.pad_type in _SURFACE_PAD_TYPES):
        return False
    return _pour_could_touch(context)


def _pour_could_touch(context: object) -> bool:
    """Whether some copper pour could reach the pad this marker sits on.

    Relevance is: a non-keepout zone, on the pad's net, on a copper layer the
    pad occupies. Any of the three failing means the connect style has nothing
    to act on -- the pour must carve clearance around foreign or unnetted copper
    regardless of what its connect style says.

    Deliberately tolerant about the container (the policy is handed whatever the
    caller had) and deliberately STRICT about the fail direction: a context this
    cannot interrogate answers TRUE. Its predecessor answered False for a
    non-dict, which made an unreadable board the safest kind to compile.

    ``kind`` follows Go's Zone.Kind (board.go:416): "" means copper_pour, so a
    zone authored before the field existed still counts, and an unrecognised
    kind counts too -- ``_zone_kind`` reports it as invalid_zone_kind
    separately, and guessing "harmless" about a zone we cannot classify is the
    fail-open direction.
    """
    if isinstance(context, AdjudicationContext):
        board, ref, pad = context.board, context.ref, context.pad
    elif isinstance(context, dict):
        # A caller that supplied no pad identity gets the board-wide answer.
        board, ref, pad = context, "", None
    else:
        return True
    if not isinstance(board, dict):
        return True
    zones = board.get("zones")
    if not isinstance(zones, list):
        # Truthy non-list: unreadable rather than empty, so it counts.
        return bool(zones)
    if pad is None or not ref:
        # No pad, or a pad whose component is unknown: neither can be scoped, so
        # they get the board-wide answer. Reading an unknown ref as "this pad is
        # on no net" would make a missing ref the cheapest way past the check.
        return _declares_copper_pour(zones)
    nets = board.get("nets")
    if nets is not None and not isinstance(nets, list):
        # Un-interrogable, exactly like a non-list `zones` above. Iterating a
        # string walks its characters and a dict walks its keys, so every pad
        # would read as netless and every marker would pass — the same
        # fail-open direction, on the other container.
        return True
    net = _pad_net_name(board, ref, pad.number)
    if net is None:
        return False
    for zone in zones:
        if not isinstance(zone, dict):
            return True
        if zone.get("kind") == ZoneKind.KEEPOUT.value:
            continue
        if zone.get("net") != net:
            continue
        if _pad_occupies(pad, zone.get("layer")):
            return True
    return False


def _declares_copper_pour(zones: list) -> bool:
    """Whether *zones* holds at least one non-keepout zone. The board-wide
    relevance test, used when no pad identity is available."""
    for zone in zones:
        if not isinstance(zone, dict):
            return True
        if zone.get("kind") != ZoneKind.KEEPOUT.value:
            return True
    return False


def _pad_net_name(board: dict, ref: str, number: str) -> Union[str, None]:
    """The net a pad belongs to, read off the board's own net pin references.

    Shares :func:`_split_pin_ref` with the net builder so the "REF.NUMBER" split
    has one definition; ``drc._pin_net_map`` is the same walk on the consumer
    side of the IR."""
    if not ref:
        return None
    for net in board.get("nets") or ():
        if not isinstance(net, dict):
            continue
        name = net.get("name")
        if not isinstance(name, str) or not name:
            continue
        for token in net.get("pins") or ():
            parsed = _split_pin_ref(token)
            if parsed is not None and parsed[0] == ref and parsed[1] == str(number):
                return name
    return None


def _pad_occupies(pad: PadDefinition, zone_layer: object) -> bool:
    """Whether *pad* has copper on the zone's layer.

    Mirrors ``drc._Pad.occupies``: a pad declaring no layers, or declaring the
    stack-spanning ``*.Cu``, answers True for every layer. Permissive is the
    fail-CLOSED direction here -- an undeclared pad that might sit under the
    pour must not talk its way out of the check. A zone layer that is empty or
    does not name copper answers True for the same reason: ``_build_zones``
    refuses it separately, but this must not assume that gate ran first, and
    folding an unrecognised name would compare it unequal to everything and so
    report the pour unreachable -- fail-open by arithmetic."""
    if not isinstance(zone_layer, str) or not is_copper(zone_layer):
        return True
    declared = [layer.id for layer in pad.layers]
    if not declared or any(layer == "*.Cu" for layer in declared):
        return True
    target = kicad_to_canon(zone_layer)
    return any(is_copper(layer) and kicad_to_canon(layer) == target
               for layer in declared)


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


def _declared_layers(board: dict) -> list[str]:
    """The board's declared copper stack, in stack order; absence == the
    canonical two-layer default (NOTHING is synthesized into the board dict --
    the Go codec's byte-identity guarantee depends on an absent ``layers`` key
    staying absent).

    Shape is NOT re-validated here: the shared boundary
    (``validate_board_v2``/``_check_layers``) ran before this and failed the
    compile on any malformed declaration -- wrong container type, unknown or
    duplicate names, missing top/bottom, out-of-order inners -- so a list that
    reaches this function is a well-formed ``[top, in1..in(N-2), bottom]``
    stack.  Whether the SELECTED manufacturer profile can fabricate a stack
    this deep is a separate, fail-closed gate in ``_build_design_rules``.
    """
    layers = board.get("layers")
    if layers is None:
        return [_TOP_ID, _BOTTOM_ID]
    return [str(x) for x in layers]


def _build_outline(board: dict, board_id: str, schema_version: int,
                   diags: _Diagnostics) -> Union[RectOutline, ProfileOutline, None]:
    """The board rim: a plain :class:`RectOutline`, or — when the board authors
    interior ``cutouts`` — a :class:`ProfileOutline` whose outer contour is that
    same rectangle and whose cutouts are validated closed rings.

    Cutout rules, every one fail-closed under ``invalid_cutout_outline``:
      * the ring parses by the ONE shared convention (:func:`_zone_contour`) —
        >= 3 distinct corners, no zero-length segment, explicit closure folded;
      * every vertex lies STRICTLY inside the outer rectangle. A vertex on or
        past the rim would make the "cutout" a NOTCH — a reshape of the outer
        contour itself, which v1 does not model (the rect IS the rim contract
        every consumer measures against);
      * cutout bounding boxes are pairwise DISJOINT. Conservative on purpose:
        two overlapping cutouts describe one opening the emitters would draw as
        two crossing contours — a shape no board house can interpret. An
        author with a complex opening merges it into one contour."""
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
    rect = RectOutline(origin=origin, width_mm=float(width), height_mm=float(height))

    raw_cutouts = board.get("cutouts")
    if not isinstance(raw_cutouts, list) or not raw_cutouts:
        # Presence-not-truthiness for the CONTAINER is enforced by the shared
        # validate boundary (`cutouts: {}` is invalid_board_structure there);
        # an absent or explicitly-empty list declares nothing.
        return rect

    ox, oy = rect.origin
    ox2, oy2 = ox + rect.width_mm, oy + rect.height_mm
    cutouts: list[ResolvedCutout] = []
    ok = True
    for ordinal, raw in enumerate(_dict_items(board, "cutouts", "cutout", diags)):
        cut_ref = SourceRef(EntityKind.CUTOUT, f"cutout:{ordinal}")
        if not _validate_child_id("cutout", raw, cut_ref, schema_version, diags):
            ok = False
            continue
        contour = _zone_contour(raw.get("outline"), ordinal, cut_ref, diags,
                                code="invalid_cutout_outline", label="cutout")
        if contour is None:
            ok = False
            continue
        outside = [seg.a for seg in contour.segments
                   if not (ox < seg.a[0] < ox2 and oy < seg.a[1] < oy2)]
        if outside:
            diags.error("invalid_cutout_outline",
                        f"cutout {ordinal}: vertex {outside[0]} lies on or outside the "
                        f"board outline; a cutout must be strictly interior (an edge "
                        f"notch reshapes the rim, which v1 does not model)", cut_ref)
            ok = False
            continue
        # THE RING MUST BE A SIMPLE POLYGON, refused at the doorway.
        #
        # Two review rounds shaped this gate. Cold review CPN1-S1 caught the
        # pentagram: consistent winding, so it passes a consecutive-cross
        # convexity test, and its core reads as "outside" to an even-odd point
        # test — it would have shipped a self-crossing Edge.Cuts contour with
        # DRC blind to copper in the star's core. Codex review 1086 finding 1
        # then caught that the checker I reached for (zone_fill's
        # _refuse_self_intersecting) recognises PROPER CROSSINGS ONLY, so a
        # vertex touching a non-adjacent edge, a collinear overlap, and a
        # retraced edge all still compiled — and a retraced ring made
        # route_bridge's miter inflation under-reserve the interior.
        #
        # So this calls the STRICT predicate (zone_fill.refuse_non_simple_ring),
        # not the crossing-only one. A cutout has no fill step and nothing
        # downstream re-measures its offset, so the compile IS its only doorway.
        ring_nm = [(_zone_to_nm(seg.a[0]), _zone_to_nm(seg.a[1]))
                   for seg in contour.segments]
        try:
            _zone_refuse_non_simple_ring(f"cutout:{ordinal}", ring_nm,
                                         label="cutout outline")
        except ZoneFillError as exc:
            diags.error("invalid_cutout_outline", f"cutout {ordinal}: {exc}", cut_ref)
            ok = False
            continue
        area2 = sum(ring_nm[i][0] * ring_nm[(i + 1) % len(ring_nm)][1]
                    - ring_nm[(i + 1) % len(ring_nm)][0] * ring_nm[i][1]
                    for i in range(len(ring_nm)))
        if area2 == 0:
            # A collinear sliver ((2,2) (8,2) (5,2)) encloses nothing: emitted
            # it would be a zero-width out-and-back slit on Edge.Cuts, and the
            # router's degenerate "inflation" of it reserves only one side —
            # a routed board that then fails its own GC5 (review finding 3).
            diags.error("invalid_cutout_outline",
                        f"cutout {ordinal}: outline encloses zero area", cut_ref)
            ok = False
            continue
        cutouts.append(ResolvedCutout(
            id=_resolve_child_id("cutout", board_id, raw, (ordinal,), schema_version),
            contour=contour))

    seen_ids: dict[str, int] = {}
    for index, cut in enumerate(cutouts):
        if cut.id in seen_ids:
            # v2 boards are defended by the shared minted-id gate; this catches
            # the v1 case of two cutouts AUTHORING the same id (both derive to
            # the same board-namespaced id — silently aliased identity).
            diags.error("invalid_cutout_outline",
                        f"cutouts {seen_ids[cut.id]} and {index} resolve to the same "
                        f"id {cut.id}; authored cutout ids must be unique", _board_ref())
            ok = False
        seen_ids[cut.id] = index
    for i in range(len(cutouts)):
        for j in range(i + 1, len(cutouts)):
            if _contour_aabbs_intersect(cutouts[i].contour, cutouts[j].contour):
                diags.error("invalid_cutout_outline",
                            f"cutouts {cutouts[i].id} and {cutouts[j].id} have "
                            f"intersecting bounding boxes. v1 models cutouts with "
                            f"DISJOINT bounding boxes only: genuinely overlapping "
                            f"contours must be merged into one, and a disjoint "
                            f"diagonal pair whose boxes overlap is refused "
                            f"conservatively (the fail-closed direction)",
                            _board_ref())
                ok = False
    if not ok:
        return None
    outer = Contour(segments=(
        LineGeometry((ox, oy), (ox2, oy)),
        LineGeometry((ox2, oy), (ox2, oy2)),
        LineGeometry((ox2, oy2), (ox, oy2)),
        LineGeometry((ox, oy2), (ox, oy)),
    ))
    return ProfileOutline(outer=outer, cutouts=tuple(cutouts))


def _contour_aabbs_intersect(a: Contour, b: Contour) -> bool:
    def box(c: Contour) -> tuple[float, float, float, float]:
        xs = [seg.a[0] for seg in c.segments]
        ys = [seg.a[1] for seg in c.segments]
        return min(xs), min(ys), max(xs), max(ys)
    ax0, ay0, ax1, ay1 = box(a)
    bx0, by0, bx1, by1 = box(b)
    return not (ax1 < bx0 or bx1 < ax0 or ay1 < by0 or by1 < ay0)


def _build_layer_stack(declared_layers: list[str]) -> LayerStack:
    """The board's resolved copper stack, built from ITS OWN declaration
    (epoch GA-1; before that this walked the global two-entry ``STACK_INDEX``
    and never consulted the board).  Declared order IS stack order -- the
    boundary validator already enforced ``[top, in1..in(N-2), bottom]`` -- and
    ``canon_to_kicad`` is the FUNCTION-level mapping, so inner layers alias
    correctly without widening the module tables the through-via span rule
    derives from."""
    copper = tuple(
        ResolvedLayer(id=canon, kicad_alias=canon_to_kicad(canon), stack_index=index)
        for index, canon in enumerate(declared_layers)
    )
    # Physical stack: DECLARE the layer order but assert NO thickness/material the
    # source did not supply (K2 review 621 MF5; tagged-union seam allows None).
    entries: list[StackupEntry] = []
    order = 0
    for position, layer in enumerate(copper):
        entries.append(StackupEntry(id=layer.kicad_alias, order=order,
                                    kind=StackupKind.COPPER, copper_layer_id=layer.id))
        order += 1
        if position < len(copper) - 1:
            entries.append(StackupEntry(id=f"dielectric-{position}", order=order,
                                        kind=StackupKind.DIELECTRIC))
            order += 1
    technical = tuple(Layer.from_id(layer_id) for layer_id in _TECHNICAL_LAYER_IDS)
    return LayerStack(copper=copper, stackup=PhysicalStackup(entries=tuple(entries)),
                      technical=technical)


# Keys a ``design_rules.net_classes`` entry may author.  ``name`` is the class's
# identity (its IR ``id`` is DERIVED from it, exactly as a net's is derived from
# the net name) and ``members`` names the nets that belong to it; the two
# ``min_``-prefixed keys are the only RULES an authored class may state — see
# ``_reject_unread_net_class_fields``.
_AUTHORED_NET_CLASS_KEYS = frozenset({
    "name", "members", "min_trace_width_mm", "min_clearance_mm",
})

# ``NetClass`` fields the IR CARRIES but no consumer READS.  Authoring them would
# ship a rule that lies (see ``_reject_unread_net_class_fields``).
_UNREAD_NET_CLASS_FIELDS: tuple[str, ...] = (
    "trace_width_mm", "via_diameter_mm", "via_drill_mm",
)


def _declared_but_not_modeled(what: str, requested_outputs: tuple[str, ...],
                              diags: _Diagnostics) -> bool:
    """The compiler's ONE policy for a design rule the source DECLARES but the v1
    IR does not carry to any consumer.  Returns True when the loss is FATAL.

    Fatal when ``rules`` is a requested output (the IR feeds DRC/routing), a
    warning when compiling CAM-only without rules (review 625.4).

    THE WARNING BRANCH IS UNREACHABLE IN PRODUCTION, and deliberately kept
    anyway.  ``compile_board``'s ``requested_outputs`` defaults to
    ``V1_FAB_OUTPUTS`` and its only other production value is
    ``V1_ROUTING_OUTPUTS`` (``methods`` passes one or the other and nothing
    else); those alias ``fab_capability``'s ``FABRICATION_CRITICAL_OUTPUTS`` and
    ``ROUTING_CRITICAL_OUTPUTS``, and ``rules`` is in BOTH.  A caller reaching
    the warning has hand-built an output set, which today only tests do.  The
    branch stays because the policy is about the OUTPUT SET, not about who calls
    it: a future CAM-only profile must degrade to a warning rather than inherit
    a fatality argued from DRC/routing that would not apply to it.
    """
    if "rules" in requested_outputs:
        diags.error("unsupported_design_rule",
                    f"{what}; dropping them is fatal because 'rules' was requested "
                    f"(DRC/routing)", _board_ref())
        return True
    diags.warning("unsupported_design_rule",
                  f"{what}; ignored for this CAM-only ('rules' not requested) compile",
                  _board_ref())
    return False


def _reject_unread_net_class_fields(entry: dict, name: str,
                                    requested_outputs: tuple[str, ...],
                                    diags: _Diagnostics) -> None:
    """Refuse a class authoring a ``NetClass`` field NO CONSUMER READS.

    ``methods._net_class_overrides`` and ``drc_geometric._net_class_minima`` —
    the only two readers of a net class anywhere — read
    ``min_trace_width_mm`` and ``min_clearance_mm``, and nothing else.  The
    remaining ``NetClass`` geometry fields (``_UNREAD_NET_CLASS_FIELDS``) are
    NOMINAL sizes mirroring ``RoutingDefaults``; accepting them would put a
    number in the IR that changes no routed copper and no DRC floor, i.e. a rule
    that LIES about being in force.  So they are refused rather than carried.

    Routed through the SAME ``_declared_but_not_modeled`` policy the diff-pair
    rules use — this is the identical situation (a declared rule the v1 IR does
    not carry to a consumer), so it gets the identical fatality argument and the
    identical ``unsupported_design_rule`` code, not a second policy.

    A DECLARATION IS A NON-NULL VALUE, not a present key: ``via_diameter_mm:``
    with no value states no rule, carries no number, and is IGNORED.  That is
    the same ``is not None`` test the diff-pair check above applies, and the two
    must agree because they are one policy with two callers.  It is also the
    line the rationale itself draws — what is refused is a VALUE that would
    silently fail to take effect; an empty key asserts nothing that could then
    be a lie.  This is deliberately NOT the presence-not-truthiness rule
    ``agent_router.board._refuse_authored_net_classes`` applies to the
    ``net_classes`` key itself: that guard asks "is the FEATURE present", where
    an empty mapping is a malformed declaration with no value slot at all, while
    this asks "did the author state THIS rule's value".  Different questions,
    different granularity; see that function's docstring for its own argument.

    RETURNS NOTHING, unlike the diff-pair call site which acts on
    ``_declared_but_not_modeled``'s fatal/non-fatal answer by returning ``None``
    and abandoning the whole ``design_rules`` build.  There is no equivalent
    decision to hand back here: an ERROR already fails the compile at the
    ``diags.has_error`` gate, so abandoning the entry would change no outcome
    while losing this entry's remaining diagnostics.

    WHAT THAT DOES AND DOES NOT BUY, stated precisely because an earlier draft
    of this docstring overclaimed it.  Walking on keeps ``_build_net_classes``
    reporting every defect it can find ACROSS THE CLASS LIST in one pass — the
    same way ``_build_nets_index`` keeps walking after a ``duplicate_net``.  It
    buys NOTHING at the level of the board: ``_build_net_classes`` is the LAST
    thing ``_build_design_rules`` does, behind four ``return None`` paths
    (absent ``design_rules``, a non-positive scalar, ``via_drill_mm`` not
    smaller than ``via_diameter_mm``, and a fatal diff-pair rule).  A board with
    BOTH a rules-block defect and a broken class therefore emits the rules-block
    diagnostic ALONE, and every class diagnostic waits for a later compile.
    That ordering is deliberate and matches the diff-pair precedent — a rules
    block that cannot be built has no classes to speak of — and giving net
    classes a whole-board one-pass path that no other rule enjoys would be a
    worse inconsistency than the deferral.
    """
    declared = [field for field in _UNREAD_NET_CLASS_FIELDS if entry.get(field) is not None]
    if not declared:
        return
    _declared_but_not_modeled(
        f"net class {name!r} declares {'/'.join(declared)}, which the v1 IR carries "
        f"but no consumer reads (only min_trace_width_mm/min_clearance_mm are read, "
        f"by routing and geometric DRC)",
        requested_outputs, diags)


def _net_class_minimum(entry: dict, field: str, name: str, diags: _Diagnostics) -> Union[float, None]:
    """Admit one authored class minimum, or diagnose it.  Returns None both for
    "the class says nothing about this dimension" (a legal, load-bearing state —
    both consumers fall through to the board floor for THAT dimension) and for a
    value that was rejected; the caller tracks rejection through ``diags``.

    ADMITTED THROUGH ``_is_positive_number``, the SAME predicate the board-level
    ``design_rules`` numbers above go through — deliberately STRICTER than the
    IR's own ``NetClass`` validation, which is ``resolved_board._nonnegative``
    (finite and ``>= 0``) and would therefore accept a ``0``.  A board-level
    ``clearance_mm: 0`` is refused here; a net class is a design rule authored in
    the same block by the same person, so it cannot be admitted on looser terms
    than the blanket rule it overrides.  The IR is NOT tightened to match: it
    stays the permissive floor for hand-built boards, and the authoring layer is
    where authored input is judged.
    """
    value = entry.get(field)
    if value is None:
        return None
    if not _is_positive_number(value):
        diags.error("invalid_net_class",
                    f"net class {name!r}: {field} must be a positive number; got {value!r}",
                    _board_ref())
        return None
    return float(value)


def _build_net_classes(rules: dict, board_id: str, requested_outputs: tuple[str, ...],
                       diags: _Diagnostics) -> tuple[tuple[NetClass, ...], dict[str, str]]:
    """Parse ``design_rules.net_classes`` into (classes, net name -> class id).

    MEMBERSHIP IS AUTHORED ON THE CLASS, not on the net.  A class both states its
    rules and names its member nets, all inside the board's ``design_rules``
    block, because the panel's net model (``pcb/ui/model/pcb_net.gd``) serialises
    a FIXED key set — a per-net class key would be destroyed by any UI
    load/save round trip, while ``pcb_data.gd`` round-trips ``design_rules``
    wholesale.  The IR stays PER-NET (``ResolvedNet.net_class_id``); this
    function returns the INVERSION the compiler applies in ``_finalize_nets``.

    Class IDS ARE DERIVED FROM THE NAME through ``derive_id``, board-namespaced,
    exactly as a net id is derived from its net name — one identity rule for both
    named entities, so the same class name in two boards yields distinct ids.

    Two membership defects fail CLOSED here, mirroring the net path's own
    diagnostics rather than being silently absorbed:
      * two classes claiming the SAME net -> ``duplicate_net_class_membership``
        (the shape ``duplicate_pin_ownership`` uses for a pin claimed twice);
      * a duplicate class NAME -> ``duplicate_net_class`` (the shape
        ``duplicate_net`` uses).
    The third — a member naming a net that does not exist — cannot be decided
    here because the net index is not built yet; ``compile_board`` raises
    ``net_class_unknown_member`` for it once both halves exist.

    An UNREFERENCED class (no ``members``, or a class no net ends up carrying) is
    LEGAL and constrains nothing.  That is the consumers' existing rule — both
    read REFERENCED classes only — and this does not change it.
    """
    raw = rules.get("net_classes")
    if raw is None:
        return (), {}
    if not isinstance(raw, list):
        diags.error("invalid_net_class",
                    f"design_rules.net_classes must be a list, got {type(raw).__name__}",
                    _board_ref())
        return (), {}

    classes: list[NetClass] = []
    class_id_by_net: dict[str, str] = {}
    owner_class: dict[str, str] = {}
    seen_names: set[str] = set()
    for index, entry in enumerate(raw):
        if not isinstance(entry, dict):
            diags.error("invalid_net_class",
                        f"design_rules.net_classes[{index}] is not a mapping ({entry!r})",
                        _board_ref())
            continue
        name = entry.get("name")
        if not isinstance(name, str) or not name:
            diags.error("invalid_net_class",
                        f"design_rules.net_classes[{index}] has no name: {entry!r}",
                        _board_ref())
            continue
        if name in seen_names:
            diags.error("duplicate_net_class",
                        f"net class {name!r} declared more than once", _board_ref())
            continue
        seen_names.add(name)

        # An authored key the surface does not accept is REFUSED, never ignored.
        # `id` lands here on purpose: identity is derived from the name, so an
        # authored `id` would be silently overruled — the exact silent-substitution
        # this whole surface exists to avoid.
        unknown = sorted(set(entry) - _AUTHORED_NET_CLASS_KEYS - set(_UNREAD_NET_CLASS_FIELDS))
        if unknown:
            diags.error("invalid_net_class",
                        f"net class {name!r} declares unknown key(s) {'/'.join(unknown)}; "
                        f"an authored class accepts only "
                        f"{'/'.join(sorted(_AUTHORED_NET_CLASS_KEYS))} "
                        f"(its id is derived from its name)", _board_ref())
            continue
        _reject_unread_net_class_fields(entry, name, requested_outputs, diags)

        min_width = _net_class_minimum(entry, "min_trace_width_mm", name, diags)
        min_clearance = _net_class_minimum(entry, "min_clearance_mm", name, diags)

        class_id = derive_id("net-class", board_id, name)
        classes.append(NetClass(id=class_id, name=name,
                                min_trace_width_mm=min_width,
                                min_clearance_mm=min_clearance))

        members = entry.get("members")
        if members is not None and not isinstance(members, list):
            diags.error("invalid_net_class",
                        f"net class {name!r}: members must be a list, got "
                        f"{type(members).__name__}", _board_ref())
            continue
        for member in members or []:
            if not isinstance(member, str) or not member:
                diags.error("invalid_net_class",
                            f"net class {name!r}: member {member!r} is not a net name",
                            _board_ref())
                continue
            prior = owner_class.get(member)
            if prior is not None and prior != name:
                diags.error("duplicate_net_class_membership",
                            f"net {member!r} is claimed by both net class {prior!r} and "
                            f"{name!r}; a net belongs to at most one class",
                            _board_ref())
                continue
            owner_class[member] = name
            class_id_by_net[member] = class_id
    return tuple(classes), class_id_by_net


def _resolve_board_rule_profile(rules: dict, profile_root: Union[str, Path, None],
                                library_layers: Union[Iterable, None],
                                diags: _Diagnostics) -> Union[LoadedRuleProfile, None]:
    """Resolve the board's SELECTED manufacturing-floor profile.

    ``design_rules.rule_profile`` names a profile id; an absent/``None`` key
    selects :data:`DEFAULT_RULE_PROFILE_ID` (v1), through the IDENTICAL
    fail-closed loader path any other id takes -- there is no separate
    "use the hardcoded floor" branch left to drift from the shipped file.

    FAIL CLOSED (K21, docket 019f762004dc): an unknown, unreadable, or
    malformed profile -- including one missing any REQUIRED
    ``ManufacturingConstraints`` field -- is a compile ERROR. Never a silent
    fall back to v1 when a DIFFERENT profile was requested and could not be
    loaded; that would let a board's digest/verdict claim to be one board
    house while actually enforcing another's numbers."""
    profile_id = rules.get("rule_profile")
    if profile_id is None:
        profile_id = DEFAULT_RULE_PROFILE_ID
    if not isinstance(profile_id, str) or not profile_id:
        diags.error("invalid_design_rule",
                    f"design_rules.rule_profile must be a non-empty string naming a "
                    f"pinned board-house profile; got {profile_id!r}", _board_ref())
        return None
    try:
        # THE SAME ordered library chain footprints resolve through (S9, owner
        # ruling): a user/project layer may ship its own board-house profile,
        # and a defect in the layer that HAS the id is refused rather than
        # served from the seed's profile of the same name.
        return load_rule_profile(profile_id, library_root=profile_root,
                                 layers=library_layers)
    except RuleProfileError as exc:
        diags.error("unknown_rule_profile", str(exc), _board_ref())
        return None


def _build_design_rules(board: dict, board_id: str, requested_outputs: tuple[str, ...],
                        profile_root: Union[str, Path, None],
                        library_layers: Union[Iterable, None],
                        diags: _Diagnostics,
                        copper_layer_count: int = 2,
                        ) -> Union[tuple[ResolvedDesignRules, dict[str, str]], None]:
    """Build the board's :class:`ResolvedDesignRules` and the net-name -> class-id
    inversion its authored net classes imply (see :func:`_build_net_classes`).

    ``copper_layer_count`` is the depth of the board's declared stack; the
    SELECTED profile must declare a ``max_copper_layers`` capability at least
    that deep or the compile fails closed (epoch GA-1) -- a board house that
    has not published an N-layer service must not be handed an N-layer board.
    """
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
    # Route the loss through the compiler's ONE declared-but-not-modeled policy
    # (review 625.4) — the same one an authored net class's unread fields use.
    if any(rules.get(k) is not None for k in ("diff_pair_gap_mm", "diff_pair_width_mm")):
        if _declared_but_not_modeled(
                "diff_pair_gap_mm/diff_pair_width_mm are declared but not modeled in the v1 IR",
                requested_outputs, diags):
            return None
    profile = _resolve_board_rule_profile(rules, profile_root, library_layers, diags)
    if profile is None:
        return None
    # Stack-depth capability gate (epoch GA-1). Fires AFTER the profile
    # resolves so the message can name the selected profile, and reuses the
    # ``unsupported_layer_stack`` code the old exactly-two refusal carried --
    # consumers keyed on the code keep working; what changed is WHY a stack is
    # refused (fab capability, no longer a hardwired pair).
    if copper_layer_count > profile.max_copper_layers:
        diags.error(
            "unsupported_layer_stack",
            f"board declares {copper_layer_count} copper layers but rule profile "
            f"{profile.ref.id!r} fabricates at most {profile.max_copper_layers} "
            f"(a profile that declares no capabilities.max_copper_layers is a "
            f"2-layer profile); select a profile whose board house publishes a "
            f"{copper_layer_count}-layer service",
            _board_ref())
        return None
    net_classes, class_id_by_net = _build_net_classes(rules, board_id, requested_outputs, diags)
    angles = _allowed_trace_angles(rules, diags)
    if angles is None:
        return None
    minima = _zone_fill_minima(rules, profile.floor, float(via_diameter), diags)
    if minima is None:
        return None
    zone_min_thickness, zone_min_island_area = minima
    return ResolvedDesignRules(
        allowed_trace_angles_deg=angles,
        zone_min_thickness_mm=zone_min_thickness,
        zone_min_island_area_mm2=zone_min_island_area,
        defaults=RoutingDefaults(
            trace_width_mm=float(trace_width),
            via_diameter_mm=float(via_diameter),
            via_drill_mm=float(via_drill),
        ),
        minimums=_floor_with_clearance(profile.floor, float(clearance)),
        allowed_via_kinds=(ViaKind.THROUGH,),
        net_classes=net_classes,
        rule_profile=profile.ref,
    ), class_id_by_net


def _allowed_trace_angles(rules: dict, diags: _Diagnostics):
    """``design_rules.allowed_trace_angles_deg``, validated. ``()`` when absent
    (the default: no direction constraint), ``None`` when malformed.

    BOARD state, not profile state. A rule profile records what a board HOUSE
    publishes and no house requires orthogonal routing; a board's routing style
    is its author's choice. Putting it in a profile would assert a fab
    capability that does not exist.

    Malformed is an ERROR rather than an ignored key. A board that asks for a
    direction constraint and silently gets none is the fail-open direction, and
    it is invisible: every trace passes a check that never ran."""
    raw = rules.get("allowed_trace_angles_deg")
    if raw is None:
        return ()
    if not isinstance(raw, list) or not raw:
        diags.error("bad_trace_angles",
                    "design_rules.allowed_trace_angles_deg must be a non-empty "
                    f"list of directions in degrees, got {raw!r}", _board_ref())
        return None
    angles: list[float] = []
    for value in raw:
        if isinstance(value, bool) or not isinstance(value, (int, float)) \
                or not math.isfinite(value):
            diags.error("bad_trace_angles",
                        "design_rules.allowed_trace_angles_deg entries must be "
                        f"finite numbers, got {value!r}", _board_ref())
            return None
        # A direction and its reverse are one constraint, so everything folds
        # into [0, 180) — otherwise 0 and 180 would be two different rules for
        # the same horizontal run.
        folded = float(value) % 180.0
        if folded not in angles:
            angles.append(folded)
    return tuple(angles)


def _zone_fill_minima(rules: dict, profile_floor: ManufacturingConstraints,
                      via_diameter_mm: float, diags: _Diagnostics):
    """The EFFECTIVE ``(zone_min_thickness_mm, zone_min_island_area_mm2)`` pair.

    Authored via ``design_rules.zone_min_thickness_mm`` /
    ``design_rules.zone_min_island_area_mm2``; ``None`` for the pair when either
    is malformed, which fails the compile closed. An unstated value takes the
    default from :func:`zone_fill.default_zone_minima` — the one place both
    defaults are derived, so the IR and a filler running without an IR value
    cannot disagree about what "scrap" means.

    A board may state ``0`` for the island area, which means "cull no island by
    size" — every orphan region is then refused. A zero THICKNESS is refused
    instead: a pour with no minimum width is not a policy, it is a missing one.
    """
    default_thickness, default_island = default_zone_minima(
        profile_floor.min_trace_width_mm, via_diameter_mm)
    thickness = rules.get("zone_min_thickness_mm")
    if thickness is None:
        thickness = default_thickness
    elif not _is_positive_number(thickness):
        diags.error("invalid_design_rule",
                    "design_rules.zone_min_thickness_mm must be a positive "
                    f"number of millimetres; got {thickness!r}", _board_ref())
        return None
    island_area = rules.get("zone_min_island_area_mm2")
    if island_area is None:
        island_area = default_island
    elif isinstance(island_area, bool) or not isinstance(island_area, (int, float)) \
            or not math.isfinite(island_area) or island_area < 0:
        diags.error("invalid_design_rule",
                    "design_rules.zone_min_island_area_mm2 must be a "
                    f"non-negative number of mm^2; got {island_area!r}",
                    _board_ref())
        return None
    return float(thickness), float(island_area)


def _floor_with_clearance(profile_floor: ManufacturingConstraints,
                          board_clearance_mm: float) -> ManufacturingConstraints:
    """The SELECTED profile's floor; the board's authored clearance may only
    TIGHTEN min_clearance above THAT floor, never weaken it (K2 review 621
    MF5). ``max()`` is the whole safety property here — a board may only ask
    for MORE clearance than its chosen board house requires, never less."""
    return replace(profile_floor,
                   min_clearance_mm=max(profile_floor.min_clearance_mm, board_clearance_mm))


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

    def judge(markers, pad: Union[PadDefinition, None] = None) -> None:
        nonlocal blocked
        context = AdjudicationContext(board=board, ref=ref, pad=pad)
        for marker in markers:
            if policy.is_blocking(marker, context, requested_outputs):
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
        judge(pad.unsupported, pad)

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
    elif pad.drill is not None and pad.drill.size[0] != pad.drill.size[1]:
        # CONTRADICTORY DRILL DATA — the shape token says ROUND but the two
        # size axes disagree, and every consumer then believes something
        # different (Codex review 1090 finding 1, verified end to end):
        #   * DRC infers "oblong" from the unequal axes and measures the MINOR
        #     axis against the slot floor — so a (1.6, 0.6) drill can read
        #     CLEAN against a 0.5mm plated-slot minimum;
        #   * both fab emitters reduce the drill to a SCALAR by taking the
        #     first axis (pad_source._from_resolved: `dr.get("x")`), so they
        #     fabricate a 1.6mm ROUND hole and silently discard the 0.6.
        # Checked geometry and fabricated geometry diverge, silently, which is
        # the one thing this compiler exists to prevent. v1 emits round holes
        # only, so the honest answer is to refuse the contradiction rather than
        # pick an axis: an author who means a slot must say so with a slot
        # shape (and that is a capability v1 does not yet emit).
        fail("unsupported_hole",
             f"drill declares the round shape {pad.drill.shape!r} but its axes "
             f"differ ({pad.drill.size[0]} x {pad.drill.size[1]}) — v1 fabricates "
             f"round holes only and would emit the first axis while DRC measured "
             f"the second; refusing rather than silently picking one")

    has_copper = any(layer.role is LayerRole.COPPER for layer in pad.layers)
    has_paste = any(layer.role is LayerRole.PASTE for layer in pad.layers)
    if (has_copper or has_paste) and pad.size is None:
        feature = "copper pad" if has_copper else "paste aperture"
        fail("missing_pad_size", f"{feature} has no declared size; v1 refuses to invent one")

    # Pad-type legality: the three seed pad types have distinct, non-overlapping
    # geometry contracts.  A definition that violates its own type is malformed.
    if pad.pad_type == "smd":
        # KiCad also spells a stencil-only aperture as an unnumbered ``smd`` pad
        # whose sole participation is F.Paste/B.Paste.  It is not an electrical
        # land and must not be rejected merely because it has no copper.  Keep the
        # accepted non-copper subset deliberately narrow: a pad on some OTHER
        # technical layer still has no modeled meaning and fails closed.
        non_copper_roles = {layer.role for layer in pad.layers
                            if layer.role is not LayerRole.COPPER}
        if not has_copper and (not has_paste or non_copper_roles != {LayerRole.PASTE}):
            fail("illegal_pad_definition",
                 "SMD pad declares neither copper nor a paste-only aperture")
        if pad.drill is not None:
            fail("illegal_pad_definition", "SMD pad must not carry a drill")
    elif pad.pad_type in ("thru_hole", "np_thru_hole"):
        if pad.drill is None:
            fail("illegal_pad_definition", f"{pad.pad_type} pad has no drill")
        # A PLATED through-hole is an electrical pad: it must declare copper, the
        # same way an SMD pad must (019f91a6cff1). Without this, a footprint whose
        # thru_hole pad declares no copper layers slips past capability with
        # has_copper=False — which also silences the `missing_pad_size` guard
        # above, since that one only fires for copper pads — and only fails much
        # later, when pad_source.require_th_annulus raises PadGeometryError on a
        # pad whose size/annulus resolved to None. Nothing was ever invented, so
        # this is an EARLIER, better-named gate, not a correctness fix.
        #
        # THE ASYMMETRY IS DELIBERATE: np_thru_hole is excluded. A NON-plated hole
        # is a mechanical feature with legitimately no copper, so guarding it here
        # would reject any mounting hole authored without copper layers. Measured
        # caveat: widening this to np_thru_hole would NOT be caught by the seed
        # library — its one NPTH pad (MountingHole_3.2mm_M3) declares *.Cu anyway.
        # The exemption is pinned by the synthetic-pad tests in
        # tests/test_compile_board.py instead.
        if pad.pad_type == "thru_hole" and not has_copper:
            fail("illegal_pad_definition",
                 "plated thru-hole declares no copper layer")
    return ok


# Non-copper wildcard expansions are GLOBAL (mask/paste exist only on the two
# outer surfaces regardless of copper depth).  ``*.Cu`` is deliberately NOT in
# this table since epoch GA-1: it expands to the board's OWN resolved copper
# stack (see ``_resolved_pad_layers``) — a THT pad's ``*.Cu`` on a 4-layer
# board carries annuli on the inner layers too, which is what the drill
# physically produces.  Before GA-1 the ``*.Cu`` entry here was the D9b
# out-of-scope hole: a hardwired (F.Cu, B.Cu) pair that would have silently
# truncated inner participation the moment deeper stacks compiled.
_WILDCARD_EXPANSION = {
    "*.Mask": ("F.Mask", "B.Mask"),
    "*.Paste": ("F.Paste", "B.Paste"),
}


def _resolved_pad_layers(pad: PadDefinition, transform: PlacementTransform, ref: str,
                         diags: _Diagnostics,
                         copper_aliases_ordered: tuple[str, ...],
                         ) -> Union[tuple[Layer, ...], None]:
    """Expand the footprint pad's DECLARED layer selectors to explicit resolved
    layers — ``*.Cu`` to the board's own copper stack, ``*.Mask``/``*.Paste``
    to both outer surfaces, explicit F.*/B.* mirrored by placement side —
    carrying exactly the participation the library declared (K2 review
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
            expansion = (copper_aliases_ordered if layer.id == "*.Cu"
                         else _WILDCARD_EXPANSION.get(layer.id))
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

    # Epoch GA repair round (Codex whole-epoch review finding 3): a pad with
    # NO DRILL has no barrel — its copper is a FACE land, and both fab
    # emitters are face-based for drill-less copper (gerber flashes SMD lands
    # on top/bottom only; kicad emits the component side's layer). Inner
    # participation on such a pad would compile, route and DRC as inner
    # copper and then be SILENTLY FABRICATED on an outer face — the exact
    # K4 silent-relocation this module refuses everywhere else, one seam
    # deeper. Refuse by name. Through pads (drill present) are untouched:
    # their barrel genuinely reaches every declared plane (GA-3 flashes the
    # annulus on each copper layer).
    if pad.drill is None:
        # INNER-NESS IS A NAMING-CONTRACT QUESTION, asked in the canonical
        # namespace (Codex re-review finding 1: the first cut compared raw
        # ids against ("F.Cu", "B.Cu"), so a pad whose resolved layer id is
        # CANONICAL "top"/"bottom" — every hand-authored pin board — was
        # misclassified as inner and refused). is_copper gates first (both
        # spellings; keeps mask/paste out of the fold so kicad_to_canon
        # never warns here), then the id folds canonical and only a genuine
        # in<k> counts.
        inner = [layer.id for layer in resolved
                 if is_copper(layer.id)
                 and inner_layer_index(kicad_to_canon(layer.id)) > 0]
        if inner:
            diags.error(
                "inner_smd_pad",
                f"component {ref!r} pad {pad.number!r}: a drill-less pad "
                f"declares copper on inner layer(s) {inner}; its land can "
                f"only be fabricated on an outer face, so this would be "
                f"silently relocated copper — refused (through pads with a "
                f"drill reach inner planes; face pads do not)",
                SourceRef(EntityKind.PAD, pad.source_id, f"component {ref}"))
            return None
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
    copper_aliases_ordered: tuple[str, ...],
) -> Union[tuple[tuple[PlacedPad, ...], tuple[PlacedGraphic, ...]], None]:
    transform = PlacementTransform(
        position=(float(comp["x_mm"]), float(comp["y_mm"])),
        rotation_deg=float(comp.get("rotation_deg") or 0.0),
        side=side,
    )
    copper_aliases = frozenset(copper_aliases_ordered)
    unemitted: set[str] = set()
    placed_pads: list[PlacedPad] = []
    for pad in definition.pads:
        layers = _resolved_pad_layers(pad, transform, ref, diags, copper_aliases_ordered)
        if layers is None:
            return None
        for layer in layers:
            if _is_emitted_layer(layer.id, copper_aliases):
                continue
            if layer.role is LayerRole.COPPER:
                # Copper the emitter cannot write is not documentation-only: the
                # gerbers would generate clean and the copper simply would not be
                # there (K4 discards clause). Scoped to COPPER -- fab/paste/silk
                # on an unemitted layer stays a warning below.
                diags.error(
                    "unemitted_copper_layer",
                    f"component {ref!r} pad {pad.number!r}: declares copper on "
                    f"layer {layer.id!r}, which the emitter does not write -- "
                    f"the copper would be silently absent from fabrication",
                    SourceRef(EntityKind.PAD, pad.source_id, f"component {ref}"))
            else:
                unemitted.add(layer.id)
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
        # The ONE resolution site for the roundrect corner-ratio default
        # (019fa73a4f88): an unauthored ratio is filled in HERE, conditioned on
        # shape == roundrect, so the fallback lives on the IR pad instead of being
        # re-substituted at each emitter. Gating on shape keeps
        # ``corner_rratio is None AND shape == roundrect`` unreachable by
        # construction downstream — a rect/circle/oval pad still carries None,
        # and an AUTHORED 0.0 (0.0 is not None) is left exactly as authored, so
        # the authored-zero-degenerates-to-Rectangle distinction survives.
        corner_rratio = pad.corner_rratio
        if pad.shape == "roundrect" and corner_rratio is None:
            corner_rratio = DEFAULT_ROUNDRECT_RRATIO
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
            corner_rratio=corner_rratio,
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
        if not _is_emitted_layer(placed_layer.id, copper_aliases):
            if placed_layer.role is LayerRole.COPPER:
                diags.error(
                    "unemitted_copper_layer",
                    f"component {ref!r} graphic {graphic.source_id!r}: declares "
                    f"copper on layer {placed_layer.id!r}, which the emitter "
                    f"does not write -- the copper would be silently absent "
                    f"from fabrication",
                    SourceRef(EntityKind.GRAPHIC, graphic.source_id, f"component {ref}"))
            else:
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

    # Validate the FOLDED FINAL state, not each field in isolation: an UNPLATED
    # (np_thru_hole) pad carries NO copper — so ANY copper-bearing dimension the
    # override AUTHORS (the annulus ring OR the pad land width/height) would be
    # silently discarded at emission. Fail CLOSED on the COMPLETE set, not just
    # annulus (finding 019f8fe77068: a final-state invariant, not a per-field check
    # — {pad_width_mm, pad_height_mm, plated:false} was slipping through).
    if pad_type == "np_thru_hole":
        discarded = [k for k in ("annulus_diameter_mm", "pad_width_mm", "pad_height_mm")
                     if override.get(k) is not None]
        if discarded:
            diags.error("override_copper_dims_on_unplated_pad",
                        f"component {ref!r} pin {pad.number!r}: override authors "
                        f"{', '.join(discarded)} but the pad is unplated (np_thru_hole) — "
                        f"an unplated hole carries no copper land/ring; drop the copper "
                        f"dimension(s) or the unplating", pad_ref)

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
                    diags: _Diagnostics, *,
                    code: str = "trace_bad_points",
                    label: str = "trace") -> Union[list[tuple[float, float]], None]:
    """Strict point extraction: any malformed point FAILS the whole entity (never
    filtered-then-stitched — K2 review 621 MF1).

    ``code``/``label`` let a second point-bearing entity reuse this ONE parsing
    convention under its own diagnostic vocabulary (a zone's ``outline``, which
    reports ``invalid_zone_outline`` — the code Go's ``validateZones`` already
    uses).  The defaults reproduce the trace wording verbatim, so the trace path is
    unchanged."""
    if not isinstance(raw_points, list):
        diags.error(code, f"{label} {ordinal}: points must be a list", ref)
        return None
    points: list[tuple[float, float]] = []
    for index, item in enumerate(raw_points):
        if isinstance(item, dict):
            x, y = item.get("x_mm"), item.get("y_mm")
        elif isinstance(item, (list, tuple)) and len(item) == 2:
            x, y = item[0], item[1]
        else:
            # A 3-tuple point etc. is malformed — do not silently drop the extra.
            diags.error(code, f"{label} {ordinal}: point[{index}] is malformed ({item!r})", ref)
            return None
        if not (_is_number(x) and _is_number(y)):
            diags.error(code,
                        f"{label} {ordinal}: point[{index}] has non-finite coordinates", ref)
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
        # NAMING gate only (epoch GA testex fix): is_copper knows the canonical
        # inner names; the old CANON_TO_KICAD membership test was the outer
        # PAIR, which refused every inner-layer trace on a declaring board.
        # STACK membership is the boundary's job (board_validate
        # trace_unknown_layer, mirrored in Go) and off-stack copper that
        # bypasses the boundary still fails closed downstream (the emitters'
        # stray-layer guard, the router's routable-set check).
        if layer is None or not is_copper(layer.id):
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
            diags.error("trace_degenerate",
                        f"{_trace_label(raw, ordinal)}: needs at least two "
                        f"points, got {len(points)}", trace_ref)
            continue
        trace_id = _resolve_child_id("trace", board_id, raw, (net_id, ordinal), schema_version)
        segments: list[ResolvedTraceSegment] = []
        degenerate = False
        for seg_ordinal, (a, b) in enumerate(zip(points, points[1:])):
            if a == b:
                diags.error("trace_degenerate",
                            f"{_trace_label(raw, ordinal)}: zero-length segment "
                            f"at {a}", trace_ref)
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


def _trace_label(raw: dict, ordinal: int) -> str:
    """``trace 3 'trace_7'`` when the board authored an id, else ``trace 3``.

    A degenerate trace makes the whole board uncompilable, so the diagnostic is
    the only thing the author has to work from — and the ordinal alone is not a
    handle. Every repair verb (delete_traces, import_trace_geometry) takes the
    AUTHORED id, so a board stranded this way could be diagnosed but not fixed
    from the message it produced."""
    authored = raw.get("id")
    if isinstance(authored, str) and authored:
        return f"trace {ordinal} {authored!r}"
    return f"trace {ordinal}"


def _board_library_lock(board: dict) -> dict:
    """The board's ``library_lock`` block as ``{ref: entry}``, or empty.

    TOLERANT BY DESIGN, in the one direction that is safe: a malformed or absent
    block yields NO pins, so the board compiles exactly as an unlocked board
    would. The alternative — refusing to compile because the lock is unreadable
    — would turn a bad edit to an optional provenance block into a board that
    cannot be built, which is a worse failure than the one it guards against.
    Individual entries are validated where they are USED, so a single malformed
    entry cannot disarm the pins beside it.
    """
    raw = board.get("library_lock")
    if not isinstance(raw, dict):
        return {}
    return {str(k): v for k, v in raw.items() if isinstance(v, dict)}


def _build_vias(board: dict, board_id: str, net_id_by_name: dict[str, str],
                schema_version: int, diags: _Diagnostics) -> tuple[ResolvedVia, ...]:
    vias: list[ResolvedVia] = []
    for ordinal, raw in enumerate(_dict_items(board, "vias", "via", diags)):
        net_name = raw.get("net")
        net_id = net_id_by_name.get(net_name) if isinstance(net_name, str) and net_name else None
        via_ref = SourceRef(EntityKind.VIA, f"via:{ordinal}", f"net {net_name}")
        if not _validate_child_id("via", raw, via_ref, schema_version, diags):
            continue
        # Empty/absent is an intentionally unassigned standalone via. A NAMED
        # net must resolve: preserving the former error for typos is what keeps
        # this relaxation narrow.
        if net_id is None and net_name not in (None, ""):
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
        # sides (the v1 symmetric case). An ABSENT or explicit-NULL `tented` is the
        # DEFAULT (tented) — matching Go, whose Via.Tented is a *bool that decodes
        # null to nil=unset and whose YAML probe explicitly allows `!!null` (finding
        # 019f9123abef: the two languages must not disagree on null). Only a non-null
        # non-bool (a string/number) fails closed.
        raw_tented = raw.get("tented")
        if raw_tented is None:
            raw_tented = True
        elif not isinstance(raw_tented, bool):
            diags.error("via_bad_tented",
                        f"via {ordinal}: tented must be a boolean, got {raw_tented!r}", via_ref)
            continue
        vias.append(ResolvedVia(
            id=_resolve_child_id("via", board_id, raw, (net_id or "unassigned", ordinal), schema_version),
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
                if raw_plated is None:
                    # An explicit `plated: null` is the DEFAULT (unplated), matching Go
                    # (Hole.Plated is a plain bool that decodes null to its false
                    # zero-value) + the pth/npth alias branch + the YAML `!!null`
                    # allowance (finding 019f9123abef). Only a non-null non-bool errors.
                    raw_plated = default_plated
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
                if explicit is not None and not isinstance(explicit, bool):
                    # A MALFORMED (non-bool) plated fails closed here too — Go's typed
                    # `bool` rejects it and mounting_holes above rejects it, so silently
                    # ignoring it on the pth/npth aliases was a Go/Python codec
                    # divergence (finding 019f8b7fb07e). The alias KEY still wins on the
                    # VALUE (below); only a wrong TYPE is the error.
                    diags.error("hole_bad_plating",
                                f"{key}[{ordinal}]: plated must be a boolean, got {explicit!r}",
                                hole_ref)
                    continue
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


# ---------------------------------------------------------------------------
# Zones (docket 019f9a73e5a2). Authored outline first; final fill after assembly.
# ---------------------------------------------------------------------------
#
# This builder preserves ``authored_outline`` and initially sets ``fill=None``;
# the distinction from ``()`` matters because None means uncomputed while an
# empty tuple is a computed-empty pour. Once the complete ResolvedBoard exists,
# ``fill_board_zones`` computes every copper pour or fails the compile. Output
# consumers therefore receive computed fill; keepouts retain None because they
# are prohibitions rather than copper.
#
# CODE VOCABULARY. ``invalid_zone_outline`` / ``zone_unknown_net`` /
# ``zone_unknown_layer`` are Go's own strings (internal/board/validate.go
# ``validateZones``), reused verbatim as its note asks rather than invented anew.
# ``zone_bad_clearance`` / ``zone_bad_thermal`` have NO Go counterpart because Go
# validates neither field; they follow this module's ``<entity>_bad_<field>``
# family (cf. ``trace_bad_width``, ``via_bad_size``).


def _zone_contour(raw_outline, ordinal: int, ref: SourceRef,
                  diags: _Diagnostics, *,
                  code: str = "invalid_zone_outline",
                  label: str = "zone") -> Union[Contour, None]:
    """The authored zone boundary as a closed :class:`Contour`, or ``None`` on error.

    ``code``/``label`` follow the :func:`_extract_points` convention: a second
    ring-bearing entity (a CUTOUT, which reports ``invalid_cutout_outline`` —
    Go's own code string) reuses this ONE ring-parsing convention under its own
    diagnostic vocabulary. The defaults reproduce the zone wording verbatim.

    The Go contract carries an ``outline`` as an ordered ``[]Point`` ring; the IR
    carries a ``Contour`` of segments whose closure is IMPLICIT (each segment's end
    is the next one's start, and the last wraps to the first — ``Contour``'s own
    invariant).  So point *i* becomes one ``LineGeometry`` to point *i+1*, wrapping
    at the end: the same convention the only other ``Contour`` construction in this
    repo uses (tests/test_drc_geometric.py builds its triangle that way).  Arc
    segments are representable in a ``Contour`` but not in Go's ``[]Point``, so an
    authored zone boundary is all-line today.

    A ring the author closed EXPLICITLY (last point repeating the first) describes
    the same polygon as the implicit form, so the redundant final point is dropped
    rather than turned into a zero-length segment.  Both notations must land on the
    identical ``Contour``."""
    points = _extract_points(raw_outline, ordinal, ref, diags,
                             code=code, label=label)
    if points is None:
        return None
    if len(points) >= 2 and points[0] == points[-1]:
        points = points[:-1]
    if len(points) < 3:
        # Go's validateZones applies the same >= 3 floor to the RAW ring. This is
        # stricter by exactly the explicit-closure case: Go accepts [A, B, A]
        # (three raw points), which is a two-corner degenerate polygon once the
        # duplicate closer is dropped. Stricter in the fail-closed direction.
        diags.error(code,
                    f"{label} {ordinal}: outline describes {len(points)} distinct corner(s); "
                    f"a polygon needs at least 3", ref)
        return None
    count = len(points)
    for index in range(count):
        if points[index] == points[(index + 1) % count]:
            # Would be a zero-length segment, which LineGeometry rejects.
            diags.error(code,
                        f"{label} {ordinal}: outline has a repeated point at "
                        f"{points[index]} (index {index}); a boundary cannot contain a "
                        f"zero-length segment", ref)
            return None
    try:
        return Contour(segments=tuple(
            LineGeometry(points[index], points[(index + 1) % count])
            for index in range(count)
        ))
    except (ValueError, TypeError) as exc:
        # The IR is the authority on its own invariants; surface a rejection as a
        # structured diagnostic rather than an unhandled traceback out of compile.
        diags.error(code,
                    f"{label} {ordinal}: outline rejected by the IR: {exc}", ref)
        return None


def _zone_clearance(raw: dict, ordinal: int, ref: SourceRef,
                    diags: _Diagnostics) -> tuple[Union[float, None], bool]:
    """``(clearance_mm, ok)`` for a zone.

    Go documents ``Zone.ClearanceMM`` as "Zero/omitted defers to the board's
    blanket design_rules.clearance_mm", so zero and absent are the SAME thing by
    contract and both map to ``None`` (defer) — not to a 0.0 mm clearance rule the
    author never stated.  A present negative or non-numeric value is an error, not
    a silent defer."""
    value = raw.get("clearance_mm")
    if value is None:
        return None, True
    if not _is_number(value):
        diags.error("zone_bad_clearance",
                    f"zone {ordinal}: clearance_mm must be a finite number, got {value!r}", ref)
        return None, False
    if value < 0:
        diags.error("zone_bad_clearance",
                    f"zone {ordinal}: clearance_mm {value} cannot be negative", ref)
        return None, False
    if value == 0:
        return None, True
    return float(value), True


def _zone_thermal(raw: dict, ordinal: int, ref: SourceRef, diags: _Diagnostics
                  ) -> tuple[Union[ConnectMode, None], Union[ThermalSettings, None], bool]:
    """``(connect_mode, thermal, ok)`` for a zone.

    Go's ``Zone`` has no connect-mode field at all, only ``ThermalGapMM`` /
    ``ThermalBridgeWidthMM``, both documented as "Zero/omitted defers to the
    compiler's own default whenever zone filling is implemented".  So:

    * NEITHER authored -> ``(None, None)``.  ``connect_mode`` is optional in the IR
      and ``None`` states nothing; picking SOLID or THERMAL here would assert a
      pad-connection strategy the author never wrote, and no consumer reads it yet
      to prefer one.
    * BOTH authored -> ``ConnectMode.THERMAL`` plus the settings.  The mode is
      ENTAILED, not chosen: relief geometry is only meaningful under thermal
      relief, and ``ResolvedZone`` rejects ``thermal`` set with any other mode.
    * EXACTLY ONE authored -> error.  ``ThermalSettings`` requires both fields
      (``bridge_width_mm`` strictly positive), so the half that is missing would
      have to be invented; and dropping the half that WAS authored would silently
      discard a fabrication-relevant dimension.  Fail closed instead.

    Zero is read as unauthored on BOTH fields, per the Go doc above, which also
    makes this stable across a Go round-trip (both fields are ``omitempty``, so a
    zero would not survive re-encoding anyway).  The cost is that a deliberate
    ``thermal_gap_mm: 0`` — a same-net pad merging flush into the pour — is not
    expressible in today's contract; that is a limit of the schema, not a value
    invented here."""
    raw_gap = raw.get("thermal_gap_mm")
    raw_bridge = raw.get("thermal_bridge_width_mm")
    for field, value in (("thermal_gap_mm", raw_gap), ("thermal_bridge_width_mm", raw_bridge)):
        if value is not None and not _is_number(value):
            diags.error("zone_bad_thermal",
                        f"zone {ordinal}: {field} must be a finite number, got {value!r}", ref)
            return None, None, False
        if value is not None and value < 0:
            diags.error("zone_bad_thermal",
                        f"zone {ordinal}: {field} {value} cannot be negative", ref)
            return None, None, False
    gap_authored = raw_gap is not None and raw_gap != 0
    bridge_authored = raw_bridge is not None and raw_bridge != 0
    if not gap_authored and not bridge_authored:
        return None, None, True
    if gap_authored != bridge_authored:
        diags.error("zone_bad_thermal",
                    f"zone {ordinal}: thermal relief needs BOTH thermal_gap_mm and a "
                    f"positive thermal_bridge_width_mm (got {raw_gap!r} / {raw_bridge!r}); "
                    f"the missing half would have to be invented", ref)
        return None, None, False
    try:
        settings = ThermalSettings(gap_mm=float(raw_gap), bridge_width_mm=float(raw_bridge))
    except (ValueError, TypeError) as exc:
        diags.error("zone_bad_thermal",
                    f"zone {ordinal}: thermal settings rejected by the IR: {exc}", ref)
        return None, None, False
    return ConnectMode.THERMAL, settings, True


def _zone_kind(raw: dict, ordinal: int, ref: SourceRef,
               diags: _Diagnostics) -> Union[ZoneKind, None]:
    """The AUTHORED zone kind, or ``None`` after recording ``invalid_zone_kind``.

    Go's ``Zone.Kind`` (board.go:416) accepts exactly ``""``, ``"copper_pour"``
    and ``"keepout"``, canonical lowercase, and documents empty as
    ``copper_pour`` so every board authored before the field existed keeps its
    meaning.  Mirrored here rather than delegated: ``board_validate._check_zones``
    is the shared-boundary gate and normally rejects a bad kind first, but
    ``compile_board`` is reachable on its own and a compiler that TRUSTS an
    upstream check is a compiler that fails open the day the upstream check is
    bypassed.  Case-sensitive, exactly as Go: the UI normalises case
    (``PCBData.zone_kind()``), so a stray ``"Keepout"`` here is a typo worth
    reporting rather than a spelling to silently accept."""
    value = raw.get("kind")
    if value is None or value == "":
        return ZoneKind.COPPER_POUR
    if not isinstance(value, str):
        diags.error("invalid_zone_kind",
                    f"zone {ordinal}: kind must be a string, got {value!r}", ref)
        return None
    try:
        return ZoneKind(value)
    except ValueError:
        diags.error("invalid_zone_kind",
                    f"zone {ordinal}: kind {value!r} is not "
                    f"{ZoneKind.COPPER_POUR.value!r} or {ZoneKind.KEEPOUT.value!r}", ref)
        return None


def _pour_only(kind: ZoneKind, design_rules: Union[ResolvedDesignRules, None],
               field: str) -> Union[float, None]:
    """A board-level zone-fill minimum, for a COPPER_POUR only.

    A keepout carries neither: it prohibits copper rather than being copper, and
    the IR refuses a keepout that claims a copper minimum."""
    if kind is not ZoneKind.COPPER_POUR or design_rules is None:
        return None
    return getattr(design_rules, field)


def _build_zones(board: dict, board_id: str, net_id_by_name: dict[str, str],
                 schema_version: int, diags: _Diagnostics,
                 design_rules: Union[ResolvedDesignRules, None] = None,
                 ) -> tuple[ResolvedZone, ...]:
    """Compile authored zones into pre-fill :class:`ResolvedZone` entries.

    Every zone gets ``fill=None`` explicitly. The completed board is passed to
    ``fill_board_zones`` at the end of compilation, so no successful compile
    returns an uncomputed copper pour.

    ``design_rules`` carries the board's zone-fill minima onto each POUR, so the
    filler grades a zone by numbers the zone holds. It is ``None`` only when the
    design-rules build already failed, and the compile is over by then."""
    zones: list[ResolvedZone] = []
    for ordinal, raw in enumerate(_dict_items(board, "zones", "zone", diags)):
        net_name = raw.get("net")
        zone_ref = SourceRef(EntityKind.ZONE, f"zone:{ordinal}", f"net {net_name}")
        if not _validate_child_id("zone", raw, zone_ref, schema_version, diags):
            continue
        kind = _zone_kind(raw, ordinal, zone_ref, diags)
        if kind is None:
            continue
        net_id = net_id_by_name.get(net_name) if isinstance(net_name, str) else None
        if kind is ZoneKind.KEEPOUT:
            # A keepout is a PROHIBITION on copper, not copper, so it needs no net
            # (owner ruling 019fb5ad6d20, mirrored by Go validate.go:288-293 and
            # board_validate._check_zones). A NAMED net still has to be declared —
            # a net-scoped keepout that names a net the board does not have is a
            # typo, not a broader prohibition.
            if net_name is not None and net_name != "" and net_id is None:
                diags.error("zone_unknown_net",
                            f"zone {ordinal}: keepout net {net_name!r} is not a declared net",
                            zone_ref)
                continue
        elif net_id is None:
            # A pour IS copper, and copper belongs to a net; a netless pour is not
            # underspecified-but-fine, it is a region of copper with no potential.
            diags.error("zone_unknown_net",
                        f"zone {ordinal}: net {net_name!r} is not a declared net", zone_ref)
            continue
        layer_id = str(raw.get("layer") or "")
        layer = Layer.from_id(layer_id) if layer_id else None
        # NAMING gate via is_copper (epoch GA testex fix — the outer-pair
        # membership test refused every inner-layer zone on a declaring
        # board); same division of labor as the trace gate above.
        if layer is None or not is_copper(layer.id):
            diags.error("zone_unknown_layer",
                        f"zone {ordinal}: layer {layer_id!r} is not a v1 copper layer", zone_ref)
            continue
        outline = _zone_contour(raw.get("outline"), ordinal, zone_ref, diags)
        if outline is None:
            continue
        clearance, clearance_ok = _zone_clearance(raw, ordinal, zone_ref, diags)
        connect_mode, thermal, thermal_ok = _zone_thermal(raw, ordinal, zone_ref, diags)
        if not (clearance_ok and thermal_ok):
            continue
        try:
            zone = ResolvedZone(
                id=_resolve_child_id("zone", board_id, raw, (net_id, ordinal), schema_version),
                net_id=net_id,
                layer=layer,
                # THE AUTHORED kind, read off the board (defect fix, C6 stage 1).
                # This used to be hardcoded to COPPER_POUR with a comment claiming
                # COPPER_POUR was "the only kind Go's Zone can express". That was
                # true when it was written and STALE by the time it was read: Go's
                # Zone.Kind landed 2026-07-30 (owner ruling 019fb5ad6d20) and both
                # validators accept `kind: keepout`. The hardcode therefore made
                # VALIDATE AND COMPILE DISAGREE — a netless keepout passed
                # board_validate and was then rejected here as zone_unknown_net,
                # because the pour net rule was applied to something that is not a
                # pour. The separate top-level `keepouts:` key is a DIFFERENT thing
                # and stays refused (:2120-2125); do not conflate them.
                kind=kind,
                authored_outline=outline,
                # HONEST INDETERMINACY, stated rather than defaulted: no fill has
                # been computed. NOT `()`, which would claim a computed-and-empty
                # pour — a false clean.
                fill=None,
                clearance_mm=clearance,
                # THE BOARD'S ZONE-FILL MINIMA, carried onto the pour the filler
                # grades by them (`None` on a keepout, which has no copper). Both
                # are authored in `design_rules` or derived there from a number
                # the author wrote — see _zone_fill_minima — so the filler never
                # culls copper by a rule nobody stated.
                min_thickness_mm=_pour_only(kind, design_rules,
                                            "zone_min_thickness_mm"),
                min_island_area_mm2=_pour_only(kind, design_rules,
                                               "zone_min_island_area_mm2"),
                # Fill priority stays unasserted: it only means something once two
                # pours overlap, which needs a filler to resolve, and there is no
                # Go counterpart to read one from.
                priority=None,
                connect_mode=connect_mode,
                thermal=thermal,
            )
        except (ValueError, TypeError) as exc:
            # ResolvedZone enforces several invariants of its own (copper layer,
            # thermal/connect-mode agreement, non-negative clearance). Its rejection
            # becomes a structured error here rather than a traceback out of compile.
            diags.error("invalid_zone", f"zone {ordinal}: rejected by the IR: {exc}", zone_ref)
            continue
        # NO `zone_unfilled` WARNING IS EMITTED HERE ANY MORE. It used to be, and
        # it was correct while nothing computed a fill: every zone left this
        # function with fill=None and the warning said so. Now a pour is filled
        # by the zone-fill pass at the end of compile (or the compile FAILS), so
        # a warning emitted here would fire on every pour and then be false by
        # the time the caller read it — the worst kind of diagnostic. The
        # per-pour outcome is reported after the fill instead (`zone_filled`).
        zones.append(zone)
    return tuple(zones)


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
    """Version-dispatched id precondition for a trace/via/hole/zone.

    v2 REQUIRES a persisted minted id and fails closed without one — a v2 board
    that reaches an identity-dependent compile without minted ids has skipped the
    migration, and routing/DRC against unstable identity is the exact hazard this
    gate exists to prevent.  v1 keeps the permissive authored-or-ordinal bridge.

    NOTE: for v2 this mintedness check is REDUNDANT behind the shared gate
    (validate_board_v2, run first in compile_board — it already fails closed on
    unminted/duplicate trace/via/hole/zone ids across all four domains).  It is kept
    as cheap per-entity defense-in-depth; the v1 branch (_authored_id_ok) is the part
    that is actually load-bearing here."""
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


def compile_board(
    board: dict,
    *,
    policy: Union[DefaultCapabilityPolicy, None] = None,
    requested_outputs: tuple[str, ...] = V1_FAB_OUTPUTS,
    library_root: Union[str, Path, None] = None,
    lockfile: Union[str, Path, None] = None,
    library_layers: Union[Iterable, None] = None,
    wip_root: Union[str, Path, None] = None,
    profile_root: Union[str, Path, None] = None,
) -> ResolutionResult:
    """Compile a canonical board dict into a :class:`ResolutionResult`.

    Returns :class:`ResolutionSuccess` (board + non-fatal diagnostics) or
    :class:`ResolutionFailure` (ERROR diagnostics, no board).  Never raises for
    an INPUT defect — only genuine programmer errors propagate.

    ``profile_root`` overrides where ``design_rules.rule_profile`` is resolved
    from (default :data:`manufacturer_profile.DEFAULT_PROFILE_ROOT`, the
    shipped ``pcb/library/profiles/`` directory) -- mirrors ``library_root``/
    ``lockfile`` and exists mainly so tests can exercise the fail-closed
    profile-loading paths without touching shipped library data.

    ``library_layers`` (S9) is the ORDERED LIBRARY CHAIN both footprints and
    manufacturer profiles resolve through -- a sequence of
    :class:`~pcb_worker.footprints.LibraryLayer` (or the equivalent mappings the
    Go side will hand across the bridge). Omitted, the chain is the shipped seed
    layer alone and this compile is byte-identical to a pre-S9 one; the shipped
    seed is always the chain's base, so a configured layer can only SHADOW a
    seed part, never remove one. The supplying layer of each component's
    footprint is recorded on its :class:`Provenance`.

    ``wip_root`` (B7) additionally tops the chain with the BLESSED WIP view
    (:func:`pcb_worker.bless.live_library_chain`): only entries carrying an
    approved bless record resolve; staged-but-unreviewed content is
    structurally absent. The wip name remains REFUSED inside
    ``library_layers`` itself — WIP enters a compile through this parameter
    or not at all."""
    if policy is None:
        policy = DefaultCapabilityPolicy()
    diags = _Diagnostics()

    if not isinstance(board, dict):
        diags.error("invalid_board", "board must be a mapping", _board_ref())
        return ResolutionFailure(diagnostics=diags.tuple())

    # Shared-boundary gate FIRST (findings 019f88bac172 / 019f8b7fb07e): the
    # production compiler runs the SAME structural + persistent-id validator the Go
    # codec and the committed vectors use (validate_board_v2), so a duplicate
    # persistent id or a null / identity-less list item fails CLOSED here with its
    # EXPLICIT shared code — not later as a generic ``board_invariant`` raised by
    # ResolvedBoard construction (previously the only thing that caught duplicate
    # ids). This is the ONE schema-validation authority: it checks schema-version
    # validity, the v2 minted board id, and top-level container shape + pin-override
    # field types — so the compiler does NOT re-check those below (finding
    # 019f88bac172, Codex @ aa2ef0f: one authority, no lazy circular import).
    seen_codes: set[str] = set()
    for code in validate_board_v2(board):
        if code in seen_codes:
            continue
        seen_codes.add(code)
        diags.error(code, _BOUNDARY_MESSAGES.get(code, code), _board_ref())
    if seen_codes:
        return ResolutionFailure(diagnostics=diags.tuple())

    # The gate guaranteed version is int 1 or 2 (unsupported_schema_version fails
    # closed there, review 630), so read it without re-validating: v1 keeps the
    # ordinal-id bridge, v2 requires persisted minted ids (item 019f802ca3af Round C).
    version = board.get("version")

    # MATERIALIZE the caller's layer configuration ONCE (Codex 1160 P2): the
    # chain load below and the profile resolution later both walk it, and a
    # generator consumed by the first walk would hand the second an EMPTY
    # config — footprints from the user layer, profile silently from the seed,
    # violating the same-chain ruling with mutually inconsistent provenance.
    if library_layers is not None:
        library_layers = tuple(library_layers)

    # Load the sha-verified lock of every LAYER ONCE; an unreadable/malformed
    # lock is fatal — provenance and footprint resolution both depend on it
    # (review 621 MF4), and a layer whose lock will not load must not be quietly
    # demoted to "absent" (that is the anti-shadowing rule one level up: a
    # broken override must refuse the board, not fall through to the seed).
    # The DEFAULT chain is the seed layer alone, so ``chain[0].lock`` here IS
    # the ``lock`` this function loaded before layering existed (S9).
    # ``wip_root`` (B7) tops the chain with the BLESSED WIP view — built by
    # bless.live_library_chain, never a raw one; profiles below keep resolving
    # through ``library_layers`` alone (normalize_library_layers refuses the
    # wip name), because WIP stages footprints, not manufacturing floors.
    try:
        chain = bless.live_library_chain(
            wip_root=wip_root, layers=library_layers,
            library_root=library_root, lockfile=lockfile)
        if any(not isinstance(loaded.lock, dict) for loaded in chain):
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
        # The gate guaranteed a minted v2 board id (unminted_persistent_id fails
        # closed there), so trust it — one authority, no re-check.
        board_id = board.get("id")
    else:
        board_id = derive_id("board", str(name or "<unnamed>"), str(version))

    # Reject recognized-but-unsupported board features by PRESENCE, not
    # truthiness — an empty-mapping ``board_graphics: {}`` is still a declaration we
    # must refuse rather than treat as absent (review 623 R2).  An explicitly empty
    # list declares nothing and is allowed.
    #
    # ``zones`` LEFT THIS LIST in epoch 4 (docket 019f9a73e5a2). _build_zones
    # creates pre-fill IR entries and the final compile pass computes copper
    # pours. Gerber/KiCad emit them, geometric DRC checks them, and routing
    # rasterises authored keepouts. The separate legacy top-level ``keepouts``
    # feature stays refused. A malformed ``zones`` CONTAINER is still rejected
    # by validate_board_v2 (``invalid_board_structure``).
    #
    # ``cutouts`` LEFT this list in epoch CPN1 (docket 019fe2faf76e), the round
    # that fixed the fail-open its refusal existed to hold back (019fbd30f7):
    # ``ir_projection.outline_frame`` no longer silently degrades a
    # ``ProfileOutline`` to its bounding box (it frames a rect outer faithfully
    # and RAISES on any other), both fab emitters draw cutout contours on
    # Edge.Cuts, geometric DRC measures copper-to-edge against cutout edges,
    # routing reserves them as all-layer obstacles, and zone fill carves pours
    # away from them by the same copper-to-edge rule.  An authored cutout now
    # compiles into ``ProfileOutline.cutouts`` via :func:`_build_outline`, which
    # owns the fail-closed geometry rules (strictly-interior, disjoint).
    # ``cutouts: {}`` is still refused — by the shared validate boundary
    # (``invalid_board_structure``), same presence-not-truthiness rule as ever.
    #board_graphics LEFT THIS LIST in the round that gave
    # board-level artwork a real owner (:mod:`board_graphics`). It compiles into
    # ResolvedBoard.board_graphics, both fab emitters draw it, and geometric DRC
    # projects it as silk — the same four-way landing zones and cutouts each had
    # to make before their own refusals were lifted. A malformed CONTAINER is
    # still refused, by validate_board_v2 (``invalid_board_structure``) and again
    # by the builder.
    for unsupported_key in ("keepouts",):
        value = board.get(unsupported_key)
        if value is None or (isinstance(value, list) and not value):
            continue
        diags.error("unsupported_board_feature",
                    f"board declares {unsupported_key!r} ({value!r}), which v1 cannot fabricate",
                    _board_ref())

    declared_layers = _declared_layers(board)
    outline = _build_outline(board, board_id, version, diags)
    layer_stack = _build_layer_stack(declared_layers)
    # The stack's KiCad aliases, in stack order: the ``*.Cu`` expansion and the
    # per-board emitted-copper accept-set (see ``_is_emitted_layer``).
    copper_aliases_ordered = tuple(layer.kicad_alias for layer in layer_stack.copper)
    built_rules = _build_design_rules(board, board_id, requested_outputs, profile_root,
                                     library_layers, diags,
                                     copper_layer_count=len(declared_layers))
    design_rules, class_id_by_net = built_rules if built_rules is not None else (None, {})

    net_id_by_name, _net_index, pin_net, net_descriptors = _build_nets_index(board, board_id, diags)

    # THE OTHER HALF OF THE MEMBERSHIP INVERSION. A class names its members
    # (_build_net_classes), but only here do both halves exist, so only here can a
    # member naming a net the board never declares be caught. It fails CLOSED: a
    # silently-ignored member is a class the author believes is in force on a net
    # that is in fact routed and checked at the board's blanket floors.
    #
    # ROOT CAUSE ONCE, not once per member (019fa2c513): when the net index
    # is EMPTY — the board declares no nets, or _build_nets_index failed and
    # already said so in its own diagnostics — every declared member would
    # cascade into net_class_unknown_member, telling the author their class
    # members are wrong when the defect is one level up. One error names the
    # real problem. A board whose index BUILT (even partially) keeps the
    # per-member errors: those are the genuine unknowns this pass exists for,
    # and suppressing them there would be the opposite defect.
    if class_id_by_net and not net_id_by_name:
        diags.error(
            "net_class_without_nets",
            f"net class(es) name {len(class_id_by_net)} member net(s) but the "
            f"board's net index is empty (no nets declared, or the nets block "
            f"failed to build — see its own diagnostics); per-member "
            f"unknown-member errors are withheld because the members are not "
            f"the defect",
            _board_ref())
    else:
        for net_name in sorted(class_id_by_net):
            if net_name not in net_id_by_name:
                diags.error("net_class_unknown_member",
                            f"net class member {net_name!r} names no net declared by this board",
                            _board_ref())

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

        # THE BOARD'S OWN GEOMETRY WINS when it carries any (see
        # inline_footprint's FULL vs PARTIAL rule). A component whose `pads`
        # list is present needs no library hit and must not take one: the
        # library on this machine may not stock the part at all, and where it
        # does it may hold different bytes under the same name. The pads the
        # board was routed against are the pads it gets fabricated with.
        if inline_footprint.carries_full_geometry(comp):
            try:
                definition = inline_footprint.footprint_from_component(comp, fp_ref)
            except (ValueError, TypeError) as exc:
                # Fail-closed rather than falling through to the library: a
                # silent substitution here is one part's copper standing in
                # for another's. Broader than InlineGeometryError on purpose —
                # the reader validates shape, but the PadDefinition/graphic
                # dataclasses validate range and type and raise bare
                # ValueError/TypeError, and both kinds of malformed geometry
                # have to land on this diagnostic rather than escape.
                diags.error("invalid_component_geometry",
                            f"component {ref!r}: inline pad geometry is unreadable: {exc}",
                            comp_ref)
                continue
            provenance = definition.provenance
            # Says the consequence, not just the fact: the board's list is
            # taken as the COMPLETE copper for this part, so a library
            # footprint feature the board never recorded is neither
            # fabricated nor adjudicated here. The pad-capability guards below
            # still bind — they judge the geometry the board DID state.
            diags.info(
                "footprint_from_board",
                f"component {ref!r}: geometry came from the board's own pads/graphics and is "
                f"taken as complete; the library was not consulted for {fp_ref!r}, so no "
                f"footprint feature outside this list is fabricated",
                comp_ref)
            if not definition.graphics:
                # The board owns BOTH halves once it owns either, so a missing
                # `graphics` list means the part really is drawn with no silk or
                # courtyard. Said out loud rather than left to be discovered on
                # a bare fabricated board.
                diags.warning(
                    "component_graphics_absent",
                    f"component {ref!r} carries its own pads but no graphics, so it "
                    f"will be fabricated with no silkscreen or courtyard; re-resolve "
                    f"it against {fp_ref!r} to attach them",
                    comp_ref)
        else:
            # The entry is read from the layer that WOULD supply this ref (first in
            # the chain whose lock contains it), so a malformed entry is judged on
            # the same layer resolution will use — never the seed's entry beside an
            # override's file.
            supplier = lookup_footprint_layer(fp_ref, chain)
            entry = supplier.lock.get(fp_ref) if supplier is not None else None
            if entry is not None and (not isinstance(entry, dict)
                                      or not isinstance(entry.get("path"), str)
                                      or not isinstance(entry.get("sha256"), str)):
                diags.error("lock_entry_malformed",
                            f"component {ref!r}: lock entry for {fp_ref!r} is malformed", comp_ref)
                continue
            # THE BOARD'S OWN LOCK, read before resolution
            # so a pinned-but-missing ref can say what it was pinned TO.
            pinned = _board_library_lock(board).get(fp_ref)
            try:
                supplied = resolve_footprint_layered(fp_ref, chain=chain)
            except FootprintLookupError as exc:
                if pinned:
                    # An ACTIONABLE refusal, not just "not found": the board knows
                    # exactly which bytes it wants, so say so and where they came
                    # from. Without this the user is told a name is missing and left
                    # to guess which of several same-named parts was meant.
                    diags.error(
                        "footprint_pinned_but_missing",
                        f"component {ref!r}: {fp_ref!r} is pinned to sha256 "
                        f"{str(pinned.get('sha256', ''))[:12]}… but no library layer supplies it"
                        + (f"; it came from {pinned.get('source')!r} when the board was locked"
                           if pinned.get("source") else "")
                        + (f" (layer {pinned.get('layer')!r})" if pinned.get("layer") else ""),
                        comp_ref)
                else:
                    diags.error("footprint_unresolved", f"component {ref!r}: {exc}", comp_ref)
                continue
            parsed = supplied.parsed

            # IDENTITY, NOT NAME. The layer chain has already proven the FILE matches
            # its own layer's lock; this asks the different question K20 exists for —
            # is it the content THIS BOARD consumed? A user layer legitimately
            # overriding a seed part under the same name is exactly the case that
            # silently changes copper, and it is the case this catches.
            #
            # FAIL CLOSED. A mismatch is refused, never resolved-anyway-with-a-
            # warning: the whole value of a lock is that a rebuild either reproduces
            # the board or stops. Provenance is reported to make it repairable, but
            # only the sha adjudicates — refusing because a layer was RENAMED would
            # break boards whose copper never moved.
            if pinned:
                expected = str(pinned.get("sha256", ""))
                actual = str((entry or {}).get("sha256", ""))
                if not expected:
                    # A pin with no usable sha CANNOT adjudicate, and staying quiet
                    # about it is the worst option available: the board looks
                    # locked, compiles clean, and is pinned to nothing. Say so
                    # rather than let a malformed entry masquerade as protection.
                    diags.warning(
                        "library_pin_unusable",
                        f"component {ref!r}: the lock entry for {fp_ref!r} carries no sha256, "
                        f"so this footprint is NOT pinned — re-lock the board to restore it",
                        comp_ref)
                elif expected and not actual:
                    # The MIRROR of library_pin_unusable: the board knows what it
                    # wants, but the supplying layer's entry carries no sha to
                    # compare against, so the pin cannot fire. Same reasoning, same
                    # refusal to stay quiet — a pin that cannot adjudicate must not
                    # look like a pin that adjudicated and passed.
                    diags.warning(
                        "library_pin_uncheckable",
                        f"component {ref!r}: {fp_ref!r} is pinned, but the supplying layer "
                        f"{supplied.layer!r} has no sha256 for it — the pin could NOT be checked",
                        comp_ref)
                elif expected and actual and expected != actual:
                    diags.error(
                        "library_lock_mismatch",
                        f"component {ref!r}: {fp_ref!r} is pinned to sha256 {expected[:12]}… "
                        f"but layer {supplied.layer!r} supplies {actual[:12]}…. The board locked "
                        f"different content than the library now provides; resolve by restoring "
                        f"the pinned content or re-locking the board deliberately.",
                        comp_ref)
                    continue

            entry = entry or {}
            provenance = Provenance(
                source_id=fp_ref,
                sha256=entry.get("sha256"),
                license=entry.get("license"),
                # WHICH LAYER the bytes came from (S9). Recorded for every compile,
                # including the default seed-only one, because "the seed supplied
                # it" is a fact worth stating rather than an absence to infer — and
                # it costs nothing: Provenance is outside every digest.
                library_layer=supplied.layer,
            )
            definition = FootprintDefinition.from_kicad_parsed(parsed, provenance=provenance)
        clean = _adjudicate_footprint(definition, fp_ref, policy, requested_outputs, board, diags)
        if clean is None:
            continue
        if not all([_check_pad_capabilities(pad, ref, diags) for pad in clean.pads]):
            continue
        pin_overrides = _check_coincidence(comp, clean, ref, diags)

        component_id = derive_id("component", board_id, ref)
        placed = _place_component(comp, component_id, clean, side, pin_net, pin_overrides, ref, diags,
                                  copper_aliases_ordered)
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

    nets = _finalize_nets(net_descriptors, pad_ids_by_net, resolved_pins, components,
                          class_id_by_net, diags)
    traces = _build_traces(board, board_id, net_id_by_name, version, diags)
    vias = _build_vias(board, board_id, net_id_by_name, version, diags)
    holes = _build_holes(board, board_id, version, diags)
    zones = _build_zones(board, board_id, net_id_by_name, version, diags, design_rules)
    # Board-level artwork. Its own module: the builder owns a
    # font, five geometry kinds and a fail-closed layer rule, none of which this
    # file should grow. Text entries expand to N open-polyline primitives here,
    # so every downstream consumer sees plain geometry and no consumer needs to
    # know a font exists.
    board_graphics = board_graphics_mod.build_board_graphics(board, board_id, diags)

    # The ordinal-id bridge diagnostic is a v1-only artifact: v2 ids are the
    # persisted minted identity (validated above), not ordinal-derived, so there
    # is nothing to warn about.  A v1 zone id is ordinal-derived on the same terms
    # (board-yaml.md notes a v1 board is in fact the only convenient way to author
    # a zone today, since MigrateV1toV2 is the only zone-id minter).
    if version == 1 and (traces or vias or holes or zones):
        diags.info("ordinal_ids",
                   "trace/via/hole/zone ids are ordinal-derived and board-namespaced but NOT "
                   "stable under reorder/insert; persisted authored identity is a YAML-v2 "
                   "handoff that must land before any DRC/routing consumer switches onto the IR",
                   _board_ref())

    # ``layer_stack`` is no longer in this gate: since GA-1 the stack always
    # builds (the boundary validated the declaration; capability refusal is a
    # design_rules error), so a None here would be a programming error, not a
    # board defect.
    if diags.has_error or outline is None or design_rules is None:
        return ResolutionFailure(diagnostics=_ensure_error(diags))

    try:
        source_digest = content_id(board)
        # THE LIBRARY THIS BOARD WAS COMPILED AGAINST. A default (seed-only)
        # chain digests the seed lock ALONE — the identical value, over the
        # identical object, that this line produced before layering — so no
        # existing board's provenance moves. A CONFIGURED chain digests every
        # layer's lock keyed by layer name, because "which library" is then a
        # different question with a different answer, and a provenance that
        # digested only the seed would claim a board was built from the shipped
        # library when an override actually supplied its parts.
        library_lock_ref = content_id(
            chain[0].lock if len(chain) == 1 and chain[0].layer.name == SEED_LAYER
            else {loaded.layer.name: loaded.lock for loaded in chain})
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
        # The SAME ref just placed on design_rules.rule_profile (guaranteed
        # non-None by the has_error/None gate above) -- setting both from one
        # value is what keeps ResolvedBoard's "board and design-rule
        # provenance disagree" consistency check (:1098-1100) satisfied for
        # every profile, not just the default (K21, docket 019f762004dc).
        rule_profile_ref=design_rules.rule_profile,
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
            zones=zones,
            board_graphics=board_graphics,
            provenance=provenance,
        )
    except (ValueError, TypeError) as exc:
        diags.error("board_invariant", f"resolved board rejected: {exc}", _board_ref())
        return ResolutionFailure(diagnostics=_ensure_error(diags))

    # ZONE FILL — the last compile step, and it runs HERE (on the assembled
    # ResolvedBoard) rather than inside _build_zones for one reason: a pour is
    # defined by everything else on its layer. It carves around pads, traces,
    # vias and drills, so it cannot be computed until all of them exist. Running
    # it on the finished board also lets it share the geometric DRC's copper
    # PROJECTION instead of forking a second harvest — so the copper a pour
    # carves around and the copper the DRC checks are the same set by
    # construction (see zone_fill.fill_board_zones).
    #
    # FAIL-CLOSED: a pour that cannot be filled is a compile ERROR naming the
    # zone, never a board that compiles with approximated or missing copper.
    culled: list[CulledRegion] = []
    try:
        resolved = fill_board_zones(resolved, culled=culled)
    except ZoneFillError as exc:
        diags.error("zone_fill_failed", str(exc),
                    SourceRef(EntityKind.ZONE, exc.zone_id))
        return ResolutionFailure(diagnostics=_ensure_error(diags))
    except (ValueError, TypeError) as exc:
        diags.error("zone_fill_failed", f"zone fill rejected the board: {exc}",
                    _board_ref())
        return ResolutionFailure(diagnostics=_ensure_error(diags))

    # CULLED COPPER IS REPORTED, NEVER SILENT. One warning per pour rather than
    # one per region: the author needs the total they lost and where each piece
    # was, and N separate rows for N crumbs of one fan-out buries that.
    for zone_id in dict.fromkeys(record.zone_id for record in culled):
        rows = [record for record in culled if record.zone_id == zone_id]
        total = sum(record.area_mm2 for record in rows)
        detail = "\n  - ".join(record.describe() for record in rows)
        diags.warning(
            "zone_fill_culled",
            f"zone {zone_id} dropped {len(rows)} unfabricable region(s) totalling "
            f"{total:.6f} mm^2 from its fill:\n  - {detail}",
            SourceRef(EntityKind.ZONE, zone_id))

    for zone in resolved.zones:
        if zone.kind is not ZoneKind.COPPER_POUR:
            continue
        area = fill_area_mm2(zone)
        if not zone.fill:
            # COMPUTED and empty — a real answer (a pour entirely covered by a
            # keepout, say), not the uncomputed fill=None this used to warn
            # about. Reported at WARNING because an author who drew a pour and
            # got no copper almost certainly did not mean to.
            diags.warning(
                "zone_fill_empty",
                f"zone {zone.id} on {zone.layer.id} computed a fill with NO copper: "
                f"its outline is entirely consumed by keepouts, clearance or the "
                f"board-edge inset. The pour is empty, not uncomputed",
                SourceRef(EntityKind.ZONE, zone.id))
            continue
        diags.info(
            "zone_filled",
            f"zone {zone.id} on {zone.layer.id} filled: {len(zone.fill)} region(s), "
            f"{area:.4f} mm^2 of copper (solid connect)",
            SourceRef(EntityKind.ZONE, zone.id))

    return ResolutionSuccess(board=resolved, diagnostics=diags.tuple())


def _footprint_pad_map(fp_ref, *, chain=None, library_root=None,
                       lock=None) -> dict[str, PadDefinition]:
    """Resolve a component's footprint to a ``{pad_number: PadDefinition}`` map via
    the SAME footprint-resolution path the compile fold classifies against
    (``resolve_footprint`` → :class:`FootprintDefinition`), so normalize correlates
    each pin to exactly the pad the compiler would.  That sameness now includes the
    LAYER CHAIN (S9): normalize classifies against the pad an override supplies, not
    the seed pad it shadows.  Best-effort: a missing/invalid
    ref or an unresolvable footprint yields an empty map, which makes any inline pin
    on that component AMBIGUOUS (fail-closed), never silently migrated.  Marker
    adjudication is intentionally skipped — it only strips feature markers and never
    alters pad drill/size geometry, which is all the classification reads.

    A loaded ``chain`` is what ``normalize_board`` passes; ``library_root``/``lock``
    are the pre-S9 single-seed-layer form, kept working (and kept meaning exactly
    what they meant) so an existing caller needs no edit."""
    if not isinstance(fp_ref, str) or not fp_ref:
        return {}
    try:
        parsed = resolve_footprint_layered(fp_ref, chain=chain, library_root=library_root,
                                           lock=lock).parsed
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
    library_layers: Union[Iterable, None] = None,
    wip_root: Union[str, Path, None] = None,
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

    # The SAME layer chain compile_board resolves through (``library_layers``
    # + ``wip_root``, S9/B7) — normalize's whole contract is that a board it
    # accepts is a board compile accepts, which it cannot be if the two read
    # different libraries. Materialized once for the same generator-safety
    # reason compile_board does it (Codex 1160 P2).
    if library_layers is not None:
        library_layers = tuple(library_layers)
    try:
        chain = bless.live_library_chain(
            wip_root=wip_root, layers=library_layers,
            library_root=library_root, lockfile=lockfile)
        if any(not isinstance(loaded.lock, dict) for loaded in chain):
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
        pad_by_number = _footprint_pad_map(comp.get("footprint"), chain=chain)
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
    (never default an unrecognized value to TOP — review 621 MF1).

    Token vocabulary read from geometry.TOP_LAYER_NAMES / BOTTOM_LAYER_NAMES —
    the single authority (docket 019fc3105828); the refusal shape here (return
    None + diags.error) stays local to this module, deliberately not unified
    with assembly_outputs._resolve_side's raise-based one."""
    if raw_layer is None:
        return Side.TOP
    token = str(raw_layer).strip().lower()
    if token in TOP_LAYER_NAMES:
        return Side.TOP
    if token in BOTTOM_LAYER_NAMES:
        return Side.BOTTOM
    diags.error("invalid_component",
                f"component {ref!r}: unknown layer/side {raw_layer!r}", comp_ref)
    return None


def _finalize_nets(descriptors, pad_ids_by_net, resolved_pins, components,
                   class_id_by_net: dict[str, str],
                   diags: _Diagnostics) -> tuple[ResolvedNet, ...]:
    """Assemble ResolvedNets from placed-pad membership.  EVERY declared pin must
    resolve to a placed pad — a well-formed reference to a nonexistent pad is an
    ERROR, never silently dropped (K2 review 623 R3).  A net with no resolved
    pads is likewise an error.

    This is where the authored net-class MEMBERSHIP becomes the IR's per-net
    ``net_class_id``: ``class_id_by_net`` is the inversion of the members lists
    ``_build_net_classes`` parsed off ``design_rules``.  Without this assignment
    both consumers (``methods._net_class_overrides``,
    ``drc_geometric._net_class_minima``) would still see nothing, because both
    read REFERENCED classes only — a populated ``design_rules.net_classes`` that
    no net points at constrains no copper."""
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
        nets.append(ResolvedNet(id=net_id, name=name, index=index, pad_refs=tuple(ordered),
                                net_class_id=class_id_by_net.get(name)))
    return tuple(nets)


def _ensure_error(diags: _Diagnostics) -> tuple[Diagnostic, ...]:
    items = diags.tuple()
    if any(d.severity is DiagnosticSeverity.ERROR for d in items):
        return items
    return items + (Diagnostic(DiagnosticSeverity.ERROR, "compile_failed",
                               "board could not be resolved", _board_ref()),)
