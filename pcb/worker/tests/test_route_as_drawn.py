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
             "pins": [{"number": "SIG", "x_mm": 0.0, "y_mm": 0.0,
                       "pad_width_mm": 1.7, "pad_height_mm": 1.7},
                      {"number": "GND", "x_mm": 0.0, "y_mm": 2.54,
                       "pad_width_mm": 1.7, "pad_height_mm": 1.7}]},
            {"ref": "J1", "footprint": "HEADER", "x_mm": 45.72, "y_mm": 20.32,
             "rotation_deg": 0, "layer": "top",
             "pins": [{"number": "SIG", "x_mm": 0.0, "y_mm": 0.0,
                       "pad_width_mm": 1.7, "pad_height_mm": 1.7},
                      {"number": "GND", "x_mm": 0.0, "y_mm": 2.54,
                       "pad_width_mm": 1.7, "pad_height_mm": 1.7}]},
        ],
        "nets": [{"name": "SIG", "pins": ["U1.SIG", "J1.SIG"]}],
    }


def _ir_two_pin_board() -> dict:
    """The same HITL-2 topology as :func:`_two_pin_board`, but COMPILABLE.

    ROUND E (019f783860c8): the route() METHOD now compiles the board and routes
    the ResolvedBoard IR, so a method-level fixture must name a footprint the seed
    library resolves and reference the footprint's own pad numbers. Real pads:
    PinSocket_1x04 puts pad "1" at the component origin, so U1.1 sits at
    (15.24, 20.32) and J1.1 at (45.72, 20.32) — the exact positions the pure-bridge
    fixture placed "SIG" at, so the drawn corridor below is unchanged.
    """
    return {
        "version": 1,
        "name": "hitl2-ir",
        "width_mm": 60,
        "height_mm": 40,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [
            {"ref": "U1", "footprint": "Connector_PinSocket_2.54mm:PinSocket_1x04_P2.54mm_Vertical",
             "x_mm": 15.24, "y_mm": 20.32, "rotation_deg": 0, "layer": "top"},
            {"ref": "J1", "footprint": "Connector_PinSocket_2.54mm:PinSocket_1x04_P2.54mm_Vertical",
             "x_mm": 45.72, "y_mm": 20.32, "rotation_deg": 0, "layer": "top"},
        ],
        "nets": [{"name": "SIG", "pins": ["U1.1", "J1.1"]}],
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
    resp = _call("route", {"board": _ir_two_pin_board(),
                           "route_hints": [_detailed_hint(source_pins=["U1.1"],
                                                          dest_pins=["J1.1"])],
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
    # The honest-omission warning must NOT fire for a materialized hint —
    # neither the detail_level note nor the waypoints-ignored status (bug
    # 019fcf152791): this hint's waypoints WERE honoured, as drawn.
    assert not [w for w in r.get("warnings", [])
                if "detail_level 'detailed'" in w.get("message", "")]
    assert not [w for w in r.get("warnings", [])
                if w.get("waypoint_status") == "ignored"]


def test_route_method_guided_hint_keeps_engine_path():
    resp = _call("route", {"board": _ir_two_pin_board(),
                           "route_hints": [_detailed_hint(detail_level="guided", _id="g1",
                                                          source_pins=["U1.1"],
                                                          dest_pins=["J1.1"])],
                           "selection": {"mode": "open"}})
    assert resp["ok"] is True, resp
    r = resp["result"]
    sig = [rt for rt in r["routes"] if rt["net"] == "SIG"]
    assert len(sig) == 1
    assert not sig[0].get("as_drawn", False)
    # detail_level is reported as having no ENGINE slot — not as inert
    # (bug 019fcf152791: the old "dropped — no agent_router equivalent"
    # wording hid that detail_level selects the bridge path one level up).
    assert any("detail_level 'guided' has no agent_router slot" in w.get("message", "")
               for w in r.get("warnings", []))

    # STAGE B (bug 019fcf152791): a guided hint's waypoints are now HONOURED
    # by the engine's product-state A*, so the Stage A "ignored" status must
    # NO LONGER fire — its presence would mean the corridor was dropped again.
    assert not [w for w in r.get("warnings", []) if w.get("waypoint_status") == "ignored"]

    # And the run reports how well it followed the corridor, per hint.
    adherence = r.get("corridor_adherence", [])
    assert len(adherence) == 1, r
    a = adherence[0]
    assert a["hint_id"] == "g1"
    assert a["status"] in ("honored", "partial")
    assert a["skipped_waypoints"] == []
    assert len(a["per_waypoint"]) == len(_WAYPOINTS)
    # Every authored waypoint influenced the route.
    assert all(w["within_tolerance"] for w in a["per_waypoint"]), a


def test_route_method_sparse_hint_without_waypoints_reports_no_status():
    """No authored corridor ⇒ nothing was ignored ⇒ no status (negative gate).

    Guards against the status becoming ambient noise on every hint, which is
    how the warning channel became unreadable in the first place.
    """
    resp = _call("route", {"board": _ir_two_pin_board(),
                           "route_hints": [_detailed_hint(detail_level="sparse", _id="s1",
                                                          source_pins=["U1.1"],
                                                          dest_pins=["J1.1"],
                                                          waypoints=[])],
                           "selection": {"mode": "open"}})
    assert resp["ok"] is True, resp
    r = resp["result"]
    assert not [w for w in r.get("warnings", []) if w.get("waypoint_status")]


# ---------------------------------------------------------------------------
# AUTHORED geometry (owner ruling (b), bug 01a001fca55f; epoch NLC C1b)
#
# A detailed hint that carries its own kind_payload.segments/vias is
# materialized from THEM. Before this, every segment was flattened onto the
# hint's single kind_payload.layer and vias were hardcoded to [] — so a via the
# user placed and watched appear on the canvas evaporated at apply, and a run
# that changed layer came out on one.
# ---------------------------------------------------------------------------


# The authored fixtures are 4-LAYER on purpose (cold review, finding 4). An
# earlier draft ran an In1.Cu segment against the 2-layer _two_pin_board() and
# asserted it materialized — pinning as CORRECT the very defect the
# declared-stack check exists to refuse.
QUAD_STACK = ["top", "in1", "in2", "bottom"]


def _quad_board() -> dict:
    """_two_pin_board() with a declared 4-layer copper stack."""
    b = _two_pin_board()
    b["layers"] = list(QUAD_STACK)
    return b


def _authored_hint(_id: str = "ann1", **kp_overrides) -> dict:
    """A detailed hint whose run crosses from F.Cu to In1.Cu through a via.

    Deliberately an INNER layer: the two-layer case cannot distinguish
    "honoured the authored layer" from "flattened onto kind_payload.layer",
    because on a 2-layer board those coincide half the time.
    """
    return _detailed_hint(
        _id,
        segments=[
            {"start": [15.24, 20.32], "end": [30.0, 20.32], "layer": "F.Cu"},
            {"start": [30.0, 20.32], "end": [45.72, 20.32], "layer": "In1.Cu"},
        ],
        vias=[[30.0, 20.32]],
        **kp_overrides,
    )


def test_authored_segments_keep_their_own_layers():
    board = route_bridge.board_to_router(_two_pin_board())
    routes, _, _, ids = route_bridge.materialize_detailed_hints(
        [_authored_hint()], board, declared_layers=QUAD_STACK)

    assert ids == ["ann1"]
    assert len(routes) == 1
    layers = [s["layer"] for s in routes[0]["segments"]]
    # The flattening bug produced ["F.Cu", "F.Cu"] here, from kp["layer"].
    assert layers == ["F.Cu", "In1.Cu"]


def test_authored_vias_are_not_dropped():
    board = route_bridge.board_to_router(_two_pin_board())
    routes, _, _, _ = route_bridge.materialize_detailed_hints(
        [_authored_hint()], board, declared_layers=QUAD_STACK)
    # Was hardcoded []. THE headline defect of bug 01a001fca55f.
    assert routes[0]["vias"] == [[30.0, 20.32]]


def test_authored_vias_reach_the_DRC_harvest_as_through_vias():
    """The consumer-side half: an emitted via must survive into the board DRC
    actually runs against, carrying the v1 through span.

    This is the assertion that makes the two above mean something. A route dict
    holding a via is not copper; methods._routes_to_vias is what turns it into
    a board via, and _post_route_board merges THAT into the board handed to
    drc.run_drc. Asserting only on the route dict would leave the same
    "producer works, nothing consumes it" gap this bug was filed for.
    """
    from pcb_worker import methods

    board = route_bridge.board_to_router(_quad_board())
    routes, _, _, _ = route_bridge.materialize_detailed_hints(
        [_authored_hint()], board, declared_layers=QUAD_STACK)

    harvested = methods._routes_to_vias(routes)
    assert len(harvested) == 1
    assert harvested[0]["x_mm"] == pytest.approx(30.0)
    assert harvested[0]["y_mm"] == pytest.approx(20.32)
    # Through via at any stack depth — see _routes_to_vias' own docstring.
    assert harvested[0]["from_layer"] == "top"
    assert harvested[0]["to_layer"] == "bottom"

    post = methods._post_route_board(_two_pin_board(), routes)
    assert any(v["x_mm"] == pytest.approx(30.0) for v in post["vias"])


def test_unknown_authored_layer_falls_back_and_warns():
    """FAILS CLOSED. An unreadable layer name must not become a default, and
    must not take half the route with it: the whole hint falls back to the
    engine and says so."""
    board = route_bridge.board_to_router(_two_pin_board())
    hint = _authored_hint()
    hint["kind_payload"]["segments"][1]["layer"] = "Nope.Cu"
    routes, nets, warnings, ids = route_bridge.materialize_detailed_hints(
        [hint], board, declared_layers=QUAD_STACK)

    assert routes == [] and nets == set() and ids == []
    assert any(w.get("id") == "ann1" and "authored geometry" in w.get("message", "")
               for w in warnings), warnings


def test_malformed_authored_via_is_not_silently_dropped():
    """The whole bug was vias disappearing without a word. A via that cannot be
    read falls the hint back to the engine WITH a warning — it never ships a
    route that quietly has one fewer hole than the author drew."""
    board = route_bridge.board_to_router(_two_pin_board())
    hint = _authored_hint()
    hint["kind_payload"]["vias"] = [[30.0]]
    routes, _, warnings, ids = route_bridge.materialize_detailed_hints(
        [hint], board, declared_layers=QUAD_STACK)

    assert routes == [] and ids == []
    assert any("via 0" in w.get("message", "") for w in warnings), warnings


def test_zero_length_authored_segment_is_skipped_not_refused():
    """Matches the waypoint path's own `pts[i] != pts[i + 1]` filter."""
    board = route_bridge.board_to_router(_two_pin_board())
    hint = _authored_hint()
    hint["kind_payload"]["segments"].insert(
        1, {"start": [30.0, 20.32], "end": [30.0, 20.32], "layer": "F.Cu"})
    routes, _, _, ids = route_bridge.materialize_detailed_hints(
        [hint], board, declared_layers=QUAD_STACK)

    assert ids == ["ann1"]
    assert [s["layer"] for s in routes[0]["segments"]] == ["F.Cu", "In1.Cu"]


def test_hint_without_authored_segments_still_uses_waypoints():
    """The fallback must survive the addition of the authored path — otherwise
    every hint that predates it silently changes shape. Same assertion as
    test_detailed_hint_materializes_verbatim, stated as a regression."""
    board = route_bridge.board_to_router(_two_pin_board())
    routes, _, _, _ = route_bridge.materialize_detailed_hints(
        [_detailed_hint()], board)
    assert routes[0]["vias"] == []
    assert all(s["layer"] == "F.Cu" for s in routes[0]["segments"])


def test_authored_layer_off_the_declared_stack_is_refused():
    """FINDING 4. canon_to_kicad accepts in1..in30 on ANY board, so without a
    declared-stack check an authored "in5" on a 4-layer board materialized
    happily — and _materialize_routes commits it through PCBData.add_trace,
    which (unlike create_trace_entity) does not gate on the stack. That is
    copper on a layer the board does not have."""
    board = route_bridge.board_to_router(_quad_board())
    hint = _authored_hint()
    hint["kind_payload"]["segments"][1]["layer"] = "In5.Cu"
    routes, nets, warnings, ids = route_bridge.materialize_detailed_hints(
        [hint], board, declared_layers=QUAD_STACK)

    assert routes == [] and nets == set() and ids == []
    assert any("does not declare" in w.get("message", "") for w in warnings), warnings


def test_unknown_declared_stack_does_not_block_authored_geometry():
    """Empty/absent `layers` means UNKNOWN, never "nothing is allowed" — a board
    that declares no stack must not have every authored hint refused."""
    board = route_bridge.board_to_router(_two_pin_board())
    routes, _, _, ids = route_bridge.materialize_detailed_hints(
        [_authored_hint()], board, declared_layers=None)
    assert ids == ["ann1"]
    assert [s["layer"] for s in routes[0]["segments"]] == ["F.Cu", "In1.Cu"]


def test_empty_segments_does_not_silently_drop_authored_vias():
    """CODEX FINDING 3. Authored geometry was honoured only when `segments` was
    a NON-EMPTY list; every other shape fell through to the waypoint path, which
    hardcodes vias:[]. So a hint with segments:[] and a real via returned a
    successful route with the hole silently gone — this epoch's headline defect,
    reached by a different door. Absent geometry and MALFORMED geometry are now
    different things."""
    board = route_bridge.board_to_router(_quad_board())
    hint = _authored_hint()
    hint["kind_payload"]["segments"] = []
    routes, _, warnings, ids = route_bridge.materialize_detailed_hints(
        [hint], board, declared_layers=QUAD_STACK)

    assert routes == [] and ids == []
    assert any("empty or not a list" in w.get("message", "") for w in warnings), warnings


def test_wrong_typed_segments_is_malformed_not_absent():
    board = route_bridge.board_to_router(_quad_board())
    hint = _authored_hint()
    hint["kind_payload"]["segments"] = {"not": "a list"}
    routes, _, warnings, ids = route_bridge.materialize_detailed_hints(
        [hint], board, declared_layers=QUAD_STACK)
    assert routes == [] and ids == []
    assert warnings


def test_vias_without_any_segments_refuse_rather_than_evaporate():
    """A hint carrying vias but no segments to place them on is malformed, not
    sparse — taking the waypoint path would drop the vias without a word."""
    board = route_bridge.board_to_router(_quad_board())
    hint = _detailed_hint()
    hint["kind_payload"]["vias"] = [[30.0, 20.32]]
    routes, _, warnings, ids = route_bridge.materialize_detailed_hints(
        [hint], board, declared_layers=QUAD_STACK)
    assert routes == [] and ids == []
    assert any("no authored segments" in w.get("message", "") for w in warnings), warnings


@pytest.mark.parametrize("bad", [[True, 20.0], [float("nan"), 20.0],
                                 [float("inf"), 20.0], ["3", 20.0]])
def test_via_coordinates_reject_bool_and_non_finite(bad):
    """CODEX FINDING 7. bool is a subclass of int in Python, so [True, 20] became
    [1.0, 20.0] — copper at a plausible but unintended point. NaN/Infinity
    survive float() just as happily."""
    board = route_bridge.board_to_router(_quad_board())
    hint = _authored_hint()
    hint["kind_payload"]["vias"] = [bad]
    routes, _, warnings, ids = route_bridge.materialize_detailed_hints(
        [hint], board, declared_layers=QUAD_STACK)
    assert routes == [] and ids == []
    assert warnings


def test_authored_vias_are_counted_in_via_count():
    """CODEX FINDING 4. via_count came only from the engine result, so a run
    whose only via was AUTHORED reported 0 while routes[0].vias held it and the
    commit went on to create it — the headline number said nothing happened."""
    from pcb_worker import methods

    drawn = [{"net": "SIG", "segments": [], "vias": [[1.0, 2.0], [3.0, 4.0]],
              "as_drawn": True, "hint_id": "ann1"}]
    payload = {"routes": [{"net": "OTHER", "vias": [[9.0, 9.0]]}],
               "via_count": 1, "success": True, "unrouted": []}

    # THE PRODUCTION MERGE, called. The arithmetic was inline in _route(), where
    # the only way to reach it was a whole compiled board — so nothing reached
    # it, which is how the bug survived. Re-implementing the sum here instead
    # would be a test that cannot fail.
    methods._merge_drawn_routes(payload, drawn)

    assert payload["via_count"] == 3, "engine's 1 + the 2 authored"
    assert payload["routes"][0]["as_drawn"] is True, "as-drawn routes lead"
    assert len(payload["routes"]) == 2
