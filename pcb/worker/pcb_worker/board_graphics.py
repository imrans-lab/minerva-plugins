"""Board-LEVEL graphics: the owner that board text and free silk hang off.

THE GAP THIS CLOSES
-------------------
Every graphic primitive this codebase had was owned by a COMPONENT. A footprint
carries silk, a component carries its designator, and both are placed by that
component's transform. There was no way to say "this artwork belongs to the
board" — so a copyright line on the back of smart-remote-v2 was authored as 65
hand-written B.SilkS polylines hung off TP1, a 1206 test point at (8, 30), with
every point in ABSOLUTE board coordinates that the component's own placement
would have corrupted the moment anyone moved it. The geometry was right only
because nothing ever touched TP1.

``ResolvedBoard.board_graphics`` and :class:`~resolved_board.BoardGraphic` have
existed since the IR was written, but nothing populated them: ``compile_board``
hardcoded ``board_graphics=()`` and listed ``board_graphics`` among the keys it
REFUSES, while both emitters raised on a non-empty tuple. This module is what
makes the slot real, the same way ``_build_zones`` and ``_build_outline`` made
zones and cutouts real before it.

TEXT IS PROVENANCE, NOT BAKED GEOMETRY
--------------------------------------
A ``kind: text`` entry stores WHAT THE TEXT SAYS — string, anchor, size,
rotation — and never its strokes. The strokes are DERIVED here, from
:mod:`board_font`, on every compile.

That is the whole point of the feature. Baking strokes into the board source is
precisely what the hand-authored workaround did, and it has three failure modes
this avoids: the YAML is unreadable and un-editable (fixing a typo means
regenerating 65 polylines), the baked geometry silently goes stale if the font
is ever corrected, and nothing can tell you what the legend SAYS without an OCR
pass over line segments. One line of YAML now carries what 700 lines carried
before, and it is the line a human would have written.

The panel derives the same strokes from the same table for display (see
``ui/model/pcb_board_font_data.gd``), so what the editor draws and what the fab
receives come from one authored source.

ONE YAML ENTRY, N IR PRIMITIVES
-------------------------------
A string is many disjoint strokes but ONE thing a user made, selects and
deletes. So a text entry keeps ONE minted ``graphic:<32hex>`` id at the source
level and expands to N :class:`BoardGraphic` IR entries whose ids are derived
(``<id>#<k>``). Derived ids are internal — they exist because the IR requires
per-primitive identity for diagnostics, and they are never minted, persisted or
shown to a caller. Delete-by-id and undo operate on the source id alone.

LAYERS ARE FAIL-CLOSED
----------------------
Silk and courtyard only. Copper is refused rather than drawn: board-level copper
would be unconnected metal that routing and DRC would have to reason about as an
obstacle with no net, and ``drc_geometric``/``route_bridge`` already treat a
copper board graphic as ``unsupported_geometry``. Edge.Cuts is refused because
the board profile has an owner already (``_build_outline`` / ``cutouts``); a
second way to draw the rim is a second answer to "how big is this board".
"""
from __future__ import annotations

from typing import Any

from . import board_font
from .geometry import place_point
from .resolved_board import (
    BoardGraphic,
    CircleGeometry,
    Layer,
    LayerRole,
    LineGeometry,
    PolygonGeometry,
    PolylineGeometry,
    Side,
    SourceRef,
    EntityKind,
)

__all__ = [
    "ALLOWED_ROLES",
    "DEFAULT_TEXT_WIDTH_MM",
    "DEFAULT_GRAPHIC_WIDTH_MM",
    "DEFAULT_TEXT_SIZE_MM",
    "GRAPHIC_KINDS",
    "text_polylines",
    "text_bounds",
    "build_board_graphics",
]

#: Board graphics are legend and keep-out documentation, never copper and never
#: the board rim. See the module docstring for why each exclusion is fail-closed.
ALLOWED_ROLES = frozenset({LayerRole.SILK, LayerRole.COURTYARD})

#: Widths default to the SAME constants component silk uses, read from
#: silk_source rather than restated, so a board legend and a footprint legend
#: cannot end up on different floors. Imported lazily inside the functions that
#: need them to keep this module's import graph as small as silk_source's own.
DEFAULT_TEXT_WIDTH_MM = 0.15
DEFAULT_GRAPHIC_WIDTH_MM = 0.15
#: Cap height of a text entry that does not say. 1.0 mm matches
#: ``silk_source.REFDES_TEXT_SIZE_MM`` so unspecified board text reads the same
#: size as a designator.
DEFAULT_TEXT_SIZE_MM = 1.0

GRAPHIC_KINDS = ("text", "line", "circle", "poly", "polyline", "rect")


def _num(value: Any, default: float | None = None) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return default
    out = float(value)
    return out if out == out and abs(out) != float("inf") else default


def _point_pair(value: Any) -> tuple[float, float] | None:
    """One point in the canonical BOARD-LEVEL shape, ``{"x_mm":, "y_mm":}``.

    STRICTLY that shape, and not the bare ``[x, y]`` pair component graphics
    use, because this collection is typed on the Go side (``board.Graphic``)
    and Go decodes ``Points []Point`` from the ``x_mm``/``y_mm`` mapping alone.
    Accepting a superset here would mean a board that parses in the worker and
    is REFUSED by the codec that gates every load — the exact validator drift
    yaml.go's ``entityListKeys`` invariant is written to prevent. Every other
    board-level collection (trace points, zone and cutout outlines, via and hole
    positions) already uses this shape, so board graphics match their
    neighbours rather than their component-hung cousins.
    """
    if not isinstance(value, dict):
        return None
    x, y = _num(value.get("x_mm")), _num(value.get("y_mm"))
    return None if x is None or y is None else (x, y)


def _anchor(entry: dict) -> tuple[float, float] | None:
    """The anchor of a text entry, accepting the nested ``position`` mapping the
    MCP verb takes as well as flat ``x_mm``/``y_mm``."""
    if "position" in entry:
        return _point_pair(entry.get("position"))
    return _point_pair(entry)


def text_polylines(text: str, x_mm: float, y_mm: float, *, size_mm: float,
                   rotation_deg: float = 0.0, mirror: bool = False,
                   h_align: str = "left"
                   ) -> tuple[tuple[tuple[float, float], ...], ...]:
    """*text* rendered to BOARD-ABSOLUTE open stroke polylines.

    Two steps, in this order and no other: :func:`board_font.render` produces
    glyph-local strokes (mirroring them in the text's own frame when *mirror*),
    then ``geometry.place_point`` applies the board placement. The rotation is
    NOT applied by the font — board geometry has exactly one rotation
    implementation, and this function is a caller of it like every other
    placement site.
    """
    rendered = board_font.render(text, size=size_mm, mirror=mirror, h_align=h_align)
    return tuple(
        tuple(place_point(x_mm, y_mm, rotation_deg, lx, ly) for lx, ly in stroke)
        for stroke in rendered.polylines
    )


def text_bounds(polylines) -> tuple[float, float, float, float] | None:
    """Axis-aligned (min_x, min_y, max_x, max_y) of placed strokes, or ``None``
    when there is nothing drawn. Reported by the authoring verbs so a caller can
    see where its legend landed without re-deriving the font."""
    pts = [p for stroke in polylines for p in stroke]
    if not pts:
        return None
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    return (min(xs), min(ys), max(xs), max(ys))


def _mirror_for(layer: Layer, entry: dict) -> bool:
    """Whether a text entry's glyphs are mirror-written.

    DERIVED FROM THE LAYER, not authored, because it is not a preference: a
    Gerber is plotted as seen from the top THROUGH the board, so back-side
    legend must be mirror-written in the file to read correctly once the board
    is flipped. Pinning it to the layer means a board cannot carry back text
    that reads backwards on the fab — the failure the hand-authored workaround
    had no guard against.

    An explicit ``mirror`` key is honoured when present so a deliberate
    exception (a "this side up" label meant to be read through a translucent
    substrate) stays expressible, but nothing authors it today.
    """
    if isinstance(entry.get("mirror"), bool):
        return bool(entry["mirror"])
    return layer.side is Side.BOTTOM


def _rect_points(entry: dict) -> tuple[tuple[float, float], ...] | None:
    """A ``rect`` entry's four corners, from either two opposite corners
    (``start``/``end``) or an origin plus a size."""
    start = _point_pair(entry.get("start"))
    end = _point_pair(entry.get("end"))
    if start is None or end is None:
        origin = _point_pair(entry.get("position")) or _point_pair(entry)
        w = _num(entry.get("width_mm"))
        h = _num(entry.get("height_mm"))
        if origin is None or w is None or h is None:
            return None
        start, end = origin, (origin[0] + w, origin[1] + h)
    x0, y0 = start
    x1, y1 = end
    if x0 == x1 or y0 == y1:
        return None
    return ((x0, y0), (x1, y0), (x1, y1), (x0, y1))


def build_board_graphics(board: dict, board_id: str, diags) -> tuple[BoardGraphic, ...]:
    """Compile the top-level ``board_graphics`` list into IR primitives.

    ``diags`` is the compiler's diagnostic sink; every refusal below is an
    ERROR, never a silent drop, because a board graphic is something a person
    deliberately placed. That is the opposite of ``silk_source``'s
    warn-and-drop ruling for FOOTPRINT silk, and deliberately so: footprint silk
    arrives in bulk from a vendored library nobody curated, while a board
    graphic is one authored object whose disappearance would be invisible.
    """
    raw = board.get("board_graphics")
    if raw is None:
        return ()
    if not isinstance(raw, list):
        diags.error("invalid_board_structure",
                    "board_graphics must be a list",
                    SourceRef(EntityKind.BOARD, board_id))
        return ()

    out: list[BoardGraphic] = []
    for ordinal, entry in enumerate(raw):
        ref = SourceRef(EntityKind.GRAPHIC, f"{board_id}:board_graphics[{ordinal}]")
        if not isinstance(entry, dict):
            diags.error("invalid_board_structure",
                        f"board_graphics[{ordinal}] is not a mapping", ref)
            continue

        graphic_id = entry.get("id")
        if not isinstance(graphic_id, str) or not graphic_id:
            diags.error("invalid_board_structure",
                        f"board_graphics[{ordinal}] has no id", ref)
            continue
        ref = SourceRef(EntityKind.GRAPHIC, graphic_id)

        layer_id = entry.get("layer")
        if not isinstance(layer_id, str) or not layer_id:
            diags.error("invalid_board_graphic",
                        f"board graphic {graphic_id} has no layer", ref)
            continue
        layer = Layer.from_id(layer_id)
        if layer.role not in ALLOWED_ROLES:
            diags.error("invalid_board_graphic",
                        f"board graphic {graphic_id} is on {layer_id!r} — board "
                        f"graphics are silk or courtyard only (copper would be "
                        f"unconnected metal; the board rim has its own owner)",
                        ref)
            continue

        kind = entry.get("kind")
        if kind not in GRAPHIC_KINDS:
            diags.error("invalid_board_graphic",
                        f"board graphic {graphic_id} has kind {kind!r}; expected "
                        f"one of {', '.join(GRAPHIC_KINDS)}", ref)
            continue

        width = _num(entry.get("width"))
        if width is None:
            width = DEFAULT_TEXT_WIDTH_MM if kind == "text" else DEFAULT_GRAPHIC_WIDTH_MM
        if width < 0:
            diags.error("invalid_board_graphic",
                        f"board graphic {graphic_id} has negative width {width}", ref)
            continue

        if kind == "text":
            text = entry.get("text")
            if not isinstance(text, str) or not text:
                diags.error("invalid_board_graphic",
                            f"board graphic {graphic_id} is text with no string", ref)
                continue
            anchor = _anchor(entry)
            if anchor is None:
                diags.error("invalid_board_graphic",
                            f"text graphic {graphic_id} has no usable position", ref)
                continue
            size = _num(entry.get("size_mm"), DEFAULT_TEXT_SIZE_MM)
            if size is None or size <= 0:
                diags.error("invalid_board_graphic",
                            f"text graphic {graphic_id} has non-positive size_mm", ref)
                continue
            rotation = _num(entry.get("rotation_deg"), 0.0) or 0.0
            align = entry.get("h_align") if entry.get("h_align") in ("left", "center") else "left"
            strokes = text_polylines(text, anchor[0], anchor[1], size_mm=size,
                                     rotation_deg=rotation,
                                     mirror=_mirror_for(layer, entry),
                                     h_align=align)
            if not strokes:
                # A string of nothing but spaces. Legal, draws nothing, and
                # saying so beats emitting an id-less zero-primitive entry.
                diags.warning("empty_board_graphic",
                              f"text graphic {graphic_id} ({text!r}) renders no "
                              f"strokes", ref)
                continue
            for index, stroke in enumerate(strokes):
                out.append(BoardGraphic(id=f"{graphic_id}#{index}", layer=layer,
                                        geometry=PolylineGeometry(points=stroke),
                                        width_mm=width))
            continue

        geometry = _build_geometry(kind, entry, graphic_id, ref, diags)
        if geometry is None:
            continue
        out.append(BoardGraphic(id=graphic_id, layer=layer, geometry=geometry,
                                width_mm=width))

    return tuple(out)


def _build_geometry(kind: str, entry: dict, graphic_id: str, ref, diags):
    """One non-text entry's geometry, or ``None`` after reporting why not."""
    if kind == "line":
        a = _point_pair(entry.get("start"))
        b = _point_pair(entry.get("end"))
        if a is None or b is None or a == b:
            diags.error("invalid_board_graphic",
                        f"line graphic {graphic_id} needs two distinct endpoints", ref)
            return None
        return LineGeometry(a=a, b=b)

    if kind == "circle":
        center = _point_pair(entry.get("center"))
        radius = _num(entry.get("radius"))
        if center is None or radius is None or radius <= 0:
            diags.error("invalid_board_graphic",
                        f"circle graphic {graphic_id} needs a center and a "
                        f"positive radius", ref)
            return None
        return CircleGeometry(center=center, radius_mm=radius)

    if kind == "rect":
        points = _rect_points(entry)
        if points is None:
            diags.error("invalid_board_graphic",
                        f"rect graphic {graphic_id} needs two opposite corners "
                        f"(start/end) or a position plus width_mm/height_mm, and "
                        f"must not be degenerate", ref)
            return None
        # A rect IS a closed polygon; it is a separate authoring kind only
        # because "two corners" is how a person describes a box. Normalising it
        # here means no consumer downstream needs a fifth geometry case.
        return PolygonGeometry(points=points)

    points = tuple(
        p for p in (_point_pair(v) for v in entry.get("points", []) or ()) if p is not None
    )
    minimum = 3 if kind == "poly" else 2
    if len(points) < minimum:
        diags.error("invalid_board_graphic",
                    f"{kind} graphic {graphic_id} needs at least {minimum} valid "
                    f"points, got {len(points)}", ref)
        return None
    if kind == "poly":
        return PolygonGeometry(points=points)
    return PolylineGeometry(points=points)
