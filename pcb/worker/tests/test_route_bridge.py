"""Unit tests for pcb_worker.route_bridge + the bridge-capable route() method.

Covers the annotation/hint -> agent_router bridge (docket 019eb481ae28):
  * board_to_router: absolute pad positions for a ROTATED component match the
    panel convention (get_pin_world_position); net membership is correct.
  * hints_to_router: waypoint coordinates survive translation bit-exact; pin
    refs resolve against the board; unresolvable refs become warnings.
  * select_hints: open-only (default) vs explicit ids.
  * route() end-to-end through the bridge on a small board + hint.

These call the pure bridge functions directly and handle_request() for the
method path (same pattern as test_methods.py).
"""

from __future__ import annotations

import math

import pytest

from pcb_worker import route_bridge
from pcb_worker.methods import handle_request


# ---------------------------------------------------------------------------
# Fixtures — small canonical boards
# ---------------------------------------------------------------------------


def _rotated_board() -> dict:
    """U1 rotated 90deg at (10, 20); pin "1" at offset (0,0), pin "2" at (2.54,0).

    Under the panel's get_pin_world_position convention (Transform2D of
    -rotation), pin "2" lands at (10, 20 - 2.54) = (10, 17.46).
    """
    return {
        "version": 1,
        "name": "RotTest",
        "width_mm": 40,
        "height_mm": 30,
        "components": [
            {
                "ref": "U1", "footprint": "IC", "x_mm": 10, "y_mm": 20,
                "rotation_deg": 90, "layer": "top",
                "pins": [
                    {"number": "1", "x_mm": 0.0, "y_mm": 0.0},
                    {"number": "2", "x_mm": 2.54, "y_mm": 0.0},
                ],
            },
            {
                "ref": "R1", "footprint": "R", "x_mm": 10, "y_mm": 5,
                "rotation_deg": 0, "layer": "top",
                "pins": [
                    {"number": "1", "x_mm": 0.0, "y_mm": 0.0},
                    {"number": "2", "x_mm": 1.0, "y_mm": 0.0},
                ],
            },
        ],
        "nets": [
            {"name": "SIG", "pins": ["U1.2", "R1.1"]},
        ],
    }


# Expected pad positions encode the PANEL convention (get_pin_world_position).
# Verified equal to a Godot Transform2D(deg_to_rad(-rotation)) simulation.
_EXPECTED_U1_2 = (10.0, 17.46)   # (10 + 2.54*cos90 + 0, 20 - 2.54*sin90 + 0)
_EXPECTED_U1_1 = (10.0, 20.0)    # origin pin is invariant under rotation


# ---------------------------------------------------------------------------
# board_to_router — rotation math + net membership
# ---------------------------------------------------------------------------


def test_board_to_router_rotated_pad_position_matches_panel_convention():
    board = route_bridge.board_to_router(_rotated_board())

    p2 = board.get_pad("U1", "2")
    assert p2 is not None
    assert p2.position[0] == pytest.approx(_EXPECTED_U1_2[0], abs=1e-9)
    assert p2.position[1] == pytest.approx(_EXPECTED_U1_2[1], abs=1e-9)

    # Origin pin is unaffected by rotation.
    p1 = board.get_pad("U1", "1")
    assert p1.position == pytest.approx(_EXPECTED_U1_1)


def test_board_to_router_matches_godot_transform_simulation():
    """Independent check: the bridge's pad position equals a direct simulation
    of Godot's Transform2D(deg_to_rad(-rotation)) * offset for several angles."""
    def godot_world(cx, cy, rot_deg, lx, ly):
        ang = math.radians(-rot_deg)
        c, s = math.cos(ang), math.sin(ang)
        return (cx + (lx * c - ly * s), cy + (lx * s + ly * c))

    for rot in (0, 90, 180, 270, 45):
        b = route_bridge.board_to_router({
            "components": [{
                "ref": "X", "x_mm": 3.0, "y_mm": 7.0, "rotation_deg": rot,
                "pins": [{"number": "p", "x_mm": 1.5, "y_mm": -0.95}],
            }],
            "nets": [],
        })
        pad = b.get_pad("X", "p")
        exp = godot_world(3.0, 7.0, rot, 1.5, -0.95)
        assert pad.position[0] == pytest.approx(exp[0], abs=1e-9)
        assert pad.position[1] == pytest.approx(exp[1], abs=1e-9)


def test_board_to_router_net_membership():
    board = route_bridge.board_to_router(_rotated_board())

    assert "SIG" in board.nets
    net = board.nets["SIG"]
    members = {(p.component, p.number) for p in net.pads}
    assert members == {("U1", "2"), ("R1", "1")}
    # pad.net back-references are set so get_net_pads / router marking agree.
    assert board.get_pad("U1", "2").net == "SIG"
    assert board.get_pad("R1", "1").net == "SIG"
    # An unreferenced pad stays net-less but still exists (keepout).
    assert board.get_pad("U1", "1").net is None


def test_board_to_router_through_hole_and_layer():
    board = route_bridge.board_to_router({
        "components": [{
            "ref": "J1", "x_mm": 0, "y_mm": 0, "rotation_deg": 0, "layer": "bottom",
            "pins": [{"number": "1", "x_mm": 0, "y_mm": 0,
                      "drill_mm": 0.8, "annulus_diameter_mm": 1.6}],
        }],
        "nets": [],
    })
    pad = board.get_pad("J1", "1")
    assert pad.pad_type == "thru_hole"
    assert pad.drill == pytest.approx(0.8)
    assert pad.size == pytest.approx((1.6, 1.6))   # from annulus diameter
    assert pad.layer == "B.Cu"                      # "bottom" -> B.Cu


@pytest.mark.parametrize("bad_drill", [float("nan"), float("inf"), float("-inf"), -1.0, 0.0])
def test_board_to_router_non_positive_or_nonfinite_drill_is_smd(bad_drill):
    # bug 019f920d433f: the router classifies through-hole via the SAME shared
    # finite-positive predicate the fab emitters use (pad_source.is_th_drill), so it
    # can never drift. A non-finite (NaN/Inf) or non-positive drill is modeled as SMD,
    # NOT a through-hole — the old bare `drill > 0` literal classified +Inf as a
    # through-hole (with an infinite drill).
    board = route_bridge.board_to_router({
        "components": [{
            "ref": "J1", "x_mm": 0, "y_mm": 0, "rotation_deg": 0, "layer": "top",
            "pins": [{"number": "1", "x_mm": 0, "y_mm": 0, "drill_mm": bad_drill,
                      "pad_width_mm": 1.0, "pad_height_mm": 1.0}],
        }],
        "nets": [],
    })
    pad = board.get_pad("J1", "1")
    assert pad.pad_type == "smd"
    assert pad.drill is None


def test_board_to_router_mounting_hole_obstacle():
    board = route_bridge.board_to_router({
        "components": [{"ref": "R1", "x_mm": 1, "y_mm": 1, "rotation_deg": 0,
                        "pins": [{"number": "1", "x_mm": 0, "y_mm": 0}]}],
        "nets": [],
        "mounting_holes": [{"x_mm": 5, "y_mm": 6, "diameter_mm": 3.2}],
    })
    assert len(board.obstacles) == 1
    obs = board.obstacles[0]
    assert obs.position == pytest.approx((5.0, 6.0))
    assert obs.radius == pytest.approx(1.6)


def test_board_to_router_rejects_empty():
    with pytest.raises(ValueError):
        route_bridge.board_to_router({"nets": []})
    with pytest.raises(ValueError):
        route_bridge.board_to_router("not a dict")


# ---------------------------------------------------------------------------
# hints_to_router — precision, resolution, warnings
# ---------------------------------------------------------------------------


def _route_hint(**payload) -> dict:
    """Build a minimal conformant pcb_route_hint envelope.

    ``_id`` / ``_lifecycle`` are envelope-level controls; everything else lands
    in kind_payload.
    """
    ann_id = payload.pop("_id", "ann1")
    lifecycle = payload.pop("_lifecycle", "open")
    kp = {
        "hint_type": "waypoint", "layer": "F.Cu", "width_mm": 0.25,
        "source_pins": [], "dest_pins": [], "waypoints": [],
    }
    kp.update(payload)
    return {
        "id": ann_id,
        "kind": "pcb_route_hint",
        "schema_version": 2,
        "anchor": {"plugin": "pcb", "type": "board.point",
                   "id": {"x": 0, "y": 0}, "snapshot": {"position": [0, 0]}},
        "kind_payload": kp,
        "lifecycle": lifecycle,
    }


def test_hints_to_router_waypoints_bit_exact():
    board = route_bridge.board_to_router(_rotated_board())
    # Pixel-accurate user corrections — must survive with ZERO drift.
    wps = [[12.3456789012345, 20.987654321], [15.111111111, 17.46]]
    env = _route_hint(source_pins=["U1.2"], waypoints=[list(w) for w in wps])
    out = route_bridge.hints_to_router([env], board)

    assert len(out.hints.net_hints) == 1
    nh = out.hints.net_hints[0]
    assert nh.net == "SIG"
    got = [[w.x, w.y] for w in nh.waypoints]
    # Bit-exact equality (==, not approx) — the whole point of the deliverable.
    assert got == wps


def test_hints_to_router_pin_ref_resolves_to_net():
    board = route_bridge.board_to_router(_rotated_board())
    env = _route_hint(source_pins=["R1.1"])   # R1.1 is on net SIG
    out = route_bridge.hints_to_router([env], board)
    assert out.hints.net_hints[0].net == "SIG"
    assert out.warnings == []


def test_hints_to_router_unresolvable_ref_warns_not_crashes():
    board = route_bridge.board_to_router(_rotated_board())
    env = _route_hint(source_pins=["U9.7"], dest_pins=[])  # no such pad
    out = route_bridge.hints_to_router([env], board)
    # No net_hint emitted, but a structured warning names the bad ref.
    assert out.hints.net_hints == []
    assert any("U9.7" in w["message"] and w["id"] == "ann1" for w in out.warnings)


def test_hints_to_router_layer_mapped_and_width_carried():
    board = route_bridge.board_to_router(_rotated_board())
    env = _route_hint(source_pins=["U1.2"], layer="bottom", width_mm=0.4,
                      waypoints=[[1, 2]])
    out = route_bridge.hints_to_router([env], board)
    assert out.hints.net_hints[0].preferred_layer == "B.Cu"
    assert out.trace_width_mm == pytest.approx(0.4)


def test_hints_to_router_ignores_non_route_hint_kind():
    board = route_bridge.board_to_router(_rotated_board())
    bad = _route_hint(source_pins=["U1.2"])
    bad["kind"] = "2d_arrow"
    out = route_bridge.hints_to_router([bad], board)
    assert out.hints.net_hints == []
    assert any("expected 'pcb_route_hint'" in w["message"] for w in out.warnings)


# ---------------------------------------------------------------------------
# select_hints — selection semantics
# ---------------------------------------------------------------------------


def test_select_hints_open_only_by_default():
    open_h = _route_hint(_id="a", source_pins=["U1.2"])
    open_h["lifecycle"] = "open"
    resolved_h = _route_hint(_id="b", source_pins=["R1.1"])
    resolved_h["lifecycle"] = "resolved"

    sel = route_bridge.select_hints([open_h, resolved_h])
    assert [e["id"] for e in sel] == ["a"]

    sel_all = route_bridge.select_hints([open_h, resolved_h], {"mode": "all"})
    assert {e["id"] for e in sel_all} == {"a", "b"}


def test_select_hints_explicit_ids_order_preserved():
    a = _route_hint(_id="a"); b = _route_hint(_id="b"); c = _route_hint(_id="c")
    for e in (a, b, c):
        e["lifecycle"] = "resolved"   # ids mode ignores lifecycle
    sel = route_bridge.select_hints([a, b, c], {"mode": "ids", "ids": ["c", "a"]})
    assert [e["id"] for e in sel] == ["c", "a"]
    # A bare list is treated as an id selection.
    sel2 = route_bridge.select_hints([a, b, c], ["b"])
    assert [e["id"] for e in sel2] == ["b"]


def test_select_hints_by_net():
    a = _route_hint(_id="a", net_names=["SIG"])
    b = _route_hint(_id="b", net_names=["GND"])
    for e in (a, b):
        e["lifecycle"] = "resolved"
    sel = route_bridge.select_hints([a, b], {"mode": "net", "net": "SIG"})
    assert [e["id"] for e in sel] == ["a"]


# ---------------------------------------------------------------------------
# route() method — end-to-end through the bridge
# ---------------------------------------------------------------------------


def _call(method: str, params: dict) -> dict:
    resp = handle_request({"id": "r1", "method": method, "params": params})
    assert resp is not None and resp["id"] == "r1"
    return resp


def _routable_board() -> dict:
    """Two 2-pad parts on net N1, close together — trivially routable."""
    return {
        "version": 1, "name": "Mini", "width_mm": 20, "height_mm": 20,
        "components": [
            {"ref": "R1", "footprint": "R", "x_mm": 5, "y_mm": 10,
             "rotation_deg": 0, "layer": "top",
             "pins": [{"number": "1", "x_mm": 0, "y_mm": 0},
                      {"number": "2", "x_mm": 1.0, "y_mm": 0}]},
            {"ref": "R2", "footprint": "R", "x_mm": 12, "y_mm": 10,
             "rotation_deg": 0, "layer": "top",
             "pins": [{"number": "1", "x_mm": 0, "y_mm": 0},
                      {"number": "2", "x_mm": 1.0, "y_mm": 0}]},
        ],
        "nets": [{"name": "N1", "pins": ["R1.2", "R2.1"]}],
    }


def test_route_method_canonical_board_no_hints():
    resp = _call("route", {"board": _routable_board()})
    assert resp["ok"] is True, resp
    r = resp["result"]
    assert "success" in r and "routes" in r and "unrouted" in r
    # This simple 1-net board should route cleanly.
    assert r["success"] is True
    assert any(rt["net"] == "N1" for rt in r["routes"])


def test_route_method_canonical_with_hint_and_warnings():
    board = _routable_board()
    hint = _route_hint(source_pins=["R1.2"], dest_pins=["R2.1"],
                       waypoints=[[6.0, 10.0], [11.0, 10.0]])
    # A second hint with a bad ref to prove warnings propagate through route().
    bad = _route_hint(_id="ann_bad", source_pins=["ZZ.9"])
    resp = _call("route", {"board": board, "route_hints": [hint, bad]})
    assert resp["ok"] is True, resp
    r = resp["result"]
    assert "warnings" in r
    assert any("ZZ.9" in w["message"] for w in r["warnings"])
    assert "ann1" in r["selected_hint_ids"] and "ann_bad" in r["selected_hint_ids"]


def test_route_method_canonical_via_yaml():
    import yaml
    resp = _call("route", {"yaml": yaml.safe_dump(_routable_board())})
    assert resp["ok"] is True
    assert resp["result"]["success"] is True


def test_route_method_native_path_still_works():
    """Grandchild-1 native pad-list shape must keep routing (back-compat)."""
    native = {
        "width": 20, "height": 20,
        "pads": [
            {"component": "R1", "number": "2", "net": "N1", "x": 6, "y": 10,
             "size": [1, 1]},
            {"component": "R2", "number": "1", "net": "N1", "x": 13, "y": 10,
             "size": [1, 1]},
        ],
    }
    resp = _call("route", {"board": native})
    assert resp["ok"] is True, resp
    assert resp["result"]["success"] is True
    # Native path emits no bridge warnings/selection keys.
    assert "warnings" not in resp["result"]


def test_route_method_bad_canonical_board_structured_error():
    resp = _call("route", {"board": {"components": []}})
    assert resp["ok"] is False
    assert resp["error"]["kind"] == "parse"
