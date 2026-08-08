"""Authored keepout zones steer the router (Epoch UX3 station 2 — K6).

K6's pre-epoch status read "avoid-regions are unverified; they may not exist".
The verification found something sharper: they existed as a REFUSAL —
``route_bridge._reject_unroutable_board`` raised on any board declaring a
keepout, because the engine's obstacle loops read only (position, radius) and
silently ignored ``Obstacle.polygon``. This file pins the replacement
end-to-end: the engine reads polygon obstacles, rasterises them per layer
(``RoutingGrid.mark_keepout_polygon`` — unit-tested in
``agent_router/test_grid.py``), and a route whose straight path crosses a
keepout DETOURS around it instead of drawing through or refusing.

Synthetic boards per ``testdata/POLICY.md`` — the geometry under test is
readable in this file.
"""

from __future__ import annotations

import math

from agent_router.board import Board, Net, Obstacle, Pad
from agent_router.router import route_board


# A 40x20 board with one horizontal 2-pad net at y=10, and a keepout band
# across the middle (x 15..25) spanning y 4..16. The straight path crosses it;
# the open corridors above (y < ~3.5) and below (y > ~16.5) do not.
KEEPOUT_RECT = [(15.0, 4.0), (25.0, 4.0), (25.0, 16.0), (15.0, 16.0)]


def _two_pad_board(*, keepout_layers) -> Board:
    board = Board(width=40, height=20)
    board.pads = [
        Pad("U1", "1", "SIG", (5.0, 10.0), (1.0, 1.0)),
        Pad("U2", "1", "SIG", (35.0, 10.0), (1.0, 1.0)),
    ]
    board.nets = {"SIG": Net("SIG", 1, [board.pads[0], board.pads[1]])}
    centre = (20.0, 10.0)
    if keepout_layers == "all":
        board.obstacles = [Obstacle(position=centre, type="keepout",
                                    polygon=KEEPOUT_RECT,
                                    blocks_all_layers=True)]
    else:
        board.obstacles = [Obstacle(position=centre, type="keepout",
                                    polygon=KEEPOUT_RECT,
                                    blocks_all_layers=False,
                                    layer=keepout_layers)]
    return board


def _sampled_points(route, layer: str | None = None, step: float = 0.1):
    """Every routed segment, sampled at ``step`` mm, optionally one layer."""
    for seg in route.segments:
        if layer is not None and seg.layer != layer:
            continue
        (x0, y0), (x1, y1) = seg.start, seg.end
        span = math.hypot(x1 - x0, y1 - y0)
        n = max(1, int(span / step))
        for i in range(n + 1):
            t = i / n
            yield (x0 + (x1 - x0) * t, y0 + (y1 - y0) * t)


def _inside_rect(p, rect=KEEPOUT_RECT) -> bool:
    xs = [q[0] for q in rect]
    ys = [q[1] for q in rect]
    return min(xs) < p[0] < max(xs) and min(ys) < p[1] < max(ys)


def test_route_detours_around_an_all_layer_keepout():
    """The K6 acceptance itself: crossing straight path -> detour, not refusal,
    not copper through the forbidden region on ANY layer."""
    board = _two_pad_board(keepout_layers="all")
    result = route_board(board, trace_width=0.25, clearance=0.2,
                         grid_resolution=0.1)
    sig = [r for r in result.routes if r.net == "SIG"]
    assert sig, (
        "the board must still ROUTE — an all-layer keepout with open corridors "
        "above and below is a detour, never a refusal")
    for p in _sampled_points(sig[0]):
        assert not _inside_rect(p), (
            f"routed copper at {p} is inside the keepout the author forbade")


def test_top_only_keepout_frees_the_bottom_layer():
    """Layer fidelity — the exact thing the old disc approximation could not
    offer: a top-only keepout must not block B.Cu, so F.Cu copper stays out of
    the region while the route is still free to cross underneath."""
    board = _two_pad_board(keepout_layers="F.Cu")
    result = route_board(board, trace_width=0.25, clearance=0.2,
                         grid_resolution=0.1)
    sig = [r for r in result.routes if r.net == "SIG"]
    assert sig, "a top-only keepout leaves B.Cu fully open; the net must route"
    for p in _sampled_points(sig[0], layer="F.Cu"):
        assert not _inside_rect(p), (
            f"F.Cu copper at {p} is inside a keepout authored on the top layer")


def test_radius_and_polygon_obstacles_coexist():
    """The disc loop's behaviour is untouched: a board carrying BOTH obstacle
    shapes marks both (the elif ordering must not shadow either)."""
    board = _two_pad_board(keepout_layers="all")
    board.obstacles.append(Obstacle(position=(30.0, 10.0), type="mounting_hole",
                                    radius=1.0))
    result = route_board(board, trace_width=0.25, clearance=0.2,
                         grid_resolution=0.1)
    sig = [r for r in result.routes if r.net == "SIG"]
    assert sig, "hole + keepout together still leave a routable corridor"
    hole_block = 1.0 + 0.2 + 0.125  # radius + keepout_margin
    for p in _sampled_points(sig[0]):
        assert not _inside_rect(p)
        assert math.hypot(p[0] - 30.0, p[1] - 10.0) > hole_block - 0.15, (
            f"routed copper at {p} crosses the mounting hole — the polygon "
            f"branch must not have swallowed the disc branch")
