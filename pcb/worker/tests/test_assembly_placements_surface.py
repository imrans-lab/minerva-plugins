"""WHAT A COMPONENT-READING SURFACE IS TOLD ABOUT PLACEMENT.

``assembly_placements`` is the worker method behind the panel's
``minerva_pcb_get_components`` / ``minerva_pcb_describe_component``: for every
component, the parts an assembly house actually picks up, each with the origin,
body-centre anchor, composed rotation, side and anchor basis a CPL row is
written from.

WHY IT EXISTS. A reader of the board sees ``assembly.placements`` — offsets and
rotations stated in the PARENT component's own local frame. Those ride the
parent's rotation and side before they mean anything on a board, and the anchor
a nozzle centres on is measured off a footprint no board file states. So the
authored numbers cannot answer "where does this part go", and a surface that
composed its own answer would be a second derivation free to disagree with the
file the house reads.

THE ORACLE, in one sentence: every number this surface reports for a placement
is a number the CPL WRITER produced for that same placement, compared here
against the writer's own rows rather than against a literal.

  ``assembly_outputs._walk`` is the row writer, and it is what the comparisons
  below reach for. ``emit`` wraps it with the order GATES and with the
  part-orientation correction — the angle by which OUR drawing of a part is
  turned relative to the vendor's. That correction is a fact about a catalogue
  part, not about where the part sits, and the surface deliberately does not
  carry it: on the socket-set fixture the emitted rotation is 90 where the
  COMPOSED rotation is 180. Anchor and side are untouched by it, so those are
  additionally checked against a full ``emit``, proving the numbers reach the
  file and not merely the walk.

TWO BOARDS, because the socket set is authored two ways in the field:

  ``assembly_child_footprint.yaml`` — the current shape: each child NAMES the
    1x22 strip it is, its anchor is MEASURED off that strip, and the board
    emits.
  ``assembly_surface.yaml`` — smart-remote-v2 rev B as authored today: the
    children carry an authored ``anchor_mm`` and a 270 rotation instead. ITS
    EMISSION REFUSES — ``assembly_gates.check_anchor_on_lands`` puts U1S_A's
    anchor 25.82 mm off the copper it is placed on — which is a defect in that
    BOARD's data, not in this surface, and precisely the class of defect the
    surface exists to make visible: nothing in the authored offsets shows it.
    The walk still writes the rows, so the comparison is unaffected.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from pcb_worker import assembly_outputs as ao
from pcb_worker import board_model, methods
from pcb_worker.compile_board import compile_board
from pcb_worker.resolved_board import ResolutionSuccess

HERE = Path(__file__).resolve().parent
BOARDS = HERE / "testdata" / "assembly_boards"
CHILD_FOOTPRINT = BOARDS / "assembly_child_footprint.yaml"
REV_B_SOCKET_SET = BOARDS / "assembly_surface.yaml"

#: The dialect-only selector: JLCPCB's CSV columns with no manufacturing tier,
#: so a fixture is not refused for the rule profile it was compiled against.
PROFILE = "jlc"

#: Millimetre tolerance. The claim is "the same number", so this is float
#: noise, not agreement to a rounding.
EPS = 1e-9


def surfaced(path: Path) -> dict:
    """The method's per-component placement lists, keyed by component ref."""
    reply = methods._assembly_placements({"yaml": path.read_text()})
    assert reply["ok"], reply
    result = reply["result"]
    assert result["resolved"], result.get("reason")
    return {entry["component"]: entry["physical"] for entry in result["components"]}


def walk_rows(path: Path) -> dict:
    """The CPL rows the writer produces for the same board, keyed by ref."""
    board = board_model.load_board({"yaml": path.read_text()})
    compiled = compile_board(board)
    rows, _ = _walk_cpl(compiled.board)
    return rows


def _walk_cpl(resolved_board):
    profile = ao._resolve_profile(PROFILE)
    _bom, cpl, _excluded, _placed = ao._walk(resolved_board, profile)
    return {row.ref: row for row in cpl}, profile


def compiled_board(path: Path):
    board = board_model.load_board({"yaml": path.read_text()})
    result = compile_board(board)
    assert isinstance(result, ResolutionSuccess), \
        [d.message for d in result.diagnostics]
    return result.board


def test_the_expansion_surfaces_the_numbers_the_cpl_writer_produced():
    """One drawn socket set, two soldered strips — and both physical rows are
    the writer's, number for number.

    Anchor and side are checked twice: against the walk, and against a FULL
    emission, whose rows are the bytes a house reads."""
    physical = {item["ref"]: item for item in surfaced(CHILD_FOOTPRINT)["U1S"]}
    rows = walk_rows(CHILD_FOOTPRINT)
    emitted = {row.ref: row for row in ao.emit(compiled_board(CHILD_FOOTPRINT),
                                               PROFILE).cpl}

    assert set(physical) == {"U1S_A", "U1S_B"}, \
        "one component, two parts — the list length is what says 'synthetic'"
    for ref in ("U1S_A", "U1S_B"):
        item, row = physical[ref], rows[ref]
        x_mm, y_mm = ao.cpl_frame_point(
            (item["anchor"]["x_mm"], item["anchor"]["y_mm"]))
        assert x_mm == pytest.approx(row.x_mm, abs=EPS)
        assert y_mm == pytest.approx(row.y_mm, abs=EPS)
        assert item["rotation_deg"] == pytest.approx(row.rotation_deg, abs=EPS)
        assert item["side"] == row.side
        # Through the gates and the orientation pass, the coordinate and the
        # side are still these ones.
        assert x_mm == pytest.approx(emitted[ref].x_mm, abs=EPS)
        assert y_mm == pytest.approx(emitted[ref].y_mm, abs=EPS)
        assert item["side"] == emitted[ref].side
        # The part is described by the drawing the PLACEMENT named, not by the
        # two-row parent that draws the copper.
        assert item["footprint"] == emitted[ref].footprint_ref


def test_rev_b_socket_set_as_authored_surfaces_the_writers_numbers():
    """The same claim on the board as smart-remote-v2 rev B authors it today —
    an authored ``anchor_mm`` and a turned child instead of a named drawing.

    Only the walk is compared: this board's emission refuses (see the module
    docstring), which is a fact about the board's data and leaves the rows the
    writer produces from it untouched."""
    physical = {item["ref"]: item for item in surfaced(REV_B_SOCKET_SET)["U1S"]}
    rows = walk_rows(REV_B_SOCKET_SET)

    assert set(physical) == {"U1S_A", "U1S_B"}
    for ref in ("U1S_A", "U1S_B"):
        item, row = physical[ref], rows[ref]
        x_mm, y_mm = ao.cpl_frame_point(
            (item["anchor"]["x_mm"], item["anchor"]["y_mm"]))
        assert x_mm == pytest.approx(row.x_mm, abs=EPS)
        assert y_mm == pytest.approx(row.y_mm, abs=EPS)
        assert item["rotation_deg"] == pytest.approx(row.rotation_deg, abs=EPS)
        assert item["side"] == row.side
        assert item["anchor_basis"] == "authored", \
            "a figure a person wrote down is never reported as measured"


def test_every_component_places_at_least_one_part_under_a_named_ref():
    """The reason a reader never has to branch on "is this synthetic": the list
    is present on every component, and for an ordinary part it holds exactly
    one entry, under that component's own ref, at the anchor the compiler
    resolved for it."""
    board = compiled_board(REV_B_SOCKET_SET)
    anchors = {component.ref: component.physical_placements
               for component in board.components}
    physical = surfaced(REV_B_SOCKET_SET)

    assert set(physical) == set(anchors), "every compiled component is listed"
    for ref, items in physical.items():
        assert items, "a component that places nothing is not a thing"
        assert len(items) == len(anchors[ref])

    ordinary = physical["C1"]
    assert len(ordinary) == 1
    assert ordinary[0]["ref"] == "C1", "an ordinary part IS its own placement"
    resolved = anchors["C1"][0].anchor
    assert ordinary[0]["anchor"]["x_mm"] == pytest.approx(resolved[0], abs=EPS)
    assert ordinary[0]["anchor"]["y_mm"] == pytest.approx(resolved[1], abs=EPS)


def test_a_board_that_does_not_compile_is_reported_not_refused():
    """A mid-layout board must be able to ask and be told why the answer is
    unavailable. An empty placement list would read as "this component places
    nothing", which is the one thing it must never be mistaken for."""
    reply = methods._assembly_placements({"board": {
        "version": 1, "name": "Uncompilable",
        "width_mm": 20, "height_mm": 20,
        "layers": ["top", "bottom"],
        # Rules are stated so the compile gets past its schema gates and fails
        # on the one thing this test is about: the drawing it cannot find.
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.25,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [{"ref": "X1", "footprint": "NoSuchLibrary:NoSuchPart",
                        "x_mm": 5, "y_mm": 5, "rotation_deg": 0,
                        "layer": "top", "pins": []}],
    }})

    assert reply["ok"], "the method ran; the board is what could not be compiled"
    result = reply["result"]
    assert result["resolved"] is False
    assert result["components"] == []
    assert "NoSuchLibrary:NoSuchPart" in result["reason"], \
        "the reason must name what blocked the compile"
