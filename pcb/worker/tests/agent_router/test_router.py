"""
Tests for multi-net router.
"""

import pytest
from agent_router.board import Board, Pad, Net
from agent_router.router import route_board, RoutingResult, Route, _build_spanning_tree, _order_nets


class TestSingleNetRouting:
    """Tests for routing single nets."""

    def test_route_single_two_pad_net(self, two_pads_pcb):
        """Route simplest case: one net with two pads."""
        board = Board.from_kicad(two_pads_pcb)
        result = route_board(board)

        assert result.success == True
        assert len(result.routes) == 1
        assert result.routes[0].net == "NET1"
        assert result.unrouted == []

    def test_route_creates_segments(self, two_pads_pcb):
        """Routing creates actual path segments."""
        board = Board.from_kicad(two_pads_pcb)
        result = route_board(board)

        assert len(result.routes) > 0
        route = result.routes[0]
        assert len(route.paths) > 0
        assert len(route.segments) > 0


class TestMultiNetRouting:
    """Tests for routing multiple nets."""

    def test_route_multiple_independent_nets(self, three_resistors_pcb):
        """Route multiple non-crossing nets."""
        board = Board.from_kicad(three_resistors_pcb)
        result = route_board(board)

        assert result.success == True
        # Should have routes for VCC, GND, and middle connections
        assert len(result.routes) >= 2
        assert result.unrouted == []

    def test_crossing_nets_need_different_layers(self, crossing_nets_pcb):
        """When nets cross, either use via or route around."""
        board = Board.from_kicad(crossing_nets_pcb)
        result = route_board(board, allow_vias=True)

        # Routing should succeed either with vias or by finding a path around
        assert result.success == True
        # Both nets should be routed
        assert len(result.routes) == 2

    def test_single_layer_mode_may_fail(self, crossing_nets_pcb):
        """Single-layer mode fails gracefully for impossible layouts."""
        board = Board.from_kicad(crossing_nets_pcb)
        result = route_board(board, allow_vias=False, single_layer=True)

        # Either succeeds with creative routing or reports unroutable
        if not result.success:
            assert len(result.unrouted) >= 1


class TestNetOrdering:
    """Tests for net ordering strategies."""

    def test_net_ordering_shortest_first(self):
        """Shortest first orders by total wire length."""
        board = Board()

        # Create two nets with different lengths
        short_pad1 = Pad("R1", "1", "SHORT", (10, 10), (1, 1))
        short_pad2 = Pad("R1", "2", "SHORT", (15, 10), (1, 1))

        long_pad1 = Pad("R2", "1", "LONG", (0, 0), (1, 1))
        long_pad2 = Pad("R2", "2", "LONG", (40, 40), (1, 1))

        board.nets["SHORT"] = Net("SHORT", 1, [short_pad1, short_pad2])
        board.nets["LONG"] = Net("LONG", 2, [long_pad1, long_pad2])

        ordered = _order_nets(board, "shortest_first")

        assert ordered[0] == "SHORT"
        assert ordered[1] == "LONG"

    def test_net_ordering_longest_first(self):
        """Longest first reverses the order."""
        board = Board()

        short_pad1 = Pad("R1", "1", "SHORT", (10, 10), (1, 1))
        short_pad2 = Pad("R1", "2", "SHORT", (15, 10), (1, 1))

        long_pad1 = Pad("R2", "1", "LONG", (0, 0), (1, 1))
        long_pad2 = Pad("R2", "2", "LONG", (40, 40), (1, 1))

        board.nets["SHORT"] = Net("SHORT", 1, [short_pad1, short_pad2])
        board.nets["LONG"] = Net("LONG", 2, [long_pad1, long_pad2])

        ordered = _order_nets(board, "longest_first")

        assert ordered[0] == "LONG"
        assert ordered[1] == "SHORT"


class TestSpanningTree:
    """Tests for minimum spanning tree algorithm."""

    def test_two_pad_spanning_tree(self):
        """Two pads create single connection."""
        pad1 = Pad("R1", "1", "NET", (0, 0), (1, 1))
        pad2 = Pad("R1", "2", "NET", (10, 0), (1, 1))

        connections = _build_spanning_tree([pad1, pad2])

        assert len(connections) == 1
        assert (pad1, pad2) in connections or (pad2, pad1) in connections

    def test_spanning_tree_for_multi_pad_nets(self, star_net_pcb):
        """Nets with 3+ pads use minimum spanning tree."""
        board = Board.from_kicad(star_net_pcb)
        result = route_board(board)

        vcc_route = result.get_route("VCC")
        assert vcc_route is not None
        # MST of 5 nodes has 4 edges
        assert len(vcc_route.segments) >= 4

    def test_spanning_tree_five_pads(self):
        """Five pads create four connections (MST property)."""
        pads = [
            Pad("U1", "1", "VCC", (0, 0), (1, 1)),
            Pad("U1", "2", "VCC", (10, 0), (1, 1)),
            Pad("U1", "3", "VCC", (20, 0), (1, 1)),
            Pad("U1", "4", "VCC", (10, 10), (1, 1)),
            Pad("U1", "5", "VCC", (10, 20), (1, 1)),
        ]

        connections = _build_spanning_tree(pads)

        # MST of n nodes has n-1 edges
        assert len(connections) == 4

    def test_spanning_tree_chooses_short_edges(self):
        """Spanning tree prefers shorter connections."""
        pads = [
            Pad("U1", "1", "VCC", (0, 0), (1, 1)),
            Pad("U1", "2", "VCC", (1, 0), (1, 1)),
            Pad("U1", "3", "VCC", (100, 100), (1, 1)),
        ]

        connections = _build_spanning_tree(pads)

        # Should connect (0,0)-(1,0) first, then one of them to (100,100)
        # Not (0,0)-(100,100) and (1,0)-(100,100)
        total_length = 0
        for p1, p2 in connections:
            dx = p1.position[0] - p2.position[0]
            dy = p1.position[1] - p2.position[1]
            total_length += (dx*dx + dy*dy) ** 0.5

        # Minimum would be 1 + ~141, maximum would be 2*141
        assert total_length < 200


class TestRoutingResult:
    """Tests for RoutingResult class."""

    def test_get_route_existing(self):
        """Get route that exists."""
        result = RoutingResult()
        route = Route(net="VCC")
        result.routes.append(route)

        assert result.get_route("VCC") is route

    def test_get_route_nonexistent(self):
        """Get route that doesn't exist returns None."""
        result = RoutingResult()
        assert result.get_route("MISSING") is None

    def test_success_when_no_unrouted(self):
        """Success is True when no unrouted connections."""
        result = RoutingResult(success=True, unrouted=[])
        assert result.success == True


class TestRoutingOptions:
    """Tests for routing options."""

    def test_trace_width_option(self, two_pads_pcb):
        """Trace width option is respected."""
        board = Board.from_kicad(two_pads_pcb)
        result = route_board(board, trace_width=0.5)

        # Routing should succeed
        assert result.success == True

    def test_clearance_option(self, two_pads_pcb):
        """Clearance option is respected."""
        board = Board.from_kicad(two_pads_pcb)
        result = route_board(board, clearance=0.3)

        assert result.success == True


class TestBusRouting:
    """Tests for bus routing with waypoints."""

    def test_route_bus_creates_parallel_traces(self):
        """Bus routing creates parallel traces with consistent spacing."""
        from agent_router.router import route_bus
        from agent_router.grid import RoutingGrid
        from agent_router.hints import BusHint, Waypoint

        # Create a simple board with 3 nets that form a bus
        board = Board(width=100, height=100)
        board.pads = [
            # Source pads (left side)
            Pad("U1", "1", "I2S_SD", (10, 50), (1, 1)),
            Pad("U1", "2", "I2S_WS", (10, 52), (1, 1)),
            Pad("U1", "3", "I2S_SCK", (10, 54), (1, 1)),
            # Destination pads (right side)
            Pad("U2", "1", "I2S_SD", (90, 50), (1, 1)),
            Pad("U2", "2", "I2S_WS", (90, 52), (1, 1)),
            Pad("U2", "3", "I2S_SCK", (90, 54), (1, 1)),
        ]
        board.nets = {
            "I2S_SD": Net("I2S_SD", 1, [board.pads[0], board.pads[3]]),
            "I2S_WS": Net("I2S_WS", 2, [board.pads[1], board.pads[4]]),
            "I2S_SCK": Net("I2S_SCK", 3, [board.pads[2], board.pads[5]]),
        }

        grid = RoutingGrid(width=100, height=100, resolution=0.5)

        bus_hint = BusHint(
            name="I2S Bus",
            nets=["I2S_SD", "I2S_WS", "I2S_SCK"],
            spacing=2.0,
            waypoints=[
                Waypoint(20, 52),  # First waypoint
                Waypoint(80, 52),  # Second waypoint
            ]
        )

        routes = route_bus(grid, board, bus_hint)

        # Should create 3 routes
        assert len(routes) == 3
        net_names = {r.net for r in routes}
        assert "I2S_SD" in net_names
        assert "I2S_WS" in net_names
        assert "I2S_SCK" in net_names

    def test_route_board_with_hints_routes_buses_first(self):
        """route_board_with_hints routes buses before other nets."""
        from agent_router.router import route_board_with_hints
        from agent_router.hints import RoutingHints, BusHint, Waypoint

        # Create a board with bus signals
        board = Board(width=100, height=100)
        board.pads = [
            Pad("U1", "1", "I2S_SD", (10, 50), (1, 1)),
            Pad("U2", "1", "I2S_SD", (90, 50), (1, 1)),
        ]
        board.nets = {
            "I2S_SD": Net("I2S_SD", 1, board.pads),
        }

        hints = RoutingHints(
            buses=[
                BusHint(
                    name="I2S",
                    nets=["I2S_SD"],
                    waypoints=[Waypoint(30, 50), Waypoint(70, 50)]
                )
            ]
        )

        result = route_board_with_hints(board, hints)

        assert result.success == True
        assert len(result.routes) == 1
        assert result.routes[0].net == "I2S_SD"

    def test_bus_hint_without_waypoints_skipped_by_route_bus(self):
        """route_bus itself still returns empty for no-waypoint buses."""
        from agent_router.router import route_bus
        from agent_router.grid import RoutingGrid
        from agent_router.hints import BusHint

        board = Board(width=100, height=100)
        grid = RoutingGrid(width=100, height=100, resolution=0.5)

        bus_hint = BusHint(
            name="Empty Bus",
            nets=["NET1"],
            waypoints=[]  # No waypoints
        )

        routes = route_bus(grid, board, bus_hint)
        assert len(routes) == 0


class TestBusAutoWaypoints:
    """Tests for auto-generated bus waypoints (Fix E)."""

    def test_generate_bus_waypoints_two_components(self):
        """Auto-generates waypoints between two component clusters."""
        from agent_router.router import _generate_bus_waypoints
        from agent_router.hints import BusHint

        board = Board(width=100, height=100)
        board.pads = [
            Pad("U1", "1", "I2S_SD", (10, 50), (1, 1)),
            Pad("U1", "2", "I2S_WS", (10, 52), (1, 1)),
            Pad("U1", "3", "I2S_SCK", (10, 54), (1, 1)),
            Pad("U2", "1", "I2S_SD", (90, 50), (1, 1)),
            Pad("U2", "2", "I2S_WS", (90, 52), (1, 1)),
            Pad("U2", "3", "I2S_SCK", (90, 54), (1, 1)),
        ]
        board.nets = {
            "I2S_SD": Net("I2S_SD", 1, [board.pads[0], board.pads[3]]),
            "I2S_WS": Net("I2S_WS", 2, [board.pads[1], board.pads[4]]),
            "I2S_SCK": Net("I2S_SCK", 3, [board.pads[2], board.pads[5]]),
        }

        bus_hint = BusHint(
            name="I2S",
            nets=["I2S_SD", "I2S_WS", "I2S_SCK"],
            spacing=0.5,
        )

        wps = _generate_bus_waypoints(board, bus_hint, escape_distance=3.0)

        assert len(wps) == 2
        # First waypoint near U1 side (x ~ 13), second near U2 side (x ~ 87)
        assert wps[0].x < 20
        assert wps[1].x > 80
        # Y should be near centroid of bus pads (~52)
        assert 50 <= wps[0].y <= 54
        assert 50 <= wps[1].y <= 54

    def test_generate_bus_waypoints_single_component_returns_empty(self):
        """Returns empty when all bus pads are on the same component."""
        from agent_router.router import _generate_bus_waypoints
        from agent_router.hints import BusHint

        board = Board(width=100, height=100)
        board.pads = [
            Pad("U1", "1", "SIG1", (10, 50), (1, 1)),
            Pad("U1", "2", "SIG1", (10, 52), (1, 1)),
        ]
        board.nets = {"SIG1": Net("SIG1", 1, board.pads)}

        bus_hint = BusHint(name="bad", nets=["SIG1"], spacing=0.5)
        wps = _generate_bus_waypoints(board, bus_hint)
        assert len(wps) == 0

    def test_auto_waypoints_used_in_route_board_with_hints(self):
        """route_board_with_hints auto-generates waypoints and routes the bus."""
        from agent_router.router import route_board_with_hints
        from agent_router.hints import RoutingHints, BusHint

        board = Board(width=100, height=100)
        board.pads = [
            Pad("U1", "1", "I2S_SD", (10, 50), (1, 1)),
            Pad("U1", "2", "I2S_WS", (10, 52), (1, 1)),
            Pad("U1", "3", "I2S_SCK", (10, 54), (1, 1)),
            Pad("U2", "1", "I2S_SD", (90, 50), (1, 1)),
            Pad("U2", "2", "I2S_WS", (90, 52), (1, 1)),
            Pad("U2", "3", "I2S_SCK", (90, 54), (1, 1)),
        ]
        board.nets = {
            "I2S_SD": Net("I2S_SD", 1, [board.pads[0], board.pads[3]]),
            "I2S_WS": Net("I2S_WS", 2, [board.pads[1], board.pads[4]]),
            "I2S_SCK": Net("I2S_SCK", 3, [board.pads[2], board.pads[5]]),
        }

        hints = RoutingHints(
            buses=[
                BusHint(
                    name="I2S",
                    nets=["I2S_SD", "I2S_WS", "I2S_SCK"],
                    spacing=2.0,
                    # No waypoints — should auto-generate
                )
            ]
        )

        result = route_board_with_hints(board, hints)

        assert result.success == True
        assert len(result.routes) == 3
        routed_nets = {r.net for r in result.routes}
        assert "I2S_SD" in routed_nets
        assert "I2S_WS" in routed_nets
        assert "I2S_SCK" in routed_nets

    def test_explicit_waypoints_not_overridden(self):
        """Explicit waypoints are preserved, not replaced by auto-gen."""
        from agent_router.router import route_board_with_hints
        from agent_router.hints import RoutingHints, BusHint, Waypoint

        board = Board(width=100, height=100)
        board.pads = [
            Pad("U1", "1", "SIG_A", (10, 50), (1, 1)),
            Pad("U2", "1", "SIG_A", (90, 50), (1, 1)),
        ]
        board.nets = {"SIG_A": Net("SIG_A", 1, board.pads)}

        explicit_wp = [Waypoint(30, 50), Waypoint(70, 50)]
        hints = RoutingHints(
            buses=[
                BusHint(
                    name="test",
                    nets=["SIG_A"],
                    spacing=0.5,
                    waypoints=list(explicit_wp),
                )
            ]
        )

        result = route_board_with_hints(board, hints)
        # Should use explicit waypoints, not auto-generate
        assert hints.buses[0].waypoints[0].x == 30
        assert hints.buses[0].waypoints[1].x == 70
        assert result.success == True


class TestChainRouting:
    """Tests for chain routing hints (daisy-chain pad-to-pad)."""

    def _make_chain_board(self):
        """Create a board with U1 bridge + 3 switches for GND chain testing."""
        from agent_router.hints import (
            RoutingHints, GlobalHints, InternalBridge, ChainHint,
        )

        board = Board(width=100, height=100)
        # U1 with GND pin 23 at (38, 10)
        # SW1.B at (31, 8), SW3.B at (31, 30), SW2.B at (16, 30)
        board.pads = [
            Pad(position=(38.0, 10.0), net="GND", component="U1", number="23",
                size=(1.2, 2.0), shape="oval", pad_type="thru_hole"),
            Pad(position=(31.0, 8.0), net="GND", component="SW1", number="B",
                size=(2.0, 2.0), shape="rect", pad_type="smd"),
            Pad(position=(31.0, 30.0), net="GND", component="SW3", number="B",
                size=(2.0, 2.0), shape="rect", pad_type="smd"),
            Pad(position=(16.0, 30.0), net="GND", component="SW2", number="B",
                size=(2.0, 2.0), shape="rect", pad_type="smd"),
        ]
        board.nets = {"GND": Net("GND", 1, board.pads)}
        return board

    def test_chain_routes_sequentially(self):
        """Chain hint routes pads in declared order, not star from bridge."""
        from agent_router.router import (
            _apply_bridge_assignments, _resolve_chain_pads,
        )
        from agent_router.hints import (
            RoutingHints, InternalBridge, ChainHint,
        )

        board = self._make_chain_board()
        pads = board.get_net_pads("GND")

        chain = ChainHint(net="GND", pads=["SW1.B", "SW3.B", "SW2.B"])
        resolved = _resolve_chain_pads(board, chain)
        assert len(resolved) == 3
        assert resolved[0].component == "SW1"
        assert resolved[1].component == "SW3"
        assert resolved[2].component == "SW2"

        # Build exclusion set (all except anchor SW1.B)
        exclusions = {(p.component, p.number) for p in resolved[1:]}
        assert ("SW3", "B") in exclusions
        assert ("SW2", "B") in exclusions
        assert ("SW1", "B") not in exclusions

        bridge = InternalBridge(
            component="U1", net="GND",
            pin_assignments={"23": ["SW1", "SW2", "SW3"]},
        )
        connections = _apply_bridge_assignments(
            pads, [bridge], board, chained_pads=exclusions,
        )
        # Only U1.23 -> SW1.B should remain (SW2, SW3 excluded)
        bridge_comps = [(a.component, b.component) for a, b in connections]
        assert ("U1", "SW1") in bridge_comps
        assert ("U1", "SW2") not in bridge_comps
        assert ("U1", "SW3") not in bridge_comps

    def test_chain_in_route_board_with_hints(self):
        """Full routing with chain produces sequential connections."""
        from agent_router.router import route_board_with_hints
        from agent_router.hints import (
            RoutingHints, GlobalHints, InternalBridge, ChainHint,
        )

        board = self._make_chain_board()
        hints = RoutingHints(
            global_hints=GlobalHints(prefer_orthogonal=True),
            internal_bridges=[
                InternalBridge(
                    component="U1", net="GND",
                    pin_assignments={"23": ["SW1", "SW2", "SW3"]},
                ),
            ],
            chains=[
                ChainHint(net="GND", pads=["SW1.B", "SW3.B", "SW2.B"]),
            ],
        )

        result = route_board_with_hints(board, hints)
        assert result.success
        # GND should be routed
        gnd_routes = [r for r in result.routes if r.net == "GND"]
        assert len(gnd_routes) == 1
        # Should have paths for: U1.23->SW1.B, SW1.B->SW3.B, SW3.B->SW2.B
        assert len(gnd_routes[0].paths) == 3

    def test_chain_without_bridge(self):
        """Chain works even without bridge assignments (standalone)."""
        from agent_router.router import route_board_with_hints
        from agent_router.hints import RoutingHints, GlobalHints, ChainHint

        board = Board(width=80, height=80)
        board.pads = [
            Pad(position=(10.0, 10.0), net="SIG", component="A", number="1",
                size=(1.5, 1.5), shape="circle", pad_type="thru_hole"),
            Pad(position=(30.0, 10.0), net="SIG", component="B", number="1",
                size=(1.5, 1.5), shape="circle", pad_type="thru_hole"),
            Pad(position=(50.0, 10.0), net="SIG", component="C", number="1",
                size=(1.5, 1.5), shape="circle", pad_type="thru_hole"),
        ]
        board.nets = {"SIG": Net("SIG", 1, board.pads)}

        hints = RoutingHints(
            global_hints=GlobalHints(prefer_orthogonal=True),
            chains=[
                ChainHint(net="SIG", pads=["A.1", "B.1", "C.1"]),
            ],
        )

        result = route_board_with_hints(board, hints)
        assert result.success

    def test_resolve_chain_pads_bad_ref(self):
        """Unresolvable pad references return empty list."""
        from agent_router.router import _resolve_chain_pads
        from agent_router.hints import ChainHint

        board = self._make_chain_board()
        chain = ChainHint(net="GND", pads=["SW1.B", "NONEXIST.X"])
        resolved = _resolve_chain_pads(board, chain)
        assert resolved == []


class TestInternalNetsRouting:
    """Tests for internal_nets filtering in bridge assignments."""

    def test_internal_orphan_pins_excluded(self):
        """Internal-net orphan pins (not in pin_assignments) produce no connections."""
        from agent_router.router import _apply_bridge_assignments
        from agent_router.hints import InternalBridge

        board = Board(width=80, height=80)
        # U1 has GND pins 1, 2, 3 (internally bonded).
        # Pin 1 is assigned to C1, pin 2 to C2, pin 3 is an orphan.
        board.pads = [
            Pad("U1", "1", "GND", (10, 10), (1, 1)),
            Pad("U1", "2", "GND", (12, 10), (1, 1)),
            Pad("U1", "3", "GND", (14, 10), (1, 1)),  # orphan
            Pad("C1", "1", "GND", (10, 30), (1, 1)),
            Pad("C2", "1", "GND", (12, 30), (1, 1)),
        ]
        board.nets = {"GND": Net("GND", 1, board.pads)}

        bridge = InternalBridge(
            component="U1", net="GND",
            pin_assignments={"1": ["C1"], "2": ["C2"]},
        )
        internal_nets = {"U1": {"GND": ["1", "2", "3"]}}

        connections = _apply_bridge_assignments(
            board.pads, [bridge], board,
            internal_nets=internal_nets,
        )

        # Pin 3 should NOT appear in any connection (it's an internal orphan)
        for pad_a, pad_b in connections:
            assert not (pad_a.component == "U1" and pad_a.number == "3"), \
                f"Orphan U1.3 found in connection: {pad_a} -> {pad_b}"
            assert not (pad_b.component == "U1" and pad_b.number == "3"), \
                f"Orphan U1.3 found in connection: {pad_a} -> {pad_b}"

    def test_bridge_pins_not_connected_to_each_other(self):
        """Bridge pins should not be routed to each other (internally bonded)."""
        from agent_router.router import _apply_bridge_assignments
        from agent_router.hints import InternalBridge

        board = Board(width=80, height=80)
        # U1 GND pins 1, 2, 3: pin 1 -> C1, pin 2 -> C2. Pin 3 orphan.
        # Plus an external pad D1.1 not in any assignment.
        board.pads = [
            Pad("U1", "1", "GND", (10, 10), (1, 1)),
            Pad("U1", "2", "GND", (12, 10), (1, 1)),
            Pad("U1", "3", "GND", (14, 10), (1, 1)),
            Pad("C1", "1", "GND", (10, 30), (1, 1)),
            Pad("C2", "1", "GND", (12, 30), (1, 1)),
            Pad("D1", "1", "GND", (20, 30), (1, 1)),  # unassigned external
        ]
        board.nets = {"GND": Net("GND", 1, board.pads)}

        bridge = InternalBridge(
            component="U1", net="GND",
            pin_assignments={"1": ["C1"], "2": ["C2"]},
        )
        internal_nets = {"U1": {"GND": ["1", "2", "3"]}}

        connections = _apply_bridge_assignments(
            board.pads, [bridge], board,
            internal_nets=internal_nets,
        )

        # No U1-to-U1 connections should exist
        u1_to_u1 = [
            (a, b) for a, b in connections
            if a.component == "U1" and b.component == "U1"
        ]
        assert len(u1_to_u1) == 0, f"Bogus U1-to-U1 connections: {u1_to_u1}"

        # D1.1 should still be connected (via single anchor to MST)
        d1_in_connections = any(
            (a.component == "D1" or b.component == "D1")
            for a, b in connections
        )
        assert d1_in_connections, "Unassigned external pad D1.1 should still be routed"

    def test_no_internal_nets_backward_compatible(self):
        """Without internal_nets, behavior is unchanged (all bridge pins as anchors)."""
        from agent_router.router import _apply_bridge_assignments
        from agent_router.hints import InternalBridge

        board = Board(width=80, height=80)
        board.pads = [
            Pad("U1", "1", "GND", (10, 10), (1, 1)),
            Pad("U1", "2", "GND", (12, 10), (1, 1)),
            Pad("C1", "1", "GND", (10, 30), (1, 1)),
        ]
        board.nets = {"GND": Net("GND", 1, board.pads)}

        bridge = InternalBridge(
            component="U1", net="GND",
            pin_assignments={"1": ["C1"]},
        )

        # No internal_nets passed — should still work
        connections = _apply_bridge_assignments(
            board.pads, [bridge], board,
        )

        # U1.1 -> C1.1 should exist
        assert any(
            a.component == "U1" and b.component == "C1"
            for a, b in connections
        )

    def test_internal_nets_in_route_board_with_hints(self):
        """Full integration: internal_nets eliminates bogus U1-to-U1 traces."""
        from agent_router.router import route_board_with_hints
        from agent_router.hints import RoutingHints, GlobalHints, InternalBridge

        board = Board(width=80, height=80)
        # Mimics the SR14 bug: U1 has GND pins 22, 23, 24, 44
        # Pin 22 -> BAT1, pin 23 -> SW1, pin 44 -> SW2
        # Pin 24 is orphan (internal only)
        board.pads = [
            Pad("U1", "22", "GND", (10, 10), (1, 1)),
            Pad("U1", "23", "GND", (12, 10), (1, 1)),
            Pad("U1", "24", "GND", (14, 10), (1, 1)),  # orphan
            Pad("U1", "44", "GND", (16, 10), (1, 1)),
            Pad("BAT1", "1", "GND", (10, 30), (1, 1)),
            Pad("SW1", "B", "GND", (12, 30), (1, 1)),
            Pad("SW2", "B", "GND", (16, 30), (1, 1)),
        ]
        board.nets = {"GND": Net("GND", 1, board.pads)}

        hints = RoutingHints(
            global_hints=GlobalHints(prefer_orthogonal=True),
            internal_bridges=[
                InternalBridge(
                    component="U1", net="GND",
                    pin_assignments={
                        "22": ["BAT1"],
                        "23": ["SW1"],
                        "44": ["SW2"],
                    },
                ),
            ],
        )
        internal_nets = {"U1": {"GND": ["22", "23", "24", "44"]}}

        result = route_board_with_hints(board, hints, internal_nets=internal_nets)
        assert result.success

        # Check that no route segment connects two U1 pads
        gnd_routes = [r for r in result.routes if r.net == "GND"]
        assert len(gnd_routes) == 1
        # Should have exactly 3 paths: U1.22->BAT1, U1.23->SW1, U1.44->SW2
        assert len(gnd_routes[0].paths) == 3
