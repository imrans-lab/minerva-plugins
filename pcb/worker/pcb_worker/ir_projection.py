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

import math

from .resolved_board import (
    ArcGeometry,
    BoardOutline,
    CircleGeometry,
    LineGeometry,
    PlacedGraphic,
    PolygonGeometry,
    ProfileOutline,
    RectOutline,
    ResolvedCutout,
)

__all__ = [
    "outline_frame",
    "profile_outer_rect",
    "outline_cutouts",
    "cutout_point_loops",
    "cutout_dicts",
    "cutout_loops_from_dict",
    "graphic_to_dict",
]


def profile_outer_rect(outline: ProfileOutline) -> tuple[float, float, float, float] | None:
    """The (origin_x, origin_y, width_mm, height_mm) frame of a
    :class:`ProfileOutline` whose OUTER contour is an axis-aligned rectangle —
    the one outer shape v1's compiler constructs — or ``None`` when the outer
    is anything else. Consumers that can only model a rectangular board rim
    (geometric DRC, routing, zone fill) use ``None`` as their refusal signal
    instead of each hand-rolling a shape test."""
    segments = outline.outer.segments
    if len(segments) != 4:
        return None
    corners: list[tuple[float, float]] = []
    for seg in segments:
        if not isinstance(seg, LineGeometry):
            return None
        if seg.a[0] != seg.b[0] and seg.a[1] != seg.b[1]:
            return None  # not axis-aligned
        corners.append((float(seg.a[0]), float(seg.a[1])))
    xs = sorted({c[0] for c in corners})
    ys = sorted({c[1] for c in corners})
    if len(xs) != 2 or len(ys) != 2:
        return None
    if {(x, y) for x in xs for y in ys} != set(corners):
        return None
    return xs[0], ys[0], xs[1] - xs[0], ys[1] - ys[0]


def outline_frame(outline: BoardOutline) -> tuple[float, float, float, float]:
    """(origin_x, origin_y, width_mm, height_mm) for the board frame — the IR
    board frame for Edge.Cuts + bounds.

    A :class:`ProfileOutline` yields a frame ONLY when its outer contour is an
    axis-aligned rectangle; any other outer RAISES instead of degrading to a
    bounding box. The old silent-bbox fallback was the worst fail-open on the
    fabrication path (docket 019fbd30f7): the bbox of a shaped outer is a lie
    both emitters would fabricate. Cutouts do not change the frame — consumers
    that must honour them read :func:`outline_cutouts`."""
    if isinstance(outline, RectOutline):
        return outline.origin[0], outline.origin[1], outline.width_mm, outline.height_mm
    if isinstance(outline, ProfileOutline):
        frame = profile_outer_rect(outline)
        if frame is None:
            raise ValueError(
                "ProfileOutline outer contour is not an axis-aligned rectangle; "
                "refusing to frame it as one (a bounding-box frame silently "
                "reshapes the board — docket 019fbd30f7)")
        return frame
    raise TypeError(f"unsupported board outline {type(outline)!r}")


def outline_cutouts(outline: BoardOutline) -> tuple[ResolvedCutout, ...]:
    """The board's interior cutouts: ``()`` for a plain :class:`RectOutline`."""
    if isinstance(outline, ProfileOutline):
        return outline.cutouts
    return ()


def cutout_point_loops(outline: BoardOutline) -> list[tuple[str, list[tuple[float, float]]]]:
    """Each cutout as ``(id, [(x_mm, y_mm), ...])`` vertex loop (closing edge
    implied). RAISES on an arc contour segment: flattening an arc is a
    tessellation-tolerance decision this projection must not invent — an
    under-flattened Edge.Cuts arc would fabricate a different opening than the
    author drew (same doctrine as route_bridge._keepout_obstacle)."""
    loops: list[tuple[str, list[tuple[float, float]]]] = []
    for cut in outline_cutouts(outline):
        points: list[tuple[float, float]] = []
        for seg in cut.contour.segments:
            if not isinstance(seg, LineGeometry):
                raise ValueError(
                    f"cutout {cut.id}: contour carries a {type(seg).__name__} "
                    f"segment; fab projection models straight-edged cutouts only")
            points.append((float(seg.a[0]), float(seg.a[1])))
        loops.append((cut.id, points))
    return loops


def cutout_dicts(outline: BoardOutline) -> list[dict]:
    """IR cutouts in the CANONICAL loose-dict shape (``{"id", "outline":
    [{"x_mm", "y_mm"}, ...]}``) — the same shape a canonical board YAML/dict
    carries, so both emitters read ONE shape regardless of which entry path
    (IR or loose dict) fed them."""
    return [
        {"id": cut_id, "outline": [{"x_mm": x, "y_mm": y} for (x, y) in points]}
        for cut_id, points in cutout_point_loops(outline)
    ]


def cutout_loops_from_dict(board: dict) -> list[tuple[str | None, list[tuple[float, float]]]]:
    """Parse a loose board dict's canonical ``cutouts`` list into
    ``(id_or_None, [(x_mm, y_mm), ...])`` loops. STRICT: emitters run
    post-validation, so a malformed entry here is a broken invariant and
    raises rather than being silently dropped (the fabricated board would be
    missing an opening)."""
    raw = board.get("cutouts")
    if raw is None:
        return []
    if not isinstance(raw, list):
        raise ValueError(f"board cutouts must be a list; got {type(raw).__name__}")
    loops: list[tuple[str | None, list[tuple[float, float]]]] = []
    for ordinal, entry in enumerate(raw):
        if not isinstance(entry, dict):
            raise ValueError(f"cutout {ordinal}: entry must be a mapping")
        cut_id = entry.get("id")
        points: list[tuple[float, float]] = []
        outline_pts = entry.get("outline")
        if not isinstance(outline_pts, list) or len(outline_pts) < 3:
            raise ValueError(f"cutout {ordinal}: outline needs at least three points")
        for index, item in enumerate(outline_pts):
            if isinstance(item, dict):
                x, y = item.get("x_mm"), item.get("y_mm")
            elif isinstance(item, (list, tuple)) and len(item) == 2:
                x, y = item[0], item[1]
            else:
                raise ValueError(f"cutout {ordinal}: point[{index}] is malformed ({item!r})")
            if (isinstance(x, bool) or isinstance(y, bool)
                    or not isinstance(x, (int, float)) or not isinstance(y, (int, float))
                    or not math.isfinite(x) or not math.isfinite(y)):
                raise ValueError(f"cutout {ordinal}: point[{index}] has non-numeric coordinates")
            points.append((float(x), float(y)))
        loops.append((cut_id if isinstance(cut_id, str) and cut_id else None, points))
    return loops


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
