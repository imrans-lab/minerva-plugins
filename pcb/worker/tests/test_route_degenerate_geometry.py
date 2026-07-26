"""Round C2b — a degenerate leg the ROUTER produced blinded the geometric DRC.

Docket 019f9cc3245d (severity 2), end to end. Under ``prefer_orthogonal`` — which
is the DEFAULT for every hinted run (``agent_router.hints.GlobalHints``) — the
pathfinder skipped its direct-path strategy and built an "L" between two
axis-aligned pads. Both candidate corners of such an L land ON an endpoint, so
the emitted route carried a ZERO-LENGTH leg. Downstream,
``ir_candidates.build_overlay`` refuses to model zero-length copper, and
``check_candidates`` turns that refusal into ONE batch-wide INDETERMINATE union
returned before any per-candidate attribution — so a single straight route made
the geometric verdict unavailable for every other route proposed with it.

Measured on this module's own fixture before the fix::

    SIG segments: (10,20)->(30,20), (30,20)->(30,20), (30,20)->(50,20),
                  (50,20)->(50,20)
    drc_geometric_summary: verdict=indeterminate,
        "candidate 'route[0]' segment[1]: zero-length leg at (30.0, 20.0)"

THE FIX IS THE PRODUCER. The pathfinder no longer emits the degenerate leg (see
``agent_router/pathfinder.py``); the downstream fail-closed guard is untouched,
because relaxing it would admit degenerate copper rather than stop it being made.

THE BATCH VERDICT STAYS BATCH-WIDE. When a candidate genuinely cannot be modeled
the whole reply is still indeterminate — dropping the offender and scoring the
rest would score the survivors WITHOUT its copper, so a short between the dropped
candidate and a survivor would vanish and the survivor would come back CLEAN.
What this round adds is the offender's NAME (``error["candidate_id"]``), which is
strictly more information and changes nothing a consumer may conclude.

MANDATORY FIXTURE GATE 019f70f76c2f is discharged below on this round's OWN
fixture rather than by reusing test_route_rules.py's, because the shape the round
is about — a net whose connections are straight runs — is not the shape that file
stages. ``_straight_board`` is a 3-pin net (P1/P3/P2, collinear, so its MST is TWO
straight connections); ``_committed``/``_undone`` are the undo-after-commit round
trip, expressed the only honest way a stateless worker can.

THE VIA, HONESTLY. Verified in
``test_the_engine_emits_no_vias_of_its_own_on_this_fixture``: the real engine
produces ZERO vias here — every connection has a same-layer path, so it never
needs one. The layer-changing-via half of the gate therefore rides on STAGED
copper: ``_committed`` writes the two-paths-plus-via shape onto the board as
ACCEPTED copper, and ``_staged_via_candidate`` hands that shape to the overlay as
a proposal. Both are real exercises of the surfaces under test; NEITHER is engine
coverage of via production, and this note stays until the engine earns its
removal.
"""

from __future__ import annotations

from pcb_worker import ir_candidates, methods
from pcb_worker.ir_pads import UnsupportedGeometry
from pcb_worker.methods import handle_request

from tests.test_route_rules import _call_route, _compile, _tp


BOARD_WIDTH_MM = 0.35
BOARD_CLEARANCE_MM = 0.3
VIA_DIAMETER_MM = 0.8
VIA_DRILL_MM = 0.4


def _straight_board(**extra) -> dict:
    """THE round's fixture: a THREE-pin net whose pads are COLLINEAR.

    P1(10,20) / P3(30,20) / P2(50,20) share a row, so the net's spanning tree is
    two connections and BOTH of them are straight horizontal runs — the geometry
    that produced a degenerate leg. Multi-path (gate 019f70f76c2f) for the same
    reason: one route legitimately carries two disconnected copper paths.

    OTHER (X1/X2) is deliberately NOT axis-aligned, so it routes as a genuine
    two-segment L. It is the second candidate in the batch — the one whose verdict
    the straight route used to take down with it.
    """
    board = {
        "version": 1, "name": "c2b-straight", "width_mm": 60, "height_mm": 40,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": BOARD_CLEARANCE_MM,
                         "trace_width_mm": BOARD_WIDTH_MM,
                         "via_diameter_mm": VIA_DIAMETER_MM,
                         "via_drill_mm": VIA_DRILL_MM},
        "components": [_tp("P1", 10, 20), _tp("P3", 30, 20), _tp("P2", 50, 20),
                       _tp("X1", 12, 8), _tp("X2", 46, 6)],
        "nets": [{"name": "SIG", "pins": ["P1.1", "P2.1", "P3.1"]},
                 {"name": "OTHER", "pins": ["X1.1", "X2.1"]}],
    }
    board.update(extra)
    return board


def _hint(hint_id: str, source: str, dest: str) -> dict:
    """A guided single-trace hint.

    ITS JOB HERE IS TO SELECT THE ENGINE ENTRY POINT, not to steer the route:
    ``methods._route`` calls ``route_board_with_hints`` only when hints are
    present, and ``prefer_orthogonal`` — the flag that skips the direct-path
    strategy and so exposed the defect — lives on ``GlobalHints``, where it
    defaults to True. An unhinted run goes through ``route_board``, which never
    passes the flag; that path never had the bug and cannot demonstrate the fix.
    """
    return {"id": hint_id, "kind": "pcb_route_hint", "lifecycle": "open",
            "author": {"kind": "human"},
            "kind_payload": {"hint_type": "single_trace",
                             "detail_level": "guided", "layer": "F.Cu",
                             "source_pins": [source], "dest_pins": [dest],
                             "waypoints": []}}


def _routed(board: dict, hints: list) -> dict:
    resp = _call_route({"board": board, "route_hints": hints})
    assert resp["ok"] is True, resp
    return resp["result"]


def _segments_of(result: dict, net: str) -> list:
    routes = [r for r in result["routes"] if r["net"] == net]
    assert len(routes) == 1, [r["net"] for r in result["routes"]]
    return routes[0]["segments"]


def _degenerate(segments: list) -> list:
    return [s for s in segments if s["start"] == s["end"]]


# ---------------------------------------------------------------------------
# 1. THE HEADLINE: a straight route gets a REAL geometric verdict.
# ---------------------------------------------------------------------------


def test_a_straight_route_is_emitted_without_a_degenerate_leg():
    result = _routed(_straight_board(), [_hint("h_sig", "P1.1", "P2.1")])

    segments = _segments_of(result, "SIG")
    assert _degenerate(segments) == [], segments
    # The route is still the straight run across the three collinear pads — the
    # fix removed a stub, it did not reroute anything.
    assert [(tuple(s["start"]), tuple(s["end"])) for s in segments] == [
        ((10.0, 20.0), (30.0, 20.0)),
        ((30.0, 20.0), (50.0, 20.0)),
    ]


def test_the_geometric_verdict_for_a_straight_route_is_real_not_indeterminate():
    """THE user-visible point of the item. Before the fix this exact call returned
    ``verdict="indeterminate"`` with ``ok=False`` and the message "candidate
    'route[0]' segment[1]: zero-length leg at (30.0, 20.0)" — the check could not
    run at all, so a human deciding whether to accept had nothing to read."""
    result = _routed(_straight_board(), [_hint("h_sig", "P1.1", "P2.1")])

    summary = result["drc_geometric_summary"]
    assert summary["ok"] is True, summary.get("error")
    assert summary["verifies_geometry"] is True
    assert summary["verdict"] in ("clean", "violations")
    assert "error" not in summary
    # The route this fixture proposes is genuinely clean, so the verdict is not
    # merely "real" — it is the right one.
    assert summary["verdict"] == "clean", summary["findings"]
    assert summary["per_candidate"]["route[0]"]["verdict"] == "clean"

    # ...and the per-route stamp agrees with the summary.
    route = [r for r in result["routes"] if r["net"] == "SIG"][0]
    assert route["drc_geometric"]["verdict"] == "clean"
    assert route["drc_geometric"]["verifies_geometry"] is True


def test_a_straight_route_no_longer_blinds_the_other_candidates_in_the_batch():
    """The DOWNSTREAM harm, which is what made this severity 2 rather than
    cosmetic: ``check_candidates`` returns ONE union for the whole batch, so the
    unmodelable straight route took the L-shaped OTHER route's verdict down with
    it — a route with nothing wrong reported as uncheckable.

    Two candidates, one straight and one not, and BOTH must come back with a real
    per-candidate verdict.
    """
    result = _routed(_straight_board(),
                     [_hint("h_sig", "P1.1", "P2.1"),
                      _hint("h_other", "X1.1", "X2.1")])

    nets = sorted(r["net"] for r in result["routes"])
    assert nets == ["OTHER", "SIG"], nets
    # The premise: OTHER really is the non-degenerate neighbour, so its verdict
    # could only have been lost to SIG's geometry.
    assert _degenerate(_segments_of(result, "OTHER")) == []
    assert len(_segments_of(result, "OTHER")) == 2

    summary = result["drc_geometric_summary"]
    assert summary["ok"] is True, summary.get("error")
    verdicts = {cid: entry["verdict"]
                for cid, entry in summary["per_candidate"].items()}
    assert len(verdicts) == 2, verdicts
    assert all(v in ("clean", "violations") for v in verdicts.values()), verdicts
    for route in result["routes"]:
        assert route["drc_geometric"]["verdict"] != "indeterminate", route["net"]


# ---------------------------------------------------------------------------
# 2. When a candidate IS unmodelable, the reply says WHICH one.
# ---------------------------------------------------------------------------


def _rb():
    return _compile(_straight_board())


def _clean_candidate(cid: str = "good") -> dict:
    return {"candidate_id": cid, "revision": 1, "net": "SIG",
            "segments": [{"id": "s0", "layer": "top", "width_mm": 0.35,
                          "points": [[10.0, 30.0], [20.0, 30.0]]}]}


def test_an_unmodelable_candidate_is_named_and_the_batch_stays_indeterminate():
    """Both halves matter and they pull in opposite directions.

    NAMED: the offender is identified by id, machine-readably — a canvas showing
    three ghosts must be able to point at the one it cannot check.

    STILL BATCH-WIDE: the surviving candidates are NOT scored. Dropping "bad" and
    evaluating "good" would evaluate "good" without "bad"'s copper, so a short
    between them would disappear and "good" would be reported CLEAN. That false
    clean is precisely what fail-closed exists to prevent, so the safe verdict is
    kept and only the diagnosis is improved.
    """
    union = ir_candidates.check_candidates(
        _rb(), [_clean_candidate(), {"candidate_id": "bad", "net": "GHOST_NET",
                                     "segments": []}])

    assert union["ok"] is False
    assert union["verdict"] == "indeterminate"
    assert union["scope"] == "geometric_candidate"
    assert union["error"]["kind"] == "unsupported_geometry"
    # THE IDENTITY, not merely that something failed.
    assert union["error"]["candidate_id"] == "bad"
    assert "GHOST_NET" in union["error"]["message"]
    # Nothing a consumer could read as a verdict for the candidate that WAS
    # modelable.
    for forbidden in ("findings", "counts", "per_candidate", "clean", "baseline"):
        assert forbidden not in union, forbidden


def test_the_named_candidate_is_the_offender_and_not_just_the_first_or_last():
    """A test that only ever saw one bad candidate could pass while reporting a
    fixed index. Three candidates, the middle one bad."""
    union = ir_candidates.check_candidates(_rb(), [
        _clean_candidate("first"),
        {"candidate_id": "middle", "revision": 2, "net": "SIG",
         "segments": [{"id": "s", "layer": "top", "width_mm": 0.35,
                       "points": [[10.0, 32.0], [10.0, 32.0]]}]},
        _clean_candidate("last")])

    assert union["error"]["candidate_id"] == "middle"
    assert "zero-length leg" in union["error"]["message"]


def test_a_fault_no_candidate_owns_carries_no_candidate_id_at_all():
    """ABSENT IS NOT NULL. A candidate that is not even a mapping cannot be named
    — it has no id to name — and the key is therefore OMITTED rather than set to
    None. A consumer must be able to tell "candidate X is the offender" from "the
    offender is unknown"; a null that reads like a default would erase that."""
    union = ir_candidates.check_candidates(_rb(), ["not-a-candidate"])

    assert union["verdict"] == "indeterminate"
    assert "candidate_id" not in union["error"]
    assert "expected a mapping" in union["error"]["message"]


def test_the_named_id_survives_to_the_route_reply():
    """The name is only useful if it reaches the caller. ``_attach_route_geometric_
    drc`` copies the error envelope verbatim onto every route, so putting the id
    inside ``error`` is what makes it arrive without a new field."""
    union = ir_candidates.candidate_indeterminate(
        "unsupported_geometry", "synthetic", candidate_id="route[3]")
    assert union["error"]["candidate_id"] == "route[3]"
    assert union["scope"] == "geometric_candidate"
    assert union["verdict"] == "indeterminate"


def test_the_named_exception_is_still_an_unsupported_geometry():
    """``check_candidates`` is ``build_overlay``'s ONLY production caller, and it
    catches ``UnsupportedGeometry``; that must keep working. The subclass adds an
    attribute, it does not narrow what anyone already handles.

    (An earlier draft of this docstring also named ``methods._draft_check`` as
    such a caller. It is NOT one; the claim is withdrawn, and
    ``test_draft_check_does_not_go_through_the_candidate_overlay_at_all`` below
    replaces it with one verified by running.)
    """
    try:
        ir_candidates.build_overlay(_rb(), [{"candidate_id": "x",
                                             "net": "GHOST_NET"}])
    except UnsupportedGeometry as exc:
        assert isinstance(exc, ir_candidates.UnmodelableCandidate)
        assert exc.candidate_id == "x"
        assert "not a net of this board" in str(exc)
    else:  # pragma: no cover - the assertion is the point
        raise AssertionError("expected UnsupportedGeometry")


def test_draft_check_does_not_go_through_the_candidate_overlay_at_all():
    """VERIFIED BY RUNNING, not by reading: ``build_overlay`` is booby-trapped and
    a real ``draft_check`` request still succeeds, so that surface cannot be
    reaching it. (It runs the centerline ``drc.run_drc`` primitives instead.)

    This exists because the docstring above previously asserted the opposite, and
    an unchecked claim about who catches what is how a fail-closed boundary rots.
    """
    import pcb_worker.ir_candidates as module

    def _boom(*args, **kwargs):
        raise AssertionError("draft_check must not reach build_overlay")

    original = module.build_overlay
    module.build_overlay = _boom
    try:
        resp = handle_request({
            "id": "dc", "method": "draft_check",
            "params": {"board": _straight_board(),
                       "candidates": [_clean_candidate("cand-1")],
                       "board_token": "sha256:abc", "workspace_generation": 1}})
    finally:
        module.build_overlay = original

    assert resp["ok"] is True, resp
    assert "cand-1" in resp["result"]["per_candidate"]


# ---------------------------------------------------------------------------
# 2b. Per-ROUTE attribution: the offender is named once, and only once.
# ---------------------------------------------------------------------------


def _two_route_payload() -> dict:
    """Two proposed routes where the FIRST is unmodelable (zero-length leg) and
    the second is ordinary copper. The batch therefore fails, and every route's
    envelope has to say something about a fault that belongs to route[0]."""
    return {"routes": [
        {"net": "SIG", "segments": [
            {"id": "s0", "layer": "F.Cu", "start": [10.0, 20.0],
             "end": [10.0, 20.0]}], "vias": []},
        {"net": "OTHER", "segments": [
            {"id": "s0", "layer": "F.Cu", "start": [12.0, 8.0],
             "end": [46.0, 8.0]}], "vias": []},
    ]}


def test_each_route_carries_its_own_identity_and_the_offender_is_named_once():
    """THE MISATTRIBUTION GUARD. One envelope copied onto every route made
    route[1] report ``candidate_id: "route[0]"`` — confidently naming the wrong
    offender, which is worse than the anonymity it replaced because it sends
    someone to fix a route that is fine.

    Asserting "some id is present" would not have caught that. These assertions
    are about WHICH id lands WHERE.
    """
    payload = _two_route_payload()
    methods._attach_route_geometric_drc(payload, _rb(), trace_width_mm=0.35)

    summary = payload["drc_geometric_summary"]
    assert summary["verdict"] == "indeterminate"
    assert summary["error"]["candidate_id"] == "route[0]"

    first, second = payload["routes"][0], payload["routes"][1]

    # Each route knows WHICH route it is...
    assert first["drc_geometric"]["candidate_id"] == "route[0]"
    assert second["drc_geometric"]["candidate_id"] == "route[1]"

    # ...and both name the SAME single offender, which is route[0].
    assert first["drc_geometric"]["error"]["candidate_id"] == "route[0]"
    assert second["drc_geometric"]["error"]["candidate_id"] == "route[0]"

    # So the discriminator a consumer needs actually discriminates: route[0] is
    # the offender, route[1] was merely blinded by it.
    assert first["drc_geometric"]["candidate_id"] == \
        first["drc_geometric"]["error"]["candidate_id"]
    assert second["drc_geometric"]["candidate_id"] != \
        second["drc_geometric"]["error"]["candidate_id"]

    # Both are still honestly indeterminate — naming the offender must not be
    # mistaken for scoring the survivor.
    for route in payload["routes"]:
        assert route["drc_geometric"]["verdict"] == "indeterminate"
        assert route["drc_geometric"]["verifies_geometry"] is False


def test_no_two_routes_share_one_error_object():
    """The envelopes must be COPIES, not aliases: a consumer that annotates one
    route's error must not silently rewrite another's."""
    payload = _two_route_payload()
    methods._attach_route_geometric_drc(payload, _rb(), trace_width_mm=0.35)

    first, second = payload["routes"][0], payload["routes"][1]
    assert first["drc_geometric"]["error"] is not second["drc_geometric"]["error"]

    first["drc_geometric"]["error"]["candidate_id"] = "MUTATED"
    assert second["drc_geometric"]["error"]["candidate_id"] == "route[0]"


# ---------------------------------------------------------------------------
# 3. MANDATORY FIXTURE GATE 019f70f76c2f — 3+ pin multi-path net, a
#    layer-changing via, and undo-after-commit. See the module docstring for
#    which halves are engine-produced and which are staged.
# ---------------------------------------------------------------------------


def _committed(board: dict) -> dict:
    """The board with a proposal ACCEPTED onto it: TWO DISCONNECTED copper paths
    (one per layer) joined by a LAYER-CHANGING VIA at (40, 20).

    P1 -> top copper -> via -> bottom copper -> P2, with P3 still unrouted, so
    the net keeps genuine remaining work. The via is the only thing holding the
    two halves together — the shape gate 019f70f76c2f exists to force.
    """
    out = dict(board)
    out["traces"] = [
        {"net": "SIG", "layer": "top", "width_mm": BOARD_WIDTH_MM,
         "points": [{"x_mm": 10.0, "y_mm": 20.0}, {"x_mm": 10.0, "y_mm": 28.0},
                    {"x_mm": 40.0, "y_mm": 28.0}, {"x_mm": 40.0, "y_mm": 20.0}]},
        {"net": "SIG", "layer": "bottom", "width_mm": BOARD_WIDTH_MM,
         "points": [{"x_mm": 40.0, "y_mm": 20.0}, {"x_mm": 50.0, "y_mm": 20.0}]},
    ]
    out["vias"] = [{"net": "SIG", "x_mm": 40.0, "y_mm": 20.0,
                    "diameter_mm": VIA_DIAMETER_MM, "drill_mm": VIA_DRILL_MM,
                    "from_layer": "top", "to_layer": "bottom"}]
    return out


def _undone(board: dict) -> dict:
    """...and the commit taken back off. Traces and vias leave TOGETHER — an undo
    that dropped only the traces would strand the via (F1, 019f70f76c2f)."""
    out = dict(board)
    out.pop("traces", None)
    out.pop("vias", None)
    return out


def _staged_via_candidate() -> dict:
    """The mandatory via shape as a PROPOSAL, staged by hand.

    STAGED, NOT ENGINE-PRODUCED — the engine emits no vias on this fixture (see
    ``test_the_engine_emits_no_vias_of_its_own_on_this_fixture``, which asserts
    that rather than asking anyone to take it on trust). What it pins is that a
    multi-path candidate carrying a layer-changing via reaches a REAL verdict on
    the round's own fixture, and that a finding lands on the via specifically.
    """
    return {"candidate_id": "staged-via", "revision": "r1", "net": "SIG",
            "segments": [
                {"id": "top-run", "layer": "top", "width_mm": BOARD_WIDTH_MM,
                 "points": [[10.0, 20.0], [10.0, 28.0], [40.0, 28.0],
                            [40.0, 20.0]]},
                {"id": "bot-run", "layer": "bottom", "width_mm": BOARD_WIDTH_MM,
                 "points": [[40.0, 20.0], [50.0, 20.0]]}],
            "vias": [{"id": "v0", "position": [40.0, 20.0],
                      "diameter_mm": VIA_DIAMETER_MM, "drill_mm": VIA_DRILL_MM,
                      "from_layer": "top", "to_layer": "bottom"}]}


def test_the_engine_emits_no_vias_of_its_own_on_this_fixture():
    """The honest caveat the module docstring makes, as an assertion rather than a
    claim. If the engine ever DOES need a via here, this fails and the docstring
    must be rewritten instead of quietly rotting."""
    result = _routed(_straight_board(), [_hint("h_sig", "P1.1", "P2.1")])
    assert result["via_count"] == 0
    assert all(r["vias"] == [] for r in result["routes"])


def test_the_staged_multi_path_via_candidate_reaches_a_real_verdict():
    union = ir_candidates.check_candidates(_rb(), [_staged_via_candidate()])

    assert union["ok"] is True, union.get("error")
    assert union["verdict"] in ("clean", "violations")
    assert union["per_candidate"]["staged-via"]["verdict"] in ("clean", "violations")


def test_the_staged_via_is_modeled_as_copper_and_a_hole_and_is_attributable():
    """The via must be REAL geometry in the overlay, not a marker — otherwise a
    "real verdict" above would be real about the traces only. Dropped onto P3's
    through-hole pad (net SIG's own pad is at (30,20); OTHER's are elsewhere), so
    move it where it must collide: X1's pad. Both the copper rule and the hole
    rule must fire, and both must name the via."""
    candidate = dict(_staged_via_candidate(),
                     vias=[{"id": "v0", "position": [12.0, 8.0],
                            "diameter_mm": VIA_DIAMETER_MM,
                            "drill_mm": VIA_DRILL_MM,
                            "from_layer": "top", "to_layer": "bottom"}])
    union = ir_candidates.check_candidates(_rb(), [candidate])

    assert union["verdict"] == "violations"
    via_findings = [f for f in union["findings"]
                    if any(s.get("via_id") == "v0" for s in f["subjects"])]
    assert via_findings, union["findings"]
    types = {f["type"] for f in via_findings}
    assert "gc2_copper_clearance" in types    # via land vs X1's land
    assert "gc6_hole_to_hole" in types        # via drill vs X1's drill
    for finding in via_findings:
        assert {"candidate_id": "staged-via", "revision": "r1", "via_id": "v0"} \
            in finding["subjects"]


def test_commit_then_undo_keeps_every_verdict_real():
    """MANDATORY undo-after-commit, in the only honest worker-side form: the
    worker holds no state, so "undo" is the board losing the copper a commit
    added.

    What must hold across the round trip is the property this round establishes —
    the run's proposal is geometrically CHECKABLE at every step. A commit changes
    the copper census and therefore what is left to route; it must never change
    whether the geometric check can run. (Before the fix, every one of these three
    calls came back indeterminate.)
    """
    board = _straight_board()
    hints = [_hint("h_sig", "P1.1", "P2.1")]

    before = _routed(board, hints)
    committed = _routed(_committed(board), hints)
    after = _routed(_undone(_committed(board)), hints)

    for label, result in (("before", before), ("committed", committed),
                          ("after-undo", after)):
        summary = result["drc_geometric_summary"]
        assert summary["ok"] is True, (label, summary.get("error"))
        assert summary["verdict"] in ("clean", "violations"), label
        for route in result["routes"]:
            assert _degenerate(route["segments"]) == [], (label, route["net"])
            assert route["drc_geometric"]["verdict"] != "indeterminate", label

    # The undo really did restore the starting point: same nets proposed, same
    # copper, as the before-commit run.
    assert [r["net"] for r in after["routes"]] == [r["net"] for r in before["routes"]]
    assert _segments_of(after, "SIG") == _segments_of(before, "SIG")
    # ...and the committed board in between was genuinely different, or the round
    # trip proved nothing.
    assert _segments_of(committed, "SIG") != _segments_of(before, "SIG")
