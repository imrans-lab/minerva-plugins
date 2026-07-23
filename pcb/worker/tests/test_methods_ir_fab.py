"""W8.2 — the LIVE fabrication methods route through the ResolvedBoard IR.

These drive ``methods.handle_request({"method": "gerbers"/"generate", ...})`` — the
PRODUCTION worker entry point — to prove the cutover reaches the reply the Go
bridge actually returns. Before W8.2 the fab methods ran a best-effort resolve and
IGNORED pin overrides, per-pad rotation and the bottom-side mirror; now they
COMPILE (strict) → ``ir_to_board_dict``/``ir_to_kicad_board_dict`` → emit, so all
three reach the emitted bytes IN THE REPLY. The pipeline under test:

    handle_request(gerbers/generate)
        -> compile_board(board)              (STRICT; fail-closed)
        -> ir_to_board_dict / ir_to_kicad_board_dict
        -> gerber.build_gerbers(placed=True) / kicad.generate

The emitter-level proofs live in test_ir_adapter.py; these are the METHODS-LEVEL
proofs — the same wins surfacing through the real request handler — plus the
strict fail-closed cutover behavior and diagnostic forwarding.
"""

from __future__ import annotations

import re

from pcb_worker.methods import handle_request


# ---------------------------------------------------------------------------
# Helpers (mirror the board builder + gerber/Excellon parsers in test_ir_adapter).
# ---------------------------------------------------------------------------


def _board(fp: str, *, layer: str = "top", x: float = 10.0, y: float = 10.0,
           rotation_deg: float = 0.0, pins=None) -> dict:
    comp = {"ref": "X1", "footprint": fp, "x_mm": x, "y_mm": y,
            "rotation_deg": rotation_deg, "layer": layer}
    if pins is not None:
        comp["pins"] = pins
    return {
        "version": 1, "name": "brd", "width_mm": 40, "height_mm": 40,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [comp],
    }


def _empty_board() -> dict:
    """A component-free board (just outline). Compiles with ZERO diagnostics —
    every REAL seed footprint surfaces documentation-only captured-geometry
    diagnostics at compile, so an empty `warnings` list is only reachable via a
    board with no footprints. This is the post-cutover clean-board case."""
    return {
        "version": 1, "name": "brd", "width_mm": 40, "height_mm": 40,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [],
    }


def _call(method: str, params: dict) -> dict:
    resp = handle_request({"id": "r1", "method": method, "params": params})
    assert resp is not None and resp["id"] == "r1"
    return resp


def _gerbers(board: dict, name: str = "brd") -> dict:
    resp = _call("gerbers", {"board": board, "name": name})
    assert resp["ok"] is True, resp
    return resp["result"]["files"]


def _decimals(text: str) -> int:
    m = re.search(r"%FSLAX\d(\d)Y\d\d", text)
    assert m, "no %FS coordinate-format line"
    return int(m.group(1))


def _flashes(text: str) -> list[tuple[float, float]]:
    d = _decimals(text)
    return [(int(x) / 10 ** d, int(y) / 10 ** d)
            for x, y in re.findall(r"X(-?\d+)Y(-?\d+)D03\*", text)]


def _apertures(text: str) -> set[str]:
    return set(re.findall(r"%ADD\d+(.*?)\*%", text))


def _excellon_tools(text: str) -> set[str]:
    return set(re.findall(r"T\d+C([\d.]+)", text))


def _excellon_ys(text: str) -> set[float]:
    return {float(y) for _x, y in re.findall(r"X([\d.]+)Y([\d.]+)", text)}


def _near(points, target, tol: float = 1e-3) -> bool:
    return any(abs(px - target[0]) < tol and abs(py - target[1]) < tol
              for px, py in points)


# ---------------------------------------------------------------------------
# 1. Happy path — the method compiles + emits a full fab set.
# ---------------------------------------------------------------------------


def test_gerbers_method_happy_path_emits_full_layer_set():
    files = _gerbers(_board("R_0805"))
    # Six copper/mask/silk/edge layers; an all-SMD board has no drills.
    assert sum(1 for k in files if k.endswith(".gbr")) == 6
    assert {"brd-F_Cu.gbr", "brd-B_Cu.gbr", "brd-F_Mask.gbr", "brd-B_Mask.gbr",
            "brd-F_SilkS.gbr", "brd-Edge_Cuts.gbr"} <= set(files)
    # ABSOLUTE placement reached copper (not the footprint-local ±0.95 origin).
    flashes = _flashes(files["brd-F_Cu.gbr"])
    assert _near(flashes, (9.05, 10.0)) and _near(flashes, (10.95, 10.0)), flashes


def test_generate_method_happy_path_emits_kicad_triplet():
    resp = _call("generate", {"board": _board("R_0805")})
    assert resp["ok"] is True, resp
    files = resp["result"]["files"]
    assert any(k.endswith(".kicad_pcb") for k in files)
    assert any(k.endswith(".kicad_sch") for k in files)
    assert any(k.endswith(".kicad_pro") for k in files)
    pcb = next(v for k, v in files.items() if k.endswith(".kicad_pcb"))
    assert pcb.startswith("(kicad_pcb") and "(footprint" in pcb


# ---------------------------------------------------------------------------
# 2. WIN — a pin override reaches the LIVE fab reply (the core W8.2 win).
#    Contrast: the pre-W8.2 best-effort path ignored pin overrides entirely.
# ---------------------------------------------------------------------------


def test_override_drill_reaches_gerbers_method_reply():
    baseline = _gerbers(_board("Package_DIP:DIP-6_W7.62mm_Socket"))
    assert _excellon_tools(baseline["brd-PTH.drl"]) == {"0.800"}

    files = _gerbers(_board("Package_DIP:DIP-6_W7.62mm_Socket",
                            pins=[{"number": "1", "override": {"drill_mm": 1.3}}]))
    tools = _excellon_tools(files["brd-PTH.drl"])
    assert "1.300" in tools, tools     # the OVERRIDDEN pin-1 hole, in the reply
    assert "0.800" in tools            # the other five keep the footprint drill


def test_override_annulus_reaches_gerbers_method_reply():
    files = _gerbers(_board("Package_DIP:DIP-6_W7.62mm_Socket",
                            pins=[{"number": "1", "override": {"annulus_diameter_mm": 3.0}}]))
    apertures = _apertures(files["brd-F_Cu.gbr"])
    assert "C,3.0" in apertures, apertures   # the OVERRIDDEN pin-1 annulus
    assert "C,1.6" in apertures              # others keep the footprint annulus


def test_override_drill_reaches_generate_method_reply():
    resp = _call("generate", {"board": _board(
        "Package_DIP:DIP-6_W7.62mm_Socket",
        pins=[{"number": "1", "override": {"drill_mm": 1.3}}])})
    assert resp["ok"] is True, resp
    pcb = next(v for k, v in resp["result"]["files"].items() if k.endswith(".kicad_pcb"))
    drills = set(re.findall(r"\(drill ([\d.]+)\)", pcb))
    assert "1.3" in drills, drills     # the OVERRIDDEN pin-1 drill, in the reply
    assert "0.8" in drills             # the other pins keep the footprint drill


# ---------------------------------------------------------------------------
# 3. WIN — the bottom-side MIRROR reaches the LIVE fab reply.
# ---------------------------------------------------------------------------


def test_bottom_side_component_lands_on_back_copper_via_method():
    top = _gerbers(_board("EVP-ASAC1A:SW_EVP-ASAC1A", layer="top"))
    bot = _gerbers(_board("EVP-ASAC1A:SW_EVP-ASAC1A", layer="bottom"))
    assert top["brd-F_Cu.gbr"].count("D03*") > 0
    assert top["brd-B_Cu.gbr"].count("D03*") == 0
    assert bot["brd-F_Cu.gbr"].count("D03*") == 0
    assert bot["brd-B_Cu.gbr"].count("D03*") > 0


def test_bottom_side_mirror_folds_the_coordinate_via_method():
    top = _gerbers(_board("Package_DIP:DIP-6_W7.62mm_Socket", layer="top"))
    bot = _gerbers(_board("Package_DIP:DIP-6_W7.62mm_Socket", layer="bottom"))
    top_ys = _excellon_ys(top["brd-PTH.drl"])
    bot_ys = _excellon_ys(bot["brd-PTH.drl"])
    assert top_ys == {10.0, 12.54, 15.08}, top_ys
    # Y-mirror about the component origin (20 - y): the fold reached the reply.
    assert bot_ys == {round(20.0 - y, 3) for y in top_ys}, bot_ys
    assert bot_ys != top_ys


# ---------------------------------------------------------------------------
# 4. Strict fail-closed — an uncompilable board returns a structured compile
#    error with NO fallback to the (removed) best-effort emitter.
# ---------------------------------------------------------------------------


def test_unresolvable_footprint_fails_closed_gerbers():
    board = _board("NoSuchLib:NoSuchFootprint")
    resp = _call("gerbers", {"board": board, "name": "brd"})
    assert resp["ok"] is False
    assert resp["error"]["kind"] == "compile"
    diags = resp["error"]["diagnostics"]
    assert any(d["severity"] == "error" and d["code"] == "footprint_unresolved"
               for d in diags), diags
    assert resp["error"]["message"]  # a human summary of the first error


def test_unresolvable_footprint_fails_closed_generate():
    resp = _call("generate", {"board": _board("NoSuchLib:NoSuchFootprint")})
    assert resp["ok"] is False
    assert resp["error"]["kind"] == "compile"
    assert any(d["code"] == "footprint_unresolved"
               for d in resp["error"]["diagnostics"])


# ---------------------------------------------------------------------------
# 5. Diagnostics forwarded — compile INFO/WARNING reach the reply's `warnings`.
# ---------------------------------------------------------------------------


def test_compile_diagnostics_forwarded_as_warnings_gerbers():
    # R_0805 carries silk/courtyard graphics the gerber copper/mask pass does not
    # emit -> compile raises `captured_geometry_not_emitted` (WARNING); a v1 board
    # also gets `ordinal_ids` (INFO) once it has traces. Use a board with a trace
    # so BOTH are present, proving INFO and WARNING both forward.
    board = _board("R_0805")
    board["nets"] = [{"name": "N", "pins": ["X1.1"]}]
    board["traces"] = [{"net": "N", "layer": "top", "width_mm": 0.3,
                        "points": [{"x_mm": 9.05, "y_mm": 10}, {"x_mm": 20, "y_mm": 10}]}]
    resp = _call("gerbers", {"board": board, "name": "brd"})
    assert resp["ok"] is True, resp
    codes = {(w["severity"], w["code"]) for w in resp["result"]["warnings"]}
    assert ("warning", "captured_geometry_not_emitted") in codes, codes
    assert ("info", "ordinal_ids") in codes, codes


def test_compile_diagnostics_forwarded_as_warnings_generate():
    resp = _call("generate", {"board": _board("R_0805")})
    assert resp["ok"] is True, resp
    codes = {w["code"] for w in resp["result"]["warnings"]}
    assert "captured_geometry_not_emitted" in codes, codes


def test_clean_compiled_board_forwards_empty_warnings_gerbers():
    # Supersedes test_cam_conformance's placeholder-footprint clean_board test: the
    # forward is additive AND present-but-empty on a clean board (no key drift for
    # consumers). A component-free board compiles with no diagnostics -> [].
    resp = _call("gerbers", {"board": _empty_board(), "name": "brd"})
    assert resp["ok"] is True, resp
    assert resp["result"]["warnings"] == []


def test_clean_compiled_board_forwards_empty_warnings_generate():
    resp = _call("generate", {"board": _empty_board()})
    assert resp["ok"] is True, resp
    assert resp["result"]["warnings"] == []


# The reply's `warnings` merges BOTH channels: the compile diagnostics (above) AND
# the EMITTER's own diagnostics. `th_pad_shape_circularized` is raised by the
# gerber/kicad emitters (NOT by compile) when an oblong TH land is circularized to
# a round annulus, so these prove the emitter warning channel still reaches the
# methods reply post-cutover — the capability the removed test_cam_conformance
# methods-forwarding tests covered, now on the real IR path.


def test_emitter_channel_warning_forwarded_gerbers():
    resp = _call("gerbers", {"board": _board(
        "Connector_JST:JST_PH_S2B-PH-K_1x02_P2.00mm_Horizontal"), "name": "brd"})
    assert resp["ok"] is True, resp
    codes = {w["code"] for w in resp["result"]["warnings"]}
    assert "th_pad_shape_circularized" in codes, codes


def test_emitter_channel_warning_forwarded_generate():
    resp = _call("generate", {"board": _board(
        "Connector_JST:JST_PH_S2B-PH-K_1x02_P2.00mm_Horizontal")})
    assert resp["ok"] is True, resp
    codes = {w["code"] for w in resp["result"]["warnings"]}
    assert "th_pad_shape_circularized" in codes, codes


# ---------------------------------------------------------------------------
# 6. A compile ERROR (missing design_rules) is a structured compile error, not
#    a crash — the loop stays alive and the diagnostics are surfaced.
# ---------------------------------------------------------------------------


def test_missing_design_rules_is_structured_compile_error():
    board = _board("R_0805")
    del board["design_rules"]
    resp = _call("gerbers", {"board": board, "name": "brd"})
    assert resp["ok"] is False
    assert resp["error"]["kind"] == "compile"
    assert resp["error"]["diagnostics"]  # carries the blocking diagnostics
    # generate fails closed the same way (no crash, structured error).
    resp2 = _call("generate", {"board": board})
    assert resp2["ok"] is False and resp2["error"]["kind"] == "compile"
