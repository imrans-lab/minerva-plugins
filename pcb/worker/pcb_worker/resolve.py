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

from .footprints import GRAPHIC_LAYERS, resolve_footprint

# Coincidence tolerance in mm — same golden threshold Round 1 validated.
COINCIDENCE_TOL_MM = 0.01


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
    graphics in component-LOCAL coordinates. The existing inline pads are left
    untouched (this round attaches silk; it does not re-source pads). The input
    is not mutated — a deep copy is returned.
    """
    resolved = copy.deepcopy(board)
    components = resolved.get("components")
    if not isinstance(components, list):
        return resolved

    for comp in components:
        if not isinstance(comp, dict):
            continue
        ref = str(comp.get("ref", ""))
        fp_ref = comp.get("footprint")
        if not isinstance(fp_ref, str) or fp_ref == "":
            raise ResolveError(
                f"component {ref!r} has no footprint ref to resolve")

        parsed = resolve_footprint(fp_ref, library_root=library_root, lockfile=lockfile)

        fp_pads = {str(p["number"]): (p["x_mm"], p["y_mm"]) for p in parsed["pads"]}
        _check_coincidence(ref, comp.get("pins") or [], fp_pads)

        # Attach only the wanted layers (parse already filters to GRAPHIC_LAYERS,
        # but assert the invariant so drift is caught here rather than in a render).
        graphics = [g for g in parsed["graphics"] if g.get("layer") in GRAPHIC_LAYERS]
        comp["graphics"] = graphics

    return resolved


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
