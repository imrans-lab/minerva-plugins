"""Layer-hop waypoints — one hint expresses "F.Cu, duck under here, F.Cu".

Work item 01a04106bd. THE HITL that filed it: the owner drew one F.Cu route
hint across a corridor blocked by VBAT_F and the buck cluster, then proposed
FOUR separate vias to duck under the obstacles. The hint was un-routable as
drawn, the four via ghosts carried no net and no owner, and the agent recovered
the intent only by matching via coordinates to hint segments BY EYE.

A waypoint may now carry a ``layer``: the run CHANGES to that copper layer at
that point, and the materializer places one through via exactly there. The hop
is a property of the corner, so there is nothing left to geometry-match.

Everything here is measured through the real entry points — the pure bridge
call and ``handle_request("route", ...)`` — never through a private helper, so
a green run is a statement about what an agent actually gets back.

FAILS AGAINST OLD: every assertion about a via or a B.Cu segment. The previous
waypoint-derived path flattened every segment onto the hint's single
``kind_payload.layer`` and hardcoded ``vias = []``.

Same conventions as test_route_as_drawn.py.
"""

from __future__ import annotations

import pytest

from pcb_worker import route_bridge
from pcb_worker.methods import handle_request


def _call(method: str, params: dict) -> dict:
    resp = handle_request({"id": "r1", "method": method, "params": params})
    assert resp is not None and resp["id"] == "r1"
    return resp


def _board() -> dict:
    """Two headers on one net, a declared 2-layer stack, and its OWN via rule.

    via_diameter_mm/via_drill_mm are deliberately neither 0.8 nor 0.4 so a via
    sized by anything other than this board is visibly wrong.
    """
    return {
        "version": 1,
        "name": "hop",
        "width_mm": 60,
        "height_mm": 40,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
                         "via_diameter_mm": 0.6, "via_drill_mm": 0.3},
        "components": [
            {"ref": "U1",
             "footprint": "Connector_PinSocket_2.54mm:PinSocket_1x04_P2.54mm_Vertical",
             "x_mm": 15.24, "y_mm": 20.32, "rotation_deg": 0, "layer": "top"},
            {"ref": "J1",
             "footprint": "Connector_PinSocket_2.54mm:PinSocket_1x04_P2.54mm_Vertical",
             "x_mm": 45.72, "y_mm": 20.32, "rotation_deg": 0, "layer": "top"},
        ],
        "nets": [{"name": "SIG", "pins": ["U1.1", "J1.1"]}],
    }


def _hint(waypoints, _id: str = "ann1", **kp_overrides) -> dict:
    kp = {
        "hint_type": "single_trace",
        "detail_level": "detailed",
        "layer": "F.Cu",
        "source_pins": ["U1.1"],
        "dest_pins": ["J1.1"],
        "waypoints": waypoints,
        "width_mm": 0.3,
    }
    kp.update(kp_overrides)
    return {"id": _id, "kind": "pcb_route_hint", "lifecycle": "open",
            "author": {"kind": "human"}, "kind_payload": kp}


def _route(hint) -> dict:
    resp = _call("route", {"board": _board(), "route_hints": [hint],
                           "selection": {"mode": "open"}})
    assert resp.get("error") is None, resp
    return resp["result"]


def _only_route(result: dict) -> dict:
    routes = result.get("routes") or []
    assert len(routes) == 1, routes
    return routes[0]


def _messages(result: dict) -> str:
    return " || ".join(w.get("message", "") for w in result.get("warnings", []))


# ---------------------------------------------------------------------------
# 1. ONE hop -> exactly one via, at the hop, and the run changes side there
# ---------------------------------------------------------------------------


def test_1_one_layer_change_yields_exactly_one_via_at_the_hop():
    result = _route(_hint([
        [20.0, 20.32],
        {"x": 25.0, "y": 20.32, "layer": "bottom"},
        [35.0, 20.32],
    ]))
    route = _only_route(result)

    assert route["as_drawn"] is True
    # 1a: exactly one via, at the waypoint that named the layer — not somewhere
    # the agent has to derive.
    assert route["vias"] == [[25.0, 20.32]]
    assert result["via_count"] == 1
    # 1b: the run is F.Cu up to the hop and B.Cu after it.
    layers = [s["layer"] for s in route["segments"]]
    assert layers == ["F.Cu", "F.Cu", "B.Cu", "B.Cu"], layers
    # 1c: geometry is still verbatim, hop or no hop.
    pts = [route["segments"][0]["start"]] + [s["end"] for s in route["segments"]]
    assert pts[0] == pytest.approx([15.24, 20.32])
    assert pts[-1] == pytest.approx([45.72, 20.32])
    assert pts[1:-1] == [[20.0, 20.32], [25.0, 20.32], [35.0, 20.32]]


# ---------------------------------------------------------------------------
# 2. Duck under AND back: the HITL's actual intent, in ONE hint
# ---------------------------------------------------------------------------


def test_2_duck_under_and_back_is_two_vias_and_three_runs():
    result = _route(_hint([
        {"x": 25.0, "y": 20.32, "layer": "B.Cu"},
        {"x": 38.0, "y": 20.32, "layer": "F.Cu"},
    ], detail_level="guided"))
    route = _only_route(result)

    assert route["vias"] == [[25.0, 20.32], [38.0, 20.32]]
    assert [s["layer"] for s in route["segments"]] == ["F.Cu", "B.Cu", "F.Cu"]
    # 2b: detail_level is INFERRED FROM WAYPOINT COUNT, and a two-hop
    # duck-under has only two waypoints ("guided"). Naming where copper changes
    # side is drawing your own path, so it takes the as-drawn path anyway —
    # without this the hops would silently lose their vias for being short.
    assert route["as_drawn"] is True


# ---------------------------------------------------------------------------
# 3. Nothing changes for a hint that names no layers
# ---------------------------------------------------------------------------


def test_3_plain_waypoints_are_unchanged_single_layer_and_via_free():
    result = _route(_hint([[20.0, 20.32], [25.0, 20.32], [35.0, 20.32]]))
    route = _only_route(result)

    assert route["vias"] == []
    assert {s["layer"] for s in route["segments"]} == {"F.Cu"}
    assert result["via_count"] == 0


def test_3b_restating_the_current_layer_is_a_corner_not_a_hole():
    """A hole that changes nothing is a drill hit nobody asked for."""
    result = _route(_hint([
        [20.0, 20.32],
        {"x": 25.0, "y": 20.32, "layer": "top"},   # == the hint's own F.Cu
        [35.0, 20.32],
    ]))
    route = _only_route(result)
    assert route["vias"] == []
    assert {s["layer"] for s in route["segments"]} == {"F.Cu"}


# ---------------------------------------------------------------------------
# 4. Fail closed on a layer the board does not have
# ---------------------------------------------------------------------------


def test_4_undeclared_waypoint_layer_refuses_the_as_drawn_path_by_name():
    """"in3" as a typo and "in3" as a plane are indistinguishable."""
    result = _route(_hint([
        [20.0, 20.32],
        {"x": 25.0, "y": 20.32, "layer": "in3"},
        [35.0, 20.32],
    ]))
    route = _only_route(result)

    # 4a: it did NOT materialize as drawn — it fell back to the engine, which
    # is the documented behaviour of every other unusable-geometry case here.
    assert route.get("as_drawn") is not True
    # 4b: and it said so, naming the hint and the layer.
    msgs = _messages(result)
    assert "ann1" in [w.get("id") for w in result["warnings"]]
    assert "unusable waypoint layer" in msgs
    assert "in3" in msgs
    # 4c: no via was fabricated on a layer the board does not declare.
    assert route["vias"] == []


def test_4b_non_copper_waypoint_layer_is_refused_too():
    result = _route(_hint([
        [20.0, 20.32],
        {"x": 25.0, "y": 20.32, "layer": "F.SilkS"},
        [35.0, 20.32],
    ]))
    route = _only_route(result)
    assert route.get("as_drawn") is not True
    assert "unusable waypoint layer" in _messages(result)


# ---------------------------------------------------------------------------
# 5. The ENGINE path cannot honour hops — and must never drop them silently
# ---------------------------------------------------------------------------


def test_5_engine_path_warns_that_authored_hops_were_not_placed():
    """allow_layer_change hands layer choice to the engine, deliberately.

    A silent drop there would look exactly like the via evaporation this work
    exists to end, so the reply names it.
    """
    result = _route(_hint([
        [20.0, 20.32],
        {"x": 25.0, "y": 20.32, "layer": "bottom"},
        [35.0, 20.32],
    ], allow_layer_change=True))

    msgs = _messages(result)
    assert "waypoint layer hop(s) are NOT placed on this path" in msgs
    assert _only_route(result).get("as_drawn") is not True


# ---------------------------------------------------------------------------
# 6. The pure bridge call, so the shape is pinned independently of the method
# ---------------------------------------------------------------------------


def test_6_bridge_emits_hop_vias_positionally():
    board = route_bridge.board_to_router(_board())
    routes, nets, warnings, ids = route_bridge.materialize_detailed_hints(
        [_hint([{"x": 25.0, "y": 20.32, "layer": "bottom"}])],
        board, declared_layers=["top", "bottom"])

    assert ids == ["ann1"]
    assert nets == {"SIG"}
    assert warnings == []
    assert len(routes) == 1
    # Positional [x, y] — the shape _routes_to_vias and _serialize_routing_result
    # already speak. A v1 via has no per-via span to carry.
    assert routes[0]["vias"] == [[25.0, 20.32]]
    assert [s["layer"] for s in routes[0]["segments"]] == ["F.Cu", "B.Cu"]


def test_6b_dict_shaped_waypoints_without_a_layer_are_plain_corners():
    """{"x","y"} has always been an accepted position shape; adding `layer` to
    the vocabulary must not make a layer-less dict mean anything new."""
    board = route_bridge.board_to_router(_board())
    routes, _nets, warnings, _ids = route_bridge.materialize_detailed_hints(
        [_hint([{"x": 25.0, "y": 20.32}])], board,
        declared_layers=["top", "bottom"])

    assert warnings == []
    assert routes[0]["vias"] == []
    assert {s["layer"] for s in routes[0]["segments"]} == {"F.Cu"}
