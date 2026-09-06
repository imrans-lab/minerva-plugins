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

        ORACLE: the fixture's own overlap — the second block starts 1 mm
        inside the first — and the x of every contact point, which must lie
        in the overlapped band.
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
            assert 4.0 <= point[0] <= 7.0
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
