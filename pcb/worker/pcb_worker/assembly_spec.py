"""The per-component ASSEMBLY facts the resolved IR carries.

An order package (BOM, CPL, gerbers, manifest) must describe ONE board. That
holds only if every artifact derives from the same compilation, so the compiler
has to know what an assembly house buys and places, not just what the fab
etches. This module is that knowledge: it reads a component's authored
``assembly`` block (docs/board-yaml.md) plus the pre-block authoring forms it
supersedes, and produces the immutable :class:`ResolvedAssembly` that
``ResolvedComponent.assembly`` carries.

It is a separate module from ``resolved_board`` for the same reason
``footprint_def`` is: the IR module declares the geometry contract and stays
free of readers that parse loose board dicts. ``ResolvedComponent`` annotates
the field by forward reference and duck-types it, exactly as it does
``refdes``.

IDENTITY PRECEDENCE — three authored homes, one answer. A field is read from
the structured block first, then a top-level scalar, then a nested
``properties`` mapping; the first non-blank string wins. The block is the
canonical home; the other two are the shapes boards in the field already use
and would otherwise lose their part identity to. Folding them here means the
precedence rule is applied ONCE, at compile, rather than separately by every
consumer that wants an MPN.

EXCLUSION — two authored forms, one answer, fail-closed on either. ``assembly:
exclude`` (the pre-block scalar for board furniture: a fiducial, a silk logo)
and ``assembly: {populate: false}`` both mean the part is on the board but is
never picked, placed or purchased. A scalar that is not ``exclude``, or a
non-boolean ``populate``, REFUSES: a typo that quietly lands a fiducial in a
BOM with a fabricated identity requirement is the quiet wrong answer the whole
order path exists to prevent.

PLACEMENTS are carried, not composed. ``placements`` expands one authored
component into the several identical physical parts it stands for, each under
an authored, stable ref. This module validates the shape and hands the offsets
and rotations on verbatim; composing them against the parent's own rotation and
side is a transform question, and the transform is owned by the placement work,
not by this reader.
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

#: The string fields read through the identity-precedence fold above.
IDENTITY_FIELDS = ("manufacturer", "mpn", "package", "comment")

#: Sub-keys the block admits. An unknown key REFUSES rather than being dropped,
#: matching the Go codec (internal/board/assembly.go): a mistyped ``mpm`` that
#: vanishes here reappears later as "missing mpn" on a part that was authored.
_BLOCK_KEYS = frozenset(("populate", "paste", "house_parts", "placements")
                        + IDENTITY_FIELDS)

_PLACEMENT_KEYS = frozenset(("ref", "offset_mm", "rotation_deg"))


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
    board coordinate."""

    ref: str
    offset_mm: tuple[float, float] | None
    rotation_deg: float


@dataclass(frozen=True)
class ResolvedAssembly:
    """What an assembly house buys and places for one compiled component.

    ``footprint_ref`` is the component's AUTHORED ``footprint`` string. It rides
    here because the BOM's Footprint column is that string today, and the IR
    otherwise keeps only ``footprint_id`` — a content hash that names the
    geometry, not the part a purchaser recognizes.

    ``house_parts`` is a sorted tuple of ``(house id, catalogue number)`` pairs
    rather than a mapping, so the whole object stays hashable and frozen like
    every other IR node."""

    footprint_ref: str
    populate: bool
    manufacturer: str | None
    mpn: str | None
    package: str | None
    comment: str | None
    house_parts: tuple[tuple[str, str], ...]
    paste: str
    placements: tuple[AssemblyPlacementSpec, ...]

    def __post_init__(self) -> None:
        if not self.footprint_ref:
            raise ValueError("ResolvedAssembly.footprint_ref must be non-empty")
        if self.paste not in PASTE_TOKENS:
            raise ValueError(f"ResolvedAssembly.paste must be one of {PASTE_TOKENS}")

    #: Refs the component actually contributes rows under: its own when no
    #: expansion is authored, else one per authored placement.
    def emitted_refs(self, component_ref: str) -> tuple[str, ...]:
        if not self.placements:
            return (component_ref,)
        return tuple(p.ref for p in self.placements)


def _identity(comp: dict, block: dict, key: str) -> str | None:
    """The identity-precedence fold: block, then top-level scalar, then a
    nested ``properties`` mapping; first non-blank string wins."""
    for source in (block, comp, comp.get("properties")):
        if not isinstance(source, dict):
            continue
        value = source.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return None


def _finite(value, field: str, ref: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise AssemblySpecError(
            f"component {ref!r} assembly {field} must be a number, got {value!r}")
    number = float(value)
    if not math.isfinite(number):
        raise AssemblySpecError(
            f"component {ref!r} assembly {field} must be finite, got {value!r}")
    return number


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
        raw_offset = item.get("offset_mm")
        offset: tuple[float, float] | None = None
        if raw_offset is not None:
            if not isinstance(raw_offset, dict) or set(raw_offset) - {"x", "y"}:
                raise AssemblySpecError(
                    f"component {ref!r} assembly.{where}.offset_mm must be a mapping "
                    f"of x/y millimetres, got {raw_offset!r}")
            offset = (_finite(raw_offset.get("x", 0.0), f"{where}.offset_mm.x", ref),
                      _finite(raw_offset.get("y", 0.0), f"{where}.offset_mm.y", ref))
        raw_rotation = item.get("rotation_deg")
        rotation = 0.0 if raw_rotation is None else _finite(
            raw_rotation, f"{where}.rotation_deg", ref)
        out.append(AssemblyPlacementSpec(ref=placement_ref, offset_mm=offset,
                                         rotation_deg=rotation))
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
    identity = {key: _identity(comp, block, key) for key in IDENTITY_FIELDS}
    return ResolvedAssembly(
        footprint_ref=footprint_ref,
        populate=populate,
        house_parts=_house_parts(block.get("house_parts"), ref),
        paste=paste,
        placements=_placements(block.get("placements"), ref),
        **identity,
    )
