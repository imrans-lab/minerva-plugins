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

import math

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


def test_a_non_finite_coordinate_never_reaches_the_mesh_or_its_bounds():
    """MUTATION THIS CATCHES: ``float("nan")`` and ``float("inf")`` parse, so a
    reader that only guards against ``ValueError`` lets them straight through.
    One of them poisons every bounding box computed from the mesh — a NaN makes
    min/max return whichever value it was compared against first, an inf makes
    the part the size of the scene — and any file written from it, and it does
    that while the mesh looks entirely well formed.

    ORACLE: the box's own arithmetic. A model with a poisoned vertex must
    measure exactly what the CLEAN corners measure, and the poisoned corner's
    faces must be gone rather than drawn to a substituted position.
    """
    clean = parse_obj("v 0 0 0\nv 2 0 0\nv 2 1 0\nv 0 1 0\nf 1// 2// 3// 4//\n")
    assert clean.bounds_mm() == ((0.0, 0.0, 0.0), (2.0, 1.0, 0.0))

    for bad in ("nan nan nan", "inf 0 0", "0 -inf 0", "NaN 1 0"):
        # The poisoned vertex is the FIRST one, so its slot has to be held: the
        # faces below index by position in the `v` stream, and dropping the line
        # would renumber them onto other points instead of removing them.
        mesh = parse_obj(
            f"v {bad}\nv 0 0 0\nv 2 0 0\nv 2 1 0\nv 0 1 0\n"
            "f 1// 2// 3//\n"          # touches the poisoned vertex: dropped
            "f 2// 3// 4// 5//\n")     # the clean square: kept
        assert all(all(math.isfinite(c) for c in p) for p in mesh.vertices), bad
        assert mesh.bounds_mm() == ((0.0, 0.0, 0.0), (2.0, 1.0, 0.0)), bad
        assert len(mesh.triangles) == 2, bad

    # The same rule on a material: a colour channel that is not a number leaves
    # the field unset rather than carrying an inf into a renderer.
    material = parse_obj("newmtl m\nKd 1.0 inf 0.5\nd nan\nendmtl\n").materials["m"]
    assert material.diffuse is None and material.dissolve is None


def test_a_degenerate_face_is_dropped_rather_than_counted_as_geometry():
    """MUTATION THIS CATCHES: a triangle with a repeated corner, or three
    collinear ones, kept as if it were a surface. It has zero area and no
    normal, so it draws nothing and cannot be lit — but it inflates a triangle
    count, and it makes any closure or area check downstream read as a defect in
    the mesh rather than in the file it came from.

    ORACLE: the same square, written three ways. Only the well-formed corners
    survive, and a body made only of degenerate faces is EMPTY — which is the
    signal the client turns into a reported absence.
    """
    square = "v 0 0 0\nv 2 0 0\nv 2 1 0\nv 0 1 0\n"
    assert len(parse_obj(square + "f 1// 2// 3// 4//\n").triangles) == 2

    # A repeated corner, and a quad that repeats one — the fan then produces
    # one zero-area ear and one real triangle, and only the real one is kept.
    assert parse_obj(square + "f 1// 1// 3//\n").triangles == ()
    assert parse_obj(square + "f 1// 2// 2// 3//\n").triangles == ((0, 1, 2),)

    # Three collinear points: a legal face, no area.
    assert parse_obj("v 0 0 0\nv 1 0 0\nv 2 0 0\nf 1// 2// 3//\n").triangles == ()
    assert parse_obj("v 0 0 0\nv 1 0 0\nv 2 0 0\nf 1// 2// 3//\n").empty
