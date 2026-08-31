"""The ASSEMBLY ANCHOR and the transform that places it.

A CPL row carries ``PhysicalPlacement.anchor`` — the resolved body-box centre —
and NOT the component's authored ``x_mm``/``y_mm``, which place the FOOTPRINT
ORIGIN. A house is told where to CENTRE a part, so for every footprint whose
origin is not its body centre — 18 of the 39 seed footprints, 14 of them because
their origin is pin 1 — emitting the origin is wrong by up to half a package,
and by 30.85 mm on the DevKit socket set. These tests are the oracle in BOTH
directions:

  * a footprint whose origin already IS its body centre must emit EXACTLY what
    it emitted before (the Q rows below, plus every existing seal in
    test_assembly_outputs.py, whose fixture is built entirely from such
    footprints and whose byte-exact cutover oracle therefore still holds);
  * a footprint whose origin is pin 1 must move by exactly its measured body
    offset, through rotation, through the bottom-side mirror, and through a
    synthetic expansion (the J and U rows).

EVERY EXPECTATION HERE IS HAND-DERIVED from two things and nothing else: the two
fixture footprints' measured fab-layer body boxes (pinned by the first test
below, so a library edit breaks the premise rather than silently rewriting the
answers) and the placement transform ``geometry.py`` documents —
``board = position + R_cw(rot) · mirror(local)``, with
``R_cw(d)·(x, y) = (x·cos d + y·sin d, −x·sin d + y·cos d)`` and ``mirror``
negating local Y on the bottom side. Nothing below asks ``assembly_anchor`` what
it thinks the answer is.

THE TWO JLC CONVENTION PROOFS live here rather than in the docstring that
asserts them, and they are measured on real compiled pad geometry:
``test_emitted_rotation_turns_the_part_counter_clockwise`` and
``test_bottom_side_coordinates_are_not_mirrored``. Both use SOT-23 because it is
asymmetric in both axes — three lands, two on one side and one on the other — so
a sign error cannot hide behind a symmetry, and a chip resistor would have let
every wrong answer pass.
"""

from __future__ import annotations

import math
from dataclasses import replace
from pathlib import Path

import pytest
import yaml

from pcb_worker import assembly_outputs as ao
from pcb_worker import refdes_anchor
from pcb_worker.compile_board import compile_board
from pcb_worker.footprint_def import FootprintDefinition
from pcb_worker.footprints import parse_kicad_mod
from pcb_worker.resolved_board import (
    ANCHOR_BASIS_AUTHORED, ANCHOR_BASIS_FAB, ANCHOR_BASIS_LANDS,
    ANCHOR_BASIS_ORIGIN, DiagnosticSeverity, ResolutionSuccess,
)
# The CPL byte seal for assembly_resolved.yaml has exactly one owner.
from tests.test_assembly_outputs import RESOLVED_FIXTURE_CPL

BOARDS = Path(__file__).resolve().parent / "testdata" / "assembly_boards"
ANCHOR_FIXTURE = BOARDS / "assembly_anchor.yaml"
OVERRIDE_FIXTURE = BOARDS / "assembly_anchor_override.yaml"
RESOLVED_FIXTURE = BOARDS / "assembly_resolved.yaml"
LIBRARY = Path(__file__).resolve().parents[2] / "library" / "footprints"

#: The measured body offset of the fixture's pin-1-origin footprint. Every J and
#: U expectation below is this number put through a transform.
SOCKET_ANCHOR_Y = 7.62
#: The DevKit row pitch the U rows expand across.
ROW_PITCH = 22.86

# --- the override fixture's three measured numbers, each derivable from a part
#     a purchaser holds rather than from the .kicad_mod ------------------------
#: Half the socket set's row spacing (22.86 mm, stated in the footprint's descr).
ROW_HALF_SPACING = 11.43
#: Half a 1x22 strip's pin span: 21 x 2.54 / 2. Where the STRIP's centre is.
STRIP_ANCHOR_Y = 26.67
#: Where the PARENT's fab box centres — the whole two-row body, i.e. the DevKit
#: module. The number every child inherits when no anchor is authored, and the
#: one that is right for neither strip.
SOCKET_SET_FAB_ANCHOR_Y = 30.8485


def _compiled(path: Path = ANCHOR_FIXTURE):
    """The compiled fixture. Fails LOUDLY rather than skipping: a fixture that
    stopped compiling would silently stop testing anything here."""
    result = compile_board(yaml.safe_load(path.read_text(encoding="utf-8")))
    if not isinstance(result, ResolutionSuccess):
        raise AssertionError(
            "fixture did not compile: "
            + ", ".join(d.code for d in result.diagnostics
                        if d.severity is DiagnosticSeverity.ERROR))
    return result.board


def _compiled_without_authored_anchors(path: Path = OVERRIDE_FIXTURE):
    """The SAME fixture with every ``anchor_mm`` key removed and nothing else
    touched — the control arm of the override oracle. Built by mutation rather
    than by a second fixture file so the two arms cannot drift apart in some
    other field and quietly stop being the same board."""
    document = yaml.safe_load(path.read_text(encoding="utf-8"))
    removed = 0
    for component in document["components"]:
        for placement in component["assembly"]["placements"]:
            removed += placement.pop("anchor_mm", None) is not None
    assert removed == 6, "the fixture stopped authoring the anchors under test"
    result = compile_board(document)
    if not isinstance(result, ResolutionSuccess):
        raise AssertionError("stripped fixture did not compile")
    return result.board


def _definition(relative: str) -> FootprintDefinition:
    return FootprintDefinition.from_kicad_parsed(
        parse_kicad_mod(LIBRARY / relative))


def _placements(board) -> dict:
    return {item.ref: item
            for component in board.components
            for item in component.physical_placements}


def _cpl_rows(board) -> dict:
    return {row.ref: row for row in ao.build_cpl(board, "jlc").rows}


def _xy(place) -> tuple[float, float]:
    return (place.anchor[0], place.anchor[1])


# ---------------------------------------------------------------------------
# The premise: what the two fixture footprints actually measure.
# ---------------------------------------------------------------------------


def test_the_fixture_footprints_measure_what_the_fixture_claims():
    """THE PREMISE OF EVERY OTHER TEST HERE, pinned so a library edit breaks
    loudly instead of quietly rewriting the hand-derived answers.

    SOT-23's fab body box is (-0.7, -1.5)..(0.7, 1.5) — centre on its own
    origin, which is what makes it the control. PinSocket_1x07's is
    (-1.32, -1.32)..(1.32, 16.56) — centre (0, 7.62), 7.62 mm from the pin-1
    datum its coordinates used to be emitted at.
    """
    sot = refdes_anchor.fab_extent_from_definition(
        _definition("Package_TO_SOT_SMD.pretty/SOT-23.kicad_mod"))
    assert (sot.min_x, sot.min_y, sot.max_x, sot.max_y) == pytest.approx(
        (-0.7, -1.5, 0.7, 1.5))
    assert (sot.center_x, sot.center_y) == pytest.approx((0.0, 0.0))

    socket = refdes_anchor.fab_extent_from_definition(_definition(
        "Connector_PinSocket_2.54mm.pretty/"
        "PinSocket_1x07_P2.54mm_Vertical.kicad_mod"))
    assert (socket.min_x, socket.min_y, socket.max_x, socket.max_y) == pytest.approx(
        (-1.32, -1.32, 1.32, 16.56))
    assert (socket.center_x, socket.center_y) == pytest.approx(
        (0.0, SOCKET_ANCHOR_Y))


def test_silk_would_have_been_the_wrong_basis():
    """WHY THE LADDER SKIPS SILK, stated as a measurement rather than an
    opinion. A footprint's silk is drawn deliberately asymmetric — D_SMA's is a
    cathode bar down one end alone — so a box measured over it is not the part.
    Had the anchor been measured from silk, every SMA diode on every board would
    have been handed to a house 3.05 mm from where it actually sits."""
    diode = _definition("Diode_SMD.pretty/D_SMA.kicad_mod")
    fab = refdes_anchor.fab_extent_from_definition(diode)
    silk = refdes_anchor._extent_of(refdes_anchor._definition_graphic_points(
        diode.graphics, frozenset({"F.SilkS", "B.SilkS"})))
    assert (fab.center_x, fab.center_y) == pytest.approx((0.0, 0.0))
    assert silk.center_x == pytest.approx(-3.05)


def test_courtyard_would_have_been_the_wrong_basis():
    """AND WHY IT SKIPS THE COURTYARD. A courtyard is a keep-out envelope drawn
    deliberately larger than the part, and — measured here — larger by DIFFERENT
    margins on different edges, so its centre is not the part's centre either:
    PinSocket_1x07's sits 0.025 mm off in x and 0.02 mm off in y."""
    socket = _definition("Connector_PinSocket_2.54mm.pretty/"
                         "PinSocket_1x07_P2.54mm_Vertical.kicad_mod")
    fab = refdes_anchor.fab_extent_from_definition(socket)
    courtyard = refdes_anchor.courtyard_extent_from_definition(socket)
    assert (courtyard.center_x, courtyard.center_y) == pytest.approx((-0.025, 7.6))
    assert (fab.center_x - courtyard.center_x) == pytest.approx(0.025)
    assert (fab.center_y - courtyard.center_y) == pytest.approx(0.02)


# ---------------------------------------------------------------------------
# The reverse oracle: a centroid-at-origin footprint must not have moved.
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("ref,position", [
    ("Q1", (10.0, 10.0)),   # top, rotation 0
    ("Q2", (20.0, 10.0)),   # top, rotation 90
    ("Q3", (30.0, 10.0)),   # bottom, rotation 0
    ("Q4", (40.0, 10.0)),   # bottom, rotation 90
])
def test_a_footprint_already_centred_on_its_origin_does_not_move(ref, position):
    """THE ORACLE IN THE OTHER DIRECTION. SOT-23's body centre IS its origin, so
    the transform composes the anchor back onto the placement position — at
    every angle and on both sides — and the emitted coordinate is bit-for-bit
    the authored one. If a part like this ever moves, the anchor derivation has
    acquired an offset from something that is not the body.

    Exact equality, not approx: the local anchor is (0, 0), and the transform
    short-circuits a zero offset to the position itself rather than through any
    trigonometry, so there is no float dust to tolerate.
    """
    place = _placements(_compiled())[ref]
    assert place.origin == position
    assert place.anchor == position
    assert place.anchor_basis == ANCHOR_BASIS_FAB


def test_the_existing_emitter_fixture_is_byte_identical():
    """The same claim on the board every OTHER assembly test measures. Every
    footprint in assembly_resolved.yaml (R_0805, D_SMA, and two excluded pieces
    of furniture) is centred on its own origin, so the anchor composes back onto
    the authored position and that board's CPL is unchanged character for
    character.

    The expected bytes are IMPORTED, not restated: test_assembly_outputs.py owns
    them (RESOLVED_FIXTURE_CPL), so this test cannot drift into agreeing with a
    stale copy."""
    content = next(iter(ao.build_cpl(
        _compiled(RESOLVED_FIXTURE), "jlc", name="afix").values()))
    assert content == RESOLVED_FIXTURE_CPL


# ---------------------------------------------------------------------------
# The blast radius: a pin-1 origin moves by its measured body offset.
# ---------------------------------------------------------------------------


def test_pin_one_origin_moves_by_the_body_offset_through_every_transform():
    """HAND-DERIVED, from the socket's local anchor (0, 7.62) and nothing else.

      J2  position (10, 30), rotation 0, top
          local (0, 7.62) unrotated, unmirrored     -> (10, 37.62)
      J3  position (25, 30), rotation 90, top
          R_cw(90)·(0, 7.62) = (7.62, 0)            -> (32.62, 30)
      J4  position (40, 30), rotation 0, bottom
          mirror -> (0, -7.62), unrotated           -> (40, 22.38)

    J2 is the plain blast-radius case: 7.62 mm, half the socket's pin span. J3 turns that offset into x, so a wrong rotation SIGN moves it to
    (17.38, 30) and cannot pass. J4 mirrors it, so a bottom side that forgot to
    mirror leaves it at 37.62.
    """
    places = _placements(_compiled())
    assert _xy(places["J2"]) == pytest.approx((10.0, 30.0 + SOCKET_ANCHOR_Y))
    assert _xy(places["J3"]) == pytest.approx((25.0 + SOCKET_ANCHOR_Y, 30.0))
    assert _xy(places["J4"]) == pytest.approx((40.0, 30.0 - SOCKET_ANCHOR_Y))
    # The origins are untouched, which is what makes the anchor the ONLY thing
    # that moved: same three placements, same authored datums.
    assert places["J2"].origin == (10.0, 30.0)
    assert places["J3"].origin == (25.0, 30.0)
    assert places["J4"].origin == (40.0, 30.0)


# ---------------------------------------------------------------------------
# The synthetic expansion.
# ---------------------------------------------------------------------------


def test_expansion_emits_one_part_per_authored_placement():
    """U1S is one DRAWN component and two SOLDERED parts, shaped like this
    board's DevKit socket: two strips 22.86 mm apart. It contributes two CPL
    rows under the AUTHORED refs — never the component's own ref, and never a
    ref the exporter invented — and a BOM quantity of two.

    Hand-derived: parent at (20, 50), rotation 0, top.
      U1S_A  offset (0, 0)      -> origin (20, 50)    anchor (20, 57.62)
      U1S_B  offset (22.86, 0)  -> origin (42.86, 50) anchor (42.86, 57.62)
    """
    board = _compiled()
    places = _placements(board)
    assert "U1S" not in places
    assert places["U1S_A"].origin == pytest.approx((20.0, 50.0))
    assert _xy(places["U1S_A"]) == pytest.approx((20.0, 50.0 + SOCKET_ANCHOR_Y))
    assert places["U1S_B"].origin == pytest.approx((20.0 + ROW_PITCH, 50.0))
    assert _xy(places["U1S_B"]) == pytest.approx(
        (20.0 + ROW_PITCH, 50.0 + SOCKET_ANCHOR_Y))

    rows = _cpl_rows(board)
    assert rows["U1S_A"].rotation_deg == 0.0
    assert rows["U1S_B"].rotation_deg == 0.0

    # The BOM counts PARTS, not drawings: U1S and U2S are two components and
    # four purchased strips, grouped as one line because they share an identity.
    bom = {row.mpn: row for row in ao.build_bom(board, "jlc").rows}
    assert bom["C41376161"].refs == ("U1S_A", "U1S_B", "U2S_A", "U2S_B")
    assert bom["C41376161"].qty == 4


def test_expansion_composes_offset_rotation_and_side_together():
    """THE THREE-COMPOSER CASE, which is the only one that can catch an order
    error in the composition. U2S: parent at (60, 50), rotation 90, BOTTOM, with
    a per-placement rotation on the second strip.

      U2S_A  offset (0, 0), rotation 0
             origin = (60, 50); angle = 90 - 0 = 90
             anchor: mirror (0, 7.62) -> (0, -7.62);
                     R_cw(90)·(0, -7.62) = (-7.62, 0)   -> (52.38, 50)
      U2S_B  offset (22.86, 0), rotation 90
             origin: mirror (22.86, 0) -> (22.86, 0);
                     R_cw(90)·(22.86, 0) = (0, -22.86)  -> (60, 27.14)
             angle = 90 - 90 = 0
             anchor: mirror -> (0, -7.62), unrotated    -> (60, 19.52)

    The per-placement angle SUBTRACTS on the bottom side rather than adding,
    because a reflection conjugates a rotation into its inverse, and B's 90 is
    chosen to make that the whole difference: adding would emit Rotation 180
    instead of 0 and put the strip's anchor at (60, 34.76) — 15.24 mm, the
    socket's entire pin span, from where it is. (A 180-degree placement rotation
    would have hidden the error, since 90 + 180 and 90 - 180 are the same
    angle.)
    """
    places = _placements(_compiled())

    assert places["U2S_A"].origin == pytest.approx((60.0, 50.0))
    assert places["U2S_A"].rotation_deg == pytest.approx(90.0)
    assert _xy(places["U2S_A"]) == pytest.approx((60.0 - SOCKET_ANCHOR_Y, 50.0))

    assert places["U2S_B"].origin == pytest.approx((60.0, 50.0 - ROW_PITCH))
    assert places["U2S_B"].rotation_deg == pytest.approx(0.0)
    assert _xy(places["U2S_B"]) == pytest.approx(
        (60.0, 50.0 - ROW_PITCH - SOCKET_ANCHOR_Y))

    assert places["U2S_A"].side.value == "bottom"
    assert places["U2S_B"].side.value == "bottom"


def test_the_whole_fixture_renders_the_hand_derived_table():
    """One seal over all eleven parts, in the emitted frame — X verbatim, Y
    NEGATED, four fixed decimals — so a change to any single number in the chain
    (anchor, transform, expansion, frame, formatting) lands here as well as in
    the focused test that owns it."""
    content = next(iter(ao.build_cpl(_compiled(), "jlc", name="anchor").values()))
    assert content == (
        "Designator,Mid X,Mid Y,Layer,Rotation\r\n"
        "J2,10.0000,-37.6200,Top,0.0000\r\n"
        "J3,32.6200,-30.0000,Top,90.0000\r\n"
        "J4,40.0000,-22.3800,Bottom,0.0000\r\n"
        "Q1,10.0000,-10.0000,Top,0.0000\r\n"
        "Q2,20.0000,-10.0000,Top,90.0000\r\n"
        "Q3,30.0000,-10.0000,Bottom,0.0000\r\n"
        "Q4,40.0000,-10.0000,Bottom,90.0000\r\n"
        "U1S_A,20.0000,-57.6200,Top,0.0000\r\n"
        "U1S_B,42.8600,-57.6200,Top,0.0000\r\n"
        "U2S_A,52.3800,-50.0000,Bottom,90.0000\r\n"
        "U2S_B,60.0000,-19.5200,Bottom,0.0000\r\n"
    )


def test_bom_and_cpl_place_exactly_the_same_designators():
    """The expansion has to reach BOTH emitters or an order describes two
    different part counts — the property held at the point the expansion is
    consumed, rather than at the reference-set gate that also enforces it."""
    board = _compiled()
    bom_refs = {ref for row in ao.build_bom(board, "jlc").rows for ref in row.refs}
    cpl_refs = {row.ref for row in ao.build_cpl(board, "jlc").rows}
    assert bom_refs == cpl_refs
    assert "U1S_A" in bom_refs and "U2S_B" in bom_refs


# ---------------------------------------------------------------------------
# The two JLC convention proofs, measured on real compiled pad geometry.
# ---------------------------------------------------------------------------


def _pads_about_the_anchor(board, ref: str) -> dict:
    """Each land of ``ref``, as an offset from its own emitted anchor, IN THE
    EMITTED FRAME (Y negated) — the frame a house reads the CSV in."""
    component = next(c for c in board.components if c.ref == ref)
    numbers = {pad.source_id: pad.number for pad in board.footprint_for(component).pads}
    place = component.physical_placements[0]
    ax, ay = place.anchor[0], -place.anchor[1]
    return {numbers[pad.source_id]: (pad.position[0] - ax, -pad.position[1] - ay)
            for pad in component.placed_pads}


def _ccw(vector, degrees: float):
    radians = math.radians(degrees)
    cos, sin = math.cos(radians), math.sin(radians)
    return (vector[0] * cos - vector[1] * sin, vector[0] * sin + vector[1] * cos)


@pytest.mark.parametrize("at_zero,turned", [("Q1", "Q2"), ("Q3", "Q4")])
def test_emitted_rotation_turns_the_part_counter_clockwise(at_zero, turned):
    """JLCPCB'S CONVENTION, PROVEN: a positive Rotation is COUNTER-CLOCKWISE.

    Not argued from a Y-up/Y-down label — measured. Two SOT-23s differing only
    in their authored rotation (0 vs 90) are compiled, each of their three lands
    is expressed as an offset from its OWN emitted anchor in the emitted frame,
    and the turned part's lands must be the unturned part's rotated
    counter-clockwise by exactly the emitted Rotation.

    SOT-23 is the asymmetric part the claim needs: pin 1 and pin 2 sit on one
    side and pin 3 on the other, so a clockwise emitter would swap pin 1 and pin
    2 and fail here. A two-terminal chip part is symmetric under the sign error
    and would pass either way.

    Run on BOTH sides (Q1/Q2 top, Q3/Q4 bottom), because the interesting half of
    this claim is that the sign does NOT flip on the bottom: the placement
    frame's mirror and the emitter's Y negation cancel, so one convention covers
    the whole board.
    """
    board = _compiled()
    rotation = _cpl_rows(board)[turned].rotation_deg
    assert rotation == 90.0

    base = _pads_about_the_anchor(board, at_zero)
    after = _pads_about_the_anchor(board, turned)
    assert set(base) == {"1", "2", "3"}
    for number, offset in base.items():
        assert after[number] == pytest.approx(_ccw(offset, rotation), abs=1e-9)


def test_bottom_side_coordinates_are_not_mirrored():
    """JLCPCB'S OTHER CONVENTION, PROVEN: bottom-side coordinates are NOT
    mirrored — they are stated in the same top-view frame as everything else, so
    a mirrored file is the wrong file.

    Two SOT-23s at the same rotation, one per side. The bottom part's emitted X
    is its authored X, unnegated, and — the sharper claim, because an X negation
    about the part's own centre would leave the row's X alone — its lands keep
    their X signs: pin 3 stays on the +x side of the anchor and pins 1/2 on the
    -x side. What DOES change is Y, which is exactly right: the part is seen
    through the board, so it is reflected top-to-bottom, not left-to-right.
    """
    board = _compiled()
    rows = _cpl_rows(board)
    assert rows["Q1"].x_mm == 10.0 and rows["Q3"].x_mm == 30.0

    top = _pads_about_the_anchor(board, "Q1")
    bottom = _pads_about_the_anchor(board, "Q3")
    for number, offset in top.items():
        assert bottom[number] == pytest.approx((offset[0], -offset[1]), abs=1e-9)
    assert top["3"][0] > 0 and bottom["3"][0] > 0


# ---------------------------------------------------------------------------
# The basis is DATA, and an IR without placements is a NAMED refusal.
# ---------------------------------------------------------------------------


def test_every_basis_in_the_ladder_is_reachable_and_recorded():
    """All three outcomes, on one real board, so "which drawing answered this"
    is never something a consumer has to guess at:

      D1   Diode_SMD:D_SMA               fab outline
      R1   R_0805                        lands (the seed 0805 draws no fab)
      TXT1 Minerva_Fixture:TXT_CouponRev silk-only furniture -> the origin,
                                         said out loud rather than inferred
    """
    places = _placements(_compiled(RESOLVED_FIXTURE))
    assert places["D1"].anchor_basis == ANCHOR_BASIS_FAB
    assert places["R1"].anchor_basis == ANCHOR_BASIS_LANDS
    assert places["TXT1"].anchor_basis == ANCHOR_BASIS_ORIGIN
    # The origin fallback is a MEASUREMENT OUTCOME, not a silent default: it
    # still resolves an anchor, and that anchor is the placement itself.
    assert places["TXT1"].anchor == places["TXT1"].origin


def test_a_component_with_no_resolved_placements_is_a_named_refusal():
    """An IR built by something other than the compiler must not read as "this
    component places nothing" — for an expansion that would drop every part but
    one from the order, silently. Same fail-closed shape as a component carrying
    no resolved assembly block."""
    board = _compiled()
    stripped = replace(board, components=tuple(
        replace(c, physical_placements=()) for c in board.components))
    with pytest.raises(ao.AssemblyBoardError) as exc_info:
        ao.build_cpl(stripped, "jlc")
    assert "physical placements" in str(exc_info.value)


# ---------------------------------------------------------------------------
# The per-placement anchor: a drawing that spreads several parts across itself.
# ---------------------------------------------------------------------------


def test_the_socket_set_footprint_measures_what_the_override_fixture_claims():
    """THE PREMISE OF THE OVERRIDE TESTS, pinned like the fixture footprints
    above so a library edit breaks loudly rather than rewriting the answers.

    The DevKit socket set draws ONE fab body box over BOTH strips —
    (-12.93, -1.1)..(12.93, 62.797), centring at (0, 30.8485), which is the
    module that plugs in rather than either soldered part. Its 44 pads sit in
    two rows at x -11.43 and +11.43, each spanning y 0..53.34, so each STRIP
    centres at (+/-11.43, 26.67). The fab centre lies BETWEEN the two strips and
    on neither of them, and it is 4.1785 mm north of both.
    """
    socket_set = _definition(
        "Espressif.pretty/ESP32-S3-DevKitC-1_SocketSet_2x22_THT.kicad_mod")
    fab = refdes_anchor.fab_extent_from_definition(socket_set)
    assert (fab.min_x, fab.min_y, fab.max_x, fab.max_y) == pytest.approx(
        (-12.93, -1.1, 12.93, 62.797))
    assert (fab.center_x, fab.center_y) == pytest.approx(
        (0.0, SOCKET_SET_FAB_ANCHOR_Y))

    rows: dict[float, list[float]] = {}
    for pad in socket_set.pads:
        rows.setdefault(pad.position[0], []).append(pad.position[1])
    assert sorted(rows) == pytest.approx([-ROW_HALF_SPACING, ROW_HALF_SPACING])
    for x, ys in rows.items():
        assert len(ys) == 22
        assert (min(ys) + max(ys)) / 2 == pytest.approx(STRIP_ANCHOR_Y)
    # The gap the fixture's authored anchors close, said as one number.
    assert SOCKET_SET_FAB_ANCHOR_Y - STRIP_ANCHOR_Y == pytest.approx(4.1785)


def test_without_an_authored_anchor_every_child_inherits_the_parents():
    """THE DEFECT, AND THE OTHER DIRECTION OF THE ORACLE. Strip the six
    ``anchor_mm`` keys and nothing else: ONE anchor is measured off the parent
    footprint and every expanded part is handed it, so both strips of every
    component are placed on the module's centre rather than on their own.

    Hand-derived from (0, 30.8485) and the transform:

      U3S  parent (30, 20), rotation 0, top
           both anchors -> y 20 + 30.8485 = 50.8485, at x 18.57 and 41.43
      U4S  parent (100, 80), rotation 90, BOTTOM
           mirror (0, 30.8485) -> (0, -30.8485); R_cw(90) -> (-30.8485, 0)
           both anchors -> x 100 - 30.8485 = 69.1515
      U5S  parent (30, 110), the DCR worked example's own offsets
           both anchors -> y 140.8485, at x 30 and 52.86

    Every pair is a correct 22.86 mm apart and every one of them is wrong.
    """
    places = _placements(_compiled_without_authored_anchors())
    for ref in ("U3S_A", "U3S_B", "U4S_A", "U4S_B", "U5S_A", "U5S_B"):
        assert places[ref].anchor_basis == ANCHOR_BASIS_FAB

    assert _xy(places["U3S_A"]) == pytest.approx(
        (30.0 - ROW_HALF_SPACING, 20.0 + SOCKET_SET_FAB_ANCHOR_Y))
    assert _xy(places["U3S_B"]) == pytest.approx(
        (30.0 + ROW_HALF_SPACING, 20.0 + SOCKET_SET_FAB_ANCHOR_Y))
    assert _xy(places["U4S_A"]) == pytest.approx(
        (100.0 - SOCKET_SET_FAB_ANCHOR_Y, 80.0 + ROW_HALF_SPACING))
    assert _xy(places["U4S_B"]) == pytest.approx(
        (100.0 - SOCKET_SET_FAB_ANCHOR_Y, 80.0 - ROW_HALF_SPACING))
    assert _xy(places["U5S_A"]) == pytest.approx(
        (30.0, 110.0 + SOCKET_SET_FAB_ANCHOR_Y))
    assert _xy(places["U5S_B"]) == pytest.approx(
        (30.0 + ROW_PITCH, 110.0 + SOCKET_SET_FAB_ANCHOR_Y))


def test_the_inherited_anchors_pass_every_existing_gate():
    """WHY THIS NEEDED A SCHEMA KEY RATHER THAN A CHECK. The six wrong anchors
    above are not merely unrefused — nothing in the order path can see them. The
    spacing gate is the only one that looks at where parts are, and it only asks
    whether two designators are too CLOSE; two anchors a correct 22.86 mm apart
    clear it whatever point they are both measured from. The whole package
    builds, and it carries no advisory either, because every anchor WAS measured
    — off the wrong body.

    The first thing that would notice is a person looking at a placement
    preview, which is exactly why the honest datum has to be authorable.
    """
    board = _compiled_without_authored_anchors()
    package = ao.build_package(board, "jlc", name="stripped")
    assert package.emission.advisories == ()
    rows = _cpl_rows(board)
    assert math.hypot(rows["U3S_B"].x_mm - rows["U3S_A"].x_mm,
                      rows["U3S_B"].y_mm - rows["U3S_A"].y_mm) == pytest.approx(ROW_PITCH)


def test_an_authored_anchor_puts_each_part_on_its_own_body_centre():
    """THE ORACLE. U3S authors one origin per strip and one anchor per strip,
    and both numbers come off the purchased part: 11.43 is half the 22.86 mm row
    spacing the footprint states in its own ``descr``, and 26.67 is half a 1x22
    strip's pin span (21 x 2.54 / 2).

      U3S_A  offset (-11.43, 0) -> origin (18.57, 20)
             anchor (0, 26.67) in its own frame -> (18.57, 46.67)
      U3S_B  offset (+11.43, 0) -> origin (41.43, 20)
             anchor (0, 26.67) in its own frame -> (41.43, 46.67)

    Each is that strip's true centre. The ORIGINS are identical to the stripped
    arm's, which is what makes the anchor the only thing the key changed.
    """
    places = _placements(_compiled(OVERRIDE_FIXTURE))
    stripped = _placements(_compiled_without_authored_anchors())

    assert _xy(places["U3S_A"]) == pytest.approx(
        (30.0 - ROW_HALF_SPACING, 20.0 + STRIP_ANCHOR_Y))
    assert _xy(places["U3S_B"]) == pytest.approx(
        (30.0 + ROW_HALF_SPACING, 20.0 + STRIP_ANCHOR_Y))
    for ref in ("U3S_A", "U3S_B"):
        assert places[ref].origin == pytest.approx(stripped[ref].origin)
        assert places[ref].anchor != stripped[ref].anchor


def test_an_authored_anchor_is_recorded_as_authored_not_measured():
    """A figure a person wrote down and a box measured off a drawing are not the
    same kind of answer, so they do not share a basis token. A consumer reading
    ``fab_outline`` on an authored anchor would be told the geometry agrees with
    a number no drawing was consulted for."""
    places = _placements(_compiled(OVERRIDE_FIXTURE))
    assert {p.anchor_basis for p in places.values()} == {ANCHOR_BASIS_AUTHORED}


def test_an_authored_anchor_rides_the_child_transform():
    """The authored number is stated in the placement's OWN local frame and is
    then turned and mirrored by the same object that places the copper — it is
    not a board coordinate and not a shortcut around the transform.

    U4S: parent (100, 80), rotation 90, BOTTOM, offsets +/-11.43 in x.

      U4S_A  offset (-11.43, 0): mirror -> (-11.43, 0);
             R_cw(90)-(x, y) = (y, -x) -> (0, 11.43)   origin (100, 91.43)
             anchor (0, 26.67): mirror -> (0, -26.67);
             R_cw(90) -> (-26.67, 0)                   -> (73.33, 91.43)
      U4S_B  offset (+11.43, 0) -> (0, -11.43)         origin (100, 68.57)
             same anchor                               -> (73.33, 68.57)

    An anchor added to the origin WITHOUT the transform would leave both at
    x 100 and put them 26.67 mm north; one that skipped only the bottom mirror
    would land at x 126.67. The measured fallback lands at x 69.1515, so the
    override moves x by exactly the 4.1785 mm the premise test names.
    """
    places = _placements(_compiled(OVERRIDE_FIXTURE))
    assert places["U4S_A"].origin == pytest.approx((100.0, 80.0 + ROW_HALF_SPACING))
    assert places["U4S_B"].origin == pytest.approx((100.0, 80.0 - ROW_HALF_SPACING))
    assert _xy(places["U4S_A"]) == pytest.approx(
        (100.0 - STRIP_ANCHOR_Y, 80.0 + ROW_HALF_SPACING))
    assert _xy(places["U4S_B"]) == pytest.approx(
        (100.0 - STRIP_ANCHOR_Y, 80.0 - ROW_HALF_SPACING))
    assert places["U4S_A"].rotation_deg == pytest.approx(90.0)
    assert places["U4S_A"].side.value == "bottom"


def test_an_authored_anchor_repairs_the_worked_examples_own_offsets():
    """U5S carries the DCR worked example's offsets VERBATIM — (0, 0) and
    (22.86, 0), which put both origins on the parent's datum line rather than on
    either strip — and repairs it with the anchor ALONE, without moving an
    authored offset or re-drawing anything.

    Both placements state the same (-11.43, 26.67), because both strips sit
    11.43 mm west of their own placement's origin: A's origin IS the parent
    datum and the west strip is 11.43 west of it; B's origin is 22.86 east of
    the datum while the east strip is only 11.43 east of it. The result is the
    same pair of true strip centres U3S reaches from the other authoring.
    """
    places = _placements(_compiled(OVERRIDE_FIXTURE))
    assert places["U5S_A"].origin == pytest.approx((30.0, 110.0))
    assert places["U5S_B"].origin == pytest.approx((30.0 + ROW_PITCH, 110.0))
    assert _xy(places["U5S_A"]) == pytest.approx(
        (30.0 - ROW_HALF_SPACING, 110.0 + STRIP_ANCHOR_Y))
    assert _xy(places["U5S_B"]) == pytest.approx(
        (30.0 + ROW_HALF_SPACING, 110.0 + STRIP_ANCHOR_Y))


def test_the_override_fixture_renders_the_hand_derived_table():
    """One seal over all six parts in the emitted frame — X verbatim, Y negated,
    four fixed decimals — so a change anywhere in the chain lands here as well as
    in the focused test that owns it."""
    content = next(iter(ao.build_cpl(
        _compiled(OVERRIDE_FIXTURE), "jlc", name="override").values()))
    assert content == (
        "Designator,Mid X,Mid Y,Layer,Rotation\r\n"
        "U3S_A,18.5700,-46.6700,Top,0.0000\r\n"
        "U3S_B,41.4300,-46.6700,Top,0.0000\r\n"
        "U4S_A,73.3300,-91.4300,Bottom,90.0000\r\n"
        "U4S_B,73.3300,-68.5700,Bottom,90.0000\r\n"
        "U5S_A,18.5700,-136.6700,Top,0.0000\r\n"
        "U5S_B,41.4300,-136.6700,Top,0.0000\r\n"
    )
