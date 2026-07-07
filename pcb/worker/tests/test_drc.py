"""Tests for the geometric DRC (pcb_worker.drc + the `drc` worker method).

Two layers of coverage:

  * REGRESSION — the real HITL board (testdata/smart_remote.yaml) must report
    EXACTLY its known defects (2 wrong-net shorts + 7 different-net crossings)
    and NOTHING else. Its GND net has T-junction taps and U1 (ESP32 module) has
    several internal-net GND pins; the false-positive guards must keep the
    dangling / layer-change checks silent on it.
  * ISOLATION goldens — tiny hand-built boards that each trip exactly one check,
    proving every check fires (and that the clean board stays clean).

Handlers are exercised both directly (run_drc) and through handle_request, the
same stdio-bypass pattern the other worker tests use.
"""

from __future__ import annotations

from pathlib import Path

import yaml

from pcb_worker import drc
from pcb_worker.methods import handle_request

SMART_REMOTE = Path(__file__).resolve().parent / "testdata" / "smart_remote.yaml"


def _run(board: dict) -> dict:
    return drc.run_drc(board)


def _of_type(result: dict, t: str) -> list[dict]:
    return [f for f in result["findings"] if f["type"] == t]


# ---------------------------------------------------------------------------
# Regression: the smart-remote HITL board — exact known defects, no noise.
# ---------------------------------------------------------------------------


def test_smart_remote_exact_findings():
    board = yaml.safe_load(SMART_REMOTE.read_text(encoding="utf-8"))
    r = _run(board)
    assert r["ok"] is True
    assert r["counts"] == {
        "wrong_net_pad": 2,
        "crossing": 7,
        "dangling_endpoint": 0,
        "layer_change_no_via": 0,
    }

    # The two shorts: BTN4 endpoint on SW4.B(GND); GND endpoint on SW4.A(BTN4).
    wnp = _of_type(r, "wrong_net_pad")
    by_net = {(f["net"], tuple(f["at"])): f for f in wnp}
    assert ("BTN4", (66.5, 104.14)) in by_net
    assert by_net[("BTN4", (66.5, 104.14))]["pad"] == {
        "ref": "SW4", "pin": "B", "net": "GND"}
    assert ("GND", (60.5, 104.14)) in by_net
    assert by_net[("GND", (60.5, 104.14))]["pad"] == {
        "ref": "SW4", "pin": "A", "net": "BTN4"}

    # The seven net-pair crossings, all on the top layer.
    crossings = _of_type(r, "crossing")
    assert all(f["layer"] == "top" for f in crossings)
    pairs = {tuple(sorted(f["nets"])) for f in crossings}
    assert pairs == {
        ("I2C_SCL", "I2S_DOUT"),
        ("I2C_SDA", "I2S_DOUT"),
        ("I2S_DOUT", "I2S_SCK"),
        ("I2S_DOUT", "I2S_WS"),
        ("I2S_SCK", "I2S_WS"),
        ("I2S_SCK", "VCC_3V3"),
        ("I2S_WS", "VCC_3V3"),
    }
    # Guards held: GND taps (T-junctions) + U1 internal GND pins stay quiet.
    assert _of_type(r, "dangling_endpoint") == []
    assert _of_type(r, "layer_change_no_via") == []


def test_smart_remote_via_worker_method():
    resp = handle_request({"id": "d1", "method": "drc",
                           "params": {"yaml": SMART_REMOTE.read_text(encoding="utf-8")}})
    assert resp["id"] == "d1"
    assert resp["ok"] is True
    assert resp["result"]["counts"]["wrong_net_pad"] == 2
    assert resp["result"]["counts"]["crossing"] == 7


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
