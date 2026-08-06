"""Assembly-collision ADVISORY floor: courtyard/body bounding-box overlaps.

HITL-4 (docs/llm-ergonomics.md F3). On the live smart-remote round, D1 (an SMA
diode at 65.0, 12.7 rot 90) and BAT1 (a JST-PH horizontal header at 68.58, 12.7
rot 90) had physically overlapping BODIES — the parts cannot be assembled — and
NO gate fired: geometric DRC is copper/drill only (gc1-gc7), and courtyard
geometry, while captured per footprint, was "documentation-only" on every reply.
The owner had flagged that exact placement the previous cycle; the tooling
never named it.

This module is the cheap ergonomics FLOOR, deliberately NOT the deferred full
courtyard DRC (docket 019fce3a6c57):

  * per-component AXIS-ALIGNED BOUNDING BOXES only — no polygon clipping, no
    rotated-rect intersection. The basis is named on every advisory so a
    consumer knows exactly how coarse the claim is.
  * ADVISORY severity only. Nothing here gates, fails a route, or feeds a DRC
    verdict; it exists so a co-worker driving the tools blind can say "these
    parts collide" BEFORE proposing copper through them.
  * best effort by construction: malformed fields never raise — an advisory
    pass must never sink the reply it rides on. A component this module cannot
    measure (no coordinates, or no courtyard graphics AND no pad geometry) is
    COUNTED, not skipped: it becomes an ``indeterminate`` entry naming the
    component and why (work item 019fd5fddc09, DCR 019fd5fd9084). The pre-
    tri-state version silently dropped such components, which made "no
    advisories" ambiguous between "measured clean" and "could not measure" —
    exactly the lie-by-omission class HITL-4 exists to remove.

TRI-STATE (work item 019fd5fddc09): the public entry is :func:`assembly_check`,
returning ``{status, findings, indeterminate?}``:

  * ``status: "findings"``      — >=1 overlap advisory (findings win: a found
                                  collision is actionable regardless of what
                                  else could not be measured; any indeterminate
                                  entries still travel beside it).
  * ``status: "indeterminate"`` — NO findings but >=1 component unmeasurable,
                                  or the checker itself faulted (then with an
                                  ``error`` string). Never a silent pass.
  * ``status: "pass"``          — every component measured, nothing overlaps.

BASIS, per component (named in the advisory):

  "courtyard"  — the union bbox of the component's captured F.CrtYd/B.CrtYd
                 graphics (the footprint-LOCAL shapes resolve.py attaches and
                 the panel's captured-geometry import carries), rotated into
                 board space. This is the honest body outline — courtyards are
                 authored to be exactly the "no other part here" envelope.
  "pad_extent" — fallback when no courtyard was captured: the union bbox of
                 the component's pad lands (resolved ``pads`` or inline
                 ``pins``), plus PAD_EXTENT_MARGIN_MM on every side. Pads
                 under-approximate a body (the JST housing reaches ~4.5mm past
                 its pads), so this basis catches gross overlaps only — which
                 is why it is NAMED rather than passed off as a courtyard.

TRANSFORM: the same placement composition drc._harvest_pads uses — rotate the
LOCAL point by the component's ``rotation_deg`` via geometry.rotate_local_offset
(KiCad CW convention) and translate by ``x_mm``/``y_mm``. No bottom-side mirror
is applied (the centerline kernel applies none either); advisories only compare
components on the SAME side, so both parts in a pair get the same treatment.
"""

from __future__ import annotations

from typing import Any, Optional

from .geometry import is_top as _is_top, rotate_local_offset as _rotate

# Layers whose captured graphics count as the component's courtyard. The legacy
# resolve DTO only attaches F.CrtYd today (resolve._LEGACY_GRAPHIC_LAYERS), but
# captured-geometry imports may carry B.CrtYd; both describe the body envelope.
COURTYARD_LAYERS = frozenset({"F.CrtYd", "B.CrtYd"})

# The pad_extent basis pads its bbox by this much per side — a stand-in for the
# pad-to-courtyard margin a real footprint authors (typically 0.25mm, the KLC
# default courtyard clearance). Coarse on purpose; the basis field says so.
PAD_EXTENT_MARGIN_MM = 0.25

# Two bboxes must overlap by MORE than this area (mm^2) to be reported.
# Courtyards that exactly share an edge (parts placed flush by design) have
# zero overlap area and stay silent; this epsilon keeps float dust out too.
MIN_OVERLAP_MM2 = 1e-4


def _num(v: Any) -> Optional[float]:
    """A finite float, or None — never raises (advisory-grade tolerance)."""
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        f = float(v)
        if f == f and f not in (float("inf"), float("-inf")):
            return f
    return None


def _list(v: Any) -> list:
    return v if isinstance(v, list) else []


def _graphic_local_points(g: dict) -> list[tuple[float, float]]:
    """Every LOCAL point a captured graphic contributes to a bbox.

    Kinds mirror footprints._parse_graphics: line (start/end), circle
    (center +/- radius on both axes), arc (its control points — a chord-based
    under-approximation, acceptable for an advisory bbox because courtyards
    are overwhelmingly line/rect authored; the real F.CrtYd of both live
    reproduction footprints is four fp_lines), poly (its points)."""
    kind = g.get("kind")
    pts: list[tuple[float, float]] = []
    if kind == "line":
        for key in ("start", "end"):
            raw = g.get(key)
            if isinstance(raw, (list, tuple)) and len(raw) >= 2:
                x, y = _num(raw[0]), _num(raw[1])
                if x is not None and y is not None:
                    pts.append((x, y))
    elif kind == "circle":
        center = g.get("center")
        r = _num(g.get("radius"))
        if isinstance(center, (list, tuple)) and len(center) >= 2 \
                and r is not None:
            cx, cy = _num(center[0]), _num(center[1])
            if cx is not None and cy is not None:
                pts.extend([(cx - r, cy - r), (cx + r, cy + r)])
    elif kind in ("arc", "poly"):
        for raw in _list(g.get("points")):
            if isinstance(raw, (list, tuple)) and len(raw) >= 2:
                x, y = _num(raw[0]), _num(raw[1])
                if x is not None and y is not None:
                    pts.append((x, y))
    return pts


def _courtyard_local_points(comp: dict) -> list[tuple[float, float]]:
    pts: list[tuple[float, float]] = []
    for g in _list(comp.get("graphics")):
        if isinstance(g, dict) and g.get("layer") in COURTYARD_LAYERS:
            pts.extend(_graphic_local_points(g))
    return pts


def _pad_extent_local_points(comp: dict) -> list[tuple[float, float]]:
    """Corner points of every pad land, component-LOCAL, from whichever pad
    census the component carries — resolved ``pads`` (position/size dicts,
    resolve._pads_from_parsed's shape) first, inline ``pins`` (x_mm/y_mm +
    pad_width_mm/pad_height_mm/annulus_diameter_mm/drill_mm) otherwise. A pad
    with no usable size contributes its center alone — an honest point, never
    an invented land."""
    pts: list[tuple[float, float]] = []
    pads = _list(comp.get("pads"))
    if pads:
        for pad in pads:
            if not isinstance(pad, dict):
                continue
            pos = pad.get("position") if isinstance(pad.get("position"), dict) else {}
            x, y = _num(pos.get("x")), _num(pos.get("y"))
            if x is None or y is None:
                continue
            size = pad.get("size") if isinstance(pad.get("size"), dict) else {}
            drill = pad.get("drill") if isinstance(pad.get("drill"), dict) else {}
            w = _num(size.get("width")) or _num(drill.get("x")) or 0.0
            h = _num(size.get("height")) or _num(drill.get("y")) or 0.0
            pts.extend([(x - w / 2, y - h / 2), (x + w / 2, y + h / 2)])
        return pts
    for pin in _list(comp.get("pins")):
        if not isinstance(pin, dict):
            continue
        x, y = _num(pin.get("x_mm")), _num(pin.get("y_mm"))
        if x is None or y is None:
            continue
        ring = _num(pin.get("annulus_diameter_mm")) or _num(pin.get("drill_mm")) or 0.0
        w = _num(pin.get("pad_width_mm")) or ring
        h = _num(pin.get("pad_height_mm")) or ring
        pts.extend([(x - w / 2, y - h / 2), (x + w / 2, y + h / 2)])
    return pts


def _placed_bbox(comp: dict) \
        -> tuple[Optional[tuple[float, float, float, float]], Optional[str],
                 Optional[str]]:
    """(board-space bbox (minx, miny, maxx, maxy), basis, reason).

    Exactly one side is populated: a measurable component returns
    ``(bbox, basis, None)``; an unmeasurable one returns ``(None, None,
    reason)`` where reason is the tri-state indeterminate vocabulary (work
    item 019fd5fddc09) — ``"no_position"`` (x_mm/y_mm absent or non-finite)
    or ``"no_geometry"`` (no courtyard graphics AND no pad geometry).

    Courtyard basis when captured graphics exist; pad_extent (+margin)
    otherwise. Local points are rotated THEN bboxed — bboxing first and
    rotating the box would inflate a rotated part's claim beyond even bbox
    coarseness."""
    cx, cy = _num(comp.get("x_mm")), _num(comp.get("y_mm"))
    if cx is None or cy is None:
        return None, None, "no_position"
    rot = _num(comp.get("rotation_deg")) or 0.0

    local = _courtyard_local_points(comp)
    basis = "courtyard"
    margin = 0.0
    if not local:
        local = _pad_extent_local_points(comp)
        basis = "pad_extent"
        margin = PAD_EXTENT_MARGIN_MM
    if not local:
        return None, None, "no_geometry"

    xs: list[float] = []
    ys: list[float] = []
    for lx, ly in local:
        ox, oy = _rotate(lx, ly, rot)
        xs.append(cx + ox)
        ys.append(cy + oy)
    return ((min(xs) - margin, min(ys) - margin,
             max(xs) + margin, max(ys) + margin), basis, None)


def _component_side(comp: dict) -> str:
    """"top"/"bottom" for pairing purposes. Advisory-grade: an absent or
    unrecognized layer reads as "top" HERE ONLY — this module never places
    copper, so the fail-closed side resolution the router rightly demands
    (route_bridge.UnresolvableComponentLayer) would be the wrong trade; a
    dropped component is a silent advisory, which is the failure F3 exists to
    remove. geometry.is_top raises on named non-fabricable layers (its own
    fail-closed contract); that too degrades to "top" here, for the same
    reason."""
    try:
        return "top" if _is_top(comp.get("layer")) else "bottom"
    except ValueError:
        return "top"


def assembly_check(board: dict) -> dict:
    """Tri-state assembly check — the module's PUBLIC entry (019fd5fddc09).

    Returns ``{"status": "pass"|"findings"|"indeterminate",
    "findings": [<advisory dict>, ...], "indeterminate": [{component,
    reason}, ...]}`` — the ``indeterminate`` key is ABSENT when empty (the
    module absent-key convention), and a fault inside the pass comes back as
    ``{"status": "indeterminate", "findings": [], "error": str}`` — a hard
    fault is NEVER a silent pass and NEVER an unstructured raise (an advisory
    pass must not sink the reply it rides on).

    Each finding keeps the pre-tri-state advisory shape exactly::

        {"components": [refA, refB],        # sorted pair
         "overlap_mm2": float,              # bbox-intersection area
         "bbox": [minx, miny, maxx, maxy],  # the intersection box, board mm
         "basis": "courtyard"|"pad_extent"|"mixed",  # joint basis
         "bases": [basisA, basisB],         # per component, aligned to refs
         "side": "top"|"bottom",
         "severity": "advisory"}

    Each indeterminate entry names the component this pass could NOT measure
    and why — ``{"component": ref, "reason": "no_position"|"no_geometry"|
    "not_a_component"}``. A list entry that is not a dict, or that carries no
    usable ``ref``, is named positionally (``components[i]``) — an honest
    handle beats dropping the fact that something on the board went unjudged.

    Deterministic: findings are compared in ref order and indeterminate
    entries ride in component-list order, so the same board always yields the
    same dict. Never raises on malformed component data (module note)."""
    try:
        return _assembly_check_measured(board)
    except Exception as exc:  # noqa: BLE001 - fault -> indeterminate, never a raise
        # The guarantee half of "never an unstructured exception": whatever a
        # malformed board finds that the tolerant helpers above did not
        # anticipate, the caller still receives the tri-state shape — and
        # NEVER a "pass" it could mistake for a measured all-clear.
        return {"status": "indeterminate", "findings": [], "error": str(exc)}


def _assembly_check_measured(board: dict) -> dict:
    """The measurement pass behind :func:`assembly_check` (may raise; the
    public entry owns the fault->indeterminate boundary)."""
    comps = board.get("components") if isinstance(board, dict) else None
    if not isinstance(comps, list):
        comps = []

    placed: list[tuple[str, str, tuple, str]] = []
    indeterminate: list[dict] = []
    for idx, comp in enumerate(comps):
        # Tri-state accounting (019fd5fddc09): every list entry ends up in
        # exactly one of `placed` or `indeterminate` — the accounting-identity
        # discipline F1 established for spans, applied to components.
        if not isinstance(comp, dict):
            indeterminate.append({"component": f"components[{idx}]",
                                  "reason": "not_a_component"})
            continue
        ref = comp.get("ref")
        name = ref if isinstance(ref, str) and ref else f"components[{idx}]"
        bbox, basis, reason = _placed_bbox(comp)
        if bbox is None:
            indeterminate.append({"component": name, "reason": reason})
            continue
        placed.append((name, _component_side(comp), bbox, basis))
    placed.sort(key=lambda entry: entry[0])

    advisories: list[dict] = []
    for i in range(len(placed)):
        ref_a, side_a, box_a, basis_a = placed[i]
        for j in range(i + 1, len(placed)):
            ref_b, side_b, box_b, basis_b = placed[j]
            if side_a != side_b:
                continue  # opposite sides cannot collide as bodies
            minx = max(box_a[0], box_b[0])
            miny = max(box_a[1], box_b[1])
            maxx = min(box_a[2], box_b[2])
            maxy = min(box_a[3], box_b[3])
            if maxx <= minx or maxy <= miny:
                continue
            area = (maxx - minx) * (maxy - miny)
            if area <= MIN_OVERLAP_MM2:
                continue
            advisories.append({
                "components": [ref_a, ref_b],
                "overlap_mm2": round(area, 4),
                "bbox": [round(minx, 3), round(miny, 3),
                         round(maxx, 3), round(maxy, 3)],
                "basis": basis_a if basis_a == basis_b else "mixed",
                "bases": [basis_a, basis_b],
                "side": side_a,
                "severity": "advisory",
            })

    # Findings WIN the status (a found collision is actionable no matter what
    # else went unmeasured); indeterminate entries still travel beside them.
    if advisories:
        status = "findings"
    elif indeterminate:
        status = "indeterminate"
    else:
        status = "pass"
    out: dict = {"status": status, "findings": advisories}
    if indeterminate:
        out["indeterminate"] = indeterminate
    return out
