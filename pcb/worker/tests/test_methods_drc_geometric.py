"""Unit tests for the ``drc_geometric`` worker method (Round C3).

Drive the REAL ``methods.handle_request({"method":"drc_geometric",...})`` dispatch
(not the kernel directly) so the wiring is proven end to end: the method must
return the GEOMETRIC RESULT UNION verbatim from
``drc_geometric.geometric_drc_from_resolution`` — the determinate envelope on a
compile success, the indeterminate envelope on a compile failure — and a
structured ``{ok:False, error:{kind:"parse"}}`` reply on a board that will not
parse. The kernel's own behaviour is covered by tests/test_drc_geometric.py; this
file is about the method contract + dispatch.
"""

from __future__ import annotations

from pcb_worker.methods import handle_request


def _call(params: dict) -> dict:
    resp = handle_request({"id": "g1", "method": "drc_geometric", "params": params})
    assert resp is not None
    assert resp["id"] == "g1"
    return resp


def _th(ref: str, x: float, y: float, drill: float = 0.5, annulus: float = 1.6) -> dict:
    return {"ref": ref, "footprint": "TH_TestPoint", "x_mm": x, "y_mm": y,
            "rotation_deg": 0, "layer": "top",
            "pins": [{"number": "1", "x_mm": 0, "y_mm": 0,
                      "drill_mm": drill, "annulus_diameter_mm": annulus}]}


def _base(**extra) -> dict:
    board = {
        "version": 1, "name": "brd", "width_mm": 40, "height_mm": 40,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [],
    }
    board.update(extra)
    return board


# ---------------------------------------------------------------------------
# Happy path — the DETERMINATE geometric union, returned verbatim.
# ---------------------------------------------------------------------------


def test_clean_board_returns_determinate_clean_union():
    board = _base(components=[_th("U1", 10, 10), _th("U2", 30, 30)],
                  nets=[{"name": "A", "pins": ["U1.1"]},
                        {"name": "B", "pins": ["U2.1"]}])
    resp = _call({"board": board})
    # The union verbatim — NOT collapsed into the legacy {ok, result} shape.
    assert resp["ok"] is True
    assert resp["scope"] == "geometric"
    assert resp["verifies_geometry"] is True
    assert resp["verdict"] == "clean"
    assert resp["findings"] == []
    assert all(v == 0 for v in resp["counts"].values())
    assert "result" not in resp          # not the legacy {ok, result} wrapper


def test_violation_board_returns_determinate_violations_union():
    # Two different-net TH lands (radius 0.8) whose centres are 1.7mm apart -> a
    # 0.1mm copper gap < the 0.2mm clearance floor: a real GC2 violation.
    board = _base(components=[_th("U1", 10, 10), _th("U2", 11.7, 10)],
                  nets=[{"name": "A", "pins": ["U1.1"]},
                        {"name": "B", "pins": ["U2.1"]}])
    resp = _call({"board": board})
    assert resp["ok"] is True
    assert resp["scope"] == "geometric"
    assert resp["verifies_geometry"] is True
    assert resp["verdict"] == "violations"
    assert resp["counts"]["gc2_copper_clearance"] >= 1
    assert any(f["type"] == "gc2_copper_clearance" for f in resp["findings"])


def test_accepts_yaml_source_like_the_other_methods():
    import yaml
    board = _base(components=[_th("U1", 10, 10), _th("U2", 30, 30)],
                  nets=[{"name": "A", "pins": ["U1.1"]},
                        {"name": "B", "pins": ["U2.1"]}])
    resp = _call({"yaml": yaml.safe_dump(board)})
    assert resp["ok"] is True
    assert resp["verdict"] == "clean"


# ---------------------------------------------------------------------------
# Parse failure — structured {ok:False, error:{kind:"parse"}} (never the union).
# ---------------------------------------------------------------------------


def test_parse_failure_returns_parse_error_reply():
    resp = _call({"yaml": "]["})
    assert resp["ok"] is False
    assert resp["error"]["kind"] == "parse"
    # A parse fault is the structured reply, NOT the geometric union.
    assert "verdict" not in resp
    assert "findings" not in resp


# ---------------------------------------------------------------------------
# Compile failure — the INDETERMINATE envelope (never a false clean).
# ---------------------------------------------------------------------------


def test_compile_failure_returns_indeterminate_envelope():
    # An unknown footprint cannot resolve -> compile fails -> indeterminate.
    board = _base(components=[{"ref": "U1", "footprint": "NOPE_NOT_A_REAL_FP",
                               "x_mm": 10, "y_mm": 10, "rotation_deg": 0,
                               "layer": "top"}])
    resp = _call({"board": board})
    assert resp["ok"] is False
    assert resp["scope"] == "geometric"
    assert resp["verifies_geometry"] is False
    assert resp["verdict"] == "indeterminate"
    # Fail-closed: NO clean/findings/counts a caller could mistake for a pass.
    assert "findings" not in resp
    assert "clean" not in resp
    assert "counts" not in resp
    # A compile/resolution failure is "unresolved_geometry" (distinct from the
    # method-level "parse" reply for a source that won't parse at all).
    assert resp["error"]["kind"] == "unresolved_geometry"
    assert resp["error"]["diagnostics"]  # carries the compile diagnostics
