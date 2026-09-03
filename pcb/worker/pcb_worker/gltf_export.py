"""THE BOARD AS ONE FILE: the textured slab, the placed parts, and the reports
that say what to distrust about them — assembled into a single ``.glb``.

WHERE IT OPENS, AND WHERE IT DOES NOT
-------------------------------------
This targets a STANDARD THIRD-PARTY VIEWER — Blender, primarily. Minerva's own
CAD surface cannot open it: that panel draws an ``ArrayMesh`` its own worker
builds and has no file loader at all, so nothing in this worker should claim the
result is viewable in the application. In-app viewing is tracked separately.

WHAT IS IN THE FILE, and which module decided it
------------------------------------------------
    the slab, holes cut, watertight        :mod:`substrate_mesh`
    the two per-side pictures of it        :mod:`texture_bake` (embedded PNGs)
    where a board mm goes in the scene     :mod:`mesh_frame`
    where a texel goes on the board        :mod:`texture_frame`
    every part, seated at the CPL's own transform, in vendor colours,
    with a magenta prism where a model is missing and a post over a part
    whose orientation was never measured   :mod:`part_placement`
    laminate, mask, finish, silk colours   :mod:`texture_appearance`

This module adds only three things: the ``d 0.0`` ruling below, the colour-space
conversion below it, and the file.

THE RULING ON ``d 0.0`` — READ THIS BEFORE "FIXING" IT
------------------------------------------------------
Every material on every vendor model measured states ``d 0.0``. In the Wavefront
convention ``d`` is the DISSOLVE factor, 1.0 opaque and 0.0 fully transparent,
so BY THE LETTER OF THE FORMAT every part on this board is invisible.

**This export renders every part OPAQUE and ignores ``d`` entirely.** The
reasons, so that a future reader who notices us contradicting the spec does not
"correct" it back:

1. THE VENDOR'S OWN VIEWER SHOWS SOLID PARTS. Whatever their exporter means by
   the field, it does not mean what their renderer does with it.
2. THE VALUE NEVER VARIES. It is exactly 0.0 on every material of every model
   measured, including on materials whose ``Kd`` differ from each other by a
   lot. A field that is constant across every sample carries no information;
   an authored one would vary at least once.
3. ``Kd`` IS PLAINLY AUTHORED and ``d`` is plainly not. Body grey 0.251, bare
   metal 1.0, a brown 0.537/0.349/0.337 on a QFN — the colour channel was
   filled in deliberately by somebody. Trusting the field that was authored and
   discarding the field that was not is the conservative reading, not the
   liberal one.
4. THE FAILURE MODES ARE NOT SYMMETRIC. Read literally, the board loads, passes
   every structural check, validates against the spec — and shows nothing but a
   bare slab, with no error anywhere to say why. Read as opaque, the worst case
   is that a part which was meant to be a clear plastic lens is drawn solid.
   One of those is a silently empty deliverable; the other is a slightly wrong
   lens.

AND THE ASSUMPTION CARRIES ITS OWN FALSIFIER. Reason 2 is a measurement, and a
measurement can go stale: if the vendor ever ships a material whose ``d`` is
something OTHER than 0.0 (or absent), the premise "nobody authored this field"
is dead. So every material is checked, and any dissolve outside that set is
recorded in :data:`DISSOLVE_SURPRISE` as an export note — still drawn opaque,
because changing the ruling is a decision for a person, but never silently.

COLOUR SPACE: ONE CONVERSION, IN ONE PLACE
------------------------------------------
glTF's ``baseColorFactor`` is LINEAR; a ``baseColorTexture``'s PNG is sRGB and
the viewer decodes it. Every colour this worker authors as a NUMBER — the FR4
swatch that paints the baked laminate, a vendor ``Kd``, the synthetic magenta —
is a display-space value, because that is how it was chosen and, in the vendor's
case, how their WebGL viewer feeds it to a shader. So all of them go through
:func:`srgb_to_linear` on the way into a material factor. Skipping it does not
look broken, it looks WASHED OUT: the board's rim would come out a pale tan next
to the same laminate colour in the texture, and every dark IC body would read as
mid-grey plastic.

THE REPORTS TRAVEL IN THE FILE
------------------------------
``asset.extras`` carries the whole placement report — every fallback and why,
every unverified orientation and why, the tallest measured part per side, the
parts whose height is unknown, and the advisories — plus the texture frames, the
ordered appearance, this ruling in prose, and the axis convention. A person who
is handed the ``.glb`` and nothing else can read all of it with any glTF tool. A
report that only reached a log is a report that is lost the moment the file is
forwarded to somebody.

Per-part facts additionally ride on the NODE, which is what actually reaches a
person in a viewer: MEASURED in Blender 5.2, node ``extras`` arrive as the
object's custom properties (so the part somebody clicks tells them its
orientation was a guess), while ``asset.extras`` does NOT reach the Blender
scene at all. That is why the per-part facts are duplicated onto the nodes
rather than left to the one report — the report is for the reader with a
parser, the node extras are for the reader with a mouse.

THE FILE IS IN METRES; THE GRAPH IS IN MILLIMETRES
--------------------------------------------------
glTF's linear unit is the METRE — "the units for all linear distances are
meters" — and everything this worker computes is board MILLIMETRES. Emitting
millimetres as scene coordinates therefore makes a 90 mm board a 90 METRE board
in any conforming viewer, and NOTHING LOOKS WRONG: a board with no reference
object beside it is identical at any scale, so neither a render, nor a reader,
nor a structural check can catch it. Only a measurement can.

The conversion is ONE ``scale`` of 0.001 on a single root node
(:data:`ROOT_NODE_NAME`) that parents every other node, rather than a
multiplication applied to each vertex and each translation on the way out:

* THE NUMBERS INSIDE THE GRAPH STAY MILLIMETRES, which is the whole reason a
  part node is translated to its anchor in the first place — a reader compares
  a node's translation with the position file's own row BY EYE, and against a
  ``report`` whose every field is ``*_mm``. Scaling the vertices would leave
  0.0234 where the CPL says 23.4 and make every one of those comparisons an
  arithmetic exercise.
* IT IS ONE PLACE. A per-vertex conversion is a factor that has to be applied
  in five places (slab positions, part positions, marker positions, both node
  translations) and stays correct only while every future writer remembers it;
  a factor missed on one of them is a part a thousand times out of position,
  which — again — nobody would see.
* IT IS UNIFORM AND TOUCHES NO VERTEX. The same positive factor on all three
  axes leaves winding and normal direction as they were, and the geometry is
  written exactly as computed — the millimetre values are never rewritten. The
  only conversion the file carries is the one factor on the root (1/1000, which
  binary floating point represents as closely as it can, not exactly), applied
  once by the viewer rather than baked into thousands of positions.

The cost is that a consumer reading raw ACCESSOR values without walking the
scene graph sees millimetres. That is why the root exists as a named node, why
:data:`AXIS_CONVENTION` states both frames, and why the report carries
``units`` naming which is which — a caller that skips the transform can at
least be told, in the file, that it did.

NODE LAYOUT
-----------
One node per part, NAMED FOR ITS REFDES and TRANSLATED to the position file's own
anchor, with the part's vertices stated relative to that. So a reader — human or
program — can read the CPL's numbers straight back out of the scene graph
instead of inferring them from a bounding box. Rotation is baked into the
vertices rather than carried as a node rotation, because the vendor-to-ours map
is not one rotation: it composes a measured ledger offset, a pad-datum
translation and, on the bottom side, a mirror. A node quaternion could only
express part of that, and a partly-honest transform is worse than none.

Every one of those nodes is a CHILD of the millimetre root above, so the scene
has exactly one root and the scale reaches all of them.

NOT HERE: any MCP verb, any user interface, any viewer. The intermediate
exchange format some CAD tools prefer (STEP) is out of scope, and so is any
material property beyond colour.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Sequence, Union

from . import gltf_write
from . import part_placement as pp
from . import substrate_mesh as sm
from . import texture_bake
from .gltf_write import Attributes, GlbBuilder, Primitive
from .texture_appearance import RGB, appearance_for
from .texture_frame import DEFAULT_SCALE_PX_PER_MM, MAX_TEXTURE_PX
from .wavefront_obj import Material

GENERATOR = "Minerva pcb worker — board export (glTF 2.0)"

#: The set of ``d`` values the ruling above was measured on. Anything else means
#: the vendor started authoring the field and the ruling needs a person.
KNOWN_DISSOLVES = (None, 0.0)
DISSOLVE_SURPRISE = "vendor_dissolve_outside_measured_set"

#: The ruling, in prose, so it travels INSIDE the file. A person handed the
#: ``.glb`` alone can read why its parts are opaque; keeping it only in this
#: module's docstring would leave the file's own reader looking at an
#: unexplained contradiction of the format the models came from.
DISSOLVE_RULING = (
    "Every material on every vendor part model states Wavefront 'd 0.0', which "
    "read literally is FULLY TRANSPARENT. This export ignores 'd' and draws "
    "every part OPAQUE: the vendor's own viewer shows solid parts, the value is "
    "constant across every material of every model measured (so nobody authored "
    "it, while Kd plainly was), and the literal reading produces a board with no "
    "visible parts and no error anywhere to say why. A model arriving with any "
    "other dissolve is reported in notes as " + DISSOLVE_SURPRISE + " and still "
    "drawn opaque, because changing this ruling is a decision for a person.")

#: What a material with no ``Kd`` at all is drawn as. A mid grey: it must not
#: pass for a measured colour, and it must not pass for a placeholder either
#: (those are magenta), so it is deliberately dull rather than loud.
NEUTRAL_PART_RGB = (0.5, 0.5, 0.5)

#: Material names the file writer must not rename or merge by colour: they are
#: how a person finds the synthetic geometry in a viewer's material list.
_SYNTHETIC = frozenset({pp.PLACEHOLDER_MATERIAL, pp.UNVERIFIED_MARKER_MATERIAL})

#: Node-name suffix for the post that stands over an unverified part. A separate
#: node rather than extra primitives on the part: named this way, every mark in
#: the scene selects (or hides) at once, which is how a person asks "what in
#: here is a guess?" and then how they get the marks out of the way again.
MARKER_SUFFIX = "__unverified_orientation"

#: The root every other node hangs under, and the scale it carries. glTF is a
#: METRE format; this worker computes board millimetres. See THE FILE IS IN
#: METRES in the module docstring before changing either.
ROOT_NODE_NAME = "board_mm"
MM_PER_METRE = 1000.0
MM_TO_METRE = 1.0 / MM_PER_METRE

AXIS_CONVENTION = (
    "node coordinates are MILLIMETRES; the single root node '" + ROOT_NODE_NAME
    + "' scales them by " + repr(MM_TO_METRE) + " so WORLD space is METRES, as "
    "glTF requires. glTF +Y up; scene (x, y, z) = (board_x, height above the "
    "board underside, board_y); the board underside rests on y = 0")

#: What ``report["units"]`` says, spelled out, because a reader who finds
#: "millimetre" in a glTF file's metadata has every right to assume the file is
#: wrong until told which frame that millimetre belongs to.
UNITS_NOTE = (
    "Vertex positions and node translations are BOARD MILLIMETRES, and so is "
    "every *_mm field in this report. The root node '" + ROOT_NODE_NAME
    + "' scales the whole scene by " + repr(MM_TO_METRE) + ", so a viewer that "
    "walks the scene graph — every conforming one does — measures the board in "
    "METRES, which is the unit glTF defines. Read an accessor without its "
    "parent transform and you are reading millimetres.")


@dataclass(frozen=True)
class BoardExport:
    """The finished file and everything the caller should say about it."""

    glb: bytes
    #: The same dictionary the file carries in ``asset.extras``.
    report: dict
    notes: tuple[str, ...]


def srgb_to_linear(channel: float) -> float:
    """One display-space channel (0..1) as the linear value glTF wants."""
    c = min(max(float(channel), 0.0), 1.0)
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def _linear_rgba(rgb: Sequence[float]) -> tuple[float, float, float, float]:
    """A display-space 0..1 triple as an OPAQUE linear RGBA factor."""
    return (srgb_to_linear(rgb[0]), srgb_to_linear(rgb[1]),
            srgb_to_linear(rgb[2]), 1.0)


def _linear_rgba_255(rgb: RGB) -> tuple[float, float, float, float]:
    """A swatch-table 0..255 triple as an OPAQUE linear RGBA factor."""
    return _linear_rgba([c / 255.0 for c in rgb])


def part_base_color(material: Union[Material, None]
                    ) -> tuple[tuple[float, float, float, float], Union[str, None]]:
    """``(linear RGBA, note)`` for one vendor material.

    Alpha is 1.0 unconditionally: see THE RULING in the module docstring. The
    note is the falsifier — set when this material's ``d`` is outside
    :data:`KNOWN_DISSOLVES`, or when it states no colour at all.
    """
    if material is None:
        return _linear_rgba(NEUTRAL_PART_RGB), None
    note = None
    if material.dissolve not in KNOWN_DISSOLVES:
        note = (f"{DISSOLVE_SURPRISE}: material {material.name!r} states "
                f"d {material.dissolve!r}, outside the values the opaque ruling "
                f"was measured on {KNOWN_DISSOLVES}; drawn OPAQUE anyway — read "
                f"the ruling in gltf_export before changing anything")
    if material.diffuse is None:
        return _linear_rgba(NEUTRAL_PART_RGB), (
            note or f"material {material.name!r} states no Kd; drawn neutral grey")
    return _linear_rgba(material.diffuse), note


# ---------------------------------------------------------------------------
# Materials, shared across every part that happens to use the same colour
# ---------------------------------------------------------------------------


class _Palette:
    """Interns materials so forty resistors of one grey become one material.

    Vendor material NAMES are useless as keys — the dialect numbers them, so
    ``1`` in two different models is two different colours — hence colours are
    interned by their VALUE and named after it. The synthetic materials are the
    exception and keep their given names, because a person looks for those by
    name.
    """

    def __init__(self, builder: GlbBuilder) -> None:
        self._builder = builder
        self._by_key: dict[Any, int] = {}
        self.notes: list[str] = []

    def of(self, name: Union[str, None], material: Union[Material, None]) -> int:
        rgba, note = part_base_color(material)
        if note is not None and note not in self.notes:
            self.notes.append(note)
        synthetic = name in _SYNTHETIC
        key: Any = name if synthetic else rgba
        if key not in self._by_key:
            label = str(name) if synthetic else "part_" + "".join(
                f"{round(c * 255):02x}" for c in rgba[:3])
            self._by_key[key] = self._builder.add_material(label, rgba)
        return self._by_key[key]


def _primitives(mesh: pp.SceneMesh, attributes: Attributes,
                palette: _Palette) -> list[Primitive]:
    """One primitive per material used by ``mesh``, in first-use order.

    A primitive is a run of triangles sharing a material, so the triangles have
    to be BUCKETED by material rather than emitted in mesh order — a part whose
    triangles alternate between two materials would otherwise need one
    primitive per triangle.
    """
    buckets: dict[Union[str, None], list[tuple[int, int, int]]] = {}
    for triangle, name in zip(mesh.triangles, mesh.triangle_materials):
        buckets.setdefault(name, []).append(triangle)
    out = []
    for name, triangles in buckets.items():
        material = mesh.materials.get(name) if name is not None else None
        out.append(Primitive(attributes=attributes, triangles=tuple(triangles),
                             material=palette.of(name, material)))
    return out


def _relative(positions: Sequence[gltf_write.Vec3], anchor: tuple[float, float]
              ) -> tuple[gltf_write.Vec3, ...]:
    """Scene positions restated relative to a node translated to ``anchor``.

    Only the two HORIZONTAL axes are displaced. Height stays absolute, so a
    part's vertices still read directly as "this far above the board's
    underside" — which is the number an enclosure question is asked in, and the
    node's own translation would otherwise have to be added back in to get it.
    """
    ax, ay = anchor
    return tuple((x - ax, y, z - ay) for (x, y, z) in positions)


def _part_extras(part: pp.PlacedPart) -> dict:
    """The per-part facts that ride on the node itself."""
    extras = {
        "ref": part.ref, "side": part.side, "kind": part.kind,
        "orientation": part.orientation,
        "height_mm": round(part.height_mm, 4),
        "height_basis": part.height_basis,
        "house_part": part.house_part, "footprint": part.footprint_ref,
    }
    if part.reason:
        extras["reason"] = part.reason
    if part.prism_basis:
        extras["prism_basis"] = part.prism_basis
    if part.anchor_delta_mm is not None:
        extras["anchor_delta_mm"] = round(part.anchor_delta_mm, 4)
    if part.notes:
        extras["notes"] = list(part.notes)
    return extras


# ---------------------------------------------------------------------------
# The assembly
# ---------------------------------------------------------------------------


def export_board(board, emission, *, client,
                 ledger=None,
                 scale_px_per_mm: float = DEFAULT_SCALE_PX_PER_MM,
                 max_px: int = MAX_TEXTURE_PX) -> BoardExport:
    """Assemble ``board`` into one GLB and the report that travels inside it.

    ``emission`` is the :class:`assembly_outputs.AssemblyEmission` the position
    file is rendered from and ``ledger`` must be the ledger it was corrected
    with — both are passed straight to :func:`part_placement.place_parts`, which
    refuses rather than draw if they do not describe this board. ``client``
    answers ``facts``/``model`` as :class:`part_models.VendorPartClient` does.

    THE BAKE COMES FIRST, and the slab is built from ITS frames rather than from
    the same arguments: a UV is ``pixel / image_dimension`` and the dimension is
    a ceiling, so two frames built independently at one scale can still
    register the board a fraction of a texel apart — and if the scale was
    clamped for one side and not the other, much further apart than that.
    """
    baked = texture_bake.bake_board(board, scale_px_per_mm=scale_px_per_mm,
                                    max_px=max_px)
    slab = sm.build_substrate_mesh(board, frames={side: b.frame
                                                  for side, b in baked.items()})
    placement = pp.place_parts(board, emission, client=client, ledger=ledger)
    appearance = appearance_for(board.fabrication)

    builder = GlbBuilder(GENERATOR)
    palette = _Palette(builder)

    top_texture = builder.add_png(baked["top"].to_png_bytes(), "board_top")
    bottom_texture = builder.add_png(baked["bottom"].to_png_bytes(), "board_bottom")
    white = (1.0, 1.0, 1.0, 1.0)
    slab_attributes = builder.add_vertices(slab.positions, normals=slab.normals,
                                           uvs=slab.uvs)
    slab_primitives = [
        Primitive(slab_attributes, slab.top_triangles,
                  builder.add_material("board_top", white, texture=top_texture)),
        Primitive(slab_attributes, slab.bottom_triangles,
                  builder.add_material("board_bottom", white, texture=bottom_texture)),
        Primitive(slab_attributes, slab.edge_triangles,
                  builder.add_material("board_laminate",
                                       _linear_rgba_255(appearance.substrate))),
    ]
    # Every node built below is collected rather than left to stand on its own:
    # they all become children of the one millimetre-to-metre root, which is
    # what puts the file in the unit glTF defines. See THE FILE IS IN METRES.
    drawn = [builder.add_node("board", builder.add_mesh("board", slab_primitives),
                              extras={"thickness_mm": slab.thickness_mm,
                                      "axis_convention": AXIS_CONVENTION})]

    for part in placement.parts:
        anchor = part.anchor_mm
        attributes = builder.add_vertices(_relative(part.mesh.positions, anchor))
        mesh = builder.add_mesh(
            part.ref, _primitives(part.mesh, attributes, palette))
        drawn.append(builder.add_node(
            part.ref, mesh, translation=(anchor[0], 0.0, anchor[1]),
            extras=_part_extras(part)))
        if part.marker is not None:
            marker_attributes = builder.add_vertices(
                _relative(part.marker.positions, anchor))
            marker_mesh = builder.add_mesh(
                part.ref + MARKER_SUFFIX,
                _primitives(part.marker, marker_attributes, palette))
            drawn.append(builder.add_node(
                part.ref + MARKER_SUFFIX, marker_mesh,
                translation=(anchor[0], 0.0, anchor[1]),
                extras={"ref": part.ref, "marks": "unverified orientation",
                        "reason": part.reason}))

    builder.add_group(ROOT_NODE_NAME, drawn,
                      scale=(MM_TO_METRE, MM_TO_METRE, MM_TO_METRE),
                      extras={"units": UNITS_NOTE,
                              "axis_convention": AXIS_CONVENTION})

    notes = list(palette.notes)
    for side in ("top", "bottom"):
        notes.extend(f"{side} texture: {note}" for note in baked[side].notes)
    notes.extend(appearance.notes)

    report = {
        "generator": GENERATOR,
        "units": {
            "world": "metre",
            "node_graph": "millimetre",
            "root_node": ROOT_NODE_NAME,
            "root_scale": MM_TO_METRE,
            "note": UNITS_NOTE,
        },
        "axis_convention": AXIS_CONVENTION,
        "board": {
            "thickness_mm": slab.thickness_mm,
            "mask_colour": board.fabrication.mask_colour,
            "finish": board.fabrication.finish,
        },
        "textures": {side: baked[side].frame.as_dict() for side in ("top", "bottom")},
        "appearance": {
            "substrate_srgb": list(appearance.substrate),
            "mask_srgb": list(appearance.mask),
            "finish_srgb": list(appearance.finish),
            "silk_srgb": list(appearance.silk),
        },
        "placement": placement.as_dict(),
        "rulings": {"vendor_material_dissolve": DISSOLVE_RULING},
        "notes": notes,
    }
    return BoardExport(glb=builder.to_glb(report), report=report,
                       notes=tuple(notes))


