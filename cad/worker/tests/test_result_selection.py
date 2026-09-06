"""A program's trailing bare expression selects what the program evaluates to.

`enclosure = bottom + top` followed by a line reading only `hump_in` means
"evaluate hump_in": the reader assumes it, every example is written that way,
and bisecting a failing document by evaluating one sub-shape depends on it.
Before the fix the render target was the last ASSIGNED part, so the trailing
name did nothing and a program ending `hump_in` still evaluated `enclosure`.

ORACLE. An independent observation that would show this wrong: export the two
sources and open both files. If the trailing name selects, the `hump_in` file
holds one cylinder and the `enclosure` file holds two separated boxes; if the
last assignment still wins, the two files are byte-identical. Judging by
shape_name alone would NOT show it, which is why these assert body_count and
vertex count — the reported name could be right while the geometry is not.
"""

import pytest

from mcad.evaluator import EvaluationError, evaluate_source

# A lid parted from its base (two disjoint bodies) plus a separate boss. The
# last ASSIGNMENT is enclosure, so a trailing `hump_in` disagrees with it in
# body count and in vertex count — a cylinder is tessellated, a box is not.
PROGRAM = """base = cube(20,20,10)
lid = translate([0,0,12], cube(20,20,4))
hump_in = translate([5,5,2], cylinder(h=6,r=3))
enclosure = base + lid
"""


def _evaluated(tail: str):
    return evaluate_source(PROGRAM + tail)


class TestTrailingExpressionSelectsTheResult:
    def test_trailing_name_selects_that_binding(self):
        whole = _evaluated("enclosure\n")
        boss = _evaluated("hump_in\n")

        assert whole.shape_name == "enclosure"
        assert boss.shape_name == "hump_in"
        # The parted enclosure is two bodies; the boss is one.
        assert whole.body_count == 2
        assert boss.body_count == 1
        # And the meshes are genuinely different geometry, not one shape
        # reported under two names.
        assert len(boss.mesh["vertices"]) != len(whole.mesh["vertices"])
        # The boss lives in z 2..8; the enclosure spans z 0..16.
        assert max(v[2] for v in boss.mesh["vertices"]) == pytest.approx(8.0)
        assert max(v[2] for v in whole.mesh["vertices"]) == pytest.approx(16.0)

    def test_no_trailing_expression_keeps_the_last_assignment(self):
        result = _evaluated("")
        assert result.shape_name == "enclosure"
        assert result.body_count == 2

    def test_trailing_non_shape_is_a_translate_error(self):
        with pytest.raises(EvaluationError) as exc:
            _evaluated("wall = 2.5\nwall\n")
        message = str(exc.value)
        assert "wall" in message
        assert "3D shape" in message

    def test_feature_queries_follow_the_selection(self):
        # The B-Rep consumers (clearance, cylindrical features) resolve the
        # shape themselves; they must land on the selected binding too.
        from mcad_worker.features import _shape_for

        assert _shape_for(PROGRAM + "hump_in\n")[0] == "hump_in"
        assert _shape_for(PROGRAM + "enclosure\n")[0] == "enclosure"
