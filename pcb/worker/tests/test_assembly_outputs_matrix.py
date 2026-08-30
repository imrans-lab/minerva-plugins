"""assembly_outputs (BOM/CPL) profile-matrix + edge cases — breadth, not depth.

The load-bearing proofs (hand-derived CPL rows, the cutover byte oracle, BOM
grouping, identity refusal, house refusal, the named uncompilable-board
refusal, byte determinism) are the EXECUTABLE seals in
``test_assembly_outputs.py`` plus a data-row addition to
``test_determinism_gate.py``. What is below crosses every profile with every
emit function and covers edge inputs no single seal needs to carry.

Every case here now goes through a strict compilation first, because that is
what the emitters read. Several cases that used to characterize a GAP in the
raw-dict path — a duplicate designator emitting two CPL rows, a blank footprint
grouping under the empty string — are gaps the compiler closes, and they are
rewritten below to pin the refusal rather than the old tolerance.
"""

from __future__ import annotations

from dataclasses import replace
from pathlib import Path

import pytest
import yaml

from pcb_worker import assembly_outputs as ao
from pcb_worker.compile_board import compile_board
from pcb_worker.resolved_board import DiagnosticSeverity, ResolutionSuccess

FIXTURE = (Path(__file__).resolve().parent / "testdata" / "assembly_boards"
          / "assembly_resolved.yaml")


def _load() -> dict:
    return yaml.safe_load(FIXTURE.read_text(encoding="utf-8"))


def _compiled(board: dict):
    result = compile_board(board)
    if not isinstance(result, ResolutionSuccess):
        raise AssertionError(
            "fixture did not compile: "
            + ", ".join(d.code for d in result.diagnostics
                        if d.severity is DiagnosticSeverity.ERROR))
    return result.board


def _compile_errors(board: dict) -> set[str]:
    result = compile_board(board)
    assert not isinstance(result, ResolutionSuccess), "expected the board to refuse"
    return {d.code for d in result.diagnostics
            if d.severity is DiagnosticSeverity.ERROR}


def _minimal(**component) -> dict:
    """A one-component board with NO nets, for the cases that need a board
    shaped differently from the fixture without dragging its net list along."""
    comp = {"ref": "R1", "footprint": "R_0805", "value": "10k",
            "x_mm": 5.0, "y_mm": 5.0, "rotation_deg": 0, "layer": "top",
            "assembly": {"mpn": "C25804"}}
    comp.update(component)
    return {
        "version": 1, "name": "minimal", "width_mm": 20, "height_mm": 20,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.25,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [comp],
    }


# ---------------------------------------------------------------------------
# Profile matrix — every shipped PROFILES entry x every emit function.
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("profile_id", sorted(ao.PROFILES))
@pytest.mark.parametrize("emit", [ao.build_bom, ao.build_cpl])
def test_profile_matrix_supports_or_refuses_by_capability(profile_id, emit):
    """Every KNOWN profile either emits (supports_assembly) or refuses BY
    NAME (not supports_assembly) — never a third outcome (a crash, a silent
    partial file, or a refusal that doesn't name the house)."""
    board = _compiled(_load())
    profile = ao.PROFILES[profile_id]
    if profile.supports_assembly:
        result = emit(board, profile_id)
        assert len(result) == 1
    else:
        with pytest.raises(ao.AssemblyProfileError, match=profile.display_name):
            emit(board, profile_id)


def test_every_assembly_capable_profile_has_a_renderer_wired():
    """A profile declared supports_assembly=True but with no renderer branch
    in build_bom/build_cpl would hit the `pragma: no cover` else-raise —
    catching that class of authoring mistake without needing a second live
    house to actually stand up. Today PROFILES has exactly one
    assembly-capable entry (jlc); this test is the tripwire for the day a
    second one is added without its renderer."""
    board = _compiled(_load())
    for profile_id, profile in ao.PROFILES.items():
        if not profile.supports_assembly:
            continue
        ao.build_bom(board, profile_id)
        ao.build_cpl(board, profile_id)


# ---------------------------------------------------------------------------
# Generic multi-field identity contract (jlc only requires ``mpn`` today; the
# CORE mechanism (_check_identity) is house-agnostic and should hold for a
# hypothetical profile requiring more than one field).
# ---------------------------------------------------------------------------


def test_identity_refusal_names_every_missing_field_not_just_the_first():
    """The fixture already supplies ``mpn`` for every component (it is
    IDENTITY-CLEAN by construction, per assembly_fixture.yaml's own header),
    so adding a SECOND required field the fixture does NOT supply
    (``distributor_pn``) isolates the "every missing field is named, not just
    the first" claim from the already-covered single-field case in
    test_assembly_outputs.py."""
    two_field_profile = replace(
        ao.PROFILES["jlc"], identity_required=("mpn", "distributor_pn"))
    ao.PROFILES["synthetic-two-field"] = two_field_profile
    try:
        board = _compiled(_load())
        with pytest.raises(ao.AssemblyIdentityError) as exc_info:
            ao.build_bom(board, "synthetic-two-field")
        message = str(exc_info.value)
        assert "distributor_pn" in message
        assert "mpn" not in message.split("identity field(s) ")[1].split(" for")[0]
        assert "R1" in message  # first component reached, alphabetically first ref group
    finally:
        del ao.PROFILES["synthetic-two-field"]


def test_identity_satisfied_when_all_required_fields_present():
    # NOTE: id stays "jlc" (only identity_required is widened) — build_bom's
    # renderer dispatch keys off profile.id, and a truly new id needs its own
    # renderer branch (see test_every_assembly_capable_profile_has_a_renderer_
    # wired above); that is a SEPARATE claim from the one this test makes.
    two_field_profile = replace(
        ao.PROFILES["jlc"], identity_required=("mpn", "distributor_pn"))
    ao.PROFILES["synthetic-two-field"] = two_field_profile
    try:
        board = _load()
        for comp in board["components"]:
            comp["distributor_pn"] = f"DIST-{comp['ref']}"
        result = ao.build_bom(_compiled(board), "synthetic-two-field")
        assert len(result.rows) == 2
    finally:
        del ao.PROFILES["synthetic-two-field"]


# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------


def test_zero_components_emits_header_only_csv():
    board = _load()
    board["components"] = []
    board["nets"] = []  # the nets name pins on the components just removed
    bom = ao.build_bom(_compiled(board), "jlc")
    cpl = ao.build_cpl(_compiled(board), "jlc")
    assert next(iter(bom.values())) == "Comment,Designator,Footprint,LCSC Part #\r\n"
    assert next(iter(cpl.values())) == "Designator,Mid X,Mid Y,Layer,Rotation\r\n"
    assert bom.rows == []
    assert cpl.rows == []


def test_rotation_exactly_360_normalizes_to_zero():
    board = _load()
    board["components"][0]["rotation_deg"] = 360
    result = ao.build_cpl(_compiled(board), "jlc")
    rows = {row.ref: row for row in result.rows}
    assert rows["R1"].rotation_deg == 0.0


def test_ref_containing_a_comma_is_csv_quoted():
    """Not a realistic board-yaml ref, but the CSV writer must not silently
    corrupt column alignment if one ever reaches this far — quoting is a
    property of the CSV layer, not of ref-string validation (which is a
    different module's job)."""
    result = ao.build_cpl(_compiled(_minimal(ref="R1,X")), "jlc")
    content = next(iter(result.values()))
    assert '"R1,X"' in content


def test_non_string_mpn_is_treated_as_missing_not_coerced():
    """assembly_spec's identity fold requires a str; an authored non-string mpn
    (e.g. a YAML int) is NOT stringified and accepted — it is treated as
    ABSENT, so the identity-refusal path fires rather than emitting a
    coerced/surprising value. Characterizes current behavior; a future unit
    may decide int-like mpns should coerce instead — that is a scope decision
    for whoever un-parks this, not an accident to preserve silently."""
    board = _load()
    board["components"][1]["mpn"] = 25804  # R2, int rather than "C25804"
    with pytest.raises(ao.AssemblyIdentityError, match="R2"):
        ao.build_bom(_compiled(board), "jlc")


def test_duplicate_refs_are_refused_before_any_row_is_emitted():
    """GAP CLOSED BY THE CUTOVER. The raw-dict path did not de-duplicate or
    validate ref uniqueness, so two components sharing a designator produced
    two CPL rows with the same Designator — almost certainly wrong for a real
    assembly order, and characterized here as a known gap rather than endorsed.

    Deriving from the compiled IR closes it for free: component ids are derived
    from the ref, so a duplicate breaks the board invariant and there is no CSV
    to be wrong."""
    board = _load()
    board["components"].append(dict(board["components"][0]))  # duplicate R1
    assert "board_invariant" in _compile_errors(board)


def test_blank_footprint_is_refused_rather_than_grouped_under_the_empty_string():
    """The other gap the cutover closes. The raw-dict path mirrored
    ``board_model.extract_bom``'s tolerance and grouped a blank footprint under
    the empty string, so a component with no footprint reached a house as a BOM
    line naming no part to place. The compiler requires a footprint ref before
    a component exists at all."""
    board = _load()
    board["components"][0]["footprint"] = ""
    assert "invalid_component" in _compile_errors(board)


def test_blank_value_still_groups_under_the_empty_string():
    """A blank VALUE is a different matter and stays tolerated: it is a
    legitimate way to author a part whose identity lives entirely in its mpn,
    and the compiler admits it. R1 simply stops grouping with R2."""
    board = _load()
    board["components"][0]["value"] = ""
    result = ao.build_bom(_compiled(board), "jlc")
    blank = next(row for row in result.rows if row.value == "")
    assert blank.refs == ("R1",)
