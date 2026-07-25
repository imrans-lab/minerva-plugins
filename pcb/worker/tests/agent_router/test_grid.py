"""
Tests for RoutingGrid.
"""

import pytest
from agent_router.grid import RoutingGrid, GridCell


class TestGridCreation:
    """Tests for grid initialization."""

    def test_empty_grid_creation(self):
        """Create empty routing grid with specified resolution."""
        grid = RoutingGrid(width=50, height=50, resolution=0.1)
        assert grid.cols == 500
        assert grid.rows == 500

    def test_grid_layers(self):
        """Grid creates layers correctly."""
        grid = RoutingGrid(width=10, height=10, resolution=1.0)
        assert "F.Cu" in grid._grid
        assert "B.Cu" in grid._grid

    def test_single_layer_grid(self):
        """Grid can be single layer."""
        grid = RoutingGrid(width=10, height=10, resolution=1.0, layers=["F.Cu"])
        assert "F.Cu" in grid._grid
        assert "B.Cu" not in grid._grid


class TestPadMarking:
    """Tests for marking pads on the grid."""

    def test_mark_pad_occupied(self):
        """Pads occupy grid cells with their net."""
        grid = RoutingGrid(width=50, height=50, resolution=0.1)
        grid.mark_pad(x=25, y=25, size=(1.0, 0.5), net="VCC")

        # Center of pad should be occupied by VCC
        cell = grid.get_cell(25, 25)
        assert cell.net == "VCC"
        assert cell.occupied == True

        # Outside pad should be free
        cell_outside = grid.get_cell(20, 20)
        assert cell_outside.occupied == False

    def test_pad_occupies_area(self):
        """Pad marks all cells within its size."""
        grid = RoutingGrid(width=50, height=50, resolution=0.1)
        grid.mark_pad(x=25, y=25, size=(2.0, 2.0), net="VCC")

        # All corners of 2x2 pad should be occupied
        assert grid.get_cell(24.5, 24.5).occupied == True
        assert grid.get_cell(25.5, 25.5).occupied == True
        assert grid.get_cell(24.5, 25.5).occupied == True
        assert grid.get_cell(25.5, 24.5).occupied == True


class TestObstacleMarking:
    """Tests for marking obstacles on the grid."""

    def test_clearance_around_obstacles(self):
        """Obstacles have clearance buffer."""
        grid = RoutingGrid(width=50, height=50, resolution=0.1, clearance=0.2)
        grid.mark_obstacle(x=25, y=25, radius=1.5)

        # Inside obstacle radius + clearance = blocked
        assert grid.is_blocked(25, 26.5) == True
        # Outside clearance = free
        assert grid.is_blocked(25, 28) == False

    def test_obstacle_blocks_all_layers(self):
        """Obstacle blocks both layers by default."""
        grid = RoutingGrid(width=50, height=50, resolution=0.1)
        grid.mark_obstacle(x=25, y=25, radius=2.0)

        assert grid.get_cell(25, 25, "F.Cu").occupied == True
        assert grid.get_cell(25, 25, "B.Cu").occupied == True

    def test_obstacle_single_layer(self):
        """Obstacle can block single layer."""
        grid = RoutingGrid(width=50, height=50, resolution=0.1)
        grid.mark_obstacle(x=25, y=25, radius=2.0, layer="F.Cu")

        assert grid.get_cell(25, 25, "F.Cu").occupied == True
        assert grid.get_cell(25, 25, "B.Cu").occupied == False


class TestRouteChecking:
    """Tests for routing checks."""

    def test_same_net_can_overlap(self):
        """Traces can touch pads/traces of same net."""
        grid = RoutingGrid(width=50, height=50, resolution=0.1)
        grid.mark_pad(x=25, y=25, size=(1.0, 1.0), net="VCC")

        # Can route through own pad
        assert grid.can_route_through(25, 25, net="VCC") == True
        # Cannot route different net through pad
        assert grid.can_route_through(25, 25, net="GND") == False

    def test_is_blocked_for_obstacles(self):
        """is_blocked returns True for obstacles (no net)."""
        grid = RoutingGrid(width=50, height=50, resolution=0.1)
        grid.mark_obstacle(x=25, y=25, radius=2.0)

        assert grid.is_blocked(25, 25) == True

    def test_is_blocked_for_pads(self):
        """is_blocked returns False for pads (they have a net)."""
        grid = RoutingGrid(width=50, height=50, resolution=0.1)
        grid.mark_pad(x=25, y=25, size=(1.0, 1.0), net="VCC")

        # Pads are not "blocked" - they belong to a net
        assert grid.is_blocked(25, 25) == False


class TestTraceMarking:
    """Tests for marking traces on the grid."""

    def test_trace_occupies_width(self):
        """Marking a trace occupies cells based on trace width."""
        grid = RoutingGrid(width=50, height=50, resolution=0.1)
        grid.mark_trace(start=(10, 25), end=(40, 25), width=0.3, net="SIG1", layer="F.Cu")

        # Center of trace = occupied
        cell = grid.get_cell(25, 25)
        assert cell.net == "SIG1"
        # Edge of trace (within width/2) = occupied
        assert grid.get_cell(25, 25.1).occupied == True
        # Outside trace width = free
        assert grid.get_cell(25, 26).occupied == False

    def test_trace_layer(self):
        """Trace only marks specified layer."""
        grid = RoutingGrid(width=50, height=50, resolution=0.1)
        grid.mark_trace(start=(10, 25), end=(40, 25), width=0.3, net="SIG1", layer="F.Cu")

        assert grid.get_cell(25, 25, "F.Cu").occupied == True
        assert grid.get_cell(25, 25, "B.Cu").occupied == False

    def test_diagonal_trace(self):
        """Diagonal traces are marked correctly."""
        grid = RoutingGrid(width=50, height=50, resolution=0.5)
        grid.mark_trace(start=(10, 10), end=(20, 20), width=0.5, net="SIG1", layer="F.Cu")

        # Check midpoint
        assert grid.get_cell(15, 15, "F.Cu").occupied == True


class TestBoundaryConditions:
    """Tests for boundary conditions."""

    def test_out_of_bounds_returns_blocked(self):
        """Positions outside grid return blocked cell."""
        grid = RoutingGrid(width=50, height=50, resolution=0.1)

        cell = grid.get_cell(100, 100)
        assert cell.occupied == True
        assert cell.obstacle_type == "boundary"

    def test_negative_position_returns_blocked(self):
        """Negative positions return blocked cell."""
        grid = RoutingGrid(width=50, height=50, resolution=0.1)

        cell = grid.get_cell(-10, -10)
        assert cell.occupied == True

    def test_cell_at_edge(self):
        """Cells at board edge are accessible."""
        grid = RoutingGrid(width=50, height=50, resolution=0.1)

        cell = grid.get_cell(0, 0)
        assert cell.occupied == False

        cell = grid.get_cell(49.9, 49.9)
        assert cell.occupied == False


class TestGridOrigin:
    """A board whose outline does not start at (0, 0) — docket 019f783860c8 gap C.

    The grid used to index world coordinates as if every board began at the world
    origin, so on an offset board every pad landed in the wrong cell. The grid now
    carries the board origin and is the SINGLE owner of the world<->cell transform
    in both directions; callers keep speaking world coordinates everywhere.
    """

    def test_origin_defaults_to_zero_and_is_backward_compatible(self):
        grid = RoutingGrid(width=10, height=10, resolution=1.0)
        assert grid.origin == (0.0, 0.0)
        assert grid._pos_to_cell(0.5, 0.5) == (0, 0)
        assert grid._pos_to_cell(9.5, 9.5) == (9, 9)

    def test_world_to_cell_subtracts_the_origin(self):
        grid = RoutingGrid(width=40, height=40, resolution=0.1, origin=(100.0, 100.0))
        assert grid._pos_to_cell(100.0, 100.0) == (0, 0)
        assert grid._pos_to_cell(120.0, 110.0) == (200, 100)
        # The far corner is the last cell, not out of bounds.
        assert grid._cell_in_bounds(*grid._pos_to_cell(139.99, 139.99))

    def test_cell_to_world_is_the_inverse_and_round_trips(self):
        grid = RoutingGrid(width=40, height=40, resolution=0.5, origin=(100.0, 100.0))
        for col, row in ((0, 0), (3, 7), (79, 79)):
            x, y = grid._cell_to_pos(col, row)
            assert grid._pos_to_cell(x, y) == (col, row)
        # Centre of cell (0,0) on this grid is half a cell in from the origin.
        assert grid._cell_to_pos(0, 0) == pytest.approx((100.25, 100.25))

    def test_a_point_before_the_origin_is_out_of_bounds(self):
        """Floor, not truncation. int() rounds toward zero, so a point just LEFT
        of the origin would become cell -0 == 0 and test as in-bounds — an
        off-board position reading as the board's first cell."""
        grid = RoutingGrid(width=40, height=40, resolution=1.0, origin=(100.0, 100.0))
        assert grid._pos_to_cell(99.5, 100.5) == (-1, 0)
        assert not grid._cell_in_bounds(*grid._pos_to_cell(99.5, 100.5))
        assert not grid._cell_in_bounds(*grid._pos_to_cell(100.5, 99.5))
        # Out-of-bounds reads are blocked, so nothing routes off-board.
        assert grid.is_blocked(99.5, 100.5)

    def test_markers_honour_the_origin(self):
        """Every rectangular marker goes through the same span helper, so a pad
        marked in world coordinates occupies the cells under it — not cells offset
        by the origin (which, before, was most of the board away)."""
        grid = RoutingGrid(width=40, height=40, resolution=0.5, origin=(100.0, 100.0))
        grid.mark_pad(x=120.0, y=120.0, size=(1.0, 1.0), net="N1", layer="F.Cu")

        assert grid.get_cell(120.0, 120.0, "F.Cu").occupied is True
        assert grid.get_cell(120.0, 120.0, "F.Cu").net == "N1"
        # The cell at the same OFFSET from zero (i.e. where the origin-blind grid
        # would have marked it) is untouched.
        assert grid.get_cell(100.25, 100.25, "F.Cu").occupied is False

    def test_trace_and_obstacle_markers_honour_the_origin(self):
        grid = RoutingGrid(width=40, height=40, resolution=0.5, origin=(100.0, 100.0))
        grid.mark_trace(start=(110.0, 110.0), end=(115.0, 110.0),
                        width=0.25, net="N2", layer="F.Cu")
        assert grid.get_cell(112.5, 110.0, "F.Cu").net == "N2"
        # The same offset from ZERO is off the board entirely: out-of-bounds reads
        # return the synthetic boundary cell, never the trace we just marked.
        off_board = grid.get_cell(12.5, 10.0, "F.Cu")
        assert off_board.obstacle_type == "boundary" and off_board.net is None

        grid.mark_obstacle(x=130.0, y=130.0, radius=1.0)
        assert grid.get_cell(130.0, 130.0, "F.Cu").obstacle_type == "hole"
