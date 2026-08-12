"""Layered library resolution (S9, DCR 019ff5685a6a B1) — acceptance test K19.

THREE tests, deliberately few and wide (epoch LIB1 rule), one per property the
layer chain has to have:

1. THE K19 SCENARIO — a ref present in BOTH the shipped seed and a higher layer
   resolves to the HIGHER layer's content, and the supplying layer is recorded
   (on the resolve return AND on compile provenance). Footprints and
   manufacturer profiles are the two content kinds that resolve through the
   chain, so both are exercised HERE rather than in two half-tests: the whole
   claim is that they behave the same way.
2. ANTI-SHADOWING — the same setup with the override CORRUPTED after locking
   refuses, naming the ref. It must NOT fall through to the seed. This is the
   test that matters most: a fall-through is invisible in every output (the
   board fabricates, from the wrong part), so the only place it can be caught is
   here.
3. SINGLE-LAYER REGRESSION — with no layers configured, resolution is what it
   was before layering existed, byte for byte, and nothing about the supplying
   layer leaks into the board dicts the emitters serialize.

Fixtures are built the way the rest of this suite builds throwaway libraries
(``test_compile_board_layer_fail_closed._seed_footprint``): real files under
``tmp_path``, sha-pinned in a real lock, resolved through the real public API —
never by reaching into resolver internals, because the shadowing bug this
guards against is a property of the whole path.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from pcb_worker import resolve
from pcb_worker.canonical_id import content_id
from pcb_worker.compile_board import compile_board
from pcb_worker.footprint_def import FootprintDefinition
from pcb_worker.footprints import (
    DEFAULT_LIBRARY_ROOT,
    DEFAULT_LOCKFILE,
    LOCK_SCHEMA_VERSION,
    SEED_LAYER,
    USER_LAYER,
    FootprintLookupError,
    LibraryLayer,
    load_lockfile,
    resolve_footprint,
    resolve_footprint_layered,
    sha256_file,
)
from pcb_worker.manufacturer_profile import (
    DEFAULT_PROFILE_ROOT,
    RuleProfileError,
    load_rule_profile,
)
from pcb_worker.resolved_board import (
    DiagnosticSeverity,
    ResolutionFailure,
    ResolutionSuccess,
)

# A ref the SHIPPED seed really supplies — the override layer below claims this
# same ref, which is the only way to test shadowing at all. Asserted present in
# ``_seed_refs`` so a seed-library change fails this loudly instead of silently
# turning the test into a no-shadowing test.
OVERRIDDEN_REF = "Package_DIP:DIP-6_W7.62mm_Socket"
SEED_DIP6_PAD_COUNT = 6

# The override: ONE smd pad, against the seed DIP-6's six through-hole pads, so
# "whose geometry won" is answered by a count and cannot be misread.
_OVERRIDE_BODY = """\
(footprint "USER_OVERRIDE_DIP6" (version 20221018) (generator pcb_worker_test)
  (layer "F.Cu")
  (fp_line (start -1 -1) (end 1 -1) (layer "F.SilkS") (width 0.12))
  (pad "1" smd rect (at 0 0) (size 1 1) (layers "F.Cu" "F.Mask" "F.Paste"))
)
"""

_OTHER_BODY = """\
(footprint "USER_ONLY_PART" (version 20221018) (generator pcb_worker_test)
  (layer "F.Cu")
  (pad "1" smd rect (at 0 0) (size 1 1) (layers "F.Cu" "F.Mask" "F.Paste"))
)
"""


def _seed_refs() -> dict:
    return load_lockfile()


def _write_layer(tmp_path: Path, name: str, bodies: dict) -> LibraryLayer:
    """Build a REAL layer on disk: ``<tmp>/<name>/footprints`` + its own v2 lock,
    sha-pinned from the bytes actually written. The root is named ``footprints``
    so the layer's profile directory falls out of ``LibraryLayer.profiles``'
    sibling convention (``<tmp>/<name>/profiles``) exactly as the shipped
    library's does — the layout a real user layer will have."""
    root = tmp_path / name / "footprints"
    entries: dict = {}
    for ref, body in bodies.items():
        lib, part = ref.split(":", 1)
        pretty = root / f"{lib}.pretty"
        pretty.mkdir(parents=True, exist_ok=True)
        path = pretty / f"{part}.kicad_mod"
        path.write_text(body, encoding="utf-8")
        entries[ref] = {"path": f"{lib}.pretty/{part}.kicad_mod",
                        "sha256": sha256_file(path),
                        "size_bytes": path.stat().st_size}
    root.mkdir(parents=True, exist_ok=True)
    lockfile = tmp_path / name / "footprints.lock.json"
    lockfile.write_text(
        json.dumps({"schema_version": LOCK_SCHEMA_VERSION, "entries": entries}),
        encoding="utf-8")
    return LibraryLayer(name=name, root=root, lockfile=lockfile)


def _write_profile(layer: LibraryLayer, profile_id: str, floor: dict) -> Path:
    """Put a profile into *layer*'s profile directory (see ``_write_layer``)."""
    layer.profiles.mkdir(parents=True, exist_ok=True)
    path = layer.profiles / f"{profile_id}.json"
    path.write_text(json.dumps({"id": profile_id, "version": "1", "floor": floor}),
                    encoding="utf-8")
    return path


def _seed_floor(profile_id: str) -> dict:
    """The shipped profile's floor dict, read from the file the seed layer would
    serve. Copied-then-tweaked rather than hand-authored so the override is a
    COMPLETE, valid profile without this test restating the required field set
    (which has changed twice)."""
    data = json.loads((DEFAULT_PROFILE_ROOT / f"{profile_id}.json").read_text(encoding="utf-8"))
    return dict(data["floor"])


def _one_component_board(ref: str) -> dict:
    return {
        "version": 1, "name": "layers", "width_mm": 20, "height_mm": 20,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [{"ref": "X1", "footprint": ref, "x_mm": 10, "y_mm": 10,
                        "rotation_deg": 0, "layer": "top"}],
    }


def _errors(result) -> list:
    return [d for d in result.diagnostics if d.severity is DiagnosticSeverity.ERROR]


# ---------------------------------------------------------------------------
# 1. K19: the higher layer supplies the content, and says so.
# ---------------------------------------------------------------------------


def test_user_layer_overrides_seed_for_both_footprints_and_profiles(tmp_path):
    """A user layer that claims a seed ref SUPPLIES it — geometry and all — and
    the supplying layer is recorded on the resolve return and on the compiled
    component's provenance. The same override, on the same chain, does the same
    thing to a manufacturer profile.

    Also pins the other half of "first hit wins": a ref the user layer does NOT
    claim still comes from the seed, so an override layer shadows one part
    rather than capturing the whole library.
    """
    seed_lock = _seed_refs()
    assert OVERRIDDEN_REF in seed_lock, (
        f"{OVERRIDDEN_REF} is no longer in the seed lock; this test can only "
        f"prove shadowing with a ref BOTH layers supply")
    seed_only_ref = next(ref for ref in sorted(seed_lock) if ref != OVERRIDDEN_REF)

    user = _write_layer(tmp_path, USER_LAYER, {OVERRIDDEN_REF: _OVERRIDE_BODY})

    # -- footprint: the override wins, and names itself as the supplier -------
    supplied = resolve_footprint_layered(OVERRIDDEN_REF, layers=[user])
    assert supplied.layer == USER_LAYER
    assert supplied.parsed["name"] == "USER_OVERRIDE_DIP6"
    assert len(supplied.parsed["pads"]) == 1, (
        "the seed DIP-6's six pads came back — the seed shadowed the override")
    assert supplied.path == user.root / "Package_DIP.pretty/DIP-6_W7.62mm_Socket.kicad_mod"

    # -- the seed still supplies everything the override does not claim ------
    from_seed = resolve_footprint_layered(seed_only_ref, layers=[user])
    assert from_seed.layer == SEED_LAYER
    # ...including the ORIGINAL of the overridden ref, when no layer is given.
    assert len(resolve_footprint(OVERRIDDEN_REF)["pads"]) == SEED_DIP6_PAD_COUNT

    # -- compile provenance carries the supplying layer ----------------------
    result = compile_board(_one_component_board(OVERRIDDEN_REF), library_layers=[user])
    assert isinstance(result, ResolutionSuccess), [d.message for d in _errors(result)]
    component = result.board.components[0]
    assert component.provenance.library_layer == USER_LAYER
    assert component.provenance.sha256 == sha256_file(supplied.path), (
        "provenance pinned the SEED entry's sha beside the override's bytes")
    assert len(component.placed_pads) == 1

    # -- profiles resolve through the SAME chain, with the same verdict ------
    profile_id = "v1-fab-conservative"
    floor = _seed_floor(profile_id)
    floor["min_trace_width_mm"] = 0.6  # a value no shipped profile declares
    _write_profile(user, profile_id, floor)

    loaded = load_rule_profile(profile_id, layers=[user])
    assert loaded.layer == USER_LAYER
    assert loaded.floor.min_trace_width_mm == 0.6
    seed_profile = load_rule_profile(profile_id)
    assert seed_profile.layer == SEED_LAYER
    assert seed_profile.floor.min_trace_width_mm != 0.6
    # A different rule set is a different pin — the digest must move with it.
    assert loaded.ref.digest != seed_profile.ref.digest


# ---------------------------------------------------------------------------
# 2. ANTI-SHADOWING: a corrupt override refuses; it never becomes the seed part.
# ---------------------------------------------------------------------------


def test_corrupt_override_refuses_instead_of_falling_through_to_seed(tmp_path):
    """The winning layer is FINAL. When the override's file no longer matches
    the override's pin, the ref is refused — naming the ref and the layer —
    rather than quietly resolving to the seed part it shadows.

    Fall-through would be invisible: the board would compile, fabricate, and be
    the WRONG part under the name the author asked for. The control assertion
    (the seed still resolves this ref on the default chain) is what makes the
    refusal mean "the override broke", not "this ref is unresolvable".
    """
    user = _write_layer(tmp_path, USER_LAYER, {OVERRIDDEN_REF: _OVERRIDE_BODY})
    corrupted = user.root / "Package_DIP.pretty/DIP-6_W7.62mm_Socket.kicad_mod"
    corrupted.write_text(_OTHER_BODY, encoding="utf-8")  # locked bytes, then changed

    with pytest.raises(FootprintLookupError) as excinfo:
        resolve_footprint_layered(OVERRIDDEN_REF, layers=[user])
    message = str(excinfo.value)
    assert OVERRIDDEN_REF in message, message
    assert "sha256" in message, message
    assert USER_LAYER in message, (
        "the refusal must say WHICH layer failed — the layer is the actionable "
        f"half of the diagnosis: {message}")

    # CONTROL: the ref is perfectly resolvable from the seed. The failure above
    # is the override refusing, not a missing part.
    assert len(resolve_footprint(OVERRIDDEN_REF)["pads"]) == SEED_DIP6_PAD_COUNT

    # And the compile fails CLOSED on the same board rather than fabricating the
    # seed's six-pad DIP under the override's name.
    result = compile_board(_one_component_board(OVERRIDDEN_REF), library_layers=[user])
    assert isinstance(result, ResolutionFailure)
    assert any(d.code == "footprint_unresolved" for d in _errors(result)), \
        [d.code for d in _errors(result)]

    # SAME RULE, PROFILE EDITION: an override profile that will not load is a
    # refusal, not a fall back to the seed's profile of the same id.
    profile_id = "v1-fab-conservative"
    _write_profile(user, profile_id, {})  # no required floor fields at all
    with pytest.raises(RuleProfileError) as profile_error:
        load_rule_profile(profile_id, layers=[user])
    assert profile_id in str(profile_error.value)


# ---------------------------------------------------------------------------
# 3. REGRESSION: the default chain is the pre-S9 behaviour, and layering leaves
#    no trace in anything the emitters serialize.
# ---------------------------------------------------------------------------


def test_default_chain_is_byte_identical_and_leaks_no_layer_into_board_dicts():
    """No layers configured => the seed layer alone => exactly what this module
    did before layering existed.

    The leak check is the important half. The supplying layer is recorded BESIDE
    the parsed footprint (``ResolvedFootprint.layer``), never inside it, so it
    cannot reach ``FootprintDefinition.content_id``, the pad dicts the emitters
    consume, or the board provenance digest — the three places where an extra
    key would become an extra fabricated byte.
    """
    parsed = resolve_footprint(OVERRIDDEN_REF)

    # Every spelling of the old call agrees, including the explicit-default one.
    assert parsed == resolve_footprint(OVERRIDDEN_REF,
                                       library_root=DEFAULT_LIBRARY_ROOT,
                                       lockfile=DEFAULT_LOCKFILE)
    assert parsed == resolve_footprint(OVERRIDDEN_REF, lock=load_lockfile())
    supplied = resolve_footprint_layered(OVERRIDDEN_REF)
    assert supplied.parsed == parsed
    assert supplied.layer == SEED_LAYER

    # The parsed dict grew NOTHING.
    assert set(parsed) <= {"name", "pads", "graphics", "reference_text", "unsupported"}

    # Neither did either board-dict projection (the fab-facing one in
    # footprint_def, and the panel/DRC-facing one in resolve).
    forbidden = {"_layer", "layer", "library_layer"}
    projections = (FootprintDefinition.from_kicad_parsed(parsed).to_board_pad_dicts()
                   + resolve._pads_from_parsed(parsed["pads"]))
    for pad in projections:
        assert not (set(pad) & forbidden), pad

    # The compiled board's library provenance digest is still taken over the
    # seed lock ALONE — a default compile's provenance did not move.
    result = compile_board(_one_component_board(OVERRIDDEN_REF))
    assert isinstance(result, ResolutionSuccess), [d.message for d in _errors(result)]
    assert result.board.provenance.library_lock_ref == content_id(load_lockfile())
    # ...and the layer IS recorded, as the seed, where it belongs: on provenance.
    assert result.board.components[0].provenance.library_layer == SEED_LAYER


# ---------------------------------------------------------------------------
# 4. GENERATOR SAFETY: one configuration object, both content kinds (Codex
#    1160 P2 — a consumed iterable must not split the chain).
# ---------------------------------------------------------------------------


def test_generator_layer_config_supplies_footprint_and_profile_from_one_chain(tmp_path):
    """`library_layers` passed as a GENERATOR (a perfectly valid Iterable) must
    give footprints AND the rule profile the SAME user-layer chain inside one
    compile. Before materialization-at-entry, the footprint walk consumed the
    generator and the profile walk silently fell back to the seed — user
    copper checked against the seed's rules, with provenance recording two
    different chains for one board."""
    profile_id = "v1-fab-conservative"
    user = _write_layer(tmp_path, USER_LAYER, {OVERRIDDEN_REF: _OVERRIDE_BODY})
    floor = _seed_floor(profile_id)
    floor["min_trace_width_mm"] = 0.6
    _write_profile(user, profile_id, floor)
    user_profile_digest = load_rule_profile(profile_id, layers=[user]).ref.digest
    seed_profile_digest = load_rule_profile(profile_id).ref.digest
    assert user_profile_digest != seed_profile_digest

    board = _one_component_board(OVERRIDDEN_REF)
    board["design_rules"]["rule_profile"] = profile_id

    result = compile_board(board, library_layers=(layer for layer in [user]))
    assert isinstance(result, ResolutionSuccess), [d.message for d in _errors(result)]
    # Footprint: supplied by the user layer...
    assert result.board.components[0].provenance.library_layer == USER_LAYER
    # ...and the profile came from the SAME chain, not an exhausted one.
    assert result.board.design_rules.rule_profile.digest == user_profile_digest
