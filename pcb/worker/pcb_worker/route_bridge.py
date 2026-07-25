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
from agent_router import layers as _layers

from .geometry import rotate_local_offset
from .ir_pads import UnsupportedGeometry, iter_ir_pads, pad_copper_shape
from .pad_source import is_th_drill
from .resolved_board import (
    LayerRole,
    OvalHole,
    RectOutline,
    ResolvedBoard,
    RoundHole,
    SlotHole,
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

    Raises ``ValueError`` on a structurally unusable board (not a mapping / no
    components). Unresolvable *net* pin refs are skipped silently — the
    canonical validator (board_model.validate_board) owns that diagnostic;
    unresolvable *hint* pin refs are surfaced as warnings by ``hints_to_router``.
    """
    if not isinstance(canonical_board, dict):
        raise ValueError("board must be a mapping")
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
        layer = _canon_layer(comp.get("layer"))

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

    return Board(
        pads=pads,
        nets=nets,
        obstacles=obstacles,
        width=_num(canonical_board.get("width_mm")),
        height=_num(canonical_board.get("height_mm")),
        origin=(ox, oy),
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
# ("Simple rectangular marking (ignoring rotation for now)", grid.py:133). Handing
# it a truthful w/h for a ROTATED elongated land would therefore under-block along
# the rotated axes. We hand it the axis-aligned bounding box of the real land
# instead — a strict superset, computed from the same neutral land owner the CAM
# emitters fabricate from (ir_pads.pad_copper_shape).


def _routing_layer_ids(rb: ResolvedBoard) -> tuple[str, ...]:
    """The engine-facing copper layer names, or fail closed.

    The vendored engine routes F.Cu/B.Cu only. A board with inner copper would be
    routed as if those layers did not exist — copper the grid never models — so it
    fails closed here instead."""
    aliases = tuple(layer.kicad_alias for layer in rb.layer_stack.copper)
    if sorted(aliases) != sorted(_ROUTABLE_KICAD_LAYERS):
        raise UnsupportedGeometry(
            f"routing engine models a 2-layer F.Cu/B.Cu stack only; board copper "
            f"stack is {list(aliases)}")
    return aliases


def _reject_unroutable_board(rb: ResolvedBoard) -> None:
    """Fail closed on compiled features the router cannot honour.

    Each of these would otherwise be SILENTLY ABSENT from the grid, and absent
    copper is exactly what lets a proposal cross real copper."""
    if not isinstance(rb.outline, RectOutline):
        raise UnsupportedGeometry(
            f"routing v1 models a rectangular (RectOutline) board only; got "
            f"{type(rb.outline).__name__}")
    if rb.traces or rb.vias:
        # EXISTING ACCEPTED COPPER (Codex gap E). The engine is given pads/holes
        # only, so already-accepted traces and vias would be invisible and a new
        # proposal could be routed straight through them. Modeling accepted copper
        # is owned by T7 019f70ebc9ed; until it lands, a board that HAS accepted
        # copper is not routable rather than routable-and-wrong.
        raise UnsupportedGeometry(
            f"board already carries accepted copper ({len(rb.traces)} trace(s), "
            f"{len(rb.vias)} via(s)) which the routing grid does not model yet "
            f"(019f70ebc9ed); routing fails closed rather than propose copper "
            f"that may cross it")
    if rb.zones:
        raise UnsupportedGeometry("routing v1 does not model copper zones/pours")
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
            component=ir_pad.ref, number=ir_pad.number, net=None,
            position=position, size=size, shape="rect", pad_type="thru_hole",
            drill=max(float(drill.size[0]), float(drill.size[1])),
            layer="*.Cu",
            # rotation is DELIBERATELY 0.0: `size` is already the axis-aligned
            # envelope of the rotated land. Passing the true rotation would
            # double-count the moment the engine starts honouring it.
            rotation=0.0)
    return Pad(
        component=ir_pad.ref, number=ir_pad.number, net=None,
        position=position, size=size, shape="rect", pad_type="smd",
        drill=None, layer=_pad_copper_layer(ir_pad, routable), rotation=0.0)


def _npth_obstacle(ir_pad) -> Obstacle:
    """A bare mechanical (NPTH) component hole: an obstacle, never a route target.

    It carries no copper land, so it is not a Pad — a Pad would be both phantom
    copper and a connectable endpoint the net list never asked for."""
    drill = ir_pad.pad.drill
    radius = max(float(drill.size[0]), float(drill.size[1])) / 2.0
    return Obstacle(position=tuple(ir_pad.pad.position), type="npth_pad",
                    radius=radius)


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

    NOT yet handled here, by design (each has its own owner, none of them silent):
      * effective width/clearance from ``rb.design_rules`` and keepout inflation
        by clearance + half the trace width — Round E2. Today the engine still
        applies its own defaults, exactly as before this change.
      * grid origin correctness for a non-zero ``RectOutline.origin`` — Round E2.
      * per-net-class width/clearance minima — Round E2, with the rest of rules.
      * accepted traces/vias — T7 019f70ebc9ed; fails closed above until then.
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

    return Board(
        pads=pads,
        nets=nets,
        obstacles=obstacles,
        width=rb.outline.width_mm,
        height=rb.outline.height_mm,
        origin=tuple(rb.outline.origin),
    )


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
    """
    hints: RoutingHints
    warnings: list[dict] = field(default_factory=list)
    trace_width_mm: Optional[float] = None
    selected_ids: list[str] = field(default_factory=list)


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


def _waypoints_of(envelope: dict) -> list[list[float]]:
    """Extract waypoints as [[x, y], …] in exact board mm (no rounding).

    Reads kind_payload.waypoints (the authoritative pixel-accurate polyline the
    panel stores as [[x_mm, y_mm], …]). Each coordinate is passed through
    float() only — an identity on values already float, so no drift.
    """
    kp = envelope.get("kind_payload") or {}
    raw = kp.get("waypoints")
    out: list[list[float]] = []
    if isinstance(raw, list):
        for wp in raw:
            if isinstance(wp, (list, tuple)) and len(wp) >= 2:
                out.append([float(wp[0]), float(wp[1])])
            elif isinstance(wp, dict) and "x" in wp and "y" in wp:
                out.append([float(wp["x"]), float(wp["y"])])
    return out


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
) -> HintTranslation:
    """Translate pcb_route_hint envelopes into native ``RoutingHints``.

    Builds the dict schema ``agent_router.hints.parse_hints`` expects (net_hints
    + buses) and calls it — the dataclass is never re-implemented here. Waypoint
    coordinates are carried bit-exact. Per-hint issues become warnings; the
    method never raises on bad hint data.
    """
    warnings: list[dict] = []
    selected = select_hints(hint_envelopes, selection)
    selected_ids = [str(e.get("id", "")) for e in selected]

    net_hints: list[dict] = []
    buses: list[dict] = []
    max_width: Optional[float] = None

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
            continue

        net = _net_for_hint(env, board, warnings)
        if net is None:
            continue  # warning already recorded
        # detail_level (sparse|guided|detailed) is a UI density hint with no
        # RoutingHints slot — surface the drop so the omission is honest
        # (per-hint width is likewise unslotted; see HintTranslation docstring).
        if kp.get("detail_level"):
            warnings.append({"id": str(env.get("id", "")), "message":
                "detail_level '%s' dropped — no agent_router equivalent"
                % kp.get("detail_level")})
        nh: dict = {"net": net, "waypoints": waypoints, "preferred_layer": layer}
        net_hints.append(nh)

    hints_dict: dict = {}
    if net_hints:
        hints_dict["net_hints"] = net_hints
    if buses:
        hints_dict["buses"] = buses

    hints = parse_hints(hints_dict) if hints_dict else RoutingHints()
    return HintTranslation(
        hints=hints,
        warnings=warnings,
        trace_width_mm=max_width,
        selected_ids=selected_ids,
    )
