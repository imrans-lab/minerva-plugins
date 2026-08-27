"""Exact geometric primitives + edge-to-edge distances for the pure copper DRC.

This is the geometry substrate for :mod:`drc_geometric` (facet 2 of the DRC
contract split, docket 019f952306f9 / parent 019f7abf7e7b). It is deliberately
free of any IR / board knowledge — it deals in plain oriented shapes and exact
(or conservatively over-approximating) distances, so it can be unit-tested in
isolation and reused by every geometric check.

GEOMETRY POLICY — FAIL-SAFE DIRECTION (critical; do NOT invert)
--------------------------------------------------------------
The one safety invariant of a geometric copper DRC is that it must never emit a
false ``clean``. Translated to geometry: a computed clearance must NEVER EXCEED
the true clearance, and a computed copper reach must never UNDER-state the true
copper. Concretely —

  * Every copper/hole shape we model is either EXACT (circle, capsule/stadium,
    oriented rectangle) or a SUPERSET of the real copper (a roundrect is modeled
    by its bounding oriented rectangle — the corners we add are copper the board
    does not have, so the modeled gap is <= the true gap).
  * ``edge_distance`` therefore returns a value <= the true edge-to-edge gap.
    A spurious violation (false POSITIVE) is acceptable; a missed one is not.

EPSILON / BOUNDARY POLICY
-------------------------
Distances are exact real arithmetic on floats. Threshold comparisons live in the
check layer (:mod:`drc_geometric`); this module only computes magnitudes. The
shared numerical tolerance :data:`EPS` (1e-9 mm, ~1e-6 of the tightest fab rule)
exists so an exact-at-threshold measurement is not tripped by floating-point
noise. It is a numerical guard only — the *geometry* is already biased to the
conservative (copper-superset) side, so EPS is the sole slack in the system.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

# Shared numerical tolerance (mm). See module docstring — numerical noise only.
EPS = 1e-9


# ---------------------------------------------------------------------------
# Axis-aligned bounding box (broad-phase primitive; broad-phase itself is C2).
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class AABB:
    min_x: float
    min_y: float
    max_x: float
    max_y: float

    def union(self, other: "AABB") -> "AABB":
        return AABB(
            min(self.min_x, other.min_x), min(self.min_y, other.min_y),
            max(self.max_x, other.max_x), max(self.max_y, other.max_y),
        )


def aabb_union(boxes: list[AABB]) -> AABB:
    it = iter(boxes)
    acc = next(it)
    for box in it:
        acc = acc.union(box)
    return acc


# ---------------------------------------------------------------------------
# Exact shape primitives.
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Capsule:
    """A segment (a -> b) swept by a radius: ``{p : dist(p, segment) <= r}``.

    This one primitive models exactly a trace segment (segment centerline ⊕
    half-width), a round drill/pad/via (a degenerate ZERO-LENGTH segment ⊕
    radius, i.e. a disc), and an obround/stadium oval or slot hole (segment ⊕
    radius). Keeping circles as degenerate capsules means the same
    segment-to-segment kernel serves every hole-distance pair (GC6) with no
    special-casing.
    """

    ax: float
    ay: float
    bx: float
    by: float
    r: float

    @classmethod
    def disc(cls, cx: float, cy: float, r: float) -> "Capsule":
        return cls(cx, cy, cx, cy, r)

    def aabb(self) -> AABB:
        return AABB(min(self.ax, self.bx) - self.r, min(self.ay, self.by) - self.r,
                    max(self.ax, self.bx) + self.r, max(self.ay, self.by) + self.r)


@dataclass(frozen=True)
class OrientedRect:
    """A rectangle centred at (cx, cy), half-extents (hw, hh), rotated by
    ``angle`` radians. Used for SMD/TH rectangular copper lands. A ROUNDRECT land
    is modeled by this same box (its bounding rectangle) — a conservative SUPERSET
    of the real copper (see module fail-safe policy)."""

    cx: float
    cy: float
    hw: float
    hh: float
    angle: float

    def corners(self) -> tuple[tuple[float, float], ...]:
        c, s = math.cos(self.angle), math.sin(self.angle)
        pts = []
        for sx, sy in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
            lx, ly = sx * self.hw, sy * self.hh
            pts.append((self.cx + lx * c - ly * s, self.cy + lx * s + ly * c))
        return tuple(pts)

    def aabb(self) -> AABB:
        xs = [p[0] for p in self.corners()]
        ys = [p[1] for p in self.corners()]
        return AABB(min(xs), min(ys), max(xs), max(ys))


@dataclass(frozen=True)
class Polygon:
    """A closed ring of copper that is NOT required to be convex.

    The one concave primitive here, and it exists for one conductor: a zone's
    FILLED region. Clearance carving makes a pour concave, and the fracture that
    expresses a void as a self-touching keyhole ring makes it more so — so the
    convex kernel below cannot measure it and this shape carries its own
    distance function (:func:`polygon_edge_distance`).

    ``points`` is the ring in order; the closing edge back to ``points[0]`` is
    implied and never stored. Edges are walked by index rather than materialised,
    because a real pour ring runs to hundreds of points and every contact test
    would otherwise rebuild that list.
    """

    points: tuple[tuple[float, float], ...]

    def aabb(self) -> AABB:
        xs = [p[0] for p in self.points]
        ys = [p[1] for p in self.points]
        return AABB(min(xs), min(ys), max(xs), max(ys))


def point_in_ring(ring: tuple[tuple[float, float], ...],
                  px: float, py: float) -> bool:
    """Even-odd containment for a ring that may be concave or self-touching.

    A KEYHOLE ring — the fracture that joins a void to the outer boundary with a
    zero-width slit — is exactly why the rule is even-odd: a point in the void
    crosses the outer boundary once and the void's boundary once, so it counts
    EVEN and reads as outside, which is the copper truth (the void is not
    copper). A winding rule would count it inside.

    A point ON the boundary is INSIDE. Boundary contact is contact, and for the
    caller (a contact predicate) that is the fact being asked for.
    """
    n = len(ring)
    if n < 3:
        return False
    inside = False
    for i in range(n):
        x1, y1 = ring[i]
        x2, y2 = ring[(i + 1) % n]
        if point_segment_distance(px, py, x1, y1, x2, y2) <= EPS:
            return True
        if (y1 > py) != (y2 > py):
            xc = x1 + (py - y1) * (x2 - x1) / (y2 - y1)
            if xc > px:
                inside = not inside
    return inside


def polygon_edge_distance(poly: Polygon, other) -> float:
    """Edge-to-edge millimetres between a ring and any other copper shape.

    Zero or negative when the two overlap; ``other`` may be another
    :class:`Polygon` or anything :func:`_decompose` accepts. Mirrors
    :func:`convex_edge_distance`'s contract (core distance minus the other
    shape's inflation radius) so a caller can pick between them on shape type
    alone and read one number either way.
    """
    ring = poly.points
    n1 = len(ring)
    if isinstance(other, Polygon):
        v2, r2, other_ring = other.points, 0.0, other.points
    else:
        v2, e2, solid2, r2 = _decompose(other)
        other_ring = v2 if solid2 else ()
    if any(point_in_ring(ring, x, y) for (x, y) in v2):
        return -r2
    if other_ring and any(
            (point_in_ring(other_ring, x, y) if isinstance(other, Polygon)
             else _point_in_convex(other_ring, x, y)) for (x, y) in ring):
        return -r2
    edges2 = (tuple((other.points[i], other.points[(i + 1) % len(other.points)])
                    for i in range(len(other.points)))
              if isinstance(other, Polygon) else e2)
    best = math.inf
    for i in range(n1):
        a, b = ring[i], ring[(i + 1) % n1]
        for c, d in edges2:
            dd = segment_segment_distance(a, b, c, d)
            if dd < best:
                best = dd
                if best <= EPS:
                    return -r2
    return best - r2


# ---------------------------------------------------------------------------
# Exact point / segment distance kernels.
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class RoundedRect:
    """A rectangle with rounded corners, modeled EXACTLY: the Minkowski sum of an
    inner rectangle (half-extents ``hw - r`` / ``hh - r``) with a disc of radius
    ``r``, centred at ``(cx, cy)`` and rotated by ``angle`` radians.

    ``hw``/``hh`` are the FULL half-extents of the rounded rectangle (its bounding
    box), and ``r`` its corner radius — the same numbers the fab aperture carries,
    so a caller never has to pre-shrink anything.

    WHY THIS EXISTS WHEN OrientedRect ALREADY "COVERS" ROUNDRECT (epoch CP2 S5).
    Copper checks model a roundrect land by its bounding OrientedRect, a
    deliberate conservative SUPERSET: bigger copper means less measured
    clearance, so GC2 over-reports rather than under-reports. That reasoning does
    NOT carry to solder-mask slivers, and assuming it did would have been a false
    clean.

    A sliver is the mask WEB BETWEEN two openings, and the rule distinguishes
    three regimes: web >= floor (fine), 0 < web < floor (a sliver — too thin to
    adhere), and web <= 0 (the openings merge, so there is no web at all and
    nothing to flag). Oversizing an aperture shrinks the measured web, which is
    harmless in the first two regimes but can push a REAL sliver across into the
    apparent-merge regime — where the check reports nothing. Fewer findings read
    as a healthier board. Modelling the corners exactly removes the ambiguity
    instead of documenting it.

    A zero or negative ``r`` degenerates to a plain rectangle, and ``r`` is
    clamped to half the smaller extent so a caller cannot construct an inner
    core with negative half-extents.
    """

    cx: float
    cy: float
    hw: float
    hh: float
    r: float
    angle: float

    def _core(self) -> "OrientedRect":
        """The inner rectangle this shape is the disc-inflation of."""
        r = max(0.0, min(self.r, min(self.hw, self.hh)))
        return OrientedRect(self.cx, self.cy, self.hw - r, self.hh - r, self.angle)

    def core_radius(self) -> float:
        return max(0.0, min(self.r, min(self.hw, self.hh)))

    def aabb(self) -> AABB:
        # The bounding box of the full shape, which is the bounding box of the
        # inner core inflated by the corner radius.
        r = self.core_radius()
        box = self._core().aabb()
        return AABB(box.min_x - r, box.min_y - r, box.max_x + r, box.max_y + r)


def point_segment_distance(px: float, py: float,
                           ax: float, ay: float, bx: float, by: float) -> float:
    """Exact distance from point (px,py) to segment a->b."""
    dx, dy = bx - ax, by - ay
    seg_len2 = dx * dx + dy * dy
    if seg_len2 <= EPS * EPS:
        return math.hypot(px - ax, py - ay)
    t = ((px - ax) * dx + (py - ay) * dy) / seg_len2
    t = max(0.0, min(1.0, t))
    projx, projy = ax + t * dx, ay + t * dy
    return math.hypot(px - projx, py - projy)


def _orient(ax, ay, bx, by, cx, cy) -> float:
    return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)


def _segments_cross(a, b, c, d) -> bool:
    o1 = _orient(*a, *b, *c)
    o2 = _orient(*a, *b, *d)
    o3 = _orient(*c, *d, *a)
    o4 = _orient(*c, *d, *b)
    if ((o1 > 0) != (o2 > 0)) and ((o3 > 0) != (o4 > 0)):
        # Strict opposite orientations on both tests -> a proper crossing.
        if abs(o1) > EPS and abs(o2) > EPS and abs(o3) > EPS and abs(o4) > EPS:
            return True
    return False


def segment_segment_distance(a: tuple[float, float], b: tuple[float, float],
                             c: tuple[float, float], d: tuple[float, float]) -> float:
    """Exact minimum distance between segment a-b and segment c-d.

    Returns 0.0 when the segments intersect. Otherwise the minimum lies at one of
    the four endpoint-to-opposite-segment projections (standard result for the
    non-crossing case), computed exactly.
    """
    if _segments_cross(a, b, c, d):
        return 0.0
    return min(
        point_segment_distance(a[0], a[1], c[0], c[1], d[0], d[1]),
        point_segment_distance(b[0], b[1], c[0], c[1], d[0], d[1]),
        point_segment_distance(c[0], c[1], a[0], a[1], b[0], b[1]),
        point_segment_distance(d[0], d[1], a[0], a[1], b[0], b[1]),
    )


def _segment_intersection(a: tuple[float, float], b: tuple[float, float],
                          c: tuple[float, float], d: tuple[float, float]
                          ) -> tuple[float, float] | None:
    """The point where segments a-b and c-d cross, or ``None`` if they do not
    intersect at a single interior point (parallel/collinear/disjoint). Used to give
    an overlapping pair a witness that actually sits ON the overlap (C2 witness fix)."""
    rx, ry = b[0] - a[0], b[1] - a[1]
    sx, sy = d[0] - c[0], d[1] - c[1]
    denom = rx * sy - ry * sx
    if abs(denom) <= EPS:
        return None  # parallel or collinear — no single crossing point.
    t = ((c[0] - a[0]) * sy - (c[1] - a[1]) * sx) / denom
    u = ((c[0] - a[0]) * ry - (c[1] - a[1]) * rx) / denom
    if -EPS <= t <= 1.0 + EPS and -EPS <= u <= 1.0 + EPS:
        return (a[0] + t * rx, a[1] + t * ry)
    return None


def segment_segment_witness(a: tuple[float, float], b: tuple[float, float],
                            c: tuple[float, float], d: tuple[float, float]
                            ) -> tuple[tuple[float, float], tuple[float, float]]:
    """The two closest points (one on each segment) — used for finding witnesses.

    Mirrors :func:`segment_segment_distance`'s endpoint-projection logic so the
    reported witness pair is consistent with the reported distance. When the two
    segments properly CROSS the closest approach is the crossing point at distance
    zero; the endpoint-projection candidates never include that point, so we return
    the crossing point on BOTH segments (a single shared point on the overlap) —
    otherwise the reported witness (some endpoint pair, non-zero apart) would
    contradict the reported distance of 0 (C2 witness-consistency fix).
    """
    cross = _segment_intersection(a, b, c, d)
    if cross is not None:
        return (cross, cross)

    def proj(px, py, sx, sy, tx, ty):
        dx, dy = tx - sx, ty - sy
        seg_len2 = dx * dx + dy * dy
        if seg_len2 <= EPS * EPS:
            return (sx, sy)
        t = ((px - sx) * dx + (py - sy) * dy) / seg_len2
        t = max(0.0, min(1.0, t))
        return (sx + t * dx, sy + t * dy)

    candidates = [
        ((a[0], a[1]), proj(a[0], a[1], c[0], c[1], d[0], d[1])),
        ((b[0], b[1]), proj(b[0], b[1], c[0], c[1], d[0], d[1])),
        (proj(c[0], c[1], a[0], a[1], b[0], b[1]), (c[0], c[1])),
        (proj(d[0], d[1], a[0], a[1], b[0], b[1]), (d[0], d[1])),
    ]
    return min(candidates, key=lambda pair: math.hypot(
        pair[0][0] - pair[1][0], pair[0][1] - pair[1][1]))


def capsule_edge_distance(c1: Capsule, c2: Capsule) -> float:
    """Edge-to-edge distance between two capsules (may be negative when the copper
    envelopes overlap). Exact for circles/segments; the shared kernel for GC6 and
    (in C2) same-layer copper clearance."""
    center = segment_segment_distance((c1.ax, c1.ay), (c1.bx, c1.by),
                                      (c2.ax, c2.ay), (c2.bx, c2.by))
    return center - c1.r - c2.r


def capsule_edge_witness(c1: Capsule, c2: Capsule
                         ) -> tuple[tuple[float, float], tuple[float, float]]:
    """Witness points on each capsule surface along the closest-approach line."""
    p1, p2 = segment_segment_witness((c1.ax, c1.ay), (c1.bx, c1.by),
                                     (c2.ax, c2.ay), (c2.bx, c2.by))
    dx, dy = p2[0] - p1[0], p2[1] - p1[1]
    dist = math.hypot(dx, dy)
    if dist <= EPS:
        return (p1, p2)
    ux, uy = dx / dist, dy / dist
    return ((p1[0] + ux * c1.r, p1[1] + uy * c1.r),
            (p2[0] - ux * c2.r, p2[1] - uy * c2.r))


# ---------------------------------------------------------------------------
# Convex copper-shape edge distance (C2 — GC2 same-layer clearance).
#
# Every copper land the projection carries is either a Capsule (trace segment,
# round pad/via as a zero-length capsule, obround) or an OrientedRect (a rect or —
# as a conservative bounding SUPERSET — a roundrect land). Each such shape is a
# convex "core" (a segment for a capsule, the four corners for a rect) inflated by
# a radius (the capsule radius; zero for a rect). The edge-to-edge distance is the
# core-to-core distance minus both radii:
#
#     edge_distance = core_distance(coreA, coreB) - rA - rB
#
# core_distance is 0 when the cores overlap (a vertex of one inside the other, or
# a pair of edges that cross) and otherwise the minimum segment-to-segment
# distance over every edge pair — EXACT for these convex cores. Because a roundrect
# is modeled by its bounding rect (a copper superset), the returned distance is
# EXACT for rect/capsule copper and a conservative UNDER-estimate for roundrect —
# the fail-safe direction (never over-reports clearance). A disc is a degenerate
# zero-length capsule, so disc↔rect / disc↔capsule fall out of the same kernel
# with no special-casing.
# ---------------------------------------------------------------------------


def _decompose(shape) -> tuple[tuple[tuple[float, float], ...],
                               tuple[tuple[tuple[float, float],
                                           tuple[float, float]], ...],
                               bool, float]:
    """Convex-core view of a copper shape: ``(vertices, edges, is_polygon, radius)``.

    A :class:`Capsule` is a segment core (its two endpoints; a single point for a
    disc) inflated by ``r`` — ``is_polygon=False`` (no 2D interior). An
    :class:`OrientedRect` is its four corners, ``is_polygon=True``, radius 0.
    Raises :class:`TypeError` for anything else (caller fail-closes)."""
    if isinstance(shape, Capsule):
        verts = ((shape.ax, shape.ay), (shape.bx, shape.by))
        edges = (((shape.ax, shape.ay), (shape.bx, shape.by)),)
        return verts, edges, False, shape.r
    if isinstance(shape, OrientedRect):
        corners = shape.corners()
        edges = tuple((corners[i], corners[(i + 1) % len(corners)])
                      for i in range(len(corners)))
        return corners, edges, True, 0.0
    if isinstance(shape, RoundedRect):
        # A rounded rectangle IS a polygon core inflated by a radius, which is
        # precisely the (vertices, edges, is_polygon, radius) view this function
        # returns — so the existing kernel handles it exactly, with no
        # special-casing downstream. `convex_edge_distance` already subtracts
        # both radii from the core distance, and `_core_distance` already
        # reports 0 for overlapping cores (which, minus the radii, correctly
        # yields a negative separation).
        r = shape.core_radius()
        core = shape._core()
        chw, chh = core.hw, core.hh

        # DEGENERATE CORES MUST NOT BE REPORTED AS POLYGONS. When the corner
        # radius reaches a half-extent the core collapses to a segment (an
        # obround) or to a point (a circle) — both legitimate roundrect
        # apertures. Passing a collapsed 4-vertex "polygon" to _core_distance
        # would be actively wrong, not merely imprecise: _point_in_convex sees
        # every cross product as zero, concludes INSIDE for any query point, and
        # _core_distance returns 0. Distance minus the radii then goes negative
        # and the caller reads two far-apart apertures as overlapping — which,
        # for the mask-sliver rule, is the "merged, nothing to flag" branch. A
        # false clean, from a shape that is perfectly ordinary.
        #
        # The non-polygon view is exactly Capsule semantics, so these fall
        # through the same segment kernel a disc or obround already uses.
        c, s = math.cos(core.angle), math.sin(core.angle)
        if chw <= EPS and chh <= EPS:
            p = (core.cx, core.cy)
            return (p, p), ((p, p),), False, r
        if chw <= EPS or chh <= EPS:
            hx, hy = (0.0, chh) if chw <= EPS else (chw, 0.0)
            dx, dy = hx * c - hy * s, hx * s + hy * c
            a = (core.cx - dx, core.cy - dy)
            b = (core.cx + dx, core.cy + dy)
            return (a, b), ((a, b),), False, r

        corners = core.corners()
        edges = tuple((corners[i], corners[(i + 1) % len(corners)])
                      for i in range(len(corners)))
        return corners, edges, True, r
    raise TypeError(f"unsupported copper shape for convex distance: {type(shape).__name__}")


def _point_in_convex(poly: tuple[tuple[float, float], ...],
                     px: float, py: float) -> bool:
    """True iff (px,py) is inside or on the boundary of the convex polygon ``poly``
    (vertices in consistent winding order). A point exactly on an edge (within EPS)
    counts as inside — treating a boundary touch as overlap only ever biases the
    distance toward 0, the fail-safe direction."""
    n = len(poly)
    if n < 3:
        return False
    sign = 0
    for i in range(n):
        x1, y1 = poly[i]
        x2, y2 = poly[(i + 1) % n]
        cross = (x2 - x1) * (py - y1) - (y2 - y1) * (px - x1)
        if cross > EPS:
            if sign < 0:
                return False
            sign = 1
        elif cross < -EPS:
            if sign > 0:
                return False
            sign = -1
    return True


def _core_distance(v1, e1, p1: bool, v2, e2, p2: bool) -> float:
    """Distance between two convex cores; 0 when they overlap."""
    if p1 and any(_point_in_convex(v1, x, y) for (x, y) in v2):
        return 0.0
    if p2 and any(_point_in_convex(v2, x, y) for (x, y) in v1):
        return 0.0
    best = math.inf
    for a, b in e1:
        for c, d in e2:
            dd = segment_segment_distance(a, b, c, d)
            if dd < best:
                best = dd
                if best <= EPS:
                    return 0.0
    return best


def convex_edge_distance(s1, s2) -> float:
    """Edge-to-edge distance between two convex copper shapes (Capsule/OrientedRect).

    Negative when the copper envelopes overlap. EXACT for rect/capsule copper; a
    conservative UNDER-estimate (never over-reports clearance) for a roundrect land
    modeled by its bounding rect. The shared narrow-phase kernel for GC2."""
    v1, e1, p1, r1 = _decompose(s1)
    v2, e2, p2, r2 = _decompose(s2)
    return _core_distance(v1, e1, p1, v2, e2, p2) - r1 - r2


def _overlap_point(v1, e1, p1: bool, v2, e2, p2: bool
                   ) -> tuple[float, float] | None:
    """A point lying on the overlap of two overlapping convex cores, or ``None`` if
    they are disjoint. Prefers a vertex of one core contained in the other, else the
    crossing point of an intersecting edge pair."""
    if p1:
        for x, y in v2:
            if _point_in_convex(v1, x, y):
                return (x, y)
    if p2:
        for x, y in v1:
            if _point_in_convex(v2, x, y):
                return (x, y)
    for a, b in e1:
        for c, d in e2:
            ip = _segment_intersection(a, b, c, d)
            if ip is not None:
                return ip
    return None


def convex_edge_witness(s1, s2
                        ) -> tuple[tuple[float, float], tuple[float, float]]:
    """Witness points on each copper surface along the closest-approach line.

    For OVERLAPPING copper (zero/negative edge distance) both witnesses are a single
    shared point on the overlap, so the highlight sits on the actual collision (C2
    witness fix). Otherwise the two points are the closest surface points, one on
    each shape."""
    v1, e1, p1, r1 = _decompose(s1)
    v2, e2, p2, r2 = _decompose(s2)
    ov = _overlap_point(v1, e1, p1, v2, e2, p2)
    if ov is not None:
        return (ov, ov)
    best = math.inf
    witness = None
    for a, b in e1:
        for c, d in e2:
            dd = segment_segment_distance(a, b, c, d)
            if dd < best:
                best = dd
                witness = segment_segment_witness(a, b, c, d)
    p1w, p2w = witness
    dx, dy = p2w[0] - p1w[0], p2w[1] - p1w[1]
    dist = math.hypot(dx, dy)
    if dist <= EPS:
        return (p1w, p2w)
    ux, uy = dx / dist, dy / dist
    return ((p1w[0] + ux * r1, p1w[1] + uy * r1),
            (p2w[0] - ux * r2, p2w[1] - uy * r2))
