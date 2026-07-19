"""Safety proof for the consolidated component-placement transform.

pcb_worker.geometry is now the SINGLE source of the rotate-a-local-offset math
that gerber.py, drc.py and route_bridge.py previously each carried. These tests
prove the promoted ``rotate_local_offset`` reproduces BOTH historical forms
(gerber's ``radians(-deg)`` matrix and route_bridge's hand-written
``radians(+deg)`` matrix) bit-for-bit, and that ``place_point`` matches the
independent agent_router KiCad-reader oracle. If the three ever disagreed, the
consolidation would be unsafe — this is the teeth.
"""

from __future__ import annotations

import math

import pytest

from pcb_worker.geometry import rotate_local_offset, place_point
# READ-ONLY oracle: the agent_router KiCad reader's absolute-position transform,
# derived independently from gerber/route_bridge. We match it, never modify it.
from agent_router.kicad_io import _transform_position


ANGLES = [0.0, 30.0, 37.5, 45.0, 90.0, 135.0, 180.0, -90.0, 270.0]
OFFSETS = [(1.0, 0.0), (0.0, 1.0), (2.5, -3.7), (-4.2, -1.1), (3.7, 2.1)]


def _gerber_form(px: float, py: float, deg: float) -> tuple[float, float]:
    """gerber.py's historical rotation: radians(-deg) CCW matrix."""
    if deg == 0.0:
        return px, py
    r = math.radians(-deg)
    c, s = math.cos(r), math.sin(r)
    return px * c - py * s, px * s + py * c


def _route_bridge_form(px: float, py: float, deg: float) -> tuple[float, float]:
    """route_bridge.py's historical rotation: hand-written radians(+deg) matrix."""
    if not deg:
        return px, py
    r = math.radians(deg)
    c, s = math.cos(r), math.sin(r)
    return px * c + py * s, -px * s + py * c


@pytest.mark.parametrize("deg", ANGLES)
@pytest.mark.parametrize("px,py", OFFSETS)
def test_rotate_matches_both_historical_forms(deg, px, py):
    """(a) EQUIVALENCE: the promoted rotate agrees with BOTH prior forms."""
    got = rotate_local_offset(px, py, deg)
    gerber = _gerber_form(px, py, deg)
    route = _route_bridge_form(px, py, deg)
    assert got == pytest.approx(gerber, abs=1e-12)
    assert got == pytest.approx(route, abs=1e-12)
    # And the two historical forms agree with each other (this is WHY it is safe).
    assert gerber == pytest.approx(route, abs=1e-12)


@pytest.mark.parametrize("cx,cy,deg,lx,ly", [
    (10.0, 20.0, 0.0, 1.0, 0.0),
    (50.0, 50.0, 90.0, 1.0, 0.0),
    (50.0, 50.0, 90.0, -1.0, 0.0),
    (3.0, -7.5, 37.5, 2.0, -1.0),
    (-4.0, 8.0, 180.0, 0.5, 0.5),
])
def test_place_point_matches_kicad_oracle(cx, cy, deg, lx, ly):
    """(b) ORACLE MATCH: place_point == kicad_io._transform_position."""
    got = place_point(cx, cy, deg, lx, ly)
    # _transform_position(rel_x, rel_y, fp_x, fp_y, rotation)
    oracle = _transform_position(lx, ly, cx, cy, deg)
    assert got == pytest.approx(oracle, abs=1e-9)


def test_zero_degree_identity_is_exact():
    """(c) 0-deg short-circuit returns inputs unchanged with NO float drift."""
    assert rotate_local_offset(3.7, -2.1, 0.0) == (3.7, -2.1)
