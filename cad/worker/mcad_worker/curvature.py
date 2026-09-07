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

FINDING THE FLATTEST POINT, NOT THE FLATTEST NODE
A uniform grid reports the flattest NODE, which is not the flattest point: on
an oblate spheroid the flattest point is the pole, the grid's nearest usable
node sits a whole grid step short of it, and the radius read there is well
under the pole's. So the grid pass only locates the neighbourhood; a
refinement pass then bisects the parametric cell around the widest sample,
halving its step each round, and keeps whichever of the surrounding samples is
wider. The centre walks toward the true maximum — including one sitting on a
parametric boundary, which is where a degenerate pole lives — and the residual
offset left after the last round is one grid step divided by 2**rounds.

WHY THE READING IS CORRECTED
The refinement converges on the flattest point FROM BELOW: every sample it
keeps sits some residual offset short of the maximum, and radius falls off
quadratically in that offset, so the reading is short by roughly a constant
times the square of the residual, relative. The returned radius is therefore
scaled up by (1 + 1.5*res**2), where res is the last parametric step the
refinement actually walked with.

THAT CORRECTION IS NOT A PROOF. 1.5 is the second-order coefficient for a
smooth quadratic maximum of the oblate-spheroid kind this was measured on, not
a bound over every surface OCCT can hand back: a face whose curvature turns
over more sharply than that in the last cell can still read a shade short. It
is the honest width of the search's own residual, and what it removes is the
systematic shortfall of approaching a maximum from one side — not the
possibility of a spike the grid never sampled.

THE HONEST LIMIT
The search is still a sample, not a proof: a curvature spike in a cell the
grid steps over entirely, and far from the widest node, is not seen. The grid
is therefore fine enough that a feature it steps over is smaller than the
facets the mesher would put there anyway, and the reply that carries this
number says the radius was sampled and refined rather than read.
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

#: Bisections of the parametric cell around the widest grid sample. Each round
#: costs eight evaluations, so the whole refinement is cheaper than the grid
#: that seeds it, and it leaves the reading within one grid step / 2**rounds
#: of the parametric point it converged on.
REFINEMENT_ROUNDS = 10

#: The refinement approaches the flattest point from below, so the radius it
#: stops at is short by about this much, relative, for a residual parametric
#: offset `res`: radius falls off as the square of the offset from a smooth
#: maximum. The reading is scaled up by it to remove that shortfall. The
#: coefficient is second-order for a smooth maximum (measured on an oblate
#: spheroid's pole) and is a correction, not a proven bound over every
#: surface.
RESIDUAL_SHORTFALL_FACTOR = 1.5


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
    best_uv: Optional[tuple[float, float]] = None
    for i in range(steps):
        u = u0 + (u1 - u0) * i / (steps - 1)
        for j in range(steps):
            v = v0 + (v1 - v0) * j / (steps - 1)
            radius, defined = _radius_at(props_class, adaptor, u, v, floor)
            evaluated = evaluated or defined
            if radius is not None and (widest is None or radius > widest):
                widest, best_uv = radius, (u, v)

    if best_uv is not None:
        du = (u1 - u0) / (steps - 1)
        dv = (v1 - v0) / (steps - 1)
        widest, best_uv, residual = _refine(props_class, adaptor, floor,
                                            widest, best_uv, du, dv,
                                            (u0, u1), (v0, v1))
        if widest is not None:
            widest *= 1.0 + RESIDUAL_SHORTFALL_FACTOR * residual * residual
    return widest, evaluated


def _radius_at(props_class, adaptor, u: float, v: float, floor: float
               ) -> tuple[Optional[float], bool]:
    """(the widest principal radius above `floor` here, was curvature defined).

    A radius of None with True means the sample evaluated but carries only
    curvature too slight to bind anything.
    """
    try:
        props = props_class(adaptor, u, v, 2, _PROP_RESOLUTION_MM)
        if not props.IsCurvatureDefined():
            return None, False
        principals = (abs(float(props.MaxCurvature())),
                      abs(float(props.MinCurvature())))
    except BaseException:  # noqa: BLE001 — a degenerate sample
        return None, False
    if not all(math.isfinite(value) for value in principals):
        return None, False
    widest: Optional[float] = None
    for curvature in principals:
        if curvature <= floor:
            continue
        radius = 1.0 / curvature
        if widest is None or radius > widest:
            widest = radius
    return widest, True


def _refine(props_class, adaptor, floor: float, widest: Optional[float],
            centre: tuple[float, float], du: float, dv: float,
            u_range: tuple[float, float], v_range: tuple[float, float]
            ) -> tuple[Optional[float], tuple[float, float], float]:
    """Walk the widest sample toward the flattest point around it.

    Each round samples the eight neighbours of the current centre at the
    current step and moves to the widest of them, then halves the step. The
    centre therefore travels at most 2*du (2*dv) in total, enough to cross the
    grid cell it started in and settle onto a maximum that lies on the
    parametric boundary.

    Returns the last step it actually WALKED with — not the halved one it
    never used — as the third value, in the surface's own parameter units:
    that is how far the centre could still be from the maximum, and it is
    what the caller corrects the radius by, since the walk only ever
    approaches the maximum from below.
    """
    u0, u1 = u_range
    v0, v1 = v_range
    walked = max(du, dv)
    for _ in range(REFINEMENT_ROUNDS):
        walked = max(du, dv)
        for offset_u in (-du, 0.0, du):
            for offset_v in (-dv, 0.0, dv):
                if offset_u == 0.0 and offset_v == 0.0:
                    continue
                u = min(max(centre[0] + offset_u, u0), u1)
                v = min(max(centre[1] + offset_v, v0), v1)
                radius, _ = _radius_at(props_class, adaptor, u, v, floor)
                if radius is not None and (widest is None or radius > widest):
                    widest, centre = radius, (u, v)
        du *= 0.5
        dv *= 0.5
    return widest, centre, walked


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
