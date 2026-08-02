"""ORACLE PARITY — our zone filler vs KiCad's, on the same synthetic board.

THIS IS THE ONE TEST THAT CAN TELL WHETHER THE FILL IS RIGHT.

Everything else in the suite grades the filler against rules the filler itself
applied. A clearance check over a fill that was produced by carving that same
clearance asks the filler whether it obeyed itself, and the answer is always
yes. Docket hint ``019faf103eee`` names the mirror-image trap: a KiCad export of
OUR board is not an oracle for anything we authored into it. Deferred-test Z2
(``019fb06e3c55``) calls pour fill "the exact class where a careful read has
lost to a mutation proof five times in this campaign".

The escape is that KiCad DOES THE FILLING here. We hand it an outline and rules
— ``kicad._zone_sexpr`` deliberately writes no ``(filled_polygon ...)``, and the
oracle refuses a board that contains one — and read back the polygon a different
codebase computed from geometry it derived itself.

IT DISCRIMINATES, which is the property that matters. During implementation a
layer-namespace mismatch made the filler skip EVERY obstacle: the pour filled
its whole outline, emitting copper straight over a foreign net. Nothing in the
worker raised, no other test failed, and the emitted Gerber looked entirely
plausible. This comparison is what caught it.

=== WHY EXACT EQUALITY IS NOT THE BAR ===

The two fillers disagree by construction, in ways that are not defects on either
side. The disagreements were MEASURED and decomposed rather than absorbed into a
round number, because the one thing a tolerance must not be is fitted to our own
output — that is the circularity coming back in through the door marked
"tolerance". On this fixture, the entire 0.5487 mm^2 excess decomposes as:

  0.4626 mm^2  HOLE-TO-COPPER RULE. KiCad carves 0.25 mm around the unplated
               mounting hole; we carve the zone's 0.2 mm copper clearance.
               ``ManufacturingConstraints`` has ``min_hole_to_hole_mm`` and
               ``min_annular_ring_mm`` but NO hole-to-copper field, so 0.2 mm is
               the only rule our schema can state. Largest term, and a genuine
               rule difference rather than a geometry error: it appears as a
               50.5 um annulus around one hole.
  0.0329 mm^2  ARC FLATTENING along the crossing trace's long void boundary.
               Both sides approximate a clearance arc with segments; KiCad's
               approximation is circumscribed and ours inscribed at a 5 um
               tolerance, so its voids are a hair larger everywhere.
  0.0215 mm^2  the same, around the via.
  0.0163 mm^2  the same, around the two foreign pads (0.0081 each).
  0.0155 mm^2  MIN-THICKNESS CORNER ROUNDING at the pour's four corners.
               KiCad deflates and re-inflates by ``min_thickness``/2 = 0.125 mm
               to shed slivers, which rounds every convex corner; we have no
               min-thickness because the schema cannot express one.

Sum: 0.5488 mm^2 against a measured 0.5487. Nothing is unaccounted for. The
band below is the WORST LOCAL offset those causes can produce (50.5 um from the
hole rule, 51.8 um from corner rounding at a 90-degree corner), rounded up —
not a number chosen because it made the test pass.
"""

from __future__ import annotations

import json
import math
from pathlib import Path

import pytest

from pcb_worker import kicad
from pcb_worker.compile_board import compile_board
from pcb_worker.manufacturer_profile import DEFAULT_PROFILE_ROOT
from pcb_worker.resolved_board import ResolutionSuccess, ZoneKind
from pcb_worker.zone_fill import NM_PER_MM, fill_area_mm2
from tests.gerber_fab import load_board
from tests.oracle.zone_fill_oracle import fill_zones, pcbnew_available

FIXTURE = Path(__file__).resolve().parents[1] / "testdata" / "zone_fill.yaml"

# Area agreement, relative. Measured 0.1374% on this fixture; 0.25% leaves room
# for a KiCad point release to move its arc approximation without leaving room
# for a missing void (the smallest void here is 2.55 mm^2 = 0.64% of the fill,
# so dropping even the smallest one still fails this).
AREA_TOLERANCE = 0.0025

# Containment band, in mm. See the module docstring's decomposition: the worst
# local offset the two known rule differences can produce is 51.8 um.
CONTAINMENT_BAND_MM = 0.080

# The pour has exactly six voids: two foreign-net pads, one crossing trace, one
# FOREIGN-net via, one netless mounting hole, one keepout.
#
# The SAME-NET stitching via contributes NO void — that is what this count is
# really pinning. It is the difference between a pour that stitches to the other
# layer and one that hangs off a sliver: a filler carving every drill at
# (radius + clearance) puts a 0.4 mm void exactly on the 0.4 mm land at clearance
# 0.2, and a 0.5 mm moat around it at 0.3. Seven voids here means that bug is
# back.
EXPECTED_VOIDS = 6


pytestmark = pytest.mark.skipif(
    not pcbnew_available(),
    reason="KiCad's pcbnew python bindings are not importable from the system "
           "interpreter (no KiCad on this machine)")


def _pyclipper():
    return pytest.importorskip("pyclipper")


@pytest.fixture(scope="module")
def board():
    result = compile_board(load_board(FIXTURE))
    assert isinstance(result, ResolutionSuccess), [d.code for d in result.diagnostics]
    return result.board


@pytest.fixture(scope="module")
def pour(board):
    pours = [z for z in board.zones if z.kind is ZoneKind.COPPER_POUR]
    assert len(pours) == 1
    return pours[0]


@pytest.fixture(scope="module")
def ours(pour):
    """Our fill as Clipper-ready integer-nm rings.

    SIMPLIFIED FIRST, and this is not cosmetic. A fractured keyhole ring is
    self-touching, and Clipper does not accept one as a SUBJECT: the boolean
    comes back as overlapping pieces whose areas do not reconcile with the input
    (measured — an early version of this test reported 49 mm^2 of copper outside
    the oracle while simultaneously reporting the oracle was entirely inside it,
    which is impossible). ``SimplifyPolygons`` converts the keyhole back to the
    equivalent outer + hole ring set. The EMITTED artifact stays fractured; this
    is only how the comparison reads it.
    """
    pc = _pyclipper()
    raw = [[(int(round(x * NM_PER_MM)), int(round(y * NM_PER_MM)))
            for (x, y) in poly.points] for poly in pour.fill]
    return pc.SimplifyPolygons(raw, pc.PFT_NONZERO)


@pytest.fixture(scope="module")
def oracle(board):
    pcb_text = next(v for k, v in kicad.generate_ir(board, "zonefill").items()
                    if k.endswith(".kicad_pcb"))
    result = fill_zones(pcb_text)
    assert result.filled, "pcbnew's ZONE_FILLER reported failure"
    pours = [z for z in result.zones if not z.is_rule_area]
    assert len(pours) == 1, f"expected one filled pour, got {len(pours)}"
    return pours[0]


# --------------------------------------------------------------------------
# The oracle is a real, independent judge — assert that before trusting it.
# --------------------------------------------------------------------------


def test_oracle_returned_fractured_integer_nm_geometry(oracle):
    """The oracle's own shape, pinned.

    Two properties this rests on, and neither is assumed: KiCad returns the
    filled pour as ONE self-touching keyhole contour rather than an outline plus
    a hole (which is why our emitter fractures too — the Gerber region primitive
    has no hole support either), and its coordinates are integer nanometres
    (which is why the comparison needs no float tolerance). If a KiCad upgrade
    changes either, this fails loudly instead of silently shifting the numbers
    below.
    """
    assert oracle.contours, "oracle produced no filled contour at all"
    assert all(h == 0 for h in oracle.holes), (
        f"oracle returned unfractured holes {oracle.holes} — it used to fracture "
        "them into keyhole contours; the comparison assumes that representation")
    assert all(isinstance(x, int) and isinstance(y, int)
               for contour in oracle.contours for (x, y) in contour)


def test_oracle_honoured_the_keepout(board):
    """The keepout reached KiCad as a RULE AREA, not as a second pour.

    Without this the keepout half of the fixture proves nothing: if KiCad read
    the keepout as an ordinary zone it would fill it with copper, and the pour's
    area would agree with ours for the wrong reason.
    """
    pcb_text = next(v for k, v in kicad.generate_ir(board, "zonefill").items()
                    if k.endswith(".kicad_pcb"))
    result = fill_zones(pcb_text)
    rule_areas = [z for z in result.zones if z.is_rule_area]
    assert len(rule_areas) == 1, "the keepout did not reach KiCad as a rule area"
    assert rule_areas[0].area_nm2 == 0, "a keepout must never carry copper"


# --------------------------------------------------------------------------
# Parity.
# --------------------------------------------------------------------------


def test_fill_area_agrees_with_the_oracle(pour, oracle):
    """Total copper area agrees within the stated band."""
    ours_mm2 = fill_area_mm2(pour)
    theirs = oracle.area_mm2
    relative = abs(ours_mm2 - theirs) / theirs
    assert relative <= AREA_TOLERANCE, (
        f"zone fill area disagrees with pcbnew by {relative:.4%} "
        f"(ours {ours_mm2:.6f} mm^2, oracle {theirs:.6f} mm^2). The known "
        f"differences total 0.549 mm^2 / 0.137%; anything larger is a new one, "
        f"and the module docstring lists what each known term is so a new term "
        f"can be identified rather than absorbed.")


def test_every_void_the_oracle_carved_we_also_carved(ours, oracle):
    """ORACLE COPPER SUBSET OF OURS — asserted EXACTLY, no tolerance.

    Copper KiCad poured and we did not would be a hole in our fill that KiCad
    says should be metal. On this fixture the containment is exact in this
    direction, so it is asserted exactly: zero square nanometres.
    """
    pc = _pyclipper()
    clipper = pc.Pyclipper()
    clipper.AddPaths(pc.SimplifyPolygons([list(c) for c in oracle.contours],
                                         pc.PFT_NONZERO), pc.PT_SUBJECT, True)
    clipper.AddPaths(ours, pc.PT_CLIP, True)
    missing = clipper.Execute(pc.CT_DIFFERENCE, pc.PFT_NONZERO, pc.PFT_NONZERO)
    area = sum(pc.Area(p) for p in missing) / (NM_PER_MM * NM_PER_MM)
    assert area == 0.0, (
        f"{area:.6f} mm^2 of copper the oracle poured is MISSING from our fill")


def test_our_fill_stays_inside_the_oracle_band(ours, oracle):
    """OUR COPPER SUBSET OF (oracle fill dilated by the band).

    This is the safety-critical direction: copper we pour where KiCad would not
    is copper reaching closer to a foreign feature than an independent filler
    thinks is legal. The band is the worst local offset the two documented rule
    differences produce, NOT a number tuned until this passed.
    """
    pc = _pyclipper()
    offset = pc.PyclipperOffset(2.0, 5000)
    offset.AddPaths([list(c) for c in oracle.contours], pc.JT_ROUND,
                    pc.ET_CLOSEDPOLYGON)
    dilated = offset.Execute(int(round(CONTAINMENT_BAND_MM * NM_PER_MM)))

    clipper = pc.Pyclipper()
    clipper.AddPaths(ours, pc.PT_SUBJECT, True)
    clipper.AddPaths(dilated, pc.PT_CLIP, True)
    outside = clipper.Execute(pc.CT_DIFFERENCE, pc.PFT_NONZERO, pc.PFT_NONZERO)
    area = sum(pc.Area(p) for p in outside) / (NM_PER_MM * NM_PER_MM)
    assert area == 0.0, (
        f"{area:.6f} mm^2 of our copper lies more than {CONTAINMENT_BAND_MM} mm "
        f"outside anything the oracle poured — that is a local shape "
        f"disagreement, not a boundary approximation")


def test_the_expected_voids_are_actually_there(ours):
    """STRUCTURE, not just area — the assertion an area check cannot make.

    A filler that carved nothing and a filler that carved every void correctly
    can be told apart by area. A filler that carved five of six voids and
    over-carved the sixth might not be. Counting the holes in the simplified
    ring set is the cheap structural check: one outer boundary plus one void per
    obstacle.
    """
    pc = _pyclipper()
    outers = [p for p in ours if pc.Orientation(p)]
    holes = [p for p in ours if not pc.Orientation(p)]
    assert len(outers) == 1, (
        f"the pour should be ONE connected region; got {len(outers)}. More than "
        f"one means a void severed it into islands — which v1 does not drop and "
        f"KiCad does, so the parity numbers above would stop meaning anything.")
    assert len(holes) == EXPECTED_VOIDS, (
        f"expected {EXPECTED_VOIDS} voids (2 foreign pads, 1 trace, 1 FOREIGN via, "
        f"1 mounting hole, 1 keepout — and NO void at the same-net stitching "
        f"via); got {len(holes)}")


# --------------------------------------------------------------------------
# HOLE-TO-COPPER — the rule difference, closed and re-measured.
#
# The module docstring decomposes this fixture's 0.5487 mm^2 excess and puts
# the LARGEST single term on the hole-to-copper rule: KiCad carves 0.25 mm
# around the unplated mounting hole and we carved the zone's 0.2 mm copper
# clearance, because ManufacturingConstraints had no hole-to-copper field.
#
# It has one now (optional -- neither shipped profile publishes a number, and
# a fab that states none has not thereby stated zero). This is the oracle
# witnessing that the field is REAL: state KiCad's own 0.25 and the term it
# was blamed for has to disappear. Nothing but a genuinely wired rule can do
# that, and no assertion inside our own filler could have shown it.
# --------------------------------------------------------------------------

# MEASURED against KiCad 9.0.9, both runs, on this fixture:
#     no hole rule           ours 399.978964   oracle 399.430251   +0.548713
#     min_hole_to_copper 0.25 ours 399.562054  oracle 399.430251   +0.131803
# so stating the rule closes 0.416910 mm^2 of a 0.548713 mm^2 disagreement.
PARITY_EXCESS_WITHOUT_RULE_MM2 = 0.548713
PARITY_EXCESS_WITH_RULE_MM2 = 0.131803

# HAND-DERIVED, and the reason this test can assert a number rather than "less".
# The only hole whose void MOVES is the unplated mounting hole (diameter 2.2, so
# radius 1.1): its void grows from radius 1.1+0.20 = 1.30 to 1.1+0.25 = 1.35, and
# the pour loses exactly that annulus:
#
#     pi(1.35^2 - 1.30^2) = pi(0.1325) = 0.416261 mm^2
#
# The SIG via's drill does NOT move the fill, which is worth stating because it
# looks like it should: its 0.8 mm land is FOREIGN copper carved at 0.4+0.2 =
# 0.6 mm, and the drill's void at 0.45 mm is entirely inside that, so raising the
# hole rule cannot reach past the copper rule already in force. The same-net
# stitching via is not carved at all.
EXPECTED_ANNULUS_MM2 = math.pi * (1.35 ** 2 - 1.30 ** 2)


@pytest.fixture(scope="module")
def hole_rule_board(tmp_path_factory):
    """The same fixture board, compiled against a profile stating 0.25 mm.

    A one-off profile rather than an edit to a shipped one: the shipped profiles
    state no hole-to-copper rule, and that is a fact about those board houses,
    not a gap to be filled to make a test pass.
    """
    root = tmp_path_factory.mktemp("profiles")
    floor = dict(json.loads(
        (DEFAULT_PROFILE_ROOT / "v1-fab-conservative.json").read_text(
            encoding="utf-8"))["floor"])
    floor["min_hole_to_copper_mm"] = 0.25
    (root / "kicad-parity.json").write_text(
        json.dumps({"id": "kicad-parity", "version": "1", "floor": floor}),
        encoding="utf-8")

    raw = load_board(FIXTURE)
    raw["design_rules"]["rule_profile"] = "kicad-parity"
    result = compile_board(raw, profile_root=root)
    assert isinstance(result, ResolutionSuccess), [d.code for d in result.diagnostics]
    return result.board


def test_stating_the_hole_rule_closes_the_largest_parity_term(board, hole_rule_board):
    """Our copper shrinks by exactly the derived annulus, and by nothing else.

    Asserted as an EQUALITY against hand-computed geometry rather than as "the
    area went down": a rule wired to the wrong holes, or applied as a
    replacement instead of a floor, would also reduce the area.
    """
    pours = [z for z in board.zones if z.kind is ZoneKind.COPPER_POUR]
    strict = [z for z in hole_rule_board.zones if z.kind is ZoneKind.COPPER_POUR]
    lost = fill_area_mm2(pours[0]) - fill_area_mm2(strict[0])
    # Budget: both voids are inscribed approximations at ARC_TOLERANCE_NM = 5 um,
    # each under-stating its circle by at most (2/3)*perimeter*t -- 0.02723 mm^2
    # at r = 1.30 and 0.02827 at r = 1.35 -- so their difference lies within
    # 0.029 mm^2. The annulus is 0.416 mm^2, fourteen times that.
    assert lost == pytest.approx(EXPECTED_ANNULUS_MM2, abs=0.029)


def test_the_oracle_agrees_far_more_closely_once_the_rule_is_stated(hole_rule_board):
    """THE INDEPENDENT HALF. KiCad refilled the same board and moved toward us.

    The test above compares our filler against arithmetic; this one compares it
    against a different codebase. The excess must fall from 0.5487 to 0.1318
    mm^2 -- a 76% reduction -- because the rule we now state is the rule KiCad
    was already applying.

    A generous band (25% of each figure) on purpose: the point is the SIZE of
    the move, and pinning KiCad's exact arithmetic would make a point release
    that shifts an arc approximation look like a regression in our filler.
    """
    pour = [z for z in hole_rule_board.zones if z.kind is ZoneKind.COPPER_POUR][0]
    pcb_text = next(v for k, v in kicad.generate_ir(hole_rule_board, "zonefill").items()
                    if k.endswith(".kicad_pcb"))
    result = fill_zones(pcb_text)
    assert result.filled, "pcbnew's ZONE_FILLER reported failure"
    oracle_pour = [z for z in result.zones if not z.is_rule_area][0]

    excess = fill_area_mm2(pour) - oracle_pour.area_mm2
    assert excess > 0, (
        "our fill is no longer a superset of the oracle's — the hole rule "
        "over-carved past what KiCad removes")
    assert excess == pytest.approx(PARITY_EXCESS_WITH_RULE_MM2, rel=0.25), (
        f"excess {excess:.6f} mm^2; expected about "
        f"{PARITY_EXCESS_WITH_RULE_MM2} once the hole rule is stated (it was "
        f"{PARITY_EXCESS_WITHOUT_RULE_MM2} without it)")
    assert excess < PARITY_EXCESS_WITHOUT_RULE_MM2 / 2, (
        "stating KiCad's own hole-to-copper rule did not materially close the "
        "gap the module docstring attributes to it")
