"""
Main routing orchestration.

Coordinates routing of all nets on a board, handling net ordering,
minimum spanning tree for multi-pad nets, and tracking results.

Implements the "Design Partner" philosophy: routing friction is design
feedback. The design_review() function should be called before routing
to identify potential issues and prompt design-level thinking.
"""

from dataclasses import dataclass, field
from typing import Optional, Sequence
from collections import defaultdict
import math
import re

from .board import Board, Pad, RoutingRulesError
from .grid import RoutingGrid
from .pathfinder import find_path, unroutable_reason, Path, _path_points
from .corridor import Corridor, measure_adherence, DEFAULT_TOLERANCE_MM


def _corridor_from_hint(conn_hint, reversed_dir: bool) -> Optional[Corridor]:
    """Build the travelled-direction Corridor for a connection hint.

    A hint is authored source -> destination; the engine may route the pair in
    either direction. Reversing here (rather than at the grading step alone)
    keeps pricing and reporting on the same oriented polyline.
    """
    if not conn_hint.waypoints:
        return None
    pts = tuple((w.x, w.y) for w in conn_hint.waypoints)
    if reversed_dir:
        pts = tuple(reversed(pts))
    tol = conn_hint.tolerance_mm
    return Corridor(waypoints=pts,
                    tolerance_mm=float(tol) if tol else DEFAULT_TOLERANCE_MM)


# Common bus prefixes to detect related signals
BUS_PREFIXES = [
    'I2C_', 'I2S_', 'SPI_', 'UART_', 'USB_', 'SDIO_', 'JTAG_',
    'D', 'A', 'GPIO', 'ADC_', 'DAC_', 'PWM_', 'CAN_', 'ETH_'
]


@dataclass
class BusGroup:
    """A group of related signals that could be routed as a bus."""
    name: str
    nets: list[str]
    prefix: str

    @property
    def pad_count(self) -> int:
        return len(self.nets)


@dataclass
class CongestionArea:
    """An area of the board with high routing density."""
    center: tuple[float, float]
    radius: float
    nets_involved: list[str]
    description: str


@dataclass
class PotentialCrossing:
    """Two nets that may need to cross each other."""
    net1: str
    net2: str
    reason: str


@dataclass
class DesignReview:
    """
    Results of analyzing a board before routing.

    This implements the "Design Partner" philosophy by identifying
    potential issues and prompting design-level questions.
    """
    bus_groups: list[BusGroup] = field(default_factory=list)
    congestion_areas: list[CongestionArea] = field(default_factory=list)
    potential_crossings: list[PotentialCrossing] = field(default_factory=list)
    design_questions: list[str] = field(default_factory=list)

    def print_report(self) -> str:
        """Generate a human-readable design review report."""
        lines = []
        lines.append("=" * 60)
        lines.append("DESIGN REVIEW - Review before routing")
        lines.append("=" * 60)
        lines.append("")

        # Bus groups
        if self.bus_groups:
            lines.append("## Detected Bus Groups")
            lines.append("These signals could be routed together with consistent spacing:")
            for bus in self.bus_groups:
                lines.append(f"  - {bus.name}: {', '.join(bus.nets)}")
            lines.append("")

        # Potential crossings
        if self.potential_crossings:
            lines.append("## Potential Crossing Nets")
            lines.append("These nets may need to cross - consider vias or layout changes:")
            for cross in self.potential_crossings:
                lines.append(f"  - {cross.net1} <-> {cross.net2}: {cross.reason}")
            lines.append("")

        # Congestion areas
        if self.congestion_areas:
            lines.append("## Congestion Areas")
            for area in self.congestion_areas:
                lines.append(f"  - {area.description}")
                lines.append(f"    Nets: {', '.join(area.nets_involved[:5])}" +
                           ("..." if len(area.nets_involved) > 5 else ""))
            lines.append("")

        # Design questions
        lines.append("## Questions to Consider")
        lines.append("Before routing, consider these design-level questions:")
        lines.append("")
        for q in self.design_questions:
            lines.append(f"  * {q}")

        lines.append("")
        lines.append("=" * 60)

        return "\n".join(lines)


def design_review(board: Board) -> DesignReview:
    """
    Analyze a board before routing to identify design opportunities.

    This implements the "Design Partner" philosophy: routing friction
    is design feedback. Call this before routing to prompt thinking
    about pin assignments, component placement, and routing strategy.

    Args:
        board: Board to analyze

    Returns:
        DesignReview with identified issues and questions
    """
    review = DesignReview()

    # Detect bus groups
    review.bus_groups = _detect_bus_groups(board)

    # Detect potential crossings
    review.potential_crossings = _detect_potential_crossings(board)

    # Detect congestion areas
    review.congestion_areas = _detect_congestion(board)

    # Generate design questions
    review.design_questions = _generate_design_questions(board, review)

    return review


def _detect_bus_groups(board: Board) -> list[BusGroup]:
    """Detect groups of related signals by prefix."""
    groups = []

    # Group nets by prefix
    prefix_nets: dict[str, list[str]] = defaultdict(list)

    for net_name in board.nets.keys():
        for prefix in BUS_PREFIXES:
            if net_name.startswith(prefix) or net_name.upper().startswith(prefix):
                prefix_nets[prefix].append(net_name)
                break

    # Create bus groups for prefixes with 2+ nets
    for prefix, nets in prefix_nets.items():
        if len(nets) >= 2:
            # Create a friendly name
            name = prefix.rstrip('_') + " Bus"
            groups.append(BusGroup(name=name, nets=sorted(nets), prefix=prefix))

    return groups


def _detect_potential_crossings(board: Board) -> list[PotentialCrossing]:
    """Detect pairs of nets that may need to cross."""
    crossings = []

    # Get nets with 2+ pads
    routable_nets = {name: net for name, net in board.nets.items()
                     if len(net.pads) >= 2}

    # For each pair of nets, check if their bounding boxes overlap
    net_names = list(routable_nets.keys())
    for i, net1_name in enumerate(net_names):
        net1 = routable_nets[net1_name]
        bb1 = _get_net_bounding_box(net1.pads)

        for net2_name in net_names[i+1:]:
            net2 = routable_nets[net2_name]
            bb2 = _get_net_bounding_box(net2.pads)

            # Check if bounding boxes overlap
            if _boxes_overlap(bb1, bb2):
                # Check if they actually cross (one net spans horizontally,
                # other spans vertically through the same area)
                if _nets_likely_cross(net1.pads, net2.pads):
                    crossings.append(PotentialCrossing(
                        net1=net1_name,
                        net2=net2_name,
                        reason="Routing paths likely intersect"
                    ))

    return crossings[:10]  # Limit to top 10


def _detect_congestion(board: Board) -> list[CongestionArea]:
    """Detect areas with high routing density."""
    areas = []

    # Find components with many pads
    component_pads: dict[str, list[Pad]] = defaultdict(list)
    for pad in board.pads:
        component_pads[pad.component].append(pad)

    for comp_name, pads in component_pads.items():
        if len(pads) >= 10:  # Dense component
            # Get center
            xs = [p.position[0] for p in pads]
            ys = [p.position[1] for p in pads]
            center = (sum(xs)/len(xs), sum(ys)/len(ys))
            radius = max(max(xs)-min(xs), max(ys)-min(ys)) / 2

            # Get unique nets
            nets = list(set(p.net for p in pads if p.net))

            areas.append(CongestionArea(
                center=center,
                radius=radius,
                nets_involved=nets,
                description=f"{comp_name} ({len(pads)} pads, {len(nets)} nets)"
            ))

    return areas


def _generate_design_questions(board: Board, review: DesignReview) -> list[str]:
    """Generate design questions based on board analysis."""
    questions = []

    # Always include these fundamental questions
    questions.append(
        "Are all pin assignments fixed, or could some be swapped to simplify routing?"
    )
    questions.append(
        "Could any components be repositioned to reduce trace crossings?"
    )

    # Bus-specific questions
    if review.bus_groups:
        bus_names = [b.name for b in review.bus_groups]
        questions.append(
            f"For bus signals ({', '.join(bus_names)}): should they be routed "
            "together with consistent spacing?"
        )

    # Crossing-specific questions
    if review.potential_crossings:
        questions.append(
            f"Found {len(review.potential_crossings)} potential net crossings. "
            "Consider: use vias, rearrange components, or reassign pins?"
        )

    # Congestion-specific questions
    if review.congestion_areas:
        components = [a.description.split()[0] for a in review.congestion_areas]
        questions.append(
            f"Dense components detected ({', '.join(components)}). "
            "Plan escape routing strategy before detailed routing."
        )

    # Power net questions
    power_nets = [n for n in board.nets.keys()
                  if any(p in n.upper() for p in ['VCC', 'GND', 'PWR', '3V3', '5V'])]
    if power_nets:
        questions.append(
            f"Power nets ({', '.join(power_nets[:3])}{'...' if len(power_nets) > 3 else ''}): "
            "consider copper pours or shared routing paths?"
        )

    return questions


def _get_net_bounding_box(pads: list[Pad]) -> tuple[float, float, float, float]:
    """Get bounding box (min_x, min_y, max_x, max_y) for a set of pads."""
    if not pads:
        return (0, 0, 0, 0)
    xs = [p.position[0] for p in pads]
    ys = [p.position[1] for p in pads]
    return (min(xs), min(ys), max(xs), max(ys))


def _boxes_overlap(bb1: tuple, bb2: tuple) -> bool:
    """Check if two bounding boxes overlap."""
    return not (bb1[2] < bb2[0] or bb2[2] < bb1[0] or
                bb1[3] < bb2[1] or bb2[3] < bb1[1])


def _nets_likely_cross(pads1: list[Pad], pads2: list[Pad]) -> bool:
    """Heuristic check if two nets are likely to cross."""
    if len(pads1) < 2 or len(pads2) < 2:
        return False

    bb1 = _get_net_bounding_box(pads1)
    bb2 = _get_net_bounding_box(pads2)

    # Check if one is more horizontal and other more vertical
    w1, h1 = bb1[2] - bb1[0], bb1[3] - bb1[1]
    w2, h2 = bb2[2] - bb2[0], bb2[3] - bb2[1]

    # If one is horizontal-ish and other is vertical-ish, likely cross
    if w1 > h1 * 1.5 and h2 > w2 * 1.5:
        return True
    if h1 > w1 * 1.5 and w2 > h2 * 1.5:
        return True

    return False


@dataclass
class Route:
    """A routed connection for a net."""
    net: str
    paths: list[Path] = field(default_factory=list)
    vias: list[tuple[float, float]] = field(default_factory=list)
    #: Per-connection corridor grading, one entry per guided connection routed
    #: on this net (bug 019fcf152791). Empty for every unguided route, so an
    #: existing caller sees exactly what it always did.
    corridor_adherence: list[dict] = field(default_factory=list)
    #: Epoch UX1 station 9 (DCR 019fd095e694): the task routing_constraint
    #: revision that steered a guided connection on this net, when one did.
    #: None for every unguided route AND for a route guided only by legacy
    #: inline hint waypoints (no task behind them) — see ConnectionHint's own
    #: doc. LAST-WRITE-WINS across multiple guided connections sharing one net
    #: (a documented simplification, not a claim that only one can exist);
    #: methods.py attaches it exactly like corridor_adherence, one key per
    #: route dict.
    constraint_revision: Optional[int] = None

    @property
    def segments(self) -> list:
        """Get all segments from all paths."""
        result = []
        for path in self.paths:
            result.extend(path.segments)
        return result


@dataclass
class RoutingResult:
    """Result of routing a board."""
    success: bool = False
    routes: list[Route] = field(default_factory=list)
    unrouted: list[tuple[str, Pad, Pad]] = field(default_factory=list)  # (net, pad1, pad2)
    # WHY each `unrouted` entry was refused, INDEX-ALIGNED with it: entry i here
    # explains entry i there. Appended together at both `find_path` failure
    # sites, so the two lists cannot drift in length.
    #
    # A PARALLEL LIST, not a fourth tuple element, on purpose: the tuple shape is
    # read by `pcb_worker.methods._serialize_routing_result` and by tests, and
    # widening it would break them for a field they do not want. See
    # `agent_router.pathfinder.unroutable_reason` for the codes and for why this
    # exists — round C2b's refusals are correct but were previously silent.
    #
    # ON THE WIRE since docket 019f9d59a49b: `_serialize_routing_result` reads
    # this and attaches each pair's code as `unrouted[i]["reason"]`. Entries are
    # paired BY INDEX with `unrouted`, so the two lists must be appended in
    # lockstep — every `result.unrouted.append(...)` in this file must be
    # followed by the matching `result.unrouted_reasons.append(...)`. The
    # serializer verifies the lengths agree and drops `reason` from every entry
    # if they do not, so breaking that invariant degrades the diagnostic rather
    # than mispairing it — but it still silently costs the whole feature.
    unrouted_reasons: list[dict] = field(default_factory=list)
    # HITL-4 (docs/llm-ergonomics.md F1): per-span OUTCOMES for every net/span
    # the run was asked about but produced neither a route nor an `unrouted`
    # pair for. Before this field existed, a span whose endpoints the board's
    # EXISTING copper already joins produced NOTHING — routes empty, unrouted
    # empty — byte-identical to a dropped request (the live GND BAT1.2→U1.22
    # reproduction cost a geometry dump and a full trace export to diagnose).
    # The skip was implicit: `_connections_for_net`'s group contraction yields
    # zero missing edges, so the per-net loop simply appended nothing anywhere.
    #
    # ACCOUNTING IDENTITY: every net the routing loop VISITS now lands in
    # exactly one of `routes`, `unrouted`, or here — silence is impossible.
    # Entries are plain dicts (JSON-shaped, like `unrouted_reasons`) with a
    # named `status`:
    #
    #   already_connected   — the automatic spanning tree over the accepted-
    #                         copper groups needed no edge: existing copper
    #                         already joins every requested terminal.
    #                         `connected_via` (best effort, absent-key when the
    #                         copper carries no source ids) lists the accepted
    #                         trace/via ids doing the joining.
    #   terminals_unmatched — a span-scoped ask (net_terminals) whose named
    #                         refs matched < 2 pads on this board. Defence in
    #                         depth: route_bridge.parse_route_scope refuses
    #                         unknown endpoints before the engine ever runs,
    #                         but the engine must not go silent if reached
    #                         through another door.
    #   bridge_absorbed     — an internal-bridge net whose pin assignments
    #                         left no external connection to route (all pads
    #                         assigned or internally bonded). Unreachable from
    #                         the worker today (route_bridge.hints_to_router
    #                         never emits bridges) but named rather than
    #                         folded into already_connected, which would be a
    #                         lie about the mechanism.
    span_outcomes: list[dict] = field(default_factory=list)
    via_count: int = 0

    def get_route(self, net_name: str) -> Optional[Route]:
        """Get the route for a specific net."""
        for route in self.routes:
            if route.net == net_name:
                return route
        return None


# Per-net-class minima (docs/routing.md, "Per-net-class minima"). Two
# SEPARATE concepts, sized differently on purpose:
#
#   * COPPER WIDTH is genuinely per-net: `net_widths` (net name -> width_mm,
#     sourced from that net's own class by `pcb_worker.methods.
#     _net_class_overrides`) says what width THAT net's own trace is drawn
#     at. A net absent from the map draws at the run's baseline `trace_width`.
#
#   * The KEEPOUT MARGIN is NOT per-net. `keepout_clearance`/`keepout_trace_
#     width` size the GRID itself (its `clearance`/`trace_width` fields, which
#     `RoutingGrid.keepout_margin` reads for EVERY marking) and so apply
#     uniformly to every pad and every trace on the board, net-classed or not.
#     A per-net margin was tried and rejected (Codex review of this round): a
#     ring is a static reservation sized once, by whichever net's copper it
#     protects, at MARK time — it has no way to also satisfy a STRICTER class
#     net that only comes along later and approaches that same copper. That is
#     an under-block, and routing.md's invariant ("the modeled keepout must be
#     a SUPERSET of the fabricated copper... under-blocking never is legal")
#     applies with no net-class exception. The fix is the same one this
#     campaign uses everywhere it meets an under-block it cannot model
#     exactly (the pad AABB superset, the oval-hole containing disc, the
#     conservative NPTH obstacle): pick the CONSERVATIVE value — here, the
#     widest clearance/width any class present on the board demands — and
#     apply it to every marking. `pcb_worker.methods._route` computes that
#     board-wide worst case and passes it as `keepout_clearance`/
#     `keepout_trace_width`; None (every pre-net-class caller) means "use the
#     run's own `clearance`/`trace_width`", i.e. unchanged behaviour.
NetWidths = dict[str, float]


# ---------------------------------------------------------------------------
# EXISTING (already-accepted) copper — T7, docket 019f70ebc9ed
# ---------------------------------------------------------------------------
# The board's own accepted traces and vias, in the engine's language. Until T7 a
# board carrying any of it was not routable at all (route_bridge fails closed),
# because the grid was given pads and holes only: accepted copper was INVISIBLE
# and a fresh proposal could be laid straight across it. That was the honest call
# while the grid could not model it, but it also meant the first accepted proposal
# ended the iterative workflow this plugin exists for.
#
# These ride as ENGINE OPTIONS rather than as fields on ``Board`` for the same
# reason ``trace_width``/``clearance`` do (see docs/routing.md, "Effective width
# and clearance"): ``agent_router.Board`` is also the shape ``Board.from_kicad``
# produces, and this round's fence does not extend to it. The projection that
# fills them is pcb_worker.route_bridge.resolved_board_existing_copper, beside the
# one that fills the Board.
#
# TWO different jobs, and conflating them is the bug this feature is prone to:
#
#   * OTHER-net copper is an OBSTACLE. It goes through the SAME markers as
#     freshly-routed copper (``RoutingGrid.mark_trace`` / ``mark_via``), so it is
#     inflated by the SAME single owner, ``RoutingGrid.keepout_margin``. There is
#     deliberately NO second, hand-inflated path here — one shipped in an earlier
#     round and had to be undone, because a margin applied in one marker and
#     forgotten (or spelled differently) in another is exactly the under-block
#     keepout_margin exists to make impossible.
#   * SAME-net copper is ALREADY-CONNECTED. It is marked with its own net, so
#     ``can_route_through`` lets that net path TO it and ALONG it; and the pads it
#     already joins are pre-merged before the spanning tree is built
#     (:func:`_preconnected_groups`), so the router adds only the connections the
#     board still lacks instead of re-routing a net that is partly done.


@dataclass(frozen=True)
class ExistingSegment:
    """One straight run of accepted copper on one layer.

    Segments, not polylines: the IR's own trace is already a chain of 2-point
    segments and every consumer (ir_connectivity, the DRC kernel) breaks polylines
    into consecutive pairs anyway, so one shape reaches all of them.
    """
    net: Optional[str]
    start: tuple[float, float]
    end: tuple[float, float]
    width: float
    layer: str
    # HITL-4 (docs/llm-ergonomics.md F1): the ACCEPTED trace this segment was
    # decomposed from (ResolvedTrace.id on the worker's canonical path), so an
    # `already_connected` span outcome can name WHICH copper satisfies the
    # span (`connected_via`, best effort). Optional with a None default: every
    # existing positional constructor call is untouched, and a caller that
    # carries no ids simply produces outcomes without the `connected_via` key.
    source_id: Optional[str] = None


@dataclass(frozen=True)
class ExistingVia:
    """An accepted via: an annulus of copper present on EVERY layer it spans."""
    net: Optional[str]
    position: tuple[float, float]
    diameter: float
    layers: tuple[str, ...]
    # HITL-4 (docs/llm-ergonomics.md F1): same best-effort attribution slot as
    # ExistingSegment.source_id, for the accepted via's own id.
    source_id: Optional[str] = None


def _mark_existing_copper(
    grid: RoutingGrid,
    existing_traces: Sequence[ExistingSegment],
    existing_vias: Sequence[ExistingVia],
    layers: Sequence[str],
) -> None:
    """Put the board's accepted copper into the grid.

    ORDER MATTERS, and it is: pads -> existing copper -> obstacles.

    * after PADS, because a pad is the board's census of copper and existing
      copper is laid on top of it; running the other way would let a pad's
      clearance ring be written where accepted copper already sits.
    * before OBSTACLES, because an obstacle (a mounting hole) is an ABSOLUTE veto
      that belongs to no net and clears whatever it lands on (see
      ``mark_obstacle``). Losing a few cells of accepted copper to a hole is the
      safe direction: it only over-blocks.

    That second clause is a PREFERENCE, not the safety property. Re-netting a
    hole cell is refused by ``RoutingGrid._mark_copper_cell`` itself, so getting
    the order wrong here (or calling the public markers from somewhere else)
    costs blocking that could have been avoided — never a hole the router is
    allowed to route through.

    Widths and diameters are the copper's OWN authored dimensions, not the run's:
    this is copper that already physically exists. Only the keepout MARGIN around
    it is the run's (grid-wide) one — that is a reservation for the newcomer, not
    a property of what is already there.
    """
    routable = set(layers)
    for seg in existing_traces:
        if seg.layer not in routable:
            # Not reachable from the canonical projection (route_bridge fails
            # closed on a non-F.Cu/B.Cu stack), but reachable for a caller that
            # asked for single_layer=True over a 2-layer board. Skipping is safe
            # THERE and only there: with no B.Cu in the grid, nothing routes on
            # B.Cu and no via can be proposed (`allow_via = allow_vias and not
            # single_layer`), so there is nothing that could cross the copper
            # being skipped.
            continue
        grid.mark_trace(start=seg.start, end=seg.end, width=seg.width,
                        net=seg.net, layer=seg.layer)
    for via in existing_vias:
        spans = [lyr for lyr in via.layers if lyr in routable]
        if not spans:
            continue
        grid.mark_via(x=via.position[0], y=via.position[1],
                      diameter=via.diameter, net=via.net, layers=spans)


# How close two pieces of copper must be before this engine calls them the same
# point, in GRID CELLS. One cell: the router cannot resolve anything finer — a
# path's own vertices come back from `_cell_to_pos` as cell CENTRES, so copper
# accepted from a previous run sits up to half a cell diagonal off the pad centre
# it was routed from. Deliberately not looser: see _preconnected_groups for why
# the error that matters here is over-counting, not under-counting.
_COINCIDENT_CELLS = 1.0


def _coincidence_tolerance(
    grid_resolution: float,
    segments: Sequence[ExistingSegment],
    vias: Sequence[ExistingVia],
) -> float:
    """How far apart two pieces of THIS net's copper may be and still count as
    joined, in mm — capped by the copper itself, never by the grid alone.

    THE CAP IS THE POINT (cold review of 019f70ebc9ed). A cells-based tolerance
    scales with ``grid_resolution``, and that is a CALLER OPTION
    (``pcb_worker.methods._route`` passes it straight through from
    ``options.grid_resolution``). At the 0.1mm default the quantisation term is
    far smaller than any real trace width, so it can only under-count. Nothing
    forbids a caller asking for 0.5mm — and at that resolution two same-net stubs
    with a GENUINE 0.4mm air gap between them merge into one pre-connected group.
    The router then skips a connection the net actually needs and the reply
    reports an OPEN net as routed: precisely the over-count, and precisely the
    false clean, that :func:`_preconnected_groups` is built to avoid. A caller's
    choice of grid must not be able to reverse the safe direction.

    So the tolerance is the SMALLER of:

      * the quantisation term (one cell), which is what it exists to absorb, and
      * the narrowest COPPER involved — a segment's half-width, a via's radius.
        Copper of width ``w`` ending at a point covers a disc of radius ``w/2``
        about it, so two pieces whose copper really touches are within
        ``(w1 + w2) / 2``; taking the narrowest single half-extent is strictly
        tighter than that, i.e. conservative in the one direction that is safe.

    Both terms shrink the tolerance and neither can grow it, so the result is
    bounded by physical copper no matter what grid the caller asks for.
    """
    reach = min([seg.width / 2.0 for seg in segments]
                + [via.diameter / 2.0 for via in vias])
    return min(grid_resolution * _COINCIDENT_CELLS, reach)


def _pad_reaches_layer(pad: Pad, layer: str) -> bool:
    """Whether ``pad``'s copper is present on ``layer``.

    Mirrors the layer choice route_board makes when MARKING the pad, minus its
    ``else: ["F.Cu"]`` fallback for an unrecognised layer name. That fallback is
    a conservative guess for a KEEPOUT (block somewhere rather than nowhere);
    reused for CONNECTIVITY it would be an invented electrical connection, which
    is the one direction this predicate must never err in.
    """
    return (pad.layer == layer or pad.layer == "*.Cu"
            or pad.pad_type == "thru_hole")


def _preconnected_groups(
    pads: list[Pad],
    segments: Sequence[ExistingSegment],
    vias: Sequence[ExistingVia],
    tolerance: float,
) -> dict[int, int]:
    """Which of ``pads`` the board's EXISTING copper already joins.

    Returns ``{pad index -> group id}``; two pads share a group iff accepted
    copper already connects them. All inputs must already be filtered to ONE net.

    THE ERROR DIRECTIONS ARE NOT SYMMETRIC, and everything below follows from
    that:

    * OVER-counting (claiming a connection the copper does not make) makes the
      router skip a connection the net genuinely needs. The reply then reports a
      net as routed while it is open — a silent false clean, and the worst
      outcome available here.
    * UNDER-counting (missing a join the copper does make) makes the router
      propose a connection that is already there. That is redundant same-net
      copper: wasteful, visible to the user in the proposal, and electrically
      harmless.

    So every rule here demands COINCIDENCE, never mere proximity or containment:

    * a segment endpoint counts as landing on a pad only within ``tolerance`` of
      the pad's CENTRE — not "inside the pad's extent". The extent the engine
      holds is the axis-aligned SUPERSET of a possibly-rotated land
      (route_bridge._router_pad), which is the right shape for a keepout and the
      wrong one for connectivity: it would credit copper that stops in the corner
      of a bounding box where no real copper exists. The centre is exact, and it
      is where copper actually terminates — routes are pathfound pad-centre to
      pad-centre and acceptance writes those coordinates back.
    * two segments join at shared ENDPOINTS only. A T-junction (one segment
      ending part-way along another) is real copper contact this misses, on
      purpose: catching it needs a point-on-segment test whose tolerance would
      have to grow with trace width, and being wrong there over-counts. The cost
      of missing it is one redundant proposed trace.
    * a via joins whatever coincides with it on a layer it SPANS, which is what
      makes a two-sided net continuous.
    """
    if not pads:
        return {}
    find, _seg_node, _via_node = _copper_union(pads, segments, vias, tolerance)
    return {pi: find(pi) for pi in range(len(pads))}


def _copper_union(
    pads: list[Pad],
    segments: Sequence[ExistingSegment],
    vias: Sequence[ExistingVia],
    tolerance: float,
):
    """The shared pad/segment/via union-find behind :func:`_preconnected_groups`.

    HITL-4 (docs/llm-ergonomics.md F1): extracted so the `already_connected`
    span outcome can attribute WHICH copper joins the pads
    (:func:`_connected_copper_ids`) with the IDENTICAL coincidence rules the
    grouping decision itself used — a second, hand-rolled traversal here would
    be free to disagree with the decision it is explaining. Every rule
    (centre-coincidence only, shared endpoints only, via spans) is documented
    on `_preconnected_groups`, which remains the semantic owner.

    Returns ``(find, seg_node, via_node)``: the find function over the packed
    node universe, and the index offsets where segment/via nodes begin.
    """
    n_pads = len(pads)
    parent = list(range(n_pads + len(segments) + len(vias)))

    def find(i: int) -> int:
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    def union(a: int, b: int) -> None:
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[rb] = ra

    def coincident(p: tuple[float, float], q: tuple[float, float]) -> bool:
        return math.hypot(p[0] - q[0], p[1] - q[1]) <= tolerance

    seg_node = n_pads
    via_node = n_pads + len(segments)

    for si, seg in enumerate(segments):
        for pi, pad in enumerate(pads):
            if not _pad_reaches_layer(pad, seg.layer):
                continue
            if coincident(seg.start, pad.position) or coincident(seg.end, pad.position):
                union(pi, seg_node + si)
        for sj in range(si + 1, len(segments)):
            other = segments[sj]
            if other.layer != seg.layer:
                continue
            if any(coincident(a, b) for a in (seg.start, seg.end)
                   for b in (other.start, other.end)):
                union(seg_node + si, seg_node + sj)

    for vi, via in enumerate(vias):
        for pi, pad in enumerate(pads):
            if any(_pad_reaches_layer(pad, lyr) for lyr in via.layers) and \
                    coincident(via.position, pad.position):
                union(pi, via_node + vi)
        for si, seg in enumerate(segments):
            if seg.layer not in via.layers:
                continue
            if coincident(seg.start, via.position) or coincident(seg.end, via.position):
                union(via_node + vi, seg_node + si)

    return find, seg_node, via_node


def _connected_copper_ids(
    pads: list[Pad],
    segments: Sequence[ExistingSegment],
    vias: Sequence[ExistingVia],
    tolerance: float,
) -> list[str]:
    """Best-effort ids of the accepted copper joining ``pads``' components.

    HITL-4 (docs/llm-ergonomics.md F1): the ``connected_via`` field of an
    `already_connected` span outcome. Runs the SAME union
    (:func:`_copper_union`, same tolerance) the grouping decision ran, then
    collects the ``source_id`` of every segment/via sharing a connected
    component with any of the pads. BEST EFFORT by contract: copper without a
    source id (any caller predating the field) contributes nothing, and the
    caller omits the key entirely when this comes back empty — absent-key,
    never an invented placeholder. Order is the copper's own (deterministic:
    the projection walks IR traces in board order), deduplicated because one
    ResolvedTrace decomposes into many segments carrying the same id.
    """
    if not pads:
        return []
    find, seg_node, via_node = _copper_union(pads, segments, vias, tolerance)
    pad_roots = {find(pi) for pi in range(len(pads))}
    ids: list[str] = []
    for si, seg in enumerate(segments):
        sid = seg.source_id
        if sid and find(seg_node + si) in pad_roots and sid not in ids:
            ids.append(sid)
    for vi, via in enumerate(vias):
        vid = via.source_id
        if vid and find(via_node + vi) in pad_roots and vid not in ids:
            ids.append(vid)
    return ids


# ---------------------------------------------------------------------------
# HITL-4 (docs/llm-ergonomics.md F1) — the per-span outcome builders.
#
# One builder per named status, called from BOTH entry points' net loops at the
# exact decision site that used to fall through silently. They build plain
# JSON-shaped dicts (the same convention as `_unrouted_reason_entry`) so the
# serializer passes them through without an engine-type hop. Pad spelling is
# the reply's own "<component>.<number>".
# ---------------------------------------------------------------------------


def _already_connected_outcome(
    net_name: str,
    pads: list[Pad],
    existing_by_net: dict,
    grid_resolution: float,
) -> dict:
    """The outcome for a net/span whose spanning tree needed ZERO edges.

    Reachable ONLY through the automatic branch (`_connections_for_net`): with
    >= 2 pads, `_build_spanning_tree` over bare pads always yields an edge, so
    an empty connection list is possible exactly when the accepted-copper
    group contraction merged every pad into one node — i.e. the board already
    connects everything that was asked for.
    """
    entry = {
        "net": net_name,
        "status": "already_connected",
        "pads": [f"{p.component}.{p.number}" for p in pads],
    }
    segments, vias = existing_by_net.get(net_name, ((), ()))
    if segments or vias:
        ids = _connected_copper_ids(
            pads, segments, vias,
            _coincidence_tolerance(grid_resolution, segments, vias))
        # Absent-key contract (hint 019f9d061f13): no ids means "the copper
        # carries no source ids", not "nothing connects these pads" — an empty
        # list would read as the latter.
        if ids:
            entry["connected_via"] = ids
    return entry


def _skipped_span_outcome(
    net_name: str,
    pads: list[Pad],
    net_terminals: Optional[dict],
) -> Optional[dict]:
    """The outcome for a net the loop skipped at the `< 2 pads` guard.

    Only a SPAN-SCOPED ask (a `net_terminals` entry for this net) gets an
    outcome: the caller named endpoints and fewer than two of them resolved,
    which is an answer the caller must see (`terminals_unmatched`). A net with
    no entry returns None — `_order_nets` never lists a net with < 2 pads, so
    that skip is not an ask that went unanswered, and inventing an outcome for
    it would put entries on the reply nobody asked about.
    """
    named = (net_terminals or {}).get(net_name)
    if named is None:
        return None
    return {
        "net": net_name,
        "status": "terminals_unmatched",
        "requested": sorted(str(r) for r in named),
        "matched": [f"{p.component}.{p.number}" for p in pads],
    }


def _existing_copper_by_net(
    existing_traces: Sequence[ExistingSegment],
    existing_vias: Sequence[ExistingVia],
) -> dict[str, tuple[list[ExistingSegment], list[ExistingVia]]]:
    """Index accepted copper by net once, so the per-net routing loop does not
    rescan the whole board's copper for every net it routes."""
    by_net: dict[str, tuple[list[ExistingSegment], list[ExistingVia]]] = {}
    for seg in existing_traces:
        if seg.net:
            by_net.setdefault(seg.net, ([], []))[0].append(seg)
    for via in existing_vias:
        if via.net:
            by_net.setdefault(via.net, ([], []))[1].append(via)
    return by_net


def _connections_for_net(
    pads: list[Pad],
    net_name: str,
    existing_by_net: dict[str, tuple[list[ExistingSegment], list[ExistingVia]]],
    grid_resolution: float,
) -> list[tuple[Pad, Pad]]:
    """The connections this net still NEEDS: a spanning tree over the groups the
    board's accepted copper has already merged, not over the bare pads.

    Takes the raw ``grid_resolution`` rather than a pre-computed tolerance so the
    physical cap in :func:`_coincidence_tolerance` cannot be bypassed by a caller
    that resolves the tolerance itself — one owner, same reasoning as
    ``RoutingGrid.keepout_margin``.
    """
    segments, vias = existing_by_net.get(net_name, ((), ()))
    if not segments and not vias:
        return _build_spanning_tree(pads, None)
    groups = _preconnected_groups(
        pads, segments, vias,
        _coincidence_tolerance(grid_resolution, segments, vias))
    return _build_spanning_tree(pads, groups)


def _net_width(net_widths: Optional[NetWidths], net_name: Optional[str],
              base_width: float) -> float:
    """THIS net's own copper width: its class override, or the run's
    baseline. `net_name=None` (an unconnected pad) and a net absent from the
    map both fall straight through — there is nothing to look up."""
    if not net_widths or net_name not in net_widths:
        return base_width
    return net_widths[net_name]


# ---------------------------------------------------------------------------
# RUN SCOPE (019f80a80123 / 019f6cf2b5f4).
#
# Both entry points below used to route EVERY net on the board with >= 2 pads,
# always. A caller that asked for two nets got the whole board back — sixteen
# proposals from two hints on the real smart-remote board — and every one of
# them was then attributed to hints that never asked for it.
#
# `only_nets` scopes the run. It is deliberately applied at ONE place, to the
# ordered net list the automatic loop walks, and NOWHERE else. Everything that
# makes the board an obstacle course — pads (board.pads), accepted copper
# (_mark_existing_copper), holes/keepouts (board.obstacles) — is marked on the
# grid BEFORE this filter is consulted and is never filtered by it. That is the
# load-bearing invariant of this parameter:
#
#     excluding a net from ROUTING must never exclude its copper from the GRID.
#
# A net left out of the run is still a wall the nets in the run must path
# around. See tests/test_route_scope.py, which drives route() over a board whose
# only clear path is blocked by an excluded net's accepted copper.
#
# Authored input (buses, chains, internal bridges) is NOT filtered — the
# standing rule in docs/routing.md is that authored input is admitted or
# rejected, never reinterpreted, the same reason the T7 group contraction is not
# applied to bridges/chains below. Callers therefore must include any authored
# net in `only_nets`; pcb_worker.methods._route does exactly that by building
# the set from the hints it just translated.
# ---------------------------------------------------------------------------


def _scoped_nets(ordered: list[str], only_nets: Optional[set] = None) -> list[str]:
    """Filter an ordered net list to the run's scope, order preserved.

    ``None`` means "no scope given" — route everything, the historical
    behaviour every unscoped caller (the CLI, design_review flows, every
    pre-scope test) still gets. An EMPTY set is a real, honoured answer: it
    means "the caller asked for a scoped run and nothing was in scope", which
    routes nothing. Conflating the two is precisely the whole-board surprise
    this parameter exists to remove, so ``if not only_nets`` would be wrong
    here and ``is None`` is what is tested.
    """
    if only_nets is None:
        return ordered
    return [n for n in ordered if n in only_nets]


def _terminal_pads(pads: list, net_name: str,
                   net_terminals: Optional[dict] = None) -> list:
    """Narrow a net's pad list to the caller-named TERMINAL subset.

    Span-scoped routing (docket 019fcb6f9d20, un-refusing route_bridge's
    documented gap 019fc155bc32): ``net_terminals`` maps net name -> a set of
    ``"Component.Pad"`` refs. A net with an entry routes ONLY between those
    pads; the omitted same-net pads keep their grid presence (they were marked
    with every other pad before any loop ran) but are no longer connection
    targets, so "connect MIC1.6 to AMP1.6" on a 14-pad GND net returns exactly
    that span instead of stitching the whole net. ``None`` (every pre-span
    caller) and a net with no entry are byte-identical to the historical
    whole-net behaviour. Terminal refs are matched on the same
    ``f"{component}.{number}"`` identity route_bridge validated against the
    board, so an unknown ref cannot silently widen the run — it simply matches
    nothing and the (< 2 pads) guard skips the net.
    """
    if net_terminals is None:
        return pads
    named = net_terminals.get(net_name)
    if named is None:
        return pads
    return [p for p in pads if f"{p.component}.{p.number}" in named]


# ---------------------------------------------------------------------------
# PRECEDENCE — the run's EFFECTIVE design rules.
#
# THE one implementation. It was born in pcb_worker.methods (Round E2) reading
# the compiled IR directly, which put it out of reach of every caller that has
# no compiler — so agent_router.cli routed at the engine's signature defaults on
# a board that authored its own (bug 019f9b38a93f). It lives HERE now because
# this is the module both entry points already depend on, and because the
# chain's LAST step is this engine's own default: `route_board`'s signature is
# three lines below, so that step is a local read rather than a cross-package
# `inspect` of another package's function.
#
# The order is UNCHANGED from Round E2 + A4 — only the physical home of step 3
# moved (from `rb.design_rules` to `board.design_rules`, which the worker fills
# with that same IR object). Highest first:
#
#   1. an explicit caller option   (options.trace_width / .clearance, or the
#                                   CLI's --trace-width / --clearance)
#   2. a hint-authored width       (TRACE WIDTH ONLY — a route hint has no
#                                   clearance field to author). Merged into
#                                   `options` by the caller BEFORE this runs, so
#                                   from here 1 and 2 are indistinguishable and
#                                   both report as "caller_or_hint"; only
#                                   pcb_worker.methods._route still knows which,
#                                   and it refines the label for the reply.
#   3. the BOARD's own design rules
#        width     <- design_rules.defaults.trace_width_mm
#        clearance <- design_rules.minimums.min_clearance_mm
#   4. what this engine would have applied, read from its own signature.
#
# (Per-net-class minima sit BETWEEN 2 and 3 for the nets that have a class;
# they are a per-net override applied by pcb_worker.methods on top of the
# run-wide pair this returns, and are deliberately not folded in here — the
# run-wide answer has to exist first for a class to narrow.)
# ---------------------------------------------------------------------------


# RoutingRulesError is defined in .board (the lower module, which must raise it
# too) and re-exported here because this is where callers meet it.
# ``pcb_worker.methods`` translates it into that package's own
# ``UnsupportedGeometry``, so the worker's structured reply is unchanged.


def positive_mm(value) -> Optional[float]:
    """A finite, strictly-positive millimetre scalar, or None.

    A copper dimension is never modeled from a non-positive or non-finite
    number. (``pcb_worker.ir_candidates.positive_mm`` is the identical predicate
    for the worker's candidate overlay; the two are separate only because this
    package may not import that one — see the finding in the round report.)
    """
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    v = float(value)
    if v <= 0.0 or v != v or v in (float("inf"), float("-inf")):
        return None
    return v


def nonnegative_mm(value) -> Optional[float]:
    """A finite, non-negative millimetre scalar, or None.

    The clearance sibling of :func:`positive_mm`. Clearance differs from a
    copper dimension in the one way that matters: **zero is a legal value**. A
    caller who explicitly asks for ``clearance: 0`` is asking for no clearance,
    and silently promoting that to the board's rule would change what an
    explicit option MEANS. ``positive_mm`` would do exactly that, so it is not
    reused here.
    """
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    v = float(value)
    if v < 0.0 or v != v or v in (float("inf"), float("-inf")):
        return None
    return v


def engine_default_mm(param: str) -> Optional[float]:
    """A millimetre default :func:`route_board` applies when the caller sets none.

    Read from the function's OWN signature rather than re-spelled as a literal:
    every consumer must model what the engine ACTUALLY does, and a duplicated
    default that drifted would silently under- or over-state copper (or a
    keepout). Returns None if it cannot be read, which makes the caller fail
    closed rather than guess.
    """
    import inspect
    try:
        default = inspect.signature(route_board).parameters[param].default
    except (KeyError, TypeError, ValueError):
        return None
    if isinstance(default, bool) or not isinstance(default, (int, float)):
        return None
    return float(default)


def _sourced_with_label(*steps: tuple) -> tuple:
    """The first precedence step that yields a value, plus that step's NAME.

    Provenance is part of the contract (docs/routing.md, "Provenance") — a
    consumer must be able to tell WHICH source supplied an effective value,
    never just what the value is.

    DELIBERATELY NOT AN ``or`` CHAIN. ``or`` treats ``0.0`` as absent, which is
    the one value that differs between the two dimensions: a zero clearance is a
    legal request, and a zero engine default would fall THROUGH to the next term
    while still passing an ``is None`` guard — the run and the candidate overlay
    would then disagree about the width, which is what Round E2 exists to
    prevent. Every step is an explicit ``is None`` test.
    """
    for label, step in steps:
        value = step()
        if value is not None:
            return value, label
    return None, None


def _explicit_mm(options: dict, key: str, predicate, expected: str) -> Optional[float]:
    """An explicitly-supplied option, admitted or REJECTED — never reinterpreted.

    None means "the caller said nothing", so the next precedence step applies. A
    key that is PRESENT but inadmissible (0 or -1 for a width, NaN, a string)
    raises instead of silently falling through to the board's rule: quietly
    routing at a different number than the caller asked for is the same class of
    dishonesty as quietly routing at the engine's default.

    The two dimensions differ only in their PREDICATE, not in this policy:
    ``clearance: 0`` is admissible while ``trace_width: 0`` is not.
    """
    if key not in options:
        return None
    value = predicate(options[key])
    if value is None:
        raise RoutingRulesError(
            f"option {key!r}={options[key]!r} is not {expected}; routing fails "
            f"closed rather than silently substitute a different value for the "
            f"one the caller asked for")
    return value


def _board_rule_mm(board: Board, *path: str, predicate) -> Optional[float]:
    """One design-rule scalar off ``board.design_rules``.

    Returns the value, or None meaning **this board authored no such rule** — a
    legitimate absence, and the only thing that may fall through to the next
    precedence step. Anything PRESENT that cannot be read raises
    :class:`RoutingRulesError`.

    THAT DISTINCTION IS THE WHOLE POINT. An earlier cut of this function walked
    a ``getattr`` chain and returned None for every failure, so a board whose
    rules were present but shaped wrong — a plain ``dict`` instead of a rules
    object, a misnamed field, an authored ``trace_width_mm: "0.35"`` — silently
    resolved to the engine's 0.25/0.2. That is precisely the silent-default
    signature of bug 019f9b38a93f, i.e. this round's own bug reintroduced one
    layer down: previously a caller forgot to PASS rules, now a caller passes
    rules we quietly fail to READ. Failing closed here also makes this
    consistent with :func:`_explicit_mm`, which already refuses a
    present-but-inadmissible run option rather than reinterpreting it.

    STRING NUMERICS ARE REJECTED, NOT COERCED. ``trace_width_mm: "0.35"`` raises
    rather than being read as 0.35. Two reasons, both deliberate: the house rule
    puts routing in the fail-closed bucket, and the raw CAM path already rejects
    string numerics in exactly this position (``pad_source
    ._require_valid_authored_drill`` refuses a string ``drill_mm``) — routing
    admitting what fabrication refuses would put the two surfaces back out of
    step, which is the class of divergence this campaign keeps closing.
    """
    rules = getattr(board, "design_rules", None)
    if rules is None:
        return None  # authors no rules at all (a bare .kicad_pcb) — fall through

    node = rules
    walked = path[0]
    for name in path[1:]:
        if not hasattr(node, name):
            raise RoutingRulesError(
                f"this board carries design rules, but {walked!r} has no "
                f"{name!r} — the rules are present and could not be read "
                f"(got {type(node).__name__}). Routing fails closed rather than "
                f"silently fall back to the engine's default and route at a "
                f"width the board did not author")
        node = getattr(node, name)
        walked = f"{walked}.{name}"
        if node is None:
            return None  # the rule itself is unset — a partial block is legal

    value = predicate(node)
    if value is None:
        raise RoutingRulesError(
            f"this board authors {walked} = {node!r}, which is not a usable "
            f"millimetre value; routing fails closed rather than ignore an "
            f"authored rule and route at the engine's default instead")
    return value


def resolve_effective_rules(board: Board, options: dict) -> tuple:
    """(trace_width_mm, width_source, clearance_mm, clearance_source).

    THE precedence chain (see the module note above). ``options`` carries steps
    1 and 2 already merged by the caller. Raises :class:`RoutingRulesError` if a
    dimension cannot be sourced or an explicit option is inadmissible.

    The pair this returns is what the ENGINE routes at, what the GRID inflates
    its keepouts by (``clearance + trace_width / 2``), and what the candidate
    overlay is checked at — one value, three consumers, so they cannot disagree.
    """
    width, width_source = _sourced_with_label(
        ("caller_or_hint", lambda: _explicit_mm(
            options, "trace_width", positive_mm,
            "a positive, finite trace width in mm")),
        ("board_rules", lambda: _board_rule_mm(
            board, "design_rules", "defaults", "trace_width_mm",
            predicate=positive_mm)),
        ("engine_default", lambda: positive_mm(engine_default_mm("trace_width"))),
    )
    if width is None:
        raise RoutingRulesError(
            "no trace width could be sourced for this run (no caller option, no "
            "hint width, no design_rules.defaults.trace_width_mm on the board, "
            "and the engine's own default is unreadable) — routing fails closed "
            "rather than route at an invented width")

    clearance, clearance_source = _sourced_with_label(
        ("caller_or_hint", lambda: _explicit_mm(
            options, "clearance", nonnegative_mm,
            "a non-negative, finite clearance in mm")),
        ("board_rules", lambda: _board_rule_mm(
            board, "design_rules", "minimums", "min_clearance_mm",
            predicate=nonnegative_mm)),
        ("engine_default", lambda: nonnegative_mm(engine_default_mm("clearance"))),
    )
    if clearance is None:
        raise RoutingRulesError(
            "no clearance could be sourced for this run (no caller option, no "
            "design_rules.minimums.min_clearance_mm on the board, and the "
            "engine's own default is unreadable) — routing fails closed rather "
            "than reserve an invented keepout")

    return (width, width_source, clearance, clearance_source)


def route_board(
    board: Board,
    allow_vias: bool = True,
    single_layer: bool = False,
    order: str = "shortest_first",
    trace_width: float = 0.25,
    clearance: float = 0.2,
    grid_resolution: float = 0.1,
    net_widths: Optional[NetWidths] = None,
    keepout_clearance: Optional[float] = None,
    keepout_trace_width: Optional[float] = None,
    existing_traces: Sequence[ExistingSegment] = (),
    existing_vias: Sequence[ExistingVia] = (),
    only_nets: Optional[set] = None,
    net_terminals: Optional[dict] = None,
) -> RoutingResult:
    """
    Route the board's nets — all of them, or the ones in ``only_nets``.

    Args:
        board: Board to route
        allow_vias: Whether to allow vias for layer changes
        single_layer: If True, only route on F.Cu
        order: Net ordering strategy ("shortest_first", "longest_first")
        trace_width: Default trace width in mm — the FALLBACK copper width for
            any net not named in ``net_widths``.
        clearance: Minimum clearance between traces in mm — the FALLBACK
            keepout clearance if ``keepout_clearance`` is None.
        grid_resolution: Grid resolution in mm
        net_widths: per-net class-sourced copper width override (see the
            module note above). Affects ONLY the copper drawn for that net —
            never the keepout margin, which is grid-wide (below).
        keepout_clearance / keepout_trace_width: the grid's OWN clearance/
            trace_width, if they differ from the run's baseline (net-class
            minima; see the module note above). None (every pre-net-class
            caller) means "use clearance/trace_width", i.e. unchanged
            behaviour — a board with no net classes present sees no change.
        existing_traces / existing_vias: the board's ALREADY-ACCEPTED copper
            (T7, 019f70ebc9ed — see the module note above). Other-net copper
            becomes an obstacle through the same markers (and therefore the same
            keepout_margin) as freshly-routed copper; same-net copper is
            already-connected, so the net may path along it and the pads it
            joins are not re-routed. Empty (every pre-T7 caller) is the
            unchanged behaviour.
        only_nets: the run's SCOPE — see the module note above ``_scoped_nets``.
            None (every pre-scope caller) routes every net, unchanged. A set
            routes only those nets; the rest still occupy the grid as pads,
            obstacles and accepted copper, so they remain obstacles.

    Returns:
        RoutingResult with routes and unrouted connections
    """
    result = RoutingResult()

    # The BOARD's own accepted copper, when the caller named none (019f9bc3909c).
    # A Board built from a partially-routed source carries its copper in its own
    # slots, so a caller that forgets these two options still routes AROUND that
    # copper instead of straight through it. An explicit option still wins — the
    # slots are the source, options are the override layer.
    existing_traces = existing_traces or board.existing_traces
    existing_vias = existing_vias or board.existing_vias

    # Create routing grid over the board's OWN extent, anchored at its origin.
    layers = ["F.Cu"] if single_layer else ["F.Cu", "B.Cu"]
    grid_w, grid_h = _grid_extent(board)
    grid = RoutingGrid(
        width=grid_w,
        height=grid_h,
        resolution=grid_resolution,
        clearance=clearance if keepout_clearance is None else keepout_clearance,
        layers=layers,
        origin=board.origin,
        # Round E2: the grid inflates every keepout by `clearance +
        # trace_width / 2`, so it needs the width this run actually routes at.
        # Passing it here (rather than letting RoutingGrid default) is what makes
        # the reserved space and the proposed copper the SAME width — a keepout
        # sized for a narrower trace than the one being laid is an under-block.
        # Net-class minima (this round): the grid's OWN trace_width is the
        # board-wide WORST CASE, not necessarily what any one net actually
        # draws — see the module note above for why that is deliberate.
        trace_width=trace_width if keepout_trace_width is None else keepout_trace_width,
    )

    # Mark all pads on the grid. The margin every pad's ring reserves is the
    # GRID's own (worst-case) margin, uniformly — see the module note above;
    # a per-pad override was rejected as an under-block.
    for pad in board.pads:
        if pad.layer in layers:
            pad_layers = [pad.layer]
        elif pad.layer == "*.Cu" or pad.pad_type == "thru_hole":
            # Through-hole pads are accessible on all copper layers
            pad_layers = list(layers)
        else:
            pad_layers = ["F.Cu"]
        for pl in pad_layers:
            grid.mark_pad(
                x=pad.position[0],
                y=pad.position[1],
                size=pad.size,
                net=pad.net,
                layer=pl,
                rotation=pad.rotation
            )

    # The board's OWN accepted copper, between pads and obstacles — see
    # _mark_existing_copper for why that position in the order is load-bearing.
    _mark_existing_copper(grid, existing_traces, existing_vias, layers)

    # Mark obstacles. Polygon obstacles (authored keepout zones — Epoch UX3
    # station 2, router item 019fc155bc32) rasterise per-layer through the
    # grid's own mark_keepout_polygon; disc obstacles keep the original path.
    # Before that method existed, Obstacle.polygon/layer were declared but
    # read NOWHERE — the gap pcb_worker.route_bridge fail-closed over.
    for obstacle in board.obstacles:
        if obstacle.radius:
            grid.mark_obstacle(
                x=obstacle.position[0],
                y=obstacle.position[1],
                radius=obstacle.radius
            )
        elif obstacle.polygon:
            grid.mark_keepout_polygon(
                obstacle.polygon,
                layer=None if obstacle.blocks_all_layers else obstacle.layer,
            )

    existing_by_net = _existing_copper_by_net(existing_traces, existing_vias)

    # Get ordered list of nets to route, narrowed to the run's scope. The
    # filter sits HERE, after every grid marking above, so an out-of-scope net
    # is absent from the routing loop but fully present on the grid.
    nets_to_route = _scoped_nets(_order_nets(board, order), only_nets)

    # Route each net
    for net_name in nets_to_route:
        pads = _terminal_pads(board.get_net_pads(net_name), net_name, net_terminals)
        if len(pads) < 2:
            # HITL-4 (docs/llm-ergonomics.md F1): a span-scoped ask whose
            # terminals resolved to < 2 pads is answered, not skipped in
            # silence — see _skipped_span_outcome for why only the span form
            # gets an entry.
            outcome = _skipped_span_outcome(net_name, pads, net_terminals)
            if outcome is not None:
                result.span_outcomes.append(outcome)
            continue  # Skip nets with less than 2 pads

        net_width = _net_width(net_widths, net_name, trace_width)
        route = Route(net=net_name)

        # Spanning tree over what the board still NEEDS: pads the accepted copper
        # already joins collapse to one node, so a partly-routed net is finished
        # rather than routed again from scratch (T7, 019f70ebc9ed).
        connections = _connections_for_net(
            pads, net_name, existing_by_net, grid_resolution)
        if not connections:
            # HITL-4 (docs/llm-ergonomics.md F1): zero needed edges with >= 2
            # pads means the accepted copper already joins everything asked
            # for (see _already_connected_outcome). This used to fall through
            # producing NOTHING — no route, no unrouted pair — which made an
            # already-satisfied span byte-identical to a dropped request.
            result.span_outcomes.append(_already_connected_outcome(
                net_name, pads, existing_by_net, grid_resolution))
            continue

        for pad_a, pad_b in connections:
            path = find_path(
                grid=grid,
                start=pad_a.position,
                end=pad_b.position,
                net=net_name,
                layer="F.Cu",
                allow_via=allow_vias and not single_layer
            )

            if path:
                route.paths.append(path)
                route.vias.extend(path.vias)
                result.via_count += len(path.vias)

                # Mark the path on the grid. The TRUE copper width goes in
                # (THIS net's own, net-class or baseline); RoutingGrid adds
                # its own keepout_margin (Round E2), sized to the board-wide
                # worst case, not to this specific net (see the module note
                # above). This used to hand-inflate to `trace_width + 2 *
                # clearance`, a half-extent of `w/2 + clearance` — short by
                # the newcomer's own half-width, so a later trace could sit
                # half a width inside the clearance gap.
                for segment in path.segments:
                    grid.mark_trace(
                        start=segment.start,
                        end=segment.end,
                        width=net_width,
                        net=net_name,
                        layer=segment.layer
                    )
            else:
                result.unrouted.append((net_name, pad_a, pad_b))
                result.unrouted_reasons.append(_unrouted_reason_entry(
                    grid, net_name, pad_a, pad_b, "F.Cu"))

        if route.paths:
            result.routes.append(route)

    result.success = len(result.unrouted) == 0
    return result


def _unrouted_reason_entry(grid, net_name: str, pad_a: Pad, pad_b: Pad,
                           layer: str) -> dict:
    """One ``RoutingResult.unrouted_reasons`` entry, naming the same pair
    ``unrouted`` names.

    The pads are spelled ``"<component>.<number>"`` — the SAME spelling
    ``pcb_worker.methods._serialize_routing_result`` already uses for
    ``unrouted``, so the two are readable side by side.

    DO NOT JOIN ON THAT TRIPLE. An earlier version of this docstring suggested
    a consumer could pair the lists on ``(net, from, to)`` "rather than trusting
    the index alignment". That is unsound and docket 019f9d59a49b measured why:
    a user-authored ``chain`` pair is appended to a net's connections
    UNDEDUPLICATED against the automatic spanning tree, so the same triple can
    legitimately appear twice in ``unrouted`` with two independently-computed
    reasons. A join cannot tell those apart; it would pick one arbitrarily.
    Index alignment is the contract — see the ``unrouted_reasons`` field
    comment above.
    """
    return {
        "net": net_name,
        "from": f"{pad_a.component}.{pad_a.number}",
        "to": f"{pad_b.component}.{pad_b.number}",
        "layer": layer,
        "reason": unroutable_reason(grid, pad_a.position, pad_b.position,
                                    net_name, layer),
    }


# Patterns that identify power/ground nets (matched case-insensitively)
_POWER_NET_PATTERNS = re.compile(
    r'^(VCC|VDD|GND|VBUS|VSYS|3V3|5V|12V|PWR|AGND|DGND|V\d)',
    re.IGNORECASE,
)


def _is_power_net(net_name: str) -> bool:
    """Return True if *net_name* looks like a power or ground rail."""
    return bool(_POWER_NET_PATTERNS.search(net_name))


def _grid_extent(board: Board) -> tuple[float, float]:
    """The board's own routable extent — its outline, nothing more.

    This used to be ``_effective_grid_size``, which GREW the grid to cover any pad
    lying outside the outline (plus a 2mm margin). That silently enlarged the legal
    routing area: copper outside the board became routable space, and a proposal
    could be laid down where no board exists. The outline is the legal area
    (019f783860c8 gap C); a pad outside it is simply out of bounds, so nets that
    need it come back UNROUTED rather than routed off-board.

    Note this is a pure extent — the grid is anchored at ``board.origin``, so a
    board spanning x in [10, 50] is 40mm wide and starts at 10, not 50 wide
    starting at 0.
    """
    return board.width, board.height


def _order_nets(board: Board, strategy: str) -> list[str]:
    """
    Order nets for routing based on strategy.

    Args:
        board: Board with nets
        strategy: "shortest_first", "longest_first", or "signals_first"

    Returns:
        Ordered list of net names
    """
    # Calculate total wire length for each net
    net_lengths: dict[str, float] = {}

    for net_name, net in board.nets.items():
        if len(net.pads) < 2:
            continue

        # Estimate length as sum of distances between adjacent pads
        total_length = 0.0
        for i in range(len(net.pads) - 1):
            p1 = net.pads[i].position
            p2 = net.pads[i + 1].position
            total_length += math.sqrt(
                (p2[0] - p1[0]) ** 2 + (p2[1] - p1[1]) ** 2
            )
        net_lengths[net_name] = total_length

    if strategy == "signals_first":
        # Signal nets first (sorted by pad count ascending), power/GND last
        def _sort_key(name: str) -> tuple[int, int, float]:
            is_pwr = 1 if _is_power_net(name) else 0
            pad_count = len(board.nets[name].pads)
            return (is_pwr, pad_count, net_lengths.get(name, 0.0))

        sorted_nets = sorted(net_lengths.keys(), key=_sort_key)
    else:
        # Sort by length
        reverse = strategy == "longest_first"
        sorted_nets = sorted(
            net_lengths.keys(),
            key=lambda n: net_lengths[n],
            reverse=reverse,
        )

    return sorted_nets


def _build_spanning_tree(
    pads: list[Pad],
    groups: Optional[dict[int, int]] = None,
) -> list[tuple[Pad, Pad]]:
    """
    Build minimum spanning tree for connecting pads.

    Uses Prim's algorithm seeded from the most peripheral pad (farthest
    from centroid) to produce chain-like topologies instead of star
    patterns radiating from a central component.

    Args:
        pads: List of pads to connect
        groups: optional ``{pad index -> group id}`` saying which pads the board's
            EXISTING accepted copper already joins (T7, 019f70ebc9ed; built by
            :func:`_preconnected_groups`). Pads sharing a group are treated as ONE
            node, so the result is a spanning tree over the GROUPS — the
            connections the net still lacks — rather than over the bare pads. A
            net whose pads are entirely joined already yields ZERO connections.
            None (every caller before T7, and every net with no accepted copper)
            means one group per pad, i.e. the unchanged full MST.

    Returns:
        List of (pad1, pad2) connections forming the MST
    """
    if len(pads) < 2:
        return []

    group_of = groups if groups is not None else {i: i for i in range(len(pads))}

    if len(pads) == 2:
        # Same short-circuit as before, but it has to ask the same question the
        # loop below does: two pads the board already joins need no connection.
        if group_of.get(0) == group_of.get(1):
            return []
        return [(pads[0], pads[1])]

    # Seed from the most peripheral pad (farthest from centroid)
    cx = sum(p.position[0] for p in pads) / len(pads)
    cy = sum(p.position[1] for p in pads) / len(pads)
    seed = max(range(len(pads)), key=lambda i: (
        (pads[i].position[0] - cx) ** 2 + (pads[i].position[1] - cy) ** 2
    ))

    # Prim's algorithm using indices (Pad is not hashable). The tree starts
    # holding the seed's WHOLE group, and absorbing any pad absorbs its whole
    # group — that contraction is the only difference from the plain MST.
    def _group_members(index: int) -> set[int]:
        gid = group_of.get(index, index)
        return {i for i in range(len(pads)) if group_of.get(i, i) == gid}

    connections = []
    in_tree_indices = _group_members(seed)
    not_in_tree_indices = set(range(len(pads))) - in_tree_indices

    while not_in_tree_indices:
        best_edge = None
        best_dist = float('inf')

        for i in in_tree_indices:
            for j in not_in_tree_indices:
                in_pad = pads[i]
                out_pad = pads[j]
                dist = math.sqrt(
                    (out_pad.position[0] - in_pad.position[0]) ** 2 +
                    (out_pad.position[1] - in_pad.position[1]) ** 2
                )
                if dist < best_dist:
                    best_dist = dist
                    best_edge = (i, j)

        if best_edge is None:
            break
        connections.append((pads[best_edge[0]], pads[best_edge[1]]))
        absorbed = _group_members(best_edge[1])
        in_tree_indices |= absorbed
        not_in_tree_indices -= absorbed

    return connections


def _apply_bridge_assignments(
    pads: list[Pad],
    bridges: list,
    board: Board,
    chained_pads: Optional[set[tuple[str, str]]] = None,
    internal_nets: dict[str, dict[str, list[str]]] | None = None,
) -> list[tuple[Pad, Pad]]:
    """Split a bridged net into subgroups based on pin_assignments.

    For a net like GND with 13 pads and bridge assignments on U1, instead
    of one MST over all 13 pads, we create subgroups where each external
    component connects only to its assigned bridge pin on U1.

    Internal pins (those in the same bridge) have zero-cost virtual edges
    because they're already connected inside the IC package.

    Args:
        pads: All pads on this net
        bridges: List of InternalBridge objects for this net
        board: Board for component lookup
        chained_pads: Set of (component, pin) tuples that will be
            connected via chain hints instead of bridge star routing.
            These pads are excluded from bridge connections.

    Returns:
        List of (pad1, pad2) connections, fewer than a full MST
    """
    if not bridges:
        return _build_spanning_tree(pads)

    if chained_pads is None:
        chained_pads = set()

    # Build subgroups from bridge assignments
    # Each subgroup: [bridge_pin_pad, external_pad_1, external_pad_2, ...]
    assigned_pads: set[int] = set()  # indices into pads list
    connections: list[tuple[Pad, Pad]] = []

    for bridge in bridges:
        comp_id = bridge.component
        for pin_str, ext_comp_ids in bridge.pin_assignments.items():
            # Find the bridge pin pad
            bridge_pad = None
            bridge_pad_idx = None
            for idx, pad in enumerate(pads):
                if pad.component == comp_id and pad.number == pin_str:
                    bridge_pad = pad
                    bridge_pad_idx = idx
                    break

            if bridge_pad is None:
                continue

            assigned_pads.add(bridge_pad_idx)

            # Find pads belonging to the assigned external components
            for ext_comp in ext_comp_ids:
                for idx, pad in enumerate(pads):
                    if pad.component == ext_comp and idx not in assigned_pads:
                        # Skip pads that are handled by chain hints
                        if (pad.component, pad.number) in chained_pads:
                            assigned_pads.add(idx)
                            continue
                        connections.append((bridge_pad, pad))
                        assigned_pads.add(idx)

    # Mark internal-net orphan pins as assigned (already bonded inside IC)
    if internal_nets:
        for bridge in bridges:
            inet_pins = internal_nets.get(bridge.component, {}).get(bridge.net, [])
            for idx, pad in enumerate(pads):
                if (pad.component == bridge.component
                        and pad.number in inet_pins
                        and idx not in assigned_pads):
                    assigned_pads.add(idx)

    # Remaining unassigned pads: route with MST among themselves + one bridge anchor
    remaining = [p for idx, p in enumerate(pads) if idx not in assigned_pads]
    if remaining:
        # Use only ONE bridge pin as anchor (all bridge pins are internally
        # connected, so any single one suffices; using all of them causes
        # the MST to create bogus bridge-to-bridge edges).
        anchor_pad = None
        for bridge in bridges:
            for pin_str in bridge.pin_assignments:
                for pad in pads:
                    if pad.component == bridge.component and pad.number == pin_str:
                        anchor_pad = pad
                        break
                if anchor_pad:
                    break
            if anchor_pad:
                break

        mst_pads = ([anchor_pad] if anchor_pad else []) + remaining
        if len(mst_pads) >= 2:
            connections.extend(_build_spanning_tree(mst_pads))

    return connections


def _resolve_chain_pads(
    board: Board,
    chain: "ChainHint",
) -> list[Pad]:
    """Resolve chain pad references (e.g. 'SW1.B') to actual Pad objects.

    Returns list of Pad objects in chain order, or empty list if
    any reference cannot be resolved.
    """
    resolved = []
    for pad_ref in chain.pads:
        comp_id, pin_id = pad_ref.split(".", 1)
        net_pads = board.get_net_pads(chain.net)
        found = None
        for pad in net_pads:
            if pad.component == comp_id and pad.number == pin_id:
                found = pad
                break
        if found is None:
            return []
        resolved.append(found)
    return resolved


def _generate_bus_waypoints(
    board: Board,
    bus_hint: "BusHint",
    escape_distance: float = 3.0,
) -> list:
    """Auto-generate waypoints for a bus that has none.

    Groups all bus-net pads by component, picks the two components with
    the most bus connections as source and destination, then places two
    waypoints along the corridor between their pad centroids (offset by
    *escape_distance* inward from each end so the bus trunk starts
    after the pads fan out).

    Returns a list of ``Waypoint`` objects (empty if generation fails).
    """
    from .hints import Waypoint

    # Collect pads per component across all bus nets
    comp_pads: dict[str, list[tuple[float, float]]] = {}
    for net_name in bus_hint.nets:
        for pad in board.get_net_pads(net_name):
            comp_pads.setdefault(pad.component, []).append(pad.position)

    if len(comp_pads) < 2:
        return []

    # Two components with the most bus pads → source and dest
    sorted_comps = sorted(comp_pads.items(), key=lambda kv: len(kv[1]), reverse=True)
    pads_a = sorted_comps[0][1]
    pads_b = sorted_comps[1][1]

    # Centroids
    cx_a = sum(p[0] for p in pads_a) / len(pads_a)
    cy_a = sum(p[1] for p in pads_a) / len(pads_a)
    cx_b = sum(p[0] for p in pads_b) / len(pads_b)
    cy_b = sum(p[1] for p in pads_b) / len(pads_b)

    dx = cx_b - cx_a
    dy = cy_b - cy_a
    dist = math.sqrt(dx * dx + dy * dy)
    if dist < 2.0 * escape_distance:
        # Components too close — just use centroids directly
        return [Waypoint(x=cx_a, y=cy_a), Waypoint(x=cx_b, y=cy_b)]

    ux, uy = dx / dist, dy / dist
    return [
        Waypoint(x=cx_a + ux * escape_distance, y=cy_a + uy * escape_distance),
        Waypoint(x=cx_b - ux * escape_distance, y=cy_b - uy * escape_distance),
    ]


def route_bus(
    grid: RoutingGrid,
    board: Board,
    bus_hint: "BusHint",
    trace_width: float = 0.25,
    layer: str = "F.Cu",
    orthogonal: bool = False,
    net_widths: Optional[NetWidths] = None,
) -> list[Route]:
    """
    Route a group of signals as a bus with consistent spacing.

    Uses waypoints from BusHint to guide the bus route. Each net in the
    bus is routed in parallel with spacing offsets.

    The algorithm ensures escape segments don't cross by:
    1. Sorting source pads by perpendicular position
    2. Using consistent offset perpendicular to waypoint segment throughout
    3. Creating entry points at the first waypoint y-level with proper spacing

    Args:
        grid: RoutingGrid with collision detection
        board: Board containing the pads
        bus_hint: BusHint with nets, spacing, and waypoints
        trace_width: Width of each trace — the FALLBACK for any net in the bus
            not named in ``net_widths``.
        layer: Layer to route on
        net_widths: per-net class-sourced copper width override (see the
            module note above ``route_board``). Net-class minima round 2: a
            bus net used to be laid at ``trace_width`` unconditionally, which
            made the reply's per-route provenance describe copper the bus
            never actually drew (docs/routing.md, "Bus routing now honours
            net-class width"). The spacing OFFSET between parallel bus traces
            is unaffected — that stays ``bus_hint.spacing``, a layout choice
            independent of any one net's width.

    Returns:
        List of Route objects, one per net in the bus
    """
    from .hints import BusHint  # Avoid circular import

    routes = []
    nets = bus_hint.nets
    spacing = bus_hint.spacing
    waypoints = bus_hint.waypoints

    if not nets or not waypoints:
        return routes

    # Calculate direction and perpendicular of waypoint segment
    if len(waypoints) >= 2:
        wp_dx = waypoints[1].x - waypoints[0].x
        wp_dy = waypoints[1].y - waypoints[0].y
        wp_length = math.sqrt(wp_dx*wp_dx + wp_dy*wp_dy)
        if wp_length > 0:
            # Unit vector along waypoint segment
            wp_dir_x = wp_dx / wp_length
            wp_dir_y = wp_dy / wp_length
            # Perpendicular unit vector (rotated 90°)
            perp_x = -wp_dir_y
            perp_y = wp_dir_x
        else:
            wp_dir_x, wp_dir_y = 0.0, 1.0
            perp_x, perp_y = 1.0, 0.0
    else:
        wp_dir_x, wp_dir_y = 0.0, 1.0
        perp_x, perp_y = 1.0, 0.0

    # Collect source and destination pads for each net
    first_wp = (waypoints[0].x, waypoints[0].y)
    last_wp = (waypoints[-1].x, waypoints[-1].y)

    net_pads = []
    for net_name in nets:
        pads = board.get_net_pads(net_name)
        if len(pads) < 2:
            continue

        source_pad = min(pads, key=lambda p:
            (p.position[0] - first_wp[0])**2 + (p.position[1] - first_wp[1])**2)
        dest_pad = min(pads, key=lambda p:
            (p.position[0] - last_wp[0])**2 + (p.position[1] - last_wp[1])**2)

        net_pads.append((net_name, source_pad, dest_pad))

    if not net_pads:
        return routes

    # For non-crossing bus routing, assign waypoint offsets based on destination
    # perpendicular position. This minimizes crossings at the destination end.
    # Note: If source and destination orderings conflict, crossings may still occur
    # and vias would be needed for a clean single-layer route.

    def dest_perp_position(item):
        _, _, dest_pad = item
        return dest_pad.position[0] * perp_x + dest_pad.position[1] * perp_y

    net_pads_sorted = sorted(net_pads, key=dest_perp_position)

    # Route each net
    num_nets = len(net_pads_sorted)
    for i, (net_name, source_pad, dest_pad) in enumerate(net_pads_sorted):
        # THIS net's own class-or-baseline width (net-class round 2) — the
        # copper actually drawn below, so the reply's per-route provenance
        # (pcb_worker.methods._attach_effective_routing_rules) never claims a
        # class width the bus laid down at the baseline instead.
        net_width = _net_width(net_widths, net_name, trace_width)

        # Calculate offset (centered around waypoint line)
        offset = (i - (num_nets - 1) / 2.0) * spacing
        offset_x = perp_x * offset
        offset_y = perp_y * offset

        # Create offset waypoints
        net_waypoints = [
            (wp.x + offset_x, wp.y + offset_y)
            for wp in waypoints
        ]

        # Calculate escape point: project pad position onto the first waypoint's
        # perpendicular line, then apply the same offset
        # This ensures parallel entry into the bus corridor

        # Vector from first waypoint to source pad
        pad_to_wp_x = source_pad.position[0] - first_wp[0]
        pad_to_wp_y = source_pad.position[1] - first_wp[1]

        # Project onto waypoint direction to find distance along bus
        dist_along_bus = pad_to_wp_x * wp_dir_x + pad_to_wp_y * wp_dir_y

        # Entry point is at first waypoint level (perpendicular to bus), with offset
        # But positioned at the pad's projection onto the perpendicular
        entry_point = (
            first_wp[0] + offset_x + dist_along_bus * wp_dir_x,
            first_wp[1] + offset_y + dist_along_bus * wp_dir_y
        )

        route = Route(net=net_name)

        # Build path: source_pad -> entry_point -> first waypoint -> ... -> dest_pad
        # Only include entry point if it's significantly different from pad and waypoint
        entry_dist_from_pad = math.sqrt(
            (entry_point[0] - source_pad.position[0])**2 +
            (entry_point[1] - source_pad.position[1])**2
        )
        entry_dist_from_wp = math.sqrt(
            (entry_point[0] - net_waypoints[0][0])**2 +
            (entry_point[1] - net_waypoints[0][1])**2
        )

        if entry_dist_from_pad > 0.5 and entry_dist_from_wp > 0.5:
            path_points = [source_pad.position, entry_point] + net_waypoints + [dest_pad.position]
        else:
            path_points = [source_pad.position] + net_waypoints + [dest_pad.position]

        # Create path segments
        path = _create_waypoint_path(path_points, net_name, layer, orthogonal=orthogonal)
        if path:
            route.paths.append(path)

            for segment in path.segments:
                # True copper width only (THIS net's own) — the grid owns the
                # keepout margin (see the note in route_board; Round E2 and
                # the net-class round).
                grid.mark_trace(
                    start=segment.start,
                    end=segment.end,
                    width=net_width,
                    net=net_name,
                    layer=layer
                )

        if route.paths:
            routes.append(route)

    return routes


def _create_waypoint_path(
    points: list[tuple[float, float]],
    net: str,
    layer: str,
    orthogonal: bool = False,
) -> Optional[Path]:
    """
    Create a Path from a list of waypoints.

    Args:
        points: List of (x, y) coordinates to connect
        net: Net name for the path
        layer: Layer for all segments
        orthogonal: If True, convert diagonal segments into L-bends

    Returns:
        Path object with segments connecting all points
    """
    from .pathfinder import Path, PathSegment

    if len(points) < 2:
        return None

    segments = []
    for i in range(len(points) - 1):
        s = points[i]
        e = points[i + 1]
        dx = abs(e[0] - s[0])
        dy = abs(e[1] - s[1])

        if orthogonal and dx > 0.01 and dy > 0.01:
            # Convert diagonal to L-bend: horizontal then vertical
            corner = (e[0], s[1])
            segments.append(PathSegment(start=s, end=corner, layer=layer))
            segments.append(PathSegment(start=corner, end=e, layer=layer))
        else:
            segments.append(PathSegment(start=s, end=e, layer=layer))

    return Path(segments=segments)


def route_board_with_hints(
    board: Board,
    hints: "RoutingHints",
    internal_nets: dict[str, dict[str, list[str]]] | None = None,
    allow_vias: bool = True,
    single_layer: bool = False,
    order: str = "signals_first",
    trace_width: float = 0.25,
    clearance: float = 0.2,
    grid_resolution: float = 0.1,
    net_widths: Optional[NetWidths] = None,
    keepout_clearance: Optional[float] = None,
    keepout_trace_width: Optional[float] = None,
    existing_traces: Sequence[ExistingSegment] = (),
    existing_vias: Sequence[ExistingVia] = (),
    only_nets: Optional[set] = None,
    net_terminals: Optional[dict] = None,
) -> RoutingResult:
    """
    Route a board using routing hints for guidance.

    This is the preferred entry point for human-AI collaborative routing.
    Buses are routed first using their waypoints, then remaining nets
    are routed with the standard algorithm.

    Args:
        board: Board to route
        hints: RoutingHints with buses, net hints, and global settings
        allow_vias: Whether to allow vias for layer changes
        single_layer: If True, only route on F.Cu
        order: Net ordering strategy for non-bus nets
        trace_width: Default trace width in mm
        clearance: Minimum clearance between traces in mm
        grid_resolution: Grid resolution in mm
        net_widths: per-net class-sourced copper width — see the module note
            above ``route_board``. Threaded to BOTH the standard per-net loop
            below AND ``route_bus`` (net-class round 2): each bus net draws at
            its own width, exactly like a standard net. Only the bus's
            parallel-spacing OFFSET stays shared across the whole bus — that
            is a layout choice, not a per-net requirement (docs/routing.md,
            "Bus routing now honours net-class width").
        keepout_clearance / keepout_trace_width: the grid's OWN (board-wide
            worst-case) clearance/trace_width — see the module note above.
            Grid-wide, not per-net, so it covers every marking regardless of
            which loop drew it (standard, bus, or pad).
        existing_traces / existing_vias: the board's ALREADY-ACCEPTED copper
            (T7, 019f70ebc9ed — see the module note above ``route_board``). It is
            marked on the SAME grid ``route_bus`` and the standard loop both
            draw on, so bus-routed nets see it too.
        only_nets: the run's SCOPE — see the module note above ``_scoped_nets``.
            Applied to the STANDARD net loop only. Buses are AUTHORED input and
            are routed regardless, on the same "admitted or rejected, never
            reinterpreted" rule that keeps the T7 group contraction off
            bridges/chains below; a caller scoping a run must therefore put its
            bus/chain/bridge nets in ``only_nets`` too, which is what
            pcb_worker.methods._route does. Chains and bridges need no separate
            carve-out — they are consumed INSIDE the standard loop, so the
            filter already reaches them.

    Returns:
        RoutingResult with routes and unrouted connections
    """
    from .hints import RoutingHints  # Avoid circular import

    result = RoutingResult()

    # The BOARD's own accepted copper, when the caller named none — see the
    # identical note in ``route_board`` (019f9bc3909c).
    existing_traces = existing_traces or board.existing_traces
    existing_vias = existing_vias or board.existing_vias

    # Create routing grid over the board's OWN extent, anchored at its origin.
    layers = ["F.Cu"] if single_layer else ["F.Cu", "B.Cu"]
    grid_w, grid_h = _grid_extent(board)
    grid = RoutingGrid(
        width=grid_w,
        height=grid_h,
        resolution=grid_resolution,
        clearance=clearance if keepout_clearance is None else keepout_clearance,
        layers=layers,
        origin=board.origin,
        # Round E2: the grid inflates every keepout by `clearance +
        # trace_width / 2`, so it needs the width this run actually routes at.
        # Passing it here (rather than letting RoutingGrid default) is what makes
        # the reserved space and the proposed copper the SAME width — a keepout
        # sized for a narrower trace than the one being laid is an under-block.
        # Net-class minima (this round): board-wide WORST CASE — see the
        # module note above route_board for why this is grid-wide, not per-net.
        trace_width=trace_width if keepout_trace_width is None else keepout_trace_width,
    )

    # Mark all pads on the grid. Margin is the GRID's own (worst-case),
    # uniformly — see the module note above route_board.
    for pad in board.pads:
        if pad.layer in layers:
            pad_layers = [pad.layer]
        elif pad.layer == "*.Cu" or pad.pad_type == "thru_hole":
            # Through-hole pads are accessible on all copper layers
            pad_layers = list(layers)
        else:
            pad_layers = ["F.Cu"]
        for pl in pad_layers:
            grid.mark_pad(
                x=pad.position[0],
                y=pad.position[1],
                size=pad.size,
                net=pad.net,
                layer=pl,
                rotation=pad.rotation
            )

    # The board's OWN accepted copper, between pads and obstacles — see
    # _mark_existing_copper. Marked BEFORE route_bus runs below, so a bus net
    # keeps out of accepted copper exactly as the standard loop does.
    _mark_existing_copper(grid, existing_traces, existing_vias, layers)

    # Mark obstacles — the same disc + keepout-polygon pair the standard loop
    # marks (see the comment there); a bus run keeps out of an authored
    # keepout exactly as a standard run does.
    for obstacle in board.obstacles:
        if obstacle.radius:
            grid.mark_obstacle(
                x=obstacle.position[0],
                y=obstacle.position[1],
                radius=obstacle.radius
            )
        elif obstacle.polygon:
            grid.mark_keepout_polygon(
                obstacle.polygon,
                layer=None if obstacle.blocks_all_layers else obstacle.layer,
            )

    existing_by_net = _existing_copper_by_net(existing_traces, existing_vias)

    # Build bridge lookup: {net_name: InternalBridge}
    bridge_map: dict[str, list] = {}
    for bridge in hints.internal_bridges:
        bridge_map.setdefault(bridge.net, []).append(bridge)

    # Build chain lookup: resolve pad refs and build exclusion sets
    # chain_pad_pairs[net] = [(pad_a, pad_b), ...] sequential connections
    # chain_exclusions[net] = set of (component, pin) to skip in bridge routing
    chain_pad_pairs: dict[str, list[tuple[Pad, Pad]]] = {}
    chain_exclusions: dict[str, set[tuple[str, str]]] = {}
    for chain in hints.chains:
        resolved = _resolve_chain_pads(board, chain)
        if len(resolved) < 2:
            continue
        pairs = [(resolved[i], resolved[i + 1]) for i in range(len(resolved) - 1)]
        chain_pad_pairs.setdefault(chain.net, []).extend(pairs)
        # Exclude all chained pads EXCEPT the first (anchor stays in bridge)
        exclusions = {(p.component, p.number) for p in resolved[1:]}
        chain_exclusions.setdefault(chain.net, set()).update(exclusions)

    # Track which nets have been routed via bus hints
    routed_nets = set()

    # Route buses first (auto-generate waypoints if not provided)
    for bus_hint in hints.buses:
        if not bus_hint.waypoints:
            bus_hint.waypoints = _generate_bus_waypoints(
                board, bus_hint, hints.global_hints.escape_distance
            )
        if bus_hint.waypoints:
            bus_routes = route_bus(
                grid=grid,
                board=board,
                bus_hint=bus_hint,
                trace_width=trace_width,
                layer=bus_hint.preferred_layer or "F.Cu",
                orthogonal=hints.global_hints.prefer_orthogonal,
                net_widths=net_widths,
            )
            result.routes.extend(bus_routes)
            for route in bus_routes:
                routed_nets.add(route.net)

    # Route remaining nets with standard algorithm, narrowed to the run's scope
    # (see the module note above _scoped_nets). Ordering happens first, then the
    # already-bus-routed nets drop out, then the scope filter — all three are
    # pure list narrowing, so the order among them is not load-bearing; what IS
    # load-bearing is that every grid marking above already happened.
    nets_to_route = _scoped_nets(
        [n for n in _order_nets(board, order) if n not in routed_nets], only_nets)

    # Jumper mode: track via budget
    jumper_mode = hints.global_hints.jumper_mode
    max_jumpers = hints.global_hints.max_jumpers
    jumpers_used = result.via_count  # count vias from bus routing

    for net_name in nets_to_route:
        pads = _terminal_pads(board.get_net_pads(net_name), net_name, net_terminals)
        if len(pads) < 2:
            # HITL-4 (docs/llm-ergonomics.md F1): same named answer as
            # route_board's loop — a span ask whose terminals resolved to < 2
            # pads must not vanish (see _skipped_span_outcome).
            outcome = _skipped_span_outcome(net_name, pads, net_terminals)
            if outcome is not None:
                result.span_outcomes.append(outcome)
            continue

        # Check for net-specific hints
        net_hint = hints.get_hint_for_net(net_name)
        preferred_layer = net_hint.preferred_layer if net_hint else "F.Cu"
        avoid_areas = net_hint.avoid_areas if net_hint else None
        preferred_direction = net_hint.preferred_direction if net_hint else None

        # In jumper mode, only allow vias if budget remains
        can_via = allow_vias and not single_layer
        if jumper_mode and jumpers_used >= max_jumpers:
            can_via = False

        net_width = _net_width(net_widths, net_name, trace_width)
        route = Route(net=net_name)
        # F4 (cold review, Epoch UX1 station 9): every DISTINCT constraint
        # revision cited by a guided connection on THIS net — see the
        # route-level assignment after the connections loop below for why
        # this is collected rather than written straight onto `route`.
        route_constraint_revisions: set = set()

        # Use bridge-aware routing if bridge assignments exist
        net_bridges = bridge_map.get(net_name, [])
        net_chain_exclusions = chain_exclusions.get(net_name, set())
        if net_bridges:
            connections = _apply_bridge_assignments(
                pads, net_bridges, board,
                chained_pads=net_chain_exclusions,
                internal_nets=internal_nets,
            )
        else:
            # Same group contraction as route_board (T7, 019f70ebc9ed).
            # Deliberately NOT applied to the bridge branch above, nor to the
            # chains appended below: those are pad pairs the USER authored, and
            # docs/routing.md's standing rule for authored input is "admitted or
            # rejected, never reinterpreted" — dropping one because the board
            # looks already-connected would silently reinterpret an explicit
            # instruction. Only the AUTOMATIC tree is the router's own choice to
            # make.
            connections = _connections_for_net(
                pads, net_name, existing_by_net, grid_resolution)

        # Add chain connections (sequential pad-to-pad)
        net_chains = chain_pad_pairs.get(net_name, [])
        connections.extend(net_chains)

        if not connections:
            # HITL-4 (docs/llm-ergonomics.md F1): the hinted loop's version of
            # route_board's zero-connections answer. Checked AFTER the chain
            # extend, so a net whose only work is user-authored chain pairs is
            # accounted by those pairs routing (or landing in `unrouted`),
            # never by an outcome claiming nothing was needed. The branch that
            # emptied `connections` names the mechanism honestly: the
            # automatic tree's group contraction means already-connected;
            # empty BRIDGE assignments mean the bridge absorbed every pad
            # (unreachable from the worker today — hints_to_router emits no
            # bridges — but a lie is not a fallback, so it gets its own name).
            if net_bridges:
                result.span_outcomes.append({
                    "net": net_name,
                    "status": "bridge_absorbed",
                    "pads": [f"{p.component}.{p.number}" for p in pads],
                })
            else:
                result.span_outcomes.append(_already_connected_outcome(
                    net_name, pads, existing_by_net, grid_resolution))
            continue

        for pad_a, pad_b in connections:
            # AUTHORED CORRIDOR for THIS connection (bug 019fcf152791).
            # Keyed on the pad pair, not the net, so a corridor authored for
            # one span is never applied to another span of the same net — and
            # a second hint on the net is no longer silently lost. The hint's
            # own preferred_layer wins over the net-wide one for this
            # connection (precedence, amendment A4).
            conn_corridor = None
            conn_layer = preferred_layer
            matched = hints.get_hint_for_connection(
                f"{pad_a.component}.{pad_a.number}",
                f"{pad_b.component}.{pad_b.number}")
            if matched is not None:
                conn_hint, reversed_dir = matched
                conn_corridor = _corridor_from_hint(conn_hint, reversed_dir)
                if conn_hint.preferred_layer:
                    conn_layer = conn_hint.preferred_layer

            path = find_path(
                grid=grid,
                start=pad_a.position,
                end=pad_b.position,
                net=net_name,
                layer=conn_layer,
                allow_via=can_via,
                avoid_areas=avoid_areas,
                preferred_direction=preferred_direction,
                prefer_orthogonal=hints.global_hints.prefer_orthogonal,
                corridor=conn_corridor,
            )

            # Grade the result against what was asked for, with the SAME exact
            # geometry the planner priced (amendment A7) — so "followed" and
            # "reported as followed" cannot disagree. Rides the route so the
            # bridge can attach it per hint.
            if path and conn_corridor:
                adherence = measure_adherence(
                    _path_points(path), conn_corridor,
                    pad_a.position, pad_b.position)
                entry = adherence.to_dict()
                entry["hint_id"] = conn_hint.hint_id
                entry["endpoints"] = [f"{pad_a.component}.{pad_a.number}",
                                      f"{pad_b.component}.{pad_b.number}"]
                # Station 9: cite the task constraint revision that produced
                # THIS corridor, when one did (None for legacy inline hint
                # waypoints — see ConnectionHint.constraint_revision's doc).
                # F4: collected into the per-net set, NOT written straight
                # onto `route` — see the route-level assignment below.
                if conn_hint.constraint_revision is not None:
                    entry["constraint_revision"] = conn_hint.constraint_revision
                    route_constraint_revisions.add(conn_hint.constraint_revision)
                route.corridor_adherence.append(entry)

            if path:
                route.paths.append(path)
                route.vias.extend(path.vias)
                new_vias = len(path.vias)
                result.via_count += new_vias
                jumpers_used += new_vias

                # Re-check budget after this path
                if jumper_mode and jumpers_used >= max_jumpers:
                    can_via = False

                # True copper width only (THIS net's own — net-class or
                # baseline) — the grid owns the keepout margin, sized to the
                # board-wide worst case (see the note in route_board; Round E2
                # and this round).
                for segment in path.segments:
                    grid.mark_trace(
                        start=segment.start,
                        end=segment.end,
                        width=net_width,
                        net=net_name,
                        layer=segment.layer
                    )
            else:
                result.unrouted.append((net_name, pad_a, pad_b))
                result.unrouted_reasons.append(_unrouted_reason_entry(
                    grid, net_name, pad_a, pad_b, preferred_layer))

        if route.paths:
            # F4 (cold review, Epoch UX1 station 9): the route-level key is a
            # CONVENIENCE for the single-constraint-per-net common case, not
            # a second source of truth — corridor_adherence's per-entry
            # `constraint_revision` (collected above, one per guided
            # connection) is what's authoritative. When two guided
            # connections on ONE net cite DIFFERENT revisions (two
            # separately-steered spans sharing a net), there is no single
            # truthful answer a route-level key could give; the old
            # last-write-wins behaviour picked whichever connection happened
            # to route last, silently wrong for every such net. Set the key
            # ONLY when every guided connection on this net agreed; omit it
            # otherwise so a caller reads the per-adherence-entry values
            # instead of a route-level lie.
            if len(route_constraint_revisions) == 1:
                route.constraint_revision = next(iter(route_constraint_revisions))
            result.routes.append(route)

    result.success = len(result.unrouted) == 0
    return result
