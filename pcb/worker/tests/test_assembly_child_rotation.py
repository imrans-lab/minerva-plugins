"""HOW A CHILD'S ROTATION COMPOSES WITH ITS PARENT'S.

One drawn component may stand for several physical parts, each with its own
``offset_mm`` and its own ``rotation_deg``, through an ``assembly.placements``
block. Each authored placement becomes one row in the position file and one
unit in the BOM, so the angle it composes to is a number a machine turns a real
part by.

THE RULE, as ``assembly_anchor.physical_placements`` composes it through one
:class:`geometry.PlacementTransform`::

    emitted = (parent_rotation + child_rotation) % 360    on the TOP side
    emitted = (parent_rotation - child_rotation) % 360    on the BOTTOM side

The subtraction is not a special case bolted on: a reflection conjugates a
rotation into its inverse (``M.R(r) = R(-r).M``), so one transform object gives
both. The child's angle turns the child ABOUT ITS OWN ORIGIN and never touches
where that origin is -- the origin is the parent's transform applied to the
authored offset, and nothing else.

WHY THIS SUITE EXISTS, MEASURED RATHER THAN ASSERTED
----------------------------------------------------
A board shipped with its child rotations wrong: the placements carried no
rotation of their own, every child silently wore its parent's, and the parts
came out a quarter turn from the holes. Nothing in the tree failed. Reading the
corpus at the time this was written:

  * ``assembly_anchor.yaml`` is the ONLY board whose child states a rotation --
    U2S_B, ``rotation_deg: 90`` under a parent at ``rotation_deg: 90`` on the
    bottom. Real coverage, and it does refuse ``p + c``. But the two operands
    COLLIDE at 90, so ``p - c`` and a swapped ``c - p`` are the same answer
    there, and it is the only board that says anything at all;
  * ``assembly_anchor_override.yaml`` sets ``rotation_deg: 0`` on all six of its
    placements -- including U4S's two, whose parent sits at 90. The one worked
    example a reader is likeliest to copy therefore teaches the exact shape that
    shipped wrong;
  * on the TOP side, where the composition ADDS, NO placement anywhere stated a
    rotation. The additive half of the rule had no board-level oracle.

So the arithmetic below is not a restatement of code that already had a test. It
is the first place the top-side sum, an operand pair that does not collide, and
the absent-``rotation_deg`` case are pinned.

EVERY EXPECTATION IS HAND-DERIVED from the fixture's authored numbers and the
transform ``geometry.py`` documents -- ``board = position + R_cw(rot) .
mirror(local)``, with ``R_cw(d).(x, y) = (x.cos d + y.sin d, -x.sin d + y.cos
d)`` and ``mirror`` negating local Y on the bottom side. Nothing here asks
``assembly_anchor`` what it thinks the answer is, and the composed angles are
written as literal constants rather than computed from the operands.
"""

from __future__ import annotations

import math
from pathlib import Path

import pytest
import yaml

from pcb_worker import assembly_outputs as ao
from pcb_worker.compile_board import compile_board
from pcb_worker.resolved_board import (
    ANCHOR_BASIS_AUTHORED, DiagnosticSeverity, ResolutionSuccess,
)
from tests import orientation_corpus

BOARDS = Path(__file__).resolve().parent / "testdata" / "assembly_boards"
FIXTURE = BOARDS / "assembly_child_rotation.yaml"

#: cos 45 = sin 45. The composed 135-degree cases land on it; every other
#: expectation below is an exact integer.
H = math.sqrt(2) / 2

# --- the fixture's authored numbers, restated once so each expectation names
#     what it came from rather than repeating a literal --------------------
U6R_AT = (45.0, 35.0)      # top parent, rotation 270
U7R_AT = (110.0, 40.0)     # bottom parent, rotation 90
PARENT_TOP_ROTATION = 270.0
PARENT_BOTTOM_ROTATION = 90.0
CHILD_TOP_ROTATION = 225.0
CHILD_BOTTOM_ROTATION = 315.0

#: THE ANSWERS. Written as literals, because a constant derived from the
#: operands would be the rule under test spelled a second time.
U6R_A_ROTATION = 135.0     # (270 + 225) % 360, i.e. 495 wrapped past a turn
U6R_B_ROTATION = 270.0     # the parent's own, nothing authored
U7R_A_ROTATION = 135.0     # (90 - 315) % 360, i.e. -225 wrapped up
U7R_B_ROTATION = 90.0      # the parent's own, nothing authored

#: Child origins. Each is the PARENT's transform applied to the authored
#: offset; the child's own rotation does not appear in any of them.
#:   U6R  R_cw(270).(x, y) = (-y, x), top, no mirror
#:     A  (18, -7)  -> (7, 18)    -> (52, 53)
#:     B  (-12, 21) -> (-21, -12) -> (24, 23)
#:   U7R  R_cw(90).(x, y) = (y, -x), bottom, local Y negated first
#:     A  (16, 25)  -> (16, -25) -> (-25, -16) -> (85, 24)
#:     B  (-22, 8)  -> (-22, -8) -> (-8, 22)   -> (102, 62)
ORIGINS = {
    "U6R_A": (52.0, 53.0),
    "U6R_B": (24.0, 23.0),
    "U7R_A": (85.0, 24.0),
    "U7R_B": (102.0, 62.0),
}

#: Emitted anchors: the authored (3, 8), stated in each placement's OWN frame,
#: put through a transform at that placement's own origin and COMPOSED angle.
#:   U6R_A  at 135, top:     R_cw(135).(3, 8)  = H.(-3+8, -3-8) = H.(5, -11)
#:   U6R_B  at 270, top:     R_cw(270).(3, 8)  = (-8, 3)
#:   U7R_A  at 135, bottom:  mirror -> (3, -8); R_cw(135) = H.(-3-8, -3+8)
#:                                            = H.(-11, 5)
#:   U7R_B  at  90, bottom:  mirror -> (3, -8); R_cw(90) = (-8, -3)
ANCHORS = {
    "U6R_A": (52.0 + 5 * H, 53.0 - 11 * H),
    "U6R_B": (16.0, 26.0),
    "U7R_A": (85.0 - 11 * H, 24.0 + 5 * H),
    "U7R_B": (94.0, 59.0),
}


@pytest.fixture(autouse=True)
def _corpus_orientation(monkeypatch):
    """The shared corpus orientation statement, installed for the same reason
    every assembly-emitting suite here installs it: these boards are drawn on
    this repository's own seed patterns, and orientation is measured by
    test_assembly_orientation.py, not here."""
    orientation_corpus.install(monkeypatch)


def _compiled():
    """The compiled fixture. Fails LOUDLY rather than skipping: a fixture that
    stopped compiling would silently stop testing anything here."""
    result = compile_board(yaml.safe_load(FIXTURE.read_text(encoding="utf-8")))
    if not isinstance(result, ResolutionSuccess):
        raise AssertionError(
            "fixture did not compile: "
            + ", ".join(d.code for d in result.diagnostics
                        if d.severity is DiagnosticSeverity.ERROR))
    return result.board


def _placements(board) -> dict:
    return {item.ref: item
            for component in board.components
            for item in component.physical_placements}


def _cpl_rows(board) -> dict:
    return {row.ref: row for row in ao.build_cpl(board, "jlc").rows}


def _authored(ref: str) -> dict:
    """One authored placement mapping, straight out of the YAML."""
    document = yaml.safe_load(FIXTURE.read_text(encoding="utf-8"))
    for component in document["components"]:
        for placement in component["assembly"]["placements"]:
            if placement["ref"] == ref:
                return {"parent": component, "placement": placement}
    raise AssertionError(f"the fixture no longer authors {ref}")


# ---------------------------------------------------------------------------
# The premise. This suite is only worth anything while the fixture keeps
# authoring the shapes it was built to author.
# ---------------------------------------------------------------------------


def test_the_fixture_authors_child_rotations_that_differ_from_their_parents():
    """THE PREMISE, GUARDED. The coverage this suite adds is destroyed the
    moment someone "tidies" a child rotation to match its parent or to zero --
    which is how it was lost before: every placement in
    ``assembly_anchor_override.yaml`` sets ``rotation_deg: 0``, two of them
    under a parent at 90, so the block's worked example teaches the very shape
    that shipped wrong.

    Asserted here, on the authored document, so a fixture edit that removes the
    test's ability to falsify fails by name instead of by still passing.
    """
    top, bottom = _authored("U6R_A"), _authored("U7R_A")

    assert top["parent"]["rotation_deg"] == PARENT_TOP_ROTATION
    assert top["parent"]["layer"] == "top"
    assert top["placement"]["rotation_deg"] == CHILD_TOP_ROTATION

    assert bottom["parent"]["rotation_deg"] == PARENT_BOTTOM_ROTATION
    assert bottom["parent"]["layer"] == "bottom"
    assert bottom["placement"]["rotation_deg"] == CHILD_BOTTOM_ROTATION

    # Neither child wears its parent's angle, and neither is at rest.
    for case in (top, bottom):
        assert case["placement"]["rotation_deg"] != case["parent"]["rotation_deg"]
        assert case["placement"]["rotation_deg"] % 360.0 != 0.0

    # And the SILENT half is authored as an absence, not as a zero: a zero would
    # be a claim, and the defect's shape is a placement that never answered.
    for ref in ("U6R_B", "U7R_B"):
        assert "rotation_deg" not in _authored(ref)["placement"]


def test_no_wrong_composition_of_the_fixtures_operands_reaches_the_right_answer():
    """WHY THESE NUMBERS AND NOT ROUNDER ONES. A test that cannot distinguish
    ``p + c`` from ``p - c`` from ``c - p`` from ``p`` alone proves nothing, and
    the corpus's only prior child rotation -- U2S_B's 90 under a parent at 90 --
    cannot tell the last three apart.

    Enumerated rather than argued, for both components: the right answer must
    differ from EVERY other composition of the same two operands. If a future
    edit picks operands that collide, this fails before the arithmetic tests do
    and says why.
    """
    for parent, child, right in (
        (PARENT_TOP_ROTATION, CHILD_TOP_ROTATION, U6R_A_ROTATION),
        (PARENT_BOTTOM_ROTATION, CHILD_BOTTOM_ROTATION, U7R_A_ROTATION),
    ):
        wrong = {(parent + child) % 360.0, (parent - child) % 360.0,
                 (child - parent) % 360.0, parent % 360.0, child % 360.0, 0.0}
        wrong.discard(right)
        assert len(wrong) == 5, (
            f"parent {parent} and child {child} produce a colliding pair: two "
            f"different compositions give the same angle, so an assertion on "
            f"{right} could pass under the wrong rule")


# ---------------------------------------------------------------------------
# The composition itself.
# ---------------------------------------------------------------------------


def test_a_child_rotation_adds_to_its_parents_on_the_top_side():
    """THE HALF NOTHING COVERED. U6R_A authors 225 under a parent at 270 on the
    top side, and must be emitted at 135: 270 + 225 = 495, wrapped past a full
    turn.

    Every other composition of those two operands is a different angle -- 45 if
    the sum were a difference, 315 if the operands were swapped, 270 if the
    child's rotation were dropped, 225 if the parent's were -- so this one
    assertion refuses all four. The unwrapped 495 could not be emitted at all:
    ``PhysicalPlacement`` refuses anything outside [0, 360).
    """
    places = _placements(_compiled())
    place = places["U6R_A"]
    assert place.rotation_deg == pytest.approx(U6R_A_ROTATION)
    assert place.side.value == "top"
    # Said the other way round, so the claim is legible without the arithmetic:
    # the child is turned 225 degrees FROM its parent. Its sibling authored no
    # rotation and therefore sits at the parent's own angle, which makes it the
    # datum this difference is read against.
    assert (place.rotation_deg - places["U6R_B"].rotation_deg) % 360.0 == (
        pytest.approx(CHILD_TOP_ROTATION))


def test_a_child_rotation_subtracts_from_its_parents_on_the_bottom_side():
    """THE MIRRORED HALF, with operands that do not collide. U7R_A authors 315
    under a parent at 90 on the BOTTOM, and must be emitted at 135: 90 - 315 is
    -225, wrapped back up. Adding would give 45 and swapping the operands would
    give 225.

    A reflection conjugates a rotation into its inverse, so the sign flip is the
    transform being one object rather than two rules. The corpus's existing
    bottom-side case (U2S_B, 90 under 90) proves the flip but cannot see an
    operand swap, because its two operands are equal.
    """
    place = _placements(_compiled())["U7R_A"]
    assert place.rotation_deg == pytest.approx(U7R_A_ROTATION)
    assert place.side.value == "bottom"
    # Named explicitly, because it is the whole content of "the bottom side
    # subtracts": the additive answer for this pair is 45, and it is not this.
    assert place.rotation_deg != pytest.approx(
        (PARENT_BOTTOM_ROTATION + CHILD_BOTTOM_ROTATION) % 360.0)


def test_a_placement_that_authors_no_rotation_wears_its_parents_exactly():
    """THE SILENT HALF, MADE EXPLICIT -- and the shape the defect shipped in.

    A placement with no ``rotation_deg`` key composes a zero, so it comes out at
    its parent's angle verbatim: 270 on the top parent, 90 on the bottom one.
    That behaviour is CORRECT and it is what a board author must know, because
    "I wrote no rotation" and "this part is turned like its parent" are the same
    sentence here. A drawing whose parts do NOT share the parent's angle has to
    say so on every placement.

    Pinned on both sides deliberately: on the bottom the composition SUBTRACTS,
    and subtracting zero has to leave the parent's angle alone rather than
    negate it -- an implementation that emitted ``-90 % 360 = 270`` for U7R_B
    would be turned a half-circle from every part it shares a board with.
    """
    places = _placements(_compiled())
    assert places["U6R_B"].rotation_deg == pytest.approx(U6R_B_ROTATION)
    assert places["U6R_B"].rotation_deg == pytest.approx(PARENT_TOP_ROTATION)
    assert places["U7R_B"].rotation_deg == pytest.approx(U7R_B_ROTATION)
    assert places["U7R_B"].rotation_deg == pytest.approx(PARENT_BOTTOM_ROTATION)


def test_siblings_under_one_parent_do_not_share_one_angle():
    """THE DEFECT'S OWN SHAPE, as one comparison. U6R_A and U6R_B are two parts
    of one drawing on one side at one parent angle, and they must come out at
    DIFFERENT angles -- 135 and 270 -- because only one of them authored a
    rotation. The board that shipped wrong had four such parts all wearing the
    parent's 270.

    The same claim on the bottom, where the pair is 135 and 90.
    """
    places = _placements(_compiled())
    assert places["U6R_A"].rotation_deg != pytest.approx(
        places["U6R_B"].rotation_deg)
    assert places["U7R_A"].rotation_deg != pytest.approx(
        places["U7R_B"].rotation_deg)

    # The two components reach the SAME 135 from opposite sides through opposite
    # operations (270 + 225 and 90 - 315). That agreement is a property of the
    # rule rather than of either input, and it is the reason both are here.
    assert places["U6R_A"].rotation_deg == pytest.approx(
        places["U7R_A"].rotation_deg)


# ---------------------------------------------------------------------------
# Offsets and rotations, composing together rather than each alone.
# ---------------------------------------------------------------------------


def test_the_offset_rides_the_parents_angle_and_the_anchor_rides_the_composed_one():
    """THE TWO ANGLES ARE NOT THE SAME ANGLE, and a placement uses both.

    A child's ORIGIN is the parent's transform applied to the authored offset --
    the parent's angle, never the child's, because the child turns about a point
    the parent already chose. The child's ANCHOR is then that origin's own
    transform applied to the authored anchor -- the COMPOSED angle, because the
    part itself is what turned.

    Hand-derived; see the ORIGINS and ANCHORS tables above for each line of the
    arithmetic. The offsets are lopsided on purpose (no ``|x|`` equals its own
    ``|y|``, and no offset is another's negation), so an offset put through the
    wrong angle cannot land back on the right point by symmetry: U6R_A's origin
    through the composed 135 instead of the parent's 270 would be (27.32,
    27.22), nowhere near (52, 53).

    All four placements author the SAME anchor, (3, 8), so the four emitted
    anchors differ by the composition and by nothing else.
    """
    places = _placements(_compiled())
    for ref, origin in ORIGINS.items():
        assert places[ref].origin == pytest.approx(origin), ref
    for ref, anchor in ANCHORS.items():
        assert (places[ref].anchor[0], places[ref].anchor[1]) == pytest.approx(
            anchor), ref
        # A number a person wrote down, never reported as one measured off a
        # drawing.
        assert places[ref].anchor_basis == ANCHOR_BASIS_AUTHORED


def test_a_wrong_composition_moves_the_anchor_far_enough_to_see():
    """THE ANCHOR IS A SECOND, INDEPENDENT WITNESS to the composed angle, and
    this says how loud it is. Under each wrong rule the emitted anchor moves by
    millimetres, not by a rounding -- so the coordinate half of a position file
    fails too, and not only its Rotation column.

    The distances are stated rather than recomputed by the arithmetic under
    test: they are the fixture's answer against the same anchor turned by each
    wrong angle at the same origin, and every one of them is more than a
    millimetre.
    """
    places = _placements(_compiled())
    for ref, parent, child in (("U6R_A", PARENT_TOP_ROTATION, CHILD_TOP_ROTATION),
                               ("U7R_A", PARENT_BOTTOM_ROTATION, CHILD_BOTTOM_ROTATION)):
        place = places[ref]
        origin = ORIGINS[ref]
        right = ANCHORS[ref]
        assert math.hypot(right[0] - origin[0], right[1] - origin[1]) == (
            pytest.approx(math.hypot(3.0, 8.0)))
        for wrong_angle in ((parent + child) % 360.0, (parent - child) % 360.0,
                            (child - parent) % 360.0, parent, child, 0.0):
            if wrong_angle == pytest.approx(place.rotation_deg):
                continue
            radians = math.radians(wrong_angle)
            ay = 8.0 if place.side.value == "top" else -8.0
            moved = (origin[0] + 3.0 * math.cos(radians) + ay * math.sin(radians),
                     origin[1] - 3.0 * math.sin(radians) + ay * math.cos(radians))
            assert math.hypot(moved[0] - right[0], moved[1] - right[1]) > 1.0, (
                f"{ref} at {wrong_angle} lands within a millimetre of the right "
                f"answer, so the anchor cannot witness the composition")


# ---------------------------------------------------------------------------
# What the house is actually sent.
# ---------------------------------------------------------------------------


def test_the_composed_angle_is_what_the_position_file_states():
    """THE CONSUMER. Every claim above is about the compiled IR; this is the
    number a machine turns a part by. One row per authored placement -- never
    one per component -- carrying the composed angle and the emitted frame's
    coordinates (X verbatim, Y NEGATED).

    Asserted field by field rather than as a rendered byte seal: the two boards
    that own byte seals own them for tables this fixture is not part of, and the
    frame map itself already has an owner in test_assembly_anchor.py. What is
    new here is which angle reaches the row.
    """
    rows = _cpl_rows(_compiled())
    assert set(rows) == {"U6R_A", "U6R_B", "U7R_A", "U7R_B"}
    assert rows["U6R_A"].rotation_deg == pytest.approx(U6R_A_ROTATION)
    assert rows["U6R_B"].rotation_deg == pytest.approx(U6R_B_ROTATION)
    assert rows["U7R_A"].rotation_deg == pytest.approx(U7R_A_ROTATION)
    assert rows["U7R_B"].rotation_deg == pytest.approx(U7R_B_ROTATION)
    for ref, anchor in ANCHORS.items():
        assert (rows[ref].x_mm, rows[ref].y_mm) == pytest.approx(
            (anchor[0], -anchor[1])), ref
    assert rows["U6R_A"].side == "top" and rows["U7R_A"].side == "bottom"


def test_the_expansion_reaches_the_bom_as_four_bought_parts():
    """The BOM counts PARTS, not drawings. Two components expand to four
    placements sharing one identity, so the order buys four -- and the two
    emitters must name the same designators or the order describes two different
    boards.
    """
    board = _compiled()
    rows = ao.build_bom(board, "jlc").rows
    bom = {row.mpn: row for row in rows}
    assert bom["C41376161"].refs == ("U6R_A", "U6R_B", "U7R_A", "U7R_B")
    assert bom["C41376161"].qty == 4
    assert {ref for row in rows for ref in row.refs} == set(_cpl_rows(board))
