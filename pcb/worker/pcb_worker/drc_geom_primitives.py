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

    def expanded(self, margin: float) -> "AABB":
        return AABB(self.min_x - margin, self.min_y - margin,
                    self.max_x + margin, self.max_y + margin)

    def as_list(self) -> list[float]:
        return [self.min_x, self.min_y, self.max_x, self.max_y]


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


# ---------------------------------------------------------------------------
# Exact point / segment distance kernels.
# ---------------------------------------------------------------------------


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


def segment_segment_witness(a: tuple[float, float], b: tuple[float, float],
                            c: tuple[float, float], d: tuple[float, float]
                            ) -> tuple[tuple[float, float], tuple[float, float]]:
    """The two closest points (one on each segment) — used for finding witnesses.

    Mirrors :func:`segment_segment_distance`'s endpoint-projection logic so the
    reported witness pair is consistent with the reported distance.
    """
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


# NOTE (C2): oriented-rect ↔ oriented-rect / rect ↔ capsule edge distances are
# NOT needed by the C1 checks (GC1/GC3/GC4/GC6 use trace widths, drill minors,
# annular webs, and hole-hole capsule distances only). They land in C2 alongside
# GC2 (copper-copper clearance) and GC5 (copper-to-edge). AABBs for oriented
# rects are provided above so the C1 projection can still carry every copper
# primitive with a broad-phase box.
