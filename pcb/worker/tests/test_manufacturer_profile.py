"""K21 (docket 019f762004dc) — pinned, fail-closed board-house profiles.

The manufacturing floor used to be one hardcoded dict
(``compile_board._V1_MANUFACTURING_FLOOR``). This unit replaces it with a
LOADABLE profile (``manufacturer_profile.load_rule_profile``): a board
selects a board-house id via ``design_rules.rule_profile`` and the compiler
resolves it through the same fail-closed path every profile takes -- no
separate "use the hardcoded default" branch, no silent fall back to v1 when
a DIFFERENT profile was requested and failed to load, and no merge of a
partial profile's missing fields from anywhere else.

Covers, at the LOADER level (this file) and the COMPILER level
(``test_compile_board.py``/``test_drc_geometric.py``):
  * a well-formed profile loads to a complete, pinned floor;
  * unknown id, unreadable file, malformed JSON, non-object floor, a floor
    missing ANY of the ten fields, an extra/unrecognized floor field, a
    non-numeric value, and an id/filename mismatch all fail CLOSED
    (``RuleProfileError``), never a partial or merged result;
  * the two shipped profiles (v1, OSH Park) each load to their own complete,
    independently-digested floor.
"""

from __future__ import annotations

import json
from dataclasses import fields

import pytest

from pcb_worker.manufacturer_profile import (
    ALLOWED_TOP_LEVEL_FIELDS,
    DEFAULT_PROFILE_ROOT,
    OPTIONAL_FLOOR_FIELDS,
    REQUIRED_FLOOR_FIELDS,
    LoadedRuleProfile,
    RuleProfileError,
    load_rule_profile,
)
from pcb_worker.resolved_board import ManufacturingConstraints, RuleProfileRef


# ---------------------------------------------------------------------------
# Well-formed shipped profiles.
# ---------------------------------------------------------------------------


def test_v1_profile_loads_to_a_complete_pinned_floor():
    loaded = load_rule_profile("v1-fab-conservative")
    assert isinstance(loaded, LoadedRuleProfile)
    assert isinstance(loaded.ref, RuleProfileRef)
    assert loaded.ref.id == "v1-fab-conservative"
    assert loaded.ref.version == "1"
    assert len(loaded.ref.digest) == 64
    assert isinstance(loaded.floor, ManufacturingConstraints)
    # The exact numbers formerly hardcoded in compile_board._V1_MANUFACTURING_FLOOR.
    assert loaded.floor.min_trace_width_mm == 0.127
    assert loaded.floor.min_clearance_mm == 0.127
    assert loaded.floor.min_drill_mm == 0.2
    assert loaded.floor.min_finished_hole_mm == 0.2
    assert loaded.floor.min_annular_ring_mm == 0.13
    assert loaded.floor.min_hole_to_hole_mm == 0.25
    assert loaded.floor.min_mask_sliver_mm == 0.1
    assert loaded.floor.solder_mask_clearance_mm == 0.05
    assert loaded.floor.solder_mask_expansion_mm == 0.0
    assert loaded.floor.copper_to_edge_mm == 0.3


def test_oshpark_profile_loads_to_a_complete_pinned_floor_distinct_from_v1():
    loaded = load_rule_profile("oshpark-2layer")
    assert loaded.ref.id == "oshpark-2layer"
    assert len(loaded.ref.digest) == 64
    v1 = load_rule_profile("v1-fab-conservative")
    assert loaded.ref.digest != v1.ref.digest
    # OSH Park's published 2-layer trace width/spacing (6 mil == 0.1524mm) is
    # stricter (larger) than v1's 0.127mm -- the discriminating axis the
    # compiler-level two-profile test exercises.
    assert loaded.floor.min_trace_width_mm == pytest.approx(0.1524)
    assert loaded.floor.min_trace_width_mm > v1.floor.min_trace_width_mm


def test_shipped_profile_root_holds_exactly_the_shipped_profiles():
    # Not a completeness guarantee for all time, just pins today's shipped
    # set so an accidental extra/missing file is noticed. jlcpcb-2layer
    # joined in epoch CPN1 (docket 019fe2fb1e76); jlcpcb-4layer in epoch GA-1.
    names = sorted(p.stem for p in DEFAULT_PROFILE_ROOT.glob("*.json"))
    assert names == ["jlcpcb-2layer", "jlcpcb-4layer",
                     "oshpark-2layer", "v1-fab-conservative"]


def test_jlcpcb_profile_loads_to_a_complete_pinned_floor():
    """The epoch CPN1 profile: JLCPCB 2-layer standard, values quoted from the
    published capabilities page (see the profile's source field). The two
    discriminating axes vs the other shipped profiles: the loosest published
    trace floor (0.10 vs 0.127/0.1524) and the FIRST shipped profile to
    DECLARE the optional hole-to-copper field (0.28, from the published
    PTH-to-track minimum — enforcement today is the pour carve only; the
    hole-to-TRACK geometric check is a filed gap, see the profile's
    ENFORCEMENT SCOPE source note)."""
    loaded = load_rule_profile("jlcpcb-2layer")
    assert loaded.ref.id == "jlcpcb-2layer"
    assert len(loaded.ref.digest) == 64
    floor = loaded.floor
    assert floor.min_trace_width_mm == pytest.approx(0.1)
    assert floor.min_clearance_mm == pytest.approx(0.1)
    assert floor.min_drill_mm == pytest.approx(0.15)
    assert floor.min_finished_hole_mm == pytest.approx(0.15)
    assert floor.min_annular_ring_mm == pytest.approx(0.18)
    # The PAD hole-to-hole figure, deliberately not the looser via-to-via 0.2
    # (single-field coarseness resolved fail-closed — see the source note).
    assert floor.min_hole_to_hole_mm == pytest.approx(0.45)
    assert floor.min_mask_sliver_mm == pytest.approx(0.1)
    assert floor.solder_mask_clearance_mm == pytest.approx(0.05)
    assert floor.solder_mask_expansion_mm == 0.0
    assert floor.copper_to_edge_mm == pytest.approx(0.2)
    assert floor.min_hole_to_copper_mm == pytest.approx(0.28)
    for other in ("v1-fab-conservative", "oshpark-2layer"):
        assert loaded.ref.digest != load_rule_profile(other).ref.digest


# ---------------------------------------------------------------------------
# Fail-closed: every defect shape raises RuleProfileError, never a partial
# or silently-merged result.
# ---------------------------------------------------------------------------


def _write_profile(tmp_path, name: str, payload) -> None:
    path = tmp_path / f"{name}.json"
    if isinstance(payload, str):
        path.write_text(payload, encoding="utf-8")
    else:
        path.write_text(json.dumps(payload), encoding="utf-8")


def _valid_floor() -> dict:
    return {
        "min_trace_width_mm": 0.2, "min_clearance_mm": 0.2, "min_drill_mm": 0.3,
        "min_finished_hole_mm": 0.3, "min_annular_ring_mm": 0.2,
        "min_hole_to_hole_mm": 0.3, "min_mask_sliver_mm": 0.15,
        "solder_mask_clearance_mm": 0.08, "solder_mask_expansion_mm": 0.01,
        "copper_to_edge_mm": 0.4,
    }


def test_unknown_profile_id_fails_closed(tmp_path):
    with pytest.raises(RuleProfileError, match="unknown rule profile"):
        load_rule_profile("no-such-house", library_root=tmp_path)


def test_malformed_json_fails_closed(tmp_path):
    _write_profile(tmp_path, "bad", "{not json")
    with pytest.raises(RuleProfileError, match="not valid JSON"):
        load_rule_profile("bad", library_root=tmp_path)


def test_non_object_top_level_fails_closed(tmp_path):
    _write_profile(tmp_path, "bad", [1, 2, 3])
    with pytest.raises(RuleProfileError, match="must be a JSON object"):
        load_rule_profile("bad", library_root=tmp_path)


def test_id_mismatch_between_filename_and_declared_id_fails_closed(tmp_path):
    _write_profile(tmp_path, "acme", {"id": "different-name", "version": "1",
                                       "floor": _valid_floor()})
    with pytest.raises(RuleProfileError, match="does not match the requested id"):
        load_rule_profile("acme", library_root=tmp_path)


def test_missing_version_fails_closed(tmp_path):
    _write_profile(tmp_path, "acme", {"id": "acme", "floor": _valid_floor()})
    with pytest.raises(RuleProfileError, match="version"):
        load_rule_profile("acme", library_root=tmp_path)


def test_non_object_floor_fails_closed(tmp_path):
    _write_profile(tmp_path, "acme", {"id": "acme", "version": "1", "floor": "loose"})
    with pytest.raises(RuleProfileError, match="no 'floor' mapping"):
        load_rule_profile("acme", library_root=tmp_path)


@pytest.mark.parametrize("missing_field", REQUIRED_FLOOR_FIELDS)
def test_a_floor_missing_any_single_field_fails_closed_not_merged(tmp_path, missing_field):
    """THE CENTRAL fail-closed contract (brief R2): a profile supplies EVERY
    required field or fails -- there is no fallback that fills the missing one
    from v1 or anywhere else. Parametrized over the tuple itself so no single
    site's check can be silently absent for one field (the exact shape that lost
    the min_finished_hole_mm enforcement site behind a shared alias upstream in
    drc_geometric -- this loader must not repeat it).

    Parametrizing over REQUIRED_FLOOR_FIELDS rather than a hand-written list is
    what let this test follow the CP2 S5 tier change with no edit: when
    solder_mask_expansion_mm was demoted it simply left the parametrisation.
    """
    floor = _valid_floor()
    del floor[missing_field]
    _write_profile(tmp_path, "acme", {"id": "acme", "version": "1", "floor": floor})
    with pytest.raises(RuleProfileError, match=f"missing field.*{missing_field}"):
        load_rule_profile("acme", library_root=tmp_path)


def test_every_required_floor_field_has_at_least_one_production_reader():
    """THE PROPERTY THAT MAKES "REQUIRED" MEAN SOMETHING, and the one epoch CP2
    exists to restore.

    The required tier's whole justification is that these fields are
    load-bearing, so a MISSING one must fail the load rather than be defaulted.
    That argument is hollow for any field nothing reads: the loader refuses a
    profile for omitting a number no code will ever consult. CP2 found FOUR such
    fields; S5 closed the last two by giving min_mask_sliver_mm a reader (GC8)
    and DEMOTING solder_mask_expansion_mm, which could not be given a correct
    one because the two shipped profiles use it for opposite ends of the process.

    This test is a SOURCE SCAN, deliberately, because the property is about the
    codebase rather than about any one run: a field is "read" if some production
    module outside the declaration and validation sites EXECUTABLY loads it.

    IT READS THE AST, NOT THE TEXT (CP2, Codex finding 6). The first version
    did a raw substring search, which a COMMENT or DOCSTRING satisfied — so the
    test that exists to catch "declared, required, never enforced" could itself
    be false-greened by prose describing the very field nothing enforces. That
    is the exact regression it guards, wearing the guard's own uniform.

    Measured when this was tightened: three modules mentioned required fields
    only in prose (compile_board.py for min_trace_width_mm, route_bridge.py for
    min_clearance_mm, pad_source.py for solder_mask_clearance_mm). All nine
    fields still have real readers elsewhere, so the tightening removed false
    credit without changing the verdict — which is the only kind of tightening
    worth making to a green test.

    Still coarse, and still meant to be: an attribute load proves the name is
    consulted somewhere, not that the consulting code is reachable or correct.
    What it catches is the regression that actually happened four times: a
    field declared, validated, required, and never referenced again.
    """
    import ast
    import pathlib

    from pcb_worker import manufacturer_profile

    pkg = pathlib.Path(manufacturer_profile.__file__).parent
    # The two files where a required field is DECLARED and VALIDATED. A mention
    # in either proves nothing about enforcement, so they are excluded.
    declaration_sites = {"resolved_board.py", "manufacturer_profile.py"}

    def executable_loads(text: str) -> set[str]:
        """Names this module actually READS at runtime.

        Three access forms, because a floor can legitimately be reached by any
        of them: attribute access (``minimums.min_drill_mm``, the convention),
        a string subscript (``floor["min_drill_mm"]``), and an explicit
        ``getattr(obj, "min_drill_mm")``. Comments never appear in an AST at
        all, and a docstring is a bare Expr constant rather than any of these,
        so prose cannot satisfy this.
        """
        names: set[str] = set()
        for node in ast.walk(ast.parse(text)):
            if isinstance(node, ast.Attribute):
                names.add(node.attr)
            elif isinstance(node, ast.Subscript) and \
                    isinstance(node.slice, ast.Constant) and \
                    isinstance(node.slice.value, str):
                names.add(node.slice.value)
            elif isinstance(node, ast.Call) and isinstance(node.func, ast.Name) \
                    and node.func.id == "getattr" and len(node.args) >= 2 \
                    and isinstance(node.args[1], ast.Constant) \
                    and isinstance(node.args[1].value, str):
                names.add(node.args[1].value)
        return names

    sources = {
        path.name: executable_loads(path.read_text(encoding="utf-8"))
        for path in pkg.glob("*.py")
        if path.name not in declaration_sites
    }

    unread = []
    for field in REQUIRED_FLOOR_FIELDS:
        readers = sorted(name for name, loaded in sources.items() if field in loaded)
        if not readers:
            unread.append(field)

    assert not unread, (
        "these REQUIRED floor fields have no production reader outside their "
        f"declaration/validation sites: {unread}. A required field nothing "
        "enforces is a rule that lies about being in force — either give it a "
        "reader, or move it to OPTIONAL_FLOOR_FIELDS with the reason recorded, "
        "as CP2 S5 did for solder_mask_expansion_mm")

    # SELF-CHECK: prove the scan can still FAIL, on this very corpus. A guard
    # whose detector has quietly stopped detecting is the failure mode this
    # epoch keeps finding, and "the assertion above passed" cannot distinguish
    # "every field has a reader" from "the matcher matches nothing".
    invented = "min_unobtainium_clearance_mm"
    assert not any(invented in loaded for loaded in sources.values()), (
        "the negative control is no longer negative — pick a name that really "
        "does not appear, or this test proves nothing")


def test_a_floor_with_an_extra_unknown_field_fails_closed(tmp_path):
    """An unknown floor key is REFUSED, never ignored: a profile naming a rule
    the schema does not implement has stated a constraint nothing will enforce,
    which is the fail-open this whole module exists to prevent.

    THE FIXTURE IS SELF-CHECKING, and it is that way because it silently rotted
    once. It used to spell the unknown field ``min_silk_width_mm`` — genuinely
    unknown when written, then ADDED to the optional tier by epoch CP2 S6, at
    which point the profile loaded successfully and this test could no longer
    pass. Worse than the red: between the schema change and its discovery, the
    fail-closed property here was guarded by nothing. The assertion below makes
    that failure mode loud instead of latent — if this name is ever implemented,
    the test says so in one line rather than dying inside a `pytest.raises`."""
    unknown = "min_unobtainium_clearance_mm"
    assert unknown not in {f.name for f in fields(ManufacturingConstraints)}, (
        f"{unknown} is now a real ManufacturingConstraints field, so it can no "
        f"longer stand in for an unknown one — pick another name")
    assert unknown not in REQUIRED_FLOOR_FIELDS + OPTIONAL_FLOOR_FIELDS

    floor = _valid_floor()
    floor[unknown] = 0.15
    _write_profile(tmp_path, "acme", {"id": "acme", "version": "1", "floor": floor})
    with pytest.raises(RuleProfileError, match="unknown field"):
        load_rule_profile("acme", library_root=tmp_path)


def test_a_non_numeric_floor_value_fails_closed(tmp_path):
    floor = _valid_floor()
    floor["min_drill_mm"] = "0.3"  # string, not a number
    _write_profile(tmp_path, "acme", {"id": "acme", "version": "1", "floor": floor})
    with pytest.raises(RuleProfileError, match="min_drill_mm"):
        load_rule_profile("acme", library_root=tmp_path)


def test_a_boolean_floor_value_is_rejected_not_coerced(tmp_path):
    # bool is a subclass of int in Python; True/False must not silently
    # become 1.0/0.0 mm.
    floor = _valid_floor()
    floor["copper_to_edge_mm"] = True
    _write_profile(tmp_path, "acme", {"id": "acme", "version": "1", "floor": floor})
    with pytest.raises(RuleProfileError, match="copper_to_edge_mm"):
        load_rule_profile("acme", library_root=tmp_path)


def test_allowed_top_level_fields_is_exactly_the_declared_set():
    # Pins the allow-list itself: symmetric with the floor-level guard, and
    # wide enough to admit ``source`` (every shipped profile carries one; see
    # test_a_profile_with_a_top_level_source_field_loads_cleanly below) and
    # the GA-1 ``capabilities`` tier without admitting anything else.
    assert ALLOWED_TOP_LEVEL_FIELDS == {
        "id", "version", "source", "floor", "capabilities"}


def test_a_profile_with_a_top_level_source_field_loads_cleanly(tmp_path):
    # ``source`` is legitimate provenance text nothing reads -- the allow-list
    # must NOT reject it (a blanket top-level rejection would break both
    # shipped profiles; this is that trap, reproduced against a synthetic
    # fixture rather than the real files).
    _write_profile(tmp_path, "acme", {
        "id": "acme", "version": "1", "source": "Acme Fab published rules v3",
        "floor": _valid_floor(),
    })
    loaded = load_rule_profile("acme", library_root=tmp_path)
    assert isinstance(loaded, LoadedRuleProfile)


def test_a_profile_with_an_unrecognized_top_level_field_fails_closed(tmp_path):
    _write_profile(tmp_path, "acme", {
        "id": "acme", "version": "1", "floor": _valid_floor(), "foo": "bar",
    })
    with pytest.raises(RuleProfileError, match="unknown top-level field.*foo"):
        load_rule_profile("acme", library_root=tmp_path)


def test_a_top_level_field_that_is_a_real_floor_constraint_name_still_fails_closed(tmp_path):
    """Discriminating fixture (brief): a rule authored ONE LEVEL TOO HIGH --
    ``min_annular_ring_mm`` is a real ManufacturingConstraints field name,
    present in ``floor`` where it belongs, but ALSO stray at the top level.
    A guard that only catches nonsense keys like ``foo`` but waves through a
    real field name in the wrong place is the exact silent-fail shape this
    brief exists to close: the author sees their rule in the JSON and
    believes it is enforced, when the top-level copy is never read."""
    floor = _valid_floor()
    payload = {
        "id": "acme", "version": "1", "floor": floor,
        "min_annular_ring_mm": 0.5,  # stray top-level copy of a real field
    }
    _write_profile(tmp_path, "acme", payload)
    with pytest.raises(RuleProfileError, match="unknown top-level field.*min_annular_ring_mm"):
        load_rule_profile("acme", library_root=tmp_path)


def test_whitespace_only_version_fails_closed(tmp_path):
    # A whitespace-only string is truthy in Python, so ``not version`` alone
    # waves it through; the guard must strip before checking emptiness.
    _write_profile(tmp_path, "acme", {"id": "acme", "version": " ", "floor": _valid_floor()})
    with pytest.raises(RuleProfileError, match="version"):
        load_rule_profile("acme", library_root=tmp_path)


def test_missing_file_directory_fails_closed(tmp_path):
    with pytest.raises(RuleProfileError):
        load_rule_profile("acme", library_root=tmp_path / "does-not-exist")


def test_empty_profile_id_fails_closed():
    with pytest.raises(RuleProfileError, match="non-empty string"):
        load_rule_profile("")


# ---------------------------------------------------------------------------
# OPTIONAL floor fields (min_hole_to_copper_mm).
#
# The second tier exists because a fab that publishes no hole-to-copper number
# has not thereby set it to zero -- it has said nothing, and `None` records
# that. What is optional is a field's PRESENCE; its correctness when present is
# validated exactly as strictly as a required field's.
# ---------------------------------------------------------------------------


def _floor(**overrides):
    floor = {
        "min_trace_width_mm": 0.2, "min_clearance_mm": 0.2, "min_drill_mm": 0.3,
        "min_finished_hole_mm": 0.3, "min_annular_ring_mm": 0.2,
        "min_hole_to_hole_mm": 0.3, "min_mask_sliver_mm": 0.15,
        "solder_mask_clearance_mm": 0.08, "solder_mask_expansion_mm": 0.0,
        "copper_to_edge_mm": 0.4,
    }
    floor.update(overrides)
    return floor


def _write(tmp_path, profile_id, floor):
    (tmp_path / f"{profile_id}.json").write_text(
        json.dumps({"id": profile_id, "version": "1", "floor": floor}),
        encoding="utf-8")
    return profile_id


def test_an_omitted_optional_field_loads_as_None_not_as_a_number(tmp_path):
    """`None` is the recorded absence of a rule, never a substituted default.

    The whole argument for a second tier collapses if omission quietly becomes
    a number -- that would be exactly the merge-from-defaults behaviour this
    module exists to refuse, wearing a different name.
    """
    loaded = load_rule_profile(_write(tmp_path, "silent-fab", _floor()),
                               library_root=tmp_path)
    assert loaded.floor.min_hole_to_copper_mm is None


def test_original_two_profiles_state_no_hole_to_copper_rule():
    """Pinned so that adding the field did not silently give either one a value.

    jlcpcb-2layer is deliberately NOT in this list: JLCPCB publishes
    'PTH to Track: 0.28mm', so that profile DECLARES the optional field —
    the declaring case is pinned in test_jlcpcb_profile_loads_to_a_complete
    _pinned_floor."""
    for profile_id in ("v1-fab-conservative", "oshpark-2layer"):
        assert load_rule_profile(profile_id).floor.min_hole_to_copper_mm is None


def test_omitting_an_optional_field_does_not_disturb_the_DIGEST(tmp_path):
    """A profile that omits the field digests as it did before the field existed.

    THE PIN THAT MATTERS FOR EXISTING BOARDS. The digest is the profile's
    identity, and every compiled board carries it. Had the optional field
    entered the digest as a literal `None`, adding the field would have
    re-identified both shipped profiles and every board pinned to them --
    a schema addition silently invalidating existing provenance.

    Proven by CONSTRUCTION rather than by a copied hash: two profiles with
    identical ten-field floors, one written before this field was conceivable
    and one written after, are the same profile and must digest the same. The
    id is part of the digest, so both use the same id from different roots.
    """
    root_a = tmp_path / "a"
    root_b = tmp_path / "b"
    root_a.mkdir()
    root_b.mkdir()
    _write(root_a, "same-fab", _floor())
    _write(root_b, "same-fab", _floor())
    assert (load_rule_profile("same-fab", library_root=root_a).ref.digest
            == load_rule_profile("same-fab", library_root=root_b).ref.digest)


def test_declaring_an_optional_field_DOES_change_the_digest(tmp_path):
    """The other half: a stated rule is a different rule set, so a different id.

    Without this, a profile could tighten its hole-to-copper rule and hand back
    boards whose provenance claims the looser one.
    """
    root_a = tmp_path / "a"
    root_b = tmp_path / "b"
    root_a.mkdir()
    root_b.mkdir()
    _write(root_a, "strict-fab", _floor())
    _write(root_b, "strict-fab", _floor(min_hole_to_copper_mm=0.25))
    plain = load_rule_profile("strict-fab", library_root=root_a)
    stated = load_rule_profile("strict-fab", library_root=root_b)
    assert stated.floor.min_hole_to_copper_mm == 0.25
    assert stated.ref.digest != plain.ref.digest


@pytest.mark.parametrize("bad", ["0.25", None, True, [0.25], {}])
def test_a_non_numeric_optional_field_fails_the_load_CLOSED(tmp_path, bad):
    """Optional governs presence, never correctness.

    `True` is in the list deliberately: bool is a subclass of int in Python, so
    a validator written as `isinstance(v, (int, float))` accepts it and a floor
    of `min_hole_to_copper_mm: true` becomes 1.0 mm of clearance. The required
    fields already guard against this; the optional path must not be the one
    place the guard was forgotten.
    """
    profile_id = _write(tmp_path, "bad-fab", _floor(min_hole_to_copper_mm=bad))
    with pytest.raises(RuleProfileError, match="min_hole_to_copper_mm"):
        load_rule_profile(profile_id, library_root=tmp_path)


def test_a_negative_optional_field_is_rejected_by_the_IR(tmp_path):
    """Numeric is not enough -- a negative clearance is not a clearance."""
    profile_id = _write(tmp_path, "neg-fab", _floor(min_hole_to_copper_mm=-0.1))
    with pytest.raises(RuleProfileError, match="min_hole_to_copper_mm"):
        load_rule_profile(profile_id, library_root=tmp_path)


def test_an_unrecognized_field_is_STILL_rejected(tmp_path):
    """Adding an optional tier must not turn the unknown-field check into a
    blanket allowance. Only the names in the two tuples are recognized."""
    profile_id = _write(tmp_path, "typo-fab",
                        _floor(min_hole_to_coper_mm=0.25))  # note the typo
    with pytest.raises(RuleProfileError, match="unknown field.*min_hole_to_coper_mm"):
        load_rule_profile(profile_id, library_root=tmp_path)


# ---------------------------------------------------------------------------
# Feature-specific drill floors (Codex review 1086 finding 2)
# ---------------------------------------------------------------------------


def _hole_board(diameter_mm: float, *, plated: bool, profile: str) -> dict:
    return {
        "version": 1, "name": "holeprobe", "width_mm": 20, "height_mm": 15,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.1, "trace_width_mm": 0.25,
                         "via_diameter_mm": 0.66, "via_drill_mm": 0.3,
                         "rule_profile": profile},
        "components": [
            {"ref": "C1", "footprint": "C_0805", "value": "X", "x_mm": 5,
             "y_mm": 7, "rotation_deg": 0, "layer": "top",
             "pins": [{"number": "1", "x_mm": -0.95, "y_mm": 0},
                      {"number": "2", "x_mm": 0.95, "y_mm": 0}]}],
        "nets": [{"name": "N1", "pins": ["C1.2"]}],
        "mounting_holes": [{"x_mm": 15, "y_mm": 7,
                            "diameter_mm": diameter_mm, "plated": plated}],
    }


def _gc3_required(board: dict):
    """The gc3_drill floor this board's hole was measured against, or None."""
    from pcb_worker.compile_board import compile_board
    from pcb_worker.drc_geometric import run_geometric_drc
    from pcb_worker.resolved_board import ResolutionSuccess

    result = compile_board(board)
    assert isinstance(result, ResolutionSuccess), [
        d.code for d in result.diagnostics if d.severity == "error"]
    findings = [f for f in run_geometric_drc(result.board).get("findings", ())
                if f["type"] == "gc3_drill"]
    return findings[0]["required_mm"] if findings else None


def test_npth_floor_is_enforced_when_the_profile_declares_one():
    """The false clean this field exists to close: JLCPCB publishes a 0.50mm
    NPTH minimum that the general 'Drill Diameter: 0.15 - 6.3 mm' row does not
    cover, so a 0.20mm non-plated hole reported CLEAN against 0.15."""
    assert _gc3_required(_hole_board(0.20, plated=False,
                                     profile="jlcpcb-2layer")) == 0.5
    assert _gc3_required(_hole_board(0.45, plated=False,
                                     profile="jlcpcb-2layer")) == 0.5
    # At and above the published floor: nothing to report.
    assert _gc3_required(_hole_board(0.50, plated=False,
                                     profile="jlcpcb-2layer")) is None
    assert _gc3_required(_hole_board(3.20, plated=False,
                                     profile="jlcpcb-2layer")) is None


def test_a_profile_that_declares_no_npth_floor_is_unchanged():
    """ABSENT means 'this profile said nothing', not zero — the general drill
    floor governs, exactly as it did before the field existed. Without this
    row the feature could silently start over-refusing on every other
    profile."""
    assert load_rule_profile("v1-fab-conservative").floor.min_npth_mm is None
    # v1's general drill floor is 0.2, so 0.15 fails against THAT, not 0.5.
    assert _gc3_required(_hole_board(0.15, plated=False,
                                     profile="v1-fab-conservative")) == 0.2
    assert _gc3_required(_hole_board(0.25, plated=False,
                                     profile="v1-fab-conservative")) is None


def test_a_round_pad_drill_is_not_classified_as_a_slot():
    """NEGATIVE CONTROL, and named as one.

    This test previously claimed to pin the oblong-pad repair while actually
    asserting is_slot is FALSE — a negative control wearing a positive
    control's name (Codex review 1090). The positive branch lives in
    test_a_slot_board_hole_is_measured_against_the_slot_floor below; an
    authored OVAL PAD drill cannot reach the projection at all, because the
    v1 capability gate refuses a non-round pad drill (and now also refuses a
    round-shaped drill whose axes disagree)."""
    from pcb_worker.compile_board import compile_board
    from pcb_worker.drc_geometric import project_board
    from pcb_worker.resolved_board import ResolutionSuccess

    board = {
        "version": 1, "name": "roundpad", "width_mm": 20, "height_mm": 15,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.1, "trace_width_mm": 0.25,
                         "via_diameter_mm": 0.66, "via_drill_mm": 0.3,
                         "rule_profile": "jlcpcb-2layer"},
        "components": [
            {"ref": "J1", "footprint": "TH_TestPoint", "value": "X",
             "x_mm": 10, "y_mm": 7, "rotation_deg": 0, "layer": "top",
             "pins": [{"number": "1", "x_mm": 0, "y_mm": 0,
                       "drill_mm": 0.3, "annulus_diameter_mm": 1.6}]}],
        "nets": [],
    }
    result = compile_board(board)
    assert isinstance(result, ResolutionSuccess)
    holes = [h for h in project_board(result.board).holes if h.origin == "pad"]
    assert holes, "the pad drill must reach the projection"
    assert all(not h.is_slot for h in holes)


def test_a_slot_board_hole_is_measured_against_the_slot_floor():
    """THE POSITIVE BRANCH. A board hole CAN be a genuine slot in the IR, so
    this is where slot classification and the slot floor are actually pinned:
    an NPTH slot narrower than JLCPCB's published 1.0mm non-plated-slot width
    must be reported, and against THAT floor rather than the general drill
    floor."""
    from pcb_worker.drc_geometric import _check_gc3_drill, HolePrimitive
    from pcb_worker.drc_geom_primitives import Capsule
    from pcb_worker.manufacturer_profile import load_rule_profile

    floor = load_rule_profile("jlcpcb-2layer").floor

    class _Proj:
        def __init__(self, holes):
            self.holes = holes

    class _Rules:
        minimums = floor

    class _Board:
        design_rules = _Rules()

    # A 0.6mm-wide non-plated slot: clears the 0.15 general drill floor and
    # even the 0.5 NPTH floor, but is under the 1.0 NPTH-slot floor.
    slot = HolePrimitive(
        entity_id="hole:slot", parent_id=None, origin="board_hole",
        net_id=None, plated=False,
        capsules=(Capsule(ax=5.0, ay=5.0, bx=9.0, by=5.0, r=0.3),),
        minor_mm=0.6, position=(7.0, 5.0),
        aabb=Capsule(ax=5.0, ay=5.0, bx=9.0, by=5.0, r=0.3).aabb(),
        is_slot=True)
    findings = _check_gc3_drill(_Proj([slot]), _Board())
    assert len(findings) == 1, findings
    assert findings[0]["required_mm"] == 1.0, findings[0]


# ---------------------------------------------------------------------------
# Capabilities tier (epoch GA-1). A capability is a CEILING, so its
# fail-closed direction INVERTS the floor tier's: an ABSENT capability means
# the v1 two-copper-layer baseline (silence never widens what a board house is
# claimed to fabricate), while a DECLARED one is validated exactly as strictly
# as a floor.
# ---------------------------------------------------------------------------


def test_absent_capabilities_defaults_to_two_copper_layers(tmp_path):
    _write_profile(tmp_path, "acme", {
        "id": "acme", "version": "1", "floor": _valid_floor()})
    loaded = load_rule_profile("acme", library_root=tmp_path)
    assert loaded.max_copper_layers == 2


def test_declared_max_copper_layers_loads(tmp_path):
    _write_profile(tmp_path, "acme", {
        "id": "acme", "version": "1", "floor": _valid_floor(),
        "capabilities": {"max_copper_layers": 6}})
    loaded = load_rule_profile("acme", library_root=tmp_path)
    assert loaded.max_copper_layers == 6


def test_empty_capabilities_mapping_is_the_baseline_not_an_error(tmp_path):
    # Present-but-empty says nothing — identical to absent, including (below)
    # in the digest.
    _write_profile(tmp_path, "acme", {
        "id": "acme", "version": "1", "floor": _valid_floor(),
        "capabilities": {}})
    loaded = load_rule_profile("acme", library_root=tmp_path)
    assert loaded.max_copper_layers == 2


def test_unknown_capability_field_fails_closed(tmp_path):
    _write_profile(tmp_path, "acme", {
        "id": "acme", "version": "1", "floor": _valid_floor(),
        "capabilities": {"blind_buried_vias": True}})
    with pytest.raises(RuleProfileError, match="unknown field"):
        load_rule_profile("acme", library_root=tmp_path)


def test_non_mapping_capabilities_fails_closed(tmp_path):
    _write_profile(tmp_path, "acme", {
        "id": "acme", "version": "1", "floor": _valid_floor(),
        "capabilities": [4]})
    with pytest.raises(RuleProfileError, match="must be a mapping"):
        load_rule_profile("acme", library_root=tmp_path)


@pytest.mark.parametrize("bad", [True, 4.0, "4", None, 1, 0, -2, 33])
def test_malformed_max_copper_layers_fails_closed(tmp_path, bad):
    # Booleans and floats are rejected, not coerced (4.0 is not a layer
    # count); 1 and 33 fall outside [2, 32] — below the universal baseline or
    # past KiCad's 32-copper stack, which every exported artifact is bounded
    # by.
    _write_profile(tmp_path, "acme", {
        "id": "acme", "version": "1", "floor": _valid_floor(),
        "capabilities": {"max_copper_layers": bad}})
    with pytest.raises(RuleProfileError, match="max_copper_layers"):
        load_rule_profile("acme", library_root=tmp_path)


def test_capability_digest_rule_matches_the_optional_floor_rule(tmp_path):
    # Omitting the tier digests exactly as before the tier existed — no
    # shipped profile is re-pinned by the schema gaining the field — and
    # declaring it digests differently, because the fabrication claim really
    # changed. {} is byte-identical to absent for the same reason.
    _write_profile(tmp_path, "plain", {
        "id": "plain", "version": "1", "floor": _valid_floor()})
    _write_profile(tmp_path, "empty", {
        "id": "empty", "version": "1", "floor": _valid_floor(),
        "capabilities": {}})
    _write_profile(tmp_path, "deep", {
        "id": "deep", "version": "1", "floor": _valid_floor(),
        "capabilities": {"max_copper_layers": 4}})
    plain = load_rule_profile("plain", library_root=tmp_path)
    empty = load_rule_profile("empty", library_root=tmp_path)
    deep = load_rule_profile("deep", library_root=tmp_path)
    # Digests pin {floor, profile-id, capabilities?}; ids differ across these
    # three fixtures by construction, so compare per-fixture against a
    # RE-LOADED twin instead of across ids: same bytes, same digest.
    assert plain.ref.digest == load_rule_profile("plain", library_root=tmp_path).ref.digest
    # The load-bearing halves: {} adds nothing to the payload...
    _write_profile(tmp_path, "plain2", {
        "id": "plain", "version": "1", "floor": _valid_floor(),
        "capabilities": {}})
    empty_as_plain = load_rule_profile("plain", library_root=tmp_path)
    assert empty_as_plain.ref.digest == plain.ref.digest
    # ...and a DECLARED capability changes the digest of the same id.
    _write_profile(tmp_path, "plain3", {
        "id": "plain", "version": "1", "floor": _valid_floor(),
        "capabilities": {"max_copper_layers": 4}})
    declared_as_plain = load_rule_profile("plain", library_root=tmp_path)
    assert declared_as_plain.ref.digest != plain.ref.digest
    assert deep.max_copper_layers == 4 and empty.max_copper_layers == 2


def test_jlcpcb_4layer_profile_loads_with_multilayer_floors_and_capability():
    """The epoch GA-1 profile: JLCPCB multilayer service, quoted 2026-08-13.
    The three published multilayer DELTAS vs jlcpcb-2layer are the
    discriminating axes — track/spacing 0.09 (vs 0.10), annular ring absolute
    minimum 0.15 (vs 0.18), plated slot 0.35 (vs 0.5) — and it is the FIRST
    shipped profile to declare a capabilities tier (max_copper_layers 4;
    deliberately 4, not the page's '1-32 Layers' family figure — provenance
    covers only the service tier the quotes were checked against)."""
    loaded = load_rule_profile("jlcpcb-4layer")
    assert loaded.ref.id == "jlcpcb-4layer"
    assert len(loaded.ref.digest) == 64
    assert loaded.max_copper_layers == 4
    floor = loaded.floor
    assert floor.min_trace_width_mm == pytest.approx(0.09)
    assert floor.min_clearance_mm == pytest.approx(0.09)
    assert floor.min_annular_ring_mm == pytest.approx(0.15)
    assert floor.min_plated_slot_mm == pytest.approx(0.35)
    # The no-multilayer-distinction fields carry the same figures as 2-layer.
    assert floor.min_drill_mm == pytest.approx(0.15)
    assert floor.min_finished_hole_mm == pytest.approx(0.15)
    assert floor.min_hole_to_hole_mm == pytest.approx(0.45)
    assert floor.min_hole_to_copper_mm == pytest.approx(0.28)
    assert floor.min_npth_mm == pytest.approx(0.5)
    assert floor.min_npth_slot_mm == pytest.approx(1.0)
    assert floor.min_silk_width_mm == pytest.approx(0.15)
    assert floor.min_silk_to_pad_mm == pytest.approx(0.15)
    assert floor.solder_mask_expansion_mm == 0.0
    assert floor.copper_to_edge_mm == pytest.approx(0.2)
    # min_hole_to_edge stays undeclared — the page publishes no such figure
    # (the S8 rule: absent means the profile said nothing).
    assert floor.min_hole_to_edge_mm is None
    # Distinct rule set ⇒ distinct digest from every other shipped profile.
    for other in ("v1-fab-conservative", "oshpark-2layer", "jlcpcb-2layer"):
        assert loaded.ref.digest != load_rule_profile(other).ref.digest


def test_shipped_two_layer_profiles_declare_no_capability():
    # The 2-layer houses and the v1 default say nothing and therefore fab the
    # baseline — a regression here (someone "helpfully" declaring 2) would
    # re-pin their digests for zero behavioral change.
    for profile_id in ("v1-fab-conservative", "oshpark-2layer", "jlcpcb-2layer"):
        assert load_rule_profile(profile_id).max_copper_layers == 2
