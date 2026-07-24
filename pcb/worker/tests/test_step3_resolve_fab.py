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
    # (the aperture-rotation source is irrelevant here — iter_pads(require_smd_size=True) raises
    # before any placement/rotation logic runs.)
    with pytest.raises(pad_source.PadGeometryError):
        gerber.build_gerbers(copy.deepcopy(board), name="board")

    # Resolved emit: the real 2.0x2.0 SW lands, and the old 1.0x0.6 placeholder
    # is nowhere in the output.
    resolved_rects = _copper_rect_apertures(
        gerber.build_gerbers(resolve.resolve_board(board), name="board"))
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
        gerber.build_gerbers(resolved, name="board"))
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


# ---------------------------------------------------------------------------
# (e) FAIL-CLOSED: plated TH pad with NO resolved annulus (K4 — retired the
#     invented `pad.annulus or drill*2` fallback). A plated through-hole pad that
#     authors neither an annulus nor a pad size no longer flashes a 2x-drill ring:
#     BOTH raw emitters RAISE PadGeometryError. Authoring the annulus emits it
#     faithfully — the SAME diameter in gerber (copper aperture) and kicad
#     (thru_hole size), never invented.
# ---------------------------------------------------------------------------


def _raw_board_plated_th(annulus=None, pad_size=None, drill=1.0):
    pin = {"number": "1", "x_mm": 0.0, "y_mm": 0.0, "drill_mm": drill}
    if annulus is not None:
        pin["annulus_diameter_mm"] = annulus
    if pad_size is not None:
        pin["pad_width_mm"] = pad_size
        pin["pad_height_mm"] = pad_size
    return {
        "version": 1, "name": "thtest", "width_mm": 20, "height_mm": 20,
        "components": [
            {"ref": "J1", "footprint": "HDR", "x_mm": 10.0, "y_mm": 10.0,
             "rotation_deg": 0, "layer": "top", "pins": [pin]},
        ],
        "nets": [],
    }


def test_raw_plated_th_no_annulus_fails_closed_gerber():
    # No annulus, no pad size on a plated TH pin -> gerber refuses (never invents
    # drill*2). This is the raw loose-dict path compile_board never sees.
    with pytest.raises(pad_source.PadGeometryError):
        gerber.build_gerbers(_raw_board_plated_th(), name="thtest")


def test_raw_plated_th_no_annulus_fails_closed_kicad():
    # kicad reads the SAME shared pad_source contract, so it fails closed identically.
    with pytest.raises(pad_source.PadGeometryError):
        kicad.generate_kicad_pcb(_raw_board_plated_th())


def test_raw_plated_th_authored_annulus_emits_faithfully_both_emitters():
    # Authoring the annulus (1.8) emits it faithfully and IDENTICALLY in both
    # emitters — the diameter is honoured, never a 2x-drill (=2.0) invention.
    board = _raw_board_plated_th(annulus=1.8)
    fcu = next(v for k, v in gerber.build_gerbers(board, name="thtest").items()
               if "F_Cu" in k)
    import re
    assert re.search(r"%ADD\d+C,1\.8\d*\*%", fcu), \
        f"gerber F_Cu missing the authored 1.8 annulus aperture:\n{fcu}"
    assert not re.search(r"%ADD\d+C,2(\.0+)?\*%", fcu), \
        "gerber F_Cu leaked a 2x-drill (2.0) invented annulus"
    pcb = kicad.generate_kicad_pcb(board)
    assert "thru_hole" in pcb and "(size 1.8 1.8)" in pcb, \
        f"kicad missing the authored 1.8 thru_hole land:\n{pcb}"


def test_raw_plated_th_equal_axis_pad_size_becomes_the_annulus():
    # A plated TH pin that authored a SIZE (equal-axis 1.8) but no annulus is NOT
    # fail-closed — its authored copper size doubles as the round annulus, exactly
    # as the resolved path does (_from_pin mirrors _from_resolved). Only a pin that
    # authored NEITHER annulus nor size fails closed.
    board = _raw_board_plated_th(pad_size=1.8)
    fcu = next(v for k, v in gerber.build_gerbers(board, name="thtest").items()
               if "F_Cu" in k)
    import re
    assert re.search(r"%ADD\d+C,1\.8\d*\*%", fcu), \
        f"gerber F_Cu missing the size-derived 1.8 annulus aperture:\n{fcu}"
    assert not re.search(r"%ADD\d+C,2(\.0+)?\*%", fcu), \
        "gerber F_Cu leaked a 2x-drill (2.0) invented annulus"
    assert "(size 1.8 1.8)" in kicad.generate_kicad_pcb(board)


@pytest.mark.parametrize("bad", [0.0, -1.0, float("nan"), float("inf")])
def test_raw_plated_th_invalid_annulus_fails_closed_both_emitters(bad):
    # bug 019f91b61337: the shared accessor must reject a non-finite / non-positive
    # annulus, not just None — else 0.0 flashes a zero aperture, NaN/Inf reach the
    # fabrication bytes literally, and a negative diverges between the two emitters.
    board = _raw_board_plated_th(annulus=bad)
    with pytest.raises(pad_source.PadGeometryError):
        gerber.build_gerbers(board, name="thtest")
    with pytest.raises(pad_source.PadGeometryError):
        kicad.generate_kicad_pcb(board)


@pytest.mark.parametrize("ann", [1.0, 0.8])  # drill is 1.0: equal == zero ring; less == nonsense
def test_raw_plated_th_annulus_not_bigger_than_drill_fails_closed_both_emitters(ann):
    # Physical invariant (distinct from a board-house min-annular-ring policy): the
    # round copper annulus must EXCEED the drill or there is no copper ring.
    board = _raw_board_plated_th(annulus=ann)
    with pytest.raises(pad_source.PadGeometryError):
        gerber.build_gerbers(board, name="thtest")
    with pytest.raises(pad_source.PadGeometryError):
        kicad.generate_kicad_pcb(board)


# ---------------------------------------------------------------------------
# (f) FAIL-CLOSED: a PRESENT but NON-FINITE drill (bug 019f91c1420c). Before the
#     shared _require_finite_drill boundary the two emitters DIVERGED on a NaN drill
#     — gerber's `drill > 0` was False so it mis-routed to the SMD branch and crashed
#     with an unstructured TypeError, while kicad's `drill is not None` was True so it
#     emitted a MALFORMED `thru_hole ... (drill nan)`. Now both share one predicate
#     (is_through_hole) and one boundary, so both fail closed identically with a
#     structured PadGeometryError; a finite 0/negative drill stays the ACCEPTED
#     "no hole -> SMD" degenerate (no predicate drift).
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("bad_drill", [float("nan"), float("inf"), float("-inf")])
def test_raw_th_non_finite_drill_fails_closed_both_emitters(bad_drill):
    # Authored a VALID annulus (1.8) so the ONLY defect is the drill — this pins the
    # non-finite drill itself (not the annulus / SMD-size) as the fail-closed cause.
    board = _raw_board_plated_th(annulus=1.8, drill=bad_drill)
    with pytest.raises(pad_source.PadGeometryError, match="not finite"):
        gerber.build_gerbers(board, name="thtest")
    with pytest.raises(pad_source.PadGeometryError, match="not finite"):
        kicad.generate_kicad_pcb(board)


@pytest.mark.parametrize("bad", [0.0, -1.0, True, "1.0"])
def test_raw_th_present_malformed_drill_fails_closed_no_size(bad):
    # bug 019f924ce991: a PRESENT authored drill_mm that cannot form a hole (finite
    # <=0, bool, or string) fails closed as authored_drill_invalid — the author WROTE
    # a drill, so it is a MALFORMED hole, not a silent "no-hole SMD". (A NON-finite
    # drill reports as drill_not_finite instead — see the parametrized test above.)
    board = _raw_board_plated_th(drill=bad)  # no annulus, no size
    with pytest.raises(pad_source.PadGeometryError, match="authored drill_mm"):
        gerber.build_gerbers(board, name="thtest")
    with pytest.raises(pad_source.PadGeometryError, match="authored drill_mm"):
        kicad.generate_kicad_pcb(board)


@pytest.mark.parametrize("bad", [-1.0, 0.0, True, "1.0"])
def test_raw_th_malformed_authored_drill_fails_closed_even_with_size(bad):
    # THE bug (019f924ce991): with a valid pad SIZE present, a malformed authored
    # drill_mm previously slipped through — both raw emitters silently DROPPED the
    # hole and fabricated an ordinary SMD pad (gerber: no .drl; kicad: (pad ... smd)).
    # It must fail closed: an authored drill intent is never silently discarded, size
    # or no size.
    board = _raw_board_plated_th(drill=bad, pad_size=1.8)
    with pytest.raises(pad_source.PadGeometryError, match="authored drill_mm"):
        gerber.build_gerbers(board, name="thtest")
    with pytest.raises(pad_source.PadGeometryError, match="authored drill_mm"):
        kicad.generate_kicad_pcb(board)


def test_raw_absent_drill_with_size_is_a_valid_smd_pad():
    # BOUNDARY: an ABSENT drill_mm (omitted / null) + a valid pad size is a normal SMD
    # pad, NOT a fail-close — this is what distinguishes "no hole intended" (omit the
    # key) from "malformed hole authored" (present-but-invalid). Both emitters succeed.
    board = _raw_board_plated_th(pad_size=1.8, drill=None)  # drill_mm null == omitted
    files = gerber.build_gerbers(board, name="thtest")
    assert not any(n.endswith(".drl") for n in files), "SMD pad must emit no drill file"
    assert "smd" in kicad.generate_kicad_pcb(board)


def test_resolved_path_non_finite_drill_fails_closed_both_emitters():
    # Defense-in-depth: the non-finite drill boundary also guards the RESOLVED pad
    # path (_from_resolved via comp["pads"]), not just inline pins. Production can't
    # author this (the compiler guarantees finite drills), but the shared validator
    # holds on either factory branch.
    board = {
        "version": 1, "name": "thtest", "width_mm": 20, "height_mm": 20,
        "components": [{
            "ref": "J1", "footprint": "HDR", "x_mm": 10.0, "y_mm": 10.0,
            "rotation_deg": 0, "layer": "top",
            "pads": [{
                "number": "1", "type": "thru_hole", "shape": "circle",
                "position": {"x": 0.0, "y": 0.0},
                "size": {"width": 1.8, "height": 1.8},
                "drill": {"x": float("nan"), "y": float("nan")},
                "layers": ["F.Cu", "B.Cu"],
            }],
        }],
        "nets": [],
    }
    with pytest.raises(pad_source.PadGeometryError, match="not finite"):
        gerber.build_gerbers(board, name="thtest")
    with pytest.raises(pad_source.PadGeometryError, match="not finite"):
        kicad.generate_kicad_pcb(board)
