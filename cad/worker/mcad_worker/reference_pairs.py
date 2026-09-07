"""Exact minimum distance between two REFERENCE meshes, pair by pair.

WHAT THIS ANSWERS
"Does the OLED sit on the devkit? How close does the joystick come to the
connector?" — the off-board parts question, which the clearance verb could not
ask because it measures the evaluated solid against a reference and nothing
else. Laying parts out on a board is reference against reference, and before
this module that was done by hand from bounding boxes.

WHY IT IS A SEPARATE MODULE FROM clearance.py
Two things fall away here. There is no DSL source and no OCCT: both sides are
meshes the panel already owns, so nothing is tessellated and there is no
tessellation tolerance to quote — the only error bar is the float32 grid the
panel's blob is written on, which the panel states itself. And the request is
about PAIRS rather than about one body against a list, so the caller sends the
node inventory once and names the pairs by index; a pair-per-entry request
would carry every 64-character key twice.

What is shared is everything below the pair: the blob format, the LRU of
swept-sphere BVH trees, and the missing-key protocol. Those live in
clearance.py and are imported rather than copied, so a reference node measured
against the solid and then against another reference builds its tree once.

CONTAINMENT. A positive distance says only that the two SURFACES are apart;
a part wholly inside another measures the same air. Wherever one node's box
lies inside the other's — the only place containment is possible — the pair is
probed by ray parity (mcad_worker.containment) and a contained pair is an
overlap with no contact points; an outer mesh that is not closed leaves the
question undecidable, which the pair reports rather than passes.

CONTACT POINTS. A distance of zero says only that there is no air between the
two meshes. FCL's mesh-mesh collision names the triangles that overlap and a
point per contact, so an overlapping pair comes back with points — which is
what turns "these two touch" into "they touch HERE". The raw position FCL
hands back is a corner of one of the two intersecting triangles, not a point
of their intersection, and a corner can sit a whole triangle away from where
the meshes actually meet. Each point is therefore clamped into the box the two
meshes share, which always contains the intersection; the reported point is
"inside the overlapped region", accurate to that box and no better. Mesh-mesh
collision does not compute a penetration DEPTH; the reply carries a depth only
where FCL gives a positive one, and never invents one.
"""

from __future__ import annotations

from typing import Any, Optional

from .clearance import (ClearanceError, _require_fcl, _tree_for, arrays_for,
                        bounds_for)
from .containment import containment

#: Contacts collected for one overlapping pair. Enough to show where a part
#: has landed on another and short enough that a badly placed part does not
#: return a megabyte of triangle hits.
DEFAULT_MAX_CONTACTS = 16


def _distance(fcl, tree_a, tree_b) -> tuple[float, list, list]:
    """Minimum distance between two trees and the points realising it, world mm.

    Both trees are already in world millimetres, so both objects carry the
    identity transform and the nearest points need nothing undone.
    """
    request = fcl.DistanceRequest(enable_nearest_points=True)
    result = fcl.DistanceResult()
    value = fcl.distance(
        fcl.CollisionObject(tree_a, fcl.Transform()),
        fcl.CollisionObject(tree_b, fcl.Transform()),
        request,
        result,
    )
    if value <= 0.0:
        # Overlapping meshes have no separation; the points FCL returns then
        # describe something inside the overlap rather than a gap.
        return 0.0, [], []
    points = list(result.nearest_points or [])
    point_a = [float(v) for v in points[0]] if len(points) > 0 else []
    point_b = [float(v) for v in points[1]] if len(points) > 1 else []
    return float(value), point_a, point_b


def _shared_box(box_a, box_b):
    """The box two bounding boxes have in common, or None if they share none."""
    if box_a is None or box_b is None:
        return None
    low = [max(a, b) for a, b in zip(box_a[0], box_b[0])]
    high = [min(a, b) for a, b in zip(box_a[1], box_b[1])]
    if any(lo > hi for lo, hi in zip(low, high)):
        return None
    return low, high


def _contacts(fcl, tree_a, tree_b, limit: int,
              box=None) -> tuple[list, int, Optional[float]]:
    """Where two overlapping meshes meet: up to `limit` points, world mm.

    Returns (points, count, depth). `depth` is FCL's deepest positive
    penetration and is None when it reported none — a mesh-mesh collision
    query is not required to compute one, and a zero reported as a depth
    would read as "they just touch".

    `box` is the two meshes' SHARED BOUNDING BOX — not the overlap itself.
    FCL reports a triangle corner rather than a point of the
    triangle-triangle intersection, so a raw position can land outside the
    boxes entirely; clamping into the shared box brings such a point back to
    where the two bodies can meet at all and leaves a point that was already
    inside untouched. A clamped point can still sit in air inside that box,
    so it locates the contact to the box and no finer. With no box, the raw
    positions are passed through.
    """
    request = fcl.CollisionRequest(num_max_contacts=max(1, limit),
                                   enable_contact=True)
    result = fcl.CollisionResult()
    fcl.collide(
        fcl.CollisionObject(tree_a, fcl.Transform()),
        fcl.CollisionObject(tree_b, fcl.Transform()),
        request,
        result,
    )
    points: list = []
    depth: Optional[float] = None
    for contact in list(result.contacts or [])[:limit]:
        position = getattr(contact, "pos", None)
        if position is not None:
            point = [float(v) for v in position]
            if box is not None:
                point = [min(max(v, lo), hi)
                         for v, lo, hi in zip(point, box[0], box[1])]
            points.append(point)
        raw = float(getattr(contact, "penetration_depth", 0.0) or 0.0)
        if raw > 0.0 and (depth is None or raw > depth):
            depth = raw
    return points, len(result.contacts or []), depth


def _pair_list(targets: list, raw_pairs: Any) -> list:
    """The index pairs to measure.

    Stated pairs are taken as given. With none, every unordered pair of
    targets whose REFERENCES differ is measured: two nodes of one file are
    parts of one part, and a bracket touching its own boss is not the
    question this verb is asked.
    """
    if isinstance(raw_pairs, list) and raw_pairs:
        pairs = []
        for entry in raw_pairs:
            if not isinstance(entry, (list, tuple)) or len(entry) != 2:
                raise ClearanceError(
                    "every pair is [i, j], two indices into params.targets")
            first, second = int(entry[0]), int(entry[1])
            for index in (first, second):
                if index < 0 or index >= len(targets):
                    raise ClearanceError(
                        "pair index %d is outside params.targets" % index)
            if first != second:
                pairs.append((first, second))
        return pairs
    out = []
    for first in range(len(targets)):
        for second in range(first + 1, len(targets)):
            if str(targets[first].get("reference", "")) \
                    != str(targets[second].get("reference", "")):
                out.append((first, second))
    return out


def _side(target: dict) -> dict:
    return {
        "reference": str(target.get("reference", "")),
        "node": str(target.get("node", "")),
        "key": str(target.get("key", "")),
    }


def reference_pairs(params: dict) -> dict:
    """Measure reference nodes against each other. Worker {ok, result|error}.

    params:
      targets       [{reference, node, key, path?}] — every node in scope,
                    named once; a pair refers to them by index.
      pairs         [[i, j], ...] — optional. Omitted, every cross-reference
                    pair is measured.
      required_mm   the gap each pair is judged against. 0 grades nothing and
                    only reports the distances.
      max_contacts  contact points collected per overlapping pair.

    A target whose key is not cached and carries no path is answered with
    `missing_keys` exactly as a clearance request is, so the caller uploads
    those blobs and asks again.
    """
    targets = params.get("targets")
    if not isinstance(targets, list) or not targets:
        return _error("reference_pairs requires params.targets: the reference "
                      "nodes to measure against each other")
    targets = [entry for entry in targets if isinstance(entry, dict)]

    try:
        required_mm = float(params.get("required_mm", 0.0))
        limit = int(params.get("max_contacts", DEFAULT_MAX_CONTACTS))
    except (TypeError, ValueError) as exc:
        return _error(f"reference_pairs received a non-numeric parameter: {exc}")

    try:
        # The pairing is settled before the geometry backend is touched, so
        # "there is nothing here to pair" is answered as itself on a runtime
        # that could not load python-fcl.
        wanted = _pair_list(targets, params.get("pairs"))
        if not wanted:
            return _error("reference_pairs was given no pair to measure: with "
                          "no explicit pairs, at least two targets from "
                          "different references are needed")
        fcl = _require_fcl()

        # Only the nodes some pair actually names are built. An all-pairs
        # request over an assembly already touches every one of them; a
        # narrow one must not pay for the rest.
        needed = sorted({index for pair in wanted for index in pair})
        trees: dict = {}
        missing: list = []
        hits = 0
        for index in needed:
            key = str(targets[index].get("key", ""))
            if not key:
                return _error("every reference_pairs target needs a key")
            try:
                tree, triangles, cached = _tree_for(key, targets[index].get("path"))
            except KeyError:
                if key not in missing:
                    missing.append(key)
                continue
            hits += 1 if cached else 0
            trees[index] = (tree, triangles)
        if missing:
            return {
                "ok": True,
                "result": {
                    "checked": False,
                    "units": "mm",
                    "reason": "the worker's blob cache holds no geometry for "
                              "%d of the targets (a first sighting, or an "
                              "eviction); send those targets again with their "
                              "path and it will read them. Nothing has been "
                              "found unreadable." % len(missing),
                    "missing_keys": missing,
                    "pairs": [],
                },
            }

        pairs = []
        for first, second in wanted:
            tree_a, triangles_a = trees[first]
            tree_b, triangles_b = trees[second]
            min_mm, point_a, point_b = _distance(fcl, tree_a, tree_b)
            pair = {
                "a": _side(targets[first]),
                "b": _side(targets[second]),
                "min_mm": min_mm,
                "pass": min_mm >= required_mm and min_mm > 0.0,
                "triangles": [int(triangles_a), int(triangles_b)],
            }
            if min_mm <= 0.0:
                box = _shared_box(bounds_for(str(targets[first].get("key", ""))),
                                  bounds_for(str(targets[second].get("key", ""))))
                points, count, depth = _contacts(fcl, tree_a, tree_b, limit, box)
                pair["overlap"] = True
                pair["contact_points_mm"] = points
                pair["contact_count"] = count
                if depth is not None:
                    pair["penetration_mm"] = depth
                pair["note"] = ("no air between these two meshes — the "
                                "contact points lie in their shared BOUNDING "
                                "BOX, located to that box and no finer (a "
                                "point in it can still be in air); a "
                                "mesh-mesh collision reports no penetration "
                                "depth unless it found one")
            else:
                pair["point_a_mm"] = point_a
                pair["point_b_mm"] = point_b
                # Air between the surfaces is not air between the PARTS:
                # one may lie wholly inside the other. Asked only where one
                # box lies inside the other's, which is the only place it
                # can be true.
                key_a = str(targets[first].get("key", ""))
                key_b = str(targets[second].get("key", ""))
                verdict = containment(arrays_for(key_a), arrays_for(key_b),
                                      bounds_for(key_a), bounds_for(key_b))
                if verdict is not None:
                    pair["containment"] = verdict["containment"]
                    pair["containment_note"] = verdict["note"]
                    if verdict["containment"] != "none":
                        pair["pass"] = False
                    if verdict["containment"].endswith("_a") \
                            or verdict["containment"].endswith("_b"):
                        pair["overlap"] = True
                        pair["contact_points_mm"] = []
                        pair["contact_count"] = 0
            pairs.append(pair)
        pairs.sort(key=lambda p: (p["min_mm"], p["a"]["reference"],
                                  p["a"]["node"], p["b"]["reference"],
                                  p["b"]["node"]))
    except ClearanceError as exc:
        return _error(str(exc))

    return {
        "ok": True,
        "result": {
            "checked": True,
            "units": "mm",
            "pass": all(p["pass"] for p in pairs),
            "required_mm": required_mm,
            "pairs_measured": len(pairs),
            "cache": {"hits": hits, "misses": len(trees) - hits,
                      "entries": len(trees)},
            "engine": "python-fcl swept-sphere BVH, exact triangle-pair minimum",
            "bound": "both sides are the meshes themselves, so no "
                     "tessellation stands between the number and the "
                     "geometry; the only quantization is the float32 grid "
                     "the vertices were written on, which the caller states",
            "pairs": pairs,
        },
    }


def _error(message: str) -> dict:
    return {"ok": False, "error": {"kind": "internal", "message": message}}
