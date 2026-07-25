"""
Routing grid with collision detection.

Provides a discrete grid representation of the board for pathfinding,
tracking occupied cells, nets, and clearance zones.
"""

from dataclasses import dataclass, field
from typing import Optional
import math


@dataclass
class GridCell:
    """Represents a single cell in the routing grid."""
    occupied: bool = False
    net: Optional[str] = None       # Which net owns this cell
    layer: Optional[str] = None     # "F.Cu" or "B.Cu"
    obstacle_type: Optional[str] = None  # "pad", "via", "trace", "hole", "keepout"


@dataclass
class RoutingGrid:
    """
    Discrete grid for routing and collision detection.

    Each cell tracks occupancy, owning net, and layer information.
    Supports marking pads, obstacles, and traces with proper clearance.
    """
    width: float           # Board width in mm
    height: float          # Board height in mm
    resolution: float      # Grid resolution in mm (cell size)
    clearance: float = 0.2  # Minimum clearance between different nets in mm
    layers: list[str] = field(default_factory=lambda: ["F.Cu", "B.Cu"])
    # Board ORIGIN in world mm: the world position of cell (0, 0)'s lower-left
    # corner. A board outline that does not start at (0, 0) — RectOutline.origin
    # in the ResolvedBoard IR — used to be ignored here, so world coordinates were
    # indexed as if the board began at the world origin and every pad landed in
    # the wrong cell (docket 019f783860c8, gap C). Callers keep speaking WORLD
    # coordinates at every boundary; the grid subtracts the origin internally.
    origin: tuple[float, float] = (0.0, 0.0)

    def __post_init__(self):
        """Initialize the grid cells."""
        self.cols = int(math.ceil(self.width / self.resolution))
        self.rows = int(math.ceil(self.height / self.resolution))
        # Create grid for each layer
        self._grid: dict[str, list[list[GridCell]]] = {}
        for layer in self.layers:
            self._grid[layer] = [
                [GridCell() for _ in range(self.cols)]
                for _ in range(self.rows)
            ]

    # -- world <-> cell -----------------------------------------------------
    # THE single owner of the transform, in both directions. Every marker, the
    # bounds test and the pathfinder go through these two methods; nothing
    # re-derives `x / resolution` on its own, so the origin cannot be honoured in
    # one place and forgotten in another.

    def _pos_to_cell(self, x: float, y: float) -> tuple[int, int]:
        """Convert a WORLD position in mm to grid cell indices.

        Uses floor, not truncation: for a position left of / above the origin,
        ``int()`` rounds toward zero and would fold two different out-of-bounds
        positions onto cell -0, which ``_cell_in_bounds`` then reads as index 0 —
        an out-of-board point testing as an in-board cell.
        """
        col = math.floor((x - self.origin[0]) / self.resolution)
        row = math.floor((y - self.origin[1]) / self.resolution)
        return (col, row)

    def _cell_to_pos(self, col: int, row: int) -> tuple[float, float]:
        """Convert grid cell indices to the WORLD position of the cell's centre.

        The inverse of :meth:`_pos_to_cell`. Path reconstruction returns world
        coordinates through here, so a routed proposal lands where the board says
        rather than offset by the origin.
        """
        return (self.origin[0] + (col + 0.5) * self.resolution,
                self.origin[1] + (row + 0.5) * self.resolution)

    def _cell_range(self, lo: float, hi: float, axis: int) -> range:
        """Inclusive cell index range covering the world span [lo, hi] on *axis*
        (0 = x/cols, 1 = y/rows). Shared by every rectangular marker so the
        origin is applied once."""
        base = self.origin[axis]
        first = math.floor((lo - base) / self.resolution)
        last = math.ceil((hi - base) / self.resolution)
        return range(first, last + 1)

    def _cell_in_bounds(self, col: int, row: int) -> bool:
        """Check if cell indices are within grid bounds."""
        return 0 <= col < self.cols and 0 <= row < self.rows

    def get_cell(self, x: float, y: float, layer: str = "F.Cu") -> GridCell:
        """
        Get the grid cell at position (x, y).

        Args:
            x: X position in mm
            y: Y position in mm
            layer: Layer name

        Returns:
            GridCell at the position
        """
        col, row = self._pos_to_cell(x, y)
        if not self._cell_in_bounds(col, row):
            # Return blocked cell for out-of-bounds
            cell = GridCell(occupied=True, obstacle_type="boundary")
            return cell
        return self._grid[layer][row][col]

    def is_blocked(self, x: float, y: float, layer: str = "F.Cu") -> bool:
        """
        Check if position is blocked (occupied by obstacle or out of bounds).

        Args:
            x: X position in mm
            y: Y position in mm
            layer: Layer name

        Returns:
            True if blocked, False otherwise
        """
        cell = self.get_cell(x, y, layer)
        return cell.occupied and cell.net is None

    def can_route_through(self, x: float, y: float, net: str, layer: str = "F.Cu") -> bool:
        """
        Check if a net can route through this position.

        Allows routing through own pads/traces but not through other nets.

        Args:
            x: X position in mm
            y: Y position in mm
            net: Net name attempting to route
            layer: Layer name

        Returns:
            True if routing is allowed, False otherwise
        """
        cell = self.get_cell(x, y, layer)
        if not cell.occupied:
            return True
        # Can route through own net
        return cell.net == net

    def mark_pad(
        self,
        x: float,
        y: float,
        size: tuple[float, float],
        net: Optional[str],
        layer: str = "F.Cu",
        rotation: float = 0.0
    ) -> None:
        """
        Mark a pad's area as occupied in the grid.

        Args:
            x: Pad center X position in mm
            y: Pad center Y position in mm
            size: Pad size (width, height) in mm
            net: Net name or None
            layer: Layer name
            rotation: Pad rotation in degrees
        """
        # Simple rectangular marking (ignoring rotation for now)
        half_w = size[0] / 2
        half_h = size[1] / 2

        # Mark cells covered by pad (world span -> cells via the shared owner, so
        # the board origin is honoured here exactly as in _pos_to_cell).
        for row in self._cell_range(y - half_h, y + half_h, 1):
            for col in self._cell_range(x - half_w, x + half_w, 0):
                if self._cell_in_bounds(col, row):
                    cell = self._grid[layer][row][col]
                    cell.occupied = True
                    cell.net = net
                    cell.obstacle_type = "pad"

    def mark_obstacle(
        self,
        x: float,
        y: float,
        radius: float,
        layer: Optional[str] = None
    ) -> None:
        """
        Mark a circular obstacle (like a mounting hole).

        Args:
            x: Center X position in mm
            y: Center Y position in mm
            radius: Obstacle radius in mm
            layer: Layer to mark, or None for all layers
        """
        # Include clearance in blocking radius
        block_radius = radius + self.clearance

        layers_to_mark = [layer] if layer else self.layers

        for cell_y in self._range_mm(y - block_radius, y + block_radius):
            for cell_x in self._range_mm(x - block_radius, x + block_radius):
                # Check if within radius
                dist = math.sqrt((cell_x - x) ** 2 + (cell_y - y) ** 2)
                if dist <= block_radius:
                    col, row = self._pos_to_cell(cell_x, cell_y)
                    if self._cell_in_bounds(col, row):
                        for lyr in layers_to_mark:
                            cell = self._grid[lyr][row][col]
                            cell.occupied = True
                            cell.obstacle_type = "hole"

    def mark_trace(
        self,
        start: tuple[float, float],
        end: tuple[float, float],
        width: float,
        net: str,
        layer: str = "F.Cu"
    ) -> None:
        """
        Mark a trace segment's area as occupied.

        Args:
            start: Start position (x, y) in mm
            end: End position (x, y) in mm
            width: Trace width in mm
            net: Net name
            layer: Layer name
        """
        # Calculate cells along the trace
        dx = end[0] - start[0]
        dy = end[1] - start[1]
        length = math.sqrt(dx * dx + dy * dy)

        if length < self.resolution:
            # Very short trace, just mark start point
            self._mark_trace_point(start[0], start[1], width, net, layer)
            return

        # Step along the trace
        steps = int(math.ceil(length / self.resolution))
        for i in range(steps + 1):
            t = i / steps
            x = start[0] + t * dx
            y = start[1] + t * dy
            self._mark_trace_point(x, y, width, net, layer)

    def _mark_trace_point(
        self,
        x: float,
        y: float,
        width: float,
        net: str,
        layer: str
    ) -> None:
        """Mark a single point of a trace with given width."""
        half_w = width / 2

        for row in self._cell_range(y - half_w, y + half_w, 1):
            for col in self._cell_range(x - half_w, x + half_w, 0):
                if self._cell_in_bounds(col, row):
                    cell = self._grid[layer][row][col]
                    cell.occupied = True
                    cell.net = net
                    cell.obstacle_type = "trace"
                    cell.layer = layer

    def _range_mm(self, start: float, end: float):
        """Generate positions from start to end at grid resolution."""
        pos = start
        while pos <= end:
            yield pos
            pos += self.resolution
