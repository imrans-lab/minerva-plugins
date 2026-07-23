"""Stage-2 step 4a-ii: fab path resolves BY DEFAULT (best-effort) + the emitter
FAILS CLOSED on a sizeless SMD pad. Closes bug 019f7736b236 (placeholder pads).

This file was written at step 3 (gate default OFF, placeholder still emitted).
Step 4a-ii flips the gate ON and REMOVES the placeholder, so the step-3 premise
is inverted — these tests now pin the NEW contract:

  (a) FAIL-CLOSED — a board whose SMD pins carry NO geometry no longer compiles
      to a placeholder land: the RAW emitter RAISES PadGeometryError, and the
      SAME board resolve_board()-ed compiles to the REAL footprint lands.
  (b) GATE DEFAULT-ON — methods._gerbers/_generate resolve by DEFAULT (no
      resolve_geometry param) and carry real geometry; with the gate explicitly
      OFF the fab methods FAIL CLOSED (structured error, not a placeholder).
  (c) STRICT FAB (W8.2 cutover) — the fab methods now COMPILE (strict): an
      unresolvable footprint fails closed as a kind:"compile" error EVEN with
      inline pin geometry (the old best-effort tolerance is GONE), and a
      coincidence mismatch surfaces as a compile pin_pad_desync. The standalone
      `resolve` action stays STRICT too. The _drc path still uses the tolerant
      best-effort _maybe_resolve (a coincidence mismatch there is still fatal, as
      kind:"coincidence").
  (d) FUNCTIONAL FLOOR (non-mocked) — real dispatch, real resolve, real gerber
      carrying real (non-placeholder) pad geometry.
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
    _resolve,
    handle_request,
)
from tests.oracle.geometry_diff import parse_output_set

HERE = Path(__file__).resolve().parent
# The one board whose footprints all resolve cleanly (coincidence passes).
BOARD_YAML = HERE / "testdata" / "footprints" / "smart-remote-orig.yaml"

# Placeholder vs real, per bug 019f7736b236: the EVP-ASAC1A tactile switch
# footprint's real SMD lands are 2.0x2.0mm; the OLD raw fab placeholder was
# 1.0x0.6 (now GONE — a sizeless SMD pad fails closed instead of placeholdering).
PLACEHOLDER_WH = (1.0, 0.6)
REAL_SW_WH = (2.0, 2.0)


def _load_board() -> dict:
    return yaml.safe_load(BOARD_YAML.read_text(encoding="utf-8"))


def _board_no_smd_geometry() -> dict:
    """The resolvable board with the SW components' inline pad geometry stripped,
    so the RAW fab path has no SMD size (the bug's trigger) while resolve still
    supplies the real 2.0x2.0 lands."""
    board = _load_board()
    for comp in board["components"]:
        if str(comp.get("ref", "")).startswith("SW"):
            for pin in comp["pins"]:
                pin.pop("pad_width_mm", None)
                pin.pop("pad_height_mm", None)
    return board


def _unresolvable_smd_board(*, inline_geom: bool) -> dict:
    """A one-SMD-component board whose footprint is NOT in the seed library.

    With inline_geom the SMD pins carry pad_width_mm/pad_height_mm (so the fab
    path can fall back to them); without, they carry only positions (so the fab
    path has nothing to fall back to → fails closed)."""
    pin_geom = {"pad_width_mm": 0.6, "pad_height_mm": 0.5} if inline_geom else {}
    return {
        "version": 1, "name": "unres", "width_mm": 10, "height_mm": 10,
        "components": [
            {"ref": "R9", "footprint": "NoSuch:Nope", "x_mm": 5, "y_mm": 5,
             "rotation_deg": 0, "layer": "top",
             "pins": [{"number": "1", "x_mm": -0.5, "y_mm": 0, **pin_geom},
                      {"number": "2", "x_mm": 0.5, "y_mm": 0, **pin_geom}]},
        ],
        "nets": [],
    }


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
# (a) FAIL-CLOSED: raw sizeless SMD raises; resolved -> real lands.
# ---------------------------------------------------------------------------


def test_raw_sizeless_smd_fails_closed_resolved_is_real():
    board = _board_no_smd_geometry()

    # RAW emit: the SW SMD pins have no size -> fail closed (no placeholder).
    # (placed=True is irrelevant here — iter_pads(require_smd_size=True) raises
    # before any placement/rotation logic runs.)
    with pytest.raises(pad_source.PadGeometryError):
        gerber.build_gerbers(copy.deepcopy(board), name="board", placed=True)

    # Resolved emit: the real 2.0x2.0 SW lands, and the old 1.0x0.6 placeholder
    # is nowhere in the output.
    resolved_rects = _copper_rect_apertures(
        gerber.build_gerbers(resolve.resolve_board(board), name="board", placed=True))
    assert REAL_SW_WH in resolved_rects, \
        f"resolved missing the real 2.0x2.0 SW lands: {resolved_rects}"
    assert PLACEHOLDER_WH not in resolved_rects, \
        f"resolved still emits the 1.0x0.6 placeholder: {resolved_rects}"


def test_gerber_and_kicad_read_the_same_resolved_geometry():
    """gerber and kicad both consume pad_source, so the two emitters agree on the
    real resolved SMD size (2.0x2.0), not just gerber."""
    board = _board_no_smd_geometry()
    resolved = resolve.resolve_board(board)
    resolved_rects = _copper_rect_apertures(
        gerber.build_gerbers(resolved, name="board", placed=True))
    assert REAL_SW_WH in resolved_rects

    pcb = kicad.generate_kicad_pcb(resolved)
    # The same real land size lands in the kicad_pcb SMD pads.
    assert "(size 2.0 2.0)" in pcb, "kicad did not emit the real 2.0x2.0 SW land"
    # And the old 1x0.6 placeholder is gone from the SW pads.
    assert "(size 1 0.6)" not in pcb


# ---------------------------------------------------------------------------
# (b) GATE DEFAULT-ON: resolves by default; explicit OFF fails closed.
# ---------------------------------------------------------------------------


def test_gate_default_is_on():
    assert RESOLVE_FAB_GEOMETRY_DEFAULT is True


def test_gerbers_default_gate_resolves_real_geometry():
    # No resolve_geometry param -> the DEFAULT (ON) resolves and carries real lands.
    resp = _gerbers({"board": _board_no_smd_geometry(), "name": "board"})
    assert resp["ok"] is True, resp
    rects = _copper_rect_apertures(resp["result"]["files"])
    assert REAL_SW_WH in rects, f"default gate did not resolve real geometry: {rects}"
    assert PLACEHOLDER_WH not in rects


def test_gerbers_resolve_geometry_off_is_ignored_still_compiles():
    # W8.2 cutover: the resolve_geometry gate NO LONGER governs the fab path — it
    # always COMPILES (strict) -> IR -> emit. resolve_geometry:False is now
    # accepted-and-ignored, so the same resolvable board still compiles and carries
    # its REAL resolved lands (NOT a fail-closed, NOT the removed placeholder).
    resp = _gerbers({"board": _board_no_smd_geometry(), "name": "board",
                     "resolve_geometry": False})
    assert resp["ok"] is True, resp
    rects = _copper_rect_apertures(resp["result"]["files"])
    assert REAL_SW_WH in rects, f"gate-off did not resolve real geometry: {rects}"
    assert PLACEHOLDER_WH not in rects


def test_generate_emits_mounting_holes_and_ignores_gate():
    # W8.2b: the spike board carries NPTH mounting_holes. This test USED to assert
    # `generate` fail-closed with kind:"generate" — but that failure came from the
    # OLD kicad-bridge RAISE on board.holes, NOT from the resolve gate (which W8.2
    # already made moot). Now the kicad bridge EMITS mounting holes faithfully, so
    # the honest contract is: `generate` SUCCEEDS (resolve_geometry:False is
    # accepted-and-ignored, the board compiles) AND its NPTH mounting holes reach
    # the .kicad_pcb as np_thru_hole pads.
    resp = _generate({"board": _board_no_smd_geometry(), "resolve_geometry": False})
    assert resp["ok"] is True, resp
    pcb = next(v for k, v in resp["result"]["files"].items()
               if k.endswith(".kicad_pcb"))
    # The spike board declares four NPTH mounting holes (diameter 3.2).
    assert pcb.count("np_thru_hole") == 4, pcb.count("np_thru_hole")
    assert '(drill 3.2) (layers "*.Cu" "*.Mask")' in pcb


def test_drc_gate_off_matches_raw_run():
    # DRC reads only pad CENTERS (never size), so it never fails closed and the
    # gate is a pure no-op for it: explicitly OFF == a raw run.
    from pcb_worker import drc as drc_mod
    board = _board_no_smd_geometry()
    raw = drc_mod.run_drc(copy.deepcopy(board))
    resp = _drc({"board": copy.deepcopy(board), "resolve_geometry": False})
    assert resp["ok"] is True
    assert resp["result"] == raw


# ---------------------------------------------------------------------------
# (c) BEST-EFFORT (fab) vs STRICT (resolve action); coincidence fatal on both.
# ---------------------------------------------------------------------------


def _coincidence_board() -> dict:
    board = _load_board()
    u1 = next(c for c in board["components"] if c["ref"] == "U1")
    u1["pins"][0]["x_mm"] = u1["pins"][0]["x_mm"] + 1.0  # 1mm >> 0.01mm tol
    return board


def test_fab_path_unresolvable_footprint_fails_closed_even_with_inline_geom():
    # W8.2 cutover INVERTS the old best-effort tolerance: the fab path COMPILES
    # (strict), so an unresolvable footprint fails closed EVEN when the pins carry
    # inline pad geometry. The removed best-effort path used to fall back to that
    # inline geometry; the strict compile now rejects the footprint outright.
    resp = _gerbers({"board": _unresolvable_smd_board(inline_geom=True),
                     "name": "unres"})
    assert resp["ok"] is False
    assert resp["error"]["kind"] == "compile"
    assert any(d["code"] == "footprint_unresolved"
               for d in resp["error"]["diagnostics"])


def test_fab_path_fails_closed_when_unresolvable_and_no_inline_geom():
    # Composes with the inline-present case above: with NO inline geometry either,
    # the strict compile still fail-closes on the unresolvable footprint (it rejects
    # the ref BEFORE geometry matters) — proving inline geometry is no longer a
    # fallback in EITHER direction. Error is the compile shape, not kind:"gerber".
    resp = _gerbers({"board": _unresolvable_smd_board(inline_geom=False),
                     "name": "unres"})
    assert resp["ok"] is False
    assert resp["error"]["kind"] == "compile"
    assert any(d["code"] == "footprint_unresolved"
               for d in resp["error"]["diagnostics"])


def test_resolve_action_is_strict_on_unresolvable_footprint():
    # The standalone `resolve` action does NOT tolerate an unresolvable footprint
    # (unlike the fab path) — it surfaces a structured resolve error.
    resp = _resolve({"board": _unresolvable_smd_board(inline_geom=True)})
    assert resp["ok"] is False
    assert resp["error"]["kind"] == "resolve"


def test_gerbers_coincidence_returns_structured_compile_error():
    # A footprint that RESOLVES but whose pads disagree with the declared pins is
    # still fatal (integrity fault). W8.2 cutover: it now surfaces as a COMPILE
    # failure (pin_pad_desync on the offending pin) rather than the old
    # kind:"coincidence" the best-effort resolve path returned.
    resp = _gerbers({"board": _coincidence_board()})
    assert resp["ok"] is False
    assert resp["error"]["kind"] == "compile"
    assert any(d["code"] == "pin_pad_desync"
               and d["source_ref"]["entity_id"] == "U1.1"
               for d in resp["error"]["diagnostics"])


def test_drc_gate_on_coincidence_returns_structured_error():
    resp = _drc({"board": _coincidence_board()})
    assert resp["ok"] is False
    assert resp["error"]["kind"] == "coincidence"


# ---------------------------------------------------------------------------
# (d) FUNCTIONAL FLOOR (non-mocked): real dispatch, gate ON, real pad geometry.
# ---------------------------------------------------------------------------


def test_functional_floor_gerbers_dispatch_carries_real_geometry():
    board = _board_no_smd_geometry()
    req = {"id": 1, "method": "gerbers",
           "params": {"board": board, "name": "board"}}
    resp = handle_request(req)
    assert resp["ok"] is True, resp
    files = resp["result"]["files"]
    rects = _copper_rect_apertures(files)
    # Real board -> real (default) resolve -> real gerber, end to end, no mocks.
    assert REAL_SW_WH in rects, f"dispatch did not carry real geometry: {rects}"
    assert PLACEHOLDER_WH not in rects, \
        f"dispatch still emitted the placeholder: {rects}"


def test_pad_source_prefers_resolved_over_pins():
    """Direct accessor contract: comp["pads"] wins when present; pins are the
    fallback when it is absent (width/height None until the size-consuming
    emitter demands them via require_smd_size)."""
    board = _board_no_smd_geometry()
    resolved = resolve.resolve_board(board)
    sw = next(c for c in resolved["components"] if c["ref"].startswith("SW"))
    pads = pad_source.iter_pads(sw)
    assert pads and all(p.from_resolve for p in pads)
    smd = [p for p in pads if p.drill is None]
    assert smd and all((p.width, p.height) == REAL_SW_WH for p in smd)

    # Same component pre-resolve (pins only, geometry stripped) -> fallback path,
    # width/height None. iter_pads without require_smd_size does NOT fail closed;
    # the emitters that DO pass require_smd_size are what refuse a sizeless SMD.
    sw_raw = next(c for c in board["components"] if c["ref"].startswith("SW"))
    raw_pads = pad_source.iter_pads(sw_raw)
    assert raw_pads and not any(p.from_resolve for p in raw_pads)
    assert all(p.width is None and p.height is None for p in raw_pads)
    with pytest.raises(pad_source.PadGeometryError):
        pad_source.iter_pads(sw_raw, require_smd_size=True)


def test_has_resolved_pads_is_the_single_marker():
    """Stage 2 step 7 (provenance-collapse): pad_source.has_resolved_pads is the
    ONE definition of "resolved-real-footprint vs inline/fallback". The board-dict
    view comp["has_pad_geometry"] and the per-pad PadGeom.from_resolve marker are
    derived VIEWS that must ALWAYS agree with it — this pins that they cannot
    drift (the whole point of collapsing the 4 formats to 1)."""
    board = _board_no_smd_geometry()

    # Pre-resolve: no comp["pads"] => fallback everywhere, all three views False.
    for comp in board["components"]:
        assert pad_source.has_resolved_pads(comp) is False
        assert bool(comp.get("has_pad_geometry")) is False
        assert not any(p.from_resolve for p in pad_source.iter_pads(comp))

    # Post-resolve (strict resolve_board): the board-dict view and per-pad view
    # each equal the one predicate, component by component.
    resolved = resolve.resolve_board(board)
    for comp in resolved["components"]:
        marker = pad_source.has_resolved_pads(comp)
        assert bool(comp.get("has_pad_geometry")) is marker
        pads = pad_source.iter_pads(comp)
        assert pads and all(p.from_resolve is marker for p in pads)
    # This board fully resolves, so the marker is True everywhere.
    assert all(pad_source.has_resolved_pads(c) for c in resolved["components"])
