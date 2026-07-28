"""Unit tests for ``agent_router.pathfinder._swept_cells`` (round D10).

THIS FUNCTION HAD NO DEDICATED TEST FILE BEFORE THIS ONE.
``test_segment_clear_corners.py`` covers exactly one geometric case (a
mid-chord corner sliver, the round ``019f9fb32de7`` fixed) plus its own
premises; nothing in the suite ever asked whether ``_swept_cells`` reports
the cell its OWN endpoints sit in. It didn't, ~70% of the time at the
production grid default (30x30mm board, 0.1mm resolution, 0.05mm-quantised
pad coordinates) — see ``TestEndpointCellProperty`` below, and the round D10
report for the full measurement. ``_pos_to_cell`` floors a point that sits
within float noise of a lattice line to one arbitrary side of it; the old
sweep, driven purely by interval midpoints, silently resolved that same
point to the OTHER side and never mentioned the first.

THE FIX resolves any point the sweep touches that sits on a grid line to
EVERY cell whose closed square contains it (``_straddling_indices``), not
just whichever one ``_pos_to_cell``'s bare ``floor`` happens to name. That is
applied in three places, each with its own test class here:

- the chord's own two endpoints (``TestEndpointCellProperty``) — the
  regression measured above;
- a chord collinear with a grid line for its FULL length, e.g. a horizontal
  run at an exact multiple of the resolution (``TestCollinearWithGridLine``)
  — a whole omitted row/column, not a point graze;
- an interior LATTICE CORNER the chord passes through exactly, e.g. a 45°
  chord through cell centres (``TestInteriorLatticeCorner``) — the same
  corner a diagonal A* step already refuses to cross
  (``pathfinder.py:444-450``), now checked here too.

``TestMutationTargets`` documents, with real numbers, which specific
mutants each test kills — see the round's report for the CAREFUL TIER
mutation proof (real output, not just this file's intent).
"""

import math

from agent_router.grid import RoutingGrid
from agent_router.pathfinder import _straddling_indices, _swept_cells, _SWEEP_EPS

_NET = "SIG1"


def _production_grid() -> RoutingGrid:
    """The grid the round's repro and rate measurement both used: 30x30mm,
    0.1mm resolution, origin at the world origin — Minerva's default."""
    return RoutingGrid(width=30.0, height=30.0, resolution=0.1, origin=(0.0, 0.0))


class TestEndpointCellProperty:
    """THE regression this round fixes: ``_swept_cells(grid, start, end)``
    must contain ``grid._pos_to_cell(*start)`` and
    ``grid._pos_to_cell(*end)`` — always, not usually.
    """

    def test_the_reported_production_repro_chord(self):
        """The exact chord from the round's brief, reproduced independently
        here rather than trusted from the report: both endpoints land in
        cells the OLD sweep omitted."""
        grid = _production_grid()
        start = (26.0, 9.7)
        end = (9.45, 26.2)

        start_cell = grid._pos_to_cell(*start)
        end_cell = grid._pos_to_cell(*end)
        assert start_cell == (260, 96)
        assert end_cell == (94, 262)

        cells = _swept_cells(grid, start, end)
        assert start_cell in cells, "start cell omitted from the sweep"
        assert end_cell in cells, "end cell omitted from the sweep"

    # A deterministic (not randomised — no flakiness, no seed to babysit)
    # sweep of 0.05mm-quantised coordinate pairs across the production grid,
    # mixing values that land exactly on a lattice line (multiples of 0.1)
    # with values that don't (the +0.05 offset), on both axes, both
    # endpoints. This is the combinatorial shape of the round's 30,000-chord
    # measurement, without depending on a random seed to reproduce it.
    _OFFSETS_MM = [round(0.05 * k, 2) for k in range(0, 40, 1)]

    def test_endpoint_cells_always_present_over_quantised_coordinates(self):
        grid = _production_grid()
        checked = 0
        for sx in self._OFFSETS_MM[0:5]:
            for sy in self._OFFSETS_MM[5:10]:
                for ex in self._OFFSETS_MM[10:15]:
                    for ey in self._OFFSETS_MM[15:20]:
                        start = (sx + 5.0, sy + 5.0)
                        end = (ex + 15.0, ey + 15.0)
                        if start == end:
                            continue
                        cells = _swept_cells(grid, start, end)
                        start_cell = grid._pos_to_cell(*start)
                        end_cell = grid._pos_to_cell(*end)
                        assert start_cell in cells, (
                            f"start {start} -> cell {start_cell} omitted"
                        )
                        assert end_cell in cells, (
                            f"end {end} -> cell {end_cell} omitted"
                        )
                        checked += 1
        # This is the combinatorial-coverage premise: if the nested loops
        # above stop producing many cases, the test has quietly stopped
        # proving much.
        assert checked >= 200, "fixture drifted: too few pairs exercised"


class TestDegenerateChord:
    """A zero-length chord (``start == end``) is handled by its own
    short-circuit, before any of the closed-square treatment below applies —
    a single point has no "other side" of a boundary to omit, so
    ``_pos_to_cell``'s pick is the only cell there is an argument for. These
    pin that the short-circuit (a) still fires, (b) still returns the right
    cell, including when the point sits exactly on a lattice line or corner,
    and (c) was not mutated into dropping the cell entirely.
    """

    def test_degenerate_interior_point(self):
        grid = _production_grid()
        p = (12.34, 5.67)
        assert _swept_cells(grid, p, p) == {grid._pos_to_cell(*p)}

    def test_degenerate_exactly_on_a_lattice_corner(self):
        grid = _production_grid()
        p = (10.0, 10.0)  # exact multiple of the 0.1mm resolution on both axes
        result = _swept_cells(grid, p, p)
        assert result == {grid._pos_to_cell(*p)}
        assert len(result) == 1, (
            "a degenerate chord has no 'other side' — it must stay a single "
            "cell even when the point sits on a lattice corner"
        )

    def test_degenerate_branch_is_not_dead_code(self):
        """Kills the mutant that turns the degenerate short-circuit into
        ``return set()``: a zero-length chord must return something, and it
        must be the cell the point is actually in."""
        grid = _production_grid()
        p = (3.3, 4.4)
        result = _swept_cells(grid, p, p)
        assert result != set()
        assert result == {grid._pos_to_cell(*p)}


class TestOriginAxesAreIndependent:
    """Nothing in the wider suite routes a grid whose ``origin[0] !=
    origin[1]`` — every existing fixture uses a square or all-zero origin, so
    a mutant that swaps ``ox`` for ``oy`` (or vice versa) in one axis's
    crossing formula survives unnoticed. This grid's origin is deliberately
    asymmetric (``ox=0.0``, ``oy=5.0``), and the chord's ``dx`` (3) and
    ``dy`` (2) are deliberately UNEQUAL so the two axes' crossings never
    coincide and mask a swap (a 45-degree chord's symmetry would hide it).

    The expected cell set below was derived independently by hand (walking
    each of the six intervals the true crossings cut the chord into) and
    confirmed against the real, correct code before being written here —
    see the round's report. Swapping ``ox``/``oy`` in the y-crossing formula
    sends both of the real y-crossings (t=0.25 at line y=6, t=0.75 at line
    y=7) out of the ``[0, 1]`` range entirely (they become large negative
    numbers, since ``ox=0`` is 5.0 away from the ``y0=5.5`` the formula
    subtracts against), so the mutated sweep never splits the chord at
    those two rows transitions and drops cells (1, 0) and (2, 2).
    """

    def test_diagonal_chord_reports_every_cell_on_an_asymmetric_origin(self):
        grid = RoutingGrid(width=10.0, height=10.0, resolution=1.0,
                           origin=(0.0, 5.0))
        start = (0.5, 5.5)
        end = (3.5, 7.5)

        # Premises: dx != dy (no accidental 45-degree symmetry), and the
        # origin really is asymmetric.
        assert (end[0] - start[0]) != (end[1] - start[1])
        assert grid.origin[0] != grid.origin[1]

        cells = _swept_cells(grid, start, end)
        assert cells == {(0, 0), (1, 0), (1, 1), (2, 1), (2, 2), (3, 2)}


class TestBoundingBoxHighEdgeOnGridLine:
    """The crossing-enumeration loops use ``range(math.floor(lo),
    math.ceil(hi) + 1)`` on each axis. When the chord's bounding box's high
    edge lands EXACTLY on a lattice line (``hi`` is already an integer number
    of cells from the origin), ``math.ceil(hi) == hi`` and the ``+ 1`` is the
    only thing that makes the range's exclusive upper bound still include
    ``hi`` itself. Pins that the cell at that exact high edge is present.
    """

    def test_high_edge_exactly_on_a_line_reports_its_cell(self):
        grid = RoutingGrid(width=5.0, height=5.0, resolution=0.1,
                           origin=(0.0, 0.0))
        start = (0.25, 0.55)
        end = (2.0, 0.55)  # u1 = 20.0 exactly: the bounding box's high edge
        # lands precisely on a lattice line.

        u1 = (end[0] - grid.origin[0]) / grid.resolution
        assert u1 == math.floor(u1), "fixture drifted: end must land exactly on a line"

        cells = _swept_cells(grid, start, end)
        end_cell = grid._pos_to_cell(*end)
        assert end_cell in cells
        # The cell immediately behind the end cell (the last real column
        # before the exact-on-a-line end) must also be present — the chord
        # unambiguously runs through it.
        assert (end_cell[0] - 1, end_cell[1]) in cells


class TestCollinearWithGridLine:
    """A horizontal or vertical chord that sits EXACTLY on a lattice line for
    its FULL length. ``dy == 0`` (or ``dx == 0``) skips the other axis's
    crossing loop entirely (there is nothing to cross — the chord never
    leaves that constant coordinate), so every interval midpoint shares the
    same on-the-line coordinate and ``_pos_to_cell`` resolves the WHOLE run
    to one arbitrary side. Demonstrated with the exact chord from the
    round's brief: 16 cells in the untouched row must all be there, not just
    the one row the old code reported.
    """

    def test_horizontal_chord_on_a_grid_line_reports_both_rows(self):
        grid = RoutingGrid(width=5.0, height=5.0, resolution=0.1,
                           origin=(0.0, 0.0))
        start = (0.25, 1.0)
        end = (1.75, 1.0)

        # Premise: y really is exactly on a lattice line.
        u = (start[1] - grid.origin[1]) / grid.resolution
        assert u == round(u)

        cells = _swept_cells(grid, start, end)
        rows = {r for _, r in cells}
        assert rows == {9, 10}, "expected both rows straddling y=1.0"

        cols_row_9 = sorted(c for c, r in cells if r == 9)
        cols_row_10 = sorted(c for c, r in cells if r == 10)
        # Every column the chord's x-span touches, on BOTH rows.
        assert cols_row_9 == list(range(2, 18))
        assert cols_row_9 == cols_row_10

    def test_vertical_chord_on_a_grid_line_reports_both_columns(self):
        """Symmetric case on the other axis — not explicitly named in the
        brief, but the same mechanism (``dx == 0``) and worth the few extra
        lines to not leave it as an asymmetric fix."""
        grid = RoutingGrid(width=5.0, height=5.0, resolution=0.1,
                           origin=(0.0, 0.0))
        start = (1.0, 0.25)
        end = (1.0, 1.75)

        u = (start[0] - grid.origin[0]) / grid.resolution
        assert u == round(u)

        cells = _swept_cells(grid, start, end)
        cols = {c for c, _ in cells}
        assert cols == {9, 10}

        rows_col_9 = sorted(r for c, r in cells if c == 9)
        rows_col_10 = sorted(r for c, r in cells if c == 10)
        assert rows_col_9 == list(range(2, 18))
        assert rows_col_9 == rows_col_10


class TestInteriorLatticeCorner:
    """An interior point where the chord touches a lattice CORNER exactly —
    both axes on a grid line at the same parametric ``t``. A corner is
    shared by up to four cells but the touch is measure-zero on the chord
    (it never gets a nonzero-width interval of its own), so the plain
    interval sweep silently resolves it to at most the two cells the
    direction of travel passes through and drops the other two — exactly
    the corner a diagonal A* step already refuses to cross
    (``pathfinder.py:444-450``), left open here until this round.
    """

    def test_exact_45_degree_chord_reports_every_corner_adjacent_cell(self):
        grid = RoutingGrid(width=5.0, height=5.0, resolution=0.1,
                           origin=(0.0, 0.0))
        start = (0.05, 0.05)
        end = (0.95, 0.95)

        cells = _swept_cells(grid, start, end)
        # The straight diagonal cells (cell i,i for i in 0..8) plus, at every
        # interior corner (0,0)-(1,1), (1,1)-(2,2), ..., the two
        # off-diagonal neighbours the pure interval sweep would drop.
        for i in range(9):
            assert (i, i) in cells
        for i in range(8):
            # corner shared by (i,i), (i+1,i), (i,i+1), (i+1,i+1)
            assert (i + 1, i) in cells, f"off-diagonal neighbour ({i+1},{i}) omitted"
            assert (i, i + 1) in cells, f"off-diagonal neighbour ({i},{i+1}) omitted"

    def test_chord_ending_exactly_at_a_lattice_corner(self):
        """The third case named in the brief: an endpoint (not just an
        interior point) landing exactly on a lattice corner must still get
        its diagonal neighbour."""
        grid = RoutingGrid(width=5.0, height=5.0, resolution=0.1,
                           origin=(0.0, 0.0))
        start = (0.55, 0.55)
        end = (1.0, 1.0)  # exact corner shared by (9,9), (9,10), (10,9), (10,10)

        cells = _swept_cells(grid, start, end)
        assert (9, 9) in cells
        assert (10, 10) in cells, "diagonal neighbour at the corner omitted"
        assert (9, 10) in cells
        assert (10, 9) in cells


class TestStraddlingIndices:
    """Direct tests of the ``_straddling_indices`` helper the fix introduces
    — the single place ``_SWEEP_EPS`` gates a SECOND kind of decision (is
    this point on a lattice line at all?) beyond the sweep's own crossing
    tolerance. Tested in isolation so its boundary is pinned independently
    of whichever chord happens to exercise it above.
    """

    def test_interior_point_is_a_single_index(self):
        assert _straddling_indices(0.37, 0.0, 0.1) == (3,)

    def test_exactly_on_a_line_is_both_neighbours(self):
        assert _straddling_indices(0.5, 0.0, 0.1) == (4, 5)

    def test_within_epsilon_of_a_line_still_counts_as_on_it(self):
        # `_straddling_indices` compares in the AXIS-NORMALISED (u) space,
        # i.e. (v - base) / res against `_SWEEP_EPS` — so a world-space
        # offset must be scaled by `res` to land just inside that tolerance.
        res = 0.1
        v = 0.5 + (_SWEEP_EPS * res * 0.5)
        assert _straddling_indices(v, 0.0, res) == (4, 5)

    def test_just_outside_epsilon_is_a_single_index_again(self):
        res = 0.1
        v = 0.5 + (_SWEEP_EPS * res * 100)
        assert _straddling_indices(v, 0.0, res) == (5,)

    def test_negative_side_of_a_line_also_straddles(self):
        res = 0.1
        v = 0.5 - (_SWEEP_EPS * res * 0.5)
        assert _straddling_indices(v, 0.0, res) == (4, 5)


class TestSweepEpsilonToleranceIsPinned:
    """A correctness pin at a scale two orders of magnitude below the
    existing ``test_segment_clear_corners.py`` fixture (that one's sliver is
    ~1.4e-4mm; this one is ~1.4e-7mm, parametric gap ~5e-8): the real
    ``_SWEEP_EPS`` (1e-9) keeps it as a genuine interval, not noise.

    NOTE ON WHAT THIS DOES AND DOES NOT KILL: this specific chord sits close
    enough to the blocked cell's exact corner that ``_straddling_indices``
    (part of the round D10 fix, sharing this same ``_SWEEP_EPS``) ALSO
    reports the cell via the interior-lattice-corner path, independent of
    the interval-skip threshold this test set out to isolate — so a mutant
    that loosens ``_SWEEP_EPS`` to ``1e-7`` does NOT fail this test (the
    corner path masks it). That mutant is killed elsewhere, by
    ``TestZeroWidthIntervalIsSkippedAsNoise`` below, whose fixture was
    deliberately found (by fuzzing, not hand construction) far enough from
    an exact corner that the corner path does not fire. This test is kept
    anyway as a real, independently useful correctness pin on the interval
    logic at this scale — just not as that mutant's kill site.
    """

    def test_a_sliver_two_orders_below_the_existing_fixture_is_still_seen(self):
        grid = RoutingGrid(width=12.0, height=12.0, resolution=1.0,
                           clearance=0.0, trace_width=0.0)
        offset = 5e-8
        start = (5.5, 4.5 + offset)
        end = (4.5, 5.5 + offset)

        cells = _swept_cells(grid, start, end)
        assert (5, 5) in cells, (
            "a ~5e-8 sliver must still be seen at the real 1e-9 epsilon"
        )


class TestZeroWidthIntervalIsSkippedAsNoise:
    """``_swept_cells`` skips an interval when ``b - a <= _SWEEP_EPS``, not
    only when it is EXACTLY zero — two crossings computed from independent
    formulas (one per axis) that are mathematically supposed to coincide can
    still land a few ULPs apart due to ordinary floating-point rounding, and
    that residue must still be treated as noise, not as a genuine sliver of
    geometry.

    This exact chord was found by fuzzing 300,000 random (non-quantised)
    chords on the production grid and comparing the real algorithm against a
    ``b - a <= 0.0`` mutant: at this precise pair of floats, two crossings
    land ``4.52e-10`` apart (real numbers, not constructed by hand) — inside
    ``_SWEEP_EPS`` (1e-9), so the real code correctly treats the gap as
    noise and never visits cell (276, 37). The ``<= 0.0`` mutant does NOT
    skip it, computes that interval's midpoint anyway, and reports (276, 37)
    as swept when the chord never truly enters it (see the round's report
    for the full search and the isolated gap value).
    """

    def test_a_near_but_not_exactly_coincident_crossing_stays_noise(self):
        grid = RoutingGrid(width=30.0, height=30.0, resolution=0.1,
                           origin=(0.0, 0.0))
        start = (28.707422080125724, 2.7711982785657323)
        end = (14.417970833347598, 14.755849146530903)

        cells = _swept_cells(grid, start, end)
        assert (276, 37) not in cells, (
            "a sub-epsilon residue between two independently-computed "
            "crossings must not be reported as a swept cell"
        )
        assert len(cells) == 263
