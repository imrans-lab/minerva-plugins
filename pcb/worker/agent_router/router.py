"""
Main routing orchestration.

Coordinates routing of all nets on a board, handling net ordering,
minimum spanning tree for multi-pad nets, and tracking results.

Implements the "Design Partner" philosophy: routing friction is design
feedback. The design_review() function should be called before routing
to identify potential issues and prompt design-level thinking.
"""

from dataclasses import dataclass, field
from typing import Optional
from collections import defaultdict
import math
import re

from .board import Board, Pad
from .grid import RoutingGrid
from .pathfinder import find_path, Path


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
    via_count: int = 0

    def get_route(self, net_name: str) -> Optional[Route]:
        """Get the route for a specific net."""
        for route in self.routes:
            if route.net == net_name:
                return route
        return None


def route_board(
    board: Board,
    allow_vias: bool = True,
    single_layer: bool = False,
    order: str = "shortest_first",
    trace_width: float = 0.25,
    clearance: float = 0.2,
    grid_resolution: float = 0.1
) -> RoutingResult:
    """
    Route all nets on a board.

    Args:
        board: Board to route
        allow_vias: Whether to allow vias for layer changes
        single_layer: If True, only route on F.Cu
        order: Net ordering strategy ("shortest_first", "longest_first")
        trace_width: Default trace width in mm
        clearance: Minimum clearance between traces in mm
        grid_resolution: Grid resolution in mm

    Returns:
        RoutingResult with routes and unrouted connections
    """
    result = RoutingResult()

    # Create routing grid – expand to cover all pad positions
    layers = ["F.Cu"] if single_layer else ["F.Cu", "B.Cu"]
    grid_w, grid_h = _effective_grid_size(board)
    grid = RoutingGrid(
        width=grid_w,
        height=grid_h,
        resolution=grid_resolution,
        clearance=clearance,
        layers=layers
    )

    # Mark all pads on the grid
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

    # Mark obstacles
    for obstacle in board.obstacles:
        if obstacle.radius:
            grid.mark_obstacle(
                x=obstacle.position[0],
                y=obstacle.position[1],
                radius=obstacle.radius
            )

    # Get ordered list of nets to route
    nets_to_route = _order_nets(board, order)

    # Route each net
    for net_name in nets_to_route:
        pads = board.get_net_pads(net_name)
        if len(pads) < 2:
            continue  # Skip nets with less than 2 pads

        route = Route(net=net_name)

        # Build minimum spanning tree for multi-pad nets
        connections = _build_spanning_tree(pads)

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

                # Mark the path on the grid (include clearance to prevent crossovers)
                for segment in path.segments:
                    grid.mark_trace(
                        start=segment.start,
                        end=segment.end,
                        width=trace_width + 2 * clearance,
                        net=net_name,
                        layer=segment.layer
                    )
            else:
                result.unrouted.append((net_name, pad_a, pad_b))

        if route.paths:
            result.routes.append(route)

    result.success = len(result.unrouted) == 0
    return result


# Patterns that identify power/ground nets (matched case-insensitively)
_POWER_NET_PATTERNS = re.compile(
    r'^(VCC|VDD|GND|VBUS|VSYS|3V3|5V|12V|PWR|AGND|DGND|V\d)',
    re.IGNORECASE,
)


def _is_power_net(net_name: str) -> bool:
    """Return True if *net_name* looks like a power or ground rail."""
    return bool(_POWER_NET_PATTERNS.search(net_name))


def _effective_grid_size(board: Board) -> tuple[float, float]:
    """Return grid dimensions that cover the board outline and all pad positions."""
    w, h = board.width, board.height
    margin = 2.0  # mm extra beyond outermost pad
    for pad in board.pads:
        x, y = pad.position
        half_w = max(pad.size) / 2 if pad.size else 0
        w = max(w, x + half_w + margin)
        h = max(h, y + half_w + margin)
    return w, h


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


def _build_spanning_tree(pads: list[Pad]) -> list[tuple[Pad, Pad]]:
    """
    Build minimum spanning tree for connecting pads.

    Uses Prim's algorithm seeded from the most peripheral pad (farthest
    from centroid) to produce chain-like topologies instead of star
    patterns radiating from a central component.

    Args:
        pads: List of pads to connect

    Returns:
        List of (pad1, pad2) connections forming the MST
    """
    if len(pads) < 2:
        return []

    if len(pads) == 2:
        return [(pads[0], pads[1])]

    # Seed from the most peripheral pad (farthest from centroid)
    cx = sum(p.position[0] for p in pads) / len(pads)
    cy = sum(p.position[1] for p in pads) / len(pads)
    seed = max(range(len(pads)), key=lambda i: (
        (pads[i].position[0] - cx) ** 2 + (pads[i].position[1] - cy) ** 2
    ))

    # Prim's algorithm using indices (Pad is not hashable)
    connections = []
    in_tree_indices = {seed}
    not_in_tree_indices = set(range(len(pads))) - {seed}

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

        if best_edge:
            connections.append((pads[best_edge[0]], pads[best_edge[1]]))
            in_tree_indices.add(best_edge[1])
            not_in_tree_indices.remove(best_edge[1])

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
        trace_width: Width of each trace
        layer: Layer to route on

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
                grid.mark_trace(
                    start=segment.start,
                    end=segment.end,
                    width=trace_width + 2 * grid.clearance,
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
    grid_resolution: float = 0.1
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

    Returns:
        RoutingResult with routes and unrouted connections
    """
    from .hints import RoutingHints  # Avoid circular import

    result = RoutingResult()

    # Create routing grid – expand to cover all pad positions
    layers = ["F.Cu"] if single_layer else ["F.Cu", "B.Cu"]
    grid_w, grid_h = _effective_grid_size(board)
    grid = RoutingGrid(
        width=grid_w,
        height=grid_h,
        resolution=grid_resolution,
        clearance=clearance,
        layers=layers
    )

    # Mark all pads on the grid
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

    # Mark obstacles
    for obstacle in board.obstacles:
        if obstacle.radius:
            grid.mark_obstacle(
                x=obstacle.position[0],
                y=obstacle.position[1],
                radius=obstacle.radius
            )

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
            )
            result.routes.extend(bus_routes)
            for route in bus_routes:
                routed_nets.add(route.net)

    # Route remaining nets with standard algorithm
    nets_to_route = [n for n in _order_nets(board, order) if n not in routed_nets]

    # Jumper mode: track via budget
    jumper_mode = hints.global_hints.jumper_mode
    max_jumpers = hints.global_hints.max_jumpers
    jumpers_used = result.via_count  # count vias from bus routing

    for net_name in nets_to_route:
        pads = board.get_net_pads(net_name)
        if len(pads) < 2:
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

        route = Route(net=net_name)

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
            connections = _build_spanning_tree(pads)

        # Add chain connections (sequential pad-to-pad)
        net_chains = chain_pad_pairs.get(net_name, [])
        connections.extend(net_chains)

        for pad_a, pad_b in connections:
            path = find_path(
                grid=grid,
                start=pad_a.position,
                end=pad_b.position,
                net=net_name,
                layer=preferred_layer,
                allow_via=can_via,
                avoid_areas=avoid_areas,
                preferred_direction=preferred_direction,
                prefer_orthogonal=hints.global_hints.prefer_orthogonal,
            )

            if path:
                route.paths.append(path)
                route.vias.extend(path.vias)
                new_vias = len(path.vias)
                result.via_count += new_vias
                jumpers_used += new_vias

                # Re-check budget after this path
                if jumper_mode and jumpers_used >= max_jumpers:
                    can_via = False

                # Mark with clearance to prevent crossovers
                for segment in path.segments:
                    grid.mark_trace(
                        start=segment.start,
                        end=segment.end,
                        width=trace_width + 2 * clearance,
                        net=net_name,
                        layer=segment.layer
                    )
            else:
                result.unrouted.append((net_name, pad_a, pad_b))

        if route.paths:
            result.routes.append(route)

    result.success = len(result.unrouted) == 0
    return result
