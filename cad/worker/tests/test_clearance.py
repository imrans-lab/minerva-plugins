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
import struct
import sys
from pathlib import Path

import pytest

from mcad_worker import clearance as clr

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
    """Write one blob and return (path, key). Mirrors the panel's writer."""
    body = _blob_bytes(verts, faces)
    key = hashlib.sha256(body).hexdigest()
    path = directory / (key + ".mcadmesh")
    header = struct.pack("<8sIII", b"MCADMESH", 1, len(verts), len(faces))
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
        key = hashlib.sha256(body).hexdigest()
        path = tmp_path / (key + ".mcadmesh")
        path.write_bytes(
            struct.pack("<8sIII", b"MCADMESH", 1, len(verts), len(broken)) + body
        )
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
        pytest.importorskip("fcl")
        pytest.importorskip("build123d")
        coarse = self._reply(tmp_path, 0.5, tolerance_mm=0.05)["result"]
        fine = self._reply(tmp_path, 0.5, tolerance_mm=0.005)["result"]

        assert coarse["tessellation_tolerance_mm"] == 0.05
        assert fine["tessellation_tolerance_mm"] == 0.005
        assert "0.05" in coarse["bound"] and "0.005" in fine["bound"]

        # The tolerance is what the measurement was MADE at, not a label:
        # a coarser tessellation of the same solid is a different set of
        # triangles, and the reply has to carry the one it used.
        assert coarse["solid_triangles"] != fine["solid_triangles"]

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
                / "scripts" / "runtime-bundle.lock").read_text()
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
