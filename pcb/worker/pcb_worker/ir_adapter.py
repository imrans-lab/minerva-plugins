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

from .geometry import place_point
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

__all__ = ["ir_to_board_dict", "ir_to_kicad_board_dict"]


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
    angle the gerber emitter applies to the aperture."""
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


# ===========================================================================
# KiCad IR->dict bridge — REAL-PLACEMENT footprints (C3, finding 019f8dbb6593).
#
# GROUND TRUTH (verified numerically vs pcbnew 9.0.9 oracle k1_bottom_oracle):
# a KiCad footprint is ``(footprint (layer F.Cu|B.Cu) (at px py rot))`` with pads/
# graphics in footprint-LOCAL coords; on LOAD KiCad applies TRANSLATE + ROTATE
# ONLY (no re-flip). A BOTTOM footprint stores its local coords already Y-mirrored,
# and each pad ``(at ... ANGLE)`` third value is the ABSOLUTE board-frame angle.
#
# The FIRST cutover emitted every footprint at ``(at 0 0 0)`` with board-ABSOLUTE
# pads. Geometrically correct, but SEMANTICALLY broken: every component's origin
# sat at 0,0, so the .kicad_pcb lost component placement, editability, and
# assembly/CPL (pick-and-place) — a CPL export reported every part at 0,0,0.
#
# REAL PLACEMENT restores it. The IR ``PlacedPad`` is already board-absolute,
# override-baked, bottom-mirrored, and carries the COMBINED absolute
# ``rotation_deg`` + correctly-sided ``layers`` — so the STORED footprint-local
# coordinate is recovered by inverting ONLY the placement translate+rotate
# (``_to_footprint_local``); the mirror and absolute angle are already baked, and
# are emitted AS-IS. KiCad re-applies (at px py rot) on load to reproduce the exact
# same absolute geometry the identity encoding produced — so copper/registration is
# byte-for-byte equivalent — while the footprint now sits at its real placement.
# gerber stays absolute-under-identity (layer-based, no footprint concept).
# ===========================================================================


def _to_footprint_local(px: float, py: float, rot: float,
                        x: float, y: float) -> tuple[float, float]:
    """Recover the KiCad footprint-LOCAL coordinate a board-ABSOLUTE point must be
    STORED as, by inverting a component placement's translate + rotate. KiCad
    reproduces the absolute on load by re-applying the footprint ``(at px py rot)``;
    the bottom-side MIRROR and the ABSOLUTE pad angle are already baked into the
    PlacedPad, so ONLY translate+rotate is inverted here. Verified vs the pcbnew
    9.0.9 oracle: ``place_point(0,0,-37, 51.794092-50, 37.395919-40) == (3.0,-1.0)``
    and the forward ``place_point(50,40,37, 3,-1)`` returns the absolute.

    Rounded to 6 decimals (KiCad's 1 nm native resolution) so the inverse rotation's
    float noise (a ``5.8e-17`` that should be ``0``) does not leak into the emitted
    ``(at)`` — clean, exactly-reproducible bytes, well within fab tolerance."""
    lx, ly = place_point(0.0, 0.0, -rot, x - px, y - py)
    return (round(lx, 6), round(ly, 6))


def _kicad_component_to_dict(board: ResolvedBoard,
                             component: ResolvedComponent) -> dict:
    """One :class:`ResolvedComponent` -> an emitter component dict at its REAL
    footprint placement (``x/y/rotation`` from :attr:`Placement`) with pad/graphic
    geometry in footprint-LOCAL coords.

    The PlacedPad is board-absolute (override-baked, bottom-mirrored, absolute
    combined angle, correctly-sided layers); :func:`_to_footprint_local` inverts the
    placement translate+rotate to recover the stored local POSITION, while the pad
    ANGLE (absolute) and LAYERS (sided) pass through unchanged — KiCad reads the pad
    ``(at)`` angle as absolute and does not re-flip a B.Cu footprint. KiCad's
    on-load translate+rotate reproduces the identical absolute geometry, so
    fabrication is unchanged while the footprint sits at its real placement (CPL /
    editability restored)."""
    number_of = _pad_number_map(board, component)
    definition = board.footprint_for(component)
    px, py = component.placement.position
    rot = component.placement.rotation_deg

    def _local_pad(pad: PlacedPad) -> dict:
        out = _pad_to_dict(pad, number_of.get(pad.source_id, ""))
        lx, ly = _to_footprint_local(px, py, rot, pad.position[0], pad.position[1])
        out["position"] = {"x": lx, "y": ly}   # local; angle + layers stay absolute/sided
        return out

    def _local_graphic(graphic: PlacedGraphic) -> dict:
        out = _graphic_to_dict(graphic)
        _localize_graphic_points(out, px, py, rot)
        return out

    return {
        "ref": component.ref,
        "value": component.value,
        "footprint": definition.name,
        "x_mm": px,
        "y_mm": py,
        "rotation_deg": rot,
        "layer": "top" if component.placement.side is Side.TOP else "bottom",
        "pads": [_local_pad(pad) for pad in component.placed_pads],
        # Only F.SilkS is rendered by the kicad emitter (bottom-side B.SilkS silk is
        # dropped as before — cosmetic, non-fabrication-critical). Localized so the
        # silk lands correctly under the real footprint (at), not double-transformed.
        "graphics": [
            _local_graphic(g) for g in component.placed_graphics
            if g.layer.id == "F.SilkS"
        ],
    }


def _localize_graphic_points(graphic_dict: dict, px: float, py: float,
                             rot: float) -> None:
    """In-place: rewrite a graphic dict's ABSOLUTE coordinate fields to footprint-
    LOCAL (``_to_footprint_local``). ``radius`` is rotation/translation-invariant, so
    only the point fields (start/end/center + the arc/poly points list) move."""
    def loc(pt: list) -> list:
        return list(_to_footprint_local(px, py, rot, pt[0], pt[1]))
    for key in ("start", "end", "center"):
        if key in graphic_dict:
            graphic_dict[key] = loc(graphic_dict[key])
    if "points" in graphic_dict:
        graphic_dict["points"] = [loc(p) for p in graphic_dict["points"]]


def _mounting_hole_refs(existing_refs: set[str], count: int) -> list[str]:
    """``count`` collision-free ``MountingHole`` refs (H1, H2, ...) that SKIP any
    ref a real component already uses. Without this a user component named ``H1``
    would duplicate a synthetic mounting-hole ref in the .kicad_pcb — a duplicate
    reference KiCad flags (Fable W8.2b note)."""
    used = set(existing_refs)
    out: list[str] = []
    n = 0
    while len(out) < count:
        n += 1
        ref = f"H{n}"
        if ref not in used:
            used.add(ref)
            out.append(ref)
    return out


def _kicad_mounting_hole_component(hole: ResolvedHole, ref: str) -> dict:
    """A board-level :class:`ResolvedHole` -> a synthetic ``MountingHole`` component
    the kicad emitter renders as one bare through-hole pad.

    KiCad represents a standalone drill as a footprint carrying a single drilled
    pad. We emit one ``MountingHole`` footprint at the hole's REAL position with the
    pad at footprint-LOCAL origin (0, 0), consistent with the real-placement
    component footprints — ``kicad._footprint`` translates the origin-local pad by
    the footprint ``(at)`` and drills it exactly where the IR says, and the hole
    footprint reads correctly in KiCad (its origin is on the drill).

    Plating drives the padstack via ``pad_source._from_resolved`` +
    ``kicad._footprint``: a NON-plated hole (NPTH / an unplated MOUNTING hole) is a
    bare ``np_thru_hole`` with size == drill (no copper, no net); a PLATED hole
    (PTH) is a ``thru_hole`` with a copper annulus (the emitter's 2x-drill nominal,
    since a RoundHole carries only its drill diameter, no separate annulus datum).
    The empty pad NUMBER matches KiCad's real mounting-hole footprints. FAIL-CLOSED
    on a non-round feature stays intact (the round-only drill seal)."""
    feature = hole.feature
    if not isinstance(feature, RoundHole):
        raise ValueError(
            f"hole {hole.id!r} has a non-round feature {type(feature).__name__} the "
            f"round-only fabrication path cannot drill — refusing to drop it silently")
    diameter = feature.diameter_mm
    pad: dict = {
        "number": "",
        "type": "thru_hole" if hole.plated else "np_thru_hole",
        "shape": "circle",
        "position": {"x": 0.0, "y": 0.0},   # footprint-local; footprint (at) is the hole
        "drill": {"x": diameter, "y": diameter},
        "layers": ["*.Cu", "*.Mask"],
    }
    # NPTH/unplated: size == drill (no copper ring). PLATED: omit size so the
    # emitter supplies its 2x-drill nominal annulus (no annulus datum in the IR).
    if not hole.plated:
        pad["size"] = {"width": diameter, "height": diameter}
    return {
        "ref": ref,
        "value": "",
        "footprint": "MountingHole",
        "x_mm": feature.position[0],
        "y_mm": feature.position[1],
        "rotation_deg": 0.0,
        "layer": "top",
        "pads": [pad],
        "graphics": [],
    }


def _kicad_net_dicts(board: ResolvedBoard) -> list[dict]:
    """Each :class:`ResolvedNet` -> the ``{name, pins:["REF.PADNUM", ...]}`` dict
    kicad._net_table reads. A net's ``pad_refs`` are PlacedPad ids; kicad wants
    ``REF.PADNUM``, so each placed-pad id is resolved to its component ref + the
    footprint pad NUMBER (via source_id) — the same join kicad's pad_net expects."""
    pin_of: dict[str, str] = {}
    for component in board.components:
        number_of = {pad.source_id: pad.number
                     for pad in board.footprint_for(component).pads}
        for placed in component.placed_pads:
            pin_of[placed.id] = f"{component.ref}.{number_of.get(placed.source_id, '')}"
    return [
        {"name": net.name, "pins": [pin_of[ref] for ref in net.pad_refs]}
        for net in board.nets
    ]


def _kicad_trace_dicts(board: ResolvedBoard, net_name_of: dict[str, str]) -> list[dict]:
    """Like :func:`_trace_dicts` but tagged with the trace's NET NAME — kicad
    assigns each ``segment`` a net index from ``board["nets"]``, so a routed board
    keeps its copper on-net (gerber ignores nets, hence the divergent projection)."""
    out: list[dict] = []
    for trace in board.traces:
        name = net_name_of.get(trace.net_id, "")
        for seg in trace.segments:
            out.append({
                "layer": seg.layer.id,
                "width_mm": seg.width_mm,
                "net": name,
                "points": [
                    {"x_mm": seg.a[0], "y_mm": seg.a[1]},
                    {"x_mm": seg.b[0], "y_mm": seg.b[1]},
                ],
            })
    return out


def _kicad_via_dicts(board: ResolvedBoard, net_name_of: dict[str, str]) -> list[dict]:
    return [
        {
            "x_mm": via.position[0],
            "y_mm": via.position[1],
            "diameter_mm": via.diameter_mm,
            "drill_mm": via.drill_mm,
            "net": net_name_of.get(via.net_id, ""),
        }
        for via in board.vias
    ]


def ir_to_kicad_board_dict(board: ResolvedBoard) -> dict:
    """Project a :class:`ResolvedBoard` (K2 IR) into the loosely-typed emitter
    board_dict that ``kicad.generate`` consumes, with each footprint at its REAL
    placement ``(at px py rot)`` and pad/graphic geometry in footprint-LOCAL coords.

    KiCad applies only translate+rotate on load (no native flip) and reads the pad
    ``(at)`` third value as the ABSOLUTE angle. The IR's board-absolute PlacedPad is
    projected back to the stored footprint-local POSITION by inverting the placement
    translate+rotate (:func:`_to_footprint_local`), while the absolute angle, sided
    layers, and baked-in overrides + bottom mirror pass through unchanged — KiCad's
    on-load transform reproduces the identical absolute geometry (fabrication /
    registration unchanged) while the footprint sits at its real placement, so the
    .kicad_pcb keeps component placement, editability, and assembly/CPL semantics
    (finding 019f8dbb6593). Additionally emits ``nets`` (kicad assigns
    pad/segment/via nets from them) and net-tagged traces/vias, which the gerber
    bridge omits. PURE + deterministic — the ResolvedBoard is only read.

    Board-level HOLES (mounting holes) are EMITTED faithfully: each round
    :class:`ResolvedHole` becomes a synthetic ``MountingHole`` footprint at the
    hole's real position carrying a single bare through-hole pad at footprint-local
    origin — an unplated hole as ``np_thru_hole`` (no copper), a plated one as
    ``thru_hole`` with a copper annulus (see :func:`_kicad_mounting_hole_component`).
    A non-round hole feature still RAISES (the round-only drill seal).

    FAIL-CLOSED seals (mirroring the gerber bridge): a captured feature the kicad
    emitter cannot render — a zone or a board-level graphic — must RAISE, never
    vanish silently from a fabrication-bound file. compile_board fail-closes
    zones/board-graphics upstream (always empty today), so these seal the adapter
    against a future IR silently dropping copper at the cutover."""
    if board.zones:
        raise ValueError(
            f"ir_to_kicad_board_dict: board has {len(board.zones)} zone(s) the kicad "
            f"bridge does not map yet — refusing to silently drop copper")
    if board.board_graphics:
        raise ValueError(
            f"ir_to_kicad_board_dict: board has {len(board.board_graphics)} board-level "
            f"graphic(s) the kicad bridge does not map yet — refusing to drop them silently")

    ox, oy, width_mm, height_mm = _outline_frame(board.outline)
    rules = board.design_rules
    net_name_of = {net.id: net.name for net in board.nets}

    # Real components first, then the synthetic mounting-hole footprints (in
    # board.holes order — deterministic). Their refs (H1, H2, ...) SKIP any real
    # component ref so the .kicad_pcb never carries a duplicate reference; they
    # carry no net, so nets/traces/vias are unaffected.
    components = [_kicad_component_to_dict(board, comp) for comp in board.components]
    hole_refs = _mounting_hole_refs({comp.ref for comp in board.components}, len(board.holes))
    components += [_kicad_mounting_hole_component(hole, ref)
                   for hole, ref in zip(board.holes, hole_refs)]

    return {
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
        "nets": _kicad_net_dicts(board),
        "components": components,
        "traces": _kicad_trace_dicts(board, net_name_of),
        "vias": _kicad_via_dicts(board, net_name_of),
    }
