"""A pad with no routable copper is excluded from its net, not fatal to the board.

An NPTH mounting hole is drilled and never plated, so it carries no copper — that
is what an NPTH IS, and nothing here changes it. But a board may legitimately
place one ON a net (a chassis-ground M3 hole; the HITL bench's row 5 stages
exactly that, `MH5.1` on `R5_A`), and the router's projection used to refuse the
WHOLE board over it: one unroutable member on ONE net and no net anywhere could
be routed.

The oracles below come from the bench's own per-row answers, not from the
router's output:

  * row 5 owes a top<->bottom join that only a plated via can deliver, so
    `R5_A`'s routable members are exactly `TP5T.1` and `TP5B.1`;
  * row 16 has a 0.4 mm trace already joining `TP16A`-`TP16B`, so a candidate
    on that net is `net_copper`-wide at 0.40, not the 0.25 mm design rule.

Row 16 is on the far side of the board from row 5 and shares nothing with it,
which is the point: the exclusion has to be local to row 5's net.
"""

from __future__ import annotations

from pathlib import Path

import pytest
import yaml

from pcb_worker import compile_board, route_bridge
from pcb_worker.methods import handle_request

HITL_BENCH = Path(__file__).resolve().parent / "testdata" / "hitl_bench.yaml"


def _bench() -> dict:
    return yaml.safe_load(HITL_BENCH.read_text(encoding="utf-8"))


def _compiled(spec: dict):
    compiled = compile_board.compile_board(
        spec, requested_outputs=compile_board.V1_ROUTING_OUTPUTS)
    board = getattr(compiled, "board", None)
    assert board is not None, getattr(compiled, "diagnostics", compiled)
    return board


def _route(params: dict) -> dict:
    resp = handle_request({"id": "npth", "method": "route", "params": params})
    assert resp is not None and resp["id"] == "npth"
    return resp


def _pad_refs(net) -> list[str]:
    return sorted(f"{p.component}.{p.number}" for p in net.pads)


def test_the_projection_drops_the_hole_from_its_net_and_keeps_every_net():
    """`MH5.1` leaves `R5_A`; the other 24 nets and `R5_A`'s two real lands stay.

    The net itself is KEPT (with one fewer member) rather than deleted: the
    engine already skips any net with fewer than two pads, while deleting it
    would make an explicit scope naming `R5_A` read "not a net of this board".
    """
    warnings: list[dict] = []
    board = route_bridge.resolved_board_to_router(_compiled(_bench()), warnings)

    assert _pad_refs(board.nets["R5_A"]) == ["TP5B.1", "TP5T.1"]
    assert len(board.nets) == 25, sorted(board.nets)
    assert all("MH5" not in ref
               for net in board.nets.values() for ref in _pad_refs(net))

    named = [w["message"] for w in warnings
             if "R5_A" in w["message"] and "MH5.1" in w["message"]]
    assert len(named) == 1, warnings
    assert "excluded" in named[0]

    # The hole is still a HOLE: dropping it from the net must not drop it from
    # the obstacle set, or copper would route straight through a 3.2 mm bore.
    holes = [o for o in board.obstacles
             if o.type == "npth_pad"
             and o.position == pytest.approx((25.0, 56.0))]
    assert len(holes) == 1, [(o.type, o.position) for o in board.obstacles]
    assert holes[0].radius == pytest.approx(1.6)


def test_the_warnings_sink_is_optional():
    """Every caller that does not want the exclusions still gets a Board."""
    assert route_bridge.resolved_board_to_router(_compiled(_bench())) is not None


def test_a_span_on_row_16_routes_while_the_hole_sits_on_row_5s_net():
    """The whole bug, end to end: propose TP16C.1 -> TP16D.1 on `R16_A`.

    This call used to come back `ok: False`, kind `unsupported_geometry`, over a
    mounting hole 180 mm away on a net the run never touches.
    """
    resp = _route({"board": _bench(), "scope": {"tasks": [
        {"task_id": "row16", "net": "R16_A",
         "endpoints": ["TP16C.1", "TP16D.1"]}]}})
    assert resp["ok"] is True, resp.get("error")
    result = resp["result"]

    routes = [r for r in result.get("routes") or [] if r.get("net") == "R16_A"]
    assert len(routes) == 1, result.get("routes")
    width = routes[0]["effective_routing_rules"]["trace_width_mm"]
    assert width["value"] == pytest.approx(0.40)
    assert width["source"] == "net_copper"

    # The exclusion rides the SAME reply, named — a silent drop would let a
    # human believe R5_A was considered and found already routed.
    messages = [w.get("message", "") for w in result.get("warnings") or []]
    assert any("R5_A" in m and "MH5.1" in m for m in messages), messages
