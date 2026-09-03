"""THE glTF 2.0 / GLB CONTAINER: buffers, accessors, materials, nodes, bytes.

This module knows the file format and NOTHING about boards. It is the half of
the export that a reader has to trust byte-for-byte, so it is kept apart from
the half that decides what a board is made of (:mod:`gltf_export`) — a bug in
"which triangles are the top face" and a bug in "where the BIN chunk starts"
have nothing in common and should not be read in one file.

WHY BINARY glTF (``.glb``) AND NOT ``.gltf`` + FILES
----------------------------------------------------
The export has to travel alone: one file a person can hand to somebody else and
open in Blender with its colours intact. A ``.gltf`` references its textures by
URI, so a board's two baked images become two more files to keep together, and
the failure mode when they are lost is a WHITE BOARD that still loads. GLB puts
the JSON and every byte of geometry and both PNGs in one container. Base64
data URIs inside a ``.gltf`` would also travel alone, at a third more bytes and
with the images no longer readable by any tool but a glTF parser.

ONE BUFFER, ONE BIN CHUNK. Everything — vertex data, indices, and the PNGs — is
appended to a single buffer, which the container emits as the GLB BIN chunk. The
buffer therefore has no ``uri`` at all, which is exactly how the spec says the
GLB-stored buffer must be declared.

THE FOUR-BYTE RULE, in three places, all of them silent when broken
-------------------------------------------------------------------
glTF requires accessor data to be aligned to its component size, GLB requires
each chunk to be a multiple of four bytes, and the two padding characters are
NOT the same (spaces for JSON, zeros for BIN). Every one of those is a rule a
writer can break while still producing a file that most viewers open, because
alignment only bites on the readers that map the buffer directly instead of
copying it. So :meth:`GlbBuilder._append` aligns every buffer view on the way
in rather than fixing anything up afterwards.

METALLIC IS NOT DEFAULTED, AND THAT MATTERS MORE THAN IT LOOKS
--------------------------------------------------------------
glTF's ``metallicFactor`` defaults to **1.0**. A material that states a colour
and nothing else is therefore a MIRROR, and a mirror with no environment map to
reflect renders nearly black — so the honest-looking file "colour and nothing
else" produces a board of black parts in most viewers. Every material written
here states ``metallicFactor`` explicitly. See :data:`DIELECTRIC_ROUGHNESS`.

INDICES ARE ALWAYS 32-BIT. A board's substrate can exceed 65 535 vertices and a
part never comes close, and choosing per-primitive would mean two code paths
through the one function whose output nobody can eyeball. The cost is four bytes
per index on the small meshes; the benefit is that there is a single path.

THE SCENE LISTS ROOTS, NOT EVERY NODE
-------------------------------------
:meth:`GlbBuilder.add_group` makes a node that DRAWS NOTHING and parents the
nodes it is given, which is how a whole scene is put under one transform (the
board export puts everything under a millimetre-to-metre scale — see
:mod:`gltf_export`). A node that has been claimed as somebody's child is no
longer a root, and the spec's scene list holds roots only: listing a child there
too draws it twice, once with its parent's transform and once without, and the
duplicate is invisible in a render because the two copies coincide when the
parent transform happens to be identity. So parentage is tracked as it is
declared and :meth:`document` derives the root list from it rather than
assuming every node is a root.
"""

from __future__ import annotations

import json
import struct

from dataclasses import dataclass
from typing import Any, Mapping, Sequence, Union

#: glTF component types.
_FLOAT = 5126
_UNSIGNED_INT = 5125

#: glTF buffer-view targets.
_ARRAY_BUFFER = 34962
_ELEMENT_ARRAY_BUFFER = 34963

#: Sampler filters and wrapping. CLAMP_TO_EDGE, not the default REPEAT: the
#: board's UVs run the full 0..1 of its own texture, so a texel fetched a hair
#: outside that range at the board's rim must clamp to the rim pixel. Under
#: REPEAT it wraps to the OPPOSITE edge of the board, which draws a thin line of
#: the far side's silk along the near edge.
_LINEAR = 9729
_LINEAR_MIPMAP_LINEAR = 9987
_CLAMP_TO_EDGE = 33071

#: Roughness for every material this export writes. Parts and laminate are
#: dielectrics with no measured gloss, and the export deliberately carries no
#: material data beyond colour, so one plausible matte value is written rather
#: than a per-material guess. 1.0 (fully rough) reads as chalk; 0.6 keeps a
#: little shape-revealing falloff on a curved part without implying we know
#: anything about its finish.
DIELECTRIC_ROUGHNESS = 0.6

GLB_MAGIC = 0x46546C67          # 'glTF'
GLB_VERSION = 2
_CHUNK_JSON = 0x4E4F534A        # 'JSON'
_CHUNK_BIN = 0x004E4942         # 'BIN\0'

Vec3 = tuple[float, float, float]
Vec2 = tuple[float, float]


@dataclass(frozen=True)
class Attributes:
    """Accessor indices for ONE shared vertex array.

    Handed back by :meth:`GlbBuilder.add_vertices` and reused by every primitive
    drawn from those vertices — which is how the substrate's three surfaces
    (top, bottom, rim) index one vertex array instead of carrying three copies
    of it.
    """

    position: int
    normal: Union[int, None] = None
    texcoord: Union[int, None] = None


@dataclass(frozen=True)
class Primitive:
    """One drawable run of triangles: which vertices, which triangles, which
    material. ``triangles`` are index triples into the vertex array
    ``attributes`` describes."""

    attributes: Attributes
    triangles: Sequence[tuple[int, int, int]]
    material: int


class GlbBuilder:
    """Accumulates a glTF document and its one buffer, then emits GLB bytes.

    Add order does not matter; indices are handed back as things are added and
    are the only way to refer to them, so nothing here depends on the caller
    counting.
    """

    def __init__(self, generator: str) -> None:
        self._bin = bytearray()
        self._views: list[dict] = []
        self._accessors: list[dict] = []
        self._images: list[dict] = []
        self._textures: list[dict] = []
        self._materials: list[dict] = []
        self._meshes: list[dict] = []
        self._nodes: list[dict] = []
        #: Node indices some group has adopted, so they are not scene roots.
        self._children: set[int] = set()
        self._sampler: Union[int, None] = None
        self._generator = generator

    # -- buffer plumbing ----------------------------------------------------

    def _append(self, data: bytes, target: Union[int, None]) -> int:
        """One buffer view over ``data``, four-byte aligned. Returns its index."""
        while len(self._bin) % 4:
            self._bin.append(0)
        offset = len(self._bin)
        self._bin.extend(data)
        view: dict[str, Any] = {"buffer": 0, "byteOffset": offset,
                                "byteLength": len(data)}
        if target is not None:
            view["target"] = target
        self._views.append(view)
        return len(self._views) - 1

    def _accessor(self, view: int, kind: str, component: int, count: int,
                  bounds: Union[tuple[list, list], None] = None) -> int:
        entry: dict[str, Any] = {"bufferView": view, "componentType": component,
                                 "count": count, "type": kind}
        if bounds is not None:
            entry["min"], entry["max"] = bounds
        self._accessors.append(entry)
        return len(self._accessors) - 1

    # -- geometry -----------------------------------------------------------

    def add_vertices(self, positions: Sequence[Vec3], *,
                     normals: Union[Sequence[Vec3], None] = None,
                     uvs: Union[Sequence[Vec2], None] = None) -> Attributes:
        """One vertex array. ``normals`` and ``uvs`` must match ``positions`` in
        length when given.

        NORMALS MAY BE OMITTED, and are for the vendor part models, which carry
        no ``vn`` records at all. The spec requires a client to compute FLAT
        normals when ``NORMAL`` is absent, which is the truthful rendering of a
        mesh whose author never stated any: faceted, exactly as faceted as the
        data. Writing normals we invented — an averaged vertex normal, say —
        would round off the corner of every chip package to make it look
        smoother than the model is.
        """
        count = len(positions)
        if not count:
            raise ValueError("add_vertices: a vertex array cannot be empty")
        for name, extra in (("normals", normals), ("uvs", uvs)):
            if extra is not None and len(extra) != count:
                raise ValueError(
                    f"add_vertices: {name} has {len(extra)} entries for "
                    f"{count} positions")

        blob = b"".join(struct.pack("<3f", *p) for p in positions)
        lo = [min(p[i] for p in positions) for i in range(3)]
        hi = [max(p[i] for p in positions) for i in range(3)]
        # POSITION's min/max are REQUIRED by the spec, not an optimisation: a
        # viewer frames the camera on them, and an accessor without them makes
        # a file that loads to an empty-looking viewport.
        position = self._accessor(self._append(blob, _ARRAY_BUFFER),
                                  "VEC3", _FLOAT, count, (lo, hi))

        normal = None
        if normals is not None:
            normal = self._accessor(
                self._append(b"".join(struct.pack("<3f", *n) for n in normals),
                             _ARRAY_BUFFER), "VEC3", _FLOAT, count)
        texcoord = None
        if uvs is not None:
            texcoord = self._accessor(
                self._append(b"".join(struct.pack("<2f", *t) for t in uvs),
                             _ARRAY_BUFFER), "VEC2", _FLOAT, count)
        return Attributes(position=position, normal=normal, texcoord=texcoord)

    def add_mesh(self, name: str, primitives: Sequence[Primitive]) -> int:
        """One mesh, its primitives split by material."""
        if not primitives:
            raise ValueError(f"add_mesh({name!r}): a mesh needs a primitive")
        out = []
        for prim in primitives:
            flat = [i for tri in prim.triangles for i in tri]
            if not flat:
                raise ValueError(f"add_mesh({name!r}): a primitive has no triangles")
            indices = self._accessor(
                self._append(struct.pack(f"<{len(flat)}I", *flat),
                             _ELEMENT_ARRAY_BUFFER),
                "SCALAR", _UNSIGNED_INT, len(flat))
            attrs: dict[str, int] = {"POSITION": prim.attributes.position}
            if prim.attributes.normal is not None:
                attrs["NORMAL"] = prim.attributes.normal
            if prim.attributes.texcoord is not None:
                attrs["TEXCOORD_0"] = prim.attributes.texcoord
            out.append({"attributes": attrs, "indices": indices,
                        "material": prim.material})
        self._meshes.append({"name": name, "primitives": out})
        return len(self._meshes) - 1

    def add_node(self, name: str, mesh: int, *,
                 translation: Union[Vec3, None] = None,
                 extras: Union[Mapping[str, Any], None] = None) -> int:
        """One scene node drawing ``mesh``, optionally displaced.

        ``extras`` rides along per node; Blender's importer turns it into the
        object's custom properties, so a per-part fact reaches a person looking
        at that part rather than only a sidecar they have to be told about.
        """
        node: dict[str, Any] = {"name": name, "mesh": mesh}
        if translation is not None and tuple(translation) != (0.0, 0.0, 0.0):
            node["translation"] = [float(v) for v in translation]
        if extras:
            node["extras"] = dict(extras)
        self._nodes.append(node)
        return len(self._nodes) - 1

    def add_group(self, name: str, children: Sequence[int], *,
                  scale: Union[Vec3, None] = None,
                  extras: Union[Mapping[str, Any], None] = None) -> int:
        """One node that draws nothing and carries ``children`` under it.

        The children stop being roots of the scene, which is the point: a
        transform on this node applies to all of them exactly once. A node
        cannot be adopted twice or adopt itself, and both refuse rather than
        produce a file whose scene graph is a lie a viewer will resolve
        arbitrarily.
        """
        if not children:
            raise ValueError(f"add_group({name!r}): a group needs children")
        node: dict[str, Any] = {"name": name}
        for child in children:
            if not 0 <= child < len(self._nodes):
                raise ValueError(
                    f"add_group({name!r}): node {child} does not exist")
            if child in self._children:
                raise ValueError(
                    f"add_group({name!r}): node {child} already has a parent")
            self._children.add(int(child))
        node["children"] = [int(c) for c in children]
        if scale is not None:
            node["scale"] = [float(v) for v in scale]
        if extras:
            node["extras"] = dict(extras)
        self._nodes.append(node)
        return len(self._nodes) - 1

    # -- appearance ---------------------------------------------------------

    def add_png(self, data: bytes, name: str) -> int:
        """One embedded PNG as a texture. Returns the TEXTURE index."""
        if not data.startswith(b"\x89PNG\r\n\x1a\n"):
            raise ValueError(f"add_png({name!r}): not PNG data")
        if self._sampler is None:
            self._sampler = 0
        view = self._append(data, None)     # no target: image data, not vertices
        self._images.append({"name": name, "bufferView": view,
                             "mimeType": "image/png"})
        self._textures.append({"name": name, "sampler": 0,
                               "source": len(self._images) - 1})
        return len(self._textures) - 1

    def add_material(self, name: str, base_color: tuple[float, float, float, float],
                     *, texture: Union[int, None] = None,
                     double_sided: bool = False) -> int:
        """One colour, optionally modulated by a texture.

        ``base_color`` is LINEAR RGBA, as the spec requires of
        ``baseColorFactor`` — the caller converts, because whether a given
        number was authored in display space is the caller's fact, not this
        module's.

        EVERY MATERIAL IS OPAQUE. ``alphaMode`` is left at its default
        (``OPAQUE``), which means the alpha channel of both the factor and the
        texture is IGNORED by a conformant viewer. That is deliberate for the
        board: the baked images are transparent outside the outline and inside
        every hole, but the slab's geometry is already cut to exactly those
        boundaries, so honouring the texture's alpha could only make a real
        board edge see-through where an antialiased texel is half covered. The
        geometry is the authority on where the board is.
        """
        pbr: dict[str, Any] = {
            "baseColorFactor": [float(c) for c in base_color],
            "metallicFactor": 0.0,
            "roughnessFactor": DIELECTRIC_ROUGHNESS,
        }
        if texture is not None:
            pbr["baseColorTexture"] = {"index": texture}
        entry: dict[str, Any] = {"name": name, "pbrMetallicRoughness": pbr}
        if double_sided:
            entry["doubleSided"] = True
        self._materials.append(entry)
        return len(self._materials) - 1

    # -- output -------------------------------------------------------------

    def document(self, extras: Union[Mapping[str, Any], None] = None) -> dict:
        """The glTF JSON, with ``extras`` on ``asset``.

        Optional arrays are omitted when empty rather than written as ``[]``:
        the spec forbids an empty array for these properties, and a validator
        that rejects the file is far better than one that shrugs.
        """
        if not self._nodes:
            raise ValueError("document: a scene with no nodes is not a board")
        asset: dict[str, Any] = {"version": "2.0", "generator": self._generator}
        if extras:
            asset["extras"] = dict(extras)
        doc: dict[str, Any] = {
            "asset": asset,
            "scene": 0,
            "scenes": [{"nodes": [i for i in range(len(self._nodes))
                                  if i not in self._children]}],
            "nodes": self._nodes,
            "meshes": self._meshes,
            "accessors": self._accessors,
            "bufferViews": self._views,
            "buffers": [{"byteLength": self._padded_bin_length()}],
        }
        if self._materials:
            doc["materials"] = self._materials
        if self._images:
            doc["images"] = self._images
            doc["textures"] = self._textures
            doc["samplers"] = [{"magFilter": _LINEAR,
                                "minFilter": _LINEAR_MIPMAP_LINEAR,
                                "wrapS": _CLAMP_TO_EDGE, "wrapT": _CLAMP_TO_EDGE}]
        return doc

    def _padded_bin_length(self) -> int:
        return len(self._bin) + (-len(self._bin) % 4)

    def to_glb(self, extras: Union[Mapping[str, Any], None] = None) -> bytes:
        """The finished single-file board."""
        doc = self.document(extras)
        # separators: no gratuitous whitespace in a binary container.
        blob = json.dumps(doc, separators=(",", ":")).encode("utf-8")
        blob += b" " * (-len(blob) % 4)              # JSON pads with SPACES
        binary = bytes(self._bin) + b"\x00" * (-len(self._bin) % 4)   # BIN with ZEROS
        length = 12 + 8 + len(blob) + (8 + len(binary) if binary else 0)
        out = bytearray(struct.pack("<III", GLB_MAGIC, GLB_VERSION, length))
        out += struct.pack("<II", len(blob), _CHUNK_JSON) + blob
        if binary:
            out += struct.pack("<II", len(binary), _CHUNK_BIN) + binary
        return bytes(out)
