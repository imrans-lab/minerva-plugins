"""Annotation/hint -> agent_router bridge (worker-side, standalone).

Translates the canonical board-source dict (pcb/internal/board/board.go +
docs/board-yaml.md) and pcb_route_hint annotation envelopes (pcb/ui/kinds/
pcb_route_hint_kind.gd + PcbAnnotationHost.build_route_hint_envelope) into the
agent_router engine's native ``Board`` + ``RoutingHints`` so the ``route``
method can drive the router from the same board the panel renders.

Design constraints (docket 019eb481ae28 / 019eb47eb567, DCR 019dc140):

  * This module lives in pcb_worker/ and IMPORTS agent_router types — it never
    edits agent_router/, keeping the engine a clean standalone package.
  * Absolute pad positions are composed the SAME way the panel model does it in
    pcb/ui/model/pcb_component.gd::get_pin_world_position, so panel and router
    agree on where a rotated component's pad lands. That convention is:

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


# ---------------------------------------------------------------------------
# Layer mapping (canonical "top"/"bottom" <-> KiCad "F.Cu"/"B.Cu")
# ---------------------------------------------------------------------------

_LAYER_MAP = {"top": "F.Cu", "bottom": "B.Cu"}
# Nominal SMD pad extent (mm) used only when a component carries no per-pad
# geometry (canonical Pin has no size field) and the pad is not through-hole.
_DEFAULT_PAD_SIZE = (1.0, 1.0)


def _num(v: Any, default: float = 0.0) -> float:
    """Coerce a scalar to float, tolerating None/str; ``default`` on failure."""
    if v is None or isinstance(v, bool):
        return default
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


def _canon_layer(layer: Any) -> str:
    """Map a canonical component/hint layer to a KiCad copper layer name."""
    s = str(layer or "").strip()
    if not s:
        return "F.Cu"
    return _LAYER_MAP.get(s.lower(), s)


def _rotate_offset(px: float, py: float, rotation_deg: float) -> tuple[float, float]:
    """Rotate a component-relative pin offset into board space.

    Mirrors pcb/ui/model/pcb_component.gd::get_pin_world_position exactly:
    a Godot Transform2D(deg_to_rad(-rotation)) applied to the offset. For a
    right-handed screen frame that is a clockwise rotation by ``rotation_deg``.
    """
    if not rotation_deg:
        return (px, py)
    r = math.radians(rotation_deg)
    c = math.cos(r)
    s = math.sin(r)
    return (px * c + py * s, -px * s + py * c)


# ---------------------------------------------------------------------------
# board_to_router
# ---------------------------------------------------------------------------


def _pad_size_for(pin: dict, extra_pads_by_num: dict[str, dict]) -> tuple[float, float]:
    """Resolve a pad's (w, h) size in mm.

    Priority: explicit render geometry (component ``pads`` Extra, present when
    the board came from YAML with footprint geometry) -> through-hole annulus
    diameter -> nominal default. Canonical ``Pin`` has no size field, so this
    is best-effort keepout sizing, not authored data.
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
    annulus = _num(pin.get("annulus_diameter_mm"))
    if annulus > 0:
        return (annulus, annulus)
    return _DEFAULT_PAD_SIZE


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
            pad = Pad(
                component=ref,
                number=num,
                net=None,  # filled from net membership below
                position=(cx + wx, cy + wy),
                size=_pad_size_for(pin, extra_pads_by_num),
                shape=str(pin.get("shape", "rect")),
                pad_type=("thru_hole" if drill > 0 else "smd"),
                drill=(drill if drill > 0 else None),
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
