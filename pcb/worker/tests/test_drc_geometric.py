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

from pcb_worker import drc_geometric as dg
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
    _broad_phase_pairs,
    _bucket_copper_by_layer,
    _check_gc2_clearance,
    _check_gc5_copper_to_edge,
    _effective_min_clearance,
    _net_class_minima,
    geometric_drc_from_resolution,
    project_board,
    run_geometric_drc,
)
from pcb_worker.resolved_board import (
    BoardGraphic,
    Contour,
    DiagnosticSeverity,
    HoleKind,
    Layer,
    LayerPad,
    LineGeometry,
    NetClass,
    OvalHole,
    ProfileOutline,
    RectOutline,
    ResolutionFailure,
    ResolutionSuccess,
    ResolvedHole,
    ResolvedZone,
    ViaPadstack,
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


def _rb_clearance(clearance=0.2, net_classes=(), nets=()):
    # A 2-layer stack so GC2's known-copper-layer guard has top/bottom to fold onto;
    # the synthetic primitives sit on "top"/"bottom" (or F.Cu/B.Cu, which fold there).
    # `nets`/`net_classes` default EMPTY (what a board authoring no `design_rules.
    # net_classes` block compiles to — still the overwhelming majority) so GC2's
    # per-net-class floor lookup resolves to the global clearance; the net-class
    # tests below pass real ResolvedNet/NetClass values in.
    return SimpleNamespace(
        design_rules=SimpleNamespace(
            minimums=SimpleNamespace(min_clearance_mm=clearance),
            net_classes=tuple(net_classes)),
        nets=tuple(nets),
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


# ===========================================================================
# REPAIR ROUND — the six close-out false-clean / contract repros (docket
# 019f95893989, 019f95897086, 019f958b45b9, 019f9589ebb3). The result-union
# (019f9589b232) + routing-label (019f958aa6db) repros live in
# test_methods_drc_geometric.py / test_route_drc.py (they are method-boundary).
# The first three repros are still closed by a fail-closed guard that
# fires BEFORE projection and yields the indeterminate envelope —
# verdict:"indeterminate", kind:"unsupported_geometry", NO clean/findings/counts.
# 019f958b45b9 is NOT: its interim guard was replaced by the real per-net-class
# floors (see that section below), so a net-classed board now runs to a real
# verdict measured against the class minima.
# ===========================================================================


def _assert_indeterminate_unsupported(res: dict) -> None:
    assert res["ok"] is False
    assert res["scope"] == "geometric"
    assert res["verifies_geometry"] is False
    assert res["verdict"] == "indeterminate"
    assert res["error"]["kind"] == "unsupported_geometry"
    # NO clean/findings/counts a caller could mistake for a pass.
    assert "findings" not in res
    assert "counts" not in res
    assert "clean" not in res


# --- 019f95893989: via per-layer padstack copper false-clean ---------------


def _via_board():
    return _base(
        components=[_th_pad_comp(ref="U1", x=10.0, annulus=1.6)],
        nets=[{"name": "N", "pins": ["U1.1"]}],
        vias=[{"net": "N", "x_mm": 20, "y_mm": 20, "diameter_mm": 0.8,
               "drill_mm": 0.4, "from_layer": "top", "to_layer": "bottom"}])


def test_via_padstack_fails_closed_indeterminate():
    # A via whose TOP padstack land (3.0) exceeds its global diameter (0.8) can
    # collide on top while GC2/GC5 read only the global diameter -> false clean.
    # With the fail-closed guard, ANY per-layer padstack makes the kernel
    # indeterminate rather than risk that (Codex option B, minimal v1).
    rb = _compile(_via_board())
    padstack = ViaPadstack(per_layer=(LayerPad("top", 3.0, 1.3),
                                      LayerPad("bottom", 0.8, 0.2)))
    via2 = dataclasses.replace(rb.vias[0], padstack=padstack)
    res = run_geometric_drc(dataclasses.replace(rb, vias=(via2,)))
    _assert_indeterminate_unsupported(res)


def test_via_without_padstack_still_runs_to_a_verdict():
    # Control: the SAME via without a padstack must NOT trip the guard — the
    # kernel runs to a determinate verdict (a padstack-less via is fully modeled).
    res = _run(_via_board())
    assert res["ok"] is True
    assert res["verdict"] in ("clean", "violations")


# --- 019f95897086: copper board/placed graphics false-clean ----------------


def test_copper_board_graphic_fails_closed_indeterminate():
    rb = _compile(_base(components=[_th_pad_comp(annulus=1.6)]))
    copper_line = BoardGraphic(
        id="copper-line", layer=Layer.from_id("F.Cu"),
        geometry=LineGeometry((1.0, 1.0), (39.0, 39.0)), width_mm=1.0)
    res = run_geometric_drc(dataclasses.replace(rb, board_graphics=(copper_line,)))
    _assert_indeterminate_unsupported(res)


def test_non_copper_board_graphic_still_runs_to_a_verdict():
    # Control: a SILK board graphic is not copper -> the kernel is unaffected.
    rb = _compile(_base(components=[_th_pad_comp(annulus=1.6)]))
    silk_line = BoardGraphic(
        id="silk-line", layer=Layer.from_id("F.SilkS"),
        geometry=LineGeometry((1.0, 1.0), (5.0, 5.0)), width_mm=0.2)
    res = run_geometric_drc(dataclasses.replace(rb, board_graphics=(silk_line,)))
    assert res["ok"] is True
    assert res["verdict"] in ("clean", "violations")


def test_copper_placed_graphic_fails_closed_indeterminate():
    # A component PlacedGraphic on a copper layer is the same unmodeled-copper
    # false clean. Flip an existing (silk) placed graphic onto F.Cu.
    rb = _compile(_base(components=[
        {"ref": "R1", "footprint": "R_0805", "x_mm": 20, "y_mm": 20,
         "rotation_deg": 0, "layer": "top"}]))
    comp = rb.components[0]
    assert comp.placed_graphics, "fixture expects footprint silk/courtyard graphics"
    pg0 = dataclasses.replace(comp.placed_graphics[0], layer=Layer.from_id("F.Cu"))
    comp2 = dataclasses.replace(
        comp, placed_graphics=(pg0,) + comp.placed_graphics[1:])
    res = run_geometric_drc(dataclasses.replace(rb, components=(comp2,)))
    _assert_indeterminate_unsupported(res)


# --- 019f958b45b9: per-net-class width/clearance minima are ENFORCED --------
#
# GC1's width floor and GC2's clearance floor are the GLOBAL
# ManufacturingConstraints minima RAISED by the net class(es) in play. This
# section is the repair for the false clean that bug names — a net whose class
# demands a stricter floor than the board's was certified against the weaker
# global one. (The interim guard that made ANY net-classed board `indeterminate`
# is gone; these tests pin its removal, not its behaviour.)
#
# MEASURED FIXTURE FLOORS, so the numbers below are readable:
#   * `_base` authors clearance_mm 0.2, and `compile_board._floor_with_clearance`
#     takes max(profile floor 0.127, authored) -> GLOBAL min_clearance_mm = 0.2.
#   * `_base` authors trace_width_mm 0.3, but that becomes `RoutingDefaults`, NOT
#     a minimum -> GLOBAL min_trace_width_mm stays the profile floor 0.127.
# Every class value below is chosen strictly ABOVE its global counterpart, and
# every geometry strictly BETWEEN the two, so only the class term can flag it.

GLOBAL_MIN_WIDTH_MM = 0.127     # _V1_MANUFACTURING_FLOOR, untightenable by a board
GLOBAL_MIN_CLEARANCE_MM = 0.2   # _base's authored clearance_mm, above the 0.127 floor


def _net_board():
    return _base(
        components=[_th_pad_comp(ref="U1", x=10.0, annulus=1.6)],
        nets=[{"name": "N", "pins": ["U1.1"]}])


def _apply_net_class(rb, nc: NetClass):
    """Attach *nc* to EVERY net (the whole board is one class)."""
    dr = dataclasses.replace(rb.design_rules, net_classes=(nc,))
    nets = tuple(dataclasses.replace(n, net_class_id=nc.id) for n in rb.nets)
    return dataclasses.replace(rb, design_rules=dr, nets=nets)


def _apply_net_class_to(rb, nc: NetClass, *net_names: str):
    """Attach *nc* to the NAMED nets only, leaving every other net unclassed. The
    net-scoping tests need one board carrying both, so a board-wide scalar cannot
    satisfy them.

    A board CAN now author its own classes (`design_rules.net_classes` — see
    `test_an_authored_net_class_raises_this_nets_gc1_floor`), so this is no longer
    the only way in. It stays because it reaches class states the authoring layer
    refuses on purpose (`compile_board._net_class_minimum` admits only positive
    numbers, while the IR admits a `0`) and because a synthetic `NetClass` is the
    shortest way to control exactly which net carries what."""
    dr = dataclasses.replace(rb.design_rules, net_classes=(nc,))
    wanted = set(net_names)
    nets = tuple(dataclasses.replace(n, net_class_id=nc.id) if n.name in wanted else n
                 for n in rb.nets)
    assert wanted <= {n.name for n in rb.nets}, "fixture names a net the board lacks"
    return dataclasses.replace(rb, design_rules=dr, nets=nets)


def _gc1_by_net(res: dict) -> dict[str, dict]:
    return {f["net_name"]: f for f in _findings(res, "gc1_trace_width")}


def _gc2_refs(res: dict) -> set[frozenset]:
    """Every GC2 finding as the unordered pair of participant refs — assertion by
    ENTITY IDENTITY, never by count."""
    return {frozenset(p["ref"] for p in f["participants"])
            for f in _findings(res, "gc2_copper_clearance")}


# -- acceptance 2: the bug reproduction is now a DETERMINATE GC1 violation ---


def _classed_width_board(width_mm: float):
    return _base(
        components=[_th_pad_comp(ref="U1", x=10.0, annulus=1.6)],
        nets=[{"name": "N", "pins": ["U1.1"]}],
        traces=[_trace(width_mm, net="N")])


def test_net_class_min_trace_width_is_applied_as_a_gc1_violation():
    # The 019f958b45b9 reproduction. A trace at 0.2mm clears the GLOBAL 0.127 floor,
    # so the board is CLEAN with no class (this is what made the original false
    # clean possible). Its net's class demands 0.4 -> the SAME board is now a
    # determinate GC1 violation naming the EFFECTIVE 0.4 floor, not the global one.
    rb = _compile(_classed_width_board(0.2))
    assert run_geometric_drc(rb)["verdict"] == "clean"

    rb2 = _apply_net_class(rb, NetClass(id="nc:strict", name="Strict",
                                        min_trace_width_mm=0.4))
    res = run_geometric_drc(rb2)
    assert res["ok"] is True
    assert res["verifies_geometry"] is True
    assert res["verdict"] == "violations"
    found = _gc1_by_net(res)
    assert set(found) == {"N"}
    # acceptance 8: the finding reports the EFFECTIVE required value.
    assert found["N"]["required_mm"] == pytest.approx(0.4)
    assert found["N"]["measured_mm"] == pytest.approx(0.2)


def test_an_authored_net_class_raises_this_nets_gc1_floor():
    """THE SAME reproduction as above, driven the way a real caller drives it:
    the class is AUTHORED in the board's own `design_rules.net_classes` block and
    compiled by the real compiler — no `dataclasses.replace`, no synthetic
    `NetClass`.

    The 0.2mm trace clears the global 0.127 floor, so the identical board is
    CLEAN without the block and a determinate GC1 violation with it, naming the
    class's 0.4 as the required value. That difference is the whole point: it
    fails on a compiler that ignores the block, and equally on one that builds
    `design_rules.net_classes` but never assigns `ResolvedNet.net_class_id`,
    because `_net_class_minima` reads REFERENCED classes only.

    A SECOND net (M) is deliberately left out of `members`, so the same run also
    pins that membership is per-net and not board-wide.
    """
    board = _base(
        components=[_th_pad_comp(ref="U1", x=10.0, annulus=1.6),
                    _th_pad_comp(ref="U2", x=25.0, annulus=1.6)],
        nets=[{"name": "N", "pins": ["U1.1"]}, {"name": "M", "pins": ["U2.1"]}],
        traces=[_trace(0.2, net="N"),
                _trace(0.2, net="M", a=(25.0, 20.0), b=(35.0, 20.0))])
    assert _run(board)["verdict"] == "clean"

    board["design_rules"] = dict(board["design_rules"], net_classes=[
        {"name": "Strict", "members": ["N"], "min_trace_width_mm": 0.4}])
    res = _run(board)
    assert res["ok"] is True
    assert res["verifies_geometry"] is True
    assert res["verdict"] == "violations"
    found = _gc1_by_net(res)
    assert set(found) == {"N"}, "M joined no class and must keep the global floor"
    assert found["N"]["required_mm"] == pytest.approx(0.4)
    assert found["N"]["measured_mm"] == pytest.approx(0.2)


def test_an_authored_net_class_raises_this_pairs_gc2_floor():
    """The CLEARANCE half of the authoring surface, end to end — the mirror of
    `test_an_authored_net_class_raises_this_nets_gc1_floor`, which covers width.

    Without this, authored `min_clearance_mm` reached neither consumer from a
    real board in any test: it was exercised only through the synthetic
    `dataclasses.replace` helpers, so a compiler that parsed the key and dropped
    it (or wired it to the wrong nets) would have gone unnoticed on the DRC side.

    Gap 0.3mm: above the GLOBAL 0.2 floor, so the board is CLEAN with no class.
    Only net A is a member — a pair's floor is the max over BOTH participants'
    classes, so one member is enough to raise it, and the run also pins that
    membership came from `members` rather than being applied board-wide.
    """
    board = _two_pad_board(11.5)
    assert _run(board)["verdict"] == "clean"

    board["design_rules"] = dict(board["design_rules"], net_classes=[
        {"name": "Strict", "members": ["A"], "min_clearance_mm": 0.5}])
    res = _run(board)
    assert res["ok"] is True
    assert res["verifies_geometry"] is True
    assert _gc2_refs(res) == {frozenset({"U1", "U2"})}
    f = _findings(res, "gc2_copper_clearance")[0]
    assert f["required_mm"] == pytest.approx(0.5), \
        "the EFFECTIVE pair floor must be the authored class value, not the global 0.2"
    assert f["measured_mm"] == pytest.approx(0.3)


def test_an_authored_net_class_clearance_does_not_reach_an_unclassed_pair():
    """The negative half: a class authored over net A must not raise the floor
    for a pair neither of whose participants joined it. Same board, same authored
    clearance, but the class names a net that exists and is not in this pair —
    so the pair stays at the global floor and the board stays clean."""
    board = _two_pad_board(11.5)
    board["components"].append(_th_pad_comp(ref="U3", x=30.0, annulus=1.2))
    board["nets"] = board["nets"] + [{"name": "C", "pins": ["U3.1"]}]
    board["design_rules"] = dict(board["design_rules"], net_classes=[
        {"name": "Strict", "members": ["C"], "min_clearance_mm": 0.5}])
    res = _run(board)
    assert res["verdict"] == "clean", \
        "A/B joined no class; their 0.3mm gap must still be judged at the global 0.2"


def test_an_authored_net_class_nobody_joins_constrains_no_copper():
    """An UNREFERENCED class is legal and changes nothing — the consumers' rule
    (both read referenced classes only), now pinned against a board that really
    authors one. The class is compiled; with no `members` it reaches no copper,
    so the same 0.2mm trace that violates the class's 0.4 floor above stays
    CLEAN here."""
    board = _classed_width_board(0.2)
    board["design_rules"] = dict(board["design_rules"], net_classes=[
        {"name": "Strict", "min_trace_width_mm": 0.4}])
    rb = _compile(board)
    assert len(rb.design_rules.net_classes) == 1
    assert all(net.net_class_id is None for net in rb.nets)
    assert run_geometric_drc(rb)["verdict"] == "clean"


def test_net_class_min_trace_width_below_the_global_floor_cannot_weaken_it():
    # The class term only ever RAISES (max), never relaxes: a class minimum UNDER
    # the global floor leaves the global floor in force.
    rb = _compile(_classed_width_board(0.1))       # under the 0.127 global floor
    rb2 = _apply_net_class(rb, NetClass(id="nc:loose", name="Loose",
                                        min_trace_width_mm=0.05))
    found = _gc1_by_net(run_geometric_drc(rb2))
    assert set(found) == {"N"}
    assert found["N"]["required_mm"] == pytest.approx(GLOBAL_MIN_WIDTH_MM)


# -- acceptance 3: the GC2 twin ---------------------------------------------


def _two_pad_board(x2: float, net2_pin_ref="U2"):
    # Two TH lands of radius 0.6 (annulus 1.2) on DIFFERENT nets, so GC2 compares
    # them; the copper gap is (x2 - 10.0) - 1.2.
    return _base(
        components=[_th_pad_comp(ref="U1", x=10.0, annulus=1.2),
                    _th_pad_comp(ref="U2", x=x2, annulus=1.2)],
        nets=[{"name": "A", "pins": ["U1.1"]},
              {"name": "B", "pins": ["U2.1"]}])


def test_net_class_min_clearance_is_applied_as_a_gc2_violation():
    # Gap 0.3mm: above the GLOBAL 0.2 floor (clean without a class), below the
    # class's 0.5 (a violation with one). Only ONE participant carries the class —
    # a pair's floor is the max over BOTH participants' classes.
    rb = _compile(_two_pad_board(11.5))
    assert run_geometric_drc(rb)["verdict"] == "clean"

    rb2 = _apply_net_class_to(rb, NetClass(id="nc:strict", name="Strict",
                                           min_clearance_mm=0.5), "A")
    res = run_geometric_drc(rb2)
    assert res["ok"] is True
    assert res["verifies_geometry"] is True
    assert _gc2_refs(res) == {frozenset({"U1", "U2"})}
    f = _findings(res, "gc2_copper_clearance")[0]
    # acceptance 8: the EFFECTIVE pair floor, not the global 0.2.
    assert f["required_mm"] == pytest.approx(0.5)
    assert f["measured_mm"] == pytest.approx(0.3)


def test_gc2_pair_floor_is_the_max_over_both_participants_classes():
    # Synthetic projection (precise net control): net "a" demands 0.4, net "b"
    # demands 0.9 — the pair must be compared against 0.9, the stricter of the two.
    nc_a = NetClass(id="nc:a", name="A", min_clearance_mm=0.4)
    nc_b = NetClass(id="nc:b", name="B", min_clearance_mm=0.9)
    nets = (SimpleNamespace(id="a", name="A", net_class_id="nc:a"),
            SimpleNamespace(id="b", name="B", net_class_id="nc:b"))
    # Discs r=0.5 whose centres are 1.6 apart -> a 0.6mm copper gap: clears 0.4,
    # violates 0.9.
    proj = _proj(_cp("p1", Capsule.disc(0.0, 0.0, 0.5), net="a"),
                 _cp("p2", Capsule.disc(1.6, 0.0, 0.5), net="b"))
    res = _check_gc2_clearance(
        proj, _rb_clearance(0.2, net_classes=(nc_a, nc_b), nets=nets))
    assert len(res) == 1
    assert res[0]["required_mm"] == pytest.approx(0.9)


def test_gc2_netless_copper_contributes_no_class_term_but_the_other_net_still_applies():
    # D2: a participant with net_id=None (e.g. `board_hole_copper`, which
    # project_board hardcodes to None) carries no class. The CLASSED participant's
    # floor still governs the pair.
    nc = NetClass(id="nc:a", name="A", min_clearance_mm=0.9)
    nets = (SimpleNamespace(id="a", name="A", net_class_id="nc:a"),)
    proj = _proj(_cp("p1", Capsule.disc(0.0, 0.0, 0.5), net="a"),
                 _cp("p2", Capsule.disc(1.6, 0.0, 0.5), net=None))
    res = _check_gc2_clearance(
        proj, _rb_clearance(0.2, net_classes=(nc,), nets=nets))
    assert len(res) == 1
    assert res[0]["required_mm"] == pytest.approx(0.9)

    # Both net-less: no class term at all, so the global floor stands and the same
    # 0.6mm gap is clean.
    both_none = _proj(_cp("q1", Capsule.disc(0.0, 0.0, 0.5), net=None),
                      _cp("q2", Capsule.disc(1.6, 0.0, 0.5), net=None))
    assert _check_gc2_clearance(
        both_none, _rb_clearance(0.2, net_classes=(nc,), nets=nets)) == []


# -- acceptance 4: NET SCOPING (one board, classed vs unclassed side by side) --


def test_gc1_flags_the_classed_net_and_clears_an_unclassed_net_at_the_same_width():
    # ONE board, TWO traces at the IDENTICAL width 0.2. CLASSED's class demands 0.4;
    # PLAIN has no class and answers only to the global 0.127. A board-wide scalar
    # floor cannot produce this split — that is the whole point of the fixture.
    board = _base(
        components=[_th_pad_comp(ref="U1", x=10.0, y=10.0, annulus=1.6),
                    _th_pad_comp(ref="U2", x=10.0, y=20.0, annulus=1.6)],
        nets=[{"name": "CLASSED", "pins": ["U1.1"]},
              {"name": "PLAIN", "pins": ["U2.1"]}],
        traces=[_trace(0.2, net="CLASSED", a=(10.0, 10.0), b=(20.0, 10.0)),
                _trace(0.2, net="PLAIN", a=(10.0, 20.0), b=(20.0, 20.0))])
    rb = _compile(board)
    rb2 = _apply_net_class_to(rb, NetClass(id="nc:strict", name="Strict",
                                           min_trace_width_mm=0.4), "CLASSED")
    res = run_geometric_drc(rb2)
    found = _gc1_by_net(res)
    # BY IDENTITY: the classed net is flagged, the unclassed net at the same width
    # is not present at all.
    assert set(found) == {"CLASSED"}
    assert found["CLASSED"]["required_mm"] == pytest.approx(0.4)


def test_gc2_flags_the_classed_pair_and_clears_an_unclassed_pair_at_the_same_gap():
    # ONE board, TWO pad pairs with the IDENTICAL 0.3mm copper gap. The pair whose
    # participant is classed (0.5) violates; the unclassed-to-unclassed pair sits
    # between the global 0.2 and that 0.5 and stays CLEAN.
    board = _base(
        components=[_th_pad_comp(ref="U1", x=10.0, y=10.0, annulus=1.2),
                    _th_pad_comp(ref="U2", x=11.5, y=10.0, annulus=1.2),
                    _th_pad_comp(ref="U3", x=10.0, y=20.0, annulus=1.2),
                    _th_pad_comp(ref="U4", x=11.5, y=20.0, annulus=1.2)],
        nets=[{"name": "CA", "pins": ["U1.1"]}, {"name": "CB", "pins": ["U2.1"]},
              {"name": "PA", "pins": ["U3.1"]}, {"name": "PB", "pins": ["U4.1"]}])
    rb = _compile(board)
    assert run_geometric_drc(rb)["verdict"] == "clean", "both gaps clear the global floor"

    rb2 = _apply_net_class_to(rb, NetClass(id="nc:strict", name="Strict",
                                           min_clearance_mm=0.5), "CA")
    res = run_geometric_drc(rb2)
    assert _gc2_refs(res) == {frozenset({"U1", "U2"})}


# -- acceptance 5: the BROAD PHASE, asserted directly and both ways ----------


def _broad_phase_fixture():
    # Two discs r=0.5 whose AABBs are 0.45mm apart — MORE than 2 x the global 0.2
    # (both boxes are inflated, so the prune threshold is 2 x margin) and LESS than
    # 2 x a 0.6 class floor.
    return [_cp("p1", Capsule.disc(0.0, 0.0, 0.5), net="a"),
            _cp("p2", Capsule.disc(1.45, 0.0, 0.5), net="b")]


def test_broad_phase_prunes_the_violating_pair_at_the_un_inflated_global_margin():
    # The pruning is REAL: swept at the global floor alone, this pair never reaches
    # the narrow phase. (If the fix had simply set margin=infinity this would fail,
    # which is exactly what it is here to catch.)
    assert _broad_phase_pairs(_broad_phase_fixture(), GLOBAL_MIN_CLEARANCE_MM) == []


def test_broad_phase_keeps_the_violating_pair_at_the_class_inflated_margin():
    # Swept at the board-wide MAXIMUM required clearance (the class's 0.6), the same
    # pair survives to be measured.
    assert _broad_phase_pairs(_broad_phase_fixture(), 0.6) == [(0, 1)]


def _two_class_board():
    """A compiled board with TWO different clearance classes in play plus one
    unclassed net, so "the board-wide maximum" is a value distinguishable from the
    global floor, from either class alone, and from their sum."""
    rb = _compile(_control_board())
    mid = NetClass(id="nc:mid", name="Mid", min_clearance_mm=0.4)
    high = NetClass(id="nc:high", name="High", min_clearance_mm=0.9)
    by_name = {"A": "nc:mid", "B": "nc:high"}          # net "C" stays unclassed
    return dataclasses.replace(
        rb,
        design_rules=dataclasses.replace(rb.design_rules, net_classes=(mid, high)),
        nets=tuple(dataclasses.replace(n, net_class_id=by_name[n.name])
                   if n.name in by_name else n for n in rb.nets))


def test_gc2_sweeps_the_broad_phase_at_exactly_the_board_wide_maximum(monkeypatch):
    # THE CALL SITE, not just the helper. Every correctness test in this file also
    # passes with `sweep_margin = inf` — the check would simply degrade to all-pairs
    # and pay for it on every board forever, which no assertion about FINDINGS can
    # see. So capture the margin GC2 actually hands the broad phase and pin it
    # exactly: the strictest class on the board (0.9), not the global floor (which
    # would prune a real violation) and not something merely larger.
    rb2 = _two_class_board()
    seen: list[float] = []
    real = dg._broad_phase_pairs

    def spy(prims, margin):
        seen.append(margin)
        return real(prims, margin)

    monkeypatch.setattr(dg, "_broad_phase_pairs", spy)
    assert run_geometric_drc(rb2)["ok"] is True
    assert seen, "GC2 must actually reach the broad phase on this fixture"
    assert set(seen) == {0.9}


def test_the_sweep_margin_is_exactly_the_board_wide_maximum_not_merely_enough():
    # THE MARGIN MUST BE MINIMAL, NOT JUST SUFFICIENT. Every correctness test above
    # would also pass with `margin = inf` — the check would simply degrade to
    # all-pairs and pay for it forever. So assert the value EXACTLY: the sweep folds
    # in the STRICTEST class on the board (0.9) and nothing more, while a pair that
    # does not involve that class keeps its own tighter floor (0.4). Anything that
    # over-inflates (summing the class terms, defaulting to infinity) fails here even
    # though it flags every violation correctly.
    rb2 = _two_class_board()
    ids = {n.name: n.id for n in rb2.nets}

    minima = _net_class_minima(rb2)
    assert set(minima) == {ids["A"], ids["B"]}, "only REFERENCED nets carry a term"

    # The board-wide sweep bound — exactly the strictest class, not a sum, not inf.
    sweep = _effective_min_clearance(GLOBAL_MIN_CLEARANCE_MM, minima, *minima)
    assert sweep == 0.9
    # ...and it really is a MAXIMUM, i.e. above every per-pair floor on the board.
    assert _effective_min_clearance(
        GLOBAL_MIN_CLEARANCE_MM, minima, ids["A"], ids["C"]) == 0.4
    assert _effective_min_clearance(
        GLOBAL_MIN_CLEARANCE_MM, minima, ids["C"], ids["C"]) == GLOBAL_MIN_CLEARANCE_MM
    assert _effective_min_clearance(
        GLOBAL_MIN_CLEARANCE_MM, minima, ids["A"], ids["B"]) == sweep


def test_gc2_flags_a_pair_the_global_margin_would_have_pruned():
    # END TO END, through run_geometric_drc: the violating gap (0.45) EXCEEDS
    # 2 x the global floor, so without the class-inflated sweep margin the pair is
    # discarded before comparison and the board reads CLEAN — the exact false clean
    # this round closes.
    rb = _compile(_two_pad_board(11.65))           # copper gap 0.45
    assert run_geometric_drc(rb)["verdict"] == "clean"

    rb2 = _apply_net_class_to(rb, NetClass(id="nc:strict", name="Strict",
                                           min_clearance_mm=0.6), "A")
    res = run_geometric_drc(rb2)
    assert _gc2_refs(res) == {frozenset({"U1", "U2"})}
    f = _findings(res, "gc2_copper_clearance")[0]
    assert f["required_mm"] == pytest.approx(0.6)
    assert f["measured_mm"] == pytest.approx(0.45)


# -- acceptance 6: controls that must NOT over-trip --------------------------


def _control_board():
    """A CLEAN board that is nevertheless SENSITIVE in every dimension a NetClass
    field could be misread into, so a control asserting "this class changed nothing"
    can actually fail. A control over inert geometry would pass no matter what the
    kernel did with the class. What each piece is here to catch:

      * a 0.3mm pad-pair gap  — clean at the global 0.2, flagged by any CLEARANCE
        floor above it;
      * a 0.2mm trace         — clean at the global 0.127, flagged by any WIDTH
        floor above it;
      * a via (0.8 land / 0.4 drill, 0.2mm annular web) — clean at the global
        min_drill 0.2 / min_annular_ring 0.13, flagged by any DRILL or ANNULAR
        floor above those. Without it the `via_diameter_mm`/`via_drill_mm` legs of
        the "nominal fields are not minima" control would have no GC3/GC4 subject
        and could only ever be caught as a width/clearance misread.
    """
    return _base(
        components=[_th_pad_comp(ref="U1", x=10.0, y=10.0, annulus=1.2),
                    _th_pad_comp(ref="U2", x=11.5, y=10.0, annulus=1.2),
                    _th_pad_comp(ref="U3", x=10.0, y=20.0, annulus=1.6)],
        nets=[{"name": "A", "pins": ["U1.1"]}, {"name": "B", "pins": ["U2.1"]},
              {"name": "C", "pins": ["U3.1"]}],
        traces=[_trace(0.2, net="C", a=(10.0, 20.0), b=(20.0, 20.0))],
        vias=[{"net": "C", "x_mm": 25.0, "y_mm": 25.0, "diameter_mm": 0.8,
               "drill_mm": 0.4, "from_layer": "top", "to_layer": "bottom"}])


def _assert_verdict_unchanged(res: dict, baseline: dict) -> None:
    assert res["ok"] is True
    assert res["verdict"] == baseline["verdict"]
    assert res["findings"] == baseline["findings"]
    assert res["counts"] == baseline["counts"]


def test_net_class_with_only_nominal_via_fields_changes_no_verdict():
    # `trace_width_mm`/`via_diameter_mm`/`via_drill_mm` on a NetClass are NOMINAL
    # sizes, not minima: they imply no per-class GC1 floor and no per-class GC3/GC4
    # floor. Every value below sits ABOVE the control board's sensitive geometry in
    # EVERY dimension it could be misread into, so misreading ANY of the three as a
    # minimum flags something and this control fails:
    #   trace_width_mm 0.8 > the 0.2 trace (width) and > the 0.3 gap (clearance);
    #   via_diameter_mm 0.9 > the via's 0.2 annular web (GC4), the 0.2 trace and
    #     the 0.3 gap;
    #   via_drill_mm   0.5 > the via's 0.4 drill (GC3), the 0.2 trace and the
    #     0.3 gap.
    rb = _compile(_control_board())
    baseline = run_geometric_drc(rb)
    assert baseline["verdict"] == "clean"
    assert rb.vias, "the via legs of this control need a via to be about anything"
    rb2 = _apply_net_class(rb, NetClass(id="nc:route", name="Route",
                                        trace_width_mm=0.8, via_diameter_mm=0.9,
                                        via_drill_mm=0.5))
    _assert_verdict_unchanged(run_geometric_drc(rb2), baseline)


def test_a_defined_but_unreferenced_net_class_changes_no_verdict():
    # A strict class that NO net points at constrains no copper — only REFERENCED
    # classes are read, exactly as `methods._net_class_overrides` reads them. Both of
    # its minima are above the control board's sensitive geometry, so leaking EITHER
    # dimension onto the unclassed nets fails this control.
    rb = _compile(_control_board())
    baseline = run_geometric_drc(rb)
    strict = NetClass(id="nc:orphan", name="Orphan", min_trace_width_mm=0.4,
                      min_clearance_mm=0.9)
    rb2 = dataclasses.replace(
        rb, design_rules=dataclasses.replace(rb.design_rules, net_classes=(strict,)))
    _assert_verdict_unchanged(run_geometric_drc(rb2), baseline)


# -- acceptance 7: D1, the deliberate 0.0 asymmetry, both ways round --------


def test_referenced_class_with_zero_min_trace_width_is_indeterminate():
    # D1. Routing rejects `min_trace_width_mm: 0` through `ir_candidates.positive_mm`
    # ("zero-width copper is not copper"); geometric DRC reads the SAME field off the
    # SAME class and must not reach a different conclusion, so it fails closed too.
    # This is NOT the deleted guard: that one said "not implemented" for ANY class
    # minimum; this says "THIS class's own rule cannot be sourced".
    rb = _compile(_net_board())
    rb2 = _apply_net_class(rb, NetClass(id="nc:zero", name="Zero",
                                        min_trace_width_mm=0.0))
    res = run_geometric_drc(rb2)
    _assert_indeterminate_unsupported(res)
    message = res["error"]["message"]
    assert "nc:zero" in message            # names the class...
    assert "min_trace_width_mm" in message  # ...and the field


def test_a_class_clearance_that_is_not_a_sourceable_number_fails_closed():
    """UNREACHABLE ON A VALID IR TODAY — and pinned anyway, deliberately.

    `NetClass.__post_init__` validates every field with `resolved_board._nonnegative`
    (`_finite` plus `>= 0`), so no real `NetClass` can carry NaN/inf/negative. A
    duck-typed stand-in is the ONLY way to reach this branch, and this test claims
    nothing else: it is not a scenario a board author can produce.

    It exists so the predicate cannot be silently dropped. Routing puts this same
    field through this same `nonnegative_mm` and RAISES; if the IR validation is ever
    relaxed and this leg were a bare read, a NaN class clearance would fail closed in
    routing while no-opping here — `max(0.2, nan)` returns `0.2` — and the two
    surfaces would disagree about the same class, in the false-clean direction. The
    width leg is guarded on exactly this reasoning; so is this one.
    """
    fake_class = SimpleNamespace(id="nc:nan", name="NaN", min_trace_width_mm=None,
                                 min_clearance_mm=float("nan"))
    fake_rb = SimpleNamespace(
        design_rules=SimpleNamespace(net_classes=(fake_class,)),
        nets=(SimpleNamespace(id="n1", name="N", net_class_id="nc:nan"),))
    with pytest.raises(UnsupportedGeometry) as exc:
        _net_class_minima(fake_rb)
    assert "nc:nan" in str(exc.value)            # names the class...
    assert "min_clearance_mm" in str(exc.value)  # ...and the field


def test_referenced_class_with_zero_min_clearance_is_admitted_as_a_no_op():
    # D1's other half, ASYMMETRIC on purpose: routing admits `min_clearance_mm: 0`
    # through the NON-negative predicate (zero clearance is a rule a class may state),
    # so geometric DRC admits it too. Under max() it is a no-op — the global floor
    # stands and the verdict is unchanged.
    rb = _compile(_control_board())
    baseline = run_geometric_drc(rb)
    rb2 = _apply_net_class(rb, NetClass(id="nc:zero", name="Zero",
                                        min_clearance_mm=0.0))
    _assert_verdict_unchanged(run_geometric_drc(rb2), baseline)


def test_zero_min_clearance_does_not_weaken_a_violation_the_global_floor_finds():
    # The same 0.0 on a board that genuinely violates the GLOBAL floor: admitting it
    # must not turn a violation into a clean.
    rb = _compile(_two_pad_board(11.3))            # copper gap 0.1, under 0.2
    assert _gc2_refs(run_geometric_drc(rb)) == {frozenset({"U1", "U2"})}
    rb2 = _apply_net_class(rb, NetClass(id="nc:zero", name="Zero",
                                        min_clearance_mm=0.0))
    res = run_geometric_drc(rb2)
    assert _gc2_refs(res) == {frozenset({"U1", "U2"})}
    assert _findings(res, "gc2_copper_clearance")[0]["required_mm"] == \
        pytest.approx(GLOBAL_MIN_CLEARANCE_MM)


# --- 019f9589ebb3: human source attribution on findings --------------------


def test_gc2_finding_names_both_refs_pins_and_net_names():
    # Two different-net TH lands (radius 0.8) overlapping in copper -> a GC2
    # violation whose two participants must NAME U1.1 (net GND) and U2.1 (net VCC)
    # in human-meaningful form, ALONGSIDE the stable hashed ids.
    board = _base(
        components=[_th_pad_comp(ref="U1", x=10.0, annulus=1.6),
                    _th_pad_comp(ref="U2", x=10.6, annulus=1.6)],
        nets=[{"name": "GND", "pins": ["U1.1"]},
              {"name": "VCC", "pins": ["U2.1"]}])
    res = _run(board)
    f = _findings(res, "gc2_copper_clearance")[0]
    parts = f["participants"]
    by_ref = {p["ref"]: p for p in parts}
    assert set(by_ref) == {"U1", "U2"}
    assert by_ref["U1"]["pad"] == "1"
    assert by_ref["U2"]["pad"] == "1"
    assert by_ref["U1"]["net_name"] == "GND"
    assert by_ref["U2"]["net_name"] == "VCC"
    # Stable hashed ids are PRESERVED alongside the human fields.
    assert all(p["entity_id"] and p["net_id"] for p in parts)


def test_single_entity_finding_carries_ref_pad_net_name():
    # A GC4 annular finding on a TH pad names its ref/pad/net_name too.
    board = _base(
        components=[_th_pad_comp(ref="U1", drill=0.5, annulus=0.7)],
        nets=[{"name": "GND", "pins": ["U1.1"]}])
    res = _run(board)
    f = _findings(res, "gc4_annular_ring")[0]
    assert f["ref"] == "U1"
    assert f["pad"] == "1"
    assert f["net_name"] == "GND"
