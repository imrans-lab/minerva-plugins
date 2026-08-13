"""Annotation/hint -> agent_router bridge (worker-side, standalone).

Translates the canonical board-source dict (pcb/internal/board/board.go +
docs/board-yaml.md) and pcb_route_hint annotation envelopes (pcb/ui/kinds/
pcb_route_hint_kind.gd + PcbAnnotationHost.build_route_hint_envelope) into the
agent_router engine's native ``Board`` + ``RoutingHints`` so the ``route``
method can drive the router from the same board the panel renders.

WHICH BUILDER IS WHICH (Round E, docket 019f783860c8)
-----------------------------------------------------
``resolved_board_to_router`` is the PRODUCTION canonical builder: it projects a
compiled ResolvedBoard, so every dimension, position, side/mirror, layer and net
is IR-authoritative. ``board_to_router`` below is the LEGACY raw-dict builder,
kept for the pure-bridge tests and the hint helpers; it no longer invents a
nominal land (a pad with no authored geometry now raises) and it is slated for
retirement with the native pad-list path in E3.

The panel-convention notes below therefore describe the LEGACY builder. Canonical
routing no longer mirrors raw panel-pin placement: it takes placement from the
IR. For a top-side component the two agree exactly (the IR's
``PlacementTransform.point`` calls the very same ``rotate_local_offset``), but for
a BOTTOM-side component they deliberately differ — the IR mirrors local Y as
pcbnew does (pinned by ``k1_bottom_oracle.kicad_pcb``, KiCad 9.0.9) while the raw
path never did. That divergence is the raw path being wrong, not a compatibility
requirement (Codex ruling 1).

Design constraints (docket 019eb481ae28 / 019eb47eb567, DCR 019dc140):

  * This module lives in pcb_worker/ and IMPORTS agent_router types. Historically
    it also never EDITED agent_router/. That note describes dependency direction,
    not a ban on evolving our own first-party engine: Codex's E1 review (comment
    773) rules that E2 makes ``RoutingGrid`` natively origin-aware rather than
    duplicating a world<->grid transform here.
  * Absolute pad positions (LEGACY builder) are composed the SAME way the panel
    model does it in pcb/ui/model/pcb_component.gd::get_pin_world_position, so
    panel and router agree on where a rotated component's pad lands. That
    convention is:

        xform  = Transform2D(deg_to_rad(-rotation_deg))   # Godot CW-positive
        world  = component_pos + xform * pin_offset

    which expands (Godot Transform2D basis: x=(cosθ,sinθ), y=(-sinθ,cosθ),
    θ = -rotation) to the closed form used in ``_rotate_offset`` below:

        wx = cx + px*cos(r) + py*sin(r)
        wy = cy - px*sin(r) + py*cos(r)          (r = radians(rotation_deg))

    NOTE this deliberately differs from the OTHER panel helper
    get_pad_world_transform (which uses +rotation via Vector2.rotated); the
    task pins get_pin_world_position as the canonical panel<->router agreement,
    because canonical Pin offsets come from the component ``pins`` dict that
    get_pin_world_position consumes.

  * Waypoint coordinates are carried bit-exact (float() identity, no rounding)
    — a route hint's waypoints are pixel-accurate user corrections and must
    survive translation with zero drift.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Any, Optional

from agent_router.board import Board, Pad, Net, Obstacle
from agent_router.hints import RoutingHints, parse_hints
from agent_router.router import ExistingSegment, ExistingVia
from agent_router import layers as _layers

from .geometry import rotate_local_offset
from .ir_pads import UnsupportedGeometry, iter_ir_pads, pad_copper_shape
from .ir_projection import outline_cutouts, outline_frame, profile_outer_rect
from .pad_source import is_th_drill
from .resolved_board import (
    LayerRole,
    LineGeometry,
    OvalHole,
    ProfileOutline,
    RectOutline,
    ResolvedBoard,
    RoundHole,
    Side,
    SlotHole,
    ZoneKind,
)


# ---------------------------------------------------------------------------
# Layer mapping (canonical "top"/"bottom" <-> KiCad "F.Cu"/"B.Cu")
# ---------------------------------------------------------------------------
# T1.5: the map now lives in the LOWER package agent_router.layers so it can be
# shared with kicad_io without inverting the dependency direction. Re-exported
# here (the SAME dict object, not a copy) so pcb_worker.methods._canonical_drc_layer
# and any other reader of route_bridge._LAYER_MAP keep working and can never
# drift from the canonical map.
_LAYER_MAP = _layers.CANON_TO_KICAD

# The copper layers the vendored engine can route (agent_router.layers is
# explicitly 2-layer: "NO N-layer support"). A compiled board whose copper stack
# is anything else fails CLOSED rather than route with inner copper the grid
# never models.
_ROUTABLE_KICAD_LAYERS = ("F.Cu", "B.Cu")


def _num(v: Any, default: float = 0.0) -> float:
    """Coerce a scalar to float, tolerating None/str; ``default`` on failure."""
    if v is None or isinstance(v, bool):
        return default
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


def _canon_layer(layer: Any) -> str:
    """Map a canonical component/hint layer to a KiCad copper layer name.

    Thin re-export of agent_router.layers.canon_to_kicad (T1.5); kept as a
    module-level name for existing call sites.
    """
    return _layers.canon_to_kicad(layer)


class UnresolvableComponentLayer(ValueError):
    """A board-source component whose copper SIDE cannot be resolved.

    ADJUDICATED (epoch C, unit C2). The alternative — default a component with
    no authored ``layer`` to "top" — is the exact class of defect this campaign
    has spent two epochs removing: ``agent_router.layers.canon_to_kicad`` used to
    return "F.Cu" for an empty/None layer and epoch 6 unit 3a deleted that
    default *by name*, because "a silently defaulted layer name puts copper on
    the wrong side of a board that then gets fabricated" (layers.py:145-152).
    Re-introducing the same default one call frame upstream, inside the board
    builder, would restore the defect with a longer stack trace.

    So this builder REFUSES. Every pad of a component inherits the component's
    side, so an unresolvable side is not a missing detail — it is the router not
    knowing which physical copper layer an entire footprint's lands live on.

    A ``ValueError`` subclass on purpose: :func:`board_to_router`'s documented
    contract is "raises ``ValueError`` on a structurally unusable board", and
    ``canon_to_kicad`` already raised a bare ``ValueError`` here, so every
    existing caller and test that catches ``ValueError`` is unaffected. What is
    new is the STRUCTURE — ``component_ref`` and ``layer`` are attributes, not
    prose a caller has to regex out of a message that never named the component
    at all.
    """

    def __init__(self, ref: Any, layer: Any, reason: str = ""):
        self.component_ref = str(ref)
        self.layer = layer
        detail = f": {reason}" if reason else ""
        super().__init__(
            f"component {self.component_ref!r}: unresolvable copper layer "
            f"{layer!r}{detail} — routing fails closed rather than place a "
            f"whole footprint's lands on a defaulted side. Author an explicit "
            f'component "layer" ("top"/"bottom", or a KiCad copper name).')


def _component_layer(ref: Any, comp: dict) -> str:
    """The KiCad copper layer a component's lands sit on, or fail closed.

    The ONE place the legacy raw-dict builder resolves a component side. Absent,
    empty and unrecognised all take the same exit — a missing key is not more
    forgivable than a typo, because both leave the router guessing which side a
    footprint's copper is on.
    """
    raw = comp.get("layer")
    try:
        return _canon_layer(raw)
    except ValueError as exc:
        reason = "no \"layer\" key" if "layer" not in comp else str(exc)
        raise UnresolvableComponentLayer(ref, raw, reason) from exc


def _rotate_offset(px: float, py: float, rotation_deg: float) -> tuple[float, float]:
    """Rotate a component-relative pin offset into board space.

    Single source of the transform is pcb_worker.geometry.rotate_local_offset;
    this thin wrapper keeps the call sites here unchanged. The geometry form
    (``radians(-deg)``) is algebraically identical to this module's former
    hand-written ``radians(+deg)`` matrix, and both mirror
    pcb/ui/model/pcb_component.gd::get_pin_world_position exactly: a Godot
    Transform2D(deg_to_rad(-rotation)) applied to the offset (a clockwise
    rotation by ``rotation_deg`` in a right-handed screen frame).
    """
    return rotate_local_offset(px, py, rotation_deg)


# ---------------------------------------------------------------------------
# board_to_router
# ---------------------------------------------------------------------------


def _pad_size_for(pin: dict, extra_pads_by_num: dict[str, dict]) -> tuple[float, float]:
    """Resolve a pad's (w, h) size in mm from AUTHORED geometry, or fail closed.

    Priority: explicit render geometry (component ``pads`` Extra, present when
    the board came from YAML with footprint geometry) -> through-hole annulus
    diameter -> :class:`UnsupportedGeometry`.

    ROUND E (019f783860c8): the third branch used to return a nominal
    ``_DEFAULT_PAD_SIZE = (1.0, 1.0)`` — copper the board does not have. The
    router then computed keepouts around a fictional land and could propose a
    trace straight through the real package land; accepted, that is approximated
    copper reaching fabrication, which the owner-ratified Step-4 ruling forbids
    ("ROUTING/DRC/CAM FAIL CLOSED. No approximated copper."). There is no honest
    size to invent here, so this path now raises. Production canonical routing
    does not reach it at all — it goes through
    :func:`resolved_board_to_router`, where every dimension is IR-authoritative.
    """
    num = str(pin.get("number", ""))
    render = extra_pads_by_num.get(num)
    if isinstance(render, dict):
        size = render.get("size")
        if isinstance(size, dict):
            w = _num(size.get("width"))
            h = _num(size.get("height"))
            if w > 0 and h > 0:
                return (w, h)
        elif isinstance(size, (list, tuple)) and len(size) >= 2:
            w = _num(size[0]); h = _num(size[1])
            if w > 0 and h > 0:
                return (w, h)
    # AUTHORED inline pin size. pad_source._from_pin has always read these keys —
    # this builder did not, so a pin that authored its own copper size still got
    # the nominal 1.0x1.0 land. Reading them is not a new inference: it is the
    # same authored datum the neutral owner already uses.
    pin_w = _num(pin.get("pad_width_mm"))
    pin_h = _num(pin.get("pad_height_mm"))
    if pin_w > 0 and pin_h > 0:
        return (pin_w, pin_h)
    annulus = _num(pin.get("annulus_diameter_mm"))
    if annulus > 0:
        return (annulus, annulus)
    raise UnsupportedGeometry(
        f"pad {pin.get('number')!r}: no authored copper geometry (neither a "
        f"resolved pad size nor a through-hole annulus) — routing fails closed "
        f"rather than invent a nominal land")


def board_to_router(canonical_board: dict) -> Board:
    """Translate a canonical board dict into an ``agent_router.Board``.

    Composes absolute pad positions from component placement + rotated pin
    offsets (get_pin_world_position convention), maps ``Ref.Pad`` net refs onto
    pad membership, and carries obstacles (mounting holes) + board size.

    Refuses a board declaring ``cutouts``: this LOOSE path models mounting-hole
    obstacles only (production routing is :func:`resolved_board_to_router`,
    methods.py, which projects cutouts as obstacles) — routing a dict board as
    if its opening did not exist would propose copper through a hole in the
    board, the silent fail-open this bridge exists to prevent.

    Raises ``ValueError`` on a structurally unusable board (not a mapping / no
    components), and its named subclass :class:`UnresolvableComponentLayer` on a
    component whose copper side cannot be resolved. Unresolvable *net* pin refs
    are skipped silently — the canonical validator (board_model.validate_board)
    owns that diagnostic; unresolvable *hint* pin refs are surfaced as warnings
    by ``hints_to_router``.
    """
    if not isinstance(canonical_board, dict):
        raise ValueError("board must be a mapping")
    raw_cutouts = canonical_board.get("cutouts")
    if isinstance(raw_cutouts, list) and raw_cutouts:
        raise UnsupportedGeometry(
            "board declares cutouts; the loose route bridge does not model "
            "them as obstacles — route via the compiled path "
            "(resolved_board_to_router) instead of proposing copper through "
            "an opening in the board")
    components = canonical_board.get("components")
    if not isinstance(components, list) or not components:
        raise ValueError("board.components must be a non-empty list")

    pads: list[Pad] = []
    # (component_ref, pad_number) -> Pad, for net-membership resolution.
    pad_index: dict[tuple[str, str], Pad] = {}

    for comp in components:
        if not isinstance(comp, dict):
            continue
        ref = str(comp.get("ref", comp.get("id", "")))
        cx = _num(comp.get("x_mm"))
        cy = _num(comp.get("y_mm"))
        rot = _num(comp.get("rotation_deg"))
        # Fail closed, BY NAME (see UnresolvableComponentLayer). Resolved here,
        # before the pin loop, because every pad below inherits this one value.
        layer = _component_layer(ref, comp)

        # Render-detail pad geometry (component "Extra" from YAML), matched by
        # pad number for size resolution. Absent for JSON-dict boards.
        extra_pads_by_num: dict[str, dict] = {}
        raw_pads = comp.get("pads")
        if isinstance(raw_pads, list):
            for rp in raw_pads:
                if isinstance(rp, dict):
                    extra_pads_by_num[str(rp.get("number", ""))] = rp

        for pin in comp.get("pins") or []:
            if not isinstance(pin, dict):
                continue
            num = str(pin.get("number", ""))
            px = _num(pin.get("x_mm"))
            py = _num(pin.get("y_mm"))
            wx, wy = _rotate_offset(px, py, rot)
            drill = _num(pin.get("drill_mm"))
            # Through-hole iff the drill is a FINITE positive diameter — the SAME
            # shared predicate the fab emitters + DRC use (bug 019f920d433f), so the
            # router can never drift from them and a NaN/Inf drill is never modeled as
            # a through-hole (the bare `drill > 0` literal classified +Inf as TH).
            is_th = is_th_drill(drill)
            pad = Pad(
                component=ref,
                number=num,
                net=None,  # filled from net membership below
                position=(cx + wx, cy + wy),
                size=_pad_size_for(pin, extra_pads_by_num),
                shape=str(pin.get("shape", "rect")),
                pad_type=("thru_hole" if is_th else "smd"),
                drill=(drill if is_th else None),
                layer=layer,
                rotation=rot,
            )
            pads.append(pad)
            pad_index[(ref, num)] = pad

    # Nets: resolve "Ref.Pad" refs onto pads, set pad.net, build Net objects.
    nets: dict[str, Net] = {}
    for net_spec in canonical_board.get("nets") or []:
        if not isinstance(net_spec, dict):
            continue
        name = str(net_spec.get("name", ""))
        if not name:
            continue
        net = nets.get(name)
        if net is None:
            net = Net(name=name, number=len(nets) + 1, pads=[])
            nets[name] = net
        for ref_str in net_spec.get("pins") or []:
            comp_ref, pad_num = _split_pin_ref(ref_str)
            if comp_ref is None:
                continue
            pad = pad_index.get((comp_ref, pad_num))
            if pad is None:
                continue  # unresolved net ref — validator's concern, skip here
            pad.net = name
            net.pads.append(pad)

    obstacles = _obstacles_from_board(canonical_board)

    origin = canonical_board.get("origin") or {}
    ox = _num(origin.get("x_mm")) if isinstance(origin, dict) else 0.0
    oy = _num(origin.get("y_mm")) if isinstance(origin, dict) else 0.0

    # THE BOARD'S OWN COMMITTED COPPER (epoch GA-2, closing bug 019f6cf2b5f4):
    # this loose-dict path ignored `traces`/`vias` entirely, so any route run
    # through it re-routed EVERY net and drew straight through copper a human
    # had already committed. The IR path fixed this in T7; here the same
    # copper reaches the Board's own slots (019f9bc3909c), which both engine
    # entry points already consume — other-net copper becomes an obstacle,
    # same-net copper reads as already-connected.
    existing_traces: list[ExistingSegment] = []
    for trace in canonical_board.get("traces") or []:
        if not isinstance(trace, dict):
            continue
        t_net = str(trace.get("net", "")) or None
        t_layer = _layers.canon_to_kicad(str(trace.get("layer") or "top"))
        width = _num(trace.get("width_mm")) or 0.25
        points = [p for p in (trace.get("points") or [])
                  if isinstance(p, dict)]
        for a, b in zip(points, points[1:]):
            existing_traces.append(ExistingSegment(
                net=t_net,
                start=(_num(a.get("x_mm")), _num(a.get("y_mm"))),
                end=(_num(b.get("x_mm")), _num(b.get("y_mm"))),
                width=width, layer=t_layer,
                source_id=str(trace.get("id")) if trace.get("id") else None))
    existing_vias: list[ExistingVia] = []
    for via in canonical_board.get("vias") or []:
        if not isinstance(via, dict):
            continue
        # Occupied set, not endpoint pair — through vias reach every layer
        # (the canonical board dict carries no stack here beyond `layers`, so
        # the declared stack, defaulted to the 2-layer pair, IS the set).
        declared = [str(x) for x in (canonical_board.get("layers")
                                     or ["top", "bottom"])]
        existing_vias.append(ExistingVia(
            net=str(via.get("net", "")) or None,
            position=(_num(via.get("x_mm")), _num(via.get("y_mm"))),
            diameter=_num(via.get("diameter_mm")) or 0.8,
            layers=tuple(_layers.canon_to_kicad(lid) for lid in declared),
            source_id=str(via.get("id")) if via.get("id") else None))

    return Board(
        pads=pads,
        nets=nets,
        obstacles=obstacles,
        width=_num(canonical_board.get("width_mm")),
        height=_num(canonical_board.get("height_mm")),
        origin=(ox, oy),
        existing_traces=existing_traces,
        existing_vias=existing_vias,
    )


def _obstacles_from_board(canonical_board: dict) -> list[Obstacle]:
    """Mounting holes -> circular obstacles (keepouts) for the router grid."""
    obstacles: list[Obstacle] = []
    for hole in canonical_board.get("mounting_holes") or []:
        if not isinstance(hole, dict):
            continue
        dia = _num(hole.get("diameter_mm")) or _num(hole.get("drill_mm"))
        radius = dia / 2.0 if dia > 0 else None
        obstacles.append(Obstacle(
            position=(_num(hole.get("x_mm")), _num(hole.get("y_mm"))),
            type="mounting_hole",
            radius=radius,
        ))
    return obstacles


# ---------------------------------------------------------------------------
# resolved_board_to_router — the IR-authoritative projection (Round E1)
# ---------------------------------------------------------------------------
# docket 019f783860c8. Canonical routing consumes REAL compiled copper or it does
# not route. Every dimension, position, side/mirror, layer participation and net
# ownership below comes from the ResolvedBoard IR; nothing is inferred from
# authored pins and nothing is defaulted.
#
# FAIL-SAFE DIRECTION (same invariant as geometric DRC, restated for keepouts):
# the modeled keepout must be a SUPERSET of the fabricated copper. Over-blocking
# is legal (the router declines a route it could have made); under-blocking is
# never legal (the router proposes copper that shorts a real land).
#
# WHY AXIS-ALIGNED ENVELOPES: agent_router's RoutingGrid.mark_pad marks an
# unrotated rectangle and DISCARDS the rotation argument it accepts
# ("Simple rectangular marking (ignoring rotation for now)"). Handing it a
# truthful w/h for a ROTATED elongated land would therefore under-block along the
# rotated axes. We hand it the axis-aligned bounding box of the real land
# instead — a strict superset, computed from the same neutral land owner the CAM
# emitters fabricate from (ir_pads.pad_copper_shape).
#
# ROUND E2 stacks a SECOND over-block on top of that one rather than replacing
# it: the grid grows every keepout it marks — pad, hole and routed trace alike —
# by `clearance + trace_width / 2` (RoutingGrid.keepout_margin, the single owner
# all three markers consult). Growing a box that already contains the rotated
# copper still contains it, so the rotation superset and the clearance
# reservation compose. Neither is a substitute for the other — the first is about
# geometry the grid cannot represent, the second about space the fabricated trace
# will occupy.


def _routing_layer_ids(rb: ResolvedBoard) -> tuple[str, ...]:
    """The engine-facing copper layer names, STACK-ORDERED, or fail closed.

    Epoch GA-2: the engine routes the board's OWN declared stack (an ordered
    grid plane per layer, through-vias reaching all of them), so the old
    exactly-F.Cu/B.Cu refusal is gone. What still fails closed is a stack
    entry whose alias is not a copper name the naming contract knows — a
    plane the grid would allocate under a name no emitter could ever write.
    Order is the resolved stack's own (outermost-first), which downstream
    consumers (via-candidate ordering, layers[0] fallbacks) depend on."""
    aliases = tuple(layer.kicad_alias for layer in rb.layer_stack.copper)
    bad = [alias for alias in aliases if not _layers.is_copper(alias)]
    if bad:
        raise UnsupportedGeometry(
            f"board copper stack carries non-copper layer name(s) {bad}; "
            f"stack is {list(aliases)}")
    return aliases


def _reject_unroutable_board(rb: ResolvedBoard) -> None:
    """Fail closed on compiled features the router cannot honour.

    Each of these would otherwise be SILENTLY ABSENT from the grid, and absent
    copper is exactly what lets a proposal cross real copper."""
    if isinstance(rb.outline, ProfileOutline):
        # A rect-outer profile (rim rectangle + interior cutouts) is routable:
        # the rim is the same rectangle routing always modelled, and each
        # cutout joins the obstacle set below (_cutout_obstacle) so the grid
        # genuinely sees it. Any other outer shape stays fail-closed.
        if profile_outer_rect(rb.outline) is None:
            raise UnsupportedGeometry(
                "routing models a rectangular board rim only; this "
                "ProfileOutline's outer contour is not an axis-aligned rectangle")
    elif not isinstance(rb.outline, RectOutline):
        raise UnsupportedGeometry(
            f"routing v1 models a rectangular (RectOutline) board only; got "
            f"{type(rb.outline).__name__}")
    # KEEPOUT zones are no longer a refusal (Epoch UX3 station 2, K6 —
    # closing router item 019fc155bc32 the way its refusal message said the
    # fix belonged: in the grid's rasteriser). The engine's obstacle loops now
    # read ``Obstacle.polygon``/``layer``/``blocks_all_layers`` and rasterise
    # them per layer (``RoutingGrid.mark_keepout_polygon``), so an authored
    # keepout becomes exactly what it means: a region the router routes
    # AROUND, on the layer(s) it names. The projection happens in
    # ``_keepout_obstacle`` below; what stays fail-closed there is the
    # geometry this projection cannot express faithfully (arc contour
    # segments), same doctrine as every other entry here.
    # COPPER POURS ARE DELIBERATELY NOT AN OBSTACLE — and this is a narrowing of a
    # refusal, so read the reason before widening it back.
    #
    # This function used to reject ANY zone, which meant DRAWING A POUR MADE THE
    # BOARD UNROUTABLE: seven zone MCP tools and a canvas zone tool ship, so a
    # user could break routing by using a shipped feature (C6 decider, "worse than
    # feature missing"). The fix is not to relax the fail-closed rule but to
    # observe that the rule never applied to a pour in the first place.
    #
    # The other entries here fail closed because they are copper the grid CANNOT
    # SEE, and invisible copper is what lets a proposal cross real copper. A pour
    # is the opposite case: it is copper that YIELDS. The fill is computed after
    # routing, from the routed result, and carves itself back by the clearance
    # around every foreign-net trace and via the router laid down. A trace cannot
    # collide with a pour, because the pour is defined as the region left over
    # once that trace has taken its clearance. Treating it as an obstacle would
    # not be conservative; it would be WRONG — it would refuse to route through
    # the exact area a pour exists to make routable.
    #
    # Two real limits of v1, stated rather than papered over:
    #   * SAME-NET REDUNDANCY. A GND pour already connects its pads, so the
    #     router may lay GND traces the pour makes unnecessary. Redundant
    #     same-net copper is harmless, just not optimal.
    #   * ISLANDING. A trace crossing a pour can cut it into pieces, and v1 does
    #     not detect a pour severed into isolated islands. That is a pour-quality
    #     gap, NOT copper the router is unaware of — it costs pour connectivity,
    #     it does not produce a short.
    if any(g.layer.role is LayerRole.COPPER for g in rb.board_graphics) or any(
            g.layer.role is LayerRole.COPPER
            for comp in rb.components for g in comp.placed_graphics):
        raise UnsupportedGeometry(
            "copper board/placed graphics are not modeled by the routing grid; "
            "routing fails closed rather than route through unmodeled copper")


def _pad_copper_layer(ir_pad, routable: tuple[str, ...]) -> str:
    """The engine layer name an SMD pad's copper sits on (IR-authoritative side).

    A pad whose copper is not on a routable layer fails closed: the engine's own
    fallback for an unrecognised layer is to mark the pad on F.Cu (router.py:393),
    which would place a bottom-side or inner-layer land on the top layer."""
    copper = tuple(layer.id for layer in ir_pad.pad.layers
                   if layer.role is LayerRole.COPPER)
    if len(copper) != 1:
        raise UnsupportedGeometry(
            f"pad {ir_pad.ref}.{ir_pad.number}: surface pad participates on "
            f"{list(copper)} copper layers; the routing grid models exactly one")
    if copper[0] not in routable:
        raise UnsupportedGeometry(
            f"pad {ir_pad.ref}.{ir_pad.number}: copper layer {copper[0]!r} is not "
            f"routable ({list(routable)})")
    return copper[0]


def _router_pad(ir_pad, routable: tuple[str, ...]) -> Pad:
    """One IR pad as an engine Pad whose extent CONTAINS the fabricated land."""
    box = pad_copper_shape(ir_pad).aabb()
    position = ((box.min_x + box.max_x) / 2.0, (box.min_y + box.max_y) / 2.0)
    size = (box.max_x - box.min_x, box.max_y - box.min_y)
    if ir_pad.is_drilled:
        # Through-hole copper spans every copper layer; the engine keys that off
        # pad_type (router.py:390) and marks all routing layers.
        drill = ir_pad.pad.drill
        return Pad(
            component=ir_pad.ref, number=ir_pad.human_number, net=None,
            position=position, size=size, shape="rect", pad_type="thru_hole",
            drill=max(float(drill.size[0]), float(drill.size[1])),
            layer="*.Cu",
            # rotation is DELIBERATELY 0.0: `size` is already the axis-aligned
            # envelope of the rotated land. Passing the true rotation would
            # double-count the moment the engine starts honouring it.
            rotation=0.0)
    return Pad(
        component=ir_pad.ref, number=ir_pad.human_number, net=None,
        position=position, size=size, shape="rect", pad_type="smd",
        drill=None, layer=_pad_copper_layer(ir_pad, routable), rotation=0.0)


def _npth_obstacle(ir_pad) -> Obstacle:
    """A bare mechanical (NPTH) component hole: an obstacle, never a route target.

    It carries no copper land, so it is not a Pad — a Pad would be both phantom
    copper and a connectable endpoint the net list never asked for. It needs no
    pad NUMBER either: KiCad routinely leaves these unnumbered (019f97eb6adf) and
    an obstacle is never addressed by name."""
    drill = ir_pad.pad.drill
    radius = max(float(drill.size[0]), float(drill.size[1])) / 2.0
    return Obstacle(position=tuple(ir_pad.pad.position), type="npth_pad",
                    radius=radius)


def _unaddressable_copper_obstacle(ir_pad) -> Obstacle:
    """Real copper with no authored pad number: a keepout, not an endpoint.

    Such a pad cannot be named by a net ref, a hint or the panel, so it must never
    become a routable Pad — but it IS copper, so it must still block. Blocked by
    the disc that CONTAINS its land (same fail-safe direction as every other
    keepout here: over-block, never under-block)."""
    box = pad_copper_shape(ir_pad).aabb()
    centre = ((box.min_x + box.max_x) / 2.0, (box.min_y + box.max_y) / 2.0)
    radius = math.hypot(box.max_x - box.min_x, box.max_y - box.min_y) / 2.0
    return Obstacle(position=centre, type="unaddressable_pad", radius=radius)


def _keepout_obstacle(zone) -> Obstacle:
    """An authored KEEPOUT zone as a polygon obstacle, layer scope intact.

    Epoch UX3 station 2 (K6): the projection the old fail-closed refusal was
    waiting for. The outline's LINE segments become the polygon vertex loop
    verbatim — no disc approximation, so a long thin keepout (the antenna
    cut-out case the refusal named) blocks exactly its own area plus the
    grid's uniform keepout margin. The layer survives too: a single-side
    copper zone blocks only its own layer; a wildcard (``*.Cu``) or sideless
    copper zone blocks every routing layer — the fail-safe reading of "the
    author did not narrow it".

    What stays fail-closed: an ARC contour segment. Flattening one faithfully
    is a tessellation-tolerance decision this projection should not invent
    (an under-flattened arc would UNDER-block its convex side — the illegal
    direction), so a keepout with arc segments refuses by name instead."""
    points: list[tuple[float, float]] = []
    for seg in zone.authored_outline.segments:
        if not isinstance(seg, LineGeometry):
            raise UnsupportedGeometry(
                f"keepout zone {zone.id}: outline carries a "
                f"{type(seg).__name__} segment; routing models straight-edged "
                f"keepouts only (an approximated arc could under-block its "
                f"convex side, which is never legal)")
        points.append((float(seg.a[0]), float(seg.a[1])))
    if len(points) < 3:
        raise UnsupportedGeometry(
            f"keepout zone {zone.id}: outline has {len(points)} usable "
            f"vertices; a region needs at least three")
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    centre = ((min(xs) + max(xs)) / 2.0, (min(ys) + max(ys)) / 2.0)
    # Layer scope by LAYER ID, not by Side (epoch GA-2): an inner-layer
    # keepout used to fall through the side test to "blocks all layers" —
    # fail-safe but over-blocking. The zone's own copper layer id names the
    # exact plane; anything that is not a single copper layer (wildcard,
    # oddball) keeps the all-layers fail-safe reading.
    layer_alias: str | None = None
    if not zone.layer.is_wildcard and _layers.is_copper(zone.layer.id):
        layer_alias = _layers.canon_to_kicad(zone.layer.id)
    return Obstacle(
        position=centre,
        type="keepout",
        polygon=points,
        blocks_all_layers=layer_alias is None,
        layer=layer_alias,
    )


def _cutout_obstacle(cut, edge_clearance_mm: float) -> Obstacle:
    """An interior board CUTOUT as an all-layer polygon obstacle, PRE-INFLATED
    by the copper-to-edge rule.

    WHY PRE-INFLATE. The grid's rasteriser blocks cells within its uniform
    ``keepout_margin`` (clearance + half trace width) of the polygon — the
    right band for a KEEPOUT, whose rule IS the copper clearance. A cutout's
    rule is ``copper_to_edge_mm`` (a slot edge is a board edge, GC5), which is
    usually LARGER, so the raw contour would let a route hug the slot at
    clearance distance and fail the DRC this projection exists to pre-satisfy.
    Handing the rasteriser the contour inflated by copper_to_edge makes the
    reserved band copper_to_edge + clearance + half width — never LESS than
    the rule, over by the margin's clearance term, which is the legal
    direction (a slightly shy router, never an illegal route).

    Straight-edged CONVEX cutouts only, both refusals loud: an arc's faithful
    flattening is a tessellation-tolerance decision this projection must not
    invent (same doctrine as :func:`_keepout_obstacle`), and mitre-offsetting a
    REFLEX vertex needs a real offset kernel (the fill kernel uses pyclipper
    for exactly that) — a hand-rolled reflex mitre under-reserves the concave
    pocket, the illegal direction.

    MITER JOINS ARE UNCAPPED, deliberately. A needle-sharp convex vertex
    miters to a long spike (length d/sin(half-angle)) that over-reserves board
    area — the FAIL-SAFE direction (a shy router, never an illegal route). The
    tempting cap — beveling the corner — is the ILLEGAL direction: the true
    offset boundary at a convex vertex is an arc of radius d that bulges
    outside the bevel chord, so a bevel under-reserves the crescent between
    them. Cap nothing; a pathologically sharp cutout costs routability, not
    correctness."""
    points: list[tuple[float, float]] = []
    for seg in cut.contour.segments:
        if not isinstance(seg, LineGeometry):
            raise UnsupportedGeometry(
                f"cutout {cut.id}: contour carries a {type(seg).__name__} "
                f"segment; routing models straight-edged cutouts only")
        points.append((float(seg.a[0]), float(seg.a[1])))
    if len(points) < 3:
        raise UnsupportedGeometry(
            f"cutout {cut.id}: contour has {len(points)} usable vertices; "
            f"a region needs at least three")

    count = len(points)
    # NORMALIZED cross products (unit-edge sines), so the collinearity
    # threshold is scale-invariant and consistent with the miter branch's
    # parallel test below (cold review CPN1-S1 finding 6: the raw cross is
    # mm^2-scaled, so "collinear" depended on edge length). Compile has
    # already refused self-intersecting rings, so consistent signs on a
    # SIMPLE polygon genuinely mean convex (a pentagram — consistent signs,
    # not simple — cannot reach here).
    cross_signs: list[float] = []
    for index in range(count):
        ax, ay = points[index]
        bx, by = points[(index + 1) % count]
        cx, cy = points[(index + 2) % count]
        l1 = math.hypot(bx - ax, by - ay) or 1.0
        l2 = math.hypot(cx - bx, cy - by) or 1.0
        cross_signs.append(
            ((bx - ax) * (cy - by) - (by - ay) * (cx - bx)) / (l1 * l2))
    nonzero = [c for c in cross_signs if abs(c) > 1e-9]
    if nonzero and (min(nonzero) < 0 < max(nonzero)):
        raise UnsupportedGeometry(
            f"cutout {cut.id}: contour is concave; routing inflates convex "
            f"cutouts only (a hand-rolled reflex mitre would under-reserve "
            f"the pocket)")

    area2 = sum((points[i][0] * points[(i + 1) % count][1]
                 - points[(i + 1) % count][0] * points[i][1])
                for i in range(count))
    ccw = area2 > 0
    d = max(0.0, float(edge_clearance_mm))
    inflated: list[tuple[float, float]] = []
    for index in range(count):
        p_prev = points[index - 1]
        p = points[index]
        p_next = points[(index + 1) % count]
        e1 = (p[0] - p_prev[0], p[1] - p_prev[1])
        e2 = (p_next[0] - p[0], p_next[1] - p[1])
        len1 = math.hypot(*e1) or 1.0
        len2 = math.hypot(*e2) or 1.0
        u1 = (e1[0] / len1, e1[1] / len1)
        u2 = (e2[0] / len2, e2[1] / len2)
        n1 = (u1[1], -u1[0]) if ccw else (-u1[1], u1[0])
        n2 = (u2[1], -u2[0]) if ccw else (-u2[1], u2[0])
        a1 = (p_prev[0] + n1[0] * d, p_prev[1] + n1[1] * d)
        a2 = (p[0] + n2[0] * d, p[1] + n2[1] * d)
        denom = u1[0] * u2[1] - u1[1] * u2[0]
        if abs(denom) < 1e-12:
            inflated.append((p[0] + n1[0] * d, p[1] + n1[1] * d))
            continue
        t = ((a2[0] - a1[0]) * u2[1] - (a2[1] - a1[1]) * u2[0]) / denom
        inflated.append((a1[0] + t * u1[0], a1[1] + t * u1[1]))

    xs = [p[0] for p in inflated]
    ys = [p[1] for p in inflated]
    centre = ((min(xs) + max(xs)) / 2.0, (min(ys) + max(ys)) / 2.0)
    return Obstacle(
        position=centre,
        type="cutout",
        polygon=inflated,
        blocks_all_layers=True,
        layer=None,
    )


def _hole_obstacle(hole) -> Obstacle:
    """A board-level hole as a circumscribing disc obstacle.

    The engine's only obstacle primitive the grid consumes is a disc
    (``mark_obstacle``; ``Obstacle.polygon`` is declared but read nowhere), so an
    oval or slot is blocked by the disc that CONTAINS it — over-blocking, which is
    the safe direction. A PLATED hole blocks its copper ANNULUS, not merely its
    drill: the copper is what a trace must not cross."""
    feature = hole.feature
    if isinstance(feature, RoundHole):
        centre = feature.position
        radius = feature.diameter_mm / 2.0
    elif isinstance(feature, OvalHole):
        centre = feature.position
        # Rotation-invariant containment: the disc through the oval's corners.
        radius = math.hypot(feature.width_mm, feature.height_mm) / 2.0
    elif isinstance(feature, SlotHole):
        xs = [p[0] for p in feature.path]
        ys = [p[1] for p in feature.path]
        centre = ((min(xs) + max(xs)) / 2.0, (min(ys) + max(ys)) / 2.0)
        span = math.hypot(max(xs) - min(xs), max(ys) - min(ys))
        radius = span / 2.0 + feature.width_mm / 2.0
    else:
        raise UnsupportedGeometry(
            f"board hole {hole.id}: geometry {type(feature).__name__} has no "
            f"conservative disc the routing grid can consume")
    if hole.plated and hole.annulus_mm:
        radius = max(radius, float(hole.annulus_mm) / 2.0)
    return Obstacle(position=tuple(centre), type="mounting_hole", radius=radius)


def resolved_board_to_router(rb: ResolvedBoard) -> Board:
    """Project a compiled :class:`ResolvedBoard` onto the engine's ``Board``.

    THE fail-closed seam for canonical routing (Round E, docket 019f783860c8):
    every pad extent, position, side, layer and net here is IR-authoritative, so
    the copper the router keeps out of is the copper the CAM emitters fabricate
    and geometric DRC checks — one owner, no drift. Anything the grid cannot
    faithfully model raises :class:`UnsupportedGeometry`; the caller turns that
    into zero routes plus diagnostics, never a proposal over guessed copper.

    DESIGN RULES DO RIDE THIS PROJECTION (019f9bc3909c; they did not in Round
    E2). ``Board.design_rules`` now carries the IR's own ``ResolvedDesignRules``
    unchanged, so a Board built here inherits its board's rules BY CONSTRUCTION
    instead of the caller having to remember a matching pair of run options —
    which is exactly what ``agent_router.cli`` failed to do (bug 019f9b38a93f).
    The rules are still not APPLIED here: the effective pair is resolved by
    ``agent_router.router.resolve_effective_rules`` (which documents the
    precedence, and which run options still override) and passed to
    ``route_board``/``route_board_with_hints``. The
    grid then inflates every keepout it marks — including the ones it lays down
    for its own routed traces — by ``clearance + trace_width / 2``
    (agent_router/grid.py::keepout_margin), which COMPOSES with
    the axis-aligned envelopes here: growing a box that already contains the
    rotated land still contains it, so the rotation superset and the clearance
    reservation stack rather than compete.

    ACCEPTED COPPER IS NOT PART OF THIS PROJECTION, but it is no longer refused
    either (T7 019f70ebc9ed): it comes across through
    :func:`resolved_board_existing_copper`, which the caller invokes beside this
    one and passes to the engine as run options. See that function for why it
    cannot ride on the ``Board``.

    NOT APPLIED here, by design (each has its own owner, none of them silent):
      * per-net-class width/clearance minima. A board AUTHORS its classes under
        ``design_rules.net_classes`` and the compiler emits them, so the
        ``ResolvedDesignRules`` copied onto ``Board.design_rules`` here carries
        the classes themselves. MEMBERSHIP DOES NOT COME ACROSS: the engine's
        :class:`~agent_router.board.Net` models ``name``/``number``/``pads`` and
        nothing else, so the per-net ``ResolvedNet.net_class_id`` — the link
        that decides which net a class applies to — has no slot in this
        projection and is dropped by it.

        That is not a loss, because nothing downstream of here reads it off the
        projection. ``methods._net_class_overrides`` resolves the classes
        against the COMPILED IR, not against this ``Board``, and hands the
        engine a per-net ``net_widths`` map as a run option; the grid's keepout
        margin is separately widened to the board-wide worst case
        (``methods._widen_for_net_classes``). So a run is NOT one width and one
        clearance — it is one baseline pair plus a per-net width override — but
        none of that is decided, or representable, here.
    """
    _reject_unroutable_board(rb)
    routable = _routing_layer_ids(rb)

    pads: list[Pad] = []
    obstacles: list[Obstacle] = []
    pad_by_id: dict[str, Pad] = {}
    for ir_pad in iter_ir_pads(rb):
        if not ir_pad.carries_copper:
            obstacles.append(_npth_obstacle(ir_pad))
            continue
        if not ir_pad.is_addressable:
            # Copper with no authored pad number (019f97eb6adf). It cannot be a
            # routed endpoint — nothing could name it — but it is real copper and
            # must block. Degrading it to a conservative obstacle keeps the board
            # routable; a NETTED one cannot degrade, because the net list claims an
            # endpoint that has no address.
            if ir_pad.pad.net_id is not None:
                raise UnsupportedGeometry(
                    f"component {ir_pad.ref!r}: pad {ir_pad.source_number!r} is on "
                    f"net {ir_pad.net_name!r} but has no authored pad number — a "
                    f"netted endpoint that nothing can address")
            obstacles.append(_unaddressable_copper_obstacle(ir_pad))
            continue
        pad = _router_pad(ir_pad, routable)
        pads.append(pad)
        pad_by_id[ir_pad.pad.id] = pad

    nets: dict[str, Net] = {}
    for resolved_net in rb.nets:
        net = Net(name=resolved_net.name, number=resolved_net.index, pads=[])
        for pad_ref in resolved_net.pad_refs:
            pad = pad_by_id.get(pad_ref)
            if pad is None:
                # The IR guarantees pad_refs resolve, so the only way to get here
                # is a net member that carries no copper (an NPTH pad). Routing to
                # it is impossible; failing closed beats silently dropping a net
                # member and reporting the net "routed".
                raise UnsupportedGeometry(
                    f"net {resolved_net.name!r} references pad {pad_ref} which "
                    f"carries no routable copper")
            pad.net = resolved_net.name
            net.pads.append(pad)
        nets[resolved_net.name] = net

    obstacles.extend(_hole_obstacle(hole) for hole in rb.holes)
    # Authored keepout zones join the obstacle set with their polygon + layer
    # scope intact (Epoch UX3 station 2, K6 — see _keepout_obstacle).
    obstacles.extend(
        _keepout_obstacle(zone) for zone in rb.zones
        if zone.kind is ZoneKind.KEEPOUT)
    # Interior cutouts join it too (epoch CPN1) — pre-inflated by the
    # copper-to-edge rule, all layers; see _cutout_obstacle for the math.
    obstacles.extend(
        _cutout_obstacle(cut, rb.design_rules.minimums.copper_to_edge_mm)
        for cut in outline_cutouts(rb.outline))

    frame_ox, frame_oy, frame_w, frame_h = outline_frame(rb.outline)
    return Board(
        pads=pads,
        nets=nets,
        obstacles=obstacles,
        width=frame_w,
        height=frame_h,
        origin=(frame_ox, frame_oy),
        # The board's OWN rules now ride the projection (019f9bc3909c). The IR's
        # ``ResolvedDesignRules`` is handed over UNCHANGED — ``Board.design_rules``
        # is duck-typed on exactly the two paths the precedence chain reads
        # (``defaults.trace_width_mm`` / ``minimums.min_clearance_mm``), so there
        # is no translation step between what the compiler decided and what the
        # router routes at, and therefore nothing to drift.
        design_rules=rb.design_rules,
    )


def resolved_board_existing_copper(
    rb: ResolvedBoard,
) -> tuple[list[ExistingSegment], list[ExistingVia]]:
    """Project the board's ALREADY-ACCEPTED traces and vias for the routing grid.

    T7, docket 019f70ebc9ed. Until this landed, ANY accepted copper made a board
    unroutable (``_reject_unroutable_board`` raised on ``rb.traces or rb.vias``):
    the grid saw pads and holes only, so accepted copper was invisible and a fresh
    proposal could be laid straight across it. That was the right call while the
    grid could not model existing copper — but it also meant the FIRST accepted
    proposal ended the incremental workflow, which is the workflow the plugin
    exists for.

    It rides BESIDE :func:`resolved_board_to_router` rather than inside its
    ``Board`` for the same reason the effective width/clearance pair does (see
    that function's "DESIGN RULES DO NOT RIDE THIS PROJECTION"): ``agent_router.
    Board`` is also what ``Board.from_kicad`` builds, and this round's fence does
    not reach it. The caller (``pcb_worker.methods._route``) passes both to
    ``route_board``/``route_board_with_hints``, inside the SAME
    ``UnsupportedGeometry`` boundary — so a board that cannot be projected here
    fails closed identically to one that cannot be projected there.

    Dimensions are the copper's OWN authored ones (``width_mm``,
    ``diameter_mm``) — this is copper that already physically exists, so there is
    nothing to resolve and nothing to invent. Only the keepout MARGIN around it
    belongs to the run, and the grid owns that (``RoutingGrid.keepout_margin``).

    The per-SEGMENT decomposition is deliberately the same one
    ``ir_connectivity.connectivity_board`` uses for the same IR traces: one
    2-point piece per ``ResolvedTraceSegment``. Both consumers then reason about
    the identical pieces of copper, which is the whole point of one compile
    feeding every half of the reply (019f97d021a8).
    """
    routable = _routing_layer_ids(rb)
    net_name_by_id = {net.id: net.name for net in rb.nets}

    segments: list[ExistingSegment] = []
    for trace in rb.traces:
        net_name = net_name_by_id.get(trace.net_id)
        for seg in trace.segments:
            # ``ResolvedTraceSegment.layer`` is a plain ``Layer`` whose ``id`` is
            # the CANONICAL name ("top"/"bottom") — NOT the ``kicad_alias`` the
            # layer-STACK entries carry. The engine speaks KiCad aliases, so the
            # hop goes through the one canonical map (agent_router.layers), which
            # exists precisely because a duplicated copy of it once drifted and
            # produced the two-emitter via bug.
            layer = _layers.canon_to_kicad(seg.layer.id)
            if layer not in routable:
                # Defence in depth, matching _pad_copper_layer: the IR already
                # validates every segment onto the compiled copper stack and
                # _routing_layer_ids already refused any stack that is not
                # F.Cu/B.Cu, so this is unreachable today. Kept because the
                # failure it guards is silent invisible copper.
                raise UnsupportedGeometry(
                    f"accepted trace {trace.id}: segment on copper layer "
                    f"{layer!r} is not routable ({list(routable)}); the routing "
                    f"grid would not see it")
            segments.append(ExistingSegment(
                net=net_name,
                start=(float(seg.a[0]), float(seg.a[1])),
                end=(float(seg.b[0]), float(seg.b[1])),
                width=float(seg.width_mm),
                layer=layer,
                # HITL-4 (docs/llm-ergonomics.md F1): the TRACE's id, not the
                # per-segment one — an `already_connected` span outcome names
                # the copper a human can find on the board, and the board
                # knows its traces, not this decomposition's segments.
                source_id=str(trace.id)))

    vias: list[ExistingVia] = []
    for via in rb.vias:
        endpoints = tuple(dict.fromkeys(
            _layers.canon_to_kicad(lid) for lid in (via.from_layer, via.to_layer)))
        unroutable = [lid for lid in endpoints if lid not in routable]
        if unroutable:
            # A span whose ENDPOINT names a layer this board's grid does not
            # carry. The v1 compiler cannot emit one (via_bad_span validates
            # endpoints against [top, bottom], which every legal stack
            # contains), so this is the same defence-in-depth as above — half
            # a via's copper modeled and half of it invisible is worse than
            # not routing the board.
            raise UnsupportedGeometry(
                f"accepted via {via.id}: spans {list(unroutable)}, which the "
                f"routing grid does not model ({list(routable)})")
        # ``ExistingVia.layers`` is the OCCUPIED set, not the endpoint pair
        # (epoch GA-2): a through via's annulus exists on EVERY stack layer it
        # crosses, so the endpoint span expands to the inclusive index range
        # in stack order. On a 2-layer stack this is byte-identically the old
        # endpoint tuple; on a deeper one it is what keeps _copper_union
        # seeing a via↔inner-segment junction and _mark_existing_copper
        # blocking the inner annuli.
        indices = [routable.index(lid) for lid in endpoints]
        lo, hi = min(indices), max(indices)
        span = tuple(routable[lo:hi + 1])
        # A via's copper is its ANNULUS, and an authored padstack may make that
        # annulus wider on some layer than the nominal diameter. Take the widest
        # — same fail-safe direction as every other keepout in this module: the
        # modeled copper must be a SUPERSET of the fabricated copper.
        diameter = float(via.diameter_mm)
        if via.padstack is not None:
            diameter = max([diameter] + [float(lp.diameter_mm)
                                         for lp in via.padstack.per_layer])
        vias.append(ExistingVia(
            net=net_name_by_id.get(via.net_id),
            position=(float(via.position[0]), float(via.position[1])),
            diameter=diameter,
            layers=span,
            # HITL-4 (docs/llm-ergonomics.md F1): same best-effort span-outcome
            # attribution as the segments above.
            source_id=str(via.id)))

    return segments, vias


# ---------------------------------------------------------------------------
# PINNED-CANDIDATE COPPER — the "treat the rest as FIXED" half of DCR finding 7
# ---------------------------------------------------------------------------
# WHAT WAS ALREADY SHIPPED, and therefore is NOT rebuilt here (measured at
# minerva-plugins a978d06):
#
#   * ACCEPTED copper -> engine keepouts: ``resolved_board_existing_copper``
#     above (T7, 019f70ebc9ed), wired at ``pcb_worker.methods._route``.
#   * CANDIDATE dicts -> IR traces/vias: ``ir_candidates.build_overlay``
#     (019f952b99f2). It is already fail-closed on every dimension (no guessed
#     width, no guessed via size, no invented layer), already names the offending
#     candidate (``UnmodelableCandidate``), and already returns a ResolvedBoard
#     that is ``base + candidate`` copper rather than candidates alone.
#
# WHAT WAS MISSING is the composition of those two: a routing run could not see
# PINNED draft copper at all. ``route()`` accepted no candidate parameter — only
# ``draft_check`` and the geometric DRC did — so a run scoped to one task routed
# as if every pinned candidate on the board were empty space, and could propose
# copper straight through a route the user had already decided to keep. That is
# the same invisible-copper failure T7 fixed for ACCEPTED copper, one lifecycle
# state earlier.
#
# It is a composition and not a second projection on purpose: a private
# candidate->keepout path here would be a second candidate LANGUAGE, and the two
# would drift exactly the way ``_draft_check``'s coercion and the geometric one
# drifted before ``ir_candidates`` was made their common owner.


def existing_copper_with_pinned(
    rb: ResolvedBoard,
    pinned_candidates: Any = None,
    *,
    default_width_mm: float | None = None,
    default_via_diameter_mm: float | None = None,
    default_via_drill_mm: float | None = None,
) -> tuple[list[ExistingSegment], list[ExistingVia]]:
    """The board's fixed copper — ACCEPTED plus PINNED-candidate — for the grid.

    Pinned candidates enter through the SAME projection as accepted copper, with
    their own net name, so the engine treats them identically: other-net copper
    is an obstacle marked at the run's keepout margin, same-net copper is already
    connected and may be pathed along. That is the correct reading of a pin — a
    pinned candidate is a decision the user has made and the run must not
    relitigate, which is precisely what ``existing`` means to the engine.

    FAIL-CLOSED, and deliberately fatal to the whole run rather than to the one
    candidate: a pinned candidate that cannot be modeled is copper the grid would
    not see, and a run over a partially-visible board can return a proposal that
    shorts it. ``ir_candidates.build_overlay`` raises ``UnmodelableCandidate``
    (an ``UnsupportedGeometry``), which the caller's existing
    ``UnsupportedGeometry`` boundary already turns into a structured zero-route
    reply naming the candidate.

    ``pinned_candidates`` empty/None is the pre-existing behaviour exactly —
    accepted copper only, no overlay built.
    """
    if not pinned_candidates:
        return resolved_board_existing_copper(rb)
    if not isinstance(pinned_candidates, list):
        raise UnsupportedGeometry(
            f"pinned_candidates must be a list of candidate mappings, got "
            f"{type(pinned_candidates).__name__}")
    # Imported here, not at module scope: ir_candidates pulls in drc_geometric,
    # and this module is imported by the hint helpers on paths that need neither.
    from . import ir_candidates

    overlay = ir_candidates.build_overlay(
        rb, pinned_candidates,
        default_width_mm=default_width_mm,
        default_via_diameter_mm=default_via_diameter_mm,
        default_via_drill_mm=default_via_drill_mm)
    return resolved_board_existing_copper(overlay.board)


# ---------------------------------------------------------------------------
# RUN SCOPE — the explicit task/span argument (the other half of finding 7)
# ---------------------------------------------------------------------------
# WHAT WAS ALREADY SHIPPED: a run scope EXISTS (019f80a80123). The engine takes
# ``only_nets`` (agent_router/router.py::_scoped_nets) and honours the
# None-vs-empty-set distinction, and ``pcb_worker.methods._route`` builds that
# set. Nothing of that is rebuilt here.
#
# WHAT WAS MISSING: the set is INFERRED, and only from route-hint annotations —
# ``methods._route`` computes it inside ``if envelopes:`` and leaves it ``None``
# otherwise. So "route this ONE task and leave everything else alone" could not
# be ASKED for: a caller with a workspace RouteTask in hand and no hint
# annotation got a whole-board run. This turns the scope into a first-class
# argument the caller states.
#
# SPAN SCOPING IS SUPPORTED (docket 019fcb6f9d20; formerly refused — the
# refusal was the record of gap 019fc155bc32, and the enabling engine change
# has landed). A RouteTask naming ENDPOINTS that are a proper subset (2+) of a
# multi-pad net resolves to a per-net TERMINAL set, handed to the engine as
# ``net_terminals`` (agent_router/router.py::_terminal_pads): the engine
# connects ONLY the named pads and the omitted same-net pads keep their grid
# presence without becoming connection targets. "Connect MIC1.6 to AMP1.6"
# on a 14-pad GND net returns exactly that span. What is STILL refused, not
# reinterpreted: a malformed spec, a task with no net, an endpoint not on its
# net, and a single-endpoint task (one pad is not a routable span). Two tasks
# naming the same net merge their terminal sets — the engine routes one tree
# over the union, which is the closest expressible answer and is named in the
# scope's warnings so the caller sees the merge.


class UnsupportedRouteScope(ValueError):
    """An explicit run scope this bridge will not silently reinterpret."""


@dataclass(frozen=True)
class RouteScope:
    """A resolved run scope: which nets route, and what the caller was told.

    ``nets`` is handed to the engine as ``only_nets``. An EMPTY frozenset is a
    real answer meaning "scoped, and nothing was in scope" (routes nothing) —
    never conflated with no scope at all, which is ``None`` from
    :func:`parse_route_scope`.
    """

    nets: frozenset
    task_ids: tuple
    warnings: tuple = ()
    # Span scoping (docket 019fcb6f9d20): net name -> frozenset of
    # "Component.Pad" terminal refs. Only nets whose task named a PROPER
    # subset of the net's pads appear here; a whole-net task carries no entry
    # (byte-identical to the pre-span behaviour). Handed to the engine as
    # ``net_terminals``.
    net_terminals: Optional[dict] = None


def _scope_task_nets(task: Any, ordinal: int, pads_by_net: dict) -> tuple:
    """One scope task -> (task_id, net_name or None, terminals or None,
    warning or None).

    ``terminals`` is a frozenset of "Component.Pad" refs when the task named a
    PROPER subset (2+) of the net's pads — the span form (docket
    019fcb6f9d20). ``None`` means whole-net (no endpoints, or endpoints that
    name every pad the net has)."""
    if not isinstance(task, dict):
        raise UnsupportedRouteScope(
            f"scope.tasks[{ordinal}]: expected a mapping, got "
            f"{type(task).__name__}")
    task_id = str(task.get("task_id", "") or f"task:{ordinal}")
    net = task.get("net")
    if not isinstance(net, str) or not net:
        raise UnsupportedRouteScope(
            f"scope task {task_id!r}: no net named — a task's net is what the "
            f"run is scoped to and there is nothing to infer it from")

    terminals = None
    endpoints = task.get("endpoints")
    if endpoints is not None:
        if not isinstance(endpoints, list):
            raise UnsupportedRouteScope(
                f"scope task {task_id!r}: endpoints must be a list of "
                f'"Ref.Pad" strings, got {type(endpoints).__name__}')
        named = {str(e) for e in endpoints}
        on_net = pads_by_net.get(net)
        if on_net is not None:
            unknown = sorted(named - on_net)
            if unknown:
                raise UnsupportedRouteScope(
                    f"scope task {task_id!r}: endpoint(s) {unknown} are not "
                    f"pads of net {net!r} ({sorted(on_net)})")
            if len(named) == 1:
                # One pad is not a routable span; approximating it to the
                # whole net would be exactly the silent widening this
                # argument exists to remove.
                raise UnsupportedRouteScope(
                    f"scope task {task_id!r}: a single endpoint "
                    f"({sorted(named)}) is not a routable span of net "
                    f"{net!r}; name 2+ pads, or omit endpoints to route the "
                    f"whole net")
            if named and named != on_net:
                # The span form: route ONLY between these pads. Resolved to a
                # terminal set the engine narrows to (agent_router
                # _terminal_pads); the omitted pads keep their grid presence.
                terminals = frozenset(named)

    if net not in pads_by_net:
        # Same disposition the bus-net scope already uses: a net the board does
        # not have is DROPPED from the scope with a warning, never ADDED to it.
        return (task_id, None, None,
                f"scope task {task_id!r} names net {net!r}, which this board "
                f"does not have — dropped from the run scope")
    return (task_id, net, terminals, None)


def parse_route_scope(spec: Any, board: Board) -> Optional[RouteScope]:
    """Resolve an explicit ``scope`` argument against the board being routed.

    ``spec`` is ``None``/absent for an unscoped run (returns ``None`` — the
    engine's "route everything", unchanged for every existing caller), or a
    mapping::

        {"tasks": [{"task_id": ..., "net": ..., "endpoints": ["U1.2", ...]}],
         "nets":  ["SIG", ...]}

    Both keys are optional and additive. ``nets`` is the plain form for a caller
    with no workspace task in hand; ``tasks`` is the RouteTask form, and carries
    the task ids back out so the reply can name what it routed.

    Refuses (``UnsupportedRouteScope``) rather than reinterprets: a malformed
    spec, a task with no net, an endpoint that is not on its net, and — the one
    that matters — a task whose endpoints name a SPAN of a multi-pad net (see
    the module note above).
    """
    if spec is None:
        return None
    if not isinstance(spec, dict):
        raise UnsupportedRouteScope(
            f"scope must be a mapping with \"tasks\" and/or \"nets\", got "
            f"{type(spec).__name__}")
    unknown_keys = sorted(set(spec) - {"tasks", "nets"})
    if unknown_keys:
        raise UnsupportedRouteScope(
            f"scope carries unknown key(s) {unknown_keys}; a scope that is "
            f"read only in part is a scope that silently widens")
    tasks = spec.get("tasks")
    nets_spec = spec.get("nets")
    if tasks is None and nets_spec is None:
        raise UnsupportedRouteScope(
            "scope names neither \"tasks\" nor \"nets\"; an empty scope would "
            "route nothing, which is a decision the caller must state")

    pads_by_net = {name: {f"{p.component}.{p.number}" for p in net.pads}
                   for name, net in board.nets.items()}

    scoped: set = set()
    task_ids: list = []
    warnings: list = []
    span_terminals: dict = {}

    if tasks is not None:
        if not isinstance(tasks, list):
            raise UnsupportedRouteScope(
                f"scope.tasks must be a list, got {type(tasks).__name__}")
        for ordinal, task in enumerate(tasks):
            task_id, net, terminals, warning = _scope_task_nets(
                task, ordinal, pads_by_net)
            task_ids.append(task_id)
            if warning:
                warnings.append(warning)
            if net is not None:
                scoped.add(net)
                if terminals is not None:
                    prior = span_terminals.get(net)
                    if prior is not None:
                        # Two span tasks on one net: the engine routes ONE
                        # tree per net, so the closest expressible answer is
                        # the union of both terminal sets — named, not silent.
                        span_terminals[net] = prior | terminals
                        warnings.append(
                            f"two span tasks name net {net!r}; their "
                            f"terminal sets are merged into one routed tree "
                            f"({sorted(prior | terminals)})")
                    else:
                        span_terminals[net] = terminals
                elif net in span_terminals:
                    # A whole-net task and a span task on the same net: the
                    # whole-net ask wins (it is the wider explicit statement),
                    # and the narrowing is dropped with a warning.
                    del span_terminals[net]
                    warnings.append(
                        f"a whole-net task and a span task both name net "
                        f"{net!r}; the whole-net ask wins and the span "
                        f"narrowing is dropped")

    if nets_spec is not None:
        if not isinstance(nets_spec, list):
            raise UnsupportedRouteScope(
                f"scope.nets must be a list of net names, got "
                f"{type(nets_spec).__name__}")
        for ordinal, name in enumerate(nets_spec):
            if not isinstance(name, str) or not name:
                raise UnsupportedRouteScope(
                    f"scope.nets[{ordinal}]: expected a non-empty net name, "
                    f"got {name!r}")
            if name in pads_by_net:
                scoped.add(name)
            else:
                warnings.append(
                    f"scope names net {name!r}, which this board does not have "
                    f"— dropped from the run scope")

    if nets_spec is not None:
        # A bare nets entry is a whole-net ask; it wins over any span task
        # naming the same net, same disposition as the task-vs-task case above.
        for name in (set(nets_spec) & set(span_terminals)):
            del span_terminals[name]
            warnings.append(
                f"scope.nets names {name!r} whole-net while a span task "
                f"narrows it; the whole-net ask wins and the span narrowing "
                f"is dropped")

    return RouteScope(nets=frozenset(scoped), task_ids=tuple(task_ids),
                      warnings=tuple(warnings),
                      net_terminals=dict(span_terminals) or None)


def _resolved_pad_refs(pins: Any, board: Board) -> list[str]:
    """Pin refs that ACTUALLY resolve to a pad, as ``"Component.Pad"`` strings.

    The single-endpoint contract for guided corridors (amendment A5) is a
    statement about RESOLVED pads, not about how many refs were typed: a hint
    naming two source pins of which one is a typo has one real endpoint, and
    should be treated as such rather than refused. Returns the canonical
    identity string the engine matches on (``f"{component}.{number}"``).
    """
    out: list[str] = []
    for ref in pins or []:
        comp, pad = _split_pin_ref(ref)
        if comp is None:
            continue
        hit = board.get_pad(comp, pad)
        if hit is None:
            continue
        canonical = f"{hit.component}.{hit.number}"
        if canonical not in out:
            out.append(canonical)
    return out


def _split_pin_ref(ref: Any) -> tuple[Optional[str], str]:
    """Split a "Ref.Pad" pin ref into (component, pad). ('U1.15' -> ('U1','15')).

    Uses rpartition so component refs containing dots survive. Returns
    (None, "") for a malformed / dotless ref.
    """
    if not isinstance(ref, str) or "." not in ref:
        return (None, "")
    comp, _, pad = ref.rpartition(".")
    if not comp or not pad:
        return (None, "")
    return (comp, pad)


# ---------------------------------------------------------------------------
# hints_to_router
# ---------------------------------------------------------------------------


@dataclass
class HintTranslation:
    """Result of translating route-hint envelopes.

    ``hints`` is the native ``RoutingHints`` (built via parse_hints, never a
    hand-rolled dataclass). ``warnings`` collects per-hint issues (unresolvable
    pin refs, malformed envelopes) so the caller can surface them without
    crashing. ``trace_width_mm`` is the widest authored width among the
    selected hints (per-hint width has no RoutingHints slot — see module notes;
    the caller may adopt it as the run's trace_width).

    ``nets_by_hint`` maps each selected hint's id to the net names THAT hint
    resolved to — the run's scope and its per-route attribution, both
    (019f80a80123). It is recorded by the SAME pass that already resolves each
    hint's net, never re-derived afterwards: a second resolution pass could
    disagree with the first (and would duplicate every warning
    ``_net_for_hint`` emits), which is exactly how a `proposal_for` that lies
    gets built. A hint that resolved to nothing is absent from the map, not
    present-with-an-empty-list, so "which hints were usable" stays readable.
    """
    hints: RoutingHints
    warnings: list[dict] = field(default_factory=list)
    trace_width_mm: Optional[float] = None
    selected_ids: list[str] = field(default_factory=list)
    nets_by_hint: dict[str, list[str]] = field(default_factory=dict)


# Selection modes for which hints feed a routing run.
_SELECTION_MODES = ("open", "all", "ids", "net")


def select_hints(envelopes: list[dict], selection: Any = None) -> list[dict]:
    """Filter which hint envelopes feed a run.

    Semantics (documented choice — default is conservative):
      * default / {"mode":"open"} — only OPEN-lifecycle hints. A hint the user
        already resolved/rejected must not silently re-drive routing.
      * {"mode":"all"}            — every hint regardless of lifecycle.
      * {"mode":"ids", "ids":[…]} — explicit annotation ids (order preserved).
      * {"mode":"net", "net":N}   — hints whose net_names include N (all-for-net).

    A bare list is treated as {"mode":"ids", "ids":<list>}. Unknown modes fall
    back to "open".
    """
    if not isinstance(envelopes, list):
        return []

    mode = "open"
    ids: list[str] = []
    net_filter = ""
    if isinstance(selection, list):
        mode, ids = "ids", [str(x) for x in selection]
    elif isinstance(selection, dict):
        mode = str(selection.get("mode", "open"))
        ids = [str(x) for x in (selection.get("ids") or [])]
        net_filter = str(selection.get("net", ""))
    if mode not in _SELECTION_MODES:
        mode = "open"

    out: list[dict] = []
    if mode == "ids":
        wanted = list(ids)
        by_id = {str(e.get("id", "")): e for e in envelopes if isinstance(e, dict)}
        for i in wanted:
            if i in by_id:
                out.append(by_id[i])
        return out

    for e in envelopes:
        if not isinstance(e, dict):
            continue
        if mode == "all":
            out.append(e)
        elif mode == "net":
            kp = e.get("kind_payload") or {}
            names = [str(n) for n in (kp.get("net_names") or [])]
            if net_filter and net_filter in names:
                out.append(e)
        else:  # "open"
            if str(e.get("lifecycle", "open")) == "open":
                out.append(e)
    return out


def _net_for_hint(envelope: dict, board: Board, warnings: list[dict]) -> Optional[str]:
    """Resolve the net a route hint targets.

    Priority: explicit kind_payload.net_names[0] -> the net of the first
    resolvable source pin -> the net of the first resolvable dest pin. Records
    a warning and returns None when nothing resolves.
    """
    kp = envelope.get("kind_payload") or {}
    ann_id = str(envelope.get("id", ""))

    names = [str(n) for n in (kp.get("net_names") or []) if str(n)]
    if names:
        # Trust an explicit net name only if the board actually has it; else warn.
        if names[0] in board.nets:
            return names[0]
        warnings.append({"id": ann_id, "message":
            f"net_names[0]={names[0]!r} not present on board"})
        # fall through to pin resolution

    for key in ("source_pins", "dest_pins"):
        for ref in kp.get(key) or []:
            comp, pad = _split_pin_ref(ref)
            if comp is None:
                warnings.append({"id": ann_id, "message":
                    f"{key} entry {ref!r} is not a 'Ref.Pad' reference"})
                continue
            hit = board.get_pad(comp, pad)
            if hit is None:
                warnings.append({"id": ann_id, "message":
                    f"{key} pin {ref!r} does not resolve to a pad on the board"})
                continue
            if hit.net:
                return hit.net
            warnings.append({"id": ann_id, "message":
                f"pin {ref!r} resolves to an unconnected pad (no net)"})

    if not names:
        warnings.append({"id": ann_id, "message":
            "route hint has no net_names and no resolvable source/dest pin — skipped"})
    return None


def _points_from_raw(raw: Any) -> list[list[float]]:
    """Parse a wire point list into [[x, y], …] float pairs, bit-exact.

    Tolerates both the array-pair wire shape (``[[x, y], …]``, what panels
    actually send) and a ``{"x":…, "y":…}`` dict shape (what a JSON round trip
    of a GDScript Vector2 corridor also produces — see PcbRouteTask's own
    _constraint_to_json). Anything else in the list is skipped rather than
    raising: one malformed point must not blank the whole corridor.
    """
    out: list[list[float]] = []
    if isinstance(raw, list):
        for wp in raw:
            if isinstance(wp, (list, tuple)) and len(wp) >= 2:
                out.append([float(wp[0]), float(wp[1])])
            elif isinstance(wp, dict) and "x" in wp and "y" in wp:
                out.append([float(wp["x"]), float(wp["y"])])
    return out


def _waypoints_of(envelope: dict) -> list[list[float]]:
    """Extract waypoints as [[x, y], …] in exact board mm (no rounding).

    Reads kind_payload.waypoints (the authoritative pixel-accurate polyline the
    panel stores as [[x_mm, y_mm], …]). Each coordinate is passed through
    float() only — an identity on values already float, so no drift.
    """
    kp = envelope.get("kind_payload") or {}
    return _points_from_raw(kp.get("waypoints"))


def _corridor_from_task_constraint(
    constraint: Any, warnings: Optional[list[dict]] = None, hint_id: str = "",
) -> tuple[list[list[float]], Optional[str], Optional[int]]:
    """Parse ONE ``task_constraints[hint_id]`` entry (Epoch UX1 station 9).

    Wire shape (panel_tools.gd's ``_task_constraints_for_hints``, mirroring
    PcbRouteTask.routing_constraint): ``{corridor_points:[[x,y],…],
    preferred_layer, revision}``. Returns (points, preferred_layer_or_None,
    revision_or_None); points is [] and the other two None for anything not a
    dict or carrying no usable corridor_points — the caller treats an empty
    result as "no override", falling back to the legacy waypoints channel
    exactly as if `task_constraints` had no entry for this hint at all.

    F10 (cold review, Epoch UX1 station 9): ``revision`` reaches this
    function straight off the wire (methods.py's ``_route`` forwards
    ``params.get("task_constraints")`` unvalidated), so a non-numeric value
    is a caller mistake, not an engine invariant — ``int()`` on it must never
    raise. A coercion failure SKIPS the whole entry (same "no override,
    fall back to legacy waypoints" degrade every other malformed shape this
    function already handles takes) and, when a `warnings` sink is given,
    records a structured note naming the hint so the caller can see why its
    steering silently did not apply.
    """
    if not isinstance(constraint, dict):
        return [], None, None
    pts = _points_from_raw(constraint.get("corridor_points"))
    if not pts:
        return [], None, None
    layer = constraint.get("preferred_layer")
    layer = str(layer) if layer else None
    raw_revision = constraint.get("revision")
    revision: Optional[int]
    if raw_revision is None:
        revision = None
    else:
        try:
            revision = int(raw_revision)
        except (TypeError, ValueError):
            if warnings is not None:
                warnings.append({
                    "id": hint_id,
                    "message":
                        "task_constraints revision %r is not numeric — this "
                        "hint's corridor override was skipped; it routed "
                        "against its own legacy kind_payload.waypoints "
                        "instead" % (raw_revision,),
                })
            return [], None, None
    return pts, layer, revision


def materialize_detailed_hints(
    hint_envelopes: list[dict],
    board: Board,
    selection: Any = None,
) -> tuple[list[dict], set, list[dict], list[str]]:
    """Materialize 'detailed' single-trace hints as routes-as-drawn.

    Native DetailLevel semantics (HITL-2 owner feedback): a hint dense enough
    to be inferred 'detailed' means "follow my line" — the human is routing
    around obstacles the engine can't see, so its waypoints are the route,
    not a soft attraction field. For each SELECTED envelope with
    hint_type=single_trace, detail_level=detailed, and BOTH endpoints
    resolvable to pads on one net, emit a serialized route dict
    (pad -> waypoints -> pad, single layer) and consume the hint + its net so
    the A* engine neither re-routes nor duplicates it. Anything that doesn't
    fully resolve is left for the engine path with a warning.

    Returns (routes, consumed_net_names, warnings, consumed_hint_ids); route
    dicts carry "as_drawn": True so callers/tests can tell the paths apart.
    """
    warnings: list[dict] = []
    routes: list[dict] = []
    consumed_nets: set = set()
    consumed_ids: list[str] = []

    for env in select_hints(hint_envelopes, selection):
        if not isinstance(env, dict) or str(env.get("kind", "")) != "pcb_route_hint":
            continue
        kp = env.get("kind_payload") or {}
        if not isinstance(kp, dict):
            continue
        if str(kp.get("hint_type", "")) != "single_trace":
            continue
        if str(kp.get("detail_level", "")) != "detailed":
            continue
        if bool(kp.get("allow_layer_change")):
            # U3 (epoch GA-2, item 019f709e9dbd): a detailed hint that OPTS
            # INTO engine layer changes is NOT materialized verbatim — its
            # verbatim single-layer segments with vias:[] are exactly the
            # bypass this item exists to close. It falls through to
            # hints_to_router, which routes it as a waypoint-carrying
            # connection hint: the engine follows the drawn line and may
            # break onto another layer through the normal costed via
            # machinery, so engine-auto vias reach the board via the
            # standard lossless path.
            continue
        ann_id = str(env.get("id", ""))

        def _endpoint(key: str):
            for ref in kp.get(key) or []:
                comp, pad = _split_pin_ref(ref)
                if comp is None:
                    continue
                hit = board.get_pad(comp, pad)
                if hit is not None:
                    return hit
            return None

        src = _endpoint("source_pins")
        dst = _endpoint("dest_pins")
        if src is None or dst is None:
            warnings.append({"id": ann_id, "message":
                "detailed hint endpoints don't both resolve to pads — "
                "falling back to engine-guided routing"})
            continue
        net = src.net or dst.net
        if not net or (src.net and dst.net and src.net != dst.net):
            warnings.append({"id": ann_id, "message":
                "detailed hint endpoints are not on one shared net — "
                "falling back to engine-guided routing"})
            continue
        if net in consumed_nets:
            warnings.append({"id": ann_id, "message":
                f"net {net!r} already materialized by an earlier detailed hint — skipped"})
            consumed_ids.append(ann_id)
            continue

        layer = _canon_layer(kp.get("layer", "F.Cu"))
        pts = [[src.position[0], src.position[1]]]
        pts += _waypoints_of(env)
        pts.append([dst.position[0], dst.position[1]])
        segments = [
            {"start": [pts[i][0], pts[i][1]],
             "end": [pts[i + 1][0], pts[i + 1][1]],
             "layer": layer}
            for i in range(len(pts) - 1)
            if pts[i] != pts[i + 1]
        ]
        if not segments:
            warnings.append({"id": ann_id, "message":
                "detailed hint has no usable geometry — skipped"})
            continue
        routes.append({"net": net, "segments": segments, "vias": [],
                       "as_drawn": True, "hint_id": ann_id})
        consumed_nets.add(net)
        consumed_ids.append(ann_id)

    return routes, consumed_nets, warnings, consumed_ids


def hints_to_router(
    hint_envelopes: list[dict],
    board: Board,
    selection: Any = None,
    task_constraints: Optional[dict] = None,
) -> HintTranslation:
    """Translate pcb_route_hint envelopes into native ``RoutingHints``.

    Builds the dict schema ``agent_router.hints.parse_hints`` expects (net_hints
    + buses) and calls it — the dataclass is never re-implemented here. Waypoint
    coordinates are carried bit-exact. Per-hint issues become warnings; the
    method never raises on bad hint data.

    ``task_constraints`` (Epoch UX1 station 9, DCR 019fd095e694): optional
    ``{hint_id: {corridor_points, preferred_layer, revision}}`` — the durable
    task-owned steering station 8 introduced (PcbRouteTask.routing_constraint),
    forwarded here by panel_tools.gd's propose/reroute request-builders. An
    entry for a hint OVERRIDES that hint's legacy ``kind_payload.waypoints``
    channel entirely (constraint corridor + preferred_layer used instead, and
    the connection_hint carries the constraint's revision); a hint with NO
    entry here is completely unaffected — same waypoints, same layer, no
    `constraint_revision` key anywhere on its output, byte-identical to a call
    that never knew this parameter existed. Absent/None/non-dict input is the
    empty case: no hint is overridden. A non-numeric `revision` on an entry
    (F10, cold review) never raises — that ONE entry degrades to "no
    override" (a warning names the hint) rather than the whole call failing.

    F2/F5 (cold review): when an override DOES apply and the hint's own
    ``kind_payload.waypoints`` was non-empty, a structured
    ``waypoint_status:"superseded_by_task_constraint"`` warning names the now-
    dead legacy field; if the override is then refused ``ambiguous_span``
    (multi-endpoint span), that warning carries ``source:"task_constraint"``
    and says TASK STEERING was dropped, not "authored waypoints" — a
    constraint-only hint never had authored waypoints of its own to drop.
    """
    warnings: list[dict] = []
    selected = select_hints(hint_envelopes, selection)
    selected_ids = [str(e.get("id", "")) for e in selected]
    task_constraints = task_constraints if isinstance(task_constraints, dict) else {}

    net_hints: list[dict] = []
    buses: list[dict] = []
    connection_hints: list[dict] = []
    max_width: Optional[float] = None
    # hint id -> nets THAT hint asked for. See HintTranslation.nets_by_hint.
    nets_by_hint: dict[str, list[str]] = {}

    for env in selected:
        if not isinstance(env, dict):
            warnings.append({"id": "", "message": "hint envelope is not a mapping — skipped"})
            continue
        if str(env.get("kind", "")) != "pcb_route_hint":
            warnings.append({"id": str(env.get("id", "")), "message":
                f"unexpected kind {env.get('kind')!r}; expected 'pcb_route_hint' — skipped"})
            continue

        kp = env.get("kind_payload") or {}
        if not isinstance(kp, dict):
            warnings.append({"id": str(env.get("id", "")), "message":
                "kind_payload missing/invalid — skipped"})
            continue

        layer = _canon_layer(kp.get("layer", "F.Cu"))
        waypoints = _waypoints_of(env)

        w = _num(kp.get("width_mm"))
        if w > 0:
            max_width = w if max_width is None else max(max_width, w)

        hint_type = str(kp.get("hint_type", "waypoint"))
        names = [str(n) for n in (kp.get("net_names") or []) if str(n)]

        if hint_type == "bus" and len(names) >= 2:
            # Multi-net bus corridor. Only keep nets the board actually carries.
            present = [n for n in names if n in board.nets]
            missing = [n for n in names if n not in board.nets]
            for m in missing:
                warnings.append({"id": str(env.get("id", "")), "message":
                    f"bus net {m!r} not present on board — dropped from bus"})
            if len(present) < 2:
                warnings.append({"id": str(env.get("id", "")), "message":
                    "bus hint resolved to <2 present nets — skipped"})
                continue
            bus: dict = {"name": str(env.get("id", "")) or "bus", "nets": present,
                         "waypoints": waypoints}
            spacing = _num(kp.get("bus_spacing"))
            if spacing > 0:
                bus["spacing"] = spacing
            if layer:
                bus["preferred_layer"] = layer
            buses.append(bus)
            # A bus hint asks for EVERY net it carries — but only the ones the
            # board actually has, which is the same `present` list handed to the
            # engine. Attributing the dropped `missing` nets to it would be the
            # blanket-list lie in miniature.
            nets_by_hint.setdefault(str(env.get("id", "")), []).extend(present)
            continue

        net = _net_for_hint(env, board, warnings)
        if net is None:
            continue  # warning already recorded
        # AUTHORED WAYPOINTS BECOME A CONNECTION HINT (bug 019fcf152791
        # Stage B). They used to be handed to the engine as
        # NetHint.waypoints, which nothing read — the dead field at the heart
        # of this bug. A corridor belongs to a CONNECTION, so it now rides an
        # endpoint-keyed ConnectionHint instead, and the engine's
        # product-state A* actually follows it.
        #
        # STATION 9 (DCR 019fd095e694): a `task_constraints` entry for this
        # hint OVERRIDES the legacy `kind_payload.waypoints` channel entirely
        # — the constraint's corridor + preferred_layer are used, and the
        # emitted ConnectionHint carries the constraint's revision. No entry
        # (the common case for every hint predating this station, and every
        # hint whose task was never given a corridor) falls through to the
        # legacy waypoints exactly as before — byte-identical, no
        # constraint_revision key anywhere.
        #
        # HITL-4 (docs/llm-ergonomics.md F4): computed BEFORE the detail_level
        # warning below, which used to fire first and therefore could not know
        # whether a constraint applies. Ordering only — the override itself is
        # unchanged.
        ann_id = str(env.get("id", ""))
        constraint_pts, constraint_layer, constraint_revision = \
            _corridor_from_task_constraint(
                task_constraints.get(ann_id), warnings, ann_id)
        # detail_level (sparse|guided|detailed) has no RoutingHints slot, but it
        # is NOT inert: one level up, _routes_as_drawn consumes `detailed`
        # single-trace hints as literal geometry. Saying "dropped — no
        # agent_router equivalent" full stop was misleading (bug 019fcf152791);
        # name the ENGINE-side omission specifically.
        #
        # HITL-4 (docs/llm-ergonomics.md F4): SUPPRESSED when a task_constraints
        # entry APPLIES to this hint (constraint_pts truthy — the exact
        # predicate the override below runs on). Intent-minted hints never
        # carry waypoints; their steering rides task_constraints, and for them
        # this warning read as "the corridor might not steer" on exactly the
        # hints where it does — an active red herring during the F0 live
        # diagnosis. The constraint-steered path already reports itself
        # (superseded_by_task_constraint / constraint_revision stamping), so
        # nothing goes silent. A hint with NO applying constraint keeps the
        # warning verbatim.
        #
        # Epoch UX2 station 5 (docket 019fde36491f, refining the F4 fix): ALSO
        # gated on the hint carrying waypoints at all. The warning's only
        # content is which bridge path detail_level selects ("route as drawn"
        # vs engine) — an EMPTY-waypoints hint has nothing to route as drawn,
        # so the distinction carries zero signal there, constraint or not:
        # HITL-5's corridor-free intents got the warning back and it read as
        # doubt about a mechanism that was working. Only a hint whose own
        # waypoints exist — where detail_level genuinely picks the path —
        # still warns.
        # U3 (epoch GA-2): ALSO suppressed for an allow_layer_change hint —
        # it CHOSE the engine path deliberately (materialize skips it), so
        # "this doesn't route as drawn" would warn about the exact behaviour
        # the author opted into.
        if kp.get("detail_level") and not constraint_pts and waypoints \
                and not bool(kp.get("allow_layer_change")):
            warnings.append({"id": str(env.get("id", "")), "message":
                "detail_level '%s' has no agent_router slot — it selects the "
                "bridge path (only 'detailed' single-trace hints route as "
                "drawn), not engine behaviour"
                % kp.get("detail_level")})
        if constraint_pts:
            effective_waypoints = constraint_pts
            effective_layer = constraint_layer or layer
        else:
            effective_waypoints = waypoints
            effective_layer = layer

        # F2 (cold review, Epoch UX1 station 9): duplicated-authority guard.
        # An override APPLIES (constraint_pts is truthy) and this hint's own
        # kind_payload.waypoints is non-empty — that legacy field is now DEAD
        # for routing (the constraint corridor is what actually steers), but
        # nothing on the hint itself said so until now. A structured per-hint
        # note, independent of whether the override below ultimately lands a
        # ConnectionHint or gets refused ambiguous_span — the supersession is
        # true either way, since it describes the WAYPOINTS field, not the
        # route outcome. Rides `hint_status` via the existing
        # _attach_hint_status lift (panel_tools.gd) — any warning carrying
        # "waypoint_status" is lifted onto the candidate by hint id already;
        # no GDScript-side change needed for this to surface. Render / edit-
        # refusal implications (e.g. should the canvas grey out or refuse to
        # hand-edit a superseded corridor) are explicitly OUT OF FENCE here —
        # deferred to the pre-boundary Codex round per the cold review.
        if constraint_pts and waypoints:
            warnings.append({
                "id": ann_id,
                "waypoint_status": "superseded_by_task_constraint",
                "constraint_revision": constraint_revision,
            })

        # SINGLE-ENDPOINT CONTRACT (amendment A5): a guided corridor needs
        # EXACTLY ONE resolved source pad and ONE resolved destination pad.
        # One polyline between multi-endpoint sets is ambiguous by
        # construction — silently taking the first pair, or expanding a
        # cross-product, would both invent an intent the author never
        # expressed. Refuse BY NAME and fall back to unguided routing.
        # Unchanged by station 9 — a task_constraints override is still
        # subject to this exact same gate, never bypassing it.
        if effective_waypoints:
            src_refs = _resolved_pad_refs(kp.get("source_pins"), board)
            dst_refs = _resolved_pad_refs(kp.get("dest_pins"), board)
            if len(src_refs) == 1 and len(dst_refs) == 1:
                ch: dict = {
                    "net": net,
                    "endpoints": [src_refs[0], dst_refs[0]],
                    "waypoints": effective_waypoints,
                    "preferred_layer": effective_layer,
                    "hint_id": ann_id,
                }
                if constraint_revision is not None:
                    ch["constraint_revision"] = constraint_revision
                connection_hints.append(ch)
            else:
                # F5 (cold review, Epoch UX1 station 9): a corridor that came
                # from a task's routing_constraint gets its own vocabulary —
                # `source:"task_constraint"` + `constraint_revision`, and a
                # message that says TASK STEERING was dropped rather than
                # "authored waypoints" (a constraint-only hint, station 8's
                # own contract, never carries authored waypoints of its own —
                # see minerva_pcb_add_route_intent's doc — so the old wording
                # was actively wrong for this case, not just imprecise).
                warn: dict = {
                    "id": ann_id,
                    "waypoint_status": "ignored",
                    "waypoint_count": len(effective_waypoints),
                    "net": net,
                    "reason": "ambiguous_span",
                }
                if constraint_pts:
                    warn["source"] = "task_constraint"
                    warn["constraint_revision"] = constraint_revision
                    warn["message"] = (
                        "%d point(s) of TASK STEERING IGNORED: a guided "
                        "corridor needs exactly one resolved source pad and "
                        "one resolved destination pad, but this hint "
                        "resolved to %d source and %d destination pad(s). "
                        "One polyline between multi-endpoint sets is "
                        "ambiguous, so the task's routing_constraint "
                        "corridor was refused rather than guessed; the "
                        "route is ordinary pad-to-pad autorouting."
                        % (len(effective_waypoints), len(src_refs), len(dst_refs)))
                else:
                    warn["message"] = (
                        "%d authored waypoint(s) IGNORED: a guided corridor "
                        "needs exactly one resolved source pad and one "
                        "resolved destination pad, but this hint resolved to "
                        "%d source and %d destination pad(s). One polyline "
                        "between multi-endpoint sets is ambiguous, so the "
                        "corridor was refused rather than guessed; the route "
                        "is ordinary pad-to-pad autorouting."
                        % (len(effective_waypoints), len(src_refs), len(dst_refs)))
                warnings.append(warn)
        nh: dict = {"net": net, "preferred_layer": layer}
        net_hints.append(nh)
        # Recorded from the SAME `net` the engine is about to be hinted with —
        # not re-resolved. See HintTranslation.nets_by_hint.
        ids_for_net = nets_by_hint.setdefault(str(env.get("id", "")), [])
        if net not in ids_for_net:
            ids_for_net.append(net)

    hints_dict: dict = {}
    if net_hints:
        hints_dict["net_hints"] = net_hints
    if buses:
        hints_dict["buses"] = buses
    if connection_hints:
        hints_dict["connection_hints"] = connection_hints

    hints = parse_hints(hints_dict) if hints_dict else RoutingHints()
    return HintTranslation(
        hints=hints,
        warnings=warnings,
        nets_by_hint=nets_by_hint,
        trace_width_mm=max_width,
        selected_ids=selected_ids,
    )
