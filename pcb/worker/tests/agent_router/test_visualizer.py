"""
Tests for visualization.
"""

import pytest
from agent_router.board import Board, Pad, Obstacle
from agent_router.router import Route
from agent_router.pathfinder import Path, PathSegment
from agent_router.visualizer import visualize_ascii, visualize_svg


class TestAsciiVisualization:
    """Tests for ASCII visualization."""

    def test_ascii_grid_shows_pads(self):
        """ASCII visualization marks pad locations."""
        board = Board(width=20, height=20)
        board.pads.append(Pad("R1", "1", "VCC", (10, 10), (1, 1)))

        ascii_art = visualize_ascii(board, scale=2.0)

        assert "●" in ascii_art  # SMD pad marker

    def test_ascii_grid_shows_thru_hole_pads(self):
        """ASCII visualization shows through-hole pads."""
        board = Board(width=20, height=20)
        board.pads.append(Pad("R1", "1", "VCC", (10, 10), (1, 1), pad_type="thru_hole"))

        ascii_art = visualize_ascii(board, scale=2.0)

        assert "◎" in ascii_art  # Through-hole pad marker

    def test_ascii_grid_shows_obstacles(self):
        """ASCII visualization marks blocked areas."""
        board = Board(width=20, height=20)
        board.obstacles.append(Obstacle((10, 10), "mounting_hole", radius=2.0))

        ascii_art = visualize_ascii(board, scale=2.0)

        assert "○" in ascii_art  # Hole marker

    def test_ascii_grid_shows_traces(self):
        """ASCII visualization shows routed traces."""
        board = Board(width=30, height=10)
        board.pads.append(Pad("R1", "1", "NET1", (5, 5), (1, 1)))
        board.pads.append(Pad("R1", "2", "NET1", (25, 5), (1, 1)))

        route = Route(net="NET1")
        path = Path(segments=[
            PathSegment((5, 5), (25, 5), "F.Cu")
        ])
        route.paths.append(path)

        ascii_art = visualize_ascii(board, routes=[route], scale=2.0)

        assert "─" in ascii_art  # Horizontal trace

    def test_ascii_shows_vias(self):
        """ASCII visualization shows vias."""
        board = Board(width=20, height=20)

        route = Route(net="NET1")
        path = Path(
            segments=[PathSegment((5, 10), (15, 10), "F.Cu")],
            vias=[(10, 10)]
        )
        route.paths.append(path)

        ascii_art = visualize_ascii(board, routes=[route], scale=2.0)

        assert "◉" in ascii_art  # Via marker

    def test_ascii_has_border(self):
        """ASCII output has board border."""
        board = Board(width=20, height=20)
        ascii_art = visualize_ascii(board, scale=2.0)

        assert "┌" in ascii_art
        assert "┐" in ascii_art
        assert "└" in ascii_art
        assert "┘" in ascii_art


class TestSvgVisualization:
    """Tests for SVG visualization."""

    def test_svg_output_valid(self):
        """SVG output is well-formed."""
        board = Board(width=50, height=50)
        board.pads.append(Pad("R1", "1", "VCC", (25, 25), (1, 1)))

        svg = visualize_svg(board)

        assert svg.startswith("<?xml") or svg.startswith("<svg")
        assert "</svg>" in svg

    def test_svg_contains_board_rect(self):
        """SVG contains board outline rectangle."""
        board = Board(width=50, height=50)
        svg = visualize_svg(board)

        assert '<rect class="board"' in svg

    def test_svg_shows_pads(self):
        """SVG shows pad elements."""
        board = Board(width=50, height=50)
        board.pads.append(Pad("R1", "1", "VCC", (25, 25), (2, 1)))

        svg = visualize_svg(board)

        assert 'class="pad"' in svg

    def test_svg_shows_obstacles(self):
        """SVG shows obstacle elements."""
        board = Board(width=50, height=50)
        board.obstacles.append(Obstacle((25, 25), "mounting_hole", radius=2.0))

        svg = visualize_svg(board)

        assert 'class="obstacle"' in svg
        assert "<circle" in svg

    def test_svg_shows_traces(self):
        """SVG shows trace elements."""
        board = Board(width=50, height=50)

        route = Route(net="NET1")
        path = Path(segments=[
            PathSegment((10, 25), (40, 25), "F.Cu")
        ])
        route.paths.append(path)

        svg = visualize_svg(board, routes=[route])

        assert 'class="trace-fcu"' in svg
        assert "<line" in svg

    def test_svg_shows_vias(self):
        """SVG shows via elements."""
        board = Board(width=50, height=50)

        route = Route(net="NET1")
        path = Path(
            segments=[PathSegment((10, 25), (40, 25), "F.Cu")],
            vias=[(25, 25)]
        )
        route.paths.append(path)

        svg = visualize_svg(board, routes=[route])

        assert 'class="via"' in svg

    def test_svg_scale_factor(self):
        """SVG respects scale factor."""
        board = Board(width=50, height=50)

        svg_10 = visualize_svg(board, scale=10.0)
        svg_20 = visualize_svg(board, scale=20.0)

        # Larger scale = larger SVG
        assert 'width="540"' in svg_10  # 50*10 + 40 padding
        assert 'width="1040"' in svg_20  # 50*20 + 40 padding

    def test_svg_custom_pad_colors(self):
        """SVG respects custom pad colors."""
        board = Board(width=50, height=50)
        board.pads.append(Pad("R1", "1", "VCC", (25, 25), (2, 1)))

        svg = visualize_svg(board, pad_colors={"VCC": "#ff0000"})

        assert "fill: #ff0000" in svg

    def test_svg_different_layer_traces(self):
        """SVG distinguishes F.Cu and B.Cu traces."""
        board = Board(width=50, height=50)

        route = Route(net="NET1")
        route.paths.append(Path(segments=[
            PathSegment((10, 20), (40, 20), "F.Cu"),
            PathSegment((10, 30), (40, 30), "B.Cu"),
        ]))

        svg = visualize_svg(board, routes=[route])

        assert 'class="trace-fcu"' in svg
        assert 'class="trace-bcu"' in svg


class TestVisualizationWithRealBoard:
    """Tests using actual KiCad PCB fixtures."""

    def test_visualize_two_pads(self, two_pads_pcb):
        """Visualize simple two-pad board."""
        from agent_router.board import Board

        board = Board.from_kicad(two_pads_pcb)
        ascii_art = visualize_ascii(board, scale=2.0)

        # Should have border and pads
        assert "┌" in ascii_art
        assert "●" in ascii_art or "◎" in ascii_art

    def test_svg_two_pads(self, two_pads_pcb):
        """SVG of simple two-pad board."""
        from agent_router.board import Board

        board = Board.from_kicad(two_pads_pcb)
        svg = visualize_svg(board)

        assert "</svg>" in svg
        assert "pad" in svg
