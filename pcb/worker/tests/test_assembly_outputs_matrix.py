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


def _board_for(profile: ao.HouseProfile) -> dict:
    """The fixture, adjusted to whatever the profile CLAIMS.

    A profile that selects a service tier checks the board against that
    manufacturer, and the shared fixture is deliberately not orderable from one:
    it takes the compiler's default floor and populates its diode on the bottom
    side. Both are properties this matrix is not about, so they are corrected
    here rather than weakening the fixture the emitter seals depend on."""
    board = _load()
    service = profile.service
    if service is None:
        return board
    board["design_rules"]["rule_profile"] = service.fab_profile
    sides = set(service.constraints.assembly_sides)
    for component in board["components"]:
        if component.get("layer") not in sides:
            component["layer"] = sorted(sides)[0]
    return board


@pytest.mark.parametrize("profile_id", sorted(ao.PROFILES))
@pytest.mark.parametrize("emit", [ao.build_bom, ao.build_cpl])
def test_profile_matrix_supports_or_refuses_by_capability(profile_id, emit):
    """Every KNOWN profile either emits (supports_assembly) or refuses BY
    NAME (not supports_assembly) — never a third outcome (a crash, a silent
    partial file, or a refusal that doesn't name the house)."""
    profile = ao.PROFILES[profile_id]
    board = _compiled(_board_for(profile))
    if profile.supports_assembly:
        result = emit(board, profile_id)
        assert len(result) == 1
    else:
        with pytest.raises(ao.AssemblyProfileError, match=profile.display_name):
            emit(board, profile_id)


def test_every_assembly_capable_profile_has_a_renderer_wired():
    """A profile declared supports_assembly=True whose DIALECT has no entry in
    the renderer table refuses with "no renderer wired" — catching that class of
    authoring mistake without needing a second live house to actually stand up.
    The table keys on the dialect rather than the selector, so a new tier of a
    house we already render needs no new entry and a genuinely new house does;
    this is the tripwire for the second case."""
    for profile_id, profile in ao.PROFILES.items():
        if not profile.supports_assembly:
            continue
        board = _compiled(_board_for(profile))
        ao.build_bom(board, profile_id)
        ao.build_cpl(board, profile_id)


# ---------------------------------------------------------------------------
# Generic multi-field identity contract (jlc only requires ``mpn`` today; the
# CORE mechanism (_check_identity) is house-agnostic and should hold for a
# hypothetical profile requiring more than one field).
# ---------------------------------------------------------------------------


def test_a_profile_cannot_require_a_field_the_identity_model_lacks():
    """The requirement set is CLOSED over what the resolved assembly actually
    carries. A profile asking for ``distributor_pn`` — a field no board can put
    on a ResolvedAssembly — could never be satisfied by any board, so it refuses
    where it is WRITTEN rather than silently refusing every export that selected
    it. The refusal names the offending field and the set that is available."""
    with pytest.raises(ao.AssemblyProfileError) as exc_info:
        replace(ao.PROFILES["jlc"], identity_required=("mpn", "distributor_pn"))
    message = str(exc_info.value)
    assert "distributor_pn" in message
    assert "mpn" in message  # the known set is spelled out, not just the fault


def test_identity_refusal_names_every_missing_field_not_just_the_first():
    """The fixture supplies ``mpn`` for every component and ``manufacturer``
    for R1 alone, so a profile requiring BOTH isolates the "every missing field
    is named, not just the first" claim: the refusal must name R2's missing
    manufacturer and must NOT name mpn, which R2 has."""
    two_field_profile = replace(
        ao.PROFILES["jlc"], identity_required=("mpn", "manufacturer"))
    ao.PROFILES["synthetic-two-field"] = two_field_profile
    try:
        board = _compiled(_load())
        with pytest.raises(ao.AssemblyIdentityError) as exc_info:
            ao.build_bom(board, "synthetic-two-field")
        message = str(exc_info.value)
        missing = message.split("identity field(s) ")[1].split(" for")[0]
        assert missing == "manufacturer"
        assert "R2" in message  # R1 carries both and passes; R2 is the first fault
    finally:
        del ao.PROFILES["synthetic-two-field"]


def test_identity_satisfied_when_all_required_fields_present():
    # NOTE: the copy keeps jlc's renderer (only identity_required is widened),
    # so it renders through the same dialect; a genuinely new house needs its
    # own renderer entry (see test_every_assembly_capable_profile_has_a_
    # renderer_wired above), which is a SEPARATE claim from this one.
    two_field_profile = replace(
        ao.PROFILES["jlc"], identity_required=("mpn", "manufacturer"))
    ao.PROFILES["synthetic-two-field"] = two_field_profile
    try:
        board = _load()
        for comp in board["components"]:
            comp.setdefault("assembly", {})
            if isinstance(comp["assembly"], dict):
                comp["assembly"]["manufacturer"] = f"MFR-{comp['ref']}"
        result = ao.build_bom(_compiled(board), "synthetic-two-field")
        # Every component now carries its own manufacturer, which is part of no
        # emitted column, so the grouping is the fixture's usual two rows.
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


def test_non_string_mpn_refuses_by_name_rather_than_being_coerced():
    """assembly_spec's identity fold requires a str, and an authored non-string
    mpn (e.g. a YAML int) is neither stringified nor dropped: it REFUSES at
    compile, naming the component and the key, so no emitter is reached.

    The scope decision this pins was made deliberately — an unquoted YAML value
    is parsed before the reader sees it and the parse is not reversible
    (``package: 0603`` arrives as 387), so treating it as absent shipped an
    identity nobody authored. The property the earlier "treated as missing"
    characterization was protecting still holds and is what the last assertion
    checks: the authored digits never come back as a plausible coerced string.
    The ``package`` twin of this refusal, followed all the way to an order
    surface's ``blocked_by``, is in test_assembly_gates.py."""
    board = _load()
    board["components"][1]["mpn"] = 25804  # R2, int rather than "C25804"
    result = compile_board(board)
    assert not isinstance(result, ResolutionSuccess)
    named = [d for d in result.diagnostics
             if d.severity is DiagnosticSeverity.ERROR
             and d.code == "invalid_component_assembly"]
    assert len(named) == 1
    assert "R2" in named[0].message and "mpn" in named[0].message

    # Nothing coerced the int into an identity: the value appears only as the
    # int the author wrote, inside the refusal that names it.
    assert "25804 (int)" in named[0].message
    assert "'25804'" not in named[0].message


def test_duplicate_component_refs_refuse_by_name_naming_the_designator():
    """Two components under one designator is a common authoring mistake and
    gets an ACTIONABLE refusal: the compiler names the ref, upstream of any
    emitter, so no CSV exists to be wrong. It used to surface as the late,
    generic ``board_invariant`` — true but silent about which designator was
    authored twice."""
    board = _load()
    board["components"].append(dict(board["components"][0]))  # duplicate R1
    result = compile_board(board)
    assert not isinstance(result, ResolutionSuccess)
    errors = [d for d in result.diagnostics if d.severity is DiagnosticSeverity.ERROR]
    codes = {d.code for d in errors}
    assert "duplicate_component_ref" in codes
    assert "board_invariant" not in codes  # named upstream, not by the late invariant
    named = next(d for d in errors if d.code == "duplicate_component_ref")
    assert "R1" in named.message


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
    blank = next(row for row in result.rows if row.comment == "")
    assert blank.refs == ("R1",)
