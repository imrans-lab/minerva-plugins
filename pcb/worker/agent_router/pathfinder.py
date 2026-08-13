"""
Pathfinding algorithms for PCB routing.

Implements direct path, L-shaped path, and A* algorithms for finding
routes between pads while avoiding obstacles.
"""

from dataclasses import dataclass, field
from typing import Optional
import heapq
import math

from .grid import RoutingGrid
from . import corridor as corridor_mod
from .corridor import Corridor


@dataclass
class PathSegment:
    """A single segment of a path (straight line)."""
    start: tuple[float, float]
    end: tuple[float, float]
    layer: str = "F.Cu"

    def length(self) -> float:
        """Calculate segment length."""
        dx = self.end[0] - self.start[0]
        dy = self.end[1] - self.start[1]
        return math.sqrt(dx * dx + dy * dy)

    @property
    def points(self) -> list[tuple[float, float]]:
        """Get all points along this segment at reasonable resolution."""
        points = [self.start]
        length = self.length()
        if length > 0.1:  # More than 0.1mm
            steps = int(math.ceil(length / 0.1))
            dx = self.end[0] - self.start[0]
            dy = self.end[1] - self.start[1]
            for i in range(1, steps):
                t = i / steps
                points.append((
                    self.start[0] + t * dx,
                    self.start[1] + t * dy
                ))
        points.append(self.end)
        return points


@dataclass
class Path:
    """A complete path from start to end, possibly with multiple segments."""
    segments: list[PathSegment] = field(default_factory=list)
    net: Optional[str] = None
    vias: list[tuple[float, float]] = field(default_factory=list)

    @property
    def start(self) -> Optional[tuple[float, float]]:
        """Get path start position."""
        if self.segments:
            return self.segments[0].start
        return None

    @property
    def end(self) -> Optional[tuple[float, float]]:
        """Get path end position."""
        if self.segments:
            return self.segments[-1].end
        return None

    def total_length(self) -> float:
        """Calculate total path length."""
        return sum(seg.length() for seg in self.segments)

    def passes_through(self, x: float, y: float, tolerance: float = 0.5) -> bool:
        """
        Check if path passes through a point.

        Args:
            x: X coordinate
            y: Y coordinate
            tolerance: Distance tolerance

        Returns:
            True if path passes within tolerance of the point
        """
        for segment in self.segments:
            for point in segment.points:
                dist = math.sqrt((point[0] - x) ** 2 + (point[1] - y) ** 2)
                if dist <= tolerance:
                    return True
        return False


def find_path(
    grid: RoutingGrid,
    start: tuple[float, float],
    end: tuple[float, float],
    net: str,
    layer: str = "F.Cu",
    allow_via: bool = False,
    avoid_areas: Optional[list] = None,
    preferred_direction: Optional[str] = None,
    prefer_orthogonal: bool = False,
    corridor: Optional[Corridor] = None,
) -> Optional[Path]:
    """
    Find a path from start to end avoiding obstacles.

    Tries in order:
    1. Direct path — the free chord, which may be diagonal (skipped when
       prefer_orthogonal=True)
    2. L-shaped path (one bend). NOT one bend when the endpoints share a row or
       a column: there is no L between two axis-aligned points, and
       :func:`_try_l_path` emits the straight run instead. So an axis-aligned
       pair still reaches :func:`_try_direct_path` under prefer_orthogonal — via
       step 2 rather than step 1, and only for a run that is already orthogonal.
    3. A* path (multiple bends)
    4. Via + alternate layer (if allow_via=True)

    NO EMITTED SEGMENT IS EVER ZERO-LENGTH (docket 019f9cc3245d). Degenerate
    copper is not modelable downstream — ``pcb_worker.ir_candidates`` raises
    ``UnsupportedGeometry`` on a zero-length leg and the whole candidate batch
    becomes INDETERMINATE, so one degenerate leg blinds the geometric verdict for
    every other route checked with it. The guard below and the axis-aligned
    branches in :func:`_try_l_path` / :func:`_collapse_run` are where that
    degeneracy was produced.

    THIS IS A CLAIM ABOUT LENGTH ONLY. It is NOT the stronger "every emitted
    segment is grid-verified" — see :func:`_segment_clear` for the measured gap
    that claim would paper over.

    Args:
        grid: Routing grid with obstacles marked
        start: Start position (x, y)
        end: End position (x, y)
        net: Net name for this path
        layer: Starting layer
        allow_via: Whether to allow layer changes
        avoid_areas: Optional list of AvoidArea objects (cost penalty, not hard block)
        preferred_direction: Optional direction hint ("right_first", "down_first", etc.)
        prefer_orthogonal: If True, skip diagonal direct paths and restrict A* to cardinal directions

    Returns:
        Path if found, None if no valid path exists
    """
    # NOTHING TO ROUTE. Coincident endpoints have no segment between them, and
    # the only "path" any strategy below can build for them is a zero-length one
    # (`_try_direct_path` would happily emit it — `_segment_clear` probes a
    # single point and passes). None is this function's own documented "no valid
    # path exists", so the caller records the pair as unrouted instead of being
    # handed copper of zero extent.
    if start == end:
        return None

    # ── AUTHORED CORRIDOR: one planner, one objective (amendment A2) ─────────
    #
    # When the caller supplied a corridor, the direct/L shortcuts are SKIPPED
    # rather than tried-and-scored. Two reasons, both from review:
    #
    #  * They pre-empt. They return BEFORE A* is ever reached, so a corridor
    #    cost that lived only in A* would leave this bug unfixed for exactly
    #    the routes that opened it (the VBAT span is a plain L). This is the
    #    "fix ships green, repro unchanged" trap.
    #  * Scoring them alongside a corridor search would mean comparing a
    #    lexicographic preference (adherence, then length) against A*'s scalar
    #    (length + corridor + skip). Those are different objectives and the
    #    argmin of one need not win the other.
    #
    # A straight or L-shaped route that genuinely follows the corridor is
    # REPRESENTABLE in the product-state search's own output and wins there on
    # its own merits — so nothing is lost by not enumerating it separately.
    # (It also sidesteps _try_l_path returning its FIRST clear corner rather
    # than the better of the two.)
    #
    # Layer choice stays a WHOLE-PATH decision, as it already is: each
    # candidate below is internally layer-consistent, so there is no
    # concatenation of legs and therefore none of the layer-discontinuity
    # hazard that a sequential sub-search design would carry.
    if corridor:
        best: Optional[Path] = None
        best_cost = float("inf")
        for cand_layer, via_cost in _corridor_layer_candidates(grid, layer, allow_via):
            found = _corridor_astar(
                grid, start, end, net, cand_layer, corridor,
                avoid_areas=avoid_areas, prefer_orthogonal=prefer_orthogonal)
            if not found:
                continue
            cand, skipped = found
            cost = _corridor_objective(cand, corridor, start, end, skipped, via_cost)
            if cost < best_cost:
                best, best_cost = cand, cost
        # ATOMIC: a corridor route is emitted whole or not at all — a partial
        # corridor walk is never returned.
        if best is not None:
            # A corridor route planned on a NON-requested layer reaches that
            # layer through a via — record it (epoch GA-2 fix; before this,
            # the corridor branch was the one layer-changing path that
            # reported ZERO vias: copper on the other side with nothing
            # joining it). Same convention as _try_via_path: the via sits at
            # the route's start, where the pad's layer transitions.
            if best.segments and best.segments[0].layer != layer and not best.vias:
                best.vias = [start]
            return best
        # NO CORRIDOR ROUTE EXISTS (obstacles, or none inside the bounded
        # excursion). Waypoints are NOT mandatory — the approved semantics —
        # so falling through to ordinary routing is the honest degrade: the
        # user keeps their connection, and the adherence report says the
        # corridor was not followed. Refusing here would make a rough authored
        # corridor cost someone a route, which is the opposite of guidance.

    # Try direct path first (skip when prefer_orthogonal — a free chord may be
    # diagonal; the axis-aligned case still reaches it, through _try_l_path)
    if not prefer_orthogonal:
        path = _try_direct_path(grid, start, end, net, layer)
        if path:
            return path

    # Try L-shaped path (ordered by preferred_direction)
    path = _try_l_path(grid, start, end, net, layer,
                       preferred_direction=preferred_direction)
    if path:
        return path

    # Try A* pathfinding (with avoid_areas cost penalty)
    path = _astar_path(grid, start, end, net, layer,
                       avoid_areas=avoid_areas,
                       prefer_orthogonal=prefer_orthogonal)
    if path:
        return path

    # Try with via if allowed. Every OTHER grid layer is a candidate (epoch
    # GA-2; before that a binary F.Cu<->B.Cu flip), tried nearest-in-stack
    # first: a through via reaches every layer equally, but preferring the
    # adjacent plane keeps 2-layer behaviour byte-identical (B.Cu is still the
    # first and only candidate) and gives deeper stacks a stable, explainable
    # order rather than a dict-order accident.
    if allow_via:
        try:
            layer_index = grid.layers.index(layer)
        except ValueError:
            layer_index = 0
        others = sorted((lyr for lyr in grid.layers if lyr != layer),
                        key=lambda lyr: abs(grid.layers.index(lyr) - layer_index))
        for other_layer in others:
            path = _try_via_path(grid, start, end, net, layer, other_layer,
                                 prefer_orthogonal=prefer_orthogonal)
            if path:
                return path

    return None


# Reason codes for a refused connection — see :func:`unroutable_reason`.
UNROUTABLE_COINCIDENT = "coincident_endpoints"
UNROUTABLE_OUT_OF_BOUNDS = "endpoint_out_of_bounds"
UNROUTABLE_START_BLOCKED = "start_blocked"
UNROUTABLE_END_BLOCKED = "end_blocked"
UNROUTABLE_NO_PATH = "no_path"


def unroutable_reason(
    grid: RoutingGrid,
    start: tuple[float, float],
    end: tuple[float, float],
    net: str,
    layer: str = "F.Cu",
) -> str:
    """Classify WHY :func:`find_path` refused a connection.

    Round C2b made two refusals possible that previously returned copper: an A*
    search out of a cell that is blocked for this net (019f9bf9c04a) and a
    coincident-endpoint pair. Both are strictly better than what they replaced —
    the first used to emit a segment starting inside foreign copper — but they
    land the pair in ``RoutingResult.unrouted`` with no explanation, where a pad
    covered by an NPTH/mounting-hole keepout looks exactly like a congested
    board. That is ORDINARY board data, and a user who cannot tell those apart
    cannot act on either.

    RE-PROBES RATHER THAN BEING THREADED THROUGH. ``find_path`` returns
    ``Optional[Path]``, and every caller and test depends on that; a second
    return value would ripple through four call sites to answer a question only
    the failure path asks. This asks the grid the SAME questions ``find_path``'s
    strategies asked, through the same owner (``can_route_through``), so it
    cannot disagree with them by construction — it can only be stale, and the
    grid does not change between the two calls.

    SCOPE OF THE ANSWER: it describes *layer*, the layer the primary attempt
    used. With ``allow_via=True`` the alternate layer was also tried and also
    failed; a ``start_blocked`` answer therefore means "blocked on the layer this
    connection was asked for", not "blocked everywhere".
    """
    if start == end:
        return UNROUTABLE_COINCIDENT
    for point in (start, end):
        if not grid._cell_in_bounds(*grid._pos_to_cell(point[0], point[1])):
            return UNROUTABLE_OUT_OF_BOUNDS
    if not grid.can_route_through(start[0], start[1], net, layer):
        return UNROUTABLE_START_BLOCKED
    if not grid.can_route_through(end[0], end[1], net, layer):
        return UNROUTABLE_END_BLOCKED
    return UNROUTABLE_NO_PATH


def _try_direct_path(
    grid: RoutingGrid,
    start: tuple[float, float],
    end: tuple[float, float],
    net: str,
    layer: str
) -> Optional[Path]:
    """Try a direct straight-line path."""
    if not _segment_clear(grid, start, end, net, layer):
        return None

    return Path(segments=[PathSegment(start=start, end=end, layer=layer)], net=net)


def _try_l_path(
    grid: RoutingGrid,
    start: tuple[float, float],
    end: tuple[float, float],
    net: str,
    layer: str,
    preferred_direction: Optional[str] = None,
) -> Optional[Path]:
    """Try an L-shaped path with one bend.

    When *preferred_direction* is set, the corner attempt order is
    adjusted:
    - ``"right_first"`` / ``"left_first"``: try horizontal-then-vertical first
    - ``"down_first"`` / ``"up_first"``: try vertical-then-horizontal first

    THERE IS NO L BETWEEN TWO AXIS-ALIGNED POINTS (docket 019f9cc3245d,
    severity 2). Both candidate corners are built FROM the endpoints' own
    coordinates, so when the endpoints share a row (``start[1] == end[1]``) the
    horizontal-first corner ``(end[0], start[1])`` IS ``end`` and the
    vertical-first corner ``(start[0], end[1])`` IS ``start``; when they share a
    column the two swap roles. Either way one leg of the "L" has zero length, and
    the emitted path was a straight run with a degenerate stub bolted to one end.
    Measured before the fix, on a 50x50 grid at 0.2mm with nothing marked:
    ``find_path((10,20) -> (30,20), prefer_orthogonal=True)`` returned 2 segments,
    the second ``(30,20) -> (30,20)``; the vertical mirror
    ``(20,10) -> (20,30)`` returned 2 segments with the FIRST one degenerate.

    THE FIX IS HERE, AT THE PRODUCER, not at the downstream guard that rejects
    the degenerate leg — relaxing that guard would admit degenerate copper rather
    than stop it being made. It is also here rather than in :func:`find_path`,
    because :func:`_try_via_path` calls this function directly: a fix that only
    tried a direct path earlier in ``find_path`` would leave the via strategy
    still emitting stubs.

    ADMITS EXACTLY THE SAME RUNS AS BEFORE. The old code accepted an axis-aligned
    pair when ``_l_segments_clear`` passed, i.e. when ``_segment_clear(start,
    corner)`` and ``_segment_clear(corner, end)`` both passed — and with a
    degenerate corner one of those two IS the full straight run while the other is
    a single-point probe of an endpoint the full run already covers. So delegating
    to :func:`_try_direct_path` asks the identical question of the grid and
    accepts the identical set of paths; only the segment COUNT changes, 2 -> 1.
    The degeneracy test is exact equality rather than a tolerance because the
    condition really is bitwise: the corner is the endpoint coordinate itself, and
    the downstream guard this exists to keep satisfied
    (``ir_candidates``' ``a == b``) is exact too.
    """
    if start[0] == end[0] or start[1] == end[1]:
        return _try_direct_path(grid, start, end, net, layer)

    # Default order: horizontal-first then vertical-first
    corner_h = (end[0], start[1])  # horizontal then vertical
    corner_v = (start[0], end[1])  # vertical then horizontal

    # Reorder based on preferred direction
    if preferred_direction in ("down_first", "up_first"):
        corners = [corner_v, corner_h]
    else:
        corners = [corner_h, corner_v]

    for corner in corners:
        path = _check_l_path(grid, start, corner, end, net, layer)
        if path:
            return path

    return None


def _check_l_path(
    grid: RoutingGrid,
    start: tuple[float, float],
    corner: tuple[float, float],
    end: tuple[float, float],
    net: str,
    layer: str
) -> Optional[Path]:
    """Check if an L-shaped path through a corner is valid."""
    if not _l_segments_clear(grid, start, corner, end, net, layer):
        return None

    return Path(segments=[PathSegment(start=start, end=corner, layer=layer),
                          PathSegment(start=corner, end=end, layer=layer)],
                net=net)


def _astar_path(
    grid: RoutingGrid,
    start: tuple[float, float],
    end: tuple[float, float],
    net: str,
    layer: str,
    avoid_areas: Optional[list] = None,
    prefer_orthogonal: bool = False,
) -> Optional[Path]:
    """
    Find path using A* algorithm on the grid.

    Uses grid cells as nodes. When prefer_orthogonal is True, only
    cardinal (4-directional) movement is allowed; otherwise 8-directional.
    Cells inside *avoid_areas* get a cost penalty (not a hard block).
    """
    # Convert positions to grid cells
    start_cell = grid._pos_to_cell(start[0], start[1])
    end_cell = grid._pos_to_cell(end[0], end[1])

    if not grid._cell_in_bounds(*start_cell) or not grid._cell_in_bounds(*end_cell):
        return None

    # THE START CELL IS VALIDATED, LIKE EVERY OTHER CELL (docket 019f9bf9c04a).
    # The expansion loop below asks `can_route_through` about every NEIGHBOUR it
    # steps into, and never about the cell it starts from — so a search launched
    # from a blocked cell emitted a path whose first point sits in foreign copper.
    # Round B1a's induction ("every emitted segment is either a verified chord or
    # an original A* step") holds for the steps but not for the origin, and the
    # two-point case makes it visible: `_simplify_path`/`_simplify_orthogonal`
    # return a 2-point list untouched, so `start -> end` is emitted with no chord
    # verification at all.
    #
    # WHY REFUSE HERE RATHER THAN VERIFY THE TWO-POINT CHORD (the docket's other
    # option): a blocked start is unroutable however many points the path has, so
    # the honest answer is the same for all of them, and the two sibling
    # strategies already give it — `_try_direct_path` and `_try_l_path` both probe
    # `start` through `_segment_clear` and return None. This makes all three
    # agree instead of leaving A* alone in accepting an origin the others refuse.
    #
    # WHY None RATHER THAN AN EXCEPTION. Checked the callers: `route_board`
    # (router.py) and `route_board_with_hints` pass `pad_a.position` for a pad OF
    # the net being routed, and `mark_pad` stamps that pad's cell with that same
    # net, so `can_route_through` returns True for its owner — no legitimate
    # caller routes out of a blocked start today, which is the docket's condition
    # for preferring this closure. What CAN block it is board data, not a
    # programming error: foreign copper or an obstacle marked over the pad. Both
    # callers already handle "no path" by recording the pair in `result.unrouted`;
    # neither handles an exception, so raising would turn a dirty board into a
    # crashed route call.
    if not grid.can_route_through(start[0], start[1], net, layer):
        return None

    # A* algorithm
    # Priority queue: (f_score, counter, cell)
    counter = 0
    open_set = [(0, counter, start_cell)]
    came_from: dict[tuple[int, int], tuple[int, int]] = {}
    g_score: dict[tuple[int, int], float] = {start_cell: 0}

    # Cardinal only when prefer_orthogonal, otherwise 8-directional
    if prefer_orthogonal:
        directions = [
            (1, 0), (-1, 0), (0, 1), (0, -1),  # Cardinal only
        ]
    else:
        directions = [
            (1, 0), (-1, 0), (0, 1), (0, -1),  # Cardinal
            (1, 1), (1, -1), (-1, 1), (-1, -1)  # Diagonal
        ]

    # Cost multiplier for cells inside avoid areas
    avoid_penalty = 5.0

    while open_set:
        _, _, current = heapq.heappop(open_set)

        if current == end_cell:
            # Reconstruct path
            return _reconstruct_path(came_from, current, start, end, net, layer, grid,
                                     prefer_orthogonal=prefer_orthogonal)

        for dx, dy in directions:
            neighbor = (current[0] + dx, current[1] + dy)

            if not grid._cell_in_bounds(*neighbor):
                continue

            # Convert cell to position for collision check
            # Cell -> WORLD through the grid's single transform owner, so a
            # non-zero board origin is honoured here too (019f783860c8 gap C).
            nx, ny = grid._cell_to_pos(*neighbor)

            if not grid.can_route_through(nx, ny, net, layer):
                continue

            # A diagonal step's straight chord passes through the corner shared
            # by the two cells orthogonally adjacent to `current` and `neighbor`
            # — (current[0]+dx, current[1]) and (current[0], current[1]+dy). Those
            # are never asked about above: the loop only validates the
            # DESTINATION cell, and for a diagonal step that is not the same as
            # the straight line between the two cell centres. If either
            # corner-adjacent cell is not routable, the chord clips it even
            # though both `current` and `neighbor` are themselves clear, so
            # reject the step (019f9d594f83). Same predicate as the destination
            # check above, so one notion of "blocked" governs the whole step.
            #
            # No bounds check needed on the corner cells: `neighbor` already
            # passed `_cell_in_bounds` above, so (current[0]+dx, current[1])
            # takes its column from `neighbor` and its row from `current` — both
            # already known valid — and symmetrically for the other corner cell.
            if dx != 0 and dy != 0:
                corner1 = grid._cell_to_pos(current[0] + dx, current[1])
                corner2 = grid._cell_to_pos(current[0], current[1] + dy)
                if not grid.can_route_through(corner1[0], corner1[1], net, layer):
                    continue
                if not grid.can_route_through(corner2[0], corner2[1], net, layer):
                    continue

            # Calculate cost (diagonal is sqrt(2) times cardinal)
            move_cost = math.sqrt(2) if dx != 0 and dy != 0 else 1.0

            # Apply avoid area penalty
            if avoid_areas:
                for area in avoid_areas:
                    if hasattr(area, 'contains') and area.contains(nx, ny):
                        move_cost *= avoid_penalty
                        break

            tentative_g = g_score[current] + move_cost

            if neighbor not in g_score or tentative_g < g_score[neighbor]:
                came_from[neighbor] = current
                g_score[neighbor] = tentative_g
                # Heuristic: Euclidean distance
                h = math.sqrt(
                    (neighbor[0] - end_cell[0]) ** 2 +
                    (neighbor[1] - end_cell[1]) ** 2
                )
                f_score = tentative_g + h
                counter += 1
                heapq.heappush(open_set, (f_score, counter, neighbor))

    return None


def _simplify_points(
    points: list[tuple[float, float]],
    grid: RoutingGrid,
    net: str,
    layer: str,
    prefer_orthogonal: bool,
) -> list[tuple[float, float]]:
    """The existing grid-aware simplification, as one reusable step."""
    if prefer_orthogonal:
        simplified = _simplify_orthogonal(points, grid, net, layer)
        return _collapse_staircases(simplified, grid, net, layer)
    return _simplify_path(points, grid, net, layer)


def _segments_from_points(points: list[tuple[float, float]],
                          layer: str) -> list[PathSegment]:
    """Points -> segments, DROPPING zero-length pairs.

    Zero-length copper is not modelable downstream (see find_path's docstring
    and docket 019f9cc3245d). Coincident consecutive points arise legitimately
    here: a corridor's REACH/SKIP transitions change milestone state without
    moving the cell, so the raw walk can repeat a position.
    """
    segments: list[PathSegment] = []
    for i in range(len(points) - 1):
        a, b = points[i], points[i + 1]
        if a == b:
            continue
        segments.append(PathSegment(start=a, end=b, layer=layer))
    return segments


#: Cost, in mm-equivalent, charged for the layer change a via represents when
#: comparing corridor candidates across layers. Physical units, converted like
#: every other corridor cost (amendment A6). It exists so a corridor route that
#: needs a via is not preferred over an equally corridor-faithful single-layer
#: one purely because the other layer happened to be emptier.
CORRIDOR_VIA_COST_MM: float = 8.0


def _corridor_layer_candidates(grid, layer: str,
                               allow_via: bool) -> list[tuple[str, float]]:
    """Layers a corridor route may be planned on, with each one's via cost.

    The requested layer is free; every OTHER grid layer (epoch GA-2; formerly
    a binary flip) is offered only when vias are permitted and carries
    CORRIDOR_VIA_COST_MM — one flat cost, because the via that reaches any of
    them is the same through-hole. Candidates keep stack order, so on a
    2-layer grid this is byte-identically the old [(layer, 0), (other, 8.0)]
    list. Every candidate is a WHOLE path — this is what keeps layer choice a
    single, internally consistent decision instead of something threaded
    across legs.
    """
    out = [(layer, 0.0)]
    if allow_via:
        out.extend((lyr, CORRIDOR_VIA_COST_MM)
                   for lyr in grid.layers if lyr != layer)
    return out


def _corridor_objective(path: Path,
                        corridor: Corridor,
                        start: tuple[float, float],
                        end: tuple[float, float],
                        skipped: list[int],
                        via_cost_mm: float) -> float:
    """ONE scalar (amendment A2) ranking corridor candidates.

    Deliberately the SAME shape the planner minimises — length plus corridor
    infidelity plus skip cost — so the candidate chosen here is the candidate
    the search itself considered best, rather than the winner of a second,
    differently-shaped preference. Adherence is measured with the exact
    geometry the report uses (amendment A7), so "the planner thought this was
    on-corridor" and "the report grades it on-corridor" cannot disagree.
    """
    points = _path_points(path)
    adherence = corridor_mod.measure_adherence(points, corridor, start, end, skipped)
    return (path.total_length()
            + corridor_mod.CORRIDOR_WEIGHT * adherence.max_deviation_mm
            + corridor_mod.SKIP_PENALTY_MM * len(skipped)
            + via_cost_mm)


def _path_points(path: Path) -> list[tuple[float, float]]:
    """A path's own VERTICES (never PathSegment.points tessellation, A7)."""
    if not path.segments:
        return []
    pts = [path.segments[0].start]
    for seg in path.segments:
        pts.append(seg.end)
    return pts


def _corridor_astar(
    grid: RoutingGrid,
    start: tuple[float, float],
    end: tuple[float, float],
    net: str,
    layer: str,
    corridor: Corridor,
    avoid_areas: Optional[list] = None,
    prefer_orthogonal: bool = False,
) -> Optional[tuple[Path, list[int]]]:
    """PRODUCT-STATE A* over ``(cell, milestone)`` — the Stage B planner.

    THE STRUCTURE (bug 019fcf152791, design comment 1023 as amended by 1024).
    A plain A* keyed on cells cannot express "visit these points IN ORDER":
    ``g_score[cell]`` cannot distinguish standing at a cell having passed
    waypoint 1 from standing at the same cell having not. So the node becomes
    a PAIR ``(cell, k)`` where ``k`` is how many authored waypoints are behind
    us, and the goal is ``(end_cell, N)``.

    Three transitions:
      MOVE  (cell,k) -> (neighbour,k)  base move cost, multiplied by the
                                       off-corridor penalty for the CURRENT
                                       leg (leg k), so attraction is ordered.
      REACH (cell,k) -> (cell,k+1)     free, when the cell is within
                                       REACH_RADIUS of waypoint k.
      SKIP  (cell,k) -> (cell,k+1)     SKIP_PENALTY. This is what makes
                                       waypoints SOFT rather than mandatory:
                                       a blocked or unreachable waypoint costs
                                       one skip and the route still completes.

    INVARIANT (amendment A3, correcting an overclaim in the first design): a
    waypoint is either REACHED in order or explicitly SKIPPED in order — it is
    never silently credited out of order. The search can still shortcut a bend,
    but only by paying for a skip, and the skip is reported.

    COSTS ARE NON-NEGATIVE and expressed in PHYSICAL mm, converted to grid cost
    here (amendment A6) — never a negative "bonus", which would break A*
    ordering, and never a constant in grid units, which would change meaning
    with grid resolution. The heuristic stays Euclidean-to-end: with
    milestones outstanding the true remaining cost is at least the straight
    line to the goal, so it never overestimates and A* stays admissible.
    """
    start_cell = grid._pos_to_cell(start[0], start[1])
    end_cell = grid._pos_to_cell(end[0], end[1])
    if not grid._cell_in_bounds(*start_cell) or not grid._cell_in_bounds(*end_cell):
        return None
    # Same start-cell validation the plain A* performs (docket 019f9bf9c04a).
    if not grid.can_route_through(start[0], start[1], net, layer):
        return None

    res = max(float(getattr(grid, "resolution", 1.0)), 1e-9)
    skip_cost = corridor_mod.SKIP_PENALTY_MM / res
    n = corridor.count
    goal = (end_cell, n)

    if prefer_orthogonal:
        directions = [(1, 0), (-1, 0), (0, 1), (0, -1)]
    else:
        directions = [(1, 0), (-1, 0), (0, 1), (0, -1),
                      (1, 1), (1, -1), (-1, 1), (-1, -1)]
    avoid_penalty = 5.0

    counter = 0
    start_state = (start_cell, 0)
    open_set = [(0.0, counter, start_state)]
    came_from: dict[tuple, tuple] = {}
    g_score: dict[tuple, float] = {start_state: 0.0}

    while open_set:
        _, _, current = heapq.heappop(open_set)
        cell, k = current
        if current == goal:
            return _reconstruct_corridor_path(
                came_from, current, start, end, net, layer, grid,
                prefer_orthogonal, corridor)

        base_g = g_score[current]

        # ── state-only transitions: REACH (free) and SKIP (penalised) ────────
        if k < n:
            pos = grid._cell_to_pos(*cell)
            advance = (cell, k + 1)
            step = 0.0 if _within_reach(pos, corridor, k) else skip_cost
            tentative = base_g + step
            if advance not in g_score or tentative < g_score[advance]:
                came_from[advance] = (current, "reach" if step == 0.0 else "skip")
                g_score[advance] = tentative
                h = math.hypot(cell[0] - end_cell[0], cell[1] - end_cell[1])
                counter += 1
                heapq.heappush(open_set, (tentative + h, counter, advance))

        # ── MOVE ────────────────────────────────────────────────────────────
        leg_a, leg_b = corridor_mod.segment_for_leg(corridor, k, start, end)
        for dx, dy in directions:
            neighbor = (cell[0] + dx, cell[1] + dy)
            if not grid._cell_in_bounds(*neighbor):
                continue
            nx, ny = grid._cell_to_pos(*neighbor)
            if not grid.can_route_through(nx, ny, net, layer):
                continue
            # Diagonal corner-clipping guard, identical to the plain A*.
            if dx != 0 and dy != 0:
                c1 = grid._cell_to_pos(cell[0] + dx, cell[1])
                c2 = grid._cell_to_pos(cell[0], cell[1] + dy)
                if not grid.can_route_through(c1[0], c1[1], net, layer):
                    continue
                if not grid.can_route_through(c2[0], c2[1], net, layer):
                    continue

            move_cost = math.sqrt(2) if dx != 0 and dy != 0 else 1.0
            if avoid_areas:
                for area in avoid_areas:
                    if hasattr(area, "contains") and area.contains(nx, ny):
                        move_cost *= avoid_penalty
                        break
            # Ordered attraction: price against the leg being travelled NOW.
            d = corridor_mod.point_segment_distance((nx, ny), leg_a, leg_b)
            # BOUNDED EXCURSION (amendment A8, measured): prune cells far
            # outside the tube instead of merely taxing them. Penalty-inflated
            # costs make the plain Euclidean heuristic weak, so an unbounded
            # search expands nearly the whole board — 21-26s on the real board
            # at 0.1mm. The bound is what keeps a guided route interactive.
            if d > corridor_mod.CORRIDOR_MAX_EXCURSION_MM:
                continue
            move_cost *= corridor_mod.off_corridor_multiplier(d, corridor.tolerance_mm)

            nxt = (neighbor, k)
            tentative = base_g + move_cost
            if nxt not in g_score or tentative < g_score[nxt]:
                came_from[nxt] = (current, "move")
                g_score[nxt] = tentative
                h = math.hypot(neighbor[0] - end_cell[0], neighbor[1] - end_cell[1])
                counter += 1
                heapq.heappush(open_set, (tentative + h, counter, nxt))

    return None


def _reconstruct_path(
    came_from: dict[tuple[int, int], tuple[int, int]],
    current: tuple[int, int],
    start: tuple[float, float],
    end: tuple[float, float],
    net: str,
    layer: str,
    grid: RoutingGrid,
    prefer_orthogonal: bool = False,
) -> Path:
    """Reconstruct path from A* came_from dict and simplify."""
    # Build list of cells
    cells = [current]
    while current in came_from:
        current = came_from[current]
        cells.append(current)
    cells.reverse()

    # Convert cells to positions
    points = [start]  # Use exact start
    for cell in cells[1:-1]:  # Skip first and last (use exact positions)
        points.append(grid._cell_to_pos(*cell))
    points.append(end)  # Use exact end

    # Simplify: merge collinear points. Both branches are GRID-AWARE — see
    # _simplify_path for why a geometry-only simplifier is not sound here.
    simplified = _simplify_points(points, grid, net, layer, prefer_orthogonal)

    return Path(segments=_segments_from_points(simplified, layer), net=net)


def _reconstruct_corridor_path(
    came_from: dict,
    current: tuple,
    start: tuple[float, float],
    end: tuple[float, float],
    net: str,
    layer: str,
    grid: RoutingGrid,
    prefer_orthogonal: bool,
    corridor: Corridor,
) -> tuple[Path, list[int]]:
    """CORRIDOR-AWARE reconstruction (bug 019fcf152791, amendment A1).

    Two hazards the plain reconstruction above cannot handle, both found in
    review before implementation:

    1. STATE-ONLY STEPS. REACH and SKIP advance the milestone index WITHOUT
       moving the cell, so the raw walk repeats positions. Emitted naively
       those become zero-length segments, which this router forbids.

    2. CORRIDOR-BLIND SIMPLIFICATION. ``_simplify_orthogonal`` /
       ``_collapse_staircases`` / ``_simplify_path`` are obstacle-aware but
       know nothing about the corridor: run across the whole walk they would
       straighten a corridor-following route back into the very shortcut this
       bug is about, and the fix would ship green while the repro still failed.

    THE RULE (amendment A1): reached waypoints are ANCHORS, and anchors
    PARTITION the path. The existing simplifiers run WITHIN each partition and
    never across an anchor. Corridor fidelity is structural — an anchor cannot
    be simplified away because no simplifier is ever handed two of them — while
    the staircase/collinear cleanup that keeps ordinary routes tidy is
    retained inside each leg. This also resolves the tension with amendment A2
    (once direct/L shortcuts are skipped, this output IS the final geometry,
    so it still has to be clean).

    Returns the path and the indices of waypoints the search declined (SKIP),
    which the caller reports as planner metadata — never as the geometric
    verdict (amendment A7).
    """
    # Walk back through (cell, k) states, remembering where milestones were
    # REACHED so those positions survive simplification as anchors.
    states = [current]
    while current in came_from:
        current = came_from[current][0]
        states.append(current)
    states.reverse()

    reached: dict[int, int] = {}      # milestone index -> position index
    skipped: list[int] = []
    points: list[tuple[float, float]] = []
    for i, (cell, k) in enumerate(states):
        if i == 0:
            pos = start
        elif i == len(states) - 1:
            pos = end
        else:
            pos = grid._cell_to_pos(*cell)
        # A state-only transition (REACH/SKIP) repeats the position; keep one
        # copy and record what happened there.
        if points and pos == points[-1]:
            prev_k = states[i - 1][1]
            if k > prev_k:
                # Which milestones advanced here, and how.
                for advanced in range(prev_k, k):
                    if _within_reach(pos, corridor, advanced):
                        reached[advanced] = len(points) - 1
                    else:
                        skipped.append(advanced)
            continue
        prev_k = states[i - 1][1] if i > 0 else 0
        if k > prev_k:
            for advanced in range(prev_k, k):
                if _within_reach(pos, corridor, advanced):
                    reached[advanced] = len(points)
                else:
                    skipped.append(advanced)
        points.append(pos)

    # Partition on anchors and simplify each partition independently.
    anchor_positions = sorted(set(reached.values()))
    bounds = [0] + [a for a in anchor_positions if 0 < a < len(points) - 1] + [len(points) - 1]
    bounds = sorted(set(bounds))

    simplified: list[tuple[float, float]] = []
    for i in range(len(bounds) - 1):
        lo, hi = bounds[i], bounds[i + 1]
        leg = _simplify_points(points[lo:hi + 1], grid, net, layer, prefer_orthogonal)
        # Splice, avoiding a duplicated anchor at the seam.
        simplified.extend(leg if not simplified else leg[1:])

    return (Path(segments=_segments_from_points(simplified, layer), net=net),
            sorted(set(skipped)))


def _within_reach(pos: tuple[float, float], corridor: Corridor, k: int) -> bool:
    """Did ``pos`` actually reach waypoint ``k``, or was the milestone skipped?"""
    if k >= corridor.count:
        return False
    wx, wy = corridor.waypoints[k]
    return math.hypot(pos[0] - wx, pos[1] - wy) <= corridor_mod.REACH_RADIUS_MM


# Numerical tolerance for the swept-cell traversal below, in fractional
# segment length (parametric t, not mm). Matches drc_geom_primitives.EPS
# (1e-9mm, "numerical noise only" per that module's docstring) applied the
# same way: it exists so an exact-at-a-grid-line crossing is not tripped by
# float roundoff, and it is far below anything this module treats as a real
# geometric feature — the acceptance fixture for 019f9fb32de7 pins a sliver
# three orders of magnitude above float noise (see
# tests/agent_router/test_segment_clear_corners.py).
_SWEEP_EPS = 1e-9


def _straddling_indices(v: float, base: float, res: float) -> tuple[int, ...]:
    """Which cell index/indices, along ONE axis, have a closed span touching
    world coordinate *v* (``base`` is that axis's grid origin component).

    Ordinarily a single index: :meth:`RoutingGrid._pos_to_cell`'s
    ``floor((v - base) / res)``. But when *v* sits within ``_SWEEP_EPS`` of a
    lattice line, it is the SHARED edge of two cells (index ``k - 1`` and
    index ``k``, where ``k`` is that line's index) and both are returned —
    ``_pos_to_cell``'s bare floor is a single, arbitrary pick of one side of
    that shared edge, not evidence the chord is actually in only that one
    cell. Used to fix a class of gaps below ``_pos_to_cell``'s single-cell
    answer that the swept-cell traversal would otherwise miss: a chord
    endpoint, a full run collinear with a grid line, or an interior lattice
    corner (see ``_swept_cells``'s docstring for each).
    """
    u = (v - base) / res
    k = round(u)
    if abs(u - k) <= _SWEEP_EPS:
        return (k - 1, k)
    return (math.floor(u),)


def _swept_cells(
    grid: RoutingGrid,
    start: tuple[float, float],
    end: tuple[float, float],
) -> set[tuple[int, int]]:
    """Every grid cell whose closed square the closed chord *start*->*end*
    intersects — EXACT, not sampled. The swept-cell ("supercover") half of the
    ``019f9fb32de7`` fix; see :func:`_segment_clear` for what asks it.

    A straight chord crosses each grid line (vertical ``x = col*res``,
    horizontal ``y = row*res``, in the grid's own origin-relative frame) at
    most once, at a single parametric point ``t`` along the chord. Collecting
    every such crossing — for every grid line the chord's bounding box could
    touch on either axis — and sorting them by ``t`` cuts the chord into
    intervals; each interval's MIDPOINT is a point of the chord that lies
    strictly inside exactly one cell (an interval endpoint sits exactly on a
    grid line, and two points *inside* one interval can never straddle a
    boundary, because the interval was built to stop at the next one). Take
    that cell as "swept" and move to the next interval.

    THIS IS WHAT PATTERN-MATCHES A CORNER GRAZE THAT POINT SAMPLING MISSES.
    A chord that clips a blocked cell's corner for 1e-4mm still crosses that
    cell's two near edges, so it still produces two crossings close together
    in ``t`` and a real (if tiny) interval between them — the interval this
    function reports the cell for. A fixed-step sampler
    (:attr:`PathSegment.points`, 0.1mm) has no mechanism that adapts to an
    interval narrower than its step; this one does, because it is driven by
    the chord's own exact intersections with the lattice, not by a stride.

    CONSERVATIVE BY CONSTRUCTION IS THE GOAL, not by margin: every point
    checked (each interval's midpoint) is a point the real, infinitely-thin
    chord actually passes through, so a cell is only ever reported when the
    chord truly enters its square — this cannot invent a false block. THE
    INTERVAL SWEEP ALONE DOES NOT MEET THAT GOAL, THOUGH (round D10 — the
    round that closed the corner-graze gap above opened a larger one): an
    interval endpoint sits EXACTLY on a grid line, and
    ``_pos_to_cell``'s bare ``floor`` resolves a point on that shared edge to
    one arbitrary side, not both. Three places that matters, all fixed below
    by resolving an on-the-line point to every cell whose CLOSED square
    contains it (see :func:`_straddling_indices`), not just the one
    ``_pos_to_cell`` happens to floor to:

    1. THE CHORD'S OWN ENDPOINTS. If ``start`` or ``end`` itself sits on a
       grid line, the cell ``_segment_clear`` most needs checked — where the
       trace actually begins or ends — could be the one cell this sweep
       omits. Measured at the production grid default (0.1mm resolution,
       0.05mm-quantised endpoints): 44% of random chords omit their start
       cell, 44% their end cell, 70% either.
    2. A CHORD COLLINEAR WITH A GRID LINE FOR ITS FULL LENGTH (``dx == 0`` or
       ``dy == 0``, landing exactly on a lattice line). Every interval
       midpoint along such a chord shares the same on-the-line coordinate, so
       ``_pos_to_cell`` resolves the WHOLE run to one side, leaving every
       cell on the other side of that line unchecked — not a point graze, a
       full row or column.
    3. AN INTERIOR LATTICE CORNER (both axes on a grid line at the same
       parametric ``t``, e.g. an exact 45-degree chord through cell centres).
       That point is shared by up to four cells but is measure-zero on the
       chord, so it never gets a nonzero-width interval of its own; the
       interval sweep silently resolves it to at most the two cells the
       direction of travel happens to pass through. This is the same
       corner a diagonal A* step explicitly checks for
       (``pathfinder.py:444-450``) — left open here until now.

    The one place actual approximation enters is ``_SWEEP_EPS``, which drops
    an interval only when it is un-samplable float noise (see that constant's
    docstring); it does not trade away real geometry.

    Degenerate (``start == end``) is handled by the one-cell case directly —
    :func:`_segment_clear` also short-circuits it, but this function stays
    correct standalone (it is called nowhere else today, but nothing here
    depends on that). It is NOT run through the closed-square treatment above
    — a single point has no "other side" to omit; :func:`_pos_to_cell`'s pick
    is the only cell there is an argument for.
    """
    x0, y0 = start
    x1, y1 = end
    if x0 == x1 and y0 == y1:
        return {grid._pos_to_cell(x0, y0)}

    dx = x1 - x0
    dy = y1 - y0
    res = grid.resolution
    ox, oy = grid.origin

    ts = {0.0, 1.0}

    if dx != 0:
        u0 = (x0 - ox) / res
        u1 = (x1 - ox) / res
        lo, hi = (u0, u1) if u0 <= u1 else (u1, u0)
        for j in range(math.floor(lo), math.ceil(hi) + 1):
            t = (ox + j * res - x0) / dx
            if -_SWEEP_EPS <= t <= 1.0 + _SWEEP_EPS:
                ts.add(min(1.0, max(0.0, t)))

    if dy != 0:
        v0 = (y0 - oy) / res
        v1 = (y1 - oy) / res
        lo, hi = (v0, v1) if v0 <= v1 else (v1, v0)
        for i in range(math.floor(lo), math.ceil(hi) + 1):
            t = (oy + i * res - y0) / dy
            if -_SWEEP_EPS <= t <= 1.0 + _SWEEP_EPS:
                ts.add(min(1.0, max(0.0, t)))

    ordered = sorted(ts)

    # (1) Seed both endpoint cells directly through the grid's own transform,
    # so the sweep agrees with `_pos_to_cell` BY CONSTRUCTION rather than by
    # coincidence — that is the property that actually matters, not merely
    # widening `_SWEEP_EPS` (which changes which slivers get dropped without
    # making the two agree).
    cells: set[tuple[int, int]] = {
        grid._pos_to_cell(x0, y0),
        grid._pos_to_cell(x1, y1),
    }

    for a, b in zip(ordered, ordered[1:]):
        if b - a <= _SWEEP_EPS:
            continue
        tm = (a + b) / 2.0
        cells.add(grid._pos_to_cell(x0 + tm * dx, y0 + tm * dy))

    def _add_if_in_bounds(col: int, row: int) -> None:
        # A "straddling" index pair can name a cell that does not exist (one
        # step past the board's own outer edge, where `_straddling_indices`
        # sees "on a line" but there is no real neighbouring cell on the
        # other side — only an interior grid line has two real cells sharing
        # it). Never register those; `can_route_through` already treats an
        # out-of-bounds probe as blocked (`grid.py` "boundary" obstacle), and
        # adding a phantom out-of-bounds neighbour here would falsely block
        # every chord that merely touches the board's edge exactly.
        if grid._cell_in_bounds(col, row):
            cells.add((col, row))

    # (2) A chord collinear with a grid line for its FULL length: every cell
    # already found above shares the on-the-line coordinate, so mirror each
    # of them across that line's other side.
    if dx == 0:
        cols = _straddling_indices(x0, ox, res)
        if len(cols) == 2:
            for _, r in list(cells):
                _add_if_in_bounds(cols[0], r)
                _add_if_in_bounds(cols[1], r)
    if dy == 0:
        rows = _straddling_indices(y0, oy, res)
        if len(rows) == 2:
            for c, _ in list(cells):
                _add_if_in_bounds(c, rows[0])
                _add_if_in_bounds(c, rows[1])

    # (3) Every point the chord is known to touch a grid line at — every
    # entry of `ordered`, endpoints included — gets checked for an interior
    # LATTICE CORNER (on a line on BOTH axes at once). Cheap and inert for
    # the overwhelming majority of chords: an ordinary single-axis crossing
    # has one axis with a single candidate, so the `== 2 and == 2` guard
    # below never fires for it.
    for t in ordered:
        px, py = x0 + t * dx, y0 + t * dy
        col_candidates = _straddling_indices(px, ox, res)
        row_candidates = _straddling_indices(py, oy, res)
        if len(col_candidates) == 2 and len(row_candidates) == 2:
            for c in col_candidates:
                for r in row_candidates:
                    _add_if_in_bounds(c, r)

    return cells


def _segment_clear(
    grid: RoutingGrid,
    start: tuple[float, float],
    end: tuple[float, float],
    net: str,
    layer: str,
) -> bool:
    """Return True if a straight run from *start* to *end* is routable for *net*.

    THE single owner of "may this net occupy this chord" — the same test
    :func:`_try_direct_path` applies to a one-segment path and
    :func:`_l_segments_clear` applies to each leg of an L. Every chord
    SIMPLIFICATION invents is asked this question too, which is what round B1a
    added and what :func:`_simplify_path` documents.

    ROUND 019f9fb32de7 REPLACED FIXED-STEP SAMPLING WITH AN EXACT SWEEP. This
    function used to walk :attr:`PathSegment.points` (0.1mm steps) and ask
    ``can_route_through`` at each sample — a chord could graze a blocked
    cell's corner strictly between two samples and this function reported the
    segment clear anyway. It now asks :func:`_swept_cells` for EVERY cell the
    chord's true geometry crosses, however briefly, and checks each one
    through the grid's cell centre (the same "ask about the cell, not a
    sampled point" pattern the A* neighbour loop already uses for its own
    corner check at ``:444-450`` — this closes the sibling gap that check does
    not, the one the docstring there names but explicitly leaves open).

    WHY THE OWNER'S RATIFIED "GEOMETRIC DRC KERNEL AS ORACLE" (Option D) IS NOT
    HERE: ``RoutingGrid`` keeps no shapes — ``GridCell`` is
    ``occupied/net/layer/obstacle_type`` only, and every marker
    (``mark_pad``/``mark_obstacle``/``mark_trace``) rasterizes its source
    geometry into cells and discards it. Plumbing DRC shapes to this function
    would mean editing ``grid.py`` and ``route_bridge.py``, both out of fence
    for this round and both larger than it. This is the ratified fallback —
    conservative swept-cell traversal — not the literal ruling; see the
    round's report for the scoring that accepted the substitution.

    A CELL-RESOLUTION GUARANTEE, LIKE THE A* CHECK, NOT A SUB-CELL ONE. Both
    this function and the A* corner check ask ``can_route_through`` about
    whole cells; neither models the trace's real width inside a cell (that is
    what :attr:`RoutingGrid.keepout_margin` already inflates INTO the cells a
    marker occupies, so the cell grid itself is the width-aware
    representation this predicate is allowed to trust).
    """
    for col, row in _swept_cells(grid, start, end):
        cx, cy = grid._cell_to_pos(col, row)
        if not grid.can_route_through(cx, cy, net, layer):
            return False
    return True


def _simplify_path(
    points: list[tuple[float, float]],
    grid: RoutingGrid,
    net: str,
    layer: str,
    tolerance: float = 0.1,
) -> list[tuple[float, float]]:
    """Remove unnecessary waypoints from a path WITHOUT leaving its corridor.

    Perpendicular distance from the last KEPT point is a cheap prefilter for
    "this point looks droppable"; the grid is the authority on whether it may
    actually be dropped. A point is removed only when the straight run that
    would replace it is itself routable for this net.

    WHY THE GRID AND NOT JUST BETTER GEOMETRY (docket 019f9bd5f2f2, severity 1).
    This function used to be geometry-only, and measured each candidate against
    ``simplified[-1]`` rather than against the original polyline. On a detour the
    error accumulates monotonically along the curve: every point looks nearly
    collinear with the one chord that keeps growing, so a path that correctly
    hugged an obstacle was emitted as a single chord straight ACROSS it. A* was
    never wrong — it found a legal detour; simplification then made it illegal.
    Directly observed on tests/test_route_drc.py's crossing-wall fixture: 18
    consecutive probe points along the emitted segment were blocked by the grid
    and ``find_path`` returned that segment anyway, giving
    ``gc2_copper_clearance`` violations of -0.20 to -0.64mm.

    TWO FIXES WERE ON THE TABLE; THIS IS THE SECOND, AND THE FIRST IS NOT ENOUGH.
    (1) measure deviation against the ORIGINAL polyline — textbook
    Douglas-Peucker, the smaller change. Measured, not assumed: on the
    crossing-wall fixture it DOES come out clean (11 segments where this fix
    emits 3), so it would have passed the headline test. It is still rejected,
    because what it guarantees is a DEVIATION bound and what is needed is a
    CLEARANCE bound, and here the two are numerically indistinguishable —
    ``tolerance`` is 0.1mm and ``router.route_board``'s default
    ``grid_resolution`` is ALSO 0.1mm (router.py:692), so a chord is licensed to
    wander a full cell sideways off the path A* proved clear.
    The counterexample is a ONE-CELL JOG, which is exactly what A* emits when it
    steps around a single blocked cell: for the polyline (4.95, 0.05) ->
    (5.05, 0.05) -> (5.15, 0.15) -> (5.25, 0.05) -> (5.35, 0.05) around a cell
    blocked at (5.15, 0.05), the jog point's deviation from the chord evaluates to
    0.09999999999999999 — STRICTLY LESS than the 0.1 tolerance. Douglas-Peucker
    therefore drops it and emits a chord straight through the blocked cell under
    EITHER comparison, ``>`` or ``>=``. This is deliberately not described as a
    knife-edge tie: a reader who thought the failure hung on a ``>`` / ``>=``
    choice could dismiss it as a tuning question, and it is not one — no tolerance
    at or above one cell can be made safe by tightening the comparison, because
    the chord is a full cell away from the path A* proved. Verified against a real
    ``RoutingGrid``; it is regression-locked by
    ``test_simplification_keeps_a_one_cell_jog_douglas_peucker_would_drop`` in
    tests/agent_router/test_pathfinder.py, so this paragraph cannot rot into a
    claim nothing checks.
    (2) re-verify the chord against the grid. It enforces the property that
    actually matters instead of a proxy for it, and it CANNOT be wrong: the
    unsimplified polyline is always available as the fallback, so the worst case
    is a route with more vertices, never one through copper.

    COST, MEASURED: this is O(N^2) in the number of A* points. Each drop re-probes
    the whole grown chord, and the chord is a different line each time, so there
    is nothing to reuse from the previous probe. Timed on a straight run — the
    worst case, since every point is droppable and the chord grows to full length:
    N = 200 / 500 / 1000 / 2000 -> 0.007 / 0.044 / 0.182 / 0.737s (clean 4x per
    doubling, i.e. quadratic as stated; absolute numbers are machine-dependent,
    the SHAPE is the claim). Bounded and
    monotone (the loop is a single forward pass; the inner probe is finite), so it
    cannot hang, but it IS on the routing hot path and a board that produced tens
    of thousands of A* points would feel it. Left quadratic deliberately rather
    than optimised speculatively: the same incremental anchoring that costs the
    time is what makes each emitted segment individually verified.

    THE SIMPLIFIER CAN SEE THE GRID — no new dependency crosses any boundary.
    ``_reconstruct_path`` already holds ``grid``/``net``/``layer`` (it hands all
    three to :func:`_collapse_staircases` on the orthogonal branch), so option 2
    costs three arguments that were already in scope. Had the grid NOT been
    reachable this would have been reported rather than plumbed.

    TRAP for anyone tuning this loop: the chord that must be verified is
    ``simplified[-1] -> points[i + 1]``, i.e. the run as it would be AFTER this
    drop, not ``prev -> curr``. Every emitted segment is the chord checked at the
    last drop before its far endpoint was kept, so each one is verified exactly
    once. Checking the pre-drop run instead would verify a segment that is never
    emitted and re-open this bug in a form that still passes a naive test.
    """
    if len(points) <= 2:
        return points

    simplified = [points[0]]

    for i in range(1, len(points) - 1):
        prev = simplified[-1]
        curr = points[i]
        next_pt = points[i + 1]

        # Vector from prev to next
        v2 = (next_pt[0] - prev[0], next_pt[1] - prev[1])
        seg_len = math.sqrt(v2[0] * v2[0] + v2[1] * v2[1])

        if seg_len < 1e-9:
            # prev and next are the same point – keep curr
            simplified.append(curr)
            continue

        # Vector from prev to curr
        v1 = (curr[0] - prev[0], curr[1] - prev[1])

        # Perpendicular distance = |cross product| / segment length
        cross = abs(v1[0] * v2[1] - v1[1] * v2[0])
        perp_dist = cross / seg_len

        # If not collinear, keep the point
        if perp_dist > tolerance:
            simplified.append(curr)
            continue

        # Looks droppable. It only IS droppable if what replaces it stays inside
        # the corridor the unsimplified path occupied.
        if not _segment_clear(grid, prev, next_pt, net, layer):
            simplified.append(curr)

    simplified.append(points[-1])
    return simplified


def _simplify_orthogonal(
    points: list[tuple[float, float]],
    grid: RoutingGrid,
    net: str,
    layer: str,
) -> list[tuple[float, float]]:
    """Simplify a path while preserving orthogonal (H/V) segments.

    Merges consecutive segments that share the same cardinal direction
    (both horizontal or both vertical). Uses direction comparison instead
    of distance tolerance to avoid collapsing staircase steps into diagonals.

    The ``_segment_clear`` call is a DEFENSIVE GUARD, NOT A BUG FIX, and it is
    UNEXERCISED BY THE ENGINE TODAY. Saying so plainly because an earlier draft of
    this docstring claimed it closed a real terminal-step defect, and that claim
    was false — cold review flagged it, and working it through proves the merge is
    exact under the invariant this function is actually called with:

    * ``_reconstruct_path`` is the only caller, and it reaches here only when
      ``prefer_orthogonal`` made A* CARDINAL, so consecutive interior points are
      cell CENTRES differing on exactly one axis. Merging two same-direction steps
      between them sweeps precisely the cells the two steps swept.
    * the two ends are the case that looked dangerous, because the exact start and
      end replace the first and last cell centres and ``_direction`` classifies by
      ``abs(dx) > abs(dy)``. It is not: the start lies INSIDE its own cell, so
      ``|dx|`` to that cell's centre is at most ``resolution / 2``, while a
      vertical move to the adjacent row's centre gives ``|dy|`` of at least
      ``resolution / 2``. ``|dx| > |dy|`` — the "H" test — therefore cannot select
      a move that changed row, and vice versa. Classification is exact.
    * given that, every point merged by an H run shares one row, and the exact
      start/end lie inside that same row's span, so every y on the chord is a
      convex combination of values within one row: the chord cannot leave it.
      Symmetrically for V.

    So the guard is kept for the INVARIANT, not for a known defect: it is what
    catches a future change that feeds this function non-cell-centre points or
    lets a diagonal move through under ``prefer_orthogonal``, either of which
    silently breaks the convexity argument above. Deleting it leaves the whole
    suite green, which is expected rather than a coverage gap — the honest test
    for a guard is that it fires when its premise is violated, and that is
    ``test_the_orthogonal_guard_fires_when_the_cell_centre_invariant_is_broken``
    in tests/agent_router/test_pathfinder.py.
    """
    if len(points) <= 2:
        return points

    def _direction(a: tuple[float, float], b: tuple[float, float]) -> str:
        dx = b[0] - a[0]
        dy = b[1] - a[1]
        if abs(dx) > abs(dy):
            return "H"
        elif abs(dy) > abs(dx):
            return "V"
        return "D"  # Diagonal or zero-length

    simplified = [points[0]]

    for i in range(1, len(points) - 1):
        prev = simplified[-1]
        curr = points[i]
        next_pt = points[i + 1]

        dir_in = _direction(prev, curr)
        dir_out = _direction(curr, next_pt)

        # Merge only if both segments go the same cardinal direction AND the
        # merged run is routable (see the docstring: exact for interior steps,
        # load-bearing at the two terminals).
        if (dir_in == dir_out and dir_in in ("H", "V")
                and _segment_clear(grid, prev, next_pt, net, layer)):
            continue  # Skip curr — extend prev→next directly
        simplified.append(curr)

    simplified.append(points[-1])
    return simplified


def _collapse_staircases(
    points: list[tuple[float, float]],
    grid: RoutingGrid,
    net: str,
    layer: str,
) -> list[tuple[float, float]]:
    """Collapse staircase H/V alternations into L-shaped bends.

    A staircase is a sequence of alternating H/V segments all trending in
    the same quadrant (e.g., all H go right, all V go down).  This replaces
    such runs with single L-bends (2 segments) when the L-path is clear,
    or recursively bisects the run when obstacles block the full L-path.
    """
    if len(points) <= 3:
        return points

    result = [points[0]]
    i = 0

    while i < len(points) - 1:
        run_end = _find_staircase_end(points, i)

        if run_end - i >= 3:  # 4+ points → meaningful staircase
            collapsed = _collapse_run(points, i, run_end, grid, net, layer)
            result.extend(collapsed[1:])  # skip first (already in result)
            i = run_end
        else:
            i += 1
            result.append(points[i])

    return result


def _find_staircase_end(
    points: list[tuple[float, float]], start: int
) -> int:
    """Return the index of the last point in a staircase run starting at *start*."""
    if start + 2 >= len(points):
        return start + 1

    def _seg_info(a: tuple[float, float], b: tuple[float, float]) -> tuple[str, int]:
        dx = b[0] - a[0]
        dy = b[1] - a[1]
        if abs(dx) > abs(dy):
            return "H", (1 if dx > 0 else -1)
        if abs(dy) > abs(dx):
            return "V", (1 if dy > 0 else -1)
        return "D", 0

    ax1, sg1 = _seg_info(points[start], points[start + 1])
    ax2, sg2 = _seg_info(points[start + 1], points[start + 2])

    if ax1 == ax2 or "D" in (ax1, ax2):
        return start + 1  # not a staircase

    j = start + 2
    while j < len(points) - 1:
        ax, sg = _seg_info(points[j], points[j + 1])
        exp_ax = ax1 if (j - start) % 2 == 0 else ax2
        exp_sg = sg1 if exp_ax == ax1 else sg2
        if ax != exp_ax or sg != exp_sg:
            break
        j += 1

    return j


def _collapse_run(
    points: list[tuple[float, float]],
    start: int,
    end: int,
    grid: RoutingGrid,
    net: str,
    layer: str,
) -> list[tuple[float, float]]:
    """Collapse a staircase run [start..end] into L-bends.

    Returns a list from points[start] to points[end] inclusive.
    Uses recursive bisection when a single L-bend is blocked.

    THE AXIS-ALIGNED BRANCH IS A GUARD ON AN INVARIANT, not a fix for a live
    defect — said plainly, because this module has been burned by comments that
    claimed more than the code did. The two corners below are built from the run
    endpoints exactly as :func:`_try_l_path`'s are, so if a run ever arrived with
    ``s`` and ``e`` sharing a row or a column, one leg of the returned L would be
    ZERO-LENGTH and the batch-poisoning of 019f9cc3245d would be back through a
    second door. It cannot arrive that way today: :func:`_find_staircase_end`
    only extends a run while segments alternate H/V with consistent signs, so a
    run's endpoints differ on BOTH axes. Nothing pinned that, and "unreachable
    today" is exactly how :func:`_try_l_path` looked before ``prefer_orthogonal``
    became the default for hinted runs. The honest test for a guard is that it
    fires when its premise is violated, and that is
    ``test_collapse_run_refuses_to_emit_a_degenerate_leg_if_its_premise_breaks``
    in tests/agent_router/test_pathfinder.py.
    """
    s = points[start]
    e = points[end]

    if end - start < 3:
        return list(points[start : end + 1])

    if s == e:
        # Nothing to draw between a point and itself. One point, so the caller's
        # `result.extend(collapsed[1:])` contributes nothing rather than a
        # zero-length segment.
        return [s]

    if s[0] == e[0] or s[1] == e[1]:
        # Both "corners" ARE the endpoints here; the only geometry available is
        # the straight run. Same reasoning, and the same acceptance test, as
        # _try_l_path's branch. If the run is blocked, fall through to bisection
        # exactly as a blocked L does.
        if _segment_clear(grid, s, e, net, layer):
            return [s, e]
    else:
        # Try full L-path (both corner orderings)
        for corner in [(e[0], s[1]), (s[0], e[1])]:
            if _l_segments_clear(grid, s, corner, e, net, layer):
                return [s, corner, e]

    # Blocked — split at midpoint and recurse
    mid = (start + end) // 2
    left = _collapse_run(points, start, mid, grid, net, layer)
    right = _collapse_run(points, mid, end, grid, net, layer)
    return left + right[1:]  # avoid duplicate midpoint


def _l_segments_clear(
    grid: RoutingGrid,
    start: tuple[float, float],
    corner: tuple[float, float],
    end: tuple[float, float],
    net: str,
    layer: str,
) -> bool:
    """Return True if both legs of an L-path are routable."""
    return all(_segment_clear(grid, seg_start, seg_end, net, layer)
               for seg_start, seg_end in [(start, corner), (corner, end)])


def _try_via_path(
    grid: RoutingGrid,
    start: tuple[float, float],
    end: tuple[float, float],
    net: str,
    start_layer: str,
    other_layer: str,
    prefer_orthogonal: bool = False,
) -> Optional[Path]:
    """Try to find a path using a via to change layers.

    Strategies tried (via at start then via at end):
    1. Direct path on alt layer (skipped when prefer_orthogonal)
    2. L-shaped path on alt layer — a STRAIGHT run when the endpoints are
       axis-aligned, which is why this strategy no longer emits a degenerate leg
       under prefer_orthogonal either (see :func:`_try_l_path`)
    3. A* path on alt layer
    """
    for via_pos, route_start, route_end in [
        (start, start, end),   # via at start
        (end, start, end),     # via at end
    ]:
        # 1. Direct path on alt layer (skip when prefer_orthogonal)
        if not prefer_orthogonal:
            path = _try_direct_path(grid, route_start, route_end, net, other_layer)
            if path:
                path.vias = [via_pos]
                return path

        # 2. L-shaped path on alt layer
        path = _try_l_path(grid, route_start, route_end, net, other_layer)
        if path:
            path.vias = [via_pos]
            return path

        # 3. A* path on alt layer
        path = _astar_path(grid, route_start, route_end, net, other_layer,
                           prefer_orthogonal=prefer_orthogonal)
        if path:
            path.vias = [via_pos]
            return path

    return None
