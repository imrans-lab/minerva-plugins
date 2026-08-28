"""Build a :class:`FootprintDefinition` from a component's OWN board geometry.

A canonical board component may carry its resolved land geometry inline — the
``pads`` list ``resolve._pads_from_parsed`` / ``footprint_def.to_board_pad_dicts``
write, plus the footprint-local ``graphics`` beside it. When it does, the board
already IS the geometry and the footprint library has nothing left to supply, so
the compiler builds the definition from these bytes instead of resolving the
``footprint`` ref. That is what lets a board survive a machine whose library does
not carry the part it was authored against.

FULL vs PARTIAL
---------------
FULL: the component carries a ``pads`` key holding a list. That list is then the
SOLE pad authority — an empty list means exactly zero pads (a graphics-only
pseudo-component), never "fall back to the library" — and ``graphics``, present
or absent, is the sole graphic authority beside it.

PARTIAL: there is no ``pads`` key at all. The ``footprint`` ref is resolved from
the library and stays the geometry authority, with inline ``pins`` acting as
per-pad-number overrides. Nothing on that path changes.

The trigger is the ``pads`` KEY, not its contents, so the two states cannot
overlap and an authoring mistake cannot silently drift a board from one to the
other. A present ``pads`` key whose value is not a list (``null``, a mapping)
is therefore a FULL component with unreadable geometry, not a PARTIAL one.

FAIL-CLOSED: a ``pads`` value that is not readable as pad geometry raises
:class:`InlineGeometryError`. It is never quietly demoted to the library path —
that would substitute one part's copper for another's without a word.

THE DESIGNATOR IS NOT PART OF THIS GEOMETRY, deliberately. A definition built
here carries no ``reference_text``, and it must not: the library is never read
on this arm, so the footprint's own authored fp_text is genuinely unavailable,
and WHERE a designator prints is a per-COMPONENT question anyway (two
components share one interned definition). The answer is composed one level up
by ``refdes_anchor.component_reference_text`` and lands on
``ResolvedComponent.refdes``: the board's own ``refdes_placement`` block when it
authors one, else the anchor derived from the very pads and graphics this module
just read. A FULL component is therefore the case where authoring the placement
on the board is the ONLY way to state one.

SHAPE PARITY: ``shape`` and ``raw_shape`` are read as INDEPENDENT keys, exactly
as ``pad_source._from_resolved`` reads the same dicts on the loose-dict fab path
(``shape`` decides the land, ``raw_shape`` is the authored-shape provenance that
``th_land`` consults). Deriving one from the other here would make the IR and
loose-dict readings of one board disagree.
"""

from __future__ import annotations

import math
from typing import Any

from .footprint_def import (
    DrillDefinition,
    FootprintDefinition,
    GraphicDefinition,
    PadDefinition,
    PadShape,
    Provenance,
)
from .pad_types import semantic_pad_type
from .resolved_board import Layer, UnsupportedFeature


#: ``Provenance.library_layer`` for a definition the BOARD supplied. Distinct
#: from every ``footprints.LAYER_PRECEDENCE`` name on purpose: "which library
#: layer" has no answer when no library was read.
BOARD_LIBRARY_LAYER = "board"


class InlineGeometryError(ValueError):
    """A component's inline ``pads``/``graphics`` cannot be read as geometry."""


def carries_full_geometry(comp: Any) -> bool:
    """True when *comp* carries a ``pads`` KEY — see FULL vs PARTIAL above.

    Deliberately NOT ``pad_source.has_resolved_pads``: that predicate answers
    "are there resolved pads to iterate", so it reads an empty list as nothing
    to iterate. This one answers "who owns this component's geometry", and an
    empty list is a full, deliberate answer to that question — zero pads.

    Deliberately NOT ``isinstance(..., list)`` either: a component that states
    ``pads`` and states it wrong (``null``, a mapping) has claimed geometry
    ownership, and answering False there would hand its copper back to the
    library — the silent substitution the whole module exists to prevent.
    ``footprint_from_component`` is what refuses the malformed value.
    """
    return isinstance(comp, dict) and "pads" in comp


def footprint_from_component(comp: dict, fp_ref: str) -> FootprintDefinition:
    """The component's inline geometry as an interned footprint definition.

    Named for the ``footprint`` ref it stands in for, so two components carrying
    identical geometry under one name still intern to one definition.
    """
    raw_pads = comp.get("pads")
    if not isinstance(raw_pads, list):
        raise InlineGeometryError(
            f"pads is present but is not a list of pads (got {raw_pads!r})")
    pads = _pads(raw_pads)
    graphics, graphic_markers = _graphics(comp.get("graphics"), fp_ref)
    return FootprintDefinition(
        name=fp_ref,
        pads=pads,
        graphics=graphics,
        provenance=Provenance(source_id=fp_ref, library_layer=BOARD_LIBRARY_LAYER),
        unsupported=graphic_markers,
    )


def _pads(raw_pads: list) -> tuple[PadDefinition, ...]:
    pads: list[PadDefinition] = []
    occurrences: dict[str, int] = {}
    for index, raw in enumerate(raw_pads):
        if not isinstance(raw, dict):
            raise InlineGeometryError(f"pads[{index}] is not a mapping")
        number = str(raw.get("number", ""))
        ordinal = occurrences.get(number, 0)
        occurrences[number] = ordinal + 1
        position = _position(raw.get("position"), index)
        shape_token = raw.get("shape") if isinstance(raw.get("shape"), str) else None
        raw_shape = raw.get("raw_shape") if isinstance(raw.get("raw_shape"), str) else None
        pad_type = raw.get("type") if isinstance(raw.get("type"), str) else None
        pads.append(PadDefinition(
            # Same "pad:<number>:<ordinal>" identity the library adapter mints,
            # so a board that stops resolving keeps its placed-pad ids.
            source_id=f"pad:{number}:{ordinal}",
            number=number,
            pad_type=semantic_pad_type(pad_type),
            raw_pad_type=pad_type,
            shape=PadShape.from_token(shape_token),
            raw_shape=raw_shape,
            position=position,
            size=_size(raw.get("size"), index),
            rotation_deg=_finite(raw.get("rotation"), 0.0, f"pads[{index}].rotation"),
            corner_rratio=_optional_finite(raw.get("corner_rratio"),
                                           f"pads[{index}].corner_rratio"),
            drill=_drill(raw.get("drill"), pad_type, index),
            layers=_layers(raw.get("layers"), index),
            solder_mask_margin=_optional_finite(raw.get("solder_mask_margin"),
                                                f"pads[{index}].solder_mask_margin"),
            solder_paste_margin=_optional_finite(raw.get("solder_paste_margin"),
                                                 f"pads[{index}].solder_paste_margin"),
        ))
    return tuple(pads)


def _graphics(raw_graphics: Any,
              fp_ref: str) -> tuple[tuple[GraphicDefinition, ...],
                                    tuple[UnsupportedFeature, ...]]:
    """Footprint-local graphics, decoded by the ONE graphic decoder.

    The board's graphic dicts are the parser's own shape except that points may
    have been re-encoded as ``{x, y}`` mappings on the way through the panel, so
    they are normalized back to pairs and handed to ``from_kicad_parsed`` — which
    also mints the ``malformed_graphic`` markers a bad entry deserves. Absent or
    non-list graphics mean none, never an error: graphics are documentation, and
    the pads above are the fabrication-critical half.

    An entry that is not a mapping at all is NOT dropped: it is replaced by an
    undecodable stand-in so it earns the same ``malformed_graphic`` marker, and
    so the entries after it keep the ``graphic:<ordinal>`` ids they would have
    had. Dropping it would report a footprint drawn with artwork nobody can see
    is missing.
    """
    if not isinstance(raw_graphics, list):
        return (), ()
    normalized = [_normalize_graphic(g) if isinstance(g, dict)
                  else {"kind": f"<not a mapping: {g!r}>"}
                  for g in raw_graphics]
    decoded = FootprintDefinition.from_kicad_parsed(
        {"name": fp_ref, "graphics": normalized})
    return decoded.graphics, decoded.unsupported


#: Graphic keys whose value is a single point, and those whose value is a list
#: of points. Both accept the ``{x, y}`` mapping form the panel re-encodes to.
_POINT_KEYS = ("start", "end", "center", "mid")
_POINT_LIST_KEYS = ("points",)


def _normalize_graphic(raw: dict) -> dict:
    out = dict(raw)
    for key in _POINT_KEYS:
        if key in out:
            out[key] = _as_pair(out[key])
    for key in _POINT_LIST_KEYS:
        value = out.get(key)
        if isinstance(value, list):
            out[key] = [_as_pair(point) for point in value]
    return out


def _as_pair(point: Any) -> Any:
    """``{x, y}`` → ``[x, y]``; anything else through untouched for the decoder
    (which reports a malformed point as a marker rather than a crash)."""
    if isinstance(point, dict):
        return [point.get("x"), point.get("y")]
    return point


def _position(raw: Any, index: int) -> tuple[float, float]:
    if not isinstance(raw, dict):
        raise InlineGeometryError(f"pads[{index}] has no position mapping")
    x, y = raw.get("x"), raw.get("y")
    if not (_is_finite(x) and _is_finite(y)):
        raise InlineGeometryError(
            f"pads[{index}] position ({x!r}, {y!r}) is not a finite local point")
    return float(x), float(y)


def _size(raw: Any, index: int) -> tuple[float, float] | None:
    """The land's copper size, or None for a pad that declares none.

    ``{width: null, height: null}`` is the established encoding for "the
    footprint authored no size" (K14) and stays None here — the fail-closed
    sizeless-SMD gate downstream is what refuses to fabricate it, not this
    reader.
    """
    if not isinstance(raw, dict):
        return None
    width, height = raw.get("width"), raw.get("height")
    if width is None and height is None:
        return None
    if not (_is_finite(width) and _is_finite(height)) or width <= 0 or height <= 0:
        raise InlineGeometryError(
            f"pads[{index}] size ({width!r}, {height!r}) is not a finite positive pair")
    return float(width), float(height)


def _drill(raw: Any, pad_type: Any, index: int) -> DrillDefinition | None:
    """``{x, y}`` → a drill, or None for a solid land.

    A zero (or absent) diameter is no hole, matching every other reader of this
    key. The board dict carries no drill SHAPE, so it is derived the way the two
    producers encode it: equal axes came from a round drill, unequal from an
    oval one.
    """
    if not isinstance(raw, dict):
        return None
    x, y = raw.get("x", 0.0), raw.get("y", 0.0)
    if not (_is_finite(x) and _is_finite(y)):
        raise InlineGeometryError(
            f"pads[{index}] drill ({x!r}, {y!r}) is not a finite pair")
    if x <= 0 or y <= 0:
        return None
    return DrillDefinition(
        "round" if x == y else "oval", (float(x), float(y)),
        plated=(semantic_pad_type(pad_type) != "np_thru_hole"))


def _layers(raw: Any, index: int) -> tuple[Layer, ...]:
    if raw is None:
        return ()
    if not isinstance(raw, list):
        raise InlineGeometryError(f"pads[{index}].layers is not a list")
    # Refused by name rather than filtered: a dropped entry is a land that
    # silently stops touching a layer it was authored on (copper, mask, paste),
    # which no downstream gate can notice.
    layers: list[Layer] = []
    for position, value in enumerate(raw):
        if not isinstance(value, str) or not value:
            raise InlineGeometryError(
                f"pads[{index}].layers[{position}] {value!r} is not a layer name")
        layers.append(Layer.from_id(value))
    return tuple(layers)


def _is_finite(value: Any) -> bool:
    return (isinstance(value, (int, float)) and not isinstance(value, bool)
            and math.isfinite(value))


def _finite(value: Any, default: float, field: str) -> float:
    if value is None:
        return default
    if not _is_finite(value):
        raise InlineGeometryError(f"{field} {value!r} is not finite")
    return float(value)


def _optional_finite(value: Any, field: str) -> float | None:
    if value is None:
        return None
    if not _is_finite(value):
        raise InlineGeometryError(f"{field} {value!r} is not finite")
    return float(value)
