"""Curvature of a face whose surface has no analytic radius to read.

WHY THIS EXISTS
`features.curvature_report` reads a radius straight off a cylinder, a sphere,
a cone or a torus. A loft, a sweep or a filleted blend is none of those: OCCT
hands back a B-spline (or a Bezier, a revolution, an extrusion, an offset)
whose "radius" is not a field on the surface. Refusing to measure those made
every clearance answer on a lofted shell advisory-only, because a tessellation
bound derived from the analytic faces alone says nothing about the ones the
reader skipped.

WHAT IT MEASURES
The surface's own curvature, sampled on a parametric grid: at each sample OCCT
evaluates the two principal curvatures, and each of those is a radius the
tessellation machinery already knows how to hold. The one it reports is the
WIDEST of them, for the same reason the analytic reader reports the widest
face: a chord stepped at a fixed angle sits r*(1 - cos(theta/2)) inside the
surface, and that grows with r, so the flattest curvature on the face is the
one the angle has to hold. A face flat everywhere — the ruled flank of a loft
between two polygons is exactly this — reports nothing and binds nothing,
exactly like a plane.

WHY A SAMPLED READING IS STILL A BOUND
A chord across a face can be no longer than the face itself, so however the
face is tessellated, a point of curvature k deviates from its chords by at
most k * L^2 / 8, where L is the face's own extent. A curvature that cannot
break the tolerance by that measure is dropped rather than allowed to drag the
mesh finer — which is what keeps the nearly-flat corner of a spline patch,
where the reported radius runs to kilometres and is mostly the evaluator's own
noise, from asking for a mesh nobody can hold. What survives is curvature that
could really break the tolerance, reported at its measured radius.

THE HONEST LIMIT
The grid is a sample, not a proof: a curvature spike between two samples is not
seen. The grid is therefore fine enough that a feature it steps over is
smaller than the facets the mesher would put there anyway, and the reply that
carries this number says the radius was sampled rather than read.
"""

from __future__ import annotations

import math
from typing import Optional

#: Samples per parametric direction. 11x11 = 121 evaluations per face: cheap
#: beside the tessellation that follows, and fine enough that a feature it
#: steps over is smaller than the facets the mesher would put there anyway.
SAMPLES_PER_DIRECTION = 11

#: Curvatures below this (radius above ten kilometres, on a part measured in
#: millimetres) are the evaluator's own noise on a flat patch, not curvature.
#: It only decides anything when no tolerance is given; with one, the extent
#: test below throws away far more than this does.
FLAT_CURVATURE_PER_MM = 1.0e-7

#: Parametric resolution handed to the curvature evaluator, millimetres.
_PROP_RESOLUTION_MM = 1.0e-7


def binding_radius(occt: dict, face, tolerance_mm: Optional[float]
                   ) -> tuple[Optional[float], bool]:
    """(the radius this face binds a tessellation at, whether it was read).

    The radius is None when the face binds nothing: it is flat, or every
    curvature on it is too slight, across the face's own extent, to deviate by
    `tolerance_mm` however the face is cut. The second value is False only
    when the face could not be evaluated at all — OCCT would not adapt it, or
    not one sample on it had a defined curvature — which is the one case a
    caller still has to report as unmeasured.

    `tolerance_mm` of None keeps every measurable curvature, which is what a
    caller asking what the shape's curvature IS, rather than which mesh to cut
    for it, wants.
    """
    try:
        adaptor = occt["BRepAdaptor_Surface"](face)
        u0, u1, v0, v1 = occt["BRepTools"].UVBounds_s(face)
    except BaseException:  # noqa: BLE001 — a face OCCT will not adapt
        return None, False
    if not all(math.isfinite(value) for value in (u0, u1, v0, v1)):
        return None, False

    extent = _extent(occt, face)
    # The tightest curvature that could still break the tolerance across the
    # face's own extent. Anything slighter deviates less than that whatever
    # the angular step, so it is not allowed to choose one.
    floor = FLAT_CURVATURE_PER_MM
    if tolerance_mm is not None and extent:
        floor = max(floor, 8.0 * tolerance_mm / (extent * extent))

    props_class = occt["BRepLProp_SLProps"]
    steps = SAMPLES_PER_DIRECTION
    evaluated = False
    widest: Optional[float] = None
    for i in range(steps):
        u = u0 + (u1 - u0) * i / (steps - 1)
        for j in range(steps):
            v = v0 + (v1 - v0) * j / (steps - 1)
            try:
                props = props_class(adaptor, u, v, 2, _PROP_RESOLUTION_MM)
                if not props.IsCurvatureDefined():
                    continue
                principals = (abs(float(props.MaxCurvature())),
                              abs(float(props.MinCurvature())))
            except BaseException:  # noqa: BLE001 — a degenerate sample
                continue
            if not all(math.isfinite(value) for value in principals):
                continue
            evaluated = True
            for curvature in principals:
                if curvature <= floor:
                    continue
                radius = 1.0 / curvature
                if widest is None or radius > widest:
                    widest = radius
    return widest, evaluated


def _extent(occt: dict, face) -> Optional[float]:
    """The diagonal of the face's bounding box, millimetres."""
    try:
        box = occt["Bnd_Box"]()
        occt["BRepBndLib"].Add_s(face, box, True)
        if box.IsVoid():
            return None
        x0, y0, z0, x1, y1, z1 = box.Get()
    except BaseException:  # noqa: BLE001 — a face with no computable box
        return None
    span = (x1 - x0, y1 - y0, z1 - z0)
    if not all(math.isfinite(value) for value in span):
        return None
    return math.sqrt(sum(value * value for value in span))
