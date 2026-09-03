"""A VENDOR'S 3D MODEL, expressed in OUR footprint-local frame — the two links of
the placement chain that no other module owns.

The chain a placed part travels, outermost link last::

    model frame (OBJ, mm, Z up)
      -> vendor canvas (EasyEDA footprint drawing, Y-DOWN, mm from the datum)   [1]
      -> our footprint-local frame (KiCad .kicad_mod, Y-DOWN)                    [2]
      -> board frame                     geometry.PlacementTransform, the CPL's own
      -> scene                           mesh_frame.scene_point

This module is links [1] and [2]. Both are ORIENTATION-SENSITIVE and both fail
SILENTLY: a wrong sign here produces a model that loads, renders and looks
plausible while sitting a quarter turn or a body-width from where the part will
be soldered. So neither link is taken from documentation. Both were measured.

LINK 1 — MODEL TO CANVAS. MEASURED, NOT READ
--------------------------------------------
The SVGNODE record that names the model also carries, as child polylines, the
vendor's OWN 2D projection of the sited model onto the footprint canvas
(``outline3D``). That projection is the answer key: a candidate map is right
exactly when it lays the model's silhouette on top of it. Fifteen live parts — three quarter-turn ``c_rotation`` values, five asymmetric side-entry
connectors, a mid-mount USB-C, a radio module with an antenna end — were fitted
under all eight candidate maps (X flip, Y flip, rotation sense). ONE map fits
every part to a few microns and every other map misses the asymmetric ones by a
body-width::

    canvas = rotate_ccw((mx, -my), c_rotation_z) + t

That is: the model's Y is NEGATED (its right-handed Z-up frame becomes the
canvas's Y-down frame), THEN the vendor rotation is applied counter-clockwise on
screen — the very same sense :func:`part_orientation.rotate_ccw` gives the
ledger offset, so the chain never spells a second rotation convention.

THE TRANSLATION ``t`` IS THE OUTLINE, NOT ``c_origin``. Across twenty-five live
payloads ``c_origin`` equalled the outline's centre for nineteen and was stale or
nonsensical for six — among them the R0805 drawing every 0805 resistor on our
boards uses (1.41 mm off on a 2.0 mm part), an SOT-23-5 at 5.4 mm off, and one
at 861 mm. The outline sat on the pads every time. So the model's mapped
bounding-box centre is placed on the outline's centre, and ``c_origin`` is
consulted only to REPORT its disagreement (:data:`NOTE_ORIGIN_DISAGREES`). A
payload with no outline falls back to ``c_origin`` and says so.

``c_width`` / ``c_height`` are the model's bounding-box extents in the MODEL's
frame, before ``c_rotation``: every measured part's OBJ bounds matched them
unrotated, and the outline's box matched them swapped where ``c_rotation`` was 90.

SEATING HEIGHT. The SVGNODE ``z`` is where the model's LOWEST point sits
relative to the board face, not an additive offset of the model's own origin.
Two readings agree whenever the model is authored with its underside at z = 0,
which most are; they disagree on the ones that are not, and there the additive
reading sinks the part INTO the board — a TSOT-23-6 authored at z in
[-0.62, 0.27] by 0.62 mm of its 0.89 mm height, a top-port microphone at
[-1.00, 0.01] entirely. The two parts whose vendor set a non-zero z (a
through-hole header, a mid-mount USB-C) both set it to EXACTLY the model's
minimum z, which is what a "height of the lowest point" field looks like. So::

    h = mz - min(mz) + z_mm          (h is height above the seating face)

and :data:`NOTE_MODEL_NOT_AT_ZERO` reports a model whose own minimum was not at
zero, so a reader can see which parts the two readings would have disagreed on.

LINK 2 — CANVAS TO OURS. THE LEDGER'S ROTATION, A RECOMPUTED TRANSLATION
------------------------------------------------------------------------
:mod:`orientation_ledger` stores the ROTATION between the vendor's drawing and
ours, in the sense ``ours = rotate_ccw(vendor, offset_deg)``. It stores NO
translation — ``datum_offset_mm`` is an output of the measurement that never
made it into the row — so the translation is recomputed here from the two pad
fields the caller is holding, by the measurement's own rule
(:func:`part_orientation.datum_offset`)::

    local = rotate_ccw(canvas, offset_deg) + datum

Where the two drawings share no pad number there is no datum to compute, and
the model is centred on our footprint origin instead (:data:`NOTE_NO_DATUM`) —
the outline centre link 1 already sited it on, never the vendor canvas origin,
which is the value known to be stale. That fallback is a TRANSLATION fallback
and touches nothing else: the caller's rotation is applied unchanged, because
it is the rotation the position file states.

Nothing here decides WHICH offset applies, or whether one applies at all: the
caller reads the ledger and the CPL's own refusals and passes the angle it has
settled on. This module turns points.

TWO CHECKS THAT FALL OUT FOR FREE — AND WHAT THEY CANNOT SEE
------------------------------------------------------------
:func:`crosswise` — once the model is in our frame, its footprint should be
elongated the same way our PAD field is. A model elongated across our pads means
the LEDGER is wrong for this pair (or the vendor rotated their model against
their own drawing). It is an independent check on the ledger, because the mesh
is data the ledger was never derived from.

:func:`extent_disagreement` — the vendor's package extent, turned into our
frame, against our fab-outline body box. It catches a length-for-width swap in a
footprint authored from a datasheet.

NEITHER CHECK CAN SEE ANYTHING ON A SQUARE PART. A 3 x 3 QFN elongates no way at
all, and a swapped 3 x 3 is 3 x 3. Both functions say so explicitly
(:data:`INDETERMINATE`) rather than returning "fine", and both are ADVISORY: a
render is a picture, and the order gate is :mod:`assembly_orientation`.
"""

from __future__ import annotations

import math

from dataclasses import dataclass
from typing import Mapping, Union

from . import part_orientation as po
from .part_models import ModelReference
from .wavefront_obj import Material, Mesh

Vec3 = tuple[float, float, float]
Point2 = tuple[float, float]

#: Below this ratio of long side to short side a box is SQUARE for the purposes
#: of both checks: neither can say anything about it, and says so. Measured on
#: the fixture footprints: an 0805 land box (2.85 x 1.40) and a side-entry JST
#: land box (12.2 x 9.2) are decidable at 1.25; a TSOT-23-6 PACKAGE with its
#: leads (2.9 x 2.8) and a 3 x 3 QFN are honestly undecided.
SQUARE_RATIO = 1.25

#: Result of a check that cannot decide on this geometry. A value, not None, so
#: a caller cannot mistake "nothing to report" for "could not look".
INDETERMINATE = "indeterminate"

#: Below this, two boxes are the same box for the extent check. Vendor package
#: boxes include leads and latches our fab outline does not (the fixture's JST
#: S4B is 12.0 x 8.6 to the vendor and 12.0 x 7.7 on our fab layer), so a
#: one-axis difference is ordinary; the check fires only where SWAPPING the
#: vendor box would fit ours better — see :func:`extent_disagreement`.
EXTENT_TOL_MM = 0.75

NOTE_ORIGIN_DISAGREES = "vendor_origin_disagrees_with_outline"
NOTE_NO_OUTLINE = "vendor_outline_absent_used_c_origin"
NOTE_MODEL_NOT_AT_ZERO = "model_minimum_not_at_zero"
#: The two drawings shared no pad number, so link 2 had no datum and the model
#: was centred on our footprint origin instead. A missing TRANSLATION only —
#: the rotation the caller passed is applied exactly as it always is.
NOTE_NO_DATUM = "no_shared_pad_number_seated_on_outline_centre"


@dataclass(frozen=True)
class SeatedModel:
    """A vendor model in OUR footprint-local frame: ``(x, y)`` Y-down millimetres
    exactly as a ``.kicad_mod`` states pad offsets, ``h`` millimetres above the
    seating face (positive is away from the board on whichever side the part is
    placed). Triangles and materials are the mesh's own, untouched."""

    part: str
    uuid: str
    points: tuple[Vec3, ...]
    triangles: tuple[tuple[int, int, int], ...]
    triangle_materials: tuple[Union[str, None], ...]
    materials: Mapping[str, Material]
    #: Axis-aligned box of the seated footprint, ``(min_x, min_y, max_x, max_y)``.
    bbox: tuple[float, float, float, float]
    #: Highest point above the seating face.
    height_mm: float
    notes: tuple[str, ...] = ()

    @property
    def centre(self) -> Point2:
        x0, y0, x1, y1 = self.bbox
        return ((x0 + x1) / 2.0, (y0 + y1) / 2.0)

    @property
    def extent(self) -> Point2:
        x0, y0, x1, y1 = self.bbox
        return (x1 - x0, y1 - y0)


def _bbox(points) -> tuple[float, float, float, float]:
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    return (min(xs), min(ys), max(xs), max(ys))


def model_to_canvas(reference: ModelReference, mesh: Mesh,
                    ) -> tuple[tuple[Vec3, ...], tuple[str, ...], Mapping[int, int]]:
    """LINK 1. Every REFERENCED mesh vertex as ``(canvas_x, canvas_y, h)``, the
    notes the siting raised, and the old-to-new vertex index map the caller
    re-indexes the triangles with (unreferenced vertices are dropped, so the
    box a viewer frames on is the part's and not the file's).

    See the module docstring for the measurement each term rests on.
    """
    used = sorted({i for tri in mesh.triangles for i in tri})
    if not used:
        return (), (), {}
    zs = [mesh.vertices[i][2] for i in used]
    z_min = min(zs)
    turn = reference.rotation_deg[2]
    # Y negated, then the vendor's rotation, counter-clockwise on screen.
    flat = {i: po.rotate_ccw((mesh.vertices[i][0], -mesh.vertices[i][1]), turn)
            for i in used}
    x0, y0, x1, y1 = _bbox(flat.values())
    centre = ((x0 + x1) / 2.0, (y0 + y1) / 2.0)

    notes: list[str] = []
    if reference.outline_bbox_mm is not None:
        ox0, oy0, ox1, oy1 = reference.outline_bbox_mm
        target = ((ox0 + ox1) / 2.0, (oy0 + oy1) / 2.0)
        gap = math.dist(target, (reference.origin_x_mm, reference.origin_y_mm))
        if gap > 0.05:
            notes.append(f"{NOTE_ORIGIN_DISAGREES}: c_origin sits {gap:.3f} mm "
                         f"from the vendor's own outline centre; the outline was used")
    else:
        # No outline to trust; the model's own origin goes where c_origin says.
        target = (centre[0] + reference.origin_x_mm, centre[1] + reference.origin_y_mm)
        notes.append(f"{NOTE_NO_OUTLINE}: the payload draws no outline3D, so the "
                     f"model was sited by c_origin, which is known to be stale on "
                     f"some parts")
    tx, ty = target[0] - centre[0], target[1] - centre[1]
    if abs(z_min) > 0.1:
        notes.append(f"{NOTE_MODEL_NOT_AT_ZERO}: the model's lowest point is at "
                     f"z={z_min:.3f} in its own frame; seated with that point at "
                     f"the vendor z of {reference.z_mm:.3f} mm")
    lift = reference.z_mm - z_min

    # Positions are re-indexed densely over the REFERENCED vertices so the
    # triangles can be carried verbatim after a remap.
    remap = {old: new for new, old in enumerate(used)}
    points = tuple((flat[i][0] + tx, flat[i][1] + ty, mesh.vertices[i][2] + lift)
                   for i in used)
    return points, tuple(notes), remap


def seat_model(reference: ModelReference, mesh: Mesh, part: str, *,
               offset_deg: float, datum: Union[Point2, None]) -> SeatedModel:
    """LINKS 1 AND 2. The model in our footprint-local frame.

    ``offset_deg`` is the rotation the caller has settled on (the ledger's, or
    0 for a pair it is knowingly guessing), ``datum`` the translation from
    :func:`part_orientation.datum_offset` — None when the two drawings share no
    pad number, in which case the model is centred on our footprint origin and
    :data:`NOTE_NO_DATUM` says so.

    A MISSING DATUM IS A MISSING TRANSLATION, NOT A MISSING ANGLE. ``datum``
    None never changes what ``offset_deg`` does; a caller holding a measured
    rotation keeps drawing at it, because that is the rotation the position
    file states and a picture that disagrees with the file is worse than one
    sited approximately.
    """
    canvas, notes, remap = model_to_canvas(reference, mesh)
    if not canvas:
        raise ValueError(f"{part}: the model carries no triangles; the client "
                         f"should have reported an absence")
    if datum is not None:
        dx, dy = datum
    else:
        # NOTHING PINS THE VENDOR'S FRAME TO OURS, so fall back to the siting
        # the model has ALREADY been given rather than inventing a second rule:
        # its own bounding-box centre, which link 1 put on the vendor's OUTLINE
        # centre — the datum that held on every payload measured — or, on a
        # payload that draws no outline, wherever link 1 could site it, having
        # said so. What is NOT used is the canvas ORIGIN, the value that did not
        # hold: stale on six of twenty-five, once by 861 mm, so laying THAT on
        # our footprint origin could throw a part clean off the board. The
        # rotation below is untouched.
        x0, y0, x1, y1 = _bbox(canvas)
        mx, my = po.rotate_ccw(((x0 + x1) / 2.0, (y0 + y1) / 2.0), offset_deg)
        dx, dy = -mx, -my
        notes = notes + (
            f"{NOTE_NO_DATUM}: the two drawings share no pad number, so the "
            f"vendor frame could not be pinned to ours; the model was centred "
            f"on our footprint origin and its ROTATION is unaffected",)
    points = []
    for cx, cy, h in canvas:
        lx, ly = po.rotate_ccw((cx, cy), offset_deg)
        points.append((lx + dx, ly + dy, h))
    triangles = tuple((remap[a], remap[b], remap[c]) for a, b, c in mesh.triangles)
    return SeatedModel(
        part=part,
        uuid=reference.uuid,
        points=tuple(points),
        triangles=triangles,
        triangle_materials=tuple(mesh.triangle_materials),
        materials=mesh.materials,
        bbox=_bbox(points),
        height_mm=max(p[2] for p in points),
        notes=notes,
    )


# ---------------------------------------------------------------------------
# Extents and the two advisory checks
# ---------------------------------------------------------------------------


def _quarter_turns(degrees: float) -> int:
    """How many quarter turns a rotation is, or -1 when it is not one.

    Every extent here is an axis-aligned BOX, and a box turned by anything other
    than a multiple of 90 has no width and height to compare. Such a rotation is
    physically unorderable for a part anyway."""
    q = degrees / 90.0
    if abs(q - round(q)) > 1e-6:
        return -1
    return int(round(q)) % 4


def package_extent_local(reference: ModelReference, offset_deg: float,
                         ) -> Union[Point2, None]:
    """The vendor's stated package box ``(width, height)`` in OUR frame: model
    extents turned by ``c_rotation`` and then by the ledger offset. None when
    either angle is not a quarter turn."""
    vendor_turns = _quarter_turns(reference.rotation_deg[2])
    ledger_turns = _quarter_turns(offset_deg)
    if vendor_turns < 0 or ledger_turns < 0:
        return None
    w, h = reference.width_mm, reference.height_mm
    return (h, w) if (vendor_turns + ledger_turns) % 2 else (w, h)


def elongation(width: float, height: float) -> Union[str, None]:
    """``"x"``, ``"y"``, or None for a box too square to have a long axis."""
    if width <= 0 or height <= 0:
        return None
    if width >= height * SQUARE_RATIO:
        return "x"
    if height >= width * SQUARE_RATIO:
        return "y"
    return None


def crosswise(model_extent: Point2, pad_extent: Point2) -> Union[str, None]:
    """Does the seated model lie ACROSS our pad field?

    Returns ``"crosswise"`` when both boxes have a long axis and the axes are
    perpendicular — the ledger offset for this pair is wrong by a quarter turn,
    or the vendor rotated their model against their own drawing;
    :data:`INDETERMINATE` when either box is square, because a square part
    hides this defect completely; None when the two agree.
    """
    ours, theirs = elongation(*pad_extent), elongation(*model_extent)
    if ours is None or theirs is None:
        return INDETERMINATE
    return "crosswise" if ours != theirs else None


def extent_disagreement(package_extent: Union[Point2, None],
                        fab_extent: Union[Point2, None],
                        tolerance_mm: float = EXTENT_TOL_MM) -> Union[str, None]:
    """Does the vendor's package box look like OUR fab body box with its length
    and width SWAPPED?

    ``"disagrees"`` when the boxes differ by more than ``tolerance_mm`` AND the
    vendor's box turned a quarter fits ours better than it does as stated — the
    signature of a footprint authored from a datasheet with L and W read the
    wrong way round. A difference along one axis alone (vendor leads our fab
    outline does not draw) is NOT reported: it is ordinary, and reporting it
    would bury the swap under noise. :data:`INDETERMINATE` when either box is
    missing or the vendor's is square, because a swapped square is the same
    square; None when they agree.
    """
    if package_extent is None or fab_extent is None:
        return INDETERMINATE
    if elongation(*package_extent) is None:
        return INDETERMINATE
    as_stated = math.dist(package_extent, fab_extent)
    swapped = math.dist((package_extent[1], package_extent[0]), fab_extent)
    return "disagrees" if as_stated > tolerance_mm and swapped < as_stated else None
