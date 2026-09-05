"""The clearance verb: exact mesh-to-mesh minimum distance, and its cache.

WHAT WOULD SHOW THIS WRONG (the oracle for the whole file)
Two bodies whose gap is a number a person can measure with a feeler gauge —
here two bars crossing at right angles with 0.8 mm of air between them. The
fixture is built from the gap, not from anything the code under test computes,
and the crossing arrangement is chosen so that the OBVIOUS wrong implementation
fails loudly: every vertex of either bar is more than 40 mm from the other bar,
so anything that samples vertices reports ~48 where the truth is 0.8.

The distance tests need python-fcl and the DSL tests need build123d, neither of
which is on a plain CI runner — they ship in the plugin's embedded runtime
bundle. Those tests skip there, so `test_backend_is_a_declared_runtime_pin`
runs unconditionally: a skip must never be able to mean "we quietly stopped
shipping the geometry backend".
"""

from __future__ import annotations

import hashlib
import math
import struct
import sys
from pathlib import Path

import pytest

from mcad_worker import clearance as clr
from mcad_worker import features as feat

# --- the fixture, in millimetres -------------------------------------------
# Bar A (the reference): long in X, narrow in Y, its top face at z = 0.
# Bar B (the solid):     long in Y, narrow in X, its bottom face at z = GAP.
# They cross over |x| <= 2, |y| <= 2, where the gap is face-to-face.
GAP_MM = 0.8
BAR_HALF_LENGTH = 50.0
BAR_HALF_WIDTH = 2.0
BAR_THICKNESS = 2.0
#: Every vertex of one bar is at least this far from the other bar, so a
#: vertex-sampling implementation cannot stumble onto the right answer.
VERTEX_SEPARATION_FLOOR_MM = 40.0


def _box(lo, hi):
    """Corner vertices and 12 triangles of an axis-aligned box."""
    verts = [
        (hi[0] if i & 4 else lo[0], hi[1] if i & 2 else lo[1], hi[2] if i & 1 else lo[2])
        for i in range(8)
    ]
    faces = [
        (0, 1, 3), (0, 3, 2), (4, 6, 7), (4, 7, 5),
        (0, 4, 5), (0, 5, 1), (2, 3, 7), (2, 7, 6),
        (0, 2, 6), (0, 6, 4), (1, 5, 7), (1, 7, 3),
    ]
    return verts, faces


def _bar_a():
    return _box(
        (-BAR_HALF_LENGTH, -BAR_HALF_WIDTH, -BAR_THICKNESS), (BAR_HALF_LENGTH, BAR_HALF_WIDTH, 0.0)
    )


def _bar_b():
    return _box(
        (-BAR_HALF_WIDTH, -BAR_HALF_LENGTH, GAP_MM),
        (BAR_HALF_WIDTH, BAR_HALF_LENGTH, GAP_MM + BAR_THICKNESS),
    )


def _blob_bytes(verts, faces):
    """The body of a mesh blob, packed exactly as geometry_checks.gd packs it."""
    body = b"".join(struct.pack("<3f", *v) for v in verts)
    body += b"".join(struct.pack("<3I", *f) for f in faces)
    return body


def write_blob(directory: Path, verts, faces) -> tuple[str, str]:
    """Write one blob and return (path, key). Mirrors the panel's writer.

    The key covers the HEADER as well as the body — the counts decide how the
    same bytes are read back, so they are part of what the digest identifies.
    """
    body = _blob_bytes(verts, faces)
    header = struct.pack("<8sIII", b"MCADMESH", 1, len(verts), len(faces))
    key = hashlib.sha256(header + body).hexdigest()
    path = directory / (key + ".mcadmesh")
    path.write_bytes(header + body)
    return str(path), key


@pytest.fixture(autouse=True)
def _clean_caches():
    clr.reset_caches()
    yield
    clr.reset_caches()


# ---------------------------------------------------------------------------
# The blob is the transport, so it is tested as one
# ---------------------------------------------------------------------------

class TestBlob:
    def test_round_trip_preserves_the_geometry(self, tmp_path):
        pytest.importorskip("numpy")
        verts, faces = _bar_a()
        path, key = write_blob(tmp_path, verts, faces)
        vertices, triangles = clr.read_blob(path, key)
        assert vertices.shape == (8, 3)
        assert triangles.shape == (12, 3)
        assert vertices.min(axis=0).tolist() == [-BAR_HALF_LENGTH, -BAR_HALF_WIDTH, -BAR_THICKNESS]
        assert vertices.max(axis=0).tolist() == [BAR_HALF_LENGTH, BAR_HALF_WIDTH, 0.0]

    def test_a_file_that_changed_under_its_key_is_refused(self, tmp_path):
        pytest.importorskip("numpy")
        verts, faces = _bar_a()
        path, key = write_blob(tmp_path, verts, faces)
        moved = [(x + 5.0, y, z) for (x, y, z) in verts]
        body = _blob_bytes(moved, faces)
        header = struct.pack("<8sIII", b"MCADMESH", 1, len(moved), len(faces))
        Path(path).write_bytes(header + body)
        with pytest.raises(clr.ClearanceError) as caught:
            clr.read_blob(path, key)
        assert key[:16] in str(caught.value)

    def test_a_foreign_or_truncated_file_is_refused_by_name(self, tmp_path):
        pytest.importorskip("numpy")
        foreign = tmp_path / "notamesh.mcadmesh"
        foreign.write_bytes(b"glTF\x02\x00\x00\x00" + b"\x00" * 32)
        with pytest.raises(clr.ClearanceError) as caught:
            clr.read_blob(str(foreign), "")
        assert "bad magic" in str(caught.value)

        verts, faces = _bar_a()
        path, key = write_blob(tmp_path, verts, faces)
        raw = Path(path).read_bytes()
        Path(path).write_bytes(raw[:-12])
        with pytest.raises(clr.ClearanceError):
            clr.read_blob(path, key)

    def test_an_out_of_range_index_is_refused(self, tmp_path):
        pytest.importorskip("numpy")
        verts, faces = _bar_a()
        broken = list(faces)
        broken[0] = (0, 1, 99)
        body = _blob_bytes(verts, broken)
        header = struct.pack("<8sIII", b"MCADMESH", 1, len(verts), len(broken))
        key = hashlib.sha256(header + body).hexdigest()
        path = tmp_path / (key + ".mcadmesh")
        path.write_bytes(header + body)
        with pytest.raises(clr.ClearanceError) as caught:
            clr.read_blob(str(path), key)
        assert "indexes vertex 99" in str(caught.value)


# ---------------------------------------------------------------------------
# The distance itself
# ---------------------------------------------------------------------------

class TestExactDistance:
    def test_the_gap_between_two_triangle_interiors_is_exact(self, tmp_path):
        """0.8 mm of air, realised nowhere near a vertex of either body."""
        fcl = pytest.importorskip("fcl")
        pytest.importorskip("numpy")
        import numpy as np

        a_verts, a_faces = _bar_a()
        b_verts, b_faces = _bar_b()

        # The premise, asserted before the answer: no vertex of either bar is
        # anywhere near the other bar, so vertex sampling cannot find 0.8.
        closest_vertex_pair = min(
            float(np.linalg.norm(np.array(p) - np.array(q)))
            for p in a_verts for q in b_verts
        )
        assert closest_vertex_pair > VERTEX_SEPARATION_FLOOR_MM

        path, key = write_blob(tmp_path, a_verts, a_faces)
        reference, _, _ = clr._tree_for(key, path)
        solid = clr._build_tree(
            np.asarray(b_verts, dtype=np.float64), np.asarray(b_faces, dtype=np.int64)
        )
        min_mm, solid_point, reference_point = clr._distance(fcl, solid, reference)

        assert abs(min_mm - GAP_MM) < 0.005
        # The realising pair lies on the two facing planes, inside the square
        # where the bars cross — the gap is face-to-face, not corner-to-corner.
        assert abs(reference_point[2] - 0.0) < 0.05
        assert abs(solid_point[2] - GAP_MM) < 0.05
        for point in (solid_point, reference_point):
            assert abs(point[0]) <= BAR_HALF_WIDTH + 0.05
            assert abs(point[1]) <= BAR_HALF_WIDTH + 0.05

    def test_overlapping_meshes_report_zero_and_no_points(self, tmp_path):
        fcl = pytest.importorskip("fcl")
        import numpy as np

        a_verts, a_faces = _bar_a()
        sunk = [(x, y, z - GAP_MM - 1.0) for (x, y, z) in _bar_b()[0]]
        path, key = write_blob(tmp_path, a_verts, a_faces)
        reference, _, _ = clr._tree_for(key, path)
        solid = clr._build_tree(
            np.asarray(sunk, dtype=np.float64),
            np.asarray(_bar_b()[1], dtype=np.int64),
        )
        min_mm, solid_point, reference_point = clr._distance(fcl, solid, reference)
        assert min_mm == 0.0
        assert solid_point == [] and reference_point == []


class TestTreeCache:
    def test_a_tree_is_built_once_and_named_by_hash_afterwards(self, tmp_path):
        pytest.importorskip("fcl")
        verts, faces = _bar_a()
        path, key = write_blob(tmp_path, verts, faces)

        first, triangles, cached = clr._tree_for(key, path)
        assert cached is False and triangles == len(faces)

        # No path this time: a cached tree must be reachable by its hash alone,
        # which is what keeps a 130k-triangle board off the wire per evaluation.
        second, _, cached_again = clr._tree_for(key, None)
        assert cached_again is True
        assert second is first

        # And a key nothing has uploaded is a miss, not a wrong answer.
        with pytest.raises(KeyError):
            clr._tree_for("0" * 64, None)

    def test_an_unknown_key_comes_back_as_an_upload_request(self):
        pytest.importorskip("fcl")
        reply = clr.clearance({
            "source": "part = cube(1, 1, 1)",
            "required_mm": 1.0,
            "targets": [{"reference": "board", "node": "Body", "key": "a" * 64}],
        })
        assert reply["ok"] is True
        result = reply["result"]
        assert result["checked"] is False
        assert result["missing_keys"] == ["a" * 64]
        assert result["pairs"] == []


# ---------------------------------------------------------------------------
# The verb
# ---------------------------------------------------------------------------

#: A solid the DSL can build in the same place as bar B: long in Y, narrow in
#: X, sitting GAP_MM above the world's z = 0 plane where bar A's top face is.
SOLID_SOURCE = "part = translate([%f, %f, %f], cube(%f, %f, %f))" % (
    -BAR_HALF_WIDTH, -BAR_HALF_LENGTH, GAP_MM,
    2 * BAR_HALF_WIDTH, 2 * BAR_HALF_LENGTH, BAR_THICKNESS,
)

#: A solid with TWO curvatures, tight and wide, in one shape. The angular
#: deflection has to hold the chord error on the WIDEST of them: an angle
#: chosen for the 2 mm bore leaves the 200 mm barrel a millimetre off its own
#: surface, and the reply's stated tolerance would be a fiction for most of
#: the part's area.
MIXED_TIGHT_R = 2.0
MIXED_WIDE_R = 200.0
MIXED_SOLID_SOURCE = "\n".join([
    "barrel = translate([0, 0, %f], cylinder(r=%f, h=%f))" % (
        GAP_MM, MIXED_WIDE_R, BAR_THICKNESS),
    "pin = translate([300, 0, %f], cylinder(r=%f, h=%f))" % (
        GAP_MM, MIXED_TIGHT_R, BAR_THICKNESS),
    "part = barrel + pin",
])

#: A CURVED solid in the same place, for the one question a box cannot answer.
#: A planar face tessellates to the same two triangles at any tolerance — the
#: chord of a straight edge is the edge — so a cube can never show that the
#: tolerance reached the mesher at all. A cylinder's facet count is a direct
#: function of the deviation allowed.
CURVED_RADIUS = BAR_HALF_WIDTH
CURVED_SOLID_SOURCE = "part = translate([0, 0, %f], cylinder(r=%f, h=%f))" % (
    GAP_MM, CURVED_RADIUS, BAR_THICKNESS,
)


def _max_chord_deviation(source: str, tolerance_mm: float,
                         radius_mm: float) -> float:
    """The worst distance from a tessellated chord to the true cylinder.

    The module's own tessellation, measured the way the error bar is defined:
    for every chord of the LATERAL surface — a triangle whose plane is not
    perpendicular to the axis, so the flat end caps (which are exact) are left
    out — the midpoint of that chord lies inside the circle by
    radius - hypot(x, y), and that is the sagitta the tolerance must bound.
    """
    import math as _math

    import numpy as np

    vertices, faces, _angular, _how, _effective, _bounded = clr._prepare_solid(
        source, tolerance_mm)
    points = np.asarray(vertices, dtype=float)
    worst = 0.0
    for triangle in faces:
        corners = [points[int(index)] for index in triangle[:3]]
        normal = np.cross(corners[1] - corners[0], corners[2] - corners[0])
        length = float(np.linalg.norm(normal))
        if length == 0.0:
            continue
        if abs(float(normal[2]) / length) > 0.9:
            continue  # an end cap: planar, and tessellated exactly
        for first, second in ((0, 1), (1, 2), (2, 0)):
            start = points[int(triangle[first])]
            end = points[int(triangle[second])]
            if abs(_math.hypot(start[0], start[1]) - radius_mm) > 1.0e-6:
                continue
            if abs(_math.hypot(end[0], end[1]) - radius_mm) > 1.0e-6:
                continue
            middle = (start + end) * 0.5
            worst = max(worst,
                        radius_mm - _math.hypot(middle[0], middle[1]))
    return worst


def test_two_meshes_with_the_same_body_bytes_cannot_share_a_key(tmp_path):
    """The counts are part of what a digest identifies.

    One buffer, two readings: N vertices with M triangles and a different
    (N', M') split of the SAME bytes are different geometry — the index words
    of one decode as coordinates of the other. A digest over the body alone
    gives them one key, and the panel's body store and this worker's cache
    then hand back whichever arrived first, with no hash failure anywhere and
    a wrong distance at the end of it.

    ORACLE: the two files. Same bytes after the header, different counts in
    it, and the keys must differ — and each must read back as the geometry it
    was written as.
    """
    verts = [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0),
             (1.0, 1.0, 0.0)]
    wide = write_blob(tmp_path, verts, [(0, 1, 2), (1, 3, 2)])
    # The same 4 vertices and 2 triangles, re-declared as 3 vertices and 3
    # triangles over the identical buffer: the fourth vertex's twelve bytes
    # become the first index triple.
    body = _blob_bytes(verts, [(0, 1, 2), (1, 3, 2)])
    header = struct.pack("<8sIII", b"MCADMESH", 1, 3, 3)
    key = hashlib.sha256(header + body).hexdigest()
    narrow = tmp_path / (key + ".mcadmesh")
    narrow.write_bytes(header + body)

    assert wide[1] != key, "two readings of one buffer share a key"
    vertices, triangles = clr.read_blob(wide[0], wide[1])
    assert vertices.shape == (4, 3) and triangles.shape == (2, 3)
    # And the other reading is not silently accepted either: under its own
    # counts the buffer's float words are indices into three vertices, which
    # is refused rather than decoded into geometry nobody wrote.
    with pytest.raises(clr.ClearanceError):
        clr.read_blob(str(narrow), key)


class TestClearanceVerb:
    def _reply(self, tmp_path, required_mm, tolerance_mm=None):
        verts, faces = _bar_a()
        path, key = write_blob(tmp_path, verts, faces)
        params = {
            "source": SOLID_SOURCE,
            "required_mm": required_mm,
            "targets": [
                {"reference": "board", "node": "Assembly/Bar", "key": key, "path": path}
            ],
        }
        if tolerance_mm is not None:
            params["tolerance_mm"] = tolerance_mm
        return clr.clearance(params)

    def test_a_clearance_that_is_met_passes_and_one_that_is_not_names_the_node(
        self, tmp_path
    ):
        pytest.importorskip("fcl")
        pytest.importorskip("build123d")

        loose = self._reply(tmp_path, 0.5)["result"]
        assert loose["checked"] is True
        assert loose["pass"] is True
        assert len(loose["pairs"]) == 1
        pair = loose["pairs"][0]
        assert abs(pair["min_mm"] - GAP_MM) < 0.005
        assert pair["pass"] is True
        assert pair["node"] == "Assembly/Bar"
        assert abs(pair["reference_point_mm"][2]) < 0.05
        assert abs(pair["solid_point_mm"][2] - GAP_MM) < 0.05

        tight = self._reply(tmp_path, 1.0)["result"]
        assert tight["pass"] is False
        assert tight["pairs"][0]["pass"] is False
        assert tight["pairs"][0]["node"] == "Assembly/Bar"

    def test_every_reply_states_the_tolerance_it_measured_at(self, tmp_path):
        """The tolerance is a BOUND the mesh keeps, not a label copied out.

        OCCT applies a linear deflection and an angular one together and the
        finer of the two wins, so a fixed angular value quietly becomes the
        real tolerance on a small curved face: this r = 2 cylinder came back
        with the same 500 triangles at 0.05 and at 0.005 mm, and the stated
        millimetres bounded nothing. The module therefore derives the angular
        deflection from the linear one and the solid's own tightest curvature
        — theta = 2*acos(1 - tol/r), the angle whose sagitta is the tolerance.

        ORACLE, and it is the geometry itself: every chord of the tessellated
        cylinder is measured against the true surface — the radius less the
        distance of that chord's midpoint from the axis, which IS the sagitta
        — and the largest of them must come in under the tolerance the reply
        states. That is the promise T13 makes to a caller subtracting the
        error bar from min_mm. The triangle counts must also differ, which is
        what says the parameter reached the mesher at all; a box would pass
        that half on 12 triangles at every tolerance there is.
        """
        pytest.importorskip("fcl")
        pytest.importorskip("build123d")
        verts, faces = _bar_a()
        path, key = write_blob(tmp_path, verts, faces)

        def _curved(tolerance_mm):
            return clr.clearance({
                "source": CURVED_SOLID_SOURCE,
                "required_mm": 0.5,
                "tolerance_mm": tolerance_mm,
                "targets": [{"reference": "board", "node": "Assembly/Bar",
                             "key": key, "path": path}],
            })["result"]

        coarse = _curved(0.05)
        fine = _curved(0.005)

        # The tolerance the mesh keeps: the request itself here, since the
        # angular floor is nowhere near binding on a 2 mm radius. (It is
        # compared approximately because it is the max of the request and a
        # sagitta computed from it, which agrees to float noise.)
        assert coarse["tessellation_tolerance_mm"] == pytest.approx(0.05)
        assert fine["tessellation_tolerance_mm"] == pytest.approx(0.005)
        assert coarse["requested_tolerance_mm"] == 0.05
        assert fine["requested_tolerance_mm"] == 0.005
        assert "0.05" in coarse["bound"] and "0.005" in fine["bound"]
        assert fine["solid_triangles"] > coarse["solid_triangles"]
        # The angular deflection is derived, and the reply says from what.
        assert coarse["angular_deflection_deg"] > fine["angular_deflection_deg"]
        assert "curved face" in coarse["angular_deflection_source"]

        # And the mesh keeps the promise, measured against the true cylinder.
        for tolerance in (0.05, 0.005):
            deviation = _max_chord_deviation(CURVED_SOLID_SOURCE, tolerance,
                                             CURVED_RADIUS)
            assert deviation <= tolerance, (tolerance, deviation)
            assert deviation > 0.0

    def test_a_tolerance_finer_than_the_mesher_will_go_is_reported_honestly(
            self, tmp_path):
        """The one number a caller subtracts, and it has to be true.

        A 200 mm barrel at a micron of tolerance asks for an angular step
        finer than this module will take: past MIN_ANGULAR_RAD the mesh would
        be one nobody can hold in memory, so the floor binds and the chords
        sit further out than the request. What the reply must NOT do is echo
        the request — a caller subtracts tessellation_tolerance_mm from
        min_mm and believes the result, so an error bar the mesh does not
        keep is worse than a coarse one.

        ORACLE: the sagitta at the floor, by hand — 200 * (1 - cos(0.005/2))
        = 0.000625 mm — against a requested 0.000001 mm. The reply states the
        first, keeps the request beside it, and says in `bound` that the floor
        is why.
        """
        pytest.importorskip("fcl")
        pytest.importorskip("build123d")
        verts, faces = _bar_a()
        path, key = write_blob(tmp_path, verts, faces)
        requested = 0.000001
        result = clr.clearance({
            "source": "part = translate([0, 0, %f], cylinder(r=%f, h=%f))" % (
                GAP_MM, MIXED_WIDE_R, BAR_THICKNESS),
            "required_mm": 0.5,
            "tolerance_mm": requested,
            "targets": [{"reference": "board", "node": "Assembly/Bar",
                         "key": key, "path": path}],
        })["result"]

        floor_sagitta = MIXED_WIDE_R * (1.0 - math.cos(clr.MIN_ANGULAR_RAD / 2))
        assert floor_sagitta == pytest.approx(0.000625, abs=1.0e-6)
        assert result["tessellation_tolerance_mm"] == pytest.approx(
            floor_sagitta, rel=1.0e-6)
        assert result["requested_tolerance_mm"] == requested
        assert result["angular_deflection_deg"] == pytest.approx(
            math.degrees(clr.MIN_ANGULAR_RAD))
        assert "%g" % floor_sagitta in result["bound"]

    def test_a_pair_is_graded_on_the_error_bar_the_reply_publishes(
            self, tmp_path):
        """A verdict and its error bar have to be the same arithmetic.

        Same 200 mm barrel at a micron: the floor binds, the reply says the
        chords keep 0.000625 mm, and a caller subtracts THAT. The barrel is
        put 0.0001 mm further from the bar than the 0.5 mm required, so the
        gap clears the requirement by the REQUESTED bar (0.5001 - 0.000001)
        and misses it by the effective one (0.5001 - 0.000625 = 0.499475). A
        pass here would be a row whose own published bound fails it.

        ORACLE: the barrel's bottom face is planar, tessellated exactly, and
        the bar's top face is the reference's own triangles, so min_mm is the
        translate distance to float precision; the two thresholds are
        0.000624 mm apart, well outside that. Lift the barrel by the full
        effective bar and the same pair must pass, which is what shows the
        verdict moved to the bound rather than simply tightening.
        """
        pytest.importorskip("fcl")
        pytest.importorskip("build123d")
        verts, faces = _bar_a()
        path, key = write_blob(tmp_path, verts, faces)
        required = 0.5
        requested = 0.000001
        effective = MIXED_WIDE_R * (1.0 - math.cos(clr.MIN_ANGULAR_RAD / 2))
        assert requested < 0.0001 < effective  # the gap sits between the bars

        def measure(lift_mm: float) -> dict:
            reply = clr.clearance({
                "source": "part = translate([0, 0, %.9f], cylinder(r=%f, h=%f))"
                          % (required + lift_mm, MIXED_WIDE_R, BAR_THICKNESS),
                "required_mm": required,
                "tolerance_mm": requested,
                "targets": [{"reference": "board", "node": "Assembly/Bar",
                             "key": key, "path": path}],
            })["result"]
            assert reply["tessellation_tolerance_mm"] == pytest.approx(
                effective, rel=1.0e-6)
            return reply

        short = measure(0.0001)
        pair = short["pairs"][0]
        assert pair["min_mm"] == pytest.approx(required + 0.0001, abs=1.0e-6)
        assert pair["min_mm"] - requested >= required  # the requested bar says yes
        assert pair["min_mm"] - effective < required   # the published one says no
        assert pair["pass"] is False
        assert short["pass"] is False
        assert pair["bound_mm"] == pytest.approx(pair["min_mm"] - effective,
                                                 abs=1.0e-9)
        assert "bound_mm" in short["bound"] and "required_mm" in short["bound"]

        clear = measure(effective + 0.0001)
        assert clear["pairs"][0]["pass"] is True
        assert clear["pass"] is True

    def test_the_widest_curve_is_the_one_the_angle_has_to_hold(self):
        """Two radii in one solid, and only one of them can set the angle.

        A 2 mm pin beside a 200 mm barrel. The sagitta of a fixed angle grows
        with the radius, so an angle derived from the TIGHTEST face — 0.2 rad
        at a 0.01 mm tolerance — leaves the barrel's chords a millimetre from
        its surface: a hundred times the error bar the reply states, over the
        largest area in the part.

        ORACLE: the barrel's own radius, measured on the mesh the module
        produces. Every lateral chord of the 200 mm face must sit within the
        stated tolerance of the true circle, and the angle must be the one
        that radius asks for rather than the pin's.
        """
        pytest.importorskip("build123d")
        tolerance = 0.01
        deviation = _max_chord_deviation(MIXED_SOLID_SOURCE, tolerance,
                                         MIXED_WIDE_R)
        assert deviation <= tolerance, deviation
        assert deviation > 0.0
        assert clr._curvature(MIXED_SOLID_SOURCE) == (
            pytest.approx(MIXED_WIDE_R, abs=1.0e-6), True)

    def test_a_cone_is_a_curved_face_too(self):
        """Cylinders and spheres are not the whole of curvature.

        A reader that recognises only those two returns the 2 mm pin's radius
        for a part whose widest curved face is a 200 mm CONE, and the angle it
        then chooses leaves that cone a millimetre from its own surface. The
        cone's radius runs with its parameter, so the answer is the wider end
        of the face's own trim rather than anything the surface says on its
        own.

        ORACLE: the DSL's own r1. And a surface kind this reader cannot
        measure at all must come back as UNKNOWN — None, so the caller falls
        back to a bound it can defend — rather than as "no curvature".
        """
        pytest.importorskip("build123d")
        source = "\n".join([
            "barrel = cylinder(r1=%f, r2=%f, h=20)" % (MIXED_WIDE_R, 100.0),
            "pin = translate([400, 0, 0], cylinder(r=%f, h=20))"
            % MIXED_TIGHT_R,
            "part = barrel + pin",
        ])
        assert feat.largest_curved_radius(source) == pytest.approx(
            MIXED_WIDE_R, abs=1.0e-6)
        # A part with no curved face at all has no radius to report either.
        assert feat.largest_curved_radius("part = cube(10, 10, 10)") is None

    def test_an_unrecognised_curved_face_is_not_promised_a_bound(self, tmp_path):
        """A guess about curvature is reported as a guess, not as a bound.

        An oblate spheroid — a 50 mm sphere squashed to a tenth of its height
        — is one B-spline face to OCCT, which this module's curvature reader
        cannot measure. Its bounding box is 100 x 100 x 10 mm, so the fallback
        radius is 50 mm; the surface at the pole has a radius of curvature of
        a^2/c = 500 mm, ten times that. The angle chosen for 50 mm leaves the
        pole's chords ten times further out than the number a reply derived
        from it would state, so that number is not a bound the mesh keeps.

        ORACLE: `curvature_report` itself says the face is unrecognised, and
        the reply must then carry tolerance_bounded False, keep the request,
        label the effective value as an estimate and say in `bound` that it
        is not guaranteed for unrecognised curved faces — while a part whose
        every curved face IS measured, and a part with no curved face at all,
        both come back bounded. The pass verdict is not this module's to
        withhold: the panel joins tolerance_bounded to its own verdict.
        """
        pytest.importorskip("fcl")
        pytest.importorskip("build123d")
        verts, faces = _bar_a()
        path, key = write_blob(tmp_path, verts, faces)
        requested = 0.01

        def _reply(source):
            return clr.clearance({
                "source": source,
                "required_mm": 0.5,
                "tolerance_mm": requested,
                "targets": [{"reference": "board", "node": "Assembly/Bar",
                             "key": key, "path": path}],
            })["result"]

        spheroid = ("part = translate([0, 0, %f], scale([1, 1, 0.1], "
                    "sphere(50)))" % (GAP_MM + 5.0))
        report = feat.curvature_report(spheroid)
        assert report["unrecognised_faces"] >= 1
        assert report["largest_radius_mm"] is None

        guessed = _reply(spheroid)
        assert guessed["checked"] is True
        assert guessed["tolerance_bounded"] is False
        assert guessed["requested_tolerance_mm"] == requested
        assert guessed["tessellation_tolerance_mm"] >= requested
        assert "not guaranteed for unrecognised curved faces" in guessed["bound"]
        assert "ESTIMATED" in guessed["bound"]
        assert "guessed from the mesh's own bounding box" \
            in guessed["angular_deflection_source"]

        measured = _reply(CURVED_SOLID_SOURCE)
        assert measured["tolerance_bounded"] is True
        assert "not guaranteed" not in measured["bound"]
        flat = _reply(SOLID_SOURCE)
        assert flat["tolerance_bounded"] is True
        assert "no curved face" in flat["angular_deflection_source"]

    def test_pairs_come_back_closest_first(self, tmp_path):
        pytest.importorskip("fcl")
        pytest.importorskip("build123d")
        near_verts, near_faces = _bar_a()
        far_verts = [(x, y, z - 10.0) for (x, y, z) in near_verts]
        near_path, near_key = write_blob(tmp_path, near_verts, near_faces)
        far_path, far_key = write_blob(tmp_path, far_verts, near_faces)

        result = clr.clearance({
            "source": SOLID_SOURCE,
            "required_mm": 0.5,
            "targets": [
                {"reference": "b", "node": "Far", "key": far_key, "path": far_path},
                {"reference": "b", "node": "Near", "key": near_key, "path": near_path},
            ],
        })["result"]
        assert [p["node"] for p in result["pairs"]] == ["Near", "Far"]
        assert result["pairs"][0]["min_mm"] < result["pairs"][1]["min_mm"]
        # Both clear 0.5 mm, so the verdict is a pass; the order is the point.
        assert result["pass"] is True

    def test_a_request_with_nothing_to_measure_is_refused_with_a_reason(self):
        for params, expected in (
            ({"targets": [{"key": "x"}]}, "source"),
            ({"source": SOLID_SOURCE}, "targets"),
            ({"source": SOLID_SOURCE, "targets": [{"key": "x"}],
              "tolerance_mm": 0.0}, "tolerance_mm"),
        ):
            reply = clr.clearance(params)
            assert reply["ok"] is False
            assert expected in reply["error"]["message"]


class TestBackendIsMandatory:
    def test_backend_is_a_declared_runtime_pin(self):
        """Runs everywhere, so a skipped suite cannot hide a dropped backend."""
        lock = (Path(__file__).resolve().parents[2]
                / "scripts" / "runtime-bundle.lock").read_text(encoding="utf-8")
        assert "python-fcl==" in lock
        assert "import fcl" in lock

    def test_a_missing_backend_fails_loudly_rather_than_approximating(
        self, monkeypatch
    ):
        """The one place a stand-in is unavoidable: the failure being tested is
        an absent compiled extension, which cannot be produced any other way."""
        class Blocker:
            def find_module(self, name, path=None):
                return self if name == "fcl" else None

            def find_spec(self, name, path=None, target=None):
                if name == "fcl":
                    raise ImportError("No module named 'fcl'")
                return None

        monkeypatch.delitem(sys.modules, "fcl", raising=False)
        monkeypatch.setattr(sys, "meta_path", [Blocker()] + sys.meta_path)
        with pytest.raises(clr.ClearanceError) as caught:
            clr._require_fcl()
        message = str(caught.value)
        assert "python-fcl" in message
