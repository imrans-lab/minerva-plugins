"""
Routing hints for human-AI collaborative routing.

Allows users to provide routing guidance via YAML, including:
- Waypoints for traces or buses
- Preferred routing directions
- Areas to avoid
- Explicit bus groupings

Example YAML:
```yaml
routing_hints:
  buses:
    - name: I2S
      nets: [I2S_SD, I2S_WS, I2S_SCK]
      spacing: 0.5
      waypoints:
        - [76, 60]   # Exit point from ESP32
        - [76, 95]   # Turn point before MIC

  net_hints:
    - net: BTN4
      avoid_areas:
        - [80, 75, 95, 90]  # [x1, y1, x2, y2] rectangle
      preferred_direction: down_first

  global:
    prefer_orthogonal: true
    escape_distance: 3.0  # mm to escape from dense components
```
"""

from dataclasses import dataclass, field
from typing import Optional
from pathlib import Path
import yaml


@dataclass
class Waypoint:
    """A point that a trace or bus should pass through."""
    x: float
    y: float

    @classmethod
    def from_list(cls, coords: list) -> "Waypoint":
        return cls(x=float(coords[0]), y=float(coords[1]))


@dataclass
class AvoidArea:
    """A rectangular area to avoid when routing."""
    x1: float
    y1: float
    x2: float
    y2: float

    @classmethod
    def from_list(cls, coords: list) -> "AvoidArea":
        return cls(
            x1=float(coords[0]),
            y1=float(coords[1]),
            x2=float(coords[2]),
            y2=float(coords[3])
        )

    def contains(self, x: float, y: float) -> bool:
        """Check if a point is inside this avoid area."""
        return (self.x1 <= x <= self.x2 and self.y1 <= y <= self.y2)


@dataclass
class BusHint:
    """Hints for routing a group of signals as a bus."""
    name: str
    nets: list[str]
    spacing: float = 0.5  # mm between traces
    waypoints: list[Waypoint] = field(default_factory=list)
    preferred_layer: Optional[str] = None


@dataclass
class NetHint:
    """Hints for routing a specific net."""
    net: str
    waypoints: list[Waypoint] = field(default_factory=list)
    avoid_areas: list[AvoidArea] = field(default_factory=list)
    preferred_direction: Optional[str] = None  # "right_first", "down_first", etc.
    preferred_layer: Optional[str] = None


@dataclass
class InternalBridge:
    """Maps a component's internal-net pin to external connections.

    When an IC has multiple GND pads connected internally, the router can
    choose which external components connect to which pin, reducing total
    trace length. ``pin_assignments`` maps pad numbers to lists of
    external component IDs that should connect through that pin.
    """
    component: str  # e.g. "U1"
    net: str  # e.g. "GND"
    pin_assignments: dict[str, list[str]] = field(default_factory=dict)
    # e.g. {"22": ["BAT1"], "44": ["SW1", "SW2"]}


@dataclass
class ChainHint:
    """Route pads sequentially in the given order (daisy-chain).

    Instead of routing all pads back to a bridge pin, connect them
    pad-to-pad in the listed order.  The first pad should already be
    reachable via a bridge assignment or earlier routing.

    ``pads`` uses ``Component.Pin`` notation, e.g. ``["SW1.B", "SW3.B", "SW2.B"]``.
    """
    net: str
    pads: list[str]  # ["SW1.B", "SW3.B", "SW2.B"]


@dataclass
class GlobalHints:
    """Global routing preferences."""
    prefer_orthogonal: bool = True  # Prefer 90° angles over 45°
    escape_distance: float = 3.0  # mm to escape from dense components
    default_spacing: float = 0.5  # mm between bus traces
    jumper_mode: bool = False  # Treat vias as jumper wires (hand-solderable)
    max_jumpers: int = 3  # Budget for number of jumpers when jumper_mode=True


@dataclass
class RoutingHints:
    """Complete set of routing hints."""
    buses: list[BusHint] = field(default_factory=list)
    net_hints: list[NetHint] = field(default_factory=list)
    global_hints: GlobalHints = field(default_factory=GlobalHints)
    internal_bridges: list[InternalBridge] = field(default_factory=list)
    chains: list[ChainHint] = field(default_factory=list)

    def get_bus_for_net(self, net_name: str) -> Optional[BusHint]:
        """Get the bus hint that includes a specific net."""
        for bus in self.buses:
            if net_name in bus.nets:
                return bus
        return None

    def get_hint_for_net(self, net_name: str) -> Optional[NetHint]:
        """Get specific hints for a net."""
        for hint in self.net_hints:
            if hint.net == net_name:
                return hint
        return None

    def is_in_avoid_area(self, net_name: str, x: float, y: float) -> bool:
        """Check if a point should be avoided for a specific net."""
        hint = self.get_hint_for_net(net_name)
        if hint:
            for area in hint.avoid_areas:
                if area.contains(x, y):
                    return True
        return False


def load_hints(yaml_path: str | Path) -> RoutingHints:
    """
    Load routing hints from a YAML file.

    Args:
        yaml_path: Path to YAML file with routing hints

    Returns:
        RoutingHints object
    """
    path = Path(yaml_path)
    if not path.exists():
        return RoutingHints()

    with open(path) as f:
        data = yaml.safe_load(f)

    return parse_hints(data)


def parse_hints(data: dict) -> RoutingHints:
    """
    Parse routing hints from a dictionary (e.g., loaded from YAML).

    Accepts either the full YAML dict (with ``routing_hints`` key) or the
    inner routing_hints dict directly.

    Args:
        data: Dictionary with routing hints

    Returns:
        RoutingHints object
    """
    if not data:
        return RoutingHints()

    # Accept both {'routing_hints': {...}} and the inner dict directly
    if 'routing_hints' in data:
        hints_data = data['routing_hints']
    elif any(k in data for k in ('buses', 'net_hints', 'global', 'internal_bridges', 'chains')):
        hints_data = data
    else:
        return RoutingHints()
    hints = RoutingHints()

    # Parse buses
    if 'buses' in hints_data:
        for bus_data in hints_data['buses']:
            waypoints = []
            if 'waypoints' in bus_data:
                waypoints = [Waypoint.from_list(w) for w in bus_data['waypoints']]

            bus = BusHint(
                name=bus_data.get('name', 'unnamed'),
                nets=bus_data.get('nets', []),
                spacing=float(bus_data.get('spacing', 0.5)),
                waypoints=waypoints,
                preferred_layer=bus_data.get('preferred_layer')
            )
            hints.buses.append(bus)

    # Parse net hints
    if 'net_hints' in hints_data:
        for net_data in hints_data['net_hints']:
            waypoints = []
            if 'waypoints' in net_data:
                waypoints = [Waypoint.from_list(w) for w in net_data['waypoints']]

            avoid_areas = []
            if 'avoid_areas' in net_data:
                avoid_areas = [AvoidArea.from_list(a) for a in net_data['avoid_areas']]

            hint = NetHint(
                net=net_data.get('net', ''),
                waypoints=waypoints,
                avoid_areas=avoid_areas,
                preferred_direction=net_data.get('preferred_direction'),
                preferred_layer=net_data.get('preferred_layer')
            )
            hints.net_hints.append(hint)

    # Parse global hints
    if 'global' in hints_data:
        global_data = hints_data['global']
        hints.global_hints = GlobalHints(
            prefer_orthogonal=global_data.get('prefer_orthogonal', True),
            escape_distance=float(global_data.get('escape_distance', 3.0)),
            default_spacing=float(global_data.get('default_spacing', 0.5)),
            jumper_mode=global_data.get('jumper_mode', False),
            max_jumpers=int(global_data.get('max_jumpers', 3)),
        )

    # Parse chains
    if 'chains' in hints_data:
        for chain_data in hints_data['chains']:
            chain = ChainHint(
                net=chain_data.get('net', ''),
                pads=chain_data.get('pads', []),
            )
            hints.chains.append(chain)

    # Parse internal bridges
    if 'internal_bridges' in hints_data:
        for bridge_data in hints_data['internal_bridges']:
            pa = {}
            for pin, comps in bridge_data.get('pin_assignments', {}).items():
                pa[str(pin)] = [str(c) for c in comps]
            bridge = InternalBridge(
                component=bridge_data.get('component', ''),
                net=bridge_data.get('net', ''),
                pin_assignments=pa,
            )
            hints.internal_bridges.append(bridge)

    return hints


def save_hints(hints: RoutingHints, yaml_path: str | Path) -> None:
    """
    Save routing hints to a YAML file.

    Args:
        hints: RoutingHints to save
        yaml_path: Path to save YAML file
    """
    data = {'routing_hints': {}}

    # Save buses
    if hints.buses:
        data['routing_hints']['buses'] = []
        for bus in hints.buses:
            bus_data = {
                'name': bus.name,
                'nets': bus.nets,
                'spacing': bus.spacing,
            }
            if bus.waypoints:
                bus_data['waypoints'] = [[w.x, w.y] for w in bus.waypoints]
            if bus.preferred_layer:
                bus_data['preferred_layer'] = bus.preferred_layer
            data['routing_hints']['buses'].append(bus_data)

    # Save net hints
    if hints.net_hints:
        data['routing_hints']['net_hints'] = []
        for hint in hints.net_hints:
            hint_data = {'net': hint.net}
            if hint.waypoints:
                hint_data['waypoints'] = [[w.x, w.y] for w in hint.waypoints]
            if hint.avoid_areas:
                hint_data['avoid_areas'] = [[a.x1, a.y1, a.x2, a.y2] for a in hint.avoid_areas]
            if hint.preferred_direction:
                hint_data['preferred_direction'] = hint.preferred_direction
            if hint.preferred_layer:
                hint_data['preferred_layer'] = hint.preferred_layer
            data['routing_hints']['net_hints'].append(hint_data)

    # Save chains
    if hints.chains:
        data['routing_hints']['chains'] = []
        for chain in hints.chains:
            data['routing_hints']['chains'].append({
                'net': chain.net,
                'pads': chain.pads,
            })

    # Save internal bridges
    if hints.internal_bridges:
        data['routing_hints']['internal_bridges'] = []
        for bridge in hints.internal_bridges:
            bridge_data = {
                'component': bridge.component,
                'net': bridge.net,
            }
            if bridge.pin_assignments:
                bridge_data['pin_assignments'] = bridge.pin_assignments
            data['routing_hints']['internal_bridges'].append(bridge_data)

    # Save global hints
    data['routing_hints']['global'] = {
        'prefer_orthogonal': hints.global_hints.prefer_orthogonal,
        'escape_distance': hints.global_hints.escape_distance,
        'default_spacing': hints.global_hints.default_spacing,
        'jumper_mode': hints.global_hints.jumper_mode,
        'max_jumpers': hints.global_hints.max_jumpers,
    }

    path = Path(yaml_path)
    with open(path, 'w') as f:
        yaml.dump(data, f, default_flow_style=False, sort_keys=False)


def generate_hints_from_review(review: "DesignReview") -> RoutingHints:
    """
    Generate initial routing hints from a design review.

    This creates a starting point that humans can modify.

    Args:
        review: DesignReview from design_review()

    Returns:
        RoutingHints with suggested bus groupings
    """
    from .router import DesignReview  # Avoid circular import

    hints = RoutingHints()

    # Create bus hints from detected bus groups
    for bus_group in review.bus_groups:
        bus = BusHint(
            name=bus_group.name,
            nets=bus_group.nets,
            spacing=0.5,
            waypoints=[]  # Human fills these in
        )
        hints.buses.append(bus)

    return hints
