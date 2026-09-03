"""SOMEBODY ELSE'S glTF PARSER READING OUR BYTES.

``pygltflib`` is an independent implementation of the glTF 2.0 spec — it did not
learn the format from this worker and shares no code with ``gltf_write`` — so it
is an oracle in the same sense pygerber and gerbonara are for the fabrication
path: it parses the GLB container, the JSON chunk, the buffer views and the
accessor declarations by its own reading of the specification. A file it loads
and reports correctly is a file a viewer will load. Everything asserted here is
therefore read BACK OUT OF THE BYTES, never taken from the exporter's return
value, with two deliberate exceptions named at their use sites.

Blender is the human half of the same oracle, and it was run: the file this
suite builds imports into Blender 5.2 as six named objects and renders as a
green board with a tan laminate rim, solid two-tone parts, a magenta placeholder
prism and an orange post over the part whose orientation is a guess. That render
is what a structural check cannot do — see the note on transparency below.

WHAT AN INDEPENDENT READER IS ACTUALLY FOR HERE
-----------------------------------------------
Nothing in this file can catch a wrong ruling on the vendor's ``d 0.0`` — a
board whose every part is fully transparent has exactly the mesh count, the
transforms and the images asserted below. That decision is tested for what it
IS, a decision, in ``tests/test_gltf_export.py``, and confirmed by eye. What a
foreign parser catches is the class of defect our own writer cannot see: an
accessor count that disagrees with the bytes behind it, an image chunk that is
not where the JSON says it is, a buffer view that does not hold what it claims.

AND THE READER IS NOT A VALIDATOR — SO THIS ORACLE IS NOT TOTAL. ``pygltflib``
resolves offsets and lengths, but it does NOT enforce the spec's ALIGNMENT
rules: drop ``gltf_write``'s four-byte buffer-view alignment or its chunk
padding and every assertion below still passes, while a viewer that maps the
buffer instead of copying it rejects the file. Nothing here or anywhere else in
this worker's suites covers those rules today. Read this file as "a foreign
reader agrees with our bytes", never as "the file is valid glTF".

THE POSITION FILE IS THE OTHER ORACLE. Every part node's translation is read
from the file and compared against the CPL row for that part — the actual
emitted position file, not a re-derivation. A part that drifts in the export
without drifting in the file it is built for fails here.

AND THE RULER IS THE THIRD. glTF's linear unit is the METRE, so "the node's
translation equals the CPL's millimetre number" is a comparison that passes
just as happily on a file a thousand times too big — which is what this export
used to write, and what neither a render nor a reader nor a mesh count can see,
because a board with no reference object beside it looks identical at any
scale. So every geometric assertion here is made in WORLD SPACE, reached by
walking the scene graph's own transforms, and the board's world extent is held
against the fixture's REAL SIZE IN METRES (:data:`BOARD_WIDTH_MM` and its
siblings, which are the numbers written in the fixture's own YAML). That is a
measurement a viewer would agree with, and it is the one assertion in this file
that no self-consistent-but-wrong file can satisfy.
"""

from __future__ import annotations

import io
import struct

import pytest

from pcb_worker import assembly_outputs as ao
from pcb_worker import gltf_export
from pcb_worker import orientation_ledger as ol
from pcb_worker import part_models as pm
from pcb_worker import part_placement as pp
from pcb_worker import texture_bake
from pcb_worker.wavefront_obj import parse_obj
from tests.test_part_placement import CorpusClient, _board_dict, _compiled
from tests.test_wavefront_obj import BOX

pygltflib = pytest.importorskip("pygltflib")
from pygltflib import GLTF2  # noqa: E402
from PIL import Image  # noqa: E402

#: THE FIXTURE BOARD'S REAL SIZE, copied from the literal ``width_mm: 40`` /
#: ``height_mm: 30`` at the top of ``assembly_orientation.yaml`` and the
#: shipped 1.6 mm laminate its fabrication block defaults to. These are the
#: ruler: they are stated here as numbers so that the world-space measurement
#: below is held against a KNOWN BOARD, not against anything the exporter, the
#: mesh builder or the compiled board says about itself. The fixture is checked
#: to still state them, so a board that is resized fails loudly here rather
#: than quietly turning this suite self-referential.
BOARD_WIDTH_MM = 40.0
BOARD_DEPTH_MM = 30.0
BOARD_THICKNESS_MM = 1.6
MM_PER_METRE = 1000.0

#: The refs the fixture board orders, and what this suite arranges each to be.
PLACEHOLDER_REF = "J1"          # its model is withheld -> a prism
UNVERIFIED_REF = "U1"           # its pair is unmeasured -> a marked guess
NO_DATUM_REF = "U2"             # its vendor pads are renumbered -> no seating datum
BOTTOM_REF = "R1"               # moved to the underside


class DialectClient(CorpusClient):
    """The corpus client, but every model is the VENDOR'S OWN DIALECT.

    ``CorpusClient`` builds a clean box with one invented material; this serves
    ``test_wavefront_obj``'s ``BOX`` instead — inline ``newmtl`` blocks, no
    ``mtllib``, ``f 1// 2// 3//`` faces, ``d 0.0`` on every material and the two
    real ``Kd`` values. So the file under test carries the colours a stock OBJ
    loader would have dropped and the dissolve that would have made every part
    invisible, rather than a shape the vendor does not ship.
    """

    def model(self, facts):
        answer = super().model(facts)
        if getattr(answer, "absent", False):
            return answer
        return pm.PartModel(part=facts.part, uuid=facts.model.uuid,
                            mesh=parse_obj(BOX))


def _ledger_without(part: str) -> ol.OrientationLedger:
    """The shipped ledger with one pair's row taken out — an UNMEASURED pair.

    That is the state a marked guess actually arrives in on a real board:
    ``emit`` refuses the row, carries the refusal, and the export draws the
    part at its raw angle under a post. Manufacturing it here rather than
    renumbering pads keeps the two defects this fixture carries distinct — an
    unknown ANGLE on one part, a missing seating DATUM on another.
    """
    full = ol.load_ledger()

    def keep(rows):
        return tuple(row for row in rows if row.part != part)

    return ol.OrientationLedger(declared=keep(full.declared),
                                measured=keep(full.measured))


@pytest.fixture(scope="module")
def exported(tmp_path_factory):
    """One board, exported to a real file on disk, and everything to check it
    against: the compiled board, the emitted position file, the placement the
    export drew, and the reader's view of the bytes.

    ONE LEDGER FOR BOTH the emission and the placement, because they must be
    the same ledger — ``place_parts`` refuses a row whose emitted rotation is
    not the offset it is about to draw with."""
    board_dict = _board_dict()
    {c["ref"]: c for c in board_dict["components"]}[BOTTOM_REF]["layer"] = "bottom"
    board = _compiled(board_dict)
    ledger = _ledger_without("C780769")
    emission = ao.emit(board, "jlc", orientation=ledger)
    client = DialectClient(withhold=["C265102"], renumber=["C910544"])

    export = gltf_export.export_board(board, emission, client=client, ledger=ledger)
    path = tmp_path_factory.mktemp("gltf") / "board.glb"
    path.write_bytes(export.glb)

    return {
        "board": board,
        "cpl": {row.ref: row for row in emission.cpl},
        "placement": pp.place_parts(board, emission, client=client, ledger=ledger),
        "gltf": GLTF2().load_binary(str(path)),
        "path": path,
    }


def _bytes_of(gltf, view_index: int) -> bytes:
    view = gltf.bufferViews[view_index]
    start = view.byteOffset or 0
    return gltf.binary_blob()[start:start + view.byteLength]


def _positions(gltf, accessor_index: int) -> list[tuple[float, float, float]]:
    accessor = gltf.accessors[accessor_index]
    assert accessor.type == "VEC3" and accessor.componentType == 5126
    raw = _bytes_of(gltf, accessor.bufferView)
    return [struct.unpack_from("<3f", raw, 12 * i) for i in range(accessor.count)]


def _triangle_count(gltf, accessor_index: int) -> int:
    accessor = gltf.accessors[accessor_index]
    assert accessor.type == "SCALAR" and accessor.componentType == 5125
    # The bytes really are there: an accessor that claims more indices than its
    # buffer view holds is exactly the kind of lie a foreign reader exists to
    # catch, so the length is checked rather than trusted.
    assert len(_bytes_of(gltf, accessor.bufferView)) == 4 * accessor.count
    assert accessor.count % 3 == 0
    return accessor.count // 3


def _node(gltf, name: str):
    for node in gltf.nodes:
        if node.name == name:
            return node
    raise AssertionError(f"no node named {name!r} in {[n.name for n in gltf.nodes]}")


def _world(gltf) -> dict[int, tuple[tuple[float, float, float],
                                    tuple[float, float, float]]]:
    """``{node index: (scale, translation)}`` in WORLD space, by walking the
    scene from its own roots.

    The graph is walked rather than assumed because the graph is the only thing
    that knows what unit the file is in: the numbers on a node are the
    exporter's, and comparing them with the exporter's other numbers is exactly
    the self-comparison this oracle exists to avoid. A composed transform is
    what a VIEWER computes, so it is what the assertions are made against.

    Scale composes multiplicatively and a child's translation is expressed in
    its parent's units, which is what makes the millimetre-to-metre root work
    at all.
    """
    scene = gltf.scenes[gltf.scene]
    out: dict[int, tuple] = {}

    def walk(index: int, scale, offset):
        node = gltf.nodes[index]
        local = tuple(node.scale or (1.0, 1.0, 1.0))
        shift = tuple(node.translation or (0.0, 0.0, 0.0))
        assert not node.rotation or list(node.rotation) == [0.0, 0.0, 0.0, 1.0], \
            f"{node.name} carries a rotation this walker does not compose"
        assert not node.matrix, f"{node.name} carries a matrix, not a TRS"
        world_scale = tuple(scale[i] * local[i] for i in range(3))
        world_offset = tuple(offset[i] + scale[i] * shift[i] for i in range(3))
        out[index] = (world_scale, world_offset)
        for child in node.children or ():
            assert child not in out, f"node {child} is reached twice in the graph"
            walk(child, world_scale, world_offset)

    for root in scene.nodes:
        walk(root, (1.0, 1.0, 1.0), (0.0, 0.0, 0.0))
    assert len(out) == len(gltf.nodes), \
        "some node is not reachable from the scene, so nothing draws it"
    return out


def _world_extent(gltf, node_index: int) -> tuple[tuple[float, float, float],
                                                  tuple[float, float, float]]:
    """``(low, high)`` corners of one node's mesh in WORLD space, from the
    accessor bounds a viewer frames its camera on."""
    scale, offset = _world(gltf)[node_index]
    node = gltf.nodes[node_index]
    lows, highs = [], []
    for prim in gltf.meshes[node.mesh].primitives:
        accessor = gltf.accessors[prim.attributes.POSITION]
        lows.append(accessor.min)
        highs.append(accessor.max)
    low = tuple(min(v[i] for v in lows) * scale[i] + offset[i] for i in range(3))
    high = tuple(max(v[i] for v in highs) * scale[i] + offset[i] for i in range(3))
    return low, high


def _image(gltf, texture_index: int) -> Image.Image:
    source = gltf.textures[texture_index].source
    image = gltf.images[source]
    assert image.mimeType == "image/png"
    return Image.open(io.BytesIO(_bytes_of(gltf, image.bufferView)))


# ---------------------------------------------------------------------------


def test_the_board_is_its_real_size_in_metres(exported):
    """THE RULER. A 40 x 30 mm board is 0.040 x 0.030 in the world glTF defines.

    This is the assertion that a self-consistent file cannot fake. Every other
    geometric check in this suite compares one number the exporter wrote with
    another number the exporter wrote, and all of them pass unchanged on a file
    whose every distance is a thousand times too large — which is what emitting
    millimetres as scene coordinates produces, and which renders as a perfectly
    ordinary board because nothing in the frame gives its size away.

    So the board's extent is composed through the scene graph the way a viewer
    composes it, and held against the fixture's OWN stated size in metres.

    MUTATION THIS CATCHES: the export as it was written — millimetres emitted
    straight as scene coordinates. Set ``gltf_export.MM_TO_METRE`` to 1.0 and
    every other assertion in this suite still passes.
    """
    gltf, board = exported["gltf"], exported["board"]

    # The ruler is a ruler: the fixture still is the board these literals name.
    assert (board.outline.width_mm, board.outline.height_mm) == \
        (BOARD_WIDTH_MM, BOARD_DEPTH_MM), "the fixture board was resized"
    assert board.fabrication.thickness_mm == BOARD_THICKNESS_MM

    board_index = gltf.nodes.index(_node(gltf, "board"))
    low, high = _world_extent(gltf, board_index)
    size = tuple(high[i] - low[i] for i in range(3))

    # (x, y, z) = (board width, thickness, board depth) — mesh_frame's mapping.
    assert size == pytest.approx((BOARD_WIDTH_MM / MM_PER_METRE,
                                  BOARD_THICKNESS_MM / MM_PER_METRE,
                                  BOARD_DEPTH_MM / MM_PER_METRE), abs=1e-9), (
        "the board does not measure %g x %g mm in metres; it measures %r m"
        % (BOARD_WIDTH_MM, BOARD_DEPTH_MM, size))

    # AND IT SITS ON THE GROUND at its authored origin, in metres. A board that
    # is the right size in the wrong place is still a board an enclosure cannot
    # be measured against.
    assert low == pytest.approx((board.outline.origin[0] / MM_PER_METRE, 0.0,
                                 board.outline.origin[1] / MM_PER_METRE), abs=1e-9)

    # A sanity floor a person can hold in their head: a board this size is
    # centimetres across, not tens of metres and not microns.
    assert 0.01 < max(size) < 1.0, "this is not a board-sized object"

    # The tallest part rises above the board and stays within a hand's span of
    # it — the same measurement, on the thing seated ON the board.
    tallest = max(_world_extent(gltf, gltf.nodes.index(_node(gltf, ref)))[1][1]
                  for ref in exported["cpl"])
    assert BOARD_THICKNESS_MM / MM_PER_METRE < tallest < 0.1


def test_the_whole_scene_hangs_under_one_root_that_states_the_unit(exported):
    """The conversion is ONE scale in ONE place, and the file says so.

    Two roots, or a node left out from under the root, is a scene where half
    the geometry is in metres and half is in millimetres — which a viewer
    renders as a board with one part a kilometre away, and which a bounding-box
    check on any single mesh would still pass.
    """
    gltf = exported["gltf"]
    scene = gltf.scenes[gltf.scene]

    assert len(scene.nodes) == 1, "the scene has more than one root"
    root = gltf.nodes[scene.nodes[0]]
    assert root.name == gltf_export.ROOT_NODE_NAME
    assert root.mesh is None, "the unit root must not also draw something"
    assert root.scale == pytest.approx([gltf_export.MM_TO_METRE] * 3)

    # Every other node is its child, and nothing is drawn outside it.
    assert sorted(root.children) == [i for i in range(len(gltf.nodes))
                                     if gltf.nodes[i] is not root]

    # And the file SAYS which frame is which, to the reader who has only the
    # file: the millimetre in this document's metadata is a node coordinate,
    # and a reader must not take it for the file's unit.
    units = gltf.asset.extras["units"]
    assert units["world"] == "metre" and units["node_graph"] == "millimetre"
    assert units["root_node"] == gltf_export.ROOT_NODE_NAME
    assert units["root_scale"] == pytest.approx(gltf_export.MM_TO_METRE)
    assert "METRES" in gltf.asset.extras["axis_convention"]
    assert root.extras["units"] == units["note"]


def test_the_reader_finds_the_scene_the_position_file_describes(exported):
    """Node for node, and every part where the CPL says it is — in metres."""
    gltf, cpl = exported["gltf"], exported["cpl"]
    marker_node = UNVERIFIED_REF + gltf_export.MARKER_SUFFIX
    world = _world(gltf)

    assert {n.name for n in gltf.nodes} == \
        set(cpl) | {"board", marker_node, gltf_export.ROOT_NODE_NAME}
    assert world[gltf.nodes.index(_node(gltf, "board"))][1] == \
        pytest.approx((0.0, 0.0, 0.0))

    for ref, row in cpl.items():
        # THE POSITION FILE, read back out of the scene graph — and CONVERTED,
        # because the row is millimetres and the world is metres. The CPL is
        # emitted Y-up (X verbatim, board Y negated) and the scene is
        # (board_x, height, board_y), so the row's own numbers are the node's
        # horizontal world position with Y negated back and scaled to metres.
        index = gltf.nodes.index(_node(gltf, ref))
        assert world[index][1] == pytest.approx(
            [row.x_mm / MM_PER_METRE, 0.0, -row.y_mm / MM_PER_METRE], abs=1e-9), \
            f"{ref} is not where the CPL says"
    # The mark travels with the part it marks.
    assert world[gltf.nodes.index(_node(gltf, marker_node))] == \
        world[gltf.nodes.index(_node(gltf, UNVERIFIED_REF))]

    # And the vertices behind those nodes are the placement's own, restated
    # relative to the translation. (The placement is the second of the two
    # things not read from the file: it is what the export was asked to write.)
    # Composed the viewer's way and compared in METRES, so a scale that reached
    # the nodes but not the vertices — or the reverse — fails here too.
    for part in exported["placement"].parts:
        node = _node(gltf, part.ref)
        scale, offset = world[gltf.nodes.index(node)]
        drawn = [p for prim in gltf.meshes[node.mesh].primitives
                 for p in _positions(gltf, prim.attributes.POSITION)]
        placed = [tuple(v / MM_PER_METRE for v in p) for p in part.mesh.positions]
        for point in drawn:
            here = tuple(point[i] * scale[i] + offset[i] for i in range(3))
            assert min(max(abs(a - b) for a, b in zip(here, p))
                       for p in placed) < 1e-6, \
                f"{part.ref} vertex {here} is not placed"


def test_the_reader_finds_every_triangle_the_export_was_asked_to_write(exported):
    """Nothing silently dropped between the mesh builders and the buffer."""
    gltf, placement = exported["gltf"], exported["placement"]

    from_file = sum(_triangle_count(gltf, prim.indices)
                    for mesh in gltf.meshes for prim in mesh.primitives)
    parts = sum(len(p.mesh.triangles) + (0 if p.marker is None
                                         else len(p.marker.triangles))
                for p in placement.parts)
    slab = gltf.meshes[_node(gltf, "board").mesh]
    assert len(slab.primitives) == 3, "top face, bottom face and the rim"
    assert from_file == parts + sum(_triangle_count(gltf, prim.indices)
                                    for prim in slab.primitives)

    # Every position accessor declares the bounds a viewer frames the camera on,
    # and they are the bounds of the data behind them.
    for mesh in gltf.meshes:
        for prim in mesh.primitives:
            accessor = gltf.accessors[prim.attributes.POSITION]
            points = _positions(gltf, prim.attributes.POSITION)
            assert accessor.min == pytest.approx(
                [min(p[i] for p in points) for i in range(3)])
            assert accessor.max == pytest.approx(
                [max(p[i] for p in points) for i in range(3)])


def test_both_baked_sides_travel_in_the_file_on_the_right_face(exported):
    """Two images, embedded, non-blank — and the top one on the top face.

    A side swap is invisible to every structural check and to a glance at a
    render, so the images are compared against the bake ITSELF rather than
    merely being counted.
    """
    gltf = exported["gltf"]
    slab = gltf.meshes[_node(gltf, "board").mesh]
    baked = texture_bake.bake_board(exported["board"])

    assert len(gltf.images) == 2, "one picture per side, embedded, no side files"
    assert all(image.uri is None for image in gltf.images), \
        "a URI would make the file stop travelling alone"

    top_prim, bottom_prim, rim_prim = slab.primitives
    for prim, side in ((top_prim, "top"), (bottom_prim, "bottom")):
        texture = gltf.materials[prim.material].pbrMetallicRoughness \
            .baseColorTexture.index
        image = _image(gltf, texture)
        frame = baked[side].frame
        assert image.size == (frame.width_px, frame.height_px)
        assert len(image.convert("RGBA").getcolors(maxcolors=1 << 20)) > 1, \
            f"the {side} picture is a flat fill — the board is not on it"
        assert _bytes_of(gltf, gltf.images[gltf.textures[texture].source].bufferView) \
            == baked[side].to_png_bytes(), f"the {side} face is wearing the other side"

    # The rim is raw laminate: no picture registers it, so it gets the ordered
    # substrate colour instead of a texture.
    assert gltf.materials[rim_prim.material].pbrMetallicRoughness \
        .baseColorTexture is None


def test_every_material_is_opaque_and_the_synthetic_ones_are_unmistakable(exported):
    """The ruling, and the two colours nothing on a real board wears."""
    gltf = exported["gltf"]
    by_name = {m.name: m for m in gltf.materials}

    for material in gltf.materials:
        pbr = material.pbrMetallicRoughness
        assert pbr.baseColorFactor[3] == 1.0, f"{material.name} is see-through"
        assert material.alphaMode == "OPAQUE"
        # glTF defaults metallicFactor to 1.0 — a material that states a colour
        # and nothing else is a mirror, and a mirror with nothing to reflect
        # renders black.
        assert pbr.metallicFactor == 0.0

    placeholder = by_name[pp.PLACEHOLDER_MATERIAL]
    assert placeholder.pbrMetallicRoughness.baseColorFactor[:3] == \
        pytest.approx(list(pp.PLACEHOLDER_RGB)), "a placeholder must not pass for a part"
    marker = by_name[pp.UNVERIFIED_MARKER_MATERIAL]
    assert marker.pbrMetallicRoughness.baseColorFactor[:3] != \
        placeholder.pbrMetallicRoughness.baseColorFactor[:3]

    # The prism wears the placeholder colour and nothing else does.
    prism = gltf.meshes[_node(gltf, PLACEHOLDER_REF).mesh]
    assert [gltf.materials[p.material].name for p in prism.primitives] == \
        [pp.PLACEHOLDER_MATERIAL]
    marked = gltf.meshes[_node(gltf, UNVERIFIED_REF + gltf_export.MARKER_SUFFIX).mesh]
    assert [gltf.materials[p.material].name for p in marked.primitives] == \
        [pp.UNVERIFIED_MARKER_MATERIAL]

    # A real part wears the vendor's own colours, both of them, and neither is
    # a synthetic one. NO_DATUM_REF is one: a lost seating datum costs it a
    # marker and a report line, never its materials.
    part = gltf.meshes[_node(gltf, NO_DATUM_REF).mesh]
    worn = {gltf.materials[p.material].name for p in part.primitives}
    assert len(worn) == 2 and not worn & {pp.PLACEHOLDER_MATERIAL,
                                          pp.UNVERIFIED_MARKER_MATERIAL}


def test_the_reports_travel_inside_the_file(exported):
    """A person handed the ``.glb`` and nothing else can read what to distrust."""
    gltf = exported["gltf"]
    extras = gltf.asset.extras
    report = extras["placement"]

    assert [f["ref"] for f in report["fallbacks"]] == [PLACEHOLDER_REF]
    assert report["fallbacks"][0]["prism_basis"]
    assert [u["ref"] for u in report["unverified"]] == [UNVERIFIED_REF]
    assert report["unverified"][0]["reason"]
    assert PLACEHOLDER_REF in report["unknown_height_refs"]
    assert {t["side"] for t in report["tallest"]} == {"top", "bottom"}
    assert {a["code"] for a in report["advisories"]} >= {
        pp.ADVISORY_UNVERIFIED_MODEL, pp.ADVISORY_NO_SHARED_PADS}
    # THE TWO DEFECTS ARE REPORTED APART. An unknown ANGLE is a marked guess;
    # a missing seating DATUM is a part drawn at the angle the position file
    # states and merely centred on our origin, so it is NOT called unverified
    # and wears no post.
    assert [a["ref"] for a in report["advisories"]
            if a["code"] == pp.ADVISORY_NO_SHARED_PADS] == [NO_DATUM_REF]
    assert NO_DATUM_REF not in [u["ref"] for u in report["unverified"]]
    assert _node(gltf, NO_DATUM_REF).extras["orientation"] == pp.ORIENTATION_VERIFIED
    assert report["board_thickness_mm"] == exported["board"].fabrication.thickness_mm

    # The frames the UVs were built in, and the ruling that explains why every
    # part in this file contradicts the format its models came from.
    assert set(extras["textures"]) == {"top", "bottom"}
    assert extras["textures"]["bottom"]["mirrored_x"] is True
    assert "OPAQUE" in extras["rulings"]["vendor_material_dissolve"]
    assert gltf_export.DISSOLVE_SURPRISE in extras["rulings"]["vendor_material_dissolve"]
    assert extras["axis_convention"] == gltf_export.AXIS_CONVENTION

    # And the same facts reach the part a person clicks on.
    marked = _node(gltf, UNVERIFIED_REF).extras
    assert marked["orientation"] == pp.ORIENTATION_UNVERIFIED and marked["reason"]
    assert _node(gltf, PLACEHOLDER_REF).extras["kind"] == pp.KIND_PLACEHOLDER
    assert _node(gltf, BOTTOM_REF).extras["side"] == "bottom"
