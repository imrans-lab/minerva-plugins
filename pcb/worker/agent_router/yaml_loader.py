"""
YAML board loader for agent-router.

Loads board geometry from .kicad_pcb (accurate pad positions) while
reading routing hints and internal_nets from the board YAML file.
This combines the best of both worlds: precise physical geometry from
KiCad with human-authored routing guidance from the YAML.
"""

from pathlib import Path
from typing import Optional

from .board import Board
from .hints import (
    RoutingHints, BusHint, NetHint, Waypoint, AvoidArea,
    GlobalHints, InternalBridge, ChainHint,
)


def load_board_with_hints(
    kicad_pcb_path: str | Path,
    board_yaml_path: str | Path,
) -> tuple[Board, RoutingHints, dict[str, dict[str, list[str]]]]:
    """Load board geometry from KiCad PCB and hints from board YAML.

    Args:
        kicad_pcb_path: Path to .kicad_pcb file (source of pad positions)
        board_yaml_path: Path to board YAML (source of routing_hints and
            internal_nets)

    Returns:
        Tuple of:
        - Board: with accurate pad positions from .kicad_pcb
        - RoutingHints: parsed from YAML routing_hints section
        - internal_nets_dict: {component_id: {net_name: [pad_numbers]}}
    """
    import yaml

    # Board geometry from KiCad (accurate pad positions)
    board = Board.from_kicad(str(kicad_pcb_path))

    # Parse the YAML for hints and internal_nets
    yaml_path = Path(board_yaml_path)
    if not yaml_path.exists():
        return board, RoutingHints(), {}

    with open(yaml_path) as f:
        data = yaml.safe_load(f)

    # Extract internal_nets from components
    internal_nets_dict: dict[str, dict[str, list[str]]] = {}
    for comp_data in data.get("components", []):
        comp_id = comp_data.get("id", "")
        inets = comp_data.get("internal_nets", {})
        if inets:
            internal_nets_dict[comp_id] = {
                str(k): [str(p) for p in v] for k, v in inets.items()
            }

    # Extract routing_hints
    hints = _parse_routing_hints(data.get("routing_hints", {}))

    return board, hints, internal_nets_dict


def _parse_routing_hints(rh_data: Optional[dict]) -> RoutingHints:
    """Parse the routing_hints section from board YAML into RoutingHints."""
    if not rh_data:
        return RoutingHints()

    hints = RoutingHints()

    # Buses
    for bus_data in rh_data.get("buses", []):
        waypoints = [
            Waypoint.from_list(w) for w in bus_data.get("waypoints", [])
        ]
        hints.buses.append(BusHint(
            name=bus_data.get("name", "unnamed"),
            nets=bus_data.get("nets", []),
            spacing=float(bus_data.get("spacing", 0.5)),
            waypoints=waypoints,
            preferred_layer=bus_data.get("preferred_layer"),
        ))

    # Net hints
    for nh_data in rh_data.get("net_hints", []):
        waypoints = [
            Waypoint.from_list(w) for w in nh_data.get("waypoints", [])
        ]
        avoid_areas = [
            AvoidArea.from_list(a) for a in nh_data.get("avoid_areas", [])
        ]
        hints.net_hints.append(NetHint(
            net=nh_data.get("net", ""),
            waypoints=waypoints,
            avoid_areas=avoid_areas,
            preferred_direction=nh_data.get("preferred_direction"),
            preferred_layer=nh_data.get("preferred_layer"),
        ))

    # Chains
    for chain_data in rh_data.get("chains", []):
        hints.chains.append(ChainHint(
            net=chain_data.get("net", ""),
            pads=chain_data.get("pads", []),
        ))

    # Internal bridges
    for bridge_data in rh_data.get("internal_bridges", []):
        pa = {}
        for pin, comps in bridge_data.get("pin_assignments", {}).items():
            pa[str(pin)] = [str(c) for c in comps]
        hints.internal_bridges.append(InternalBridge(
            component=bridge_data.get("component", ""),
            net=bridge_data.get("net", ""),
            pin_assignments=pa,
        ))

    # Global hints
    g = rh_data.get("global", {})
    hints.global_hints = GlobalHints(
        prefer_orthogonal=g.get("prefer_orthogonal", True),
        escape_distance=float(g.get("escape_distance", 3.0)),
        default_spacing=float(g.get("default_spacing", 0.5)),
        jumper_mode=g.get("jumper_mode", False),
        max_jumpers=int(g.get("max_jumpers", 3)),
    )

    return hints
