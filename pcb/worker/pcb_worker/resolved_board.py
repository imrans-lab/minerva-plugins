"""Fabrication-complete, identity-bearing PCB intermediate representation.

``ResolvedBoard`` is the one immutable geometry authority consumed by CAM,
KiCad export, DRC, and routing after the K2/K3 migration.  It contains no
preview fallbacks or unsupported placeholders.  A compiler instead returns a
``ResolutionSuccess`` (board plus warnings) or ``ResolutionFailure``.

This module intentionally does not import :mod:`footprint_def` at runtime.
Footprint definitions import the shared Layer/diagnostic contracts from here;
using a forward annotation in the board keeps that dependency one-way.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
import math
from types import MappingProxyType
from typing import Mapping, Protocol, TYPE_CHECKING, TypeAlias

if TYPE_CHECKING:  # pragma: no cover - annotation-only cycle breaker
    from .footprint_def import DrillDefinition, FootprintDefinition, PadShape, Provenance


Point: TypeAlias = tuple[float, float]


def _nonempty(value: str, field: str) -> None:
    if not isinstance(value, str) or not value:
        raise ValueError(f"{field} must be a non-empty string")


def _finite(value: float, field: str) -> None:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError(f"{field} must be a finite number")


def _nonnegative(value: float, field: str) -> None:
    _finite(value, field)
    if value < 0:
        raise ValueError(f"{field} must be >= 0")


def _positive(value: float, field: str) -> None:
    _finite(value, field)
    if value <= 0:
        raise ValueError(f"{field} must be > 0")


def _point(value: Point, field: str) -> None:
    if not isinstance(value, tuple) or len(value) != 2:
        raise TypeError(f"{field} must be an immutable (x, y) tuple")
    _finite(value[0], f"{field}.x")
    _finite(value[1], f"{field}.y")


def _tuple(value: tuple, field: str) -> None:
    if not isinstance(value, tuple):
        raise TypeError(f"{field} must be a tuple")


def _unique_ids(items: tuple, field: str) -> None:
    ids = [item.id for item in items]
    if len(ids) != len(set(ids)):
        raise ValueError(f"{field} contains duplicate ids")


def _typed(value: object, expected: type, field: str) -> None:
    if not isinstance(value, expected):
        raise TypeError(f"{field} must be {expected.__name__}")


class Side(str, Enum):
    TOP = "top"
    BOTTOM = "bottom"


class LayerRole(str, Enum):
    COPPER = "copper"
    MASK = "mask"
    PASTE = "paste"
    SILK = "silk"
    FAB = "fab"
    COURTYARD = "courtyard"
    EDGE = "edge"
    USER = "user"
    OTHER = "other"


@dataclass(frozen=True, order=True)
class Layer:
    """Open layer value: standard layers are recognized, arbitrary User.* survives."""

    id: str
    role: LayerRole
    side: Side | None = None

    def __post_init__(self) -> None:
        _nonempty(self.id, "Layer.id")
        _typed(self.role, LayerRole, "Layer.role")
        if self.side is not None:
            _typed(self.side, Side, "Layer.side")

    @classmethod
    def from_id(cls, layer_id: str) -> "Layer":
        _nonempty(layer_id, "layer_id")
        low = layer_id.lower()
        side: Side | None = None
        if low == "top" or low.startswith("f."):
            side = Side.TOP
        elif low == "bottom" or low.startswith("b."):
            side = Side.BOTTOM

        if low in {"top", "bottom", "f.cu", "b.cu"} or low.endswith(".cu"):
            role = LayerRole.COPPER
        elif low.endswith(".mask"):
            role = LayerRole.MASK
        elif low.endswith(".paste"):
            role = LayerRole.PASTE
        elif low.endswith(".silks"):
            role = LayerRole.SILK
        elif low.endswith(".fab"):
            role = LayerRole.FAB
        elif low.endswith(".crtyd"):
            role = LayerRole.COURTYARD
        elif low == "edge.cuts":
            role = LayerRole.EDGE
            side = None
        elif "user" in low or low == "cmts.user":
            role = LayerRole.USER
            side = None
        else:
            role = LayerRole.OTHER
        if layer_id.startswith("*."):
            side = None
        return cls(layer_id, role, side)

    @property
    def is_wildcard(self) -> bool:
        return self.id.startswith("*.")

    def flipped(self) -> "Layer":
        """Swap one explicit front/back layer; wildcards and global layers stay put."""
        if self.is_wildcard or self.side is None:
            return self
        if self.id == "top":
            return Layer.from_id("bottom")
        if self.id == "bottom":
            return Layer.from_id("top")
        if self.id.startswith("F."):
            return Layer.from_id("B." + self.id[2:])
        if self.id.startswith("B."):
            return Layer.from_id("F." + self.id[2:])
        return Layer(self.id, self.role, Side.BOTTOM if self.side is Side.TOP else Side.TOP)


class DiagnosticSeverity(str, Enum):
    INFO = "info"
    WARNING = "warning"
    ERROR = "error"


class EntityKind(str, Enum):
    BOARD = "board"
    COMPONENT = "component"
    PAD = "pad"
    NET = "net"
    TRACE = "trace"
    SEGMENT = "segment"
    VIA = "via"
    HOLE = "hole"
    GRAPHIC = "graphic"
    ZONE = "zone"
    FOOTPRINT = "footprint"


@dataclass(frozen=True)
class SourceRef:
    entity_kind: EntityKind
    entity_id: str
    detail: str | None = None

    def __post_init__(self) -> None:
        _typed(self.entity_kind, EntityKind, "SourceRef.entity_kind")
        _nonempty(self.entity_id, "SourceRef.entity_id")


class FeatureDomain(str, Enum):
    COPPER = "copper"
    DRILL = "drill"
    MASK = "mask"
    PASTE = "paste"
    SILK = "silk"
    FAB = "fab"
    DOCUMENTATION = "documentation"
    ASSEMBLY = "assembly"
    RULES = "rules"


@dataclass(frozen=True)
class UnsupportedFeature:
    feature: str
    domain: FeatureDomain
    affected_layer: Layer | None
    affected_outputs: tuple[str, ...]
    default_blocking: bool
    detail: str
    source_ref: SourceRef

    def __post_init__(self) -> None:
        _nonempty(self.feature, "UnsupportedFeature.feature")
        _typed(self.domain, FeatureDomain, "UnsupportedFeature.domain")
        if self.affected_layer is not None:
            _typed(self.affected_layer, Layer, "UnsupportedFeature.affected_layer")
        _tuple(self.affected_outputs, "UnsupportedFeature.affected_outputs")
        if not self.affected_outputs:
            raise ValueError("UnsupportedFeature.affected_outputs must not be empty")
        for output in self.affected_outputs:
            _nonempty(output, "UnsupportedFeature.affected_outputs entry")
        _nonempty(self.detail, "UnsupportedFeature.detail")


@dataclass(frozen=True)
class Diagnostic:
    severity: DiagnosticSeverity
    code: str
    message: str
    source_ref: SourceRef

    def __post_init__(self) -> None:
        _typed(self.severity, DiagnosticSeverity, "Diagnostic.severity")
        _nonempty(self.code, "Diagnostic.code")
        _nonempty(self.message, "Diagnostic.message")


class CapabilityPolicy(Protocol):
    def is_blocking(
        self,
        marker: UnsupportedFeature,
        board_context: object,
        requested_outputs: tuple[str, ...],
    ) -> bool: ...


# ---------------------------------------------------------------------------
# Geometry primitives shared by placed graphics, contours, and board graphics.
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class LineGeometry:
    a: Point
    b: Point

    def __post_init__(self) -> None:
        _point(self.a, "LineGeometry.a")
        _point(self.b, "LineGeometry.b")
        if self.a == self.b:
            raise ValueError("line endpoints must differ")


@dataclass(frozen=True)
class CircleGeometry:
    center: Point
    radius_mm: float

    def __post_init__(self) -> None:
        _point(self.center, "CircleGeometry.center")
        _positive(self.radius_mm, "CircleGeometry.radius_mm")


@dataclass(frozen=True)
class ArcGeometry:
    start: Point
    mid: Point
    end: Point

    def __post_init__(self) -> None:
        _point(self.start, "ArcGeometry.start")
        _point(self.mid, "ArcGeometry.mid")
        _point(self.end, "ArcGeometry.end")
        if len({self.start, self.mid, self.end}) < 3:
            raise ValueError("arc start/mid/end must be distinct")


@dataclass(frozen=True)
class PolygonGeometry:
    points: tuple[Point, ...]

    def __post_init__(self) -> None:
        _tuple(self.points, "PolygonGeometry.points")
        if len(self.points) < 3:
            raise ValueError("polygon requires at least three points")
        for index, value in enumerate(self.points):
            _point(value, f"PolygonGeometry.points[{index}]")


GraphicGeometry: TypeAlias = LineGeometry | CircleGeometry | ArcGeometry | PolygonGeometry
ContourSegment: TypeAlias = LineGeometry | ArcGeometry


@dataclass(frozen=True)
class Contour:
    segments: tuple[ContourSegment, ...]

    def __post_init__(self) -> None:
        _tuple(self.segments, "Contour.segments")
        if not self.segments:
            raise ValueError("contour must contain at least one segment")
        ends = [s.b if isinstance(s, LineGeometry) else s.end for s in self.segments]
        starts = [s.a if isinstance(s, LineGeometry) else s.start for s in self.segments]
        if any(ends[i] != starts[(i + 1) % len(starts)] for i in range(len(starts))):
            raise ValueError("contour segments must form one closed ordered loop")


# ---------------------------------------------------------------------------
# Board frame, stack, rules, and provenance.
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class RectOutline:
    origin: Point
    width_mm: float
    height_mm: float

    def __post_init__(self) -> None:
        _point(self.origin, "RectOutline.origin")
        _positive(self.width_mm, "RectOutline.width_mm")
        _positive(self.height_mm, "RectOutline.height_mm")


@dataclass(frozen=True)
class ProfileOutline:
    outer: Contour
    cutouts: tuple[Contour, ...] = ()

    def __post_init__(self) -> None:
        _tuple(self.cutouts, "ProfileOutline.cutouts")


BoardOutline: TypeAlias = RectOutline | ProfileOutline


@dataclass(frozen=True)
class ResolvedLayer:
    id: str
    kicad_alias: str
    stack_index: int
    role: LayerRole = LayerRole.COPPER

    def __post_init__(self) -> None:
        _nonempty(self.id, "ResolvedLayer.id")
        _nonempty(self.kicad_alias, "ResolvedLayer.kicad_alias")
        _typed(self.role, LayerRole, "ResolvedLayer.role")
        if self.stack_index < 0:
            raise ValueError("ResolvedLayer.stack_index must be >= 0")
        if self.role is not LayerRole.COPPER:
            raise ValueError("ResolvedLayer must describe copper")


class StackupKind(str, Enum):
    COPPER = "copper"
    DIELECTRIC = "dielectric"
    MASK = "mask"
    SILK = "silk"
    OTHER = "other"


@dataclass(frozen=True)
class StackupEntry:
    id: str
    order: int
    kind: StackupKind
    thickness_mm: float | None = None
    material: str | None = None
    copper_layer_id: str | None = None

    def __post_init__(self) -> None:
        _nonempty(self.id, "StackupEntry.id")
        _typed(self.kind, StackupKind, "StackupEntry.kind")
        if self.order < 0:
            raise ValueError("StackupEntry.order must be >= 0")
        if self.thickness_mm is not None:
            _positive(self.thickness_mm, "StackupEntry.thickness_mm")
        if self.kind is StackupKind.COPPER and not self.copper_layer_id:
            raise ValueError("copper stack entries require copper_layer_id")
        if self.kind is not StackupKind.COPPER and self.copper_layer_id is not None:
            raise ValueError("only copper stack entries may reference a copper layer")


@dataclass(frozen=True)
class PhysicalStackup:
    entries: tuple[StackupEntry, ...]

    def __post_init__(self) -> None:
        _tuple(self.entries, "PhysicalStackup.entries")
        if not self.entries:
            raise ValueError("PhysicalStackup.entries must not be empty")
        _unique_ids(self.entries, "PhysicalStackup.entries")
        orders = [entry.order for entry in self.entries]
        if orders != list(range(len(orders))):
            raise ValueError("PhysicalStackup.entry order must be contiguous from zero")


@dataclass(frozen=True)
class LayerStack:
    copper: tuple[ResolvedLayer, ...]
    stackup: PhysicalStackup
    technical: tuple[Layer, ...]

    def __post_init__(self) -> None:
        _tuple(self.copper, "LayerStack.copper")
        _tuple(self.technical, "LayerStack.technical")
        if len(self.copper) < 2:
            raise ValueError("LayerStack requires at least two copper layers")
        _unique_ids(self.copper, "LayerStack.copper")
        aliases = [layer.kicad_alias for layer in self.copper]
        if len(aliases) != len(set(aliases)):
            raise ValueError("copper layers must have unique KiCad aliases")
        indices = [layer.stack_index for layer in self.copper]
        if indices != list(range(len(indices))):
            raise ValueError("copper stack indices must be contiguous from zero")
        copper_ids = {layer.id for layer in self.copper}
        stack_copper_ids = [
            entry.copper_layer_id for entry in self.stackup.entries
            if entry.kind is StackupKind.COPPER
        ]
        if set(stack_copper_ids) != copper_ids or len(stack_copper_ids) != len(copper_ids):
            raise ValueError("physical stackup must contain each copper layer exactly once")
        for entry in self.stackup.entries:
            if entry.copper_layer_id and entry.copper_layer_id not in copper_ids:
                raise ValueError(f"stack entry references unknown copper layer {entry.copper_layer_id!r}")
        if any(layer.role is LayerRole.COPPER for layer in self.technical):
            raise ValueError("technical layers must not duplicate the copper stack")
        technical_ids = [layer.id for layer in self.technical]
        if len(technical_ids) != len(set(technical_ids)):
            raise ValueError("technical layer ids must be unique")

    def is_legal_via_span(self, from_layer: str, to_layer: str) -> bool:
        indices = {layer.id: layer.stack_index for layer in self.copper}
        return from_layer in indices and to_layer in indices and indices[from_layer] != indices[to_layer]


@dataclass(frozen=True)
class RuleProfileRef:
    id: str
    version: str
    digest: str

    def __post_init__(self) -> None:
        _nonempty(self.id, "RuleProfileRef.id")
        _nonempty(self.version, "RuleProfileRef.version")
        _nonempty(self.digest, "RuleProfileRef.digest")


@dataclass(frozen=True)
class RoutingDefaults:
    trace_width_mm: float
    via_diameter_mm: float
    via_drill_mm: float

    def __post_init__(self) -> None:
        _positive(self.trace_width_mm, "RoutingDefaults.trace_width_mm")
        _positive(self.via_diameter_mm, "RoutingDefaults.via_diameter_mm")
        _positive(self.via_drill_mm, "RoutingDefaults.via_drill_mm")
        if self.via_drill_mm >= self.via_diameter_mm:
            raise ValueError("default via drill must be smaller than diameter")


@dataclass(frozen=True)
class ManufacturingConstraints:
    min_trace_width_mm: float
    min_clearance_mm: float
    min_drill_mm: float
    min_finished_hole_mm: float
    min_annular_ring_mm: float
    min_hole_to_hole_mm: float
    min_mask_sliver_mm: float
    solder_mask_clearance_mm: float
    solder_mask_expansion_mm: float
    copper_to_edge_mm: float

    def __post_init__(self) -> None:
        for field in (
            "min_trace_width_mm", "min_clearance_mm", "min_drill_mm",
            "min_finished_hole_mm", "min_annular_ring_mm",
            "min_hole_to_hole_mm", "min_mask_sliver_mm",
            "solder_mask_clearance_mm", "copper_to_edge_mm",
        ):
            _nonnegative(getattr(self, field), f"ManufacturingConstraints.{field}")
        _finite(self.solder_mask_expansion_mm, "ManufacturingConstraints.solder_mask_expansion_mm")


class ViaKind(str, Enum):
    THROUGH = "through"
    BLIND = "blind"
    BURIED = "buried"
    MICRO = "micro"


@dataclass(frozen=True)
class NetClass:
    id: str
    name: str
    trace_width_mm: float | None = None
    via_diameter_mm: float | None = None
    via_drill_mm: float | None = None
    min_trace_width_mm: float | None = None
    min_clearance_mm: float | None = None

    def __post_init__(self) -> None:
        _nonempty(self.id, "NetClass.id")
        _nonempty(self.name, "NetClass.name")
        for field in (
            "trace_width_mm", "via_diameter_mm", "via_drill_mm",
            "min_trace_width_mm", "min_clearance_mm",
        ):
            value = getattr(self, field)
            if value is not None:
                _nonnegative(value, f"NetClass.{field}")
        if (self.via_diameter_mm is not None and self.via_drill_mm is not None
                and self.via_drill_mm >= self.via_diameter_mm):
            raise ValueError("net-class via drill must be smaller than diameter")


@dataclass(frozen=True)
class ResolvedDesignRules:
    defaults: RoutingDefaults
    minimums: ManufacturingConstraints
    allowed_via_kinds: tuple[ViaKind, ...]
    net_classes: tuple[NetClass, ...]
    rule_profile: RuleProfileRef

    def __post_init__(self) -> None:
        _tuple(self.allowed_via_kinds, "ResolvedDesignRules.allowed_via_kinds")
        _tuple(self.net_classes, "ResolvedDesignRules.net_classes")
        if not self.allowed_via_kinds:
            raise ValueError("at least one via kind must be allowed")
        if len(self.allowed_via_kinds) != len(set(self.allowed_via_kinds)):
            raise ValueError("allowed via kinds must be unique")
        _unique_ids(self.net_classes, "ResolvedDesignRules.net_classes")


@dataclass(frozen=True)
class BoardProvenance:
    compiler_version: str
    source_digest: str
    library_lock_ref: str
    rule_profile_ref: RuleProfileRef | None = None
    generated_at: str | None = None

    def __post_init__(self) -> None:
        _nonempty(self.compiler_version, "BoardProvenance.compiler_version")
        _nonempty(self.source_digest, "BoardProvenance.source_digest")
        _nonempty(self.library_lock_ref, "BoardProvenance.library_lock_ref")


# ---------------------------------------------------------------------------
# Placed electrical/mechanical entities.
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Placement:
    position: Point
    rotation_deg: float
    side: Side

    def __post_init__(self) -> None:
        _point(self.position, "Placement.position")
        _finite(self.rotation_deg, "Placement.rotation_deg")
        _typed(self.side, Side, "Placement.side")


@dataclass(frozen=True)
class PlacedPad:
    id: str
    component_id: str
    source_id: str
    net_id: str | None
    pad_type: str
    shape: "PadShape"
    position: Point
    size: tuple[float, float] | None
    rotation_deg: float
    corner_rratio: float | None
    drill: "DrillDefinition | None"
    annulus: float | None
    solder_mask_margin: float | None
    solder_paste_margin: float | None
    layers: tuple[Layer, ...]
    side: Side

    def __post_init__(self) -> None:
        for field in ("id", "component_id", "source_id", "pad_type"):
            _nonempty(getattr(self, field), f"PlacedPad.{field}")
        _point(self.position, "PlacedPad.position")
        _finite(self.rotation_deg, "PlacedPad.rotation_deg")
        _typed(self.side, Side, "PlacedPad.side")
        if self.size is not None:
            _point(self.size, "PlacedPad.size")
            _positive(self.size[0], "PlacedPad.size.width")
            _positive(self.size[1], "PlacedPad.size.height")
        if self.corner_rratio is not None and not 0 <= self.corner_rratio <= 0.5:
            raise ValueError("PlacedPad.corner_rratio must be in [0, 0.5]")
        if self.annulus is not None:
            _positive(self.annulus, "PlacedPad.annulus")
        _tuple(self.layers, "PlacedPad.layers")


@dataclass(frozen=True)
class PlacedGraphic:
    id: str
    component_id: str
    source_id: str
    layer: Layer
    geometry: GraphicGeometry
    width_mm: float | None

    def __post_init__(self) -> None:
        for field in ("id", "component_id", "source_id"):
            _nonempty(getattr(self, field), f"PlacedGraphic.{field}")
        _typed(self.layer, Layer, "PlacedGraphic.layer")
        if not isinstance(self.geometry, (LineGeometry, CircleGeometry, ArcGeometry, PolygonGeometry)):
            raise TypeError("PlacedGraphic.geometry has an unknown geometry type")
        if self.width_mm is not None:
            _nonnegative(self.width_mm, "PlacedGraphic.width_mm")


@dataclass(frozen=True)
class ResolvedComponent:
    id: str
    ref: str
    footprint_id: str
    placement: Placement
    placed_pads: tuple[PlacedPad, ...]
    placed_graphics: tuple[PlacedGraphic, ...]
    provenance: "Provenance"
    value: str = ""

    def __post_init__(self) -> None:
        for field in ("id", "ref", "footprint_id"):
            _nonempty(getattr(self, field), f"ResolvedComponent.{field}")
        if not isinstance(self.value, str):
            raise TypeError("ResolvedComponent.value must be a string")
        _tuple(self.placed_pads, "ResolvedComponent.placed_pads")
        _tuple(self.placed_graphics, "ResolvedComponent.placed_graphics")
        _unique_ids(self.placed_pads, "ResolvedComponent.placed_pads")
        _unique_ids(self.placed_graphics, "ResolvedComponent.placed_graphics")
        if self.provenance is None:
            raise ValueError("ResolvedComponent.provenance is mandatory")
        if any(p.component_id != self.id for p in self.placed_pads):
            raise ValueError("placed pad component_id does not match component")
        if any(g.component_id != self.id for g in self.placed_graphics):
            raise ValueError("placed graphic component_id does not match component")


@dataclass(frozen=True)
class ResolvedNet:
    id: str
    name: str
    index: int
    pad_refs: tuple[str, ...]
    net_class_id: str | None = None

    def __post_init__(self) -> None:
        _nonempty(self.id, "ResolvedNet.id")
        _nonempty(self.name, "ResolvedNet.name")
        if self.index <= 0:
            raise ValueError("ResolvedNet.index must be positive; KiCad reserves zero")
        _tuple(self.pad_refs, "ResolvedNet.pad_refs")
        if len(self.pad_refs) != len(set(self.pad_refs)):
            raise ValueError("ResolvedNet.pad_refs must be unique")


@dataclass(frozen=True)
class ResolvedTraceSegment:
    id: str
    a: Point
    b: Point
    width_mm: float
    layer: Layer

    def __post_init__(self) -> None:
        _nonempty(self.id, "ResolvedTraceSegment.id")
        _point(self.a, "ResolvedTraceSegment.a")
        _point(self.b, "ResolvedTraceSegment.b")
        if self.a == self.b:
            raise ValueError("trace segment endpoints must differ")
        _positive(self.width_mm, "ResolvedTraceSegment.width_mm")
        _typed(self.layer, Layer, "ResolvedTraceSegment.layer")
        if self.layer.role is not LayerRole.COPPER:
            raise ValueError("trace segments must be on copper")


@dataclass(frozen=True)
class ResolvedTrace:
    id: str
    net_id: str
    segments: tuple[ResolvedTraceSegment, ...]

    def __post_init__(self) -> None:
        _nonempty(self.id, "ResolvedTrace.id")
        _nonempty(self.net_id, "ResolvedTrace.net_id")
        _tuple(self.segments, "ResolvedTrace.segments")
        if not self.segments:
            raise ValueError("ResolvedTrace requires at least one segment")
        _unique_ids(self.segments, "ResolvedTrace.segments")


@dataclass(frozen=True)
class LayerPad:
    layer_id: str
    diameter_mm: float
    annulus_mm: float

    def __post_init__(self) -> None:
        _nonempty(self.layer_id, "LayerPad.layer_id")
        _positive(self.diameter_mm, "LayerPad.diameter_mm")
        _nonnegative(self.annulus_mm, "LayerPad.annulus_mm")


@dataclass(frozen=True)
class ViaPadstack:
    per_layer: tuple[LayerPad, ...]

    def __post_init__(self) -> None:
        _tuple(self.per_layer, "ViaPadstack.per_layer")
        if not self.per_layer:
            raise ValueError("ViaPadstack requires at least one layer pad")
        layer_ids = [pad.layer_id for pad in self.per_layer]
        if len(layer_ids) != len(set(layer_ids)):
            raise ValueError("ViaPadstack has duplicate layers")


@dataclass(frozen=True)
class ResolvedVia:
    id: str
    position: Point
    diameter_mm: float
    drill_mm: float
    net_id: str
    kind: ViaKind
    from_layer: str
    to_layer: str
    tented_front: bool
    tented_back: bool
    padstack: ViaPadstack | None = None

    def __post_init__(self) -> None:
        for field in ("id", "net_id", "from_layer", "to_layer"):
            _nonempty(getattr(self, field), f"ResolvedVia.{field}")
        _point(self.position, "ResolvedVia.position")
        _positive(self.diameter_mm, "ResolvedVia.diameter_mm")
        _positive(self.drill_mm, "ResolvedVia.drill_mm")
        _typed(self.kind, ViaKind, "ResolvedVia.kind")
        if self.drill_mm >= self.diameter_mm:
            raise ValueError("via drill must be smaller than diameter")
        if self.from_layer == self.to_layer:
            raise ValueError("via span must change layers")


@dataclass(frozen=True)
class RoundHole:
    position: Point
    diameter_mm: float

    def __post_init__(self) -> None:
        _point(self.position, "RoundHole.position")
        _positive(self.diameter_mm, "RoundHole.diameter_mm")


@dataclass(frozen=True)
class OvalHole:
    position: Point
    width_mm: float
    height_mm: float
    rotation_deg: float

    def __post_init__(self) -> None:
        _point(self.position, "OvalHole.position")
        _positive(self.width_mm, "OvalHole.width_mm")
        _positive(self.height_mm, "OvalHole.height_mm")
        _finite(self.rotation_deg, "OvalHole.rotation_deg")


@dataclass(frozen=True)
class SlotHole:
    path: tuple[Point, ...]
    width_mm: float

    def __post_init__(self) -> None:
        _tuple(self.path, "SlotHole.path")
        if len(self.path) < 2:
            raise ValueError("slot path needs at least two points")
        for index, value in enumerate(self.path):
            _point(value, f"SlotHole.path[{index}]")
        _positive(self.width_mm, "SlotHole.width_mm")


HoleFeature: TypeAlias = RoundHole | OvalHole | SlotHole


class HoleKind(str, Enum):
    MOUNTING = "mounting"
    NPTH = "npth"
    PTH = "pth"


@dataclass(frozen=True)
class ResolvedHole:
    id: str
    feature: HoleFeature
    plated: bool
    kind: HoleKind

    def __post_init__(self) -> None:
        _nonempty(self.id, "ResolvedHole.id")
        _typed(self.kind, HoleKind, "ResolvedHole.kind")
        if self.kind is HoleKind.NPTH and self.plated:
            raise ValueError("NPTH holes cannot be plated")
        if self.kind is HoleKind.PTH and not self.plated:
            raise ValueError("PTH holes must be plated")


class ZoneKind(str, Enum):
    COPPER_POUR = "copper_pour"
    KEEPOUT = "keepout"


class ConnectMode(str, Enum):
    SOLID = "solid"
    THERMAL = "thermal"
    NONE = "none"


@dataclass(frozen=True)
class ThermalSettings:
    gap_mm: float
    bridge_width_mm: float

    def __post_init__(self) -> None:
        _nonnegative(self.gap_mm, "ThermalSettings.gap_mm")
        _positive(self.bridge_width_mm, "ThermalSettings.bridge_width_mm")


@dataclass(frozen=True)
class ResolvedZone:
    id: str
    net_id: str | None
    layer: Layer
    kind: ZoneKind
    authored_outline: Contour
    fill: tuple[PolygonGeometry, ...] | None = None
    clearance_mm: float | None = None
    min_thickness_mm: float | None = None
    priority: int | None = None
    connect_mode: ConnectMode | None = None
    thermal: ThermalSettings | None = None

    def __post_init__(self) -> None:
        _nonempty(self.id, "ResolvedZone.id")
        _typed(self.layer, Layer, "ResolvedZone.layer")
        _typed(self.kind, ZoneKind, "ResolvedZone.kind")
        if self.connect_mode is not None:
            _typed(self.connect_mode, ConnectMode, "ResolvedZone.connect_mode")
        if self.layer.role is not LayerRole.COPPER:
            raise ValueError("zones must be on copper")
        if self.fill is not None:
            _tuple(self.fill, "ResolvedZone.fill")
        if self.clearance_mm is not None:
            _nonnegative(self.clearance_mm, "ResolvedZone.clearance_mm")
        if self.min_thickness_mm is not None:
            _positive(self.min_thickness_mm, "ResolvedZone.min_thickness_mm")
        if self.thermal is not None and self.connect_mode is not ConnectMode.THERMAL:
            raise ValueError("thermal settings require thermal connect mode")


@dataclass(frozen=True)
class BoardGraphic:
    id: str
    layer: Layer
    geometry: GraphicGeometry
    width_mm: float | None = None

    def __post_init__(self) -> None:
        _nonempty(self.id, "BoardGraphic.id")
        _typed(self.layer, Layer, "BoardGraphic.layer")
        if not isinstance(self.geometry, (LineGeometry, CircleGeometry, ArcGeometry, PolygonGeometry)):
            raise TypeError("BoardGraphic.geometry has an unknown geometry type")
        if self.width_mm is not None:
            _nonnegative(self.width_mm, "BoardGraphic.width_mm")


# ---------------------------------------------------------------------------
# Preview-only projection and resolution result envelope.
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class FallbackPin:
    number: str
    position: Point
    net_id: str | None = None

    def __post_init__(self) -> None:
        _nonempty(self.number, "FallbackPin.number")
        _point(self.position, "FallbackPin.position")


@dataclass(frozen=True)
class PreviewComponent:
    id: str
    ref: str
    placement: Placement
    placed_pads: tuple[PlacedPad, ...]
    fallback_pins: tuple[FallbackPin, ...]
    has_pad_geometry: bool
    unresolved_footprint_badge: bool
    diagnostics: tuple[Diagnostic, ...]

    def __post_init__(self) -> None:
        _nonempty(self.id, "PreviewComponent.id")
        _nonempty(self.ref, "PreviewComponent.ref")
        _tuple(self.placed_pads, "PreviewComponent.placed_pads")
        _tuple(self.fallback_pins, "PreviewComponent.fallback_pins")
        _tuple(self.diagnostics, "PreviewComponent.diagnostics")


@dataclass(frozen=True)
class PreviewBoard:
    source_id: str
    name: str
    outline: BoardOutline | None
    layer_stack: LayerStack | None
    components: tuple[PreviewComponent, ...]
    diagnostics: tuple[Diagnostic, ...]

    def __post_init__(self) -> None:
        _nonempty(self.source_id, "PreviewBoard.source_id")
        _nonempty(self.name, "PreviewBoard.name")
        _tuple(self.components, "PreviewBoard.components")
        _tuple(self.diagnostics, "PreviewBoard.diagnostics")
        _unique_ids(self.components, "PreviewBoard.components")


@dataclass(frozen=True)
class ResolutionFailure:
    diagnostics: tuple[Diagnostic, ...]

    def __post_init__(self) -> None:
        _tuple(self.diagnostics, "ResolutionFailure.diagnostics")
        if not self.diagnostics:
            raise ValueError("ResolutionFailure requires diagnostics")
        if not any(d.severity is DiagnosticSeverity.ERROR for d in self.diagnostics):
            raise ValueError("ResolutionFailure requires at least one error")


@dataclass(frozen=True)
class ResolutionSuccess:
    board: "ResolvedBoard"
    diagnostics: tuple[Diagnostic, ...] = ()

    def __post_init__(self) -> None:
        _tuple(self.diagnostics, "ResolutionSuccess.diagnostics")
        if any(d.severity is DiagnosticSeverity.ERROR for d in self.diagnostics):
            raise ValueError("ResolutionSuccess cannot carry error diagnostics")


ResolutionResult: TypeAlias = ResolutionSuccess | ResolutionFailure


@dataclass(frozen=True)
class ResolvedBoard:
    id: str
    name: str
    outline: BoardOutline
    layer_stack: LayerStack
    design_rules: ResolvedDesignRules
    footprint_definitions: tuple["FootprintDefinition", ...]
    nets: tuple[ResolvedNet, ...]
    components: tuple[ResolvedComponent, ...]
    traces: tuple[ResolvedTrace, ...]
    vias: tuple[ResolvedVia, ...]
    holes: tuple[ResolvedHole, ...]
    zones: tuple[ResolvedZone, ...]
    board_graphics: tuple[BoardGraphic, ...]
    provenance: BoardProvenance

    def __post_init__(self) -> None:
        _nonempty(self.id, "ResolvedBoard.id")
        _nonempty(self.name, "ResolvedBoard.name")
        for field in (
            "footprint_definitions", "nets", "components", "traces", "vias",
            "holes", "zones", "board_graphics",
        ):
            _tuple(getattr(self, field), f"ResolvedBoard.{field}")

        footprint_ids = [definition.content_id for definition in self.footprint_definitions]
        if len(footprint_ids) != len(set(footprint_ids)):
            raise ValueError("ResolvedBoard has duplicate footprint content ids")
        for definition in self.footprint_definitions:
            if definition.unsupported or any(pad.unsupported for pad in definition.pads):
                raise ValueError(
                    "ResolvedBoard cannot contain unresolved footprint feature markers"
                )
        for field in ("nets", "components", "traces", "vias", "holes", "zones", "board_graphics"):
            _unique_ids(getattr(self, field), f"ResolvedBoard.{field}")
        segment_ids = [segment.id for trace in self.traces for segment in trace.segments]
        if len(segment_ids) != len(set(segment_ids)):
            raise ValueError("ResolvedBoard has duplicate trace segment ids")

        net_ids = {net.id for net in self.nets}
        net_class_ids = {item.id for item in self.design_rules.net_classes}
        if len({net.index for net in self.nets}) != len(self.nets):
            raise ValueError("ResolvedBoard net indices must be unique")
        if any(net.net_class_id and net.net_class_id not in net_class_ids for net in self.nets):
            raise ValueError("ResolvedNet references an unknown net class")
        if any(component.footprint_id not in footprint_ids for component in self.components):
            raise ValueError("ResolvedComponent references an unknown footprint definition")
        for component in self.components:
            definition = next(
                item for item in self.footprint_definitions
                if item.content_id == component.footprint_id
            )
            pad_sources = {item.source_id for item in definition.pads}
            graphic_sources = {item.source_id for item in definition.graphics}
            if any(pad.source_id not in pad_sources for pad in component.placed_pads):
                raise ValueError("PlacedPad references an unknown footprint pad")
            if any(graphic.source_id not in graphic_sources
                   for graphic in component.placed_graphics):
                raise ValueError("PlacedGraphic references an unknown footprint graphic")
            for pad in component.placed_pads:
                if pad.net_id is not None and pad.net_id not in net_ids:
                    raise ValueError("PlacedPad references an unknown net")
        if any(trace.net_id not in net_ids for trace in self.traces):
            raise ValueError("ResolvedTrace references an unknown net")
        if any(via.net_id not in net_ids for via in self.vias):
            raise ValueError("ResolvedVia references an unknown net")
        if any(zone.net_id is not None and zone.net_id not in net_ids for zone in self.zones):
            raise ValueError("ResolvedZone references an unknown net")
        for via in self.vias:
            if not self.layer_stack.is_legal_via_span(via.from_layer, via.to_layer):
                raise ValueError(f"ResolvedVia {via.id!r} has an illegal layer span")
            if via.kind not in self.design_rules.allowed_via_kinds:
                raise ValueError(f"ResolvedVia {via.id!r} uses a disallowed via kind")

        copper_ids = {layer.id for layer in self.layer_stack.copper}
        for trace in self.traces:
            if any(segment.layer.id not in copper_ids for segment in trace.segments):
                raise ValueError(f"ResolvedTrace {trace.id!r} uses an unknown copper layer")
        if any(zone.layer.id not in copper_ids for zone in self.zones):
            raise ValueError("ResolvedZone uses an unknown copper layer")

        pad_ids = {pad.id for component in self.components for pad in component.placed_pads}
        if len(pad_ids) != sum(len(component.placed_pads) for component in self.components):
            raise ValueError("ResolvedBoard has duplicate placed pad ids")
        for net in self.nets:
            if any(ref not in pad_ids for ref in net.pad_refs):
                raise ValueError(f"ResolvedNet {net.id!r} references an unknown pad")
        all_pad_refs = [pad_id for net in self.nets for pad_id in net.pad_refs]
        if len(all_pad_refs) != len(set(all_pad_refs)):
            raise ValueError("one placed pad cannot belong to multiple nets")
        declared_pad_net = {
            pad.id: pad.net_id
            for component in self.components
            for pad in component.placed_pads
            if pad.net_id is not None
        }
        indexed_pad_net = {
            pad_id: net.id for net in self.nets for pad_id in net.pad_refs
        }
        if declared_pad_net != indexed_pad_net:
            raise ValueError("PlacedPad.net_id and ResolvedNet.pad_refs disagree")

        if (self.provenance.rule_profile_ref is not None
                and self.provenance.rule_profile_ref != self.design_rules.rule_profile):
            raise ValueError("board and design-rule provenance disagree")

    @property
    def footprint_index(self) -> Mapping[str, "FootprintDefinition"]:
        return MappingProxyType({item.content_id: item for item in self.footprint_definitions})

    def footprint_for(self, component: ResolvedComponent) -> "FootprintDefinition":
        try:
            return self.footprint_index[component.footprint_id]
        except KeyError as exc:  # defensive: construction already validates
            raise KeyError(f"unknown footprint id {component.footprint_id!r}") from exc

    @property
    def net_index(self) -> Mapping[str, int]:
        return MappingProxyType({net.id: net.index for net in self.nets})

    @property
    def pad_net(self) -> Mapping[str, str]:
        return MappingProxyType({pad_id: net.id for net in self.nets for pad_id in net.pad_refs})
