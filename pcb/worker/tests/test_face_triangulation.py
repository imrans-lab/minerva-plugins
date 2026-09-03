"""The face a viewer draws must not carry needles.

Fixture: a 30 x 20 mm rectangle with a column of five 1.0 mm bores at 2.54 mm
pitch (the socket strip case that makes the worst needles) and one 3.2 mm
mounting hole, every ring polygonised the way board_region does it — dense,
with an arc sagitta of a few microns.
"""

from __future__ import annotations

import math

from pcb_worker import earcut
from pcb_worker.board_region import Region, subtract
from pcb_worker.face_triangulation import (delaunay_flip, ring_edges,
                                           triangulate_region)


def _circle(cx: float, cy: float, r: float, n: int) -> tuple[tuple[float, float], ...]:
    return tuple((round(cx + r * math.cos(2 * math.pi * i / n), 6),
                  round(cy + r * math.sin(2 * math.pi * i / n), 6)) for i in range(n))


def _fixture() -> Region:
    outline = ((0.0, 0.0), (30.0, 0.0), (30.0, 20.0), (0.0, 20.0))
    holes = tuple(_circle(8.0, 3.0 + 2.54 * i, 0.5, 24) for i in range(5))
    holes += (_circle(22.0, 10.0, 1.6, 48),)
    regions = subtract(outline, holes)
    assert len(regions) == 1
    return regions[0]


def _thickness_and_length(points, tri):
    a, b, c = (points[i] for i in tri)
    longest = max(math.dist(a, b), math.dist(b, c), math.dist(c, a))
    area = abs((b[0] - a[0]) * (c[1] - a[1]) - (c[0] - a[0]) * (b[1] - a[1])) / 2
    return 2 * area / longest, longest


def _needles(points, triangles, thinner_than=0.05, longer_than=1.0) -> int:
    return sum(1 for t in triangles
               if (lambda th, ln: th < thinner_than and ln > longer_than)(
                   *_thickness_and_length(points, t)))


def _in_circumcircle(a, b, c, d) -> bool:
    ax, ay, bx, by, cx, cy = a[0]-d[0], a[1]-d[1], b[0]-d[0], b[1]-d[1], c[0]-d[0], c[1]-d[1]
    return ((ax*ax+ay*ay)*(bx*cy-cx*by) - (bx*bx+by*by)*(ax*cy-cx*ay)
            + (cx*cx+cy*cy)*(ax*by-bx*ay)) > 1e-9


def test_the_face_has_no_needle_the_points_do_not_force_and_no_edge_spans_the_board():
    """MUTATION THIS CATCHES: skipping the partition (a 30 mm fan edge
    reappears), skipping the flips (needles between the aligned bores
    reappear), or flipping a ring edge (the bore is no longer a hole).

    ORACLES, none of them the code under test: plain ear clipping of the same
    region as the baseline the result must beat by an order of magnitude; the
    Delaunay circumcircle test applied by hand to every interior edge; the
    region's own area; and the ring edges, which must all survive as edges.
    """
    region = _fixture()
    base_points, base_tris = earcut.triangulate(list(region.outer),
                                                [list(h) for h in region.holes])
    points, triangles = triangulate_region(region, cell_mm=6.0, clearance_mm=0.5)

    # Measured on this fixture: plain clipping 14 / 34; partition without
    # flips 14 / 30; flips without partition 2 / 19; both 0 / 9. Each line
    # below fails one of the two mutations on its own.
    baseline = _needles(base_points, base_tris)
    assert baseline >= 10, "the fixture must provoke needles or this proves nothing"
    assert _needles(points, triangles, thinner_than=0.02) == 0, \
        "a needle thinner than 0.02 mm and longer than 1 mm survived the flips"
    assert _needles(points, triangles, thinner_than=0.05) <= baseline // 3

    # A cell grows by at most one clearance per side when its lines are
    # nudged, so nothing may be longer than such a cell's diagonal.
    longest = max(_thickness_and_length(points, t)[1] for t in triangles)
    assert longest <= math.sqrt(2) * (6.0 + 2 * 0.5) + 1e-9, \
        f"an edge of {longest:.2f} mm spans cells"

    # Area is conserved to the micron, every triangle wound positively.
    area = sum((lambda a, b, c: ((b[0]-a[0])*(c[1]-a[1]) - (c[0]-a[0])*(b[1]-a[1])) / 2)(
        *(points[i] for i in t)) for t in triangles)
    assert area == __import__("pytest").approx(region.area_mm2(), abs=1e-6)
    assert all(_thickness_and_length(points, t)[0] > 0 for t in triangles)

    # The face's rim — every edge with exactly one triangle — is the rings and
    # nothing else: a flipped ring edge would put a triangle across a bore and
    # drop that edge from the rim, and a seam along a grid line would add one.
    owners: dict[frozenset, int] = {}
    for t in triangles:
        for i in range(3):
            e = frozenset((t[i], t[(i + 1) % 3]))
            owners[e] = owners.get(e, 0) + 1
    rim = sum(math.dist(points[a], points[b]) for e, n in owners.items() if n == 1
              for a, b in [tuple(e)])
    perimeter = sum(math.dist(a, b) for ring in (region.outer,) + region.holes
                    for a, b in zip(ring, ring[1:] + ring[:1]))
    assert rim == __import__("pytest").approx(perimeter, abs=1e-6)


def test_every_interior_edge_of_a_cell_is_delaunay_after_flipping():
    """The flip pass is graded by the definition it implements, applied to its
    output by a separate hand-written test — not by the pass's own predicate."""
    region = _fixture()
    points, tris = earcut.triangulate(list(region.outer), [list(h) for h in region.holes])
    constrained = ring_edges(region)
    flipped = delaunay_flip(points, tris, constrained)
    assert len(flipped) == len(tris)

    owners: dict[frozenset, list] = {}
    for t in flipped:
        for i in range(3):
            owners.setdefault(frozenset((t[i], t[(i + 1) % 3])), []).append(t)
    checked = violations = 0
    for edge, pair in owners.items():
        if len(pair) != 2 or edge in constrained:
            continue
        t1, t2 = pair
        q = next(x for x in t2 if x not in edge)
        p = next(x for x in t1 if x not in edge)
        u, v = tuple(edge)
        convex = ((points[q][0]-points[p][0])*(points[u][1]-points[p][1]) - (points[u][0]-points[p][0])*(points[q][1]-points[p][1])) * \
                 ((points[q][0]-points[p][0])*(points[v][1]-points[p][1]) - (points[v][0]-points[p][0])*(points[q][1]-points[p][1])) < 0
        if not convex:
            continue
        checked += 1
        if _in_circumcircle(points[t1[0]], points[t1[1]], points[t1[2]], points[q]):
            violations += 1
    assert checked > 100, "the fixture must have interior edges to check"
    assert violations == 0
