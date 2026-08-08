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


# ---------------------------------------------------------------------------
# Connectivity COMPLETENESS — HITL-4 (docs/llm-ergonomics.md F2).
#
# THE BUG, from the live round: the connectivity summary reported clean while
# net VCC_5V (D1.1→U1.21) had ZERO copper on the board. All four checks are
# violation detectors — copper that is MISSING was structurally unreportable,
# so "clean" was a lie by omission and the owner found the open by eye. run_drc
# now carries `complete` + `missing_copper` (+ `partial`, absent-key when
# empty) beside the unchanged findings/counts; `clean`-equivalent consumers of
# counts see exactly what they always saw.
# ---------------------------------------------------------------------------

# The live shape in miniature: a >=2-pin net declared with NO copper at all.
_ZERO_COPPER = """
version: 1
name: zerocopper
width_mm: 20
height_mm: 20
design_rules: {clearance_mm: 0.2}
components:
  - {ref: D1, footprint: R, x_mm: 5, y_mm: 5, rotation_deg: 0,
     pins: [{number: '1', x_mm: 0, y_mm: 0, pad_width_mm: 1, pad_height_mm: 1}]}
  - {ref: U1, footprint: R, x_mm: 15, y_mm: 5, rotation_deg: 0,
     pins: [{number: '21', x_mm: 0, y_mm: 0, pad_width_mm: 1, pad_height_mm: 1}]}
nets:
  - {name: VCC_5V, pins: ['D1.1', 'U1.21']}
"""

# Copper exists but strands a pin: three pads, one trace joining two of them.
_PARTIAL = """
version: 1
name: partialnet
width_mm: 30
height_mm: 20
design_rules: {clearance_mm: 0.2}
components:
  - {ref: P1, footprint: R, x_mm: 5, y_mm: 5, rotation_deg: 0,
     pins: [{number: '1', x_mm: 0, y_mm: 0, pad_width_mm: 1, pad_height_mm: 1}]}
  - {ref: P2, footprint: R, x_mm: 15, y_mm: 5, rotation_deg: 0,
     pins: [{number: '1', x_mm: 0, y_mm: 0, pad_width_mm: 1, pad_height_mm: 1}]}
  - {ref: P3, footprint: R, x_mm: 25, y_mm: 15, rotation_deg: 0,
     pins: [{number: '1', x_mm: 0, y_mm: 0, pad_width_mm: 1, pad_height_mm: 1}]}
nets:
  - {name: SIG, pins: ['P1.1', 'P2.1', 'P3.1']}
traces:
  - {net: SIG, layer: top, width_mm: 0.25,
     points: [{x_mm: 5, y_mm: 5}, {x_mm: 15, y_mm: 5}]}
"""


def test_a_zero_copper_net_is_named_missing_never_silently_clean():
    """The VCC_5V reproduction: every violation count is zero — the OLD reply
    in full — and the new keys say what the old reply could not."""
    r = _run(yaml.safe_load(_ZERO_COPPER))
    assert r["findings"] == []  # nothing WRONG — the copper is absent, not bad
    assert r["complete"] is False
    assert r["missing_copper"] == ["VCC_5V"]
    assert "partial" not in r


def test_a_complete_board_reports_complete_and_names_nothing():
    """Negative gate: the clean golden is also COMPLETE — `complete: True`,
    empty `missing_copper`, and no `partial` key at all (absent-key)."""
    r = _run(yaml.safe_load(_CLEAN))
    assert r["complete"] is True
    assert r["missing_copper"] == []
    assert "partial" not in r


def test_partial_connectivity_reports_the_island_count():
    """Copper exists but P3 is stranded: not `missing_copper` (there IS
    copper), but two pin islands — reported, with the count."""
    r = _run(yaml.safe_load(_PARTIAL))
    assert r["complete"] is False
    assert r["missing_copper"] == []
    assert r["partial"] == [{"net": "SIG", "pin_groups": 2}]


def test_single_pin_nets_are_never_incomplete():
    """A 1-pin net has nothing to connect — it must not be reported missing
    (the _DANGLING golden's net D is exactly that shape)."""
    r = _run(yaml.safe_load(_DANGLING))
    assert r["missing_copper"] == []


def test_a_zone_counts_as_copper_but_is_indeterminate_not_complete():
    """CENSUS CORRECTION 019fd5fdeef3b (DCR 019fd5fd9084): a poured net is
    COPPER (not missing_copper), but pour connectivity is a geometry question
    this centerline kernel cannot answer honestly — in EITHER direction. The
    pre-fix rule "zone counts as copper => complete" was a false complete
    over copper nobody measured; the net is now INDETERMINATE ({net, reason:
    "zone_copper"}), never falsely `partial` and never auto-complete —
    flipping the board's `complete` from True to None (tri-state: nothing
    known-missing, one net unjudgeable)."""
    board = yaml.safe_load(_ZERO_COPPER)
    board["zones"] = [{"net": "VCC_5V", "layer": "top",
                       "points": [{"x_mm": 0, "y_mm": 0},
                                  {"x_mm": 20, "y_mm": 0},
                                  {"x_mm": 20, "y_mm": 20},
                                  {"x_mm": 0, "y_mm": 20}]}]
    r = _run(board)
    assert r["missing_copper"] == []
    assert "partial" not in r
    assert r["complete"] is None
    assert r["indeterminate"] == [{"net": "VCC_5V", "reason": "zone_copper"}]


def test_a_known_defect_outranks_an_indeterminate_zone():
    """Tri-state precedence: with a zone-bearing net AND a zero-copper net in
    scope, `complete` is False (a measured defect), not None — indeterminate
    only withholds a True, it never masks a False."""
    board = yaml.safe_load(_ZERO_COPPER)
    # Second net, poured: VCC_5V stays zero-copper (missing), GNDZ is poured.
    board["components"].append(
        {"ref": "Z1", "footprint": "R", "x_mm": 5, "y_mm": 15,
         "rotation_deg": 0,
         "pins": [{"number": "1", "x_mm": 0, "y_mm": 0,
                   "pad_width_mm": 1, "pad_height_mm": 1}]})
    board["components"].append(
        {"ref": "Z2", "footprint": "R", "x_mm": 15, "y_mm": 15,
         "rotation_deg": 0,
         "pins": [{"number": "1", "x_mm": 0, "y_mm": 0,
                   "pad_width_mm": 1, "pad_height_mm": 1}]})
    board["nets"].append({"name": "GNDZ", "pins": ["Z1.1", "Z2.1"]})
    board["zones"] = [{"net": "GNDZ", "layer": "top",
                       "points": [{"x_mm": 0, "y_mm": 0},
                                  {"x_mm": 20, "y_mm": 0},
                                  {"x_mm": 20, "y_mm": 20},
                                  {"x_mm": 0, "y_mm": 20}]}]
    r = _run(board)
    assert r["complete"] is False
    assert r["missing_copper"] == ["VCC_5V"]
    assert r["indeterminate"] == [{"net": "GNDZ", "reason": "zone_copper"}]


def test_parallel_traces_a_clearance_apart_do_not_union():
    """CENSUS CORRECTION 019fd5fdeef3a (DCR 019fd5fd9084): two parallel
    same-net traces 0.15mm apart with NO touching endpoints are SEPARATE
    copper — 0.15mm is an air gap, not a connection. The pre-fix census
    unioned segment endpoints at design-clearance (0.2mm) distance, so this
    exact board read falsely "complete"; the copper-copper credit now uses
    the coincidence epsilon (COPPER_COINCIDENT_EPS_MM, 1e-3mm) and the board
    reads `partial` with two pin islands."""
    board = {
        "version": 1, "name": "parallel", "width_mm": 30, "height_mm": 20,
        "design_rules": {"clearance_mm": 0.2},
        "components": [
            {"ref": "P1", "footprint": "R", "x_mm": 5, "y_mm": 5,
             "rotation_deg": 0,
             "pins": [{"number": "1", "x_mm": 0, "y_mm": 0,
                       "pad_width_mm": 1, "pad_height_mm": 1}]},
            {"ref": "P2", "footprint": "R", "x_mm": 15, "y_mm": 5.15,
             "rotation_deg": 0,
             "pins": [{"number": "1", "x_mm": 0, "y_mm": 0,
                       "pad_width_mm": 1, "pad_height_mm": 1}]},
        ],
        "nets": [{"name": "SIG", "pins": ["P1.1", "P2.1"]}],
        # Trace A ends mid-air at (10, 5); trace B starts mid-air at
        # (10, 5.15) — endpoint gap 0.15mm, no interior touch, no crossing.
        "traces": [
            {"net": "SIG", "layer": "top", "width_mm": 0.25,
             "points": [{"x_mm": 5, "y_mm": 5}, {"x_mm": 10, "y_mm": 5}]},
            {"net": "SIG", "layer": "top", "width_mm": 0.25,
             "points": [{"x_mm": 10, "y_mm": 5.15},
                        {"x_mm": 15, "y_mm": 5.15}]},
        ],
    }
    r = _run(board)
    assert r["complete"] is False
    assert r["missing_copper"] == []
    assert r["partial"] == [{"net": "SIG", "pin_groups": 2}]


def test_a_same_layer_plus_sign_crossing_is_one_pin_group():
    """CENSUS CORRECTION 019fd5fdeef3c (DCR 019fd5fd9084): two same-net
    traces that properly INTERSECT on ONE layer (an X-crossing with no shared
    endpoint) are physically connected copper. The pre-fix census had no
    intersection credit, so this plus-sign read as TWO pin islands (a false
    "partial"); it is one."""
    board = {
        "version": 1, "name": "plus-sign", "width_mm": 30, "height_mm": 30,
        "design_rules": {"clearance_mm": 0.2},
        "components": [
            {"ref": c["ref"], "footprint": "R", "x_mm": c["x"], "y_mm": c["y"],
             "rotation_deg": 0,
             "pins": [{"number": "1", "x_mm": 0, "y_mm": 0,
                       "pad_width_mm": 1, "pad_height_mm": 1}]}
            for c in ({"ref": "W", "x": 5, "y": 15},
                      {"ref": "E", "x": 25, "y": 15},
                      {"ref": "N", "x": 15, "y": 5},
                      {"ref": "S", "x": 15, "y": 25})
        ],
        "nets": [{"name": "SIG",
                  "pins": ["W.1", "E.1", "N.1", "S.1"]}],
        # The horizontal bar joins W-E, the vertical bar joins N-S; they cross
        # at (15, 15), which is no segment's endpoint.
        "traces": [
            {"net": "SIG", "layer": "top", "width_mm": 0.25,
             "points": [{"x_mm": 5, "y_mm": 15}, {"x_mm": 25, "y_mm": 15}]},
            {"net": "SIG", "layer": "top", "width_mm": 0.25,
             "points": [{"x_mm": 15, "y_mm": 5}, {"x_mm": 15, "y_mm": 25}]},
        ],
    }
    r = _run(board)
    assert r["complete"] is True
    assert r["missing_copper"] == []
    assert "partial" not in r


def test_a_cross_layer_x_crossing_earns_no_intersection_credit():
    """The negative gate on 019fd5fdeef3c: the same plus-sign with the bars on
    DIFFERENT layers is NOT connected (layers overlap freely; only a via or a
    TH pad bridges them) — two pin islands."""
    board = {
        "version": 1, "name": "cross-layer", "width_mm": 30, "height_mm": 30,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2},
        "components": [
            {"ref": c["ref"], "footprint": "R", "x_mm": c["x"], "y_mm": c["y"],
             "rotation_deg": 0,
             "pins": [{"number": "1", "x_mm": 0, "y_mm": 0,
                       "pad_width_mm": 1, "pad_height_mm": 1}]}
            for c in ({"ref": "W", "x": 5, "y": 15},
                      {"ref": "E", "x": 25, "y": 15},
                      {"ref": "N", "x": 15, "y": 5},
                      {"ref": "S", "x": 15, "y": 25})
        ],
        "nets": [{"name": "SIG",
                  "pins": ["W.1", "E.1", "N.1", "S.1"]}],
        "traces": [
            {"net": "SIG", "layer": "top", "width_mm": 0.25,
             "points": [{"x_mm": 5, "y_mm": 15}, {"x_mm": 25, "y_mm": 15}]},
            {"net": "SIG", "layer": "bottom", "width_mm": 0.25,
             "points": [{"x_mm": 15, "y_mm": 5}, {"x_mm": 15, "y_mm": 25}]},
        ],
    }
    r = _run(board)
    assert r["complete"] is False
    assert r["partial"] == [{"net": "SIG", "pin_groups": 2}]


def test_every_census_reply_carries_the_approximate_label():
    """DCR 019fd5fd9084: the census basis is centerline coincidence, not
    geometric copper — every census output says so (`approximate: True`),
    complete or not."""
    assert _run(yaml.safe_load(_CLEAN))["approximate"] is True
    assert _run(yaml.safe_load(_ZERO_COPPER))["approximate"] is True


def test_completeness_rides_the_worker_drc_method_too():
    """The standalone `drc` method reply (the surface the owner actually read
    "clean" from) carries the same keys."""
    resp = handle_request({"id": "d3", "method": "drc",
                           "params": {"yaml": _ZERO_COPPER}})
    assert resp["ok"] is True
    assert resp["result"]["complete"] is False
    assert resp["result"]["missing_copper"] == ["VCC_5V"]
    assert resp["result"]["approximate"] is True


# ---------------------------------------------------------------------------
# Census narrowing: zone-bearing nets (epoch CPN1 — the coupon's return pour
# blocked its own promote)
# ---------------------------------------------------------------------------


def _zone_net_board(with_bridge_trace: bool) -> dict:
    board = {
        "name": "pour-census", "width_mm": 20, "height_mm": 15,
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.25,
                         "via_diameter_mm": 0.6, "via_drill_mm": 0.3},
        "components": [
            {"ref": "R1", "footprint": "R", "x_mm": 4, "y_mm": 7, "layer": "top",
             "pins": [{"number": "1", "x_mm": 0, "y_mm": 0,
                       "pad_width_mm": 1.0, "pad_height_mm": 1.0}]},
            {"ref": "R2", "footprint": "R", "x_mm": 16, "y_mm": 7, "layer": "top",
             "pins": [{"number": "1", "x_mm": 0, "y_mm": 0,
                       "pad_width_mm": 1.0, "pad_height_mm": 1.0}]},
        ],
        "nets": [{"name": "GNDZ", "pins": ["R1.1", "R2.1"]}],
        "zones": [{"id": "z1", "net": "GNDZ", "layer": "top", "kind": "copper_pour",
                   "outline": [{"x_mm": 2, "y_mm": 2}, {"x_mm": 18, "y_mm": 2},
                               {"x_mm": 18, "y_mm": 13}, {"x_mm": 2, "y_mm": 13}]}],
        "traces": [],
    }
    if with_bridge_trace:
        board["traces"] = [{"net": "GNDZ", "layer": "top", "width_mm": 0.25,
                            "points": [{"x_mm": 4, "y_mm": 7},
                                       {"x_mm": 16, "y_mm": 7}]}]
    return board


def test_zone_net_complete_by_traces_alone_is_complete_not_indeterminate():
    """The CPN1 narrowing: when the trace+via graph ALONE joins every pin,
    zone copper can only ADD — the unanswerable pour question cannot change
    the verdict, so the net is COMPLETE and the board census tri-state is
    True, not None. (Before this, any pour on a net made the whole board
    unpromotable: 'an unverifiable board does not promote'.)"""
    census = drc.connectivity_completeness(_zone_net_board(with_bridge_trace=True))
    assert census["indeterminate"] == []
    assert census["complete"] is True


def test_zone_net_with_trace_islands_stays_indeterminate():
    """The fail-closed half survives: no bridging trace -> the pour MIGHT
    connect the pins, might not — indeterminate, never auto-complete and
    never falsely partial."""
    census = drc.connectivity_completeness(_zone_net_board(with_bridge_trace=False))
    assert census["indeterminate"] == [{"net": "GNDZ", "reason": "zone_copper"}]
    assert census["complete"] is None
    assert census["partial"] == []
