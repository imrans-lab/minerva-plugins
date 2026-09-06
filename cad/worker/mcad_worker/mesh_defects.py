"""Where a tessellation is wrong, not only how often.

A count ("2 non-manifold edges") tells a reader that the part will not slice
and nothing at all about which feature to edit. This module walks the same
welded tessellation the counts come from and keeps the geometry of the
offending elements: the world position of every non-manifold edge, and a
capped, evenly-spread sample of degenerate faces.

Vertices arrive one per face corner (normals differ across an edge), so two
faces sharing an edge index different vertices at the same point. Everything
here works on positions welded to six decimals — the same weld the panel's
outline pass uses — or a closed solid reads as entirely open.

Degenerate faces are NOT defects by themselves: a curved face tessellates
into slivers whose corners round onto each other, and a part with hundreds of
them prints perfectly. Non-manifold edges are real: three or more faces
meeting on one edge is geometry no slicer can interpret. The report says so in
the note it carries.
"""

from __future__ import annotations

# Locations are a diagnostic, not a dataset: enough to find the feature that
# made them, few enough that the reply stays small on a part with hundreds.
NON_MANIFOLD_SITE_CAP = 64
DEGENERATE_SITE_CAP = 32

_NON_MANIFOLD_NOTE = (
    "three or more faces meet on this edge; a slicer cannot interpret it. "
    "Positions are model millimetres, the same frame as the bounding box."
)
_DEGENERATE_NOTE = (
    "degenerate counts include tessellation slivers on curved faces and are "
    "not defects by themselves — a part with hundreds of them prints. Sites "
    "are a spread sample, not the whole set."
)

_WELD_DECIMALS = 6


def _round(value: float) -> float:
    """Trim float noise out of a reported coordinate."""
    return round(float(value), 4)


def _centroid(points: list) -> list:
    n = float(len(points))
    return [
        _round(sum(p[0] for p in points) / n),
        _round(sum(p[1] for p in points) / n),
        _round(sum(p[2] for p in points) / n),
    ]


def _sample(items: list, cap: int) -> list:
    """At most *cap* of *items*, spread evenly across the whole list.

    A head slice of a part's degenerate faces all come off the same curved
    face; a stride walks the part instead.
    """
    if len(items) <= cap:
        return list(items)
    stride = len(items) / float(cap)
    return [items[int(i * stride)] for i in range(cap)]


def defect_report(mesh: dict) -> dict:
    """``{"counts": {class: n, ...}, "sites": {class: {...}, ...}}`` for *mesh*.

    ``counts`` holds only the non-zero classes — open edges, non-manifold
    edges, degenerate faces, duplicate faces — and is the single derivation
    the summary reply and the 3MF refusal both quote. ``sites`` locates the
    two classes a reader can act on, and is empty when neither occurs.
    """
    vertices = mesh.get("vertices") or []
    faces = mesh.get("faces") or []

    # Weld positions: welded index → the position it stands at.
    welded: dict = {}
    weld_pos: list = []
    weld_of: list = []
    for vertex in vertices:
        key = tuple(round(float(c), _WELD_DECIMALS) for c in vertex)
        index = welded.get(key)
        if index is None:
            index = len(weld_pos)
            welded[key] = index
            weld_pos.append([float(c) for c in vertex])
        weld_of.append(index)

    edge_uses: dict = {}
    seen_faces: set = set()
    degenerate_sites: list = []
    degenerate = 0
    duplicate = 0
    for raw_face in faces:
        face = [weld_of[int(i)] if int(i) < len(weld_of) else int(i) for i in raw_face]
        if len(set(face)) != len(face):
            degenerate += 1
            corners = [vertices[int(i)] for i in raw_face if int(i) < len(vertices)]
            if corners:
                degenerate_sites.append({"position": _centroid(corners)})
            continue
        key = tuple(sorted(face))
        if key in seen_faces:
            duplicate += 1
        else:
            seen_faces.add(key)
        for i in range(len(face)):
            a, b = face[i], face[(i + 1) % len(face)]
            edge = (a, b) if a < b else (b, a)
            edge_uses[edge] = edge_uses.get(edge, 0) + 1

    open_edges = 0
    non_manifold_sites: list = []
    for (a, b), uses in edge_uses.items():
        if uses == 1:
            open_edges += 1
        elif uses > 2:
            pa, pb = weld_pos[a], weld_pos[b]
            non_manifold_sites.append({
                "position": _centroid([pa, pb]),
                "from": [_round(c) for c in pa],
                "to": [_round(c) for c in pb],
                "faces": uses,
            })
    # Encounter order follows the tessellation, which reorders between
    # kernel versions; position order is the same list every run.
    non_manifold_sites.sort(key=lambda site: site["position"])

    counts = {
        "open_edges": open_edges,
        "non_manifold_edges": len(non_manifold_sites),
        "degenerate_faces": degenerate,
        "duplicate_faces": duplicate,
    }
    sites: dict = {}
    if non_manifold_sites:
        sites["non_manifold_edges"] = {
            "total": len(non_manifold_sites),
            "note": _NON_MANIFOLD_NOTE,
            "sites": _sample(non_manifold_sites, NON_MANIFOLD_SITE_CAP),
        }
    if degenerate_sites:
        sites["degenerate_faces"] = {
            "total": degenerate,
            "note": _DEGENERATE_NOTE,
            "sites": _sample(degenerate_sites, DEGENERATE_SITE_CAP),
        }
    return {
        "counts": {name: n for name, n in counts.items() if n > 0},
        "sites": sites,
    }
