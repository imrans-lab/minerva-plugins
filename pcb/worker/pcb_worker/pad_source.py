"""Single resolve-aware pad-geometry accessor for the fabrication compilers.

Before this module, three fab sites (gerber._harvest, kicad._footprint,
drc._harvest_pads) each hand-read ``comp["pins"]`` and, for an SMD pad with no
declared geometry, fell back to a hard-coded PLACEHOLDER size (gerber 1.0x0.6,
kicad 1/0.6). That placeholder is the emitter pad-geometry bug (docket
019f7736b236): the RAW board's pins carry no footprint pad geometry, so a fab
run flashed nominal rectangles instead of the real lands.

``resolve.resolve_board`` ALREADY attaches the real per-component footprint pad
geometry to ``comp["pads"]`` (fail-closed coincidence guard). This accessor is
the ONE place that PREFERS that resolved geometry when present and falls back to
reconstructing today's exact per-pin behaviour otherwise. The three consumers
now iterate ``iter_pads(comp)`` instead of ``comp["pins"]`` — so a single change
(resolve wired into the fab path, gated in methods.py) flips all three emitters
to real geometry consistently, and gerber + kicad read the SAME sizes.

WHY THE SMD PLACEHOLDER LITERAL STAYS IN EACH EMITTER (not centralised here):
the two emitters deliberately spell the fallback size differently — gerber uses
the float constant ``DEFAULT_SMD_PAD_W_MM=1.0`` (fed numerically to an aperture),
kicad emits the integer literal ``1``/``0.6`` into its s-expression text. Baking
one representation here would change kicad's bytes. So this accessor deliberately
leaves ``width``/``height`` as ``None`` when a pin declares no size, and each
emitter applies its own placeholder — preserving byte-identical output while
still sharing the iteration, the resolved-vs-pin PREFERENCE, and the field
extraction (the actual duplicated logic).

Coordinates are component-LOCAL (pre-placement-rotation), the SAME frame the
pins and the resolved pads both use; the placement transform is applied
downstream by each consumer (gerber/drc rotate; kicad emits local under the
footprint's own ``(at x y rot)``).
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any


def _num(v: Any, default: float = 0.0) -> float:
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else default


def _opt_num(v: Any) -> float | None:
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None


@dataclass(frozen=True)
class PadGeom:
    """Normalised, consumer-ready geometry for one pad.

    Deliberately RAW-preserving where the three fab sites diverge, so each keeps
    its exact historical tail on the shared data:
      * ``number`` is the raw pin number (``str | None | ...``): kicad SKIPS a
        ``None`` number, drc ``str()``-es it (``None`` -> ``"None"``), gerber
        ignores it.
      * ``drill`` is ``_opt_num(drill_mm)`` (``0.0`` preserved, ``None`` if
        absent/non-numeric): gerber treats a through-hole as ``drill > 0``,
        kicad as ``drill is not None`` (so a ``0`` drill is TH to kicad, SMD to
        gerber) — each applies its own predicate to this one field.
      * ``width``/``height`` are ``None`` when the source declares no size, so
        each emitter can apply its own placeholder literal (see module note).
    """

    number: Any            # raw pin number (str|None|...) — see class note
    x: float               # component-LOCAL (pre-placement-rotation)
    y: float
    width: float | None    # SMD copper width; None => emitter placeholder
    height: float | None
    drill: float | None    # drill diameter mm (0.0 preserved); None => no datum
    annulus: float | None  # TH copper annulus diameter; None => emitter default
    plated: bool
    shape: str
    pad_type: str          # "smd" | "thru_hole" | "np_thru_hole"
    layers: list
    from_resolve: bool      # provenance: real footprint geometry vs pin fallback


def iter_pads(comp: dict) -> list[PadGeom]:
    """Yield normalised pad geometry for one component.

    PREFERS ``comp["pads"]`` (resolve_board's real footprint geometry) when it is
    a non-empty list; otherwise reconstructs today's per-pin fallback from
    ``comp["pins"]``. One ``PadGeom`` per usable pad/pin, in source order.
    """
    if not isinstance(comp, dict):
        return []
    resolved = comp.get("pads")
    if isinstance(resolved, list) and resolved:
        return [_from_resolved(p) for p in resolved if isinstance(p, dict)]
    pins = comp.get("pins")
    pins = pins if isinstance(pins, list) else []
    return [_from_pin(p) for p in pins if isinstance(p, dict)]


def _from_pin(pin: dict) -> PadGeom:
    """Fallback: reconstruct a pad from a canonical pin, byte-for-byte matching
    what gerber/kicad/drc used to read directly."""
    drill = _opt_num(pin.get("drill_mm"))
    return PadGeom(
        number=pin.get("number"),
        x=_num(pin.get("x_mm")),
        y=_num(pin.get("y_mm")),
        width=_opt_num(pin.get("pad_width_mm")),
        height=_opt_num(pin.get("pad_height_mm")),
        drill=drill,
        annulus=_opt_num(pin.get("annulus_diameter_mm")),
        plated=(pin.get("plated", True) is not False),
        shape="rect",
        pad_type=("thru_hole" if (drill is not None and drill > 0) else "smd"),
        layers=[],
        from_resolve=False,
    )


def _from_resolved(pad: dict) -> PadGeom:
    """Preferred: map resolve_board's ``comp["pads"]`` entry (LOCAL coords,
    ``{number,type,shape,position{x,y},size{width,height},drill{x,y},layers}``)
    to a PadGeom. A resolved through-hole carries no separate annulus datum, so
    its copper pad width doubles as the annulus diameter (keeps gerber's circular
    annulus and kicad's thru_hole size reading the same real copper dimension)."""
    pos = pad.get("position") or {}
    size = pad.get("size") or {}
    dr = pad.get("drill") or {}
    drill = _opt_num(dr.get("x"))
    if drill is not None and drill <= 0:
        drill = None
    width = _opt_num(size.get("width"))
    height = _opt_num(size.get("height"))
    pad_type = pad.get("type") or "smd"
    return PadGeom(
        number=pad.get("number"),
        x=_num(pos.get("x")),
        y=_num(pos.get("y")),
        width=width,
        height=height,
        drill=drill,
        annulus=(width if drill is not None else None),
        plated=(pad_type != "np_thru_hole"),
        shape=pad.get("shape") or "rect",
        pad_type=pad_type,
        layers=pad.get("layers") or [],
        from_resolve=True,
    )
