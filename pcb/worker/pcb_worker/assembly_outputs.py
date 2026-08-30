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
renderer (JLCPCB-style CSV, ``PROFILES["jlc"]``). An unrecognized or
assembly-incapable house id is a NAMED refusal (:class:`AssemblyProfileError`),
never a silent best-guess format.

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

from . import assembly_gates
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
    # comparison. The real figures are facts a house publishes and the service-
    # profile work pins; the gates read them off whatever profile is selected,
    # so filling in a measured limit later is a data change, not a code change.
    # Defaults and rationale live in assembly_gates.
    max_refs_per_row: int = assembly_gates.DEFAULT_MAX_REFS_PER_ROW
    min_designator_separation_mm: float = (
        assembly_gates.DEFAULT_MIN_DESIGNATOR_SEPARATION_MM)
    coordinate_unit: str = assembly_gates.METRIC_COORDINATE_UNIT

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


# The ONE JLC-style profile this unit ships (scope: "house-format-agnostic
# core + ONE JLC-style profile"). JLCPCB's SMT assembly service requires an
# LCSC part number per placed part — that is what ``identity_required``
# encodes; a component missing it is a structured refusal, not a blank BOM
# cell (see module docstring, PART-IDENTITY CONTRACT).
#
# ``oshpark`` is deliberately KNOWN-BUT-UNSUPPORTED (not merely absent from
# the dict): the docket is explicit that "OSHPark is bare-board only", so a
# caller asking for an OSHPark assembly package gets a refusal that SAYS that,
# distinct from asking for a house this module has simply never heard of.
PROFILES: dict[str, HouseProfile] = {
    "jlc": HouseProfile(
        id="jlc", display_name="JLCPCB", supports_assembly=True,
        identity_required=("mpn",),
        # Boards name JLC's catalogue by the house's full id, not the short
        # profile selector — measured on the shipped fixtures, which all author
        # ``house_parts: {jlcpcb: …}``.
        house_part_key="jlcpcb",
    ),
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
    order against a distributor quote needs both."""

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
        comment = assembly.comment or component.value
        footprint = assembly.package or assembly.footprint_ref
        part_number = dict(assembly.house_parts).get(profile.house_part_id) or assembly.mpn

        # BOM GROUPING KEY = THE COMPLETE EMITTED IDENTITY, i.e. every cell of
        # the rendered row except the Designator list itself. Grouping on a
        # narrower key (the part number alone) would merge two rows a house
        # reads as different parts; grouping on a wider one would split a row
        # over a difference the file never carries. It is therefore built from
        # the RESOLVED columns above, not the authored fields behind them: two
        # components that print identically are one line whichever field each
        # authored it in.
        key = (footprint, comment, part_number or "")
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


def emit(board, profile_id: str) -> AssemblyEmission:
    """Walk the compiled board once, run every hard gate, collect the
    advisories — or refuse by name. The single entry point behind both files."""
    profile = _resolve_profile(profile_id)
    assembly_gates.check_profile(profile)
    assembly_gates.check_components(board)
    bom, cpl, excluded, placed = _walk(board, profile)
    assembly_gates.check_designators(placed)
    assembly_gates.check_reference_sets(bom, cpl)
    assembly_gates.check_row_limits(bom, profile)
    assembly_gates.check_placement_spacing(cpl, profile, dict(placed))
    return AssemblyEmission(profile=profile, bom=tuple(bom), cpl=tuple(cpl),
                            excluded_refs=excluded,
                            advisories=assembly_gates.advisories(board))


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


def _render_jlc_bom(rows: list[BomRow]) -> str:
    lines = [_csv_line(["Comment", "Designator", "Footprint", "LCSC Part #"])]
    for row in rows:
        lines.append(_csv_line([
            row.comment, ",".join(row.refs), row.footprint, row.part_number or "",
        ]))
    return CSV_EOL.join(lines) + CSV_EOL


def _render_jlc_cpl(rows: list[CplRow]) -> str:
    lines = [_csv_line(["Designator", "Mid X", "Mid Y", "Layer", "Rotation"])]
    for row in rows:
        lines.append(_csv_line([
            row.ref, _fmt_mm(row.x_mm), _fmt_mm(row.y_mm),
            "Top" if row.side == "top" else "Bottom",
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
    findings a surface should SHOW without refusing (assembly_gates)."""

    def __init__(self, files: dict[str, str], rows,
                 excluded_refs: tuple[str, ...] = (),
                 advisories: tuple[dict, ...] = ()):
        super().__init__(files)
        self.rows = rows
        self.excluded_refs = excluded_refs
        self.advisories = advisories


#: ``profile id -> (BOM renderer, CPL renderer)``. One table, so a profile
#: declared assembly-capable with no renderer is one missing entry rather than
#: two divergent dispatch branches.
_RENDERERS = {"jlc": (_render_jlc_bom, _render_jlc_cpl)}


def _renderers(profile: HouseProfile):
    try:
        return _RENDERERS[profile.id]
    except KeyError:  # pragma: no cover - unreachable while PROFILES has one assembly-capable entry
        raise AssemblyProfileError(
            f"no renderer wired for profile {profile.id!r}") from None


def bom_filename(profile: HouseProfile, name: str | None = None) -> str:
    return f"{name or 'board'}-bom-{profile.id}.csv"


def cpl_filename(profile: HouseProfile, name: str | None = None) -> str:
    return f"{name or 'board'}-cpl-{profile.id}.csv"


def build_bom(board, profile_id: str, *, name: str | None = None) -> AssemblyResult:
    """House-agnostic BOM extraction rendered through ``profile_id``'s house
    format. ``board`` is a compiled ``resolved_board.ResolvedBoard`` — the same
    object the gerber emitter reads. Raises AssemblyProfileError /
    AssemblyIdentityError / AssemblyBoardError / AssemblyGateError — never
    returns a partial or best-guess result."""
    emission = emit(board, profile_id)
    render_bom, _ = _renderers(emission.profile)
    return AssemblyResult({bom_filename(emission.profile, name): render_bom(emission.bom)},
                          list(emission.bom), emission.excluded_refs,
                          emission.advisories)


def build_cpl(board, profile_id: str, *, name: str | None = None) -> AssemblyResult:
    """House-agnostic CPL/pick-and-place extraction rendered through
    ``profile_id``'s house format. Same compiled-IR input and same fail-closed
    contract as :func:`build_bom`."""
    emission = emit(board, profile_id)
    _, render_cpl = _renderers(emission.profile)
    return AssemblyResult({cpl_filename(emission.profile, name): render_cpl(emission.cpl)},
                          list(emission.cpl), emission.excluded_refs,
                          emission.advisories)


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
        files={bom_file: render_bom(emission.bom),
               cpl_file: render_cpl(emission.cpl)})


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
