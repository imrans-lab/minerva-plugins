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

import pytest

from pcb_worker.methods import handle_request


def _call(params: dict) -> dict:
    resp = handle_request({"id": "dc1", "method": "draft_check", "params": params})
    assert resp is not None and resp["id"] == "dc1"
    return resp


# ---------------------------------------------------------------------------
# Board fixture: one committed vertical trace on net EXIST (x=30, y 5..35, top),
# with pads placed so candidate endpoints never read as dangling opens.
# ---------------------------------------------------------------------------


def _board() -> dict:
    return {
        "version": 1,
        "name": "draft-check",
        "width_mm": 80,
        "height_mm": 80,
        "components": [
            # SIG (C1) endpoints
            {"ref": "U1", "footprint": "HDR", "x_mm": 10, "y_mm": 20, "rotation_deg": 0,
             "layer": "top", "pins": [{"number": "1", "x_mm": 0, "y_mm": 0}]},
            {"ref": "J1", "footprint": "HDR", "x_mm": 50, "y_mm": 20, "rotation_deg": 0,
             "layer": "top", "pins": [{"number": "1", "x_mm": 0, "y_mm": 0}]},
            # SIG2 (C2) endpoints
            {"ref": "U2", "footprint": "HDR", "x_mm": 20, "y_mm": 0, "rotation_deg": 0,
             "layer": "top", "pins": [{"number": "1", "x_mm": 0, "y_mm": 0}]},
            {"ref": "J2", "footprint": "HDR", "x_mm": 20, "y_mm": 40, "rotation_deg": 0,
             "layer": "top", "pins": [{"number": "1", "x_mm": 0, "y_mm": 0}]},
            # CLEAN (C3) endpoints — far from everything
            {"ref": "U3", "footprint": "HDR", "x_mm": 5, "y_mm": 60, "rotation_deg": 0,
             "layer": "top", "pins": [{"number": "1", "x_mm": 0, "y_mm": 0}]},
            {"ref": "J3", "footprint": "HDR", "x_mm": 12, "y_mm": 60, "rotation_deg": 0,
             "layer": "top", "pins": [{"number": "1", "x_mm": 0, "y_mm": 0}]},
            # EXIST committed-trace pads
            {"ref": "A1", "footprint": "HDR", "x_mm": 30, "y_mm": 5, "rotation_deg": 0,
             "layer": "top", "pins": [{"number": "1", "x_mm": 0, "y_mm": 0}]},
            {"ref": "A2", "footprint": "HDR", "x_mm": 30, "y_mm": 35, "rotation_deg": 0,
             "layer": "top", "pins": [{"number": "1", "x_mm": 0, "y_mm": 0}]},
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


# C2 (net SIG2): vertical x=20, (20,0)->(20,40). Crosses C1 at (20,20).
def _c2() -> dict:
    return {"candidate_id": "cand_2", "net": "SIG2", "revision": 7,
            "segments": [_seg("s2", "top", [[20, 0], [20, 40]])], "vias": []}


# C3 (net CLEAN): short segment on its own pads (5,60)->(12,60). No collision.
def _c3() -> dict:
    return {"candidate_id": "cand_3", "net": "CLEAN", "revision": 1,
            "segments": [_seg("s3", "top", [[5, 60], [12, 60]])], "vias": []}


# ---------------------------------------------------------------------------
# 1. Set-scoped verdicts + subject identity + verbatim echo.
# ---------------------------------------------------------------------------


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


# ---------------------------------------------------------------------------
# 2. Same-layer crossing gate: two candidates that cross on DIFFERENT layers
#    do NOT collide (proves layer is respected, set-scoped).
# ---------------------------------------------------------------------------


def test_different_layer_crossing_is_clean():
    c2_bottom = _c2()
    c2_bottom["segments"][0]["layer"] = "bottom"  # now on the other layer
    params = {
        "board": {"version": 1, "name": "x", "width_mm": 80, "height_mm": 80,
                  "components": _board()["components"], "nets": _board()["nets"],
                  "traces": [], "vias": []},
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
        "components": [
            {"ref": "P1", "footprint": "HDR", "x_mm": 60, "y_mm": 60, "rotation_deg": 0,
             "layer": "top", "pins": [{"number": "1", "x_mm": 0, "y_mm": 0}]},
            {"ref": "P2", "footprint": "HDR", "x_mm": 70, "y_mm": 60, "rotation_deg": 0,
             "layer": "top", "pins": [{"number": "1", "x_mm": 0, "y_mm": 0}]},
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
    assert res["per_candidate"]["cand_3"] == "clean"
    assert res["per_candidate"]["cand_empty"] == "error"


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
    """A board that actually COMPILES — real seed footprint, real design rules —
    so the geometric kernel can run over it. The fixture above deliberately uses
    synthetic footprints and does not compile, which is why it exercises the
    fail-closed path instead."""
    return {
        "version": 1, "name": "draft-geo", "width_mm": 40, "height_mm": 40,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [{"ref": "X1", "footprint": _SEEDED_REF, "x_mm": 20,
                        "y_mm": 20, "rotation_deg": 0, "layer": "top"}],
        "nets": [], "traces": [], "vias": [],
    }


def test_a_staged_zone_that_violates_clearance_IS_REPORTED():
    """THE DECISIVE ORACLE. The previous version of this test asserted only that
    `geometric_indeterminate` was ABSENT for a compiling board — which deleting
    the geometric pass entirely also satisfies, so it could not catch the very
    mutation its docstring claimed (Codex re-review finding 6). Asserting the
    absence of a failure signal proves nothing about a check having run.

    This asserts a POSITIVE result instead: a staged keepout zone overlapping a
    pad must produce a geometric finding. MUTATION THIS CATCHES: deleting the
    pass, passing `board` instead of `effective`, or dropping the findings on
    the floor — none of which can produce this finding."""
    board = _compiling_board()
    # A keepout laid directly over the component's pads: the composed draft
    # board the panel would send once this zone is staged.
    board["zones"] = [{
        "id": "zone:violator", "kind": "keepout", "layer": "top", "net": "",
        "outline": [{"x_mm": 18.0, "y_mm": 18.0}, {"x_mm": 24.0, "y_mm": 18.0},
                    {"x_mm": 24.0, "y_mm": 24.0}, {"x_mm": 18.0, "y_mm": 24.0}],
    }]
    res = _call({"board": board, "candidates": [],
                 "board_token": "t", "workspace_generation": 1})["result"]
    if res.get("geometric_indeterminate"):
        pytest.fail("the kernel refused this board rather than checking it: %s"
                    % res["geometric_indeterminate"])
    geo = [f for f in res.get("findings", [])
           if str(f.get("scope", "")) == "geometric"]
    assert geo, ("a keepout laid over the pads produced no geometric finding; "
                 "the composed board is not reaching the kernel")


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

    The module fixture uses synthetic footprints ("HDR") that do not resolve, so
    the compile refuses and this is the honest path."""
    res = _call({"board": _board(), "candidates": [_c3()],
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
