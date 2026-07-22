"""Footprint-RESOLVE step: enrich a canonical board with silk/courtyard graphics.

Canonical boards (docs/board-yaml.md) carry each component's inline pad geometry
plus a ``footprint`` ref, but NO silkscreen/courtyard graphics — so a bare render
looks like a cluster of pads with no body outlines. This step resolves each
component's footprint (via the sha-verified seed library in ``footprints.py``)
and attaches its ``F.SilkS`` + ``F.CrtYd`` graphics to the component.

Coincidence guard (fail-closed)
-------------------------------
Before attaching a footprint's graphics, we PROVE the footprint actually matches
the routed board: every declared pin's LOCAL position must equal the resolved
footprint pad's LOCAL position (matched by pad number) within 0.01mm. If they
disagree, the silkscreen we'd draw would be desynced from the copper the board
was routed against — so we FAIL with a structured error naming the component,
pin, and delta rather than silently drawing wrong silk. (Round 1's golden proved
this holds at 0.000mm for all 10 smart-remote components — same math as
``tests/test_footprints.py::test_coincidence_golden_all_components``.)

Coordinates stay footprint-LOCAL: the board-placement transform (component
position + KiCad rotation) is applied downstream by the renderer/gerber writer,
consistent with how pins are already stored.

Public API
----------
* ``resolve_board(board, library_root=None, lockfile=None) -> dict``  (deep copy)
"""

from __future__ import annotations

import copy
import math
from pathlib import Path
from typing import Union

from .footprints import FootprintLookupError, resolve_footprint
from .pad_source import has_resolved_pads
from .pad_types import PAD_TYPE_MAP as _PAD_TYPE_MAP
from .pad_types import normalize_pad_type as _normalize_pad_type

# Coincidence tolerance in mm — same golden threshold Round 1 validated.
COINCIDENCE_TOL_MM = 0.01

# The parser now captures a broader fabrication definition, but this legacy
# preview DTO retains its established F.SilkS/F.CrtYd payload until K3 moves
# consumers to ResolvedBoard.  Keeping this filter local prevents a parser
# capability expansion from silently changing the live panel contract.
_LEGACY_GRAPHIC_LAYERS = frozenset({"F.SilkS", "F.CrtYd"})

class ResolveError(Exception):
    """Base for resolve-step faults."""


class ResolveCoincidenceError(ResolveError):
    """A component's declared pin does not sit on its footprint's pad.

    Carries the located mismatch so the caller can surface it structurally
    (ref/pin/delta) rather than as an opaque string.
    """

    def __init__(self, ref: str, pin: str, delta_mm: float,
                 pin_xy: tuple, pad_xy: Union[tuple, None]):
        self.ref = ref
        self.pin = pin
        self.delta_mm = delta_mm
        self.pin_xy = pin_xy
        self.pad_xy = pad_xy
        if pad_xy is None:
            msg = (f"component {ref!r} pin {pin!r} has no matching pad in its "
                   f"footprint (declared at {pin_xy})")
        else:
            msg = (f"component {ref!r} pin {pin!r}: declared local {pin_xy} vs "
                   f"footprint pad local {pad_xy} -> {delta_mm:.4f}mm > "
                   f"{COINCIDENCE_TOL_MM}mm (silk would desync from copper)")
        super().__init__(msg)


def _silk_count(graphics: list) -> int:
    return sum(1 for g in graphics if g.get("layer") == "F.SilkS")


def _courtyard_count(graphics: list) -> int:
    return sum(1 for g in graphics if g.get("layer") == "F.CrtYd")


def _check_coincidence(ref: str, pins: list, fp_pads: dict) -> None:
    """Raise ResolveCoincidenceError if any declared pin's LOCAL position does
    not coincide (within COINCIDENCE_TOL_MM) with the footprint pad of the same
    number. Fail-closed: an unknown pad number is also a coincidence failure."""
    for pin in pins:
        if not isinstance(pin, dict):
            continue
        num = str(pin.get("number"))
        px, py = pin.get("x_mm"), pin.get("y_mm")
        if px is None or py is None:
            continue  # a pin with no local position can't be checked; skip
        pad = fp_pads.get(num)
        if pad is None or pad[0] is None or pad[1] is None:
            raise ResolveCoincidenceError(ref, num, float("inf"), (px, py), None)
        d = math.hypot(pad[0] - px, pad[1] - py)
        if d > COINCIDENCE_TOL_MM:
            raise ResolveCoincidenceError(ref, num, d, (px, py), (pad[0], pad[1]))


def resolve_board(
    board: dict,
    library_root: Union[str, Path, None] = None,
    lockfile: Union[str, Path, None] = None,
) -> dict:
    """Resolve every component's footprint and attach its silk/courtyard graphics.

    For each component: resolve the footprint ref, PROVE its pads coincide with
    the component's declared pins (fail-closed — see ResolveCoincidenceError),
    then set ``component["graphics"]`` to the footprint's ``F.SilkS`` + ``F.CrtYd``
    graphics AND ``component["pads"]`` to the footprint's real pad geometry
    (shape/size/drill/type), both in component-LOCAL coordinates, and flag
    ``component["has_pad_geometry"] = True`` so the panel's accurate pad renderer
    takes over. The input is not mutated — a deep copy is returned.
    """
    resolved = copy.deepcopy(board)
    components = resolved.get("components")
    if not isinstance(components, list):
        return resolved

    for comp in components:
        if not isinstance(comp, dict):
            continue
        _resolve_component(comp, library_root, lockfile)

    return resolved


def resolve_board_best_effort(
    board: dict,
    library_root: Union[str, Path, None] = None,
    lockfile: Union[str, Path, None] = None,
) -> dict:
    """TOLERANT resolve for the fabrication path (Stage 2 step 4a-ii, design 2).

    Same as ``resolve_board`` but a component whose footprint is UNRESOLVABLE
    (not in the library) or that declares no footprint ref is LEFT INLINE — its
    ``pins`` remain the source of truth — instead of failing the whole board. The
    downstream emitter then fail-closes only if such a component's SMD pad has no
    inline geometry either (pad_source.iter_pads(require_smd_size=True)). So the
    two controls compose: resolve what you can, and refuse to fabricate a pad you
    still have no geometry for.

    A ResolveCoincidenceError is NOT tolerated — a footprint that resolves but
    whose pads DISAGREE with the routed pins is an integrity fault (silk/copper
    would desync), so it still propagates and fails the board. The input is not
    mutated — a deep copy is returned. The standalone ``resolve`` worker action
    keeps using the STRICT ``resolve_board`` (an unresolvable footprint there IS
    an error the caller asked to surface).
    """
    resolved = copy.deepcopy(board)
    components = resolved.get("components")
    if not isinstance(components, list):
        return resolved

    for comp in components:
        if not isinstance(comp, dict):
            continue
        try:
            _resolve_component(comp, library_root, lockfile)
        except ResolveCoincidenceError:
            raise  # integrity fault: footprint pads disagree with routed pins
        except (ResolveError, FootprintLookupError):
            continue  # unresolvable / no-ref footprint — leave inline (pins win)

    return resolved


def _resolve_component(
    comp: dict,
    library_root: Union[str, Path, None],
    lockfile: Union[str, Path, None],
) -> None:
    """Resolve ONE component's footprint and attach its graphics + pad geometry.

    Mutates ``comp`` in place (sets ``graphics``/``pads``/``has_pad_geometry``).
    Raises ResolveError (no footprint ref), FootprintLookupError (not in library),
    or ResolveCoincidenceError (pads disagree with pins) — the caller decides
    whether to propagate (strict) or leave the component inline (best-effort).
    Nothing is mutated until AFTER the coincidence check passes, so a raising
    component is left pristine (inline).
    """
    ref = str(comp.get("ref", ""))
    fp_ref = comp.get("footprint")
    if not isinstance(fp_ref, str) or fp_ref == "":
        raise ResolveError(f"component {ref!r} has no footprint ref to resolve")

    parsed = resolve_footprint(fp_ref, library_root=library_root, lockfile=lockfile)

    fp_pads = {str(p["number"]): (p["x_mm"], p["y_mm"]) for p in parsed["pads"]}
    _check_coincidence(ref, comp.get("pins") or [], fp_pads)

    # Attach only the wanted layers (parse already filters to GRAPHIC_LAYERS,
    # but assert the invariant so drift is caught here rather than in a render).
    graphics = [
        g for g in parsed["graphics"]
        if g.get("layer") in _LEGACY_GRAPHIC_LAYERS
    ]
    comp["graphics"] = graphics

    # Attach real pad geometry (footprint-LOCAL coords — the SAME frame the
    # graphics above are in, so silk and copper co-register). Built from the
    # SAME parsed footprint used for the coincidence check; no re-parse. The
    # coincidence guard has already run (and would have raised) before we get
    # here, so pads are only attached to a proven-coincident component.
    comp["pads"] = _pads_from_parsed(parsed["pads"])
    # ``has_pad_geometry`` is the board-dict VIEW of the one resolved-vs-fallback
    # predicate (pad_source.has_resolved_pads) — NOT an independent computation,
    # so it can never drift from what iter_pads/the emitters see. Only claims
    # geometry when pads actually resolved, else the panel would suppress its
    # fallback pin renderer and draw nothing at all (Stage 2 step 7 collapse).
    comp["has_pad_geometry"] = has_resolved_pads(comp)


def _pads_from_parsed(fp_pads: list) -> list:
    """Map ``footprints._parse_pad`` output → the panel's board-dict pad shape.

    Emits ``{number, type, shape, position{x,y}, size{width,height},
    drill{x,y}, layers}`` plus the fab-affecting optionals the parser surfaces
    (see ``pcb_component.gd::_pads_from_list``). Pads with no local position are
    skipped — mirrors the coincidence path's null skip so we never emit a
    positionless pad.

    SB2 (019f8acfd651): the parser (``footprints._parse_pad``) already extracts
    ``roundrect_rratio`` / ``solder_mask_margin`` / ``solder_paste_margin`` /
    ``rotation``, but this projection used to DROP them, so every resolved
    roundrect fell back to the emitter's default corner ratio and every pad to
    the board-global mask clearance. Thread them through here (name-mapping
    ``roundrect_rratio`` → ``corner_rratio``, the key the gerber/kicad emitters
    read) so the LIVE emitters see the real per-pad geometry. ``rotation`` and
    ``solder_paste_margin`` are carried for losslessness; their APPLICATION
    (pad-local rotation into the placement transform; a paste layer) lands in W8.
    """
    out: list = []
    for p in fp_pads:
        x, y = p.get("x_mm"), p.get("y_mm")
        if x is None or y is None:
            continue

        size = p.get("size")
        if size and size[0] is not None and size[1] is not None:
            size_dict = {"width": size[0], "height": size[1]}
        else:
            size_dict = {"width": 1.0, "height": 1.0}

        # KiCad drill is a single float (or absent) → symmetric {x,y}; 0 == no hole.
        drill = p.get("drill")
        drill_dict = ({"x": drill, "y": drill} if drill is not None
                      else {"x": 0.0, "y": 0.0})

        pad_out = {
            "number": str(p.get("number", "")),
            "type": _normalize_pad_type(p.get("type")),
            "shape": p.get("shape") or "rect",
            "position": {"x": x, "y": y},
            "size": size_dict,
            "drill": drill_dict,
            "layers": p.get("layers") or [],
        }
        # Fab-affecting optionals — only present when the footprint carries them,
        # so a plain rect pad stays clean. corner_rratio + solder_mask_margin are
        # consumed by the emitters NOW; rotation + solder_paste_margin are carried
        # for W8.
        rratio = p.get("roundrect_rratio")
        if rratio is not None:
            pad_out["corner_rratio"] = rratio
        for key in ("solder_mask_margin", "solder_paste_margin"):
            val = p.get(key)
            if val is not None:
                pad_out[key] = val
        # A 0/absent local rotation is a no-op; omit it so this projection stays
        # byte-identical to footprint_def.to_board_pad_dicts (whose PadDefinition
        # .rotation_deg defaults to 0.0 and can't distinguish absent from zero).
        rot = p.get("rotation")
        if rot:
            pad_out["rotation"] = rot
        out.append(pad_out)
    return out


def board_graphic_stats(board: dict) -> dict:
    """Summarise attached graphics: {components, silk_graphics, courtyard_graphics}."""
    components = board.get("components") if isinstance(board.get("components"), list) else []
    silk = 0
    crtyd = 0
    for comp in components:
        if not isinstance(comp, dict):
            continue
        g = comp.get("graphics") or []
        silk += _silk_count(g)
        crtyd += _courtyard_count(g)
    return {
        "components": len(components),
        "silk_graphics": silk,
        "courtyard_graphics": crtyd,
    }
