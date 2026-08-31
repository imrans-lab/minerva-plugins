"""Assembly-package outputs: the BOM (bill of materials) and CPL (component
placement list / pick-and-place) for a pre-assembled board order.

ONE COMPILATION FEEDS EVERY ORDER ARTIFACT. Both emitters read the compiled
``ResolvedBoard`` IR — the same object ``gerber.build_gerbers_ir`` reads — and
nothing else, so a single order cannot carry CSVs describing one board and
gerbers describing another. Every coordinate, side, rotation, value and part
identity below comes from a component the compiler admitted; a board that cannot
strictly compile refuses by name (:func:`not_compilable_error`), never with a
traceback and never with a partial CSV.

ONE EMISSION, TWO FILES. :func:`emit` builds the BOM rows AND the CPL rows in a
single walk, and every builder renders out of one emission. That is what lets
the reference-set gate compare the files a caller actually receives rather than
a third derivation of the board — and why asking for only the BOM still refuses
when the CPL would have disagreed with it.

The pair therefore has its OWN entry point, :func:`build_package`. Calling
:func:`build_bom` and then :func:`build_cpl` is two emissions of two
compilations, and the agreement gate inside each proves only that THAT walk was
self-consistent; nothing there compares one call to the other. A caller that
wants both files must ask for both at once.

A house-format-agnostic CORE (:func:`_walk`) plus exactly ONE house-specific
renderer (JLCPCB-style CSV). An unrecognized or assembly-incapable house id is a
NAMED refusal (:class:`AssemblyProfileError`), never a silent best-guess format.

THE SELECTED PROFILE IS PINNED DATA, NOT PYTHON. Every dialect fact below — the
emitted column headers, the house's catalogue key, the identity fields it
requires, and the three thresholds :mod:`assembly_gates` compares against —
comes from a service-profile FILE (:mod:`service_profile`,
``pcb/library/service-profiles``), which also names the fabrication rule profile
a board must have compiled against and pins the house's own template artifacts.
One file, one definition of each fact.

TWO SELECTORS, ONE FILE, and the difference is what is CLAIMED. ``jlcpcb-economic``
selects the SERVICE: the tier's compatibility checks run, and a board that
disagrees with it is refused by name. ``jlc`` selects the same file's DIALECT
with NO tier — the legacy selector, kept because a mid-layout quote export
against a board not yet compiled for any house is legitimate (the DCR's
readiness states) and must not be dressed up as orderable. Both emit identical
files; only ``jlcpcb-economic`` makes a claim about a manufacturer.

PART-IDENTITY CONTRACT. A component the selected profile requires identity for
(today: ``mpn``) and that lacks it is a NAMED refusal
(:class:`AssemblyIdentityError`) naming the ref, never a blank cell. Where the
profile requires nothing, a blank field is emitted and a blank value/footprint
stays a warning — the contract is a stricter, profile-gated rule on top of that,
not a relaxation of it. A profile may only require a field the identity model
carries (``assembly_spec.IDENTITY_FIELDS``); one that names anything else
refuses when the PROFILE is built, because a requirement nothing can satisfy
would otherwise refuse every board that ever selected it.

WHAT EACH BOM COLUMN CARRIES, and what it falls back to. The schema
(docs/board-yaml.md) gives three of the assembly block's fields a column of
their own, and each is read here with ONE defined fallback to the pre-block
source it supersedes:

===================== ============================ ========================
column                authored field               fallback when absent
===================== ============================ ========================
Comment               ``assembly.comment``         the component's ``value``
Footprint             ``assembly.package``         the authored footprint ref
house catalogue no.   ``assembly.house_parts[h]``  ``assembly.mpn``
===================== ============================ ========================

``h`` is the profile's own :attr:`HouseProfile.house_part_id` — the id a board
names THAT house's number under. Selecting by profile rather than by position
is what keeps a board that carries two houses' numbers from shipping the wrong
one; which id a house answers to is a dialect fact, so it is a profile field.

HARD GATES, NAMED. Before either file is rendered the rows both emitters built
go through :mod:`assembly_gates`. Every gate refuses with a stable code naming
the component and the field; ADVISORIES (what the pipeline could not measure)
ride back on the result instead of refusing.

THE COORDINATE IS THE ASSEMBLY ANCHOR, not the drawing datum. ``x_mm``/``y_mm``
place the FOOTPRINT ORIGIN, and where that sits on the part is a property of the
footprint: over ``pcb/library/footprints``, 14 of 39 put it on pin 1 and 18
resolve an anchor somewhere other than their origin. Every row therefore reads
``ResolvedComponent.physical_placements`` — the resolved body-centre anchors
``assembly_anchor`` composes at compile time — and never ``Placement.position``.
The same list is what makes a SYNTHETIC EXPANSION real: one drawn component
carrying ``assembly.placements`` contributes one CPL row and one BOM quantity
per authored placement, the offset already composed against the parent's
rotation and side, once, by the compiler.

FRAME AND ROTATION, both measured against a real position-file run by the
dev/CI-only export tool this module may not name (STANDING GUARD 2,
``tests/test_kicad_cli_boundary.py``): CPL X is the anchor's X VERBATIM, CPL Y
is its Y NEGATED, bottom-side X is UNMIRRORED, and ``Rotation`` is the authored
``rotation_deg`` verbatim (modulo 360) — which reads as JLC's
counter-clockwise-positive convention precisely because Y is negated. Do not
touch the arithmetic in :func:`_walk` without reading
``docs/assembly-outputs.md``, which carries the oracle, the measured table and
the two non-claims (this is not a promise a part mounts right-side-up, and a
BOM/CPL pair is not a stencil).
"""

from __future__ import annotations

from dataclasses import dataclass

from . import assembly_gates, service_profile
from .assembly_spec import IDENTITY_FIELDS

CSV_EOL = "\r\n"  # JLC's own templates ship CRLF; keep it stable either way.


class AssemblyProfileError(ValueError):
    """The requested house id is unknown, or the house does not offer
    assembly (BOM/CPL) service at all — a NAMED refusal, never a silent
    best-guess format or a fallback to a different house's columns."""

    #: Stable refusal name, carried the same way assembly_gates.AssemblyGateError
    #: carries one, so every assembly refusal reaches a surface with a code.
    code = "assembly_profile"


class AssemblyIdentityError(ValueError):
    """A component lacks an identity field the selected profile REQUIRES
    (e.g. MPN) — a NAMED refusal identifying the component ref, never a
    blank BOM/CPL cell."""

    code = "assembly_missing_identity"


class AssemblyBoardError(ValueError):
    """The COMPILED board handed to an emitter is not usable for assembly
    output — today, a component the compiler did not attach assembly facts to.
    Fails closed with an exception rather than an {"ok": False} payload, which
    is how ``gerber.build_gerbers_ir`` callers already handle emitter faults.

    The board-SHAPE faults this used to raise (a non-mapping board, a component
    with no ref, a non-string value or footprint, an unrecognized layer) are now
    the compiler's, and a board carrying any of them refuses before an emitter
    is reached — see :func:`not_compilable_error`."""

    code = "assembly_board_not_resolved"


@dataclass(frozen=True)
class HouseProfile:
    """One assembly house's format contract. House-format-agnostic CORE row
    data (below) is rendered through exactly one of these per emit call."""

    id: str
    display_name: str
    supports_assembly: bool
    identity_required: tuple[str, ...] = ()
    #: The id a board names THIS house's catalogue number under in
    #: ``assembly.house_parts``. Separate from ``id`` because that is the
    #: caller's short selector while this is the board's own spelling for the
    #: house; empty means the two coincide. Read through
    #: :attr:`house_part_id`, never directly.
    house_part_key: str = ""
    # DIALECT PARAMETERS, defaulted rather than hard-coded at the point of
    # comparison. The real figures are facts a house publishes and the selected
    # service profile pins; the gates read them off whatever profile is passed,
    # so filling in a measured limit is a data change, not a code change. The
    # defaults here are what a profile that pins nothing gets, and their
    # rationale lives in assembly_gates.
    max_refs_per_row: int = assembly_gates.DEFAULT_MAX_REFS_PER_ROW
    min_designator_separation_mm: float = (
        assembly_gates.DEFAULT_MIN_DESIGNATOR_SEPARATION_MM)
    coordinate_unit: str = assembly_gates.METRIC_COORDINATE_UNIT
    #: What each emitted coordinate carries AFTER its number. Empty is the bare
    #: millimetre figure every KiCad-side exporter writes; JLCPCB's own CPL
    #: sample writes ``95.0518mm``, and its uploader takes either. A dialect
    #: fact, so it is pinned rather than decided at the point of formatting.
    coordinate_suffix: str = ""
    #: The CSV dialect this profile renders through, separate from ``id``
    #: because the FORMAT and the SERVICE are different facts: several tiers of
    #: one house emit one dialect. Empty means the two coincide; read through
    #: :attr:`renderer_id`. This is also what keeps the emitted filenames
    #: naming a format rather than a tier.
    renderer: str = ""
    #: The emitted header row of each file, pinned by the service profile. Kept
    #: here rather than in the renderer so the columns a house publishes and the
    #: columns we write are comparable — see ``service_profile._check_drift``.
    bom_columns: tuple[str, ...] = ()
    cpl_columns: tuple[str, ...] = ()
    #: What separates designators inside one grouped BOM row's Designator cell.
    designator_separator: str = ","
    #: The token each board side prints in the CPL's Layer column, by
    #: ``Side`` value.
    layer_tokens: tuple[tuple[str, str], ...] = ()
    #: The pinned service tier, or None when the selector claims no tier. Its
    #: presence is what turns on the manufacturer-compatibility checks in
    #: :func:`service_profile.check_board`.
    service: "service_profile.ServiceProfile | None" = None

    def __post_init__(self) -> None:
        # A profile may only require identity the model can actually carry. A
        # requirement outside IDENTITY_FIELDS is unsatisfiable by construction —
        # every board selecting the profile would refuse for a field no author
        # can supply — so it refuses HERE, where the profile is written, rather
        # than silently at every export.
        unknown = [f for f in self.identity_required if f not in IDENTITY_FIELDS]
        if unknown:
            raise AssemblyProfileError(
                f"assembly profile {self.id!r} requires identity field(s) "
                f"{'/'.join(unknown)}, which the resolved assembly model does not carry; "
                f"a board could never satisfy it. Known identity fields: "
                f"{'/'.join(IDENTITY_FIELDS)}")

    @property
    def house_part_id(self) -> str:
        """The ``assembly.house_parts`` key this profile's catalogue number is
        read from."""
        return self.house_part_key or self.id

    @property
    def renderer_id(self) -> str:
        """The CSV dialect this profile renders through."""
        return self.renderer or self.id

    def layer_token(self, side: str) -> str:
        """The Layer-column token for a board side. Falls back to the
        capitalized side name for a profile that pins no tokens, which is what
        every emitted CPL carried before the tokens were pinned."""
        return dict(self.layer_tokens).get(side, side.capitalize())


#: The service-profile file every JLCPCB selector below reads its dialect from.
#: Loaded EAGERLY, the same way ``compile_board`` loads its default rule profile
#: at import: shipped worker data that fails to load is a broken install, not a
#: condition to discover halfway through an order.
JLCPCB_ECONOMIC = service_profile.load_service_profile("jlcpcb-economic")


def _house_profile(service, *, selector: str, select_service: bool) -> HouseProfile:
    """One selectable house profile built from a pinned service profile.

    ``select_service`` is the whole difference between the two JLCPCB selectors:
    carrying the service turns on the manufacturer-compatibility checks, and
    omitting it says "this export claims no tier" (module docstring, TWO
    SELECTORS)."""
    dialect = service.dialect
    return HouseProfile(
        id=selector,
        display_name=service.display_name if select_service else "JLCPCB",
        supports_assembly=True,
        identity_required=tuple(dialect["identity_required"]),
        house_part_key=dialect["house_part_key"],
        max_refs_per_row=dialect["max_refs_per_row"],
        min_designator_separation_mm=float(dialect["min_designator_separation_mm"]),
        coordinate_unit=dialect["coordinate_unit"],
        coordinate_suffix=dialect["coordinate_suffix"],
        renderer=dialect["renderer"],
        bom_columns=tuple(dialect["bom_columns"]),
        cpl_columns=tuple(dialect["cpl_columns"]),
        designator_separator=dialect["designator_separator"],
        layer_tokens=tuple(sorted(dialect["layer_tokens"].items())),
        service=service if select_service else None,
    )


# The selectable assembly profiles this unit ships.
#
# ``jlcpcb-economic`` is the SERVICE: selecting it pins the fabrication rule
# profile, the dialect, the template artifacts and the rule lists at once, and a
# board that disagrees with any of them refuses by name. ``jlc`` is the same
# file's dialect with no tier claimed — see the module docstring. JLCPCB's SMT
# assembly service requires a part number per placed part, which is what the
# profile's ``identity_required`` encodes; a component missing it is a
# structured refusal, not a blank BOM cell (PART-IDENTITY CONTRACT).
#
# ``oshpark`` is deliberately KNOWN-BUT-UNSUPPORTED (not merely absent from
# the dict): the docket is explicit that "OSHPark is bare-board only", so a
# caller asking for an OSHPark assembly package gets a refusal that SAYS that,
# distinct from asking for a house this module has simply never heard of.
PROFILES: dict[str, HouseProfile] = {
    JLCPCB_ECONOMIC.id: _house_profile(
        JLCPCB_ECONOMIC, selector=JLCPCB_ECONOMIC.id, select_service=True),
    "jlc": _house_profile(JLCPCB_ECONOMIC, selector="jlc", select_service=False),
    "oshpark": HouseProfile(
        id="oshpark", display_name="OSH Park", supports_assembly=False,
    ),
}


def _resolve_profile(profile_id) -> HouseProfile:
    if not isinstance(profile_id, str) or not profile_id.strip():
        raise AssemblyProfileError(
            f"assembly house profile id must be a non-empty string; got {profile_id!r}")
    profile = PROFILES.get(profile_id)
    if profile is None:
        known = ", ".join(sorted(PROFILES))
        raise AssemblyProfileError(
            f"unknown assembly house profile {profile_id!r}; known profiles: {known}")
    if not profile.supports_assembly:
        raise AssemblyProfileError(
            f"{profile.display_name!r} ({profile_id!r}) does not offer assembly "
            f"(BOM/CPL) service — refusing to emit an assembly package for it")
    return profile


@dataclass(frozen=True)
class BomRow:
    """One grouped BOM line, in EMITTED COLUMNS rather than authored fields.

    Each field below is a cell of the rendered row, already resolved through
    the module docstring's column table (authored field, else its fallback), so
    a renderer never re-decides what a column means and two renderers cannot
    decide differently. ``mpn`` rides alongside as the manufacturer's own
    number: it is what ``part_number`` falls back to, and a caller comparing an
    order against a distributor quote needs both.

    ``mpn`` DESCRIBES EVERY REF ON THE LINE, because the grouping key in
    :func:`_walk` covers it. A row therefore never reports a part number that
    is true of only some of its designators — the failure a reconciler cannot
    detect and the reason the row does not simply carry the first component's."""

    refs: tuple[str, ...]
    comment: str
    footprint: str
    part_number: str | None
    mpn: str | None
    qty: int


@dataclass(frozen=True)
class CplRow:
    ref: str
    x_mm: float
    y_mm: float
    rotation_deg: float
    side: str  # "top" | "bottom"
    mpn: str | None


def _assembly_of(component):
    """The component's resolved assembly facts, or a NAMED refusal.

    A compiled component always carries them (compile_board attaches one to
    every component it admits), so ``None`` means an IR built by something
    other than the compiler reached an order emitter — refused rather than read
    as "this part has no assembly facts", which would silently drop its
    identity requirement."""
    assembly = getattr(component, "assembly", None)
    if assembly is None:
        raise AssemblyBoardError(
            f"component {component.ref!r} carries no resolved assembly block; "
            f"assembly outputs are derived only from a strict compilation")
    return assembly


def _check_identity(profile: HouseProfile, ref: str, assembly) -> None:
    """Raise AssemblyIdentityError, naming the component, when it lacks an
    identity field ``profile`` REQUIRES. Side-effect-only: callers read the
    actual values back off ``assembly`` afterward, so a profile with an EMPTY
    requirement set still surfaces an informational value (e.g. mpn) when the
    author supplied one, without requiring it."""
    missing = [f for f in profile.identity_required if getattr(assembly, f, None) is None]
    if missing:
        error = AssemblyIdentityError(
            f"component {ref!r} is missing required identity field(s) "
            f"{'/'.join(missing)} for assembly profile {profile.id!r} — refusing to "
            f"emit a BOM/CPL row with a blank identity cell (part-identity contract)")
        # The refusal's SUBJECT, carried structurally as well as in the prose, so
        # a surface can point at the component and the field without parsing the
        # sentence — the same contract assembly_gates.AssemblyGateError has.
        error.component = ref
        error.field = "/".join(f"assembly.{f}" for f in missing)
        raise error


def _physical_placements_of(component):
    """The PARTS this component resolves to, or a NAMED refusal.

    Same contract and same reason as :func:`_assembly_of`: the compiler attaches
    at least one to every component it admits, so an empty tuple means an IR
    built by something other than the compiler reached an order emitter. Read as
    "this component places nothing" it would silently drop a part from the
    order — including, for an expansion, every part but the one that shares the
    component's own ref."""
    placements = getattr(component, "physical_placements", ())
    if not placements:
        raise AssemblyBoardError(
            f"component {component.ref!r} carries no resolved physical placements; "
            f"assembly outputs are derived only from a strict compilation")
    return placements


def _walk(board, profile: HouseProfile):
    """ONE walk of the compiled board producing everything both files and every
    gate need: the grouped BOM rows, the CPL rows, the designators left out, and
    the (designator, owning component) pairs the uniqueness gate names collisions
    with.

    A non-populated part (board furniture, or a DNP) is RECORDED as excluded and
    contributes no row, BEFORE the identity contract: a fiducial has no MPN and
    must not be refused for lacking one. It still passes the per-component gates
    and still owns its designator — being unbought does not make a part invisible
    to the board.

    ``excluded`` records the PHYSICAL refs, not the component ref: a
    non-populated component that expands into several parts leaves several
    designators out of the order, and naming only the drawing would under-report
    what a house is not being sent.
    """
    groups: dict[tuple, dict] = {}
    cpl: list[CplRow] = []
    excluded: list[str] = []
    placed: list[tuple[str, str]] = []
    for component in board.components:
        assembly = _assembly_of(component)
        placements = _physical_placements_of(component)
        placed.extend((item.ref, component.ref) for item in placements)
        if not assembly.populate:
            excluded.extend(item.ref for item in placements)
            continue
        _check_identity(profile, component.ref, assembly)

        # THE DOCUMENTED COLUMNS, each with its ONE fallback (module docstring).
        # The fallbacks are what a board authored before the block existed: the
        # component's value, the footprint string it routes against, and the
        # manufacturer's part number. The AUTHORED footprint string is used,
        # never the IR's content-hash footprint_id, because this column names a
        # part a purchaser recognizes.
        #
        # FALLBACK ON ABSENCE, NOT ON FALSITY. Each test is ``is None``, never
        # ``or``: a field that is PRESENT AND EMPTY is an authored blank cell,
        # and ``or`` cannot tell it from an absent one — it would print the
        # fallback into a column the author deliberately blanked.
        comment = component.value if assembly.comment is None else assembly.comment
        footprint = (assembly.footprint_ref if assembly.package is None
                     else assembly.package)
        house_number = dict(assembly.house_parts).get(profile.house_part_id)
        part_number = assembly.mpn if house_number is None else house_number

        # BOM GROUPING KEY = EVERYTHING THE ROW ASSERTS ABOUT ALL OF ITS REFS:
        # every cell of the rendered row except the Designator list, PLUS the
        # ``mpn`` the row carries beside those cells. Grouping on a narrower key
        # (the part number alone) would merge two rows a house reads as
        # different parts; grouping on a key narrower than what the ROW reports
        # lets one line report one component's mpn for refs it does not
        # describe. The emitted cells come from the RESOLVED columns above, not
        # the authored fields behind them, so two components that print
        # identically are one line whichever field each authored it in.
        key = (footprint, comment, part_number or "", assembly.mpn or "")
        grp = groups.setdefault(key, {
            "refs": [], "comment": comment, "footprint": footprint,
            "part_number": part_number, "mpn": assembly.mpn,
        })
        # ONE REF PER PART, not per drawing: a component carrying a synthetic
        # expansion contributes each authored physical designator, so a grouped
        # row's qty is the number of parts a house buys rather than the number
        # of symbols the board draws.
        grp["refs"].extend(item.ref for item in placements)

        for physical in placements:
            # THE ANCHOR, NOT THE POSITION. Then Y NEGATED, X VERBATIM, and X
            # NOT mirrored on the bottom side (the reference exporter's default;
            # its opt-in bottom-X-negate flag is deliberately not matched).
            # Rotation arrives already normalized into [0, 360) and is otherwise
            # the composed placement angle, verbatim. The measured oracle for all
            # of it is in tests/test_assembly_outputs.py — it may not be cited
            # from shipped worker code (STANDING GUARD 2) — and is written up in
            # docs/assembly-outputs.md.
            cpl.append(CplRow(
                ref=physical.ref,
                x_mm=float(physical.anchor[0]),
                y_mm=-float(physical.anchor[1]),
                rotation_deg=float(physical.rotation_deg),
                side=physical.side.value,
                mpn=assembly.mpn,
            ))

    bom = [
        BomRow(
            refs=tuple(sorted(g["refs"])), comment=g["comment"], footprint=g["footprint"],
            part_number=g["part_number"], mpn=g["mpn"], qty=len(g["refs"]),
        )
        for g in groups.values()
    ]
    bom.sort(key=lambda r: (r.footprint, r.comment, r.refs[0] if r.refs else ""))
    cpl.sort(key=lambda r: r.ref)
    return bom, cpl, tuple(excluded), placed


@dataclass(frozen=True)
class AssemblyEmission:
    """Both files' rows from one walk, plus what rode along with them.

    Returned whole so a caller that wants both — a package builder, a preview —
    compiles and walks the board ONCE. :func:`build_bom` and :func:`build_cpl`
    are thin renderers over this."""

    profile: HouseProfile
    bom: tuple[BomRow, ...]
    cpl: tuple[CplRow, ...]
    excluded_refs: tuple[str, ...]
    advisories: tuple[dict, ...]
    #: What the SELECTED SERVICE states it does not check, each with its reason.
    #: Empty for a selector that claims no tier. Carried out of the emission
    #: rather than left in the profile file because a rule nobody is told about
    #: is indistinguishable from a rule nobody wrote: the caller that receives
    #: the files is the one that has to know what was not looked at.
    unchecked: tuple[dict, ...] = ()


def emit(board, profile_id: str) -> AssemblyEmission:
    """Walk the compiled board once, run every hard gate, collect the
    advisories — or refuse by name. The single entry point behind both files."""
    profile = _resolve_profile(profile_id)
    assembly_gates.check_profile(profile)
    # THE SERVICE FIRST, when one is selected. A tier incompatibility is not
    # something an author fixes by editing an assembly block — the house will
    # not build the board at all — so naming it before the per-component data
    # gates avoids sending somebody to correct paste policy on a board the tier
    # was never going to accept.
    service_advisories: tuple[dict, ...] = ()
    unchecked: tuple[dict, ...] = ()
    if profile.service is not None:
        service_advisories = service_profile.check_board(board, profile.service)
        unchecked = profile.service.unchecked_rules
    assembly_gates.check_components(board)
    bom, cpl, excluded, placed = _walk(board, profile)
    assembly_gates.check_designators(placed)
    assembly_gates.check_reference_sets(bom, cpl)
    assembly_gates.check_row_limits(bom, profile)
    assembly_gates.check_placement_spacing(cpl, profile, dict(placed))
    return AssemblyEmission(profile=profile, bom=tuple(bom), cpl=tuple(cpl),
                            excluded_refs=excluded,
                            advisories=assembly_gates.advisories(board) + service_advisories,
                            unchecked=unchecked)


def _csv_line(fields) -> str:
    out = []
    for f_ in fields:
        s = "" if f_ is None else str(f_)
        if any(ch in s for ch in (",", '"', "\n", "\r")):
            s = '"' + s.replace('"', '""') + '"'
        out.append(s)
    return ",".join(out)


def _fmt_mm(value: float) -> str:
    # Fixed 4-decimal formatting: stable across runs (Python float repr is
    # already deterministic, but a fixed format also avoids "10.0" vs "10"
    # drift if an upstream caller ever hands us an int-valued float).
    return f"{value:.4f}"


def _render_jlc_bom(rows: list[BomRow], profile: HouseProfile) -> str:
    """The header row and the designator separator both come from the PROFILE,
    so what this emits and what the pinned template contains are two lists a
    reader can hold beside each other (``service_profile._check_drift`` does
    exactly that at load)."""
    lines = [_csv_line(profile.bom_columns)]
    for row in rows:
        lines.append(_csv_line([
            row.comment, profile.designator_separator.join(row.refs),
            row.footprint, row.part_number or "",
        ]))
    return CSV_EOL.join(lines) + CSV_EOL


def _render_jlc_cpl(rows: list[CplRow], profile: HouseProfile) -> str:
    lines = [_csv_line(profile.cpl_columns)]
    for row in rows:
        lines.append(_csv_line([
            row.ref,
            _fmt_mm(row.x_mm) + profile.coordinate_suffix,
            _fmt_mm(row.y_mm) + profile.coordinate_suffix,
            profile.layer_token(row.side),
            _fmt_mm(row.rotation_deg),
        ]))
    return CSV_EOL.join(lines) + CSV_EOL


class AssemblyResult(dict):
    """``{filename: content}`` — same "callers can treat this as a plain
    dict" contract as ``gerber.GerberResult`` (it IS one), with the rows that
    produced the file kept as a side channel for tests that want to assert on
    structured data rather than re-parsing the CSV. ``excluded_refs`` is the
    second side channel (epoch CPN1): the refs skipped by ``assembly:
    exclude``, in board order — always a tuple, empty when nothing was
    excluded, so a reply can surface the advisory absent-when-empty.
    ``advisories`` is the third and follows the same absent-when-empty idiom:
    findings a surface should SHOW without refusing (assembly_gates and the
    selected service). ``unchecked`` is the fourth: what the selected service
    states it did NOT look at, so a caller can tell an all-clear from an
    unexamined one."""

    def __init__(self, files: dict[str, str], rows,
                 excluded_refs: tuple[str, ...] = (),
                 advisories: tuple[dict, ...] = (),
                 unchecked: tuple[dict, ...] = ()):
        super().__init__(files)
        self.rows = rows
        self.excluded_refs = excluded_refs
        self.advisories = advisories
        self.unchecked = unchecked


#: ``dialect id -> (BOM renderer, CPL renderer)``. Keyed on
#: :attr:`HouseProfile.renderer_id` rather than on the selector, because the CSV
#: FORMAT and the SERVICE TIER are different facts: every JLCPCB tier writes one
#: dialect, and keying on the selector would have needed a new entry (or a new
#: branch) for each tier that shares it.
_RENDERERS = {"jlc": (_render_jlc_bom, _render_jlc_cpl)}


def _renderers(profile: HouseProfile):
    try:
        return _RENDERERS[profile.renderer_id]
    except KeyError:
        raise AssemblyProfileError(
            f"no renderer wired for dialect {profile.renderer_id!r} "
            f"(profile {profile.id!r}); known dialects: "
            f"{', '.join(sorted(_RENDERERS))}") from None


def bom_filename(profile: HouseProfile, name: str | None = None) -> str:
    """The emitted BOM's name. Tagged with the DIALECT, not the selector: the
    tag says what format the file is in, and every tier of one house writes the
    same format."""
    return f"{name or 'board'}-bom-{profile.renderer_id}.csv"


def cpl_filename(profile: HouseProfile, name: str | None = None) -> str:
    return f"{name or 'board'}-cpl-{profile.renderer_id}.csv"


def build_bom(board, profile_id: str, *, name: str | None = None) -> AssemblyResult:
    """House-agnostic BOM extraction rendered through ``profile_id``'s house
    format. ``board`` is a compiled ``resolved_board.ResolvedBoard`` — the same
    object the gerber emitter reads. Raises AssemblyProfileError /
    AssemblyIdentityError / AssemblyBoardError / AssemblyGateError — never
    returns a partial or best-guess result."""
    emission = emit(board, profile_id)
    render_bom, _ = _renderers(emission.profile)
    return AssemblyResult({bom_filename(emission.profile, name): render_bom(emission.bom, emission.profile)},
                          list(emission.bom), emission.excluded_refs,
                          emission.advisories, emission.unchecked)


def build_cpl(board, profile_id: str, *, name: str | None = None) -> AssemblyResult:
    """House-agnostic CPL/pick-and-place extraction rendered through
    ``profile_id``'s house format. Same compiled-IR input and same fail-closed
    contract as :func:`build_bom`."""
    emission = emit(board, profile_id)
    _, render_cpl = _renderers(emission.profile)
    return AssemblyResult({cpl_filename(emission.profile, name): render_cpl(emission.cpl, emission.profile)},
                          list(emission.cpl), emission.excluded_refs,
                          emission.advisories, emission.unchecked)


@dataclass(frozen=True)
class AssemblyPackage:
    """Both order files from ONE emission of ONE compiled board.

    THE ORDER BOUNDARY. A caller that wants the pair must come through here
    rather than calling :func:`build_bom` and :func:`build_cpl` in turn: those
    are two emissions, and if the board, library or footprint state moves
    between them the two files describe two different resolved boards while the
    reference-set gate inside each still passes. The gate compares the rows of
    ONE walk, so it can only prove the two files agree when there is one walk.

    ``files`` is the ``{filename: content}`` mapping the writers take; the two
    name fields say which entry is which without re-deriving a filename."""

    emission: AssemblyEmission
    bom_file: str
    cpl_file: str
    files: dict[str, str]


def build_package(board, profile_id: str, *, name: str | None = None) -> AssemblyPackage:
    """Both order CSVs from one compilation, one walk and one gate run."""
    emission = emit(board, profile_id)
    render_bom, render_cpl = _renderers(emission.profile)
    bom_file = bom_filename(emission.profile, name)
    cpl_file = cpl_filename(emission.profile, name)
    return AssemblyPackage(
        emission=emission, bom_file=bom_file, cpl_file=cpl_file,
        files={bom_file: render_bom(emission.bom, emission.profile),
               cpl_file: render_cpl(emission.cpl, emission.profile)})


# ---------------------------------------------------------------------------
# The named refusal for a board that cannot be compiled at all.
# ---------------------------------------------------------------------------

#: The refusal kind an order surface sees when the board did not compile. Its
#: own name, distinct from the generic ``compile`` kind the fab tools use,
#: because it reports a CAPABILITY REGRESSION a caller may remember working:
#: BOM/CPL used to be emitted off the raw board dict and are now derived from
#: the same strict compilation the gerbers are.
NOT_COMPILABLE_KIND = "assembly_not_compilable"


def not_compilable_error(compile_error: dict) -> dict:
    """Re-shape a compile failure into the NAMED assembly refusal.

    Takes the ``{kind, message, diagnostics}`` error payload the shared strict-
    compile prologue produces and returns the ``error`` payload the assembly
    surfaces refuse with. ``blocked_by`` is the ERROR-severity subset, each
    entry naming the code and the entity (component, pad, footprint) that
    blocked the compile, so a caller sees WHICH part stopped the order rather
    than a bare "compile failed". The full diagnostic list rides along
    unchanged so nothing is lost by summarising.

    Works on the serialized payload rather than the ``ResolutionFailure``
    object so this module keeps its one-way dependency: emitters read the IR,
    they do not import the compiler."""
    diagnostics = compile_error.get("diagnostics") or []
    blocked_by = [
        {
            "code": d.get("code", ""),
            "entity_kind": (d.get("source_ref") or {}).get("entity_kind", ""),
            "entity_id": (d.get("source_ref") or {}).get("entity_id", ""),
            "message": d.get("message", ""),
        }
        for d in diagnostics if d.get("severity") == "error"
    ]
    named = "; ".join(f"{b['code']} on {b['entity_id']}" for b in blocked_by[:5])
    if len(blocked_by) > 5:
        named += f"; (+{len(blocked_by) - 5} more)"
    message = (
        "assembly outputs (BOM/CPL) are derived from ONE strict compilation of the "
        "board — the same compilation the gerbers come from — so a board that does "
        "not compile yields no BOM and no CPL. "
        + (f"{len(blocked_by)} error(s) blocked it: {named}" if blocked_by
           else str(compile_error.get("message", "board could not be compiled"))))
    return {"kind": NOT_COMPILABLE_KIND, "message": message,
            "blocked_by": blocked_by, "diagnostics": diagnostics}
