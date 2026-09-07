"""A defect report says WHERE, not only how many.

ORACLES.
1. A hand-built mesh whose two non-manifold edges are placed by construction:
   three triangles share the edge (0,0,0)→(10,0,0) and three more share
   (0,0,20)→(10,0,20). Both midpoints are known exactly, so the report either
   names them or it is wrong — no kernel, no tessellation, no tolerance
   argument.
2. The rev-3 enclosure fixture, which an independent observation (opening its
   STL in a mesh tool) shows carries two non-manifold edges. The report must
   locate both, inside the part's own bounding box, and must carry them
   through the summary reply the panel and MCP read.

Counting and locating are one walk, so the report's counts must equal what
`_mesh_defects` reports — a divergence here means a reader is being told two
different stories about the same mesh.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from mcad_worker import mesh_defects
from mcad_worker.methods import _mesh_defects

FIXTURE = (
    Path(__file__).resolve().parents[2]
    / "tests"
    / "fixtures"
    / "smart-remote-v2"
    / "enclosure-rev3.mcad"
)


def _fin_mesh() -> dict:
    """Two edges with three faces each, at z=0 and z=20.

    Each fin is a shared edge A→B plus three triangles hanging off it, which
    is exactly the "three faces meet on one edge" condition and nothing else.
    """
    vertices: list = []
    faces: list = []
    for z in (0.0, 20.0):
        base = len(vertices)
        vertices.extend([
            [0.0, 0.0, z],    # A
            [10.0, 0.0, z],   # B
            [0.0, 5.0, z],    # C1
            [0.0, -5.0, z],   # C2
            [0.0, 0.0, z + 5.0],  # C3
        ])
        for corner in (2, 3, 4):
            faces.append([base + 0, base + 1, base + corner])
    return {"vertices": vertices, "faces": faces}


def test_non_manifold_edges_are_located_by_construction():
    report = mesh_defects.defect_report(_fin_mesh())

    assert report["counts"]["non_manifold_edges"] == 2
    located = report["sites"]["non_manifold_edges"]
    assert located["total"] == 2
    positions = sorted(site["position"] for site in located["sites"])
    assert positions == [[5.0, 0.0, 0.0], [5.0, 0.0, 20.0]]
    for site in located["sites"]:
        assert site["faces"] == 3
        assert sorted([site["from"], site["to"]]) == sorted([
            [0.0, 0.0, site["position"][2]],
            [10.0, 0.0, site["position"][2]],
        ])
    # The note is the trap the counts alone set: slivers are not defects.
    assert "non_manifold_edges" in report["sites"]


def test_counts_agree_with_the_summary_derivation():
    mesh = _fin_mesh()
    assert _mesh_defects(mesh) == mesh_defects.defect_report(mesh)["counts"]


def test_degenerate_faces_are_sampled_across_the_part_with_a_note():
    """Many slivers report a capped, spread sample — not the first N."""
    vertices: list = []
    faces: list = []
    count = mesh_defects.DEGENERATE_SITE_CAP * 4
    for i in range(count):
        base = len(vertices)
        x = float(i)
        vertices.extend([[x, 0.0, 0.0], [x, 1.0, 0.0]])
        faces.append([base, base + 1, base])  # repeats a corner → degenerate

    report = mesh_defects.defect_report({"vertices": vertices, "faces": faces})

    assert report["counts"]["degenerate_faces"] == count
    located = report["sites"]["degenerate_faces"]
    assert located["total"] == count
    assert len(located["sites"]) == mesh_defects.DEGENERATE_SITE_CAP
    xs = [site["position"][0] for site in located["sites"]]
    # A head slice would stop at cap-1; a spread sample reaches the far end.
    assert xs[0] < 1.0 and xs[-1] > count * 0.7
    assert "not defects by themselves" in located["note"]


def test_rev3_fixture_reports_both_edges_with_positions():
    """The enclosure the owner exported: two edges, located, inside the part."""
    pytest.importorskip("build123d", reason="build123d not installed here")
    from mcad_worker.methods import _evaluate

    response = _evaluate({"source": FIXTURE.read_text(encoding="utf-8"), "summary": True})
    assert response["ok"] is True, response
    summary = response["result"]

    assert summary["mesh_defects"]["non_manifold_edges"] == 2
    located = summary["mesh_defect_sites"]["non_manifold_edges"]
    assert located["total"] == 2
    assert len(located["sites"]) == 2
    low = summary["bbox"]["min"]
    high = summary["bbox"]["max"]
    for site in located["sites"]:
        for axis in range(3):
            assert low[axis] - 0.01 <= site["position"][axis] <= high[axis] + 0.01
    # Counts and sites agree about degenerate faces. This tessellation has
    # none, so both keys are absent -- zero-valued classes are filtered out of
    # counts and never get a sites entry. The sampling itself is covered on a
    # synthetic mesh above; here the claim is only that the two halves of the
    # reply cannot disagree.
    degenerate_count = summary["mesh_defects"].get("degenerate_faces")
    degenerate = summary["mesh_defect_sites"].get("degenerate_faces")
    assert (degenerate_count is None) == (degenerate is None)
    if degenerate is not None:
        assert degenerate["total"] == degenerate_count
        assert len(degenerate["sites"]) <= mesh_defects.DEGENERATE_SITE_CAP
