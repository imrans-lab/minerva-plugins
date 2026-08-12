"""GC11 — hole-to-edge (epoch CP2 station S8).

AUTHORED, NOT EXECUTED during CP2: this epoch writes tests at every station and
runs them for the first time after the Fable and Codex rounds that follow S8.

WHAT WAS FAIL-OPEN. Geometric DRC had no hole-to-edge class at all. GC5 measures
COPPER to the edge, GC6 measures holes against each other, and the pour carve
measures holes against copper — so a drill placed INSIDE a slot opening, or half
off the board rim, compiled, passed DRC clean, and emitted a drill file the fab
would run against a board that has no material there.

THE SPLIT IS THE DESIGN. Containment is UNCONDITIONAL: a bore outside the
material is nonsense at any tolerance and needs no published number. Proximity is
gated on the OPTIONAL ``min_hole_to_edge_mm``, which NO shipped profile declares
because none of the three publishes such a figure. Collapsing the two would have
made the useful half hostage to a number nobody states — the check would have
existed and never run. Several rows below exist specifically to prove the
unconditional half fires with the floor absent.

THE RULING UNDER TEST, and it is a REFUSAL of legitimate geometry: containment
permanently forecloses castellated / mouse-bite edge holes. See
``test_castellated_edge_holes_are_refused_and_that_is_the_ruling``.
"""

from __future__ import annotations

import copy
import math
from pathlib import Path

import pytest
import yaml

from pcb_worker.compile_board import compile_board
from pcb_worker.drc_geom_primitives import Capsule
from pcb_worker.drc_geometric import (
    GC11_CONTAINMENT,
    GC11_PROXIMITY,
    HolePrimitive,
    Projection,
    _aabb_loop_clearance,
    _check_gc11_hole_to_edge,
    _COUNT_KEYS,
    _hole_loop_clearance,
    run_geometric_drc,
)
from pcb_worker.manufacturer_profile import OPTIONAL_FLOOR_FIELDS
from pcb_worker.resolved_board import (
    Contour,
    LineGeometry,
    ProfileOutline,
    RectOutline,
    ResolutionSuccess,
    ResolvedCutout,
)

COUPON = Path(__file__).resolve().parent / "testdata" / "coupon_jlc1.yaml"

# A 10x10 board at the origin, for every stub row.
BOARD_W = BOARD_H = 10.0


class _Minimums:
    def __init__(self, floor):
        self.min_hole_to_edge_mm = floor


class _Rules:
    def __init__(self, floor):
        self.minimums = _Minimums(floor)


class _Board:
    """The narrowest stand-in GC11 reads: the floor plus a real outline.

    The OUTLINE is a genuine IR object rather than a stub, because GC11 reads it
    through ``outline_frame`` / ``cutout_point_loops`` — the same projection GC5
    uses — and faking those would test a shape the checker never sees.
    """

    def __init__(self, floor=None, cutouts=()):
        self.design_rules = _Rules(floor)
        if cutouts:
            self.outline = ProfileOutline(outer=_rect_contour(
                0.0, 0.0, BOARD_W, BOARD_H), cutouts=tuple(cutouts))
        else:
            self.outline = RectOutline(origin=(0.0, 0.0), width_mm=BOARD_W,
                                       height_mm=BOARD_H)


def _rect_contour(x, y, w, h) -> Contour:
    pts = [(x, y), (x + w, y), (x + w, y + h), (x, y + h)]
    return Contour(segments=tuple(
        LineGeometry(a=pts[i], b=pts[(i + 1) % 4]) for i in range(4)))


def _cutout(x, y, w, h, cut_id="cut1") -> ResolvedCutout:
    return ResolvedCutout(id=cut_id, contour=_rect_contour(x, y, w, h))


def _hole(x, y, dia=1.0, *, entity="h", origin="board_hole", plated=False,
          net=None, ref=None):
    cap = Capsule.disc(x, y, dia / 2.0)
    return HolePrimitive(
        entity_id=entity, parent_id=None, origin=origin, net_id=net,
        plated=plated, capsules=(cap,), minor_mm=dia, position=(x, y),
        aabb=cap.aabb(), ref=ref)


def _slot(legs, width=0.5, *, entity="slot"):
    caps = tuple(Capsule(a[0], a[1], b[0], b[1], width / 2.0)
                 for a, b in zip(legs, legs[1:]))
    box = caps[0].aabb()
    for cap in caps[1:]:
        box = box.union(cap.aabb())
    return HolePrimitive(
        entity_id=entity, parent_id=None, origin="board_hole", net_id=None,
        plated=False, capsules=caps, minor_mm=width, position=legs[0],
        aabb=box, is_slot=True)


def _run(holes, floor=None, cutouts=()):
    proj = Projection(copper=(), holes=tuple(holes), annular=())
    return _check_gc11_hole_to_edge(proj, _Board(floor, cutouts))


# ---------------------------------------------------------------------------
# Containment: unconditional, and that is the point.
# ---------------------------------------------------------------------------


class TestContainmentNeedsNoFloor:
    def test_a_bore_crossing_the_rim_is_refused_with_no_floor_declared(self):
        """THE ROW THE WHOLE SPLIT EXISTS FOR. ``min_hole_to_edge_mm`` is None —
        which is the state of every profile we ship — and the check still fires.
        An implementation that early-returned on an absent floor would pass every
        other containment row in this file by never running."""
        found = _run([_hole(0.2, 5.0, dia=1.0)], floor=None)
        assert len(found) == 1
        assert found[0]["type"] == GC11_CONTAINMENT
        # Bore spans x -0.3..0.7; it hangs 0.3 past the rim.
        assert found[0]["measured_mm"] == pytest.approx(-0.3, abs=1e-9)

    def test_containment_reports_zero_as_its_required_value(self):
        """0.0 is the literal rule — the bore must not leave the material — not a
        floor that happens to be zero. A consumer rendering "required 0.28mm"
        next to a hole drilled through air would be describing a tolerance, and
        this is not one."""
        found = _run([_hole(0.2, 5.0)], floor=None)
        assert found[0]["required_mm"] == 0.0

    def test_a_bore_entirely_off_the_board_is_refused(self):
        found = _run([_hole(-4.0, 5.0)], floor=None)
        assert len(found) == 1
        assert found[0]["type"] == GC11_CONTAINMENT
        assert found[0]["measured_mm"] == pytest.approx(-4.5, abs=1e-9)

    def test_a_bore_tangent_to_the_rim_is_contained_and_passes(self):
        """Inset exactly 0. ``_violates`` treats AT the boundary as legal, and
        containment fires only on ``measured < -EPS``: touching the outline is
        contained, crossing it is not."""
        assert _run([_hole(0.5, 5.0, dia=1.0)], floor=None) == []

    def test_a_bore_inside_a_cutout_is_refused(self):
        found = _run([_hole(5.0, 5.0, dia=1.0)], floor=None,
                     cutouts=[_cutout(3.0, 3.0, 4.0, 4.0)])
        assert len(found) == 1
        assert found[0]["type"] == GC11_CONTAINMENT
        assert found[0]["edge"] == "cutout"
        assert found[0]["against_entity_id"] == "cut1"
        # Spine 2.0 deep inside the opening, plus the 0.5 bore radius.
        assert found[0]["measured_mm"] == pytest.approx(-2.5, abs=1e-9)

    def test_a_bore_straddling_a_cutout_edge_is_refused(self):
        found = _run([_hole(2.8, 5.0, dia=1.0)], floor=None,
                     cutouts=[_cutout(3.0, 3.0, 4.0, 4.0)])
        assert len(found) == 1
        assert found[0]["type"] == GC11_CONTAINMENT
        assert found[0]["measured_mm"] == pytest.approx(-0.3, abs=1e-9)

    def test_a_bore_clear_of_the_cutout_passes(self):
        assert _run([_hole(2.0, 5.0, dia=1.0)], floor=None,
                    cutouts=[_cutout(3.0, 3.0, 4.0, 4.0)]) == []

    def test_castellated_edge_holes_are_refused_and_that_is_the_ruling(self):
        """A DELIBERATE REFUSAL OF LEGITIMATE GEOMETRY, pinned so nobody repairs
        it as a bug.

        Castellations (and mouse-bite break-off tabs) are half-holes drilled ON
        the outline so the plating wraps the board edge — ordinary, correct, and
        refused here. The justification is that the SCHEMA CANNOT EXPRESS THEM: a
        hole is a bore at a point with no field saying "this one is meant to be
        cut through", so an edge-crossing bore is indistinguishable from a
        misplaced one, and fail-closed is the only safe reading.

        If castellations become authorable, they arrive as an explicit hole KIND
        and this check learns to exempt that kind. It must NOT be repaired by
        relaxing the geometry test, which would re-open the fault for every
        genuinely misplaced hole on every board."""
        castellation = _hole(0.0, 5.0, dia=1.0, entity="castellation")
        found = _run([castellation], floor=None)
        assert len(found) == 1
        assert found[0]["type"] == GC11_CONTAINMENT


# ---------------------------------------------------------------------------
# Proximity: gated, and absent on every profile we ship.
# ---------------------------------------------------------------------------


class TestProximityIsFloorGated:
    def test_no_floor_means_no_proximity_finding(self):
        """A bore 0.1 mm inside the rim — well inside any real fab's tolerance —
        is CLEAN when the profile publishes no figure. "The profile said nothing"
        is not "0.0", and it is not an invitation to substitute a number from
        somewhere else."""
        assert _run([_hole(0.6, 5.0, dia=1.0)], floor=None) == []

    def test_the_same_bore_violates_once_a_floor_is_declared(self):
        found = _run([_hole(0.6, 5.0, dia=1.0)], floor=0.3)
        assert len(found) == 1
        assert found[0]["type"] == GC11_PROXIMITY
        assert found[0]["measured_mm"] == pytest.approx(0.1, abs=1e-9)
        assert found[0]["required_mm"] == pytest.approx(0.3)

    def test_a_bore_exactly_on_the_floor_passes(self):
        assert _run([_hole(0.8, 5.0, dia=1.0)], floor=0.3) == []

    def test_proximity_applies_to_cutout_edges_too(self):
        found = _run([_hole(2.4, 5.0, dia=1.0)], floor=0.3,
                     cutouts=[_cutout(3.0, 3.0, 4.0, 4.0)])
        assert len(found) == 1
        assert found[0]["type"] == GC11_PROXIMITY
        assert found[0]["edge"] == "cutout"
        assert found[0]["measured_mm"] == pytest.approx(0.1, abs=1e-9)

    def test_containment_wins_and_never_double_reports(self):
        """A bore off the board has also broken any proximity floor. Emitting
        both would make one fault read as two, and would inflate every count a
        consumer uses to rank boards."""
        found = _run([_hole(0.2, 5.0, dia=1.0)], floor=0.3)
        assert len(found) == 1
        assert found[0]["type"] == GC11_CONTAINMENT

    def test_no_shipped_profile_declares_the_floor(self):
        """PINNED DOCTRINE, not an accident of the fixtures. None of the three
        shipped profiles publishes a hole-to-edge figure, so the proximity half
        does not run on anything in the corpus. If a profile ever declares one,
        this row fails and forces the epoch record to be updated rather than
        letting a previously-dormant check start firing unannounced."""
        import json

        profiles = Path(__file__).resolve().parents[2] / "library" / "profiles"
        declared = {p.name for p in profiles.glob("*.json")
                    if "min_hole_to_edge_mm" in json.loads(p.read_text())["floor"]}
        assert declared == set()
        assert "min_hole_to_edge_mm" in OPTIONAL_FLOOR_FIELDS


# ---------------------------------------------------------------------------
# The kernel. This is where an AABB shortcut would have gone wrong.
# ---------------------------------------------------------------------------


class TestTheCutoutKernelIsExact:
    def test_a_bore_clear_of_a_cutout_corner_is_not_falsely_refused(self):
        """THE ROW THAT JUSTIFIES A SECOND KERNEL.

        GC5 measures copper to a cutout with ``_aabb_loop_clearance``, and its
        AABB over-report is fine there: a spurious CLEARANCE finding is the
        fail-safe direction. Containment is different — the finding asserts "this
        hole is drilled through air", and being wrong about that refuses a legal
        board on a claim that is simply false.

        A round bore's bounding square pokes past the disc at each corner by
        r(sqrt2 - 1). Place a bore diagonally off a cutout corner, clear of it,
        and the corner lands INSIDE the bore's AABB: the AABB kernel reports
        overlap, the exact kernel reports the true positive clearance."""
        loop = [(3.0, 3.0), (7.0, 3.0), (7.0, 7.0), (3.0, 7.0)]
        # Centre 0.566 from the corner (3,3), so a 0.5-radius bore clears it by
        # 0.066 — while the corner sits 0.1 INSIDE the bore's bounding square.
        cap = Capsule.disc(2.6, 2.6, 0.5)
        exact, _hole_pt, _edge_pt = _hole_loop_clearance(cap, loop)
        assert exact == pytest.approx(math.hypot(0.4, 0.4) - 0.5, abs=1e-9)
        assert exact > 0.0

        aabb_measured, _cp, _wp = _aabb_loop_clearance(cap.aabb(), loop)
        assert aabb_measured == pytest.approx(-0.1, abs=1e-9), (
            "the AABB kernel is expected to over-report here; if it no longer "
            "does, this row's justification is gone and the exact kernel should "
            "be re-argued rather than silently kept")

        assert _run([_hole(2.6, 2.6, dia=1.0)], floor=None,
                    cutouts=[_cutout(3.0, 3.0, 4.0, 4.0)]) == []

    def test_the_sign_flips_on_the_contour_not_at_the_centre(self):
        """A bore whose SPINE is inside the opening is inside it however small
        the bore is. Measuring unsigned distance-to-contour would report a tiny
        hole deep inside a big slot as comfortably clear — a false clean, and the
        worst-shaped one: the deeper it sits, the healthier it reads."""
        loop = [(3.0, 3.0), (7.0, 3.0), (7.0, 7.0), (3.0, 7.0)]
        tiny_deep = Capsule.disc(5.0, 5.0, 0.05)
        measured, _hp, _ep = _hole_loop_clearance(tiny_deep, loop)
        assert measured == pytest.approx(-2.05, abs=1e-9)

    def test_a_slot_is_judged_by_its_worst_leg(self):
        """A routed slot projects one capsule per path leg. Taking the first leg,
        or the slot's nominal position, clears a slot whose far end runs into the
        opening."""
        # Leg 1 is far from the cutout; leg 2 drives into it.
        slot = _slot([(1.0, 1.0), (1.0, 5.0), (4.0, 5.0)], width=0.5)
        found = _run([slot], floor=None, cutouts=[_cutout(3.0, 3.0, 4.0, 4.0)])
        assert len(found) == 1
        assert found[0]["type"] == GC11_CONTAINMENT
        assert found[0]["measured_mm"] < 0.0


# ---------------------------------------------------------------------------
# Bookkeeping and finding shape.
# ---------------------------------------------------------------------------


class TestBookkeeping:
    def test_both_count_keys_exist(self):
        """Two keys, not one: a consumer must be able to tell a REFUSAL from a
        tolerance without parsing prose. And a check missing from _COUNT_KEYS is
        invisible on a violating board and shows only on a clean one."""
        assert GC11_CONTAINMENT in _COUNT_KEYS
        assert GC11_PROXIMITY in _COUNT_KEYS

    def test_a_finding_names_which_edge_it_hit(self):
        rim = _run([_hole(0.2, 5.0)], floor=None)[0]
        assert rim["edge"] == "rim"
        assert "against_entity_id" not in rim
        cut = _run([_hole(5.0, 5.0)], floor=None,
                   cutouts=[_cutout(3.0, 3.0, 4.0, 4.0)])[0]
        assert cut["edge"] == "cutout"
        assert cut["against_entity_id"] == "cut1"

    def test_the_witness_sits_on_the_edge_it_names(self):
        """The edge witness must land ON the outline, so a reader can see which
        boundary the bore hit rather than inferring it from the hole's own
        position."""
        found = _run([_hole(0.2, 5.0)], floor=None)[0]
        assert found["witness"] == [0.0, 5.0]

    def test_findings_are_deterministic_under_input_order(self):
        holes = [_hole(0.2, 5.0, entity="hb"), _hole(0.2, 2.0, entity="ha")]
        forward = _run(holes, floor=None)
        reverse = _run(list(reversed(holes)), floor=None)
        assert len(forward) == 2
        assert forward == reverse
        assert [f["entity_id"] for f in forward] == ["ha", "hb"]

    def test_every_cutout_is_measured_not_just_the_first(self):
        """A board with several openings must have all of them checked; the loop
        over cutouts is easy to write as a ``next()``."""
        found = _run([_hole(2.0, 2.0, dia=3.0)], floor=None,
                     cutouts=[_cutout(3.0, 3.0, 2.0, 2.0, "cutA"),
                              _cutout(0.5, 0.5, 1.0, 1.0, "cutB")])
        assert {f["against_entity_id"] for f in found} == {"cutA", "cutB"}


# ---------------------------------------------------------------------------
# End to end, on the real seed board.
# ---------------------------------------------------------------------------


def _coupon_with(holes):
    board = copy.deepcopy(yaml.safe_load(COUPON.read_text(encoding="utf-8")))
    if holes:
        # The coupon is board-source v2 (strict ids): mint a "<kind>:<32hex>"
        # id for any added hole, at this one funnel rather than in five
        # callers. Deterministic per index so failures stay reproducible.
        board["mounting_holes"] = [
            dict(hole, id=hole.get("id", f"hole:{index:032x}"))
            for index, hole in enumerate(holes, start=1)]
    result = compile_board(board)
    assert isinstance(result, ResolutionSuccess), \
        [(d.code, d.message) for d in result.diagnostics]
    return run_geometric_drc(result.board)


class TestOnTheCoupon:
    """The coupon carries a real 3x6 mm slot cutout at x 10.8..13.8,
    y 5.0..11.0, which is what makes it a usable end-to-end fixture here."""

    def test_the_coupon_is_untouched_by_this_station(self):
        drc = _coupon_with([])
        assert drc["ok"] is True
        assert drc["verdict"] == "clean"
        assert drc["counts"][GC11_CONTAINMENT] == 0
        assert drc["counts"][GC11_PROXIMITY] == 0

    def test_a_hole_drilled_inside_the_coupons_slot_is_refused(self):
        drc = _coupon_with(
            [{"x_mm": 12.3, "y_mm": 8.0, "diameter_mm": 1.0, "plated": False}])
        assert drc["verdict"] == "violations"
        rows = [f for f in drc["findings"] if f["type"] == GC11_CONTAINMENT]
        assert len(rows) == 1
        # 1.5 mm in from the nearest slot edge, plus the 0.5 mm bore radius.
        assert rows[0]["measured_mm"] == pytest.approx(-2.0, abs=1e-6)
        assert rows[0]["edge"] == "cutout"

    def test_a_hole_that_only_GRAZES_the_slot_is_still_refused(self):
        """y=4.9 sits below the slot, but the bore's upper edge crosses y=5.0 by
        0.4 mm. The fault is the bore, not the drill point — an implementation
        testing only the centre passes this."""
        drc = _coupon_with(
            [{"x_mm": 12.3, "y_mm": 4.9, "diameter_mm": 1.0, "plated": False}])
        rows = [f for f in drc["findings"] if f["type"] == GC11_CONTAINMENT]
        assert len(rows) == 1
        assert rows[0]["measured_mm"] == pytest.approx(-0.4, abs=1e-6)

    def test_the_same_hole_clear_of_the_slot_leaves_the_board_clean(self):
        """y=4.0 -> the bore's upper edge is 0.5 mm below the slot. The board
        returns to determinately clean, so the two rows above are proving
        DISTANCE sensitivity rather than "adding a hole fires something"."""
        drc = _coupon_with(
            [{"x_mm": 12.3, "y_mm": 4.0, "diameter_mm": 1.0, "plated": False}])
        assert drc["verdict"] == "clean"
        assert drc["findings"] == []

    def test_a_hole_half_off_the_coupon_rim_is_refused(self):
        drc = _coupon_with(
            [{"x_mm": 0.1, "y_mm": 8.0, "diameter_mm": 1.0, "plated": False}])
        rows = [f for f in drc["findings"] if f["type"] == GC11_CONTAINMENT]
        assert len(rows) == 1
        assert rows[0]["edge"] == "rim"
        assert rows[0]["measured_mm"] == pytest.approx(-0.4, abs=1e-6)

    def test_the_proximity_half_never_runs_on_this_profile(self):
        """STATED, not assumed. jlcpcb-2layer declares no min_hole_to_edge_mm, so
        the proximity key is 0 on every coupon variant above — including the ones
        with a hole 0.5 mm from the slot, which a declared floor would flag. That
        0 means "the profile said nothing", and this row is what keeps it from
        being read as "checked and clean"."""
        drc = _coupon_with(
            [{"x_mm": 12.3, "y_mm": 4.0, "diameter_mm": 1.0, "plated": False}])
        assert drc["counts"][GC11_PROXIMITY] == 0
        rb = compile_board(yaml.safe_load(COUPON.read_text(encoding="utf-8"))).board
        assert rb.design_rules.minimums.min_hole_to_edge_mm is None
