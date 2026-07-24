"""Unit tests for the pure geometric copper DRC (facet 2, Round C1).

Design of record: docket 019f952306f9. Covers GC1/GC3/GC4/GC6 with
below/equal/above-threshold triples, a rotated pad fixture, the DRY land-owner
contract, the exact-at-threshold epsilon policy, a clean board, and the
fail-closed (indeterminate) envelopes. Boards are hand-authored and driven
through ``compile_board`` so the fixtures are real ResolvedBoards.
"""

from __future__ import annotations

import dataclasses
import math

import pytest

from pcb_worker.compile_board import compile_board
from pcb_worker.drc_geom_primitives import (
    Capsule,
    OrientedRect,
    capsule_edge_distance,
    segment_segment_distance,
)
from pcb_worker.drc_geometric import (
    geometric_drc_from_resolution,
    project_board,
    run_geometric_drc,
)
from pcb_worker.resolved_board import (
    Contour,
    DiagnosticSeverity,
    HoleKind,
    Layer,
    LineGeometry,
    OvalHole,
    ProfileOutline,
    ResolutionFailure,
    ResolutionSuccess,
    ResolvedHole,
    ResolvedZone,
    ZoneKind,
)


# ---------------------------------------------------------------------------
# Board builders.
# ---------------------------------------------------------------------------


def _base(**extra) -> dict:
    board = {
        "version": 1, "name": "brd", "width_mm": 40, "height_mm": 40,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [],
    }
    board.update(extra)
    return board


def _compile(board: dict):
    result = compile_board(board)
    assert isinstance(result, ResolutionSuccess), [
        d.code for d in result.diagnostics
        if d.severity is DiagnosticSeverity.ERROR]
    return result.board


def _th_pad_comp(ref="U1", x=10.0, y=10.0, rot=0.0, drill=0.5, annulus=1.2):
    return {"ref": ref, "footprint": "TH_TestPoint", "x_mm": x, "y_mm": y,
            "rotation_deg": rot, "layer": "top",
            "pins": [{"number": "1", "x_mm": 0, "y_mm": 0,
                      "drill_mm": drill, "annulus_diameter_mm": annulus}]}


def _trace(width, net="N", a=(10.0, 10.0), b=(20.0, 10.0)):
    return {"net": net, "layer": "top", "width_mm": width,
            "points": [{"x_mm": a[0], "y_mm": a[1]},
                       {"x_mm": b[0], "y_mm": b[1]}]}


def _run(board: dict) -> dict:
    return run_geometric_drc(_compile(board))


def _counts(res: dict, rule: str) -> int:
    return res["counts"][rule]


def _findings(res: dict, rule: str) -> list[dict]:
    return [f for f in res["findings"] if f["type"] == rule]


# ---------------------------------------------------------------------------
# Determinate clean baseline + result-union shape.
# ---------------------------------------------------------------------------


def test_clean_board_is_determinate_clean_with_zero_counts():
    board = _base(
        components=[_th_pad_comp(annulus=1.6),
                    {"ref": "R1", "footprint": "R_0805", "x_mm": 25, "y_mm": 25,
                     "rotation_deg": 0, "layer": "top"}],
        nets=[{"name": "N", "pins": ["U1.1", "R1.1"]}],
        traces=[_trace(0.3)])
    res = _run(board)
    assert res["ok"] is True
    assert res["scope"] == "geometric"
    assert res["verifies_geometry"] is True
    assert res["verdict"] == "clean"
    assert res["findings"] == []
    assert all(v == 0 for v in res["counts"].values())


def test_determinate_result_carries_board_identity_and_rule_profile():
    board = _base(components=[_th_pad_comp(annulus=1.6)])
    rb = _compile(board)
    res = run_geometric_drc(rb)
    assert res["board_id"] == rb.id
    assert res["source_digest"] == rb.provenance.source_digest
    prof = rb.design_rules.rule_profile
    assert res["rule_profile"] == {
        "id": prof.id, "version": prof.version, "digest": prof.digest}


def test_success_surfaces_compile_warnings_via_adapter():
    board = _base(components=[_th_pad_comp(annulus=1.6)])
    result = compile_board(board)
    res = geometric_drc_from_resolution(result)
    assert res["ok"] is True
    assert "warnings" in res and isinstance(res["warnings"], list)


# ---------------------------------------------------------------------------
# GC1 min trace width — below / equal / above.
# ---------------------------------------------------------------------------


def _trace_board(width):
    return _base(
        components=[_th_pad_comp(annulus=1.6),
                    {"ref": "R1", "footprint": "R_0805", "x_mm": 25, "y_mm": 25,
                     "rotation_deg": 0, "layer": "top"}],
        nets=[{"name": "N", "pins": ["U1.1", "R1.1"]}],
        traces=[_trace(width)])


def test_gc1_trace_below_threshold_flags():
    res = _run(_trace_board(0.1))
    assert res["verdict"] == "violations"
    assert _counts(res, "gc1_trace_width") == 1
    f = _findings(res, "gc1_trace_width")[0]
    assert f["measured_mm"] == 0.1
    assert f["required_mm"] == pytest.approx(0.127)
    assert f["kind"] == "trace_seg"


def test_gc1_trace_at_threshold_passes():
    # exact-at-threshold PASSES per the epsilon policy (measured == required).
    res = _run(_trace_board(0.127))
    assert _counts(res, "gc1_trace_width") == 0


def test_gc1_trace_above_threshold_passes():
    res = _run(_trace_board(0.3))
    assert _counts(res, "gc1_trace_width") == 0


# ---------------------------------------------------------------------------
# GC3 drill / finished hole — below / equal / above.
# ---------------------------------------------------------------------------


def test_gc3_pad_drill_below_threshold_flags():
    # drill 0.15 < min_drill 0.2 (annulus kept large so GC4 stays clean).
    res = _run(_base(components=[_th_pad_comp(drill=0.15, annulus=1.6)]))
    assert _counts(res, "gc3_drill") == 1
    f = _findings(res, "gc3_drill")[0]
    assert f["measured_mm"] == 0.15
    assert f["required_mm"] == pytest.approx(0.2)


def test_gc3_pad_drill_at_threshold_passes():
    res = _run(_base(components=[_th_pad_comp(drill=0.2, annulus=1.6)]))
    assert _counts(res, "gc3_drill") == 0


def test_gc3_pad_drill_above_threshold_passes():
    res = _run(_base(components=[_th_pad_comp(drill=0.5, annulus=1.6)]))
    assert _counts(res, "gc3_drill") == 0


def test_gc3_via_drill_below_threshold_flags():
    board = _base(
        components=[_th_pad_comp(annulus=1.6)],
        nets=[{"name": "N", "pins": ["U1.1"]}],
        vias=[{"net": "N", "x_mm": 30, "y_mm": 30, "diameter_mm": 0.8,
               "drill_mm": 0.15, "from_layer": "top", "to_layer": "bottom"}])
    res = _run(board)
    f = _findings(res, "gc3_drill")
    assert any(x["kind"] == "via" and x["measured_mm"] == 0.15 for x in f)


def test_gc3_finished_hole_flags_plated_hole_between_floors():
    # The v1 floor sets min_finished == min_drill, so the finished-hole branch is
    # dormant by default. Raise min_finished above min_drill (a profile floor) and a
    # PLATED hole whose drill clears min_drill but sits below min_finished must flag
    # gc3_finished_hole — the necessary-condition check (finished <= drill, so
    # drill < min_finished guarantees a real finished-bore violation).
    rb = _compile(_base(
        components=[{"ref": "R1", "footprint": "R_0805", "x_mm": 5, "y_mm": 5,
                     "rotation_deg": 0, "layer": "top"}],
        pth_holes=[{"x_mm": 20, "y_mm": 20, "diameter_mm": 0.5, "annulus_mm": 1.5}]))
    mins = dataclasses.replace(rb.design_rules.minimums, min_finished_hole_mm=0.6)
    dr = dataclasses.replace(rb.design_rules, minimums=mins)
    res = run_geometric_drc(dataclasses.replace(rb, design_rules=dr))
    assert _counts(res, "gc3_drill") == 0            # 0.5 >= min_drill 0.2
    assert _counts(res, "gc3_finished_hole") == 1    # 0.5 < min_finished 0.6, plated
    f = _findings(res, "gc3_finished_hole")[0]
    assert f["measured_mm"] == pytest.approx(0.5)
    assert f["required_mm"] == pytest.approx(0.6)


def test_gc3_oval_hole_uses_minor_dimension():
    # Swap in an oval board hole whose MINOR width is sub-min; the limiting
    # dimension (0.15), not the major (0.5), governs GC3.
    rb = _compile(_base(components=[_th_pad_comp(annulus=1.6)]))
    oval = ResolvedHole(
        id="hole:oval", feature=OvalHole(position=(30.0, 30.0), width_mm=0.5,
                                         height_mm=0.15, rotation_deg=0.0),
        plated=False, kind=HoleKind.NPTH)
    rb2 = dataclasses.replace(rb, holes=(oval,))
    res = run_geometric_drc(rb2)
    f = _findings(res, "gc3_drill")
    assert len(f) == 1 and f[0]["measured_mm"] == 0.15


# ---------------------------------------------------------------------------
# GC4 annular ring — below / equal / above (+ DRY land owner).
# ---------------------------------------------------------------------------


def test_gc4_below_threshold_flags_each_layer():
    # ring = (annulus - drill)/2 = (0.7 - 0.5)/2 = 0.1 < 0.13; PTH pad spans
    # both copper layers -> one finding per participating layer.
    res = _run(_base(components=[_th_pad_comp(drill=0.5, annulus=0.7)]))
    assert _counts(res, "gc4_annular_ring") == 2
    f = _findings(res, "gc4_annular_ring")[0]
    assert f["measured_mm"] == pytest.approx(0.1)
    assert f["required_mm"] == pytest.approx(0.13)


def test_gc4_at_threshold_passes():
    # ring exactly 0.13: annulus - drill = 0.26 -> annulus 0.76, drill 0.5.
    res = _run(_base(components=[_th_pad_comp(drill=0.5, annulus=0.76)]))
    assert _counts(res, "gc4_annular_ring") == 0


def test_gc4_above_threshold_passes():
    res = _run(_base(components=[_th_pad_comp(drill=0.5, annulus=1.2)]))
    assert _counts(res, "gc4_annular_ring") == 0


def test_gc4_land_shape_comes_from_neutral_owner_not_footprint_size():
    # DRY PROOF (Codex #3): the TH_TestPoint footprint copper size is 1.6, which
    # would give ring (1.6-0.5)/2 = 0.55 (clean). The pin OVERRIDES the annulus to
    # 0.7 -> ring 0.1 (violation). A violation here proves GC4 took the land from
    # pad_source.placed_pad_to_geom + th_land (the emitters' land owner), NOT the
    # raw PlacedPad.size.
    res = _run(_base(components=[_th_pad_comp(drill=0.5, annulus=0.7)]))
    assert _counts(res, "gc4_annular_ring") == 2
    assert _findings(res, "gc4_annular_ring")[0]["measured_mm"] == pytest.approx(0.1)


def test_gc4_plated_board_hole_annulus():
    board = _base(
        components=[{"ref": "R1", "footprint": "R_0805", "x_mm": 5, "y_mm": 5,
                     "rotation_deg": 0, "layer": "top"}],
        pth_holes=[{"x_mm": 20, "y_mm": 20, "diameter_mm": 1.0, "annulus_mm": 1.1}])
    # ring = (1.1 - 1.0)/2 = 0.05 < 0.13 -> flagged on both copper layers.
    res = _run(board)
    f = _findings(res, "gc4_annular_ring")
    assert len(f) == 2
    assert f[0]["kind"] == "board_hole_copper"
    assert f[0]["measured_mm"] == pytest.approx(0.05)


# ---------------------------------------------------------------------------
# GC6 hole-to-hole — below / equal / above.
# ---------------------------------------------------------------------------


def _two_hole_board(second_x):
    return _base(
        components=[_th_pad_comp(x=10.0, drill=0.5, annulus=1.6)],
        mounting_holes=[{"x_mm": second_x, "y_mm": 10.0, "diameter_mm": 0.5,
                         "plated": False}])


def test_gc6_below_threshold_flags():
    # pad drill r=0.25 at x=10; mount hole r=0.25 at x=10.6 -> edge 0.1 < 0.25.
    res = _run(_two_hole_board(10.6))
    assert _counts(res, "gc6_hole_to_hole") == 1
    f = _findings(res, "gc6_hole_to_hole")[0]
    assert f["measured_mm"] == pytest.approx(0.1)
    assert f["required_mm"] == pytest.approx(0.25)


def test_gc6_at_threshold_passes():
    # centres 0.75 apart -> edge 0.75 - 0.5 = 0.25 == floor -> passes.
    res = _run(_two_hole_board(10.75))
    assert _counts(res, "gc6_hole_to_hole") == 0


def test_gc6_above_threshold_passes():
    res = _run(_two_hole_board(12.0))
    assert _counts(res, "gc6_hole_to_hole") == 0


# ---------------------------------------------------------------------------
# Rotated pad fixture.
# ---------------------------------------------------------------------------


def test_rotated_smd_pad_projects_oriented_rect_with_angle():
    board = _base(
        components=[{"ref": "R1", "footprint": "R_0805", "x_mm": 20, "y_mm": 20,
                     "rotation_deg": 45, "layer": "top"}])
    proj = project_board(_compile(board))
    rects = [c.shape for c in proj.copper
             if c.kind == "smd_pad" and isinstance(c.shape, OrientedRect)]
    assert rects, "expected a rotated SMD rectangular land"
    assert any(abs(r.angle - math.radians(45)) < 1e-9 for r in rects)


def test_rotated_th_pad_annular_ring_is_rotation_invariant():
    # A round annulus + round drill: the ring is identical at 0 and 37 degrees.
    r0 = _run(_base(components=[_th_pad_comp(rot=0, drill=0.5, annulus=0.7)]))
    r37 = _run(_base(components=[_th_pad_comp(rot=37, drill=0.5, annulus=0.7)]))
    m0 = _findings(r0, "gc4_annular_ring")[0]["measured_mm"]
    m37 = _findings(r37, "gc4_annular_ring")[0]["measured_mm"]
    assert m0 == pytest.approx(m37)


# ---------------------------------------------------------------------------
# Fail-closed / indeterminate envelopes (NO false clean).
# ---------------------------------------------------------------------------


def test_failed_compile_maps_to_indeterminate_no_clean():
    board = _base(components=[{"ref": "X1", "footprint": "NoSuchFootprint",
                              "x_mm": 10, "y_mm": 10, "rotation_deg": 0,
                              "layer": "top"}])
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    res = geometric_drc_from_resolution(result)
    assert res["ok"] is False
    assert res["verifies_geometry"] is False
    assert res["verdict"] == "indeterminate"
    assert res["error"]["kind"] == "parse"
    # NO clean/findings/zero-counts a caller could mistake for a pass.
    assert "findings" not in res
    assert "counts" not in res
    assert "verdict" in res and res["verdict"] != "clean"
    assert res["error"]["diagnostics"]


def test_non_rect_outline_is_indeterminate_unsupported_geometry():
    rb = _compile(_base(components=[_th_pad_comp(annulus=1.6)]))
    tri = Contour(segments=(
        LineGeometry((0.0, 0.0), (10.0, 0.0)),
        LineGeometry((10.0, 0.0), (5.0, 10.0)),
        LineGeometry((5.0, 10.0), (0.0, 0.0))))
    rb2 = dataclasses.replace(rb, outline=ProfileOutline(outer=tri))
    res = run_geometric_drc(rb2)
    assert res["ok"] is False
    assert res["verdict"] == "indeterminate"
    assert res["error"]["kind"] == "unsupported_geometry"
    assert "findings" not in res and "counts" not in res


def test_zones_present_is_indeterminate_unsupported_geometry():
    # The compiler rejects non-empty zones today; if a future IR ever carries an
    # (unfilled) copper zone, the kernel must fail closed to indeterminate rather
    # than silently ignore unmodeled copper and report a clean board.
    rb = _compile(_base(components=[_th_pad_comp(annulus=1.6)]))
    zone = ResolvedZone(
        id="zone:1", net_id=None,
        layer=Layer.from_id(rb.layer_stack.copper[0].id),
        kind=next(iter(ZoneKind)),
        authored_outline=Contour(segments=(
            LineGeometry((0.0, 0.0), (10.0, 0.0)),
            LineGeometry((10.0, 0.0), (10.0, 10.0)),
            LineGeometry((10.0, 10.0), (0.0, 0.0)))))
    res = run_geometric_drc(dataclasses.replace(rb, zones=(zone,)))
    assert res["ok"] is False
    assert res["verdict"] == "indeterminate"
    assert res["error"]["kind"] == "unsupported_geometry"
    assert "findings" not in res and "counts" not in res


# ---------------------------------------------------------------------------
# Geometry primitives — fail-safe direction + exactness.
# ---------------------------------------------------------------------------


def test_circle_edge_distance_is_exact():
    a = Capsule.disc(0.0, 0.0, 1.0)
    b = Capsule.disc(3.0, 0.0, 1.0)
    assert capsule_edge_distance(a, b) == pytest.approx(1.0)


def test_overlapping_capsules_report_negative_distance():
    a = Capsule.disc(0.0, 0.0, 1.0)
    b = Capsule.disc(1.0, 0.0, 1.0)
    assert capsule_edge_distance(a, b) < 0


def test_crossing_segments_have_zero_distance():
    assert segment_segment_distance((0, 0), (2, 2), (0, 2), (2, 0)) == pytest.approx(0.0)


def test_rotated_rect_aabb_is_a_superset_envelope():
    # A 45-deg oriented rect's AABB must ENCLOSE the rotated copper (a superset), so
    # a distance measured to the box never EXCEEDS the true distance (fail-safe). For
    # a unit half-extent rect at 45 deg the box half-width is |hw*cos|+|hh*sin| =
    # sqrt(2) > 1.0 — strictly larger than the unrotated extent. A self-AABB check of
    # an axis-aligned rect (box == its own extents) is tautological and would miss a
    # broken rotation; this asserts the genuine grow-with-rotation superset property.
    box = OrientedRect(0.0, 0.0, 1.0, 1.0, math.radians(45)).aabb()
    assert box.max_x == pytest.approx(math.sqrt(2))
    assert box.min_x == pytest.approx(-math.sqrt(2))
    assert box.max_y == pytest.approx(math.sqrt(2))
    assert box.min_y == pytest.approx(-math.sqrt(2))
