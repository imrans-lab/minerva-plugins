"""The HARD GATES an assembly order has to pass, and the ADVISORIES it carries.

An order package is submitted once, paid for, and manufactured. Every check
below therefore REFUSES BY NAME — a stable code, plus prose naming the component
and the FIELD responsible — rather than emitting a file that is merely
plausible. "Best effort" is the failure mode this module exists to remove: a
CSV that is syntactically fine and describes the wrong board costs a reel of
parts and a fortnight.

WHAT EACH REFUSAL PROTECTS, stated so a later reader can tell a real gate from a
tidy one:

* :data:`CODE_REFERENCE_SET_MISMATCH` — the BOM and the CPL must name the SAME
  set of designators after expansion. A house buys from one file and places from
  the other; a designator in only one of them is either a part that arrives and
  is never placed, or a placement with nothing to place.
* :data:`CODE_DUPLICATE_DESIGNATOR` — one designator, one physical part. Checked
  CASE-FOLDED, board-wide, over every physical placement including the
  non-populated ones: a house's uploader and its operators do not agree on case,
  and ``C1`` / ``c1`` reaching the same order is a coin toss over which part gets
  placed. The Go validator already refuses the exact-match subset of this
  (``duplicate_assembly_designator``, internal/board/assembly.go); this covers
  what that one deliberately leaves out — component refs colliding with each
  other, and every case-fold collision.
* :data:`CODE_ROW_REF_LIMIT` — a grouped BOM row's Designator cell is one CSV
  field, and every house caps how many refs it will read out of one. Over the
  cap the tail is silently truncated, which is exactly a wrong order that looks
  right. The cap is a PROFILE parameter (see PROFILE PARAMETERS below).
* :data:`CODE_NON_METRIC_COORDINATES` — the emitter writes bare millimetre
  numbers. A profile whose dialect states any other coordinate unit would have
  those numbers read as that unit.
* :data:`CODE_PLACEMENTS_TOO_CLOSE` — two designators on the same side closer
  than the profile's minimum are two parts in one place: the ordinary cause is a
  synthetic expansion whose authored ``offset_mm`` is missing or zero, which
  emits two rows on top of each other and reads as a legitimate order.
* :data:`CODE_EMPTY_EXPANSION` — a component that authored ``placements`` and
  named none. It resolves to one implicit part under its own ref, so the board
  ships as though the expansion had never been written.
* :data:`CODE_PASTE_UNDECIDED` — a NOT-populated part whose lands still take
  solder paste, with ``assembly.paste`` left on ``auto``. There is no defensible
  default: paste under a part nobody places is either deliberate (the board is
  hand-populated later, or a variant populates it) or a stencil defect that
  bridges bare lands. The author decides, by writing ``include`` or ``exclude``.

ALREADY ENFORCED ELSEWHERE — not duplicated here, on purpose:

* Non-finite transforms. ``assembly_spec._finite`` refuses a non-finite authored
  ``offset_mm`` / ``rotation_deg`` naming the component AND the key, at compile;
  ``resolved_board.PhysicalPlacement.__post_init__`` refuses a non-finite anchor,
  origin or rotation, and an out-of-range angle, at IR construction. Neither can
  reach an emitter, so a third copy here would be unreachable code asserting a
  property the type already carries.
* Profile-required part identity. ``assembly_outputs._check_identity`` refuses,
  naming the component and the missing field(s), driven by the profile's own
  ``identity_required`` tuple — which reads any ``ResolvedAssembly`` field name,
  so a profile that comes to require ``package`` or ``comment`` needs no code
  here.

PROFILE PARAMETERS. Every threshold is read off the selected ``HouseProfile``
with a default, never hard-coded at the point of comparison, because the real
figures are DIALECT facts a house states and the profile work pins later. The
defaults below are what this unit measured to be reasonable and are explicitly
NOT a claim about any particular house's published limit.

WHAT A REFUSAL NAMES. Most gates name one component and one authored key. Two
cannot, and say so by leaving ``component`` unset rather than picking an
arbitrary one: :data:`CODE_ROW_REF_LIMIT` is about a GROUPED row that several
components share equally, and :data:`CODE_REFERENCE_SET_MISMATCH` is about two
files disagreeing. Both name every designator involved in ``refs`` instead,
which is the thing an author can act on.

NOT TO BE CONFUSED WITH ``assembly_advisory``, which is the board-health
assemblability checker (a tri-state DFM verdict over a tolerantly-resolved
board). This module is the ORDER path: gates that stop an export, and one
advisory that rides back on it.

ADVISORIES ARE NOT REFUSALS. :func:`advisories` reports what the pipeline could
not measure. Today that is one thing: a POPULATED part whose anchor fell all the
way through the basis ladder to ``footprint_origin``, meaning the footprint drew
neither a fab body outline nor a sized land, so the coordinate being emitted as
the part's centre is really its drawn datum. Silk-only board furniture lands
there legitimately, which is exactly why this cannot be a refusal — and why the
advisory is scoped to POPULATED parts, the only ones a nozzle visits.
"""

from __future__ import annotations

import math

from .assembly_spec import PASTE_AUTO, PASTE_EXCLUDE, PASTE_INCLUDE
from .resolved_board import ANCHOR_BASIS_ORIGIN, LayerRole

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


def _param(profile, name: str, default):
    """A profile threshold, defaulted. Read by NAME off whatever profile object
    a caller supplies, so the profile type can grow a parameter without this
    module importing it (which would close an import cycle with the emitters)."""
    value = getattr(profile, name, None)
    return default if value is None else value


def emits_paste(component) -> bool:
    """Does any of this component's resolved lands reach a paste layer?

    The honest question behind the paste policy: not "is it SMD" but "would this
    part put solder paste on the stencil". Read off the pads' own resolved layer
    participation — the same fact ``pad_source.has_paste`` reads and the gerber
    emitter acts on — so the gate and the output cannot disagree about which
    parts have a paste decision to make."""
    return any(layer.role is LayerRole.PASTE
               for pad in getattr(component, "placed_pads", ())
               for layer in pad.layers)


def check_profile(profile) -> None:
    """Profile-level gates, run before the board is walked."""
    unit = _param(profile, "coordinate_unit", METRIC_COORDINATE_UNIT)
    if unit != METRIC_COORDINATE_UNIT:
        raise AssemblyGateError(
            CODE_NON_METRIC_COORDINATES,
            f"assembly profile {getattr(profile, 'id', profile)!r} states coordinate_unit "
            f"{unit!r}, but the CPL renderer writes bare {METRIC_COORDINATE_UNIT} numbers "
            f"— refusing to emit millimetres under a non-metric dialect",
            field="coordinate_unit")


def _component_faults(component, assembly):
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


def check_components(board) -> None:
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
        assembly = getattr(component, "assembly", None)
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


def check_row_limits(bom_rows, profile) -> None:
    """No grouped BOM row may carry more designators than the profile admits in
    one Designator cell."""
    limit = _param(profile, "max_refs_per_row", DEFAULT_MAX_REFS_PER_ROW)
    for row in bom_rows:
        if len(row.refs) <= limit:
            continue
        identity = " / ".join(part for part in (row.value, row.footprint, row.mpn) if part)
        raise AssemblyGateError(
            CODE_ROW_REF_LIMIT,
            f"grouped BOM row [{identity}] carries {len(row.refs)} designators, over the "
            f"{getattr(profile, 'id', profile)!r} profile's max_refs_per_row of {limit} "
            f"(first {row.refs[0]!r}, last {row.refs[-1]!r}) — a house reading only the "
            f"first {limit} would place the rest with nothing ordered for them. Split the "
            f"row by authoring distinct identities (a reference-prefix family per row) or "
            f"raise the profile's limit to what the house actually accepts",
            field="max_refs_per_row", refs=row.refs)


def check_placement_spacing(cpl_rows, profile, owner_of_ref=None) -> None:
    """No two designators on the SAME side may sit closer than the profile's
    minimum separation.

    Swept in X order rather than compared pairwise, so a board with thousands of
    parts costs one sort: rows further apart in X than the threshold cannot be
    within it in distance, so the inner loop breaks. Distance is measured in the
    emitted frame, which negates Y — an isometry, so the number is the same one
    the board frame would give. ``owner_of_ref`` maps a designator to the
    component that drew it, so the refusal names a component as well as the two
    designators — for an expansion those differ, and the component is the thing
    an author edits."""
    owners = owner_of_ref or {}
    limit = float(_param(profile, "min_designator_separation_mm",
                         DEFAULT_MIN_DESIGNATOR_SEPARATION_MM))
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
                    f"{getattr(profile, 'id', profile)!r} profile's "
                    f"min_designator_separation_mm of {limit} — two parts cannot occupy "
                    f"one place; the usual cause is a synthetic expansion whose authored "
                    f"offset_mm is missing or zero",
                    component=owners.get(near.ref),
                    field="assembly.placements[].offset_mm",
                    refs=(near.ref, other.ref))


def advisories(board) -> tuple[dict, ...]:
    """What the pipeline could not MEASURE — reported, never refused.

    See the module docstring's ADVISORIES section for why an unmeasured anchor
    on a populated part is the one thing reported here and why it cannot be a
    gate."""
    out: list[dict] = []
    for component in board.components:
        assembly = getattr(component, "assembly", None)
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
