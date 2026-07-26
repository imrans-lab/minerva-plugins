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
from pcb_worker.methods import _routes_to_vias, handle_request


def _call(method: str, params: dict) -> dict:
    resp = handle_request({"id": "r1", "method": method, "params": params})
    assert resp is not None and resp["id"] == "r1"
    return resp


def _detailed_hint(_id: str = "ann1", **kp_overrides) -> dict:
    kp = {
        "hint_type": "single_trace",
        "detail_level": "detailed",
        "layer": "F.Cu",
        # ROUND E: pin refs name the FOOTPRINT's pad numbers now that route()
        # routes the compiled IR — TH_TestPoint's single pad is "1".
        "source_pins": ["U1.1"],
        "dest_pins": ["J1.1"],
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
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [
            {"ref": "U1", "footprint": "TH_TestPoint", "x_mm": 10, "y_mm": 20,
             "rotation_deg": 0, "layer": "top",
             "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0,
                       "drill_mm": 0.8, "annulus_diameter_mm": 1.6}]},
            {"ref": "J1", "footprint": "TH_TestPoint", "x_mm": 50, "y_mm": 20,
             "rotation_deg": 0, "layer": "top",
             "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0,
                       "drill_mm": 0.8, "annulus_diameter_mm": 1.6}]},
            {"ref": "A1", "footprint": "TH_TestPoint", "x_mm": 30, "y_mm": 5,
             "rotation_deg": 0, "layer": "top",
             "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0,
                       "drill_mm": 0.8, "annulus_diameter_mm": 1.6}]},
            {"ref": "A2", "footprint": "TH_TestPoint", "x_mm": 30, "y_mm": 35,
             "rotation_deg": 0, "layer": "top",
             "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0,
                       "drill_mm": 0.8, "annulus_diameter_mm": 1.6}]},
        ],
        "nets": [
            {"name": "SIG", "pins": ["U1.1", "J1.1"]},
            {"name": "EXIST", "pins": ["A1.1", "A2.1"]},
        ],
        "traces": existing_traces or [],
    }


_CROSSING_TRACE = [{"net": "EXIST", "layer": "top", "width_mm": 0.25,
                    "points": [{"x_mm": 30, "y_mm": 5}, {"x_mm": 30, "y_mm": 35}]}]


def _clean_board() -> dict:
    """U1<->J1 (net SIG) ONLY — no second multi-pad net.

    HISTORY, because this docstring used to document a defect and the defect is
    gone. It read: route() auto-routes EVERY net with >= 2 pads, not just the
    ones a hint targets, so _board()'s EXIST net (A1/A2) would itself get routed
    and could produce its own crossing, contaminating a "nothing to report"
    fixture — therefore a clean-DRC fixture must have only one net. That was a
    true workaround for docket 019f6cf2b5f4 / 019f80a80123, and a working repro
    of it.

    FIXED: a hinted run is now scoped to the nets its hints name
    (pcb/docs/routing.md, "Run scope"). Re-measured on this board: _board() with
    the same detailed hint returns routes for SIG alone, drc clean, geometric
    clean. So the second net can no longer contaminate anything, and this
    fixture is now a simplification rather than a workaround — kept because a
    one-net board is the smallest thing that makes the point, not because a
    two-net one would break. The scoping itself is pinned by
    tests/test_route_scope.py, which is where a regression would show up first.
    """
    return {
        "version": 1,
        "name": "drc-at-propose-clean",
        "width_mm": 60,
        "height_mm": 40,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [
            {"ref": "U1", "footprint": "TH_TestPoint", "x_mm": 10, "y_mm": 20,
             "rotation_deg": 0, "layer": "top",
             "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0,
                       "drill_mm": 0.8, "annulus_diameter_mm": 1.6}]},
            {"ref": "J1", "footprint": "TH_TestPoint", "x_mm": 50, "y_mm": 20,
             "rotation_deg": 0, "layer": "top",
             "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0,
                       "drill_mm": 0.8, "annulus_diameter_mm": 1.6}]},
        ],
        "nets": [{"name": "SIG", "pins": ["U1.1", "J1.1"]}],
        "traces": [],
    }


# ---------------------------------------------------------------------------
# Dirty fixture: the routed SIG segment crosses the existing EXIST trace.
# ---------------------------------------------------------------------------


def test_the_router_routes_around_accepted_foreign_copper_instead_of_over_it():
    """T7, docket 019f70ebc9ed — driven through ``route()``, the real entry point.

    ROUND E (019f783860c8, Codex gap E) made this board unroutable ON PURPOSE: the
    grid was given pads and holes only, so accepted copper was INVISIBLE and a
    fresh proposal could be laid straight through a trace the user had already
    accepted. Failing closed was right while the grid could not model it — but it
    also meant the FIRST accepted proposal ended the incremental workflow.

    The fixture is the one that made the old failure visible: an EXIST trace walled
    across x=30 from y=5 to y=35, and SIG needing to get from U1(10,20) to
    J1(50,20) — a straight line right through it. Two things must now hold, and
    only the SECOND of them is about the wall being seen at all:

      * the board routes (it no longer fails closed), and
      * NO proposed segment crosses the wall. If existing copper were still
        invisible the engine would take the straight line, which is both the
        cheapest path and a short.

    Deliberately NOT driven with the detailed hint the DRC tests use: a detailed
    hint materializes AS DRAWN, bypassing the grid entirely, so it could not tell
    a seen wall from an unseen one.

    THE GEOMETRIC CLAIM IS NOW MADE (019f9bd5f2f2). This docstring used to carry a
    caveat that "routes around" did NOT mean "geometrically clean", because
    `pathfinder._simplify_path` collapsed the detour into a chord back through
    A2's land — 18 blocked probe points on the emitted segment, and a
    `gc2_copper_clearance` violation to show for it. The simplifier now re-checks
    every chord against the grid before dropping a point, so the caveat is gone
    and the assertion it was standing in for is made directly below. The
    corridor-level proof (probe the grid along every emitted segment) is
    `test_no_emitted_segment_crosses_a_cell_the_routing_grid_blocked`."""
    resp = _call("route", {"board": _board(_CROSSING_TRACE)})
    assert resp["ok"] is True, resp

    sig = [r for r in resp["result"]["routes"] if r["net"] == "SIG"]
    assert sig, resp["result"]
    wall_a, wall_b = (30.0, 5.0), (30.0, 35.0)
    for seg in sig[0]["segments"]:
        start = (seg["start"][0], seg["start"][1])
        end = (seg["end"][0], seg["end"][1])
        assert not drc_module._segments_intersect(start, end, wall_a, wall_b), \
            f"proposed SIG segment {start}->{end} crosses the accepted EXIST trace"
    # And the connectivity kernel agrees, over the same board: no crossing found.
    assert resp["result"]["drc_summary"]["clean"] is True, resp["result"]
    # The geometric overlay — the real short detector, not the centerline-only
    # connectivity kernel — agrees too. This is the assertion the pre-019f9bd5f2f2
    # caveat said could not honestly be made.
    assert resp["result"]["drc_geometric_summary"]["verdict"] == "clean", \
        resp["result"]["drc_geometric_summary"]


def _route_probing_the_real_grid(monkeypatch, board: dict) -> tuple[dict, list[str]]:
    """Drive ``route()`` and probe the grid IT ACTUALLY USED along every segment
    it emitted. Returns (result payload, list of human-readable violations).

    The grid is captured rather than rebuilt: a re-derived grid is a second copy
    of route_board's construction (resolution, clearance, trace_width, origin,
    which copper got marked and in what order), and a probe against a grid that
    merely resembles the router's own proves nothing about the router. Patching
    the name ``agent_router.router.RoutingGrid`` catches it at the one place
    route_board builds it (router.py:736).

    Probing is at ``PathSegment.points`` resolution — the SAME sampling A* and
    `_segment_clear` use — so "the grid blocks this point" means exactly what it
    means inside the pathfinder.
    """
    from agent_router import router as router_mod
    from agent_router.grid import RoutingGrid
    from agent_router.pathfinder import PathSegment

    captured: list[RoutingGrid] = []

    class _RecordingGrid(RoutingGrid):
        def __post_init__(self):
            super().__post_init__()
            captured.append(self)

    monkeypatch.setattr(router_mod, "RoutingGrid", _RecordingGrid)

    resp = _call("route", {"board": board})
    assert resp["ok"] is True, resp
    assert captured, "route() never built a RoutingGrid — the probe saw nothing"
    grid = captured[-1]

    problems: list[str] = []
    for route in resp["result"]["routes"]:
        net = route["net"]
        for seg in route["segments"]:
            start = (seg["start"][0], seg["start"][1])
            end = (seg["end"][0], seg["end"][1])
            layer = seg["layer"]
            blocked = [pt for pt in PathSegment(start=start, end=end,
                                                layer=layer).points
                       if not grid.can_route_through(pt[0], pt[1], net, layer)]
            if blocked:
                problems.append(
                    f"{net} segment {start}->{end} on {layer}: "
                    f"{len(blocked)} blocked probe point(s), "
                    f"first {blocked[0]}, last {blocked[-1]}")
    return resp["result"], problems


def test_no_emitted_segment_crosses_a_cell_the_routing_grid_blocked(monkeypatch):
    """THE decisive test for 019f9bd5f2f2: a simplified path must stay inside the
    corridor the unsimplified path occupied.

    A* was never the problem — it finds a legal detour around the EXIST wall.
    `_simplify_path` then measured each candidate's deviation against the last
    KEPT point, so error accumulated monotonically along the detour and the whole
    curve collapsed into one chord straight across A2's land. This test states the
    property that failed, in the terms the router itself uses: take the grid
    route() routed against, walk every segment route() emitted, and assert the
    grid would have permitted every point of it.

    It is deliberately NOT a test of `_simplify_path` in isolation. This campaign
    has been burned by tests that exercised a helper directly and never its call
    sites; the bug lives in the gap between "A* proved these cells clear" and
    "these are the segments we shipped", and only the real entry point spans it.

    MEASURED BEFORE THE FIX: 18 blocked probe points on the first of two emitted
    segments, running from (29.28, 34.83) to (30.62, 35.86) — straight through
    A2's pad at (30, 35). AFTER: three segments, zero blocked points.
    """
    result, problems = _route_probing_the_real_grid(
        monkeypatch, _board(_CROSSING_TRACE))

    assert [r["net"] for r in result["routes"]] == ["SIG"], result
    assert result["routes"][0]["segments"], "no segments to probe — vacuous pass"
    assert problems == [], (
        "the router emitted copper through cells its own grid blocked:\n  "
        + "\n  ".join(problems))


def test_the_detour_that_exposed_the_bug_is_geometrically_clean(monkeypatch):
    """The same detour, judged by the geometric DRC overlay rather than by the
    grid — the two are independent verdicts and 019f9bd5f2f2 broke both.

    `drc_geometric` reported `gc2_copper_clearance` violations of -0.20 to
    -0.64mm on this board. Grid probes and the geometric overlay can disagree
    (the grid is quantised and models a keepout, the overlay measures real copper
    against fab rules), so a fix that satisfied only one of them would be half a
    fix. Both are asserted, in separate tests, on purpose.
    """
    result, _ = _route_probing_the_real_grid(monkeypatch, _board(_CROSSING_TRACE))
    summary = result["drc_geometric_summary"]
    assert summary["ok"] is True, summary
    assert summary["verdict"] == "clean", summary
    assert not [f for f in summary["findings"]
                if f.get("rule") == "gc2_copper_clearance"], summary


def test_a_net_the_accepted_copper_already_joins_is_not_proposed_again():
    """The other half of T7 (019f70ebc9ed), same fixture, same entry point.

    EXIST's two pads (A1, A2) are the endpoints of the accepted trace — that net
    is DONE. Same-net copper is already-connected, not an obstacle, so the router
    must propose nothing for it. Treating it as an obstacle would make the net
    unroutable; ignoring it entirely (the pre-T7 behaviour, had the board reached
    the router at all) would re-propose a trace the board already carries, laid
    straight on top of its own copper.
    """
    resp = _call("route", {"board": _board(_CROSSING_TRACE)})
    assert resp["ok"] is True, resp
    assert [r["net"] for r in resp["result"]["routes"]] == ["SIG"], \
        "EXIST is already joined by accepted copper and must not be re-routed"
    assert not resp["result"].get("unrouted"), resp["result"]


def test_drc_attach_flags_a_proposal_crossing_an_existing_trace():
    """The crossing check itself, at the layer that still sees existing copper.

    ``_attach_route_drc`` is what route() calls once it has proposals; it is a pure
    function of (canonical board, routes), so the pre-existing-trace scenario is
    exercised here verbatim even though route() now refuses such a board."""
    from pcb_worker.methods import _attach_route_drc

    board = _board(_CROSSING_TRACE)
    # The proposal route() would have produced: a straight SIG segment at y=20,
    # crossing the existing EXIST trace at (30, 20) on the same layer.
    payload = {"routes": [{"net": "SIG", "segments": [
        {"layer": "top", "width_mm": 0.25, "start": [10, 20], "end": [50, 20]}]}]}
    _attach_route_drc(payload, board)

    route_drc = payload["routes"][0]["drc"]
    # HONEST LABEL (019f958aa6db): route DRC is CONNECTIVITY-scoped, never geometric.
    assert route_drc["scope"] == "connectivity"
    assert route_drc["clean"] is False
    assert any(v["type"] == "crossing" for v in route_drc["violations"])
    crossing = [v for v in route_drc["violations"] if v["type"] == "crossing"][0]
    assert sorted(crossing["nets"]) == ["EXIST", "SIG"]
    assert crossing["layer"] == "top"

    summary = payload["drc_summary"]
    assert summary["scope"] == "connectivity"
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
    # HONEST LABEL (019f958aa6db): a clean connectivity result is scope-tagged so
    # the UI renders "Connectivity clean", never a misleading bare "DRC clean".
    assert sig[0]["drc"] == {"scope": "connectivity", "clean": True, "violations": []}
    assert r["drc_summary"] == {"scope": "connectivity", "clean": True,
                                "violation_count": 0}


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
    assert sig[0]["drc"]["scope"] == "connectivity"
    assert sig[0]["drc"]["clean"] is None
    assert "synthetic DRC engine fault" in sig[0]["drc"]["error"]

    assert r["drc_summary"]["scope"] == "connectivity"
    assert r["drc_summary"]["clean"] is None
    assert "synthetic DRC engine fault" in r["drc_summary"]["error"]


# ---------------------------------------------------------------------------
# Native pad-list path: no canonical board, DRC is skipped entirely.
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# _routes_to_vias (docket 019... U1: canonical via schema) — internal-only
# DRC-harvesting shape, NOT the public route() JSON contract (routes[].vias
# stays [[x, y], ...] there — see _serialize_routing_result / test above's
# fixtures, none of which produce vias). agent_router.Route.vias is
# positional-only, so from_layer/to_layer are always the top<->bottom default
# here (a 2-layer board via always spans the full board).
# ---------------------------------------------------------------------------


def test_routes_to_vias_attaches_default_layer_span():
    routes = [{"net": "SIG", "segments": [], "vias": [[12.5, 7.25], (1.0, 2.0)]}]
    vias = _routes_to_vias(routes)
    assert vias == [
        {"x_mm": 12.5, "y_mm": 7.25, "from_layer": "top", "to_layer": "bottom"},
        {"x_mm": 1.0, "y_mm": 2.0, "from_layer": "top", "to_layer": "bottom"},
    ]


def test_routes_to_vias_ignores_malformed_entries():
    routes = [{"net": "SIG", "vias": [[1.0], "bad", None]}, "not-a-dict", {}]
    assert _routes_to_vias(routes) == []


def test_native_pad_list_shape_is_rejected_with_a_structured_parse_error():
    """The flat "pads" list shape (grandchild-1, _board_from_native) was
    retired: it had no compile, no IR, and no DRC of any kind. route() must
    now fail closed with a message that names the canonical replacement,
    not silently accept the shape (or fall through to the canonical loader
    and fail with some unrelated, unnamed message)."""
    resp = _call("route", {"board": {
        "pads": [
            {"component": "U1", "number": "1", "net": "SIG", "x": 0, "y": 0, "size": [1, 1]},
            {"component": "U2", "number": "1", "net": "SIG", "x": 10, "y": 0, "size": [1, 1]},
        ],
        "width": 20, "height": 20,
    }})
    assert resp["ok"] is False, resp
    assert resp["error"]["kind"] == "parse"
    message = resp["error"]["message"]
    assert "pads" in message
    assert "components" in message
    assert "yaml" in message


def test_a_malformed_board_is_not_misdiagnosed_as_the_retired_pads_shape():
    """The retirement guard must not become a catch-all. An input that never
    used the pads shape has to keep getting load_board's accurate message —
    telling someone who sent {} that "the pads shape was retired" sends them
    looking for a pads key they never wrote.

    This is a real regression that was caught in review: the first cut gated
    on "is this input not canonical?", which is true of every malformed input,
    not just the retired one."""
    # kind varies HONESTLY with how far the input gets: the first three do not
    # load at all ("parse"), while a board dict with neither key loads and then
    # fails the schema ("compile", carrying diagnostics). Both are accurate;
    # what none of them may say is that a pads shape was retired.
    for bad, kind in (({}, "parse"),
                      ({"board": "not-a-dict"}, "parse"),
                      ({"yaml": 123}, "parse"),
                      ({"board": {"nets": [], "traces": []}}, "compile")):
        resp = _call("route", bad)
        assert resp["ok"] is False, (bad, resp)
        assert resp["error"]["kind"] == kind, (bad, resp)
        assert "retired" not in resp["error"]["message"], (bad, resp)


# ---------------------------------------------------------------------------
# GEOMETRIC DRC-at-propose (docket 019f952b99f2, bug 019f80b5124d) — the copper
# complement attached ALONGSIDE the connectivity result above. The connectivity
# payloads asserted earlier in this file are unchanged: this surface ADDS
# `drc_geometric` / `drc_geometric_summary`, it replaces nothing.
# ---------------------------------------------------------------------------


def test_route_attaches_both_scopes_and_they_are_distinguishable():
    resp = _call("route", {"board": _clean_board(),
                           "route_hints": [_detailed_hint()],
                           "selection": {"mode": "open"}})
    assert resp["ok"] is True, resp
    r = resp["result"]
    sig = [rt for rt in r["routes"] if rt["net"] == "SIG"][0]

    # Two answers to two different questions, never one blurred "DRC clean".
    assert sig["drc"]["scope"] == "connectivity"
    assert sig["drc_geometric"]["scope"] == "geometric_candidate"
    assert sig["drc_geometric"]["verifies_geometry"] is True
    assert sig["drc_geometric"]["verdict"] == "clean"
    # Deliberately NOT spelled `clean` — a consumer cannot confuse the geometric
    # verdict with the connectivity boolean, nor read "did not run" as "passed".
    assert "clean" not in sig["drc_geometric"]

    summary = r["drc_geometric_summary"]
    assert summary["scope"] == "geometric_candidate"
    assert summary["verdict"] == "clean"
    assert summary["per_candidate"]["route[0]"]["verdict"] == "clean"
    # Staleness detection: the candidate verdict names the source it was computed
    # against (the finding contract already carries source_digest).
    assert summary["source_digest"]
    assert summary["board_id"]


def test_geometric_drc_flags_a_proposal_running_over_a_foreign_pad():
    """The bug class of 019f80b5124d, on route()'s own path: a proposal whose
    waypoint lands on a different-net pad. Connectivity catches this particular
    one because the waypoint is a VERTEX; the geometric surface catches it as what
    it physically is — copper overlapping copper, with a measured margin."""
    board = _board()
    board["components"][2]["x_mm"] = 30
    board["components"][2]["y_mm"] = 20

    resp = _call("route", {"board": board,
                           "route_hints": [_detailed_hint(waypoints=[[30, 20]])],
                           "selection": {"mode": "open"}})
    assert resp["ok"] is True, resp
    r = resp["result"]
    sig = [rt for rt in r["routes"] if rt["net"] == "SIG"][0]

    assert sig["drc_geometric"]["verdict"] == "violations"
    shorts = [v for v in sig["drc_geometric"]["violations"]
              if any(p.get("ref") == "A1" for p in v.get("participants") or [])]
    assert shorts, sig["drc_geometric"]["violations"]
    short = shorts[0]
    assert short["type"] == "gc2_copper_clearance"
    assert short["measured_mm"] < short["required_mm"]
    assert {p.get("net_name") for p in short["participants"]} == {"SIG", "EXIST"}
    # Attributed to the specific proposal a canvas is drawing.
    assert any(s["candidate_id"] == "route[0]" for s in short["subjects"])


def test_geometric_drc_failure_is_indeterminate_never_clean(monkeypatch):
    """A geometric fault must not fail the route call, and must not silently
    become a pass. Case (c) of the honesty contract."""
    from pcb_worker import ir_candidates

    def _boom(*_args, **_kwargs):
        raise RuntimeError("synthetic geometric kernel fault")

    monkeypatch.setattr(ir_candidates, "run_geometric_drc", _boom)

    resp = _call("route", {"board": _clean_board(),
                           "route_hints": [_detailed_hint()],
                           "selection": {"mode": "open"}})
    assert resp["ok"] is True, resp          # routes still return
    r = resp["result"]
    sig = [rt for rt in r["routes"] if rt["net"] == "SIG"][0]

    assert sig["drc_geometric"]["verdict"] == "indeterminate"
    assert sig["drc_geometric"]["verifies_geometry"] is False
    assert "violations" not in sig["drc_geometric"]
    assert "clean" not in sig["drc_geometric"]
    assert "synthetic geometric kernel fault" in \
        sig["drc_geometric"]["error"]["message"]

    summary = r["drc_geometric_summary"]
    assert summary["ok"] is False
    assert summary["verdict"] == "indeterminate"
    for forbidden in ("findings", "counts", "per_candidate", "baseline"):
        assert forbidden not in summary
    # The CONNECTIVITY half is unaffected — one surface failing must not take the
    # other's honest answer down with it.
    assert sig["drc"]["scope"] == "connectivity"
    assert sig["drc"]["clean"] is True


def test_native_pad_list_shape_is_rejected_before_any_geometric_overlay():
    """Same retirement as test_native_pad_list_shape_is_rejected_with_a_structured_parse_error,
    pinned again here: the flat "pads" list never reaches compile, so there is
    nothing to overlay geometric DRC onto — route() must reject it outright,
    not return a routeless-looking success with no drc_geometric keys."""
    resp = _call("route", {"board": {
        "pads": [
            {"component": "U1", "number": "1", "net": "SIG", "x": 0, "y": 0, "size": [1, 1]},
            {"component": "U2", "number": "1", "net": "SIG", "x": 10, "y": 0, "size": [1, 1]},
        ],
        "width": 20, "height": 20,
    }})
    assert resp["ok"] is False, resp
    assert resp["error"]["kind"] == "parse"


def test_board_with_both_components_and_stray_pads_key_routes_as_canonical():
    """The discriminator footgun: before this round, ANY top-level "pads" key
    vetoed "components" and silently dropped a structurally-canonical board
    onto the unsafe native branch. Canonical boards never legitimately carry
    a top-level "pads" key (canonical pads live under each component's
    "pins", see docs/board-yaml.md), so the retirement guard fires only when
    "pads" is present AND "components" is absent — a stray "pads" key is
    inert. This pins that decision: the board still routes on the CANONICAL
    path (compiled, DRC-attached), it is not rejected and not mis-routed."""
    board = _clean_board()
    board["pads"] = ["leftover-garbage"]
    resp = _call("route", {"board": board,
                           "route_hints": [_detailed_hint()],
                           "selection": {"mode": "open"}})
    assert resp["ok"] is True, resp
    r = resp["result"]
    sig = [rt for rt in r["routes"] if rt["net"] == "SIG"][0]
    # Canonical-only keys prove the canonical (compiled + DRC) branch ran.
    assert sig["drc"]["scope"] == "connectivity"
    assert sig["drc_geometric"]["scope"] == "geometric_candidate"


def test_geometric_candidate_width_is_the_width_the_engine_routed_at():
    """The overlay models the width the run ACTUALLY used, read from the engine's
    own signature rather than a duplicated literal — under-stating candidate
    copper would be a route to a false clean."""
    from pcb_worker.methods import _engine_default_trace_width_mm
    from agent_router.router import route_board
    import inspect

    assert _engine_default_trace_width_mm() == \
        inspect.signature(route_board).parameters["trace_width"].default


def test_an_unchecked_empty_route_is_recorded_in_the_summary_not_silently_clean():
    """A route with no segments and no vias never reaches the overlay, so
    `per_candidate` would omit it entirely. The per-route reply already refuses
    to say "clean" about copper that does not exist; the SUMMARY must not stay
    silent either, or a caller reading only the summary sees an all-clean
    verdict with no sign that a route went unchecked. Silence about copper that
    was not checked is the same dishonesty as a false clean."""
    from pcb_worker import compile_board
    from pcb_worker.methods import _attach_route_geometric_drc, _compile_or_fail

    compiled = _compile_or_fail(
        _clean_board(), requested_outputs=compile_board.V1_ROUTING_OUTPUTS)
    payload = {"routes": [{"net": "SIG", "segments": [], "vias": []}]}
    _attach_route_geometric_drc(payload, compiled.board, trace_width_mm=0.25)

    route = payload["routes"][0]
    assert route["drc_geometric"]["verdict"] == "indeterminate"
    assert route["drc_geometric"]["verifies_geometry"] is False
    assert "clean" not in route["drc_geometric"]

    entry = payload["drc_geometric_summary"]["per_candidate"]["route[0]"]
    assert entry["verdict"] == "indeterminate"
    assert entry["reason"]
