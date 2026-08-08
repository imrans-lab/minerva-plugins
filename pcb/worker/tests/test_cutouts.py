"""Epoch CPN1 station S1 — interior board cutouts, end to end.

The contract under test (docket 019fe2faf76e, closing fail-open 019fbd30f7):
a board authoring ``cutouts`` compiles into ``ProfileOutline(outer=<rim rect>,
cutouts=(ResolvedCutout, ...))`` and every consumer then genuinely sees it —

  * ``ir_projection.outline_frame`` frames a rect-outer profile faithfully and
    RAISES on any other outer (never the old silent bounding-box degrade);
  * the Gerber emitter draws each cutout as a second closed Profile contour on
    Edge_Cuts; the KiCad projection draws the matching gr_line loop;
  * geometric DRC GC5 measures copper-to-edge against cutout contours (a slot
    edge IS a board edge);
  * routing reserves each cutout as an all-layer polygon obstacle PRE-INFLATED
    by copper_to_edge (the grid's keepout margin then adds clearance + half
    trace width on top — over-reserving, never under);
  * zone fill carves pours away from cutouts by the same copper-to-edge band.

Fail-closed edges: strictly-interior vertices, pairwise-disjoint bounding
boxes, >= 3 distinct corners, SELF-INTERSECTING and zero-area rings refused
at COMPILE (the doorway — a pentagram has consistent winding and defeats
every downstream convexity/even-odd reading, cold review CPN1-S1 finding 1),
arc contours refused by every projection, simple-concave cutouts refused by
the ROUTER only (fill and DRC handle them).

Every oracle in this file was first proven interactively against the live
implementation during station S1 and its cold-review repair round (measured
numbers, not aspirations).
"""

from __future__ import annotations

import copy
import re

import pytest

from pcb_worker.compile_board import compile_board
from pcb_worker.drc_geom_primitives import point_segment_distance
from pcb_worker.drc_geometric import run_geometric_drc
from pcb_worker.gerber import build_gerbers_ir
from pcb_worker.ir_projection import (
    cutout_dicts,
    cutout_loops_from_dict,
    outline_cutouts,
    outline_frame,
    profile_outer_rect,
)
from pcb_worker.kicad import _ir_board_dict, generate_ir
from pcb_worker.resolved_board import (
    ArcGeometry,
    Contour,
    LineGeometry,
    ProfileOutline,
    RectOutline,
    ResolutionFailure,
    ResolutionSuccess,
    ResolvedCutout,
)
from pcb_worker.route_bridge import (
    UnsupportedGeometry,
    _cutout_obstacle,
    resolved_board_to_router,
)
from pcb_worker.zone_fill import ZoneFillError, fill_board_zones


# ---------------------------------------------------------------------------
# Board scaffolding — a 40x30 board with one 4x10 slot at x 18..22, y 10..20.
# ---------------------------------------------------------------------------

SLOT = [(18.0, 10.0), (22.0, 10.0), (22.0, 20.0), (18.0, 20.0)]


def _board(**overrides) -> dict:
    board = {
        "version": 1, "name": "cutout-suite", "width_mm": 40, "height_mm": 30,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.25,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [
            {"ref": "C1", "footprint": "C_0805", "value": "X", "x_mm": 5,
             "y_mm": 15, "rotation_deg": 0, "layer": "top",
             "pins": [{"number": "1", "name": "A", "x_mm": -0.95, "y_mm": 0},
                      {"number": "2", "name": "B", "x_mm": 0.95, "y_mm": 0}]},
            {"ref": "C2", "footprint": "C_0805", "value": "X", "x_mm": 35,
             "y_mm": 15, "rotation_deg": 0, "layer": "top",
             "pins": [{"number": "1", "name": "A", "x_mm": -0.95, "y_mm": 0},
                      {"number": "2", "name": "B", "x_mm": 0.95, "y_mm": 0}]},
        ],
        "nets": [{"name": "N1", "pins": ["C1.2", "C2.1"]}],
        "cutouts": [{"id": "slot1", "outline": [
            {"x_mm": x, "y_mm": y} for (x, y) in SLOT]}],
    }
    board.update(overrides)
    return board


def _compiled(board: dict):
    result = compile_board(board)
    assert isinstance(result, ResolutionSuccess), \
        [(d.code, d.message) for d in result.diagnostics]
    return result.board


def _error_codes(result) -> list[str]:
    assert isinstance(result, ResolutionFailure)
    return [d.code for d in result.diagnostics if d.severity == "error"]


def _slot_contour(points=SLOT) -> Contour:
    count = len(points)
    return Contour(segments=tuple(
        LineGeometry(points[i], points[(i + 1) % count]) for i in range(count)))


# ---------------------------------------------------------------------------
# 1. Compile: cutouts land in the IR.
# ---------------------------------------------------------------------------


class TestCompile:
    def test_cutout_board_compiles_to_profile_outline(self):
        rb = _compiled(_board())
        assert isinstance(rb.outline, ProfileOutline)
        assert len(rb.outline.cutouts) == 1
        cut = rb.outline.cutouts[0]
        assert isinstance(cut, ResolvedCutout)
        assert len(cut.contour.segments) == 4
        # The outer contour is the same rim rectangle a cutout-less board gets.
        assert profile_outer_rect(rb.outline) == (0.0, 0.0, 40.0, 30.0)

    def test_cutout_less_board_still_compiles_to_rect_outline(self):
        board = _board()
        del board["cutouts"]
        rb = _compiled(board)
        assert isinstance(rb.outline, RectOutline)

    def test_empty_cutouts_list_declares_nothing(self):
        rb = _compiled(_board(cutouts=[]))
        assert isinstance(rb.outline, RectOutline)

    def test_cutout_id_is_board_namespaced_and_stable(self):
        rb1 = _compiled(_board())
        rb2 = _compiled(_board())
        assert rb1.outline.cutouts[0].id == rb2.outline.cutouts[0].id
        assert rb1.outline.cutouts[0].id  # non-empty

    def test_vertex_outside_rim_refuses(self):
        board = _board(cutouts=[{"id": "slot1", "outline": [
            {"x_mm": 38, "y_mm": 10}, {"x_mm": 42, "y_mm": 10},
            {"x_mm": 42, "y_mm": 20}, {"x_mm": 38, "y_mm": 20}]}])
        assert "invalid_cutout_outline" in _error_codes(compile_board(board))

    def test_vertex_on_rim_is_a_notch_and_refuses(self):
        board = _board(cutouts=[{"id": "slot1", "outline": [
            {"x_mm": 18, "y_mm": 0}, {"x_mm": 22, "y_mm": 0},
            {"x_mm": 22, "y_mm": 20}, {"x_mm": 18, "y_mm": 20}]}])
        assert "invalid_cutout_outline" in _error_codes(compile_board(board))

    def test_overlapping_cutout_bounding_boxes_refuse(self):
        board = _board()
        board["cutouts"].append({"id": "slot2", "outline": [
            {"x_mm": 20, "y_mm": 12}, {"x_mm": 26, "y_mm": 12},
            {"x_mm": 26, "y_mm": 18}, {"x_mm": 20, "y_mm": 18}]})
        assert "invalid_cutout_outline" in _error_codes(compile_board(board))

    def test_disjoint_cutouts_both_compile(self):
        board = _board()
        board["cutouts"].append({"id": "slot2", "outline": [
            {"x_mm": 26, "y_mm": 12}, {"x_mm": 30, "y_mm": 12},
            {"x_mm": 30, "y_mm": 18}, {"x_mm": 26, "y_mm": 18}]})
        rb = _compiled(board)
        assert len(rb.outline.cutouts) == 2

    def test_two_point_ring_refuses(self):
        board = _board(cutouts=[{"id": "slot1", "outline": [
            {"x_mm": 18, "y_mm": 10}, {"x_mm": 22, "y_mm": 10}]}])
        assert "invalid_cutout_outline" in _error_codes(compile_board(board))

    def test_repeated_adjacent_point_refuses(self):
        board = _board(cutouts=[{"id": "slot1", "outline": [
            {"x_mm": 18, "y_mm": 10}, {"x_mm": 18, "y_mm": 10},
            {"x_mm": 22, "y_mm": 10}, {"x_mm": 20, "y_mm": 20}]}])
        assert "invalid_cutout_outline" in _error_codes(compile_board(board))

    def test_explicitly_closed_ring_folds_to_implicit(self):
        board = _board(cutouts=[{"id": "slot1", "outline": [
            {"x_mm": x, "y_mm": y} for (x, y) in SLOT + [SLOT[0]]]}])
        rb = _compiled(board)
        assert len(rb.outline.cutouts[0].contour.segments) == 4

    def test_pentagram_ring_refuses(self):
        """Cold review finding 1: a star traversal has CONSISTENT winding (all
        same-sign consecutive crosses) and its core reads as OUTSIDE to an
        even-odd test — before this gate it compiled, defeated the router's
        convexity check, hid core copper from GC5, and shipped a self-crossing
        Edge.Cuts contour. Refused at the doorway now."""
        import math
        star = []
        for k in range(5):
            ang = math.pi / 2 + k * 4 * math.pi / 5
            star.append((20 + 8 * math.cos(ang), 15 + 8 * math.sin(ang)))
        board = _board(cutouts=[{"id": "s", "outline": [
            {"x_mm": x, "y_mm": y} for (x, y) in star]}])
        assert "invalid_cutout_outline" in _error_codes(compile_board(board))

    def test_bowtie_ring_refuses(self):
        board = _board(cutouts=[{"id": "b", "outline": [
            {"x_mm": 15, "y_mm": 10}, {"x_mm": 25, "y_mm": 20},
            {"x_mm": 25, "y_mm": 10}, {"x_mm": 15, "y_mm": 20}]}])
        assert "invalid_cutout_outline" in _error_codes(compile_board(board))

    def test_collinear_zero_area_sliver_refuses(self):
        """Finding 3: (12,12)-(18,12)-(15,12) encloses nothing; emitted it
        would be a zero-width slit whose degenerate router 'inflation'
        reserves only one side — a routed board failing its own GC5."""
        board = _board(cutouts=[{"id": "c", "outline": [
            {"x_mm": 12, "y_mm": 12}, {"x_mm": 18, "y_mm": 12},
            {"x_mm": 15, "y_mm": 12}]}])
        assert "invalid_cutout_outline" in _error_codes(compile_board(board))

    def test_duplicate_authored_ids_refuse(self):
        """v1 boards derive ids from the authored id; two cutouts authoring
        the same id would silently alias identity (v2 has the minted gate)."""
        board = _board(cutouts=[
            {"id": "dup", "outline": [
                {"x_mm": 12, "y_mm": 12}, {"x_mm": 15, "y_mm": 12},
                {"x_mm": 15, "y_mm": 15}, {"x_mm": 12, "y_mm": 15}]},
            {"id": "dup", "outline": [
                {"x_mm": 25, "y_mm": 12}, {"x_mm": 28, "y_mm": 12},
                {"x_mm": 28, "y_mm": 15}, {"x_mm": 25, "y_mm": 15}]}])
        assert "invalid_cutout_outline" in _error_codes(compile_board(board))


# ---------------------------------------------------------------------------
# 2. ir_projection: the strict frame (bug 019fbd30f7's oracle) + helpers.
# ---------------------------------------------------------------------------


class TestProjection:
    def test_rect_outer_profile_frames_faithfully(self):
        rb = _compiled(_board())
        assert outline_frame(rb.outline) == (0.0, 0.0, 40.0, 30.0)

    def test_non_rect_outer_raises_never_bbox(self):
        # The 019fbd30f7 oracle verbatim: faithful frame or a raised refusal,
        # never a silent bounding box. A triangular outer has a bbox; asking
        # for its frame must raise.
        tri = ProfileOutline(outer=Contour(segments=(
            LineGeometry((0.0, 0.0), (40.0, 0.0)),
            LineGeometry((40.0, 0.0), (20.0, 30.0)),
            LineGeometry((20.0, 30.0), (0.0, 0.0)))))
        with pytest.raises(ValueError, match="019fbd30f7"):
            outline_frame(tri)
        assert profile_outer_rect(tri) is None

    def test_diagonal_quad_outer_is_not_a_rect(self):
        quad = ProfileOutline(outer=Contour(segments=(
            LineGeometry((0.0, 0.0), (40.0, 2.0)),
            LineGeometry((40.0, 2.0), (40.0, 30.0)),
            LineGeometry((40.0, 30.0), (0.0, 28.0)),
            LineGeometry((0.0, 28.0), (0.0, 0.0)))))
        assert profile_outer_rect(quad) is None

    def test_outline_cutouts_empty_for_rect(self):
        assert outline_cutouts(RectOutline(origin=(0.0, 0.0),
                                           width_mm=10.0, height_mm=10.0)) == ()

    def test_cutout_dicts_round_canonical_shape(self):
        rb = _compiled(_board())
        dicts = cutout_dicts(rb.outline)
        assert len(dicts) == 1
        assert dicts[0]["outline"][0] == {"x_mm": 18.0, "y_mm": 10.0}
        # The canonical dict shape parses straight back through the loose parser.
        loops = cutout_loops_from_dict({"cutouts": dicts})
        assert loops[0][1] == SLOT

    def test_loose_parser_raises_on_malformed_entry(self):
        with pytest.raises(ValueError):
            cutout_loops_from_dict({"cutouts": [{"outline": "nope"}]})
        with pytest.raises(ValueError):
            cutout_loops_from_dict({"cutouts": [{"outline": [
                {"x_mm": 1, "y_mm": 2}, {"x_mm": 3}]}]})
        with pytest.raises(ValueError):
            cutout_loops_from_dict({"cutouts": "nope"})

    def test_arc_cutout_refused_by_fab_projection(self):
        arc_cut = ProfileOutline(
            outer=_slot_contour([(0.0, 0.0), (40.0, 0.0), (40.0, 30.0), (0.0, 30.0)]),
            cutouts=(ResolvedCutout(id="c1", contour=Contour(segments=(
                LineGeometry((18.0, 10.0), (22.0, 10.0)),
                ArcGeometry(start=(22.0, 10.0), mid=(23.0, 15.0), end=(22.0, 20.0)),
                LineGeometry((22.0, 20.0), (18.0, 20.0)),
                LineGeometry((18.0, 20.0), (18.0, 10.0))))),))
        with pytest.raises(ValueError, match="straight-edged"):
            cutout_dicts(arc_cut)


# ---------------------------------------------------------------------------
# 3. Emitters: the opening reaches both fabrication surfaces.
# ---------------------------------------------------------------------------


class TestEmitters:
    def test_gerber_edge_cuts_carries_slot_contour(self):
        rb = _compiled(_board())
        files = build_gerbers_ir(rb)
        edge = next(text for name, text in files.items() if "Edge_Cuts" in name)
        # Slot x extents in the emitter's 1e6-scaled frame; Y is negated per
        # vertex exactly like the rim rectangle.
        assert re.search(r"X18000000", edge)
        assert re.search(r"X22000000", edge)
        assert re.search(r"Y-10000000", edge)
        assert re.search(r"Y-20000000", edge)

    def test_gerber_edge_cuts_unchanged_without_cutouts(self):
        board = _board()
        del board["cutouts"]
        rb = _compiled(board)
        files = build_gerbers_ir(rb)
        edge = next(text for name, text in files.items() if "Edge_Cuts" in name)
        assert not re.search(r"X18000000", edge)

    def test_kicad_dict_carries_canonical_cutouts(self):
        rb = _compiled(_board())
        board_dict = _ir_board_dict(rb)
        assert board_dict["cutouts"][0]["outline"][0] == {"x_mm": 18.0, "y_mm": 10.0}

    def test_kicad_sexpr_draws_closed_cutout_loop(self):
        rb = _compiled(_board())
        out = generate_ir(rb)
        text = next(v for k, v in out.items() if k.endswith(".kicad_pcb"))
        cut_lines = [ln for ln in text.splitlines()
                     if "Edge.Cuts" in ln and "gr_line" in ln
                     and ("start 18.0" in ln or "start 22.0" in ln)]
        # Four segments: (18,10)->(22,10)->(22,20)->(18,20)->closed.
        assert len(cut_lines) == 4


# ---------------------------------------------------------------------------
# 4. Geometric DRC: GC5 vs cutout edges.
# ---------------------------------------------------------------------------


class TestDrc:
    def test_trace_crossing_slot_violates(self):
        board = _board(traces=[{"net": "N1", "layer": "top", "width_mm": 0.25,
                                "points": [{"x_mm": 5.95, "y_mm": 15},
                                           {"x_mm": 34.05, "y_mm": 15}]}])
        drc = run_geometric_drc(_compiled(board))
        assert drc["verdict"] == "violations"
        gc5 = [f for f in drc["findings"] if f["type"] == "gc5_copper_to_edge"]
        assert len(gc5) == 1
        finding = gc5[0]
        # A crossing measures <= 0 and the witness sits on the slot contour.
        assert finding["measured_mm"] <= 0.0
        wx, wy = finding["witness"]
        assert wx in (18.0, 22.0) and 10.0 <= wy <= 20.0

    def test_trace_hugging_slot_inside_band_violates_with_positive_measure(self):
        # 0.25-wide trace whose edge sits 0.175 from the slot's left edge:
        # centerline at x=17.7 -> AABB max_x 17.825, slot at 18.0.
        board = _board(traces=[{"net": "N1", "layer": "top", "width_mm": 0.25,
                                "points": [{"x_mm": 17.7, "y_mm": 12},
                                           {"x_mm": 17.7, "y_mm": 18}]}])
        drc = run_geometric_drc(_compiled(board))
        gc5 = [f for f in drc["findings"] if f["type"] == "gc5_copper_to_edge"]
        assert len(gc5) == 1
        assert 0.0 < gc5[0]["measured_mm"] < 0.3

    def test_distant_trace_clean(self):
        board = _board(traces=[{"net": "N1", "layer": "top", "width_mm": 0.25,
                                "points": [{"x_mm": 5.95, "y_mm": 27},
                                           {"x_mm": 34.05, "y_mm": 27}]}])
        drc = run_geometric_drc(_compiled(board))
        assert drc["verdict"] == "clean"

    def test_cutout_board_is_determinate(self):
        # The old guard made ANY non-RectOutline indeterminate; a rect-outer
        # profile must now be checked, not refused.
        drc = run_geometric_drc(_compiled(_board()))
        assert drc["verdict"] in ("clean", "violations")
        assert drc["verdict"] == "clean"


# ---------------------------------------------------------------------------
# 5. Routing: the cutout is an obstacle the grid genuinely sees.
# ---------------------------------------------------------------------------


class TestRouting:
    def test_router_board_carries_pre_inflated_cutout_obstacle(self):
        board = resolved_board_to_router(_compiled(_board()))
        cuts = [o for o in board.obstacles if o.type == "cutout"]
        assert len(cuts) == 1
        obstacle = cuts[0]
        assert obstacle.blocks_all_layers is True
        assert obstacle.layer is None
        # copper_to_edge floor is 0.3 -> the 18..22 x 10..20 slot inflates to
        # 17.7..22.3 x 9.7..20.3 (measured during S1).
        rounded = [(round(x, 3), round(y, 3)) for (x, y) in obstacle.polygon]
        assert rounded == [(17.7, 9.7), (22.3, 9.7), (22.3, 20.3), (17.7, 20.3)]

    def test_concave_cutout_refused_by_router_projection(self):
        concave = ResolvedCutout(id="c1", contour=_slot_contour(
            [(18.0, 10.0), (22.0, 10.0), (22.0, 20.0), (20.0, 14.0), (18.0, 20.0)]))
        with pytest.raises(UnsupportedGeometry, match="concave"):
            _cutout_obstacle(concave, 0.3)

    def test_arc_cutout_refused_by_router_projection(self):
        arc = ResolvedCutout(id="c1", contour=Contour(segments=(
            LineGeometry((18.0, 10.0), (22.0, 10.0)),
            ArcGeometry(start=(22.0, 10.0), mid=(23.0, 15.0), end=(22.0, 20.0)),
            LineGeometry((22.0, 20.0), (18.0, 20.0)),
            LineGeometry((18.0, 20.0), (18.0, 10.0)))))
        with pytest.raises(UnsupportedGeometry, match="straight-edged"):
            _cutout_obstacle(arc, 0.3)

    def test_zero_inflation_keeps_original_polygon(self):
        cut = ResolvedCutout(id="c1", contour=_slot_contour())
        obstacle = _cutout_obstacle(cut, 0.0)
        rounded = [(round(x, 3), round(y, 3)) for (x, y) in obstacle.polygon]
        assert rounded == [(round(x, 3), round(y, 3)) for (x, y) in SLOT]


# ---------------------------------------------------------------------------
# 6. Zone fill: pours carve the opening plus the copper-to-edge band.
# ---------------------------------------------------------------------------


def _pour_board() -> dict:
    return _board(zones=[{"id": "z1", "net": "N1", "layer": "bottom",
                          "kind": "copper_pour",
                          "outline": [{"x_mm": 2, "y_mm": 2}, {"x_mm": 38, "y_mm": 2},
                                      {"x_mm": 38, "y_mm": 28},
                                      {"x_mm": 2, "y_mm": 28}]}])


def _point_in_poly(x: float, y: float, points) -> bool:
    inside = False
    count = len(points)
    for i in range(count):
        x1, y1 = points[i]
        x2, y2 = points[(i + 1) % count]
        if (y1 > y) != (y2 > y) and x < x1 + (y - y1) * (x2 - x1) / (y2 - y1):
            inside = not inside
    return inside


class TestZoneFill:
    def test_pour_carves_the_slot_not_just_its_vertices(self):
        """Cold review finding 2 killed the first version of this test: a
        vertex-only oracle passes even if the carve is deleted (an uncarved
        rectangle's four vertices all sit far from the slot). The load-bearing
        assertions are COVERAGE ones: the slot's centre and its band are not
        inside any fill region, and the fill area is smaller than the
        uncarved bound by at least the slot+band area."""
        rb = _compiled(_pour_board())
        filled = rb if rb.zones[0].fill is not None else fill_board_zones(rb)
        zone = filled.zones[0]
        assert zone.fill is not None and len(zone.fill) >= 1

        # 1. The slot centre and points just inside the band are NOT covered.
        for probe in ((20.0, 15.0),            # slot centre
                      (18.05, 15.0),           # inside the opening
                      (17.75, 15.0),           # inside the 0.3 band
                      (20.0, 20.25)):          # band above the slot
            covered = any(_point_in_poly(*probe, poly.points)
                          for poly in zone.fill)
            assert not covered, f"fill covers {probe}, inside the slot/band"

        # 2. Points clearly outside the band ARE covered (the carve did not
        #    eat the whole pour).
        for probe in ((10.0, 15.0), (30.0, 15.0), (20.0, 25.0)):
            assert any(_point_in_poly(*probe, poly.points)
                       for poly in zone.fill), f"fill missing at {probe}"

        # 3. Area: the pour outline (36x26 = 936 mm^2, already inside the rim
        #    inset) is the uncarved bound; the slot+band alone removes
        #    ~4.6x10.6 = 48.76 mm^2 (round joins shave the corners slightly).
        #    Measured live during the repair round: 887.32 mm^2.
        from pcb_worker.zone_fill import fill_area_mm2
        assert fill_area_mm2(zone) <= 936.0 - 48.0

        # 4. Vertex-distance floor (the original oracle, kept as a supplement).
        def dist_to_slot(x: float, y: float) -> float:
            return min(point_segment_distance(x, y, *SLOT[i], *SLOT[(i + 1) % 4])
                       for i in range(4))

        floor = rb.design_rules.minimums.copper_to_edge_mm
        for poly in zone.fill:
            for (x, y) in poly.points:
                assert not (18.0 < x < 22.0 and 10.0 < y < 20.0), (x, y)
                assert dist_to_slot(x, y) >= floor - 1e-5, (x, y)

    def test_arc_cutout_refuses_fill(self):
        rb = _compiled(_pour_board())
        arc_outline = ProfileOutline(
            outer=rb.outline.outer,
            cutouts=(ResolvedCutout(id="c1", contour=Contour(segments=(
                LineGeometry((18.0, 10.0), (22.0, 10.0)),
                ArcGeometry(start=(22.0, 10.0), mid=(23.0, 15.0), end=(22.0, 20.0)),
                LineGeometry((22.0, 20.0), (18.0, 20.0)),
                LineGeometry((18.0, 20.0), (18.0, 10.0))))),))
        from dataclasses import replace
        broken = replace(rb, outline=arc_outline,
                         zones=tuple(replace(z, fill=None) for z in rb.zones))
        with pytest.raises(ZoneFillError):
            fill_board_zones(broken)


# ---------------------------------------------------------------------------
# 7. Cold-review repair rows: containment, concave handlers, multi-cutout,
#    parity family, end-to-end route.
# ---------------------------------------------------------------------------


L_CUTOUT = [(14.0, 8.0), (26.0, 8.0), (26.0, 22.0), (22.0, 22.0),
            (22.0, 12.0), (14.0, 12.0)]  # simple concave L, strictly interior


class TestDrcRepairRows:
    def test_copper_swallowed_by_cutout_measures_negative(self):
        """The containment branch of _aabb_loop_clearance: a trace strictly
        inside the opening (its AABB swallowed by the loop) must report a
        NEGATIVE measured value, not a distance to the far edge."""
        board = _board(traces=[{"net": "N1", "layer": "top", "width_mm": 0.25,
                                "points": [{"x_mm": 19, "y_mm": 14},
                                           {"x_mm": 21, "y_mm": 16}]}])
        drc = run_geometric_drc(_compiled(board))
        gc5 = [f for f in drc["findings"] if f["type"] == "gc5_copper_to_edge"]
        assert len(gc5) == 1
        assert gc5[0]["measured_mm"] < 0.0

    def test_gc5_cutout_finding_names_the_cutout(self):
        """Review finding 4: on a multi-cutout board the witness coordinates
        alone cannot say which slot; the finding carries against_entity_id
        (the GC7 pattern), and it names the VIOLATED cutout."""
        board = _board()
        board["cutouts"].append({"id": "slot2", "outline": [
            {"x_mm": 28, "y_mm": 22}, {"x_mm": 32, "y_mm": 22},
            {"x_mm": 32, "y_mm": 26}, {"x_mm": 28, "y_mm": 26}]})
        board["traces"] = [{"net": "N1", "layer": "top", "width_mm": 0.25,
                            "points": [{"x_mm": 5.95, "y_mm": 15},
                                       {"x_mm": 34.05, "y_mm": 15}]}]
        rb = _compiled(board)
        slot1_id = rb.outline.cutouts[0].id
        drc = run_geometric_drc(rb)
        gc5 = [f for f in drc["findings"] if f["type"] == "gc5_copper_to_edge"]
        assert len(gc5) == 1  # the trace crosses slot1 only
        assert gc5[0]["against_entity_id"] == slot1_id

    def test_concave_cutout_notch_copper_is_clean_not_bbox_flagged(self):
        """The docstring claim 'fill and DRC handle concave', made precise: a
        trace in the L's NOTCH sits inside the cutout's BOUNDING BOX but
        outside the polygon, 1.875 mm from the nearest L edge (x=22 arm) —
        far beyond the 0.3 rule. A bbox-based checker would flag it; the
        polygon-exact check must return a determinate CLEAN."""
        board = _board(cutouts=[{"id": "ell", "outline": [
            {"x_mm": x, "y_mm": y} for (x, y) in L_CUTOUT]}])
        board["traces"] = [{"net": "N1", "layer": "top", "width_mm": 0.25,
                            "points": [{"x_mm": 15, "y_mm": 15},
                                       {"x_mm": 20, "y_mm": 15}]}]
        drc = run_geometric_drc(_compiled(board))
        assert drc["verdict"] == "clean"

    def test_concave_cutout_arm_copper_violates_with_attribution(self):
        """And the converse: copper crossing the L's bottom arm violates,
        determinately, naming the cutout."""
        board = _board(cutouts=[{"id": "ell", "outline": [
            {"x_mm": x, "y_mm": y} for (x, y) in L_CUTOUT]}])
        board["traces"] = [{"net": "N1", "layer": "top", "width_mm": 0.25,
                            "points": [{"x_mm": 15, "y_mm": 10},
                                       {"x_mm": 25, "y_mm": 10}]}]
        rb = _compiled(board)
        drc = run_geometric_drc(rb)
        gc5 = [f for f in drc["findings"] if f["type"] == "gc5_copper_to_edge"]
        assert len(gc5) == 1
        assert gc5[0]["against_entity_id"] == rb.outline.cutouts[0].id
        assert gc5[0]["measured_mm"] < 0.3


class TestZoneFillRepairRows:
    def test_concave_cutout_fill_carves_polygon_not_bbox(self):
        """Fill must carve the L POLYGON, not its bounding box: copper in the
        notch (inside bbox, outside polygon, > band from every edge) stays."""
        board = _pour_board()
        board["cutouts"] = [{"id": "ell", "outline": [
            {"x_mm": x, "y_mm": y} for (x, y) in L_CUTOUT]}]
        rb = _compiled(board)
        filled = rb if rb.zones[0].fill is not None else fill_board_zones(rb)
        zone = filled.zones[0]
        # Inside the L's arm -> carved.
        assert not any(_point_in_poly(20.0, 10.0, poly.points)
                       for poly in zone.fill)
        # In the notch, > 0.3 from the nearest L edge (e.g. (17, 16): 4.0 from
        # y=12 arm, 5.0 from x=22 arm... use (17, 16)) -> covered.
        assert any(_point_in_poly(17.0, 16.0, poly.points)
                   for poly in zone.fill)

    def test_multi_cutout_fill_carves_both(self):
        board = _pour_board()
        board["cutouts"].append({"id": "slot2", "outline": [
            {"x_mm": 28, "y_mm": 22}, {"x_mm": 32, "y_mm": 22},
            {"x_mm": 32, "y_mm": 26}, {"x_mm": 28, "y_mm": 26}]})
        rb = _compiled(board)
        filled = rb if rb.zones[0].fill is not None else fill_board_zones(rb)
        zone = filled.zones[0]
        for centre in ((20.0, 15.0), (30.0, 24.0)):
            assert not any(_point_in_poly(*centre, poly.points)
                           for poly in zone.fill), centre


class TestLooseParserRepairRows:
    def test_two_element_list_point_form_parses(self):
        loops = cutout_loops_from_dict({"cutouts": [
            {"id": "c", "outline": [[18, 10], [22, 10], [22, 20]]}]})
        assert loops == [("c", [(18.0, 10.0), (22.0, 10.0), (22.0, 20.0)])]


class TestParity:
    def test_cutout_family_agrees_across_all_three_surfaces(self):
        """Review finding 5: the outline family is bbox-only, so an emitter
        silently dropping a cutout was invisible to parity. The cutout family
        keys each interior loop by bbox; IR, kicad and gerber must produce
        identical row sets (proven live: both slots, segment_count 4)."""
        from pcb_worker import ir_parity
        board = _board()
        board["cutouts"].append({"id": "slot2", "outline": [
            {"x_mm": 28, "y_mm": 22}, {"x_mm": 32, "y_mm": 22},
            {"x_mm": 32, "y_mm": 26}, {"x_mm": 28, "y_mm": 26}]})
        rb = _compiled(board)
        expected = {((18.0, 10.0, 22.0, 20.0), (("segment_count", 4),)),
                    ((28.0, 22.0, 32.0, 26.0), (("segment_count", 4),))}
        for table in (ir_parity.tabulate_ir(rb), ir_parity.tabulate_kicad(rb),
                      ir_parity.tabulate_gerber(rb)):
            rows = {(r.key, r.fields) for r in table.rows if r.family == "cutout"}
            assert rows == expected, table.surface

    def test_diff_catches_a_dropped_cutout(self):
        """The seal itself: an emitter that loses a cutout must FAIL the diff
        against the IR reference (simulated by diffing the two-cutout IR
        against the one-cutout board's kicad surface)."""
        from pcb_worker import ir_parity
        two = _board()
        two["cutouts"].append({"id": "slot2", "outline": [
            {"x_mm": 28, "y_mm": 22}, {"x_mm": 32, "y_mm": 22},
            {"x_mm": 32, "y_mm": 26}, {"x_mm": 28, "y_mm": 26}]})
        rb_two = _compiled(two)
        rb_one = _compiled(_board())
        deltas = ir_parity.diff_against_reference(
            ir_parity.tabulate_ir(rb_two), ir_parity.tabulate_kicad(rb_one))
        cutout_deltas = [d for d in deltas if d.family == "cutout"]
        assert cutout_deltas, "a dropped cutout must produce a cutout-family delta"
        assert any(d.kind == "missing_row" for d in cutout_deltas)


class TestRouteEndToEnd:
    def test_route_detours_around_the_slot_and_passes_gc5(self):
        """Review row (c): not just obstacle construction — an actual routed
        net. C1->C2 crosses the slot straight-line; the router must detour
        (no route point inside the slot or its reserved band) and the result
        must be a route the DRC's own cutout rule would accept for the
        centerline (band = 0.3 copper_to_edge + 0.125 half-width)."""
        from agent_router.router import route_board
        board = resolved_board_to_router(_compiled(_board()))
        result = route_board(board, trace_width=0.25, clearance=0.2,
                             grid_resolution=0.1)
        n1 = [r for r in result.routes if r.net == "N1"]
        assert n1, "an open corridor exists above and below the slot; must route"
        # DRC-legality band for the CENTERLINE: 0.3 copper_to_edge + 0.125
        # half-width. The router actually reserves more (0.3 pre-inflation +
        # grid margin of clearance + half-width), so this asserts the DRC
        # bound with margin to spare. Segments are SAMPLED, not
        # endpoint-checked — a straight segment could cross the slot with
        # both endpoints outside it.
        import math as _math
        band = 0.3 + 0.125
        for route in n1:
            for seg in route.segments:
                (x0, y0), (x1, y1) = seg.start, seg.end
                span = _math.hypot(x1 - x0, y1 - y0)
                steps = max(1, int(span / 0.1))
                for i in range(steps + 1):
                    t = i / steps
                    x, y = x0 + (x1 - x0) * t, y0 + (y1 - y0) * t
                    inside = (18.0 - band < x < 22.0 + band
                              and 10.0 - band < y < 20.0 + band)
                    assert not inside, f"route point ({x}, {y}) inside slot band"

    def test_loose_route_bridge_refuses_cutout_boards(self):
        """The loose dict entry (board_to_router) models mounting-hole
        obstacles only; a cutouts board must REFUSE there, never route as if
        the opening did not exist (production routing is the compiled path)."""
        from pcb_worker.route_bridge import board_to_router
        with pytest.raises(UnsupportedGeometry, match="cutouts"):
            board_to_router(_board())
