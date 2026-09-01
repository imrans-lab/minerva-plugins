"""THE SELECTED MANUFACTURING SERVICE — one pinned artifact that fixes
everything an order export consumes for one house tier.

WHY THIS IS A THIRD FILE AND NOT A FIELD ON THE OTHER TWO. Three id spaces were
already in play before this module: the fab-rule profiles under
``pcb/library/profiles`` (``jlcpcb-2layer``), the CSV-dialect house profiles in
``assembly_outputs.PROFILES`` (``jlc``), and the service tier a person actually
buys (``jlcpcb-economic``). Assembly keys cannot be folded into a rule profile:
``manufacturer_profile._load_profile_file`` rejects an unknown top-level key and
an unknown floor key by design, so a fab profile carrying a BOM dialect would
refuse to load. What this module does instead is make the SERVICE profile the
one selectable identity: it NAMES the fab profile a board must have compiled
against, and it OWNS the dialect numbers that used to be Python defaults on
:class:`assembly_outputs.HouseProfile`. Selecting ``jlcpcb-economic`` therefore
pins the fab rules, the CSV dialect, the pinned template artifacts and the rule
lists at once, and there is exactly ONE place each of those facts is written.

WHAT A SERVICE PROFILE PINS
    ``fab_profile``   the rule-profile id a board MUST have compiled against.
                      A board compiled against anything else is refused by name
                      rather than silently relabelled as ready for this house.
    ``dialect``       the BOM/CPL format facts: the emitted column headers, the
                      house's catalogue key, the identity fields it requires,
                      and the three threshold parameters the gates read
                      (``coordinate_unit``, ``max_refs_per_row``,
                      ``min_designator_separation_mm``).
    ``service``       the tier's own capability limits — which sides it
                      populates, which board sizes it builds, and the guidance
                      figures its advisories compare against.
    ``templates``     the house's OWN sample files, pinned by URL, fetch date
                      and SHA-256, with the columns parsed OUT of the workbook.
                      Never transcribed from help-page prose.
    ``checked_rules`` / ``advisory_rules`` / ``unchecked_rules``
                      what is and is not in force. See the next paragraph.

A DECLARED RULE MUST EXIST. ``checked_rules`` and ``advisory_rules`` may only
name codes this module or :mod:`assembly_gates` actually implements
(:data:`IMPLEMENTED_CHECKS`), and ``unchecked_rules`` may only name things that
are NOT implemented. The load fails on either violation, so a profile cannot
claim a rule is in force when no code runs it, and cannot quietly list a rule as
unchecked once somebody implements it. That is the whole reason the three lists
are data rather than prose in a comment.

BLOCKERS VERSUS ADVISORIES. An incompatibility with the SELECTED service is a
refusal: a board with parts on the bottom side is not "mostly orderable" from a
single-sided tier, and nothing an author can do at export time makes it so.
Everything the house itself states as a suggestion (its component-to-edge
figure is worded "we suggest") rides back as an advisory, alongside what the
pipeline could not measure. The refusals raise
:class:`assembly_gates.AssemblyGateError` so that every assembly refusal reaches
a surface with the same shape and a stable code.

NO LIBRARY LAYERING, deliberately. Fab-rule profiles resolve through the
ordered library chain because a board library may legitimately override the
geometry a board is built from. A service profile is a contract with a company,
not a property of a footprint library, so it resolves through exactly one
shipped directory and a ``root`` argument tests pass explicitly.
"""

from __future__ import annotations

import json
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Union

from . import assembly_gates, ir_projection, plugin_root as _plugin_root
from .geometry import PlacementTransform
from .refdes_anchor import body_extent_from_definition
from .resolved_board import ResolvedBoard, ResolvedComponent, Side

# The SAME plugin root the seed footprint library and the fab-rule profiles
# resolve through — one derivation, in plugin_root.py.
DEFAULT_SERVICE_PROFILE_ROOT = _plugin_root.PCB_ROOT / "library" / "service-profiles"

# --- refusal codes (service incompatibility: BLOCKERS) ----------------------

CODE_FAB_PROFILE_MISMATCH = "assembly_service_fab_profile_mismatch"
CODE_SIDE_UNSUPPORTED = "assembly_service_side_unsupported"
CODE_BOARD_SIZE_UNSUPPORTED = "assembly_service_board_size_unsupported"

# --- advisory codes (house guidance, and what could not be measured) --------

ADVISORY_COMPONENT_TO_EDGE = "assembly_house_component_to_edge"
ADVISORY_TOOLING_HOLES = "assembly_house_tooling_holes"
ADVISORY_UNMEASURABLE = "assembly_service_unmeasurable"

#: ``assembly_outputs.AssemblyIdentityError.code``, spelled here rather than
#: imported: ``assembly_outputs`` loads its service profile at import, so the
#: dependency runs one way only. Sealed against drift by
#: ``test_the_identity_refusal_code_matches_its_error_class``.
CODE_MISSING_IDENTITY = "assembly_missing_identity"

#: ``assembly_orientation``'s three refusal codes, spelled here for the same
#: one-way-dependency reason ``CODE_MISSING_IDENTITY`` is. Sealed against drift
#: by ``test_the_orientation_refusal_codes_match_their_module``.
CODE_ORIENTATION_UNKNOWN = "assembly_orientation_unknown"
CODE_ORIENTATION_UNDECIDED = "assembly_orientation_undecided"
CODE_ORIENTATION_MISMATCH = "assembly_orientation_geometry_mismatch"

#: Every rule code a profile may claim in ``checked_rules`` or
#: ``advisory_rules``, mapped to the module that runs it. The service and
#: advisory codes above are this module's; the rest belong to :mod:`assembly_gates` and
#: are listed because a service profile's dialect numbers are what those gates
#: compare against — the rule really is in force because this profile was
#: selected.
IMPLEMENTED_CHECKS: dict[str, str] = {
    CODE_FAB_PROFILE_MISMATCH: __name__,
    CODE_SIDE_UNSUPPORTED: __name__,
    CODE_BOARD_SIZE_UNSUPPORTED: __name__,
    ADVISORY_COMPONENT_TO_EDGE: __name__,
    ADVISORY_TOOLING_HOLES: __name__,
    ADVISORY_UNMEASURABLE: __name__,
    CODE_MISSING_IDENTITY: "pcb_worker.assembly_outputs",
    CODE_ORIENTATION_UNKNOWN: "pcb_worker.assembly_orientation",
    CODE_ORIENTATION_UNDECIDED: "pcb_worker.assembly_orientation",
    CODE_ORIENTATION_MISMATCH: "pcb_worker.assembly_orientation",
    assembly_gates.CODE_REFERENCE_SET_MISMATCH: assembly_gates.__name__,
    assembly_gates.CODE_DUPLICATE_DESIGNATOR: assembly_gates.__name__,
    assembly_gates.CODE_ROW_REF_LIMIT: assembly_gates.__name__,
    assembly_gates.CODE_NON_METRIC_COORDINATES: assembly_gates.__name__,
    assembly_gates.CODE_PLACEMENTS_TOO_CLOSE: assembly_gates.__name__,
    assembly_gates.CODE_EMPTY_EXPANSION: assembly_gates.__name__,
    assembly_gates.CODE_PASTE_UNDECIDED: assembly_gates.__name__,
}


class ServiceProfileError(ValueError):
    """A service profile file is unknown, malformed, or declares a rule that
    does not exist — a NAMED refusal at LOAD time, so a profile that lies about
    what it enforces never reaches a board."""

    code = "assembly_service_profile"


# ---------------------------------------------------------------------------
# The pinned shapes.
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class TemplatePin:
    """One official house artifact, pinned to the bytes that were fetched.

    ``columns`` is PARSED OUT of the workbook, never transcribed from the help
    page that links to it. ``drift`` explains every position at which those
    columns differ from what this profile emits; the loader checks that the
    explanation is complete, so a header change on either side fails the load
    instead of silently shipping a mismatch.

    ``observed_layer_tokens`` and ``observed_coordinate_suffix`` record what the
    sample ROWS carry, which is how a value-level dialect difference (the CPL
    sample writes ``T``/``B`` and a ``mm`` suffix; this emitter writes
    ``Top``/``Bottom`` and bare numbers) stays visible rather than being noticed
    by nobody."""

    artifact: str
    url: str
    referenced_from: str
    fetched: str
    sha256: str
    columns: tuple[str, ...]
    observed_layer_tokens: dict
    observed_coordinate_suffix: str
    drift: tuple[dict, ...]


@dataclass(frozen=True)
class ServiceConstraints:
    """The tier's own capability ceilings, as published.

    ``board_max_short_edge_mm`` / ``board_max_long_edge_mm`` read the published
    ``10x10mm - 470x500mm`` as a pair of sorted dimensions: the board's shorter
    edge against 470 and its longer edge against 500, which is the reading that
    refuses a 500x500 board rather than admitting it on a technicality."""

    assembly_sides: tuple[str, ...]
    board_min_edge_mm: float
    board_max_short_edge_mm: float
    board_max_long_edge_mm: float
    component_to_edge_mm: float
    tooling_holes_added: bool
    tooling_hole_count: str
    tooling_hole_diameter_mm: float


@dataclass(frozen=True)
class ServiceProfile:
    """One selected manufacturing service, whole.

    ``dialect`` stays a plain mapping because :class:`assembly_outputs.
    HouseProfile` is the type that consumes it; re-typing every key here would
    give the same facts two dataclasses and put us back to two definition
    sites."""

    id: str
    version: str
    display_name: str
    source: str
    fab_profile: str
    dialect: dict
    constraints: ServiceConstraints
    templates: tuple[TemplatePin, ...]
    checked_rules: tuple[str, ...]
    advisory_rules: tuple[str, ...]
    unchecked_rules: tuple[dict, ...]

    def template(self, artifact: str) -> Union[TemplatePin, None]:
        """The pin for one artifact kind (``"bom"``/``"cpl"``), or None."""
        for pin in self.templates:
            if pin.artifact == artifact:
                return pin
        return None


# ---------------------------------------------------------------------------
# Loading, fail-closed.
# ---------------------------------------------------------------------------

_TOP_LEVEL_FIELDS = frozenset({
    "id", "version", "display_name", "source", "fab_profile", "dialect",
    "service", "templates", "checked_rules", "advisory_rules", "unchecked_rules"})

_DIALECT_FIELDS = frozenset({
    "renderer", "house_part_key", "identity_required", "coordinate_unit",
    "coordinate_suffix", "max_refs_per_row", "min_designator_separation_mm",
    "bom_columns", "cpl_columns", "designator_separator", "layer_tokens"})

_SERVICE_FIELDS = frozenset({
    "assembly_sides", "board_min_edge_mm",
    "board_max_short_edge_mm", "board_max_long_edge_mm", "component_to_edge_mm",
    "tooling_holes_added", "tooling_hole_count", "tooling_hole_diameter_mm"})

_TEMPLATE_FIELDS = frozenset({
    "artifact", "url", "referenced_from", "fetched", "sha256", "columns",
    "observed_layer_tokens", "observed_coordinate_suffix", "drift"})

#: Which emitted column list a template's ``drift`` is measured against.
_TEMPLATE_EMITTED_COLUMNS = {"bom": "bom_columns", "cpl": "cpl_columns"}


def _reject_extra(profile_id: str, where: str, data: dict, allowed) -> None:
    extra = sorted(set(data) - set(allowed))
    if extra:
        raise ServiceProfileError(
            f"service profile {profile_id!r} {where} declares unknown field(s) "
            f"{'/'.join(extra)}; an authored field with no reader is a rule that "
            f"lies about being in force")


def _require(profile_id: str, where: str, data: dict, required) -> None:
    missing = [key for key in required if key not in data]
    if missing:
        raise ServiceProfileError(
            f"service profile {profile_id!r} {where} is missing field(s) "
            f"{'/'.join(missing)}")


def _strings(profile_id: str, where: str, value) -> tuple[str, ...]:
    if not isinstance(value, list) or any(
            not isinstance(item, str) or not item for item in value):
        raise ServiceProfileError(
            f"service profile {profile_id!r} {where} must be a list of non-empty "
            f"strings; got {value!r}")
    return tuple(value)


def _number(profile_id: str, where: str, value) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ServiceProfileError(
            f"service profile {profile_id!r} {where} must be a number; got {value!r}")
    return float(value)


def _load_constraints(profile_id: str, data) -> ServiceConstraints:
    if not isinstance(data, dict):
        raise ServiceProfileError(
            f"service profile {profile_id!r} has no 'service' mapping")
    _reject_extra(profile_id, "service", data, _SERVICE_FIELDS)
    _require(profile_id, "service", data, sorted(_SERVICE_FIELDS))
    sides = _strings(profile_id, "service.assembly_sides", data["assembly_sides"])
    known = {side.value for side in Side}
    unknown = [side for side in sides if side not in known]
    if not sides or unknown:
        raise ServiceProfileError(
            f"service profile {profile_id!r} service.assembly_sides must name at "
            f"least one of {sorted(known)}; got {list(sides)}")
    if not isinstance(data["tooling_holes_added"], bool):
        raise ServiceProfileError(
            f"service profile {profile_id!r} service.tooling_holes_added must be "
            f"a boolean; got {data['tooling_holes_added']!r}")
    if not isinstance(data["tooling_hole_count"], str):
        raise ServiceProfileError(
            f"service profile {profile_id!r} service.tooling_hole_count must be a "
            f"string (the house publishes a range, not a number)")
    return ServiceConstraints(
        assembly_sides=sides,
        board_min_edge_mm=_number(
            profile_id, "service.board_min_edge_mm", data["board_min_edge_mm"]),
        board_max_short_edge_mm=_number(
            profile_id, "service.board_max_short_edge_mm", data["board_max_short_edge_mm"]),
        board_max_long_edge_mm=_number(
            profile_id, "service.board_max_long_edge_mm", data["board_max_long_edge_mm"]),
        component_to_edge_mm=_number(
            profile_id, "service.component_to_edge_mm", data["component_to_edge_mm"]),
        tooling_holes_added=data["tooling_holes_added"],
        tooling_hole_count=data["tooling_hole_count"],
        tooling_hole_diameter_mm=_number(
            profile_id, "service.tooling_hole_diameter_mm",
            data["tooling_hole_diameter_mm"]),
    )


def _load_dialect(profile_id: str, data) -> dict:
    if not isinstance(data, dict):
        raise ServiceProfileError(
            f"service profile {profile_id!r} has no 'dialect' mapping")
    _reject_extra(profile_id, "dialect", data, _DIALECT_FIELDS)
    _require(profile_id, "dialect", data, sorted(_DIALECT_FIELDS))
    for key in ("renderer", "house_part_key", "coordinate_unit",
                "coordinate_suffix", "designator_separator"):
        if not isinstance(data[key], str):
            raise ServiceProfileError(
                f"service profile {profile_id!r} dialect.{key} must be a string; "
                f"got {data[key]!r}")
    for key in ("identity_required", "bom_columns", "cpl_columns"):
        _strings(profile_id, f"dialect.{key}", data[key])
    limit = data["max_refs_per_row"]
    if isinstance(limit, bool) or not isinstance(limit, int) or limit < 1:
        raise ServiceProfileError(
            f"service profile {profile_id!r} dialect.max_refs_per_row must be a "
            f"positive integer; got {limit!r}")
    _number(profile_id, "dialect.min_designator_separation_mm",
            data["min_designator_separation_mm"])
    tokens = data["layer_tokens"]
    if (not isinstance(tokens, dict)
            or set(tokens) != {side.value for side in Side}
            or any(not isinstance(v, str) or not v for v in tokens.values())):
        raise ServiceProfileError(
            f"service profile {profile_id!r} dialect.layer_tokens must name every "
            f"board side ({sorted(side.value for side in Side)}) with a non-empty "
            f"string; got {tokens!r}")
    return dict(data)


def _load_template(profile_id: str, dialect: dict, data) -> TemplatePin:
    if not isinstance(data, dict):
        raise ServiceProfileError(
            f"service profile {profile_id!r} templates entries must be mappings")
    _reject_extra(profile_id, "templates[]", data, _TEMPLATE_FIELDS)
    _require(profile_id, "templates[]", data, sorted(_TEMPLATE_FIELDS))
    artifact = data["artifact"]
    if artifact not in _TEMPLATE_EMITTED_COLUMNS:
        raise ServiceProfileError(
            f"service profile {profile_id!r} pins a template for unknown artifact "
            f"{artifact!r}; known: {sorted(_TEMPLATE_EMITTED_COLUMNS)}")
    digest = data["sha256"]
    if not isinstance(digest, str) or len(digest) != 64 or any(
            ch not in "0123456789abcdef" for ch in digest):
        raise ServiceProfileError(
            f"service profile {profile_id!r} template {artifact!r} sha256 must be "
            f"64 lowercase hex characters — the digest of the bytes that were "
            f"actually fetched; got {digest!r}")
    for key in ("url", "referenced_from", "fetched", "observed_coordinate_suffix"):
        if not isinstance(data[key], str):
            raise ServiceProfileError(
                f"service profile {profile_id!r} template {artifact!r} {key} must "
                f"be a string; got {data[key]!r}")
    columns = _strings(profile_id, f"templates[{artifact}].columns", data["columns"])
    emitted = tuple(dialect[_TEMPLATE_EMITTED_COLUMNS[artifact]])
    drift = data["drift"]
    if not isinstance(drift, list) or any(not isinstance(item, dict) for item in drift):
        raise ServiceProfileError(
            f"service profile {profile_id!r} template {artifact!r} drift must be a "
            f"list of mappings")
    _check_drift(profile_id, artifact, columns, emitted, drift)
    tokens = data["observed_layer_tokens"]
    if not isinstance(tokens, dict) or any(
            not isinstance(v, str) for v in tokens.values()):
        raise ServiceProfileError(
            f"service profile {profile_id!r} template {artifact!r} "
            f"observed_layer_tokens must map side -> string")
    return TemplatePin(
        artifact=artifact, url=data["url"], referenced_from=data["referenced_from"],
        fetched=data["fetched"], sha256=digest, columns=columns,
        observed_layer_tokens=dict(tokens),
        observed_coordinate_suffix=data["observed_coordinate_suffix"],
        drift=tuple(dict(item) for item in drift))


def _check_drift(profile_id: str, artifact: str, columns: tuple[str, ...],
                 emitted: tuple[str, ...], drift: list) -> None:
    """Every position at which the pinned template and the emitted header differ
    must be explained, and every explanation must describe a real difference.

    Checked both ways on purpose. An unexplained difference is a header change
    nobody noticed; an explanation for a position that now agrees is a stale
    note that would keep a resolved question open forever."""
    if len(columns) != len(emitted):
        raise ServiceProfileError(
            f"service profile {profile_id!r} pins a {artifact!r} template with "
            f"{len(columns)} column(s) but emits {len(emitted)}; a column count "
            f"difference is not header drift, it is a different file format")
    differing = {index for index, pair in enumerate(zip(columns, emitted))
                 if pair[0] != pair[1]}
    explained = set()
    for entry in drift:
        position = entry.get("position")
        if not isinstance(position, int) or not 0 <= position < len(columns):
            raise ServiceProfileError(
                f"service profile {profile_id!r} {artifact!r} drift entry names "
                f"position {position!r}, outside the pinned template's columns")
        if (entry.get("template") != columns[position]
                or entry.get("emitted") != emitted[position]):
            raise ServiceProfileError(
                f"service profile {profile_id!r} {artifact!r} drift at position "
                f"{position} claims {entry.get('template')!r} vs "
                f"{entry.get('emitted')!r}, but the profile pins "
                f"{columns[position]!r} vs {emitted[position]!r}")
        if not str(entry.get("note", "")).strip():
            raise ServiceProfileError(
                f"service profile {profile_id!r} {artifact!r} drift at position "
                f"{position} carries no note; an unexplained difference between "
                f"what a house publishes and what we emit is the whole finding")
        explained.add(position)
    if differing != explained:
        raise ServiceProfileError(
            f"service profile {profile_id!r} {artifact!r} header drift is not "
            f"accounted for: differing column position(s) "
            f"{sorted(differing - explained)} carry no drift entry, and drift "
            f"entries at {sorted(explained - differing)} describe columns that "
            f"agree")


def _check_rule_lists(profile_id: str, checked: tuple[str, ...],
                      advisory: tuple[str, ...], unchecked: tuple[dict, ...]) -> None:
    """A declared rule must exist, and an unchecked one must not.

    Both directions matter. Naming a code nothing runs is a rule that lies about
    being in force; listing an IMPLEMENTED code as unchecked understates what
    the pipeline caught, which sends a reader looking for a check that is
    already there."""
    for name, names in (("checked_rules", checked), ("advisory_rules", advisory)):
        unknown = [code for code in names if code not in IMPLEMENTED_CHECKS]
        if unknown:
            raise ServiceProfileError(
                f"service profile {profile_id!r} {name} names {'/'.join(unknown)}, "
                f"which no check implements; a declared rule with no code behind it "
                f"is a rule that lies about being in force. Implemented: "
                f"{', '.join(sorted(IMPLEMENTED_CHECKS))}")
    overlap = sorted(set(checked) & set(advisory))
    if overlap:
        raise ServiceProfileError(
            f"service profile {profile_id!r} lists {'/'.join(overlap)} as both "
            f"checked and advisory; a rule either refuses or it does not")
    for entry in unchecked:
        rule_id = entry.get("id")
        if not isinstance(rule_id, str) or not rule_id:
            raise ServiceProfileError(
                f"service profile {profile_id!r} unchecked_rules entries need a "
                f"non-empty string 'id'")
        if not str(entry.get("reason", "")).strip():
            raise ServiceProfileError(
                f"service profile {profile_id!r} unchecked rule {rule_id!r} carries "
                f"no reason; naming a rule as unchecked without saying WHY is the "
                f"same silence the list exists to break")
        if rule_id in IMPLEMENTED_CHECKS:
            raise ServiceProfileError(
                f"service profile {profile_id!r} lists implemented check "
                f"{rule_id!r} as unchecked")


def load_service_profile(profile_id: str, *,
                         root: Union[str, Path, None] = None) -> ServiceProfile:
    """Load and pin ONE service profile by id, or refuse by name.

    Fail-closed on every defect, the same way
    :func:`manufacturer_profile.load_rule_profile` is: unreadable file, bad
    JSON, wrong declared id, missing or unknown field at any level, unexplained
    template drift, or a rule list that names a check nobody wrote."""
    if not isinstance(profile_id, str) or not profile_id.strip():
        raise ServiceProfileError(
            f"service profile id must be a non-empty string; got {profile_id!r}")
    directory = Path(root) if root is not None else DEFAULT_SERVICE_PROFILE_ROOT
    path = directory / f"{profile_id}.json"
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise ServiceProfileError(
            f"unknown service profile {profile_id!r}: {path} could not be read "
            f"({exc})") from exc
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ServiceProfileError(
            f"service profile {profile_id!r} is not valid JSON: {exc}") from exc
    if not isinstance(data, dict):
        raise ServiceProfileError(
            f"service profile {profile_id!r} must be a JSON object, got "
            f"{type(data).__name__}")
    _reject_extra(profile_id, "top level", data, _TOP_LEVEL_FIELDS)
    _require(profile_id, "top level", data, sorted(_TOP_LEVEL_FIELDS))
    if data["id"] != profile_id:
        raise ServiceProfileError(
            f"service profile file {path} declares id {data['id']!r}, which does "
            f"not match the requested id {profile_id!r}")
    for key in ("version", "display_name", "source", "fab_profile"):
        if not isinstance(data[key], str) or not data[key].strip():
            raise ServiceProfileError(
                f"service profile {profile_id!r} has no non-empty string {key!r}")
    dialect = _load_dialect(profile_id, data["dialect"])
    constraints = _load_constraints(profile_id, data["service"])
    templates_raw = data["templates"]
    if not isinstance(templates_raw, list):
        raise ServiceProfileError(
            f"service profile {profile_id!r} templates must be a list")
    templates = tuple(_load_template(profile_id, dialect, item)
                      for item in templates_raw)
    kinds = [pin.artifact for pin in templates]
    if len(kinds) != len(set(kinds)):
        raise ServiceProfileError(
            f"service profile {profile_id!r} pins two templates for one artifact")
    checked = _strings(profile_id, "checked_rules", data["checked_rules"])
    advisory = _strings(profile_id, "advisory_rules", data["advisory_rules"])
    unchecked_raw = data["unchecked_rules"]
    if not isinstance(unchecked_raw, list) or any(
            not isinstance(item, dict) for item in unchecked_raw):
        raise ServiceProfileError(
            f"service profile {profile_id!r} unchecked_rules must be a list of "
            f"mappings")
    unchecked = tuple(dict(item) for item in unchecked_raw)
    _check_rule_lists(profile_id, checked, advisory, unchecked)
    return ServiceProfile(
        id=profile_id, version=data["version"], display_name=data["display_name"],
        source=data["source"], fab_profile=data["fab_profile"], dialect=dialect,
        constraints=constraints, templates=templates, checked_rules=checked,
        advisory_rules=advisory, unchecked_rules=unchecked)


# ---------------------------------------------------------------------------
# The checks the selected service runs over a compiled board.
# ---------------------------------------------------------------------------


def check_board(board: ResolvedBoard, service: ServiceProfile) -> tuple[dict, ...]:
    """Refuse a board this service cannot build; return what it can only advise
    about.

    Raises :class:`assembly_gates.AssemblyGateError` on the first
    incompatibility, in the order below — the fab-profile disagreement first,
    because a board compiled against another house's floor is not a board this
    one merely declines to assemble, it is a board whose numbers were never
    checked against this house at all."""
    _check_fab_profile(board, service)
    _check_board_size(board, service)
    _check_sides(board, service)
    return advisories(board, service)


def _check_fab_profile(board: ResolvedBoard, service: ServiceProfile) -> None:
    compiled_against = board.design_rules.rule_profile.id
    if compiled_against == service.fab_profile:
        return
    raise assembly_gates.AssemblyGateError(
        CODE_FAB_PROFILE_MISMATCH,
        f"board {board.name!r} was compiled against fabrication rule profile "
        f"{compiled_against!r}, but service profile {service.id!r} "
        f"({service.display_name}) builds boards compiled against "
        f"{service.fab_profile!r} — refusing to relabel a board checked against "
        f"one house's floor as ready for another's. Author "
        f"design_rules.rule_profile: {service.fab_profile!r} and recompile, or "
        f"export against the service that matches this board",
        field="design_rules.rule_profile")


def _check_board_size(board: ResolvedBoard, service: ServiceProfile) -> None:
    frame = _outline_frame(board)
    if frame is None:  # reported as an advisory by advisories(); not a refusal
        return
    _, _, width, height = frame
    short_edge, long_edge = sorted((width, height))
    limits = service.constraints
    if (short_edge >= limits.board_min_edge_mm
            and short_edge <= limits.board_max_short_edge_mm
            and long_edge <= limits.board_max_long_edge_mm):
        return
    raise assembly_gates.AssemblyGateError(
        CODE_BOARD_SIZE_UNSUPPORTED,
        f"board {board.name!r} measures {width:.4g} x {height:.4g} mm; service "
        f"{service.id!r} builds single boards from "
        f"{limits.board_min_edge_mm:.4g} x {limits.board_min_edge_mm:.4g} mm up "
        f"to {limits.board_max_short_edge_mm:.4g} x "
        f"{limits.board_max_long_edge_mm:.4g} mm (shorter edge against the first "
        f"figure)",
        field="outline")


def _check_sides(board: ResolvedBoard, service: ServiceProfile) -> None:
    """Every POPULATED part must sit on a side this service places on.

    Scoped to populated parts because a non-populated one is not placed by
    anybody: a bottom-side fiducial or a DNP footprint does not make a
    single-sided tier impossible."""
    allowed = set(service.constraints.assembly_sides)
    offenders: list[tuple[str, str]] = []
    for component in board.components:
        assembly = component.assembly
        if assembly is None or not assembly.populate:
            continue
        for physical in component.physical_placements:
            if physical.side.value not in allowed:
                offenders.append((physical.ref, physical.side.value))
    if not offenders:
        return
    ref, side = offenders[0]
    raise assembly_gates.AssemblyGateError(
        CODE_SIDE_UNSUPPORTED,
        f"designator {ref!r} is populated on the {side} side, but service "
        f"{service.id!r} ({service.display_name}) places on "
        f"{'/'.join(sorted(allowed))} only — {len(offenders)} placement(s) are on "
        f"an unsupported side. This is not a guideline an author can accept: the "
        f"tier will not place them. Move the parts to a supported side or select "
        f"a service that populates both",
        field="layer", refs=tuple(item[0] for item in offenders))


# ---------------------------------------------------------------------------
# Advisories: house guidance, and what could not be measured.
# ---------------------------------------------------------------------------


def advisories(board: ResolvedBoard, service: ServiceProfile) -> tuple[dict, ...]:
    """House guidance findings, plus a named entry for anything the checks could
    not measure. Never refuses."""
    out: list[dict] = []
    out.extend(_component_to_edge_advisories(board, service))
    if service.constraints.tooling_holes_added:
        out.append({
            "code": ADVISORY_TOOLING_HOLES,
            "field": "outline",
            "message": (
                f"{service.display_name} adds tooling holes to boards ordered on "
                f"this tier — typically {service.constraints.tooling_hole_count} "
                f"non-plated holes of "
                f"{service.constraints.tooling_hole_diameter_mm} mm diameter, near "
                f"the corners, placed after upload. That is a physical "
                f"modification of the board this package does not describe: "
                f"confirm it on the order page before paying"),
        })
    return tuple(out)


def _outline_frame(board: ResolvedBoard):
    """The board's rectangular frame, or None when the outline is not one.

    ``ir_projection.outline_frame`` RAISES on a shaped outer rather than
    degrading to a bounding box, which is the right behaviour for an emitter and
    the wrong one for an advisory pass: here the answer is "could not measure",
    reported by name."""
    try:
        return ir_projection.outline_frame(board.outline)
    except (ValueError, TypeError):
        return None


def _component_to_edge_advisories(board: ResolvedBoard,
                                  service: ServiceProfile) -> list[dict]:
    """Populated parts whose body box sits closer to the board rim than the
    house suggests.

    BASIS, named on every finding: the footprint's BODY extent (drawn outline
    plus lands — ``refdes_anchor.body_extent_from_definition``, "what the part
    covers once soldered"), turned by the component's own placement transform
    and re-boxed axis-aligned. Re-boxing a rotated box OVER-states the extent,
    so a part at an angle is reported slightly early rather than slightly late —
    the safe direction for an advisory.

    OUTER RIM ONLY. Interior cutout openings are board edges too and are not
    measured; that gap is named in the profile's unchecked list rather than left
    for a reader to discover."""
    limit = service.constraints.component_to_edge_mm
    frame = _outline_frame(board)
    if frame is None:
        return [{
            "code": ADVISORY_UNMEASURABLE,
            "field": "outline",
            "message": (
                f"board {board.name!r} does not have an axis-aligned rectangular "
                f"outline, so the {limit} mm component-to-edge guidance of "
                f"{service.display_name} could not be measured for any part"),
        }]
    ox, oy, width, height = frame
    definitions = board.footprint_index
    out: list[dict] = []
    unmeasured: list[str] = []
    for component in board.components:
        assembly = component.assembly
        if assembly is None or not assembly.populate:
            continue
        box = _placed_body_box(component, definitions.get(component.footprint_id))
        if box is None:
            unmeasured.append(component.ref)
            continue
        min_x, min_y, max_x, max_y = box
        clearance = min(min_x - ox, min_y - oy,
                        (ox + width) - max_x, (oy + height) - max_y)
        if clearance >= limit:
            continue
        out.append({
            "code": ADVISORY_COMPONENT_TO_EDGE,
            "component": component.ref,
            "field": "x_mm/y_mm",
            "refs": [item.ref for item in component.physical_placements],
            "message": (
                f"component {component.ref!r} sits {clearance:.4g} mm from the "
                f"board edge, inside {service.display_name}'s suggested "
                f"{limit} mm for this tier (its stated depanel routing tolerance "
                f"is about 0.2 mm). Measured from the footprint's body box "
                f"(drawn outline plus lands), re-boxed axis-aligned after "
                f"rotation"),
        })
    if unmeasured:
        out.append({
            "code": ADVISORY_UNMEASURABLE,
            "component": unmeasured[0],
            "field": "footprint",
            "refs": unmeasured,
            "message": (
                f"{len(unmeasured)} populated component(s) draw neither a body "
                f"outline nor a sized land, so their distance to the board edge "
                f"could not be measured: {', '.join(unmeasured)}"),
        })
    return out


def _placed_body_box(component: ResolvedComponent, footprint):
    """The component's body box in BOARD millimetres, or None when the footprint
    draws nothing measurable."""
    extent = body_extent_from_definition(footprint)
    if extent is None:
        return None
    transform = PlacementTransform(position=component.placement.position,
                                   rotation_deg=component.placement.rotation_deg,
                                   side=component.placement.side)
    corners = [transform.point(point) for point in (
        (extent.min_x, extent.min_y), (extent.max_x, extent.min_y),
        (extent.max_x, extent.max_y), (extent.min_x, extent.max_y))]
    xs = [point[0] for point in corners]
    ys = [point[1] for point in corners]
    if any(not math.isfinite(value) for value in xs + ys):
        return None
    return min(xs), min(ys), max(xs), max(ys)
