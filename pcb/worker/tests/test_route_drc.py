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

BASELINE PARTITION (docket 019f9cc386b6): every one of those payloads also
carries a "baseline" — the board's OWN pre-existing violations, from a second
kernel run over the board WITHOUT the proposal. `clean`/`violations`/
`violation_count` are therefore PROPOSAL-scoped: they answer "does accepting
this introduce a violation?", never "is the board dirty?". Same separation
ir_candidates.check_candidates gives the geometric surface, in connectivity's
own vocabulary. See the section at the bottom of this file.

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
    the name ``agent_router.router.RoutingGrid`` catches it where ``route_board``
    builds it (router.py:1051) — this helper is only ever driven through plain
    ``route()`` calls with no route_hints, so that is the site exercised here.
    The same patch would equally catch ``route_board_with_hints``'s build
    (router.py:1814), since both functions resolve the same module-global name
    at call time.

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
    # BASELINE PARTITION (019f9cc386b6): every payload now carries the board's own
    # pre-existing state alongside the proposal's. On a clean board both halves
    # are clean and empty, so the payloads stay assertable byte-for-byte.
    assert sig[0]["drc"] == {"scope": "connectivity", "clean": True,
                             "violations": [],
                             "baseline": {"clean": True, "violations": []}}
    # HITL-4 (docs/llm-ergonomics.md F2): the summary now ALSO answers the
    # completeness question — `clean` alone could not say "and no in-scope net
    # is missing its copper". Fully-routed clean board: complete, nothing
    # missing (and no `partial`/`indeterminate` key at all — absent-key when
    # empty). `approximate` is the census's standing centerline-basis honesty
    # label (DCR 019fd5fd9084).
    assert r["drc_summary"] == {
        "scope": "connectivity", "clean": True, "violation_count": 0,
        "complete": True, "missing_copper": [], "approximate": True,
        "baseline": {"clean": True, "violation_count": 0, "findings": []}}


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


# ---------------------------------------------------------------------------
# BASELINE PARTITION (docket 019f9cc386b6)
#
# `drc_summary` used to carry ONE flat count over base+proposal, so a board that
# was already dirty billed the proposal for violations that predated it. The
# GEOMETRIC surface had solved this (ir_candidates.check_candidates, key
# "baseline"); these tests pin the same separation for CONNECTIVITY — including
# that the two surfaces stay independent, which is the constraint the fix could
# most easily have broken.
# ---------------------------------------------------------------------------


# Two pre-existing SIG dangling endpoints (a stub whose ends touch no pad) and
# one pre-existing EXIST dangling endpoint. Authored so the EXIST trace ALSO
# runs across the SIG pad-to-pad line at (30, 20) — a detailed hint materializes
# that line verbatim, so the proposal introduces exactly one crossing on top of
# three violations it did not cause. That is the shape triage measured.
_DIRTY_BASELINE = [
    {"net": "SIG", "layer": "top", "width_mm": 0.25,
     "points": [{"x_mm": 20, "y_mm": 35}, {"x_mm": 26, "y_mm": 35}]},
    {"net": "EXIST", "layer": "top", "width_mm": 0.25,
     "points": [{"x_mm": 30, "y_mm": 5}, {"x_mm": 30, "y_mm": 25}]},
]

# The same dirty board MINUS the trace the proposal collides with: the board is
# still dirty, the proposal introduces nothing.
_DIRTY_BASELINE_NO_COLLISION = [_DIRTY_BASELINE[0]]


def _base_only_drc_findings(board: dict) -> list:
    """A SECOND, independent base-only connectivity run over the same board —
    compiled and projected exactly as ``methods._route`` does, but WITHOUT any
    proposal. This is the reference the reported baseline must equal; it is
    computed here from the board alone, never read back off the reply."""
    from pcb_worker import ir_connectivity
    from pcb_worker.compile_board import compile_board

    resolution = compile_board(board)
    return drc_module.run_drc(
        ir_connectivity.connectivity_board(resolution.board))["findings"]


def _propose(board: dict) -> dict:
    resp = _call("route", {"board": board, "route_hints": [_detailed_hint()],
                           "selection": {"mode": "open"}})
    assert resp["ok"] is True, resp
    return resp["result"]


def test_baseline_is_exactly_what_a_base_only_drc_run_produces():
    """THE HEADLINE. A board with pre-existing connectivity violations plus a
    proposal that introduces one more reports the two SEPARATELY, and the
    reported baseline is the IDENTICAL SET a base-only run produces — the same
    check triage ran against the geometric surface."""
    board = _board(_DIRTY_BASELINE)
    expected_baseline = _base_only_drc_findings(board)
    assert len(expected_baseline) == 3, expected_baseline  # fixture is really dirty

    summary = _propose(board)["drc_summary"]

    # IDENTICAL SETS — not merely the same count.
    assert summary["baseline"]["findings"] == expected_baseline
    assert summary["baseline"]["violation_count"] == 3
    assert summary["baseline"]["clean"] is False

    # ...and the proposal is billed for its ONE crossing, not for all four.
    assert summary["violation_count"] == 1, summary
    assert summary["clean"] is False


def test_a_proposal_that_introduces_nothing_is_not_blamed_for_a_dirty_board():
    """The regression proper: pre-019f9cc386b6 this reported clean:False with
    violation_count 2, all of it the board's own pre-existing state."""
    board = _board(_DIRTY_BASELINE_NO_COLLISION)
    assert len(_base_only_drc_findings(board)) == 2  # the board IS dirty

    summary = _propose(board)["drc_summary"]
    assert summary["clean"] is True, summary
    assert summary["violation_count"] == 0, summary
    # ...and the dirt is still reported, not hidden.
    assert summary["baseline"]["clean"] is False
    assert summary["baseline"]["violation_count"] == 2


def test_per_route_violations_exclude_that_nets_own_pre_existing_findings():
    """Triage measured "2 of the 3 violations attributed to the proposal
    actually predating it". Those two are the SIG dangling endpoints, which
    _finding_involves_net matches on the route's net just as readily as the
    crossing the proposal really did introduce — so the per-route payload, not
    only the summary, needed the partition."""
    result = _propose(_board(_DIRTY_BASELINE))
    sig = [rt for rt in result["routes"] if rt["net"] == "SIG"]
    assert len(sig) == 1
    drc_payload = sig[0]["drc"]

    assert [v["type"] for v in drc_payload["violations"]] == ["crossing"]
    assert drc_payload["clean"] is False
    # The two pre-existing SIG findings are reported, under baseline.
    assert [v["type"] for v in drc_payload["baseline"]["violations"]] == \
        ["dangling_endpoint", "dangling_endpoint"]
    assert drc_payload["baseline"]["clean"] is False
    # ...and are NOT double-counted as the proposal's.
    assert not any(v["type"] == "dangling_endpoint"
                   for v in drc_payload["violations"])


def test_a_dirty_connectivity_baseline_does_not_move_the_geometric_verdict():
    """Requirement: the two surfaces stay independent. This board's CONNECTIVITY
    baseline carries two violations while the proposal introduces no geometric
    violation — the geometric verdict must still read clean."""
    result = _propose(_board(_DIRTY_BASELINE_NO_COLLISION))
    assert result["drc_summary"]["baseline"]["violation_count"] == 2
    assert result["drc_geometric_summary"]["verdict"] == "clean", \
        result["drc_geometric_summary"]


def test_a_dirty_geometric_baseline_does_not_move_the_connectivity_verdict():
    """The converse direction. G1/G2 are two different-net pads 1.0 mm apart
    (1.6 mm lands, so their copper overlaps) with no traces at all: the GEOMETRIC
    baseline is dirty, the CONNECTIVITY baseline is empty — the connectivity
    payload must not inherit the geometric surface's dirt."""
    board = _clean_board()
    board["components"] += [
        {"ref": "G1", "footprint": "TH_TestPoint", "x_mm": 5, "y_mm": 35,
         "rotation_deg": 0, "layer": "top",
         "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0,
                   "drill_mm": 0.8, "annulus_diameter_mm": 1.6}]},
        {"ref": "G2", "footprint": "TH_TestPoint", "x_mm": 5, "y_mm": 36,
         "rotation_deg": 0, "layer": "top",
         "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0,
                   "drill_mm": 0.8, "annulus_diameter_mm": 1.6}]},
    ]
    board["nets"] += [{"name": "GEO_A", "pins": ["G1.1"]},
                      {"name": "GEO_B", "pins": ["G2.1"]}]

    result = _propose(board)
    geometric_baseline = result["drc_geometric_summary"]["baseline"]["findings"]
    assert len(geometric_baseline) == 3, geometric_baseline  # really geometrically dirty
    assert {f["type"] for f in geometric_baseline} == \
        {"gc2_copper_clearance", "gc6_hole_to_hole"}

    assert result["drc_summary"]["clean"] is True, result["drc_summary"]
    assert result["drc_summary"]["baseline"] == {
        "clean": True, "violation_count": 0, "findings": []}


# ---------------------------------------------------------------------------
# The three-way `clean` contract under the partition.
# ---------------------------------------------------------------------------


def test_engine_fault_reports_an_indeterminate_baseline_not_a_clean_one():
    """When the kernel faults, BOTH halves are undetermined. `clean` is null at
    every level, and the baseline carries NO violation_count/findings — a zero
    count under a failed check is exactly the silent degradation the geometric
    surface's indeterminate union refuses to emit."""
    from pcb_worker.methods import _attach_route_drc

    def _boom(_board):
        raise RuntimeError("synthetic DRC engine fault")

    payload = {"routes": [{"net": "SIG", "segments": [
        {"layer": "top", "width_mm": 0.25, "start": [10, 20], "end": [50, 20]}]}]}
    with pytest.MonkeyPatch.context() as mp:
        mp.setattr(drc_module, "run_drc", _boom)
        _attach_route_drc(payload, _board(_DIRTY_BASELINE))

    for level in (payload["drc_summary"], payload["routes"][0]["drc"]):
        assert level["clean"] is None
        assert "synthetic DRC engine fault" in level["error"]
        assert level["baseline"]["clean"] is None
        assert "synthetic DRC engine fault" in level["baseline"]["error"]
        assert "violation_count" not in level["baseline"]
        assert "findings" not in level["baseline"]
        assert "violations" not in level["baseline"]
    # ...and the SUMMARY's own count is absent too, for the same reason: a check
    # that did not run has no count, and 0 reads as "nothing wrong" to anything
    # that does not branch on clean is None first.
    assert "violation_count" not in payload["drc_summary"]


def test_an_uncomputable_baseline_makes_the_proposal_verdict_null_not_dirty():
    """If the BASE run faults while the post run succeeds, post findings exist
    but cannot be attributed. Reporting clean:False would bill the proposal for
    a partition we could not compute, and clean:True would launder it — the only
    honest answer is the three-way null."""
    from pcb_worker import drc as drc_mod
    from pcb_worker.methods import _attach_route_drc

    real_run_drc = drc_mod.run_drc
    calls = {"n": 0}

    def _base_only_boom(board):
        calls["n"] += 1
        if calls["n"] == 1:          # the base run is always made first
            raise RuntimeError("synthetic baseline fault")
        return real_run_drc(board)

    payload = {"routes": [{"net": "SIG", "segments": [
        {"layer": "top", "width_mm": 0.25, "start": [10, 20], "end": [50, 20]}]}]}
    with pytest.MonkeyPatch.context() as mp:
        mp.setattr(drc_mod, "run_drc", _base_only_boom)
        _attach_route_drc(payload, _board(_DIRTY_BASELINE))

    assert calls["n"] == 2, "the post run must still be attempted"
    summary = payload["drc_summary"]
    assert summary["clean"] is None, summary
    assert "synthetic baseline fault" in summary["error"]
    assert summary["baseline"]["clean"] is None
    assert "violation_count" not in summary
    assert payload["routes"][0]["drc"]["clean"] is None


# ---------------------------------------------------------------------------
# The partition primitive itself.
# ---------------------------------------------------------------------------


def test_the_connectivity_kernel_is_not_monotone_in_added_copper():
    """THE REASON the geometric surface's attribution mechanism cannot be reused
    here, proven by RUNNING the kernel rather than asserted in a comment.

    ir_candidates partitions by attribution and argues that equals a base-only
    run because candidate copper only ADDS geometric primitives, so no base
    finding can vanish. That argument is false for this kernel: _check_dangling
    computes per-net endpoint DEGREE over base and proposed segments TOGETHER, so
    a proposal continuing a stub from its loose end raises that endpoint's degree
    to 2 and the base finding disappears from the post run entirely.

    Under attribution the vanished finding would land in NEITHER partition and
    the board would silently look cleaner than it is. Re-running the base kernel
    is what keeps it reported."""
    from pcb_worker.methods import _drc_for_routes

    board = _clean_board()
    board["traces"] = [{"net": "SIG", "layer": "top", "width_mm": 0.25,
                        "points": [{"x_mm": 10, "y_mm": 20},
                                   {"x_mm": 30, "y_mm": 20}]}]  # stub, loose at (30,20)
    continuation = [{"net": "SIG", "segments": [
        {"layer": "top", "width_mm": 0.25, "start": [30, 20], "end": [50, 20]}]}]

    base = drc_module.run_drc(board)["findings"]
    post = _drc_for_routes(board, continuation)["findings"]

    assert [f["type"] for f in base] == ["dangling_endpoint"]
    assert base[0]["at"] == [30.0, 20.0]
    assert post == [], post          # the base finding VANISHED — non-monotone

    # And the partition still reports it, out of the base run, blaming nobody.
    from pcb_worker.ir_connectivity import partition_findings
    introduced, baseline = partition_findings(base, post)
    assert introduced == []
    assert baseline == base


def test_partition_keeps_a_baseline_finding_the_proposal_resolves():
    """The partition primitive's half of the case above: a base finding absent
    from the post run stays in `baseline` (the board has it TODAY) and never
    turns up as something the proposal introduced."""
    from pcb_worker.ir_connectivity import partition_findings

    resolved = {"type": "dangling_endpoint", "net": "SIG", "at": [20.0, 35.0]}
    still_there = {"type": "dangling_endpoint", "net": "EXIST", "at": [30.0, 25.0]}
    new = {"type": "crossing", "nets": ["EXIST", "SIG"], "layer": "top",
           "at": [30.0, 20.0]}

    introduced, baseline = partition_findings([resolved, still_there],
                                              [still_there, new])
    assert baseline == [resolved, still_there]
    assert introduced == [new]


def test_partition_is_a_multiset_difference_not_a_set_difference():
    """Two indistinguishable findings must not collapse: a board carrying one
    copy and a post run carrying two means the proposal introduced the second."""
    from pcb_worker.ir_connectivity import partition_findings

    finding = {"type": "dangling_endpoint", "net": "SIG", "at": [20.0, 35.0]}
    introduced, baseline = partition_findings([finding], [finding, dict(finding)])
    assert introduced == [finding]
    assert baseline == [finding]


def test_partition_identity_ignores_key_order():
    """Findings are compared by canonical serialization, so a dict authored with
    the same content in a different key order is the SAME finding — otherwise a
    pre-existing violation would be re-reported as introduced."""
    from pcb_worker.ir_connectivity import partition_findings

    a = {"type": "crossing", "nets": ["A", "B"], "layer": "top", "at": [1.0, 2.0]}
    b = {"at": [1.0, 2.0], "layer": "top", "nets": ["A", "B"], "type": "crossing"}
    introduced, _ = partition_findings([a], [b])
    assert introduced == []


# ---------------------------------------------------------------------------
# FAIL-OPEN REGRESSION (019f9cc386b6 cold review, severity 1)
# ---------------------------------------------------------------------------


def test_a_second_crossing_of_the_same_pair_and_layer_is_reported_not_cancelled():
    """The partition must not cancel a genuinely NEW short.

    drc._check_crossings used to dedupe by (net-pair, layer) ALONE, with no
    location. A board already carrying an EXIST/SIG crossing on `top` therefore
    produced a base finding BYTE-IDENTICAL to the one a proposal creates by
    shorting the same pair on the same layer somewhere else — so
    partition_findings cancelled the new short as pre-existing and the reply read
    `clean: true, violation_count: 0` on a board with a live short in it.
    PCBPanel._connectivity_status_suffix renders that as "Connectivity clean".

    The wall runs x=30 from y=5 to y=35. A pre-existing SIG stub crosses it at
    (30, 30); the proposed U1->J1 route crosses it again at (30, 20). Two shorts,
    same pair, same layer, different places — both must be visible, and the new
    one must be billed to the proposal."""
    board = _board([
        {"net": "EXIST", "layer": "top", "width_mm": 0.25,
         "points": [{"x_mm": 30, "y_mm": 5}, {"x_mm": 30, "y_mm": 35}]},
        {"net": "SIG", "layer": "top", "width_mm": 0.25,
         "points": [{"x_mm": 20, "y_mm": 30}, {"x_mm": 40, "y_mm": 30}]},
    ])

    base_crossings = [f for f in _base_only_drc_findings(board)
                      if f["type"] == "crossing"]
    assert [f["at"] for f in base_crossings] == [[30.0, 30.0]], base_crossings

    result = _propose(board)
    summary = result["drc_summary"]

    # THE PROPOSAL IS BILLED FOR ITS OWN SHORT.
    assert summary["clean"] is False, summary
    introduced_crossings = [f for f in _base_only_drc_findings(board)
                            if f["type"] == "crossing"]
    sig = [rt for rt in result["routes"] if rt["net"] == "SIG"][0]
    new = [v for v in sig["drc"]["violations"] if v["type"] == "crossing"]
    assert [v["at"] for v in new] == [[30.0, 20.0]], sig["drc"]

    # ...while the pre-existing one is still reported, at its OWN location.
    baseline_crossings = [f for f in summary["baseline"]["findings"]
                          if f["type"] == "crossing"]
    assert [f["at"] for f in baseline_crossings] == [[30.0, 30.0]]
    assert len(introduced_crossings) == 1  # the base run itself still sees one


def test_two_distinct_crossings_of_one_pair_on_one_layer_are_two_findings():
    """The kernel-level half of the fix: location is part of a crossing's
    identity, so two shorts are two findings and not one."""
    board = _clean_board()
    board["nets"].append({"name": "EXIST", "pins": []})
    board["traces"] = [
        {"net": "SIG", "layer": "top", "width_mm": 0.25,
         "points": [{"x_mm": 10, "y_mm": 10}, {"x_mm": 10, "y_mm": 30}]},
        {"net": "SIG", "layer": "top", "width_mm": 0.25,
         "points": [{"x_mm": 40, "y_mm": 10}, {"x_mm": 40, "y_mm": 30}]},
        {"net": "EXIST", "layer": "top", "width_mm": 0.25,
         "points": [{"x_mm": 5, "y_mm": 20}, {"x_mm": 50, "y_mm": 20}]},
    ]
    crossings = [f for f in drc_module.run_drc(board)["findings"]
                 if f["type"] == "crossing"]
    assert sorted(f["at"] for f in crossings) == [[10.0, 20.0], [40.0, 20.0]], crossings


def test_one_crossing_met_by_two_segments_of_a_polyline_stays_one_finding():
    """The rounding in the dedupe key is load-bearing in the other direction:
    a polyline whose two segments share the vertex that lands on a foreign trace
    must not report the same short twice."""
    board = _clean_board()
    board["nets"].append({"name": "EXIST", "pins": []})
    board["traces"] = [
        # Two segments meeting exactly at (20, 20), the crossing point.
        {"net": "SIG", "layer": "top", "width_mm": 0.25,
         "points": [{"x_mm": 10, "y_mm": 10}, {"x_mm": 20, "y_mm": 20},
                    {"x_mm": 30, "y_mm": 30}]},
        {"net": "EXIST", "layer": "top", "width_mm": 0.25,
         "points": [{"x_mm": 10, "y_mm": 30}, {"x_mm": 30, "y_mm": 10}]},
    ]
    crossings = [f for f in drc_module.run_drc(board)["findings"]
                 if f["type"] == "crossing"]
    assert [f["at"] for f in crossings] == [[20.0, 20.0]], crossings


# ---------------------------------------------------------------------------
# Finding IDENTITY is content-based (cold review, must-fix 2)
# ---------------------------------------------------------------------------


def test_same_type_findings_at_different_places_are_different_findings():
    """Pins that _finding_key is CONTENT-based, not type-based.

    Every other fixture in this file happens to use distinct finding TYPES, so a
    _finding_key of `str(finding["type"])` was indistinguishable from a correct
    one and the whole suite passed with it. The failure that permits: the board
    has dangling_endpoint@P1, the proposal creates dangling_endpoint@P2, and the
    partition cancels the new one as pre-existing — clean:true on a proposal that
    left a wire hanging."""
    from pcb_worker.ir_connectivity import partition_findings

    at_p1 = {"type": "dangling_endpoint", "net": "SIG", "at": [20.0, 35.0]}
    at_p2 = {"type": "dangling_endpoint", "net": "SIG", "at": [26.0, 35.0]}

    # DISCRIMINATING SHAPE. `base=[P1], post=[P1, P2]` would NOT be: the multiset
    # count alone cancels exactly one of the two, so a type-only key reaches the
    # right answer by luck. Here the proposal RESOLVES P1 and creates P2 (the
    # non-monotone case, which really happens), so counts match at 1-vs-1 and
    # only a content-based key can tell that nothing was cancelled.
    introduced, baseline = partition_findings([at_p1], [at_p2])
    assert introduced == [at_p2], introduced
    assert baseline == [at_p1]

    # And with both present, the SURVIVING content must be right, not just the
    # count — post is ordered new-first so a type-only key cancels the wrong one.
    introduced, _ = partition_findings([at_p1], [at_p2, at_p1])
    assert introduced == [at_p2], introduced


def test_same_type_and_place_findings_on_different_nets_are_different_findings():
    """The other field that must participate in identity: two nets can dangle at
    the same coordinate on different layers of the same board."""
    from pcb_worker.ir_connectivity import partition_findings

    sig = {"type": "dangling_endpoint", "net": "SIG", "at": [20.0, 35.0]}
    other = {"type": "dangling_endpoint", "net": "EXIST", "at": [20.0, 35.0]}

    # 1-vs-1 so the multiset count cannot mask a key that ignores "net".
    introduced, baseline = partition_findings([sig], [other])
    assert introduced == [other], introduced
    assert baseline == [sig]


def test_same_type_crossings_at_different_places_are_different_findings():
    """The severity-1 case at the primitive level: crossing findings differing
    ONLY in `at` must not cancel each other."""
    from pcb_worker.ir_connectivity import partition_findings

    old = {"type": "crossing", "nets": ["EXIST", "SIG"], "layer": "top",
           "at": [30.0, 30.0]}
    new = {"type": "crossing", "nets": ["EXIST", "SIG"], "layer": "top",
           "at": [30.0, 20.0]}

    # 1-vs-1, and then both-present ordered new-first: neither shape lets a
    # count-only or type-only key land on the right answer by accident.
    introduced, baseline = partition_findings([old], [new])
    assert introduced == [new], introduced
    assert baseline == [old]

    introduced, _ = partition_findings([old], [new, old])
    assert introduced == [new], introduced


# ---------------------------------------------------------------------------
# Connectivity COMPLETENESS on the route reply — HITL-4 (docs/llm-ergonomics.md
# F2). The propose-side surface of the same fix tests/test_drc.py pins for the
# standalone method: `drc_summary` gains `complete` + `missing_copper`
# (+ `partial`, absent-key) computed over the POST-proposal board, narrowed to
# the run's scope. `clean` keeps meaning exactly what it meant (no introduced
# short/mismatch), so a blocked net now reads clean:True + complete:False —
# honestly split — where it used to read just "clean".
# ---------------------------------------------------------------------------


def _f2_tp(ref: str, x: float, y: float) -> dict:
    """Through-hole test point — the same shape _board()'s components use,
    factored because this section places them at parametrised positions."""
    return {"ref": ref, "footprint": "TH_TestPoint", "x_mm": x, "y_mm": y,
            "rotation_deg": 0, "layer": "top",
            "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0,
                      "drill_mm": 0.8, "annulus_diameter_mm": 1.6}]}


def _walled_vcc_board() -> dict:
    """VCC needs to cross a full-height foreign wall; with single_layer there
    is no way around or under, so VCC comes back unrouted — leaving an
    in-scope net with pins and ZERO copper on the post-proposal board."""
    return {
        "version": 1, "name": "missing-copper", "width_mm": 60, "height_mm": 40,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [
            _f2_tp("U2", 10, 20), _f2_tp("J2", 50, 20),
            _f2_tp("A1", 30, 0.8), _f2_tp("A2", 30, 39.2),
        ],
        "nets": [{"name": "VCC", "pins": ["U2.1", "J2.1"]},
                 {"name": "EXIST", "pins": ["A1.1", "A2.1"]}],
        "traces": [{"net": "EXIST", "layer": "top", "width_mm": 0.25,
                    "points": [{"x_mm": 30, "y_mm": 0.8},
                               {"x_mm": 30, "y_mm": 39.2}]}],
    }


def test_an_unroutable_scoped_net_is_named_missing_copper_not_just_clean():
    resp = _call("route", {"board": _walled_vcc_board(),
                           "scope": {"nets": ["VCC"]},
                           "options": {"single_layer": True}})
    assert resp["ok"] is True, resp
    r = resp["result"]
    assert {u["net"] for u in r["unrouted"]} == {"VCC"}
    summary = r["drc_summary"]
    # The old halves keep their meaning: nothing was introduced, so clean.
    assert summary["scope"] == "connectivity"
    assert summary["clean"] is True
    # The new half says what "clean" never could: the copper is not there.
    assert summary["complete"] is False
    assert summary["missing_copper"] == ["VCC"]


def test_missing_copper_is_scoped_to_the_nets_the_run_asked_about():
    """EXIST is fully wired and is the whole scope; VCC has zero copper but
    was NOT asked about, so it must not be named HERE — drc_summary is the
    PROPOSAL ledger and answers the request. The whole board's state is the
    `board_health` BOARD ledger's job (tested below) and the standalone `drc`
    method's."""
    resp = _call("route", {"board": _walled_vcc_board(),
                           "scope": {"nets": ["EXIST"]}})
    assert resp["ok"] is True, resp
    summary = resp["result"]["drc_summary"]
    assert summary["complete"] is True
    assert summary["missing_copper"] == []
    assert "partial" not in summary


def test_a_fully_routed_run_reports_complete():
    """Negative gate at the route level: route VCC with both layers available
    and the summary is complete with nothing missing."""
    resp = _call("route", {"board": _walled_vcc_board(),
                           "scope": {"nets": ["VCC"]}})
    assert resp["ok"] is True, resp
    r = resp["result"]
    assert {rt["net"] for rt in r["routes"]} == {"VCC"}
    assert r["drc_summary"]["complete"] is True
    assert r["drc_summary"]["missing_copper"] == []


# ---------------------------------------------------------------------------
# board_health — the WHOLE-BOARD ledger (DCR 019fd5fd9084). drc_summary above
# is the PROPOSAL ledger (scoped to the run's only_nets); board_health rides
# every ok route reply regardless of scope, over the same post-proposal board:
# whole-board census + the tri-state assembly verdict.
# ---------------------------------------------------------------------------


def test_board_health_reports_the_whole_board_despite_a_narrow_scope():
    """THE ledger split in one test: a run scoped to fully-wired EXIST keeps a
    scoped (clean, complete) drc_summary — and board_health still names
    un-asked-about VCC's missing copper, because the board ledger answers
    "what state is the BOARD in?" no matter what this run was asked."""
    resp = _call("route", {"board": _walled_vcc_board(),
                           "scope": {"nets": ["EXIST"]}})
    assert resp["ok"] is True, resp
    r = resp["result"]
    # The proposal ledger stays scoped (previous test) …
    assert r["drc_summary"]["complete"] is True
    assert r["drc_summary"]["missing_copper"] == []
    # … while the board ledger tells the whole truth.
    health = r["board_health"]
    assert health["complete"] is False
    assert health["missing_copper"] == ["VCC"]
    assert "partial" not in health
    assert health["approximate"] is True
    assert health["assembly"]["status"] in ("pass", "findings",
                                            "indeterminate")


def test_board_health_is_always_present_and_carries_assembly():
    """Every ok route reply carries board_health — including a fully-healthy
    run, where it is the measured all-clear: complete, nothing missing, and a
    tri-state assembly verdict (TH test points resolve to measurable pad
    extents, so this board's parts are judged, not skipped)."""
    resp = _call("route", {"board": _walled_vcc_board(),
                           "scope": {"nets": ["VCC"]}})
    assert resp["ok"] is True, resp
    health = resp["result"]["board_health"]
    assert health["complete"] is True
    assert health["missing_copper"] == []
    assert health["approximate"] is True
    assert health["assembly"] == {"status": "pass", "findings": []}


def test_board_health_census_faults_degrade_to_indeterminate(monkeypatch):
    """A census fault inside board_health is a report, not a failure: complete
    None + completeness_error, NO missing_copper key a consumer could read as
    "nothing missing" — and the route reply itself still succeeds."""
    real = drc_module.connectivity_completeness

    def _boom(board, scope_nets=None):
        if scope_nets is None:  # the board-ledger (whole-board) call only
            raise RuntimeError("synthetic census fault")
        return real(board, scope_nets)

    monkeypatch.setattr(drc_module, "connectivity_completeness", _boom)
    resp = _call("route", {"board": _walled_vcc_board(),
                           "scope": {"nets": ["VCC"]}})
    assert resp["ok"] is True, resp
    health = resp["result"]["board_health"]
    assert health["complete"] is None
    assert "synthetic census fault" in health["completeness_error"]
    assert "missing_copper" not in health
    assert health["approximate"] is True
    # The assembly half is a separate computation and still answers.
    assert health["assembly"]["status"] in ("pass", "findings",
                                            "indeterminate")


def test_a_zone_bearing_net_reads_indeterminate_on_both_ledgers():
    """CENSUS CORRECTION 019fd5fdeef3b at the propose-reply seams: a poured
    net is unjudgeable copper — {net, reason: "zone_copper"} — and flips
    `complete` to None (tri-state) rather than the pre-fix auto-complete, on
    the scoped summary AND the board ledger alike.

    Exercised at the attach seams (`_attach_route_drc` / `_board_health`)
    rather than through `route`: the routing path fails closed on
    zone-bearing boards (UnsupportedGeometry) before either ledger exists, so
    this seam is how zone copper actually reaches these summaries (e.g. via
    the drawn/as-drawn reply assembly)."""
    from pcb_worker.methods import _attach_route_drc, _board_health

    board = _walled_vcc_board()
    board["zones"] = [{"net": "EXIST", "layer": "bottom",
                       "points": [{"x_mm": 0, "y_mm": 0},
                                  {"x_mm": 60, "y_mm": 0},
                                  {"x_mm": 60, "y_mm": 40},
                                  {"x_mm": 0, "y_mm": 40}]}]
    payload: dict = {"routes": []}
    _attach_route_drc(payload, board, scope_nets={"EXIST"})
    summary = payload["drc_summary"]
    assert summary["complete"] is None  # nothing missing, one net unjudgeable
    assert summary["missing_copper"] == []
    assert summary["indeterminate"] == [
        {"net": "EXIST", "reason": "zone_copper"}]
    assert summary["approximate"] is True

    health = _board_health(board, [], board)
    assert health["complete"] is False  # whole board: VCC is measurably missing
    assert health["missing_copper"] == ["VCC"]
    assert health["indeterminate"] == [
        {"net": "EXIST", "reason": "zone_copper"}]


# ---------------------------------------------------------------------------
# island_delta (Epoch UX2 station 6, docket 019fde367b24) — per-route census
# CREDIT. "GND partial, 9 pin groups" is true but unactionable; "this route
# merges 2 islands -> 1" is a decision aid. Each route is judged ALONE
# against the PRE-proposal board (accepting only one candidate must not
# inherit a sibling's credit), with the same union-find + credits as the
# census itself (drc.net_pin_group_count), and the per-route stamps are
# hoisted as top-level `island_deltas` (the span_outcomes convention).
# ---------------------------------------------------------------------------


def test_a_route_reports_its_island_delta_and_the_hoisted_list():
    """VCC starts as two unconnected pins (2 islands); one routed span takes
    it to 1 — stamped on the route AND hoisted, identical numbers."""
    resp = _call("route", {"board": _walled_vcc_board(),
                           "scope": {"nets": ["VCC"]}})
    assert resp["ok"] is True, resp
    r = resp["result"]
    vcc = [rt for rt in r["routes"] if rt["net"] == "VCC"]
    assert len(vcc) == 1
    assert vcc[0]["island_delta"] == {"pin_groups_before": 2,
                                      "pin_groups_after": 1}
    assert r["island_deltas"] == [{"net": "VCC", "pin_groups_before": 2,
                                   "pin_groups_after": 1}]


def test_island_delta_is_computed_against_the_pre_proposal_board():
    """The board_health census runs POST-proposal (VCC complete after this
    run) while the delta's `pin_groups_before` reads the PRE-proposal state —
    both from one reply, so the split is observable in a single call."""
    resp = _call("route", {"board": _walled_vcc_board(),
                           "scope": {"nets": ["VCC"]}})
    assert resp["ok"] is True, resp
    r = resp["result"]
    assert r["board_health"]["complete"] is True  # post-proposal ledger
    assert r["island_deltas"][0]["pin_groups_before"] == 2  # pre-proposal


def test_island_delta_absent_for_a_zone_bearing_net():
    """019fd5fdeef3b mirrored: pour connectivity is unjudgeable for the
    centerline kernel, so a zone-bearing net earns NO delta (never a number
    that pretends the pour was measured). Exercised at the attach seam like
    the census-correction test above — the routing path fails closed on
    zone-bearing boards before any ledger exists."""
    from pcb_worker.methods import _attach_island_deltas

    board = _walled_vcc_board()
    board["zones"] = [{"net": "VCC", "layer": "bottom",
                       "points": [{"x_mm": 0, "y_mm": 0},
                                  {"x_mm": 60, "y_mm": 0},
                                  {"x_mm": 60, "y_mm": 40},
                                  {"x_mm": 0, "y_mm": 40}]}]
    payload: dict = {"routes": [{"net": "VCC", "segments": [
        {"start": [10.0, 20.0], "end": [50.0, 20.0], "layer": "top"}]}]}
    _attach_island_deltas(payload, board)
    assert "island_delta" not in payload["routes"][0]
    assert "island_deltas" not in payload


def test_island_delta_absent_for_a_single_pin_net():
    """Fewer than two pins: nothing to connect, no delta — mirrors the
    census's own <2-pin skip."""
    from pcb_worker.methods import _attach_island_deltas

    board = _walled_vcc_board()
    board["nets"].append({"name": "LONE", "pins": ["A1.1"]})
    payload: dict = {"routes": [{"net": "LONE", "segments": [
        {"start": [30.0, 0.8], "end": [40.0, 0.8], "layer": "top"}]}]}
    _attach_island_deltas(payload, board)
    assert "island_delta" not in payload["routes"][0]
    assert "island_deltas" not in payload


def test_island_delta_zero_merge_is_reported_not_hidden():
    """A route whose copper connects nothing new (both endpoints already on
    the same island) reports before == after — the 'this candidate buys
    nothing' smell, which absent-key would hide."""
    from pcb_worker.methods import _attach_island_deltas

    board = _walled_vcc_board()
    # EXIST is already fully wired (one island); add a redundant parallel run.
    payload: dict = {"routes": [{"net": "EXIST", "segments": [
        {"start": [30.0, 0.8], "end": [30.0, 39.2], "layer": "top"}]}]}
    _attach_island_deltas(payload, board)
    assert payload["routes"][0]["island_delta"] == {
        "pin_groups_before": 1, "pin_groups_after": 1}


# ---------------------------------------------------------------------------
# board_health as a STANDALONE method (Epoch UX2 station 9, docket
# 019fde571300): the same whole-board ledger a route reply carries, computable
# with NO routing run — the load path's census+assembly surface, one kernel
# (_board_health) behind both.
# ---------------------------------------------------------------------------


def test_board_health_method_reports_the_ledger_without_a_routing_run():
    resp = _call("board_health", {"board": _walled_vcc_board()})
    assert resp["ok"] is True, resp
    health = resp["result"]
    # EXIST is fully wired; VCC has pins and zero copper.
    assert health["complete"] is False
    assert health["missing_copper"] == ["VCC"]
    assert "partial" not in health
    assert health["approximate"] is True
    assert health["assembly"]["status"] in ("pass", "findings", "indeterminate")


def test_board_health_method_matches_a_route_replys_ledger():
    """One kernel behind both surfaces: the standalone method over the base
    board equals the route reply's board_health for a run that landed no new
    copper (scoped to already-wired EXIST — census unchanged)."""
    standalone = _call("board_health", {"board": _walled_vcc_board()})["result"]
    routed = _call("route", {"board": _walled_vcc_board(),
                             "scope": {"nets": ["EXIST"]}})
    assert routed["ok"] is True, routed
    via_route = routed["result"]["board_health"]
    assert standalone["complete"] == via_route["complete"]
    assert standalone["missing_copper"] == via_route["missing_copper"]
    assert standalone["assembly"]["status"] == via_route["assembly"]["status"]


def test_board_health_method_parse_failure_is_structured():
    resp = _call("board_health", {"board": "not-a-board"})
    assert resp["ok"] is False
    assert resp["error"]["kind"] == "parse"
