"""AN AUTHORED ANCHOR THAT RESOLVES OFF THE PART'S OWN COPPER.

``assembly.placements[].anchor_mm`` is stated in the placement's OWN local
frame and rides the placement's transform, so the child's ``rotation_deg``
turns it. The child carries no copper -- the parent's footprint draws all of it
-- so turning a child moves the coordinate a pick-and-place nozzle drives to
while every piece of copper stays exactly where it was. DRC, connectivity and
board check are therefore all clean, and the CPL is the only artifact that
shows it: the assembly house is the one who finds it.

``assembly_gates.check_anchor_on_lands`` refuses that, and this suite is the
proof, on the reduction of the board it was found on
(``testdata/assembly_boards/assembly_anchor_off_lands.yaml``).

THE ORACLE, HAND-DERIVED from the fixture's authored numbers, the footprint
file's own pad grid, and the transform ``geometry.py`` documents -- ``board =
position + R_cw(rot) . mirror(local)``, with ``R_cw(d).(x, y) = (x.cos d + y.sin
d, -x.sin d + y.cos d)``. Nothing below asks the worker what it thinks the
answer is.

  The parent sits at (45, 62.797), rotation 180, top, so ``R_cw(180).(x, y) =
  (-x, -y)`` and no mirror::

    origins    A  offset (-11.43, 0) -> ( 11.43, 0) -> (56.43, 62.797)
               B  offset ( 11.43, 0) -> (-11.43, 0) -> (33.57, 62.797)

  A child's own rotation turns the anchor about that origin and never moves it,
  and the top side ADDS::

    control    child   0 -> composed 180.  R_cw(180).(0, 26.67) = (0, -26.67)
                       A (56.43, 36.127)   B (33.57, 36.127)  -- the strip centres
    defect     child 270 -> composed  90.  R_cw(90).(0, 26.67) = (26.67, 0)
                       A (83.1, 62.797)    B (60.24, 62.797)  -- bare board

  THE BOX. The footprint's 44 lands are 1.7 mm square on two rows at x -11.43
  and +11.43, each spanning y 0 .. 53.34 (21 x 2.54), so the lands box is
  (-12.28, -0.85) .. (12.28, 54.19) locally, and (32.72, 8.607) .. (57.28,
  63.647) once the same ``R_cw(180)`` at (45, 62.797) is applied.

  THE DISTANCES. Both defect anchors are level with the box in y and east of it
  in x, so each distance is one subtraction::

    A  83.10 - 57.28 = 25.82        B  60.24 - 57.28 = 2.96

  25.82, not the 26.67 the anchor was authored at: the anchor swings 26.67 mm
  east of the strip's end PIN, and the box the gate measures against reaches
  0.85 mm further east than that pin's centre, because a land is 1.7 mm across.

WHY 25.82 AND NOT 26.67 IS THE ASSERTION THAT MATTERS. It is the one number
that distinguishes the box the gate really uses -- the lands' EXTENT -- from the
box their centres span. Both refuse this board; only the extent box leaves the
corpus's ordinary parts alone, which is what ``J5`` and ``SW4`` are here to
witness.
"""

from __future__ import annotations

from pathlib import Path

import pytest
import yaml

from pcb_worker import assembly_gates as ag
from pcb_worker import assembly_outputs as ao
from pcb_worker import refdes_anchor as ra
from pcb_worker.compile_board import compile_board
from pcb_worker.resolved_board import (
    ANCHOR_BASIS_AUTHORED, DiagnosticSeverity, ResolutionSuccess,
)
# The shared corpus orientation statement, autouse in this module: these boards
# are drawn on this repository's own land patterns, and orientation is measured
# by test_assembly_orientation.py, not here.
from tests.orientation_corpus import corpus_orientation  # noqa: F401

FIXTURE = (Path(__file__).resolve().parent / "testdata" / "assembly_boards"
           / "assembly_anchor_off_lands.yaml")

#: The one key the defect is away from the control, and what it composes to.
CONTROL_CHILD_ROTATION = 0.0
DEFECT_CHILD_ROTATION = 270.0
CONTROL_COMPOSED = 180.0
DEFECT_COMPOSED = 90.0

#: Written as literals; see the module docstring for each derivation.
ORIGINS = {"U1S_A": (56.43, 62.797), "U1S_B": (33.57, 62.797)}
CONTROL_ANCHORS = {"U1S_A": (56.43, 36.127), "U1S_B": (33.57, 36.127)}
DEFECT_ANCHORS = {"U1S_A": (83.1, 62.797), "U1S_B": (60.24, 62.797)}
LANDS_BOX = (32.72, 8.607, 57.28, 63.647)
DEFECT_DISTANCES = {"U1S_A": 25.82, "U1S_B": 2.96}

#: J5's measured body centre is this far clear of every land it solders to --
#: fab box (-2, -1.4)..(4, 6.3) centres at (1, 2.45), lands box
#: (-0.6, -0.875)..(2.6, 0.875) reaches y 0.875, and 2.45 - 0.875 = 1.575.
J5_OVERHANG_MM = 1.575


def _document(child_rotation_deg: float | None = None) -> dict:
    """The fixture as authored, or with ONLY the expansion's child rotations
    replaced -- which is the whole edit that turns the control into the defect,
    and is applied to the parsed document so no second copy of the board can
    drift from the first."""
    document = yaml.safe_load(FIXTURE.read_text(encoding="utf-8"))
    if child_rotation_deg is not None:
        for placement in _expansion(document)["assembly"]["placements"]:
            placement["rotation_deg"] = child_rotation_deg
    return document


def _expansion(document: dict) -> dict:
    for component in document["components"]:
        if component["ref"] == "U1S":
            return component
    raise AssertionError("the fixture no longer authors the U1S expansion")


def _compiled(child_rotation_deg: float | None = None):
    """Fails LOUDLY rather than skipping: a fixture that stopped compiling
    would silently stop testing anything here."""
    result = compile_board(_document(child_rotation_deg))
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


def _component(board, ref: str):
    for component in board.components:
        if component.ref == ref:
            return component
    raise AssertionError(f"the fixture no longer places {ref}")


def _close(actual, expected, tolerance=1e-9) -> bool:
    return all(abs(a - b) <= tolerance for a, b in zip(actual, expected))


# ---------------------------------------------------------------------------
# The premise. This suite is worth nothing while the fixture stops authoring
# the shape it was built to author.
# ---------------------------------------------------------------------------


def test_the_fixture_authors_a_correct_expansion_one_key_away_from_the_defect():
    """THE PREMISE, GUARDED, on the authored document.

    The control has to be genuinely correct -- an expansion whose anchors are
    already off the copper would refuse for a reason that has nothing to do
    with the child rotation, and the suite would still pass. So: the authored
    board turns neither child, and the only edit the defect half makes is that
    rotation.
    """
    expansion = _expansion(_document())

    assert expansion["x_mm"] == 45.0
    assert expansion["y_mm"] == 62.797
    assert expansion["rotation_deg"] == 180.0
    assert expansion["layer"] == "top"

    placements = expansion["assembly"]["placements"]
    assert [p["ref"] for p in placements] == ["U1S_A", "U1S_B"]
    for placement, offset_x in zip(placements, (-11.43, 11.43)):
        assert placement["offset_mm"] == {"x": offset_x, "y": 0}
        assert placement["anchor_mm"] == {"x": 0, "y": 26.67}
        assert placement["rotation_deg"] == CONTROL_CHILD_ROTATION

    # And the defect edit touches that key and nothing else.
    turned = _expansion(_document(DEFECT_CHILD_ROTATION))
    for placement in turned["assembly"]["placements"]:
        placement["rotation_deg"] = CONTROL_CHILD_ROTATION
    assert turned == expansion


# ---------------------------------------------------------------------------
# The gate.
# ---------------------------------------------------------------------------


def test_a_child_anchor_turned_off_its_own_lands_is_refused_and_the_control_is_not():
    """THE WHOLE CLAIM, both halves, over one board that differs by one key.

    The control emits -- every anchor on its own strip, every other part of the
    board placed. Turn both children a quarter turn and the SAME board is
    refused by name, with the anchor, the box it was tested against and the
    distance all in the message, because a person reading "this anchor is
    wrong" cannot act on it without knowing what it was compared to.

    The composed angles are asserted alongside, so a failure says which of the
    two derivations moved: the transform that resolves the anchor, or the gate
    that judges it.
    """
    control = _compiled()
    turned = _compiled(DEFECT_CHILD_ROTATION)

    # --- the control resolves onto the strips, and emits.
    placements = _placements(control)
    for ref, anchor in CONTROL_ANCHORS.items():
        assert placements[ref].anchor_basis == ANCHOR_BASIS_AUTHORED
        assert placements[ref].rotation_deg == CONTROL_COMPOSED
        assert _close(placements[ref].origin, ORIGINS[ref])
        assert _close(placements[ref].anchor, anchor)
    emission = ao.emit(control, "jlc")
    assert {row.ref for row in emission.cpl} == {"U1S_A", "U1S_B", "SW4", "J5"}
    # A REFUSAL, NOT AN ADVISORY: the code must never appear on the soft channel.
    assert not [item for item in emission.advisories
                if item["code"] == ag.CODE_ANCHOR_OFF_LANDS]

    # --- one key later, the anchors are east of the strips on bare board.
    placements = _placements(turned)
    for ref, anchor in DEFECT_ANCHORS.items():
        assert placements[ref].rotation_deg == DEFECT_COMPOSED
        # The ORIGIN did not move: only the anchor turned about it, which is
        # what makes the defect invisible to every copper-based check.
        assert _close(placements[ref].origin, ORIGINS[ref])
        assert _close(placements[ref].anchor, anchor)

    # --- and the order path refuses it, structurally and in prose.
    with pytest.raises(ag.AssemblyGateError) as raised:
        ao.emit(turned, "jlc")
    error = raised.value
    assert error.code == ag.CODE_ANCHOR_OFF_LANDS
    assert error.component == "U1S"
    assert error.field == "assembly.placements[].anchor_mm"
    assert error.refs == ("U1S_A", "U1S_B")

    message = str(error)
    named = DEFECT_ANCHORS["U1S_A"]
    assert f"({named[0]:.4f}, {named[1]:.4f})" in message
    assert f"{DEFECT_DISTANCES['U1S_A']:.4f} mm outside" in message
    assert (f"({LANDS_BOX[0]:.4f}, {LANDS_BOX[1]:.4f}) to "
            f"({LANDS_BOX[2]:.4f}, {LANDS_BOX[3]:.4f})") in message
    # The sibling is named too: an expansion whose children swung off together
    # must not cost one round trip per child.
    assert "'U1S_B'" in message

    # --- the box really is the lands' EXTENT and not their centres. Measured
    #     off the resolved pads here, independently of the gate's own call.
    box = ra.placed_land_extent(_component(turned, "U1S").placed_pads)
    assert _close((box.min_x, box.min_y, box.max_x, box.max_y), LANDS_BOX)


def test_a_measured_anchor_that_legitimately_overhangs_its_lands_is_left_alone():
    """WHY THE GATE READS ONLY AUTHORED ANCHORS.

    A part's body legitimately overhangs its copper. J5 is a side-entry JST PH:
    its housing sits 1.575 mm clear of the two lands it solders to, so the
    anchor measured off its fab outline -- the correct place for a nozzle to
    pick it up -- is OUTSIDE its own lands box and always will be. A gate that
    judged measured anchors would refuse a perfectly good connector.

    Both facts are asserted together, because either alone can pass while the
    claim is false: that J5's anchor really is off its lands by that distance,
    and that the board emits anyway.
    """
    board = _compiled()
    j5 = _component(board, "J5")
    anchor = _placements(board)["J5"]
    assert anchor.anchor_basis != ANCHOR_BASIS_AUTHORED

    # The overhang is purely northward here -- the housing runs past the tabs
    # in +y and stays within them in x -- so the distance is one subtraction,
    # derived here rather than borrowed from the gate.
    box = ra.placed_land_extent(j5.placed_pads)
    assert box.min_x <= anchor.anchor[0] <= box.max_x
    assert anchor.anchor[1] - box.max_y == pytest.approx(J5_OVERHANG_MM, abs=1e-9)

    assert "J5" in {row.ref for row in ao.emit(board, "jlc").cpl}
