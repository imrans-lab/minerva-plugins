"""PARKED — explicit run scope + pinned-candidate keepouts (epoch C, unit C2).

NOT COLLECTED. The filename has no ``test_`` prefix, and ``pyproject.toml``
sets ``testpaths = ["tests"]`` with no ``python_files`` override, so pytest's
default ``test_*.py`` / ``*_test.py`` patterns never see this file — locally or
in ``.github/workflows/pcb.yml``, which runs the same ``python -m pytest
tests/ -q``. It is authored now and EXECUTED at the epoch boundary, when it is
renamed to ``test_route_bridge_scope.py``. Until then it must stay
``py_compile``-clean, which is the only gate it is held to.

WHAT THIS FILE PINS
-------------------
The two halves of DCR finding 7 that unit C2 measured as still open, and only
those. It deliberately re-pins nothing that already ships:

  * ``route_bridge.resolved_board_existing_copper`` (accepted copper -> engine
    keepouts, T7 019f70ebc9ed) is pinned by ``tests/test_route_rules.py`` and
    ``tests/test_route_scope.py``;
  * ``only_nets`` as an ENGINE parameter is pinned by
    ``agent_router``'s own suite and by ``tests/test_route_scope.py``;
  * ``ir_candidates.build_overlay`` (candidate dicts -> IR copper, fail-closed
    on every dimension) is pinned by ``tests/test_candidate_overlay.py``.

What was missing, and is what every test below drives:

  1. the scope could not be STATED — it was inferred from route-hint
     annotations and only inside ``if envelopes:``, so a caller holding a
     workspace RouteTask and no hint got a whole-board run; and
  2. a run could not see PINNED draft copper at all — ``route()`` took no
     candidate parameter, so a scoped run routed as if every pinned candidate
     were empty space and could propose copper straight through a route the
     user had already decided to keep.

THE GEOMETRY IS BORROWED, NOT RE-STAGED
---------------------------------------
The keepout vectors reuse ``test_route_scope._walled_board`` — A1/A2 at
(30,5)/(30,35) carrying a vertical wall at x=30, with SIG needing to get from
U1(10,20) to J1(50,20), a straight line straight through it. That fixture
already earned its keep proving the same claim for ACCEPTED copper; asking it
one lifecycle state earlier is the cheapest honest way to prove it for PINNED
copper, and it means the two answers cannot drift by being staged differently.

Hand-derived expectations are stated as the CONTRACT (which nets are proposed;
whether a proposed segment crosses a named wall segment; which structured error
kind comes back), never as an exact pathfinder output. The engine's chosen
detour is an implementation detail; "it did not cross the wall" is the claim.

MANDATORY FIXTURE GATE 019f70f76c2f is discharged at the bottom by reusing
``test_route_rules``' 3-pin multi-path net and its committed/undone pair, the
same way ``test_route_scope.py`` does.
"""

from __future__ import annotations

import pytest

from pcb_worker import drc as drc_module
from pcb_worker import route_bridge
from pcb_worker.methods import handle_request

from tests.test_route_scope import (
    _WALL_A,
    _WALL_B,
    _sig_hint,
    _walled_board,
)
from tests.test_route_rules import (
    _committed,
    _three_pin_board,
    _undone,
)


# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------


def _call(params: dict) -> dict:
    resp = handle_request({"id": "c2", "method": "route", "params": params})
    assert resp is not None and resp["id"] == "c2"
    return resp


def _ok(params: dict) -> dict:
    resp = _call(params)
    assert resp["ok"] is True, resp
    return resp["result"]


def _err(params: dict) -> dict:
    resp = _call(params)
    assert resp["ok"] is False, resp
    return resp["error"]


def _nets_of(result: dict) -> list:
    return sorted({r["net"] for r in result.get("routes") or []})


def _two_net_board() -> dict:
    """Two independent 2-pin nets, far apart. Nothing blocks anything; this
    fixture is about WHICH nets a run touches, not about pathfinding."""
    def tp(ref, x, y):
        return {"ref": ref, "footprint": "TH_TestPoint", "x_mm": x, "y_mm": y,
                "rotation_deg": 0, "layer": "top",
                "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0,
                          "drill_mm": 0.8, "annulus_diameter_mm": 1.6}]}
    return {
        "version": 1, "name": "c2-two-net", "width_mm": 60, "height_mm": 40,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [tp("U1", 10, 10), tp("J1", 50, 10),
                       tp("U2", 10, 30), tp("J2", 50, 30)],
        "nets": [{"name": "SIG", "pins": ["U1.1", "J1.1"]},
                 {"name": "GND", "pins": ["U2.1", "J2.1"]}],
    }


def _bridge_board(spec: dict):
    """The engine ``Board`` the scope parser is asked about, built the way
    ``_route`` builds it — through the compiler, not the legacy raw builder."""
    from pcb_worker import compile_board

    compiled = compile_board.compile_board(
        spec, requested_outputs=compile_board.V1_ROUTING_OUTPUTS)
    board = getattr(compiled, "board", None)
    assert board is not None, (
        "the scope fixture did not compile; the parser is being asked about a "
        f"board that does not exist: {getattr(compiled, 'diagnostics', compiled)}")
    return route_bridge.resolved_board_to_router(board)


# ---------------------------------------------------------------------------
# 1. parse_route_scope — the argument's own semantics.
# ---------------------------------------------------------------------------


def test_no_scope_is_none_and_none_means_route_everything():
    """The None-vs-empty-set distinction is the whole reason ``_scoped_nets``
    tests ``is None``. The parser must preserve it at its own boundary: an
    absent scope is None (unscoped), never an empty set (scoped to nothing)."""
    board = _bridge_board(_two_net_board())
    assert route_bridge.parse_route_scope(None, board) is None


def test_a_net_form_scope_resolves_to_exactly_those_nets():
    board = _bridge_board(_two_net_board())
    scope = route_bridge.parse_route_scope({"nets": ["SIG"]}, board)
    assert scope.nets == frozenset({"SIG"})
    assert scope.task_ids == ()
    assert scope.warnings == ()


def test_a_task_form_scope_carries_its_task_ids_back_out():
    """A workspace RouteTask is the caller's unit of work; a scope that resolved
    to nets and forgot which task asked would leave the workspace unable to file
    the reply against the task it came from."""
    board = _bridge_board(_two_net_board())
    scope = route_bridge.parse_route_scope(
        {"tasks": [{"task_id": "t-1", "net": "SIG"}]}, board)
    assert scope.nets == frozenset({"SIG"})
    assert scope.task_ids == ("t-1",)


def test_tasks_and_nets_are_additive():
    board = _bridge_board(_two_net_board())
    scope = route_bridge.parse_route_scope(
        {"tasks": [{"task_id": "t-1", "net": "SIG"}], "nets": ["GND"]}, board)
    assert scope.nets == frozenset({"SIG", "GND"})
    assert scope.task_ids == ("t-1",)


def test_a_net_the_board_lacks_is_dropped_from_the_scope_not_added_to_it():
    """Same disposition the bus-net scope already uses (test_route_scope.py::
    test_a_bus_net_the_board_lacks_is_dropped_from_the_scope_not_added_to_it).
    A scope naming a net that is not there must SHRINK the run, never widen it —
    and must say so, because a silently-empty scope routes nothing and looks
    identical to a broken run."""
    board = _bridge_board(_two_net_board())
    scope = route_bridge.parse_route_scope({"nets": ["NOSUCHNET"]}, board)
    assert scope.nets == frozenset()
    assert len(scope.warnings) == 1
    assert "NOSUCHNET" in scope.warnings[0]


def test_a_task_naming_a_net_the_board_lacks_warns_and_keeps_its_task_id():
    board = _bridge_board(_two_net_board())
    scope = route_bridge.parse_route_scope(
        {"tasks": [{"task_id": "t-gone", "net": "NOSUCHNET"}]}, board)
    assert scope.nets == frozenset()
    assert scope.task_ids == ("t-gone",)
    assert any("t-gone" in w for w in scope.warnings)


def test_endpoints_naming_the_whole_net_are_accepted():
    """A 2-pin net's task names both its pads. That is the WHOLE net, so there is
    no span to refuse — the scope is exactly what the engine can express."""
    board = _bridge_board(_two_net_board())
    scope = route_bridge.parse_route_scope(
        {"tasks": [{"task_id": "t-1", "net": "SIG",
                    "endpoints": ["U1.1", "J1.1"]}]}, board)
    assert scope.nets == frozenset({"SIG"})


def test_a_span_of_a_multi_pad_net_resolves_to_a_terminal_set():
    """THE deliberate rewrite the old refusal test demanded of whoever landed
    span routing (docket 019fcb6f9d20, formerly gap 019fc155bc32).

    ``_three_pin_board``'s SIG has three pads. A task naming two of them is a
    SPAN, and it now resolves to a per-net TERMINAL set the engine narrows to
    (agent_router ``_terminal_pads``) instead of being refused: the run scopes
    to SIG, and ``net_terminals`` records exactly the named pair, so routing
    returns copper between those two pads only — the ask is the task boundary.
    """
    board = _bridge_board(_three_pin_board())
    pads = {f"{p.component}.{p.number}" for p in board.nets["SIG"].pads}
    assert len(pads) >= 3, pads
    span = sorted(pads)[:2]

    scope = route_bridge.parse_route_scope(
        {"tasks": [{"task_id": "t-span", "net": "SIG",
                    "endpoints": span}]}, board)
    assert scope.nets == frozenset({"SIG"})
    assert scope.task_ids == ("t-span",)
    assert scope.net_terminals == {"SIG": frozenset(span)}


def test_endpoints_naming_the_whole_net_carry_no_terminal_narrowing():
    """The whole-net form stays byte-identical to pre-span behaviour: a task
    whose endpoints ARE the net's full pad set produces no net_terminals
    entry, so the engine's historical whole-net path runs unchanged."""
    board = _bridge_board(_two_net_board())
    scope = route_bridge.parse_route_scope(
        {"tasks": [{"task_id": "t-1", "net": "SIG",
                    "endpoints": ["U1.1", "J1.1"]}]}, board)
    assert scope.net_terminals is None


def test_a_single_endpoint_span_is_refused_not_widened():
    """One pad is not a routable span. Approximating it to the whole net would
    be exactly the silent widening the scope argument exists to remove."""
    board = _bridge_board(_three_pin_board())
    pads = sorted(f"{p.component}.{p.number}" for p in board.nets["SIG"].pads)
    with pytest.raises(route_bridge.UnsupportedRouteScope) as excinfo:
        route_bridge.parse_route_scope(
            {"tasks": [{"task_id": "t-one", "net": "SIG",
                        "endpoints": pads[:1]}]}, board)
    message = str(excinfo.value)
    assert "t-one" in message
    assert "single endpoint" in message or "2+" in message


def test_two_span_tasks_on_one_net_merge_terminals_with_a_warning():
    """The engine routes ONE tree per net; two spans on the same net union
    their terminal sets, and the merge is NAMED so the caller sees it."""
    board = _bridge_board(_three_pin_board())
    pads = sorted(f"{p.component}.{p.number}" for p in board.nets["SIG"].pads)
    assert len(pads) >= 3
    scope = route_bridge.parse_route_scope(
        {"tasks": [
            {"task_id": "t-a", "net": "SIG", "endpoints": pads[:2]},
            {"task_id": "t-b", "net": "SIG", "endpoints": pads[1:3]},
        ]}, board)
    assert scope.net_terminals == {"SIG": frozenset(pads[:3])}
    assert any("merged" in w for w in scope.warnings)


def test_a_whole_net_ask_beats_a_span_narrowing_on_the_same_net():
    """Explicitly stated wider ask wins; the narrowing is dropped LOUDLY."""
    board = _bridge_board(_three_pin_board())
    pads = sorted(f"{p.component}.{p.number}" for p in board.nets["SIG"].pads)
    scope = route_bridge.parse_route_scope(
        {"tasks": [{"task_id": "t-a", "net": "SIG", "endpoints": pads[:2]}],
         "nets": ["SIG"]}, board)
    assert scope.net_terminals is None
    assert any("whole-net ask wins" in w for w in scope.warnings)


def test_an_endpoint_that_is_not_on_its_net_is_refused():
    """Not a span — a mistake. Dropping it silently would let a task scope a net
    it does not actually touch."""
    board = _bridge_board(_two_net_board())
    with pytest.raises(route_bridge.UnsupportedRouteScope):
        route_bridge.parse_route_scope(
            {"tasks": [{"task_id": "t-1", "net": "SIG",
                        "endpoints": ["U1.1", "U2.1"]}]}, board)


def test_a_task_with_no_net_is_refused():
    board = _bridge_board(_two_net_board())
    with pytest.raises(route_bridge.UnsupportedRouteScope):
        route_bridge.parse_route_scope({"tasks": [{"task_id": "t-1"}]}, board)


def test_an_unknown_scope_key_is_refused_rather_than_ignored():
    """A scope read only in part is a scope that silently widens: the caller
    believes it constrained the run by a key nobody read."""
    board = _bridge_board(_two_net_board())
    with pytest.raises(route_bridge.UnsupportedRouteScope):
        route_bridge.parse_route_scope(
            {"nets": ["SIG"], "spans": [{"from": "U1.1"}]}, board)


def test_a_scope_that_names_neither_tasks_nor_nets_is_refused():
    """An empty mapping could mean "everything" or "nothing"; both readings are
    defensible, which is exactly why the caller has to say which."""
    board = _bridge_board(_two_net_board())
    with pytest.raises(route_bridge.UnsupportedRouteScope):
        route_bridge.parse_route_scope({}, board)


@pytest.mark.parametrize("bad", ["SIG", ["SIG"], 7])
def test_a_non_mapping_scope_is_refused(bad):
    board = _bridge_board(_two_net_board())
    with pytest.raises(route_bridge.UnsupportedRouteScope):
        route_bridge.parse_route_scope(bad, board)


# ---------------------------------------------------------------------------
# 2. The scope through route() — the entry point, not the helper.
# ---------------------------------------------------------------------------


def test_an_explicit_scope_with_no_hints_at_all_routes_only_the_named_net():
    """THE gap. Before this argument existed, a run with no hint annotations was
    unconditionally whole-board, so "route this one task and leave the rest"
    could not be asked for without authoring an annotation first."""
    result = _ok({"board": _two_net_board(), "scope": {"nets": ["SIG"]}})
    assert _nets_of(result) == ["SIG"]


def test_the_same_board_with_no_scope_still_routes_everything():
    """The control. Without it the test above passes on a board that simply
    could not route GND."""
    result = _ok({"board": _two_net_board()})
    assert _nets_of(result) == ["GND", "SIG"]


def test_an_out_of_scope_net_is_not_reported_as_unrouted_either():
    """Out of scope is not "failed to route" — a net nobody asked about must not
    appear in the unrouted list, or every scoped run looks like a partial
    failure."""
    result = _ok({"board": _two_net_board(), "scope": {"nets": ["SIG"]}})
    unrouted_nets = {u.get("net") for u in result.get("unrouted") or []}
    assert "GND" not in unrouted_nets


def test_a_task_form_scope_echoes_its_task_ids_in_the_reply():
    result = _ok({"board": _two_net_board(),
                  "scope": {"tasks": [{"task_id": "t-1", "net": "SIG"}]}})
    assert result["scope_task_ids"] == ["t-1"]
    assert _nets_of(result) == ["SIG"]


def test_a_net_form_scope_carries_no_task_id_key_at_all():
    """Absent, not empty — the same rule the hint attribution follows. An empty
    list would read as "a task asked and got nothing"."""
    result = _ok({"board": _two_net_board(), "scope": {"nets": ["SIG"]}})
    assert "scope_task_ids" not in result


def test_a_scope_naming_no_present_net_routes_nothing_and_says_why():
    """The honoured-empty-set case at the entry point: the caller asked for a
    scoped run and nothing was in scope. That routes NOTHING — never the whole
    board — and the warning is what stops it looking like a crash."""
    result = _ok({"board": _two_net_board(), "scope": {"nets": ["NOSUCHNET"]}})
    assert result.get("routes") == []
    assert any("NOSUCHNET" in w.get("message", "")
               for w in result.get("warnings") or [])


def test_a_hint_and_an_explicit_scope_that_disagree_are_a_named_refusal():
    """Two scopes, two answers. Widening to the union routes past the scope the
    caller just stated; narrowing to the intersection drops a hint the caller
    authored. Both are silent reinterpretations of a stated intent, so the run
    refuses and names both sides."""
    board = _walled_board()
    error = _err({"board": board, "route_hints": [_sig_hint()],
                  "selection": {"mode": "ids", "ids": ["h_sig"]},
                  "scope": {"nets": ["EXIST"]}})
    assert error["kind"] == "unsupported_scope"
    assert "SIG" in error["message"]
    assert "EXIST" in error["message"]


def test_a_hint_and_an_explicit_scope_that_AGREE_are_fine():
    """The control for the refusal above — agreement must not be collateral
    damage, or the two arguments become mutually exclusive."""
    result = _ok({"board": _walled_board(), "route_hints": [_sig_hint()],
                  "selection": {"mode": "ids", "ids": ["h_sig"]},
                  "scope": {"nets": ["SIG"]}})
    assert _nets_of(result) == ["SIG"]


def test_a_malformed_scope_is_a_structured_error_not_a_traceback():
    error = _err({"board": _two_net_board(), "scope": {"nets": "SIG"}})
    assert error["kind"] == "unsupported_scope"
    # The message must be the structured explanation, not a stringified
    # traceback (review note: a dict-key membership check could never fail).
    assert "Traceback (most recent call last)" not in error["message"]
    assert "nets" in error["message"]


def test_scoping_a_net_out_does_not_take_its_copper_off_the_grid():
    """The standing invariant, restated for the EXPLICIT scope.

    ``test_route_scope.py`` proves it for the hint-inferred scope. The explicit
    argument is a second way to reach ``only_nets``, and a second path is a
    second chance to implement scoping by DELETING the net — which passes "only
    SIG was proposed" and fails this.
    """
    result = _ok({"board": _walled_board(), "scope": {"nets": ["SIG"]}})
    assert _nets_of(result) == ["SIG"]
    sig = [r for r in result["routes"] if r["net"] == "SIG"][0]
    assert sig["segments"], sig
    for seg in sig["segments"]:
        start = (seg["start"][0], seg["start"][1])
        end = (seg["end"][0], seg["end"][1])
        assert not drc_module._segments_intersect(
            start, end, _WALL_A, _WALL_B), (
            f"proposed SIG segment {start}->{end} crosses the out-of-scope "
            "EXIST net's accepted copper — the explicit scope has taken its "
            "copper off the grid")
    assert result["drc_geometric_summary"]["verdict"] == "clean", \
        result["drc_geometric_summary"]


# ---------------------------------------------------------------------------
# 3. PINNED-CANDIDATE COPPER as keepouts.
#
# The wall from _walled_board(), one lifecycle state earlier: the vertical run
# at x=30 from (30,5) to (30,35) is a PINNED candidate rather than an accepted
# trace. Everything else about the board — geometry, rules, the straight-line
# temptation at y=20 — is identical, so a difference in the answer is a
# difference in how pinned copper is treated and nothing else.
# ---------------------------------------------------------------------------


def _pinned_wall(**overrides) -> dict:
    """The x=30 wall as a PINNED workspace candidate on net EXIST."""
    candidate = {
        "candidate_id": "cand-wall",
        "net": "EXIST",
        "revision": 3,
        "segments": [{"id": "s1", "layer": "top", "width_mm": 0.25,
                      "points": [[30.0, 5.0], [30.0, 35.0]]}],
    }
    candidate.update(overrides)
    return candidate


def _unaccepted_walled_board() -> dict:
    """``_walled_board`` with its ACCEPTED trace removed — the wall is supplied
    as a pinned candidate instead, so the two cannot both be marking the grid."""
    board = _walled_board()
    board["traces"] = []
    return board


def test_a_pinned_candidates_copper_is_an_obstacle_for_another_net():
    """THE claim. SIG's cheapest path from U1(10,20) to J1(50,20) is the straight
    line at y=20, which crosses x=30. If the pinned candidate is invisible the
    engine takes it — and accepting that proposal shorts SIG to EXIST."""
    result = _ok({"board": _unaccepted_walled_board(),
                  "scope": {"nets": ["SIG"]},
                  "pinned_candidates": [_pinned_wall()]})
    assert _nets_of(result) == ["SIG"]
    sig = [r for r in result["routes"] if r["net"] == "SIG"][0]
    assert sig["segments"], sig
    for seg in sig["segments"]:
        start = (seg["start"][0], seg["start"][1])
        end = (seg["end"][0], seg["end"][1])
        assert not drc_module._segments_intersect(
            start, end, _WALL_A, _WALL_B), (
            f"proposed SIG segment {start}->{end} crosses the PINNED EXIST "
            "candidate — pinned draft copper is invisible to the grid")


def test_the_control_the_same_board_with_no_pinned_candidate_takes_the_straight_line():
    """Non-vacuous by construction. Without this, the test above passes on a
    board where the engine detoured for some unrelated reason."""
    result = _ok({"board": _unaccepted_walled_board(),
                  "scope": {"nets": ["SIG"]}})
    sig = [r for r in result["routes"] if r["net"] == "SIG"][0]
    crossed = any(
        drc_module._segments_intersect(
            (seg["start"][0], seg["start"][1]),
            (seg["end"][0], seg["end"][1]), _WALL_A, _WALL_B)
        for seg in sig["segments"])
    assert crossed, (
        "with NO pinned candidate the engine did not take the straight line "
        "through x=30 — the keepout test above proves nothing")


def test_a_pinned_candidate_reads_the_same_wire_shape_the_draft_check_does():
    """``[[x,y],...]`` pairs and ``{x_mm,y_mm}`` dicts are the SAME candidate
    language on both surfaces, because both go through ``ir_candidates``. A
    shape one accepts and the other silently drops is a correctness trap."""
    dict_points = _pinned_wall(segments=[{
        "id": "s1", "layer": "top", "width_mm": 0.25,
        "points": [{"x_mm": 30.0, "y_mm": 5.0}, {"x_mm": 30.0, "y_mm": 35.0}]}])
    result = _ok({"board": _unaccepted_walled_board(),
                  "scope": {"nets": ["SIG"]},
                  "pinned_candidates": [dict_points]})
    sig = [r for r in result["routes"] if r["net"] == "SIG"][0]
    for seg in sig["segments"]:
        assert not drc_module._segments_intersect(
            (seg["start"][0], seg["start"][1]),
            (seg["end"][0], seg["end"][1]), _WALL_A, _WALL_B)


_WIDTHLESS_WALL_SEGMENTS = [{"id": "s1", "layer": "top",
                             "points": [[30.0, 5.0], [30.0, 35.0]]}]


def test_a_pinned_candidate_with_no_width_falls_to_the_BOARDS_authored_default():
    """THE CONTRACT MOVED AFTER THIS FILE WAS PARKED, and this pair of tests is
    the corrected reading of it.

    As authored (unit C2) this asserted that a widthless pinned candidate is
    FATAL to the whole run. Chore ``019fc15cdf13`` then landed
    ``methods._candidate_overlay_defaults``, which states ONE precedence for
    ``build_overlay``'s fallback dimensions across both call sites (the propose/
    route path and the geometric-DRC path, which had disagreed):

      1. the entity's own declared dimensions;
      2. the RUN's effective width — only for copper THIS run produced, which a
         pinned candidate is not, so ``_route`` deliberately passes none;
      3. the BOARD's own authored routing defaults (``design_rules``), i.e. what
         the candidate would BECOME on acceptance;
      4. fail closed.

    So the run does NOT abort — and, the load-bearing half, the candidate is NOT
    invisible either. THE HAZARD THIS FILE EXISTS TO KILL IS UNSEEN COPPER, so
    that is what is asserted: the widthless ghost still marks the grid and SIG
    still detours around it. A width read from the board's own design rules is a
    real design value, not the guessed dimension the no-approximated-copper
    ruling forbids.
    """
    result = _ok({"board": _unaccepted_walled_board(),
                  "scope": {"nets": ["SIG"]},
                  "pinned_candidates": [
                      _pinned_wall(segments=_WIDTHLESS_WALL_SEGMENTS)]})
    sig = [r for r in result["routes"] if r["net"] == "SIG"][0]
    assert sig["segments"], sig
    for seg in sig["segments"]:
        assert not drc_module._segments_intersect(
            (seg["start"][0], seg["start"][1]),
            (seg["end"][0], seg["end"][1]), _WALL_A, _WALL_B), (
            f"proposed SIG segment {seg} crosses a pinned candidate that "
            "declared no width — the board-default fallback left the ghost "
            "invisible to the grid, which is the failure the fallback exists "
            "to avoid")


def test_the_fail_closed_FLOOR_still_exists_and_still_names_the_candidate():
    """Step 4 of that precedence, pinned at the layer that owns it.

    It cannot be reached THROUGH ``route``: ``compile_board`` refuses a board
    whose ``design_rules.trace_width_mm`` is absent or non-positive
    ("design_rules.trace_width_mm must be a positive number; got None"), so
    every board that reaches ``existing_copper_with_pinned`` already carries a
    positive authored default and step 3 always answers first. Asserting the
    floor through the run would therefore be asserting an unreachable state.

    It is asserted here instead, at ``existing_copper_with_pinned`` with no
    default supplied — the exact call ``_route`` makes minus the defaults — so
    the guarantee stays executable rather than becoming a comment. Both halves
    of the original claim survive: the refusal is an ``UnsupportedGeometry`` (so
    the caller's boundary turns it into a structured zero-route reply of kind
    ``unsupported_geometry``), and it NAMES the candidate and the missing
    dimension so a human can fix the right ghost.
    """
    from pcb_worker import compile_board

    compiled = compile_board.compile_board(
        _unaccepted_walled_board(),
        requested_outputs=compile_board.V1_ROUTING_OUTPUTS)
    with pytest.raises(route_bridge.UnsupportedGeometry) as excinfo:
        route_bridge.existing_copper_with_pinned(
            compiled.board,
            [_pinned_wall(segments=_WIDTHLESS_WALL_SEGMENTS)])
    message = str(excinfo.value)
    assert "cand-wall" in message
    assert "width" in message


def test_a_pinned_candidate_on_a_net_the_board_lacks_fails_closed():
    """No net means no same-net exemption and no electrical meaning; guessing
    would make the ghost conflict with its own pads."""
    error = _err({"board": _unaccepted_walled_board(),
                  "scope": {"nets": ["SIG"]},
                  "pinned_candidates": [_pinned_wall(net="NOSUCHNET")]})
    assert error["kind"] == "unsupported_geometry"
    assert "cand-wall" in error["message"]


def test_a_pinned_candidate_on_a_layer_the_board_lacks_fails_closed():
    error = _err({"board": _unaccepted_walled_board(),
                  "scope": {"nets": ["SIG"]},
                  "pinned_candidates": [_pinned_wall(segments=[{
                      "id": "s1", "layer": "in3", "width_mm": 0.25,
                      "points": [[30.0, 5.0], [30.0, 35.0]]}])]})
    assert error["kind"] == "unsupported_geometry"


@pytest.mark.parametrize("empty", [None, []])
def test_no_pinned_candidates_is_byte_for_byte_the_old_behaviour(empty):
    """The regression guard for the plumbing itself. Every existing caller sends
    no candidates, and must get the identical answer it got before the parameter
    existed — not a nearly-identical one."""
    baseline = _ok({"board": _walled_board(), "scope": {"nets": ["SIG"]}})
    with_key = _ok({"board": _walled_board(), "scope": {"nets": ["SIG"]},
                    "pinned_candidates": empty})
    assert with_key["routes"] == baseline["routes"]


def test_a_pinned_candidate_on_the_RUNS_OWN_net_is_already_connected_copper():
    """A pin is a decision, and the run must not relitigate it. Pinned copper on
    the scoped net enters as the net's OWN existing copper, so the pads it
    already joins are not proposed a second time — the same same-net treatment
    accepted copper gets, which is what makes an incremental workflow converge
    instead of re-proposing the whole net every round."""
    board = _unaccepted_walled_board()
    result = _ok({"board": board, "scope": {"nets": ["EXIST"]},
                  "pinned_candidates": [_pinned_wall()]})
    # A1(30,5) and A2(30,35) are exactly the endpoints of the pinned run, so
    # EXIST is already whole: there is nothing left to propose for it.
    assert _nets_of(result) == []
    unrouted_nets = {u.get("net") for u in result.get("unrouted") or []}
    assert "EXIST" not in unrouted_nets


def test_a_pinned_candidates_via_is_a_keepout_too():
    """Vias are copper the grid must hold on BOTH layers it spans. A candidate
    whose via is invisible lets a proposal on the far layer path straight
    through the annulus."""
    result = _ok({"board": _unaccepted_walled_board(),
                  "scope": {"nets": ["SIG"]},
                  "pinned_candidates": [_pinned_wall(vias=[{
                      "id": "v1", "position": [30.0, 20.0],
                      "diameter_mm": 0.8, "drill_mm": 0.4,
                      "from_layer": "top", "to_layer": "bottom"}])]})
    sig = [r for r in result["routes"] if r["net"] == "SIG"][0]
    for seg in sig["segments"]:
        start = (seg["start"][0], seg["start"][1])
        end = (seg["end"][0], seg["end"][1])
        # The via sits at (30,20), dead on the straight-line temptation, and its
        # copper spans BOTH layers — so no layer offers a way through it.
        assert not drc_module._segments_intersect(
            start, end, (30.0, 19.0), (30.0, 21.0)), (
            f"proposed SIG segment {start}->{end} runs through the pinned "
            "candidate's via at (30,20)")


def test_a_pinned_via_with_a_drill_wider_than_its_annulus_fails_closed():
    error = _err({"board": _unaccepted_walled_board(),
                  "scope": {"nets": ["SIG"]},
                  "pinned_candidates": [_pinned_wall(vias=[{
                      "id": "v1", "position": [30.0, 20.0],
                      "diameter_mm": 0.4, "drill_mm": 0.8,
                      "from_layer": "top", "to_layer": "bottom"}])]})
    assert error["kind"] == "unsupported_geometry"
    assert "cand-wall" in error["message"]


# ---------------------------------------------------------------------------
# 4. MANDATORY FIXTURE GATE 019f70f76c2f.
#
# Reused, not re-staged: test_route_rules' 3-pin net whose copper is two
# disconnected paths, and its committed/undone pair. Same reasoning as
# test_route_scope.py's own gate section — a near-copy of a gate fixture is how
# two files start disagreeing about what the gate covers.
# ---------------------------------------------------------------------------


def test_the_three_pin_multi_path_fixture_scopes_by_the_explicit_argument():
    """The GATE net, scoped by the ARGUMENT rather than by a hint. Its copper is
    two disconnected paths, so the "already connected, propose nothing"
    shortcut cannot mask a scope that silently widened."""
    result = _ok({"board": _three_pin_board(), "scope": {"nets": ["SIG"]}})
    assert _nets_of(result) == ["SIG"], _nets_of(result)


def test_commit_then_undo_under_an_explicitly_scoped_run_scopes_the_same_both_times():
    """The GATE's undo-after-commit half. The board's copper changes underneath
    the run; the SCOPE must not. A scope derived from board state rather than
    from the caller's argument would drift between these two calls."""
    committed = _ok({"board": _committed(_three_pin_board()),
                     "scope": {"nets": ["SIG"]}})
    undone = _ok({"board": _undone(_three_pin_board()),
                  "scope": {"nets": ["SIG"]}})
    assert _nets_of(committed) in ([], ["SIG"]), _nets_of(committed)
    assert _nets_of(undone) == ["SIG"], _nets_of(undone)
    for result in (committed, undone):
        assert all(r["net"] == "SIG" for r in result.get("routes") or [])


def test_a_pinned_candidate_on_the_gate_fixture_is_still_an_obstacle():
    """The two halves together: the GATE's multi-path net, with a pinned
    candidate in the run. Whatever the scope does, pinned copper stays on the
    grid — the same superset invariant every other keepout in this module
    obeys."""
    board = _three_pin_board()
    result = _ok({"board": board, "scope": {"nets": ["SIG"]},
                  "pinned_candidates": []})
    assert _nets_of(result) == ["SIG"], _nets_of(result)
    assert result["drc_geometric_summary"]["verdict"] == "clean", \
        result["drc_geometric_summary"]
