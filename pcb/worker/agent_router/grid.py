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

    def _pos_to_cell(self, x: float, y: float) -> tuple[int, int]:
        """Convert position in mm to grid cell indices."""
        col = int(x / self.resolution)
        row = int(y / self.resolution)
        return (col, row)

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

        # Mark cells covered by pad
        x_min = x - half_w
        x_max = x + half_w
        y_min = y - half_h
        y_max = y + half_h

        # Convert to cell indices
        col_min = int(x_min / self.resolution)
        col_max = int(math.ceil(x_max / self.resolution))
        row_min = int(y_min / self.resolution)
        row_max = int(math.ceil(y_max / self.resolution))

        for row in range(row_min, row_max + 1):
            for col in range(col_min, col_max + 1):
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

        # Calculate the range of grid cells to mark
        x_min = x - half_w
        x_max = x + half_w
        y_min = y - half_w
        y_max = y + half_w

        # Convert to cell indices
        col_min = int(x_min / self.resolution)
        col_max = int(math.ceil(x_max / self.resolution))
        row_min = int(y_min / self.resolution)
        row_max = int(math.ceil(y_max / self.resolution))

        for row in range(row_min, row_max + 1):
            for col in range(col_min, col_max + 1):
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
