"""The render target is the LAST 3D binding, even when it holds two bodies.

An OCCT boolean on two Solids returns a ShapeList when the operands stay
disjoint. A list has no ``tessellate`` and no ``volume``, so ``part = a + b``
of two separated halves never became the render target: the panel, and every
check that reads the evaluated solid, kept showing whichever half was bound
last before it. Every number was right about the wrong body.

ORACLE. An independent observation that would show this wrong: export the same
source and open it in a mesh viewer. Both halves are there, and the bounding
box spans both. If the reply's bounds cover only one half while the exported
file has two, the render target is still being picked by type rather than by
binding order.
"""

from mcad.evaluator import evaluate_source

# Two 10 mm cubes 20 mm apart, each cut by its own bore, unioned last. The
# union is disjoint, which is the whole point.
SOURCE_E = """a = cube(10,10,10)
b = translate([20,0,0], cube(10,10,10))
a = a - translate([5,5,-1], cylinder(h=12,r=1))
b = b - translate([25,5,-1], cylinder(h=12,r=2))
part = a + b
"""

# The two halves of an enclosure parted with a 0.3 mm gap, each drilled, then
# unioned. Nothing touches, so the union is a compound.
SOURCE_F = """outer = cube(30,30,20)
inner = translate([2,2,2], cube(26,26,16))
hollow = outer - inner
bottom = hollow - translate([-1,-1,10], cube(32,32,20))
lid = hollow - translate([-1,-1,-10], cube(32,32,20.3))
bottom = bottom - translate([15,15,-1], cylinder(h=6,r=1))
lid = lid - translate([15,15,14], cylinder(h=10,r=2))
part = bottom + lid
"""

# The halves touching: this always worked, and is here because it is what hides
# the defect — a fused pair comes back as one Solid.
SOURCE_G = """outer = cube(30,30,20)
inner = translate([2,2,2], cube(26,26,16))
hollow = outer - inner
bottom = hollow - translate([-1,-1,10], cube(32,32,20))
lid = hollow - translate([-1,-1,-10], cube(32,32,20))
part = bottom + lid
"""


def _bounds(result):
    xs = [v[0] for v in result.mesh["vertices"]]
    ys = [v[1] for v in result.mesh["vertices"]]
    zs = [v[2] for v in result.mesh["vertices"]]
    return (min(xs), min(ys), min(zs)), (max(xs), max(ys), max(zs))


class TestDisjointUnionIsTheRenderTarget:
    def test_two_bored_cubes_render_as_part(self):
        result = evaluate_source(SOURCE_E)
        assert result.shape_name == "part"
        assert result.body_count == 2
        low, high = _bounds(result)
        # Both cubes: x runs 0..30, not 0..10 (a alone) or 20..30 (b alone).
        assert low[0] == 0.0
        assert high[0] == 30.0

    def test_a_parted_enclosure_renders_both_halves(self):
        result = evaluate_source(SOURCE_F)
        assert result.shape_name == "part"
        assert result.body_count == 2
        low, high = _bounds(result)
        # The bottom runs z 0..10 and the lid z 10.3..20; the whole part is the
        # union of both, so only a target of "lid" would start above zero.
        assert low[2] == 0.0
        assert high[2] == 20.0

    def test_touching_halves_are_one_body(self):
        result = evaluate_source(SOURCE_G)
        assert result.shape_name == "part"
        assert result.body_count == 1

    def test_a_single_solid_reports_one_body(self):
        result = evaluate_source("part = cube(10,10,10)\n")
        assert result.shape_name == "part"
        assert result.body_count == 1
