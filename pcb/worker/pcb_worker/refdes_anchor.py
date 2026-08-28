"""WHERE a component's reference designator gets printed — the one derivation.

A designator ("R1", "SW2") is not in any IR: it is synthesized from the
component's ref by ``silk_source.refdes_strokes``. WHERE it goes is a separate
question with exactly two answers:

* the footprint AUTHORED a reference ``fp_text`` on F.SilkS — that placement is
  the answer, always, and nothing here touches it; or
* it did not, and the anchor must be DERIVED from the footprint's own body.

The derived answer used to be a single constant (``silk_source.
REFDES_LOCAL_Y_MM = -1.5``), which put the text 1.5 mm above the footprint
ORIGIN — inside the body of anything bigger than an 0805. A 6 x 6 mm tactile
switch got its designator printed under the switch, where it is invisible the
moment the part is soldered. This module replaces that constant with the rule
KiCad's own footprint authors follow by hand: the designator sits clear of the
part, centred just above the COURTYARD, which is the footprint's declared
"nothing else may be here" envelope.

THE RULE (footprint-LOCAL mm, board Y-DOWN so "above" is more negative Y):

    x = the occupied extent's x centre
    y = the occupied extent's top edge - CLEARANCE_MM - half the stroke width

``y`` is the text BASELINE, and ``board_font`` grows capitals UPWARD from the
baseline (cap top at ``-size``), so the text's own height carries it further
clear of the part rather than back into it — which is why the height does not
appear in the formula and why a centre-anchored font would need half of it
added here.

The anchor is footprint-LOCAL, so it costs nothing to make it rotate and mirror
with the part: every consumer already puts it through the component's placement
transform (``silk_source._place``), which turns it with the component's rotation
and mirrors it on the bottom side — and the courtyard it was measured against
turns and mirrors with it, so the clearance is preserved exactly.

WHAT "THE BODY" MEANS HERE. The anchor is measured against everything the
footprint OCCUPIES — its courtyard, its drawn outline (silk/fab) and its lands,
unioned. For a well-formed footprint that IS the courtyard, which contains the
rest by construction (a footprint's own body outline sitting inside its
courtyard is the KiCad convention, not a collision). The union is what keeps the
rule honest for the ones that are not: a seed socket footprint draws silk 1 mm
ABOVE its own courtyard, and a courtyard-only measurement would print the
designator straight through it. With no courtyard the union is simply the silk
and the lands; with nothing at all — no graphics, no pads — there is no body to
be clear of and the historical constant applies.

The panel's BODY BOX is a different question with a different answer
(``resolve._body_box``: courtyard first, else outline, else lands, one basis
only) — that box says "how big is this part", where this one says "what must
the text not print on". They share the point extractors below, not the rule.

TWO SHAPES, ONE RULE. The extent is measured from whichever of the two
footprint representations the caller holds — the parser's ``parsed`` dict (the
resolve/panel path) or a built ``FootprintDefinition`` (the compiled IR the
Gerber emitter and the DRC silk projection run on). Only the field names differ;
the box and the anchor are computed once, here, so the panel, the fab silk and
the DRC projection cannot drift apart.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Any, Iterable, Sequence, Union

from .footprint_def import (
    ArcGraphic,
    CircleGraphic,
    FootprintDefinition,
    LineGraphic,
    PolyGraphic,
    ReferenceTextDefinition,
)
from .geometry import rotation_radians
from .silk_source import (
    REFDES_TEXT_SIZE_MM,
    REFDES_LOCAL_Y_MM,
    SILK_TEXT_WIDTH_MM,
)

__all__ = [
    "COURTYARD_LAYERS",
    "OUTLINE_LAYERS",
    "CLEARANCE_MM",
    "LocalExtent",
    "body_extent_from_parsed",
    "occupied_extent_from_parsed",
    "occupied_extent_from_definition",
    "default_anchor",
    "anchor_dict_from_parsed",
    "effective_reference_text",
]

#: The declared body envelope. Both sides: a bottom-side footprint draws its
#: courtyard on B.CrtYd, and the anchor is measured in the footprint's own
#: local frame either way (the side flip happens at placement, not here).
COURTYARD_LAYERS = frozenset({"F.CrtYd", "B.CrtYd"})
#: The drawn body outline. Silk is the printed outline, fab the assembly
#: outline; neither is copper, so a footprint whose only extent is its lands
#: still measures as a body.
OUTLINE_LAYERS = frozenset({"F.SilkS", "B.SilkS", "F.Fab", "B.Fab"})

#: Gap between the body extent's top edge and the designator's INK, in mm.
#: Roughly KiCad's own hand-placed spacing, and comfortably above the silk
#: minimum width so the two strokes can never merge into one blob.
CLEARANCE_MM = 0.25


@dataclass(frozen=True)
class LocalExtent:
    """A footprint's body box in footprint-LOCAL mm (board Y-DOWN)."""

    min_x: float
    min_y: float
    max_x: float
    max_y: float

    @property
    def width(self) -> float:
        return self.max_x - self.min_x

    @property
    def height(self) -> float:
        return self.max_y - self.min_y

    @property
    def center_x(self) -> float:
        return (self.min_x + self.max_x) / 2.0

    @property
    def center_y(self) -> float:
        return (self.min_y + self.max_y) / 2.0


# ---------------------------------------------------------------------------
# The rule
# ---------------------------------------------------------------------------


def default_anchor(extent: Union[LocalExtent, None]) -> tuple[float, float]:
    """The DERIVED designator anchor for a footprint with no authored one.

    ``extent`` is what the footprint occupies (see
    :func:`occupied_extent_from_parsed` / :func:`occupied_extent_from_definition`);
    ``None`` means the footprint occupies nothing measurable and the historical
    constant applies. Returns the text BASELINE's footprint-local ``(x, y)``;
    the text size does not enter, because the glyphs grow upward from the
    baseline, away from the part (see the module docstring).
    """
    if extent is None:
        return 0.0, REFDES_LOCAL_Y_MM
    return (extent.center_x,
            extent.min_y - CLEARANCE_MM - SILK_TEXT_WIDTH_MM / 2.0)


def anchor_dict_from_parsed(parsed: dict) -> dict:
    """``{x_mm, y_mm, rotation_deg, size_mm, hidden}`` for a PARSED footprint.

    The wire shape the resolve step attaches to every component (and the panel
    strokes the live ref at). Always complete, so a renderer never has to guess
    which half was omitted: the footprint's own authored reference fp_text when
    it declares one, else the derived anchor above.
    """
    rt = parsed.get("reference_text") if isinstance(parsed, dict) else None
    if isinstance(rt, dict):
        return {
            "x_mm": float(rt["x_mm"]),
            "y_mm": float(rt["y_mm"]),
            "rotation_deg": float(rt.get("rotation_deg", 0.0)),
            "size_mm": float(rt.get("size_mm", REFDES_TEXT_SIZE_MM)),
            "hidden": bool(rt.get("hidden") or False),
        }
    x, y = default_anchor(occupied_extent_from_parsed(parsed))
    return {"x_mm": x, "y_mm": y, "rotation_deg": 0.0,
            "size_mm": REFDES_TEXT_SIZE_MM, "hidden": False}


def effective_reference_text(
        footprint: Union[FootprintDefinition, None]
) -> Union[ReferenceTextDefinition, None]:
    """The reference-text placement a SILK CONSUMER should draw *footprint*'s
    designator at: the authored one untouched, else the derived anchor as a
    synthetic :class:`ReferenceTextDefinition`.

    Returning the same type either way is what keeps ``silk_source.
    refdes_strokes`` a single code path — the emitter and the DRC projection ask
    this one question and place glyphs one way, so they cannot diverge. ``None``
    comes back only for a footprint with no body to measure, and means "use the
    module's own constant default", exactly as before.
    """
    if footprint is None:
        return None
    if footprint.reference_text is not None:
        return footprint.reference_text
    extent = occupied_extent_from_definition(footprint)
    if extent is None:
        return None
    x, y = default_anchor(extent)
    return ReferenceTextDefinition(position=(x, y), rotation_deg=0.0,
                                   size_mm=REFDES_TEXT_SIZE_MM, hidden=False)


# ---------------------------------------------------------------------------
# The extents, from either footprint representation
# ---------------------------------------------------------------------------


def _parsed_groups(parsed: Any) -> tuple[list, list, list]:
    if not isinstance(parsed, dict):
        return [], [], []
    graphics = parsed.get("graphics") or []
    return (_parsed_graphic_points(graphics, COURTYARD_LAYERS),
            _parsed_graphic_points(graphics, OUTLINE_LAYERS),
            _parsed_pad_points(parsed.get("pads") or []))


def occupied_extent_from_parsed(parsed: Any) -> Union[LocalExtent, None]:
    """Everything a PARSED footprint occupies, unioned — the box the designator
    must stay off. None when the footprint occupies nothing measurable."""
    courtyard, outline, pads = _parsed_groups(parsed)
    return _extent_of([*courtyard, *outline, *pads])


def body_extent_from_parsed(parsed: Any) -> Union[LocalExtent, None]:
    """The panel's BODY box basis: courtyard, else drawn outline, else lands.

    One basis, not a union — "how big is this part" is answered by the
    footprint's own declared envelope when it has one, and a courtyard is
    deliberately larger than the body it encloses.
    """
    return _first_extent(*_parsed_groups(parsed))


def occupied_extent_from_definition(
        footprint: Union[FootprintDefinition, None]) -> Union[LocalExtent, None]:
    """Everything a built :class:`FootprintDefinition` occupies, unioned."""
    if footprint is None:
        return None
    return _extent_of([
        *_definition_graphic_points(footprint.graphics, COURTYARD_LAYERS),
        *_definition_graphic_points(footprint.graphics, OUTLINE_LAYERS),
        *_definition_pad_points(footprint.pads),
    ])


def _first_extent(*groups: Iterable[tuple[float, float]]) -> Union[LocalExtent, None]:
    """The first point group that has a real extent, in precedence order.

    A group with no points, or whose points collapse to one spot, is not a body
    and falls through to the next — a single pad centre says nothing about how
    big the part is. A group with extent on ONE axis (a straight outline) is
    kept: it still says where the top edge is.
    """
    for points in groups:
        extent = _extent_of(points)
        if extent is not None:
            return extent
    return None


def _extent_of(points: Iterable[tuple[float, float]]) -> Union[LocalExtent, None]:
    xs: list[float] = []
    ys: list[float] = []
    for x, y in points:
        xs.append(x)
        ys.append(y)
    if not xs:
        return None
    extent = LocalExtent(min(xs), min(ys), max(xs), max(ys))
    if extent.width <= 0.0 and extent.height <= 0.0:
        return None
    return extent


def _num(value: Any) -> Union[float, None]:
    """A finite float, or None. Measurement is tolerant on purpose: a footprint
    with one unreadable coordinate still has a body worth measuring, and a
    designator anchor is not the place to refuse a board."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    out = float(value)
    return out if math.isfinite(out) else None


def _pair(raw: Any) -> Union[tuple[float, float], None]:
    if not isinstance(raw, (list, tuple)) or len(raw) < 2:
        return None
    x, y = _num(raw[0]), _num(raw[1])
    return None if x is None or y is None else (x, y)


def _parsed_graphic_points(graphics: Any,
                           layers: frozenset) -> list[tuple[float, float]]:
    """Every point the parsed graphics on *layers* contribute.

    An arc contributes its stored control points rather than its true swept
    extent: courtyards are drawn from lines and short fillet arcs, so the
    understatement is bounded by the fillet radius, and reconstructing swept
    extrema here would be a second arc implementation this box does not need.
    """
    points: list[tuple[float, float]] = []
    if not isinstance(graphics, list):
        return points
    for graphic in graphics:
        if not isinstance(graphic, dict) or graphic.get("layer") not in layers:
            continue
        if graphic.get("kind") == "circle":
            center = _pair(graphic.get("center"))
            radius = _num(graphic.get("radius"))
            if center is not None and radius is not None:
                points.extend(_circle_points(center, radius))
            continue
        for raw in (graphic.get("start"), graphic.get("end"),
                    *(graphic.get("points") or [])):
            point = _pair(raw)
            if point is not None:
                points.append(point)
    return points


def _parsed_pad_points(pads: Any) -> list[tuple[float, float]]:
    """The turned corners of every parsed pad (``x_mm``/``y_mm``/``size``/
    ``rotation`` — ``footprints._parse_pad``'s shape)."""
    points: list[tuple[float, float]] = []
    if not isinstance(pads, list):
        return points
    for pad in pads:
        if not isinstance(pad, dict):
            continue
        x, y = _num(pad.get("x_mm")), _num(pad.get("y_mm"))
        if x is None or y is None:
            continue
        size = pad.get("size")
        width = height = 0.0
        if isinstance(size, (list, tuple)) and len(size) >= 2:
            width = _num(size[0]) or 0.0
            height = _num(size[1]) or 0.0
        points.extend(_pad_corners(x, y, width / 2.0, height / 2.0,
                                   _num(pad.get("rotation")) or 0.0))
    return points


def _definition_graphic_points(graphics: Sequence[Any],
                               layers: frozenset) -> list[tuple[float, float]]:
    points: list[tuple[float, float]] = []
    for graphic in graphics:
        if graphic.layer.id not in layers:
            continue
        if isinstance(graphic, LineGraphic):
            points.extend((graphic.a, graphic.b))
        elif isinstance(graphic, CircleGraphic):
            points.extend(_circle_points(graphic.center, graphic.radius_mm))
        elif isinstance(graphic, ArcGraphic):
            points.extend((graphic.start, graphic.mid, graphic.end))
        elif isinstance(graphic, PolyGraphic):
            points.extend(graphic.points)
    return points


def _definition_pad_points(pads: Sequence[Any]) -> list[tuple[float, float]]:
    points: list[tuple[float, float]] = []
    for pad in pads:
        x, y = pad.position
        width, height = pad.size if pad.size is not None else (0.0, 0.0)
        points.extend(_pad_corners(x, y, width / 2.0, height / 2.0,
                                   pad.rotation_deg))
    return points


def _circle_points(center: tuple[float, float],
                   radius: float) -> list[tuple[float, float]]:
    cx, cy = center
    return [(cx - radius, cy - radius), (cx + radius, cy + radius)]


def _pad_corners(x: float, y: float, half_w: float, half_h: float,
                 rotation_deg: float) -> list[tuple[float, float]]:
    """The four corners of one land, footprint-LOCAL.

    A land's own rotation turns it about its centre, so the box is measured from
    the TURNED corners: an axis-aligned ``+/- half_w, +/- half_h`` understates a
    rotated rectangle (a 45-degree land is ``(w + h) / sqrt(2)`` across). The
    angle goes through :func:`geometry.rotation_radians` — the pinned
    clockwise-in-a-Y-down-frame convention — so this box turns the way the
    emitters flash the land.
    """
    corners = [(-half_w, -half_h), (half_w, -half_h),
               (half_w, half_h), (-half_w, half_h)]
    if not rotation_deg:
        return [(x + dx, y + dy) for dx, dy in corners]
    theta = rotation_radians(rotation_deg)
    cos_t, sin_t = math.cos(theta), math.sin(theta)
    return [(x + dx * cos_t - dy * sin_t, y + dx * sin_t + dy * cos_t)
            for dx, dy in corners]
