"""THE BOARD AS 2D AREA: the outline, less its cutouts, less every drill.

One step, and the only one in the 3D path that needs exact arithmetic. It hands
:mod:`substrate_mesh` a set of regions — an outer boundary with holes inside it —
that are guaranteed simple, correctly nested and consistently wound, which is
precisely the input an ear-clipping triangulator needs and cannot check for
itself.

WHY A BOOLEAN AND NOT "OUTLINE PLUS A LIST OF HOLE RINGS". Because holes on a
real board are not disjoint interior discs. Two vias 0.2 mm apart overlap once
their bores are drawn; a mounting hole can straddle the rim; a pad drill can sit
inside a cutout that already removed it. Feeding overlapping rings to a
triangulator is undefined behaviour, and hand-rolling the merge is writing a
polygon boolean badly. ``pyclipper`` is already a hard dependency of this worker
(copper-zone fill cannot run without it), it does this exactly in 64-bit
INTEGER arithmetic, and its PolyTree hands back the nesting already worked out.

THE INTEGER DOMAIN is nanometres, the same one ``zone_fill`` works in, so a
coordinate means the same thing in both and both are bit-reproducible rather
than dependent on float rounding. The constants are restated here rather than
imported so the 3D path does not drag the copper-fill module (and the whole DRC
primitive stack behind it) into its import graph for two integers.

CURVES ARE FLATTENED BY THE OFFSET, never by hand: a drill's capsule core is
offset by its radius with round joins, so a round bore, an oval and a routed
slot are one code path and the polygon is INSCRIBED in the true circle. Erring
inward means a rendered bore is never LARGER than the drilled one, which is the
safe direction for the thing this export exists for — checking a board against
an enclosure.
"""

from __future__ import annotations

from dataclasses import dataclass

from .board_drills import DrillOpening, drill_openings
from .earcut import signed_area
from .ir_projection import cutout_point_loops
from .resolved_board import LineGeometry, ProfileOutline, RectOutline, ResolvedBoard

Point = tuple[float, float]

#: Millimetres -> integer nanometres, matching ``zone_fill.NM_PER_MM``.
NM_PER_MM = 1_000_000

#: Largest deviation allowed when a round join is flattened to segments:
#: 0.005 mm, the same figure ``zone_fill`` uses and KiCad calls ARC_HIGH_DEF. At
#: that tolerance the smallest bore a board carries (a 0.3 mm via) becomes a
#: 12-gon and a 3 mm mounting hole a 78-gon — round to any eye at any sane
#: viewing distance, and bounded enough that a via-heavy board stays in the low
#: tens of thousands of triangles. It MUST be set explicitly: pyclipper's
#: default is 0.25 in the active unit, which here would mean quarter-NANOMETRE
#: circles, i.e. tens of thousands of vertices per via.
ARC_TOLERANCE_NM = 5_000


@dataclass(frozen=True)
class Region:
    """One connected piece of board: an outer boundary and its holes.

    Rings are BOARD-frame millimetres, open (no repeated closing point). The
    outer ring is positively wound and every hole negatively, as
    :mod:`earcut` requires. A board normally has exactly one region; a shape
    that a cutout or an oversized slot severs in two has more, and that is a
    fact worth carrying rather than a case to refuse.
    """

    outer: tuple[Point, ...]
    holes: tuple[tuple[Point, ...], ...] = ()

    def area_mm2(self) -> float:
        return abs(signed_area(self.outer)) - sum(abs(signed_area(h)) for h in self.holes)


def board_regions(board: ResolvedBoard) -> tuple[Region, ...]:
    """The board's material area: outline - cutouts - drills."""
    return subtract(outline_ring(board), cutout_rings(board) + drill_rings(board))


def outline_ring(board: ResolvedBoard) -> tuple[Point, ...]:
    """The board's outer boundary as a vertex ring, in board millimetres.

    A :class:`RectOutline` is its four corners. A :class:`ProfileOutline` is its
    outer contour's segment starts — straight segments only. An arc RAISES, the
    same refusal ``ir_projection.cutout_point_loops`` and ``zone_fill`` make:
    the tolerance to flatten a board EDGE at is a fabrication decision, and this
    module has no standing to invent one for a shape somebody will measure an
    enclosure against. (Today the refusal is academic — a shaped outer cannot be
    registered for a texture either, since ``ir_projection.outline_frame`` frames
    axis-aligned rectangles only.)
    """
    outline = board.outline
    if isinstance(outline, RectOutline):
        ox, oy = outline.origin
        w, h = outline.width_mm, outline.height_mm
        return ((ox, oy), (ox + w, oy), (ox + w, oy + h), (ox, oy + h))
    if isinstance(outline, ProfileOutline):
        points: list[Point] = []
        for segment in outline.outer.segments:
            if not isinstance(segment, LineGeometry):
                raise ValueError(
                    f"board outline carries a {type(segment).__name__} segment; the "
                    f"3D substrate models straight-edged outlines only and will not "
                    f"invent an arc tolerance for a board edge")
            points.append((float(segment.a[0]), float(segment.a[1])))
        if len(points) < 3:
            raise ValueError("board outline collapses to fewer than three points")
        return tuple(points)
    raise TypeError(f"unsupported board outline {type(outline).__name__}")


def cutout_rings(board: ResolvedBoard) -> tuple[tuple[Point, ...], ...]:
    """Interior openings authored on the outline, in board millimetres."""
    return tuple(tuple(loop) for (_cut_id, loop) in cutout_point_loops(board.outline))


def drill_rings(board: ResolvedBoard,
                openings: tuple[DrillOpening, ...] | None = None
                ) -> tuple[tuple[Point, ...], ...]:
    """Every drilled opening as a closed ring, true to its shape.

    ``openings`` lets a caller that already harvested them (to report what it
    cut, say) avoid harvesting twice.
    """
    pc = _pyclipper()
    rings: list[tuple[Point, ...]] = []
    for opening in (drill_openings(board) if openings is None else openings):
        offset = pc.PyclipperOffset()
        offset.ArcTolerance = ARC_TOLERANCE_NM
        offset.AddPath(_to_nm_path(opening.core), pc.JT_ROUND, pc.ET_OPENROUND)
        for path in offset.Execute(opening.radius_mm * NM_PER_MM):
            rings.append(_to_mm_ring(path))
    return tuple(rings)


def subtract(outer: tuple[Point, ...],
             clips: tuple[tuple[Point, ...], ...]) -> tuple[Region, ...]:
    """``outer`` minus every ring in ``clips``, as properly nested regions."""
    pc = _pyclipper()
    clipper = pc.Pyclipper()
    clipper.AddPath(_to_nm_path(outer), pc.PT_SUBJECT, True)
    usable = [_to_nm_path(ring) for ring in clips if len(ring) >= 3]
    if usable:
        clipper.AddPaths(usable, pc.PT_CLIP, True)
    tree = clipper.Execute2(pc.CT_DIFFERENCE, pc.PFT_NONZERO, pc.PFT_NONZERO)
    regions: list[Region] = []
    _collect(tree, regions)
    return tuple(regions)


def partition(region: Region, cell_mm: float, clearance_mm: float) -> tuple[Region, ...]:
    """``region`` cut into grid cells of about ``cell_mm``, each a region of
    its own (an outer ring and the holes wholly inside it).

    A grid line is nudged off any ring's extreme x or y by ``clearance_mm``:
    a line grazing a bore's rim would shave off a lens a fraction of a
    millimetre wide, and that lens is exactly the needle the partition exists
    to prevent. Cells are exact integer booleans, so two neighbours share
    identical vertices along their common line and weld without a seam.
    """
    pc = _pyclipper()
    xs = [p[0] for p in region.outer]
    ys = [p[1] for p in region.outer]
    avoid_x: set[float] = set()
    avoid_y: set[float] = set()
    for ring in (region.outer,) + region.holes:
        rx = [p[0] for p in ring]
        ry = [p[1] for p in ring]
        avoid_x.update((min(rx), max(rx)))
        avoid_y.update((min(ry), max(ry)))
    grid_x = [min(xs)] + _grid_lines(min(xs), max(xs), cell_mm, avoid_x, clearance_mm) + [max(xs)]
    grid_y = [min(ys)] + _grid_lines(min(ys), max(ys), cell_mm, avoid_y, clearance_mm) + [max(ys)]

    subject = [_to_nm_path(region.outer)] + [_to_nm_path(h) for h in region.holes]
    cells: list[Region] = []
    for x0, x1 in zip(grid_x, grid_x[1:]):
        for y0, y1 in zip(grid_y, grid_y[1:]):
            clipper = pc.Pyclipper()
            clipper.AddPaths(subject, pc.PT_SUBJECT, True)
            clipper.AddPath(_to_nm_path(((x0, y0), (x1, y0), (x1, y1), (x0, y1))),
                            pc.PT_CLIP, True)
            tree = clipper.Execute2(pc.CT_INTERSECTION, pc.PFT_NONZERO, pc.PFT_NONZERO)
            _collect(tree, cells)
    return tuple(cells)


def _grid_lines(lo: float, hi: float, pitch: float, avoid: set[float],
                clearance: float) -> list[float]:
    """Interior grid coordinates at about ``pitch``, each pushed clear of
    every value in ``avoid``."""
    lines: list[float] = []
    x = lo + pitch
    while x < hi - clearance:
        line = x
        for _ in range(16):
            near = [a for a in avoid if abs(a - line) < clearance]
            if not near:
                break
            a = min(near, key=lambda v: abs(v - line))
            line = a + clearance if line >= a else a - clearance
        if lo + clearance < line < hi - clearance:
            lines.append(line)
        x += pitch
    return lines


def _collect(node, regions: list[Region]) -> None:
    """Walk a PolyTree: every solid node is a region, its children are its holes,
    and an island nested inside a hole is a region in its own right."""
    for child in node.Childs:
        if child.IsHole:
            _collect(child, regions)
            continue
        holes = tuple(_oriented(_to_mm_ring(h.Contour), positive=False)
                      for h in child.Childs if len(h.Contour) >= 3)
        regions.append(Region(outer=_oriented(_to_mm_ring(child.Contour), positive=True),
                              holes=holes))
        for hole in child.Childs:
            _collect(hole, regions)


def _oriented(ring: tuple[Point, ...], *, positive: bool) -> tuple[Point, ...]:
    """The ring wound the way :mod:`earcut` expects, so no consumer has to guess.

    Clipper already returns solids and holes oppositely wound; normalising here
    anyway costs one shoelace pass and removes a silent dependency on which way
    round that library happens to be.
    """
    if (signed_area(ring) >= 0.0) == positive:
        return ring
    return tuple(reversed(ring))


def _to_nm_path(points) -> list[tuple[int, int]]:
    """Board millimetres -> integer nanometres, round-half-even like zone_fill:
    truncation would bias every coordinate toward the origin and turn a
    symmetric bore into an asymmetric one."""
    return [(int(round(x * NM_PER_MM)), int(round(y * NM_PER_MM))) for (x, y) in points]


def _to_mm_ring(path) -> tuple[Point, ...]:
    return tuple((x / NM_PER_MM, y / NM_PER_MM) for (x, y) in path)


def _pyclipper():
    """Import pyclipper, or fail with an actionable message — the same lazy
    import ``zone_fill`` uses, for the same reason: nothing on the cold-start
    path needs a polygon boolean."""
    try:
        import pyclipper  # noqa: PLC0415  (deliberate lazy import)
    except Exception as exc:                # pragma: no cover - install-time only
        raise RuntimeError(
            "pyclipper is not installed; the 3D substrate needs an exact integer "
            "polygon boolean to cut holes through the board "
            f"(pip install 'pyclipper==1.4.0'): {exc}") from exc
    return pyclipper
