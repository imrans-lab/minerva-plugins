"""Connectivity/topology check over a canonical board model.

NOT a geometric copper DRC. It CANNOT verify a clearance, a width rule, an
annular ring or mask geometry, and a zero-finding result means "no
connectivity/topology fault found", NOT "geometrically or fab clean". Real
geometric-copper DRC + manufacturer DFM need resolved pad/trace geometry (the
ResolvedBoard IR, docket 019f7abf55c2) and are reported separately (019f7abf7e7b).

ONE PLACE READS REAL COPPER EXTENT: whether a piece of copper JOINS a pad. That
question is answered by the shared contact predicate (:mod:`copper_contact`) —
the run's swept width against the pad's land — because a pad-centre distance
gets it wrong in both directions: a wide trace ending off-centre reads as an
open, and a run driven across a land reads as unconnected. Everything ELSE here
is still centreline-to-centre: the shorts (check A) measure a centreline against
a pad CENTER, deliberately, so this module keeps under-reporting a clearance it
has no standing to judge.

Pure Python, no KiCad binary — operates on the same canonical board dict
(``board_model.load_board``) that gerber.py / kicad.py consume. Four connectivity checks:

  A. wrong_net_pad     — a trace centerline within clearance of a pad of a
                         DIFFERENT net, at an ENDPOINT (short / mis-route) or
                         ANYWHERE ALONG the run (a segment driven straight over
                         a foreign land)  -> deduped per (segment, pad).
  B. crossing          — two trace segments on the SAME layer, DIFFERENT nets,
                         that intersect  -> deduped per (net-pair, layer).
  C. dangling_endpoint — a LEAF trace endpoint (degree 1 in its net) that reaches
                         no pad, via, same-net POUR FILL, or other same-net
                         copper  -> open.
  D. layer_change_no_via — a net's top-side and bottom-side copper meet at a point
                         that is neither a via nor a through-hole pad -> missing via.

FALSE-POSITIVE GUARDS (mandatory — a DRC that cries wolf is useless):

  * T-junction credit: a leaf endpoint lying on the INTERIOR of another same-net
    segment counts as connected (not just shared endpoints) — else GND taps read
    as opens.
  * Any-pad credit for dangling: an endpoint whose copper reaches *any* pad (even
    a wrong-net one) is copper-connected, so it is a short (check A), never an
    open (check C).
    This also means a leaf ending on ANY pad of its component is never a false
    open — same-component same-net pads (module internal nets, e.g. an ESP32's
    several GND pins) are internally connected and stay quiet.

DRY: pad absolute positions, land angles and board layers all come from ONE
placement rule, geometry.component_transform -> PlacementTransform — the very
transform compile_board applies — so DRC and the fabrication compiler agree
byte-for-byte on where a rotated or bottom-MOUNTED pad lands and which side its
copper is on. This module owns only the net<->pad wiring and the segment
geometry that gerber has no need for.
"""

from __future__ import annotations

import math
from collections import defaultdict
from typing import Any, NamedTuple

from agent_router import layers as _layers

from . import copper_contact, zone_copper
from .geometry import PlacementTransform, component_transform
from .resolved_board import Layer
from .pad_source import has_copper, is_through_hole, is_unplated_hole, iter_pads

# Tolerances (mm). COINCIDENT gates "touches a pad/via" and "meets the other
# layer"; it defaults to the board's clearance rule (same value the wrong-net
# short test uses). MERGE_EPS collapses points that are meant to be identical
# (authored to the same coordinate) for degree / meeting-point bookkeeping.
DEFAULT_COINCIDENT_MM = 0.2
MERGE_EPS_MM = 1e-3
ORIENT_EPS = 1e-9

# COPPER-COPPER coincidence epsilon for the COMPLETENESS census (work item
# 019fd5fdeef3, DCR 019fd5fd9084). The census used to union two same-net
# trace segments whenever their endpoints came within the DESIGN CLEARANCE
# (~0.2mm) of each other — but clearance is the minimum legal AIR GAP between
# separate copper, so that credit declared traces "connected" at exactly the
# spacing where they are guaranteed to be legally SEPARATE (the measured
# false-complete: two parallel same-net traces 0.15mm apart, touching
# nothing, read as one island). Trace-to-trace connection in a centerline
# kernel is an authoring-identity question — the points were written to BE
# the same point — so the credit uses this coincidence epsilon (the same
# 1e-3mm scale MERGE_EPS_MM already uses for endpoint-degree bookkeeping).
#
# DELIBERATE ASYMMETRY: PAD- and VIA-involved credits KEEP the clearance-
# scale tolerance. A pad is a LAND with real extent (typically >=0.5mm
# across) and a via has a barrel + annulus, so a centerline endpoint within
# clearance of the pad/via CENTER genuinely reaches that copper; a bare
# segment endpoint has no extent at all in this kernel, so there is no land
# geometry to justify reaching it.
COPPER_COINCIDENT_EPS_MM = 1e-3


# ---------------------------------------------------------------------------
# Loosely-typed board helpers (mirror gerber.py so behaviour matches).
# ---------------------------------------------------------------------------


def _num(v: Any, default: float = 0.0) -> float:
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else default


def _opt_num(v: Any) -> float | None:
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def _list(v: Any) -> list:
    return v if isinstance(v, list) else []


def _round_pt(p: tuple[float, float]) -> tuple[float, float]:
    return (round(p[0], 3), round(p[1], 3))


# ---------------------------------------------------------------------------
# Geometry primitives.
# ---------------------------------------------------------------------------


def _orient(a, b, c) -> int:
    v = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])
    if abs(v) < ORIENT_EPS:
        return 0
    return 1 if v > 0 else -1


def _on_seg(a, b, c) -> bool:
    """c is within a-b's bounding box (used only when a,b,c are collinear)."""
    return (min(a[0], b[0]) - ORIENT_EPS <= c[0] <= max(a[0], b[0]) + ORIENT_EPS and
            min(a[1], b[1]) - ORIENT_EPS <= c[1] <= max(a[1], b[1]) + ORIENT_EPS)


def _segments_intersect(p1, p2, p3, p4) -> bool:
    """Proper segment-intersection test incl. collinear overlap. A naive
    parametric test yields false positives on parallel/collinear pairs; this is
    the standard four-orientation predicate."""
    o1, o2 = _orient(p1, p2, p3), _orient(p1, p2, p4)
    o3, o4 = _orient(p3, p4, p1), _orient(p3, p4, p2)
    if o1 != o2 and o3 != o4:
        return True
    return ((o1 == 0 and _on_seg(p1, p2, p3)) or
            (o2 == 0 and _on_seg(p1, p2, p4)) or
            (o3 == 0 and _on_seg(p3, p4, p1)) or
            (o4 == 0 and _on_seg(p3, p4, p2)))


def _intersection_point(p1, p2, p3, p4) -> tuple[float, float]:
    """Representative crossing point. Proper (non-parallel) crossings solve the
    line-line intersection; for a collinear overlap we return whichever endpoint
    lies inside the other segment (a stable, on-copper representative)."""
    x1, y1 = p1
    x2, y2 = p2
    x3, y3 = p3
    x4, y4 = p4
    d = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4)
    if abs(d) > ORIENT_EPS:
        t = ((x1 - x3) * (y3 - y4) - (y1 - y3) * (x3 - x4)) / d
        return (x1 + t * (x2 - x1), y1 + t * (y2 - y1))
    for cand, a, b in ((p3, p1, p2), (p4, p1, p2), (p1, p3, p4), (p2, p3, p4)):
        if _on_seg(a, b, cand):
            return cand
    return p1


def _dist(a, b) -> float:
    return ((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2) ** 0.5


def _point_on_segment_interior(pt, a, b, eps: float) -> bool:
    """True if pt lies on the STRICT interior of segment a-b (perpendicular
    distance <= eps, and at least eps ALONG the segment from either endpoint).
    Endpoint coincidences are handled separately via degree counting.

    UNITS. ``t`` is the dimensionless projection parameter in [0, 1]; ``eps`` is
    a distance in MILLIMETRES. Comparing them directly (``t <= eps``) scaled the
    endpoint exclusion by the segment's own length: on a 12mm run at eps=0.2 it
    blanked 2.4mm at each end, so a pad sitting on real copper 2.35mm from a
    trace end earned no T-junction credit and its net silently reported an extra
    pin island. Both ends of the comparison are metric now.
    """
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    seg_len2 = dx * dx + dy * dy
    if seg_len2 < eps * eps:
        return False
    seg_len = math.sqrt(seg_len2)
    t = ((pt[0] - ax) * dx + (pt[1] - ay) * dy) / seg_len2
    if t * seg_len <= eps or (1.0 - t) * seg_len <= eps:
        return False
    proj = (ax + t * dx, ay + t * dy)
    return _dist(pt, proj) <= eps


def _closest_point_on_segment(pt, a, b) -> tuple[float, float]:
    """The point of segment a-b nearest ``pt``, CLAMPED to the segment (a
    degenerate zero-length segment answers ``a``).

    Unlike :func:`_point_on_segment_interior` this carves out no endpoint band
    and returns a POINT rather than a verdict: the caller decides which stretch
    of the run it owns and needs the location to report.
    """
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    seg_len2 = dx * dx + dy * dy
    if seg_len2 <= 0.0:
        return a
    t = ((pt[0] - ax) * dx + (pt[1] - ay) * dy) / seg_len2
    t = 0.0 if t < 0.0 else (1.0 if t > 1.0 else t)
    return (ax + t * dx, ay + t * dy)


# ---------------------------------------------------------------------------
# Board -> geometry harvest.
# ---------------------------------------------------------------------------


class _Pad:
    """One harvested pad. ``layers`` is the CANONICAL set of copper layers the
    pad actually occupies ("top"/"in1"/.../"bottom"), folded once at harvest
    exactly like :class:`_Seg`.

    A pad is not a column through the stack. A top-side SMD land shares no
    copper with a bottom-layer trace passing under it, which is ordinary
    routing -- yet a layer-blind reader called it a short (check A) AND, worse,
    let it JOIN two islands of a net (the pin-group census), which fails open.
    ``through_hole`` stays as the separate, cheaper fact the emitters share.
    THE LAYER SET IS THE CONTACT NODE'S: every check measures copper through
    the shared predicate, which meets layers on the way, and ``occupies`` reads
    that same node — so there is no second layer rule here to drift from it."""

    __slots__ = ("ref", "pin", "net", "x", "y", "through_hole", "layers",
                 "contact")

    def __init__(self, ref, pin, net, x, y, through_hole, layers=None,
                 contact=None):
        self.ref = ref
        self.pin = pin
        self.net = net
        self.x = x
        self.y = y
        self.through_hole = through_hole
        self.layers = layers
        #: This land as a :class:`copper_contact.ContactNode` — the ONE thing
        #: every "does copper reach this pad" question below asks. Built at
        #: harvest so the sweeps do not rebuild geometry per comparison.
        self.contact = contact

    def occupies(self, layer) -> bool:
        """Whether this pad's copper reaches ``layer`` (a canonical id).

        ONE DERIVATION: the contact node's own layer set, which is what every
        check actually measures against. PERMISSIVE when that set is None — a
        plated barrel spans the stack, and a pad from the inline-pin fallback
        declares no layers at all. Only a pad that positively states its copper
        layers can say no.
        """
        if self.contact is None or self.contact.layers is None:
            return True
        return layer in self.contact.layers

    @property
    def pt(self):
        return (self.x, self.y)


class _Seg:
    """One harvested copper segment. ``layer`` is the CANONICAL id (epoch
    GA-3: "top"/"in1"/../"bottom", folded once at harvest) — the old per-seg
    ``top`` boolean is gone because a stack is not a pair. Folding at harvest
    also means the crossing check compares one spelling: before, a board that
    mixed "top" with "F.Cu" spellings compared them UNEQUAL and under-detected
    crossings between them."""

    __slots__ = ("net", "layer", "a", "b", "width")

    def __init__(self, net, layer, a, b, width=0.0):
        self.net = net
        self.layer = layer
        self.a = a
        self.b = b
        #: SWEPT WIDTH, in mm. The centreline alone cannot answer whether a run
        #: covers a land, so the pad-contact predicate needs the real copper; a
        #: board stating no width keeps 0.0 (the bare centreline) rather than a
        #: guessed one.
        self.width = width

    def node(self):
        """This segment's swept copper."""
        return copper_contact.segment_node(self.a, self.b, self.width,
                                           self.layer)

    def end_node(self, pt):
        """The copper at ONE end of this segment (its round cap)."""
        return copper_contact.endpoint_node(pt, self.width, self.layer)


def _pin_net_map(board: dict) -> dict[tuple[str, str], str]:
    """(ref, pin_number) -> net name, from the board's net pin references."""
    out: dict[tuple[str, str], str] = {}
    for net in _list(board.get("nets")):
        if not isinstance(net, dict):
            continue
        name = net.get("name")
        if not isinstance(name, str):
            continue
        for ref in _list(net.get("pins")):
            if not isinstance(ref, str):
                continue
            comp, _, pin = ref.rpartition(".")
            if comp:
                out[(comp, pin)] = name
    return out


def _harvest_pads(board: dict) -> list[_Pad]:
    pin_net = _pin_net_map(board)
    # The fallback reach for a pad that states no copper size — the board's own
    # coincidence tolerance, which is exactly the credit such a pad has always
    # been given. See copper_contact._land_shape.
    unknown_land_radius = _board_clearance(board)
    pads: list[_Pad] = []
    for comp in _list(board.get("components")):
        if not isinstance(comp, dict):
            continue
        ref = comp.get("ref")
        # ONE placement rule, shared with the compiler: rotation AND the
        # bottom-side mirror come from geometry.PlacementTransform, built off
        # the component's own authored side. This harvest used to rotate but
        # never mirror, so a bottom-mounted part's pads were checked where its
        # top-side twin would sit — up to a whole footprint away from the copper
        # the fab path (compile_board._place_component, the same transform)
        # actually places.
        transform = component_transform(comp)
        # iter_pads PREFERS resolved comp["pads"] (real footprint pad CENTERS) and
        # otherwise reconstructs the exact per-pin fallback used inline before —
        # DRC uses only the pad center + through-hole flag (no pad SIZE), so
        # gate-OFF is a pure no-op (see pad_source).
        for pad in iter_pads(comp):
            num = str(pad.number)
            px, py = transform.point((pad.x, pad.y))
            # is_through_hole is the SHARED predicate the two emitters also use, so
            # DRC classifies TH-vs-SMD identically (no third hand-written literal to
            # drift — bug 019f91c1420c). DRC runs iter_pads WITHOUT require_smd_size,
            # so a non-finite drill is not fail-closed here; is_through_hole's
            # isfinite guard means it is simply not counted as a through-hole (never
            # NaN-classified), matching the emitters' post-validation behaviour.
            # UNPLATED holes are excluded here, not merely given no contact
            # copper: `through_hole` is also what makes a pad's copper span the
            # stack and what lets check D call a layer hand-off resolved. A
            # hole with no barrel does neither.
            through_hole = is_through_hole(pad) and not is_unplated_hole(pad)
            # PASTE-ONLY apertures are not pads. KiCad splits a QFN thermal pad
            # into several unnumbered `(pad "" smd ... (layers "F.Paste"))`
            # nodes; they are stencil geometry with no copper and no net. Left
            # in, each one reads as an unnetted pad sitting inside the very
            # thermal land it stencils, so any trace endpoint within `clearance`
            # of an aperture centre was reported as a wrong-net short against a
            # nameless pad -- a false positive with no way for the router to
            # comply. `has_copper` is pad_source's own predicate for exactly
            # this distinction, and it preserves the unresolved inline-pin
            # fallback (no layer list => still copper).
            if not has_copper(pad):
                continue
            declared = _placed_layers(transform, pad.layers or [])
            if any(lay == "*.Cu" for lay in declared):
                canon = None          # spans the stack -> permissive
            else:
                canon = frozenset(_layers.kicad_to_canon(lay) for lay in declared
                                  if _layers.is_copper(lay)) or None
            # BOARD angle of the land: the placement angle composed with the
            # pad's own, through the same transform that placed the offset just
            # above — so a bottom-side component's land turns with its mirror
            # (a compiled-IR pad carries its combined angle and rides a
            # zero-rotation top-side component, so the fold is right there too).
            land_deg = transform.angle(_num(pad.rotation))
            # A PLATED BARREL IS COPPER ON EVERY LAYER IT PASSES, so its
            # contact node is layer-blind even when the footprint lists only
            # F.Cu/B.Cu. That is what `occupies` has always said; stating it
            # only there left an inner-layer run ending on the barrel reading
            # as dangling. (An UNPLATED hole never reaches here as a
            # through_hole — see above — and pad_node gives it no copper.)
            contact = copper_contact.pad_node(
                pad, (px, py), land_deg,
                None if through_hole else canon, unknown_land_radius)
            pads.append(_Pad(ref, num, pin_net.get((str(ref), num)),
                             px, py, through_hole, canon, contact))
    return pads


def _placed_layers(transform: PlacementTransform, declared: list) -> list:
    """The BOARD layers a pad's footprint-declared layers occupy once placed.

    A layer name is an absolute board fact, not a footprint-local one: the F.Cu
    land of a bottom-mounted part is B.Cu copper. The flip is the compiler's own
    (``PlacementTransform.layer`` via ``Layer.flipped``), so wildcards like
    ``*.Cu`` survive here exactly as they do on the compiled path. A token
    ``Layer`` cannot read is passed through untouched — the canonical fold above
    already fails visible on junk, and a name that never reached the fold has no
    side to swap.
    """
    out: list = []
    for name in declared:
        if isinstance(name, str) and name:
            out.append(transform.layer(Layer.from_id(name)).id)
        else:
            out.append(name)
    return out


def _harvest_segments(board: dict) -> list[_Seg]:
    segs: list[_Seg] = []
    for tr in _list(board.get("traces")):
        if not isinstance(tr, dict):
            continue
        net = tr.get("net")
        # Canonical fold (epoch GA-3; replaces the _is_top boolean, which
        # RAISED on any inner layer): "F.Cu"/"top" -> "top", "In1.Cu"/"in1"
        # -> "in1". kicad_to_canon fails VISIBLE (warns + passes through) on
        # junk, per the read-side doctrine — connectivity DRC on a legacy
        # board must degrade, not crash.
        layer = _layers.kicad_to_canon(tr.get("layer"))
        pts = [(_num(p.get("x_mm")), _num(p.get("y_mm")))
               for p in _list(tr.get("points")) if isinstance(p, dict)]
        width = max(_num(tr.get("width_mm")), 0.0)
        for a, b in zip(pts, pts[1:]):
            segs.append(_Seg(net, layer, a, b, width))
    return segs


class _HarvestedVia(NamedTuple):
    """A via's position, its declared ``net`` (``None`` when unstated), and its
    barrel as a :class:`copper_contact.ContactNode`.

    A NAMEDTUPLE so ``v[0]`` / ``v[1]`` still read as x / y for check D's
    authored-coincidence test, which asks whether a via was PLACED at a
    hand-off point rather than whether copper reaches it. Every credit that
    asks about COPPER — the dangling endpoint credit and the census — reads
    ``contact`` instead, so a barrel joins a run it sits under wherever along
    that run it sits, not only near an endpoint.
    """

    x: float
    y: float
    net: object
    contact: object


def _harvest_vias(board: dict) -> list[_HarvestedVia]:
    """Harvest each via as a position, its declared net, and its BARREL.

    A canonical via may carry first-class from_layer/to_layer (top/bottom span;
    see pcb_data.gd / board-yaml.md), but under the v1 THROUGH-VIA model (epoch
    GA-3) every via joins ALL declared copper layers at its point, at ANY stack
    depth, so the barrel is built layer-blind. This function never mutates
    board["vias"], so from_layer/to_layer are never dropped from the source
    data — they simply aren't load-bearing yet. A partial (blind/buried) via
    needs the span threaded into the node's layer set here, and nowhere else,
    because the credits downstream already ask the contact predicate.
    """
    out: list[_HarvestedVia] = []
    unknown_radius = _board_clearance(board)
    for via in _list(board.get("vias")):
        if not isinstance(via, dict):
            continue
        net = via.get("net")
        x, y = _num(via.get("x_mm")), _num(via.get("y_mm"))
        out.append(_HarvestedVia(
            x, y, net if isinstance(net, str) and net else None,
            # LAYERS None: under the v1 through-via model a barrel is copper on
            # every layer at its point, which is what makes a top run and a
            # bottom run join through it.
            copper_contact.via_node((x, y), 2.0 * _via_radius(via, unknown_radius),
                                    None)))
    return out


def _via_radius(via: dict, unknown_radius_mm: float) -> float:
    """A via's outer copper radius: half its stated diameter, or — when it
    states none — the board's coincidence tolerance.

    THE SAME RULE :func:`copper_contact.pad_node` gives a land of unknown size,
    for the same reason: a via that declares no diameter has no geometry to be
    exact about, and the coincidence disc is exactly the credit the old
    centre-distance test gave it. A via that DOES declare one is measured as
    the copper it declares, even when that is smaller.
    """
    dia = _opt_num(via.get("diameter_mm"))
    if dia is None or not math.isfinite(dia) or dia <= 0.0:
        return unknown_radius_mm
    return dia / 2.0


# ---------------------------------------------------------------------------
# The four checks.
# ---------------------------------------------------------------------------


def _check_wrong_net_pad(segs, pads, clr) -> list[dict]:
    """Check A — a trace within ``clr`` of a foreign-net pad, reported wherever
    along the run it happens.

    TWO PASSES OVER ONE FAULT, split by which pads each owns so neither can
    double-report the other's: the ENDPOINT pass owns every pad whose center is
    within ``clr`` of ``seg.a`` or ``seg.b``, the ALONG-SEGMENT pass owns all
    the rest. Both emit ``wrong_net_pad`` — the physical fault is the same short
    and consumers key off the type — and ``at`` says which stretch it is (an
    endpoint coordinate vs. the closest point on the run).

    A FOREIGN PAD IS REPORTED WHETHER OR NOT THE END ALSO LANDS CORRECTLY.
    Landing on its own pad says the trace reached its destination; it says
    nothing about the other net's land sitting within clearance of that same
    point, and that land is shorted either way. Vetoing the whole endpoint on
    the strength of the correct landing hid the short from both passes at once
    — the along-segment pass defers every pad near an end to this one.

    MEASURE: the run's swept copper to the pad's LAND, edge to edge, through
    the shared contact predicate (:func:`copper_contact.node_gap`) — still at
    ``clr``, so this stays a clearance-scale check and not a bare touch test.
    Reading the LAND rather than the pad CENTRE is what makes the finding about
    the copper that is actually shorted: a wide land is reported from its edge,
    and a hole with NO copper (an unplated mounting hole, whose footprint still
    writes ``*.Cu``) is reported never, because there is nothing there to short
    to.
    """
    findings: list[dict] = []
    seen_at_ends: set = set()
    seen_along: set = set()
    for seg in segs:
        for pt in (seg.a, seg.b):
            # EVERY foreign pad crowding this end, not just the nearest one. An
            # end wedged between two foreign lands shorts to BOTH, and naming
            # one of them told the reader to move the trace far enough to clear
            # that one — which the other still forbids. Ordered by distance so
            # the nearest still reads first.
            end = seg.end_node(pt)
            foreign = [p for p in pads
                       if p.net != seg.net and p.contact is not None
                       and copper_contact.nodes_within(end, p.contact, clr)]
            for pad in sorted(foreign,
                              key=lambda p: (copper_contact.node_gap(end, p.contact),
                                             str(p.ref), str(p.pin))):
                key = (seg.net, _round_pt(pt), pad.ref, pad.pin)
                if key in seen_at_ends:
                    continue
                seen_at_ends.add(key)
                findings.append({
                    "type": "wrong_net_pad",
                    "net": seg.net,
                    "at": [round(pt[0], 3), round(pt[1], 3)],
                    "pad": {"ref": pad.ref, "pin": pad.pin, "net": pad.net},
                })
        swept = seg.node()
        ends = (seg.end_node(seg.a), seg.end_node(seg.b))
        for pad in pads:
            if pad.net == seg.net or pad.contact is None:
                continue
            if not copper_contact.nodes_within(swept, pad.contact, clr):
                continue
            if any(copper_contact.nodes_within(e, pad.contact, clr) for e in ends):
                continue  # the endpoint pass owns this pad
            # The report still names a point ON THE RUN, which is what a router
            # has to move; the gap that decided the finding is land-to-copper.
            at = _closest_point_on_segment(pad.pt, seg.a, seg.b)
            # One row per (segment, pad): the segment by its authored geometry
            # rather than by identity, so a duplicated trace cannot report the
            # same short twice. A pad on a shared polyline VERTEX is not
            # double-billed either — it is within clr of both segments' shared
            # endpoint, so both hand it to the endpoint pass, which dedupes on
            # the point.
            #
            # THE ENDPOINT PAIR IS SORTED, because a segment is the same copper
            # whichever way its two ends are written: A->B and B->A keyed
            # differently, so a board carrying both spellings of one run
            # reported the foreign land it crosses twice.
            key = (seg.net, seg.layer) + tuple(sorted(
                (_round_pt(seg.a), _round_pt(seg.b)))) + (pad.ref, pad.pin)
            if key in seen_along:
                continue
            seen_along.add(key)
            findings.append({
                "type": "wrong_net_pad",
                "net": seg.net,
                "at": [round(at[0], 3), round(at[1], 3)],
                "pad": {"ref": pad.ref, "pin": pad.pin, "net": pad.net},
            })
    return findings


def _check_crossings(segs) -> list[dict]:
    findings: list[dict] = []
    seen: set = set()
    n = len(segs)
    for i in range(n):
        s1 = segs[i]
        for j in range(i + 1, n):
            s2 = segs[j]
            if s1.net == s2.net or s1.layer != s2.layer:
                continue
            if not _segments_intersect(s1.a, s1.b, s2.a, s2.b):
                continue
            pt = _intersection_point(s1.a, s1.b, s2.a, s2.b)
            # DEDUPE INCLUDES THE LOCATION (019f9cc386b6 cold review, sev 1).
            # It used to be (net-pair, layer) only, so two shorts between the
            # SAME pair on the SAME layer at DIFFERENT places collapsed into one
            # finding — and, because the surviving finding is byte-identical to
            # the other, a genuinely NEW short became indistinguishable from a
            # pre-existing one and was cancelled as baseline by
            # ir_connectivity.partition_findings. A finding now means what it
            # appears to mean: one short, at one place.
            #
            # The rounding matches the "at" field the finding reports (and
            # _check_dangling's own keying), so two segments of one polyline
            # meeting the same foreign trace at a shared vertex still produce a
            # single finding rather than one per segment.
            key = tuple(sorted([str(s1.net), str(s2.net)])) + (s1.layer,) \
                + _round_pt(pt)
            if key in seen:
                continue  # dedupe: one finding per (net-pair, layer, location)
            seen.add(key)
            findings.append({
                "type": "crossing",
                "nets": [key[0], key[1]],
                "layer": s1.layer,
                "at": [round(pt[0], 3), round(pt[1], 3)],
            })
    return findings


def _check_dangling(segs, pads, vias, clr, pours: dict) -> list[dict]:
    """``pours`` maps a net name to its filled pour regions (see
    :mod:`zone_copper`); a net with no entry has no plane, or none that could be
    measured."""
    findings: list[dict] = []
    # Per-net endpoint degree (endpoints authored to the same coord coincide).
    by_net: dict = defaultdict(list)
    for seg in segs:
        by_net[seg.net].append(seg)

    for net, net_segs in by_net.items():
        degree: dict = defaultdict(int)
        for seg in net_segs:
            degree[_round_pt(seg.a)] += 1
            degree[_round_pt(seg.b)] += 1
        seen: set = set()
        for seg in net_segs:
            for pt in (seg.a, seg.b):
                rp = _round_pt(pt)
                if degree[rp] != 1:
                    continue  # junction, not a leaf
                if rp in seen:
                    continue
                # Any pad (any net) -> copper-connected (short, not open).
                #
                # THE PAD CREDIT IS THE SHARED CONTACT PREDICATE: this end's own
                # swept copper against the pad's land (copper_contact), so a
                # wide run landing off-centre, an end anywhere on a big exposed
                # pad, and a rotated roundrect land all read as landed — and an
                # end that genuinely stops short of the copper still reads as
                # open. The END cap is measured, not the whole segment, so
                # copper at the far end cannot credit this one.
                #
                # DEPENDENCY, stated because this check is net-BLIND on purpose
                # (cold review of the CPN1 repair round): a foreign-net pad or
                # via that suppresses a dangling finding here is itself either
                # touching this net's copper (a short — check A) or within
                # clearance of it (a geometric clearance violation — GC2), so
                # SOME check fires. That holds only when the geometric DRC runs
                # too. run_drc ALONE is topology-only and will read such an
                # endpoint as clean; the promote gate composes both, which is
                # what makes the silence here safe rather than merely quiet.
                end = seg.end_node(pt)
                if any(copper_contact.nodes_touch(end, p.contact)
                       for p in pads if p.contact is not None):
                    continue
                # A BARREL IS COPPER WITH EXTENT, so this asks the contact
                # predicate, not a centre distance: an end that stops on the
                # far side of a via's annulus is landed on it, and an end that
                # merely comes within clearance of a bare point is not.
                if any(copper_contact.nodes_touch(end, v.contact) for v in vias):
                    continue
                # POUR CREDIT — SAME NET ONLY, unlike the pad credit above.
                # The pad credit can be net-blind because a foreign pad touching
                # this copper is itself reported (a short by check A, a clearance
                # violation by GC2). NOTHING here reports a trace end that stops
                # inside a FOREIGN plane — check A compares traces to pads only —
                # so crediting one would turn a real defect into silence. An end
                # in the wrong plane keeps reading as an open until the geometric
                # DRC names it as the short it is.
                if any(copper_contact.nodes_touch(end, region)
                       for region in pours.get(net, ())):
                    continue
                # T-junction credit: on the interior of another same-net segment.
                if any(_point_on_segment_interior(pt, o.a, o.b, MERGE_EPS_MM)
                       for o in net_segs if o is not seg):
                    continue
                seen.add(rp)
                findings.append({
                    "type": "dangling_endpoint",
                    "net": net,
                    "at": [round(pt[0], 3), round(pt[1], 3)],
                })
    return findings


def _check_layer_change(segs, pads, vias, clr) -> list[dict]:
    findings: list[dict] = []
    th_pads = [p for p in pads if p.through_hole]

    by_net: dict = defaultdict(list)
    for seg in segs:
        by_net[seg.net].append(seg)

    for net, net_segs in by_net.items():
        by_layer: dict = defaultdict(list)
        for s in net_segs:
            by_layer[s.layer].append(s)
        if len(by_layer) < 2:
            continue  # single-layer net can't change layers
        # A layer hand-off is a segment ENDPOINT on one layer coincident with
        # a segment ENDPOINT on ANOTHER layer (the routing terminates on one
        # layer and resumes on the other at that exact point). Endpoint-on-
        # INTERIOR overlaps are NOT transitions — different layers overlap
        # freely and only connect where there is a via or a through-hole pad,
        # so treating an overlap as a required via reports a false missing-via.
        #
        # Epoch GA-3: generalized from the top/bottom split to EVERY layer
        # pair the net occupies. Pair order is stack order (the board's own
        # sequence of first appearance is not stable, so sort by canonical
        # name with the outer pair anchored); one meetings dict per net keeps
        # a three-layer junction point a single finding, not one per pair. On
        # a 2-layer board this is byte-identical to the old top-vs-bottom
        # walk: one pair, top as the reference end-set, bottom iterated.
        order = {"top": 0, "bottom": 10 ** 9}
        layer_keys = sorted(
            by_layer,
            key=lambda lid: (order.get(
                lid, _layers.inner_layer_index(lid) or 10 ** 6), lid))
        meetings: dict = {}  # rounded point -> raw point
        for i in range(len(layer_keys)):
            ref_ends = {p for s in by_layer[layer_keys[i]] for p in (s.a, s.b)}
            for j in range(i + 1, len(layer_keys)):
                for bs in by_layer[layer_keys[j]]:
                    for bp in (bs.a, bs.b):
                        for tp in ref_ends:
                            if _dist(bp, tp) <= MERGE_EPS_MM:
                                meetings.setdefault(_round_pt(bp), bp)

        for pt in meetings.values():
            if any(_dist(pt, v) <= clr for v in vias):
                continue
            if any(_dist(pt, p.pt) <= clr for p in th_pads):
                continue
            findings.append({
                "type": "layer_change_no_via",
                "net": net,
                "at": [round(pt[0], 3), round(pt[1], 3)],
            })
    return findings


# ---------------------------------------------------------------------------
# Connectivity COMPLETENESS — HITL-4 (docs/llm-ergonomics.md F2).
#
# The four checks above are all VIOLATION detectors: they can only report
# copper that is WRONG, never copper that is MISSING. On the live smart-remote
# round that made "clean" a lie by omission — net VCC_5V (D1.1→U1.21) had ZERO
# copper on the board and the connectivity summary had no vocabulary to say
# so; the owner found the open by eye. This section gives the summary that
# vocabulary. It deliberately does NOT change what `clean` means (no shorts /
# mismatches, exactly as before — existing consumers must not flip); it adds
# `complete` + the lists beside it.
#
# Same centerline scope as everything else in this module: pad centers and
# trace centerlines, the kernel's own coincidence credits. A ZONE-carrying net
# is counted as having copper (a pour IS copper) but the kernel cannot judge
# POUR connectivity at all — so such a net is reported INDETERMINATE
# ({net, reason: "zone_copper"}; census correction 019fd5fdeef3b), never
# auto-complete (the pre-fix behaviour: "has a zone => complete", a false
# complete over copper nobody measured) and never falsely "partial".
#
# `complete` is TRI-STATE since 019fd5fdeef3d: True = every in-scope
# multi-pin net fully connected AND none indeterminate; False = any
# missing_copper or partial; None = nothing missing/partial but >=1
# indeterminate net (the census cannot vouch for the whole scope). Every
# census output also carries `approximate: True` — a standing honesty label
# for the centerline basis (coincidence credits over pad centers, not
# geometric copper).
# ---------------------------------------------------------------------------


# Board.fabrication_stage tokens. The Go mirror is internal/board/board.go's
# FabStage* constants, and internal/board/validate.go is what REFUSES a value
# outside this set — this module never sees an unknown one on a board that
# passed the write gate, and treats one as "routed" if it somehow does, which
# is the conservative direction (a defect stays a defect).
FAB_STAGE_ROUTED = "routed"
FAB_STAGE_ROUTING_DEFERRED = "routing_deferred"
FAB_STAGE_VIAS_ONLY = "vias_only"


def fabrication_stage(board: dict) -> str:
    """This board's declared manufacturing intent, "routed" when it declares
    none. Absent and "routed" are the same board (DCR 01a0033a12a9 change 3)."""
    stage = (board or {}).get("fabrication_stage")
    if isinstance(stage, str) and stage:
        return stage
    return FAB_STAGE_ROUTED


def routing_is_deferred(board: dict) -> bool:
    """Whether this board's stage says its nets are MEANT to be unrouted.

    THE ONE PREDICATE behind that question — the Python mirror of
    board.Board.RoutingIsDeferred — so a future deferred stage cannot leave one
    consumer branching on a stale list of tokens. Every caller asks this rather
    than comparing ``fabrication_stage`` to a literal.
    """
    return fabrication_stage(board) in (
        FAB_STAGE_ROUTING_DEFERRED, FAB_STAGE_VIAS_ONLY)


def _board_clearance(board: dict) -> float:
    """The board's coincidence tolerance — the same derivation run_drc uses."""
    dr = board.get("design_rules") or {}
    clr = DEFAULT_COINCIDENT_MM
    if isinstance(dr, dict):
        c = _opt_num(dr.get("clearance_mm"))
        if c is not None and c > 0:
            clr = c
    return clr


def _net_pin_groups(net: str, pads: list, segs: list, vias: list,
                    clr: float, regions: list | None = None) -> int:
    """How many disconnected pin ISLANDS this net's copper leaves, >= 1.

    ``regions`` are this net's FILLED pour regions (:mod:`zone_copper`). They
    are union-find members like any other conductor — the plane is copper, and
    on a board whose return path is the plane it is the copper that joins most
    of the net.

    Union-find over the net's own pads + trace segments, joined by the SAME
    credits the violation checks above extend (a finding and a completeness
    verdict must not disagree about what "touches" means):

      * a segment whose swept copper reaches a pad's LAND joins pad<->segment,
        through the shared contact predicate (:mod:`copper_contact`) the
        dangling credit also reads. One call covers landing ON the pad and
        running THROUGH it: same-net copper driven straight across a land is
        physically connected copper and needs no separate interior test;
      * two segments join at COINCIDENT endpoints (within
        COPPER_COINCIDENT_EPS_MM — NOT clearance; see the constant's rationale
        for the census correction 019fd5fdeef3a and the pad/via asymmetry),
        or where one's endpoint lies on the other's interior (the T-junction
        credit, same epsilon);
      * two SAME-LAYER segments that properly INTERSECT (an X-crossing with no
        shared endpoint) join — touching copper on one layer IS connected
        copper (census correction 019fd5fdeef3c; a same-net plus-sign pair is
        one island, not two). Cross-layer crossings earn NO such credit —
        different layers overlap freely and only connect at a via/TH pad;
      * a POUR REGION joins any pad or segment its copper reaches, through the
        same contact predicate, and joins a via whose barrel reaches it. Two
        regions of one net join where they overlap (same-net pours may overlap;
        each fills independently);
      * a via joins every same-net pad, segment and pour region its BARREL
        reaches, through the same contact predicate — a barrel sitting on a
        run's interior is copper on that run, which is how a probe pad is
        strapped to a plane. The harvest carries each via's declared NET (see
        _harvest_vias), and that is what keeps a FOREIGN conductor from joining
        this net's islands.

    Segments on different layers joined at a COINCIDENT point are joined here
    without demanding the via: check D (layer_change_no_via) already reports
    that fault, and double-billing it as ALSO "partial" would report one
    defect as two.
    """
    net_pads = [p for p in pads if p.net == net]
    if len(net_pads) < 2:
        return 1  # one pin (or none harvested) cannot be an island count > 1
    net_segs = [s for s in segs if s.net == net]
    net_regions = list(regions or ())

    n_pads = len(net_pads)
    parent = list(range(n_pads + len(net_segs) + len(net_regions)))

    def find(i: int) -> int:
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    def union(a: int, b: int) -> None:
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[rb] = ra

    seg_node = n_pads
    region_node = n_pads + len(net_segs)
    # Built ONCE: the pad/region sweeps below and the via loop at the end all
    # measure against the same swept copper.
    seg_nodes = [seg.node() for seg in net_segs]
    for ri, region in enumerate(net_regions):
        for pi, pad in enumerate(net_pads):
            if pad.contact is not None and copper_contact.nodes_touch(
                    region, pad.contact):
                union(pi, region_node + ri)
        for rj in range(ri + 1, len(net_regions)):
            if copper_contact.nodes_touch(region, net_regions[rj]):
                union(region_node + ri, region_node + rj)
    for si, seg in enumerate(net_segs):
        swept = seg_nodes[si]
        for pi, pad in enumerate(net_pads):
            if pad.contact is None:
                continue
            # ONE call covers both ways copper reaches a land: an END on it, and
            # a run driven THROUGH it. A stadium-to-land distance does not care
            # which stretch of the run is nearest, so the pass-through tap needs
            # no separate interior test — and the layer check rides inside the
            # predicate rather than being asked again here.
            if copper_contact.nodes_touch(swept, pad.contact):
                union(pi, seg_node + si)
        for ri, region in enumerate(net_regions):
            if copper_contact.nodes_touch(swept, region):
                union(region_node + ri, seg_node + si)
        for sj in range(si + 1, len(net_segs)):
            other = net_segs[sj]
            # Copper-copper credits at COINCIDENCE epsilon, not clearance
            # (019fd5fdeef3a — see COPPER_COINCIDENT_EPS_MM), plus the
            # same-layer proper-intersection credit (019fd5fdeef3c). The
            # intersect predicate subsumes exact shared endpoints and
            # collinear overlap on the same layer; the epsilon terms remain
            # load-bearing for NEAR-coincident endpoints and for cross-layer
            # hand-offs (which check D bills separately — comment above).
            eps = COPPER_COINCIDENT_EPS_MM
            if (_dist(seg.a, other.a) <= eps or _dist(seg.a, other.b) <= eps
                    or _dist(seg.b, other.a) <= eps
                    or _dist(seg.b, other.b) <= eps
                    or _point_on_segment_interior(seg.a, other.a, other.b, eps)
                    or _point_on_segment_interior(seg.b, other.a, other.b, eps)
                    or _point_on_segment_interior(other.a, seg.a, seg.b, eps)
                    or _point_on_segment_interior(other.b, seg.a, seg.b, eps)
                    or (seg.layer == other.layer
                        and _segments_intersect(seg.a, seg.b,
                                                other.a, other.b))):
                union(seg_node + si, seg_node + sj)
    for v in vias:
        # OWNERSHIP GATE (Codex review 1086 finding 5). A via explicitly on a
        # DIFFERENT net is a different conductor: it may touch this net's
        # copper (that is a short, and GC2's business), but it does not JOIN
        # this net's islands, and counting it did — turning two disconnected
        # islands into a "complete" net. That mattered beyond reporting:
        # `indeterminate` gates promotion, so a false complete REMOVED a
        # promote refusal.
        #
        # A NETLESS via still unions, deliberately: an undeclared via is
        # physically a barrel joining whatever copper it lands on, so refusing
        # it would invent a disconnection rather than avoid inventing a
        # connection. Only an explicit mismatch is excluded.
        if v.net is not None and v.net != net:
            continue
        # ONE PREDICATE for all three, against the barrel's real copper. The
        # segment credit used to compare the via CENTRE with the two segment
        # ENDPOINTS, so a via dropped anywhere along a run's interior — the
        # ordinary way a test point is strapped to a plane — joined nothing,
        # and its net reported an island that the copper does not have.
        touching = [seg_node + si for si, node in enumerate(seg_nodes)
                    if copper_contact.nodes_touch(v.contact, node)]
        touching += [pi for pi, pad in enumerate(net_pads)
                     if pad.contact is not None
                     and copper_contact.nodes_touch(v.contact, pad.contact)]
        touching += [region_node + ri
                     for ri, region in enumerate(net_regions)
                     if copper_contact.nodes_touch(v.contact, region)]
        for node in touching[1:]:
            union(touching[0], node)

    return len({find(pi) for pi in range(n_pads)})


def connectivity_completeness(board: dict, scope_nets=None, *,
                              pours: dict | None = None,
                              pour_reason: str | None = None) -> dict:
    """Which in-scope nets are missing or only partially wired.

    ``pours``/``pour_reason`` are :func:`zone_copper.pour_nodes`' two halves,
    passed in by a caller that already computed them (``run_drc`` does) so one
    check costs one fill; computed here when they are not.

    HITL-4 (docs/llm-ergonomics.md F2). ``scope_nets`` narrows the census to
    the nets a run was ASKED about (``None`` = every net the board declares —
    the standalone whole-board DRC, and any unscoped route). Returns::

        {"complete": bool | None,    # tri-state — module note (019fd5fdeef3d):
                                     #   True  = all connected, none indeterminate
                                     #   False = any missing_copper or partial
                                     #   None  = only indeterminate stands between
                                     #           the scope and "complete"
         "missing_copper": [name],   # >=2-pin nets with ZERO copper (no trace,
                                     #   no netted via, no zone)
         "partial": [{"net": name,   # copper exists but leaves > 1 pin island
                      "pin_groups": k}],
         "indeterminate": [{"net": name,   # copper the kernel cannot judge
                            "reason": "zone_copper",
                            "detail": str}],  # why the pour fill is missing
         "fabrication_stage": str,   # the board's DECLARED intent ("routed"
                                     #   when it declares none)
         "routing_deferred": bool,   # derived: does that stage say these nets
                                     #   are MEANT to be unrouted? Branch on
                                     #   this, never on the token
         "expected_incomplete": bool,# deferred AND something is unrouted —
                                     #   the label that earns a True `complete`
                                     #   over a non-empty missing_copper
         "approximate": True}        # standing centerline-basis honesty label

    DECLARED INTENT (DCR 01a0033a12a9 change 3). On a board whose stage defers
    routing, unrouted nets are the JOB, not a defect, so `complete` is True and
    `expected_incomplete` says why. The lists are still fully populated — the
    stage reclassifies them, it never hides them, and the violation checks in
    :func:`run_drc` are untouched because they report copper that is WRONG
    rather than copper that is ABSENT.

    Every key is ALWAYS present here (this is the internal census; reply
    surfaces apply their own absent-when-empty conventions). Nets with fewer
    than two pins are never incomplete — there is nothing to connect.
    Zone-carrying nets count as having copper (never ``missing_copper``). A pour
    whose FILL was computed is measured like any other copper and its net is
    judged for real; only a pour whose fill could NOT be computed leaves its net
    INDETERMINATE, and then the row says why (:mod:`zone_copper`).
    """
    clr = _board_clearance(board)
    pads = _harvest_pads(board)
    segs = _harvest_segments(board)
    vias = _harvest_vias(board)
    if pours is None or pour_reason is None:
        pours, pour_reason = zone_copper.pour_nodes(board)

    pin_counts: dict[str, int] = {}
    for net in _list(board.get("nets")):
        if isinstance(net, dict) and isinstance(net.get("name"), str):
            pin_counts[net["name"]] = len(_list(net.get("pins")))

    trace_nets = {s.net for s in segs}
    # COPPER POURS ONLY — a keepout emits no copper, so a net named by one has
    # gained nothing. zone_copper is the one reader of that distinction.
    zone_nets = zone_copper.zone_nets(board)
    # ONE reader of via ownership. This used to re-read board["vias"] directly
    # with its own truthiness rule while the harvest applied a stricter
    # non-empty-str rule — two readers of one fact, and they disagreed: a via
    # carrying a non-string net (e.g. `net: 123`) was "netless" to the census
    # gate but not counted here. Both now come off the harvested records.
    netted_via_nets = {v.net for v in vias if v.net}

    missing: list[str] = []
    partial: list[dict] = []
    indeterminate: list[dict] = []
    for name in sorted(pin_counts):
        if scope_nets is not None and name not in scope_nets:
            continue
        if pin_counts[name] < 2:
            continue
        if not (name in trace_nets or name in zone_nets
                or name in netted_via_nets):
            missing.append(name)
            continue
        groups = _net_pin_groups(name, pads, segs, vias, clr,
                                 pours.get(name))
        if name in zone_nets and pour_reason:
            # THE FILL COULD NOT BE COMPUTED, so nothing about this plane was
            # measured. Islands the pour MIGHT bridge stay unjudged — never
            # falsely "partial", never auto-complete. When the trace+via graph
            # alone already joins every pin the net is COMPLETE regardless:
            # copper can only ADD connections, so an unmeasured pour cannot
            # change that verdict.
            if groups > 1:
                indeterminate.append({"net": name, "reason": "zone_copper",
                                      "detail": pour_reason})
            continue
        if groups > 1:
            partial.append({"net": name, "pin_groups": groups})

    # Tri-state `complete` (019fd5fdeef3d): a defect anywhere is False even
    # when other nets are indeterminate (a known defect outranks an unknown);
    # indeterminate alone withholds the True a nobody-measured pour cannot
    # earn.
    #
    # DECLARED INTENT OUTRANKS ALL THREE (DCR 01a0033a12a9 change 3). On a board
    # whose stage defers routing, "this net has no copper" is not a defect — it
    # is the job. A via-only board has EVERY net missing by design (the
    # fiber-laser customer drills first and lases the runs later), and before
    # this the census had no vocabulary for that: the correct board read as a
    # wall of incompleteness, indistinguishable from one abandoned half-routed.
    #
    # NOTHING IS SUPPRESSED, and that distinction is the whole design. Every
    # unrouted, fragmented and unjudgeable net is still computed and still
    # listed below; the stage rides in the same dict, so no reader can see the
    # verdict without seeing why it is what it is. Only the classification of
    # those lists changes — defect vs intended — which is a question about
    # INTENT that nothing but the board can answer.
    #
    # THE VIOLATION CHECKS ARE UNTOUCHED. run_drc's shorts, crossings, dangling
    # endpoints and layer-change-without-via all still fire on a deferred board,
    # because those report copper that is WRONG, not copper that is ABSENT. A
    # stage excuses only the absence.
    deferred = routing_is_deferred(board)
    if deferred:
        complete: bool | None = True
    elif missing or partial:
        complete = False
    elif indeterminate:
        complete = None
    else:
        complete = True
    return {"complete": complete,
            "missing_copper": missing,
            "partial": partial,
            "indeterminate": indeterminate,
            "fabrication_stage": fabrication_stage(board),
            # The DERIVED question, beside the raw declaration. Consumers branch
            # on this rather than re-deriving it from the token, which is what
            # keeps a future stage from needing an edit in every reply surface.
            "routing_deferred": deferred,
            # Present ONLY on a deferred board, and it is the honesty label that
            # earns the True above: these nets are unrouted and that is intended.
            # A reader that ignores it still sees the lists.
            "expected_incomplete": bool(deferred and (missing or partial)),
            "approximate": True}


def net_pin_group_count(board: dict, net: str) -> int | None:
    """Pin-island count for ONE net over this board's copper, or None.

    Epoch UX2 station 6 (docket 019fde367b24) — the census kernel exposed
    per-net so a route reply can report its own island DELTA ("merges N
    islands") instead of leaving the caller with a bare whole-board count.
    Same union-find + credits as :func:`connectivity_completeness` (which
    stays the one classifier — this answers a count question, not a
    missing/partial/indeterminate one). None when the census cannot judge the
    net: fewer than two pins (nothing to connect), or a pour on it whose FILL
    could not be computed (nothing was measured, so there is no count to
    report — mirrors the classifier's indeterminate row)."""
    pin_count = 0
    for n in _list(board.get("nets")):
        if isinstance(n, dict) and n.get("name") == net:
            pin_count = len(_list(n.get("pins")))
    if pin_count < 2:
        return None
    pours, pour_reason = zone_copper.pour_nodes(board)
    if pour_reason and net in zone_copper.zone_nets(board):
        return None
    return _net_pin_groups(net, _harvest_pads(board), _harvest_segments(board),
                           _harvest_vias(board), _board_clearance(board),
                           pours.get(net))


# ---------------------------------------------------------------------------
# Public entry point.
# ---------------------------------------------------------------------------


def run_drc(board: dict) -> dict:
    """Run all connectivity/topology checks over a canonical board dict.

    Returns {ok, scope, verifies_geometry, findings, counts}. `ok` reports that
    the check RAN (structured findings are data, not an error); callers inspect
    counts / findings to decide pass/fail. `scope` is "connectivity" and
    `verifies_geometry` is False: these checks read pad centers + trace
    centerlines only, so a zero-finding result is NOT a geometric/fab-clean
    verdict. Geometric-copper DRC + DFM are reported separately once resolved
    geometry exists (ResolvedBoard IR).
    """
    clr = _board_clearance(board)

    pads = _harvest_pads(board)
    segs = _harvest_segments(board)
    vias = _harvest_vias(board)
    # ONE fill per run, shared by the dangling credit and the census below, so
    # the two cannot disagree about what the plane conducts.
    pours, pour_reason = zone_copper.pour_nodes(board)

    findings: list[dict] = []
    findings += _check_wrong_net_pad(segs, pads, clr)
    findings += _check_crossings(segs)
    findings += _check_dangling(segs, pads, vias, clr, pours)
    findings += _check_layer_change(segs, pads, vias, clr)

    counts = {
        "wrong_net_pad": 0,
        "crossing": 0,
        "dangling_endpoint": 0,
        "layer_change_no_via": 0,
    }
    for f in findings:
        counts[f["type"]] = counts.get(f["type"], 0) + 1

    # HITL-4 (docs/llm-ergonomics.md F2): the standalone method's reply says
    # "incomplete" too — whole-board scope here (scope_nets=None). Additive
    # keys beside the unchanged findings/counts; `partial`/`indeterminate`
    # follow the absent-key contract (an empty list is not a fact worth a
    # key). `complete` is tri-state and the census carries its standing
    # `approximate` honesty label (work item 019fd5fdeef3, DCR 019fd5fd9084).
    completeness = connectivity_completeness(board, pours=pours,
                                             pour_reason=pour_reason)

    out = {
        "ok": True,
        # HONEST SCOPE (docket 019f7abf7e7b): connectivity/topology over pad
        # centers + trace centerlines — NOT geometric copper DRC. A zero-finding
        # result does NOT mean geometrically or fab clean.
        "scope": "connectivity",
        "verifies_geometry": False,
        "findings": findings,
        "counts": counts,
        "complete": completeness["complete"],
        "missing_copper": completeness["missing_copper"],
        "approximate": True,
    }
    if completeness["partial"]:
        out["partial"] = completeness["partial"]
    if completeness["indeterminate"]:
        out["indeterminate"] = completeness["indeterminate"]
    # DECLARED INTENT rides with the verdict it produced, never separately — a
    # `complete: True` over a non-empty missing_copper is only honest if the
    # reason is in the same reply. Absent-key convention for the default board:
    # a "routed" board says nothing new here, so no existing reply shape moves.
    if completeness["routing_deferred"]:
        out["fabrication_stage"] = completeness["fabrication_stage"]
        out["routing_deferred"] = True
        out["expected_incomplete"] = completeness["expected_incomplete"]
    return out
