"""
Tests for Board representation.
"""

import pytest
from agent_router.board import Board, Pad, Net, Obstacle


class TestBoardLoading:
    """Tests for loading boards from KiCad files."""

    def test_load_pads_from_kicad(self, two_pads_pcb):
        """Load a KiCad PCB and extract pad positions."""
        board = Board.from_kicad(two_pads_pcb)
        assert len(board.pads) == 2
        assert board.pads[0].net == "NET1"
        # Pad 1 is at footprint (25, 30) with offset (-0.825, 0) = (24.175, 30)
        assert board.pads[0].position == pytest.approx((24.175, 30.0), abs=0.01)

    def test_pad_rotation_transform(self, rotated_component_pcb):
        """Pads on rotated components have correct absolute positions."""
        board = Board.from_kicad(rotated_component_pcb)
        # Component at (50, 50) rotated 90° (KiCad clockwise), pad offset (1, 0) -> absolute (50, 49)
        pad = board.get_pad("R1", "1")
        assert pad is not None
        assert pad.position == pytest.approx((50.0, 49.0), abs=0.01)

    def test_net_grouping(self, three_resistors_pcb):
        """Pads are correctly grouped by net."""
        board = Board.from_kicad(three_resistors_pcb)
        vcc_pads = board.get_net_pads("VCC")
        assert len(vcc_pads) == 3

    def test_obstacles_from_mounting_holes(self, board_with_holes_pcb):
        """Mounting holes create blocked regions."""
        board = Board.from_kicad(board_with_holes_pcb)
        assert len(board.obstacles) >= 1
        hole = board.obstacles[0]
        assert hole.type == "mounting_hole"
        assert hole.blocks_all_layers == True

    def test_board_bounds(self, two_pads_pcb):
        """Board outline defines routing bounds."""
        board = Board.from_kicad(two_pads_pcb)
        assert board.width == pytest.approx(50.0, abs=0.1)
        assert board.height == pytest.approx(50.0, abs=0.1)


class TestBoardMethods:
    """Tests for Board methods."""

    def test_get_pad_existing(self):
        """Get pad that exists."""
        board = Board()
        pad = Pad(
            component="R1",
            number="1",
            net="VCC",
            position=(10.0, 20.0),
            size=(1.0, 0.5)
        )
        board.pads.append(pad)

        result = board.get_pad("R1", "1")
        assert result is pad

    def test_get_pad_nonexistent(self):
        """Get pad that doesn't exist returns None."""
        board = Board()
        result = board.get_pad("R1", "1")
        assert result is None

    def test_get_net_pads_from_nets_dict(self):
        """Get pads from nets dictionary."""
        board = Board()
        pad1 = Pad(component="R1", number="1", net="VCC", position=(10, 20), size=(1, 1))
        pad2 = Pad(component="R2", number="1", net="VCC", position=(30, 40), size=(1, 1))

        net = Net(name="VCC", number=1, pads=[pad1, pad2])
        board.nets["VCC"] = net

        result = board.get_net_pads("VCC")
        assert len(result) == 2
        assert pad1 in result
        assert pad2 in result

    def test_get_net_pads_from_pads_list(self):
        """Get pads by scanning pads list when net not in dict."""
        board = Board()
        pad1 = Pad(component="R1", number="1", net="VCC", position=(10, 20), size=(1, 1))
        pad2 = Pad(component="R2", number="1", net="GND", position=(30, 40), size=(1, 1))
        board.pads = [pad1, pad2]

        result = board.get_net_pads("VCC")
        assert len(result) == 1
        assert pad1 in result


class TestDataclasses:
    """Tests for dataclass definitions."""

    def test_pad_defaults(self):
        """Pad has correct defaults."""
        pad = Pad(
            component="R1",
            number="1",
            net="VCC",
            position=(10.0, 20.0),
            size=(1.0, 0.5)
        )
        assert pad.shape == "rect"
        assert pad.pad_type == "smd"
        assert pad.drill is None
        assert pad.layer == "F.Cu"
        assert pad.rotation == 0.0

    def test_obstacle_defaults(self):
        """Obstacle has correct defaults."""
        obs = Obstacle(
            position=(25.0, 25.0),
            type="mounting_hole"
        )
        assert obs.radius is None
        assert obs.polygon is None
        assert obs.blocks_all_layers == True
        assert obs.layer is None

    def test_net_defaults(self):
        """Net has correct defaults."""
        net = Net(name="VCC", number=1)
        assert net.pads == []
