"""Cylindrical features of the evaluated solid, read off the B-Rep itself.

WHAT THIS ANSWERS
"Where are the screw bosses in the thing I just modelled, and how big are
they?" The panel already fits cylinders to FOREIGN meshes (mesh_features.gd):
it has to, because a reference arrives as a triangle soup and nothing else is
left of the CAD kernel that made it. The evaluated solid is not in that
position. It is an OCCT B-Rep here in the worker, and a bore's axis, radius and
axial extent are stored on it exactly — as a Geom_CylindricalSurface, not as
chords. Fitting the solid's own tessellation would throw that away and hand
back a circumscribed radius and an axis carrying the tessellation's chordal
error, which is the wrong side of the tolerance a fastener check is graded at.

So this method exports what the kernel knows. The panel's fitter stays as the
NAMED FALLBACK for a bore the kernel has no cylindrical face for, and every
reply that uses it says so.

WHAT A CYLINDER IS HERE
One cylindrical surface, not one face. OCCT routinely splits a full bore into
two half-faces at the seam, and a boss cut by a pocket into several patches, so
faces that share an axis line, a radius and an overlapping stretch of that line
are merged into one feature. `closed` is then the honest word for "this goes
all the way round"; a 180-degree sweep is a fillet or a slot end, not a hole.

THE EXTENT COMES FROM THE FACE'S OWN BOUNDARY, NOT ITS UV BOX
`BRepTools.UVBounds_s` is a parametric BOUNDING BOX. For a bore cut off by a
tilted plane the trim curve sweeps between two different heights, and the box
reports the deeper one all the way round: the length comes out longer than any
part of the bore actually is, and a fastener graded on it engages a boss that
is not there. So the boundary edges are sampled in 3D and each sample is
projected onto the axis (its axial coordinate) and around it (its angle). The
extent is the range of those axial coordinates, which is the real trim.

The sweep is measured the same way and for the same reason: as the fraction of
angular BINS the boundary samples actually occupy, unioned across the faces of
one surface. Summing per-face parametric spans would call two half-turn fillet
patches that happen to share an axis line a closed hole; a union of occupied
bins cannot, because it counts each part of the turn once.

CONCAVE OR CONVEX, FROM THE ORIENTATION AND NOTHING ELSE
A cylindrical surface's natural normal points AWAY from its axis when the
surface's own coordinate system is direct. A face of a solid carries the
outward normal of the material, which is the natural normal when the face is
FORWARD and its opposite when REVERSED. So material inside the cylinder (a
pin, a boss's outer wall) is a FORWARD face of a direct surface, and material
outside it (a bore, a hole) is a REVERSED one. Both flips are applied, because
an indirect axis system reverses the natural normal on its own and reading
only the face orientation would call every bore a boss.

EVERY LENGTH IS A MILLIMETRE, in the solid's own frame — which is also the
panel's world frame, because the evaluated solid is never posed.
"""

from __future__ import annotations

import math
from typing import Optional

#: Two faces belong to the same cylinder when their radii agree to within this
#: and their axis lines coincide to within it. A B-Rep's own faces of one
#: surface agree to kernel precision; the tolerance exists so that a bore
#: rebuilt by a boolean still merges with its other half.
MERGE_TOLERANCE_MM = 1.0e-6

#: Axis directions this close to parallel are the same axis. cos(0.01 deg).
MERGE_PARALLEL_DOT = 1.0 - 1.0e-8

#: Angular bins the turn is divided into when measuring how much of it a face's
#: boundary covers. 72 bins is 5 degrees, fine enough that a quarter-turn
#: fillet and a full bore cannot be confused and coarse enough that a sampled
#: boundary fills every bin it crosses.
ANGULAR_BINS = 72

#: The width of one bin, degrees. Reported on every cylinder as `bin_deg`,
#: because it is the resolution of every angular number in the row and a
#: consumer must derive its own thresholds from it rather than hard-code one.
BIN_DEG = 360.0 / ANGULAR_BINS

#: Slack on a full turn, degrees — smaller than any real gap, large enough to
#: absorb float formatting.
SWEEP_EPSILON_DEG = 0.01

#: THE CLOSED RULE, and it is stated in exactly one place. A cylindrical
#: surface is closed — a hole or a full boss rather than a fillet, a slot end
#: or a rounded corner — when its measured sweep is within ONE BIN of a full
#: turn. The sweep is a count of occupied bins, so a seam that leaves a single
#: bin empty reports 360 - BIN_DEG and is still a bore; anything shorter is
#: not. A consumer applying this rule for itself must derive it from the
#: reported bin_deg, which is why bin_deg travels on every row.
CLOSED_SWEEP_MIN_DEG = 360.0 - BIN_DEG - SWEEP_EPSILON_DEG

#: How far the sampled polyline of a boundary edge may sit from the edge
#: itself, millimetres. The kernel's own deflection sampler puts the points
#: where the curve needs them, so a spike between two samples cannot exceed
#: this — which is what lets the reported extent carry a bound that is
#: conservative BY CONSTRUCTION rather than by hoping the trim is smooth.
EDGE_DEFLECTION_MM = 0.01

#: Samples taken along a boundary edge when the deflection sampler is not
#: available (an OCCT build without GCPnts, or a curve it refuses). A fixed
#: count says nothing about what happens between two samples, so a face
#: sampled this way is reported as NOT deflection-bounded and every consumer
#: of its extent is told the number is unbounded. It has to be at least twice
#: ANGULAR_BINS so that a full circle leaves no bin empty between two samples;
#: 145 puts a sample every 2.5 degrees of a full turn.
EDGE_SAMPLES = 145

#: Two boundary samples closer together than this, measured around the axis,
#: are treated as one place: the ratio that would come out of them is a
#: division by noise, not a slope.
SLOPE_MIN_TRAVEL_MM = 1.0e-6

#: Two faces of one surface must also overlap along the axis to be the same
#: feature — adjacent patches touch, and this lets them. Two bores on one
#: infinite line with a gap between them are two features.
MERGE_AXIAL_SLACK_MM = 1.0e-6


class FeatureError(Exception):
    """A feature request that cannot be answered, with a reason for the user."""


def _occt():
    """Import the OCCT topology surface, or raise with a reason.

    Imported at call time, exactly like clearance's fcl: a worker that never
    asks for features never pays for the import, and a broken build says what
    is broken instead of raising a bare ImportError from three frames down.
    """
    try:
        from OCP.BRepAdaptor import BRepAdaptor_Curve, BRepAdaptor_Surface
        from OCP.BRepGProp import BRepGProp
        from OCP.BRepTools import BRepTools
        from OCP.GCPnts import GCPnts_QuasiUniformDeflection
        from OCP.GProp import GProp_GProps
        from OCP.GeomAbs import GeomAbs_Cylinder
        from OCP.TopAbs import TopAbs_EDGE, TopAbs_FACE, TopAbs_REVERSED
        from OCP.TopExp import TopExp_Explorer
        from OCP.TopoDS import TopoDS
    except BaseException as exc:  # noqa: BLE001 — a broken .so raises anything
        raise FeatureError(
            "reading B-Rep features needs the OCCT bindings (OCP), which this "
            "runtime bundle could not load: %s" % exc
        ) from exc
    return {
        "BRepAdaptor_Curve": BRepAdaptor_Curve,
        "BRepAdaptor_Surface": BRepAdaptor_Surface,
        "BRepGProp": BRepGProp,
        "BRepTools": BRepTools,
        "GCPnts_QuasiUniformDeflection": GCPnts_QuasiUniformDeflection,
        "GProp_GProps": GProp_GProps,
        "GeomAbs_Cylinder": GeomAbs_Cylinder,
        "TopAbs_EDGE": TopAbs_EDGE,
        "TopAbs_FACE": TopAbs_FACE,
        "TopAbs_REVERSED": TopAbs_REVERSED,
        "TopExp_Explorer": TopExp_Explorer,
        "TopoDS": TopoDS,
    }


def _shape_for(source: str):
    """Translate the DSL and hand back (shape_name, shape).

    Deliberately not `evaluate_source`: that one returns a tessellation and
    throws the shape away, and the shape is the entire point of this method.
    """
    try:
        from mcad.parser import ParseError, parse
        from mcad.translator import Translator, TranslatorError
    except ImportError as exc:
        raise FeatureError(f"mcad package unavailable: {exc}") from exc

    try:
        program = parse(source)
        translator = Translator()
        translator.translate(program)
    except (ParseError, TranslatorError) as exc:
        raise FeatureError(f"the DSL did not evaluate: {exc}") from exc

    shape_name, shape = translator.last_part()
    if shape_name is None or shape is None:
        raise FeatureError(
            "the document produced no 3D part, so it has no B-Rep features; "
            "define a shape with extrude(...) or a primitive first"
        )
    wrapped = getattr(shape, "wrapped", shape)
    if wrapped is None:
        raise FeatureError("the evaluated part carries no OCCT shape")
    return str(shape_name), wrapped


def _face_cylinder(occt: dict, face) -> Optional[dict]:
    """One cylindrical face as a raw record, or None for any other surface."""
    surface = occt["BRepAdaptor_Surface"](face)
    if surface.GetType() != occt["GeomAbs_Cylinder"]:
        return None

    cylinder = surface.Cylinder()
    axis = cylinder.Axis()
    location = axis.Location()
    direction = axis.Direction()
    origin = (location.X(), location.Y(), location.Z())
    axis_dir = (direction.X(), direction.Y(), direction.Z())

    # The parametric box, kept ONLY as the fallback for a face whose boundary
    # cannot be sampled. It is a bounding box, not the trim: see the header.
    u_min, u_max, v_min, v_max = occt["BRepTools"].UVBounds_s(face)
    boundary, boundary_bounded, boundary_complete = _boundary_points(occt, face)

    # Direct surface: natural normal away from the axis. Indirect: toward it.
    direct = True
    try:
        direct = bool(cylinder.Position().Direct())
    except AttributeError:
        pass
    reversed_face = face.Orientation() == occt["TopAbs_REVERSED"]
    outward_from_axis = direct != reversed_face
    sense = "convex" if outward_from_axis else "concave"

    props = occt["GProp_GProps"]()
    occt["BRepGProp"].SurfaceProperties_s(face, props)

    return {
        "origin": origin,
        "direction": axis_dir,
        "radius": float(cylinder.Radius()),
        "v_min": float(v_min),
        "v_max": float(v_max),
        "sweep": abs(float(u_max) - float(u_min)),
        # Flat, for the bins; per edge, for the rate the trim changes at.
        "points": [point for edge in boundary for point in edge],
        "edges": boundary,
        # True while every edge was sampled by deflection, so the polyline is
        # within EDGE_DEFLECTION_MM of the real trim everywhere.
        "deflection_bounded": boundary_bounded,
        "deflection_mm": EDGE_DEFLECTION_MM if boundary_bounded else None,
        # False when some edge of this trim could not be read at all: the
        # boundary that remains is not the whole one, so no extent taken from
        # it may call itself exact.
        "boundary_complete": boundary_complete,
        "sense": sense,
        "area": float(props.Mass()),
    }


def _boundary_points(occt: dict, face) -> list:
    """Sample every boundary edge of `face` in 3D: (edges, bounded, complete).

    These points ARE the trim: where they reach along the axis is how long the
    face is, and which way round they go is how far it sweeps. A face whose
    edges cannot be adapted (a degenerate seam, a curve with no 3D
    representation) contributes none, and the caller falls back to the
    parametric box for that face and says so.

    The edges are kept apart because CONSECUTIVE SAMPLES OF ONE EDGE are the
    only pairs that are actually adjacent on the boundary. Two ends of two
    different edges can sit at the same azimuth and 4 mm apart along the axis
    — a rate read across that pair is not a slope, it is a seam.
    """
    edges: list = []
    bounded = True
    complete = True
    explorer = occt["TopExp_Explorer"](face, occt["TopAbs_EDGE"])
    while explorer.More():
        edge = occt["TopoDS"].Edge_s(explorer.Current())
        explorer.Next()
        try:
            curve = occt["BRepAdaptor_Curve"](edge)
            first = float(curve.FirstParameter())
            last = float(curve.LastParameter())
        except BaseException:  # noqa: BLE001 — a degenerate edge raises anything
            # A rim of this trim could not be read AT ALL. What is left is a
            # PARTIAL boundary, and an extent measured from it is understated
            # by however much that rim would have added — so the face is
            # neither exact nor bounded, however well its other edges went.
            complete = False
            bounded = False
            continue
        if not (last > first):
            complete = False
            bounded = False
            continue
        samples = _deflection_samples(occt, curve)
        if samples is None:
            # This edge was walked at a fixed pitch, so nothing bounds what it
            # does between two of those points. The FACE is then unbounded,
            # whatever its other edges managed.
            bounded = False
            samples = _uniform_samples(curve, first, last)
        if samples:
            edges.append(samples)
        else:
            complete = False
            bounded = False
    return edges, bounded, complete


def _deflection_samples(occt: dict, curve):
    """Points along `curve` no further than EDGE_DEFLECTION_MM from it.

    GCPnts_QuasiUniformDeflection places points where the curvature asks for
    them: the polyline through them lies within the stated deflection of the
    real curve everywhere, INCLUDING between two points. That is the only
    sampling that lets a bound on the extent be honest about a spike nobody
    happened to land on. Returns None when the sampler is unavailable or
    refuses the curve, and the caller falls back and says so.
    """
    factory = occt.get("GCPnts_QuasiUniformDeflection")
    if factory is None:
        return None
    try:
        sampler = factory(curve, EDGE_DEFLECTION_MM)
        if not sampler.IsDone():
            return None
        count = int(sampler.NbPoints())
    except BaseException:  # noqa: BLE001 — a curve it cannot adapt raises
        return None
    if count < 2:
        return None
    points = []
    for index in range(1, count + 1):
        try:
            point = sampler.Value(index)
        except BaseException:  # noqa: BLE001
            return None
        points.append((point.X(), point.Y(), point.Z()))
    return points


def _uniform_samples(curve, first: float, last: float):
    """The fallback walk: EDGE_SAMPLES points at a fixed parametric pitch."""
    span = last - first
    points = []
    for i in range(EDGE_SAMPLES):
        parameter = first + span * (i / float(EDGE_SAMPLES - 1))
        try:
            point = curve.Value(parameter)
        except BaseException:  # noqa: BLE001
            break
        points.append((point.X(), point.Y(), point.Z()))
    return points


def _widest_deflection(held, extra):
    """The worse of two sampling bounds; None (unbounded) beats any number."""
    if held is None or extra is None:
        return None
    return max(held, extra)


def _steepest(edges: list, origin, direction) -> float:
    """The steepest rise per unit of travel around the axis, over all edges.

    Read between CONSECUTIVE SAMPLES OF ONE EDGE: |change along the axis| over
    the distance travelled perpendicular to it. A pair that barely moves
    around the axis (an edge running straight down the wall, or two samples on
    top of each other) says nothing about how fast the trim turns and is
    skipped.
    """
    steepest = 0.0
    for edge in edges:
        previous = None
        for point in edge:
            offset = _sub(point, origin)
            axial = _dot(offset, direction)
            radial = _sub(offset, tuple(c * axial for c in direction))
            if previous is not None:
                step = _sub(radial, previous[1])
                travel = math.sqrt(_dot(step, step))
                if travel > SLOPE_MIN_TRAVEL_MM:
                    steepest = max(steepest,
                                   abs(axial - previous[0]) / travel)
            previous = (axial, radial)
    return steepest


def _project(points: list, origin, direction, edges: list = None) -> tuple:
    """(axial min, axial max, per-bin axial spans, steepest slope) of `points`.

    The angular frame is derived from the DIRECTION alone — a reference vector
    chosen the same way for every caller — so two faces of one surface land in
    one frame and their bins can be unioned rather than added.

    The bins carry each azimuth's OWN axial span, not merely the fact that it
    is occupied. A trim that is not perpendicular to the axis reaches further
    at one azimuth than at another, and the length a screw can engage over is
    the stretch that is there at EVERY azimuth — a number the global min and
    max cannot express, because those two extrema happen at different
    azimuths.

    The fourth value is the steepest RISE PER UNIT OF TRAVEL the boundary
    shows between two consecutive samples — |d(axial)| over the distance
    travelled around the axis. It is what says how much height the trim can
    hide between two samples, and therefore inside one bin, which no amount of
    binning can otherwise see.
    """
    reference = _perpendicular(direction)
    other = _cross(direction, reference)
    low = None
    high = None
    bins: dict = {}
    # Rates are read WITHIN one edge only; `edges` is the same boundary the
    # flat `points` list carries, kept in its own curves.
    slope = _steepest(edges or [], origin, direction)
    for point in points:
        axial = _dot(_sub(point, origin), direction)
        low = axial if low is None else min(low, axial)
        high = axial if high is None else max(high, axial)
    if edges:
        # SEGMENTS, not points. The kernel's sampler places points where the
        # CURVATURE needs them, which on a small bore is every dozen degrees —
        # a 1.2 mm rim sampled to 0.01 mm of deflection lands about 24 points
        # on a full turn. Binning those points alone leaves two bins in three
        # empty and reports a drilled hole as a partial cylinder. Each segment
        # between two samples is therefore walked across every bin its azimuth
        # crosses, with its height interpolated along the way.
        for edge in edges:
            previous = None
            for point in edge:
                current = _measure(point, origin, direction, reference, other)
                if previous is not None:
                    _bin_segment(bins, previous, current)
                previous = current
    else:
        for point in points:
            _bin_at(bins, *_measure(point, origin, direction, reference, other))
    return low, high, bins, slope


def _measure(point, origin, direction, reference, other) -> tuple:
    """(axial, azimuth) of one boundary point in the axis frame."""
    offset = _sub(point, origin)
    axial = _dot(offset, direction)
    radial = _sub(offset, tuple(c * axial for c in direction))
    return axial, math.atan2(_dot(radial, other), _dot(radial, reference))


def _bin_at(bins: dict, axial: float, angle: float) -> None:
    """Widen the bin `angle` falls in to include `axial`."""
    index = int((angle % (2.0 * math.pi)) / (2.0 * math.pi) * ANGULAR_BINS) \
        % ANGULAR_BINS
    span = bins.get(index)
    if span is None:
        bins[index] = [axial, axial]
    else:
        span[0] = min(span[0], axial)
        span[1] = max(span[1], axial)


def _bin_segment(bins: dict, start: tuple, end: tuple) -> None:
    """Bin every bin the straight run from `start` to `end` passes through.

    The segment is walked at half a bin at a time, so no bin it crosses can be
    stepped over, and its height is interpolated linearly along the way — the
    boundary between two samples of a deflection-sampled edge is a chord, and
    a chord is exactly linear.
    """
    axial_from, angle_from = start
    axial_to, angle_to = end
    turn = 2.0 * math.pi
    # The short way round: two consecutive samples of one edge never take the
    # long way, and the wrap at +/-pi would otherwise paint the whole turn.
    delta = (angle_to - angle_from + math.pi) % turn - math.pi
    bin_angle = turn / ANGULAR_BINS
    steps = max(1, int(math.ceil(abs(delta) / (bin_angle * 0.5))))
    for index in range(steps + 1):
        fraction = index / float(steps)
        _bin_at(bins,
                axial_from + (axial_to - axial_from) * fraction,
                angle_from + delta * fraction)


def _union_bins(into: dict, extra: dict) -> dict:
    """Merge per-bin axial spans, widening a bin both faces reach into."""
    for index, span in extra.items():
        held = into.get(index)
        if held is None:
            into[index] = [span[0], span[1]]
        else:
            held[0] = min(held[0], span[0])
            held[1] = max(held[1], span[1])
    return into


def _full_turn_bound(bins: dict, radius: float, slope: float,
                     deflection) -> dict:
    """How far the binned full-turn extent may be from the true one, in mm.

    TWO ERRORS, AND BOTH ENDS PAY THEM. The extent is read per angular BIN, so
    the true boundary between two bins — and between two samples inside one
    bin — is not seen:

      step  the largest change between NEIGHBOURING occupied bins. The trim is
            continuous, so what it does across one bin is on the order of what
            it does between two.
      hidden  one bin's arc length times the steepest rise per unit of travel
            the boundary actually showed. This is what bounds a sharp trim
            that turns inside a single bin, which no difference between bin
            values can see.
      sampling  the deflection the boundary was sampled at. The kernel's
            sampler guarantees the polyline lies within it of the real curve
            EVERYWHERE, so a spike that no sample landed on is still inside
            this. Without it — a face the sampler refused — nothing bounds
            what happens between two samples, `bounded` is false, and the
            number is a floor rather than a bound.

    The full-turn extent is max(bin lows) .. min(bin highs): the start can be
    UNDER-stated by one such error and the end OVER-stated by another, so
    extent itself can be too long by twice their sum. That doubled figure is
    the bound, so a consumer subtracting it is conservative in the only
    direction that matters — a screw is never credited with engagement it may
    not have.

    Returns {mm, step_mm, hidden_mm, sampling_mm, bin_arc_mm, bounded}; a
    perpendicular trim measures zero for step and slope, and is left with the
    sampling deflection alone.
    """
    step = 0.0
    if len(bins) >= 2:
        order = sorted(bins)
        for index, key in enumerate(order):
            nxt = bins[order[(index + 1) % len(order)]]
            cur = bins[key]
            step = max(step, abs(nxt[0] - cur[0]), abs(nxt[1] - cur[1]))
    bin_arc = 2.0 * math.pi * abs(radius) / ANGULAR_BINS
    hidden = bin_arc * max(0.0, slope)
    sampling = float(deflection) if deflection is not None else 0.0
    return {
        "mm": 2.0 * (step + hidden + sampling),
        "step_mm": step,
        "hidden_mm": hidden,
        "sampling_mm": sampling,
        "bin_arc_mm": bin_arc,
        "bounded": deflection is not None,
    }


def _full_turn_extent(bins: dict) -> tuple:
    """(start, end) of the stretch present at EVERY OCCUPIED azimuth.

    For a closed bore that is the full circumference, which is what a screw
    engages over. For a partial surface — half a fillet — it is the stretch
    common to the part of the turn the surface actually occupies, and the
    caller has `sweep_deg` to tell the two cases apart.

    Empty (0.0, 0.0) when no such stretch exists — a trim steep enough that
    the highest point of one side is below the lowest point of the other has
    no length that goes all the way round.
    """
    if not bins:
        return 0.0, 0.0
    start = max(span[0] for span in bins.values())
    end = min(span[1] for span in bins.values())
    if end <= start:
        return 0.0, 0.0
    return start, end


def _perpendicular(direction):
    """Any unit vector perpendicular to `direction`, chosen deterministically."""
    axis = (1.0, 0.0, 0.0) if abs(direction[0]) < 0.9 else (0.0, 1.0, 0.0)
    vector = _cross(direction, axis)
    length = math.sqrt(_dot(vector, vector))
    return tuple(c / length for c in vector)


def _cross(a, b):
    return (
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    )


def _dot(a, b) -> float:
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def _sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def _add_scaled(a, b, k: float):
    return (a[0] + b[0] * k, a[1] + b[1] * k, a[2] + b[2] * k)


def _on_same_line(group: dict, face: dict) -> bool:
    """Do this face and this group lie on the same infinite cylinder?

    Radius, sense, axis DIRECTION (either way round — a seam half can carry the
    opposite one) and the perpendicular distance between the two axis lines.
    Says nothing about WHERE along that line either of them is; `_merge` adds
    that, because two bores on one line with a gap between them are two
    features and not one long one.
    """
    if abs(group["radius"] - face["radius"]) > MERGE_TOLERANCE_MM:
        return False
    if group["sense"] != face["sense"]:
        return False
    if abs(_dot(group["direction"], face["direction"])) < MERGE_PARALLEL_DOT:
        return False
    offset = _sub(face["origin"], group["origin"])
    along = _dot(offset, group["direction"])
    perpendicular = _sub(offset, tuple(c * along for c in group["direction"]))
    return math.sqrt(_dot(perpendicular, perpendicular)) <= MERGE_TOLERANCE_MM


def _extent_in(group_origin, group_direction, face: dict) -> tuple:
    """(low, high, bins, exact, slope, deflection) of one face in the GROUP's
    axis frame. `deflection` is the millimetres the sampled boundary may sit
    from the real one, or None when nothing bounds it.

    Exact when the face's own boundary could be sampled. Otherwise this falls
    back to the parametric box, which is a bounding box and can overstate the
    length, and says so through `exact` so the reply can carry the caveat
    rather than hiding it.
    """
    if face["points"]:
        low, high, bins, slope = _project(
            face["points"], group_origin, group_direction, face.get("edges"))
        if low is not None:
            complete = bool(face.get("boundary_complete", True))
            deflection = face.get("deflection_mm", 0.0) \
                if face.get("deflection_bounded", True) and complete else None
            # `exact` is a claim about the whole trim, so a face missing one
            # of its rims cannot make it.
            return low, high, bins, complete, slope, deflection
    offset = _sub(face["origin"], group_origin)
    base = _dot(offset, group_direction)
    sign = 1.0 if _dot(face["direction"], group_direction) > 0.0 else -1.0
    lo = base + sign * face["v_min"]
    hi = base + sign * face["v_max"]
    # Without a boundary there is nowhere to put the sweep except the
    # parametric span; bin it so the union arithmetic stays uniform.
    covered = min(int(round(face["sweep"] / (2.0 * math.pi) * ANGULAR_BINS)),
                  ANGULAR_BINS)
    low, high = min(lo, hi), max(lo, hi)
    # The box says nothing about where the trim runs at each azimuth, so every
    # bin it covers gets the whole span — which is the assumption that
    # overstates the length, and is exactly what `exact` false warns about.
    # No boundary, so no slope to measure either; `exact` false is what warns
    # the reader that this face's extent is a bounding box.
    return (low, high, {index: [low, high] for index in range(covered)},
            False, 0.0, None)


def _merge(faces: list) -> list:
    """Group faces of one cylindrical surface into one feature each.

    TWO relations, applied in that order. First the faces are clustered by
    LINE — same radius, same sense, same axis line — which says nothing about
    where along that line each one sits. Then, inside one line cluster and in
    ONE frame (the cluster's first face), the faces are clustered by AXIAL
    OVERLAP: intervals are sorted and a new feature starts wherever a gap
    opens, so two bores on one axis with air between them stay two features.

    Sorting is what makes the second step order-independent. A patch that
    BRIDGES two others — extents [0,1], [2,3] and then [1,2] — arrives last
    from an OCCT traversal that guarantees no order at all, and a one-pass
    "does this face touch a group I already have" walk leaves it merged into
    whichever of the two it met first, reporting two features where the
    geometry has one continuous bore.

    Every group keeps its first face's axis frame and expresses the others'
    extents and angular bins in it, so a seam half whose own axis points the
    other way still lands on the same interval rather than beside it, and the
    bins can be UNIONED instead of added.
    """
    lines: list = []
    for face in faces:
        for line in lines:
            if _on_same_line(line[0], face):
                line.append(face)
                break
        else:
            lines.append([face])

    groups: list = []
    for line in lines:
        anchor = line[0]
        measured = []
        for face in line:
            low, high, bins, exact, slope, deflection = _extent_in(
                anchor["origin"], anchor["direction"], face)
            measured.append((low, high, bins, exact, slope, deflection, face))
        measured.sort(key=lambda item: item[0])
        current = None
        for low, high, bins, exact, slope, deflection, face in measured:
            if current is not None and low <= current["end"] + MERGE_AXIAL_SLACK_MM:
                current["end"] = max(current["end"], high)
                _union_bins(current["bins"], bins)
                current["area"] += face["area"]
                current["faces"] += 1
                current["exact"] = current["exact"] and exact
                current["slope"] = max(current["slope"], slope)
                current["deflection"] = _widest_deflection(
                    current["deflection"], deflection)
                continue
            current = {
                "origin": anchor["origin"],
                "direction": anchor["direction"],
                "radius": anchor["radius"],
                "sense": anchor["sense"],
                "start": low,
                "end": high,
                "bins": bins,
                "area": face["area"],
                "faces": 1,
                "exact": exact,
                "slope": slope,
                "deflection": deflection,
            }
            groups.append(current)
    return groups


def _reported(group: dict) -> dict:
    """One merged cylinder in the shape the panel reads.

    The reported origin is moved onto the START of the extent so that
    `start_mm` is always 0 and every axial number is a distance from a point
    that is actually on the feature — a bore's axis line is infinite and an
    origin somewhere off in space is a needless chance to get a sign wrong.
    """
    direction = group["direction"]
    origin = _add_scaled(group["origin"], direction, group["start"])
    length = group["end"] - group["start"]
    centre = _add_scaled(origin, direction, length * 0.5)
    # Two lengths, because a trim that is not perpendicular to the axis gives
    # the surface two of them: the stretch that is there at every azimuth (the
    # one a screw can engage over) and the stretch the material reaches at its
    # furthest azimuth (where the wall is).
    full_start, full_end = _full_turn_extent(group["bins"])
    full_bound = _full_turn_bound(
        group["bins"], group["radius"], group.get("slope", 0.0),
        group.get("deflection"))
    if full_end > full_start:
        # Stations measured from the reported origin, which sits on the start
        # of the extent.
        full_start -= group["start"]
        full_end -= group["start"]
    else:
        # No stretch is present at every azimuth (a trim steep enough that one
        # side's highest point is below the other's lowest). There is no
        # station to report, and shifting a zero-length span by the group's
        # own start would place it at an arbitrary one.
        full_start = 0.0
        full_end = 0.0
    # The fraction of the turn the boundary actually occupies, not the sum of
    # the faces' parametric spans: see the header.
    sweep = len(group["bins"]) / float(ANGULAR_BINS) * 2.0 * math.pi
    return {
        "source": "b_rep",
        "sense": group["sense"],
        "radius_mm": group["radius"],
        "dia_mm": group["radius"] * 2.0,
        "axis": {
            "origin_mm": list(origin),
            "direction": list(direction),
        },
        "centre_mm": list(centre),
        "start_mm": 0.0,
        "end_mm": length,
        "length_mm": length,
        # The extent measured from the axis origin, both ways round.
        "extent_max_mm": length,
        # The stretch present at every azimuth the surface occupies, and where
        # it runs. Zero, 0 to 0, when there is no such stretch.
        "extent_full_mm": max(0.0, full_end - full_start),
        "full_start_mm": full_start,
        "full_end_mm": full_end,
        # NEVER exact: this one is read per angular bin, so it carries the
        # bin's own resolution as an error bar. A consumer grading a screw's
        # engagement on it must subtract the bound before comparing to a
        # threshold, or a pass can turn on where a bin boundary happened to
        # fall.
        "extent_full_exact": False,
        "extent_full_bound_mm": full_bound["mm"],
        "extent_full_bound_parts": {
            "bin_step_mm": full_bound["step_mm"],
            "hidden_in_bin_mm": full_bound["hidden_mm"],
            "sampling_deflection_mm": full_bound["sampling_mm"],
            "bin_arc_mm": full_bound["bin_arc_mm"],
            "max_slope": group.get("slope", 0.0),
            "ends": 2,
        },
        # False when some edge of this surface had to be walked at a fixed
        # pitch instead of by deflection: nothing then bounds what the trim
        # does between two samples, and extent_full_bound_mm is a floor rather
        # than a bound. A consumer grading against a threshold must treat the
        # extent as unknown, not as measured.
        "extent_full_bounded": full_bound["bounded"],
        "boundary_deflection_mm": group.get("deflection"),
        "extent_full_bound": ("the full-turn extent is read in %d angular bins "
                              "of %.2f degrees. Between two bins the trim can "
                              "move %.4f mm, inside one it can hide %.4f mm "
                              "(a %.4f mm arc at a slope of %.4f), and the "
                              "boundary itself was sampled to %s. Both ends of "
                              "the extent can pay all of that, so the bound is "
                              "twice their sum, %.4f mm. Subtract it before "
                              "comparing the extent to a threshold%s"
                              % (ANGULAR_BINS, BIN_DEG, full_bound["step_mm"],
                                 full_bound["hidden_mm"],
                                 full_bound["bin_arc_mm"],
                                 group.get("slope", 0.0),
                                 ("%.4f mm" % full_bound["sampling_mm"])
                                 if full_bound["bounded"] else "no stated "
                                 "deflection",
                                 full_bound["mm"],
                                 "" if full_bound["bounded"] else
                                 " \u2014 and treat it as a FLOOR, not a bound: "
                                 "an edge was walked at a fixed pitch and "
                                 "nothing limits what it does between two "
                                 "samples")),
        "sweep_deg": math.degrees(sweep),
        "closed": math.degrees(sweep) >= CLOSED_SWEEP_MIN_DEG,
        # The resolution every angular number here is measured at. A consumer
        # deciding for itself whether a surface closed derives its tolerance
        # from this, never from a constant of its own.
        "bin_deg": BIN_DEG,
        "closed_min_sweep_deg": CLOSED_SWEEP_MIN_DEG,
        "faces": group["faces"],
        "area_mm2": group["area"],
        # False when some face of this surface had no samplable boundary and
        # its parametric box was used instead, which can overstate the length.
        "extent_exact": bool(group["exact"]),
    }


def cylindrical_features(params: dict) -> dict:
    """Answer a cylindrical-feature request. Returns {ok, result|error}.

    params:
      source     .mcad DSL text.
      min_dia_mm / max_dia_mm   optional diameter window, millimetres.
      sense      "concave" | "convex" | "any" (default) — bores, bosses, both.
      closed_only  when true, only features sweeping a full turn are reported.

    result:
      {units, count, shape_name, cylinders: [...]} — see `_reported`.
    """
    source = params.get("source")
    if not isinstance(source, str) or not source.strip():
        return _error("cylindrical_features requires params.source: the .mcad DSL text")

    sense_filter = str(params.get("sense", "any"))
    if sense_filter not in ("any", "concave", "convex"):
        return _error(
            "cylindrical_features sense must be 'any', 'concave' or 'convex', "
            "not %r" % sense_filter
        )
    try:
        min_dia = float(params.get("min_dia_mm", 0.0))
        max_dia = float(params.get("max_dia_mm", 1.0e9))
    except (TypeError, ValueError) as exc:
        return _error(f"cylindrical_features received a non-numeric parameter: {exc}")
    closed_only = bool(params.get("closed_only", False))

    try:
        occt = _occt()
        shape_name, wrapped = _shape_for(source)
        raw: list = []
        explorer = occt["TopExp_Explorer"](wrapped, occt["TopAbs_FACE"])
        while explorer.More():
            face = occt["TopoDS"].Face_s(explorer.Current())
            record = _face_cylinder(occt, face)
            if record is not None:
                raw.append(record)
            explorer.Next()
    except FeatureError as exc:
        return _error(str(exc))

    cylinders = []
    for group in _merge(raw):
        entry = _reported(group)
        if sense_filter != "any" and entry["sense"] != sense_filter:
            continue
        if entry["dia_mm"] < min_dia or entry["dia_mm"] > max_dia:
            continue
        if closed_only and not entry["closed"]:
            continue
        cylinders.append(entry)
    cylinders.sort(key=lambda c: (-c["dia_mm"], c["centre_mm"]))

    return {
        "ok": True,
        "result": {
            "units": "mm",
            "shape_name": shape_name,
            "faces_examined": len(raw),
            "count": len(cylinders),
            # True only while every reported extent came from a sampled
            # boundary. A face whose edges could not be adapted falls back to
            # the parametric box, which can overstate a length, and the reply
            # must not claim exactness it does not have.
            "exact": all(c["extent_exact"] for c in cylinders),
            "bound": ("axes and radii are read from the OCCT surfaces "
                      "themselves and carry no tessellation error; each axial "
                      "extent is the range of the face's own sampled boundary, "
                      "so a bore cut by a tilted face reports the length it "
                      "really has"),
            "cylinders": cylinders,
        },
    }


def _error(message: str) -> dict:
    return {"ok": False, "error": {"kind": "internal", "message": message}}
