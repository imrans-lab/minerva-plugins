"""Stage-2 step 3: resolve wired into the fab path (gated) + the single
resolve-aware pad_source accessor.

TEETH proving the wiring is LIVE and CORRECT while DEFAULT output is unchanged:

  (a) GEOMETRY-DIFF old-vs-new — the crux. A real board whose SMD pins carry NO
      pad geometry compiles to the 1.0x0.6 PLACEHOLDER on the raw path; the SAME
      board resolve_board()-ed compiles to the REAL 2.0x2.0 footprint lands. The
      existing oracle geometry_diff (REUSED, not edited) shows a non-empty diff,
      and the specific SMD apertures flip placeholder -> real.
  (b) GATE DEFAULT-OFF no-op — methods._gerbers/_generate/_drc with no
      resolve_geometry param are byte-identical to a raw compile.
  (c) GATE ERROR PASSTHROUGH — a coincidence failure with the gate ON returns a
      STRUCTURED error (kind coincidence), not a crash.
  (d) FUNCTIONAL FLOOR (non-mocked) — the real methods dispatch over a real
      resolvable board with resolve_geometry=True returns fab files carrying real
      (non-placeholder) pad geometry. Real board -> real resolve -> real gerber.

Bug: 019f7736b236 (placeholder SMD pads). The DEFAULT gate stays OFF this step —
goldens and the pad-bug xfail are untouched; a later step flips the gate.
"""

from __future__ import annotations

import copy
from pathlib import Path

import pytest
import yaml

from pcb_worker import gerber, kicad, pad_source, resolve
from pcb_worker.methods import (
    RESOLVE_FAB_GEOMETRY_DEFAULT,
    _drc,
    _generate,
    _gerbers,
    handle_request,
)
from tests.oracle.geometry_diff import diff_geometry, parse_output_set

HERE = Path(__file__).resolve().parent
# The one board whose footprints all resolve cleanly (coincidence passes).
BOARD_YAML = HERE / "testdata" / "footprints" / "smart-remote-orig.yaml"

# Placeholder vs real, per bug 019f7736b236: the EVP-ASAC1A tactile switch
# footprint's real SMD lands are 2.0x2.0mm; the raw fab placeholder is 1.0x0.6.
PLACEHOLDER_WH = (1.0, 0.6)
REAL_SW_WH = (2.0, 2.0)


def _load_board() -> dict:
    return yaml.safe_load(BOARD_YAML.read_text(encoding="utf-8"))


def _board_no_smd_geometry() -> dict:
    """The resolvable board with the SW components' inline pad geometry stripped,
    so the RAW fab path is forced onto the placeholder (the bug), while resolve
    still supplies the real 2.0x2.0 lands."""
    board = _load_board()
    for comp in board["components"]:
        if str(comp.get("ref", "")).startswith("SW"):
            for pin in comp["pins"]:
                pin.pop("pad_width_mm", None)
                pin.pop("pad_height_mm", None)
    return board


def _copper_rect_apertures(files: dict[str, str]) -> set[tuple[float, float]]:
    """(w, h) of every rectangular aperture used on the copper layers."""
    parsed = parse_output_set(files)
    out: set[tuple[float, float]] = set()
    for suffix in ("F_Cu", "B_Cu"):
        lg = parsed.layers.get(suffix)
        if not lg:
            continue
        for key in lg.apertures:
            if key[0] == "rectangle":
                dims = dict(key[1])
                out.add((dims.get("w"), dims.get("h")))
    return out


# ---------------------------------------------------------------------------
# (a) GEOMETRY-DIFF: placeholder (raw) -> real (resolved).
# ---------------------------------------------------------------------------


def test_geometry_diff_placeholder_to_real_smd_pads():
    board = _board_no_smd_geometry()
    raw_files = gerber.build_gerbers(copy.deepcopy(board), name="board")
    resolved_files = gerber.build_gerbers(resolve.resolve_board(board), name="board")

    diff = diff_geometry(parse_output_set(resolved_files), parse_output_set(raw_files))
    assert not diff.is_empty, "resolve made no geometry difference — wiring is dead"

    raw_rects = _copper_rect_apertures(raw_files)
    resolved_rects = _copper_rect_apertures(resolved_files)

    # RAW compiles the SW lands to the 1.0x0.6 placeholder (the bug); resolved
    # replaces them with the real 2.0x2.0 footprint lands.
    assert PLACEHOLDER_WH in raw_rects, f"raw did not use the placeholder: {raw_rects}"
    assert PLACEHOLDER_WH not in resolved_rects, \
        f"resolved still emits the 1.0x0.6 placeholder: {resolved_rects}"
    assert REAL_SW_WH in resolved_rects, \
        f"resolved missing the real 2.0x2.0 SW lands: {resolved_rects}"


def test_gerber_and_kicad_read_the_same_resolved_geometry():
    """Criterion 6: gerber and kicad both consume pad_source, so the two emitters
    agree on the real resolved SMD size (2.0x2.0), not just gerber."""
    board = _board_no_smd_geometry()
    resolved = resolve.resolve_board(board)
    resolved_rects = _copper_rect_apertures(gerber.build_gerbers(resolved, name="board"))
    assert REAL_SW_WH in resolved_rects

    pcb = kicad.generate_kicad_pcb(resolved)
    # The same real land size lands in the kicad_pcb SMD pads.
    assert "(size 2.0 2.0)" in pcb, "kicad did not emit the real 2.0x2.0 SW land"
    # And the placeholder is gone from the SW pads (kicad's nominal is 1 0.6).
    assert "(size 1 0.6)" not in pcb


# ---------------------------------------------------------------------------
# (b) GATE DEFAULT-OFF: pure no-op vs a raw compile.
# ---------------------------------------------------------------------------


def test_gate_default_is_off():
    assert RESOLVE_FAB_GEOMETRY_DEFAULT is False


def test_gerbers_gate_off_matches_raw_compile():
    board = _board_no_smd_geometry()
    raw_files = gerber.build_gerbers(copy.deepcopy(board), name="board")
    resp = _gerbers({"board": copy.deepcopy(board), "name": "board"})
    assert resp["ok"] is True
    assert resp["result"]["files"] == raw_files


def test_generate_gate_off_matches_raw_compile():
    board = _board_no_smd_geometry()
    raw_files = kicad.generate(copy.deepcopy(board))
    resp = _generate({"board": copy.deepcopy(board)})
    assert resp["ok"] is True
    assert resp["result"]["files"] == raw_files


def test_drc_gate_off_matches_raw_run():
    from pcb_worker import drc as drc_mod
    board = _board_no_smd_geometry()
    raw = drc_mod.run_drc(copy.deepcopy(board))
    resp = _drc({"board": copy.deepcopy(board)})
    assert resp["ok"] is True
    assert resp["result"] == raw


# ---------------------------------------------------------------------------
# (c) GATE ERROR PASSTHROUGH: coincidence failure, gate ON -> structured error.
# ---------------------------------------------------------------------------


def _coincidence_board() -> dict:
    board = _load_board()
    u1 = next(c for c in board["components"] if c["ref"] == "U1")
    u1["pins"][0]["x_mm"] = u1["pins"][0]["x_mm"] + 1.0  # 1mm >> 0.01mm tol
    return board


def test_gerbers_gate_on_coincidence_returns_structured_error():
    resp = _gerbers({"board": _coincidence_board(), "resolve_geometry": True})
    assert resp["ok"] is False
    assert resp["error"]["kind"] == "coincidence"
    assert resp["error"]["ref"] == "U1"


def test_drc_gate_on_coincidence_returns_structured_error():
    resp = _drc({"board": _coincidence_board(), "resolve_geometry": True})
    assert resp["ok"] is False
    assert resp["error"]["kind"] == "coincidence"


def test_generate_gate_on_lookup_error_returns_structured_error():
    board = _load_board()
    board["components"][0]["footprint"] = "NoSuch:Footprint_Missing"
    resp = _generate({"board": board, "resolve_geometry": True})
    assert resp["ok"] is False
    assert resp["error"]["kind"] == "resolve"


# ---------------------------------------------------------------------------
# (d) FUNCTIONAL FLOOR (non-mocked): real dispatch, gate ON, real pad geometry.
# ---------------------------------------------------------------------------


def test_functional_floor_gerbers_dispatch_carries_real_geometry():
    board = _board_no_smd_geometry()
    req = {"id": 1, "method": "gerbers",
           "params": {"board": board, "name": "board", "resolve_geometry": True}}
    resp = handle_request(req)
    assert resp["ok"] is True, resp
    files = resp["result"]["files"]
    rects = _copper_rect_apertures(files)
    # Real board -> real resolve -> real gerber, end to end, no mocks.
    assert REAL_SW_WH in rects, f"dispatch did not carry real geometry: {rects}"
    assert PLACEHOLDER_WH not in rects, \
        f"dispatch still emitted the placeholder: {rects}"


def test_pad_source_prefers_resolved_over_pins():
    """Direct accessor contract: comp["pads"] wins when present; pins are the
    fallback when it is absent."""
    board = _board_no_smd_geometry()
    resolved = resolve.resolve_board(board)
    sw = next(c for c in resolved["components"] if c["ref"].startswith("SW"))
    pads = pad_source.iter_pads(sw)
    assert pads and all(p.from_resolve for p in pads)
    smd = [p for p in pads if p.drill is None]
    assert smd and all((p.width, p.height) == REAL_SW_WH for p in smd)

    # Same component pre-resolve (pins only, geometry stripped) -> fallback path,
    # width/height None so each emitter applies its own placeholder.
    sw_raw = next(c for c in board["components"] if c["ref"].startswith("SW"))
    raw_pads = pad_source.iter_pads(sw_raw)
    assert raw_pads and not any(p.from_resolve for p in raw_pads)
    assert all(p.width is None and p.height is None for p in raw_pads)
