"""The HARD GATES an assembly order has to pass, and the ADVISORIES it carries.

An order package is submitted once, paid for, and manufactured, so every check
below REFUSES BY NAME — a stable code plus prose naming the component and the
FIELD responsible — rather than emitting a file that is merely plausible.

WHAT EACH REFUSAL PROTECTS, so a later reader can tell a real gate from a tidy
one:

* :data:`CODE_REFERENCE_SET_MISMATCH` — a house buys from the BOM and places
  from the CPL, so a designator in only one of them is either a part that
  arrives and is never placed or a placement with nothing to place.
* :data:`CODE_DUPLICATE_DESIGNATOR` — one designator, one physical part.
  CASE-FOLDED, board-wide, over every physical placement including the
  non-populated ones: a house's uploader does not distinguish case, so ``C1``
  and ``c1`` in one order is a coin toss over which part gets placed. What
  reaches this gate is only what the two EXACT-match checks upstream leave: the
  compiler refuses two components sharing a ref, naming it
  (``duplicate_component_ref``, compile_board), and the Go validator refuses an
  expansion placing two parts under one designator
  (``duplicate_assembly_designator``, internal/board/assembly.go). So an exact
  duplicate never gets this far, and every collision this gate reports is one
  that survives exact comparison — a case fold.
* :data:`CODE_ROW_REF_LIMIT` — a grouped BOM row's Designator cell is one CSV
  field, and over the profile's cap a house silently truncates the tail.
* :data:`CODE_NON_METRIC_COORDINATES` — the emitter writes bare millimetre
  numbers, which a profile stating another coordinate unit would misread.
* :data:`CODE_PLACEMENTS_TOO_CLOSE` — two designators in one place; the ordinary
  cause is a synthetic expansion whose authored ``offset_mm`` is missing or zero.
* :data:`CODE_EMPTY_EXPANSION` — a component that authored ``placements`` and
  named none, which resolves back to one implicit part under its own ref.
* :data:`CODE_PASTE_UNDECIDED` — a NOT-populated part whose lands still take
  solder paste, with ``assembly.paste`` on ``auto``. There is no defensible
  default: it is either deliberate (hand-populated later, or a variant populates
  it) or a stencil defect that bridges bare lands, so the author decides.

ALREADY ENFORCED ELSEWHERE, deliberately not duplicated: non-finite transforms
(``assembly_spec._finite`` at compile, ``resolved_board.PhysicalPlacement`` at
IR construction) and profile-required part identity
(``assembly_outputs._check_identity``). Neither can reach an emitter, so a copy
here would be unreachable code asserting a property the type already carries.

PROFILE PARAMETERS. Every threshold is read off the selected profile rather than
hard-coded at the point of comparison, because the real figures are DIALECT
facts a house states. The defaults here are reasonable starting values, NOT a
claim about any particular house's published limit.

WHAT A REFUSAL NAMES. Most gates name one component and one authored key. Two
cannot and say so by leaving ``component`` unset rather than picking one:
:data:`CODE_ROW_REF_LIMIT` is about a GROUPED row several components share, and
:data:`CODE_REFERENCE_SET_MISMATCH` is about two files disagreeing. Both name
every designator involved in ``refs`` instead.

NOT ``assembly_advisory``, which is the board-health assemblability checker (a
tri-state DFM verdict over a tolerantly-resolved board). This module is the
ORDER path.

ADVISORIES ARE NOT REFUSALS. :func:`advisories` reports what the pipeline could
not measure — today, a POPULATED part whose anchor fell through the basis ladder
to ``footprint_origin``, so the coordinate emitted as its centre is really its
drawn datum. Silk-only board furniture lands there legitimately, which is why
this cannot be a refusal and why it is scoped to POPULATED parts, the only ones
a nozzle visits. A placement that authored its own ``anchor_mm`` records the
``authored`` basis instead and is deliberately not reported: the pipeline did
not measure it, but somebody answered.
"""

from __future__ import annotations

import math
from typing import Protocol

from .assembly_spec import (PASTE_AUTO, PASTE_EXCLUDE, PASTE_INCLUDE,
                            ResolvedAssembly)
from .resolved_board import (ANCHOR_BASIS_ORIGIN, LayerRole, ResolvedBoard,
                             ResolvedComponent)

# --- refusal codes ---------------------------------------------------------

CODE_REFERENCE_SET_MISMATCH = "assembly_reference_set_mismatch"
CODE_DUPLICATE_DESIGNATOR = "assembly_duplicate_designator"
CODE_ROW_REF_LIMIT = "assembly_row_ref_limit"
CODE_NON_METRIC_COORDINATES = "assembly_non_metric_coordinates"
CODE_PLACEMENTS_TOO_CLOSE = "assembly_placements_too_close"
CODE_EMPTY_EXPANSION = "assembly_empty_expansion"
CODE_PASTE_UNDECIDED = "assembly_paste_undecided"

# --- advisory codes --------------------------------------------------------

ADVISORY_ANCHOR_UNMEASURED = "assembly_anchor_unmeasured"

# --- profile parameter defaults --------------------------------------------

#: Designators one grouped BOM row may carry. A starting default, not a
#: measured house limit — the profile work pins the real dialect figure.
DEFAULT_MAX_REFS_PER_ROW = 200

#: Minimum centre-to-centre distance between two designators on one side.
DEFAULT_MIN_DESIGNATOR_SEPARATION_MM = 0.2

#: The only coordinate unit the CPL renderer writes.
METRIC_COORDINATE_UNIT = "mm"


class AssemblyGateError(ValueError):
    """One named hard-gate refusal.

    ``code`` is the stable name a surface matches on; ``component`` and ``field``
    are what the refusal is ABOUT, carried structurally so a caller can point at
    them without parsing the message. ``refs`` names the designators involved
    when the fault is between two of them rather than inside one component."""

    def __init__(self, code: str, message: str, *, component: str | None = None,
                 field: str | None = None, refs=()):
        super().__init__(message)
        self.code = code
        self.component = component
        self.field = field
        self.refs = tuple(refs)


class AssemblyProfile(Protocol):
    """The slice of a house profile the gates read.

    Structural, not an import: the concrete type is
    ``assembly_outputs.HouseProfile``, and that module already imports this one
    for the threshold defaults below — naming the class here would close the
    cycle. A Protocol states the same contract without it, so the gates read
    real attributes rather than duck-typed lookups."""

    id: str
    coordinate_unit: str
    max_refs_per_row: int
    min_designator_separation_mm: float


def emits_paste(component: ResolvedComponent) -> bool:
    """Does any of this component's resolved lands reach a paste layer?

    The honest question behind the paste policy: not "is it SMD" but "would this
    part put solder paste on the stencil". Read off the pads' own resolved layer
    participation — the same fact ``pad_source.has_paste`` reads and the gerber
    emitter acts on — so the gate and the output cannot disagree about which
    parts have a paste decision to make."""
    return any(layer.role is LayerRole.PASTE
               for pad in component.placed_pads
               for layer in pad.layers)


def check_profile(profile: AssemblyProfile) -> None:
    """Profile-level gates, run before the board is walked."""
    unit = profile.coordinate_unit
    if unit != METRIC_COORDINATE_UNIT:
        raise AssemblyGateError(
            CODE_NON_METRIC_COORDINATES,
            f"assembly profile {profile.id!r} states coordinate_unit "
            f"{unit!r}, but the CPL renderer writes bare {METRIC_COORDINATE_UNIT} numbers "
            f"— refusing to emit millimetres under a non-metric dialect",
            field="coordinate_unit")


def _component_faults(component: ResolvedComponent, assembly: ResolvedAssembly):
    """Every per-component gate this component fails, as
    ``(code, field, message)``. Both faults below are checked for POPULATED and
    NOT-populated components alike: authored nonsense is just as reachable on a
    part nobody buys."""
    ref = component.ref
    if assembly.expansion_authored and not assembly.placements:
        yield (CODE_EMPTY_EXPANSION, "assembly.placements",
               f"component {ref!r} authors assembly.placements but names no placement; "
               f"a component that stands for several physical parts must name each one "
               f"(an exporter never invents a designator), and one that stands for "
               f"itself must omit the key — as authored it silently resolves to a "
               f"single part under {ref!r}")
    if not assembly.populate and assembly.paste == PASTE_AUTO and emits_paste(component):
        yield (CODE_PASTE_UNDECIDED, "assembly.paste",
               f"component {ref!r} is not populated, but its footprint puts solder "
               f"paste on its lands and assembly.paste is {PASTE_AUTO!r}; there is no "
               f"safe default — author assembly.paste: {PASTE_INCLUDE!r} to keep the "
               f"stencil apertures (a part populated by hand or by a later variant) or "
               f"{PASTE_EXCLUDE!r} to drop them (no paste under a part nobody places)")


def check_components(board: ResolvedBoard) -> None:
    """The per-component gates, over the whole board in one pass.

    COLLECTED, NOT RAISED ON SIGHT. A board that migrated from the pre-block
    ``assembly: exclude`` scalar can carry the same fault on a dozen fiducials
    and solder dams at once, and refusing one at a time would make fixing it a
    dozen round trips through a compile. One refusal is raised — the first code
    in board order — naming its first component in full and every other
    component carrying that same fault in ``refs``."""
    faults: dict[str, list[tuple[str, str, str]]] = {}
    order: list[str] = []
    for component in board.components:
        assembly = component.assembly
        if assembly is None:
            continue
        for code, field, message in _component_faults(component, assembly):
            if code not in faults:
                order.append(code)
            faults.setdefault(code, []).append((component.ref, field, message))
    if not order:
        return
    entries = faults[order[0]]
    ref, field, message = entries[0]
    others = [name for name, _, _ in entries[1:]]
    if others:
        message += (f". The same fault is on {len(others)} further component(s): "
                    + ", ".join(repr(name) for name in others))
    raise AssemblyGateError(order[0], message, component=ref, field=field,
                            refs=[name for name, _, _ in entries])


def check_designators(placed) -> None:
    """Board-wide designator uniqueness, CASE-FOLDED.

    ``placed`` is ``(physical ref, owning component ref)`` in board order, over
    EVERY physical placement — a non-populated part still owns its designator,
    and a collision with one is still two parts under one name on the board."""
    seen: dict[str, tuple[str, str]] = {}
    for ref, owner in placed:
        key = ref.casefold()
        previous = seen.get(key)
        if previous is not None:
            prior_ref, prior_owner = previous
            how = ("is already placed by" if prior_ref == ref
                   else f"case-folds onto {prior_ref!r}, already placed by")
            raise AssemblyGateError(
                CODE_DUPLICATE_DESIGNATOR,
                f"designator {ref!r} (component {owner!r}) {how} component "
                f"{prior_owner!r}; one designator names exactly one physical part, and "
                f"an assembly house's uploader does not distinguish case",
                component=owner, field="ref", refs=(prior_ref, ref))
        seen[key] = (ref, owner)


def check_reference_sets(bom_rows, cpl_rows) -> None:
    """The BOM and the CPL must name the same designators, with the same
    multiplicity. Compared over the rows the emitters ACTUALLY built, not over a
    third derivation from the board, so the check cannot pass while the two
    files disagree."""
    bom_refs: list[str] = []
    for row in bom_rows:
        bom_refs.extend(row.refs)
    cpl_refs = [row.ref for row in cpl_rows]
    if sorted(bom_refs) == sorted(cpl_refs):
        return
    bom_only = sorted(set(bom_refs) - set(cpl_refs))
    cpl_only = sorted(set(cpl_refs) - set(bom_refs))
    detail = []
    if bom_only:
        detail.append("bought but never placed: " + ", ".join(bom_only))
    if cpl_only:
        detail.append("placed but never bought: " + ", ".join(cpl_only))
    if not detail:
        detail.append(f"same designators, different counts "
                      f"({len(bom_refs)} BOM vs {len(cpl_refs)} CPL)")
    raise AssemblyGateError(
        CODE_REFERENCE_SET_MISMATCH,
        "BOM and CPL name different designators after expansion — " + "; ".join(detail),
        field="Designator", refs=tuple(bom_only + cpl_only))


def check_row_limits(bom_rows, profile: AssemblyProfile) -> None:
    """No grouped BOM row may carry more designators than the profile admits in
    one Designator cell."""
    limit = profile.max_refs_per_row
    for row in bom_rows:
        if len(row.refs) <= limit:
            continue
        identity = " / ".join(
            part for part in (row.comment, row.footprint, row.part_number) if part)
        raise AssemblyGateError(
            CODE_ROW_REF_LIMIT,
            f"grouped BOM row [{identity}] carries {len(row.refs)} designators, over the "
            f"{profile.id!r} profile's max_refs_per_row of {limit} "
            f"(first {row.refs[0]!r}, last {row.refs[-1]!r}) — a house reading only the "
            f"first {limit} would place the rest with nothing ordered for them. Split the "
            f"row by authoring distinct identities (a reference-prefix family per row) or "
            f"raise the profile's limit to what the house actually accepts",
            field="max_refs_per_row", refs=row.refs)


def check_placement_spacing(cpl_rows, profile: AssemblyProfile,
                            owner_of_ref=None) -> None:
    """No two designators on the SAME side may sit closer than the profile's
    minimum separation.

    SCOPE: only POPULATED parts, because only they have CPL rows — a
    do-not-populate part sitting on top of a populated one passes this gate
    silently, which is intended, since nothing is placed there.

    Swept in X order rather than compared pairwise, so a board with thousands of
    parts costs one sort: rows further apart in X than the threshold cannot be
    within it in distance, so the inner loop breaks. Distance is measured in the
    emitted frame, which negates Y — an isometry, so the number is the same one
    the board frame would give. ``owner_of_ref`` maps a designator to the
    component that drew it, so the refusal names a component as well as the two
    designators — for an expansion those differ, and the component is the thing
    an author edits."""
    owners = owner_of_ref or {}
    limit = float(profile.min_designator_separation_mm)
    if limit <= 0:
        return
    order = sorted(cpl_rows, key=lambda r: (r.x_mm, r.y_mm, r.ref))
    for index, near in enumerate(order):
        for other in order[index + 1:]:
            if other.x_mm - near.x_mm >= limit:
                break
            if other.side != near.side:
                continue
            distance = math.hypot(other.x_mm - near.x_mm, other.y_mm - near.y_mm)
            if distance < limit:
                raise AssemblyGateError(
                    CODE_PLACEMENTS_TOO_CLOSE,
                    f"designators {near.ref!r} and {other.ref!r} are placed "
                    f"{distance:.4f} mm apart on the {near.side} side, under the "
                    f"{profile.id!r} profile's "
                    f"min_designator_separation_mm of {limit} — two parts cannot occupy "
                    f"one place; the usual cause is a synthetic expansion whose authored "
                    f"offset_mm is missing or zero",
                    component=owners.get(near.ref),
                    field="assembly.placements[].offset_mm",
                    refs=(near.ref, other.ref))


def advisories(board: ResolvedBoard) -> tuple[dict, ...]:
    """What the pipeline could not MEASURE — reported, never refused.

    See the module docstring's ADVISORIES section for why an unmeasured anchor
    on a populated part is the one thing reported here and why it cannot be a
    gate."""
    out: list[dict] = []
    for component in board.components:
        assembly = component.assembly
        if assembly is None or not assembly.populate:
            continue
        refs = tuple(item.ref for item in component.physical_placements
                     if item.anchor_basis == ANCHOR_BASIS_ORIGIN)
        if not refs:
            continue
        out.append({
            "code": ADVISORY_ANCHOR_UNMEASURED,
            "component": component.ref,
            "field": "assembly anchor",
            "refs": list(refs),
            "message": (
                f"could not measure the body of component {component.ref!r} "
                f"({assembly.footprint_ref}): its footprint draws neither a fab body "
                f"outline nor a sized land, so the emitted coordinate is the footprint's "
                f"drawn origin rather than a measured centre — verify this part on the "
                f"placement preview before ordering"),
        })
    return tuple(out)
