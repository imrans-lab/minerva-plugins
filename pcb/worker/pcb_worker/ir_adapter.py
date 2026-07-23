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
through unchanged. Feed the result to ``gerber.build_gerbers(dict)``: the emitter
sources the aperture rotation from each pad's ``rotation`` rather than the — now
zero — component angle (see gerber.py hazard #2).

    compile_board(source).board  ->  ir_to_board_dict(rb)  ->  build_gerbers(dict)

This is the phase that makes overrides + bottom-side mirror + pad-rotation reach
the gerber/Excellon fab bytes. PURE + deterministic: the ResolvedBoard is only
READ, never mutated.

NOT wired into the live emitter path here — that is W8.2 (``methods.py``). This
module only builds the bridge and is exercised by tests.
"""

from __future__ import annotations

from .kicad import (
    _graphic_to_dict,
    _ir_board_dict,
    _outline_frame,
    _pad_number_map,
    _pad_to_dict,
)
from .resolved_board import (
    HoleKind,
    ResolvedBoard,
    ResolvedComponent,
    ResolvedHole,
    RoundHole,
    Side,
)

__all__ = ["ir_to_board_dict", "ir_to_kicad_board_dict"]


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
            # Per-side mask tenting (finding 019f8fe7cbaf): an untented side gets a
            # mask opening over the via annulus; a tented side (default) does not.
            "tented_front": via.tented_front,
            "tented_back": via.tented_back,
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
    out = {
        "x_mm": feature.position[0],
        "y_mm": feature.position[1],
        "diameter_mm": feature.diameter_mm,
        "plated": hole.plated,
    }
    # AUTHORED copper annulus for a plated board hole (finding 019f8dbb7104): the
    # gerber bridge emits this exact ring on both copper layers — no invented 2x-drill.
    if hole.annulus_mm is not None:
        out["annulus_mm"] = hole.annulus_mm
    return out


# ResolvedHole kind -> the board-dict key gerber._harvest reads.
_HOLE_KEY = {
    HoleKind.PTH: "pth_holes",
    HoleKind.NPTH: "npth_holes",
    HoleKind.MOUNTING: "mounting_holes",
}


def ir_to_board_dict(board: ResolvedBoard) -> dict:
    """Project a :class:`ResolvedBoard` (K2 IR) into the loosely-typed emitter
    board_dict, in BOARD-ABSOLUTE geometry with IDENTITY component placement.

    Feed the result to ``gerber.build_gerbers(dict)``: positions are already
    absolute (identity placement no-ops the emitter transform), overrides and the
    bottom-side mirror are baked into every :class:`PlacedPad`, and the emitter
    sources each aperture's rotation from the pad's own absolute angle. PURE +
    deterministic — the ResolvedBoard is only read.
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


def ir_to_kicad_board_dict(board: ResolvedBoard) -> dict:
    """Thin delegation to :func:`kicad._ir_board_dict` — the KiCad IR->dict
    projection moved into ``kicad`` (C5b) so the live path no longer transits this
    module; kept only for the byte-equivalence test (C5c deletes it)."""
    return _ir_board_dict(board)
