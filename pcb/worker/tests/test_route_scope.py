"""RUN SCOPE + per-route ATTRIBUTION (docket 019f80a80123; mechanism 019f6cf2b5f4).

THE BUG, as observed on the real smart-remote board: two `pcb_route_hint`
annotations targeting MIC1/AMP1 produced SIXTEEN proposals — one per net — every
one tagged `proposal_for` the two hints that never asked for them. `selection` /
`hint_ids` scoped only which hint ANNOTATIONS were consumed; the engine still
auto-routed every net with >= 2 pads.

MEASURED BEFORE THE FIX (not assumed — round B1/7c32d63 had already changed the
symptom): on a 4-net board, ONE hint naming ONE net returned FOUR routes. B1 made
accepted copper visible, so a WHOLLY-routed net now comes back pre-connected and
proposes nothing; that hid the most visible symptom on a finished board and
changed nothing else. A PARTIALLY-routed net was still re-routed in full, and an
unrouted one always was.

WHAT THESE TESTS DRIVE. `route()`, the real entry point, every time — never
`_scoped_nets`/`_hint_ids_by_net` in isolation. This campaign has been burned by
a unit test that exercised a helper and none of its call sites, so a helper-level
test here would close neither docket. The one exception is the no-scope/empty-set
distinction, which is asserted through route() too (an unhinted run vs a run
whose hints resolve to nothing).

THE INVARIANT MOST LIKELY TO BE BROKEN BY THIS FIX, and therefore the test to
read first: `test_an_excluded_nets_accepted_copper_is_still_an_obstacle`.
Excluding a net from ROUTING must never exclude its copper from the GRID. The
cheap implementation — deleting the net from `board.nets` — happens to preserve
this (pads live on `board.pads`, copper on `existing_traces`), but the scope
filter deliberately sits after every grid marking so it is preserved by
construction, and this file proves it rather than trusting it.

MANDATORY FIXTURE GATE 019f70f76c2f is discharged at the bottom by reusing
test_route_rules.py's own fixtures — a 3-pin net whose copper is two
disconnected paths plus a layer-changing via, and an undo-after-commit scenario —
rather than re-staging near-copies of them here.
"""

from __future__ import annotations

import pytest

from pcb_worker import drc as drc_module
from pcb_worker.methods import handle_request

from tests.test_route_rules import (
    BOARD_WIDTH_MM,
    _committed,
    _committed_joined,
    _three_pin_board,
    _undone,
)


# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------


def _call_route(params: dict) -> dict:
    resp = handle_request({"id": "scope", "method": "route", "params": params})
    assert resp is not None and resp["id"] == "scope"
    return resp


def _ok(params: dict) -> dict:
    resp = _call_route(params)
    assert resp["ok"] is True, resp
    return resp["result"]


def _tp(ref: str, x: float, y: float) -> dict:
    """A through-hole test point — one numbered pad, drilled, on every layer.

    Same shape as test_route_rules._tp / test_route_drc's fixtures, kept local
    because those files build it inside board factories this file does not use.
    """
    return {"ref": ref, "footprint": "TH_TestPoint", "x_mm": x, "y_mm": y,
            "rotation_deg": 0, "layer": "top",
            "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0,
                      "drill_mm": 0.8, "annulus_diameter_mm": 1.6}]}


# Six parallel 2-pad nets, well separated, each trivially routable on its own.
# Six rather than two so "only the hinted nets came back" cannot be satisfied by
# accident, and so the count is a real reduction (6 -> 2) rather than a coin
# flip. This IS the smart-remote shape in miniature: many independent nets, a
# couple of hints.
_NET_ROWS = [
    ("NET_A", 6.0), ("NET_B", 13.0), ("NET_C", 20.0),
    ("NET_D", 27.0), ("NET_E", 34.0), ("NET_F", 41.0),
]


def _many_net_board(**extra) -> dict:
    components: list = []
    nets: list = []
    for index, (name, y) in enumerate(_NET_ROWS):
        left, right = f"L{index}", f"R{index}"
        components += [_tp(left, 10.0, y), _tp(right, 50.0, y)]
        nets.append({"name": name, "pins": [f"{left}.1", f"{right}.1"]})
    board = {
        "version": 1, "name": "route-scope", "width_mm": 60, "height_mm": 47,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.25,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": components, "nets": nets,
    }
    board.update(extra)
    return board


def _hint(_id: str, net_index: int, **kp_overrides) -> dict:
    """A hint that names its net ONLY through its source/dest pins.

    Deliberately no `net_names`: pin refs are the weaker, harder case for both
    halves of this round. Scope has to resolve the net the same way the engine
    will, and ATTRIBUTION cannot fall back to matching a proposal's net against
    a `net_names` list that isn't there — which is exactly the path that used to
    produce the blanket "every selected hint" answer.
    """
    kp = {
        "hint_type": "single_trace",
        "detail_level": "guided",  # NOT 'detailed' — see _detailed_hint below
        "layer": "F.Cu",
        "source_pins": [f"L{net_index}.1"],
        "dest_pins": [f"R{net_index}.1"],
        "waypoints": [],
    }
    kp.update(kp_overrides)
    return {"id": _id, "kind": "pcb_route_hint", "lifecycle": "open",
            "author": {"kind": "human"}, "kind_payload": kp}


def _nets_of(result: dict) -> list[str]:
    return sorted(r["net"] for r in result.get("routes", []))


def _attribution(result: dict) -> dict:
    return {r["net"]: r.get("hint_ids", "<absent>")
            for r in result.get("routes", [])}


# ---------------------------------------------------------------------------
# 1. THE ACCEPTANCE TEST: docket 019f80a80123's own repro.
# ---------------------------------------------------------------------------


def test_two_hints_on_a_multi_net_board_propose_only_those_two_nets():
    """019f80a80123, reproduced and closed at the entry point.

    Six routable nets, two hints. Before the fix this returned SIX routes; the
    real board returned sixteen. Both halves of the docket are asserted here
    together on purpose — a run that scoped correctly but still attributed every
    proposal to the whole selection would be half a fix, and the docket
    describes one user-visible defect, not two.
    """
    result = _ok({"board": _many_net_board(),
                  "route_hints": [_hint("h1", 0), _hint("h2", 1)],
                  "selection": {"mode": "ids", "ids": ["h1", "h2"]}})

    assert _nets_of(result) == ["NET_A", "NET_B"], _nets_of(result)
    # ...and each proposal names the ONE hint that asked for it.
    assert _attribution(result) == {"NET_A": ["h1"], "NET_B": ["h2"]}
    # The run-wide list is unchanged and still means what it always meant —
    # "these hints fed the run" — which is why it is NOT what attribution uses.
    assert result["selected_hint_ids"] == ["h1", "h2"]


def test_the_default_open_selection_scopes_just_as_hard_as_an_explicit_one():
    """No `selection` at all. The panel sends {"mode":"open"} and an agent may
    send nothing; the two must not disagree about how much board gets routed —
    the old code scoped neither, so they agreed by being equally wrong."""
    hints = [_hint("h1", 0), _hint("h2", 1)]
    with_selection = _ok({"board": _many_net_board(), "route_hints": hints,
                          "selection": {"mode": "open"}})
    without = _ok({"board": _many_net_board(), "route_hints": hints})
    assert _nets_of(without) == _nets_of(with_selection) == ["NET_A", "NET_B"]
    # Attribution too, on both — two hints and two distinct nets is the shape
    # that tells a per-net answer apart from the blanket one.
    assert _attribution(without) == _attribution(with_selection) == \
        {"NET_A": ["h1"], "NET_B": ["h2"]}


def test_one_hint_does_not_drag_its_neighbours_in():
    result = _ok({"board": _many_net_board(), "route_hints": [_hint("h1", 3)],
                  "selection": {"mode": "ids", "ids": ["h1"]}})
    assert _nets_of(result) == ["NET_D"]
    assert _attribution(result) == {"NET_D": ["h1"]}


def test_the_out_of_scope_nets_are_not_reported_as_unrouted_either():
    """Scoping must not convert "not asked for" into "we tried and failed".
    `unrouted` drives the caller's retry/report loop, so a net that was never in
    the run has no business appearing there."""
    result = _ok({"board": _many_net_board(), "route_hints": [_hint("h1", 0)],
                  "selection": {"mode": "ids", "ids": ["h1"]}})
    assert [u["net"] for u in result.get("unrouted", [])] == []


def test_selection_by_net_scopes_the_engine_to_that_net():
    """`{"mode":"net"}` picked the hints for a net and then routed the whole
    board anyway — the most direct statement of the bug there was."""
    result = _ok({"board": _many_net_board(),
                  "route_hints": [_hint("h1", 0, net_names=["NET_A"]),
                                  _hint("h2", 4, net_names=["NET_E"])],
                  "selection": {"mode": "net", "net": "NET_E"}})
    assert _nets_of(result) == ["NET_E"]
    assert _attribution(result) == {"NET_E": ["h2"]}


# ---------------------------------------------------------------------------
# 2. ATTRIBUTION truthfulness.
# ---------------------------------------------------------------------------


def test_two_hints_asking_for_the_same_net_are_both_named():
    """Truthful is not the same as "exactly one id". When two hints really do
    ask for one net, both belong on the proposal."""
    result = _ok({"board": _many_net_board(),
                  "route_hints": [_hint("h1", 2), _hint("h2", 2)],
                  "selection": {"mode": "ids", "ids": ["h1", "h2"]}})
    assert _nets_of(result) == ["NET_C"]
    assert _attribution(result) == {"NET_C": ["h1", "h2"]}


def test_an_unhinted_whole_board_run_carries_no_attribution_key_at_all():
    """Absent-key contract, same as "drc"/"drc_geometric" (methods.py). An empty
    list would read as "no hint wanted this route", which is a claim; the truth
    is that no hint was asked, which is the absence of one."""
    result = _ok({"board": _many_net_board()})
    assert len(result["routes"]) == len(_NET_ROWS)
    for route in result["routes"]:
        assert "hint_ids" not in route, route


def test_a_hint_that_names_a_net_the_board_lacks_is_not_credited_with_a_route():
    """`net_names[0]` pointing at a missing net falls through to pin resolution
    (route_bridge._net_for_hint). The route it ends up asking for is the PIN's
    net — so the attribution must say NET_A, and the scope must be NET_A, not
    the phantom."""
    result = _ok({"board": _many_net_board(),
                  "route_hints": [_hint("h1", 0, net_names=["NO_SUCH_NET"])],
                  "selection": {"mode": "ids", "ids": ["h1"]}})
    assert _nets_of(result) == ["NET_A"]
    assert _attribution(result) == {"NET_A": ["h1"]}
    assert any("NO_SUCH_NET" in w["message"] for w in result.get("warnings", []))


# ---------------------------------------------------------------------------
# 3. THE DOCUMENTED no-selection / empty-scope DECISION (pcb/docs/routing.md,
#    "Run scope"). Route-everything and route-nothing are BOTH defensible; what
#    is not defensible is doing one silently while the caller expects the other.
#    So both branches are pinned here, and the doc says the same thing.
# ---------------------------------------------------------------------------


def test_no_hints_at_all_still_routes_the_whole_board():
    """DECISION, half 1: `route(board)` with no hints means "autoroute this
    board". It is the CLI's contract and every unhinted caller's, there is no
    selection to narrow it with, and changing it would break the one use of the
    method that was never confused."""
    result = _ok({"board": _many_net_board()})
    assert _nets_of(result) == sorted(name for name, _y in _NET_ROWS)


def test_an_empty_hint_list_is_the_same_as_no_hints():
    result = _ok({"board": _many_net_board(), "route_hints": []})
    assert _nets_of(result) == sorted(name for name, _y in _NET_ROWS)


def test_hints_that_resolve_to_no_net_route_nothing_and_say_why():
    """DECISION, half 2: a hinted run is SCOPED, and an empty scope is honoured.

    The caller named hints, so it asked for a scoped run. Widening back to the
    whole board here would reinstate the exact surprise this round removes, at
    the worst possible moment — when the worker has just failed to understand
    the request. Nothing is routed, and the reply says so in `warnings` rather
    than looking like a board with nothing to do.
    """
    bad = _hint("h1", 0, source_pins=["NOPE.1"], dest_pins=["ALSO_NOPE.1"])
    result = _ok({"board": _many_net_board(), "route_hints": [bad],
                  "selection": {"mode": "ids", "ids": ["h1"]}})
    assert result["routes"] == []
    assert any("none resolved to a net" in w["message"]
               for w in result.get("warnings", [])), result.get("warnings")


def test_a_selection_that_matches_no_hint_routes_nothing():
    """Same rule reached the other way: real hints, a selection that excludes
    all of them. "I asked for these three ids and this board has none of them"
    must not autoroute the board."""
    result = _ok({"board": _many_net_board(),
                  "route_hints": [_hint("h1", 0), _hint("h2", 1)],
                  "selection": {"mode": "ids", "ids": ["nope"]}})
    assert result["routes"] == []
    assert result.get("selected_hint_ids") is None


def test_a_closed_hint_does_not_widen_the_scope_of_an_open_one():
    """Default 'open' selection: the resolved hint is filtered out BEFORE net
    resolution, so its net must not be routed — and must not be attributed."""
    open_hint = _hint("h_open", 0)
    closed = _hint("h_closed", 5)
    closed["lifecycle"] = "resolved"
    result = _ok({"board": _many_net_board(),
                  "route_hints": [open_hint, closed]})
    assert _nets_of(result) == ["NET_A"]
    assert _attribution(result) == {"NET_A": ["h_open"]}


# ---------------------------------------------------------------------------
# 4. THE REGRESSION GUARD FOR ROUND B1 (7c32d63): an EXCLUDED net's copper is
#    still on the grid. This is the invariant a scoping fix is most likely to
#    break, so it is tested with geometry, not with a flag.
# ---------------------------------------------------------------------------


# A1/A2 (net EXIST) at (30,5)/(30,35) carry a vertical wall of accepted copper at
# x=30. SIG must get from U1(10,20) to J1(50,20) — a straight line straight
# through it. Same fixture as test_route_drc's crossing case, which is where it
# earned its keep: if accepted copper were invisible the engine takes the
# straight line, because it is both the cheapest path and a short.
_WALL_A = (30.0, 5.0)
_WALL_B = (30.0, 35.0)


def _walled_board() -> dict:
    return {
        "version": 1, "name": "route-scope-wall", "width_mm": 60,
        "height_mm": 40, "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [_tp("U1", 10, 20), _tp("J1", 50, 20),
                       _tp("A1", 30, 5), _tp("A2", 30, 35)],
        "nets": [{"name": "SIG", "pins": ["U1.1", "J1.1"]},
                 {"name": "EXIST", "pins": ["A1.1", "A2.1"]}],
        "traces": [{"net": "EXIST", "layer": "top", "width_mm": 0.25,
                    "points": [{"x_mm": 30, "y_mm": 5},
                               {"x_mm": 30, "y_mm": 35}]}],
    }


def _sig_hint() -> dict:
    return {"id": "h_sig", "kind": "pcb_route_hint", "lifecycle": "open",
            "author": {"kind": "human"},
            "kind_payload": {"hint_type": "single_trace",
                             "detail_level": "guided", "layer": "F.Cu",
                             "source_pins": ["U1.1"], "dest_pins": ["J1.1"],
                             "waypoints": []}}


def test_an_excluded_nets_accepted_copper_is_still_an_obstacle():
    """THE test for "do not regress round B1" (7c32d63, T7 019f70ebc9ed).

    EXIST is OUT of the run — one hint, naming SIG only — and its wall of
    accepted copper is still marked on the grid. Three things must hold, and
    the second is the whole point:

      * only SIG is proposed (the scope worked at all), and
      * no proposed SIG segment crosses the EXIST wall, and
      * the geometric overlay agrees the proposal is clean.

    An implementation that scoped by DELETING the net — from board.nets, from
    the pad list, or from `existing_traces` — passes the first assertion and
    fails the second, because the cheapest path is then the straight line at
    y=20 straight through x=30. That is the failure mode this file exists for.
    """
    result = _ok({"board": _walled_board(), "route_hints": [_sig_hint()],
                  "selection": {"mode": "ids", "ids": ["h_sig"]}})

    assert _nets_of(result) == ["SIG"], _nets_of(result)
    assert _attribution(result) == {"SIG": ["h_sig"]}

    sig = [r for r in result["routes"] if r["net"] == "SIG"][0]
    assert sig["segments"], sig
    for seg in sig["segments"]:
        start = (seg["start"][0], seg["start"][1])
        end = (seg["end"][0], seg["end"][1])
        assert not drc_module._segments_intersect(start, end, _WALL_A, _WALL_B), (
            f"proposed SIG segment {start}->{end} crosses the EXCLUDED EXIST "
            "net's accepted copper — excluding a net from routing has excluded "
            "its copper from the grid")
    assert result["drc_geometric_summary"]["verdict"] == "clean", \
        result["drc_geometric_summary"]


def _route_capturing_the_grid(monkeypatch, params: dict):
    """Drive route() and hand back the RoutingGrid IT ACTUALLY BUILT.

    Captured, never rebuilt: a re-derived grid is a second copy of the engine's
    construction (resolution, clearance, trace_width, origin, which copper got
    marked and in what order), and a probe against a grid that merely resembles
    the router's own proves nothing about the router. Same reasoning, and the
    same seam, as test_route_drc._route_probing_the_real_grid.
    """
    from agent_router import router as router_mod
    from agent_router.grid import RoutingGrid

    captured: list = []

    class _RecordingGrid(RoutingGrid):
        def __post_init__(self):
            super().__post_init__()
            captured.append(self)

    monkeypatch.setattr(router_mod, "RoutingGrid", _RecordingGrid)
    result = _ok(params)
    assert captured, "route() never built a RoutingGrid — the probe saw nothing"
    return result, captured[-1]


# Points strictly INSIDE the EXIST wall's copper run (x=30, y from 5 to 35),
# clear of both A1's and A2's pad lands so a blocked verdict can only come from
# the TRACE, not from a pad that happens to sit at the same x.
_WALL_PROBES = [(30.0, 14.0), (30.0, 20.0), (30.0, 26.0)]


def test_the_scoped_runs_own_grid_still_blocks_the_excluded_nets_copper(monkeypatch):
    """The same claim as the test above, stated where it is decided rather than
    where it is observed: interrogate the grid the SCOPED run actually routed
    against, at points inside the EXCLUDED net's copper.

    The crossing assertion above can be satisfied by luck — some other obstacle,
    or a path that happened to go the long way. This cannot: the grid either
    holds EXIST's copper or it does not.

    Non-vacuous by construction: the SAME probe points on the SAME board with
    the trace removed must come back routable, so a `can_route_through` that
    returned False for everything would fail the control.
    """
    _result, grid = _route_capturing_the_grid(
        monkeypatch, {"board": _walled_board(), "route_hints": [_sig_hint()],
                      "selection": {"mode": "ids", "ids": ["h_sig"]}})
    for x, y in _WALL_PROBES:
        assert not grid.can_route_through(x, y, "SIG", "F.Cu"), (
            f"grid cell ({x}, {y}) is open to SIG, but the EXCLUDED net EXIST "
            "has accepted copper there — scoping a net out of the run has "
            "taken its copper off the grid")

    bare = _walled_board()
    bare["traces"] = []
    _result2, control_grid = _route_capturing_the_grid(
        monkeypatch, {"board": bare, "route_hints": [_sig_hint()],
                      "selection": {"mode": "ids", "ids": ["h_sig"]}})
    for x, y in _WALL_PROBES:
        assert control_grid.can_route_through(x, y, "SIG", "F.Cu"), (
            f"control probe ({x}, {y}) is blocked on a board with NO trace — "
            "the probe above proves nothing")


def test_an_excluded_nets_pads_are_still_obstacles():
    """Copper is not the only thing an excluded net owns. X1 sits in the middle
    of the only straight run between P1 and P2 on the 3-pin fixture; with OTHER
    out of scope, the SIG proposal must still keep clear of X1's land.

    Proven through the geometric overlay (ir_candidates/drc_geometric), which is
    the checker that actually knows where the copper is — not through a
    hand-rolled distance test that could disagree with it.
    """
    result = _ok({"board": _three_pin_board(),
                  "route_hints": [_three_pin_hint()],
                  "selection": {"mode": "ids", "ids": ["h_3pin"]}})
    assert _nets_of(result) == ["SIG"], _nets_of(result)
    assert result["drc_geometric_summary"]["verdict"] == "clean", \
        result["drc_geometric_summary"]
    assert result["drc_summary"]["clean"] is True, result["drc_summary"]


# ---------------------------------------------------------------------------
# 5. Partially-routed nets — the half of the old bug B1 did NOT fix.
# ---------------------------------------------------------------------------


def test_a_partly_routed_net_out_of_scope_is_left_alone():
    """MEASURED before the fix: B1 (7c32d63) suppressed a WHOLLY-routed net's
    proposal because its pads come back pre-connected, but a PARTLY-routed net
    still got re-routed in full. `_committed_joined(..., with_via=False)` is the
    3-pin fixture with the via taken out, so SIG's two copper runs no longer
    join and the net is genuinely half-done.

    With the hint naming OTHER, SIG must not be touched — not because it looks
    finished (it does not), but because nobody asked.
    """
    board = _committed_joined(_three_pin_board(), with_via=False)
    result = _ok({"board": board, "route_hints": [_other_hint()],
                  "selection": {"mode": "ids", "ids": ["h_other"]}})
    assert _nets_of(result) == ["OTHER"], _nets_of(result)
    assert _attribution(result) == {"OTHER": ["h_other"]}

    # ...and the same board with NO hints still finishes SIG, so the assertion
    # above is about scope and not about SIG having become unroutable.
    unhinted = _ok({"board": board})
    assert "SIG" in _nets_of(unhinted), _nets_of(unhinted)


# ---------------------------------------------------------------------------
# 6. Route-as-drawn: a 'detailed' hint is materialized verbatim rather than
#    routed, so it takes the OTHER path through _route. Its attribution comes
#    from the route's own `hint_id`, and it must not widen the scope.
# ---------------------------------------------------------------------------


def _detailed_hint(_id: str, net_index: int) -> dict:
    hint = _hint(_id, net_index)
    hint["kind_payload"]["detail_level"] = "detailed"
    return hint


def test_an_as_drawn_route_is_attributed_to_the_hint_that_drew_it():
    result = _ok({"board": _many_net_board(),
                  "route_hints": [_detailed_hint("d1", 0), _hint("h2", 1)],
                  "selection": {"mode": "ids", "ids": ["d1", "h2"]}})
    assert _nets_of(result) == ["NET_A", "NET_B"]
    assert _attribution(result) == {"NET_A": ["d1"], "NET_B": ["h2"]}
    drawn = [r for r in result["routes"] if r.get("as_drawn")]
    assert [r["net"] for r in drawn] == ["NET_A"], result["routes"]


def test_a_detailed_hint_alone_does_not_autoroute_the_rest_of_the_board():
    """The as-drawn path consumes its net BEFORE the engine runs (methods.py
    pops it from board.nets). That alone never scoped anything — the other five
    nets were routed anyway. This is the same defect on the second path."""
    result = _ok({"board": _many_net_board(),
                  "route_hints": [_detailed_hint("d1", 2)],
                  "selection": {"mode": "ids", "ids": ["d1"]}})
    assert _nets_of(result) == ["NET_C"]
    assert _attribution(result) == {"NET_C": ["d1"]}


# ---------------------------------------------------------------------------
# 7. Buses. A bus hint is AUTHORED input routed OUTSIDE the scoped net loop
#    (agent_router/router.py::route_board_with_hints), so the scope has to be a
#    superset of its nets or the run would contradict itself.
# ---------------------------------------------------------------------------


def test_a_bus_hint_puts_every_net_it_carries_in_scope_and_no_others():
    bus = {"id": "b1", "kind": "pcb_route_hint", "lifecycle": "open",
           "author": {"kind": "human"},
           "kind_payload": {"hint_type": "bus", "layer": "F.Cu",
                            "net_names": ["NET_A", "NET_B"],
                            "waypoints": [[20.0, 9.0], [40.0, 9.0]]}}
    result = _ok({"board": _many_net_board(), "route_hints": [bus],
                  "selection": {"mode": "ids", "ids": ["b1"]}})
    assert _nets_of(result) == ["NET_A", "NET_B"], _nets_of(result)
    # Both nets are attributed to the ONE hint that asked for both — truthful
    # and not blanket, because it really did ask for both.
    assert _attribution(result) == {"NET_A": ["b1"], "NET_B": ["b1"]}


def test_a_bus_net_the_board_lacks_is_dropped_from_the_scope_not_added_to_it():
    """route_bridge drops absent bus nets with a warning; the scope must be
    built from the nets that SURVIVED that drop, not from what was asked for."""
    bus = {"id": "b1", "kind": "pcb_route_hint", "lifecycle": "open",
           "author": {"kind": "human"},
           "kind_payload": {"hint_type": "bus", "layer": "F.Cu",
                            "net_names": ["NET_A", "NET_B", "GHOST"],
                            "waypoints": [[20.0, 9.0], [40.0, 9.0]]}}
    result = _ok({"board": _many_net_board(), "route_hints": [bus],
                  "selection": {"mode": "ids", "ids": ["b1"]}})
    assert _nets_of(result) == ["NET_A", "NET_B"]
    assert "GHOST" not in _attribution(result)
    assert any("GHOST" in w["message"] for w in result.get("warnings", []))


# ---------------------------------------------------------------------------
# 8. MANDATORY FIXTURE GATE 019f70f76c2f, discharged on this round's change.
#
#    Both required scenarios are REUSED from test_route_rules.py rather than
#    re-staged: `_three_pin_board` (a 3-pin net whose MST is two connections,
#    so its route is legitimately two disconnected copper paths) and
#    `_committed`/`_undone` (the undo-after-commit round trip, expressed the
#    only honest way a stateless worker can: the same board with the commit's
#    copper on it, then off it again).
#
#    THE VIA, HONESTLY. Verified again on this round: the real engine produces
#    ZERO vias on this fixture — `route()` finds a same-layer path and never
#    needs one. The layer-changing-via half of the gate therefore rides on
#    STAGED copper: `_committed_joined` writes the two-paths-plus-via shape onto
#    the board as ACCEPTED copper, and the tests below assert what the SCOPE
#    does in the presence of that shape. That is a real exercise of the change
#    (the via and both copper runs are on the grid, and the scope decides
#    whether SIG is re-proposed), and it is NOT engine coverage of via
#    production. Saying so is the same caveat test_route_rules.py carries on
#    `_three_pin_route_reply`, and it stays until the engine earns its removal.
# ---------------------------------------------------------------------------


def _three_pin_hint() -> dict:
    return {"id": "h_3pin", "kind": "pcb_route_hint", "lifecycle": "open",
            "author": {"kind": "human"},
            "kind_payload": {"hint_type": "single_trace",
                             "detail_level": "guided", "layer": "F.Cu",
                             "source_pins": ["P1.1"], "dest_pins": ["P2.1"],
                             "waypoints": []}}


def _other_hint() -> dict:
    return {"id": "h_other", "kind": "pcb_route_hint", "lifecycle": "open",
            "author": {"kind": "human"},
            "kind_payload": {"hint_type": "single_trace",
                             "detail_level": "guided", "layer": "F.Cu",
                             "source_pins": ["X1.1"], "dest_pins": ["X2.1"],
                             "waypoints": []}}


def test_the_three_pin_multi_path_fixture_scopes_to_the_hinted_net():
    """A 3-pin net is where "scope" could plausibly mean "one connection" rather
    than "one net". It means the NET: SIG's route still carries the whole
    spanning tree (two connections, so >= 2 segments), and OTHER stays out."""
    result = _ok({"board": _three_pin_board(),
                  "route_hints": [_three_pin_hint()],
                  "selection": {"mode": "ids", "ids": ["h_3pin"]}})
    assert _nets_of(result) == ["SIG"]
    sig = [r for r in result["routes"] if r["net"] == "SIG"][0]
    assert len(sig["segments"]) >= 2, sig
    assert sig["hint_ids"] == ["h_3pin"]
    # The engine's honest output on this fixture — see the section note.
    assert result["via_count"] == 0, result["via_count"]


def test_the_staged_two_path_via_shape_does_not_leak_the_net_back_into_scope():
    """The gate's copper shape (two disconnected paths on two layers joined by a
    layer-changing via) is present as ACCEPTED copper while OTHER is the only
    hinted net. SIG must stay out of the run — and its via and both copper runs
    must still be on the grid, which the geometric verdict on OTHER's proposal
    is what actually checks."""
    board = _committed_joined(_three_pin_board(), with_via=True)
    assert len(board["vias"]) == 1 and len(board["traces"]) == 2, board

    result = _ok({"board": board, "route_hints": [_other_hint()],
                  "selection": {"mode": "ids", "ids": ["h_other"]}})
    assert _nets_of(result) == ["OTHER"], _nets_of(result)
    assert _attribution(result) == {"OTHER": ["h_other"]}
    assert result["drc_geometric_summary"]["verdict"] == "clean", \
        result["drc_geometric_summary"]


def test_commit_then_undo_under_a_scoped_run_scopes_the_same_both_times():
    """MANDATORY undo-after-commit, asked of THIS round's change.

    The scope is a function of the HINTS, never of what copper happens to be on
    the board. Commit SIG's copper, then take it back off: the hinted net is
    OTHER throughout, so all three runs must return exactly OTHER. An
    implementation that derived scope from "what still needs routing" — a
    tempting shortcut, and one that looks right on a clean board — returns SIG
    on the undone board and fails here.
    """
    board = _three_pin_board()
    hints = {"route_hints": [_other_hint()],
             "selection": {"mode": "ids", "ids": ["h_other"]}}

    before = _ok({"board": board, **hints})
    committed = _ok({"board": _committed(board), **hints})
    undone = _ok({"board": _undone(_committed(board)), **hints})

    assert _nets_of(before) == ["OTHER"], _nets_of(before)
    assert _nets_of(committed) == ["OTHER"], _nets_of(committed)
    assert _nets_of(undone) == ["OTHER"], _nets_of(undone)
    for result in (before, committed, undone):
        assert _attribution(result) == {"OTHER": ["h_other"]}
    # The width the copper came back at is still the board's own — the scope
    # change must not have disturbed the E2 precedence chain on the way past.
    other = [r for r in undone["routes"] if r["net"] == "OTHER"][0]
    assert other["effective_routing_rules"]["trace_width_mm"]["value"] == \
        pytest.approx(BOARD_WIDTH_MM)


# ---------------------------------------------------------------------------
# 8. PER-SPAN OUTCOMES — HITL-4 (docs/llm-ergonomics.md F1).
#
# THE BUG, from the live HITL-4 round (smart-remote board): a span-scoped ask
# for GND BAT1.2→U1.22 whose endpoints an existing B.Cu trace already joined
# returned routes_returned:0, unrouted:[], no warning — byte-identical to a
# dropped request. Diagnosing "the copper is already there" cost a geometry
# dump, a solo re-propose and a full trace export. The skip was implicit: the
# T7 group contraction (agent_router._connections_for_net) yields zero missing
# edges and the per-net loop appended nothing anywhere.
#
# THE CONTRACT these tests pin: every asked-about span/net lands in exactly ONE
# of `routes`, `unrouted`, or the additive `span_outcomes` key — and the key is
# ABSENT entirely when there is nothing to report, so a pre-F1 consumer sees
# the exact bytes it always saw.
# ---------------------------------------------------------------------------


def _gnd_span_board(with_copper: bool = True) -> dict:
    """The live shape in miniature: a 3-pad GND net whose B1.1↔U1.1 span is
    (optionally) already satisfied by an existing BOTTOM-layer trace — the
    same "satisfied by B.Cu copper the ask never mentioned" twist as the real
    GND BAT1.2→U1.22 reproduction. X1 is the deliberately-unconnected third
    pad that makes B1.1/U1.1 a PROPER subset, so the scope resolves to the
    span form (net_terminals) rather than collapsing to whole-net."""
    board = {
        "version": 1, "name": "span-outcome", "width_mm": 60, "height_mm": 40,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.25,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [_tp("B1", 10, 10), _tp("U1", 50, 10), _tp("X1", 30, 30)],
        "nets": [{"name": "GND", "pins": ["B1.1", "U1.1", "X1.1"]}],
    }
    if with_copper:
        board["traces"] = [{"net": "GND", "layer": "bottom", "width_mm": 0.25,
                            "points": [{"x_mm": 10, "y_mm": 10},
                                       {"x_mm": 50, "y_mm": 10}]}]
    return board


_GND_SPAN_SCOPE = {"tasks": [{"task_id": "t-gnd", "net": "GND",
                              "endpoints": ["B1.1", "U1.1"]}]}


def test_an_already_connected_span_reports_an_outcome_not_silence():
    """The reproduction. The span's endpoints are already joined by existing
    copper, so nothing routes and nothing is unrouted — and that answer must
    now be STATED, with the joining copper named (best effort)."""
    result = _ok({"board": _gnd_span_board(), "scope": _GND_SPAN_SCOPE})
    assert result.get("routes", []) == []
    assert result.get("unrouted", []) == []
    outcomes = result.get("span_outcomes")
    assert outcomes is not None, (
        "an already-connected span produced NO outcome — the reply is again "
        "indistinguishable from a dropped request")
    assert len(outcomes) == 1, outcomes
    outcome = outcomes[0]
    assert outcome["net"] == "GND"
    assert outcome["status"] == "already_connected"
    assert sorted(outcome["pads"]) == ["B1.1", "U1.1"]
    # Best-effort attribution: the compiled trace's own id (ordinal-derived on
    # a v1 board — the ID SCHEME is the compiler's business, non-emptiness is
    # this contract's).
    assert outcome["connected_via"], outcome
    assert all(isinstance(t, str) and t for t in outcome["connected_via"])


def test_a_normal_span_still_routes_and_carries_no_span_outcomes_key():
    """Negative gate: remove the pre-existing copper and the identical ask
    routes exactly as before, with NO span_outcomes key at all (absent-key,
    not an empty list a consumer might have to learn to ignore)."""
    result = _ok({"board": _gnd_span_board(with_copper=False),
                  "scope": _GND_SPAN_SCOPE})
    assert _nets_of(result) == ["GND"], _nets_of(result)
    assert result.get("unrouted", []) == []
    assert "span_outcomes" not in result


def test_every_asked_net_lands_in_exactly_one_reply_bucket():
    """The accounting identity itself, over a mixed scope: one net already
    connected, one net needing (and getting) a route."""
    board = _gnd_span_board()
    board["components"] += [_tp("L9", 10, 35), _tp("R9", 50, 35)]
    board["nets"].append({"name": "SIG", "pins": ["L9.1", "R9.1"]})
    result = _ok({"board": board,
                  "scope": {"tasks": _GND_SPAN_SCOPE["tasks"]
                            + [{"task_id": "t-sig", "net": "SIG"}]}})
    routed = {r["net"] for r in result.get("routes", [])}
    unrouted = {u["net"] for u in result.get("unrouted", [])}
    outcome_nets = {o["net"] for o in result.get("span_outcomes", [])}
    for net in ("GND", "SIG"):
        buckets = [net in routed, net in unrouted, net in outcome_nets]
        assert buckets.count(True) == 1, (net, result)
    assert outcome_nets == {"GND"}
    assert routed == {"SIG"}


def test_a_whole_net_already_connected_by_copper_reports_the_outcome():
    """Whole-net form of the same silence: `scope.nets` naming a net whose
    copper is complete used to come back empty-handed with no explanation."""
    board = _gnd_span_board()
    board["nets"] = [{"name": "GND", "pins": ["B1.1", "U1.1"]}]
    del board["components"][2]  # X1 is off the net now; drop it entirely
    result = _ok({"board": board, "scope": {"nets": ["GND"]}})
    assert result.get("routes", []) == []
    outcomes = result.get("span_outcomes")
    assert outcomes and outcomes[0]["status"] == "already_connected"
    assert outcomes[0]["net"] == "GND"
    assert sorted(outcomes[0]["pads"]) == ["B1.1", "U1.1"]


def test_span_outcomes_are_attributed_to_the_hints_that_asked():
    """A HINTED run's outcome carries `hint_ids` — the same net->hints map and
    the same hinted-run-only gate the routes themselves use, so an
    already-connected span can be filed back against the hint that asked."""
    board = _many_net_board(traces=[{
        "net": "NET_A", "layer": "top", "width_mm": 0.25,
        "points": [{"x_mm": 10.0, "y_mm": 6.0}, {"x_mm": 50.0, "y_mm": 6.0}]}])
    result = _ok({"board": board, "route_hints": [_hint("h_a", 0)],
                  "selection": {"mode": "open"}})
    assert _nets_of(result) == [], _nets_of(result)
    outcomes = result.get("span_outcomes")
    assert outcomes and outcomes[0]["net"] == "NET_A"
    assert outcomes[0]["status"] == "already_connected"
    assert outcomes[0]["hint_ids"] == ["h_a"]


def test_an_unhinted_outcome_carries_no_hint_ids_key():
    """Same absent-key rule as routes' own `hint_ids`: no hint was asked, so
    no attribution key exists — an empty list would read as "no hint wanted
    this" on a run where no hint was ever consulted."""
    result = _ok({"board": _gnd_span_board(), "scope": _GND_SPAN_SCOPE})
    assert "hint_ids" not in result["span_outcomes"][0]


def test_unmatched_span_terminals_get_their_own_named_status():
    """Engine-level defence in depth: parse_route_scope refuses unknown
    endpoints long before the engine runs, but the engine itself must not go
    silent if a caller reaches it through another door with terminal refs
    that match nothing. Named `terminals_unmatched`, never folded into
    `already_connected` (a lie about the mechanism)."""
    from agent_router.router import route_board
    from pcb_worker import route_bridge as rb

    board = rb.board_to_router(_gnd_span_board(with_copper=False))
    result = route_board(board, net_terminals={"GND": {"NOPE.1", "ALSO.2"}})
    assert result.routes == [] and result.unrouted == []
    assert result.span_outcomes == [{
        "net": "GND", "status": "terminals_unmatched",
        "requested": ["ALSO.2", "NOPE.1"], "matched": []}]
