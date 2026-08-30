"""Assembly-package outputs: BOM (bill of materials) + CPL (component
placement list / pick-and-place) for pre-assembled board ordering (docket
019f763cdf5b).

Scope:

  * ONE COMPILATION FEEDS EVERY ORDER ARTIFACT. Both emitters read the compiled
    ``ResolvedBoard`` IR — the same object ``gerber.build_gerbers_ir`` reads —
    and nothing else. They used to read the RAW canonical board dict instead,
    which meant a single order could carry CSVs describing one board and
    gerbers describing another: the dict path emitted rows for placements the
    compiler had never resolved, footprints no library supplies, and pins whose
    declared positions the coincidence check refuses. Every coordinate, side,
    rotation, value and part identity below now comes from a component the
    compiler admitted.

    THE DELIBERATE CAPABILITY REGRESSION this creates, stated rather than
    discovered: a board that cannot strictly compile could produce a BOM and a
    CPL before, and cannot now. That outcome is a NAMED, structured refusal
    identifying what blocked compilation (:func:`not_compilable_error`) — never
    a traceback, and never a partial CSV.
  * House-format-agnostic CORE (:func:`_walk`, one pass, both files) plus
    exactly ONE house-specific renderer (JLCPCB-style CSV, ``PROFILES["jlc"]``).
    An unrecognized or assembly-incapable house id is a NAMED refusal
    (:class:`AssemblyProfileError`) — never a silent best-guess format.
  * PART-IDENTITY CONTRACT: a component the selected profile requires identity
    for (today: ``mpn``) and that lacks it is a NAMED, structured refusal
    (:class:`AssemblyIdentityError`) naming the component ref — never a blank
    BOM/CPL cell. A component the profile does NOT require identity for (no
    profile selected, or a future profile with an empty requirement set) is
    emitted with an empty field, same as today's ``extract_bom`` (a blank
    value/footprint is a warning, not a fatal — the identity contract adds a
    STRICTER, profile-gated rule on top of that, it does not relax it).

  * HARD GATES, NAMED. Before either file is rendered, the rows both emitters
    built are put through :mod:`assembly_gates` — designator uniqueness,
    BOM/CPL reference-set equality, the profile's per-row designator cap and
    minimum placement separation, and the per-component authored-expansion and
    do-not-populate-paste rules. Every one refuses with a stable code naming the
    component and the field. ADVISORIES (what the pipeline could not measure)
    ride back on the result instead of refusing.
  * ONE EMISSION, TWO FILES. :func:`emit` builds the BOM rows AND the CPL rows in
    a single walk of the compiled board, and both :func:`build_bom` and
    :func:`build_cpl` render out of it. That is what lets the reference-set gate
    compare the files a caller actually receives rather than a third derivation
    of the board — and it is why asking for only the BOM still refuses when the
    CPL would have disagreed with it.

PASTE NON-CLAIM: neither output here says anything about solder-paste
coverage. Paste is emitted by ``gerber.py`` (``F_Paste``/``B_Paste``) and is
fail-closed there since docket 019fb0155d93/019fb079ce60 (see
``fab_capability.FABRICATION_CRITICAL_OUTPUTS``). A BOM/CPL pair is NOT a
stencil and must never be read as one.

ROTATION CONVENTION — read before touching any rotation math here:

    CPL ``Rotation`` is emitted VERBATIM from the component's authored
    ``rotation_deg`` (normalized to ``[0, 360)`` only — no sign change, no
    trigonometry). This is deliberately the SAME number ``compile_board``
    threads unchanged into ``Placement.rotation_deg`` (compile_board.py:2275,
    ``rotation_deg=float(rotation or 0.0)``) and the SAME convention
    ``geometry.py`` documents as "KiCad-equivalent": KiCad applies a footprint
    ``(at x y rot)`` angle CLOCKWISE in the file's Y-down frame
    (``math.radians(-deg)``), exactly matching
    ``agent_router/kicad_io.py::_transform_position`` (`rad =
    math.radians(-rotation)` — "KiCad uses clockwise rotation in screen
    coords", kicad_io.py:495). geometry.py is the pinned single source for
    this (tests/test_rotation.py, tests/test_geometry.py:73, docket
    019f3ba0f455). KiCad's own Footprint Position File plugin dumps this same
    stored angle unmodified — it does not re-sign it — and JLCPCB's SMT
    upload flow is documented to accept a KiCad-generated position file
    as-is. So the emitter's job is to reproduce THAT number faithfully.

    AND THAT IS ALREADY JLC's COUNTER-CLOCKWISE-POSITIVE CONVENTION, which is
    not a coincidence and not a second decision: the angle is clockwise in a
    Y-DOWN frame, and negating Y (which the COORDINATE FRAME section below
    does to every row) conjugates a clockwise turn into a counter-clockwise
    one. In the frame the CSV is actually written in, a part at rotation 90
    has turned 90 degrees COUNTER-CLOCKWISE from its rotation-0 pose — on BOTH
    sides of the board, because the bottom-side mirror cancels against that
    same Y negation. Proven on real library geometry, rather than by this
    argument, in ``tests/test_assembly_anchor.py``.

    NON-CLAIM (the trap the docket names explicitly): this is NOT the same
    thing as "the part will mount right-side-up in JLC's SMT feeder." JLC's
    OWN internal component-library images sometimes disagree with a
    footprint's 0-degree reference — a PER-PART-TYPE calibration problem
    ("JLCPCB rotation cheat sheet"), not a board-wide sign convention. JLC's
    own placement-review UI is where a customer catches and corrects that
    class of error; it is a part-identity/library-modeling problem
    (coordinated with contract item 019f761fe518), not something a coordinate
    transform in THIS module can discover from a board YAML alone. Emitting
    the wrong global sign here would rotate EVERY part; not correcting a
    per-part JLC calibration quirk rotates at most a few footprint families —
    the two are different bugs with different owners, and this module claims
    to fix only the first one.

    (Boards authored in the pcb-architect dialect use the OPPOSITE sign for
    their own ``rotation`` field; per geometry.py, that is reconciled at
    IMPORT time, before a component ever reaches this module — so
    ``rotation_deg`` here is already KiCad-equivalent by the time we see it.)

ASSEMBLY ANCHOR — WHAT THE COORDINATE IS. A CPL row carries the PART's centre,
not the drawing's datum. ``x_mm``/``y_mm`` place the FOOTPRINT ORIGIN, and where
that origin sits on the part is a property of the footprint: measured over
``pcb/library/footprints``, 14 of 39 put it on pin 1 and 18 resolve an anchor
somewhere other than their origin, so emitting the placement position as a
pick-and-place coordinate is wrong by up to half a package. Every row below
therefore reads ``ResolvedComponent.physical_placements`` — the resolved,
explicitly-based body-centre anchors ``assembly_anchor`` composes at compile
time — and never ``Placement.position``. One consequence stated plainly, since
it changed numbers a caller may have on file: the emitted coordinate of every
part whose footprint origin differs from its body centre MOVED when that anchor
landed; a part whose origin already IS its body centre (every chip-scale SMD
footprint in the seed library) emits exactly what it emitted before.

The same list is also what makes a SYNTHETIC EXPANSION real. One drawn
component carrying ``assembly.placements`` stands for several soldered parts,
and each contributes its own CPL row under its own authored designator and its
own BOM quantity — the expansion offset already composed against the parent's
rotation and side, once, by the compiler.

COORDINATE FRAME — MEASURED, NOT ASSUMED. CPL X is the resolved anchor's
X VERBATIM; CPL Y is its Y NEGATED. This is proven
against KiCad itself, not inferred from a Y-down/Y-up label — full command,
measured output table, and the byte-exact seal are in
``tests/test_assembly_outputs.py::test_cpl_y_matches_kicad_cli_position_file_oracle``
(this runtime module deliberately does not name the dev/CI-only export tool
here; see ``tests/test_kicad_cli_boundary.py`` — STANDING GUARD 2 — which
forbids that in shipped worker code and is why the citation lives in the test
instead). Summary of the finding: PosX matches the placed footprint
ORIGIN's X exactly; PosY is the NEGATION of its Y; Rot matches authored
``rotation_deg`` VERBATIM (confirming the ROTATION CONVENTION section above)
— a finding about the FRAME, which the anchor above is expressed in and does
not disturb;
a bottom-side part's X is UNMIRRORED (the reference exporter only negates X
for bottom parts under an opt-in flag, which the oracle run did NOT pass —
the omission is the profile decision this module makes: match the tool's
DEFAULT, not the opt-in). This is also consistent with ``gerber.py``'s own
``_Geometry.to_gerber_frame`` (gerber.py:466), which negates Y at its harvest
boundary for the identical reason: the placement frame is Y-DOWN, and every
consumer outside that one frame (Gerber's Y-up plot frame,
KiCad's own position-file export) negates it. A CPL is not a Gerber layer and
is not re-derived through ``_Geometry`` — this module negates Y itself, at
its own row-construction boundary (:func:`_walk`), rather than importing
gerber.py's frame converter. An earlier draft of this module claimed KiCad's
position-file export does NOT flip Y; that claim was never measured and was
WRONG — corrected here after running the oracle referenced above.
"""

from __future__ import annotations

from dataclasses import dataclass

from . import assembly_gates

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
    # DIALECT PARAMETERS, defaulted rather than hard-coded at the point of
    # comparison. The real figures are facts a house publishes and the service-
    # profile work pins; the gates read them off whatever profile is selected,
    # so filling in a measured limit later is a data change, not a code change.
    # Defaults and rationale live in assembly_gates.
    max_refs_per_row: int = assembly_gates.DEFAULT_MAX_REFS_PER_ROW
    min_designator_separation_mm: float = (
        assembly_gates.DEFAULT_MIN_DESIGNATOR_SEPARATION_MM)
    coordinate_unit: str = assembly_gates.METRIC_COORDINATE_UNIT


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
    refs: tuple[str, ...]
    value: str
    footprint: str
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

        # BOM GROUPING KEY = THE COMPLETE EMITTED IDENTITY, i.e. every cell of
        # the rendered row except the Designator list itself. Grouping on a
        # narrower key (the part number alone) would merge two rows a house
        # reads as different parts; grouping on a wider one would split a row
        # over a difference the file never carries.
        #
        # The AUTHORED footprint string, not the IR's content-hash footprint_id:
        # the BOM's Footprint column names a part a purchaser recognizes.
        # (assembly.package is its intended eventual home per the schema, but
        # moving the column would change what a house is sent and is not this
        # unit's job.)
        footprint = assembly.footprint_ref
        key = (footprint, component.value, assembly.mpn or "")
        grp = groups.setdefault(key, {
            "refs": [], "value": component.value, "footprint": footprint,
            "mpn": assembly.mpn,
        })
        # ONE REF PER PART, not per drawing: a component carrying a synthetic
        # expansion contributes each authored physical designator, so a grouped
        # row's qty is the number of parts a house buys rather than the number
        # of symbols the board draws.
        grp["refs"].extend(item.ref for item in placements)

        for physical in placements:
            # THE ANCHOR, NOT THE POSITION — see the module docstring's ASSEMBLY
            # ANCHOR section. Then Y NEGATED, X VERBATIM (COORDINATE FRAME
            # section; the measured oracle citation lives in
            # tests/test_assembly_outputs.py, not here — STANDING GUARD 2). X is
            # NOT mirrored on the bottom side either (the reference exporter's
            # default: its opt-in bottom-X-negate flag was NOT applied — the
            # profile decision this module makes, documented at the point of use
            # as instructed). Rotation arrives already normalized into [0, 360)
            # and is otherwise the composed placement angle, verbatim.
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
            refs=tuple(sorted(g["refs"])), value=g["value"], footprint=g["footprint"],
            mpn=g["mpn"], qty=len(g["refs"]),
        )
        for g in groups.values()
    ]
    bom.sort(key=lambda r: (r.footprint, r.value, r.refs[0] if r.refs else ""))
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
            row.value, ",".join(row.refs), row.footprint, row.mpn or "",
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


def build_bom(board, profile_id: str, *, name: str | None = None) -> AssemblyResult:
    """House-agnostic BOM extraction rendered through ``profile_id``'s house
    format. ``board`` is a compiled ``resolved_board.ResolvedBoard`` — the same
    object the gerber emitter reads. Raises AssemblyProfileError /
    AssemblyIdentityError / AssemblyBoardError / AssemblyGateError — never
    returns a partial or best-guess result."""
    emission = emit(board, profile_id)
    base = name or "board"
    if emission.profile.id == "jlc":
        content = _render_jlc_bom(emission.bom)
    else:  # pragma: no cover - unreachable while PROFILES has one assembly-capable entry
        raise AssemblyProfileError(
            f"no BOM renderer wired for profile {emission.profile.id!r}")
    return AssemblyResult({f"{base}-bom-{emission.profile.id}.csv": content},
                          list(emission.bom), emission.excluded_refs,
                          emission.advisories)


def build_cpl(board, profile_id: str, *, name: str | None = None) -> AssemblyResult:
    """House-agnostic CPL/pick-and-place extraction rendered through
    ``profile_id``'s house format. Same compiled-IR input and same fail-closed
    contract as :func:`build_bom`."""
    emission = emit(board, profile_id)
    base = name or "board"
    if emission.profile.id == "jlc":
        content = _render_jlc_cpl(emission.cpl)
    else:  # pragma: no cover - unreachable while PROFILES has one assembly-capable entry
        raise AssemblyProfileError(
            f"no CPL renderer wired for profile {emission.profile.id!r}")
    return AssemblyResult({f"{base}-cpl-{emission.profile.id}.csv": content},
                          list(emission.cpl), emission.excluded_refs,
                          emission.advisories)


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
