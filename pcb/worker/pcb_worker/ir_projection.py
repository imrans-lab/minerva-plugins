"""Neutral IR->dict projection helpers shared by BOTH fab emitters (C5c).

The gerber and kicad emitters each need to project a couple of purely-geometric
:class:`~pcb_worker.resolved_board.ResolvedBoard` primitives into the loose dict
shape their harvest paths read. Those two projections — the board OUTLINE frame
and a placed silk/board GRAPHIC — are byte-identical between the emitters (the
board is board-ABSOLUTE in the IR, so neither emitter re-applies a transform),
so they live here ONCE instead of being duplicated per emitter.

Deliberately MINIMAL: only the genuinely-shared, emitter-neutral projections
belong here. Pad / component / net / trace / via / hole projection is NOT shared
— gerber builds a ``_Geometry`` while kicad builds an s-expression dict — so
those stay in their respective emitters.

Imports ONLY low-level model types (``resolved_board``); it must NEVER import
``gerber``/``kicad``/``methods`` (that would cycle). PURE + deterministic: the
inputs are only READ.
"""

from __future__ import annotations

from .resolved_board import (
    ArcGeometry,
    BoardOutline,
    CircleGeometry,
    LineGeometry,
    PlacedGraphic,
    PolygonGeometry,
    ProfileOutline,
    RectOutline,
)

__all__ = ["outline_frame", "graphic_to_dict"]


def outline_frame(outline: BoardOutline) -> tuple[float, float, float, float]:
    """(origin_x, origin_y, width_mm, height_mm) for the board frame — the IR
    board frame for Edge.Cuts + bounds. v1 compiles a :class:`RectOutline`; a
    :class:`ProfileOutline` (future) degrades to its outer-contour axis-aligned
    bounding box so Edge.Cuts still frames the board."""
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


def graphic_to_dict(graphic: PlacedGraphic) -> dict:
    """One board-ABSOLUTE :class:`PlacedGraphic` → the silk/board-graphic dict shape
    both emitters' harvest paths read. Under the IR's identity component placement
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
