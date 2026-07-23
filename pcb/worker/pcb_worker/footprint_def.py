"""Durable, KiCad-independent footprint definition contract.

The parser remains KiCad-specific; this module adapts its plain dictionaries
into immutable local geometry with stable definition-local identities,
provenance, and attributed unsupported-feature markers.  No placement or board
coordinates live here.  K2 is the sole constructor of placed projections.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
import math
from typing import Optional, TypeAlias

from .canonical_id import content_id as hash_content
from .pad_types import is_known_pad_type, normalize_pad_type, semantic_pad_type
from .resolved_board import (
    EntityKind,
    FeatureDomain,
    Layer,
    LayerRole,
    SourceRef,
    UnsupportedFeature,
)


Point = tuple[float, float]


def _point(raw, field_name: str) -> Point:
    if not isinstance(raw, (list, tuple)) or len(raw) < 2:
        raise ValueError(f"{field_name} must contain x/y")
    x, y = raw[0], raw[1]
    if not all(isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)
               for v in (x, y)):
        raise ValueError(f"{field_name} must contain finite x/y")
    return float(x), float(y)


class PadShape(str, Enum):
    RECT = "rect"
    ROUNDRECT = "roundrect"
    CIRCLE = "circle"
    OVAL = "oval"
    CUSTOM = "custom"
    TRAPEZOID = "trapezoid"
    CHAMFER = "chamfer"

    @classmethod
    def from_token(cls, token: Optional[str]) -> "PadShape":
        if not token:
            return cls.RECT
        try:
            return cls(token)
        except ValueError:
            return cls.CUSTOM

    @property
    def is_supported(self) -> bool:
        return self in {
            PadShape.RECT, PadShape.ROUNDRECT, PadShape.CIRCLE, PadShape.OVAL,
        }


@dataclass(frozen=True)
class DrillDefinition:
    shape: str
    size: tuple[float, float]
    plated: bool = True

    def __post_init__(self) -> None:
        if not self.shape:
            raise ValueError("DrillDefinition.shape must be non-empty")
        if not isinstance(self.size, tuple) or len(self.size) != 2:
            raise TypeError("DrillDefinition.size must be an immutable pair")
        if any(not isinstance(v, (int, float)) or isinstance(v, bool)
               or not math.isfinite(v) or v <= 0 for v in self.size):
            raise ValueError("DrillDefinition.size values must be finite and positive")
        if not isinstance(self.plated, bool):
            raise TypeError("DrillDefinition.plated must be bool")


@dataclass(frozen=True)
class PadDefinition:
    source_id: str
    number: str
    pad_type: str
    raw_pad_type: str | None
    shape: PadShape
    raw_shape: str | None
    position: Point
    size: tuple[float, float] | None
    rotation_deg: float = 0.0
    corner_rratio: float | None = None
    drill: DrillDefinition | None = None
    layers: tuple[Layer, ...] = ()
    solder_mask_margin: float | None = None
    solder_paste_margin: float | None = None
    unsupported: tuple[UnsupportedFeature, ...] = ()

    def __post_init__(self) -> None:
        if not self.source_id or not self.pad_type:
            raise ValueError("PadDefinition source_id and pad_type are required")
        if not isinstance(self.shape, PadShape):
            raise TypeError("PadDefinition.shape must be PadShape")
        _point(self.position, "PadDefinition.position")
        if self.size is not None:
            _point(self.size, "PadDefinition.size")
            if self.size[0] <= 0 or self.size[1] <= 0:
                raise ValueError("PadDefinition.size values must be positive")
        if (isinstance(self.rotation_deg, bool)
                or not isinstance(self.rotation_deg, (int, float))
                or not math.isfinite(self.rotation_deg)):
            raise ValueError("PadDefinition.rotation_deg must be finite")
        if self.corner_rratio is not None:
            if (isinstance(self.corner_rratio, bool)
                    or not isinstance(self.corner_rratio, (int, float))
                    or not math.isfinite(self.corner_rratio)
                    or not 0 <= self.corner_rratio <= 0.5):
                raise ValueError("PadDefinition.corner_rratio must be finite and in [0, 0.5]")
        for field_name in ("solder_mask_margin", "solder_paste_margin"):
            value = getattr(self, field_name)
            if value is not None and (
                isinstance(value, bool)
                or not isinstance(value, (int, float))
                or not math.isfinite(value)
            ):
                raise ValueError(f"PadDefinition.{field_name} must be finite")
        if not isinstance(self.layers, tuple) or not isinstance(self.unsupported, tuple):
            raise TypeError("PadDefinition collections must be tuples")
        if any(not isinstance(layer, Layer) for layer in self.layers):
            raise TypeError("PadDefinition.layers entries must be Layer values")
        if any(not isinstance(item, UnsupportedFeature) for item in self.unsupported):
            raise TypeError("PadDefinition.unsupported entries must be UnsupportedFeature")


def _graphic_common(source_id: str, width_mm: float | None) -> None:
    if not source_id:
        raise ValueError("graphic source_id must be non-empty")
    if width_mm is not None and (
        isinstance(width_mm, bool)
        or not isinstance(width_mm, (int, float))
        or not math.isfinite(width_mm)
        or width_mm < 0
    ):
        raise ValueError("graphic width_mm must be finite and nonnegative")


def _graphic_layer(layer: Layer) -> None:
    if not isinstance(layer, Layer):
        raise TypeError("graphic layer must be a Layer")


@dataclass(frozen=True)
class LineGraphic:
    source_id: str
    layer: Layer
    width_mm: float | None
    a: Point
    b: Point

    def __post_init__(self) -> None:
        _graphic_common(self.source_id, self.width_mm)
        _graphic_layer(self.layer)
        _point(self.a, "LineGraphic.a")
        _point(self.b, "LineGraphic.b")
        if self.a == self.b:
            raise ValueError("LineGraphic endpoints must differ")


@dataclass(frozen=True)
class CircleGraphic:
    source_id: str
    layer: Layer
    width_mm: float | None
    center: Point
    radius_mm: float

    def __post_init__(self) -> None:
        _graphic_common(self.source_id, self.width_mm)
        _graphic_layer(self.layer)
        _point(self.center, "CircleGraphic.center")
        if (isinstance(self.radius_mm, bool)
                or not isinstance(self.radius_mm, (int, float))
                or not math.isfinite(self.radius_mm) or self.radius_mm <= 0):
            raise ValueError("CircleGraphic.radius_mm must be finite and positive")


@dataclass(frozen=True)
class ArcGraphic:
    source_id: str
    layer: Layer
    width_mm: float | None
    start: Point
    mid: Point
    end: Point

    def __post_init__(self) -> None:
        _graphic_common(self.source_id, self.width_mm)
        _graphic_layer(self.layer)
        _point(self.start, "ArcGraphic.start")
        _point(self.mid, "ArcGraphic.mid")
        _point(self.end, "ArcGraphic.end")
        if len({self.start, self.mid, self.end}) < 3:
            raise ValueError("ArcGraphic start/mid/end must be distinct")


@dataclass(frozen=True)
class PolyGraphic:
    source_id: str
    layer: Layer
    width_mm: float | None
    points: tuple[Point, ...]

    def __post_init__(self) -> None:
        _graphic_common(self.source_id, self.width_mm)
        _graphic_layer(self.layer)
        if not isinstance(self.points, tuple):
            raise TypeError("PolyGraphic.points must be a tuple")
        if len(self.points) < 3:
            raise ValueError("PolyGraphic requires at least three points")
        for index, point in enumerate(self.points):
            _point(point, f"PolyGraphic.points[{index}]")


GraphicDefinition: TypeAlias = LineGraphic | CircleGraphic | ArcGraphic | PolyGraphic


@dataclass(frozen=True)
class Model3D:
    path: str | None = None


@dataclass(frozen=True)
class Provenance:
    source_id: str | None = None
    sha256: str | None = None
    license: str | None = None
    retrieved_at: str | None = None


def _source_ref(kind: EntityKind, entity_id: str, detail: str | None = None) -> SourceRef:
    return SourceRef(kind, entity_id or "<unknown>", detail)


def _layer_domain(layer: Layer | None) -> FeatureDomain:
    if layer is None:
        return FeatureDomain.DOCUMENTATION
    return {
        LayerRole.COPPER: FeatureDomain.COPPER,
        LayerRole.MASK: FeatureDomain.MASK,
        LayerRole.PASTE: FeatureDomain.PASTE,
        LayerRole.SILK: FeatureDomain.SILK,
        LayerRole.FAB: FeatureDomain.FAB,
    }.get(layer.role, FeatureDomain.DOCUMENTATION)


def _raw_marker(
    raw: dict,
    source_ref: SourceRef,
    *,
    pad_layers: tuple[Layer, ...] = (),
) -> UnsupportedFeature:
    feature = str(raw.get("feature") or "unsupported_feature")
    raw_layer = raw.get("layer")
    layer = Layer.from_id(raw_layer) if isinstance(raw_layer, str) and raw_layer else None

    if feature == "custom_primitives":
        domain, blocking = FeatureDomain.COPPER, True
    elif feature == "pad_drill_offset":
        domain, blocking = FeatureDomain.DRILL, True
    elif feature == "chamfer":
        domain, blocking = FeatureDomain.COPPER, True
    elif feature == "local_clearance":
        domain, blocking = FeatureDomain.RULES, True
    elif feature == "zone_connect":
        domain, blocking = FeatureDomain.COPPER, False
    elif feature in {"unknown_pad_type", "unknown_pad_shape", "pad_position_missing"}:
        domain, blocking = FeatureDomain.COPPER, True
    else:
        domain = _layer_domain(layer)
        blocking = domain in {
            FeatureDomain.COPPER, FeatureDomain.DRILL,
            FeatureDomain.MASK, FeatureDomain.PASTE,
        }

    if layer is None and pad_layers:
        # A pad marker without a single source layer affects the strongest
        # fabrication domain represented by its layer selector set.
        roles = {item.role for item in pad_layers}
        if LayerRole.COPPER in roles:
            domain = FeatureDomain.COPPER

    outputs = (layer.id,) if layer is not None else (domain.value,)
    return UnsupportedFeature(
        feature=feature,
        domain=domain,
        affected_layer=layer,
        affected_outputs=outputs,
        default_blocking=blocking,
        detail=str(raw.get("detail") or feature),
        source_ref=source_ref,
    )


def _rotate_clockwise(point: Point, degrees: float, center: Point) -> Point:
    """KiCad's file-coordinate rotation (Y grows downward)."""
    radians = math.radians(-degrees)
    c, s = math.cos(radians), math.sin(radians)
    x, y = point[0] - center[0], point[1] - center[1]
    return center[0] + x * c - y * s, center[1] + x * s + y * c


def _legacy_arc(
    source_id: str,
    layer: Layer,
    width: float | None,
    points: list,
    angle_deg: float,
) -> GraphicDefinition | None:
    """Normalize KiCad legacy center/start/sweep into a three-point arc.

    Despite the s-expression labels ``start`` and ``end``, legacy KiCad's first
    parsed point is the arc CENTER and its second is the arc START.  This is
    pinned by the real DIP-6 notch and the existing Gerber oracle.
    """
    if len(points) < 2 or not math.isfinite(angle_deg):
        return None
    center = _point(points[0], "legacy arc center")
    start = _point(points[1], "legacy arc start")
    radius = math.hypot(start[0] - center[0], start[1] - center[1])
    if radius == 0 or abs(angle_deg) < 1e-6:
        return None
    if abs(angle_deg) >= 360.0 - 1e-9:
        return CircleGraphic(source_id, layer, width, center, radius)
    mid = _rotate_clockwise(start, angle_deg / 2.0, center)
    end = _rotate_clockwise(start, angle_deg, center)
    return ArcGraphic(source_id, layer, width, start, mid, end)


def _graphic_to_payload(graphic: GraphicDefinition) -> dict:
    common = {
        "source_id": graphic.source_id,
        "layer": {"id": graphic.layer.id, "role": graphic.layer.role.value,
                  "side": graphic.layer.side.value if graphic.layer.side else None},
        "width_mm": graphic.width_mm,
    }
    if isinstance(graphic, LineGraphic):
        return {**common, "kind": "line", "a": graphic.a, "b": graphic.b}
    if isinstance(graphic, CircleGraphic):
        return {**common, "kind": "circle", "center": graphic.center,
                "radius_mm": graphic.radius_mm}
    if isinstance(graphic, ArcGraphic):
        return {**common, "kind": "arc", "start": graphic.start,
                "mid": graphic.mid, "end": graphic.end}
    return {**common, "kind": "poly", "points": graphic.points}


def _unsupported_to_payload(marker: UnsupportedFeature) -> dict:
    return {
        "feature": marker.feature,
        "domain": marker.domain.value,
        "affected_layer": marker.affected_layer.id if marker.affected_layer else None,
        "affected_outputs": marker.affected_outputs,
        "default_blocking": marker.default_blocking,
        "detail": marker.detail,
        "source_ref": {
            "entity_kind": marker.source_ref.entity_kind.value,
            "entity_id": marker.source_ref.entity_id,
            "detail": marker.source_ref.detail,
        },
    }


@dataclass(frozen=True)
class FootprintDefinition:
    name: str
    pads: tuple[PadDefinition, ...] = ()
    graphics: tuple[GraphicDefinition, ...] = ()
    model3d: Model3D | None = None
    provenance: Provenance | None = None
    unsupported: tuple[UnsupportedFeature, ...] = ()
    content_id: str = field(init=False)

    def __post_init__(self) -> None:
        if not self.name:
            raise ValueError("FootprintDefinition.name must be non-empty")
        if not isinstance(self.pads, tuple) or not isinstance(self.graphics, tuple):
            raise TypeError("FootprintDefinition pads/graphics must be tuples")
        if not isinstance(self.unsupported, tuple):
            raise TypeError("FootprintDefinition.unsupported must be a tuple")
        if any(not isinstance(item, PadDefinition) for item in self.pads):
            raise TypeError("FootprintDefinition.pads entries must be PadDefinition")
        if any(not isinstance(item, (LineGraphic, CircleGraphic, ArcGraphic, PolyGraphic))
               for item in self.graphics):
            raise TypeError("FootprintDefinition.graphics has an unknown variant")
        if any(not isinstance(item, UnsupportedFeature) for item in self.unsupported):
            raise TypeError("FootprintDefinition.unsupported entries must be UnsupportedFeature")
        source_ids = [item.source_id for item in (*self.pads, *self.graphics)]
        if len(source_ids) != len(set(source_ids)):
            raise ValueError("FootprintDefinition source ids must be unique")
        payload = {
            "name": self.name,
            "pads": [self._pad_payload(pad) for pad in self.pads],
            "graphics": [_graphic_to_payload(graphic) for graphic in self.graphics],
            "model3d": self.model3d.path if self.model3d else None,
            "unsupported": [_unsupported_to_payload(item) for item in self.unsupported],
        }
        object.__setattr__(self, "content_id", hash_content(payload))

    @staticmethod
    def _pad_payload(pad: PadDefinition) -> dict:
        return {
            "source_id": pad.source_id,
            "number": pad.number,
            "pad_type": pad.pad_type,
            "raw_pad_type": pad.raw_pad_type,
            "shape": pad.shape.value,
            "raw_shape": pad.raw_shape,
            "position": pad.position,
            "size": pad.size,
            "rotation_deg": pad.rotation_deg,
            "corner_rratio": pad.corner_rratio,
            "drill": None if pad.drill is None else {
                "shape": pad.drill.shape,
                "size": pad.drill.size,
                "plated": pad.drill.plated,
            },
            "layers": [
                {"id": layer.id, "role": layer.role.value,
                 "side": layer.side.value if layer.side else None}
                for layer in pad.layers
            ],
            "solder_mask_margin": pad.solder_mask_margin,
            "solder_paste_margin": pad.solder_paste_margin,
            "unsupported": [_unsupported_to_payload(item) for item in pad.unsupported],
        }

    @classmethod
    def from_kicad_parsed(
        cls,
        parsed: dict,
        provenance: Provenance | None = None,
    ) -> "FootprintDefinition":
        name = str(parsed.get("name") or "")
        pads: list[PadDefinition] = []
        footprint_markers: list[UnsupportedFeature] = []
        occurrences: dict[str, int] = {}

        for raw in parsed.get("pads", ()):
            if not isinstance(raw, dict):
                continue
            number = str(raw.get("number", ""))
            ordinal = occurrences.get(number, 0)
            occurrences[number] = ordinal + 1
            source_id = f"pad:{number}:{ordinal}"
            source_ref = _source_ref(EntityKind.PAD, source_id, f"footprint {name}")
            x, y = raw.get("x_mm"), raw.get("y_mm")
            if not all(isinstance(v, (int, float)) and not isinstance(v, bool)
                       and math.isfinite(v) for v in (x, y)):
                footprint_markers.append(_raw_marker({
                    "feature": "pad_position_missing",
                    "detail": f"pad {number!r} has no finite local position",
                }, source_ref))
                continue

            layers = tuple(
                Layer.from_id(value) for value in (raw.get("layers") or ())
                if isinstance(value, str) and value
            )
            marker_list = [
                _raw_marker(item, source_ref, pad_layers=layers)
                for item in (raw.get("unsupported") or ()) if isinstance(item, dict)
            ]
            raw_pad_type = raw.get("type") if isinstance(raw.get("type"), str) else None
            if not is_known_pad_type(raw_pad_type):
                marker_list.append(_raw_marker({
                    "feature": "unknown_pad_type",
                    "detail": f"pad {number!r} has unknown type {raw_pad_type!r}",
                }, source_ref, pad_layers=layers))
            raw_shape = raw.get("shape") if isinstance(raw.get("shape"), str) else None
            shape = PadShape.from_token(raw_shape)
            if raw_shape and raw_shape not in {item.value for item in PadShape}:
                marker_list.append(_raw_marker({
                    "feature": "unknown_pad_shape",
                    "detail": f"pad {number!r} has unknown shape {raw_shape!r}",
                }, source_ref, pad_layers=layers))

            raw_size = raw.get("size")
            size = None
            if (isinstance(raw_size, (list, tuple)) and len(raw_size) >= 2
                    and raw_size[0] is not None and raw_size[1] is not None):
                size = float(raw_size[0]), float(raw_size[1])

            drill = None
            raw_drill = raw.get("drill")
            drill_size = raw.get("drill_size")
            if isinstance(drill_size, (list, tuple)) and drill_size:
                dimensions = [float(value) for value in drill_size
                              if isinstance(value, (int, float)) and not isinstance(value, bool)]
                if len(dimensions) == 1:
                    dimensions.append(dimensions[0])
                if len(dimensions) >= 2:
                    drill = DrillDefinition(
                        str(raw.get("drill_shape") or "oval"),
                        (dimensions[0], dimensions[1]),
                        plated=(semantic_pad_type(raw_pad_type) != "np_thru_hole"),
                    )
            elif isinstance(raw_drill, (int, float)) and not isinstance(raw_drill, bool):
                drill = DrillDefinition(
                    "round", (float(raw_drill), float(raw_drill)),
                    plated=(semantic_pad_type(raw_pad_type) != "np_thru_hole"),
                )

            pads.append(PadDefinition(
                source_id=source_id,
                number=number,
                pad_type=semantic_pad_type(raw_pad_type),
                raw_pad_type=raw_pad_type,
                shape=shape,
                raw_shape=raw_shape,
                position=(float(x), float(y)),
                size=size,
                rotation_deg=float(raw.get("rotation") or 0.0),
                corner_rratio=raw.get("roundrect_rratio"),
                drill=drill,
                layers=layers,
                solder_mask_margin=raw.get("solder_mask_margin"),
                solder_paste_margin=raw.get("solder_paste_margin"),
                unsupported=tuple(marker_list),
            ))

        graphics: list[GraphicDefinition] = []
        for ordinal, raw in enumerate(parsed.get("graphics", ())):
            if not isinstance(raw, dict):
                continue
            source_id = f"graphic:{ordinal}"
            layer = Layer.from_id(str(raw.get("layer") or "User.Unknown"))
            width = raw.get("width")
            width = float(width) if isinstance(width, (int, float)) else None
            kind = raw.get("kind")
            try:
                if kind == "line":
                    graphic = LineGraphic(
                        source_id, layer, width,
                        _point(raw.get("start"), "line.start"),
                        _point(raw.get("end"), "line.end"),
                    )
                elif kind == "circle":
                    radius = raw.get("radius")
                    if not isinstance(radius, (int, float)) or radius <= 0:
                        raise ValueError("circle radius must be positive")
                    graphic = CircleGraphic(
                        source_id, layer, width,
                        _point(raw.get("center"), "circle.center"), float(radius),
                    )
                elif kind == "arc":
                    points = raw.get("points") or []
                    angle = raw.get("angle")
                    if isinstance(angle, (int, float)):
                        graphic = _legacy_arc(source_id, layer, width, points, float(angle))
                        if graphic is None:
                            raise ValueError("degenerate legacy arc")
                    elif len(points) >= 3:
                        graphic = ArcGraphic(
                            source_id, layer, width,
                            _point(points[0], "arc.start"),
                            _point(points[1], "arc.mid"),
                            _point(points[2], "arc.end"),
                        )
                    else:
                        raise ValueError("arc needs start/mid/end")
                elif kind == "poly":
                    points = tuple(_point(point, "poly.point") for point in raw.get("points", ()))
                    if len(points) < 3:
                        raise ValueError("poly needs at least three points")
                    graphic = PolyGraphic(source_id, layer, width, points)
                else:
                    raise ValueError(f"unknown graphic kind {kind!r}")
                graphics.append(graphic)
            except (TypeError, ValueError) as exc:
                footprint_markers.append(_raw_marker({
                    "feature": "malformed_graphic",
                    "layer": layer.id,
                    "detail": f"graphic {ordinal}: {exc}",
                }, _source_ref(EntityKind.GRAPHIC, source_id, f"footprint {name}")))

        footprint_markers.extend(
            _raw_marker(
                item,
                _source_ref(EntityKind.FOOTPRINT, name or "<unnamed>"),
            )
            for item in (parsed.get("unsupported") or ()) if isinstance(item, dict)
        )
        return cls(
            name=name,
            pads=tuple(pads),
            graphics=tuple(graphics),
            provenance=provenance,
            unsupported=tuple(footprint_markers),
        )

    def to_board_pad_dicts(self) -> list:
        """Legacy panel DTO adapter; intentionally absent from the future IR path."""
        out = []
        for pad in self.pads:
            drill_dict = ({"x": pad.drill.size[0], "y": pad.drill.size[1]}
                          if pad.drill else {"x": 0.0, "y": 0.0})
            size_dict = ({"width": pad.size[0], "height": pad.size[1]}
                         if pad.size is not None else {"width": None, "height": None})
            pad_dict = {
                "number": pad.number,
                "type": normalize_pad_type(pad.pad_type),
                "shape": pad.shape.value,
                "position": {"x": pad.position[0], "y": pad.position[1]},
                "size": size_dict,
                "drill": drill_dict,
                "layers": [layer.id for layer in pad.layers],
            }
            # SB2 (019f8acfd651): thread the fab-affecting optionals in exact
            # parity with resolve._pads_from_parsed (the round-trip invariant).
            # corner_rratio + margins only when present; a 0/absent rotation is
            # omitted (rotation_deg defaults to 0.0 and can't encode "absent").
            if pad.corner_rratio is not None:
                pad_dict["corner_rratio"] = pad.corner_rratio
            for key, val in (("solder_mask_margin", pad.solder_mask_margin),
                             ("solder_paste_margin", pad.solder_paste_margin)):
                if val is not None:
                    pad_dict[key] = val
            if pad.rotation_deg:
                pad_dict["rotation"] = pad.rotation_deg
            if pad.raw_shape is not None:
                pad_dict["raw_shape"] = pad.raw_shape   # D1 provenance parity
            out.append(pad_dict)
        return out
