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

from types import SimpleNamespace

from pcb_worker.compile_board import compile_board
from pcb_worker.drc_geom_primitives import (
    Capsule,
    OrientedRect,
    capsule_edge_distance,
    convex_edge_distance,
    convex_edge_witness,
    segment_segment_distance,
    segment_segment_witness,
)
from pcb_worker.drc_geometric import (
    CopperPrimitive,
    Projection,
    UnsupportedGeometry,
    _bucket_copper_by_layer,
    _check_gc2_clearance,
    _check_gc5_copper_to_edge,
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
    RectOutline,
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
    # A compile/resolution failure is "unresolved_geometry", not "parse" (the board
    # parsed; it could not resolve to fabricable geometry).
    assert res["error"]["kind"] == "unresolved_geometry"
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


def test_copper_on_unknown_layer_fails_closed():
    # Fail-closed guard (Fable C2 note a): a copper primitive whose layer does not
    # fold to a known board copper layer is UNMODELED — it must raise (the kernel maps
    # that to indeterminate), never be silently un-paired. Uncompared copper is a
    # potential missed short = a false clean. Unreachable on today's 2-layer boards;
    # this guards the N-layer / mixed-namespace future.
    disc = Capsule.disc(0.0, 0.0, 0.5)
    prim = CopperPrimitive(
        entity_id="p1", parent_id=None, kind="smd_pad",
        layers=("In1.Cu",), net_id=None, shape=disc, aabb=disc.aabb())
    proj = Projection(copper=(prim,), holes=(), annular=())
    with pytest.raises(UnsupportedGeometry):
        _bucket_copper_by_layer(proj, frozenset({"top", "bottom"}))


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


# ===========================================================================
# C2 — GC2 copper clearance, GC5 copper-to-edge, broad phase, layer/NPTH/witness.
# Design of record: docket 019f952306f9 §4/§5 + Codex comment 762.
# ===========================================================================


# ---------------------------------------------------------------------------
# Convex-shape edge distance (drc_geom_primitives) — the GC2 narrow-phase kernel.
# below / equal / above the fail-safe direction, for every GC2 pairing.
# ---------------------------------------------------------------------------


def test_convex_disc_disc_distance_exact():
    # disc <-> disc == circle edge distance (fail-safe: exact for round copper).
    assert convex_edge_distance(
        Capsule.disc(0.0, 0.0, 1.0), Capsule.disc(3.0, 0.0, 1.0)
    ) == pytest.approx(1.0)


def test_convex_rect_rect_distance_exact():
    # rect [-1,1] vs rect [2,4] on x -> a 1.0 gap.
    a = OrientedRect(0.0, 0.0, 1.0, 1.0, 0.0)
    b = OrientedRect(3.0, 0.0, 1.0, 1.0, 0.0)
    assert convex_edge_distance(a, b) == pytest.approx(1.0)


def test_convex_rect_capsule_distance_exact():
    # rect right edge at x=1; disc (zero-length capsule) core at x=3, r=0.5.
    rect = OrientedRect(0.0, 0.0, 1.0, 1.0, 0.0)
    disc = Capsule.disc(3.0, 0.0, 0.5)
    assert convex_edge_distance(rect, disc) == pytest.approx(1.5)


def test_convex_rect_trace_capsule_distance_exact():
    # rect top edge at y=1; a horizontal trace capsule at y=3, r=0.25.
    rect = OrientedRect(0.0, 0.0, 1.0, 1.0, 0.0)
    trace = Capsule(-5.0, 3.0, 5.0, 3.0, 0.25)
    assert convex_edge_distance(rect, trace) == pytest.approx(1.75)


def test_convex_overlap_is_negative():
    # A disc whose centre is inside the rect -> overlap -> negative edge distance
    # (fail-safe: overlapping copper never reads as positive clearance).
    rect = OrientedRect(0.0, 0.0, 1.0, 1.0, 0.0)
    disc = Capsule.disc(0.5, 0.0, 0.5)
    assert convex_edge_distance(rect, disc) < 0


def test_convex_witness_on_overlap_is_a_single_shared_point():
    # WITNESS FIX: overlapping shapes must return a witness ON the overlap, the same
    # point for both, so a collision highlight sits on the real intersection.
    rect = OrientedRect(0.0, 0.0, 1.0, 1.0, 0.0)
    disc = Capsule.disc(0.5, 0.0, 0.5)
    w1, w2 = convex_edge_witness(rect, disc)
    assert w1 == w2


def test_crossing_segment_witness_is_the_crossing_point():
    # WITNESS FIX (segment level): two segments that PROPERLY CROSS have distance 0;
    # the witness must be the crossing point on BOTH, not a stale endpoint pair.
    w1, w2 = segment_segment_witness((0, 0), (2, 2), (0, 2), (2, 0))
    assert w1 == pytest.approx((1.0, 1.0))
    assert w1 == w2


# ---------------------------------------------------------------------------
# GC2 via the real check over a hand-built Projection (precise net/layer/shape
# control that footprint fixtures cannot give). Reuses the real convex kernel +
# broad phase; only the copper set is synthesized.
# ---------------------------------------------------------------------------


def _cp(eid, shape, *, net=None, layers=("top",), kind="smd_pad", parent=None,
        width=None):
    return CopperPrimitive(entity_id=eid, parent_id=parent, kind=kind, layers=layers,
                           net_id=net, shape=shape, aabb=shape.aabb(), width_mm=width)


def _proj(*copper):
    return Projection(copper=tuple(copper), holes=(), annular=())


def _rb_clearance(clearance=0.2):
    # A 2-layer stack so GC2's known-copper-layer guard has top/bottom to fold onto;
    # the synthetic primitives sit on "top"/"bottom" (or F.Cu/B.Cu, which fold there).
    return SimpleNamespace(
        design_rules=SimpleNamespace(
            minimums=SimpleNamespace(min_clearance_mm=clearance)),
        layer_stack=SimpleNamespace(
            copper=(SimpleNamespace(id="top"), SimpleNamespace(id="bottom"))))


def _gc2(proj, clearance=0.2):
    return _check_gc2_clearance(proj, _rb_clearance(clearance))


# --- pad <-> pad (disc <-> disc), different nets: below / equal / above ------


def test_gc2_pad_pad_below_threshold_flags():
    res = _gc2(_proj(_cp("p1", Capsule.disc(0.0, 0.0, 0.5), net="A"),
                     _cp("p2", Capsule.disc(1.05, 0.0, 0.5), net="B")))
    assert len(res) == 1
    f = res[0]
    assert f["type"] == "gc2_copper_clearance"
    assert f["measured_mm"] == pytest.approx(0.05)
    assert f["required_mm"] == pytest.approx(0.2)
    assert f["layer"] == "top"
    assert {p["entity_id"] for p in f["participants"]} == {"p1", "p2"}


def test_gc2_pad_pad_at_threshold_passes():
    # centres 1.2 apart -> edge 0.2 == floor -> exact-at-threshold PASSES (epsilon).
    res = _gc2(_proj(_cp("p1", Capsule.disc(0.0, 0.0, 0.5), net="A"),
                     _cp("p2", Capsule.disc(1.2, 0.0, 0.5), net="B")))
    assert res == []


def test_gc2_pad_pad_above_threshold_passes():
    res = _gc2(_proj(_cp("p1", Capsule.disc(0.0, 0.0, 0.5), net="A"),
                     _cp("p2", Capsule.disc(2.0, 0.0, 0.5), net="B")))
    assert res == []


# --- trace <-> pad, trace <-> trace, via <-> pad (mixed shapes) -------------


def test_gc2_trace_pad_below_threshold_flags():
    trace = _cp("t1", Capsule(0.0, 0.0, 2.0, 0.0, 0.15), net="A", kind="trace_seg",
                parent="trace:A", width=0.3)
    pad = _cp("p1", Capsule.disc(1.0, 0.4, 0.15), net="B")
    res = _gc2(_proj(trace, pad))
    assert len(res) == 1                     # gap 0.4 - 0.15 - 0.15 = 0.1 < 0.2
    assert res[0]["measured_mm"] == pytest.approx(0.1)


def test_gc2_trace_trace_below_threshold_flags():
    a = _cp("t1", Capsule(0.0, 0.0, 2.0, 0.0, 0.15), net="A", kind="trace_seg",
            parent="trace:A")
    b = _cp("t2", Capsule(0.0, 0.35, 2.0, 0.35, 0.15), net="B", kind="trace_seg",
            parent="trace:B")
    res = _gc2(_proj(a, b))
    assert len(res) == 1                     # 0.35 - 0.3 = 0.05 < 0.2
    assert res[0]["measured_mm"] == pytest.approx(0.05)


def test_gc2_via_pad_below_threshold_flags():
    via = _cp("v1", Capsule.disc(0.0, 0.0, 0.4), net="A", kind="via",
              layers=("top", "bottom"))
    pad = _cp("p1", Capsule.disc(0.85, 0.0, 0.3), net="B")   # pad on top only
    res = _gc2(_proj(via, pad))
    assert len(res) == 1                     # shared layer 'top'; 0.85-0.7 = 0.15
    assert res[0]["measured_mm"] == pytest.approx(0.15)
    assert res[0]["layer"] == "top"


# --- same-net / None / self / adjacent exemption semantics ------------------


def test_gc2_same_non_null_net_is_exempt():
    # Overlapping copper on the SAME non-null net is a shared electrical node -> exempt.
    res = _gc2(_proj(_cp("p1", Capsule.disc(0.0, 0.0, 0.5), net="N"),
                     _cp("p2", Capsule.disc(0.3, 0.0, 0.5), net="N")))
    assert res == []


def test_gc2_none_vs_none_is_checked_and_flagged():
    # Two UNASSIGNED (None-net) primitives are NOT a shared net -> must be checked.
    res = _gc2(_proj(_cp("p1", Capsule.disc(0.0, 0.0, 0.5), net=None),
                     _cp("p2", Capsule.disc(0.3, 0.0, 0.5), net=None)))
    assert len(res) == 1


def test_gc2_none_vs_net_is_checked_and_flagged():
    res = _gc2(_proj(_cp("p1", Capsule.disc(0.0, 0.0, 0.5), net=None),
                     _cp("p2", Capsule.disc(0.3, 0.0, 0.5), net="A")))
    assert len(res) == 1


def test_gc2_self_pair_is_not_flagged():
    # Two entries sharing an entity_id (a shape vs itself) are never a violation.
    shape = Capsule.disc(0.0, 0.0, 0.5)
    res = _gc2(_proj(_cp("p1", shape, net=None), _cp("p1", shape, net=None)))
    assert res == []


def test_gc2_adjacent_segments_of_one_trace_share_vertex_not_flagged():
    # Two segments of ONE polyline meet by construction at a shared vertex; that touch
    # is not a clearance violation (subsumed by the same-non-null-net exemption).
    a = _cp("t1:0", Capsule(0.0, 0.0, 1.0, 0.0, 0.2), net="N", kind="trace_seg",
            parent="trace:N")
    b = _cp("t1:1", Capsule(1.0, 0.0, 2.0, 0.0, 0.2), net="N", kind="trace_seg",
            parent="trace:N")
    res = _gc2(_proj(a, b))
    assert res == []


# --- layer normalization: F.Cu vs B.Cu at the same xy must NOT conflict -----


def test_gc2_opposite_layer_pair_does_not_conflict():
    # An F.Cu pad and a B.Cu pad at the SAME xy are on different physical layers.
    # Layer normalization (kicad_to_canon: F.Cu->top, B.Cu->bottom) puts them in
    # separate buckets, so they do NOT conflict even though they fully overlap in xy.
    res = _gc2(_proj(_cp("p1", Capsule.disc(0.0, 0.0, 0.5), net="A", layers=("F.Cu",)),
                     _cp("p2", Capsule.disc(0.0, 0.0, 0.5), net="B", layers=("B.Cu",))))
    assert res == []


def test_gc2_same_layer_kicad_namespace_pair_conflicts():
    # Control for the above: the SAME two overlapping pads both on F.Cu DO conflict —
    # proving it was the layer separation, not some other exemption, that spared them.
    res = _gc2(_proj(_cp("p1", Capsule.disc(0.0, 0.0, 0.5), net="A", layers=("F.Cu",)),
                     _cp("p2", Capsule.disc(0.0, 0.0, 0.5), net="B", layers=("F.Cu",))))
    assert len(res) == 1
    assert res[0]["layer"] == "top"          # reported in the canonical namespace


# --- broad phase: correctness-equivalent to all-pairs ------------------------


def test_gc2_broad_phase_finds_the_one_violating_pair_among_many():
    # A grid of well-separated discs (no violations) PLUS one close violating pair.
    # The broad phase must prune the far pairs yet still surface the close one.
    copper = []
    n = 0
    for gx in range(6):
        for gy in range(6):
            copper.append(_cp(f"g{n:02d}", Capsule.disc(gx * 5.0, gy * 5.0, 0.5),
                              net=f"N{n}"))
            n += 1
    # One extra disc 0.05mm (edge) from grid cell g00 at (0,0), different net.
    copper.append(_cp("hot", Capsule.disc(1.05, 0.0, 0.5), net="HOT"))
    res = _gc2(_proj(*copper))
    assert len(res) == 1
    assert {p["entity_id"] for p in res[0]["participants"]} == {"g00", "hot"}


def test_gc2_broad_phase_matches_naive_all_pairs():
    # Equivalence check: the broad-phase result equals a brute-force all-pairs scan
    # over the same copper (same violations, no drops, no spurious adds).
    import itertools
    copper = [
        _cp("a", Capsule.disc(0.0, 0.0, 0.5), net="A"),
        _cp("b", Capsule.disc(1.05, 0.0, 0.5), net="B"),     # a-b violate
        _cp("c", Capsule.disc(20.0, 20.0, 0.5), net="C"),
        _cp("d", Capsule.disc(20.6, 20.0, 0.5), net="D"),    # c-d violate
        _cp("e", Capsule.disc(50.0, 0.0, 0.5), net="E"),     # isolated
    ]
    res = _gc2(_proj(*copper))
    got = {tuple(sorted(p["entity_id"] for p in f["participants"])) for f in res}
    naive = set()
    for x, y in itertools.combinations(copper, 2):
        if x.net_id is not None and x.net_id == y.net_id:
            continue
        if convex_edge_distance(x.shape, y.shape) < 0.2 - 1e-9:
            naive.add(tuple(sorted((x.entity_id, y.entity_id))))
    assert got == naive
    assert naive == {("a", "b"), ("c", "d")}


# ---------------------------------------------------------------------------
# GC5 copper-to-edge — hand-built Projection over a real RectOutline.
# ---------------------------------------------------------------------------


def _rb_edge(edge=0.3, origin=(0.0, 0.0), w=40.0, h=40.0):
    return SimpleNamespace(
        design_rules=SimpleNamespace(minimums=SimpleNamespace(copper_to_edge_mm=edge)),
        outline=RectOutline(origin=origin, width_mm=w, height_mm=h))


def _gc5(proj, **kw):
    return _check_gc5_copper_to_edge(proj, _rb_edge(**kw))


def test_gc5_interior_copper_above_threshold_passes():
    res = _gc5(_proj(_cp("p1", Capsule.disc(20.0, 20.0, 0.5))))
    assert res == []


def test_gc5_copper_at_threshold_passes():
    # left inset exactly 0.3: disc r0.5 centred at x=0.8 -> min_x 0.3 -> inset 0.3.
    res = _gc5(_proj(_cp("p1", Capsule.disc(0.8, 20.0, 0.5))))
    assert res == []


def test_gc5_copper_below_threshold_flags():
    # disc r0.5 at x=0.6 -> min_x 0.1 -> left inset 0.1 < 0.3.
    res = _gc5(_proj(_cp("p1", Capsule.disc(0.6, 20.0, 0.5))))
    assert len(res) == 1
    assert res[0]["type"] == "gc5_copper_to_edge"
    assert res[0]["measured_mm"] == pytest.approx(0.1)
    assert res[0]["required_mm"] == pytest.approx(0.3)


def test_gc5_copper_outside_outline_is_negative_violation():
    # disc r0.5 at x=0.2 -> min_x -0.3 (copper pokes past the left edge) -> negative.
    res = _gc5(_proj(_cp("p1", Capsule.disc(0.2, 20.0, 0.5))))
    assert len(res) == 1
    assert res[0]["measured_mm"] < 0


def test_gc5_honors_outline_origin():
    # Outline shifted to origin (10,10), 20x20 -> board spans x,y in [10,30]. A disc at
    # x=10.4 is well inside a (0,0) board but only 0.1mm inside the SHIFTED left edge.
    inside_origin_00 = _gc5(_proj(_cp("p1", Capsule.disc(10.4, 20.0, 0.5))),
                            origin=(0.0, 0.0), w=40.0, h=40.0)
    assert inside_origin_00 == []                     # 9.9mm inset -> clean at (0,0)
    shifted = _gc5(_proj(_cp("p1", Capsule.disc(10.4, 20.0, 0.5))),
                   origin=(10.0, 10.0), w=20.0, h=20.0)
    assert len(shifted) == 1                          # (10.4-0.5) - 10 = -0.1 -> flag
    assert shifted[0]["measured_mm"] < 0


# ---------------------------------------------------------------------------
# End-to-end over a compiled ResolvedBoard: GC2 None-conflict, same-net
# exemption, and the NPTH-as-hole prerequisite.
# ---------------------------------------------------------------------------


def _flip_pad_type(rb, comp_ref, new_type):
    comps = []
    for comp in rb.components:
        if comp.ref == comp_ref:
            pads = tuple(dataclasses.replace(p, pad_type=new_type)
                         for p in comp.placed_pads)
            comp = dataclasses.replace(comp, placed_pads=pads)
        comps.append(comp)
    return dataclasses.replace(rb, components=tuple(comps))


def _two_th_pads(**net):
    return _base(
        components=[_th_pad_comp(ref="U1", x=10.0, annulus=1.6),
                    _th_pad_comp(ref="U2", x=10.6, annulus=1.6)],
        **net)


def test_gc2_compiled_none_vs_none_flags_across_both_layers():
    # Two plated TH pads (no nets -> net None) overlapping in copper. Not same-net
    # exempt; both span top+bottom, so the conflict is reported on each layer.
    res = _run(_two_th_pads())
    assert _counts(res, "gc2_copper_clearance") == 2
    layers = {f["layer"] for f in _findings(res, "gc2_copper_clearance")}
    assert layers == {"top", "bottom"}


def test_gc2_compiled_same_net_is_exempt():
    res = _run(_two_th_pads(nets=[{"name": "N", "pins": ["U1.1", "U2.1"]}]))
    assert _counts(res, "gc2_copper_clearance") == 0


def test_npth_pad_projects_hole_not_copper():
    # PREREQUISITE: an np_thru_hole pad has NO copper land/ring — it is a bare hole.
    rb = _compile(_base(components=[_th_pad_comp(ref="U1", x=10.0, annulus=1.6)]))
    pad_id = rb.components[0].placed_pads[0].id
    rb = _flip_pad_type(rb, "U1", "np_thru_hole")
    proj = project_board(rb)
    assert pad_id not in {c.entity_id for c in proj.copper}      # NO copper
    assert pad_id in {h.entity_id for h in proj.holes}           # IS a hole (GC3/GC6)
    assert pad_id not in {a.entity_id for a in proj.annular}     # NO annular (GC4)


def test_npth_pad_suppresses_gc2_but_keeps_gc6():
    # Baseline: two plated TH pads overlapping -> GC2 fires (copper), GC6 fires (holes).
    rb = _compile(_two_th_pads())
    base = run_geometric_drc(rb)
    assert _counts(base, "gc2_copper_clearance") >= 1
    assert _counts(base, "gc6_hole_to_hole") == 1
    # Flip U2 to np_thru_hole: its copper vanishes (no GC2 against U1), but its DRILL
    # remains, so hole-to-hole (GC6) against U1 still fires — proving it is modeled as
    # a hole, not copper.
    res = run_geometric_drc(_flip_pad_type(rb, "U2", "np_thru_hole"))
    assert _counts(res, "gc2_copper_clearance") == 0
    assert _counts(res, "gc6_hole_to_hole") == 1
