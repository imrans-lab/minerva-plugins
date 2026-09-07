"""Is one closed mesh INSIDE another, when their surfaces do not meet?

WHY A DISTANCE CANNOT SAY
The reference-pair measurement is a surface-to-surface minimum. A part
sitting wholly inside another has air between the two surfaces exactly as a
part standing beside it does, so a positive distance is not evidence that the
pair is clear. Nothing short of a containment test settles it, and this
module is that test.

WHERE IT IS WORTH ASKING
Only where one node's bounding box lies inside the other's. A mesh cannot be
inside another whose box it is not inside, so every other pair is settled by
its boxes, and the probe is paid for only on the pairs that need it.

HOW IT DECIDES
One vertex of the inner mesh is enough: the two surfaces do not intersect
(the distance between them is positive), so the whole inner mesh lies on one
side of the outer surface and every one of its vertices answers the same way.
The side is read by ray parity — an odd number of crossings with the outer
mesh's triangles means inside — along three directions chosen to lie on no
axis and no edge in common; a direction that grazes an edge or a vertex can
miscount by one, and three readings that disagree are reported as UNDECIDED
rather than voted on. Parity means nothing on a mesh that is not closed, so
the outer mesh's edges are counted first (welded by position, because a GLB
splits its vertices along every hard edge) and an open outer mesh is undecided
too. Undecided is not clean and not a crash; the caller withholds the pass.
"""

from __future__ import annotations

from typing import Optional

#: Three ray directions off every axis and off each other, so a triangle
#: edge lying along a world axis cannot be grazed by all of them at once.
_DIRECTIONS = (
    (0.3712, 0.6013, 0.7077),
    (-0.7291, 0.2864, 0.6216),
    (0.5307, -0.7534, 0.3882),
)

#: Positions closer than this are one vertex, millimetres. The same weld the
#: evaluation's defect walk uses.
_WELD_DECIMALS = 6

#: A hit closer than this to the ray origin is the origin's own surface, not
#: a crossing. The origin is a vertex of the OTHER mesh, so nothing legitimate
#: is this near unless the two surfaces touch, which the caller has excluded.
_MIN_HIT_T = 1.0e-9


def nested(box_a, box_b) -> Optional[str]:
    """Which box lies inside the other: 'a_in_b', 'b_in_a', or None.

    Boxes are ((min xyz), (max xyz)). Inclusive on the faces, because a mesh
    touching its container's box from the inside is still inside it.
    """
    if box_a is None or box_b is None:
        return None
    a_in_b = all(lo_b <= lo_a and hi_a <= hi_b for lo_a, lo_b, hi_a, hi_b
                 in zip(box_a[0], box_b[0], box_a[1], box_b[1]))
    if a_in_b:
        return "a_in_b"
    b_in_a = all(lo_a <= lo_b and hi_b <= hi_a for lo_a, lo_b, hi_a, hi_b
                 in zip(box_a[0], box_b[0], box_a[1], box_b[1]))
    return "b_in_a" if b_in_a else None


def is_closed(vertices, faces) -> bool:
    """Does every edge of the mesh belong to exactly two faces?

    Vertices are welded by position first: a mesh exported with a vertex per
    face corner reads as entirely open otherwise.
    """
    import numpy as np

    points = np.asarray(vertices, dtype=float)
    if len(points) == 0 or len(faces) == 0:
        return False
    keys = np.round(points, _WELD_DECIMALS)
    _unique, weld = np.unique(keys, axis=0, return_inverse=True)
    weld = np.asarray(weld).reshape(-1)
    tri = weld[np.asarray(faces, dtype=np.int64)]
    edges = np.concatenate([tri[:, [0, 1]], tri[:, [1, 2]], tri[:, [2, 0]]])
    edges.sort(axis=1)
    # A degenerate triangle (two corners welded together) contributes an
    # edge from a vertex to itself; it is not a surface edge.
    edges = edges[edges[:, 0] != edges[:, 1]]
    _unique_edges, counts = np.unique(edges, axis=0, return_counts=True)
    return bool(len(counts)) and bool(np.all(counts == 2))


def _crossings(origin, direction, vertices, faces) -> int:
    """How many triangles the ray from `origin` along `direction` crosses.

    Moller-Trumbore over every triangle at once; a hit at the ray's own
    origin does not count.
    """
    import numpy as np

    points = np.asarray(vertices, dtype=float)
    tri = np.asarray(faces, dtype=np.int64)
    v0 = points[tri[:, 0]]
    edge1 = points[tri[:, 1]] - v0
    edge2 = points[tri[:, 2]] - v0
    d = np.asarray(direction, dtype=float)
    p = np.cross(d, edge2)
    det = np.einsum("ij,ij->i", edge1, p)
    parallel = np.abs(det) < 1.0e-12
    safe_det = np.where(parallel, 1.0, det)
    t_vec = np.asarray(origin, dtype=float) - v0
    u = np.einsum("ij,ij->i", t_vec, p) / safe_det
    q = np.cross(t_vec, edge1)
    v = np.einsum("j,ij->i", d, q) / safe_det
    t = np.einsum("ij,ij->i", edge2, q) / safe_det
    hit = (~parallel) & (u >= 0.0) & (v >= 0.0) & (u + v <= 1.0) & (t > _MIN_HIT_T)
    return int(np.count_nonzero(hit))


def point_inside(point, vertices, faces) -> Optional[bool]:
    """True inside, False outside, None when the three rays disagree."""
    readings = {_crossings(point, direction, vertices, faces) % 2 == 1
                for direction in _DIRECTIONS}
    if len(readings) != 1:
        return None
    return readings.pop()


def containment(arrays_a, arrays_b, box_a, box_b) -> Optional[dict]:
    """The containment verdict for a pair with air between its surfaces.

    `arrays_*` are (vertices, faces); `box_*` their bounds. Returns None when
    neither box lies inside the other (nothing to ask), else
    {"containment": "a_inside_b" | "b_inside_a" | "none" | "undecidable",
     "note": why}.
    """
    which = nested(box_a, box_b)
    if which is None:
        return None
    inner, outer = (arrays_a, arrays_b) if which == "a_in_b" else (arrays_b, arrays_a)
    inner_name = "a" if which == "a_in_b" else "b"
    outer_name = "b" if which == "a_in_b" else "a"
    if not is_closed(outer[0], outer[1]):
        return {
            "containment": "undecidable",
            "note": ("%s's box lies inside %s's, and %s is not a closed mesh, "
                     "so ray parity cannot say whether %s is inside it"
                     % (inner_name, outer_name, outer_name, inner_name)),
        }
    if len(inner[0]) == 0:
        return None
    inside = point_inside(inner[0][0], outer[0], outer[1])
    if inside is None:
        return {
            "containment": "undecidable",
            "note": ("%s's box lies inside %s's and the three parity rays "
                     "disagreed, so whether %s is inside %s is not decided"
                     % (inner_name, outer_name, inner_name, outer_name)),
        }
    if inside:
        return {
            "containment": "%s_inside_%s" % (inner_name, outer_name),
            "note": ("%s lies wholly inside %s: the surfaces do not meet, "
                     "but there is no air between the parts"
                     % (inner_name, outer_name)),
        }
    return {
        "containment": "none",
        "note": ("%s's box lies inside %s's, and a parity probe found %s "
                 "outside %s's material" % (inner_name, outer_name,
                                             inner_name, outer_name)),
    }
