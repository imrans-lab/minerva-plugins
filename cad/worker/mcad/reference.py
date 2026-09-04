"""Foreign mesh references in the MCAD DSL.

A reference is a *pose*, not geometry. ``mesh("part.glb")`` names a file the
worker never opens: nothing here reads, stats or resolves the path. The
worker's only job is to record what the source said and to accumulate the
transform stack that the DSL applied, so the panel can load the file once and
place it in the CAD world.

Two consequences shape this module:

* A reference is immutable. ``translate`` / ``rotate`` / ``scale`` / ``mirror``
  return a *new* reference carrying the composed matrix; the original binding
  is untouched. This is what makes statement order observable — ``translate(t,
  rotate(r, ref))`` composes ``T·R`` while ``rotate(r, translate(t, ref))``
  composes ``R·T``. The rigid transforms compose on the left; ``scale`` is the
  exception and composes on the right (see ``MeshReference.resized``).
* Units and up-axis defaults depend on the file format, because the formats
  themselves differ: glTF/GLB is metres and Y-up by specification, while STL
  and OBJ carry no unit or orientation at all. We record the default (or the
  explicit override) and leave the conversion to the panel.

Matrices are 4x4, row-major, column-vector convention (``p' = M·p``) in the CAD
frame: millimetres, Z-up, the same frame the B-Rep solids live in.
"""

from __future__ import annotations

import math

from dataclasses import dataclass, replace
from typing import Any, Sequence

Matrix = tuple[tuple[float, float, float, float], ...]

IDENTITY: Matrix = (
    (1.0, 0.0, 0.0, 0.0),
    (0.0, 1.0, 0.0, 0.0),
    (0.0, 0.0, 1.0, 0.0),
    (0.0, 0.0, 0.0, 1.0),
)

# Per-format defaults for (units, up). A format that carries no unit or
# orientation information falls through to _FALLBACK_DEFAULTS.
FORMAT_DEFAULTS: dict[str, tuple[str, str]] = {
    ".glb": ("m", "y"),
    ".gltf": ("m", "y"),
}
_FALLBACK_DEFAULTS: tuple[str, str] = ("mm", "z")

SUPPORTED_UNITS: tuple[str, ...] = ("mm", "cm", "m", "in")
SUPPORTED_UP_AXES: tuple[str, ...] = ("x", "y", "z")


class MeshReferenceError(Exception):
    """Raised when a mesh() call is malformed. The translator re-raises it."""


# ---------------------------------------------------------------------------
# Matrix algebra
# ---------------------------------------------------------------------------

def multiply(outer: Matrix, inner: Matrix) -> Matrix:
    """Return ``outer · inner`` — *inner* applies first, *outer* second."""
    return tuple(
        tuple(
            sum(outer[row][k] * inner[k][col] for k in range(4))
            for col in range(4)
        )
        for row in range(4)
    )


def translation(offset: Sequence[float]) -> Matrix:
    x, y, z = (float(v) for v in offset)
    return (
        (1.0, 0.0, 0.0, x),
        (0.0, 1.0, 0.0, y),
        (0.0, 0.0, 1.0, z),
        (0.0, 0.0, 0.0, 1.0),
    )


def rotation(angles_deg: Sequence[float]) -> Matrix:
    """Rotation matrix for ``rotate([rx, ry, rz], ...)``.

    Built from build123d's own ``Location`` rather than from hand-written Euler
    maths, so a reference and a solid given the same angles are posed by
    definitionally the same rotation — there is no second convention to drift.
    """
    from build123d import Location  # Local: keeps the matrix helpers importable without OCCT.

    rx, ry, rz = (float(a) for a in angles_deg)
    trsf = Location((0.0, 0.0, 0.0), (rx, ry, rz)).wrapped.Transformation()
    return (
        tuple(trsf.Value(1, col) for col in range(1, 5)),
        tuple(trsf.Value(2, col) for col in range(1, 5)),
        tuple(trsf.Value(3, col) for col in range(1, 5)),
        (0.0, 0.0, 0.0, 1.0),
    )


def scaling(factors: Sequence[float]) -> Matrix:
    sx, sy, sz = (float(v) for v in factors)
    return (
        (sx, 0.0, 0.0, 0.0),
        (0.0, sy, 0.0, 0.0),
        (0.0, 0.0, sz, 0.0),
        (0.0, 0.0, 0.0, 1.0),
    )


def reflection(normal: Sequence[float]) -> Matrix:
    """Householder reflection in the origin-centred plane with this normal.

    Matches ``mirror([nx, ny, nz], solid)``, which mirrors about
    ``Plane(origin=(0,0,0), z_dir=normal)``.
    """
    nx, ny, nz = (float(v) for v in normal)
    magnitude = (nx * nx + ny * ny + nz * nz) ** 0.5
    if magnitude <= 0.0:
        raise MeshReferenceError("mirror() normal vector must be non-zero")
    nx, ny, nz = nx / magnitude, ny / magnitude, nz / magnitude
    axis = (nx, ny, nz)
    rows = []
    for row in range(3):
        rows.append(
            tuple(
                (1.0 if row == col else 0.0) - 2.0 * axis[row] * axis[col]
                for col in range(3)
            )
            + (0.0,)
        )
    rows.append((0.0, 0.0, 0.0, 1.0))
    return tuple(rows)


# ---------------------------------------------------------------------------
# The reference itself
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class MeshReference:
    """One foreign mesh file, posed but never opened.

    ``path`` is stored exactly as the source wrote it; resolving it relative to
    the .mcad document is the panel's job.
    """

    path: str
    units: str
    up: str
    matrix: Matrix = IDENTITY
    name: str | None = None

    @property
    def label(self) -> str:
        """How the reference is named in an error message."""
        if self.name:
            return f'{self.name} (mesh("{self.path}"))'
        return f'mesh("{self.path}")'

    def posed(self, transform: Matrix) -> "MeshReference":
        """Return a copy with a rigid *transform* applied on top of the pose.

        Rigid transforms act in world space: build123d's ``moved`` and
        ``mirror`` both compose on the left of whatever pose a solid already
        carries, so translate / rotate / mirror do the same here.
        """
        return replace(self, matrix=multiply(transform, self.matrix))

    def resized(self, factors: Sequence[float]) -> "MeshReference":
        """Return a copy scaled in the reference's OWN frame.

        Scaling is the odd one out. build123d's ``scale`` strips a shape's
        location, scales the geometry, then restores the location — so the
        scale lands *inside* the pose already composed, not on top of it.
        Right-multiplying keeps a reference and a solid in step; left-
        multiplying would move a scaled-then-translated reference to a
        different place than the equivalent solid.

        The scale must be UNIFORM and non-zero. A reference is measured, not
        rendered: a non-uniform scale turns every hole in the file into an
        ellipse, which has no diameter for a measurement to report and no pin
        that fits it, and a zero factor collapses the pose so that no point in
        the world maps back to a point in the file.
        """
        sx, sy, sz = (float(v) for v in factors)
        if not all(math.isfinite(v) for v in (sx, sy, sz)):
            raise MeshReferenceError(
                f"scale({[sx, sy, sz]}, {self.label}) has a non-finite factor"
            )
        if any(abs(v) < 1e-12 for v in (sx, sy, sz)):
            raise MeshReferenceError(
                f"scale({[sx, sy, sz]}, {self.label}) has a zero factor; a "
                "reference scaled to nothing cannot be posed or measured"
            )
        # Compared with a tolerance: factors like 0.1+0.2 vs 0.3 are the same
        # scale to a user even though they differ in the last bit.
        if not (math.isclose(sx, sy, rel_tol=1e-9, abs_tol=1e-12)
                and math.isclose(sx, sz, rel_tol=1e-9, abs_tol=1e-12)):
            raise MeshReferenceError(
                f"scale({[sx, sy, sz]}, {self.label}) is not uniform; a mesh "
                "reference is measured geometry and a "
                "non-uniform scale turns its holes into ellipses. Scale it "
                "equally on all three axes, or edit the mesh."
            )
        return replace(self, matrix=multiply(self.matrix, scaling(factors)))

    def renamed(self, name: str) -> "MeshReference":
        return replace(self, name=name)

    def to_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "path": self.path,
            "units": self.units,
            "up": self.up,
            "matrix": [list(row) for row in self.matrix],
        }


def default_units_and_up(path: str) -> tuple[str, str]:
    """Format-derived defaults, keyed on the path's extension."""
    lowered = path.lower()
    for extension, defaults in FORMAT_DEFAULTS.items():
        if lowered.endswith(extension):
            return defaults
    return _FALLBACK_DEFAULTS


def make_reference(
    path: Any,
    units: Any = None,
    up: Any = None,
) -> MeshReference:
    """Build a reference from evaluated ``mesh()`` arguments.

    Raises ``MeshReferenceError`` for anything the DSL got wrong. No file
    access happens here or anywhere else in the worker.
    """
    if not isinstance(path, str) or isinstance(path, bool):
        raise MeshReferenceError(
            f"mesh() path must be a string, got {type(path).__name__}"
        )
    if path.strip() == "":
        raise MeshReferenceError("mesh() path must not be empty")

    default_units, default_up = default_units_and_up(path)

    if units is None:
        resolved_units = default_units
    else:
        if not isinstance(units, str):
            raise MeshReferenceError(
                f"mesh() units= must be a string, got {type(units).__name__}"
            )
        resolved_units = units.strip().lower()
        if resolved_units in ("inch", "inches"):
            resolved_units = "in"
        if resolved_units not in SUPPORTED_UNITS:
            raise MeshReferenceError(
                f"mesh() units= must be one of {', '.join(SUPPORTED_UNITS)}, "
                f"got '{units}'"
            )

    if up is None:
        resolved_up = default_up
    else:
        if not isinstance(up, str):
            raise MeshReferenceError(
                f"mesh() up= must be a string, got {type(up).__name__}"
            )
        resolved_up = up.strip().lower()
        if resolved_up not in SUPPORTED_UP_AXES:
            raise MeshReferenceError(
                f"mesh() up= must be one of {', '.join(SUPPORTED_UP_AXES)}, "
                f"got '{up}'"
            )

    return MeshReference(path=path, units=resolved_units, up=resolved_up)
