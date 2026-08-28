"""Legend that will be unreadable once the parts are on (drc_silk_placement).

AUTHORED, NOT EXECUTED in this cycle: task-cycle 9 authors tests and runs them
in one scoped run afterwards.

THE ORACLE THIS FILE IS BUILT ON is not "the checker fires" — a checker can
fire on the wrong pair, or fire on the footprint convention every board on
earth follows, and still look healthy in a count assertion. It is: TAKE THE
SUGGESTION AND THE BOARD GOES QUIET. Every row here carries an anchor the
checker claims is clear; ``test_the_suggested_anchor_clears_the_board`` writes
that anchor onto the footprint and re-runs the whole projection, so a
suggestion computed from a rule the checker does not actually apply fails
loudly rather than reading as advice.

THE BOARDS ARE SYNTHETIC AND SELF-CONTAINED (testdata/POLICY.md): every
component carries its own ``pads`` + ``graphics``, so ``inline_footprint``
builds the definitions and no library is consulted. The four shapes are chosen
so each case isolates one rule:

  BOX    a 4x4 body inside a 5x5 courtyard, with a drawn silk outline — the
         part whose OWN outline sits inside its OWN courtyard, which must never
         be a finding.
  SLAB   a wide keep-out with NO silk of its own — a neighbour that can hide
         another part's designator without contributing legend of its own, so
         the under-part case cannot be confused with the over-silk one.
  PLATE  a 16x16 keep-out — a part hemmed in on all eight compass slots.
  CHIP   a body so small that two neighbours' designators overlap while their
         courtyards do not — the over-silk case with the under-part rule
         provably silent.

FAILS AGAINST OLD: every test here fails with an ImportError before
drc_silk_placement exists.
"""

from __future__ import annotations

import copy
import dataclasses

from pcb_worker import drc_silk_placement
from pcb_worker.compile_board import compile_board
from pcb_worker.drc_geometric import project_board, run_geometric_drc
from pcb_worker.footprint_def import ReferenceTextDefinition
from pcb_worker.resolved_board import ResolutionSuccess

UNDER = drc_silk_placement.SILK_UNDER_PART
OVER = drc_silk_placement.SILK_OVER_SILK


# ---------------------------------------------------------------------------
# The synthetic parts and boards
# ---------------------------------------------------------------------------


def _rect(layer: str, x0: float, y0: float, x1: float, y1: float,
          width: float = 0.15) -> list[dict]:
    corners = [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
    return [{"layer": layer, "kind": "line", "width": width,
             "start": list(corners[i]), "end": list(corners[(i + 1) % 4])}
            for i in range(4)]


def _pad(number: str, x: float, y: float, w: float = 1.0, h: float = 1.0) -> dict:
    return {"number": number, "type": "smd", "shape": "rect",
            "position": {"x": x, "y": y},
            "size": {"width": w, "height": h}, "layers": ["F.Cu"]}


#: 4x4 body, 5x5 courtyard, two lands. Occupied extent -2.5..2.5 on both axes,
#: so its derived designator baseline is 2.825 mm above the part origin.
BOX = {"pads": [_pad("1", -1.5, 0.0), _pad("2", 1.5, 0.0)],
       "graphics": _rect("F.CrtYd", -2.5, -2.5, 2.5, 2.5, 0.05)
                   + _rect("F.SilkS", -2.0, -2.0, 2.0, 2.0)}
#: 12x3 keep-out, NO silk of its own.
SLAB = {"pads": [_pad("1", -4.5, 0.0), _pad("2", 4.5, 0.0)],
        "graphics": _rect("F.CrtYd", -6.0, -1.5, 6.0, 1.5, 0.05)}
#: 16x16 keep-out, NO silk of its own — big enough to swallow every slot.
PLATE = {"pads": [_pad("1", -7.0, 0.0), _pad("2", 7.0, 0.0)],
         "graphics": _rect("F.CrtYd", -8.0, -8.0, 8.0, 8.0, 0.05)}
#: 1.8x1.2 keep-out, NO silk of its own — smaller than its own designator.
CHIP = {"pads": [_pad("1", -0.5, 0.0, 0.6, 0.6), _pad("2", 0.5, 0.0, 0.6, 0.6)],
        "graphics": _rect("F.CrtYd", -0.9, -0.6, 0.9, 0.6, 0.05)}


def _comp(ref: str, footprint: str, geometry: dict, x: float, y: float) -> dict:
    """One component carrying its own geometry — the FULL arm of
    ``inline_footprint``'s rule, which is what makes these boards library-free."""
    out = {"ref": ref, "footprint": footprint, "x_mm": x, "y_mm": y,
           "rotation_deg": 0, "layer": "top",
           "pins": [{"number": pad["number"],
                     "x_mm": pad["position"]["x"], "y_mm": pad["position"]["y"]}
                    for pad in geometry["pads"]]}
    out.update(copy.deepcopy(geometry))
    return out


def _compiled(components: list[dict]):
    board = {"version": 2, "id": "board:" + "0" * 32, "name": "silk-placement",
             "width_mm": 60, "height_mm": 60, "grid_mm": 1.0,
             "layers": ["top", "bottom"],
             "design_rules": {"clearance_mm": 0.15, "trace_width_mm": 0.25,
                              "via_diameter_mm": 0.6, "via_drill_mm": 0.3,
                              "rule_profile": "jlcpcb-2layer"},
             "components": components, "nets": []}
    result = compile_board(board)
    assert isinstance(result, ResolutionSuccess), \
        [(d.code, d.message) for d in result.diagnostics]
    return result.board


def _rows(components: list[dict]) -> tuple:
    rb = _compiled(components)
    return rb, drc_silk_placement.check(project_board(rb), rb)


def _of_type(rows, row_type):
    return [r for r in rows if r["type"] == row_type]


def _with_anchor(rb, ref: str, anchor: dict):
    """The same board with ONE component's footprint re-authored to print its
    reference at *anchor* — how a suggestion is "applied" without inventing a
    board-level field for it (the designator anchor is a footprint fact today;
    see ``refdes_anchor.effective_reference_text``). The definition's content id
    moves with its content, so the component is re-pointed at the new one."""
    comp = next(c for c in rb.components if c.ref == ref)
    old = rb.footprint_for(comp)
    new = dataclasses.replace(old, reference_text=ReferenceTextDefinition(
        position=(anchor["x_mm"], anchor["y_mm"]),
        rotation_deg=anchor["rotation_deg"], size_mm=anchor["size_mm"],
        hidden=anchor["hidden"]))
    kept = tuple(d for d in rb.footprint_definitions if d.content_id != old.content_id)
    comps = tuple(dataclasses.replace(c, footprint_id=new.content_id)
                  if c.ref == ref else c for c in rb.components)
    return dataclasses.replace(rb, footprint_definitions=kept + (new,),
                               components=comps)


#: R1's designator lands squarely inside U1's keep-out; R9 sits alone in the
#: corner with nothing near it. U1 draws no silk, so nothing here can produce an
#: over-silk row and the under-part count is unambiguous.
BURIED = [_comp("R1", "T:BOX", BOX, 10, 10),
          _comp("U1", "T:SLAB", SLAB, 10, 6),
          _comp("R9", "T:BOX", BOX, 40, 40)]


# ---------------------------------------------------------------------------
# Under a part
# ---------------------------------------------------------------------------


def test_a_buried_designator_is_one_row_naming_the_right_pair():
    """ORACLE: the ONE part whose designator is geometrically inside the ONE
    neighbour's keep-out is the only pair reported — the clear part in the same
    board is the control, and a rule that fired on "any two parts" or on a
    part's own artwork would name it too."""
    _, rows = _rows(BURIED)
    under = _of_type(rows, UNDER)
    assert len(under) == 1, [(r["ref"], r["offender_ref"], r["origin"]) for r in under]
    row = under[0]
    assert (row["ref"], row["offender_ref"]) == ("R1", "U1")
    assert row["origin"] == "refdes"
    assert row["offender_kind"] == "courtyard"
    assert row["side"] == "top"
    assert row["layer"] == "F.SilkS"
    # Real millimetres of legend lost, not a flag: the designator is ~1.15 mm
    # tall and its strokes total several mm inside the slab.
    assert row["measured_mm"] > 1.0
    assert row["required_mm"] == 0.0
    # R9 is named nowhere, and nothing crosses anything.
    assert "R9" not in {r["ref"] for r in rows}
    assert _of_type(rows, OVER) == []


def test_the_suggested_anchor_clears_the_board():
    """THE LOAD-BEARING ORACLE. The suggestion is written onto the footprint's
    reference text and the WHOLE projection is re-run — so it is checked against
    the same rules that produced the finding rather than against the arithmetic
    that produced it. A suggestion that merely moved the text somewhere else
    fails here."""
    rb, rows = _rows([_comp("R1", "T:BOX", BOX, 10, 10),
                      _comp("U1", "T:SLAB", SLAB, 10, 6)])
    suggestion = _of_type(rows, UNDER)[0]["suggestion"]
    assert suggestion["hidden"] is False
    assert suggestion["slot"] in drc_silk_placement.SLOT_ORDER

    moved = _with_anchor(rb, "R1", suggestion)
    assert drc_silk_placement.check(project_board(moved), moved) == []


def test_a_part_hemmed_in_on_every_side_is_told_to_hide_its_designator():
    """ORACLE: a designator with nowhere to go must say so rather than hand back
    a slot that is just as buried. The plate covers all eight compass slots at
    the derived offset, so every candidate collides and the only honest answer
    is `hidden`."""
    _, rows = _rows([_comp("R1", "T:BOX", BOX, 30, 30),
                     _comp("U2", "T:PLATE", PLATE, 30, 30)])
    designator = [r for r in _of_type(rows, UNDER) if r["origin"] == "refdes"]
    assert len(designator) == 1
    suggestion = designator[0]["suggestion"]
    assert suggestion["hidden"] is True
    assert suggestion["slot"] is None
    assert "hide" in designator[0]["note"]


def test_a_footprints_own_outline_inside_its_own_courtyard_is_never_a_finding():
    """ORACLE: THE FOOTPRINT CONVENTION. A courtyard is drawn around the outline
    by definition, so a rule that measured a part's own silk against its own
    keep-out would fire on every part of every board ever authored. One part,
    alone, drawing exactly that — nothing is reported."""
    _, rows = _rows([_comp("R1", "T:BOX", BOX, 30, 30)])
    assert rows == []


# ---------------------------------------------------------------------------
# Over other legend
# ---------------------------------------------------------------------------


def test_two_designators_laid_across_each_other_are_one_row():
    """ORACLE: one blot is one finding. Both designators walk the pairing loop
    (each is a refdes), so an unordered pair reported from both ends would count
    two. The chips' keep-outs do NOT overlap and their designators sit clear
    above both, which is what makes this the over-silk case alone."""
    _, rows = _rows([_comp("R11", "T:CHIP", CHIP, 20, 20),
                     _comp("R12", "T:CHIP", CHIP, 22, 20)])
    assert _of_type(rows, UNDER) == []
    over = _of_type(rows, OVER)
    assert len(over) == 1, [(r["ref"], r["offender_ref"]) for r in over]
    row = over[0]
    assert {row["ref"], row["offender_ref"]} == {"R11", "R12"}
    assert row["offender_kind"] == "refdes"
    assert row["measured_mm"] >= drc_silk_placement.SAMPLE_STEP_MM
    assert row["suggestion"]["hidden"] is False


# ---------------------------------------------------------------------------
# Where the rows land in the DRC envelope
# ---------------------------------------------------------------------------


def test_the_placement_rows_are_advisory_and_never_move_the_verdict():
    """ORACLE: the shipped severity rule for legend. Silk is cosmetic, so these
    rows ride the `advisories` key and are counted, and the board that carries
    them still reads `clean` — a row that reached `findings` would flip every
    real board to `violations` over ink."""
    rb = _compiled(BURIED)
    result = run_geometric_drc(rb)
    assert result["ok"] is True
    assert result["verdict"] == "clean"
    assert [f for f in result["findings"]
            if f["type"] in drc_silk_placement.ADVISORY_TYPES] == []
    assert result["counts"][UNDER] == 1
    assert result["counts"][OVER] == 0
    assert [a["type"] for a in result["advisories"] if a["type"] == UNDER] == [UNDER]
    # Both keys are ZERO-INITIALISED, which is what lets a consumer tell "ran
    # and found nothing" from "never ran" (see drc_geometric._COUNT_KEYS).
    clean = run_geometric_drc(_compiled([_comp("R1", "T:BOX", BOX, 30, 30)]))
    assert clean["counts"][UNDER] == 0 and clean["counts"][OVER] == 0
