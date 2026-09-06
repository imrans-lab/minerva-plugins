"""Sampling a B-Rep edge into a polyline a consumer can draw.

Split from the translator because it is geometry sampling, not DSL
translation, and the translator is long enough already.
"""

from __future__ import annotations

from typing import Any

# Chord deflection, in millimetres, used to sample a curved edge into the
# polyline every registry entry carries. Finer than the default tessellation
# tolerance (0.1 mm) so an outline drawn from these points never reads coarser
# than the shaded surface beside it.
EDGE_POLYLINE_DEFLECTION = 0.05

try:  # OCCT's own deflection sampler; absent only from a stripped install.
    from OCP.BRepAdaptor import BRepAdaptor_Curve as _BRepAdaptor_Curve
    from OCP.GCPnts import GCPnts_QuasiUniformDeflection as _QuasiUniformDeflection
except Exception:  # pragma: no cover - exercised only without OCP
    _BRepAdaptor_Curve = None
    _QuasiUniformDeflection = None


def edge_polyline(
    edge: Any, deflection: float = EDGE_POLYLINE_DEFLECTION
) -> list[list[float]]:
    """Sample *edge* into an ordered chord polyline, first point to last.

    Straight edges come back as their two ends; a circle, spline or boolean
    intersection curve comes back as enough points that no chord strays
    further than *deflection* from the true curve. This is what lets a
    consumer draw the edge itself instead of guessing it from a triangle
    mesh, which is where sliver triangles at a boolean seam turn into
    speckles.

    Falls back to the two endpoints when OCCT's sampler is unavailable or
    refuses the curve: a straight-line stand-in is wrong only for a curve,
    and is never worse than the endpoints already stored beside it.
    """
    ends: list[list[float]] = []
    try:
        start = edge.start_point()
        finish = edge.end_point()
        ends = [
            [float(start.X), float(start.Y), float(start.Z)],
            [float(finish.X), float(finish.Y), float(finish.Z)],
        ]
    except Exception:
        ends = []

    if _QuasiUniformDeflection is None or _BRepAdaptor_Curve is None:
        return ends

    try:
        sampler = _QuasiUniformDeflection(
            _BRepAdaptor_Curve(edge.wrapped), float(deflection)
        )
        if not sampler.IsDone() or sampler.NbPoints() < 2:
            return ends
        points: list[list[float]] = []
        for index in range(1, sampler.NbPoints() + 1):
            point = sampler.Value(index)
            points.append([float(point.X()), float(point.Y()), float(point.Z())])
        return points
    except Exception:
        return ends
