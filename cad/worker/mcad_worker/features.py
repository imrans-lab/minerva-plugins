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

#: A merged sweep at least this much of a full turn is a closed cylinder — a
#: hole or a full boss rather than a fillet, a slot end or a rounded corner.
#: With the sweep measured in bins, this threshold means EVERY bin: one empty
#: bin out of ANGULAR_BINS is 355 degrees and does not reach it.
CLOSED_SWEEP_RAD = math.radians(359.5)

#: Angular bins the turn is divided into when measuring how much of it a face's
#: boundary covers. 72 bins is 5 degrees, fine enough that a quarter-turn
#: fillet and a full bore cannot be confused and coarse enough that a sampled
#: boundary fills every bin it crosses.
ANGULAR_BINS = 72

#: Samples taken along each boundary edge. It has to be at least twice
#: ANGULAR_BINS so that a full circle leaves no bin empty between two samples;
#: 145 puts a sample every 2.5 degrees of a full turn.
EDGE_SAMPLES = 145

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
    boundary = _boundary_points(occt, face)

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
        "points": boundary,
        "sense": sense,
        "area": float(props.Mass()),
    }


def _boundary_points(occt: dict, face) -> list:
    """Sample every boundary edge of `face` in 3D.

    These points ARE the trim: where they reach along the axis is how long the
    face is, and which way round they go is how far it sweeps. A face whose
    edges cannot be adapted (a degenerate seam, a curve with no 3D
    representation) contributes none, and the caller falls back to the
    parametric box for that face and says so.
    """
    points: list = []
    explorer = occt["TopExp_Explorer"](face, occt["TopAbs_EDGE"])
    while explorer.More():
        edge = occt["TopoDS"].Edge_s(explorer.Current())
        explorer.Next()
        try:
            curve = occt["BRepAdaptor_Curve"](edge)
            first = float(curve.FirstParameter())
            last = float(curve.LastParameter())
        except BaseException:  # noqa: BLE001 — a degenerate edge raises anything
            continue
        if not (last > first):
            continue
        span = last - first
        for i in range(EDGE_SAMPLES):
            parameter = first + span * (i / float(EDGE_SAMPLES - 1))
            try:
                point = curve.Value(parameter)
            except BaseException:  # noqa: BLE001
                break
            points.append((point.X(), point.Y(), point.Z()))
    return points


def _project(points: list, origin, direction) -> tuple:
    """(axial min, axial max, occupied angular bins) of `points` about an axis.

    The angular frame is derived from the DIRECTION alone — a reference vector
    chosen the same way for every caller — so two faces of one surface land in
    one frame and their bins can be unioned rather than added.
    """
    reference = _perpendicular(direction)
    other = _cross(direction, reference)
    low = None
    high = None
    bins: set = set()
    for point in points:
        offset = _sub(point, origin)
        axial = _dot(offset, direction)
        low = axial if low is None else min(low, axial)
        high = axial if high is None else max(high, axial)
        radial = _sub(offset, tuple(c * axial for c in direction))
        angle = math.atan2(_dot(radial, other), _dot(radial, reference))
        bins.add(int((angle % (2.0 * math.pi)) / (2.0 * math.pi) * ANGULAR_BINS)
                 % ANGULAR_BINS)
    return low, high, bins


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
    """(low, high, bins, exact) of one face in the GROUP's axis frame.

    Exact when the face's own boundary could be sampled. Otherwise this falls
    back to the parametric box, which is a bounding box and can overstate the
    length, and says so through `exact` so the reply can carry the caveat
    rather than hiding it.
    """
    if face["points"]:
        low, high, bins = _project(face["points"], group_origin, group_direction)
        if low is not None:
            return low, high, bins, True
    offset = _sub(face["origin"], group_origin)
    base = _dot(offset, group_direction)
    sign = 1.0 if _dot(face["direction"], group_direction) > 0.0 else -1.0
    lo = base + sign * face["v_min"]
    hi = base + sign * face["v_max"]
    # Without a boundary there is nowhere to put the sweep except the
    # parametric span; bin it so the union arithmetic stays uniform.
    covered = min(int(round(face["sweep"] / (2.0 * math.pi) * ANGULAR_BINS)),
                  ANGULAR_BINS)
    return min(lo, hi), max(lo, hi), set(range(covered)), False


def _merge(faces: list) -> list:
    """Group faces of one cylindrical surface into one feature each.

    Every group keeps the FIRST face's axis frame and expresses the others'
    extents and angular bins in it, so a seam half whose own axis points the
    other way still lands on the same interval rather than beside it, and the
    bins can be UNIONED instead of added.
    """
    groups: list = []
    for face in faces:
        placed = False
        for group in groups:
            if not _on_same_line(group, face):
                continue
            low, high, bins, exact = _extent_in(
                group["origin"], group["direction"], face)
            # Same line AND overlapping stretch of it, or they are two
            # features that happen to be collinear.
            if low > group["end"] + MERGE_AXIAL_SLACK_MM \
                    or high < group["start"] - MERGE_AXIAL_SLACK_MM:
                continue
            group["start"] = min(group["start"], low)
            group["end"] = max(group["end"], high)
            group["bins"] |= bins
            group["area"] += face["area"]
            group["faces"] += 1
            group["exact"] = group["exact"] and exact
            placed = True
            break
        if placed:
            continue
        low, high, bins, exact = _extent_in(
            face["origin"], face["direction"], face)
        groups.append({
            "origin": face["origin"],
            "direction": face["direction"],
            "radius": face["radius"],
            "sense": face["sense"],
            "start": low,
            "end": high,
            "bins": bins,
            "area": face["area"],
            "faces": 1,
            "exact": exact,
        })
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
        "sweep_deg": math.degrees(sweep),
        "closed": sweep >= CLOSED_SWEEP_RAD,
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
