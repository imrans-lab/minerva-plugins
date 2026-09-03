"""THE BOARD AS A SOLID: outline extruded to thickness, holes cut through it.

The output is a closed triangle mesh with the two large faces textured in the
registration :mod:`texture_frame` defines, and it stands on its own — no network,
no part models, no file format. Load it and you are looking at the board.

WHY THE HOLES ARE REAL. Seeing THROUGH a mounting hole is one of the things this
export exists to allow: it is how a person checks a board against an enclosure.
A hole painted on the surface looks right from straight on and is a lie from
every other angle, and the angle a person checks a mounting boss from is never
straight on. So the openings are cut out of the geometry
(:mod:`board_region`) and the bores get walls.

WHAT IT IS MADE OF, and where each decision lives:

  thickness      the ORDERED thickness, ``board.fabrication.thickness_mm``, the
                 value the fabrication block records and the order checklist
                 prints. Never a default invented here.
  area           :mod:`board_region` — outline, less cutouts, less every drill,
                 as an exact integer polygon boolean.
  triangles      :mod:`earcut` — ear clipping with hole bridging. The two faces
                 AND the walls are all read off this one triangulation, so a
                 wall cannot describe a rim the face disagrees with.
  axes, winding  :mod:`mesh_frame`.
  UVs            :mod:`texture_frame`, unchanged and un-flipped. The bottom
                 face's mirror is inside that frame, so nothing here is aware
                 that the two sides differ.

UNIFORM THICKNESS, deliberately. Copper relief — the ~35 um a pour stands proud
of the laminate — and the dip a mask opening makes are NOT modelled. They are
below the thickness tolerance of the board itself, they would need a per-layer
displacement the texture already shows as colour, and they would multiply the
triangle count by the copper's complexity for something invisible at any
viewing distance from which the board is recognisable.

A MISSING PIECE OF BOARD IS A REFUSAL, NEVER A SMALLER SLAB. Ear clipping is a
partial function: a region it cannot fill, or fills only part of, yields fewer
triangles than the area asks for. Skipping such a region would export a board
with a piece of its material simply absent — and an incomplete slab is the one
defect class this export cannot show you, because it looks exactly like a board
with a differently-shaped outline. So every region is measured against the area
:mod:`board_region` computed for it (:data:`AREA_TOLERANCE`), the finished
surface is checked closed, and either failure raises
:class:`SubstrateMeshError` naming what did not come out.

THREE GROUPS OF TRIANGLES, not one. ``top`` and ``bottom`` carry the baked
per-side textures. ``edge`` is the rim and every bore wall: raw laminate, which
no texture registers, so those vertices carry a placeholder UV and are meant to
be drawn in the substrate colour the appearance already resolves
(``texture_appearance.appearance_for(board.fabrication).substrate``). Handing a
writer one undifferentiated triangle soup would force it to guess which
triangles a texture belongs on.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Mapping

from . import mesh_frame
from .board_drills import DrillOpening, DrillOrigin, drill_openings
from .board_region import cutout_rings, drill_rings, outline_ring, subtract
from .earcut import triangulate
from .ir_projection import outline_frame
from .mesh_frame import Vec3
from .resolved_board import ResolvedBoard, Side
from .texture_frame import DEFAULT_SCALE_PX_PER_MM, MAX_TEXTURE_PX, TextureFrame

#: A board-frame point, as :mod:`earcut` hands them back.
Point2 = tuple[float, float]

#: Placeholder UV for a vertex no texture registers — every rim and bore-wall
#: vertex. Not (0.5, 0.5): a corner is a defined, inspectable place, and on a
#: rectangular board texel (0, 0) is genuinely on the board, so a consumer that
#: ignores the grouping and textures everything gets laminate colour on its
#: walls rather than transparency.
EDGE_UV: tuple[float, float] = (0.0, 0.0)

#: How far a triangulated region may fall short of (or overshoot) the area the
#: boolean says it has, as a FRACTION of that area. The two figures are computed
#: from the same vertices by different arithmetic — a shoelace over the rings
#: versus a sum of cross products over the triangles — so they agree to float
#: round-off when the fill is complete, and disagree by whole ears when it is
#: not. 1e-9 is round-off at board scale with orders of magnitude to spare; the
#: smallest thing that can go missing is a triangle, and no triangle a clipper
#: region contains is anywhere near a billionth of it.
AREA_TOLERANCE: float = 1e-9


class SubstrateMeshError(ValueError):
    """The slab could not be built as a complete solid, and says which part."""


@dataclass(frozen=True)
class SubstrateMesh:
    """A watertight board slab.

    ``positions`` / ``normals`` / ``uvs`` run in parallel — one entry per vertex,
    which is what a glTF primitive wants. Triangles index into them and are
    split by which surface they belong to. Faces and walls never SHARE a vertex
    even where they meet: a shared one would have to carry a single normal for
    two perpendicular surfaces and would round the board's edge off.
    """

    positions: tuple[Vec3, ...]
    normals: tuple[Vec3, ...]
    uvs: tuple[tuple[float, float], ...]
    top_triangles: tuple[tuple[int, int, int], ...]
    bottom_triangles: tuple[tuple[int, int, int], ...]
    edge_triangles: tuple[tuple[int, int, int], ...]
    thickness_mm: float
    top_frame: TextureFrame
    bottom_frame: TextureFrame
    openings: tuple[DrillOpening, ...]

    @property
    def triangles(self) -> tuple[tuple[int, int, int], ...]:
        """Every triangle, faces first. For whole-mesh checks — closure, volume
        — not for drawing, which needs the groups kept apart."""
        return self.top_triangles + self.bottom_triangles + self.edge_triangles

    def frame_for(self, side) -> TextureFrame:
        name = getattr(side, "value", side)
        if name == "top":
            return self.top_frame
        if name == "bottom":
            return self.bottom_frame
        raise ValueError(f"side must be 'top' or 'bottom', got {name!r}")

    def opening_count(self, origin: DrillOrigin) -> int:
        return sum(1 for opening in self.openings if opening.origin is origin)


def build_substrate_mesh(board: ResolvedBoard, *,
                         scale_px_per_mm: float = DEFAULT_SCALE_PX_PER_MM,
                         max_px: int = MAX_TEXTURE_PX,
                         frames: Mapping[str, TextureFrame] | None = None
                         ) -> SubstrateMesh:
    """Extrude ``board`` to its ordered thickness with its holes cut through.

    ``frames`` accepts the frames an existing bake already built
    (``{side: BakedSide.frame}``). Pass them whenever the textures exist: a UV is
    ``pixel / image_dimension``, and the dimension is a CEIL, so a frame built at
    a different scale — or clamped when the other was not — registers the same
    board a fraction of a texel differently.
    """
    thickness = float(board.fabrication.thickness_mm)
    if not thickness > 0:                    # ResolvedFabrication guarantees this
        raise SubstrateMeshError(
            f"board thickness must be positive, got {thickness}")
    top_y = mesh_frame.top_y_mm(thickness)
    bottom_y = mesh_frame.BOARD_BOTTOM_Y_MM

    top_frame, bottom_frame = _frames(board, scale_px_per_mm, max_px, frames)
    openings = drill_openings(board)
    regions = subtract(outline_ring(board),
                       cutout_rings(board) + drill_rings(board, openings))
    if not regions:
        # Every openable thing consumed the outline. There is no board to
        # export, and an empty mesh would be handed on as one.
        raise SubstrateMeshError(
            "the board's outline is entirely consumed by its cutouts and "
            "drills; there is no material left to build a solid from")

    positions: list[Vec3] = []
    normals: list[Vec3] = []
    uvs: list[tuple[float, float]] = []
    top_tris: list[tuple[int, int, int]] = []
    bottom_tris: list[tuple[int, int, int]] = []
    edge_tris: list[tuple[int, int, int]] = []

    for index, region in enumerate(regions):
        points, triangles = triangulate(list(region.outer),
                                        [list(hole) for hole in region.holes])
        _check_region_filled(index, region, points, triangles)

        # The two faces share a 2D vertex list and differ in height, normal, UV
        # frame and winding — the winding because mapping the board's Y-down
        # frame into the scene reflects orientation once (see mesh_frame).
        top_base = len(positions)
        for (x, y) in points:
            positions.append(mesh_frame.scene_point(x, y, top_y))
            normals.append((0.0, 1.0, 0.0))
            uvs.append(top_frame.uv(x, y))
        bottom_base = len(positions)
        for (x, y) in points:
            positions.append(mesh_frame.scene_point(x, y, bottom_y))
            normals.append((0.0, -1.0, 0.0))
            uvs.append(bottom_frame.uv(x, y))

        for (a, b, c) in triangles:
            top_tris.append((top_base + c, top_base + b, top_base + a))
            bottom_tris.append((bottom_base + a, bottom_base + b, bottom_base + c))

        _add_walls(_face_boundary(points, triangles), top_y, bottom_y,
                   positions, normals, uvs, edge_tris)

    mesh = SubstrateMesh(
        positions=tuple(positions), normals=tuple(normals), uvs=tuple(uvs),
        top_triangles=tuple(top_tris), bottom_triangles=tuple(bottom_tris),
        edge_triangles=tuple(edge_tris), thickness_mm=thickness,
        top_frame=top_frame, bottom_frame=bottom_frame, openings=openings)
    _check_closed(mesh)
    return mesh


def _check_region_filled(index: int, region, points, triangles) -> None:
    """Refuse a region the triangulator did not turn into its whole area.

    ``triangulate`` returns what it managed, so "some triangles" is not the
    same claim as "this region". The area of the ears it emitted is compared
    against the area the polygon boolean says the region has; a pinched or
    self-touching region that clips partway through comes back short and is
    refused here rather than exported as board that is quietly not there.
    """
    expected = region.area_mm2()
    filled = 0.0
    for (a, b, c) in triangles:
        (ax, ay), (bx, by), (cx, cy) = points[a], points[b], points[c]
        filled += abs((bx - ax) * (cy - ay) - (cx - ax) * (by - ay)) / 2.0
    if abs(filled - expected) > max(AREA_TOLERANCE * expected, AREA_TOLERANCE):
        raise SubstrateMeshError(
            f"region {index} triangulated to {filled:.9g} mm^2 of the "
            f"{expected:.9g} mm^2 it covers ({len(triangles)} triangle(s) over "
            f"{len(region.outer)} outer point(s) and {len(region.holes)} "
            f"hole(s)); refusing to export a board with material missing")


def _check_closed(mesh: SubstrateMesh) -> None:
    """Refuse a surface that does not bound a solid.

    Vertices are WELDED BY POSITION first: faces and walls deliberately keep
    their own copies so their normals stay flat, so the index topology is open
    by construction while the solid is not. The rule over the welded surface is
    that every directed edge is traversed as often as its reverse — a missing
    bore wall, a face triangulated over a hole, a wall wound inside out and a
    rim split on one side of a seam but not the other each break it.

    BALANCE, NOT "EXACTLY ONCE". A board can legitimately touch itself: a bore
    exactly tangent to the outline, or to another bore, pinches the material to
    zero width along one line, and the edge on that line belongs to two pieces
    of skin at once. That surface still encloses its volume — it is the shape
    the board really has — so it is not a defect to refuse; a wall that is
    simply drawn twice is, and it fails the balance the same way a missing one
    does.
    """
    edges: dict[tuple[Vec3, Vec3], int] = {}
    for tri in mesh.triangles:
        a, b, c = (mesh.positions[i] for i in tri)
        for edge in ((a, b), (b, c), (c, a)):
            edges[edge] = edges.get(edge, 0) + 1
    unbalanced = [edge for edge, count in edges.items()
                  if edges.get((edge[1], edge[0]), 0) != count]
    if unbalanced:
        (ax, ay, az), (bx, by, bz) = unbalanced[0]
        raise SubstrateMeshError(
            f"the finished surface does not bound a solid: {len(unbalanced)} "
            f"directed edge(s) are not matched by the same number of opposite "
            f"faces, the first from ({ax:g}, {ay:g}, {az:g}) to "
            f"({bx:g}, {by:g}, {bz:g}); refusing to export a solid with holes "
            f"in its skin")


def _face_boundary(points, triangles) -> list[tuple[Point2, Point2]]:
    """The rim of a triangulated face: every edge with no triangle on its far
    side, in the direction the face winds it.

    THE WALLS FOLLOW THE TRIANGULATION, NOT THE RINGS, and that difference is
    the whole watertightness argument. The two are usually the same set of
    edges — and then differ exactly where a T-JUNCTION appears: a bore that
    touches the outline at a single point puts a vertex in the MIDDLE of an
    outline edge, so the face is triangulated to two half-edges there while the
    ring still describes one long one. A wall raised on the ring then spans a
    seam the face has already split, and the solid has a hairline crack down
    the side of the board that no viewer draws and no volume computation
    survives. Reading the rim off the triangles cannot make that mistake:
    every edge the face leaves open gets exactly one wall.
    """
    counts: dict[tuple[Point2, Point2], int] = {}
    for (a, b, c) in triangles:
        for edge in ((points[a], points[b]), (points[b], points[c]),
                     (points[c], points[a])):
            counts[edge] = counts.get(edge, 0) + 1
    return [edge for edge in counts if (edge[1], edge[0]) not in counts]


def _add_walls(edges, top_y: float, bottom_y: float,
               positions: list, normals: list, uvs: list, edge_tris: list) -> None:
    """Raise a wall on every open edge of one face.

    Each edge gets its own four vertices so its normal is flat and the board's
    corners stay sharp; the seam is invisible because both copies of a shared
    corner sit at exactly the same coordinates, which is also what keeps the
    mesh watertight once vertices are welded by position.
    """
    for ((ax, ay), (bx, by)) in edges:
        if ax == bx and ay == by:
            continue
        normal = mesh_frame.edge_outward_normal(ax, ay, bx, by)
        base = len(positions)
        for (x, y, height) in ((ax, ay, bottom_y), (ax, ay, top_y),
                               (bx, by, top_y), (bx, by, bottom_y)):
            positions.append(mesh_frame.scene_point(x, y, height))
            normals.append(normal)
            uvs.append(EDGE_UV)
        # a_low -> a_high -> b_high -> b_low, wound to face along `normal`.
        edge_tris.append((base, base + 1, base + 2))
        edge_tris.append((base, base + 2, base + 3))


def _frames(board: ResolvedBoard, scale_px_per_mm: float, max_px: int,
            supplied: Mapping[str, TextureFrame] | None
            ) -> tuple[TextureFrame, TextureFrame]:
    if supplied is not None:
        return supplied[Side.TOP.value], supplied[Side.BOTTOM.value]
    origin_x, origin_y, width_mm, height_mm = outline_frame(board.outline)
    return tuple(                                     # type: ignore[return-value]
        TextureFrame.for_board((origin_x, origin_y), (width_mm, height_mm), side,
                               scale_px_per_mm=scale_px_per_mm, max_px=max_px)
        for side in (Side.TOP.value, Side.BOTTOM.value))


__all__ = ["AREA_TOLERANCE", "EDGE_UV", "SubstrateMesh",
           "SubstrateMeshError", "build_substrate_mesh"]
