"""Writing a 3MF, and keeping the reason the writer refused.

build123d's ``Mesher`` triangulates the shape itself and checks the result
before it will hold it: a part whose triangulation is not a closed, oriented
solid is rejected with a bare ``RuntimeError("3mf mesh is invalid")`` that
names neither the defect nor the part. STL streams the same triangles out
without asking, which is why a document can export to STL and not to 3MF.

This module is the only place that call is made, so the refusal becomes a
typed error the export reply can describe. Nothing here validates geometry —
the counts a caller attaches to the message come from the evaluation's own
tessellation, which has already been measured.
"""

from __future__ import annotations

from typing import Any


class MeshNotSolid(Exception):
    """3MF refused a shape: its triangulation is not a closed manifold solid.

    ``node_name`` is the DSL binding the shape came from — the nearest thing
    to a body name the exporter has.
    """

    def __init__(self, cause: BaseException, *, node_name: str = "part") -> None:
        self.cause = cause
        self.node_name = node_name
        super().__init__(str(cause) or "3mf mesh is invalid")


def write_3mf(shape: Any, path: str, *, node_name: str = "part") -> str:
    """Write *shape* to *path* as 3MF, or raise :class:`MeshNotSolid`.

    The Mesher validates inside ``add_shape``, not ``write``, so both calls
    sit under the same guard; the guard matches the refusal's own message,
    so an unrelated RuntimeError never becomes a claim about the geometry
    (lib3mf's own failures are not RuntimeErrors at all).
    """
    from build123d import Mesher

    mesher = Mesher()
    try:
        mesher.add_shape(shape)
        mesher.write(path)
    except RuntimeError as exc:
        # Only the Mesher's own validation refusal is a geometry verdict;
        # any other RuntimeError from the writer is passed on as itself.
        if "mesh is invalid" not in str(exc):
            raise
        raise MeshNotSolid(exc, node_name=node_name) from exc
    return path
