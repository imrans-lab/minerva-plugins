"""
Tests for pathfinding algorithms.
"""

import pytest
from agent_router.grid import RoutingGrid
from agent_router.pathfinder import find_path, Path, PathSegment


class TestDirectPath:
    """Tests for direct path finding."""

    def test_direct_path_unobstructed(self):
        """Find direct path when nothing blocks it."""
        grid = RoutingGrid(width=50, height=50, resolution=0.5)
        path = find_path(grid, start=(10, 25), end=(40, 25), net="SIG1")

        assert path is not None
        assert path.start == (10, 25)
        assert path.end == (40, 25)
        assert len(path.segments) == 1  # Direct line

    def test_direct_diagonal_path(self):
        """Direct diagonal path works."""
        grid = RoutingGrid(width=50, height=50, resolution=0.5)
        path = find_path(grid, start=(10, 10), end=(40, 40), net="SIG1")

        assert path is not None
        assert len(path.segments) == 1

    def test_direct_path_blocked(self):
        """Direct path fails when blocked."""
        grid = RoutingGrid(width=50, height=50, resolution=0.5)
        grid.mark_obstacle(x=25, y=25, radius=5)

        # Direct path is blocked, but A* should find alternative
        path = find_path(grid, start=(10, 25), end=(40, 25), net="SIG1")
        # Should find path around obstacle
        assert path is not None
        assert len(path.segments) >= 2


class TestLShapedPath:
    """Tests for L-shaped path finding."""

    def test_l_shaped_path_around_obstacle(self):
        """Route around single obstacle with L-shape."""
        grid = RoutingGrid(width=50, height=50, resolution=0.5)
        grid.mark_obstacle(x=25, y=25, radius=3)

        path = find_path(grid, start=(10, 25), end=(40, 25), net="SIG1")

        assert path is not None
        assert len(path.segments) >= 2  # At least one bend
        assert not path.passes_through(25, 25)

    def test_l_path_horizontal_then_vertical(self):
        """L-path can go horizontal then vertical."""
        grid = RoutingGrid(width=50, height=50, resolution=0.5)
        # Block direct path
        grid.mark_obstacle(x=25, y=35, radius=3)

        path = find_path(grid, start=(10, 40), end=(40, 30), net="SIG1")

        assert path is not None


class TestAStarPath:
    """Tests for A* pathfinding."""

    def test_no_path_when_blocked(self):
        """Return None when no valid path exists."""
        grid = RoutingGrid(width=50, height=50, resolution=0.5)
        # Create wall across entire board
        for y in range(51):
            grid.mark_obstacle(x=25, y=y, radius=0.5)

        path = find_path(grid, start=(10, 25), end=(40, 25), net="SIG1")
        assert path is None

    def test_path_respects_clearance(self):
        """Path maintains clearance from other nets."""
        # Use a larger grid with a partial blocker (not full height)
        grid = RoutingGrid(width=50, height=50, resolution=0.5, clearance=0.2)
        # Create a trace that doesn't span the full height, leaving room to go around
        grid.mark_trace(start=(25, 15), end=(25, 35), width=0.25, net="OTHER", layer="F.Cu")

        path = find_path(grid, start=(10, 25), end=(40, 25), net="SIG1")

        # Path should go around, not through
        assert path is not None
        for segment in path.segments:
            for point in segment.points:
                # Should not pass directly through the other trace center
                if 15 <= point[1] <= 35:  # In the y-range of the blocker
                    assert abs(point[0] - 25) >= 0.2  # Keep away from x=25

    def test_astar_finds_reasonable_path(self):
        """A* finds reasonably short path, not just any path."""
        grid = RoutingGrid(width=100, height=100, resolution=1.0)
        # Create obstacle requiring detour
        grid.mark_obstacle(x=50, y=50, radius=20)

        path = find_path(grid, start=(10, 50), end=(90, 50), net="SIG1")

        assert path is not None
        assert path.total_length() < 150  # Should not take ridiculous detour

    def test_complex_maze(self):
        """Find path through more complex obstacle arrangement."""
        grid = RoutingGrid(width=50, height=50, resolution=0.5)

        # Create a simple maze
        grid.mark_obstacle(x=20, y=15, radius=5)
        grid.mark_obstacle(x=30, y=35, radius=5)
        grid.mark_obstacle(x=25, y=25, radius=3)

        path = find_path(grid, start=(5, 25), end=(45, 25), net="SIG1")

        assert path is not None


class TestPathWithVias:
    """Tests for paths using vias."""

    def test_via_path_when_layer_blocked(self):
        """Use via when primary layer is fully blocked."""
        grid = RoutingGrid(width=50, height=50, resolution=0.5)

        # Block F.Cu completely in the path
        for x in range(20, 31):
            grid.mark_trace(
                start=(x, 0), end=(x, 50),
                width=0.5, net="BLOCKER", layer="F.Cu"
            )

        path = find_path(
            grid,
            start=(10, 25),
            end=(40, 25),
            net="SIG1",
            allow_via=True
        )

        # Should find path using via to B.Cu
        assert path is not None
        assert len(path.vias) >= 1


class TestPathSegment:
    """Tests for PathSegment class."""

    def test_segment_length(self):
        """Segment calculates length correctly."""
        seg = PathSegment(start=(0, 0), end=(3, 4), layer="F.Cu")
        assert seg.length() == pytest.approx(5.0)

    def test_segment_points(self):
        """Segment generates points along its length."""
        seg = PathSegment(start=(0, 0), end=(10, 0), layer="F.Cu")
        points = seg.points

        assert points[0] == (0, 0)
        assert points[-1] == (10, 0)
        assert len(points) > 2


class TestPath:
    """Tests for Path class."""

    def test_path_total_length(self):
        """Path calculates total length."""
        path = Path(segments=[
            PathSegment(start=(0, 0), end=(10, 0), layer="F.Cu"),
            PathSegment(start=(10, 0), end=(10, 10), layer="F.Cu"),
        ])
        assert path.total_length() == pytest.approx(20.0)

    def test_path_passes_through(self):
        """Path correctly reports points it passes through."""
        path = Path(segments=[
            PathSegment(start=(0, 0), end=(10, 0), layer="F.Cu"),
        ])

        assert path.passes_through(5, 0) == True
        assert path.passes_through(5, 10) == False

    def test_empty_path(self):
        """Empty path has no start/end."""
        path = Path()
        assert path.start is None
        assert path.end is None
        assert path.total_length() == 0


class TestStaircaseCollapse:
    """Tests for staircase collapse in orthogonal A* paths."""

    def test_orthogonal_diagonal_produces_few_segments(self):
        """prefer_orthogonal diagonal route collapses into L-bend, not staircase."""
        grid = RoutingGrid(width=50, height=50, resolution=0.5)
        path = find_path(
            grid, start=(5, 5), end=(40, 40), net="SIG1",
            prefer_orthogonal=True,
        )
        assert path is not None
        # Without collapse this would be ~140 segments. With collapse: 2 (one L-bend).
        assert len(path.segments) <= 4

    def test_orthogonal_around_obstacle_still_routes(self):
        """Staircase collapse handles obstacle by splitting into multiple L-bends."""
        grid = RoutingGrid(width=50, height=50, resolution=0.5)
        # Obstacle in the middle forces A* to detour
        grid.mark_obstacle(x=25, y=25, radius=5)

        path = find_path(
            grid, start=(5, 5), end=(45, 45), net="SIG1",
            prefer_orthogonal=True,
        )
        assert path is not None
        # Should still be much fewer segments than raw staircase
        assert len(path.segments) < 30

    def test_orthogonal_all_segments_hv(self):
        """After collapse, all segments are still horizontal or vertical."""
        grid = RoutingGrid(width=60, height=60, resolution=0.5)
        path = find_path(
            grid, start=(5, 5), end=(50, 45), net="SIG1",
            prefer_orthogonal=True,
        )
        assert path is not None
        for seg in path.segments:
            dx = abs(seg.end[0] - seg.start[0])
            dy = abs(seg.end[1] - seg.start[1])
            # Each segment should be predominantly H or V
            # (exact pad-to-grid hops may have tiny diagonal component)
            if dx > 0.2 and dy > 0.2:
                # Allow only the first/last segment (pad-to-grid connection)
                assert seg == path.segments[0] or seg == path.segments[-1]

    def test_straight_path_unchanged(self):
        """A purely horizontal path is not affected by collapse."""
        grid = RoutingGrid(width=50, height=50, resolution=0.5)
        path = find_path(
            grid, start=(5, 25), end=(45, 25), net="SIG1",
            prefer_orthogonal=True,
        )
        assert path is not None
        # L-path finds this directly: one H segment
        assert len(path.segments) <= 2

    def test_l_path_not_degraded(self):
        """An L-shaped path stays as 2 segments after collapse."""
        grid = RoutingGrid(width=50, height=50, resolution=0.5)
        path = find_path(
            grid, start=(5, 5), end=(40, 30), net="SIG1",
            prefer_orthogonal=True,
        )
        assert path is not None
        # L-path finder should get this before A* even runs
        assert len(path.segments) == 2
