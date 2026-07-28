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
* A floor missing ANY of the ten :class:`ManufacturingConstraints` fields is
  an ERROR -- there is NO merge with another profile's (e.g. v1's) values to
  fill the gap. A loader that filled missing keys from a default floor would
  produce a hybrid whose digest CLAIMS to be a specific board house while
  actually enforcing someone else's numbers on the fields it didn't author --
  exactly the silent failure this module exists to prevent.
* A floor declaring an EXTRA (unrecognized) field is also an ERROR: an
  authored key with no reader is a rule that lies about being in force (the
  same argument ``compile_board._reject_unread_net_class_fields`` makes for
  net classes).
* A non-numeric floor value is an ERROR.

Callers never catch a partial success: :func:`load_rule_profile` returns a
COMPLETE :class:`LoadedRuleProfile` or raises :class:`RuleProfileError`.
``compile_board`` is the one production caller and turns that exception into
a fail-closed compile diagnostic (never a silent fall back to v1).

Pinning reuses the existing shape: :class:`~pcb_worker.resolved_board.RuleProfileRef`
(``id``/``version``/``digest``) is unchanged; the digest is a JCS content-id
over ``{"floor": <the ten fields>, "profile": <id>}``, the same formula the
retired ``compile_board._v1_rule_profile`` used (with ``id`` in place of a
second hardcoded string), so v1's digest shape is preserved even though its
numbers now live in a shipped file instead of Python source.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Union

from .canonical_id import CanonicalizationError, content_id
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
# ``floor`` is an unread key -- an ALLOW-LIST, not a blanket rejection, so a
# future legitimate metadata field can be added here deliberately instead of
# silently accepted. See the ``floor``-level unknown-field check below for
# the same argument one level down.
ALLOWED_TOP_LEVEL_FIELDS: frozenset[str] = frozenset({"id", "version", "source", "floor"})

# The exact ManufacturingConstraints field set, in the dataclass's own
# declaration order. A profile supplies ALL TEN or the load fails -- see the
# module docstring's fail-closed list.
REQUIRED_FLOOR_FIELDS: tuple[str, ...] = (
    "min_trace_width_mm",
    "min_clearance_mm",
    "min_drill_mm",
    "min_finished_hole_mm",
    "min_annular_ring_mm",
    "min_hole_to_hole_mm",
    "min_mask_sliver_mm",
    "solder_mask_clearance_mm",
    "solder_mask_expansion_mm",
    "copper_to_edge_mm",
)


class RuleProfileError(ValueError):
    """A profile could not be resolved to a usable, complete manufacturing
    floor. Every raise site in this module is a fail-closed boundary --
    ``compile_board`` must turn this into a diagnostic ERROR and refuse the
    compile, never substitute a default profile."""


@dataclass(frozen=True)
class LoadedRuleProfile:
    """A fully-resolved, pinned board-house profile: the digest-pinned
    identity (``ref``) plus the complete, validated floor (``floor``)."""

    ref: RuleProfileRef
    floor: ManufacturingConstraints


def _profile_path(profile_id: str, root: Path) -> Path:
    if not isinstance(profile_id, str) or not profile_id:
        raise RuleProfileError(
            f"rule profile id must be a non-empty string; got {profile_id!r}")
    return root / f"{profile_id}.json"


def load_rule_profile(
    profile_id: str, *, library_root: Union[str, Path, None] = None,
) -> LoadedRuleProfile:
    """Load and pin ONE board-house profile by id. Fail closed on every
    defect (see module docstring); never a partial or merged result."""
    root = Path(library_root) if library_root is not None else DEFAULT_PROFILE_ROOT
    path = _profile_path(profile_id, root)
    if not path.is_file():
        raise RuleProfileError(f"unknown rule profile {profile_id!r}: no such file {path}")
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

    # ALL TEN fields or fail -- no merge with any other profile (module
    # docstring). Checked as its own pass (not folded into the coercion loop
    # below) so a missing field is reported by NAME, not as a KeyError.
    missing = [key for key in REQUIRED_FLOOR_FIELDS if key not in floor]
    if missing:
        raise RuleProfileError(
            f"rule profile {profile_id!r} floor is missing field(s) {'/'.join(missing)}; "
            f"a profile must supply all ten ManufacturingConstraints fields or fail "
            f"(no merge with another profile's defaults)")
    extra = sorted(set(floor) - set(REQUIRED_FLOOR_FIELDS))
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

    try:
        constraints = ManufacturingConstraints(**numeric_floor)
    except ValueError as exc:
        raise RuleProfileError(f"rule profile {profile_id!r} floor is invalid: {exc}") from exc

    try:
        digest = content_id({"floor": numeric_floor, "profile": profile_id})
    except CanonicalizationError as exc:
        raise RuleProfileError(
            f"rule profile {profile_id!r} could not be digested: {exc}") from exc

    return LoadedRuleProfile(
        ref=RuleProfileRef(id=profile_id, version=version, digest=digest),
        floor=constraints,
    )
