"""Tests for the source-rewrite (``normalize_board``) — the SB4 sync-back that
persists the compile fold's inline-geometry decision back into the canonical
source, plus the ``normalize`` method handler.

The central guarantee is ANTI-DRIFT: ``normalize_board`` and the compile fold
(``_fold_inline_geometry`` → ``_check_coincidence``) share ONE classification
(``_classify_inline_geometry``), so the override the compiler APPLIES and the
override normalize PERSISTS can never disagree.
"""

from __future__ import annotations

import copy
from pathlib import Path
from types import SimpleNamespace

import pytest
import yaml

from pcb_worker.compile_board import (
    _Diagnostics,
    _check_coincidence,
    _classify_inline_geometry,
    _footprint_pad_map,
    compile_board,
    normalize_board,
)
from pcb_worker.footprints import load_lockfile
from pcb_worker.methods import handle_request
from pcb_worker.resolved_board import DiagnosticSeverity, ResolutionSuccess

TESTDATA = Path(__file__).resolve().parent / "testdata"

# A footprint that resolves in the seed library; pad "1" has drill 0.8 (plated)
# and size (1.2, 2.0) — so an inline ``annulus_diameter_mm: 1.2`` is REDUNDANT and
# ``2.0`` DIVERGES (migrate). Probed live so the test can't drift from the library.
_FOOTPRINT = "Espressif:ESP32-S3-DevKitC"


# An SMD footprint whose pads carry NO drill — so an inline drill_mm on one of its
# pads is a divergence the compiler REJECTS at apply (override_drill_on_drilless_pad).
_SMD_FOOTPRINT = "C_0805"


def _norm_board(pins: list[dict], footprint: str = _FOOTPRINT) -> dict:
    """A minimal 1-component board carrying *pins* — the only shape normalize reads."""
    return {"components": [{"ref": "U1", "footprint": footprint, "pins": pins}]}


def _pins(board: dict) -> list[dict]:
    return board["components"][0]["pins"]


def _codes(diags) -> list[str]:
    return [d.code for d in diags]


# ---------------------------------------------------------------------------
# normalize_board — per-pin outcomes
# ---------------------------------------------------------------------------


def test_divergent_inline_is_migrated_to_override_and_inline_dropped():
    board = _norm_board([{"number": "1", "drill_mm": 0.8, "annulus_diameter_mm": 2.0}])
    normalized, diags = normalize_board(board)
    assert normalized is not None
    pin = _pins(normalized)[0]
    assert pin["override"] == {"drill_mm": 0.8, "annulus_diameter_mm": 2.0}
    assert "drill_mm" not in pin and "annulus_diameter_mm" not in pin
    assert not any(d.severity is DiagnosticSeverity.ERROR for d in diags)


def test_redundant_inline_is_dropped_without_override():
    # annulus 1.2 == footprint pad size[0]; drill 0.8 == footprint drill → redundant.
    board = _norm_board([{"number": "1", "drill_mm": 0.8, "annulus_diameter_mm": 1.2}])
    normalized, diags = normalize_board(board)
    assert normalized is not None
    pin = _pins(normalized)[0]
    assert "override" not in pin
    assert "drill_mm" not in pin and "annulus_diameter_mm" not in pin
    assert not any(d.severity is DiagnosticSeverity.ERROR for d in diags)


def test_ambiguous_no_pad_fails_whole_normalize():
    board = _norm_board([{"number": "999", "drill_mm": 0.8}])  # no such footprint pad
    normalized, diags = normalize_board(board)
    assert normalized is None  # fail-closed: no board
    assert "inline_geometry_without_pad" in _codes(diags)


def test_ambiguous_unverifiable_fails_whole_normalize():
    board = _norm_board([{"number": "1", "drill_mm": "big"}])  # wrong type
    normalized, diags = normalize_board(board)
    assert normalized is None
    assert "inline_geometry_unverifiable" in _codes(diags)


def test_one_ambiguous_pin_blocks_the_migratable_pin_too():
    # A migratable pin AND an ambiguous pin → the WHOLE normalize fails; the good
    # pin is NOT partially normalized (a half-normalized source is worse than none).
    board = _norm_board([
        {"number": "1", "drill_mm": 0.8, "annulus_diameter_mm": 2.0},  # would migrate
        {"number": "999", "drill_mm": 0.8},                             # ambiguous
    ])
    normalized, diags = normalize_board(board)
    assert normalized is None
    assert "inline_geometry_without_pad" in _codes(diags)


def test_existing_override_is_left_unchanged():
    board = _norm_board([{"number": "1", "override": {"annulus_diameter_mm": 2.0}}])
    before = copy.deepcopy(board)
    normalized, diags = normalize_board(board)
    assert normalized == before  # untouched
    assert board == before       # caller's input not mutated
    assert not any(d.severity is DiagnosticSeverity.ERROR for d in diags)


def test_pin_without_inline_is_left_unchanged():
    board = _norm_board([{"number": "1", "x_mm": 1.0, "y_mm": 2.0}])
    before = copy.deepcopy(board)
    normalized, _ = normalize_board(board)
    assert normalized == before


def test_input_board_is_not_mutated():
    board = _norm_board([{"number": "1", "drill_mm": 0.8, "annulus_diameter_mm": 2.0}])
    before = copy.deepcopy(board)
    normalize_board(board)
    assert board == before  # deep-copy — caller keeps its source verbatim


def test_output_carries_no_resolve_artifacts():
    board = _norm_board([{"number": "1", "drill_mm": 0.8, "annulus_diameter_mm": 2.0}])
    normalized, _ = normalize_board(board)
    comp = normalized["components"][0]
    for artifact in ("pads", "graphics", "has_pad_geometry"):
        assert artifact not in comp, f"resolve artifact {artifact!r} leaked into normalized board"


def test_non_dict_board_fails_closed():
    normalized, diags = normalize_board(["not", "a", "board"])
    assert normalized is None
    assert "invalid_board" in _codes(diags)


# ---------------------------------------------------------------------------
# FIX 1 — normalize must not persist an override the compiler would REJECT at apply
# (invariant: a board normalize succeeds on must compile).
# ---------------------------------------------------------------------------


def test_value_invalid_divergent_inline_fails_not_persisted():
    # drill_mm -0.5 diverges from the footprint (→ MIGRATE) but is value-invalid;
    # the compiler's apply-time guard rejects it (invalid_pin_override). normalize
    # MUST fail-closed rather than write a source every future compile rejects.
    board = _norm_board([{"number": "1", "drill_mm": -0.5}])
    normalized, diags = normalize_board(board)
    assert normalized is None
    assert "invalid_pin_override" in _codes(diags)


def test_drill_on_smd_pad_inline_fails_not_persisted():
    # An inline drill on a drill-less SMD pad diverges (→ MIGRATE) but the compiler
    # rejects it at apply (override_drill_on_drilless_pad) → normalize fail-closed.
    board = _norm_board([{"number": "1", "drill_mm": 0.5}], footprint=_SMD_FOOTPRINT)
    normalized, diags = normalize_board(board)
    assert normalized is None
    assert "override_drill_on_drilless_pad" in _codes(diags)


def test_normalize_success_implies_compile_success():
    # The FIX-1 invariant, end to end: whatever normalize returns a board for, the
    # compiler accepts (no pad-override rejection surfaces on recompile).
    board = yaml.safe_load((TESTDATA / "smart_remote.yaml").read_text(encoding="utf-8"))
    normalized, _ = normalize_board(board)
    assert normalized is not None
    result = compile_board(normalized)
    assert isinstance(result, ResolutionSuccess)


# ---------------------------------------------------------------------------
# FIX 2 — a source-mutating action records what it changed (transparency).
# ---------------------------------------------------------------------------


def test_migrated_pin_records_info():
    board = _norm_board([{"number": "1", "drill_mm": 0.8, "annulus_diameter_mm": 2.0}])
    _, diags = normalize_board(board)
    infos = [d for d in diags if d.code == "inline_pin_geometry_migrated"]
    assert len(infos) == 1
    assert infos[0].severity is DiagnosticSeverity.INFO
    assert "annulus" in infos[0].message  # names the diverging field


def test_dropped_redundant_pin_records_info():
    board = _norm_board([{"number": "1", "drill_mm": 0.8, "annulus_diameter_mm": 1.2}])
    _, diags = normalize_board(board)
    dropped = [d for d in diags if d.code == "inline_pin_geometry_dropped"]
    assert len(dropped) == 1 and dropped[0].severity is DiagnosticSeverity.INFO


# ---------------------------------------------------------------------------
# FIX 3 — an override-bearing pin also drops its superseded inline keys.
# ---------------------------------------------------------------------------


def test_override_pin_drops_superseded_inline_keys():
    board = _norm_board([{
        "number": "1",
        "override": {"annulus_diameter_mm": 2.0},
        "drill_mm": 0.8,               # legacy inline superseded by the override
        "annulus_diameter_mm": 1.2,
    }])
    normalized, diags = normalize_board(board)
    assert normalized is not None
    pin = _pins(normalized)[0]
    assert pin["override"] == {"annulus_diameter_mm": 2.0}  # override untouched
    assert "drill_mm" not in pin and "annulus_diameter_mm" not in pin  # inline gone
    assert "inline_pin_geometry_dropped" in _codes(diags)


def test_override_pin_with_superseded_inline_is_idempotent():
    board = _norm_board([{
        "number": "1", "override": {"annulus_diameter_mm": 2.0}, "drill_mm": 0.8,
    }])
    once, _ = normalize_board(board)
    twice, d2 = normalize_board(once)
    assert twice == once
    # second pass has nothing left to drop
    assert "inline_pin_geometry_dropped" not in _codes(d2)


# ---------------------------------------------------------------------------
# Idempotence
# ---------------------------------------------------------------------------


def test_normalize_is_idempotent():
    board = _norm_board([
        {"number": "1", "drill_mm": 0.8, "annulus_diameter_mm": 2.0},  # migrate
        {"number": "2", "drill_mm": 0.8, "annulus_diameter_mm": 1.2},  # redundant
    ])
    once, _ = normalize_board(board)
    twice, _ = normalize_board(once)
    assert twice == once  # a second pass is a no-op


def test_smart_remote_normalize_is_idempotent():
    board = yaml.safe_load((TESTDATA / "smart_remote.yaml").read_text(encoding="utf-8"))
    once, d1 = normalize_board(board)
    assert once is not None and not any(x.severity is DiagnosticSeverity.ERROR for x in d1)
    twice, _ = normalize_board(once)
    assert twice == once


# ---------------------------------------------------------------------------
# Anti-drift — the key test
# ---------------------------------------------------------------------------


def test_compile_applied_override_equals_normalize_written_override():
    board = _norm_board([{"number": "1", "drill_mm": 0.8, "annulus_diameter_mm": 2.0}])

    # What COMPILE synthesizes+applies, via _check_coincidence's returned map.
    lock = load_lockfile()
    pad_map = _footprint_pad_map(_FOOTPRINT, library_root=None, lock=lock)
    definition = SimpleNamespace(pads=list(pad_map.values()))
    applied = _check_coincidence(board["components"][0], definition, "U1", _Diagnostics())

    # What NORMALIZE writes back to the source pin.
    normalized, _ = normalize_board(board)
    written = {p["number"]: p["override"]
               for p in _pins(normalized) if "override" in p}

    assert applied == written == {"1": {"drill_mm": 0.8, "annulus_diameter_mm": 2.0}}


def test_shared_classifier_backs_both_paths():
    # The classifier is the single decision both callers consume.
    lock = load_lockfile()
    pad = _footprint_pad_map(_FOOTPRINT, library_root=None, lock=lock)["1"]
    pin = {"number": "1", "drill_mm": 0.8, "annulus_diameter_mm": 2.0}
    verdict = _classify_inline_geometry(pin, pad, "1", ["drill_mm", "annulus_diameter_mm"], "U1")
    assert verdict.outcome == "migrate"
    assert verdict.override == {"drill_mm": 0.8, "annulus_diameter_mm": 2.0}


# ---------------------------------------------------------------------------
# Functional floor — semantics preserved through the round-trip
# ---------------------------------------------------------------------------


def _placed_pad_geometry(result) -> dict:
    """{(comp_ref, pad_source_id): (position, size, drill, annulus, pad_type)}."""
    out: dict = {}
    for comp in result.board.components:
        for pad in comp.placed_pads:
            out[(comp.ref, pad.source_id)] = (
                pad.position, pad.size, pad.drill, pad.annulus, pad.pad_type)
    return out


def test_recompiling_normalized_board_preserves_placed_geometry():
    original = yaml.safe_load((TESTDATA / "smart_remote.yaml").read_text(encoding="utf-8"))
    normalized, diags = normalize_board(original)
    assert normalized is not None
    assert not any(d.severity is DiagnosticSeverity.ERROR for d in diags)

    base = compile_board(original)
    round_trip = compile_board(normalized)
    assert isinstance(base, ResolutionSuccess)
    assert isinstance(round_trip, ResolutionSuccess)
    assert _placed_pad_geometry(round_trip) == _placed_pad_geometry(base)


# ---------------------------------------------------------------------------
# normalize method handler
# ---------------------------------------------------------------------------


def _call(method: str, params: dict) -> dict:
    resp = handle_request({"id": "r1", "method": method, "params": params})
    assert resp is not None and resp["id"] == "r1"
    return resp


def test_handler_returns_normalized_board():
    board = _norm_board([{"number": "1", "drill_mm": 0.8, "annulus_diameter_mm": 2.0}])
    resp = _call("normalize", {"board": board})
    assert resp["ok"] is True
    result = resp["result"]
    assert result["ok"] is True
    pin = result["board"]["components"][0]["pins"][0]
    assert pin["override"] == {"drill_mm": 0.8, "annulus_diameter_mm": 2.0}
    assert "drill_mm" not in pin
    assert isinstance(result["warnings"], list)
    # The rewrite is surfaced to the host: a migrate INFO rides the warnings list.
    assert any(w["code"] == "inline_pin_geometry_migrated" for w in result["warnings"])


def test_handler_ambiguous_board_is_structured_error():
    board = _norm_board([{"number": "999", "drill_mm": 0.8}])
    resp = _call("normalize", {"board": board})
    assert resp["ok"] is False
    assert resp["error"]["kind"] == "normalize"
    assert resp["error"]["diagnostics"]
    assert any(d["code"] == "inline_geometry_without_pad"
               for d in resp["error"]["diagnostics"])


def test_handler_parse_error_is_structured():
    resp = _call("normalize", {"yaml": "name: [unterminated"})
    assert resp["ok"] is False
    assert resp["error"]["kind"] == "parse"


def test_handler_writes_no_file(tmp_path):
    # normalize is PURE; even with an out_dir-looking param it must not write.
    board = _norm_board([{"number": "1", "drill_mm": 0.8, "annulus_diameter_mm": 2.0}])
    before = set(tmp_path.iterdir())
    _call("normalize", {"board": board, "out_dir": str(tmp_path)})
    assert set(tmp_path.iterdir()) == before  # nothing written
