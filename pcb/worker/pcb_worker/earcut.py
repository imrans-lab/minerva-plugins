"""POLYGON TRIANGULATION THAT ACCEPTS HOLES — a Python PORT of mapbox/earcut.

THIRD-PARTY ORIGIN, STATED PLAINLY. This is not an independent implementation
of ear clipping: it is a function-for-function port of the JavaScript
``earcut`` library (mapbox/earcut v2.2.4), down to the hole-bridge search, the
two robustness fallbacks and the point-in-triangle predicate. Names were
snake_cased and the z-order spatial index was dropped (see COST below);
everything else is upstream's algorithm and upstream's edge-case handling.

    earcut — https://github.com/mapbox/earcut (v2.2.4)

    ISC License

    Copyright (c) 2016, Mapbox

    Permission to use, copy, modify, and/or distribute this software for any
    purpose with or without fee is hereby granted, provided that the above
    copyright notice and this permission notice appear in all copies.

    THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
    WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
    MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
    ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
    WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
    ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR
    IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

WHY IT EXISTS HERE. Nothing else in this worker triangulates. ``pyclipper``
does exact integer booleans and offsets and has no triangulator; ``gerbonara``
reads Gerbers; ``wavefront_obj`` reads triangles somebody else already made. A
board that is a solid with real holes in it needs a triangle list, and an
extrusion cannot invent one — an extruded ring is a tube, not a slab with a
bore through it. Ported rather than taken as a dependency because it is a few
hundred lines with no runtime deps, and the alternatives (constrained Delaunay,
``mapbox_earcut``/``triangle``/``shapely``) buy triangle QUALITY, which nothing
here needs: the output is drawn, not simulated, and a sliver renders exactly
like a fat triangle.

COST. The port omits upstream's optional z-order (Morton) hash, so ear
candidacy is a linear scan of the ring and the whole clip is quadratic in
vertex count. Measured on a rectangle with 16-gon holes: 40 holes (644 ring
vertices) 11 ms, 80 holes 39 ms, 160 holes (2,564 vertices) 154 ms — doubling
the hole count roughly quadruples the time. Fine at board scale, where a
via-heavy face is ~1,500 vertices; a caller with tens of thousands wants the
index back.

THE INPUT THIS IS DESIGNED FOR is a cleaned Clipper region: rings that are
simple, closed, correctly nested and consistently oriented, which is what
:mod:`board_region` hands it. Ear clipping on rings that cross each other has
no defined answer. Upstream's two robustness passes (splice out a local
self-intersection; otherwise split at a valid diagonal and recurse) are kept
anyway, because a degenerate-but-simple ring — three collinear points, a pinch
where a bridge touches the ring it bridges to — is reachable from real board
data.

ORIENTATION IS A CONTRACT, not an observation. :func:`triangulate` normalises
its input (outer ring positive signed area, holes negative) and every emitted
triangle is therefore positively wound in the coordinate system it was handed.
This module is deliberately blind to what that means on screen: in the Y-DOWN
board frame a positively wound triangle appears CLOCKWISE, and deciding which
way a face must point is the caller's job (:mod:`mesh_frame` owns it).
"""

from __future__ import annotations

Point = tuple[float, float]


class _Node:
    """One ring vertex in the doubly-linked ring the clipper walks."""

    __slots__ = ("i", "x", "y", "prev", "next", "steiner")

    def __init__(self, i: int, x: float, y: float) -> None:
        self.i = i
        self.x = x
        self.y = y
        self.prev: _Node = self          # closed by _link/_insert
        self.next: _Node = self
        self.steiner = False


def triangulate(outer: list[Point],
                holes: list[list[Point]] | tuple[list[Point], ...] = ()
                ) -> tuple[list[Point], list[tuple[int, int, int]]]:
    """Triangulate ``outer`` with ``holes`` cut out of it.

    Returns the merged vertex list (outer ring first, then each hole in the
    order given) and triangles as index triples into it. Rings are given
    WITHOUT a repeated closing point; a repeated one is tolerated and dropped.
    """
    points: list[Point] = [(float(x), float(y)) for (x, y) in _open_ring(outer)]
    hole_starts: list[int] = []
    for hole in holes:
        ring = _open_ring(hole)
        if len(ring) < 3:
            continue                      # a degenerate hole removes no area
        hole_starts.append(len(points))
        points.extend((float(x), float(y)) for (x, y) in ring)
    if len(points) < 3:
        return points, []
    return points, _earcut(points, hole_starts)


def _open_ring(ring) -> list:
    ring = list(ring)
    while len(ring) > 1 and ring[0] == ring[-1]:
        ring.pop()
    return ring


def signed_area(ring) -> float:
    """Shoelace area. Positive rings are the outer-boundary orientation here."""
    total = 0.0
    n = len(ring)
    for i in range(n):
        ax, ay = ring[i - 1]
        bx, by = ring[i]
        total += (ax - bx) * (ay + by)
    return total / 2.0


# ---------------------------------------------------------------------------
# The clip itself.
# ---------------------------------------------------------------------------


def _earcut(points: list[Point], hole_starts: list[int]) -> list[tuple[int, int, int]]:
    outer_end = hole_starts[0] if hole_starts else len(points)
    outer = _linked_ring(points, 0, outer_end, positive=True)
    if outer is None or outer.next is outer.prev:
        return []
    if hole_starts:
        outer = _eliminate_holes(points, hole_starts, outer)
    triangles: list[tuple[int, int, int]] = []
    _earcut_linked(outer, triangles, 0)
    return triangles


def _linked_ring(points: list[Point], start: int, end: int,
                 *, positive: bool) -> _Node | None:
    """Link ``points[start:end]`` into a ring wound to the requested sign."""
    ring = points[start:end]
    last: _Node | None = None
    forward = (signed_area(ring) >= 0.0) == positive
    order = range(start, end) if forward else range(end - 1, start - 1, -1)
    for i in order:
        last = _insert(i, points[i][0], points[i][1], last)
    if last is not None and _equal(last, last.next):
        _remove(last)
        last = last.next
    return last


def _insert(i: int, x: float, y: float, last: _Node | None) -> _Node:
    node = _Node(i, x, y)
    if last is None:
        node.prev = node
        node.next = node
    else:
        node.next = last.next
        node.prev = last
        last.next.prev = node
        last.next = node
    return node


def _remove(node: _Node) -> None:
    node.next.prev = node.prev
    node.prev.next = node.next


def _equal(a: _Node, b: _Node) -> bool:
    return a.x == b.x and a.y == b.y


def _cross(px: float, py: float, qx: float, qy: float,
           rx: float, ry: float) -> float:
    """Twice the signed area of triangle p-q-r."""
    return (qy - py) * (rx - qx) - (qx - px) * (ry - qy)


def _filter_points(start: _Node | None, end: _Node | None = None) -> _Node | None:
    """Drop duplicate and strictly collinear vertices from a ring."""
    if start is None:
        return None
    if end is None:
        end = start
    node = start
    while True:
        again = False
        if not node.steiner and (_equal(node, node.next)
                                 or _cross(node.prev.x, node.prev.y, node.x, node.y,
                                           node.next.x, node.next.y) == 0.0):
            _remove(node)
            node = end = node.prev
            if node is node.next:
                return None
            again = True
        else:
            node = node.next
        if not again and node is end:
            return end


def _earcut_linked(ear: _Node | None, triangles: list, pass_: int) -> None:
    """Clip ears off ``ear``'s ring, appending index triples to ``triangles``.

    ``pass_`` is the robustness ladder: 0 clips, 1 retries on a filtered ring,
    2 splices out a local self-intersection, 3 splits at a diagonal. A ring that
    is simple and non-degenerate never leaves pass 0.
    """
    if ear is None:
        return
    if pass_ == 0:
        ear = _filter_points(ear)
        if ear is None:
            return
    stop = ear
    while ear.prev is not ear.next:
        prev, next_ = ear.prev, ear.next
        if _is_ear(ear):
            triangles.append((prev.i, ear.i, next_.i))
            _remove(ear)
            ear = next_.next
            stop = next_.next
            continue
        ear = next_
        if ear is stop:
            # A full lap with no ear taken: something about this ring is
            # degenerate. Escalate rather than silently dropping the area.
            if pass_ == 0:
                _earcut_linked(_filter_points(ear), triangles, 1)
            elif pass_ == 1:
                _earcut_linked(_cure_local_intersections(_filter_points(ear), triangles),
                               triangles, 2)
            elif pass_ == 2:
                _split_earcut(ear, triangles)
            return


def _is_ear(ear: _Node) -> bool:
    a, b, c = ear.prev, ear, ear.next
    if _cross(a.x, a.y, b.x, b.y, c.x, c.y) >= 0.0:
        return False                       # reflex vertex: never an ear
    # No other vertex of the ring may fall inside the candidate triangle. The
    # bounding box short-circuit is what keeps this affordable on the ~1500
    # vertices a via-heavy board's face carries.
    min_x, max_x = min(a.x, b.x, c.x), max(a.x, b.x, c.x)
    min_y, max_y = min(a.y, b.y, c.y), max(a.y, b.y, c.y)
    node = c.next
    while node is not a:
        if (min_x <= node.x <= max_x and min_y <= node.y <= max_y
                and _point_in_triangle(a.x, a.y, b.x, b.y, c.x, c.y, node.x, node.y)
                and _cross(node.prev.x, node.prev.y, node.x, node.y,
                           node.next.x, node.next.y) >= 0.0):
            return False
        node = node.next
    return True


def _point_in_triangle(ax, ay, bx, by, cx, cy, px, py) -> bool:
    return ((cx - px) * (ay - py) >= (ax - px) * (cy - py)
            and (ax - px) * (by - py) >= (bx - px) * (ay - py)
            and (bx - px) * (cy - py) >= (cx - px) * (by - py))


def _cure_local_intersections(start: _Node | None, triangles: list) -> _Node | None:
    """Splice out a vertex pair whose edges cross locally, emitting the triangle
    that the splice cuts off. The first fallback pass."""
    if start is None:
        return None
    node = start
    while True:
        a, b = node.prev, node.next.next
        if (not _equal(a, b) and _intersects(a, node, node.next, b)
                and _locally_inside(a, b) and _locally_inside(b, a)):
            triangles.append((a.i, node.i, b.i))
            _remove(node)
            _remove(node.next)
            node = start = b
        node = node.next
        if node is start:
            break
    return _filter_points(node)


def _split_earcut(start: _Node, triangles: list) -> None:
    """Split the ring at a valid diagonal and triangulate the halves. The last
    fallback pass — it is what rescues a ring pinched by a hole bridge."""
    a = start
    while True:
        b = a.next.next
        while b is not a.prev:
            if a.i != b.i and _is_valid_diagonal(a, b):
                c = _split_polygon(a, b)
                _earcut_linked(_filter_points(a, a.next), triangles, 0)
                _earcut_linked(_filter_points(c, c.next), triangles, 0)
                return
            b = b.next
        a = a.next
        if a is start:
            return


# ---------------------------------------------------------------------------
# Holes: bridge each one into the outer ring.
# ---------------------------------------------------------------------------


def _eliminate_holes(points: list[Point], hole_starts: list[int],
                     outer: _Node) -> _Node:
    queue: list[_Node] = []
    for index, start in enumerate(hole_starts):
        end = hole_starts[index + 1] if index + 1 < len(hole_starts) else len(points)
        ring = _linked_ring(points, start, end, positive=False)
        if ring is None:
            continue
        if ring is ring.next:
            ring.steiner = True
        queue.append(_leftmost(ring))
    # Left to right: a hole is bridged to geometry that is already final, so
    # bridging the leftmost first means every later bridge sees the earlier ones.
    queue.sort(key=lambda node: (node.x, node.y))
    for hole in queue:
        outer = _eliminate_hole(hole, outer)
    return outer


def _eliminate_hole(hole: _Node, outer: _Node) -> _Node:
    bridge = _find_hole_bridge(hole, outer)
    if bridge is None:
        return outer
    reverse = _split_polygon(bridge, hole)
    # Collinear points around BOTH cut ends go, and the ring head becomes the
    # bridge: filtering can remove the node the caller was holding.
    _filter_points(reverse, reverse.next)
    return _filter_points(bridge, bridge.next) or bridge


def _leftmost(ring: _Node) -> _Node:
    best = node = ring
    while True:
        if node.x < best.x or (node.x == best.x and node.y < best.y):
            best = node
        node = node.next
        if node is ring:
            return best


def _find_hole_bridge(hole: _Node, outer: _Node) -> _Node | None:
    """The outer-ring vertex a hole's leftmost point can see.

    Cast a ray LEFT from the hole's leftmost vertex and take the nearest outer
    edge it hits — only DOWNWARD-crossing edges, which on a positively wound
    ring are the ones whose interior faces the hole. Then, among the outer
    vertices inside the triangle (ray hit, hole point, that edge's endpoint),
    keep the one at the smallest angle to the ray: it is the one actually
    visible. A naive nearest-VERTEX bridge crosses the ring the moment a hole
    sits in a concave pocket, which a board rim with a cutout in it has.
    """
    hx, hy = hole.x, hole.y
    qx = float("-inf")
    m: _Node | None = None
    node = outer
    while True:
        nxt = node.next
        if hy <= node.y and hy >= nxt.y and nxt.y != node.y:
            x = node.x + (hy - node.y) * (nxt.x - node.x) / (nxt.y - node.y)
            if qx < x <= hx:
                qx = x
                m = node if node.x < nxt.x else nxt
                if x == hx:
                    return m            # the hole touches the edge outright
        node = nxt
        if node is outer:
            break
    if m is None:
        return None

    stop = m
    mx, my = m.x, m.y
    tan_min = float("inf")
    node = m
    while True:
        if (hx >= node.x >= mx and hx != node.x
                and _point_in_triangle(hx if hy < my else qx, hy, mx, my,
                                       qx if hy < my else hx, hy, node.x, node.y)):
            tan = abs(hy - node.y) / (hx - node.x)
            if _locally_inside(node, hole) and (
                    tan < tan_min
                    or (tan == tan_min
                        and (node.x > m.x
                             or (node.x == m.x and _sector_contains(m, node))))):
                m = node
                tan_min = tan
        node = node.next
        if node is stop:
            break
    return m


def _sector_contains(m: _Node, p: _Node) -> bool:
    """Tie-break for two equally angled candidates: prefer the one whose sector
    contains the other's."""
    return (_cross(m.prev.x, m.prev.y, m.x, m.y, p.prev.x, p.prev.y) < 0.0
            and _cross(p.next.x, p.next.y, m.x, m.y, m.next.x, m.next.y) < 0.0)


# ---------------------------------------------------------------------------
# Diagonal predicates.
# ---------------------------------------------------------------------------


def _is_valid_diagonal(a: _Node, b: _Node) -> bool:
    return (a.next.i != b.i and a.prev.i != b.i
            and not _intersects_polygon(a, b)
            and ((_locally_inside(a, b) and _locally_inside(b, a) and _middle_inside(a, b)
                  and (_area(a.prev, a, b.prev) != 0.0 or _area(a, b.prev, b) != 0.0))
                 or (_equal(a, b) and _area(a.prev, a, a.next) > 0.0
                     and _area(b.prev, b, b.next) > 0.0)))


def _area(p: _Node, q: _Node, r: _Node) -> float:
    return _cross(p.x, p.y, q.x, q.y, r.x, r.y)


def _on_segment(p: _Node, q: _Node, r: _Node) -> bool:
    return (min(p.x, r.x) <= q.x <= max(p.x, r.x)
            and min(p.y, r.y) <= q.y <= max(p.y, r.y))


def _sign(value: float) -> int:
    return (value > 0.0) - (value < 0.0)


def _intersects(p1: _Node, q1: _Node, p2: _Node, q2: _Node) -> bool:
    o1, o2 = _sign(_area(p1, q1, p2)), _sign(_area(p1, q1, q2))
    o3, o4 = _sign(_area(p2, q2, p1)), _sign(_area(p2, q2, q1))
    if o1 != o2 and o3 != o4:
        return True
    if o1 == 0 and _on_segment(p1, p2, q1):
        return True
    if o2 == 0 and _on_segment(p1, q2, q1):
        return True
    if o3 == 0 and _on_segment(p2, p1, q2):
        return True
    return o4 == 0 and _on_segment(p2, q1, q2)


def _intersects_polygon(a: _Node, b: _Node) -> bool:
    node = a
    while True:
        if (node.i != a.i and node.next.i != a.i
                and node.i != b.i and node.next.i != b.i
                and _intersects(node, node.next, a, b)):
            return True
        node = node.next
        if node is a:
            return False


def _locally_inside(a: _Node, b: _Node) -> bool:
    if _area(a.prev, a, a.next) < 0.0:
        return _area(a, b, a.next) >= 0.0 and _area(a, a.prev, b) >= 0.0
    return _area(a, b, a.prev) < 0.0 or _area(a, a.next, b) < 0.0


def _middle_inside(a: _Node, b: _Node) -> bool:
    inside = False
    px, py = (a.x + b.x) / 2.0, (a.y + b.y) / 2.0
    node = a
    while True:
        if ((node.y > py) != (node.next.y > py) and node.next.y != node.y
                and px < (node.next.x - node.x) * (py - node.y)
                / (node.next.y - node.y) + node.x):
            inside = not inside
        node = node.next
        if node is a:
            return inside


def _split_polygon(a: _Node, b: _Node) -> _Node:
    """Cut the ring in two along a-b, returning the second ring's node ``b2``."""
    a2 = _Node(a.i, a.x, a.y)
    b2 = _Node(b.i, b.x, b.y)
    an, bp = a.next, b.prev

    a.next = b
    b.prev = a
    a2.next = an
    an.prev = a2
    b2.next = a2
    a2.prev = b2
    bp.next = b2
    b2.prev = bp
    return b2
