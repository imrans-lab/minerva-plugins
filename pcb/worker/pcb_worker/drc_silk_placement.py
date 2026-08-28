"""Legend that will be UNREADABLE on the assembled board.

GC9's two shipped rules measure legend the way a fab does — is the stroke wide
enough to print, does it contaminate a solderable surface. Both can pass on a
board whose silkscreen is useless to the human holding it, because neither asks
the question an assembler asks: *can I still see it once the parts are on*.

TWO WAYS LEGEND STOPS BEING LEGEND:

  UNDER A PART (``gc9_silk_under_part``). Ink printed where a component body
  will sit is gone the moment that component is soldered. Two shapes of it:

    * any silk stroke inside a FOREIGN component's envelope — its declared
      courtyard, or, for a footprint that declares none, the body it draws; and
    * a DESIGNATOR stroke inside its OWN component's body/pad extent.

    A footprint's OWN body-outline silk sitting inside its OWN courtyard is
    NOT a finding and never can be: that IS the footprint convention (the
    courtyard is drawn around the outline by definition), and reporting it
    would fire on every part on every board. The own-component arm therefore
    measures against the BODY box, which excludes the courtyard, and only for
    the synthesized designator — the one piece of legend nobody authored and
    the only one this stack can move.

  OVER OTHER LEGEND (``gc9_silk_over_silk``). Two strokes printed on top of
  each other are one illegible blot. Scoped to pairs involving a DESIGNATOR,
  because that is the collision this stack can act on: a designator crossing
  another part's designator, another part's outline, or board-level silk text.
  Two authored footprint graphics overlapping is the footprint author's
  business and there is no anchor to move.

ADVISORY, like the rest of the GC9 family, and for the same ratified reason:
silk is cosmetic (``fab_capability``'s output-criticality rule), so these rows
are reported and counted but never move the verdict. Unlike the other two GC9
rules they are NOT gated on a manufacturer floor — no fab publishes "legend
must be legible", and the geometry is decided by placement rather than by
process capability.

EVERY ROW CARRIES A SUGGESTION for the designators, because a finding an agent
cannot act on is a complaint. The suggestion is the first COMPASS SLOT around
the part — N, S, E, W, then the diagonals — at the footprint's own derived
default offset, that clears both rules above AND the existing silk-to-pad
clearance. When no slot clears, the suggestion is ``hidden: true`` and the row
says so: a designator printed nowhere readable is worse than one not printed,
because it is ink the fab charges for and the assembler mis-reads.

WHY THE SLOTS ARE THE DERIVED DEFAULT, TURNED. ``refdes_anchor`` derives the
default anchor as "centred just above the occupied extent, one CLEARANCE_MM
gap clear of it". The N slot here reproduces that number exactly (same extent,
same gap, same half-stroke inset); the other seven are the same construction
rotated around the box. So the suggestion is never a new rule — it is the one
existing rule applied on a side that happens to be free.

MEASUREMENT. "Overlap" is reported as the length of the stroke's CENTRELINE
that lies inside the offending shape, sampled at :data:`SAMPLE_STEP_MM`. The
centreline (rather than the swept ink) is deliberate: a stroke that merely
grazes a courtyard edge measures ~0 and is not reported, which is the right
answer for a rule about ink DISAPPEARING rather than about clearance. The
sampling quantum is the reported resolution, and a pair the exact kernel says
overlaps is never reported as 0 — it floors at one step.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Any, Iterable, Sequence

from agent_router.layers import kicad_to_canon

from . import refdes_anchor, silk_source
from .board_font import text_width
from .drc_geom_primitives import (
    AABB,
    EPS,
    Capsule,
    capsule_edge_distance,
    convex_edge_distance,
    point_segment_distance,
)
from .footprint_def import ReferenceTextDefinition
from .geometry import PlacementTransform
from .resolved_board import Side

#: The two row types this module emits. Members of GC9's advisory family (see
#: ``drc_geometric.GC9_ADVISORY_TYPES``), which is what keeps them out of the
#: blocking verdict.
SILK_UNDER_PART = "gc9_silk_under_part"
SILK_OVER_SILK = "gc9_silk_over_silk"
ADVISORY_TYPES: frozenset[str] = frozenset({SILK_UNDER_PART, SILK_OVER_SILK})

#: Centreline sampling pitch for the reported overlap length, mm. Fine enough
#: that a right-angle crossing of two 0.15 mm strokes still measures three
#: samples, coarse enough that a whole board's legend is walked in one pass.
SAMPLE_STEP_MM = 0.05

#: The compass slots a suggestion is searched through, in order. Cardinals
#: first because a designator beside or above its part reads naturally; the
#: diagonals are the fallback for a part hemmed in on its four sides.
SLOT_ORDER: tuple[str, ...] = ("N", "S", "E", "W", "NE", "NW", "SE", "SW")

#: Grid pitch of the broad-phase bucket used to pair silk with silk, mm. Sized
#: at roughly one designator's height: small enough that a cell holds a handful
#: of strokes on a dense board, large enough that one stroke rarely spans more
#: than a few cells.
_BUCKET_MM = 2.0


# ---------------------------------------------------------------------------
# Silk primitives as swept bodies
# ---------------------------------------------------------------------------


def silk_capsules(prim: Any) -> tuple[Capsule, ...]:
    """One silk primitive as swept-segment capsules, in the board frame.

    Silk is DRAWN geometry — every primitive is a stroked path, so its physical
    extent is the centreline swept by half the stroke width. That is exactly a
    Capsule, which is why no new primitive is needed here (contrast GC8, where
    mask apertures are filled regions and a roundrect needed exact modelling).

    A CIRCLE and an ARC are approximated by an inscribed polyline, and the
    approximation direction is chosen deliberately: chord midpoints sit INSIDE
    the true curve, so the polyline under-states how far the stroke reaches
    outward. For a silk-to-pad clearance that makes the measured distance
    LARGER than the truth — the wrong way for fail-safety. The segment count is
    therefore chosen so the sagitta (max radial error) stays under a tenth of
    the stroke half-width, and the capsule radius is then inflated by that
    residual, so the modelled body always CONTAINS the true stroke.

    Lives here rather than in ``drc_geometric`` because both the silk DFM check
    and this one need it and the dependency runs one way: this module knows
    nothing about the geometric-DRC kernel, and the kernel imports it.
    """
    half = prim.width_mm / 2.0
    geom = prim.geometry

    if isinstance(geom, silk_source.SilkLine):
        return (Capsule(geom.x1, geom.y1, geom.x2, geom.y2, half),)

    if isinstance(geom, silk_source.SilkPoly):
        pts = list(geom.points)
        if len(pts) < 2:
            return (Capsule(pts[0][0], pts[0][1], pts[0][0], pts[0][1], half),) if pts else ()
        pairs = list(zip(pts, pts[1:]))
        if geom.closed and len(pts) > 2:
            pairs.append((pts[-1], pts[0]))
        return tuple(Capsule(a[0], a[1], b[0], b[1], half) for a, b in pairs)

    # Circle / arc -> polyline. Both carry a centre and a radius; an arc also
    # carries a sweep, and a circle is the full-turn case.
    if isinstance(geom, silk_source.SilkCircle):
        cx, cy, radius = geom.cx, geom.cy, geom.radius
        start_ang, sweep = 0.0, 2.0 * math.pi
    else:
        cx, cy = geom.center
        radius = math.hypot(geom.start[0] - cx, geom.start[1] - cy)
        start_ang = math.atan2(geom.start[1] - cy, geom.start[0] - cx)
        end_ang = math.atan2(geom.end[1] - cy, geom.end[0] - cx)
        sweep = end_ang - start_ang
        # Orientation "+" is counter-clockwise in the board frame; normalise the
        # sweep into that direction so a wrap does not silently become a tiny arc.
        if geom.orientation == "+":
            while sweep <= 0:
                sweep += 2.0 * math.pi
        else:
            while sweep >= 0:
                sweep -= 2.0 * math.pi

    if radius <= EPS:
        return (Capsule(cx, cy, cx, cy, half),)

    # sagitta = r * (1 - cos(step/2)); solve for step given the error budget.
    budget = max(half * 0.1, EPS)
    if budget >= radius:
        segments = 4
    else:
        step = 2.0 * math.acos(max(-1.0, min(1.0, 1.0 - budget / radius)))
        segments = max(4, int(math.ceil(abs(sweep) / step)))
    step = sweep / segments
    residual = radius * (1.0 - math.cos(abs(step) / 2.0))

    caps = []
    for i in range(segments):
        a0, a1 = start_ang + i * step, start_ang + (i + 1) * step
        caps.append(Capsule(
            cx + radius * math.cos(a0), cy + radius * math.sin(a0),
            cx + radius * math.cos(a1), cy + radius * math.sin(a1),
            half + residual))
    return tuple(caps)


# ---------------------------------------------------------------------------
# What a part covers, in the board frame
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class _Envelope:
    """A part's footprint on the board as a TURNED RECTANGLE.

    Built by putting the four corners of a footprint-LOCAL extent box through
    the component's own placement transform, so it rotates and mirrors with the
    part exactly as its artwork does. A box rather than the courtyard's true
    outline: courtyards are rectangles in all but a handful of footprints, the
    box always CONTAINS the real envelope (never under-states what a part
    covers), and the alternative is a second polygon reader for a cosmetic row.
    """

    component_id: str
    ref: str
    side: Side
    corners: tuple[tuple[float, float], ...]
    box: AABB

    def contains(self, x: float, y: float) -> bool:
        if not (self.box.min_x - EPS <= x <= self.box.max_x + EPS
                and self.box.min_y - EPS <= y <= self.box.max_y + EPS):
            return False
        return _point_in_quad(self.corners, x, y)


def _point_in_quad(corners: Sequence[tuple[float, float]],
                   px: float, py: float) -> bool:
    """Containment in a convex quad given in ring order; a point on an edge is
    inside, because ink on the boundary of a body is still under the part."""
    sign = 0
    n = len(corners)
    for i in range(n):
        x1, y1 = corners[i]
        x2, y2 = corners[(i + 1) % n]
        cross = (x2 - x1) * (py - y1) - (y2 - y1) * (px - x1)
        if cross > EPS:
            if sign < 0:
                return False
            sign = 1
        elif cross < -EPS:
            if sign > 0:
                return False
            sign = -1
    return True


def _placed_envelope(comp: Any, extent: Any) -> "_Envelope | None":
    """One footprint-local extent box, placed. None for a part with no box."""
    if extent is None:
        return None
    placement = comp.placement
    transform = PlacementTransform(position=tuple(placement.position),
                                   rotation_deg=float(placement.rotation_deg),
                                   side=placement.side)
    corners = tuple(transform.point(pt) for pt in (
        (extent.min_x, extent.min_y), (extent.max_x, extent.min_y),
        (extent.max_x, extent.max_y), (extent.min_x, extent.max_y)))
    xs = [p[0] for p in corners]
    ys = [p[1] for p in corners]
    return _Envelope(component_id=comp.id, ref=comp.ref, side=placement.side,
                     corners=corners,
                     box=AABB(min(xs), min(ys), max(xs), max(ys)))


def _keepout_envelopes(rb: Any) -> list[_Envelope]:
    """Every component's KEEP-OUT envelope: its courtyard, else the body it
    draws. The fallback matters — a footprint that declares no courtyard still
    hides whatever is printed under it, and skipping those parts would make the
    rule silently narrower on exactly the sloppier libraries where it is most
    needed."""
    out: list[_Envelope] = []
    for comp in rb.components:
        definition = rb.footprint_for(comp)
        extent = (refdes_anchor.courtyard_extent_from_definition(definition)
                  or refdes_anchor.body_extent_from_definition(definition))
        envelope = _placed_envelope(comp, extent)
        if envelope is not None:
            out.append(envelope)
    return out


def _body_envelopes(rb: Any) -> dict[str, _Envelope]:
    """Each component's own BODY box — outline plus lands, courtyard excluded.
    Keyed by component id; a part that draws no outline and has no sized land
    is absent, and its designator is then judged only against its neighbours."""
    out: dict[str, _Envelope] = {}
    for comp in rb.components:
        envelope = _placed_envelope(
            comp, refdes_anchor.body_extent_from_definition(rb.footprint_for(comp)))
        if envelope is not None:
            out[comp.id] = envelope
    return out


# ---------------------------------------------------------------------------
# Overlap measurement
# ---------------------------------------------------------------------------


def _covered_length(caps: Sequence[Capsule], inside) -> tuple[float, tuple[float, float] | None]:
    """(length of centreline satisfying *inside*, one witness point on it)."""
    covered = 0.0
    witness: tuple[float, float] | None = None
    for cap in caps:
        length = math.hypot(cap.bx - cap.ax, cap.by - cap.ay)
        steps = max(1, int(math.ceil(length / SAMPLE_STEP_MM)))
        step_len = length / steps
        for i in range(steps + 1):
            t = i / steps
            px = cap.ax + (cap.bx - cap.ax) * t
            py = cap.ay + (cap.by - cap.ay) * t
            if inside(px, py):
                covered += step_len
                if witness is None:
                    witness = (px, py)
    return covered, witness


def _caps_overlap(a: Sequence[Capsule], b: Sequence[Capsule]) -> bool:
    """Exact swept-body contact between two silk primitives. Used for DETECTION
    so a glancing crossing is never lost to the sampling grid; the length is
    then measured by sampling and floored at one step."""
    for c1 in a:
        for c2 in b:
            if capsule_edge_distance(c1, c2) <= EPS:
                return True
    return False


def _caps_box(caps: Sequence[Capsule]) -> AABB:
    boxes = [c.aabb() for c in caps]
    return AABB(min(b.min_x for b in boxes), min(b.min_y for b in boxes),
                max(b.max_x for b in boxes), max(b.max_y for b in boxes))


def _boxes_touch(a: AABB, b: AABB, slack: float = 0.0) -> bool:
    return not (a.max_x + slack < b.min_x or b.max_x + slack < a.min_x
                or a.max_y + slack < b.min_y or b.max_y + slack < a.min_y)


# ---------------------------------------------------------------------------
# The check
# ---------------------------------------------------------------------------


def _source_id(prim: Any) -> str:
    """The id a FINDING is grouped under.

    A designator arrives as one primitive per glyph stroke, so grouping by the
    primitive's own entity id would report the same collision a dozen times —
    once per stroke of "U12". Every stroke of one designator therefore folds
    onto its component's designator id, while an authored graphic keeps its own
    entity id (one graphic really is one piece of artwork)."""
    if prim.origin == "refdes":
        return f"{prim.parent_id}:refdes"
    return prim.entity_id


def _origin_word(origin: str) -> str:
    return {"refdes": "designator", "graphic": "footprint graphic",
            "board_graphic": "board graphic"}.get(origin, origin)


def _layer_of(side: Side) -> str:
    return "F.SilkS" if side is Side.TOP else "B.SilkS"


def _row(row_type: str, prim: Any, offender_id: str, offender_kind: str,
         offender_ref: str | None, overlap_mm: float,
         witness: tuple[float, float], note: str) -> dict:
    """One advisory row. Built explicitly rather than through
    ``drc_geometric._finding`` so this module keeps its one-way dependency on
    the kernel — and because the row carries fields (`origin`, `offender`,
    `suggestion`) that finding shape has no place for. The measured/required
    pair still reads the way every other row does: measured is the millimetres
    of legend lost, required is zero."""
    return {
        "type": row_type,
        "entity_id": f"{_source_id(prim)}|{offender_id}",
        "parent": prim.parent_id,
        "kind": "silk",
        "net_id": None,
        "layer": _layer_of(prim.side),
        "ref": prim.ref,
        "pad": None,
        "net_name": None,
        "measured_mm": round(overlap_mm, 6),
        "required_mm": 0.0,
        "closest": [round(witness[0], 6), round(witness[1], 6)],
        "witness": [round(witness[0], 6), round(witness[1], 6)],
        "origin": prim.origin,
        "origin_label": _origin_word(prim.origin),
        "side": prim.side.value,
        "offender": offender_id,
        "offender_kind": offender_kind,
        "offender_ref": offender_ref,
        # Filled in by _attach_suggestions for designator rows; None on a row
        # whose legend this stack cannot move (an authored footprint graphic or
        # board artwork — the fix there is to move the part or edit the
        # footprint, and inventing an anchor for it would be a lie).
        "suggestion": None,
        "note": note,
    }


def check(proj: Any, rb: Any) -> list[dict]:
    """The two placement advisories over an already-built projection.

    Takes the SAME ``Projection.silk`` the emitter's own harvest produced (see
    ``drc_geometric._project_silk``), so what is judged here is what the fab
    will print — the whole reason the silk projection exists.
    """
    keepouts = _keepout_envelopes(rb)
    bodies = _body_envelopes(rb)
    caps_by_prim = {id(p): silk_capsules(p) for p in proj.silk}

    rows: list[dict] = []
    rows += _under_part_rows(proj, keepouts, bodies, caps_by_prim)
    rows += _over_silk_rows(proj, caps_by_prim)
    _attach_suggestions(rows, proj, rb, keepouts, bodies, caps_by_prim)
    # Deterministic order: two runs over one board must produce byte-identical
    # results, and dict iteration over primitives is only incidentally stable.
    rows.sort(key=lambda r: (r["type"], r["entity_id"]))
    return rows


def _under_part_rows(proj: Any, keepouts: Sequence[_Envelope],
                     bodies: dict[str, _Envelope], caps_by_prim: dict) -> list[dict]:
    # (source, offender) -> [overlap_mm, witness, prim]. Accumulated rather than
    # emitted per primitive: one designator is a dozen strokes and one row.
    acc: dict[tuple[str, str], list] = {}

    def note(prim, offender_id, kind_word):
        return (f"{_origin_word(prim.origin)} legend is printed inside "
                f"{kind_word} — it disappears when {offender_id} is assembled")

    for prim in proj.silk:
        caps = caps_by_prim[id(prim)]
        if not caps:
            continue
        box = _caps_box(caps)
        for envelope in keepouts:
            if envelope.component_id == prim.parent_id:
                # The part's OWN envelope. Its outline lives inside its own
                # courtyard by construction, and its designator is judged
                # against the BODY box below instead.
                continue
            if envelope.side is not prim.side or not _boxes_touch(box, envelope.box):
                continue
            overlap, witness = _covered_length(caps, envelope.contains)
            if witness is None:
                continue
            _accumulate(acc, prim, envelope.component_id, "courtyard",
                        envelope.ref, overlap, witness,
                        note(prim, envelope.ref, f"{envelope.ref}'s keep-out envelope"))

        if prim.origin != "refdes":
            continue
        own = bodies.get(prim.parent_id)
        if own is None or own.side is not prim.side or not _boxes_touch(box, own.box):
            continue
        overlap, witness = _covered_length(caps, own.contains)
        if witness is None:
            continue
        _accumulate(acc, prim, own.component_id, "own_body", own.ref,
                    overlap, witness,
                    f"designator is printed inside {own.ref}'s own body/pad "
                    f"extent — it disappears under the part it names")

    return [_row(SILK_UNDER_PART, entry[2], offender, entry[3], entry[4],
                 entry[0], entry[1], entry[5])
            for (_, offender), entry in acc.items()]


def _accumulate(acc: dict, prim: Any, offender_id: str, offender_kind: str,
                offender_ref: str | None, overlap: float,
                witness: tuple[float, float], note: str) -> None:
    key = (_source_id(prim), offender_id)
    entry = acc.get(key)
    if entry is None:
        acc[key] = [overlap, witness, prim, offender_kind, offender_ref, note]
    else:
        entry[0] += overlap


def _over_silk_rows(proj: Any, caps_by_prim: dict) -> list[dict]:
    """Designator strokes crossing legend that belongs to somebody else.

    Broad-phased through a fixed grid rather than an all-pairs walk: a real
    board carries thousands of silk primitives and the quadratic walk over them
    is seconds of wall clock for a cosmetic advisory.
    """
    buckets: dict[tuple[int, int, str], list] = {}
    boxes: dict[int, AABB] = {}
    for prim in proj.silk:
        caps = caps_by_prim[id(prim)]
        if not caps:
            continue
        box = _caps_box(caps)
        boxes[id(prim)] = box
        for cell in _cells(box, prim.side):
            buckets.setdefault(cell, []).append(prim)

    acc: dict[tuple[str, str], list] = {}
    for prim in proj.silk:
        if prim.origin != "refdes":
            continue
        caps = caps_by_prim[id(prim)]
        if not caps:
            continue
        box = boxes[id(prim)]
        seen: set[int] = set()
        for cell in _cells(box, prim.side):
            for other in buckets.get(cell, ()):
                if id(other) in seen:
                    continue
                seen.add(id(other))
                # Same owner => same part's own artwork. A designator over its
                # own outline is the under-part rule's own-body arm, not a
                # collision between two parts' legend.
                if other.parent_id == prim.parent_id:
                    continue
                # ONE ROW PER CROSSING. Both halves of a designator-on-
                # designator crossing walk this loop (each is a refdes), so
                # without an ordering rule "U1 over U2" and "U2 over U1" would
                # both be reported for one blot. The pair is canonicalised on
                # source id; a designator over a GRAPHIC has only one walker
                # and needs no rule.
                if other.origin == "refdes" and _source_id(other) <= _source_id(prim):
                    continue
                other_caps = caps_by_prim[id(other)]
                if not _boxes_touch(box, boxes[id(other)]):
                    continue
                if not _caps_overlap(caps, other_caps):
                    continue
                overlap, witness = _covered_length(
                    caps, lambda x, y, oc=other_caps: _point_under(x, y, oc))
                if witness is None:
                    # The exact kernel says the ink touches but no centreline
                    # sample landed inside — a glancing crossing. Report it at
                    # the sampling floor rather than dropping it.
                    overlap, witness = SAMPLE_STEP_MM, (caps[0].ax, caps[0].ay)
                _accumulate(
                    acc, prim, _source_id(other), other.origin, other.ref,
                    max(overlap, SAMPLE_STEP_MM), witness,
                    f"designator crosses {_origin_word(other.origin)} legend"
                    + (f" belonging to {other.ref}" if other.ref else ""))

    return [_row(SILK_OVER_SILK, entry[2], offender, entry[3], entry[4],
                 entry[0], entry[1], entry[5])
            for (_, offender), entry in acc.items()]


def _point_under(px: float, py: float, caps: Sequence[Capsule]) -> bool:
    return any(point_segment_distance(px, py, c.ax, c.ay, c.bx, c.by) <= c.r + EPS
               for c in caps)


def _cells(box: AABB, side: Side) -> Iterable[tuple[int, int, str]]:
    x0 = int(math.floor(box.min_x / _BUCKET_MM))
    x1 = int(math.floor(box.max_x / _BUCKET_MM))
    y0 = int(math.floor(box.min_y / _BUCKET_MM))
    y1 = int(math.floor(box.max_y / _BUCKET_MM))
    for cx in range(x0, x1 + 1):
        for cy in range(y0, y1 + 1):
            yield (cx, cy, side.value)


# ---------------------------------------------------------------------------
# The suggestion
# ---------------------------------------------------------------------------


def _attach_suggestions(rows: list[dict], proj: Any, rb: Any,
                        keepouts: Sequence[_Envelope],
                        bodies: dict[str, _Envelope],
                        caps_by_prim: dict) -> None:
    """Give every DESIGNATOR row a place to move to.

    Computed once per component, not once per row: a designator buried under
    two neighbours produces two rows and has exactly one right answer.
    """
    components = {comp.id: comp for comp in rb.components}
    pads_by_side = _pads_by_side(proj)
    min_to_pad = rb.design_rules.minimums.min_silk_to_pad_mm
    # Foreign legend a moved designator must still clear: everything except the
    # strokes of the designator being moved.
    cache: dict[str, dict] = {}
    for row in rows:
        if row["origin"] != "refdes":
            continue
        comp = components.get(row["parent"])
        if comp is None:
            continue
        if comp.id not in cache:
            cache[comp.id] = _suggest(comp, rb, proj, keepouts, bodies,
                                      caps_by_prim, pads_by_side, min_to_pad)
        row["suggestion"] = dict(cache[comp.id])
        if row["suggestion"]["hidden"]:
            row["note"] += ("; no compass slot around the part is clear, so the "
                            "suggestion is to hide the designator rather than "
                            "print it where it cannot be read")


def _pads_by_side(proj: Any) -> dict[Side, list]:
    out: dict[Side, list] = {Side.TOP: [], Side.BOTTOM: []}
    for cp in proj.copper:
        if cp.kind not in ("smd_pad", "pth_pad"):
            continue
        canon = {kicad_to_canon(lid) for lid in cp.layers}
        if "top" in canon:
            out[Side.TOP].append(cp)
        if "bottom" in canon:
            out[Side.BOTTOM].append(cp)
    return out


def _slot_anchors(extent: Any, ref: str, size_mm: float) -> list[tuple[str, tuple[float, float]]]:
    """The eight candidate anchors, footprint-LOCAL, in :data:`SLOT_ORDER`.

    The designator's own ink box at ``size_mm`` is half a stroke wider than the
    glyph advance on every side (the strokes are swept, not hairlines), and the
    font grows capitals from the baseline UP — cap top at ``-size``, baseline at
    0 — which is why the north and south offsets are asymmetric.

    N reproduces ``refdes_anchor.default_anchor`` exactly: the box bottom is the
    half stroke below the baseline, so an anchor of
    ``extent.min_y - CLEARANCE_MM - half_stroke`` is the same number T1 derives.
    """
    gap = refdes_anchor.CLEARANCE_MM
    half_stroke = silk_source.SILK_TEXT_WIDTH_MM / 2.0
    half_w = text_width(ref, size_mm) / 2.0 + half_stroke
    top = size_mm + half_stroke          # box top above the baseline
    bottom = half_stroke                 # box bottom below the baseline
    north_y = extent.min_y - gap - bottom
    south_y = extent.max_y + gap + top
    east_x = extent.max_x + gap + half_w
    west_x = extent.min_x - gap - half_w
    mid_x = extent.center_x
    mid_y = extent.center_y + (top - bottom) / 2.0
    by_slot = {
        "N": (mid_x, north_y), "S": (mid_x, south_y),
        "E": (east_x, mid_y), "W": (west_x, mid_y),
        "NE": (east_x, north_y), "NW": (west_x, north_y),
        "SE": (east_x, south_y), "SW": (west_x, south_y),
    }
    return [(slot, by_slot[slot]) for slot in SLOT_ORDER]


def _suggest(comp: Any, rb: Any, proj: Any, keepouts: Sequence[_Envelope],
             bodies: dict[str, _Envelope], caps_by_prim: dict,
             pads_by_side: dict[Side, list], min_to_pad: float | None) -> dict:
    """The first clear compass slot for one component's designator, or hidden.

    "Clear" means all three rules at once — no keep-out envelope (its own body
    included), no foreign legend, and the silk-to-pad floor the profile
    published, if it published one. Checking fewer would hand back a suggestion
    that trades one advisory for another.
    """
    definition = rb.footprint_for(comp)
    extent = refdes_anchor.occupied_extent_from_definition(definition)
    # The component's EFFECTIVE placement, not the footprint's raw fp_text: a
    # suggestion must keep the size and rotation the designator is ACTUALLY
    # printed at, or taking it silently resizes a label the board authored.
    in_force = comp.refdes
    size = in_force.size_mm if in_force is not None else silk_source.REFDES_TEXT_SIZE_MM
    rotation = in_force.rotation_deg if in_force is not None else 0.0
    hidden = {"x_mm": 0.0, "y_mm": 0.0, "rotation_deg": rotation,
              "size_mm": size, "hidden": True, "slot": None}
    if extent is None:
        # No body to measure means no slots to measure from. Hiding is the only
        # honest answer this rule can give.
        return hidden

    side = comp.placement.side
    pads = pads_by_side[side]
    # Foreign legend, pre-filtered once: everything not owned by this component.
    others = [(p, caps_by_prim[id(p)]) for p in proj.silk
              if p.parent_id != comp.id and p.side is side and caps_by_prim[id(p)]]
    envelopes = [e for e in keepouts if e.side is side and e.component_id != comp.id]
    own_body = bodies.get(comp.id)

    for slot, (ax, ay) in _slot_anchors(extent, comp.ref, size):
        strokes = silk_source.refdes_strokes(
            comp.ref, comp.placement.position[0], comp.placement.position[1],
            comp.placement.rotation_deg,
            ReferenceTextDefinition(position=(ax, ay), rotation_deg=rotation,
                                    size_mm=size, hidden=False),
            side)
        caps = [c for stroke in strokes
                for c in silk_capsules(_Stroke(stroke, silk_source.SILK_TEXT_WIDTH_MM))]
        if not caps:
            return hidden
        if _slot_is_clear(caps, envelopes, own_body, others, pads, min_to_pad):
            return {"x_mm": round(ax, 6), "y_mm": round(ay, 6),
                    "rotation_deg": rotation, "size_mm": size,
                    "hidden": False, "slot": slot}
    return hidden


@dataclass(frozen=True)
class _Stroke:
    """The two fields :func:`silk_capsules` reads, for a candidate stroke that
    is not (yet) a projected primitive."""

    geometry: Any
    width_mm: float


def _slot_is_clear(caps: Sequence[Capsule], envelopes: Sequence[_Envelope],
                   own_body: "_Envelope | None", others: Sequence[tuple[Any, Sequence[Capsule]]],
                   pads: Sequence[Any], min_to_pad: float | None) -> bool:
    box = _caps_box(caps)
    for envelope in envelopes:
        if _boxes_touch(box, envelope.box) and _covered_length(caps, envelope.contains)[1]:
            return False
    if own_body is not None and _boxes_touch(box, own_body.box) \
            and _covered_length(caps, own_body.contains)[1]:
        return False
    for other, other_caps in others:
        if _boxes_touch(box, _caps_box(other_caps)) and _caps_overlap(caps, other_caps):
            return False
    if min_to_pad is not None:
        for cp in pads:
            if not _boxes_touch(box, cp.aabb, min_to_pad):
                continue
            for cap in caps:
                # The SAME threshold predicate GC9's silk-to-pad rule uses
                # (drc_geometric._violates): at the floor passes, short of it
                # by more than float noise fails. A stricter test here would
                # reject slots the shipped rule calls clean.
                if convex_edge_distance(cap, cp.shape) < min_to_pad - EPS:
                    return False
    return True
