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


class TestSimplificationStaysInsideTheCorridor:
    """Docket 019f9bd5f2f2 — a simplified path must stay inside the corridor the
    unsimplified path occupied.

    The end-to-end proof lives in tests/test_route_drc.py
    (`test_no_emitted_segment_crosses_a_cell_the_routing_grid_blocked`), which
    drives `route()` and probes the grid the router actually used. These two are
    the narrow regression locks for the specific geometry that decided the fix,
    which a board-level fixture cannot pin precisely.
    """

    def test_simplification_keeps_a_one_cell_jog_douglas_peucker_would_drop(self):
        """WHY THE FIX IS A GRID CHECK AND NOT JUST BETTER GEOMETRY.

        The rejected alternative was textbook Douglas-Peucker — measure each
        candidate's deviation against the ORIGINAL polyline instead of against the
        last kept point. That bounds deviation by `tolerance`, but a deviation
        bound is not a clearance bound, and here they are the same number:
        tolerance is 0.1mm and route_board's default grid_resolution is 0.1mm
        too, so a chord may wander a full cell off the path A* proved clear.

        This is the counterexample, and it is the commonest detour A* makes: a
        ONE-CELL JOG around a single blocked cell. The jog point's perpendicular
        deviation from the chord is EXACTLY 0.1 — not GREATER than tolerance — so
        Douglas-Peucker drops it and emits a chord straight through the blocked
        cell. Measured: 1 blocked probe point for Douglas-Peucker, 0 for the
        grid-checked simplifier.

        If this test ever fails because the jog point was dropped, the
        simplifier stopped asking the grid and the severity-1 defect is back.
        """
        from agent_router.pathfinder import _simplify_path

        grid = RoutingGrid(width=10, height=10, resolution=0.1,
                           clearance=0.0, trace_width=0.0)
        # Block exactly ONE cell — the one whose centre is (5.15, 0.05).
        col, row = grid._pos_to_cell(5.15, 0.05)
        blocked_cell = grid._grid["F.Cu"][row][col]
        blocked_cell.occupied = True
        blocked_cell.net = None
        blocked_cell.obstacle_type = "hole"
        assert grid._cell_to_pos(col, row) == pytest.approx((5.15, 0.05))

        # The polyline A* emits: a one-cell jog OVER that cell. Every point of it
        # is routable, or the premise (A* is correct, simplification is not) is
        # not what is being tested.
        points = [(4.95, 0.05), (5.05, 0.05), (5.15, 0.15),
                  (5.25, 0.05), (5.35, 0.05)]
        for pt in points:
            assert grid.can_route_through(pt[0], pt[1], "SIG") is True

        simplified = _simplify_path(points, grid, "SIG", "F.Cu")

        # The jog survives — dropping it is precisely what Douglas-Peucker does.
        assert (5.15, 0.15) in simplified, (
            "the jog point was dropped; the replacement chord runs through the "
            "blocked cell at (5.15, 0.05)")
        # And the shipped result is clear end to end, at the pathfinder's own
        # sampling resolution.
        for i in range(len(simplified) - 1):
            seg = PathSegment(start=simplified[i], end=simplified[i + 1],
                              layer="F.Cu")
            for pt in seg.points:
                assert grid.can_route_through(pt[0], pt[1], "SIG") is True, \
                    f"simplified run {simplified[i]}->{simplified[i+1]} is blocked at {pt}"

    def test_a_genuinely_collinear_run_still_collapses(self):
        """The fix must not simply stop simplifying — that would 'pass' the
        corridor property by never dropping anything, and every route would ship
        one vertex per grid cell.

        A straight run through free space has nothing to hug, so it must still
        collapse to its two endpoints.
        """
        from agent_router.pathfinder import _simplify_path

        grid = RoutingGrid(width=10, height=10, resolution=0.1,
                           clearance=0.0, trace_width=0.0)
        points = [(1.05 + 0.1 * i, 5.05) for i in range(20)]

        simplified = _simplify_path(points, grid, "SIG", "F.Cu")

        assert simplified == [points[0], points[-1]], simplified

    def test_the_orthogonal_guard_fires_when_the_cell_centre_invariant_is_broken(self):
        """`_simplify_orthogonal`'s grid check is a GUARD ON AN INVARIANT, and this
        is the honest test for one: feed it a premise violation and watch it fire.

        Cold review found that deleting that check leaves the whole suite green,
        and it is right that nothing engine-driven exercises it — the merge is
        EXACT under the invariant the only caller supplies (cardinal A*, so
        interior points are cell centres one axis apart; see the proof in
        `_simplify_orthogonal`'s docstring). An earlier draft of that docstring
        claimed the check closed a live terminal-step defect. It does not, the
        claim was withdrawn, and this test replaces it with one that is true.

        So the premise is broken deliberately, the way a future change would break
        it — points that are NOT cell centres, with a perpendicular excursion big
        enough to leave the row. `_direction` still reads both steps as "H", so
        the pre-guard code would merge them into a chord through a blocked cell.
        If this ever fails, the guard was removed and `_simplify_orthogonal` is
        merging on direction alone again.
        """
        from agent_router.pathfinder import _simplify_orthogonal, _simplify_path

        grid = RoutingGrid(width=10, height=10, resolution=0.1,
                           clearance=0.0, trace_width=0.0)
        col, row = grid._pos_to_cell(1.5, 5.02)
        blocked_cell = grid._grid["F.Cu"][row][col]
        blocked_cell.occupied = True
        blocked_cell.net = None
        blocked_cell.obstacle_type = "hole"

        # Both steps classify as "H" (|dx| = 0.5 > |dy| = 0.4), so the direction
        # test alone would merge them.
        points = [(1.0, 5.0), (1.5, 5.4), (2.0, 5.0)]

        def _blocked(a, b):
            seg = PathSegment(start=a, end=b, layer="F.Cu")
            return [p for p in seg.points
                    if not grid.can_route_through(p[0], p[1], "SIG")]

        # Premise: the polyline is clear and the merged chord is not — otherwise
        # this test proves nothing.
        assert _blocked(points[0], points[1]) == []
        assert _blocked(points[1], points[2]) == []
        assert _blocked(points[0], points[2]), \
            "the merged chord must be blocked or there is no guard to test"

        assert _simplify_orthogonal(points, grid, "SIG", "F.Cu") == points, \
            "the guard did not fire: the peak was merged into a blocked chord"
        # The diagonal branch refuses the same merge, by the same question.
        assert _simplify_path(points, grid, "SIG", "F.Cu") == points
