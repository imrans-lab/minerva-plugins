"""Footprint-resolve step tests (offline).

Covers:
  (a) resolving the smart-remote board attaches F.SilkS + F.CrtYd graphics to
      every component; ESP32 (U1) gains its body-outline silk; coincidence passes,
  (b) the fail-closed coincidence guard: a pin nudged 1mm off its footprint pad
      raises ResolveCoincidenceError,
  (c) determinism: resolve twice -> identical output, input not mutated,
  (d) the `resolve` worker method's {ok, board, stats} envelope.

All fixtures are vendored in-repo; no network access.
"""

from __future__ import annotations

import copy
from pathlib import Path

import pytest
import yaml

from pcb_worker import resolve
from pcb_worker.methods import handle_request
from pcb_worker.resolve import ResolveCoincidenceError, resolve_board

HERE = Path(__file__).resolve().parent
BOARD_YAML = HERE / "testdata" / "footprints" / "smart-remote-orig.yaml"


def _load_board() -> dict:
    return yaml.safe_load(BOARD_YAML.read_text(encoding="utf-8"))


def _silk(comp: dict) -> list:
    return [g for g in comp.get("graphics", []) if g["layer"] == "F.SilkS"]


def _crtyd(comp: dict) -> list:
    return [g for g in comp.get("graphics", []) if g["layer"] == "F.CrtYd"]


# ---------------------------------------------------------------------------
# (a) Happy path: every component gains graphics; ESP32 body outline present.
# ---------------------------------------------------------------------------


def test_resolve_attaches_graphics_to_every_component():
    board = _load_board()
    resolved = resolve_board(board)

    total_silk = 0
    total_crtyd = 0
    for comp in resolved["components"]:
        assert "graphics" in comp, f"{comp.get('ref')}: no graphics attached"
        assert all(g["layer"] in {"F.SilkS", "F.CrtYd"} for g in comp["graphics"])
        total_silk += len(_silk(comp))
        total_crtyd += len(_crtyd(comp))

    assert total_silk > 0, "board gained no silkscreen graphics at all"
    assert total_crtyd > 0, "board gained no courtyard graphics at all"


def test_resolve_esp32_gets_body_outline_silk():
    resolved = resolve_board(_load_board())
    u1 = next(c for c in resolved["components"] if c["ref"] == "U1")
    silk_lines = [g for g in _silk(u1) if g["kind"] == "line"]
    assert len(silk_lines) >= 1, "ESP32 (U1) has no F.SilkS body-outline line"
    assert len(_crtyd(u1)) >= 1, "ESP32 (U1) has no courtyard graphic"


def test_resolve_coincidence_passes_for_smart_remote():
    # No exception == guard passed for all 10 components.
    resolve_board(_load_board())


# ---------------------------------------------------------------------------
# (a2) Pad geometry: resolve also attaches real per-component pads.
# ---------------------------------------------------------------------------


def test_resolve_attaches_pads_to_every_component():
    resolved = resolve_board(_load_board())
    for comp in resolved["components"]:
        assert comp.get("has_pad_geometry") is True, \
            f"{comp.get('ref')}: has_pad_geometry not set"
        pads = comp.get("pads")
        assert isinstance(pads, list) and len(pads) > 0, \
            f"{comp.get('ref')}: no pads attached"
        # Contract shape consumed by pcb_component.gd::_pads_from_list.
        for pad in pads:
            assert set(pad) >= {
                "number", "type", "shape", "position", "size", "drill", "layers"}
            assert {"x", "y"} <= set(pad["position"])
            assert {"width", "height"} <= set(pad["size"])
            assert {"x", "y"} <= set(pad["drill"])
            assert pad["type"] in {"smd", "thru_hole", "np_thru_hole"}


def test_resolve_pad_counts_match_footprints():
    resolved = resolve_board(_load_board())
    by_ref = {c["ref"]: c for c in resolved["components"]}
    # ESP32-S3-DevKitC-1 (U1) is a 44-pin module; MIC1 is a 6-pin DIP.
    assert len(by_ref["U1"]["pads"]) == 44
    assert len(by_ref["MIC1"]["pads"]) == 6


def test_resolve_pad_shape_and_size_fidelity():
    resolved = resolve_board(_load_board())
    u1 = next(c for c in resolved["components"] if c["ref"] == "U1")
    # Real geometry, not a uniform circle stand-in: some pad is non-rect OR
    # has an asymmetric footprint, and every size is positive.
    real = any(
        pad["shape"] != "rect"
        or pad["size"]["width"] != pad["size"]["height"]
        for pad in u1["pads"])
    assert real, "U1 pads look like uniform stand-ins, not real geometry"
    for pad in u1["pads"]:
        assert pad["size"]["width"] > 0 and pad["size"]["height"] > 0


def test_resolve_tht_vs_smd_drill():
    resolved = resolve_board(_load_board())
    by_ref = {c["ref"]: c for c in resolved["components"]}
    # U1 is thru-hole → drilled copper.
    assert any(pad["drill"]["x"] > 0 for pad in by_ref["U1"]["pads"]), \
        "expected at least one drilled (thru-hole) pad on U1"
    assert all(pad["type"] == "thru_hole" for pad in by_ref["U1"]["pads"])
    # SW1 (EVP-ASAC1A tactile switch) is SMD → EVERY pad drill-less.
    sw1 = by_ref["SW1"]
    assert all(pad["drill"]["x"] == 0 and pad["drill"]["y"] == 0 for pad in sw1["pads"]), \
        "expected all SMD pads on SW1 to be drill-less"
    assert all(pad["type"] == "smd" for pad in sw1["pads"])


def test_resolve_pads_coregister_with_declared_pins():
    board = _load_board()
    resolved = resolve_board(board)
    u1_in = next(c for c in board["components"] if c["ref"] == "U1")
    u1_out = next(c for c in resolved["components"] if c["ref"] == "U1")
    declared = {str(p["number"]): (p["x_mm"], p["y_mm"]) for p in u1_in["pins"]}
    checked = 0
    for pad in u1_out["pads"]:
        pin = declared.get(pad["number"])
        if pin is None:
            continue
        assert abs(pad["position"]["x"] - pin[0]) <= 0.01
        assert abs(pad["position"]["y"] - pin[1]) <= 0.01
        checked += 1
    assert checked > 0, "no U1 pads matched a declared pin number"


# ---------------------------------------------------------------------------
# (b) NEGATIVE: a pin moved off its pad trips the fail-closed guard.
# ---------------------------------------------------------------------------


def test_resolve_fails_when_pin_desyncs_from_pad():
    board = _load_board()
    # Nudge U1 pin 1 by 1mm — far beyond the 0.01mm coincidence tolerance.
    u1 = next(c for c in board["components"] if c["ref"] == "U1")
    pin1 = next(p for p in u1["pins"] if str(p["number"]) == "1")
    pin1["x_mm"] += 1.0

    with pytest.raises(ResolveCoincidenceError) as ei:
        resolve_board(board)
    err = ei.value
    assert err.ref == "U1"
    assert err.pin == "1"
    assert err.delta_mm == pytest.approx(1.0, abs=1e-6)


# ---------------------------------------------------------------------------
# (c) Determinism + no input mutation.
# ---------------------------------------------------------------------------


def test_resolve_is_deterministic():
    board = _load_board()
    a = resolve_board(board)
    b = resolve_board(board)
    assert a == b


def test_resolve_does_not_mutate_input():
    board = _load_board()
    snapshot = copy.deepcopy(board)
    resolve_board(board)
    assert board == snapshot, "resolve_board mutated its input"


# ---------------------------------------------------------------------------
# (d) Worker method envelope.
# ---------------------------------------------------------------------------


def _call(method: str, params: dict) -> dict:
    resp = handle_request({"id": "r1", "method": method, "params": params})
    assert resp is not None
    assert resp["id"] == "r1"
    return resp


def test_resolve_method_returns_board_and_stats():
    resp = _call("resolve", {"yaml": BOARD_YAML.read_text(encoding="utf-8")})
    assert resp["ok"] is True
    result = resp["result"]
    assert result["ok"] is True
    assert "components" in result["board"]
    stats = result["stats"]
    assert stats["components"] == len(result["board"]["components"])
    assert stats["silk_graphics"] > 0
    assert stats["courtyard_graphics"] > 0


def test_resolve_method_reports_coincidence_error():
    board = _load_board()
    u1 = next(c for c in board["components"] if c["ref"] == "U1")
    pin1 = next(p for p in u1["pins"] if str(p["number"]) == "1")
    pin1["y_mm"] += 1.0

    resp = _call("resolve", {"board": board})
    assert resp["ok"] is False
    assert resp["error"]["kind"] == "coincidence"
    assert resp["error"]["ref"] == "U1"
    assert resp["error"]["pin"] == "1"


def test_resolve_method_parse_error():
    resp = _call("resolve", {})
    assert resp["ok"] is False
    assert resp["error"]["kind"] == "parse"


def test_board_graphic_stats_matches_manual_count():
    resolved = resolve_board(_load_board())
    stats = resolve.board_graphic_stats(resolved)
    manual_silk = sum(len(_silk(c)) for c in resolved["components"])
    manual_crtyd = sum(len(_crtyd(c)) for c in resolved["components"])
    assert stats["silk_graphics"] == manual_silk
    assert stats["courtyard_graphics"] == manual_crtyd


# ---------------------------------------------------------------------------
# SB2 (019f8acfd651): the pad projection must THREAD the fab-affecting fields the
# footprint parser extracts (corner_rratio / solder_mask_margin / rotation) —
# previously dropped, so every resolved roundrect fell back to the emitter's
# default corner ratio and every pad to the global mask clearance. The live
# emitters read `corner_rratio` + `solder_mask_margin` off comp["pads"].
# ---------------------------------------------------------------------------

from pcb_worker.footprints import parse_kicad_mod
from pcb_worker.resolve import _pads_from_parsed

_PAD_FIELDS = HERE / "testdata" / "k1_lossless" / "PAD_FIELDS.kicad_mod"


def test_pads_from_parsed_threads_fab_optionals_from_real_footprint():
    # PAD_FIELDS pad "1": smd roundrect (at -1 0 90), roundrect_rratio 0.25,
    # solder_mask_margin 0.05, solder_paste_margin -0.02. The projection must
    # carry all four (roundrect_rratio NAME-MAPPED to corner_rratio, the key the
    # emitters read); the plain rect pad "3" must carry none of them.
    pads = _pads_from_parsed(parse_kicad_mod(_PAD_FIELDS)["pads"])
    by_num = {p["number"]: p for p in pads}
    p1 = by_num["1"]
    assert p1["corner_rratio"] == pytest.approx(0.25)   # name-mapped from roundrect_rratio
    assert p1["solder_mask_margin"] == pytest.approx(0.05)
    assert p1["solder_paste_margin"] == pytest.approx(-0.02)
    assert p1["rotation"] == pytest.approx(90)
    p3 = by_num["3"]
    for k in ("corner_rratio", "solder_mask_margin", "solder_paste_margin", "rotation"):
        assert k not in p3, f"plain rect pad should not carry {k}"


def test_pads_from_parsed_name_maps_roundrect_rratio_not_hardcoded():
    # A non-default ratio proves the value is threaded, not defaulted to 0.25.
    parsed = [{"number": "9", "type": "smd", "shape": "roundrect",
               "x_mm": 0.0, "y_mm": 0.0, "size": (2.0, 1.0), "layers": ["F.Cu"],
               "roundrect_rratio": 0.4, "solder_mask_margin": 0.12}]
    out = _pads_from_parsed(parsed)[0]
    assert out["corner_rratio"] == 0.4
    assert out["solder_mask_margin"] == 0.12
    # A pad with no optionals stays clean (no None-valued keys injected).
    plain = _pads_from_parsed([{"number": "1", "type": "smd", "shape": "rect",
                                "x_mm": 0.0, "y_mm": 0.0, "size": (1.0, 1.0),
                                "layers": ["F.Cu"]}])[0]
    assert "corner_rratio" not in plain and "solder_mask_margin" not in plain


def test_pads_from_parsed_and_footprint_def_agree_on_fab_optionals():
    # The TWO board-dict projections — resolve._pads_from_parsed and
    # FootprintDefinition.to_board_pad_dicts — must stay byte-identical on the
    # SB2-threaded fields (corner_rratio/margins/rotation), not just the base keys,
    # else the lockstep drifts silently (Fable SB2 note 1: no parity fixture
    # otherwise exercises these). PAD_FIELDS pads "1" (roundrect + margins +
    # rotation) and "3" (plain rect) exercise them. Pad "2" is SKIPPED: its oval
    # drill carries a PRE-EXISTING resolve-vs-footprint_def divergence filed
    # separately (out of SB2 scope).
    from pcb_worker.footprint_def import FootprintDefinition
    parsed = parse_kicad_mod(_PAD_FIELDS)
    from_resolve = {p["number"]: p for p in _pads_from_parsed(parsed["pads"])}
    from_fpdef = {p["number"]: p
                  for p in FootprintDefinition.from_kicad_parsed(parsed).to_board_pad_dicts()}
    for num in ("1", "3"):
        assert from_resolve[num] == from_fpdef[num], f"projection drift on pad {num}"
    # Guard against both projections agreeing by both DROPPING the optionals.
    assert from_resolve["1"]["corner_rratio"] == pytest.approx(0.25)
    assert from_resolve["1"]["solder_mask_margin"] == pytest.approx(0.05)
    assert from_resolve["1"]["rotation"] == pytest.approx(90)
