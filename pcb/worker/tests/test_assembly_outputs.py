"""Tests for pcb_worker.assembly_outputs — BOM + CPL assembly-package
emitters, now derived from ONE strict compilation of the board.

EXECUTABLE SEALS (never parked — these are the load-bearing proofs the epoch
regime requires for this unit):
  * test_cpl_rows_match_hand_derived_values — every CPL row for the synthetic
    fixture, HAND-DERIVED by inspection of assembly_resolved.yaml (a fabricated
    or library-sourced expectation here would defeat the point of the seal).
  * test_cpl_csv_bytes_are_unchanged_by_the_compiled_cutover — the SAME bytes
    the raw-dict emitter produced before the cutover, character for character.
    This is the oracle for "the plumbing swap changed nothing it should not":
    the emitter now reads Placement.position/rotation_deg/side instead of
    comp["x_mm"]/["y_mm"]/["rotation_deg"]/["layer"], and every emitted number
    has to survive that unchanged.
  * test_rows_match_the_raw_dict_arithmetic_they_replaced — the same oracle
    stated independently of any hardcoded string: the expectation is computed
    in-test straight from the fixture's own YAML, so it cannot drift with the
    emitter.

BOTH CUTOVER SEALS SURVIVED THE ASSEMBLY-ANCHOR UNIT, and that is a finding
rather than an accident. Rows now carry the resolved body-centre ANCHOR instead
of the placement position, which moved the emitted coordinate of every part
whose footprint origin is not its body centre — but every footprint this fixture
places (R_0805, D_SMA, and two excluded pieces of furniture) is already centred
on its own origin, so its anchors compose back onto its positions exactly. That
makes this file the "nothing moved that should not have" half of that unit's
oracle; the half where things DO move is test_assembly_anchor.py.
  * test_bom_groups_by_the_emitted_columns — BOM grouping seal. Both resistors
    sit on the same unlabelled drawing, so this seal measures grouping rather
    than a labelling asymmetry; the asymmetry gets its own board and its own
    test (test_bom_asymmetric_labelling_splits_the_row).
  * test_*_identity_refusal* — the part-identity contract.
  * test_*_house_refusal* — the per-house capability refusal.
  * test_uncompilable_board_* — the deliberate capability regression, named.

TWO FIXTURES, and the difference matters. assembly_resolved.yaml COMPILES and
is what the emitters are measured on. assembly_fixture.yaml does NOT compile —
its pins are offset from its library pads and one of its footprints is in no
library — and it is retained precisely because the raw-dict emitter used to
produce a clean BOM and CPL for it anyway. It is now the refusal fixture.

See test_assembly_spec.py for the authored-block reader (exclusion forms,
identity precedence, paste, placements) and test_methods.py for the
RPC-dispatch-level coverage of the same path.
"""

from __future__ import annotations

from pathlib import Path

import pytest
import yaml

from pcb_worker import assembly_outputs as ao
from pcb_worker.compile_board import compile_board
from pcb_worker.footprints import load_lockfile
from pcb_worker.resolved_board import DiagnosticSeverity, ResolutionSuccess
# The shared corpus orientation statement, autouse in this module: these
# boards are drawn on this repository's own land patterns, and orientation
# is measured by test_assembly_orientation.py, not here.
from tests.orientation_corpus import corpus_orientation  # noqa: F401

BOARDS = Path(__file__).resolve().parent / "testdata" / "assembly_boards"
FIXTURE = BOARDS / "assembly_resolved.yaml"


UNCOMPILABLE_FIXTURE = BOARDS / "assembly_fixture.yaml"

#: A seed-library drawing whose lock entry states a package label, and the
#: label itself, read off the lock rather than retyped so the test measures
#: "the column prints what the lock says" and not a string two files agree on.
LABELLED_FOOTPRINT = "EVP-ASAC1A:SW_EVP-ASAC1A"


def _lock_label(footprint: str):
    entry = load_lockfile().get(footprint) or {}
    block = entry.get("assembly") or {}
    return block.get("package")

#: THE ONE PLACE these bytes are written down. Every other test that needs the
#: CPL of ``assembly_resolved.yaml`` imports this rather than re-typing it, so
#: an intended format change is edited once and an unintended one cannot be
#: half-updated into agreement. Sealed by
#: :func:`test_cpl_csv_bytes_are_unchanged_by_the_compiled_cutover`.
RESOLVED_FIXTURE_CPL = (
    "Designator,Mid X,Mid Y,Layer,Rotation\r\n"
    "D1,12.5000,-14.0000,Bottom,45.0000\r\n"
    "R1,10.0000,-5.0000,Top,0.0000\r\n"
    "R2,15.0000,-5.0000,Top,90.0000\r\n"
)


def _load(path: Path = FIXTURE) -> dict:
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def _compiled(board: dict):
    """The board the emitters actually read. Fails LOUDLY rather than skipping:
    a fixture that stopped compiling would otherwise silently stop testing the
    emitters at all."""
    result = compile_board(board)
    if not isinstance(result, ResolutionSuccess):
        raise AssertionError(
            "fixture did not compile: "
            + ", ".join(d.code for d in result.diagnostics
                        if d.severity is DiagnosticSeverity.ERROR))
    return result.board


def _compile_errors(board: dict) -> list[str]:
    """The ERROR diagnostic codes a board compiles to, for the cases the
    emitters no longer adjudicate because the compiler does."""
    result = compile_board(board)
    assert not isinstance(result, ResolutionSuccess), "expected the board to refuse"
    return [d.code for d in result.diagnostics
            if d.severity is DiagnosticSeverity.ERROR]


def _minimal(**component) -> dict:
    """A one-component board that compiles, for the block-level cases that do
    not need the whole fixture. R_0805 is a seed-library footprint and the
    component declares no pins, so the library owns the pads."""
    comp = {"ref": "R1", "footprint": "R_0805", "value": "10k",
            "x_mm": 5.0, "y_mm": 5.0, "rotation_deg": 0, "layer": "top"}
    comp.update(component)
    return {
        "version": 1, "name": "minimal", "width_mm": 20, "height_mm": 20,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.25,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [comp],
    }


# ---------------------------------------------------------------------------
# CPL — hand-derived rows (rotation-convention + side seal)
# ---------------------------------------------------------------------------


def test_cpl_rows_match_hand_derived_values():
    """assembly_resolved.yaml, by inspection, THEN through the MEASURED
    coordinate frame (docs/assembly-outputs.md: X verbatim, Y NEGATED —
    proven against a real ``kicad-cli 9.0.9 pcb export pos`` run). The emitted coordinate is the resolved body-centre ANCHOR, which
    for R_0805 and D_SMA composes back onto the authored position because both
    footprints are already centred on their own origin (measured:
    test_assembly_anchor.py):
      R1: x_mm=10.0 y_mm=5.0  rotation_deg=0  layer=top    -> (10.0, -5.0, 0.0, top)
      R2: x_mm=15.0 y_mm=5.0  rotation_deg=90 layer=top    -> (15.0, -5.0, 90.0, top)
      D1: x_mm=12.5 y_mm=14.0 rotation_deg=45 layer=bottom -> (12.5, -14.0, 45.0, bottom)
    Rotation is emitted VERBATIM — no sign flip, no trigonometry — so rotation
    stays exact arithmetic identity with the authored YAML; only Y changes sign.
    D1's X is UNMIRRORED despite being bottom-side (kicad-cli's default).
    FID1/TXT1 are board furniture and contribute no row.
    Rows sort by ref: D1, R1, R2.
    """
    result = ao.build_cpl(_compiled(_load()), "jlc")
    rows = {row.ref: row for row in result.rows}

    assert [row.ref for row in result.rows] == ["D1", "R1", "R2"]

    assert rows["R1"].x_mm == 10.0
    assert rows["R1"].y_mm == -5.0
    assert rows["R1"].rotation_deg == 0.0
    assert rows["R1"].side == "top"

    assert rows["R2"].x_mm == 15.0
    assert rows["R2"].y_mm == -5.0
    assert rows["R2"].rotation_deg == 90.0
    assert rows["R2"].side == "top"

    assert rows["D1"].x_mm == 12.5
    assert rows["D1"].y_mm == -14.0
    assert rows["D1"].rotation_deg == 45.0
    assert rows["D1"].side == "bottom"


def test_cpl_csv_bytes_are_unchanged_by_the_compiled_cutover():
    """THE CUTOVER ORACLE. This exact string is what the raw-dict emitter
    produced for the same three placements before BOM/CPL moved onto the
    compiled IR — header, ref order, CRLF endings, 4-decimal fixed point,
    Top/Bottom capitalisation, negated Y and verbatim rotation, all identical.
    A coordinate or rotation that moved during the plumbing swap breaks here
    and nowhere subtler.

    It survived the assembly-anchor unit unchanged, which is the point: those
    bytes are now the anchor's, and they are the same bytes, because this
    fixture's footprints are centred on their origins."""
    result = ao.build_cpl(_compiled(_load()), "jlc", name="afix")
    assert list(result.keys()) == ["afix-cpl-jlc.csv"]
    assert result["afix-cpl-jlc.csv"] == RESOLVED_FIXTURE_CPL


def test_rows_match_the_raw_dict_arithmetic_they_replaced():
    """The same oracle as above, stated so it cannot go stale with a fixture
    edit: the expectation is derived HERE, in the test, from the fixture's own
    authored dict using the arithmetic the retired raw-dict path used (x
    verbatim, y negated, rotation modulo 360, layer as side). Every populated
    component must match. The BOM arm derives its two columns from the
    documented column table rather than from the retired path's footprint
    string, because the Footprint column now prefers an authored `package`.

    This is what makes "the plumbing swap changed nothing it should not" a
    measured claim rather than a hardcoded one — it holds for whatever the
    fixture says, not only for the three rows spelled out above.

    IT IS ALSO A CONDITIONAL CLAIM NOW, and the condition is worth stating: the
    emitted coordinate is the body-centre anchor, and it equals the authored
    x_mm/y_mm only for a footprint whose origin IS its body centre. That is true
    of every footprint this fixture places and false of, for example, any
    PinSocket. A future edit that gives this fixture a pin-1-origin footprint
    must expect the anchor, not the position — see test_assembly_anchor.py."""
    board = _load()
    authored = {c["ref"]: c for c in board["components"]}
    compiled = _compiled(board)

    for row in ao.build_cpl(compiled, "jlc").rows:
        comp = authored[row.ref]
        assert row.x_mm == float(comp["x_mm"])
        assert row.y_mm == -float(comp["y_mm"])
        assert row.rotation_deg == float(comp.get("rotation_deg") or 0.0) % 360.0
        assert row.side == (comp.get("layer") or "top")

    for bom_row in ao.build_bom(compiled, "jlc").rows:
        for ref in bom_row.refs:
            comp = authored[ref]
            # The Footprint column is the drawing's lock label, else the
            # drawing ref. `comment` is authored nowhere here, so the Comment
            # column is the component's own value.
            assert bom_row.footprint == (_lock_label(comp["footprint"]) or comp["footprint"])
            assert bom_row.comment == comp.get("value", "")


def test_cpl_rotation_normalizes_negative_and_over_360():
    board = _load()
    board["components"][0]["rotation_deg"] = -90  # R1: -90 == 270
    board["components"][1]["rotation_deg"] = 450  # R2: 450 == 90
    rows = {r.ref: r for r in ao.build_cpl(_compiled(board), "jlc").rows}
    assert rows["R1"].rotation_deg == 270.0
    assert rows["R2"].rotation_deg == 90.0


def test_cpl_absent_layer_still_defaults_to_top():
    """The compiler's own ``raw_layer is None -> Side.TOP`` branch, read back
    off the placement the emitter now uses."""
    board = _load()
    del board["components"][0]["layer"]
    rows = {r.ref: r for r in ao.build_cpl(_compiled(board), "jlc").rows}
    assert rows["R1"].side == "top"


@pytest.mark.parametrize("layer", ["in1.cu", ""])
def test_unusable_layer_never_reaches_the_emitter(layer):
    """A layer token that is neither top nor bottom — including the
    present-but-EMPTY string, which must not silently default to top — used to
    be adjudicated twice, once by the compiler and once by this module's own
    copy of the rule. There is now one adjudicator: the board refuses to
    compile, so no CSV exists to be wrong."""
    board = _load()
    board["components"][0]["layer"] = layer
    assert "invalid_component" in _compile_errors(board)


# ---------------------------------------------------------------------------
# BOM — grouping seal
# ---------------------------------------------------------------------------


def test_bom_groups_by_the_emitted_columns():
    """R1 + R2 print identically ("R_0805", "10k", C25804) -> ONE grouped row
    with both refs and qty=2 — even though R1 names its part number as a
    ``house_parts`` entry and R2 as a bare ``mpn``. That is the point of
    grouping on the RESOLVED columns: what a house reads is one line, so the
    file carries one line. Neither drawing carries a lock label, so the
    Footprint cell is the drawing ref; D1 (Diode_SMD:D_SMA, 1N4148, C2128) is
    its own row, qty=1."""
    result = ao.build_bom(_compiled(_load()), "jlc")
    assert len(result.rows) == 2

    by_footprint = {row.footprint: row for row in result.rows}
    r0805 = by_footprint["R_0805"]
    assert r0805.refs == ("R1", "R2")
    assert r0805.comment == "10k"
    assert r0805.part_number == "C25804"
    assert r0805.qty == 2

    diode = by_footprint["Diode_SMD:D_SMA"]
    assert diode.refs == ("D1",)
    assert diode.comment == "1N4148"
    assert diode.part_number == "C2128"
    assert diode.qty == 1


# ---------------------------------------------------------------------------
# BOM columns — the schema's own fields reach the file
# ---------------------------------------------------------------------------


def test_each_authored_assembly_field_reaches_its_own_bom_column():
    """The schema (docs/board-yaml.md) gives ``comment`` and ``house_parts`` a
    BOM column each, and the Footprint column reads the DRAWING's lock label.
    A component authoring both fields on a labelled drawing must print all
    three — not its ``value``, its footprint ref and its ``mpn``, which are
    what those columns fall back to. Ordering the wrong part is the failure
    this whole path exists to prevent, so the assertion is on the rendered
    LINE, not only on the row object. The label is read off the lock, and the
    test refuses to run against a lock that stopped labelling the drawing:
    the fallback would then satisfy a weaker claim."""
    label = _lock_label(LABELLED_FOOTPRINT)
    assert label and label != LABELLED_FOOTPRINT, "the seed lock no longer labels the drawing"
    board = _compiled(_minimal(value="switch", footprint=LABELLED_FOOTPRINT, assembly={
        "mpn": "EVP-ASAC1A",
        "comment": "SW TACT 6x6",
        "house_parts": {"jlcpcb": "C4365033"},
    }))
    result = ao.build_bom(board, "jlc")
    row = result.rows[0]
    assert row.comment == "SW TACT 6x6"          # not "switch"
    assert row.footprint == label                # not the drawing ref
    assert row.part_number == "C4365033"         # not the mpn
    assert next(iter(result.values())).splitlines()[1] == \
        f"SW TACT 6x6,R1,{label},C4365033"


def test_absent_assembly_fields_fall_back_to_their_pre_block_sources():
    """The other half of the column contract: exactly one fallback per column,
    and it is the shape boards used before the block existed."""
    board = _compiled(_minimal(value="10k", footprint="R_0805",
                               assembly={"mpn": "C25804"}))
    row = ao.build_bom(board, "jlc").rows[0]
    assert row.comment == "10k"                 # the component's value
    assert row.footprint == "R_0805"            # the authored footprint ref
    assert row.part_number == "C25804"          # the mpn


def test_a_present_but_empty_column_is_emitted_blank_not_filled_from_its_fallback():
    """FALLBACK IS KEYED ON ABSENCE, NOT ON TRUTH. A column falls back only
    when the resolved field is ``None``; a field that is PRESENT AND EMPTY is a
    blank cell the author asked for, and an ``or`` fallback cannot tell the two
    apart — it prints the fallback into a column that was deliberately blanked.

    Measured at the emitter's own boundary on a real compiled IR, because the
    compile-time identity fold ahead of it maps an authored blank onto absent
    (see the test below) and would otherwise hide which rule this pins. The
    oracle is the rendered LINE: an empty Comment cell, not "10k"."""
    import dataclasses

    board = _compiled(_minimal(value="10k", footprint="R_0805", assembly={
        "mpn": "RC0805FR-0710KL", "house_parts": {"jlcpcb": "C84376"}}))
    component = board.components[0]
    board = dataclasses.replace(board, components=(dataclasses.replace(
        component, assembly=dataclasses.replace(component.assembly, comment="")),))

    result = ao.build_bom(board, "jlc")
    assert result.rows[0].comment == ""
    assert next(iter(result.values())).splitlines()[1] == ",R1,R_0805,C84376"


def test_an_authored_blank_is_folded_to_absent_before_the_emitter_sees_it():
    """WHERE A YAML-LEVEL BLANK ACTUALLY GOES, stated so the emitter rule above
    is not mistaken for an end-to-end promise. assembly_spec reads a blank
    identity value as absent, so ``comment: ""`` reaches the IR as ``None`` and
    the column falls back. The oracle is the rendered line."""
    board = _compiled(_minimal(value="10k", footprint="R_0805", assembly={
        "comment": "", "mpn": "M1"}))
    resolved = board.components[0].assembly
    assert resolved.comment is None

    result = ao.build_bom(board, "jlc")
    assert next(iter(result.values())).splitlines()[1] == "10k,R1,R_0805,M1"


def test_the_house_part_number_is_chosen_by_the_profile():
    """A board may carry several houses' catalogue numbers. Which one is
    ordered against is the SELECTED profile's, read under its own
    ``house_part_id`` — never the first entry, and never a house the caller did
    not ask for."""
    board = _compiled(_minimal(assembly={
        "mpn": "RC0805FR-0710KL",
        "house_parts": {"jlcpcb": "C84376", "aaa-house": "AAA-000"},
    }))
    assert ao.PROFILES["jlc"].house_part_id == "jlcpcb"
    assert ao.build_bom(board, "jlc").rows[0].part_number == "C84376"


def test_a_house_number_for_another_house_only_is_not_used():
    """A number authored for a DIFFERENT house must not be ordered against;
    the column falls back to the mpn, which at least names the real part."""
    board = _compiled(_minimal(assembly={
        "mpn": "RC0805FR-0710KL", "house_parts": {"aaa-house": "AAA-000"},
    }))
    assert ao.build_bom(board, "jlc").rows[0].part_number == "RC0805FR-0710KL"


def test_two_parts_differing_only_in_comment_are_separate_rows():
    """The grouping key is the emitted identity, so a difference the file DOES
    carry splits the row — otherwise one line would claim one description for
    two parts a purchaser was told apart."""
    board = _load()
    board["components"][0]["assembly"]["comment"] = "RES 10k 1% 0805"
    result = ao.build_bom(_compiled(board), "jlc")
    assert {row.refs for row in result.rows} == {("R1",), ("R2",), ("D1",)}


def test_bom_csv_hand_derived_bytes():
    """assembly_resolved.yaml, by inspection, through the column table in
    assembly_outputs' docstring — Comment = ``assembly.comment`` else ``value``,
    Footprint = the drawing's lock label else the drawing ref, LCSC = the
    jlcpcb ``house_parts`` entry else ``mpn``:

      R1 -> ("10k", R_0805's cell, "C25804")   house number from the block
      R2 -> ("10k", R_0805's cell, "C25804")   mpn from the block
      D1 -> ("1N4148", D_SMA's cell, "C2128")  no house entry

    Neither seed drawing carries a lock label, so each cell is the ref itself
    — read off the lock here rather than retyped, so a label added to the seed
    later moves this expectation with it. R1 and R2 agree on all four
    grouping-key fields (those three plus mpn "C25804"), so they are ONE line
    whose Designator cell is CSV-quoted for the comma it contains. Rows sort
    by (Footprint, Comment, first ref): "Diode_SMD:D_SMA" sorts before
    "R_0805" — 'D' precedes 'R' — so the diode line is first. FID1/TXT1 are
    furniture and contribute nothing."""
    r_cell = _lock_label("R_0805") or "R_0805"
    d_cell = _lock_label("Diode_SMD:D_SMA") or "Diode_SMD:D_SMA"
    assert d_cell < r_cell, "the hand-derived row order below assumes the diode sorts first"
    result = ao.build_bom(_compiled(_load()), "jlc", name="afix")
    assert list(result.keys()) == ["afix-bom-jlc.csv"]
    expected = (
        "Comment,Designator,Footprint,LCSC Part #\r\n"
        f"1N4148,D1,{d_cell},C2128\r\n"
        f'10k,"R1,R2",{r_cell},C25804\r\n'
    )
    assert result["afix-bom-jlc.csv"] == expected


def test_bom_different_mpn_same_footprint_value_are_separate_rows():
    """Two components sharing (footprint, value) but authored with DIFFERENT
    mpn are NOT collapsed into one row — an mpn is part of the identity a
    grouped BOM row asserts, so merging would silently claim one part number
    for two potentially-different real parts.

    THE mpn HAS TO BE THE ONLY DIFFERENCE, or the split proves nothing about
    it. R2 authors no ``house_parts``, so changing its mpn alone would also
    change its LCSC cell (that column falls back to the mpn) and the row would
    split on the Footprint/LCSC key before mpn was ever consulted. Giving R2
    R1's house number holds all four emitted columns identical, so mpn is the
    single field the two disagree about and the single reason they split."""
    board = _load()
    # R2 diverges from R1 in mpn only.
    board["components"][1]["assembly"] = {"mpn": "C99999", "house_parts": {"jlcpcb": "C25804"}}
    result = ao.build_bom(_compiled(board), "jlc")
    assert len(result.rows) == 3

    rows = {row.refs: row for row in result.rows}
    assert ("R1",) in rows and ("R2",) in rows
    r1, r2 = rows[("R1",)], rows[("R2",)]
    # Every emitted cell agrees; only the mpn riding beside them differs.
    assert (r1.comment, r1.footprint, r1.part_number) == ("10k", "R_0805", "C25804")
    assert (r2.comment, r2.footprint, r2.part_number) == ("10k", "R_0805", "C25804")
    assert (r1.mpn, r2.mpn) == ("C25804", "C99999")


def _pair(first_assembly: dict, second_assembly: dict) -> dict:
    """A two-component board that compiles, both parts identical in every
    authored field except the assembly block each carries."""
    board = _minimal()
    template = board["components"][0]
    board["components"] = [
        dict(template, ref="R1", x_mm=5.0, assembly=first_assembly),
        dict(template, ref="R2", x_mm=12.0, assembly=second_assembly),
    ]
    return board


def test_two_refs_with_different_mpn_never_share_a_row_that_reports_one_of_them():
    """A GROUPED ROW ASSERTS ITS mpn OF EVERY REF ON IT. R1 and R2 print the
    same three cells — same comment, same drawing, same house catalogue number,
    which is what actually gets ordered — but name DIFFERENT manufacturer
    parts. Merging them leaves one row carrying one component's mpn for both
    designators, and a caller reconciling the BOM against a distributor quote
    is then handed a part number that is wrong for R2 with nothing in the row
    to say so. The grouping key therefore covers mpn, not only the emitted
    cells.

    THE ORACLE IS WHAT THE ROWS REPORT, not only what the CSV renders: the
    house number is identical on both lines, so a CSV-only assertion would pass
    on the merged row too."""
    result = ao.build_bom(_compiled(_pair(
        {"mpn": "RC0805FR-0710KL", "comment": "RES 10k",
         "house_parts": {"jlcpcb": "C84376"}},
        {"mpn": "ERJ6ENF1002V", "comment": "RES 10k",
         "house_parts": {"jlcpcb": "C84376"}})), "jlc")

    reported = {row.refs: row.mpn for row in result.rows}
    assert reported == {("R1",): "RC0805FR-0710KL", ("R2",): "ERJ6ENF1002V"}
    assert all(row.qty == 1 for row in result.rows)


def test_one_mpn_across_both_refs_still_groups_into_a_single_row():
    """The other side of the same key: mpn splits a row only where the
    components disagree about it. Two parts that agree on everything the row
    asserts stay ONE line with both designators, so the wider key did not turn
    every board into one row per component."""
    block = {"mpn": "RC0805FR-0710KL", "comment": "RES 10k",
             "house_parts": {"jlcpcb": "C84376"}}
    result = ao.build_bom(_compiled(_pair(dict(block), dict(block))), "jlc")
    assert [(row.refs, row.mpn, row.qty) for row in result.rows] == [
        (("R1", "R2"), "RC0805FR-0710KL", 2)]
    assert next(iter(result.values())).splitlines()[1] == 'RES 10k,"R1,R2",R_0805,C84376'


def test_bom_asymmetric_labelling_splits_the_row():
    """A LABELLED DRAWING BESIDE AN UNLABELLED ONE SPLITS THE ROW, and that is
    correct rather than a grouping bug. The Footprint column prints the lock
    label when the drawing has one and the drawing ref when it has not, so two
    parts with identical identity on different drawings print two different
    cells — two grouping keys, two lines, qty=1 each.

    Pinned on its OWN board rather than inside a grouping seal. The seals exist
    to prove that parts a house reads as one part arrive as one line; a fixture
    that labelled the drawings asymmetrically would satisfy them by splitting
    on this instead. Here the split IS the claim.

    The oracle is both cells: one row carries the label the lock states, the
    other the drawing ref it falls back to. Everything else about the two parts
    — value, mpn, and therefore the LCSC cell that falls back to it — is
    identical. Rows sort by the Footprint cell, and "R_0805" sorts before the
    label ('R' precedes 'S'), so R2's line comes first."""
    label = _lock_label(LABELLED_FOOTPRINT)
    assert label and label != LABELLED_FOOTPRINT, "the seed lock no longer labels the drawing"
    board = _pair({"mpn": "C25804"}, {"mpn": "C25804"})
    board["components"][0]["footprint"] = LABELLED_FOOTPRINT
    result = ao.build_bom(_compiled(board), "jlc")

    assert "R_0805" < label, "the row order below assumes the ref sorts before the label"
    assert [(row.refs, row.footprint, row.qty) for row in result.rows] == [
        (("R2",), "R_0805", 1),
        (("R1",), label, 1),
    ]
    assert all(row.comment == "10k" and row.part_number == "C25804"
               and row.mpn == "C25804" for row in result.rows)
    assert next(iter(result.values())).splitlines()[1:] == [
        "10k,R2,R_0805,C25804",
        f"10k,R1,{label},C25804",
    ]


@pytest.mark.parametrize("key,bad", [("value", 10), ("footprint", 12345)])
def test_non_string_identity_field_never_reaches_the_emitter(key, bad):
    """A non-string ``value`` or ``footprint`` used to poison the BOM sort key
    (mixed str/int tuple comparison) and surface as a bare traceback, so this
    module carried its own type guard. The compiler already refuses both by
    name, and it is now the only adjudicator."""
    board = _load()
    board["components"][0][key] = bad
    assert "invalid_component" in _compile_errors(board)


# ---------------------------------------------------------------------------
# Part-identity contract — structured refusal naming the component
# ---------------------------------------------------------------------------


def test_bom_missing_mpn_is_named_refusal_not_blank_cell():
    board = _load()
    del board["components"][0]["assembly"]["mpn"]  # R1
    with pytest.raises(ao.AssemblyIdentityError) as exc_info:
        ao.build_bom(_compiled(board), "jlc")
    message = str(exc_info.value)
    assert "R1" in message
    assert "mpn" in message


def test_cpl_missing_mpn_is_named_refusal_not_blank_cell():
    board = _load()
    del board["components"][2]["assembly"]  # D1
    with pytest.raises(ao.AssemblyIdentityError) as exc_info:
        ao.build_cpl(_compiled(board), "jlc")
    assert "D1" in str(exc_info.value)


@pytest.mark.parametrize("blank", ["", "   ", "\r", "\r\n", "\t"])
def test_whitespace_only_mpn_is_treated_as_missing_not_a_blank_cell(blank):
    """An mpn that is present-but-empty must refuse exactly like an ABSENT
    one — the identity contract is about a usable part number reaching the
    assembly house, not about a key existing.

    The "\\r" cases are not hypothetical: they are the shape a CRLF-mangled
    edit (or a hand-quoted value copied off a Windows checkout) leaves behind,
    and a house would receive a BOM line whose LCSC column is a lone carriage
    return. Pins the ``.strip()`` in assembly_spec's identity fold as
    load-bearing, not cosmetic (see the Windows-CI note on replaceOnceLF in
    pcb/main_test.go for the sibling break on the Go side).
    """
    board = _load()
    board["components"][0]["assembly"]["mpn"] = blank  # R1
    with pytest.raises(ao.AssemblyIdentityError) as exc_info:
        ao.build_bom(_compiled(board), "jlc")
    assert "R1" in str(exc_info.value)
    assert "mpn" in str(exc_info.value)


# ---------------------------------------------------------------------------
# House-format-agnostic core + per-house capability refusal
# ---------------------------------------------------------------------------


def test_unknown_house_is_named_refusal():
    board = _compiled(_load())
    with pytest.raises(ao.AssemblyProfileError, match="acme"):
        ao.build_bom(board, "acme")
    with pytest.raises(ao.AssemblyProfileError, match="acme"):
        ao.build_cpl(board, "acme")


def test_house_without_assembly_service_is_named_refusal():
    """OSH Park is bare-board only — a KNOWN house, but one that must refuse an
    assembly-package request BY NAME, distinct from a house this module has
    never heard of."""
    board = _compiled(_load())
    with pytest.raises(ao.AssemblyProfileError, match="OSH Park"):
        ao.build_bom(board, "oshpark")
    with pytest.raises(ao.AssemblyProfileError, match="OSH Park"):
        ao.build_cpl(board, "oshpark")


def test_profile_id_must_be_a_string():
    board = _compiled(_load())
    with pytest.raises(ao.AssemblyProfileError):
        ao.build_bom(board, None)
    with pytest.raises(ao.AssemblyProfileError):
        ao.build_bom(board, "")


# ---------------------------------------------------------------------------
# The deliberate capability regression, named
# ---------------------------------------------------------------------------


def test_uncompilable_board_used_to_emit_and_now_refuses_by_name():
    """THE REGRESSION ORACLE. assembly_fixture.yaml is a board a house could
    never build: its resistor pins sit 0.05mm off their library pads, its diode
    names a footprint no library supplies, and it omits two required via rules.
    The raw-dict emitter produced a clean BOM and CPL for it regardless — that
    is the two-boards-in-one-order defect, in one file.

    It must now refuse, and the refusal must NAME what blocked the compile:
    the offending pads, the unresolved footprint, and the missing rules — never
    a traceback, and never a partial CSV."""
    codes = _compile_errors(_load(UNCOMPILABLE_FIXTURE))
    assert "pin_pad_desync" in codes
    assert "footprint_unresolved" in codes
    assert "invalid_design_rule" in codes


def test_not_compilable_error_names_the_blocking_entities():
    """The refusal PAYLOAD the order surfaces return, built from that same
    board's diagnostics: its own kind (so a caller can tell "this board cannot
    be compiled" from "this house has no assembly service"), a message that
    states the regression, and a blocked_by list naming every component, pad
    and footprint that stopped the compile.

    Built here from the compile failure directly, so the payload's shape is
    pinned independently of the RPC wiring that returns it
    (test_methods.py covers the dispatch)."""
    from pcb_worker import methods

    failure = compile_board(_load(UNCOMPILABLE_FIXTURE))
    error = ao.not_compilable_error(methods._compile_failure_reply(failure)["error"])

    assert error["kind"] == ao.NOT_COMPILABLE_KIND == "assembly_not_compilable"
    assert "does not compile yields no bom and no cpl" in error["message"].lower()

    named = {b["entity_id"] for b in error["blocked_by"]}
    assert {"R1.1", "R1.2", "R2.1", "R2.2"} <= named  # the desynced pads
    assert "D1" in named                              # the unresolved footprint
    assert all(b["code"] for b in error["blocked_by"])
    # Only ERROR diagnostics block; every diagnostic still rides along.
    assert len(error["blocked_by"]) <= len(error["diagnostics"])


# ---------------------------------------------------------------------------
# Determinism (module-mechanics level; the standing byte-identity GATE is
# test_determinism_gate.py, extended with this fixture as a data row).
# ---------------------------------------------------------------------------


def test_bom_and_cpl_are_byte_identical_across_runs():
    board = _compiled(_load())
    assert dict(ao.build_bom(board, "jlc")) == dict(ao.build_bom(board, "jlc"))
    assert dict(ao.build_cpl(board, "jlc")) == dict(ao.build_cpl(board, "jlc"))


# ---------------------------------------------------------------------------
# PASTE NON-CLAIM — neither output claims paste coverage.
# ---------------------------------------------------------------------------


def test_neither_output_mentions_paste():
    """Unchanged by the cutover even though the IR now CARRIES a paste policy
    (``ResolvedAssembly.paste``): a BOM/CPL pair is not a stencil, and a paste
    column appearing here would be read as one."""
    board = _compiled(_load())
    bom_content = next(iter(ao.build_bom(board, "jlc").values()))
    cpl_content = next(iter(ao.build_cpl(board, "jlc").values()))
    assert "paste" not in bom_content.lower()
    assert "paste" not in cpl_content.lower()


# ---------------------------------------------------------------------------
# Board furniture and do-not-populate, through the compiled IR
# ---------------------------------------------------------------------------


def test_excluded_components_skip_rows_and_the_identity_contract():
    """FID1 (legacy ``assembly: exclude``) and TXT1 (structured
    ``populate: false``) carry no mpn; without the exclusion the identity
    contract would refuse the whole board. They are skipped BEFORE the identity
    check and RECORDED on the result's side channel in board order, never
    silently dropped — and BOTH authored forms behave identically, which is
    what keeps the Go codec's scalar migration from changing what is ordered."""
    board = _compiled(_load())
    bom = ao.build_bom(board, "jlc")
    assert bom.excluded_refs == ("FID1", "TXT1")
    csv_text = next(iter(bom.values()))
    assert "FID1" not in csv_text and "TXT1" not in csv_text

    cpl = ao.build_cpl(board, "jlc")
    assert [r.ref for r in cpl.rows] == ["D1", "R1", "R2"]
    assert cpl.excluded_refs == ("FID1", "TXT1")


def test_exclusion_does_not_relax_identity_for_assembled_parts():
    """The contract is skip-or-enforce, never weaken: a NON-excluded part
    missing its mpn still refuses even when furniture is present."""
    board = _load()
    del board["components"][0]["assembly"]["mpn"]
    with pytest.raises(ao.AssemblyIdentityError, match="R1"):
        ao.build_bom(_compiled(board), "jlc")


def test_populated_block_does_not_exclude_and_carries_identity():
    """A block that says populate:true is NOT an exclusion, and its ``mpn`` is
    the component's identity — the block is where part identity lives, so a
    board that moved its mpn there must not read as missing one."""
    board = _compiled(_minimal(assembly={
        "populate": True, "mpn": "RC0805FR-0710KL",
        "manufacturer": "Yageo", "paste": "auto"}))
    bom = ao.build_bom(board, "jlc")
    assert [r.refs for r in bom.rows] == [("R1",)]
    assert bom.rows[0].mpn == "RC0805FR-0710KL"
    assert bom.excluded_refs == ()
    assert ao.build_cpl(board, "jlc").rows[0].mpn == "RC0805FR-0710KL"


def test_block_mpn_wins_over_the_legacy_top_level_scalar():
    """Precedence, stated once in assembly_spec and pinned here at the emitted
    value: the structured block is the explicit authority, the top-level scalar
    is the pre-block form."""
    board = _compiled(_minimal(mpn="OLD-PART", assembly={"mpn": "NEW-PART"}))
    assert ao.build_bom(board, "jlc").rows[0].mpn == "NEW-PART"


def test_empty_block_is_not_an_exclusion_and_still_needs_identity():
    """An ``assembly: {}`` block states nothing: the component is populated,
    and the identity contract applies to it in full."""
    with pytest.raises(ao.AssemblyIdentityError, match="R1"):
        ao.build_bom(_compiled(_minimal(assembly={})), "jlc")


def test_no_exclusions_keeps_side_channel_empty():
    board = _compiled(_minimal(assembly={"mpn": "C25804"}))
    assert ao.build_bom(board, "jlc").excluded_refs == ()


def test_component_without_a_resolved_assembly_block_is_a_named_refusal():
    """Fail-closed on an IR built by something other than the compiler: a
    component carrying no resolved assembly block must refuse by name rather
    than be read as "this part has no assembly facts", which would drop its
    identity requirement silently."""
    import dataclasses

    board = _compiled(_load())
    stripped = dataclasses.replace(board.components[0], assembly=None)
    board = dataclasses.replace(
        board, components=(stripped,) + tuple(board.components[1:]))
    with pytest.raises(ao.AssemblyBoardError, match="no resolved assembly block"):
        ao.build_bom(board, "jlc")
