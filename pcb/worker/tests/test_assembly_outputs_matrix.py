"""PARKED — assembly_outputs (BOM/CPL) profile-matrix + edge cases (epoch C,
unit C8, docket 019f763cdf5b).

NOT COLLECTED. The filename has no ``test_`` prefix, and ``pyproject.toml``
sets ``testpaths = ["tests"]`` with no ``python_files`` override, so pytest's
default ``test_*.py`` / ``*_test.py`` patterns never see this file — locally
or in ``.github/workflows/pcb.yml`` (``python -m pytest tests/ -q``). It is
authored now and EXECUTED at the epoch boundary, when it is renamed to
``test_assembly_outputs_matrix.py``. Until then it must stay ``py_compile``
clean, which is the only gate it is held to.

WHY THIS IS PARKED, NOT AN EXECUTABLE SEAL
-------------------------------------------
The load-bearing proofs for C8 (hand-derived CPL rows, BOM grouping,
identity-refusal, house-refusal, byte-determinism) already ship as EXECUTABLE
seals in ``test_assembly_outputs.py`` + a data-row addition to
``test_determinism_gate.py``. What's below is breadth, not depth: every
profile crossed with every emit function, and edge inputs no single seal
needs to carry. None of it changes the unit's acceptance; it widens the net
for the epoch boundary pass.
"""

from __future__ import annotations

from dataclasses import replace
from pathlib import Path

import pytest
import yaml

from pcb_worker import assembly_outputs as ao

FIXTURE = (Path(__file__).resolve().parent / "testdata" / "assembly_boards"
          / "assembly_fixture.yaml")


def _load() -> dict:
    return yaml.safe_load(FIXTURE.read_text(encoding="utf-8"))


# ---------------------------------------------------------------------------
# Profile matrix — every shipped PROFILES entry x every emit function.
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("profile_id", sorted(ao.PROFILES))
@pytest.mark.parametrize("emit", [ao.build_bom, ao.build_cpl])
def test_profile_matrix_supports_or_refuses_by_capability(profile_id, emit):
    """Every KNOWN profile either emits (supports_assembly) or refuses BY
    NAME (not supports_assembly) — never a third outcome (a crash, a silent
    partial file, or a refusal that doesn't name the house)."""
    board = _load()
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
    board = _load()
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
        board = _load()
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
        result = ao.build_bom(board, "synthetic-two-field")
        assert len(result.rows) == 2
    finally:
        del ao.PROFILES["synthetic-two-field"]


# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------


def test_zero_components_emits_header_only_csv():
    board = _load()
    board["components"] = []
    bom = ao.build_bom(board, "jlc")
    cpl = ao.build_cpl(board, "jlc")
    assert next(iter(bom.values())) == "Comment,Designator,Footprint,LCSC Part #\r\n"
    assert next(iter(cpl.values())) == "Designator,Mid X,Mid Y,Layer,Rotation\r\n"
    assert bom.rows == []
    assert cpl.rows == []


def test_rotation_exactly_360_normalizes_to_zero():
    board = _load()
    board["components"][0]["rotation_deg"] = 360
    result = ao.build_cpl(board, "jlc")
    rows = {row.ref: row for row in result.rows}
    assert rows["R1"].rotation_deg == 0.0


def test_ref_containing_a_comma_is_csv_quoted():
    """Not a realistic board-yaml ref, but the CSV writer must not silently
    corrupt column alignment if one ever reaches this far — quoting is a
    property of the CSV layer, not of ref-string validation (which is a
    different module's job)."""
    board = _load()
    board["components"][0]["ref"] = "R1,X"
    result = ao.build_cpl(board, "jlc")
    content = next(iter(result.values()))
    assert '"R1,X"' in content


def test_non_string_mpn_is_treated_as_missing_not_coerced():
    """`_component_property` requires a str; an authored non-string mpn
    (e.g. a YAML int) is NOT stringified and accepted — it is treated as
    ABSENT, so the identity-refusal path fires rather than emitting a
    coerced/surprising value. Characterizes current behavior; a future unit
    may decide int-like mpns should coerce instead — that is a scope decision
    for whoever un-parks this, not an accident to preserve silently."""
    board = _load()
    board["components"][0]["mpn"] = 25804  # int, not "C25804"
    with pytest.raises(ao.AssemblyIdentityError, match="R1"):
        ao.build_bom(board, "jlc")


def test_duplicate_refs_both_appear_as_separate_cpl_rows():
    """assembly_outputs does not de-duplicate or validate ref uniqueness
    (board_validate.validate_board_v2 is a SEPARATE, not-invoked gate on this
    path — see assembly_outputs.py's module docstring on operating over the
    raw dict). Two components sharing a ref today produce two CPL rows with
    the same Designator, which is almost certainly wrong for a real
    assembly order. Characterization test, not an endorsement: flags the gap
    for the epoch boundary rather than leaving it silently unexercised."""
    board = _load()
    board["components"].append(dict(board["components"][0]))  # duplicate R1
    result = ao.build_cpl(board, "jlc")
    refs = [row.ref for row in result.rows]
    assert refs.count("R1") == 2


def test_blank_footprint_and_value_group_together_like_extract_bom():
    """Mirrors board_model.extract_bom's stance (an unpopulated footprint/
    value is a legitimate DNP, not a hard error) — as long as identity
    (mpn) is still present, a blank footprint/value groups under the empty
    string exactly like extract_bom's own ``(footprint, value)`` key does."""
    board = _load()
    board["components"][0]["footprint"] = ""
    board["components"][0]["value"] = ""
    # R1 no longer groups with R2 (different footprint key now).
    result = ao.build_bom(board, "jlc")
    assert len(result.rows) == 3
    blank = next(row for row in result.rows if row.footprint == "")
    assert blank.refs == ("R1",)
