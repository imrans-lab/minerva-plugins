"""Geometric, shape-bound edge selections for one topology-changing operation."""
from dataclasses import dataclass
import math
from typing import Any


@dataclass(frozen=True)
class EdgeSelection:
    shape: Any
    edges: tuple


def _number(value, name):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError(f"edges {name} must be finite numeric data")
    return float(value)


def _direction(value, name):
    from build123d import Vector
    if not isinstance(value, (list, tuple)) or len(value) != 3:
        raise ValueError(f"edges {name} must be [x,y,z]")
    result = Vector(*(_number(v, name) for v in value))
    if result.length <= 1e-12:
        raise ValueError(f"edges {name} must have nonzero length")
    return result.normalized()


def _straight(edge, tolerance):
    """Recognize collinear spline poles too: affine scaling may erase LINE tags."""
    from build123d import GeomType, Vector
    from OCP.BRepAdaptor import BRepAdaptor_Curve
    if edge.geom_type == GeomType.LINE:
        return True
    if edge.geom_type not in (GeomType.BSPLINE, GeomType.BEZIER):
        return False
    curve = BRepAdaptor_Curve(edge.wrapped)
    spline = curve.BSpline() if edge.geom_type == GeomType.BSPLINE else curve.Bezier()
    start, end = edge.start_point(), edge.end_point()
    direction = end - start
    if direction.length <= tolerance:
        return False
    axis = direction.normalized()
    return all((Vector(spline.Pole(i)) - start).cross(axis).length <= tolerance
               for i in range(1, spline.NbPoles() + 1))


def _planar(face, tolerance):
    from build123d import GeomType
    from OCP.BRep import BRep_Tool
    from OCP.GeomLib import GeomLib_IsPlanarSurface
    return face.geom_type == GeomType.PLANE or GeomLib_IsPlanarSurface(
        BRep_Tool.Surface_s(face.wrapped), tolerance).IsPlanar()


def select_edges(shape, *, parallel=None, face_normal=None, outer=False,
                 above_z=None, below_z=None, tolerance=1e-6,
                 angle_deg=0.1, expected=None):
    if not hasattr(shape, "edges") or not hasattr(shape, "faces"):
        raise ValueError("edges requires a B-Rep shape, before instancing")
    tolerance = _number(tolerance, "tolerance")
    angle_deg = _number(angle_deg, "angle_deg")
    if tolerance < 0 or not 0 <= angle_deg < 90:
        raise ValueError("edges tolerance must be nonnegative and angle_deg in [0,90)")
    if not isinstance(outer, bool) or (outer and face_normal is None):
        raise ValueError("edges outer=true requires face_normal to identify planar face boundaries")
    if expected is not None and (isinstance(expected, bool) or not isinstance(expected, int) or expected <= 0):
        raise ValueError("edges expected must be a positive integer")
    minimum = _number(above_z, "above_z") if above_z is not None else None
    maximum = _number(below_z, "below_z") if below_z is not None else None
    if minimum is not None and maximum is not None and minimum > maximum:
        raise ValueError("edges above_z must not exceed below_z")
    axis = _direction(parallel, "parallel") if parallel is not None else None
    normal = _direction(face_normal, "face_normal") if face_normal is not None else None
    cosine = math.cos(math.radians(angle_deg))
    face_edges = []
    if normal is not None:
        for face in shape.faces():
            if _planar(face, tolerance) and face.normal_at().dot(normal) >= cosine - 1e-12:
                face_edges.extend(face.outer_wire().edges() if outer else face.edges())
    selected = []
    for edge in shape.edges():
        if axis is not None and (not _straight(edge, tolerance) or abs(edge.tangent_at(0.5).dot(axis)) < cosine - 1e-12):
            continue
        if normal is not None and not any(edge.is_same(candidate) for candidate in face_edges):
            continue
        bounds = edge.bounding_box()
        if minimum is not None and bounds.min.Z < minimum - tolerance:
            continue
        if maximum is not None and bounds.max.Z > maximum + tolerance:
            continue
        selected.append(edge)
    if not selected:
        raise ValueError("edge rule matched no edges")
    if expected is not None and len(selected) != expected:
        raise ValueError(f"edge rule expected {expected} edges but matched {len(selected)}")
    return EdgeSelection(shape, tuple(selected))
