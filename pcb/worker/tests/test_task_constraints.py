"""Task-owned steering CONSUMPTION (Epoch UX1 station 9, DCR 019fd095e694).

Station 8 (docket comment 1042) landed PcbRouteTask.routing_constraint —
durable, revision-tracked corridor storage on the routing TASK, round-tripped
but never READ by the router: "propose/router reading it (constraint
CONSUMPTION) is station 9". This station is that read side.

route_bridge.hints_to_router gains an optional `task_constraints` map —
``{hint_id: {corridor_points, preferred_layer, revision}}``, built panel-side
(panel_tools.gd's ``_task_constraints_for_hints``) from each SELECTED hint's
own task. When an entry names a hint it OVERRIDES that hint's legacy
``kind_payload.waypoints`` channel entirely: the constraint's corridor and
preferred_layer are what the engine follows, and the resulting
ConnectionHint / corridor_adherence entry / per-route dict all cite the
constraint's revision (station 9's "candidates cite the revision" half,
methods.py attaching `constraint_revision` exactly like it already attaches
`corridor_adherence`). A hint with NO entry — the overwhelming majority of
calls, since task_constraints is entirely additive — is completely untouched:
same corridor (its own legacy waypoints, or none), no `constraint_revision`
key anywhere, byte-identical to a pre-station call.

Same conventions as test_route_bridge.py (pure bridge calls against
`hints_to_router` directly) and test_route_as_drawn.py (the `route()` method
end to end via handle_request, against a compilable IR board).
"""

from __future__ import annotations

import pytest

from pcb_worker import route_bridge
from pcb_worker.methods import handle_request


def _call(method: str, params: dict) -> dict:
    resp = handle_request({"id": "r1", "method": method, "params": params})
    assert resp is not None and resp["id"] == "r1"
    return resp


# ---------------------------------------------------------------------------
# Pure bridge — hints_to_router(..., task_constraints=...)
# ---------------------------------------------------------------------------


def _rotated_board() -> dict:
    """Same two-pad, one-net board test_route_bridge.py's rotation test uses.

    U1.2 lands at (10.0, 17.46), R1.1 at (10.0, 20.0), net "SIG" — duplicated
    here rather than imported (test_route_bridge.py's fixtures are module-
    private helpers, same convention test_route_as_drawn.py already follows
    by defining its own board fixtures instead of cross-importing).
    """
    return {
        "version": 1,
        "name": "RotTest",
        "width_mm": 40,
        "height_mm": 30,
        "components": [
            {"ref": "U1", "footprint": "IC", "x_mm": 10, "y_mm": 20,
             "rotation_deg": 90, "layer": "top",
             "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0,
                       "pad_width_mm": 1.0, "pad_height_mm": 1.0},
                      {"number": "2", "x_mm": 2.54, "y_mm": 0.0,
                       "pad_width_mm": 1.0, "pad_height_mm": 1.0}]},
            {"ref": "R1", "footprint": "R", "x_mm": 10, "y_mm": 5,
             "rotation_deg": 0, "layer": "top",
             "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0,
                       "pad_width_mm": 1.0, "pad_height_mm": 1.0},
                      {"number": "2", "x_mm": 1.0, "y_mm": 0.0,
                       "pad_width_mm": 1.0, "pad_height_mm": 1.0}]},
        ],
        "nets": [{"name": "SIG", "pins": ["U1.2", "R1.1"]}],
    }


def _route_hint(**payload) -> dict:
    """Minimal conformant pcb_route_hint envelope (test_route_bridge.py's own
    helper, duplicated for the same module-privacy reason as the board above).
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


_LEGACY_WPS = [[11.0, 18.0]]
_CONSTRAINT_WPS = [[9.5, 19.0], [9.8, 18.2]]


def test_task_constraint_overrides_legacy_waypoints():
    """An entry for this hint wins over its OWN kind_payload.waypoints."""
    board = route_bridge.board_to_router(_rotated_board())
    env = _route_hint(source_pins=["U1.2"], dest_pins=["R1.1"],
                      waypoints=[list(w) for w in _LEGACY_WPS])
    out = route_bridge.hints_to_router(
        [env], board, task_constraints={
            "ann1": {"corridor_points": [list(w) for w in _CONSTRAINT_WPS],
                     "preferred_layer": "B.Cu", "revision": 3},
        })

    assert len(out.hints.connection_hints) == 1
    ch = out.hints.connection_hints[0]
    got = [[w.x, w.y] for w in ch.waypoints]
    assert got == _CONSTRAINT_WPS, "the constraint corridor must win, not the hint's own waypoints"
    assert ch.preferred_layer == "B.Cu"
    assert ch.constraint_revision == 3
    assert ch.hint_id == "ann1"
    # F2 (cold review, Epoch UX1 station 9): the hint's own legacy
    # kind_payload.waypoints is non-empty AND the override applied — that
    # field is now dead for routing, and the bridge says so via a structured
    # per-hint note (rides hint_status via panel_tools.gd's existing
    # _attach_hint_status lift; no GDScript change needed for the lift).
    assert out.warnings == [{
        "id": "ann1",
        "waypoint_status": "superseded_by_task_constraint",
        "constraint_revision": 3,
    }]


def test_no_task_constraints_entry_is_byte_identical_to_legacy():
    """No entry for this hint id ⇒ unchanged legacy path, no revision anywhere."""
    board = route_bridge.board_to_router(_rotated_board())
    env = _route_hint(source_pins=["U1.2"], dest_pins=["R1.1"],
                      waypoints=[list(w) for w in _LEGACY_WPS])

    baseline = route_bridge.hints_to_router([env], board)
    overridden_elsewhere = route_bridge.hints_to_router(
        [env], board, task_constraints={"some_other_hint": {
            "corridor_points": [[0.0, 0.0]], "revision": 1}})

    for out in (baseline, overridden_elsewhere):
        assert len(out.hints.connection_hints) == 1
        ch = out.hints.connection_hints[0]
        got = [[w.x, w.y] for w in ch.waypoints]
        assert got == _LEGACY_WPS
        assert ch.preferred_layer == "F.Cu"
        assert ch.constraint_revision is None, \
            "no task_constraints entry named this hint — no revision may appear"


def test_malformed_task_constraints_entry_falls_back_to_legacy():
    """An entry that IS present but carries no usable corridor degrades to
    'no override' rather than blanking the hint's own waypoints — a caller
    stating an empty/garbled corridor must not silently kill legacy geometry.
    """
    board = route_bridge.board_to_router(_rotated_board())
    env = _route_hint(source_pins=["U1.2"], dest_pins=["R1.1"],
                      waypoints=[list(w) for w in _LEGACY_WPS])

    for bad_entry in ({"corridor_points": [], "revision": 1}, {"revision": 1}, "not-a-dict", None):
        out = route_bridge.hints_to_router(
            [env], board, task_constraints={"ann1": bad_entry})
        ch = out.hints.connection_hints[0]
        got = [[w.x, w.y] for w in ch.waypoints]
        assert got == _LEGACY_WPS, bad_entry
        assert ch.constraint_revision is None, bad_entry


def test_task_constraint_alone_supplies_the_corridor():
    """The intent tool (station 8) never puts waypoints on the hint — the
    constraint is the ONLY source of corridor geometry for such a hint, and
    that must be sufficient (no legacy waypoints required to accompany it).
    """
    board = route_bridge.board_to_router(_rotated_board())
    env = _route_hint(source_pins=["U1.2"], dest_pins=["R1.1"], waypoints=[])
    out = route_bridge.hints_to_router(
        [env], board, task_constraints={
            "ann1": {"corridor_points": [list(w) for w in _CONSTRAINT_WPS], "revision": 1},
        })
    assert len(out.hints.connection_hints) == 1
    ch = out.hints.connection_hints[0]
    assert [[w.x, w.y] for w in ch.waypoints] == _CONSTRAINT_WPS
    assert ch.constraint_revision == 1


def test_task_constraint_still_subject_to_single_endpoint_contract():
    """A constraint-supplied corridor is refused the SAME way an ambiguous
    legacy waypoint span is (amendment A5) — the override does not bypass the
    gate, it only changes which corridor reaches it.
    """
    board = route_bridge.board_to_router(_rotated_board())
    env = _route_hint(source_pins=["U1.2"], dest_pins=[], waypoints=[])
    out = route_bridge.hints_to_router(
        [env], board, task_constraints={
            "ann1": {"corridor_points": [[9.0, 18.0]], "revision": 1},
        })
    assert out.hints.connection_hints == []
    refusal = [w for w in out.warnings if w.get("reason") == "ambiguous_span"]
    assert len(refusal) == 1, out.warnings


# ---------------------------------------------------------------------------
# route() method — end to end through handle_request (methods.py attach)
# ---------------------------------------------------------------------------


def _ir_two_pin_board() -> dict:
    """Same compilable two-header/one-net IR fixture test_route_as_drawn.py
    uses for its guided-hint case (real footprint, real pad "1")."""
    return {
        "version": 1,
        "name": "station9-ir",
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


# The same up-and-over corridor test_route_as_drawn.py's guided-hint case
# proves the engine actually follows (product-state A*) — reused so this
# station's "the constraint corridor is honoured" claim rides a fixture
# already known to route cleanly, not a hand-picked new shape.
_CORRIDOR = [[15.27, 14.93], [15.32, 9.84], [33.26, 15.18], [45.99, 10.09]]


def _guided_hint_no_waypoints(_id: str = "g1") -> dict:
    return {"id": _id, "kind": "pcb_route_hint", "lifecycle": "open",
            "author": {"kind": "human"},
            "kind_payload": {"hint_type": "waypoint", "detail_level": "guided",
                             "layer": "F.Cu", "source_pins": ["U1.1"],
                             "dest_pins": ["J1.1"], "waypoints": []}}


def _guided_hint_with_legacy_waypoints(pts: list, _id: str = "g1") -> dict:
    env = _guided_hint_no_waypoints(_id)
    env["kind_payload"]["waypoints"] = [list(w) for w in pts]
    return env


def test_route_method_task_constraint_steers_and_echoes_revision():
    """The station's headline claim: corridor honoured, adherence reported,
    constraint_revision echoed — both per-route and per-adherence-entry.
    """
    resp = _call("route", {
        "board": _ir_two_pin_board(),
        "route_hints": [_guided_hint_no_waypoints()],
        "selection": {"mode": "open"},
        "task_constraints": {"g1": {
            "corridor_points": [list(w) for w in _CORRIDOR],
            "revision": 5,
        }},
    })
    assert resp["ok"] is True, resp
    r = resp["result"]
    assert r["success"] is True

    sig = [rt for rt in r["routes"] if rt["net"] == "SIG"]
    assert len(sig) == 1
    route = sig[0]

    # Per-route key (methods.py attaches it exactly like corridor_adherence).
    assert route.get("constraint_revision") == 5

    adherence = route.get("corridor_adherence", [])
    assert len(adherence) == 1, route
    a = adherence[0]
    assert a["hint_id"] == "g1"
    assert a["constraint_revision"] == 5
    assert a["status"] in ("honored", "partial")
    assert a["skipped_waypoints"] == []
    assert all(w["within_tolerance"] for w in a["per_waypoint"]), a

    # No stale "waypoints ignored" noise for a corridor that WAS honoured.
    assert not [w for w in r.get("warnings", []) if w.get("waypoint_status") == "ignored"]


def test_route_method_revision_zero_survives_the_full_wire():
    """F9 (cold review): revision 0 is a LEGITIMATE value — a task's very
    first constraint, or a caller that simply passed 0 — and must survive
    every hop of the wire (route_bridge -> router.py -> methods.py) exactly
    like any other revision. Every attachment site along that path used to
    (or, for route_bridge/router.py, always did) test `is not None`; the one
    holdout was methods.py's per-route attach, which tested TRUTHINESS and
    so silently dropped a 0 — indistinguishable from "no task steered this".
    This asserts the key is PRESENT (not just absent-safe) at both the
    per-route and per-adherence-entry sites for revision 0 specifically.
    """
    resp = _call("route", {
        "board": _ir_two_pin_board(),
        "route_hints": [_guided_hint_no_waypoints()],
        "selection": {"mode": "open"},
        "task_constraints": {"g1": {
            "corridor_points": [list(w) for w in _CORRIDOR],
            "revision": 0,
        }},
    })
    assert resp["ok"] is True, resp
    r = resp["result"]
    assert r["success"] is True

    sig = [rt for rt in r["routes"] if rt["net"] == "SIG"]
    assert len(sig) == 1
    route = sig[0]

    assert "constraint_revision" in route, route
    assert route["constraint_revision"] == 0

    adherence = route.get("corridor_adherence", [])
    assert len(adherence) == 1, route
    assert "constraint_revision" in adherence[0]
    assert adherence[0]["constraint_revision"] == 0


def test_route_method_no_task_constraints_is_byte_identical():
    """No `task_constraints` key at all in the request ⇒ the LEGACY guided-hint
    path runs exactly as it did before this station (corridor from the hint's
    own waypoints, adherence reported) with no `constraint_revision` anywhere
    in the reply — the additive-key, no-regression contract. Uses the SAME
    hint the override test steers via task_constraints, but as its own legacy
    waypoints, so this is a true "same corridor, no constraint" control.
    """
    resp = _call("route", {
        "board": _ir_two_pin_board(),
        "route_hints": [_guided_hint_with_legacy_waypoints(_CORRIDOR)],
        "selection": {"mode": "open"},
    })
    assert resp["ok"] is True, resp
    r = resp["result"]
    sig = [rt for rt in r["routes"] if rt["net"] == "SIG"]
    assert len(sig) == 1
    route = sig[0]
    assert "constraint_revision" not in route
    adherence = route.get("corridor_adherence", [])
    assert len(adherence) == 1, route
    assert "constraint_revision" not in adherence[0]


# ---------------------------------------------------------------------------
# HITL-4 (docs/llm-ergonomics.md F4): the detail_level warning must not fire on
# a constraint-steered hint.
#
# Intent-minted hints NEVER carry waypoints — their steering rides
# task_constraints — and every one of them carries a detail_level. During the
# F0 live diagnosis the bridge drew "detail_level 'sparse' has no agent_router
# slot … not engine behaviour" on exactly those hints, implying the corridor
# might not steer on exactly the hints where it does: an active red herring.
# The warning used to be emitted BEFORE the constraint override was computed,
# so it could not know better; it is now computed after, and gated on the SAME
# constraint_pts predicate the override itself runs on. The constraint-steered
# path already reports itself (superseded_by_task_constraint /
# constraint_revision stamping), so suppression removes a lie, not a signal.
# ---------------------------------------------------------------------------

_SLOT_WARNING = "has no agent_router slot"


def _slot_warnings(out) -> list[dict]:
    return [w for w in out.warnings if _SLOT_WARNING in w.get("message", "")]


def test_a_constraint_steered_sparse_hint_draws_no_slot_warning():
    """The reproduction: an intent-minted-shaped hint (detail_level 'sparse',
    NO waypoints of its own, steering in task_constraints) must not be told
    its detail_level 'selects the bridge path, not engine behaviour' — the
    constraint corridor IS engine behaviour, and it applied."""
    board = route_bridge.board_to_router(_rotated_board())
    env = _route_hint(source_pins=["U1.2"], dest_pins=["R1.1"],
                      detail_level="sparse")
    out = route_bridge.hints_to_router(
        [env], board, task_constraints={
            "ann1": {"corridor_points": [list(w) for w in _CONSTRAINT_WPS],
                     "preferred_layer": "F.Cu", "revision": 1},
        })
    assert _slot_warnings(out) == [], out.warnings
    # …and the steering it would have cast doubt on really did land: the
    # constraint's own reporting channel carries the story instead.
    assert len(out.hints.connection_hints) == 1
    assert out.hints.connection_hints[0].constraint_revision == 1


def test_an_unconstrained_sparse_hint_still_draws_the_warning_verbatim():
    """Negative gate: with no constraint applying, the warning is exactly what
    it always was — the honest bridge-path note stays for the hints it is
    true of."""
    board = route_bridge.board_to_router(_rotated_board())
    env = _route_hint(source_pins=["U1.2"], dest_pins=["R1.1"],
                      detail_level="sparse")
    out = route_bridge.hints_to_router([env], board)
    warnings = _slot_warnings(out)
    assert len(warnings) == 1, out.warnings
    assert warnings[0]["message"] == (
        "detail_level 'sparse' has no agent_router slot — it selects the "
        "bridge path (only 'detailed' single-trace hints route as "
        "drawn), not engine behaviour")


def test_a_refused_constraint_entry_keeps_the_warning():
    """A task_constraints entry that does NOT apply (unusable corridor_points
    — the same 'no override' degrade every malformed entry takes) leaves the
    hint on the legacy path, so the warning stays true and stays emitted."""
    board = route_bridge.board_to_router(_rotated_board())
    env = _route_hint(source_pins=["U1.2"], dest_pins=["R1.1"],
                      detail_level="sparse")
    out = route_bridge.hints_to_router(
        [env], board,
        task_constraints={"ann1": {"corridor_points": "not-points"}})
    assert len(_slot_warnings(out)) == 1, out.warnings
