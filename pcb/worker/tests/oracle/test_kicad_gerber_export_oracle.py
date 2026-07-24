"""DEV-ONLY kicad-cli GERBER-EXPORT oracle for solder-mask CAM (finding 019f90c5c962).

The banked lesson E3/E4 nearly shipped past: a pcbnew ``LoadBoard`` reads pad
``(layers "*.Cu" "*.Mask")`` and via ``(tenting ...)`` fine even when the board's
``(layers ...)`` table omits the mask layers — but KiCad's Gerber EXPORTER then
plots NOTHING for those undeclared layers (exits 0, no mask file). So the real
proof that the NPTH mask (E3) and via tenting (E4) reach fabrication is to run the
actual Gerber export and assert the mask bytes carry the expected flashes.

BOUNDARY: shells out to kicad-cli (dev/CI-only); skips cleanly when it is absent.
"""

from __future__ import annotations

import re

import pytest

from pcb_worker import kicad
from pcb_worker.compile_board import compile_board
from tests.oracle.kicad_drc import export_gerbers_on_pcb_text, kicad_cli_available

pytestmark = pytest.mark.skipif(
    not kicad_cli_available(), reason="kicad-cli not on PATH (dev/CI oracle)")

MASK_LAYERS = ["F.Cu", "B.Cu", "F.Mask", "B.Mask", "Edge.Cuts"]


def _export(board: dict) -> dict[str, str]:
    resolved = compile_board(board).board
    pcb = kicad.generate_ir(resolved, base_name="brd")["brd.kicad_pcb"]
    return export_gerbers_on_pcb_text(pcb, MASK_LAYERS, name="brd")


def _fmask(files: dict[str, str]) -> str:
    return next(v for k, v in files.items() if "F_Mask" in k)


def test_kicad_cli_exports_nonempty_mask_with_npth_and_untented_via():
    # A board with a plated TH pad (annulus 1.6), an UNTENTED via (0.8), and an NPTH
    # mounting hole (3.2). All three must appear as mask openings on the exported
    # F.Mask — proving the layer table declares F.Mask so KiCad plots it (F3), the
    # NPTH mask reaches fab (E3), and the untented via is exposed (E4).
    board = {
        "version": 1, "name": "brd", "width_mm": 40, "height_mm": 30,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.25,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [{"ref": "U1", "footprint": "TH_TestPoint", "x_mm": 30, "y_mm": 15,
                        "rotation_deg": 0, "layer": "top",
                        "pins": [{"number": "1", "x_mm": 0, "y_mm": 0,
                                  "drill_mm": 0.8, "annulus_diameter_mm": 1.6}]}],
        "nets": [{"name": "N", "pins": ["U1.1"]}],
        "vias": [{"net": "N", "x_mm": 20, "y_mm": 10, "diameter_mm": 0.8, "drill_mm": 0.4,
                  "from_layer": "top", "to_layer": "bottom", "tented": False}],
        "mounting_holes": [{"x_mm": 5, "y_mm": 5, "diameter_mm": 3.2, "plated": False}],
    }
    fmask = _fmask(_export(board))
    # Openings carry the compiler-resolved 0.05mm/side solder-mask clearance (bug
    # 019f9266b9cd: KiCad previously applied 0 for an empty (setup), shipping 0mm
    # plated-pad openings that DIVERGED from the Gerber emitter's clearance). The
    # plated TH annulus 1.6 -> 1.7 and the untented via 0.8 -> 0.9 (both +2*0.05);
    # the NPTH mount stays drill-size 3.2 (margin 0). These are IDENTICAL to the
    # production Gerber emitter's F.Mask on this board — the two CAM paths now agree.
    assert re.search(r"%ADD\d+C,3\.2\d*\*%", fmask), "NPTH Ø3.2 mask aperture missing (E3/F3)"
    assert re.search(r"%ADD\d+C,1\.7\d*\*%", fmask), "TH pad Ø1.7 (1.6 + 2*0.05) mask aperture missing"
    assert re.search(r"%ADD\d+C,0\.9\d*\*%", fmask), "untented via Ø0.9 (0.8 + 2*0.05) mask aperture missing"
    assert not re.search(r"%ADD\d+C,1\.6\d*\*%", fmask), "TH mask must NOT be at copper size (0 clearance — the bug)"
    assert fmask.count("D03*") >= 3, "F.Mask should flash all three openings"


def test_tented_via_has_no_mask_opening_through_kicad_cli():
    # The complement (E4): a TENTED via must NOT appear on the exported mask. Only
    # the two TH openings (pad + NPTH mount) remain.
    board = {
        "version": 1, "name": "brd", "width_mm": 40, "height_mm": 30,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.25,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [{"ref": "U1", "footprint": "TH_TestPoint", "x_mm": 30, "y_mm": 15,
                        "rotation_deg": 0, "layer": "top",
                        "pins": [{"number": "1", "x_mm": 0, "y_mm": 0,
                                  "drill_mm": 0.8, "annulus_diameter_mm": 1.6}]}],
        "nets": [{"name": "N", "pins": ["U1.1"]}],
        "vias": [{"net": "N", "x_mm": 20, "y_mm": 10, "diameter_mm": 0.8, "drill_mm": 0.4,
                  "from_layer": "top", "to_layer": "bottom", "tented": True}],
        "mounting_holes": [{"x_mm": 5, "y_mm": 5, "diameter_mm": 3.2, "plated": False}],
    }
    fmask = _fmask(_export(board))
    # No Ø0.8 aperture (the tented via) — the via at (20,10) has no opening.
    assert not re.search(r"%ADD\d+C,0\.8\d*\*%", fmask), "tented via leaked a mask opening (E4)"
    assert re.search(r"%ADD\d+C,3\.2\d*\*%", fmask), "NPTH mask still expected (E3)"


ALL_TECH_LAYERS = ["F.Cu", "B.Cu", "F.Mask", "B.Mask", "F.Paste", "B.Paste",
                   "F.Fab", "B.Fab", "Edge.Cuts"]


def test_kicad_cli_exports_all_referenced_technical_layers_both_sides():
    # G2 (finding 019f90c5c962): the export gate must be EXHAUSTIVE — every declared
    # technical layer on BOTH sides actually plots, not just F.Mask. A board with a
    # TOP and a BOTTOM SMD land (for F/B.Paste + F/B.Mask) plus a TH pad exports
    # cleanly and every requested layer yields a file; the mask + paste layers carry
    # real flashes (not just an empty header).
    board = {
        "version": 1, "name": "brd", "width_mm": 40, "height_mm": 30,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.25,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [
            {"ref": "R1", "footprint": "R_0805", "x_mm": 10, "y_mm": 10,
             "rotation_deg": 0, "layer": "top"},
            {"ref": "R2", "footprint": "R_0805", "x_mm": 25, "y_mm": 15,
             "rotation_deg": 0, "layer": "bottom"},
            {"ref": "U1", "footprint": "TH_TestPoint", "x_mm": 30, "y_mm": 20,
             "rotation_deg": 0, "layer": "top",
             "pins": [{"number": "1", "x_mm": 0, "y_mm": 0, "drill_mm": 0.8,
                       "annulus_diameter_mm": 1.6}]}],
        "nets": [{"name": "N", "pins": ["R1.1", "U1.1"]}],
        "vias": [],
        "mounting_holes": [{"x_mm": 5, "y_mm": 5, "diameter_mm": 3.2, "plated": False}],
    }
    resolved = compile_board(board).board
    pcb = kicad.generate_ir(resolved, base_name="brd")["brd.kicad_pcb"]
    files = export_gerbers_on_pcb_text(pcb, ALL_TECH_LAYERS, name="brd")

    def _layer(tok: str) -> str:
        matches = [v for k, v in files.items() if tok in k]
        assert matches, f"no exported gerber file for layer token {tok!r} (files={list(files)})"
        return matches[0]

    # Every requested technical layer produced a file (declared -> plotted).
    for tok in ("F_Cu", "B_Cu", "F_Mask", "B_Mask", "F_Paste", "B_Paste",
                "F_Fab", "B_Fab", "Edge_Cuts"):
        _layer(tok)
    # Mask + paste carry real geometry on BOTH sides (the F3 failure was silent
    # empties). Top has R1's land + U1's TH; bottom has R2's land.
    for tok in ("F_Mask", "B_Mask", "F_Paste", "B_Paste"):
        assert _layer(tok).count("D03*") >= 1, f"{tok} exported with no flashes (silent-empty regression)"
    # NPTH Ø3.2 mask opening present (E3) on both mask sides.
    assert re.search(r"%ADD\d+C,3\.2\d*\*%", _layer("F_Mask"))
    assert re.search(r"%ADD\d+C,3\.2\d*\*%", _layer("B_Mask"))
