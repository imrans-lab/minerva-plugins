"""Assembly-package outputs: BOM (bill of materials) + CPL (component
placement list / pick-and-place) for pre-assembled board ordering (docket
019f763cdf5b).

Scope, deliberately narrow (C8, epoch C):

  * Operates on the RAW canonical board dict (the same loose-dict shape
    ``board_model.extract_bom`` already reads), NOT the compiled
    ``ResolvedBoard`` IR. This mirrors the one BOM path that already ships
    (``board_model.extract_bom``) rather than growing ``resolved_board.py`` /
    ``compile_board.py`` with a new per-component "properties" field this unit
    was not asked to model. A component's identity fields (MPN etc.) are read
    straight off its authored dict entry.
  * House-format-agnostic CORE (:func:`_bom_rows` / :func:`_cpl_rows`) plus
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

COORDINATE FRAME — MEASURED, NOT ASSUMED. CPL X is the authored ``x_mm``
VERBATIM; CPL Y is the authored ``y_mm`` NEGATED (``-y_mm``). This is proven
against KiCad itself, not inferred from a Y-down/Y-up label — full command,
measured output table, and the byte-exact seal are in
``tests/test_assembly_outputs.py::test_cpl_y_matches_kicad_cli_position_file_oracle``
(this runtime module deliberately does not name the dev/CI-only export tool
here; see ``tests/test_kicad_cli_boundary.py`` — STANDING GUARD 2 — which
forbids that in shipped worker code and is why the citation lives in the test
instead). Summary of the finding: PosX matches authored ``x_mm`` exactly;
PosY is the NEGATION of authored ``y_mm``; Rot matches authored
``rotation_deg`` VERBATIM (confirming the ROTATION CONVENTION section above);
a bottom-side part's X is UNMIRRORED (the reference exporter only negates X
for bottom parts under an opt-in flag, which the oracle run did NOT pass —
the omission is the profile decision this module makes: match the tool's
DEFAULT, not the opt-in). This is also consistent with ``gerber.py``'s own
``_Geometry.to_gerber_frame`` (gerber.py:466), which negates Y at its harvest
boundary for the identical reason: the canonical board dict's ``y_mm`` is
Y-DOWN, and every consumer outside that one frame (Gerber's Y-up plot frame,
KiCad's own position-file export) negates it. A CPL is not a Gerber layer and
is not re-derived through ``_Geometry`` — this module negates Y itself, at
its own row-construction boundary (:func:`_cpl_rows`), rather than importing
gerber.py's frame converter. An earlier draft of this module claimed KiCad's
position-file export does NOT flip Y; that claim was never measured and was
WRONG — corrected here after running the oracle referenced above.
"""

from __future__ import annotations

from dataclasses import dataclass

from .board_model import _as_list, _is_number
from .geometry import BOTTOM_LAYER_NAMES, TOP_LAYER_NAMES

CSV_EOL = "\r\n"  # JLC's own templates ship CRLF; keep it stable either way.


class AssemblyProfileError(ValueError):
    """The requested house id is unknown, or the house does not offer
    assembly (BOM/CPL) service at all — a NAMED refusal, never a silent
    best-guess format or a fallback to a different house's columns."""


class AssemblyIdentityError(ValueError):
    """A component lacks an identity field the selected profile REQUIRES
    (e.g. MPN) — a NAMED refusal identifying the component ref, never a
    blank BOM/CPL cell."""


class AssemblyBoardError(ValueError):
    """The board dict itself is structurally unusable for assembly output
    (mirrors board_model.extract_bom's error shape, but this module fails
    closed with an exception rather than an {"ok": False} payload — callers
    that want the tolerant shape should catch this, matching how
    ``gerber.build_gerbers_ir`` callers already catch emitter exceptions)."""


@dataclass(frozen=True)
class HouseProfile:
    """One assembly house's format contract. House-format-agnostic CORE row
    data (below) is rendered through exactly one of these per emit call."""

    id: str
    display_name: str
    supports_assembly: bool
    identity_required: tuple[str, ...] = ()


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


def _component_property(comp: dict, key: str) -> str | None:
    """Read an identity field off a component's authored dict entry.

    Checked in two places, both tolerant/optional passthrough per the
    canonical board-yaml contract (docs/board-yaml.md Extra fields): a
    top-level scalar (``comp["mpn"]``) or a nested ``properties`` mapping
    (``comp["properties"]["mpn"]``) — the latter so a future structured
    properties bag (part-identity contract item 019f761fe518) is honored
    without a second reader needing to be written.
    """
    direct = comp.get(key)
    if isinstance(direct, str) and direct.strip():
        return direct.strip()
    props = comp.get("properties")
    if isinstance(props, dict):
        nested = props.get(key)
        if isinstance(nested, str) and nested.strip():
            return nested.strip()
    return None


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


def _iter_components(board: dict):
    if not isinstance(board, dict):
        raise AssemblyBoardError(f"board must be a mapping, got {type(board).__name__}")
    for i, comp in enumerate(_as_list(board.get("components"))):
        if not isinstance(comp, dict):
            raise AssemblyBoardError(f"components[{i}] must be a mapping")
        ref = comp.get("ref")
        if not isinstance(ref, str) or not ref:
            raise AssemblyBoardError(f"components[{i}] is missing 'ref'")
        yield ref, comp


def _resolve_side(raw_layer, ref: str) -> str:
    """Map a component's authored ``layer`` to "top"/"bottom", MIRRORING
    ``compile_board._resolve_side`` (compile_board.py:2549-2562) field-for-
    field — this module must not be laxer than the compiler on the same
    input: absent (``None``) defaults to top (the legacy "no side authored"
    shape), a recognized token resolves, and anything else — INCLUDING a
    present-but-empty string — is a NAMED refusal, never a silent top
    default. ``geometry.is_top`` was used here previously and is WRONG for
    this purpose: it folds "" into the same "absent -> top" bucket as
    ``None`` (its own docstring: "absence is the legacy shape for the
    default side"), which is a real behavioral difference from compile_board
    and a cross-surface fail-open a caller could trigger with
    ``layer: ""``.

    Token vocabulary now read from geometry.TOP_LAYER_NAMES /
    BOTTOM_LAYER_NAMES — the single authority both this function and
    compile_board._resolve_side read (docket 019fc3105828), so the "field-
    for-field" claim above can no longer drift by hand-edit. The refusal
    shape (raise AssemblyBoardError) stays local, unchanged, and still
    deliberately different from compile_board's (return None + diags.error)."""
    if raw_layer is None:
        return "top"
    token = str(raw_layer).strip().lower()
    if token in TOP_LAYER_NAMES:
        return "top"
    if token in BOTTOM_LAYER_NAMES:
        return "bottom"
    raise AssemblyBoardError(
        f"component {ref!r}: unrecognized layer/side {raw_layer!r} — refusing "
        f"to default it to top (mirrors compile_board._resolve_side)")


def _is_assembly_excluded(comp: dict, ref: str) -> bool:
    """A component authoring ``assembly: exclude`` is board FURNITURE — a
    fiducial, a silk logo — physically on the board but never picked, placed,
    or purchased, so it belongs in NO BOM/CPL row and must not trip the
    part-identity contract (epoch CPN1, docket 019fe2fb07f8).

    Fail-closed on the value: ``exclude`` is the only recognized token, and a
    present-but-unrecognized value REFUSES rather than being read as "not
    excluded" — a typo (``exlcude``) silently landing a fiducial in the BOM
    with a fabricated identity requirement is exactly the quiet wrong-answer
    this module's every other refusal exists to prevent."""
    raw = comp.get("assembly")
    if raw is None:
        return False
    if raw == "exclude":
        return True
    raise AssemblyBoardError(
        f"component {ref!r} assembly must be 'exclude' when present, got {raw!r}")


def _check_identity(profile: HouseProfile, ref: str, comp: dict) -> None:
    """Raise AssemblyIdentityError, naming the component, when ``comp`` lacks
    an identity field ``profile`` REQUIRES. Side-effect-only: callers read the
    actual values back through :func:`_component_property` afterward, so a
    profile with an EMPTY requirement set still surfaces an informational
    value (e.g. mpn) when the author supplied one, without requiring it."""
    missing = [f for f in profile.identity_required if _component_property(comp, f) is None]
    if missing:
        raise AssemblyIdentityError(
            f"component {ref!r} is missing required identity field(s) "
            f"{'/'.join(missing)} for assembly profile {profile.id!r} — refusing to "
            f"emit a BOM/CPL row with a blank identity cell (part-identity contract)")


def _require_optional_str(comp: dict, key: str, ref: str) -> str:
    """A present value for ``key`` must be a string or the sort/group key
    below (mixed str/int tuples) TypeErrors with a bare traceback instead of
    a named refusal. Mirrors compile_board.py:2223-2229's identical check for
    ``value`` ("the canonical contract types Component.Value as a string; a
    present non-string value must not be stringified... review 630") —
    applied here to BOTH ``value`` and ``footprint`` since both sit in the
    same BOM sort/group key and either can poison it the same way."""
    raw = comp.get(key)
    if raw is not None and not isinstance(raw, str):
        raise AssemblyBoardError(
            f"component {ref!r} {key} must be a string, got {raw!r}")
    return raw or ""


def _bom_rows(board: dict, profile: HouseProfile,
              excluded: list[str] | None = None) -> list[BomRow]:
    groups: dict[tuple, dict] = {}
    for ref, comp in _iter_components(board):
        if _is_assembly_excluded(comp, ref):
            # Skipped BEFORE the identity contract: furniture has no MPN and
            # must not be refused for lacking one. The ref is RECORDED, never
            # silently dropped — the reply carries it as an advisory.
            if excluded is not None:
                excluded.append(ref)
            continue
        value = _require_optional_str(comp, "value", ref)
        footprint = _require_optional_str(comp, "footprint", ref)
        _check_identity(profile, ref, comp)
        mpn = _component_property(comp, "mpn")
        key = (footprint, value, mpn or "")
        grp = groups.setdefault(key, {
            "refs": [], "value": value, "footprint": footprint, "mpn": mpn,
        })
        grp["refs"].append(ref)
    rows = [
        BomRow(
            refs=tuple(sorted(g["refs"])), value=g["value"], footprint=g["footprint"],
            mpn=g["mpn"], qty=len(g["refs"]),
        )
        for g in groups.values()
    ]
    rows.sort(key=lambda r: (r.footprint, r.value, r.refs[0] if r.refs else ""))
    return rows


def _cpl_rows(board: dict, profile: HouseProfile,
              excluded: list[str] | None = None) -> list[CplRow]:
    rows: list[CplRow] = []
    for ref, comp in _iter_components(board):
        if _is_assembly_excluded(comp, ref):
            # Same skip-before-identity as _bom_rows; a fiducial is placed by
            # the FAB (it is bare copper), not by the assembly line.
            if excluded is not None:
                excluded.append(ref)
            continue
        _check_identity(profile, ref, comp)
        mpn = _component_property(comp, "mpn")
        x_mm, y_mm = comp.get("x_mm"), comp.get("y_mm")
        if not _is_number(x_mm) or not _is_number(y_mm):
            raise AssemblyBoardError(f"component {ref!r} has a non-numeric x_mm/y_mm")
        rotation = comp.get("rotation_deg")
        if rotation is not None and not _is_number(rotation):
            raise AssemblyBoardError(f"component {ref!r} has a non-numeric rotation_deg")
        rotation_deg = float(rotation or 0.0) % 360.0
        side = _resolve_side(comp.get("layer"), ref)
        # Y NEGATED, X VERBATIM — see module docstring's COORDINATE FRAME
        # section (the measured oracle citation lives in
        # tests/test_assembly_outputs.py, not here — STANDING GUARD 2). X is
        # NOT mirrored on the bottom side either (the reference exporter's
        # default: its opt-in bottom-X-negate flag was NOT applied — the
        # profile decision this module makes, documented at the point of use
        # as instructed).
        rows.append(CplRow(
            ref=ref, x_mm=float(x_mm), y_mm=-float(y_mm),
            rotation_deg=rotation_deg, side=side, mpn=mpn,
        ))
    rows.sort(key=lambda r: r.ref)
    return rows


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
    excluded, so a reply can surface the advisory absent-when-empty."""

    def __init__(self, files: dict[str, str], rows,
                 excluded_refs: tuple[str, ...] = ()):
        super().__init__(files)
        self.rows = rows
        self.excluded_refs = excluded_refs


def build_bom(board: dict, profile_id: str, *, name: str | None = None) -> AssemblyResult:
    """House-agnostic BOM extraction rendered through ``profile_id``'s house
    format. Raises AssemblyProfileError / AssemblyIdentityError /
    AssemblyBoardError — never returns a partial or best-guess result."""
    profile = _resolve_profile(profile_id)
    excluded: list[str] = []
    rows = _bom_rows(board, profile, excluded)
    base = name or "board"
    if profile.id == "jlc":
        content = _render_jlc_bom(rows)
    else:  # pragma: no cover - unreachable while PROFILES has one assembly-capable entry
        raise AssemblyProfileError(f"no BOM renderer wired for profile {profile.id!r}")
    return AssemblyResult({f"{base}-bom-{profile.id}.csv": content}, rows,
                          tuple(excluded))


def build_cpl(board: dict, profile_id: str, *, name: str | None = None) -> AssemblyResult:
    """House-agnostic CPL/pick-and-place extraction rendered through
    ``profile_id``'s house format. Same fail-closed contract as build_bom."""
    profile = _resolve_profile(profile_id)
    excluded: list[str] = []
    rows = _cpl_rows(board, profile, excluded)
    base = name or "board"
    if profile.id == "jlc":
        content = _render_jlc_cpl(rows)
    else:  # pragma: no cover - unreachable while PROFILES has one assembly-capable entry
        raise AssemblyProfileError(f"no CPL renderer wired for profile {profile.id!r}")
    return AssemblyResult({f"{base}-cpl-{profile.id}.csv": content}, rows,
                          tuple(excluded))
