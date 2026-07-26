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
        """prefer_orthogonal diagonal route collapses into L-bend, not staircase.

        TIGHTENED in round C2b: the comment said "2" while the bound admitted 4.
        A bound with slack in it cannot fail when the shape degrades, which is the
        only thing this test is for.
        """
        grid = RoutingGrid(width=50, height=50, resolution=0.5)
        path = find_path(
            grid, start=(5, 5), end=(40, 40), net="SIG1",
            prefer_orthogonal=True,
        )
        assert path is not None
        # Without collapse this would be ~140 segments. With collapse: 2 (one L-bend).
        assert [(s.start, s.end) for s in path.segments] == [
            ((5, 5), (40, 5)), ((40, 5), (40, 40))]

    def test_orthogonal_around_obstacle_still_routes(self):
        """An obstacle off the L corridor does not force a staircase at all — the
        L-path strategy answers first, at 2 segments.

        TIGHTENED in round C2b: this asserted ``< 30`` against an actual of 2, so
        it would have passed a route that collapsed 15x worse than it does. The
        obstacle at (25,25) is nowhere near the (5,5)->(45,5)->(45,45) corridor,
        which is exactly why the L is clear; the detouring case is covered by
        ``test_l_shaped_path_around_obstacle`` and ``test_complex_maze``.
        """
        grid = RoutingGrid(width=50, height=50, resolution=0.5)
        # Obstacle in the middle forces A* to detour
        grid.mark_obstacle(x=25, y=25, radius=5)

        path = find_path(
            grid, start=(5, 5), end=(45, 45), net="SIG1",
            prefer_orthogonal=True,
        )
        assert path is not None
        assert [(s.start, s.end) for s in path.segments] == [
            ((5, 5), (45, 5)), ((45, 5), (45, 45))]
        assert not path.passes_through(25, 25)

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
        """A purely horizontal path is not affected by collapse.

        TIGHTENED in round C2b (019f9cc3245d). The comment always said "one H
        segment" while the assertion allowed two — and two is exactly what this
        returned, the second of them ZERO-LENGTH, for as long as the bug was
        live. A bound that admits the defect it describes is not a regression
        lock; the count is now the one the comment claims.
        """
        grid = RoutingGrid(width=50, height=50, resolution=0.5)
        path = find_path(
            grid, start=(5, 25), end=(45, 25), net="SIG1",
            prefer_orthogonal=True,
        )
        assert path is not None
        # L-path finds this directly: one H segment
        assert len(path.segments) == 1
        assert path.segments[0].length() > 0.0

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


class TestNoDegenerateSegmentIsEverEmitted:
    """Docket 019f9cc3245d (severity 2) — the pathfinder must not PRODUCE a
    zero-length leg.

    Why it matters downstream, and why the fix is here rather than there: a
    zero-length leg is copper the candidate overlay refuses to model
    (``ir_candidates`` raises ``UnsupportedGeometry``), and ``check_candidates``
    turns that into ONE batch-wide indeterminate returned before any per-candidate
    attribution — so a single straight route blinds the geometric verdict for
    every other candidate checked with it. The end-to-end proof of that is
    ``tests/test_route_degenerate_geometry.py``; these are the narrow locks on the
    producer.
    """

    @pytest.mark.parametrize("start,end,axis", [
        ((10.0, 20.0), (30.0, 20.0), "horizontal"),
        ((20.0, 10.0), (20.0, 30.0), "vertical"),
    ])
    def test_an_axis_aligned_orthogonal_route_is_one_real_segment(
            self, start, end, axis):
        """BOTH orientations, because both were broken and they broke differently.

        The corners are built from the endpoints' own coordinates, so a shared
        ROW made the horizontal-first corner equal ``end`` (degenerate SECOND leg)
        and a shared COLUMN made it equal ``start`` (degenerate FIRST leg). A test
        that only covered one would have left the other shipping.
        """
        grid = RoutingGrid(width=50.0, height=50.0, resolution=0.2)
        path = find_path(grid, start=start, end=end, net="N1", layer="F.Cu",
                         prefer_orthogonal=True)

        assert path is not None
        assert len(path.segments) == 1, [(s.start, s.end) for s in path.segments]
        assert [s for s in path.segments if s.length() == 0.0] == []
        # ...and it is still the run that was asked for, not a shortened one.
        assert path.start == start
        assert path.end == end

    def test_coincident_endpoints_are_refused_not_routed_as_zero_length(self):
        """The other producer of degenerate copper: there is nothing to route
        between a point and itself, and ``_try_direct_path`` would have emitted a
        single zero-length segment for it (``_segment_clear`` probes one point and
        passes). None is the honest answer — the caller records the pair unrouted.
        """
        grid = RoutingGrid(width=50.0, height=50.0, resolution=0.2)
        for prefer_orthogonal in (False, True):
            assert find_path(grid, start=(10.0, 10.0), end=(10.0, 10.0),
                             net="N1", layer="F.Cu",
                             prefer_orthogonal=prefer_orthogonal) is None

    def test_a_non_axis_aligned_route_is_unchanged(self):
        """REGRESSION GUARD. The L-path is the common case and the fix edits it,
        so pin that a genuine L is untouched: two segments, bending at the
        horizontal-first corner, no leg degenerate.
        """
        grid = RoutingGrid(width=50.0, height=50.0, resolution=0.2)
        path = find_path(grid, start=(10.0, 10.0), end=(30.0, 25.0), net="N1",
                         layer="F.Cu", prefer_orthogonal=True)

        assert path is not None
        assert [(s.start, s.end) for s in path.segments] == [
            ((10.0, 10.0), (30.0, 10.0)),
            ((30.0, 10.0), (30.0, 25.0)),
        ]
        assert all(s.length() > 0.0 for s in path.segments)

    def test_the_diagonal_direct_path_is_still_taken_when_not_orthogonal(self):
        """The other half of "unchanged": with prefer_orthogonal off, an
        axis-aligned pair still takes the direct chord at step 1 and never reaches
        the new branch. One segment either way — this pins that the fix did not
        move which strategy answers.
        """
        grid = RoutingGrid(width=50.0, height=50.0, resolution=0.2)
        path = find_path(grid, start=(10.0, 10.0), end=(30.0, 25.0), net="N1",
                         layer="F.Cu", prefer_orthogonal=False)
        assert path is not None
        assert [(s.start, s.end) for s in path.segments] == [
            ((10.0, 10.0), (30.0, 25.0))]


    def test_collapse_run_refuses_to_emit_a_degenerate_leg_if_its_premise_breaks(self):
        """``_collapse_run`` is the FIFTH place an L-corner is built from run
        endpoints, and it had no degeneracy guard.

        The honest test for a guard is that it fires when its premise is violated,
        so the premise is violated deliberately here. ``_find_staircase_end`` only
        extends a run while H/V alternate with consistent signs, which is what
        keeps a run's endpoints differing on both axes and this branch unreachable
        from the engine today; the function is called DIRECTLY with a run that
        doubles back, so its endpoints share a row.

        Without the guard, ``(e[0], s[1])`` IS ``e`` and the returned corner list
        carries the same point twice — one zero-length segment in the emitted
        path, and 019f9cc3245d back through a second door.
        """
        from agent_router.pathfinder import _collapse_run

        grid = RoutingGrid(width=20, height=20, resolution=0.5)
        # Alternating H/V that returns to its starting row: endpoints (1,1) and
        # (4,1) share y, which a real staircase run never does.
        points = [(1.0, 1.0), (2.0, 1.0), (2.0, 2.0), (3.0, 2.0),
                  (3.0, 1.0), (4.0, 1.0)]
        collapsed = _collapse_run(points, 0, len(points) - 1, grid, "SIG", "F.Cu")

        assert collapsed[0] == points[0]
        assert collapsed[-1] == points[-1]
        repeats = [(a, b) for a, b in zip(collapsed, collapsed[1:]) if a == b]
        assert repeats == [], collapsed

    def test_collapse_run_still_collapses_a_genuine_staircase_to_an_l(self):
        """The guard must not be a stop-collapsing switch: a real staircase (both
        axes advancing, which is the shape the engine actually produces) still
        becomes two legs through one corner."""
        from agent_router.pathfinder import _collapse_run

        grid = RoutingGrid(width=20, height=20, resolution=0.5)
        points = [(1.0, 1.0), (2.0, 1.0), (2.0, 2.0), (3.0, 2.0),
                  (3.0, 3.0), (4.0, 3.0)]
        collapsed = _collapse_run(points, 0, len(points) - 1, grid, "SIG", "F.Cu")

        assert collapsed == [(1.0, 1.0), (4.0, 1.0), (4.0, 3.0)]


class TestTheRefusalReasonIsRecorded:
    """Round C2b's new refusals are correct but were silent — a pad under an NPTH
    keepout looked exactly like a congested board. ``unroutable_reason`` is the
    in-engine classification; ``RoutingResult.unrouted_reasons`` is where the
    router records it.
    """

    def test_each_refusal_gets_its_own_reason_code(self):
        from agent_router.pathfinder import (
            UNROUTABLE_COINCIDENT, UNROUTABLE_END_BLOCKED,
            UNROUTABLE_NO_PATH, UNROUTABLE_OUT_OF_BOUNDS,
            UNROUTABLE_START_BLOCKED, unroutable_reason)

        grid = RoutingGrid(width=20, height=20, resolution=0.5)
        grid.mark_pad(x=5.0, y=5.0, size=(0.4, 0.4), net="OTHER", layer="F.Cu")
        grid.mark_pad(x=15.0, y=15.0, size=(0.4, 0.4), net="OTHER", layer="F.Cu")

        assert unroutable_reason(grid, (2.0, 2.0), (2.0, 2.0), "SIG") == \
            UNROUTABLE_COINCIDENT
        assert unroutable_reason(grid, (-3.0, 2.0), (2.0, 2.0), "SIG") == \
            UNROUTABLE_OUT_OF_BOUNDS
        assert unroutable_reason(grid, (5.0, 5.0), (2.0, 2.0), "SIG") == \
            UNROUTABLE_START_BLOCKED
        assert unroutable_reason(grid, (2.0, 2.0), (15.0, 15.0), "SIG") == \
            UNROUTABLE_END_BLOCKED
        # Both ends clear: whatever the refusal was, it was not an endpoint.
        assert unroutable_reason(grid, (2.0, 2.0), (8.0, 8.0), "SIG") == \
            UNROUTABLE_NO_PATH
        # ...and the same pad is NOT a blocked start for the net that owns it,
        # which is why the canonical routing path never sees these codes.
        assert unroutable_reason(grid, (5.0, 5.0), (2.0, 2.0), "OTHER") == \
            UNROUTABLE_NO_PATH

    def test_the_router_records_a_reason_for_every_unrouted_pair(self):
        """The two lists are index-aligned and populated together, so a consumer
        can always ask WHY about an entry it can see."""
        from agent_router.board import Board, Net, Obstacle, Pad
        from agent_router.router import route_board

        # SIG's two pads, with a mounting hole sitting ON the first one — the
        # NPTH-over-a-pad shape, which is ordinary board data, not a malformed
        # board. Before round C2b this emitted a path starting inside the hole's
        # keepout; now it correctly refuses, and must say why.
        pads = [
            Pad(component="P1", number="1", net="SIG", position=(5.0, 5.0),
                size=(1.0, 1.0)),
            Pad(component="P2", number="1", net="SIG", position=(15.0, 15.0),
                size=(1.0, 1.0)),
        ]
        board = Board(width=20.0, height=20.0, pads=pads,
                      nets={"SIG": Net(name="SIG", number=1, pads=pads)},
                      obstacles=[Obstacle(position=(5.0, 5.0),
                                          type="mounting_hole", radius=1.5)])

        result = route_board(board, trace_width=0.25, clearance=0.2)

        assert result.unrouted, "fixture must actually fail to route"
        assert len(result.unrouted_reasons) == len(result.unrouted)
        entry = result.unrouted_reasons[0]
        assert entry["net"] == "SIG"
        assert {entry["from"], entry["to"]} == {"P1.1", "P2.1"}
        assert entry["reason"] == "start_blocked"
        assert entry["layer"] == "F.Cu"

    def test_a_board_that_routes_records_no_reasons(self):
        """The list is not a running log — it says exactly as much as `unrouted`."""
        from agent_router.board import Board, Net, Pad
        from agent_router.router import route_board

        pads = [
            Pad(component="P1", number="1", net="SIG", position=(5.0, 5.0),
                size=(1.0, 1.0)),
            Pad(component="P2", number="1", net="SIG", position=(15.0, 15.0),
                size=(1.0, 1.0)),
        ]
        board = Board(width=20.0, height=20.0, pads=pads,
                      nets={"SIG": Net(name="SIG", number=1, pads=pads)})

        result = route_board(board, trace_width=0.25, clearance=0.2)
        assert result.unrouted == []
        assert result.unrouted_reasons == []


class TestAStarRefusesABlockedStart:
    """Docket 019f9bf9c04a (severity 3) — A* validated every cell it stepped INTO
    and never the one it started FROM.

    Latent when found (on the canonical path the start is a pad of the net being
    routed, so its own copper is not blocked for it), and nothing in the suite
    exercised it. These tests are that exercise.
    """

    @staticmethod
    def _grid_with_a_foreign_pad_over_the_start():
        """A grid where (2.1, 2.0) is FOREIGN copper, and the two-point case is
        reachable: start and end sit in the same 0.5mm cell, so A* pops the goal
        immediately and `_simplify_path`'s ``len(points) <= 2`` early return hands
        back ``start -> end`` with no chord verification anywhere."""
        grid = RoutingGrid(width=10.0, height=10.0, resolution=0.5)
        grid.mark_pad(x=2.25, y=2.0, size=(0.4, 0.4), net="OTHER", layer="F.Cu")
        return grid

    def test_a_blocked_start_yields_no_path_instead_of_unverified_copper(self):
        from agent_router.pathfinder import _astar_path, _segment_clear

        grid = self._grid_with_a_foreign_pad_over_the_start()
        start, end = (2.1, 2.0), (2.4, 2.0)

        # PREMISE, asserted so this test cannot pass vacuously: the start really
        # is blocked for SIG, both points land in ONE cell (the two-point path),
        # and the chord that used to be emitted really does run through foreign
        # copper — i.e. there was something unsafe to stop, not merely an
        # unnecessary path.
        assert grid.can_route_through(start[0], start[1], "SIG") is False
        assert grid._pos_to_cell(*start) == grid._pos_to_cell(*end)
        assert _segment_clear(grid, start, end, "SIG", "F.Cu") is False

        assert _astar_path(grid, start, end, "SIG", "F.Cu") is None
        # ...and through the public entry point, with every strategy in play.
        assert find_path(grid, start=start, end=end, net="SIG", layer="F.Cu") is None

    def test_the_same_geometry_still_routes_for_the_net_that_owns_the_copper(self):
        """POSITIVE CONTROL. The refusal must be about the start being blocked FOR
        THIS NET, not about the geometry being small or the cell being occupied.
        OTHER owns that pad, so OTHER may route out of it — which is exactly the
        canonical case (a pad of the net being routed) the docket says keeps this
        bug latent."""
        from agent_router.pathfinder import _astar_path

        grid = self._grid_with_a_foreign_pad_over_the_start()
        start, end = (2.1, 2.0), (2.4, 2.0)

        assert grid.can_route_through(start[0], start[1], "OTHER") is True
        path = _astar_path(grid, start, end, "OTHER", "F.Cu")
        assert path is not None
        assert [(s.start, s.end) for s in path.segments] == [(start, end)]


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
