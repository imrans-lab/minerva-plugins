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

    # Try with via if allowed
    if allow_via:
        other_layer = "B.Cu" if layer == "F.Cu" else "F.Cu"
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
    if prefer_orthogonal:
        simplified = _simplify_orthogonal(points, grid, net, layer)
        simplified = _collapse_staircases(simplified, grid, net, layer)
    else:
        simplified = _simplify_path(points, grid, net, layer)

    # Create segments
    segments = []
    for i in range(len(simplified) - 1):
        segments.append(PathSegment(
            start=simplified[i],
            end=simplified[i + 1],
            layer=layer
        ))

    return Path(segments=segments, net=net)


def _segment_clear(
    grid: RoutingGrid,
    start: tuple[float, float],
    end: tuple[float, float],
    net: str,
    layer: str,
) -> bool:
    """Return True if a straight run from *start* to *end* is routable for *net*.

    THE single owner of "may this net occupy this chord", sampled at
    :attr:`PathSegment.points` resolution (0.1mm) — the same test
    :func:`_try_direct_path` applies to a one-segment path and
    :func:`_l_segments_clear` applies to each leg of an L. Every chord
    SIMPLIFICATION invents is asked this question too, which is what round B1a
    added and what :func:`_simplify_path` documents.

    WHAT "verified" MEANS HERE, stated precisely because two earlier drafts of
    this paragraph got it wrong in opposite directions. As of round C2d
    (019f9d594f83), A*'s neighbour loop rejects a diagonal step whenever either
    of the two cells orthogonally adjacent to the step (the corner the chord
    would cut) fails ``can_route_through`` — so every ORIGINAL A* STEP has now
    been checked across the full 2x2 cell block that step crosses, not just its
    destination cell. SIMPLIFICATION-INVENTED CHORDS ARE NOT COVERED BY THAT
    CHECK: the corner test lives in the neighbour loop, so a chord created by
    :func:`_simplify_path` is verified only by this function's sampling, which
    is the weaker guarantee described immediately below.

    THAT IS A CELL-RESOLUTION GUARANTEE, NOT WHAT THIS FUNCTION TESTS. This
    function still only point-samples the chord at 0.1mm (see
    :attr:`PathSegment.points`), which is coarser than "prove every cell the
    chord's true geometry crosses is routable" — a chord can graze a blocked
    cell's corner between two 0.1mm samples and this function will still return
    True for it. That gap is real, independent of the A* fix above (it exists
    for any chord, not just original diagonal steps), and is tracked separately
    as ``019f9fb32de7``; it is OUT OF SCOPE for this function to close. So: A*
    steps are now cell-verified at the point they are generated, and this
    predicate remains corner-permissive at the resolution it samples.
    """
    seg = PathSegment(start=start, end=end, layer=layer)
    for pt in seg.points:
        if not grid.can_route_through(pt[0], pt[1], net, layer):
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
