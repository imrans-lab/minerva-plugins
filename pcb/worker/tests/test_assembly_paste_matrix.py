"""THE PASTE MATRIX — what the stencil actually gets, per matrix cell.

The oracle is the EMITTED APERTURES, not a flag on the IR and not the emitter's
own opinion of itself: every assertion below parses ``F_Paste``/``B_Paste`` out
of a production gerber build and compares the flash coordinates to a hand-derived
table. A cell passes only when what the board authored and what the stencil
carries agree.

WHAT THIS CAUGHT WHEN IT WAS WRITTEN. Before it, ``assembly.paste`` was carried
on the IR and read by nobody: ``paste: exclude`` on a do-not-populate part
emitted exactly the same apertures as ``paste: include``. Both DNP cells were
indistinguishable in the one artifact that decides where solder goes.

THE THROUGH-HOLE SEAL (:func:`test_through_hole_part_emits_no_paste`) is a
REGRESSION test for a fact, not a rule: paste participation is read strictly off
each pad's resolved layer list, and the seed library's through-hole footprints
simply do not declare ``*.Paste``. "No paste on through-hole" is therefore a
consequence, not a branch — and a footprint that genuinely wants paste-in-hole
reflow still gets it. The seal exists so that a change which starts inferring
paste from ``pad_type`` fails here instead of arriving on a stencil.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest
import yaml

from pcb_worker import assembly_outputs as ao, gerber
from pcb_worker.compile_board import compile_board
from pcb_worker.resolved_board import DiagnosticSeverity, ResolutionSuccess

FIXTURE = (Path(__file__).resolve().parent / "testdata" / "assembly_boards"
           / "assembly_paste.yaml")

#: One flash: ``X<int>Y<int>D03*`` in the gerber's 1e-6 mm integer units.
_FLASH = re.compile(r"^X(-?\d+)Y(-?\d+)D03\*$")

# HAND-DERIVED EXPECTATIONS, per matrix cell. R_0805's two lands sit at
# x = +/-0.95 mm from the footprint origin, D_SMA's at +/-2.05 mm; the gerber
# plot frame negates Y (gerber.py's _Geometry.to_gerber_frame), so a component
# placed at y = 5 flashes at -5. Both are stated as absolute board coordinates
# rather than computed from the pads, so a change in either the placement
# transform or the frame conversion shows up here as a moved flash rather than
# being re-derived into agreement.
POPULATED_SMD_TOP = {(9.05, -5.0), (10.95, -5.0)}          # R1, paste absent (auto)
DNP_PASTE_INCLUDE_TOP = {(19.05, -5.0), (20.95, -5.0)}     # R2, paste: include
DNP_PASTE_EXCLUDE_TOP: set = set()                         # R3, paste: exclude
THROUGH_HOLE_TOP: set = set()                              # J1, seven TH lands
POPULATED_SMD_BOTTOM = {(12.95, -32.0), (17.05, -32.0)}    # D1, paste absent
DNP_PASTE_EXCLUDE_BOTTOM: set = set()                       # D2, paste: exclude


def _compiled():
    board = yaml.safe_load(FIXTURE.read_text(encoding="utf-8"))
    result = compile_board(board)
    if not isinstance(result, ResolutionSuccess):
        raise AssertionError(
            "paste fixture did not compile: "
            + ", ".join(d.code for d in result.diagnostics
                        if d.severity is DiagnosticSeverity.ERROR))
    return result.board


def _paste_flashes(files, side: str) -> set[tuple[float, float]]:
    """Every flash on one paste layer, in millimetres, as a set."""
    out = set()
    for line in files[f"paste-{side}_Paste.gbr"].splitlines():
        match = _FLASH.match(line)
        if match:
            out.add((int(match.group(1)) / 1e6, int(match.group(2)) / 1e6))
    return out


@pytest.fixture(scope="module")
def emitted():
    return gerber.build_gerbers_ir(_compiled(), name="paste")


@pytest.mark.parametrize("side,expected", [
    ("F", POPULATED_SMD_TOP | DNP_PASTE_INCLUDE_TOP | DNP_PASTE_EXCLUDE_TOP
          | THROUGH_HOLE_TOP),
    ("B", POPULATED_SMD_BOTTOM | DNP_PASTE_EXCLUDE_BOTTOM),
])
def test_paste_matrix_emits_exactly_what_was_authored(emitted, side, expected):
    """The whole matrix in one comparison per side: the emitted stencil is
    EXACTLY the union of the cells that should contribute and nothing else.

    Comparing the whole set rather than each cell in turn is what makes an
    APPEARING aperture a failure as well as a missing one — a suppression that
    leaks a part's lands onto the stencil has to show up somewhere, and an
    equality over the layer is the only assertion that has nowhere for it to
    hide."""
    assert _paste_flashes(emitted, side) == expected


def test_do_not_populate_paste_exclude_removes_only_that_part(emitted):
    """``paste: exclude`` suppresses ITS OWN component and no other. Stated
    separately from the whole-layer equality above because it is the specific
    claim the feature makes: a per-component suppression, not a board-wide
    switch."""
    top = _paste_flashes(emitted, "F")
    assert DNP_PASTE_EXCLUDE_TOP == set(), "R3's cell is the suppressed one"
    assert not (top & {(29.05, -5.0), (30.95, -5.0)}), (
        "R3 is placed at x=30 with paste: exclude — its lands must contribute no "
        "stencil aperture")
    assert DNP_PASTE_INCLUDE_TOP <= top, (
        "R2 is the neighbouring do-not-populate part with paste: include — "
        "suppressing R3 must not touch it")


def test_do_not_populate_parts_keep_their_copper(emitted):
    """A do-not-populate part stays in the GERBERS: its lands are still etched
    whatever its paste policy says. That is what makes it populatable later, and
    it is the half of the DNP contract the CSV exclusion could otherwise be
    mistaken for reversing."""
    copper = emitted["paste-F_Cu.gbr"]
    for x_mm in (19.05, 20.95, 29.05, 30.95):  # R2's and R3's lands
        assert f"X{int(round(x_mm * 1e6))}Y-5000000D03*" in copper, (
            f"land at x={x_mm} mm is missing from F.Cu — a do-not-populate part "
            f"must keep its copper")


def test_through_hole_part_emits_no_paste(emitted):
    """REGRESSION SEAL: the through-hole socket contributes no paste aperture on
    either side.

    J1's seven through-hole lands run down the line x = 10 mm from y = 20 mm at
    2.54 mm pitch. Its footprint declares ``*.Cu`` and ``*.Mask`` on those pads
    and nothing else, so ``pad_source.has_paste`` answers False for both sides —
    and the seven drilled lands ARE present in the copper output, so this is a
    statement about paste specifically and not about the part failing to resolve.

    Scoped to J1's own column rather than a box, because the bottom-side diodes
    share its Y range and only its X."""
    for side in ("F", "B"):
        over_j1 = {(x, y) for (x, y) in _paste_flashes(emitted, side)
                   if abs(x - 10.0) <= 1.5 and -36.0 <= y <= -19.0}
        assert over_j1 == set(), (
            f"{side}.Paste carries {len(over_j1)} aperture(s) over the through-hole "
            f"socket J1: {sorted(over_j1)}")
    assert "X10000000Y-20000000D03*" in emitted["paste-F_Cu.gbr"], (
        "J1's pin-1 land is missing from F.Cu — the no-paste claim above would be "
        "vacuous if the part had not resolved at all")


def test_do_not_populate_parts_leave_both_csvs_and_are_logged():
    """The other half of the DNP contract, on the two files rather than the
    stencil: a not-populated part appears in NEITHER csv and IS named in the
    exclusion log — for every paste policy, since paste decides the stencil and
    populate decides the order."""
    board = _compiled()
    bom = ao.build_bom(board, "jlc")
    cpl = ao.build_cpl(board, "jlc")
    emitted_refs = {ref for row in bom.rows for ref in row.refs}
    assert emitted_refs == {"R1", "J1", "D1"}
    assert {row.ref for row in cpl.rows} == {"R1", "J1", "D1"}
    # Board order, and both paste policies represented among the excluded.
    assert bom.excluded_refs == ("R2", "R3", "D2")
    assert cpl.excluded_refs == bom.excluded_refs
