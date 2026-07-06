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
    1. Direct path (skipped when prefer_orthogonal=True)
    2. L-shaped path (one bend)
    3. A* path (multiple bends)
    4. Via + alternate layer (if allow_via=True)

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
    # Try direct path first (skip when prefer_orthogonal — direct paths are diagonal)
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


def _try_direct_path(
    grid: RoutingGrid,
    start: tuple[float, float],
    end: tuple[float, float],
    net: str,
    layer: str
) -> Optional[Path]:
    """Try a direct straight-line path."""
    segment = PathSegment(start=start, end=end, layer=layer)

    # Check all points along the path
    for point in segment.points:
        if not grid.can_route_through(point[0], point[1], net, layer):
            return None

    return Path(segments=[segment], net=net)


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
    """
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
    seg1 = PathSegment(start=start, end=corner, layer=layer)
    seg2 = PathSegment(start=corner, end=end, layer=layer)

    for point in seg1.points:
        if not grid.can_route_through(point[0], point[1], net, layer):
            return None

    for point in seg2.points:
        if not grid.can_route_through(point[0], point[1], net, layer):
            return None

    return Path(segments=[seg1, seg2], net=net)


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
            nx = neighbor[0] * grid.resolution + grid.resolution / 2
            ny = neighbor[1] * grid.resolution + grid.resolution / 2

            if not grid.can_route_through(nx, ny, net, layer):
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
        x = cell[0] * grid.resolution + grid.resolution / 2
        y = cell[1] * grid.resolution + grid.resolution / 2
        points.append((x, y))
    points.append(end)  # Use exact end

    # Simplify: merge collinear points
    if prefer_orthogonal:
        simplified = _simplify_orthogonal(points)
        simplified = _collapse_staircases(simplified, grid, net, layer)
    else:
        simplified = _simplify_path(points)

    # Create segments
    segments = []
    for i in range(len(simplified) - 1):
        segments.append(PathSegment(
            start=simplified[i],
            end=simplified[i + 1],
            layer=layer
        ))

    return Path(segments=segments, net=net)


def _simplify_path(points: list[tuple[float, float]], tolerance: float = 0.1) -> list[tuple[float, float]]:
    """Remove unnecessary waypoints from a path.

    Uses perpendicular distance from each point to the line between its
    neighbors. Points closer than ``tolerance`` mm are removed.
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

    simplified.append(points[-1])
    return simplified


def _simplify_orthogonal(points: list[tuple[float, float]]) -> list[tuple[float, float]]:
    """Simplify a path while preserving orthogonal (H/V) segments.

    Merges consecutive segments that share the same cardinal direction
    (both horizontal or both vertical). Uses direction comparison instead
    of distance tolerance to avoid collapsing staircase steps into diagonals.
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

        # Merge only if both segments go the same cardinal direction
        if dir_in == dir_out and dir_in in ("H", "V"):
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
    """
    s = points[start]
    e = points[end]

    if end - start < 3:
        return list(points[start : end + 1])

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
    for seg_start, seg_end in [(start, corner), (corner, end)]:
        seg = PathSegment(start=seg_start, end=seg_end, layer=layer)
        for pt in seg.points:
            if not grid.can_route_through(pt[0], pt[1], net, layer):
                return False
    return True


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
    2. L-shaped path on alt layer
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
