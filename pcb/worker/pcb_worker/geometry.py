"""Canonical component-placement geometry for the PCB worker.

Single source of truth for the KiCad footprint-placement transform: rotate a
component-LOCAL offset by the placement angle, and translate it to the
component's board position. gerber.py, drc.py and route_bridge.py all delegate
here so there is exactly ONE rotation implementation in pcb_worker (DRY), and
no path can silently drift to a different sign.

Rotation convention (pinned by tests/test_rotation.py against a real
KiCad-authored fixture):

    KiCad applies a footprint ``(at x y rot)`` angle CLOCKWISE in the file's
    coordinate frame (Y grows downward) — i.e. negate the angle before applying
    the standard CCW rotation matrix (``math.radians(-deg)``). This is the exact
    convention the agent_router KiCad reader encodes
    (``kicad_io._transform_position`` uses ``radians(-rotation)``), which is the
    ground truth. The previous ``+deg`` (CCW) form flashed pads MIRRORED about
    the component centre versus KiCad, so a connector authored at rotation 90
    landed off its routed trace endpoints (docket 019f3ba0f455).

    0 deg is rotation-invariant and short-circuits (returns the inputs
    unchanged, exactly — no float drift), so the rotation_deg=0 gerber goldens
    are unaffected by the sign fix.

    (Boards authored in the pcb-architect dialect use the OPPOSITE sign for their
    ``rotation`` field; reconciling that is an IMPORT-layer concern — negate at
    import — not this worker's, whose rotation_deg is defined as KiCad-equivalent.)

Equivalence note (why consolidating three call sites is safe): route_bridge's
former hand-written ``radians(+deg)`` matrix ``(px·cos d + py·sin d,
−px·sin d + py·cos d)`` is algebraically IDENTICAL to the ``radians(-deg)`` form
here — expand ``cos(-d)=cos d`` and ``sin(-d)=−sin d`` and both collapse to the
same closed form. tests/test_geometry.py proves this across many angles.
"""

from __future__ import annotations

import math
from typing import Any


def is_top(layer: Any) -> bool:
    """A component/trace is on the top side unless it explicitly says bottom."""
    if isinstance(layer, str):
        return layer.strip().lower() not in ("bottom", "b.cu", "back")
    return True


def rotate_local_offset(px: float, py: float, deg: float) -> tuple[float, float]:
    """Rotate a component-LOCAL pad offset by *deg* using KiCad's footprint-angle
    convention, so the resulting flash lands on KiCad's own absolute pad position.

    See the module docstring for the full clockwise-convention rationale (KiCad
    negates the angle; pinned by tests/test_rotation.py; docket 019f3ba0f455).

    0 deg is rotation-invariant and short-circuits, returning the inputs
    unchanged (exact, no float drift).
    """
    if deg == 0.0:
        return px, py
    r = math.radians(-deg)
    c, s = math.cos(r), math.sin(r)
    return px * c - py * s, px * s + py * c


def place_point(cx: float, cy: float, deg: float,
                lx: float, ly: float) -> tuple[float, float]:
    """Rotate a component-LOCAL point (lx, ly) by *deg* (via ``rotate_local_offset``)
    and translate by the component's board placement (cx, cy) — the exact pad
    convention KiCad's reader (kicad_io._transform_position) applies."""
    ox, oy = rotate_local_offset(lx, ly, deg)
    return cx + ox, cy + oy
