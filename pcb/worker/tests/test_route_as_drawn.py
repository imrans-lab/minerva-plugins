"""Route-as-drawn for 'detailed' single-trace hints (HITL-2 owner feedback).

Native DetailLevel semantics: a hint dense enough to infer 'detailed' means
"follow my line" — the human is routing around obstacles the engine cannot
see, so the waypoints ARE the route. materialize_detailed_hints() consumes
such hints and emits their polyline verbatim (pad -> waypoints -> pad); the
A* engine never re-routes those nets. 'guided'/'sparse' hints keep the old
soft-guidance path unchanged.

Same conventions as test_route_bridge.py (pure bridge calls + handle_request
for the method path).
"""

from __future__ import annotations

import pytest

from pcb_worker import route_bridge
from pcb_worker.methods import handle_request


def _call(method: str, params: dict) -> dict:
    resp = handle_request({"id": "r1", "method": method, "params": params})
    assert resp is not None and resp["id"] == "r1"
    return resp


def _two_pin_board() -> dict:
    """The HITL-2 fixture: two 2-pin headers, one net, no traces."""
    return {
        "version": 1,
        "name": "hitl2",
        "width_mm": 60,
        "height_mm": 40,
        "components": [
            {"ref": "U1", "footprint": "HEADER", "x_mm": 15.24, "y_mm": 20.32,
             "rotation_deg": 0, "layer": "top",
             "pins": [{"number": "SIG", "x_mm": 0.0, "y_mm": 0.0},
                      {"number": "GND", "x_mm": 0.0, "y_mm": 2.54}]},
            {"ref": "J1", "footprint": "HEADER", "x_mm": 45.72, "y_mm": 20.32,
             "rotation_deg": 0, "layer": "top",
             "pins": [{"number": "SIG", "x_mm": 0.0, "y_mm": 0.0},
                      {"number": "GND", "x_mm": 0.0, "y_mm": 2.54}]},
        ],
        "nets": [{"name": "SIG", "pins": ["U1.SIG", "J1.SIG"]}],
    }


# The owner's actual up-and-over obstacle-avoidance corridor.
_WAYPOINTS = [[15.27, 14.93], [15.32, 9.84], [33.26, 15.18], [45.99, 10.09]]


def _detailed_hint(_id: str = "ann1", **kp_overrides) -> dict:
    kp = {
        "hint_type": "single_trace",
        "detail_level": "detailed",
        "layer": "F.Cu",
        "source_pins": ["U1.SIG"],
        "dest_pins": ["J1.SIG"],
        "waypoints": [list(w) for w in _WAYPOINTS],
        "width_mm": 0.25,
    }
    kp.update(kp_overrides)
    return {"id": _id, "kind": "pcb_route_hint", "lifecycle": "open",
            "author": {"kind": "human"}, "kind_payload": kp}


# ---------------------------------------------------------------------------
# materialize_detailed_hints — pure bridge behavior
# ---------------------------------------------------------------------------


def test_detailed_hint_materializes_verbatim():
    board = route_bridge.board_to_router(_two_pin_board())
    routes, nets, warnings, ids = route_bridge.materialize_detailed_hints(
        [_detailed_hint()], board)

    assert ids == ["ann1"]
    assert nets == {"SIG"}
    assert len(routes) == 1
    r = routes[0]
    assert r["as_drawn"] is True
    assert r["net"] == "SIG"
    # pad -> each waypoint bit-exact -> pad
    pts = [r["segments"][0]["start"]] + [s["end"] for s in r["segments"]]
    assert pts[0] == pytest.approx([15.24, 20.32])
    assert pts[-1] == pytest.approx([45.72, 20.32])
    assert pts[1:-1] == _WAYPOINTS
    assert all(s["layer"] == "F.Cu" for s in r["segments"])
    assert not [w for w in warnings if "detail_level" in w.get("message", "")]


def test_guided_hint_is_not_materialized():
    board = route_bridge.board_to_router(_two_pin_board())
    routes, nets, _, ids = route_bridge.materialize_detailed_hints(
        [_detailed_hint(detail_level="guided")], board)
    assert routes == [] and nets == set() and ids == []


def test_unresolvable_endpoint_falls_back_to_engine():
    board = route_bridge.board_to_router(_two_pin_board())
    routes, nets, warnings, ids = route_bridge.materialize_detailed_hints(
        [_detailed_hint(dest_pins=["ZZ.9"])], board)
    assert routes == [] and nets == set() and ids == []
    assert any("fall" in w["message"] for w in warnings)


def test_cross_net_endpoints_fall_back_to_engine():
    spec = _two_pin_board()
    spec["nets"] = [{"name": "A", "pins": ["U1.SIG"]},
                    {"name": "B", "pins": ["J1.SIG"]}]
    board = route_bridge.board_to_router(spec)
    routes, nets, warnings, _ = route_bridge.materialize_detailed_hints(
        [_detailed_hint()], board)
    assert routes == [] and nets == set()
    assert any("shared net" in w["message"] for w in warnings)


# ---------------------------------------------------------------------------
# route() method — end to end through handle_request
# ---------------------------------------------------------------------------


def test_route_method_detailed_hint_routes_as_drawn():
    resp = _call("route", {"board": _two_pin_board(),
                           "route_hints": [_detailed_hint()],
                           "selection": {"mode": "open"}})
    assert resp["ok"] is True, resp
    r = resp["result"]
    assert r["success"] is True
    assert r["unrouted"] == []
    assert "ann1" in r.get("selected_hint_ids", [])

    sig = [rt for rt in r["routes"] if rt["net"] == "SIG"]
    assert len(sig) == 1, "net must not be routed twice (engine consumed it)"
    assert sig[0].get("as_drawn") is True
    pts = [sig[0]["segments"][0]["start"]] + [s["end"] for s in sig[0]["segments"]]
    assert pts[1:-1] == _WAYPOINTS
    # The honest-omission warning must NOT fire for a materialized hint.
    assert not [w for w in r.get("warnings", [])
                if "detail_level 'detailed' dropped" in w.get("message", "")]


def test_route_method_guided_hint_keeps_engine_path():
    resp = _call("route", {"board": _two_pin_board(),
                           "route_hints": [_detailed_hint(detail_level="guided", _id="g1")],
                           "selection": {"mode": "open"}})
    assert resp["ok"] is True, resp
    r = resp["result"]
    sig = [rt for rt in r["routes"] if rt["net"] == "SIG"]
    assert len(sig) == 1
    assert not sig[0].get("as_drawn", False)
    assert any("detail_level 'guided' dropped" in w.get("message", "")
               for w in r.get("warnings", []))
