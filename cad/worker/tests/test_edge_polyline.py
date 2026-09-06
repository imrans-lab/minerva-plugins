"""Every registry edge carries itself as a drawable polyline.

The panel used to infer the solid's ortho outline from the tessellation, by
comparing triangle normals across each mesh edge. On a boolean seam over a
curved face OCCT emits slivers whose normals point anywhere, so the inference
came back as isolated fragments — arcs of dots that read as holes in the part.
The registry has no such problem: it is topology, and it now carries each edge
sampled to chord tolerance so a consumer can draw the edge itself.

ORACLE. An independent observation that would show this wrong: the sampled
points must lie ON the edge, which the registry describes by other means. For
a hole rim we know the centre and the radius (read from OCCT's arc geometry,
not from the sampler), so every point must be exactly that far from that
centre, and the chords must hug it to within the stated deflection. For any
edge we know its length, so the polyline walked end to end must be that long —
a sampler that shuffled its points, or repeated them, or ran the wrong curve,
would produce a longer path or a shorter one. Straightness is the control: a
straight edge samples to its two ends and nothing more.
"""

from __future__ import annotations

import math

import pytest

build123d = pytest.importorskip("build123d", exc_type=ImportError)

from mcad.parser import parse
from mcad.edge_polyline import EDGE_POLYLINE_DEFLECTION
from mcad.translator import Translator

# The smallest repro of the reported speckle: one cylinder fused into a
# two-section oval loft, standing near enough the rim that it breaks out
# through the SLOPED side rather than the flat top. That intersection is
# neither a line nor a circle, so before this it was the one thing the registry
# could not describe.
POST_X = 16.0
POST_RADIUS = 3.0
SEAM_SOURCE = f"""body = loft:
    z=0: oval(40, 26)
    z=14: oval(28, 18)
post = translate([{POST_X},0,4], cylinder(h=14, r={POST_RADIUS}))
body = body + post
"""

# A plate and a round post, both raised in ONE extrusion. The circle sits clear
# of the rectangle in the profile — a rect(40, 40) is centred, so it ends at
# x = 20, and the circle is centred at x = 30 — so the extrusion is two
# disjoint bodies. The extruded fast path numbers only the Z-, X- and
# Y-parallel edges it can read off the 2D profile, so the post's two arcs used
# to have no entry at all, and an outline drawn from entries would have left
# them off the drawing.
BOSS_RADIUS = 8.0
BOSS_SOURCE = f"""sketch:
    p = rect(40, 40) + circle({BOSS_RADIUS}) center at point(30, 0)
block = extrude(p, 20)
"""

# A plate with a through hole: straight edges and circular rims in one part.
PLATE_SOURCE = """sketch:
    p = rect(40, 40)
block = extrude(p, 20)
hole = translate([0, 0, -5], cylinder(h=30, r=5))
block = block - hole
"""


def _registry(source: str) -> list[dict]:
    translator = Translator()
    translator.translate(parse(source))
    name, _shape = translator.last_part()
    return translator.get_edge_registry(name)


def _polyline_length(points: list[list[float]]) -> float:
    return sum(
        math.dist(points[i], points[i + 1]) for i in range(len(points) - 1)
    )


def _max_offset_from_chord(points: list[list[float]]) -> float:
    """Furthest any sampled point strays from the straight line end to end."""
    start = points[0]
    span = [points[-1][i] - start[i] for i in range(3)]
    span_length = math.sqrt(sum(component * component for component in span))
    if span_length < 1e-12:
        return max(math.dist(point, start) for point in points)
    unit = [component / span_length for component in span]
    worst = 0.0
    for point in points:
        offset = [point[i] - start[i] for i in range(3)]
        along = sum(offset[i] * unit[i] for i in range(3))
        across = [offset[i] - along * unit[i] for i in range(3)]
        worst = max(worst, math.sqrt(sum(c * c for c in across)))
    return worst


class TestEveryEdgeIsDrawable:
    def test_every_entry_carries_at_least_two_points(self):
        registry = _registry(SEAM_SOURCE)
        assert registry, "the fused body must have edges to draw"
        short = [e["id"] for e in registry if len(e.get("polyline", [])) < 2]
        assert not short, (
            f"edges {short} cannot be drawn: an outline that skips them falls "
            "back to guessing, which is what speckled the panes"
        )

    def test_the_polyline_runs_between_the_entrys_own_endpoints(self):
        # Either way round: the registry reads its endpoints off the vertices
        # and the sampler off the parameter range, and nothing promises the
        # two agree on which end is first.
        for entry in _registry(SEAM_SOURCE):
            points = entry["polyline"]
            forward = (
                math.dist(points[0], entry["start"]) < 1e-6
                and math.dist(points[-1], entry["end"]) < 1e-6
            )
            backward = (
                math.dist(points[0], entry["end"]) < 1e-6
                and math.dist(points[-1], entry["start"]) < 1e-6
            )
            assert forward or backward, entry["id"]

    def test_walking_the_polyline_covers_the_edges_own_length(self):
        # Chords cut corners, so the walk is never longer than the edge and
        # never shorter than the edge minus what the deflection allows.
        for entry in _registry(SEAM_SOURCE):
            walked = _polyline_length(entry["polyline"])
            assert walked <= entry["length"] + 1e-6, entry["id"]
            assert walked > entry["length"] * 0.95, (
                f"edge {entry['id']} ({entry['kind']}, {entry['length']:.3f} mm) "
                f"walks only {walked:.3f} mm — its points are out of order or "
                "off the curve"
            )


class TestTheSeamThatSpeckled:
    """The post breaks out of the sloped side; the two curves that meet there
    are the arcs that speckled.

    ORACLE: those points must be on the POST, which the DSL states and the
    sampler knows nothing about — every one of them exactly POST_RADIUS from
    the post's axis. A sampler that walked the wrong curve, or that returned
    the chord instead of the curve, puts them somewhere else.
    """

    def _seams(self) -> list[dict]:
        seams = []
        for entry in _registry(SEAM_SOURCE):
            if entry["kind"] != "curve":
                continue
            if all(
                abs(math.hypot(point[0] - POST_X, point[1]) - POST_RADIUS) < 1e-6
                for point in entry["polyline"]
            ):
                seams.append(entry)
        return seams

    def test_the_break_out_leaves_two_seams_and_both_lie_on_the_post(self):
        assert len(self._seams()) == 2, (
            "the post breaks out of one side of the loft, leaving one "
            "intersection curve on each flank"
        )

    def test_each_seam_is_drawn_as_a_curve_and_not_as_a_chord(self):
        for seam in self._seams():
            assert len(seam["polyline"]) > 2, seam["id"]
            # Two points would draw a line that leaves the surface by far
            # more than the sampling tolerance, which is what shows on the pane.
            assert (
                _max_offset_from_chord(seam["polyline"])
                > EDGE_POLYLINE_DEFLECTION
            ), seam["id"]


class TestAgainstGeometryTheSamplerDidNotProduce:
    def test_a_hole_rim_samples_onto_its_own_circle(self):
        rims = [e for e in _registry(PLATE_SOURCE) if e["kind"] == "circle"]
        assert len(rims) == 2, "a through hole has a rim at each face"
        for rim in rims:
            centre = rim["center"]
            radius = rim["radius"]
            for point in rim["polyline"]:
                assert abs(math.dist(point, centre) - radius) < 1e-6, (
                    "a sampled point is off the arc OCCT reported"
                )
            # Sagitta of each chord against that same radius: what the eye
            # would see as a polygon instead of a circle.
            for index in range(len(rim["polyline"]) - 1):
                chord = math.dist(
                    rim["polyline"][index], rim["polyline"][index + 1]
                )
                sagitta = radius - math.sqrt(
                    max(radius * radius - (chord / 2.0) ** 2, 0.0)
                )
                assert sagitta <= EDGE_POLYLINE_DEFLECTION + 1e-6

    def test_a_straight_edge_is_its_two_ends_and_no_more(self):
        straights = [
            e
            for e in _registry(PLATE_SOURCE)
            if e["kind"] in ("straight", "longitudinal", "cap_edge")
        ]
        assert straights, "the block still has straight edges after the cut"
        assert all(len(e["polyline"]) == 2 for e in straights), (
            "a straight edge sampled into more than two points is wasted wire"
        )


class TestTheRegistryIsTheWholePart:
    """An outline drawn from the edge list is only the part if the edge list is.

    ORACLE: the DSL says there is a circle of BOSS_RADIUS in the profile, so
    the extruded solid has two arcs of exactly that radius. They are in the
    registry or they are not; nothing about the fast path's axis filters can
    argue with the number written in the source.
    """

    def test_the_profiles_arc_is_in_the_registry_at_its_stated_radius(self):
        arcs = [e for e in _registry(BOSS_SOURCE) if e["kind"] == "circle"]
        assert len(arcs) == 2, "the post has a rim at each end of the extrusion"
        assert all(abs(arc["radius"] - BOSS_RADIUS) < 1e-6 for arc in arcs)
        assert all(len(arc["polyline"]) > 2 for arc in arcs)

    def test_every_edge_of_the_solid_but_the_seam_has_an_entry(self):
        translator = Translator()
        translator.translate(parse(BOSS_SOURCE))
        name, shape = translator.last_part()
        registry = translator.get_edge_registry(name)
        # 15 edges: the plate's own 12 plus the post's two rims and the
        # parametric seam up its wall. The seam is a closure artifact of OCCT's
        # rolled surface, not a feature, and is filtered out.
        assert len(list(shape.edges())) == 15
        assert len(registry) == 14
        assert len({e["id"] for e in registry}) == 14, "ids must be unique"


class TestTheListingStaysReadable:
    """The points are for drawing, not for reading.

    ORACLE: the same registry reaches two very different readers. The panel's
    evaluation must carry the polylines or it cannot draw the part; the
    `list_edges` listing an agent reads must not, or a real enclosure answers
    "what edges are there?" with tens of thousands of coordinates.
    """

    def test_the_listing_drops_the_points_the_evaluation_keeps(self):
        from mcad_worker import methods

        methods.reset_caches()
        reply = methods._list_edges({"source": BOSS_SOURCE})
        assert reply["ok"] is True, reply
        listed = reply["result"]
        assert listed and all("id" in e and "kind" in e for e in listed)
        assert all("polyline" not in e for e in listed)
        assert all(len(e["polyline"]) >= 2 for e in _registry(BOSS_SOURCE))
