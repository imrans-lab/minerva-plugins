"""Single resolve-aware pad-geometry accessor for the fabrication compilers.

Before this module, three pad-geometry readers hand-read ``comp["pins"]`` — the
two SIZE-consuming fabrication emitters (gerber._harvest, kicad._footprint) plus
the TOLERANT DRC reader (drc._harvest_pads, which reads pad CENTERS only, never
size). The two emitters, for an SMD pad with no declared geometry, fell back to a
hard-coded PLACEHOLDER size (gerber 1.0x0.6, kicad 1/0.6). That placeholder is the
emitter pad-geometry bug (docket 019f7736b236): the RAW board's pins carry no
footprint pad geometry, so a fab run flashed nominal rectangles instead of the real
lands. DRC never hit the placeholder (it ignores size) and stays tolerant — the
fail-closed geometry checks below bind only the two fabrication emitters.

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
from typing import TYPE_CHECKING, Any

from .fab_capability import SUPPORTED_PAD_SHAPES

if TYPE_CHECKING:
    from .resolved_board import PlacedPad


class PadGeometryError(ValueError):
    """A pad reached a size-consuming emitter with no faithful copper geometry.

    Fail-closed signal: rather than flashing a placeholder rectangle (SMD, bug
    019f7736b236) or INVENTING a copper ring (plated through-hole, K4 —
    fabrication-critical copper is never invented, mirroring the board-hole
    contract finding 019f8dbb7104), the emitter refuses. Carries the component
    ref + pad number so the caller (methods._gerbers/_generate) can surface it as
    a structured fab error.
    """

    def __init__(self, ref: Any, number: Any, message: str):
        self.ref = ref
        self.number = number
        super().__init__(message)

    @classmethod
    def smd_no_size(cls, ref: Any, number: Any, width: Any, height: Any) -> "PadGeometryError":
        return cls(
            ref, number,
            f"component {ref!r} pad {number!r} is SMD but has no copper geometry "
            f"(width={width}, height={height}); resolve its footprint or declare "
            f"inline pad_width_mm/pad_height_mm — fail-closed, bug 019f7736b236")

    @classmethod
    def th_no_annulus(cls, ref: Any, number: Any, annulus: Any, drill: Any) -> "PadGeometryError":
        return cls(
            ref, number,
            f"component {ref!r} pad {number!r} is a PLATED through-hole pad with no "
            f"VALID copper annulus (annulus={annulus!r}, drill={drill!r}); the round "
            f"copper ring must be a finite POSITIVE diameter — author an "
            f"'annulus_diameter_mm' or a pad size — fail-closed, never invented (K4, "
            f"mirrors the plated-board-hole contract finding 019f8dbb7104)")

    @classmethod
    def th_annulus_not_bigger_than_drill(
            cls, ref: Any, number: Any, annulus: Any, drill: Any) -> "PadGeometryError":
        return cls(
            ref, number,
            f"component {ref!r} pad {number!r}: plated through-hole copper annulus "
            f"{annulus} must EXCEED the drill {drill} to leave a copper ring — "
            f"fail-closed (physical invariant, distinct from a board-house min "
            f"annular-ring policy; mirrors the board-hole check finding 019f8dbb7104)")

    @classmethod
    def drill_not_finite(cls, ref: Any, number: Any, drill: Any) -> "PadGeometryError":
        return cls(
            ref, number,
            f"component {ref!r} pad {number!r}: through-hole drill diameter {drill!r} "
            f"is not finite — a drilled hole must be a FINITE positive diameter; "
            f"fail-closed (bug 019f91c1420c: a 0/negative drill is normalized to no "
            f"hole, but a NaN/Inf drill is a corrupt TH intent the two emitters would "
            f"otherwise treat divergently — Gerber crashes, KiCad emits `(drill nan)`)")

    @classmethod
    def authored_drill_invalid(cls, ref: Any, number: Any, drill: Any) -> "PadGeometryError":
        return cls(
            ref, number,
            f"component {ref!r} pad {number!r}: authored drill_mm {drill!r} is not a "
            f"finite positive diameter — a raw pin that AUTHORS a drill_mm must author "
            f"a valid hole; OMIT drill_mm (or set it null) for an SMD pad. Fail-closed, "
            f"never silently dropped to an SMD pad (bug 019f924ce991).")

    @classmethod
    def mask_opening_collapsed(
            cls, ref: Any, number: Any, dim: Any, margin: Any) -> "PadGeometryError":
        return cls(
            ref, number,
            f"component {ref!r} pad {number!r}: solder-mask opening dimension "
            f"{dim} is not a finite positive value (margin {margin}) — fail-closed")


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
      * ``drill`` is the drill diameter mm, or ``None`` for no hole. The factories
        normalize a FINITE <= 0 drill to None; a PRESENT non-finite drill is
        preserved and fail-closed by ``_require_finite_drill``. All three fab sites
        (gerber, kicad, drc) classify through-hole via the ONE shared
        ``is_through_hole`` predicate (finite positive), so they cannot diverge on
        this field (bug 019f91c1420c retired the per-emitter literals).
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
    drill: float | None    # drill diameter mm (finite positive => hole); None => no hole
    annulus: float | None  # round TH copper annulus diameter; None on a plated TH pad fails closed at emit (require_th_annulus) — never an emitter-invented default
    plated: bool
    shape: str
    corner_rratio: float | None  # roundrect corner radius / min(w,h), in [0,0.5]; None => none/default
    solder_mask_margin: float | None  # per-side mask growth over copper; None => board global clearance
    pad_type: str          # "smd" | "thru_hole" | "np_thru_hole"
    layers: list
    from_resolve: bool     # per-pad view of has_resolved_pads(comp): resolved vs fallback
    rotation: float | None = None  # ABSOLUTE combined pad angle (IR placed mode); None => use the component angle (legacy). Read by the IR fab bridges: gerber placed path (W8.1) AND kicad absolute-under-identity (W8.1b, emitted as the pad (at) third value).
    raw_shape: str | None = None  # the FOOTPRINT-AUTHORED shape token, None when the footprint pad declared none (resolve defaulted `shape` to "rect"). th_land shapes an EQUAL-AXIS TH land only when the shape was genuinely authored (D1, finding 019f8b7fd295) — a defaulted-rect square stays a round annulus.


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
            # FIRST: a present-but-non-finite drill fails closed before any TH-vs-SMD
            # predicate (or the SMD-size check) reads it — else a NaN drill slips past
            # both (nan is not None, nan > 0 is False) and diverges at emit.
            _require_finite_drill(ref, pad)
            # THEN: a raw pin that AUTHORED a malformed drill_mm (finite <=0, bool,
            # string) fails closed even if it also carries a pad size — else the hole
            # is silently dropped and it fabricates as an SMD pad (bug 019f924ce991).
            _require_valid_authored_drill(ref, rawpad, pad)
            _require_smd_size(ref, pad)
            _require_faithful_shape(ref, rawpad, pad)
            _require_valid_solder_mask_margin(ref, rawpad, pad)
    return pads


def _require_finite_drill(ref: Any, pad: PadGeom) -> None:
    """Fail-closed: a PRESENT drill datum must be a FINITE positive diameter.

    The pad factories normalize a finite 0/negative drill to None (no hole -> SMD,
    the accepted degenerate handling — Codex d00427f). A PRESENT but NON-FINITE
    drill (NaN / +-Inf) is a corrupt through-hole intent that the two emitters would
    otherwise treat DIVERGENTLY and INVALIDLY: gerber's ``drill > 0`` is False for
    NaN so it mis-routes to the SMD branch and crashes on ``None + mask_margin``
    (unstructured TypeError); kicad's ``drill is not None`` is True so it emits a
    malformed ``thru_hole ... (drill nan)``. This is the SINGLE drill boundary both
    emitters share (bug 019f91c1420c) — a non-finite drill fails closed here, WITH
    pad context, before either predicate runs, for plated AND unplated holes."""
    d = pad.drill
    if d is not None and not math.isfinite(d):
        raise PadGeometryError.drill_not_finite(ref, pad.number, d)


def _require_valid_authored_drill(ref: Any, rawpad: dict, pad: PadGeom) -> None:
    """Fail-closed: a RAW pin that AUTHORS a ``drill_mm`` must author a VALID one.

    Distinguishes an ABSENT drill (a legitimate SMD pad) from a PRESENT-but-malformed
    one. The pad factories normalize a finite <=0 / nonnumeric / bool ``drill_mm`` to
    None (no hole); combined with an authored pad size BOTH raw emitters would then
    silently fabricate an ordinary SMD pad, DISCARDING the authored drill intent (bug
    019f924ce991: agreement is not correctness). The raw emitter's contract is
    fail-closed: a pin that WROTE a ``drill_mm`` but wrote a value that cannot form a
    hole (bool, string, non-finite, or <= 0) fails closed WITH context rather than
    shipping copper the author did not intend. To author an SMD pad, OMIT ``drill_mm``
    (or set it null).

    Resolved pads are EXEMPT: they carry no ``drill_mm`` (their hole is ``drill:{x,y}``
    with {0,0} the no-hole SENTINEL, not an authored value), and the IR guarantees a
    finite positive drill otherwise. A non-finite drill on either path is already
    fail-closed by ``_require_finite_drill`` (which runs first, so NaN/Inf reports as
    drill_not_finite)."""
    if pad.from_resolve or "drill_mm" not in rawpad:
        return
    raw = rawpad["drill_mm"]
    if raw is None:
        return  # explicit null == absent == SMD intent
    if (isinstance(raw, bool) or not isinstance(raw, (int, float))
            or not math.isfinite(raw) or raw <= 0):
        raise PadGeometryError.authored_drill_invalid(ref, pad.number, raw)


def _require_smd_size(ref: Any, pad: PadGeom) -> None:
    """Fail-closed: an SMD pad (no drill) must carry a positive width AND height.

    A through-hole / mounting pad is exempt — its copper is a drill-derived
    annulus, not an SMD land. ``not is_through_hole(pad)`` is the SMD test — the
    SAME shared predicate both emitters use (bug 019f91c1420c), so the fail-closed
    check and the emitters can never disagree on what counts as SMD. (A present
    non-finite drill has already fail-closed in ``_require_finite_drill``, which
    runs first, so here a pad is SMD iff it has no finite-positive drill.) A
    zero-size SMD pad — a latent form of the placeholder bug — also fails closed.
    """
    if not is_through_hole(pad) and not (pad.width and pad.width > 0
                                         and pad.height and pad.height > 0):
        raise PadGeometryError.smd_no_size(ref, pad.number, pad.width, pad.height)


def require_th_annulus(pad: PadGeom, ref: Any) -> float:
    """The round-annulus copper diameter for a PLATED through-hole pad — the SINGLE
    accessor both fab emitters consume, so gerber and kicad can never diverge on the
    "faithful-or-fail-closed" contract (K4).

    Returns ``pad.annulus`` when present. A plated TH pad that reaches here with NO
    resolved annulus fails CLOSED (``PadGeometryError``) — the emitter never invents
    a ring (the retired ``pad.annulus or drill*2`` fallback), exactly as a plated
    board hole must author its ``annulus_mm`` (finding 019f8dbb7104). On the
    production path this can't fire — a footprint TH pad's copper size doubles as the
    annulus (placed_pad_to_geom / _from_resolved) and a plated copper pad with no
    size is already rejected at compile by ``_check_pad_capabilities``
    (``missing_pad_size``). This is the defense-in-depth for the raw loose-dict path:
    a plated TH pin authoring NEITHER an ``annulus_diameter_mm`` NOR a pad size (both
    factories now derive the annulus from an authored size — see ``_from_pin`` /
    ``_from_resolved``).

    Callers gate this on the SAME predicate the emitters use for the round-annulus
    branch (plated, drilled, equal-axis land), so an unplated ``np_thru_hole`` (bare
    mechanical hole, no copper ring) never reaches it.

    The returned value is VALIDATED, never merely non-None (bug 019f91b61337): a
    zero / negative / NaN / infinite diameter would otherwise flash a malformed
    aperture (Gerber) or a degenerate/negative pad (KiCad) and let the two emitters
    diverge. It must be a finite positive diameter that EXCEEDS the drill (else there
    is no copper ring — the physical invariant, mirroring the board-hole check; this
    is NOT a board-house minimum-annular-ring policy, which stays a fab-house
    concern).
    """
    ann = pad.annulus
    if ann is None or not math.isfinite(ann) or ann <= 0:
        raise PadGeometryError.th_no_annulus(ref, pad.number, ann, pad.drill)
    if pad.drill is not None and ann <= pad.drill:
        raise PadGeometryError.th_annulus_not_bigger_than_drill(
            ref, pad.number, ann, pad.drill)
    return ann


def is_th_drill(drill: "float | None") -> bool:
    """Scalar through-hole test: a drill denotes a hole iff it is a FINITE POSITIVE
    diameter. The ONE definition every consumer derives from — ``is_through_hole``
    (PadGeom), the ``_from_pin`` pad_type, and the router bridge's raw-pin
    classification (route_bridge, bug 019f920d433f) — so not even a sibling module or
    the factory can grow a divergent literal (bug 019f91c1420c). Public because it is
    shared across modules that hold a bare scalar drill rather than a PadGeom."""
    return drill is not None and math.isfinite(drill) and drill > 0


def is_through_hole(pad: "PadGeom") -> bool:
    """The SINGLE through-hole predicate all three fab sites consume (gerber, kicad,
    drc), so they can never diverge on the TH-vs-SMD classification (bug
    019f91c1420c).

    A pad is through-hole iff it carries a FINITE POSITIVE drill diameter. Before
    this predicate each site hand-wrote its own literal that only HAPPENED to agree:
    gerber/drc ``drill is not None and drill > 0``, kicad ``drill is not None``.
    They were equivalent only because the pad factories normalize a finite <= 0
    drill to None (no hole); a PRESENT non-finite drill (NaN/Inf) is fail-closed
    upstream by ``_require_finite_drill``. Literals kept in lockstep BY HAND drift —
    this states the contract ONCE, positively, and is robust by construction
    (``isfinite`` means a stray NaN can never be classified through-hole here, so
    even off the validated path the sites cannot disagree)."""
    return is_th_drill(pad.drill)


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

    An EQUAL-AXIS land is shaped too when its shape was genuinely AUTHORED by the
    footprint (``pad.raw_shape`` in a shapeable family) — a real square ``rect``
    pin-1 marker or a rounded-rect land keeps its corners instead of collapsing to a
    round annulus (D1, finding 019f8b7fd295 comment 688). A DEFAULTED ``rect``
    (``raw_shape is None``, resolve's fallback for an unshaped pad) stays a round
    annulus, so a plain round TH pad is unaffected — oblongness OR authored-shape,
    not the effective token, is the signal.

    This function NEVER coerces an unrecognized shape: an oblong land whose shape is
    not shapeable (circle / custom / unknown) has no faithful oblong aperture and is
    fail-closed UPSTREAM by ``_require_faithful_shape`` before emission, so the
    ``shaped=False`` return for such a land is unreachable on the gated emit path
    (returning round there would circularize — the exact defect this fixes)."""
    w, h = pad.width, pad.height
    if w is None or h is None or pad.shape not in _TH_SHAPEABLE:
        return (False, "circle", 0.0, 0.0, None)
    oblong = abs(w - h) > _TH_OBLONG_TOL_MM
    # An EQUAL-AXIS land is shaped only for an authored CORNERED shape (rect /
    # roundrect) — a genuine square / rounded-square land keeps its corners. An
    # equal-axis authored OVAL is geometrically a circle, so it stays a round
    # annulus (no spurious obround); a defaulted rect (raw_shape None) stays round.
    authored_cornered = pad.raw_shape in ("rect", "roundrect")
    if oblong or authored_cornered:
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

    A THROUGH-HOLE pad's copper is a round annulus UNLESS ``th_land`` shapes it —
    either an OBLONG land, OR an equal-axis land whose shape was genuinely AUTHORED
    as a cornered ``rect``/``roundrect`` (D1, finding 019f8b7fd295: a square /
    rounded-square land keeps its corners). Only a DEFAULTED-``rect`` or an
    (equal-axis) ``oval`` land stays a round annulus. A shaped TH land must have a
    shapeable family (``_TH_SHAPEABLE``) to be emitted faithfully — a ``circle``
    cannot be oblong and a ``custom``/unknown token has no faithful copper aperture,
    so such a land fails CLOSED here rather than being silently circularized (dropping copper
    extent) or coerced to an obround (misrepresenting a custom outline) — finding
    019f8b7fd295, "faithfully OR fail closed". The raw pad dict is needed because a
    non-numeric ``corner_rratio`` is coerced to None before it reaches PadGeom."""
    # A roundrect corner ratio must be finite in [0, 0.5] for ANY roundrect land —
    # SMD or a (now shapeable) TH land (D1). Checked BEFORE the drill branch so a
    # through-hole roundrect no longer skips it (an unvalidated ratio would flatten
    # to a plain rectangle or crash the aperture writer on fabrication-critical
    # copper). Runs on the raw value: a non-numeric is coerced to None before PadGeom.
    if pad.shape == "roundrect":
        rr = rawpad.get("corner_rratio")
        if rr is not None and (isinstance(rr, bool)
                               or not isinstance(rr, (int, float))
                               or not math.isfinite(rr)
                               or not 0.0 <= rr <= 0.5):
            raise ValueError(
                f"component {ref!r} pad {pad.number!r}: roundrect corner_rratio "
                f"{rr!r} must be a finite number in [0, 0.5]")
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
    <= 0 is a geometric check owned by mask_opening_dim (margin + clearance in hand)."""
    smm = rawpad.get("solder_mask_margin")
    if smm is None:
        return
    if (isinstance(smm, bool) or not isinstance(smm, (int, float))
            or not math.isfinite(smm)):
        raise ValueError(
            f"component {ref!r} pad {pad.number!r}: solder_mask_margin "
            f"{smm!r} must be a finite number")


def mask_opening_dim(base: float, margin: float, ref: Any, number: Any) -> float:
    """Enlarge a copper dimension by the per-side solder-mask ``margin``, failing
    CLOSED unless the resulting opening is a FINITE POSITIVE dimension. A collapse to
    <= 0 (e.g. a large-negative margin) is not a manufacturable mask window; a
    non-finite opening (NaN/±Inf base or margin — e.g. a +Inf global clearance that
    slipped a resolver, bug 019f94b686b4) is malformed geometry. A merely-negative
    margin whose opening stays > 0 is a legitimate KiCad mask-sliver feature and IS
    accepted (symmetry with _require_valid_solder_mask_margin, which accepts finite
    negatives).

    The SINGLE owner of the mask-opening geometry boundary, SHARED by both CAM
    emitters (gerber._mask_dim aliases this; kicad gates its per-pad
    solder_mask_margin through it) so the two never disagree on the fail boundary
    (bug 019f929b1416) — and the last-line guard against a non-finite clearance
    reaching either emitter's aperture text (bug 019f94b686b4)."""
    dim = base + 2 * margin
    if not (math.isfinite(dim) and dim > 0):
        raise PadGeometryError.mask_opening_collapsed(ref, number, dim, margin)
    return dim


# Per-side solder-mask expansion default for a RAW (loose-dict) board that authors
# no global clearance. Production always carries the compiler-resolved value in the
# ResolvedBoard IR (compile_board's v1 manufacturing floor, 0.05mm).
DEFAULT_MASK_CLEARANCE_MM = 0.1


def resolve_global_mask_clearance(board: dict) -> float:
    """The per-side solder-mask clearance for a RAW (loose-dict) board, resolved
    IDENTICALLY for both CAM emitters (gerber.build_gerbers / kicad.generate) so a
    raw board never diverges between them. A board that authors NO global clearance
    gets the documented raw default :data:`DEFAULT_MASK_CLEARANCE_MM`. An authored
    ``design_rules.solder_mask_clearance_mm`` that is PRESENT must be a finite,
    non-negative number, else fail CLOSED (attributed) — an authored-but-invalid
    global clearance is corrupt fab intent, NOT a missing value, so it must never be
    silently rewritten to the default nor leaked as malformed geometry (bug
    019f94b686b4: -1/NaN/-Inf were silently swapped to 0.1; +Inf reached the emitter
    aperture text literally). The canonical production path does NOT reach here —
    compile_board bakes the v1 manufacturing floor (0.05mm) into the ResolvedBoard
    IR before emission."""
    dr = board.get("design_rules")
    if not isinstance(dr, dict):
        return DEFAULT_MASK_CLEARANCE_MM
    mc = dr.get("solder_mask_clearance_mm")
    if mc is None:
        return DEFAULT_MASK_CLEARANCE_MM
    if (isinstance(mc, bool) or not isinstance(mc, (int, float))
            or not math.isfinite(mc) or mc < 0):
        raise ValueError(
            f"design_rules.solder_mask_clearance_mm {mc!r} must be a finite, "
            f"non-negative number (mm) — fail-closed, never silently defaulted to "
            f"{DEFAULT_MASK_CLEARANCE_MM} nor emitted as malformed geometry "
            f"(bug 019f94b686b4)")
    return float(mc)


def pad_mask_margin(pad: "PadGeom", mask_clearance: float) -> float:
    """The effective per-side solder-mask margin for one pad, SHARED by both CAM
    emitters so they produce the same mask opening (bug 019f9266b9cd). An UNPLATED
    hole (np_thru_hole / plated False) gets a drill-size opening (margin 0, matching
    gerber's literal-drill NPTH); every copper pad (SMD or plated TH) gets its own
    ``solder_mask_margin`` override, else the board clearance. (Gerber never calls
    this on an NPTH pad — its NPTH branch emits the literal drill — so the margin-0
    branch is a no-op for gerber's plated-TH/SMD call sites and load-bearing only for
    kicad, which emits (solder_mask_margin) on the np_thru_hole line too.)"""
    if is_through_hole(pad) and not (pad.plated and pad.pad_type != "np_thru_hole"):
        return 0.0
    return pad.solder_mask_margin if pad.solder_mask_margin is not None else mask_clearance


def _from_pin(pin: dict) -> PadGeom:
    """Fallback: reconstruct a pad from a canonical pin. Matches what
    gerber/kicad/drc read directly, and normalises a FINITE 0/negative drill to
    None (no hole) exactly as ``_from_resolved`` does — so both paths agree that a
    sizeless drill-less pad is an SMD land, and every consumer's TH test agrees at
    the degenerate drill==0. A PRESENT non-finite drill (NaN/+-Inf) is deliberately
    PRESERVED here so the shared ``_require_finite_drill`` boundary fails it closed
    with pad context (bug 019f91c1420c) rather than it silently becoming a no-hole
    SMD via ``-inf <= 0``."""
    drill = _opt_num(pin.get("drill_mm"))
    if drill is not None and math.isfinite(drill) and drill <= 0:
        drill = None
    width = _opt_num(pin.get("pad_width_mm"))
    # A drilled pad's round-annulus copper: the pin's authored annulus_diameter_mm
    # when present, else its authored pad width doubles as the annulus — the SAME
    # "copper size IS the annulus" rule _from_resolved applies, so the raw and
    # resolved factories agree. Only a plated TH pin authoring NEITHER an annulus
    # nor a size resolves annulus=None and fails closed downstream (require_th_annulus).
    explicit_annulus = _opt_num(pin.get("annulus_diameter_mm"))
    return PadGeom(
        number=pin.get("number"),
        x=_num(pin.get("x_mm")),
        y=_num(pin.get("y_mm")),
        width=width,
        height=_opt_num(pin.get("pad_height_mm")),
        drill=drill,
        annulus=(explicit_annulus if explicit_annulus is not None
                 else (width if drill is not None else None)),
        plated=(pin.get("plated", True) is not False),
        shape="rect",
        corner_rratio=None,  # inline-pin fallback carries no footprint corner datum
        solder_mask_margin=_opt_num(pin.get("solder_mask_margin")),
        pad_type=("thru_hole" if is_th_drill(drill) else "smd"),
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
    # FINITE 0/negative -> no hole (SMD); a non-finite drill is preserved for
    # _require_finite_drill to fail closed (bug 019f91c1420c). On the IR path the
    # compiler already guarantees a finite drill, so this guard is a no-op there.
    if drill is not None and math.isfinite(drill) and drill <= 0:
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
        # FOOTPRINT-authored shape token (None => defaulted), the D1 provenance
        # signal th_land uses to shape an equal-axis authored land.
        raw_shape=pad.get("raw_shape"),
    )


def placed_pad_to_geom(pad: "PlacedPad", number: str) -> PadGeom:
    """A board-absolute :class:`PlacedPad` (K2 IR) -> a :class:`PadGeom` — the
    IR-NATIVE pad accessor the fab emitters use so they consume the ResolvedBoard
    directly (C5: the IR->loose-dict adapter is gone).

    It projects the PlacedPad into the resolved-pad dict shape and reuses
    :func:`_from_resolved`, so the IR path and the raw loose-dict path apply the SAME
    TH annulus/drill contract and size/None handling. A drilled pad's copper width
    doubles as the annulus: the override-set :attr:`PlacedPad.annulus` when present
    (round), else the footprint copper :attr:`PlacedPad.size`."""
    is_drilled = pad.drill is not None
    if is_drilled:
        if pad.annulus is not None:
            width = height = pad.annulus
        elif pad.size is not None:
            width, height = pad.size
        else:
            width = height = None
    else:
        width, height = pad.size if pad.size is not None else (None, None)
    d: dict = {
        "number": number,
        "type": pad.pad_type,
        "shape": pad.shape.value,
        "position": {"x": pad.position[0], "y": pad.position[1]},
        "layers": [layer.id for layer in pad.layers],
        "rotation": pad.rotation_deg,
        "drill": ({"x": pad.drill.size[0], "y": pad.drill.size[1]}
                  if is_drilled else {"x": 0.0, "y": 0.0}),
    }
    if width is not None and height is not None:
        d["size"] = {"width": width, "height": height}
    if pad.corner_rratio is not None:
        d["corner_rratio"] = pad.corner_rratio
    if pad.solder_mask_margin is not None:
        d["solder_mask_margin"] = pad.solder_mask_margin
    # D1 provenance — but an OVERRIDE annulus (pad.annulus set) is an explicitly
    # ROUND copper ring that supersedes the footprint's authored shape, so it is not
    # carried: an override-annulus pad stays a round annulus regardless of raw_shape.
    if pad.raw_shape is not None and pad.annulus is None:
        d["raw_shape"] = pad.raw_shape
    return _from_resolved(d)
