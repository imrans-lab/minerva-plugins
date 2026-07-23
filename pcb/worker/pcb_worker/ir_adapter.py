"""GERBER IR→dict bridge (W8.1 of the PCB K3 cutover).

The live fab emitters consume a loosely-typed ``board_dict`` (the shape
``resolve.resolve_board`` / ``board_model.load_board`` produce) in which each
component carries footprint geometry in LOCAL coordinates and the emitter applies
its OWN placement transform. That legacy path IGNORES pin ``override``s, does NOT
mirror bottom-side components, and DROPS per-pad rotation.

The CORRECT geometry lives in the :class:`~pcb_worker.resolved_board.ResolvedBoard`
IR (``compile_board(source).board``): every :class:`PlacedPad` is BOARD-ABSOLUTE
(via ``geometry.PlacementTransform`` — overrides applied, bottom side mirrored,
per-pad ``rotation_deg`` combined). :func:`ir_to_board_dict` projects that IR back
into the emitter's board_dict shape with IDENTITY component placement, so the
emitter's ``_rotate`` + ``cx/cy`` become a no-op and the absolute geometry passes
through unchanged. Feed the result to ``gerber.build_gerbers(dict, placed=True)``
(``placed=True`` makes the aperture rotation come from each pad's ``rotation``
rather than the — now zero — component angle; see gerber.py hazard #2).

    compile_board(source).board  ->  ir_to_board_dict(rb)  ->  build_gerbers(dict, placed=True)

This is the phase that makes overrides + bottom-side mirror + pad-rotation reach
the gerber/Excellon fab bytes. PURE + deterministic: the ResolvedBoard is only
READ, never mutated.

NOT wired into the live emitter path here — that is W8.2 (``methods.py``). This
module only builds the bridge and is exercised by tests.
"""

from __future__ import annotations

from .resolved_board import (
    ArcGeometry,
    BoardOutline,
    CircleGeometry,
    HoleKind,
    LineGeometry,
    PlacedGraphic,
    PlacedPad,
    PolygonGeometry,
    ProfileOutline,
    RectOutline,
    ResolvedBoard,
    ResolvedComponent,
    ResolvedHole,
    RoundHole,
    Side,
)

__all__ = ["ir_to_board_dict"]


def _outline_frame(outline: BoardOutline) -> tuple[float, float, float, float]:
    """(origin_x, origin_y, width_mm, height_mm) for the board frame. v1 compiles
    a :class:`RectOutline`; a :class:`ProfileOutline` (future) degrades to its
    outer-contour axis-aligned bounding box so Edge.Cuts still frames the board."""
    if isinstance(outline, RectOutline):
        return outline.origin[0], outline.origin[1], outline.width_mm, outline.height_mm
    if isinstance(outline, ProfileOutline):
        pts: list[tuple[float, float]] = []
        for seg in outline.outer.segments:
            if isinstance(seg, LineGeometry):
                pts.extend((seg.a, seg.b))
            elif isinstance(seg, ArcGeometry):
                pts.extend((seg.start, seg.mid, seg.end))
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        return min(xs), min(ys), max(xs) - min(xs), max(ys) - min(ys)
    raise TypeError(f"unsupported board outline {type(outline)!r}")


def _pad_number_map(board: ResolvedBoard, component: ResolvedComponent) -> dict[str, str]:
    """``{footprint-pad source_id: pad number}`` for this component's footprint.

    A :class:`PlacedPad` carries its footprint ``source_id`` but not the human pad
    NUMBER; the emitter uses the number only for diagnostics / fail-closed pad
    context (never geometry), so recovering it from the interned footprint keeps
    error messages meaningful without touching any emitted byte."""
    definition = board.footprint_for(component)
    return {pad.source_id: pad.number for pad in definition.pads}


def _pad_to_dict(pad: PlacedPad, number: str) -> dict:
    """One :class:`PlacedPad` (BOARD-ABSOLUTE) → the emitter pad-dict shape
    ``pad_source._from_resolved`` reads.

    Geometry is ALREADY absolute + override-baked + side-mirrored (compile_board);
    nothing is re-applied. The TH annulus/drill contract is the load-bearing part:
    ``_from_resolved`` derives ``PadGeom.annulus`` from ``size.width`` (a resolved
    TH pad carries no separate annulus datum — its copper pad width DOUBLES as the
    annulus diameter). So a drilled pad's ``size`` here must be the EFFECTIVE
    annulus: the override-set :attr:`PlacedPad.annulus` when present (round), else
    the footprint copper land :attr:`PlacedPad.size`. ``drill.x`` carries the
    (possibly overridden) round drill; ``rotation`` is the absolute combined pad
    angle the ``placed=True`` gerber path applies to the aperture."""
    is_drilled = pad.drill is not None

    out: dict = {
        "number": number,
        "type": pad.pad_type,
        "shape": pad.shape.value,
        "position": {"x": pad.position[0], "y": pad.position[1]},
        "layers": [layer.id for layer in pad.layers],
        # ABSOLUTE combined angle — read only on the gerber placed path.
        "rotation": pad.rotation_deg,
    }

    # Size: for a drilled pad the width doubles as the annulus (see docstring); an
    # override annulus wins and is round. For an SMD pad it is the copper land.
    width: float | None
    height: float | None
    if is_drilled:
        if pad.annulus is not None:
            width = height = pad.annulus
        elif pad.size is not None:
            width, height = pad.size
        else:
            width = height = None
    else:
        # SMD pads always carry a size in the IR (compile_board fail-closes a
        # copper pad without one); guard defensively anyway.
        width, height = pad.size if pad.size is not None else (None, None)
    if width is not None and height is not None:
        out["size"] = {"width": width, "height": height}

    # Drill: {x, y} from the (possibly overridden) round drill; {0, 0} == no hole,
    # the same sentinel resolve emits (gerber treats drill > 0 as through-hole).
    if is_drilled:
        out["drill"] = {"x": pad.drill.size[0], "y": pad.drill.size[1]}
    else:
        out["drill"] = {"x": 0.0, "y": 0.0}

    # Fab-affecting optionals — present only when the IR carries them, so a plain
    # rect pad stays clean (mirrors resolve._pads_from_parsed).
    if pad.corner_rratio is not None:
        out["corner_rratio"] = pad.corner_rratio
    if pad.solder_mask_margin is not None:
        out["solder_mask_margin"] = pad.solder_mask_margin
    return out


def _graphic_to_dict(graphic: PlacedGraphic) -> dict:
    """One :class:`PlacedGraphic` (BOARD-ABSOLUTE) → the silk-graphic dict shape
    ``gerber._harvest_silk_graphic`` reads. With the component placed at identity
    the harvest silk transform is a no-op, so the absolute coords pass through.
    Coordinates are emitted as LISTS (the harvest ``isinstance(..., list)`` guards
    reject tuples). Arcs use the modern 3-point ``(start, mid, end)`` form, which
    is exactly what :class:`ArcGeometry` carries."""
    geom = graphic.geometry
    out: dict = {"layer": graphic.layer.id}
    if isinstance(geom, LineGeometry):
        out["kind"] = "line"
        out["start"] = [geom.a[0], geom.a[1]]
        out["end"] = [geom.b[0], geom.b[1]]
    elif isinstance(geom, CircleGeometry):
        out["kind"] = "circle"
        out["center"] = [geom.center[0], geom.center[1]]
        out["radius"] = geom.radius_mm
    elif isinstance(geom, ArcGeometry):
        out["kind"] = "arc"
        out["points"] = [
            [geom.start[0], geom.start[1]],
            [geom.mid[0], geom.mid[1]],
            [geom.end[0], geom.end[1]],
        ]
    elif isinstance(geom, PolygonGeometry):
        out["kind"] = "poly"
        out["points"] = [[p[0], p[1]] for p in geom.points]
    else:  # pragma: no cover - GraphicGeometry is a closed union
        raise TypeError(f"unsupported graphic geometry {type(geom)!r}")
    if graphic.width_mm is not None:
        out["width"] = graphic.width_mm
    return out


def _component_to_dict(board: ResolvedBoard, component: ResolvedComponent) -> dict:
    """One :class:`ResolvedComponent` → an emitter component dict with IDENTITY
    placement (``x_mm=y_mm=rotation_deg=0``). Identity makes the emitter's own
    ``_rotate`` + ``cx/cy`` a no-op so the ABSOLUTE pad/graphic geometry passes
    through unchanged; ``layer`` still tags the side so SMD copper lands on the
    right F/B layer and top-only silk is emitted as before."""
    number_of = _pad_number_map(board, component)
    return {
        "ref": component.ref,
        "x_mm": 0.0,
        "y_mm": 0.0,
        "rotation_deg": 0.0,
        "layer": "top" if component.placement.side is Side.TOP else "bottom",
        "pads": [
            _pad_to_dict(pad, number_of.get(pad.source_id, ""))
            for pad in component.placed_pads
        ],
        "graphics": [_graphic_to_dict(g) for g in component.placed_graphics],
    }


def _trace_dicts(board: ResolvedBoard) -> list[dict]:
    """Each :class:`ResolvedTraceSegment` → a two-point emitter trace dict. One
    dict per segment (not per polyline) so a trace whose segments differ in
    layer/width is carried faithfully; geometrically identical to the polyline the
    emitter would zip."""
    out: list[dict] = []
    for trace in board.traces:
        for seg in trace.segments:
            out.append({
                "layer": seg.layer.id,
                "width_mm": seg.width_mm,
                "points": [
                    {"x_mm": seg.a[0], "y_mm": seg.a[1]},
                    {"x_mm": seg.b[0], "y_mm": seg.b[1]},
                ],
            })
    return out


def _via_dicts(board: ResolvedBoard) -> list[dict]:
    return [
        {
            "x_mm": via.position[0],
            "y_mm": via.position[1],
            "diameter_mm": via.diameter_mm,
            "drill_mm": via.drill_mm,
        }
        for via in board.vias
    ]


def _hole_dict(hole: ResolvedHole) -> dict:
    """A :class:`ResolvedHole` → the emitter hole dict. FAIL-CLOSED on a non-round
    feature: drill is fabrication-critical, so a hole the round-only gerber path
    cannot drill must error with context, NOT vanish silently (compile_board
    already fail-closes a non-round drill upstream, so this is unreachable today —
    the raise seals the adapter against a future oval/slot IR silently dropping a
    hole at the cutover)."""
    feature = hole.feature
    if not isinstance(feature, RoundHole):
        raise ValueError(
            f"hole {hole.id!r} has a non-round feature {type(feature).__name__} the "
            f"round-only fabrication path cannot drill — refusing to drop it silently")
    return {
        "x_mm": feature.position[0],
        "y_mm": feature.position[1],
        "diameter_mm": feature.diameter_mm,
        "plated": hole.plated,
    }


# ResolvedHole kind -> the board-dict key gerber._harvest reads.
_HOLE_KEY = {
    HoleKind.PTH: "pth_holes",
    HoleKind.NPTH: "npth_holes",
    HoleKind.MOUNTING: "mounting_holes",
}


def ir_to_board_dict(board: ResolvedBoard) -> dict:
    """Project a :class:`ResolvedBoard` (K2 IR) into the loosely-typed emitter
    board_dict, in BOARD-ABSOLUTE geometry with IDENTITY component placement.

    Feed the result to ``gerber.build_gerbers(dict, placed=True)``: positions are
    already absolute (identity placement no-ops the emitter transform), overrides
    and the bottom-side mirror are baked into every :class:`PlacedPad`, and
    ``placed=True`` sources each aperture's rotation from the pad's own absolute
    angle. PURE + deterministic — the ResolvedBoard is only read.
    """
    # Copper the adapter does not yet map must NOT vanish at the cutover.
    # compile_board fail-closes zone/board-graphic DECLARATIONS today, so these are
    # always empty — the guard seals the adapter against a future copper-pour /
    # board-graphic IR silently losing copper when fed to fabrication.
    if board.zones:
        raise ValueError(
            f"ir_to_board_dict: board has {len(board.zones)} zone(s) the gerber bridge "
            f"does not map yet — refusing to emit fabrication that silently drops copper")
    if board.board_graphics:
        raise ValueError(
            f"ir_to_board_dict: board has {len(board.board_graphics)} board-level graphic(s) "
            f"the gerber bridge does not map yet — refusing to drop them silently")

    ox, oy, width_mm, height_mm = _outline_frame(board.outline)
    rules = board.design_rules

    holes: dict[str, list[dict]] = {"pth_holes": [], "npth_holes": [], "mounting_holes": []}
    for hole in board.holes:
        holes[_HOLE_KEY[hole.kind]].append(_hole_dict(hole))

    out: dict = {
        "name": board.name,
        "width_mm": width_mm,
        "height_mm": height_mm,
        "origin": {"x_mm": ox, "y_mm": oy},
        "design_rules": {
            "trace_width_mm": rules.defaults.trace_width_mm,
            "via_diameter_mm": rules.defaults.via_diameter_mm,
            "via_drill_mm": rules.defaults.via_drill_mm,
            "solder_mask_clearance_mm": rules.minimums.solder_mask_clearance_mm,
        },
        "components": [_component_to_dict(board, comp) for comp in board.components],
        "traces": _trace_dicts(board),
        "vias": _via_dicts(board),
    }
    # Only surface a hole class the board actually has (keeps the dict clean and
    # matches how producers pre-split plating).
    for key, entries in holes.items():
        if entries:
            out[key] = entries
    return out
