"""Board-house manufacturing-floor profiles (K21, docket 019f762004dc).

A :class:`~pcb_worker.resolved_board.ManufacturingConstraints` floor used to
be a single hardcoded dict in ``compile_board.py`` (``_V1_MANUFACTURING_FLOOR``).
That made "which fab house's rules are enforced" a code edit, not a board
choice, and meant there was only ever one floor to test against. This module
replaces the hardcoded dict with a loadable, PINNED, FAIL-CLOSED profile: a
board authors ``design_rules.rule_profile`` (a profile id string); the
compiler resolves that id to a :class:`LoadedRuleProfile` through
:func:`load_rule_profile` and never invents or merges a floor.

FAIL CLOSED, on every axis (K2 review 621 MF5 fail-closed sweep applies here
too):

* An unknown id (no matching file) is an ERROR.
* Malformed JSON, a non-object top level, a missing/wrong-type ``version``,
  a missing/non-object ``floor``, is an ERROR.
* A floor missing ANY of the REQUIRED :class:`ManufacturingConstraints`
  fields is an ERROR -- there is NO merge with another profile's (e.g. v1's)
  values to fill the gap. A loader that filled missing keys from a default floor
  would produce a hybrid whose digest CLAIMS to be a specific board house while
  actually enforcing someone else's numbers on the fields it didn't author --
  exactly the silent failure this module exists to prevent.
* A floor declaring an EXTRA (unrecognized) field is also an ERROR: an
  authored key with no reader is a rule that lies about being in force (the
  same argument ``compile_board._reject_unread_net_class_fields`` makes for
  net classes). ``OPTIONAL_FLOOR_FIELDS`` are recognized, so they are not
  "extra"; everything outside both tuples still fails.
* A non-numeric floor value is an ERROR -- for OPTIONAL fields exactly as much
  as for required ones. Optional governs whether a field may be ABSENT, never
  whether it may be wrong.

Callers never catch a partial success: :func:`load_rule_profile` returns a
COMPLETE :class:`LoadedRuleProfile` or raises :class:`RuleProfileError`.
``compile_board`` is the one production caller and turns that exception into
a fail-closed compile diagnostic (never a silent fall back to v1).

Pinning reuses the existing shape: :class:`~pcb_worker.resolved_board.RuleProfileRef`
(``id``/``version``/``digest``) is unchanged; the digest is a JCS content-id
over ``{"floor": <the declared fields>, "profile": <id>}``, the same formula the
retired ``compile_board._v1_rule_profile`` used (with ``id`` in place of a
second hardcoded string), so v1's digest shape is preserved even though its
numbers now live in a shipped file instead of Python source.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Union

from agent_router.layers import MAX_INNER_LAYERS

from .canonical_id import CanonicalizationError, content_id
from .footprints import SEED_LAYER, normalize_library_layers
from .resolved_board import ManufacturingConstraints, RuleProfileRef

# Repo layout: this file is pcb/worker/pcb_worker/manufacturer_profile.py, so
# the shipped profile library lives two levels up -- the SAME root the seed
# footprint library resolves through (``footprints.py:63-65``). Do not invent
# a second root for shipped worker data.
_PCB_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_PROFILE_ROOT = _PCB_ROOT / "library" / "profiles"

# The complete set of top-level keys a profile file is allowed to declare.
# ``source`` is legitimate free-text provenance (both shipped profiles carry
# one) that no reader consumes; everything else that isn't ``id``/``version``/
# ``floor``/``capabilities`` is an unread key -- an ALLOW-LIST, not a blanket
# rejection, so a future legitimate metadata field can be added here
# deliberately instead of silently accepted. See the ``floor``-level
# unknown-field check below for the same argument one level down.
ALLOWED_TOP_LEVEL_FIELDS: frozenset[str] = frozenset(
    {"id", "version", "source", "floor", "capabilities"})

# ``capabilities`` is the profile's third tier (epoch GA station 1), and it is
# NOT a floor. A floor is a minimum a board must stay above; a capability is a
# CEILING on what the fab can build at all, so the fail-closed direction
# INVERTS: an ABSENT floor field means "this profile said nothing, nothing
# extra is enforced", while an ABSENT capability means "this profile fabricates
# only what every profile has always fabricated" -- the v1 two-copper-layer
# baseline. A profile must DECLARE a capability to unlock it; silence never
# widens what a board house is claimed to build.
ALLOWED_CAPABILITY_FIELDS: tuple[str, ...] = ("max_copper_layers",)

# The capability every profile has when it declares none: the v1 stack. Two
# copper layers is not a guess -- it is the only stack any profile-selected
# board has ever fabricated, so a legacy profile keeps exactly the behaviour
# it always had.
DEFAULT_MAX_COPPER_LAYERS = 2

# The REQUIRED ManufacturingConstraints field set, in the dataclass's own
# declaration order. A profile supplies EVERY ONE of these or the load fails --
# see the module docstring's fail-closed list. Deliberately not restated as a
# count anywhere: the tier changed once (CP2 S5) and every prose "ten" in this
# module had to be hunted down afterwards.
REQUIRED_FLOOR_FIELDS: tuple[str, ...] = (
    "min_trace_width_mm",
    "min_clearance_mm",
    "min_drill_mm",
    "min_finished_hole_mm",
    "min_annular_ring_mm",
    "min_hole_to_hole_mm",
    "min_mask_sliver_mm",
    "solder_mask_clearance_mm",
    "copper_to_edge_mm",
)
# NINE, not ten, since epoch CP2 S5. `solder_mask_expansion_mm` moved to the
# optional tier below; the ruling and its reasoning live on the dataclass field
# in resolved_board.py. The number in this comment is worth keeping accurate:
# after S5 every field in the tuple above has at least one production reader
# (measured, not asserted), which is the property that makes "required" mean
# something.

# Floor fields a profile MAY declare and that a reader consumes when present.
#
# WHY A SECOND TIER AT ALL, given the module's whole argument is that a missing
# field must fail rather than default. The required fields are quantities every
# board house publishes, so an absent one means the profile is INCOMPLETE and
# guessing it would invent a rule. `min_hole_to_copper_mm` is different in kind:
# the original two shipped profiles state no such rule (jlcpcb-2layer, added in
# epoch CPN1, is the first to DECLARE one — 0.28, from its published
# PTH-to-track minimum), and a fab that does not publish a hole-to-copper
# number has not thereby set it to zero — it has said nothing.
# `None` records "said nothing", and the pour falls back to the ordinary copper
# clearance, which is the behaviour that was already in force.
#
# THE FAIL-CLOSED PART IS NOT WEAKENED: an optional field that IS declared gets
# the same numeric validation and the same unknown-field rejection as a required
# one. What is optional is its PRESENCE, never its correctness.
OPTIONAL_FLOOR_FIELDS: tuple[str, ...] = (
    "min_hole_to_copper_mm",
    # Feature-specific drill floors (Codex review 1086 finding 2). Same tier
    # and same semantics as the field above: PRESENT means enforced, ABSENT
    # means this profile said nothing and the general drill floor governs.
    "min_npth_mm",
    "min_plated_slot_mm",
    "min_npth_slot_mm",
    # Silkscreen DFM floors (epoch CP2 S6). Same tier and semantics: PRESENT
    # means GC9 enforces it, ABSENT means the profile published no such rule.
    "min_silk_width_mm",
    "min_silk_to_pad_mm",
    # Hole-to-edge (epoch CP2 S8). Same tier and semantics — and NO shipped
    # profile declares it, because none of the three publishes a hole-to-edge
    # figure. It is admitted here so a profile that DOES publish one can state
    # it without a schema change; GC11's containment half runs regardless.
    "min_hole_to_edge_mm",
    # DEMOTED from the required tier in epoch CP2 S5 — the last required floor
    # with no production reader, and one that cannot be given a correct reader
    # until its semantics are settled (the two shipped profiles use it for
    # opposite ends of the process: fab-applied vs authoring-side expansion).
    # The full ruling is on the ManufacturingConstraints field in
    # resolved_board.py. It sits in THIS tier rather than being deleted because
    # both shipped profiles legitimately declare it and the value is real
    # provenance; what changed is the false claim that anything enforces it.
    "solder_mask_expansion_mm",
)


class RuleProfileError(ValueError):
    """A profile could not be resolved to a usable, complete manufacturing
    floor. Every raise site in this module is a fail-closed boundary --
    ``compile_board`` must turn this into a diagnostic ERROR and refuse the
    compile, never substitute a default profile."""


@dataclass(frozen=True)
class LoadedRuleProfile:
    """A fully-resolved, pinned board-house profile: the digest-pinned
    identity (``ref``) plus the complete, validated floor (``floor``).

    ``layer`` (S9) records WHICH library layer supplied the file -- provenance
    only. It is deliberately NOT part of ``ref``: the digest pins the profile's
    RULES, and the same floor authored in a user layer and in the seed is the
    same floor, so where the bytes came from must not change a board's pinned
    profile identity (and therefore cannot change one fabricated byte).

    ``max_copper_layers`` (epoch GA-1) is the profile's declared copper-stack
    CEILING -- the deepest stack this board house is on record as fabricating.
    Defaults to :data:`DEFAULT_MAX_COPPER_LAYERS`: a profile that declares no
    ``capabilities`` fabricates the v1 two-layer stack it always has. The
    compile-side reader is ``compile_board._build_design_rules``, which refuses
    a board whose declared stack is deeper than this."""

    ref: RuleProfileRef
    floor: ManufacturingConstraints
    layer: str = SEED_LAYER
    max_copper_layers: int = DEFAULT_MAX_COPPER_LAYERS


def _profile_path(profile_id: str, root: Path) -> Path:
    if not isinstance(profile_id, str) or not profile_id:
        raise RuleProfileError(
            f"rule profile id must be a non-empty string; got {profile_id!r}")
    return root / f"{profile_id}.json"


def _profile_roots(
    layers: Union[Iterable, None], library_root: Union[str, Path, None],
) -> tuple[tuple[str, Path], ...]:
    """The ordered ``(layer_name, profile_dir)`` pairs a lookup walks.

    THE SAME CHAIN footprints resolve through (owner ruling, S9): each layer's
    profile directory is ``LibraryLayer.profiles`` -- the sibling ``profiles/``
    of its footprint root, which for the seed IS :data:`DEFAULT_PROFILE_ROOT`.
    So ``layers=None`` yields exactly one root and exactly today's behaviour.

    ``library_root`` (this module's long-standing profile-root override, used by
    tests to exercise the fail-closed paths without touching shipped data)
    REPLACES the seed layer's directory rather than competing with the chain, so
    the two arguments compose instead of one silently winning.
    """
    roots: list[tuple[str, Path]] = []
    for layer in normalize_library_layers(layers):
        if layer.name == SEED_LAYER and library_root is not None:
            roots.append((layer.name, Path(library_root)))
        else:
            roots.append((layer.name, layer.profiles))
    return tuple(roots)


def load_rule_profile(
    profile_id: str, *, library_root: Union[str, Path, None] = None,
    layers: Union[Iterable, None] = None,
) -> LoadedRuleProfile:
    """Load and pin ONE board-house profile by id. Fail closed on every
    defect (see module docstring); never a partial or merged result.

    ``layers`` (S9) resolves the id through the SAME ordered library chain
    footprints use (:func:`pcb_worker.footprints.normalize_library_layers`):
    highest-precedence layer first, FIRST layer that HAS the file wins, and a
    defect in that file is refused outright -- a malformed override is never
    quietly replaced by the seed's profile of the same id, for the same reason a
    corrupt footprint override is never replaced by the seed's geometry. Omitted
    (the default), the chain is the seed layer alone and this function behaves
    exactly as it did before layering existed.
    """
    searched: list[Path] = []
    for layer_name, root in _profile_roots(layers, library_root):
        path = _profile_path(profile_id, root)
        searched.append(path)
        if path.is_file():
            return _load_profile_file(profile_id, path, layer_name)
    if len(searched) == 1:
        raise RuleProfileError(
            f"unknown rule profile {profile_id!r}: no such file {searched[0]}")
    raise RuleProfileError(
        f"unknown rule profile {profile_id!r}: no such file in any of the "
        f"{len(searched)} library layers "
        f"({'; '.join(str(path) for path in searched)})")


def _load_profile_file(profile_id: str, path: Path, layer_name: str) -> LoadedRuleProfile:
    """Read, validate, and pin the profile file the chain SELECTED. Every raise
    below is a hard refusal of that file -- there is no continue-to-the-next-layer
    path out of this function, by construction."""
    try:
        raw_text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise RuleProfileError(f"rule profile {profile_id!r} could not be read: {exc}") from exc
    try:
        data = json.loads(raw_text)
    except json.JSONDecodeError as exc:
        raise RuleProfileError(f"rule profile {profile_id!r} is not valid JSON: {exc}") from exc
    if not isinstance(data, dict):
        raise RuleProfileError(
            f"rule profile {profile_id!r} must be a JSON object, got {type(data).__name__}")

    # An authored top-level key with no reader is a rule that lies about
    # being in force -- the same argument the floor-level unknown-field
    # check below makes, one level up. Allow-listed (not blanket-rejected)
    # because ``source`` is legitimate provenance text neither reader
    # consumes but both shipped profiles carry.
    top_level_extra = sorted(set(data) - ALLOWED_TOP_LEVEL_FIELDS)
    if top_level_extra:
        raise RuleProfileError(
            f"rule profile {profile_id!r} declares unknown top-level field(s) "
            f"{'/'.join(top_level_extra)}; an authored field with no reader is a rule "
            f"that lies about being in force")

    # Identity: the file must declare the SAME id it is named after -- a
    # profile renamed on disk without updating its own declared id is a
    # malformed profile, not a silently-accepted rename.
    file_id = data.get("id")
    if file_id != profile_id:
        raise RuleProfileError(
            f"rule profile file {path} declares id {file_id!r}, which does not match "
            f"the requested id {profile_id!r}")
    version = data.get("version")
    if not isinstance(version, str) or not version.strip():
        raise RuleProfileError(f"rule profile {profile_id!r} has no non-empty string 'version'")

    floor = data.get("floor")
    if not isinstance(floor, dict):
        raise RuleProfileError(f"rule profile {profile_id!r} has no 'floor' mapping")

    # EVERY REQUIRED field or fail -- no merge with any other profile (module
    # docstring). Checked as its own pass (not folded into the coercion loop
    # below) so a missing field is reported by NAME, not as a KeyError.
    #
    # The count is NINE since CP2 S5 demoted solder_mask_expansion_mm, and this
    # text no longer states a number: the previous wording ("all ten") was
    # duplicated here and in the comment above the tuple, so the tier could not
    # change without two edits and the error message was one of them. It now
    # derives from the tuple, which is the only place the count should live.
    missing = [key for key in REQUIRED_FLOOR_FIELDS if key not in floor]
    if missing:
        raise RuleProfileError(
            f"rule profile {profile_id!r} floor is missing field(s) {'/'.join(missing)}; "
            f"a profile must supply all {len(REQUIRED_FLOOR_FIELDS)} required "
            f"ManufacturingConstraints fields or fail "
            f"(no merge with another profile's defaults)")
    extra = sorted(set(floor) - set(REQUIRED_FLOOR_FIELDS) - set(OPTIONAL_FLOOR_FIELDS))
    if extra:
        raise RuleProfileError(
            f"rule profile {profile_id!r} floor declares unknown field(s) {'/'.join(extra)}; "
            f"an authored field with no reader is a rule that lies about being in force")

    numeric_floor: dict[str, float] = {}
    for key in REQUIRED_FLOOR_FIELDS:
        value = floor[key]
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise RuleProfileError(
                f"rule profile {profile_id!r} floor.{key} must be a number; got {value!r}")
        numeric_floor[key] = float(value)

    # OPTIONAL fields are validated exactly as strictly as required ones when
    # PRESENT, and are simply absent from `numeric_floor` when not. Two
    # consequences, both deliberate:
    #   * The DIGEST is computed over `numeric_floor`, so a profile that omits
    #     an optional field digests exactly as it did before the field existed
    #     — adding the field pins no existing profile to a new id. A profile
    #     that DECLARES one digests differently, which is correct: its rule set
    #     really did change.
    #   * `ManufacturingConstraints(**numeric_floor)` then takes the field's own
    #     `None` default, which is the "this profile states no such rule" fact
    #     rather than a substituted number.
    for key in OPTIONAL_FLOOR_FIELDS:
        if key not in floor:
            continue
        value = floor[key]
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise RuleProfileError(
                f"rule profile {profile_id!r} floor.{key} must be a number; got {value!r}")
        numeric_floor[key] = float(value)

    try:
        constraints = ManufacturingConstraints(**numeric_floor)
    except ValueError as exc:
        raise RuleProfileError(f"rule profile {profile_id!r} floor is invalid: {exc}") from exc

    # CAPABILITIES (epoch GA-1): validated exactly as strictly as a floor when
    # PRESENT; when ABSENT the profile keeps the v1 two-copper-layer baseline
    # (see ALLOWED_CAPABILITY_FIELDS -- for a ceiling, silence must never
    # widen). ``max_copper_layers`` is an INT, not a float: half a copper layer
    # is not a fabrication option, and accepting 4.0 here would put a float
    # into a count comparison and into the digest.
    max_copper_layers = DEFAULT_MAX_COPPER_LAYERS
    capabilities = data.get("capabilities")
    declared_capabilities: dict[str, int] = {}
    if capabilities is not None:
        if not isinstance(capabilities, dict):
            raise RuleProfileError(
                f"rule profile {profile_id!r} 'capabilities' must be a mapping; "
                f"got {type(capabilities).__name__}")
        unknown_caps = sorted(set(capabilities) - set(ALLOWED_CAPABILITY_FIELDS))
        if unknown_caps:
            raise RuleProfileError(
                f"rule profile {profile_id!r} capabilities declares unknown field(s) "
                f"{'/'.join(unknown_caps)}; an authored field with no reader is a rule "
                f"that lies about being in force")
        if "max_copper_layers" in capabilities:
            value = capabilities["max_copper_layers"]
            # KiCad's copper stack caps at F.Cu + In1..In30 + B.Cu; a profile
            # claiming more names layers no exported artifact could carry.
            ceiling = MAX_INNER_LAYERS + 2
            if isinstance(value, bool) or not isinstance(value, int):
                raise RuleProfileError(
                    f"rule profile {profile_id!r} capabilities.max_copper_layers must be "
                    f"an integer; got {value!r}")
            if not (2 <= value <= ceiling):
                raise RuleProfileError(
                    f"rule profile {profile_id!r} capabilities.max_copper_layers must be "
                    f"between 2 and {ceiling}; got {value!r}")
            max_copper_layers = value
            declared_capabilities["max_copper_layers"] = value

    # The digest payload gains a "capabilities" key ONLY when the file declares
    # one -- the same shape-preserving rule the optional floor tier uses: a
    # profile that says nothing digests exactly as it did before the tier
    # existed, and a profile that DOES declare a capability digests
    # differently, which is correct -- its fabrication claim really changed.
    digest_payload: dict = {"floor": numeric_floor, "profile": profile_id}
    if declared_capabilities:
        digest_payload["capabilities"] = declared_capabilities
    try:
        digest = content_id(digest_payload)
    except CanonicalizationError as exc:
        raise RuleProfileError(
            f"rule profile {profile_id!r} could not be digested: {exc}") from exc

    return LoadedRuleProfile(
        ref=RuleProfileRef(id=profile_id, version=version, digest=digest),
        floor=constraints,
        layer=layer_name,
        max_copper_layers=max_copper_layers,
    )
