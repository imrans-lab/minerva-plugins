"""Tests for pcb_worker.assembly_outputs — BOM + CPL assembly-package
emitters (C8, docket 019f763cdf5b).

EXECUTABLE SEALS (never parked — these are the load-bearing proofs the epoch
regime requires for this unit):
  * test_cpl_rows_match_hand_derived_values — every CPL row for the synthetic
    fixture, HAND-DERIVED by inspection of assembly_fixture.yaml (a fabricated
    or library-sourced expectation here would defeat the point of the seal).
  * test_bom_groups_by_footprint_value_mpn — BOM grouping seal.
  * test_*_identity_refusal* — the part-identity contract.
  * test_*_house_refusal* — the per-house capability refusal.

See test_methods.py for the RPC-dispatch-level ("assembly_bom"/"assembly_cpl"
worker methods) coverage of the same module — this file is emitter-mechanics
only.
"""

from __future__ import annotations

from pathlib import Path

import pytest
import yaml

from pcb_worker import assembly_outputs as ao

FIXTURE = (Path(__file__).resolve().parent / "testdata" / "assembly_boards"
          / "assembly_fixture.yaml")


def _load() -> dict:
    return yaml.safe_load(FIXTURE.read_text(encoding="utf-8"))


# ---------------------------------------------------------------------------
# CPL — hand-derived rows (rotation-convention + side seal)
# ---------------------------------------------------------------------------


def test_cpl_rows_match_hand_derived_values():
    """assembly_fixture.yaml, by inspection, THEN through the MEASURED
    coordinate frame (module docstring's COORDINATE FRAME section: X
    verbatim, Y NEGATED — proven against a real ``kicad-cli 9.0.9 pcb export
    pos`` run on this exact fixture):
      R1: x_mm=10.0 y_mm=5.0  rotation_deg=0  layer=top    -> (10.0, -5.0, 0.0, top)
      R2: x_mm=15.0 y_mm=5.0  rotation_deg=90 layer=top    -> (15.0, -5.0, 90.0, top)
      D1: x_mm=12.5 y_mm=14.0 rotation_deg=45 layer=bottom -> (12.5, -14.0, 45.0, bottom)
    Rotation is emitted VERBATIM (module docstring's ROTATION CONVENTION) — no
    sign flip, no trigonometry — so rotation stays exact arithmetic identity
    with the authored YAML; only Y changes sign. D1's X is UNMIRRORED despite
    being bottom-side (kicad-cli's default; see module docstring).
    Rows sort by ref: D1, R1, R2.
    """
    board = _load()
    result = ao.build_cpl(board, "jlc")
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


def test_cpl_csv_hand_derived_bytes():
    """The rendered JLC CPL CSV, byte-for-byte, hand-derived from the same
    three rows (header + D1/R1/R2 in ref order, CRLF line endings, 4-decimal
    fixed-point mm/degrees, Top/Bottom capitalized per the JLC template, Y
    negated per the measured coordinate frame)."""
    board = _load()
    result = ao.build_cpl(board, "jlc", name="afix")
    assert list(result.keys()) == ["afix-cpl-jlc.csv"]
    content = result["afix-cpl-jlc.csv"]
    expected = (
        "Designator,Mid X,Mid Y,Layer,Rotation\r\n"
        "D1,12.5000,-14.0000,Bottom,45.0000\r\n"
        "R1,10.0000,-5.0000,Top,0.0000\r\n"
        "R2,15.0000,-5.0000,Top,90.0000\r\n"
    )
    assert content == expected


def test_cpl_y_matches_kicad_cli_position_file_oracle():
    """INDEPENDENT of the hand-derivation above: this is the actual oracle
    proof. assembly_fixture.yaml, run through this repo's own
    ``kicad.generate_kicad_pcb`` and then a REAL ``kicad-cli 9.0.9 pcb export
    pos --format csv --units mm`` (the position file a board house would
    receive), measured:

        Ref  PosX       PosY        Rot  Side
        R1   10.000000  -5.000000   0    top
        R2   15.000000  -5.000000   90   top
        D1   12.500000  -14.000000  45   bottom

    This test hardcodes that MEASURED output (not re-run here — kicad-cli is
    a dev/CI-optional oracle elsewhere in this suite, see
    tests/oracle/test_kicad_drc_oracle.py; this seal pins the value already
    measured rather than adding a second live kicad-cli dependency to this
    module's own tests) and asserts assembly_outputs agrees with it exactly.
    """
    board = _load()
    result = ao.build_cpl(board, "jlc")
    rows = {row.ref: row for row in result.rows}
    kicad_cli_oracle = {
        "R1": (10.0, -5.0, 0.0, "top"),
        "R2": (15.0, -5.0, 90.0, "top"),
        "D1": (12.5, -14.0, 45.0, "bottom"),
    }
    for ref, (px, py, rot, side) in kicad_cli_oracle.items():
        assert rows[ref].x_mm == px
        assert rows[ref].y_mm == py
        assert rows[ref].rotation_deg == rot
        assert rows[ref].side == side


def test_cpl_rotation_normalizes_negative_and_over_360():
    board = _load()
    board["components"][0]["rotation_deg"] = -90  # R1: -90 == 270
    board["components"][1]["rotation_deg"] = 450   # R2: 450 == 90
    result = ao.build_cpl(board, "jlc")
    rows = {row.ref: row for row in result.rows}
    assert rows["R1"].rotation_deg == 270.0
    assert rows["R2"].rotation_deg == 90.0


def test_cpl_unrecognized_layer_is_named_refusal():
    board = _load()
    board["components"][0]["layer"] = "in1.cu"  # a named, non-top/bottom layer
    with pytest.raises(ao.AssemblyBoardError, match="R1"):
        ao.build_cpl(board, "jlc")


def test_cpl_empty_string_layer_is_named_refusal_not_silent_top():
    """compile_board._resolve_side (compile_board.py:2549-2562) treats a
    PRESENT-but-empty layer string as a refusal, distinct from an ABSENT
    (None) layer, which defaults to top. This module must match that exactly
    — a component with ``layer: ""`` must refuse, not silently emit top,
    or a caller passing this module's output past a compile-gated caller
    would see two different verdicts for the same board (cross-surface
    fail-open the review caught: geometry.is_top folded "" into the same
    bucket as None)."""
    board = _load()
    board["components"][0]["layer"] = ""
    with pytest.raises(ao.AssemblyBoardError, match="R1"):
        ao.build_cpl(board, "jlc")


def test_cpl_absent_layer_still_defaults_to_top():
    """The None/absent case is UNCHANGED — only present-but-unrecognized
    (including "") is refused. Mirrors compile_board._resolve_side's
    ``raw_layer is None -> Side.TOP`` branch exactly."""
    board = _load()
    del board["components"][0]["layer"]
    result = ao.build_cpl(board, "jlc")
    rows = {row.ref: row for row in result.rows}
    assert rows["R1"].side == "top"


# ---------------------------------------------------------------------------
# BOM — grouping seal
# ---------------------------------------------------------------------------


def test_bom_groups_by_footprint_value_mpn():
    """R1 + R2 share (R_0805, "10k", C25804) -> ONE grouped row with both
    refs and qty=2; D1 (D_SOD-123, 1N4148, C2128) is its own row, qty=1."""
    board = _load()
    result = ao.build_bom(board, "jlc")
    assert len(result.rows) == 2

    by_footprint = {row.footprint: row for row in result.rows}
    r0805 = by_footprint["R_0805"]
    assert r0805.refs == ("R1", "R2")
    assert r0805.value == "10k"
    assert r0805.mpn == "C25804"
    assert r0805.qty == 2

    diode = by_footprint["D_SOD-123"]
    assert diode.refs == ("D1",)
    assert diode.value == "1N4148"
    assert diode.mpn == "C2128"
    assert diode.qty == 1


def test_bom_csv_hand_derived_bytes():
    board = _load()
    result = ao.build_bom(board, "jlc", name="afix")
    assert list(result.keys()) == ["afix-bom-jlc.csv"]
    content = result["afix-bom-jlc.csv"]
    expected = (
        "Comment,Designator,Footprint,LCSC Part #\r\n"
        "1N4148,D1,D_SOD-123,C2128\r\n"
        '10k,"R1,R2",R_0805,C25804\r\n'
    )
    assert content == expected


def test_bom_different_mpn_same_footprint_value_are_separate_rows():
    """Two components sharing (footprint, value) but authored with DIFFERENT
    mpn are NOT collapsed into one row — an mpn is part of the identity a
    grouped BOM row asserts, so merging would silently claim one part number
    for two potentially-different real parts."""
    board = _load()
    board["components"][1]["mpn"] = "C99999"  # R2 diverges from R1
    result = ao.build_bom(board, "jlc")
    assert len(result.rows) == 3
    refs = {row.refs for row in result.rows}
    assert ("R1",) in refs and ("R2",) in refs


def test_bom_non_string_value_is_named_refusal_not_a_crash():
    """A non-string ``value`` (e.g. an int from a loosely-typed board dict)
    used to poison the BOM sort key (mixed str/int tuple comparison) and
    surface as a bare TypeError/traceback. Mirrors compile_board.py:2223-2229
    ("the canonical contract types Component.Value as a string... a present
    non-string value must not be stringified") — refuse by name instead."""
    board = _load()
    board["components"][0]["value"] = 10  # int, not "10k"
    with pytest.raises(ao.AssemblyBoardError, match="R1"):
        ao.build_bom(board, "jlc")


def test_bom_non_string_footprint_is_named_refusal_not_a_crash():
    """Same class of bug as the value case above — footprint sits in the same
    sort/group key tuple and can poison it identically."""
    board = _load()
    board["components"][0]["footprint"] = 12345
    with pytest.raises(ao.AssemblyBoardError, match="R1"):
        ao.build_bom(board, "jlc")


# ---------------------------------------------------------------------------
# Part-identity contract — structured refusal naming the component
# ---------------------------------------------------------------------------


def test_bom_missing_mpn_is_named_refusal_not_blank_cell():
    board = _load()
    del board["components"][0]["mpn"]  # R1
    with pytest.raises(ao.AssemblyIdentityError) as exc_info:
        ao.build_bom(board, "jlc")
    message = str(exc_info.value)
    assert "R1" in message
    assert "mpn" in message


def test_cpl_missing_mpn_is_named_refusal_not_blank_cell():
    board = _load()
    del board["components"][2]["mpn"]  # D1
    with pytest.raises(ao.AssemblyIdentityError) as exc_info:
        ao.build_cpl(board, "jlc")
    assert "D1" in str(exc_info.value)


@pytest.mark.parametrize("blank", ["", "   ", "\r", "\r\n", "\t"])
def test_whitespace_only_mpn_is_treated_as_missing_not_a_blank_cell(blank):
    """An mpn that is present-but-empty must refuse exactly like an ABSENT
    one — the identity contract is about a usable part number reaching the
    assembly house, not about a key existing.

    The "\\r" cases are not hypothetical: they are the shape a CRLF-mangled
    edit (or a hand-quoted value copied off a Windows checkout) leaves behind,
    and a house would receive a BOM line whose LCSC column is a lone carriage
    return. Pins the `.strip()` in assembly_outputs._component_property as
    load-bearing, not cosmetic (see the Windows-CI note on replaceOnceLF in
    pcb/main_test.go for the sibling break on the Go side).
    """
    board = _load()
    board["components"][0]["mpn"] = blank  # R1
    with pytest.raises(ao.AssemblyIdentityError) as exc_info:
        ao.build_bom(board, "jlc")
    assert "R1" in str(exc_info.value)
    assert "mpn" in str(exc_info.value)


def test_identity_from_nested_properties_mapping_also_satisfies():
    """The tolerant `properties.mpn` fallback (module docstring) satisfies the
    same identity requirement as a top-level `mpn` scalar."""
    board = _load()
    del board["components"][0]["mpn"]
    board["components"][0]["properties"] = {"mpn": "C25804"}
    result = ao.build_bom(board, "jlc")
    assert any(row.mpn == "C25804" and "R1" in row.refs for row in result.rows)


# ---------------------------------------------------------------------------
# House-format-agnostic core + per-house capability refusal
# ---------------------------------------------------------------------------


def test_unknown_house_is_named_refusal():
    board = _load()
    with pytest.raises(ao.AssemblyProfileError, match="acme"):
        ao.build_bom(board, "acme")
    with pytest.raises(ao.AssemblyProfileError, match="acme"):
        ao.build_cpl(board, "acme")


def test_house_without_assembly_service_is_named_refusal():
    """OSH Park is bare-board only (docket 019f763cdf5b) — a KNOWN house, but
    one that must refuse an assembly-package request BY NAME, distinct from a
    house this module has never heard of."""
    board = _load()
    with pytest.raises(ao.AssemblyProfileError, match="OSH Park"):
        ao.build_bom(board, "oshpark")
    with pytest.raises(ao.AssemblyProfileError, match="OSH Park"):
        ao.build_cpl(board, "oshpark")


def test_profile_id_must_be_a_string():
    board = _load()
    with pytest.raises(ao.AssemblyProfileError):
        ao.build_bom(board, None)
    with pytest.raises(ao.AssemblyProfileError):
        ao.build_bom(board, "")


# ---------------------------------------------------------------------------
# Determinism (module-mechanics level; the standing byte-identity GATE is
# test_determinism_gate.py, extended with this fixture as a data row — same
# pattern C6 used for the zone-fill fixture).
# ---------------------------------------------------------------------------


def test_bom_and_cpl_are_byte_identical_across_runs():
    board = _load()
    bom_a, bom_b = ao.build_bom(board, "jlc"), ao.build_bom(board, "jlc")
    cpl_a, cpl_b = ao.build_cpl(board, "jlc"), ao.build_cpl(board, "jlc")
    assert dict(bom_a) == dict(bom_b)
    assert dict(cpl_a) == dict(cpl_b)


# ---------------------------------------------------------------------------
# PASTE NON-CLAIM — neither output claims paste coverage.
# ---------------------------------------------------------------------------


def test_neither_output_mentions_paste():
    board = _load()
    bom_content = next(iter(ao.build_bom(board, "jlc").values()))
    cpl_content = next(iter(ao.build_cpl(board, "jlc").values()))
    assert "paste" not in bom_content.lower()
    assert "paste" not in cpl_content.lower()


# ---------------------------------------------------------------------------
# The assembly block — board furniture and do-not-populate
# ---------------------------------------------------------------------------


def _furniture_board() -> dict:
    return {
        "name": "furniture", "components": [
            {"ref": "C1", "footprint": "C_0805", "value": "100n", "mpn": "C1525",
             "x_mm": 5, "y_mm": 5, "layer": "top"},
            {"ref": "LOGO1", "footprint": "OWL", "x_mm": 10, "y_mm": 10,
             "layer": "top", "assembly": "exclude"},
            {"ref": "FID1", "footprint": "FID", "x_mm": 2, "y_mm": 2,
             "layer": "top", "assembly": "exclude"},
        ]}


def test_excluded_components_skip_bom_and_identity_contract():
    """LOGO1/FID1 have no mpn; without the exclusion the identity contract
    would refuse the whole board. With it, they are skipped BEFORE the
    identity check and RECORDED on the result's side channel (board order),
    never silently dropped."""
    result = ao.build_bom(_furniture_board(), "jlc")
    assert [r.refs for r in result.rows] == [("C1",)]
    assert result.excluded_refs == ("LOGO1", "FID1")
    # The rendered CSV carries no furniture refs.
    csv_text = next(iter(result.values()))
    assert "LOGO1" not in csv_text and "FID1" not in csv_text


def test_excluded_components_skip_cpl_rows():
    result = ao.build_cpl(_furniture_board(), "jlc")
    assert [r.ref for r in result.rows] == ["C1"]
    assert result.excluded_refs == ("LOGO1", "FID1")


def test_exclusion_does_not_relax_identity_for_assembled_parts():
    """The contract is skip-or-enforce, never weaken: a NON-excluded part
    missing its mpn still refuses even when furniture is present."""
    board = _furniture_board()
    del board["components"][0]["mpn"]
    with pytest.raises(ao.AssemblyIdentityError, match="C1"):
        ao.build_bom(board, "jlc")


def test_unrecognized_assembly_value_is_named_refusal():
    """Fail-closed on the token: a typo must never be read as 'not excluded'
    (that lands a fiducial in the BOM with a fabricated identity demand)."""
    board = _furniture_board()
    board["components"][1]["assembly"] = "exlcude"
    with pytest.raises(ao.AssemblyBoardError, match="legacy 'exclude' scalar"):
        ao.build_bom(board, "jlc")
    with pytest.raises(ao.AssemblyBoardError, match="legacy 'exclude' scalar"):
        ao.build_cpl(board, "jlc")


def test_structured_block_reads_the_same_as_the_legacy_scalar():
    """The Go codec migrates `assembly: exclude` to `{populate: false}`, so a
    promoted board reaches this module in the STRUCTURED shape. Both forms must
    produce identical outputs — otherwise the migration silently changes what
    gets ordered. The board here is _furniture_board with its two scalars
    rewritten; every assertion is the scalar tests' assertion."""
    board = _furniture_board()
    for comp in board["components"][1:]:
        comp["assembly"] = {"populate": False}
    bom = ao.build_bom(board, "jlc")
    assert [r.refs for r in bom.rows] == [("C1",)]
    assert bom.excluded_refs == ("LOGO1", "FID1")
    cpl = ao.build_cpl(board, "jlc")
    assert [r.ref for r in cpl.rows] == ["C1"]
    assert cpl.excluded_refs == ("LOGO1", "FID1")


def test_populated_block_does_not_exclude_and_carries_identity():
    """A block that says populate:true is NOT an exclusion, and its `mpn` is
    the component's identity — the block is where part identity lives, so a
    board that moved its mpn there must not read as missing one."""
    board = {"name": "populated", "components": [
        {"ref": "R1", "footprint": "R_0805", "value": "10k",
         "x_mm": 5, "y_mm": 5, "layer": "top",
         "assembly": {"populate": True, "mpn": "RC0805FR-0710KL",
                      "manufacturer": "Yageo", "paste": "auto"}},
    ]}
    bom = ao.build_bom(board, "jlc")
    assert [r.refs for r in bom.rows] == [("R1",)]
    assert bom.rows[0].mpn == "RC0805FR-0710KL"
    assert bom.excluded_refs == ()
    assert ao.build_cpl(board, "jlc").rows[0].mpn == "RC0805FR-0710KL"


def test_block_mpn_wins_over_the_legacy_top_level_scalar():
    """Precedence, stated once and pinned here: the structured block is the
    explicit authority, the top-level scalar is the pre-block form."""
    board = {"name": "both", "components": [
        {"ref": "R1", "footprint": "R_0805", "value": "10k",
         "x_mm": 5, "y_mm": 5, "layer": "top", "mpn": "OLD-PART",
         "assembly": {"mpn": "NEW-PART"}},
    ]}
    assert ao.build_bom(board, "jlc").rows[0].mpn == "NEW-PART"


def test_empty_block_is_not_an_exclusion_and_still_needs_identity():
    """An `assembly: {}` block states nothing: the component is populated, and
    the identity contract applies to it in full."""
    board = {"name": "empty-block", "components": [
        {"ref": "R1", "footprint": "R_0805", "value": "10k",
         "x_mm": 5, "y_mm": 5, "layer": "top", "assembly": {}},
    ]}
    with pytest.raises(ao.AssemblyIdentityError, match="R1"):
        ao.build_bom(board, "jlc")


def test_non_boolean_populate_is_a_named_refusal():
    """`populate: "false"` (a string) must not be read as truthy-and-populated:
    the one thing this module never does is guess."""
    board = _furniture_board()
    board["components"][1]["assembly"] = {"populate": "false"}
    with pytest.raises(ao.AssemblyBoardError, match="populate must be a boolean"):
        ao.build_bom(board, "jlc")


def test_no_exclusions_keeps_side_channel_empty():
    board = _furniture_board()
    board["components"] = [board["components"][0]]
    result = ao.build_bom(board, "jlc")
    assert result.excluded_refs == ()
