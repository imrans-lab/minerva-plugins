"""SOLID zone fill — turning an authored pour outline into fabricable copper.

WHAT THIS COMPUTES. For every ``ZoneKind.COPPER_POUR`` zone: the zone outline,
MINUS every foreign-net copper feature on that layer inflated by the applicable
clearance, MINUS every drilled hole inflated the same way, MINUS every keepout
that applies, clipped to the board edge. Same-net copper is NOT subtracted — the
pour merges flush into it (SOLID connect; see "NET ATTACHMENT" below). The
result is emitted as FRACTURED contours: one self-touching keyhole ring per
region, because the Gerber region primitive we emit through cannot express a
hole.

=== WHY INTEGER NANOMETRES ===

Every boolean here runs in integer nanometres (scale 1e6), never in float mm.
Three independent reasons, each measured rather than assumed:

  * It is the EMITTED precision exactly. gerber-writer self-selects
    ``%FSLAX36Y36`` — 6 decimals — for any board under ~1000 mm, so a nanometre
    IS the Gerber coordinate resolution. Computing finer would invent detail the
    file cannot carry; computing coarser would lose detail it can.
  * It makes the booleans EXACT. Clipper's integer kernel has no epsilon and no
    accumulated round-off, so byte-reproducibility of the fill is STRUCTURAL —
    a property of the arithmetic, not a property we hope holds and test for.
    (We test for it anyway; see tests/test_determinism_gate.py.)
  * It is the ORACLE'S OWN DOMAIN. KiCad's ZONE_FILLER is exact integer
    arithmetic and returns integer-nanometre coordinates, so oracle comparison
    needs no float tolerance to be meaningful.

Float booleans (shapely/GEOS) were rejected for this: they are not bit-stable
across library builds and platforms, and the gerber golden README already flags
version-sensitivity as a live hazard here.

=== NET ATTACHMENT: SOLID ONLY, AND THERMAL IS REFUSED ===

v1 connects same-net copper SOLID: the pour simply does not carve around it, so
pad and pour become one region. Thermal relief — spokes bridging a pad to the
pour across a gap — is NOT implemented.

This is not an oversight to be quietly tolerated. The board this exists for is
HAND-SOLDERED (``pcb/fab/coupon-001/SUBMISSION.md:186,196``), and a pad tied
solid into a large ground plane sinks the iron's heat into the whole pour, so
the joint never reaches reflow temperature: cold joints on exactly the ground
pins, worse the bigger the pour. Whether v1 ships solid or spokes is an OWNER
ruling (accumulator R-d) that has not been made.

Until it is, a board that AUTHORS ``thermal_gap_mm`` / ``thermal_bridge_width_mm``
is REFUSED with a named error rather than filled solid. Filling it solid would
silently discard an authored fabrication parameter and hand back a pour that
looks right and solders badly — precisely the failure class this campaign has
been closing. See :func:`_refuse_thermal`.

=== KEEPOUT SEMANTICS ===

A keepout SUBTRACTS from pours on its layer and emits no copper of its own. A
netless keepout subtracts from every pour; a net-scoped keepout (one naming a
net) subtracts only from pours of that net, mirroring the authored contract and
both validators.

Note what this does NOT do: a keepout also constrains ROUTING, and the routing
grid does not model it. That is why ``route_bridge`` still fails closed on a
keepout — subtracting it from a pour here does not make the board routable, and
must not be read as making it so.

=== FAIL-CLOSED ===

Every path that cannot produce copper we can stand behind raises
:class:`ZoneFillError` naming the zone. Never an approximation, never a silent
empty fill, never a partial result. The specific traps: an arc in a zone outline
(v1 has no arc discretisation policy the oracle would agree with), a
self-intersecting or degenerate outline, a fracture that does not reproduce the
unfractured area exactly, and authored thermal fields.

A pour whose fill is legitimately EMPTY (entirely covered by a keepout, say) is
NOT an error — it returns ``()``. That is a computed-and-empty pour, which is a
different fact from ``None`` (uncomputed), and the emitters distinguish them.

=== ISLANDS AND SLIVERS ARE REFUSED, NOT EMITTED AND NOT CULLED ===

A fill that breaks into a region overlapping no same-net copper (an ISLAND), or
into a region nowhere as wide as the profile's ``min_trace_width_mm`` (a
SLIVER), is REFUSED by name. Both used to be emitted in silence, recorded only
in this docstring and in three skipped tests — a skip reads as coverage in a
green tally, which is why they are now executable.

KiCad culls both instead, and the difference is not an oversight: it culls
against per-zone properties ITS schema has and ours does not (``min_thickness``,
``island_removal_mode``). Deleting the author's copper by a rule the author
never wrote is exactly the silent-damage class every other refusal here exists
to prevent. See :func:`_refuse_unfabricable_regions` for the measurement behind
this, for why it does not prejudge the thermal ruling, and for the one case it
deliberately does not catch (sub-floor necks inside an otherwise sound region,
which need an authored min-thickness).

=== KNOWN v1 GAPS (stated, not hidden) ===

  * ZONE MIN-THICKNESS IS NOT AUTHORABLE. ``ResolvedZone.min_thickness_mm``
    exists in the IR and is never populated, so the deflate/re-inflate opening
    KiCad performs — which sheds sub-thickness necks and rounds every convex
    corner — has no number to run at. Adding one is a board-schema change and
    needs the Go validator to agree, or validate and compile would disagree
    about a fabrication parameter.
  * POUR-TO-POUR PRIORITY. Two pours of different nets overlapping on one layer
    would both claim the overlap. ``priority`` is unpopulated, so there is no
    authored answer; the case is refused rather than resolved arbitrarily.
"""

from __future__ import annotations

from dataclasses import replace

from agent_router.layers import kicad_to_canon

from .drc_geom_primitives import Capsule, OrientedRect
from .ir_projection import outline_cutouts, profile_outer_rect
from .resolved_board import (
    ArcGeometry,
    LineGeometry,
    PolygonGeometry,
    ProfileOutline,
    RectOutline,
    ResolvedBoard,
    ResolvedZone,
    ZoneKind,
)

# --------------------------------------------------------------------------
# Quantisation
# --------------------------------------------------------------------------

NM_PER_MM = 1_000_000
"""Integer scale. 1e6 == the emitted Gerber coordinate resolution (%FSLAX36Y36)."""

ARC_TOLERANCE_NM = 5_000
"""Max deviation when a round join is flattened to segments: 0.005 mm.

Matched to KiCad's own ARC_HIGH_DEF so our clearance outlines and the oracle's
differ by approximation error rather than by policy. It MUST be set explicitly:
pyclipper's default arc tolerance is 0.25 in the active unit, which in the
nanometre domain means 0.25 nm — a quarter-nanometre-accurate circle, i.e. tens
of thousands of vertices per pad, in every Gerber.
"""

MITER_LIMIT = 2.0


def _to_nm(value_mm: float) -> int:
    """mm -> integer nanometres. ROUND-half-even, never truncate: truncation
    biases every coordinate toward the origin and turns a symmetric pad into an
    asymmetric one."""
    return int(round(value_mm * NM_PER_MM))


def _to_mm(value_nm: int) -> float:
    return value_nm / NM_PER_MM


class ZoneFillError(ValueError):
    """A pour that cannot be filled into copper we can stand behind.

    Carries ``zone_id`` so a caller can name the offending zone without parsing
    the message.
    """

    def __init__(self, zone_id: str, message: str) -> None:
        super().__init__(f"zone {zone_id!r}: {message}")
        self.zone_id = zone_id


def _pyclipper():
    """Import pyclipper, or fail with an actionable message.

    Imported lazily and locally so a worker that never fills a zone never pays
    for the native extension, and so a missing install surfaces as a named
    fabrication refusal rather than an ImportError at module load — the same
    treatment gerber-writer gets.
    """
    try:
        import pyclipper  # noqa: PLC0415  (deliberate lazy import)
    except ImportError as exc:  # pragma: no cover - install-time condition
        raise ZoneFillError(
            "<all>",
            "pyclipper is not installed; zone fill needs an exact integer "
            "polygon-boolean kernel and will not approximate one "
            f"(pip install 'pyclipper==1.4.0'): {exc}") from exc
    return pyclipper


# --------------------------------------------------------------------------
# Geometry -> integer-nm rings
# --------------------------------------------------------------------------


def _contour_ring(zone: ResolvedZone) -> list[tuple[int, int]]:
    """A zone's authored outline as a closed integer-nm ring.

    Refuses arcs: discretising one needs a chord-tolerance policy, and any
    policy we pick here is a policy the oracle did not pick, which turns an
    honest parity comparison into a comparison of two different curves.
    """
    ring: list[tuple[int, int]] = []
    for segment in zone.authored_outline.segments:
        if isinstance(segment, ArcGeometry):
            raise ZoneFillError(
                zone.id,
                "outline contains an arc; v1 fill has no arc-discretisation "
                "policy and will not invent one")
        if not isinstance(segment, LineGeometry):
            raise ZoneFillError(
                zone.id,
                f"outline contains an unsupported segment {type(segment).__name__}")
        ring.append((_to_nm(segment.a[0]), _to_nm(segment.a[1])))
    if len(ring) < 3:
        raise ZoneFillError(zone.id, f"outline collapses to {len(ring)} distinct point(s)")
    _refuse_self_intersecting(zone.id, ring)
    return ring


def _refuse_self_intersecting(zone_id: str, ring) -> None:
    """A self-intersecting outline has no single interior. Refuse it.

    FOUND BY A HAND-DERIVED TEST, not by reading the code. A bow-tie outline
    ((5,5) (15,15) (15,5) (5,15)) compiled cleanly and poured 47.88 mm^2 across
    three regions: Clipper had silently resolved the ambiguity with its own fill
    rule and handed back plausible-looking copper. Nothing raised.

    There is no right answer to pick. An even-odd reading of that bow-tie is two
    triangles (50 mm^2), a nonzero reading is one (25 mm^2), and the difference
    is REAL COPPER on a real board. The author wrote a shape whose interior they
    did not define; the fill rule is the compiler's convention, not their intent.
    Emitting either is inventing the answer.

    O(n^2) with exact integer orientation, which is affordable because zone
    outlines are tens of points, and exact because there is no epsilon: an outline
    that grazes itself to within a nanometre is caught, and one that does not is
    not.
    """
    edges = _edges(ring)
    count = len(edges)
    for i in range(count):
        for j in range(i + 2, count):
            if i == 0 and j == count - 1:
                continue  # first and last edges legitimately share a vertex
            a, b = edges[i]
            c, d = edges[j]
            if _crosses(a, b, c, d):
                raise ZoneFillError(
                    zone_id,
                    f"outline is SELF-INTERSECTING (segment {i} crosses segment "
                    f"{j}), so it has no unambiguous interior — a bow-tie fills to "
                    f"one area under an even-odd rule and another under a nonzero "
                    f"rule, and both are copper. Refusing to pick one")


def _segments_meet(a, b, c, d) -> bool:
    """True iff segments ab and cd share ANY point — proper crossing, a touch,
    or a collinear overlap. The STRICT sibling of :func:`_crosses`, which
    recognises proper crossings only.

    Both exist on purpose and neither is the other's bug fix. ``_crosses`` is
    right for the keyhole bridge, which legitimately TOUCHES the rings it joins
    at its endpoints and must only refuse a bridge passing THROUGH an edge.
    This one is right for asking "is this ring a simple polygon", where a touch
    is exactly as disqualifying as a crossing. Exact integer arithmetic — no
    epsilon, so a coordinate that meets is reported and one that misses by a
    nanometre is not.
    """
    d1, d2 = _orient2(c, d, a), _orient2(c, d, b)
    d3, d4 = _orient2(a, b, c), _orient2(a, b, d)
    if ((d1 > 0) != (d2 > 0)) and ((d3 > 0) != (d4 > 0)) and 0 not in (d1, d2, d3, d4):
        return True                                    # proper crossing
    def _within(p, q, r) -> bool:                      # r collinear with pq
        return (min(p[0], q[0]) <= r[0] <= max(p[0], q[0])
                and min(p[1], q[1]) <= r[1] <= max(p[1], q[1]))
    return ((d1 == 0 and _within(c, d, a)) or (d2 == 0 and _within(c, d, b))
            or (d3 == 0 and _within(a, b, c)) or (d4 == 0 and _within(a, b, d)))


def refuse_non_simple_ring(entity_id: str, ring, *,
                           error=None, label: str = "outline") -> None:
    """Refuse a ring that is not a SIMPLE polygon.

    Stricter than :func:`_refuse_self_intersecting` on three axes, each of
    which Codex review 1086 finding 1 reproduced as compiling and then being
    mishandled downstream:

      * a vertex TOUCHING a non-adjacent edge (no proper crossing occurs);
      * a COLLINEAR OVERLAP between non-adjacent edges;
      * a RETRACED edge — adjacent edges doubling back along the same line,
        a zero-area spur that has no interior at all.

    Plus zero-length edges, which nm quantisation can collapse a real-looking
    authored edge into.

    WHY CUTOUTS NEED THIS AND ZONES ARE LEFT ON THE OLDER CHECK (deliberate,
    not an oversight): a zone's ambiguous ring reaches Clipper, which resolves
    it by fill rule, and the resulting copper is still measured by GC7 and the
    pcbnew oracle — wrong, but CHECKED. A cutout's ring reaches
    ``route_bridge._cutout_obstacle``'s hand-rolled miter offset, whose
    correctness ASSUMES a simple polygon and which silently under-reserved the
    interior on a retraced ring; nothing downstream re-measures that. Zones
    carrying the same latent ambiguity is filed separately rather than widened
    into a repair round.

    O(n^2) exact-integer, affordable because an authored ring is tens of points.
    """
    err = error or (lambda msg: ZoneFillError(entity_id, msg))
    edges = _edges(ring)
    count = len(edges)

    for i, (a, b) in enumerate(edges):
        if a == b:
            raise err(f"{label} edge {i} has zero length at {a} — a real edge "
                      f"collapsed by nanometre quantisation, or a repeated point")

    for i in range(count):
        for j in range(i + 1, count):
            adjacent = (j == i + 1) or (i == 0 and j == count - 1)
            a, b = edges[i]
            c, d = edges[j]
            if adjacent:
                # Adjacent edges always meet at their shared vertex; the only
                # defect is doubling back along the same line (a spur).
                shared = b if b in (c, d) else a
                far_a = a if shared == b else b
                far_b = d if shared == c else c
                if _orient2(far_a, shared, far_b) == 0:
                    v1 = (shared[0] - far_a[0], shared[1] - far_a[1])
                    v2 = (far_b[0] - shared[0], far_b[1] - shared[1])
                    if v1[0] * v2[0] + v1[1] * v2[1] < 0:
                        raise err(
                            f"{label} RETRACES itself at {shared} (edges {i} and "
                            f"{j} double back along the same line), enclosing no "
                            f"area there — the region has no interior to cut")
                continue
            if _segments_meet(a, b, c, d):
                raise err(
                    f"{label} is NOT A SIMPLE POLYGON: segments {i} and {j} meet "
                    f"(crossing, touching, or overlapping), so the ring has no "
                    f"unambiguous interior. A shape whose inside is undefined "
                    f"cannot be offset, reserved, or milled")


def _capsule_ring(shape: Capsule) -> list[tuple[int, int]]:
    """A capsule's SEGMENT CORE as an integer-nm path.

    Only the core: the radius is folded into the offset distance by the caller,
    so a trace or a round pad is inflated exactly once, by (half-width +
    clearance), in a single Clipper offset with a round join. Building a stadium
    polygon first and offsetting THAT would flatten the same curve twice and
    double the approximation error.
    """
    a = (_to_nm(shape.ax), _to_nm(shape.ay))
    b = (_to_nm(shape.bx), _to_nm(shape.by))
    return [a] if a == b else [a, b]


def _rect_ring(shape: OrientedRect) -> list[tuple[int, int]]:
    return [(_to_nm(x), _to_nm(y)) for (x, y) in shape.corners()]


def _inflate(pc, paths_and_reach) -> list[list[tuple[int, int]]]:
    """Offset each (path, closed?, distance_nm) outward and union the lot.

    ROUND joins, always. A clearance is "every point at least d away", which is
    the Minkowski sum with a disc — a round join IS the definition, not a
    smoothing choice. A miter join would leave square corners on the void around
    a pad, which is both physically wrong and a visible disagreement with the
    oracle (measured: miter 315.000 mm^2 vs round 315.224 vs oracle 315.188 on
    the reference case).
    """
    out: list[list[tuple[int, int]]] = []
    for path, closed, distance in paths_and_reach:
        if distance <= 0:
            if closed:
                out.append(list(path))
            continue
        offset = pc.PyclipperOffset(MITER_LIMIT, ARC_TOLERANCE_NM)
        # ET_OPENROUND on an open path sweeps a disc along it, which is
        # exactly "everything within d of this segment" — the same set the
        # Capsule primitive defines. A single-point path degenerates to a disc,
        # which is how a round pad / via / drill arrives here.
        end_type = pc.ET_CLOSEDPOLYGON if closed else pc.ET_OPENROUND
        offset.AddPath(list(path), pc.JT_ROUND, end_type)
        out.extend(offset.Execute(distance))
    return out


# --------------------------------------------------------------------------
# Fracture
# --------------------------------------------------------------------------


def _ring_area2(ring) -> int:
    """TWICE the signed shoelace area of an integer ring, as an exact Python int.

    NOT ``pyclipper.Area``, and the reason is subtler than it first appears —
    this docstring said "the shoelace sum overflows 2**53" until that was
    actually measured and turned out to be false. Clipper accumulates carefully
    and a board-sized area is perfectly representable in a double.

    The real defect: ``Area()`` returns the SIGNED AREA — the shoelace sum
    HALVED — so any ring whose doubled area is ODD comes back as an exact
    ``x.5``. The fracture check then took ``int()`` of it per ring, discarding
    that half, and discarded a DIFFERENT NUMBER of halves on each side of its
    comparison: once per outer-and-hole ring before fracturing, once per
    fractured ring after. Measured: the two sides disagreed by exactly 1 nm^2 on
    a real pour and the compile failed with "fracturing changed the filled area",
    blaming a fracture bug that did not exist.

    Working in DOUBLED area and in Python ints removes the half entirely: there
    is nothing to round, at any board size, so the fracture verification is a
    true equality with one-square-nanometre resolution instead of a comparison
    carrying half a unit of hidden slack per contour. Pinned by
    tests/test_zone_seals.py::test_ring_area_is_exact_for_an_odd_doubled_area.
    """
    total = 0
    count = len(ring)
    for index in range(count):
        x0, y0 = ring[index]
        x1, y1 = ring[(index + 1) % count]
        total += x0 * y1 - x1 * y0
    return total


def _is_outer(ring) -> bool:
    """Positive (counter-clockwise) orientation == an outer contour, in Clipper's
    Y-down convention. Read off the exact integer area for the same reason."""
    return _ring_area2(ring) > 0


def _group_regions(pc, zone_id: str, solution):
    """Split a Clipper contour set into DISJOINT FILLED REGIONS.

    Returns ``(outers, {outer_index: [hole, ...]})``. Each outer ring plus the
    holes assigned to it is one physically separate piece of copper — the unit
    both the island check and the sliver check are stated over, and the unit
    :func:`_fracture` turns into one keyhole ring.

    Extracted so those three readers share ONE definition of "a region". They
    used to be the same six lines written twice, which is precisely how a check
    ends up grading a different set of shapes than the emitter emits.
    """
    outers = [list(p) for p in solution if _is_outer(p)]
    holes = [list(p) for p in solution if not _is_outer(p)]
    assigned: dict[int, list[list[tuple[int, int]]]] = {i: [] for i in range(len(outers))}
    if not outers:
        # Returned BEFORE the hole assignment below, which would otherwise raise
        # "a void inside no filled region" for every hole. Preserved exactly as
        # _fracture ordered it before this function was extracted: an empty
        # solution is an empty fill, not a malformed one.
        return outers, assigned
    # Assign each hole to the outer ring that contains it. A hole is inside
    # exactly one outer ring in a well-formed Clipper solution.
    for hole in holes:
        probe = hole[0]
        owner = None
        for index, outer in enumerate(outers):
            if pc.PointInPolygon(probe, outer) != 0:
                owner = index
                break
        if owner is None:
            raise ZoneFillError(
                zone_id,
                "fill produced a void that lies inside no filled region — the "
                "boolean result is not a well-formed polygon set")
        assigned[owner].append(hole)
    return outers, assigned


def _fracture(pc, zone_id: str, solution) -> list[list[tuple[int, int]]]:
    """Turn Clipper's (outer + hole) contour set into self-touching keyhole rings.

    THE EMITTER FORCES THIS. ``gerber_writer.DataLayer.add_region`` has no hole
    support at all — its ``negative=`` flag emits a %LPC layer-polarity command,
    which flips whether an object is dark or clear, and does not punch a void
    into another object. The one representation that expresses "copper with a
    window" in a single positive contour is the keyhole: walk the outer boundary
    to a vertex, cross a zero-width bridge to the hole, walk the hole all the way
    round, cross back, finish the outer boundary.

    This is also exactly what KiCad does — measured: a pour with one void comes
    back from ZONE_FILLER as ``OutlineCount()==1, HoleCount(0)==0`` with 67
    points, one fractured ring. Matching its representation means the oracle
    comparison is comparing copper, not comparing fracture policies.

    VERIFIED, NOT ASSUMED. A bridge is a straight line between two rings, and
    nothing about the nearest-vertex choice guarantees it will not cross a third
    ring on the way. So each fractured ring is re-simplified through Clipper and
    its area compared to the exact unfractured area. Any mismatch is a bad
    fracture and raises: the check is exact (integer domain, no tolerance), so it
    cannot pass a fracture that lost or double-counted area.
    """
    outers, assigned = _group_regions(pc, zone_id, solution)
    if not outers:
        return []

    # Doubled areas throughout — exact integers, never halved, never floats.
    expected = sum(_ring_area2(r) for r in outers)
    expected += sum(_ring_area2(h) for holes in assigned.values() for h in holes)

    rings: list[list[tuple[int, int]]] = []
    for index, outer in enumerate(outers):
        ring = list(outer)
        # Deterministic hole order: by the hole's own extreme vertex, so the
        # emitted ring never depends on Clipper's internal contour ordering (and
        # therefore neither do the emitted bytes).
        pending = sorted(assigned[index], key=lambda h: (min(h), len(h)))
        while pending:
            hole = pending.pop(0)
            # The holes NOT yet merged are obstacles too: a bridge that skewers a
            # void we are about to splice is just as wrong as one that skewers a
            # void already spliced.
            ring = _splice(zone_id, ring, hole, pending)
        rings.append(ring)

    _verify_fracture(pc, zone_id, rings, expected)
    return rings


def _orient2(a, b, c) -> int:
    """Exact integer orientation of (a, b, c): >0 left turn, <0 right, 0 collinear."""
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])


def _crosses(p1, p2, p3, p4) -> bool:
    """True iff segment p1p2 PROPERLY crosses segment p3p4.

    Proper crossing only: shared endpoints and collinear touching do NOT count. A
    keyhole bridge legitimately touches the rings it joins at its two endpoints,
    and the slit legitimately runs alongside itself; what must never happen is a
    bridge passing THROUGH an edge. Exact integer arithmetic, so there is no
    epsilon to tune and no near-miss that reads as a hit.
    """
    d1 = _orient2(p3, p4, p1)
    d2 = _orient2(p3, p4, p2)
    d3 = _orient2(p1, p2, p3)
    d4 = _orient2(p1, p2, p4)
    return ((d1 > 0) != (d2 > 0)) and ((d3 > 0) != (d4 > 0)) and 0 not in (d1, d2, d3, d4)


def _edges(ring):
    return [(ring[i], ring[(i + 1) % len(ring)]) for i in range(len(ring))]


def _clear(bridge_a, bridge_b, edge_sets) -> bool:
    """True iff the bridge crosses none of the given edges."""
    for edges in edge_sets:
        for (e1, e2) in edges:
            if _crosses(bridge_a, bridge_b, e1, e2):
                return False
    return True


def _splice(zone_id: str, outer: list, hole: list, obstacles) -> list:
    """Bridge ``hole`` into ``outer`` along a VISIBLE zero-width slit.

    NEAREST-VERTEX ALONE IS NOT ENOUGH, and this is not theoretical: the first
    implementation picked the closest vertex pair and, on a pour with five voids,
    ran a bridge straight through a neighbouring void. The area check caught it —
    but a filler that refuses every realistic board is not a filler.

    So candidates are tried in increasing distance order and the first one whose
    slit crosses NOTHING is taken: not the outer ring, not the hole being merged,
    not any hole still waiting to be merged. Nearest-first keeps the slit short
    (a long slit through open copper is ugly and, at zero width, pointless);
    the visibility test is what makes it correct.

    Exact integers throughout — the bridge lands on EXISTING vertices rather than
    on a computed edge intersection, so no coordinate is ever rounded into place
    and the fractured ring's area is exactly the unfractured area. (Bridging to a
    ray/edge intersection, which is how KiCad does it, would put a fractional
    point on an edge and lose that exactness.)
    """
    candidates = sorted(
        ((((outer[i][0] - hole[j][0]) ** 2 + (outer[i][1] - hole[j][1]) ** 2), i, j)
         for i in range(len(outer)) for j in range(len(hole))))
    obstacle_edges = [_edges(outer), _edges(hole)] + [_edges(h) for h in obstacles]
    for _, i, j in candidates:
        if _clear(outer[i], hole[j], obstacle_edges):
            # outer[..i] -> hole[j..] wrapping back to hole[j] -> outer[i..]
            return outer[:i + 1] + hole[j:] + hole[:j + 1] + outer[i:]
    raise ZoneFillError(
        zone_id,
        "no unobstructed path exists between a filled region and one of its "
        "voids, so the void cannot be expressed as a keyhole contour and the "
        "region cannot be emitted as a Gerber region")


def _verify_fracture(pc, zone_id: str, rings, expected: int) -> None:
    """Exact area re-check of the fractured rings. Fail closed on any mismatch."""
    simplified = pc.SimplifyPolygons([list(r) for r in rings], pc.PFT_NONZERO)
    got = sum(_ring_area2(p) for p in simplified)
    if got != expected:
        raise ZoneFillError(
            zone_id,
            f"fracturing changed the filled area ({got / 2} vs {expected / 2} nm^2) — "
            f"a keyhole bridge crossed geometry it should not have. Refusing to "
            f"emit copper whose shape we cannot account for")


# --------------------------------------------------------------------------
# Obstacles
# --------------------------------------------------------------------------


def _net_class_clearances(board: ResolvedBoard) -> dict[str, float]:
    """``net_id -> class min_clearance_mm`` for nets whose class names one."""
    class_by_id = {cls.id: cls for cls in board.design_rules.net_classes}
    out: dict[str, float] = {}
    for net in board.nets:
        cls = class_by_id.get(net.net_class_id)
        if cls is not None and cls.min_clearance_mm is not None:
            out[net.id] = cls.min_clearance_mm
    return out


def _clearance_mm(zone: ResolvedZone, board: ResolvedBoard,
                  class_clearance: dict[str, float],
                  other_net_id: str | None) -> float:
    """The gap this pour must leave around one foreign feature.

    THE MAXIMUM of three floors, because each is a floor and none may be
    undercut: the zone's own authored ``clearance_mm`` (or the board's blanket
    minimum when it defers), and either participating net's class minimum. Using
    only the zone's number would let a pour carve a 0.2 mm gap around copper on
    a net whose class demands 0.4 mm — copper that passes the filler and then
    FAILS the DRC that checks it. Same rule resolution the geometric DRC applies
    (``_effective_min_clearance``), so the fill obeys the rule it will be judged
    against.
    """
    floor = zone.clearance_mm
    if floor is None:
        floor = board.design_rules.minimums.min_clearance_mm
    for net_id in (zone.net_id, other_net_id):
        if net_id is not None and net_id in class_clearance:
            floor = max(floor, class_clearance[net_id])
    return floor


def _hole_clearance_mm(zone: ResolvedZone, board: ResolvedBoard,
                       class_clearance: dict[str, float], hole) -> float:
    """The gap this pour must leave around one DRILLED hole.

    The copper clearance from :func:`_clearance_mm`, raised to the profile's
    ``min_hole_to_copper_mm`` when it states one. MAXIMUM, never replacement:
    both are floors, and a hole that also carries foreign copper (a via) must
    still clear that copper by the copper rule.

    WHY A SEPARATE RULE AT ALL. Copper-to-copper clearance answers "how close may
    two potentials sit"; hole-to-copper answers "how far can the drill wander".
    They are different physical failures with different numbers, and a board
    house publishes them separately. Before this existed the pour carved every
    hole at the copper number, which on the reference fixture was 0.2 mm against
    KiCad's 0.25 mm — MEASURED as the single largest term in the oracle parity
    gap (0.4626 of 0.5487 mm^2), showing up as a 50.5 um annulus around one
    mounting hole. Not a geometry error on either side: it was the only rule our
    schema could state.

    APPLIED ONLY TO HOLES THE POUR ACTUALLY CARVES, which is why this is called
    after the same-net-plated skip above and not before it. Raising the gap on a
    same-net stitching via would reinstate the moat bug that skip exists to
    prevent — and there is nothing to protect there anyway: the barrel is the
    same net as the pour, so a drill that wanders into it shorts nothing.
    """
    gap = _clearance_mm(zone, board, class_clearance, hole.net_id)
    hole_to_copper = board.design_rules.minimums.min_hole_to_copper_mm
    if hole_to_copper is None:
        # The profile states no hole-to-copper rule. The copper clearance is then
        # the only floor our schema can name, which is what v1 has always done —
        # now as a stated fallback rather than an unexamined one.
        return gap
    return max(gap, hole_to_copper)


def _obstacle_paths(pc, zone: ResolvedZone, board: ResolvedBoard, projection,
                    class_clearance: dict[str, float]):
    """Every (path, closed?, offset_nm) this pour must carve around, on its layer.

    FOREIGN-NET copper only: same-net copper is what the pour connects TO, and
    v1 connects solid. Drilled holes are carved regardless of net — a drill
    through a pour removes copper whether or not the two share a potential, and
    an unplated mounting hole carries no net at all.
    """
    # TWO LAYER NAMESPACES, FOLDED ONTO ONE KEY — and getting this wrong is
    # SILENT. The copper stack ids a zone carries are canonical (`top`/`bottom`,
    # agent_router.layers.STACK_INDEX) while PlacedPad.layers carry KiCad ids
    # (`F.Cu`/`B.Cu`). A raw `zone.layer.id in prim.layers` test therefore never
    # matches ANYTHING: every obstacle is skipped, the pour fills its whole
    # outline, and nothing raises — a fail-open that emits copper shorting every
    # foreign net it covers. (Measured during implementation: a pour over a
    # foreign SMD pad filled to the full 256.0000 mm^2 with the void missing.)
    # Folded through the ONE existing worker-side mapping the geometric DRC
    # already uses (drc_geometric._canon_layer), not a second hand-rolled table.
    layer_canon = kicad_to_canon(zone.layer.id)
    items = []

    for prim in projection.copper:
        if layer_canon not in {kicad_to_canon(lid) for lid in prim.layers}:
            continue
        if prim.net_id is not None and prim.net_id == zone.net_id:
            continue  # same net -> SOLID connect, no carve
        gap = _clearance_mm(zone, board, class_clearance, prim.net_id)
        if isinstance(prim.shape, Capsule):
            items.append((_capsule_ring(prim.shape), False,
                          _to_nm(prim.shape.r + gap)))
        elif isinstance(prim.shape, OrientedRect):
            items.append((_rect_ring(prim.shape), True, _to_nm(gap)))
        else:
            raise ZoneFillError(
                zone.id,
                f"copper primitive {prim.entity_id!r} has shape "
                f"{type(prim.shape).__name__}, which the filler cannot inflate")

    for hole in projection.holes:
        # SAME-NET PLATED HOLES CARVE THE BARE DRILL, WITH NO CLEARANCE BAND.
        #
        # THE STITCHING-VIA MOAT (found in review). Carving every drill at
        # (radius + clearance) looks conservative and is a silent OPEN. A GND
        # stitching via inside a GND pour exists precisely to tie the pour to the
        # other layer: its LAND is same-net and correctly not carved, but a
        # clearance ring around its DRILL eats the land from the inside. Measured
        # on the fixture: at clearance 0.2 the void radius lands on 0.4000 mm —
        # exactly the land radius, so the via hangs on by a sliver; at 0.3 the
        # void is 0.5000 mm and the via is a free-floating island in a 0.100 mm
        # moat. The board still compiles, still passes DRC, and still emits
        # plausible Gerbers, having quietly disconnected the pour it was stitching.
        #
        # A clearance is a rule about copper of DIFFERENT potential. The barrel of
        # a same-net plated hole is that same net — it is the connection, not a
        # hazard to be spaced away from.
        #
        # NOT EVEN THE BORE IS CARVED, which is one step further than it first
        # looks and is the behaviour BOTH independent references agree on:
        #   * MEASURED from the oracle: KiCad's filled polygon has no void at the
        #     same-net via at all (six voids on this fixture, none at the via).
        #   * OUR OWN EMITTER already works this way for every other drilled
        #     feature — `_add_annuli` flashes a SOLID disc for a through-hole
        #     land and `_emit_board_hole` a solid ring; neither punches the bore
        #     out of the copper artwork.
        # Copper artwork is solid and the DRILL FILE removes the material. Punching
        # the bore out of the pour, and only the pour, would make this one feature
        # disagree with every other hole on the board for no gain.
        #
        # NON-PLATED holes keep the full carve however their net field reads: an
        # unplated bore has no copper barrel to connect anything, so it is a
        # mechanical hazard to every net including its own. FOREIGN-net holes keep
        # it for the obvious reason.
        if hole.net_id is not None and hole.net_id == zone.net_id and hole.plated:
            continue
        gap = _hole_clearance_mm(zone, board, class_clearance, hole)
        for capsule in hole.capsules:
            items.append((_capsule_ring(capsule), False, _to_nm(capsule.r + gap)))

    return items


def _keepout_paths(zone: ResolvedZone, board: ResolvedBoard):
    """Keepout rings that apply to this pour: same layer, and either netless
    (applies to every pour) or naming this pour's net."""
    out = []
    for other in board.zones:
        if other.kind is not ZoneKind.KEEPOUT:
            continue
        if kicad_to_canon(other.layer.id) != kicad_to_canon(zone.layer.id):
            continue
        if other.net_id is not None and other.net_id != zone.net_id:
            continue
        out.append(_contour_ring(other))
    return out


def _board_clip_ring(board: ResolvedBoard, zone: ResolvedZone) -> list[tuple[int, int]]:
    """The board rim inset by the copper-to-edge rule.

    Copper is not allowed to run to the board edge; the router and the DRC both
    know it (GC5) and a pour drawn past the edge would otherwise emit copper into
    the routed slot. Clipping here means an over-drawn outline yields a legal
    pour rather than a DRC violation, and it matches what the oracle does.

    A rect-outer :class:`ProfileOutline` clips to the same rim rectangle; its
    interior cutouts are handled separately (:func:`_cutout_items`) because
    they subtract from the middle rather than bound the outside.
    """
    outline = board.outline
    if isinstance(outline, ProfileOutline):
        frame = profile_outer_rect(outline)
        if frame is None:
            raise ZoneFillError(
                zone.id,
                "v1 fill clips to a rectangular board rim only; this "
                "ProfileOutline's outer contour is not an axis-aligned rectangle")
        ox, oy, width_mm, height_mm = frame
    elif isinstance(outline, RectOutline):
        ox, oy = outline.origin
        width_mm, height_mm = outline.width_mm, outline.height_mm
    else:
        raise ZoneFillError(
            zone.id,
            f"v1 fill clips to a rectangular board only; got "
            f"{type(outline).__name__}")
    inset = board.design_rules.minimums.copper_to_edge_mm
    x0, y0 = _to_nm(ox + inset), _to_nm(oy + inset)
    x1 = _to_nm(ox + width_mm - inset)
    y1 = _to_nm(oy + height_mm - inset)
    if x1 <= x0 or y1 <= y0:
        raise ZoneFillError(
            zone.id,
            f"copper-to-edge inset {inset} mm leaves no fillable board area")
    return [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]


def _cutout_items(board: ResolvedBoard):
    """Every interior board cutout as a ``(ring, closed, offset_nm)``
    subtraction item: the opening itself plus the copper-to-edge band around
    it. A slot edge is a board edge (GC5), so a pour keeps the same clearance
    from a cutout that :func:`_board_clip_ring` keeps from the rim — carved
    here BY CONSTRUCTION so the fill never emits copper the DRC would flag."""
    inset = board.design_rules.minimums.copper_to_edge_mm
    items = []
    for cut in outline_cutouts(board.outline):
        ring: list[tuple[int, int]] = []
        for segment in cut.contour.segments:
            if not isinstance(segment, LineGeometry):
                raise ZoneFillError(
                    cut.id,
                    f"cutout contour contains a {type(segment).__name__}; v1 "
                    f"fill has no arc-discretisation policy and will not invent one")
            ring.append((_to_nm(segment.a[0]), _to_nm(segment.a[1])))
        if len(ring) < 3:
            raise ZoneFillError(
                cut.id, f"cutout contour collapses to {len(ring)} distinct point(s)")
        _refuse_self_intersecting(cut.id, ring)
        items.append((ring, True, _to_nm(inset)))
    return items


def _refuse_thermal(zone: ResolvedZone) -> None:
    """Refuse a pour that authors thermal-relief geometry. See module docstring."""
    if zone.thermal is None:
        return
    raise ZoneFillError(
        zone.id,
        f"authors thermal relief (thermal_gap_mm={zone.thermal.gap_mm}, "
        f"thermal_bridge_width_mm={zone.thermal.bridge_width_mm}) but v1 fill "
        f"implements SOLID connect only. Filling solid would silently discard an "
        f"authored fabrication parameter on a HAND-SOLDERED board, where a "
        f"solid-tied ground pad is the classic cold-joint cause. Whether v1 pours "
        f"solid or with spokes is a pending owner ruling; until it is made this "
        f"board is refused rather than mis-filled")


# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------


def fill_board_zones(board: ResolvedBoard) -> ResolvedBoard:
    """Return ``board`` with every COPPER_POUR zone carrying a computed fill.

    Keepouts pass through untouched with ``fill=None``: a keepout has no copper,
    so there is nothing to compute, and ``()`` would falsely claim a computed
    empty pour. Raises :class:`ZoneFillError` for any pour that cannot be filled.
    """
    if not board.zones:
        return board

    pours = [z for z in board.zones if z.kind is ZoneKind.COPPER_POUR]
    if not pours:
        return board

    pc = _pyclipper()
    _refuse_overlapping_pours(pc, pours)
    # Imported here rather than at module scope: the filler is the only consumer,
    # and the projection is the DRC's, deliberately SHARED rather than forked so
    # the copper a pour carves around and the copper the DRC checks are the same
    # set by construction. Two hand-kept-in-step harvests would drift silently,
    # and the drift would be a pour carved around copper nobody checks.
    from .drc_geometric import project_board  # noqa: PLC0415

    projection = project_board(board)
    class_clearance = _net_class_clearances(board)

    filled: list[ResolvedZone] = []
    for zone in board.zones:
        if zone.kind is not ZoneKind.COPPER_POUR:
            filled.append(zone)
            continue
        _refuse_thermal(zone)
        filled.append(replace(zone, fill=_fill_one(pc, zone, board, projection,
                                                   class_clearance)))
    return replace(board, zones=tuple(filled))


def _refuse_overlapping_pours(pc, pours) -> None:
    """Refuse pours of DIFFERENT nets whose outlines GENUINELY OVERLAP.

    THE TEST IS ACTUAL INTERSECTION, not co-residence on a layer. An earlier
    version refused any two different-net pours sharing a layer, which is far too
    broad and rejects the ordinary case: a GND pour and a 5V pour side by side on
    the top layer is how a real board is built, and they do not interact at all
    when they are disjoint. Two pours on a layer is not a conflict; two pours
    claiming the SAME COPPER is.

    WHY THE REMAINING REFUSAL IS AT COMPILE RATHER THAN LEFT TO DRC. The natural
    objection is that foreign-net copper too close together is GC7's business.
    GC7 cannot see this one: it checks a pour against
    ``drc_geometric.project_board``, which flattens pads, traces, vias and
    board-hole copper — and NOT zone fill. Nothing in the DRC models pour-versus-
    pour. Since each pour is also filled independently, and neither carves around
    the other, two overlapping different-net pours would both claim the overlap
    and emit literally shorted copper that no check on the board would report.
    Nor is there an authored answer to resolve it with: ``ResolvedZone.priority``
    exists in the IR and is never populated, so "which pour wins" would have to be
    invented. Fail closed.

    SAME-NET OVERLAP IS FINE and is deliberately allowed: two pours at the same
    potential merge into one region, which is a union, not a conflict.
    """
    by_layer: dict[str, list] = {}
    for zone in pours:
        by_layer.setdefault(kicad_to_canon(zone.layer.id), []).append(zone)

    for layer_id, group in by_layer.items():
        for index, first in enumerate(group):
            for second in group[index + 1:]:
                if first.net_id == second.net_id:
                    continue
                clipper = pc.Pyclipper()
                clipper.AddPath(_contour_ring(first), pc.PT_SUBJECT, True)
                clipper.AddPath(_contour_ring(second), pc.PT_CLIP, True)
                shared = clipper.Execute(pc.CT_INTERSECTION,
                                         pc.PFT_NONZERO, pc.PFT_NONZERO)
                if not shared:
                    continue
                area_mm2 = abs(sum(_ring_area2(r) for r in shared)) / 2.0 / (
                    NM_PER_MM * NM_PER_MM)
                raise ZoneFillError(
                    first.id,
                    f"overlaps pour {second.id!r} of a DIFFERENT net by "
                    f"{area_mm2:.6f} mm^2 on layer {layer_id}. Both would fill "
                    f"that copper at different potentials — a short that no DRC "
                    f"check models (geometric DRC projects pads/traces/vias, "
                    f"never zone fill) — and fill priority is not authorable in "
                    f"this schema, so which pour owns it has no answer to read")


QUANTUM_NM = 1
"""One nanometre — the smallest distance the emitted Gerber can express.

Used to dilate same-net copper before the island test so that copper TOUCHING a
region counts as attached to it. Clipper's intersection of two shapes that share
only a boundary is empty, which would report a pad sitting exactly on the pour's
edge as unconnected. This is not a tolerance and no number was chosen: one
quantum is the smallest representable non-zero in the domain the whole filler
works in, so it can absorb an exact-touch and nothing else.
"""


def _same_net_copper_paths(pc, zone: ResolvedZone, projection):
    """Same-net copper on this pour's layer, as a dilated integer-nm path set.

    This is what the pour is FOR: under SOLID connect it is not carved around,
    so a region of fill that overlaps some of it is electrically attached to the
    net, and a region that overlaps none of it is attached to nothing.
    """
    layer_canon = kicad_to_canon(zone.layer.id)
    items = []
    for prim in projection.copper:
        if prim.net_id is None or prim.net_id != zone.net_id:
            continue
        if layer_canon not in {kicad_to_canon(lid) for lid in prim.layers}:
            continue
        if isinstance(prim.shape, Capsule):
            items.append((_capsule_ring(prim.shape), False,
                          _to_nm(prim.shape.r) + QUANTUM_NM))
        elif isinstance(prim.shape, OrientedRect):
            items.append((_rect_ring(prim.shape), True, QUANTUM_NM))
        else:
            raise ZoneFillError(
                zone.id,
                f"same-net copper primitive {prim.entity_id!r} has shape "
                f"{type(prim.shape).__name__}, which the filler cannot inflate")
    if not items:
        return []
    return _inflate(pc, items)


def _net_name(board: ResolvedBoard, net_id: str | None) -> str:
    """The authored net NAME for a diagnostic, falling back to the id.

    A refusal that says "overlaps no net:2781cb9ca13e..." names a hash the author
    has never seen; one that says "overlaps no GND copper" names the thing they
    drew. The id is kept as the fallback rather than dropped, so a net that
    somehow has no entry still identifies itself.
    """
    if net_id is None:
        return "(netless)"
    for net in board.nets:
        if net.id == net_id:
            return net.name
    return net_id


def _region_bbox_mm(outer):
    xs = [p[0] for p in outer]
    ys = [p[1] for p in outer]
    return (_to_mm(min(xs)), _to_mm(min(ys)), _to_mm(max(xs)), _to_mm(max(ys)))


def _region_area_mm2(outer, holes) -> float:
    doubled = _ring_area2(outer) + sum(_ring_area2(h) for h in holes)
    return abs(doubled) / 2.0 / (NM_PER_MM * NM_PER_MM)


def _refuse_unfabricable_regions(pc, zone: ResolvedZone, board: ResolvedBoard,
                                 projection, solution) -> None:
    """Refuse a pour whose fill broke into copper that cannot go to fab.

    TWO FAULTS, both stated over one disjoint filled REGION (see
    :func:`_group_regions`), both previously EMITTED IN SILENCE and recorded only
    as skipped tests:

      * ISLAND — a region overlapping no same-net copper at all. It is live
        copper attached to nothing: an antenna, floating at whatever potential
        it couples to, and on a ground pour it is also ground plane the designer
        believes they have and do not. KiCad removes these by default
        (MEASURED against KiCad 9.0.9: a 20 mm^2 severed fragment vanishes from
        ``ZONE_FILLER``'s output, and reappears at exactly 19.9745 mm^2 when
        ``island_removal_mode`` is set to 1 or 2 — so removal is the default and
        the fragment is exactly what removal takes).
      * SLIVER — a region that is nowhere as wide as the board house's minimum
        feature, so no part of it can be etched reliably. Detected by deflating
        the region by half the floor and asking whether ANYTHING survives: a
        shape contains a disc of radius d/2 exactly when it is at least d wide
        somewhere, so an empty deflation is a proof of sub-floor width, not an
        estimate of one. No tolerance and no area threshold appears here.

    === WHY REFUSE RATHER THAN CULL, WHEN KiCad CULLS ===

    KiCad culls both, and we deliberately do not copy it, because KiCad culls
    against NUMBERS ITS AUTHOR SUPPLIED and we have none. Its sliver cull runs at
    the zone's own ``min_thickness`` (default 0.25 mm) and its island cull at the
    zone's own ``island_removal_mode``; both are per-zone authored properties in
    its schema. Ours has neither field, and ``ResolvedZone.min_thickness_mm``
    exists in the IR precisely as a place one would go — it is never populated.

    So the choice is not "cull or refuse", it is "invent a rule and silently
    delete the author's copper by it, or hand the author the fact". Deleting
    copper on a rule nobody wrote is the failure mode this module's every other
    refusal exists to prevent, and it is worse here than elsewhere because the
    deletion is invisible: the pour still fills, still passes DRC, and still
    emits plausible Gerbers with less ground plane than the designer drew.

    THE FLOOR IS NOT INVENTED. ``min_trace_width_mm`` is the pinned profile's own
    published minimum feature — a rule the author DID write, by choosing that
    board house. A fragment thinner than it is unmanufacturable by the fab's own
    statement, which is a fact about the fab and not a policy of ours.

    === WHY THIS DOES NOT PREJUDGE THE THERMAL RULING (R-d) ===

    Both faults would, in general, interact with thermal relief: under spokes it
    is the SPOKES that attach a pad's surrounding fill to the pour, so which
    regions count as islands can depend on spoke geometry. That interaction
    cannot arise here, because :func:`_refuse_thermal` refuses any board that
    authors thermal fields BEFORE the fill runs. Everything this function ever
    sees is SOLID-connect fill, where "region overlaps same-net copper" is the
    whole of the connectivity question — the measurement above confirms KiCad
    reaches the same verdict on the same geometry in both modes.

    When R-d lands and spokes are implemented, the spokes become part of the fill
    and both tests read them for free: a region joined by a spoke overlaps the
    pad it is spoked to, and a spoke narrower than the minimum feature is a
    genuine sliver rather than a false positive. What must NOT happen is spokes
    being added downstream of this check.

    === WHAT THIS DOES NOT CATCH ===

    Two things, both xfailed by name in tests/test_zone_fill.py rather than
    skipped, so the tally counts them as open:

      * Sub-floor copper INSIDE an otherwise sound region — a thin neck or spike
        on a fragment that is elsewhere wide. Detecting it needs the
        deflate/inflate opening KiCad performs, which rounds every convex corner
        and so cannot be distinguished from a real defect without a fitted area
        threshold; the honest form is an authored ``min_thickness`` applied as
        KiCad applies it.
      * A pour with NO same-net copper on its layer at all. That is a whole-pour
        fact rather than a severed-fragment fact, and the island test is scoped
        away from it deliberately — see the ``if not attached`` branch.
    """
    outers, assigned = _group_regions(pc, zone.id, solution)
    if not outers:
        return

    floor_mm = board.design_rules.minimums.min_trace_width_mm
    floor_nm = _to_nm(floor_mm)
    attached = _same_net_copper_paths(pc, zone, projection)

    faults: list[tuple[tuple, str]] = []
    survivors: list[tuple[tuple, float, tuple, bool]] = []
    for index, outer in enumerate(outers):
        holes = assigned[index]
        bbox = _region_bbox_mm(outer)
        area = _region_area_mm2(outer, holes)
        sort_key = (bbox[0], bbox[1], bbox[2], bbox[3], area)

        # SLIVER IS REPORTED IN PREFERENCE TO ISLAND when a region is both, and
        # the order is fixed rather than incidental: a fragment that cannot be
        # etched at all is a fact about the fab, while whether it connects to
        # anything is a fact about the netlist, and reporting the second while
        # the first holds would send the author to fix the wrong thing.
        if floor_nm > 0 and not _survives_deflation(pc, outer, holes, floor_nm):
            faults.append((sort_key, (
                f"SLIVER at ({bbox[0]:.4f},{bbox[1]:.4f})-({bbox[2]:.4f},"
                f"{bbox[3]:.4f}) of {area:.6f} mm^2 is nowhere as wide as the "
                f"{floor_mm} mm minimum feature this board's profile publishes "
                f"(min_trace_width_mm), so no part of it etches reliably")))
            continue

        survivors.append((sort_key, area, bbox,
                          _overlaps_any(pc, outer, holes, attached)))

    # AN ISLAND IS A REGION SEVERED FROM *THIS POUR'S OWN* ATTACHED COPPER, so
    # the rule only engages once some region of this pour IS attached. That
    # condition is the whole of the scoping, and it is not a convenience:
    #
    #   * If NO region is attached, the pour as a whole touches none of its net
    #     — a bottom-side GND pour on a board whose only GND copper is top-side,
    #     say. Nothing was severed from anything. Reporting every region would
    #     be reporting a WHOLE-POUR fact ("this pour attaches to nothing") in
    #     the vocabulary of a per-fragment one, while having lost the ability to
    #     tell a severed fragment from an intact one. That fact deserves its own
    #     diagnostic and is recorded as an open in tests/test_zone_fill.py, not
    #     smuggled in here.
    #   * If SOME region is attached and others are not, the carve genuinely cut
    #     those others loose. That is the fault this rule names.
    #
    # A netless pour also lands in the first case (nothing can match a null net),
    # which keeps a future schema change from silently deleting its copper;
    # compile_board rejects one upstream today.
    if any(is_attached for _, _, _, is_attached in survivors):
        for sort_key, area, bbox, is_attached in survivors:
            if is_attached:
                continue
            faults.append((sort_key, (
                f"ISLAND at ({bbox[0]:.4f},{bbox[1]:.4f})-({bbox[2]:.4f},"
                f"{bbox[3]:.4f}) of {area:.6f} mm^2 overlaps no "
                f"{_net_name(board, zone.net_id)} copper on "
                f"{kicad_to_canon(zone.layer.id)}, so it is live copper "
                f"severed from the rest of this pour")))

    if not faults:
        return
    # Sorted by geometry, never by Clipper's contour order, so the message a
    # given board produces is the same message on every run and every platform.
    detail = "\n  - ".join(text for _, text in sorted(faults))
    raise ZoneFillError(
        zone.id,
        f"fill broke into {len(faults)} region(s) that cannot be fabricated:\n"
        f"  - {detail}\n"
        f"Neither fault is culled: dropping copper the author drew needs a rule "
        f"the author wrote, and this schema has neither a zone min-thickness nor "
        f"an island-removal mode to read one from")


def _survives_deflation(pc, outer, holes, floor_nm: int) -> bool:
    """True when the region still holds a disc of radius ``floor_nm/2``.

    Exactly the "is it ever as wide as the floor" question, asked in the integer
    kernel. NEGATIVE offsets on a region are why the holes must be included: a
    ring of copper around a big void is thin everywhere, and deflating only its
    outer boundary would report it as solid.
    """
    offset = pc.PyclipperOffset()
    offset.MiterLimit = MITER_LIMIT
    offset.ArcTolerance = ARC_TOLERANCE_NM
    offset.AddPath(outer, pc.JT_ROUND, pc.ET_CLOSEDPOLYGON)
    for hole in holes:
        offset.AddPath(hole, pc.JT_ROUND, pc.ET_CLOSEDPOLYGON)
    return bool(offset.Execute(-floor_nm / 2.0))


def _overlaps_any(pc, outer, holes, clip_paths) -> bool:
    """True when the region shares ANY area with ``clip_paths``."""
    if not clip_paths:
        return False
    clipper = pc.Pyclipper()
    clipper.AddPath(outer, pc.PT_SUBJECT, True)
    for hole in holes:
        clipper.AddPath(hole, pc.PT_SUBJECT, True)
    clipper.AddPaths(clip_paths, pc.PT_CLIP, True)
    return bool(clipper.Execute(pc.CT_INTERSECTION, pc.PFT_NONZERO, pc.PFT_NONZERO))


def _fill_one(pc, zone: ResolvedZone, board: ResolvedBoard, projection,
              class_clearance: dict[str, float]) -> tuple[PolygonGeometry, ...]:
    subject = _contour_ring(zone)

    clip = pc.Pyclipper()
    clip.AddPath(subject, pc.PT_SUBJECT, True)
    clip.AddPath(_board_clip_ring(board, zone), pc.PT_CLIP, True)
    try:
        bounded = clip.Execute(pc.CT_INTERSECTION, pc.PFT_NONZERO, pc.PFT_NONZERO)
    except pc.ClipperException as exc:
        raise ZoneFillError(
            zone.id, f"outline rejected by the boolean kernel (self-intersecting "
                     f"or degenerate?): {exc}") from exc
    if not bounded:
        return ()

    subtrahends = _inflate(
        pc, _obstacle_paths(pc, zone, board, projection, class_clearance)
        + _cutout_items(board))
    subtrahends.extend(_keepout_paths(zone, board))

    if subtrahends:
        carve = pc.Pyclipper()
        carve.AddPaths(bounded, pc.PT_SUBJECT, True)
        carve.AddPaths(subtrahends, pc.PT_CLIP, True)
        try:
            solution = carve.Execute(pc.CT_DIFFERENCE, pc.PFT_NONZERO, pc.PFT_NONZERO)
        except pc.ClipperException as exc:
            raise ZoneFillError(
                zone.id, f"clearance carve failed in the boolean kernel: {exc}") from exc
    else:
        solution = bounded

    if not solution:
        # Legitimately nothing left (fully covered by a keepout, say). A COMPUTED
        # empty pour, which is not the same fact as an uncomputed one.
        return ()

    # BEFORE fracturing, because fracturing merges each region's voids into a
    # self-touching keyhole and the two checks below are stated over regions and
    # their voids as separate rings. Checking afterwards would ask both questions
    # of a shape that no longer distinguishes copper from the window in it.
    _refuse_unfabricable_regions(pc, zone, board, projection, solution)

    rings = _fracture(pc, zone.id, solution)
    polygons = []
    for ring in rings:
        if len(ring) < 3:
            raise ZoneFillError(
                zone.id, f"fill produced a degenerate {len(ring)}-point contour")
        polygons.append(PolygonGeometry(
            points=tuple((_to_mm(x), _to_mm(y)) for (x, y) in ring)))
    return tuple(polygons)


def fill_area_mm2(zone: ResolvedZone) -> float:
    """Signed-shoelace area of a zone's computed fill, in mm^2.

    A fractured keyhole ring's zero-width slit contributes exactly zero to the
    shoelace sum, so this is the real copper area of a pour with voids — the
    same quantity KiCad's ``Area()`` reports, which is what makes the two
    directly comparable.
    """
    if not zone.fill:
        return 0.0
    total = 0.0
    for polygon in zone.fill:
        pts = polygon.points
        acc = 0.0
        for i, (x, y) in enumerate(pts):
            nx, ny = pts[(i + 1) % len(pts)]
            acc += x * ny - nx * y
        total += acc / 2.0
    return abs(total)


__all__ = [
    "ARC_TOLERANCE_NM",
    "NM_PER_MM",
    "ZoneFillError",
    "fill_area_mm2",
    "fill_board_zones",
]
