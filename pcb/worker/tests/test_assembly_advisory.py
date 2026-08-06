"""Assembly-collision ADVISORY floor — HITL-4 (docs/llm-ergonomics.md F3).

THE BUG, from the live round (smart-remote board): D1 (Diode_SMD:D_SMA at
65.0, 12.7 rot 90) and BAT1 (Connector_JST JST_PH horizontal at 68.58, 12.7
rot 90) have physically overlapping BODIES — the parts cannot be assembled —
and no gate fired: geometric DRC is copper/drill only, and the captured
F.CrtYd geometry was "documentation-only" on every reply. The collision
PRE-EXISTED the routing session; the owner had flagged that placement the
cycle before, and the tooling never named it.

WHAT THESE TESTS PIN: the bbox-level advisory pass
(pcb_worker.assembly_advisory), TRI-STATE since work item 019fd5fddc09 (DCR
019fd5fd9084) — the public entry is `assembly_check`, returning
{status: "pass"|"findings"|"indeterminate", findings, indeterminate?} —
its three surfaces (the standalone `assembly_check` worker method, the route()
reply's `board_health.assembly`, and the resolve_best_effort board-LOAD
reply's `assembly`), and its honesty features: the basis is NAMED per finding
("courtyard" vs the coarser "pad_extent" fallback), an UNMEASURABLE component
is COUNTED as an indeterminate contribution (never silently skipped — "pass"
means measured-clean, not nothing-said), a checker fault is status
"indeterminate" + error (never a silent pass, never a raise), opposite sides
never collide, and severity is always "advisory" (this is the ergonomics
floor, NOT the deferred full courtyard DRC — docket 019fce3a6c57).

THE GEOMETRY IS THE REAL GEOMETRY: the courtyard lines below are copied
verbatim from the seed library's own footprints
(library/footprints/Diode_SMD.pretty/D_SMA.kicad_mod and
Connector_JST.pretty/JST_PH_S2B-PH-K_1x02_P2.00mm_Horizontal.kicad_mod), and
the placements are the live board's. The expected overlap is hand-derived:
under the KiCad CW rotation (rotate_local_offset: +90° maps (x, y)→(y, −x)),
D1's courtyard lands at X[63.2, 66.8] Y[9.0, 16.4] and BAT1's at
X[66.73, 75.33] Y[8.25, 15.15] — a 0.07 × 6.15 mm sliver ≈ 0.4305 mm².
"""

from __future__ import annotations

import pytest

from pcb_worker import assembly_advisory
from pcb_worker.methods import handle_request


def _call(method: str, params: dict) -> dict:
    resp = handle_request({"id": "a1", "method": method, "params": params})
    assert resp is not None and resp["id"] == "a1"
    return resp


def _courtyard_lines(x1: float, y1: float, x2: float, y2: float) -> list[dict]:
    """A rectangular F.CrtYd outline as four fp_lines — the exact shape both
    live footprints author, in the dict form resolve.py/footprints.py emit."""
    return [
        {"layer": "F.CrtYd", "kind": "line", "start": [x1, y1], "end": [x2, y1], "width": 0.05},
        {"layer": "F.CrtYd", "kind": "line", "start": [x2, y1], "end": [x2, y2], "width": 0.05},
        {"layer": "F.CrtYd", "kind": "line", "start": [x2, y2], "end": [x1, y2], "width": 0.05},
        {"layer": "F.CrtYd", "kind": "line", "start": [x1, y2], "end": [x1, y1], "width": 0.05},
    ]


def _d1(x: float = 65.0, y: float = 12.7, rot: float = 90, **extra) -> dict:
    """D1: Diode_SMD:D_SMA — courtyard (−3.7, −1.8)…(3.7, 1.8), SMD pads
    2.2×1.7 at (±2.05, 0). Real library geometry, live board placement."""
    comp = {
        "ref": "D1", "footprint": "Diode_SMD:D_SMA",
        "x_mm": x, "y_mm": y, "rotation_deg": rot, "layer": "top",
        "pins": [
            {"number": "1", "x_mm": -2.05, "y_mm": 0.0,
             "pad_width_mm": 2.2, "pad_height_mm": 1.7},
            {"number": "2", "x_mm": 2.05, "y_mm": 0.0,
             "pad_width_mm": 2.2, "pad_height_mm": 1.7},
        ],
        "graphics": _courtyard_lines(-3.7, -1.8, 3.7, 1.8),
    }
    comp.update(extra)
    return comp


def _bat1(x: float = 68.58, y: float = 12.7, rot: float = 90, **extra) -> dict:
    """BAT1: JST_PH_S2B-PH-K_1x02_P2.00mm_Horizontal — courtyard
    (−2.45, −1.85)…(4.45, 6.75) (the housing reaches ~4.5mm past the pads,
    which is exactly why the pad_extent fallback could never catch this
    pair), TH pads 1.2×1.75 drill 0.75 at (0,0)/(2,0)."""
    comp = {
        "ref": "BAT1",
        "footprint": "Connector_JST:JST_PH_S2B-PH-K_1x02_P2.00mm_Horizontal",
        "x_mm": x, "y_mm": y, "rotation_deg": rot, "layer": "top",
        "pins": [
            {"number": "1", "x_mm": 0.0, "y_mm": 0.0, "drill_mm": 0.75,
             "pad_width_mm": 1.2, "pad_height_mm": 1.75},
            {"number": "2", "x_mm": 2.0, "y_mm": 0.0, "drill_mm": 0.75,
             "pad_width_mm": 1.2, "pad_height_mm": 1.75},
        ],
        "graphics": _courtyard_lines(-2.45, -1.85, 4.45, 6.75),
    }
    comp.update(extra)
    return comp


def _board(components: list, **extra) -> dict:
    board = {
        "version": 1, "name": "assembly-advisory", "width_mm": 100,
        "height_mm": 60, "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.25,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": components, "nets": [],
    }
    board.update(extra)
    return board


# ---------------------------------------------------------------------------
# The pass itself — real D1/BAT1 geometry, through the tri-state entry
# (work item 019fd5fddc09).
# ---------------------------------------------------------------------------


def _findings(board: dict) -> list:
    """assembly_check's findings, asserting the tri-state invariants every
    call must hold: a findings-bearing check says "findings", an empty one
    with everything measured says "pass", and `indeterminate` is an
    absent-when-empty key."""
    check = assembly_advisory.assembly_check(board)
    if check["findings"]:
        assert check["status"] == "findings", check
    elif "indeterminate" not in check:
        assert check["status"] == "pass", check
    return check["findings"]


def test_the_live_D1_BAT1_overlap_is_flagged_on_courtyard_basis():
    check = assembly_advisory.assembly_check(_board([_d1(), _bat1()]))
    assert check["status"] == "findings"
    assert "indeterminate" not in check  # every component measured
    advisories = check["findings"]
    assert len(advisories) == 1, advisories
    adv = advisories[0]
    assert adv["components"] == ["BAT1", "D1"]  # sorted pair
    assert adv["basis"] == "courtyard"
    assert adv["bases"] == ["courtyard", "courtyard"]
    assert adv["side"] == "top"
    assert adv["severity"] == "advisory"
    # The hand-derived sliver (module docstring): 0.07 × 6.15 mm.
    assert adv["overlap_mm2"] == pytest.approx(0.4305, abs=0.01)
    minx, miny, maxx, maxy = adv["bbox"]
    assert (minx, maxx) == (pytest.approx(66.73), pytest.approx(66.8))
    assert (miny, maxy) == (pytest.approx(9.0), pytest.approx(15.15))


def test_pulled_apart_the_same_parts_are_a_measured_pass():
    """Negative gate: give BAT1 the clearance the owner asked for and the
    advisory disappears — non-overlapping measured parts are a "pass" with
    empty findings (a MEASURED all-clear, which the tri-state refactor
    distinguishes from could-not-measure)."""
    check = assembly_advisory.assembly_check(_board([_d1(), _bat1(x=80.0)]))
    assert check == {"status": "pass", "findings": []}


def test_rotation_is_applied_before_the_bbox_not_after():
    """The same parts at rot 0 also overlap (hand-derived: D1 spans
    X[61.3, 68.7] Y[10.9, 14.5], BAT1 X[66.13, 73.03] Y[10.85, 19.45] — a
    2.57 × 3.6 mm block), but along a DIFFERENT intersection box than the
    rot-90 sliver. An implementation that bboxed the unrotated footprint and
    ignored `rotation_deg` would report the rot-0 box for both placements;
    the two differing pins that local points are rotated BEFORE boxing."""
    rot90 = _findings(_board([_d1(), _bat1()]))
    rot0 = _findings(_board([_d1(rot=0), _bat1(rot=0)]))
    assert rot90 and rot0
    assert rot90[0]["bbox"] != rot0[0]["bbox"]
    assert rot0[0]["overlap_mm2"] == pytest.approx(2.57 * 3.6, abs=0.01)


def test_opposite_sides_never_collide():
    check = assembly_advisory.assembly_check(
        _board([_d1(), _bat1(layer="bottom")]))
    assert check == {"status": "pass", "findings": []}


def test_components_without_courtyards_fall_back_to_named_pad_extent():
    """Strip the graphics: the pass degrades to pad extents + margin and SAYS
    SO. The real D1/BAT1 pair is invisible on this basis (the JST housing far
    outreaches its pads — asserted here, which is the honest statement of the
    fallback's limit), so the positive case squeezes two bare parts together
    until even their pads collide."""
    d1 = _d1()
    bat1 = _bat1()
    del d1["graphics"], bat1["graphics"]
    assert _findings(_board([d1, bat1])) == []

    close_bat1 = _bat1(x=66.5)
    del close_bat1["graphics"]
    d1_again = _d1()
    del d1_again["graphics"]
    advisories = _findings(_board([d1_again, close_bat1]))
    assert len(advisories) == 1, advisories
    assert advisories[0]["basis"] == "pad_extent"
    assert advisories[0]["bases"] == ["pad_extent", "pad_extent"]


def test_mixed_bases_are_named_mixed():
    bare_d1 = _d1(x=66.5)  # close enough for its pad extent to reach BAT1's courtyard
    del bare_d1["graphics"]
    advisories = _findings(_board([bare_d1, _bat1()]))
    assert len(advisories) == 1, advisories
    assert advisories[0]["basis"] == "mixed"
    assert sorted(advisories[0]["bases"]) == ["courtyard", "pad_extent"]


def test_malformed_components_never_raise_and_are_counted_indeterminate():
    """Advisory-grade tolerance, tri-stated (019fd5fddc09): junk in the
    component list never raises and never advises — but it is COUNTED, not
    skipped. The pre-tri-state pass returned an empty list here, which was
    byte-identical to a measured all-clear; the status now says that NOTHING
    on this board was actually judged. Entries without a usable ref are named
    positionally — an honest handle beats dropping the fact."""
    board = _board([
        "not-a-dict",
        {"ref": "NOPOS"},  # no coordinates
        {"x_mm": 1, "y_mm": 1},  # no ref (positional handle), no geometry
        {"ref": "NOGEOM", "x_mm": 5, "y_mm": 5},  # nothing measurable
        {"ref": "BADNUM", "x_mm": "five", "y_mm": 5,
         "graphics": _courtyard_lines(-1, -1, 1, 1)},
    ])
    check = assembly_advisory.assembly_check(board)
    assert check["status"] == "indeterminate"
    assert check["findings"] == []
    assert check["indeterminate"] == [
        {"component": "components[0]", "reason": "not_a_component"},
        {"component": "NOPOS", "reason": "no_position"},
        {"component": "components[2]", "reason": "no_geometry"},
        {"component": "NOGEOM", "reason": "no_geometry"},
        {"component": "BADNUM", "reason": "no_position"},
    ]


def test_one_unmeasurable_component_makes_a_clean_board_indeterminate():
    """The tri-state boundary case: measurable parts that do NOT overlap plus
    ONE unmeasurable part is `indeterminate`, not "pass" — the check cannot
    vouch for a body it never saw."""
    check = assembly_advisory.assembly_check(_board(
        [_d1(), _bat1(x=80.0), {"ref": "MYSTERY", "x_mm": 30, "y_mm": 30}]))
    assert check["status"] == "indeterminate"
    assert check["findings"] == []
    assert check["indeterminate"] == [
        {"component": "MYSTERY", "reason": "no_geometry"}]


def test_findings_win_the_status_over_indeterminate():
    """A found collision is actionable regardless of what else went
    unmeasured: status is "findings", with the indeterminate entries still
    riding beside it."""
    check = assembly_advisory.assembly_check(_board(
        [_d1(), _bat1(), {"ref": "MYSTERY", "x_mm": 30, "y_mm": 30}]))
    assert check["status"] == "findings"
    assert len(check["findings"]) == 1
    assert check["indeterminate"] == [
        {"component": "MYSTERY", "reason": "no_geometry"}]


def test_a_checker_fault_is_indeterminate_with_error_never_a_pass(monkeypatch):
    """The hard-fault half of the tri-state contract: an exception inside the
    measurement pass surfaces as status "indeterminate" + error — NEVER a
    silent pass and NEVER an unstructured raise."""
    def _boom(_board):
        raise RuntimeError("synthetic assembly fault")

    monkeypatch.setattr(assembly_advisory, "_assembly_check_measured", _boom)
    check = assembly_advisory.assembly_check(_board([_d1(), _bat1()]))
    assert check["status"] == "indeterminate"
    assert check["findings"] == []
    assert "synthetic assembly fault" in check["error"]


def test_flush_placement_is_not_an_overlap():
    """Courtyards that exactly share an edge are parts placed flush BY DESIGN
    — zero overlap area, a measured pass."""
    a = _d1(x=10.0, y=10.0, rot=0)
    b = _d1(x=17.4, y=10.0, rot=0)  # 7.4mm courtyard width: edges touch at 13.7
    b["ref"] = "D2"
    assert assembly_advisory.assembly_check(_board([a, b])) == {
        "status": "pass", "findings": []}


# ---------------------------------------------------------------------------
# Surface (a): the route() reply — `board_health.assembly` (DCR 019fd5fd9084;
# the old optional top-level `assembly_advisories` key is GONE).
# ---------------------------------------------------------------------------


def _routable_board_with_collision() -> dict:
    def tp(ref, x, y):
        return {"ref": ref, "footprint": "TH_TestPoint", "x_mm": x, "y_mm": y,
                "rotation_deg": 0, "layer": "top",
                "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0,
                          "drill_mm": 0.8, "annulus_diameter_mm": 1.6}]}
    board = _board([tp("U9", 10, 40), tp("J9", 60, 40), _d1(), _bat1()],
                   width_mm=100, height_mm=60)
    board["nets"] = [{"name": "SIG", "pins": ["U9.1", "J9.1"]}]
    return board


def test_the_route_reply_carries_the_assembly_verdict_in_board_health():
    """Propose replies must be able to say "these parts collide" — the D1/BAT1
    placement pre-existed its routing session and the route reply was the
    surface being read when nothing said so. Since DCR 019fd5fd9084 the
    verdict rides as the tri-state `board_health.assembly`, and the old
    top-level `assembly_advisories` key is gone."""
    resp = _call("route", {"board": _routable_board_with_collision(),
                           "scope": {"nets": ["SIG"]}})
    assert resp["ok"] is True, resp
    assert "assembly_advisories" not in resp["result"]  # replaced, not doubled
    assembly = resp["result"]["board_health"]["assembly"]
    assert assembly["status"] == "findings"
    advisories = assembly["findings"]
    assert advisories and advisories[0]["components"] == ["BAT1", "D1"]
    assert advisories[0]["severity"] == "advisory"
    # …and stays advisory: the route itself succeeded regardless.
    assert {r["net"] for r in resp["result"]["routes"]} == {"SIG"}


def test_a_collision_free_route_reply_says_pass_out_loud():
    """The tri-state upgrade of the old absent-key contract: a collision-free
    board is a MEASURED "pass" in board_health.assembly (and the retired
    top-level key stays gone) — silence is no longer the all-clear signal."""
    board = _routable_board_with_collision()
    board["components"] = [c for c in board["components"]
                           if c["ref"] not in ("D1", "BAT1")]
    resp = _call("route", {"board": board, "scope": {"nets": ["SIG"]}})
    assert resp["ok"] is True, resp
    assert "assembly_advisories" not in resp["result"]
    assembly = resp["result"]["board_health"]["assembly"]
    assert assembly == {"status": "pass", "findings": []}


# ---------------------------------------------------------------------------
# Surface (b): the resolve_best_effort board-LOAD reply — where the owner most
# wants to see the collision, before any routing is attempted. Tri-state
# `assembly`, ALWAYS present (019fd5fddc09).
# ---------------------------------------------------------------------------


def test_the_board_load_reply_carries_the_assembly_verdict():
    """Components whose footprints the library cannot explain stay inline
    (tolerant resolve), keeping their captured courtyard graphics — so the
    load reply names the collision without any library round-trip. The
    `footprint` refs here are deliberately NOT in the seed library, driving
    exactly that inline path."""
    board = _board([
        _d1(footprint="NotInLibrary:D_SMA"),
        _bat1(footprint="NotInLibrary:JST_PH"),
    ])
    resp = _call("resolve_best_effort", {"board": board})
    assert resp["ok"] is True, resp
    assert "assembly_advisories" not in resp["result"]  # replaced, not doubled
    assembly = resp["result"]["assembly"]
    assert assembly["status"] == "findings"
    advisories = assembly["findings"]
    assert advisories and advisories[0]["components"] == ["BAT1", "D1"]
    assert advisories[0]["basis"] == "courtyard"


def test_a_collision_free_board_load_says_pass_out_loud():
    resp = _call("resolve_best_effort", {"board": _board([
        _d1(footprint="NotInLibrary:D_SMA"),
        _bat1(x=80.0, footprint="NotInLibrary:JST_PH"),
    ])})
    assert resp["ok"] is True, resp
    assert "assembly_advisories" not in resp["result"]
    assert resp["result"]["assembly"] == {"status": "pass", "findings": []}


# ---------------------------------------------------------------------------
# Surface (c): the standalone `assembly_check` worker method
# (DCR 019fd5fd9084 / work item 019fd5fddc09) — {board} -> the same tri-state
# object board_health.assembly carries, computed without proposing copper.
# ---------------------------------------------------------------------------


def test_assembly_check_method_reports_findings():
    resp = _call("assembly_check",
                 {"board": _board([_d1(), _bat1()])})
    assert resp["ok"] is True, resp
    result = resp["result"]
    assert result["status"] == "findings"
    assert result["findings"][0]["components"] == ["BAT1", "D1"]
    assert result["findings"][0]["severity"] == "advisory"
    assert "indeterminate" not in result


def test_assembly_check_method_reports_a_measured_pass():
    resp = _call("assembly_check",
                 {"board": _board([_d1(), _bat1(x=80.0)])})
    assert resp["ok"] is True, resp
    assert resp["result"] == {"status": "pass", "findings": []}


def test_assembly_check_method_reports_indeterminate_components():
    resp = _call("assembly_check", {"board": _board(
        [_d1(), _bat1(x=80.0), {"ref": "MYSTERY", "x_mm": 30, "y_mm": 30}])})
    assert resp["ok"] is True, resp
    result = resp["result"]
    assert result["status"] == "indeterminate"
    assert result["findings"] == []
    assert result["indeterminate"] == [
        {"component": "MYSTERY", "reason": "no_geometry"}]


def test_assembly_check_method_resolves_tolerantly_first():
    """The method must see LIBRARY courtyards, not just captured graphics —
    the resolve-first behaviour the route attach learned in the HITL-4 retry.
    Real seed-library footprints, graphics deliberately stripped: only the
    tolerant resolve can restore the courtyard basis that sees D1/BAT1."""
    d1 = _d1()
    bat1 = _bat1()
    del d1["graphics"], bat1["graphics"]  # pad_extent alone cannot see this pair
    resp = _call("assembly_check", {"board": _board([d1, bat1])})
    assert resp["ok"] is True, resp
    result = resp["result"]
    assert result["status"] == "findings", result
    assert result["findings"][0]["components"] == ["BAT1", "D1"]
    assert result["findings"][0]["basis"] == "courtyard"


def test_assembly_check_method_fault_is_indeterminate_with_error(monkeypatch):
    """Fault injection at the method seam: a checker crash comes back as a
    STRUCTURED indeterminate (+error) result — never a silent pass, never an
    unstructured exception, mirroring the module-level contract."""
    from pcb_worker import methods as methods_module

    def _boom(_board):
        raise RuntimeError("synthetic assembly method fault")

    monkeypatch.setattr(
        methods_module.assembly_advisory, "assembly_check", _boom)
    resp = _call("assembly_check", {"board": _board([_d1(), _bat1()])})
    assert resp["ok"] is True, resp
    result = resp["result"]
    assert result["status"] == "indeterminate"
    assert result["findings"] == []
    assert "synthetic assembly method fault" in result["error"]


def test_assembly_check_method_parse_error_is_structured():
    resp = _call("assembly_check", {"yaml": "]["})
    assert resp["ok"] is False
    assert resp["error"]["kind"] == "parse"
