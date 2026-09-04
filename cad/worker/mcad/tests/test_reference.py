"""Tests for the mesh() reference primitive.

A reference is a pose the worker records and refuses to alter. The tests here
check three separable things:

* the composed matrix agrees with what OCCT does to a real solid given the
  same transform statements (so "reference pose" means the same thing as
  "solid pose"), and it depends on statement order;
* every geometry operation involving a reference fails loudly and names it,
  while a reference that merely exists changes nothing else in the document;
* the eval result carries the reference verbatim, and no file is ever opened
  (every path used here is fictional).
"""

from __future__ import annotations

import pytest

# Skip the module if build123d is absent, matching the other worker suites.
build123d = pytest.importorskip("build123d", exc_type=ImportError)

from mcad.evaluator import evaluate_source
from mcad.parser import parse
from mcad.reference import MeshReference
from mcad.translator import Translator, TranslatorError


def _translate(source: str) -> Translator:
    program = parse(source)
    t = Translator()
    t.translate(program)
    return t


def _matrix(source: str, name: str = "r") -> list[list[float]]:
    value = _translate(source).env[name]
    assert isinstance(value, MeshReference)
    return [list(row) for row in value.matrix]


def _apply(matrix, point):
    """Transform a 3D point by a 4x4 column-vector matrix."""
    x, y, z = point
    return tuple(
        matrix[row][0] * x + matrix[row][1] * y + matrix[row][2] * z + matrix[row][3]
        for row in range(3)
    )


def _assert_close(actual, expected, tol=1e-9):
    assert len(actual) == len(expected)
    for a, e in zip(actual, expected):
        if isinstance(e, (list, tuple)):
            _assert_close(a, e, tol)
        else:
            assert abs(a - e) < tol, f"{actual} != {expected}"


# ---------------------------------------------------------------------------
# 1. Pose composition
# ---------------------------------------------------------------------------

class TestPoseComposition:
    """Transform statements compose on a reference in statement order."""

    def test_nesting_order_changes_the_matrix(self):
        # Hand-composed expectations. rotate([0,0,90]) maps +X to +Y.
        #   translate(rotate(ref)) → T·R : the offset is applied in world space.
        #   rotate(translate(ref)) → R·T : the offset itself is rotated.
        outer_translate = _matrix(
            'r = translate([10, 0, 0], rotate([0, 0, 90], mesh("a.glb")))'
        )
        outer_rotate = _matrix(
            'r = rotate([0, 0, 90], translate([10, 0, 0], mesh("a.glb")))'
        )

        assert outer_translate != outer_rotate

        _assert_close(outer_translate, [
            [0.0, -1.0, 0.0, 10.0],
            [1.0, 0.0, 0.0, 0.0],
            [0.0, 0.0, 1.0, 0.0],
            [0.0, 0.0, 0.0, 1.0],
        ])
        _assert_close(outer_rotate, [
            [0.0, -1.0, 0.0, 0.0],
            [1.0, 0.0, 0.0, 10.0],
            [0.0, 0.0, 1.0, 0.0],
            [0.0, 0.0, 0.0, 1.0],
        ])

    # Each stack is written once and applied both to a real solid and to a
    # reference; the two must land in the same place. Note the two scale
    # stacks: build123d scales a shape about its own origin, so scale and
    # translate produce the same solid in either order — the reference has to
    # reproduce that, not an idealised world-space scale.
    STACKS = [
        "translate([10, 0, 0], rotate([0, 0, 90], {inner}))",
        "rotate([0, 0, 90], translate([10, 0, 0], {inner}))",
        "rotate([90, 0, 0], {inner})",
        "rotate([0, 45, 30], translate([1, 2, 3], {inner}))",
        # Uniform, because a reference refuses anything else (see
        # TestReferenceScaleMustBeUniform). The two orders still separate
        # right- from left-multiplication.
        "translate([5, -5, 2], scale([2, 2, 2], {inner}))",
        "scale([2, 2, 2], translate([5, -5, 2], {inner}))",
        "mirror([1, 0, 0], translate([7, 1, 2], {inner}))",
        "translate([0, 0, 9], mirror([0, 1, 0], rotate([0, 0, 30], {inner})))",
    ]

    @pytest.mark.parametrize("stack", STACKS)
    def test_reference_pose_matches_the_same_transforms_on_a_solid(self, stack):
        """The composed matrix reproduces OCCT's own answer.

        The solid is the independent observation: if the matrix used a
        different rotation convention, a different composition order, or
        pre- instead of post-multiplication, the two bounding boxes diverge.
        """
        box = (2.0, 4.0, 6.0)  # cube() places the corner at the origin
        solid = _translate(
            "s = " + stack.format(inner=f"cube({box[0]}, {box[1]}, {box[2]})")
        ).env["s"]
        matrix = _matrix("r = " + stack.format(inner='mesh("a.glb")'))

        corners = [
            (x, y, z)
            for x in (0.0, box[0])
            for y in (0.0, box[1])
            for z in (0.0, box[2])
        ]
        posed = [_apply(matrix, corner) for corner in corners]
        expected_min = [min(p[axis] for p in posed) for axis in range(3)]
        expected_max = [max(p[axis] for p in posed) for axis in range(3)]

        bbox = solid.bounding_box()
        _assert_close(
            [bbox.min.X, bbox.min.Y, bbox.min.Z], expected_min, tol=1e-6
        )
        _assert_close(
            [bbox.max.X, bbox.max.Y, bbox.max.Z], expected_max, tol=1e-6
        )

    def test_a_reference_is_never_altered_in_place(self):
        t = _translate(
            'a = mesh("a.glb")\n'
            'b = translate([5, 0, 0], a)\n'
        )
        assert list(t.env["a"].matrix[0]) == [1.0, 0.0, 0.0, 0.0]
        assert list(t.env["b"].matrix[0]) == [1.0, 0.0, 0.0, 5.0]
        assert [ref["name"] for ref in t.get_references()] == ["a", "b"]


class TestReferenceScaleMustBeUniform:
    """A reference is measured, not rendered.

    The panel reports a hole's diameter in world millimetres by scaling the
    fitted radius with the pose, which only has an answer when the pose scales
    every axis alike: scale([1, 2, 1], board) turns every hole in the file into
    an ellipse that has no diameter and takes no pin. A zero factor is worse —
    the pose stops being invertible, so no measured world point maps back to a
    point in the file.
    """

    def test_a_uniform_scale_is_accepted_and_composes(self):
        matrix = _matrix('r = scale([2, 2, 2], mesh("a.glb"))')
        _assert_close(matrix, [
            [2.0, 0.0, 0.0, 0.0],
            [0.0, 2.0, 0.0, 0.0],
            [0.0, 0.0, 2.0, 0.0],
            [0.0, 0.0, 0.0, 1.0],
        ])

    @pytest.mark.parametrize("factors", ["[1, 2, 1]", "[2, 2, 3]", "[-1, 1, 1]"])
    def test_a_non_uniform_scale_is_refused_by_name(self, factors):
        with pytest.raises(TranslatorError) as excinfo:
            _translate(f'board = scale({factors}, mesh("boards/main.glb"))\n')
        message = str(excinfo.value)
        assert "uniform" in message
        assert "boards/main.glb" in message

    @pytest.mark.parametrize("factors", ["[0, 0, 0]", "[1, 0, 1]"])
    def test_a_zero_scale_is_refused_by_name(self, factors):
        with pytest.raises(TranslatorError) as excinfo:
            _translate(f'board = scale({factors}, mesh("boards/main.glb"))\n')
        message = str(excinfo.value)
        assert "zero" in message
        assert "boards/main.glb" in message

    def test_a_non_uniform_scale_on_a_SOLID_is_still_fine(self):
        # The refusal is about references, not about scale(): a B-Rep solid
        # scaled unevenly is ordinary modelling and must keep working.
        solid = _translate("s = scale([1, 2, 3], cube(10, 10, 10))").env["s"]
        bbox = solid.bounding_box()
        _assert_close(
            [bbox.max.X, bbox.max.Y, bbox.max.Z], [10.0, 20.0, 30.0], tol=1e-6
        )


# ---------------------------------------------------------------------------
# 2. Geometry operations refuse a reference
# ---------------------------------------------------------------------------

class TestReferenceRefusesGeometry:

    def test_boolean_with_a_reference_names_it(self):
        with pytest.raises(TranslatorError) as excinfo:
            _translate('part = cube(10, 10, 10) - mesh("a.glb")')
        message = str(excinfo.value)
        assert "a.glb" in message

    @pytest.mark.parametrize("statement", [
        'part = cube(10, 10, 10) + ref',
        'part = ref - cube(10, 10, 10)',
        'fillet ref, 1, r=2',
        'chamfer ref, 1, d=1',
        'shell ref, 1.5',
        'part = extrude(ref, 10)',
        'export ref "out.stl"',
    ])
    def test_every_geometry_operation_names_the_reference(self, statement):
        with pytest.raises(TranslatorError) as excinfo:
            _translate('ref = mesh("boards/main.glb")\n' + statement + "\n")
        # The path is the load-bearing part: "reference" alone would make a
        # substring check on the variable name pass by accident.
        assert "boards/main.glb" in str(excinfo.value)

    def test_a_reference_that_merely_exists_changes_nothing(self):
        plain = evaluate_source(
            "part = cube(10, 10, 10)\n"
        )
        with_reference = evaluate_source(
            'ref = mesh("a.glb")\n'
            "part = cube(10, 10, 10)\n"
        )
        # Edge ids come from OCCT traversal of real solids; a reference must
        # not add, drop or renumber any of them.
        assert with_reference.edges == plain.edges
        assert with_reference.mesh == plain.mesh
        assert with_reference.shape_name == plain.shape_name
        assert plain.references == []
        assert len(with_reference.references) == 1

    def test_rebinding_a_reference_name_retires_the_reference(self):
        # The report must mirror the final environment: a name that once held
        # a reference and now holds a solid reports no reference at all.
        result = evaluate_source(
            'board = mesh("a.glb")\n'
            "board = cube(10, 10, 10)\n"
        )
        assert result.references == []
        assert result.shape_name == "board"

    def test_escaped_path_round_trips_through_the_lexer(self):
        # The GUI import escapes backslashes and quotes when it writes the
        # line; the value the worker reports must be the original path.
        result = evaluate_source(
            'ref = mesh("C:\\\\meshes\\\\a \\"b\\".glb")\n'
        )
        assert result.references[0]["path"] == 'C:\\meshes\\a "b".glb'

    def test_unary_minus_names_the_reference(self):
        with pytest.raises(TranslatorError, match="a.glb"):
            _translate('ref = mesh("a.glb")\npart = -ref\n')


# ---------------------------------------------------------------------------
# 3. What the eval result reports
# ---------------------------------------------------------------------------

class TestReferenceReporting:

    def test_result_carries_path_units_up_and_matrix(self):
        result = evaluate_source(
            'board = translate([1, 2, 3], mesh("../boards/main.glb"))\n'
            "part = cube(10, 10, 10)\n"
        )
        assert len(result.references) == 1
        ref = result.references[0]
        assert ref["name"] == "board"
        # Recorded verbatim — resolving it is the panel's job.
        assert ref["path"] == "../boards/main.glb"
        assert ref["units"] == "m"
        assert ref["up"] == "y"
        assert [row[3] for row in ref["matrix"][:3]] == [1.0, 2.0, 3.0]
        assert ref["matrix"][3] == [0.0, 0.0, 0.0, 1.0]

    @pytest.mark.parametrize("path,units,up", [
        ("part.glb", "m", "y"),
        ("part.gltf", "m", "y"),
        ("part.stl", "mm", "z"),
        ("part.obj", "mm", "z"),
        ("PART.GLB", "m", "y"),
    ])
    def test_format_defaults(self, path, units, up):
        ref = _translate(f'r = mesh("{path}")').env["r"]
        assert (ref.units, ref.up) == (units, up)

    def test_explicit_units_and_up_override_the_format_default(self):
        ref = _translate('r = mesh("part.glb", units="mm", up="z")').env["r"]
        assert (ref.units, ref.up) == ("mm", "z")

    @pytest.mark.parametrize("call", [
        'mesh("part.glb", units="furlongs")',
        'mesh("part.glb", up="w")',
        'mesh("")',
        "mesh(12)",
        'mesh("a.glb", "b.glb")',
        'mesh("a.glb", scale=2)',
    ])
    def test_malformed_mesh_calls_are_rejected(self, call):
        with pytest.raises(TranslatorError):
            _translate(f"r = {call}\n")

    def test_a_document_of_references_only_evaluates(self):
        """The GUI import writes a mesh() line before any solid exists."""
        result = evaluate_source('board = mesh("a.glb")\n')
        assert result.mesh == {"vertices": [], "faces": []}
        assert result.edges == []
        assert [ref["name"] for ref in result.references] == ["board"]
