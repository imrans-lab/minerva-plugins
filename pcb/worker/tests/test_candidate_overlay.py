"""Typed candidate-copper overlay — geometric feedback BEFORE acceptance.

Docket 019f952b99f2, closing bug 019f80b5124d: a routing proposal ran a trace
straight through the centre of a different-net pad, shorting two nets, and the
DRC attached to that proposal reported it CLEAN. Connectivity's check A only
looked at trace ENDPOINTS then, so a run driven THROUGH a pad said nothing; it
reads the whole run now and names this one. What connectivity still cannot do is
measure copper EXTENT — geometric DRC detects that exactly, but only ever ran on
ACCEPTED copper.

BASELINE ROBUSTNESS. ``parity_corners.yaml`` (docket 019fbe68c5f8 — replaces the
withdrawn product board ``smart_remote.yaml``, see testdata/POLICY.md) already
carries 6 geometric violations of its own, incidentally: it was authored to reach
parity-gate geometry classes, not to be DRC-clean, and a couple of its library
footprint's un-overridden pins land close enough to routed copper to trip
gc2/gc5 on their own. Nothing here fixes that — it plays exactly the role
smart_remote's 12 incidental violations used to play. Every assertion below is
therefore about the DELTA a candidate introduces, or about a specific attributed
finding. Nothing asserts "clean" on a whole board, and no count is hard-coded
against the fixture's own dirt.
"""

from __future__ import annotations

import yaml

from pcb_worker import board_model, compile_board, ir_candidates
from pcb_worker.ir_pads import UnsupportedGeometry
from pcb_worker.methods import handle_request

PARITY_CORNERS = "tests/testdata/parity_corners.yaml"


def _parity_corners_dict() -> dict:
    with open(PARITY_CORNERS) as fh:
        return yaml.safe_load(fh)


def _compile(board: dict):
    result = compile_board.compile_board(board)
    assert isinstance(result, compile_board.ResolutionSuccess), result
    return result.board


def _compiled_parity_corners():
    return _compile(board_model.load_board({"yaml": yaml.safe_dump(_parity_corners_dict())}))


# A DELIBERATE short, built the same way bug 019f80b5124d looked in the wild: a
# candidate trace on one net (N_OBL) running straight through a placed pad that
# belongs to a DIFFERENT, real net (SW9 pad B, N_BOT). Unlike smart_remote's
# MIC1/I2S short, this is not an accident the fixture happened to contain — it is
# constructed here on purpose, because parity_corners is not otherwise dirty in
# this specific spot (docket 019fbe68c5f8: repointing away from a withdrawn
# product board must not quietly stop exercising the thing the test proves).
SHORTING_SEGMENT = {
    "id": "seg-0", "layer": "top", "width_mm": 0.3,
    "points": [[10.0, 16.0], [10.0, 22.0]],
}


def _shorting_candidate(candidate_id: str = "ghost-1", revision=7) -> dict:
    return {"candidate_id": candidate_id, "revision": revision, "net": "N_OBL",
            "segments": [dict(SHORTING_SEGMENT)]}


def _sw9_padB_findings(findings: list) -> list:
    """Findings that name SW9 pad B AND the trespassing net — the short itself."""
    out = []
    for f in findings:
        participants = f.get("participants") or []
        names = {(p.get("ref"), p.get("pad")) for p in participants}
        nets = {p.get("net_name") for p in participants}
        if ("SW9", "B") in names and nets == {"N_OBL", "N_BOT"}:
            out.append(f)
    return out


# ---------------------------------------------------------------------------
# THE HEADLINE: the shorting proposal is caught BEFORE acceptance.
# ---------------------------------------------------------------------------


def test_shorting_proposal_is_caught_before_acceptance():
    rb = _compiled_parity_corners()
    union = ir_candidates.check_candidates(rb, [_shorting_candidate()])

    # Case (b): the check RAN and found violations — unmistakably geometric, and
    # unmistakably NOT the connectivity scope today's propose DRC carries.
    assert union["ok"] is True
    assert union["scope"] == "geometric_candidate"
    assert union["verifies_geometry"] is True
    assert union["verdict"] == "violations"

    shorts = _sw9_padB_findings(union["findings"])
    assert len(shorts) == 1, union["findings"]
    short = shorts[0]
    assert short["type"] == "gc2_copper_clearance"
    # Measured, attributed, and located — not merely "something is wrong".
    assert short["measured_mm"] == -0.15
    assert short["required_mm"] == 0.2
    # Canonical witness: the land's short edges at y 17.8 / 20.2 are equally deep
    # crossings of the shorting run, so _overlap_point returns the lexicographic
    # minimum — stable whichever way the rotation winds the rect's corners.
    assert short["closest"] == [10.0, 17.8]
    assert short["layer"] == "top"

    # Attribution back to the specific ghost route + its revision, so a canvas can
    # highlight THAT trace and detect a stale result.
    assert {"candidate_id": "ghost-1", "revision": 7, "segment_id": "seg-0"} \
        in short["subjects"]
    assert {"candidate_id": "board"} in short["subjects"]

    per_candidate = union["per_candidate"]["ghost-1"]
    assert per_candidate["verdict"] == "violations"
    assert per_candidate["revision"] == 7
    assert per_candidate["finding_count"] == len(union["findings"])


def test_connectivity_drc_names_the_short_but_cannot_measure_it():
    """The division of labour, measured rather than assumed.

    This used to assert connectivity reported the shorting proposal CLEAN, on the
    premise that "a centerline checker cannot represent this". Measured, that
    premise was false for THIS geometry: SW9 pad B's centre is (10.0, 19.0) and
    the candidate centerline runs straight through it, so the fault was visible to
    a centerline kernel all along — only check A's endpoint-only scope hid it.
    With check A reading the whole run, connectivity NAMES the short.

    What it still cannot do is MEASURE it: the geometric surface reports the
    copper-edge overlap (measured_mm/required_mm above) off real pad and trace
    extents, which is the fault class a centre-to-centerline test genuinely cannot
    represent — a trace that misses a pad's centre by more than clearance while
    its copper still overlaps the land."""
    from pcb_worker.methods import _attach_route_drc
    from pcb_worker import ir_connectivity

    rb = _compiled_parity_corners()
    payload = {"routes": [{"net": "N_OBL", "segments": [
        {"layer": "top", "start": [10.0, 16.0], "end": [10.0, 22.0]}]}]}
    _attach_route_drc(payload, ir_connectivity.connectivity_board(rb))
    route_drc = payload["routes"][0]["drc"]
    assert route_drc["scope"] == "connectivity"
    shorts = [v for v in route_drc["violations"] if v.get("type") == "wrong_net_pad"]
    assert shorts == [{"type": "wrong_net_pad", "net": "N_OBL", "at": [10.0, 19.0],
                       "pad": {"ref": "SW9", "pin": "B", "net": "N_BOT"}}]
    assert all("measured_mm" not in v for v in shorts)


# ---------------------------------------------------------------------------
# PROPOSE-TIME == POST-ACCEPT. The same geometry, checked both ways.
# ---------------------------------------------------------------------------


def _comparable(finding: dict) -> dict:
    """A finding stripped of IR identity, so a candidate's synthetic entity ids can
    be compared against the ids the compiler mints for an accepted trace. What
    remains is everything a human or a canvas actually reads.

    PAIR ORDER IS NORMALIZED, deliberately. GC2/GC6 order the two sides of a pair
    by opaque entity_id (drc_geometric ``lo, hi``), and a candidate's id is not the
    id the compiler will mint once it is accepted — so the SAME collision can be
    reported as (pad, trace) before acceptance and (trace, pad) after, swapping
    ``closest``/``witness`` with it. That is presentation, not measurement: the
    pair, the rule, the measured margin and the location are identical. A consumer
    that draws the pair must not depend on the order either."""
    keep = {k: v for k, v in finding.items()
            if k not in ("entity_id", "parent", "participants", "subjects",
                         "closest", "witness", "entities")}
    keep["participants"] = sorted(
        ({pk: pv for pk, pv in p.items()
          if pk not in ("entity_id", "parent", "net_id")}
         for p in finding.get("participants") or []),
        key=repr)
    keep["endpoints"] = sorted([finding.get("closest"), finding.get("witness")],
                               key=repr)
    return keep


def test_proposed_and_accepted_geometry_produce_the_identical_finding():
    """The proposal and the same trace accepted into the board must agree — the
    whole point of overlaying at the IR level instead of re-deriving primitives."""
    rb = _compiled_parity_corners()
    proposed = ir_candidates.check_candidates(rb, [_shorting_candidate()])

    accepted_src = _parity_corners_dict()
    accepted_src["traces"].append({
        "net": "N_OBL", "layer": "top", "width_mm": 0.3,
        "points": [{"x_mm": 10.0, "y_mm": 16.0}, {"x_mm": 10.0, "y_mm": 22.0}]})
    accepted = handle_request({"id": "a", "method": "drc_geometric",
                               "params": {"yaml": yaml.safe_dump(accepted_src)}})["result"]
    assert accepted["ok"] is True and accepted["verdict"] == "violations"

    proposed_short = _comparable(_sw9_padB_findings(proposed["findings"])[0])
    accepted_short = _comparable(_sw9_padB_findings(accepted["findings"])[0])
    assert proposed_short == accepted_short

    # And the whole delta agrees, not just the headline finding: every violation
    # the accepted board gained is one the proposal predicted.
    baseline = {str(_comparable(f)) for f in proposed["baseline"]["findings"]}
    introduced = sorted(str(_comparable(f)) for f in proposed["findings"])
    accepted_delta = sorted(str(_comparable(f)) for f in accepted["findings"]
                            if str(_comparable(f)) not in baseline)
    assert introduced == accepted_delta


def test_baseline_is_reported_separately_and_never_charged_to_a_candidate():
    """The fixture's incidental pre-existing violations belong to the BOARD.
    They must be visible — hiding them would be dishonest — but never attributed to
    a proposal, and never allowed to make a clean proposal look dirty."""
    rb = _compiled_parity_corners()
    whole_board = handle_request({
        "id": "b", "method": "drc_geometric",
        "params": {"yaml": yaml.safe_dump(_parity_corners_dict())}})["result"]

    union = ir_candidates.check_candidates(rb, [_shorting_candidate()])
    assert len(union["baseline"]["findings"]) == len(whole_board["findings"])
    assert union["baseline"]["verdict"] == "violations"
    assert union["baseline"]["counts"] == whole_board["counts"]
    for finding in union["baseline"]["findings"]:
        assert "subjects" not in finding

    # The kernel's ADVISORY rows are board state too, and they are the reason
    # the counts above agree: an overlay adds copper only, so a legend advisory
    # can never belong to a candidate. They must be reported (not silently
    # dropped by this surface) and they must be on the baseline, not charged to
    # the proposal.
    assert union["baseline"]["advisories"] == whole_board["advisories"]
    assert whole_board["advisories"], (
        "the fixture should still exercise an advisory rule; without one this "
        "assertion proves nothing")
    assert "advisories" not in union


def test_a_clean_candidate_on_a_dirty_board_is_reported_clean():
    """Case (a) over a board that is NOT clean: the candidate verdict is about the
    candidate. A dirty board must not veto an honest proposal."""
    rb = _compiled_parity_corners()
    # Empty top-left corner of the board, well clear of every placed part.
    union = ir_candidates.check_candidates(rb, [{
        "candidate_id": "ghost-clean", "revision": 1, "net": "N_OBL",
        "segments": [{"id": "s0", "layer": "top", "width_mm": 0.3,
                      "points": [[2.0, 2.0], [2.0, 5.0]]}]}])
    assert union["ok"] is True
    assert union["verdict"] == "clean"
    assert union["findings"] == []
    assert union["per_candidate"]["ghost-clean"]["verdict"] == "clean"
    # ... while the board's own dirt is still on the record, right beside it.
    assert union["baseline"]["verdict"] == "violations"


# ---------------------------------------------------------------------------
# MULTI-PAD NET (3+ pins) — campaign standing rule, gate 019f70f76c2f.
# Two-pin single-path fixtures previously missed four real bugs.
# ---------------------------------------------------------------------------


def _pad(ref: str, x: float, y: float) -> dict:
    return {"ref": ref, "footprint": "TH_TestPoint", "x_mm": x, "y_mm": y,
            "rotation_deg": 0, "layer": "top",
            "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0,
                      "drill_mm": 0.8, "annulus_diameter_mm": 1.6}]}


def _bus_board() -> dict:
    """A THREE-pin net (BUS: P1/P2/P3) plus a foreign net whose pad X1 sits on the
    straight P1->P2 run. A 2-pin fixture cannot express this: the fault needs a
    net whose route legitimately passes OTHER pads, some its own (must stay clean)
    and one not (must be caught)."""
    return {
        "version": 1, "name": "bus-multipad", "width_mm": 60, "height_mm": 40,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [_pad("P1", 10, 20), _pad("P2", 50, 20), _pad("P3", 30, 35),
                       _pad("X1", 30, 20), _pad("X2", 50, 35)],
        "nets": [{"name": "BUS", "pins": ["P1.1", "P2.1", "P3.1"]},
                 {"name": "OTHER", "pins": ["X1.1", "X2.1"]}],
        "traces": [],
    }


def _bus_rb():
    return _compile(board_model.load_board({"board": _bus_board()}))


def test_multipad_net_candidate_through_a_foreign_pad_is_caught():
    rb = _bus_rb()
    union = ir_candidates.check_candidates(rb, [{
        "candidate_id": "bus-a", "revision": "r1", "net": "BUS",
        "segments": [{"id": "run", "layer": "top", "width_mm": 0.3,
                      "points": [[10, 20], [50, 20]]}]}])
    assert union["verdict"] == "violations"
    hits = [f for f in union["findings"]
            if any(p.get("ref") == "X1" for p in f.get("participants") or [])]
    assert hits, union["findings"]
    nets = {p.get("net_name") for p in hits[0]["participants"]}
    assert nets == {"BUS", "OTHER"}
    assert {"candidate_id": "bus-a", "revision": "r1", "segment_id": "run"} \
        in hits[0]["subjects"]


def test_multipad_net_candidate_over_its_own_pads_stays_clean():
    """The same-net exemption across a 3-pin net: a BUS route that runs from P1 to
    P3 touches its OWN pads, which is a connection, not a short."""
    rb = _bus_rb()
    union = ir_candidates.check_candidates(rb, [{
        "candidate_id": "bus-b", "revision": "r1", "net": "BUS",
        "segments": [{"id": "leg-a", "layer": "top", "width_mm": 0.3,
                      "points": [[10, 20], [10, 35], [30, 35]]}]}])
    assert union["verdict"] == "clean", union["findings"]
    assert union["per_candidate"]["bus-b"]["verdict"] == "clean"


def test_two_candidates_colliding_name_both_ghosts_and_not_the_board():
    """Candidate-vs-candidate. A canvas must be able to blame both ghosts, and must
    NOT be told committed copper is involved when it is not."""
    rb = _bus_rb()
    union = ir_candidates.check_candidates(rb, [
        {"candidate_id": "g1", "revision": 1, "net": "BUS",
         "segments": [{"id": "a", "layer": "top", "width_mm": 0.3,
                       "points": [[12, 25], [12, 32]]}]},
        {"candidate_id": "g2", "revision": 1, "net": "OTHER",
         "segments": [{"id": "b", "layer": "top", "width_mm": 0.3,
                       "points": [[8, 28], [16, 28]]}]}])
    assert union["verdict"] == "violations"
    crossed = [f for f in union["findings"]
               if {s["candidate_id"] for s in f["subjects"]} == {"g1", "g2"}]
    assert crossed, union["findings"]
    assert all(s["candidate_id"] != "board" for s in crossed[0]["subjects"])
    assert union["per_candidate"]["g1"]["verdict"] == "violations"
    assert union["per_candidate"]["g2"]["verdict"] == "violations"


def test_candidate_via_is_projected_as_real_copper_and_a_real_hole():
    """A ghost VIA is copper on both layers and a drilled hole, not a marker."""
    rb = _bus_rb()
    union = ir_candidates.check_candidates(rb, [{
        "candidate_id": "g-via", "revision": 1, "net": "BUS",
        # Dropped right on top of X1's PTH pad (net OTHER) at (30, 20).
        "vias": [{"id": "v0", "position": [30, 20], "diameter_mm": 0.8,
                  "drill_mm": 0.4}]}])
    assert union["verdict"] == "violations"
    types = {f["type"] for f in union["findings"]}
    assert "gc2_copper_clearance" in types      # via land vs pad land
    assert "gc6_hole_to_hole" in types          # via drill vs pad drill
    for finding in union["findings"]:
        assert {"candidate_id": "g-via", "revision": 1, "via_id": "v0"} \
            in finding["subjects"]


# ---------------------------------------------------------------------------
# FAIL-CLOSED — case (c) must never read like case (a).
# ---------------------------------------------------------------------------


def _assert_indeterminate(union: dict, kind: str, needle: str) -> None:
    assert union["ok"] is False
    assert union["scope"] == "geometric_candidate"
    assert union["verifies_geometry"] is False
    assert union["verdict"] == "indeterminate"
    assert union["error"]["kind"] == kind
    assert needle in union["error"]["message"]
    # NOTHING a consumer could read as a pass.
    for forbidden in ("findings", "counts", "per_candidate", "clean", "baseline"):
        assert forbidden not in union, forbidden


def test_candidate_on_an_unknown_net_fails_closed():
    _assert_indeterminate(
        ir_candidates.check_candidates(_bus_rb(), [{
            "candidate_id": "g", "net": "NOT_A_NET",
            "segments": [{"layer": "top", "width_mm": 0.3,
                          "points": [[10, 20], [20, 20]]}]}]),
        "unsupported_geometry", "not a net of this board")


def test_candidate_without_a_declared_width_fails_closed():
    """No approximated copper: a width nobody declared is never invented."""
    _assert_indeterminate(
        ir_candidates.check_candidates(_bus_rb(), [{
            "candidate_id": "g", "net": "BUS",
            "segments": [{"layer": "top", "points": [[10, 20], [20, 20]]}]}]),
        "unsupported_geometry", "never modeled at a guessed width")


def test_candidate_via_without_a_declared_size_fails_closed():
    _assert_indeterminate(
        ir_candidates.check_candidates(_bus_rb(), [{
            "candidate_id": "g", "net": "BUS",
            "vias": [{"position": [20, 20]}]}]),
        "unsupported_geometry", "never modeled at a guessed")


def test_candidate_on_a_foreign_layer_fails_closed():
    _assert_indeterminate(
        ir_candidates.check_candidates(_bus_rb(), [{
            "candidate_id": "g", "net": "BUS",
            "segments": [{"layer": "In1.Cu", "width_mm": 0.3,
                          "points": [[10, 20], [20, 20]]}]}]),
        "unsupported_geometry", "is not a copper layer of this board")


def test_zero_length_candidate_leg_fails_closed():
    _assert_indeterminate(
        ir_candidates.check_candidates(_bus_rb(), [{
            "candidate_id": "g", "net": "BUS",
            "segments": [{"layer": "top", "width_mm": 0.3,
                          "points": [[10, 20], [10, 20]]}]}]),
        "unsupported_geometry", "zero-length leg")


def test_duplicate_candidate_ids_fail_closed():
    """Two ghosts sharing an id would make attribution ambiguous — a finding could
    not be pinned to one route. Ambiguous attribution is a wrong answer."""
    seg = {"layer": "top", "width_mm": 0.3, "points": [[10, 20], [20, 20]]}
    _assert_indeterminate(
        ir_candidates.check_candidates(_bus_rb(), [
            {"candidate_id": "same", "net": "BUS", "segments": [dict(seg)]},
            {"candidate_id": "same", "net": "BUS", "segments": [dict(seg)]}]),
        "unsupported_geometry", "duplicate candidate_id")


def test_kernel_indeterminacy_propagates_and_is_not_downgraded(monkeypatch):
    """When the KERNEL cannot reach a verdict over base+candidates, the candidate
    reply is indeterminate too — never a clean, never a partial finding list."""
    from pcb_worker import drc_geometric

    monkeypatch.setattr(
        ir_candidates, "run_geometric_drc",
        lambda rb, warnings=(): drc_geometric.geometric_indeterminate(
            "unsupported_geometry", "synthetic unmodelable geometry"))
    _assert_indeterminate(
        ir_candidates.check_candidates(_bus_rb(), [{
            "candidate_id": "g", "net": "BUS",
            "segments": [{"layer": "top", "width_mm": 0.3,
                          "points": [[10, 20], [20, 20]]}]}]),
        "unsupported_geometry", "synthetic unmodelable geometry")


def test_overlay_raises_rather_than_returning_partial_geometry():
    """The projection itself is all-or-nothing: one unmodelable candidate does not
    yield a board carrying the others."""
    rb = _bus_rb()
    try:
        ir_candidates.build_overlay(rb, [
            {"candidate_id": "ok", "net": "BUS",
             "segments": [{"layer": "top", "width_mm": 0.3,
                           "points": [[10, 20], [20, 20]]}]},
            {"candidate_id": "bad", "net": "NOPE", "segments": []}])
    except UnsupportedGeometry as exc:
        assert "not a net of this board" in str(exc)
    else:  # pragma: no cover - the assertion is the point
        raise AssertionError("expected UnsupportedGeometry")


def test_overlay_does_not_mutate_the_base_board():
    rb = _bus_rb()
    before = (len(rb.traces), len(rb.vias))
    overlay = ir_candidates.build_overlay(rb, [{
        "candidate_id": "g", "net": "BUS",
        "segments": [{"layer": "top", "width_mm": 0.3,
                      "points": [[10, 20], [20, 20]]}]}])
    assert (len(rb.traces), len(rb.vias)) == before
    assert len(overlay.board.traces) == before[0] + 1
    # The overlaid board keeps the BASE board's identity + digest, so a consumer
    # can tell which source a candidate verdict was computed against.
    assert overlay.board.id == rb.id
    assert overlay.board.provenance.source_digest == rb.provenance.source_digest


def test_route_segment_start_end_shape_is_accepted():
    """route() serializes segments as {start, end, layer} while ghosts use
    {points}. Both are the same candidate language here."""
    rb = _bus_rb()
    union = ir_candidates.check_candidates(rb, [{
        "candidate_id": "g", "net": "BUS",
        "segments": [{"id": "s", "layer": "top", "width_mm": 0.3,
                      "start": [10, 20], "end": [50, 20]}]}])
    assert union["verdict"] == "violations"
    assert any(p.get("ref") == "X1"
               for f in union["findings"] for p in f.get("participants") or [])


# ---------------------------------------------------------------------------
# ASYMMETRIC FINDING SHAPES — the false clean found in the CP2 S8 review round.
# ---------------------------------------------------------------------------
#
# Most geometric rules name both parties (GC2/GC6 carry `participants`). Five do
# NOT: GC5-cutout, GC7, GC9, GC10 and GC11 are ASYMMETRIC on purpose — the
# finding is keyed on the SUBJECT of the rule (the pour, the bore, the legend
# stroke) and the other party appears only in `against_entity_id`/`pad_entity`.
#
# `_finding_entity_ids` did not read those keys. So when the opposing party was
# a CANDIDATE, the candidate appeared in no field attribution looked at: the
# finding was partitioned into `baseline` as a pre-existing board fault and the
# proposal that CAUSED it was reported CLEAN. That is the exact laundering this
# module's contract forbids, on the surface a user actually accepts routes
# through. GC7 has carried this shape since long before CP2, so the hole was
# pre-existing; GC10/GC11 joined it.


def _asymmetric_finding(rule: str, subject: str, opposed: str, key: str) -> dict:
    return {"type": rule, "entity_id": subject, "parent": None, key: opposed}


def test_the_opposed_party_of_an_asymmetric_rule_is_attributed():
    """Every asymmetric shape must yield BOTH entities, or the opposing party
    cannot be matched against the overlay and the finding is misfiled."""
    cases = [
        ("gc10_hole_to_copper", "hole:A", "candidate-segment:B", "against_entity_id"),
        ("gc7_zone_clearance", "zone:A", "candidate-segment:B", "against_entity_id"),
        ("gc11_hole_to_edge", "hole:A", "cutout:B", "against_entity_id"),
        ("gc5_copper_to_edge", "candidate-segment:A", "cutout:B", "against_entity_id"),
        ("gc9_silk_to_pad", "graphic:A", "candidate-pad:B", "pad_entity"),
    ]
    for rule, subject, opposed, key in cases:
        ids = ir_candidates._finding_entity_ids(
            _asymmetric_finding(rule, subject, opposed, key))
        assert subject in ids, rule
        assert opposed in ids, (
            f"{rule} names {opposed!r} only in {key!r}; attribution must read it "
            f"or a candidate on that side is laundered into baseline")


def test_a_candidate_that_causes_a_gc10_violation_is_not_laundered():
    """END TO END, through the real check_candidates path.

    An unplated bore projects NO copper primitive, so GC2 can form no pair and
    only GC10 sees a track run too close to it — which makes this the shape that
    exposed the bug. The candidate must own the violation; baseline must stay
    clean, because the board without the candidate IS clean."""
    import copy

    import yaml as _yaml

    with open("tests/testdata/coupon_jlc1.yaml") as fh:
        board = copy.deepcopy(_yaml.safe_load(fh))
    # A mounting hole in clear space; the board stays clean with it.
    # v2 coupon: added entities must carry minted ids (see the gc10 note).
    board["mounting_holes"] = [
        {"id": "hole:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
         "x_mm": 12.3, "y_mm": 14.0, "diameter_mm": 1.0, "plated": False}]
    rb = _compile(board)

    from pcb_worker.drc_geometric import run_geometric_drc
    assert run_geometric_drc(rb)["verdict"] == "clean", "premise: board is clean"

    # A candidate trace whose edge sits 0.125mm from the bore — under the 0.28
    # min_hole_to_copper_mm floor this profile declares.
    union = ir_candidates.check_candidates(rb, [{
        "candidate_id": "ghost-1", "revision": 1, "net": "NET_A",
        "segments": [{"id": "seg-0", "layer": "top", "width_mm": 0.25,
                      "points": [[9.0, 14.75], [16.0, 14.75]]}]}])

    assert union["verdict"] == "violations"
    per = union["per_candidate"]["ghost-1"]
    assert per["verdict"] == "violations", (
        "the candidate CAUSED this violation and must own it")
    assert per["finding_count"] >= 1
    assert union["baseline"]["verdict"] == "clean", (
        "the board without the candidate is clean; a laundered finding would "
        "show up here as a pre-existing fault")
