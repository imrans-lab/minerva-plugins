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

import math
from dataclasses import dataclass
from typing import Any

from .fab_capability import SUPPORTED_PAD_SHAPES


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
    corner_rratio: float | None  # roundrect corner radius / min(w,h), in [0,0.5]; None => none/default
    solder_mask_margin: float | None  # per-side mask growth over copper; None => board global clearance
    pad_type: str          # "smd" | "thru_hole" | "np_thru_hole"
    layers: list
    from_resolve: bool     # per-pad view of has_resolved_pads(comp): resolved vs fallback
    rotation: float | None = None  # ABSOLUTE combined pad angle (IR placed mode); None => use the component angle (legacy). Read by the IR fab bridges: gerber placed path (W8.1) AND kicad absolute-under-identity (W8.1b, emitted as the pad (at) third value).


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
        raw = [p for p in comp["pads"] if isinstance(p, dict)]
        pads = [_from_resolved(p) for p in raw]
    else:
        pins = comp.get("pins")
        pins = pins if isinstance(pins, list) else []
        raw = [p for p in pins if isinstance(p, dict)]
        pads = [_from_pin(p) for p in raw]

    if require_smd_size:
        ref = comp.get("ref")
        for rawpad, pad in zip(raw, pads):
            _require_smd_size(ref, pad)
            _require_faithful_shape(ref, rawpad, pad)
            _require_valid_solder_mask_margin(ref, rawpad, pad)
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


# Circle width/height must agree to within this to be a faithful circle.
_SHAPE_TOL_MM = 1e-6


# Two through-hole land dims within this tolerance are treated as equal (a round
# annulus); beyond it the land is genuinely oblong. Shared by BOTH emitters via
# th_land so gerber and kicad cannot drift on the decision.
_TH_OBLONG_TOL_MM = 1e-6

# The pad-shape families for which a genuinely OBLONG through-hole land has a
# faithful non-round copper aperture in both emitters. A KiCad ``circle`` cannot be
# oblong; ``custom`` / ``trapezoid`` / any unknown token has no faithful oblong
# aperture — an oblong land carrying one is fail-closed by _require_faithful_shape
# (never silently coerced, never silently circularized).
_TH_SHAPEABLE = ("oval", "roundrect", "rect")


def th_land(pad: "PadGeom") -> tuple[bool, str, float, float, "float | None"]:
    """Decide a through-hole pad's COPPER-LAND geometry — the SINGLE source of
    truth both fab emitters consume, so gerber and kicad can never disagree on
    when/how a TH land is shaped (the anti-drift point of finding 019f8b7fd295).

    Returns ``(shaped, shape, width, height, corner_rratio)``.

    A TH land is SHAPED — faithful oblong copper honoring width AND height — when it
    declares both dims, they DIFFER (``abs(w-h) > tol``), AND the declared shape is a
    shapeable family (``_TH_SHAPEABLE``). Oblongness is the reliable size signal:
    ``resolve`` defaults an unshaped pad's ``shape`` to ``rect``
    (pad_source._from_resolved) and sets its round-annulus diameter to the pad
    WIDTH, so a 1.2x2.0 land silently collapsed to a round dia-1.2 annulus, dropping
    the height (the finding). An equal-axis land stays the historical round annulus
    (``shaped=False``, byte-identical goldens). The round DRILL is unchanged in both
    cases (SUPPORTED_HOLE_SHAPES) — only the LAND takes a shape.

    This function NEVER coerces an unrecognized shape: an oblong land whose shape is
    not shapeable (circle / custom / unknown) has no faithful oblong aperture and is
    fail-closed UPSTREAM by ``_require_faithful_shape`` before emission, so the
    ``shaped=False`` return for such a land is unreachable on the gated emit path
    (returning round there would circularize — the exact defect this fixes)."""
    w, h = pad.width, pad.height
    if (w is not None and h is not None and abs(w - h) > _TH_OBLONG_TOL_MM
            and pad.shape in _TH_SHAPEABLE):
        return (True, pad.shape, w, h, pad.corner_rratio)
    return (False, "circle", 0.0, 0.0, None)


def _require_faithful_shape(ref: Any, rawpad: dict, pad: PadGeom) -> None:
    """Fail-closed: SMD pad geometry an emitter cannot render faithfully must
    error WITH CONTEXT rather than silently corrupt or flatten copper (the K3
    capability-conformance doctrine, 019f8a44484f / 019f7aed6d9e comment 628).

      * a ``circle`` whose width != height has no faithful single circular
        aperture — emitting one silently drops an axis (copper corruption);
      * a ``roundrect`` corner ratio must be a finite number in [0, 0.5]. A
        negative or non-numeric ratio would otherwise silently flatten to a plain
        rectangle (the exact defect class this gate exists to kill) or crash the
        aperture writer with no pad context.

    A THROUGH-HOLE pad's copper is a round annulus UNLESS its land is oblong
    (th_land). An equal-axis TH land is a round annulus regardless of shape token,
    so it is exempt. An OBLONG TH land, however, must have a shapeable family
    (``_TH_SHAPEABLE``) to be emitted faithfully — a ``circle`` cannot be oblong and
    a ``custom``/unknown token has no faithful oblong copper aperture, so such a land
    fails CLOSED here rather than being silently circularized (dropping copper
    extent) or coerced to an obround (misrepresenting a custom outline) — finding
    019f8b7fd295, "faithfully OR fail closed". The raw pad dict is needed because a
    non-numeric ``corner_rratio`` is coerced to None before it reaches PadGeom."""
    if pad.drill is not None:
        if (pad.width is not None and pad.height is not None
                and abs(pad.width - pad.height) > _TH_OBLONG_TOL_MM
                and pad.shape not in _TH_SHAPEABLE):
            raise ValueError(
                f"component {ref!r} pad {pad.number!r}: oblong through-hole land "
                f"{pad.width}x{pad.height} has shape {pad.shape!r}, which has no "
                f"faithful oblong copper aperture (shapeable: {sorted(_TH_SHAPEABLE)}) "
                f"— refusing to circularize (drop copper extent) or coerce it")
        return
    if pad.shape not in SUPPORTED_PAD_SHAPES:
        # An unknown SMD shape would sail through to the emitter's aperture/token
        # mapping and silently FLATTEN to a rectangle (gerber _shape_aperture /
        # kicad _smd_shape_tokens both fall through to rect) with no diagnostic —
        # the exact silent-flatten this gate exists to kill, on fabrication-
        # critical copper. Fail CLOSED with context instead.
        raise ValueError(
            f"component {ref!r} pad {pad.number!r}: SMD pad shape {pad.shape!r} is "
            f"not a supported pad shape {sorted(SUPPORTED_PAD_SHAPES)} — refusing to "
            f"silently flatten it to a rectangle")
    if (pad.shape == "circle" and pad.width is not None and pad.height is not None
            and abs(pad.width - pad.height) > _SHAPE_TOL_MM):
        raise ValueError(
            f"component {ref!r} pad {pad.number!r}: circle pad width {pad.width} "
            f"!= height {pad.height} — no faithful circular aperture")
    if pad.shape == "roundrect":
        rr = rawpad.get("corner_rratio")
        if rr is not None and (isinstance(rr, bool)
                               or not isinstance(rr, (int, float))
                               or not math.isfinite(rr)
                               or not 0.0 <= rr <= 0.5):
            raise ValueError(
                f"component {ref!r} pad {pad.number!r}: roundrect corner_rratio "
                f"{rr!r} must be a finite number in [0, 0.5]")


def _require_valid_solder_mask_margin(ref: Any, rawpad: dict, pad: PadGeom) -> None:
    """Fail-closed: a per-pad ``solder_mask_margin`` that is PRESENT must be a
    finite number (R2 mask-conformance, symmetric to _require_faithful_shape).

    The RAW value is read here — a non-numeric like the string ``"0.4"`` is coerced
    to None by ``_opt_num`` before it reaches PadGeom, which would silently fall
    back to the global clearance (a wrong-but-quiet mask window). Reading the raw
    dict catches the string / bool / NaN / ±inf and errors WITH pad context. Both
    SMD and TH pads carry a mask, so this is NOT gated on shape/drill (unlike
    _require_faithful_shape). A merely-negative but finite margin is a legitimate
    KiCad mask-sliver value and is accepted; whether it collapses the opening to
    <= 0 is a geometric check owned by gerber._mask_dim (margin + clearance in hand)."""
    smm = rawpad.get("solder_mask_margin")
    if smm is None:
        return
    if (isinstance(smm, bool) or not isinstance(smm, (int, float))
            or not math.isfinite(smm)):
        raise ValueError(
            f"component {ref!r} pad {pad.number!r}: solder_mask_margin "
            f"{smm!r} must be a finite number")


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
        corner_rratio=None,  # inline-pin fallback carries no footprint corner datum
        solder_mask_margin=_opt_num(pin.get("solder_mask_margin")),
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
        corner_rratio=_opt_num(pad.get("corner_rratio")),
        solder_mask_margin=_opt_num(pad.get("solder_mask_margin")),
        pad_type=pad_type,
        layers=pad.get("layers") or [],
        from_resolve=True,
        # ABSOLUTE combined pad angle from the IR (compile_board bakes the
        # placement rotation + footprint-local pad rotation into one value). Read by
        # the IR fab bridges — the gerber placed path AND kicad's absolute-under-
        # identity emit (kicad writes it as the pad (at) third value, which KiCad
        # reads as the absolute angle). Legacy resolve dicts carry no rotation key
        # for a zero-rotation pad so this stays None and the legacy path is
        # unchanged; a rotated-footprint resolve dict does carry it, and kicad now
        # honours it (previously dropped — Codex 2b).
        rotation=_opt_num(pad.get("rotation")),
    )
