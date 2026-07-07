"""Geometric design-rule check (DRC) over a canonical board model.

Pure Python, no KiCad binary — operates on the same canonical board dict
(``board_model.load_board``) that gerber.py / kicad.py consume. Four checks:

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

DRY: pad absolute positions reuse gerber._rotate (KiCad CW convention,
math.radians(-deg)) so DRC and the fabrication compiler agree byte-for-byte on
where a rotated pad lands. This module owns only the net<->pad wiring and the
segment geometry that gerber has no need for.
"""

from __future__ import annotations

from collections import defaultdict
from typing import Any

from .gerber import _is_top, _rotate

# Tolerances (mm). COINCIDENT gates "touches a pad/via" and "meets the other
# layer"; it defaults to the board's clearance rule (same value the wrong-net
# short test uses). MERGE_EPS collapses points that are meant to be identical
# (authored to the same coordinate) for degree / meeting-point bookkeeping.
DEFAULT_COINCIDENT_MM = 0.2
MERGE_EPS_MM = 1e-3
ORIENT_EPS = 1e-9


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
        for pin in _list(comp.get("pins")):
            if not isinstance(pin, dict):
                continue
            num = str(pin.get("number"))
            ox, oy = _rotate(_num(pin.get("x_mm")), _num(pin.get("y_mm")), rot)
            drill = _opt_num(pin.get("drill_mm"))
            through_hole = drill is not None and drill > 0
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


def _harvest_vias(board: dict) -> list[tuple[float, float]]:
    out: list[tuple[float, float]] = []
    for via in _list(board.get("vias")):
        if not isinstance(via, dict):
            continue
        out.append((_num(via.get("x_mm")), _num(via.get("y_mm"))))
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
            key = tuple(sorted([str(s1.net), str(s2.net)])) + (s1.layer,)
            if key in seen:
                continue  # dedupe: one finding per (net-pair, layer)
            seen.add(key)
            pt = _intersection_point(s1.a, s1.b, s2.a, s2.b)
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
# Public entry point.
# ---------------------------------------------------------------------------


def run_drc(board: dict) -> dict:
    """Run all geometric checks over a canonical board dict.

    Returns {ok: True, findings: [...], counts: {type: n}}. `ok` reports that the
    check RAN (structured findings are data, not an error); callers inspect
    counts / findings to decide pass/fail.
    """
    dr = board.get("design_rules") or {}
    clr = DEFAULT_COINCIDENT_MM
    if isinstance(dr, dict):
        c = _opt_num(dr.get("clearance_mm"))
        if c is not None and c > 0:
            clr = c

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

    return {"ok": True, "findings": findings, "counts": counts}
