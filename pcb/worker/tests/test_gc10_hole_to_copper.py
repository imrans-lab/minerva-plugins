"""GC10 — hole-to-copper (epoch CP2 station S7).

AUTHORED, NOT EXECUTED during CP2: this epoch writes tests at every station and
runs them for the first time after the Fable and Codex rounds that follow S8.

WHAT THIS CHECK IS FOR. ``min_hole_to_copper_mm`` is declared by the shipping
JLCPCB profile (0.28, quoted "PTH to Track: 0.28mm minimum") and, until this
station, its ONLY reader was the zone-fill pour carve. A track 0.10 mm from a
through-hole barrel passed geometric DRC clean — the profile said one thing and
the checker enforced another, which is the fail-open shape this epoch exists to
close.

THE WHOLE DIFFICULTY IS THE EXEMPTION, and it is difficult in the false-POSITIVE
direction rather than the usual false-clean one. Every drilled feature sits
inside its own copper land by design: the gap between a via's bore and its own
ring is the annular web, roughly 0.18 mm on this profile — comfortably below any
hole-to-copper floor. Get the exemption wrong and GC10 flags every plated hole on
every board against itself, which is not a subtle failure but it IS a subtle
mistake to make, because the obvious formulation is wrong in a way that looks
right:

    "exempt same-net copper"  -- INSUFFICIENT.

``_same_net_exempt``'s rule (both net_ids non-null and equal) never fires for a
plated board hole, whose hole AND whose own ``board_hole_copper`` primitive both
carry ``net_id=None``; nor for an unconnected PTH pad, which carries None on both
halves of itself. So the tests below spend most of their weight on the exemption
predicate: what it must catch, and — equally — what it must NOT catch, because an
over-broad exemption is a false clean and those are the ones that matter.
"""

from __future__ import annotations

from pathlib import Path

import pytest
import yaml

from pcb_worker.compile_board import compile_board
from pcb_worker.drc_geom_primitives import Capsule, OrientedRect
from pcb_worker.drc_geometric import (
    CopperPrimitive,
    HolePrimitive,
    Projection,
    _check_gc10_hole_to_copper,
    _COUNT_KEYS,
    _hole_copper_exempt,
    project_board,
    run_geometric_drc,
)
from pcb_worker.resolved_board import ResolutionSuccess

FLOOR = 0.28

COUPON = Path(__file__).resolve().parent / "testdata" / "coupon_jlc1.yaml"


class _Minimums:
    def __init__(self, floor):
        self.min_hole_to_copper_mm = floor


class _Rules:
    def __init__(self, floor):
        self.minimums = _Minimums(floor)


class _Board:
    """The narrowest stand-in GC10 actually reads.

    GC10 consumes exactly ``rb.design_rules.minimums.min_hole_to_copper_mm`` plus
    the projection's ``holes`` and ``copper`` tuples, so a stub keeps each failure
    attributable to the rule under test rather than to compilation. End-to-end
    wiring is covered at the bottom of this file against the real coupon.
    """

    def __init__(self, floor=FLOOR):
        self.design_rules = _Rules(floor)


def _hole(x=0.0, y=0.0, dia=0.4, *, entity="h", parent=None, origin="via",
          net=None, plated=True, ref=None, pad=None, net_name=None):
    cap = Capsule.disc(x, y, dia / 2.0)
    return HolePrimitive(
        entity_id=entity, parent_id=parent, origin=origin, net_id=net,
        plated=plated, capsules=(cap,), minor_mm=dia, position=(x, y),
        aabb=cap.aabb(), ref=ref, pad_number=pad, net_name=net_name)


def _disc_copper(x=0.0, y=0.0, dia=0.8, *, entity="c", parent=None,
                 kind="via", net=None, ref=None, pad=None, net_name=None):
    cap = Capsule.disc(x, y, dia / 2.0)
    return CopperPrimitive(
        entity_id=entity, parent_id=parent, kind=kind, layers=("top",),
        net_id=net, shape=cap, aabb=cap.aabb(), ref=ref, pad_number=pad,
        net_name=net_name)


def _trace(ax, ay, bx, by, width=0.2, *, entity="t", parent="tr", net="NET"):
    cap = Capsule(ax, ay, bx, by, width / 2.0)
    return CopperPrimitive(
        entity_id=entity, parent_id=parent, kind="trace_seg", layers=("top",),
        net_id=net, shape=cap, aabb=cap.aabb(), width_mm=width, net_name=net)


def _rect_pad(cx, cy, w=1.0, h=1.0, *, entity="p", parent=None, net=None,
              kind="smd_pad"):
    rect = OrientedRect(cx, cy, w / 2.0, h / 2.0, 0.0)
    return CopperPrimitive(
        entity_id=entity, parent_id=parent, kind=kind, layers=("top",),
        net_id=net, shape=rect, aabb=rect.aabb(), net_name=net)


def _run(holes, copper, floor=FLOOR):
    proj = Projection(copper=tuple(copper), holes=tuple(holes), annular=())
    return _check_gc10_hole_to_copper(proj, _Board(floor))


# ---------------------------------------------------------------------------
# The floor itself.
# ---------------------------------------------------------------------------


class TestTheFloorIsOptional:
    def test_absent_floor_checks_nothing(self):
        """``None`` means the profile PUBLISHED no hole-to-copper figure.

        "The profile said nothing" is not "checked and clean" — but it is also
        not a licence to invent 0.28 for a fab that never stated it. Geometry
        that would violate under JLCPCB must pass silently here."""
        hole = _hole(0.0, 0.0, 0.4, entity="h")
        near = _trace(0.0, 0.25, 2.0, 0.25, width=0.2, entity="t", net="N")
        assert _run([hole], [near], floor=None) == []
        # ... and the SAME geometry under a stated floor is a violation, so the
        # row above is proving the floor is read, not that the pair is far apart.
        assert len(_run([hole], [near], floor=FLOOR)) == 1

    def test_zero_floor_is_a_floor_not_an_absence(self):
        """0.0 is a published rule meaning "may touch, may not overlap", and it
        is NOT the same as None. A ``if not required:`` implementation conflates
        them; only ``is None`` distinguishes."""
        hole = _hole(0.0, 0.0, 0.4)
        # Copper OVERLAPPING the bore: edge distance is negative.
        overlapping = _disc_copper(0.1, 0.0, 0.4, entity="c", net="N")
        assert len(_run([hole], [overlapping], floor=0.0)) == 1

    def test_the_count_key_exists(self):
        """A check absent from ``_COUNT_KEYS`` still counts its findings via the
        ``.get`` fallback, so the omission is invisible on a VIOLATING board and
        shows only on a clean one — where the key is missing instead of zero, and
        a consumer cannot tell "ran, found nothing" from "did not run"."""
        assert "gc10_hole_to_copper" in _COUNT_KEYS


# ---------------------------------------------------------------------------
# The measurement.
# ---------------------------------------------------------------------------


class TestTheMeasurement:
    def test_measured_is_edge_to_edge_not_centre_to_centre(self):
        """Assert the VALUE, not the cardinality. A centre-to-centre
        implementation also reports exactly one finding here, and would pass a
        test that only counted rows."""
        # Bore radius 0.2, trace half-width 0.1, centres 0.45 apart in y.
        # Edge-to-edge = 0.45 - 0.2 - 0.1 = 0.15.
        hole = _hole(0.0, 0.0, 0.4)
        trace = _trace(-2.0, 0.45, 2.0, 0.45, width=0.2, net="N")
        found = _run([hole], [trace])
        assert len(found) == 1
        assert found[0]["measured_mm"] == pytest.approx(0.15, abs=1e-9)
        assert found[0]["required_mm"] == pytest.approx(FLOOR)

    def test_a_pair_exactly_on_the_floor_passes(self):
        """``_violates`` is ``measured < required - EPS``: AT the floor is legal.
        A fab publishing a 0.28 minimum accepts 0.28."""
        # Edge-to-edge exactly 0.28: 0.2 (bore) + 0.1 (half width) + 0.28.
        hole = _hole(0.0, 0.0, 0.4)
        trace = _trace(-2.0, 0.58, 2.0, 0.58, width=0.2, net="N")
        assert _run([hole], [trace]) == []

    def test_a_hair_under_the_floor_fails(self):
        hole = _hole(0.0, 0.0, 0.4)
        trace = _trace(-2.0, 0.5795, 2.0, 0.5795, width=0.2, net="N")
        found = _run([hole], [trace])
        assert len(found) == 1
        assert found[0]["measured_mm"] == pytest.approx(0.2795, abs=1e-9)

    def test_overlapping_copper_reports_a_negative_measurement(self):
        """Copper ON TOP of a bore is the worst case and must not read as a
        near-miss. The measurement is signed, so it stays orderable against every
        other finding rather than clamping to zero."""
        hole = _hole(0.0, 0.0, 0.4)
        over = _rect_pad(0.0, 0.0, 1.0, 1.0, entity="p", net="N")
        found = _run([hole], [over])
        assert len(found) == 1
        assert found[0]["measured_mm"] < 0.0

    def test_a_slot_measures_from_the_nearest_leg(self):
        """A routed slot projects one capsule PER PATH LEG. The reported distance
        must be the minimum over legs — taking the first, or the centre, would
        clear copper sitting against the far end of an L-shaped slot."""
        far = Capsule(-2.0, 0.0, -1.0, 0.0, 0.25)
        near = Capsule(-1.0, 0.0, 1.0, 0.0, 0.25)
        hole = HolePrimitive(
            entity_id="slot", parent_id=None, origin="board_hole", net_id=None,
            plated=False, capsules=(far, near), minor_mm=0.5,
            position=(-2.0, 0.0),
            aabb=far.aabb().union(near.aabb()), is_slot=True)
        # Copper 0.1 from the NEAR leg, far from the first one in the tuple.
        trace = _trace(0.5, 0.45, 2.5, 0.45, width=0.2, net="N")
        found = _run([hole], [trace])
        assert len(found) == 1
        assert found[0]["measured_mm"] == pytest.approx(0.1, abs=1e-9)


# ---------------------------------------------------------------------------
# The exemption — what it MUST catch.
# ---------------------------------------------------------------------------


class TestExemptionsThatMustFire:
    def test_a_hole_is_exempt_from_its_own_land(self):
        """The annular web is GC4's rule (``min_annular_ring_mm``, 0.18 here),
        not this one, and it is ALWAYS below the hole-to-copper floor. Without
        the same-entity exemption, GC10 flags every plated hole on every board
        against itself."""
        hole = _hole(0.0, 0.0, 0.4, entity="V1", net="GND")
        land = _disc_copper(0.0, 0.0, 0.8, entity="V1", net="GND")
        assert _hole_copper_exempt(hole, land) is True
        assert _run([hole], [land]) == []

    def test_an_unconnected_pth_pad_is_exempt_from_its_own_land(self):
        """THE CASE A NET-ONLY EXEMPTION MISSES. Both halves of an unconnected
        pad carry ``net_id=None``, and ``_same_net_exempt``'s rule (both non-null
        and equal) is False for None-vs-None. Only the entity identity saves it."""
        hole = _hole(0.0, 0.0, 0.9, entity="U1-3", parent="U1", origin="pad",
                     net=None, ref="U1", pad="3")
        land = _disc_copper(0.0, 0.0, 1.26, entity="U1-3", parent="U1",
                            kind="pth_pad", net=None, ref="U1", pad="3")
        assert land.net_id is None and hole.net_id is None
        assert _hole_copper_exempt(hole, land) is True
        assert _run([hole], [land]) == []

    def test_a_plated_board_hole_is_exempt_from_its_own_annulus(self):
        """The other None/None case: ``project_board`` gives a plated board hole
        and its ``board_hole_copper`` primitive the SAME entity_id and no net at
        all."""
        hole = _hole(5.0, 5.0, 3.2, entity="MH1", origin="board_hole", net=None)
        annulus = _disc_copper(5.0, 5.0, 3.56, entity="MH1",
                               kind="board_hole_copper", net=None)
        assert _hole_copper_exempt(hole, annulus) is True
        assert _run([hole], [annulus]) == []

    def test_a_same_net_plated_barrel_is_exempt_from_its_connecting_trace(self):
        """The barrel IS that net. Without this, the trace that LANDS on a
        through-hole pad flags on every board that routes anything — the gap
        from bore to trace is the annular web again."""
        hole = _hole(0.0, 0.0, 0.4, entity="V1", net="GND", plated=True)
        trace = _trace(0.0, 0.0, 3.0, 0.0, width=0.25, entity="t1", net="GND")
        assert _hole_copper_exempt(hole, trace) is True
        assert _run([hole], [trace]) == []

    def test_the_exemption_mirrors_zone_fills_carve_skip(self):
        """DRY, and load-bearing rather than tidy: the pour and the checker must
        exempt the SAME set, or a board is clean for the filler and dirty for the
        DRC (or worse, the reverse). ``zone_fill`` skips the carve exactly when
        ``hole.net_id is not None and hole.net_id == zone.net_id and
        hole.plated`` — the same three conjuncts, evaluated here against a copper
        primitive instead of a zone."""
        import inspect

        from pcb_worker import zone_fill

        # Anchored on the MODULE, not on `_obstacle_paths`, so a rename cannot
        # quietly turn this row into a skip. What is pinned is the predicate
        # itself; if the filler's rule moves, this fails loudly and the two
        # sides get reconciled deliberately instead of drifting apart.
        filler = inspect.getsource(zone_fill)
        assert "hole.net_id is not None and hole.net_id == zone.net_id" in filler
        assert "and hole.plated" in filler
        checker = inspect.getsource(_hole_copper_exempt)
        assert "hole.plated and hole.net_id is not None" in checker
        assert "hole.net_id == prim.net_id" in checker


# ---------------------------------------------------------------------------
# The exemption — what it MUST NOT catch. These are the false-clean rows.
# ---------------------------------------------------------------------------


class TestExemptionsThatMustNotFire:
    def test_an_unplated_hole_is_not_exempt_from_same_net_copper(self):
        """An unplated bore has NO copper barrel, so it connects nothing: a
        matching net field on it is a coincidence, and the drill is a mechanical
        hazard to that net like any other. ``zone_fill`` states the same rule for
        the pour ("NON-plated holes keep the full carve however their net field
        reads"); a checker that read it the other way would clear exactly the
        mounting-hole-through-a-pour case the carve exists for."""
        hole = _hole(0.0, 0.0, 3.0, entity="MH1", origin="board_hole",
                     net="GND", plated=False)
        trace = _trace(-3.0, 1.6, 3.0, 1.6, width=0.2, entity="t1", net="GND")
        assert _hole_copper_exempt(hole, trace) is False
        assert len(_run([hole], [trace])) == 1

    def test_a_shared_parent_does_not_exempt(self):
        """Pad 1's DRILL versus pad 2's COPPER on the same component: two
        distinct potentials a hair apart, which is precisely what this check is
        for. An exemption keyed on ``parent_id`` — the component — would clear
        every intra-footprint violation on the board."""
        hole = _hole(0.0, 0.0, 0.9, entity="U1-1", parent="U1", origin="pad",
                     net="NET_A", ref="U1", pad="1")
        other = _disc_copper(1.0, 0.0, 1.26, entity="U1-2", parent="U1",
                             kind="pth_pad", net="NET_B", ref="U1", pad="2")
        assert hole.parent_id == other.parent_id
        assert _hole_copper_exempt(hole, other) is False
        assert len(_run([hole], [other])) == 1

    def test_two_netless_features_are_not_a_shared_net(self):
        """The GC2 reading, kept consistent: unassigned is not a net. Two
        DIFFERENT entities that both happen to carry ``net_id=None`` are foreign
        to each other."""
        hole = _hole(0.0, 0.0, 0.4, entity="h1", net=None)
        copper = _rect_pad(0.4, 0.0, 0.4, 1.0, entity="c1", net=None)
        assert _hole_copper_exempt(hole, copper) is False
        assert len(_run([hole], [copper])) == 1

    def test_a_foreign_net_trace_is_checked(self):
        hole = _hole(0.0, 0.0, 0.4, entity="V1", net="GND", plated=True)
        foreign = _trace(-2.0, 0.4, 2.0, 0.4, width=0.2, entity="t1",
                         net="VCC")
        assert _hole_copper_exempt(hole, foreign) is False
        assert len(_run([hole], [foreign])) == 1


# ---------------------------------------------------------------------------
# The finding shape.
# ---------------------------------------------------------------------------


class TestFindingShape:
    def _one(self):
        hole = _hole(0.0, 0.0, 0.4, entity="V1", parent=None, origin="via",
                     net="GND", plated=True, net_name="GND")
        foreign = _trace(-2.0, 0.4, 2.0, 0.4, width=0.2, entity="t1",
                         parent="TR9", net="VCC")
        return _run([hole], [foreign])[0]

    def test_the_hole_is_the_subject(self):
        """GC10 uses the GC5/GC7 idiom (one subject + ``against_entity_id``),
        not GC6's ``a|b`` pair idiom, because the rule is ASYMMETRIC — it is
        about where the DRILL may go. A consumer that groups findings by
        entity_id therefore groups them by hole."""
        found = self._one()
        assert found["type"] == "gc10_hole_to_copper"
        assert found["entity_id"] == "V1"
        assert found["kind"] == "via"
        assert found["against_entity_id"] == "t1"
        assert found["against_kind"] == "trace_seg"

    def test_it_names_both_participants_in_human_terms(self):
        """A finding a person cannot act on is a finding that gets ignored: the
        hole's own attribution rides the standard ref/pad/net_name fields and the
        copper's rides the ``against_*`` mirror."""
        found = self._one()
        assert found["net_name"] == "GND"
        assert found["against_net_name"] == "VCC"
        assert found["against_net_id"] == "VCC"
        assert found["plated"] is True

    def test_the_witness_pair_spans_the_measured_gap(self):
        """The two witness points must be exactly ``measured_mm`` apart, and the
        midpoint must sit between them — that is what makes the finding
        renderable and, more importantly, auditable by hand."""
        import math

        found = self._one()
        (x1, y1), (x2, y2) = found["closest"], found["witness"]
        span = math.hypot(x2 - x1, y2 - y1)
        assert span == pytest.approx(found["measured_mm"], abs=1e-6)
        assert found["midpoint"] == [pytest.approx((x1 + x2) / 2.0, abs=1e-6),
                                     pytest.approx((y1 + y2) / 2.0, abs=1e-6)]

    def test_findings_are_deterministic_under_input_order(self):
        """Both sides are sorted by entity_id before pairing, so a projection
        built in any order yields the same rows in the same sequence. Findings
        that shuffle make every downstream diff unreadable."""
        holes = [_hole(0.0, 0.0, 0.4, entity="hb", net=None),
                 _hole(3.0, 0.0, 0.4, entity="ha", net=None)]
        copper = [_rect_pad(3.4, 0.0, 0.4, 1.0, entity="cb", net=None),
                  _rect_pad(0.4, 0.0, 0.4, 1.0, entity="ca", net=None)]
        forward = _run(holes, copper)
        reverse = _run(list(reversed(holes)), list(reversed(copper)))
        assert len(forward) == 2
        assert forward == reverse
        assert [f["entity_id"] for f in forward] == ["ha", "hb"]


# ---------------------------------------------------------------------------
# End to end, on the real seed board.
# ---------------------------------------------------------------------------


def _coupon():
    result = compile_board(yaml.safe_load(COUPON.read_text(encoding="utf-8")))
    assert isinstance(result, ResolutionSuccess), \
        [(d.code, d.message) for d in result.diagnostics]
    return result.board


class TestOnTheCoupon:
    def test_the_coupon_stays_clean_under_the_new_check(self):
        """MEASURED, and it contradicts what S7's brief predicted. The station
        was written expecting GC10 to break the coupon on landing (the floor is
        already declared at 0.28), with an in-station repair budgeted. It does
        not: the coupon's tightest non-exempt hole-to-copper gap is 0.3614 mm,
        clearing 0.28 by 0.0814 mm. No fixture was edited and no golden was
        re-blessed for this station."""
        drc = run_geometric_drc(_coupon())
        assert drc["ok"] is True
        assert drc["counts"]["gc10_hole_to_copper"] == 0
        assert drc["verdict"] == "clean"

    def test_that_clean_is_EARNED_rather_than_vacuous(self):
        """The row above is worthless on its own: a GC10 that exempted every pair
        — or never ran — would satisfy it exactly. This one measures the
        exemption's blast radius on a real board and pins the tightest surviving
        gap, so a change that quietly widens the exemption moves a number here
        instead of passing silently.

        Measured on the coupon: 690 candidate pairs, 10 eaten by the same-entity
        exemption (one per hole — every hole on this board carries its own land),
        106 by the same-net-plated exemption, leaving 574 genuinely measured."""
        rb = _coupon()
        proj = project_board(rb)
        pairs = [(h, c) for h in proj.holes for c in proj.copper]
        measured = [(h, c) for h, c in pairs if not _hole_copper_exempt(h, c)]
        assert len(pairs) == 690
        assert len(measured) == 574

        from pcb_worker.drc_geom_primitives import convex_edge_distance
        tightest = min(
            min(convex_edge_distance(cap, c.shape) for cap in h.capsules)
            for h, c in measured)
        assert tightest == pytest.approx(0.3614, abs=5e-4)
        assert tightest > rb.design_rules.minimums.min_hole_to_copper_mm

    def test_the_profile_actually_declares_the_floor(self):
        """If the JLCPCB profile ever drops the field, GC10 silently stops
        checking the seed board and every row above still passes. Pin it."""
        rb = _coupon()
        assert rb.design_rules.minimums.min_hole_to_copper_mm == pytest.approx(0.28)

    def test_the_seed_corpus_contains_no_unplated_hole(self):
        """A STATED LIMITATION, pinned so it cannot rot into an assumption.

        Every one of the coupon's 10 holes is a plated pad or via carrying its
        own land — the corpus has no ``mounting_holes`` at all. That matters
        because the plated-with-a-land case is the one where GC10 adds NOTHING
        on this profile, and the arithmetic is worth stating rather than
        rediscovering. For a plated hole, GC2 measures its LAND against foreign
        copper at 0.10 while GC10 measures its BORE at 0.28; the bore is smaller
        than the land by the annular ring, so GC2 is the stricter of the two
        whenever ``ring >= 0.28 - 0.10 = 0.18`` — and GC4 REFUSES any ring below
        0.18 (``min_annular_ring_mm``). Every plated hole this profile admits is
        therefore already covered by GC2, and GC10's entire marginal value sits
        on UNPLATED bores, which project no copper for GC2 to pair. Which is
        exactly what the seed corpus does not contain, and why the end-to-end
        witness below authors one."""
        rb = _coupon()
        assert rb.holes == ()
        proj = project_board(rb)
        assert len(proj.holes) == 10
        assert all(h.plated for h in proj.holes)
        with_own_land = {c.entity_id for c in proj.copper}
        assert all(h.entity_id in with_own_land for h in proj.holes)


class TestTheFloorIsLiveOnARealBoard:
    """The end-to-end witness: compile -> project -> run, on the seed coupon.

    Perturbed IN MEMORY (the ``TestWitnessesSitOnTheirFloors`` idiom) — no
    fixture is edited and no golden is re-blessed, which matters because this
    epoch commits nothing and re-blessing a golden to make a new check pass is
    the exact move that would hide a real defect.

    THE PERTURBATION IS AN UNPLATED MOUNTING HOLE, chosen deliberately. An
    unplated bore projects a hole primitive and NO copper primitive, so GC2 has
    nothing to compare and stays silent no matter how close a track runs. That
    is the fail-open GC10 exists to close, and it is invisible to every other
    check in the set.
    """

    @staticmethod
    def _with_hole(y_mm: float):
        import copy

        board = copy.deepcopy(yaml.safe_load(COUPON.read_text(encoding="utf-8")))
        # x=13.0 sits under the NET_A and NET_B trace pair that both run along
        # y=11.45 at width 0.25. Bore radius 0.5 + trace half-width 0.125 = 0.625,
        # so the edge-to-edge gap is (y_mm - 11.45) - 0.625.
        board["mounting_holes"] = [
            {"x_mm": 13.0, "y_mm": y_mm, "diameter_mm": 1.0, "plated": False}]
        result = compile_board(board)
        assert isinstance(result, ResolutionSuccess), \
            [(d.code, d.message) for d in result.diagnostics]
        return run_geometric_drc(result.board)

    def test_a_clear_unplated_hole_passes(self):
        """y=12.5 -> gap 0.425, clearing the 0.28 floor. The board must stay
        determinately clean, so the violating row below is proving DISTANCE
        sensitivity rather than "adding a hole fires something"."""
        drc = self._with_hole(12.5)
        assert drc["ok"] is True
        assert drc["verdict"] == "clean"
        assert drc["counts"]["gc10_hole_to_copper"] == 0

    def test_the_same_hole_0_3mm_closer_violates(self):
        """y=12.2 -> gap 0.125, breaking the 0.28 floor against BOTH tracks."""
        drc = self._with_hole(12.2)
        assert drc["ok"] is True
        assert drc["verdict"] == "violations"
        gc10 = [f for f in drc["findings"] if f["type"] == "gc10_hole_to_copper"]
        assert len(gc10) == 2
        assert drc["counts"]["gc10_hole_to_copper"] == 2
        for finding in gc10:
            assert finding["measured_mm"] == pytest.approx(0.125, abs=1e-4)
            assert finding["against_kind"] == "trace_seg"
            assert finding["plated"] is False
        assert {f["against_net_name"] for f in gc10} == {"NET_A", "NET_B"}

    def test_no_other_check_sees_this_violation(self):
        """THE POINT OF THE WHOLE STATION, asserted rather than argued.

        A track 0.125 mm from an unplated bore is a board JLCPCB would reject,
        and before GC10 every check in the set passed it: GC2 compares copper to
        copper and an unplated hole HAS no copper, so there is no pair to form.
        If this row ever fails because GC2 started firing here, the two checks
        have begun overlapping and the exemption logic needs re-reading — it does
        not mean GC10 became redundant."""
        drc = self._with_hole(12.2)
        types = {f["type"] for f in drc["findings"]}
        assert types == {"gc10_hole_to_copper"}
        assert drc["counts"]["gc2_copper_clearance"] == 0
