"""Connectivity/topology check over a canonical board model.

NOT a geometric copper DRC. Every check below reads pad CENTERS and trace
CENTERLINES only — never copper extents, pad shapes, trace widths, or mask
geometry — so it CANNOT verify clearances. A zero-finding result means "no
connectivity/topology fault found", NOT "geometrically or fab clean". Real
geometric-copper DRC + manufacturer DFM need resolved pad/trace geometry (the
ResolvedBoard IR, docket 019f7abf55c2) and are reported separately (019f7abf7e7b).

Pure Python, no KiCad binary — operates on the same canonical board dict
(``board_model.load_board``) that gerber.py / kicad.py consume. Four connectivity checks:

  A. wrong_net_pad     — a trace endpoint coincident (<= clearance) with a pad of
                         a DIFFERENT net  -> short / mis-route.
  B. crossing          — two trace segments on the SAME layer, DIFFERENT nets,
                         that intersect  -> deduped per (net-pair, layer).
  C. dangling_endpoint — a LEAF trace endpoint (degree 1 in its net) that reaches
                         no pad, via, or other same-net copper  -> open.
  D. layer_change_no_via — a net's top-side and bottom-side copper meet at a point
                         that is neither a via nor a through-hole pad -> missing via.

FALSE-POSITIVE GUARDS (mandatory — a DRC that cries wolf is useless):

  * T-junction credit: a leaf endpoint lying on the INTERIOR of another same-net
    segment counts as connected (not just shared endpoints) — else GND taps read
    as opens.
  * Any-pad credit for dangling: an endpoint touching *any* pad (even a wrong-net
    one) is copper-connected, so it is a short (check A), never an open (check C).
    This also means a leaf ending on ANY pad of its component is never a false
    open — same-component same-net pads (module internal nets, e.g. an ESP32's
    several GND pins) are internally connected and stay quiet.

DRY: pad absolute positions reuse geometry.rotate_local_offset (KiCad CW
convention, math.radians(-deg)) so DRC and the fabrication compiler agree
byte-for-byte on where a rotated pad lands. This module owns only the net<->pad
wiring and the segment geometry that gerber has no need for.
"""

from __future__ import annotations

from collections import defaultdict
from typing import Any, NamedTuple

from .geometry import is_top as _is_top, rotate_local_offset as _rotate
from .pad_source import is_through_hole, iter_pads

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
    """True if pt lies on the STRICT interior of segment a-b (distance <= eps,
    projection parameter strictly between the endpoints). Endpoint coincidences
    are handled separately via degree counting."""
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    seg_len2 = dx * dx + dy * dy
    if seg_len2 < eps * eps:
        return False
    t = ((pt[0] - ax) * dx + (pt[1] - ay) * dy) / seg_len2
    if t <= eps or t >= 1.0 - eps:
        return False
    proj = (ax + t * dx, ay + t * dy)
    return _dist(pt, proj) <= eps


# ---------------------------------------------------------------------------
# Board -> geometry harvest.
# ---------------------------------------------------------------------------


class _Pad:
    __slots__ = ("ref", "pin", "net", "x", "y", "through_hole")

    def __init__(self, ref, pin, net, x, y, through_hole):
        self.ref = ref
        self.pin = pin
        self.net = net
        self.x = x
        self.y = y
        self.through_hole = through_hole

    @property
    def pt(self):
        return (self.x, self.y)


class _Seg:
    __slots__ = ("net", "layer", "top", "a", "b")

    def __init__(self, net, layer, top, a, b):
        self.net = net
        self.layer = layer
        self.top = top
        self.a = a
        self.b = b


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
    pads: list[_Pad] = []
    for comp in _list(board.get("components")):
        if not isinstance(comp, dict):
            continue
        ref = comp.get("ref")
        cx, cy = _num(comp.get("x_mm")), _num(comp.get("y_mm"))
        rot = _num(comp.get("rotation_deg"))
        # iter_pads PREFERS resolved comp["pads"] (real footprint pad CENTERS) and
        # otherwise reconstructs the exact per-pin fallback used inline before —
        # DRC uses only the pad center + through-hole flag (no pad SIZE), so
        # gate-OFF is a pure no-op (see pad_source).
        for pad in iter_pads(comp):
            num = str(pad.number)
            ox, oy = _rotate(pad.x, pad.y, rot)
            # is_through_hole is the SHARED predicate the two emitters also use, so
            # DRC classifies TH-vs-SMD identically (no third hand-written literal to
            # drift — bug 019f91c1420c). DRC runs iter_pads WITHOUT require_smd_size,
            # so a non-finite drill is not fail-closed here; is_through_hole's
            # isfinite guard means it is simply not counted as a through-hole (never
            # NaN-classified), matching the emitters' post-validation behaviour.
            through_hole = is_through_hole(pad)
            pads.append(_Pad(ref, num, pin_net.get((str(ref), num)),
                             cx + ox, cy + oy, through_hole))
    return pads


def _harvest_segments(board: dict) -> list[_Seg]:
    segs: list[_Seg] = []
    for tr in _list(board.get("traces")):
        if not isinstance(tr, dict):
            continue
        net = tr.get("net")
        layer = tr.get("layer")
        top = _is_top(layer)
        pts = [(_num(p.get("x_mm")), _num(p.get("y_mm")))
               for p in _list(tr.get("points")) if isinstance(p, dict)]
        for a, b in zip(pts, pts[1:]):
            segs.append(_Seg(net, layer if isinstance(layer, str) else "", top, a, b))
    return segs


class _HarvestedVia(NamedTuple):
    """A via's position plus its declared ``net`` (``None`` when unstated).

    A NAMEDTUPLE so ``v[0]`` / ``v[1]`` still read as x / y: every distance
    test here indexes rather than unpacks (:func:`_dist`), so the
    position-only consumers — check C's dangling credit and check D's
    layer-change resolution — keep working byte-for-byte unchanged while the
    ownership rides along for the one consumer that needs it, the copper
    CENSUS (see :func:`_net_pin_groups`, Codex review 1086 finding 5).
    """

    x: float
    y: float
    net: object


def _harvest_vias(board: dict) -> list[_HarvestedVia]:
    """Harvest via positions, each carrying its declared net (see below).

    A canonical via may now carry first-class from_layer/to_layer (top/bottom
    span; see pcb_data.gd / board-yaml.md), but every DRC use of a via
    (check C's dangling-endpoint credit, check D's layer_change_no_via
    resolution) only needs to know THAT a via exists at a point, not which
    two layers it bridges — on a 2-layer board every via already spans the
    full top<->bottom, which is exactly what both checks assume. This
    function never mutates board["vias"], so from_layer/to_layer are never
    dropped from the source data — they simply aren't load-bearing for these
    two checks today. If a future multi-layer board or partial (blind/buried)
    via needs a layer-aware credit, extend this to a small (x, y, from, to)
    tuple/dataclass and thread the span into checks C/D's distance tests.
    """
    out: list[_HarvestedVia] = []
    for via in _list(board.get("vias")):
        if not isinstance(via, dict):
            continue
        net = via.get("net")
        out.append(_HarvestedVia(_num(via.get("x_mm")), _num(via.get("y_mm")),
                                 net if isinstance(net, str) and net else None))
    return out


# ---------------------------------------------------------------------------
# The four checks.
# ---------------------------------------------------------------------------


def _check_wrong_net_pad(segs, pads, clr) -> list[dict]:
    findings: list[dict] = []
    seen: set = set()
    for seg in segs:
        for pt in (seg.a, seg.b):
            near = [p for p in pads if _dist(pt, p.pt) <= clr]
            if not near:
                continue
            nets_here = {p.net for p in near}
            if seg.net in nets_here:
                continue  # correctly lands on its own net's pad
            pad = min(near, key=lambda p: _dist(pt, p.pt))
            key = (seg.net, _round_pt(pt), pad.ref, pad.pin)
            if key in seen:
                continue
            seen.add(key)
            findings.append({
                "type": "wrong_net_pad",
                "net": seg.net,
                "at": [round(pt[0], 3), round(pt[1], 3)],
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


def _check_dangling(segs, pads, vias, clr) -> list[dict]:
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
                if any(_dist(pt, p.pt) <= clr for p in pads):
                    continue
                if any(_dist(pt, v) <= clr for v in vias):
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
        top_segs = [s for s in net_segs if s.top]
        bot_segs = [s for s in net_segs if not s.top]
        if not top_segs or not bot_segs:
            continue  # single-sided net can't change layers
        # A layer hand-off is a top-side segment ENDPOINT coincident with a
        # bottom-side segment ENDPOINT (the routing terminates on one layer and
        # resumes on the other at that exact point). Endpoint-on-INTERIOR
        # overlaps are NOT transitions — different layers overlap freely and
        # only connect where there is a via or a through-hole pad, so treating
        # an overlap as a required via reports a false missing-via.
        top_ends = {tp for ts in top_segs for tp in (ts.a, ts.b)}
        meetings: dict = {}  # rounded point -> raw point
        for bs in bot_segs:
            for bp in (bs.a, bs.b):
                for tp in top_ends:
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
                    clr: float) -> int:
    """How many disconnected pin ISLANDS this net's copper leaves, >= 1.

    Union-find over the net's own pads + trace segments, joined by the SAME
    credits the violation checks above extend (a finding and a completeness
    verdict must not disagree about what "touches" means):

      * a segment endpoint within ``clr`` of a pad CENTER joins pad<->segment
        (the wrong_net_pad / dangling credit, same-net restricted here);
      * a pad CENTER on a segment's interior joins too — same-net copper run
        straight across a pad is physically connected copper;
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
      * a via joins every same-net segment endpoint within ``clr`` of it —
        the harvest carries via POSITIONS only (see _harvest_vias), which is
        exactly the "a via exists here" fact layer bridging needs.

    Segments on different layers joined at a COINCIDENT point are joined here
    without demanding the via: check D (layer_change_no_via) already reports
    that fault, and double-billing it as ALSO "partial" would report one
    defect as two.
    """
    net_pads = [p for p in pads if p.net == net]
    if len(net_pads) < 2:
        return 1  # one pin (or none harvested) cannot be an island count > 1
    net_segs = [s for s in segs if s.net == net]

    n_pads = len(net_pads)
    parent = list(range(n_pads + len(net_segs)))

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
    for si, seg in enumerate(net_segs):
        for pi, pad in enumerate(net_pads):
            if (_dist(seg.a, pad.pt) <= clr or _dist(seg.b, pad.pt) <= clr
                    or _point_on_segment_interior(pad.pt, seg.a, seg.b, clr)):
                union(pi, seg_node + si)
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
        touching = [seg_node + si for si, seg in enumerate(net_segs)
                    if _dist(seg.a, v) <= clr or _dist(seg.b, v) <= clr]
        touching += [pi for pi, pad in enumerate(net_pads)
                     if _dist(pad.pt, v) <= clr]
        for node in touching[1:]:
            union(touching[0], node)

    return len({find(pi) for pi in range(n_pads)})


def connectivity_completeness(board: dict, scope_nets=None) -> dict:
    """Which in-scope nets are missing or only partially wired.

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
                            "reason": "zone_copper"}],
         "approximate": True}        # standing centerline-basis honesty label

    Every key is ALWAYS present here (this is the internal census; reply
    surfaces apply their own absent-when-empty conventions). Nets with fewer
    than two pins are never incomplete — there is nothing to connect.
    Zone-carrying nets count as having copper (never ``missing_copper``);
    they are COMPLETE when the trace+via graph alone joins every pin (zone
    copper only ever adds — epoch CPN1 narrowing) and INDETERMINATE when
    islands remain that the pour may or may not bridge (module note above).
    """
    clr = _board_clearance(board)
    pads = _harvest_pads(board)
    segs = _harvest_segments(board)
    vias = _harvest_vias(board)

    pin_counts: dict[str, int] = {}
    for net in _list(board.get("nets")):
        if isinstance(net, dict) and isinstance(net.get("name"), str):
            pin_counts[net["name"]] = len(_list(net.get("pins")))

    trace_nets = {s.net for s in segs}
    zone_nets = {z.get("net") for z in _list(board.get("zones"))
                 if isinstance(z, dict) and z.get("net")}
    # _harvest_vias deliberately drops net ownership (positions are all the
    # violation checks need); the copper CENSUS reads it off the raw dicts so
    # a netted via still counts as that net's copper.
    netted_via_nets = {v.get("net") for v in _list(board.get("vias"))
                       if isinstance(v, dict) and v.get("net")}

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
        groups = _net_pin_groups(name, pads, segs, vias, clr)
        if name in zone_nets:
            # 019fd5fdeef3b: a pour IS copper, but pour connectivity is a
            # geometry question this centerline kernel cannot answer. NARROWED
            # in epoch CPN1 (the coupon's return pour blocked its own promote):
            # when the TRACE+VIA graph ALONE already joins every pin into one
            # group, the net is COMPLETE — zone copper can only ADD connections,
            # never remove one, so the unanswerable pour question cannot change
            # the verdict. Only a zone-bearing net whose trace graph leaves
            # islands stays INDETERMINATE (the pour might bridge them, might
            # not — never falsely "partial", never auto-complete).
            if groups > 1:
                indeterminate.append({"net": name, "reason": "zone_copper"})
            continue
        if groups > 1:
            partial.append({"net": name, "pin_groups": groups})

    # Tri-state `complete` (019fd5fdeef3d): a defect anywhere is False even
    # when other nets are indeterminate (a known defect outranks an unknown);
    # indeterminate alone withholds the True a nobody-measured pour cannot
    # earn.
    if missing or partial:
        complete: bool | None = False
    elif indeterminate:
        complete = None
    else:
        complete = True
    return {"complete": complete,
            "missing_copper": missing,
            "partial": partial,
            "indeterminate": indeterminate,
            "approximate": True}


def net_pin_group_count(board: dict, net: str) -> int | None:
    """Pin-island count for ONE net over this board's copper, or None.

    Epoch UX2 station 6 (docket 019fde367b24) — the census kernel exposed
    per-net so a route reply can report its own island DELTA ("merges N
    islands") instead of leaving the caller with a bare whole-board count.
    Same union-find + credits as :func:`connectivity_completeness` (which
    stays the one classifier — this answers a count question, not a
    missing/partial/indeterminate one). None when the census cannot judge
    the net: fewer than two pins (nothing to connect), or zone copper on it
    (pour connectivity is indeterminate for this centerline kernel —
    019fd5fdeef3b's rule, mirrored)."""
    pin_count = 0
    for n in _list(board.get("nets")):
        if isinstance(n, dict) and n.get("name") == net:
            pin_count = len(_list(n.get("pins")))
    if pin_count < 2:
        return None
    for z in _list(board.get("zones")):
        if isinstance(z, dict) and z.get("net") == net:
            return None
    return _net_pin_groups(net, _harvest_pads(board), _harvest_segments(board),
                           _harvest_vias(board), _board_clearance(board))


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

    findings: list[dict] = []
    findings += _check_wrong_net_pad(segs, pads, clr)
    findings += _check_crossings(segs)
    findings += _check_dangling(segs, pads, vias, clr)
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
    completeness = connectivity_completeness(board)

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
    return out
