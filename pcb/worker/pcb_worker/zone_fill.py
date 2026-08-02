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

=== KNOWN v1 GAPS (stated, not hidden) ===

  * ISLAND REMOVAL. A pour fragment connected to no same-net copper is kept.
    KiCad drops such islands by default, so a fixture that produces one will not
    reach oracle parity. Dropping copper the author drew needs a rule, and the
    schema has none (``min_thickness_mm`` and ``priority`` exist in the IR and
    are never populated). Left in, and left loud.
  * POUR-TO-POUR PRIORITY. Two pours of different nets overlapping on one layer
    would both claim the overlap. ``priority`` is unpopulated, so there is no
    authored answer; the case is refused rather than resolved arbitrarily.
"""

from __future__ import annotations

from dataclasses import replace

from agent_router.layers import kicad_to_canon

from .drc_geom_primitives import Capsule, OrientedRect
from .resolved_board import (
    ArcGeometry,
    LineGeometry,
    PolygonGeometry,
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
    outers = [list(p) for p in solution if _is_outer(p)]
    holes = [list(p) for p in solution if not _is_outer(p)]
    if not outers:
        return []

    # Doubled areas throughout — exact integers, never halved, never floats.
    expected = sum(_ring_area2(r) for r in outers + holes)  # holes are negative

    # Assign each hole to the outer ring that contains it. A hole is inside
    # exactly one outer ring in a well-formed Clipper solution.
    assigned: dict[int, list[list[tuple[int, int]]]] = {i: [] for i in range(len(outers))}
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
        gap = _clearance_mm(zone, board, class_clearance, hole.net_id)
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
    """The board outline inset by the copper-to-edge rule.

    Copper is not allowed to run to the board edge; the router and the DRC both
    know it (GC5) and a pour drawn past the edge would otherwise emit copper into
    the routed slot. Clipping here means an over-drawn outline yields a legal
    pour rather than a DRC violation, and it matches what the oracle does.
    """
    outline = board.outline
    if not isinstance(outline, RectOutline):
        raise ZoneFillError(
            zone.id,
            f"v1 fill clips to a rectangular board only; got "
            f"{type(outline).__name__}")
    inset = board.design_rules.minimums.copper_to_edge_mm
    ox, oy = outline.origin
    x0, y0 = _to_nm(ox + inset), _to_nm(oy + inset)
    x1 = _to_nm(ox + outline.width_mm - inset)
    y1 = _to_nm(oy + outline.height_mm - inset)
    if x1 <= x0 or y1 <= y0:
        raise ZoneFillError(
            zone.id,
            f"copper-to-edge inset {inset} mm leaves no fillable board area")
    return [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]


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
        pc, _obstacle_paths(pc, zone, board, projection, class_clearance))
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
