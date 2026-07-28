"""Regression test for the corner-graze blind spot in ``_segment_clear``
(docket ``019f9fb32de7``).

Point sampling at a fixed step (0.1mm, :attr:`pathfinder.PathSegment.points`)
cannot see a cell whose CORNER the chord clips: the chord passes through the
corner region strictly between two samples, and the old ``_segment_clear``
reported the segment clear anyway. The fix (this round) replaces fixed-step
sampling with an EXACT swept-cell traversal —
:func:`agent_router.pathfinder._swept_cells` — that finds every cell the
chord's true geometry crosses, however briefly.

THE GEOMETRY IS BUILT, NOT SEARCHED (the earlier draft of this acceptance
criterion — "if your test would pass with a smaller sample step, it is
testing the wrong thing" — was rejected because no FIXED geometry can satisfy
it for every possible step; see the round's brief, [R2]). Instead this
fixture is exact: a blocked cell B sits at grid cell (5, 5) of a
resolution=1.0mm grid (world square ``[5, 6) x [5, 6)``). The chord runs along
the exact line ``x + y = 10.0001`` from deep inside cell (5, 4) to deep inside
cell (4, 5) — both left clear. That line crosses B's bottom edge at
``(5.0001, 5.0)`` and B's left edge at ``(5.0, 5.0001)``, so the chord dips
into B for a run of length ``sqrt(2) * 1e-4 ~= 1.414e-4mm`` — three orders of
magnitude below the 0.1mm sample step (matches the round's acceptance target)
and eleven orders above the numerical tolerance either this module
(``_SWEEP_EPS``) or the geometric DRC (``drc_geom_primitives.EPS``, 1e-9mm)
treats as float noise. The two endpoints are placed symmetrically so the
sliver falls at the geometric MIDPOINT of the ~1.414mm chord: the point
farthest, on average, from any small fixed-step sample grid.
"""

import math

from agent_router.grid import RoutingGrid
from agent_router.pathfinder import PathSegment, _segment_clear

_NET = "SIG1"
_LAYER = "F.Cu"

# The exact chord and blocked cell described in the module docstring.
_START = (5.5, 4.5001)
_END = (4.5, 5.5001)
_BLOCKED_CELL_CENTRE = (5.5, 5.5)


def _make_fixture() -> RoutingGrid:
    """Build the grid described in the module docstring: resolution=1.0mm,
    cell (5, 5) blocked directly (not via :meth:`RoutingGrid.mark_obstacle`,
    whose own rounding would make the exact sliver arithmetic above fragile
    to touch) — a "hole" blocks every net, matching the existing pattern used
    by ``TestSimplifyOrthogonalGuard`` in ``test_pathfinder.py``.
    """
    grid = RoutingGrid(width=12.0, height=12.0, resolution=1.0,
                       clearance=0.0, trace_width=0.0)
    col, row = grid._pos_to_cell(*_BLOCKED_CELL_CENTRE)
    assert (col, row) == (5, 5), \
        "fixture drifted: blocked cell is no longer (5, 5)"
    blocked = grid._grid[_LAYER][row][col]
    blocked.occupied = True
    blocked.net = None
    blocked.obstacle_type = "hole"
    return grid


def _sample_points(start, end, step):
    """Reproduce the OLD ``_segment_clear``'s fixed-step sampling exactly
    (see :attr:`pathfinder.PathSegment.points`'s algorithm), parametrised on
    *step* so the same logic can be re-run at a tighter resolution."""
    points = [start]
    length = math.dist(start, end)
    if length > step:
        steps = int(math.ceil(length / step))
        dx = end[0] - start[0]
        dy = end[1] - start[1]
        for i in range(1, steps):
            t = i / steps
            points.append((start[0] + t * dx, start[1] + t * dy))
    points.append(end)
    return points


class TestSegmentClearSeesACornerGraze:
    """All four tests share one fixture (see module docstring). Ordered so a
    failure earlier in the class explains a failure later: if the premise
    test fails, the fixture itself is broken and nothing below it means
    anything.
    """

    def test_premises_hold(self):
        """The fixture is what the module docstring claims, or nothing below
        proves anything. Both endpoints route clear; the blocked cell truly
        blocks; and the chord's true geometry (checked independently of any
        sampling — a point on the finite segment, not just the infinite
        line) lies inside the blocked cell's square.
        """
        grid = _make_fixture()

        assert grid.can_route_through(_START[0], _START[1], _NET, _LAYER) is True
        assert grid.can_route_through(_END[0], _END[1], _NET, _LAYER) is True
        assert grid.can_route_through(
            _BLOCKED_CELL_CENTRE[0], _BLOCKED_CELL_CENTRE[1], _NET, _LAYER
        ) is False

        # A point strictly between the two crossing points computed in the
        # module docstring, (5.0001, 5.0) and (5.0, 5.0001): x=5.00005 is
        # between end.x (4.5) and start.x (5.5), so it's on the finite chord,
        # not just the infinite line through it.
        c = _START[0] + _START[1]  # the chord's line: x + y = c
        x_probe = 5.00005
        assert _END[0] < x_probe < _START[0], "probe x must lie on the finite chord"
        y_probe = c - x_probe
        assert 5.0 <= x_probe < 6.0
        assert 5.0 <= y_probe < 6.0, \
            "the chosen chord does not truly clip the blocked cell's square"

    def test_old_point_sampling_at_0_1mm_misses_the_clip(self):
        """Demonstrates the DEFECT directly, not hypothetically: probing
        every 0.1mm sample the segment offers — exactly what the OLD
        ``_segment_clear`` did — finds nothing blocked, even though the
        chord truly clips the blocked cell (``test_premises_hold``). This is
        what makes the corner-graze a real gap rather than a theoretical
        one.
        """
        grid = _make_fixture()
        seg = PathSegment(start=_START, end=_END, layer=_LAYER)
        assert len(seg.points) >= 10, \
            "fixture too short to exercise multi-sample stepping"
        assert all(
            grid.can_route_through(pt[0], pt[1], _NET, _LAYER) for pt in seg.points
        ), "expected every 0.1mm sample to miss the sliver — fixture drifted"

    def test_tightening_the_sample_step_to_0_001mm_still_misses_it(self):
        """[R2] 'Shrinking the sample step' is REJECTED in the brief as a
        fail-open that reads as a fix ('it moves the residue without
        removing it'). Demonstrated here, not merely asserted: even a step
        100x tighter than production (0.001mm vs 0.1mm) still walks past the
        ~1.414e-4mm sliver without a single sample landing inside it, run
        against the UNFIXED sampling algorithm. No fixed step is safe for
        this bug class — this is the half-mutation evidence for that claim.
        """
        grid = _make_fixture()
        tight_points = _sample_points(_START, _END, 0.001)
        assert len(tight_points) >= 100, \
            "fixture too short to exercise the tightened step meaningfully"
        assert all(
            grid.can_route_through(pt[0], pt[1], _NET, _LAYER) for pt in tight_points
        ), "0.001mm sampling caught the sliver — shrink the fixture and retry"

    def test_segment_clear_reports_the_corner_clip(self):
        """THE FIX: ``_segment_clear`` must return False for this chord, even
        though the old point-sampling algorithm — proven above, at two step
        sizes — sees nothing wrong with it either way.
        """
        grid = _make_fixture()
        assert _segment_clear(grid, _START, _END, _NET, _LAYER) is False
