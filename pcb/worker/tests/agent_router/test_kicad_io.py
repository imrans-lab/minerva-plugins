"""
Tests for KiCad I/O.
"""

import textwrap

import pytest
from pathlib import Path

from agent_router import router as engine_router
from agent_router.board import Board
from agent_router.router import ExistingSegment, ExistingVia
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


# ---------------------------------------------------------------------------
# 019f9d0bc17c — read (segment ...) / (via ...) into Board.existing_traces /
# existing_vias, net NUMBER resolved to net NAME.
# ---------------------------------------------------------------------------


def _pcb_text(*, extra_copper: str = "", third_pad: bool = False) -> str:
    """A minimal routed .kicad_pcb: two (optionally three) pads on net "SIG",
    positioned so their absolute pad centres are exact round numbers a test
    can target with copper endpoints — no coincidence-tolerance guesswork.

    P1 @ (10, 20), P2 @ (30, 20), and — if ``third_pad`` — P3 @ (50, 20), all
    on F.Cu, all net 1 "SIG". ``extra_copper`` is inserted verbatim (one or
    more ``(segment ...)`` / ``(via ...)`` blocks).
    """
    third = ""
    if third_pad:
        third = textwrap.dedent("""\
            (footprint "R_0603" (layer "F.Cu")
              (at 50 20)
              (property "Reference" "P3")
              (pad "1" smd rect (at 0 0) (size 1.6 1.6) (layers "F.Cu") (net 1 "SIG"))
            )
            """)
    return textwrap.dedent(f"""\
        (kicad_pcb (version 20221018) (generator pcbnew)
          (general (thickness 1.6))
          (paper "A4")
          (layers
            (0 "F.Cu" signal)
            (31 "B.Cu" signal)
            (44 "Edge.Cuts" user)
          )
          (net 0 "")
          (net 1 "SIG")
          (gr_rect (start 0 0) (end 60 40) (layer "Edge.Cuts") (width 0.1))
          (footprint "R_0603" (layer "F.Cu")
            (at 10 20)
            (property "Reference" "P1")
            (pad "1" smd rect (at 0 0) (size 1.6 1.6) (layers "F.Cu") (net 1 "SIG"))
          )
          (footprint "R_0603" (layer "F.Cu")
            (at 30 20)
            (property "Reference" "P2")
            (pad "1" smd rect (at 0 0) (size 1.6 1.6) (layers "F.Cu") (net 1 "SIG"))
          )
          {third}{extra_copper}
        )
        """)


class TestExistingCopper:
    """``Board.from_kicad`` reads already-accepted copper (019f9d0bc17c).

    The trap this class exists to catch: ``kicad_io.TraceSegment.net`` /
    ``Via.net`` are int net NUMBERS (KiCad's own vocabulary), but
    ``router.ExistingSegment.net`` / ``ExistingVia.net`` are ``Optional[str]``
    net NAMES, and ``router._existing_copper_by_net`` keys on the NAME to
    match ``board.get_net_pads(net_name)``. Fill the slot with the raw int and
    the copper is marked under a label nothing else recognises: pre-connected
    groups never merge, and the router proposes fresh copper across ground
    that is already joined — a silent divergence from a board that is already
    (partly) routed, not a crash.
    """

    def test_segment_is_read_with_correct_geometry_and_layer(self, tmp_path):
        pcb = tmp_path / "b.kicad_pcb"
        pcb.write_text(_pcb_text(
            extra_copper='(segment (start 10 20) (end 30 20) (width 0.3) '
                        '(layer "F.Cu") (net 1))'))
        board = Board.from_kicad(pcb)

        assert len(board.existing_traces) == 1
        seg = board.existing_traces[0]
        assert isinstance(seg, ExistingSegment)
        assert seg.start == (10.0, 20.0)
        assert seg.end == (30.0, 20.0)
        assert seg.width == 0.3
        assert seg.layer == "F.Cu"

    def test_via_is_read_with_correct_geometry_and_layers(self, tmp_path):
        pcb = tmp_path / "b.kicad_pcb"
        pcb.write_text(_pcb_text(
            extra_copper='(via (at 20 20) (size 0.8) (drill 0.4) '
                        '(layers "F.Cu" "B.Cu") (net 1))'))
        board = Board.from_kicad(pcb)

        assert len(board.existing_vias) == 1
        via = board.existing_vias[0]
        assert isinstance(via, ExistingVia)
        assert via.position == (20.0, 20.0)
        assert via.diameter == 0.8
        # `ExistingVia.layers` is the OCCUPIED SET, not `kicad_io.Via.layers`'
        # (from, to) SPAN — see the class-level note. On THIS package's boards
        # (agent_router.layers models exactly top/bottom) the two happen to
        # contain the same two names, which is why this assertion ALONE would
        # pass under a naive "just copy the span tuple" implementation too;
        # it is here for basic coverage, not as the discriminating proof —
        # that is `test_the_net_name_not_the_net_number_is_what_merges_
        # pre_connected_groups` below, which fails under exactly that naive
        # implementation whenever the net type is wrong (it would also fail
        # were the layers merely aliased rather than derived).
        assert set(via.layers) == {"F.Cu", "B.Cu"}

    def test_a_degenerate_via_span_collapses_to_the_one_layer_it_occupies(
            self, tmp_path):
        """The type distinction made concrete: a FROM==TO via block (malformed
        as real copper, but a legal thing for THIS reader to be handed) has a
        2-element SPAN by the KiCad file's own shape, but occupies exactly ONE
        layer. `dict.fromkeys` on the pair proves the mapping enumerates
        occupied layers rather than aliasing the span tuple — a straight
        ``layers=via.layers`` copy would keep both (identical) entries and
        return a 2-tuple here instead of 1."""
        pcb = tmp_path / "b.kicad_pcb"
        pcb.write_text(_pcb_text(
            extra_copper='(via (at 20 20) (size 0.8) (drill 0.4) '
                        '(layers "F.Cu" "F.Cu") (net 1))'))
        board = Board.from_kicad(pcb)

        assert len(board.existing_vias) == 1
        assert board.existing_vias[0].layers == ("F.Cu",)

    def test_the_net_name_not_the_net_number_is_what_merges_pre_connected_groups(
            self, tmp_path):
        """THE discriminating test (assert it directly, per the item).

        P1 and P2 sit on net 1 "SIG" and are ALREADY joined by an existing
        segment. P3 is a third "SIG" pad with no copper to it at all. If the
        segment's net came through as the NAME "SIG", the router's
        pre-connected-group merge recognises P1/P2 as already joined and the
        reply needs exactly ONE new connection (folding P3 into that group —
        the SAME shape ``test_the_via_is_what_joins_the_two_halves_of_an_
        accepted_net`` in test_route_rules.py pins for the via case). If the
        segment's net leaked through as the raw int ``1`` instead, ``router.
        _existing_copper_by_net`` (keyed on the NAME) would never find it under
        "SIG": P1 and P2 would look unconnected, the spanning tree would ask
        for TWO connections instead of one, and — since the mislabelled
        segment is also marked on the grid as an obstacle under a net name
        nothing else matches — the router could reroute across it as though it
        were a stranger's copper. Either way the run silently disagrees with
        what is already on the board while reporting a clean result.
        """
        pcb = tmp_path / "b.kicad_pcb"
        pcb.write_text(_pcb_text(
            third_pad=True,
            extra_copper='(segment (start 10 20) (end 30 20) (width 0.25) '
                        '(layer "F.Cu") (net 1))'))
        board = Board.from_kicad(pcb)

        # Assert the resolution directly, not just its downstream effect.
        assert board.existing_traces[0].net == "SIG"

        result = engine_router.route_board(
            board, trace_width=0.25, clearance=0.2)
        route = result.get_route("SIG")
        assert route is not None, "P3 still needs joining in"
        assert len(route.paths) == 1, (
            "P1/P2 are already joined by accepted copper; only P3 is loose — "
            "two paths here means the pre-connected groups did not merge")
        assert not result.unrouted

    def test_a_net_wholly_joined_by_existing_copper_gets_no_new_route(
            self, tmp_path):
        """The degenerate case: existing copper already spans the WHOLE net,
        so nothing should be proposed at all — not a redundant parallel trace
        laid straight over (or through) the copper already there."""
        pcb = tmp_path / "b.kicad_pcb"
        pcb.write_text(_pcb_text(
            extra_copper='(segment (start 10 20) (end 30 20) (width 0.25) '
                        '(layer "F.Cu") (net 1))'))
        board = Board.from_kicad(pcb)

        result = engine_router.route_board(
            board, trace_width=0.25, clearance=0.2)
        assert result.get_route("SIG") is None
        assert not result.unrouted

    def test_a_segment_with_no_width_is_a_parse_failure_not_a_default(
            self, tmp_path):
        """Lazy-fix trap: populating start/end while defaulting width. A trace
        is a CENTERLINE and keepout is derived from its width, so a defaulted
        width under-blocks — the fail-open direction that reintroduces the
        short this reader exists to prevent."""
        pcb = tmp_path / "b.kicad_pcb"
        pcb.write_text(_pcb_text(
            extra_copper='(segment (start 10 20) (end 30 20) '
                        '(layer "F.Cu") (net 1))'))
        with pytest.raises(ValueError, match="width"):
            Board.from_kicad(pcb)

    def test_a_via_with_no_size_is_a_parse_failure_not_a_default(self, tmp_path):
        """Same lazy-fix trap, via side: no ``(size ...)`` must fail, never
        default to 0.8."""
        pcb = tmp_path / "b.kicad_pcb"
        pcb.write_text(_pcb_text(
            extra_copper='(via (at 20 20) (drill 0.4) '
                        '(layers "F.Cu" "B.Cu") (net 1))'))
        with pytest.raises(ValueError, match="size"):
            Board.from_kicad(pcb)

    def test_a_clean_board_still_reads_with_empty_existing_copper_slots(
            self, tmp_path):
        """The control: a board with no routed copper at all must not
        fabricate any."""
        pcb = tmp_path / "b.kicad_pcb"
        pcb.write_text(_pcb_text())
        board = Board.from_kicad(pcb)
        assert board.existing_traces == ()
        assert board.existing_vias == ()


class TestViaSpanExpandsToTheOccupiedStackRange:
    """Epoch GA-3: a parsed via's ``(layers "A" "B")`` endpoint pair expands
    to the INCLUSIVE stack-order range against the file's own copper header —
    on a 4-layer file a through via occupies In1/In2 too, and handing the raw
    pair through left those annuli unguarded on the grid."""

    def _four_layer_text(self, extra_copper: str) -> str:
        text = _pcb_text(extra_copper=extra_copper)
        return text.replace(
            '(0 "F.Cu" signal)\n    (31 "B.Cu" signal)',
            '(0 "F.Cu" signal)\n    (4 "In1.Cu" signal)\n'
            '    (6 "In2.Cu" signal)\n    (2 "B.Cu" signal)')

    def test_a_through_via_occupies_every_layer_of_a_four_layer_file(
            self, tmp_path):
        pcb = tmp_path / "b.kicad_pcb"
        pcb.write_text(self._four_layer_text(
            '(via (at 20 20) (size 0.8) (drill 0.4) '
            '(layers "F.Cu" "B.Cu") (net 1))'))
        board = Board.from_kicad(pcb)
        assert len(board.existing_vias) == 1
        assert board.existing_vias[0].layers == (
            "F.Cu", "In1.Cu", "In2.Cu", "B.Cu")

    def test_a_two_layer_file_keeps_the_endpoint_pair_byte_identically(
            self, tmp_path):
        pcb = tmp_path / "b.kicad_pcb"
        pcb.write_text(_pcb_text(
            extra_copper='(via (at 20 20) (size 0.8) (drill 0.4) '
                         '(layers "F.Cu" "B.Cu") (net 1))'))
        board = Board.from_kicad(pcb)
        assert board.existing_vias[0].layers == ("F.Cu", "B.Cu")

    def test_header_order_does_not_matter_stack_order_is_rederived(
            self, tmp_path):
        """A foreign file may list copper in layer-ID order (F, B, In1, In2);
        the occupied range must still follow the physical stack."""
        text = _pcb_text(extra_copper=(
            '(via (at 20 20) (size 0.8) (drill 0.4) '
            '(layers "F.Cu" "In2.Cu") (net 1))'))
        text = text.replace(
            '(0 "F.Cu" signal)\n    (31 "B.Cu" signal)',
            '(0 "F.Cu" signal)\n    (2 "B.Cu" signal)\n'
            '    (4 "In1.Cu" signal)\n    (6 "In2.Cu" signal)')
        pcb = tmp_path / "b.kicad_pcb"
        pcb.write_text(text)
        board = Board.from_kicad(pcb)
        # F.Cu -> In2.Cu spans F, In1, In2 — NOT everything up to B.Cu.
        assert board.existing_vias[0].layers == ("F.Cu", "In1.Cu", "In2.Cu")


class TestUnnumberedPadsParse:
    """Bug 019f9af741 (fixed at epoch GA-6): `(pad "" np_thru_hole ...)` — the
    shape KiCad writes for EVERY board-level NPTH mounting hole — used to fail
    _parse_pad's number regex and vanish from the parse with no diagnostic.
    A drilled hole the reader cannot see is free space the router can route
    through; the ir_parity harness carried a private recovery regex for the
    gap, deleted with the fix (its shelf life ended as its comment predicted)."""

    def test_an_unnumbered_npth_pad_is_parsed_not_dropped(self, tmp_path):
        extra = textwrap.dedent("""\
            (footprint "MountingHole" (layer "F.Cu")
              (at 50 30)
              (property "Reference" "H1")
              (pad "" np_thru_hole circle (at 0 0) (size 3.2 3.2) (drill 3.2) (layers "*.Cu" "*.Mask"))
            )
            """)
        pcb = tmp_path / "b.kicad_pcb"
        pcb.write_text(_pcb_text(extra_copper=extra))
        board = read_kicad_pcb(pcb)
        holes = [p for p in board.pads if p.pad_type == "np_thru_hole"]
        assert len(holes) == 1, (
            "the NPTH mounting-hole pad must survive the parse — before the "
            "fix it silently vanished and its drill was routable free space")
        hole = holes[0]
        assert hole.number == ""
        # KiCad's unconnected net 0 is named "" in the file's own net table,
        # and the reader maps it through verbatim — the longstanding net-0
        # convention for EVERY pad, not a hole-specific choice. Both None
        # and "" mean "owned by no real net" to the grid (no authored net is
        # ever named the empty string).
        assert hole.net in (None, "")
        assert hole.drill == 3.2
        assert hole.position == (50.0, 30.0)

    def test_numbered_pads_still_parse_both_spellings(self, tmp_path):
        """Regression control for the regex change: quoted and bare numbers
        keep parsing exactly as before."""
        pcb = tmp_path / "b.kicad_pcb"
        pcb.write_text(_pcb_text())
        board = read_kicad_pcb(pcb)
        assert {p.number for p in board.pads} == {"1"}
