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
