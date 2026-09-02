"""WHERE a component's reference designator gets printed — the one derivation.

A designator ("R1", "SW2") is not in any IR: it is synthesized from the
component's ref by ``silk_source.refdes_strokes``. WHERE it goes is a separate
question, and there is ONE precedence rule for it everywhere:

1. the BOARD authored a placement for this component — the optional
   ``refdes_placement`` block (:data:`COMPONENT_REFDES_KEY`), set through
   ``minerva_pcb_set_refdes``. It wins over everything, because it is the only
   one of the three that somebody chose;
2. else the footprint AUTHORED a reference ``fp_text`` on F.SilkS — that
   placement is the answer and nothing here touches it;
3. else the anchor is DERIVED from the footprint's own body.

``refdes_placement`` is a PARTIAL overlay, not a replacement: a block stating
only ``hidden`` (or only ``x_mm``) keeps rules 2/3's answer for every field it
does not state, which is what makes "hide just this one designator" a one-key
edit. The panel verb validates and stores a partial write the same way.

THE DERIVED ANCHOR (footprint-LOCAL mm, board Y-DOWN so "above" is more
negative Y):

    x = the occupied extent's x centre
    y = the occupied extent's top edge - CLEARANCE_MM - half the stroke width

``y`` is the text BASELINE, and ``board_font`` grows capitals UPWARD from it
(cap top at ``-size``), so the text's own height carries it further clear of
the part rather than back into it — which is why the height is not in the
formula, and why a centre-anchored font would need half of it added here.

The anchor is footprint-LOCAL, so every consumer puts it through the
component's placement transform (``silk_source._place``): it turns with the
component's rotation and mirrors on the bottom side, and so does the body it
was measured against, so the clearance is preserved exactly.

WHAT "THE BODY" MEANS HERE: everything the footprint OCCUPIES — its courtyard,
its drawn outline (silk/fab) and its lands, UNIONED. A graphic occupies its
INK, not its centreline: the box is grown by half the stroke width on every
side, and an arc or circle contributes the extent its sweep really reaches (a
bowed arc reaches past both of its endpoints). For a well-formed
footprint that is the courtyard, which contains the rest by construction (a
footprint's own outline inside its own courtyard is the KiCad convention, not a
collision). The union is what keeps the rule honest for the ones that are not:
a footprint drawing silk 1 mm ABOVE its own courtyard would otherwise have the
designator printed straight through it. With no graphics and no pads at all
there is no body to be clear of, and ``silk_source.REFDES_LOCAL_Y_MM`` applies.

The panel's BODY BOX is a different question with a different answer
(:func:`body_extent_from_parsed`: courtyard first, else outline, else lands,
one basis only) — that box says "how big is this part", this one says "what
must the text not print on". They share the point extractors below, not the
rule.

TWO SHAPES, ONE RULE. The extent is measured from whichever footprint
representation the caller holds — the parser's ``parsed`` dict (the
resolve/panel path) or a built ``FootprintDefinition`` (the compiled IR the
Gerber emitter and the DRC silk projection run on). Only the field names
differ; the box and the anchor are computed once, here, so the panel, the fab
silk and the DRC projection cannot drift apart.
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
from .geometry import rotate_local_offset, rotation_radians
from .silk_source import (
    REFDES_TEXT_SIZE_MM,
    REFDES_LOCAL_Y_MM,
    SILK_GRAPHIC_WIDTH_MM,
    SILK_TEXT_WIDTH_MM,
    graphic_width,
)
# The arc solve is BORROWED, not re-derived: silk_source._circumcenter is the
# circle every arc consumer (the silk emitter, the Gerber harvest) already draws
# an arc on, so a swept extent measured here cannot disagree with the ink that
# actually gets printed. gerber.py aliases the same private helper.
from .silk_source import _circumcenter

__all__ = [
    "COURTYARD_LAYERS",
    "OUTLINE_LAYERS",
    "CLEARANCE_MM",
    "COMPONENT_REFDES_KEY",
    "LocalExtent",
    "body_extent_from_parsed",
    "occupied_extent_from_parsed",
    "occupied_extent_from_definition",
    "body_extent_from_definition",
    "courtyard_extent_from_definition",
    "fab_extent_from_definition",
    "land_extent_from_definition",
    "placed_land_extent",
    "default_anchor",
    "anchor_dict_from_parsed",
    "anchor_dict_from_component",
    "authored_placement",
    "effective_reference_text",
    "component_reference_text",
    "loose_reference_text",
]

#: The declared body envelope. Both sides: a bottom-side footprint draws its
#: courtyard on B.CrtYd, and the anchor is measured in the footprint's own
#: local frame either way (the side flip happens at placement, not here).
COURTYARD_LAYERS = frozenset({"F.CrtYd", "B.CrtYd"})
#: The drawn body outline. Silk is the printed outline, fab the assembly
#: outline; neither is copper, so a footprint whose only extent is its lands
#: still measures as a body.
OUTLINE_LAYERS = frozenset({"F.SilkS", "B.SilkS", "F.Fab", "B.Fab"})

#: The ASSEMBLY drawing alone — the fab layers, without the printed silk.
#: Silk is deliberately asymmetric (a cathode bar, a pin-1 dot, a polarity
#: chevron), so a box measured over it is off the part it draws; measured over
#: this library, ``D_SMA``'s silk box centre sits 3.05 mm from its fab box
#: centre. Fab carries the body and nothing else, which is what makes it the
#: basis for a question about where the part's middle IS rather than about what
#: must not be printed on.
FAB_LAYERS = frozenset({"F.Fab", "B.Fab"})

#: The per-component key a BOARD authors its designator placement under. Not a
#: derived key: the Go codec models it as a typed component field
#: (``Component.RefdesPlacement``) and carries it verbatim. Named so
#: it cannot be mistaken for the wire's ``refdes_anchor``, which is the
#: EFFECTIVE placement a resolve computed and is session state on both sides.
COMPONENT_REFDES_KEY = "refdes_placement"

#: Gap between the body extent's top edge and the designator's INK, in mm.
#: Roughly KiCad's own hand-placed spacing, and comfortably above the silk
#: minimum width so the two strokes can never merge into one blob.
CLEARANCE_MM = 0.25


@dataclass(frozen=True)
class LocalExtent:
    """An axis-aligned box in millimetres, board Y-DOWN.

    Footprint-LOCAL for every measurement taken off a footprint, which is all
    of them but :func:`placed_land_extent` — the box carries no frame of its
    own, only the frame its points were measured in.
    """

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
# The AUTHORED placement, and the one precedence rule over it
# ---------------------------------------------------------------------------


def authored_placement(comp: Any) -> Union[dict, None]:
    """The raw ``refdes_placement`` block a board component states, or None.

    Only "did the board say anything" is answered here — the FIELDS are read by
    :func:`_overlay`, which is tolerant per field. A block that is present but
    not a mapping is treated as absent rather than raised on: the panel is the
    validating writer (``ui/model/pcb_refdes_anchor.gd`` refuses a bad write by
    name before it ever reaches a document), and a hand-typed YAML typo must not
    make a board unfabricable over the placement of one legend glyph.
    """
    if not isinstance(comp, dict):
        return None
    block = comp.get(COMPONENT_REFDES_KEY)
    return block if isinstance(block, dict) else None


def _overlay(base: dict, authored: dict) -> dict:
    """*base* with every field *authored* states VALIDLY replaced.

    Per-field, so a partial block (the common one is ``{hidden: true}``) keeps
    the library/derived answer for everything it leaves out. An unreadable
    field value keeps the base value rather than failing the board — see
    :func:`authored_placement` for why this reader is the tolerant end.
    """
    out = dict(base)
    for key in ("x_mm", "y_mm", "rotation_deg"):
        value = _num(authored.get(key))
        if value is not None:
            out[key] = value
    size = _num(authored.get("size_mm"))
    if size is not None and size > 0.0:
        out["size_mm"] = size
    hidden = authored.get("hidden")
    if isinstance(hidden, bool):
        out["hidden"] = hidden
    return out


def _anchor_dict(text: Union[ReferenceTextDefinition, None]) -> dict:
    """A complete anchor dict for *text*, or the historical constant for None."""
    if text is None:
        return {"x_mm": 0.0, "y_mm": REFDES_LOCAL_Y_MM, "rotation_deg": 0.0,
                "size_mm": REFDES_TEXT_SIZE_MM, "hidden": False}
    return {"x_mm": float(text.position[0]), "y_mm": float(text.position[1]),
            "rotation_deg": float(text.rotation_deg),
            "size_mm": float(text.size_mm), "hidden": bool(text.hidden)}


def _reference_text(anchor: dict) -> ReferenceTextDefinition:
    return ReferenceTextDefinition(
        position=(anchor["x_mm"], anchor["y_mm"]),
        rotation_deg=anchor["rotation_deg"], size_mm=anchor["size_mm"],
        hidden=anchor["hidden"])


def anchor_dict_from_component(comp: Any, parsed: dict) -> dict:
    """The EFFECTIVE anchor dict for one board component — the wire shape.

    :func:`anchor_dict_from_parsed` answers rules 2/3 (the footprint's own
    fp_text, else the derived anchor); this overlays rule 1, the board's own
    ``refdes_placement``. The resolve step sends this, so the panel draws the
    designator exactly where the fab will print it whoever placed it.
    """
    base = anchor_dict_from_parsed(parsed)
    authored = authored_placement(comp)
    return base if authored is None else _overlay(base, authored)


def anchor_dict_from_definition(
        comp: Any, footprint: Union[FootprintDefinition, None]) -> dict:
    """The wire anchor for a component measured on a BUILT definition — the
    representation compile_board holds. Same precedence as
    :func:`anchor_dict_from_component`, so a component whose geometry the board
    owns gets, on the wire, exactly the anchor the emitters print at."""
    return _anchor_dict(component_reference_text(comp, footprint))


def component_reference_text(
        comp: Any, footprint: Union[FootprintDefinition, None]
) -> Union[ReferenceTextDefinition, None]:
    """The placement a SILK CONSUMER should draw one COMPONENT's designator at
    — the whole precedence rule, from the component dict and its footprint.

    The sibling of :func:`effective_reference_text`, which answers the same
    question for a footprint with no component in hand. Returning ``None`` for
    "nothing authored anywhere and no body to measure" is preserved exactly:
    ``silk_source.refdes_strokes`` reads None as its own constant default, and
    turning that into a synthetic placement here would move every golden for a
    bodyless footprint while changing no ink.

    The board's placement is per COMPONENT, so it cannot live on the footprint
    definition: definitions are interned by content id and two components
    sharing a footprint would otherwise fork it into two, moving footprint_id —
    the identity the library lock and the BOM group by.
    """
    base = effective_reference_text(footprint)
    authored = authored_placement(comp)
    if authored is None:
        return base
    return _reference_text(_overlay(_anchor_dict(base), authored))


def loose_reference_text(comp: Any) -> Union[ReferenceTextDefinition, None]:
    """The same answer for a consumer holding only the LOOSE board dict.

    The KiCad export runs on a resolved loose-dict board rather than the IR, so
    rules 2/3 reach it already computed, as the ``refdes_anchor`` the resolve
    step attached (:func:`anchor_dict_from_component`). This overlays the
    board's authored block on top of it, and returns None when there is neither
    — the same "use the constant default" signal the IR path returns.
    """
    wire = comp.get("refdes_anchor") if isinstance(comp, dict) else None
    base = _anchor_dict(None)
    if isinstance(wire, dict):
        base = _overlay(base, wire)
    authored = authored_placement(comp)
    if authored is None and not isinstance(wire, dict):
        return None
    if authored is not None:
        base = _overlay(base, authored)
    return _reference_text(base)


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


def courtyard_extent_from_definition(
        footprint: Union[FootprintDefinition, None]) -> Union[LocalExtent, None]:
    """The KEEP-OUT envelope a built :class:`FootprintDefinition` declares —
    its courtyard alone, in footprint-LOCAL mm. None when it declares none.

    A courtyard is drawn deliberately larger than the part, so this is the box
    that answers "would this ink disappear under the neighbour", while
    :func:`body_extent_from_definition` answers "under its OWN component".
    """
    if footprint is None:
        return None
    return _extent_of(_definition_graphic_points(footprint.graphics,
                                                 COURTYARD_LAYERS))


def body_extent_from_definition(
        footprint: Union[FootprintDefinition, None]) -> Union[LocalExtent, None]:
    """What a built :class:`FootprintDefinition` PHYSICALLY covers once soldered:
    its drawn outline and its lands, with the COURTYARD deliberately left out.

    The sibling of :func:`occupied_extent_from_definition`, and the difference is
    the whole point. A courtyard is a keep-out envelope drawn larger than the
    part on purpose, so it is the right box to place a designator OUTSIDE of
    (which is what the default anchor does) and the wrong box to ask "is this
    ink going to end up under the component body". Legend inside the courtyard
    but clear of the body is still readable on the assembled board; legend
    inside the body is not.

    None when the footprint draws no outline and carries no sized land.
    """
    if footprint is None:
        return None
    return _extent_of([
        *_definition_graphic_points(footprint.graphics, OUTLINE_LAYERS),
        *_definition_pad_points(footprint.pads),
    ])


def fab_extent_from_definition(
        footprint: Union[FootprintDefinition, None]) -> Union[LocalExtent, None]:
    """The ASSEMBLY DRAWING's box for a built :class:`FootprintDefinition` — its
    fab-layer outline alone, in footprint-LOCAL mm. None when it draws none.

    The third sibling of :func:`occupied_extent_from_definition` (courtyard +
    outline + lands, "what must the text avoid") and
    :func:`body_extent_from_definition` (outline + lands, "what does the part
    cover once soldered"): this one answers "where did the footprint's author
    draw the component BODY", which is the only one of the three a nozzle
    centre can be measured from — see :data:`FAB_LAYERS`.
    """
    if footprint is None:
        return None
    return _extent_of(_definition_graphic_points(footprint.graphics, FAB_LAYERS))


def land_extent_from_definition(
        footprint: Union[FootprintDefinition, None]) -> Union[LocalExtent, None]:
    """The LANDS' box for a built :class:`FootprintDefinition` — every pad's
    turned corners, no graphics at all. None when it carries no sized land.

    The fallback basis for a footprint that draws no fab outline: the pads are
    where the part is soldered, so their box is the part's own footprint even
    when nobody drew its body.
    """
    if footprint is None:
        return None
    return _extent_of(_definition_pad_points(footprint.pads))


def placed_land_extent(pads: Sequence[Any]) -> Union[LocalExtent, None]:
    """The LANDS' box for pads already PLACED on a board — same turned-corner
    rule as :func:`land_extent_from_definition`, in BOARD millimetres.

    The third shape this module measures (see the docstring's TWO SHAPES, ONE
    RULE): ``resolved_board.PlacedPad`` carries the same three fields a
    footprint pad does — a centre, a size and its own rotation — already put
    through the component's placement transform, so the box comes out in the
    board's frame without re-composing anything. None when the pads carry no
    size, or collapse to a single spot.
    """
    return _extent_of(_definition_pad_points(pads))


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
    """The INK box corners of every parsed graphic on *layers*.

    Each graphic contributes the two corners of its own extent grown by HALF ITS
    STROKE WIDTH, because a plotted stroke is centred on the geometry and its
    ink reaches that much further on every side. Arcs and circles contribute the
    extent their SWEEP reaches rather than their stored control points: an arc
    bows away from its chord, by up to its full radius on a half turn, so the
    endpoint box can sit entirely inside the printed ink.
    """
    points: list[tuple[float, float]] = []
    if not isinstance(graphics, list):
        return points
    for graphic in graphics:
        if not isinstance(graphic, dict) or graphic.get("layer") not in layers:
            continue
        half = graphic_width(graphic) / 2.0
        kind = graphic.get("kind")
        if kind == "circle":
            center = _pair(graphic.get("center"))
            radius = _num(graphic.get("radius"))
            if center is not None and radius is not None:
                points.extend(_ink_corners(_circle_points(center, radius), half))
            continue
        if kind == "arc":
            points.extend(_ink_corners(_parsed_arc_points(graphic), half))
            continue
        drawn: list[tuple[float, float]] = []
        for raw in (graphic.get("start"), graphic.get("end"),
                    *(graphic.get("points") or [])):
            point = _pair(raw)
            if point is not None:
                drawn.append(point)
        points.extend(_ink_corners(drawn, half))
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
    """The compiled-IR twin of :func:`_parsed_graphic_points` — same ink box,
    same swept arc, only the field names differ."""
    points: list[tuple[float, float]] = []
    for graphic in graphics:
        if graphic.layer.id not in layers:
            continue
        half = _definition_width(graphic) / 2.0
        if isinstance(graphic, LineGraphic):
            drawn = [graphic.a, graphic.b]
        elif isinstance(graphic, CircleGraphic):
            drawn = _circle_points(graphic.center, graphic.radius_mm)
        elif isinstance(graphic, ArcGraphic):
            drawn = _arc_span_points(graphic.start, graphic.mid, graphic.end)
        elif isinstance(graphic, PolyGraphic):
            drawn = list(graphic.points)
        else:
            continue
        points.extend(_ink_corners(drawn, half))
    return points


def _definition_width(graphic: Any) -> float:
    """Stroke width of one compiled graphic — the same fallback
    :func:`silk_source.graphic_width` applies to the parsed dict form."""
    width = _num(getattr(graphic, "width_mm", None))
    return width if (width is not None and width > 0) else SILK_GRAPHIC_WIDTH_MM


def _ink_corners(points: Sequence[tuple[float, float]],
                 half_width: float) -> list[tuple[float, float]]:
    """The two opposite corners of *points*' box grown by *half_width*.

    Two corners are enough: every caller folds these into one min/max box, so a
    per-graphic box grown by its own stroke unions to exactly the ink box. Doing
    the growth per graphic rather than once at the end is what lets a thin
    courtyard and a thick outline each carry their own width.
    """
    if not points:
        return []
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    return [(min(xs) - half_width, min(ys) - half_width),
            (max(xs) + half_width, max(ys) + half_width)]


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


_TAU = 2.0 * math.pi


def _parsed_arc_points(graphic: dict) -> list[tuple[float, float]]:
    """The swept extent of one PARSED arc, in both forms
    ``footprints._parse_graphics`` produces: KiCad 6's centre/start plus an
    ``angle`` sweep, and KiCad 7/8's three ``points`` (start, mid, end).

    The legacy form is converted into the three-point one by turning its radius
    vector through half and all of the sweep. ``rotate_local_offset`` is the
    very turn ``silk_source._harvest_arc`` uses to find that arc's end, so the
    two cannot disagree about which arc was authored. An arc with neither a mid
    nor an angle is underspecified and draws as its chord — the same
    approximation the emitter makes, warned about there.
    """
    pts = [p for p in (_pair(raw) for raw in (graphic.get("points") or []))
           if p is not None]
    angle = _num(graphic.get("angle"))
    if angle is not None and angle != 0.0 and len(pts) >= 2:
        (ccx, ccy), (sx, sy) = pts[0], pts[1]
        vx, vy = sx - ccx, sy - ccy
        if vx == 0.0 and vy == 0.0:
            return []
        if abs(angle) >= 360.0:
            # A closed sweep: the three-point solve below degenerates (start and
            # end coincide, so there is no circumcircle), and the shape is a
            # circle anyway.
            return _circle_points((ccx, ccy), math.hypot(vx, vy))
        mx, my = rotate_local_offset(vx, vy, angle / 2.0)
        ex, ey = rotate_local_offset(vx, vy, angle)
        return _arc_span_points((sx, sy), (ccx + mx, ccy + my),
                                (ccx + ex, ccy + ey))
    if len(pts) >= 3:
        return _arc_span_points(pts[0], pts[1], pts[2])
    return pts


def _arc_span_points(start: tuple[float, float], mid: tuple[float, float],
                     end: tuple[float, float]) -> list[tuple[float, float]]:
    """*start*, *end*, and every axis extremum the arc through the three points
    actually sweeps through.

    An arc's bounding box is its endpoints plus whichever of the four cardinal
    points of its circle fall inside the sweep — between two cardinals the
    circle is monotone on both axes, so nothing else can be extremal. Both the
    circle and the sweep DIRECTION come from ``silk_source._circumcenter``,
    which returns the circumcentre together with twice the signed area of
    start->mid->end; that sign says whether the turn runs in the increasing- or
    decreasing-angle direction of this frame.

    Collinear or coincident control points describe a line rather than an arc
    (the emitter draws them as one), and are then their own whole extent.
    """
    solved = _circumcenter(start, mid, end)
    if solved is None:
        return [start, mid, end]
    (cx, cy), d = solved
    radius = math.hypot(start[0] - cx, start[1] - cy)
    begin = math.atan2(start[1] - cy, start[0] - cx)
    sign = 1.0 if d > 0 else -1.0
    span = (sign * (math.atan2(end[1] - cy, end[0] - cx) - begin)) % _TAU

    def _on(angle: float) -> tuple[float, float]:
        return cx + radius * math.cos(angle), cy + radius * math.sin(angle)

    points = [_on(begin), _on(begin + sign * span)]
    for quarter in range(4):
        angle = quarter * (math.pi / 2.0)
        if (sign * (angle - begin)) % _TAU <= span:
            points.append(_on(angle))
    return points


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
