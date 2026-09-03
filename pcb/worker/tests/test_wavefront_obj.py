"""The OBJ reader, against the dialect the vendor actually emits.

WHY THE FIXTURE IS AUTHORED HERE AND NOT DOWNLOADED. Nothing fetched is ever
committed, so a real vendor model cannot live in this repository. What CAN live
here is the vendor's DIALECT — measured from five real models on 2026-09-02 —
wrapped around geometry whose answers are arithmetic:

* materials inline as ``newmtl``/``Ka``/``Kd``/``Ks``/``d``/``endmtl`` blocks
  interleaved with the ``v`` lines, and **no** ``mtllib`` — the thing a stock
  loader drops on the floor, which is the entire reason this parser exists;
* faces written ``f 1// 2// 3//``, a vertex index with empty texture and normal
  slots, which strict ``i/j/k`` parsers reject;
* ``d 0.0`` on every material, which is NOT an opacity and must survive
  unmapped;
* no ``vn``, no ``vt``, no ``o``/``g``.

The oracle is a box: a reader that gets the index base, the ``//`` stripping or
the fan triangulation wrong cannot produce 2.0 x 1.3 x 0.6 from these numbers.

Live models are read by the acceptance station that has a network. CI reads
this.
"""

from __future__ import annotations

from pcb_worker.wavefront_obj import parse_obj

#: A 2.0 x 1.3 x 0.6 box in the vendor's dialect. Six quad faces, so the fan
#: triangulation has to turn them into twelve triangles; the two material runs
#: split four triangles from eight.
BOX = """\
v -1.0 -0.65 0.0
v 1.0 -0.65 0.0
newmtl 1
Ka 0.25098039215686274 0.25098039215686274 0.25098039215686274
Kd 0.25098039215686274 0.25098039215686274 0.25098039215686274
Ks 0.12549019607843137 0.12549019607843137 0.12549019607843137
d 0.0
endmtl
v 1.0 0.65 0.0
v -1.0 0.65 0.0
v -1.0 -0.65 0.6
newmtl 2
Ka 1.0 1.0 1.0
Kd 1.0 1.0 1.0
Ks 0.5019607843137255 0.5019607843137255 0.5019607843137255
d 0.0
endmtl
v 1.0 -0.65 0.6
v 1.0 0.65 0.6
v -1.0 0.65 0.6
vn 0.0 0.0 1.0
usemtl 1
f 1// 2// 3// 4//
f 5// 6// 7// 8//
usemtl 2
f 1// 2// 6// 5//
f 2// 3// 7// 6//
f 3// 4// 8// 7//
f 4// 1// 5// 8//
"""


def test_the_vendor_dialect_parses_to_geometry_and_its_inline_colours():
    """One wide test over everything the dialect makes non-obvious."""
    mesh = parse_obj(BOX)

    # Geometry: 1-based indices resolved, "//" slots stripped, quads fanned.
    assert len(mesh.vertices) == 8
    assert len(mesh.triangles) == 12
    assert all(0 <= i < 8 for tri in mesh.triangles for i in tri)
    low, high = mesh.bounds_mm()
    assert [round(high[i] - low[i], 6) for i in range(3)] == [2.0, 1.3, 0.6]
    assert low[2] == 0.0        # z starts at the seating plane

    # The colours a stock loader would have lost, because there is no mtllib
    # for it to follow.
    assert sorted(mesh.materials) == ["1", "2"]
    assert mesh.materials["2"].diffuse == (1.0, 1.0, 1.0)
    assert mesh.materials["1"].diffuse[0] == 0.25098039215686274
    assert mesh.materials["1"].specular is not None

    # `d` is carried RAW. Every real material measured states 0.0, which read
    # as an opacity would make the whole part invisible, so this must arrive
    # unmapped and let a consumer decide.
    assert mesh.materials["1"].dissolve == 0.0
    assert mesh.materials["2"].dissolve == 0.0

    # Which triangles wear which material: two quads under `1`, four under `2`.
    assert mesh.triangle_materials.count("1") == 4
    assert mesh.triangle_materials.count("2") == 8
    assert None not in mesh.triangle_materials

    # A directive we do not read is REPORTED, not silently dropped, so a vendor
    # that starts emitting normals or an mtllib shows up as a visible fact.
    assert mesh.ignored_directives == ("vn",)


def test_a_body_that_is_not_a_model_is_an_empty_mesh_and_never_an_exception():
    """A retired model uuid answers with an object-store XML error rather than
    a status we could branch on, so "empty mesh" is the absence signal the
    client keys on. It has to hold for every way a download can go wrong."""
    xml = ('<?xml version="1.0" encoding="UTF-8"?>\n<Error>\n'
           '  <Code>NoSuchKey</Code>\n</Error>')
    for body in (xml, "", "   \n#comment only\n", "<html><body>502</body></html>",
                 "v 0 0 0\nv 1 0 0\nf 1// 2//\n",       # a degenerate face
                 "v 0 0 0\nf 1// 9// 4//\n",            # indices off the end
                 "v nan-ish x y\n"):
        mesh = parse_obj(body)
        assert mesh.empty, body
        assert mesh.bounds_mm() is None


def test_relative_vertex_indices_resolve_against_the_running_count():
    """OBJ allows negative indices meaning "counting back from here". They are
    rare in these models but legal, and resolving them wrong would silently
    move geometry rather than fail."""
    mesh = parse_obj("v 0 0 0\nv 1 0 0\nv 0 1 0\nf -3// -2// -1//\n")
    assert mesh.triangles == ((0, 1, 2),)
