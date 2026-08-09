"""GC9 — silkscreen DFM (epoch CP2 station S6).

AUTHORED, NOT EXECUTED during CP2: first execution comes after the Fable and
Codex rounds that follow S8.

TWO FLOORS, BOTH OPTIONAL-TIER, BOTH TAKEN FROM A PUBLISHED PAGE:
  min_silk_width_mm   — "Minimum Line Width: >=0.15mm"
  min_silk_to_pad_mm  — "The Minimum Distance Between Pad and Silkscreen: 0.15mm"
(JLCPCB capabilities, re-fetched 2026-08-09.)

THE FIELD NAME IS NOT THE ONE THE PLAN ASKED FOR, deliberately. The station
called for `min_silk_to_mask_mm`; JLCPCB publishes a silk-to-PAD figure and no
silk-to-mask-opening figure at all. A mask opening is the pad plus the mask
allowance, so the two are different quantities, and filing a pad clearance under
a mask-clearance name would have invented a semantics — the same class of error
as inventing a number. Tests below measure against COPPER PADS accordingly.

ABSENT MEANS SILENT. A profile that publishes no silk rule enforces none of
this, which is the optional-tier doctrine ("said nothing" is not "zero"). Half
of this file exists to pin that, because a check that quietly enforces a
defaulted number would be worse than one that does not run.
"""

from __future__ import annotations

import dataclasses
import math

import pytest

from pcb_worker import silk_source
from pcb_worker.drc_geom_primitives import Capsule, OrientedRect
from pcb_worker.drc_geometric import (
    CopperPrimitive,
    Projection,
    SilkPrimitive,
    _check_gc9_silk,
    _silk_capsules,
)
from pcb_worker.resolved_board import Side

WIDTH_FLOOR = 0.15
PAD_FLOOR = 0.15


class _Minimums:
    def __init__(self, width=None, to_pad=None):
        self.min_silk_width_mm = width
        self.min_silk_to_pad_mm = to_pad


class _Rules:
    def __init__(self, **kw):
        self.minimums = _Minimums(**kw)


class _Board:
    def __init__(self, **kw):
        self.design_rules = _Rules(**kw)


def _line(x1, y1, x2, y2, width=0.15, side=Side.TOP, entity="g1"):
    return SilkPrimitive(
        entity_id=entity, parent_id="c1", side=side,
        geometry=silk_source.SilkLine(x1, y1, x2, y2, width),
        width_mm=width, origin="graphic", ref="R1")


def _pad(cx, cy, w=1.0, h=1.0, layers=("F.Cu",), entity="pad1"):
    return CopperPrimitive(
        entity_id=entity, parent_id="c1", kind="smd_pad", layers=tuple(layers),
        net_id=None, shape=OrientedRect(cx, cy, w / 2.0, h / 2.0, 0.0),
        aabb=OrientedRect(cx, cy, w / 2.0, h / 2.0, 0.0).aabb(),
        ref="R1", pad_number="1")


def _run(silk=(), copper=(), warnings=(), **floors):
    proj = Projection(copper=tuple(copper), holes=(), annular=(),
                      silk=tuple(silk), silk_warnings=tuple(warnings))
    return _check_gc9_silk(proj, _Board(**floors))


def _types(findings):
    return sorted(f["type"] for f in findings)


# ---------------------------------------------------------------------------
# Absent floors enforce nothing.
# ---------------------------------------------------------------------------


def test_no_declared_floors_means_no_silk_findings():
    """THE OPTIONAL-TIER CONTRACT. A profile that publishes no silkscreen rule
    must produce no silk findings — not "checked and clean", but not checked.
    A hairline stroke sitting on top of a pad passes here, and that is correct:
    nobody stated a rule for it."""
    findings = _run(silk=[_line(0, 0, 1, 0, width=0.01)],
                    copper=[_pad(0.5, 0.0)])
    assert findings == []


def test_the_width_floor_alone_does_not_enable_the_pad_check():
    """The two floors are independent fields and must gate independently. A
    profile publishing only a line width has said nothing about clearance."""
    findings = _run(silk=[_line(0, 0, 1, 0, width=0.2)],
                    copper=[_pad(0.5, 0.0)],
                    width=WIDTH_FLOOR)
    assert _types(findings) == []


def test_the_pad_floor_alone_does_not_enable_the_width_check():
    findings = _run(silk=[_line(0, 5, 1, 5, width=0.01)],
                    copper=[_pad(0.5, 0.0)],
                    to_pad=PAD_FLOOR)
    assert _types(findings) == []


# ---------------------------------------------------------------------------
# Stroke width.
# ---------------------------------------------------------------------------


def test_a_stroke_below_the_width_floor_is_flagged():
    findings = _run(silk=[_line(0, 0, 1, 0, width=0.12)], width=WIDTH_FLOOR)
    assert len(findings) == 1
    f = findings[0]
    assert f["type"] == "gc9_silk_width"
    assert f["measured_mm"] == pytest.approx(0.12)
    assert f["required_mm"] == pytest.approx(0.15)
    assert f["layer"] == "F.SilkS"
    assert f["ref"] == "R1"


def test_a_stroke_exactly_at_the_width_floor_passes():
    """AT the floor passes, consistent with every other check in the module.
    This is the case that matters most here: the seed fixtures authored for this
    epoch sit exactly at 0.15, so a strict `<=` would fail the whole corpus."""
    assert _run(silk=[_line(0, 0, 1, 0, width=0.15)], width=WIDTH_FLOOR) == []


def test_bottom_side_strokes_are_flagged_on_their_own_layer():
    findings = _run(silk=[_line(0, 0, 1, 0, width=0.1, side=Side.BOTTOM)],
                    width=WIDTH_FLOOR)
    assert len(findings) == 1
    assert findings[0]["layer"] == "B.SilkS"


def test_synthesized_designators_are_checked_too():
    """A reference designator is in NO IR — it is generated at emission. If the
    width rule skipped synthesized strokes, the most common silk on any board
    would go unchecked, which is the same blind spot the S4 projection existed
    to remove."""
    prim = dataclasses.replace(
        _line(0, 0, 1, 0, width=0.05), origin="refdes")
    findings = _run(silk=[prim], width=WIDTH_FLOOR)
    assert len(findings) == 1
    assert findings[0]["origin"] == "refdes"


# ---------------------------------------------------------------------------
# Silk to pad.
# ---------------------------------------------------------------------------


def test_silk_far_from_every_pad_is_clean():
    assert _run(silk=[_line(0, 5, 1, 5)], copper=[_pad(0.5, 0.0)],
                to_pad=PAD_FLOOR) == []


def test_silk_too_close_to_a_pad_is_flagged():
    # Pad spans y = -0.5..0.5 at x 0..1; a stroke at y=0.6 with half-width
    # 0.075 reaches y=0.525, leaving 0.025 to the pad edge.
    findings = _run(silk=[_line(0, 0.6, 1, 0.6, width=0.15)],
                    copper=[_pad(0.5, 0.0)], to_pad=PAD_FLOOR)
    assert len(findings) == 1
    f = findings[0]
    assert f["type"] == "gc9_silk_to_pad"
    assert f["measured_mm"] == pytest.approx(0.025)
    assert f["pad"] == "1"


def test_the_stroke_width_counts_toward_the_clearance_not_just_the_centreline():
    """Silk is DRAWN geometry: its physical extent is the centreline swept by
    half the stroke width. Measuring centreline-to-pad would over-report
    clearance by half the width on every stroke — always in the unsafe
    direction."""
    near = _run(silk=[_line(0, 0.65, 1, 0.65, width=0.3)],
                copper=[_pad(0.5, 0.0)], to_pad=PAD_FLOOR)
    assert near, "a wide stroke must be measured by its EDGE, not its centre"


def test_silk_is_only_compared_against_pads_on_its_own_side():
    """Front legend cannot contaminate a pad that exists only on the back."""
    findings = _run(silk=[_line(0, 0.55, 1, 0.55, width=0.1)],
                    copper=[_pad(0.5, 0.0, layers=("B.Cu",))],
                    to_pad=PAD_FLOOR)
    assert findings == []


def test_through_hole_pads_participate_on_both_sides():
    """A TH pad's copper reaches both outer layers, so legend on either side can
    sit on it."""
    for side in (Side.TOP, Side.BOTTOM):
        findings = _run(
            silk=[_line(0, 0.55, 1, 0.55, width=0.1, side=side)],
            copper=[_pad(0.5, 0.0, layers=("F.Cu", "B.Cu"))],
            to_pad=PAD_FLOOR)
        assert len(findings) == 1, f"{side} legend must see a TH pad"


def test_traces_are_not_treated_as_pads():
    """The published rule is about PADS — legend over a trace is cosmetic,
    legend over a pad contaminates a solderable surface. Including traces would
    flag ordinary, acceptable artwork."""
    trace = CopperPrimitive(
        entity_id="seg1", parent_id="t1", kind="trace_seg", layers=("F.Cu",),
        net_id=None, shape=Capsule(0.0, 0.0, 1.0, 0.0, 0.1),
        aabb=Capsule(0.0, 0.0, 1.0, 0.0, 0.1).aabb(), width_mm=0.2)
    assert _run(silk=[_line(0, 0.15, 1, 0.15, width=0.1)], copper=[trace],
                to_pad=PAD_FLOOR) == []


def test_the_finding_carries_witness_points_from_the_same_kernel():
    """A finding a human can act on has to say WHERE. The two witness points
    come from the same distance kernel that produced the number, so opening the
    board at those coordinates shows the pair the measurement came from."""
    findings = _run(silk=[_line(0, 0.6, 1, 0.6, width=0.15)],
                    copper=[_pad(0.5, 0.0)], to_pad=PAD_FLOOR)
    f = findings[0]
    assert len(f["closest"]) == 2 and len(f["witness"]) == 2
    assert "midpoint" in f


# ---------------------------------------------------------------------------
# Curved strokes — the approximation direction is the whole point.
# ---------------------------------------------------------------------------


def test_a_circle_decomposes_into_capsules_that_contain_the_true_stroke():
    """THE FAIL-SAFE DIRECTION, asserted rather than asserted-in-a-comment.

    A circle is approximated by an inscribed polyline. Chord midpoints sit
    INSIDE the true arc, so a naive polyline UNDER-states how far the stroke
    reaches outward — which would over-report clearance to a pad outside the
    circle, the unsafe direction. The capsule radius is inflated by the sagitta
    so the modelled body always CONTAINS the true stroke.
    """
    radius, width = 2.0, 0.15
    prim = SilkPrimitive(
        entity_id="c", parent_id="p", side=Side.TOP,
        geometry=silk_source.SilkCircle(0.0, 0.0, radius, width),
        width_mm=width, origin="graphic", ref="R1")
    caps = _silk_capsules(prim)
    assert len(caps) >= 4

    # The true stroke's outer edge is at radius + width/2. Every point of the
    # modelled body must reach at least that far where the true stroke does —
    # check at each chord midpoint, the worst case.
    outer = radius + width / 2.0
    for cap in caps:
        mx, my = (cap.ax + cap.bx) / 2.0, (cap.ay + cap.by) / 2.0
        reach = math.hypot(mx, my) + cap.r
        assert reach >= outer - 1e-9, (
            f"the polyline under-reaches the true circle at a chord midpoint: "
            f"{reach} < {outer}")


def test_a_degenerate_zero_radius_circle_does_not_explode():
    prim = SilkPrimitive(
        entity_id="c", parent_id="p", side=Side.TOP,
        geometry=silk_source.SilkCircle(1.0, 1.0, 0.0, 0.15),
        width_mm=0.15, origin="graphic", ref="R1")
    caps = _silk_capsules(prim)
    assert len(caps) == 1
    assert (caps[0].ax, caps[0].ay) == (1.0, 1.0)


def test_a_closed_poly_closes_its_last_segment():
    """An open and a closed polyline differ by exactly one segment, and the
    missing one is the segment most likely to be the one near a pad."""
    pts = ((0.0, 0.0), (1.0, 0.0), (1.0, 1.0))
    open_prim = SilkPrimitive(
        entity_id="p", parent_id="c", side=Side.TOP,
        geometry=silk_source.SilkPoly(pts, 0.15, False),
        width_mm=0.15, origin="graphic", ref="R1")
    closed_prim = dataclasses.replace(
        open_prim, geometry=silk_source.SilkPoly(pts, 0.15, True))
    assert len(_silk_capsules(open_prim)) == 2
    assert len(_silk_capsules(closed_prim)) == 3


# ---------------------------------------------------------------------------
# Dropped artwork — the silk_warnings obligation.
# ---------------------------------------------------------------------------


def test_dropped_silk_is_reported_not_silently_cleared():
    """THE S4 OBLIGATION, discharged. `Projection.silk_warnings` carries
    primitives the shared harvest could not build. Until this station nothing
    read it, so a checker could inherit a narrower artwork set than the emitter
    draws and clear legend it never measured."""
    findings = _run(warnings=[("silk_primitive_unemitted", "arc dropped", "R1")])
    assert len(findings) == 1
    f = findings[0]
    assert f["type"] == "gc9_silk_indeterminate"
    assert f["code"] == "silk_primitive_unemitted"
    assert f["ref"] == "R1"


def test_the_dropped_row_carries_no_measurement():
    """It has none. A row that reported measured_mm=0.0 to satisfy a signature
    would read as a catastrophic violation instead of an unanswered question —
    the difference between "this is 0mm wide" and "we could not see this"."""
    f = _run(warnings=[("silk_primitive_unemitted", "arc dropped", None)])[0]
    assert f["measured_mm"] is None
    assert f["required_mm"] is None


def test_dropped_silk_is_reported_even_with_no_floors_declared():
    """NOT gated on a floor. "The checker could not see this artwork" is true
    whatever numbers the profile publishes, so a profile that declares no silk
    rule still learns that geometry went missing."""
    findings = _run(warnings=[("silk_primitive_unemitted", "x", "R1")])
    assert _types(findings) == ["gc9_silk_indeterminate"]


# ---------------------------------------------------------------------------
# Advisory, not blocking — the station's central decision.
# ---------------------------------------------------------------------------


def test_every_gc9_row_type_is_declared_advisory():
    """The list that decides blocking-vs-advisory must cover every row GC9 can
    emit. A type missing from it would silently become a BLOCKING violation, and
    on a legend rule that means refusing real boards."""
    from pcb_worker.drc_geometric import GC9_ADVISORY_TYPES

    emitted = _run(
        silk=[_line(0, 0.6, 1, 0.6, width=0.12)],
        copper=[_pad(0.5, 0.0)],
        warnings=[("silk_primitive_unemitted", "x", "R1")],
        width=WIDTH_FLOOR, to_pad=PAD_FLOOR)
    assert {f["type"] for f in emitted} <= GC9_ADVISORY_TYPES
    # And the reverse: nothing is declared advisory that GC9 cannot produce, so
    # the set cannot quietly grow to cover a check that SHOULD block.
    assert GC9_ADVISORY_TYPES == {
        "gc9_silk_width", "gc9_silk_to_pad", "gc9_silk_indeterminate"}


def test_silk_advisories_do_not_flip_the_verdict_but_are_counted():
    """THE DECISION THIS STATION TURNS ON, asserted end to end.

    JLCPCB publishes a 0.15mm minimum silk line width; KiCad's shipped library
    — which every real board is authored from — draws 0.12. Measured on the seed
    library: 15 of the 17 silk-graphic-carrying footprints are sub-0.15 (94 of
    202 primitives; re-measured in the CP2 S8 review round). A blocking rule
    would refuse essentially every real board, so silk rows are ADVISORY, which
    is also what this codebase's own output-criticality doctrine already says
    (fab_capability excludes silk from FABRICATION_CRITICAL_OUTPUTS: "warned,
    never fatal").

    Advisory must not mean hidden, so both halves are pinned here: the verdict
    is unaffected AND the rows are present and counted.
    """
    import yaml

    from pcb_worker.compile_board import compile_board
    from pcb_worker.drc_geometric import run_geometric_drc
    from pcb_worker.resolved_board import ResolutionSuccess
    from pathlib import Path

    coupon = Path(__file__).resolve().parent / "testdata" / "coupon_jlc1.yaml"
    result = compile_board(yaml.safe_load(coupon.read_text(encoding="utf-8")))
    assert isinstance(result, ResolutionSuccess)
    drc = run_geometric_drc(result.board)

    # The coupon genuinely carries sub-floor legend: its stock TH_TestPoint and
    # PinHeader footprints draw at 0.12. That is REAL, not contrived — it is
    # what a board built from the standard library looks like.
    assert drc["counts"]["gc9_silk_width"] > 0, (
        "the coupon should still exercise this rule; if it no longer does, the "
        "coupon stopped being representative of real authoring")
    assert drc["advisories"], "advisory rows must be returned, not just counted"
    assert all(a["type"] in GC9_TYPES for a in drc["advisories"])

    # ...and none of it blocks.
    assert drc["verdict"] == "clean"
    assert drc["findings"] == []


GC9_TYPES = {"gc9_silk_width", "gc9_silk_to_pad", "gc9_silk_indeterminate"}
