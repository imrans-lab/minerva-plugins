"""DRC-at-propose (docket 019f6f1492e0): route() attaches per-route DRC results.

When routing succeeds on the CANONICAL path, `route()` builds the post-route
board (the input board's existing traces + every returned route materialized
as traces, per-segment layer respected) and runs the EXISTING drc.run_drc
engine over it (drc.py's four checks, reused verbatim — see
pcb_worker.methods._drc_for_routes). Each route gains "drc": {clean,
violations} filtered to findings involving that route's net; the payload
gains a top-level "drc_summary": {clean, violation_count}. A DRC-engine
fault must never fail the route call — routes still return, with
"drc": {clean: None, error}.

Same fixture/call conventions as test_route_as_drawn.py: a 'detailed'
single-trace hint materializes verbatim (pad -> waypoints -> pad), so the
resulting route geometry is fully predictable and easy to collide with a
hand-authored existing trace.
"""

from __future__ import annotations

import pytest

from pcb_worker import drc as drc_module
from pcb_worker.methods import handle_request


def _call(method: str, params: dict) -> dict:
    resp = handle_request({"id": "r1", "method": method, "params": params})
    assert resp is not None and resp["id"] == "r1"
    return resp


def _detailed_hint(_id: str = "ann1", **kp_overrides) -> dict:
    kp = {
        "hint_type": "single_trace",
        "detail_level": "detailed",
        "layer": "F.Cu",
        "source_pins": ["U1.SIG"],
        "dest_pins": ["J1.SIG"],
        "waypoints": [],  # straight pad -> pad segment: fully predictable geometry
        "width_mm": 0.25,
    }
    kp.update(kp_overrides)
    return {"id": _id, "kind": "pcb_route_hint", "lifecycle": "open",
            "author": {"kind": "human"}, "kind_payload": kp}


def _board(existing_traces: list | None = None) -> dict:
    """U1(10,20)-SIG <-> J1(50,20)-SIG, one net, no existing traces by default.

    A1/A2 (net EXIST) at (30,5)/(30,35) let callers author an existing
    vertical trace at x=30 that the SIG pad-to-pad segment (a straight
    horizontal line at y=20) crosses at (30, 20) — same layer, different net.
    """
    return {
        "version": 1,
        "name": "drc-at-propose",
        "width_mm": 60,
        "height_mm": 40,
        "components": [
            {"ref": "U1", "footprint": "HEADER", "x_mm": 10, "y_mm": 20,
             "rotation_deg": 0, "layer": "top",
             "pins": [{"number": "SIG", "x_mm": 0.0, "y_mm": 0.0}]},
            {"ref": "J1", "footprint": "HEADER", "x_mm": 50, "y_mm": 20,
             "rotation_deg": 0, "layer": "top",
             "pins": [{"number": "SIG", "x_mm": 0.0, "y_mm": 0.0}]},
            {"ref": "A1", "footprint": "HEADER", "x_mm": 30, "y_mm": 5,
             "rotation_deg": 0, "layer": "top",
             "pins": [{"number": "EXIST", "x_mm": 0.0, "y_mm": 0.0}]},
            {"ref": "A2", "footprint": "HEADER", "x_mm": 30, "y_mm": 35,
             "rotation_deg": 0, "layer": "top",
             "pins": [{"number": "EXIST", "x_mm": 0.0, "y_mm": 0.0}]},
        ],
        "nets": [
            {"name": "SIG", "pins": ["U1.SIG", "J1.SIG"]},
            {"name": "EXIST", "pins": ["A1.EXIST", "A2.EXIST"]},
        ],
        "traces": existing_traces or [],
    }


_CROSSING_TRACE = [{"net": "EXIST", "layer": "top", "width_mm": 0.25,
                    "points": [{"x_mm": 30, "y_mm": 5}, {"x_mm": 30, "y_mm": 35}]}]


def _clean_board() -> dict:
    """U1<->J1 (net SIG) ONLY — no second multi-pad net. FINDING (pre-existing,
    confirmed by nudge hint pcb-plugin/router-reroutes-whole-board): route()
    auto-routes EVERY net on the board with >=2 pads, not just the ones a hint
    targets — so _board()'s EXIST net (A1/A2, 2 pads) would itself get routed
    and could produce its own crossing, contaminating a "nothing to report"
    fixture. A clean-DRC fixture must therefore have only the one net."""
    return {
        "version": 1,
        "name": "drc-at-propose-clean",
        "width_mm": 60,
        "height_mm": 40,
        "components": [
            {"ref": "U1", "footprint": "HEADER", "x_mm": 10, "y_mm": 20,
             "rotation_deg": 0, "layer": "top",
             "pins": [{"number": "SIG", "x_mm": 0.0, "y_mm": 0.0}]},
            {"ref": "J1", "footprint": "HEADER", "x_mm": 50, "y_mm": 20,
             "rotation_deg": 0, "layer": "top",
             "pins": [{"number": "SIG", "x_mm": 0.0, "y_mm": 0.0}]},
        ],
        "nets": [{"name": "SIG", "pins": ["U1.SIG", "J1.SIG"]}],
        "traces": [],
    }


# ---------------------------------------------------------------------------
# Dirty fixture: the routed SIG segment crosses the existing EXIST trace.
# ---------------------------------------------------------------------------


def test_route_flags_collision_with_existing_trace():
    resp = _call("route", {"board": _board(_CROSSING_TRACE),
                           "route_hints": [_detailed_hint()],
                           "selection": {"mode": "open"}})
    assert resp["ok"] is True, resp
    r = resp["result"]

    sig = [rt for rt in r["routes"] if rt["net"] == "SIG"]
    assert len(sig) == 1
    route_drc = sig[0]["drc"]
    assert route_drc["clean"] is False
    assert len(route_drc["violations"]) >= 1
    assert any(v["type"] == "crossing" for v in route_drc["violations"])
    crossing = [v for v in route_drc["violations"] if v["type"] == "crossing"][0]
    assert sorted(crossing["nets"]) == ["EXIST", "SIG"]
    assert crossing["layer"] == "top"

    summary = r["drc_summary"]
    assert summary["clean"] is False
    assert summary["violation_count"] >= 1


def test_wrong_net_pad_collision_flags_the_offending_route():
    """SW1-collision live case: a hint whose waypoint lands ON a foreign pad
    mid-route (A1's EXIST pad at (30,20), directly on the SIG path). Using an
    INTERIOR waypoint (not a terminal) is deliberate: _check_wrong_net_pad only
    inspects a trace's own vertex points, and a route's terminal endpoints are
    always exactly its own pad (drc.py correctly no-ops there — "correctly
    lands on its own net's pad") — so the collision must be authored at a
    waypoint vertex to be a genuine wrong-net short, exactly like a hint
    dragged across a foreign component's pad."""
    board = _board()  # A1 (net EXIST) sits at (30, 5) by default; move it onto the path
    board["components"][2]["x_mm"] = 30
    board["components"][2]["y_mm"] = 20

    hint = _detailed_hint(waypoints=[[30, 20]])
    resp = _call("route", {"board": board,
                           "route_hints": [hint],
                           "selection": {"mode": "open"}})
    assert resp["ok"] is True, resp
    r = resp["result"]
    sig = [rt for rt in r["routes"] if rt["net"] == "SIG"]
    assert len(sig) == 1
    assert sig[0]["drc"]["clean"] is False
    assert any(v["type"] == "wrong_net_pad" for v in sig[0]["drc"]["violations"])
    assert r["drc_summary"]["clean"] is False


# ---------------------------------------------------------------------------
# Clean fixture: nothing to report.
# ---------------------------------------------------------------------------


def test_route_clean_when_no_collision():
    resp = _call("route", {"board": _clean_board(),
                           "route_hints": [_detailed_hint()],
                           "selection": {"mode": "open"}})
    assert resp["ok"] is True, resp
    r = resp["result"]

    sig = [rt for rt in r["routes"] if rt["net"] == "SIG"]
    assert len(sig) == 1
    assert sig[0]["drc"] == {"clean": True, "violations": []}
    assert r["drc_summary"] == {"clean": True, "violation_count": 0}


# ---------------------------------------------------------------------------
# DRC-engine failure: route() must still succeed, with clean:null everywhere.
# ---------------------------------------------------------------------------


def test_drc_engine_failure_is_reported_not_raised(monkeypatch):
    def _boom(_board):
        raise RuntimeError("synthetic DRC engine fault")

    monkeypatch.setattr(drc_module, "run_drc", _boom)

    resp = _call("route", {"board": _clean_board(),
                           "route_hints": [_detailed_hint()],
                           "selection": {"mode": "open"}})
    assert resp["ok"] is True, resp
    r = resp["result"]

    sig = [rt for rt in r["routes"] if rt["net"] == "SIG"]
    assert len(sig) == 1
    assert sig[0]["drc"]["clean"] is None
    assert "synthetic DRC engine fault" in sig[0]["drc"]["error"]

    assert r["drc_summary"]["clean"] is None
    assert "synthetic DRC engine fault" in r["drc_summary"]["error"]


# ---------------------------------------------------------------------------
# Native pad-list path: no canonical board, DRC is skipped entirely.
# ---------------------------------------------------------------------------


def test_native_path_carries_no_drc_keys():
    resp = _call("route", {"board": {
        "pads": [
            {"component": "U1", "number": "1", "net": "SIG", "x": 0, "y": 0, "size": [1, 1]},
            {"component": "U2", "number": "1", "net": "SIG", "x": 10, "y": 0, "size": [1, 1]},
        ],
        "width": 20, "height": 20,
    }})
    assert resp["ok"] is True, resp
    r = resp["result"]
    assert "drc_summary" not in r
    for rt in r["routes"]:
        assert "drc" not in rt
