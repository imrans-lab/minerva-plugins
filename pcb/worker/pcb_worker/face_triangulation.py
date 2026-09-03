"""A board face triangulated so that a viewer can draw it.

:mod:`earcut` fills a face correctly and badly: ear clipping with hole
bridging fans needle triangles from a corner across the whole board (a
100 mm edge on a 90 mm board) and clips ears out of three consecutive
vertices of a polygonised bore whose thickness is the arc tolerance itself.
A needle thinner than a screen pixel rasterises as a broken line, and a GPU's
screen-space derivatives on it are garbage, so it shades differently from its
neighbours — the owner saw them as dashed rays from the origin on the first
rev B export. Nothing structural catches this: the area is right, the shell is
closed, every hole is open.

Two passes fix what ear clipping does, with no new dependency:

1. PARTITION the region into grid cells (:func:`board_region.partition`,
   pyclipper) and clip each cell alone. No bridge and no fan can be longer
   than a cell. The grid lines are nudged away from every ring's extreme
   coordinates so a line does not shave a lens off a bore.
2. FLIP every interior edge that fails the Delaunay circumcircle test (Lawson's
   algorithm), never a ring edge. From any valid triangulation this converges
   to the constrained Delaunay triangulation of the cell, which maximises the
   smallest angle the point set allows.

What remains thin is inherent to the points — two aligned bores whose extreme
vertices are collinear to within their arc tolerance — and those needles are
now short (a hole pitch) rather than the board's diagonal. Measured on rev B:
needles under 0.02 mm and over 1 mm long fell from 217 to 13, the longest edge
from 100 mm to 6 mm.

The cells are merged back into ONE vertex list per region, welded on exact
coordinates, so the substrate's rim detection sees a face with no seam along
a grid line and raises no wall there.
"""

from __future__ import annotations

from . import earcut
from .board_region import Region, partition

Point = tuple[float, float]
Triangle = tuple[int, int, int]

#: Grid pitch the face is partitioned at, and how far a grid line keeps from
#: any ring's extreme x or y. 6 mm measured best on rev B among 4/6/8/12: a
#: smaller cell trades long needles for lens fragments at its own edges.
CELL_MM = 6.0
CELL_CLEARANCE_MM = 0.5


def triangulate_region(region: Region, *, cell_mm: float = CELL_MM,
                       clearance_mm: float = CELL_CLEARANCE_MM
                       ) -> tuple[list[Point], list[Triangle]]:
    """``region`` as one welded vertex list and its triangles, every triangle
    positively wound in the region's own frame."""
    index: dict[Point, int] = {}
    points: list[Point] = []
    triangles: list[Triangle] = []
    for cell in partition(region, cell_mm, clearance_mm):
        cell_points, cell_triangles = earcut.triangulate(
            list(cell.outer), [list(hole) for hole in cell.holes])
        cell_triangles = delaunay_flip(cell_points, cell_triangles,
                                       ring_edges(cell))
        remap = []
        for point in cell_points:
            if point not in index:
                index[point] = len(points)
                points.append(point)
            remap.append(index[point])
        triangles.extend((remap[a], remap[b], remap[c])
                         for (a, b, c) in cell_triangles)
    return points, triangles


def ring_edges(region: Region) -> set[frozenset[int]]:
    """Every ring edge as an index pair into the vertex list
    :func:`earcut.triangulate` builds for ``region`` (outer ring first, then
    each hole in order). These edges are the constraints a flip must keep."""
    edges: set[frozenset[int]] = set()
    base = 0
    for ring in (region.outer,) + region.holes:
        n = len(ring)
        edges.update(frozenset((base + i, base + (i + 1) % n)) for i in range(n))
        base += n
    return edges


def delaunay_flip(points: list[Point], triangles: list[Triangle],
                  constrained: set[frozenset[int]]) -> list[Triangle]:
    """Lawson's edge flipping: the constrained Delaunay triangulation of
    ``points`` reached from ``triangles``, with every edge in ``constrained``
    kept. Triangles come back counter-clockwise."""
    tris = [_ccw(points, t) for t in triangles]
    owners: dict[frozenset[int], set[int]] = {}

    def link(ti: int, add: bool) -> None:
        for edge in _edges(tris[ti]):
            bucket = owners.setdefault(edge, set())
            (bucket.add if add else bucket.discard)(ti)

    for ti in range(len(tris)):
        link(ti, True)
    queue = [edge for edge in owners if edge not in constrained]
    # Every flip strictly increases the sorted angle vector, so the loop ends;
    # the bound is only insurance against a degenerate point set.
    budget = 64 * len(tris) + 64
    while queue and budget:
        budget -= 1
        edge = queue.pop()
        pair = owners.get(edge, ())
        if len(pair) != 2 or edge in constrained:
            continue
        t1, t2 = (tris[i] for i in pair)
        u, v = tuple(edge)
        p = next(x for x in t1 if x not in edge)
        q = next(x for x in t2 if x not in edge)
        if p == q:
            continue
        # The quad p-u-q-v must be convex for the diagonal to be swappable.
        if _orient(points[p], points[q], points[u]) * _orient(points[p], points[q], points[v]) >= 0:
            continue
        if not _in_circumcircle(points[t1[0]], points[t1[1]], points[t1[2]], points[q]):
            continue
        i1, i2 = tuple(pair)
        link(i1, False)
        link(i2, False)
        tris[i1] = _ccw(points, (p, q, u))
        tris[i2] = _ccw(points, (q, p, v))
        link(i1, True)
        link(i2, True)
        queue.extend(frozenset(e) for e in ((p, u), (u, q), (q, v), (v, p)))
    return tris


def _edges(t: Triangle):
    return (frozenset((t[0], t[1])), frozenset((t[1], t[2])), frozenset((t[2], t[0])))


def _ccw(points: list[Point], t: Triangle) -> Triangle:
    a, b, c = t
    return (a, b, c) if _orient(points[a], points[b], points[c]) > 0 else (a, c, b)


def _orient(a: Point, b: Point, c: Point) -> float:
    return (b[0] - a[0]) * (c[1] - a[1]) - (c[0] - a[0]) * (b[1] - a[1])


def _in_circumcircle(a: Point, b: Point, c: Point, d: Point) -> bool:
    """True when ``d`` lies strictly inside the circle through the
    counter-clockwise triangle ``a b c``."""
    ax, ay = a[0] - d[0], a[1] - d[1]
    bx, by = b[0] - d[0], b[1] - d[1]
    cx, cy = c[0] - d[0], c[1] - d[1]
    det = ((ax * ax + ay * ay) * (bx * cy - cx * by)
           - (bx * bx + by * by) * (ax * cy - cx * ay)
           + (cx * cx + cy * cy) * (ax * by - bx * ay))
    return det > 1e-18
