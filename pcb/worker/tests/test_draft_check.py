"""draft_check (T2.4): honest, SET-scoped DRC over the complete candidate set.

draft_check runs the EXISTING drc.run_drc primitives (drc.py's four checks,
reused verbatim) over the UNION of the board's committed copper and every
candidate's draft segments/vias — so a verdict for one candidate depends on the
whole effective set. Unlike route()'s per-route DRC-at-propose, findings here
carry SUBJECT IDENTITY: {candidate_id, segment_id?/via_id?}, not net-only. A
collision between two candidates names BOTH subjects; a candidate-vs-committed
collision names the candidate + a {candidate_id:"board"} subject.

board_token + workspace_generation are echoed VERBATIM so the GD side can
discard a stale reply.

Fixture/call conventions mirror test_route_drc.py (handle_request dispatch).
"""

from __future__ import annotations

from pcb_worker.methods import handle_request


def _call(params: dict) -> dict:
    resp = handle_request({"id": "dc1", "method": "draft_check", "params": params})
    assert resp is not None and resp["id"] == "dc1"
    return resp


# ---------------------------------------------------------------------------
# Board fixture: one committed vertical trace on net EXIST (x=30, y 5..35, top),
# with pads placed so candidate endpoints never read as dangling opens.
# ---------------------------------------------------------------------------


def _through_hole_pad(ref: str, x: float, y: float) -> dict:
    return {
        "ref": ref, "footprint": "TH_TestPoint", "x_mm": x, "y_mm": y,
        "rotation_deg": 0, "layer": "top",
        "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0,
                  "drill_mm": 0.8, "annulus_diameter_mm": 1.6}],
    }


def _board() -> dict:
    return {
        "version": 1,
        "name": "draft-check",
        "width_mm": 80,
        "height_mm": 80,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.25,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [
            # SIG (C1) endpoints
            _through_hole_pad("U1", 10, 20),
            _through_hole_pad("J1", 50, 20),
            # SIG2 (C2) endpoints
            _through_hole_pad("U2", 20, 5),
            _through_hole_pad("J2", 20, 35),
            # CLEAN (C3) endpoints — far from everything
            _through_hole_pad("U3", 5, 60),
            _through_hole_pad("J3", 12, 60),
            # EXIST committed-trace pads
            _through_hole_pad("A1", 30, 5),
            _through_hole_pad("A2", 30, 35),
        ],
        "nets": [
            {"name": "SIG", "pins": ["U1.1", "J1.1"]},
            {"name": "SIG2", "pins": ["U2.1", "J2.1"]},
            {"name": "CLEAN", "pins": ["U3.1", "J3.1"]},
            {"name": "EXIST", "pins": ["A1.1", "A2.1"]},
        ],
        # Committed copper: vertical trace on net EXIST at x=30 (y 5..35).
        "traces": [{"net": "EXIST", "layer": "top", "width_mm": 0.25,
                    "points": [{"x_mm": 30, "y_mm": 5}, {"x_mm": 30, "y_mm": 35}]}],
        "vias": [],
    }


def _seg(sid: str, layer: str, pts: list) -> dict:
    return {"id": sid, "layer": layer, "width": 0.25, "points": pts}


# C1 (net SIG): horizontal y=20, (10,20)->(50,20). Crosses committed EXIST at
# (30,20) AND crosses C2 at (20,20).
def _c1() -> dict:
    return {"candidate_id": "cand_1", "net": "SIG", "revision": 3,
            "segments": [_seg("s1", "top", [[10, 20], [50, 20]])], "vias": []}


# C2 (net SIG2): vertical x=20, (20,5)->(20,35). Crosses C1 at (20,20).
def _c2() -> dict:
    return {"candidate_id": "cand_2", "net": "SIG2", "revision": 7,
            "segments": [_seg("s2", "top", [[20, 5], [20, 35]])], "vias": []}


# C3 (net CLEAN): short segment on its own pads (5,60)->(12,60). No collision.
def _c3() -> dict:
    return {"candidate_id": "cand_3", "net": "CLEAN", "revision": 1,
            "segments": [_seg("s3", "top", [[5, 60], [12, 60]])], "vias": []}


def _netless_via(cid: str, x: float, y: float) -> dict:
    return {"candidate_id": cid, "net": "", "revision": 1, "segments": [],
            "vias": [{"id": f"{cid}_via", "position": [x, y],
                      "diameter_mm": 0.8, "drill_mm": 0.4,
                      "from_layer": "top", "to_layer": "bottom"}]}


# ---------------------------------------------------------------------------
# 1. Set-scoped verdicts + subject identity + verbatim echo.
# ---------------------------------------------------------------------------


def _write_board_snapshot(tmp_path, board: dict):
    """A board snapshot exactly as the panel writes one: JSON bytes plus their
    sha256, which is what {board_path, board_digest} refers to."""
    import hashlib
    import json

    path = tmp_path / "board.snap"
    data = json.dumps(board).encode("utf-8")
    path.write_bytes(data)
    return str(path), hashlib.sha256(data).hexdigest()


def test_draft_check_reads_a_board_sent_by_reference(tmp_path):
    """SR2FAB S6. The draft board is the canonical board PLUS the staged
    overlay, so it is the largest payload any channel sends and it goes over the
    same capped broker pipe as the rest. Sent by reference it arrived here as no
    board at all — and this method reads an absent board as "there is no
    committed copper", which scores every candidate against an empty board and
    calls it CLEAN. The false clean fired on exactly the large boards that most
    need checking."""
    board = _board()
    path, digest = _write_board_snapshot(tmp_path, board)

    inline = _call({"board": board, "candidates": [], "board_token": "tok"})
    by_ref = _call({"board_path": path, "board_digest": digest,
                    "candidates": [], "board_token": "tok"})
    assert by_ref["ok"] is True, by_ref
    # Same board, same verdict, whichever way it travelled.
    assert by_ref["result"] == inline["result"]


def test_an_unreadable_board_reference_refuses_instead_of_scoring(tmp_path):
    """FAIL CLOSED: no verdict at all beats a verdict computed without the
    committed copper. The reply carries an error and an EMPTY per_candidate, so
    the panel's guard reverts every candidate to the validation it had."""
    board = _board()
    path, digest = _write_board_snapshot(tmp_path, board)

    for bad in ({"board_path": path},                       # no digest
                {"board_path": path, "board_digest": "0" * 64},   # wrong digest
                {"board_path": str(tmp_path / "gone.snap"),
                 "board_digest": digest}):                  # missing file
        resp = _call(dict(bad, candidates=[], board_token="tok"))
        assert resp["ok"] is True, bad
        result = resp["result"]
        assert result["per_candidate"] == {}, bad
        assert "unreadable" in result["error"], bad
        assert result["findings"] == [], bad
        # The echo the panel's coherence guard compares against still rides the
        # refusal, or the guard cannot tell this reply from a foreign one.
        assert result["board_token"] == "tok", bad


def test_an_inline_board_still_wins_over_a_reference(tmp_path):
    """Same precedence the other channels keep: an inline board is used as-is
    and the snapshot is not read, so a stale path beside a good board cannot
    change the verdict."""
    board = _board()
    resp = _call({"board": board,
                  "board_path": str(tmp_path / "never-read.snap"),
                  "board_digest": "0" * 64,
                  "candidates": [], "board_token": "tok"})
    assert resp["ok"] is True
    assert "error" not in resp["result"]


def test_draft_check_verdicts_and_subjects():
    params = {
        "board": _board(),
        "candidates": [_c1(), _c2(), _c3()],
        "board_token": "sha256:abc123",
        "workspace_generation": 5,
    }
    resp = _call(params)
    assert resp["ok"] is True, resp
    res = resp["result"]

    # Verbatim echo (string token + int generation, unchanged).
    assert res["board_token"] == "sha256:abc123"
    assert res["workspace_generation"] == 5

    pc = res["per_candidate"]
    assert pc["cand_1"] == "violating"   # crosses committed EXIST and C2
    assert pc["cand_2"] == "violating"   # crosses C1
    assert pc["cand_3"] == "clean"       # isolated on its own pads

    findings = res["findings"]
    assert findings, "expected crossing findings"

    # Every finding names SUBJECT IDENTITY, not net-only.
    for f in findings:
        assert "subjects" in f and isinstance(f["subjects"], list) and f["subjects"]
        for s in f["subjects"]:
            assert "candidate_id" in s

    # The candidate-vs-candidate crossing names BOTH C1 and C2 (subject segments).
    cc = [f for f in findings if f["kind"] == "crossing"
          and set(f.get("nets", [])) == {"SIG", "SIG2"}]
    assert len(cc) == 1, cc
    subs = {(s["candidate_id"], s.get("segment_id")) for s in cc[0]["subjects"]}
    assert ("cand_1", "s1") in subs
    assert ("cand_2", "s2") in subs

    # The candidate-vs-committed crossing names C1's segment + the board side.
    cb = [f for f in findings if f["kind"] == "crossing"
          and set(f.get("nets", [])) == {"SIG", "EXIST"}]
    assert len(cb) == 1, cb
    cids = {s["candidate_id"] for s in cb[0]["subjects"]}
    assert "cand_1" in cids
    assert "board" in cids
    assert ("cand_1", "s1") in {(s["candidate_id"], s.get("segment_id")) for s in cb[0]["subjects"]}


def test_netless_committed_and_candidate_vias_are_checked_not_indeterminate():
    """The live editor permits via-only, unassigned work. Both real and ghost
    forms must project as netless copper instead of poisoning the batch with
    via_unknown_net / unsupported candidate-net errors."""
    board = _board()
    board["vias"] = [{"net": "", "x_mm": 70, "y_mm": 70,
                      "diameter_mm": 0.8, "drill_mm": 0.4,
                      "from_layer": "top", "to_layer": "bottom"}]
    resp = _call({"board": board, "candidates": [_netless_via("solo", 65, 65)],
                  "board_token": "netless", "workspace_generation": 1})
    assert resp["ok"] is True, resp
    result = resp["result"]
    assert "geometric_indeterminate" not in result, result
    assert result["per_candidate"]["solo"] == "clean"


# ---------------------------------------------------------------------------
# 2. Same-layer crossing gate: two candidates that cross on DIFFERENT layers
#    do NOT collide (proves layer is respected, set-scoped).
# ---------------------------------------------------------------------------


def test_different_layer_crossing_is_clean():
    c2_bottom = _c2()
    c2_bottom["segments"][0]["layer"] = "bottom"  # now on the other layer
    board = _board()
    board["traces"] = []
    params = {
        "board": board,
        "candidates": [_c1(), c2_bottom],
        "board_token": "t", "workspace_generation": 1,
    }
    res = _call(params)["result"]
    # C1 on top, C2 on bottom cross in XY but not on the same layer → no crossing.
    crossings = [f for f in res["findings"] if f["kind"] == "crossing"]
    assert crossings == [], crossings
    assert res["per_candidate"]["cand_1"] == "clean"
    assert res["per_candidate"]["cand_2"] == "clean"


# ---------------------------------------------------------------------------
# 3. Missing-via layer change (reuses drc's layer_change_no_via check).
# ---------------------------------------------------------------------------


def _layer_change_board() -> dict:
    return {
        "version": 1, "name": "lc", "width_mm": 80, "height_mm": 80,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.25,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [
            _through_hole_pad("P1", 60, 60),
            _through_hole_pad("P2", 70, 60),
        ],
        "nets": [{"name": "LC", "pins": ["P1.1", "P2.1"]}],
        "traces": [], "vias": [],
    }


def _layer_change_candidate(with_via: bool) -> dict:
    cand = {
        "candidate_id": "cand_9", "net": "LC", "revision": 1,
        "segments": [
            _seg("t", "top", [[60, 60], [65, 60]]),      # top run into the hand-off
            _seg("b", "bottom", [[65, 60], [70, 60]]),   # bottom run out — meet at (65,60)
        ],
        "vias": [],
    }
    if with_via:
        cand["vias"] = [{"id": "v1", "position": [65, 60],
                         "from_layer": "top", "to_layer": "bottom"}]
    return cand


def test_missing_via_layer_change_flags_candidate_segments():
    params = {"board": _layer_change_board(),
              "candidates": [_layer_change_candidate(with_via=False)],
              "board_token": "t", "workspace_generation": 2}
    res = _call(params)["result"]
    lc = [f for f in res["findings"] if f["kind"] == "layer_change_no_via"]
    assert len(lc) == 1, res["findings"]
    # The finding names the candidate (its meeting segments), not net-only.
    cids = {s["candidate_id"] for s in lc[0]["subjects"]}
    assert cids == {"cand_9"}
    seg_ids = {s.get("segment_id") for s in lc[0]["subjects"]}
    assert seg_ids == {"t", "b"}  # both segments meeting without a via
    assert res["per_candidate"]["cand_9"] == "violating"


def test_via_present_resolves_layer_change():
    params = {"board": _layer_change_board(),
              "candidates": [_layer_change_candidate(with_via=True)],
              "board_token": "t", "workspace_generation": 2}
    res = _call(params)["result"]
    lc = [f for f in res["findings"] if f["kind"] == "layer_change_no_via"]
    assert lc == [], res["findings"]
    assert res["per_candidate"]["cand_9"] == "clean"


# ---------------------------------------------------------------------------
# 4. Verbatim echo of a NON-trivial generation + missing-geometry → error.
# ---------------------------------------------------------------------------


def test_echo_is_verbatim_and_geometryless_candidate_errors():
    params = {
        "board": _board(),
        "candidates": [
            _c3(),  # clean
            {"candidate_id": "cand_empty", "net": "NONE", "revision": 0,
             "segments": [], "vias": []},  # no usable geometry
        ],
        "board_token": "sha256:zzz", "workspace_generation": 42,
    }
    res = _call(params)["result"]
    assert res["board_token"] == "sha256:zzz"
    assert res["workspace_generation"] == 42
    # The empty candidate has no copper and cannot interact with cand_3, so its
    # bad/deleted net is a local input error rather than a reason to erase the
    # real geometric verdict for the rest of the batch.
    assert res["per_candidate"]["cand_3"] == "clean"
    assert res["per_candidate"]["cand_empty"] == "error"
    assert "geometric_indeterminate" not in res, res.get("geometric_indeterminate")


def test_idless_direct_candidate_uses_one_fallback_identity_everywhere():
    """A direct caller may omit the workspace-minted id. Connectivity and the
    IR overlay must derive the same fallback or the geometric violation cannot
    merge back into the candidate verdict and silently reads clean."""
    candidate = {
        "net": "BUS", "revision": 7,
        "segments": [{"id": "run", "layer": "top", "width": 0.3,
                      "points": [[10, 20], [50, 20]]}],
    }
    res = _call({"board": _candidate_geometry_board(), "candidates": [candidate],
                 "board_token": "t", "workspace_generation": 1})["result"]
    assert res["per_candidate"]["candidate:0"] == "violating"
    assert any(
        {"candidate_id": "candidate:0", "revision": 7, "segment_id": "run"}
        in f.get("subjects", [])
        for f in res.get("findings", []) if f.get("scope") == "geometric")


def test_idless_identity_survives_empty_candidate_filtering():
    """Filtering a provably-empty predecessor must not renumber later fallback
    ids inside the reduced geometric batch."""
    empty = {"candidate_id": "empty", "net": "DELETED_NET",
             "segments": [], "vias": []}
    candidate = {
        "net": "BUS", "revision": 8,
        "segments": [{"id": "run", "layer": "top", "width": 0.3,
                      "points": [[10, 20], [50, 20]]}],
    }
    res = _call({"board": _candidate_geometry_board(),
                 "candidates": [empty, candidate],
                 "board_token": "t", "workspace_generation": 1})["result"]
    assert res["per_candidate"]["empty"] == "error"
    assert res["per_candidate"]["candidate:1"] == "violating"
    assert any(
        {"candidate_id": "candidate:1", "revision": 8, "segment_id": "run"}
        in f.get("subjects", [])
        for f in res.get("findings", []) if f.get("scope") == "geometric")


def test_indeterminate_names_the_candidate_that_poisoned_the_batch():
    candidate = {
        "candidate_id": "poison", "net": "DELETED_NET", "revision": 1,
        "segments": [{"id": "s", "layer": "top", "width": 0.3,
                      "points": [[2, 2], [5, 2]]}],
    }
    res = _call({"board": _candidate_geometry_board(), "candidates": [candidate],
                 "board_token": "t", "workspace_generation": 1})["result"]
    # Connectivity may independently prove a violation (for example dangling
    # copper); that sound result survives. The important contract is that the
    # geometric refusal never produces clean and names its offender.
    assert res["per_candidate"]["poison"] != "clean"
    assert res["geometric_indeterminate"]["candidate_id"] == "poison"


def test_unknown_future_geometric_verdict_fails_closed(monkeypatch):
    """The current producer emits only clean/violations. Pin the adapter so a
    future vocabulary addition cannot fall through an `else clean` branch."""
    from pcb_worker import methods

    def future_union(_board, _candidates, **_kwargs):
        return {
            "ok": True, "verifies_geometry": True,
            "per_candidate": {"cand-clean": {"verdict": "partial"}},
            "findings": [], "baseline": {"findings": []},
        }

    monkeypatch.setattr(methods.ir_candidates, "check_candidates", future_union)
    candidate = {
        "candidate_id": "cand-clean", "net": "BUS", "revision": 1,
        "segments": [{"id": "safe", "layer": "top", "width": 0.3,
                      "points": [[10, 20], [10, 35], [30, 35]]}],
    }
    res = _call({"board": _candidate_geometry_board(), "candidates": [candidate],
                 "board_token": "t", "workspace_generation": 1})["result"]
    assert res["per_candidate"]["cand-clean"] == "error"
    assert res["geometric_indeterminate"]["kind"] == "internal"
    assert res["geometric_indeterminate"]["candidate_id"] == "cand-clean"


def test_findings_carry_witness_geometry_and_both_type_spellings():
    """Epoch UX3 station 4 (K11, cold review F1): the reply must not strip the
    source finding's keys. The canvas witness overlay reads `type` +
    `closest`/`witness` [x, y] pairs; the reply's historical consumers read
    `kind`. Both spellings ride every finding, and a point finding's pair
    collapses onto its `at` — a finding with no geometry cannot be drawn
    where the problem is, which was the whole defect."""
    resp = _call({
        "board": _board(),
        "candidates": [_c1(), _c2(), _c3()],
        "board_token": "t", "workspace_generation": 1,
    })
    assert resp["ok"] is True, resp
    findings = resp["result"]["findings"]
    assert findings, "fixture must produce findings"
    for f in findings:
        assert f.get("kind"), f
        assert f.get("type") == f.get("kind"), (
            "both spellings must name the same class")
        at = f.get("at")
        if isinstance(at, (list, tuple)) and len(at) == 2:
            assert f.get("closest") == list(at), f
            assert f.get("witness") == list(at), f


# ── the GEOMETRIC half of K9 (019fa6ed5e23) ─────────────────────────────────
#
# WHAT WAS WRONG. The panel composes canonical geometry plus the live staged
# overlay — staged zones appended, staged placements applied — and sends that
# board here. But this method's subject set is built only from board["traces"]
# and board["vias"] plus the candidates, and its verdict came from drc.run_drc,
# which states in its own module docstring that it reads pad CENTERS and trace
# CENTERLINES only and CANNOT verify clearances. The composition was therefore
# INERT: a staged zone or a moved component could not produce a finding however
# badly it violated, because nothing in the path ever looked at zones,
# components or pads. Composing correctly and CHECKING what was composed are
# two claims, and only the first had been built.

_SEEDED_REF = "Package_DIP:DIP-6_W7.62mm_Socket"


def _compiling_board() -> dict:
    """A compact seed-library board for the geometric kernel's clean case."""
    return {
        "version": 1, "name": "draft-geo", "width_mm": 40, "height_mm": 40,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [{"ref": "X1", "footprint": _SEEDED_REF, "x_mm": 20,
                        "y_mm": 20, "rotation_deg": 0, "layer": "top"}],
        "nets": [], "traces": [], "vias": [],
    }


def _candidate_geometry_board() -> dict:
    """A compiling three-pad net plus a foreign pad on its straight run."""
    return {
        "version": 1, "name": "draft-candidate-geo",
        "width_mm": 60, "height_mm": 40,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [
            _through_hole_pad("P1", 10, 20),
            _through_hole_pad("P2", 50, 20),
            _through_hole_pad("P3", 30, 35),
            _through_hole_pad("X1", 30, 20),
            _through_hole_pad("X2", 50, 35),
        ],
        "nets": [
            {"name": "BUS", "pins": ["P1.1", "P2.1", "P3.1"]},
            {"name": "OTHER", "pins": ["X1.1", "X2.1"]},
        ],
        "traces": [], "vias": [],
    }


def test_candidate_geometric_violation_is_reported_and_attributed():
    """THE DECISIVE ORACLE. The previous version of this test asserted only that
    a geometric pass can actually SEE candidate copper and return the identity
    that the workspace uses to retain the finding. A BUS trace runs through X1,
    a foreign-net plated pad. Deleting the candidate overlay, checking only the
    base board, or re-attributing the witness with connectivity's point heuristic
    all fail this oracle."""
    candidate = {
        "candidate_id": "cand-short", "revision": 7, "net": "BUS",
        "segments": [{"id": "run", "layer": "top", "width": 0.3,
                      "points": [[10, 20], [50, 20]]}],
    }
    res = _call({"board": _candidate_geometry_board(), "candidates": [candidate],
                 "board_token": "t", "workspace_generation": 1})["result"]
    assert "geometric_indeterminate" not in res, res.get("geometric_indeterminate")
    assert res["per_candidate"]["cand-short"] == "violating"
    attributed = [
        f for f in res.get("findings", [])
        if f.get("scope") == "geometric"
        and {"candidate_id": "cand-short", "revision": 7,
             "segment_id": "run"} in f.get("subjects", [])
    ]
    assert attributed, res.get("findings")


def test_composed_placement_violation_reaches_the_geometric_kernel():
    """A staged placement is already materialized into the board by the panel.
    Coincident foreign-net pads therefore have to appear as a board-baseline
    geometric finding even when there are no route candidates."""
    board = _candidate_geometry_board()
    x1 = next(c for c in board["components"] if c["ref"] == "X1")
    x1["x_mm"], x1["y_mm"] = 10, 20
    res = _call({"board": board, "candidates": [],
                 "board_token": "t", "workspace_generation": 1})["result"]
    assert "geometric_indeterminate" not in res, res.get("geometric_indeterminate")
    collisions = [
        f for f in res.get("findings", [])
        if f.get("scope") == "geometric"
        and {p.get("ref") for p in f.get("participants", [])} == {"P1", "X1"}
    ]
    assert collisions, res.get("findings")


def test_dimensionless_candidate_via_uses_the_board_defaults():
    """Workspace candidates intentionally omit accepted-board via dimensions.
    The old raw-board overlay sent that incomplete via back through the compiler,
    poisoning the whole geometric check. The IR overlay must apply the authored
    board defaults and reach a real verdict instead."""
    candidate = {
        "candidate_id": "via-defaults", "revision": 2, "net": "BUS",
        "segments": [
            {"id": "top-leg", "layer": "top", "width": 0.3,
             "points": [[2, 2], [4, 2]]},
            {"id": "bottom-leg", "layer": "bottom", "width": 0.3,
             "points": [[4, 2], [6, 2]]},
        ],
        "vias": [{"id": "turn", "position": [4, 2],
                  "from_layer": "top", "to_layer": "bottom"}],
    }
    res = _call({"board": _candidate_geometry_board(), "candidates": [candidate],
                 "board_token": "t", "workspace_generation": 1})["result"]
    assert "geometric_indeterminate" not in res, res.get("geometric_indeterminate")
    assert res["per_candidate"]["via-defaults"] in ("clean", "violating")


def test_a_clean_compiling_board_declares_no_indeterminate():
    """The negative half, kept for what it IS good for: a board the kernel can
    model must not claim it could not be modelled. On its own this proves
    nothing about the pass running — see the test above, which does."""
    res = _call({"board": _compiling_board(), "candidates": [],
                 "board_token": "t", "workspace_generation": 1})["result"]
    assert "geometric_indeterminate" not in res, res.get("geometric_indeterminate")


def test_a_board_the_kernel_cannot_model_says_so_rather_than_reading_clean():
    """MUTATION THIS CATCHES: swallowing a compile/kernel failure into an empty
    finding list. An empty list is indistinguishable from "checked and clean",
    and a draft check that cannot verify geometry must never present itself as
    having verified it — the false-clean K14 forbids.

    Corrupt one otherwise-real fixture footprint so compile refuses; keeping the
    healthy fixture healthy ensures all other tests exercise the actual kernel."""
    board = _board()
    board["components"][0]["footprint"] = "UNRESOLVED_FOR_TEST"
    res = _call({"board": board, "candidates": [_c3()],
                 "board_token": "t", "workspace_generation": 1})["result"]
    ind = res.get("geometric_indeterminate")
    assert ind, "a board that cannot be compiled reported no geometric verdict at all"
    assert ind.get("kind"), ind
    assert str(ind.get("message", "")).strip(), ind


def test_draft_provenance_is_echoed_so_a_finding_can_be_traced_to_its_draft():
    """MUTATION THIS CATCHES: dropping the echo. The panel sends provenance
    beside the board so a finding naming a staged entity can be tied back to the
    store entry it came from. Without the echo the field was WRITE-ONLY — sent
    every request and consumed by nothing, which is how it shipped."""
    prov = [{"staged_id": "staged_1", "entity_id": "zone:1", "kind": "zone",
             "disposition": "staged", "materialized": True}]
    res = _call({"board": _compiling_board(), "candidates": [],
                 "draft_provenance": prov,
                 "board_token": "t", "workspace_generation": 1})["result"]
    assert res.get("draft_provenance") == prov


def test_absent_provenance_does_not_invent_an_empty_one():
    """MUTATION THIS CATCHES: echoing [] unconditionally. A caller would then be
    unable to tell "this request carried no drafts" from "provenance was
    stripped somewhere", and the second is a bug worth seeing."""
    res = _call({"board": _compiling_board(), "candidates": [],
                 "board_token": "t", "workspace_generation": 1})["result"]
    assert "draft_provenance" not in res
