"""THE BOARD-TO-SCENE AXIS CONVENTION for 3D output, defined ONCE.

:mod:`texture_frame` owns the raster registration — where pixel (0, 0) is, which
way ``u`` and ``v`` run, and the fact that the bottom side mirrors on X and
NEVER on Y. It says nothing about a third dimension, because a picture has none.
This module adds exactly the missing piece and nothing else: how a board
millimetre becomes a scene millimetre, and which way a face has to be wound to
point out of the solid. It is deliberately tiny and dependency-free so the mesh
builder and the file writer that follows it both read the SAME answer instead of
each deciding — a board exported upside down or inside out looks plausible in a
thumbnail and is wrong on every viewer that culls back faces.

THE MAPPING
-----------
glTF is right-handed with +Y UP. The board frame is KiCad's: X right, **Y down**,
with no third axis at all. So::

    scene_x = board_x          board X is unchanged
    scene_y = height above the board's underside
    scene_z = board_y          board's DOWN-the-page axis becomes scene +Z

Read that from a standard top view — camera on +Y looking down, its up vector
-Z — and screen-right is +X while screen-DOWN is +Z, which is exactly how the
editor draws the board. So "the model, seen from above" and "the board, on the
canvas" agree, and they agree without anyone negating anything.

THE BOARD SITS ON THE GROUND: its underside is the plane ``scene_y = 0`` and its
top face is at ``scene_y = thickness``. Nothing is re-centred, so a board
authored at KiCad coordinates keeps them and a feature at board (x, y) is
findable at scene (x, *, y) by inspection. That matters more than a tidy origin:
a viewer frames on the bounding box anyway, whereas a silent translation is
something every later consumer has to know about and one of them will not.

WINDING IS A CONSEQUENCE OF THE MAPPING, NOT A SEPARATE CHOICE
---------------------------------------------------------------
Mapping ``(x, y) -> (x, h, y)`` reflects orientation exactly once, so a triangle
that is POSITIVELY wound in the board frame (:func:`earcut.signed_area` > 0)
comes out with its geometric normal pointing at **-Y**. Therefore:

  * the BOTTOM face keeps the triangulator's winding, and faces down;
  * the TOP face must REVERSE it, and faces up;
  * a wall quad walking a ring edge a -> b is wound ``(a_low, a_high, b_high)``,
    ``(a_low, b_high, b_low)``, which points along the 2D outward normal
    ``(dy, -dx)`` of that edge.

Every one of those three is asserted geometrically by the substrate mesh's tests
rather than trusted, because "the normals are backwards" is not a crash, it is a
board that renders as a hole in the world.
"""

from __future__ import annotations

Vec3 = tuple[float, float, float]

#: The scene plane the board's UNDERSIDE rests on.
BOARD_BOTTOM_Y_MM = 0.0


def scene_point(x_mm: float, y_mm: float, height_mm: float) -> Vec3:
    """One board-frame point, at ``height_mm`` above the underside, in the scene."""
    return (x_mm, height_mm, y_mm)


def scene_direction(dx: float, dy: float) -> Vec3:
    """A board-frame DIRECTION (no height component) in the scene."""
    return (dx, 0.0, dy)


def top_y_mm(thickness_mm: float) -> float:
    """The scene height of the board's top face."""
    return BOARD_BOTTOM_Y_MM + thickness_mm


def edge_outward_normal(ax: float, ay: float, bx: float, by: float) -> Vec3:
    """The outward scene normal of the wall raised on board edge ``a -> b``.

    ``(dy, -dx)`` is outward for a positively wound outer ring and, without any
    special case, also outward-from-the-solid for a negatively wound hole ring —
    which is why hole walls need no separate rule.
    """
    dx, dy = bx - ax, by - ay
    length = (dx * dx + dy * dy) ** 0.5
    if length == 0.0:
        return (0.0, 0.0, 0.0)
    return (dy / length, 0.0, -dx / length)
