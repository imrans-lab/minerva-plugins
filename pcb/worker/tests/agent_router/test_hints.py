"""
Tests for routing hints module.
"""

import pytest
import tempfile
from pathlib import Path

from agent_router.hints import (
    RoutingHints, BusHint, NetHint, GlobalHints, Waypoint, AvoidArea,
    load_hints, save_hints, parse_hints
)


class TestWaypoint:
    """Tests for Waypoint class."""

    def test_waypoint_from_list(self):
        """Create waypoint from coordinate list."""
        wp = Waypoint.from_list([10.5, 20.5])
        assert wp.x == 10.5
        assert wp.y == 20.5

    def test_waypoint_from_list_converts_to_float(self):
        """Waypoint coordinates are converted to float."""
        wp = Waypoint.from_list([10, 20])
        assert isinstance(wp.x, float)
        assert isinstance(wp.y, float)


class TestAvoidArea:
    """Tests for AvoidArea class."""

    def test_avoid_area_from_list(self):
        """Create avoid area from coordinate list."""
        area = AvoidArea.from_list([10, 20, 30, 40])
        assert area.x1 == 10.0
        assert area.y1 == 20.0
        assert area.x2 == 30.0
        assert area.y2 == 40.0

    def test_contains_inside(self):
        """Point inside area returns True."""
        area = AvoidArea(10, 20, 30, 40)
        assert area.contains(20, 30) == True

    def test_contains_outside(self):
        """Point outside area returns False."""
        area = AvoidArea(10, 20, 30, 40)
        assert area.contains(5, 30) == False
        assert area.contains(35, 30) == False

    def test_contains_on_edge(self):
        """Point on edge is inside."""
        area = AvoidArea(10, 20, 30, 40)
        assert area.contains(10, 30) == True
        assert area.contains(30, 30) == True


class TestRoutingHints:
    """Tests for RoutingHints class."""

    def test_get_bus_for_net(self):
        """Get bus that contains a net."""
        hints = RoutingHints()
        hints.buses = [
            BusHint("I2C", ["I2C_SDA", "I2C_SCL"]),
            BusHint("SPI", ["SPI_MOSI", "SPI_MISO", "SPI_CLK"]),
        ]

        bus = hints.get_bus_for_net("I2C_SDA")
        assert bus is not None
        assert bus.name == "I2C"

    def test_get_bus_for_net_not_found(self):
        """Return None for net not in any bus."""
        hints = RoutingHints()
        hints.buses = [BusHint("I2C", ["I2C_SDA", "I2C_SCL"])]

        assert hints.get_bus_for_net("UART_TX") is None

    def test_get_hint_for_net(self):
        """Get hint for a specific net."""
        hints = RoutingHints()
        hints.net_hints = [
            NetHint("VCC"),
            NetHint("GND", preferred_direction="down_first"),
        ]

        hint = hints.get_hint_for_net("GND")
        assert hint is not None
        assert hint.preferred_direction == "down_first"

    def test_is_in_avoid_area(self):
        """Check if point should be avoided for a net."""
        hints = RoutingHints()
        hints.net_hints = [
            NetHint("SIGNAL", avoid_areas=[AvoidArea(10, 10, 20, 20)]),
        ]

        assert hints.is_in_avoid_area("SIGNAL", 15, 15) == True
        assert hints.is_in_avoid_area("SIGNAL", 25, 25) == False
        assert hints.is_in_avoid_area("OTHER", 15, 15) == False


class TestParseHints:
    """Tests for parsing hints from dict (YAML)."""

    def test_parse_empty(self):
        """Empty data returns default hints."""
        hints = parse_hints({})
        assert len(hints.buses) == 0
        assert len(hints.net_hints) == 0

    def test_parse_buses(self):
        """Parse bus definitions."""
        data = {
            'routing_hints': {
                'buses': [
                    {
                        'name': 'I2S Bus',
                        'nets': ['I2S_SD', 'I2S_WS', 'I2S_SCK'],
                        'spacing': 0.5,
                        'waypoints': [[76, 60], [76, 95]]
                    }
                ]
            }
        }

        hints = parse_hints(data)
        assert len(hints.buses) == 1
        bus = hints.buses[0]
        assert bus.name == "I2S Bus"
        assert bus.nets == ['I2S_SD', 'I2S_WS', 'I2S_SCK']
        assert bus.spacing == 0.5
        assert len(bus.waypoints) == 2
        assert bus.waypoints[0].x == 76
        assert bus.waypoints[0].y == 60

    def test_parse_net_hints(self):
        """Parse net-specific hints."""
        data = {
            'routing_hints': {
                'net_hints': [
                    {
                        'net': 'BTN4',
                        'avoid_areas': [[80, 75, 95, 90]],
                        'preferred_direction': 'down_first'
                    }
                ]
            }
        }

        hints = parse_hints(data)
        assert len(hints.net_hints) == 1
        nh = hints.net_hints[0]
        assert nh.net == "BTN4"
        assert nh.preferred_direction == "down_first"
        assert len(nh.avoid_areas) == 1

    def test_parse_global_hints(self):
        """Parse global routing preferences."""
        data = {
            'routing_hints': {
                'global': {
                    'prefer_orthogonal': False,
                    'escape_distance': 5.0,
                    'default_spacing': 0.8
                }
            }
        }

        hints = parse_hints(data)
        assert hints.global_hints.prefer_orthogonal == False
        assert hints.global_hints.escape_distance == 5.0
        assert hints.global_hints.default_spacing == 0.8


class TestLoadSaveHints:
    """Tests for loading and saving hints to YAML files."""

    def test_load_nonexistent_file(self):
        """Loading nonexistent file returns empty hints."""
        hints = load_hints("/nonexistent/path/hints.yaml")
        assert len(hints.buses) == 0
        assert len(hints.net_hints) == 0

    def test_save_and_load_roundtrip(self):
        """Saved hints can be loaded back."""
        original = RoutingHints()
        original.buses = [
            BusHint("I2C", ["I2C_SDA", "I2C_SCL"], spacing=0.5,
                   waypoints=[Waypoint(10, 20), Waypoint(30, 40)])
        ]
        original.net_hints = [
            NetHint("VCC", avoid_areas=[AvoidArea(0, 0, 10, 10)])
        ]
        original.global_hints = GlobalHints(
            prefer_orthogonal=False,
            escape_distance=4.0
        )

        with tempfile.NamedTemporaryFile(suffix=".yaml", delete=False) as f:
            save_hints(original, f.name)
            loaded = load_hints(f.name)

        # Check buses
        assert len(loaded.buses) == 1
        assert loaded.buses[0].name == "I2C"
        assert loaded.buses[0].nets == ["I2C_SDA", "I2C_SCL"]
        assert len(loaded.buses[0].waypoints) == 2

        # Check net hints
        assert len(loaded.net_hints) == 1
        assert loaded.net_hints[0].net == "VCC"

        # Check global hints
        assert loaded.global_hints.prefer_orthogonal == False
        assert loaded.global_hints.escape_distance == 4.0
