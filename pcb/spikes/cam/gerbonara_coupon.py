#!/usr/bin/env python
"""CAM writer spike: emit the fabrication coupon through **gerbonara 1.6.3** as a
unified Gerber + Excellon + IPC-356 writer, to compare against the incumbent
gerber-writer stack (pcb/worker/pcb_worker/gerber.py) and the BLESSED golden
(pcb/spikes/gerber/golden/, provenance spike-gerber-v1).

This is a SPIKE prototype (docket MNR 019f761fcfc3). It hard-codes the coupon
geometry the same way the incumbent spike's generate.py does — a canonical
board.yaml -> gerbonara compiler is NOT spike scope. Geometry mirrors the blessed
golden (real 1.2x1.3 mm 0805 SMD lands, O1.6 TH pad, O0.8 via, VCC/GND traces,
2 courtyards + pin-1 tick, 40x30 outline, PTH O0.8+O0.4, NPTH O3.2) so the output
is directly diffable against golden/ via the SB.2 geometry_diff harness.

It ALSO emits the harder features the brief asks gerbonara to prove:
  * X2 FILE attributes as canonical %TF...*% extended commands.
  * a filled REGION / copper pour (G36/G37).
  * a true silk ARC (G02/G03 with I/J).
  * a routed SLOT in the drill file (Excellon G00/M15/G01 route mode).
  * an IPC-356 (IPC-D-356A) netlist.

Determinism: gerbonara emits NO wall-clock timestamp at all, so output is
byte-reproducible with no pinning needed (unlike gerber-writer, whose
TF.CreationDate the incumbent must regex-pin). Coordinate format is pinned
explicitly via FileSettings(number_format=(3,6)) to match the golden's
self-declared %FSLAX36Y36 for this board size.

Run: python gerbonara_coupon.py [out_dir]   (defaults to ./out)

KNOWN gerbonara 1.6.3 writer bugs worked around here (reported as findings):
  * ipc356.TestRecord: constructor field is misspelled `lefover` but
    format() reads self.leftover -> AttributeError. Worked around by setting
    record.leftover = '' before write.
  * Netlist.write_to_bytes / ExcellonFile.split_by_plating crash when
    import_settings is None (`None.copy()`); we always pass explicit settings.
"""
from __future__ import annotations

import sys
from pathlib import Path

from gerbonara import GerberFile, ExcellonFile
from gerbonara.apertures import CircleAperture, RectangleAperture, ExcellonTool
from gerbonara.graphic_objects import Flash, Line, Arc, Region
from gerbonara.cam import FileSettings
from gerbonara.utils import MM
from gerbonara.ipc356 import Netlist, TestRecord, PadType

# --- Coupon geometry constants (mirror pcb/spikes/gerber/golden generate.py) ---
BOARD_W, BOARD_H = 40.0, 30.0
R1 = (10.0, 10.0)
C1 = (10.0, 20.0)
U1 = (30.0, 15.0)
VIA = (20.0, 10.0)
MOUNT = (5.0, 5.0)

SMD_W, SMD_H = 1.2, 1.3
TRACE_W = 0.25
TH_DRILL, TH_ANNULUS = 0.8, 1.6
VIA_DRILL, VIA_DIA = 0.4, 0.8
MASK_CLR = 0.1
MOUNT_DIA = 3.2
SILK_W = 0.15
EDGE_W = 0.1

r1p1, r1p2 = (R1[0] - 0.95, R1[1]), (R1[0] + 0.95, R1[1])
c1p1, c1p2 = (C1[0] - 0.95, C1[1]), (C1[0] + 0.95, C1[1])

# Pin the coordinate format to match the golden's self-declared FSLAX36Y36.
SETTINGS = FileSettings(unit=MM, number_format=(3, 6), zeros="leading",
                        notation="absolute")


def _ff(*parts):
    """A .FileFunction file-attribute value list."""
    return list(parts)


def _gerber(objects, file_function, polarity="Positive"):
    return GerberFile(
        objects=objects,
        file_attrs={
            ".FileFunction": _ff(*file_function),
            ".FilePolarity": [polarity],
            ".GenerationSoftware": ["Minerva", "cam-spike/gerbonara_coupon.py", "spike"],
        },
    )


def build() -> dict[str, str]:
    """Return {filename: text} for the gerbonara-emitted coupon."""
    files: dict[str, str] = {}

    # Shared aperture masters (gerbonara dedups by value on write).
    smd = RectangleAperture(SMD_W, SMD_H, unit=MM)
    smd_mask = RectangleAperture(SMD_W + 2 * MASK_CLR, SMD_H + 2 * MASK_CLR, unit=MM)
    th_cu = CircleAperture(TH_ANNULUS, unit=MM)
    th_mask = CircleAperture(TH_ANNULUS + 2 * MASK_CLR, unit=MM)
    via_cu = CircleAperture(VIA_DIA, unit=MM)
    trace_ap = CircleAperture(TRACE_W, unit=MM)
    silk_ap = CircleAperture(SILK_W, unit=MM)
    edge_ap = CircleAperture(EDGE_W, unit=MM)

    def seg(a, b, ap):
        return Line(a[0], a[1], b[0], b[1], ap, unit=MM)

    def flash(pt, ap):
        return Flash(pt[0], pt[1], ap, unit=MM)

    # --- F.Cu ---
    f_cu = [
        flash(r1p1, smd), flash(r1p2, smd), flash(c1p1, smd), flash(c1p2, smd),
        flash(U1, th_cu), flash(VIA, via_cu),
        seg(r1p2, VIA, trace_ap),   # VCC
        seg(r1p1, c1p1, trace_ap),  # GND
    ]
    files["board-F_Cu.gbr"] = _gerber(f_cu, ("Copper", "L1", "Top", "Signal")).write_to_bytes(settings=SETTINGS).decode()

    # --- B.Cu (+ a demonstration copper POUR region and a via stitch) ---
    b_cu = [
        flash(U1, th_cu), flash(VIA, via_cu),
        seg(VIA, U1, trace_ap),  # VCC on bottom
        # Filled ground pour in a corner (proves G36/G37 region emission).
        Region([(1, 1), (8, 1), (8, 6), (1, 6), (1, 1)], unit=MM),
    ]
    files["board-B_Cu.gbr"] = _gerber(b_cu, ("Copper", "L2", "Bot", "Signal")).write_to_bytes(settings=SETTINGS).decode()

    # --- F.Mask ---
    f_mask = [flash(r1p1, smd_mask), flash(r1p2, smd_mask),
              flash(c1p1, smd_mask), flash(c1p2, smd_mask), flash(U1, th_mask)]
    files["board-F_Mask.gbr"] = _gerber(f_mask, ("Soldermask", "Top")).write_to_bytes(settings=SETTINGS).decode()

    # --- B.Mask ---
    b_mask = [flash(U1, th_mask)]
    files["board-B_Mask.gbr"] = _gerber(b_mask, ("Soldermask", "Bot")).write_to_bytes(settings=SETTINGS).decode()

    # --- F.SilkS: 2 courtyards + pin-1 tick + a demonstration ARC ---
    def courtyard(c, hw, hh):
        x0, y0, x1, y1 = c[0] - hw, c[1] - hh, c[0] + hw, c[1] + hh
        return [seg((x0, y0), (x1, y0), silk_ap), seg((x1, y0), (x1, y1), silk_ap),
                seg((x1, y1), (x0, y1), silk_ap), seg((x0, y1), (x0, y0), silk_ap)]

    f_silk = [*courtyard(R1, 1.6, 1.0), *courtyard(C1, 1.6, 1.0),
              seg((U1[0] - TH_ANNULUS / 2 - 0.6, U1[1]),
                  (U1[0] - TH_ANNULUS / 2 - 0.2, U1[1]), silk_ap),
              # A true CW arc near C1 (proves G02 with I/J center offset).
              Arc(C1[0] + 2, C1[1], C1[0], C1[1] + 2, C1[0], C1[1], True, silk_ap, unit=MM)]
    files["board-F_SilkS.gbr"] = _gerber(f_silk, ("Legend", "Top")).write_to_bytes(settings=SETTINGS).decode()

    # --- Edge.Cuts ---
    edge = [seg((0, 0), (BOARD_W, 0), edge_ap), seg((BOARD_W, 0), (BOARD_W, BOARD_H), edge_ap),
            seg((BOARD_W, BOARD_H), (0, BOARD_H), edge_ap), seg((0, BOARD_H), (0, 0), edge_ap)]
    files["board-Edge_Cuts.gbr"] = _gerber(edge, ("Profile", "NP")).write_to_bytes(settings=SETTINGS).decode()

    # --- Excellon PTH / NPTH (separate files = incumbent convention). ---
    # PTH also carries a demonstration ROUTED SLOT (Line in route mode).
    pth = ExcellonFile(objects=[
        Flash(U1[0], U1[1], ExcellonTool(TH_DRILL, plated=True, unit=MM), unit=MM),
        Flash(VIA[0], VIA[1], ExcellonTool(VIA_DRILL, plated=True, unit=MM), unit=MM),
        Line(34, 5, 38, 5, ExcellonTool(1.0, plated=True, unit=MM), unit=MM),  # routed slot
    ])
    files["board-PTH.drl"] = pth.write_to_bytes(settings=SETTINGS).decode()

    npth = ExcellonFile(objects=[
        Flash(MOUNT[0], MOUNT[1], ExcellonTool(MOUNT_DIA, plated=False, unit=MM), unit=MM),
    ])
    files["board-NPTH.drl"] = npth.write_to_bytes(settings=SETTINGS).decode()

    # --- IPC-356 netlist (IPC-D-356A). gerbonara has this; gerber-writer does not.
    recs = [
        TestRecord(pad_type=PadType.THROUGH_HOLE, net_name="VCC", ref_des="U1",
                   pin_num=1, x=U1[0], y=U1[1], hole_dia=TH_DRILL, is_plated=True,
                   access_layer=0, unit=MM),
        TestRecord(pad_type=PadType.SMD_PAD, net_name="VCC", ref_des="R1",
                   pin_num=2, x=r1p2[0], y=r1p2[1], access_layer=1, unit=MM),
        TestRecord(pad_type=PadType.SMD_PAD, net_name="GND", ref_des="R1",
                   pin_num=1, x=r1p1[0], y=r1p1[1], access_layer=1, unit=MM),
        TestRecord(pad_type=PadType.SMD_PAD, net_name="GND", ref_des="C1",
                   pin_num=1, x=c1p1[0], y=c1p1[1], access_layer=1, unit=MM),
    ]
    for r in recs:              # work around the lefover/leftover typo bug
        r.leftover = ""
    nl = Netlist(test_records=recs)
    files["board.ipc356"] = nl.write_to_bytes(settings=SETTINGS).decode()

    return files


def main() -> None:
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).parent / "out"
    out.mkdir(parents=True, exist_ok=True)
    files = build()
    for name, text in files.items():
        (out / name).write_text(text, encoding="utf-8")
    # Determinism self-check: build twice, assert byte-identical.
    again = build()
    identical = all(files[k] == again[k] for k in files)
    print(f"Wrote {len(files)} files to {out}")
    print(f"Deterministic (byte-identical on re-emit, no timestamp): {identical}")


if __name__ == "__main__":
    main()
