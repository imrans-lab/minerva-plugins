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
faces that share an axis line and a radius are merged into one feature and
their angular sweeps summed. `closed` is then the honest word for "this goes
all the way round"; a 180-degree sweep is a fillet or a slot end, not a hole.

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
CLOSED_SWEEP_RAD = math.radians(359.5)


class FeatureError(Exception):
    """A feature request that cannot be answered, with a reason for the user."""


def _occt():
    """Import the OCCT topology surface, or raise with a reason.

    Imported at call time, exactly like clearance's fcl: a worker that never
    asks for features never pays for the import, and a broken build says what
    is broken instead of raising a bare ImportError from three frames down.
    """
    try:
        from OCP.BRepAdaptor import BRepAdaptor_Surface
        from OCP.BRepGProp import BRepGProp
        from OCP.BRepTools import BRepTools
        from OCP.GProp import GProp_GProps
        from OCP.GeomAbs import GeomAbs_Cylinder
        from OCP.TopAbs import TopAbs_FACE, TopAbs_REVERSED
        from OCP.TopExp import TopExp_Explorer
        from OCP.TopoDS import TopoDS
    except BaseException as exc:  # noqa: BLE001 — a broken .so raises anything
        raise FeatureError(
            "reading B-Rep features needs the OCCT bindings (OCP), which this "
            "runtime bundle could not load: %s" % exc
        ) from exc
    return {
        "BRepAdaptor_Surface": BRepAdaptor_Surface,
        "BRepGProp": BRepGProp,
        "BRepTools": BRepTools,
        "GProp_GProps": GProp_GProps,
        "GeomAbs_Cylinder": GeomAbs_Cylinder,
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

    # The face's own trimmed parameter box. For a cylinder, v IS the signed
    # distance along the axis from `origin`, and u is the angle round it, so
    # the extent needs no projection of vertices.
    u_min, u_max, v_min, v_max = occt["BRepTools"].UVBounds_s(face)

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
        "sense": sense,
        "area": float(props.Mass()),
    }


def _dot(a, b) -> float:
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def _sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def _add_scaled(a, b, k: float):
    return (a[0] + b[0] * k, a[1] + b[1] * k, a[2] + b[2] * k)


def _same_axis(group: dict, face: dict) -> bool:
    """Do this face and this group lie on the same infinite cylinder?

    Radius, axis DIRECTION (either sense — a seam half can carry the opposite
    one) and the perpendicular distance between the two axis lines.
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


def _merge(faces: list) -> list:
    """Group faces of one cylindrical surface into one feature each.

    Every group keeps the FIRST face's axis frame and expresses the others'
    axial extents in it, so a seam half whose own axis points the other way
    still lands on the same interval rather than beside it.
    """
    groups: list = []
    for face in faces:
        for group in groups:
            if not _same_axis(group, face):
                continue
            offset = _sub(face["origin"], group["origin"])
            base = _dot(offset, group["direction"])
            sign = 1.0 if _dot(face["direction"], group["direction"]) > 0.0 else -1.0
            lo = base + sign * face["v_min"]
            hi = base + sign * face["v_max"]
            group["start"] = min(group["start"], lo, hi)
            group["end"] = max(group["end"], lo, hi)
            group["sweep"] += face["sweep"]
            group["area"] += face["area"]
            group["faces"] += 1
            break
        else:
            groups.append({
                "origin": face["origin"],
                "direction": face["direction"],
                "radius": face["radius"],
                "sense": face["sense"],
                "start": min(face["v_min"], face["v_max"]),
                "end": max(face["v_min"], face["v_max"]),
                "sweep": face["sweep"],
                "area": face["area"],
                "faces": 1,
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
    sweep = min(group["sweep"], 2.0 * math.pi)
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
            "exact": True,
            "bound": ("axes, radii and axial extents are read from the OCCT "
                      "surfaces themselves and carry no tessellation error"),
            "cylinders": cylinders,
        },
    }


def _error(message: str) -> dict:
    return {"ok": False, "error": {"kind": "internal", "message": message}}
