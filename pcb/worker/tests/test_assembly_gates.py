"""THE HARD GATES — every refusal must NAME the component and the field.

THE ORACLE, and it is a single one applied to every case below: a refusal that
fires without saying WHICH component and WHICH authored field is responsible has
failed, even though it refused. An order surface's whole job is to send the
author back to a line of YAML; "assembly export failed" sends them back to the
board. So :func:`_refusal` asserts the structured ``code`` / ``component`` /
``field`` AND that the component's own ref appears in the prose, for every gate,
rather than each case asserting whatever it happens to find convenient.

BOTH EMITTERS, EVERY GATE. Each refusal case is parametrized over ``build_bom``
AND ``build_cpl``: the gates run inside the one shared walk both files come out
of, so asking for only the BOM cannot dodge a fault that would have shown up in
the CPL. That is the property, not an incidental symmetry.

BOARDS ARE BUILT FROM REAL LIBRARY FOOTPRINTS and strictly compiled — no stub
IR, no hand-made ResolvedComponent. A gate that only refuses a synthetic object
is not a gate an order ever meets.
"""

from __future__ import annotations

import copy
from dataclasses import replace

import pytest

from pcb_worker import assembly_gates as ag, assembly_outputs as ao, methods
from pcb_worker.compile_board import compile_board
from pcb_worker.resolved_board import DiagnosticSeverity, ResolutionSuccess

EMITTERS = [ao.build_bom, ao.build_cpl]

# R_0805 is SMD and its footprint puts paste on both lands (the paste gate needs
# a part with a paste decision to make); PinSocket_1x07 is through-hole and puts
# paste on none (the same gate must NOT fire on it).
SMD = "R_0805"
THROUGH_HOLE = "Connector_PinSocket_2.54mm:PinSocket_1x07_P2.54mm_Vertical"
#: Silk-only board furniture: no fab outline, no sized land, so its anchor falls
#: all the way through the basis ladder to the footprint origin.
UNMEASURABLE = "Minerva_Fixture:TXT_CouponRev"


def _component(ref: str, x_mm: float, y_mm: float, footprint: str = SMD, **assembly):
    block = {"mpn": "C25804"}
    block.update(assembly)
    return {"ref": ref, "footprint": footprint, "value": "10k",
            "x_mm": x_mm, "y_mm": y_mm, "rotation_deg": 0, "layer": "top",
            "assembly": block}


def _board(*components) -> dict:
    return {
        "version": 1, "name": "gates", "width_mm": 120, "height_mm": 60,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.25,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": list(components),
    }


def _compiled(board: dict):
    result = compile_board(copy.deepcopy(board))
    if not isinstance(result, ResolutionSuccess):
        raise AssertionError(
            "gate fixture did not compile: "
            + ", ".join(f"{d.code}: {d.message}" for d in result.diagnostics
                        if d.severity is DiagnosticSeverity.ERROR))
    return result.board


def _refusal(emit, board: dict, code: str, component: str, field: str,
             profile_id: str = "jlc"):
    """Emit, expect a NAMED refusal, and apply the module's one oracle to it."""
    with pytest.raises(ValueError) as caught:
        emit(_compiled(board), profile_id)
    error = caught.value
    assert getattr(error, "code", None) == code, (
        f"expected refusal code {code!r}, got {getattr(error, 'code', None)!r}: {error}")
    assert getattr(error, "component", None) == component, (
        f"refusal {code} must NAME the component {component!r}, named "
        f"{getattr(error, 'component', None)!r}")
    assert getattr(error, "field", None) == field, (
        f"refusal {code} must NAME the field {field!r}, named "
        f"{getattr(error, 'field', None)!r}")
    assert component in str(error), (
        f"refusal {code} names {component!r} structurally but not in its prose, "
        f"which is what a human actually reads: {error}")
    return error


# ---------------------------------------------------------------------------
# Per-component gates.
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("emit", EMITTERS)
def test_do_not_populate_smd_with_automatic_paste_refuses(emit):
    """The paste policy's whole point: a part nobody places, whose lands would
    still take solder paste, with the decision never authored."""
    board = _board(_component("R1", 10, 10),
                   _component("R2", 20, 10, populate=False))
    error = _refusal(emit, board, ag.CODE_PASTE_UNDECIDED, "R2", "assembly.paste")
    assert "include" in str(error) and "exclude" in str(error), (
        "the refusal has to say what to author instead, not only that something "
        "is missing")


@pytest.mark.parametrize("emit", EMITTERS)
@pytest.mark.parametrize("paste", ["include", "exclude"])
def test_do_not_populate_smd_with_an_authored_paste_policy_emits(emit, paste):
    """The other side of the same gate: once the question is answered, either
    answer is accepted. Without this the gate would be indistinguishable from
    "do-not-populate SMD parts are banned"."""
    board = _board(_component("R1", 10, 10),
                   _component("R2", 20, 10, populate=False, paste=paste))
    result = emit(_compiled(board), "jlc")
    assert result.excluded_refs == ("R2",)


@pytest.mark.parametrize("emit", EMITTERS)
def test_do_not_populate_through_hole_does_not_need_a_paste_policy(emit):
    """The gate keys on whether the part's lands actually take paste, not on
    ``pad_type``: a through-hole socket whose footprint declares no paste layer
    has nothing to decide, and refusing it would be a false alarm on every
    hand-soldered header a board marks do-not-populate."""
    board = _board(_component("R1", 10, 10),
                   _component("J1", 40, 10, footprint=THROUGH_HOLE, populate=False))
    result = emit(_compiled(board), "jlc")
    assert result.excluded_refs == ("J1",)


@pytest.mark.parametrize("emit", EMITTERS)
def test_authored_but_empty_expansion_refuses(emit):
    """``placements: []`` resolves back to one implicit part under the
    component's own ref, so without this gate the board would ship as though the
    expansion had never been authored."""
    board = _board(_component("U1S", 10, 10, placements=[]))
    _refusal(emit, board, ag.CODE_EMPTY_EXPANSION, "U1S", "assembly.placements")


@pytest.mark.parametrize("emit", EMITTERS)
def test_per_component_refusal_names_every_component_carrying_the_fault(emit):
    """One refusal, all offenders. A board migrated from the pre-block
    ``assembly: exclude`` scalar can carry the same fault on a dozen fiducials at
    once, and one-at-a-time refusals would make fixing it a dozen compiles."""
    board = _board(_component("R1", 10, 10, populate=False),
                   _component("R2", 20, 10, populate=False),
                   _component("R3", 30, 10, populate=False))
    error = _refusal(emit, board, ag.CODE_PASTE_UNDECIDED, "R1", "assembly.paste")
    assert error.refs == ("R1", "R2", "R3")
    assert "'R2'" in str(error) and "'R3'" in str(error)


# ---------------------------------------------------------------------------
# Board-wide gates.
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("emit", EMITTERS)
def test_case_folding_designator_collision_refuses(emit):
    """An assembly house's uploader does not distinguish case, so ``R1`` and
    ``r1`` reaching one order is a coin toss over which part gets placed. Every
    check upstream compares refs EXACTLY — the compiler's own
    ``duplicate_component_ref`` and the Go validator's
    ``duplicate_assembly_designator`` alike — so a collision that only appears
    after case-folding reaches the emitters unrefused, and this gate is the only
    thing standing between it and an order."""
    board = _board(_component("R1", 10, 10), _component("r1", 20, 10))
    error = _refusal(emit, board, ag.CODE_DUPLICATE_DESIGNATOR, "r1", "ref")
    assert error.refs == ("R1", "r1")


@pytest.mark.parametrize("emit", EMITTERS)
def test_expansion_designator_colliding_with_another_component_refuses(emit):
    """The collision that matters most in practice: an authored expansion ref
    that is already some other drawing's designator."""
    board = _board(_component("R1", 10, 10),
                   _component("U1S", 30, 10, placements=[
                       {"ref": "U1S_A", "offset_mm": {"x": 0, "y": 0}},
                       {"ref": "r1", "offset_mm": {"x": 5, "y": 0}}]))
    _refusal(emit, board, ag.CODE_DUPLICATE_DESIGNATOR, "U1S", "ref")


@pytest.mark.parametrize("emit", EMITTERS)
def test_expansion_placed_on_top_of_itself_refuses(emit):
    """Two designators in one place. The ordinary cause is exactly this: an
    expansion authored without an ``offset_mm``, which emits two CPL rows at the
    same coordinate and reads as a perfectly legitimate order."""
    board = _board(_component("U1S", 10, 10, placements=[
        {"ref": "U1S_A"}, {"ref": "U1S_B"}]))
    error = _refusal(emit, board, ag.CODE_PLACEMENTS_TOO_CLOSE, "U1S",
                     "assembly.placements[].offset_mm")
    assert set(error.refs) == {"U1S_A", "U1S_B"}
    assert str(ag.DEFAULT_MIN_DESIGNATOR_SEPARATION_MM) in str(error)


@pytest.mark.parametrize("emit", EMITTERS)
def test_separated_expansion_emits(emit):
    """The same board with the offset authored: the separation gate is about
    coincident parts, not about expansions."""
    board = _board(_component("U1S", 10, 10, placements=[
        {"ref": "U1S_A", "offset_mm": {"x": 0, "y": 0}},
        {"ref": "U1S_B", "offset_mm": {"x": 22.86, "y": 0}}]))
    result = emit(_compiled(board), "jlc")
    refs = ({ref for row in result.rows for ref in row.refs}
            if emit is ao.build_bom else {row.ref for row in result.rows})
    assert refs == {"U1S_A", "U1S_B"}


@pytest.mark.parametrize("emit", EMITTERS)
def test_missing_profile_required_identity_refuses(emit):
    """Already enforced by the emitters' own identity contract before this gate
    module existed — pinned here so the refusal vocabulary stays uniform: it
    carries the same structured code / component / field a gate does."""
    board = _board(_component("R1", 10, 10))
    board["components"][0]["assembly"].pop("mpn")
    _refusal(emit, board, "assembly_missing_identity", "R1", "assembly.mpn")


def test_reference_sets_are_equal_on_every_board_that_emits():
    """The BOM/CPL equality gate has no authored way to fail — both files come
    out of ONE walk — so what is provable is the invariant itself, over a board
    exercising every row shape at once: an expansion, a do-not-populate part, and
    two components grouping onto one BOM row."""
    board = _board(
        _component("R1", 10, 10), _component("R2", 20, 10),
        _component("R3", 30, 10, populate=False, paste="exclude"),
        _component("U1S", 50, 10, placements=[
            {"ref": "U1S_A", "offset_mm": {"x": 0, "y": 0}},
            {"ref": "U1S_B", "offset_mm": {"x": 22.86, "y": 0}}]))
    compiled = _compiled(board)
    bom = ao.build_bom(compiled, "jlc")
    cpl = ao.build_cpl(compiled, "jlc")
    assert sorted(ref for row in bom.rows for ref in row.refs) == \
        sorted(row.ref for row in cpl.rows)
    # And the gate itself refuses when handed rows that disagree, which is the
    # only way to prove it would catch a future divergence between the two
    # renderers.
    with pytest.raises(ag.AssemblyGateError) as caught:
        ag.check_reference_sets(bom.rows, cpl.rows[:-1])
    assert caught.value.code == ag.CODE_REFERENCE_SET_MISMATCH
    assert cpl.rows[-1].ref in str(caught.value)


# ---------------------------------------------------------------------------
# Profile-supplied parameters — the thresholds are DATA, not constants.
# ---------------------------------------------------------------------------


def test_row_designator_cap_comes_from_the_profile():
    """The cap is a dialect fact a house publishes, so the gate has to read it
    off the selected profile. Proven by moving the limit either side of one
    board's actual row width rather than by asserting a number: a hard-coded 200
    would pass a test that only checked the default."""
    board = _board(*[_component(f"R{i + 1}", 5 + i * 6.0, 10) for i in range(6)])
    compiled = _compiled(board)
    # The profile ID is left alone on purpose: the CSV renderer is selected by
    # id, so a renamed profile would refuse for want of a renderer instead of
    # exercising the cap. Only the parameter under test moves.
    tight = replace(ao.PROFILES["jlc"], max_refs_per_row=5)
    roomy = replace(ao.PROFILES["jlc"], max_refs_per_row=6)
    try:
        ao.PROFILES["tight"], ao.PROFILES["roomy"] = tight, roomy
        with pytest.raises(ag.AssemblyGateError) as caught:
            ao.build_bom(compiled, "tight")
        assert caught.value.code == ag.CODE_ROW_REF_LIMIT
        assert caught.value.field == "max_refs_per_row"
        # The refusal names the row that overflowed and both of its ends, so the
        # author knows which line of the CSV to split.
        assert "R1" in str(caught.value) and "R6" in str(caught.value)
        assert len(ao.build_bom(compiled, "roomy").rows) == 1
    finally:
        ao.PROFILES.pop("tight", None)
        ao.PROFILES.pop("roomy", None)
    # The SHIPPED profile still carries the documented default, so raising the
    # limit in a test cannot quietly become the product's answer.
    assert ao.PROFILES["jlc"].max_refs_per_row == ag.DEFAULT_MAX_REFS_PER_ROW
    assert (ao.PROFILES["jlc"].min_designator_separation_mm
            == ag.DEFAULT_MIN_DESIGNATOR_SEPARATION_MM)


def test_a_non_metric_profile_dialect_refuses():
    """The CPL renderer writes bare millimetre numbers. A profile stating any
    other coordinate unit would have those numbers read as that unit — so the
    dialect refuses rather than the emitter silently disagreeing with it.

    The board schema is millimetre-by-construction (every coordinate key is
    ``_mm``-suffixed and there is no units field), so no BOARD can reach this:
    it guards the profile, which is the only place a unit is stated at all."""
    board = _board(_component("R1", 10, 10))
    compiled = _compiled(board)
    imperial = replace(ao.PROFILES["jlc"], id="imperial", coordinate_unit="inch")
    try:
        ao.PROFILES["imperial"] = imperial
        for emit in EMITTERS:
            with pytest.raises(ag.AssemblyGateError) as caught:
                emit(compiled, "imperial")
            assert caught.value.code == ag.CODE_NON_METRIC_COORDINATES
            assert caught.value.field == "coordinate_unit"
            assert "imperial" in str(caught.value)
    finally:
        ao.PROFILES.pop("imperial", None)


# ---------------------------------------------------------------------------
# Advisories — reported, never refused — and what a caller actually sees.
# ---------------------------------------------------------------------------


def test_unmeasurable_body_on_a_populated_part_is_an_advisory_not_a_refusal():
    """A populated part whose footprint draws neither a fab body outline nor a
    sized land has no measurable centre, so its emitted coordinate is the drawn
    origin. That is worth SAYING and not worth refusing: the same footprint is
    legitimate as silk-only furniture, and a board is allowed to populate one."""
    board = _board(_component("R1", 10, 10),
                   _component("TXT1", 40, 10, footprint=UNMEASURABLE),
                   _component("TXT2", 60, 10, footprint=UNMEASURABLE,
                              populate=False))
    result = ao.build_bom(_compiled(board), "jlc")
    codes = [a["code"] for a in result.advisories]
    assert codes == [ag.ADVISORY_ANCHOR_UNMEASURED], (
        "exactly the POPULATED unmeasurable part is advised about — the "
        "do-not-populate one is furniture, which is the case the ladder's "
        "footprint_origin rung exists for")
    advisory = result.advisories[0]
    assert advisory["component"] == "TXT1"
    assert advisory["refs"] == ["TXT1"]
    assert "TXT1" in advisory["message"]


def test_the_dispatch_surface_carries_codes_advisories_and_exclusions():
    """WHAT A CALLER SEES, at the surface an agent and the panel both go
    through. A refusal arrives as a structured payload it can point at; a success
    carries both honest-outcome lists, absent when empty."""
    good = _board(_component("R1", 10, 10),
                  _component("TXT1", 40, 10, footprint=UNMEASURABLE),
                  _component("R3", 60, 10, populate=False, paste="exclude"))
    reply = methods._assembly_bom({"board": copy.deepcopy(good)})
    assert reply["ok"], reply
    result = reply["result"]
    assert result["excluded_components"] == ["R3"]
    assert [a["code"] for a in result["advisories"]] == [ag.ADVISORY_ANCHOR_UNMEASURED]

    clean = methods._assembly_cpl({"board": _board(_component("R1", 10, 10))})
    assert clean["ok"], clean
    assert "advisories" not in clean["result"], "absent when empty, not an empty list"
    assert "excluded_components" not in clean["result"]

    bad = _board(_component("R1", 10, 10), _component("r1", 20, 10))
    refused = methods._assembly_cpl({"board": bad})
    assert refused["ok"] is False
    error = refused["error"]
    assert error["kind"] == "assembly"
    assert error["code"] == ag.CODE_DUPLICATE_DESIGNATOR
    assert error["component"] == "r1"
    assert error["field"] == "ref"
    assert error["refs"] == ["R1", "r1"]


# ---------------------------------------------------------------------------
# What is enforced UPSTREAM, pinned here so the gate module is not re-grown to
# duplicate it.
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("bad_offset", [float("inf"), float("nan")])
def test_a_non_finite_transform_is_refused_before_an_emitter_sees_it(bad_offset):
    """Non-finite transforms never reach the gates: the assembly-spec reader
    refuses them at COMPILE, naming the component and the exact key, under the
    same ``invalid_component_assembly`` code the Go codec uses. An order surface
    sees that as the named uncompilable-board refusal with the component in its
    ``blocked_by`` list — which is why there is no finiteness check in
    assembly_gates to keep in sync with this one."""
    board = _board(_component("U1S", 10, 10, placements=[
        {"ref": "U1S_A", "offset_mm": {"x": bad_offset, "y": 0}}]))
    result = compile_board(board)
    assert not isinstance(result, ResolutionSuccess)
    errors = [d for d in result.diagnostics if d.severity is DiagnosticSeverity.ERROR]
    assert [d.code for d in errors] == ["invalid_component_assembly"]
    assert "U1S" in errors[0].message and "offset_mm" in errors[0].message

    reply = methods._assembly_bom({"board": board})
    assert reply["ok"] is False
    error = reply["error"]
    assert error["kind"] == ao.NOT_COMPILABLE_KIND
    assert [b["entity_id"] for b in error["blocked_by"]] == ["U1S"]
