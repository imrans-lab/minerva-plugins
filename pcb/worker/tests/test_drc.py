"""Tests for the connectivity/topology DRC (pcb_worker.drc + the `drc` worker method).

Two layers of coverage:

  * REGRESSION — a real board (testdata/parity_corners.yaml) must report EXACTLY
    its known findings and NOTHING else. Until 2026-07-30 this ran over
    ``smart_remote.yaml``, a real Turnrock product board withdrawn from the
    corpus as an IP leak (docket 019fbe68c5f8, see testdata/POLICY.md); its
    known defects were 2 wrong-net shorts + 7 different-net crossings.
    ``parity_corners.yaml`` was authored for the CROSS-SURFACE geometry parity
    gate, not for connectivity DRC, so it does not happen to reproduce that
    defect shape — measured, it reports exactly ONE dangling endpoint (its
    routed N_OBL trace's far end does not land on the SW9.A pad it is nominally
    headed for) and nothing else. That is still a real, exact, regression-worthy
    claim; it is just a smaller one than the withdrawn board made. NEVER repair
    this module by restoring the deleted fixture from git history.
  * ISOLATION goldens — tiny hand-built boards that each trip exactly one check,
    proving every check fires (and that the clean board stays clean). These
    still carry the crossing / wrong-net-pad / layer-change-no-via / dangling
    cases the withdrawn board's regression used to exercise together; the
    fixture change only affects what runs against the ONE real-board fixture.

Handlers are exercised both directly (run_drc) and through handle_request, the
same stdio-bypass pattern the other worker tests use.
"""

from __future__ import annotations

from pathlib import Path

import yaml

from pcb_worker import drc
from pcb_worker.methods import handle_request

PARITY_CORNERS = Path(__file__).resolve().parent / "testdata" / "parity_corners.yaml"


def _run(board: dict) -> dict:
    return drc.run_drc(board)


def _of_type(result: dict, t: str) -> list[dict]:
    return [f for f in result["findings"] if f["type"] == t]


def test_drc_result_declares_connectivity_scope_not_geometric():
    """Honesty contract (docket 019f7abf7e7b): run_drc is connectivity/topology
    only — pad centers + trace centerlines, no copper extents — so it must
    self-describe as such. A zero-finding result must never be read as a
    geometric/fab-clean verdict; these fields make that explicit."""
    board = yaml.safe_load(PARITY_CORNERS.read_text(encoding="utf-8"))
    r = _run(board)
    assert r["ok"] is True
    assert r["scope"] == "connectivity"
    assert r["verifies_geometry"] is False


# ---------------------------------------------------------------------------
# Regression: the parity-corners real board — exact known findings, no noise.
#
# docket 019fbe68c5f8: this used to run over smart_remote.yaml and pin its two
# wrong-net shorts + seven crossings. That board was withdrawn (see
# testdata/POLICY.md); parity_corners.yaml is authored for a different purpose
# (cross-surface geometry parity, not connectivity DRC) and its ACTUAL,
# MEASURED connectivity story is smaller: one dangling endpoint, nothing else.
# The isolation goldens below still independently prove every check (crossing,
# wrong_net_pad, layer_change_no_via, dangling_endpoint) fires on a purpose-
# built board; this test's job is only to pin the real board's exact findings
# so a regression here is caught, whatever they happen to be.
# ---------------------------------------------------------------------------


def test_parity_corners_exact_findings():
    board = yaml.safe_load(PARITY_CORNERS.read_text(encoding="utf-8"))
    r = _run(board)
    assert r["ok"] is True
    assert r["counts"] == {
        "wrong_net_pad": 0,
        "crossing": 0,
        "dangling_endpoint": 1,
        "layer_change_no_via": 0,
    }

    # The one dangling endpoint: the routed N_OBL trace's far end (7.0, 22.0)
    # does not land on the SW9.A pad (10.0, 25.0) it is nominally headed for —
    # incidental to how the fixture was authored for geometry parity, not
    # routing precision, but a real and stable connectivity finding.
    dangling = _of_type(r, "dangling_endpoint")
    assert len(dangling) == 1
    assert dangling[0]["net"] == "N_OBL"
    assert dangling[0]["at"] == [7.0, 22.0]

    # No noise from the other checks.
    assert _of_type(r, "wrong_net_pad") == []
    assert _of_type(r, "crossing") == []
    assert _of_type(r, "layer_change_no_via") == []


def test_parity_corners_via_worker_method():
    resp = handle_request({"id": "d1", "method": "drc",
                           "params": {"yaml": PARITY_CORNERS.read_text(encoding="utf-8")}})
    assert resp["id"] == "d1"
    assert resp["ok"] is True
    assert resp["result"]["counts"]["wrong_net_pad"] == 0
    assert resp["result"]["counts"]["crossing"] == 0
    assert resp["result"]["counts"]["dangling_endpoint"] == 1


# ---------------------------------------------------------------------------
# Isolation goldens — each trips exactly one check.
# ---------------------------------------------------------------------------

# (a) Clean two-pad net, single trace: nothing to report.
_CLEAN = """
version: 1
name: clean
width_mm: 20
height_mm: 20
design_rules: {clearance_mm: 0.2}
components:
  - {ref: R1, footprint: R, x_mm: 5, y_mm: 5, rotation_deg: 0,
     pins: [{number: '1', x_mm: 0, y_mm: 0, pad_width_mm: 1, pad_height_mm: 1}]}
  - {ref: R2, footprint: R, x_mm: 15, y_mm: 5, rotation_deg: 0,
     pins: [{number: '1', x_mm: 0, y_mm: 0, pad_width_mm: 1, pad_height_mm: 1}]}
nets:
  - {name: N1, pins: ['R1.1', 'R2.1']}
traces:
  - {net: N1, layer: top, width_mm: 0.25,
     points: [{x_mm: 5, y_mm: 5}, {x_mm: 15, y_mm: 5}]}
"""

# (b) Two different-net traces on the same layer that cross at (5,5).
_CROSSING = """
version: 1
name: crossing
width_mm: 12
height_mm: 12
design_rules: {clearance_mm: 0.2}
components:
  - {ref: A1, footprint: R, x_mm: 0, y_mm: 5, rotation_deg: 0,
     pins: [{number: '1', x_mm: 0, y_mm: 0, pad_width_mm: 1, pad_height_mm: 1}]}
  - {ref: A2, footprint: R, x_mm: 10, y_mm: 5, rotation_deg: 0,
     pins: [{number: '1', x_mm: 0, y_mm: 0, pad_width_mm: 1, pad_height_mm: 1}]}
  - {ref: B1, footprint: R, x_mm: 5, y_mm: 0, rotation_deg: 0,
     pins: [{number: '1', x_mm: 0, y_mm: 0, pad_width_mm: 1, pad_height_mm: 1}]}
  - {ref: B2, footprint: R, x_mm: 5, y_mm: 10, rotation_deg: 0,
     pins: [{number: '1', x_mm: 0, y_mm: 0, pad_width_mm: 1, pad_height_mm: 1}]}
nets:
  - {name: NA, pins: ['A1.1', 'A2.1']}
  - {name: NB, pins: ['B1.1', 'B2.1']}
traces:
  - {net: NA, layer: top, width_mm: 0.25,
     points: [{x_mm: 0, y_mm: 5}, {x_mm: 10, y_mm: 5}]}
  - {net: NB, layer: top, width_mm: 0.25,
     points: [{x_mm: 5, y_mm: 0}, {x_mm: 5, y_mm: 10}]}
"""

# (c) A net-A trace whose far endpoint lands on a net-B pad (short / mis-route).
_WRONG_NET = """
version: 1
name: wrongnet
width_mm: 12
height_mm: 12
design_rules: {clearance_mm: 0.2}
components:
  - {ref: A1, footprint: R, x_mm: 0, y_mm: 5, rotation_deg: 0,
     pins: [{number: '1', x_mm: 0, y_mm: 0, pad_width_mm: 1, pad_height_mm: 1}]}
  - {ref: B1, footprint: R, x_mm: 10, y_mm: 5, rotation_deg: 0,
     pins: [{number: '1', x_mm: 0, y_mm: 0, pad_width_mm: 1, pad_height_mm: 1}]}
nets:
  - {name: NA, pins: ['A1.1']}
  - {name: NB, pins: ['B1.1']}
traces:
  - {net: NA, layer: top, width_mm: 0.25,
     points: [{x_mm: 0, y_mm: 5}, {x_mm: 10, y_mm: 5}]}
"""

# (d) A net changing layers at (5,5) with no via / TH pad there (missing via).
# Pads at the outer ends keep the dangling check quiet, isolating check D.
_MISSING_VIA = """
version: 1
name: missingvia
width_mm: 15
height_mm: 15
design_rules: {clearance_mm: 0.2}
components:
  - {ref: P1, footprint: R, x_mm: 0, y_mm: 0, rotation_deg: 0,
     pins: [{number: '1', x_mm: 0, y_mm: 0, pad_width_mm: 1, pad_height_mm: 1}]}
  - {ref: P2, footprint: R, x_mm: 10, y_mm: 10, rotation_deg: 0,
     pins: [{number: '1', x_mm: 0, y_mm: 0, pad_width_mm: 1, pad_height_mm: 1}]}
nets:
  - {name: V, pins: ['P1.1', 'P2.1']}
traces:
  - {net: V, layer: top, width_mm: 0.25,
     points: [{x_mm: 0, y_mm: 0}, {x_mm: 5, y_mm: 5}]}
  - {net: V, layer: bottom, width_mm: 0.25,
     points: [{x_mm: 5, y_mm: 5}, {x_mm: 10, y_mm: 10}]}
"""

# (e) A net with one trace whose free endpoint reaches nothing (open).
_DANGLING = """
version: 1
name: dangling
width_mm: 12
height_mm: 12
design_rules: {clearance_mm: 0.2}
components:
  - {ref: P1, footprint: R, x_mm: 0, y_mm: 0, rotation_deg: 0,
     pins: [{number: '1', x_mm: 0, y_mm: 0, pad_width_mm: 1, pad_height_mm: 1}]}
nets:
  - {name: D, pins: ['P1.1']}
traces:
  - {net: D, layer: top, width_mm: 0.25,
     points: [{x_mm: 0, y_mm: 0}, {x_mm: 5, y_mm: 5}]}
"""


def test_clean_board_has_no_findings():
    r = _run(yaml.safe_load(_CLEAN))
    assert r["findings"] == []
    assert r["counts"] == {"wrong_net_pad": 0, "crossing": 0,
                           "dangling_endpoint": 0, "layer_change_no_via": 0}


def test_single_crossing():
    r = _run(yaml.safe_load(_CROSSING))
    assert r["counts"]["crossing"] == 1
    assert r["counts"]["wrong_net_pad"] == 0
    assert r["counts"]["dangling_endpoint"] == 0
    f = _of_type(r, "crossing")[0]
    assert tuple(sorted(f["nets"])) == ("NA", "NB")
    assert f["layer"] == "top"
    assert f["at"] == [5.0, 5.0]


def test_single_wrong_net_pad():
    r = _run(yaml.safe_load(_WRONG_NET))
    assert r["counts"]["wrong_net_pad"] == 1
    assert r["counts"]["crossing"] == 0
    assert r["counts"]["dangling_endpoint"] == 0
    f = _of_type(r, "wrong_net_pad")[0]
    assert f["net"] == "NA"
    assert f["at"] == [10.0, 5.0]
    assert f["pad"]["ref"] == "B1"
    assert f["pad"]["net"] == "NB"


def test_single_layer_change_no_via():
    r = _run(yaml.safe_load(_MISSING_VIA))
    assert r["counts"]["layer_change_no_via"] == 1
    assert r["counts"]["dangling_endpoint"] == 0
    assert r["counts"]["crossing"] == 0
    f = _of_type(r, "layer_change_no_via")[0]
    assert f["net"] == "V"
    assert f["at"] == [5.0, 5.0]


def test_via_with_layer_span_satisfies_layer_change_check():
    """A via carrying first-class from_layer/to_layer (docket 019... U1:
    canonical via schema) still satisfies check D by POSITION — the layer
    span isn't load-bearing for this check (see drc._harvest_vias docstring),
    so adding a via at the meeting point silences the finding exactly as a
    position-only via always has."""
    board = yaml.safe_load(_MISSING_VIA)
    board["vias"] = [{"x_mm": 5.0, "y_mm": 5.0, "drill_mm": 0.4,
                      "diameter_mm": 0.8, "net": "V",
                      "from_layer": "top", "to_layer": "bottom"}]
    r = _run(board)
    assert r["counts"]["layer_change_no_via"] == 0


def test_legacy_via_without_layer_span_still_satisfies_check():
    """A legacy via dict with NO from_layer/to_layer keys (pre-U1 shape) must
    still work — no crash, same position-based credit."""
    board = yaml.safe_load(_MISSING_VIA)
    board["vias"] = [{"x_mm": 5.0, "y_mm": 5.0, "drill_mm": 0.4,
                      "diameter_mm": 0.8, "net": "V"}]
    r = _run(board)
    assert r["counts"]["layer_change_no_via"] == 0


def test_single_dangling_endpoint():
    r = _run(yaml.safe_load(_DANGLING))
    assert r["counts"]["dangling_endpoint"] == 1
    assert r["counts"]["wrong_net_pad"] == 0
    assert r["counts"]["layer_change_no_via"] == 0
    f = _of_type(r, "dangling_endpoint")[0]
    assert f["net"] == "D"
    assert f["at"] == [5.0, 5.0]


def test_drc_parse_error_is_structured():
    resp = handle_request({"id": "d2", "method": "drc", "params": {"yaml": "]["}})
    assert resp["ok"] is False
    assert resp["error"]["kind"] == "parse"
