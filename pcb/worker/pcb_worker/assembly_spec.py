"""The per-component ASSEMBLY facts the resolved IR carries.

An order package (BOM, CPL, gerbers, manifest) must describe ONE board. That
holds only if every artifact derives from the same compilation, so the compiler
has to know what an assembly house buys and places, not just what the fab
etches. This module is that knowledge: it reads a component's authored
``assembly`` block (docs/board-yaml.md) and produces the immutable
:class:`ResolvedAssembly` that ``ResolvedComponent.assembly`` carries.

It is a separate module from ``resolved_board`` for the same reason
``footprint_def`` is: the IR module declares the geometry contract and stays
free of readers that parse loose board dicts. ``ResolvedComponent`` annotates
the field by forward reference and duck-types it, exactly as it does
``refdes``.

IDENTITY HAS ONE HOME: the ``assembly`` block. A part number written as a
top-level component key or inside a ``properties`` mapping is not a second
home with a precedence rule; it is an unknown key the codec refuses at the file
boundary, so nothing here has to fold homes and no consumer can read a value
the block did not state.

A BLANK identity value is ABSENT, and there is deliberately no authored way to
force an empty BOM cell: the Go codec tags the fields ``omitempty``, so an
authored blank dies on the first serialize, and a rule that only Python
honoured would be a value that vanishes on promote.

THE FOOTPRINT COLUMN IS NOT AUTHORED PER COMPONENT. What a purchaser reads as
the part's package is a fact about the DRAWING, stated once on the footprint's
acquisition-lock entry (``footprints.lock.json`` ``assembly.package``) and
carried here as ``package_labels``, keyed by drawing ref, for the component's
own drawing and each placement child that names one. A drawing with no label
prints its ref verbatim — an honest fallback, never a guess.

A NON-STRING identity value REFUSES, naming the component and the field:
YAML reads an unquoted ``mpn: 0201`` as the number 129, and coercing would
print 129 into an order. This matches ``_house_parts`` below, which has always
refused a non-string.

EXCLUSION — two authored forms, one answer, fail-closed on either. ``assembly:
exclude`` (the pre-block scalar for board furniture: a fiducial, a silk logo)
and ``assembly: {populate: false}`` both mean the part is on the board but is
never picked, placed or purchased. A scalar that is not ``exclude``, or a
non-boolean ``populate``, REFUSES: a typo that quietly lands a fiducial in a
BOM with a fabricated identity requirement is the quiet wrong answer the whole
order path exists to prevent.

PER-PLACEMENT ANCHOR. An expansion child has NO geometry of its own — the
parent's footprint draws all of it, and the child is a ref plus a transform — so
without an authored answer every child inherits ONE anchor measured off the
parent's whole body. That is right when the drawing IS the part and wrong the
moment the drawing spreads several parts across itself: the DevKit socket set
draws two 1x22 rows whose true centres are (-11.43, 26.67) and (+11.43, 26.67),
while its fab box centre — the number every child would otherwise inherit — is
(0, 30.8485), between the rows and on neither. An optional ``anchor_mm``, stated
in the placement's own local frame and read here verbatim, is that answer;
absent, the parent-measured anchor still applies and nothing changes. It is
carried, not composed, for the same reason the offsets are.

A PLACEMENT MAY NAME THE FOOTPRINT IT IS. A child draws no copper, so on its
own it is a ref and a transform with no identity; ``footprint`` gives it one:
the library ref of the child's OWN land pattern (the 1x22 strip a socket-set
row is bought as). It is read here as a string and nothing more — resolving it
against the library is the compiler's job — and every consumer that asks a
PART question (its orientation pair, its body centre, its BOM footprint) reads
this drawing for a child that names one, while the copper stays the parent's.
Absent, the child is described by the parent's drawing exactly as before.

PLACEMENTS are carried, not composed. ``placements`` expands one authored
component into the several identical physical parts it stands for, each under
an authored, stable ref. This module validates the shape and hands the offsets
and rotations on verbatim; composing them against the parent's own rotation and
side is a transform question, and the transform is owned by the placement work,
not by this reader.

AUTHORED-EMPTY IS NOT ABSENT, which is why ``expansion_authored`` is carried
alongside the placements themselves. ``placements: []`` and no ``placements``
key at all both leave an empty tuple, and the anchor pass then resolves BOTH to
one implicit part under the component's own ref — so without the flag, a
component whose author said "this drawing stands for several parts" and then
named none would ship as an ordinary single part. The flag is the only surviving
evidence of the difference; the ORDER GATE is what refuses on it
(``assembly_gates``), not this reader, because a board mid-layout must still
load, compile and gerber.
"""

from __future__ import annotations

from dataclasses import dataclass
import math

#: Legacy scalar form of "this component is board furniture".
LEGACY_EXCLUDE = "exclude"

#: Paste tokens, mirroring internal/board/assembly.go's constants. ``auto``
#: (the default when the key is absent) leaves the decision to the land type.
PASTE_AUTO = "auto"
PASTE_INCLUDE = "include"
PASTE_EXCLUDE = "exclude"
PASTE_TOKENS = (PASTE_AUTO, PASTE_INCLUDE, PASTE_EXCLUDE)

#: The block's part-identity string fields.
IDENTITY_FIELDS = ("manufacturer", "mpn", "comment")

#: Sub-keys the block admits. An unknown key REFUSES rather than being dropped,
#: matching the Go codec (internal/board/assembly.go): a mistyped ``mpm`` that
#: vanishes here reappears later as "missing mpn" on a part that was authored.
_BLOCK_KEYS = frozenset(("populate", "paste", "house_parts", "placements")
                        + IDENTITY_FIELDS)

_PLACEMENT_KEYS = frozenset(("ref", "footprint", "offset_mm", "rotation_deg",
                             "anchor_mm"))


class AssemblySpecError(ValueError):
    """The authored ``assembly`` block is malformed. Carries no code of its
    own: the compiler records every one of these under the single
    ``invalid_component_assembly`` diagnostic, the same code the Go codec
    refuses with, so one refusal name covers the block on both surfaces."""


@dataclass(frozen=True)
class AssemblyPlacementSpec:
    """One physically placed instance of a component. ``offset_mm`` is in the
    PARENT's local frame, before the parent's rotation and side are applied —
    stated here because that is what makes it a transform input rather than a
    board coordinate.

    ``anchor_mm`` is this part's own body centre, measured from THIS placement's
    origin, and ``None`` means "not authored" — the anchor pass then measures
    one off the child's own footprint when it names one, else off the parent's.
    See the module docstring's PER-PLACEMENT ANCHOR section.

    ``footprint`` is the library ref of this part's OWN drawing, or ``None``
    when the placement is described by the parent's (the module docstring's A
    PLACEMENT MAY NAME THE FOOTPRINT IT IS)."""

    ref: str
    offset_mm: tuple[float, float] | None
    rotation_deg: float
    anchor_mm: tuple[float, float] | None = None
    footprint: str | None = None


@dataclass(frozen=True)
class ResolvedAssembly:
    """What an assembly house buys and places for one compiled component.

    ``footprint_ref`` is the component's AUTHORED ``footprint`` string. It rides
    here because it is what the BOM's Footprint column falls back to when no
    label is stated for it, and the IR otherwise keeps only ``footprint_id`` —
    a content hash that names the geometry, not the part a purchaser
    recognizes.

    ``house_parts`` is a sorted tuple of ``(house id, catalogue number)`` pairs
    rather than a mapping, so the whole object stays hashable and frozen like
    every other IR node."""

    footprint_ref: str
    populate: bool
    manufacturer: str | None
    mpn: str | None
    comment: str | None
    house_parts: tuple[tuple[str, str], ...]
    paste: str
    placements: tuple[AssemblyPlacementSpec, ...]
    #: Whether a ``placements`` LIST was authored, regardless of its length —
    #: see the module docstring's AUTHORED-EMPTY section.
    expansion_authored: bool = False
    #: ``(drawing ref, package label)`` pairs from the footprint lock, for the
    #: drawings this component's parts are — see THE FOOTPRINT COLUMN above.
    #: Filled by the compiler, which holds the library chain; absent for a
    #: drawing whose lock entry carries no label.
    package_labels: tuple[tuple[str, str], ...] = ()

    def __post_init__(self) -> None:
        if not self.footprint_ref:
            raise ValueError("ResolvedAssembly.footprint_ref must be non-empty")
        if self.paste not in PASTE_TOKENS:
            raise ValueError(f"ResolvedAssembly.paste must be one of {PASTE_TOKENS}")

    def label_for(self, drawing: str) -> str | None:
        """The package label the footprint lock states for *drawing*, or
        ``None`` when the drawing carries none — the BOM Footprint column then
        prints the drawing ref itself."""
        for ref, label in self.package_labels:
            if ref == drawing:
                return label
        return None

    def drawing_for(self, physical) -> str:
        """The library ref of the drawing ONE placement is described by: the
        one the placement named, else this component's own.

        Every part-level question — the BOM's footprint cell, the orientation
        ledger key, what a reader is told the part IS — answers off this, so
        the rule has one spelling. ``physical`` is anything carrying a
        ``footprint_ref`` (a resolved placement, or an authored spec)."""
        return getattr(physical, "footprint_ref", None) or self.footprint_ref

    #: Refs the component actually contributes rows under: its own when no
    #: expansion is authored, else one per authored placement.
    def emitted_refs(self, component_ref: str) -> tuple[str, ...]:
        if not self.placements:
            return (component_ref,)
        return tuple(p.ref for p in self.placements)


def _identity(block: dict, key: str, ref: str) -> str | None:
    """One identity field off the block: absent, null and blank all mean "not
    authored"; a non-string REFUSES rather than being coerced or dropped."""
    value = block.get(key)
    if value is None:
        return None
    if not isinstance(value, str):
        raise AssemblySpecError(
            f"component {ref!r} assembly {key} must be a quoted string, got "
            f"{value!r} ({type(value).__name__}); an unquoted YAML value is "
            f"parsed before it is read here and the parse is not reversible "
            f"(mpn 0201 arrives as 129). Re-author the value in quotes.")
    return value.strip() or None


def _finite(value, field: str, ref: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise AssemblySpecError(
            f"component {ref!r} assembly {field} must be a number, got {value!r}")
    number = float(value)
    if not math.isfinite(number):
        raise AssemblySpecError(
            f"component {ref!r} assembly {field} must be finite, got {value!r}")
    return number


def _point_mm(raw, field: str, ref: str) -> tuple[float, float] | None:
    """A placement's ``{x, y}`` millimetre mapping, or ``None`` when absent.

    Both placement points read through here, so an unknown axis refuses the same
    way under either key: a mistyped ``{xx: 22.86, y: 0}`` accepted with x
    defaulted to 0 would place the part — or its anchor — at the parent's origin.
    A missing axis inside an otherwise well-formed mapping IS 0.0, because the
    key was written and only one axis was needed."""
    if raw is None:
        return None
    if not isinstance(raw, dict) or set(raw) - {"x", "y"}:
        raise AssemblySpecError(
            f"component {ref!r} assembly.{field} must be a mapping "
            f"of x/y millimetres, got {raw!r}")
    return (_finite(raw.get("x", 0.0), f"{field}.x", ref),
            _finite(raw.get("y", 0.0), f"{field}.y", ref))


def _placements(raw, ref: str) -> tuple[AssemblyPlacementSpec, ...]:
    if raw is None:
        return ()
    if not isinstance(raw, list):
        raise AssemblySpecError(
            f"component {ref!r} assembly.placements must be a list, got {raw!r}")
    out: list[AssemblyPlacementSpec] = []
    seen: set[str] = set()
    for index, item in enumerate(raw):
        where = f"placements[{index}]"
        if not isinstance(item, dict):
            raise AssemblySpecError(
                f"component {ref!r} assembly.{where} must be a mapping, got {item!r}")
        unknown = sorted(set(item) - _PLACEMENT_KEYS)
        if unknown:
            raise AssemblySpecError(
                f"component {ref!r} assembly.{where} has unknown key(s) "
                f"{'/'.join(unknown)}; known keys: {'/'.join(sorted(_PLACEMENT_KEYS))}")
        placement_ref = item.get("ref")
        if not isinstance(placement_ref, str) or not placement_ref.strip():
            raise AssemblySpecError(
                f"component {ref!r} assembly.{where} needs a non-empty authored 'ref' "
                f"(an exporter must never invent one), got {placement_ref!r}")
        placement_ref = placement_ref.strip()
        if placement_ref in seen:
            raise AssemblySpecError(
                f"component {ref!r} assembly.{where} repeats the designator "
                f"{placement_ref!r}; each physical placement needs its own")
        seen.add(placement_ref)
        offset = _point_mm(item.get("offset_mm"), f"{where}.offset_mm", ref)
        anchor = _point_mm(item.get("anchor_mm"), f"{where}.anchor_mm", ref)
        raw_rotation = item.get("rotation_deg")
        rotation = 0.0 if raw_rotation is None else _finite(
            raw_rotation, f"{where}.rotation_deg", ref)
        # Present-and-blank is refused rather than read as absent: a blank ref
        # names no drawing, and falling through to the parent's would quietly
        # gate this part's orientation on a drawing the author tried to leave.
        footprint = item.get("footprint")
        if footprint is not None and (not isinstance(footprint, str)
                                      or not footprint.strip()):
            raise AssemblySpecError(
                f"component {ref!r} assembly.{where}.footprint must be a non-empty "
                f"library footprint ref when present, got {footprint!r}")
        out.append(AssemblyPlacementSpec(
            ref=placement_ref, offset_mm=offset, rotation_deg=rotation,
            anchor_mm=anchor,
            footprint=footprint.strip() if footprint is not None else None))
    return tuple(out)


def _house_parts(raw, ref: str) -> tuple[tuple[str, str], ...]:
    if raw is None:
        return ()
    if not isinstance(raw, dict):
        raise AssemblySpecError(
            f"component {ref!r} assembly.house_parts must be a mapping of house id to "
            f"catalogue number, got {raw!r}")
    out: list[tuple[str, str]] = []
    for house, number in raw.items():
        if not isinstance(house, str) or not house.strip():
            raise AssemblySpecError(
                f"component {ref!r} assembly.house_parts has a non-string house id {house!r}")
        if not isinstance(number, str) or not number.strip():
            raise AssemblySpecError(
                f"component {ref!r} assembly.house_parts[{house!r}] must be a non-empty "
                f"catalogue number string, got {number!r}")
        out.append((house.strip(), number.strip()))
    return tuple(sorted(out))


def _block(comp: dict, ref: str) -> tuple[dict, bool]:
    """The authored block as a mapping plus its populate verdict, with both
    authored forms folded. Refuses any other scalar and any non-boolean
    ``populate`` — see the module docstring's EXCLUSION section."""
    raw = comp.get("assembly")
    if raw is None:
        return {}, True
    if raw == LEGACY_EXCLUDE:
        return {}, False
    if not isinstance(raw, dict):
        raise AssemblySpecError(
            f"component {ref!r} assembly must be a mapping or the legacy "
            f"{LEGACY_EXCLUDE!r} scalar, got {raw!r}")
    unknown = sorted(set(raw) - _BLOCK_KEYS)
    if unknown:
        raise AssemblySpecError(
            f"component {ref!r} assembly has unknown key(s) {'/'.join(unknown)}; "
            f"known keys: {'/'.join(sorted(_BLOCK_KEYS))}")
    populate = raw.get("populate")
    if populate is None:
        return raw, True
    if not isinstance(populate, bool):
        raise AssemblySpecError(
            f"component {ref!r} assembly.populate must be a boolean when present, "
            f"got {populate!r}")
    return raw, populate


def resolve_assembly(comp: dict, footprint_ref: str, ref: str) -> ResolvedAssembly:
    """Read one component's assembly facts, or raise :class:`AssemblySpecError`
    naming the component and the offending key."""
    block, populate = _block(comp, ref)
    paste = block.get("paste")
    if paste is None:
        paste = PASTE_AUTO
    if paste not in PASTE_TOKENS:
        raise AssemblySpecError(
            f"component {ref!r} assembly.paste must be one of "
            f"{'/'.join(PASTE_TOKENS)}, got {paste!r}")
    identity = {key: _identity(block, key, ref) for key in IDENTITY_FIELDS}
    raw_placements = block.get("placements")
    return ResolvedAssembly(
        footprint_ref=footprint_ref,
        populate=populate,
        house_parts=_house_parts(block.get("house_parts"), ref),
        paste=paste,
        placements=_placements(raw_placements, ref),
        expansion_authored=isinstance(raw_placements, list),
        **identity,
    )
