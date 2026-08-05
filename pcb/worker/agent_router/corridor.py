"""Authored-corridor geometry, cost and adherence (bug 019fcf152791 Stage B).

A "corridor" is an author's ordered polyline for ONE connection: the waypoints
of a pcb_route_hint, oriented source -> destination. Before Stage B those
waypoints reached the engine and were never read (the RCA on that bug); this
module is the shared vocabulary that makes them influence the search AND lets
the run report how well it followed them.

TWO CONSUMERS, ONE GEOMETRY. The product-state A* in :mod:`pathfinder` uses
:func:`segment_distance` to price a step, and the adherence report uses the
same primitives to grade the finished path. They must not drift: a route the
planner believed was on-corridor has to grade as on-corridor.

SEMANTICS (owner-approved, docket comments 1021/1024): ordered, obstacle-aware
ATTRACTION. Waypoints are NOT mandatory — the planner may skip one at a cost —
but a waypoint is either reached in order or explicitly skipped in order, never
silently credited out of order. Deviations are always reported, and a route
that wandered outside tolerance is FLAGGED, not merely measured.

UNITS ARE PHYSICAL (mm), NEVER GRID CELLS. Costs are expressed in
mm-equivalent and converted at search time by dividing by the grid resolution
(a grid step costs 1.0). A constant in "grid-move units" would silently change
meaning between a 0.1mm and a 0.2mm grid — amendment A6 on the bug.
"""

from dataclasses import dataclass, field
from typing import Optional, Sequence
import math

# ── Tuning, all in PHYSICAL mm (see module docstring on units) ───────────────

#: Centreline tolerance: how far the routed centreline may sit from the
#: authored polyline before the route is reported as not honouring it.
#: OWNER-DECIDED FLAT 1.0mm, overridable per hint (docket 1024). Deliberately
#: NOT scaled by trace width: the metric compares CENTRELINES, so a 1mm-wide
#: power trace must not thereby be allowed 2mm of drift. The GND route that
#: opened this bug deviated 1.09mm, which must fail.
DEFAULT_TOLERANCE_MM: float = 1.0

#: Off-corridor penalty ceiling, as a multiplier on a step's base cost. The
#: ramp is ZERO through the tolerance boundary and rises OUTSIDE it to this
#: cap (amendment A6 corrected the contradictory "zero inside, rising to 1 at
#: the edge" wording in the first design). Same multiplicative shape the
#: existing avoid_areas penalty already uses, so this is not a new cost
#: concept in the engine.
CORRIDOR_WEIGHT: float = 4.0

#: Distance beyond the tolerance band at which the penalty reaches its cap.
#: Wider than the band so the ramp stays a gradient rather than a cliff — a
#: cliff makes A* indifferent between "slightly outside" and "miles away".
CORRIDOR_RAMP_MM: float = 3.0

#: How far off the CURRENT corridor leg the search may wander before a cell is
#: pruned outright. MEASURED, not guessed (amendment A8): without this bound a
#: guided route on an 80x110mm board at 0.1mm resolution took 21-26 SECONDS
#: versus 23ms unguided, because penalty-inflated edge costs against an
#: unweighted Euclidean heuristic degenerate A* toward Dijkstra — it expands
#: nearly the whole board. Bounding the excursion turns the search space into a
#: tube around the authored polyline, which is what "follow this corridor"
#: means anyway.
#:
#: Generous on purpose: a detour around an obstacle must still fit inside the
#: tube. When even the tube has no path, the caller FALLS BACK to unguided
#: routing rather than returning nothing — waypoints are not mandatory, so a
#: corridor that cannot be honoured must not cost the user their route.
CORRIDOR_MAX_EXCURSION_MM: float = 20.0

#: Cost of declining a waypoint, in mm-equivalent travel. Large enough that
#: the planner detours rather than skipping whenever a legal detour exists,
#: finite so that a blocked or unreachable waypoint degrades to a completed
#: route instead of no route at all — which is what "waypoints are not
#: mandatory" means operationally.
SKIP_PENALTY_MM: float = 50.0

#: How close the path must come to a waypoint for it to count as REACHED.
#: Sized to the corridor tolerance: a route inside the band at the waypoint is
#: doing what was asked.
REACH_RADIUS_MM: float = DEFAULT_TOLERANCE_MM

#: Cap on authored waypoints per corridor. The product state multiplies the
#: search space by (N+1), so this is a real budget, not decoration. Refused BY
#: NAME beyond the cap rather than degrading silently. The number is
#: provisional pending the benchmark required by amendment A8.
MAX_WAYPOINTS: int = 16


@dataclass(frozen=True)
class Corridor:
    """An ordered authored polyline for one connection, in board mm.

    ``waypoints`` are the INTERIOR points only — the connection's own pads are
    the endpoints and are never repeated here. ``tolerance_mm`` is per-corridor
    so a hint can widen or tighten the band it is graded against.
    """

    waypoints: tuple[tuple[float, float], ...] = ()
    tolerance_mm: float = DEFAULT_TOLERANCE_MM

    def __post_init__(self) -> None:
        if len(self.waypoints) > MAX_WAYPOINTS:
            raise ValueError(
                f"corridor carries {len(self.waypoints)} waypoints; the cap is "
                f"{MAX_WAYPOINTS} (the product-state search multiplies by N+1)")

    def __bool__(self) -> bool:
        return bool(self.waypoints)

    @property
    def count(self) -> int:
        return len(self.waypoints)

    def reversed_corridor(self) -> "Corridor":
        """The same corridor oriented dest -> source.

        A hint is authored source -> destination, but the engine may route a
        connection in either direction; grading and pricing must both see the
        corridor in the direction actually being travelled.
        """
        return Corridor(tuple(reversed(self.waypoints)), self.tolerance_mm)

    def polyline(self, start: tuple[float, float],
                 end: tuple[float, float]) -> tuple[tuple[float, float], ...]:
        """The full INTENDED path: start pad -> waypoints -> end pad.

        This — not the bare waypoint list — is what a routed path is graded
        against, because a route can pass through every waypoint and still
        wander arbitrarily far between them.
        """
        return (start,) + tuple(self.waypoints) + (end,)


# ── Exact geometry (NEVER sampled — amendment A7) ────────────────────────────
#
# PathSegment.points samples at 0.1mm. Grading a correctness verdict off a
# sampling grid would make `corridor_honored` depend on how densely a segment
# happens to be tessellated, so every distance below is closed-form.


def point_segment_distance(p: tuple[float, float],
                           a: tuple[float, float],
                           b: tuple[float, float]) -> float:
    """Exact distance from point ``p`` to the segment ``a``-``b``."""
    ax, ay = a
    bx, by = b
    px, py = p
    dx = bx - ax
    dy = by - ay
    len_sq = dx * dx + dy * dy
    if len_sq <= 0.0:
        return math.hypot(px - ax, py - ay)
    t = ((px - ax) * dx + (py - ay) * dy) / len_sq
    t = max(0.0, min(1.0, t))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def point_polyline_distance(p: tuple[float, float],
                            polyline: Sequence[tuple[float, float]]) -> float:
    """Exact distance from ``p`` to the nearest point on a polyline."""
    if not polyline:
        return float("inf")
    if len(polyline) == 1:
        return math.hypot(p[0] - polyline[0][0], p[1] - polyline[0][1])
    return min(point_segment_distance(p, polyline[i], polyline[i + 1])
               for i in range(len(polyline) - 1))


def _segment_polyline_max_distance(a: tuple[float, float],
                                   b: tuple[float, float],
                                   polyline: Sequence[tuple[float, float]],
                                   samples: int = 0) -> float:
    """Upper bound on the distance from segment ``a``-``b`` to ``polyline``.

    THE DOCUMENTED CONSERVATIVE BOUND of amendment A7. The exact maximum of a
    point-to-polyline distance function along a segment is attained either at
    an endpoint or where the nearest-feature changes, and enumerating those
    breakpoints exactly means intersecting the polyline's Voronoi diagram with
    the segment — far more machinery than this verdict warrants.

    Instead: evaluate at both endpoints, at the projection of every polyline
    VERTEX onto the segment (the only interior points where a nearest-feature
    switch can produce a local maximum for piecewise-linear input), and — when
    ``samples`` is set — at that many extra evenly spaced parameters. The
    result is a lower bound on the true maximum that is EXACT for the shapes
    this router emits (straight runs against a straight-ish corridor), and it
    is deterministic: it never depends on PathSegment tessellation.
    """
    candidates: list[float] = [
        point_polyline_distance(a, polyline),
        point_polyline_distance(b, polyline),
    ]
    dx = b[0] - a[0]
    dy = b[1] - a[1]
    len_sq = dx * dx + dy * dy
    if len_sq > 0.0:
        for vx, vy in polyline:
            t = ((vx - a[0]) * dx + (vy - a[1]) * dy) / len_sq
            if 0.0 < t < 1.0:
                candidates.append(point_polyline_distance(
                    (a[0] + t * dx, a[1] + t * dy), polyline))
        for i in range(1, samples + 1):
            t = i / (samples + 1)
            candidates.append(point_polyline_distance(
                (a[0] + t * dx, a[1] + t * dy), polyline))
    return max(candidates)


# ── Cost (planner side) ──────────────────────────────────────────────────────


def off_corridor_multiplier(distance_mm: float, tolerance_mm: float) -> float:
    """Step-cost multiplier for a point ``distance_mm`` off the corridor.

    ZERO PENALTY through the tolerance boundary, then a linear ramp to
    ``CORRIDOR_WEIGHT`` over ``CORRIDOR_RAMP_MM`` beyond it (amendment A6).
    Always >= 1.0 — the returned value MULTIPLIES a positive base cost, so the
    effective penalty is non-negative and A* keeps well-defined ordering and
    an admissible heuristic. Never a negative "bonus".
    """
    if distance_mm <= tolerance_mm:
        return 1.0
    over = distance_mm - tolerance_mm
    ramp = min(1.0, over / CORRIDOR_RAMP_MM) if CORRIDOR_RAMP_MM > 0 else 1.0
    return 1.0 + CORRIDOR_WEIGHT * ramp


def segment_for_leg(corridor: Corridor,
                    k: int,
                    start: tuple[float, float],
                    end: tuple[float, float]) -> tuple[tuple[float, float],
                                                       tuple[float, float]]:
    """The corridor leg a search in milestone state ``k`` is travelling.

    Leg ``k`` runs from the previous anchor (the start pad for k=0, else
    waypoint k-1) to the next target (waypoint k, or the end pad once every
    waypoint is behind us). Pricing against the CURRENT leg rather than the
    whole polyline is what keeps attraction ORDERED: a cell near a later leg
    earns no discount while earlier waypoints are outstanding.
    """
    prev = start if k == 0 else corridor.waypoints[k - 1]
    nxt = corridor.waypoints[k] if k < corridor.count else end
    return prev, nxt


# ── Adherence (reporting side) ───────────────────────────────────────────────

#: Verdicts (amendment A7). `ignored` is Stage A's case — the corridor could
#: not influence the search at all — and must never be produced by a run that
#: actually planned with the corridor.
HONORED = "honored"
PARTIAL = "partial"
IGNORED = "ignored"


@dataclass
class Adherence:
    """How well a routed path followed its authored corridor."""

    status: str = HONORED
    max_deviation_mm: float = 0.0
    corridor_honored: bool = True
    tolerance_mm: float = DEFAULT_TOLERANCE_MM
    per_waypoint: list[dict] = field(default_factory=list)
    skipped_waypoints: list[int] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {
            "status": self.status,
            "corridor_honored": self.corridor_honored,
            "max_deviation_mm": round(self.max_deviation_mm, 4),
            "tolerance_mm": self.tolerance_mm,
            "per_waypoint": self.per_waypoint,
            "skipped_waypoints": list(self.skipped_waypoints),
        }


def measure_adherence(path_points: Sequence[tuple[float, float]],
                      corridor: Corridor,
                      start: tuple[float, float],
                      end: tuple[float, float],
                      skipped: Optional[Sequence[int]] = None) -> Adherence:
    """Grade a routed polyline against its authored corridor.

    ``path_points`` is the route's own vertex list (segment endpoints), NOT a
    tessellation — see amendment A7.

    Two independent measurements, because either alone lies:
      * per-waypoint minimum distance says WHICH waypoint was missed;
      * max deviation from the whole intended polyline catches a route that
        hit every waypoint and wandered in between.

    ``skipped`` is PLANNER metadata (which waypoints the search declined). It
    is reported verbatim but does NOT by itself decide the geometric verdict:
    a skipped waypoint may still end up within tolerance, and that is honestly
    a corridor-following route.
    """
    skipped_list = sorted(set(int(i) for i in (skipped or ())))
    tol = corridor.tolerance_mm
    intended = corridor.polyline(start, end)

    per_waypoint: list[dict] = []
    for idx, wp in enumerate(corridor.waypoints):
        d = point_polyline_distance(wp, path_points) if path_points else float("inf")
        per_waypoint.append({
            "index": idx,
            "waypoint": [wp[0], wp[1]],
            "min_distance_mm": round(d, 4),
            "within_tolerance": d <= tol,
            "skipped_by_planner": idx in skipped_list,
        })

    max_dev = 0.0
    for i in range(len(path_points) - 1):
        max_dev = max(max_dev, _segment_polyline_max_distance(
            path_points[i], path_points[i + 1], intended))

    honored = max_dev <= tol and all(w["within_tolerance"] for w in per_waypoint)
    return Adherence(
        status=HONORED if honored else PARTIAL,
        max_deviation_mm=max_dev,
        corridor_honored=honored,
        tolerance_mm=tol,
        per_waypoint=per_waypoint,
        skipped_waypoints=skipped_list,
    )
