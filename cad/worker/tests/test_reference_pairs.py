"""Reference against reference: the part-layout measurement.

WHAT WOULD SHOW THIS WRONG (the oracle for the whole file)
Two stand-in parts whose gap is a number chosen by the fixture and not by
anything the code computes: two blocks 0.5 mm apart in x must be reported at
0.5 mm, and the pair that is 12 mm away must sort behind them. The blocks are
placed so that no vertex of one is 0.5 mm from a vertex of the other — the
facing faces overlap in y and z but their corners do not line up — so an
implementation that compared vertices, or bounding boxes of whole files, would
report a different number rather than stumbling onto the right one.

Overlap is the second case: two blocks driven into each other must come back
with overlap true, no gap, and the contact points where they meet.

The distance tests need python-fcl, which is not on a plain CI runner: it
ships in the plugin's embedded runtime bundle, and the pairing tests that need
no geometry backend run unconditionally so a skip cannot mean the whole file
went quiet.
"""

from __future__ import annotations

import pytest

from mcad_worker import clearance as clr
from mcad_worker import reference_pairs as rp
from .test_clearance import _box, write_blob

#: The gap the fixture is built from, in millimetres.
GAP_MM = 0.5
#: The second part's distance, far enough that it can only sort behind.
FAR_GAP_MM = 12.0


def _part(lo_x, size=(6.0, 8.0, 4.0), offset_y=0.0):
    """A block starting at `lo_x`, offset in y so no two corners line up."""
    return _box((lo_x, offset_y, 0.0),
                (lo_x + size[0], offset_y + size[1], size[2]))


@pytest.fixture(autouse=True)
def _clean_caches():
    clr.reset_caches()
    yield
    clr.reset_caches()


def _target(tmp_path, reference, node, verts, faces):
    path, key = write_blob(tmp_path, verts, faces)
    return {"reference": reference, "node": node, "key": key, "path": path}


class TestPairing:
    """Which pairs get measured — no geometry backend needed."""

    def test_pairs_default_to_every_cross_reference_pair(self):
        targets = [
            {"reference": "a", "node": "A/1"},
            {"reference": "a", "node": "A/2"},
            {"reference": "b", "node": "B/1"},
        ]
        pairs = rp._pair_list(targets, None)
        assert sorted(pairs) == [(0, 2), (1, 2)]

    def test_two_nodes_of_one_reference_are_not_a_pair(self):
        """They are parts of ONE part; a bracket meeting its own boss is not
        the question this verb is asked."""
        targets = [{"reference": "a", "node": "A/1"},
                   {"reference": "a", "node": "A/2"}]
        assert rp._pair_list(targets, None) == []

    def test_a_stated_pair_out_of_range_is_refused_by_name(self):
        targets = [{"reference": "a", "node": "A/1"},
                   {"reference": "b", "node": "B/1"}]
        with pytest.raises(clr.ClearanceError) as exc:
            rp._pair_list(targets, [[0, 5]])
        assert "outside params.targets" in str(exc.value)


class TestMeasurement:
    def test_two_parts_half_a_millimetre_apart_report_half_a_millimetre(self, tmp_path):
        """THE ORACLE: the gap the fixture was built with, and the ordering.

        Three parts: the near one 0.5 mm from the first, the far one 12 mm.
        Both distances are face-to-face across offset blocks, so no vertex
        pair and no whole-file bounding box gives 0.5.
        """
        pytest.importorskip("fcl")
        verts_a, faces_a = _part(0.0)
        verts_b, faces_b = _part(6.0 + GAP_MM, offset_y=3.0)
        verts_c, faces_c = _part(6.0 + FAR_GAP_MM, offset_y=1.0)
        params = {
            "required_mm": 1.0,
            "targets": [
                _target(tmp_path, "stick", "Stick/Housing", verts_a, faces_a),
                _target(tmp_path, "devkit", "Devkit/Body", verts_b, faces_b),
                _target(tmp_path, "oled", "Oled/Body", verts_c, faces_c),
            ],
            "pairs": [[0, 1], [0, 2]],
        }
        reply = rp.reference_pairs(params)
        assert reply["ok"] is True
        result = reply["result"]
        assert result["checked"] is True
        near, far = result["pairs"]
        assert near["a"]["node"] == "Stick/Housing"
        assert near["b"]["node"] == "Devkit/Body"
        assert near["min_mm"] == pytest.approx(GAP_MM, abs=1e-4)
        assert far["min_mm"] == pytest.approx(FAR_GAP_MM, abs=1e-4)
        # Graded against the call's own required_mm, and the closest pair is
        # the one that fails it.
        assert near["pass"] is False and far["pass"] is True
        assert result["pass"] is False
        # The points that realise the gap lie on the two facing faces.
        assert near["point_a_mm"][0] == pytest.approx(6.0, abs=1e-4)
        assert near["point_b_mm"][0] == pytest.approx(6.0 + GAP_MM, abs=1e-4)

    def test_parts_driven_into_each_other_report_overlap_and_where(self, tmp_path):
        """An unsigned distance is 0 for contact and for containment alike, so
        the pair is reported as overlap with the contact points and never as a
        gap.

        ORACLE: the fixture's own overlap, derived from the two blocks. A is
        x 0..6, y 0..8, z 0..4; B is x 5..11, y 3..11, z 0..4. They share
        exactly x 5..6, y 3..8, z 0..4, so every reported contact point must
        lie in that box. FCL's raw position is a corner of an intersecting
        triangle and lands as far out as x 11 — a point on B's far face,
        6 mm from anything the two share.
        """
        pytest.importorskip("fcl")
        verts_a, faces_a = _part(0.0)
        verts_b, faces_b = _part(5.0, offset_y=3.0)
        params = {
            "required_mm": 0.0,
            "targets": [
                _target(tmp_path, "collar", "Collar/Body", verts_a, faces_a),
                _target(tmp_path, "devkit", "Devkit/Body", verts_b, faces_b),
            ],
        }
        result = rp.reference_pairs(params)["result"]
        pair = result["pairs"][0]
        assert pair["min_mm"] == 0.0
        assert pair["overlap"] is True
        assert pair["pass"] is False
        assert pair["contact_count"] >= 1
        assert pair["contact_points_mm"]
        for point in pair["contact_points_mm"]:
            assert 5.0 <= point[0] <= 6.0
            assert 3.0 <= point[1] <= 8.0
            assert 0.0 <= point[2] <= 4.0
        assert "point_a_mm" not in pair

    def test_a_target_the_worker_has_never_seen_is_asked_for_and_not_failed(
        self, tmp_path
    ):
        """The upload protocol, which the panel's retry depends on: an
        uncached key with no path comes back in missing_keys with
        checked:false, not as an error.

        ORACLE: the key itself, written by the fixture and then withheld.
        """
        pytest.importorskip("fcl")
        verts_a, faces_a = _part(0.0)
        verts_b, faces_b = _part(6.0 + GAP_MM, offset_y=3.0)
        first = _target(tmp_path, "a", "A/1", verts_a, faces_a)
        second = _target(tmp_path, "b", "B/1", verts_b, faces_b)
        second.pop("path")
        result = rp.reference_pairs({"targets": [first, second]})["result"]
        assert result["checked"] is False
        assert result["missing_keys"] == [second["key"]]

    def test_a_reference_node_measured_twice_builds_its_tree_once(self, tmp_path):
        """The trees are the clearance module's cache, shared with the
        solid-against-reference check: measuring a node against the solid and
        then against another part must not pay for a second BVH.

        ORACLE: `cache.hits` on the second call, over the same keys.
        """
        pytest.importorskip("fcl")
        verts_a, faces_a = _part(0.0)
        verts_b, faces_b = _part(6.0 + GAP_MM, offset_y=3.0)
        params = {
            "targets": [
                _target(tmp_path, "a", "A/1", verts_a, faces_a),
                _target(tmp_path, "b", "B/1", verts_b, faces_b),
            ],
        }
        first = rp.reference_pairs(params)["result"]
        assert first["cache"]["hits"] == 0
        second = rp.reference_pairs(params)["result"]
        assert second["cache"]["hits"] == 2


def test_a_request_with_nothing_to_pair_is_an_error_and_not_a_clean_bill():
    """One part on its own is not "everything clears": the verb says so."""
    reply = rp.reference_pairs({"targets": [{"reference": "a", "node": "A/1",
                                             "key": "0" * 64}]})
    assert reply["ok"] is False
    assert "no pair" in reply["error"]["message"]


class TestContainment:
    """A positive surface distance is not air between the PARTS.

    ORACLE: the fixture's own nesting. A is the cube [0,10]^3 and B the cube
    [2,3]^3 — B lies wholly inside A with 2 mm of air between the surfaces —
    so a pair that reports 2 mm and passes a 0.5 mm requirement has certified
    a crash. The same B moved to [12,13]^3 is beside A, its box outside A's,
    and passes on the same 2 mm. And A with one triangle removed is no longer
    a closed mesh, so parity cannot answer: the pair says undecidable and
    withholds the pass rather than guessing either way.
    """

    def test_a_part_inside_another_is_an_overlap_not_a_gap(self, tmp_path):
        pytest.importorskip("fcl")
        verts_a, faces_a = _box((0.0, 0.0, 0.0), (10.0, 10.0, 10.0))
        verts_b, faces_b = _box((2.0, 2.0, 2.0), (3.0, 3.0, 3.0))
        result = rp.reference_pairs({
            "required_mm": 0.5,
            "targets": [_target(tmp_path, "shell", "Shell/Body", verts_a, faces_a),
                        _target(tmp_path, "cap", "Cap/Body", verts_b, faces_b)],
        })["result"]
        pair = result["pairs"][0]
        assert pair["min_mm"] == pytest.approx(2.0, abs=1e-4)
        assert pair["containment"] == "b_inside_a"
        assert pair["overlap"] is True
        assert pair["pass"] is False
        assert result["pass"] is False

    def test_a_part_beside_another_is_not_probed_and_passes(self, tmp_path):
        pytest.importorskip("fcl")
        verts_a, faces_a = _box((0.0, 0.0, 0.0), (10.0, 10.0, 10.0))
        verts_b, faces_b = _box((12.0, 2.0, 2.0), (13.0, 3.0, 3.0))
        result = rp.reference_pairs({
            "required_mm": 0.5,
            "targets": [_target(tmp_path, "shell", "Shell/Body", verts_a, faces_a),
                        _target(tmp_path, "cap", "Cap/Body", verts_b, faces_b)],
        })["result"]
        pair = result["pairs"][0]
        assert pair["min_mm"] == pytest.approx(2.0, abs=1e-4)
        assert "containment" not in pair
        assert pair["pass"] is True and result["pass"] is True

    def test_an_open_outer_mesh_is_undecidable_and_withholds_the_pass(self, tmp_path):
        pytest.importorskip("fcl")
        verts_a, faces_a = _box((0.0, 0.0, 0.0), (10.0, 10.0, 10.0))
        verts_b, faces_b = _box((2.0, 2.0, 2.0), (3.0, 3.0, 3.0))
        result = rp.reference_pairs({
            "required_mm": 0.5,
            "targets": [_target(tmp_path, "shell", "Shell/Body", verts_a, faces_a[:-1]),
                        _target(tmp_path, "cap", "Cap/Body", verts_b, faces_b)],
        })["result"]
        pair = result["pairs"][0]
        assert pair["containment"] == "undecidable"
        assert "not a closed mesh" in pair["containment_note"]
        assert pair["pass"] is False and result["pass"] is False


def _union(*meshes):
    """Several closed boxes as ONE mesh: a node made of disconnected shells."""
    verts, faces = [], []
    for box_verts, box_faces in meshes:
        base = len(verts)
        verts.extend(box_verts)
        faces.extend(tuple(base + i for i in tri) for tri in box_faces)
    return verts, faces


class TestContainmentPerComponent:
    """A node is often several disconnected shells, and the node's box as a
    whole says nothing about where each shell is.

    ORACLE: B is two cubes, [2,3]^3 inside A = [0,10]^3 and [20,21]^3 far
    beside it. B's whole box, [2,21]^3, neither contains A's nor lies inside
    it, so a probe keyed on whole-node boxes asks nothing and passes the pair
    at 2 mm of surface distance — with B's first shell buried in A's material.
    Probed per component, the pair is b_inside_a and fails. The same B with
    its near shell moved to [12,13]^3 has both shells outside A and passes.
    """

    def test_a_disconnected_shell_inside_the_other_part_is_an_overlap(self, tmp_path):
        pytest.importorskip("fcl")
        verts_a, faces_a = _box((0.0, 0.0, 0.0), (10.0, 10.0, 10.0))
        verts_b, faces_b = _union(_box((2.0, 2.0, 2.0), (3.0, 3.0, 3.0)),
                                  _box((20.0, 20.0, 20.0), (21.0, 21.0, 21.0)))
        result = rp.reference_pairs({
            "required_mm": 0.5,
            "targets": [_target(tmp_path, "shell", "Shell/Body", verts_a, faces_a),
                        _target(tmp_path, "pins", "Pins/Body", verts_b, faces_b)],
        })["result"]
        pair = result["pairs"][0]
        assert pair["min_mm"] == pytest.approx(2.0, abs=1e-4)
        assert pair["containment"] == "b_inside_a"
        assert pair["overlap"] is True
        assert pair["pass"] is False and result["pass"] is False

    def test_two_shells_both_beside_the_other_part_pass(self, tmp_path):
        pytest.importorskip("fcl")
        verts_a, faces_a = _box((0.0, 0.0, 0.0), (10.0, 10.0, 10.0))
        verts_b, faces_b = _union(_box((12.0, 2.0, 2.0), (13.0, 3.0, 3.0)),
                                  _box((20.0, 20.0, 20.0), (21.0, 21.0, 21.0)))
        result = rp.reference_pairs({
            "required_mm": 0.5,
            "targets": [_target(tmp_path, "shell", "Shell/Body", verts_a, faces_a),
                        _target(tmp_path, "pins", "Pins/Body", verts_b, faces_b)],
        })["result"]
        pair = result["pairs"][0]
        assert pair["min_mm"] == pytest.approx(2.0, abs=1e-4)
        assert "containment" not in pair
        assert pair["pass"] is True and result["pass"] is True


class TestContainmentSurvivesEviction:
    """The tree cache is a bounded LRU shared by every request, and a request
    that names more targets than it holds evicts its own first target while
    the later ones are built.

    ORACLE: nested A = [0,10]^3 and B = [2,3]^3 plus a far C, under an LRU of
    two. A is built first and evicted by C; the request still holds A's tree
    locally, so the distance reads 2 mm, and the containment probe must read
    A's triangles from the same place — a probe that asked the cache would
    find nothing, ask nothing, and pass the buried part.
    """

    def test_a_target_evicted_mid_request_is_still_probed(self, tmp_path, monkeypatch):
        pytest.importorskip("fcl")
        monkeypatch.setattr(clr, "_reference_trees", clr._LRU(2))
        verts_a, faces_a = _box((0.0, 0.0, 0.0), (10.0, 10.0, 10.0))
        verts_b, faces_b = _box((2.0, 2.0, 2.0), (3.0, 3.0, 3.0))
        verts_c, faces_c = _box((40.0, 0.0, 0.0), (41.0, 1.0, 1.0))
        targets = [_target(tmp_path, "shell", "Shell/Body", verts_a, faces_a),
                   _target(tmp_path, "cap", "Cap/Body", verts_b, faces_b),
                   _target(tmp_path, "far", "Far/Body", verts_c, faces_c)]
        result = rp.reference_pairs({"required_mm": 0.5, "targets": targets,
                                     "pairs": [[0, 1], [0, 2]]})["result"]
        assert clr._reference_trees.get(targets[0]["key"]) is None
        nested_pair = [p for p in result["pairs"] if p["b"]["node"] == "Cap/Body"][0]
        assert nested_pair["min_mm"] == pytest.approx(2.0, abs=1e-4)
        assert nested_pair["containment"] == "b_inside_a"
        assert nested_pair["pass"] is False and result["pass"] is False


def test_containment_probe_needs_no_geometry_backend():
    """The parity walk is numpy over the triangles: the cube's own vertex at
    (2,2,2) is inside [0,10]^3 and a point at (12,2,2) is not."""
    from mcad_worker import containment as ct
    verts, faces = _box((0.0, 0.0, 0.0), (10.0, 10.0, 10.0))
    assert ct.is_closed(verts, faces) is True
    assert ct.is_closed(verts, faces[:-1]) is False
    assert ct.point_inside((2.0, 2.0, 2.0), verts, faces) is True
    assert ct.point_inside((12.0, 2.0, 2.0), verts, faces) is False
    assert ct.nested(((2, 2, 2), (3, 3, 3)), ((0, 0, 0), (10, 10, 10))) == "a_in_b"
    assert ct.nested(((0, 0, 0), (10, 10, 10)), ((12, 2, 2), (13, 3, 3))) is None
    # Two boxes in one mesh are two components; missing triangles are
    # undecidable, never clean.
    two = _union(_box((2, 2, 2), (3, 3, 3)), _box((20, 20, 20), (21, 21, 21)))
    assert len(ct.components(*two)) == 2
    assert ct.containment(None, (verts, faces), None,
                          ((0, 0, 0), (10, 10, 10)))["containment"] == "undecidable"
    inside = ct.containment(two, (verts, faces), ((2, 2, 2), (21, 21, 21)),
                            ((0, 0, 0), (10, 10, 10)))
    assert inside["containment"] == "a_inside_b"
