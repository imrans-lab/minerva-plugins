"""Single resolve-aware pad-geometry accessor for the fabrication compilers.

Before this module, three fab sites (gerber._harvest, kicad._footprint,
drc._harvest_pads) each hand-read ``comp["pins"]`` and, for an SMD pad with no
declared geometry, fell back to a hard-coded PLACEHOLDER size (gerber 1.0x0.6,
kicad 1/0.6). That placeholder is the emitter pad-geometry bug (docket
019f7736b236): the RAW board's pins carry no footprint pad geometry, so a fab
run flashed nominal rectangles instead of the real lands.

``resolve.resolve_board`` attaches the real per-component footprint pad geometry
to ``comp["pads"]`` (fail-closed coincidence guard). This accessor is the ONE
place that PREFERS that resolved geometry when present and otherwise reconstructs
the per-pin data from ``comp["pins"]``. The three consumers iterate
``iter_pads(comp)`` instead of ``comp["pins"]``.

FAIL-CLOSED (Stage 2 step 4a-ii, closes bug 019f7736b236)
---------------------------------------------------------
The SMD placeholder literals are GONE from the emitters. Instead, the two
SIZE-consuming emitters (gerber + kicad) call ``iter_pads(comp,
require_smd_size=True)``: an SMD pad that carries no positive copper size — from
resolve OR from an inline ``pad_width_mm``/``pad_height_mm`` — now RAISES
``PadGeometryError`` rather than fabricating a fake rectangle. Real fab runs
resolve the board first (methods._maybe_resolve, gate default ON, best-effort),
so a resolvable footprint supplies the geometry; only a genuinely geometry-less
SMD pad fails, and it fails LOUD instead of shipping wrong copper.

``require_smd_size`` is OPT-IN because drc._harvest_pads also calls ``iter_pads``
but reads only pad CENTERS (never size) — so DRC must keep working on a board
whose SMD pads have no size, and it passes ``require_smd_size=False`` (the
default). Centralising the check here (not duplicated in each emitter) keeps it
DRY and keeps ``pad_source`` the single owner of pad-geometry policy.

Coordinates are component-LOCAL (pre-placement-rotation), the SAME frame the
pins and the resolved pads both use; the placement transform is applied
downstream by each consumer (gerber/drc rotate; kicad emits local under the
footprint's own ``(at x y rot)``).
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any


class PadGeometryError(ValueError):
    """An SMD pad reached a size-consuming emitter with no copper geometry.

    Fail-closed signal for bug 019f7736b236: rather than flashing a placeholder
    rectangle, the emitter refuses. Carries the component ref + pad number so the
    caller (methods._gerbers/_generate) can surface it as a structured fab error.
    """

    def __init__(self, ref: Any, number: Any, width: Any, height: Any):
        self.ref = ref
        self.number = number
        super().__init__(
            f"component {ref!r} pad {number!r} is SMD but has no copper geometry "
            f"(width={width}, height={height}); resolve its footprint or declare "
            f"inline pad_width_mm/pad_height_mm — fail-closed, bug 019f7736b236"
        )


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
      * ``width``/``height`` are ``None`` when the source declares no size. The
        size-consuming emitters (gerber/kicad) demand a real size via
        ``iter_pads(require_smd_size=True)``, which fail-closes on a sizeless
        SMD pad; drc ignores size entirely.
    """

    number: Any            # raw pin number (str|None|...) — see class note
    x: float               # component-LOCAL (pre-placement-rotation)
    y: float
    width: float | None    # SMD copper width; None => no declared/resolved size
    height: float | None
    drill: float | None    # drill diameter mm (0.0 preserved); None => no datum
    annulus: float | None  # TH copper annulus diameter; None => emitter default
    plated: bool
    shape: str
    pad_type: str          # "smd" | "thru_hole" | "np_thru_hole"
    layers: list
    from_resolve: bool     # per-pad view of has_resolved_pads(comp): resolved vs fallback


def has_resolved_pads(comp: Any) -> bool:
    """The ONE definition of "this component's pad geometry came from a resolved
    footprint" (vs the inline-pin fallback).

    ``resolve._resolve_component`` attaches the real footprint pad list to
    ``comp["pads"]``; a non-empty list there is the SINGLE ground truth for the
    resolved-vs-fallback fact. The board-dict view ``comp["has_pad_geometry"]``
    (resolve.py), the per-pad ``PadGeom.from_resolve`` marker, and the branch in
    ``iter_pads`` below all derive from THIS predicate — so the fact has one
    definition rather than several independently-computed copies (Stage 2 step 7
    provenance-collapse, docket 019f761fe518 / 019f791cdf26). GDScript mirrors it
    across the worker↔panel boundary under the same key ``has_pad_geometry``
    (pcb_component.gd), with the legacy ``footprint_found`` key still accepted.
    """
    resolved = comp.get("pads") if isinstance(comp, dict) else None
    return isinstance(resolved, list) and bool(resolved)


def iter_pads(comp: dict, *, require_smd_size: bool = False) -> list[PadGeom]:
    """Yield normalised pad geometry for one component.

    PREFERS ``comp["pads"]`` (resolve_board's real footprint geometry) when it is
    a non-empty list; otherwise reconstructs the per-pin fallback from
    ``comp["pins"]``. One ``PadGeom`` per usable pad/pin, in source order.

    With ``require_smd_size=True`` (the two size-consuming emitters, gerber +
    kicad) every SMD pad MUST carry a positive width and height — a sizeless SMD
    pad raises ``PadGeometryError`` (fail-closed, bug 019f7736b236). drc leaves
    this ``False`` (it reads only centers), so it keeps working sizeless.
    """
    if not isinstance(comp, dict):
        return []
    if has_resolved_pads(comp):
        pads = [_from_resolved(p) for p in comp["pads"] if isinstance(p, dict)]
    else:
        pins = comp.get("pins")
        pins = pins if isinstance(pins, list) else []
        pads = [_from_pin(p) for p in pins if isinstance(p, dict)]

    if require_smd_size:
        ref = comp.get("ref")
        for pad in pads:
            _require_smd_size(ref, pad)
    return pads


def _require_smd_size(ref: Any, pad: PadGeom) -> None:
    """Fail-closed: an SMD pad (no drill) must carry a positive width AND height.

    A through-hole / mounting pad is exempt — its copper is a drill-derived
    annulus, not an SMD land. ``drill is None`` is the SMD test (both _from_pin
    and _from_resolved normalise a 0/negative drill to None), the SAME boundary
    kicad._footprint uses (``drill is not None`` => TH), so the fail-closed check
    and the emitters never disagree. A zero-size SMD pad — a latent form of the
    same placeholder bug — also fails closed now.
    """
    if pad.drill is None and not (pad.width and pad.width > 0
                                  and pad.height and pad.height > 0):
        raise PadGeometryError(ref, pad.number, pad.width, pad.height)


def _from_pin(pin: dict) -> PadGeom:
    """Fallback: reconstruct a pad from a canonical pin. Matches what
    gerber/kicad/drc read directly, and normalises a 0/negative drill to None
    (no hole) exactly as ``_from_resolved`` does — so both paths agree that a
    sizeless drill-less pad is an SMD land, and the fail-closed check + kicad's
    ``drill is not None`` TH test never disagree at the degenerate drill==0."""
    drill = _opt_num(pin.get("drill_mm"))
    if drill is not None and drill <= 0:
        drill = None
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
