"""The HITL bench's WHOLE-BOARD baseline, asserted the way the walk reads it.

``pcb/docs/hitl_bench.md`` records what the bench board answers before anyone
touches it — 5 dangling ends at named coordinates, six partial nets with their
island counts, exactly one geometric finding, four pour fills with their areas.
A HITL operator reads those numbers off the doc and compares them to the panel;
until this file existed, nothing else did, so a drift in a row's answer showed
up only when a human next walked the bench.

THE NUMBERS COME FROM THE DOC, not from a recorded run of the code they check.
They are hand-derived per row (each row's own line in the doc carries its
derivation), and the doc's table is what an operator is told to expect. If a
change here goes red the question is which of the two is wrong — the code, or
the doc and the row derivation behind it — and the answer is never "re-record
the assertion".

SCOPE: whole-board surfaces only (`drc`, `drc_geometric`, `zone_fill`), through
the worker's own request entry point, over the bench file as it ships. The
per-row gestures are the HITL walk's job and stay there.
"""

from __future__ import annotations

from pathlib import Path

import yaml

from pcb_worker.methods import handle_request

HITL_BENCH = Path(__file__).resolve().parent / "testdata" / "hitl_bench.yaml"


def _bench() -> dict:
    return yaml.safe_load(HITL_BENCH.read_text(encoding="utf-8"))


def _result(method: str) -> dict:
    resp = handle_request(
        {"id": "bench", "method": method, "params": {"board": _bench()}})
    assert resp is not None and resp["id"] == "bench", resp
    assert resp.get("ok") is True, resp
    return resp["result"]


def _ring_area_mm2(ring: list) -> float:
    """Shoelace area of one fill ring, sign-free — the doc states magnitudes."""
    pts = [(float(p["x_mm"]), float(p["y_mm"])) for p in ring]
    twice = sum(pts[i][0] * pts[(i + 1) % len(pts)][1]
                - pts[(i + 1) % len(pts)][0] * pts[i][1]
                for i in range(len(pts)))
    return abs(twice) / 2.0


def test_connectivity_drc_matches_the_documented_baseline():
    """`drc` connectivity: 5 dangling ends and nothing else, at the five places
    the doc names, with the six partial nets' island counts and the two nets
    that carry no copper at all."""
    result = _result("drc")

    assert result["counts"] == {
        "dangling_endpoint": 5,
        "wrong_net_pad": 0,
        "crossing": 0,
        "layer_change_no_via": 0,
    }, result["counts"]
    assert "indeterminate" not in result, result.get("indeterminate")

    dangling = sorted(
        (f["net"], round(f["at"][0], 3), round(f["at"][1], 3))
        for f in result["findings"] if f["type"] == "dangling_endpoint")
    assert dangling == [
        ("R1_B", 40.475, 4.75),
        ("R22_A", 22.0, 260.0),
        ("R23_B", 46.0, 274.0),
        ("R5_A", 22.9, 56.0),
        ("R5_A", 27.1, 56.0),
    ], dangling

    partial = {row["net"]: row["pin_groups"] for row in result["partial"]}
    assert partial == {"R1_B": 2, "R3_G": 2, "R5_A": 3,
                       "R16_A": 3, "R21_B": 2, "R23_B": 2}, partial

    assert sorted(result["missing_copper"]) == ["R15_A", "R4_A"], \
        result["missing_copper"]


def test_geometric_drc_reports_exactly_the_one_deliberate_finding():
    """`drc_geometric`: DETERMINATE, and its single finding is R9 B's probe,
    which the bench authors under the board's own trace-width rule on purpose
    (`validate` reports the same one as its lone warning)."""
    union = _result("drc_geometric")

    assert union["verifies_geometry"] is True, union
    assert union["verdict"] == "violations", union.get("verdict")

    findings = union["findings"]
    assert len(findings) == 1, [f["type"] for f in findings]
    assert findings[0]["type"] == "gc1_trace_width", findings[0]


def test_pour_fill_areas_match_the_documented_baseline():
    """`zone_fill`: four pours, one region each, at the areas the doc states.

    FOUR is the count, not five: the bench carries five zones and the doc's
    compile row records `zone_filled` x4, the fifth being a keepout, which is
    not copper and is omitted from this reply by contract.

    The AREA is what a drifting fill moves. A clearance carve or an edge inset
    that changes a pour's shape without splitting it leaves the region COUNT
    alone, so the count on its own would not notice.
    """
    zones = {z["id"]: z["fill"] for z in _result("zone_fill")["zones"]}

    expected = {"Z3": 104.0, "Z13": 112.0, "Z21A": 70.0, "Z21B": 70.0}
    assert sorted(zones) == sorted(expected), sorted(zones)
    for zone_id, area in expected.items():
        rings = zones[zone_id]
        assert len(rings) == 1, (zone_id, len(rings))
        assert round(_ring_area_mm2(rings[0]), 4) == area, zone_id
