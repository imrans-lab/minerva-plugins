"""Epoch CPN1 station S5 — the Minerva_Fixture footprint trio.

Three purpose-built seed-library footprints for the public test coupon
(docket 019fe2fb3ceb), each closing a named coverage gap:

  * ``SMD_WeirdPads_2P`` — pad 1 ROUNDRECT at an AUTHORED corner ratio (0.4,
    not the 0.25 default), pad 2 OVAL (0.8 x 1.6, taller than wide so a
    dropped rotation shows in copper). Closes parity_corners.yaml's
    deliberately-open gap #4: the circle/oval/roundrect SMD aperture families
    ``gerber._shape_aperture`` branches on, finally reached from a board.
  * ``LOGO_Owl_TestCoupon`` — pad-less silk furniture: a stroke-art owl using
    ALL FOUR silk primitive classes (fp_circle eyes, fp_arc head, fp_poly
    beak, fp_line body + the baked-in "TEST COUPON" text). The silk
    arc/circle emitter paths only library footprints can reach.
  * ``FID_Circle_1mm`` — bare-copper fiducial: 1.0 mm circle pad, 2.0 mm mask
    opening (solder_mask_margin 0.5), and NO paste layer.

Oracles measured live during S5 (aperture strings quoted from the emitted
bytes, not derived).
"""

from __future__ import annotations

import re

from pcb_worker.compile_board import compile_board
from pcb_worker.gerber import build_gerbers_ir
from pcb_worker.resolved_board import (
    ArcGeometry,
    CircleGeometry,
    LineGeometry,
    PolygonGeometry,
    ResolutionSuccess,
)


def _board() -> dict:
    return {
        "version": 1, "name": "fixture-suite", "width_mm": 24, "height_mm": 18,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.25,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [
            {"ref": "C1", "footprint": "Minerva_Fixture:SMD_WeirdPads_2P",
             "value": "W", "x_mm": 8, "y_mm": 9, "rotation_deg": 0,
             "layer": "top",
             "pins": [{"number": "1", "name": "A", "x_mm": -0.95, "y_mm": 0},
                      {"number": "2", "name": "B", "x_mm": 0.95, "y_mm": 0}]},
            {"ref": "LOGO1", "footprint": "Minerva_Fixture:LOGO_Owl_TestCoupon",
             "x_mm": 17, "y_mm": 9, "rotation_deg": 0, "layer": "top",
             "assembly": "exclude", "pins": []},
            {"ref": "FID1", "footprint": "Minerva_Fixture:FID_Circle_1mm",
             "x_mm": 2.5, "y_mm": 2.5, "rotation_deg": 0, "layer": "top",
             "assembly": "exclude",
             "pins": [{"number": "1", "name": "F", "x_mm": 0, "y_mm": 0}]},
        ],
        "nets": [{"name": "N1", "pins": ["C1.1", "C1.2"]}],
    }


def _compiled():
    result = compile_board(_board())
    assert isinstance(result, ResolutionSuccess), \
        [(d.code, d.message) for d in result.diagnostics]
    return result


def _aperture_defs(text: str) -> list[str]:
    return re.findall(r"%AD[^*]*\*%", text)


class TestFixtureTrio:
    def test_pad_less_logo_compiles_with_all_four_silk_classes(self):
        rb = _compiled().board
        logo = next(c for c in rb.components if c.ref == "LOGO1")
        assert len(logo.placed_pads) == 0
        kinds = {type(g.geometry) for g in logo.placed_graphics}
        assert {LineGeometry, CircleGeometry, ArcGeometry,
                PolygonGeometry} <= kinds

    def test_only_warnings_are_courtyard_documentation(self):
        result = _compiled()
        for diag in result.diagnostics:
            if diag.severity == "warning":
                assert diag.code == "captured_geometry_not_emitted"
                assert "F.CrtYd" in diag.message

    def test_weird_pad_apertures_reach_copper_and_paste(self):
        files = build_gerbers_ir(_compiled().board)
        f_cu = next(t for n, t in files.items() if n.endswith("F_Cu.gbr"))
        f_paste = next(t for n, t in files.items() if n.endswith("F_Paste.gbr"))
        # Measured aperture strings: roundrect with the AUTHORED 0.4 ratio and
        # the 0.8x1.6 obround, on copper and paste alike.
        assert ("%ADD10RoundedRectangle,"
                "0.6X0.5X0.2X0.1X0.0X0.8X0.2X0.1X-0.2X0.1*%") in f_cu
        assert "%ADD11O,0.8X1.6*%" in f_cu
        cu_defs = "".join(_aperture_defs(f_cu))
        paste_defs = "".join(_aperture_defs(f_paste))
        assert "RoundedRectangle" in paste_defs and "O,0.8X1.6" in paste_defs
        # The fiducial's 1.0 circle is copper...
        assert "C,1.0" in cu_defs

    def test_fiducial_has_mask_opening_but_no_paste(self):
        files = build_gerbers_ir(_compiled().board)
        f_paste = next(t for n, t in files.items() if n.endswith("F_Paste.gbr"))
        f_mask = next(t for n, t in files.items() if n.endswith("F_Mask.gbr"))
        # ...no circle aperture reaches the stencil (a fiducial is never
        # pasted; its footprint's pad omits F.Paste)...
        assert "C,1.0" not in "".join(_aperture_defs(f_paste))
        assert "C,2.0" not in "".join(_aperture_defs(f_paste))
        # ...and the mask opening is 2.0 mm: 1.0 pad + the authored
        # solder_mask_margin 0.5 per side (margin wins over the board default).
        assert "C,2.0" in "".join(_aperture_defs(f_mask))

    def test_silk_carries_arcs_from_the_owl(self):
        files = build_gerbers_ir(_compiled().board)
        f_silk = next(t for n, t in files.items() if n.endswith("F_SilkS.gbr"))
        assert "G75" in f_silk or "G03" in f_silk or "G02" in f_silk
