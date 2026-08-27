"""ONE predicate: does this piece of copper JOIN that piece of copper?

Every question of the form "is this trace end landed on the pad", "is this run
driven across the pad", "is this end still free to draw from" is the SAME
question — copper reaching copper — and it is answered here, once, so the DRC,
the trace verbs and the connectivity census cannot give three answers about one
board.

THE MODEL. A :class:`ContactNode` is one connected piece of copper, reduced to
a set of layers plus a set of exact-or-superset SHAPES. Nothing else about the
copper survives into the predicate: a pad, a trace segment, a via and (next) a
zone's filled region differ only in which builder made the node. Adding a
conductor kind is therefore a new BUILDER, never a new predicate — the whole
point of the shape.

THE MEASURE is edge to edge, through :mod:`drc_geom_primitives`. A trace
segment is its swept width (the centreline stadium), NOT its centreline: a
1.0mm run whose end sits 0.35mm off a pad centre covers that pad, and the
pad-centre distance the connectivity kernel used to compare says the opposite.
A pad is its land — the oriented rectangle, the true-radius roundrect, the
stadium, the disc — so an end anywhere ON the copper counts, including the
corner of a big exposed pad, and a run driven THROUGH a land counts too because
a stadium-to-land distance does not care which part of the run is nearest.

THE FAIL-SAFE DIRECTION IS THE OPPOSITE OF THE CLEARANCE DRC'S. A clearance
check must never under-state copper, so :func:`ir_pads.pad_land` models a
roundrect by its bounding rectangle (extra copper is safe there). A CONTACT
check must never OVER-state copper: modelled overhang would credit a join that
the fabricated board does not have, which deletes a real open. So the shapes
built here are EXACT wherever the source states enough to be exact, and the
roundrect keeps its corner radius rather than being boxed.

A PAD WHOSE LAND IS UNKNOWN — an inline pin with no size, the loose-dict
fallback — has no geometry to be exact about. It is modelled as a disc of the
board's coincidence tolerance about the pad centre, which is precisely the
credit the centreline kernel has always given such a pad. Expressed as a shape
rather than as a second code path, so there is still ONE predicate.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Any

from .drc_geom_primitives import (
    EPS,
    AABB,
    Capsule,
    OrientedRect,
    Polygon,
    RoundedRect,
    convex_edge_distance,
    polygon_edge_distance,
)
from .geometry import rotate_local_offset

#: How much float noise counts as "the same copper", in mm. One micron: far
#: below any gap a fabricator can etch and far above the rounding error of
#: mm-quantized board coordinates. The GDScript side spells this
#: ``PcbCopperContact.TOUCH_EPS_MM`` and the two MUST stay equal — the shared
#: vectors under ``pcb/spec/contact`` are what proves they do.
TOUCH_EPS_MM = 1e-3

#: Node kinds. ``ZONE_REGION`` is one FILLED pour region, a conductor like any
#: other. ``NO_COPPER`` is the one node that joins nothing at all — see
#: :func:`no_copper_node`.
PAD = "pad"
TRACE_SEG = "trace_seg"
VIA = "via"
ZONE_REGION = "zone_region"
NO_COPPER = "no_copper"


@dataclass(frozen=True)
class ContactNode:
    """One connected piece of copper.

    ``layers`` is the canonical copper-layer set the piece occupies, or None
    when it spans the stack / is unknown — None meets everything, because
    inventing a separation is the one error that turns a real join into a false
    open. ``shapes`` are :mod:`drc_geom_primitives` primitives; they are OR-ed
    (the node is their union), so a conductor needing several is just a longer
    tuple.
    """

    kind: str
    layers: frozenset[str] | None
    shapes: tuple[Any, ...]
    aabb: AABB


def layers_meet(a: ContactNode, b: ContactNode) -> bool:
    if a.layers is None or b.layers is None:
        return True
    return not a.layers.isdisjoint(b.layers)


def _shape_gap(s1: Any, s2: Any) -> float:
    """Edge-to-edge millimetres between two primitives, negative when they
    overlap is NOT promised — the kernel clamps at 0 for overlapping shapes,
    which is all a contact test needs.

    TWO KERNELS, chosen by shape family. A pour region is a ring that clearance
    carving and void fracturing both make CONCAVE, which the convex kernel
    cannot measure, so it carries its own; everything else is convex. This is
    the branch the predicate above never has to grow."""
    if isinstance(s1, Polygon):
        return polygon_edge_distance(s1, s2)
    if isinstance(s2, Polygon):
        return polygon_edge_distance(s2, s1)
    return convex_edge_distance(s1, s2)


def node_gap(a: ContactNode, b: ContactNode) -> float:
    """Smallest edge-to-edge distance between the two pieces, in mm. ``inf``
    when they share no layer — copper on different layers has no gap to
    measure, it simply is not the same conductor."""
    if not a.shapes or not b.shapes:
        return math.inf   # a node with no copper has no gap to measure
    if not layers_meet(a, b):
        return math.inf
    if not _aabb_within(a.aabb, b.aabb, TOUCH_EPS_MM):
        return math.inf
    best = math.inf
    for s1 in a.shapes:
        for s2 in b.shapes:
            gap = _shape_gap(s1, s2)
            if gap < best:
                best = gap
                if best <= 0.0:
                    return 0.0
    return best


def nodes_touch(a: ContactNode, b: ContactNode) -> bool:
    """THE predicate: are these two pieces of copper one conductor?"""
    return node_gap(a, b) <= TOUCH_EPS_MM + EPS


def _aabb_within(a: AABB, b: AABB, slack: float) -> bool:
    """Cheap reject so the O(pads x segments) sweeps in :mod:`drc` stay cheap."""
    return not (a.min_x - slack > b.max_x or b.min_x - slack > a.max_x
                or a.min_y - slack > b.max_y or b.min_y - slack > a.max_y)


def _node(kind: str, layers: frozenset[str] | None,
          shapes: tuple[Any, ...]) -> ContactNode:
    box = shapes[0].aabb()
    for shape in shapes[1:]:
        box = box.union(shape.aabb())
    return ContactNode(kind=kind, layers=layers, shapes=shapes, aabb=box)


# ---------------------------------------------------------------------------
# Builders — one per conductor kind.
# ---------------------------------------------------------------------------


def segment_node(a: tuple[float, float], b: tuple[float, float],
                 width_mm: float, layer: str | None) -> ContactNode:
    """A trace segment as its SWEPT COPPER: the centreline stadium. A width of
    zero degenerates to the bare centreline, which is what a board that states
    no width gets — never a guessed width."""
    half = max(float(width_mm), 0.0) / 2.0
    layers = None if not layer else frozenset({layer})
    return _node(TRACE_SEG, layers, (Capsule(a[0], a[1], b[0], b[1], half),))


def endpoint_node(pt: tuple[float, float], width_mm: float,
                  layer: str | None) -> ContactNode:
    """The copper AT one end of a run: the round cap of the swept width.

    Distinct from :func:`segment_node` on purpose. "Is this END landed?" must
    not be answered by copper at the OTHER end of the same segment, which is
    exactly what measuring the whole stadium would do."""
    half = max(float(width_mm), 0.0) / 2.0
    layers = None if not layer else frozenset({layer})
    return _node(TRACE_SEG, layers, (Capsule.disc(pt[0], pt[1], half),))


def via_node(pt: tuple[float, float], diameter_mm: float,
             layers: frozenset[str] | None) -> ContactNode:
    return _node(VIA, layers,
                 (Capsule.disc(pt[0], pt[1], max(float(diameter_mm), 0.0) / 2.0),))


def region_node(shapes: tuple[Any, ...],
                layers: frozenset[str] | None) -> ContactNode:
    """One FILLED pour region as one conductor.

    The shapes are the region's rings (:class:`Polygon`), taken from the
    COMPILED fill and never from the authored outline: carving cuts one outline
    into regions that do not conduct to each other, so the outline would credit
    joins the copper does not make.
    """
    return _node(ZONE_REGION, layers, tuple(shapes))


def no_copper_node(pt: tuple[float, float]) -> ContactNode:
    """A land that is NOT copper, and so joins nothing.

    An UNPLATED through-hole is the case: a drilled mechanical hole. Its
    footprint pad still declares copper layers (KiCad writes ``*.Cu`` on an
    ``np_thru_hole`` line), and CAM plates nothing there — so a node built from
    those layers would bridge the whole stack through a hole with no barrel,
    which is the one error direction that deletes a real open.

    It is a NODE rather than a dropped pad because the pin still EXISTS: a board
    may name it on a net, and the honest report is "this pin's copper reaches
    nothing", not "this pin is absent". Empty shapes are what make it join
    nothing — :func:`node_gap` returns infinity for a node with no copper — and
    the empty layer set says the same thing a second way.
    """
    return ContactNode(kind=NO_COPPER, layers=frozenset(), shapes=(),
                       aabb=AABB(pt[0], pt[1], pt[0], pt[1]))


def pad_node(geom, centre: tuple[float, float], angle_deg: float,
             layers: frozenset[str] | None,
             unknown_land_radius_mm: float) -> ContactNode:
    """A pad's LAND, from the neutral pad-geometry owner
    (:class:`pad_source.PadGeom`) so a pad this predicate joins to and a pad the
    emitters fabricate are the same copper.

    ``centre`` is the land's BOARD position and ``angle_deg`` its BOARD angle,
    both already composed by the caller — this builder never re-derives a
    placement. ``unknown_land_radius_mm`` is the coincidence disc a pad with no
    stated copper size falls back to (see the module note).

    AN UNPLATED HOLE IS NOT A CONDUCTOR and comes back as
    :func:`no_copper_node`, whatever its footprint declares — see there.
    """
    from .pad_source import is_unplated_hole

    if is_unplated_hole(geom):
        return no_copper_node(centre)
    shape = _land_shape(geom, centre, angle_deg, unknown_land_radius_mm)
    return _node(PAD, layers, (shape,))


def _land_shape(geom, centre: tuple[float, float], angle_deg: float,
                unknown_land_radius_mm: float) -> Any:
    """The exact copper of one land, or the coincidence disc when the source
    states no usable size.

    A DRILLED pad's land is whatever :func:`pad_source.th_land` says — the same
    single authority the fab emitters ask — so a round annulus stays round and
    an oblong/authored-cornered land keeps its shape.
    """
    from .pad_source import is_through_hole, th_land

    angle = _board_angle_rad(angle_deg)
    cx, cy = centre

    if is_through_hole(geom):
        shaped, token, w, h, rratio = th_land(geom)
        if not shaped:
            dia = geom.annulus
            if dia is None or not math.isfinite(dia) or dia <= 0:
                return Capsule.disc(cx, cy, unknown_land_radius_mm)
            return Capsule.disc(cx, cy, float(dia) / 2.0)
        return _sized_shape(token, float(w), float(h), rratio, cx, cy, angle,
                            unknown_land_radius_mm)

    w, h = geom.width, geom.height
    if (w is None or h is None or not math.isfinite(w) or not math.isfinite(h)
            or w <= 0 or h <= 0):
        return Capsule.disc(cx, cy, unknown_land_radius_mm)
    return _sized_shape(geom.shape, float(w), float(h), geom.corner_rratio,
                        cx, cy, angle, unknown_land_radius_mm)


def _sized_shape(token: str, w: float, h: float, rratio: float | None,
                 cx: float, cy: float, angle: float,
                 unknown_land_radius_mm: float) -> Any:
    """A land of known size as its EXACT copper. An unrecognised shape token
    falls back to the oriented rectangle of the stated size — the family every
    modelled land is inscribed in, which for a CONTACT test is the permissive
    direction and so is reported honestly here rather than silently."""
    token = (token or "rect").strip().lower()
    if w <= 0 or h <= 0:
        return Capsule.disc(cx, cy, unknown_land_radius_mm)
    if token == "circle":
        return Capsule.disc(cx, cy, w / 2.0)
    if token == "oval":
        radius = min(w, h) / 2.0
        extent = max(w, h) / 2.0 - radius
        # The long axis lies along the land's own x when it is the wider side.
        dx, dy = ((extent * math.cos(angle), extent * math.sin(angle))
                  if w >= h else
                  (-extent * math.sin(angle), extent * math.cos(angle)))
        return Capsule(cx - dx, cy - dy, cx + dx, cy + dy, radius)
    if token == "roundrect" and rratio is not None:
        radius = max(min(float(rratio), 0.5), 0.0) * min(w, h)
        if radius > 0.0:
            return RoundedRect(cx, cy, w / 2.0, h / 2.0, radius, angle)
    return OrientedRect(cx, cy, w / 2.0, h / 2.0, angle)


def _board_angle_rad(angle_deg: float) -> float:
    """A KiCad placement angle as the CCW radians the shape primitives take.

    Derived by turning the local +x axis through the SHARED placement rotation
    (:func:`geometry.rotate_local_offset`, the KiCad clockwise convention) and
    reading the result's direction, rather than by writing a sign here. A land's
    BODY and a land's OFFSET then turn by one operator, so no future change to
    the placement convention can rotate one without the other.
    """
    if not angle_deg:
        return 0.0
    ux, uy = rotate_local_offset(1.0, 0.0, float(angle_deg))
    return math.atan2(uy, ux)
