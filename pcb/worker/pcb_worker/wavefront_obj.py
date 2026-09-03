"""Wavefront OBJ text -> vertices, triangles and the materials they use.

Split out of :mod:`pcb_worker.part_models` because it is a FILE FORMAT and
knows nothing about EasyEDA, catalogue numbers, caching or HTTP. It still
belongs to the vendor-data client rather than to any renderer: a consumer that
wants a part's geometry asks the client and gets a :class:`Mesh`, so no
downstream editor ever grows its own copy of this.

WHAT THE VENDOR ACTUALLY SENDS — MEASURED, NOT ASSUMED
------------------------------------------------------
Five models fetched from ``modules.easyeda.com/3dmodel/<uuid>`` were read
byte-for-byte. Every one of them:

* is in MILLIMETRES. ``R0805`` (``c7acac53...``) measures 2.00 x 1.30 x 0.61,
  which is exactly the ``R0805_L2.0-W1.3-H0.6`` its own package title states.
  Z starts at 0 — the seating plane — and grows upward.
* carries its materials INLINE, as ``newmtl``/``Ka``/``Kd``/``Ks``/``d``/
  ``endmtl`` blocks interleaved with the ``v`` lines, and emits NO ``mtllib``
  directive. This is not standard Wavefront, where materials live in a
  separate ``.mtl`` file. A stock OBJ loader therefore sees ``usemtl 1`` with
  no library to resolve it against and renders the part untextured. **So the
  colours are there and a naive importer will lose them** — which is why this
  parser reads the inline blocks and hands them back explicitly.
* triangulates everything, and writes faces as ``f 1// 2// 3//`` — a vertex
  index with empty texture and normal slots. Legal, but strict parsers that
  expect ``i/j/k`` choke on the empty fields.
* carries no ``vn``, no ``vt``, and no ``o``/``g`` grouping.

THE ``d`` FIELD IS NOT OPACITY HERE
-----------------------------------
Every material on every model measured states ``d 0.0``. In the Wavefront
convention ``d`` is the DISSOLVE factor where 1.0 is opaque and 0.0 is fully
transparent, so read literally the vendor is shipping wholly invisible parts —
which they plainly are not, since ``Kd`` varies meaningfully across materials
(body grey 0.251, metal white 1.0, a brown 0.537/0.349/0.337 on the QFN). The
value is reported RAW as :attr:`Material.dissolve` and deliberately NOT mapped
to an alpha. A consumer that wants transparency must decide what to do with it;
this module refuses to guess on its behalf.

NEVER RAISES
------------
A truncated download, an HTML error page, an OSS ``NoSuchKey`` XML body: all of
them parse to a :class:`Mesh` with no triangles. Callers test
``mesh.triangles`` and report an absence. Nothing here is exceptional enough to
stop an export of forty other parts.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Mapping

# Directives this parser understands are handled below by name. Anything else
# is counted into `Mesh.ignored_directives` and skipped — so a vendor that
# starts emitting `vn` or `mtllib` shows up as a visible fact rather than as
# geometry that silently changed.

_Vec3 = tuple[float, float, float]


@dataclass(frozen=True)
class Material:
    """One inline ``newmtl`` block.

    Colours are 0..1 triples straight from the file. ``dissolve`` is the raw
    ``d`` value and is NOT an opacity — see the module docstring before using
    it for anything.
    """

    name: str
    ambient: _Vec3 | None = None
    diffuse: _Vec3 | None = None
    specular: _Vec3 | None = None
    dissolve: float | None = None


@dataclass(frozen=True)
class Mesh:
    """A parsed OBJ, in the file's own frame and units (millimetres, here).

    ``triangles`` index into ``vertices`` ZERO-BASED — the file's 1-based and
    negative-relative indices are resolved during parsing, so a consumer never
    has to know which convention it is holding. ``triangle_materials`` runs
    parallel to ``triangles``; an entry is ``None`` where no ``usemtl`` was in
    effect.
    """

    vertices: tuple[_Vec3, ...] = ()
    triangles: tuple[tuple[int, int, int], ...] = ()
    triangle_materials: tuple[str | None, ...] = ()
    materials: Mapping[str, Material] = field(default_factory=dict)
    ignored_directives: tuple[str, ...] = ()

    @property
    def empty(self) -> bool:
        return not self.triangles

    def bounds_mm(self) -> tuple[_Vec3, _Vec3] | None:
        """Axis-aligned min/max corner over the REFERENCED vertices, or None
        when there is no geometry.

        Referenced, not all: an OBJ may carry stray vertices no face uses, and
        a bounding box that counts them describes the file rather than the
        part.
        """
        used = {i for tri in self.triangles for i in tri}
        if not used:
            return None
        pts = [self.vertices[i] for i in used]
        lo = (min(p[0] for p in pts), min(p[1] for p in pts),
              min(p[2] for p in pts))
        hi = (max(p[0] for p in pts), max(p[1] for p in pts),
              max(p[2] for p in pts))
        return lo, hi


def _floats(parts: list[str], count: int) -> tuple[float, ...] | None:
    if len(parts) < count:
        return None
    try:
        return tuple(float(p) for p in parts[:count])
    except ValueError:
        return None


def _vertex_index(token: str, total: int) -> int | None:
    """Resolve one face token (``"12"``, ``"12//"``, ``"12/3/4"``, ``"-1"``)
    to a zero-based index, or None when it is unusable."""
    head = token.split("/", 1)[0].strip()
    if not head:
        return None
    try:
        raw = int(head)
    except ValueError:
        return None
    if raw > 0:
        idx = raw - 1
    elif raw < 0:
        idx = total + raw          # -1 is the most recent vertex
    else:
        return None                # 0 is not a valid OBJ index
    return idx if 0 <= idx < total else None


def parse_obj(text: str) -> Mesh:
    """Parse OBJ source into a :class:`Mesh`. Never raises.

    Faces with more than three vertices are fan-triangulated, which is correct
    for the convex planar polygons OBJ faces are defined to be. Unparseable
    lines are dropped rather than defended against: a half-downloaded model
    should come out as a smaller mesh or an empty one, not as an exception.
    """
    vertices: list[_Vec3] = []
    triangles: list[tuple[int, int, int]] = []
    tri_materials: list[str | None] = []
    materials: dict[str, Material] = {}
    ignored: set[str] = set()

    current: str | None = None          # active usemtl
    building: str | None = None         # name inside an open newmtl block
    fields: dict[str, object] = {}

    def close_material() -> None:
        nonlocal building, fields
        if building is not None:
            materials[building] = Material(
                name=building,
                ambient=fields.get("Ka"),      # type: ignore[arg-type]
                diffuse=fields.get("Kd"),      # type: ignore[arg-type]
                specular=fields.get("Ks"),     # type: ignore[arg-type]
                dissolve=fields.get("d"),      # type: ignore[arg-type]
            )
        building, fields = None, {}

    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        key, rest = parts[0], parts[1:]

        if key == "v":
            xyz = _floats(rest, 3)
            if xyz is not None:
                vertices.append(xyz)  # type: ignore[arg-type]
        elif key == "f":
            idx = [_vertex_index(t, len(vertices)) for t in rest]
            good = [i for i in idx if i is not None]
            if len(good) != len(idx) or len(good) < 3:
                continue
            for k in range(1, len(good) - 1):
                triangles.append((good[0], good[k], good[k + 1]))
                tri_materials.append(current)
        elif key == "usemtl":
            current = rest[0] if rest else None
        elif key == "newmtl":
            close_material()
            building = rest[0] if rest else None
        elif key == "endmtl":
            close_material()
        elif key in ("Ka", "Kd", "Ks"):
            rgb = _floats(rest, 3)
            if rgb is not None and building is not None:
                fields[key] = rgb
        elif key == "d":
            val = _floats(rest, 1)
            if val is not None and building is not None:
                fields["d"] = val[0]
        else:
            ignored.add(key)

    close_material()   # a file that ends mid-block still yields its material
    return Mesh(vertices=tuple(vertices),
                triangles=tuple(triangles),
                triangle_materials=tuple(tri_materials),
                materials=materials,
                ignored_directives=tuple(sorted(ignored)))
