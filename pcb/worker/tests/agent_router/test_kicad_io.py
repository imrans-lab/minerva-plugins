"""
Tests for KiCad I/O.
"""

import pytest
from pathlib import Path

from agent_router.kicad_io import (
    read_kicad_pcb,
    write_kicad_pcb,
    TraceSegment,
    Via,
    KiCadPCB,
    _transform_position,
)


class TestKiCadReading:
    """Tests for reading KiCad PCB files."""

    def test_read_pcb_footprints(self, two_pads_pcb):
        """Parse footprints from KiCad PCB file."""
        board = read_kicad_pcb(two_pads_pcb)
        assert len(board.pads) >= 1

    def test_read_pcb_nets(self, two_pads_pcb):
        """Parse net definitions from KiCad PCB file."""
        board = read_kicad_pcb(two_pads_pcb)
        assert "NET1" in board.nets

    def test_read_pad_positions(self, two_pads_pcb):
        """Pads have correct positions."""
        board = read_kicad_pcb(two_pads_pcb)
        assert len(board.pads) == 2

        # Check positions are reasonable (not at origin)
        for pad in board.pads:
            assert pad.position[0] > 0 or pad.position[1] > 0

    def test_read_board_dimensions(self, two_pads_pcb):
        """Board dimensions are parsed."""
        board = read_kicad_pcb(two_pads_pcb)
        assert board.width > 0
        assert board.height > 0


class TestPositionTransform:
    """Tests for position transformation."""

    def test_no_rotation(self):
        """Position without rotation."""
        abs_x, abs_y = _transform_position(1, 0, 50, 50, 0)
        assert abs_x == pytest.approx(51, abs=0.01)
        assert abs_y == pytest.approx(50, abs=0.01)

    def test_90_degree_rotation(self):
        """Position with 90° rotation (KiCad clockwise convention)."""
        abs_x, abs_y = _transform_position(1, 0, 50, 50, 90)
        assert abs_x == pytest.approx(50, abs=0.01)
        assert abs_y == pytest.approx(49, abs=0.01)

    def test_180_degree_rotation(self):
        """Position with 180° rotation."""
        abs_x, abs_y = _transform_position(1, 0, 50, 50, 180)
        assert abs_x == pytest.approx(49, abs=0.01)
        assert abs_y == pytest.approx(50, abs=0.01)

    def test_270_degree_rotation(self):
        """Position with 270° rotation (KiCad clockwise convention)."""
        abs_x, abs_y = _transform_position(1, 0, 50, 50, 270)
        assert abs_x == pytest.approx(50, abs=0.01)
        assert abs_y == pytest.approx(51, abs=0.01)


class TestTraceSegment:
    """Tests for TraceSegment class."""

    def test_write_trace_segment(self):
        """Write trace segment in correct KiCad format."""
        segment = TraceSegment(
            start=(25.0, 30.0),
            end=(40.0, 30.0),
            width=0.25,
            layer="F.Cu",
            net=1
        )
        kicad_str = segment.to_kicad()

        assert "(segment" in kicad_str
        assert "(start 25.0 30.0)" in kicad_str
        assert "(end 40.0 30.0)" in kicad_str
        assert "(width 0.25)" in kicad_str
        assert '(layer "F.Cu")' in kicad_str
        assert "(net 1)" in kicad_str


class TestVia:
    """Tests for Via class."""

    def test_write_via(self):
        """Write via in correct KiCad format."""
        via = Via(position=(30.0, 25.0), size=0.8, drill=0.4, net=2)
        kicad_str = via.to_kicad()

        assert "(via" in kicad_str
        assert "(at 30.0 25.0)" in kicad_str
        assert "(size 0.8)" in kicad_str
        assert "(drill 0.4)" in kicad_str
        assert "(net 2)" in kicad_str

    def test_via_default_layers(self):
        """Via has correct default layers."""
        via = Via(position=(30.0, 25.0), size=0.8, drill=0.4, net=2)
        assert via.layers == ("F.Cu", "B.Cu")

    def test_from_canonical_maps_top_bottom_to_kicad_layers(self):
        """A canonical via with from_layer/to_layer maps top/bottom -> F.Cu/B.Cu
        (docket 019... U1: canonical via schema)."""
        via = Via.from_canonical(
            {"x_mm": 15.7, "y_mm": 55.88, "drill_mm": 0.4, "diameter_mm": 0.8,
             "from_layer": "top", "to_layer": "bottom"},
            net_number=3,
        )
        assert via.position == (15.7, 55.88)
        assert via.size == 0.8
        assert via.drill == 0.4
        assert via.net == 3
        assert via.layers == ("F.Cu", "B.Cu")
        assert '(layers "F.Cu" "B.Cu")' in via.to_kicad()

    def test_from_canonical_tolerates_legacy_via_without_span(self):
        """A legacy via with no from_layer/to_layer defaults to F.Cu/B.Cu (no
        crash) — same default the dataclass itself uses."""
        via = Via.from_canonical(
            {"x_mm": 1.0, "y_mm": 2.0, "drill_mm": 0.4, "diameter_mm": 0.8})
        assert via.layers == ("F.Cu", "B.Cu")

    def test_from_canonical_missing_size_fields_use_defaults(self):
        """Missing diameter_mm/drill_mm fall back to sane defaults instead of
        raising, mirroring Via's own dataclass defaults."""
        via = Via.from_canonical({"x_mm": 1.0, "y_mm": 2.0})
        assert via.size == 0.8
        assert via.drill == 0.4
        assert via.net == 0


class TestKiCadWriting:
    """Tests for writing KiCad PCB files."""

    def test_roundtrip_preserves_original(self, two_pads_pcb, tmp_dir):
        """Reading and writing back preserves non-routing elements."""
        # Read original
        original_content = Path(two_pads_pcb).read_text()
        pcb = KiCadPCB(raw_content=original_content)

        # Add a route
        pcb.add_segment(TraceSegment(
            start=(25.0, 30.0),
            end=(40.0, 30.0),
            width=0.25,
            layer="F.Cu",
            net=1
        ))

        # Write
        output_path = tmp_dir / "output.kicad_pcb"
        write_kicad_pcb(pcb, output_path)

        # Read back
        reloaded_content = output_path.read_text()

        # Original content should be preserved
        assert "(footprint" in reloaded_content
        # New segment should be present
        assert "(segment" in reloaded_content
        assert "(start 25.0 30.0)" in reloaded_content

    def test_write_multiple_segments(self, two_pads_pcb, tmp_dir):
        """Multiple segments are written correctly."""
        original_content = Path(two_pads_pcb).read_text()
        pcb = KiCadPCB(raw_content=original_content)

        pcb.add_segment(TraceSegment((10, 10), (20, 10), 0.25, "F.Cu", 1))
        pcb.add_segment(TraceSegment((20, 10), (20, 20), 0.25, "F.Cu", 1))
        pcb.add_segment(TraceSegment((20, 20), (30, 20), 0.25, "F.Cu", 1))

        output_path = tmp_dir / "output.kicad_pcb"
        write_kicad_pcb(pcb, output_path)

        content = output_path.read_text()
        assert content.count("(segment") == 3

    def test_write_vias(self, two_pads_pcb, tmp_dir):
        """Vias are written correctly."""
        original_content = Path(two_pads_pcb).read_text()
        pcb = KiCadPCB(raw_content=original_content)

        pcb.add_via(Via((25, 25), 0.8, 0.4, 1))

        output_path = tmp_dir / "output.kicad_pcb"
        write_kicad_pcb(pcb, output_path)

        content = output_path.read_text()
        assert "(via" in content
        assert "(at 25 25)" in content


class TestKiCadPCB:
    """Tests for KiCadPCB class."""

    def test_add_segment(self):
        """Adding segment updates list."""
        pcb = KiCadPCB()
        seg = TraceSegment((0, 0), (10, 10), 0.25, "F.Cu", 1)
        pcb.add_segment(seg)

        assert len(pcb.segments) == 1
        assert pcb.segments[0] is seg

    def test_add_via(self):
        """Adding via updates list."""
        pcb = KiCadPCB()
        via = Via((5, 5), 0.8, 0.4, 1)
        pcb.add_via(via)

        assert len(pcb.vias) == 1
        assert pcb.vias[0] is via
