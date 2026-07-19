"""``FootprintDefinition`` — the durable, KiCad-INDEPENDENT footprint schema (A1).

This is the contract every later Stage-2 fabrication step consumes. It formalizes
the de-facto pad DTO that ``resolve._pads_from_parsed`` emits today (and that
``pcb_component.gd::_pads_from_list`` renders) into a frozen, typed shape, and
ADDS the fabrication fields the design ratified (rotation, roundrect corner
ratio, solder-mask margin, drill plating/shape, 3D-model + provenance refs).

KiCad independence
------------------
Nothing here imports the ``.kicad_mod`` s-expression parser. The KiCad-specific
``from_kicad_parsed`` adapter takes an ALREADY-PARSED dict (the output of
``footprints.parse_kicad_mod``) so the schema itself never depends on any one
CAD file format — a later step can add adapters for other sources without
touching this type.

Round-trip guarantee (proven in ``tests/test_footprint_def.py``)
----------------------------------------------------------------
``from_kicad_parsed(parse_kicad_mod(fx)).to_board_pad_dicts()`` reproduces
``resolve._pads_from_parsed(parse_kicad_mod(fx)["pads"])`` dict-for-dict for
every real fixture, so wiring this type into the live fab path is a NO-OP for
existing parts.

RULING 2: the schema can HOLD exotic pad shapes (custom/trapezoid/chamfer) from
day one, but no geometry is implemented for them — they are merely represented
and marked unsupported (``PadShape.is_supported``). Fail-closed enforcement is a
later step; this round only represents + marks.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import Optional

# DRY: the raw→panel pad-type mapping and its fail-safe are defined ONCE in
# resolve. We reuse both here rather than re-declaring the smd/thru_hole/
# np_thru_hole/connect semantics — the single source of truth for pad typing.
from .resolve import _PAD_TYPE_MAP, _normalize_pad_type

# The four semantic pad kinds KiCad emits and the schema recognizes. Derived
# from resolve's mapping so the two never drift (connect is edge-connector
# copper; np_thru_hole is a non-plated hole).
_KNOWN_PAD_TYPES = frozenset(_PAD_TYPE_MAP)


class PadShape(Enum):
    """Pad copper shape. Supported kinds have real downstream geometry; the
    exotic kinds are representable (RULING 2) but unsupported this round."""

    RECT = "rect"
    ROUNDRECT = "roundrect"
    CIRCLE = "circle"
    OVAL = "oval"
    # Representable-but-unsupported (no geometry implemented yet).
    CUSTOM = "custom"
    TRAPEZOID = "trapezoid"
    CHAMFER = "chamfer"

    @classmethod
    def from_token(cls, token: Optional[str]) -> "PadShape":
        """Map a KiCad shape token to a member. A missing/empty token means the
        board-dict default ``rect`` (mirrors ``p.get("shape") or "rect"``); an
        unrecognized token fails safe to CUSTOM (unsupported).

        DIVERGENCE NOTE (for the step-3 rewire): the current
        ``resolve._pads_from_parsed`` passes an unrecognized token THROUGH
        verbatim, so ``to_board_pad_dicts`` would emit ``"custom"`` where the
        legacy path emitted the raw string — the round-trip is dict-identical
        only for the enum's known tokens. This is intended: ruling 2 fail-closes
        exotic/unsupported shapes at step 4, so an out-of-enum shape must never
        reach the emitter to be compared in the first place. No real fixture
        currently carries such a token."""
        if not token:
            return cls.RECT
        try:
            return cls(token)
        except ValueError:
            return cls.CUSTOM

    @property
    def is_supported(self) -> bool:
        return self in _SUPPORTED_SHAPES


_SUPPORTED_SHAPES = frozenset(
    {PadShape.RECT, PadShape.ROUNDRECT, PadShape.CIRCLE, PadShape.OVAL}
)


def _semantic_pad_type(raw: Optional[str]) -> str:
    """Normalize a raw pad-type token into the four schema kinds, preserving
    ``connect`` (unlike ``_normalize_pad_type``, which collapses it to smd for
    the panel). Unknown/None fails safe to smd — the SAME fallback resolve uses,
    so ``_normalize_pad_type(_semantic_pad_type(raw)) == _normalize_pad_type(raw)``
    for every raw value (the identity the round-trip relies on)."""
    return raw if raw in _KNOWN_PAD_TYPES else "smd"


@dataclass(frozen=True)
class DrillDefinition:
    """A pad's drilled hole. ``shape`` is ``'round'`` or represents an
    oval/slot; ``size`` is (x, y) in mm (equal for a round hole)."""

    shape: str
    size: tuple
    plated: bool = True


@dataclass(frozen=True)
class PadDefinition:
    """One footprint pad in footprint-LOCAL coordinates."""

    number: str
    pad_type: str  # smd | thru_hole | np_thru_hole | connect
    shape: PadShape
    position: tuple  # (x, y) mm
    size: tuple  # (width, height) mm
    rotation_deg: float = 0.0
    corner_rratio: Optional[float] = None  # roundrect corner ratio, if any
    drill: Optional[DrillDefinition] = None
    layers: tuple = ()
    solder_mask_margin: Optional[float] = None


@dataclass(frozen=True)
class Model3D:
    """Reference to a 3D model (path only this round)."""

    path: Optional[str] = None


@dataclass(frozen=True)
class Provenance:
    """Source lineage of the footprint (id / sha / license placeholders)."""

    source_id: Optional[str] = None
    sha256: Optional[str] = None
    license: Optional[str] = None


@dataclass(frozen=True)
class FootprintDefinition:
    """A durable, CAD-independent footprint definition."""

    name: str
    pads: tuple = ()
    graphics: tuple = ()
    model3d: Optional[Model3D] = None
    provenance: Optional[Provenance] = None

    # -- adapters ----------------------------------------------------------

    @classmethod
    def from_kicad_parsed(cls, parsed: dict) -> "FootprintDefinition":
        """Build a ``FootprintDefinition`` from ``footprints.parse_kicad_mod``
        output. Consumes the already-parsed dict only — no s-expression re-parse.

        Pads with no local position are skipped, mirroring
        ``resolve._pads_from_parsed``'s null-skip so the two stay dict-identical.

        Note: ``corner_rratio`` is read from an optional ``roundrect_rratio``
        key. The current ``parse_kicad_mod`` does not yet surface it (that is a
        deferred enhancement to the fenced ``footprints.py``), so it is ``None``
        for real fixtures today; the adapter is forward-compatible for when the
        parser starts emitting it.
        """
        pads = []
        for p in parsed.get("pads", ()):
            x, y = p.get("x_mm"), p.get("y_mm")
            if x is None or y is None:
                continue  # cf. resolve._pads_from_parsed: never emit a positionless pad

            raw_size = p.get("size")
            if raw_size and raw_size[0] is not None and raw_size[1] is not None:
                size = (raw_size[0], raw_size[1])
            else:
                size = (1.0, 1.0)

            pad_type = _semantic_pad_type(p.get("type"))

            raw_drill = p.get("drill")
            drill = None
            if raw_drill is not None:
                # parse yields a single hole dimension; a round hole is (d, d).
                # Plating follows KiCad convention: np_thru_hole is non-plated.
                drill = DrillDefinition(
                    shape="round",
                    size=(raw_drill, raw_drill),
                    plated=(pad_type != "np_thru_hole"),
                )

            pads.append(
                PadDefinition(
                    number=str(p.get("number", "")),
                    pad_type=pad_type,
                    shape=PadShape.from_token(p.get("shape")),
                    position=(x, y),
                    size=size,
                    corner_rratio=p.get("roundrect_rratio"),
                    drill=drill,
                    layers=tuple(p.get("layers") or ()),
                )
            )

        return cls(
            name=parsed.get("name", ""),
            pads=tuple(pads),
            graphics=tuple(parsed.get("graphics", ()) or ()),
        )

    def to_board_pad_dicts(self) -> list:
        """Emit the EXACT board-dict pad shape ``resolve._pads_from_parsed``
        produces today: ``{number, type, shape, position{x,y},
        size{width,height}, drill{x,y}, layers}`` (see
        ``pcb_component.gd::_pads_from_list``)."""
        out = []
        for pad in self.pads:
            if pad.drill is not None:
                drill_dict = {"x": pad.drill.size[0], "y": pad.drill.size[1]}
            else:
                drill_dict = {"x": 0.0, "y": 0.0}
            out.append(
                {
                    "number": pad.number,
                    # collapse connect→smd for the panel, exactly as resolve does.
                    "type": _normalize_pad_type(pad.pad_type),
                    "shape": pad.shape.value,
                    "position": {"x": pad.position[0], "y": pad.position[1]},
                    "size": {"width": pad.size[0], "height": pad.size[1]},
                    "drill": drill_dict,
                    "layers": list(pad.layers),
                }
            )
        return out
