"""Epoch GA-2 — the routing engine routes the board's OWN declared stack.

Four contracts pinned here, one per section:

  1. N-LAYER ROUTE — a four-layer board (declared stack + a profile whose
     capabilities ceiling admits it) routes end-to-end through the route()
     method, and every proposed segment lands on a DECLARED plane. The same
     board WITHOUT a declaring profile refuses at compile: silence never
     widens a ceiling.
  2. STACK ORDER — the engine-facing layer list is the resolved stack's own
     order, outermost-first. Via-candidate ordering and every ``layers[0]``
     fallback in the engine depend on that order, so it is a contract, not a
     convenience.
  3. LOOSE-DICT COMMITTED COPPER (bug 019f6cf2b5f4) — ``board_to_router``'s
     dict path projects ``traces``/``vias`` into the Board's own
     existing-copper slots, so a net a human already routed is NOT re-routed
     and its copper is not crossed. Before GA-2 this path dropped both keys
     entirely: every accepted trace was invisible and every route run redrew
     the whole board.
  4. U3 OPT-IN (item 019f709e9dbd) — a 'detailed' hint carrying
     ``allow_layer_change: true`` is NOT materialized verbatim (verbatim
     means its single layer and ``vias: []`` forever); it flows to the
     engine's corridor path, where the normal costed via machinery may break
     onto another layer. Opting in is a choice, not a fallback, so no
     warning fires.

Same conventions as test_route_as_drawn.py (pure bridge calls +
handle_request for the method path).
"""

from __future__ import annotations

import pytest

from agent_router.router import route_board
from pcb_worker import compile_board as cb
from pcb_worker import route_bridge
from pcb_worker.methods import handle_request


def _call(method: str, params: dict) -> dict:
    resp = handle_request({"id": "ga2", "method": method, "params": params})
    assert resp is not None and resp["id"] == "ga2"
    return resp


_FOUR_LAYERS = ["top", "in1", "in2", "bottom"]
_FOUR_ALIASES = ("F.Cu", "In1.Cu", "In2.Cu", "B.Cu")


def _four_layer_board(**extra) -> dict:
    """A compilable 4-layer two-pin board under the one shipped profile that
    declares a 4-copper ceiling. Geometry is the HITL-2 topology so the route
    itself is trivially satisfiable — the stack is what's under test."""
    board = {
        "version": 1,
        "name": "ga2-4layer",
        "width_mm": 60,
        "height_mm": 40,
        "layers": list(_FOUR_LAYERS),
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4,
                         "rule_profile": "jlcpcb-4layer"},
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
    board.update(extra)
    return board


# ---------------------------------------------------------------------------
# 1. N-layer route through the method path.
# ---------------------------------------------------------------------------


def test_a_four_layer_board_routes_and_every_segment_is_on_a_declared_plane():
    resp = _call("route", {"board": _four_layer_board()})
    assert resp["ok"] is True, resp
    r = resp["result"]
    assert r["success"] is True
    assert r["unrouted"] == []
    sig = [rt for rt in r["routes"] if rt["net"] == "SIG"]
    assert len(sig) == 1
    layers_used = {s["layer"] for rt in r["routes"] for s in rt["segments"]}
    assert layers_used, "a routed board proposes real segments"
    assert layers_used <= set(_FOUR_ALIASES), (
        f"segments must land on the DECLARED stack only, got {layers_used}")


def test_the_same_stack_without_a_declaring_profile_refuses_at_compile():
    """The capabilities ceiling is the route method's gate too: absent
    declaration means the 2-layer baseline, and a deeper board fails the
    whole compile closed rather than routing on planes no profile admits."""
    board = _four_layer_board()
    del board["design_rules"]["rule_profile"]
    resp = _call("route", {"board": board})
    assert resp["ok"] is False
    assert resp["error"]["kind"] == "compile"
    assert any(d.get("code") == "unsupported_layer_stack"
               for d in resp["error"]["diagnostics"])
    assert "result" not in resp


# ---------------------------------------------------------------------------
# 2. Stack order is the engine's layer order.
# ---------------------------------------------------------------------------


def test_engine_layer_list_is_the_resolved_stack_outermost_first():
    result = cb.compile_board(_four_layer_board(),
                              requested_outputs=cb.V1_ROUTING_OUTPUTS)
    assert isinstance(result, cb.ResolutionSuccess), getattr(
        result, "diagnostics", None)
    assert route_bridge._routing_layer_ids(result.board) == _FOUR_ALIASES


# ---------------------------------------------------------------------------
# 3. Loose-dict committed copper (bug 019f6cf2b5f4).
# ---------------------------------------------------------------------------


def _loose_committed_board() -> dict:
    """Hand-authored pin board, TWO nets: net A's pads are already joined by a
    committed trace (with a via on it), net B is unrouted. The dict carries no
    ``layers`` key, so the declared stack defaults to the 2-layer pair."""
    return {
        "version": 1,
        "name": "loose-committed",
        "width_mm": 60,
        "height_mm": 40,
        "components": [
            {"ref": "U1", "footprint": "HEADER", "x_mm": 15.24, "y_mm": 20.32,
             "rotation_deg": 0, "layer": "top",
             "pins": [{"number": "A", "x_mm": 0.0, "y_mm": 0.0,
                       "pad_width_mm": 1.7, "pad_height_mm": 1.7},
                      {"number": "B", "x_mm": 0.0, "y_mm": 2.54,
                       "pad_width_mm": 1.7, "pad_height_mm": 1.7}]},
            {"ref": "J1", "footprint": "HEADER", "x_mm": 45.72, "y_mm": 20.32,
             "rotation_deg": 0, "layer": "top",
             "pins": [{"number": "A", "x_mm": 0.0, "y_mm": 0.0,
                       "pad_width_mm": 1.7, "pad_height_mm": 1.7},
                      {"number": "B", "x_mm": 0.0, "y_mm": 2.54,
                       "pad_width_mm": 1.7, "pad_height_mm": 1.7}]},
        ],
        "nets": [{"name": "A", "pins": ["U1.A", "J1.A"]},
                 {"name": "B", "pins": ["U1.B", "J1.B"]}],
        "traces": [{"id": "tA", "net": "A", "layer": "top", "width_mm": 0.3,
                    "points": [{"x_mm": 15.24, "y_mm": 20.32},
                               {"x_mm": 45.72, "y_mm": 20.32}]}],
        "vias": [{"id": "vA", "net": "A", "x_mm": 30.0, "y_mm": 20.32,
                  "diameter_mm": 0.8}],
    }


def test_loose_dict_traces_and_vias_reach_the_boards_existing_copper_slots():
    board = route_bridge.board_to_router(_loose_committed_board())
    assert len(board.existing_traces) == 1
    seg = board.existing_traces[0]
    assert seg.net == "A"
    assert seg.layer == "F.Cu"                 # canonical "top" -> engine alias
    assert seg.width == pytest.approx(0.3)
    assert seg.start == pytest.approx((15.24, 20.32))
    assert seg.end == pytest.approx((45.72, 20.32))
    assert seg.source_id == "tA"
    assert len(board.existing_vias) == 1
    via = board.existing_vias[0]
    assert via.net == "A"
    # Occupied SET, not endpoint pair: a through via reaches every declared
    # layer, and with no `layers` key declared that is the 2-layer default.
    assert via.layers == ("F.Cu", "B.Cu")


def test_a_committed_net_is_not_rerouted_and_the_open_net_still_routes():
    """THE discriminating assertion for bug 019f6cf2b5f4: before GA-2 the
    loose path saw no existing copper, so net A was re-routed from scratch —
    duplicate copper over a human's committed trace. Now A's committed trace
    already joins its pads (no new route), and B routes around copper the
    grid genuinely sees."""
    board = route_bridge.board_to_router(_loose_committed_board())
    result = route_board(board)
    assert not [r for r in result.routes if r.net == "A"], (
        "net A's pads are joined by committed copper — proposing a route for "
        "it is the exact duplication the bug names")
    assert [r for r in result.routes if r.net == "B"], (
        "the open net still routes")
    assert result.unrouted == []


# ---------------------------------------------------------------------------
# 4. U3 — allow_layer_change opts a detailed hint into the engine path.
# ---------------------------------------------------------------------------


def _two_pin_board() -> dict:
    """The HITL-2 pure-bridge fixture (one net, hand-authored pads)."""
    return {
        "version": 1,
        "name": "u3",
        "width_mm": 60,
        "height_mm": 40,
        "components": [
            {"ref": "U1", "footprint": "HEADER", "x_mm": 15.24, "y_mm": 20.32,
             "rotation_deg": 0, "layer": "top",
             "pins": [{"number": "SIG", "x_mm": 0.0, "y_mm": 0.0,
                       "pad_width_mm": 1.7, "pad_height_mm": 1.7}]},
            {"ref": "J1", "footprint": "HEADER", "x_mm": 45.72, "y_mm": 20.32,
             "rotation_deg": 0, "layer": "top",
             "pins": [{"number": "SIG", "x_mm": 0.0, "y_mm": 0.0,
                       "pad_width_mm": 1.7, "pad_height_mm": 1.7}]},
        ],
        "nets": [{"name": "SIG", "pins": ["U1.SIG", "J1.SIG"]}],
    }


def _ir_two_pin_board() -> dict:
    """The same topology, compilable (real seed footprint, real pad numbers)."""
    return {
        "version": 1,
        "name": "u3-ir",
        "width_mm": 60,
        "height_mm": 40,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
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


def test_allow_layer_change_hint_is_not_materialized_and_not_warned_about():
    board = route_bridge.board_to_router(_two_pin_board())
    routes, nets, warnings, ids = route_bridge.materialize_detailed_hints(
        [_detailed_hint(allow_layer_change=True)], board)
    assert routes == [] and nets == set() and ids == []
    # Opting in is a CHOICE, not a fallback — nothing to warn about.
    assert warnings == []


def test_opted_out_detailed_hint_still_routes_as_drawn_with_no_vias():
    """The unchanged half of U3's boundary: absent (or false) means verbatim
    materialization, single layer, vias:[] — exactly what the author drew."""
    board = route_bridge.board_to_router(_two_pin_board())
    routes, nets, _, ids = route_bridge.materialize_detailed_hints(
        [_detailed_hint(allow_layer_change=False)], board)
    assert ids == ["ann1"] and nets == {"SIG"}
    assert len(routes) == 1
    assert routes[0]["as_drawn"] is True
    assert routes[0].get("vias", []) == []


def test_route_method_allow_layer_change_flows_to_the_engine_corridor_path():
    hint = _detailed_hint(source_pins=["U1.1"], dest_pins=["J1.1"],
                          allow_layer_change=True)
    resp = _call("route", {"board": _ir_two_pin_board(),
                           "route_hints": [hint],
                           "selection": {"mode": "open"}})
    assert resp["ok"] is True, resp
    r = resp["result"]
    sig = [rt for rt in r["routes"] if rt["net"] == "SIG"]
    assert len(sig) == 1, "engine routes the net exactly once"
    assert not sig[0].get("as_drawn", False), (
        "opting into layer changes must NOT freeze the drawn line verbatim")
    # The detail_level warning is suppressed for the behaviour the author
    # chose (U3): warning about "not routed as drawn" here would be warning
    # about the opt-in itself.
    assert not [w for w in r.get("warnings", [])
                if "detail_level" in w.get("message", "")]
    # The drawn line still steers the engine — corridor grading is reported.
    adherence = r.get("corridor_adherence", [])
    assert [a for a in adherence if a["hint_id"] == "ann1"], r
