"""Tests for pcb_worker.assembly_spec — the reader that turns a component's
authored ``assembly`` block into the ResolvedAssembly the IR carries.

This is the compile-time half of the order path. The emitter half lives in
test_assembly_outputs.py; what is pinned here is the READING: which authored
shapes are accepted, which are refused by name, and where a part's identity is
allowed to live.

Every refusal is checked for the component ref in its message. A refusal that
does not name the component is the thing an order path cannot afford — the
author is told something is wrong with a board of fifty parts and not which.
"""

from __future__ import annotations

import pytest

from pcb_worker import assembly_spec as spec


def _resolve(**comp):
    base = {"ref": "R1", "footprint": "R_0805", "value": "10k"}
    base.update(comp)
    return spec.resolve_assembly(base, base["footprint"], base["ref"])


# ---------------------------------------------------------------------------
# The absent block, and the two authored exclusion forms
# ---------------------------------------------------------------------------


def test_absent_block_is_a_populated_part_with_no_identity():
    """Every board that predates the block must keep compiling, and must keep
    meaning what it meant: the part is populated, nothing is authored about
    it, and paste is left to the land type."""
    resolved = _resolve()
    assert resolved.populate is True
    assert resolved.mpn is None
    assert resolved.paste == spec.PASTE_AUTO
    assert resolved.placements == ()
    assert resolved.house_parts == ()
    assert resolved.footprint_ref == "R_0805"


@pytest.mark.parametrize("authored", ["exclude", {"populate": False}])
def test_both_exclusion_forms_resolve_identically(authored):
    """The Go codec migrates the legacy scalar to the structured state, so a
    promoted board reaches the compiler in the structured shape and an
    un-promoted one does not. Both must mean the same thing, or the migration
    silently changes what gets ordered."""
    assert _resolve(assembly=authored).populate is False


def test_empty_block_is_not_an_exclusion():
    """``assembly: {}`` states nothing. Stating nothing is not the same as
    stating do-not-populate."""
    assert _resolve(assembly={}).populate is True


@pytest.mark.parametrize("bad", ["exlcude", "EXCLUDE", "true", 7, ["exclude"]])
def test_unrecognized_assembly_scalar_is_a_named_refusal(bad):
    """Fail-closed on the token: a typo must never be read as "not excluded",
    which lands a fiducial in the BOM with a fabricated identity demand."""
    with pytest.raises(spec.AssemblySpecError, match="R1"):
        _resolve(assembly=bad)


@pytest.mark.parametrize("bad", ["false", 0, 1, ""])
def test_non_boolean_populate_is_a_named_refusal(bad):
    """``populate: "false"`` must not be read as truthy-and-populated: the one
    thing this reader never does is guess."""
    with pytest.raises(spec.AssemblySpecError, match="populate must be a boolean"):
        _resolve(assembly={"populate": bad})


def test_unknown_block_key_refuses_rather_than_being_dropped():
    """Mirrors the Go codec exactly. A mistyped ``mpm`` that vanishes here
    reappears later as "missing mpn" on a part the author did fill in — the
    quiet wrong answer the whole order path exists to refuse."""
    with pytest.raises(spec.AssemblySpecError, match="mpm"):
        _resolve(assembly={"mpm": "C25804"})


# ---------------------------------------------------------------------------
# Identity — one authored home, the block
# ---------------------------------------------------------------------------


def test_identity_is_read_from_the_block_alone():
    """The block is the ONLY home. A top-level ``mpn`` or a ``properties``
    mapping is not a lower-precedence spelling to fall through to: the codec
    refuses either as an unknown key before this reader runs, and this reader
    does not consult them even when handed a dict that carries one."""
    assert _resolve(assembly={"mpn": "BLOCK"}).mpn == "BLOCK"
    assert _resolve(mpn="SCALAR", properties={"mpn": "PROPS"}).mpn is None


@pytest.mark.parametrize("blank", ["", "   ", "\r", "\r\n", "\t"])
def test_blank_identity_is_absent(blank):
    """A present-but-empty value is not an answer — a house receiving a BOM
    line whose part column is a lone carriage return is the failure this
    guards."""
    assert _resolve(assembly={"mpn": blank}).mpn is None


def test_an_explicitly_null_identity_is_absent_like_a_blank():
    """``mpn:`` with nothing after it is YAML null. It is the absent case, not
    the malformed one — the refusal below must not swallow it, or every board
    that leaves an identity key parked and empty stops compiling."""
    assert _resolve(assembly={"mpn": None}).mpn is None


def test_identity_values_are_stripped():
    assert _resolve(assembly={"mpn": "  C25804 "}).mpn == "C25804"


@pytest.mark.parametrize("key", spec.IDENTITY_FIELDS)
def test_non_string_identity_is_a_named_refusal(key):
    """An authored YAML number is neither stringified nor dropped. Coercing
    prints a plausible-looking wrong answer the identity gate would then pass;
    dropping is not the safe half either, because an absent identity is what
    the order gate refuses later, by a different name. Every identity field
    refuses alike, and the refusal names the component and the field."""
    with pytest.raises(spec.AssemblySpecError, match=key) as caught:
        _resolve(assembly={key: 387})
    assert "R1" in str(caught.value)


@pytest.mark.parametrize("bad", [129, 1.29, True, ["0201"], {"v": "0201"}])
def test_every_non_string_identity_shape_refuses(bad):
    """Not just ints: a bool or a mistyped list is equally not a part number,
    and each must refuse rather than reach an emitter as an absent value."""
    with pytest.raises(spec.AssemblySpecError, match="mpn"):
        _resolve(assembly={"mpn": bad})


def test_package_is_not_a_block_key():
    """The Footprint column is a fact about the DRAWING, stated once on the
    footprint's lock entry; a per-component ``package`` was a second home for
    it and is refused like any other unknown block key."""
    with pytest.raises(spec.AssemblySpecError, match="package"):
        _resolve(assembly={"package": "0805"})


def test_every_identity_field_reads_through_the_same_fold():
    resolved = _resolve(assembly={"manufacturer": "Yageo", "mpn": "C25804",
                                  "comment": "10k 1%"})
    assert (resolved.manufacturer, resolved.mpn,
            resolved.comment) == ("Yageo", "C25804", "10k 1%")


# ---------------------------------------------------------------------------
# Paste, house parts, placements
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("token", spec.PASTE_TOKENS)
def test_every_paste_token_is_accepted(token):
    assert _resolve(assembly={"paste": token}).paste == token


@pytest.mark.parametrize("bad", ["none", "AUTO", True, 1])
def test_unknown_paste_token_is_a_named_refusal(bad):
    with pytest.raises(spec.AssemblySpecError, match="R1"):
        _resolve(assembly={"paste": bad})


def test_house_parts_are_sorted_pairs_so_the_block_stays_hashable():
    resolved = _resolve(assembly={"house_parts": {"pcbway": "W1", "jlcpcb": "C41376161"}})
    assert resolved.house_parts == (("jlcpcb", "C41376161"), ("pcbway", "W1"))


@pytest.mark.parametrize("bad", [{"jlcpcb": 41376161}, {"jlcpcb": ""}, {"": "C1"}, "C41376161"])
def test_malformed_house_parts_are_a_named_refusal(bad):
    """A bare catalogue number with no house id is exactly the shape the schema
    rejected on purpose — a board must state WHOSE number it carries."""
    with pytest.raises(spec.AssemblySpecError, match="R1"):
        _resolve(assembly={"house_parts": bad})


def test_placements_carry_authored_refs_offsets_and_rotations():
    """Carried, not composed: the offsets are in the parent's local frame and
    are handed on verbatim. Composing them against the parent's rotation and
    side is the transform work, which owns its own fixtures."""
    resolved = _resolve(assembly={"placements": [
        {"ref": "U1S_A"},
        {"ref": "U1S_B", "offset_mm": {"x": 22.86, "y": 0}, "rotation_deg": 180},
    ]})
    assert [p.ref for p in resolved.placements] == ["U1S_A", "U1S_B"]
    assert resolved.placements[0].offset_mm is None
    assert resolved.placements[0].rotation_deg == 0.0
    assert resolved.placements[1].offset_mm == (22.86, 0.0)
    assert resolved.placements[1].rotation_deg == 180.0


def test_a_placement_anchor_is_carried_verbatim_and_absent_by_default():
    """``anchor_mm`` is read exactly like ``offset_mm`` and handed on unchanged.
    ABSENT IS None, not a zero pair: the anchor pass measures one off the parent
    footprint when nothing was authored, and it can only tell the two apart if
    "not authored" has its own value."""
    resolved = _resolve(assembly={"placements": [
        {"ref": "U1S_A"},
        {"ref": "U1S_B", "offset_mm": {"x": 22.86, "y": 0},
         "anchor_mm": {"x": -11.43, "y": 26.67}},
    ]})
    assert resolved.placements[0].anchor_mm is None
    assert resolved.placements[1].anchor_mm == (-11.43, 26.67)


def test_an_authored_zero_anchor_is_an_answer_and_not_an_absence():
    """The truthiness trap. ``(0.0, 0.0)`` says "this part's centre IS its own
    placement origin", which is a real claim about a real part — a reader that
    fell back on falsity rather than on ``None`` would silently measure the
    parent's body instead."""
    resolved = _resolve(assembly={"placements": [
        {"ref": "U1S_A", "anchor_mm": {"x": 0, "y": 0}}]})
    assert resolved.placements[0].anchor_mm == (0.0, 0.0)
    assert resolved.placements[0].anchor_mm is not None


@pytest.mark.parametrize("key", ["offset_mm", "anchor_mm"])
def test_one_missing_axis_inside_an_authored_point_is_zero(key):
    """A written key with one axis means the other is 0 — the axis that was not
    needed. The same rule for both points, because they read through one
    helper."""
    resolved = _resolve(assembly={"placements": [{"ref": "A", key: {"y": 26.67}}]})
    assert getattr(resolved.placements[0], key) == (0.0, 26.67)


def test_emitted_refs_are_the_component_ref_until_placements_expand_it():
    assert _resolve().emitted_refs("R1") == ("R1",)
    expanded = _resolve(assembly={"placements": [{"ref": "U1S_A"}, {"ref": "U1S_B"}]})
    assert expanded.emitted_refs("U1S") == ("U1S_A", "U1S_B")


@pytest.mark.parametrize("bad", [
    [{"offset_mm": {"x": 0, "y": 0}}],          # no authored ref
    [{"ref": ""}],                               # blank ref
    [{"ref": "A"}, {"ref": "A"}],                # repeated designator
    [{"ref": "A", "offest_mm": {"x": 0}}],       # typo'd key
    [{"ref": "A", "offset_mm": {"x": float("inf"), "y": 0}}],
    [{"ref": "A", "anchor_mm": {"xx": 0, "y": 26.67}}],   # typo'd anchor axis
    [{"ref": "A", "anchor_mm": 26.67}],                   # a scalar, not a point
    [{"ref": "A", "anchor_mm": {"x": 0, "y": float("nan")}}],
    [{"ref": "A", "rotation_deg": "90"}],
    {"ref": "A"},                                # a mapping, not a list
])
def test_malformed_placements_are_a_named_refusal(bad):
    """An exporter that invented a designator would rename a part between two
    orders of the same design, and a typo'd offset key would quietly place a
    part at the origin — both refuse."""
    with pytest.raises(spec.AssemblySpecError, match="R1"):
        _resolve(assembly={"placements": bad})
